//! Bounded public-market projection that consumes only canonical feed output.

const canonical = @import("canonical_event.zig");
const std = @import("std");

pub const Projection = struct {
    definition: ?canonical.InstrumentDefinitionObserved = null,
    active_rules_version: ?u64 = null,
    last_book: ?canonical.L2BookSnapshot = null,
    health: canonical.MarketDataHealth = .awaiting_snapshot,
    mark: ?canonical.InstrumentPrice = null,
    index: ?canonical.InstrumentPrice = null,

    pub fn activateRules(self: *Projection, instrument: canonical.InstrumentIdentity, rules_version: u64) !void {
        const definition = self.definition orelse return error.MissingInstrumentDefinition;
        if (definition.instrument != instrument or definition.rules_version != rules_version) return error.InvalidConfigurationBarrier;
        self.active_rules_version = rules_version;
    }

    pub fn apply(self: *Projection, event: canonical.CanonicalEvent) !void {
        switch (event) {
            .instrument_definition_observed => |definition| self.definition = definition,
            .l2_book_snapshot => |snapshot| try self.applySnapshot(snapshot),
            .l2_book_delta => |delta| try self.applyDelta(delta),
            .reference_price => |price| {
                if (price.kind == .mark) self.mark = price.price else self.index = price.price;
            },
            .market_data_health_changed => |change| {
                if (change.health == .healthy and self.health != .healthy) return error.FreshSnapshotRequired;
                self.health = change.health;
            },
            else => {},
        }
    }

    fn applySnapshot(self: *Projection, snapshot: canonical.L2BookSnapshot) !void {
        if (self.active_rules_version == null or self.active_rules_version.? != snapshot.best_bid.rules_version or snapshot.best_bid.rules_version != snapshot.best_ask.rules_version)
            return error.InstrumentRulesInactive;
        self.last_book = snapshot;
        self.health = .healthy;
    }

    fn applyDelta(self: *Projection, delta: canonical.L2BookDelta) !void {
        const previous = self.last_book orelse return self.gap(error.MissingBookSnapshot);
        if (self.health != .healthy) return error.MarketGap;
        if (delta.sequence == previous.sequence) {
            if (delta.previous_sequence == previous.sequence - 1 and std.meta.eql(delta.best_bid, previous.best_bid) and std.meta.eql(delta.best_ask, previous.best_ask)) return;
            return self.gap(error.ConflictingBookDelta);
        }
        if (delta.previous_sequence != previous.sequence or delta.sequence != previous.sequence + 1) return self.gap(error.BookSequenceGap);
        self.last_book = .{ .instrument = delta.instrument, .sequence = delta.sequence, .best_bid = delta.best_bid, .best_ask = delta.best_ask };
    }

    fn gap(self: *Projection, err: anyerror) anyerror!void {
        self.health = .gap;
        return err;
    }
};

test "definition barrier, L2 continuity, and independent reference prices are enforced" {
    var projection = Projection{};
    const definition: canonical.InstrumentDefinitionObserved = .{ .instrument = 1, .rules_version = 3 };
    const snapshot: canonical.L2BookSnapshot = .{ .instrument = 1, .sequence = 10, .best_bid = .{ .instrument = 1, .rules_version = 3, .ticks = 100 }, .best_ask = .{ .instrument = 1, .rules_version = 3, .ticks = 101 } };
    try projection.apply(.{ .instrument_definition_observed = definition });
    try std.testing.expectError(error.InstrumentRulesInactive, projection.apply(.{ .l2_book_snapshot = snapshot }));
    try projection.activateRules(1, 3);
    try projection.apply(.{ .l2_book_snapshot = snapshot });
    const delta: canonical.L2BookDelta = .{ .instrument = 1, .previous_sequence = 10, .sequence = 11, .best_bid = snapshot.best_bid, .best_ask = snapshot.best_ask };
    try projection.apply(.{ .l2_book_delta = delta });
    try projection.apply(.{ .l2_book_delta = delta });
    var conflicting = delta;
    conflicting.best_bid.ticks = 99;
    try std.testing.expectError(error.ConflictingBookDelta, projection.apply(.{ .l2_book_delta = conflicting }));
    try std.testing.expectEqual(canonical.MarketDataHealth.gap, projection.health);
    try std.testing.expectError(error.FreshSnapshotRequired, projection.apply(.{ .market_data_health_changed = .{ .instrument = 1, .health = .healthy } }));
    try std.testing.expectError(error.MarketGap, projection.apply(.{ .l2_book_delta = delta }));
    var fresh = snapshot;
    fresh.sequence = 20;
    try projection.apply(.{ .l2_book_snapshot = fresh });
    try std.testing.expectEqual(canonical.MarketDataHealth.healthy, projection.health);
    try projection.apply(.{ .reference_price = .{ .instrument = 1, .kind = .mark, .price = snapshot.best_bid } });
    try projection.apply(.{ .reference_price = .{ .instrument = 1, .kind = .index, .price = snapshot.best_ask } });
    try std.testing.expectEqual(@as(i128, 100), projection.mark.?.ticks);
    try std.testing.expectEqual(@as(i128, 101), projection.index.?.ticks);
}
