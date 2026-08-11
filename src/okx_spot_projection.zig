//! Authoritative BTC-USDT spot projection for qualified OKX private facts.
//! Amounts remain in their native assets at 1e-8 precision; valuation is not
//! mixed into the ledger. The private decoder remains the owner of raw ingress
//! and venue fact deduplication.

const std = @import("std");
const private = @import("okx_private_reconciliation.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const asset_scale: i128 = 100_000_000;

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
    order: ?Order = null,
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
        return if (self.order) |order| order.state else null;
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
        if (self.order) |order| {
            hasher.update(&.{1});
            hashInt(&hasher, u64, @intFromEnum(order.venue_order_id));
            hasher.update(order.client_order_id.slice());
            hasher.update(&.{ @intFromEnum(order.side), @intFromEnum(order.state) });
            hashInt(&hasher, i64, order.quantity_base_atoms);
            hashInt(&hasher, i64, order.reported_filled_base_atoms);
            hashInt(&hasher, i64, order.projected_filled_base_atoms);
        } else hasher.update(&.{0});
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
        if (self.order) |*order| {
            if (order.venue_order_id != report.venue_order_id or
                !std.mem.eql(u8, order.client_order_id.slice(), report.client_order_id.slice()) or
                order.side != report.side or order.quantity_base_atoms != quantity)
                return error.ConflictingOrderIdentity;
            if (filled < order.reported_filled_base_atoms or filled < order.projected_filled_base_atoms)
                return error.RegressedOrderFact;
            if (!validTransition(order.state, next_state)) return error.ConflictingOrderState;
            order.reported_filled_base_atoms = filled;
            order.state = next_state;
        } else {
            self.order = .{
                .venue_order_id = report.venue_order_id,
                .client_order_id = report.client_order_id,
                .side = report.side,
                .quantity_base_atoms = quantity,
                .reported_filled_base_atoms = filled,
                .state = next_state,
            };
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
        const order = &(self.order orelse return error.FillBeforeOrder);
        if (order.venue_order_id != fill.venue_order_id or
            !std.mem.eql(u8, order.client_order_id.slice(), fill.client_order_id.slice()) or
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
};

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
        if (venue_value != layer.realized_pnl_quote_atoms - realized_before)
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
    return .{ .envelope = envelope(@intFromEnum(status) + 1), .payload = .{ .execution_report = .{
        .venue_order_id = @enumFromInt(10),
        .client_order_id = try private.ClientOrderId.init("RWN1DEMO"),
        .instrument = .btc_usdt_spot,
        .side = .buy,
        .order_type = .market,
        .status = status,
        .quantity = try private.Decimal.parse("0.0001"),
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
    try std.testing.expectEqual(@as(i64, 10_000), first.portfolio.position_base_atoms);
    try std.testing.expectEqual(@as(i64, 500_000_000), first.portfolio.open_cost_quote_atoms);
    try std.testing.expectEqual(@as(i64, 8), first.portfolio.fee_btc_atoms);
    try std.testing.expectEqual(@as(i64, 9_992), first.portfolio.btc_balance_atoms);
    try std.testing.expectEqual(@as(i64, -500_000_000), first.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(u64, 2), first.portfolio.ledger_transactions);

    var final = initial;
    final.scope = .ws_reported;
    final.balances[0].cash_balance = try private.Decimal.parse("1.00009992");
    final.balances[1].cash_balance = try private.Decimal.parse("995");
    try first.apply(.{ .envelope = envelope(5), .payload = .{ .exchange_balance_snapshot = final } });
    try std.testing.expect(first.economicReconciled());

    var replayed: Projection = .{};
    for (events) |event| try replayed.apply(event);
    try replayed.apply(.{ .envelope = envelope(5), .payload = .{ .exchange_balance_snapshot = final } });
    try std.testing.expectEqualSlices(u8, &first.digest(), &replayed.digest());
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
    try std.testing.expectEqual(@as(i64, 6_000), layer.position_base_atoms);
    try std.testing.expectEqual(@as(i64, 300_000_000), layer.open_cost_quote_atoms);
    try std.testing.expectEqual(@as(i64, 4_000_000), layer.realized_pnl_quote_atoms);
    try std.testing.expectEqual(@as(i64, 100_000), layer.fee_usdt_atoms);
    try std.testing.expectEqual(@as(u64, 4), layer.ledger_transactions);
}
