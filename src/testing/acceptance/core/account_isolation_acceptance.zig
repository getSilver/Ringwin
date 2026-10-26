//! Ticket 06: durable public Owner boundaries, never a network transport.
const std = @import("std");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const setup = @import("shared_venue_delivery_acceptance.zig");
const shared = @import("shared_gateway_venue_acceptance.zig");
const execution = @import("../../../execution/execution_gateway.zig");

fn command(owner: *demo.Owner, identity: u64, kind: @import("../../../trading/operational.zig").CommandKind, latch: u128) !void {
    _ = try owner.apply(fixture.atGroup(48, .{ .identity = identity, .payload = .{ .control_command = .{
        .command_identity = identity,
        .content_hash = identity,
        .target_identity = owner.shard.operational_state.target_identity,
        .expected_version = owner.shard.operational_state.version,
        .expires_at = std.math.maxInt(u64),
        .kind = kind,
        .referenced_latch_identity = latch,
    } } }));
}

test "06 two accounts in one domain retain independent safety causes" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try @import("multi_account_authority_acceptance.zig").initializePythonOwner(owner);
    var first = try coordination.CoordinatorOwner.init(.init(20, 100, 100), .{ .domain = .control, .id = 9403 }, memory.interface(), undefined);
    var second = try coordination.CoordinatorOwner.init(.init(30, 100, 100), .{ .domain = .control, .id = 9404 }, memory.interface(), undefined);
    for ([_]*coordination.CoordinatorOwner{ &first, &second }) |coordinator| {
        try coordinator.apply(.{ .shared_safety = .{ .source = .credential, .version = 1, .open = false } });
        const state = coordinator.coordinator.shared_safety[0];
        _ = try owner.apply(.{ .core = try coordination.accountGateEvent(.{ .shard_id = .shard_0, .gate = .{ .identity = state.identity, .open = state.open, .latched = true } }, 1) });
    }
    try std.testing.expect(first.coordinator.shared_safety[0].identity != second.coordinator.shared_safety[0].identity);
    try first.apply(.{ .shared_safety = .{ .source = .credential, .version = 2, .open = true } });
    _ = try owner.apply(.{ .core = try coordination.accountGateEvent(.{ .shard_id = .shard_0, .gate = .{ .identity = first.coordinator.shared_safety[0].identity, .open = true, .latched = false } }, 1) });
    try command(owner, 8200, .resolve_latch, first.coordinator.shared_safety[0].identity);
    try std.testing.expectError(error.SafetyGateCauseUnresolved, command(owner, 8201, .resolve_latch, second.coordinator.shared_safety[0].identity));
    try demo.Owner.recoverInto(owner, memory.interface(), undefined, owner.stream);
    try std.testing.expect(!owner.shard.operational_state.effectiveTradingAuthority());
}

test "06 independent account credential and Gateway restrictions fan out and recover without authorization" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const owners = try std.testing.allocator.alloc(demo.Owner, 4);
    defer std.testing.allocator.free(owners);
    var coordinator = try coordination.CoordinatorOwner.init(.init(2, 100, 100), .{ .domain = .control, .id = 9400 }, memory.interface(), undefined);
    for (owners, 0..) |*owner, index| {
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 9101 + index });
        try setup.initialize(owner, index);
        try shared.prepareTrading(owner, index, 1);
        try coordinator.apply(.{ .publish_summary = .{ .identity = index + 1, .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 1, index + 1) } });
    }
    const targets = [4]*demo.Owner{ &owners[0], &owners[1], &owners[2], &owners[3] };
    const local = fixture.atGroup(46, .{ .identity = 8000, .payload = .{ .safety_gate_change = .{
        .gate_identity = 8000,
        .target_identity = 1,
        .kind = .latched,
        .reason = .market_data,
        .open = false,
    } } });
    var siblings: [3][32]u8 = undefined;
    for (owners[1..], 0..) |*owner, index| siblings[index] = owner.shard.canonicalStateDigest();
    _ = try owners[0].apply(local);
    for (owners[1..], 0..) |*owner, index| try std.testing.expectEqualDeep(siblings[index], owner.shard.canonicalStateDigest());
    try coordinator.apply(.{ .shared_safety = .{ .source = .credential, .version = 1, .open = false } });
    try coordinator.apply(.{ .shared_safety = .{ .source = .gateway, .version = 1, .open = false } });
    for (try coordinator.deliverAccountSafety(targets, 1_460_000_000)) |failure| try std.testing.expect(failure == null);
    for (owners) |*owner| try std.testing.expect(!owner.shard.operational_state.effectiveTradingAuthority());
    // One unavailable Owner cannot prevent the remaining three safety deliveries.
    owners[0].closed = true;
    try coordinator.apply(.{ .shared_safety = .{ .source = .credential, .version = 2, .open = true } });
    const failures = try coordinator.deliverAccountSafety(targets, 1_460_000_000);
    try std.testing.expectEqual(error.DecisionLogUnavailable, failures[0].?);
    for (failures[1..]) |failure| try std.testing.expect(failure == null);
    try coordinator.apply(.{ .shared_safety = .{ .source = .credential, .version = 3, .open = false } });
    const missed_recovery = try coordinator.deliverAccountSafety(targets, 1_460_000_000);
    try std.testing.expectEqual(error.DecisionLogUnavailable, missed_recovery[0].?);
    owners[0].closed = false;
    try coordinator.apply(.{ .shared_safety = .{ .source = .credential, .version = 4, .open = true } });
    try coordinator.apply(.{ .shared_safety = .{ .source = .gateway, .version = 2, .open = true } });
    for (try coordinator.deliverAccountSafety(targets, 1_460_000_000)) |failure| try std.testing.expect(failure == null);
    for (owners) |*owner| try std.testing.expect(!owner.shard.operational_state.trading_authorized);
    try std.testing.expect(!owners[0].shard.operational_state.latches[0].resolved);
    const gateway = try std.testing.allocator.create(execution.Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 9401 });
    try gateway.pinDeploymentDigest(owners[0].shard.deployment.header.?.expected_digest);
    const previous_gate = coordinator.coordinator.shared_safety[0].identity;
    for (owners, 0..) |*owner, index| {
        try command(owner, 8100, .resolve_latch, previous_gate);
        try command(owner, 8101, .resolve_latch, coordinator.coordinator.shared_safety[1].identity);
        if (index != 0) {
            try command(owner, 8102, .enable_trading, 0);
            try std.testing.expect(owner.shard.operational_state.effectiveTradingAuthority());
        }
        try owner.checkpoint();
        _ = try owner.archiveControlHistory(gateway);
    }
    try std.testing.expect(!owners[0].shard.operational_state.effectiveTradingAuthority());
    try coordinator.checkpoint();
    try coordinator.apply(.{ .shared_safety = .{ .source = .credential, .version = 5, .open = false } });
    try std.testing.expectEqual(previous_gate, coordinator.coordinator.shared_safety[0].identity);
    for (try coordinator.deliverAccountSafety(targets, 1_460_000_000)) |failure| try std.testing.expect(failure == null);
    const duplicate_digest = coordinator.coordinator.digest();
    try coordinator.apply(.{ .shared_safety = .{ .source = .credential, .version = 5, .open = false } });
    try std.testing.expectEqualDeep(duplicate_digest, coordinator.coordinator.digest());
    const restored = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(restored);
    for (owners) |*owner| {
        const digest = owner.shard.canonicalStateDigest();
        try demo.Owner.recoverInto(restored, memory.interface(), undefined, owner.stream);
        try std.testing.expectEqualDeep(digest, restored.shard.canonicalStateDigest());
        try std.testing.expectEqualDeep(owner.shard.operational_state, restored.shard.operational_state);
        try std.testing.expectEqual(owner.shard.oms.command_history_count, restored.shard.oms.command_history_count);
        try std.testing.expect(!restored.shard.operational_state.trading_authorized);
    }
    const before = coordinator.coordinator.digest();
    const recovered = try coordination.CoordinatorOwner.recover(coordinator.stream, memory.interface(), undefined);
    try std.testing.expectEqualDeep(before, recovered.coordinator.digest());
    try std.testing.expectError(error.SharedSafetyIdentityConflict, coordinator.apply(.{ .shared_safety = .{ .source = .gateway, .version = 2, .open = false } }));
}

test "06 closed cause cannot be manually resolved and recurring cause relatches" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 9101 });
    try setup.initialize(owner, 0);
    try shared.prepareTrading(owner, 0, 1);
    var gate = fixture.atGroup(46, .{ .identity = 8000, .payload = .{ .safety_gate_change = .{
        .gate_identity = 8000,
        .target_identity = 1,
        .kind = .latched,
        .reason = .identity,
        .open = false,
    } } });
    _ = try owner.apply(gate);
    var resolve = fixture.atGroup(47, .{ .identity = 8001, .payload = .{ .control_command = .{
        .command_identity = 8001,
        .content_hash = 8001,
        .target_identity = 1,
        .expected_version = owner.shard.operational_state.version,
        .expires_at = std.math.maxInt(u64),
        .kind = .resolve_latch,
        .referenced_latch_identity = 8000,
    } } });
    try std.testing.expectError(error.SafetyGateCauseUnresolved, owner.apply(resolve));
    try demo.Owner.recoverInto(owner, memory.interface(), undefined, owner.stream);
    gate.core.payload.safety_gate_change.open = true;
    _ = try owner.apply(gate);
    _ = try owner.apply(resolve);
    try std.testing.expect(!owner.shard.operational_state.trading_authorized);
    gate.core.payload.safety_gate_change.open = false;
    _ = try owner.apply(gate);
    resolve.core.payload.control_command.command_identity = 8002;
    resolve.core.payload.control_command.content_hash = 8002;
    resolve.core.payload.control_command.expected_version = owner.shard.operational_state.version;
    try std.testing.expectError(error.SafetyGateCauseUnresolved, owner.apply(resolve));
    try demo.Owner.recoverInto(owner, memory.interface(), undefined, owner.stream);
    try std.testing.expect(!owner.shard.operational_state.latches[0].resolved);
}
