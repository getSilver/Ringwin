const std = @import("std");
const canonical = @import("canonical_event.zig");

pub const ppm_scale: i128 = 1_000_000;

pub const Product = enum(u8) { spot, isolated_linear_usdt };
pub const Side = enum(u8) { buy, sell };
pub const MarginGate = enum(u8) { healthy, warning, kill };

pub const Limits = struct {
    strategy: canonical.AssetAmount,
    portfolio: canonical.AssetAmount,
    decision_domain: canonical.AssetAmount,
    exchange_account: canonical.AssetAmount,
    global: canonical.AssetAmount,
};

pub const Rules = struct {
    settlement_asset: canonical.AssetIdentity,
    instrument: canonical.InstrumentIdentity,
    rules_version: u64,
    quantity_denominator: i64,
    price_tick_value: canonical.AssetAmount,
    venue_initial_margin_ppm: i64,
    internal_initial_margin_ppm: i64,
    internal_maintenance_margin_ppm: i64,
    fee_ppm: i64,
    opening_buffer: canonical.AssetAmount,
    opening_buffer_bps: i64 = 0,
    opening_liquidation_distance_ticks: i64 = 0,
    warning_buffer: canonical.AssetAmount,
    kill_buffer: canonical.AssetAmount,
    warning_buffer_bps: i64 = 0,
    kill_buffer_bps: i64 = 0,
    warning_liquidation_distance_ticks: i64 = 0,
    kill_liquidation_distance_ticks: i64 = 0,
};

pub const State = struct {
    portfolio_cash: canonical.AssetAmount,
    exchange_cash: canonical.AssetAmount,
    portfolio_position: canonical.InstrumentQuantity,
    exchange_position: canonical.InstrumentQuantity,
    active_order_reservations: canonical.AssetAmount,
    replaced_order_reservation: canonical.AssetAmount,
    mark_price: canonical.InstrumentPrice,
};

pub const Request = struct {
    product: Product,
    side: Side,
    quantity: canonical.InstrumentQuantity,
    risk_price: canonical.InstrumentPrice,
    portfolio_reduce_only: bool = false,
};

pub const Assessment = struct {
    order_reservation: canonical.AssetAmount,
    total_reserved: canonical.AssetAmount,
    venue_initial_margin: canonical.AssetAmount,
    internal_initial_margin: canonical.AssetAmount,
    fee_buffer: canonical.AssetAmount,
    portfolio_margin_buffer: canonical.AssetAmount,
    exchange_margin_buffer: canonical.AssetAmount,
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
    const asset = rules.settlement_asset;
    if (rules.quantity_denominator <= 0 or rules.price_tick_value.asset != asset or rules.price_tick_value.atoms <= 0 or
        request.quantity.instrument != rules.instrument or request.quantity.rules_version != rules.rules_version or
        request.risk_price.instrument != rules.instrument or request.risk_price.rules_version != rules.rules_version or
        state.portfolio_position.instrument != rules.instrument or state.portfolio_position.rules_version != rules.rules_version or
        state.exchange_position.instrument != rules.instrument or state.exchange_position.rules_version != rules.rules_version or
        state.mark_price.instrument != rules.instrument or state.mark_price.rules_version != rules.rules_version or
        state.portfolio_cash.asset != asset or state.exchange_cash.asset != asset or
        state.active_order_reservations.asset != asset or state.replaced_order_reservation.asset != asset or
        limits.strategy.asset != asset or limits.portfolio.asset != asset or limits.decision_domain.asset != asset or
        limits.exchange_account.asset != asset or limits.global.asset != asset or
        rules.opening_buffer.asset != asset or rules.warning_buffer.asset != asset or rules.kill_buffer.asset != asset or
        rules.venue_initial_margin_ppm <= 0 or
        rules.internal_initial_margin_ppm < rules.venue_initial_margin_ppm or
        rules.internal_maintenance_margin_ppm <= 0 or rules.fee_ppm < 0 or
        rules.opening_buffer.atoms < rules.warning_buffer.atoms or
        rules.warning_buffer.atoms < rules.kill_buffer.atoms or
        rules.kill_buffer.atoms < 0 or
        (rules.opening_buffer_bps > 0 and rules.opening_buffer_bps < rules.warning_buffer_bps) or
        rules.warning_buffer_bps < rules.kill_buffer_bps or
        rules.kill_buffer_bps < 0 or
        (rules.opening_liquidation_distance_ticks > 0 and rules.opening_liquidation_distance_ticks < rules.warning_liquidation_distance_ticks) or
        rules.warning_liquidation_distance_ticks < rules.kill_liquidation_distance_ticks or
        rules.kill_liquidation_distance_ticks < 0 or request.quantity.lots <= 0 or
        request.risk_price.ticks <= 0 or state.mark_price.ticks <= 0)
        return error.InvalidRiskInput;

    const direction: i128 = if (request.side == .buy) 1 else -1;
    const portfolio_after = try std.math.add(i128, state.portfolio_position.lots, try std.math.mul(i128, direction, request.quantity.lots));
    const exchange_after = try std.math.add(i128, state.exchange_position.lots, try std.math.mul(i128, direction, request.quantity.lots));
    const portfolio_reduces = reducesWithoutCrossing(state.portfolio_position.lots, portfolio_after);
    const venue_reduces = reducesWithoutCrossing(state.exchange_position.lots, exchange_after);
    if (request.portfolio_reduce_only and !portfolio_reduces) return error.PortfolioReduceOnlyViolation;
    if (request.product == .spot and request.side == .sell and portfolio_after < 0)
        return error.InsufficientSpotAsset;

    const notional = try notionalAtoms(request.quantity.lots, request.risk_price.ticks, rules.quantity_denominator);
    const fee = try rateAtoms(notional, rules.fee_ppm);
    const venue_initial = if (request.product == .isolated_linear_usdt and !venue_reduces)
        try rateAtoms(notional, rules.venue_initial_margin_ppm)
    else
        0;
    const internal_initial = if (request.product == .isolated_linear_usdt and !portfolio_reduces)
        try rateAtoms(notional, rules.internal_initial_margin_ppm)
    else
        0;
    const reservation = switch (request.product) {
        .spot => if (request.side == .buy) try std.math.add(i128, notional, fee) else fee,
        .isolated_linear_usdt => try std.math.add(i128, @max(internal_initial, venue_initial), fee),
    };

    const base = try std.math.sub(i128, state.active_order_reservations.atoms, state.replaced_order_reservation.atoms);
    if (base < 0) return error.InvalidRiskInput;
    const replacement_reservation = @max(state.replaced_order_reservation.atoms, reservation);
    const total = try std.math.add(i128, base, replacement_reservation);
    try checkLimits(limits, total);

    const portfolio_maintenance = if (request.product == .isolated_linear_usdt)
        try maintenanceWithCloseFee(rules, portfolio_after, state.mark_price.ticks)
    else
        0;
    const exchange_maintenance = if (request.product == .isolated_linear_usdt)
        try maintenanceWithCloseFee(rules, exchange_after, state.mark_price.ticks)
    else
        0;
    const portfolio_buffer = try std.math.sub(i128, try std.math.sub(i128, state.portfolio_cash.atoms, total), portfolio_maintenance);
    const exchange_buffer = try std.math.sub(i128, try std.math.sub(i128, state.exchange_cash.atoms, total), exchange_maintenance);
    const portfolio_after_notional = try notionalAtoms(abs128(portfolio_after), state.mark_price.ticks, rules.quantity_denominator);
    const exchange_after_notional = try notionalAtoms(abs128(exchange_after), state.mark_price.ticks, rules.quantity_denominator);
    const portfolio_buffer_bps = try bufferBps(portfolio_buffer, portfolio_after_notional);
    const exchange_buffer_bps = try bufferBps(exchange_buffer, exchange_after_notional);
    const portfolio_distance = try liquidationDistanceTicks(portfolio_buffer, portfolio_after, rules.quantity_denominator, rules.price_tick_value.atoms);
    const exchange_distance = try liquidationDistanceTicks(exchange_buffer, exchange_after, rules.quantity_denominator, rules.price_tick_value.atoms);
    const account_risk_increasing = !portfolio_reduces or !venue_reduces;
    if (account_risk_increasing and !opens(rules, portfolio_buffer, portfolio_buffer_bps, portfolio_distance)) return error.PortfolioOpeningGateClosed;
    if (account_risk_increasing and !opens(rules, exchange_buffer, exchange_buffer_bps, exchange_distance)) return error.ExchangeOpeningGateClosed;

    return .{
        .order_reservation = .{ .asset = asset, .atoms = reservation },
        .total_reserved = .{ .asset = asset, .atoms = total },
        .venue_initial_margin = .{ .asset = asset, .atoms = venue_initial },
        .internal_initial_margin = .{ .asset = asset, .atoms = internal_initial },
        .fee_buffer = .{ .asset = asset, .atoms = fee },
        .portfolio_margin_buffer = .{ .asset = asset, .atoms = portfolio_buffer },
        .exchange_margin_buffer = .{ .asset = asset, .atoms = exchange_buffer },
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

fn opens(rules: Rules, buffer: i128, buffer_bps: i64, distance_ticks: i64) bool {
    return buffer >= rules.opening_buffer.atoms and
        (rules.opening_buffer_bps == 0 or buffer_bps >= rules.opening_buffer_bps) and
        (rules.opening_liquidation_distance_ticks == 0 or distance_ticks >= rules.opening_liquidation_distance_ticks);
}

fn maintenanceWithCloseFee(rules: Rules, quantity: i128, price_ticks: i128) !i128 {
    const notional = try notionalAtoms(abs128(quantity), price_ticks, rules.quantity_denominator);
    return std.math.add(i128, try rateAtoms(notional, rules.internal_maintenance_margin_ppm), try rateAtoms(notional, rules.fee_ppm));
}

fn marginGate(rules: Rules, buffer: i128, buffer_bps: i64, distance_ticks: i64) MarginGate {
    if (buffer <= rules.kill_buffer.atoms or
        (rules.kill_buffer_bps > 0 and buffer_bps <= rules.kill_buffer_bps) or
        (rules.kill_liquidation_distance_ticks > 0 and distance_ticks <= rules.kill_liquidation_distance_ticks)) return .kill;
    if (buffer <= rules.warning_buffer.atoms or
        (rules.warning_buffer_bps > 0 and buffer_bps <= rules.warning_buffer_bps) or
        (rules.warning_liquidation_distance_ticks > 0 and distance_ticks <= rules.warning_liquidation_distance_ticks)) return .warning;
    return .healthy;
}

fn bufferBps(buffer: i128, notional: i128) !i64 {
    if (notional == 0) return std.math.maxInt(i64);
    return std.math.cast(i64, @divFloor(@as(i128, buffer) * 10_000, notional)) orelse error.Overflow;
}

fn liquidationDistanceTicks(buffer: i128, quantity: i128, denominator: i64, tick_atoms: i128) !i64 {
    if (quantity == 0) return std.math.maxInt(i64);
    const per_tick_loss = try ceilPositive(abs128(quantity) * tick_atoms, denominator);
    if (buffer <= 0) return 0;
    return std.math.cast(i64, @divFloor(@as(i128, buffer), per_tick_loss)) orelse error.Overflow;
}

fn checkLimits(limits: Limits, required: i128) !void {
    if (limits.strategy.atoms <= 0 or required > limits.strategy.atoms) return error.StrategyLimitExceeded;
    if (limits.portfolio.atoms <= 0 or required > limits.portfolio.atoms) return error.VirtualPortfolioLimitExceeded;
    if (limits.decision_domain.atoms <= 0 or required > limits.decision_domain.atoms) return error.DecisionDomainLimitExceeded;
    if (limits.exchange_account.atoms <= 0 or required > limits.exchange_account.atoms) return error.ExchangeAccountLimitExceeded;
    if (limits.global.atoms <= 0 or required > limits.global.atoms) return error.GlobalLimitExceeded;
}

fn reducesWithoutCrossing(before: i128, after: i128) bool {
    if (before == 0) return false;
    if ((before > 0 and after < 0) or (before < 0 and after > 0)) return false;
    return abs128(after) < abs128(before);
}

fn abs128(value: i128) i128 {
    return if (value < 0) -value else value;
}

fn notionalAtoms(quantity: i128, price_ticks: i128, denominator: i64) !i128 {
    return ceilPositive(quantity * price_ticks, denominator);
}

fn rateAtoms(notional: i128, ppm: i64) !i128 {
    return ceilPositive(notional * ppm, ppm_scale);
}

fn ceilPositive(numerator: i128, denominator: i128) !i128 {
    if (numerator < 0 or denominator <= 0) return error.InvalidRiskInput;
    return @divFloor(numerator + denominator - 1, denominator);
}

const test_asset: canonical.AssetIdentity = 1;
const test_instrument: canonical.InstrumentIdentity = 2;

fn amount(atoms: i128) canonical.AssetAmount {
    return .{ .asset = test_asset, .atoms = atoms };
}

fn testQuantity(lots: i128) canonical.InstrumentQuantity {
    return .{ .instrument = test_instrument, .rules_version = 1, .lots = lots };
}

fn price(ticks: i128) canonical.InstrumentPrice {
    return .{ .instrument = test_instrument, .rules_version = 1, .ticks = ticks };
}

fn fixtureRules() Rules {
    return .{
        .settlement_asset = test_asset,
        .instrument = test_instrument,
        .rules_version = 1,
        .quantity_denominator = 100,
        .price_tick_value = amount(1),
        .venue_initial_margin_ppm = 100_000,
        .internal_initial_margin_ppm = 120_000,
        .internal_maintenance_margin_ppm = 60_000,
        .fee_ppm = 750,
        .opening_buffer = amount(1_000_000),
        .warning_buffer = amount(500_000),
        .kill_buffer = amount(100_000),
    };
}

fn fixtureLimits() Limits {
    return .{ .strategy = amount(100_000_000), .portfolio = amount(100_000_000), .decision_domain = amount(100_000_000), .exchange_account = amount(100_000_000), .global = amount(100_000_000) };
}

fn fixtureState() State {
    return .{ .portfolio_cash = amount(100_000_000), .exchange_cash = amount(100_000_000), .portfolio_position = testQuantity(10), .exchange_position = testQuantity(-5), .active_order_reservations = amount(0), .replaced_order_reservation = amount(0), .mark_price = price(50_000_000) };
}

test "five layers, cash, isolated margin, and dual reduce-only are deterministic" {
    const rules = fixtureRules();
    const limits = fixtureLimits();
    const state = fixtureState();

    const spot = try assess(rules, limits, state, .{ .product = .spot, .side = .buy, .quantity = testQuantity(2), .risk_price = price(50_000_000) });
    try std.testing.expectEqual(@as(i128, 1_000_750), spot.order_reservation.atoms);

    const swap = try assess(rules, limits, state, .{ .product = .isolated_linear_usdt, .side = .sell, .quantity = testQuantity(8), .risk_price = price(50_000_000), .portfolio_reduce_only = true });
    try std.testing.expect(swap.portfolio_reduce_only);
    try std.testing.expect(!swap.venue_reduce_only);
    try std.testing.expectEqual(@as(i128, 400_000), swap.venue_initial_margin.atoms);
    try std.testing.expectEqual(@as(i128, 403_000), swap.order_reservation.atoms);

    const inferred = try assess(rules, limits, state, .{ .product = .isolated_linear_usdt, .side = .sell, .quantity = testQuantity(8), .risk_price = price(50_000_000) });
    try std.testing.expect(inferred.portfolio_reduce_only);
    try std.testing.expect(!inferred.venue_reduce_only);

    var tight = limits;
    tight.strategy = amount(100);
    try std.testing.expectError(error.StrategyLimitExceeded, assess(rules, tight, state, .{ .product = .spot, .side = .buy, .quantity = testQuantity(2), .risk_price = price(50_000_000) }));
}

test "margin safety gate takes the strictest amount bps and liquidation distance" {
    var rules = fixtureRules();
    rules.price_tick_value = amount(1_000);
    rules.warning_buffer_bps = 1_000;
    rules.kill_buffer_bps = 500;
    rules.warning_liquidation_distance_ticks = 50_000;
    rules.kill_liquidation_distance_ticks = 15_000;
    const state: State = .{ .portfolio_cash = amount(2_000_000), .exchange_cash = amount(2_000_000), .portfolio_position = testQuantity(10), .exchange_position = testQuantity(10), .active_order_reservations = amount(0), .replaced_order_reservation = amount(0), .mark_price = price(50_000_000) };
    const assessment = try assess(rules, fixtureLimits(), state, .{ .product = .isolated_linear_usdt, .side = .buy, .quantity = testQuantity(1), .risk_price = price(50_000_000) });
    try std.testing.expectEqual(MarginGate.kill, assessment.portfolio_gate);
    try std.testing.expect(assessment.portfolio_buffer_bps > 500);
    try std.testing.expectEqual(@as(i64, 14_595), assessment.portfolio_liquidation_distance_ticks);
}

test "opening gate rejects sufficient cash with insufficient liquidation distance" {
    var rules = fixtureRules();
    rules.price_tick_value = amount(1_000);
    rules.opening_liquidation_distance_ticks = 20_000;
    const state: State = .{ .portfolio_cash = amount(2_000_000), .exchange_cash = amount(2_000_000), .portfolio_position = testQuantity(10), .exchange_position = testQuantity(10), .active_order_reservations = amount(0), .replaced_order_reservation = amount(0), .mark_price = price(50_000_000) };
    try std.testing.expectError(error.PortfolioOpeningGateClosed, assess(rules, fixtureLimits(), state, .{ .product = .isolated_linear_usdt, .side = .buy, .quantity = testQuantity(1), .risk_price = price(50_000_000) }));
}
