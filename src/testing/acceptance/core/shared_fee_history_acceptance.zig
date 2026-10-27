const std = @import("std");
const canonical = @import("../../../model/canonical_event.zig");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const history = @import("../../../persistence/business_history.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const closed_cycle = @import("multi_account_authority_acceptance.zig");
const trading = @import("../../../trading/trading_shard.zig");

fn accountEconomics(shard: *const trading.TradingShard, account: u128) *const trading.economics.Projection {
    if (account == shard.exchange_account_identity) return &shard.economic_projection;
    for (shard.secondary_accounts[0..shard.secondary_account_count]) |*partition| {
        if (partition.identity == account) return &partition.state.economic_projection;
    }
    unreachable;
}

fn failQuery(_: *anyopaque, _: std.Io, _: history.LookupRequest) anyerror!history.LookupResult {
    return error.InjectedHistoryEio;
}

test "03 coordinator verifies a closed cycle fee origin in cold history after recovery" {
    try exerciseColdFee(20);
    try exerciseColdFee(30);
}

fn exerciseColdFee(account: u128) !void {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try closed_cycle.initializeResidualEconomicsOwner(owner);
    try std.testing.expectEqual(@as(u8, 0), owner.shard.cycles.count);
    const original = accountEconomics(&owner.shard, account).feeOrigin(1).?;
    const gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.attachRecoveredDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    _ = try owner.archiveFillHistoryForAccount(account, 1, gateway);
    try std.testing.expect(accountEconomics(&owner.shard, account).feeOrigin(1) == null);
    try owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expect(accountEconomics(&recovered.shard, account).feeOrigin(1) == null);
    var record = fixture.canonicalAt(80, 1, .{ .fee_adjustment = .{
        .identity = 800,
        .original = original,
        .fill_identity = original.original.identity,
        .exchange_account = account,
        .portfolio = original.portfolio,
        .strategy = original.strategy,
        .cycle_first_sequence = original.cycle_first_sequence,
        .source_version = 1,
        .previous_fee_version = 0,
        .new_fee = .{ .asset = original.original.fee.?.asset, .atoms = original.original.fee.?.atoms + 1 },
        .source = .{ .stream = 7, .sequence = 80, .digest = @splat(2) },
        .effective_time_utc_ns = fixture.atGroup(80, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
    } }).venue;
    record.envelope.venue = original.original.venue_trade.venue;
    record.envelope.identity.stream = 71;
    record.envelope.source_stream = 71;
    record.envelope.exchange_account = account;
    record.envelope.instrument = original.original.instrument;
    record.envelope.asset = original.original.fee.?.asset;
    record.envelope.source_fact_identity = 800;
    record.envelope.raw_evidence = record.event.fee_adjustment.source;
    const before = accountEconomics(&recovered.shard, account).semanticDigest();
    const before_cash = accountEconomics(&recovered.shard, account).portfolio.usdt_balance_atoms;
    const other_account: u128 = if (account == 20) 30 else 20;
    const untouched = accountEconomics(&recovered.shard, other_account).semanticDigest();
    const view = try allocator.create(@import("../../../trading/trading_shard.zig").TradingShard);
    defer allocator.destroy(view);
    try recovered.shard.copyAccountViewInto(view, account);
    for ([_]enum { same, conflict, unavailable }{ .conflict, .unavailable, .same }, 0..) |mode, branch| {
        var coordinator = try coordination.CoordinatorOwner.init(.init(account, 100, 100), .{ .domain = .control, .id = 9591 + branch }, memory.interface(), undefined);
        try coordinator.apply(.{ .publish_summary = .{ .identity = 1, .summary = try coordination.shardSummaryFromShard(view, .shard_0, 1, 1) } });
        try coordinator.checkpoint();
        var candidate = record;
        var failing = memory.interface().vtable.*;
        failing.query_order_history = failQuery;
        if (mode == .conflict) candidate.event.fee_adjustment.original.?.original.price.ticks += 1;
        if (mode == .unavailable) {
            recovered.store = .{ .context = memory, .vtable = &failing };
            try std.testing.expectError(error.InjectedHistoryEio, coordinator.acceptVenueFactFromOwners(candidate, .{ recovered, recovered, recovered, recovered }));
            recovered.store = memory.interface();
            try std.testing.expect(coordinator.closed);
        } else {
            try coordinator.acceptVenueFactFromOwners(candidate, .{ recovered, recovered, recovered, recovered });
            if (mode == .same) {
                try std.testing.expectEqualDeep(candidate, (try coordinator.pendingVenueFact(.shard_0)).?);
            } else {
                var suspense: [1]canonical.EventRecord = undefined;
                try std.testing.expectEqualDeep(candidate, (try coordinator.venueSuspense(&suspense))[0]);
            }
            try coordinator.checkpoint();
        }
        var restored = try coordination.CoordinatorOwner.recover(coordinator.stream, memory.interface(), undefined);
        if (mode == .same) try std.testing.expectEqualDeep(candidate, (try restored.pendingVenueFact(.shard_0)).?) else try std.testing.expect(restored.coordinator.margin_gate.latched);
        try std.testing.expectEqualDeep(before, accountEconomics(&recovered.shard, account).semanticDigest());
        if (mode == .same) {
            try std.testing.expect(try restored.deliverVenueFact(.shard_0, recovered));
            try std.testing.expectEqual(before_cash - 1, accountEconomics(&recovered.shard, account).portfolio.usdt_balance_atoms);
            const applied = recovered.shard.canonicalStateDigest();
            try restored.acceptVenueFactFromOwners(candidate, .{ recovered, recovered, recovered, recovered });
            try std.testing.expect(!try restored.deliverVenueFact(.shard_0, recovered));
            try std.testing.expectEqualDeep(applied, recovered.shard.canonicalStateDigest());
            try std.testing.expectEqualDeep(untouched, accountEconomics(&recovered.shard, other_account).semanticDigest());
        }
    }
}
