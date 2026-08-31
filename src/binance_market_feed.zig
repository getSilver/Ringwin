//! Binance public-market implementation of the shared MarketFeedAdapter seam.
//!
//! Complete frames are persisted before parsing. Venue JSON is consumed here;
//! only stable canonical facts are emitted to the rest of Ringwin.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const market = @import("market_feed_adapter.zig");
const raw = @import("binance_public_market.zig");

pub const Instrument = enum(u8) { btc_usdt_spot, btc_usdt_linear };
pub const btc_usdt_spot: canonical.InstrumentIdentity = 0x424e_00000001;
pub const btc_usdt_linear: canonical.InstrumentIdentity = 0x424e_00000002;

const State = enum { idle, running, stopped };
const BookHealth = enum { awaiting_snapshot, healthy, gap };
const Rules = struct { tick_size: canonical.Decimal, version: u64 };
const BookTop = struct {
    bid: ?canonical.InstrumentPrice = null,
    ask: ?canonical.InstrumentPrice = null,
    last_update_id: ?u64 = null,
    health: BookHealth = .awaiting_snapshot,
};
const Level = struct { price: canonical.Decimal, quantity: canonical.Decimal };

pub const BinanceMarketFeed = struct {
    raw_sink: raw.RawSink,
    state: State = .idle,
    config: ?market.Config = null,
    pending: ?canonical.AdapterOutputBatch = null,
    next_event_sequence: u64 = 0,
    rules: [2]?Rules = .{ null, null },
    books: [2]BookTop = .{ .{}, .{} },

    pub fn init(raw_sink: raw.RawSink) BinanceMarketFeed {
        return .{ .raw_sink = raw_sink };
    }

    pub fn adapter(self: *BinanceMarketFeed) market.MarketFeedAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_drain = drain, .stop = stop } };
    }

    /// `instrument` is bound by the subscribed WebSocket or REST endpoint.
    /// It disambiguates the identical BTCUSDT code on spot and USD-M streams.
    pub fn ingest(self: *BinanceMarketFeed, allocator: std.mem.Allocator, instrument: Instrument, times: raw.Times, frame: []const u8) !void {
        try self.requireRunning();
        if (self.pending != null) return error.OutputPending;
        const evidence = try self.ingestRaw(times, frame);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, frame, .{}) catch return error.InvalidFrame;
        defer parsed.deinit();
        var output: canonical.AdapterOutputBatch = .{};
        try self.decode(&output, instrument, times, evidence, try asObject(parsed.value));
        if (output.len != 0) self.pending = output;
    }

    /// The control acknowledgement is external evidence for a subscription
    /// reset; deltas stay blocked until a later REST snapshot is accepted.
    pub fn beginSubscription(self: *BinanceMarketFeed, instrument: Instrument, times: raw.Times, frame: []const u8) !void {
        try self.requireRunning();
        if (self.pending != null) return error.OutputPending;
        const evidence = try self.ingestRaw(times, frame);
        var output: canonical.AdapterOutputBatch = .{};
        self.books[@intFromEnum(instrument)] = .{};
        try self.append(&output, instrument, evidence.stream_sequence, null, null, times, evidence, "resubscribe", .{
            .market_data_health_changed = .{ .instrument = instrumentIdentity(instrument), .health = .awaiting_snapshot },
        });
        self.pending = output;
    }

    /// Commits each complete frame before any field interpretation or mutation.
    pub fn ingestRaw(self: *BinanceMarketFeed, times: raw.Times, frame: []const u8) !raw.RawEvidenceRef {
        try self.requireRunning();
        if (frame.len == 0 or frame.len > raw.max_raw_frame_bytes or frame.len > std.math.maxInt(u32)) return error.InvalidFrame;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(frame, &digest, .{});
        return self.raw_sink.append(.{
            .source_session = try self.sourceSession(),
            .receive_time_utc_ns = times.receive_time_utc_ns,
            .monotonic_time_ns = times.monotonic_time_ns,
            .wall_time_utc_ns = times.wall_time_utc_ns,
            .byte_len = @intCast(frame.len),
            .sha256 = digest,
        }, frame);
    }

    fn start(ptr: *anyopaque, config: market.Config) market.StartError!void {
        const self: *BinanceMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.environment != .demo or config.venue == 0 or config.subscription_set == 0 or config.session == 0 or
            config.session > std.math.maxInt(u64) or config.output_capacity < 3 or config.output_capacity > canonical.max_events_per_adapter_batch)
            return error.InvalidConfig;
        self.config = config;
        self.state = .running;
    }

    fn drain(ptr: *anyopaque) market.DrainError!?canonical.AdapterOutputBatch {
        const self: *BinanceMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const pending = self.pending;
        self.pending = null;
        return pending;
    }

    fn stop(ptr: *anyopaque, _: market.DrainDeadline) market.StopError!void {
        const self: *BinanceMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.state = .stopped;
    }

    fn requireRunning(self: *const BinanceMarketFeed) !void {
        return switch (self.state) {
            .idle => error.NotStarted,
            .stopped => error.Stopped,
            .running => {},
        };
    }

    fn sourceSession(self: *const BinanceMarketFeed) !u64 {
        return @intCast((self.config orelse return error.NotStarted).session);
    }

    fn decode(self: *BinanceMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, times: raw.Times, evidence: raw.RawEvidenceRef, object: std.json.ObjectMap) !void {
        if (object.get("symbols") != null) return self.decodeExchangeInfo(output, instrument, times, evidence, object);
        if (object.get("lastUpdateId") != null) return self.decodeSnapshot(output, instrument, times, evidence, object);
        const event = try stringField(object, "e");
        if (std.mem.eql(u8, event, "depthUpdate")) return self.decodeDepth(output, instrument, times, evidence, object);
        if (std.mem.eql(u8, event, "markPriceUpdate")) return self.decodeMarkPrice(output, instrument, times, evidence, object);
        return error.UnsupportedFrame;
    }

    fn decodeExchangeInfo(self: *BinanceMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, times: raw.Times, evidence: raw.RawEvidenceRef, object: std.json.ObjectMap) !void {
        const symbols = try asArray(try objectField(object, "symbols"));
        for (symbols.items) |value| {
            const symbol = try asObject(value);
            if (!std.mem.eql(u8, try stringField(symbol, "symbol"), "BTCUSDT")) continue;
            if (!std.mem.eql(u8, try stringField(symbol, "status"), "TRADING")) return error.UnsupportedInstrument;
            if (instrument == .btc_usdt_linear and
                (!std.mem.eql(u8, try stringField(symbol, "contractType"), "PERPETUAL") or
                    !std.mem.eql(u8, try stringField(symbol, "marginAsset"), "USDT"))) return error.UnsupportedInstrument;
            const rules: Rules = .{ .tick_size = try tickSize(symbol), .version = (self.config orelse return error.NotStarted).config_version };
            self.rules[@intFromEnum(instrument)] = rules;
            self.books[@intFromEnum(instrument)] = .{};
            try self.append(output, instrument, evidence.stream_sequence, null, null, times, evidence, "definition", .{
                .instrument_definition_observed = .{ .instrument = instrumentIdentity(instrument), .rules_version = rules.version },
            });
            return;
        }
        return error.UnsupportedInstrument;
    }

    fn decodeSnapshot(self: *BinanceMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, times: raw.Times, evidence: raw.RawEvidenceRef, object: std.json.ObjectMap) !void {
        const rules = self.rules[@intFromEnum(instrument)] orelse return error.MissingInstrumentRules;
        const update_id = try uintField(object, "lastUpdateId");
        const bid = try price(instrument, rules, try firstLevel(object, "bids"));
        const ask = try price(instrument, rules, try firstLevel(object, "asks"));
        self.books[@intFromEnum(instrument)] = .{ .bid = bid, .ask = ask, .last_update_id = update_id, .health = .healthy };
        try self.append(output, instrument, update_id, null, null, times, evidence, "snapshot", .{
            .l2_book_snapshot = .{ .instrument = instrumentIdentity(instrument), .sequence = update_id, .best_bid = bid, .best_ask = ask },
        });
        try self.append(output, instrument, update_id, null, null, times, evidence, "healthy", .{
            .market_data_health_changed = .{ .instrument = instrumentIdentity(instrument), .health = .healthy },
        });
    }

    fn decodeDepth(self: *BinanceMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, times: raw.Times, evidence: raw.RawEvidenceRef, object: std.json.ObjectMap) !void {
        try expectSymbol(object);
        const first = try uintField(object, "U");
        const last = try uintField(object, "u");
        const source_time = try millisToNs(try uintField(object, "E"));
        var book = &self.books[@intFromEnum(instrument)];
        const previous = book.last_update_id orelse return;
        const required = std.math.add(u64, previous, 1) catch return self.gap(output, instrument, previous, last, source_time, times, evidence);
        if (book.health != .healthy or first > required or last < required) return self.gap(output, instrument, previous, last, source_time, times, evidence);
        if (last <= previous) return;
        const rules = self.rules[@intFromEnum(instrument)] orelse return error.MissingInstrumentRules;
        const bid = try applyBid(book.bid orelse return self.gap(output, instrument, previous, last, source_time, times, evidence), try levels(object, "b"), instrument, rules) orelse
            return self.gap(output, instrument, previous, last, source_time, times, evidence);
        const ask = try applyAsk(book.ask orelse return self.gap(output, instrument, previous, last, source_time, times, evidence), try levels(object, "a"), instrument, rules) orelse
            return self.gap(output, instrument, previous, last, source_time, times, evidence);
        book.bid = bid;
        book.ask = ask;
        book.last_update_id = last;
        try self.append(output, instrument, last, previous, source_time, times, evidence, "delta", .{
            .l2_book_delta = .{ .instrument = instrumentIdentity(instrument), .previous_sequence = previous, .sequence = last, .best_bid = bid, .best_ask = ask },
        });
    }

    fn decodeMarkPrice(self: *BinanceMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, times: raw.Times, evidence: raw.RawEvidenceRef, object: std.json.ObjectMap) !void {
        if (instrument != .btc_usdt_linear) return error.UnsupportedInstrument;
        try expectSymbol(object);
        const rules = self.rules[@intFromEnum(instrument)] orelse return error.MissingInstrumentRules;
        const source_time = try millisToNs(try uintField(object, "E"));
        const sequence = evidence.stream_sequence;
        try self.append(output, instrument, sequence, null, source_time, times, evidence, "mark", .{
            .reference_price = .{ .instrument = instrumentIdentity(instrument), .kind = .mark, .price = try price(instrument, rules, try decimalField(object, "p")) },
        });
        try self.append(output, instrument, sequence, null, source_time, times, evidence, "index", .{
            .reference_price = .{ .instrument = instrumentIdentity(instrument), .kind = .index, .price = try price(instrument, rules, try decimalField(object, "i")) },
        });
        const ppm = try (try decimalField(object, "r")).exactAtoms(6);
        try self.append(output, instrument, sequence, null, source_time, times, evidence, "funding", .{
            .funding_rate_published = .{ .instrument = instrumentIdentity(instrument), .rate_ppm = std.math.cast(i64, ppm) orelse return error.FundingRateOverflow, .funding_time_utc_ns = try millisToNs(try uintField(object, "T")) },
        });
    }

    fn gap(self: *BinanceMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, previous: u64, observed: u64, source_time: ?u64, times: raw.Times, evidence: raw.RawEvidenceRef) !void {
        var book = &self.books[@intFromEnum(instrument)];
        if (book.health == .gap) return;
        book.health = .gap;
        book.last_update_id = null;
        try self.append(output, instrument, observed, previous, source_time, times, evidence, "gap", .{
            .market_data_health_changed = .{ .instrument = instrumentIdentity(instrument), .health = .gap },
        });
    }

    fn append(self: *BinanceMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, source_sequence: u64, previous: ?u64, source_time: ?u64, times: raw.Times, evidence: raw.RawEvidenceRef, kind: []const u8, event: canonical.CanonicalEvent) !void {
        const config = self.config orelse return error.NotStarted;
        if (output.len >= config.output_capacity) return error.OutputCapacityExceeded;
        self.next_event_sequence = std.math.add(u64, self.next_event_sequence, 1) catch return error.EventSequenceOverflow;
        try output.append(.{ .envelope = .{
            .event_type = @intFromEnum(canonical.eventType(event)),
            .schema_version = 1,
            .identity = .{ .stream = config.session, .sequence = self.next_event_sequence },
            .source_fact_identity = sourceFactIdentity(evidence.sha256, kind),
            .scope = .instrument,
            .venue = config.venue,
            .instrument = instrumentIdentity(instrument),
            .source_stream = config.subscription_set,
            .source_sequence = source_sequence,
            .source_previous_sequence = previous,
            .adapter_session = config.session,
            .times = .{ .source_utc_ns = source_time, .receive_utc_ns = times.receive_time_utc_ns, .monotonic_ns = times.monotonic_time_ns, .audit_utc_ns = times.wall_time_utc_ns },
            .raw_evidence = .{ .stream = config.subscription_set, .sequence = evidence.stream_sequence, .digest = evidence.sha256 },
        }, .event = event });
    }
};

fn instrumentIdentity(instrument: Instrument) canonical.InstrumentIdentity {
    return switch (instrument) {
        .btc_usdt_spot => btc_usdt_spot,
        .btc_usdt_linear => btc_usdt_linear,
    };
}

fn price(instrument: Instrument, rules: Rules, value: canonical.Decimal) !canonical.InstrumentPrice {
    return canonical.InstrumentPrice.fromDecimal(instrumentIdentity(instrument), rules.version, value, rules.tick_size.scale, try rules.tick_size.exactAtoms(rules.tick_size.scale));
}

fn asObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidFrame,
    };
}
fn asArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.InvalidFrame,
    };
}
fn objectField(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.InvalidFrame;
}
fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (try objectField(object, name)) {
        .string => |text| text,
        else => error.InvalidFrame,
    };
}
fn uintField(object: std.json.ObjectMap, name: []const u8) !u64 {
    return switch (try objectField(object, name)) {
        .integer => |value| std.math.cast(u64, value) orelse error.InvalidFrame,
        else => error.InvalidFrame,
    };
}
fn decimalField(object: std.json.ObjectMap, name: []const u8) !canonical.Decimal {
    return canonical.Decimal.parse(try stringField(object, name));
}
fn millisToNs(value: u64) !u64 {
    return std.math.mul(u64, value, std.time.ns_per_ms) catch error.InvalidFrame;
}
fn expectSymbol(object: std.json.ObjectMap) !void {
    if (!std.mem.eql(u8, try stringField(object, "s"), "BTCUSDT")) return error.UnsupportedInstrument;
}
fn tickSize(symbol: std.json.ObjectMap) !canonical.Decimal {
    const filters = try asArray(try objectField(symbol, "filters"));
    for (filters.items) |value| {
        const filter = try asObject(value);
        if (std.mem.eql(u8, try stringField(filter, "filterType"), "PRICE_FILTER")) return decimalField(filter, "tickSize");
    }
    return error.InvalidFrame;
}
fn levels(object: std.json.ObjectMap, name: []const u8) ![]const std.json.Value {
    return (try asArray(try objectField(object, name))).items;
}
fn firstLevel(object: std.json.ObjectMap, name: []const u8) !canonical.Decimal {
    const updates = try levels(object, name);
    if (updates.len == 0) return error.InvalidFrame;
    const pair = try asArray(updates[0]);
    if (pair.items.len != 2) return error.InvalidFrame;
    const level = try decimalValue(pair.items[0]);
    const quantity = try decimalValue(pair.items[1]);
    if (level.coefficient <= 0 or quantity.coefficient <= 0) return error.InvalidFrame;
    return level;
}
fn parseLevels(values: []const std.json.Value, buffer: *[64]Level) ![]const Level {
    if (values.len > buffer.len) return error.InvalidFrame;
    for (values, 0..) |value, index| {
        const pair = try asArray(value);
        if (pair.items.len != 2) return error.InvalidFrame;
        buffer[index] = .{ .price = try decimalValue(pair.items[0]), .quantity = try decimalValue(pair.items[1]) };
        if (buffer[index].price.coefficient <= 0 or buffer[index].quantity.coefficient < 0) return error.InvalidFrame;
    }
    return buffer[0..values.len];
}
fn decimalValue(value: std.json.Value) !canonical.Decimal {
    return switch (value) {
        .string => |text| canonical.Decimal.parse(text),
        else => error.InvalidFrame,
    };
}
fn applyBid(current: canonical.InstrumentPrice, updates: []const std.json.Value, instrument: Instrument, rules: Rules) !?canonical.InstrumentPrice {
    var storage: [64]Level = undefined;
    var next = current;
    for (try parseLevels(updates, &storage)) |update| {
        const price_value = try price(instrument, rules, update.price);
        if (update.quantity.coefficient == 0) {
            if (price_value.ticks == next.ticks) return null;
        } else if (price_value.ticks >= next.ticks) next = price_value;
    }
    return next;
}
fn applyAsk(current: canonical.InstrumentPrice, updates: []const std.json.Value, instrument: Instrument, rules: Rules) !?canonical.InstrumentPrice {
    var storage: [64]Level = undefined;
    var next = current;
    for (try parseLevels(updates, &storage)) |update| {
        const price_value = try price(instrument, rules, update.price);
        if (update.quantity.coefficient == 0) {
            if (price_value.ticks == next.ticks) return null;
        } else if (price_value.ticks <= next.ticks) next = price_value;
    }
    return next;
}
fn sourceFactIdentity(digest: [32]u8, kind: []const u8) u128 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&digest);
    hasher.update(kind);
    const result = hasher.finalResult();
    return std.mem.readInt(u128, result[0..16], .little);
}

const TestRawSink = struct {
    append_count: u64 = 0,
    fn sink(self: *TestRawSink) raw.RawSink {
        return .{ .ptr = self, .append_fn = append };
    }
    fn append(ptr: *anyopaque, record: raw.RawIngressRecord, bytes: []const u8) raw.RawSinkError!u64 {
        const self: *TestRawSink = @ptrCast(@alignCast(ptr));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &record.sha256)) return error.Unavailable;
        self.append_count += 1;
        return self.append_count;
    }
};
const test_times: raw.Times = .{ .receive_time_utc_ns = 1_800_000_000_000_000_001, .monotonic_time_ns = 10_000_001, .wall_time_utc_ns = 1_800_000_000_000_000_002 };
fn startTest(feed: *BinanceMarketFeed) !market.MarketFeedAdapter {
    const adapter = feed.adapter();
    try adapter.start(.{ .venue = 20, .environment = .demo, .subscription_set = 8, .config_version = 7, .session = 6, .output_capacity = 3 });
    return adapter;
}

// Fixtures use the documented Spot depth and USD-M mark-price field shapes.
test "Binance official public fixtures cross the market seam as shared facts" {
    var sink = TestRawSink{};
    var feed = BinanceMarketFeed.init(sink.sink());
    const adapter = try startTest(&feed);
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times,
        \\{"symbols":[{"symbol":"BTCUSDT","status":"TRADING","filters":[{"filterType":"PRICE_FILTER","tickSize":"0.10"}]}]}
    );
    const spot_definition = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(btc_usdt_spot, spot_definition.events[0].event.instrument_definition_observed.instrument);
    try std.testing.expectEqual(@as(u64, 7), spot_definition.events[0].event.instrument_definition_observed.rules_version);
    try feed.ingest(std.testing.allocator, .btc_usdt_linear, test_times,
        \\{"symbols":[{"symbol":"BTCUSDT","status":"TRADING","contractType":"PERPETUAL","marginAsset":"USDT","filters":[{"filterType":"PRICE_FILTER","tickSize":"0.10"}]}]}
    );
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times,
        \\{"lastUpdateId":100,"bids":[["50099.90","1"]],"asks":[["50100.10","2"]]}
    );
    const snapshot = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u64, 100), snapshot.events[0].event.l2_book_snapshot.sequence);
    try std.testing.expectEqual(canonical.MarketDataHealth.healthy, snapshot.events[1].event.market_data_health_changed.health);
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times,
        \\{"e":"depthUpdate","E":1800000000100,"s":"BTCUSDT","U":101,"u":101,"b":[["50100.00","1"]],"a":[]}
    );
    const delta = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u64, 101), delta.events[0].event.l2_book_delta.sequence);
    try std.testing.expectEqual(@as(u128, 8), delta.events[0].envelope.source_stream);
    try std.testing.expectEqual(@as(u64, 4), delta.events[0].envelope.raw_evidence.sequence);
    try feed.ingest(std.testing.allocator, .btc_usdt_linear, test_times,
        \\{"lastUpdateId":200,"bids":[["50099.90","1"]],"asks":[["50100.10","2"]]}
    );
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, .btc_usdt_linear, test_times,
        \\{"e":"depthUpdate","E":1800000000100,"s":"BTCUSDT","U":201,"u":201,"b":[["50100.00","1"]],"a":[]}
    );
    const linear_delta = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(btc_usdt_linear, linear_delta.events[0].event.l2_book_delta.instrument);
    try feed.ingest(std.testing.allocator, .btc_usdt_linear, test_times,
        \\{"e":"markPriceUpdate","E":1800000000100,"s":"BTCUSDT","p":"50123.40","i":"50120.10","r":"0.00010000","T":1800003600000}
    );
    const prices = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.ReferencePriceKind.mark, prices.events[0].event.reference_price.kind);
    try std.testing.expectEqual(canonical.ReferencePriceKind.index, prices.events[1].event.reference_price.kind);
    try std.testing.expectEqual(@as(i64, 100), prices.events[2].event.funding_rate_published.rate_ppm);
    try std.testing.expectEqual(@as(u64, 7), sink.append_count);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "Binance L2 gap and subscription reset require a fresh snapshot" {
    var sink = TestRawSink{};
    var feed = BinanceMarketFeed.init(sink.sink());
    const adapter = try startTest(&feed);
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times,
        \\{"symbols":[{"symbol":"BTCUSDT","status":"TRADING","filters":[{"filterType":"PRICE_FILTER","tickSize":"0.10"}]}]}
    );
    _ = try adapter.tryDrain();
    const snapshot =
        \\{"lastUpdateId":100,"bids":[["50099.90","1"]],"asks":[["50100.10","2"]]}
    ;
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, snapshot);
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times,
        \\{"e":"depthUpdate","E":1800000000100,"s":"BTCUSDT","U":103,"u":103,"b":[],"a":[]}
    );
    const gap = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.MarketDataHealth.gap, gap.events[0].event.market_data_health_changed.health);
    try feed.beginSubscription(.btc_usdt_spot, test_times, "{\"result\":null,\"id\":1}");
    const awaiting = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.MarketDataHealth.awaiting_snapshot, awaiting.events[0].event.market_data_health_changed.health);
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, snapshot);
    const recovered = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.MarketDataHealth.healthy, recovered.events[1].event.market_data_health_changed.health);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "Binance implementation obeys the shared lifecycle and raw-first contract" {
    var sink = TestRawSink{};
    var feed = BinanceMarketFeed.init(sink.sink());
    const adapter = feed.adapter();
    try std.testing.expectError(error.InvalidConfig, adapter.start(.{ .venue = 20, .environment = .demo, .subscription_set = 8, .config_version = 7, .session = 6, .output_capacity = 2 }));
    try market.testStartupContract(adapter, .{ .venue = 20, .environment = .demo, .subscription_set = 8, .config_version = 7, .session = 6, .output_capacity = 3 });
    try std.testing.expectError(error.InvalidFrame, feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, "not json"));
    try std.testing.expectEqual(@as(u64, 1), sink.append_count);
    try feed.beginSubscription(.btc_usdt_spot, test_times, "{\"result\":null,\"id\":1}");
    try std.testing.expectError(error.OutputPending, adapter.stop(.{ .monotonic_ns = 1 }));
    _ = try adapter.tryDrain();
    try adapter.stop(.{ .monotonic_ns = 1 });
}
