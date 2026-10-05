//! Fixed units for one ledger history. TradingShard owns activation barriers.
const std = @import("std");
const canonical = @import("canonical_event.zig");
pub const max_entries = 8;
pub const Entry = struct { definition: canonical.AssetDefinition, barrier: u64 };
pub const Registry = struct {
    entries: [max_entries]Entry = @splat(std.mem.zeroes(Entry)),
    count: u8 = 0,
    pub fn get(self: *const Registry, asset: canonical.AssetIdentity) ?Entry {
        for (self.entries[0..self.count]) |entry| if (entry.definition.asset == asset) return entry;
        return null;
    }
    pub fn activate(self: *Registry, definition: canonical.AssetDefinition, barrier: u64) !bool {
        try validateDefinition(definition);
        if (barrier == 0) return error.AssetDefinitionInactive;
        for (self.entries[0..self.count]) |*entry| {
            const known = entry.definition;
            if (known.asset != definition.asset) continue;
            if (definition.version < known.version) return error.AssetDefinitionRegression;
            if (definition.atomic_scale != known.atomic_scale) return error.AssetPrecisionChange;
            if (definition.version == known.version) {
                if (!std.meta.eql(known, definition)) return error.AssetDefinitionConflict;
                return false;
            }
            entry.* = .{ .definition = definition, .barrier = barrier };
            return true;
        }
        if (self.count == max_entries) return error.AssetRegistryFull;
        self.entries[self.count] = .{ .definition = definition, .barrier = barrier };
        self.count += 1;
        return true;
    }
    pub fn validate(self: *const Registry) !void {
        if (self.count > max_entries) return error.InvalidAssetDefinition;
        for (self.entries[0..self.count], 0..) |entry, index| {
            try validateDefinition(entry.definition);
            if (entry.barrier == 0) return error.AssetDefinitionInactive;
            for (self.entries[0..index]) |prior| if (prior.definition.asset == entry.definition.asset) return error.AssetDefinitionConflict;
        }
    }
    /// Temporary admission ceiling for existing micros/i64 economic consumers.
    /// New atom scales are representable ingress, but cannot authorize those consumers.
    pub fn legacyConsumerCompatible(self: *const Registry) bool {
        const quote = self.get(1) orelse return false;
        const base = self.get(0x425443) orelse return false;
        if (!legacyDefinitionCompatible(quote.definition) or !legacyDefinitionCompatible(base.definition)) return false;
        for (self.entries[0..self.count]) |entry| if (!legacyDefinitionCompatible(entry.definition)) return false;
        return true;
    }
    /// Native quote/base consumers share fixed units; third assets remain gated.
    pub fn consumerCompatible(self: *const Registry, native_settlement_atoms: bool) bool {
        if (!native_settlement_atoms) return self.legacyConsumerCompatible();
        _ = self.get(1) orelse return false;
        _ = self.get(0x425443) orelse return false;
        for (self.entries[0..self.count]) |entry| {
            if (entry.definition.asset != 1 and entry.definition.asset != 0x425443) return false;
        }
        return true;
    }
    pub fn checkAmount(self: *const Registry, amount_value: canonical.AssetAmount, single: bool) !void {
        const entry = self.get(amount_value.asset) orelse return error.UnknownAssetDefinition;
        const limit = if (single) entry.definition.max_single_atoms else entry.definition.max_balance_atoms;
        if (amount_value.atoms > limit or amount_value.atoms < -limit) return error.AssetAmountOutOfRange;
    }
    pub fn amount(self: *const Registry, asset: canonical.AssetIdentity, decimal: canonical.Decimal) !canonical.AssetAmount {
        const entry = self.get(asset) orelse return error.UnknownAssetDefinition;
        if (entry.barrier == 0 or entry.definition.version == 0) return error.AssetDefinitionInactive;
        const atoms = try decimal.exactAtoms(entry.definition.atomic_scale);
        const limit = entry.definition.max_balance_atoms;
        if (atoms > limit or atoms < -limit) return error.AssetAmountOutOfRange;
        return .{ .asset = asset, .atoms = atoms };
    }
};
pub fn legacyDefinitionCompatible(value: canonical.AssetDefinition) bool {
    const scale: u8 = switch (value.asset) {
        1 => 6,
        0x425443 => 8,
        else => return false,
    };
    return value.atomic_scale == scale and value.source_kind == .test_fixture and value.max_cumulative_atoms <= std.math.maxInt(i64);
}
pub fn validateDefinition(value: canonical.AssetDefinition) !void {
    if (value.asset == 0 or value.version == 0 or value.source_identity == 0 or std.mem.allEqual(u8, &value.source_digest, 0) or
        value.atomic_scale > canonical.Decimal.max_scale or value.max_rescale_power < value.atomic_scale or value.max_rescale_power > canonical.Decimal.max_scale or
        value.max_single_atoms <= 0 or value.max_balance_atoms < value.max_single_atoms or value.max_cumulative_atoms < value.max_balance_atoms or
        value.max_quantity_lots <= 0 or value.max_price_ticks <= 0 or value.max_postings < 2 or value.max_postings > @import("economics.zig").max_postings) return error.InvalidAssetDefinition;
    _ = std.math.mul(i128, value.max_cumulative_atoms, value.max_postings) catch return error.AssetRangeOverflow;
    _ = std.math.mul(i128, value.max_quantity_lots, value.max_price_ticks) catch return error.AssetRangeOverflow;
    _ = (canonical.Decimal{ .coefficient = value.max_cumulative_atoms, .scale = 0 }).exactAtoms(value.max_rescale_power) catch return error.AssetRangeOverflow;
}

/// Explicit offline evidence. Policy forbids these definitions on live transport.
pub fn testDefinitions(usdt_scale: u8, btc_scale: u8) [2]canonical.AssetDefinition {
    var definitions: [2]canonical.AssetDefinition = undefined;
    for (&definitions, [_]canonical.AssetIdentity{ 1, 0x425443 }, [_]u8{ usdt_scale, btc_scale }) |*definition, asset, scale| {
        definition.* = .{ .asset = asset, .atomic_scale = scale, .version = 1, .source_identity = 0x74657374 + asset, .source_digest = @splat(0x74), .source_kind = .test_fixture, .max_single_atoms = 1_000_000_000_000_000, .max_balance_atoms = 1_000_000_000_000_000, .max_cumulative_atoms = 1_000_000_000_000_000_000, .max_quantity_lots = 1_000_000_000, .max_price_ticks = 100_000_000_000, .max_rescale_power = scale, .max_postings = 4 };
    }
    return definitions;
}
