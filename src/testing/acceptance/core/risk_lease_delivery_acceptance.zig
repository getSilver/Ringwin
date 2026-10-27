const std = @import("std");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const trading = @import("../../../trading/trading_shard.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const domain_fixture = @import("multi_account_authority_acceptance.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");

test "02 configured domain lease delivery retains target binding and independent barrier" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try domain_fixture.initializePythonOwner(owner);
    const shard = &owner.shard;
    const before = shard.authoritativeBarrier();
    const lease: coordination.RiskLease = .{
        .identity = 9,
        .exchange_account = 20,
        .shard_id = .shard_0,
        .decision_domain = 1,
        .version = 2,
        .valid_through_barrier = 4,
        .shard_valid_through_barrier = before + 40,
        .limit_atoms = 50,
        .used_atoms = 0,
        .open = true,
    };
    _ = try owner.apply(.{ .core = try coordination.riskLeaseEventForShard(lease, .shard_0, shard) });
    try std.testing.expectEqual(@as(u64, 2), shard.risk_lease_version);
    try std.testing.expectEqual(@as(i128, 50), shard.risk_lease_atoms);
    try std.testing.expectEqual(before + 40, shard.risk_lease_valid_through_barrier);
    try std.testing.expect(shard.risk_lease_valid_through_barrier > shard.authoritativeBarrier());
    const digest = shard.canonicalStateDigest();
    try std.testing.expectError(error.CrossShardDelivery, coordination.riskLeaseEventForShard(lease, .shard_1, shard));
    var foreign = lease;
    foreign.exchange_account = 999;
    try std.testing.expectError(error.CrossAccountDelivery, coordination.riskLeaseEventForShard(foreign, .shard_0, shard));
    foreign = lease;
    foreign.decision_domain = 2;
    try std.testing.expectError(error.UnverifiedRiskLeaseAllocation, coordination.riskLeaseEventForShard(foreign, .shard_0, shard));
    try std.testing.expectEqualDeep(digest, shard.canonicalStateDigest());
    var secondary = lease;
    secondary.exchange_account = 30;
    secondary.limit_atoms = 35;
    _ = try owner.apply(.{ .core = try coordination.riskLeaseEventForShard(secondary, .shard_0, shard) });
    try std.testing.expectEqual(@as(i128, 35), shard.accountState(30).?.risk_lease_atoms);
    try std.testing.expectEqual(@as(u64, 2), shard.accountState(30).?.risk_lease_version);
    try std.testing.expectEqual(@as(i128, 50), shard.risk_lease_atoms);
    var closed = lease;
    closed.identity = 13;
    closed.version = 3;
    closed.limit_atoms = 0;
    closed.open = false;
    _ = try owner.apply(.{ .core = try coordination.riskLeaseEventForShard(closed, .shard_0, shard) });
    try std.testing.expectEqual(@as(i128, 0), shard.risk_lease_atoms);
    var renewed = lease;
    renewed.identity = 17;
    renewed.version = 4;
    var oversized = renewed;
    oversized.limit_atoms = 61;
    const closed_digest = shard.canonicalStateDigest();
    try std.testing.expectError(error.RiskLeaseOversubscribed, shard.apply(.{ .core = try coordination.riskLeaseEventForShard(oversized, .shard_0, shard) }));
    try std.testing.expectEqualDeep(closed_digest, shard.canonicalStateDigest());
    _ = try owner.apply(.{ .core = try coordination.riskLeaseEventForShard(renewed, .shard_0, shard) });
    try std.testing.expectEqual(@as(i128, 50), shard.risk_lease_atoms);
    try std.testing.expectEqual(@as(i128, 35), shard.accountState(30).?.risk_lease_atoms);
    var increase = renewed;
    increase.identity = 21;
    increase.version = 5;
    increase.limit_atoms = 51;
    const renewed_digest = shard.canonicalStateDigest();
    try std.testing.expectError(error.RiskLeaseOversubscribed, shard.apply(.{ .core = try coordination.riskLeaseEventForShard(increase, .shard_0, shard) }));
    try std.testing.expectEqualDeep(renewed_digest, shard.canonicalStateDigest());
    try owner.checkpoint();
    const restored = try allocator.create(demo.Owner);
    defer allocator.destroy(restored);
    try demo.Owner.recoverInto(restored, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try std.testing.expectEqual(@as(u64, 4), restored.shard.risk_lease_version);
    try std.testing.expectEqual(before + 40, restored.shard.risk_lease_valid_through_barrier);
    try std.testing.expectEqual(@as(i128, 35), restored.shard.accountState(30).?.risk_lease_atoms);
    try std.testing.expect(restored.shard.recovery_admission_pending);
}

const Four = [coordination.max_shards]fixture.LiveRun;

fn publishAll(owner: *coordination.CoordinatorOwner, runs: *const Four) !void {
    for (runs, 0..) |*run, index| {
        const previous = owner.coordinator.summaries[index];
        const version = if (previous.present) previous.value.publication_version + 1 else 1;
        try owner.apply(.{ .publish_summary = .{
            .identity = owner.sequence + 1,
            .summary = try coordination.shardSummaryFromShard(&run.shard, @enumFromInt(index), version, index + 1),
        } });
    }
}

fn deliverAll(owner: *const coordination.CoordinatorOwner, runs: *Four) !void {
    for (owner.coordinator.leases[0..owner.coordinator.lease_count], 0..) |lease, index|
        try coordination.applyRiskLeaseStable(lease, @enumFromInt(index), &runs[index].shard, &runs[index].decision_journal);
}

test "02 four shard lease lifecycle retains reservations gates and replay authority" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const runs = try allocator.create(Four);
    defer allocator.destroy(runs);
    for (runs, 0..) |*run, index| {
        run.* = .{ .shard = .{}, .decision_journal = .init() };
        const authorization: @import("../../../strategy/strategy_host_gateway.zig").Authorization = .{
            .strategy_identity = index + 1,
            .config_version = 1,
            .activation_identity = index + 1,
            .activation_barrier = 0,
        };
        for (fixture.genesisEvents(authorization, .leveraged)) |original| {
            var input = original;
            if (input.core.payload == .virtual_portfolio_activated)
                input.core.payload.virtual_portfolio_activated.portfolio_identity = index + 11;
            _ = try fixture.apply(run, input);
        }
        _ = try fixture.apply(run, fixture.atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{
            .strategy_identity = authorization.strategy_identity,
            .config_version = 1,
            .activation_identity = authorization.activation_identity,
            .session = .{ .fencing = 1, .shard = @intCast(index), .generation = 1 },
            .activation_barrier = 0,
            .state_digest = run.shard.canonicalStateDigest(),
        } } }));
        _ = try fixture.apply(run, fixture.snapshotAt(12, 1));
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
        group.members[0] = .{
            .intent_sequence = 1,
            .strategy_instance = index + 1,
            .operation = .place,
            .instrument = fixture.swap_instrument,
            .quantity = 1,
            .limit_price = fixture.omsPrice(fixture.swap_instrument, fixture.order_limit_price),
        };
        _ = try fixture.apply(run, fixture.atGroup(13, .{ .identity = 1000 + index, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@as(usize, 1), run.shard.oms.emitted().len);
        try std.testing.expect((try run.shard.activeReservationAtoms()) > 0);
    }
    var owner = try coordination.CoordinatorOwner.init(.init(2, 800_000, 800_000), .{ .domain = .control, .id = 88001 }, memory.interface(), undefined);
    try publishAll(&owner, runs);
    try owner.apply(.{ .allocate_leases = .{ .version = 2, .valid_through_barrier = 100 } });
    try deliverAll(&owner, runs);
    const first = owner.coordinator.leases;
    try owner.checkpoint();
    for (runs, 0..) |*run, index| {
        const before = run.shard.canonicalStateDigest();
        const barrier = run.shard.authoritativeBarrier();
        try coordination.applyRiskLeaseStable(first[index], @enumFromInt(index), &run.shard, &run.decision_journal);
        try std.testing.expectEqualDeep(before, run.shard.canonicalStateDigest());
        try std.testing.expectEqual(barrier, run.shard.authoritativeBarrier());
    }
    try owner.apply(.{ .tighten_leases = .{ .valid_through_barrier = 90, .requested_limits = @splat(160_000) } });
    try deliverAll(&owner, runs);
    for (runs, 0..) |*run, index| {
        try std.testing.expectEqual(@as(i128, 160_000), run.shard.risk_lease_atoms);
        const before = run.shard.canonicalStateDigest();
        try std.testing.expectError(error.InvalidRiskLease, coordination.applyRiskLeaseStable(first[index], @enumFromInt(index), &run.shard, &run.decision_journal));
        try std.testing.expectEqualDeep(before, run.shard.canonicalStateDigest());
    }
    try owner.apply(.{ .expire_leases = 91 });
    try deliverAll(&owner, runs);
    for (runs, 0..) |*run, index| {
        try std.testing.expectEqual(@as(i128, 0), run.shard.risk_lease_atoms);
        try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
        try std.testing.expectEqual(try run.shard.activeReservationAtoms(), owner.coordinator.leases[index].used_atoms);
    }
    try publishAll(&owner, runs);
    try owner.apply(.{ .allocate_leases = .{ .version = 5, .valid_through_barrier = 120 } });
    try deliverAll(&owner, runs);
    for (runs) |*run| try std.testing.expectEqual(@as(i128, 200_000), run.shard.risk_lease_atoms);
    try owner.apply(.{ .revoke_leases = 100 });
    try deliverAll(&owner, runs);

    var denied = try coordination.CoordinatorOwner.init(.init(2, 1, 1), .{ .domain = .control, .id = 88002 }, memory.interface(), undefined);
    try publishAll(&denied, runs);
    const before_denial = denied.coordinator.digest();
    try std.testing.expectError(error.AccountSafetyCeilingExceeded, denied.apply(.{ .allocate_leases = .{ .version = 7, .valid_through_barrier = 150 } }));
    try std.testing.expectError(error.AccountSafetyCeilingExceeded, denied.apply(.{ .allocate_leases = .{ .version = 7, .valid_through_barrier = 150 } }));
    try std.testing.expectEqualDeep(before_denial, denied.coordinator.digest());
    const recovered = try coordination.CoordinatorOwner.recover(owner.stream, memory.interface(), undefined);
    try std.testing.expectEqualDeep(owner.coordinator.digest(), recovered.coordinator.digest());
    const initial = try allocator.create(trading.TradingShard);
    defer allocator.destroy(initial);
    initial.* = .{};
    const replayed = try allocator.create(trading.TradingShard);
    defer allocator.destroy(replayed);
    for (runs, 0..) |*run, index| {
        try run.decision_journal.seal();
        _ = try trading.recoverStableInto(replayed, initial, run.decision_journal.bytes());
        try std.testing.expectEqualDeep(run.shard.canonicalStateDigest(), replayed.canonicalStateDigest());
        try std.testing.expectEqual(run.shard.operational_state.mode, replayed.operational_state.mode);
        try std.testing.expectEqual(run.shard.operational_state.trading_authorized, replayed.operational_state.trading_authorized);
        try std.testing.expectEqualDeep(run.shard.operational_state.gates[0..run.shard.operational_state.gate_count], replayed.operational_state.gates[0..replayed.operational_state.gate_count]);
        try std.testing.expectEqualDeep(run.shard.operational_state.latches[0..run.shard.operational_state.latch_count], replayed.operational_state.latches[0..replayed.operational_state.latch_count]);
        try std.testing.expectEqual(@as(u64, 6), replayed.risk_lease_version);
        try std.testing.expectEqual(@as(i128, 0), replayed.risk_lease_atoms);
        try std.testing.expectEqualDeep(
            try coordination.shardSummaryFromShard(&run.shard, @enumFromInt(index), 3, index + 1),
            try coordination.shardSummaryFromShard(replayed, @enumFromInt(index), 3, index + 1),
        );
    }
}
