//! OKX public-market implementation of the shared MarketFeedAdapter seam.
//!
//! `okx_public_market` deliberately owns the Venue protocol. This module owns
//! only the one-way translation from those private facts into shared values.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const market = @import("market_feed_adapter.zig");
const okx = @import("okx_public_market.zig");

pub const btc_usdt_spot: canonical.InstrumentIdentity = 0x4f4b58_00000001;
pub const btc_usdt_swap: canonical.InstrumentIdentity = 0x4f4b58_00000002;

const State = enum { idle, running, stopped };
const Rules = struct {
    tick_size: okx.Decimal,
    version: u64,
};
const BookTop = struct {
    bid: canonical.InstrumentPrice,
    ask: canonical.InstrumentPrice,
    ready: bool = false,
};

pub const OkxMarketFeed = struct {
    decoder: okx.Decoder = .{},
    raw_sink: okx.RawSink,
    state: State = .idle,
    config: ?market.Config = null,
    pending: ?canonical.AdapterOutputBatch = null,
    next_event_sequence: u64 = 0,
    rules: [2]?Rules = .{ null, null },
    books: [2]BookTop = .{ undefined, undefined },

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
        var output: canonical.AdapterOutputBatch = .{};
        for (ingress.eventSlice()) |event|
            try self.translate(&output, event);
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
                self.rules[index] = .{ .tick_size = definition.tick_size, .version = version };
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
                const sequence = try sourceSequence(snapshot.source_sequence);
                self.books[index] = .{ .bid = bid, .ask = ask, .ready = true };
                try self.append(output, event.envelope, instrumentIdentity(snapshot.instrument), sequence, null, .{
                    .l2_book_snapshot = .{ .instrument = instrumentIdentity(snapshot.instrument), .sequence = sequence, .best_bid = bid, .best_ask = ask },
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
        if (!book.ready or !try applyBid(&book.bid, delta.bids.slice(), delta.instrument, rules) or !try applyAsk(&book.ask, delta.asks.slice(), delta.instrument, rules)) {
            book.ready = false;
            return self.append(output, envelope, instrumentIdentity(delta.instrument), sequence, previous, .{
                .market_data_health_changed = .{ .instrument = instrumentIdentity(delta.instrument), .health = .gap },
            });
        }
        try self.append(output, envelope, instrumentIdentity(delta.instrument), sequence, previous, .{
            .l2_book_delta = .{ .instrument = instrumentIdentity(delta.instrument), .previous_sequence = previous, .sequence = sequence, .best_bid = book.bid, .best_ask = book.ask },
        });
    }

    fn append(self: *OkxMarketFeed, output: *canonical.AdapterOutputBatch, envelope: okx.EventEnvelope, instrument: canonical.InstrumentIdentity, source_sequence: u64, previous: ?u64, event: canonical.CanonicalEvent) !void {
        const config = self.config orelse return error.NotStarted;
        self.next_event_sequence = std.math.add(u64, self.next_event_sequence, 1) catch return error.EventSequenceOverflow;
        try output.append(.{ .envelope = .{
            .event_type = 2,
            .schema_version = 1,
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

fn applyBid(current: *canonical.InstrumentPrice, updates: []const okx.BookLevel, instrument: okx.Instrument, rules: Rules) !bool {
    if (updates.len == 0) return true;
    const update = updates[0];
    const next = try price(instrument, rules, update.price);
    if (update.quantity.coefficient == 0) return next.ticks != current.ticks;
    if (next.ticks >= current.ticks) current.* = next;
    return true;
}

fn applyAsk(current: *canonical.InstrumentPrice, updates: []const okx.BookLevel, instrument: okx.Instrument, rules: Rules) !bool {
    if (updates.len == 0) return true;
    const update = updates[0];
    const next = try price(instrument, rules, update.price);
    if (update.quantity.coefficient == 0) return next.ticks != current.ticks;
    if (next.ticks <= current.ticks) current.* = next;
    return true;
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
