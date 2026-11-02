//! Offline public feed -> TradingShard -> Host and durable recovery acceptance.
const std = @import("std");
const feed_module = @import("../../../adapters/hyperliquid/hyperliquid_market_feed.zig");
const c = @import("../../../model/canonical_event.zig");
const engine = @import("../../../trading/trading_shard.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const host = @import("../../../strategy/strategy_host_gateway.zig");
const depth = @import("../../../market/depth_snapshot.zig");
const Sink = struct {
    count: u64 = 0,
    fn append(ptr: *anyopaque, _: feed_module.RawRecord, _: []const u8) feed_module.RawError!u64 {
        const self: *Sink = @ptrCast(@alignCast(ptr));
        self.count += 1;
        return self.count;
    }
};

test "Hyperliquid public core application and snapshot tail recovery preserve Host depth and tape" {
    const allocator = std.testing.allocator;
    const live = try allocator.create(engine.TradingShard);
    defer allocator.destroy(live);
    live.* = .{};
    const initial = try allocator.create(engine.TradingShard);
    defer allocator.destroy(initial);
    initial.* = .{};
    const recovered = try allocator.create(engine.TradingShard);
    defer allocator.destroy(recovered);
    var log = engine.journal.Journal.init();
    for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged)) |event|
        _ = try engine.applyStable(live, &log, event);
    var sink: Sink = .{};
    var feed = feed_module.HyperliquidMarketFeed.init(.{ .instrument = 3, .coin = "BTC", .product = .isolated_linear, .universe_index = 0, .size_decimals = 0, .rules_version = 1, .expected_metadata_digest = .{ 0x57, 0xad, 0x35, 0xcf, 0x0c, 0xda, 0xe7, 0xc2, 0xf4, 0x54, 0xb3, 0x50, 0xc9, 0xa2, 0xb0, 0x5e, 0x89, 0xe2, 0x1b, 0xeb, 0xd3, 0xc3, 0x7b, 0x3a, 0xb9, 0x9c, 0x80, 0x77, 0xb8, 0x43, 0xc2, 0x09 }, .price_scale = 6, .tick_atoms = 1, .quantity_scale = 4, .lot_atoms = 1 }, .{ .ptr = &sink, .append_fn = Sink.append }, 0);
    const adapter = feed.adapter();
    try adapter.start(.{ .venue = 1, .environment = .demo, .subscription_set = 70, .session = 60, .config_version = 1, .output_capacity = 32 });
    const times: feed_module.Times = .{ .receive_time_utc_ns = 1_000_000_000_000, .monotonic_time_ns = 2_000_000_000, .wall_time_utc_ns = 1_000_000_000_000 };
    const inputs = [_]struct { epoch: u64, kind: feed_module.Input, bytes: []const u8 }{
        .{ .epoch = 0, .kind = .metadata, .bytes = "{\"collateralToken\":0,\"universe\":[{\"name\":\"BTC\",\"szDecimals\":0,\"maxLeverage\":40,\"marginTableId\":54}],\"marginTables\":[[54,{\"marginTiers\":[{\"lowerBound\":\"0\",\"maxLeverage\":40}]}]]}" },
        .{ .epoch = 1, .kind = .subscribe, .bytes = "subscribe" },
        .{ .epoch = 1, .kind = .book, .bytes = "{\"coin\":\"BTC\",\"time\":1000000,\"levels\":[[{\"px\":\"49999\",\"sz\":\"2\",\"n\":1}],[{\"px\":\"50000\",\"sz\":\"3\",\"n\":1},{\"px\":\"50001\",\"sz\":\"4\",\"n\":1}]]}" },
        .{ .epoch = 1, .kind = .trades, .bytes = "[{\"coin\":\"BTC\",\"time\":1000000,\"tid\":7,\"side\":\"B\",\"px\":\"50000\",\"sz\":\"2\"}]" },
    };
    var tape: c.EventRecord = undefined;
    for (inputs) |input| {
        try feed.ingest(allocator, input.epoch, input.kind, times, input.bytes);
        const batch = (try adapter.tryDrain()).?;
        for (batch.slice()) |record| {
            _ = try engine.applyStable(live, &log, .{ .venue = record });
            if (record.event == .market_trade) tape = record;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), live.oms.order_count);
    try std.testing.expectEqual(@as(i128, 0), live.economic_projection.portfolio.fee_atoms);
    try std.testing.expectEqual(@as(i128, 20_000), tape.event.market_trade.quantity.lots);
    try std.testing.expectEqual(@as(i128, 20_000), live.canonical_market.get(3).?.last_book.?.best_bid_quantity.?.lots);
    var invalid = tape;
    invalid.envelope.identity.sequence = 500;
    invalid.envelope.source_sequence = 500;
    invalid.event.market_trade.trade_identity += 1;
    invalid.envelope.source_fact_identity = invalid.event.market_trade.trade_identity;
    invalid.event.market_trade.price.rules_version = 2;
    invalid.event.market_trade.quantity.rules_version = 2;
    try std.testing.expectError(error.InstrumentRulesInactive, engine.applyStable(live, &log, .{ .venue = invalid }));
    invalid.event.market_trade.price.rules_version = 1;
    invalid.event.market_trade.quantity.rules_version = 1;
    invalid.envelope.scope = .account;
    try std.testing.expectError(error.CanonicalScopeMismatch, engine.applyStable(live, &log, .{ .venue = invalid }));
    var wire: [depth.wire_len]u8 = undefined;
    const book_input = try host.depthSnapshotInput(&live.canonical_market, 3, live.authoritativeBarrier(), &wire, 2_000_000_000, 1_000_000_000_000);
    var before: [depth.wire_len]u8 = undefined;
    @memcpy(&before, book_input.payload);
    var tape_wire: [96]u8 = undefined;
    const trade_input = try host.marketTradeInput(tape, live.authoritativeBarrier() + 1, &tape_wire);
    var gateway = try host.Gateway.init(.{ .schema_registry = 50, .decision_domain = 1, .session = .{ .fencing = 1, .shard = 0, .generation = 1 }, .authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 } }, &.{host.Subscription.of(1, &.{ .depth_snapshot, .market_trade })});
    var batch_wire: [2048]u8 = undefined;
    const host_batch = try gateway.encodeBatch(&batch_wire, 1, live.authoritativeBarrier(), live.authoritativeBarrier() + 1, 100, &.{ book_input, trade_input });
    const ipc = @import("../../../strategy/strategy_host_ipc.zig");
    try std.testing.expectEqual(ipc.QshStatusV1.ok, ipc.validateBatchAt(host_batch, gateway.config.session, 1, null, 101).status);
    try log.seal();
    const storage = try allocator.alloc(u8, @import("../../../persistence/durable_store.zig").max_snapshot_bytes);
    defer allocator.free(storage);
    const encoded = try live.snapshot(&log, live.authoritativeBarrier(), storage);
    _ = try engine.TradingShard.restoreSnapshotInto(recovered, encoded);
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &recovered.canonicalStateDigest());
    _ = try engine.recoverStableInto(recovered, initial, log.bytes());
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &recovered.canonicalStateDigest());
    const recovered_input = try host.depthSnapshotInput(&recovered.canonical_market, 3, recovered.authoritativeBarrier(), &wire, 2_000_000_000, 1_000_000_000_000);
    try std.testing.expectEqualSlices(u8, &before, recovered_input.payload);

    var tail = engine.journal.Journal.initAt(live.authoritativeBarrier() + 1);
    try feed.ingest(allocator, 1, .disconnected, times, "disconnected");
    const disconnected = (try adapter.tryDrain()).?;
    _ = try engine.applyStable(live, &tail, .{ .venue = disconnected.events[0] });
    try std.testing.expectError(error.MarketGap, host.depthSnapshotInput(&live.canonical_market, 3, live.authoritativeBarrier(), &wire, 200, 1000));
    try feed.ingest(allocator, 2, .subscribe, times, "subscribe");
    _ = try engine.applyStable(live, &tail, .{ .venue = (try adapter.tryDrain()).?.events[0] });
    try feed.ingest(allocator, 2, .book, times, inputs[2].bytes);
    _ = try engine.applyStable(live, &tail, .{ .venue = (try adapter.tryDrain()).?.events[0] });
    try tail.seal();
    _ = try engine.TradingShard.restoreSegmentsInto(recovered, encoded, &.{tail.bytes()});
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &recovered.canonicalStateDigest());
}
