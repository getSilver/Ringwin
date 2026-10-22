const std = @import("std");
pub const max_cycles = 64;
pub const max_members = 2;
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
};
pub const Closed = struct {
    record: Record,
    proof: Closure,
    fact_sequence: u64,
};
pub const State = struct {
    records: [max_cycles]Record = @splat(.{}),
    count: u8 = 0,
    // shortcut: completed identities remain resident; add authenticated archival before exceeding 64 closures.
    closed: [max_cycles]Closed = @splat(std.mem.zeroes(Closed)),
    closed_count: u8 = 0,

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
        for (self.records[0..self.count]) |record| for (record.members[0..record.count]) |occupied|
            if (std.meta.eql(occupied, member)) return record;
        return null;
    }

    pub fn checkAvailable(self: *const State, members: []const Member) !void {
        if (members.len == 0 or members.len > max_members) return error.InvalidCycleMembers;
        if (@as(usize, self.count) + self.closed_count >= max_cycles) return error.CycleCapacity;
        for (members, 0..) |member, index| {
            if (member.account == 0 or member.instrument == 0) return error.InvalidCycleMembers;
            for (members[0..index]) |prior| if (std.meta.eql(prior, member)) return error.InvalidCycleMembers;
            for (self.records[0..self.count]) |record| for (record.members[0..record.count]) |occupied|
                if (std.meta.eql(occupied, member)) return error.InstrumentOccupied;
        }
    }

    pub fn establish(self: *State, record: Record) !void {
        if (record.strategy == 0 or record.first_sequence == 0 or record.portfolio == 0 or record.fact_sequence == 0 or record.count > max_members or
            std.mem.allEqual(u8, &record.configuration_digest, 0) or std.mem.allEqual(u8, &record.content_digest, 0)) return error.InvalidCycle;
        if (self.find(record.strategy, record.first_sequence) != null) return error.ConflictingCycle;
        if (self.completed(record.strategy, record.first_sequence) != null) return error.ConflictingCycle;
        try self.checkAvailable(record.members[0..record.count]);
        self.records[self.count] = record;
        self.count += 1;
    }

    pub fn validate(self: *const State) !void {
        if (@as(usize, self.count) + self.closed_count > max_cycles) return error.InvalidCycle;
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
