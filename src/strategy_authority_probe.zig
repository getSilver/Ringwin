//! Offline Web/Host/core acceptance node. No Venue transport or credentials.
const std = @import("std");
const fixture = @import("testing/support/trading_shard_fixture.zig");
const trading = @import("trading/trading_shard.zig");
const package = @import("strategy/strategy_package_authority.zig");
const lifecycle = @import("strategy/strategy_host_lifecycle.zig");
const execution = @import("execution/execution_gateway.zig");
const durable = @import("persistence/durable_store.zig");
const demo = @import("runtime/demo/demo_authority.zig");
const simulated = @import("adapters/simulated/simulated_venue.zig");

const Node = struct {
    run: fixture.LiveRun,
    joint: ?*demo.Owner = null,
    fn shard(self: *Node) *trading.TradingShard {
        return if (self.joint) |owner| &owner.shard else &self.run.shard;
    }
    fn journal(self: *Node) *trading.journal.Journal {
        return if (self.joint) |owner| &owner.decision_journal else &self.run.decision_journal;
    }
    fn reconcile(context: *anyopaque) !@import("runtime/recovery_cutover.zig").VenueEvidence {
        const self: *Node = @ptrCast(@alignCast(context));
        // Offline fixture observation only; production must supply actual Venue evidence.
        const Recovery = @import("runtime/recovery_cutover.zig").RecoveryCoordinator;
        const recovery = try std.heap.page_allocator.create(Recovery);
        defer std.heap.page_allocator.destroy(recovery);
        Recovery.beginInto(recovery, self.shard(), self.shard().authoritativeBarrier());
        return recovery.expectedVenueEvidence();
    }
    fn commit(context: *anyopaque, payload: trading.CorePayload) !void {
        const self: *Node = @ptrCast(@alignCast(context));
        var input = fixture.atGroup(if (self.joint != null) 45 else 15, .{ .identity = self.shard().authoritativeBarrier() + 1, .payload = payload });
        if (self.joint) |owner| {
            if (payload == .mark_price) input.core.account_scope = 20;
            _ = try owner.apply(input);
        } else _ = try trading.applyStable(self.shard(), self.journal(), input);
    }
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const key_path = args.next() orelse return error.KeyFileRequired;
    const group = args.next() != null;
    const key = try std.Io.Dir.cwd().readFileAlloc(init.io, key_path, init.gpa, .limited(33));
    defer init.gpa.free(key);
    if (key.len != 32) return error.InvalidKey;
    const node = try init.gpa.create(Node);
    defer init.gpa.destroy(node);
    node.* = .{ .run = .{ .shard = .{}, .decision_journal = trading.journal.Journal.init() } };
    const core_store = try init.gpa.create(durable.MemoryAdapter);
    defer init.gpa.destroy(core_store);
    core_store.* = .initWithAllocator(init.gpa);
    defer core_store.deinit();
    const joint = try init.gpa.create(demo.Owner);
    defer init.gpa.destroy(joint);
    if (group) {
        try demo.Owner.bootstrapInto(joint, core_store.interface(), init.io, .{ .domain = .decision_log, .id = 91 });
        try @import("testing/acceptance/core/multi_account_authority_acceptance.zig").initializePythonOwner(joint);
        node.joint = joint;
    } else {
        try fixture.applyCanonicalGenesis(&node.run.shard, &node.run.decision_journal, .{ .strategy_identity = 16, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged, 1);
        try fixture.applyHealthyPrelude(&node.run);
    }
    const pause = @import("control_channel.zig").ControlCommand{
        .command_identity = 7001,
        .content_hash = 7001,
        .kind = .trading_pause,
        .target_identity = 1,
        .expected_version = node.shard().operational_state.version,
        .expires_at = std.math.maxInt(u64),
    };
    try Node.commit(node, .{ .control_command = pause });
    try Node.commit(node, .{ .lifecycle_progress = .{ .operation_identity = 7001, .target_identity = 1, .open_orders_closed = true, .reconciliation_complete = true, .position_quantity = 0 } });
    const plan = lifecycle.developmentPlan(1, 1, 0);
    var authority: package.Authority = .{
        .shard = node.shard(),
        .journal = node.journal(),
        .context = node,
        .commit = Node.commit,
        .strategy = if (group) 9 else 16,
        .config_version = 1,
        .schema_registry = plan.compatibility.schema_registry,
        .decision_domain = 1,
        .fencing = 1,
        .shard_id = 1,
        .max_outputs = 4,
        .reconciliation = Node.reconcile,
    };
    defer authority.revoke() catch {};
    const venue = try init.gpa.create(simulated.SimulatedVenue);
    defer init.gpa.destroy(venue);
    venue.* = .{};
    const adapter = venue.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = if (group) 20 else 2, .adapter_session = 1, .request_capacity = 16, .output_capacity = 16, .asset_definitions = node.shard().activatedAssets(), .instrument_definitions = node.shard().instrument_registry });
    const dispatch_store = try init.gpa.create(durable.MemoryAdapter);
    defer init.gpa.destroy(dispatch_store);
    dispatch_store.* = .initWithAllocator(init.gpa);
    defer dispatch_store.deinit();
    const gateway = try init.gpa.create(execution.Gateway);
    defer init.gpa.destroy(gateway);
    gateway.init();
    try gateway.add(.{ .account = if (group) 20 else 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    try gateway.bootstrapDurableDispatch(dispatch_store.interface(), init.io, .{ .domain = .control, .id = 77 });
    if (group) try gateway.pinDeploymentDigest(node.shard().deployment.header.?.expected_digest);
    const input_storage = try init.gpa.alloc(u8, 256 * 1024 + 4);
    defer init.gpa.free(input_storage);
    var input = std.Io.File.stdin().reader(init.io, input_storage);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    while (true) {
        const len = input.interface.takeInt(u32, .little) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (len == 0 or len > 256 * 1024) return error.RequestTooLarge;
        const bytes = try input.interface.take(len);
        const request = try std.json.parseFromSlice(struct { operation: []const u8 }, init.gpa, bytes, .{ .ignore_unknown_fields = true });
        defer request.deinit();
        if (std.mem.eql(u8, request.value.operation, "dispatch")) {
            const command = node.shard().oms.findCommand(1) orelse return error.NoCommand;
            if (node.shard().currentNetExchangePosition(command.instrument)) |position| try gateway.observeAuthorityFromShard(node.shard(), .{
                .account = if (group) 20 else 2,
                .effective_trading_authority = node.shard().operational_state.effectiveTradingAuthority(),
                .reservation_identity = command.reservation_identity,
                .reservation = command.reservation,
                .primary_lease_expires_at_monotonic_ns = 100 * std.time.ns_per_s,
                .fencing_token = 1,
                .exchange_position = position,
                .authority_barrier = node.shard().authoritativeBarrier(),
            });
            const result = gateway.sendFromShard(node.shard(), 1, command.authority.dispatch_deadline_monotonic_ns -| 1) catch |err| {
                try output.interface.print("{{\"dispatch\":\"{s}\",\"attempts\":{d}}}\n", .{ @errorName(err), gateway.send_attempt_count });
                try output.interface.flush();
                continue;
            };
            try output.interface.print("{{\"dispatch\":\"{s}\",\"attempts\":{d}}}\n", .{ @tagName(result), gateway.send_attempt_count });
        } else if (std.mem.eql(u8, request.value.operation, "advance")) {
            try Node.commit(node, .{ .mark_price = .{ .instrument = if (group) 101 else 3, .price_atoms = if (group) 10 else 50_000_000_000 } });
            try output.interface.print("{{\"cursor\":{d}}}\n", .{node.shard().authoritativeBarrier()});
        } else if (std.mem.eql(u8, request.value.operation, "gate")) {
            try Node.commit(node, .{ .safety_gate_change = .{ .gate_identity = 0x1234, .target_identity = 1, .kind = .self_recovering, .reason = .primary_lease, .open = false } });
            try output.interface.writeAll("{}\n");
        } else {
            const result = authority.request(init.gpa, bytes, key[0..32], init.io) catch |err| {
                try output.interface.print("{{\"error\":\"{s}\"}}\n", .{@errorName(err)});
                try output.interface.flush();
                continue;
            };
            defer init.gpa.free(result);
            try output.interface.writeAll(result);
            try output.interface.writeByte('\n');
        }
        try output.interface.flush();
    }
}
