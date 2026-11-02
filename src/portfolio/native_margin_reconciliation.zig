const std = @import("std");

pub const Model = enum(u8) { isolated_linear_v1 = 1, unsupported = 255, _ };

/// Explicit native model: mark-based margin and fees; exact linear liquidation
/// equation followed by adverse-direction price rounding. Activation is required.
pub const Rules = struct {
    model: Model,
    tier_identity: u64,
    notional_lower_atoms: i128,
    notional_upper_atoms: i128,
    initial_margin_ppm: i64,
    maintenance_ppm: i64,
    maintenance_deduction_atoms: i128,
    close_fee_ppm: i64,
    margin_rounding_atoms: i128,
    price_rounding_ticks: i128,

    pub fn validate(self: Rules) !void {
        if (self.model != .isolated_linear_v1) return error.UnsupportedNativeMarginModel;
        if (self.tier_identity == 0 or self.notional_lower_atoms < 0 or
            self.notional_upper_atoms <= self.notional_lower_atoms or
            self.initial_margin_ppm < 0 or self.initial_margin_ppm >= ppm_scale or
            self.maintenance_ppm < 0 or self.maintenance_ppm > self.initial_margin_ppm or
            self.close_fee_ppm < 0 or self.close_fee_ppm >= ppm_scale or
            self.maintenance_ppm + self.close_fee_ppm >= ppm_scale or
            self.maintenance_deduction_atoms < 0 or self.margin_rounding_atoms <= 0 or
            self.price_rounding_ticks <= 0) return error.InvalidNativeMarginRules;
    }
};

pub const Assessment = struct {
    initial_margin_atoms: i128,
    maintenance_atoms: i128,
    close_fee_atoms: i128,
    buffer_atoms: i128,
    liquidation_price_ticks: ?i128,
};

const ppm_scale = 1_000_000;

/// The caller supplies units from the same activated InstrumentRules version.
/// Null means the declared model/tier cannot explain this position; it grants no authority.
pub fn calculate(
    rules: Rules,
    quantity_lots: i64,
    quantity_numerator: i64,
    quantity_denominator: i64,
    price_tick_atoms: i128,
    average_price_ticks: i128,
    mark_price_ticks: i128,
    collateral_atoms: i128,
) !?Assessment {
    if (rules.model != .isolated_linear_v1) return null;
    try rules.validate();
    if (quantity_numerator <= 0 or quantity_denominator <= 0 or
        price_tick_atoms <= 0 or collateral_atoms < 0) return error.InvalidNativeMarginInput;
    if (quantity_lots == 0) return .{
        .initial_margin_atoms = 0,
        .maintenance_atoms = 0,
        .close_fee_atoms = 0,
        .buffer_atoms = collateral_atoms,
        .liquidation_price_ticks = null,
    };
    if (average_price_ticks <= 0 or mark_price_ticks <= 0) return error.InvalidNativeMarginInput;

    const signed_quantity: i256 = quantity_lots;
    const quantity = if (signed_quantity < 0) -signed_quantity else signed_quantity;
    const price_factor = try mul(try mul(quantity, quantity_numerator), price_tick_atoms);
    const denominator: i256 = quantity_denominator;
    const notional = try mul(price_factor, mark_price_ticks);
    if (!try inTier(rules, notional, denominator)) return null;

    const initial = try roundedCost(notional, denominator, rules.initial_margin_ppm, rules.margin_rounding_atoms);
    const maintenance_before_deduction = try roundedCost(notional, denominator, rules.maintenance_ppm, rules.margin_rounding_atoms);
    const maintenance = @max(maintenance_before_deduction - rules.maintenance_deduction_atoms, 0);
    const fee = try roundedCost(notional, denominator, rules.close_fee_ppm, rules.margin_rounding_atoms);
    const price_delta = try std.math.sub(i256, mark_price_ticks, average_price_ticks);
    const pnl_numerator = try mul(price_factor, if (quantity_lots > 0) price_delta else -price_delta);
    const pnl = @divFloor(pnl_numerator, denominator);
    const equity = try std.math.add(i256, collateral_atoms, pnl);
    const buffer = try std.math.sub(i256, try std.math.sub(i256, equity, maintenance), fee);

    // At the exact native threshold, collateral + signed PnL equals the
    // unrounded maintenance and fee requirement, including the tier deduction.
    const entry = try mul(try mul(price_factor, average_price_ticks), ppm_scale);
    const collateral_and_deduction = try std.math.add(i256, collateral_atoms, rules.maintenance_deduction_atoms);
    const adjustment = try mul(try mul(collateral_and_deduction, denominator), ppm_scale);
    const numerator = if (quantity_lots > 0)
        try std.math.sub(i256, entry, adjustment)
    else
        try std.math.add(i256, entry, adjustment);
    if (numerator <= 0) return null;
    const rate = rules.maintenance_ppm + rules.close_fee_ppm;
    const threshold_denominator = try mul(price_factor, if (quantity_lots > 0) ppm_scale - rate else ppm_scale + rate);
    const price_unit_denominator = try mul(threshold_denominator, rules.price_rounding_ticks);
    const units = if (quantity_lots > 0)
        @divFloor(numerator, price_unit_denominator)
    else
        ceilPositive(numerator, price_unit_denominator);
    const threshold = try mul(units, rules.price_rounding_ticks);
    if (threshold <= 0 or !try inTier(rules, try mul(price_factor, threshold), denominator)) return null;
    const threshold_maintenance = try mul(try mul(price_factor, threshold), rules.maintenance_ppm);
    const deduction = try mul(try mul(rules.maintenance_deduction_atoms, denominator), ppm_scale);
    if (threshold_maintenance < deduction) return null;
    return .{
        .initial_margin_atoms = initial,
        .maintenance_atoms = maintenance,
        .close_fee_atoms = fee,
        .buffer_atoms = std.math.cast(i128, buffer) orelse return error.Overflow,
        .liquidation_price_ticks = std.math.cast(i128, threshold) orelse return error.Overflow,
    };
}

fn mul(a: i256, b: i256) !i256 {
    return std.math.mul(i256, a, b);
}

fn ceilPositive(numerator: i256, denominator: i256) i256 {
    return @divTrunc(numerator, denominator) + @as(i256, @intFromBool(@rem(numerator, denominator) != 0));
}

fn roundedCost(notional: i256, denominator: i256, rate: i64, unit: i128) !i128 {
    const numerator = try mul(notional, rate);
    const divisor = try mul(try mul(denominator, ppm_scale), unit);
    return std.math.cast(i128, try mul(ceilPositive(numerator, divisor), unit)) orelse error.Overflow;
}

fn inTier(rules: Rules, notional: i256, denominator: i256) !bool {
    return notional >= try mul(rules.notional_lower_atoms, denominator) and
        notional <= try mul(rules.notional_upper_atoms, denominator);
}
