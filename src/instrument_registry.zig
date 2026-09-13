//! The bounded, authoritative instrument configuration registry.

const canonical = @import("canonical_event.zig");
const risk = @import("risk.zig");
const shard_event = @import("trading_shard_event.zig");
const std = @import("std");

pub const max_entries = 4;

pub const Entry = struct {
    instrument: canonical.InstrumentIdentity,
    venue: canonical.VenueIdentity,
    product: risk.Product,
    rules: shard_event.InstrumentRules,
    margin: shard_event.MarginRules,
    margin_configured: bool = false,
    rules_barrier: u64 = 0,
    capability: ?shard_event.CapabilityProfileActivation = null,
    capability_barrier: u64 = 0,
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

    /// Adds an entry or confirms an exact duplicate. A changed identity is
    /// never silently replaced, which keeps replay and snapshot state stable.
    pub fn register(self: *Registry, entry: Entry) !bool {
        if (entry.instrument == 0 or entry.rules.version == 0 or
            entry.rules.instrument_identity != entry.instrument or
            entry.rules.quantity_denominator <= 0 or
            entry.rules.product != entry.product)
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
            known.* = entry;
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
        if (!validMargin(margin)) return error.InvalidMarginRules;
        if (entry.margin_configured) {
            if (!std.meta.eql(entry.margin, margin)) return error.InstrumentRulesConflict;
            return false;
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
                entry.rules.quantity_denominator <= 0 or
                entry.rules.product != entry.product or
                (entry.capability != null and (entry.capability.?.instrument != entry.instrument or
                    entry.capability.?.venue != entry.venue or entry.capability.?.product != entry.rules.product or
                    entry.capability.?.rules_version != entry.rules.version or entry.capability_barrier == 0)) or
                (entry.capability == null and entry.capability_barrier != 0) or
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
    return margin.version != 0 and margin.price_tick_micros > 0 and
        margin.venue_initial_margin_ppm > 0 and
        margin.internal_initial_margin_ppm >= margin.venue_initial_margin_ppm and
        margin.internal_maintenance_margin_ppm > 0 and
        margin.internal_maintenance_margin_ppm <= margin.internal_initial_margin_ppm and
        margin.fee_ppm >= 0 and margin.opening_buffer_micros >= margin.warning_buffer_micros and
        margin.warning_buffer_micros >= margin.kill_buffer_micros and margin.kill_buffer_micros >= 0 and
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
    for ([_]u128{ 11, 12, 13 }) |identity| {
        var next = entry;
        next.instrument = identity;
        next.rules.instrument_identity = identity;
        try std.testing.expect(try registry.register(next));
    }
    var overflow = entry;
    overflow.instrument = 14;
    overflow.rules.instrument_identity = 14;
    try std.testing.expectError(error.InstrumentRegistryFull, registry.register(overflow));
    try std.testing.expectEqual(@as(u8, max_entries), registry.count);
}
