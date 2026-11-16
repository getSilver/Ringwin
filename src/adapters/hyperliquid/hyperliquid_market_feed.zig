//! Bounded, transport-injected public feed. No account, credentials, or send authority.
const std = @import("std");
const c = @import("../../model/canonical_event.zig");
const market = @import("../../market/market_feed_adapter.zig");
const depth_contract = @import("../../market/depth_snapshot.zig");

pub const max_frame_bytes = 1024 * 1024;
pub const max_trades = 30;
pub const Times = struct { receive_time_utc_ns: u64, monotonic_time_ns: u64, wall_time_utc_ns: u64 };
pub const Input = enum { metadata, book, trades, context, funding_history, subscribe, disconnected, expired };
/// All identities/units are supplied by configuration; observation cannot activate them.
pub const Binding = struct {
    instrument: c.InstrumentIdentity,
    coin: []const u8,
    product: c.Product,
    universe_index: u32,
    base_token: u32 = 0,
    quote_token: u32 = 0,
    base_token_id: []const u8 = "",
    quote_token_id: []const u8 = "",
    size_decimals: u8,
    rules_version: u64,
    expected_metadata_digest: [32]u8,
    price_scale: u8,
    tick_atoms: i128,
    quantity_scale: u8,
    lot_atoms: i128,
    max_age_ns: u64 = 5_000_000_000,
};
pub const RawRecord = struct {
    venue: c.VenueIdentity,
    environment: market.Environment,
    stream: u128,
    session: u128,
    epoch: u64,
    input: Input,
    instrument: u128,
    times: Times,
    byte_len: u32,
    sha256: [32]u8,
};
pub const RawError = error{ Unavailable, Backpressure };
pub const RawSink = struct {
    ptr: *anyopaque,
    append_fn: *const fn (*anyopaque, RawRecord, []const u8) RawError!u64,
};
pub const Evidence = struct { sequence: u64, digest: [32]u8 };
pub const PerpetualSpecification = struct {
    coin: []const u8,
    price_quote: enum { USDT, USDC },
    universe_index: u32,
    size_decimals: u8,
    metadata_digest: [32]u8,
};

/// Standard perp metadata only; a coin label never establishes cross-venue asset equivalence.
pub fn perpetualSpecification(allocator: std.mem.Allocator, value: std.json.Value, index: u32, collateral: u32) !PerpetualSpecification {
    const root = try object(value);
    const universe = try array(try field(root, "universe"));
    if (index >= universe.items.len) return error.UnsupportedInstrument;
    const row = try object(universe.items[index]);
    const coin = try string(try field(row, "name"));
    if (coin.len == 0 or coin.len > 64) return error.UnsupportedInstrument;
    for (coin) |byte| if (byte < 33 or byte > 126 or byte == '"' or byte == '\\' or byte == ':') return error.UnsupportedInstrument;
    if (try uint(try field(root, "collateralToken")) != collateral) return error.UnsupportedCollateral;
    if (try uint(try field(row, "maxLeverage")) == 0) return error.UnsupportedInstrument;
    if (row.get("isDelisted")) |delisted| if (delisted != .bool or delisted.bool) return error.UnsupportedInstrument;
    const size = try uint(try field(row, "szDecimals"));
    if (size > 6) return error.UnsupportedDecimalUnits;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    try hashValue(allocator, &hash, .{ .object = row });
    const table_id = try uint(try field(row, "marginTableId"));
    var found = false;
    for ((try array(try field(root, "marginTables"))).items) |item| {
        const pair = try array(item);
        if (pair.items.len != 2) return error.InvalidFrame;
        if (try uint(pair.items[0]) == table_id) {
            if (found) return error.DuplicateMarginTable;
            _ = try object(pair.items[1]);
            try hashValue(allocator, &hash, item);
            found = true;
        }
    }
    if (!found) return error.MissingMarginTable;
    // Official standard-perp contract specifications distinguish these USDC price indices.
    const price_quote: @FieldType(PerpetualSpecification, "price_quote") = if (std.mem.eql(u8, coin, "HYPE") or std.mem.eql(u8, coin, "PURR")) .USDC else .USDT;
    return .{ .coin = coin, .price_quote = price_quote, .universe_index = index, .size_decimals = @intCast(size), .metadata_digest = hash.finalResult() };
}
const TradeKey = struct { time: u64, tid: u64, trade: c.MarketTrade };

pub const HyperliquidMarketFeed = struct {
    binding: Binding,
    raw_sink: RawSink,
    state: enum { idle, running, stopped } = .idle,
    config: ?market.Config = null,
    pending: ?c.AdapterOutputBatch = null,
    epoch: u64,
    subscribed: bool = false,
    observed: bool = false,
    health: c.MarketDataHealth = .awaiting_snapshot,
    barrier: Times = .{ .receive_time_utc_ns = 0, .monotonic_time_ns = 0, .wall_time_utc_ns = 0 },
    last_book_time: u64 = 0,
    last_book_monotonic: u64 = 0,
    last_book: ?c.L2BookSnapshot = null,
    event_sequence: u64 = 0,
    raw_sequence: u64 = 0,
    seen: [256]TradeKey = undefined,
    seen_count: usize = 0,
    // shortcut: retain 256 tape identities; older unknown trades revoke coverage instead of being reapplied.
    retired_trade_time: u64 = 0,

    /// restored_epoch is a durable high-water mark owned by the runtime, never guessed here.
    pub fn init(binding: Binding, raw_sink: RawSink, restored_epoch: u64) HyperliquidMarketFeed {
        return .{ .binding = binding, .raw_sink = raw_sink, .epoch = restored_epoch };
    }
    pub fn adapter(self: *HyperliquidMarketFeed) market.MarketFeedAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_drain = drain, .stop = stop } };
    }
    /// Transport sends at most these three requests per incarnation; no aggregated price levels.
    pub fn subscription(self: *const HyperliquidMarketFeed, input: Input, destination: []u8) ![]const u8 {
        if (self.state != .running) return error.NotStarted;
        const channel = switch (input) {
            .book => "l2Book",
            .trades => "trades",
            .context => if (self.binding.product == .isolated_linear) "activeAssetCtx" else return error.UnsupportedFrame,
            else => return error.UnsupportedFrame,
        };
        return std.fmt.bufPrint(destination, "{{\"method\":\"subscribe\",\"subscription\":{{\"type\":\"{s}\",\"coin\":\"{s}\"}}}}", .{ channel, self.binding.coin });
    }
    /// Runtime drives this bounded timer independently for each source, including while output is pending.
    pub fn poll(self: *HyperliquidMarketFeed, allocator: std.mem.Allocator, times: Times) !void {
        if (self.state != .running) return error.NotStarted;
        if (self.health != .healthy) return;
        if (times.monotonic_time_ns < self.last_book_monotonic or times.monotonic_time_ns - self.last_book_monotonic > self.binding.max_age_ns)
            try self.capture(allocator, self.epoch, .expired, times, "{\"event\":\"expired\"}");
    }
    fn ready(self: *const HyperliquidMarketFeed) !void {
        if (self.state != .running) return error.NotStarted;
        if (self.pending != null) return error.OutputCapacityExceeded;
    }
    pub fn ingest(self: *HyperliquidMarketFeed, allocator: std.mem.Allocator, epoch: u64, input: Input, times: Times, bytes: []const u8) !void {
        if (input == .disconnected or input == .expired) {
            if (self.state != .running) return error.NotStarted;
        } else try self.ready();
        try self.capture(allocator, epoch, input, times, bytes);
    }
    fn capture(self: *HyperliquidMarketFeed, allocator: std.mem.Allocator, epoch: u64, input: Input, times: Times, bytes: []const u8) !void {
        if (bytes.len > max_frame_bytes + 1) {
            try self.invalidate(times, .{ .sequence = 0, .digest = @splat(0) });
            return error.FrameTooLarge;
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const sequence = self.raw_sink.append_fn(self.raw_sink.ptr, .{
            .venue = self.config.?.venue,
            .environment = self.config.?.environment,
            .stream = self.config.?.subscription_set,
            .session = self.config.?.session,
            .epoch = epoch,
            .input = input,
            .instrument = self.binding.instrument,
            .times = times,
            .byte_len = @intCast(bytes.len),
            .sha256 = digest,
        }, bytes) catch |err| {
            // No raw evidence exists for a capture failure; publish only local safety invalidation.
            try self.invalidate(times, .{ .sequence = 0, .digest = @splat(0) });
            return err;
        };
        try self.process(allocator, epoch, input, times, .{ .sequence = sequence, .digest = digest }, bytes);
    }
    pub fn replay(self: *HyperliquidMarketFeed, allocator: std.mem.Allocator, record: RawRecord, evidence: Evidence, bytes: []const u8) !void {
        if (record.input == .disconnected or record.input == .expired) {
            if (self.state != .running) return error.NotStarted;
        } else try self.ready();
        if (bytes.len > max_frame_bytes + 1) return error.FrameTooLarge;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (record.venue != self.config.?.venue or record.environment != self.config.?.environment or
            record.stream != self.config.?.subscription_set or record.session != self.config.?.session or record.instrument != self.binding.instrument or
            record.byte_len != bytes.len or !std.mem.eql(u8, &digest, &record.sha256) or
            !std.mem.eql(u8, &digest, &evidence.digest)) return error.InvalidRawEvidence;
        try self.process(allocator, record.epoch, record.input, record.times, evidence, bytes);
    }
    fn process(self: *HyperliquidMarketFeed, allocator: std.mem.Allocator, epoch: u64, input: Input, times: Times, evidence: Evidence, bytes: []const u8) !void {
        if (evidence.sequence == 0 or evidence.sequence <= self.raw_sequence) {
            try self.invalidate(times, evidence);
            return error.InvalidRawSequence;
        }
        self.raw_sequence = evidence.sequence;
        self.decode(allocator, epoch, input, times, evidence, bytes) catch |err| {
            if (err == error.AwaitingFreshSnapshot) {
                try self.queueGap(times, evidence);
            } else {
                if (input == .metadata) self.observed = false;
                try self.invalidate(times, evidence);
            }
            return err;
        };
    }
    fn decode(self: *HyperliquidMarketFeed, allocator: std.mem.Allocator, epoch: u64, input: Input, times: Times, evidence: Evidence, bytes: []const u8) !void {
        if (bytes.len == 0 or bytes.len > max_frame_bytes) return error.FrameTooLarge;
        if (input == .subscribe) {
            if (epoch <= self.epoch or times.monotonic_time_ns < self.barrier.monotonic_time_ns or
                times.receive_time_utc_ns < self.barrier.receive_time_utc_ns) return error.StaleSession;
            self.epoch = epoch;
            self.barrier = times;
            self.subscribed = true;
            self.health = .gap;
            self.last_book_time = 0;
            self.last_book = null;
            // Keep trade identities across reconnect; reconnect is not a new public trade.
            try self.invalidate(times, evidence);
            self.subscribed = true;
            return;
        }
        if (epoch != self.epoch) return error.StaleSession;
        if (input == .disconnected or input == .expired) {
            try self.invalidate(times, evidence);
            return;
        }
        if (times.monotonic_time_ns < self.barrier.monotonic_time_ns or times.receive_time_utc_ns < self.barrier.receive_time_utc_ns)
            return error.StaleFrame;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        var output: c.AdapterOutputBatch = .{};
        switch (input) {
            .metadata => try self.metadata(allocator, &output, parsed.value, times, evidence),
            .book, .trades, .context => {
                if (!self.observed) return error.MissingInstrumentRules;
                if (!self.subscribed) return error.FreshSubscriptionRequired;
                var data = parsed.value;
                const root = if (data == .object) data.object else null;
                if (if (root) |row| row.get("channel") else null) |channel| {
                    const expected = switch (input) {
                        .book => "l2Book",
                        .trades => "trades",
                        .context => "activeAssetCtx",
                        else => unreachable,
                    };
                    if (!std.mem.eql(u8, try string(channel), expected)) return error.UnsupportedFrame;
                    data = try field(root.?, "data");
                } else if (input == .context) return error.UnsupportedFrame;
                switch (input) {
                    .book => try self.book(&output, try object(data), times, evidence),
                    .trades => try self.trades(&output, try array(data), times, evidence),
                    .context => try self.context(&output, try object(data), times, evidence),
                    else => unreachable,
                }
            },
            .funding_history => try self.funding(&output, try array(parsed.value), times, evidence),
            else => unreachable,
        }
        if (output.len != 0) self.pending = output;
    }
    fn metadata(self: *HyperliquidMarketFeed, allocator: std.mem.Allocator, output: *c.AdapterOutputBatch, value: std.json.Value, times: Times, evidence: Evidence) !void {
        const root = try object(value);
        const universe = try array(try field(root, "universe"));
        var match: ?std.json.ObjectMap = null;
        if (self.binding.product == .isolated_linear) {
            if (self.binding.universe_index >= universe.items.len) return error.UnsupportedInstrument;
            match = try object(universe.items[self.binding.universe_index]);
        } else {
            for (universe.items) |item| {
                const row = try object(item);
                if (try uint(try field(row, "index")) == self.binding.universe_index) {
                    if (match != null) return error.DuplicateInstrument;
                    match = row;
                }
            }
        }
        const row = match orelse return error.UnsupportedInstrument;
        var rules_hash = std.crypto.hash.sha2.Sha256.init(.{});
        try hashValue(allocator, &rules_hash, .{ .object = row });
        if (!std.mem.eql(u8, try string(try field(row, "name")), self.binding.coin)) return error.UnsupportedInstrument;
        var size: u64 = undefined;
        if (self.binding.product == .isolated_linear) {
            const spec = try perpetualSpecification(allocator, value, self.binding.universe_index, self.binding.quote_token);
            size = spec.size_decimals;
            if (!std.mem.eql(u8, &spec.metadata_digest, &self.binding.expected_metadata_digest)) return error.InstrumentRulesChanged;
        } else {
            const pair = try array(try field(row, "tokens"));
            if (pair.items.len != 2 or try uint(pair.items[0]) != self.binding.base_token or try uint(pair.items[1]) != self.binding.quote_token)
                return error.UnsupportedInstrument;
            const tokens = try array(try field(root, "tokens"));
            var base_size: ?u64 = null;
            var quote_found = false;
            for (tokens.items) |item| {
                const token = try object(item);
                const index = try uint(try field(token, "index"));
                if (index == self.binding.base_token) {
                    try hashValue(allocator, &rules_hash, item);
                    if (!std.mem.eql(u8, try string(try field(token, "tokenId")), self.binding.base_token_id)) return error.UnsupportedInstrument;
                    base_size = try uint(try field(token, "szDecimals"));
                }
                if (index == self.binding.quote_token) {
                    try hashValue(allocator, &rules_hash, item);
                    if (!std.mem.eql(u8, try string(try field(token, "tokenId")), self.binding.quote_token_id)) return error.UnsupportedInstrument;
                    quote_found = true;
                }
            }
            if (!quote_found) return error.UnsupportedInstrument;
            size = base_size orelse return error.UnsupportedInstrument;
        }
        if (size != self.binding.size_decimals) {
            self.observed = false;
            return error.InstrumentRulesChanged;
        }
        const digest = rules_hash.finalResult();
        if (self.binding.product != .isolated_linear and !std.mem.eql(u8, &self.binding.expected_metadata_digest, &digest)) return error.InstrumentRulesChanged;
        try self.append(output, times, evidence, null, .{ .instrument_definition_observed = .{ .instrument = self.binding.instrument, .rules_version = self.binding.rules_version } });
        self.observed = true;
    }
    fn book(self: *HyperliquidMarketFeed, output: *c.AdapterOutputBatch, row: std.json.ObjectMap, times: Times, evidence: Evidence) !void {
        try self.coin(row);
        const source_time = try millis(try uint(try field(row, "time")));
        const levels = try array(try field(row, "levels"));
        if (levels.items.len != 2) return error.InvalidDepth;
        var depth: c.BookDepth = .{ .visible_at_ns = times.receive_time_utc_ns };
        for (levels.items, 0..) |side, side_index| {
            const rows = try array(side);
            if (rows.items.len == 0 or rows.items.len > 20) return error.InvalidDepth;
            var previous: ?i128 = null;
            for (rows.items, 0..) |item, index| {
                const level = try object(item);
                const px = try self.price(try string(try field(level, "px")), true);
                const qty = try self.quantity(try string(try field(level, "sz")));
                if (try uint(try field(level, "n")) == 0) return error.InvalidDepth;
                if (previous) |prior| if ((side_index == 0 and px.ticks >= prior) or (side_index == 1 and px.ticks <= prior)) return error.InvalidDepth;
                previous = px.ticks;
                if (index < c.max_depth_levels) {
                    const target = if (side_index == 0) &depth.bids[index] else &depth.asks[index];
                    target.* = .{ .ticks = px.ticks, .lots = qty.lots };
                }
            }
            const count: u8 = @intCast(@min(rows.items.len, c.max_depth_levels));
            if (side_index == 0) {
                depth.bid_count = count;
                depth.bids_truncated = rows.items.len > c.max_depth_levels;
            } else {
                depth.ask_count = count;
                depth.asks_truncated = rows.items.len > c.max_depth_levels;
            }
        }
        const snapshot: c.L2BookSnapshot = .{
            .sequence_kind = .capture,
            .capture_epoch = self.epoch,
            .sequence = evidence.sequence,
            .instrument = self.binding.instrument,
            .depth = depth,
            .best_bid = self.priceTicks(depth.bids[0].ticks),
            .best_ask = self.priceTicks(depth.asks[0].ticks),
            .best_bid_quantity = self.quantityLots(depth.bids[0].lots.?),
            .best_ask_quantity = self.quantityLots(depth.asks[0].lots.?),
            .next_ask = if (depth.ask_count > 1) self.priceTicks(depth.asks[1].ticks) else null,
            .next_ask_quantity = if (depth.ask_count > 1) self.quantityLots(depth.asks[1].lots.?) else null,
        };
        try depth_contract.validate(snapshot);
        // A cached initial book cannot qualify or advance the new subscription's time barrier.
        if (self.last_book == null and source_time < self.barrier.receive_time_utc_ns and
            times.receive_time_utc_ns - source_time <= self.binding.max_age_ns) return error.AwaitingFreshSnapshot;
        try self.fresh(source_time, times);
        if (source_time < self.last_book_time) return error.StaleFrame;
        if (source_time == self.last_book_time) {
            var old = self.last_book orelse return error.StaleFrame;
            var candidate = snapshot;
            old.sequence = 1;
            candidate.sequence = 1;
            old.depth.?.visible_at_ns = 0;
            candidate.depth.?.visible_at_ns = 0;
            if (!std.meta.eql(old, candidate)) return error.ConflictingSnapshot;
            return;
        }
        try self.append(output, times, evidence, source_time, .{ .l2_book_snapshot = snapshot });
        self.last_book_time = source_time;
        self.last_book_monotonic = times.monotonic_time_ns;
        self.last_book = snapshot;
        self.health = .healthy;
    }
    fn trades(self: *HyperliquidMarketFeed, output: *c.AdapterOutputBatch, rows: std.json.Array, times: Times, evidence: Evidence) !void {
        if (rows.items.len > max_trades) return error.TradeCapacityExceeded;
        // Commit dedup state only after the complete frame is validated.
        var additions: [max_trades]TradeKey = undefined;
        var count: usize = 0;
        for (rows.items) |item| {
            const row = try object(item);
            try self.coin(row);
            const source_time = try millis(try uint(try field(row, "time")));
            try self.fresh(source_time, times);
            const tid = try uint(try field(row, "tid"));
            const side = try string(try field(row, "side"));
            const trade: c.MarketTrade = .{
                .instrument = self.binding.instrument,
                .trade_identity = tradeIdentity(self.binding.instrument, source_time, tid),
                .source_time_utc_ns = source_time,
                .price = try self.price(try string(try field(row, "px")), true),
                .quantity = try self.quantity(try string(try field(row, "sz"))),
                .side = if (std.mem.eql(u8, side, "B")) .buy else if (std.mem.eql(u8, side, "A")) .sell else return error.InvalidSide,
            };
            var duplicate = false;
            for (self.seen[0..self.seen_count]) |previous| if (previous.time == source_time and previous.tid == tid) {
                if (!std.meta.eql(previous.trade, trade)) return error.ConflictingTrade;
                duplicate = true;
                break;
            };
            for (additions[0..count]) |previous| if (previous.time == source_time and previous.tid == tid) {
                if (!std.meta.eql(previous.trade, trade)) return error.ConflictingTrade;
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            if (source_time <= self.retired_trade_time) return error.TradeCoverageExceeded;
            additions[count] = .{ .time = source_time, .tid = tid, .trade = trade };
            count += 1;
            try self.append(output, times, evidence, source_time, .{ .market_trade = trade });
        }
        for (additions[0..count]) |addition| {
            var index = self.seen_count;
            if (index == self.seen.len) {
                index = 0;
                for (self.seen[0..self.seen_count], 0..) |previous, candidate| {
                    if (previous.time < self.seen[index].time) index = candidate;
                }
                self.retired_trade_time = @max(self.retired_trade_time, self.seen[index].time);
            } else self.seen_count += 1;
            self.seen[index] = addition;
        }
    }
    fn context(self: *HyperliquidMarketFeed, output: *c.AdapterOutputBatch, row: std.json.ObjectMap, times: Times, evidence: Evidence) !void {
        if (self.binding.product != .isolated_linear) return error.UnsupportedFrame;
        try self.coin(row);
        const ctx = try object(try field(row, "ctx"));
        // activeAssetCtx has no source timestamp or funding period. Do not invent either.
        try self.append(output, times, evidence, null, .{ .reference_price = .{ .instrument = self.binding.instrument, .kind = .mark, .price = try self.price(try string(try field(ctx, "markPx")), false) } });
        try self.append(output, times, evidence, null, .{ .reference_price = .{ .instrument = self.binding.instrument, .kind = .index, .price = try self.price(try string(try field(ctx, "oraclePx")), false) } });
    }
    fn funding(self: *HyperliquidMarketFeed, output: *c.AdapterOutputBatch, rows: std.json.Array, times: Times, evidence: Evidence) !void {
        if (self.binding.product != .isolated_linear or !self.observed or !self.subscribed) return error.UnsupportedFrame;
        if (rows.items.len > max_trades) return error.FundingCapacityExceeded;
        for (rows.items) |item| {
            const row = try object(item);
            try self.coin(row);
            const rate = try (try c.Decimal.parse(try string(try field(row, "fundingRate")))).exactAtoms(6);
            const source_time = try millis(try uint(try field(row, "time")));
            try self.append(output, times, evidence, source_time, .{ .funding_rate_published = .{
                .instrument = self.binding.instrument,
                .rate_ppm = std.math.cast(i64, rate) orelse return error.FundingRateOverflow,
                .funding_time_utc_ns = source_time,
            } });
        }
    }
    fn coin(self: *const HyperliquidMarketFeed, row: std.json.ObjectMap) !void {
        if (!std.mem.eql(u8, try string(try field(row, "coin")), self.binding.coin)) return error.UnsupportedInstrument;
    }
    fn fresh(self: *const HyperliquidMarketFeed, source_time: u64, times: Times) !void {
        if (source_time < self.barrier.receive_time_utc_ns or source_time > times.receive_time_utc_ns or
            times.receive_time_utc_ns - source_time > self.binding.max_age_ns) return error.StaleFrame;
    }
    fn price(self: *const HyperliquidMarketFeed, text: []const u8, order_price: bool) !c.InstrumentPrice {
        const value = try c.InstrumentPrice.fromDecimal(self.binding.instrument, self.binding.rules_version, try c.Decimal.parse(text), self.binding.price_scale, self.binding.tick_atoms);
        if (value.ticks <= 0) return error.InvalidPrice;
        if (order_price) {
            const limit: u8 = if (self.binding.product == .spot) 8 else 6;
            try (c.PriceConstraints{ .max_significant_digits = 5, .max_decimal_places = limit - self.binding.size_decimals, .integer_exception = true }).validate(value.ticks, self.binding.tick_atoms, self.binding.price_scale);
        }
        return value;
    }
    fn quantity(self: *const HyperliquidMarketFeed, text: []const u8) !c.InstrumentQuantity {
        const decimal = try c.Decimal.parse(text);
        _ = try decimal.exactAtoms(self.binding.size_decimals);
        const value = try c.InstrumentQuantity.fromDecimal(self.binding.instrument, self.binding.rules_version, decimal, self.binding.quantity_scale, self.binding.lot_atoms);
        if (value.lots <= 0) return error.InvalidQuantity;
        return value;
    }
    fn priceTicks(self: *const HyperliquidMarketFeed, ticks: i128) c.InstrumentPrice {
        return .{ .instrument = self.binding.instrument, .rules_version = self.binding.rules_version, .ticks = ticks };
    }
    fn quantityLots(self: *const HyperliquidMarketFeed, lots: i128) c.InstrumentQuantity {
        return .{ .instrument = self.binding.instrument, .rules_version = self.binding.rules_version, .lots = lots };
    }
    fn append(self: *HyperliquidMarketFeed, output: *c.AdapterOutputBatch, times: Times, evidence: Evidence, source_time: ?u64, payload: c.Payload) !void {
        const limit = self.config.?.output_capacity - @as(u16, if (payload == .market_data_health_changed) 0 else 1);
        if (output.len >= limit) return error.OutputCapacityExceeded;
        const sequence = try std.math.add(u64, self.event_sequence, 1);
        try output.append(.{ .envelope = .{
            .event_type = @intFromEnum(c.eventType(payload)),
            .schema_version = c.schema_version,
            .identity = .{ .stream = self.config.?.session, .sequence = sequence },
            .source_fact_identity = if (payload == .market_trade) payload.market_trade.trade_identity else tradeIdentity(self.binding.instrument, self.epoch, sequence),
            .scope = .instrument,
            .venue = self.config.?.venue,
            .instrument = self.binding.instrument,
            .source_stream = tradeIdentity(self.config.?.subscription_set, self.epoch, 0x48594c4951554944),
            .source_sequence = evidence.sequence,
            .adapter_session = self.config.?.session,
            .times = .{ .source_utc_ns = source_time, .receive_utc_ns = times.receive_time_utc_ns, .monotonic_ns = times.monotonic_time_ns, .audit_utc_ns = times.wall_time_utc_ns },
            .raw_evidence = .{ .stream = if (evidence.sequence == 0) 0 else self.config.?.subscription_set, .sequence = evidence.sequence, .digest = evidence.digest },
        }, .event = payload });
        self.event_sequence = sequence;
    }
    fn invalidate(self: *HyperliquidMarketFeed, times: Times, evidence: Evidence) !void {
        self.subscribed = false;
        self.health = .gap;
        self.barrier.monotonic_time_ns = @max(self.barrier.monotonic_time_ns, times.monotonic_time_ns);
        self.barrier.receive_time_utc_ns = @max(self.barrier.receive_time_utc_ns, times.receive_time_utc_ns);
        try self.queueGap(times, evidence);
    }
    fn queueGap(self: *HyperliquidMarketFeed, times: Times, evidence: Evidence) !void {
        if (self.pending) |pending| if (pending.len != 0 and pending.events[pending.len - 1].event == .market_data_health_changed and
            pending.events[pending.len - 1].event.market_data_health_changed.health == .gap) return;
        var output = self.pending orelse c.AdapterOutputBatch{};
        try self.append(&output, times, evidence, null, .{ .market_data_health_changed = .{ .instrument = self.binding.instrument, .health = .gap } });
        self.pending = output;
    }
    fn start(ptr: *anyopaque, config: market.Config) market.StartError!void {
        const self: *HyperliquidMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        const b = self.binding;
        const max_decimals: u8 = if (b.product == .spot) 8 else 6;
        for (b.coin) |byte| if (byte < 33 or byte > 126 or byte == '"' or byte == '\\' or byte == ':') return error.InvalidConfig;
        if (config.venue == 0 or config.subscription_set == 0 or config.config_version == 0 or config.session == 0 or
            config.output_capacity < 3 or config.output_capacity > c.max_events_per_adapter_batch or b.instrument == 0 or
            b.coin.len == 0 or b.coin.len > 64 or b.rules_version == 0 or b.size_decimals > max_decimals or
            b.price_scale > c.Decimal.max_scale or b.quantity_scale > c.Decimal.max_scale or b.tick_atoms <= 0 or b.lot_atoms <= 0 or b.max_age_ns == 0 or
            std.mem.allEqual(u8, &b.expected_metadata_digest, 0) or
            (b.product == .spot and (b.base_token_id.len == 0 or b.quote_token_id.len == 0 or b.base_token == b.quote_token))) return error.InvalidConfig;
        self.config = config;
        self.state = .running;
    }
    fn drain(ptr: *anyopaque) market.DrainError!?market.MarketEventBatch {
        const self: *HyperliquidMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const output = self.pending;
        self.pending = null;
        return output;
    }
    fn stop(ptr: *anyopaque, _: market.DrainDeadline) market.StopError!void {
        const self: *HyperliquidMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        if (self.health == .healthy) {
            self.invalidate(self.barrier, .{ .sequence = 0, .digest = @splat(0) }) catch unreachable;
            return error.OutputPending;
        }
        self.state = .stopped;
    }
};

fn object(value: std.json.Value) !std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidFrame;
}
fn hashValue(allocator: std.mem.Allocator, hasher: *std.crypto.hash.sha2.Sha256, value: std.json.Value) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    hasher.update(bytes);
}
fn array(value: std.json.Value) !std.json.Array {
    return if (value == .array) value.array else error.InvalidFrame;
}
fn string(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidFrame;
}
fn field(row: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return row.get(name) orelse error.MissingField;
}
fn uint(value: std.json.Value) !u64 {
    return if (value == .integer) std.math.cast(u64, value.integer) orelse error.InvalidInteger else error.InvalidInteger;
}
fn millis(value: u64) !u64 {
    if (value == 0) return error.InvalidInteger;
    return std.math.mul(u64, value, 1_000_000);
}
fn tradeIdentity(instrument: u128, time: u64, tid: u64) u128 {
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u128, bytes[0..16], instrument, .little);
    std.mem.writeInt(u64, bytes[16..24], time, .little);
    std.mem.writeInt(u64, bytes[24..32], tid, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
    return std.mem.readInt(u128, digest[0..16], .little);
}

const TestSink = struct {
    count: usize = 0,
    fail: bool = false,
    records: [64]RawRecord = undefined,
    frames: [64][]const u8 = undefined,
    fn sink(self: *TestSink) RawSink {
        return .{ .ptr = self, .append_fn = capture };
    }
    fn capture(ptr: *anyopaque, record: RawRecord, bytes: []const u8) RawError!u64 {
        const self: *TestSink = @ptrCast(@alignCast(ptr));
        if (self.fail) return error.Unavailable;
        if (self.count == self.records.len) return error.Backpressure;
        self.records[self.count] = record;
        self.frames[self.count] = bytes;
        self.count += 1;
        return self.count;
    }
};
const test_binding: Binding = .{ .instrument = 3, .coin = "BTC", .product = .isolated_linear, .universe_index = 0, .size_decimals = 0, .rules_version = 1, .expected_metadata_digest = .{ 0x57, 0xad, 0x35, 0xcf, 0x0c, 0xda, 0xe7, 0xc2, 0xf4, 0x54, 0xb3, 0x50, 0xc9, 0xa2, 0xb0, 0x5e, 0x89, 0xe2, 0x1b, 0xeb, 0xd3, 0xc3, 0x7b, 0x3a, 0xb9, 0x9c, 0x80, 0x77, 0xb8, 0x43, 0xc2, 0x09 }, .price_scale = 0, .tick_atoms = 1, .quantity_scale = 0, .lot_atoms = 1 };
const test_config: market.Config = .{ .venue = 1, .environment = .demo, .subscription_set = 70, .config_version = 1, .session = 60, .output_capacity = 32 };
const test_times: Times = .{ .receive_time_utc_ns = 1_000_000_000_000, .monotonic_time_ns = 100, .wall_time_utc_ns = 1_000_000_000_000 };
const test_metadata = "{\"collateralToken\":0,\"universe\":[{\"name\":\"BTC\",\"szDecimals\":0,\"maxLeverage\":40,\"marginTableId\":54}],\"marginTables\":[[54,{\"marginTiers\":[{\"lowerBound\":\"0\",\"maxLeverage\":40}]}]]}";
const test_book = "{\"coin\":\"BTC\",\"time\":1000000,\"levels\":[[{\"px\":\"99\",\"sz\":\"2\",\"n\":1}],[{\"px\":\"100\",\"sz\":\"3\",\"n\":1},{\"px\":\"101\",\"sz\":\"4\",\"n\":1}]]}";
fn startTest(feed: *HyperliquidMarketFeed) !market.MarketFeedAdapter {
    const adapter = feed.adapter();
    try market.testStartupContract(adapter, test_config);
    try feed.ingest(std.testing.allocator, 0, .metadata, test_times, test_metadata);
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, 1, .subscribe, test_times, "{\"event\":\"subscribe\"}");
    _ = try adapter.tryDrain();
    return adapter;
}

test "Hyperliquid public seam preserves bounded depth and raw replay to Host" {
    var sink: TestSink = .{};
    var feed = HyperliquidMarketFeed.init(test_binding, sink.sink(), 0);
    const adapter = try startTest(&feed);
    try feed.ingest(std.testing.allocator, 1, .book, test_times, test_book);
    const batch = (try adapter.tryDrain()).?;
    const snapshot = batch.events[0].event.l2_book_snapshot;
    try std.testing.expectEqual(c.BookSequenceKind.capture, snapshot.sequence_kind);
    try std.testing.expectEqual(@as(u64, 1), snapshot.capture_epoch);
    try std.testing.expectEqual(@as(u8, 2), snapshot.depth.?.ask_count);
    try std.testing.expectEqual(@as(i128, 4), snapshot.depth.?.asks[1].lots.?);
    var projection: @import("../../market/market_projection.zig").Projection = .{};
    try projection.apply(.{ .instrument_definition_observed = .{ .instrument = 3, .rules_version = 1 } });
    try std.testing.expectEqual(@as(?u64, null), projection.get(3).?.active_rules_version);
    try projection.activateRules(3, 1);
    try projection.apply(batch.events[0].event);
    const host = @import("../../strategy/strategy_host_gateway.zig");
    var wire: [depth_contract.wire_len]u8 = undefined;
    const input = try host.depthSnapshotInput(&projection, 3, 1, &wire, 100, 1000);
    try std.testing.expectEqualDeep(snapshot, try depth_contract.decode(input.payload));
    try std.testing.expectError(error.InsufficientDepth, depth_contract.quote(snapshot, .buy, 8, 101, 0, .quote));

    var replay_sink: TestSink = .{};
    var replay_feed = HyperliquidMarketFeed.init(test_binding, replay_sink.sink(), 0);
    const replay_adapter = replay_feed.adapter();
    try replay_adapter.start(test_config);
    const codec = @import("../../persistence/canonical_event_codec.zig");
    var encoded: [codec.max_encoded_len]u8 = undefined;
    for (sink.records[0..sink.count], sink.frames[0..sink.count], 0..) |record, bytes, index| {
        try replay_feed.replay(std.testing.allocator, record, .{ .sequence = index + 1, .digest = record.sha256 }, bytes);
        const output = (try replay_adapter.tryDrain()).?;
        for (output.slice()) |event| {
            try std.testing.expectEqualDeep(event, try codec.decode(try codec.encode(&encoded, event)));
        }
        if (index == 2) try std.testing.expectEqualDeep(batch.events[0], output.events[0]);
    }
    try std.testing.expectEqual(@as(usize, 0), replay_sink.count);
    try std.testing.expectError(error.OutputPending, adapter.stop(.{ .monotonic_ns = 200 }));
    const stopped = (try adapter.tryDrain()).?;
    try projection.apply(stopped.events[0].event);
    try std.testing.expectError(error.MarketGap, host.depthSnapshotInput(&projection, 3, 2, &wire, 200, 2000));
    try adapter.stop(.{ .monotonic_ns = 200 });
    try std.testing.expectError(error.NotStarted, feed.ingest(std.testing.allocator, 1, .book, test_times, test_book));
}

test "Hyperliquid malformed frames stale sessions and backpressure revoke qualification" {
    const cases = [_][]const u8{
        "{",                                                                                                                                "{}",                                                            "{\"coin\":\"ETH\",\"time\":1000000,\"levels\":[[],[]]}",
        "{\"coin\":\"BTC\",\"time\":1000000,\"levels\":[[],[]]}",                                                                           "{\"coin\":\"BTC\",\"time\":18446744073709,\"levels\":[[],[]]}", "{\"coin\":\"BTC\",\"time\":999999,\"levels\":[[],[]]}",
        "{\"coin\":\"BTC\",\"time\":1000000,\"levels\":[[{\"px\":\"101\",\"sz\":\"1\",\"n\":1}],[{\"px\":\"100\",\"sz\":\"1\",\"n\":1}]]}",
    };
    for (cases) |invalid| {
        var sink: TestSink = .{};
        var feed = HyperliquidMarketFeed.init(test_binding, sink.sink(), 0);
        const adapter = try startTest(&feed);
        try feed.ingest(std.testing.allocator, 1, .book, test_times, test_book);
        _ = try adapter.tryDrain();
        if (feed.ingest(std.testing.allocator, 1, .book, test_times, invalid)) |_| return error.ExpectedInvalidFrame else |_| {}
        const gap = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(c.MarketDataHealth.gap, gap.events[0].event.market_data_health_changed.health);
        try std.testing.expectEqual(@as(usize, 4), sink.count);
        try std.testing.expectError(error.FreshSubscriptionRequired, feed.ingest(std.testing.allocator, 1, .book, test_times, test_book));
        _ = try adapter.tryDrain();
        try feed.ingest(std.testing.allocator, 2, .subscribe, test_times, "reset");
        _ = try adapter.tryDrain();
        try feed.ingest(std.testing.allocator, 2, .book, test_times, test_book);
        try std.testing.expectError(error.OutputPending, adapter.stop(.{ .monotonic_ns = 200 }));
        const count_before = sink.count;
        try std.testing.expectError(error.OutputCapacityExceeded, feed.ingest(std.testing.allocator, 2, .book, test_times, test_book));
        try std.testing.expectEqual(count_before, sink.count);
        _ = try adapter.tryDrain();
        try std.testing.expectError(error.StaleSession, feed.ingest(std.testing.allocator, 1, .book, test_times, test_book));
        const last_gap = (try adapter.tryDrain()).?;
        var replay_sink: TestSink = .{};
        var replay_feed = HyperliquidMarketFeed.init(test_binding, replay_sink.sink(), 0);
        const replay_adapter = replay_feed.adapter();
        try replay_adapter.start(test_config);
        for (sink.records[0..sink.count], sink.frames[0..sink.count], 0..) |record, bytes, index| {
            replay_feed.replay(std.testing.allocator, record, .{ .sequence = index + 1, .digest = record.sha256 }, bytes) catch {};
            const replayed = (try replay_adapter.tryDrain()).?;
            if (index + 1 == sink.count) try std.testing.expectEqualDeep(last_gap.events[0], replayed.events[0]);
        }
        try std.testing.expectEqual(@as(usize, 0), replay_sink.count);
    }
}

test "Hyperliquid public trades references funding and conflicts cross the seam" {
    var sink: TestSink = .{};
    var feed = HyperliquidMarketFeed.init(test_binding, sink.sink(), 0);
    const adapter = try startTest(&feed);
    const trades_frame = "[{\"coin\":\"BTC\",\"time\":1000000,\"tid\":7,\"side\":\"B\",\"px\":\"99\",\"sz\":\"2\"}]";
    try feed.ingest(std.testing.allocator, 1, .trades, test_times, trades_frame);
    const tape = (try adapter.tryDrain()).?;
    const trade = tape.events[0].event.market_trade;
    try std.testing.expectEqual(c.OrderSide.buy, trade.side);
    try std.testing.expectEqual(@as(i128, 2), trade.quantity.lots);
    var wire: [96]u8 = undefined;
    const input = try @import("../../strategy/strategy_host_gateway.zig").marketTradeInput(tape.events[0], 10, &wire);
    try std.testing.expectEqualDeep(trade, try @import("../../market/market_trade.zig").decode(input.payload));
    try feed.ingest(std.testing.allocator, 1, .trades, test_times, trades_frame);
    try std.testing.expectEqual(@as(?c.AdapterOutputBatch, null), try adapter.tryDrain());
    try feed.ingest(std.testing.allocator, 1, .context, test_times, "{\"channel\":\"activeAssetCtx\",\"data\":{\"coin\":\"BTC\",\"ctx\":{\"markPx\":\"99\",\"oraclePx\":\"98\",\"funding\":\"0.00001\"}}}");
    const prices = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 2), prices.len);
    try std.testing.expectEqual(@as(i128, 99), prices.events[0].event.reference_price.price.ticks);
    try std.testing.expectEqual(@as(i128, 98), prices.events[1].event.reference_price.price.ticks);
    try std.testing.expectEqual(@as(?u64, null), prices.events[0].envelope.times.source_utc_ns);
    try feed.ingest(std.testing.allocator, 1, .funding_history, test_times, "[{\"coin\":\"BTC\",\"time\":1000000,\"fundingRate\":\"-0.00001\"}]");
    const funding = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(i64, -10), funding.events[0].event.funding_rate_published.rate_ppm);
    try std.testing.expectError(error.ConflictingTrade, feed.ingest(std.testing.allocator, 1, .trades, test_times, "[{\"coin\":\"BTC\",\"time\":1000000,\"tid\":7,\"side\":\"B\",\"px\":\"99\",\"sz\":\"3\"}]"));
    _ = try adapter.tryDrain();
}

test "Hyperliquid official captured metadata and full book retain eight validated levels" {
    var sink: TestSink = .{};
    var binding = test_binding;
    binding.universe_index = 3;
    binding.expected_metadata_digest = .{ 0xf6, 0x43, 0xad, 0x46, 0x8c, 0x3b, 0x3d, 0xf4, 0x94, 0x26, 0x1c, 0x96, 0x35, 0x48, 0x06, 0xa7, 0x67, 0x50, 0x62, 0x74, 0x91, 0x99, 0x54, 0xa8, 0x32, 0x96, 0x17, 0x79, 0x17, 0x0a, 0x6e, 0x15 };
    binding.size_decimals = 5;
    binding.price_scale = 1;
    binding.quantity_scale = 5;
    var feed = HyperliquidMarketFeed.init(binding, sink.sink(), 10);
    const adapter = feed.adapter();
    try adapter.start(test_config);
    const metadata_bytes = @embedFile("../../testing/fixtures/hyperliquid/meta.json");
    const book_bytes = @embedFile("../../testing/fixtures/hyperliquid/btc-book.json");
    const times: Times = .{ .receive_time_utc_ns = 1_793_597_467_260_000_000, .monotonic_time_ns = 100, .wall_time_utc_ns = 1_793_597_467_260_000_000 };
    try feed.ingest(std.testing.allocator, 10, .metadata, times, metadata_bytes);
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, 11, .subscribe, times, "subscribe");
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, 11, .book, times, book_bytes);
    const batch = (try adapter.tryDrain()).?;
    const snapshot = batch.events[0].event.l2_book_snapshot;
    try std.testing.expectEqual(@as(u8, 8), snapshot.depth.?.bid_count);
    try std.testing.expectEqual(@as(u8, 8), snapshot.depth.?.ask_count);
    try std.testing.expect(snapshot.depth.?.bids_truncated and snapshot.depth.?.asks_truncated);
    try std.testing.expectEqual(@as(i128, 777110), snapshot.depth.?.bids[7].ticks);
    try std.testing.expectEqual(@as(i128, 25), snapshot.depth.?.bids[7].lots.?);
    try std.testing.expectEqual(@as(u64, 11), snapshot.capture_epoch);
    try std.testing.expectEqual(@as(?u64, null), batch.events[0].envelope.source_previous_sequence);
    // A malformed ninth level must revoke even though it would be truncated.
    const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, book_bytes, "77708.0", "77712.0");
    defer std.testing.allocator.free(malformed);
    try std.testing.expectError(error.InvalidDepth, feed.ingest(std.testing.allocator, 11, .book, times, malformed));
    const gap = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(c.MarketDataHealth.gap, gap.events[0].event.market_data_health_changed.health);
}

test "Hyperliquid pending output expires in order and source faults do not affect another feed" {
    var sink: TestSink = .{};
    var feed = HyperliquidMarketFeed.init(test_binding, sink.sink(), 0);
    const adapter = try startTest(&feed);
    var other_sink: TestSink = .{};
    var other = HyperliquidMarketFeed.init(test_binding, other_sink.sink(), 0);
    const other_adapter = try startTest(&other);
    try feed.ingest(std.testing.allocator, 1, .book, test_times, test_book);
    var later = test_times;
    later.monotonic_time_ns += test_binding.max_age_ns + 1;
    later.receive_time_utc_ns += test_binding.max_age_ns + 1;
    try feed.poll(std.testing.allocator, later);
    const expired = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 2), expired.len);
    try std.testing.expectEqual(c.EventType.l2_book_snapshot, c.eventType(expired.events[0].event));
    try std.testing.expectEqual(c.MarketDataHealth.gap, expired.events[1].event.market_data_health_changed.health);
    try other.ingest(std.testing.allocator, 1, .book, test_times, test_book);
    try std.testing.expectEqual(c.EventType.l2_book_snapshot, c.eventType((try other_adapter.tryDrain()).?.events[0].event));
    try feed.ingest(std.testing.allocator, 2, .subscribe, later, "subscribe");
    _ = try adapter.tryDrain();
    try std.testing.expectError(error.StaleFrame, feed.ingest(std.testing.allocator, 2, .book, later, test_book));
    _ = try adapter.tryDrain();
    sink.fail = true;
    try std.testing.expectError(error.Unavailable, feed.ingest(std.testing.allocator, 3, .subscribe, later, "subscribe"));
    const capture_failure = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u64, 0), capture_failure.events[0].envelope.raw_evidence.sequence);
    try std.testing.expectEqual(c.MarketDataHealth.gap, capture_failure.events[0].event.market_data_health_changed.health);
}

test "Hyperliquid rule changes duplicate books and exact funding failures are explicit" {
    var sink: TestSink = .{};
    var feed = HyperliquidMarketFeed.init(test_binding, sink.sink(), 0);
    const adapter = try startTest(&feed);
    try feed.ingest(std.testing.allocator, 1, .book, test_times, test_book);
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, 1, .book, test_times, test_book);
    try std.testing.expect((try adapter.tryDrain()) == null);
    const conflict = try std.mem.replaceOwned(u8, std.testing.allocator, test_book, "\"3\"", "\"4\"");
    defer std.testing.allocator.free(conflict);
    try std.testing.expectError(error.ConflictingSnapshot, feed.ingest(std.testing.allocator, 1, .book, test_times, conflict));
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, 2, .subscribe, test_times, "subscribe");
    _ = try adapter.tryDrain();
    try std.testing.expectError(error.InexactDecimal, feed.ingest(std.testing.allocator, 2, .funding_history, test_times, "[{\"coin\":\"BTC\",\"time\":1000000,\"fundingRate\":\"0.0000001\"}]"));
    _ = try adapter.tryDrain();
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, test_metadata, "40", "20");
    defer std.testing.allocator.free(changed);
    try std.testing.expectError(error.InstrumentRulesChanged, feed.ingest(std.testing.allocator, 2, .metadata, test_times, changed));
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, 3, .subscribe, test_times, "subscribe");
    _ = try adapter.tryDrain();
    try std.testing.expectError(error.MissingInstrumentRules, feed.ingest(std.testing.allocator, 3, .book, test_times, test_book));
    _ = try adapter.tryDrain();
    var request: [256]u8 = undefined;
    try std.testing.expectEqualStrings("{\"method\":\"subscribe\",\"subscription\":{\"type\":\"l2Book\",\"coin\":\"BTC\"}}", try feed.subscription(.book, &request));
}

test "Hyperliquid spot metadata binds actual tokens and capacity failure publishes only gap" {
    var sink: TestSink = .{};
    var binding = test_binding;
    binding.product = .spot;
    binding.expected_metadata_digest = .{ 0x20, 0x92, 0xc9, 0x75, 0x62, 0x1f, 0xfe, 0x45, 0x91, 0x6d, 0x4b, 0x47, 0x6d, 0x62, 0xab, 0xf2, 0x12, 0xaa, 0x3e, 0xd2, 0x62, 0xcb, 0xa0, 0xfa, 0x37, 0x60, 0x72, 0x61, 0xf0, 0x58, 0x69, 0xb1 };
    binding.coin = "@1137";
    binding.universe_index = 1137;
    binding.base_token = 1242;
    binding.quote_token = 0;
    binding.base_token_id = "0xe4371d8166f362d6578725f11e0a14f3";
    binding.quote_token_id = "0xeb62eee3685fc4c43992febcd9e75443";
    binding.size_decimals = 4;
    binding.quantity_scale = 4;
    var feed = HyperliquidMarketFeed.init(binding, sink.sink(), 0);
    const adapter = feed.adapter();
    try adapter.start(test_config);
    try feed.ingest(std.testing.allocator, 0, .metadata, test_times, @embedFile("../../testing/fixtures/hyperliquid/spot-meta.json"));
    const observation = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u128, 3), observation.events[0].event.instrument_definition_observed.instrument);
    var request: [256]u8 = undefined;
    try std.testing.expectError(error.UnsupportedFrame, feed.subscription(.context, &request));
    var small_sink: TestSink = .{};
    var small_feed = HyperliquidMarketFeed.init(test_binding, small_sink.sink(), 0);
    const small_adapter = small_feed.adapter();
    var config = test_config;
    config.output_capacity = 3;
    try small_adapter.start(config);
    try small_feed.ingest(std.testing.allocator, 0, .metadata, test_times, test_metadata);
    _ = try small_adapter.tryDrain();
    try small_feed.ingest(std.testing.allocator, 1, .subscribe, test_times, "subscribe");
    _ = try small_adapter.tryDrain();
    const rows = "[{\"coin\":\"BTC\",\"time\":1000000,\"tid\":1,\"side\":\"B\",\"px\":\"99\",\"sz\":\"2\"},{\"coin\":\"BTC\",\"time\":1000000,\"tid\":2,\"side\":\"B\",\"px\":\"99\",\"sz\":\"2\"},{\"coin\":\"BTC\",\"time\":1000000,\"tid\":3,\"side\":\"B\",\"px\":\"99\",\"sz\":\"2\"}]";
    try std.testing.expectError(error.OutputCapacityExceeded, small_feed.ingest(std.testing.allocator, 1, .trades, test_times, rows));
    const gap = (try small_adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 1), gap.len);
    try std.testing.expectEqual(c.MarketDataHealth.gap, gap.events[0].event.market_data_health_changed.health);
}

test "Hyperliquid late disconnect cannot lower the fresh subscription barrier" {
    var sink: TestSink = .{};
    var feed = HyperliquidMarketFeed.init(test_binding, sink.sink(), 0);
    const adapter = try startTest(&feed);
    var later = test_times;
    later.monotonic_time_ns += 100;
    later.receive_time_utc_ns += 1_000_000;
    try feed.ingest(std.testing.allocator, 2, .subscribe, later, "subscribe");
    _ = try adapter.tryDrain();
    try feed.ingest(std.testing.allocator, 2, .disconnected, test_times, "late disconnect");
    _ = try adapter.tryDrain();
    try std.testing.expectError(error.StaleSession, feed.ingest(std.testing.allocator, 3, .subscribe, test_times, "old subscribe"));
    const rejected = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(c.MarketDataHealth.gap, rejected.events[0].event.market_data_health_changed.health);
    try feed.ingest(std.testing.allocator, 3, .subscribe, later, "fresh subscribe");
    _ = try adapter.tryDrain();
    try std.testing.expectError(error.AwaitingFreshSnapshot, feed.ingest(std.testing.allocator, 3, .book, later, test_book));
    _ = try adapter.tryDrain();
}

test "Hyperliquid same-frame duplicates and conflicts are atomic and retired trade coverage fails closed" {
    var sink: TestSink = .{};
    var feed = HyperliquidMarketFeed.init(test_binding, sink.sink(), 0);
    const adapter = try startTest(&feed);
    const row = "{\"coin\":\"BTC\",\"time\":1000000,\"tid\":7,\"side\":\"B\",\"px\":\"99\",\"sz\":\"2\"}";
    try feed.ingest(std.testing.allocator, 1, .trades, test_times, "[" ++ row ++ "," ++ row ++ "]");
    const unique = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 1), unique.len);
    const conflict = "[{\"coin\":\"BTC\",\"time\":1000000,\"tid\":8,\"side\":\"B\",\"px\":\"99\",\"sz\":\"2\"},{\"coin\":\"BTC\",\"time\":1000000,\"tid\":8,\"side\":\"B\",\"px\":\"99\",\"sz\":\"3\"}]";
    try std.testing.expectError(error.ConflictingTrade, feed.ingest(std.testing.allocator, 1, .trades, test_times, conflict));
    const rejected = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 1), rejected.len);
    try std.testing.expectEqual(c.EventType.market_data_health_changed, c.eventType(rejected.events[0].event));
    try feed.ingest(std.testing.allocator, 2, .subscribe, test_times, "subscribe");
    _ = try adapter.tryDrain();
    const Row = struct { coin: []const u8 = "BTC", time: u64, tid: u64, side: []const u8 = "B", px: []const u8 = "99", sz: []const u8 = "2" };
    var rows: [30]Row = undefined;
    for (0..9) |batch_index| {
        for (&rows, 0..) |*item, index| item.* = .{ .time = 1_000_000 + batch_index, .tid = 100 + batch_index * 30 + index };
        const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, rows, .{});
        defer std.testing.allocator.free(bytes);
        var times = test_times;
        times.receive_time_utc_ns += batch_index * 1_000_000;
        try feed.ingest(std.testing.allocator, 2, .trades, times, bytes);
        const batch = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(@as(u8, 30), batch.len);
    }
    try std.testing.expectError(error.TradeCoverageExceeded, feed.ingest(std.testing.allocator, 2, .trades, test_times, "[{\"coin\":\"BTC\",\"time\":1000000,\"tid\":1,\"side\":\"B\",\"px\":\"99\",\"sz\":\"2\"}]"));
    _ = try adapter.tryDrain();
}

test "Hyperliquid cached initial book stays unqualified until a fresh book in the same new epoch" {
    var sink: TestSink = .{};
    var feed = HyperliquidMarketFeed.init(test_binding, sink.sink(), 0);
    const adapter = try startTest(&feed);
    var subscribed = test_times;
    subscribed.receive_time_utc_ns += 1_000_000;
    subscribed.monotonic_time_ns += 100;
    try feed.ingest(std.testing.allocator, 2, .subscribe, subscribed, "subscribe");
    _ = try adapter.tryDrain();
    var received = subscribed;
    received.receive_time_utc_ns += 3_000_000;
    received.monotonic_time_ns += 100;
    try std.testing.expectError(error.AwaitingFreshSnapshot, feed.ingest(std.testing.allocator, 2, .book, received, test_book));
    const cached = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(c.MarketDataHealth.gap, cached.events[0].event.market_data_health_changed.health);
    const fresh = try std.mem.replaceOwned(u8, std.testing.allocator, test_book, "1000000", "1000001");
    defer std.testing.allocator.free(fresh);
    try feed.ingest(std.testing.allocator, 2, .book, received, fresh);
    const qualified = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(c.EventType.l2_book_snapshot, c.eventType(qualified.events[0].event));
    try std.testing.expectEqual(@as(u64, 2), qualified.events[0].event.l2_book_snapshot.capture_epoch);
    try std.testing.expectError(error.StaleFrame, feed.ingest(std.testing.allocator, 2, .book, received, test_book));
    _ = try adapter.tryDrain();
    try std.testing.expectError(error.FreshSubscriptionRequired, feed.ingest(std.testing.allocator, 2, .book, received, fresh));
    _ = try adapter.tryDrain();
}

test "Hyperliquid approved metadata rejects same-id margin table changes even after restart" {
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, test_metadata, "\"lowerBound\":\"0\"", "\"lowerBound\":\"1\"");
    defer std.testing.allocator.free(changed);
    for ([_]bool{ false, true }) |restarted| {
        var sink: TestSink = .{};
        var feed = HyperliquidMarketFeed.init(test_binding, sink.sink(), 1);
        const adapter = feed.adapter();
        try adapter.start(test_config);
        if (!restarted) {
            try feed.ingest(std.testing.allocator, 1, .metadata, test_times, test_metadata);
            _ = try adapter.tryDrain();
        }
        try std.testing.expectError(error.InstrumentRulesChanged, feed.ingest(std.testing.allocator, 1, .metadata, test_times, changed));
        const gap = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(c.MarketDataHealth.gap, gap.events[0].event.market_data_health_changed.health);
        try feed.ingest(std.testing.allocator, 2, .subscribe, test_times, "subscribe");
        _ = try adapter.tryDrain();
        try std.testing.expectError(error.MissingInstrumentRules, feed.ingest(std.testing.allocator, 2, .book, test_times, test_book));
        _ = try adapter.tryDrain();
    }
    var sink: TestSink = .{};
    var feed = HyperliquidMarketFeed.init(test_binding, sink.sink(), 0);
    const adapter = feed.adapter();
    try adapter.start(test_config);
    try std.testing.expectError(error.DuplicateMarginTable, feed.ingest(std.testing.allocator, 0, .metadata, test_times, "{\"collateralToken\":0,\"universe\":[{\"name\":\"BTC\",\"szDecimals\":0,\"maxLeverage\":40,\"marginTableId\":54}],\"marginTables\":[[54,{}],[54,{}]]}"));
    _ = try adapter.tryDrain();
    try std.testing.expectError(error.MissingMarginTable, feed.ingest(std.testing.allocator, 0, .metadata, test_times, "{\"collateralToken\":0,\"universe\":[{\"name\":\"BTC\",\"szDecimals\":0,\"maxLeverage\":40,\"marginTableId\":54}],\"marginTables\":[]}"));
    _ = try adapter.tryDrain();
    var unbound = test_binding;
    unbound.expected_metadata_digest = @splat(0);
    var unbound_feed = HyperliquidMarketFeed.init(unbound, sink.sink(), 0);
    try std.testing.expectError(error.InvalidConfig, unbound_feed.adapter().start(test_config));
}
