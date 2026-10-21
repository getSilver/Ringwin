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
pub const State = struct {
    records: [max_cycles]Record = @splat(.{}),
    count: u8 = 0,

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
        if (self.count >= max_cycles) return error.CycleCapacity;
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
        try self.checkAvailable(record.members[0..record.count]);
        self.records[self.count] = record;
        self.count += 1;
    }

    pub fn validate(self: *const State) !void {
        if (self.count > max_cycles) return error.InvalidCycle;
        var previous: State = .{};
        for (self.records[0..self.count]) |record| try previous.establish(record);
    }
};
