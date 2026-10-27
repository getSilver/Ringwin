const std = @import("std");
const fixtures = @import("../core/multi_account_authority_acceptance.zig");
const trading = @import("../../../trading/trading_shard.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const history = @import("../../../persistence/business_history.zig");

test "owned residual fee charge and refund restore the original consumption without changing Fill ownership" {
    try exerciseFeeRefund(false);
    try exerciseFeeRefund(true);
}

fn exerciseFeeRefund(frozen: bool) !void {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try fixtures.initializeResidualEconomicsOwner(owner);
    if (frozen) {
        const live = owner.shard.cycles.residual_lifecycle.find(9, 3, 0).?;
        _ = try owner.apply(fixture.atGroup(62, .{ .identity = 83001, .payload = .{ .control_command = .{
            .command_identity = 83001,
            .content_hash = 83001,
            .target_identity = owner.shard.operational_state.target_identity,
            .expected_version = owner.shard.operational_state.version,
            .expires_at = std.math.maxInt(u64),
            .kind = .freeze_residual,
            .residual = .{ .strategy = 9, .first_sequence = 3, .member = 0, .expected_version = live.version, .original_fact = live.original_fact, .atoms = 1 },
        } } }));
    }
    const original = owner.shard.economic_projection.feeOrigin(1).?;
    const gateway = try allocator.create(@import("../../../execution/execution_gateway.zig").Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.attachRecoveredDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    _ = try owner.archiveFillHistory(1, gateway);
    try std.testing.expect(owner.shard.economic_projection.feeOrigin(1) == null);
    const unrelated = owner.shard.accountState(30).?.economic_projection.semanticDigest();
    for (0..3) |revision| {
        const source: trading.canonical.RawEvidenceRef = .{ .stream = 98, .sequence = revision + 1, .digest = history.hash(if (revision == 0) "residual-charge" else "residual-refund") };
        var input = fixture.canonicalAt(62 + revision, revision + 1, .{ .fee_adjustment = .{
            .original = original,
            .identity = 9900 + revision,
            .fill_identity = 1,
            .exchange_account = 20,
            .portfolio = 10,
            .strategy = 9,
            .cycle_first_sequence = 3,
            .source_version = revision + 1,
            .previous_fee_version = revision,
            .new_fee = .{ .asset = 0x425443, .atoms = if (revision < 2) 1 else 0 },
            .source = source,
            .effective_time_utc_ns = fixture.atGroup(62 + revision, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
        } });
        input.venue.envelope.exchange_account = 20;
        input.venue.envelope.identity.stream = 98;
        input.venue.envelope.source_stream = 98;
        input.venue.envelope.raw_evidence = source;
        var batch: trading.canonical.AdapterOutputBatch = .{};
        try batch.append(input.venue);
        try owner.applyAdapterBatch(batch);
        const expected: i128 = if (revision < 2) 0 else 1;
        try std.testing.expectEqual(expected, try owner.shard.cycles.residual_lifecycle.outstandingAtoms(20, 10, 0x425443));
        try std.testing.expectEqual(expected, owner.shard.economic_projection.portfolio.spotInventoryAtoms(0x425443));
        try std.testing.expectEqual(expected, owner.shard.economic_projection.portfolio.instrumentPosition(101).?.spot_asset_atoms);
        try std.testing.expectEqual(frozen, owner.shard.oms.recovery_only);
        try std.testing.expectEqualDeep(original, owner.shard.economic_projection.feeOrigin(1).?);
        const digest = owner.shard.economic_projection.semanticDigest();
        try owner.applyAdapterBatch(batch);
        try std.testing.expectEqualSlices(u8, &digest, &owner.shard.economic_projection.semanticDigest());
    }
    try std.testing.expectEqualSlices(u8, &unrelated, &owner.shard.accountState(30).?.economic_projection.semanticDigest());
    try owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
}

test "owned residual finer lot sale keeps real Fill quantity without creating gross short or duplicated inventory" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try fixtures.initializeResidualEconomicsOwner(owner);
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 21001, .count = 2 };
    group.members[0] = .{ .portfolio = 10, .intent_sequence = 21001, .strategy_instance = 9, .exchange_account = 20, .instrument = 103, .operation = .place, .side = .sell, .quantity = 1, .limit_price = .{ .instrument = 103, .rules_version = 1, .ticks = 100000000 } };
    group.members[1] = .{ .portfolio = 10, .intent_sequence = 21002, .strategy_instance = 9, .exchange_account = 30, .instrument = 102, .operation = .place, .quantity = 10000, .limit_price = .{ .instrument = 102, .rules_version = 1, .ticks = 10 } };
    _ = try owner.apply(fixture.atGroup(62, .{ .identity = 21001, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.none, owner.shard.last_reject_reason);
    try std.testing.expectEqual(@as(u16, 6), owner.shard.oms.order_count);
    const order = owner.shard.oms.orderById(5).?;
    const cash = owner.shard.economic_projection.portfolio.usdt_balance_atoms;
    const pnl = owner.shard.economic_projection.portfolio.realized_pnl_atoms;
    const rebate = owner.shard.economic_projection.portfolio.instrumentPosition(101).?.base_rebate_atoms;
    var fill = fixture.canonicalAt(63, 1, .{ .fill = .{
        .identity = 5,
        .order = 5,
        .client_order_id = order.client_order_id,
        .venue_order = try trading.canonical.VenueOrderRef.init(1, "residual-sale"),
        .venue_trade = try trading.canonical.VenueTradeRef.init(1, "residual-sale-fill"),
        .instrument = 103,
        .exchange_account = 20,
        .side = .sell,
        .quantity = .{ .instrument = 103, .rules_version = 1, .lots = 1 },
        .price = .{ .instrument = 103, .rules_version = 1, .ticks = 100000000 },
        .fee = .{ .asset = 1, .atoms = 0 },
        .liquidity = .taker,
        .venue_fill_time_utc_ns = fixture.atGroup(63, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
    } });
    fill.venue.envelope.identity.stream = 99;
    fill.venue.envelope.source_stream = 99;
    fill.venue.envelope.exchange_account = 20;
    var batch: trading.canonical.AdapterOutputBatch = .{};
    try batch.append(fill.venue);
    try owner.applyAdapterBatch(batch);
    for ([_]@TypeOf(owner.shard.economic_projection.portfolio){ owner.shard.economic_projection.portfolio, owner.shard.economic_projection.exchange }) |layer| {
        try std.testing.expectEqual(@as(i64, 0), layer.positionForInstrument(103).quantity);
        try std.testing.expectEqual(@as(i128, 0), layer.positionForInstrument(103).open_cost_atoms);
        try std.testing.expectEqual(@as(i128, 0), layer.spotInventoryAtoms(0x425443));
        try std.testing.expectEqual(@as(i128, 0), layer.instrumentPosition(101).?.spot_asset_atoms);
        try std.testing.expectEqual(@as(i128, 0), layer.instrumentPosition(103).?.spot_asset_atoms);
    }
    try std.testing.expectEqual(cash + 1, owner.shard.economic_projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(pnl + 1, owner.shard.economic_projection.portfolio.realized_pnl_atoms);
    try std.testing.expectEqual(rebate, owner.shard.economic_projection.portfolio.instrumentPosition(101).?.base_rebate_atoms);
    try std.testing.expectEqual(@as(i64, 1), try owner.shard.economic_projection.appliedCanonicalFillQuantity(5));
    try std.testing.expectEqual(@as(i64, 0), owner.shard.oms.orderById(5).?.cumulative_quantity);
    const before = owner.shard.economic_projection.semanticDigest();
    try owner.applyAdapterBatch(batch);
    try std.testing.expectEqualSlices(u8, &before, &owner.shard.economic_projection.semanticDigest());
    try owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
}

test "owned residual pre carry fee refund creates original cycle credit without rewriting acceptance" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try fixtures.initializeResidualCreditEconomicsOwner(owner);
    const original = owner.shard.economic_projection.feeOrigin(1).?;
    const gateway = try allocator.create(@import("../../../execution/execution_gateway.zig").Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.attachRecoveredDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    _ = try owner.archiveFillHistory(1, gateway);
    try std.testing.expect(owner.shard.economic_projection.feeOrigin(1) == null);
    const unrelated = owner.shard.accountState(30).?.economic_projection.semanticDigest();
    for (0..1) |revision| {
        const source: trading.canonical.RawEvidenceRef = .{ .stream = 98, .sequence = revision + 1, .digest = history.hash(if (revision == 0) "residual-charge" else "residual-refund") };
        var input = fixture.canonicalAt(62 + revision, revision + 1, .{ .fee_adjustment = .{
            .original = original,
            .identity = 9900 + revision,
            .fill_identity = 1,
            .exchange_account = 20,
            .portfolio = 10,
            .strategy = 9,
            .cycle_first_sequence = 3,
            .source_version = revision + 1,
            .previous_fee_version = revision,
            .new_fee = .{ .asset = 0x425443, .atoms = 0 },
            .source = source,
            .effective_time_utc_ns = fixture.atGroup(62 + revision, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
        } });
        input.venue.envelope.exchange_account = 20;
        input.venue.envelope.identity.stream = 98;
        input.venue.envelope.source_stream = 98;
        input.venue.envelope.raw_evidence = source;
        var batch: trading.canonical.AdapterOutputBatch = .{};
        try batch.append(input.venue);
        try owner.applyAdapterBatch(batch);
        const expected: i128 = 2;
        try std.testing.expectEqual(expected, try owner.shard.cycles.residual_lifecycle.outstandingAtoms(20, 10, 0x425443));
        try std.testing.expectEqual(expected, owner.shard.economic_projection.portfolio.spotInventoryAtoms(0x425443));
        try std.testing.expectEqual(expected, owner.shard.economic_projection.portfolio.instrumentPosition(101).?.spot_asset_atoms);
        try std.testing.expect(!owner.shard.oms.recovery_only);
        try std.testing.expectEqual(@as(i128, 1), owner.shard.cycles.residual_lifecycle.find(9, 3, 0).?.credited_atoms);
        try std.testing.expectEqual(@as(i128, 1), owner.shard.cycles.closed[0].proof.residuals[0].?.atoms);
        try std.testing.expectEqualDeep(original, owner.shard.economic_projection.feeOrigin(1).?);
        const digest = owner.shard.economic_projection.semanticDigest();
        try owner.applyAdapterBatch(batch);
        try std.testing.expectEqualSlices(u8, &digest, &owner.shard.economic_projection.semanticDigest());
    }
    try std.testing.expectEqualSlices(u8, &unrelated, &owner.shard.accountState(30).?.economic_projection.semanticDigest());
    try owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
}
