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

/// Fixed-capacity owner of cross-shard leases and account reconciliation only.
pub const AccountCoordinator = struct {
    exchange_account: u128,
    account_safety_ceiling_micros: i64,
    global_ceiling_micros: i64,
    barrier: u64 = 0,
    summaries: [max_shards]SummaryRecord = @splat(.{}),

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
};

test "shared account protocol rejects conflicting shard summaries" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    const summary = ShardSummary.fixture(.shard_0, 1, 100);
    _ = try coordinator.publishSummary(1, summary);
    var conflict = summary;
    conflict.reservation_micros += 1;
    try std.testing.expectError(error.SummaryIdentityConflict, coordinator.publishSummary(1, conflict));
}
