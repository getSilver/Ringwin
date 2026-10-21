//! OKX public-market implementation of the shared MarketFeedAdapter seam.
//!
//! `okx_public_market` deliberately owns the Venue protocol. This module owns
//! only the one-way translation from those private facts into shared values.

const std = @import("std");
const canonical = @import("../../model/canonical_event.zig");
const market = @import("../../market/market_feed_adapter.zig");
const okx = @import("okx_public_market.zig");

pub const btc_usdt_spot: canonical.InstrumentIdentity = 0x4f4b58_00000001;
pub const btc_usdt_swap: canonical.InstrumentIdentity = 0x4f4b58_00000002;

const State = enum { idle, running, stopped };
const Rules = struct {
    tick_size: okx.Decimal,
    lot_size: okx.Decimal,
    version: u64,
};
const BookState = struct {
    ready: bool = false,
    depth: ?canonical.BookDepth = null,
};

pub const OkxMarketFeed = struct {
    decoder: okx.Decoder = .{},
    raw_sink: okx.RawSink,
    state: State = .idle,
    config: ?market.Config = null,
    pending: ?canonical.AdapterOutputBatch = null,
    next_event_sequence: u64 = 0,
    rules: [2]?Rules = .{ null, null },
    books: [2]BookState = .{ undefined, undefined },

    pub fn init(raw_sink: okx.RawSink) OkxMarketFeed {
        return .{ .raw_sink = raw_sink };
    }

    pub fn adapter(self: *OkxMarketFeed) market.MarketFeedAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_drain = drain, .stop = stop } };
    }

    /// Appends a complete REST or WebSocket data frame before decoding it.
    pub fn ingest(self: *OkxMarketFeed, allocator: std.mem.Allocator, times: okx.Times, raw: []const u8) !void {
        try self.requireRunning();
        if (self.pending != null) return error.OutputPending;
        const ingress = try self.decoder.ingest(allocator, self.raw_sink, try self.sourceSession(), times, raw);
        try self.stage(ingress);
    }

    pub fn replay(self: *OkxMarketFeed, allocator: std.mem.Allocator, source_session: u64, times: okx.Times, evidence: okx.RawEvidenceRef, raw: []const u8) !void {
        try self.requireRunning();
        if (self.pending != null) return error.OutputPending;
        if (source_session != try self.sourceSession()) return error.SourceSessionMismatch;
        const ingress = try self.decoder.replay(allocator, times, evidence, raw);
        try self.stage(ingress);
    }

    fn stage(self: *OkxMarketFeed, ingress: okx.IngressBatch) !void {
        var output: canonical.AdapterOutputBatch = .{};
        for (ingress.eventSlice()) |event| {
            self.translate(&output, event) catch |err| {
                if (event.payload == .l2_book_snapshot or event.payload == .l2_book_delta) {
                    const instrument = if (event.payload == .l2_book_snapshot) event.payload.l2_book_snapshot.instrument else event.payload.l2_book_delta.instrument;
                    self.books[@intFromEnum(instrument)].ready = false;
                    var failed: canonical.AdapterOutputBatch = .{};
                    try self.append(&failed, event.envelope, instrumentIdentity(instrument), event.envelope.raw_evidence.stream_sequence, null, .{ .market_data_health_changed = .{ .instrument = instrumentIdentity(instrument), .health = .gap } });
                    self.pending = failed;
                }
                return err;
            };
        }
        if (output.len != 0) self.pending = output;
    }

    /// The caller supplies the actual subscription acknowledgement/control
    /// frame, so the reset health fact has genuine RawIngress evidence too.
    pub fn beginSubscription(self: *OkxMarketFeed, instrument: okx.Instrument, times: okx.Times, raw: []const u8) !void {
        try self.requireRunning();
        if (self.pending != null) return error.OutputPending;
        if (raw.len > okx.max_raw_frame_bytes or raw.len > std.math.maxInt(u32)) return error.FrameTooLarge;

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
        const evidence = try self.raw_sink.append(.{
            .source_session = try self.sourceSession(),
            .receive_time_utc_ns = times.receive_time_utc_ns,
            .monotonic_time_ns = times.monotonic_time_ns,
            .wall_time_utc_ns = times.wall_time_utc_ns,
            .byte_len = @intCast(raw.len),
            .sha256 = digest,
        }, raw);
        const reset = self.decoder.beginSubscription(instrument);
        self.books[@intFromEnum(instrument)].ready = false;
        var output: canonical.AdapterOutputBatch = .{};
        try self.append(
            &output,
            .{ .source_time_utc_ns = null, .receive_time_utc_ns = times.receive_time_utc_ns, .monotonic_time_ns = times.monotonic_time_ns, .wall_time_utc_ns = times.wall_time_utc_ns, .raw_evidence = evidence, .source_fact_identity = digest },
            instrumentIdentity(instrument),
            evidence.stream_sequence,
            null,
            .{ .market_data_health_changed = .{ .instrument = instrumentIdentity(instrument), .health = health(reset.health) } },
        );
        self.pending = output;
    }

    fn start(ptr: *anyopaque, config: market.Config) market.StartError!void {
        const self: *OkxMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.environment != .demo or config.venue == 0 or config.subscription_set == 0 or config.session == 0 or
            config.session > std.math.maxInt(u64) or config.output_capacity < okx.max_events_per_ingress or
            config.output_capacity > canonical.max_events_per_adapter_batch)
            return error.InvalidConfig;
        self.state = .running;
        self.config = config;
    }

    fn drain(ptr: *anyopaque) market.DrainError!?canonical.AdapterOutputBatch {
        const self: *OkxMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const pending = self.pending;
        self.pending = null;
        return pending;
    }

    fn stop(ptr: *anyopaque, _: market.DrainDeadline) market.StopError!void {
        const self: *OkxMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.state = .stopped;
    }

    fn requireRunning(self: *const OkxMarketFeed) !void {
        return switch (self.state) {
            .idle => error.NotStarted,
            .stopped => error.Stopped,
            .running => {},
        };
    }

    fn sourceSession(self: *const OkxMarketFeed) !u64 {
        return @intCast((self.config orelse return error.NotStarted).session);
    }

    fn translate(self: *OkxMarketFeed, output: *canonical.AdapterOutputBatch, event: okx.PrivateEvent) !void {
        switch (event.payload) {
            .instrument_definition_observed => |definition| {
                const index = @intFromEnum(definition.instrument);
                const version = (self.config orelse return error.NotStarted).config_version;
                self.rules[index] = .{ .tick_size = definition.tick_size, .lot_size = definition.lot_size, .version = version };
                self.books[index].ready = false;
                try self.append(output, event.envelope, instrumentIdentity(definition.instrument), event.envelope.raw_evidence.stream_sequence, null, .{
                    .instrument_definition_observed = .{ .instrument = instrumentIdentity(definition.instrument), .rules_version = version },
                });
            },
            .l2_book_snapshot => |snapshot| {
                const index = @intFromEnum(snapshot.instrument);
                const rules = self.rules[index] orelse return error.MissingInstrumentRules;
                if (snapshot.bids.len == 0 or snapshot.asks.len == 0) {
                    self.books[index].ready = false;
                    return self.append(output, event.envelope, instrumentIdentity(snapshot.instrument), event.envelope.raw_evidence.stream_sequence, null, .{
                        .market_data_health_changed = .{ .instrument = instrumentIdentity(snapshot.instrument), .health = .gap },
                    });
                }
                const bid = try price(snapshot.instrument, rules, snapshot.bids.slice()[0].price);
                const ask = try price(snapshot.instrument, rules, snapshot.asks.slice()[0].price);
                const bid_quantity = try quantity(snapshot.instrument, rules, snapshot.bids.slice()[0].quantity);
                const ask_quantity = try quantity(snapshot.instrument, rules, snapshot.asks.slice()[0].quantity);
                var depth: canonical.BookDepth = .{
                    .visible_at_ns = event.envelope.receive_time_utc_ns,
                    .bid_count = @intCast(@min(snapshot.bids.len, canonical.max_depth_levels)),
                    .ask_count = @intCast(@min(snapshot.asks.len, canonical.max_depth_levels)),
                    .bids_truncated = snapshot.bids.len > canonical.max_depth_levels,
                    .asks_truncated = snapshot.asks.len > canonical.max_depth_levels,
                };
                // Validate every received level, including the discarded tail.
                for (snapshot.bids.slice(), 0..) |level, i| {
                    const px = try price(snapshot.instrument, rules, level.price);
                    const qty = try quantity(snapshot.instrument, rules, level.quantity);
                    if (px.ticks <= 0 or qty.lots < 0) return error.InvalidDepthLevel;
                    if (i > 0 and try compareDecimal(snapshot.bids.slice()[i - 1].price, level.price) != .gt) return error.InvalidDepthLevel;
                    if (i < depth.bid_count) depth.bids[i] = .{ .ticks = px.ticks, .lots = qty.lots };
                }
                for (snapshot.asks.slice(), 0..) |level, i| {
                    const px = try price(snapshot.instrument, rules, level.price);
                    const qty = try quantity(snapshot.instrument, rules, level.quantity);
                    if (px.ticks <= 0 or qty.lots < 0) return error.InvalidDepthLevel;
                    if (i > 0 and try compareDecimal(snapshot.asks.slice()[i - 1].price, level.price) != .lt) return error.InvalidDepthLevel;
                    if (i < depth.ask_count) depth.asks[i] = .{ .ticks = px.ticks, .lots = qty.lots };
                }
                const sequence = try sourceSequence(snapshot.source_sequence);
                try @import("../../market/depth_snapshot.zig").validate(.{ .instrument = instrumentIdentity(snapshot.instrument), .sequence = sequence, .depth = depth, .best_bid = bid, .best_ask = ask, .best_bid_quantity = bid_quantity, .best_ask_quantity = ask_quantity });
                self.books[index] = .{ .ready = true, .depth = depth };
                try self.append(output, event.envelope, instrumentIdentity(snapshot.instrument), sequence, null, .{
                    .l2_book_snapshot = .{ .instrument = instrumentIdentity(snapshot.instrument), .sequence = sequence, .depth = depth, .best_bid = bid, .best_ask = ask, .best_bid_quantity = bid_quantity, .best_ask_quantity = ask_quantity, .next_ask = if (depth.ask_count > 1) .{ .instrument = bid.instrument, .rules_version = rules.version, .ticks = depth.asks[1].ticks } else null, .next_ask_quantity = if (depth.ask_count > 1) .{ .instrument = bid.instrument, .rules_version = rules.version, .lots = depth.asks[1].lots.? } else null },
                });
            },
            .l2_book_delta => |delta| try self.translateDelta(output, event.envelope, delta),
            .reference_price => |reference| {
                const rules = self.rules[@intFromEnum(reference.instrument)] orelse return error.MissingInstrumentRules;
                try self.append(output, event.envelope, instrumentIdentity(reference.instrument), event.envelope.raw_evidence.stream_sequence, null, .{
                    .reference_price = .{ .instrument = instrumentIdentity(reference.instrument), .kind = switch (reference.kind) {
                        .mark => .mark,
                        .index => .index,
                    }, .price = try price(reference.instrument, rules, reference.price) },
                });
            },
            .funding_rate_published => |funding| {
                const rate = try canonicalDecimal(funding.predicted_rate).exactAtoms(6);
                try self.append(output, event.envelope, instrumentIdentity(funding.instrument), event.envelope.raw_evidence.stream_sequence, null, .{
                    .funding_rate_published = .{ .instrument = instrumentIdentity(funding.instrument), .rate_ppm = std.math.cast(i64, rate) orelse return error.FundingRateOverflow, .funding_time_utc_ns = funding.funding_time_utc_ns },
                });
            },
            .market_data_health_changed => |change| {
                if (change.health != .healthy) self.books[@intFromEnum(change.instrument)].ready = false;
                if (change.health == .healthy and !self.books[@intFromEnum(change.instrument)].ready) return;
                try self.append(output, event.envelope, instrumentIdentity(change.instrument), event.envelope.raw_evidence.stream_sequence, null, .{
                    .market_data_health_changed = .{ .instrument = instrumentIdentity(change.instrument), .health = health(change.health) },
                });
            },
        }
    }

    fn translateDelta(self: *OkxMarketFeed, output: *canonical.AdapterOutputBatch, envelope: okx.EventEnvelope, delta: okx.L2BookDelta) !void {
        const index = @intFromEnum(delta.instrument);
        const rules = self.rules[index] orelse return error.MissingInstrumentRules;
        var book = &self.books[index];
        const sequence = try sourceSequence(delta.source_sequence);
        const previous = try sourceSequence(delta.previous_source_sequence);
        if (!book.ready or book.depth == null) {
            book.ready = false;
            return self.append(output, envelope, instrumentIdentity(delta.instrument), sequence, previous, .{
                .market_data_health_changed = .{ .instrument = instrumentIdentity(delta.instrument), .health = .gap },
            });
        }
        var depth = book.depth.?;
        if (depth.bids_truncated or depth.asks_truncated) return error.TruncatedBookRequiresSnapshot;
        try updateSide(&depth.bids, &depth.bid_count, delta.bids.slice(), delta.instrument, rules, true);
        try updateSide(&depth.asks, &depth.ask_count, delta.asks.slice(), delta.instrument, rules, false);
        if (depth.bid_count == 0 or depth.ask_count == 0) return error.IncompleteBookSnapshot;
        depth.visible_at_ns = envelope.receive_time_utc_ns;
        const instrument = instrumentIdentity(delta.instrument);
        const bid: canonical.InstrumentPrice = .{ .instrument = instrument, .rules_version = rules.version, .ticks = depth.bids[0].ticks };
        const ask: canonical.InstrumentPrice = .{ .instrument = instrument, .rules_version = rules.version, .ticks = depth.asks[0].ticks };
        const bid_quantity: canonical.InstrumentQuantity = .{ .instrument = instrument, .rules_version = rules.version, .lots = depth.bids[0].lots.? };
        const ask_quantity: canonical.InstrumentQuantity = .{ .instrument = instrument, .rules_version = rules.version, .lots = depth.asks[0].lots.? };
        const next_ask: ?canonical.InstrumentPrice = if (depth.ask_count > 1) .{ .instrument = instrument, .rules_version = rules.version, .ticks = depth.asks[1].ticks } else null;
        const next_quantity: ?canonical.InstrumentQuantity = if (depth.ask_count > 1) .{ .instrument = instrument, .rules_version = rules.version, .lots = depth.asks[1].lots.? } else null;
        try @import("../../market/depth_snapshot.zig").validate(.{ .instrument = instrument, .sequence = sequence, .depth = depth, .best_bid = bid, .best_ask = ask, .best_bid_quantity = bid_quantity, .best_ask_quantity = ask_quantity, .next_ask = next_ask, .next_ask_quantity = next_quantity });
        book.* = .{ .depth = depth, .ready = true };
        try self.append(output, envelope, instrument, sequence, previous, .{
            .l2_book_delta = .{ .instrument = instrument, .previous_sequence = previous, .sequence = sequence, .depth = depth, .best_bid = bid, .best_ask = ask, .best_bid_quantity = bid_quantity, .best_ask_quantity = ask_quantity, .next_ask = next_ask, .next_ask_quantity = next_quantity },
        });
    }

    fn append(self: *OkxMarketFeed, output: *canonical.AdapterOutputBatch, envelope: okx.EventEnvelope, instrument: canonical.InstrumentIdentity, source_sequence: u64, previous: ?u64, event: canonical.Payload) !void {
        const config = self.config orelse return error.NotStarted;
        self.next_event_sequence = std.math.add(u64, self.next_event_sequence, 1) catch return error.EventSequenceOverflow;
        try output.append(.{ .envelope = .{
            .event_type = @intFromEnum(canonical.eventType(event)),
            .schema_version = canonical.schema_version,
            .identity = .{ .stream = config.session, .sequence = self.next_event_sequence },
            .source_fact_identity = std.mem.readInt(u128, envelope.source_fact_identity[0..16], .little),
            .scope = .instrument,
            .venue = config.venue,
            .instrument = instrument,
            .source_stream = config.subscription_set,
            .source_sequence = source_sequence,
            .source_previous_sequence = previous,
            .adapter_session = config.session,
            .times = .{ .source_utc_ns = envelope.source_time_utc_ns, .receive_utc_ns = envelope.receive_time_utc_ns, .monotonic_ns = envelope.monotonic_time_ns, .audit_utc_ns = envelope.wall_time_utc_ns },
            .raw_evidence = .{ .stream = config.subscription_set, .sequence = envelope.raw_evidence.stream_sequence, .digest = envelope.raw_evidence.sha256 },
        }, .event = event });
    }
};

fn instrumentIdentity(instrument: okx.Instrument) canonical.InstrumentIdentity {
    return switch (instrument) {
        .btc_usdt_spot => btc_usdt_spot,
        .btc_usdt_swap => btc_usdt_swap,
    };
}

fn canonicalDecimal(value: okx.Decimal) canonical.Decimal {
    return .{ .coefficient = value.coefficient, .scale = value.scale };
}

fn price(instrument: okx.Instrument, rules: Rules, value: okx.Decimal) !canonical.InstrumentPrice {
    const tick_atoms = try canonicalDecimal(rules.tick_size).exactAtoms(rules.tick_size.scale);
    return canonical.InstrumentPrice.fromDecimal(instrumentIdentity(instrument), rules.version, canonicalDecimal(value), rules.tick_size.scale, tick_atoms);
}

fn quantity(instrument: okx.Instrument, rules: Rules, value: okx.Decimal) !canonical.InstrumentQuantity {
    const lot_atoms = try canonicalDecimal(rules.lot_size).exactAtoms(rules.lot_size.scale);
    return canonical.InstrumentQuantity.fromDecimal(instrumentIdentity(instrument), rules.version, canonicalDecimal(value), rules.lot_size.scale, lot_atoms);
}

fn sourceSequence(value: i64) !u64 {
    if (value < 0) return error.InvalidSourceSequence;
    return @intCast(value);
}

fn health(value: okx.MarketDataHealth) canonical.MarketDataHealth {
    return switch (value) {
        .awaiting_snapshot => .awaiting_snapshot,
        .healthy => .healthy,
        .gap => .gap,
    };
}

// Apply all updates to a candidate; a failed side never publishes partial depth.
fn updateSide(levels: *[canonical.max_depth_levels]canonical.DepthLevel, count: *u8, updates: []const okx.BookLevel, instrument: okx.Instrument, rules: Rules, bids: bool) !void {
    for (updates, 0..) |update, update_index| {
        const px = try price(instrument, rules, update.price);
        const qty = try quantity(instrument, rules, update.quantity);
        if (px.ticks <= 0 or qty.lots < 0) return error.InvalidDepthLevel;
        for (updates[0..update_index]) |earlier| {
            if ((try price(instrument, rules, earlier.price)).ticks == px.ticks) return error.ConflictingBookDelta;
        }
        var index: usize = 0;
        while (index < count.* and (if (bids) levels[index].ticks > px.ticks else levels[index].ticks < px.ticks)) : (index += 1) {}
        const found = index < count.* and levels[index].ticks == px.ticks;
        if (qty.lots == 0) {
            if (found) {
                var i = index;
                while (i + 1 < count.*) : (i += 1) levels[i] = levels[i + 1];
                count.* -= 1;
                levels[count.*] = .{};
            }
        } else if (found) {
            levels[index].lots = qty.lots;
        } else {
            if (count.* == levels.len) return error.DepthCapacityExceeded;
            // A bounded snapshot proves only through its last supplied price.
            // A new worse price cannot prove the unknown intervening tail empty.
            if (count.* == 0 or index == count.*) return error.UnprovenDepthCoverage;
            var i: usize = count.*;
            while (i > index) : (i -= 1) levels[i] = levels[i - 1];
            levels[index] = .{ .ticks = px.ticks, .lots = qty.lots };
            count.* += 1;
        }
    }
}

const TestRawSink = struct {
    append_count: u64 = 0,

    fn sink(self: *TestRawSink) okx.RawSink {
        return .{ .ptr = self, .append_fn = append };
    }

    fn append(ptr: *anyopaque, record: okx.RawIngressRecord, bytes: []const u8) okx.RawSinkError!u64 {
        const self: *TestRawSink = @ptrCast(@alignCast(ptr));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &record.sha256)) return error.Unavailable;
        self.append_count += 1;
        return self.append_count;
    }
};

const test_times: okx.Times = .{ .receive_time_utc_ns = 1_800_000_000_000_000_001, .monotonic_time_ns = 10_000_001, .wall_time_utc_ns = 1_800_000_000_000_000_002 };

fn startTest(feed: *OkxMarketFeed) !market.MarketFeedAdapter {
    const adapter = feed.adapter();
    try adapter.start(.{ .venue = 9, .environment = .demo, .subscription_set = 8, .config_version = 7, .session = 6, .output_capacity = 2 });
    return adapter;
}

test "OKX official public fixtures cross the market seam as shared facts" {
    var sink = TestRawSink{};
    var feed = OkxMarketFeed.init(sink.sink());
    const adapter = try startTest(&feed);
    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"instruments","instType":"SWAP"},"data":[{"instType":"SWAP","instId":"BTC-USDT-SWAP","state":"live","ruleType":"normal","tickSz":"0.1","lotSz":"0.01","minSz":"0.01","maxLmtSz":"1000000","maxMktSz":"10000","maxLmtAmt":"","maxMktAmt":"","ctType":"linear","ctVal":"0.01","ctValCcy":"BTC","settleCcy":"USDT","tradeQuoteCcyList":[],"upcChg":[],"ts":"1800000000000"}]}
    );
    const definition = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 1), definition.len);
    try std.testing.expectEqual(btc_usdt_swap, definition.events[0].event.instrument_definition_observed.instrument);
    try std.testing.expectEqual(@as(u64, 1), sink.append_count);

    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"books","instId":"BTC-USDT-SWAP"},"action":"snapshot","data":[{"asks":[["50100.1","2.0","0","3"]],"bids":[["50099.9","1.5","0","2"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1","checksum":0}]}
    );
    const snapshot = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 2), snapshot.len);
    try std.testing.expectEqual(@as(i128, 500999), snapshot.events[0].event.l2_book_snapshot.best_bid.ticks);
    try std.testing.expectEqual(@as(i128, 150), snapshot.events[0].event.l2_book_snapshot.best_bid_quantity.?.lots);
    try std.testing.expectEqual(@as(i128, 200), snapshot.events[0].event.l2_book_snapshot.best_ask_quantity.?.lots);
    try std.testing.expectEqual(canonical.MarketDataHealth.healthy, snapshot.events[1].event.market_data_health_changed.health);

    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"mark-price","instId":"BTC-USDT-SWAP"},"data":[{"instId":"BTC-USDT-SWAP","markPx":"50123.40","ts":"1800000000100"}]}
    );
    const mark = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(i128, 501234), mark.events[0].event.reference_price.price.ticks);

    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"funding-rate","instId":"BTC-USDT-SWAP"},"data":[{"instId":"BTC-USDT-SWAP","fundingRate":"0.00010000","fundingTime":"1800003600000","nextFundingTime":"1800032400000","settFundingRate":"0.00009","settState":"settled","ts":"1800000000300"}]}
    );
    const funding = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(i64, 100), funding.events[0].event.funding_rate_published.rate_ppm);

    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"0.1","lotSz":"0.00000001","minSz":"0.00001","maxLmtSz":"100","maxMktSz":"10","maxLmtAmt":"1000000","maxMktAmt":"100000","ctType":"","ctVal":"","ctValCcy":"","settleCcy":"","tradeQuoteCcyList":["USDT"],"upcChg":[],"ts":"1800000000000"}]}
    );
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"index-tickers","instId":"BTC-USDT"},"data":[{"instId":"BTC-USDT","idxPx":"50120.1","ts":"1800000000200"}]}
    );
    const index = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.ReferencePriceKind.index, index.events[0].event.reference_price.kind);
    try std.testing.expectEqual(btc_usdt_spot, index.events[0].event.reference_price.instrument);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "OKX market feed fails closed on a book gap and requires a new snapshot after re-subscribe" {
    var sink = TestRawSink{};
    var feed = OkxMarketFeed.init(sink.sink());
    const adapter = try startTest(&feed);
    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"0.1","lotSz":"0.00000001","minSz":"0.00001","maxLmtSz":"100","maxMktSz":"10","maxLmtAmt":"1000000","maxMktAmt":"100000","ctType":"","ctVal":"","ctValCcy":"","settleCcy":"","tradeQuoteCcyList":["USDT"],"upcChg":[],"ts":"1800000000000"}]}
    );
    _ = try adapter.tryDrain();
    const snapshot_frame =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["50100.1","2.0","0","3"]],"bids":[["50099.9","1.5","0","2"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1","checksum":0}]}
    ;
    try feed.ingest(std.testing.allocator, test_times, snapshot_frame);
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[],"bids":[["50099.8","1.0","0","1"]],"ts":"1800000000200","seqId":"110","prevSeqId":"108","checksum":0}]}
    );
    const gap = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.MarketDataHealth.gap, gap.events[0].event.market_data_health_changed.health);

    try feed.beginSubscription(.btc_usdt_spot, test_times, "{\"event\":\"subscribe\",\"channel\":\"books\"}");
    const awaiting = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.MarketDataHealth.awaiting_snapshot, awaiting.events[0].event.market_data_health_changed.health);
    try feed.ingest(std.testing.allocator, test_times, snapshot_frame);
    const recovered = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.MarketDataHealth.healthy, recovered.events[1].event.market_data_health_changed.health);
    try std.testing.expectEqual(@as(u64, 5), sink.append_count);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "OKX implementation obeys the shared lifecycle and output backpressure contract" {
    var sink = TestRawSink{};
    var feed = OkxMarketFeed.init(sink.sink());
    const adapter = feed.adapter();
    try std.testing.expectError(error.InvalidConfig, adapter.start(.{ .venue = 9, .environment = .demo, .subscription_set = 8, .config_version = 7, .session = 6, .output_capacity = 1 }));
    try market.testStartupContract(adapter, .{ .venue = 9, .environment = .demo, .subscription_set = 8, .config_version = 7, .session = 6, .output_capacity = 2 });
    try feed.beginSubscription(.btc_usdt_spot, test_times, "{\"event\":\"subscribe\"}");
    try std.testing.expectError(error.OutputPending, adapter.stop(.{ .monotonic_ns = 1 }));
    _ = try adapter.tryDrain();
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "02 captured multi-level snapshot retains both sides at the public seam" {
    var sink = TestRawSink{};
    var feed = OkxMarketFeed.init(sink.sink());
    const adapter = try startTest(&feed);
    const definition_raw =
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"0.1","lotSz":"0.01","minSz":"0.01","maxLmtSz":"1000000","maxMktSz":"10000","maxLmtAmt":"","maxMktAmt":"","tradeQuoteCcyList":[],"upcChg":[],"ts":"1800000000000"}]}
    ;
    try feed.ingest(std.testing.allocator, test_times, definition_raw);
    const definition_output = (try adapter.tryDrain()).?;
    const snapshot_raw =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["100.1","0.02","0","1"],["100.2","0.03","0","1"]],"bids":[["99.9","0.04","0","1"],["99.8","0.05","0","1"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1","checksum":0}]}
    ;
    try feed.ingest(std.testing.allocator, test_times, snapshot_raw);
    const batch = (try adapter.tryDrain()).?;
    var replay_sink = TestRawSink{};
    var replay_feed = OkxMarketFeed.init(replay_sink.sink());
    const replay_adapter = try startTest(&replay_feed);
    const definition_evidence = definition_output.events[0].envelope.raw_evidence;
    try replay_feed.replay(std.testing.allocator, 6, test_times, .{ .stream_sequence = definition_evidence.sequence, .sha256 = definition_evidence.digest }, definition_raw);
    _ = try replay_adapter.tryDrain();
    const snapshot_evidence = batch.events[0].envelope.raw_evidence;
    try replay_feed.replay(std.testing.allocator, 6, test_times, .{ .stream_sequence = snapshot_evidence.sequence, .sha256 = snapshot_evidence.digest }, snapshot_raw);
    const replay_output = (try replay_adapter.tryDrain()).?;
    try std.testing.expectEqualDeep(batch.events[0], replay_output.events[0]);
    try std.testing.expectEqual(@as(u64, 0), replay_sink.append_count);
    const depth = batch.events[0].event.l2_book_snapshot.depth.?;
    try std.testing.expectEqual(@as(u8, 2), depth.bid_count);
    try std.testing.expectEqual(@as(u8, 2), depth.ask_count);
    try std.testing.expectEqual(@as(i128, 998), depth.bids[1].ticks);
    try std.testing.expectEqual(@as(?i128, 3), depth.asks[1].lots);
    const projection_module = @import("../../market/market_projection.zig");
    const host = @import("../../strategy/strategy_host_gateway.zig");
    const ipc = @import("../../strategy/strategy_host_ipc.zig");
    const depth_module = @import("../../market/depth_snapshot.zig");
    const codec = @import("../../persistence/canonical_event_codec.zig");
    var projection: projection_module.Projection = .{};
    try projection.apply(.{ .instrument_definition_observed = .{ .instrument = btc_usdt_spot, .rules_version = 7 } });
    try projection.activateRules(btc_usdt_spot, 7);
    try projection.apply(batch.events[0].event);
    var wire: [depth_module.wire_len]u8 = undefined;
    const input = try host.depthSnapshotInput(&projection, btc_usdt_spot, 1, &wire, 10, 12);
    const visible = try depth_module.decode(input.payload);
    try std.testing.expectEqualDeep(batch.events[0].event.l2_book_snapshot, visible);
    try std.testing.expectEqual(@as(i128, 5008), (try depth_module.quote(visible, .buy, 5, 1002, 0, .quote)).quote_tick_lots);
    try std.testing.expectEqual(@as(i128, 4989), (try depth_module.quote(visible, .sell, 5, 998, 1000, .quote)).quote_tick_lots);
    try std.testing.expectEqual(@as(i128, 5014), (try depth_module.quote(visible, .buy, 5, 1002, 1000, .quote)).quote_tick_lots);
    try std.testing.expectEqual(@as(i128, 4), (try depth_module.quote(visible, .buy, 5, 1002, 1000, .base)).base_lots);
    try std.testing.expectEqual(@as(i128, 6), (try depth_module.quote(visible, .sell, 5, 998, 1000, .base)).base_lots);
    try std.testing.expectError(error.InsufficientDepth, depth_module.quote(visible, .buy, 6, 1002, 0, .quote));
    try std.testing.expectError(error.InsufficientDepth, depth_module.quote(visible, .buy, 5, 1001, 0, .quote));
    var gateway = try host.Gateway.init(.{ .schema_registry = 10, .decision_domain = 20, .session = .{ .fencing = 1, .shard = 0, .generation = 1 }, .authorization = .{ .strategy_identity = 1, .config_version = 7, .activation_identity = 1, .activation_barrier = 0 } }, &.{host.Subscription.of(1, &.{.depth_snapshot})});
    var batch_bytes: [2048]u8 = undefined;
    const host_batch = try gateway.encodeBatch(&batch_bytes, 1, 1, 1, 10, &.{input});
    try std.testing.expectEqual(ipc.QshStatusV1.ok, ipc.validateBatchAt(host_batch, gateway.config.session, 1, null, 11).status);
    try std.testing.expectEqualDeep(visible, try depth_module.decode(host_batch[192..][0..depth_module.wire_len]));

    // Appendix V2, with one price tick and one quantity lot per stated unit.
    var v2_sink = TestRawSink{};
    var v2_feed = OkxMarketFeed.init(v2_sink.sink());
    const v2_adapter = try startTest(&v2_feed);
    const v2_definition_raw =
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"1","lotSz":"1","minSz":"0.01","maxLmtSz":"1000000","maxMktSz":"10000","maxLmtAmt":"","maxMktAmt":"","tradeQuoteCcyList":[],"upcChg":[],"ts":"1800000000000"}]}
    ;
    try v2_feed.ingest(std.testing.allocator, test_times, v2_definition_raw);
    const v2_definition = (try v2_adapter.tryDrain()).?;
    try v2_feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["100","1","0","1"],["101","2","0","1"]],"bids":[["99","1","0","1"],["98","2","0","1"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1","checksum":0}]}
    );
    const v2_batch = (try v2_adapter.tryDrain()).?;
    var v2_projection: projection_module.Projection = .{};
    try v2_projection.apply(v2_definition.events[0].event);
    try v2_projection.activateRules(btc_usdt_spot, 7);
    try v2_projection.apply(v2_batch.events[0].event);
    const v2_input = try host.depthSnapshotInput(&v2_projection, btc_usdt_spot, 1, &wire, 10, 12);
    const v2_book = try depth_module.decode(v2_input.payload);
    try std.testing.expectEqual(@as(i128, 302), (try depth_module.quote(v2_book, .buy, 3, 101, 0, .quote)).quote_tick_lots);
    try std.testing.expectError(error.InsufficientDepth, depth_module.quote(v2_book, .buy, 3, 100, 0, .quote));
    try std.testing.expectEqual(@as(i128, 100), (try depth_module.quote(v2_book, .buy, 1, 100, 0, .quote)).quote_tick_lots);
    try std.testing.expectEqual(@as(i128, 295), (try depth_module.quote(v2_book, .sell, 3, 98, 0, .quote)).quote_tick_lots);
    try std.testing.expectError(error.InsufficientDepth, depth_module.quote(v2_book, .sell, 3, 99, 0, .quote));

    // Capture encoding/replay cannot lose depth or invent tail liquidity.
    var encoded: [codec.max_encoded_len]u8 = undefined;
    const record = try codec.decode(try codec.encode(&encoded, batch.events[0]));
    var old_schema = batch.events[0];
    old_schema.envelope.schema_version = 13;
    try std.testing.expectError(error.InvalidCanonicalEnvelope, codec.encode(&encoded, old_schema));
    const encoded_current = try codec.encode(&encoded, batch.events[0]);
    encoded[0] = 11;
    try std.testing.expectError(error.UnsupportedCanonicalEncoding, codec.decode(encoded_current));

    var replayed = projection;
    replayed.entries[0].last_book = null;
    try replayed.apply(record.event);
    try std.testing.expectEqualDeep(projection.get(btc_usdt_spot), replayed.get(btc_usdt_spot));
    try std.testing.expectError(error.StaleBookSnapshot, projection.apply(record.event));
    try std.testing.expectEqualDeep(visible, projection.get(btc_usdt_spot).?.last_book.?);
    // A late snapshot may revoke health but never replace a previous decision input.
    try std.testing.expectError(error.MarketGap, host.depthSnapshotInput(&projection, btc_usdt_spot, 2, &wire, 11, 13));

    var invalid = visible;
    invalid.depth.?.ask_count = 9;
    try std.testing.expectError(error.DepthCapacityExceeded, depth_module.quote(invalid, .buy, 1, 1002, 0, .quote));
    invalid = visible;
    invalid.depth.?.ask_count = 0;
    try std.testing.expectError(error.IncompleteBookSnapshot, depth_module.quote(invalid, .buy, 1, 1002, 0, .quote));
    invalid = visible;
    invalid.depth.?.asks[1].ticks = 1000;
    try std.testing.expectError(error.InvalidDepthLevel, depth_module.quote(invalid, .buy, 1, 1002, 0, .quote));
    invalid = visible;
    invalid.depth.?.asks[1].lots = null;
    invalid.next_ask_quantity = null;
    try std.testing.expectError(error.InsufficientDepth, depth_module.quote(invalid, .buy, 3, 1002, 0, .quote));
    invalid.depth.?.asks[1].lots = 0;
    invalid.next_ask_quantity = .{ .instrument = visible.instrument, .rules_version = 7, .lots = 0 };
    try std.testing.expectError(error.InsufficientDepth, depth_module.quote(invalid, .buy, 3, 1002, 0, .quote));
    invalid = visible;
    invalid.complete = false;
    try std.testing.expectError(error.IncompleteBookSnapshot, depth_module.quote(invalid, .buy, 1, 1002, 0, .quote));
    invalid = visible;
    invalid.depth = null;
    try std.testing.expectError(error.MissingDepth, depth_module.quote(invalid, .buy, 1, 1002, 0, .quote));
    var small: [32]u8 = undefined;
    try std.testing.expectError(error.DepthCapacityExceeded, depth_module.encode(&small, visible));
    _ = try depth_module.encode(&wire, visible);
    wire[40] = 9;
    try std.testing.expectError(error.DepthCapacityExceeded, depth_module.decode(&wire));
    // Raw malformed ticks revoke the adapter book, with captured gap evidence.
    try std.testing.expectError(error.InexactDecimal, feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["100.15","0.02","0","1"]],"bids":[["99.9","0.04","0","1"]],"ts":"1800000000000","seqId":"101","prevSeqId":"-1","checksum":0}]}
    ));
    const failed = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.MarketDataHealth.gap, failed.events[0].event.market_data_health_changed.health);
    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["100.1","0.01","0","1"],["100.2","0.01","0","1"],["100.3","0.01","0","1"],["100.4","0.01","0","1"],["100.5","0.01","0","1"],["100.6","0.01","0","1"],["100.7","0.01","0","1"],["100.8","0.01","0","1"],["100.9","0.01","0","1"]],"bids":[["99.9","0.01","0","1"],["99.8","0.01","0","1"],["99.7","0.01","0","1"],["99.6","0.01","0","1"],["99.5","0.01","0","1"],["99.4","0.01","0","1"],["99.3","0.01","0","1"],["99.2","0.01","0","1"],["99.1","0.01","0","1"]],"ts":"1800000000000","seqId":"102","prevSeqId":"-1","checksum":0}]}
    );
    const bounded = (try adapter.tryDrain()).?.events[0].event.l2_book_snapshot;
    try std.testing.expectEqual(@as(u8, 8), bounded.depth.?.bid_count);
    try std.testing.expect(bounded.depth.?.bids_truncated and bounded.depth.?.asks_truncated);
    try std.testing.expectError(error.InsufficientDepth, depth_module.quote(bounded, .buy, 9, 1010, 0, .quote));
    try std.testing.expectError(error.InsufficientDepth, depth_module.quote(bounded, .sell, 9, 990, 0, .quote));
}

fn compareDecimal(a: okx.Decimal, b: okx.Decimal) !std.math.Order {
    const scale = @max(a.scale, b.scale);
    return std.math.order(try canonicalDecimal(a).exactAtoms(scale), try canonicalDecimal(b).exactAtoms(scale));
}

test "03 depth updates delete levels and preserve Host evidence" {
    const projection_module = @import("../../market/market_projection.zig");
    const host = @import("../../strategy/strategy_host_gateway.zig");
    const depth_module = @import("../../market/depth_snapshot.zig");
    var sink = TestRawSink{};
    var feed = OkxMarketFeed.init(sink.sink());
    const adapter = try startTest(&feed);
    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"1","lotSz":"1","minSz":"1","ts":"1800000000000"}]}
    );
    const definition = (try adapter.tryDrain()).?;
    var projection: projection_module.Projection = .{};
    try projection.apply(definition.events[0].event);
    try projection.activateRules(btc_usdt_spot, 7);
    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["100","1","0","1"],["101","2","0","1"],["102","3","0","1"]],"bids":[["99","1","0","1"],["98","2","0","1"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1"}]}
    );
    const snapshot = (try adapter.tryDrain()).?;
    for (snapshot.events[0..snapshot.len]) |record| try projection.apply(record.event);
    try feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[["100","0","0","1"],["102","4","0","1"]],"bids":[["98","5","0","1"]],"ts":"1800000000001","seqId":"105","prevSeqId":"100"}]}
    );
    const delta = (try adapter.tryDrain()).?;
    for (delta.events[0..delta.len]) |record| try projection.apply(record.event);
    var wire: [depth_module.wire_len]u8 = undefined;
    const input = try host.depthSnapshotInput(&projection, btc_usdt_spot, 2, &wire, 10, 12);
    const visible = try depth_module.decode(input.payload);
    try std.testing.expectEqual(@as(u64, 105), visible.sequence);
    try std.testing.expectEqual(@as(u8, 2), visible.depth.?.ask_count);
    try std.testing.expectEqual(@as(i128, 610), (try depth_module.quote(visible, .buy, 6, 102, 0, .quote)).quote_tick_lots);
    try std.testing.expectEqual(@as(?i128, 5), visible.depth.?.bids[1].lots);
    // A single update beyond known coverage cannot prove the intervening tail.
    try std.testing.expectError(error.UnprovenDepthCoverage, feed.ingest(std.testing.allocator, test_times,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[["103","1","0","1"]],"bids":[],"ts":"1800000000002","seqId":"110","prevSeqId":"105"}]}
    ));
    const failed = (try adapter.tryDrain()).?;
    try projection.apply(failed.events[0].event);
    try std.testing.expectError(error.MarketGap, host.depthSnapshotInput(&projection, btc_usdt_spot, 3, &wire, 10, 12));
}

// Each captured frame is checked at the MarketFeedAdapter and Host boundaries.
// No test inspects decoder state or adapter-owned depth.
test "03 depth resynchronization capture replay agrees at every failure cut" {
    const projection_module = @import("../../market/market_projection.zig");
    const host = @import("../../strategy/strategy_host_gateway.zig");
    const depth_module = @import("../../market/depth_snapshot.zig");
    const codec = @import("../../persistence/canonical_event_codec.zig");
    const ipc = @import("../../strategy/strategy_host_ipc.zig");
    var gateway = try host.Gateway.init(.{ .schema_registry = 10, .decision_domain = 20, .session = .{ .fencing = 1, .shard = 0, .generation = 1 }, .authorization = .{ .strategy_identity = 1, .config_version = 7, .activation_identity = 1, .activation_barrier = 0 } }, &.{host.Subscription.of(1, &.{.depth_snapshot})});
    var sink = TestRawSink{};
    var replay_sink = TestRawSink{};
    var feed = OkxMarketFeed.init(sink.sink());
    var replay_feed = OkxMarketFeed.init(replay_sink.sink());
    const adapter = try startTest(&feed);
    const replay_adapter = try startTest(&replay_feed);
    var projection: projection_module.Projection = .{};
    var replayed: projection_module.Projection = .{};
    const definition =
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"1","lotSz":"1","minSz":"1","ts":"1800000000000"}]}
    ;
    const snapshot =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["100","1","0","1"],["101","2","0","1"]],"bids":[["99","1","0","1"],["98","2","0","1"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1"}]}
    ;
    const update =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[["100","3","0","1"]],"bids":[],"ts":"1800000000001","seqId":"105","prevSeqId":"100"}]}
    ;
    const conflict =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[["100","4","0","1"]],"bids":[],"ts":"1800000000001","seqId":"105","prevSeqId":"100"}]}
    ;
    const restored =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["100","1","0","1"],["101","2","0","1"]],"bids":[["99","1","0","1"],["98","2","0","1"]],"ts":"1800000000002","seqId":"110","prevSeqId":"-1"}]}
    ;
    const gap =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[],"bids":[],"ts":"1800000000003","seqId":"112","prevSeqId":"111"}]}
    ;
    const malformed =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[["100"]],"bids":[],"ts":"1800000000003","seqId":"111","prevSeqId":"110"}]}
    ;
    const frames = [_][]const u8{ definition, snapshot, update, update, conflict, update, snapshot, restored, gap, malformed, "{" };
    const qualified = [_]bool{ false, true, true, true, false, false, false, true, false, false, false };
    for (frames, qualified, 0..) |raw, healthy, cut| {
        try feed.ingest(std.testing.allocator, test_times, raw);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        try replay_feed.replay(std.testing.allocator, 6, test_times, .{ .stream_sequence = sink.append_count, .sha256 = hash }, raw);
        const actual = try adapter.tryDrain();
        const recovered = try replay_adapter.tryDrain();
        try std.testing.expectEqual(actual != null, recovered != null);
        if (actual) |batch| {
            try std.testing.expectEqualDeep(batch.events[0..batch.len], recovered.?.events[0..recovered.?.len]);
            for (batch.events[0..batch.len]) |record| {
                try projection.apply(record.event);
                var encoded: [codec.max_encoded_len]u8 = undefined;
                try replayed.apply((try codec.decode(try codec.encode(&encoded, record))).event);
                if (record.event == .instrument_definition_observed) {
                    try projection.activateRules(btc_usdt_spot, 7);
                    try replayed.activateRules(btc_usdt_spot, 7);
                }
            }
        }
        try std.testing.expectEqualDeep(projection.get(btc_usdt_spot), replayed.get(btc_usdt_spot));
        var live_wire: [depth_module.wire_len]u8 = undefined;
        var replay_wire: [depth_module.wire_len]u8 = undefined;
        var input_events: [1]host.EventEnvelope = undefined;
        var input_count: usize = 0;
        if (healthy) {
            const input = try host.depthSnapshotInput(&projection, btc_usdt_spot, cut + 1, &live_wire, 10, 12);
            const replay_input = try host.depthSnapshotInput(&replayed, btc_usdt_spot, cut + 1, &replay_wire, 10, 12);
            try std.testing.expectEqualSlices(u8, input.payload, replay_input.payload);
            input_events[0] = input;
            input_count = 1;
        } else {
            const entry = projection.get(btc_usdt_spot).?;
            try std.testing.expect(entry.health != .healthy);
        }
        var batch_bytes: [2048]u8 = undefined;
        const batch = try gateway.encodeBatch(&batch_bytes, cut + 1, cut + 1, cut + 1, 10, input_events[0..input_count]);
        try std.testing.expectEqual(ipc.QshStatusV1.ok, ipc.validateBatchAt(batch, gateway.config.session, cut + 1, null, 11).status);
        try gateway.recordPublished(cut + 1, cut + 1, 10);
        if (input_count == 1) try std.testing.expectEqualSlices(u8, input_events[0].payload, batch[192..][0..depth_module.wire_len]);
    }
    try std.testing.expectEqual(@as(u64, 0), replay_sink.append_count);
}

test "03 depth capacity unknown quantity and numeric overflow fail closed" {
    // Raw cases use a fresh captured snapshot before every invalid update.
    const definition =
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"1","lotSz":"1","minSz":"1","ts":"1800000000000"}]}
    ;
    const snapshot =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["100","1","0","1"],["101","1","0","1"],["102","1","0","1"],["103","1","0","1"],["104","1","0","1"],["105","1","0","1"],["106","1","0","1"],["107","1","0","1"]],"bids":[["99","1","0","1"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1"}]}
    ;
    const updates = [_][]const u8{
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[["108","1","0","1"]],"bids":[],"ts":"1800000000001","seqId":"105","prevSeqId":"100"}]}
        ,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[["100","170141183460469231731687303715884105728","0","1"]],"bids":[],"ts":"1800000000001","seqId":"105","prevSeqId":"100"}]}
        ,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[["100",null,"0","1"]],"bids":[],"ts":"1800000000001","seqId":"105","prevSeqId":"100"}]}
        ,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"update","data":[{"asks":[],"bids":[],"ts":"1800000000001","seqId":"99","prevSeqId":"100"}]}
    };
    for (updates) |raw| {
        var sink = TestRawSink{};
        var feed = OkxMarketFeed.init(sink.sink());
        const adapter = try startTest(&feed);
        try feed.ingest(std.testing.allocator, test_times, definition);
        _ = try adapter.tryDrain();
        try feed.ingest(std.testing.allocator, test_times, snapshot);
        _ = try adapter.tryDrain();
        feed.ingest(std.testing.allocator, test_times, raw) catch |err| {
            try std.testing.expectEqual(error.DepthCapacityExceeded, err);
        };
        const failed = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(canonical.MarketDataHealth.gap, failed.events[0].event.market_data_health_changed.health);
        var replay_sink = TestRawSink{};
        var replay_feed = OkxMarketFeed.init(replay_sink.sink());
        const replay_adapter = try startTest(&replay_feed);
        for ([_][]const u8{ definition, snapshot, raw }, 0..) |captured, cut| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(captured, &digest, .{});
            replay_feed.replay(std.testing.allocator, 6, test_times, .{ .stream_sequence = cut + 1, .sha256 = digest }, captured) catch |err| {
                try std.testing.expectEqual(error.DepthCapacityExceeded, err);
            };
            const restored = (try replay_adapter.tryDrain()).?;
            if (cut == 2) try std.testing.expectEqualDeep(failed.events[0..failed.len], restored.events[0..restored.len]);
        }
    }
    // A truncated snapshot is bounded evidence, but cannot seed an incremental book.
    var sink = TestRawSink{};
    var feed = OkxMarketFeed.init(sink.sink());
    const adapter = try startTest(&feed);
    try feed.ingest(std.testing.allocator, test_times, definition);
    _ = try adapter.tryDrain();
    const truncated = try std.mem.replaceOwned(u8, std.testing.allocator, snapshot, "[\"107\",\"1\",\"0\",\"1\"]", "[\"107\",\"1\",\"0\",\"1\"],[\"108\",\"1\",\"0\",\"1\"]");
    defer std.testing.allocator.free(truncated);
    try feed.ingest(std.testing.allocator, test_times, truncated);
    const bounded = (try adapter.tryDrain()).?;
    try std.testing.expect(bounded.events[0].event.l2_book_snapshot.depth.?.asks_truncated);
    try std.testing.expectError(error.TruncatedBookRequiresSnapshot, feed.ingest(std.testing.allocator, test_times, updates[0]));
    try std.testing.expectEqual(canonical.MarketDataHealth.gap, (try adapter.tryDrain()).?.events[0].event.market_data_health_changed.health);
}

test "03 oversized captured frames revoke depth and replay before fresh recovery" {
    const definition =
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"1","lotSz":"1","minSz":"1","ts":"1800000000000"}]}
    ;
    const snapshot =
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["100","1","0","1"]],"bids":[["99","1","0","1"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1"}]}
    ;
    const projection_module = @import("../../market/market_projection.zig");
    const host = @import("../../strategy/strategy_host_gateway.zig");
    const depth_module = @import("../../market/depth_snapshot.zig");
    var sink = TestRawSink{};
    var replay_sink = TestRawSink{};
    var feed = OkxMarketFeed.init(sink.sink());
    var replay_feed = OkxMarketFeed.init(replay_sink.sink());
    const adapter = try startTest(&feed);
    const replay_adapter = try startTest(&replay_feed);
    var projection: projection_module.Projection = .{};
    var replayed: projection_module.Projection = .{};
    const oversized = try std.testing.allocator.alloc(u8, okx.max_raw_frame_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    const fresh = try std.mem.replaceOwned(u8, std.testing.allocator, snapshot, "100\"", "110\"");
    defer std.testing.allocator.free(fresh);
    for ([_][]const u8{ definition, snapshot, oversized, fresh }, 0..) |raw, cut| {
        try feed.ingest(std.testing.allocator, test_times, raw);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
        try replay_feed.replay(std.testing.allocator, 6, test_times, .{ .stream_sequence = sink.append_count, .sha256 = hash }, raw);
        const batch = (try adapter.tryDrain()).?;
        const restored = (try replay_adapter.tryDrain()).?;
        try std.testing.expectEqualDeep(batch.events[0..batch.len], restored.events[0..restored.len]);
        for (batch.events[0..batch.len]) |record| {
            try projection.apply(record.event);
            try replayed.apply(record.event);
            if (cut == 0) {
                try projection.activateRules(btc_usdt_spot, 7);
                try replayed.activateRules(btc_usdt_spot, 7);
            }
        }
        var wire: [depth_module.wire_len]u8 = undefined;
        if (cut == 2) {
            try std.testing.expectError(error.MarketGap, host.depthSnapshotInput(&projection, btc_usdt_spot, cut + 1, &wire, 10, 12));
        } else if (cut != 0) _ = try host.depthSnapshotInput(&projection, btc_usdt_spot, cut + 1, &wire, 10, 12);
        try std.testing.expectEqualDeep(projection.get(btc_usdt_spot), replayed.get(btc_usdt_spot));
    }
}
