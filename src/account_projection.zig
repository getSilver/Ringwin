//! Bounded account bootstrap/observation projection for the Adapter seam.

const canonical = @import("canonical_event.zig");
const std = @import("std");

pub const AccountProjection = struct {
    bootstrap: ?canonical.BootstrapSnapshotIdentity = null,
    exchange_account: ?canonical.ExchangeAccountIdentity = null,
    source_stream: ?canonical.VenueSourceStreamIdentity = null,
    last_sequence: canonical.VenueSourceSequence = 0,
    valid: bool = false,
    seen: [canonical.max_account_facts]canonical.AccountObservation = undefined,
    seen_count: u8 = 0,
    balances: [canonical.max_account_facts]canonical.AccountBalance = undefined,
    balance_count: u8 = 0,
    positions: [canonical.max_account_facts]canonical.AccountPosition = undefined,
    position_count: u8 = 0,
    margins: [canonical.max_account_facts]canonical.AccountMargin = undefined,
    margin_count: u8 = 0,

    pub fn apply(self: *AccountProjection, event: canonical.CanonicalEvent) !void {
        switch (event) {
            .account_bootstrap_snapshot => |snapshot| {
                if (snapshot.balance_count > canonical.max_account_facts or snapshot.position_count > canonical.max_account_facts or snapshot.margin_count > canonical.max_account_facts)
                    return error.InvalidSnapshot;
                if (!snapshot.scope.balances_complete or !snapshot.scope.positions_complete or !snapshot.scope.margins_complete) return error.IncompleteSnapshotScope;
                self.* = .{ .bootstrap = snapshot.identity, .exchange_account = snapshot.exchange_account, .source_stream = snapshot.source_stream, .last_sequence = snapshot.source_sequence, .valid = true };
                @memcpy(self.balances[0..snapshot.balance_count], snapshot.balances[0..snapshot.balance_count]);
                @memcpy(self.positions[0..snapshot.position_count], snapshot.positions[0..snapshot.position_count]);
                @memcpy(self.margins[0..snapshot.margin_count], snapshot.margins[0..snapshot.margin_count]);
                self.balance_count = snapshot.balance_count;
                self.position_count = snapshot.position_count;
                self.margin_count = snapshot.margin_count;
            },
            .account_observed => |observation| try self.applyObserved(observation),
            else => {},
        }
    }

    fn applyObserved(self: *AccountProjection, observation: canonical.AccountObservation) !void {
        for (self.seen[0..self.seen_count]) |known| if (known.identity == observation.identity) {
            if (std.meta.eql(known, observation)) return;
            return self.invalidate(error.ConflictingObservationIdentity);
        };
        if (!self.valid or self.bootstrap != observation.bootstrap or self.exchange_account != observation.exchange_account) return self.invalidate(error.InvalidBootstrap);
        if (self.source_stream) |stream| {
            if (stream != observation.source_stream or observation.source_sequence != self.last_sequence + 1)
                return self.invalidate(error.SourceSequenceGap);
        } else self.source_stream = observation.source_stream;
        if (self.seen_count == self.seen.len) return self.invalidate(error.ObservationCapacityExceeded);
        self.seen[self.seen_count] = observation;
        self.seen_count += 1;
        self.last_sequence = observation.source_sequence;
        switch (observation.value) {
            .balance => |value| try self.applyBalance(value),
            .position => |value| try self.applyPosition(value),
            .margin => |value| try self.applyMargin(value),
        }
    }

    fn applyBalance(self: *AccountProjection, observed: anytype) !void {
        for (self.balances[0..self.balance_count], 0..) |_, index| if (self.balances[index].asset == observed.asset) {
            if (observed.removed) remove(canonical.AccountBalance, &self.balances, &self.balance_count, index) else self.balances[index] = observed.value;
            return;
        };
        if (observed.removed) return;
        if (self.balance_count == self.balances.len) return self.invalidate(error.ObservationCapacityExceeded);
        self.balances[self.balance_count] = observed.value;
        self.balance_count += 1;
    }
    fn applyPosition(self: *AccountProjection, observed: anytype) !void {
        for (self.positions[0..self.position_count], 0..) |_, index| if (self.positions[index].instrument == observed.instrument and self.positions[index].side == observed.side) {
            if (observed.removed) remove(canonical.AccountPosition, &self.positions, &self.position_count, index) else self.positions[index] = .{ .instrument = observed.instrument, .side = observed.side, .quantity = observed.value };
            return;
        };
        if (observed.removed) return;
        if (self.position_count == self.positions.len) return self.invalidate(error.ObservationCapacityExceeded);
        self.positions[self.position_count] = .{ .instrument = observed.instrument, .side = observed.side, .quantity = observed.value };
        self.position_count += 1;
    }
    fn applyMargin(self: *AccountProjection, observed: anytype) !void {
        for (self.margins[0..self.margin_count], 0..) |_, index| if (self.margins[index].instrument == observed.instrument) {
            if (observed.removed) remove(canonical.AccountMargin, &self.margins, &self.margin_count, index) else self.margins[index] = observed.value;
            return;
        };
        if (observed.removed) return;
        if (self.margin_count == self.margins.len) return self.invalidate(error.ObservationCapacityExceeded);
        self.margins[self.margin_count] = observed.value;
        self.margin_count += 1;
    }
    fn remove(comptime T: type, values: *[canonical.max_account_facts]T, count: *u8, index: usize) void {
        var cursor = index;
        while (cursor + 1 < count.*) : (cursor += 1) values[cursor] = values[cursor + 1];
        count.* -= 1;
    }

    fn invalidate(self: *AccountProjection, err: anyerror) anyerror!void {
        self.valid = false;
        return err;
    }
};

test "observations require a bootstrap and a continuous source" {
    var projection = AccountProjection{};
    const snapshot: canonical.AccountBootstrapSnapshot = .{ .identity = 1, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 4, .source_sequence = 0, .balance_count = 0, .position_count = 0, .margin_count = 0 };
    try projection.apply(.{ .account_bootstrap_snapshot = snapshot });
    const observed: canonical.AccountObservation = .{
        .identity = 3,
        .exchange_account = 2,
        .bootstrap = 1,
        .source_stream = 4,
        .source_sequence = 1,
        .value = .{ .balance = .{ .asset = 5, .value = .{ .asset = 5, .total = .{ .asset = 5, .atoms = 10 }, .available = .{ .asset = 5, .atoms = 8 }, .held = .{ .asset = 5, .atoms = 2 } } } },
    };
    try projection.apply(.{ .account_observed = observed });
    try projection.apply(.{ .account_observed = observed });
    try std.testing.expectEqual(@as(u8, 1), projection.balance_count);
    var removed = observed;
    removed.identity = 4;
    removed.source_sequence = 2;
    removed.value.balance.removed = true;
    try projection.apply(.{ .account_observed = removed });
    try std.testing.expectEqual(@as(u8, 0), projection.balance_count);
    try std.testing.expect(projection.valid);
    var gap = observed;
    gap.identity = 5;
    gap.source_sequence = 4;
    try std.testing.expectError(error.SourceSequenceGap, projection.apply(.{ .account_observed = gap }));
    try std.testing.expect(!projection.valid);
}

test "partial snapshots and conflicting or regressing observations invalidate only this projection" {
    const complete: canonical.AccountBootstrapSnapshot = .{ .identity = 1, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 4, .source_sequence = 0, .balance_count = 0, .position_count = 0, .margin_count = 0 };
    var partial = complete;
    partial.scope.balances_complete = false;
    var rejected = AccountProjection{};
    try std.testing.expectError(error.IncompleteSnapshotScope, rejected.apply(.{ .account_bootstrap_snapshot = partial }));

    const observed: canonical.AccountObservation = .{ .identity = 3, .exchange_account = 2, .bootstrap = 1, .source_stream = 4, .source_sequence = 1, .value = .{ .margin = .{ .value = .{ .amount = .{ .asset = 5, .atoms = 10 } } } } };
    var conflicting = AccountProjection{};
    try conflicting.apply(.{ .account_bootstrap_snapshot = complete });
    try conflicting.apply(.{ .account_observed = observed });
    var changed = observed;
    changed.value.margin.value.amount.atoms = 11;
    try std.testing.expectError(error.ConflictingObservationIdentity, conflicting.apply(.{ .account_observed = changed }));
    try std.testing.expect(!conflicting.valid);

    var regressing = AccountProjection{};
    try regressing.apply(.{ .account_bootstrap_snapshot = complete });
    try regressing.apply(.{ .account_observed = observed });
    var old = observed;
    old.identity = 4;
    old.source_sequence = 0;
    try std.testing.expectError(error.SourceSequenceGap, regressing.apply(.{ .account_observed = old }));
    try std.testing.expect(!regressing.valid);
}
