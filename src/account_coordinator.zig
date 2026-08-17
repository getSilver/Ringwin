const std = @import("std");
const trading = @import("trading_shard.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const snapshot_magic: u64 = 0x54434341574e4952;
const account_margin_gate_identity: u128 = 0x414343544d415247;

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
    spot_margin_micros: i64 = 0,
    exchange_margin_micros: i64 = 0,
    risk_tier: u8 = 0,
    liquidation_distance_ticks: i64 = std.math.maxInt(i64),

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

    fn withSequence(self: ShardSummary, sequence: u64) ShardSummary {
        var result = self;
        result.shard_sequence = sequence;
        return result;
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
pub const AccountFactPayload = union(enum) {
    account_snapshot: struct { cash_micros: i64, spot_quantity: i64 = 0, swap_quantity: i64, margin_micros: i64 },
    forced_execution: struct { owner: ?ShardId, quantity: i64, price_micros: i64, fee_micros: i64 },
};

/// Account-wide observations normalized once before deterministic fan-out.
pub const AccountFact = struct {
    identity: u128,
    exchange_account: u128,
    version: u64,
    barrier: u64,
    payload: AccountFactPayload,
};

/// One target assignment; the target shard still applies the canonical fact.
pub const Delivery = struct { shard_id: ShardId, fact: AccountFact };

/// Venue account-margin evidence used only for reconciliation.
pub const MarginObservation = struct {
    identity: u128,
    barrier: u64,
    venue_net_margin_micros: i64,
    venue_swap_quantity: i64,
    venue_spot_margin_micros: i64 = 0,
    venue_swap_margin_micros: i64 = 0,
    margin_mode: enum(u8) { isolated },
    rules_version: u32,
    venue_risk_tier: u8 = 0,
    venue_liquidation_distance_ticks: i64 = std.math.maxInt(i64),
};

/// Account-level authority result that every affected shard must consume.
pub const AccountGate = struct { identity: u128, open: bool, latched: bool };
/// One account-wide gate delivery to a specific shard.
pub const GateDelivery = struct { shard_id: ShardId, gate: AccountGate };

/// Converts one routed account fact into the target shard's stable event seam.
pub fn accountFactEvent(delivery: Delivery) !trading.CanonicalEvent {
    const identity = std.math.cast(u64, delivery.fact.identity) orelse return error.IdentityOutOfRange;
    return .{
        .identity = identity,
        .payload = switch (delivery.fact.payload) {
            .account_snapshot => |snapshot| .{ .economic_account_snapshot = .{
                .snapshot_id = identity,
                .usdt_balance_micros = snapshot.cash_micros,
                .spot_asset_quantity = snapshot.spot_quantity,
                .swap_position_quantity = snapshot.swap_quantity,
                .margin_micros = snapshot.margin_micros,
            } },
            .forced_execution => |execution| .{ .venue_forced_execution = .{
                .execution_id = identity,
                .side = if (execution.quantity < 0) .sell else .buy,
                .quantity = if (execution.quantity == std.math.minInt(i64))
                    return error.InvalidAccountFact
                else
                    @intCast(@abs(execution.quantity)),
                .price_micros = execution.price_micros,
                .fee_micros = execution.fee_micros,
            } },
        },
    };
}

/// Converts one lease grant into the existing shard risk-lease event.
pub fn riskLeaseEvent(lease: RiskLease) !trading.CanonicalEvent {
    const identity = std.math.cast(u64, lease.identity) orelse return error.IdentityOutOfRange;
    return .{ .identity = identity, .payload = .{ .risk_lease_granted = .{
        .lease_identity = identity,
        .version = lease.version,
        .valid_through_barrier = lease.valid_through_barrier,
        .open = lease.open,
        .amount_micros = if (lease.open) lease.limit_micros else 0,
        .strategy_limit_micros = if (lease.open) lease.limit_micros else 0,
        .portfolio_limit_micros = if (lease.open) lease.limit_micros else 0,
        .exchange_account_limit_micros = if (lease.open) lease.limit_micros else 0,
        .global_limit_micros = if (lease.open) lease.limit_micros else 0,
    } } };
}

/// Converts one account-wide restriction into a shard-local stable gate fact.
pub fn accountGateEvent(delivery: GateDelivery, target_identity: u128) !trading.CanonicalEvent {
    const identity = std.math.cast(u64, delivery.gate.identity) orelse return error.IdentityOutOfRange;
    return .{ .identity = identity, .payload = .{ .safety_gate_change = .{
        .gate_identity = delivery.gate.identity,
        .target_identity = target_identity,
        .kind = .latched,
        .reason = .reconciliation_break,
        .open = delivery.gate.open,
    } } };
}

/// Durably applies one routed account fact through the shard's transactional seam.
pub fn applyAccountFactStable(delivery: Delivery, target_shard_id: ShardId, shard: *trading.TradingShard, stable_journal: *trading.journal.Journal) !void {
    if (delivery.shard_id != target_shard_id) return error.CrossShardDelivery;
    _ = try trading.applyStable(shard, stable_journal, try accountFactEvent(delivery));
}

/// Durably applies one account restriction through the shard's transactional seam.
pub fn applyAccountGateStable(delivery: GateDelivery, target_shard_id: ShardId, shard: *trading.TradingShard, stable_journal: *trading.journal.Journal) !void {
    if (delivery.shard_id != target_shard_id) return error.CrossShardDelivery;
    _ = try trading.applyStable(shard, stable_journal, try accountGateEvent(delivery, shard.operational_state.target_identity));
}

/// One qualified command submitted through the shared transport periphery.
pub const GatewayRequest = struct {
    exchange_account: u128,
    shard_id: ShardId,
    fencing_token: u64,
    command: trading.oms.Command,
};

/// Stable owner key assigned by the gateway without owning OMS state.
pub const GatewayReceipt = struct { shard_id: ShardId, command_id: u64 };

/// One itemized transport outcome routed to its sole owner.
pub const GatewayOutcome = struct {
    exchange_account: u128,
    shard_id: ShardId,
    command_id: u64,
    order_id: u64,
    revision: u32,
    fencing_token: u64,
    state: trading.oms.DispatchState,
};

const GatewayRecord = struct { exchange_account: u128, shard_id: ShardId, command_id: u64, order_id: u64, revision: u32, fencing_token: u64 };

/// Fixed-capacity shared sender that owns routing and transport attempts only.
pub const SharedExecutionGateway = struct {
    exchange_account: u128 = 0,
    records: [32]GatewayRecord = undefined,
    count: u8 = 0,
    latest_fencing_tokens: [max_shards]u64 = @splat(0),

    /// Admits one uniquely owned command before the transport send attempt.
    pub fn submit(self: *SharedExecutionGateway, request: GatewayRequest) !GatewayReceipt {
        if (request.exchange_account == 0 or request.fencing_token == 0 or request.command.command_id == 0 or
            request.command.order_id == 0 or request.command.revision == 0)
            return error.InvalidGatewayRequest;
        if (self.exchange_account != 0 and request.exchange_account != self.exchange_account)
            return error.CrossAccountGatewayRequest;
        const shard_index: usize = @intFromEnum(request.shard_id);
        if (request.fencing_token < self.latest_fencing_tokens[shard_index]) return error.StaleFencingToken;
        for (self.records[0..self.count]) |known| {
            if (known.shard_id == request.shard_id and known.command_id == request.command.command_id)
                return error.DuplicateCommandIdentity;
        }
        if (self.count == self.records.len) return error.GatewayCapacityExceeded;
        if (self.exchange_account == 0) self.exchange_account = request.exchange_account;
        self.latest_fencing_tokens[shard_index] = request.fencing_token;
        self.records[self.count] = .{
            .exchange_account = request.exchange_account,
            .shard_id = request.shard_id,
            .command_id = request.command.command_id,
            .order_id = request.command.order_id,
            .revision = request.command.revision,
            .fencing_token = request.fencing_token,
        };
        self.count += 1;
        return .{ .shard_id = request.shard_id, .command_id = request.command.command_id };
    }

    /// Routes an itemized result only when its owner and command identity match.
    pub fn complete(self: *const SharedExecutionGateway, outcome: GatewayOutcome) !GatewayOutcome {
        for (self.records[0..self.count]) |known| {
            if (known.command_id == outcome.command_id and known.shard_id == outcome.shard_id) {
                if (known.exchange_account != outcome.exchange_account or known.order_id != outcome.order_id or
                    known.revision != outcome.revision or known.fencing_token != outcome.fencing_token)
                    return error.GatewayOutcomeIdentityConflict;
                return outcome;
            }
        }
        return error.UnknownGatewayCommand;
    }

    /// Converts an itemized transport outcome into the owning OMS apply seam.
    pub fn outcomeEvent(self: *const SharedExecutionGateway, outcome: GatewayOutcome) !trading.CanonicalEvent {
        _ = try self.complete(outcome);
        var items: [trading.oms.max_commands]trading.oms.DispatchItem = undefined;
        items[0] = .{ .command_id = outcome.command_id, .state = outcome.state };
        return .{ .identity = outcome.command_id, .payload = .{ .oms_dispatch_batch = .{ .items = items, .count = 1 } } };
    }

    /// Durably applies one transport outcome only to its exact owning shard.
    pub fn applyOutcomeStable(
        self: *const SharedExecutionGateway,
        outcome: GatewayOutcome,
        target_shard_id: ShardId,
        shard: *trading.TradingShard,
        stable_journal: *trading.journal.Journal,
    ) !void {
        if (outcome.shard_id != target_shard_id) return error.CrossShardDelivery;
        _ = try trading.applyStable(shard, stable_journal, try self.outcomeEvent(outcome));
    }
};

fn commandFixture(command_id: u64, order_id: u64) trading.oms.Command {
    return .{
        .command_id = command_id,
        .order_id = order_id,
        .strategy_instance = 1,
        .revision = 1,
        .operation = .place,
        .instrument = .btc_usdt_swap,
        .side = .buy,
        .portfolio_reduce_only = false,
        .venue_reduce_only = false,
        .quantity = 1,
        .limit_price_micros = 1,
        .reservation_micros = 1,
    };
}

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
    last_margin_observation: ?MarginObservation = null,
    margin_gate: AccountGate = .{ .identity = 0, .open = false, .latched = false },
    gate_deliveries: [max_shards]GateDelivery = undefined,
    recovery_only: bool = false,
    recovery_margin_identity: u128 = 0,

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
            if (summary.shard_sequence != known.value.shard_sequence + 1) return error.ShardSequenceGap;
            if (summary.decision_domain != known.value.decision_domain or
                summary.virtual_portfolio != known.value.virtual_portfolio or
                summary.exchange_account != known.value.exchange_account)
                return error.ShardIdentityDrift;
        } else if (summary.shard_sequence != 1) {
            return error.ShardSequenceGap;
        }
        const next_barrier = try std.math.add(u64, self.barrier, 1);
        known.* = .{ .identity = identity, .value = summary, .present = true };
        self.barrier = next_barrier;
        return true;
    }

    /// Computes a stable digest of coordination-owned state only.
    pub fn digest(self: *const AccountCoordinator) [Sha256.digest_length]u8 {
        var hasher = Sha256.init(.{});
        digestInt(&hasher, u128, self.exchange_account);
        digestInt(&hasher, i64, self.account_safety_ceiling_micros);
        digestInt(&hasher, i64, self.global_ceiling_micros);
        digestInt(&hasher, u64, self.barrier);
        for (self.summaries) |record| {
            hasher.update(&.{@intFromBool(record.present)});
            if (record.present) {
                digestInt(&hasher, u128, record.identity);
                digestStruct(&hasher, ShardSummary, record.value);
            }
        }
        digestInt(&hasher, u8, self.lease_count);
        for (self.leases[0..self.lease_count]) |lease| digestStruct(&hasher, RiskLease, lease);
        digestInt(&hasher, i64, self.account_netting_benefit_micros);
        hasher.update(&.{@intFromBool(self.recovery_only)});
        digestOptionalAccountFact(&hasher, self.last_account_fact);
        digestOptionalMarginObservation(&hasher, self.last_margin_observation);
        digestStruct(&hasher, AccountGate, self.margin_gate);
        var result: [Sha256.digest_length]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    /// Returns the non-netted sum of all published Portfolio reservations.
    pub fn grossPortfolioMargin(self: *const AccountCoordinator) !i64 {
        var total: i64 = 0;
        for (self.summaries) |record| {
            if (record.present) total = try std.math.add(i64, total, record.value.reservation_micros);
        }
        return total;
    }

    /// Allocates deterministic leases without turning account netting into buying power.
    pub fn allocateLeases(self: *AccountCoordinator, version: u64, valid_through_barrier: u64) ![]const RiskLease {
        if (self.recovery_only) return error.CoordinatorRecoveryOnly;
        if (version == 0 or valid_through_barrier < self.barrier) return error.InvalidRiskLease;
        for (self.summaries) |record| if (!record.present) return error.IncompleteShardSummaries;
        const gross = try self.grossPortfolioMargin();
        const ceiling = @min(self.account_safety_ceiling_micros, self.global_ceiling_micros);
        if (gross > ceiling or ceiling <= 0) return error.AccountSafetyCeilingExceeded;
        const base = @divFloor(ceiling, max_shards);
        const remainder = @mod(ceiling, max_shards);
        var candidate: [max_shards]RiskLease = undefined;
        for (&candidate, 0..) |*lease, index| {
            const summary = self.summaries[index].value;
            const limit = base + @as(i64, if (index < remainder) 1 else 0);
            if (summary.reservation_micros > limit) return error.RiskLeaseOversubscribed;
            lease.* = .{
                .identity = try std.math.add(u128, try std.math.mul(u128, version, max_shards), index + 1),
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
        if (self.lease_count != 0) {
            if (version < self.leases[0].version) return error.StaleRiskLease;
            if (version == self.leases[0].version) {
                if (!std.meta.eql(candidate, self.leases)) return error.RiskLeaseIdentityConflict;
                return self.leases[0..self.lease_count];
            }
        }
        self.leases = candidate;
        self.lease_count = max_shards;
        return self.leases[0..self.lease_count];
    }

    /// Closes every lease whose durable coordination barrier has expired.
    pub fn expireLeases(self: *AccountCoordinator, barrier: u64) !bool {
        var candidate = self.leases;
        var changed = false;
        for (candidate[0..self.lease_count], 0..) |*lease, index| {
            if (lease.open and barrier > lease.valid_through_barrier) {
                lease.version = try std.math.add(u64, lease.version, 1);
                lease.identity = try std.math.add(
                    u128,
                    try std.math.mul(u128, lease.version, max_shards),
                    index + 1,
                );
                lease.valid_through_barrier = barrier;
                lease.limit_micros = 0;
                lease.used_micros = 0;
                lease.open = false;
                changed = true;
            }
        }
        if (changed) self.leases = candidate;
        return changed;
    }

    /// Returns the stable close events that must be applied to every expired lease owner.
    pub fn expiredLeaseEvents(self: *const AccountCoordinator, events: *[max_shards]trading.CanonicalEvent) ![]const trading.CanonicalEvent {
        var count: usize = 0;
        for (self.leases[0..self.lease_count]) |lease| {
            if (lease.open) continue;
            events[count] = try riskLeaseEvent(lease);
            count += 1;
        }
        return events[0..count];
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
            if (fact.barrier != known.barrier + 1) return error.AccountFactBarrierGap;
        } else if (fact.barrier != 1) {
            return error.AccountFactBarrierGap;
        }
        self.last_account_fact = fact;
        const count: usize = switch (fact.payload) {
            .account_snapshot => max_shards,
            .forced_execution => 1,
        };
        switch (fact.payload) {
            .forced_execution => {
                // Unowned economics enter exactly one deterministic SuspenseAccount projection.
                self.deliveries[0] = .{ .shard_id = fact.payload.forced_execution.owner orelse .shard_0, .fact = fact };
            },
            .account_snapshot => {
                for (self.deliveries[0..count], 0..) |*delivery, index|
                    delivery.* = .{ .shard_id = @enumFromInt(index), .fact = fact };
            },
        }
        return self.deliveries[0..count];
    }

    /// Reconciles gross portfolio state with Venue net margin without allocating the difference.
    pub fn reconcileMargin(self: *AccountCoordinator, observation: MarginObservation) !AccountGate {
        if (observation.identity == 0 or observation.barrier < self.barrier or
            observation.venue_net_margin_micros < 0 or observation.rules_version == 0)
            return error.InvalidMarginObservation;
        if (self.last_margin_observation) |known| {
            if (observation.identity == known.identity) {
                if (!std.meta.eql(known, observation)) return error.MarginObservationIdentityConflict;
                return self.margin_gate;
            }
            if (observation.barrier <= known.barrier) return error.StaleMarginObservation;
        }
        var projected_quantity: i64 = 0;
        var projected_margin: i64 = 0;
        var projected_spot_margin: i64 = 0;
        var projected_risk_tier: u8 = 0;
        var projected_liquidation_distance: i64 = std.math.maxInt(i64);
        for (self.summaries) |record| {
            if (!record.present) return error.IncompleteShardSummaries;
            projected_quantity = try std.math.add(i64, projected_quantity, record.value.swap_quantity);
            projected_margin = try std.math.add(i64, projected_margin, record.value.exchange_margin_micros);
            projected_spot_margin = try std.math.add(i64, projected_spot_margin, record.value.spot_margin_micros);
            projected_risk_tier = @max(projected_risk_tier, record.value.risk_tier);
            projected_liquidation_distance = @min(projected_liquidation_distance, record.value.liquidation_distance_ticks);
        }
        const gross = try self.grossPortfolioMargin();
        self.account_netting_benefit_micros = @max(gross - observation.venue_net_margin_micros, 0);
        const closed = projected_quantity == observation.venue_swap_quantity and
            try std.math.add(i64, projected_spot_margin, projected_margin) == observation.venue_net_margin_micros and
            projected_spot_margin == observation.venue_spot_margin_micros and
            projected_margin == observation.venue_swap_margin_micros and
            projected_risk_tier == observation.venue_risk_tier and
            projected_liquidation_distance == observation.venue_liquidation_distance_ticks and
            observation.venue_net_margin_micros <= gross;
        self.last_margin_observation = observation;
        if (self.recovery_only) self.recovery_margin_identity = observation.identity;
        self.margin_gate = if (self.margin_gate.latched)
            .{ .identity = account_margin_gate_identity, .open = false, .latched = true }
        else
            .{ .identity = account_margin_gate_identity, .open = closed, .latched = !closed };
        return self.margin_gate;
    }

    /// Clears the account margin latch only after healthy evidence and explicit resolution.
    pub fn resolveMarginGate(self: *AccountCoordinator, observation_identity: u128) !AccountGate {
        const observation = self.last_margin_observation orelse return error.MarginObservationRequired;
        if (observation.identity != observation_identity) return error.MarginObservationIdentityConflict;
        var projected_quantity: i64 = 0;
        var projected_margin: i64 = 0;
        var projected_spot_margin: i64 = 0;
        var projected_risk_tier: u8 = 0;
        var projected_liquidation_distance: i64 = std.math.maxInt(i64);
        for (self.summaries) |record| {
            if (!record.present) return error.IncompleteShardSummaries;
            projected_quantity = try std.math.add(i64, projected_quantity, record.value.swap_quantity);
            projected_margin = try std.math.add(i64, projected_margin, record.value.exchange_margin_micros);
            projected_spot_margin = try std.math.add(i64, projected_spot_margin, record.value.spot_margin_micros);
            projected_risk_tier = @max(projected_risk_tier, record.value.risk_tier);
            projected_liquidation_distance = @min(projected_liquidation_distance, record.value.liquidation_distance_ticks);
        }
        if (projected_quantity != observation.venue_swap_quantity or
            try std.math.add(i64, projected_spot_margin, projected_margin) != observation.venue_net_margin_micros or
            projected_spot_margin != observation.venue_spot_margin_micros or
            projected_margin != observation.venue_swap_margin_micros or
            projected_risk_tier != observation.venue_risk_tier or
            projected_liquidation_distance != observation.venue_liquidation_distance_ticks or
            observation.venue_net_margin_micros > try self.grossPortfolioMargin())
            return error.MarginReconciliationStillBroken;
        self.margin_gate = .{ .identity = account_margin_gate_identity, .open = true, .latched = false };
        return self.margin_gate;
    }

    /// Produces a stable fan-out plan for an account-level authority restriction.
    pub fn accountGateDeliveries(self: *AccountCoordinator, gate: AccountGate) []const GateDelivery {
        for (&self.gate_deliveries, 0..) |*delivery, index|
            delivery.* = .{ .shard_id = @enumFromInt(index), .gate = gate };
        return &self.gate_deliveries;
    }

    /// Leaves RecoveryOnly only after current leases and account reconciliation are healthy.
    pub fn completeRecovery(self: *AccountCoordinator) !void {
        if (!self.recovery_only) return error.CoordinatorNotRecovering;
        if (self.recovery_margin_identity == 0) return error.FreshMarginObservationRequired;
        if (!self.margin_gate.open or self.margin_gate.latched) return error.MarginReconciliationRequired;
        if (self.lease_count != max_shards) return error.IncompleteRiskLeases;
        for (self.leases[0..self.lease_count]) |lease| {
            if (!lease.open) return error.RiskLeaseClosed;
            if (lease.valid_through_barrier < self.barrier) return error.RiskLeaseExpired;
        }
        self.recovery_only = false;
    }

    /// Encodes coordination-owned state at its exact barrier without shard internals.
    pub fn snapshot(self: *const AccountCoordinator, destination: []u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(destination);
        try writer.writeInt(u64, snapshot_magic, .little);
        try writer.writeInt(u16, 1, .little);
        try writer.writeInt(u128, self.exchange_account, .little);
        try writer.writeInt(i64, self.account_safety_ceiling_micros, .little);
        try writer.writeInt(i64, self.global_ceiling_micros, .little);
        try writer.writeInt(u64, self.barrier, .little);
        for (self.summaries) |record| {
            try writer.writeByte(@intFromBool(record.present));
            if (!record.present) continue;
            try writer.writeInt(u128, record.identity, .little);
            inline for (@typeInfo(ShardSummary).@"struct".fields) |field| {
                const value = @field(record.value, field.name);
                if (field.type == bool)
                    try writer.writeByte(@intFromBool(value))
                else if (@typeInfo(field.type) == .@"enum")
                    try writer.writeInt(@typeInfo(field.type).@"enum".tag_type, @intFromEnum(value), .little)
                else
                    try writer.writeInt(field.type, value, .little);
            }
        }
        try writer.writeInt(u8, self.lease_count, .little);
        for (self.leases[0..self.lease_count]) |lease| inline for (@typeInfo(RiskLease).@"struct".fields) |field| {
            const value = @field(lease, field.name);
            if (field.type == bool)
                try writer.writeByte(@intFromBool(value))
            else if (@typeInfo(field.type) == .@"enum")
                try writer.writeInt(@typeInfo(field.type).@"enum".tag_type, @intFromEnum(value), .little)
            else
                try writer.writeInt(field.type, value, .little);
        };
        try writer.writeInt(i64, self.account_netting_benefit_micros, .little);
        try writer.writeByte(@intFromBool(self.recovery_only));
        try writeOptionalAccountFact(&writer, self.last_account_fact);
        try writeOptionalMarginObservation(&writer, self.last_margin_observation);
        try writer.writeInt(u128, self.margin_gate.identity, .little);
        try writer.writeByte(@intFromBool(self.margin_gate.open));
        try writer.writeByte(@intFromBool(self.margin_gate.latched));
        const digest_value = self.digest();
        try writer.writeAll(&digest_value);
        return writer.buffered();
    }

    /// Restores a validated coordination snapshot into RecoveryOnly account authority.
    pub fn restore(encoded: []const u8) !AccountCoordinator {
        var reader: std.Io.Reader = .fixed(encoded);
        if (try reader.takeInt(u64, .little) != snapshot_magic or try reader.takeInt(u16, .little) != 1)
            return error.InvalidCoordinatorSnapshot;
        var result = AccountCoordinator.init(
            try reader.takeInt(u128, .little),
            try reader.takeInt(i64, .little),
            try reader.takeInt(i64, .little),
        );
        result.barrier = try reader.takeInt(u64, .little);
        for (&result.summaries) |*record| {
            record.present = try readBool(&reader);
            if (!record.present) continue;
            record.identity = try reader.takeInt(u128, .little);
            inline for (@typeInfo(ShardSummary).@"struct".fields) |field| {
                @field(record.value, field.name) = if (field.type == bool)
                    try readBool(&reader)
                else if (@typeInfo(field.type) == .@"enum")
                    std.enums.fromInt(field.type, try reader.takeInt(@typeInfo(field.type).@"enum".tag_type, .little)) orelse return error.InvalidCoordinatorSnapshot
                else
                    try reader.takeInt(field.type, .little);
            }
        }
        result.lease_count = try reader.takeInt(u8, .little);
        if (result.lease_count > result.leases.len) return error.InvalidCoordinatorSnapshot;
        for (result.leases[0..result.lease_count]) |*lease| inline for (@typeInfo(RiskLease).@"struct".fields) |field| {
            @field(lease, field.name) = if (field.type == bool)
                try readBool(&reader)
            else if (@typeInfo(field.type) == .@"enum")
                std.enums.fromInt(field.type, try reader.takeInt(@typeInfo(field.type).@"enum".tag_type, .little)) orelse return error.InvalidCoordinatorSnapshot
            else
                try reader.takeInt(field.type, .little);
        };
        result.account_netting_benefit_micros = try reader.takeInt(i64, .little);
        result.recovery_only = try readBool(&reader);
        result.last_account_fact = try readOptionalAccountFact(&reader);
        result.last_margin_observation = try readOptionalMarginObservation(&reader);
        result.margin_gate = .{
            .identity = try reader.takeInt(u128, .little),
            .open = try readBool(&reader),
            .latched = try readBool(&reader),
        };
        const expected = try reader.take(32);
        const encoded_digest = result.digest();
        if (reader.seek != encoded.len or !std.mem.eql(u8, expected, &encoded_digest))
            return error.InvalidCoordinatorSnapshot;
        result.recovery_only = true;
        result.recovery_margin_identity = 0;
        return result;
    }
};

/// Recovery-only bundle tying one coordinator snapshot to four restored shard barriers.
pub const AccountRecovery = struct {
    coordinator: AccountCoordinator,
    shards: [max_shards]trading.TradingShard,
    shard_barriers: [max_shards]u64,

    /// Restores all five authoritative snapshots before any Venue reconciliation.
    pub fn begin(
        coordinator_snapshot: []const u8,
        shard_snapshots: [max_shards][]const u8,
        shard_tails: [max_shards][]const u8,
    ) !AccountRecovery {
        var result: AccountRecovery = .{
            .coordinator = try AccountCoordinator.restore(coordinator_snapshot),
            .shards = undefined,
            .shard_barriers = undefined,
        };
        for (0..max_shards) |index| {
            const recovered = try trading.TradingShard.restore(shard_snapshots[index], shard_tails[index]);
            result.shards[index] = recovered.shard;
            result.shards[index].operational_state.trading_authorized = false;
            result.shards[index].operational_state.mode = .recovering;
            result.shard_barriers[index] = recovered.barrier;
            const summary = result.coordinator.summaries[index];
            if (!summary.present or summary.value.shard_sequence != recovered.barrier)
                return error.AccountRecoveryBarrierMismatch;
        }
        return result;
    }

    /// Releases only the coordinator fence; each shard still requires Venue recovery and enable.
    pub fn completeCoordinatorRecovery(self: *AccountRecovery) !void {
        try self.coordinator.completeRecovery();
        for (self.shards) |shard| if (shard.operational_state.mode != .recovering)
            return error.ShardRecoveryFenceLost;
    }
};

fn digestInt(hasher: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn digestStruct(hasher: *Sha256, comptime T: type, value: T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const item = @field(value, field.name);
        if (field.type == bool)
            hasher.update(&.{@intFromBool(item)})
        else if (@typeInfo(field.type) == .@"enum")
            digestInt(hasher, @typeInfo(field.type).@"enum".tag_type, @intFromEnum(item))
        else
            digestInt(hasher, field.type, item);
    }
}

fn digestOptionalAccountFact(hasher: *Sha256, fact: ?AccountFact) void {
    hasher.update(&.{@intFromBool(fact != null)});
    const value = fact orelse return;
    digestInt(hasher, u128, value.identity);
    digestInt(hasher, u128, value.exchange_account);
    digestInt(hasher, u64, value.version);
    digestInt(hasher, u64, value.barrier);
    switch (value.payload) {
        .account_snapshot => |snapshot| {
            digestInt(hasher, u8, 0);
            digestStruct(hasher, @TypeOf(snapshot), snapshot);
        },
        .forced_execution => |execution| {
            digestInt(hasher, u8, 1);
            hasher.update(&.{@intFromBool(execution.owner != null)});
            if (execution.owner) |owner| digestInt(hasher, u8, @intFromEnum(owner));
            digestInt(hasher, i64, execution.quantity);
            digestInt(hasher, i64, execution.price_micros);
            digestInt(hasher, i64, execution.fee_micros);
        },
    }
}

fn digestOptionalMarginObservation(hasher: *Sha256, observation: ?MarginObservation) void {
    hasher.update(&.{@intFromBool(observation != null)});
    if (observation) |value| digestStruct(hasher, MarginObservation, value);
}

fn writeOptionalAccountFact(writer: *std.Io.Writer, fact: ?AccountFact) !void {
    try writer.writeByte(@intFromBool(fact != null));
    const value = fact orelse return;
    try writer.writeInt(u128, value.identity, .little);
    try writer.writeInt(u128, value.exchange_account, .little);
    try writer.writeInt(u64, value.version, .little);
    try writer.writeInt(u64, value.barrier, .little);
    switch (value.payload) {
        .account_snapshot => |snapshot| {
            try writer.writeByte(0);
            try writer.writeInt(i64, snapshot.cash_micros, .little);
            try writer.writeInt(i64, snapshot.spot_quantity, .little);
            try writer.writeInt(i64, snapshot.swap_quantity, .little);
            try writer.writeInt(i64, snapshot.margin_micros, .little);
        },
        .forced_execution => |execution| {
            try writer.writeByte(1);
            try writer.writeByte(@intFromBool(execution.owner != null));
            if (execution.owner) |owner| try writer.writeByte(@intFromEnum(owner));
            try writer.writeInt(i64, execution.quantity, .little);
            try writer.writeInt(i64, execution.price_micros, .little);
            try writer.writeInt(i64, execution.fee_micros, .little);
        },
    }
}

fn readOptionalAccountFact(reader: *std.Io.Reader) !?AccountFact {
    if (!try readBool(reader)) return null;
    const identity = try reader.takeInt(u128, .little);
    const exchange_account = try reader.takeInt(u128, .little);
    const version = try reader.takeInt(u64, .little);
    const barrier = try reader.takeInt(u64, .little);
    const payload: AccountFactPayload = switch (try reader.takeByte()) {
        0 => .{ .account_snapshot = .{
            .cash_micros = try reader.takeInt(i64, .little),
            .spot_quantity = try reader.takeInt(i64, .little),
            .swap_quantity = try reader.takeInt(i64, .little),
            .margin_micros = try reader.takeInt(i64, .little),
        } },
        1 => .{ .forced_execution = .{
            .owner = if (try readBool(reader))
                std.enums.fromInt(ShardId, try reader.takeByte()) orelse return error.InvalidCoordinatorSnapshot
            else
                null,
            .quantity = try reader.takeInt(i64, .little),
            .price_micros = try reader.takeInt(i64, .little),
            .fee_micros = try reader.takeInt(i64, .little),
        } },
        else => return error.InvalidCoordinatorSnapshot,
    };
    return .{ .identity = identity, .exchange_account = exchange_account, .version = version, .barrier = barrier, .payload = payload };
}

fn writeOptionalMarginObservation(writer: *std.Io.Writer, observation: ?MarginObservation) !void {
    try writer.writeByte(@intFromBool(observation != null));
    if (observation) |value| {
        try writer.writeInt(u128, value.identity, .little);
        try writer.writeInt(u64, value.barrier, .little);
        try writer.writeInt(i64, value.venue_net_margin_micros, .little);
        try writer.writeInt(i64, value.venue_swap_quantity, .little);
        try writer.writeInt(i64, value.venue_spot_margin_micros, .little);
        try writer.writeInt(i64, value.venue_swap_margin_micros, .little);
        try writer.writeByte(@intFromEnum(value.margin_mode));
        try writer.writeInt(u32, value.rules_version, .little);
        try writer.writeByte(value.venue_risk_tier);
        try writer.writeInt(i64, value.venue_liquidation_distance_ticks, .little);
    }
}

fn readOptionalMarginObservation(reader: *std.Io.Reader) !?MarginObservation {
    if (!try readBool(reader)) return null;
    return .{
        .identity = try reader.takeInt(u128, .little),
        .barrier = try reader.takeInt(u64, .little),
        .venue_net_margin_micros = try reader.takeInt(i64, .little),
        .venue_swap_quantity = try reader.takeInt(i64, .little),
        .venue_spot_margin_micros = try reader.takeInt(i64, .little),
        .venue_swap_margin_micros = try reader.takeInt(i64, .little),
        .margin_mode = std.enums.fromInt(@FieldType(MarginObservation, "margin_mode"), try reader.takeByte()) orelse return error.InvalidCoordinatorSnapshot,
        .rules_version = try reader.takeInt(u32, .little),
        .venue_risk_tier = try reader.takeByte(),
        .venue_liquidation_distance_ticks = try reader.takeInt(i64, .little),
    };
}

fn readBool(reader: *std.Io.Reader) !bool {
    return switch (try reader.takeByte()) {
        0 => false,
        1 => true,
        else => error.InvalidCoordinatorSnapshot,
    };
}

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
    try std.testing.expectEqual(@as(i64, 400), try coordinator.grossPortfolioMargin());
    var total: i64 = 0;
    for (leases) |lease| total += lease.limit_micros;
    try std.testing.expectEqual(@as(i64, 1_000), total);
    try std.testing.expectEqual(@as(i64, 0), coordinator.account_netting_benefit_micros);
}

test "failed risk lease allocation is atomic and gross overflow fails closed" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    for (0..max_shards) |index| {
        const reservation: i64 = if (index == 2) 251 else 100;
        _ = try coordinator.publishSummary(index + 1, ShardSummary.fixture(@enumFromInt(index), 1, reservation));
    }
    const before = coordinator.digest();
    try std.testing.expectError(error.RiskLeaseOversubscribed, coordinator.allocateLeases(1, 10));
    try std.testing.expectEqual(@as(u8, 0), coordinator.lease_count);
    try std.testing.expectEqualSlices(u8, &before, &coordinator.digest());

    var overflowing = AccountCoordinator.init(900, std.math.maxInt(i64), std.math.maxInt(i64));
    for (0..max_shards) |index| {
        const reservation: i64 = if (index < 2) std.math.maxInt(i64) else 0;
        _ = try overflowing.publishSummary(index + 1, ShardSummary.fixture(@enumFromInt(index), 1, reservation));
    }
    try std.testing.expectError(error.Overflow, overflowing.grossPortfolioMargin());
    try std.testing.expectError(error.Overflow, overflowing.allocateLeases(1, 10));
    try std.testing.expectEqual(@as(u8, 0), overflowing.lease_count);
}

test "summary barrier and lease expiry fail atomically on overflow" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    coordinator.barrier = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, coordinator.publishSummary(1, ShardSummary.fixture(.shard_0, 1, 100)));
    try std.testing.expect(!coordinator.summaries[0].present);

    coordinator.barrier = 0;
    for (0..max_shards) |index| _ = try coordinator.publishSummary(index + 1, ShardSummary.fixture(@enumFromInt(index), 1, 100));
    _ = try coordinator.allocateLeases(1, 20);
    coordinator.leases[2].version = std.math.maxInt(u64);
    const before = coordinator.leases;
    try std.testing.expectError(error.Overflow, coordinator.expireLeases(21));
    try std.testing.expectEqualDeep(before, coordinator.leases);
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

test "margin reconciliation preserves netting benefit but latches unexplained differences" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    for (0..max_shards) |index| {
        var summary = ShardSummary.fixture(@enumFromInt(index), 1, 100);
        summary.exchange_margin_micros = if (index < 2) 63 else 62;
        _ = try coordinator.publishSummary(index + 1, summary);
    }
    const healthy = try coordinator.reconcileMargin(.{ .identity = 20, .barrier = 5, .venue_net_margin_micros = 250, .venue_swap_margin_micros = 250, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 });
    try std.testing.expect(healthy.open);
    try std.testing.expectEqual(@as(i64, 150), coordinator.account_netting_benefit_micros);
    try std.testing.expectEqual(@as(i64, 400), try coordinator.grossPortfolioMargin());
    const broken = try coordinator.reconcileMargin(.{ .identity = 21, .barrier = 6, .venue_net_margin_micros = 250, .venue_swap_margin_micros = 250, .venue_swap_quantity = 1, .margin_mode = .isolated, .rules_version = 1 });
    try std.testing.expect(!broken.open);
    try std.testing.expect(broken.latched);
    const still_latched = try coordinator.reconcileMargin(.{ .identity = 22, .barrier = 7, .venue_net_margin_micros = 250, .venue_swap_margin_micros = 250, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 });
    try std.testing.expect(still_latched.latched);
    const resolved = try coordinator.resolveMarginGate(22);
    try std.testing.expect(resolved.open);
    try std.testing.expect(!resolved.latched);
}

test "unowned economics route once and account gates enter the stable shard seam" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    const deliveries = try coordinator.acceptAccountFact(.{
        .identity = 33,
        .exchange_account = 900,
        .version = 1,
        .barrier = 1,
        .payload = .{ .forced_execution = .{ .owner = null, .quantity = -1, .price_micros = 100, .fee_micros = 1 } },
    });
    try std.testing.expectEqual(@as(usize, 1), deliveries.len);
    try std.testing.expectEqual(ShardId.shard_0, deliveries[0].shard_id);

    var shard: trading.TradingShard = .{};
    shard.quantity_denominator = 1;
    shard.operational_state = trading.operational.State.init(100);
    var stable_journal = trading.journal.Journal.init();
    try applyAccountFactStable(deliveries[0], .shard_0, &shard, &stable_journal);
    try std.testing.expect(shard.economicSummary().reconciliation_break);
    const gate_delivery: GateDelivery = .{ .shard_id = .shard_0, .gate = .{ .identity = 44, .open = false, .latched = true } };
    try applyAccountGateStable(gate_delivery, .shard_0, &shard, &stable_journal);
    try std.testing.expect(!shard.operational_state.effectiveTradingAuthority());
    try std.testing.expect(shard.operational_state.latch_count > 0);
}

test "shared gateway routes itemized outcomes to the unique owning shard" {
    var gateway: SharedExecutionGateway = .{};
    const first = try gateway.submit(.{ .exchange_account = 900, .shard_id = .shard_0, .fencing_token = 7, .command = commandFixture(1, 1) });
    const second = try gateway.submit(.{ .exchange_account = 900, .shard_id = .shard_1, .fencing_token = 7, .command = commandFixture(1, 1) });
    try std.testing.expectEqual(ShardId.shard_0, first.shard_id);
    try std.testing.expectEqual(ShardId.shard_1, second.shard_id);
    try std.testing.expectError(error.DuplicateCommandIdentity, gateway.submit(.{ .exchange_account = 900, .shard_id = .shard_0, .fencing_token = 7, .command = commandFixture(1, 1) }));
    try std.testing.expectError(error.CrossAccountGatewayRequest, gateway.submit(.{ .exchange_account = 901, .shard_id = .shard_2, .fencing_token = 7, .command = commandFixture(2, 1) }));
    const routed = try gateway.complete(.{
        .exchange_account = 900,
        .shard_id = .shard_1,
        .command_id = second.command_id,
        .order_id = 1,
        .revision = 1,
        .fencing_token = 7,
        .state = .unknown,
    });
    try std.testing.expectEqual(ShardId.shard_1, routed.shard_id);
    try std.testing.expectEqual(trading.oms.DispatchState.unknown, routed.state);
}

test "protocol rejects sequence gaps identity drift and cross shard delivery" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    const first = ShardSummary.fixture(.shard_0, 1, 100);
    _ = try coordinator.publishSummary(1, first);
    try std.testing.expectError(error.ShardSequenceGap, coordinator.publishSummary(2, first.withSequence(3)));
    var drift = first.withSequence(2);
    drift.decision_domain = 99;
    try std.testing.expectError(error.ShardIdentityDrift, coordinator.publishSummary(2, drift));

    const delivery: Delivery = .{ .shard_id = .shard_0, .fact = .{
        .identity = 3,
        .exchange_account = 900,
        .version = 1,
        .barrier = 1,
        .payload = .{ .forced_execution = .{ .owner = .shard_0, .quantity = -1, .price_micros = 1, .fee_micros = 0 } },
    } };
    var shard: trading.TradingShard = .{};
    var stable_journal = trading.journal.Journal.init();
    try std.testing.expectError(error.CrossShardDelivery, applyAccountFactStable(delivery, .shard_1, &shard, &stable_journal));
}

test "local faults stay local while account gates tighten every shard" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    for (0..max_shards) |index| _ = try coordinator.publishSummary(index + 1, ShardSummary.fixture(@enumFromInt(index), 1, 100));
    const before = coordinator.summaries[1].value;
    var local = coordinator.summaries[0].value;
    local.local_gate_closed = true;
    _ = try coordinator.publishSummary(10, local.withSequence(2));
    try std.testing.expectEqualDeep(before, coordinator.summaries[1].value);
    const gates = coordinator.accountGateDeliveries(.{ .identity = 30, .open = false, .latched = true });
    try std.testing.expectEqual(@as(usize, 4), gates.len);
    for (gates, 0..) |delivery, index| {
        try std.testing.expectEqual(@as(ShardId, @enumFromInt(index)), delivery.shard_id);
        try std.testing.expect(!delivery.gate.open);
    }
}

test "four shard coordinator snapshot restores deterministic authority" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    for (0..max_shards) |index| {
        var summary = ShardSummary.fixture(@enumFromInt(index), 1, 100);
        summary.exchange_margin_micros = if (index < 2) 63 else 62;
        _ = try coordinator.publishSummary(index + 1, summary);
    }
    _ = try coordinator.allocateLeases(1, 10);
    _ = try coordinator.reconcileMargin(.{ .identity = 20, .barrier = 5, .venue_net_margin_micros = 250, .venue_swap_margin_micros = 250, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 });
    var storage: [4096]u8 = undefined;
    const encoded = try coordinator.snapshot(&storage);
    const recovered = try AccountCoordinator.restore(encoded);
    try std.testing.expect(recovered.recovery_only);
    var expected = coordinator;
    expected.recovery_only = true;
    try std.testing.expectEqualSlices(u8, &expected.digest(), &recovered.digest());
    try std.testing.expectEqual(try coordinator.grossPortfolioMargin(), try recovered.grossPortfolioMargin());
    try std.testing.expectEqual(coordinator.account_netting_benefit_micros, recovered.account_netting_benefit_micros);
    try std.testing.expectEqual(coordinator.barrier, recovered.barrier);
}

test "account recovery restores four matching shard tails under fresh evidence fence" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    var shard_snapshots_storage: [max_shards][32 * 1024]u8 = undefined;
    var shard_snapshots: [max_shards][]const u8 = undefined;
    var shard_tails: [max_shards][]const u8 = undefined;
    var tail_journals: [max_shards]trading.journal.Journal = undefined;
    for (0..max_shards) |index| {
        var shard: trading.TradingShard = .{};
        var stable_journal = trading.journal.Journal.init();
        _ = try trading.applyStable(&shard, &stable_journal, .{
            .identity = 1,
            .payload = .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = 1, .quantity_denominator = 1, .reservation_model = .leveraged } },
        });
        _ = try trading.applyStable(&shard, &stable_journal, .{
            .identity = 1,
            .payload = .{ .margin_rules_activated = .{ .version = 1 } },
        });
        _ = try trading.applyStable(&shard, &stable_journal, .{
            .identity = 1,
            .payload = .{ .account_configuration = .{ .exchange_account_identity = 900 } },
        });
        try stable_journal.seal();
        shard_snapshots[index] = try shard.snapshot(&stable_journal, 3, &shard_snapshots_storage[index]);
        tail_journals[index] = trading.journal.Journal.initAt(4);
        try tail_journals[index].seal();
        shard_tails[index] = tail_journals[index].bytes();
        _ = try coordinator.publishSummary(index + 1, ShardSummary.fixture(@enumFromInt(index), 1, 100));
        _ = try coordinator.publishSummary(index + 11, ShardSummary.fixture(@enumFromInt(index), 2, 100));
        _ = try coordinator.publishSummary(index + 21, ShardSummary.fixture(@enumFromInt(index), 3, 100));
    }
    _ = try coordinator.allocateLeases(1, 20);
    var coordinator_storage: [4096]u8 = undefined;
    const coordinator_snapshot = try coordinator.snapshot(&coordinator_storage);
    var recovered = try AccountRecovery.begin(coordinator_snapshot, shard_snapshots, shard_tails);
    try std.testing.expect(recovered.coordinator.recovery_only);
    for (recovered.shards) |shard| try std.testing.expectEqual(trading.operational.OperationalMode.recovering, shard.operational_state.mode);
    try std.testing.expectError(error.FreshMarginObservationRequired, recovered.completeCoordinatorRecovery());
}
