//! Native economic contract through the real SimulatedVenue public seam.
//! Genesis is a core fixture, not independent Venue account qualification.
const std = @import("std");
const canonical = @import("../../../model/canonical_event.zig");
const durable = @import("../../../persistence/durable_store.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const simulated = @import("../../../adapters/simulated/simulated_venue.zig");
const venue = @import("../../../execution/venue_adapter.zig");

const Case = enum { quote, base, third, zero, unknown, overflow, conflict };
const third_asset = 0x424e42;

fn exercise(case: Case) !void {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    const assets = @import("../../../trading/asset_registry.zig").testDefinitions(12, 9);
    for (assets) |definition| _ = try owner.apply(.{ .core = .{ .identity = definition.asset, .payload = .{ .asset_definition_activated = definition } } });
    var third = assets[0];
    third.asset = third_asset;
    third.source_identity = third_asset;
    for (third.code_bindings[0..third.code_binding_count]) |*code| code.* = try canonical.AssetCodeBinding.init(code.venue, "BNB");
    _ = try owner.apply(.{ .core = .{ .identity = third_asset, .payload = .{ .asset_definition_activated = third } } });
    for (fixture.genesisEvents(.{ .strategy_identity = 40, .config_version = 1, .activation_identity = 50, .activation_barrier = 1 }, .cash)) |original| {
        var event = original;
        switch (event.core.payload) {
            .instrument_rules_activated => |*rules| {
                if (rules.instrument_identity == fixture.spot_instrument) continue;
                rules.quantity_denominator = 10_000_000;
                rules.quantity_numerator = 2;
            },
            .margin_rules_activated => |*margin| {
                if (margin.instrument == fixture.spot_instrument) continue;
                margin.native_settlement_atoms = true;
                margin.price_tick_atoms = 250_000_000_000;
            },
            .mark_price => |*mark| {
                if (mark.instrument == fixture.spot_instrument) continue;
                mark.price_atoms = 50_000_000_000_000_000;
            },
            .instrument_trading_authorization => |authorization| {
                if (authorization.instrument == fixture.spot_instrument) continue;
            },
            .asset_definition_activated => |*definition| definition.* = if (definition.asset == 1) assets[0] else assets[1],
            .exchange_balance => |*balance| balance.cash_atoms = 100_000_000_000_000,
            .opening_balance => |*balance| balance.cash_atoms = 100_000_000_000_000,
            .portfolio_transfer => |*transfer| transfer.amount_atoms = 90_000_000_000_000,
            .risk_lease_granted => |*lease| lease.amount_atoms = 80_000_000_000_000,
            else => {},
        }
        _ = try owner.apply(event);
    }
    var book = fixture.canonicalAt(18, 1, .{ .l2_book_snapshot = .{ .instrument = 3, .sequence = 1, .best_bid = .{ .instrument = 3, .rules_version = 1, .ticks = 199_999 }, .best_ask = .{ .instrument = 3, .rules_version = 1, .ticks = 200_000 }, .best_bid_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 100 }, .best_ask_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 100 } } });
    book.venue.envelope.identity.stream = 999;
    book.venue.envelope.source_stream = 999;
    _ = try owner.apply(book);
    var group: @import("../../../execution/oms.zig").IntentGroup = .{ .first_intent_sequence = 90, .count = 1 };
    group.members[0] = .{ .intent_sequence = 90, .operation = .place, .instrument = 3, .side = .buy, .quantity = 4, .limit_price = .{ .instrument = 3, .rules_version = 1, .ticks = 200_000 } };
    _ = try owner.apply(.{ .core = .{ .identity = 90, .payload = .{ .oms_intent_group = group } } });
    try std.testing.expectEqual(@as(u8, 1), owner.shard.oms.command_history_count);
    const command = owner.shard.oms.command_history[0];
    try std.testing.expectEqual(command.order_id, command.command_id);
    try owner.sealBootstrap();
    var implementation: simulated.SimulatedVenue = .{};
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry, .native_settlement_atoms = true });
    const fee_asset: canonical.AssetIdentity = switch (case) {
        .base => assets[1].asset,
        .third => third_asset,
        .unknown => 999,
        else => 1,
    };
    var request: canonical.AdapterRequest = .{ .order_command = .{ .identity = command.order_id, .exchange_account = 2, .instrument = 3, .client_order_id = command.client_order_id, .capability_version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .dispatch_deadline_monotonic_ns = 100, .quantity = .{ .instrument = 3, .rules_version = 1, .lots = 4 }, .limit_price = .{ .instrument = 3, .rules_version = 1, .ticks = 200_000 }, .fee_asset = fee_asset, .fee_atoms = if (case == .zero) 0 else if (case == .third) 1 else if (case == .overflow) 2_000_000_000_000_002 else 3, .rebate_asset = fee_asset, .rebate_atoms = if (case == .unknown or case == .overflow or case == .zero) 0 else if (case == .third) 3 else 1 } };
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(request));
    try std.testing.expectEqual(venue.SendResult.backpressure, try adapter.trySend(request));
    const batch = (try adapter.tryDrain()).?;
    try @import("../../contracts/venue_adapter_contract.zig").exerciseFillRecovery(batch.slice(), .{ .venue = 1, .exchange_account = 2, .adapter_session = 1 });
    const before = owner.shard.economicSummary();
    const failure = case == .unknown or case == .overflow;
    if (failure) {
        try std.testing.expectError(if (case == .unknown) error.UnknownAssetDefinition else error.AssetAmountOutOfRange, owner.applyAdapterBatch(batch));
        try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
        try std.testing.expectEqual(@as(u64, 1), owner.shard.economic_fault_count);
        try std.testing.expect(owner.shard.oms.recovery_only);
    } else {
        try owner.applyAdapterBatch(batch);
        const summary = owner.shard.economicSummary();
        try std.testing.expectEqual(@as(i128, if (case == .quote or case == .conflict) 89_959_999_999_998 else 89_960_000_000_000), summary.portfolio.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, if (case == .quote or case == .conflict) 99_959_999_999_998 else 99_960_000_000_000), summary.exchange.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, if (case == .base) 798 else 800), summary.exchange.spot_asset_atoms);
        try std.testing.expectEqual(@as(i128, 40_000_000_000), summary.portfolio.spot.open_cost_atoms);
        try std.testing.expectEqual(@as(i128, if (case == .quote or case == .conflict) 3 else 0), summary.portfolio.fee_atoms);
        try std.testing.expectEqual(@as(i128, if (case == .quote or case == .conflict) 1 else 0), summary.portfolio.rebate_atoms);
        try std.testing.expectEqual(@as(i128, if (case == .base) 3 else 0), summary.portfolio.base_fee_atoms);
        try std.testing.expectEqual(@as(i128, if (case == .base) 1 else 0), summary.portfolio.base_rebate_atoms);
        try std.testing.expectEqual(@as(i128, 4), try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
        try std.testing.expectEqual(@as(i64, 4), owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
        if (case == .third) {
            const balance = owner.shard.economic_projection.portfolio.nativeAsset(third_asset).?;
            try std.testing.expectEqual(@as(i128, 2), balance.balance_atoms);
            try std.testing.expectEqual(@as(i128, 1), balance.fee_atoms);
            try std.testing.expectEqual(@as(i128, 3), balance.rebate_atoms);
            try std.testing.expectEqual(@as(i128, 2), owner.shard.economic_projection.exchange.nativeAsset(third_asset).?.balance_atoms);
            try std.testing.expect(!summary.valuation_complete);
        }
        const once = owner.shard.canonicalStateDigest();
        for (batch.slice()) |record| {
            if (record.event == .fill) _ = try owner.apply(.{ .venue = record });
        }
        try std.testing.expectEqualSlices(u8, &once, &owner.shard.canonicalStateDigest());
        if (case == .conflict) {
            request.order_command.fee_atoms = 5;
            try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(request));
            const conflicting = (try adapter.tryDrain()).?;
            for (conflicting.slice()) |record| {
                if (record.event != .fill) continue;
                try std.testing.expectError(error.ConflictingFillIdentity, owner.apply(.{ .venue = record }));
                break;
            }
            try std.testing.expectEqualDeep(summary, owner.shard.economicSummary());
            try std.testing.expectEqual(@as(u64, 1), owner.shard.economic_fault_count);
            try std.testing.expect(owner.shard.oms.recovery_only);
        }
    }
    try owner.shard.assertClosures();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    const storage = try allocator.alloc(u8, durable.max_snapshot_bytes);
    defer allocator.free(storage);
    const restored = try allocator.create(@import("../../../trading/trading_shard.zig").TradingShard);
    defer allocator.destroy(restored);
    _ = try @import("../../../trading/trading_shard.zig").TradingShard.restoreSnapshotInto(restored, try owner.committedSnapshot(storage));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.canonicalStateDigest());
    try std.testing.expect((try adapter.tryDrain()) == null);
    if (failure or case == .conflict) try std.testing.expect(recovered.shard.oms.recovery_only);
    try adapter.stop(.{ .monotonic_ns = 100 });
}

test "Simulated native public Owner contract preserves split microfees rebates nonunit quantity and replay" {
    for ([_]Case{ .quote, .base, .third, .zero }) |case| try exercise(case);
}

test "Simulated native public Owner contract persists unknown asset and amount range faults" {
    for ([_]Case{ .unknown, .overflow, .conflict }) |case| try exercise(case);
}
