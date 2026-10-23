const std = @import("std");
pub const capacity = 128;
pub const ConsumptionSource = struct {
    kind: enum(u8) { fill, fee_adjustment },
    identity: u128,
    account: u128,
    portfolio: u128,
    asset: u64,
    strategy: u128 = 0,
    cycle_first_sequence: u64 = 0,
    digest: [32]u8,
    fact_sequence: u64,
};
pub const Live = struct {
    strategy: u128 = 0,
    first_sequence: u64 = 0,
    member: u8 = 0,
    account: u128 = 0,
    portfolio: u128 = 0,
    asset: u64 = 0,
    instrument: u128 = 0,
    credited_atoms: i128 = 0,
    original_atoms: i128 = 0,
    remaining: i128 = 0,
    frozen: i128 = 0,
    version: u64 = 1,
    original_fact: u64 = 0,
};
pub const Receipt = struct {
    source: ConsumptionSource,
    allocations: [capacity]i128 = @splat(0),
    frozen_allocations: [capacity]i128 = @splat(0),
};
pub const ConsumptionResult = struct { consumed_atoms: i128 = 0, frozen_consumed_atoms: i128 = 0 };
pub const Freeze = struct {
    strategy: u128,
    first_sequence: u64,
    member: u8,
    expected_version: u64,
    original_fact: u64,
    atoms: i128,
};
pub const Credit = struct { source: ConsumptionSource, slot: u8, atoms: i128 };
pub const State = struct {
    credits: [32]Credit = @splat(std.mem.zeroes(Credit)),
    credit_count: u8 = 0,
    live: [capacity]Live = @splat(.{}),
    live_count: u16 = 0,
    receipts: [capacity]Receipt = @splat(std.mem.zeroes(Receipt)),
    receipt_count: u16 = 0,

    pub fn checkNewRiskCapacity(self: *const State) !void {
        var outstanding = false;
        for (self.live[0..self.live_count]) |live| if (live.remaining > 0) {
            outstanding = true;
        };
        // shortcut: reserve sixteen source slots for in-flight facts; unbounded partial fills still require durable fault handling.
        if (outstanding and (self.receipt_count >= capacity - 16 or self.credit_count == self.credits.len)) return error.ResidualConsumptionCapacity;
    }
    pub fn checkSellCapacity(self: *const State, gross: i64, pending: i64, committed: i64, group: i64) !void {
        const possible = try std.math.add(i64, pending, try std.math.add(i64, committed, group));
        if (possible > @max(gross, 0)) try self.checkNewRiskCapacity();
    }
    pub fn add(self: *State, live: Live) !void {
        if (self.live_count == capacity) return error.ResidualCapacity;
        if (self.find(live.strategy, live.first_sequence, live.member) != null or live.remaining != live.original_atoms or live.remaining <= 0 or live.frozen != 0 or live.original_fact == 0) return error.InvalidResidual;
        self.live[self.live_count] = live;
        self.live_count += 1;
    }
    pub fn find(self: *const State, strategy: u128, first: u64, member: u8) ?Live {
        for (self.live[0..self.live_count]) |live| if (live.strategy == strategy and live.first_sequence == first and live.member == member) return live;
        return null;
    }
    pub fn outstandingAtoms(self: *const State, account: u128, portfolio: u128, asset: u64) !i128 {
        var total: i128 = 0;
        for (self.live[0..self.live_count]) |live| if (live.account == account and live.portfolio == portfolio and live.asset == asset) {
            total = try std.math.add(i128, total, live.remaining);
        };
        return total;
    }
    pub fn frozenAtoms(self: *const State, account: u128, portfolio: u128, asset: u64) !i128 {
        var total: i128 = 0;
        for (self.live[0..self.live_count]) |live| if (live.account == account and live.portfolio == portfolio and live.asset == asset) {
            total = try std.math.add(i128, total, live.frozen);
        };
        return total;
    }
    pub fn freeze(self: *State, request: Freeze, release: bool) !void {
        if (request.atoms <= 0) return error.InvalidResidualFreeze;
        for (self.live[0..self.live_count]) |*live| {
            if (live.strategy != request.strategy or live.first_sequence != request.first_sequence or live.member != request.member) continue;
            if (live.version != request.expected_version or live.original_fact != request.original_fact) return error.ResidualVersionConflict;
            if (release) {
                if (request.atoms > live.frozen) return error.InvalidResidualFreeze;
                live.frozen -= request.atoms;
            } else {
                if (request.atoms > live.remaining - live.frozen) return error.InvalidResidualFreeze;
                live.frozen += request.atoms;
            }
            live.version = try std.math.add(u64, live.version, 1);
            return;
        }
        return error.UnknownResidual;
    }
    pub fn receipt(self: *const State, source: ConsumptionSource) ?Receipt {
        for (self.receipts[0..self.receipt_count]) |entry| if (sameSource(entry.source, source)) return entry;
        return null;
    }
    pub fn consumeOwned(self: *State, account: u128, portfolio: u128, asset: u64, atoms: i128, source: ConsumptionSource) !ConsumptionResult {
        if (atoms < 0 or source.account != account or source.portfolio != portfolio or source.asset != asset or source.identity == 0 or source.fact_sequence == 0 or std.mem.allEqual(u8, &source.digest, 0)) return error.InvalidResidualConsumption;
        if (self.receipt(source) != null) return error.DuplicateResidualConsumption;
        if (atoms == 0 or try self.outstandingAtoms(account, portfolio, asset) == 0) return .{};
        if (self.receipt_count == capacity) return error.ResidualConsumptionCapacity;
        var entry: Receipt = .{ .source = source };
        var pending = atoms;
        var result: ConsumptionResult = .{};
        for (0..2) |pass| for (self.live[0..self.live_count], 0..) |*live, index| {
            if (live.account != account or live.portfolio != portfolio or live.asset != asset) continue;
            const available = if (pass == 0) live.remaining - live.frozen else live.frozen;
            const take = @min(available, pending);
            if (take == 0) continue;
            live.remaining -= take;
            live.version = try std.math.add(u64, live.version, 1);
            entry.allocations[index] += take;
            if (pass == 1) {
                live.frozen -= take;
                entry.frozen_allocations[index] += take;
                result.frozen_consumed_atoms += take;
            }
            pending -= take;
            result.consumed_atoms += take;
        };
        if (result.consumed_atoms != 0) {
            self.receipts[self.receipt_count] = entry;
            self.receipt_count += 1;
        }
        return result;
    }
    pub fn restoreConsumption(self: *State, source: ConsumptionSource, atoms: i128) !i128 {
        if (atoms < 0) return error.InvalidResidualConsumption;
        for (self.receipts[0..self.receipt_count]) |*entry| {
            if (!sameSource(entry.source, source)) continue;
            var pending = atoms;
            var cursor: usize = self.live_count;
            while (cursor > 0) {
                cursor -= 1;
                const restore = @min(pending, entry.allocations[cursor]);
                if (restore == 0) continue;
                const frozen = @min(restore, entry.frozen_allocations[cursor]);
                self.live[cursor].remaining += restore;
                self.live[cursor].frozen += frozen;
                self.live[cursor].version = try std.math.add(u64, self.live[cursor].version, 1);
                entry.allocations[cursor] -= restore;
                entry.frozen_allocations[cursor] -= frozen;
                pending -= restore;
            }
            return atoms - pending;
        }
        return 0;
    }
    pub fn creditOwned(self: *State, source: ConsumptionSource, atoms: i128) !i128 {
        if (source.kind != .fee_adjustment or atoms <= 0 or source.fact_sequence == 0 or source.identity == 0 or std.mem.allEqual(u8, &source.digest, 0)) return error.InvalidResidualCredit;
        for (self.credits[0..self.credit_count]) |known| if (sameSource(known.source, source)) {
            if (known.atoms != atoms or !std.mem.eql(u8, &known.source.digest, &source.digest)) return error.ConflictingResidualCredit;
            return 0;
        };
        var slot: ?usize = null;
        for (self.live[0..self.live_count], 0..) |live, index| {
            if (live.strategy != source.strategy or live.first_sequence != source.cycle_first_sequence or live.account != source.account or live.portfolio != source.portfolio or live.asset != source.asset) continue;
            if (slot != null) return error.AmbiguousResidualCredit;
            slot = index;
        }
        const index = slot orelse return error.UnknownResidual;
        if (self.credit_count == self.credits.len) return error.ResidualCreditCapacity;
        const credited = try std.math.add(i128, self.live[index].credited_atoms, atoms);
        const remaining = try std.math.add(i128, self.live[index].remaining, atoms);
        self.live[index].version = try std.math.add(u64, self.live[index].version, 1);
        self.live[index].credited_atoms = credited;
        self.live[index].remaining = remaining;
        self.credits[self.credit_count] = .{ .source = source, .slot = @intCast(index), .atoms = atoms };
        self.credit_count += 1;
        return atoms;
    }
    pub fn validate(self: *const State) !void {
        if (self.live_count > capacity or self.receipt_count > capacity or self.credit_count > self.credits.len) return error.InvalidResidual;
        for (self.receipts[0..self.receipt_count], 0..) |entry, index| {
            if (entry.source.identity == 0 or entry.source.fact_sequence == 0 or std.mem.allEqual(u8, &entry.source.digest, 0)) return error.InvalidResidual;
            for (self.receipts[0..index]) |prior| if (sameSource(prior.source, entry.source)) return error.InvalidResidual;
            for (entry.allocations[self.live_count..]) |atoms| if (atoms != 0) return error.InvalidResidual;
            for (entry.frozen_allocations[self.live_count..]) |atoms| if (atoms != 0) return error.InvalidResidual;
        }
        for (self.live[0..self.live_count], 0..) |live, index| {
            if (live.remaining < 0 or live.frozen < 0 or live.frozen > live.remaining or live.original_atoms <= 0 or live.version == 0) return error.InvalidResidual;
            var consumed: i128 = 0;
            for (self.receipts[0..self.receipt_count]) |entry| {
                if (entry.allocations[index] < 0 or entry.frozen_allocations[index] < 0 or entry.frozen_allocations[index] > entry.allocations[index]) return error.InvalidResidual;
                if (entry.allocations[index] != 0 and (entry.source.account != live.account or entry.source.portfolio != live.portfolio or entry.source.asset != live.asset)) return error.InvalidResidual;
                consumed = try std.math.add(i128, consumed, entry.allocations[index]);
            }
            var credit_total: i128 = 0;
            for (self.credits[0..self.credit_count], 0..) |credit, credit_index| {
                for (self.credits[0..credit_index]) |prior| if (sameSource(prior.source, credit.source)) return error.InvalidResidual;
                if (credit.source.identity == 0 or std.mem.allEqual(u8, &credit.source.digest, 0)) return error.InvalidResidual;
                if (credit.slot >= self.live_count or credit.atoms <= 0 or credit.source.kind != .fee_adjustment or credit.source.fact_sequence == 0) return error.InvalidResidual;
                if (credit.slot == index) {
                    if (credit.source.strategy != live.strategy or credit.source.cycle_first_sequence != live.first_sequence or credit.source.account != live.account or credit.source.portfolio != live.portfolio or credit.source.asset != live.asset) return error.InvalidResidual;
                    credit_total = try std.math.add(i128, credit_total, credit.atoms);
                }
            }
            if (credit_total != live.credited_atoms or try std.math.add(i128, consumed, live.remaining) != try std.math.add(i128, live.original_atoms, credit_total)) return error.InvalidResidual;
        }
    }
};
fn sameSource(a: ConsumptionSource, b: ConsumptionSource) bool {
    return a.kind == b.kind and a.identity == b.identity and a.account == b.account and a.portfolio == b.portfolio and a.asset == b.asset;
}

test "owned residual capacity preserves sixteen bounded in-flight slots and refuses to invent consumption" {
    var state: State = .{};
    try state.add(.{ .strategy = 9, .first_sequence = 3, .member = 0, .account = 20, .portfolio = 10, .asset = 2, .instrument = 101, .original_atoms = 129, .remaining = 129, .original_fact = 1 });
    for (0..capacity) |index| {
        if (index < capacity - 16) try state.checkNewRiskCapacity() else try std.testing.expectError(error.ResidualConsumptionCapacity, state.checkNewRiskCapacity());
        if (index == capacity - 16) {
            try state.checkSellCapacity(10, 10, 0, 0);
            try state.checkSellCapacity(10, 5, 0, 5);
            try std.testing.expectError(error.ResidualConsumptionCapacity, state.checkSellCapacity(10, 10, 10, 0));
            try std.testing.expectError(error.ResidualConsumptionCapacity, state.checkSellCapacity(10, 6, 0, 5));
        }
        const source: ConsumptionSource = .{ .kind = .fill, .identity = index + 1, .account = 20, .portfolio = 10, .asset = 2, .digest = @splat(1), .fact_sequence = index + 2 };
        const result = try state.consumeOwned(20, 10, 2, 1, source);
        try std.testing.expectEqual(@as(i128, 1), result.consumed_atoms);
        try std.testing.expectEqual(@as(i128, 0), result.frozen_consumed_atoms);
    }
    try state.validate();
    try std.testing.expectEqual(@as(i128, 1), try state.outstandingAtoms(20, 10, 2));
    try std.testing.expectEqual(@as(i128, 0), try state.frozenAtoms(20, 10, 2));
    const source: ConsumptionSource = .{ .kind = .fill, .identity = 999, .account = 20, .portfolio = 10, .asset = 2, .digest = @splat(2), .fact_sequence = 999 };
    try std.testing.expectError(error.ResidualConsumptionCapacity, state.consumeOwned(20, 10, 2, 1, source));
    try std.testing.expectEqual(@as(i128, 1), try state.outstandingAtoms(20, 10, 2));
    try std.testing.expectEqual(@as(u16, 128), state.receipt_count);
    try std.testing.expect(state.receipt(source) == null);
    try state.validate();
}
