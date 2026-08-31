//! Bybit V5 public-market implementation of the shared MarketFeedAdapter seam.
//! Protocol topics and JSON remain private; only canonical facts leave this file.

const canonical = @import("canonical_event.zig");
const market = @import("market_feed_adapter.zig");
const std = @import("std");

pub const btc_usdt_spot: canonical.InstrumentIdentity = 0x4259_00000001;
pub const btc_usdt_linear: canonical.InstrumentIdentity = 0x4259_00000002;
pub const Instrument = enum(u8) { btc_usdt_spot, btc_usdt_linear };
pub const Times = struct { receive_time_utc_ns: u64, monotonic_time_ns: u64, wall_time_utc_ns: u64 };
pub const RawIngressRecord = struct { source_session: u64, receive_time_utc_ns: u64, monotonic_time_ns: u64, wall_time_utc_ns: u64, byte_len: u32, sha256: [32]u8 };
pub const RawEvidenceRef = struct { stream_sequence: u64, sha256: [32]u8 };
pub const RawSinkError = error{ Unavailable, Backpressure };
pub const RawSink = struct {
    ptr: *anyopaque,
    append_fn: *const fn (*anyopaque, RawIngressRecord, []const u8) RawSinkError!u64,
    pub fn append(self: RawSink, record: RawIngressRecord, bytes: []const u8) RawSinkError!RawEvidenceRef {
        return .{ .stream_sequence = try self.append_fn(self.ptr, record, bytes), .sha256 = record.sha256 };
    }
};

const State = enum { idle, running, stopped };
const BookHealth = enum { awaiting_snapshot, healthy, gap };
const Rules = struct { tick_size: canonical.Decimal, version: u64 };
const Book = struct {
    bid: ?canonical.InstrumentPrice = null,
    ask: ?canonical.InstrumentPrice = null,
    update_id: ?u64 = null,
    health: BookHealth = .awaiting_snapshot,
};

pub const BybitMarketFeed = struct {
    raw_sink: RawSink,
    state: State = .idle,
    config: ?market.Config = null,
    pending: ?canonical.AdapterOutputBatch = null,
    next_event_sequence: u64 = 0,
    rules: [2]?Rules = .{ null, null },
    books: [2]Book = .{ .{}, .{} },

    pub fn init(raw_sink: RawSink) BybitMarketFeed {
        return .{ .raw_sink = raw_sink };
    }
    pub fn adapter(self: *BybitMarketFeed) market.MarketFeedAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_drain = drain, .stop = stop } };
    }
    pub fn ingest(self: *BybitMarketFeed, allocator: std.mem.Allocator, instrument: Instrument, times: Times, frame: []const u8) !void {
        try self.requireRunning();
        const evidence = try self.ingestRaw(times, frame);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, frame, .{}) catch return error.InvalidFrame;
        defer parsed.deinit();
        const root = try asObject(parsed.value);
        var output: canonical.AdapterOutputBatch = .{};
        if (root.get("result") != null) {
            try self.decodeInstruments(&output, instrument, times, evidence, root);
        } else if (root.get("topic")) |topic_value| {
            const topic = try asString(topic_value);
            if (std.mem.startsWith(u8, topic, "orderbook."))
                try self.decodeBook(&output, instrument, times, evidence, root)
            else if (std.mem.startsWith(u8, topic, "tickers."))
                try self.decodeTicker(&output, instrument, times, evidence, root)
            else
                return error.UnsupportedFrame;
        } else return error.UnsupportedFrame;
        if (output.len != 0) try self.queue(output);
    }
    pub fn beginSubscription(self: *BybitMarketFeed, instrument: Instrument, times: Times, frame: []const u8) !void {
        try self.requireRunning();
        const evidence = try self.ingestRaw(times, frame);
        self.books[@intFromEnum(instrument)] = .{};
        var output: canonical.AdapterOutputBatch = .{};
        try self.append(&output, instrument, evidence.stream_sequence, null, null, null, times, evidence, "awaiting_snapshot", .{
            .market_data_health_changed = .{ .instrument = instrumentIdentity(instrument), .health = .awaiting_snapshot },
        });
        try self.queue(output);
    }
    pub fn ingestRaw(self: *BybitMarketFeed, times: Times, frame: []const u8) !RawEvidenceRef {
        const config = self.config orelse return error.NotStarted;
        if (frame.len == 0 or frame.len > std.math.maxInt(u32)) return error.InvalidFrame;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(frame, &digest, .{});
        return self.raw_sink.append(.{
            .source_session = @intCast(config.session),
            .receive_time_utc_ns = times.receive_time_utc_ns,
            .monotonic_time_ns = times.monotonic_time_ns,
            .wall_time_utc_ns = times.wall_time_utc_ns,
            .byte_len = @intCast(frame.len),
            .sha256 = digest,
        }, frame);
    }

    fn start(ptr: *anyopaque, config: market.Config) market.StartError!void {
        const self: *BybitMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.environment != .demo or config.venue == 0 or config.subscription_set == 0 or config.config_version == 0 or config.session == 0 or config.output_capacity < 3) return error.InvalidConfig;
        self.config = config;
        self.state = .running;
    }
    fn drain(ptr: *anyopaque) market.DrainError!?market.MarketEventBatch {
        const self: *BybitMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const pending = self.pending;
        self.pending = null;
        return pending;
    }
    fn stop(ptr: *anyopaque, _: market.DrainDeadline) market.StopError!void {
        const self: *BybitMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.state = .stopped;
    }
    fn requireRunning(self: *const BybitMarketFeed) !void {
        if (self.state != .running) return error.NotStarted;
    }
    fn queue(self: *BybitMarketFeed, output: canonical.AdapterOutputBatch) !void {
        if (self.pending != null) return error.OutputCapacityExceeded;
        self.pending = output;
    }
    fn decodeInstruments(self: *BybitMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, times: Times, evidence: RawEvidenceRef, root: std.json.ObjectMap) !void {
        const result = try asObject(try field(root, "result"));
        const category = try stringField(result, "category");
        if (!categoryMatches(instrument, category)) return error.UnsupportedInstrument;
        const list = try asArray(try field(result, "list"));
        for (list.items) |value| {
            const item = try asObject(value);
            if (!std.mem.eql(u8, try stringField(item, "symbol"), "BTCUSDT")) continue;
            if (!std.mem.eql(u8, try stringField(item, "status"), "Trading")) return error.UnsupportedInstrument;
            if (instrument == .btc_usdt_linear and (!std.mem.eql(u8, try stringField(item, "contractType"), "LinearPerpetual") or !std.mem.eql(u8, try stringField(item, "settleCoin"), "USDT"))) return error.UnsupportedInstrument;
            const price_filter = try asObject(try field(item, "priceFilter"));
            const rules: Rules = .{ .tick_size = try canonical.Decimal.parse(try stringField(price_filter, "tickSize")), .version = (self.config orelse return error.NotStarted).config_version };
            self.rules[@intFromEnum(instrument)] = rules;
            self.books[@intFromEnum(instrument)] = .{};
            try self.append(output, instrument, evidence.stream_sequence, null, null, null, times, evidence, "definition", .{
                .instrument_definition_observed = .{ .instrument = instrumentIdentity(instrument), .rules_version = rules.version },
            });
            return;
        }
        return error.UnsupportedInstrument;
    }
    fn decodeBook(self: *BybitMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, times: Times, evidence: RawEvidenceRef, root: std.json.ObjectMap) !void {
        const data = try asObject(try field(root, "data"));
        if (!std.mem.eql(u8, try stringField(data, "s"), "BTCUSDT")) return error.UnsupportedInstrument;
        const update_id = try uintField(data, "u");
        const cross = optionalUint(data, "seq");
        const source_time = try millisToNs(try uintField(root, "cts"));
        const message_type = try stringField(root, "type");
        const rules = self.rules[@intFromEnum(instrument)] orelse return error.MissingInstrumentRules;
        if (std.mem.eql(u8, message_type, "snapshot")) {
            const bid = try firstPrice(data, "b", instrument, rules);
            const ask = try firstPrice(data, "a", instrument, rules);
            self.books[@intFromEnum(instrument)] = .{ .bid = bid, .ask = ask, .update_id = update_id, .health = .healthy };
            try self.append(output, instrument, update_id, null, cross, source_time, times, evidence, "snapshot", .{ .l2_book_snapshot = .{ .instrument = instrumentIdentity(instrument), .sequence = update_id, .best_bid = bid, .best_ask = ask } });
            try self.append(output, instrument, update_id, null, cross, source_time, times, evidence, "healthy", .{ .market_data_health_changed = .{ .instrument = instrumentIdentity(instrument), .health = .healthy } });
            return;
        }
        if (!std.mem.eql(u8, message_type, "delta")) return error.UnsupportedFrame;
        const book = &self.books[@intFromEnum(instrument)];
        const previous = book.update_id orelse return self.gap(output, instrument, 0, update_id, cross, source_time, times, evidence);
        const required = std.math.add(u64, previous, 1) catch return self.gap(output, instrument, previous, update_id, cross, source_time, times, evidence);
        if (book.health != .healthy or update_id != required) return self.gap(output, instrument, previous, update_id, cross, source_time, times, evidence);
        const bid = try applyBid(book.bid orelse return self.gap(output, instrument, previous, update_id, cross, source_time, times, evidence), try levels(data, "b"), instrument, rules) orelse return self.gap(output, instrument, previous, update_id, cross, source_time, times, evidence);
        const ask = try applyAsk(book.ask orelse return self.gap(output, instrument, previous, update_id, cross, source_time, times, evidence), try levels(data, "a"), instrument, rules) orelse return self.gap(output, instrument, previous, update_id, cross, source_time, times, evidence);
        book.bid = bid;
        book.ask = ask;
        book.update_id = update_id;
        try self.append(output, instrument, update_id, previous, cross, source_time, times, evidence, "delta", .{ .l2_book_delta = .{ .instrument = instrumentIdentity(instrument), .previous_sequence = previous, .sequence = update_id, .best_bid = bid, .best_ask = ask } });
    }
    fn decodeTicker(self: *BybitMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, times: Times, evidence: RawEvidenceRef, root: std.json.ObjectMap) !void {
        if (instrument != .btc_usdt_linear) return error.UnsupportedInstrument;
        const data = try asObject(try field(root, "data"));
        if (!std.mem.eql(u8, try stringField(data, "symbol"), "BTCUSDT")) return error.UnsupportedInstrument;
        const rules = self.rules[@intFromEnum(instrument)] orelse return error.MissingInstrumentRules;
        const source_time = try millisToNs(try uintField(root, "ts"));
        const cross = optionalUint(root, "cs");
        const sequence = evidence.stream_sequence;
        try self.append(output, instrument, sequence, null, cross, source_time, times, evidence, "mark", .{ .reference_price = .{ .instrument = instrumentIdentity(instrument), .kind = .mark, .price = try price(instrument, rules, try canonical.Decimal.parse(try stringField(data, "markPrice"))) } });
        try self.append(output, instrument, sequence, null, cross, source_time, times, evidence, "index", .{ .reference_price = .{ .instrument = instrumentIdentity(instrument), .kind = .index, .price = try price(instrument, rules, try canonical.Decimal.parse(try stringField(data, "indexPrice"))) } });
        const ppm = try (try canonical.Decimal.parse(try stringField(data, "fundingRate"))).exactAtoms(6);
        try self.append(output, instrument, sequence, null, cross, source_time, times, evidence, "funding", .{ .funding_rate_published = .{ .instrument = instrumentIdentity(instrument), .rate_ppm = std.math.cast(i64, ppm) orelse return error.FundingRateOverflow, .funding_time_utc_ns = try millisToNs(try uintOrStringField(data, "nextFundingTime")) } });
    }
    fn gap(self: *BybitMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, previous: u64, observed: u64, cross: ?u64, source_time: u64, times: Times, evidence: RawEvidenceRef) !void {
        const book = &self.books[@intFromEnum(instrument)];
        if (book.health == .gap) return;
        book.* = .{ .health = .gap };
        try self.append(output, instrument, observed, previous, cross, source_time, times, evidence, "gap", .{ .market_data_health_changed = .{ .instrument = instrumentIdentity(instrument), .health = .gap } });
    }
    fn append(self: *BybitMarketFeed, output: *canonical.AdapterOutputBatch, instrument: Instrument, source_sequence: u64, previous_sequence: ?u64, cross_sequence: ?u64, source_time: ?u64, times: Times, evidence: RawEvidenceRef, kind: []const u8, event: canonical.CanonicalEvent) !void {
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
            .source_previous_sequence = previous_sequence,
            .source_cross_sequence = cross_sequence,
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
fn categoryMatches(instrument: Instrument, category: []const u8) bool {
    return std.mem.eql(u8, category, switch (instrument) {
        .btc_usdt_spot => "spot",
        .btc_usdt_linear => "linear",
    });
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
fn asString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidFrame,
    };
}
fn field(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.InvalidFrame;
}
fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return asString(try field(object, name));
}
fn uintField(object: std.json.ObjectMap, name: []const u8) !u64 {
    return switch (try field(object, name)) {
        .integer => |value| std.math.cast(u64, value) orelse error.InvalidFrame,
        else => error.InvalidFrame,
    };
}
fn uintOrStringField(object: std.json.ObjectMap, name: []const u8) !u64 {
    return switch (try field(object, name)) {
        .integer => |value| std.math.cast(u64, value) orelse error.InvalidFrame,
        .string => |text| std.fmt.parseInt(u64, text, 10) catch error.InvalidFrame,
        else => error.InvalidFrame,
    };
}
fn optionalUint(object: std.json.ObjectMap, name: []const u8) ?u64 {
    return if (object.get(name)) |value| switch (value) {
        .integer => |integer| std.math.cast(u64, integer),
        else => null,
    } else null;
}
fn millisToNs(value: u64) !u64 {
    return std.math.mul(u64, value, std.time.ns_per_ms) catch error.InvalidFrame;
}
fn levels(object: std.json.ObjectMap, name: []const u8) ![]const std.json.Value {
    return (try asArray(try field(object, name))).items;
}
fn firstPrice(object: std.json.ObjectMap, name: []const u8, instrument: Instrument, rules: Rules) !canonical.InstrumentPrice {
    const values = try levels(object, name);
    if (values.len == 0) return error.InvalidFrame;
    const pair = try asArray(values[0]);
    if (pair.items.len != 2) return error.InvalidFrame;
    const amount = try canonical.Decimal.parse(try asString(pair.items[1]));
    if (amount.coefficient <= 0) return error.InvalidFrame;
    return price(instrument, rules, try canonical.Decimal.parse(try asString(pair.items[0])));
}
const Level = struct { price: canonical.Decimal, quantity: canonical.Decimal };
fn parseLevels(values: []const std.json.Value, buffer: *[64]Level) ![]const Level {
    if (values.len > buffer.len) return error.InvalidFrame;
    for (values, 0..) |value, index| {
        const pair = try asArray(value);
        if (pair.items.len != 2) return error.InvalidFrame;
        buffer[index] = .{ .price = try canonical.Decimal.parse(try asString(pair.items[0])), .quantity = try canonical.Decimal.parse(try asString(pair.items[1])) };
        if (buffer[index].price.coefficient <= 0 or buffer[index].quantity.coefficient < 0) return error.InvalidFrame;
    }
    return buffer[0..values.len];
}
fn applyBid(current: canonical.InstrumentPrice, values: []const std.json.Value, instrument: Instrument, rules: Rules) !?canonical.InstrumentPrice {
    var storage: [64]Level = undefined;
    var next = current;
    for (try parseLevels(values, &storage)) |update| {
        const next_price = try price(instrument, rules, update.price);
        if (update.quantity.coefficient == 0) {
            if (next_price.ticks == next.ticks) return null;
        } else if (next_price.ticks >= next.ticks) next = next_price;
    }
    return next;
}
fn applyAsk(current: canonical.InstrumentPrice, values: []const std.json.Value, instrument: Instrument, rules: Rules) !?canonical.InstrumentPrice {
    var storage: [64]Level = undefined;
    var next = current;
    for (try parseLevels(values, &storage)) |update| {
        const next_price = try price(instrument, rules, update.price);
        if (update.quantity.coefficient == 0) {
            if (next_price.ticks == next.ticks) return null;
        } else if (next_price.ticks <= next.ticks) next = next_price;
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
    fn sink(self: *TestRawSink) RawSink {
        return .{ .ptr = self, .append_fn = append };
    }
    fn append(ptr: *anyopaque, record: RawIngressRecord, bytes: []const u8) RawSinkError!u64 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &record.sha256)) return error.Unavailable;
        self.append_count += 1;
        return self.append_count;
    }
};
const test_times: Times = .{ .receive_time_utc_ns = 1_800_000_000_000_000_001, .monotonic_time_ns = 10_000_001, .wall_time_utc_ns = 1_800_000_000_000_000_002 };
fn startTest(feed: *BybitMarketFeed) !market.MarketFeedAdapter {
    const adapter = feed.adapter();
    try adapter.start(.{ .venue = 30, .environment = .demo, .subscription_set = 8, .config_version = 7, .session = 6, .output_capacity = 3 });
    return adapter;
}

test "Bybit official public fixtures cross the market seam as shared facts" {
    var sink = TestRawSink{};
    var feed = BybitMarketFeed.init(sink.sink());
    const adapter = try startTest(&feed);
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, "{\"retCode\":0,\"result\":{\"category\":\"spot\",\"list\":[{\"symbol\":\"BTCUSDT\",\"status\":\"Trading\",\"priceFilter\":{\"tickSize\":\"0.10\"}}]}}");
    try std.testing.expectEqual(btc_usdt_spot, (try adapter.tryDrain()).?.events[0].event.instrument_definition_observed.instrument);
    try feed.ingest(std.testing.allocator, .btc_usdt_linear, test_times, "{\"retCode\":0,\"result\":{\"category\":\"linear\",\"list\":[{\"symbol\":\"BTCUSDT\",\"status\":\"Trading\",\"contractType\":\"LinearPerpetual\",\"settleCoin\":\"USDT\",\"priceFilter\":{\"tickSize\":\"0.10\"}}]}}");
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, "{\"topic\":\"orderbook.50.BTCUSDT\",\"type\":\"snapshot\",\"ts\":1800000000100,\"cts\":1800000000099,\"data\":{\"s\":\"BTCUSDT\",\"b\":[[\"50099.90\",\"1\"]],\"a\":[[\"50100.10\",\"2\"]],\"u\":100,\"seq\":1000}}");
    const snapshot = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u64, 100), snapshot.events[0].event.l2_book_snapshot.sequence);
    try std.testing.expectEqual(canonical.MarketDataHealth.healthy, snapshot.events[1].event.market_data_health_changed.health);
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, "{\"topic\":\"orderbook.50.BTCUSDT\",\"type\":\"delta\",\"ts\":1800000000110,\"cts\":1800000000109,\"data\":{\"s\":\"BTCUSDT\",\"b\":[[\"50100.00\",\"1\"]],\"a\":[],\"u\":101,\"seq\":1001}}");
    const delta = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u64, 101), delta.events[0].event.l2_book_delta.sequence);
    try std.testing.expectEqual(@as(u64, 100), delta.events[0].envelope.source_previous_sequence.?);
    try std.testing.expectEqual(@as(u64, 1001), delta.events[0].envelope.source_cross_sequence.?);
    try feed.ingest(std.testing.allocator, .btc_usdt_linear, test_times, "{\"topic\":\"tickers.BTCUSDT\",\"type\":\"snapshot\",\"ts\":1800000000200,\"cs\":2000,\"data\":{\"symbol\":\"BTCUSDT\",\"markPrice\":\"50123.40\",\"indexPrice\":\"50120.10\",\"fundingRate\":\"0.00010000\",\"nextFundingTime\":1800003600000}}");
    const prices = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.ReferencePriceKind.mark, prices.events[0].event.reference_price.kind);
    try std.testing.expectEqual(canonical.ReferencePriceKind.index, prices.events[1].event.reference_price.kind);
    try std.testing.expectEqual(@as(i64, 100), prices.events[2].event.funding_rate_published.rate_ppm);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "Bybit gap and subscription reset require a fresh snapshot" {
    var sink = TestRawSink{};
    var feed = BybitMarketFeed.init(sink.sink());
    const adapter = try startTest(&feed);
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, "{\"retCode\":0,\"result\":{\"category\":\"spot\",\"list\":[{\"symbol\":\"BTCUSDT\",\"status\":\"Trading\",\"priceFilter\":{\"tickSize\":\"0.10\"}}]}}");
    _ = try adapter.tryDrain();
    const snapshot = "{\"topic\":\"orderbook.50.BTCUSDT\",\"type\":\"snapshot\",\"ts\":1800000000100,\"cts\":1800000000099,\"data\":{\"s\":\"BTCUSDT\",\"b\":[[\"50099.90\",\"1\"]],\"a\":[[\"50100.10\",\"2\"]],\"u\":100,\"seq\":1000}}";
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, snapshot);
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, "{\"topic\":\"orderbook.50.BTCUSDT\",\"type\":\"delta\",\"ts\":1800000000110,\"cts\":1800000000109,\"data\":{\"s\":\"BTCUSDT\",\"b\":[],\"a\":[],\"u\":103,\"seq\":1003}}");
    try std.testing.expectEqual(canonical.MarketDataHealth.gap, (try adapter.tryDrain()).?.events[0].event.market_data_health_changed.health);
    try feed.beginSubscription(.btc_usdt_spot, test_times, "{\"success\":true,\"op\":\"subscribe\"}");
    try std.testing.expectEqual(canonical.MarketDataHealth.awaiting_snapshot, (try adapter.tryDrain()).?.events[0].event.market_data_health_changed.health);
    try feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, snapshot);
    try std.testing.expectEqual(canonical.MarketDataHealth.healthy, (try adapter.tryDrain()).?.events[1].event.market_data_health_changed.health);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "Bybit implementation obeys the shared lifecycle and raw-first contract" {
    var sink = TestRawSink{};
    var feed = BybitMarketFeed.init(sink.sink());
    const adapter = feed.adapter();
    try std.testing.expectError(error.InvalidConfig, adapter.start(.{ .venue = 30, .environment = .demo, .subscription_set = 8, .config_version = 7, .session = 6, .output_capacity = 2 }));
    try market.testStartupContract(adapter, .{ .venue = 30, .environment = .demo, .subscription_set = 8, .config_version = 7, .session = 6, .output_capacity = 3 });
    try std.testing.expectError(error.InvalidFrame, feed.ingest(std.testing.allocator, .btc_usdt_spot, test_times, "not json"));
    try std.testing.expectEqual(@as(u64, 1), sink.append_count);
    try feed.beginSubscription(.btc_usdt_spot, test_times, "{\"success\":true}");
    try std.testing.expectError(error.OutputPending, adapter.stop(.{ .monotonic_ns = 1 }));
    _ = try adapter.tryDrain();
    try adapter.stop(.{ .monotonic_ns = 1 });
}
