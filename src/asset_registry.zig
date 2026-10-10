//! Fixed units for one ledger history. TradingShard owns activation barriers.
const std = @import("std");
const canonical = @import("canonical_event.zig");
pub const max_entries = canonical.max_asset_definitions;
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
        for (self.entries[0..self.count]) |entry| {
            if (entry.definition.asset == definition.asset) continue;
            try checkCodeConflicts(entry.definition, definition);
        }
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
            for (self.entries[0..index]) |prior| {
                if (prior.definition.asset == entry.definition.asset) return error.AssetDefinitionConflict;
                try checkCodeConflicts(prior.definition, entry.definition);
            }
        }
    }
    pub fn resolveCode(self: *const Registry, venue: canonical.VenueIdentity, code: []const u8) !canonical.AssetIdentity {
        if (code.len == 0) return error.UnsupportedAsset;
        for (self.entries[0..self.count]) |entry| {
            if (entry.barrier == 0 or entry.definition.version == 0) return error.AssetDefinitionInactive;
            for (entry.definition.code_bindings[0..entry.definition.code_binding_count]) |binding| {
                if (binding.venue == venue and std.mem.eql(u8, binding.slice(), code)) return entry.definition.asset;
            }
        }
        return error.UnsupportedAsset;
    }
    pub fn hasVenueCode(self: *const Registry, asset: canonical.AssetIdentity, venue: canonical.VenueIdentity) bool {
        const entry = self.get(asset) orelse return false;
        for (entry.definition.code_bindings[0..entry.definition.code_binding_count]) |binding|
            if (binding.venue == venue) return true;
        return false;
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
    /// Every activated native asset uses the same bounded economic consumer.
    pub fn consumerCompatible(self: *const Registry, native_settlement_atoms: bool) bool {
        if (!native_settlement_atoms) return self.legacyConsumerCompatible();
        _ = self.get(1) orelse return false;
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
    if (value.code_binding_count > canonical.max_asset_code_bindings) return error.InvalidAssetDefinition;
    for (value.code_bindings, 0..) |binding, index| {
        if (index >= value.code_binding_count) {
            if (!std.meta.eql(binding, canonical.AssetCodeBinding{})) return error.InvalidAssetDefinition;
            continue;
        }
        if (binding.code_len == 0 or binding.code_len > binding.code.len) return error.InvalidAssetDefinition;
        const normalized = canonical.AssetCodeBinding.init(binding.venue, binding.slice()) catch return error.InvalidAssetDefinition;
        if (!std.meta.eql(binding, normalized)) return error.InvalidAssetDefinition;
        for (value.code_bindings[0..index]) |prior|
            if (prior.venue == binding.venue and std.mem.eql(u8, prior.slice(), binding.slice())) return error.AssetCodeConflict;
    }
}

fn checkCodeConflicts(a: canonical.AssetDefinition, b: canonical.AssetDefinition) !void {
    for (a.code_bindings[0..a.code_binding_count]) |left| {
        for (b.code_bindings[0..b.code_binding_count]) |right|
            if (left.venue == right.venue and std.mem.eql(u8, left.slice(), right.slice())) return error.AssetCodeConflict;
    }
}

/// Explicit offline evidence. Policy forbids these definitions on live transport.
pub fn testDefinitions(usdt_scale: u8, btc_scale: u8) [2]canonical.AssetDefinition {
    var definitions: [2]canonical.AssetDefinition = undefined;
    for (&definitions, [_]canonical.AssetIdentity{ 1, 0x425443 }, [_]u8{ usdt_scale, btc_scale }) |*definition, asset, scale| {
        definition.* = .{ .asset = asset, .atomic_scale = scale, .version = 1, .source_identity = 0x74657374 + asset, .source_digest = @splat(0x74), .source_kind = .test_fixture, .max_single_atoms = 1_000_000_000_000_000, .max_balance_atoms = 1_000_000_000_000_000, .max_cumulative_atoms = 1_000_000_000_000_000_000, .max_quantity_lots = 1_000_000_000, .max_price_ticks = 100_000_000_000, .max_rescale_power = scale, .max_postings = 4 };
        definition.code_binding_count = 3;
        for ([_]canonical.VenueIdentity{ 1, 21, 42 }, 0..) |venue, index|
            definition.code_bindings[index] = canonical.AssetCodeBinding.init(venue, if (asset == 1) "USDT" else "BTC") catch unreachable;
    }
    return definitions;
}

test "activated source asset codes resolve by venue and reject ambiguous authority" {
    var registry: Registry = .{};
    var quote = testDefinitions(6, 8)[0];
    quote.code_bindings = @splat(.{});
    quote.code_binding_count = 1;
    quote.code_bindings[0] = try canonical.AssetCodeBinding.init(1, "USDT");
    _ = try registry.activate(quote, 1);
    try std.testing.expectEqual(@as(canonical.AssetIdentity, 1), try registry.resolveCode(1, "USDT"));
    try std.testing.expectError(error.UnsupportedAsset, registry.resolveCode(21, "USDT"));
    var third = quote;
    third.asset = 99;
    try std.testing.expectError(error.AssetCodeConflict, registry.activate(third, 2));
    try std.testing.expectEqual(@as(u8, 1), registry.count);
}
