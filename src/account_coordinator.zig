const std = @import("std");
const durable = @import("durable_store.zig");
const trading = @import("trading_shard.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const snapshot_magic: u64 = 0x54434341574e4952;
const coordinator_snapshot_version: u16 = 8;
const history = @import("business_history.zig");
const codec = @import("snapshot_codec.zig");
const account_margin_gate_identity: u128 = 0x414343544d415247;

fn applyCoreStable(shard: *trading.TradingShard, stable_journal: *trading.journal.Journal, input: trading.CoreEvent) !?trading.OrderCommand {
    return trading.applyStable(shard, stable_journal, .{ .core = input });
}

pub const max_shards = 4;
const max_completed_forced_allocations = 32;

/// Account-level margin mode; IsolatedLinearUsdtV1 stays the only supported model.
pub const AccountMarginMode = enum(u8) { isolated, cross };

/// Deterministic classification of one margin reconciliation observation.
pub const MarginReconciliationState = enum(u8) { unknown, healthy, broken };

const unknown_liquidation_distance: i64 = std.math.maxInt(i64);

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
    reservation_atoms: i128,
    spot_quantity: i64,
    spot_asset_atoms: i128 = 0,
    swap_quantity: i64,
    cash_atoms: i128,
    open_orders: u8,
    unknown_orders: u8,
    local_gate_closed: bool,
    spot_margin_atoms: i128 = 0,
    exchange_margin_atoms: i128 = 0,
    risk_tier: u8 = 0,
    liquidation_distance_ticks: i64 = unknown_liquidation_distance,
    margin_mode: AccountMarginMode = .isolated,

    fn fixture(shard_id: ShardId, sequence: u64, reservation: i128) ShardSummary {
        return .{
            .shard_id = shard_id,
            .decision_domain = @intFromEnum(shard_id) + 1,
            .virtual_portfolio = @intFromEnum(shard_id) + 11,
            .exchange_account = 900,
            .shard_sequence = sequence,
            .rules_version = 1,
            .lease_version = 1,
            .reservation_atoms = reservation,
            .spot_quantity = 0,
            .swap_quantity = 0,
            .cash_atoms = 1_000,
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
    limit_atoms: i128,
    used_atoms: i128,
    open: bool,
};

/// Account-wide observations normalized once before deterministic fan-out.
pub const AccountFactPayload = union(enum) {
    account_snapshot: struct { cash_atoms: i128, spot_asset_atoms: i128 = 0, swap_quantity: i64, margin_atoms: i128 },
    forced_execution: struct { owner: ?ShardId, quantity: i64, price_ticks: i64, realized_pnl_atoms: i128 = 0, fee_atoms: i128, penalty_atoms: i128 = 0 },
};

/// Account-wide observations normalized once before deterministic fan-out.
pub const AccountFact = struct {
    times: ?@import("economics.zig").FundingCoreTimes = null,
    identity: u128,
    exchange_account: u128,
    version: u64,
    barrier: u64,
    payload: AccountFactPayload,
};

/// One target assignment; the target shard still applies the canonical fact.
pub const Delivery = struct { shard_id: ShardId, fact: AccountFact, allocation_identity: u128 = 0, slice_index: u8 = 0, source_identity: u128 = 0 };

pub const ForcedExecutionSlice = struct {
    owner: ShardId = .shard_0,
    quantity: i64 = 0,
    position_delta: i64 = 0,
    realized_pnl_atoms: i128 = 0,
    fee_atoms: i128 = 0,
    penalty_atoms: i128 = 0,
};

pub const ForcedExecutionAllocation = struct {
    identity: u128,
    forced_execution_identity: u128,
    slices: [max_shards]ForcedExecutionSlice = @splat(.{}),
    count: u8,
};

pub const ForcedAllocationRecord = struct {
    allocation: ForcedExecutionAllocation,
    delivered_mask: u8 = 0,
};

/// Immutable complete source evidence; unused records have canonical zero values.
pub const ForcedOwner = struct { portfolio: u128 = 0, decision_domain: u128 = 0 };
pub const ForcedSourceHistory = struct {
    owners: [max_shards]ForcedOwner,
    source: AccountFact,
    positions: [max_shards]i64,
    allocations: [max_shards]ForcedAllocationRecord,
    count: u8,
};

pub const ForcedSuspense = struct { quantity: i64, position_delta: i64, realized_pnl_atoms: i128, fee_atoms: i128, penalty_atoms: i128 };

/// Venue account-margin evidence used only for reconciliation.
pub const MarginObservation = struct {
    identity: u128,
    barrier: u64,
    venue_net_margin_atoms: i128,
    venue_swap_quantity: i64,
    venue_spot_asset_atoms: i128 = 0,
    venue_spot_margin_atoms: i128 = 0,
    venue_swap_margin_atoms: i128 = 0,
    margin_mode: AccountMarginMode,
    rules_version: u32,
    venue_risk_tier: u8 = 0,
    venue_liquidation_distance_ticks: i64 = unknown_liquidation_distance,
    bucket_rounding_atoms: i128 = 0,
};

/// Account-level authority result that every affected shard must consume.
pub const AccountGate = struct { identity: u128, open: bool, latched: bool };
/// One account-wide gate delivery to a specific shard.
pub const GateDelivery = struct { shard_id: ShardId, gate: AccountGate };

/// One durable coordinator input that can be replayed after a coordinator snapshot.
pub const CoordinationEvent = union(enum) {
    publish_summary: struct { identity: u128, summary: ShardSummary },
    allocate_leases: struct { version: u64, valid_through_barrier: u64 },
    account_fact: AccountFact,
    margin_observation: MarginObservation,
    resolve_margin_gate: u128,
    tighten_leases: struct { valid_through_barrier: u64, requested_limits: [max_shards]i128 },
    forced_execution_allocation: ForcedExecutionAllocation,
    forced_delivery_ack: struct { allocation_identity: u128, slice_index: u8 },
    forced_history_commit: history.Receipt,
    forced_history_checked: struct { allocation: ForcedExecutionAllocation, proof: history.LookupProof },
    forced_source_checked: struct { fact: AccountFact, proof: history.LookupProof },
    gateway_record: struct { request: GatewayRequest, proof: ?history.LookupProof = null },
    gateway_retire: struct { qualification: GatewayRetirement, receipt: history.Receipt },
};

/// Append-only, checksummed durable tail for inputs owned by AccountCoordinator.
pub const CoordinationJournal = struct {
    stable: trading.journal.Journal,

    /// Creates a tail with an explicit, independent durable input sequence.
    pub fn initAt(first_sequence: u64) CoordinationJournal {
        return .{ .stable = trading.journal.Journal.initAt(first_sequence) };
    }

    /// Appends one normalized coordinator input before it is applied live.
    pub fn append(self: *CoordinationJournal, event: CoordinationEvent) !void {
        var storage: [trading.journal.max_payload_size]u8 = undefined;
        const encoded = try encodeCoordinationEvent(&storage, event);
        try self.stable.append(.{
            .type_id = coordinationEventType(event),
            .schema_version = @import("production_contract.zig").journal_schema_version,
            .flags = trading.journal.input_flag,
            .sequence = try std.math.add(u64, self.stable.last_sequence, 1),
            .source_time = 0,
            .receive_time = 0,
            .monotonic_time = 0,
            .wall_time = 0,
            .time_presence = .{},
            .payload = encoded,
        });
    }

    /// Seals this segment so recovery can distinguish a clean tail from a truncation.
    pub fn seal(self: *CoordinationJournal) !void {
        try self.stable.seal();
    }

    /// Returns the immutable bytes to persist with the coordinator snapshot.
    pub fn bytes(self: *const CoordinationJournal) []const u8 {
        return self.stable.bytes();
    }
};

/// Converts one routed account fact into the target shard's stable event seam.
pub fn accountFactEvent(delivery: Delivery) !trading.CoreEvent {
    const identity = std.math.cast(u64, delivery.fact.identity) orelse return error.IdentityOutOfRange;
    if (delivery.fact.payload == .forced_execution and
        (delivery.allocation_identity == 0 or delivery.source_identity == 0)) return error.UnallocatedForcedExecution;
    return .{
        .identity = identity,
        .source_time = if (delivery.fact.times) |times| times.source else 0,
        .receive_time = if (delivery.fact.times) |times| times.receive else 0,
        .monotonic_time = if (delivery.fact.times) |times| times.monotonic else 0,
        .wall_time = if (delivery.fact.times) |times| times.wall else 0,
        .time_presence = if (delivery.fact.times) |times| times.presence else .{},
        .payload = switch (delivery.fact.payload) {
            .account_snapshot => |snapshot| .{ .economic_account_snapshot = .{
                .snapshot_id = identity,
                .usdt_balance_atoms = snapshot.cash_atoms,
                .spot_asset_atoms = snapshot.spot_asset_atoms,
                .swap_position_quantity = snapshot.swap_quantity,
                .margin_atoms = snapshot.margin_atoms,
            } },
            .forced_execution => |execution| .{ .venue_forced_execution = .{
                .execution_id = identity,
                .source_identity = delivery.source_identity,
                .side = if (execution.quantity < 0) .sell else .buy,
                .quantity = if (execution.quantity == std.math.minInt(i64))
                    return error.InvalidAccountFact
                else
                    @intCast(@abs(execution.quantity)),
                .price_ticks = execution.price_ticks,
                .fee_atoms = execution.fee_atoms,
                .penalty_atoms = execution.penalty_atoms,
                .expected_realized_pnl_atoms = execution.realized_pnl_atoms,
            } },
        },
    };
}

/// Converts one lease grant into the existing shard risk-lease event.
pub fn riskLeaseEvent(lease: RiskLease) !trading.CoreEvent {
    const identity = std.math.cast(u64, lease.identity) orelse return error.IdentityOutOfRange;
    return .{ .identity = identity, .payload = .{ .risk_lease_granted = .{
        .lease_identity = identity,
        .version = lease.version,
        .valid_through_barrier = lease.valid_through_barrier,
        .open = lease.open,
        .amount_atoms = if (lease.open) lease.limit_atoms else 0,
        .strategy_limit_atoms = if (lease.open) lease.limit_atoms else 0,
        .portfolio_limit_atoms = if (lease.open) lease.limit_atoms else 0,
        .exchange_account_limit_atoms = if (lease.open) lease.limit_atoms else 0,
        .global_limit_atoms = if (lease.open) lease.limit_atoms else 0,
    } } };
}

/// Converts one account-wide restriction into a shard-local stable gate fact.
pub fn accountGateEvent(delivery: GateDelivery, target_identity: u128) !trading.CoreEvent {
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
    if (delivery.fact.payload == .forced_execution) return error.ForcedAllocationRequired;
    _ = try applyCoreStable(shard, stable_journal, try accountFactEvent(delivery));
}

/// The shard commit precedes the coordinator ack; retry after a crash uses the same slice identity.
pub fn applyForcedDeliveryStable(coordinator: *AccountCoordinator, coordination_journal: *CoordinationJournal, delivery: Delivery, target_shard_id: ShardId, shard: *trading.TradingShard, stable_journal: *trading.journal.Journal) !void {
    var known = false;
    for (try coordinator.pendingForcedDeliveries()) |pending| {
        if (std.meta.eql(pending, delivery)) known = true;
    }
    if (!known) return error.UnknownForcedDelivery;
    var candidate = coordinator.*;
    try candidate.markForcedDelivered(delivery.allocation_identity, delivery.slice_index);
    if (delivery.shard_id != target_shard_id) return error.CrossShardDelivery;
    _ = try applyCoreStable(shard, stable_journal, try accountFactEvent(delivery));
    try coordination_journal.append(.{ .forced_delivery_ack = .{ .allocation_identity = delivery.allocation_identity, .slice_index = delivery.slice_index } });
    coordinator.* = candidate;
}

fn shardHasAppliedForced(delivery: Delivery, shard: *const trading.TradingShard) !bool {
    var candidate = shard.*;
    const before = candidate.trace.len;
    _ = try candidate.apply(.{ .core = try accountFactEvent(delivery) });
    return candidate.trace.len == before;
}

fn forcedTailExplainsSummaryChange(coordinator: *AccountCoordinator, shard_id: ShardId, snapshot: []const u8, tail: []const u8, summary: ShardSummary) !bool {
    var before = (try trading.TradingShard.restoreSnapshot(snapshot)).shard;
    before.operational_state.trading_authorized = false;
    before.operational_state.mode = .recovering;
    const baseline = try shardSummaryFromShard(&before, shard_id, summary.shard_sequence, summary.decision_domain);
    if (!std.meta.eql(baseline, summary)) return false;
    var reader = try trading.journal.Reader.init(tail);
    var forced_count: usize = 0;
    while (true) switch (try reader.next()) {
        .record => |record| {
            if (record.flags != trading.journal.input_flag) continue;
            const input = try trading.decodeStableInput(record);
            if (input != .core or input.core.payload != .venue_forced_execution) return false;
            var matched = false;
            for (try coordinator.forcedDeliveries(true)) |delivery| {
                if (delivery.shard_id != shard_id) continue;
                if (std.meta.eql(input.core, try accountFactEvent(delivery))) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
            forced_count += 1;
        },
        .end => |status| return status == .clean and forced_count > 0,
    };
}

/// Durably applies one account restriction through the shard's transactional seam.
pub fn applyAccountGateStable(delivery: GateDelivery, target_shard_id: ShardId, shard: *trading.TradingShard, stable_journal: *trading.journal.Journal) !void {
    if (delivery.shard_id != target_shard_id) return error.CrossShardDelivery;
    _ = try applyCoreStable(shard, stable_journal, try accountGateEvent(delivery, shard.operational_state.target_identity));
}

/// Derives one shard's own publication strictly from its authoritative state.
pub fn shardSummaryFromShard(
    shard: *const trading.TradingShard,
    shard_id: ShardId,
    shard_sequence: u64,
    decision_domain: u128,
) !ShardSummary {
    if (decision_domain == 0 or shard_sequence == 0 or
        !shard.account_configured or shard.exchange_account_identity == 0)
        return error.InvalidShardSummary;
    const rules_version = @min(shard.instrument_rules_version, shard.margin_rules_version);
    if (rules_version == 0 or shard.portfolio_identity == 0) return error.InvalidShardSummary;
    var open_orders: u8 = 0;
    var unknown_orders: u8 = 0;
    for (shard.oms.orders[0..shard.oms.order_count]) |order| switch (order.state) {
        .unknown => unknown_orders += 1,
        .filled, .canceled, .rejected => {},
        else => open_orders += 1,
    };
    const economics_summary = shard.economicSummary();
    const portfolio_distance = shard.portfolio_liquidation_distance_ticks;
    const exchange_distance = shard.exchange_liquidation_distance_ticks;
    return .{
        .shard_id = shard_id,
        .decision_domain = decision_domain,
        .virtual_portfolio = shard.portfolio_identity,
        .exchange_account = shard.exchange_account_identity,
        .shard_sequence = shard_sequence,
        .rules_version = rules_version,
        .lease_version = shard.risk_lease_version,
        .reservation_atoms = try shard.activeReservationAtoms(),
        .spot_quantity = economics_summary.portfolio.spot.quantity,
        .spot_asset_atoms = economics_summary.portfolio.spot_asset_atoms,
        .swap_quantity = economics_summary.portfolio.swap.quantity,
        .cash_atoms = economics_summary.portfolio.usdt_balance_atoms,
        .open_orders = open_orders,
        .unknown_orders = unknown_orders,
        .local_gate_closed = shard.operational_state.latch_count > 0 or
            shard.portfolio_margin_gate != .healthy or
            shard.exchange_margin_gate != .healthy,
        .exchange_margin_atoms = economics_summary.exchange.margin_atoms,
        .risk_tier = shard.last_risk_tier,
        .liquidation_distance_ticks = @min(portfolio_distance, exchange_distance),
    };
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

pub const GatewayRetirement = struct {
    record: GatewayRecord,
    source_origin: history.Origin,
    source_barrier: u64,
    source_digest: history.Digest,
    order: trading.oms.OrderArchiveQualification,
    pub fn digest(self: GatewayRetirement) history.Digest {
        var bytes: [history.max_record_bytes]u8 = undefined;
        return history.hash(codec.encodeBare(&bytes, self) catch unreachable);
    }
};
pub const GatewayRecord = struct { exchange_account: u128, shard_id: ShardId, command_id: u64, order_id: u64, revision: u32, fencing_token: u64, command_digest: history.Digest };
fn gatewayRecord(request: GatewayRequest) GatewayRecord {
    var bytes: [2048]u8 = undefined;
    return .{ .exchange_account = request.exchange_account, .shard_id = request.shard_id, .command_id = request.command.command_id, .order_id = request.command.order_id, .revision = request.command.revision, .fencing_token = request.fencing_token, .command_digest = history.hash(codec.encodeBare(&bytes, request.command) catch unreachable) };
}

/// Fixed-capacity ownership ledger used beside the sole transport Gateway.
pub const GatewayOwnership = struct {
    exchange_account: u128 = 0,
    records: [32]GatewayRecord = @splat(std.mem.zeroes(GatewayRecord)),
    count: u8 = 0,
    latest_fencing_tokens: [max_shards]u64 = @splat(0),

    /// Records one uniquely owned command before the transport send attempt.
    pub fn record(self: *GatewayOwnership, request: GatewayRequest) !GatewayReceipt {
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
        self.records[self.count] = gatewayRecord(request);
        self.count += 1;
        return .{ .shard_id = request.shard_id, .command_id = request.command.command_id };
    }

    /// Routes an itemized result only when its owner and command identity match.
    pub fn complete(self: *const GatewayOwnership, outcome: GatewayOutcome) !GatewayOutcome {
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
    pub fn outcomeEvent(self: *const GatewayOwnership, outcome: GatewayOutcome) !trading.CoreEvent {
        _ = try self.complete(outcome);
        var items: [trading.oms.max_commands]trading.oms.DispatchItem = undefined;
        items[0] = .{ .command_id = outcome.command_id, .state = outcome.state };
        return .{ .identity = outcome.command_id, .payload = .{ .oms_dispatch_batch = .{ .items = items, .count = 1 } } };
    }

    /// Durably applies one transport outcome only to its exact owning shard.
    pub fn applyOutcomeStable(
        self: *const GatewayOwnership,
        outcome: GatewayOutcome,
        target_shard_id: ShardId,
        shard: *trading.TradingShard,
        stable_journal: *trading.journal.Journal,
    ) !void {
        if (outcome.shard_id != target_shard_id) return error.CrossShardDelivery;
        _ = try applyCoreStable(shard, stable_journal, try self.outcomeEvent(outcome));
    }
};

const fixture_swap_instrument: trading.oms.Instrument = 2;
const fixture_settlement_asset: trading.canonical.AssetIdentity = 1;

fn activateFixtureAssets(shard: *trading.TradingShard, log: *trading.journal.Journal) !void {
    for (@import("asset_registry.zig").testDefinitions(6, 8), 0..) |definition, index| {
        _ = try applyCoreStable(shard, log, .{ .identity = 100 + index, .payload = .{ .asset_definition_activated = definition } });
    }
}

fn commandFixture(command_id: u64, order_id: u64) trading.oms.Command {
    return .{
        .command_id = command_id,
        .order_id = order_id,
        .strategy_instance = 1,
        .revision = 1,
        .operation = .place,
        .instrument = fixture_swap_instrument,
        .side = .buy,
        .portfolio_reduce_only = false,
        .venue_reduce_only = false,
        .quantity = 1,
        .limit_price = .{ .instrument = fixture_swap_instrument, .rules_version = 1, .ticks = 1 },
        .reservation = .{ .asset = fixture_settlement_asset, .atoms = 1 },
    };
}

/// Fixed-capacity owner of cross-shard leases and account reconciliation only.
pub const AccountCoordinator = struct {
    exchange_account: u128,
    account_safety_ceiling_atoms: i128,
    global_ceiling_atoms: i128,
    barrier: u64 = 0,
    summaries: [max_shards]SummaryRecord = @splat(.{}),
    leases: [max_shards]RiskLease = undefined,
    lease_count: u8 = 0,
    account_netting_benefit_atoms: i128 = 0,
    last_account_fact: ?AccountFact = null,
    deliveries: [max_shards]Delivery = undefined,
    last_margin_observation: ?MarginObservation = null,
    margin_gate: AccountGate = .{ .identity = 0, .open = false, .latched = false },
    margin_reconciliation_state: MarginReconciliationState = .unknown,
    gate_deliveries: [max_shards]GateDelivery = undefined,
    recovery_only: bool = false,
    recovery_margin_identity: u128 = 0,
    suspense_forced_execution: ?AccountFact = null,
    reconciliation_break_identity: u128 = 0,
    forced_execution_source: ?AccountFact = null,
    forced_source_positions: [max_shards]i64 = @splat(0),
    forced_source_owners: [max_shards]ForcedOwner = @splat(.{}),
    forced_allocations: [max_shards]ForcedAllocationRecord = undefined,
    forced_allocation_count: u8 = 0,
    completed_forced_allocations: [max_completed_forced_allocations]ForcedExecutionAllocation = undefined,
    completed_forced_allocation_count: u8 = 0,
    forced_deliveries: [max_shards * max_shards]Delivery = undefined,
    history_root: ?history.Root = null,
    gateway_ownership: GatewayOwnership = .{},

    /// Keeps incomplete sources and their exact ACK state resident.
    pub fn prepareForcedSourceHistory(self: *const AccountCoordinator) !ForcedSourceHistory {
        const source = self.forced_execution_source orelse return error.ForcedSourceNotClosed;
        if (self.suspense_forced_execution != null or self.reconciliation_break_identity != 0 or
            self.forced_allocation_count == 0) return error.ForcedSourceNotClosed;
        var result: ForcedSourceHistory = .{ .source = source, .owners = self.forced_source_owners, .positions = self.forced_source_positions, .allocations = @splat(.{ .allocation = .{ .identity = 0, .forced_execution_identity = 0, .count = 0 } }), .count = self.forced_allocation_count };
        for (self.forced_allocations[0..self.forced_allocation_count], 0..) |record, index| {
            if (record.delivered_mask != (@as(u8, 1) << @intCast(record.allocation.count)) - 1)
                return error.ForcedSourceNotClosed;
            result.allocations[index] = record;
        }
        return result;
    }

    fn commitForcedSourceHistory(self: *AccountCoordinator, receipt: history.Receipt) !void {
        const source = try self.prepareForcedSourceHistory();
        var bytes: [8192]u8 = undefined;
        const qualification = history.hash(try codec.encodeBare(&bytes, source));
        if (receipt.root.origin.stream.domain != .control or receipt.root.origin.account != self.exchange_account)
            return error.InvalidCoordinatorHistoryOrigin;
        const root = try history.verifyReceipt(receipt, receipt.root.origin, qualification, self.history_root);
        self.history_root = root;
        self.forced_execution_source = null;
        self.forced_allocation_count = 0;
        self.forced_source_positions = @splat(0);
        self.forced_source_owners = @splat(.{});
    }

    pub fn accountFactHistoryRequest(self: *const AccountCoordinator, fact: AccountFact, pending_id: u128) history.LookupRequest {
        const root = self.history_root.?;
        var bytes: [1024]u8 = undefined;
        const value = history.hash(codec.encodeBare(&bytes, fact) catch unreachable);
        return .{ .pending_id = pending_id, .key = .{ .origin = root.origin, .identity = .{ .coordinator_account_fact = fact.identity } }, .candidate_payload_digest = value, .original_input_digest = value, .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
    }

    pub fn gatewayHistoryRequest(self: *const AccountCoordinator, record: GatewayRecord, pending_id: u128) history.LookupRequest {
        const root = self.history_root.?;
        var bytes: [1024]u8 = undefined;
        const value = history.hash(codec.encodeBare(&bytes, record) catch unreachable);
        return .{ .pending_id = pending_id, .key = .{ .origin = root.origin, .identity = .{ .coordinator_gateway_command = .{ .shard = @intFromEnum(record.shard_id), .command = record.command_id } } }, .candidate_payload_digest = value, .original_input_digest = value, .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
    }

    pub fn allocationHistoryRequest(self: *const AccountCoordinator, allocation: ForcedExecutionAllocation, pending_id: u128) history.LookupRequest {
        const root = self.history_root.?;
        var bytes: [1024]u8 = undefined;
        const digest_value = history.hash(codec.encodeBare(&bytes, allocation) catch unreachable);
        return .{ .pending_id = pending_id, .key = .{ .origin = root.origin, .identity = .{ .coordinator_forced_allocation = allocation.identity } }, .candidate_payload_digest = digest_value, .original_input_digest = digest_value, .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
    }

    /// Creates one coordinator for exactly one ExchangeAccount.
    pub fn init(exchange_account: u128, account_ceiling: i128, global_ceiling: i128) AccountCoordinator {
        return .{
            .exchange_account = exchange_account,
            .account_safety_ceiling_atoms = account_ceiling,
            .global_ceiling_atoms = global_ceiling,
        };
    }

    /// Publishes one semantic shard summary, accepting exact duplicates as no-op.
    pub fn publishSummary(self: *AccountCoordinator, identity: u128, summary: ShardSummary) !bool {
        if (identity == 0 or summary.decision_domain == 0 or summary.virtual_portfolio == 0 or
            summary.exchange_account != self.exchange_account or summary.shard_sequence == 0 or
            summary.rules_version == 0 or summary.reservation_atoms < 0)
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
        hasher.update("coordinator-history-v8");
        if (self.history_root) |root| hasher.update(&root.root_digest);
        var gateway_bytes: [1024]u8 = undefined;
        digestInt(&hasher, u128, self.gateway_ownership.exchange_account);
        digestInt(&hasher, u8, self.gateway_ownership.count);
        for (self.gateway_ownership.latest_fencing_tokens) |token| digestInt(&hasher, u64, token);
        for (self.gateway_ownership.records[0..self.gateway_ownership.count]) |record|
            hasher.update(codec.encodeBare(&gateway_bytes, record) catch unreachable);
        digestInt(&hasher, u128, self.exchange_account);
        digestInt(&hasher, i128, self.account_safety_ceiling_atoms);
        digestInt(&hasher, i128, self.global_ceiling_atoms);
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
        digestInt(&hasher, i128, self.account_netting_benefit_atoms);
        digestOptionalAccountFact(&hasher, self.last_account_fact);
        digestOptionalAccountFact(&hasher, self.suspense_forced_execution);
        digestInt(&hasher, u128, self.reconciliation_break_identity);
        digestOptionalAccountFact(&hasher, self.forced_execution_source);
        for (self.forced_source_positions) |position| digestInt(&hasher, i64, position);
        for (self.forced_source_owners) |owner| {
            digestInt(&hasher, u128, owner.portfolio);
            digestInt(&hasher, u128, owner.decision_domain);
        }
        digestInt(&hasher, u8, self.forced_allocation_count);
        for (self.forced_allocations[0..self.forced_allocation_count]) |record| {
            digestInt(&hasher, u128, record.allocation.identity);
            digestInt(&hasher, u128, record.allocation.forced_execution_identity);
            digestInt(&hasher, u8, record.allocation.count);
            for (record.allocation.slices[0..record.allocation.count]) |slice| digestStruct(&hasher, ForcedExecutionSlice, slice);
            digestInt(&hasher, u8, record.delivered_mask);
        }
        digestInt(&hasher, u8, self.completed_forced_allocation_count);
        for (self.completed_forced_allocations[0..self.completed_forced_allocation_count]) |allocation| {
            digestInt(&hasher, u128, allocation.identity);
            digestInt(&hasher, u128, allocation.forced_execution_identity);
            digestInt(&hasher, u8, allocation.count);
            for (allocation.slices[0..allocation.count]) |slice| digestStruct(&hasher, ForcedExecutionSlice, slice);
        }
        digestOptionalMarginObservation(&hasher, self.last_margin_observation);
        digestStruct(&hasher, AccountGate, self.margin_gate);
        digestInt(&hasher, u8, @intFromEnum(self.margin_reconciliation_state));
        var result: [Sha256.digest_length]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    /// Returns the non-netted sum of all published Portfolio reservations.
    pub fn grossPortfolioMargin(self: *const AccountCoordinator) !i128 {
        var total: i128 = 0;
        for (self.summaries) |record| {
            if (record.present) total = try std.math.add(i128, total, record.value.reservation_atoms);
        }
        return total;
    }

    /// Allocates deterministic leases without turning account netting into buying power.
    pub fn allocateLeases(self: *AccountCoordinator, version: u64, valid_through_barrier: u64) ![]const RiskLease {
        if (self.recovery_only) return error.CoordinatorRecoveryOnly;
        if (self.margin_gate.latched or self.margin_reconciliation_state == .broken)
            return error.MarginReconciliationRequired;
        if (version == 0 or valid_through_barrier < self.barrier) return error.InvalidRiskLease;
        for (self.summaries) |record| if (!record.present) return error.IncompleteShardSummaries;
        const gross = try self.grossPortfolioMargin();
        const ceiling = @min(self.account_safety_ceiling_atoms, self.global_ceiling_atoms);
        if (gross > ceiling or ceiling <= 0) return error.AccountSafetyCeilingExceeded;
        const base = @divFloor(ceiling, max_shards);
        const remainder = @mod(ceiling, max_shards);
        var candidate: [max_shards]RiskLease = undefined;
        for (&candidate, 0..) |*lease, index| {
            const summary = self.summaries[index].value;
            var limit = base + @as(i64, if (index < remainder) 1 else 0);
            if (self.lease_count != 0 and self.leases[index].open)
                limit = @min(limit, self.leases[index].limit_atoms);
            if (summary.reservation_atoms > limit) return error.RiskLeaseOversubscribed;
            lease.* = .{
                .identity = try std.math.add(u128, try std.math.mul(u128, version, max_shards), index + 1),
                .exchange_account = self.exchange_account,
                .shard_id = @enumFromInt(index),
                .decision_domain = summary.decision_domain,
                .version = version,
                .valid_through_barrier = valid_through_barrier,
                .limit_atoms = limit,
                .used_atoms = summary.reservation_atoms,
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
                lease.limit_atoms = 0;
                lease.used_atoms = 0;
                lease.open = false;
                changed = true;
            }
        }
        if (changed) self.leases = candidate;
        return changed;
    }

    /// Returns the stable close events that must be applied to every expired lease owner.
    pub fn expiredLeaseEvents(self: *const AccountCoordinator, events: *[max_shards]trading.CoreEvent) ![]const trading.CoreEvent {
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
        if (fact.payload == .forced_execution) {
            const forced = fact.payload.forced_execution;
            if (forced.quantity == 0 or forced.quantity == std.math.minInt(i64) or
                forced.price_ticks <= 0 or forced.fee_atoms < 0 or forced.penalty_atoms < 0)
                return error.InvalidAccountFact;
            if (@as(usize, self.completed_forced_allocation_count) + self.forced_allocation_count > max_completed_forced_allocations)
                return error.ForcedExecutionHistoryCapacityExceeded;
        }
        const count: usize = switch (fact.payload) {
            .account_snapshot => max_shards,
            .forced_execution => 0,
        };
        if (count == 0 and self.suspense_forced_execution != null) return error.SuspenseAccountCapacityExceeded;
        self.last_account_fact = fact;
        switch (fact.payload) {
            .forced_execution => {
                // ponytail: bounded identity history; add explicit archive retention if 32 completed allocations are insufficient.
                for (self.forced_allocations[0..self.forced_allocation_count]) |record| {
                    self.completed_forced_allocations[self.completed_forced_allocation_count] = record.allocation;
                    self.completed_forced_allocation_count += 1;
                }
                self.forced_allocation_count = 0;
                self.forced_execution_source = fact;
                for (self.summaries, 0..) |summary, index| {
                    self.forced_source_positions[index] = if (summary.present) summary.value.swap_quantity else 0;
                    self.forced_source_owners[index] = if (summary.present) .{ .portfolio = summary.value.virtual_portfolio, .decision_domain = summary.value.decision_domain } else .{};
                }
                self.suspense_forced_execution = fact;
                self.reconciliation_break_identity = fact.identity;
                self.margin_gate = .{ .identity = fact.identity, .open = false, .latched = true };
                self.recovery_only = true;
                for (self.leases[0..self.lease_count]) |*lease| lease.used_atoms = lease.limit_atoms;
            },
            .account_snapshot => {
                for (self.deliveries[0..count], 0..) |*delivery, index|
                    delivery.* = .{ .shard_id = @enumFromInt(index), .fact = fact };
            },
        }
        return self.deliveries[0..count];
    }

    pub fn allocateForcedExecution(self: *AccountCoordinator, allocation: ForcedExecutionAllocation) ![]const Delivery {
        if (self.history_root != null) return error.CoordinatorHistoryProofRequired;
        return self.allocateForcedExecutionVerified(allocation);
    }

    fn allocateForcedExecutionVerified(self: *AccountCoordinator, allocation: ForcedExecutionAllocation) ![]const Delivery {
        var normalized = allocation;
        if (normalized.count <= max_shards) {
            for (normalized.slices[normalized.count..]) |*slice| slice.* = .{};
        }
        for (self.completed_forced_allocations[0..self.completed_forced_allocation_count]) |known| {
            if (known.identity != normalized.identity) continue;
            if (!std.meta.eql(known, normalized)) return error.ForcedExecutionAllocationConflict;
            return self.forced_deliveries[0..0];
        }
        const source = self.forced_execution_source orelse return error.UnknownForcedExecution;
        if (allocation.identity == 0 or allocation.forced_execution_identity != source.identity or
            allocation.count == 0 or allocation.count > max_shards or
            std.math.cast(u64, allocation.identity) == null or
            allocation.identity > (std.math.maxInt(u64) - max_shards) / max_shards)
            return error.InvalidForcedExecutionAllocation;
        for (self.forced_allocations[0..self.forced_allocation_count]) |known| {
            if (known.allocation.identity == normalized.identity) {
                if (!std.meta.eql(known.allocation, normalized)) return error.ForcedExecutionAllocationConflict;
                return self.pendingForcedDeliveries();
            }
        }
        if (self.forced_allocation_count == max_shards) return error.ForcedExecutionAllocationCapacityExceeded;
        var quantity: i128 = 0;
        var pnl: i128 = 0;
        var fee: i128 = 0;
        var penalty: i128 = 0;
        var owner_quantity: [max_shards]i128 = @splat(0);
        for (self.forced_allocations[0..self.forced_allocation_count]) |known| {
            for (known.allocation.slices[0..known.allocation.count]) |slice| {
                quantity += slice.quantity;
                pnl = try std.math.add(i128, pnl, slice.realized_pnl_atoms);
                fee = try std.math.add(i128, fee, slice.fee_atoms);
                penalty = try std.math.add(i128, penalty, slice.penalty_atoms);
                owner_quantity[@intFromEnum(slice.owner)] += slice.quantity;
            }
        }
        for (normalized.slices[0..normalized.count]) |slice| {
            if (slice.quantity == 0 or slice.quantity == std.math.minInt(i64) or
                slice.position_delta != slice.quantity or slice.fee_atoms < 0 or slice.penalty_atoms < 0)
                return error.InvalidForcedExecutionAllocation;
            const index = @intFromEnum(slice.owner);
            const position = self.forced_source_positions[index];
            if (position == 0 or (position > 0) == (slice.quantity > 0)) return error.ForcedExecutionOwnerMismatch;
            owner_quantity[index] += slice.quantity;
            if (@abs(owner_quantity[index]) > @abs(@as(i128, position))) return error.ForcedExecutionOwnerMismatch;
            quantity += slice.quantity;
            pnl = try std.math.add(i128, pnl, slice.realized_pnl_atoms);
            fee = try std.math.add(i128, fee, slice.fee_atoms);
            penalty = try std.math.add(i128, penalty, slice.penalty_atoms);
        }
        const execution = source.payload.forced_execution;
        _ = try std.math.sub(i128, execution.realized_pnl_atoms, pnl);
        if (fee > execution.fee_atoms or penalty > execution.penalty_atoms or
            std.math.cast(i64, @as(i128, execution.quantity) - quantity) == null)
            return error.ForcedExecutionAllocationNotConserved;
        self.forced_allocations[self.forced_allocation_count] = .{ .allocation = normalized };
        self.forced_allocation_count += 1;
        return self.pendingForcedDeliveries();
    }

    pub fn commitForcedAllocation(self: *AccountCoordinator, journal: *CoordinationJournal, allocation: ForcedExecutionAllocation) ![]const Delivery {
        var normalized = allocation;
        if (normalized.count <= max_shards) {
            for (normalized.slices[normalized.count..]) |*slice| slice.* = .{};
        }
        for (self.completed_forced_allocations[0..self.completed_forced_allocation_count]) |known| {
            if (known.identity != normalized.identity) continue;
            if (!std.meta.eql(known, normalized)) return error.ForcedExecutionAllocationConflict;
            return self.forced_deliveries[0..0];
        }
        var candidate = self.*;
        _ = try candidate.allocateForcedExecution(allocation);
        if (candidate.forced_allocation_count == self.forced_allocation_count) return self.pendingForcedDeliveries();
        try journal.append(.{ .forced_execution_allocation = allocation });
        self.* = candidate;
        return self.pendingForcedDeliveries();
    }

    pub fn pendingForcedDeliveries(self: *AccountCoordinator) ![]const Delivery {
        return self.forcedDeliveries(false);
    }

    fn forcedDeliveries(self: *AccountCoordinator, include_delivered: bool) ![]const Delivery {
        const source = self.forced_execution_source orelse return self.forced_deliveries[0..0];
        var count: usize = 0;
        for (self.forced_allocations[0..self.forced_allocation_count]) |record| {
            for (record.allocation.slices[0..record.allocation.count], 0..) |slice, index| {
                if (!include_delivered and record.delivered_mask & (@as(u8, 1) << @intCast(index)) != 0) continue;
                var fact = source;
                fact.identity = try std.math.add(u64, try std.math.mul(u64, @intCast(record.allocation.identity), max_shards), @intCast(index + 1));
                fact.payload.forced_execution = .{
                    .owner = slice.owner,
                    .quantity = slice.quantity,
                    .price_ticks = source.payload.forced_execution.price_ticks,
                    .realized_pnl_atoms = slice.realized_pnl_atoms,
                    .fee_atoms = slice.fee_atoms,
                    .penalty_atoms = slice.penalty_atoms,
                };
                self.forced_deliveries[count] = .{ .shard_id = slice.owner, .fact = fact, .allocation_identity = record.allocation.identity, .slice_index = @intCast(index), .source_identity = source.identity };
                count += 1;
            }
        }
        return self.forced_deliveries[0..count];
    }

    pub fn forcedSuspenseRemaining(self: *const AccountCoordinator) !?ForcedSuspense {
        const source = self.suspense_forced_execution orelse return null;
        const forced = source.payload.forced_execution;
        var quantity: i128 = forced.quantity;
        var position_delta: i128 = forced.quantity;
        var pnl: i128 = forced.realized_pnl_atoms;
        var fee: i128 = forced.fee_atoms;
        var penalty: i128 = forced.penalty_atoms;
        for (self.forced_allocations[0..self.forced_allocation_count]) |record| {
            for (record.allocation.slices[0..record.allocation.count]) |slice| {
                quantity -= slice.quantity;
                position_delta -= slice.position_delta;
                pnl = try std.math.sub(i128, pnl, slice.realized_pnl_atoms);
                fee = try std.math.sub(i128, fee, slice.fee_atoms);
                penalty = try std.math.sub(i128, penalty, slice.penalty_atoms);
            }
        }
        return .{
            .quantity = std.math.cast(i64, quantity) orelse return error.ForcedSuspenseOutOfRange,
            .position_delta = std.math.cast(i64, position_delta) orelse return error.ForcedSuspenseOutOfRange,
            .realized_pnl_atoms = pnl,
            .fee_atoms = fee,
            .penalty_atoms = penalty,
        };
    }

    pub fn ackForcedDeliveryFromShard(self: *AccountCoordinator, journal: *CoordinationJournal, delivery: Delivery, shard: *const trading.TradingShard) !void {
        var known = false;
        for (try self.pendingForcedDeliveries()) |pending| {
            if (std.meta.eql(pending, delivery)) known = true;
        }
        if (!known or !try shardHasAppliedForced(delivery, shard)) return error.ForcedDeliveryNotCommitted;
        var candidate = self.*;
        try candidate.markForcedDelivered(delivery.allocation_identity, delivery.slice_index);
        try journal.append(.{ .forced_delivery_ack = .{ .allocation_identity = delivery.allocation_identity, .slice_index = delivery.slice_index } });
        self.* = candidate;
    }

    fn markForcedDelivered(self: *AccountCoordinator, allocation_identity: u128, slice_index: u8) !void {
        for (self.forced_allocations[0..self.forced_allocation_count]) |*record| {
            if (record.allocation.identity != allocation_identity) continue;
            if (slice_index >= record.allocation.count) return error.UnknownForcedDelivery;
            record.delivered_mask |= @as(u8, 1) << @intCast(slice_index);
            try self.closeForcedBreakIfComplete();
            return;
        }
        return error.UnknownForcedDelivery;
    }

    fn closeForcedBreakIfComplete(self: *AccountCoordinator) !void {
        const source = self.forced_execution_source orelse return;
        var quantity: i128 = 0;
        var pnl: i128 = 0;
        var fee: i128 = 0;
        var penalty: i128 = 0;
        for (self.forced_allocations[0..self.forced_allocation_count]) |record| {
            if (record.delivered_mask != (@as(u8, 1) << @intCast(record.allocation.count)) - 1) return;
            for (record.allocation.slices[0..record.allocation.count]) |slice| {
                quantity += slice.quantity;
                pnl = try std.math.add(i128, pnl, slice.realized_pnl_atoms);
                fee = try std.math.add(i128, fee, slice.fee_atoms);
                penalty = try std.math.add(i128, penalty, slice.penalty_atoms);
            }
        }
        const execution = source.payload.forced_execution;
        if (quantity == execution.quantity and pnl == execution.realized_pnl_atoms and
            fee == execution.fee_atoms and penalty == execution.penalty_atoms)
        {
            self.suspense_forced_execution = null;
            self.reconciliation_break_identity = 0;
        }
    }

    /// Reconciles gross portfolio state with Venue net margin without allocating the difference.
    pub fn reconcileMargin(self: *AccountCoordinator, observation: MarginObservation) !AccountGate {
        if (observation.identity == 0 or observation.barrier < self.barrier or
            observation.venue_net_margin_atoms < 0 or observation.rules_version == 0 or
            observation.venue_spot_asset_atoms < 0 or observation.bucket_rounding_atoms < 0)
            return error.InvalidMarginObservation;
        if (self.last_margin_observation) |known| {
            if (observation.identity == known.identity) {
                if (!std.meta.eql(known, observation)) return error.MarginObservationIdentityConflict;
                return self.margin_gate;
            }
            if (observation.barrier <= known.barrier) return error.StaleMarginObservation;
        }
        const projected = try self.projectAccounts();
        const gross = try self.grossPortfolioMargin();
        self.account_netting_benefit_atoms = @max(gross - observation.venue_net_margin_atoms, 0);
        self.last_margin_observation = observation;
        self.margin_reconciliation_state = classifyObservation(projected, gross, observation);
        if (self.recovery_only) self.recovery_margin_identity = observation.identity;
        if (!self.margin_gate.latched) switch (self.margin_reconciliation_state) {
            .unknown => self.margin_gate = .{ .identity = account_margin_gate_identity, .open = false, .latched = false },
            .healthy => self.margin_gate = .{ .identity = account_margin_gate_identity, .open = true, .latched = false },
            .broken => {
                self.margin_gate = .{ .identity = account_margin_gate_identity, .open = false, .latched = true };
                try self.revokeNewRiskHeadroom();
            },
        };
        return self.margin_gate;
    }

    /// Clears the account margin latch only after healthy evidence and explicit resolution.
    pub fn resolveMarginGate(self: *AccountCoordinator, observation_identity: u128) !AccountGate {
        if (self.suspense_forced_execution != null) return error.ForcedExecutionReconciliationBreak;
        const observation = self.last_margin_observation orelse return error.MarginObservationRequired;
        if (observation.identity != observation_identity) return error.MarginObservationIdentityConflict;
        const projected = try self.projectAccounts();
        if (classifyObservation(projected, try self.grossPortfolioMargin(), observation) != .healthy)
            return error.MarginReconciliationStillBroken;
        self.margin_reconciliation_state = .healthy;
        self.margin_gate = .{ .identity = account_margin_gate_identity, .open = true, .latched = false };
        return self.margin_gate;
    }

    const AccountProjection = struct {
        swap_quantity: i64 = 0,
        spot_asset_atoms: i128 = 0,
        swap_margin_atoms: i128 = 0,
        spot_margin_atoms: i128 = 0,
        total_margin_atoms: i128 = 0,
        risk_tier: u8 = 0,
        liquidation_distance_ticks: i64 = unknown_liquidation_distance,
    };

    fn projectAccounts(self: *const AccountCoordinator) !AccountProjection {
        var projected: AccountProjection = .{};
        for (self.summaries) |record| {
            if (!record.present) return error.IncompleteShardSummaries;
            projected.swap_quantity = try std.math.add(i64, projected.swap_quantity, record.value.swap_quantity);
            projected.spot_asset_atoms = try std.math.add(i128, projected.spot_asset_atoms, record.value.spot_asset_atoms);
            projected.swap_margin_atoms = try std.math.add(i128, projected.swap_margin_atoms, record.value.exchange_margin_atoms);
            projected.spot_margin_atoms = try std.math.add(i128, projected.spot_margin_atoms, record.value.spot_margin_atoms);
            projected.total_margin_atoms = try std.math.add(i128, projected.total_margin_atoms, try std.math.add(i128, record.value.exchange_margin_atoms, record.value.spot_margin_atoms));
            projected.risk_tier = @max(projected.risk_tier, record.value.risk_tier);
            projected.liquidation_distance_ticks = @min(projected.liquidation_distance_ticks, record.value.liquidation_distance_ticks);
        }
        return projected;
    }

    fn classifyObservation(projected: AccountProjection, gross: i128, observation: MarginObservation) MarginReconciliationState {
        var inputs_known = true;
        if ((projected.liquidation_distance_ticks == unknown_liquidation_distance) !=
            (observation.venue_liquidation_distance_ticks == unknown_liquidation_distance)) inputs_known = false;
        if ((projected.risk_tier == 0) != (observation.venue_risk_tier == 0)) inputs_known = false;
        if (!inputs_known) return .unknown;
        const unit = observation.bucket_rounding_atoms;
        const explained = observation.margin_mode == .isolated and
            projected.swap_quantity == observation.venue_swap_quantity and
            projected.spot_asset_atoms == observation.venue_spot_asset_atoms and
            withinRoundingUnit(projected.swap_margin_atoms, observation.venue_swap_margin_atoms, unit) and
            withinRoundingUnit(projected.spot_margin_atoms, observation.venue_spot_margin_atoms, unit) and
            withinRoundingUnit(projected.total_margin_atoms, observation.venue_net_margin_atoms, unit) and
            projected.risk_tier == observation.venue_risk_tier and
            projected.liquidation_distance_ticks == observation.venue_liquidation_distance_ticks and
            observation.venue_net_margin_atoms <= gross;
        return if (explained) .healthy else .broken;
    }

    /// Caps every open lease at its used reservation so no shard keeps new risk headroom.
    fn revokeNewRiskHeadroom(self: *AccountCoordinator) !void {
        for (self.leases[0..self.lease_count], 0..) |*lease, index| {
            if (!lease.open) continue;
            const capped = @min(lease.limit_atoms, lease.used_atoms);
            if (capped == lease.limit_atoms) continue;
            lease.limit_atoms = capped;
            lease.version = try std.math.add(u64, lease.version, 1);
            lease.identity = try leaseIdentity(lease.version, index);
        }
    }

    /// Deterministically lowers open leases to the requested caps without ever adding headroom.
    pub fn tightenLeases(
        self: *AccountCoordinator,
        valid_through_barrier: u64,
        requested_limits: [max_shards]i128,
    ) ![]const RiskLease {
        if (self.recovery_only) return error.CoordinatorRecoveryOnly;
        if (self.lease_count != max_shards) return error.IncompleteRiskLeases;
        if (valid_through_barrier < self.barrier) return error.StaleRiskLease;
        var candidate = self.leases;
        var changed = false;
        for (&candidate, 0..) |*lease, index| {
            if (requested_limits[index] < 0) return error.InvalidRiskLease;
            if (!lease.open) continue;
            const target = @min(requested_limits[index], lease.limit_atoms);
            if (target == lease.limit_atoms and valid_through_barrier <= lease.valid_through_barrier) continue;
            lease.limit_atoms = target;
            if (valid_through_barrier > lease.valid_through_barrier) lease.valid_through_barrier = valid_through_barrier;
            lease.version = try std.math.add(u64, lease.version, 1);
            lease.identity = try leaseIdentity(lease.version, index);
            changed = true;
        }
        if (changed) self.leases = candidate;
        return self.leases[0..self.lease_count];
    }

    /// Returns stable events carrying every current lease to its owning shard.
    pub fn currentLeaseEvents(self: *const AccountCoordinator, events: *[max_shards]trading.CoreEvent) ![]const trading.CoreEvent {
        for (self.leases[0..self.lease_count], 0..) |lease, index|
            events[index] = try riskLeaseEvent(lease);
        return events[0..self.lease_count];
    }

    /// Reports whether one lease's used reservation exceeds its tightened limit.
    pub fn leaseOverTightened(self: *const AccountCoordinator, shard_id: ShardId) bool {
        if (self.lease_count != max_shards) return false;
        const lease = self.leases[@intFromEnum(shard_id)];
        return lease.open and lease.used_atoms > lease.limit_atoms;
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
        if (self.suspense_forced_execution != null) return error.ForcedExecutionReconciliationBreak;
        if (self.recovery_margin_identity == 0) return error.FreshMarginObservationRequired;
        if (!self.margin_gate.open or self.margin_gate.latched) return error.MarginReconciliationRequired;
        if (self.lease_count != max_shards) return error.IncompleteRiskLeases;
        for (self.leases[0..self.lease_count]) |lease| {
            if (!lease.open) return error.RiskLeaseClosed;
            if (lease.valid_through_barrier < self.barrier) return error.RiskLeaseExpired;
        }
        self.recovery_only = false;
    }

    /// Replays a durable pre-crash coordinator input without treating it as fresh recovery evidence.
    fn applyHistoricalEvent(self: *AccountCoordinator, event: CoordinationEvent) !void {
        const was_recovery_only = self.recovery_only;
        self.recovery_only = false;
        defer self.recovery_only = was_recovery_only;
        try self.applyEvent(event);
    }

    fn applyEvent(self: *AccountCoordinator, event: CoordinationEvent) !void {
        switch (event) {
            .publish_summary => |publish| _ = try self.publishSummary(publish.identity, publish.summary),
            .allocate_leases => |allocation| _ = try self.allocateLeases(allocation.version, allocation.valid_through_barrier),
            .account_fact => |fact| _ = try self.acceptAccountFact(fact),
            .margin_observation => |observation| _ = try self.reconcileMargin(observation),
            .resolve_margin_gate => |identity| _ = try self.resolveMarginGate(identity),
            .tighten_leases => |tightening| _ = try self.tightenLeases(tightening.valid_through_barrier, tightening.requested_limits),
            .forced_execution_allocation => |allocation| _ = try self.allocateForcedExecution(allocation),
            .forced_delivery_ack => |ack| try self.markForcedDelivered(ack.allocation_identity, ack.slice_index),
            .forced_source_checked => |checked| {
                const root = self.history_root orelse return error.CoordinatorHistoryProofRequired;
                const request = self.accountFactHistoryRequest(checked.fact, checked.proof.request.pending_id);
                switch (try history.verifyResult(request, &checked.proof, root)) {
                    .same => {},
                    .conflict => return error.AccountFactIdentityConflict,
                    .expired => return error.CoordinatorHistoryExpired,
                    .proven_first => {
                        if (checked.fact.payload == .forced_execution and self.forced_execution_source != null)
                            return error.ForcedSourceArchiveRequired;
                        _ = try self.acceptAccountFact(checked.fact);
                    },
                }
            },
            .gateway_record => |input| {
                if (input.request.exchange_account != self.exchange_account) return error.CrossAccountGatewayRequest;
                const record = gatewayRecord(input.request);
                if (self.history_root) |root| {
                    const proof = input.proof orelse return error.CoordinatorHistoryProofRequired;
                    const request = self.gatewayHistoryRequest(record, proof.request.pending_id);
                    switch (try history.verifyResult(request, &proof, root)) {
                        .same => return error.DuplicateCommandIdentity,
                        .conflict => return error.GatewayOutcomeIdentityConflict,
                        .expired => return error.CoordinatorHistoryExpired,
                        .proven_first => {},
                    }
                }
                _ = try self.gateway_ownership.record(input.request);
            },
            .gateway_retire => |retire| {
                var bytes: [1024]u8 = undefined;
                _ = &bytes;
                const qualification = retire.qualification.digest();
                const retired = retire.qualification.record;
                if (retire.qualification.source_origin.account != self.exchange_account or
                    retire.qualification.source_origin.stream.domain != .decision_log or retire.qualification.source_barrier == 0 or
                    retire.qualification.order.order.id != retired.order_id or
                    retire.qualification.order.order.revision < retired.revision) return error.InvalidCoordinatorHistoryOrigin;
                if (retire.receipt.root.origin.account != self.exchange_account or retire.receipt.root.origin.stream.domain != .control)
                    return error.InvalidCoordinatorHistoryOrigin;
                const root = try history.verifyReceipt(retire.receipt, retire.receipt.root.origin, qualification, self.history_root);
                var found: ?usize = null;
                for (self.gateway_ownership.records[0..self.gateway_ownership.count], 0..) |known, index| {
                    if (std.meta.eql(known, retired)) found = index;
                }
                const index = found orelse return error.UnknownGatewayCommand;
                const records = &self.gateway_ownership.records;
                std.mem.copyForwards(GatewayRecord, records[index .. self.gateway_ownership.count - 1], records[index + 1 .. self.gateway_ownership.count]);
                self.gateway_ownership.count -= 1;
                self.history_root = root;
            },
            .forced_history_commit => |receipt| try self.commitForcedSourceHistory(receipt),
            .forced_history_checked => |checked| {
                const root = self.history_root orelse return error.CoordinatorHistoryProofRequired;
                const request = self.allocationHistoryRequest(checked.allocation, checked.proof.request.pending_id);
                switch (try history.verifyResult(request, &checked.proof, root)) {
                    .same => {},
                    .conflict => return error.ForcedExecutionAllocationConflict,
                    .expired => return error.CoordinatorHistoryExpired,
                    .proven_first => _ = try self.allocateForcedExecutionVerified(checked.allocation),
                }
            },
        }
    }

    /// Encodes coordination-owned state at its exact barrier without shard internals.
    pub fn snapshot(self: *const AccountCoordinator, destination: []u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(destination);
        try writer.writeInt(u64, snapshot_magic, .little);
        try writer.writeInt(u16, coordinator_snapshot_version, .little);
        try writer.writeInt(u128, self.exchange_account, .little);
        try writer.writeInt(i128, self.account_safety_ceiling_atoms, .little);
        try writer.writeInt(i128, self.global_ceiling_atoms, .little);
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
        try writer.writeInt(i128, self.account_netting_benefit_atoms, .little);
        try writer.writeByte(@intFromBool(self.recovery_only));
        try writeOptionalAccountFact(&writer, self.last_account_fact);
        try writeOptionalAccountFact(&writer, self.suspense_forced_execution);
        try writer.writeInt(u128, self.reconciliation_break_identity, .little);
        try writeOptionalAccountFact(&writer, self.forced_execution_source);
        for (self.forced_source_positions) |position| try writer.writeInt(i64, position, .little);
        for (self.forced_source_owners) |owner| {
            try writer.writeInt(u128, owner.portfolio, .little);
            try writer.writeInt(u128, owner.decision_domain, .little);
        }
        try writer.writeByte(self.forced_allocation_count);
        for (self.forced_allocations[0..self.forced_allocation_count]) |record| {
            try writeForcedAllocation(&writer, record.allocation);
            try writer.writeByte(record.delivered_mask);
        }
        try writer.writeByte(self.completed_forced_allocation_count);
        for (self.completed_forced_allocations[0..self.completed_forced_allocation_count]) |allocation|
            try writeForcedAllocation(&writer, allocation);
        try writeOptionalMarginObservation(&writer, self.last_margin_observation);
        try writer.writeInt(u128, self.margin_gate.identity, .little);
        try writer.writeByte(@intFromBool(self.margin_gate.open));
        try writer.writeByte(@intFromBool(self.margin_gate.latched));
        try writer.writeByte(@intFromEnum(self.margin_reconciliation_state));
        var root_bytes: [1024]u8 = undefined;
        const encoded_root = try codec.encodeBare(&root_bytes, self.history_root);
        try writer.writeInt(u16, @intCast(encoded_root.len), .little);
        try writer.writeAll(encoded_root);
        try writer.writeInt(u128, self.gateway_ownership.exchange_account, .little);
        try writer.writeByte(self.gateway_ownership.count);
        for (self.gateway_ownership.latest_fencing_tokens) |token| try writer.writeInt(u64, token, .little);
        for (self.gateway_ownership.records[0..self.gateway_ownership.count]) |record| {
            var record_bytes: [1024]u8 = undefined;
            const encoded_record = try codec.encodeBare(&record_bytes, record);
            try writer.writeInt(u16, @intCast(encoded_record.len), .little);
            try writer.writeAll(encoded_record);
        }
        const digest_value = self.digest();
        try writer.writeAll(&digest_value);
        return writer.buffered();
    }

    /// Restores a validated coordination snapshot into RecoveryOnly account authority.
    pub fn restore(encoded: []const u8) !AccountCoordinator {
        var reader: std.Io.Reader = .fixed(encoded);
        if (try reader.takeInt(u64, .little) != snapshot_magic or
            try reader.takeInt(u16, .little) != coordinator_snapshot_version)
            return error.InvalidCoordinatorSnapshot;
        var result = AccountCoordinator.init(
            try reader.takeInt(u128, .little),
            try reader.takeInt(i128, .little),
            try reader.takeInt(i128, .little),
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
        result.account_netting_benefit_atoms = try reader.takeInt(i128, .little);
        result.recovery_only = try readBool(&reader);
        result.last_account_fact = try readOptionalAccountFact(&reader);
        result.suspense_forced_execution = try readOptionalAccountFact(&reader);
        result.reconciliation_break_identity = try reader.takeInt(u128, .little);
        result.forced_execution_source = try readOptionalAccountFact(&reader);
        for (&result.forced_source_positions) |*position| position.* = try reader.takeInt(i64, .little);
        for (&result.forced_source_owners) |*owner| {
            owner.portfolio = try reader.takeInt(u128, .little);
            owner.decision_domain = try reader.takeInt(u128, .little);
        }
        result.forced_allocation_count = try reader.takeByte();
        if (result.forced_allocation_count > max_shards) return error.InvalidCoordinatorSnapshot;
        for (result.forced_allocations[0..result.forced_allocation_count]) |*record| {
            record.allocation = try readForcedAllocation(&reader);
            record.delivered_mask = try reader.takeByte();
            if (record.delivered_mask >> @intCast(record.allocation.count) != 0) return error.InvalidCoordinatorSnapshot;
        }
        result.completed_forced_allocation_count = try reader.takeByte();
        if (result.completed_forced_allocation_count > max_completed_forced_allocations) return error.InvalidCoordinatorSnapshot;
        for (result.completed_forced_allocations[0..result.completed_forced_allocation_count]) |*allocation|
            allocation.* = try readForcedAllocation(&reader);
        result.last_margin_observation = try readOptionalMarginObservation(&reader);
        result.margin_gate = .{
            .identity = try reader.takeInt(u128, .little),
            .open = try readBool(&reader),
            .latched = try readBool(&reader),
        };
        result.margin_reconciliation_state = std.enums.fromInt(
            MarginReconciliationState,
            try reader.takeByte(),
        ) orelse return error.InvalidCoordinatorSnapshot;
        const root_len = try reader.takeInt(u16, .little);
        result.history_root = try codec.decodeBare(try reader.take(root_len), ?history.Root);
        if (result.history_root) |root| {
            try history.validateRoot(root);
            if (root.origin.account != result.exchange_account or root.origin.stream.domain != .control)
                return error.InvalidCoordinatorSnapshot;
        }
        result.gateway_ownership.exchange_account = try reader.takeInt(u128, .little);
        result.gateway_ownership.count = try reader.takeByte();
        if (result.gateway_ownership.count > result.gateway_ownership.records.len or
            (result.gateway_ownership.exchange_account != 0 and result.gateway_ownership.exchange_account != result.exchange_account))
            return error.InvalidCoordinatorSnapshot;
        for (&result.gateway_ownership.latest_fencing_tokens) |*token| token.* = try reader.takeInt(u64, .little);
        for (result.gateway_ownership.records[0..result.gateway_ownership.count]) |*record| {
            const record_len = try reader.takeInt(u16, .little);
            record.* = try codec.decodeBare(try reader.take(record_len), GatewayRecord);
            if (record.exchange_account != result.exchange_account or record.command_id == 0 or record.fencing_token == 0 or
                record.fencing_token > result.gateway_ownership.latest_fencing_tokens[@intFromEnum(record.shard_id)])
                return error.InvalidCoordinatorSnapshot;
        }
        const expected = try reader.take(32);
        const encoded_digest = result.digest();
        if (reader.seek != encoded.len or !std.mem.eql(u8, expected, &encoded_digest))
            return error.InvalidCoordinatorSnapshot;
        result.recovery_only = true;
        result.recovery_margin_identity = 0;
        return result;
    }
};

fn coordinationEventType(event: CoordinationEvent) u16 {
    return switch (event) {
        .publish_summary => 1,
        .allocate_leases => 2,
        .account_fact => 3,
        .margin_observation => 4,
        .resolve_margin_gate => 5,
        .tighten_leases => 6,
        .forced_execution_allocation => 7,
        .forced_delivery_ack => 8,
        .forced_history_commit => 9,
        .forced_history_checked => 10,
        .gateway_record => 11,
        .gateway_retire => 12,
        .forced_source_checked => 13,
    };
}

fn writeScalar(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    if (T == bool)
        try writer.writeByte(@intFromBool(value))
    else if (@typeInfo(T) == .@"enum")
        try writer.writeInt(@typeInfo(T).@"enum".tag_type, @intFromEnum(value), .little)
    else
        try writer.writeInt(T, value, .little);
}

fn readScalar(reader: *std.Io.Reader, comptime T: type) !T {
    if (T == bool) return readBool(reader);
    if (@typeInfo(T) == .@"enum")
        return std.enums.fromInt(T, try reader.takeInt(@typeInfo(T).@"enum".tag_type, .little)) orelse error.InvalidCoordinationTail;
    return reader.takeInt(T, .little);
}

fn writePlainStruct(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    inline for (@typeInfo(T).@"struct".fields) |field|
        try writeScalar(writer, field.type, @field(value, field.name));
}

fn readPlainStruct(reader: *std.Io.Reader, comptime T: type) !T {
    var value: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field|
        @field(value, field.name) = try readScalar(reader, field.type);
    return value;
}

fn writeForcedAllocation(writer: *std.Io.Writer, allocation: ForcedExecutionAllocation) !void {
    try writer.writeInt(u128, allocation.identity, .little);
    try writer.writeInt(u128, allocation.forced_execution_identity, .little);
    try writer.writeByte(allocation.count);
    for (allocation.slices[0..allocation.count]) |slice| try writePlainStruct(writer, ForcedExecutionSlice, slice);
}

fn readForcedAllocation(reader: *std.Io.Reader) !ForcedExecutionAllocation {
    var allocation: ForcedExecutionAllocation = .{
        .identity = try reader.takeInt(u128, .little),
        .forced_execution_identity = try reader.takeInt(u128, .little),
        .count = try reader.takeByte(),
    };
    if (allocation.count == 0 or allocation.count > max_shards) return error.InvalidCoordinationTail;
    for (allocation.slices[0..allocation.count]) |*slice| slice.* = try readPlainStruct(reader, ForcedExecutionSlice);
    return allocation;
}

fn writeAccountFact(writer: *std.Io.Writer, fact: AccountFact) !void {
    try writer.writeInt(u128, fact.identity, .little);
    try writer.writeInt(u128, fact.exchange_account, .little);
    try writer.writeInt(u64, fact.version, .little);
    try writer.writeInt(u64, fact.barrier, .little);
    try writer.writeByte(@intFromBool(fact.times != null));
    if (fact.times) |times| {
        try writer.writeInt(u64, times.source, .little);
        try writer.writeInt(u64, times.receive, .little);
        try writer.writeInt(u64, times.monotonic, .little);
        try writer.writeInt(u64, times.wall, .little);
        try writer.writeByte(@bitCast(times.presence));
    }
    switch (fact.payload) {
        .account_snapshot => |snapshot| {
            try writer.writeByte(0);
            try writePlainStruct(writer, @TypeOf(snapshot), snapshot);
        },
        .forced_execution => |execution| {
            try writer.writeByte(1);
            try writer.writeByte(@intFromBool(execution.owner != null));
            if (execution.owner) |owner| try writeScalar(writer, ShardId, owner);
            try writer.writeInt(i64, execution.quantity, .little);
            try writer.writeInt(i64, execution.price_ticks, .little);
            try writer.writeInt(i128, execution.realized_pnl_atoms, .little);
            try writer.writeInt(i128, execution.fee_atoms, .little);
            try writer.writeInt(i128, execution.penalty_atoms, .little);
        },
    }
}

fn readAccountFact(reader: *std.Io.Reader) !AccountFact {
    const identity = try reader.takeInt(u128, .little);
    const exchange_account = try reader.takeInt(u128, .little);
    const version = try reader.takeInt(u64, .little);
    const barrier = try reader.takeInt(u64, .little);
    const times: ?@import("economics.zig").FundingCoreTimes = if (try readBool(reader)) .{
        .source = try reader.takeInt(u64, .little),
        .receive = try reader.takeInt(u64, .little),
        .monotonic = try reader.takeInt(u64, .little),
        .wall = try reader.takeInt(u64, .little),
        .presence = @bitCast(try reader.takeByte()),
    } else null;
    const payload: AccountFactPayload = switch (try reader.takeByte()) {
        0 => .{ .account_snapshot = try readPlainStruct(reader, @FieldType(AccountFactPayload, "account_snapshot")) },
        1 => .{ .forced_execution = .{
            .owner = if (try readBool(reader)) try readScalar(reader, ShardId) else null,
            .quantity = try reader.takeInt(i64, .little),
            .price_ticks = try reader.takeInt(i64, .little),
            .realized_pnl_atoms = try reader.takeInt(i128, .little),
            .fee_atoms = try reader.takeInt(i128, .little),
            .penalty_atoms = try reader.takeInt(i128, .little),
        } },
        else => return error.InvalidCoordinationTail,
    };
    return .{ .identity = identity, .exchange_account = exchange_account, .version = version, .barrier = barrier, .times = times, .payload = payload };
}

fn encodeCoordinationEvent(destination: []u8, event: CoordinationEvent) ![]const u8 {
    var writer: std.Io.Writer = .fixed(destination);
    switch (event) {
        .publish_summary => |publish| {
            try writer.writeInt(u128, publish.identity, .little);
            try writePlainStruct(&writer, ShardSummary, publish.summary);
        },
        .allocate_leases => |allocation| {
            try writer.writeInt(u64, allocation.version, .little);
            try writer.writeInt(u64, allocation.valid_through_barrier, .little);
        },
        .account_fact => |fact| try writeAccountFact(&writer, fact),
        .margin_observation => |observation| try writePlainStruct(&writer, MarginObservation, observation),
        .resolve_margin_gate => |identity| try writer.writeInt(u128, identity, .little),
        .tighten_leases => |tightening| {
            try writer.writeInt(u64, tightening.valid_through_barrier, .little);
            for (tightening.requested_limits) |limit| try writer.writeInt(i128, limit, .little);
        },
        .forced_execution_allocation => |allocation| try writeForcedAllocation(&writer, allocation),
        .forced_delivery_ack => |ack| {
            try writer.writeInt(u128, ack.allocation_identity, .little);
            try writer.writeByte(ack.slice_index);
        },
        .forced_history_commit => |receipt| return codec.encodeBare(destination, receipt),
        .forced_history_checked => |checked| return codec.encodeBare(destination, checked),
        .gateway_record => |request| return codec.encodeBare(destination, request),
        .gateway_retire => |retire| return codec.encodeBare(destination, retire),
        .forced_source_checked => |checked| return codec.encodeBare(destination, checked),
    }
    return writer.buffered();
}

fn decodeCoordinationEvent(record: trading.journal.Record) !CoordinationEvent {
    if (record.schema_version != @import("production_contract.zig").journal_schema_version or record.flags != trading.journal.input_flag)
        return error.InvalidCoordinationTail;
    var reader: std.Io.Reader = .fixed(record.payload);
    const event: CoordinationEvent = switch (record.type_id) {
        1 => .{ .publish_summary = .{
            .identity = try reader.takeInt(u128, .little),
            .summary = try readPlainStruct(&reader, ShardSummary),
        } },
        2 => .{ .allocate_leases = .{
            .version = try reader.takeInt(u64, .little),
            .valid_through_barrier = try reader.takeInt(u64, .little),
        } },
        3 => .{ .account_fact = try readAccountFact(&reader) },
        4 => .{ .margin_observation = try readPlainStruct(&reader, MarginObservation) },
        5 => .{ .resolve_margin_gate = try reader.takeInt(u128, .little) },
        6 => blk: {
            var requested_limits: [max_shards]i128 = undefined;
            const valid_through_barrier = try reader.takeInt(u64, .little);
            for (&requested_limits) |*limit| limit.* = try reader.takeInt(i128, .little);
            break :blk .{ .tighten_leases = .{ .valid_through_barrier = valid_through_barrier, .requested_limits = requested_limits } };
        },
        7 => .{ .forced_execution_allocation = try readForcedAllocation(&reader) },
        8 => .{ .forced_delivery_ack = .{ .allocation_identity = try reader.takeInt(u128, .little), .slice_index = try reader.takeByte() } },
        9 => return .{ .forced_history_commit = try codec.decodeBare(record.payload, history.Receipt) },
        10 => return .{ .forced_history_checked = try codec.decodeBare(record.payload, @FieldType(CoordinationEvent, "forced_history_checked")) },
        11 => return .{ .gateway_record = try codec.decodeBare(record.payload, @FieldType(CoordinationEvent, "gateway_record")) },
        12 => return .{ .gateway_retire = try codec.decodeBare(record.payload, @FieldType(CoordinationEvent, "gateway_retire")) },
        13 => return .{ .forced_source_checked = try codec.decodeBare(record.payload, @FieldType(CoordinationEvent, "forced_source_checked")) },
        else => return error.InvalidCoordinationTail,
    };
    if (reader.seek != record.payload.len) return error.InvalidCoordinationTail;
    return event;
}

fn replayCoordinationTail(coordinator: *AccountCoordinator, encoded: []const u8) !void {
    var reader = try trading.journal.Reader.init(encoded);
    while (true) switch (try reader.next()) {
        .record => |record| try coordinator.applyHistoricalEvent(try decodeCoordinationEvent(record)),
        .end => |status| {
            if (status != .clean) return error.TruncatedCoordinationTail;
            return;
        },
    };
}

/// Recovery-only bundle tying one coordinator snapshot to four restored shard barriers.
pub const AccountRecovery = struct {
    coordinator: AccountCoordinator,
    shards: [max_shards]trading.TradingShard,
    shard_barriers: [max_shards]u64,
    summary_refresh_mask: u8 = 0,

    /// Restores all five authoritative snapshots before any Venue reconciliation.
    pub fn begin(
        coordinator_snapshot: []const u8,
        shard_snapshots: [max_shards][]const u8,
        shard_tails: [max_shards][]const u8,
    ) !AccountRecovery {
        var empty_tail = CoordinationJournal.initAt(1);
        try empty_tail.seal();
        return beginWithCoordinatorTail(coordinator_snapshot, empty_tail.bytes(), shard_snapshots, shard_tails);
    }

    /// Restores a coordinator snapshot and its durable input tail before validating shard recovery.
    pub fn beginWithCoordinatorTail(
        coordinator_snapshot: []const u8,
        coordinator_tail: []const u8,
        shard_snapshots: [max_shards][]const u8,
        shard_tails: [max_shards][]const u8,
    ) !AccountRecovery {
        var result: AccountRecovery = undefined;
        try beginWithCoordinatorTailInto(&result, coordinator_snapshot, coordinator_tail, shard_snapshots, shard_tails);
        return result;
    }

    /// Failure may modify this destination; publish it only after every shard validates.
    pub fn beginWithCoordinatorTailInto(
        result: *AccountRecovery,
        coordinator_snapshot: []const u8,
        coordinator_tail: []const u8,
        shard_snapshots: [max_shards][]const u8,
        shard_tails: [max_shards][]const u8,
    ) !void {
        result.coordinator = try AccountCoordinator.restore(coordinator_snapshot);
        result.summary_refresh_mask = 0;
        try replayCoordinationTail(&result.coordinator, coordinator_tail);
        for (0..max_shards) |index| {
            const recovered = try trading.TradingShard.restoreSegmentsInto(&result.shards[index], shard_snapshots[index], &.{shard_tails[index]});
            result.shards[index].operational_state.trading_authorized = false;
            result.shards[index].operational_state.mode = .recovering;
            result.shard_barriers[index] = recovered.barrier;
            const summary = result.coordinator.summaries[index];
            if (!summary.present) return error.AccountRecoveryBarrierMismatch;
            const derived = try shardSummaryFromShard(
                &result.shards[index],
                @enumFromInt(index),
                summary.value.shard_sequence,
                summary.value.decision_domain,
            );
            if (!std.meta.eql(derived, summary.value)) {
                if (!try forcedTailExplainsSummaryChange(&result.coordinator, @enumFromInt(index), shard_snapshots[index], shard_tails[index], summary.value))
                    return error.AccountRecoveryBarrierMismatch;
                result.summary_refresh_mask |= @as(u8, 1) << @intCast(index);
            }
        }
        for (try result.coordinator.forcedDeliveries(true)) |delivery| {
            for (result.coordinator.forced_allocations[0..result.coordinator.forced_allocation_count]) |record| {
                if (record.allocation.identity != delivery.allocation_identity) continue;
                if (record.delivered_mask & (@as(u8, 1) << @intCast(delivery.slice_index)) == 0) break;
                if (!try shardHasAppliedForced(delivery, &result.shards[@intFromEnum(delivery.shard_id)]))
                    return error.ForcedDeliveryAckWithoutShardCommit;
                break;
            }
        }
    }

    /// Releases only the coordinator fence; each shard still requires Venue recovery and enable.
    pub fn completeCoordinatorRecovery(self: *AccountRecovery) !void {
        for (0..max_shards) |index| {
            if (self.summary_refresh_mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
            const summary = self.coordinator.summaries[index];
            if (!summary.present) return error.AccountRecoveryBarrierMismatch;
            const derived = try shardSummaryFromShard(
                &self.shards[index],
                @enumFromInt(index),
                summary.value.shard_sequence,
                summary.value.decision_domain,
            );
            if (!std.meta.eql(derived, summary.value)) return error.FreshShardSummaryRequired;
        }
        try self.coordinator.completeRecovery();
        for (self.shards) |shard| if (shard.operational_state.mode != .recovering)
            return error.ShardRecoveryFenceLost;
    }
};

fn leaseIdentity(version: u64, index: usize) !u128 {
    return std.math.add(u128, try std.math.mul(u128, version, max_shards), index + 1);
}

fn withinRoundingUnit(projected: i128, venue: i128, unit: i128) bool {
    if (unit <= 0) return projected == venue;
    return venue >= projected -| unit and venue <= projected +| unit;
}

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
    hasher.update(&.{@intFromBool(value.times != null)});
    if (value.times) |times| {
        digestInt(hasher, u64, times.source);
        digestInt(hasher, u64, times.receive);
        digestInt(hasher, u64, times.monotonic);
        digestInt(hasher, u64, times.wall);
        hasher.update(&.{@as(u8, @bitCast(times.presence))});
    }
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
            digestInt(hasher, i64, execution.price_ticks);
            digestInt(hasher, i128, execution.realized_pnl_atoms);
            digestInt(hasher, i128, execution.fee_atoms);
            digestInt(hasher, i128, execution.penalty_atoms);
        },
    }
}

fn digestOptionalMarginObservation(hasher: *Sha256, observation: ?MarginObservation) void {
    hasher.update(&.{@intFromBool(observation != null)});
    if (observation) |value| digestStruct(hasher, MarginObservation, value);
}

fn writeOptionalAccountFact(writer: *std.Io.Writer, fact: ?AccountFact) !void {
    try writer.writeByte(@intFromBool(fact != null));
    if (fact) |value| try writeAccountFact(writer, value);
}

fn readOptionalAccountFact(reader: *std.Io.Reader) !?AccountFact {
    if (!try readBool(reader)) return null;
    return readAccountFact(reader) catch return error.InvalidCoordinatorSnapshot;
}

fn writeOptionalMarginObservation(writer: *std.Io.Writer, observation: ?MarginObservation) !void {
    try writer.writeByte(@intFromBool(observation != null));
    if (observation) |value| {
        try writer.writeInt(u128, value.identity, .little);
        try writer.writeInt(u64, value.barrier, .little);
        try writer.writeInt(i128, value.venue_net_margin_atoms, .little);
        try writer.writeInt(i64, value.venue_swap_quantity, .little);
        try writer.writeInt(i128, value.venue_spot_asset_atoms, .little);
        try writer.writeInt(i128, value.venue_spot_margin_atoms, .little);
        try writer.writeInt(i128, value.venue_swap_margin_atoms, .little);
        try writer.writeByte(@intFromEnum(value.margin_mode));
        try writer.writeInt(u32, value.rules_version, .little);
        try writer.writeByte(value.venue_risk_tier);
        try writer.writeInt(i64, value.venue_liquidation_distance_ticks, .little);
        try writer.writeInt(i128, value.bucket_rounding_atoms, .little);
    }
}

fn readOptionalMarginObservation(reader: *std.Io.Reader) !?MarginObservation {
    if (!try readBool(reader)) return null;
    return .{
        .identity = try reader.takeInt(u128, .little),
        .barrier = try reader.takeInt(u64, .little),
        .venue_net_margin_atoms = try reader.takeInt(i128, .little),
        .venue_swap_quantity = try reader.takeInt(i64, .little),
        .venue_spot_asset_atoms = try reader.takeInt(i128, .little),
        .venue_spot_margin_atoms = try reader.takeInt(i128, .little),
        .venue_swap_margin_atoms = try reader.takeInt(i128, .little),
        .margin_mode = std.enums.fromInt(AccountMarginMode, try reader.takeByte()) orelse return error.InvalidCoordinatorSnapshot,
        .rules_version = try reader.takeInt(u32, .little),
        .venue_risk_tier = try reader.takeByte(),
        .venue_liquidation_distance_ticks = try reader.takeInt(i64, .little),
        .bucket_rounding_atoms = try reader.takeInt(i128, .little),
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
    conflict.reservation_atoms += 1;
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
    var total: i128 = 0;
    for (leases) |lease| total += lease.limit_atoms;
    try std.testing.expectEqual(@as(i64, 1_000), total);
    try std.testing.expectEqual(@as(i64, 0), coordinator.account_netting_benefit_atoms);
}

test "failed risk lease allocation is atomic and gross overflow fails closed" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    for (0..max_shards) |index| {
        const reservation: i128 = if (index == 2) 251 else 100;
        _ = try coordinator.publishSummary(index + 1, ShardSummary.fixture(@enumFromInt(index), 1, reservation));
    }
    const before = coordinator.digest();
    try std.testing.expectError(error.RiskLeaseOversubscribed, coordinator.allocateLeases(1, 10));
    try std.testing.expectEqual(@as(u8, 0), coordinator.lease_count);
    try std.testing.expectEqualSlices(u8, &before, &coordinator.digest());

    var overflowing = AccountCoordinator.init(900, std.math.maxInt(i128), std.math.maxInt(i128));
    for (0..max_shards) |index| {
        const reservation: i128 = if (index < 2) std.math.maxInt(i128) else 0;
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
        .payload = .{ .account_snapshot = .{ .cash_atoms = 800, .swap_quantity = 0, .margin_atoms = 100 } },
    });
    try std.testing.expectEqual(@as(usize, 4), deliveries.len);
    for (deliveries, 0..) |delivery, index| try std.testing.expectEqual(@as(ShardId, @enumFromInt(index)), delivery.shard_id);
    try std.testing.expectEqual(@as(usize, 0), (try coordinator.acceptAccountFact(.{
        .identity = 7,
        .exchange_account = 900,
        .version = 1,
        .barrier = 1,
        .payload = .{ .account_snapshot = .{ .cash_atoms = 800, .swap_quantity = 0, .margin_atoms = 100 } },
    })).len);
}

test "margin reconciliation preserves netting benefit but latches unexplained differences" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    for (0..max_shards) |index| {
        var summary = ShardSummary.fixture(@enumFromInt(index), 1, 100);
        summary.exchange_margin_atoms = if (index < 2) 63 else 62;
        _ = try coordinator.publishSummary(index + 1, summary);
    }
    const healthy = try coordinator.reconcileMargin(.{ .identity = 20, .barrier = 5, .venue_net_margin_atoms = 250, .venue_swap_margin_atoms = 250, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 });
    try std.testing.expect(healthy.open);
    try std.testing.expectEqual(@as(i64, 150), coordinator.account_netting_benefit_atoms);
    try std.testing.expectEqual(@as(i64, 400), try coordinator.grossPortfolioMargin());
    const broken = try coordinator.reconcileMargin(.{ .identity = 21, .barrier = 6, .venue_net_margin_atoms = 250, .venue_swap_margin_atoms = 250, .venue_swap_quantity = 1, .margin_mode = .isolated, .rules_version = 1 });
    try std.testing.expect(!broken.open);
    try std.testing.expect(broken.latched);
    const still_latched = try coordinator.reconcileMargin(.{ .identity = 22, .barrier = 7, .venue_net_margin_atoms = 250, .venue_swap_margin_atoms = 250, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 });
    try std.testing.expect(still_latched.latched);
    const resolved = try coordinator.resolveMarginGate(22);
    try std.testing.expect(resolved.open);
    try std.testing.expect(!resolved.latched);
    _ = try coordinator.acceptAccountFact(.{ .identity = 30, .exchange_account = 900, .version = 1, .barrier = 1, .payload = .{ .forced_execution = .{ .owner = null, .quantity = -1, .price_ticks = 100, .fee_atoms = 0 } } });
    const held = try coordinator.reconcileMargin(.{ .identity = 23, .barrier = 8, .venue_net_margin_atoms = 250, .venue_swap_margin_atoms = 250, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 });
    try std.testing.expect(held.latched);
    try std.testing.expectError(error.ForcedExecutionReconciliationBreak, coordinator.resolveMarginGate(23));
    try std.testing.expectError(error.ForcedExecutionReconciliationBreak, coordinator.completeRecovery());
}

test "unowned economics stay in suspense until an immutable allocation" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    var summary = ShardSummary.fixture(.shard_0, 1, 100);
    summary.swap_quantity = 1;
    _ = try coordinator.publishSummary(1, summary);
    const deliveries = try coordinator.acceptAccountFact(.{
        .identity = 33,
        .exchange_account = 900,
        .version = 1,
        .barrier = 1,
        .payload = .{ .forced_execution = .{ .owner = null, .quantity = -1, .price_ticks = 100, .fee_atoms = 1 } },
    });
    try std.testing.expectEqual(@as(usize, 0), deliveries.len);
    try std.testing.expect(coordinator.suspense_forced_execution != null);
    try std.testing.expect(coordinator.margin_gate.latched);
    const before_capacity_reject = coordinator.digest();
    try std.testing.expectError(error.SuspenseAccountCapacityExceeded, coordinator.acceptAccountFact(.{
        .identity = 34,
        .exchange_account = 900,
        .version = 1,
        .barrier = 2,
        .payload = .{ .forced_execution = .{ .owner = null, .quantity = -2, .price_ticks = 100, .fee_atoms = 1 } },
    }));
    try std.testing.expectEqualSlices(u8, &before_capacity_reject, &coordinator.digest());

    var snapshot_storage: [4096]u8 = undefined;
    const snapshot_bytes = try coordinator.snapshot(&snapshot_storage);
    var recovered = try AccountCoordinator.restore(snapshot_bytes);
    try std.testing.expect(recovered.suspense_forced_execution != null);
    try std.testing.expectEqual(@as(u128, 33), recovered.reconciliation_break_identity);

    var allocation: ForcedExecutionAllocation = .{ .identity = 34, .forced_execution_identity = 33, .count = 1 };
    allocation.slices[0] = .{ .owner = .shard_0, .quantity = -1, .position_delta = -1, .fee_atoms = 1 };
    const allocated = try coordinator.allocateForcedExecution(allocation);
    try std.testing.expectEqual(ShardId.shard_0, allocated[0].shard_id);
    const recovered_allocation = try recovered.allocateForcedExecution(allocation);
    try std.testing.expectEqual(ShardId.shard_0, recovered_allocation[0].shard_id);
    try std.testing.expectEqualSlices(u8, &coordinator.digest(), &recovered.digest());
    try std.testing.expectEqual(ShardId.shard_0, (try recovered.allocateForcedExecution(allocation))[0].shard_id);

    const shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(shard);
    shard.* = .{};
    shard.operational_state = trading.operational.State.init(100);
    var stable_journal = trading.journal.Journal.init();
    _ = try applyCoreStable(shard, &stable_journal, .{ .identity = 1, .payload = .{ .instrument_rules_activated = .{
        .version = 1,
        .instrument_identity = 3,
        .quantity_denominator = 1,
        .reservation_model = .leveraged,
        .product = .isolated_linear_usdt,
        .venue = 1,
    } } });
    _ = try applyCoreStable(shard, &stable_journal, .{ .identity = 2, .payload = .{ .margin_rules_activated = .{
        .version = 1,
        .instrument = 3,
    } } });
    try std.testing.expectEqual(@as(u128, 33), allocated[0].source_identity);
    const gate_delivery: GateDelivery = .{ .shard_id = .shard_0, .gate = .{ .identity = 44, .open = false, .latched = true } };
    try applyAccountGateStable(gate_delivery, .shard_0, shard, &stable_journal);
    try std.testing.expect(!shard.operational_state.effectiveTradingAuthority());
    try std.testing.expect(shard.operational_state.latch_count > 0);
}

test "caller owner cannot directly route forced execution" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    const deliveries = try coordinator.acceptAccountFact(.{
        .identity = 50,
        .exchange_account = 900,
        .version = 1,
        .barrier = 1,
        .payload = .{ .forced_execution = .{ .owner = .shard_0, .quantity = -1, .price_ticks = 100, .fee_atoms = 1 } },
    });
    try std.testing.expectEqual(@as(usize, 0), deliveries.len);
    try std.testing.expectEqual(@as(u128, 50), coordinator.suspense_forced_execution.?.identity);
    try std.testing.expect(coordinator.margin_gate.latched);
    var forged: Delivery = .{ .shard_id = .shard_0, .fact = coordinator.suspense_forced_execution.?, .allocation_identity = 1, .source_identity = 50 };
    const shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(shard);
    shard.* = .{};
    var journal = trading.journal.Journal.init();
    try std.testing.expectError(error.ForcedAllocationRequired, applyAccountFactStable(forged, .shard_0, shard, &journal));
    forged.allocation_identity = 0;
    try std.testing.expectError(error.UnallocatedForcedExecution, accountFactEvent(forged));
}

test "completed forced allocation survives the next source and snapshot" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    var summary = ShardSummary.fixture(.shard_0, 1, 100);
    summary.swap_quantity = 1;
    _ = try coordinator.publishSummary(1, summary);
    _ = try coordinator.acceptAccountFact(.{ .identity = 80, .exchange_account = 900, .version = 1, .barrier = 1, .payload = .{ .forced_execution = .{ .owner = null, .quantity = -1, .price_ticks = 100, .fee_atoms = 0 } } });
    var old: ForcedExecutionAllocation = .{ .identity = 81, .forced_execution_identity = 80, .count = 1 };
    old.slices[0] = .{ .owner = .shard_0, .quantity = -1, .position_delta = -1 };
    _ = try coordinator.allocateForcedExecution(old);
    try coordinator.markForcedDelivered(81, 0);
    _ = try coordinator.acceptAccountFact(.{ .identity = 82, .exchange_account = 900, .version = 2, .barrier = 2, .payload = .{ .forced_execution = .{ .owner = null, .quantity = -1, .price_ticks = 100, .fee_atoms = 0 } } });
    try std.testing.expectEqual(@as(usize, 0), (try coordinator.allocateForcedExecution(old)).len);
    var storage: [16384]u8 = undefined;
    var restored = try AccountCoordinator.restore(try coordinator.snapshot(&storage));
    try std.testing.expectEqual(@as(usize, 0), (try restored.allocateForcedExecution(old)).len);
    try std.testing.expectEqualSlices(u8, &coordinator.digest(), &restored.digest());
}

test "multi-owner forced allocation survives newer account facts and delivery replay" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    var long = ShardSummary.fixture(.shard_0, 1, 100);
    long.swap_quantity = 3;
    var short = ShardSummary.fixture(.shard_1, 1, 100);
    short.swap_quantity = -1;
    _ = try coordinator.publishSummary(1, long);
    _ = try coordinator.publishSummary(2, short);
    const source: AccountFact = .{ .identity = 33, .exchange_account = 900, .version = 1, .barrier = 1, .payload = .{ .forced_execution = .{ .owner = .shard_0, .quantity = -2, .price_ticks = 100, .realized_pnl_atoms = 5, .fee_atoms = 3, .penalty_atoms = 2 } } };
    try std.testing.expectEqual(@as(usize, 0), (try coordinator.acceptAccountFact(source)).len);
    var snapshot_storage: [4096]u8 = undefined;
    const snapshot_bytes = try coordinator.snapshot(&snapshot_storage);
    var tail = CoordinationJournal.initAt(1);
    var allocation: ForcedExecutionAllocation = .{ .identity = 34, .forced_execution_identity = 33, .count = 2 };
    allocation.slices[0] = .{ .owner = .shard_0, .quantity = -3, .position_delta = -3, .realized_pnl_atoms = 10, .fee_atoms = 2, .penalty_atoms = 1 };
    allocation.slices[1] = .{ .owner = .shard_1, .quantity = 1, .position_delta = 1, .realized_pnl_atoms = -5, .fee_atoms = 1, .penalty_atoms = 1 };
    var over_fee = allocation;
    over_fee.identity = 35;
    over_fee.slices[1].fee_atoms = 2;
    try std.testing.expectError(error.ForcedExecutionAllocationNotConserved, coordinator.allocateForcedExecution(over_fee));
    try std.testing.expectEqual(@as(usize, 2), (try coordinator.commitForcedAllocation(&tail, allocation)).len);
    const newer: AccountFact = .{ .identity = 40, .exchange_account = 900, .version = 2, .barrier = 2, .payload = .{ .account_snapshot = .{ .cash_atoms = 1_000, .swap_quantity = -2, .margin_atoms = 0 } } };
    try tail.append(.{ .account_fact = newer });
    _ = try coordinator.acceptAccountFact(newer);
    try std.testing.expectEqual(@as(u128, 33), (try coordinator.pendingForcedDeliveries())[0].source_identity);
    try tail.append(.{ .forced_delivery_ack = .{ .allocation_identity = 34, .slice_index = 0 } });
    try coordinator.markForcedDelivered(34, 0);
    try std.testing.expectEqual(@as(usize, 1), (try coordinator.pendingForcedDeliveries()).len);
    try tail.seal();
    var recovered = try AccountCoordinator.restore(snapshot_bytes);
    try replayCoordinationTail(&recovered, tail.bytes());
    try std.testing.expectEqualSlices(u8, &coordinator.digest(), &recovered.digest());
    const pending = try recovered.pendingForcedDeliveries();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(ShardId.shard_1, pending[0].shard_id);
    try recovered.markForcedDelivered(34, 1);
    try std.testing.expect(recovered.suspense_forced_execution == null);
    try std.testing.expectEqual(@as(u128, 0), recovered.reconciliation_break_identity);
}

test "partial forced attribution retains exact suspense until remaining slices are delivered" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    var summary = ShardSummary.fixture(.shard_0, 1, 100);
    summary.swap_quantity = 3;
    _ = try coordinator.publishSummary(1, summary);
    _ = try coordinator.acceptAccountFact(.{ .identity = 60, .exchange_account = 900, .version = 1, .barrier = 1, .payload = .{ .forced_execution = .{ .owner = null, .quantity = -3, .price_ticks = 100, .realized_pnl_atoms = 5, .fee_atoms = 3, .penalty_atoms = 2 } } });
    var first: ForcedExecutionAllocation = .{ .identity = 61, .forced_execution_identity = 60, .count = 1 };
    first.slices[0] = .{ .owner = .shard_0, .quantity = -1, .position_delta = -1, .realized_pnl_atoms = 2, .fee_atoms = 1, .penalty_atoms = 1 };
    _ = try coordinator.allocateForcedExecution(first);
    const residual = (try coordinator.forcedSuspenseRemaining()).?;
    try std.testing.expectEqual(@as(i64, -2), residual.quantity);
    try std.testing.expectEqual(@as(i64, -2), residual.position_delta);
    try std.testing.expectEqual(@as(i64, 3), residual.realized_pnl_atoms);
    try std.testing.expectEqual(@as(i64, 2), residual.fee_atoms);
    try std.testing.expectEqual(@as(i64, 1), residual.penalty_atoms);
    var second: ForcedExecutionAllocation = .{ .identity = 62, .forced_execution_identity = 60, .count = 1 };
    second.slices[0] = .{ .owner = .shard_0, .quantity = -2, .position_delta = -2, .realized_pnl_atoms = 3, .fee_atoms = 2, .penalty_atoms = 1 };
    _ = try coordinator.allocateForcedExecution(second);
    try std.testing.expectEqual(@as(i64, 0), (try coordinator.forcedSuspenseRemaining()).?.quantity);
    try std.testing.expect(coordinator.suspense_forced_execution != null);
    try coordinator.markForcedDelivered(61, 0);
    try std.testing.expect(coordinator.suspense_forced_execution != null);
    try coordinator.markForcedDelivered(62, 0);
    try std.testing.expect((try coordinator.forcedSuspenseRemaining()) == null);
}

test "opposing positions can be attributed in separate forced allocations" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    var long = ShardSummary.fixture(.shard_0, 1, 100);
    long.swap_quantity = 3;
    var short = ShardSummary.fixture(.shard_1, 1, 101);
    short.swap_quantity = -1;
    _ = try coordinator.publishSummary(1, long);
    _ = try coordinator.publishSummary(2, short);
    _ = try coordinator.acceptAccountFact(.{ .identity = 70, .exchange_account = 900, .version = 1, .barrier = 1, .payload = .{ .forced_execution = .{ .owner = null, .quantity = -2, .price_ticks = 100, .realized_pnl_atoms = 0, .fee_atoms = 0, .penalty_atoms = 0 } } });
    var first: ForcedExecutionAllocation = .{ .identity = 71, .forced_execution_identity = 70, .count = 1 };
    first.slices[0] = .{ .owner = .shard_1, .quantity = 1, .position_delta = 1, .realized_pnl_atoms = -10, .fee_atoms = 0, .penalty_atoms = 0 };
    _ = try coordinator.allocateForcedExecution(first);
    try std.testing.expectEqual(@as(i64, -3), (try coordinator.forcedSuspenseRemaining()).?.quantity);
    var second: ForcedExecutionAllocation = .{ .identity = 72, .forced_execution_identity = 70, .count = 1 };
    second.slices[0] = .{ .owner = .shard_0, .quantity = -3, .position_delta = -3, .realized_pnl_atoms = 10, .fee_atoms = 0, .penalty_atoms = 0 };
    _ = try coordinator.allocateForcedExecution(second);
    try coordinator.markForcedDelivered(71, 0);
    try coordinator.markForcedDelivered(72, 0);
    try std.testing.expect((try coordinator.forcedSuspenseRemaining()) == null);
}

test "forced delivery retry after shard commit does not charge penalty twice" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    var summary = ShardSummary.fixture(.shard_0, 1, 100);
    summary.swap_quantity = 1;
    _ = try coordinator.publishSummary(1, summary);
    _ = try coordinator.acceptAccountFact(.{ .identity = 50, .exchange_account = 900, .version = 1, .barrier = 1, .payload = .{ .forced_execution = .{ .owner = null, .quantity = -1, .price_ticks = 100, .fee_atoms = 0, .penalty_atoms = 2 } } });
    var allocation: ForcedExecutionAllocation = .{ .identity = 51, .forced_execution_identity = 50, .count = 1 };
    allocation.slices[0] = .{ .owner = .shard_0, .quantity = -1, .position_delta = -1, .penalty_atoms = 2 };
    var coordination_journal = CoordinationJournal.initAt(1);
    const delivery = (try coordinator.commitForcedAllocation(&coordination_journal, allocation))[0];
    const shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(shard);
    shard.* = .{};
    var stable_journal = trading.journal.Journal.init();
    try activateFixtureAssets(shard, &stable_journal);
    _ = try applyCoreStable(shard, &stable_journal, .{ .identity = 1, .payload = .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = 3, .quantity_denominator = 1, .reservation_model = .leveraged, .product = .isolated_linear_usdt, .venue = 1 } } });
    _ = try applyCoreStable(shard, &stable_journal, .{ .identity = 2, .payload = .{ .margin_rules_activated = .{ .version = 1, .instrument = 3 } } });
    try shard.economic_projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .quantity = .{ .instrument = 3, .rules_version = 1, .lots = 1 }, .price = .{ .instrument = 3, .rules_version = 1, .ticks = 100 }, .price_tick_value = .{ .asset = 1, .atoms = 1 }, .quantity_denominator = 1, .product = .isolated_linear_usdt } });
    try std.testing.expectError(error.ForcedDeliveryNotCommitted, coordinator.ackForcedDeliveryFromShard(&coordination_journal, delivery, shard));
    _ = try applyCoreStable(shard, &stable_journal, try accountFactEvent(delivery));
    const after_first = shard.economic_projection.digest();
    try std.testing.expectEqual(@as(i64, 2), shard.economic_projection.portfolio.penalty_atoms);
    try std.testing.expectEqual(@as(usize, 1), (try coordinator.pendingForcedDeliveries()).len);
    try applyForcedDeliveryStable(&coordinator, &coordination_journal, delivery, .shard_0, shard, &stable_journal);
    try std.testing.expectEqualSlices(u8, &after_first, &shard.economic_projection.digest());
    try std.testing.expectEqual(@as(usize, 0), (try coordinator.pendingForcedDeliveries()).len);
    try std.testing.expect(coordinator.suspense_forced_execution == null);
}

test "shared gateway routes itemized outcomes to the unique owning shard" {
    var gateway: GatewayOwnership = .{};
    const first = try gateway.record(.{ .exchange_account = 900, .shard_id = .shard_0, .fencing_token = 7, .command = commandFixture(1, 1) });
    const second = try gateway.record(.{ .exchange_account = 900, .shard_id = .shard_1, .fencing_token = 7, .command = commandFixture(1, 1) });
    try std.testing.expectEqual(ShardId.shard_0, first.shard_id);
    try std.testing.expectEqual(ShardId.shard_1, second.shard_id);
    try std.testing.expectError(error.DuplicateCommandIdentity, gateway.record(.{ .exchange_account = 900, .shard_id = .shard_0, .fencing_token = 7, .command = commandFixture(1, 1) }));
    try std.testing.expectError(error.CrossAccountGatewayRequest, gateway.record(.{ .exchange_account = 901, .shard_id = .shard_2, .fencing_token = 7, .command = commandFixture(2, 1) }));
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
        .payload = .{ .forced_execution = .{ .owner = .shard_0, .quantity = -1, .price_ticks = 1, .fee_atoms = 0 } },
    } };
    const shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(shard);
    shard.* = .{};
    var stable_journal = trading.journal.Journal.init();
    try activateFixtureAssets(shard, &stable_journal);
    try std.testing.expectError(error.CrossShardDelivery, applyAccountFactStable(delivery, .shard_1, shard, &stable_journal));
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
        summary.exchange_margin_atoms = if (index < 2) 63 else 62;
        _ = try coordinator.publishSummary(index + 1, summary);
    }
    _ = try coordinator.allocateLeases(1, 10);
    _ = try coordinator.reconcileMargin(.{ .identity = 20, .barrier = 5, .venue_net_margin_atoms = 250, .venue_swap_margin_atoms = 250, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 });
    var storage: [4096]u8 = undefined;
    const encoded = try coordinator.snapshot(&storage);
    const recovered = try AccountCoordinator.restore(encoded);
    try std.testing.expect(recovered.recovery_only);
    var expected = coordinator;
    expected.recovery_only = true;
    try std.testing.expectEqualSlices(u8, &expected.digest(), &recovered.digest());
    try std.testing.expectEqual(try coordinator.grossPortfolioMargin(), try recovered.grossPortfolioMargin());
    try std.testing.expectEqual(coordinator.account_netting_benefit_atoms, recovered.account_netting_benefit_atoms);
    try std.testing.expectEqual(coordinator.barrier, recovered.barrier);
}

test "account recovery restores four matching shard tails under fresh evidence fence" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    const shard_snapshots_storage = try std.testing.allocator.create([max_shards][durable.max_snapshot_bytes]u8);
    defer std.testing.allocator.destroy(shard_snapshots_storage);
    var shard_snapshots: [max_shards][]const u8 = undefined;
    var shard_tails: [max_shards][]const u8 = undefined;
    var tail_journals: [max_shards]trading.journal.Journal = undefined;
    for (0..max_shards) |index| {
        const shard = try std.testing.allocator.create(trading.TradingShard);
        defer std.testing.allocator.destroy(shard);
        shard.* = .{};
        var stable_journal = trading.journal.Journal.init();
        try activateFixtureAssets(shard, &stable_journal);
        _ = try applyCoreStable(shard, &stable_journal, .{
            .identity = 1,
            .payload = .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = 1, .quantity_denominator = 1, .reservation_model = .leveraged } },
        });
        _ = try applyCoreStable(shard, &stable_journal, .{
            .identity = 1,
            .payload = .{ .margin_rules_activated = .{ .version = 1 } },
        });
        _ = try applyCoreStable(shard, &stable_journal, .{
            .identity = 1,
            .payload = .{ .account_configuration = .{ .exchange_account_identity = 900 } },
        });
        _ = try applyCoreStable(shard, &stable_journal, .{
            .identity = 1,
            .payload = .{ .exchange_balance = .{ .cash_atoms = 10_000 } },
        });
        _ = try applyCoreStable(shard, &stable_journal, .{
            .identity = 1,
            .payload = .exchange_positions,
        });
        _ = try applyCoreStable(shard, &stable_journal, .{
            .identity = 1,
            .payload = .{ .opening_balance = .{ .cash_atoms = 10_000 } },
        });
        _ = try applyCoreStable(shard, &stable_journal, .{
            .identity = 1,
            .payload = .{ .virtual_portfolio_activated = .{ .portfolio_identity = index + 11 } },
        });
        try stable_journal.seal();
        shard_snapshots[index] = try shard.snapshot(&stable_journal, @intCast(shard.authoritativeBarrier()), &shard_snapshots_storage[index]);
        tail_journals[index] = trading.journal.Journal.initAt(stable_journal.last_sequence + 1);
        try tail_journals[index].seal();
        shard_tails[index] = tail_journals[index].bytes();
        for (1..8) |sequence| {
            const derived = try shardSummaryFromShard(shard, @enumFromInt(index), sequence, @intCast(index + 1));
            _ = try coordinator.publishSummary(index * 100 + sequence, derived);
        }
    }
    _ = try coordinator.allocateLeases(1, 40);
    var coordinator_storage: [4096]u8 = undefined;
    const coordinator_snapshot = try coordinator.snapshot(&coordinator_storage);
    var coordinator_tail = CoordinationJournal.initAt(1);
    for (0..max_shards) |index| {
        var summary = coordinator.summaries[index].value;
        summary.shard_sequence += 1;
        const event: CoordinationEvent = .{ .publish_summary = .{ .identity = 1_000 + index, .summary = summary } };
        try coordinator_tail.append(event);
        _ = try coordinator.publishSummary(event.publish_summary.identity, event.publish_summary.summary);
    }
    try coordinator_tail.seal();
    const recovered = try std.testing.allocator.create(AccountRecovery);
    defer std.testing.allocator.destroy(recovered);
    try AccountRecovery.beginWithCoordinatorTailInto(recovered, coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, shard_tails);
    try std.testing.expect(recovered.coordinator.recovery_only);
    var expected = coordinator;
    expected.recovery_only = true;
    try std.testing.expectEqualSlices(u8, &expected.digest(), &recovered.coordinator.digest());
    for (&recovered.shards) |*shard| try std.testing.expectEqual(trading.operational.OperationalMode.recovering, shard.operational_state.mode);
    try std.testing.expectError(error.FreshMarginObservationRequired, recovered.completeCoordinatorRecovery());
}

test "account recovery retains a forced shard commit awaiting coordinator ack" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    const snapshot_storage = try std.testing.allocator.create([max_shards][durable.max_snapshot_bytes]u8);
    defer std.testing.allocator.destroy(snapshot_storage);
    var shard_snapshots: [max_shards][]const u8 = undefined;
    var shard_tails: [max_shards][]const u8 = undefined;
    var tails: [max_shards]trading.journal.Journal = undefined;
    for (0..max_shards) |index| {
        const shard = try std.testing.allocator.create(trading.TradingShard);
        defer std.testing.allocator.destroy(shard);
        shard.* = .{};
        var journal = trading.journal.Journal.init();
        try activateFixtureAssets(shard, &journal);
        _ = try applyCoreStable(shard, &journal, .{ .identity = 1, .payload = .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = 1, .venue = 1, .quantity_denominator = 1, .reservation_model = .leveraged } } });
        _ = try applyCoreStable(shard, &journal, .{ .identity = 2, .payload = .{ .margin_rules_activated = .{ .version = 1 } } });
        _ = try applyCoreStable(shard, &journal, .{ .identity = 3, .payload = .{ .account_configuration = .{ .exchange_account_identity = 900 } } });
        _ = try applyCoreStable(shard, &journal, .{ .identity = 4, .payload = .{ .exchange_balance = .{ .cash_atoms = 10_000 } } });
        _ = try applyCoreStable(shard, &journal, .{ .identity = 5, .payload = .exchange_positions });
        _ = try applyCoreStable(shard, &journal, .{ .identity = 6, .payload = .{ .opening_balance = .{ .cash_atoms = 10_000 } } });
        _ = try applyCoreStable(shard, &journal, .{ .identity = 7, .payload = .{ .virtual_portfolio_activated = .{ .portfolio_identity = index + 11 } } });
        if (index == 0) {
            // One owned order and Fill establish the position through the same
            // public journal/recovery path used by the subsequent forced delivery.
            const fixture = @import("trading_shard_fixture.zig");
            _ = try trading.applyStable(shard, &journal, fixture.atGroup(8, .{ .identity = 8, .payload = .{ .portfolio_transfer = .{ .amount_atoms = 1_000 } } }));
            const genesis = fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged);
            for (genesis[14..], 14..) |original, genesis_index| {
                if (genesis_index == 20) continue; // This fixture owns only the perpetual instrument.
                var input = original;
                if (input.core.payload == .risk_lease_granted) input.core.payload.risk_lease_granted.amount_atoms = 1_000;
                if (input.core.payload == .instrument_trading_authorization) {
                    input.core.payload.instrument_trading_authorization.exchange_account = 900;
                    input.core.payload.instrument_trading_authorization.instrument = 1;
                }
                _ = try trading.applyStable(shard, &journal, input);
            }
            _ = try trading.applyStable(shard, &journal, fixture.atGroup(12, .{ .identity = 9, .payload = .{ .host_activated = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .session = .{ .fencing = 1, .shard = 0, .generation = 1 }, .activation_barrier = 0, .state_digest = shard.canonicalStateDigest() } } }));
            _ = try trading.applyStable(shard, &journal, fixture.atGroup(13, .{ .identity = 10, .payload = .{ .mark_price = .{ .instrument = 1, .price_atoms = 100 } } }));
            var book = fixture.snapshotAt(14, 1);
            book.venue.envelope.exchange_account = 900;
            book.venue.envelope.instrument = 1;
            var snapshot = &book.venue.event.l2_book_snapshot;
            snapshot.instrument = 1;
            snapshot.best_bid = .{ .instrument = 1, .rules_version = 1, .ticks = 99 };
            snapshot.best_ask = .{ .instrument = 1, .rules_version = 1, .ticks = 100 };
            snapshot.next_ask = .{ .instrument = 1, .rules_version = 1, .ticks = 101 };
            snapshot.best_bid_quantity.?.instrument = 1;
            snapshot.best_ask_quantity.?.instrument = 1;
            snapshot.next_ask_quantity.?.instrument = 1;
            _ = try trading.applyStable(shard, &journal, book);
            _ = try trading.applyStable(shard, &journal, fixture.atGroup(15, .{ .identity = 11, .payload = .{ .capability_profile_activation = .{ .exchange_account = 900, .instrument = 1, .venue = 1, .environment = .simulation, .product = .isolated_linear_usdt, .version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .max_dispatch_age_ns = 10 * std.time.ns_per_s, .supports_place = true, .supports_cancel = true, .supports_native_amend = false, .supports_venue_reduce_only = false, .supports_post_only = false, .supports_market_protection = false } } }));
            const command = (try trading.applyStable(shard, &journal, fixture.atGroup(16, .{ .identity = 12, .payload = .{ .timer = .{ .side = .buy, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 1, .limit_price_micros = 100 } } }))) orelse return error.ExpectedOwnedSeedOrder;
            _ = try trading.applyStable(shard, &journal, fixture.atGroup(17, .{ .identity = 13, .payload = .{ .economic_fill = .{ .fill_id = 1, .order_id = command.order_id, .quantity = 1, .price_ticks = 100 } } }));
            _ = try trading.applyStable(shard, &journal, fixture.atGroup(18, .{ .identity = 14, .payload = .{ .oms_execution_report = .{ .report_id = 14, .order_id = command.order_id, .revision = 1, .status = .filled, .cumulative_quantity = 1, .remaining_quantity = 0 } } }));
            try std.testing.expectEqual(@as(i64, 1), shard.economic_projection.portfolio.swap.quantity);
            try std.testing.expectEqual(@as(i64, 1), shard.economic_projection.exchange.swap.quantity);
            try std.testing.expectEqual(@as(i128, 100), shard.economic_projection.portfolio.swap.open_cost_atoms);
            try std.testing.expectEqual(@as(i128, 100), shard.economic_projection.exchange.swap.open_cost_atoms);
            try std.testing.expectEqual(@as(u64, 1), shard.open_economic_fact_count);
            try std.testing.expect(!shard.economic_projection.reconciliation_break);
        }
        try journal.seal();
        shard_snapshots[index] = try shard.snapshot(&journal, @intCast(shard.authoritativeBarrier()), &snapshot_storage[index]);
        _ = try coordinator.publishSummary(index + 1, try shardSummaryFromShard(shard, @enumFromInt(index), 1, @intCast(index + 1)));
        tails[index] = trading.journal.Journal.initAt(journal.last_sequence + 1);
    }
    var coordinator_storage: [16384]u8 = undefined;
    const coordinator_snapshot = try coordinator.snapshot(&coordinator_storage);
    var coordinator_tail = CoordinationJournal.initAt(1);
    const source: AccountFact = .{ .identity = 90, .exchange_account = 900, .version = 1, .barrier = 1, .payload = .{ .forced_execution = .{ .owner = null, .quantity = -1, .price_ticks = 100, .fee_atoms = 0 } } };
    try coordinator_tail.append(.{ .account_fact = source });
    _ = try coordinator.acceptAccountFact(source);
    var allocation: ForcedExecutionAllocation = .{ .identity = 91, .forced_execution_identity = 90, .count = 1 };
    allocation.slices[0] = .{ .owner = .shard_0, .quantity = -1, .position_delta = -1 };
    const delivery = (try coordinator.commitForcedAllocation(&coordinator_tail, allocation))[0];
    const committed_shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(committed_shard);
    _ = try trading.TradingShard.restoreSnapshotInto(committed_shard, shard_snapshots[0]);
    _ = try applyCoreStable(committed_shard, &tails[0], try accountFactEvent(delivery));
    for (0..max_shards) |index| {
        try tails[index].seal();
        shard_tails[index] = tails[index].bytes();
    }
    try coordinator_tail.seal();
    const recovered = try std.testing.allocator.create(AccountRecovery);
    defer std.testing.allocator.destroy(recovered);
    try AccountRecovery.beginWithCoordinatorTailInto(recovered, coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, shard_tails);
    try std.testing.expectEqual(@as(u8, 1), recovered.summary_refresh_mask);
    try std.testing.expectEqual(@as(usize, 1), (try recovered.coordinator.pendingForcedDeliveries()).len);
    const drift_shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(drift_shard);
    _ = try trading.TradingShard.restoreSnapshotInto(drift_shard, shard_snapshots[0]);
    var drift_tail = trading.journal.Journal.initAt(@as(u64, @intCast(drift_shard.authoritativeBarrier())) + 1);
    _ = try applyCoreStable(drift_shard, &drift_tail, try accountFactEvent(delivery));
    _ = try applyCoreStable(drift_shard, &drift_tail, .{ .identity = 92, .payload = .{ .funding_settlement = .{ .settlement_id = 92, .amount_atoms = 1 } } });
    try drift_tail.seal();
    var drift_tails = shard_tails;
    drift_tails[0] = drift_tail.bytes();
    const rejected = try std.testing.allocator.create(AccountRecovery);
    defer std.testing.allocator.destroy(rejected);
    try std.testing.expectError(error.AccountRecoveryBarrierMismatch, AccountRecovery.beginWithCoordinatorTailInto(rejected, coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, drift_tails));
    var ack_tail = CoordinationJournal.initAt(1);
    try ack_tail.append(.{ .account_fact = source });
    try ack_tail.append(.{ .forced_execution_allocation = allocation });
    try ack_tail.append(.{ .forced_delivery_ack = .{ .allocation_identity = 91, .slice_index = 0 } });
    try ack_tail.seal();
    const after_ack = try std.testing.allocator.create(AccountRecovery);
    defer std.testing.allocator.destroy(after_ack);
    try AccountRecovery.beginWithCoordinatorTailInto(after_ack, coordinator_snapshot, ack_tail.bytes(), shard_snapshots, shard_tails);
    try std.testing.expectEqual(@as(u8, 1), after_ack.summary_refresh_mask);
    try std.testing.expect(after_ack.coordinator.suspense_forced_execution == null);
    var empty_tails: [max_shards][]const u8 = undefined;
    var empty_journals: [max_shards]trading.journal.Journal = undefined;
    for (0..max_shards) |index| {
        const initial_shard = try std.testing.allocator.create(trading.TradingShard);
        defer std.testing.allocator.destroy(initial_shard);
        const initial_barrier = try trading.TradingShard.restoreSnapshotInto(initial_shard, shard_snapshots[index]);
        empty_journals[index] = trading.journal.Journal.initAt(initial_barrier + 1);
        try empty_journals[index].seal();
        empty_tails[index] = empty_journals[index].bytes();
    }
    try std.testing.expectError(error.ForcedDeliveryAckWithoutShardCommit, AccountRecovery.beginWithCoordinatorTailInto(rejected, coordinator_snapshot, ack_tail.bytes(), shard_snapshots, empty_tails));
    var recovery_ack_journal = CoordinationJournal.initAt(3);
    try recovered.coordinator.ackForcedDeliveryFromShard(&recovery_ack_journal, delivery, &recovered.shards[0]);
    try std.testing.expectEqual(@as(u64, 1), recovery_ack_journal.stable.records);
    try std.testing.expectError(error.FreshShardSummaryRequired, recovered.completeCoordinatorRecovery());
    const refreshed = try shardSummaryFromShard(&recovered.shards[0], .shard_0, 2, 1);
    _ = try recovered.coordinator.publishSummary(10, refreshed);
    try std.testing.expectError(error.FreshMarginObservationRequired, recovered.completeCoordinatorRecovery());
}

test "shard summaries derive from authoritative state and coordinate four real shards" {
    const shards = try std.testing.allocator.create([max_shards]trading.TradingShard);
    defer std.testing.allocator.destroy(shards);
    var journals: [max_shards]trading.journal.Journal = undefined;
    for (0..max_shards) |index| {
        shards[index] = .{};
        journals[index] = trading.journal.Journal.init();
        const journal = &journals[index];
        try activateFixtureAssets(&shards[index], journal);
        _ = try applyCoreStable(&shards[index], journal, .{
            .identity = 1,
            .payload = .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = 1, .quantity_denominator = 1, .reservation_model = .leveraged } },
        });
        _ = try applyCoreStable(&shards[index], journal, .{
            .identity = 2,
            .payload = .{ .margin_rules_activated = .{ .version = 1 } },
        });
        _ = try applyCoreStable(&shards[index], journal, .{
            .identity = 3,
            .payload = .{ .account_configuration = .{ .exchange_account_identity = 900 } },
        });
        _ = try applyCoreStable(&shards[index], journal, .{
            .identity = 4,
            .payload = .{ .exchange_balance = .{ .cash_atoms = 10_000 } },
        });
        _ = try applyCoreStable(&shards[index], journal, .{
            .identity = 5,
            .payload = .exchange_positions,
        });
        _ = try applyCoreStable(&shards[index], journal, .{
            .identity = 6,
            .payload = .{ .opening_balance = .{ .cash_atoms = 10_000 } },
        });
        _ = try applyCoreStable(&shards[index], journal, .{
            .identity = 7,
            .payload = .{ .virtual_portfolio_activated = .{ .portfolio_identity = index + 11 } },
        });
    }
    const invalid = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(invalid);
    invalid.* = .{};
    try std.testing.expectError(error.InvalidShardSummary, shardSummaryFromShard(invalid, .shard_0, 1, 1));

    var coordinator = AccountCoordinator.init(900, 4_000, 4_000);
    var initial: [max_shards]ShardSummary = undefined;
    for (0..max_shards) |index| {
        initial[index] = try shardSummaryFromShard(&shards[index], @enumFromInt(index), 1, @intCast(index + 1));
        try std.testing.expect(try coordinator.publishSummary(index + 100, initial[index]));
    }
    try std.testing.expectEqual(@as(i64, 0), try coordinator.grossPortfolioMargin());
    const first_leases = try coordinator.allocateLeases(1, 10);
    for (first_leases) |lease| {
        try std.testing.expectEqual(@as(i64, 0), lease.used_atoms);
        try std.testing.expectEqual(@as(i64, 1_000), lease.limit_atoms);
    }

    var reservation_group: trading.oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    reservation_group.members[0] = .{
        .intent_sequence = 1,
        .operation = .place,
        .instrument = 1,
        .quantity = 1,
        .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 1 },
        .reservation = .{ .asset = 1, .atoms = 500 },
    };
    try shards[3].oms.applyGroup(reservation_group);
    shards[3].last_risk_tier = 2;
    const advanced = try shardSummaryFromShard(&shards[3], .shard_3, 2, 4);
    try std.testing.expectEqual(@as(i64, 500), advanced.reservation_atoms);
    try std.testing.expect(!advanced.local_gate_closed);
    try std.testing.expect(try coordinator.publishSummary(203, advanced));
    try std.testing.expectEqual(@as(i64, 500), try coordinator.grossPortfolioMargin());
    const renewed = try coordinator.allocateLeases(2, 20);
    try std.testing.expectEqual(@as(i64, 500), renewed[3].used_atoms);
    try std.testing.expectEqual(@as(i64, 1_000), renewed[3].limit_atoms);
    _ = try coordinator.reconcileMargin(.{
        .identity = 300,
        .barrier = 25,
        .venue_net_margin_atoms = 0,
        .venue_swap_margin_atoms = 0,
        .venue_swap_quantity = 0,
        .margin_mode = .isolated,
        .rules_version = 1,
        .venue_risk_tier = 2,
        .venue_liquidation_distance_ticks = std.math.maxInt(i64),
    });
    try std.testing.expect(coordinator.margin_gate.open);
    try std.testing.expectEqual(@as(i64, 500), coordinator.account_netting_benefit_atoms);

    const gated_shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(gated_shard);
    @memcpy(std.mem.asBytes(gated_shard), std.mem.asBytes(&shards[0]));
    try applyAccountGateStable(.{ .shard_id = .shard_0, .gate = .{ .identity = 8, .open = false, .latched = true } }, .shard_0, gated_shard, &journals[0]);
    const latched = try shardSummaryFromShard(gated_shard, .shard_0, 3, 1);
    try std.testing.expect(latched.local_gate_closed);

    var replayed = AccountCoordinator.init(900, 4_000, 4_000);
    for (0..max_shards) |index| _ = try replayed.publishSummary(index + 100, initial[index]);
    _ = try replayed.allocateLeases(1, 10);
    _ = try replayed.publishSummary(203, try shardSummaryFromShard(&shards[3], .shard_3, 2, 4));
    _ = try replayed.allocateLeases(2, 20);
    _ = try replayed.reconcileMargin(.{
        .identity = 300,
        .barrier = 25,
        .venue_net_margin_atoms = 0,
        .venue_swap_margin_atoms = 0,
        .venue_swap_quantity = 0,
        .margin_mode = .isolated,
        .rules_version = 1,
        .venue_risk_tier = 2,
        .venue_liquidation_distance_ticks = std.math.maxInt(i64),
    });
    try std.testing.expectEqualSlices(u8, &coordinator.digest(), &replayed.digest());
}

test "explicit lease tightening is a replayable deterministic fact" {
    var coordinator = AccountCoordinator.init(900, 1_000, 1_000);
    for (0..max_shards) |index| _ = try coordinator.publishSummary(index + 1, ShardSummary.fixture(@enumFromInt(index), 1, 100));
    const leases = try coordinator.allocateLeases(1, 10);
    try std.testing.expectEqual(@as(i64, 250), leases[0].limit_atoms);
    try std.testing.expectEqual(@as(i64, 100), leases[0].used_atoms);

    const tightened = try coordinator.tightenLeases(12, .{ 100, 200, 250, 40 });
    try std.testing.expectEqual(@as(i64, 100), tightened[0].limit_atoms);
    try std.testing.expectEqual(@as(i64, 200), tightened[1].limit_atoms);
    try std.testing.expectEqual(@as(i64, 250), tightened[2].limit_atoms);
    try std.testing.expectEqual(@as(u64, 2), tightened[3].version);
    try std.testing.expectEqual(@as(i64, 40), tightened[3].limit_atoms);
    try std.testing.expectEqual(@as(i64, 100), tightened[3].used_atoms);
    try std.testing.expect(tightened[3].open);
    try std.testing.expect(coordinator.leaseOverTightened(.shard_3));
    try std.testing.expect(!coordinator.leaseOverTightened(.shard_1));
    try std.testing.expect(!coordinator.leaseOverTightened(.shard_0));

    const digest_after_tighten = coordinator.digest();
    const duplicated = try coordinator.tightenLeases(12, .{ 100, 200, 250, 40 });
    try std.testing.expectEqual(@as(u64, 2), duplicated[0].version);
    try std.testing.expectEqualSlices(u8, &digest_after_tighten, &coordinator.digest());
    try std.testing.expectError(error.StaleRiskLease, coordinator.tightenLeases(3, .{ 100, 200, 250, 40 }));
    try std.testing.expectError(error.InvalidRiskLease, coordinator.tightenLeases(13, .{ -1, 200, 250, 40 }));
    try std.testing.expectEqualSlices(u8, &digest_after_tighten, &coordinator.digest());

    var grown = ShardSummary.fixture(.shard_1, 2, 201);
    grown.exchange_account = 900;
    _ = try coordinator.publishSummary(51, grown);
    const digest_before_renewal = coordinator.digest();
    try std.testing.expectError(error.RiskLeaseOversubscribed, coordinator.allocateLeases(2, 20));
    try std.testing.expectEqualSlices(u8, &digest_before_renewal, &coordinator.digest());
    try std.testing.expectError(error.MarginReconciliationRequired, blk: {
        var gated = coordinator;
        gated.margin_gate = .{ .identity = 1, .open = false, .latched = true };
        break :blk gated.allocateLeases(2, 20);
    });

    var events: [max_shards]trading.CoreEvent = undefined;
    const lease_events = try coordinator.currentLeaseEvents(&events);
    try std.testing.expectEqual(max_shards, lease_events.len);
    for (lease_events, 0..) |event, index| switch (event.payload) {
        .risk_lease_granted => |grant| {
            try std.testing.expect(grant.open);
            try std.testing.expectEqual(@as(u128, @intCast(index)), (grant.lease_identity - 1) % max_shards);
        },
        else => return error.UnexpectedLeaseEvent,
    };

    var replayed = AccountCoordinator.init(900, 1_000, 1_000);
    for (0..max_shards) |index| _ = try replayed.publishSummary(index + 1, ShardSummary.fixture(@enumFromInt(index), 1, 100));
    _ = try replayed.allocateLeases(1, 10);
    _ = try replayed.tightenLeases(12, .{ 100, 200, 250, 40 });
    _ = try replayed.tightenLeases(12, .{ 100, 200, 250, 40 });
    var replay_grown = ShardSummary.fixture(.shard_1, 2, 201);
    replay_grown.exchange_account = 900;
    _ = try replayed.publishSummary(51, replay_grown);
    try std.testing.expectError(error.RiskLeaseOversubscribed, replayed.allocateLeases(2, 20));
    try std.testing.expectEqualSlices(u8, &coordinator.digest(), &replayed.digest());
}

fn fourBucketSummaries() !AccountCoordinator {
    var coordinator = AccountCoordinator.init(900, 10_000, 10_000);
    for (0..max_shards) |index| {
        var summary = ShardSummary.fixture(@enumFromInt(index), 1, 500);
        summary.exchange_margin_atoms = if (index % 2 == 0) 120 else 80;
        summary.spot_margin_atoms = 10;
        summary.spot_quantity = 3;
        summary.spot_asset_atoms = 3;
        summary.swap_quantity = if (index < 2) 5 else -5;
        summary.risk_tier = 2;
        summary.liquidation_distance_ticks = 900;
        _ = try coordinator.publishSummary(index + 1, summary);
    }
    return coordinator;
}

fn bucketObservation(identity: u128, barrier: u64) MarginObservation {
    return .{
        .identity = identity,
        .barrier = barrier,
        .venue_net_margin_atoms = 440,
        .venue_swap_quantity = 0,
        .venue_spot_asset_atoms = 12,
        .venue_spot_margin_atoms = 40,
        .venue_swap_margin_atoms = 400,
        .margin_mode = .isolated,
        .rules_version = 1,
        .venue_risk_tier = 2,
        .venue_liquidation_distance_ticks = 900,
    };
}

test "margin reconciliation covers mode buckets rounding and unknown evidence" {
    var coordinator = try fourBucketSummaries();
    const leases = try coordinator.allocateLeases(1, 60);
    for (leases) |lease| try std.testing.expectEqual(@as(i64, 2_500), lease.limit_atoms);

    const healthy = try coordinator.reconcileMargin(bucketObservation(30, 50));
    try std.testing.expect(healthy.open);
    try std.testing.expectEqual(MarginReconciliationState.healthy, coordinator.margin_reconciliation_state);
    try std.testing.expectEqual(@as(i64, 1_560), coordinator.account_netting_benefit_atoms);
    for (leases) |lease| try std.testing.expectEqual(@as(i64, 2_500), lease.limit_atoms);

    var rounded = bucketObservation(31, 51);
    rounded.bucket_rounding_atoms = 5;
    rounded.venue_swap_margin_atoms = 403;
    rounded.venue_spot_margin_atoms = 38;
    rounded.venue_net_margin_atoms = 441;
    const explained = try coordinator.reconcileMargin(rounded);
    try std.testing.expect(explained.open);

    var beyond_unit = rounded;
    beyond_unit.identity = 32;
    beyond_unit.barrier = 52;
    beyond_unit.venue_net_margin_atoms = 450;
    const broken = try coordinator.reconcileMargin(beyond_unit);
    const digest_at_break = coordinator.digest();
    try std.testing.expect(!broken.open);
    try std.testing.expect(broken.latched);
    try std.testing.expectEqual(MarginReconciliationState.broken, coordinator.margin_reconciliation_state);
    for (coordinator.leases[0..coordinator.lease_count]) |lease| {
        try std.testing.expect(lease.open);
        try std.testing.expectEqual(@as(i64, 500), lease.limit_atoms);
        try std.testing.expectEqual(@as(i64, 500), lease.used_atoms);
    }

    const still_latched = try coordinator.reconcileMargin(bucketObservation(33, 53));
    try std.testing.expect(still_latched.latched);
    const resolved = try coordinator.resolveMarginGate(33);
    try std.testing.expect(resolved.open);
    try std.testing.expect(!resolved.latched);

    var cross_mode = bucketObservation(34, 54);
    cross_mode.margin_mode = .cross;
    const mode_break = try coordinator.reconcileMargin(cross_mode);
    try std.testing.expect(mode_break.latched);
    try std.testing.expectEqual(MarginReconciliationState.broken, coordinator.margin_reconciliation_state);
    try std.testing.expectError(error.MarginReconciliationStillBroken, coordinator.resolveMarginGate(cross_mode.identity));

    var netting_only = AccountCoordinator.init(900, 10_000, 10_000);
    for (0..max_shards) |index| {
        var summary = ShardSummary.fixture(@enumFromInt(index), 1, 500);
        summary.swap_quantity = if (index < 2) 5 else -5;
        _ = try netting_only.publishSummary(index + 1, summary);
    }
    const gross = try netting_only.grossPortfolioMargin();
    _ = try netting_only.reconcileMargin(.{
        .identity = 40,
        .barrier = 70,
        .venue_net_margin_atoms = @intCast(@divFloor(gross, 4)),
        .venue_swap_quantity = 0,
        .margin_mode = .isolated,
        .rules_version = 1,
    });
    try std.testing.expectEqual(@as(i128, gross - @divFloor(gross, 4)), netting_only.account_netting_benefit_atoms);

    var unknown_holder = try fourBucketSummaries();
    _ = try unknown_holder.allocateLeases(1, 60);
    var unknown_distance = bucketObservation(41, 80);
    unknown_distance.venue_liquidation_distance_ticks = unknown_liquidation_distance;
    _ = try unknown_holder.reconcileMargin(unknown_distance);
    try std.testing.expectEqual(MarginReconciliationState.unknown, unknown_holder.margin_reconciliation_state);
    try std.testing.expect(!unknown_holder.margin_gate.open);
    try std.testing.expect(!unknown_holder.margin_gate.latched);
    for (unknown_holder.leases[0..unknown_holder.lease_count]) |lease|
        try std.testing.expectEqual(@as(i64, 2_500), lease.limit_atoms);

    var unknown_tier = bucketObservation(42, 81);
    unknown_tier.venue_risk_tier = 0;
    _ = try unknown_holder.reconcileMargin(unknown_tier);
    try std.testing.expectEqual(MarginReconciliationState.unknown, unknown_holder.margin_reconciliation_state);

    const recovered = try unknown_holder.reconcileMargin(bucketObservation(43, 82));
    try std.testing.expect(recovered.open);
    try std.testing.expectEqual(MarginReconciliationState.healthy, unknown_holder.margin_reconciliation_state);

    var spot_mismatch = bucketObservation(44, 83);
    spot_mismatch.venue_spot_asset_atoms = 13;
    const position_break = try unknown_holder.reconcileMargin(spot_mismatch);
    try std.testing.expect(position_break.latched);
    for (unknown_holder.leases[0..unknown_holder.lease_count]) |lease| {
        try std.testing.expect(lease.open);
        try std.testing.expectEqual(@as(i64, 500), lease.limit_atoms);
    }

    var replayed = try fourBucketSummaries();
    _ = try replayed.allocateLeases(1, 60);
    _ = try replayed.reconcileMargin(bucketObservation(30, 50));
    var replay_rounded = bucketObservation(31, 51);
    replay_rounded.bucket_rounding_atoms = 5;
    replay_rounded.venue_swap_margin_atoms = 403;
    replay_rounded.venue_spot_margin_atoms = 38;
    replay_rounded.venue_net_margin_atoms = 441;
    _ = try replayed.reconcileMargin(replay_rounded);
    var replay_beyond = replay_rounded;
    replay_beyond.identity = 32;
    replay_beyond.barrier = 52;
    replay_beyond.venue_net_margin_atoms = 450;
    _ = try replayed.reconcileMargin(replay_beyond);
    try std.testing.expectEqualSlices(u8, &digest_at_break, &replayed.digest());
}

test "coordinator history pins incomplete forced source" {
    var coordinator = AccountCoordinator.init(900, 1000, 1000);
    _ = try coordinator.acceptAccountFact(.{ .identity = 1, .exchange_account = 900, .version = 1, .barrier = 1, .payload = .{ .forced_execution = .{ .owner = null, .quantity = -4, .price_ticks = 10, .fee_atoms = 4 } } });
    try std.testing.expectError(error.ForcedSourceNotClosed, coordinator.prepareForcedSourceHistory());
}

/// Single writer around Coordinator: Store commit precedes publication of state.
/// A failed write latches the writer; recovery is required before another input.
pub const CoordinatorOwner = struct {
    const bootstrap_type: u16 = 0xC008;
    coordinator: AccountCoordinator,
    stream: durable.StreamIdentity,
    store: durable.Store,
    io: std.Io,
    sequence: u64 = 0,
    closed: bool = false,

    pub fn init(coordinator: AccountCoordinator, stream: durable.StreamIdentity, store: durable.Store, io: std.Io) !CoordinatorOwner {
        var owner = try bind(coordinator, stream, store, io);
        var bytes: [trading.journal.max_payload_size]u8 = undefined;
        const payload = try coordinator.snapshot(&bytes);
        try store.append(io, .{ .stream = stream, .record = .{
            .type_id = bootstrap_type,
            .schema_version = @import("production_contract.zig").journal_schema_version,
            .flags = trading.journal.input_flag,
            .sequence = 1,
            .source_time = 0,
            .receive_time = 0,
            .monotonic_time = 0,
            .wall_time = 0,
            .time_presence = .{},
            .payload = payload,
        } });
        try store.commit(io, stream, 1);
        owner.sequence = 1;
        return owner;
    }

    fn bind(coordinator: AccountCoordinator, stream: durable.StreamIdentity, store: durable.Store, io: std.Io) !CoordinatorOwner {
        if (stream.domain != .control or stream.id == 0) return error.InvalidCoordinatorHistoryOrigin;
        if (coordinator.history_root) |root| {
            if (!std.meta.eql(root.origin.stream, stream)) return error.InvalidCoordinatorHistoryOrigin;
        }
        return .{ .coordinator = coordinator, .stream = stream, .store = store, .io = io };
    }

    pub fn apply(self: *CoordinatorOwner, event: CoordinationEvent) !void {
        if (self.closed) return error.CoordinatorWriterClosed;
        switch (event) {
            .forced_delivery_ack, .gateway_retire, .forced_history_commit => return error.CoordinatorVerifiedInputRequired,
            .account_fact => |fact| {
                // Resident original semantics already constitute exact evidence.
                // A retry must not require release or become a second input.
                if (self.coordinator.last_account_fact) |known| {
                    if (fact.identity == known.identity) {
                        if (!std.meta.eql(fact, known)) {
                            self.closed = true;
                            self.coordinator.recovery_only = true;
                            return error.AccountFactIdentityConflict;
                        }
                        return;
                    }
                }
                if (self.coordinator.history_root != null) {
                    self.closed = true;
                    self.coordinator.recovery_only = true;
                    return error.CoordinatorHistoryProofRequired;
                }
                if (fact.payload == .forced_execution and self.coordinator.forced_execution_source != null)
                    return error.ForcedSourceArchiveRequired;
            },
            else => {},
        }
        return self.applyCommitted(event);
    }

    fn applyCommitted(self: *CoordinatorOwner, event: CoordinationEvent) !void {
        if (self.closed) return error.CoordinatorWriterClosed;
        var candidate = self.coordinator;
        candidate.applyEvent(event) catch |err| {
            switch (err) {
                error.InvalidHistoryProof,
                error.InvalidHistoryRoot,
                error.InvalidHistoryKey,
                error.CoordinatorHistoryExpired,
                error.GatewayOutcomeIdentityConflict,
                error.ForcedExecutionAllocationConflict,
                error.AccountFactIdentityConflict,
                error.CoordinatorHistoryProofRequired,
                => {
                    self.closed = true;
                    self.coordinator.recovery_only = true;
                },
                else => {},
            }
            return err;
        };
        const sequence = try std.math.add(u64, self.sequence, 1);
        var bytes: [trading.journal.max_payload_size]u8 = undefined;
        const payload = try encodeCoordinationEvent(&bytes, event);
        errdefer self.closed = true;
        try self.store.append(self.io, .{ .stream = self.stream, .record = .{
            .type_id = coordinationEventType(event),
            .schema_version = @import("production_contract.zig").journal_schema_version,
            .flags = trading.journal.input_flag,
            .sequence = sequence,
            .source_time = 0,
            .receive_time = 0,
            .monotonic_time = 0,
            .wall_time = 0,
            .time_presence = .{},
            .payload = payload,
        } });
        try self.store.commit(self.io, self.stream, sequence);
        self.coordinator = candidate;
        self.sequence = sequence;
    }

    /// Publishes complete immutable source/slices/ACKs before a durable release.
    pub fn archiveForcedSource(self: *CoordinatorOwner) !history.Receipt {
        if (self.closed) return error.CoordinatorWriterClosed;
        const source = try self.coordinator.prepareForcedSourceHistory();
        const origin: history.Origin = .{ .stream = self.stream, .account = self.coordinator.exchange_account };
        var source_bytes: [8192]u8 = undefined;
        const encoded_source = try codec.encodeBare(&source_bytes, source);
        var allocation_bytes: [max_shards][1024]u8 = undefined;
        var records: [max_shards + 2]history.Record = undefined;
        var entries: [max_shards + 2]history.Entry = undefined;
        records[0] = .{ .bytes = encoded_source, .payload_digest = history.hash(encoded_source) };
        entries[0] = .{ .key = .{ .origin = origin, .identity = .{ .coordinator_forced_source = source.source.identity } }, .record_index = 0 };
        for (source.allocations[0..source.count], 0..) |record, index| {
            const encoded = try codec.encodeBare(&allocation_bytes[index], record.allocation);
            records[index + 1] = .{ .bytes = encoded, .payload_digest = history.hash(encoded) };
            entries[index + 1] = .{ .key = .{ .origin = origin, .identity = .{ .coordinator_forced_allocation = record.allocation.identity } }, .record_index = @intCast(index + 1) };
        }
        var fact_bytes: [1024]u8 = undefined;
        const encoded_fact = try codec.encodeBare(&fact_bytes, source.source);
        records[source.count + 1] = .{ .bytes = encoded_fact, .payload_digest = history.hash(encoded_fact) };
        entries[source.count + 1] = .{ .key = .{ .origin = origin, .identity = .{ .coordinator_account_fact = source.source.identity } }, .record_index = source.count + 1 };
        errdefer self.closed = true;
        const receipt = try self.store.publishOrderHistory(self.io, .{ .origin = origin, .previous_root = self.coordinator.history_root, .barrier = self.sequence + 1, .epoch = if (self.coordinator.history_root) |root| root.epoch else 1, .qualification_digest = records[0].payload_digest, .records = records[0 .. source.count + 2], .entries = entries[0 .. source.count + 2] });
        try self.applyCommitted(.{ .forced_history_commit = receipt });
        return receipt;
    }

    pub fn recordGateway(self: *CoordinatorOwner, request: GatewayRequest) !void {
        if (self.closed) return error.CoordinatorWriterClosed;
        var proof: ?history.LookupProof = null;
        if (self.coordinator.history_root != null) {
            const result = self.store.queryOrderHistory(self.io, self.coordinator.gatewayHistoryRequest(gatewayRecord(request), self.sequence + 1)) catch |err| {
                self.closed = true;
                return err;
            };
            proof = result.proof;
        }
        try self.apply(.{ .gateway_record = .{ .request = request, .proof = proof } });
    }

    /// A safe terminal OMS qualification pins Unknown and unresolved references.
    pub fn retireGateway(self: *CoordinatorOwner, shard_id: ShardId, command_id: u64, shard_owner: *const @import("demo_authority.zig").Owner) !void {
        const shard = try shard_owner.source();
        const summary = self.coordinator.summaries[@intFromEnum(shard_id)];
        if (!summary.present or summary.value.virtual_portfolio != shard.portfolio_identity) return error.CrossShardDelivery;
        if (self.closed) return error.CoordinatorWriterClosed;
        if (shard.exchange_account_identity != self.coordinator.exchange_account) return error.CrossAccountGatewayRequest;
        var record: ?GatewayRecord = null;
        for (self.coordinator.gateway_ownership.records[0..self.coordinator.gateway_ownership.count]) |known| {
            if (known.shard_id == shard_id and known.command_id == command_id) record = known;
        }
        const known = record orelse return error.UnknownGatewayCommand;
        const qualification = try shard.oms.prepareOrderArchive(known.order_id, try shard.economic_projection.appliedCanonicalFillQuantity(known.order_id), self.coordinator.exchange_account);
        if (qualification.order.revision < known.revision) return error.GatewayOutcomeIdentityConflict;
        var matched = false;
        for (shard.oms.command_history[0..shard.oms.command_history_count]) |command| {
            if (command.command_id != command_id) continue;
            if (!std.meta.eql(known, gatewayRecord(.{ .exchange_account = self.coordinator.exchange_account, .shard_id = shard_id, .fencing_token = known.fencing_token, .command = command }))) return error.GatewayOutcomeIdentityConflict;
            matched = true;
        }
        if (!matched) return error.UnknownGatewayCommand;
        const retirement: GatewayRetirement = .{ .record = known, .source_origin = .{ .stream = shard_owner.stream, .account = shard.exchange_account_identity }, .source_barrier = shard.authoritativeBarrier(), .source_digest = shard.canonicalStateDigest(), .order = qualification };
        var bytes: [1024]u8 = undefined;
        const encoded = try codec.encodeBare(&bytes, known);
        const origin: history.Origin = .{ .stream = self.stream, .account = self.coordinator.exchange_account };
        var retirement_bytes: [history.max_record_bytes]u8 = undefined;
        const encoded_retirement = try codec.encodeBare(&retirement_bytes, retirement);
        const records = [_]history.Record{ .{ .bytes = encoded, .payload_digest = history.hash(encoded) }, .{ .bytes = encoded_retirement, .payload_digest = history.hash(encoded_retirement) } };
        const entries = [_]history.Entry{
            .{ .key = .{ .origin = origin, .identity = .{ .coordinator_gateway_command = .{ .shard = @intFromEnum(shard_id), .command = command_id } } }, .record_index = 0 },
            .{ .key = .{ .origin = origin, .identity = .{ .coordinator_gateway_closure = .{ .shard = @intFromEnum(shard_id), .command = command_id } } }, .record_index = 1 },
        };
        errdefer self.closed = true;
        const receipt = try self.store.publishOrderHistory(self.io, .{ .origin = origin, .previous_root = self.coordinator.history_root, .barrier = self.sequence + 1, .epoch = if (self.coordinator.history_root) |root| root.epoch else 1, .qualification_digest = retirement.digest(), .records = &records, .entries = &entries });
        try self.applyCommitted(.{ .gateway_retire = .{ .qualification = retirement, .receipt = receipt } });
    }

    pub fn acceptAccountFact(self: *CoordinatorOwner, fact: AccountFact) !void {
        if (self.closed) return error.CoordinatorWriterClosed;
        if (self.coordinator.history_root == null) return self.apply(.{ .account_fact = fact });
        errdefer self.closed = true;
        const result = try self.store.queryOrderHistory(self.io, self.coordinator.accountFactHistoryRequest(fact, self.sequence + 1));
        try self.apply(.{ .forced_source_checked = .{ .fact = fact, .proof = result.proof } });
    }

    pub fn allocateForcedExecution(self: *CoordinatorOwner, allocation: ForcedExecutionAllocation) !void {
        if (self.coordinator.history_root == null) return self.apply(.{ .forced_execution_allocation = allocation });
        const request = self.coordinator.allocationHistoryRequest(allocation, self.sequence + 1);
        errdefer self.closed = true;
        const result = try self.store.queryOrderHistory(self.io, request);
        try self.apply(.{ .forced_history_checked = .{ .allocation = allocation, .proof = result.proof } });
    }

    pub fn ackForcedDelivery(self: *CoordinatorOwner, delivery: Delivery, shard_owner: *const @import("demo_authority.zig").Owner) !void {
        const shard = try shard_owner.source();
        const owner = self.coordinator.forced_source_owners[@intFromEnum(delivery.shard_id)];
        if (owner.portfolio != shard.portfolio_identity or shard.exchange_account_identity != self.coordinator.exchange_account) return error.CrossShardDelivery;
        var found = false;
        for (try self.coordinator.pendingForcedDeliveries()) |pending| {
            if (std.meta.eql(pending, delivery)) found = true;
        }
        if (!found or !try shardHasAppliedForced(delivery, shard)) return error.ForcedDeliveryNotCommitted;
        try self.applyCommitted(.{ .forced_delivery_ack = .{ .allocation_identity = delivery.allocation_identity, .slice_index = delivery.slice_index } });
    }

    /// Snapshot exact committed sequence, then seal/rotate without resetting it.
    pub fn completeRecovery(self: *CoordinatorOwner) !void {
        if (self.closed or self.store.safetyGate() != .open) return error.CoordinatorWriterClosed;
        // Runtime admission is never replayed as authority. A restart always
        // requires another committed fresh margin observation.
        try self.coordinator.completeRecovery();
    }

    pub fn checkpoint(self: *CoordinatorOwner) !void {
        if (self.closed) return error.CoordinatorWriterClosed;
        var state_bytes: [32768]u8 = undefined;
        const state = try self.coordinator.snapshot(state_bytes[8..]);
        std.mem.writeInt(u64, state_bytes[0..8], self.sequence, .little);
        errdefer self.closed = true;
        try self.store.seal(self.io, self.stream);
        try self.store.publishSnapshot(self.io, self.stream, self.sequence, state_bytes[0 .. state.len + 8]);
        try self.store.rotate(self.io, self.stream);
    }

    pub fn recover(stream: durable.StreamIdentity, store: durable.Store, io: std.Io) !CoordinatorOwner {
        const recovered = try store.recover(io, stream);
        var result: CoordinatorOwner = .{ .coordinator = undefined, .stream = stream, .store = store, .io = io };
        if (recovered.snapshot.len != 0) {
            if (recovered.snapshot.len < 8) return error.InvalidCoordinatorSnapshot;
            result.sequence = std.mem.readInt(u64, recovered.snapshot[0..8], .little);
            if (result.sequence != recovered.snapshot_barrier) return error.InvalidCoordinatorSnapshot;
            result = try bind(try AccountCoordinator.restore(recovered.snapshot[8..]), stream, store, io);
            result.sequence = recovered.snapshot_barrier;
        }
        const fallback = [_][]const u8{recovered.tail};
        const tails = if (recovered.tail_count != 0) recovered.tail_segments[0..recovered.tail_count] else &fallback;
        var has_uncommitted_suffix = false;
        for (tails) |tail| {
            if (tail.len == 0) continue;
            var reader = try trading.journal.Reader.init(tail);
            while (true) switch (try reader.next()) {
                .record => |record| {
                    if (record.sequence <= result.sequence) continue;
                    if (record.sequence > recovered.committed_barrier) {
                        has_uncommitted_suffix = true;
                        continue;
                    }
                    if (record.sequence != result.sequence + 1) return error.InvalidCoordinationTail;
                    if (result.sequence == 0) {
                        if (record.type_id != bootstrap_type or record.schema_version != @import("production_contract.zig").journal_schema_version) return error.InvalidCoordinationTail;
                        result = try bind(try AccountCoordinator.restore(record.payload), stream, store, io);
                    } else try result.coordinator.applyHistoricalEvent(try decodeCoordinationEvent(record));
                    result.sequence = record.sequence;
                },
                .end => |status| {
                    // A committed prefix has no footer when a later physical
                    // append was not committed. The Store retains that suffix;
                    // restore only the exact committed projection and quarantine.
                    if (status != .clean and result.sequence != recovered.committed_barrier)
                        return error.InvalidCoordinationTail;
                    break;
                },
            };
        }
        if (result.sequence == 0 or result.sequence != recovered.committed_barrier) return error.InvalidCoordinationTail;
        result.closed = has_uncommitted_suffix or recovered.status != .ready or recovered.last_sequence != recovered.committed_barrier;
        const origin: history.Origin = .{ .account = result.coordinator.exchange_account, .stream = stream };
        if (store.recoverOrderHistory(io, origin)) |published| {
            if (result.coordinator.history_root) |root| {
                if (!std.meta.eql(root, published.root)) result.closed = true;
            } else result.closed = true; // Published without a committed release.
        } else |err| {
            if (result.coordinator.history_root != null or err != error.OrderHistoryUnavailable) result.closed = true;
        }
        return result;
    }
};

test "coordinator history durable writer rotates beyond old journal capacity and recovers exact sequence" {
    const adapter = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(adapter);
    adapter.* = durable.MemoryAdapter.init();
    defer adapter.deinit();
    var owner = try CoordinatorOwner.init(AccountCoordinator.init(900, 1000, 1000), .{ .domain = .control, .id = 900 }, adapter.interface(), undefined);
    for (1..12001) |index| {
        try owner.apply(.{ .publish_summary = .{ .identity = index, .summary = ShardSummary.fixture(.shard_0, index, 1) } });
        if (index % 30 == 0) {
            const before = owner.coordinator.digest();
            try owner.checkpoint();
            owner = try CoordinatorOwner.recover(owner.stream, adapter.interface(), undefined);
            try std.testing.expectEqualDeep(before, owner.coordinator.digest());
            try std.testing.expectEqual(@as(u64, index + 1), owner.sequence);
            try std.testing.expect(owner.coordinator.recovery_only);
        }
    }
    try std.testing.expectEqual(@as(u64, 12000), owner.coordinator.summaries[0].value.shard_sequence);
    try std.testing.expect(adapter.archive_bytes > 10 * 192 * 1024);
}
