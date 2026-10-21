//! Bounded account bootstrap/observation projection for the Adapter seam.

const canonical = @import("../model/canonical_event.zig");
const std = @import("std");
pub const max_balances = canonical.max_asset_definitions;
pub const max_positions = @import("../trading/instrument_registry.zig").max_entries;
pub const max_margins = max_positions;
const max_seen = max_balances + max_positions + max_margins;

pub const AccountProjection = struct {
    pub const Failure = enum(u8) { invalid_snapshot, incomplete_snapshot, sequence_gap, identity_conflict, capacity_exhausted, invalid_bootstrap };
    bootstrap: ?canonical.BootstrapSnapshotIdentity = null,
    bootstrap_digest: ?[32]u8 = null,
    exchange_account: ?canonical.ExchangeAccountIdentity = null,
    source_stream: ?canonical.VenueSourceStreamIdentity = null,
    last_sequence: canonical.VenueSourceSequence = 0,
    // Validity of the retained observations. Current economic authority also
    // depends on the Shard's unresolved faults, exposed by integritySnapshot.
    valid: bool = false,
    failure: ?Failure = null,
    seen: [max_seen]canonical.AccountObservation = undefined,
    seen_count: u16 = 0,
    balances: [max_balances]canonical.AccountBalance = undefined,
    balance_count: u8 = 0,
    positions: [max_positions]canonical.AccountPosition = undefined,
    position_count: u8 = 0,
    margins: [max_margins]canonical.AccountMargin = undefined,
    margin_count: u8 = 0,

    pub fn apply(self: *AccountProjection, event: canonical.Payload) !void {
        switch (event) {
            .account_bootstrap_snapshot => |snapshot| {
                if (snapshot.balance_count > canonical.max_account_facts or snapshot.position_count > canonical.max_account_facts or snapshot.margin_count > canonical.max_account_facts)
                    return self.invalidate(.invalid_snapshot, error.InvalidSnapshot);
                if (!snapshot.scope.balances_complete or !snapshot.scope.positions_complete or !snapshot.scope.margins_complete)
                    return self.invalidate(.incomplete_snapshot, error.IncompleteSnapshotScope);
                for (snapshot.balances[0..snapshot.balance_count], 0..) |balance, index| {
                    if (!validBalance(balance)) return self.invalidate(.invalid_snapshot, error.InvalidAccountUnits);
                    for (snapshot.balances[0..index]) |known| if (known.asset == balance.asset)
                        return self.invalidate(.invalid_snapshot, error.DuplicateAccountKey);
                }
                for (snapshot.margins[0..snapshot.margin_count], 0..) |margin, index| {
                    if (!validMargin(margin)) return self.invalidate(.invalid_snapshot, error.InvalidAccountUnits);
                    for (snapshot.margins[0..index]) |known| if (known.instrument == margin.instrument)
                        return self.invalidate(.invalid_snapshot, error.DuplicateAccountKey);
                }
                for (snapshot.positions[0..snapshot.position_count], 0..) |position, index| {
                    if (!validPosition(position)) return self.invalidate(.invalid_snapshot, error.InvalidAccountUnits);
                    for (snapshot.positions[0..index]) |known| if (known.instrument == position.instrument and known.side == position.side)
                        return self.invalidate(.invalid_snapshot, error.DuplicateAccountKey);
                }
                var bytes: [@import("../persistence/canonical_event_codec.zig").max_encoded_len]u8 = undefined;
                const encoded = @import("../persistence/canonical_event_codec.zig").encodePayload(&bytes, event) catch |err|
                    return self.invalidate(.invalid_snapshot, err);
                var snapshot_digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(encoded, &snapshot_digest, .{});
                if (self.bootstrap) |identity| {
                    if (identity == snapshot.identity) {
                        if (self.bootstrap_digest == null or !std.mem.eql(u8, &self.bootstrap_digest.?, &snapshot_digest))
                            return self.invalidate(.identity_conflict, error.ConflictingBootstrapIdentity);
                        if (!self.valid) return error.InvalidProjection;
                        return;
                    }
                    if (self.source_stream == snapshot.source_stream and snapshot.source_sequence < self.last_sequence)
                        return self.invalidate(.sequence_gap, error.StaleBootstrap);
                }
                self.* = .{ .bootstrap = snapshot.identity, .bootstrap_digest = snapshot_digest, .exchange_account = snapshot.exchange_account, .source_stream = snapshot.source_stream, .last_sequence = snapshot.source_sequence, .valid = true, .failure = null };
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
        if (!validObservation(observation)) return self.invalidate(.invalid_snapshot, error.InvalidAccountUnits);
        if (try self.lookupObservation(observation)) return;
        if (!self.valid) return error.InvalidProjection;
        if (self.bootstrap != observation.bootstrap or self.exchange_account != observation.exchange_account)
            return self.invalidate(.invalid_bootstrap, error.InvalidBootstrap);
        if (self.source_stream) |stream| {
            if (stream != observation.source_stream or observation.source_sequence != (std.math.add(u64, self.last_sequence, 1) catch return self.invalidate(.sequence_gap, error.SourceSequenceGap)))
                return self.invalidate(.sequence_gap, error.SourceSequenceGap);
        } else self.source_stream = observation.source_stream;
        // Keep recent identities for duplicate detection; source sequence still
        // rejects an older observation after its identity leaves this window.
        if (self.seen_count == self.seen.len) {
            std.mem.copyForwards(canonical.AccountObservation, self.seen[0 .. self.seen.len - 1], self.seen[1..]);
        } else self.seen_count += 1;
        self.seen[self.seen_count - 1] = observation;
        self.last_sequence = observation.source_sequence;
        switch (observation.value) {
            .balance => |value| try self.applyBalance(value),
            .position => |value| try self.applyPosition(value),
            .margin => |value| try self.applyMargin(value),
        }
    }

    pub fn lookupObservation(self: *AccountProjection, observation: canonical.AccountObservation) !bool {
        for (self.seen[0..self.seen_count]) |known| if (known.identity == observation.identity) {
            if (std.meta.eql(known, observation)) return true;
            self.invalidate(.identity_conflict, error.ConflictingObservationIdentity) catch |err| return err;
        };
        return false;
    }

    pub fn rejectIdentityConflict(self: *AccountProjection) !void {
        return self.invalidate(.identity_conflict, error.ConflictingCanonicalIdentity);
    }

    fn applyBalance(self: *AccountProjection, observed: anytype) !void {
        if (observed.asset != observed.value.asset or !validBalance(observed.value))
            return self.invalidate(.invalid_snapshot, error.InvalidAccountUnits);
        for (self.balances[0..self.balance_count], 0..) |_, index| if (self.balances[index].asset == observed.asset) {
            if (observed.removed) remove(canonical.AccountBalance, &self.balances, &self.balance_count, index) else self.balances[index] = observed.value;
            return;
        };
        if (observed.removed) return;
        if (self.balance_count == self.balances.len) return self.invalidate(.capacity_exhausted, error.ObservationCapacityExceeded);
        self.balances[self.balance_count] = observed.value;
        self.balance_count += 1;
    }
    fn applyPosition(self: *AccountProjection, observed: anytype) !void {
        if (observed.instrument != observed.value.instrument or observed.side != observed.value.side or observed.value.quantity.instrument != observed.instrument)
            return self.invalidate(.invalid_snapshot, error.InvalidAccountUnits);
        for (self.positions[0..self.position_count], 0..) |_, index| if (self.positions[index].instrument == observed.instrument and self.positions[index].side == observed.side) {
            if (observed.removed) remove(canonical.AccountPosition, &self.positions, &self.position_count, index) else self.positions[index] = observed.value;
            return;
        };
        if (observed.removed) return;
        if (self.position_count == self.positions.len) return self.invalidate(.capacity_exhausted, error.ObservationCapacityExceeded);
        self.positions[self.position_count] = observed.value;
        self.position_count += 1;
    }
    fn applyMargin(self: *AccountProjection, observed: anytype) !void {
        if (observed.instrument != observed.value.instrument or !validMargin(observed.value))
            return self.invalidate(.invalid_snapshot, error.InvalidAccountUnits);
        for (self.margins[0..self.margin_count], 0..) |_, index| if (self.margins[index].instrument == observed.instrument) {
            if (observed.removed) remove(canonical.AccountMargin, &self.margins, &self.margin_count, index) else self.margins[index] = observed.value;
            return;
        };
        if (observed.removed) return;
        if (self.margin_count == self.margins.len) return self.invalidate(.capacity_exhausted, error.ObservationCapacityExceeded);
        self.margins[self.margin_count] = observed.value;
        self.margin_count += 1;
    }
    fn remove(comptime T: type, values: []T, count: *u8, index: usize) void {
        var cursor = index;
        while (cursor + 1 < count.*) : (cursor += 1) values[cursor] = values[cursor + 1];
        count.* -= 1;
    }

    fn validBalance(balance: canonical.AccountBalance) bool {
        if (balance.asset == 0 or balance.total.asset != balance.asset or balance.available.asset != balance.asset or balance.held.asset != balance.asset) return false;
        for ([_]?canonical.AssetAmount{ balance.liability, balance.cash_balance, balance.isolated_liability, balance.cross_liability }) |value|
            if (value) |amount| if (amount.asset != balance.asset) return false;
        return true;
    }

    fn validMargin(margin: canonical.AccountMargin) bool {
        if (margin.margin_ratio) |ratio| if (ratio.scale > canonical.Decimal.max_scale) return false;
        if (margin.usd_valuation) |valuation| {
            if (valuation.total_equity == null and valuation.adjusted_equity == null and valuation.initial_margin == null and valuation.maintenance_margin == null and valuation.isolated_equity == null) return false;
            for ([_]?canonical.Decimal{ valuation.total_equity, valuation.adjusted_equity, valuation.initial_margin, valuation.maintenance_margin, valuation.isolated_equity, margin.margin_ratio }) |value|
                if (value) |amount| if (amount.scale > canonical.Decimal.max_scale) return false;
        }
        const native = margin.amount orelse return margin.adjusted_equity == null and margin.initial_margin == null and margin.maintenance_margin == null and margin.isolated_equity == null and margin.usd_valuation != null;
        if (native.asset == 0) return false;
        for ([_]?canonical.AssetAmount{ margin.adjusted_equity, margin.initial_margin, margin.maintenance_margin, margin.isolated_equity }) |value|
            if (value) |amount| if (amount.asset != native.asset) return false;
        return true;
    }

    fn validPosition(position: canonical.AccountPosition) bool {
        if (position.instrument == 0 or position.quantity.instrument != position.instrument) return false;
        for ([_]?canonical.InstrumentPrice{ position.average_price, position.mark_price, position.liquidation_price }) |value|
            if (value) |price| if (price.instrument != position.instrument or price.rules_version != position.quantity.rules_version) return false;
        if (position.margin) |margin| if (position.unrealized_pnl) |pnl| if (margin.asset != pnl.asset) return false;
        return true;
    }

    fn validObservation(observation: canonical.AccountObservation) bool {
        return switch (observation.value) {
            .balance => |value| value.asset == value.value.asset and validBalance(value.value),
            .position => |value| value.instrument == value.value.instrument and value.side == value.value.side and validPosition(value.value),
            .margin => |value| value.instrument == value.value.instrument and validMargin(value.value),
        };
    }

    pub fn validate(self: *const AccountProjection) !void {
        if (self.balance_count > self.balances.len or self.position_count > self.positions.len or self.margin_count > self.margins.len or self.seen_count > self.seen.len) return error.InvalidAccountFactCount;
        if (self.valid and (self.bootstrap == null or self.bootstrap_digest == null or self.exchange_account == null or self.source_stream == null or self.failure != null)) return error.InvalidProjection;
        for (self.balances[0..self.balance_count], 0..) |balance, index| {
            if (!validBalance(balance)) return error.InvalidAccountUnits;
            for (self.balances[0..index]) |known| if (known.asset == balance.asset) return error.DuplicateAccountKey;
        }
        for (self.positions[0..self.position_count], 0..) |position, index| {
            if (!validPosition(position)) return error.InvalidAccountUnits;
            for (self.positions[0..index]) |known| if (known.instrument == position.instrument and known.side == position.side) return error.DuplicateAccountKey;
        }
        for (self.margins[0..self.margin_count], 0..) |margin, index| {
            if (!validMargin(margin)) return error.InvalidAccountUnits;
            for (self.margins[0..index]) |known| if (known.instrument == margin.instrument) return error.DuplicateAccountKey;
        }
        for (self.seen[0..self.seen_count]) |observation| if (!validObservation(observation)) return error.InvalidAccountUnits;
    }

    fn hashValue(hasher: *std.crypto.hash.sha2.Sha256, value: anytype) void {
        var bytes: [4096]u8 = undefined;
        const encoded = @import("../persistence/snapshot_codec.zig").encodeBare(&bytes, value) catch unreachable;
        hasher.update(encoded);
    }

    pub fn digest(self: *const AccountProjection) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashValue(&hasher, .{ self.bootstrap, self.bootstrap_digest, self.exchange_account, self.source_stream, self.last_sequence, self.valid, self.failure, self.seen_count, self.balance_count, self.position_count, self.margin_count });
        for (self.seen[0..self.seen_count]) |value| hashValue(&hasher, value);
        for (self.balances[0..self.balance_count]) |value| hashValue(&hasher, value);
        for (self.positions[0..self.position_count]) |value| hashValue(&hasher, value);
        for (self.margins[0..self.margin_count]) |value| hashValue(&hasher, value);
        return hasher.finalResult();
    }

    pub fn semanticDigest(self: *const AccountProjection) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashValue(&hasher, .{ self.exchange_account, self.valid, self.failure, self.balance_count, self.position_count, self.margin_count });
        var balances: [max_balances]canonical.AccountBalance = undefined;
        var positions: [max_positions]canonical.AccountPosition = undefined;
        var margins: [max_margins]canonical.AccountMargin = undefined;
        @memcpy(balances[0..self.balance_count], self.balances[0..self.balance_count]);
        @memcpy(positions[0..self.position_count], self.positions[0..self.position_count]);
        @memcpy(margins[0..self.margin_count], self.margins[0..self.margin_count]);
        std.mem.sort(canonical.AccountBalance, balances[0..self.balance_count], {}, struct {
            fn less(_: void, a: canonical.AccountBalance, b: canonical.AccountBalance) bool {
                return a.asset < b.asset;
            }
        }.less);
        std.mem.sort(canonical.AccountPosition, positions[0..self.position_count], {}, struct {
            fn less(_: void, a: canonical.AccountPosition, b: canonical.AccountPosition) bool {
                return a.instrument < b.instrument or (a.instrument == b.instrument and @intFromEnum(a.side) < @intFromEnum(b.side));
            }
        }.less);
        std.mem.sort(canonical.AccountMargin, margins[0..self.margin_count], {}, struct {
            fn less(_: void, a: canonical.AccountMargin, b: canonical.AccountMargin) bool {
                return (a.instrument orelse 0) < (b.instrument orelse 0);
            }
        }.less);
        for (balances[0..self.balance_count]) |value| hashValue(&hasher, value);
        for (positions[0..self.position_count]) |value| hashValue(&hasher, value);
        for (margins[0..self.margin_count]) |value| hashValue(&hasher, value);
        return hasher.finalResult();
    }

    /// Missing debt fields cannot prove an unlevered account.
    pub fn nativeAvailable(self: *const AccountProjection, asset: canonical.AssetIdentity) ?canonical.AssetAmount {
        if (!self.valid) return null;
        for (self.balances[0..self.balance_count]) |balance| {
            if (balance.asset != asset) continue;
            if (!validBalance(balance) or balance.cash_balance == null or balance.liability == null or balance.isolated_liability == null or balance.cross_liability == null) return null;
            if (balance.total.atoms < 0 or balance.available.atoms < 0 or balance.held.atoms < 0 or balance.cash_balance.?.atoms != balance.total.atoms or
                balance.available.atoms > balance.total.atoms or balance.held.atoms != balance.total.atoms - balance.available.atoms or
                balance.liability.?.atoms != 0 or balance.isolated_liability.?.atoms != 0 or balance.cross_liability.?.atoms != 0) return null;
            return balance.available;
        }
        return null;
    }

    /// Leveraged risk requires instrument-scoped native margin, never USD valuation.
    pub fn nativeMarginEvidence(self: *const AccountProjection, instrument: canonical.InstrumentIdentity, asset: canonical.AssetIdentity) ?canonical.AccountMargin {
        if (!self.valid) return null;
        var account_margin: ?canonical.AccountMargin = null;
        for (self.margins[0..self.margin_count]) |margin| {
            if ((margin.instrument != null and margin.instrument != instrument) or !validMargin(margin)) continue;
            const native = margin.amount orelse continue;
            if (native.asset != asset or native.atoms < 0 or margin.initial_margin == null or margin.maintenance_margin == null) continue;
            if (margin.initial_margin.?.atoms < 0 or margin.maintenance_margin.?.atoms < 0) continue;
            if (margin.instrument == instrument) {
                if (margin.isolated_equity == null or margin.isolated_equity.?.atoms < 0) return null;
                return margin;
            }
            if (margin.adjusted_equity) |equity| if (equity.atoms >= 0) {
                account_margin = margin;
            };
        }
        return account_margin;
    }

    fn invalidate(self: *AccountProjection, failure: Failure, err: anyerror) anyerror!void {
        self.valid = false;
        self.failure = failure;
        return err;
    }
};

test "native account bootstrap identity conflicts and mixed units invalidate observations" {
    var snapshot: canonical.AccountBootstrapSnapshot = .{ .identity = 1, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 4, .source_sequence = 0, .balance_count = 1, .position_count = 0, .margin_count = 0 };
    snapshot.balances[0] = .{ .asset = 5, .total = .{ .asset = 5, .atoms = 10 }, .available = .{ .asset = 5, .atoms = 8 }, .held = .{ .asset = 5, .atoms = 2 } };
    var projection = AccountProjection{};
    try projection.apply(.{ .account_bootstrap_snapshot = snapshot });
    try projection.validate();
    const original_digest = projection.digest();
    const original_semantic = projection.semanticDigest();
    try projection.apply(.{ .account_bootstrap_snapshot = snapshot });
    try std.testing.expectEqualSlices(u8, &original_digest, &projection.digest());
    var same_amounts = snapshot;
    same_amounts.identity = 2;
    same_amounts.source_sequence = 1;
    var fresh = AccountProjection{};
    try fresh.apply(.{ .account_bootstrap_snapshot = same_amounts });
    try std.testing.expectEqualSlices(u8, &original_semantic, &fresh.semanticDigest());
    try std.testing.expect(!std.mem.eql(u8, &original_digest, &fresh.digest()));
    snapshot.balances[0].total.atoms = 11;
    try std.testing.expectError(error.ConflictingBootstrapIdentity, projection.apply(.{ .account_bootstrap_snapshot = snapshot }));
    try std.testing.expect(!projection.valid);
    snapshot.identity = 2;
    snapshot.balances[0].total.asset = 6;
    try std.testing.expectError(error.InvalidAccountUnits, projection.apply(.{ .account_bootstrap_snapshot = snapshot }));
    try std.testing.expect(!projection.valid);
}

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

test "native cash proofs and USD margin digests preserve exact observations" {
    var snapshot: canonical.AccountBootstrapSnapshot = .{ .identity = 1, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 4, .source_sequence = 0, .balance_count = 1, .position_count = 0, .margin_count = 1 };
    snapshot.balances[0] = .{ .asset = 5, .total = .{ .asset = 5, .atoms = 9223372036854775818 }, .available = .{ .asset = 5, .atoms = 9223372036854775808 }, .held = .{ .asset = 5, .atoms = 10 }, .cash_balance = .{ .asset = 5, .atoms = 9223372036854775818 }, .liability = .{ .asset = 5, .atoms = 0 }, .isolated_liability = .{ .asset = 5, .atoms = 0 }, .cross_liability = .{ .asset = 5, .atoms = 0 } };
    snapshot.margins[0] = .{ .usd_valuation = .{ .total_equity = .{ .coefficient = 1, .scale = 20 }, .initial_margin = .{ .coefficient = 2, .scale = 20 } } };
    var projection = AccountProjection{};
    try projection.apply(.{ .account_bootstrap_snapshot = snapshot });
    try std.testing.expectEqual(@as(i128, 9223372036854775808), projection.nativeAvailable(5).?.atoms);
    try std.testing.expect(projection.nativeMarginEvidence(7, 5) == null);
    const original_digest = projection.digest();
    const original_semantic = projection.semanticDigest();
    const margin_observation: canonical.AccountObservation = .{ .identity = 3, .exchange_account = 2, .bootstrap = 1, .source_stream = 4, .source_sequence = 1, .value = .{ .margin = .{ .value = .{ .usd_valuation = .{ .total_equity = .{ .coefficient = 1, .scale = 20 }, .initial_margin = .{ .coefficient = 3, .scale = 20 } } } } } };
    try projection.apply(.{ .account_observed = margin_observation });
    try std.testing.expect(!std.mem.eql(u8, &original_digest, &projection.digest()));
    try std.testing.expect(!std.mem.eql(u8, &original_semantic, &projection.semanticDigest()));
    var borrowed: canonical.AccountObservation = .{ .identity = 4, .exchange_account = 2, .bootstrap = 1, .source_stream = 4, .source_sequence = 2, .value = .{ .balance = .{ .asset = 5, .value = snapshot.balances[0] } } };
    borrowed.value.balance.value.liability.?.atoms = 1;
    try projection.apply(.{ .account_observed = borrowed });
    try std.testing.expect(projection.nativeAvailable(5) == null);
    borrowed.identity = 5;
    borrowed.source_sequence = 3;
    borrowed.value.balance.value.total.asset = 6;
    try std.testing.expectError(error.InvalidAccountUnits, projection.apply(.{ .account_observed = borrowed }));
    try std.testing.expectEqual(@as(u64, 2), projection.last_sequence);
    try std.testing.expectEqual(@as(u8, 2), projection.seen_count);
    try projection.validate();
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
    changed.value.margin.value.amount.?.atoms = 11;
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

test "account observations retain a bounded duplicate window without exhausting the projection" {
    var projection = AccountProjection{};
    try projection.apply(.{ .account_bootstrap_snapshot = .{ .identity = 1, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 4, .source_sequence = 0, .balance_count = 0, .position_count = 0, .margin_count = 0 } });
    var observation: canonical.AccountObservation = .{ .identity = 100, .exchange_account = 2, .bootstrap = 1, .source_stream = 4, .source_sequence = 1, .value = .{ .margin = .{ .value = .{ .amount = .{ .asset = 5, .atoms = 1 } } } } };
    for (0..max_seen + 1) |index| {
        observation.identity = 100 + index;
        observation.source_sequence = 1 + index;
        observation.value.margin.value.amount.?.atoms = 1 + @as(i128, @intCast(index));
        try projection.apply(.{ .account_observed = observation });
    }
    try std.testing.expect(projection.valid);
    try std.testing.expectEqual(@as(u16, max_seen), projection.seen_count);
    try projection.apply(.{ .account_observed = observation });
    observation.identity = 100;
    observation.source_sequence = 1;
    try std.testing.expectError(error.SourceSequenceGap, projection.apply(.{ .account_observed = observation }));
}
