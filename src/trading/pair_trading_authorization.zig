//! Core-owned, bounded approval of an observed pair. Approval is not send permission.
const std = @import("std");
const deployment = @import("deployment_allocation.zig");
const oms = @import("../execution/oms.zig");
pub const Mode = enum(u8) { taker_taker, maker_first, maker_second };
pub const Leg = struct {
    venue: u64,
    environment: deployment.Environment,
    account: u128,
    instrument: u128,
    rules_version: u32,
};
pub const Request = struct {
    identity: u128,
    strategy: u128,
    portfolio: u128,
    activation: u128,
    config_version: u64,
    expected_version: u64,
    legs: [2]Leg,
    direction: i8,
    mode: Mode,
    enabled: bool,
};
pub const Record = struct { request: Request, version: u64, barrier: u64 };
pub const Revocation = struct { identity: u128, strategy: u128, portfolio: u128 };
pub const RevocationReceipt = struct { version: u64, barrier: u64 };
pub const max_history = 256;
// Each approval reserves its own receipt slot, keyed by its immutable history index.
pub const Revocations = [max_history]?RevocationReceipt;

pub const State = struct {
    records: [max_history]Record = std.mem.zeroes([max_history]Record),
    count: u16 = 0,
    version: u64 = 0,

    pub fn receipt(self: *const State, identity: u128) ?Record {
        return self.records[self.historyIndex(identity) orelse return null];
    }

    pub fn historyIndex(self: *const State, identity: u128) ?usize {
        for (self.records[0..self.count], 0..) |record, index|
            if (record.request.identity == identity) return index;
        return null;
    }

    pub fn validate(self: *const State, revocations: ?*const Revocations) !void {
        if (self.count > self.records.len or self.version > 2 * max_history) return error.InvalidPairAuthorizationState;
        var versions: std.StaticBitSet(2 * max_history) = .initEmpty();
        var previous_version: u64 = 0;
        for (self.records[0..self.count], 0..) |record, index| {
            if (record.version <= previous_version or record.version > self.version or record.barrier == 0 or
                record.request.expected_version != record.version - 1) return error.InvalidPairAuthorizationState;
            previous_version = record.version;
            const version: usize = @intCast(record.version - 1);
            if (versions.isSet(version)) return error.InvalidPairAuthorizationState;
            versions.set(version);
            try validateRequest(record.request);
            for (self.records[0..index]) |previous| if (previous.request.identity == record.request.identity)
                return error.InvalidPairAuthorizationState;
            if (revocations) |receipts| if (receipts[index]) |revoked| {
                if (!record.request.enabled or revoked.version <= record.version or revoked.version > self.version or
                    revoked.barrier <= record.barrier) return error.InvalidPairAuthorizationState;
                const revoked_version: usize = @intCast(revoked.version - 1);
                if (versions.isSet(revoked_version)) return error.InvalidPairAuthorizationState;
                versions.set(revoked_version);
            };
        }
        if (revocations) |receipts| for (receipts[self.count..]) |revoked| {
            if (revoked != null) return error.InvalidPairAuthorizationState;
        };
        if (versions.count() != self.version) return error.InvalidPairAuthorizationState;
    }

    pub fn append(self: *State, request: Request, barrier: u64) !bool {
        try validateRequest(request);
        if (self.receipt(request.identity)) |previous| {
            if (!std.meta.eql(previous.request, request)) return error.PairAuthorizationIdentityConflict;
            return false;
        }
        if (request.expected_version != self.version) return error.PairAuthorizationVersionConflict;
        if (self.count == self.records.len) return error.PairAuthorizationCapacity;
        self.records[self.count] = .{ .request = request, .version = self.version + 1, .barrier = barrier };
        self.count += 1;
        self.version += 1;
        return true;
    }

    pub fn hasHistory(self: *const State, strategy: u128) bool {
        for (self.records[0..self.count]) |record| if (record.request.strategy == strategy) return true;
        return false;
    }

    pub fn isCurrent(self: *const State, index: usize, revocations: ?*const Revocations) bool {
        const request = self.records[index].request;
        if (!request.enabled) return false;
        if (revocations) |receipts| if (receipts[index] != null) return false;
        for (self.records[index + 1 .. self.count]) |later| if (sameSelector(request, later.request)) return false;
        return true;
    }

    pub fn allowedRequest(self: *const State, group: oms.IntentGroup, config_version: u64, revocations: ?*const Revocations) ?Request {
        if (group.count == 0 or group.count > 2) return null;
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            const request = self.records[i].request;
            if (request.strategy != group.members[0].strategy_instance or request.portfolio != group.members[0].portfolio or
                request.config_version != config_version) continue;
            if (!self.isCurrent(i, revocations)) continue;
            var matched = true;
            for (group.members[0..group.count]) |member| {
                const leg: usize = if (member.exchange_account == request.legs[0].account and member.instrument == request.legs[0].instrument) 0 else if (member.exchange_account == request.legs[1].account and member.instrument == request.legs[1].instrument) 1 else {
                    matched = false;
                    break;
                };
                const buy = (leg == 0) == (request.direction == 1);
                const maker = (request.mode == .maker_first and leg == 0) or (request.mode == .maker_second and leg == 1);
                if (member.operation != .place or member.portfolio_reduce_only or
                    member.side != (if (buy) oms.Side.buy else oms.Side.sell) or
                    (maker and member.order_type != .post_only) or
                    (!maker and (member.order_type != .limit or member.time_in_force != .immediate_or_cancel))) matched = false;
            }
            if (group.count == 1 and request.mode == .taker_taker) matched = false;
            if (matched) return request;
        }
        return null;
    }

    pub fn allowedAmendment(self: *const State, intent: oms.Intent, members: []const @import("cycle_occupancy.zig").Member, config_version: u64, revocations: ?*const Revocations) ?Request {
        if (members.len != 2) return null;
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            const request = self.records[i].request;
            if (!request.enabled or request.strategy != intent.strategy_instance or request.portfolio != intent.portfolio or request.config_version != config_version) continue;
            if (!self.isCurrent(i, revocations)) continue;
            var matches_cycle = true;
            for (request.legs) |leg| {
                var found = false;
                for (members) |member| if (member.account == leg.account and member.instrument == leg.instrument) {
                    found = true;
                    break;
                };
                if (!found) matches_cycle = false;
            }
            if (!matches_cycle) continue;
            for (request.legs, 0..) |leg, index| {
                if (leg.account != intent.exchange_account or leg.instrument != intent.instrument) continue;
                const buy = (index == 0) == (request.direction == 1);
                const maker = (request.mode == .maker_first and index == 0) or (request.mode == .maker_second and index == 1);
                if (intent.side != (if (buy) oms.Side.buy else oms.Side.sell)) continue;
                if ((maker and intent.order_type == .post_only) or (!maker and intent.order_type == .limit and intent.time_in_force == .immediate_or_cancel)) return request;
            }
        }
        return null;
    }
};

fn sameSelector(a: Request, b: Request) bool {
    return a.strategy == b.strategy and a.portfolio == b.portfolio and a.direction == b.direction and a.mode == b.mode and
        a.legs[0].account == b.legs[0].account and a.legs[1].account == b.legs[1].account and
        a.legs[0].instrument == b.legs[0].instrument and a.legs[1].instrument == b.legs[1].instrument;
}

pub fn validateRequest(request: Request) !void {
    if (request.identity == 0 or request.strategy == 0 or request.portfolio == 0 or request.activation == 0 or
        request.config_version == 0 or (request.direction != 1 and request.direction != -1) or
        request.legs[0].venue >= request.legs[1].venue or request.legs[0].account == request.legs[1].account or
        request.legs[0].instrument == request.legs[1].instrument)
        return error.InvalidPairAuthorization;
    for (request.legs) |leg| if (leg.venue == 0 or leg.account == 0 or leg.instrument == 0 or leg.rules_version == 0)
        return error.InvalidPairAuthorization;
}
