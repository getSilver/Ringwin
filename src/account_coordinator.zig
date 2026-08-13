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

/// Venue account-margin evidence used only for reconciliation.
pub const MarginObservation = struct {
    identity: u128,
    barrier: u64,
    venue_net_margin_micros: i64,
    venue_swap_quantity: i64,
    margin_mode: enum(u8) { isolated },
    rules_version: u32,
};

/// Account-level authority result that every affected shard must consume.
pub const AccountGate = struct { identity: u128, open: bool, latched: bool };
/// One account-wide gate delivery to a specific shard.
pub const GateDelivery = struct { shard_id: ShardId, gate: AccountGate };

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
pub const GatewayOutcome = struct { shard_id: ShardId, command_id: u64, state: trading.oms.DispatchState };

const GatewayRecord = struct { exchange_account: u128, shard_id: ShardId, command_id: u64, order_id: u64, revision: u32, fencing_token: u64 };

/// Fixed-capacity shared sender that owns routing and transport attempts only.
pub const SharedExecutionGateway = struct {
    records: [32]GatewayRecord = undefined,
    count: u8 = 0,
    latest_fencing_token: u64 = 0,

    /// Admits one uniquely owned command before the transport send attempt.
    pub fn submit(self: *SharedExecutionGateway, request: GatewayRequest) !GatewayReceipt {
        if (request.exchange_account == 0 or request.fencing_token == 0 or request.command.command_id == 0 or
            request.command.order_id == 0 or request.command.revision == 0)
            return error.InvalidGatewayRequest;
        if (request.fencing_token < self.latest_fencing_token) return error.StaleFencingToken;
        for (self.records[0..self.count]) |known| {
            if (known.shard_id == request.shard_id and known.command_id == request.command.command_id)
                return error.DuplicateCommandIdentity;
        }
        if (self.count == self.records.len) return error.GatewayCapacityExceeded;
        self.latest_fencing_token = @max(self.latest_fencing_token, request.fencing_token);
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
            if (known.command_id == outcome.command_id and known.shard_id == outcome.shard_id) return outcome;
        }
        return error.UnknownGatewayCommand;
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
        for (self.summaries) |record| {
            if (!record.present) return error.IncompleteShardSummaries;
            projected_quantity = try std.math.add(i64, projected_quantity, record.value.swap_quantity);
        }
        const gross = self.grossPortfolioMargin();
        self.account_netting_benefit_micros = @max(gross - observation.venue_net_margin_micros, 0);
        const closed = projected_quantity == observation.venue_swap_quantity and
            observation.venue_net_margin_micros <= gross;
        self.last_margin_observation = observation;
        self.margin_gate = .{ .identity = observation.identity, .open = closed, .latched = !closed };
        return self.margin_gate;
    }

    /// Produces a stable fan-out plan for an account-level authority restriction.
    pub fn accountGateDeliveries(self: *AccountCoordinator, gate: AccountGate) []const GateDelivery {
        for (&self.gate_deliveries, 0..) |*delivery, index|
            delivery.* = .{ .shard_id = @enumFromInt(index), .gate = gate };
        return &self.gate_deliveries;
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

test "margin reconciliation preserves netting benefit but latches unexplained differences" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    for (0..max_shards) |index| _ = try coordinator.publishSummary(index + 1, ShardSummary.fixture(@enumFromInt(index), 1, 100));
    const healthy = try coordinator.reconcileMargin(.{ .identity = 20, .barrier = 5, .venue_net_margin_micros = 250, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 });
    try std.testing.expect(healthy.open);
    try std.testing.expectEqual(@as(i64, 150), coordinator.account_netting_benefit_micros);
    try std.testing.expectEqual(@as(i64, 400), coordinator.grossPortfolioMargin());
    const broken = try coordinator.reconcileMargin(.{ .identity = 21, .barrier = 6, .venue_net_margin_micros = 250, .venue_swap_quantity = 1, .margin_mode = .isolated, .rules_version = 1 });
    try std.testing.expect(!broken.open);
    try std.testing.expect(broken.latched);
}

test "shared gateway routes itemized outcomes to the unique owning shard" {
    var gateway: SharedExecutionGateway = .{};
    const first = try gateway.submit(.{ .exchange_account = 900, .shard_id = .shard_0, .fencing_token = 7, .command = commandFixture(1, 1) });
    const second = try gateway.submit(.{ .exchange_account = 900, .shard_id = .shard_1, .fencing_token = 7, .command = commandFixture(1, 1) });
    try std.testing.expectEqual(ShardId.shard_0, first.shard_id);
    try std.testing.expectEqual(ShardId.shard_1, second.shard_id);
    try std.testing.expectError(error.DuplicateCommandIdentity, gateway.submit(.{ .exchange_account = 900, .shard_id = .shard_0, .fencing_token = 7, .command = commandFixture(1, 1) }));
    const routed = try gateway.complete(.{ .shard_id = .shard_1, .command_id = second.command_id, .state = .unknown });
    try std.testing.expectEqual(ShardId.shard_1, routed.shard_id);
    try std.testing.expectEqual(trading.oms.DispatchState.unknown, routed.state);
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
