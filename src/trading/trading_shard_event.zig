//! Versioned TradingShard input schema and stable journal codec.

const std = @import("std");
const canonical = @import("../model/canonical_event.zig");
const economics_module = @import("../portfolio/economics.zig");
const host_gateway = @import("../strategy/strategy_host_gateway.zig");
const journal = @import("../persistence/journal.zig");
const oms_module = @import("../execution/oms.zig");
const operational = @import("operational.zig");
const production_contract = @import("../runtime/production_contract.zig");
const history_module = @import("../persistence/business_history.zig");
const snapshot_codec = @import("../persistence/snapshot_codec.zig");
const cold = @import("cold_business_candidate.zig");

pub const OrderArchiveCommit = struct {
    order_id: u64,
    applied_fill_quantity: i64,
    qualification_digest: [32]u8,
    receipt: history_module.Receipt,
};

pub const FillArchiveCommit = struct {
    fill_id: u64,
    qualification_digest: [32]u8,
    receipt: history_module.Receipt,
};

pub const FundingArchiveCommit = struct { funding_id: u64, qualification_digest: [32]u8, receipt: history_module.Receipt };
pub const ForcedArchiveCommit = struct { forced_id: u64, qualification_digest: [32]u8, receipt: history_module.Receipt, evidence: @import("../portfolio/forced_archive_proof.zig").Evidence };
pub const VersionActivationHistoryVerified = struct { activation: VersionActivationEvent, proof: history_module.LookupProof };
pub const ControlArchiveCommit = struct { qualification_digest: [32]u8, receipt: history_module.Receipt };
pub const ReconciliationArchiveCommit = struct { window_id: u128, qualification_digest: [32]u8, receipt: history_module.Receipt };

pub const HistorySafetyCandidateVerified = struct { pending: cold.PendingCandidate, proof: history_module.LookupProof };

pub const schema_version: u16 = production_contract.journal_schema_version;

pub const EventKind = enum(u16) {
    asset_definition_activated,
    asset_definition_rejected,
    instrument_rules_activated,
    margin_rules_activated,
    account_configuration,
    exchange_balance,
    exchange_positions,
    opening_balance,
    virtual_portfolio_activated,
    portfolio_transfer,
    strategy_activated,
    host_activated,
    host_activation_revoked,
    primary_lease_granted,
    risk_lease_granted,
    mark_price,
    l2_snapshot,
    l2_delta,
    market_healthy,
    market_gap,
    timer,
    order_intent,
    risk_accepted,
    risk_rejected_market_data,
    risk_rejected_lease,
    risk_reservation_created,
    order_command,
    order_dispatched,
    order_dispatch_unknown,
    order_reconciled_live,
    order_accepted,
    fill,
    fee_ledger_transaction,
    risk_reservation_rebalanced,
    order_partially_filled,
    order_filled,
    order_canceled,
    strategy_intent_rejected,
    oms_intent_group,
    oms_dispatch_batch,
    oms_execution_report,
    oms_reconciliation_result,
    economic_fill,
    funding_settlement,
    venue_forced_execution,
    economic_account_snapshot,
    control_command_applied,
    recovery_completed,
    safety_gate_changed,
    lifecycle_progressed,
    risk_warning_recorded,
    lease_gate_changed,
    version_activated,
    strategy_cutover_fenced,
    canonical_reconciliation_started,
    canonical_account_reconciliation_started,
    canonical_instrument_definition,
    canonical_index_price,
    canonical_funding_rate,
    canonical_account_bootstrap,
    canonical_account_observed,
    canonical_venue_configuration,
    canonical_order_reconciliation,
    canonical_account_reconciliation,
    order_not_sent,
    order_rejected,
    order_amended,
    canonical_account_invalidated,
    canonical_market_invalidated,
    capability_profile_activated,
    oms_intent_conflict,
    checkpoint_committed,
    instrument_trading_authorized,
    order_archive_committed,
    history_candidate_started,
    history_candidate_verified,
    history_candidate_conflict,
    canonical_history_deferred,
    canonical_history_admission_released,
    fill_archive_committed,
    funding_archive_committed,
    reconciliation_archive_committed,
    economic_open_commitment,
    control_archive_committed,
    forced_archive_committed,
    account_coordinator_bound,
    deployment_configuration_staged,
    deployment_configuration_sealed,
    decision_domain_bound,
    cycle_occupied,
    cycle_closed,
};

pub const Fact = struct {
    sequence: u64,
    identity: u64,
    kind: EventKind,
    reject_reason: RejectReason = .none,
    input_digest: [32]u8 = @splat(0),
    input_first: bool = false,
    economic_open_digest: ?[32]u8 = null,
};

pub const CheckpointReceipt = struct {
    version: u16 = 1,
    stream: u64,
    generation: u64,
    first_sequence: u64,
    barrier: u64,
    history_head: [32]u8,
    input_head: [32]u8,
    previous_checkpoint_root: [32]u8,
    snapshot_digest: [32]u8,
    pinned_fact_root: [32]u8,
    archive_root: [32]u8,
    checkpoint_root: [32]u8,
};

pub const Trace = struct {
    events: [256]Fact = undefined,
    len: usize = 0,
    base_sequence: u64 = 0,
    last_sequence: u64 = 0,
    base_history_head: [32]u8 = @splat(0),
    history_head: [32]u8 = @splat(0),
    base_input_head: [32]u8 = @splat(0),
    input_head: [32]u8 = @splat(0),
    pinned: [8192]Fact = undefined,
    pinned_len: usize = 0,
    pinned_root: [32]u8 = @splat(0),

    pub fn factHead(previous: [32]u8, fact: Fact) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("OrderedShardFactV1\x00");
        hasher.update(&previous);
        var sequence: [8]u8 = undefined;
        std.mem.writeInt(u64, &sequence, fact.sequence, .little);
        hasher.update(&sequence);
        std.mem.writeInt(u64, &sequence, fact.identity, .little);
        hasher.update(&sequence);
        var kind: [2]u8 = undefined;
        std.mem.writeInt(u16, &kind, @intFromEnum(fact.kind), .little);
        hasher.update(&kind);
        hasher.update(&.{ @intFromEnum(fact.reject_reason), @intFromBool(fact.input_first) });
        hasher.update(&fact.input_digest);
        hasher.update(&.{@intFromBool(fact.economic_open_digest != null)});
        if (fact.economic_open_digest) |digest| hasher.update(&digest);
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn inputHead(previous: [32]u8, fact: Fact) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("OrderedShardInputV1\x00");
        hasher.update(&previous);
        var sequence: [8]u8 = undefined;
        std.mem.writeInt(u64, &sequence, fact.sequence, .little);
        hasher.update(&sequence);
        hasher.update(&fact.input_digest);
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    pub fn validate(self: *const Trace) !void {
        // shortcut: bounded linear pin validation; index only if measured lookup cost requires it.
        if (self.len > self.events.len or self.pinned_len > self.pinned.len or
            self.last_sequence != try std.math.add(u64, self.base_sequence, @intCast(self.len))) return error.InvalidTrace;
        var history = self.base_history_head;
        var inputs = self.base_input_head;
        for (self.events[0..self.len], 0..) |fact, index| {
            if (fact.sequence != try std.math.add(u64, self.base_sequence, @as(u64, @intCast(index)) + 1)) return error.InvalidTrace;
            if ((fact.kind == .economic_open_commitment) != (fact.economic_open_digest != null)) return error.InvalidTrace;
            history = factHead(history, fact);
            if (fact.input_first) inputs = inputHead(inputs, fact);
        }
        if (!std.mem.eql(u8, &history, &self.history_head) or !std.mem.eql(u8, &inputs, &self.input_head)) return error.InvalidTrace;
        for (self.pinned[0..self.pinned_len], 0..) |fact, index| {
            if ((fact.kind == .economic_open_commitment) != (fact.economic_open_digest != null)) return error.InvalidTrace;
            if (fact.sequence == 0 or fact.sequence > self.base_sequence or
                (index > 0 and self.pinned[index - 1].sequence >= fact.sequence)) return error.InvalidTrace;
        }
        if ((self.base_sequence != 0 or self.pinned_len != 0) and !std.mem.eql(u8, &self.pinned_root, &self.pinnedDigest())) return error.InvalidTrace;
    }

    pub fn pinnedDigest(self: *const Trace) [32]u8 {
        var head: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("PinnedShardFactsV1\x00", &head, .{});
        for (self.pinned[0..self.pinned_len]) |fact| head = factHead(head, fact);
        return head;
    }

    pub fn factAt(self: *const Trace, sequence: u64) ?Fact {
        if (sequence == 0 or sequence > self.last_sequence or self.len > self.events.len or self.pinned_len > self.pinned.len) return null;
        for (self.events[0..self.len]) |fact| if (fact.sequence == sequence) return fact;
        for (self.pinned[0..self.pinned_len]) |fact| if (fact.sequence == sequence) return fact;
        return null;
    }

    pub fn factsAfter(self: *const Trace, barrier: u64) ![]const Fact {
        if (barrier < self.base_sequence or barrier > self.last_sequence or self.len > self.events.len or
            barrier - self.base_sequence > self.len) return error.InvalidTrace;
        return self.events[@intCast(barrier - self.base_sequence)..self.len];
    }

    pub fn finalizeInput(self: *Trace, barrier: u64, digest: [32]u8) !void {
        const first: usize = @intCast(barrier - self.base_sequence);
        if (first >= self.len) return;
        for (self.events[first..self.len], 0..) |*fact, index| {
            fact.input_digest = digest;
            fact.input_first = index == 0;
        }
        self.history_head = self.base_history_head;
        self.input_head = self.base_input_head;
        for (self.events[0..self.len]) |fact| {
            self.history_head = factHead(self.history_head, fact);
            if (fact.input_first) self.input_head = inputHead(self.input_head, fact);
        }
    }

    pub fn append(self: *Trace, kind: EventKind, identity: u64) !void {
        try self.appendRejection(kind, identity, .none);
    }

    pub fn appendRejection(self: *Trace, kind: EventKind, identity: u64, reason: RejectReason) !void {
        try self.appendFact(kind, identity, reason, null);
    }

    pub fn appendEconomicCommitment(self: *Trace, identity: u64, digest: [32]u8) !void {
        try self.appendFact(.economic_open_commitment, identity, .none, digest);
    }

    fn appendFact(self: *Trace, kind: EventKind, identity: u64, reason: RejectReason, economic_digest: ?[32]u8) !void {
        if ((kind == .economic_open_commitment) != (economic_digest != null)) return error.InvalidTrace;
        const sequence = try std.math.add(u64, self.last_sequence, 1);
        try self.validate();
        if (traceCapacityReached(self.len)) return error.TraceFull;
        const fact: Fact = .{ .sequence = sequence, .kind = kind, .identity = identity, .reject_reason = reason, .economic_open_digest = economic_digest };
        self.events[self.len] = fact;
        self.len += 1;
        self.last_sequence = sequence;
        self.history_head = factHead(self.history_head, fact);
    }
};

fn traceCapacityReached(count: usize) bool {
    return count >= @typeInfo(@FieldType(Trace, "events")).array.len;
}

test "09 boundary Trace guard rejects full and excess counts without populating facts" {
    try std.testing.expect(!traceCapacityReached(255));
    try std.testing.expect(traceCapacityReached(256));
    try std.testing.expect(traceCapacityReached(257));
    try std.testing.expect(traceCapacityReached(std.math.maxInt(usize)));
}

pub const MarketHealth = enum(u8) { initializing, healthy, gap };
/// Stable decision rejection taxonomy.  The trace may group these into a
/// coarse risk event, but the authoritative state retains the exact layer.
pub const RejectReason = enum(u8) {
    none,
    authorization_closed,
    market_data_gap,
    strategy_limit_exceeded,
    portfolio_limit_exceeded,
    decision_domain_limit_exceeded,
    exchange_account_limit_exceeded,
    global_limit_exceeded,
    portfolio_opening_gate_closed,
    exchange_opening_gate_closed,
    insufficient_spot_asset,
    portfolio_reduce_only_violation,
    unsupported_order_spec,
    host_not_activated,
    identity_mismatch,
    intent_identity_conflict,
    open_order,
    capability_unsupported,
    invalid_cursor,
    margin_safety_gate_closed,
    identity_capacity_exhausted,
    stale_canonical_source,
    joint_admission_unavailable,
    host_output_stale,
    instrument_occupied,
    cycle_capacity_exhausted,
    admission_capacity_exhausted,
    invalid_scope,
    arithmetic_overflow,
};

pub const TimerRequest = struct {
    side: host_gateway.Side,
    time_in_force: host_gateway.TimeInForce,
    portfolio_reduce_only: bool,
    quantity: i64,
    limit_price_micros: i64,
};

pub const EconomicFill = struct {
    fill_id: u64,
    order_id: u64,
    quantity: i64,
    price_ticks: i64,
    fee_atoms: i128 = 0,
    rebate_atoms: i128 = 0,
};

pub const FundingSettlement = struct { settlement_id: u64, amount_atoms: i128, instrument: u128 = 0 };
pub const VenueForcedExecution = struct {
    execution_id: u64,
    source_identity: u128 = 0,
    side: oms_module.Side,
    quantity: i64,
    price_ticks: i64,
    fee_atoms: i128 = 0,
    penalty_atoms: i128 = 0,
    expected_realized_pnl_atoms: ?i128 = null,
};
pub const EconomicAccountSnapshot = struct {
    snapshot_id: u64,
    usdt_balance_atoms: i128,
    spot_asset_atoms: i128,
    swap_position_quantity: i64,
    margin_atoms: i128,
};

pub const EconomicSummary = struct {
    portfolio: economics_module.Layer,
    exchange: economics_module.Layer,
    treasury_usdt_atoms: i128,
    suspense_usdt_atoms: i128,
    ledger_transactions: u8,
    reconciliation_break: bool,
    valuation_complete: bool,
    treasury_native_assets: [economics_module.max_native_assets]canonical.AssetAmount,
    treasury_native_asset_count: u8,
    suspense_native_assets: [economics_module.max_native_assets]canonical.AssetAmount,
    suspense_native_asset_count: u8,
};

pub const PayloadTag = enum(u16) {
    asset_definition_activated,
    instrument_rules_activated,
    margin_rules_activated,
    account_configuration,
    exchange_balance,
    exchange_positions,
    opening_balance,
    virtual_portfolio_activated,
    portfolio_transfer,
    strategy_activated,
    host_activated,
    host_activation_revoked,
    primary_lease_granted,
    risk_lease_granted,
    mark_price,
    timer,
    external_order_intent,
    strategy_intent_rejected,
    oms_intent_group,
    oms_dispatch_batch,
    oms_execution_report,
    oms_reconciliation_result,
    economic_fill,
    funding_settlement,
    venue_forced_execution,
    economic_account_snapshot,
    control_command,
    recovery_completed,
    safety_gate_change,
    lifecycle_progress,
    risk_warning,
    lease_gate_change,
    version_activation,
    strategy_cutover_fence,
    capability_profile_activation,
    checkpoint_committed,
    instrument_trading_authorization,
    order_archive_committed,
    history_candidate_started,
    history_candidate_verified,
    fill_archive_committed,
    history_safety_candidate_verified,
    funding_archive_committed,
    reconciliation_archive_committed,
    control_archive_committed,
    forced_archive_committed,
    version_activation_history_verified,
    account_coordinator_bound,
    external_intent_group,
    deployment_configuration,
    decision_domain_bound,
    cycle_closed,
};

pub const ReservationModel = enum(u8) { leveraged, cash };
pub const Product = canonical.Product;

pub const InstrumentRules = struct {
    version: u32,
    instrument_identity: u128,
    quantity_denominator: i64,
    quantity_numerator: i64 = 1,
    reservation_model: ReservationModel,
    /// Explicit product semantics. A zero-value legacy Genesis is normalized
    /// from reservation_model at the compatibility boundary only.
    product: Product = .isolated_linear_usdt,
    venue: canonical.VenueIdentity = 0,
    settlement_asset: canonical.AssetIdentity = 1,
    base_asset: canonical.AssetIdentity = 0,
};

pub const MarginRules = struct {
    version: u32,
    native_settlement_atoms: bool = false,
    instrument: canonical.InstrumentIdentity = 0,
    price_tick_atoms: i128 = 1,
    venue_initial_margin_ppm: i64 = 20_000,
    internal_initial_margin_ppm: i64 = 22_000,
    internal_maintenance_margin_ppm: i64 = 11_000,
    fee_ppm: i64 = 750,
    opening_buffer_atoms: i128 = 0,
    opening_buffer_bps: i64 = 0,
    opening_liquidation_distance_ticks: i64 = 0,
    warning_buffer_atoms: i128 = 0,
    kill_buffer_atoms: i128 = 0,
    warning_buffer_bps: i64 = 0,
    kill_buffer_bps: i64 = 0,
    warning_liquidation_distance_ticks: i64 = 0,
    kill_liquidation_distance_ticks: i64 = 0,
};
pub const AccountConfiguration = struct { exchange_account_identity: u128 };
pub const Balance = struct { cash_atoms: i128 };
pub const OpeningBalance = struct {
    cash_atoms: i128,
    native_balances: [economics_module.max_native_assets]canonical.AssetAmount = @splat(.{ .asset = 0, .atoms = 0 }),
    native_balance_count: u8 = 0,
};
pub const VirtualPortfolioActivation = struct { portfolio_identity: u128 };
pub const PortfolioTransfer = struct { amount_atoms: i128 };
pub const StrategyActivation = struct {
    strategy_identity: u128,
    config_version: u64,
    activation_identity: u128,
};
/// Persisted authorization fact required before a StrategyHost session may
/// submit an external intent.  Strategy deployment and host capability
/// activation are deliberately separate facts.
pub const HostActivated = struct {
    strategy_identity: u128,
    config_version: u64,
    activation_identity: u128,
    session: @import("../strategy/strategy_host_ipc.zig").Session,
    activation_barrier: u64,
    state_digest: [32]u8,
};
pub const HostRevocationReason = enum(u8) { fault, control, session_replaced };
pub const HostActivationRevoked = struct {
    strategy_identity: u128,
    activation_identity: u128,
    reason: HostRevocationReason,
};
pub const PrimaryLease = struct { fencing_token: u64 };
pub const MarkPrice = struct { instrument: canonical.InstrumentIdentity, price_atoms: i128 };
pub const RiskLease = struct {
    allocation: ?struct { configuration_digest: [32]u8, account: u128, asset: u64, domain: u128, stream: u64 } = null,
    lease_identity: u64 = 0,
    version: u64 = 1,
    valid_through_barrier: u64 = std.math.maxInt(u64),
    open: bool = true,
    amount_atoms: i128,
    strategy_limit_atoms: i128 = 0,
    portfolio_limit_atoms: i128 = 0,
    exchange_account_limit_atoms: i128 = 0,
    global_limit_atoms: i128 = 0,
};
/// Stable strategy-scoped intent fence used during cutover.
pub const StrategyCutoverFence = struct { strategy_instance: u128 };
/// Stable strategy-private-state handling recorded at cutover.
pub const StrategyStateTransition = enum(u8) { keep, migrate, rebuild };
/// Immutable fact selecting the sole active release after one cutover barrier.
pub const VersionActivationEvent = struct {
    activation_identity: u128,
    generation: u64,
    old_release: u64,
    new_release: u64,
    old_strategy_instance: u128,
    new_strategy_instance: u128,
    strategy_definition: u128,
    parameter_version: u64,
    state_schema_version: u32,
    transition: StrategyStateTransition,
    barrier: u64,
    canonical_state_digest: [32]u8,
};

/// A scoped, versioned capability fact supplied by the qualification owner.
/// This is not a trading authorization or a replayable send permit.
pub const CapabilityProfileActivation = struct {
    pub const Environment = enum(u8) { simulation, demo, testnet, production };
    exchange_account: canonical.ExchangeAccountIdentity,
    instrument: canonical.InstrumentIdentity,
    venue: canonical.VenueIdentity,
    environment: Environment,
    product: Product,
    version: u64,
    rules_version: u64,
    config_version: u64,
    adapter_session: canonical.AdapterSessionIdentity,
    max_dispatch_age_ns: u64,
    supports_place: bool,
    supports_cancel: bool,
    supports_native_amend: bool,
    supports_venue_reduce_only: bool,
    supports_post_only: bool,
    supports_market_protection: bool,
};

pub const InstrumentTradingAuthorization = struct {
    exchange_account: canonical.ExchangeAccountIdentity,
    instrument: canonical.InstrumentIdentity,
    strategy_activation_identity: u128,
    config_version: u64,
    expected_version: u64,
    enabled: bool,
};

pub const CorePayload = union(PayloadTag) {
    asset_definition_activated: canonical.AssetDefinition,
    instrument_rules_activated: InstrumentRules,
    margin_rules_activated: MarginRules,
    account_configuration: AccountConfiguration,
    exchange_balance: Balance,
    exchange_positions,
    opening_balance: OpeningBalance,
    virtual_portfolio_activated: VirtualPortfolioActivation,
    portfolio_transfer: PortfolioTransfer,
    strategy_activated: StrategyActivation,
    host_activated: HostActivated,
    host_activation_revoked: HostActivationRevoked,
    primary_lease_granted: PrimaryLease,
    risk_lease_granted: RiskLease,
    mark_price: MarkPrice,
    timer: TimerRequest,
    external_order_intent: host_gateway.OrderIntent,
    strategy_intent_rejected: host_gateway.Rejection,
    oms_intent_group: oms_module.IntentGroup,
    oms_dispatch_batch: oms_module.DispatchBatch,
    oms_execution_report: oms_module.ExecutionReport,
    oms_reconciliation_result: oms_module.ReconciliationResult,
    economic_fill: EconomicFill,
    funding_settlement: FundingSettlement,
    venue_forced_execution: VenueForcedExecution,
    economic_account_snapshot: EconomicAccountSnapshot,
    control_command: operational.ControlCommand,
    recovery_completed,
    safety_gate_change: operational.SafetyGateChange,
    lifecycle_progress: operational.LifecycleProgress,
    risk_warning: operational.RiskWarning,
    lease_gate_change: operational.SafetyGateChange,
    version_activation: VersionActivationEvent,
    strategy_cutover_fence: StrategyCutoverFence,
    capability_profile_activation: CapabilityProfileActivation,
    checkpoint_committed: CheckpointReceipt,
    instrument_trading_authorization: InstrumentTradingAuthorization,
    order_archive_committed: OrderArchiveCommit,
    history_candidate_started: cold.PendingCandidate,
    history_candidate_verified: history_module.LookupProof,
    fill_archive_committed: FillArchiveCommit,
    history_safety_candidate_verified: HistorySafetyCandidateVerified,
    funding_archive_committed: FundingArchiveCommit,
    reconciliation_archive_committed: ReconciliationArchiveCommit,
    control_archive_committed: ControlArchiveCommit,
    forced_archive_committed: ForcedArchiveCommit,
    version_activation_history_verified: VersionActivationHistoryVerified,
    account_coordinator_bound: history_module.Origin,
    external_intent_group: host_gateway.GroupCandidate,
    deployment_configuration: @import("deployment_allocation.zig").Input,
    decision_domain_bound: @import("deployment_allocation.zig").DomainBinding,
    cycle_closed: @import("cycle_occupancy.zig").Closure,
};

/// Typed core-originated event carried by the authoritative CanonicalEvent.
pub const CoreEvent = struct {
    identity: u64,
    account_scope: ?canonical.ExchangeAccountIdentity = null,
    source_time: u64 = 0,
    receive_time: u64 = 0,
    monotonic_time: u64 = 0,
    wall_time: u64 = 0,
    time_presence: journal.TimePresence = .{},
    payload: CorePayload,
};

/// The only event admitted by TradingShard, stable journal and replay.
pub const CanonicalEvent = union(enum) {
    core: CoreEvent,
    venue: canonical.EventRecord,
};

pub const EncodedInput = struct {
    bytes: []u8,
    len: usize = 0,

    fn init(bytes: []u8) @This() {
        return .{ .bytes = bytes };
    }

    fn put(self: *EncodedInput, comptime T: type, value: T) !void {
        if (self.bytes.len - self.len < @sizeOf(T)) return error.InputPayloadTooLarge;
        std.mem.writeInt(T, self.bytes[self.len..][0..@sizeOf(T)], value, .little);
        self.len += @sizeOf(T);
    }
};

pub fn encodeInput(destination: []u8, input: CoreEvent) !EncodedInput {
    var encoded = EncodedInput.init(destination);
    try encoded.put(u64, input.identity);
    try encoded.put(u16, @intFromEnum(std.meta.activeTag(input.payload)));
    try encoded.put(u8, @intFromBool(input.account_scope != null));
    if (input.account_scope) |account| try encoded.put(u128, account);
    switch (input.payload) {
        .cycle_closed => |value| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], value);
            encoded.len += bytes.len;
        },
        .decision_domain_bound => |value| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], value);
            encoded.len += bytes.len;
        },
        .deployment_configuration => |value| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], value);
            encoded.len += bytes.len;
        },
        .external_intent_group => |value| {
            if (value.len > value.bytes.len) return error.InvalidIntentGroup;
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], value);
            encoded.len += bytes.len;
        },
        .history_candidate_started => |pending| {
            const bytes = try cold.encodeCompact(encoded.bytes[encoded.len..], &pending);
            encoded.len += bytes.len;
        },
        .history_candidate_verified => |proof| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], proof);
            encoded.len += bytes.len;
        },
        .history_safety_candidate_verified => |verified| {
            const length_offset = encoded.len;
            try encoded.put(u32, 0);
            const pending_bytes = try cold.encodeCompact(encoded.bytes[encoded.len..], &verified.pending);
            std.mem.writeInt(u32, encoded.bytes[length_offset..][0..4], @intCast(pending_bytes.len), .little);
            encoded.len += pending_bytes.len;
            const proof_bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], verified.proof);
            encoded.len += proof_bytes.len;
        },
        .order_archive_committed => |commit| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], commit);
            encoded.len += bytes.len;
        },
        .version_activation_history_verified => |verified| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], verified);
            encoded.len += bytes.len;
        },
        .account_coordinator_bound => |origin| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], origin);
            encoded.len += bytes.len;
        },
        .forced_archive_committed => |commit| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], commit);
            encoded.len += bytes.len;
        },
        .control_archive_committed => |commit| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], commit);
            encoded.len += bytes.len;
        },
        .funding_archive_committed => |commit| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], commit);
            encoded.len += bytes.len;
        },
        .reconciliation_archive_committed => |commit| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], commit);
            encoded.len += bytes.len;
        },
        .fill_archive_committed => |commit| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], commit);
            encoded.len += bytes.len;
        },
        .checkpoint_committed => |receipt| {
            inline for (std.meta.fields(CheckpointReceipt)) |field| {
                const value = @field(receipt, field.name);
                switch (@typeInfo(field.type)) {
                    .int => try encoded.put(field.type, value),
                    .array => for (value) |byte| try encoded.put(u8, byte),
                    else => unreachable,
                }
            }
        },
        .asset_definition_activated => |value| {
            inline for (std.meta.fields(canonical.AssetDefinition)) |field| {
                const item = @field(value, field.name);
                switch (@typeInfo(field.type)) {
                    .int => try encoded.put(field.type, item),
                    .@"enum" => try encoded.put(u8, @intFromEnum(item)),
                    .array => if (comptime std.mem.eql(u8, field.name, "code_bindings")) {
                        for (item) |binding| {
                            try encoded.put(u64, binding.venue);
                            try encoded.put(u8, binding.code_len);
                            for (binding.code) |byte| try encoded.put(u8, byte);
                        }
                    } else for (item) |byte| try encoded.put(u8, byte),
                    else => unreachable,
                }
            }
        },
        .instrument_rules_activated => |value| {
            try encoded.put(u32, value.version);
            try encoded.put(u128, value.instrument_identity);
            try encoded.put(i64, value.quantity_denominator);
            try encoded.put(i64, value.quantity_numerator);
            try encoded.put(u8, @intFromEnum(value.reservation_model));
            try encoded.put(u8, @intFromEnum(value.product));
            try encoded.put(u64, value.venue);
            try encoded.put(u64, value.settlement_asset);
            try encoded.put(u64, value.base_asset);
        },
        .margin_rules_activated => |value| {
            try encoded.put(u8, @intFromBool(value.native_settlement_atoms));
            try encoded.put(u32, value.version);
            try encoded.put(u128, value.instrument);
            try encoded.put(i128, value.price_tick_atoms);
            try encoded.put(i64, value.venue_initial_margin_ppm);
            try encoded.put(i64, value.internal_initial_margin_ppm);
            try encoded.put(i64, value.internal_maintenance_margin_ppm);
            try encoded.put(i64, value.fee_ppm);
            try encoded.put(i128, value.opening_buffer_atoms);
            try encoded.put(i64, value.opening_buffer_bps);
            try encoded.put(i64, value.opening_liquidation_distance_ticks);
            try encoded.put(i128, value.warning_buffer_atoms);
            try encoded.put(i128, value.kill_buffer_atoms);
            try encoded.put(i64, value.warning_buffer_bps);
            try encoded.put(i64, value.kill_buffer_bps);
            try encoded.put(i64, value.warning_liquidation_distance_ticks);
            try encoded.put(i64, value.kill_liquidation_distance_ticks);
        },
        .account_configuration => |value| try encoded.put(u128, value.exchange_account_identity),
        .exchange_balance => |value| try encoded.put(i128, value.cash_atoms),
        .opening_balance => |value| {
            if (value.native_balance_count > value.native_balances.len) return error.InvalidOpeningBalance;
            try encoded.put(i128, value.cash_atoms);
            try encoded.put(u8, value.native_balance_count);
            for (value.native_balances[0..value.native_balance_count]) |balance| {
                try encoded.put(u64, balance.asset);
                try encoded.put(i128, balance.atoms);
            }
        },
        .virtual_portfolio_activated => |value| try encoded.put(u128, value.portfolio_identity),
        .portfolio_transfer => |value| try encoded.put(i128, value.amount_atoms),
        .strategy_activated => |value| {
            try encoded.put(u128, value.strategy_identity);
            try encoded.put(u64, value.config_version);
            try encoded.put(u128, value.activation_identity);
        },
        .host_activated => |value| {
            try encoded.put(u128, value.strategy_identity);
            try encoded.put(u64, value.config_version);
            try encoded.put(u128, value.activation_identity);
            try encoded.put(u64, value.session.fencing);
            try encoded.put(u32, value.session.shard);
            try encoded.put(u64, value.session.generation);
            try encoded.put(u64, value.activation_barrier);
            for (value.state_digest) |byte| try encoded.put(u8, byte);
        },
        .host_activation_revoked => |value| {
            try encoded.put(u128, value.strategy_identity);
            try encoded.put(u128, value.activation_identity);
            try encoded.put(u8, @intFromEnum(value.reason));
        },
        .primary_lease_granted => |value| try encoded.put(u64, value.fencing_token),
        .risk_lease_granted => |value| {
            const bytes = try snapshot_codec.encodeBare(encoded.bytes[encoded.len..], value);
            encoded.len += bytes.len;
        },
        .mark_price => |value| {
            try encoded.put(u128, value.instrument);
            try encoded.put(i128, value.price_atoms);
        },
        .timer => |value| {
            try encoded.put(u8, @intFromEnum(value.side));
            try encoded.put(u8, @intFromEnum(value.time_in_force));
            try encoded.put(u8, @intFromBool(value.portfolio_reduce_only));
            try encoded.put(i64, value.quantity);
            try encoded.put(i64, value.limit_price_micros);
        },
        .external_order_intent => |value| {
            try encoded.put(u128, value.strategy_identity);
            try encoded.put(u64, value.intent_sequence);
            try encoded.put(u64, value.strategy_cursor);
            try encoded.put(u64, value.config_version);
            try encoded.put(u128, value.activation_identity);
            try encoded.put(u128, value.portfolio_identity);
            try encoded.put(u128, value.exchange_account_identity);
            try encoded.put(u128, value.instrument_identity);
            try encoded.put(u8, @intFromEnum(value.side));
            try encoded.put(u8, @intFromEnum(value.order_type));
            try encoded.put(u8, @intFromEnum(value.time_in_force));
            try encoded.put(u8, @intFromBool(value.portfolio_reduce_only));
            try encoded.put(i64, value.quantity);
            try encoded.put(i64, value.limit_price_micros);
        },
        .strategy_intent_rejected => |value| {
            try encoded.put(u16, @intFromEnum(value.reason));
            try encoded.put(u128, value.strategy_identity);
            try encoded.put(u64, value.intent_sequence);
        },
        .oms_intent_group => |value| {
            if (value.count > value.members.len) return error.InvalidIntentGroup;
            try encoded.put(u64, value.first_intent_sequence);
            try encoded.put(u8, @intFromEnum(value.policy));
            try encoded.put(u8, value.count);
            for (value.members[0..value.count]) |member| {
                if (member.client_order_id.len > member.client_order_id.bytes.len) return error.InvalidIntentGroup;
                try encoded.put(u64, member.intent_sequence);
                try encoded.put(u128, member.strategy_instance);
                try encoded.put(u128, member.exchange_account);
                try encoded.put(u8, @intFromEnum(member.operation));
                try encoded.put(u128, member.instrument);
                try encoded.put(u8, @intFromEnum(member.side));
                try encoded.put(u8, @intFromBool(member.portfolio_reduce_only));
                try encoded.put(u8, @intFromBool(member.venue_reduce_only));
                try encoded.put(u64, member.target_order_id);
                try encoded.put(u32, member.expected_revision);
                try encoded.put(i64, member.expected_cumulative_quantity);
                try encoded.put(i64, member.quantity);
                try encoded.put(u128, member.limit_price.instrument);
                try encoded.put(u64, member.limit_price.rules_version);
                try encoded.put(i128, member.limit_price.ticks);
                try encoded.put(u8, @intFromBool(member.native_amend));
                try encoded.put(u8, @intFromBool(member.allow_cancel_confirm_create));
                try encoded.put(u64, member.reservation.asset);
                try encoded.put(i128, member.reservation.atoms);
                try encoded.put(u8, @intFromEnum(member.order_type));
                try encoded.put(u8, @intFromEnum(member.time_in_force));
                try encoded.put(u8, @intFromBool(member.market_protection_price != null));
                if (member.market_protection_price) |price| {
                    try encoded.put(u128, price.instrument);
                    try encoded.put(u64, price.rules_version);
                    try encoded.put(i128, price.ticks);
                }
                try encoded.put(u8, member.client_order_id.len);
                for (member.client_order_id.slice()) |byte| try encoded.put(u8, byte);
            }
        },
        .oms_dispatch_batch => |value| {
            if (value.count > value.items.len) return error.InvalidDispatchBatch;
            try encoded.put(u8, value.count);
            for (value.items[0..value.count]) |item| {
                try encoded.put(u64, item.command_id);
                try encoded.put(u8, @intFromEnum(item.state));
                try encoded.put(u8, @intFromBool(item.definite_reject));
            }
        },
        .oms_execution_report => |value| {
            try encoded.put(u64, value.report_id);
            try encoded.put(u64, value.order_id);
            try encoded.put(u32, value.revision);
            try encoded.put(u8, @intFromEnum(value.status));
            try encoded.put(i64, value.cumulative_quantity);
            try encoded.put(i64, value.remaining_quantity);
        },
        .oms_reconciliation_result => |value| {
            try encoded.put(u64, value.reconciliation_id);
            try encoded.put(u64, value.order_id);
            try encoded.put(u8, @intFromEnum(value.status));
            try encoded.put(u32, value.revision);
            try encoded.put(i64, value.cumulative_quantity);
            try encoded.put(i64, value.remaining_quantity);
            try encoded.put(u8, @intFromBool(value.terminal_state != null));
            if (value.terminal_state) |terminal| try encoded.put(u8, @intFromEnum(terminal));
        },
        .economic_fill => |value| {
            try encoded.put(u64, value.fill_id);
            try encoded.put(u64, value.order_id);
            try encoded.put(i64, value.quantity);
            try encoded.put(i64, value.price_ticks);
            try encoded.put(i128, value.fee_atoms);
            try encoded.put(i128, value.rebate_atoms);
        },
        .funding_settlement => |value| {
            try encoded.put(u64, value.settlement_id);
            try encoded.put(i128, value.amount_atoms);
            try encoded.put(u128, value.instrument);
        },
        .venue_forced_execution => |value| {
            try encoded.put(u64, value.execution_id);
            try encoded.put(u128, value.source_identity);
            try encoded.put(u8, @intFromEnum(value.side));
            try encoded.put(i64, value.quantity);
            try encoded.put(i64, value.price_ticks);
            try encoded.put(i128, value.fee_atoms);
            try encoded.put(i128, value.penalty_atoms);
            try encoded.put(u8, @intFromBool(value.expected_realized_pnl_atoms != null));
            if (value.expected_realized_pnl_atoms) |pnl| try encoded.put(i128, pnl);
        },
        .economic_account_snapshot => |value| {
            try encoded.put(u64, value.snapshot_id);
            try encoded.put(i128, value.usdt_balance_atoms);
            try encoded.put(i128, value.spot_asset_atoms);
            try encoded.put(i64, value.swap_position_quantity);
            try encoded.put(i128, value.margin_atoms);
        },
        .control_command => |value| {
            try encoded.put(u128, value.command_identity);
            try encoded.put(u128, value.content_hash);
            try encoded.put(u128, value.target_identity);
            try encoded.put(u64, value.expected_version);
            try encoded.put(u64, value.expires_at);
            try encoded.put(u8, @intFromEnum(value.kind));
            try encoded.put(i64, value.target_position);
            try encoded.put(u128, value.referenced_latch_identity);
            try encoded.put(u8, @intFromBool(value.risk_warning_acknowledged));
            try encoded.put(u128, value.risk_warning_identity);
        },
        .recovery_completed => {},
        .safety_gate_change => |value| {
            try encoded.put(u128, value.gate_identity);
            try encoded.put(u128, value.target_identity);
            try encoded.put(u8, @intFromEnum(value.kind));
            try encoded.put(u8, @intFromEnum(value.reason));
            try encoded.put(u8, @intFromBool(value.open));
            try encoded.put(u8, @intFromBool(value.continuity_proven));
            try encoded.put(u8, @intFromBool(value.blocks_buy));
            try encoded.put(u8, @intFromBool(value.blocks_sell));
        },
        .lifecycle_progress => |value| {
            try encoded.put(u128, value.operation_identity);
            try encoded.put(u128, value.target_identity);
            try encoded.put(u8, @intFromBool(value.open_orders_closed));
            try encoded.put(u8, @intFromBool(value.reconciliation_complete));
            try encoded.put(i64, value.position_quantity);
        },
        .risk_warning => |value| {
            try encoded.put(u128, value.warning_identity);
            try encoded.put(u128, value.target_identity);
        },
        .lease_gate_change => |value| {
            try encoded.put(u128, value.gate_identity);
            try encoded.put(u128, value.target_identity);
            try encoded.put(u8, @intFromEnum(value.reason));
            try encoded.put(u8, @intFromBool(value.open));
        },
        .strategy_cutover_fence => |value| try encoded.put(u128, value.strategy_instance),
        .version_activation => |value| {
            try encoded.put(u128, value.activation_identity);
            try encoded.put(u64, value.generation);
            try encoded.put(u64, value.old_release);
            try encoded.put(u64, value.new_release);
            try encoded.put(u128, value.old_strategy_instance);
            try encoded.put(u128, value.new_strategy_instance);
            try encoded.put(u128, value.strategy_definition);
            try encoded.put(u64, value.parameter_version);
            try encoded.put(u32, value.state_schema_version);
            try encoded.put(u8, @intFromEnum(value.transition));
            try encoded.put(u64, value.barrier);
            for (value.canonical_state_digest) |byte| try encoded.put(u8, byte);
        },
        .capability_profile_activation => |value| {
            try encoded.put(u128, value.exchange_account);
            try encoded.put(u128, value.instrument);
            try encoded.put(u64, value.venue);
            try encoded.put(u8, @intFromEnum(value.environment));
            try encoded.put(u8, @intFromEnum(value.product));
            try encoded.put(u64, value.version);
            try encoded.put(u64, value.rules_version);
            try encoded.put(u64, value.config_version);
            try encoded.put(u128, value.adapter_session);
            try encoded.put(u64, value.max_dispatch_age_ns);
            try encoded.put(u8, @intFromBool(value.supports_place));
            try encoded.put(u8, @intFromBool(value.supports_cancel));
            try encoded.put(u8, @intFromBool(value.supports_native_amend));
            try encoded.put(u8, @intFromBool(value.supports_venue_reduce_only));
            try encoded.put(u8, @intFromBool(value.supports_post_only));
            try encoded.put(u8, @intFromBool(value.supports_market_protection));
        },
        .instrument_trading_authorization => |value| {
            try encoded.put(u128, value.exchange_account);
            try encoded.put(u128, value.instrument);
            try encoded.put(u128, value.strategy_activation_identity);
            try encoded.put(u64, value.config_version);
            try encoded.put(u64, value.expected_version);
            try encoded.put(u8, @intFromBool(value.enabled));
        },
        else => {},
    }
    return encoded;
}

fn readInputValue(comptime T: type, bytes: []const u8, offset: *usize) !T {
    if (bytes.len - offset.* < @sizeOf(T)) return error.TruncatedInputPayload;
    const value = std.mem.readInt(T, bytes[offset.*..][0..@sizeOf(T)], .little);
    offset.* += @sizeOf(T);
    return value;
}

fn readInputBool(bytes: []const u8, offset: *usize) !bool {
    return switch (try readInputValue(u8, bytes, offset)) {
        0 => false,
        1 => true,
        else => error.InvalidInputPayload,
    };
}

pub fn decodeInput(record: journal.Record) !CoreEvent {
    if (record.schema_version != schema_version) return error.UnsupportedSchema;
    var offset: usize = 0;
    const identity = try readInputValue(u64, record.payload, &offset);
    const tag = std.enums.fromInt(
        PayloadTag,
        try readInputValue(u16, record.payload, &offset),
    ) orelse return error.UnknownInputType;
    const account_scope: ?u128 = if (try readInputBool(record.payload, &offset)) try readInputValue(u128, record.payload, &offset) else null;
    const payload: CorePayload = switch (tag) {
        .cycle_closed => blk: {
            const value = try snapshot_codec.decodeBare(record.payload[offset..], @import("cycle_occupancy.zig").Closure);
            offset = record.payload.len;
            break :blk .{ .cycle_closed = value };
        },
        .decision_domain_bound => blk: {
            const value = try snapshot_codec.decodeBare(record.payload[offset..], @import("deployment_allocation.zig").DomainBinding);
            offset = record.payload.len;
            break :blk .{ .decision_domain_bound = value };
        },
        .deployment_configuration => blk: {
            const value = try snapshot_codec.decodeBare(record.payload[offset..], @import("deployment_allocation.zig").Input);
            offset = record.payload.len;
            break :blk .{ .deployment_configuration = value };
        },
        .external_intent_group => blk: {
            const value = try snapshot_codec.decodeBare(record.payload[offset..], host_gateway.GroupCandidate);
            if (value.len > value.bytes.len) return error.InvalidIntentGroup;
            offset = record.payload.len;
            break :blk .{ .external_intent_group = value };
        },
        .history_candidate_started => blk: {
            const pending = try cold.decodeCompact(record.payload[offset..]);
            offset = record.payload.len;
            break :blk .{ .history_candidate_started = pending };
        },
        .history_candidate_verified => blk: {
            const proof = try snapshot_codec.decodeBare(record.payload[offset..], history_module.LookupProof);
            offset = record.payload.len;
            break :blk .{ .history_candidate_verified = proof };
        },
        .history_safety_candidate_verified => blk: {
            const pending_len = try readInputValue(u32, record.payload, &offset);
            if (pending_len > record.payload.len - offset) return error.InvalidInputEncoding;
            const pending = try cold.decodeCompact(record.payload[offset..][0..pending_len]);
            offset += pending_len;
            const proof = try snapshot_codec.decodeBare(record.payload[offset..], history_module.LookupProof);
            offset = record.payload.len;
            break :blk .{ .history_safety_candidate_verified = .{ .pending = pending, .proof = proof } };
        },
        .order_archive_committed => blk: {
            const commit = try snapshot_codec.decodeBare(record.payload[offset..], OrderArchiveCommit);
            offset = record.payload.len;
            break :blk .{ .order_archive_committed = commit };
        },
        .version_activation_history_verified => blk: {
            const verified = try snapshot_codec.decodeBare(record.payload[offset..], VersionActivationHistoryVerified);
            offset = record.payload.len;
            break :blk .{ .version_activation_history_verified = verified };
        },
        .account_coordinator_bound => blk: {
            const origin = try snapshot_codec.decodeBare(record.payload[offset..], history_module.Origin);
            offset = record.payload.len;
            break :blk .{ .account_coordinator_bound = origin };
        },
        .forced_archive_committed => blk: {
            const commit = try snapshot_codec.decodeBare(record.payload[offset..], ForcedArchiveCommit);
            offset = record.payload.len;
            break :blk .{ .forced_archive_committed = commit };
        },
        .control_archive_committed => blk: {
            const commit = try snapshot_codec.decodeBare(record.payload[offset..], ControlArchiveCommit);
            offset = record.payload.len;
            break :blk .{ .control_archive_committed = commit };
        },
        .funding_archive_committed => blk: {
            const commit = try snapshot_codec.decodeBare(record.payload[offset..], FundingArchiveCommit);
            offset = record.payload.len;
            break :blk .{ .funding_archive_committed = commit };
        },
        .reconciliation_archive_committed => blk: {
            const commit = try snapshot_codec.decodeBare(record.payload[offset..], ReconciliationArchiveCommit);
            offset = record.payload.len;
            break :blk .{ .reconciliation_archive_committed = commit };
        },
        .fill_archive_committed => blk: {
            const commit = try snapshot_codec.decodeBare(record.payload[offset..], FillArchiveCommit);
            offset = record.payload.len;
            break :blk .{ .fill_archive_committed = commit };
        },
        .checkpoint_committed => blk: {
            var receipt: CheckpointReceipt = undefined;
            inline for (std.meta.fields(CheckpointReceipt)) |field| {
                switch (@typeInfo(field.type)) {
                    .int => @field(receipt, field.name) = try readInputValue(field.type, record.payload, &offset),
                    .array => for (&@field(receipt, field.name)) |*byte| {
                        byte.* = try readInputValue(u8, record.payload, &offset);
                    },
                    else => unreachable,
                }
            }
            break :blk .{ .checkpoint_committed = receipt };
        },
        .asset_definition_activated => blk: {
            var value: canonical.AssetDefinition = undefined;
            inline for (std.meta.fields(canonical.AssetDefinition)) |field| {
                @field(value, field.name) = switch (@typeInfo(field.type)) {
                    .int => try readInputValue(field.type, record.payload, &offset),
                    .@"enum" => std.enums.fromInt(field.type, try readInputValue(u8, record.payload, &offset)) orelse return error.InvalidAssetDefinition,
                    .array => array: {
                        var bytes: field.type = undefined;
                        if (comptime std.mem.eql(u8, field.name, "code_bindings")) {
                            for (&bytes) |*binding| {
                                binding.venue = try readInputValue(u64, record.payload, &offset);
                                binding.code_len = try readInputValue(u8, record.payload, &offset);
                                for (&binding.code) |*byte| byte.* = try readInputValue(u8, record.payload, &offset);
                            }
                        } else for (&bytes) |*byte| byte.* = try readInputValue(u8, record.payload, &offset);
                        break :array bytes;
                    },
                    else => unreachable,
                };
            }
            break :blk .{ .asset_definition_activated = value };
        },
        .instrument_rules_activated => .{ .instrument_rules_activated = .{
            .version = try readInputValue(u32, record.payload, &offset),
            .instrument_identity = try readInputValue(u128, record.payload, &offset),
            .quantity_denominator = try readInputValue(i64, record.payload, &offset),
            .quantity_numerator = try readInputValue(i64, record.payload, &offset),
            .reservation_model = std.enums.fromInt(
                ReservationModel,
                try readInputValue(u8, record.payload, &offset),
            ) orelse return error.UnknownReservationModel,
            .product = std.enums.fromInt(
                Product,
                try readInputValue(u8, record.payload, &offset),
            ) orelse return error.UnknownProduct,
            .venue = try readInputValue(u64, record.payload, &offset),
            .settlement_asset = try readInputValue(u64, record.payload, &offset),
            .base_asset = try readInputValue(u64, record.payload, &offset),
        } },
        .margin_rules_activated => .{ .margin_rules_activated = .{
            .native_settlement_atoms = try readInputValue(u8, record.payload, &offset) == 1,
            .version = try readInputValue(u32, record.payload, &offset),
            .instrument = try readInputValue(u128, record.payload, &offset),
            .price_tick_atoms = try readInputValue(i128, record.payload, &offset),
            .venue_initial_margin_ppm = try readInputValue(i64, record.payload, &offset),
            .internal_initial_margin_ppm = try readInputValue(i64, record.payload, &offset),
            .internal_maintenance_margin_ppm = try readInputValue(i64, record.payload, &offset),
            .fee_ppm = try readInputValue(i64, record.payload, &offset),
            .opening_buffer_atoms = try readInputValue(i128, record.payload, &offset),
            .opening_buffer_bps = try readInputValue(i64, record.payload, &offset),
            .opening_liquidation_distance_ticks = try readInputValue(i64, record.payload, &offset),
            .warning_buffer_atoms = try readInputValue(i128, record.payload, &offset),
            .kill_buffer_atoms = try readInputValue(i128, record.payload, &offset),
            .warning_buffer_bps = try readInputValue(i64, record.payload, &offset),
            .kill_buffer_bps = try readInputValue(i64, record.payload, &offset),
            .warning_liquidation_distance_ticks = try readInputValue(i64, record.payload, &offset),
            .kill_liquidation_distance_ticks = try readInputValue(i64, record.payload, &offset),
        } },
        .account_configuration => .{ .account_configuration = .{
            .exchange_account_identity = try readInputValue(u128, record.payload, &offset),
        } },
        .exchange_balance => .{ .exchange_balance = .{
            .cash_atoms = try readInputValue(i128, record.payload, &offset),
        } },
        .exchange_positions => .exchange_positions,
        .opening_balance => blk: {
            var opening: OpeningBalance = .{ .cash_atoms = try readInputValue(i128, record.payload, &offset) };
            opening.native_balance_count = try readInputValue(u8, record.payload, &offset);
            if (opening.native_balance_count > opening.native_balances.len) return error.InvalidOpeningBalance;
            for (opening.native_balances[0..opening.native_balance_count]) |*balance| {
                balance.asset = try readInputValue(u64, record.payload, &offset);
                balance.atoms = try readInputValue(i128, record.payload, &offset);
            }
            break :blk .{ .opening_balance = opening };
        },
        .virtual_portfolio_activated => .{ .virtual_portfolio_activated = .{
            .portfolio_identity = try readInputValue(u128, record.payload, &offset),
        } },
        .portfolio_transfer => .{ .portfolio_transfer = .{
            .amount_atoms = try readInputValue(i128, record.payload, &offset),
        } },
        .strategy_activated => .{ .strategy_activated = .{
            .strategy_identity = try readInputValue(u128, record.payload, &offset),
            .config_version = try readInputValue(u64, record.payload, &offset),
            .activation_identity = try readInputValue(u128, record.payload, &offset),
        } },
        .host_activated => .{ .host_activated = .{
            .strategy_identity = try readInputValue(u128, record.payload, &offset),
            .config_version = try readInputValue(u64, record.payload, &offset),
            .activation_identity = try readInputValue(u128, record.payload, &offset),
            .session = .{
                .fencing = try readInputValue(u64, record.payload, &offset),
                .shard = try readInputValue(u32, record.payload, &offset),
                .generation = try readInputValue(u64, record.payload, &offset),
            },
            .activation_barrier = try readInputValue(u64, record.payload, &offset),
            .state_digest = blk: {
                var digest: [32]u8 = undefined;
                for (&digest) |*byte| byte.* = try readInputValue(u8, record.payload, &offset);
                break :blk digest;
            },
        } },
        .host_activation_revoked => .{ .host_activation_revoked = .{
            .strategy_identity = try readInputValue(u128, record.payload, &offset),
            .activation_identity = try readInputValue(u128, record.payload, &offset),
            .reason = std.enums.fromInt(HostRevocationReason, try readInputValue(u8, record.payload, &offset)) orelse return error.InvalidHostRevocationReason,
        } },
        .primary_lease_granted => .{ .primary_lease_granted = .{
            .fencing_token = try readInputValue(u64, record.payload, &offset),
        } },
        .risk_lease_granted => blk: {
            const value = try snapshot_codec.decodeBare(record.payload[offset..], RiskLease);
            offset = record.payload.len;
            break :blk .{ .risk_lease_granted = value };
        },
        .mark_price => .{ .mark_price = .{
            .instrument = try readInputValue(u128, record.payload, &offset),
            .price_atoms = try readInputValue(i128, record.payload, &offset),
        } },
        .timer => .{ .timer = .{
            .side = std.enums.fromInt(host_gateway.Side, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownOrderSide,
            .time_in_force = std.enums.fromInt(host_gateway.TimeInForce, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownTimeInForce,
            .portfolio_reduce_only = try readInputBool(record.payload, &offset),
            .quantity = try readInputValue(i64, record.payload, &offset),
            .limit_price_micros = try readInputValue(i64, record.payload, &offset),
        } },
        .external_order_intent => .{ .external_order_intent = .{
            .strategy_identity = try readInputValue(u128, record.payload, &offset),
            .intent_sequence = try readInputValue(u64, record.payload, &offset),
            .strategy_cursor = try readInputValue(u64, record.payload, &offset),
            .config_version = try readInputValue(u64, record.payload, &offset),
            .activation_identity = try readInputValue(u128, record.payload, &offset),
            .portfolio_identity = try readInputValue(u128, record.payload, &offset),
            .exchange_account_identity = try readInputValue(u128, record.payload, &offset),
            .instrument_identity = try readInputValue(u128, record.payload, &offset),
            .side = std.enums.fromInt(
                host_gateway.Side,
                try readInputValue(u8, record.payload, &offset),
            ) orelse return error.UnknownIntentSide,
            .order_type = std.enums.fromInt(
                host_gateway.OrderType,
                try readInputValue(u8, record.payload, &offset),
            ) orelse return error.UnknownIntentOrderType,
            .time_in_force = std.enums.fromInt(
                host_gateway.TimeInForce,
                try readInputValue(u8, record.payload, &offset),
            ) orelse return error.UnknownIntentTimeInForce,
            .portfolio_reduce_only = switch (try readInputValue(u8, record.payload, &offset)) {
                0 => false,
                1 => true,
                else => return error.InvalidIntentBoolean,
            },
            .quantity = try readInputValue(i64, record.payload, &offset),
            .limit_price_micros = try readInputValue(i64, record.payload, &offset),
        } },
        .strategy_intent_rejected => .{ .strategy_intent_rejected = .{
            .reason = std.enums.fromInt(
                host_gateway.RejectReason,
                try readInputValue(u16, record.payload, &offset),
            ) orelse return error.UnknownIntentRejectReason,
            .strategy_identity = try readInputValue(u128, record.payload, &offset),
            .intent_sequence = try readInputValue(u64, record.payload, &offset),
        } },
        .oms_intent_group => blk: {
            var value: oms_module.IntentGroup = .{
                .first_intent_sequence = try readInputValue(u64, record.payload, &offset),
                .policy = std.enums.fromInt(oms_module.PartialExecutionPolicy, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownPartialExecutionPolicy,
                .count = try readInputValue(u8, record.payload, &offset),
            };
            if (value.count > oms_module.max_group_members) return error.InvalidIntentGroup;
            for (value.members[0..value.count]) |*member| {
                member.* = .{
                    .intent_sequence = try readInputValue(u64, record.payload, &offset),
                    .strategy_instance = try readInputValue(u128, record.payload, &offset),
                    .exchange_account = try readInputValue(u128, record.payload, &offset),
                    .operation = std.enums.fromInt(oms_module.Operation, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownOmsOperation,
                    .instrument = try readInputValue(u128, record.payload, &offset),
                    .side = std.enums.fromInt(oms_module.Side, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownOmsSide,
                    .portfolio_reduce_only = switch (try readInputValue(u8, record.payload, &offset)) {
                        0 => false,
                        1 => true,
                        else => return error.InvalidIntentBoolean,
                    },
                    .venue_reduce_only = switch (try readInputValue(u8, record.payload, &offset)) {
                        0 => false,
                        1 => true,
                        else => return error.InvalidIntentBoolean,
                    },
                    .target_order_id = try readInputValue(u64, record.payload, &offset),
                    .expected_revision = try readInputValue(u32, record.payload, &offset),
                    .expected_cumulative_quantity = try readInputValue(i64, record.payload, &offset),
                    .quantity = try readInputValue(i64, record.payload, &offset),
                    .limit_price = .{
                        .instrument = try readInputValue(u128, record.payload, &offset),
                        .rules_version = try readInputValue(u64, record.payload, &offset),
                        .ticks = try readInputValue(i128, record.payload, &offset),
                    },
                    .native_amend = (try readInputValue(u8, record.payload, &offset)) == 1,
                    .allow_cancel_confirm_create = (try readInputValue(u8, record.payload, &offset)) == 1,
                    .reservation = .{
                        .asset = try readInputValue(u64, record.payload, &offset),
                        .atoms = try readInputValue(i128, record.payload, &offset),
                    },
                    .order_type = std.enums.fromInt(canonical.OrderType, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownOrderType,
                    .time_in_force = std.enums.fromInt(canonical.TimeInForce, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownTimeInForce,
                    .market_protection_price = if ((try readInputValue(u8, record.payload, &offset)) == 1) .{
                        .instrument = try readInputValue(u128, record.payload, &offset),
                        .rules_version = try readInputValue(u64, record.payload, &offset),
                        .ticks = try readInputValue(i128, record.payload, &offset),
                    } else null,
                };
                const client_len = try readInputValue(u8, record.payload, &offset);
                if (client_len > 64 or record.payload.len - offset < client_len) return error.InvalidClientOrderId;
                member.client_order_id = if (client_len == 0)
                    .{}
                else
                    try canonical.ClientOrderId.init(record.payload[offset..][0..client_len]);
                offset += client_len;
            }
            break :blk .{ .oms_intent_group = value };
        },
        .oms_dispatch_batch => blk: {
            var value: oms_module.DispatchBatch = .{ .count = try readInputValue(u8, record.payload, &offset) };
            if (value.count > oms_module.max_commands) return error.InvalidDispatchBatch;
            for (value.items[0..value.count]) |*item| item.* = .{
                .command_id = try readInputValue(u64, record.payload, &offset),
                .state = std.enums.fromInt(oms_module.DispatchState, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownDispatchStatus,
                .definite_reject = (try readInputValue(u8, record.payload, &offset)) == 1,
            };
            break :blk .{ .oms_dispatch_batch = value };
        },
        .oms_execution_report => .{ .oms_execution_report = .{
            .report_id = try readInputValue(u64, record.payload, &offset),
            .order_id = try readInputValue(u64, record.payload, &offset),
            .revision = try readInputValue(u32, record.payload, &offset),
            .status = std.enums.fromInt(oms_module.ReportStatus, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownExecutionStatus,
            .cumulative_quantity = try readInputValue(i64, record.payload, &offset),
            .remaining_quantity = try readInputValue(i64, record.payload, &offset),
        } },
        .oms_reconciliation_result => .{ .oms_reconciliation_result = .{
            .reconciliation_id = try readInputValue(u64, record.payload, &offset),
            .order_id = try readInputValue(u64, record.payload, &offset),
            .status = std.enums.fromInt(oms_module.ReconciliationStatus, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownReconciliationStatus,
            .revision = try readInputValue(u32, record.payload, &offset),
            .cumulative_quantity = try readInputValue(i64, record.payload, &offset),
            .remaining_quantity = try readInputValue(i64, record.payload, &offset),
            .terminal_state = if ((try readInputValue(u8, record.payload, &offset)) == 1)
                std.enums.fromInt(oms_module.TerminalState, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownTerminalState
            else
                null,
        } },
        .economic_fill => .{ .economic_fill = .{
            .fill_id = try readInputValue(u64, record.payload, &offset),
            .order_id = try readInputValue(u64, record.payload, &offset),
            .quantity = try readInputValue(i64, record.payload, &offset),
            .price_ticks = try readInputValue(i64, record.payload, &offset),
            .fee_atoms = try readInputValue(i128, record.payload, &offset),
            .rebate_atoms = try readInputValue(i128, record.payload, &offset),
        } },
        .funding_settlement => .{ .funding_settlement = .{
            .settlement_id = try readInputValue(u64, record.payload, &offset),
            .amount_atoms = try readInputValue(i128, record.payload, &offset),
            .instrument = try readInputValue(u128, record.payload, &offset),
        } },
        .venue_forced_execution => .{ .venue_forced_execution = .{
            .execution_id = try readInputValue(u64, record.payload, &offset),
            .source_identity = try readInputValue(u128, record.payload, &offset),
            .side = std.enums.fromInt(oms_module.Side, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownOmsSide,
            .quantity = try readInputValue(i64, record.payload, &offset),
            .price_ticks = try readInputValue(i64, record.payload, &offset),
            .fee_atoms = try readInputValue(i128, record.payload, &offset),
            .penalty_atoms = try readInputValue(i128, record.payload, &offset),
            .expected_realized_pnl_atoms = switch (try readInputValue(u8, record.payload, &offset)) {
                0 => null,
                1 => try readInputValue(i128, record.payload, &offset),
                else => return error.InvalidForcedExecutionPnlEvidence,
            },
        } },
        .economic_account_snapshot => .{ .economic_account_snapshot = .{
            .snapshot_id = try readInputValue(u64, record.payload, &offset),
            .usdt_balance_atoms = try readInputValue(i128, record.payload, &offset),
            .spot_asset_atoms = try readInputValue(i128, record.payload, &offset),
            .swap_position_quantity = try readInputValue(i64, record.payload, &offset),
            .margin_atoms = try readInputValue(i128, record.payload, &offset),
        } },
        .control_command => .{ .control_command = .{
            .command_identity = try readInputValue(u128, record.payload, &offset),
            .content_hash = try readInputValue(u128, record.payload, &offset),
            .target_identity = try readInputValue(u128, record.payload, &offset),
            .expected_version = try readInputValue(u64, record.payload, &offset),
            .expires_at = try readInputValue(u64, record.payload, &offset),
            .kind = std.enums.fromInt(operational.CommandKind, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownControlCommand,
            .target_position = try readInputValue(i64, record.payload, &offset),
            .referenced_latch_identity = try readInputValue(u128, record.payload, &offset),
            .risk_warning_acknowledged = (try readInputValue(u8, record.payload, &offset)) == 1,
            .risk_warning_identity = try readInputValue(u128, record.payload, &offset),
        } },
        .recovery_completed => .recovery_completed,
        .safety_gate_change => .{ .safety_gate_change = .{
            .gate_identity = try readInputValue(u128, record.payload, &offset),
            .target_identity = try readInputValue(u128, record.payload, &offset),
            .kind = std.enums.fromInt(operational.GateKind, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownSafetyGateKind,
            .reason = std.enums.fromInt(operational.GateReason, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownSafetyGateReason,
            .open = (try readInputValue(u8, record.payload, &offset)) == 1,
            .continuity_proven = (try readInputValue(u8, record.payload, &offset)) == 1,
            .blocks_buy = (try readInputValue(u8, record.payload, &offset)) == 1,
            .blocks_sell = (try readInputValue(u8, record.payload, &offset)) == 1,
        } },
        .lifecycle_progress => .{ .lifecycle_progress = .{
            .operation_identity = try readInputValue(u128, record.payload, &offset),
            .target_identity = try readInputValue(u128, record.payload, &offset),
            .open_orders_closed = (try readInputValue(u8, record.payload, &offset)) == 1,
            .reconciliation_complete = (try readInputValue(u8, record.payload, &offset)) == 1,
            .position_quantity = try readInputValue(i64, record.payload, &offset),
        } },
        .risk_warning => .{ .risk_warning = .{
            .warning_identity = try readInputValue(u128, record.payload, &offset),
            .target_identity = try readInputValue(u128, record.payload, &offset),
        } },
        .lease_gate_change => .{ .lease_gate_change = .{
            .gate_identity = try readInputValue(u128, record.payload, &offset),
            .target_identity = try readInputValue(u128, record.payload, &offset),
            .kind = .self_recovering,
            .reason = std.enums.fromInt(operational.GateReason, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownSafetyGateReason,
            .open = (try readInputValue(u8, record.payload, &offset)) == 1,
            .continuity_proven = false,
        } },
        .strategy_cutover_fence => .{ .strategy_cutover_fence = .{
            .strategy_instance = try readInputValue(u128, record.payload, &offset),
        } },
        .version_activation => blk: {
            var value: VersionActivationEvent = .{
                .activation_identity = try readInputValue(u128, record.payload, &offset),
                .generation = try readInputValue(u64, record.payload, &offset),
                .old_release = try readInputValue(u64, record.payload, &offset),
                .new_release = try readInputValue(u64, record.payload, &offset),
                .old_strategy_instance = try readInputValue(u128, record.payload, &offset),
                .new_strategy_instance = try readInputValue(u128, record.payload, &offset),
                .strategy_definition = try readInputValue(u128, record.payload, &offset),
                .parameter_version = try readInputValue(u64, record.payload, &offset),
                .state_schema_version = try readInputValue(u32, record.payload, &offset),
                .transition = std.enums.fromInt(StrategyStateTransition, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownStrategyStateTransition,
                .barrier = try readInputValue(u64, record.payload, &offset),
                .canonical_state_digest = undefined,
            };
            for (&value.canonical_state_digest) |*byte| byte.* = try readInputValue(u8, record.payload, &offset);
            break :blk .{ .version_activation = value };
        },
        .capability_profile_activation => .{ .capability_profile_activation = .{
            .exchange_account = try readInputValue(u128, record.payload, &offset),
            .instrument = try readInputValue(u128, record.payload, &offset),
            .venue = try readInputValue(u64, record.payload, &offset),
            .environment = std.enums.fromInt(CapabilityProfileActivation.Environment, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownEnvironment,
            .product = std.enums.fromInt(Product, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownProduct,
            .version = try readInputValue(u64, record.payload, &offset),
            .rules_version = try readInputValue(u64, record.payload, &offset),
            .config_version = try readInputValue(u64, record.payload, &offset),
            .adapter_session = try readInputValue(u128, record.payload, &offset),
            .max_dispatch_age_ns = try readInputValue(u64, record.payload, &offset),
            .supports_place = try readInputBool(record.payload, &offset),
            .supports_cancel = try readInputBool(record.payload, &offset),
            .supports_native_amend = try readInputBool(record.payload, &offset),
            .supports_venue_reduce_only = try readInputBool(record.payload, &offset),
            .supports_post_only = try readInputBool(record.payload, &offset),
            .supports_market_protection = try readInputBool(record.payload, &offset),
        } },
        .instrument_trading_authorization => .{ .instrument_trading_authorization = .{
            .exchange_account = try readInputValue(u128, record.payload, &offset),
            .instrument = try readInputValue(u128, record.payload, &offset),
            .strategy_activation_identity = try readInputValue(u128, record.payload, &offset),
            .config_version = try readInputValue(u64, record.payload, &offset),
            .expected_version = try readInputValue(u64, record.payload, &offset),
            .enabled = try readInputBool(record.payload, &offset),
        } },
    };
    if (offset != record.payload.len) return error.TrailingInputPayload;
    return .{
        .identity = identity,
        .account_scope = account_scope,
        .source_time = record.source_time,
        .receive_time = record.receive_time,
        .monotonic_time = record.monotonic_time,
        .wall_time = record.wall_time,
        .time_presence = record.time_presence,
        .payload = payload,
    };
}

pub fn eventIdentity(payload: []const u8) !u64 {
    if (payload.len < @sizeOf(u64)) return error.MissingEventIdentity;
    return std.mem.readInt(u64, payload[0..@sizeOf(u64)], .little);
}
