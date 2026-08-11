const std = @import("std");

pub const money_scale: i64 = 1_000_000;
const rate_scale: i128 = 1_000_000;

pub const Tier = struct {
    upper_notional: i64,
    imr_ppm: u32,
    mmr_ppm: u32,
    deduction: i64,
};

pub const Rules = struct {
    tiers: []const Tier,
    contract_num: i64,
    contract_den: i64,
    price_tick: i64,
    fee_ppm: u32,
    leverage_milli: u32,
};

pub const State = struct {
    qty: i64,
    entry_price: i64,
    mark_price: i64,
    open_buy_qty: i64 = 0,
    open_sell_qty: i64 = 0,
    buy_worst_price: i64 = 0,
    sell_worst_price: i64 = 0,
    buy_portfolio_reduce_only: bool = false,
    sell_portfolio_reduce_only: bool = false,
    margin: i64,
};

pub const Assessment = struct {
    current_tier: usize,
    worst_im_tier: usize,
    effective_imr_ppm: u32,
    position_notional: i64,
    worst_notional: i64,
    initial_margin: i64,
    maintenance_margin: i64,
    order_fee_reserve: i64,
    reservation_required: i64,
    reservation_surplus: i64,
    close_fee_buffer: i64,
    upl: i64,
    equity: i64,
    margin_buffer: i64,
    projected_side: Side,
    projected_qty: i64,
    projected_maintenance_margin: i64,
    projected_equity: i64,
    projected_margin_buffer: i64,
};

pub const Side = enum { current, buy, sell };

pub const Liquidation = struct {
    price: i64,
    distance_ticks: u64,
    distance_bps: u64,
};

pub const ReduceOnly = struct {
    portfolio: bool,
    venue: bool,
};

pub const Contributor = struct {
    id: u32,
    qty: i64,
};

pub const ForcedEconomics = struct {
    qty: i64,
    realized_pnl: i64,
    fee: i64,
    penalty: i64,
};

pub const Allocation = struct {
    id: u32,
    qty: i64,
    realized_pnl: i64,
    fee: i64,
    penalty: i64,
    remainder: i128,
};

const Margin = struct {
    tier: usize,
    amount: i64,
    effective_rate_ppm: u32,
};

const Scenario = struct {
    side: Side,
    order_qty: i64,
    fill_qty: i64,
    final_qty: i64,
    price: i64,
};

const Projection = struct {
    side: Side,
    qty: i64,
    maintenance_margin: i64,
    equity: i64,
    buffer: i64,
};

fn ceilDivPositive(numerator: i128, denominator: i128) !i64 {
    if (numerator < 0 or denominator <= 0) return error.InvalidPositiveDivision;
    return std.math.cast(i64, @divFloor(numerator + denominator - 1, denominator)) orelse
        error.Overflow;
}

fn floorDivSigned(numerator: i128, denominator: i128) !i64 {
    if (denominator <= 0) return error.InvalidDenominator;
    return std.math.cast(i64, @divFloor(numerator, denominator)) orelse error.Overflow;
}

fn abs128(value: i64) i128 {
    const wide: i128 = value;
    return if (wide < 0) -wide else wide;
}

pub fn notional(rules: Rules, qty: i64, price: i64) !i64 {
    if (price <= 0 or rules.contract_num <= 0 or rules.contract_den <= 0)
        return error.InvalidRules;
    return ceilDivPositive(
        abs128(qty) * price * rules.contract_num,
        rules.contract_den,
    );
}

fn rateCeil(amount: i64, ppm: u32) !i64 {
    if (amount < 0) return error.InvalidAmount;
    return ceilDivPositive(@as(i128, amount) * ppm, rate_scale);
}

fn tierIndex(rules: Rules, amount: i64) !usize {
    if (rules.tiers.len == 0) return error.NoTiers;
    for (rules.tiers, 0..) |tier, index| {
        if (amount <= tier.upper_notional) return index;
    }
    return error.RiskLimitExceeded;
}

fn marginFor(rules: Rules, amount: i64, maintenance: bool) !Margin {
    const index = try tierIndex(rules, amount);
    const tier = rules.tiers[index];
    if (!maintenance) {
        if (rules.leverage_milli == 0) return error.InvalidRules;
        const leverage_rate: u32 = @intCast(try ceilDivPositive(
            rate_scale * 1_000,
            rules.leverage_milli,
        ));
        const effective_rate = @max(leverage_rate, tier.imr_ppm);
        return .{
            .tier = index,
            .amount = try rateCeil(amount, effective_rate),
            .effective_rate_ppm = effective_rate,
        };
    }
    const gross = try rateCeil(amount, tier.mmr_ppm);
    return .{
        .tier = index,
        .amount = @max(gross - tier.deduction, 0),
        .effective_rate_ppm = tier.mmr_ppm,
    };
}

fn scenario(state: State, side: Side) !Scenario {
    const order_qty = switch (side) {
        .current => 0,
        .buy => state.open_buy_qty,
        .sell => state.open_sell_qty,
    };
    const reduce_only = switch (side) {
        .current => false,
        .buy => state.buy_portfolio_reduce_only,
        .sell => state.sell_portfolio_reduce_only,
    };
    if (order_qty < 0) return error.InvalidOpenQuantity;
    if (reduce_only and order_qty > 0) {
        const valid_direction = (side == .buy and state.qty < 0) or
            (side == .sell and state.qty > 0);
        if (!valid_direction or abs128(state.qty) < order_qty)
            return error.InvalidPortfolioReduceOnly;
    }
    const fill_qty = switch (side) {
        .current => 0,
        .buy => order_qty,
        .sell => -order_qty,
    };
    return .{
        .side = side,
        .order_qty = order_qty,
        .fill_qty = fill_qty,
        .final_qty = try std.math.add(i64, state.qty, fill_qty),
        .price = switch (side) {
            .current => state.mark_price,
            .buy => if (order_qty > 0 and state.buy_worst_price > 0)
                state.buy_worst_price
            else
                state.mark_price,
            .sell => if (order_qty > 0 and state.sell_worst_price > 0)
                state.sell_worst_price
            else
                state.mark_price,
        },
    };
}

fn project(rules: Rules, state: State, current_upl: i64, input: Scenario) !Projection {
    const fill_pnl = try floorDivSigned(
        @as(i128, input.fill_qty) * (state.mark_price - input.price) * rules.contract_num,
        rules.contract_den,
    );
    const execution_fee = try rateCeil(
        try notional(rules, input.order_qty, input.price),
        rules.fee_ppm,
    );
    const equity_before_fee = try std.math.add(
        i64,
        try std.math.add(i64, state.margin, current_upl),
        fill_pnl,
    );
    const equity = try std.math.sub(i64, equity_before_fee, execution_fee);
    const projected_notional = try notional(rules, input.final_qty, state.mark_price);
    const mm = try marginFor(rules, projected_notional, true);
    const close_fee = try rateCeil(projected_notional, rules.fee_ppm);
    return .{
        .side = input.side,
        .qty = input.final_qty,
        .maintenance_margin = mm.amount,
        .equity = equity,
        .buffer = try std.math.sub(
            i64,
            try std.math.sub(i64, equity, mm.amount),
            close_fee,
        ),
    };
}

pub fn assess(rules: Rules, state: State) !Assessment {
    if (state.open_buy_qty < 0 or state.open_sell_qty < 0) return error.InvalidOpenQuantity;
    const current_notional = try notional(rules, state.qty, state.mark_price);
    const current = try scenario(state, .current);
    const buy = try scenario(state, .buy);
    const sell = try scenario(state, .sell);
    const buy_notional = try notional(rules, buy.final_qty, buy.price);
    const sell_notional = try notional(rules, sell.final_qty, sell.price);
    const worst_notional = @max(current_notional, @max(buy_notional, sell_notional));
    const im = try marginFor(rules, worst_notional, false);
    const mm = try marginFor(rules, current_notional, true);

    const buy_fee = try rateCeil(
        try notional(rules, buy.order_qty, buy.price),
        rules.fee_ppm,
    );
    const sell_fee = try rateCeil(
        try notional(rules, sell.order_qty, sell.price),
        rules.fee_ppm,
    );
    const order_fee = try std.math.add(i64, buy_fee, sell_fee);
    const close_fee = try rateCeil(current_notional, rules.fee_ppm);
    const upl = try floorDivSigned(
        @as(i128, state.qty) * (state.mark_price - state.entry_price) * rules.contract_num,
        rules.contract_den,
    );
    const equity = try std.math.add(i64, state.margin, upl);
    const buffer_before_fee = try std.math.sub(i64, equity, mm.amount);
    const current_buffer = try std.math.sub(i64, buffer_before_fee, close_fee);

    var projection = try project(rules, state, upl, current);
    if (buy.order_qty > 0) {
        const candidate = try project(rules, state, upl, buy);
        if (candidate.buffer < projection.buffer) projection = candidate;
    }
    if (sell.order_qty > 0) {
        const candidate = try project(rules, state, upl, sell);
        if (candidate.buffer < projection.buffer) projection = candidate;
    }
    const reservation_required = try std.math.add(i64, im.amount, order_fee);

    return .{
        .current_tier = mm.tier,
        .worst_im_tier = im.tier,
        .effective_imr_ppm = im.effective_rate_ppm,
        .position_notional = current_notional,
        .worst_notional = worst_notional,
        .initial_margin = im.amount,
        .maintenance_margin = mm.amount,
        .order_fee_reserve = order_fee,
        .reservation_required = reservation_required,
        .reservation_surplus = try std.math.sub(i64, state.margin, reservation_required),
        .close_fee_buffer = close_fee,
        .upl = upl,
        .equity = equity,
        .margin_buffer = current_buffer,
        .projected_side = projection.side,
        .projected_qty = projection.qty,
        .projected_maintenance_margin = projection.maintenance_margin,
        .projected_equity = projection.equity,
        .projected_margin_buffer = projection.buffer,
    };
}

fn liquidationBuffer(rules: Rules, state: State, price: i64) !i64 {
    var current = state;
    current.mark_price = price;
    current.open_buy_qty = 0;
    current.open_sell_qty = 0;
    return (try assess(rules, current)).margin_buffer;
}

pub fn liquidation(rules: Rules, state: State) !?Liquidation {
    if (state.qty == 0) return null;
    if (rules.price_tick <= 0 or state.mark_price < rules.price_tick) return error.InvalidRules;
    if (try liquidationBuffer(rules, state, state.mark_price) <= 0)
        return .{ .price = state.mark_price, .distance_ticks = 0, .distance_bps = 0 };

    var liq_price: i64 = undefined;
    if (state.qty > 0) {
        var unsafe = rules.price_tick;
        if (try liquidationBuffer(rules, state, unsafe) > 0) return null;
        var safe = state.mark_price;
        while (safe - unsafe > rules.price_tick) {
            const midpoint = @divFloor(unsafe + safe, 2 * rules.price_tick) * rules.price_tick;
            if (try liquidationBuffer(rules, state, midpoint) <= 0)
                unsafe = midpoint
            else
                safe = midpoint;
        }
        liq_price = unsafe;
    } else {
        var safe = state.mark_price;
        var unsafe = try std.math.mul(i64, state.mark_price, 16);
        unsafe = @divFloor(unsafe, rules.price_tick) * rules.price_tick;
        if (try liquidationBuffer(rules, state, unsafe) > 0) return null;
        while (unsafe - safe > rules.price_tick) {
            const midpoint = @divFloor(unsafe + safe, 2 * rules.price_tick) * rules.price_tick;
            if (try liquidationBuffer(rules, state, midpoint) <= 0)
                unsafe = midpoint
            else
                safe = midpoint;
        }
        liq_price = unsafe;
    }

    const distance: i128 = if (liq_price >= state.mark_price)
        liq_price - state.mark_price
    else
        state.mark_price - liq_price;
    return .{
        .price = liq_price,
        .distance_ticks = @intCast(@divFloor(distance, rules.price_tick)),
        .distance_bps = @intCast(@divFloor(distance * 10_000 + state.mark_price - 1, state.mark_price)),
    };
}

fn reduces(before: i64, after: i64) bool {
    if (before == 0) return false;
    if (after != 0 and (before > 0) != (after > 0)) return false;
    return abs128(after) <= abs128(before);
}

pub fn reduceOnlyFlags(
    portfolio_before: i64,
    portfolio_after: i64,
    venue_before: i64,
    venue_after: i64,
) ReduceOnly {
    return .{
        .portfolio = reduces(portfolio_before, portfolio_after),
        .venue = reduces(venue_before, venue_after),
    };
}

fn allocateComponent(
    contributors: []const Contributor,
    position_side: i8,
    total_weight: i128,
    total_value: i64,
    out: []Allocation,
    comptime field: []const u8,
) !void {
    if (total_value == std.math.minInt(i64)) return error.Overflow;
    const value_abs = abs128(total_value);
    var allocated_abs: i64 = 0;
    for (contributors, 0..) |item, index| {
        const eligible = item.qty != 0 and (if (item.qty > 0) @as(i8, 1) else -1) == position_side;
        const numerator = if (eligible) abs128(item.qty) * value_abs else 0;
        const base_abs: i64 = if (total_weight == 0) 0 else @intCast(@divFloor(numerator, total_weight));
        @field(out[index], field) = if (total_value < 0) -base_abs else base_abs;
        out[index].remainder = if (total_weight == 0) 0 else @mod(numerator, total_weight);
        allocated_abs += base_abs;
    }

    var left: i128 = value_abs - allocated_abs;
    while (left > 0) : (left -= 1) {
        var best: ?usize = null;
        for (out[0..contributors.len], 0..) |item, index| {
            if (item.remainder == 0) continue;
            if (best == null or item.remainder > out[best.?].remainder or
                (item.remainder == out[best.?].remainder and item.id < out[best.?].id))
                best = index;
        }
        const index = best orelse return error.AllocationDidNotClose;
        @field(out[index], field) += if (total_value < 0) -1 else 1;
        out[index].remainder = -1;
    }
}

pub fn allocateForced(
    contributors: []const Contributor,
    position_side: i8,
    forced: ForcedEconomics,
    out: []Allocation,
) ![]Allocation {
    if ((position_side != 1 and position_side != -1) or forced.qty < 0 or out.len < contributors.len)
        return error.InvalidAllocationInput;
    var total_weight: i128 = 0;
    for (contributors) |item| {
        if (item.qty != 0 and (if (item.qty > 0) @as(i8, 1) else -1) == position_side)
            total_weight += abs128(item.qty);
    }
    if (forced.qty > total_weight) return error.ForcedQuantityExceedsPosition;
    if (total_weight == 0 and
        (forced.qty != 0 or forced.realized_pnl != 0 or forced.fee != 0 or forced.penalty != 0))
        return error.NoContributors;

    for (contributors, 0..) |item, index| {
        out[index] = .{
            .id = item.id,
            .qty = 0,
            .realized_pnl = 0,
            .fee = 0,
            .penalty = 0,
            .remainder = 0,
        };
    }
    try allocateComponent(contributors, position_side, total_weight, forced.qty, out, "qty");
    try allocateComponent(contributors, position_side, total_weight, forced.realized_pnl, out, "realized_pnl");
    try allocateComponent(contributors, position_side, total_weight, forced.fee, out, "fee");
    try allocateComponent(contributors, position_side, total_weight, forced.penalty, out, "penalty");
    for (out[0..contributors.len]) |*item| item.remainder = 0;
    return out[0..contributors.len];
}
