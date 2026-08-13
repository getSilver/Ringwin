const std = @import("std");
const trading = @import("trading_shard.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_shards = 4;

/// Stable identity of one of the four single-writer shards.
pub const ShardId = enum(u8) { shard_0, shard_1, shard_2, shard_3 };

/// Versioned publication containing only cross-account coordination inputs.
pub const ShardSummary = struct {
    shard_id: ShardId,
    decision_domain: u128,
    virtual_portfolio: u128,
    exchange_account: u128,
    shard_sequence: u64,
    rules_version: u32,
    lease_version: u64,
    reservation_micros: i64,
    spot_quantity: i64,
    swap_quantity: i64,
    cash_micros: i64,
    open_orders: u8,
    unknown_orders: u8,
    local_gate_closed: bool,

    fn fixture(shard_id: ShardId, sequence: u64, reservation: i64) ShardSummary {
        return .{
            .shard_id = shard_id,
            .decision_domain = @intFromEnum(shard_id) + 1,
            .virtual_portfolio = @intFromEnum(shard_id) + 11,
            .exchange_account = 900,
            .shard_sequence = sequence,
            .rules_version = 1,
            .lease_version = 1,
            .reservation_micros = reservation,
            .spot_quantity = 0,
            .swap_quantity = 0,
            .cash_micros = 1_000,
            .open_orders = 0,
            .unknown_orders = 0,
            .local_gate_closed = false,
        };
    }
};

const SummaryRecord = struct { identity: u128 = 0, value: ShardSummary = undefined, present: bool = false };

/// Versioned risk authority granted to one DecisionDomain.
pub const RiskLease = struct {
    identity: u128,
    exchange_account: u128,
    shard_id: ShardId,
    decision_domain: u128,
    version: u64,
    valid_through_barrier: u64,
    limit_micros: i64,
    used_micros: i64,
    open: bool,
};

/// Account-wide observations normalized once before deterministic fan-out.
pub const AccountFact = struct {
    identity: u128,
    exchange_account: u128,
    version: u64,
    barrier: u64,
    payload: union(enum) {
        account_snapshot: struct { cash_micros: i64, swap_quantity: i64, margin_micros: i64 },
        forced_execution: struct { owner: ?ShardId, quantity: i64, price_micros: i64, fee_micros: i64 },
    },
};

/// One target assignment; the target shard still applies the canonical fact.
pub const Delivery = struct { shard_id: ShardId, fact: AccountFact };

/// Fixed-capacity owner of cross-shard leases and account reconciliation only.
pub const AccountCoordinator = struct {
    exchange_account: u128,
    account_safety_ceiling_micros: i64,
    global_ceiling_micros: i64,
    barrier: u64 = 0,
    summaries: [max_shards]SummaryRecord = @splat(.{}),
    leases: [max_shards]RiskLease = undefined,
    lease_count: u8 = 0,
    account_netting_benefit_micros: i64 = 0,
    last_account_fact: ?AccountFact = null,
    deliveries: [max_shards]Delivery = undefined,

    /// Creates one coordinator for exactly one ExchangeAccount.
    pub fn init(exchange_account: u128, account_ceiling: i64, global_ceiling: i64) AccountCoordinator {
        return .{
            .exchange_account = exchange_account,
            .account_safety_ceiling_micros = account_ceiling,
            .global_ceiling_micros = global_ceiling,
        };
    }

    /// Publishes one semantic shard summary, accepting exact duplicates as no-op.
    pub fn publishSummary(self: *AccountCoordinator, identity: u128, summary: ShardSummary) !bool {
        if (identity == 0 or summary.decision_domain == 0 or summary.virtual_portfolio == 0 or
            summary.exchange_account != self.exchange_account or summary.shard_sequence == 0 or
            summary.rules_version == 0 or summary.reservation_micros < 0)
            return error.InvalidShardSummary;
        const index: usize = @intFromEnum(summary.shard_id);
        const known = &self.summaries[index];
        if (known.present) {
            if (identity == known.identity) {
                if (!std.meta.eql(known.value, summary)) return error.SummaryIdentityConflict;
                return false;
            }
            if (summary.shard_sequence <= known.value.shard_sequence) return error.StaleShardSummary;
        }
        known.* = .{ .identity = identity, .value = summary, .present = true };
        self.barrier += 1;
        return true;
    }

    /// Computes a stable digest of coordination-owned state only.
    pub fn digest(self: *const AccountCoordinator) [Sha256.digest_length]u8 {
        var hasher = Sha256.init(.{});
        hasher.update(std.mem.asBytes(&self.exchange_account));
        hasher.update(std.mem.asBytes(&self.account_safety_ceiling_micros));
        hasher.update(std.mem.asBytes(&self.global_ceiling_micros));
        hasher.update(std.mem.asBytes(&self.barrier));
        for (self.summaries) |record| {
            hasher.update(&.{@intFromBool(record.present)});
            if (record.present) {
                hasher.update(std.mem.asBytes(&record.identity));
                inline for (@typeInfo(ShardSummary).@"struct".fields) |field|
                    hasher.update(std.mem.asBytes(&@field(record.value, field.name)));
            }
        }
        var result: [Sha256.digest_length]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    /// Returns the non-netted sum of all published Portfolio reservations.
    pub fn grossPortfolioMargin(self: *const AccountCoordinator) i64 {
        var total: i64 = 0;
        for (self.summaries) |record| {
            if (record.present) total += record.value.reservation_micros;
        }
        return total;
    }

    /// Allocates deterministic leases without turning account netting into buying power.
    pub fn allocateLeases(self: *AccountCoordinator, version: u64, valid_through_barrier: u64) ![]const RiskLease {
        if (version == 0 or valid_through_barrier < self.barrier) return error.InvalidRiskLease;
        for (self.summaries) |record| if (!record.present) return error.IncompleteShardSummaries;
        const gross = self.grossPortfolioMargin();
        const ceiling = @min(self.account_safety_ceiling_micros, self.global_ceiling_micros);
        if (gross > ceiling or ceiling <= 0) return error.AccountSafetyCeilingExceeded;
        const base = @divFloor(ceiling, max_shards);
        const remainder = @mod(ceiling, max_shards);
        self.lease_count = max_shards;
        for (&self.leases, 0..) |*lease, index| {
            const summary = self.summaries[index].value;
            const limit = base + @as(i64, if (index < remainder) 1 else 0);
            if (summary.reservation_micros > limit) return error.RiskLeaseOversubscribed;
            lease.* = .{
                .identity = (@as(u128, version) << 64) | index + 1,
                .exchange_account = self.exchange_account,
                .shard_id = @enumFromInt(index),
                .decision_domain = summary.decision_domain,
                .version = version,
                .valid_through_barrier = valid_through_barrier,
                .limit_micros = limit,
                .used_micros = summary.reservation_micros,
                .open = true,
            };
        }
        return self.leases[0..self.lease_count];
    }

    /// Normalizes one account fact and returns its stable per-shard routing plan.
    pub fn acceptAccountFact(self: *AccountCoordinator, fact: AccountFact) ![]const Delivery {
        if (fact.identity == 0 or fact.exchange_account != self.exchange_account or fact.version == 0 or fact.barrier == 0)
            return error.InvalidAccountFact;
        if (self.last_account_fact) |known| {
            if (fact.identity == known.identity) {
                if (!std.meta.eql(known, fact)) return error.AccountFactIdentityConflict;
                return self.deliveries[0..0];
            }
            if (fact.barrier <= known.barrier) return error.StaleAccountFact;
        }
        self.last_account_fact = fact;
        const count: usize = switch (fact.payload) {
            .account_snapshot => max_shards,
            .forced_execution => |forced| if (forced.owner == null) max_shards else 1,
        };
        if (fact.payload == .forced_execution and fact.payload.forced_execution.owner != null) {
            self.deliveries[0] = .{ .shard_id = fact.payload.forced_execution.owner.?, .fact = fact };
        } else {
            for (self.deliveries[0..count], 0..) |*delivery, index|
                delivery.* = .{ .shard_id = @enumFromInt(index), .fact = fact };
        }
        return self.deliveries[0..count];
    }
};

test "shared account protocol rejects conflicting shard summaries" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    const summary = ShardSummary.fixture(.shard_0, 1, 100);
    _ = try coordinator.publishSummary(1, summary);
    var conflict = summary;
    conflict.reservation_micros += 1;
    try std.testing.expectError(error.SummaryIdentityConflict, coordinator.publishSummary(1, conflict));
}

test "risk leases allocate from gross reservations without netting benefit" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    for (0..max_shards) |index| {
        var summary = ShardSummary.fixture(@enumFromInt(index), 1, 100);
        summary.swap_quantity = if (index % 2 == 0) 5 else -5;
        _ = try coordinator.publishSummary(index + 1, summary);
    }
    const leases = try coordinator.allocateLeases(1, 10);
    try std.testing.expectEqual(@as(i64, 400), coordinator.grossPortfolioMargin());
    var total: i64 = 0;
    for (leases) |lease| total += lease.limit_micros;
    try std.testing.expectEqual(@as(i64, 1_000), total);
    try std.testing.expectEqual(@as(i64, 0), coordinator.account_netting_benefit_micros);
}

test "account facts fan out once in stable shard order" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    const deliveries = try coordinator.acceptAccountFact(.{
        .identity = 7,
        .exchange_account = 900,
        .version = 1,
        .barrier = 1,
        .payload = .{ .account_snapshot = .{ .cash_micros = 800, .swap_quantity = 0, .margin_micros = 100 } },
    });
    try std.testing.expectEqual(@as(usize, 4), deliveries.len);
    for (deliveries, 0..) |delivery, index| try std.testing.expectEqual(@as(ShardId, @enumFromInt(index)), delivery.shard_id);
    try std.testing.expectEqual(@as(usize, 0), (try coordinator.acceptAccountFact(.{
        .identity = 7,
        .exchange_account = 900,
        .version = 1,
        .barrier = 1,
        .payload = .{ .account_snapshot = .{ .cash_micros = 800, .swap_quantity = 0, .margin_micros = 100 } },
    })).len);
}
