const std = @import("std");

pub const ppm_scale: i64 = 1_000_000;

pub const Product = enum(u8) { spot, isolated_linear_usdt };
pub const Side = enum(u8) { buy, sell };
pub const MarginGate = enum(u8) { healthy, warning, kill };

pub const Limits = struct {
    strategy_micros: i64,
    portfolio_micros: i64,
    decision_domain_micros: i64,
    exchange_account_micros: i64,
    global_micros: i64,
};

pub const Rules = struct {
    quantity_denominator: i64,
    price_tick_micros: i64 = 1,
    venue_initial_margin_ppm: i64,
    internal_initial_margin_ppm: i64,
    internal_maintenance_margin_ppm: i64,
    fee_ppm: i64,
    opening_buffer_micros: i64,
    opening_buffer_bps: i64 = 0,
    opening_liquidation_distance_ticks: i64 = 0,
    warning_buffer_micros: i64,
    kill_buffer_micros: i64,
    warning_buffer_bps: i64 = 0,
    kill_buffer_bps: i64 = 0,
    warning_liquidation_distance_ticks: i64 = 0,
    kill_liquidation_distance_ticks: i64 = 0,
};

pub const State = struct {
    portfolio_cash_micros: i64,
    exchange_cash_micros: i64,
    portfolio_position_quantity: i64,
    exchange_position_quantity: i64,
    active_order_reservations_micros: i64,
    replaced_order_reservation_micros: i64 = 0,
    mark_price_micros: i64,
};

pub const Request = struct {
    product: Product,
    side: Side,
    quantity: i64,
    risk_price_micros: i64,
    portfolio_reduce_only: bool = false,
};

pub const Assessment = struct {
    order_reservation_micros: i64,
    total_reserved_micros: i64,
    venue_initial_margin_micros: i64,
    internal_initial_margin_micros: i64,
    fee_buffer_micros: i64,
    portfolio_margin_buffer_micros: i64,
    exchange_margin_buffer_micros: i64,
    portfolio_buffer_bps: i64,
    exchange_buffer_bps: i64,
    portfolio_liquidation_distance_ticks: i64,
    exchange_liquidation_distance_ticks: i64,
    portfolio_gate: MarginGate,
    exchange_gate: MarginGate,
    portfolio_reduce_only: bool,
    venue_reduce_only: bool,
};

pub fn assess(rules: Rules, limits: Limits, state: State, request: Request) !Assessment {
    if (rules.quantity_denominator <= 0 or rules.price_tick_micros <= 0 or rules.venue_initial_margin_ppm <= 0 or
        rules.internal_initial_margin_ppm < rules.venue_initial_margin_ppm or
        rules.internal_maintenance_margin_ppm <= 0 or rules.fee_ppm < 0 or
        rules.opening_buffer_micros < rules.warning_buffer_micros or
        rules.warning_buffer_micros < rules.kill_buffer_micros or
        rules.kill_buffer_micros < 0 or
        (rules.opening_buffer_bps > 0 and rules.opening_buffer_bps < rules.warning_buffer_bps) or
        rules.warning_buffer_bps < rules.kill_buffer_bps or
        rules.kill_buffer_bps < 0 or
        (rules.opening_liquidation_distance_ticks > 0 and rules.opening_liquidation_distance_ticks < rules.warning_liquidation_distance_ticks) or
        rules.warning_liquidation_distance_ticks < rules.kill_liquidation_distance_ticks or
        rules.kill_liquidation_distance_ticks < 0 or request.quantity <= 0 or
        request.risk_price_micros <= 0 or state.mark_price_micros <= 0)
        return error.InvalidRiskInput;

    const direction: i64 = if (request.side == .buy) 1 else -1;
    const portfolio_after = try std.math.add(i64, state.portfolio_position_quantity, try std.math.mul(i64, direction, request.quantity));
    const exchange_after = try std.math.add(i64, state.exchange_position_quantity, try std.math.mul(i64, direction, request.quantity));
    const portfolio_reduces = reducesWithoutCrossing(state.portfolio_position_quantity, portfolio_after);
    const venue_reduces = reducesWithoutCrossing(state.exchange_position_quantity, exchange_after);
    if (request.portfolio_reduce_only and !portfolio_reduces) return error.PortfolioReduceOnlyViolation;
    if (request.product == .spot and request.side == .sell and portfolio_after < 0)
        return error.InsufficientSpotAsset;

    const notional = try notionalMicros(request.quantity, request.risk_price_micros, rules.quantity_denominator);
    const fee = try rateMicros(notional, rules.fee_ppm);
    const venue_initial = if (request.product == .isolated_linear_usdt and !venue_reduces)
        try rateMicros(notional, rules.venue_initial_margin_ppm)
    else
        0;
    const internal_initial = if (request.product == .isolated_linear_usdt and !portfolio_reduces)
        try rateMicros(notional, rules.internal_initial_margin_ppm)
    else
        0;
    const reservation = switch (request.product) {
        .spot => if (request.side == .buy) try std.math.add(i64, notional, fee) else fee,
        .isolated_linear_usdt => try std.math.add(i64, @max(internal_initial, venue_initial), fee),
    };

    const base = try std.math.sub(i64, state.active_order_reservations_micros, state.replaced_order_reservation_micros);
    if (base < 0) return error.InvalidRiskInput;
    const replacement_reservation = @max(state.replaced_order_reservation_micros, reservation);
    const total = try std.math.add(i64, base, replacement_reservation);
    try checkLimits(limits, total);

    const portfolio_maintenance = if (request.product == .isolated_linear_usdt)
        try maintenanceWithCloseFee(rules, portfolio_after, state.mark_price_micros)
    else
        0;
    const exchange_maintenance = if (request.product == .isolated_linear_usdt)
        try maintenanceWithCloseFee(rules, exchange_after, state.mark_price_micros)
    else
        0;
    const portfolio_buffer = try std.math.sub(i64, try std.math.sub(i64, state.portfolio_cash_micros, total), portfolio_maintenance);
    const exchange_buffer = try std.math.sub(i64, try std.math.sub(i64, state.exchange_cash_micros, total), exchange_maintenance);
    const portfolio_after_notional = try notionalMicros(std.math.cast(i64, abs128(portfolio_after)) orelse return error.Overflow, state.mark_price_micros, rules.quantity_denominator);
    const exchange_after_notional = try notionalMicros(std.math.cast(i64, abs128(exchange_after)) orelse return error.Overflow, state.mark_price_micros, rules.quantity_denominator);
    const portfolio_buffer_bps = try bufferBps(portfolio_buffer, portfolio_after_notional);
    const exchange_buffer_bps = try bufferBps(exchange_buffer, exchange_after_notional);
    const portfolio_distance = try liquidationDistanceTicks(portfolio_buffer, portfolio_after, rules.quantity_denominator, rules.price_tick_micros);
    const exchange_distance = try liquidationDistanceTicks(exchange_buffer, exchange_after, rules.quantity_denominator, rules.price_tick_micros);
    const account_risk_increasing = !portfolio_reduces or !venue_reduces;
    if (account_risk_increasing and !opens(rules, portfolio_buffer, portfolio_buffer_bps, portfolio_distance)) return error.PortfolioOpeningGateClosed;
    if (account_risk_increasing and !opens(rules, exchange_buffer, exchange_buffer_bps, exchange_distance)) return error.ExchangeOpeningGateClosed;

    return .{
        .order_reservation_micros = reservation,
        .total_reserved_micros = total,
        .venue_initial_margin_micros = venue_initial,
        .internal_initial_margin_micros = internal_initial,
        .fee_buffer_micros = fee,
        .portfolio_margin_buffer_micros = portfolio_buffer,
        .exchange_margin_buffer_micros = exchange_buffer,
        .portfolio_buffer_bps = portfolio_buffer_bps,
        .exchange_buffer_bps = exchange_buffer_bps,
        .portfolio_liquidation_distance_ticks = portfolio_distance,
        .exchange_liquidation_distance_ticks = exchange_distance,
        .portfolio_gate = marginGate(rules, portfolio_buffer, portfolio_buffer_bps, portfolio_distance),
        .exchange_gate = marginGate(rules, exchange_buffer, exchange_buffer_bps, exchange_distance),
        .portfolio_reduce_only = portfolio_reduces,
        .venue_reduce_only = venue_reduces,
    };
}

fn opens(rules: Rules, buffer: i64, buffer_bps: i64, distance_ticks: i64) bool {
    return buffer >= rules.opening_buffer_micros and
        (rules.opening_buffer_bps == 0 or buffer_bps >= rules.opening_buffer_bps) and
        (rules.opening_liquidation_distance_ticks == 0 or distance_ticks >= rules.opening_liquidation_distance_ticks);
}

fn maintenanceWithCloseFee(rules: Rules, quantity: i64, price_micros: i64) !i64 {
    const absolute = std.math.cast(i64, abs128(quantity)) orelse return error.Overflow;
    const notional = try notionalMicros(absolute, price_micros, rules.quantity_denominator);
    return std.math.add(i64, try rateMicros(notional, rules.internal_maintenance_margin_ppm), try rateMicros(notional, rules.fee_ppm));
}

fn marginGate(rules: Rules, buffer: i64, buffer_bps: i64, distance_ticks: i64) MarginGate {
    if (buffer <= rules.kill_buffer_micros or
        (rules.kill_buffer_bps > 0 and buffer_bps <= rules.kill_buffer_bps) or
        (rules.kill_liquidation_distance_ticks > 0 and distance_ticks <= rules.kill_liquidation_distance_ticks)) return .kill;
    if (buffer <= rules.warning_buffer_micros or
        (rules.warning_buffer_bps > 0 and buffer_bps <= rules.warning_buffer_bps) or
        (rules.warning_liquidation_distance_ticks > 0 and distance_ticks <= rules.warning_liquidation_distance_ticks)) return .warning;
    return .healthy;
}

fn bufferBps(buffer: i64, notional: i64) !i64 {
    if (notional == 0) return std.math.maxInt(i64);
    return std.math.cast(i64, @divFloor(@as(i128, buffer) * 10_000, notional)) orelse error.Overflow;
}

fn liquidationDistanceTicks(buffer: i64, quantity: i64, denominator: i64, tick_micros: i64) !i64 {
    if (quantity == 0) return std.math.maxInt(i64);
    const per_tick_loss = try ceilPositive(abs128(quantity) * tick_micros, denominator);
    if (buffer <= 0) return 0;
    return std.math.cast(i64, @divFloor(@as(i128, buffer), per_tick_loss)) orelse error.Overflow;
}

fn checkLimits(limits: Limits, required: i64) !void {
    if (limits.strategy_micros <= 0 or required > limits.strategy_micros) return error.StrategyLimitExceeded;
    if (limits.portfolio_micros <= 0 or required > limits.portfolio_micros) return error.VirtualPortfolioLimitExceeded;
    if (limits.decision_domain_micros <= 0 or required > limits.decision_domain_micros) return error.DecisionDomainLimitExceeded;
    if (limits.exchange_account_micros <= 0 or required > limits.exchange_account_micros) return error.ExchangeAccountLimitExceeded;
    if (limits.global_micros <= 0 or required > limits.global_micros) return error.GlobalLimitExceeded;
}

fn reducesWithoutCrossing(before: i64, after: i64) bool {
    if (before == 0) return false;
    if ((before > 0 and after < 0) or (before < 0 and after > 0)) return false;
    return abs128(after) < abs128(before);
}

fn abs128(value: i64) i128 {
    const wide: i128 = value;
    return if (wide < 0) -wide else wide;
}

fn notionalMicros(quantity: i64, price_micros: i64, denominator: i64) !i64 {
    return ceilPositive(@as(i128, quantity) * price_micros, denominator);
}

fn rateMicros(notional: i64, ppm: i64) !i64 {
    return ceilPositive(@as(i128, notional) * ppm, ppm_scale);
}

fn ceilPositive(numerator: i128, denominator: i128) !i64 {
    if (numerator < 0 or denominator <= 0) return error.InvalidRiskInput;
    return std.math.cast(i64, @divFloor(numerator + denominator - 1, denominator)) orelse error.Overflow;
}

test "five layers, cash, isolated margin, and dual reduce-only are deterministic" {
    const rules: Rules = .{ .quantity_denominator = 100, .venue_initial_margin_ppm = 100_000, .internal_initial_margin_ppm = 120_000, .internal_maintenance_margin_ppm = 60_000, .fee_ppm = 750, .opening_buffer_micros = 1_000_000, .warning_buffer_micros = 500_000, .kill_buffer_micros = 100_000 };
    const limits: Limits = .{ .strategy_micros = 100_000_000, .portfolio_micros = 100_000_000, .decision_domain_micros = 100_000_000, .exchange_account_micros = 100_000_000, .global_micros = 100_000_000 };
    const state: State = .{ .portfolio_cash_micros = 100_000_000, .exchange_cash_micros = 100_000_000, .portfolio_position_quantity = 10, .exchange_position_quantity = -5, .active_order_reservations_micros = 0, .mark_price_micros = 50_000_000 };

    const spot = try assess(rules, limits, state, .{ .product = .spot, .side = .buy, .quantity = 2, .risk_price_micros = 50_000_000 });
    try std.testing.expectEqual(@as(i64, 1_000_750), spot.order_reservation_micros);

    const swap = try assess(rules, limits, state, .{ .product = .isolated_linear_usdt, .side = .sell, .quantity = 8, .risk_price_micros = 50_000_000, .portfolio_reduce_only = true });
    try std.testing.expect(swap.portfolio_reduce_only);
    try std.testing.expect(!swap.venue_reduce_only);
    try std.testing.expectEqual(@as(i64, 400_000), swap.venue_initial_margin_micros);
    try std.testing.expectEqual(@as(i64, 403_000), swap.order_reservation_micros);

    const inferred = try assess(rules, limits, state, .{ .product = .isolated_linear_usdt, .side = .sell, .quantity = 8, .risk_price_micros = 50_000_000 });
    try std.testing.expect(inferred.portfolio_reduce_only);
    try std.testing.expect(!inferred.venue_reduce_only);

    var tight = limits;
    tight.strategy_micros = 100;
    try std.testing.expectError(error.StrategyLimitExceeded, assess(rules, tight, state, .{ .product = .spot, .side = .buy, .quantity = 2, .risk_price_micros = 50_000_000 }));
}

test "margin safety gate takes the strictest amount bps and liquidation distance" {
    const rules: Rules = .{
        .quantity_denominator = 100,
        .price_tick_micros = 1_000,
        .venue_initial_margin_ppm = 100_000,
        .internal_initial_margin_ppm = 120_000,
        .internal_maintenance_margin_ppm = 60_000,
        .fee_ppm = 750,
        .opening_buffer_micros = 1_000_000,
        .warning_buffer_micros = 500_000,
        .kill_buffer_micros = 100_000,
        .warning_buffer_bps = 1_000,
        .kill_buffer_bps = 500,
        .warning_liquidation_distance_ticks = 50_000,
        .kill_liquidation_distance_ticks = 15_000,
    };
    const limits: Limits = .{ .strategy_micros = 100_000_000, .portfolio_micros = 100_000_000, .decision_domain_micros = 100_000_000, .exchange_account_micros = 100_000_000, .global_micros = 100_000_000 };
    const assessment = try assess(rules, limits, .{ .portfolio_cash_micros = 2_000_000, .exchange_cash_micros = 2_000_000, .portfolio_position_quantity = 10, .exchange_position_quantity = 10, .active_order_reservations_micros = 0, .mark_price_micros = 50_000_000 }, .{ .product = .isolated_linear_usdt, .side = .buy, .quantity = 1, .risk_price_micros = 50_000_000 });
    try std.testing.expectEqual(MarginGate.kill, assessment.portfolio_gate);
    try std.testing.expect(assessment.portfolio_buffer_bps > 500);
    try std.testing.expectEqual(@as(i64, 14_595), assessment.portfolio_liquidation_distance_ticks);
}

test "opening gate rejects sufficient cash with insufficient liquidation distance" {
    const rules: Rules = .{
        .quantity_denominator = 100,
        .price_tick_micros = 1_000,
        .venue_initial_margin_ppm = 100_000,
        .internal_initial_margin_ppm = 120_000,
        .internal_maintenance_margin_ppm = 60_000,
        .fee_ppm = 750,
        .opening_buffer_micros = 1_000_000,
        .warning_buffer_micros = 500_000,
        .kill_buffer_micros = 100_000,
        .opening_liquidation_distance_ticks = 20_000,
    };
    const limits: Limits = .{ .strategy_micros = 100_000_000, .portfolio_micros = 100_000_000, .decision_domain_micros = 100_000_000, .exchange_account_micros = 100_000_000, .global_micros = 100_000_000 };
    try std.testing.expectError(error.PortfolioOpeningGateClosed, assess(rules, limits, .{ .portfolio_cash_micros = 2_000_000, .exchange_cash_micros = 2_000_000, .portfolio_position_quantity = 10, .exchange_position_quantity = 10, .active_order_reservations_micros = 0, .mark_price_micros = 50_000_000 }, .{ .product = .isolated_linear_usdt, .side = .buy, .quantity = 1, .risk_price_micros = 50_000_000 }));
}
