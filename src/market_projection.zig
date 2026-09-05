//! Bounded per-Instrument public-market projections.

const canonical = @import("canonical_event.zig");
const std = @import("std");

pub const max_instruments = 4;

const MarketFailure = enum(u8) { missing_snapshot, sequence_gap, conflicting_delta, stale_snapshot, incomplete_snapshot, scope_mismatch };

pub const InstrumentProjection = struct {
    instrument: canonical.InstrumentIdentity,
    definition: canonical.InstrumentDefinitionObserved,
    active_rules_version: ?u64 = null,
    last_book: ?canonical.L2BookSnapshot = null,
    health: canonical.MarketDataHealth = .awaiting_snapshot,
    failure: ?MarketFailure = null,
    mark: ?canonical.InstrumentPrice = null,
    index: ?canonical.InstrumentPrice = null,

    fn applySnapshot(self: *InstrumentProjection, snapshot: canonical.L2BookSnapshot) !void {
        if (!snapshot.complete) return self.gap(.incomplete_snapshot, error.IncompleteBookSnapshot);
        if (snapshot.instrument != self.instrument or snapshot.best_bid.instrument != self.instrument or
            snapshot.best_ask.instrument != self.instrument)
            return self.gap(.scope_mismatch, error.MarketInstrumentMismatch);
        if (self.active_rules_version == null or self.active_rules_version.? != snapshot.best_bid.rules_version or
            snapshot.best_bid.rules_version != snapshot.best_ask.rules_version)
            return error.InstrumentRulesInactive;
        if (self.last_book) |previous| if (self.health != .gap and snapshot.sequence <= previous.sequence) {
            return self.gap(.stale_snapshot, error.StaleBookSnapshot);
        };
        self.last_book = snapshot;
        self.health = .healthy;
        self.failure = null;
    }

    fn applyDelta(self: *InstrumentProjection, delta: canonical.L2BookDelta) !void {
        const previous = self.last_book orelse return self.gap(.missing_snapshot, error.MissingBookSnapshot);
        if (delta.instrument != self.instrument or delta.best_bid.instrument != self.instrument or
            delta.best_ask.instrument != self.instrument)
            return self.gap(.scope_mismatch, error.MarketInstrumentMismatch);
        if (self.health != .healthy) return error.MarketGap;
        if (delta.sequence == previous.sequence) {
            if (delta.previous_sequence == previous.sequence - 1 and std.meta.eql(delta.best_bid, previous.best_bid) and std.meta.eql(delta.best_ask, previous.best_ask)) return;
            return self.gap(.conflicting_delta, error.ConflictingBookDelta);
        }
        if (delta.previous_sequence != previous.sequence or delta.sequence != previous.sequence + 1)
            return self.gap(.sequence_gap, error.BookSequenceGap);
        self.last_book = .{
            .instrument = delta.instrument,
            .sequence = delta.sequence,
            .best_bid = delta.best_bid,
            .best_ask = delta.best_ask,
            .best_bid_quantity = delta.best_bid_quantity,
            .best_ask_quantity = delta.best_ask_quantity,
            .next_ask = delta.next_ask,
            .next_ask_quantity = delta.next_ask_quantity,
        };
    }

    fn gap(self: *InstrumentProjection, failure: MarketFailure, err: anyerror) anyerror!void {
        self.health = .gap;
        self.failure = failure;
        return err;
    }
};

pub const Projection = struct {
    pub const Failure = MarketFailure;

    entries: [max_instruments]InstrumentProjection = undefined,
    count: u8 = 0,
    failure_generation: u64 = 0,

    pub fn get(self: *const Projection, instrument: canonical.InstrumentIdentity) ?InstrumentProjection {
        for (self.entries[0..self.count]) |entry| if (entry.instrument == instrument) return entry;
        return null;
    }

    fn getPtr(self: *Projection, instrument: canonical.InstrumentIdentity) ?*InstrumentProjection {
        for (self.entries[0..self.count]) |*entry| if (entry.instrument == instrument) return entry;
        return null;
    }

    pub fn activateRules(self: *Projection, instrument: canonical.InstrumentIdentity, rules_version: u64) !void {
        const entry = self.getPtr(instrument) orelse return error.MissingInstrumentDefinition;
        if (entry.definition.rules_version != rules_version) return error.InvalidConfigurationBarrier;
        if (entry.active_rules_version != null and entry.active_rules_version.? != rules_version) {
            entry.last_book = null;
            entry.health = .awaiting_snapshot;
            entry.failure = null;
            entry.mark = null;
            entry.index = null;
        }
        entry.active_rules_version = rules_version;
    }

    pub fn apply(self: *Projection, event: canonical.Payload) !void {
        switch (event) {
            .instrument_definition_observed => |definition| try self.applyDefinition(definition),
            .l2_book_snapshot => |snapshot| try self.applyFor(snapshot.instrument, event),
            .l2_book_delta => |delta| try self.applyFor(delta.instrument, event),
            .reference_price => |price| try self.applyFor(price.instrument, event),
            .market_data_health_changed => |change| try self.applyFor(change.instrument, event),
            else => {},
        }
    }

    fn applyDefinition(self: *Projection, definition: canonical.InstrumentDefinitionObserved) !void {
        if (self.getPtr(definition.instrument)) |entry| {
            if (std.meta.eql(entry.definition, definition)) return;
            if (definition.rules_version <= entry.definition.rules_version) return error.InstrumentRulesRegression;
            entry.definition = definition;
            return;
        }
        if (self.count == self.entries.len) return error.MarketInstrumentCapacityExceeded;
        self.entries[self.count] = .{ .instrument = definition.instrument, .definition = definition };
        self.count += 1;
    }

    fn applyFor(self: *Projection, instrument: canonical.InstrumentIdentity, event: canonical.Payload) !void {
        const entry = self.getPtr(instrument) orelse return error.MissingInstrumentDefinition;
        const failure_before = entry.failure;
        (switch (event) {
            .l2_book_snapshot => |snapshot| entry.applySnapshot(snapshot),
            .l2_book_delta => |delta| entry.applyDelta(delta),
            .reference_price => |price| {
                if (price.price.instrument != instrument or price.price.rules_version != entry.active_rules_version)
                    return error.MarketInstrumentMismatch;
                if (price.kind == .mark) entry.mark = price.price else entry.index = price.price;
            },
            .market_data_health_changed => |change| {
                if (change.health == .healthy and entry.health != .healthy) return error.FreshSnapshotRequired;
                entry.health = change.health;
            },
            else => unreachable,
        }) catch |err| {
            if (entry.failure != failure_before) self.failure_generation += 1;
            return err;
        };
    }

    pub fn aggregateHealth(self: *const Projection) canonical.MarketDataHealth {
        if (self.count == 0) return .awaiting_snapshot;
        var result: canonical.MarketDataHealth = .healthy;
        for (self.entries[0..self.count]) |entry| switch (entry.health) {
            .gap => return .gap,
            .awaiting_snapshot => result = .awaiting_snapshot,
            .healthy => {},
        };
        return result;
    }

    pub fn latestFailure(self: *const Projection) ?Failure {
        var index: usize = self.count;
        while (index != 0) {
            index -= 1;
            if (self.entries[index].failure) |failure| return failure;
        }
        return null;
    }
};

test "definition barrier and L2 continuity are isolated by Instrument" {
    var projection = Projection{};
    const first: canonical.InstrumentDefinitionObserved = .{ .instrument = 10, .rules_version = 3 };
    const second: canonical.InstrumentDefinitionObserved = .{ .instrument = 20, .rules_version = 4 };
    try projection.apply(.{ .instrument_definition_observed = first });
    try projection.apply(.{ .instrument_definition_observed = second });
    try projection.activateRules(first.instrument, first.rules_version);
    try projection.activateRules(second.instrument, second.rules_version);
    const first_book: canonical.L2BookSnapshot = .{ .instrument = 10, .sequence = 10, .best_bid = .{ .instrument = 10, .rules_version = 3, .ticks = 100 }, .best_ask = .{ .instrument = 10, .rules_version = 3, .ticks = 101 } };
    const second_book: canonical.L2BookSnapshot = .{ .instrument = 20, .sequence = 30, .best_bid = .{ .instrument = 20, .rules_version = 4, .ticks = 200 }, .best_ask = .{ .instrument = 20, .rules_version = 4, .ticks = 201 } };
    try projection.apply(.{ .l2_book_snapshot = first_book });
    try projection.apply(.{ .l2_book_snapshot = second_book });
    const first_before = projection.get(first.instrument).?;
    var gap: canonical.L2BookDelta = .{ .instrument = 20, .previous_sequence = 31, .sequence = 32, .best_bid = second_book.best_bid, .best_ask = second_book.best_ask };
    try std.testing.expectError(error.BookSequenceGap, projection.apply(.{ .l2_book_delta = gap }));
    try std.testing.expectEqualDeep(first_before, projection.get(first.instrument).?);
    gap.previous_sequence = 30;
    gap.sequence = 31;
    try std.testing.expectError(error.MarketGap, projection.apply(.{ .l2_book_delta = gap }));
    try projection.apply(.{ .instrument_definition_observed = .{ .instrument = 10, .rules_version = 5 } });
    try std.testing.expectEqualDeep(first_before.last_book, projection.get(10).?.last_book);
    try std.testing.expectEqual(first_before.health, projection.get(10).?.health);
    try std.testing.expectEqual(first_before.active_rules_version, projection.get(10).?.active_rules_version);
    try projection.activateRules(10, 5);
    try std.testing.expectEqual(canonical.MarketDataHealth.awaiting_snapshot, projection.get(10).?.health);
    try std.testing.expect(projection.get(10).?.last_book == null);
    try projection.apply(.{ .instrument_definition_observed = .{ .instrument = 30, .rules_version = 1 } });
    try projection.apply(.{ .instrument_definition_observed = .{ .instrument = 40, .rules_version = 1 } });
    const before_capacity = projection;
    try std.testing.expectError(error.MarketInstrumentCapacityExceeded, projection.apply(.{ .instrument_definition_observed = .{ .instrument = 50, .rules_version = 1 } }));
    try std.testing.expectEqualDeep(before_capacity, projection);
}
