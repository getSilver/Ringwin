//! Authoritative BTC-USDT spot projection for qualified OKX private facts.
//! Amounts remain in their native assets at 1e-8 precision; valuation is not
//! mixed into the ledger. The private decoder remains the owner of raw ingress
//! and venue fact deduplication.

const std = @import("std");
const journal = @import("journal.zig");
const private = @import("okx_private_reconciliation.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const asset_scale: i128 = 100_000_000;
const stable_schema_version: u16 = 1;
const max_orders = 4;

const StableEventType = enum(u16) {
    okx_spot_execution_report = 1001,
    okx_spot_fill = 1002,
    okx_spot_balance_snapshot = 1003,
};

pub const OrderState = enum(u8) { live, partially_filled, filled, canceled };

pub const Layer = struct {
    btc_balance_atoms: i64 = 0,
    usdt_balance_atoms: i64 = 0,
    position_base_atoms: i64 = 0,
    open_cost_quote_atoms: i64 = 0,
    realized_pnl_quote_atoms: i64 = 0,
    fee_btc_atoms: i64 = 0,
    fee_usdt_atoms: i64 = 0,
    rebate_btc_atoms: i64 = 0,
    rebate_usdt_atoms: i64 = 0,
    ledger_transactions: u64 = 0,
};

const Order = struct {
    venue_order_id: private.VenueOrderId,
    client_order_id: private.ClientOrderId,
    side: private.Side,
    quantity_base_atoms: i64,
    reported_filled_base_atoms: i64,
    projected_filled_base_atoms: i64 = 0,
    state: OrderState,
};

const SeenFill = struct {
    venue_trade_id: private.VenueTradeId,
    source_fact_identity: [Sha256.digest_length]u8,
};

pub const Projection = struct {
    orders: [max_orders]Order = undefined,
    order_count: u8 = 0,
    portfolio: Layer = .{},
    exchange: Layer = .{},
    seen_fills: [16]SeenFill = undefined,
    seen_fill_count: u8 = 0,
    baseline_btc_atoms: ?i64 = null,
    baseline_usdt_atoms: ?i64 = null,
    observed_btc_atoms: ?i64 = null,
    observed_usdt_atoms: ?i64 = null,

    pub fn apply(self: *Projection, event: private.CanonicalEvent) !void {
        switch (event.payload) {
            .execution_report => |report| try self.applyReport(report),
            .fill => |fill| try self.applyFill(fill, event.envelope.source_fact_identity),
            .exchange_balance_snapshot => |snapshot| try self.observeBalance(snapshot),
            else => {},
        }
        try self.assertLayers();
    }

    pub fn state(self: *const Projection) ?OrderState {
        return if (self.order_count == 0) null else self.orders[self.order_count - 1].state;
    }

    pub fn orderState(self: *const Projection, venue_order_id: private.VenueOrderId) ?OrderState {
        const index = self.orderIndex(venue_order_id) orelse return null;
        return self.orders[index].state;
    }

    pub fn economicReconciled(self: *const Projection) bool {
        const base_btc = self.baseline_btc_atoms orelse return false;
        const base_usdt = self.baseline_usdt_atoms orelse return false;
        const observed_btc = self.observed_btc_atoms orelse return false;
        const observed_usdt = self.observed_usdt_atoms orelse return false;
        return observed_btc - base_btc == self.exchange.btc_balance_atoms and
            observed_usdt - base_usdt == self.exchange.usdt_balance_atoms;
    }

    pub fn digest(self: *const Projection) [Sha256.digest_length]u8 {
        var hasher = Sha256.init(.{});
        hasher.update(&.{self.order_count});
        for (self.orders[0..self.order_count]) |order| {
            hashInt(&hasher, u64, @intFromEnum(order.venue_order_id));
            hasher.update(order.client_order_id.slice());
            hasher.update(&.{ @intFromEnum(order.side), @intFromEnum(order.state) });
            hashInt(&hasher, i64, order.quantity_base_atoms);
            hashInt(&hasher, i64, order.reported_filled_base_atoms);
            hashInt(&hasher, i64, order.projected_filled_base_atoms);
        }
        hashLayer(&hasher, self.portfolio);
        hashLayer(&hasher, self.exchange);
        hasher.update(&.{self.seen_fill_count});
        for (self.seen_fills[0..self.seen_fill_count]) |seen| {
            hashInt(&hasher, i64, @intFromEnum(seen.venue_trade_id));
            hasher.update(&seen.source_fact_identity);
        }
        hashOptional(&hasher, self.baseline_btc_atoms);
        hashOptional(&hasher, self.baseline_usdt_atoms);
        hashOptional(&hasher, self.observed_btc_atoms);
        hashOptional(&hasher, self.observed_usdt_atoms);
        var result: [Sha256.digest_length]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn applyReport(self: *Projection, report: private.ExecutionReport) !void {
        if (!report.owned_by_ringwin or report.instrument != .btc_usdt_spot)
            return error.UnownedOrUnsupportedFact;
        const quantity = try atoms(report.quantity);
        const filled = try atoms(report.cumulative_filled_quantity);
        if (quantity <= 0 or filled < 0 or filled > quantity) return error.InvalidOrderQuantity;
        const next_state: OrderState = switch (report.status) {
            .live => .live,
            .partially_filled => .partially_filled,
            .filled => .filled,
            .canceled => .canceled,
        };
        try validateOrderState(next_state, filled, quantity);
        if (self.orderIndex(report.venue_order_id)) |index| {
            const order = &self.orders[index];
            if (!std.mem.eql(u8, order.client_order_id.slice(), report.client_order_id.slice()) or
                order.side != report.side or order.quantity_base_atoms != quantity)
                return error.ConflictingOrderIdentity;
            if (filled < order.reported_filled_base_atoms or filled < order.projected_filled_base_atoms)
                return error.RegressedOrderFact;
            if (!validTransition(order.state, next_state)) return error.ConflictingOrderState;
            order.reported_filled_base_atoms = filled;
            order.state = next_state;
        } else {
            if (self.order_count == self.orders.len) return error.OrderSetFull;
            self.orders[self.order_count] = .{
                .venue_order_id = report.venue_order_id,
                .client_order_id = report.client_order_id,
                .side = report.side,
                .quantity_base_atoms = quantity,
                .reported_filled_base_atoms = filled,
                .state = next_state,
            };
            self.order_count += 1;
        }
    }

    fn applyFill(
        self: *Projection,
        fill: private.Fill,
        source_fact_identity: [Sha256.digest_length]u8,
    ) !void {
        if (!fill.owned_by_ringwin or fill.instrument != .btc_usdt_spot)
            return error.UnownedOrUnsupportedFact;
        for (self.seen_fills[0..self.seen_fill_count]) |seen| {
            if (seen.venue_trade_id == fill.venue_trade_id) {
                if (!std.mem.eql(u8, &seen.source_fact_identity, &source_fact_identity))
                    return error.ConflictingFillIdentity;
                return;
            }
        }
        if (self.seen_fill_count == self.seen_fills.len) return error.FillSetFull;
        const order_index = self.orderIndex(fill.venue_order_id) orelse return error.FillBeforeOrder;
        const order = &self.orders[order_index];
        if (!std.mem.eql(u8, order.client_order_id.slice(), fill.client_order_id.slice()) or
            order.side != fill.side)
            return error.FillOrderMismatch;
        const quantity = try atoms(fill.quantity);
        const price = try atoms(fill.price);
        if (quantity <= 0 or price <= 0) return error.InvalidFill;
        const next_filled = try std.math.add(i64, order.projected_filled_base_atoms, quantity);
        if (next_filled > order.reported_filled_base_atoms) return error.FillAheadOfReport;
        var next_portfolio = self.portfolio;
        var next_exchange = self.exchange;
        try applyEconomic(&next_portfolio, fill.side, quantity, price, fill.fee, fill.fee_asset, fill.realized_pnl);
        try applyEconomic(&next_exchange, fill.side, quantity, price, fill.fee, fill.fee_asset, fill.realized_pnl);
        self.portfolio = next_portfolio;
        self.exchange = next_exchange;
        order.projected_filled_base_atoms = next_filled;
        self.seen_fills[self.seen_fill_count] = .{ .venue_trade_id = fill.venue_trade_id, .source_fact_identity = source_fact_identity };
        self.seen_fill_count += 1;
    }

    fn observeBalance(self: *Projection, snapshot: private.ExchangeBalanceSnapshot) !void {
        var btc: ?i64 = null;
        var usdt: ?i64 = null;
        for (snapshot.balances[0..snapshot.balance_count]) |balance| {
            const cash = balance.cash_balance orelse continue;
            if (std.mem.eql(u8, balance.asset.slice(), "BTC")) btc = try atoms(cash);
            if (std.mem.eql(u8, balance.asset.slice(), "USDT")) usdt = try atoms(cash);
        }
        if (snapshot.scope == .full_rest and self.seen_fill_count == 0) {
            if (btc) |value| self.baseline_btc_atoms = value;
            if (usdt) |value| self.baseline_usdt_atoms = value;
        }
        if (btc) |value| self.observed_btc_atoms = value;
        if (usdt) |value| self.observed_usdt_atoms = value;
    }

    fn assertLayers(self: *const Projection) !void {
        if (!std.meta.eql(self.portfolio, self.exchange)) return error.EconomicLayerMismatch;
    }

    fn orderIndex(self: *const Projection, venue_order_id: private.VenueOrderId) ?usize {
        for (self.orders[0..self.order_count], 0..) |order, index|
            if (order.venue_order_id == venue_order_id) return index;
        return null;
    }
};

pub fn appendStable(log: *journal.Journal, sequence: u64, event: private.CanonicalEvent) !void {
    var encoded: StablePayload = .{};
    try encoded.put(u64, event.envelope.raw_evidence.stream_sequence);
    try encoded.bytesValue(&event.envelope.raw_evidence.sha256);
    try encoded.bytesValue(&event.envelope.source_fact_identity);
    const event_type: StableEventType = switch (event.payload) {
        .execution_report => |value| blk: {
            if (!value.owned_by_ringwin or value.instrument != .btc_usdt_spot)
                return error.UnownedOrUnsupportedFact;
            try encodeReport(&encoded, value);
            break :blk .okx_spot_execution_report;
        },
        .fill => |value| blk: {
            if (!value.owned_by_ringwin or value.instrument != .btc_usdt_spot)
                return error.UnownedOrUnsupportedFact;
            try encodeFill(&encoded, value);
            break :blk .okx_spot_fill;
        },
        .exchange_balance_snapshot => |value| blk: {
            try encodeBalance(&encoded, value);
            break :blk .okx_spot_balance_snapshot;
        },
        else => return error.UnsupportedStableEvent,
    };
    try log.append(.{
        .type_id = @intFromEnum(event_type),
        .schema_version = stable_schema_version,
        .flags = journal.input_flag,
        .sequence = sequence,
        .source_time = event.envelope.source_time_utc_ns orelse 0,
        .receive_time = event.envelope.receive_time_utc_ns,
        .monotonic_time = event.envelope.monotonic_time_ns,
        .wall_time = event.envelope.wall_time_utc_ns,
        .time_presence = .{
            .source = event.envelope.source_time_utc_ns != null,
            .receive = true,
            .monotonic = true,
            .wall = true,
        },
        .payload = encoded.slice(),
    });
}

pub fn replayStable(bytes: []const u8) !Projection {
    var projection: Projection = .{};
    var reader = try journal.Reader.init(bytes);
    while (true) switch (try reader.next()) {
        .record => |record| try projection.apply(try decodeStable(record)),
        .end => |status| {
            if (status != .clean) return error.TruncatedStableReplay;
            return projection;
        },
    };
}

fn decodeStable(record: journal.Record) !private.CanonicalEvent {
    if (record.schema_version != stable_schema_version) return error.UnknownStableSchema;
    if (record.flags != journal.input_flag) return error.InvalidStableFlags;
    if (!record.time_presence.receive or !record.time_presence.monotonic or
        !record.time_presence.wall or record.time_presence.reserved != 0 or
        (!record.time_presence.source and record.source_time != 0))
        return error.InvalidStableTimes;
    const event_type = std.enums.fromInt(StableEventType, record.type_id) orelse
        return error.UnknownStableEventType;
    var decoder: StableDecoder = .{ .bytes = record.payload };
    const raw_sequence = try decoder.take(u64);
    const raw_hash = try decoder.takeBytes(Sha256.digest_length);
    const fact_identity = try decoder.takeBytes(Sha256.digest_length);
    const payload: private.EventPayload = switch (event_type) {
        .okx_spot_execution_report => .{ .execution_report = try decodeReport(&decoder) },
        .okx_spot_fill => .{ .fill = try decodeFill(&decoder) },
        .okx_spot_balance_snapshot => .{ .exchange_balance_snapshot = try decodeBalance(&decoder) },
    };
    if (decoder.offset != decoder.bytes.len) return error.TrailingStablePayload;
    var evidence_hash: [Sha256.digest_length]u8 = undefined;
    var identity: [Sha256.digest_length]u8 = undefined;
    @memcpy(&evidence_hash, raw_hash);
    @memcpy(&identity, fact_identity);
    return .{
        .envelope = .{
            .source_time_utc_ns = if (record.time_presence.source) record.source_time else null,
            .receive_time_utc_ns = record.receive_time,
            .monotonic_time_ns = record.monotonic_time,
            .wall_time_utc_ns = record.wall_time,
            .raw_evidence = .{ .stream_sequence = raw_sequence, .sha256 = evidence_hash },
            .source_fact_identity = identity,
        },
        .payload = payload,
    };
}

const StablePayload = struct {
    bytes: [2048]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const StablePayload) []const u8 {
        return self.bytes[0..self.len];
    }

    fn put(self: *StablePayload, comptime T: type, value: T) !void {
        if (self.bytes.len - self.len < @sizeOf(T)) return error.StablePayloadTooLarge;
        std.mem.writeInt(T, self.bytes[self.len..][0..@sizeOf(T)], value, .little);
        self.len += @sizeOf(T);
    }

    fn bytesValue(self: *StablePayload, value: []const u8) !void {
        if (self.bytes.len - self.len < value.len) return error.StablePayloadTooLarge;
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
    }

    fn boolean(self: *StablePayload, value: bool) !void {
        try self.put(u8, @intFromBool(value));
    }

    fn decimal(self: *StablePayload, value: private.Decimal) !void {
        try self.put(i128, value.coefficient);
        try self.put(u8, value.scale);
    }

    fn optionalDecimal(self: *StablePayload, value: ?private.Decimal) !void {
        try self.boolean(value != null);
        if (value) |present| try self.decimal(present);
    }

    fn text(self: *StablePayload, value: anytype) !void {
        const bytes = value.slice();
        if (bytes.len > std.math.maxInt(u8)) return error.StableTextTooLong;
        try self.put(u8, @intCast(bytes.len));
        try self.bytesValue(bytes);
    }
};

const StableDecoder = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *StableDecoder, comptime T: type) !T {
        if (self.bytes.len - self.offset < @sizeOf(T)) return error.TruncatedStablePayload;
        defer self.offset += @sizeOf(T);
        return std.mem.readInt(T, self.bytes[self.offset..][0..@sizeOf(T)], .little);
    }

    fn takeBytes(self: *StableDecoder, length: usize) ![]const u8 {
        if (self.bytes.len - self.offset < length) return error.TruncatedStablePayload;
        defer self.offset += length;
        return self.bytes[self.offset..][0..length];
    }

    fn boolean(self: *StableDecoder) !bool {
        return switch (try self.take(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidStableBoolean,
        };
    }

    fn decimal(self: *StableDecoder) !private.Decimal {
        const value: private.Decimal = .{ .coefficient = try self.take(i128), .scale = try self.take(u8) };
        if (value.scale > 0 and @mod(value.coefficient, 10) == 0)
            return error.NonCanonicalStableDecimal;
        return value;
    }

    fn optionalDecimal(self: *StableDecoder) !?private.Decimal {
        return if (try self.boolean()) try self.decimal() else null;
    }

    fn text(self: *StableDecoder, comptime T: type) !T {
        return T.init(try self.takeBytes(try self.take(u8)));
    }
};

fn encodeReport(encoded: *StablePayload, value: private.ExecutionReport) !void {
    try encoded.put(u64, @intFromEnum(value.venue_order_id));
    try encoded.text(value.client_order_id);
    try encoded.put(u8, @intFromEnum(value.instrument));
    try encoded.put(u8, @intFromEnum(value.side));
    try encoded.put(u8, @intFromEnum(value.order_type));
    try encoded.put(u8, @intFromEnum(value.status));
    try encoded.decimal(value.quantity);
    try encoded.optionalDecimal(value.limit_price);
    try encoded.decimal(value.cumulative_filled_quantity);
    try encoded.optionalDecimal(value.average_fill_price);
    try encoded.text(value.request_id);
    try encoded.boolean(value.last_trade_id != null);
    if (value.last_trade_id) |trade_id| try encoded.put(i64, @intFromEnum(trade_id));
    try encoded.put(u64, value.venue_update_time_utc_ns);
    try encoded.boolean(value.owned_by_ringwin);
}

fn decodeReport(decoder: *StableDecoder) !private.ExecutionReport {
    return .{
        .venue_order_id = @enumFromInt(try decoder.take(u64)),
        .client_order_id = try decoder.text(private.ClientOrderId),
        .instrument = std.enums.fromInt(private.Instrument, try decoder.take(u8)) orelse return error.InvalidStableEnum,
        .side = std.enums.fromInt(private.Side, try decoder.take(u8)) orelse return error.InvalidStableEnum,
        .order_type = std.enums.fromInt(private.OrderType, try decoder.take(u8)) orelse return error.InvalidStableEnum,
        .status = std.enums.fromInt(private.ExecutionStatus, try decoder.take(u8)) orelse return error.InvalidStableEnum,
        .quantity = try decoder.decimal(),
        .limit_price = try decoder.optionalDecimal(),
        .cumulative_filled_quantity = try decoder.decimal(),
        .average_fill_price = try decoder.optionalDecimal(),
        .request_id = try decoder.text(private.FixedText(32)),
        .last_trade_id = if (try decoder.boolean()) @enumFromInt(try decoder.take(i64)) else null,
        .venue_update_time_utc_ns = try decoder.take(u64),
        .owned_by_ringwin = try decoder.boolean(),
    };
}

fn encodeFill(encoded: *StablePayload, value: private.Fill) !void {
    try encoded.put(i64, @intFromEnum(value.venue_trade_id));
    try encoded.boolean(value.venue_bill_id != null);
    if (value.venue_bill_id) |bill_id| try encoded.put(u64, @intFromEnum(bill_id));
    try encoded.put(u64, @intFromEnum(value.venue_order_id));
    try encoded.text(value.client_order_id);
    try encoded.put(u8, @intFromEnum(value.instrument));
    try encoded.put(u8, @intFromEnum(value.side));
    try encoded.decimal(value.quantity);
    try encoded.decimal(value.price);
    try encoded.decimal(value.fee);
    try encoded.text(value.fee_asset);
    try encoded.optionalDecimal(value.realized_pnl);
    try encoded.boolean(value.liquidity != null);
    if (value.liquidity) |liquidity| try encoded.put(u8, @intFromEnum(liquidity));
    try encoded.put(u64, value.venue_fill_time_utc_ns);
    try encoded.boolean(value.owned_by_ringwin);
}

fn decodeFill(decoder: *StableDecoder) !private.Fill {
    return .{
        .venue_trade_id = @enumFromInt(try decoder.take(i64)),
        .venue_bill_id = if (try decoder.boolean()) @enumFromInt(try decoder.take(u64)) else null,
        .venue_order_id = @enumFromInt(try decoder.take(u64)),
        .client_order_id = try decoder.text(private.ClientOrderId),
        .instrument = std.enums.fromInt(private.Instrument, try decoder.take(u8)) orelse return error.InvalidStableEnum,
        .side = std.enums.fromInt(private.Side, try decoder.take(u8)) orelse return error.InvalidStableEnum,
        .quantity = try decoder.decimal(),
        .price = try decoder.decimal(),
        .fee = try decoder.decimal(),
        .fee_asset = try decoder.text(private.AssetCode),
        .realized_pnl = try decoder.optionalDecimal(),
        .liquidity = if (try decoder.boolean()) std.enums.fromInt(private.Liquidity, try decoder.take(u8)) orelse return error.InvalidStableEnum else null,
        .venue_fill_time_utc_ns = try decoder.take(u64),
        .owned_by_ringwin = try decoder.boolean(),
    };
}

fn encodeBalance(encoded: *StablePayload, value: private.ExchangeBalanceSnapshot) !void {
    try encoded.put(u8, @intFromEnum(value.scope));
    try encoded.put(u64, value.venue_update_time_utc_ns);
    try encoded.put(u8, value.balance_count);
    for (value.balances[0..value.balance_count]) |balance| {
        try encoded.text(balance.asset);
        try encoded.optionalDecimal(balance.cash_balance);
        try encoded.optionalDecimal(balance.available_balance);
        try encoded.optionalDecimal(balance.equity);
        try encoded.optionalDecimal(balance.frozen_balance);
        try encoded.optionalDecimal(balance.liability);
        try encoded.optionalDecimal(balance.isolated_liability);
        try encoded.optionalDecimal(balance.cross_liability);
    }
}

fn decodeBalance(decoder: *StableDecoder) !private.ExchangeBalanceSnapshot {
    var result: private.ExchangeBalanceSnapshot = .{
        .scope = std.enums.fromInt(private.SnapshotScope, try decoder.take(u8)) orelse return error.InvalidStableEnum,
        .venue_update_time_utc_ns = try decoder.take(u64),
    };
    result.balance_count = try decoder.take(u8);
    if (result.balance_count > result.balances.len) return error.InvalidStableBalanceCount;
    for (result.balances[0..result.balance_count]) |*balance| balance.* = .{
        .asset = try decoder.text(private.AssetCode),
        .cash_balance = try decoder.optionalDecimal(),
        .available_balance = try decoder.optionalDecimal(),
        .equity = try decoder.optionalDecimal(),
        .frozen_balance = try decoder.optionalDecimal(),
        .liability = try decoder.optionalDecimal(),
        .isolated_liability = try decoder.optionalDecimal(),
        .cross_liability = try decoder.optionalDecimal(),
    };
    return result;
}

fn validateOrderState(state: OrderState, filled: i64, quantity: i64) !void {
    const valid = switch (state) {
        .live => filled == 0,
        .partially_filled => filled > 0 and filled < quantity,
        .filled => filled == quantity,
        .canceled => filled < quantity,
    };
    if (!valid) return error.InvalidOrderState;
}

fn validTransition(current: OrderState, next: OrderState) bool {
    return switch (current) {
        .live => true,
        .partially_filled => next != .live,
        .filled => next == .filled,
        .canceled => next == .canceled,
    };
}

fn applyEconomic(
    layer: *Layer,
    side: private.Side,
    quantity: i64,
    price: i64,
    venue_fee: private.Decimal,
    fee_asset: private.AssetCode,
    venue_realized_pnl: ?private.Decimal,
) !void {
    const fee_atoms = try atoms(venue_fee);
    const fee_is_btc = std.mem.eql(u8, fee_asset.slice(), "BTC");
    if (side == .sell and fee_is_btc and fee_atoms != 0)
        return error.UnsupportedSellBaseFee;
    const product = try std.math.mul(i128, quantity, price);
    if (@mod(product, asset_scale) != 0) return error.InexactQuoteAmount;
    const quote = std.math.cast(i64, @divTrunc(product, asset_scale)) orelse return error.Overflow;
    const realized_before = layer.realized_pnl_quote_atoms;
    switch (side) {
        .buy => {
            layer.btc_balance_atoms = try std.math.add(i64, layer.btc_balance_atoms, quantity);
            layer.usdt_balance_atoms = try std.math.sub(i64, layer.usdt_balance_atoms, quote);
            layer.position_base_atoms = try std.math.add(i64, layer.position_base_atoms, quantity);
            layer.open_cost_quote_atoms = try std.math.add(i64, layer.open_cost_quote_atoms, quote);
            if (fee_is_btc and fee_atoms != 0) {
                const net_quantity = try std.math.add(i64, quantity, fee_atoms);
                if (net_quantity <= 0) return error.InvalidBaseFee;
                layer.position_base_atoms = try std.math.add(i64, layer.position_base_atoms, fee_atoms);
                if (fee_atoms < 0) {
                    const fee_cost_product = try std.math.mul(i128, -@as(i128, fee_atoms), price);
                    const fee_cost = std.math.cast(i64, @divFloor(fee_cost_product, asset_scale)) orelse
                        return error.Overflow;
                    layer.open_cost_quote_atoms = try std.math.sub(i64, layer.open_cost_quote_atoms, fee_cost);
                }
            }
        },
        .sell => {
            if (quantity > layer.position_base_atoms) return error.SpotShortNotAllowed;
            const released = if (quantity == layer.position_base_atoms)
                layer.open_cost_quote_atoms
            else
                std.math.cast(i64, @divFloor(
                    try std.math.mul(i128, layer.open_cost_quote_atoms, quantity),
                    layer.position_base_atoms,
                )) orelse return error.Overflow;
            layer.btc_balance_atoms = try std.math.sub(i64, layer.btc_balance_atoms, quantity);
            layer.usdt_balance_atoms = try std.math.add(i64, layer.usdt_balance_atoms, quote);
            layer.position_base_atoms = try std.math.sub(i64, layer.position_base_atoms, quantity);
            layer.open_cost_quote_atoms = try std.math.sub(i64, layer.open_cost_quote_atoms, released);
            layer.realized_pnl_quote_atoms = try std.math.add(
                i64,
                layer.realized_pnl_quote_atoms,
                try std.math.sub(i64, quote, released),
            );
        },
    }
    layer.ledger_transactions = try std.math.add(u64, layer.ledger_transactions, 1);
    try applyFee(layer, venue_fee, fee_asset);
    if (venue_realized_pnl) |reported| {
        const venue_value = try atoms(reported);
        // OKX SPOT reports fillPnl as zero; local inventory cost owns SPOT realized PnL.
        if (venue_value != 0 and venue_value != layer.realized_pnl_quote_atoms - realized_before)
            return error.RealizedPnlMismatch;
    }
}

fn applyFee(layer: *Layer, venue_fee: private.Decimal, fee_asset: private.AssetCode) !void {
    const signed = try atoms(venue_fee);
    if (signed == 0) return;
    const btc = std.mem.eql(u8, fee_asset.slice(), "BTC");
    const usdt = std.mem.eql(u8, fee_asset.slice(), "USDT");
    if (!btc and !usdt) return error.UnsupportedFeeAsset;
    if (btc) layer.btc_balance_atoms = try std.math.add(i64, layer.btc_balance_atoms, signed);
    if (usdt) layer.usdt_balance_atoms = try std.math.add(i64, layer.usdt_balance_atoms, signed);
    if (signed < 0) {
        const expense = std.math.negate(signed) catch return error.Overflow;
        if (btc) layer.fee_btc_atoms = try std.math.add(i64, layer.fee_btc_atoms, expense);
        if (usdt) layer.fee_usdt_atoms = try std.math.add(i64, layer.fee_usdt_atoms, expense);
    } else {
        if (btc) layer.rebate_btc_atoms = try std.math.add(i64, layer.rebate_btc_atoms, signed);
        if (usdt) layer.rebate_usdt_atoms = try std.math.add(i64, layer.rebate_usdt_atoms, signed);
    }
    layer.ledger_transactions = try std.math.add(u64, layer.ledger_transactions, 1);
}

fn atoms(value: private.Decimal) !i64 {
    var scaled = value.coefficient;
    if (value.scale < 8) {
        for (value.scale..8) |_| scaled = try std.math.mul(i128, scaled, 10);
    } else if (value.scale > 8) {
        var divisor: i128 = 1;
        for (8..value.scale) |_| divisor = try std.math.mul(i128, divisor, 10);
        if (@mod(scaled, divisor) != 0) return error.InexactAssetAmount;
        scaled = @divTrunc(scaled, divisor);
    }
    return std.math.cast(i64, scaled) orelse error.Overflow;
}

fn hashLayer(hasher: *Sha256, layer: Layer) void {
    inline for (std.meta.fields(Layer)) |field| hashInt(hasher, field.type, @field(layer, field.name));
}

fn hashOptional(hasher: *Sha256, value: ?i64) void {
    if (value) |present| {
        hasher.update(&.{1});
        hashInt(hasher, i64, present);
    } else hasher.update(&.{0});
}

fn hashInt(hasher: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn envelope(identity: u8) private.EventEnvelope {
    return .{
        .source_time_utc_ns = 1,
        .receive_time_utc_ns = 2,
        .monotonic_time_ns = 3,
        .wall_time_utc_ns = 4,
        .raw_evidence = .{ .stream_sequence = identity, .sha256 = @splat(identity) },
        .source_fact_identity = @splat(identity),
    };
}

fn fixtureReport(status: private.ExecutionStatus, filled: []const u8) !private.CanonicalEvent {
    return fixtureOrderReport(10, "RWN1DEMO", .buy, status, "0.0001", filled);
}

fn fixtureOrderReport(
    venue_order_id: u64,
    client_order_id: []const u8,
    side: private.Side,
    status: private.ExecutionStatus,
    quantity: []const u8,
    filled: []const u8,
) !private.CanonicalEvent {
    return .{ .envelope = envelope(@intFromEnum(status) + 1), .payload = .{ .execution_report = .{
        .venue_order_id = @enumFromInt(venue_order_id),
        .client_order_id = try private.ClientOrderId.init(client_order_id),
        .instrument = .btc_usdt_spot,
        .side = side,
        .order_type = .market,
        .status = status,
        .quantity = try private.Decimal.parse(quantity),
        .limit_price = null,
        .cumulative_filled_quantity = try private.Decimal.parse(filled),
        .average_fill_price = if (status == .filled) try private.Decimal.parse("50000") else null,
        .request_id = try private.FixedText(32).init(""),
        .last_trade_id = if (status == .filled) @enumFromInt(20) else null,
        .venue_update_time_utc_ns = 1,
        .owned_by_ringwin = true,
    } } };
}

test "OKX spot fill projects native fee dual layers and replays deterministically" {
    var initial: private.ExchangeBalanceSnapshot = .{ .scope = .full_rest, .venue_update_time_utc_ns = 1 };
    initial.balances[0] = .{ .asset = try private.AssetCode.init("BTC"), .cash_balance = try private.Decimal.parse("1"), .available_balance = null, .equity = null, .frozen_balance = null, .liability = null, .isolated_liability = null, .cross_liability = null };
    initial.balances[1] = .{ .asset = try private.AssetCode.init("USDT"), .cash_balance = try private.Decimal.parse("1000"), .available_balance = null, .equity = null, .frozen_balance = null, .liability = null, .isolated_liability = null, .cross_liability = null };
    initial.balance_count = 2;
    const events = [_]private.CanonicalEvent{
        .{ .envelope = envelope(1), .payload = .{ .exchange_balance_snapshot = initial } },
        try fixtureReport(.live, "0"),
        try fixtureReport(.filled, "0.0001"),
        .{ .envelope = envelope(4), .payload = .{ .fill = .{
            .venue_trade_id = @enumFromInt(20),
            .venue_bill_id = @enumFromInt(30),
            .venue_order_id = @enumFromInt(10),
            .client_order_id = try private.ClientOrderId.init("RWN1DEMO"),
            .instrument = .btc_usdt_spot,
            .side = .buy,
            .quantity = try private.Decimal.parse("0.0001"),
            .price = try private.Decimal.parse("50000"),
            .fee = try private.Decimal.parse("-0.00000008"),
            .fee_asset = try private.AssetCode.init("BTC"),
            .realized_pnl = try private.Decimal.parse("0"),
            .liquidity = .taker,
            .venue_fill_time_utc_ns = 1,
            .owned_by_ringwin = true,
        } } },
    };
    var first: Projection = .{};
    for (events) |event| try first.apply(event);
    try std.testing.expectEqual(OrderState.filled, first.state().?);
    try std.testing.expectEqual(@as(i64, 9_992), first.portfolio.position_base_atoms);
    try std.testing.expectEqual(@as(i64, 499_600_000), first.portfolio.open_cost_quote_atoms);
    try std.testing.expectEqual(@as(i64, 8), first.portfolio.fee_btc_atoms);
    try std.testing.expectEqual(@as(i64, 9_992), first.portfolio.btc_balance_atoms);
    try std.testing.expectEqual(@as(i64, -500_000_000), first.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(u64, 2), first.portfolio.ledger_transactions);

    var final = initial;
    final.scope = .ws_reported;
    final.balances[0].cash_balance = try private.Decimal.parse("1.00009992");
    final.balances[1].cash_balance = try private.Decimal.parse("995");
    const final_event: private.CanonicalEvent = .{ .envelope = envelope(5), .payload = .{ .exchange_balance_snapshot = final } };
    try first.apply(final_event);
    try std.testing.expect(first.economicReconciled());

    var stable = journal.Journal.init();
    for (events, 1..) |event, sequence| try appendStable(&stable, sequence, event);
    try appendStable(&stable, events.len + 1, final_event);
    try stable.seal();
    const replayed = try replayStable(stable.bytes());
    try std.testing.expectEqualSlices(u8, &first.digest(), &replayed.digest());
    try std.testing.expectError(
        error.TruncatedStableReplay,
        replayStable(stable.bytes()[0 .. stable.bytes().len - 1]),
    );
    var reader = try journal.Reader.init(stable.bytes());
    var first_record = (try reader.next()).record;
    first_record.schema_version = 2;
    try std.testing.expectError(error.UnknownStableSchema, decodeStable(first_record));
}

test "spot partial sell releases average cost and records venue USDT fee" {
    var layer: Layer = .{};
    try applyEconomic(
        &layer,
        .buy,
        10_000,
        5_000_000_000_000,
        try private.Decimal.parse("-0.00000008"),
        try private.AssetCode.init("BTC"),
        try private.Decimal.parse("0"),
    );
    try applyEconomic(
        &layer,
        .sell,
        4_000,
        5_100_000_000_000,
        try private.Decimal.parse("-0.001"),
        try private.AssetCode.init("USDT"),
        try private.Decimal.parse("0.04"),
    );
    try std.testing.expectEqual(@as(i64, 5_992), layer.position_base_atoms);
    try std.testing.expectEqual(@as(i64, 299_600_000), layer.open_cost_quote_atoms);
    try std.testing.expectEqual(@as(i64, 4_000_000), layer.realized_pnl_quote_atoms);
    try std.testing.expectEqual(@as(i64, 100_000), layer.fee_usdt_atoms);
    try std.testing.expectEqual(@as(u64, 4), layer.ledger_transactions);
}

test "spot base fee cost uses quote-atom floor at live tick precision" {
    var layer: Layer = .{};
    try applyEconomic(
        &layer,
        .buy,
        5_000,
        6_354_790_000_000,
        try private.Decimal.parse("-0.00000004"),
        try private.AssetCode.init("BTC"),
        try private.Decimal.parse("0"),
    );
    try std.testing.expectEqual(@as(i64, 4_996), layer.position_base_atoms);
    try std.testing.expectEqual(@as(i64, 317_485_309), layer.open_cost_quote_atoms);
}

test "spot projection retains strategy and cleanup orders across stable replay" {
    const events = [_]private.CanonicalEvent{
        try fixtureOrderReport(10, "RWN1BUY", .buy, .filled, "0.0001", "0.0001"),
        .{ .envelope = envelope(10), .payload = .{ .fill = .{
            .venue_trade_id = @enumFromInt(20),
            .venue_bill_id = @enumFromInt(30),
            .venue_order_id = @enumFromInt(10),
            .client_order_id = try private.ClientOrderId.init("RWN1BUY"),
            .instrument = .btc_usdt_spot,
            .side = .buy,
            .quantity = try private.Decimal.parse("0.0001"),
            .price = try private.Decimal.parse("50000"),
            .fee = try private.Decimal.parse("-0.00000008"),
            .fee_asset = try private.AssetCode.init("BTC"),
            .realized_pnl = try private.Decimal.parse("0"),
            .liquidity = .taker,
            .venue_fill_time_utc_ns = 1,
            .owned_by_ringwin = true,
        } } },
        try fixtureOrderReport(11, "RWN1SELL", .sell, .filled, "0.00009992", "0.00009992"),
        .{ .envelope = envelope(11), .payload = .{ .fill = .{
            .venue_trade_id = @enumFromInt(21),
            .venue_bill_id = @enumFromInt(31),
            .venue_order_id = @enumFromInt(11),
            .client_order_id = try private.ClientOrderId.init("RWN1SELL"),
            .instrument = .btc_usdt_spot,
            .side = .sell,
            .quantity = try private.Decimal.parse("0.00009992"),
            .price = try private.Decimal.parse("50100"),
            .fee = try private.Decimal.parse("-0.00400599"),
            .fee_asset = try private.AssetCode.init("USDT"),
            .realized_pnl = try private.Decimal.parse("0"),
            .liquidity = .taker,
            .venue_fill_time_utc_ns = 1,
            .owned_by_ringwin = true,
        } } },
    };
    var projection: Projection = .{};
    var stable = journal.Journal.init();
    for (events, 1..) |event, sequence| {
        try projection.apply(event);
        try appendStable(&stable, sequence, event);
    }
    try stable.seal();
    try std.testing.expectEqual(@as(u8, 2), projection.order_count);
    try std.testing.expectEqual(OrderState.filled, projection.orderState(@enumFromInt(10)).?);
    try std.testing.expectEqual(OrderState.filled, projection.orderState(@enumFromInt(11)).?);
    try std.testing.expectEqual(@as(i64, 0), projection.portfolio.position_base_atoms);
    try std.testing.expectEqual(@as(i64, 0), projection.portfolio.open_cost_quote_atoms);
    const replayed = try replayStable(stable.bytes());
    try std.testing.expectEqualSlices(u8, &projection.digest(), &replayed.digest());
}
