//! Tickets 10/11: small native file Owner/Gateway faults, with no network or credentials.
const std = @import("std");
const builtin = @import("builtin");
const durable = @import("../../../persistence/durable_store.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const trading = @import("../../../trading/trading_shard.zig");
const canonical = @import("../../../model/canonical_event.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const failover = @import("../../../runtime/failover.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const acceptance = @import("../history/order_gateway_archive_acceptance.zig");

fn place(sequence: u64) trading.oms.IntentGroup {
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = sequence, .count = 1 };
    group.members[0] = .{ .intent_sequence = sequence, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    return group;
}

fn openFile(path: []const u8) !*durable.LinuxFileAdapter {
    const adapter = try std.testing.allocator.create(durable.LinuxFileAdapter);
    errdefer std.testing.allocator.destroy(adapter);
    @memset(std.mem.asBytes(adapter), 0);
    if (builtin.os.tag == .linux) try adapter.initLinux(std.testing.io, path) else try adapter.initWindowsVerification(std.testing.io, path);
    return adapter;
}

fn closeFile(adapter: *durable.LinuxFileAdapter) void {
    adapter.close(std.testing.io);
    std.testing.allocator.destroy(adapter);
}

const FileHarness = struct {
    owner: *demo.Owner,
    gateway: *execution.Gateway,
    simulator: acceptance.CountingSimulator = .{},
    authority: failover.FencingAuthority,
    lease: failover.PrimaryLease,
    guard: failover.GatewayLeaseGuard,
    route: execution.Route,
    stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 10100 },
    dispatch: durable.StreamIdentity = .{ .domain = .control, .id = 10101 },
    first: trading.oms.Command,
    unknown: trading.oms.Command,
    next_fill: canonical.EventRecord,

    fn create(store: durable.Store, checkpoint_gateway: bool) !*@This() {
        const allocator = std.testing.allocator;
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.* = .{
            .owner = try allocator.create(demo.Owner),
            .gateway = undefined,
            .authority = failover.authorityForTesting(),
            .lease = undefined,
            .guard = undefined,
            .route = undefined,
            .first = undefined,
            .unknown = undefined,
            .next_fill = undefined,
        };
        errdefer allocator.destroy(self.owner);
        self.gateway = try allocator.create(execution.Gateway);
        errdefer allocator.destroy(self.gateway);
        try demo.Owner.bootstrapInto(self.owner, store, std.testing.io, self.stream);
        try acceptance.initializeOwner(self.owner);
        self.gateway.init();
        self.lease = try self.authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 3 * std.time.ns_per_s / 2);
        self.guard = .{ .authority = &self.authority, .lease = &self.lease };
        const adapter = self.simulator.adapter();
        try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = self.owner.shard.activatedAssets(), .instrument_definitions = self.owner.shard.instrument_registry });
        self.route = .{ .account = 2, .adapter = adapter, .venue_identity = 1, .lease_guard = &self.guard, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } };
        try self.gateway.add(self.route);
        try self.gateway.bootstrapDurableDispatch(store, std.testing.io, self.dispatch);
        _ = try self.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .oms_intent_group = place(101) } }));
        self.first = self.owner.shard.oms.emitted()[0];
        try std.testing.expectEqual(@import("../../../execution/venue_adapter.zig").SendResult.accepted, try self.owner.send(self.gateway, &self.guard, self.first.command_id, 2 * std.time.ns_per_s));
        var batch = (try adapter.tryDrain()).?;
        // Keep a real partial Fill with a nonzero fee, plus its matching report.
        batch.events[2].event.fill.fee.?.atoms = 17;
        for (batch.slice()[0..4]) |record| _ = try self.owner.apply(.{ .venue = record });
        self.next_fill = batch.events[4];
        self.next_fill.event.fill.fee.?.atoms = 19;
        _ = try self.owner.apply(fixture.atGroup(21, .{ .identity = 102, .payload = .{ .oms_intent_group = place(102) } }));
        self.unknown = self.owner.shard.oms.emitted()[0];
        try std.testing.expectEqual(@import("../../../execution/venue_adapter.zig").SendResult.accepted, try self.owner.send(self.gateway, &self.guard, self.unknown.command_id, 2 * std.time.ns_per_s));
        var uncertain = (try adapter.tryDrain()).?.events[0];
        uncertain.event.order_dispatch_result.state = .unknown;
        uncertain.envelope.identity.stream = 66;
        uncertain.envelope.source_stream = 66;
        uncertain.envelope.raw_evidence.stream = 66;
        _ = try self.owner.apply(.{ .venue = uncertain });
        try self.owner.checkpoint();
        if (checkpoint_gateway) try self.gateway.checkpointDurableDispatch();
        try std.testing.expectEqual(@as(u16, 2), self.owner.shard.oms.liveOrderCount());
        try std.testing.expectEqual(@as(i64, 10), try self.owner.shard.economic_projection.appliedCanonicalFillQuantity(self.first.order_id));
        return self;
    }

    fn destroy(self: *@This()) void {
        std.testing.allocator.destroy(self.owner);
        std.testing.allocator.destroy(self.gateway);
        std.testing.allocator.destroy(self);
    }
};

fn copyShard(shard: *const trading.TradingShard) !*trading.TradingShard {
    const result = try std.testing.allocator.create(trading.TradingShard);
    @memcpy(std.mem.asBytes(result), std.mem.asBytes(shard));
    return result;
}

fn expectState(actual: *const trading.TradingShard, expected: *const trading.TradingShard) !void {
    try std.testing.expectEqualSlices(u8, &expected.canonicalStateDigest(), &actual.canonicalStateDigest());
    try std.testing.expectEqualSlices(u8, &expected.economic_projection.digest(), &actual.economic_projection.digest());
    try std.testing.expectEqual(try expected.activeReservationAtoms(), try actual.activeReservationAtoms());
    try std.testing.expectEqual(expected.authoritativeBarrier(), actual.authoritativeBarrier());
    try std.testing.expectEqualDeep(expected.canonical_ingress_cursors[0..expected.canonical_ingress_cursor_count], actual.canonical_ingress_cursors[0..actual.canonical_ingress_cursor_count]);
    inline for (.{ "portfolio", "exchange" }) |layer| {
        const left = &@field(expected.economic_projection, layer);
        const right = &@field(actual.economic_projection, layer);
        try std.testing.expectEqual(left.usdt_balance_atoms, right.usdt_balance_atoms);
        try std.testing.expectEqual(left.spotInventoryAtoms(0x425443), right.spotInventoryAtoms(0x425443));
        try std.testing.expectEqual(left.fee_atoms, right.fee_atoms);
        try std.testing.expectEqualDeep(left.positionForInstrument(3), right.positionForInstrument(3));
    }
    try std.testing.expectEqual(expected.economic_projection.ledger_count, actual.economic_projection.ledger_count);
    for (expected.economic_projection.ledger[0..expected.economic_projection.ledger_count], actual.economic_projection.ledger[0..actual.economic_projection.ledger_count]) |left, right| {
        try std.testing.expectEqual(left.source_identity, right.source_identity);
        try std.testing.expectEqual(left.kind, right.kind);
        try std.testing.expectEqual(left.layer, right.layer);
        try std.testing.expectEqualDeep(left.postings[0..left.posting_count], right.postings[0..right.posting_count]);
    }
}

test "Native file capacity faults recover complete partial Fill economics reservations and Unknown without sends" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;
    const Case = struct { point: durable.FaultPoint, fault: durable.Fault, apply: bool = false, skip: usize = 0 };
    const cases = [_]Case{
        .{ .point = .append, .fault = .short_write, .apply = true },
        .{ .point = .commit, .fault = .sync_timeout, .apply = true },
        .{ .point = .root_publish, .fault = .eio, .apply = true },
        .{ .point = .root_publish, .fault = .eio, .apply = true, .skip = 1 },
        .{ .point = .publish, .fault = .read_only },
        .{ .point = .snapshot_sync, .fault = .sync_timeout },
        .{ .point = .archive_sync, .fault = .sync_timeout },
        .{ .point = .root_publish, .fault = .eio },
        .{ .point = .reclaim, .fault = .eio },
    };
    for (cases) |case| {
        var temp = std.testing.tmpDir(.{});
        var path_buffer: [1024]u8 = undefined;
        const path = path_buffer[0..try temp.dir.realPath(std.testing.io, &path_buffer)];
        var completed = false;
        defer if (completed) temp.cleanup() else std.debug.print("windows_capacity_failed_directory={s}\n", .{path});
        var adapter: ?*durable.LinuxFileAdapter = try openFile(path);
        defer if (adapter) |value| closeFile(value);
        const harness = try FileHarness.create(adapter.?.interface(), true);
        defer harness.destroy();
        const old = try copyShard(&harness.owner.shard);
        defer std.testing.allocator.destroy(old);
        const new = try copyShard(old);
        defer std.testing.allocator.destroy(new);
        var reference_journal = harness.owner.decision_journal;
        _ = try trading.applyStable(new, &reference_journal, .{ .venue = harness.next_fill });
        if (!case.apply) _ = try harness.owner.apply(.{ .venue = harness.next_fill });
        adapter.?.injectFaultAfter(case.fault, case.point, case.skip);
        if (case.apply) {
            try std.testing.expectError(error.DecisionLogUnavailable, harness.owner.apply(.{ .venue = harness.next_fill }));
        } else {
            try std.testing.expectError(error.DecisionLogUnavailable, harness.owner.checkpoint());
        }
        try std.testing.expect(harness.owner.closed);
        try std.testing.expectEqual(durable.GateState.closed, adapter.?.interface().safetyGate());
        try std.testing.expectError(error.DecisionLogUnavailable, harness.owner.send(harness.gateway, &harness.guard, harness.unknown.command_id, 2 * std.time.ns_per_s));
        closeFile(adapter.?);
        adapter = null;
        const reopened = try openFile(path);
        defer closeFile(reopened);
        const recovered = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(recovered);
        try demo.Owner.recoverInto(recovered, reopened.interface(), std.testing.io, harness.stream);
        try expectState(&recovered.shard, if (recovered.shard.authoritativeBarrier() == old.authoritativeBarrier()) old else new);
        try std.testing.expect(recovered.closed or recovered.shard.recovery_admission_pending);
        try std.testing.expectEqual(trading.oms.OrderState.unknown, recovered.shard.oms.orderById(harness.unknown.order_id).?.state);
        const gateway = try std.testing.allocator.create(execution.Gateway);
        defer std.testing.allocator.destroy(gateway);
        gateway.init();
        try gateway.add(harness.route);
        try gateway.attachRecoveredDurableDispatch(reopened.interface(), std.testing.io, harness.dispatch);
        try std.testing.expect(gateway.acceptedClientOrderIdFromShard(&recovered.shard, harness.first.command_id) != null);
        try std.testing.expect(gateway.acceptedClientOrderIdFromShard(&recovered.shard, harness.unknown.command_id) != null);
        try std.testing.expectError(error.DecisionLogUnavailable, recovered.send(gateway, &harness.guard, harness.first.command_id, 2 * std.time.ns_per_s));
        try std.testing.expectError(error.DecisionLogUnavailable, recovered.send(gateway, &harness.guard, harness.unknown.command_id, 2 * std.time.ns_per_s));
        try std.testing.expectEqual(@as(u64, 2), harness.simulator.sends);
        const again = try openFile(path);
        defer closeFile(again);
        const repeated = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(repeated);
        try demo.Owner.recoverInto(repeated, again.interface(), std.testing.io, harness.stream);
        try expectState(&repeated.shard, &recovered.shard);
        std.debug.print("windows_capacity_fault injection=adapter_hook point={s} fault={s} public_error=DecisionLogUnavailable apply={any} skip={d} live=2 terminal=0 barrier={d} recovered_closed={any} sends=2 schema={d} artifact={d} old_digest={x} new_digest={x} recovered_digest={x} economics={x}\n", .{ @tagName(case.point), @tagName(case.fault), case.apply, case.skip, recovered.shard.authoritativeBarrier(), recovered.closed, @import("../../../runtime/production_contract.zig").state_schema_version, trading.release_artifact_identity, old.canonicalStateDigest(), new.canonicalStateDigest(), recovered.shard.canonicalStateDigest(), recovered.shard.economic_projection.digest() });
        completed = true;
    }
}

fn publishIncompatible(context: *anyopaque, io: std.Io, stream: durable.StreamIdentity, barrier: u64, bytes: []const u8, comptime artifact: bool) !void {
    const adapter: *durable.LinuxFileAdapter = @ptrCast(@alignCast(context));
    const changed = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(changed);
    // Publish through the real file Store so its object hash and root certify
    // this exact incompatible payload. Core must reject identity independently
    // of transport checks, rather than the test bypassing Store authentication.
    if (artifact) {
        std.mem.writeInt(u64, changed[20..28], trading.release_artifact_identity + 1, .little);
    } else {
        std.mem.writeInt(u32, changed[16..20], @import("../../../runtime/production_contract.zig").previous_state_schema_version, .little);
    }
    std.mem.writeInt(u32, changed[124..128], std.hash.crc.Crc32Iscsi.hash(changed[0..124]), .little);
    try adapter.interface().publishSnapshot(io, stream, barrier, changed);
}

fn publishOldSchema(context: *anyopaque, io: std.Io, stream: durable.StreamIdentity, barrier: u64, bytes: []const u8) !void {
    try publishIncompatible(context, io, stream, barrier, bytes, false);
}

fn publishForeignArtifact(context: *anyopaque, io: std.Io, stream: durable.StreamIdentity, barrier: u64, bytes: []const u8) !void {
    try publishIncompatible(context, io, stream, barrier, bytes, true);
}

test "Native file capacity file reopen rejects missing corrupt and authenticated incompatible authority" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;
    const Damage = enum { missing_segment, corrupt_segment, truncate_segment, corrupt_manifest, old_schema, foreign_artifact };
    for ([_]Damage{ .missing_segment, .corrupt_segment, .truncate_segment, .corrupt_manifest, .old_schema, .foreign_artifact }) |damage| {
        var temp = std.testing.tmpDir(.{});
        var path_buffer: [1024]u8 = undefined;
        const path = path_buffer[0..try temp.dir.realPath(std.testing.io, &path_buffer)];
        var completed = false;
        defer if (completed) temp.cleanup() else std.debug.print("windows_capacity_failed_directory={s}\n", .{path});
        var adapter: ?*durable.LinuxFileAdapter = try openFile(path);
        defer if (adapter) |value| closeFile(value);
        const harness = try FileHarness.create(adapter.?.interface(), true);
        defer harness.destroy();
        if (damage == .old_schema or damage == .foreign_artifact) {
            _ = try harness.owner.apply(.{ .venue = harness.next_fill });
            var vtable = adapter.?.interface().vtable.*;
            vtable.publish = if (damage == .old_schema) publishOldSchema else publishForeignArtifact;
            harness.owner.store = .{ .context = adapter.?, .vtable = &vtable };
            try harness.owner.checkpoint();
            // The physical file root is intact; only the Core identity is wrong.
            const physical = try adapter.?.interface().recover(std.testing.io, harness.stream);
            try std.testing.expectEqual(durable.RecoveryStatus.ready, physical.status);
        }
        const before = try adapter.?.interface().recover(std.testing.io, harness.stream);
        closeFile(adapter.?);
        adapter = null;
        var name_buffer: [128]u8 = undefined;
        const segment = try std.fmt.bufPrint(&name_buffer, "segment-{d}-{d}-{d}.log", .{ @intFromEnum(harness.stream.domain), harness.stream.id, before.segment_index });
        if (damage == .missing_segment) try temp.dir.deleteFile(std.testing.io, segment);
        if (damage == .corrupt_segment) {
            const file = try temp.dir.openFile(std.testing.io, segment, .{ .mode = .read_write });
            defer file.close(std.testing.io);
            var byte: [1]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 1), try file.readPositionalAll(std.testing.io, &byte, 0));
            byte[0] ^= 1;
            // Same length, different digest; do not merely exercise truncation.
            try file.writePositionalAll(std.testing.io, &byte, 0);
            try file.sync(std.testing.io);
        }
        if (damage == .truncate_segment or damage == .corrupt_manifest) {
            const file = try temp.dir.createFile(std.testing.io, if (damage == .corrupt_manifest) "manifest.bin" else segment, .{});
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, "damaged-published-authority");
            try file.sync(std.testing.io);
        }
        const reopened = try openFile(path);
        defer closeFile(reopened);
        const physical = try reopened.interface().recover(std.testing.io, harness.stream);
        const rejected = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(rejected);
        try std.testing.expectError(error.DecisionLogUnavailable, demo.Owner.recoverInto(rejected, reopened.interface(), std.testing.io, harness.stream));
        try std.testing.expect(rejected.closed);
        try std.testing.expectError(error.DecisionLogUnavailable, rejected.source());
        try std.testing.expectEqual(@as(u64, 2), harness.simulator.sends);
        std.debug.print("windows_capacity_reject injection={s} damage={s} live_input=2 terminal_input=0 store_physical_ready={any} core_error=DecisionLogUnavailable owner_closed=true sends=2 expected_schema={d} published_schema={d} expected_artifact={d} published_artifact={d}\n", .{ if (damage == .old_schema or damage == .foreign_artifact) "authenticated_snapshot_publish" else "task_owned_file_mutation", @tagName(damage), physical.status == .ready, @import("../../../runtime/production_contract.zig").state_schema_version, if (damage == .old_schema) @import("../../../runtime/production_contract.zig").previous_state_schema_version else @import("../../../runtime/production_contract.zig").state_schema_version, trading.release_artifact_identity, trading.release_artifact_identity + @as(u64, @intFromBool(damage == .foreign_artifact)) });
        completed = true;
    }
}

test "Native file capacity Gateway checkpoint faults preserve accepted proofs and never resend Unknown" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;
    for ([_]durable.FaultPoint{ .snapshot_sync, .root_publish, .reclaim }) |point| {
        var temp = std.testing.tmpDir(.{});
        var path_buffer: [1024]u8 = undefined;
        const path = path_buffer[0..try temp.dir.realPath(std.testing.io, &path_buffer)];
        var completed = false;
        defer if (completed) temp.cleanup() else std.debug.print("windows_capacity_failed_directory={s}\n", .{path});
        var adapter: ?*durable.LinuxFileAdapter = try openFile(path);
        defer if (adapter) |value| closeFile(value);
        const harness = try FileHarness.create(adapter.?.interface(), false);
        defer harness.destroy();
        const expected = try copyShard(&harness.owner.shard);
        defer std.testing.allocator.destroy(expected);
        adapter.?.injectFaultAt(.eio, point);
        try std.testing.expectError(error.InputOutput, harness.gateway.checkpointDurableDispatch());
        try std.testing.expectEqual(durable.GateState.closed, adapter.?.interface().safetyGate());
        try std.testing.expectError(error.DecisionLogUnavailable, harness.owner.send(harness.gateway, &harness.guard, harness.unknown.command_id, 2 * std.time.ns_per_s));
        closeFile(adapter.?);
        adapter = null;
        const reopened = try openFile(path);
        defer closeFile(reopened);
        const recovered = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(recovered);
        try demo.Owner.recoverInto(recovered, reopened.interface(), std.testing.io, harness.stream);
        try expectState(&recovered.shard, expected);
        const gateway = try std.testing.allocator.create(execution.Gateway);
        defer std.testing.allocator.destroy(gateway);
        gateway.init();
        try gateway.add(harness.route);
        try gateway.attachRecoveredDurableDispatch(reopened.interface(), std.testing.io, harness.dispatch);
        try std.testing.expectEqual(@as(u16, 2), gateway.accepted_dispatch_count);
        try std.testing.expect(gateway.acceptedClientOrderIdFromShard(&recovered.shard, harness.first.command_id) != null);
        try std.testing.expect(gateway.acceptedClientOrderIdFromShard(&recovered.shard, harness.unknown.command_id) != null);
        try std.testing.expectEqual(trading.oms.OrderState.unknown, recovered.shard.oms.orderById(harness.unknown.order_id).?.state);
        try std.testing.expectError(error.DecisionLogUnavailable, recovered.send(gateway, &harness.guard, harness.unknown.command_id, 2 * std.time.ns_per_s));
        try std.testing.expectEqual(@as(u64, 2), harness.simulator.sends);
        std.debug.print("windows_capacity_gateway_fault injection=adapter_hook point={s} fault=eio public_error=InputOutput live=2 terminal=0 accepted=2 unknown_orders=1 sends=2 recovered_digest={x}\n", .{ @tagName(point), recovered.shard.canonicalStateDigest() });
        completed = true;
    }
}
