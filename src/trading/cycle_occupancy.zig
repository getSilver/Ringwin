const std = @import("std");
pub const max_cycles = 64;
pub const max_members = 2;
pub const max_residual_rules = 16;
pub const ResidualRule = struct {
    asset: u64,
    asset_version: u64,
    version: u64,
    max_atoms: i128,
    max_total_atoms: i128,

    pub fn validate(self: ResidualRule) !void {
        if (self.asset == 0 or self.asset_version == 0 or self.version == 0 or self.max_atoms <= 0 or
            self.max_total_atoms < self.max_atoms) return error.InvalidResidualRule;
    }
};
pub const Residual = struct {
    account: u128,
    portfolio: u128,
    instrument: u128,
    asset: u64,
    atoms: i128,
    instrument_version: u32,
    base_atoms_per_lot: i128,
    rule: ResidualRule,
    rule_fact_sequence: u64,
    accepted_at_utc_ns: u64,
    economic_digest: [32]u8,
};
pub const Member = struct { account: u128 = 0, instrument: u128 = 0 };
pub const Record = struct {
    strategy: u128 = 0,
    first_sequence: u64 = 0,
    portfolio: u128 = 0,
    configuration_digest: [32]u8 = @splat(0),
    content_digest: [32]u8 = @splat(0),
    fact_sequence: u64 = 0,
    members: [max_members]Member = @splat(.{}),
    count: u8 = 0,
};
pub const Closure = struct {
    strategy: u128,
    first_sequence: u64,
    content_digest: [32]u8,
    reconciliation_roots: [max_members][32]u8,
    residuals: [max_members]?Residual = @splat(null),
};
pub const Closed = struct {
    record: Record,
    proof: Closure,
    fact_sequence: u64,
};
pub const State = struct {
    residual_commitment_fact: u64 = 0,
    residual_lifecycle: @import("residual_lifecycle.zig").State = .{},
    records: [max_cycles]Record = @splat(.{}),
    count: u8 = 0,
    // shortcut: completed identities remain resident; add authenticated archival before exceeding 64 closures.
    closed: [max_cycles]Closed = @splat(std.mem.zeroes(Closed)),
    closed_count: u8 = 0,
    residual_rules: [max_residual_rules]ResidualRule = @splat(std.mem.zeroes(ResidualRule)),
    residual_rule_barriers: [max_residual_rules]u64 = @splat(0),
    residual_rule_count: u8 = 0,

    pub fn configureResidual(self: *State, rule: ResidualRule, barrier: u64) !bool {
        try rule.validate();
        if (barrier == 0) return error.InvalidResidualRule;
        for (self.residual_rules[0..self.residual_rule_count], 0..) |*known, index| {
            if (known.asset != rule.asset) continue;
            if (std.meta.eql(known.*, rule)) return false;
            if (rule.version <= known.version or rule.asset_version < known.asset_version) return error.ResidualRuleConflict;
            known.* = rule;
            self.residual_rule_barriers[index] = barrier;
            return true;
        }
        if (self.residual_rule_count == max_residual_rules) return error.ResidualRuleCapacity;
        self.residual_rules[self.residual_rule_count] = rule;
        self.residual_rule_barriers[self.residual_rule_count] = barrier;
        self.residual_rule_count += 1;
        return true;
    }

    pub fn residualRule(self: *const State, asset: u64) ?ResidualRule {
        for (self.residual_rules[0..self.residual_rule_count]) |rule| if (rule.asset == asset) return rule;
        return null;
    }

    pub fn residualRuleBarrier(self: *const State, asset: u64) u64 {
        for (self.residual_rules[0..self.residual_rule_count], 0..) |rule, index| if (rule.asset == asset) return self.residual_rule_barriers[index];
        return 0;
    }

    pub const ConsumptionSource = @import("residual_lifecycle.zig").ConsumptionSource;
    pub const ConsumptionResult = @import("residual_lifecycle.zig").ConsumptionResult;
    pub fn reservedAtoms(self: *const State, account: u128, portfolio: u128, asset: u64) !i128 {
        return self.residual_lifecycle.frozenAtoms(account, portfolio, asset);
    }
    pub fn outstandingAtoms(self: *const State, account: u128, portfolio: u128, asset: u64) !i128 {
        return self.residual_lifecycle.outstandingAtoms(account, portfolio, asset);
    }
    pub fn consumeOwned(self: *State, account: u128, portfolio: u128, asset: u64, atoms: i128, source: ConsumptionSource) !ConsumptionResult {
        return self.residual_lifecycle.consumeOwned(account, portfolio, asset, atoms, source);
    }
    pub fn creditOwned(self: *State, source: ConsumptionSource, atoms: i128) !i128 {
        return self.residual_lifecycle.creditOwned(source, atoms);
    }
    pub fn restoreConsumption(self: *State, source: ConsumptionSource, atoms: i128) !i128 {
        return self.residual_lifecycle.restoreConsumption(source, atoms);
    }
    pub fn receipt(self: *const State, source: ConsumptionSource) ?@import("residual_lifecycle.zig").Receipt {
        return self.residual_lifecycle.receipt(source);
    }
    pub fn hasResidual(self: *const State) bool {
        return self.residual_lifecycle.live_count != 0;
    }
    pub fn reservedInstrumentAtoms(self: *const State, account: u128, portfolio: u128, asset: u64, instrument: u128) !i128 {
        var result: i128 = 0;
        for (self.residual_lifecycle.live[0..self.residual_lifecycle.live_count]) |live| if (live.account == account and live.portfolio == portfolio and live.asset == asset and live.instrument == instrument) {
            result = try std.math.add(i128, result, live.remaining);
        };
        return result;
    }
    pub fn checkResidualLimit(self: *const State, proposed: Residual) !void {
        var total = proposed.atoms;
        for (self.residual_lifecycle.live[0..self.residual_lifecycle.live_count]) |live| if (live.asset == proposed.asset) {
            total = try std.math.add(i128, total, live.remaining);
        };
        if (proposed.atoms <= 0 or proposed.atoms > proposed.rule.max_atoms or total > proposed.rule.max_total_atoms) return error.ResidualLimit;
    }

    pub fn completed(self: *const State, strategy: u128, first_sequence: u64) ?Closed {
        for (self.closed[0..self.closed_count]) |entry|
            if (entry.proof.strategy == strategy and entry.proof.first_sequence == first_sequence) return entry;
        return null;
    }

    pub fn close(self: *State, proof: Closure, fact_sequence: u64) !void {
        if (self.completed(proof.strategy, proof.first_sequence)) |known| {
            if (!std.meta.eql(known.proof, proof)) return error.ConflictingCycleClosure;
            return;
        }
        if (self.closed_count == max_cycles) return error.CycleClosureCapacity;
        for (self.records[0..self.count], 0..) |record, index| {
            if (record.strategy != proof.strategy or record.first_sequence != proof.first_sequence) continue;
            if (fact_sequence <= record.fact_sequence or !std.mem.eql(u8, &record.content_digest, &proof.content_digest)) return error.ConflictingCycleClosure;
            for (proof.reconciliation_roots) |root| if (std.mem.allEqual(u8, &root, 0)) return error.ConflictingCycleClosure;
            for (proof.residuals, 0..) |maybe, member| if (maybe) |residual| try self.residual_lifecycle.add(.{
                .strategy = record.strategy,
                .first_sequence = record.first_sequence,
                .member = @intCast(member),
                .account = residual.account,
                .portfolio = residual.portfolio,
                .asset = residual.asset,
                .instrument = residual.instrument,
                .original_atoms = residual.atoms,
                .remaining = residual.atoms,
                .original_fact = fact_sequence,
            });
            self.closed[self.closed_count] = .{ .record = record, .proof = proof, .fact_sequence = fact_sequence };
            self.closed_count += 1;
            std.mem.copyForwards(Record, self.records[index .. self.count - 1], self.records[index + 1 .. self.count]);
            self.count -= 1;
            self.records[self.count] = .{};
            return;
        }
        return error.UnknownCycle;
    }

    pub fn find(self: *const State, strategy: u128, first_sequence: u64) ?Record {
        for (self.records[0..self.count]) |record|
            if (record.strategy == strategy and record.first_sequence == first_sequence) return record;
        return null;
    }

    pub fn owning(self: *const State, member: Member) ?Record {
        return self.owningForPortfolio(member, 0);
    }

    pub fn owningForPortfolio(self: *const State, member: Member, portfolio: u128) ?Record {
        for (self.records[0..self.count]) |record| {
            if (portfolio != 0 and record.portfolio != portfolio) continue;
            for (record.members[0..record.count]) |occupied|
                if (std.meta.eql(occupied, member)) return record;
        }
        return null;
    }

    pub fn checkAvailable(self: *const State, members: []const Member) !void {
        return self.checkAvailableForPortfolio(members, 0);
    }

    pub fn checkAvailableForPortfolio(self: *const State, members: []const Member, portfolio: u128) !void {
        if (members.len == 0 or members.len > max_members) return error.InvalidCycleMembers;
        if (@as(usize, self.count) + self.closed_count >= max_cycles) return error.CycleCapacity;
        for (members, 0..) |member, index| {
            if (member.account == 0 or member.instrument == 0) return error.InvalidCycleMembers;
            for (members[0..index]) |prior| if (std.meta.eql(prior, member)) return error.InvalidCycleMembers;
            for (self.records[0..self.count]) |record| {
                if (portfolio != 0 and record.portfolio != portfolio) continue;
                for (record.members[0..record.count]) |occupied|
                    if (std.meta.eql(occupied, member)) return error.InstrumentOccupied;
            }
        }
    }

    pub fn establish(self: *State, record: Record) !void {
        if (record.strategy == 0 or record.first_sequence == 0 or record.portfolio == 0 or record.fact_sequence == 0 or record.count > max_members or
            std.mem.allEqual(u8, &record.configuration_digest, 0) or std.mem.allEqual(u8, &record.content_digest, 0)) return error.InvalidCycle;
        if (self.find(record.strategy, record.first_sequence) != null) return error.ConflictingCycle;
        if (self.completed(record.strategy, record.first_sequence) != null) return error.ConflictingCycle;
        try self.checkAvailableForPortfolio(record.members[0..record.count], record.portfolio);
        self.records[self.count] = record;
        self.count += 1;
    }

    pub fn validate(self: *const State) !void {
        try self.residual_lifecycle.validate();
        var residual_count: usize = 0;
        for (self.closed[0..self.closed_count]) |entry| for (entry.proof.residuals) |maybe| if (maybe != null) {
            residual_count += 1;
        };
        if (residual_count != self.residual_lifecycle.live_count) return error.InvalidCycle;
        if (@as(usize, self.count) + self.closed_count > max_cycles) return error.InvalidCycle;
        if (self.residual_rule_count > max_residual_rules) return error.InvalidCycle;
        for (self.residual_rules[0..self.residual_rule_count], 0..) |rule, index| {
            try rule.validate();
            if (self.residual_rule_barriers[index] == 0) return error.InvalidCycle;
            for (self.residual_rules[0..index]) |prior| if (prior.asset == rule.asset) return error.InvalidCycle;
        }
        var previous: State = .{};
        for (self.records[0..self.count]) |record| try previous.establish(record);
        for (self.closed[0..self.closed_count], 0..) |entry, index| {
            var isolated: State = .{};
            try isolated.establish(entry.record);
            if (entry.proof.strategy == 0 or entry.proof.first_sequence == 0 or entry.fact_sequence == 0 or
                entry.fact_sequence <= entry.record.fact_sequence or entry.proof.strategy != entry.record.strategy or
                entry.proof.first_sequence != entry.record.first_sequence or
                !std.mem.eql(u8, &entry.proof.content_digest, &entry.record.content_digest)) return error.InvalidCycle;
            for (entry.proof.reconciliation_roots) |root| if (std.mem.allEqual(u8, &root, 0)) return error.InvalidCycle;
            for (entry.proof.residuals, 0..) |maybe, member_index| if (maybe) |residual| {
                try residual.rule.validate();
                if (residual.account != entry.record.members[member_index].account or residual.instrument != entry.record.members[member_index].instrument or
                    residual.portfolio != entry.record.portfolio or residual.asset != residual.rule.asset or residual.atoms <= 0 or
                    residual.atoms > residual.rule.max_atoms or residual.atoms >= residual.base_atoms_per_lot or
                    residual.accepted_at_utc_ns == 0 or residual.instrument_version == 0 or residual.rule_fact_sequence == 0 or
                    residual.rule_fact_sequence >= entry.fact_sequence or
                    std.mem.allEqual(u8, &residual.economic_digest, 0)) return error.InvalidCycle;
                const active_rule = self.residualRule(residual.asset) orelse return error.InvalidCycle;
                if (active_rule.version < residual.rule.version or active_rule.asset_version < residual.rule.asset_version or
                    (active_rule.version == residual.rule.version and !std.meta.eql(active_rule, residual.rule))) return error.InvalidCycle;
                const live = self.residual_lifecycle.find(entry.record.strategy, entry.record.first_sequence, @intCast(member_index)) orelse return error.InvalidCycle;
                if (live.original_atoms != residual.atoms or live.original_fact != entry.fact_sequence or live.account != residual.account or live.portfolio != residual.portfolio or live.asset != residual.asset or live.instrument != residual.instrument) return error.InvalidCycle;
            };
            if (self.find(entry.proof.strategy, entry.proof.first_sequence) != null) return error.InvalidCycle;
            for (self.closed[0..index]) |prior|
                if (prior.proof.strategy == entry.proof.strategy and prior.proof.first_sequence == entry.proof.first_sequence) return error.InvalidCycle;
        }
    }
};

test "09a cycle capacity reserves terminal identities and never evicts occupied members" {
    var state: State = .{};
    for (0..max_cycles) |index| try state.establish(.{
        .strategy = 1,
        .first_sequence = index + 1,
        .portfolio = 1,
        .configuration_digest = @splat(1),
        .content_digest = @splat(2),
        .fact_sequence = index + 1,
        .members = .{ .{ .account = 1, .instrument = index * 2 + 1 }, .{ .account = 2, .instrument = index * 2 + 2 } },
        .count = 2,
    });
    const extra = [_]Member{.{ .account = 3, .instrument = 999 }};
    try std.testing.expectError(error.CycleCapacity, state.checkAvailable(&extra));
    try std.testing.expectEqual(@as(u8, 64), state.count);
    for (0..max_cycles) |index| {
        const proof: Closure = .{ .strategy = 1, .first_sequence = index + 1, .content_digest = @splat(2), .reconciliation_roots = @splat(@splat(3)) };
        try state.close(proof, 100 + index);
        try state.close(proof, 100 + index);
        try std.testing.expect(state.owning(.{ .account = 1, .instrument = index * 2 + 1 }) == null);
    }
    try state.validate();
    try std.testing.expectEqual(@as(u8, 0), state.count);
    try std.testing.expectEqual(@as(u8, 64), state.closed_count);
    try std.testing.expectError(error.CycleCapacity, state.checkAvailable(&extra));
    var conflict = state.closed[0].proof;
    conflict.reconciliation_roots[0][0] ^= 1;
    try std.testing.expectError(error.ConflictingCycleClosure, state.close(conflict, 200));
}

test "09a residual rules are bounded and changed versions cannot replace equal identities" {
    var state: State = .{};
    for (0..max_residual_rules) |index| try std.testing.expect(try state.configureResidual(.{
        .asset = index + 1,
        .asset_version = 1,
        .version = 1,
        .max_atoms = 1,
        .max_total_atoms = 2,
    }, index + 1));
    var rule = state.residual_rules[0];
    try std.testing.expect(!try state.configureResidual(rule, 100));
    rule.max_atoms = 2;
    try std.testing.expectError(error.ResidualRuleConflict, state.configureResidual(rule, 100));
    rule.version = 2;
    try std.testing.expect(try state.configureResidual(rule, 100));
    rule.asset = max_residual_rules + 1;
    try std.testing.expectError(error.ResidualRuleCapacity, state.configureResidual(rule, 100));
    try state.validate();
}
