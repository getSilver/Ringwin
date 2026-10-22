const std = @import("std");
const acceptance = @import("../history/order_gateway_archive_acceptance.zig");
const trading = @import("../../../trading/trading_shard.zig");
const canonical = @import("../../../model/canonical_event.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const history = @import("../../../persistence/business_history.zig");

fn input(sequence: u64, payload: canonical.Payload) trading.CanonicalEvent {
    var event = fixture.canonicalAt(100 + sequence, sequence, payload);
    event.venue.envelope.identity.stream = 88;
    event.venue.envelope.source_stream = 88;
    return event;
}

test "fee adjustment keeps instrument inventory aligned through base charge refund and spot exit" {
    const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, 1782);
    defer harness.destroy();
    var simulator: acceptance.RestingSimulator = .{};
    try harness.bindAdapter(simulator.adapter());
    var original: ?canonical.Fill = null;
    for (0..2) |leg| {
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 101 + leg, .count = 1 };
        group.members[0] = .{ .intent_sequence = 101 + leg, .operation = .place, .instrument = 3, .quantity = 20, .side = if (leg == 0) .buy else .sell, .limit_price = fixture.omsPrice(3, 50_000_000) };
        _ = try harness.owner.apply(fixture.atGroup(20 + leg, .{ .identity = 101 + leg, .payload = .{ .oms_intent_group = group } }));
        const command = harness.owner.shard.oms.emitted()[0];
        const fill: canonical.Fill = .{
            .identity = 8000 + leg,
            .order = command.order_id,
            .client_order_id = command.client_order_id,
            .venue_order = try canonical.VenueOrderRef.init(1, "fee-inventory-order"),
            .venue_trade = try canonical.VenueTradeRef.init(1, if (leg == 0) "entry" else "exit"),
            .instrument = 3,
            .exchange_account = 2,
            .side = if (leg == 0) .buy else .sell,
            .quantity = .{ .instrument = 3, .rules_version = 1, .lots = 20 },
            .price = fixture.omsPrice(3, 50_000_000),
            .fee = .{ .asset = 1, .atoms = 0 },
            .liquidity = .taker,
            .venue_fill_time_utc_ns = fixture.atGroup(101 + leg * 3, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
        };
        var batch: canonical.AdapterOutputBatch = .{};
        try batch.append(input(1 + leg * 3, .{ .fill = fill }).venue);
        try harness.owner.applyAdapterBatch(batch);
        if (leg == 0) {
            original = fill;
            for (0..2) |revision| {
                const origin = harness.owner.shard.economic_projection.feeOrigin(fill.identity).?;
                const source: canonical.RawEvidenceRef = .{ .stream = 88, .sequence = 2 + revision, .digest = history.hash(if (revision == 0) "charge" else "refund") };
                var event = input(2 + revision, .{ .fee_adjustment = .{
                    .original = origin,
                    .identity = 8100 + revision,
                    .fill_identity = fill.identity,
                    .exchange_account = 2,
                    .portfolio = origin.portfolio,
                    .strategy = origin.strategy,
                    .cycle_first_sequence = origin.cycle_first_sequence,
                    .source_version = 1 + revision,
                    .previous_fee_version = revision,
                    .new_fee = .{ .asset = 0x425443, .atoms = if (revision == 0) 1 else 0 },
                    .source = source,
                    .effective_time_utc_ns = input(2 + revision, .{ .economic_fault = .{ .reason = .decoder_rejected } }).venue.envelope.times.source_utc_ns.?,
                } });
                event.venue.envelope.raw_evidence = source;
                batch = .{};
                try batch.append(event.venue);
                try harness.owner.applyAdapterBatch(batch);
                for ([_]@TypeOf(harness.owner.shard.economic_projection.portfolio){ harness.owner.shard.economic_projection.portfolio, harness.owner.shard.economic_projection.exchange }) |layer| {
                    try std.testing.expectEqual(@as(i128, if (revision == 0) 19 else 20), layer.instrumentPosition(3).?.spot_asset_atoms);
                    try std.testing.expectEqual(layer.spotInventoryAtoms(0x425443), layer.instrumentPosition(3).?.spot_asset_atoms);
                }
            }
        }
    }
    for ([_]@TypeOf(harness.owner.shard.economic_projection.portfolio){ harness.owner.shard.economic_projection.portfolio, harness.owner.shard.economic_projection.exchange }) |layer| {
        try std.testing.expectEqual(@as(i64, 0), layer.positionForInstrument(3).quantity);
        try std.testing.expectEqual(@as(i128, 0), layer.instrumentPosition(3).?.spot_asset_atoms);
        try std.testing.expectEqual(@as(i128, 0), layer.spotInventoryAtoms(0x425443));
    }
    try std.testing.expectEqualDeep(original.?, harness.owner.shard.economic_projection.applied_fills[0].source.canonical_fill.?);
    try harness.owner.checkpoint();
}
