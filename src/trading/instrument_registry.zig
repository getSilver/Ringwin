//! The bounded, authoritative instrument configuration registry.

const canonical = @import("../model/canonical_event.zig");
const risk = @import("../risk/risk.zig");
const shard_event = @import("trading_shard_event.zig");
const std = @import("std");

pub const max_entries = canonical.max_instrument_definitions;

pub const Entry = struct {
    instrument: canonical.InstrumentIdentity,
    venue: canonical.VenueIdentity,
    product: risk.Product,
    rules: shard_event.InstrumentRules,
    margin: shard_event.MarginRules,
    margin_configured: bool = false,
    margin_barrier: u64 = 0,
    rules_barrier: u64 = 0,
    capability: ?shard_event.CapabilityProfileActivation = null,
    capability_barrier: u64 = 0,
    trading_enabled: bool = false,
    trading_version: u64 = 0,
    trading_barrier: u64 = 0,
};

pub const Registry = struct {
    entries: [max_entries]Entry = undefined,
    count: u8 = 0,

    pub fn get(self: *const Registry, instrument: canonical.InstrumentIdentity) ?Entry {
        for (self.entries[0..self.count]) |entry|
            if (entry.instrument == instrument) return entry;
        return null;
    }

    pub fn getPtr(self: *Registry, instrument: canonical.InstrumentIdentity) ?*Entry {
        for (self.entries[0..self.count]) |*entry|
            if (entry.instrument == instrument) return entry;
        return null;
    }

    pub fn permitsEconomicUnits(self: *const Registry, assets: *const @import("asset_registry.zig").Registry, instrument: canonical.InstrumentIdentity) bool {
        // Existing isolated decoder fixtures have no order configuration.
        if (self.count == 0) return assets.legacyConsumerCompatible();
        const entry = self.get(instrument) orelse return false;
        if (!assets.hasVenueCode(entry.rules.settlement_asset, entry.venue) or
            (entry.product == .spot and !assets.hasVenueCode(entry.rules.base_asset, entry.venue))) return false;
        return entry.margin_configured and assets.consumerCompatible(entry.margin.native_settlement_atoms);
    }

    /// Venue parsing units must equal the committed Core lot and tick authority.
    pub fn validateVenueUnits(self: *const Registry, assets: *const @import("asset_registry.zig").Registry, instrument: canonical.InstrumentIdentity, version: u64, lot: canonical.Decimal, tick: canonical.Decimal) !void {
        const entry = self.get(instrument) orelse return error.UnknownInstrument;
        if (entry.rules.version != version or !entry.margin_configured or lot.coefficient <= 0 or tick.coefficient <= 0)
            return error.InvalidInstrumentConfiguration;
        const lot_power = try (canonical.Decimal{ .coefficient = 1, .scale = 0 }).exactAtoms(lot.scale);
        if (try std.math.mul(i128, lot.coefficient, entry.rules.quantity_denominator) !=
            try std.math.mul(i128, entry.rules.quantity_numerator, lot_power)) return error.InvalidInstrumentConfiguration;
        const quote = assets.get(entry.rules.settlement_asset) orelse return error.UnknownAssetDefinition;
        if (!assets.hasVenueCode(entry.rules.settlement_asset, entry.venue) or
            (entry.product == .spot and !assets.hasVenueCode(entry.rules.base_asset, entry.venue))) return error.InvalidInstrumentConfiguration;
        if (try tick.exactAtoms(quote.definition.atomic_scale) != entry.margin.price_tick_atoms)
            return error.InvalidInstrumentConfiguration;
    }

    /// Adds an entry or confirms an exact duplicate. A changed identity is
    /// never silently replaced, which keeps replay and snapshot state stable.
    pub fn register(self: *Registry, entry: Entry) !bool {
        if (entry.instrument == 0 or entry.rules.version == 0 or
            entry.rules.instrument_identity != entry.instrument or
            entry.rules.quantity_denominator <= 0 or entry.rules.quantity_numerator <= 0 or
            entry.rules.product != entry.product or
            (entry.product == .spot and entry.rules.base_asset != 0 and entry.rules.base_asset == entry.rules.settlement_asset))
            return error.InvalidInstrumentConfiguration;
        if (self.getPtr(entry.instrument)) |known| {
            // Margin is activated by a separate canonical fact. Registration
            // therefore compares only the immutable identity/rules portion;
            // re-registering after margin activation remains an exact no-op.
            if (known.venue != entry.venue or known.product != entry.product)
                return error.InstrumentIdentityConflict;
            if (std.meta.eql(known.rules, entry.rules)) return false;
            if (entry.rules.version < known.rules.version) return error.InstrumentRulesRegression;
            if (entry.rules.version == known.rules.version) return error.InstrumentRulesConflict;
            known.rules = entry.rules;
            known.rules_barrier = entry.rules_barrier;
            known.capability = null;
            known.capability_barrier = 0;
            return true;
        }
        if (self.count == self.entries.len) return error.InstrumentRegistryFull;
        self.entries[self.count] = entry;
        self.count += 1;
        return true;
    }

    pub fn configureMargin(
        self: *Registry,
        instrument: canonical.InstrumentIdentity,
        margin: shard_event.MarginRules,
    ) !bool {
        const entry = self.getPtr(instrument) orelse return error.UnknownInstrument;
        if (!validMargin(margin) or (margin.instrument != 0 and margin.instrument != instrument)) return error.InvalidMarginRules;
        if (entry.margin_configured) {
            if (std.meta.eql(entry.margin, margin)) return false;
            if (margin.version < entry.margin.version) return error.InstrumentRulesRegression;
            if (margin.version == entry.margin.version) return error.InstrumentRulesConflict;
        }
        entry.margin = margin;
        entry.margin_configured = true;
        return true;
    }

    pub fn validate(self: *const Registry) !void {
        if (self.count > self.entries.len) return error.InvalidInstrumentRegistry;
        for (self.entries[0..self.count], 0..) |entry, index| {
            if (entry.instrument == 0 or entry.rules.version == 0 or
                entry.rules.instrument_identity != entry.instrument or
                entry.rules.quantity_denominator <= 0 or entry.rules.quantity_numerator <= 0 or
                entry.rules.product != entry.product or
                (entry.product == .spot and entry.rules.base_asset != 0 and entry.rules.base_asset == entry.rules.settlement_asset) or
                (entry.capability != null and (entry.capability.?.instrument != entry.instrument or
                    entry.capability.?.venue != entry.venue or entry.capability.?.product != entry.rules.product or
                    entry.capability.?.rules_version != entry.rules.version or entry.capability_barrier == 0)) or
                (entry.capability == null and entry.capability_barrier != 0) or
                (entry.trading_version == 0 and (entry.trading_enabled or entry.trading_barrier != 0)) or
                (entry.trading_version != 0 and entry.trading_barrier == 0) or
                (!entry.margin_configured and entry.margin_barrier != 0) or
                (entry.margin_configured and
                    (entry.margin.instrument != 0 and entry.margin.instrument != entry.instrument or
                        !validMargin(entry.margin))))
                return error.InvalidInstrumentRegistry;
            for (self.entries[0..index]) |previous|
                if (previous.instrument == entry.instrument)
                    return error.InvalidInstrumentRegistry;
        }
    }
};

pub fn validMargin(margin: shard_event.MarginRules) bool {
    return margin.version != 0 and margin.price_tick_atoms > 0 and
        margin.venue_initial_margin_ppm > 0 and
        margin.internal_initial_margin_ppm >= margin.venue_initial_margin_ppm and
        margin.internal_maintenance_margin_ppm > 0 and
        margin.internal_maintenance_margin_ppm <= margin.internal_initial_margin_ppm and
        margin.fee_ppm >= 0 and margin.opening_buffer_atoms >= margin.warning_buffer_atoms and
        margin.warning_buffer_atoms >= margin.kill_buffer_atoms and margin.kill_buffer_atoms >= 0 and
        (margin.opening_buffer_bps == 0 or margin.opening_buffer_bps >= margin.warning_buffer_bps) and
        margin.warning_buffer_bps >= margin.kill_buffer_bps and margin.kill_buffer_bps >= 0 and
        (margin.opening_liquidation_distance_ticks == 0 or
            margin.opening_liquidation_distance_ticks >= margin.warning_liquidation_distance_ticks) and
        margin.warning_liquidation_distance_ticks >= margin.kill_liquidation_distance_ticks and
        margin.kill_liquidation_distance_ticks >= 0;
}

test "instrument registry is bounded, explicit, and idempotent" {
    var registry = Registry{};
    const rules: shard_event.InstrumentRules = .{
        .version = 1,
        .instrument_identity = 10,
        .quantity_denominator = 1,
        .reservation_model = .cash,
        .product = .spot,
    };
    const entry: Entry = .{ .instrument = 10, .venue = 2, .product = .spot, .rules = rules, .margin = .{ .version = 1 } };
    var invalid_base = entry;
    invalid_base.rules.base_asset = invalid_base.rules.settlement_asset;
    try std.testing.expectError(error.InvalidInstrumentConfiguration, registry.register(invalid_base));
    try std.testing.expect(try registry.register(entry));
    try std.testing.expect(!(try registry.register(entry)));
    var conflict = entry;
    conflict.venue = 3;
    try std.testing.expectError(error.InstrumentIdentityConflict, registry.register(conflict));
    try std.testing.expectEqualDeep(entry, registry.get(10).?);
    var upgraded = entry;
    upgraded.rules.version = 2;
    try std.testing.expect(try registry.register(upgraded));
    try std.testing.expectEqual(@as(u32, 2), registry.get(10).?.rules.version);
    try std.testing.expectError(error.InstrumentRulesRegression, registry.register(entry));
    try std.testing.expectEqualDeep(upgraded, registry.get(10).?);
    for (11..11 + max_entries - 1) |identity| {
        var next = entry;
        next.instrument = identity;
        next.rules.instrument_identity = identity;
        try std.testing.expect(try registry.register(next));
    }
    var overflow = entry;
    overflow.instrument = 11 + max_entries;
    overflow.rules.instrument_identity = overflow.instrument;
    try std.testing.expectError(error.InstrumentRegistryFull, registry.register(overflow));
    try std.testing.expectEqual(@as(u8, max_entries), registry.count);
}

test "rules upgrades retain independent margin and disabled trading authority" {
    var registry = Registry{};
    const entry: Entry = .{
        .instrument = 10,
        .venue = 2,
        .product = .spot,
        .rules = .{ .version = 1, .instrument_identity = 10, .quantity_denominator = 1, .reservation_model = .cash, .product = .spot },
        .margin = .{ .version = 1 },
    };
    _ = try registry.register(entry);
    _ = try registry.configureMargin(10, .{ .version = 1, .instrument = 10, .price_tick_atoms = 1, .venue_initial_margin_ppm = 1, .internal_initial_margin_ppm = 2, .internal_maintenance_margin_ppm = 1 });
    registry.getPtr(10).?.margin_barrier = 2;
    registry.getPtr(10).?.trading_version = 2;
    registry.getPtr(10).?.trading_barrier = 3;
    var upgraded = entry;
    upgraded.rules.version = 2;
    _ = try registry.register(upgraded);
    const retained = registry.get(10).?;
    try std.testing.expect(retained.margin_configured);
    try std.testing.expectEqual(@as(u64, 2), retained.margin_barrier);
    try std.testing.expect(!retained.trading_enabled);
    try std.testing.expectEqual(@as(u64, 2), retained.trading_version);
    try std.testing.expectEqual(@as(u64, 3), retained.trading_barrier);
    var margin = retained.margin;
    margin.version = 2;
    margin.price_tick_atoms = 2;
    try std.testing.expect(try registry.configureMargin(10, margin));
    try std.testing.expectError(error.InstrumentRulesRegression, registry.configureMargin(10, retained.margin));
    margin.instrument = 11;
    try std.testing.expectError(error.InvalidMarginRules, registry.configureMargin(10, margin));
    try registry.validate();
}
