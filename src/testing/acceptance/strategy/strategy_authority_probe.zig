//! Offline Web/Host/core acceptance node. No Venue transport or credentials.
const std = @import("std");
const fixture = @import("../../support/trading_shard_fixture.zig");
const trading = @import("../../../trading/trading_shard.zig");
const package = @import("../../../strategy/strategy_package_authority.zig");
const lifecycle = @import("../../../strategy/strategy_host_lifecycle.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const durable = @import("../../../persistence/durable_store.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const simulated = @import("../../../adapters/simulated/simulated_venue.zig");
const hyperliquid = @import("../../../runtime/hyperliquid_runtime.zig");
const hl = @import("../../../adapters/hyperliquid/hyperliquid_venue_adapter.zig");
const offline_io = @import("../../support/hyperliquid_runtime_io.zig");
const raw = @import("../../../persistence/raw_ingress.zig");

const Node = struct {
    run: fixture.LiveRun,
    joint: ?*demo.Owner = null,
    fn shard(self: *Node) *trading.TradingShard {
        return if (self.joint) |owner| &owner.shard else &self.run.shard;
    }
    fn journal(self: *Node) *trading.journal.Journal {
        return if (self.joint) |owner| &owner.decision_journal else &self.run.decision_journal;
    }
    fn reconcile(context: *anyopaque) !@import("../../../runtime/recovery_cutover.zig").VenueEvidence {
        const self: *Node = @ptrCast(@alignCast(context));
        // Offline fixture observation only; production must supply actual Venue evidence.
        const Recovery = @import("../../../runtime/recovery_cutover.zig").RecoveryCoordinator;
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
    const executable_path = try std.process.executablePathAlloc(init.io, init.gpa);
    defer init.gpa.free(executable_path);
    const executable = try std.Io.Dir.cwd().readFileAlloc(init.io, if (@import("builtin").os.tag == .linux) "/proc/self/exe" else executable_path, init.gpa, .limited(256 * 1024 * 1024));
    defer init.gpa.free(executable);
    var binary_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(executable, &binary_digest, .{});
    const key_path = args.next() orelse return error.KeyFileRequired;
    const mode = args.next();
    const group = mode != null;
    const multiple = if (mode) |value| std.mem.eql(u8, value, "multiple") else false;
    const use_hyperliquid = if (mode) |value| std.mem.eql(u8, value, "hyperliquid") else false;
    if (mode) |value| if (!multiple and !use_hyperliquid and !std.mem.eql(u8, value, "group")) return error.InvalidOfflineMode;
    if (args.next() != null) return error.UnknownArgument;
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
        if (multiple) {
            const manifest = try @import("../core/multi_portfolio_authority_acceptance.zig").cycleConfiguration();
            try @import("../core/multi_account_authority_acceptance.zig").initializePythonOwnerForConfiguration(joint, &manifest);
            for ([_]u128{ 20, 30 }) |account| {
                _ = try joint.apply(fixture.atGroup(45, .{ .identity = joint.shard.authoritativeBarrier() + 1, .account_scope = account, .payload = .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } } }));
                _ = try joint.apply(fixture.atGroup(45, .{ .identity = joint.shard.authoritativeBarrier() + 1, .account_scope = account, .payload = .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 100 } } }));
            }
            _ = try joint.apply(fixture.atGroup(45, .{ .identity = joint.shard.authoritativeBarrier() + 1, .payload = .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } } }));
            for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| {
                _ = try joint.apply(fixture.atGroup(45, .{ .identity = joint.shard.authoritativeBarrier() + 1, .account_scope = account, .payload = .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = account, .instrument = instrument, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = true } } }));
            }
        } else try @import("../core/multi_account_authority_acceptance.zig").initializePythonOwner(joint);
        if (use_hyperliquid) {
            var capability = joint.shard.registryInstrument(101).?.capability.?;
            capability.version = 2;
            capability.adapter_session = 7;
            _ = try joint.apply(fixture.atGroup(44, .{ .identity = 2000, .account_scope = 20, .payload = .{ .capability_profile_activation = capability } }));
        }
        node.joint = joint;
    } else {
        try fixture.applyCanonicalGenesis(&node.run.shard, &node.run.decision_journal, .{ .strategy_identity = 16, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged, 1);
        try fixture.applyHealthyPrelude(&node.run);
    }
    const pause = @import("../../../runtime/control_channel.zig").ControlCommand{
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
        .running_binary_sha256 = std.fmt.bytesToHex(binary_digest, .lower),
    };
    defer authority.revoke() catch {};
    var secondary = authority;
    secondary.strategy = 19;
    defer if (multiple) secondary.revoke() catch {};
    var bindings = [_]*package.Authority{ &authority, &secondary };
    const authorities: package.AuthoritySet = .{ .members = bindings[0..if (multiple) 2 else 1] };
    const venue = try init.gpa.create(simulated.SimulatedVenue);
    defer init.gpa.destroy(venue);
    venue.* = .{};
    const adapter = venue.adapter();
    const view = try init.gpa.create(trading.TradingShard);
    defer init.gpa.destroy(view);
    if (use_hyperliquid) try node.shard().copyAccountViewInto(view, 30) else @memcpy(std.mem.asBytes(view), std.mem.asBytes(node.shard()));
    try adapter.start(.{ .venue = if (use_hyperliquid) 21 else 1, .environment = .simulation, .exchange_account = if (use_hyperliquid) 30 else if (group) 20 else 2, .adapter_session = 1, .request_capacity = 16, .output_capacity = 16, .asset_definitions = view.activatedAssets(), .instrument_definitions = view.instrument_registry });
    const dispatch_store = try init.gpa.create(durable.MemoryAdapter);
    defer init.gpa.destroy(dispatch_store);
    dispatch_store.* = .initWithAllocator(init.gpa);
    defer dispatch_store.deinit();
    const gateway = try init.gpa.create(execution.Gateway);
    defer init.gpa.destroy(gateway);
    gateway.init();
    try gateway.add(.{ .account = if (use_hyperliquid) 30 else if (group) 20 else 2, .adapter = adapter, .venue_identity = if (use_hyperliquid) 21 else 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    try gateway.bootstrapDurableDispatch(dispatch_store.interface(), init.io, .{ .domain = .control, .id = 77 });
    if (group) try gateway.pinDeploymentDigest(node.shard().deployment.header.?.expected_digest);
    const assembly = if (use_hyperliquid) try init.gpa.create(hyperliquid.Runtime) else null;
    defer if (assembly) |value| init.gpa.destroy(value);
    var hl_io: offline_io.IO = undefined;
    var budget: hl.Budget = .{};
    const hl_bindings = [_]hl.Binding{.{ .instrument = 101, .coin = "BTC", .wire_asset = 3, .product = .isolated_linear, .size_decimals = 4, .quantity_scale = 4, .lot_atoms = 1, .price_scale = 6, .tick_atoms = 1 }};
    const hl_feeds = [_]hyperliquid.FeedConfiguration{.{ .binding = .{ .instrument = 101, .coin = "BTC", .product = .isolated_linear, .universe_index = 3, .size_decimals = 4, .rules_version = 1, .expected_metadata_digest = @splat(1), .quantity_scale = 4, .lot_atoms = 1, .price_scale = 6, .tick_atoms = 1 }, .subscription_set = 70, .session = 60 }};
    if (assembly) |value| {
        hl_io = .{ .sink = try raw.DurableSink.init(core_store.interface(), init.io, .{ .domain = .raw_ingress, .id = 7 }), .session = 7 };
        try hyperliquid.Runtime.initInto(value, init.gpa, .{ .epoch_startup = .virgin, .profile = .{ .venue = 1, .account = 20, .session = 7, .funding = @splat(2), .environment = .simulation, .bindings = &hl_bindings, .version = 2, .rules_version = 1, .config_version = 1 }, .feeds = &hl_feeds }, .{ .offline = .{ .transport = .{ .ptr = &hl_io, .submit_fn = offline_io.IO.submit, .query_fn = offline_io.IO.query }, .authorizer = .{ .ptr = &hl_io, .sign_fn = offline_io.IO.sign, .check_fn = offline_io.IO.check } } }, joint, gateway, .{ .ptr = &hl_io, .now_fn = offline_io.IO.now }, &budget, hl_io.sink, try raw.DurableSink.init(core_store.interface(), init.io, .{ .domain = .raw_ingress, .id = 8 }), .{ .domain = .control, .id = 94 });
    }
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
        const request = try std.json.parseFromSlice(struct { operation: []const u8, command: u64 = 1 }, init.gpa, bytes, .{ .ignore_unknown_fields = true });
        defer request.deinit();
        if (std.mem.eql(u8, request.value.operation, "dispatch")) {
            const command = node.shard().oms.findCommand(request.value.command) orelse return error.NoCommand;
            if (group) try node.shard().copyAccountViewInto(view, command.authority.exchange_account) else @memcpy(std.mem.asBytes(view), std.mem.asBytes(node.shard()));
            if (view.currentNetExchangePosition(command.instrument)) |position| try gateway.observeAuthorityFromShard(node.shard(), .{
                .account = command.authority.exchange_account,
                .effective_trading_authority = view.operational_state.effectiveTradingAuthority(),
                .reservation_identity = command.reservation_identity,
                .reservation = command.reservation,
                .primary_lease_expires_at_monotonic_ns = 100 * std.time.ns_per_s,
                .fencing_token = 1,
                .exchange_position = position,
                .authority_barrier = node.shard().authoritativeBarrier(),
            });
            const now = command.authority.dispatch_deadline_monotonic_ns -| 1;
            if (assembly != null) hl_io.current.monotonic_time_ns = now;
            const result = (if (assembly != null and command.authority.exchange_account == 20) assembly.?.send(command.command_id, now) else gateway.sendFromShard(node.shard(), command.command_id, now)) catch |err| {
                try output.interface.print("{{\"dispatch\":\"{s}\",\"attempts\":{d}}}\n", .{ @errorName(err), gateway.send_attempt_count });
                try output.interface.flush();
                continue;
            };
            if (assembly) |value| {
                if (command.authority.exchange_account == 20 and hl_io.sends == 0) return error.HyperliquidOfflineTransportNotReached;
                try value.drain();
            }
            try output.interface.print("{{\"dispatch\":\"{s}\",\"attempts\":{d}}}\n", .{ @tagName(result), gateway.send_attempt_count });
        } else if (std.mem.eql(u8, request.value.operation, "native_reference")) {
            if (group) return error.UnsupportedNativeFixture;
            const sequence = node.shard().authoritativeBarrier() + 1_000;
            var price_input = fixture.canonicalAt(15, sequence, .{ .reference_price = .{
                .instrument = 3,
                .kind = .index,
                .price = .{ .instrument = 3, .rules_version = 1, .ticks = 42 },
            } });
            price_input.venue.envelope.scope = .instrument;
            price_input.venue.envelope.exchange_account = null;
            price_input.venue.envelope.instrument = 3;
            price_input.venue.envelope.identity.stream = 9000;
            price_input.venue.envelope.source_stream = 9000;
            _ = try trading.applyStable(node.shard(), node.journal(), price_input);
            try output.interface.print("{{\"cursor\":{d}}}\n", .{node.shard().authoritativeBarrier()});
        } else if (std.mem.eql(u8, request.value.operation, "advance")) {
            try Node.commit(node, .{ .mark_price = .{ .instrument = if (group) 101 else 3, .price_atoms = if (group) 10 else 50_000_000_000 } });
            try output.interface.print("{{\"cursor\":{d}}}\n", .{node.shard().authoritativeBarrier()});
        } else if (std.mem.eql(u8, request.value.operation, "gate")) {
            try Node.commit(node, .{ .safety_gate_change = .{ .gate_identity = 0x1234, .target_identity = 1, .kind = .self_recovering, .reason = .primary_lease, .open = false } });
            try output.interface.writeAll("{}\n");
        } else {
            const result = authorities.request(init.gpa, bytes, key[0..32], init.io) catch |err| {
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
