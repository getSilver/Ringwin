const std = @import("std");
const builtin = @import("builtin");
/// Stable journal codec used by snapshot and semantic replay.
pub const journal = @import("journal.zig");
pub const canonical = @import("canonical_event.zig");
pub const oms = @import("oms.zig");
const oms_module = oms;
pub const risk = @import("risk.zig");
const risk_module = risk;
pub const economics = @import("economics.zig");
const economics_module = economics;
pub const operational = @import("operational.zig");
const host_gateway = @import("strategy_host_gateway.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const snapshot_codec = @import("snapshot_codec.zig");
const canonical_event_codec = @import("canonical_event_codec.zig");
const account_projection = @import("account_projection.zig");
const market_projection = @import("market_projection.zig");
const asset_registry = @import("asset_registry.zig");
const instrument_registry = @import("instrument_registry.zig");
const production_contract = @import("production_contract.zig");
const history = @import("business_history.zig");
const cold = @import("cold_business_candidate.zig");
const history_batch = @import("order_history_batch.zig");
pub const OrderArchiveCommit = @import("trading_shard_event.zig").OrderArchiveCommit;
pub const FillArchiveCommit = @import("trading_shard_event.zig").FillArchiveCommit;
pub const FundingArchiveCommit = shard_event.FundingArchiveCommit;
pub const ReconciliationArchiveCommit = shard_event.ReconciliationArchiveCommit;
pub const BusinessArchiveKind = enum { order, fill, funding, reconciliation, control, forced };
const ArchiveCommitInput = struct { identity: u64, times: StableTimes };

pub const OpenEconomicFact = struct {
    identity: u64,
    kind: @FieldType(canonical.EconomicFactRef, "kind"),
    digest: history.Digest,
    economic_time_utc_ns: ?u64,
    accepted_input_digest: history.Digest = @splat(0),
};
pub const ReconciliationCursor = struct {
    identity: u128,
    through_utc_ns: u64,
    closed_economic_fact_count: u64,
    balance_count: u8,
    balances: [canonical.max_account_facts]canonical.AssetAmount,
    root_digest: history.Digest,
};
pub const ReconciliationWindow = struct {
    identity: u128,
    original: canonical.EventRecord,
    previous_cursor: ?ReconciliationCursor,
    economic_fact_count: u64,
    projection_digest: history.Digest,
};
pub const ReconciliationWindowArchiveQualification = struct {
    origin: history.Origin,
    barrier: u64,
    projection_digest: history.Digest,
    window: ReconciliationWindow,
    pub fn digest(self: *const @This()) history.Digest {
        var bytes: [history.max_record_bytes]u8 = undefined;
        return history.hash(snapshot_codec.encodeBare(&bytes, self.*) catch unreachable);
    }
};

/// Current physical schema for AuthoritativeTradingState snapshots.
pub const state_schema_version: u32 = production_contract.state_schema_version;
/// Release artifact producing the current snapshot schema.
pub const release_artifact_identity: u64 = 1;
/// Registry entry defining the current snapshot and journal schemas.
pub const schema_registry_identity: u64 = production_contract.schema_registry_identity;
const settlement_asset: canonical.AssetIdentity = 1;
const money_scale: i64 = 1_000_000;
const contract_denominator: i64 = 10_000;
const market_data_gate_identity: u128 = 0x4d41524b455444415441;
const account_data_gate_identity: u128 = 0x4143434f554e5444415441;
const margin_warning_gate_identity: u128 = 0x4d415247494e5741524e;
const margin_kill_gate_identity: u128 = 0x4d415247494e4b494c4c;
const primary_lease_gate_identity: u128 = 0x5052494d4152594c45415345;
const risk_lease_gate_identity: u128 = 0x5249534b4c45415345;

const shard_event = @import("trading_shard_event.zig");
pub const schema_version = shard_event.schema_version;
pub const EventKind = shard_event.EventKind;
pub const Fact = shard_event.Fact;
pub const CheckpointReceipt = shard_event.CheckpointReceipt;
const Trace = shard_event.Trace;
const MarketHealth = shard_event.MarketHealth;
const RejectReason = shard_event.RejectReason;
pub const TimerRequest = shard_event.TimerRequest;
pub const EconomicFill = shard_event.EconomicFill;
pub const FundingSettlement = shard_event.FundingSettlement;
pub const VenueForcedExecution = shard_event.VenueForcedExecution;
pub const EconomicAccountSnapshot = shard_event.EconomicAccountSnapshot;
pub const EconomicSummary = shard_event.EconomicSummary;
pub const ReservationModel = shard_event.ReservationModel;
pub const InstrumentRules = shard_event.InstrumentRules;
pub const InstrumentProduct = shard_event.Product;
pub const InstrumentEntry = instrument_registry.Entry;
pub const MarginRules = shard_event.MarginRules;
pub const AccountConfiguration = shard_event.AccountConfiguration;
pub const Balance = shard_event.Balance;
pub const VirtualPortfolioActivation = shard_event.VirtualPortfolioActivation;
pub const PortfolioTransfer = shard_event.PortfolioTransfer;
pub const StrategyActivation = shard_event.StrategyActivation;
pub const HostActivated = shard_event.HostActivated;
pub const HostActivationRevoked = shard_event.HostActivationRevoked;
pub const PrimaryLease = shard_event.PrimaryLease;
pub const RiskLease = shard_event.RiskLease;
pub const StrategyCutoverFence = shard_event.StrategyCutoverFence;
pub const StrategyStateTransition = shard_event.StrategyStateTransition;
pub const VersionActivationEvent = shard_event.VersionActivationEvent;
pub const CorePayload = shard_event.CorePayload;
pub const CoreEvent = shard_event.CoreEvent;
pub const CanonicalEvent = shard_event.CanonicalEvent;

const EncodedInput = shard_event.EncodedInput;
const encodeInput = shard_event.encodeInput;
const decodeInput = shard_event.decodeInput;
const eventIdentity = shard_event.eventIdentity;

pub const OrderCommand = oms_module.Command;

pub const ApplyResult = struct {
    facts: []const Fact,
    order_command: ?OrderCommand,
    oms_commands: []const oms_module.Command,
};

pub const ReplayTradingShard = struct {
    shard: TradingShard = .{},

    pub fn apply(self: *ReplayTradingShard, input: CanonicalEvent) ![]const Fact {
        return (try self.shard.apply(input)).facts;
    }

    pub fn canonicalStateDigest(self: *const ReplayTradingShard) [Sha256.digest_length]u8 {
        return self.shard.canonicalStateDigest();
    }
};

/// Strictly decoded authoritative snapshot and its exact journal barrier.
pub const SnapshotRestore = struct {
    shard: TradingShard,
    barrier: u64,
};

/// Recovered authoritative state and the stable tail scan result.
pub const RestoreMetadata = struct {
    barrier: u64,
    status: journal.ScanStatus,
};

pub const SnapshotRecovery = struct {
    shard: TradingShard,
    barrier: u64,
    status: journal.ScanStatus,
};

const Position = struct {
    quantity: i64 = 0,
    open_cost_atoms: i128 = 0,
};

fn ceilDivPositive(numerator: i128, denominator: i128) !i128 {
    if (numerator < 0 or denominator <= 0) return error.InvalidPositiveDivision;
    const rounded = try std.math.sub(i128, try std.math.add(i128, numerator, denominator), 1);
    return @divFloor(rounded, denominator);
}

fn notionalAtomsScaled(quantity: i64, price_atoms: i128, quantity_denominator: i64, quantity_numerator: i64) !i128 {
    if (quantity < 0 or price_atoms <= 0 or quantity_denominator <= 0)
        return error.InvalidNotionalInput;
    return ceilDivPositive(try std.math.mul(i128, try std.math.mul(i128, quantity, price_atoms), quantity_numerator), quantity_denominator);
}

fn priceTicks(price_atoms: i128, tick_atoms: i128) !i128 {
    if (price_atoms <= 0 or tick_atoms <= 0 or @mod(price_atoms, tick_atoms) != 0)
        return error.InvalidPriceTick;
    return @divExact(price_atoms, tick_atoms);
}

fn changesTradingAuthorization(kind: operational.CommandKind) bool {
    return switch (kind) {
        .enable_trading, .trading_pause, .stop_keep_positions, .de_risk, .resolve_latch => true,
        .start_recovery, .cancel_open_orders => false,
    };
}

fn riskTier(notional_atoms: i128, scale: u8) !u8 {
    if (notional_atoms <= try (canonical.Decimal{ .coefficient = 500_000, .scale = 0 }).exactAtoms(scale)) return 1;
    if (notional_atoms <= try (canonical.Decimal{ .coefficient = 1_000_000, .scale = 0 }).exactAtoms(scale)) return 2;
    if (notional_atoms <= try (canonical.Decimal{ .coefficient = 1_500_000, .scale = 0 }).exactAtoms(scale)) return 3;
    return error.RiskLimitExceeded;
}

const CanonicalIngressCursor = struct {
    identity: canonical.EventIdentity,
    event_type: canonical.EventType,
    raw_digest: [Sha256.digest_length]u8,
    payload_digest: [Sha256.digest_length]u8,
};

pub const DispatchIngressBody = struct {
    command: u64,
    state: canonical.DispatchState,
    venue: canonical.VenueIdentity,
    account: canonical.ExchangeAccountIdentity,
    canonical_digest: [32]u8,
};
pub const DispatchIngressEvidence = struct {
    body: DispatchIngressBody,
    cursor: struct { identity: canonical.EventIdentity, raw_digest: [32]u8, payload_digest: [32]u8 },
};

const DeferredHistoryAdmission = struct {
    identity: canonical.EventIdentity,
    event_type: u32,
    order_id: u64,
    raw_digest: [32]u8,
    payload_digest: [32]u8,
    original_input_digest: [32]u8,
    fact_sequence: u64,
};

fn canonicalPayloadDigest(event: canonical.Payload) ![Sha256.digest_length]u8 {
    var payload_bytes: [canonical_event_codec.max_encoded_len]u8 = undefined;
    const payload = try canonical_event_codec.encodePayload(&payload_bytes, event);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    return digest;
}
const max_canonical_ingress_streams = 16;

fn ingressAdmissionFull(count: usize, capacity: usize) bool {
    return count >= capacity;
}

test "09 canonical stream and deferred admission numeric boundaries preserve the final free slot" {
    for ([_]usize{ max_canonical_ingress_streams, 64 }) |capacity| {
        try std.testing.expect(!ingressAdmissionFull(capacity - 1, capacity));
        try std.testing.expect(ingressAdmissionFull(capacity, capacity));
        try std.testing.expect(ingressAdmissionFull(capacity + 1, capacity));
        try std.testing.expect(ingressAdmissionFull(std.math.maxInt(usize), capacity));
    }
}

pub const TradingShard = struct {
    pending_history_candidate: ?cold.PendingCandidate = null,
    pending_history_member_index: ?u8 = null,
    pending_safety_history_candidate: ?cold.PendingCandidate = null,
    pending_safety_history_member_index: ?u8 = null,
    history_conflict_latched: bool = false,
    next_history_pending_id: u128 = 1,
    business_history_root: ?history.Root = null,
    last_order_archive: ?OrderArchiveCommit = null,
    last_fill_archive: ?FillArchiveCommit = null,
    last_funding_archive: ?FundingArchiveCommit = null,
    last_funding_archive_input: ?ArchiveCommitInput = null,
    last_reconciliation_archive: ?ReconciliationArchiveCommit = null,
    last_reconciliation_archive_input: ?ArchiveCommitInput = null,
    reconciliation_cursor: ?ReconciliationCursor = null,
    pending_reconciliation_window: ?ReconciliationWindow = null,
    open_economic_facts: [16]OpenEconomicFact = undefined,
    open_economic_fact_count: u64 = 0,
    open_economic_commitment_sequence: u64 = 0,
    open_economic_min_utc_ns: u64 = 0,
    open_economic_max_utc_ns: u64 = 0,
    open_economic_unknown_time_count: u64 = 0,
    last_business_archive_kind: ?BusinessArchiveKind = null,
    last_control_archive: ?shard_event.ControlArchiveCommit = null,
    coordinator_history_origin: ?history.Origin = null,
    coordinator_binding_fact: u64 = 0,
    last_forced_archive: ?shard_event.ForcedArchiveCommit = null,
    last_forced_archive_input: ?ArchiveCommitInput = null,
    last_control_archive_input: ?ArchiveCommitInput = null,
    archived_control_records: u64 = 0,
    deferred_history_admissions: [64]DeferredHistoryAdmission = undefined,
    deferred_history_admission_count: u8 = 0,
    /// Restart admission is separate from deterministic economic state: Owner
    /// re-arms it on every recovery. Snapshot encoding preserves the fence;
    /// canonical/semantic digests deliberately describe committed facts only.
    recovery_admission_pending: bool = false,
    trace: Trace = .{},
    checkpoint: ?CheckpointReceipt = null,
    control_fact_sequences: [operational.max_commands]u64 = @splat(0),
    instrument_rules_version: u32 = 0,
    margin_rules_version: u32 = 0,
    account_configured: bool = false,
    virtual_portfolio_active: bool = false,
    strategy_active: bool = false,
    fencing_token: u64 = 0,
    expected_source_sequence: ?u64 = null,
    market_health: MarketHealth = .initializing,
    bid_price_ticks: i64 = 0,
    bid_quantity: i64 = 0,
    ask_1_price_ticks: i64 = 0,
    ask_1_quantity: i64 = 0,
    ask_2_price_ticks: i64 = 0,
    ask_2_quantity: i64 = 0,
    strategy_cursor: u64 = 0,
    strategy_decision_count: u64 = 0,
    timer_pending: bool = true,
    dispatch_attempt_count: u64 = 0,
    last_reject_reason: RejectReason = .none,
    last_risk_required_atoms: i128 = 0,
    last_risk_tier: u8 = 0,
    mark_price_atoms: i128 = 0,
    risk_lease_atoms: i128 = 0,
    risk_lease_identity: u64 = 0,
    risk_lease_version: u64 = 0,
    risk_lease_valid_through_barrier: u64 = 0,
    strategy_limit_atoms: i128 = 0,
    portfolio_limit_atoms: i128 = 0,
    exchange_account_limit_atoms: i128 = 0,
    global_limit_atoms: i128 = 0,
    price_tick_atoms: i128 = 0,
    venue_initial_margin_ppm: i64 = 0,
    internal_initial_margin_ppm: i64 = 0,
    internal_maintenance_margin_ppm: i64 = 0,
    risk_fee_ppm: i64 = 0,
    opening_buffer_atoms: i128 = 0,
    opening_buffer_bps: i64 = 0,
    opening_liquidation_distance_ticks: i64 = 0,
    warning_buffer_atoms: i128 = 0,
    kill_buffer_atoms: i128 = 0,
    warning_buffer_bps: i64 = 0,
    kill_buffer_bps: i64 = 0,
    warning_liquidation_distance_ticks: i64 = 0,
    kill_liquidation_distance_ticks: i64 = 0,
    portfolio_margin_buffer_atoms: i128 = 0,
    exchange_margin_buffer_atoms: i128 = 0,
    portfolio_buffer_bps: i64 = 0,
    exchange_buffer_bps: i64 = 0,
    portfolio_liquidation_distance_ticks: i64 = std.math.maxInt(i64),
    exchange_liquidation_distance_ticks: i64 = std.math.maxInt(i64),
    portfolio_margin_gate: risk_module.MarginGate = .healthy,
    exchange_margin_gate: risk_module.MarginGate = .healthy,
    quantity_denominator: i64 = contract_denominator,
    reservation_model: ReservationModel = .leveraged,
    instrument_identity: u128 = 0,
    exchange_account_identity: u128 = 0,
    portfolio_identity: u128 = 0,
    strategy_identity: u128 = 0,
    strategy_config_version: u64 = 0,
    authority_control_barrier: u64 = 0,
    strategy_activation_identity: u128 = 0,
    host_activation_identity: u128 = 0,
    host_activation_barrier: u64 = 0,
    host_activation_session: @import("strategy_host_ipc.zig").Session = .{ .fencing = 0, .shard = 0, .generation = 0 },
    host_activation_fact_sequence: u64 = 0,
    host_activation_state_digest: [32]u8 = @splat(0),
    host_activation_seen: bool = false,
    exchange_balance_observed: bool = false,
    exchange_positions_observed: bool = false,
    opening_balance_observed: bool = false,
    account_balance_utc_ns: u64 = 0,
    economic_baseline_utc_ns: u64 = 0,
    economic_baseline_balances: [canonical.max_account_facts]canonical.AssetAmount = @splat(.{ .asset = 0, .atoms = 0 }),
    economic_baseline_balance_count: u8 = 0,
    portfolio_funded: bool = false,
    oms: oms_module.Oms = .{},
    economic_projection: economics_module.Projection = .{},
    operational_state: operational.State = .{},
    release_generation: u64 = 0,
    active_release: u64 = 0,
    active_strategy_instance: u128 = 0,
    fenced_strategy_instances: [8]u128 = @splat(0),
    fenced_strategy_count: u8 = 0,
    canonical_market: market_projection.Projection = .{},
    canonical_account: account_projection.AccountProjection = .{},
    last_funding_rate: ?canonical.FundingRatePublished = null,
    last_venue_configuration: ?canonical.VenueAccountConfigurationSnapshot = null,
    economic_fault_count: u64 = 0,
    economic_fault_reason: canonical.EconomicFaultReason = .invalid_economic_fact,
    economic_fault_evidence: canonical.RawEvidenceRef = .{ .stream = 0, .sequence = 0, .digest = @splat(0) },
    canonical_ingress_count: u64 = 0,
    canonical_ingress_digest: [Sha256.digest_length]u8 = @splat(0),
    canonical_ingress_cursors: [max_canonical_ingress_streams]CanonicalIngressCursor = undefined,
    canonical_ingress_cursor_count: u8 = 0,
    dispatch_ingress_history: [oms_module.max_command_history * 3]DispatchIngressEvidence = undefined,
    dispatch_ingress_history_count: u16 = 0,
    asset_registry: asset_registry.Registry = .{},
    asset_configuration_failed: bool = false,
    asset_configuration_failure_count: u64 = 0,
    /// Single source of product/rules semantics. The scalar fields above are
    /// retained only as the normalized legacy active-instrument view.
    instrument_registry: instrument_registry.Registry = .{},

    /// The sole public core ingress seam. Both typed core events and canonical
    /// Venue records enter through this tagged event and commit transactionally.
    pub fn historySafetyInput(input: CanonicalEvent) bool {
        return switch (input) {
            .venue => true,
            .core => |event| switch (event.payload) {
                .timer, .order_archive_committed, .fill_archive_committed, .funding_archive_committed, .reconciliation_archive_committed, .control_archive_committed, .forced_archive_committed => false,
                .external_order_intent => |intent| intent.portfolio_reduce_only,
                .oms_intent_group => |group| blk: {
                    if (group.count == 0 or group.count > group.members.len) break :blk false;
                    for (group.members[0..group.count]) |intent|
                        if (intent.operation != .cancel and !intent.portfolio_reduce_only) break :blk false;
                    break :blk true;
                },
                else => true,
            },
        };
    }

    pub fn historyCandidateFor(self: *const TradingShard, input: CanonicalEvent) !?cold.PendingCandidate {
        return self.prepareHistoryCandidate(input, false);
    }

    pub fn historySafetyCandidateFor(self: *const TradingShard, input: CanonicalEvent) !?cold.PendingCandidate {
        if (self.pending_safety_history_candidate == null or input != .venue or input.venue.event != .fill) return null;
        return self.prepareHistoryCandidate(input, true);
    }

    fn prepareHistoryCandidate(self: *const TradingShard, input: CanonicalEvent, synchronous_fill: bool) !?cold.PendingCandidate {
        const root = self.business_history_root orelse return null;
        if ((self.pending_history_candidate != null or self.pending_safety_history_candidate != null or self.deferred_history_admission_count != 0) and !historySafetyInput(input)) return error.HistoryLookupPending;
        switch (input) {
            .core => |event| switch (event.payload) {
                .oms_intent_group => |group| if (try self.oms.groupIdentityStatus(group) != .fresh) return null,
                .external_order_intent => |intent| if (try self.oms.groupIdentityStatus(originalHostIntentGroup(intent)) != .fresh) return null,
                .funding_settlement => |funding| for (self.economic_projection.applied_fundings[0..self.economic_projection.applied_funding_count]) |known| {
                    if (known.funding.identity == funding.settlement_id) return null;
                },
                .venue_forced_execution => |forced| for (self.economic_projection.applied_forced_executions[0..self.economic_projection.applied_forced_execution_count]) |known| {
                    if (known.forced.identity == forced.execution_id) return null;
                },
                .control_command => |command| {
                    if (command.target_identity != self.operational_state.target_identity) return error.ControlCommandWrongTarget;
                    if (event.wall_time > command.expires_at) return error.ControlCommandExpired;
                    for (self.operational_state.command_history[0..self.operational_state.command_count]) |known|
                        if (known.command.command_identity == command.command_identity) return null;
                },
                .safety_gate_change => |gate| {
                    if (gate.target_identity != self.operational_state.target_identity) return error.SafetyGateWrongTarget;
                    for (self.operational_state.gates[0..self.operational_state.gate_count]) |known|
                        if (known.gate_identity == gate.gate_identity) return null;
                },
                .strategy_cutover_fence => |fence| {
                    for (self.fenced_strategy_instances[0..self.fenced_strategy_count]) |known| if (known == fence.strategy_instance) return null;
                },
                .strategy_activated => {},
                .economic_fill => |fill| for (self.economic_projection.canonical_fill_evidence[0..self.economic_projection.canonical_fill_evidence_count]) |known| {
                    if (known.identity == fill.fill_id) return null;
                },
                .oms_execution_report => |report| for (self.oms.report_history[0..self.oms.report_history_count]) |known| {
                    if (known.report_id == report.report_id) return null;
                },
                .oms_reconciliation_result => |result| for (self.oms.reconciliation_history[0..self.oms.reconciliation_history_count]) |known| {
                    if (known.reconciliation_id == result.reconciliation_id) return null;
                },
                else => return null,
            },
            .venue => |event| switch (event.event) {
                .funding_settlement => |funding| for (self.economic_projection.applied_fundings[0..self.economic_projection.applied_funding_count]) |known| {
                    if (known.funding.identity == funding.identity) return null;
                },
                .fill => |fill| for (self.economic_projection.canonical_fill_evidence[0..self.economic_projection.canonical_fill_evidence_count]) |known| {
                    if (known.identity == fill.identity) return null;
                },
                .order_dispatch_result => |result| for (self.dispatch_ingress_history[0..self.dispatch_ingress_history_count]) |known| {
                    if (known.body.command == result.command and known.body.state == result.state) return null;
                },
                .execution_report => |report| for (self.oms.report_history[0..self.oms.report_history_count]) |known| {
                    if (known.report_id == report.identity) return null;
                },
                .order_reconciliation_result => |result| for (self.oms.reconciliation_history[0..self.oms.reconciliation_history_count]) |known| {
                    if (known.reconciliation_id == result.identity) return null;
                },
                .account_reconciliation_result => |result| for (self.economic_projection.seen[0..self.economic_projection.seen_count]) |known| {
                    if (known.kind == .account_snapshot and known.identity == result.identity) return null;
                },
                else => return null,
            },
        }
        const semantic = (try self.historySemantic(input, null)) orelse return null;
        if (historyOrderUpdate(input)) |order_id| {
            inline for (.{ "pending_history_candidate", "pending_safety_history_candidate" }) |field| {
                if (@field(self, field)) |pending| {
                    const earlier = try decodeStableInput(pending.originalRecord());
                    if (historyOrderUpdate(earlier)) |earlier_order|
                        if (earlier_order == order_id) return error.HistorySafetyCapacity;
                }
            }
        }
        if (self.pending_safety_history_candidate != null and !synchronous_fill) return error.HistorySafetyCapacity;
        var storage: [cold.max_original_input_size]u8 = undefined;
        const payload = try encodeStableInput(&storage, input);
        const times = stableTimes(input);
        const record: journal.Record = .{ .type_id = 0, .schema_version = schema_version, .flags = journal.input_flag, .sequence = self.authoritativeBarrier() + 1, .source_time = times.source, .receive_time = times.receive, .monotonic_time = times.monotonic, .wall_time = times.wall, .time_presence = times.presence, .payload = payload };
        if (self.next_history_pending_id == 0 or self.next_history_pending_id > std.math.maxInt(u64)) return error.HistoryPendingIdentityCapacity;
        var pending = try cold.begin(record, .{ .pending_id = self.next_history_pending_id, .key = .{ .origin = root.origin, .identity = semantic.identity }, .candidate_payload_digest = semantic.digest, .original_input_digest = cold.inputDigest(record), .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier }, root);
        pending.original_was_admissible = try self.canonicalInputWasAdmissible(input, pending.request.original_input_digest);
        return pending;
    }

    fn canonicalInputWasAdmissible(self: *const TradingShard, input: CanonicalEvent, input_digest: [32]u8) !bool {
        if (input != .venue) return true;
        const record = input.venue;
        const payload_digest = try canonicalPayloadDigest(record.event);
        for (self.deferred_history_admissions[0..self.deferred_history_admission_count]) |admission| {
            if (!std.meta.eql(admission.identity, record.envelope.identity)) continue;
            if (admission.event_type != record.envelope.event_type or !std.mem.eql(u8, &admission.raw_digest, &record.envelope.raw_evidence.digest) or
                !std.mem.eql(u8, &admission.payload_digest, &payload_digest)) return error.ConflictingCanonicalIdentity;
            if (std.mem.eql(u8, &admission.original_input_digest, &input_digest)) return true;
            // The first durable admission fixes the original clock and envelope.
            // A retimed retry cannot create another row or acquire fresh admission.
            return error.ConflictingCanonicalIdentity;
        }
        for (self.canonical_ingress_cursors[0..self.canonical_ingress_cursor_count]) |cursor| {
            const envelope = input.venue.envelope;
            if (cursor.identity.stream != envelope.identity.stream) continue;
            if (envelope.identity.sequence == cursor.identity.sequence and
                (cursor.event_type != canonical.eventType(input.venue.event) or
                    !std.mem.eql(u8, &cursor.raw_digest, &envelope.raw_evidence.digest) or
                    !std.mem.eql(u8, &cursor.payload_digest, &try canonicalPayloadDigest(input.venue.event)))) return error.ConflictingCanonicalIdentity;
            return envelope.identity.sequence > cursor.identity.sequence;
        }
        return true;
    }

    fn acceptedOriginalDigest(input: CanonicalEvent) ![32]u8 {
        var bytes: [cold.max_original_input_size]u8 = undefined;
        const times = stableTimes(input);
        return cold.inputDigest(.{ .type_id = 0, .schema_version = schema_version, .flags = journal.input_flag, .sequence = 1, .source_time = times.source, .receive_time = times.receive, .monotonic_time = times.monotonic, .wall_time = times.wall, .time_presence = times.presence, .payload = try encodeStableInput(&bytes, input) });
    }

    fn retainDeferredHistoryAdmission(self: *TradingShard, input: CanonicalEvent) !void {
        if (input != .venue or (try self.historySemantic(input, null)) == null) return error.HistorySafetyCapacity;
        const input_digest = try acceptedOriginalDigest(input);
        if (!try self.canonicalInputWasAdmissible(input, input_digest)) return error.StaleCanonicalIdentity;
        for (self.deferred_history_admissions[0..self.deferred_history_admission_count]) |admission|
            if (std.meta.eql(admission.identity, input.venue.envelope.identity) and std.mem.eql(u8, &admission.original_input_digest, &input_digest)) return;
        if (ingressAdmissionFull(self.deferred_history_admission_count, self.deferred_history_admissions.len)) return error.HistoryAdmissionCapacity;
        var order_id = historyOrderUpdate(input) orelse 0;
        if (input.venue.event == .fill) order_id = std.math.cast(u64, input.venue.event.fill.order) orelse return error.IdentityOutOfRange;
        if (input.venue.event == .order_dispatch_result) for (self.oms.command_history[0..self.oms.command_history_count]) |command| {
            if (command.command_id == input.venue.event.order_dispatch_result.command) {
                order_id = command.order_id;
                break;
            }
        };
        try self.trace.append(.canonical_history_deferred, input.venue.envelope.identity.sequence);
        self.deferred_history_admissions[self.deferred_history_admission_count] = .{ .identity = input.venue.envelope.identity, .event_type = input.venue.envelope.event_type, .order_id = order_id, .raw_digest = input.venue.envelope.raw_evidence.digest, .payload_digest = try canonicalPayloadDigest(input.venue.event), .original_input_digest = input_digest, .fact_sequence = self.authoritativeBarrier() };
        self.deferred_history_admission_count += 1;
    }

    fn releaseDeferredHistoryAdmission(self: *TradingShard, input: CanonicalEvent) bool {
        if (input != .venue) return false;
        for (self.deferred_history_admissions[0..self.deferred_history_admission_count], 0..) |admission, index| {
            if (!std.meta.eql(admission.identity, input.venue.envelope.identity)) continue;
            var move = index;
            while (move + 1 < self.deferred_history_admission_count) : (move += 1)
                self.deferred_history_admissions[move] = self.deferred_history_admissions[move + 1];
            self.deferred_history_admission_count -= 1;
            return true;
        }
        return false;
    }

    pub fn hasDeferredOrderHistory(self: *const TradingShard, order_id: u64) bool {
        for (self.deferred_history_admissions[0..self.deferred_history_admission_count]) |admission| if (admission.order_id == order_id) return true;
        return false;
    }

    fn historyOrderUpdate(input: CanonicalEvent) ?u64 {
        return switch (input) {
            .core => |event| switch (event.payload) {
                .oms_execution_report => |report| report.order_id,
                .oms_reconciliation_result => |result| result.order_id,
                else => null,
            },
            .venue => |event| switch (event.event) {
                .execution_report => |report| std.math.cast(u64, report.order),
                .order_reconciliation_result => |result| std.math.cast(u64, result.order),
                else => null,
            },
        };
    }

    const HistorySemantic = struct { identity: history.Identity, digest: history.Digest };

    fn historySemantic(self: *const TradingShard, input: CanonicalEvent, member: ?u8) !?HistorySemantic {
        var bytes: [cold.max_original_input_size]u8 = undefined;
        switch (input) {
            .core => |event| switch (event.payload) {
                .oms_intent_group => |group| return try groupHistorySemantic(group, member, &bytes),
                .external_order_intent => |intent| return try groupHistorySemantic(originalHostIntentGroup(intent), member, &bytes),
                .venue_forced_execution => |forced| return .{ .identity = .{ .core_forced = forced.execution_id }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, forced)) },
                .control_command => |command| return .{ .identity = .{ .operational_command = command.command_identity }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, command)) },
                .safety_gate_change => |gate| return .{ .identity = .{ .retired_gate = gate.gate_identity }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, gate)) },
                .strategy_cutover_fence => |fence| return .{ .identity = .{ .strategy_fence = fence.strategy_instance }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, fence)) },
                .strategy_activated => |activation| return .{ .identity = .{ .strategy_fence = activation.strategy_identity }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, StrategyCutoverFence{ .strategy_instance = activation.strategy_identity })) },
                .funding_settlement => |funding| return .{ .identity = .{ .core_funding = funding.settlement_id }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, funding)) },
                .economic_fill => |fill| return .{ .identity = .{ .core_fill = fill.fill_id }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, fill)) },
                .oms_execution_report => |report| return .{ .identity = .{ .report = report.report_id }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, report)) },
                .oms_reconciliation_result => |result| return .{ .identity = .{ .reconciliation = result.reconciliation_id }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, result)) },
                else => return null,
            },
            .venue => |event| switch (event.event) {
                .funding_settlement => |funding| {
                    try self.validateHistoryEnvelope(event, funding.instrument);
                    if (funding.exchange_account != self.exchange_account_identity) return error.CanonicalScopeMismatch;
                    return .{ .identity = .{ .canonical_funding = std.math.cast(u64, funding.identity) orelse return error.IdentityOutOfRange }, .digest = try canonicalPayloadDigest(event.event) };
                },
                .fill => |fill| {
                    try self.validateHistoryEnvelope(event, fill.instrument);
                    if (fill.exchange_account != self.exchange_account_identity or fill.instrument != fill.quantity.instrument or fill.instrument != fill.price.instrument) return error.CanonicalScopeMismatch;
                    return .{ .identity = .{ .canonical_fill = std.math.cast(u64, fill.identity) orelse return error.IdentityOutOfRange }, .digest = try canonicalPayloadDigest(event.event) };
                },
                .order_dispatch_result => |result| {
                    const body = try self.dispatchIngressBody(event);
                    return .{ .identity = .{ .dispatch_result = .{ .command = body.command, .state = result.state } }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, body)) };
                },
                .execution_report => |report| {
                    try self.validateHistoryEnvelope(event, report.instrument);
                    if (report.exchange_account != self.exchange_account_identity or report.instrument != report.cumulative_quantity.instrument or report.instrument != report.remaining_quantity.instrument) return error.CanonicalScopeMismatch;
                    const converted: oms.ExecutionReport = .{ .report_id = std.math.cast(u64, report.identity) orelse return error.IdentityOutOfRange, .order_id = std.math.cast(u64, report.order) orelse return error.IdentityOutOfRange, .revision = report.revision, .status = switch (report.status) {
                        .accepted => .accepted,
                        .partially_filled => .partially_filled,
                        .filled => .filled,
                        .canceled => .canceled,
                        .rejected => .rejected,
                        .amended => .amended,
                    }, .cumulative_quantity = std.math.cast(i64, report.cumulative_quantity.lots) orelse return error.QuantityOutOfRange, .remaining_quantity = std.math.cast(i64, report.remaining_quantity.lots) orelse return error.QuantityOutOfRange, .canonical_digest = try canonicalPayloadDigest(event.event) };
                    return .{ .identity = .{ .report = report.identity }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, converted)) };
                },
                .order_reconciliation_result => |result| {
                    const evidence = result.evidence orelse return error.IncompleteReconciliationEvidence;
                    try self.validateHistoryEnvelope(event, evidence.scope.instrument);
                    if (!reconciliationEvidenceValid(result, event.envelope)) return error.IncompleteReconciliationEvidence;
                    if (event.envelope.exchange_account != self.exchange_account_identity) return error.CanonicalScopeMismatch;
                    const converted: oms.ReconciliationResult = .{ .reconciliation_id = std.math.cast(u64, result.identity) orelse return error.IdentityOutOfRange, .order_id = std.math.cast(u64, result.order) orelse return error.IdentityOutOfRange, .revision = result.revision, .status = switch (result.status) {
                        .found_live => .found_live,
                        .found_terminal => .found_terminal,
                        .confirmed_absent => .confirmed_absent,
                        .unresolved => .unresolved,
                    }, .cumulative_quantity = std.math.cast(i64, (result.cumulative_quantity orelse return error.InvalidReconciliation).lots) orelse return error.QuantityOutOfRange, .remaining_quantity = std.math.cast(i64, (result.remaining_quantity orelse return error.InvalidReconciliation).lots) orelse return error.QuantityOutOfRange, .terminal_state = if (result.terminal_status) |terminal| switch (terminal) {
                        .filled => .filled,
                        .canceled => .canceled,
                        .rejected => .rejected,
                        else => return error.InvalidReconciliation,
                    } else null, .canonical_digest = try canonicalPayloadDigest(event.event) };
                    return .{ .identity = .{ .reconciliation = result.identity }, .digest = history.hash(try snapshot_codec.encodeBare(&bytes, converted)) };
                },
                .account_reconciliation_result => |result| {
                    const evidence = result.account_economics orelse return null;
                    if (member == null and self.reconciliation_cursor != null) return .{ .identity = .{ .canonical_account_reconciliation = result.identity }, .digest = try canonicalPayloadDigest(event.event) };
                    if (evidence.covered_economic_fact_count > evidence.facts.len) return error.IncompleteReconciliationEvidence;
                    const index = member orelse (try self.coldAccountFactIndex(input, 0) orelse return null);
                    if (event.envelope.exchange_account != self.exchange_account_identity or evidence.exchange_account != self.exchange_account_identity or
                        event.envelope.scope != .account) return error.CanonicalScopeMismatch;
                    if (index >= evidence.covered_economic_fact_count) return error.InvalidHistoryCandidate;
                    const fact = evidence.facts[index];
                    return .{ .identity = switch (fact.kind) {
                        .fill => .{ .fill_economic_digest = fact.identity },
                        .funding => .{ .funding_economic_digest = fact.identity },
                        .forced => .{ .forced_economic_digest = fact.identity },
                    }, .digest = history.hash(&fact.digest) };
                },
                else => return null,
            },
        }
    }

    fn coldAccountFactIndex(self: *const TradingShard, input: CanonicalEvent, first: usize) !?u8 {
        if (input != .venue or input.venue.event != .account_reconciliation_result) return null;
        const evidence = input.venue.event.account_reconciliation_result.account_economics orelse return null;
        if (evidence.covered_economic_fact_count > evidence.facts.len) return error.IncompleteReconciliationEvidence;
        for (evidence.facts[0..evidence.covered_economic_fact_count], 0..) |fact, index| {
            if (index < first) continue;
            var retained = false;
            switch (fact.kind) {
                .fill => for (self.economic_projection.canonical_fill_evidence[0..self.economic_projection.canonical_fill_evidence_count]) |known| {
                    if (known.identity == fact.identity) {
                        retained = true;
                        break;
                    }
                },
                .forced => for (self.economic_projection.applied_forced_executions[0..self.economic_projection.applied_forced_execution_count]) |known| {
                    if (known.forced.identity == fact.identity) {
                        retained = true;
                        break;
                    }
                },
                .funding => for (self.economic_projection.applied_fundings[0..self.economic_projection.applied_funding_count]) |known| {
                    if (known.funding.identity == fact.identity) {
                        retained = true;
                        break;
                    }
                },
            }
            if (!retained) return @intCast(index);
        }
        return null;
    }

    const VerifiedAccountCoverage = struct { input_digest: history.Digest, root_digest: history.Digest };

    fn accountCoverageInputDigest(record: canonical.EventRecord) !history.Digest {
        var bytes: [cold.max_original_input_size]u8 = undefined;
        return history.hash(try encodeStableInput(&bytes, .{ .venue = record }));
    }

    fn groupHistorySemantic(group: oms.IntentGroup, member: ?u8, bytes: []u8) !HistorySemantic {
        if (group.count == 0 or group.count > group.members.len) return error.InvalidIntentGroup;
        var record: @import("order_history_batch.zig").GroupRecord = .{ .strategy = group.members[0].strategy_instance, .first_sequence = group.first_intent_sequence, .count = group.count, .members = std.mem.zeroes([oms.max_group_members]oms.SeenIntent) };
        for (group.members[0..group.count], 0..) |intent, index| {
            if (intent.strategy_instance != record.strategy or intent.intent_sequence != try std.math.add(u64, group.first_intent_sequence, index)) return error.NonConsecutiveIntentGroup;
            record.members[index] = .{ .strategy_instance = intent.strategy_instance, .intent_sequence = intent.intent_sequence, .group = group.first_intent_sequence, .policy = group.policy, .fingerprint = oms.intentFingerprint(intent, group.count) };
        }
        if (member != null or group.count == 1) {
            const index = member orelse 0;
            if (index >= group.count) return error.InvalidHistoryCandidate;
            const intent = record.members[index];
            return .{ .identity = .{ .intent = .{ .strategy = intent.strategy_instance, .sequence = intent.intent_sequence } }, .digest = history.hash(try snapshot_codec.encodeBare(bytes, intent)) };
        }
        return .{ .identity = .{ .group = .{ .strategy = record.strategy, .first_sequence = record.first_sequence } }, .digest = history.hash(try snapshot_codec.encodeBare(bytes, record)) };
    }

    fn validateHistoryEnvelope(self: *const TradingShard, event: canonical.EventRecord, instrument: canonical.InstrumentIdentity) !void {
        if (event.envelope.schema_version != canonical.schema_version or event.envelope.exchange_account != self.exchange_account_identity or
            (event.envelope.scope != .account and event.envelope.scope != .instrument) or
            (event.envelope.instrument != null and event.envelope.instrument != instrument)) return error.CanonicalScopeMismatch;
        const configured = self.instrumentEntry(instrument) orelse return error.UnknownOmsInstrument;
        if (event.envelope.venue != configured.venue) return error.CanonicalScopeMismatch;
    }

    pub fn apply(self: *TradingShard, input: CanonicalEvent) !ApplyResult {
        const before = self.authoritativeBarrier();
        var candidate: TradingShard = undefined;
        copyTradingState(&candidate, self);
        var publish_on_error = false;
        const result = candidate.applyCandidate(self, input, &publish_on_error, null) catch |err| {
            if (publish_on_error) copyTradingState(self, &candidate);
            return err;
        };
        copyTradingState(self, &candidate);
        return .{ .facts = try self.trace.factsAfter(before), .order_command = result.order_command, .oms_commands = self.oms.emitted() };
    }

    /// Applies to an unpublished copy of previous. Errors may mutate this copy;
    /// publish_on_error is true only for the original authoritative error path.
    pub fn applyOwnedCandidate(self: *TradingShard, previous: *const TradingShard, input: CanonicalEvent, publish_on_error: *bool) !ApplyResult {
        return self.applyCandidate(previous, input, publish_on_error, previous);
    }

    fn applyCandidate(self: *TradingShard, previous: *const TradingShard, input: CanonicalEvent, publish_on_error: *bool, rollback: ?*const TradingShard) !ApplyResult {
        publish_on_error.* = false;
        if (self == previous) return error.OwnedCandidateAliasesCommittedState;
        if (self.authoritativeBarrier() != previous.authoritativeBarrier()) return error.OwnedCandidateBarrierMismatch;
        if (input == .venue and input.venue.envelope.schema_version != canonical.schema_version) return error.UnsupportedSchema;
        _ = try std.math.add(u64, self.authoritativeBarrier(), 1);
        try self.trace.validate();
        var encoded: [journal.max_payload_size]u8 = undefined;
        const payload = try encodeStableInput(&encoded, input);
        var hasher = Sha256.init(.{});
        hasher.update("AcceptedShardInputV1\x00");
        digestInt(&hasher, u16, schema_version);
        const times = stableTimes(input);
        digestInt(&hasher, u64, times.source);
        digestInt(&hasher, u64, times.receive);
        digestInt(&hasher, u64, times.monotonic);
        digestInt(&hasher, u64, times.wall);
        digestInt(&hasher, u8, @bitCast(times.presence));
        hasher.update(payload);
        var input_digest: [32]u8 = undefined;
        hasher.final(&input_digest);
        const before = self.authoritativeBarrier();
        const result = self.applyUnfinalized(input, true, rollback, null) catch |err| {
            if (self.authoritativeBarrier() != before) {
                try self.trace.finalizeInput(before, input_digest);
                publish_on_error.* = true;
            }
            return err;
        };
        if (input != .core or (input.core.payload != .history_candidate_verified and input.core.payload != .history_safety_candidate_verified)) try self.observeOrderArchiveTimes(previous, input);
        if (self.open_economic_fact_count != previous.open_economic_fact_count or !std.meta.eql(self.reconciliation_cursor, previous.reconciliation_cursor)) {
            if (self.open_economic_fact_count > previous.open_economic_fact_count and self.open_economic_fact_count <= self.open_economic_facts.len) {
                const fact = &self.open_economic_facts[@intCast(self.open_economic_fact_count - 1)];
                fact.accepted_input_digest = input_digest;
                // Forced source evidence binds the original economic input,
                // including when a later history verification applies it.
                if (fact.kind == .forced) {
                    for (self.economic_projection.applied_forced_executions[0..self.economic_projection.applied_forced_execution_count]) |applied| {
                        if (applied.forced.identity != fact.identity) continue;
                        fact.accepted_input_digest = applied.source.accepted_input_digest;
                        break;
                    }
                }
            }
            try self.commitOpenEconomicFacts();
        }
        if (self.authoritativeBarrier() != before) try self.trace.finalizeInput(before, input_digest);
        // The original public path published before materializing its borrowed result.
        publish_on_error.* = true;
        return .{ .facts = try self.trace.factsAfter(before), .order_command = result.order_command, .oms_commands = self.oms.emitted() };
    }

    fn observeOrderArchiveTimes(self: *TradingShard, previous: *const TradingShard, input: CanonicalEvent) !void {
        const times = stableTimes(input);
        if (!times.presence.receive or times.receive == 0) return;
        for (self.oms.orders[0..self.oms.order_count], 0..) |*order, index| {
            if (order.id >= previous.oms.next_order_id) try self.oms.noteOrderCreated(order.id, times.receive);
            const terminal = switch (order.state) {
                .filled, .canceled, .rejected => true,
                else => false,
            };
            if (!terminal) continue;
            const was = if (index < previous.oms.order_count and previous.oms.orders[index].id == order.id)
                previous.oms.orders[index]
            else
                previous.oms.orderById(order.id);
            const newly_observed = was == null or order.last_report_id != was.?.last_report_id or order.last_reconciliation_id != was.?.last_reconciliation_id;
            if (newly_observed and order.created_at_utc_ns != 0) try self.oms.noteTerminalObserved(order.id, times.receive);
        }
    }

    fn applyUnfinalized(self: *TradingShard, input: CanonicalEvent, allow_cold_staging: bool, rollback: ?*const TradingShard, coverage: ?VerifiedAccountCoverage) anyerror!ApplyResult {
        if ((self.deferred_history_admission_count != 0 or (allow_cold_staging and (self.pending_history_candidate != null or self.pending_safety_history_candidate != null))) and !historySafetyInput(input))
            return error.HistoryLookupPending;
        if (allow_cold_staging) if (self.historyCandidateFor(input) catch |err| {
            if (err == error.HistorySafetyCapacity and input == .venue) try self.retainDeferredHistoryAdmission(input);
            return err;
        }) |pending| {
            const staged: CoreEvent = .{ .identity = std.math.cast(u64, pending.request.pending_id) orelse return error.HistoryPendingIdentityCapacity, .payload = .{ .history_candidate_started = pending } };
            return if (rollback) |previous| self.applyCoreOnOwnedCandidate(previous, staged) else self.applyCore(staged);
        };

        // Process admission cannot emit durable rejection facts: restart
        // replay reconstructs committed facts independently of this fence.
        if (self.recovery_admission_pending and input == .core) switch (input.core.payload) {
            .timer, .external_order_intent => return error.RecoveryAdmissionPending,
            .oms_intent_group => |group| {
                if (group.count == 0 or group.count > group.members.len) return error.InvalidIntentGroup;
                for (group.members[0..group.count]) |intent|
                    if (intent.operation != .cancel) return error.RecoveryAdmissionPending;
            },
            else => {},
        };
        return switch (input) {
            // The authenticated original executes inside the outer proof transaction candidate.
            .core => |event| if (allow_cold_staging)
                if (rollback) |previous| self.applyCoreOnOwnedCandidate(previous, event) else @call(.never_inline, TradingShard.applyCore, .{ self, event })
            else
                self.applyCoreInPlace(event),
            .venue => |event| if (rollback) |previous| self.applyVenueOnOwnedCandidate(previous, event, !allow_cold_staging, coverage) else @call(.never_inline, TradingShard.applyVenue, .{ self, event, !allow_cold_staging, coverage }),
        };
    }

    fn applyVenue(self: *TradingShard, event: canonical.EventRecord, verified_original: bool, coverage: ?VerifiedAccountCoverage) !ApplyResult {
        var candidate: TradingShard = undefined;
        copyTradingState(&candidate, self);
        const before = self.authoritativeBarrier();
        const result = candidate.applyVenueOnOwnedCandidate(self, event, verified_original, coverage) catch |err| {
            copyTradingState(self, &candidate);
            return err;
        };
        copyTradingState(self, &candidate);
        return .{ .facts = try self.trace.factsAfter(before), .order_command = result.order_command, .oms_commands = self.oms.emitted() };
    }

    fn applyVenueOnOwnedCandidate(self: *TradingShard, previous: *const TradingShard, event: canonical.EventRecord, verified_original: bool, coverage: ?VerifiedAccountCoverage) !ApplyResult {
        var publish = false;
        defer if (!publish) copyTradingState(self, previous);
        const account_failure_before = self.canonical_account.failure;
        const market_failure_generation_before = self.canonical_market.failure_generation;
        const before = self.authoritativeBarrier();
        self.oms.begin();
        const command = blk: {
            if (event.envelope.schema_version != canonical.schema_version) return error.UnsupportedSchema;
            break :blk self.handleCanonical(event, verified_original, coverage);
        } catch |err| {
            // Projection invalidation is authoritative even when the public
            // apply call reports the rejected observation. This is the only
            // exception to the ordinary candidate-commit-on-success rule.
            if (err == error.TombstoneFactConflict or err == error.ArchivedFactOutsideRetention or err == error.TerminalFactConflict or
                (event.event == .execution_report and event.envelope.exchange_account == self.exchange_account_identity and
                    (err == error.InvalidExecutionReport or err == error.StaleOrderRevision)))
            {
                self.oms.recovery_only = true;
                if (self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = event.envelope.identity.sequence,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .latched,
                    .reason = .reconciliation_break,
                    .open = false,
                });
                try self.trace.append(.canonical_order_reconciliation, event.envelope.identity.sequence);
                publish = true;
            } else if ((event.event == .fill or event.event == .funding_settlement or
                (event.event == .account_reconciliation_result and event.event.account_reconciliation_result.account_economics != null)) and event.envelope.exchange_account == self.exchange_account_identity)
            {
                copyTradingState(self, previous);
                self.oms.begin();
                if (event.event == .account_reconciliation_result) {
                    if (std.math.cast(u64, event.event.account_reconciliation_result.identity)) |identity| {
                        // Preserve verified identity for an unresolved result. A full
                        // evidence store or existing conflict retains the original fault.
                        _ = self.economic_projection.retainCanonicalSnapshot(identity, try canonicalPayloadDigest(event.event)) catch false;
                    }
                }
                try self.latchEconomicFault(event, switch (err) {
                    error.Overflow, error.QuantityOutOfRange, error.PriceOutOfRange, error.AssetAmountOutOfRange => .overflow,
                    error.NativeAssetCapacityExceeded, error.LedgerCapacityExceeded, error.EconomicFactCapacityExceeded, error.SafetyGateSetFull => .capacity_exhausted,
                    error.UnknownAssetDefinition => .unknown_asset,
                    error.MissingFillFee => .missing_amount,
                    error.InexactEconomicAmount => .inexact_amount,
                    else => .invalid_economic_fact,
                });
                try self.bindFreshCancellations(event.envelope.times.monotonic_ns orelse 0);
                publish = true;
            } else if ((event.event == .account_bootstrap_snapshot or event.event == .account_observed) and
                (err == error.UnknownAssetDefinition or err == error.AssetAmountOutOfRange))
            {
                copyTradingState(self, previous);
                self.oms.begin();
                try self.latchEconomicFault(event, if (err == error.UnknownAssetDefinition) .unknown_asset else .overflow);
                publish = true;
            } else if (self.canonical_account.failure != account_failure_before) {
                try self.latchEconomicFault(event, .invalid_economic_fact);
                try self.bindFreshCancellations(event.envelope.times.monotonic_ns orelse 0);
                publish = true;
            } else if (self.canonical_market.failure_generation != market_failure_generation_before) {
                if (self.canonical_market.get(self.instrument_identity)) |market| {
                    if (market.health == .gap) self.market_health = .gap;
                }
                try self.trace.append(.canonical_market_invalidated, event.envelope.identity.sequence);
                publish = true;
            }
            return err;
        };
        try self.bindFreshCancellations(event.envelope.times.monotonic_ns orelse 0);
        publish = true;
        return .{
            .facts = try self.trace.factsAfter(before),
            .order_command = command,
            .oms_commands = self.oms.emitted(),
        };
    }

    fn applyCore(self: *TradingShard, event: CoreEvent) !ApplyResult {
        var candidate: TradingShard = undefined;
        copyTradingState(&candidate, self);
        const before = self.authoritativeBarrier();
        const result = candidate.applyCoreInPlace(event) catch |err| {
            if (event.payload == .asset_definition_activated or err == error.TombstoneFactConflict or
                err == error.ArchivedFactOutsideRetention or err == error.TerminalFactConflict or err == error.LateEconomicFact or err == error.UnresolvedSettlementBoundary or err == error.ConflictingEconomicIdentity or
                ((event.payload == .history_candidate_verified or event.payload == .history_safety_candidate_verified) and candidate.economic_fault_count > self.economic_fault_count))
                copyTradingState(self, &candidate);
            return err;
        };
        copyTradingState(self, &candidate);
        return .{ .facts = try self.trace.factsAfter(before), .order_command = result.order_command, .oms_commands = self.oms.emitted() };
    }

    fn applyCoreOnOwnedCandidate(self: *TradingShard, previous: *const TradingShard, event: CoreEvent) !ApplyResult {
        return self.applyCoreInPlace(event) catch |err| {
            if (event.payload != .asset_definition_activated and err != error.TombstoneFactConflict and
                err != error.ArchivedFactOutsideRetention and err != error.TerminalFactConflict and err != error.LateEconomicFact and err != error.UnresolvedSettlementBoundary and err != error.ConflictingEconomicIdentity and
                !((event.payload == .history_candidate_verified or event.payload == .history_safety_candidate_verified) and self.economic_fault_count > previous.economic_fault_count))
                copyTradingState(self, previous);
            return err;
        };
    }

    fn applyCoreInPlace(self: *TradingShard, event: CoreEvent) !ApplyResult {
        const before = self.authoritativeBarrier();
        const asset_failures_before = self.asset_configuration_failure_count;
        self.oms.begin();
        const command = self.handle(event) catch |err| {
            if (event.payload == .asset_definition_activated) {
                self.asset_configuration_failed = true;
                self.asset_configuration_failure_count = try std.math.add(u64, asset_failures_before, 1);
                self.oms.recovery_only = true;
                try self.trace.append(.asset_definition_rejected, event.identity);
            }

            if (err == error.TombstoneFactConflict or err == error.ArchivedFactOutsideRetention or err == error.TerminalFactConflict or err == error.LateEconomicFact or err == error.UnresolvedSettlementBoundary or err == error.ConflictingEconomicIdentity) {
                self.oms.recovery_only = true;
                if (self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = event.identity,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .latched,
                    .reason = .reconciliation_break,
                    .open = false,
                });
                try self.trace.append(.oms_reconciliation_result, event.identity);
            }
            return err;
        };
        // Verified candidates already bind cancellation authority with their original clock.
        if (event.payload != .history_candidate_verified and event.payload != .history_safety_candidate_verified)
            try self.bindFreshCancellations(if (event.time_presence.monotonic) event.monotonic_time else 0);
        return .{
            .facts = try self.trace.factsAfter(before),
            .order_command = command,
            .oms_commands = self.oms.emitted(),
        };
    }

    pub fn checkpointGeneration(self: *const TradingShard) u64 {
        return if (self.checkpoint) |receipt| receipt.generation else 0;
    }
    pub fn checkpointArchiveBarrier(self: *const TradingShard) u64 {
        return if (self.checkpoint) |receipt| receipt.barrier else 0;
    }
    pub fn checkpointArchiveRoot(self: *const TradingShard) [32]u8 {
        return if (self.checkpoint) |receipt| receipt.archive_root else @splat(0);
    }

    fn pinFact(self: *const TradingShard, target: *Trace, sequence: u64) !void {
        if (sequence == 0) return;
        for (target.pinned[0..target.pinned_len]) |fact| if (fact.sequence == sequence) return;
        if (target.pinned_len == target.pinned.len) return error.PinnedFactCapacityExceeded;
        target.pinned[target.pinned_len] = self.trace.factAt(sequence) orelse return error.MissingPinnedFact;
        target.pinned_len += 1;
    }

    fn commandNeedsDispatchFacts(self: *const TradingShard, order_id: u64) bool {
        const order = self.oms.orderById(order_id) orelse return true;
        return switch (order.state) {
            .filled, .canceled, .rejected => order.reservation_active or order.reservation.atoms != 0 or
                order.pending_reservation != null or order.pending_previous_spec != null or
                order.pending_basis_quantity != 0 or order.replacement != null,
            else => true,
        };
    }

    fn checkpointPins(self: *const TradingShard) !Trace {
        var target = self.trace;
        target.pinned_len = 0;
        for (self.asset_registry.entries[0..self.asset_registry.count]) |entry| try self.pinFact(&target, entry.barrier);
        for (self.instrument_registry.entries[0..self.instrument_registry.count]) |entry| {
            try self.pinFact(&target, entry.rules_barrier);
            try self.pinFact(&target, entry.margin_barrier);
            try self.pinFact(&target, entry.trading_barrier);
            try self.pinFact(&target, entry.capability_barrier);
        }
        try self.pinFact(&target, self.coordinator_binding_fact);
        try self.pinFact(&target, self.host_activation_fact_sequence);
        try self.pinFact(&target, self.authority_control_barrier);
        for (self.control_fact_sequences[0..self.operational_state.command_count]) |sequence| try self.pinFact(&target, sequence);
        for ([_]EventKind{ .primary_lease_granted, .risk_lease_granted, .strategy_activated, .canonical_account_reconciliation_started, .canonical_account_reconciliation }) |kind| {
            if (self.latestFact(kind)) |fact| try self.pinFact(&target, fact.sequence);
        }
        for (self.oms.command_history[0..self.oms.command_history_count]) |command| {
            if (!self.commandNeedsDispatchFacts(command.order_id)) continue;
            try self.pinFact(&target, command.risk_decision_identity);
            try self.pinFact(&target, command.reservation_identity);
            const refs = command.authority;
            for ([_]u64{ refs.trading_authorization.barrier, refs.primary_lease.barrier, refs.risk_lease.barrier, refs.capability.barrier, refs.instrument_rules.barrier, refs.margin_rules.barrier, refs.instrument_trading.barrier, refs.config.barrier, refs.deadline_barrier }) |sequence| try self.pinFact(&target, sequence);
        }
        if (self.last_order_archive) |commit| try self.pinFact(&target, try std.math.add(u64, commit.receipt.root.barrier, 1));
        if (self.last_fill_archive) |commit| try self.pinFact(&target, try std.math.add(u64, commit.receipt.root.barrier, 1));
        if (self.last_forced_archive) |commit| try self.pinFact(&target, try std.math.add(u64, commit.receipt.root.barrier, 1));
        if (self.last_control_archive) |commit| try self.pinFact(&target, try std.math.add(u64, commit.receipt.root.barrier, 1));
        if (self.last_funding_archive) |commit| try self.pinFact(&target, try std.math.add(u64, commit.receipt.root.barrier, 1));
        if (self.last_reconciliation_archive) |commit| try self.pinFact(&target, try std.math.add(u64, commit.receipt.root.barrier, 1));
        if (self.open_economic_commitment_sequence != 0) try self.pinFact(&target, self.open_economic_commitment_sequence);
        for (self.deferred_history_admissions[0..self.deferred_history_admission_count]) |admission| try self.pinFact(&target, admission.fact_sequence);
        if (self.pending_history_candidate) |pending| try self.pinFact(&target, pending.original.sequence);
        if (self.pending_safety_history_candidate) |pending| try self.pinFact(&target, pending.original.sequence);
        std.mem.sort(Fact, target.pinned[0..target.pinned_len], {}, struct {
            fn less(_: void, a: Fact, b: Fact) bool {
                return a.sequence < b.sequence;
            }
        }.less);
        target.pinned_root = target.pinnedDigest();
        return target;
    }

    pub fn checkpointReceipt(self: *const TradingShard, stream: u64, generation: u64, archive_root: [32]u8) !CheckpointReceipt {
        try self.trace.validate();
        if (stream == 0 or self.trace.len == 0 or std.mem.allEqual(u8, &archive_root, 0) or
            generation != try std.math.add(u64, self.checkpointGeneration(), 1) or
            (self.checkpoint != null and self.checkpoint.?.stream != stream)) return error.InvalidCheckpointReceipt;
        const pins = try self.checkpointPins();
        var receipt: CheckpointReceipt = .{
            .stream = stream,
            .generation = generation,
            .first_sequence = try std.math.add(u64, self.trace.base_sequence, 1),
            .barrier = self.authoritativeBarrier(),
            .history_head = self.trace.history_head,
            .input_head = self.trace.input_head,
            .previous_checkpoint_root = if (self.checkpoint) |previous| previous.checkpoint_root else @splat(0),
            .snapshot_digest = self.canonicalStateDigest(),
            .pinned_fact_root = pins.pinned_root,
            .archive_root = archive_root,
            .checkpoint_root = @splat(0),
        };
        receipt.checkpoint_root = checkpointRoot(receipt);
        return receipt;
    }

    pub fn authoritativeBarrier(self: *const TradingShard) u64 {
        return self.trace.last_sequence;
    }

    pub fn canonicalStateDigest(self: *const TradingShard) [Sha256.digest_length]u8 {
        return stateDigestBorrowed(self);
    }

    pub fn appliedHostActivation(self: *const TradingShard, stable_journal: *const journal.Journal) !host_gateway.AppliedActivation {
        try self.trace.validate();
        if (self.host_activation_identity == 0 or self.host_activation_fact_sequence == 0 or
            stable_journal.last_sequence != self.authoritativeBarrier() or
            stable_journal.last_sequence < self.host_activation_fact_sequence)
            return error.HostNotActivated;
        return .{
            .authorization = .{
                .strategy_identity = self.strategy_identity,
                .config_version = self.strategy_config_version,
                .activation_identity = self.host_activation_identity,
                .activation_barrier = self.host_activation_barrier,
            },
            .session = self.host_activation_session,
            .fact_sequence = self.host_activation_fact_sequence,
            .state_digest = self.host_activation_state_digest,
        };
    }

    pub fn nextHostActivationIdentity(self: *const TradingShard) !u128 {
        if (!self.host_activation_seen or self.host_activation_identity != 0) return error.HostNotRevoked;
        return std.math.add(u128, self.strategy_activation_identity, 1);
    }

    /// A permutation-only business-state comparison. CanonicalStateDigest
    /// remains the ordered history/snapshot integrity digest.
    pub fn semanticAuthorityDigest(self: *const TradingShard) [Sha256.digest_length]u8 {
        return semanticStateDigest(self);
    }

    /// Reports whether one strategy is durably fenced from new risk intent.
    pub fn strategyFenced(self: *const TradingShard, strategy_instance: u128) bool {
        for (self.fenced_strategy_instances[0..self.fenced_strategy_count]) |identity|
            if (identity == strategy_instance) return true;
        return false;
    }

    /// Encodes authoritative state at the exact sealed stable-journal barrier.
    pub fn snapshot(
        self: *const TradingShard,
        stable_journal: *const journal.Journal,
        barrier: u64,
        destination: []u8,
    ) ![]const u8 {
        if (self.trace.len > self.trace.events.len or self.trace.pinned_len > self.trace.pinned.len) return error.InvalidSnapshotState;
        if (!stable_journal.sealed or barrier == 0 or
            barrier != stable_journal.last_sequence or self.authoritativeBarrier() != barrier)
            return error.InvalidSnapshotBarrier;
        return snapshot_codec.writeWithPolicy(destination, .{
            .state_schema = state_schema_version,
            .release_artifact = release_artifact_identity,
            .schema_registry = schema_registry_identity,
            .barrier = barrier,
            .instrument_rules_version = self.instrument_rules_version,
            .margin_rules_version = self.margin_rules_version,
            .state_digest = self.canonicalStateDigest(),
        }, self, CoreSnapshotEncodingPolicy);
    }

    /// Restores a validated snapshot into caller-owned recovery storage.
    pub fn restoreSnapshotInto(recovered: *TradingShard, encoded: []const u8) !u64 {
        const metadata = try snapshot_codec.readInto(encoded, recovered, state_schema_version, release_artifact_identity, schema_registry_identity);
        recovered.oms.begin();
        try validateSnapshotState(recovered);
        const digest = recovered.canonicalStateDigest();
        if (metadata.barrier == 0 or recovered.authoritativeBarrier() != metadata.barrier or
            recovered.instrument_rules_version != metadata.instrument_rules_version or
            recovered.margin_rules_version != metadata.margin_rules_version or
            !std.mem.eql(u8, &metadata.state_digest, &digest))
            return error.InvalidSnapshotState;
        return metadata.barrier;
    }

    pub fn restoreSnapshot(encoded: []const u8) !SnapshotRestore {
        var restored: SnapshotRestore = undefined;
        restored.barrier = try restoreSnapshotInto(&restored.shard, encoded);
        return restored;
    }

    /// Restores a snapshot and semantically replays its immediately following journal segment.
    pub fn restore(encoded: []const u8, stable_tail: []const u8) !SnapshotRecovery {
        return restoreSegments(encoded, &.{stable_tail});
    }

    /// Publishes only complete verified fact groups into caller-owned recovery storage.
    pub fn restoreSegmentsInto(shard: *TradingShard, encoded: []const u8, stable_tails: []const []const u8) !RestoreMetadata {
        const barrier = try restoreSnapshotInto(shard, encoded);
        var status: journal.ScanStatus = .clean;
        for (stable_tails, 0..) |tail, index| {
            var reader = try journal.Reader.init(tail);
            if (reader.next_sequence != try std.math.add(u64, shard.authoritativeBarrier(), 1)) return error.SnapshotJournalGap;
            status = try replayReaderInto(&reader, shard);
            if (status == .truncated_tail and index + 1 != stable_tails.len) return error.SnapshotJournalGap;
        }
        return .{ .barrier = barrier, .status = status };
    }

    pub fn restoreSegments(encoded: []const u8, stable_tails: []const []const u8) !SnapshotRecovery {
        var restored: SnapshotRecovery = undefined;
        const metadata = try restoreSegmentsInto(&restored.shard, encoded, stable_tails);
        restored.barrier = metadata.barrier;
        restored.status = metadata.status;
        return restored;
    }

    pub fn economicSummary(self: *const TradingShard) EconomicSummary {
        return .{
            .portfolio = self.economic_projection.portfolio,
            .exchange = self.economic_projection.exchange,
            .treasury_usdt_atoms = self.economic_projection.treasury_usdt_atoms,
            .suspense_usdt_atoms = self.economic_projection.suspense_usdt_atoms,
            .ledger_transactions = self.economic_projection.ledger_count,
            .reconciliation_break = self.economic_projection.reconciliation_break,
            .valuation_complete = self.economic_projection.reportingValuationComplete(),
            .treasury_native_assets = self.economic_projection.treasury_native_assets,
            .treasury_native_asset_count = self.economic_projection.treasury_native_asset_count,
            .suspense_native_assets = self.economic_projection.suspense_native_assets,
            .suspense_native_asset_count = self.economic_projection.suspense_native_asset_count,
        };
    }

    /// Remaining lease headroom derived from the authoritative economic and
    /// OMS reservation owners; it is never snapshotted as competing state.
    pub fn riskLeaseRemainingAtoms(self: *const TradingShard) !i128 {
        return std.math.sub(
            i128,
            self.risk_lease_atoms,
            try std.math.add(i128, self.economic_projection.portfolio.margin_atoms, try self.activeReservationAtoms()),
        );
    }

    pub fn activeReservationAtoms(self: *const TradingShard) !i128 {
        const reservation = try self.oms.activeReservations(settlement_asset);
        return reservation.atoms;
    }

    pub const IntegritySnapshot = struct {
        account_valid: bool,
        account_failure: ?account_projection.AccountProjection.Failure,
        market_health: canonical.MarketDataHealth,
        market_failure: ?market_projection.Projection.Failure,
        effective_trading_authority: bool,
        canonical_state_digest: [Sha256.digest_length]u8,
    };

    pub fn integritySnapshot(self: *const TradingShard) IntegritySnapshot {
        return .{
            .account_valid = self.canonical_account.valid and self.economic_fault_count == 0,
            .account_failure = self.canonical_account.failure,
            .market_health = self.canonical_market.aggregateHealth(),
            .market_failure = self.canonical_market.latestFailure(),
            .effective_trading_authority = self.operational_state.effectiveTradingAuthority(),
            .canonical_state_digest = self.canonicalStateDigest(),
        };
    }

    /// Account reconciliation is single-flight at the VenueAdapter seam, so
    /// the latest durable control/result trace pair is its recovery status.
    pub fn accountReconciliationPending(self: *const TradingShard) bool {
        const started = self.latestFact(.canonical_account_reconciliation_started) orelse return false;
        const completed = self.latestFact(.canonical_account_reconciliation) orelse return true;
        return started.sequence > completed.sequence;
    }

    /// A copied snapshot of exactly the replayed Owner configuration, without defaults.
    pub fn activatedAssets(self: *const TradingShard) asset_registry.Registry {
        return self.asset_registry;
    }

    pub fn genesisReady(self: *const TradingShard) bool {
        self.requireSettlementConsumers() catch return false;
        return !self.asset_configuration_failed and self.instrument_registry.count != 0 and self.instrument_rules_version != 0 and self.margin_rules_version != 0 and
            self.account_configured and self.exchange_balance_observed and
            self.exchange_positions_observed and self.opening_balance_observed and
            self.virtual_portfolio_active and self.portfolio_funded and self.strategy_active and
            self.fencing_token != 0 and self.risk_lease_atoms > 0;
    }

    fn portfolioPosition(self: *const TradingShard) Position {
        return .{ .quantity = self.economic_projection.portfolio.swap.quantity, .open_cost_atoms = self.economic_projection.portfolio.swap.open_cost_atoms };
    }

    fn exchangePosition(self: *const TradingShard) Position {
        return .{ .quantity = self.economic_projection.exchange.swap.quantity, .open_cost_atoms = self.economic_projection.exchange.swap.open_cost_atoms };
    }

    fn spotPortfolioPosition(self: *const TradingShard) Position {
        return .{ .quantity = self.economic_projection.portfolio.spot.quantity, .open_cost_atoms = self.economic_projection.portfolio.spot.open_cost_atoms };
    }

    fn spotExchangePosition(self: *const TradingShard) Position {
        return .{ .quantity = self.economic_projection.exchange.spot.quantity, .open_cost_atoms = self.economic_projection.exchange.spot.open_cost_atoms };
    }

    fn portfolioCash(self: *const TradingShard) i128 {
        return self.economic_projection.portfolio.usdt_balance_atoms;
    }
    fn treasuryCash(self: *const TradingShard) i128 {
        return self.economic_projection.treasury_usdt_atoms;
    }
    fn exchangeCash(self: *const TradingShard) i128 {
        return self.economic_projection.exchange.usdt_balance_atoms;
    }
    fn portfolioFee(self: *const TradingShard) i128 {
        return self.economic_projection.portfolio.fee_atoms;
    }
    fn exchangeFee(self: *const TradingShard) i128 {
        return self.economic_projection.exchange.fee_atoms;
    }
    fn totalFees(self: *const TradingShard) i128 {
        return self.portfolioFee();
    }
    fn realizedPnl(self: *const TradingShard) i128 {
        return self.economic_projection.portfolio.realized_pnl_atoms;
    }
    fn unrealizedPnl(self: *const TradingShard) i128 {
        return self.economic_projection.portfolio.unrealized_pnl_atoms;
    }

    fn riskLimits(self: *const TradingShard) risk_module.Limits {
        return .{
            .strategy = .{ .asset = settlement_asset, .atoms = self.strategy_limit_atoms },
            .portfolio = .{ .asset = settlement_asset, .atoms = self.portfolio_limit_atoms },
            .decision_domain = .{ .asset = settlement_asset, .atoms = self.risk_lease_atoms },
            .exchange_account = .{ .asset = settlement_asset, .atoms = self.exchange_account_limit_atoms },
            .global = .{ .asset = settlement_asset, .atoms = self.global_limit_atoms },
        };
    }

    fn riskRules(self: *const TradingShard, instrument_id: canonical.InstrumentIdentity) risk_module.Rules {
        const registered = self.instrument_registry.get(instrument_id);
        const rules_version = if (registered) |entry| entry.rules.version else self.instrument_rules_version;
        const quantity_denominator = if (registered) |entry| entry.rules.quantity_denominator else self.quantity_denominator;
        const margin = if (registered) |entry| entry.margin else shard_event.MarginRules{ .version = self.margin_rules_version, .price_tick_atoms = self.price_tick_atoms, .venue_initial_margin_ppm = self.venue_initial_margin_ppm, .internal_initial_margin_ppm = self.internal_initial_margin_ppm, .internal_maintenance_margin_ppm = self.internal_maintenance_margin_ppm, .fee_ppm = self.risk_fee_ppm, .opening_buffer_atoms = self.opening_buffer_atoms, .opening_buffer_bps = self.opening_buffer_bps, .opening_liquidation_distance_ticks = self.opening_liquidation_distance_ticks, .warning_buffer_atoms = self.warning_buffer_atoms, .kill_buffer_atoms = self.kill_buffer_atoms, .warning_buffer_bps = self.warning_buffer_bps, .kill_buffer_bps = self.kill_buffer_bps, .warning_liquidation_distance_ticks = self.warning_liquidation_distance_ticks, .kill_liquidation_distance_ticks = self.kill_liquidation_distance_ticks };
        return .{
            .settlement_asset = if (registered) |entry| entry.rules.settlement_asset else settlement_asset,
            .instrument = instrument_id,
            .rules_version = rules_version,
            .quantity_denominator = quantity_denominator,
            .quantity_numerator = if (registered) |entry| entry.rules.quantity_numerator else 1,
            .price_tick_value = .{ .asset = if (registered) |entry| entry.rules.settlement_asset else settlement_asset, .atoms = margin.price_tick_atoms },
            .venue_initial_margin_ppm = margin.venue_initial_margin_ppm,
            .internal_initial_margin_ppm = margin.internal_initial_margin_ppm,
            .internal_maintenance_margin_ppm = margin.internal_maintenance_margin_ppm,
            .fee_ppm = margin.fee_ppm,
            .opening_buffer = .{ .asset = if (registered) |entry| entry.rules.settlement_asset else settlement_asset, .atoms = margin.opening_buffer_atoms },
            .opening_buffer_bps = margin.opening_buffer_bps,
            .opening_liquidation_distance_ticks = margin.opening_liquidation_distance_ticks,
            .warning_buffer = .{ .asset = if (registered) |entry| entry.rules.settlement_asset else settlement_asset, .atoms = margin.warning_buffer_atoms },
            .kill_buffer = .{ .asset = if (registered) |entry| entry.rules.settlement_asset else settlement_asset, .atoms = margin.kill_buffer_atoms },
            .warning_buffer_bps = margin.warning_buffer_bps,
            .kill_buffer_bps = margin.kill_buffer_bps,
            .warning_liquidation_distance_ticks = margin.warning_liquidation_distance_ticks,
            .kill_liquidation_distance_ticks = margin.kill_liquidation_distance_ticks,
        };
    }

    const QualifiedIntentGroup = struct {
        group: oms_module.IntentGroup,
        reservation_atoms: i128,
    };

    fn validateExactOmsSpec(intent: oms_module.Intent, entry: instrument_registry.Entry) !void {
        if (intent.quantity <= 0 or intent.limit_price.instrument != intent.instrument or
            intent.limit_price.rules_version != entry.rules.version or intent.limit_price.ticks <= 0)
            return error.UnsupportedOrderSpec;
        if (intent.market_protection_price) |price| {
            if (price.instrument != intent.instrument or price.rules_version != entry.rules.version or price.ticks <= 0)
                return error.UnsupportedOrderSpec;
        }
        if (!oms_module.exactOrderSpec(intent.order_type, intent.time_in_force, intent.market_protection_price != null)) return error.UnsupportedOrderSpec;
        if (intent.operation == .amend and intent.native_amend and
            !(if (entry.capability) |capability| capability.supports_native_amend else false))
            return error.CapabilityUnsupported;
        if (intent.order_type == .post_only or intent.venue_reduce_only or intent.market_protection_price != null) {
            const capability = entry.capability orelse return error.CapabilityUnsupported;
            if ((intent.order_type == .post_only and !capability.supports_post_only) or
                (intent.venue_reduce_only and !capability.supports_venue_reduce_only) or
                (intent.market_protection_price != null and !capability.supports_market_protection))
                return error.CapabilityUnsupported;
        }
    }

    fn qualifyOmsGroup(self: *TradingShard, group: oms_module.IntentGroup) !QualifiedIntentGroup {
        var qualified = group;
        var active = try self.oms.activeReservations(settlement_asset);
        for (qualified.members[0..qualified.count], 0..) |*intent, member_index| {
            for (self.fenced_strategy_instances[0..self.fenced_strategy_count]) |fenced|
                if (intent.strategy_instance == fenced and intent.operation != .cancel)
                    return error.StrategyCutoverFenced;
            if (intent.operation == .cancel) continue;
            if (!self.settlementConsumersCompatible(intent.instrument)) return error.AssetPrecisionUnsupported;
            var replaced: canonical.AssetAmount = .{ .asset = settlement_asset, .atoms = 0 };
            if (intent.operation == .amend) {
                const target = self.oms.orderById(intent.target_order_id) orelse return error.UnknownOrder;
                if (target.reservation_active) replaced = target.reservation;
            }
            const instrument_config = self.instrumentEntry(intent.instrument) orelse return error.UnknownOmsInstrument;
            if (!instrument_config.margin_configured) return error.InstrumentRulesInactive;
            if (!instrument_config.trading_enabled) return error.TradingNotAuthorized;
            const market_state = self.canonical_market.get(intent.instrument) orelse return error.MissingInstrumentDefinition;
            if (market_state.health != .healthy) return error.MarketDataGap;
            const observed_exchange_cash = try self.currentNativeRiskCash(intent.instrument);
            if (instrument_config.product == .spot) {
                const unit = try self.baseAtomsPerLot(instrument_config);
                try self.asset_registry.checkAmount(.{ .asset = unit.asset, .atoms = try std.math.mul(i128, intent.quantity, unit.atoms) }, true);
            }
            if (instrument_config.product == .spot and intent.side == .sell) {
                const unit = try self.baseAtomsPerLot(instrument_config);
                var pending_lots: i64 = intent.quantity;
                var committed_sell_atoms: i128 = 0;
                for (self.oms.orders[0..self.oms.order_count]) |order| {
                    const ordered = self.instrumentEntry(order.instrument) orelse return error.UnknownOmsInstrument;
                    if (ordered.product != .spot or ordered.rules.base_asset != unit.asset or order.side != .sell) continue;
                    const order_unit = try self.baseAtomsPerLot(ordered);
                    // Reports describe executed lots; only unique applied fills
                    // have debited the native inventory backing those lots.
                    const applied = try self.economic_projection.appliedCanonicalFillQuantity(order.id);
                    const obligation = if (order.reservation_active) @max(order.confirmed_quantity, @max(order.quantity, order.pending_basis_quantity)) else order.cumulative_quantity;
                    const remaining = @max(try std.math.sub(i64, obligation, applied), 0);
                    if (intent.operation == .amend and order.id == intent.target_order_id) {
                        const prospective = try std.math.add(i64, intent.quantity, @max(try std.math.sub(i64, order.cumulative_quantity, applied), 0));
                        pending_lots = @max(prospective, remaining);
                        continue;
                    }
                    committed_sell_atoms = try std.math.add(i128, committed_sell_atoms, try std.math.mul(i128, remaining, order_unit.atoms));
                }
                for (self.oms.tombstones[0..self.oms.tombstone_count]) |archived| {
                    const archived_config = self.instrumentEntry(archived.instrument) orelse return error.UnknownOmsInstrument;
                    if (archived_config.product != .spot or archived_config.rules.base_asset != unit.asset) continue;
                    const archive_unit = try self.baseAtomsPerLot(archived_config);
                    const applied = try self.economic_projection.appliedCanonicalFillQuantity(archived.order_id);
                    const remaining = @max(try std.math.sub(i64, archived.cumulative_quantity, applied), 0);
                    if (remaining == 0) continue;
                    var side: ?oms_module.Side = null;
                    for (self.oms.command_history[0..self.oms.command_history_count]) |command| {
                        if (command.order_id == archived.order_id) {
                            side = command.side;
                            break;
                        }
                    }
                    if (side == null) return error.IncompleteReconciliationEvidence;
                    if (side.? == .sell)
                        committed_sell_atoms = try std.math.add(i128, committed_sell_atoms, try std.math.mul(i128, remaining, archive_unit.atoms));
                }
                var group_sell_atoms: i128 = 0;
                for (qualified.members[0..member_index]) |prior| {
                    if (prior.operation == .cancel or prior.side != .sell) continue;
                    const prior_entry = self.instrumentEntry(prior.instrument) orelse return error.UnknownOmsInstrument;
                    if (prior_entry.product != .spot or prior_entry.rules.base_asset != unit.asset) continue;
                    const prior_unit = try self.baseAtomsPerLot(prior_entry);
                    group_sell_atoms = try std.math.add(i128, group_sell_atoms, try std.math.mul(i128, prior.quantity, prior_unit.atoms));
                }
                group_sell_atoms = try std.math.add(i128, group_sell_atoms, try std.math.mul(i128, pending_lots, unit.atoms));
                const required = try std.math.add(i128, committed_sell_atoms, group_sell_atoms);
                if (required > self.economic_projection.portfolio.spotInventoryAtoms(unit.asset) or
                    required > self.economic_projection.exchange.spotInventoryAtoms(unit.asset)) return error.InsufficientSpotAsset;
            }
            try validateExactOmsSpec(intent.*, instrument_config);
            try self.checkAssetAmounts(canonical.InstrumentQuantity{ .instrument = intent.instrument, .rules_version = instrument_config.rules.version, .lots = intent.quantity }, true);
            try self.checkAssetAmounts(intent.limit_price, true);
            if (intent.market_protection_price) |price| try self.checkAssetAmounts(price, true);
            const portfolio_position_quantity = self.economic_projection.portfolio.positionForInstrument(intent.instrument).quantity;
            const exchange_position_quantity = self.economic_projection.exchange.positionForInstrument(intent.instrument).quantity;
            const signed_delta = (if (intent.side == .buy) intent.quantity else -intent.quantity);
            const next_portfolio = try std.math.add(i64, portfolio_position_quantity, signed_delta);
            const reduces_portfolio = @abs(next_portfolio) <= @abs(portfolio_position_quantity) and
                !(portfolio_position_quantity != 0 and next_portfolio != 0 and
                    (portfolio_position_quantity < 0) != (next_portfolio < 0));
            const next_exchange = try std.math.add(i64, exchange_position_quantity, signed_delta);
            const reduces_exchange = @abs(next_exchange) <= @abs(exchange_position_quantity) and
                !(exchange_position_quantity != 0 and next_exchange != 0 and
                    (exchange_position_quantity < 0) != (next_exchange < 0));
            const reduces_only = reduces_portfolio and reduces_exchange;
            if (self.operational_state.mode == .draining and
                self.operational_state.active_operation_kind == .de_risk)
            {
                const target = self.operational_state.target_position;
                if ((portfolio_position_quantity > target and
                    (intent.side != .sell or next_portfolio < target)) or
                    (portfolio_position_quantity < target and
                        (intent.side != .buy or next_portfolio > target)) or
                    portfolio_position_quantity == target)
                    return error.DeRiskTargetViolation;
            }
            if (!reduces_only and !self.operational_state.mayIncrease(intent.side == .buy))
                return error.TradingNotAuthorized;
            if (reduces_only and !self.operational_state.effectiveTradingAuthority() and
                !self.operational_state.mayReduceOnly())
                return error.TradingNotAuthorized;
            const market = self.canonical_market.get(intent.instrument) orelse return error.MissingInstrumentDefinition;
            const mark = market.mark orelse return error.InvalidMarkPrice;
            const mark_price = mark.ticks;
            const assessment = try risk_module.assess(self.riskRules(intent.instrument), self.riskLimits(), .{
                .portfolio_cash = .{ .asset = settlement_asset, .atoms = self.portfolioCash() },
                .exchange_cash = .{ .asset = settlement_asset, .atoms = observed_exchange_cash },
                .portfolio_position = .{ .instrument = intent.instrument, .rules_version = instrument_config.rules.version, .lots = portfolio_position_quantity },
                .exchange_position = .{ .instrument = intent.instrument, .rules_version = instrument_config.rules.version, .lots = exchange_position_quantity },
                .active_order_reservations = active,
                .replaced_order_reservation = replaced,
                .mark_price = mark,
            }, .{
                .product = instrument_config.product,
                .side = if (intent.side == .buy) .buy else .sell,
                .quantity = .{ .instrument = intent.instrument, .rules_version = instrument_config.rules.version, .lots = intent.quantity },
                .risk_price = .{ .instrument = intent.instrument, .rules_version = instrument_config.rules.version, .ticks = @max(intent.limit_price.ticks, mark_price) },
                .portfolio_reduce_only = intent.portfolio_reduce_only,
            });
            intent.reservation = assessment.order_reservation;
            intent.portfolio_reduce_only = assessment.portfolio_reduce_only;
            if (intent.venue_reduce_only and !assessment.venue_reduce_only) return error.UnsupportedOrderSpec;
            intent.venue_reduce_only = assessment.venue_reduce_only and
                (if (instrument_config.capability) |capability| capability.supports_venue_reduce_only else false);
            active = assessment.total_reserved;
            self.portfolio_margin_buffer_atoms = assessment.portfolio_margin_buffer.atoms;
            self.exchange_margin_buffer_atoms = assessment.exchange_margin_buffer.atoms;
            self.portfolio_buffer_bps = assessment.portfolio_buffer_bps;
            self.exchange_buffer_bps = assessment.exchange_buffer_bps;
            self.portfolio_liquidation_distance_ticks = assessment.portfolio_liquidation_distance_ticks;
            self.exchange_liquidation_distance_ticks = assessment.exchange_liquidation_distance_ticks;
            self.portfolio_margin_gate = assessment.portfolio_gate;
            self.exchange_margin_gate = assessment.exchange_gate;
            const strict_gate = if (@intFromEnum(assessment.portfolio_gate) >= @intFromEnum(assessment.exchange_gate))
                assessment.portfolio_gate
            else
                assessment.exchange_gate;
            if (self.operational_state.initialized) try self.applyOperationalGate(.{
                .gate_identity = if (strict_gate == .kill) margin_kill_gate_identity else margin_warning_gate_identity,
                .target_identity = self.operational_state.target_identity,
                .kind = if (strict_gate == .kill) .latched else .warning,
                .reason = if (strict_gate == .kill) .margin_kill else .margin_warning,
                .open = strict_gate == .healthy,
                .blocks_buy = true,
                .blocks_sell = true,
            });
            if (!reduces_only and strict_gate != .healthy) return error.MarginSafetyGateClosed;
        }
        return .{
            .group = qualified,
            .reservation_atoms = active.atoms,
        };
    }

    fn instrumentEntry(self: *const TradingShard, instrument_id: canonical.InstrumentIdentity) ?instrument_registry.Entry {
        return self.instrument_registry.get(instrument_id);
    }

    fn singleProductEntry(self: *const TradingShard, product: canonical.Product) ?instrument_registry.Entry {
        var found: ?instrument_registry.Entry = null;
        for (self.instrument_registry.entries[0..self.instrument_registry.count]) |entry| {
            if (entry.product != product) continue;
            if (found != null) return null;
            found = entry;
        }
        return found;
    }

    /// Returns the immutable registry view used by risk, OMS and economics.
    /// Callers cannot mutate the shard through this copy-returning query.
    pub fn registryInstrument(self: *const TradingShard, identity: canonical.InstrumentIdentity) ?InstrumentEntry {
        return self.instrumentEntry(identity);
    }

    fn confirmPendingReplacement(self: *TradingShard, order_id: u64, sequence: u64, now_monotonic_ns: u64) !?i128 {
        const replacement = (self.oms.replacementIntent(order_id, sequence) catch {
            try self.oms.discardReplacement(order_id);
            return null;
        }) orelse return null;
        if (self.oms.blocksNewSend()) {
            try self.oms.discardReplacement(order_id);
            return null;
        }
        return self.qualifyAndConfirmReplacement(order_id, replacement, now_monotonic_ns);
    }

    // Ordinary reports have no replacement; do not reserve a full shard
    // candidate in those callers' already transactional frames.
    noinline fn qualifyAndConfirmReplacement(self: *TradingShard, order_id: u64, replacement: oms_module.Intent, now_monotonic_ns: u64) !?i128 {
        var candidate: TradingShard = undefined;
        copyTradingState(&candidate, self);
        var group: oms_module.IntentGroup = .{ .first_intent_sequence = replacement.intent_sequence, .count = 1 };
        group.members[0] = replacement;
        const qualified = candidate.qualifyOmsGroup(group) catch |err| switch (err) {
            error.MarketDataGap,
            error.StrategyLimitExceeded,
            error.VirtualPortfolioLimitExceeded,
            error.DecisionDomainLimitExceeded,
            error.ExchangeAccountLimitExceeded,
            error.GlobalLimitExceeded,
            error.PortfolioOpeningGateClosed,
            error.ExchangeOpeningGateClosed,
            error.InsufficientSpotAsset,
            error.PortfolioReduceOnlyViolation,
            error.MarginSafetyGateClosed,
            error.StrategyCutoverFenced,
            error.TradingNotAuthorized,
            => {
                try self.oms.discardReplacement(order_id);
                return null;
            },
            else => return err,
        };
        const intent = qualified.group.members[0];
        try candidate.trace.append(.risk_accepted, intent.intent_sequence);
        const decision_barrier: u64 = candidate.authoritativeBarrier();
        try candidate.trace.append(.risk_reservation_created, intent.intent_sequence);
        try candidate.oms.confirmReplacement(order_id, intent.reservation, intent.portfolio_reduce_only, intent.venue_reduce_only, intent.intent_sequence, .{
            .decision = decision_barrier,
            .reservation = candidate.authoritativeBarrier(),
            .authority = try candidate.dispatchAuthorityRefs(intent.instrument, now_monotonic_ns, decision_barrier),
        });
        copyTradingState(self, &candidate);
        return qualified.reservation_atoms;
    }

    fn adjustMarginBuffersForReservationChange(self: *TradingShard, previous: i128) !void {
        const current_atoms = try self.activeReservationAtoms();
        const change = try std.math.sub(i128, current_atoms, previous);
        self.portfolio_margin_buffer_atoms = try std.math.sub(i128, self.portfolio_margin_buffer_atoms, change);
        self.exchange_margin_buffer_atoms = try std.math.sub(i128, self.exchange_margin_buffer_atoms, change);
    }

    fn applyOperationalGate(self: *TradingShard, change: operational.SafetyGateChange) !void {
        const action = try self.operational_state.applyGate(change);
        if (action.cancel_open_orders)
            try self.oms.cancelOpenOrders(action.cancel_increasing_only);
    }

    /// Authoritative economics that KeepPositions must preserve verbatim.
    pub const LifecycleEconomics = struct {
        positions: struct {
            portfolio_swap: Position = .{},
            exchange_swap: Position = .{},
            portfolio_spot: Position = .{},
            exchange_spot: Position = .{},
        } = .{},
        cash: struct {
            portfolio_atoms: i128 = 0,
            treasury_atoms: i128 = 0,
            exchange_atoms: i128 = 0,
        } = .{},
        fees: struct {
            portfolio_atoms: i128 = 0,
            exchange_atoms: i128 = 0,
            total_atoms: i128 = 0,
        } = .{},
        pnl: struct {
            realized_atoms: i128 = 0,
            unrealized_atoms: i128 = 0,
        } = .{},
        ledger: struct {
            transaction_count: u64 = 0,
            portfolio_transfer_count: u64 = 0,
            portfolio_debits_atoms: i128 = 0,
            portfolio_credits_atoms: i128 = 0,
            exchange_debits_atoms: i128 = 0,
            exchange_credits_atoms: i128 = 0,
            projections_complete: bool = false,
        } = .{},
        projection_digest: [Sha256.digest_length]u8 = @splat(0),
        de_risk_target_position: i64 = 0,
    };

    pub fn captureLifecycleEconomics(self: *const TradingShard) LifecycleEconomics {
        return .{
            .positions = .{
                .portfolio_swap = self.portfolioPosition(),
                .exchange_swap = self.exchangePosition(),
                .portfolio_spot = self.spotPortfolioPosition(),
                .exchange_spot = self.spotExchangePosition(),
            },
            .cash = .{
                .portfolio_atoms = self.portfolioCash(),
                .treasury_atoms = self.treasuryCash(),
                .exchange_atoms = self.exchangeCash(),
            },
            .fees = .{
                .portfolio_atoms = self.portfolioFee(),
                .exchange_atoms = self.exchangeFee(),
                .total_atoms = self.totalFees(),
            },
            .pnl = .{
                .realized_atoms = self.realizedPnl(),
                .unrealized_atoms = self.unrealizedPnl(),
            },
            .ledger = .{
                .transaction_count = self.economic_projection.ledger_summary.transaction_count,
                .portfolio_transfer_count = self.economic_projection.ledger_summary.portfolio_transfer_count,
                .portfolio_debits_atoms = self.economic_projection.ledger_summary.portfolio_debits_atoms,
                .portfolio_credits_atoms = self.economic_projection.ledger_summary.portfolio_credits_atoms,
                .exchange_debits_atoms = self.economic_projection.ledger_summary.exchange_debits_atoms,
                .exchange_credits_atoms = self.economic_projection.ledger_summary.exchange_credits_atoms,
                .projections_complete = self.economic_projection.ledger_summary.projections_complete,
            },
            .projection_digest = self.economic_projection.digest(),
            .de_risk_target_position = self.operational_state.target_position,
        };
    }

    fn assertLifecycleEconomicsPreserved(self: *const TradingShard, preserved: LifecycleEconomics) !void {
        const current = self.captureLifecycleEconomics();
        if (!std.meta.eql(preserved, current))
            return error.KeepPositionsEconomicsChanged;
    }

    fn recalculateRisk(self: *TradingShard, fail_if_exceeded: bool) !void {
        // These compatibility summary fields are derived from the two
        // authoritative owners.  OMS owns all open-order reservations and the
        // economic projection owns position margin; never recompute either
        // from the legacy single-order scalars.
        const used = try std.math.add(
            i128,
            self.economic_projection.portfolio.margin_atoms,
            try self.activeReservationAtoms(),
        );
        const remaining = try std.math.sub(i128, self.risk_lease_atoms, used);
        if (fail_if_exceeded and remaining < 0) return error.RiskLeaseExceeded;
    }

    pub fn assertClosures(self: *const TradingShard) !void {
        const portfolio_position = self.portfolioPosition();
        const exchange_position = self.exchangePosition();
        if (portfolio_position.quantity != exchange_position.quantity or
            portfolio_position.open_cost_atoms != exchange_position.open_cost_atoms)
            return error.PositionLayerMismatch;
        if (try std.math.add(
            i128,
            self.portfolioCash(),
            try std.math.add(i128, self.treasuryCash(), self.economic_projection.suspense_usdt_atoms),
        ) != self.exchangeCash())
            return error.CashLayerMismatch;
        if (self.portfolioFee() != self.exchangeFee() or
            self.totalFees() != self.portfolioFee())
            return error.FeeLayerMismatch;
        const ledger = self.economic_projection.ledger_summary;
        if (ledger.portfolio_debits_atoms != ledger.portfolio_credits_atoms or
            ledger.exchange_debits_atoms != ledger.exchange_credits_atoms)
            return error.LedgerPostingsDoNotClose;
        if (try std.math.add(i128, try self.riskLeaseRemainingAtoms(), try std.math.add(
            i128,
            try self.activeReservationAtoms(),
            self.economic_projection.portfolio.margin_atoms,
        )) != self.risk_lease_atoms)
            return error.RiskLeaseDoesNotClose;
    }

    fn totalEconomicFactCount(self: *const TradingShard) !u64 {
        if (self.economic_projection.seen_count > self.economic_projection.seen.len) return error.InvalidEconomicFact;
        var count = try std.math.add(u64, try std.math.add(u64, self.economic_projection.archived_fill_count, self.economic_projection.archived_funding_count), self.economic_projection.archived_forced_count);
        for (self.economic_projection.seen[0..self.economic_projection.seen_count]) |known| {
            if (known.kind == .fill or known.kind == .funding or known.kind == .forced_execution) count = try std.math.add(u64, count, 1);
        }
        return count;
    }

    fn openEconomicFactsDigest(self: *const TradingShard) history.Digest {
        var hasher = Sha256.init(.{});
        hasher.update("OpenEconomicFactsV1\x00");
        digestInt(&hasher, u64, self.open_economic_fact_count);
        digestInt(&hasher, u64, self.open_economic_min_utc_ns);
        digestInt(&hasher, u64, self.open_economic_max_utc_ns);
        digestInt(&hasher, u64, self.open_economic_unknown_time_count);
        digestBare(&hasher, self.reconciliation_cursor);
        for (self.open_economic_facts[0..@min(self.open_economic_fact_count, self.open_economic_facts.len)]) |fact| digestBare(&hasher, fact);
        var result: history.Digest = undefined;
        hasher.final(&result);
        return result;
    }

    fn commitOpenEconomicFacts(self: *TradingShard) !void {
        // This derived fact belongs to the same authoritative input group.
        // Journal replay derives them again; checkpoint pinning preserves their
        // independently authenticated commitment after the original group retires.
        const digest = self.openEconomicFactsDigest();
        self.open_economic_commitment_sequence = try std.math.add(u64, self.authoritativeBarrier(), 1);
        try self.trace.appendEconomicCommitment(self.open_economic_fact_count, digest);
    }

    fn admitEconomicTime(self: *const TradingShard, economic_time: ?u64) !void {
        if (self.pending_reconciliation_window != null and self.reconciliation_cursor != null) return error.ReconciliationWindowPending;
        if (self.reconciliation_cursor) |cursor| {
            const time = economic_time orelse return error.UnresolvedSettlementBoundary;
            if (time == 0 or time <= cursor.through_utc_ns) return error.LateEconomicFact;
        }
    }

    fn rememberEconomicTime(self: *TradingShard, identity: u64, kind: @FieldType(canonical.EconomicFactRef, "kind"), payload_digest: history.Digest, economic_time: ?u64) !void {
        // A new economic fact invalidates an uncommitted first window. Later
        // windows reject it at admission until their cursor commits.
        self.pending_reconciliation_window = null;
        if (self.open_economic_fact_count < self.open_economic_facts.len) {
            self.open_economic_facts[@intCast(self.open_economic_fact_count)] = .{ .identity = identity, .kind = kind, .digest = payload_digest, .economic_time_utc_ns = economic_time };
        }
        self.open_economic_fact_count = try std.math.add(u64, self.open_economic_fact_count, 1);
        const time = economic_time orelse 0;
        if (time == 0) {
            self.open_economic_unknown_time_count = try std.math.add(u64, self.open_economic_unknown_time_count, 1);
        } else {
            if (self.open_economic_min_utc_ns == 0 or time < self.open_economic_min_utc_ns) self.open_economic_min_utc_ns = time;
            self.open_economic_max_utc_ns = @max(self.open_economic_max_utc_ns, time);
        }
    }

    fn reconciliationAnchorMatches(self: *const TradingShard, evidence: canonical.AccountEconomicEvidence) bool {
        if (evidence.before_balance_count > evidence.before_balances.len or evidence.balance_count > evidence.balances.len or evidence.before_balance_count != evidence.balance_count) return false;
        if (self.economic_baseline_balance_count > self.economic_baseline_balances.len) return false;
        if (self.reconciliation_cursor) |cursor| if (cursor.balance_count > cursor.balances.len) return false;
        const anchor = if (self.reconciliation_cursor) |*cursor| cursor.balances[0..cursor.balance_count] else self.economic_baseline_balances[0..self.economic_baseline_balance_count];
        if (self.reconciliation_cursor != null and evidence.before_balance_count != anchor.len) return false;
        for (anchor) |balance| {
            var found = false;
            for (evidence.before_balances[0..evidence.before_balance_count]) |before| if (before.asset == balance.asset and before.atoms == balance.atoms) {
                found = true;
            };
            if (!found) return false;
        }
        for (evidence.before_balances[0..evidence.before_balance_count], 0..) |before, index| {
            for (evidence.before_balances[0..index]) |known| if (known.asset == before.asset) return false;
            var found = false;
            for (anchor) |balance| if (balance.asset == before.asset) {
                found = true;
            };
            if (!found and before.atoms != 0) return false;
            found = false;
            for (evidence.balances[0..evidence.balance_count]) |after| if (after.asset == before.asset) {
                found = true;
            };
            if (!found) return false;
        }
        return true;
    }

    fn reconciliationClosingMatches(self: *const TradingShard, evidence: canonical.AccountEconomicEvidence) bool {
        if (evidence.balance_count == 0 or evidence.balance_count > evidence.balances.len) return false;
        if (self.economic_projection.exchange.native_asset_count > self.economic_projection.exchange.native_assets.len) return false;
        var settlement_found = false;
        for (evidence.balances[0..evidence.balance_count], 0..) |balance, index| {
            const definition = self.asset_registry.get(balance.asset) orelse return false;
            if (evidence.asset_versions[index] != definition.definition.version) return false;
            for (evidence.balances[0..index]) |known| if (known.asset == balance.asset) return false;
            const expected = if (balance.asset == self.economic_projection.settlement_asset) blk: {
                settlement_found = true;
                break :blk self.economic_projection.exchange.usdt_balance_atoms;
            } else if (self.economic_projection.exchange.nativeAsset(balance.asset)) |asset| asset.balance_atoms else 0;
            if (balance.atoms != expected) return false;
        }
        if (!settlement_found) return false;
        for (self.economic_projection.exchange.native_assets[0..self.economic_projection.exchange.native_asset_count]) |asset| {
            if (asset.balance_atoms == 0) continue;
            var found = false;
            for (evidence.balances[0..evidence.balance_count]) |balance| if (balance.asset == asset.asset) {
                found = true;
            };
            if (!found) return false;
        }
        return true;
    }

    fn unresolvedEconomicGate(self: *const TradingShard) bool {
        if (self.economic_fault_count != 0 or self.history_conflict_latched) return true;
        if (self.operational_state.latch_count > self.operational_state.latches.len) return true;
        for (self.operational_state.latches[0..self.operational_state.latch_count]) |latch| if (!latch.resolved and latch.reason == .reconciliation_break) return true;
        return false;
    }

    pub fn prepareForcedArchive(self: *const TradingShard, identity: u64, origin: history.Origin, evidence: *const @import("forced_archive_proof.zig").Evidence) !economics_module.ForcedArchiveQualification {
        if (origin.account != self.exchange_account_identity or origin.stream.id != (self.checkpoint orelse return error.OrderArchiveOriginUnavailable).stream or
            self.pending_history_candidate != null or self.pending_safety_history_candidate != null or self.deferred_history_admission_count != 0) return error.ForcedArchivePinned;
        const coordinator_origin = self.coordinator_history_origin orelse return error.ForcedArchivePinned;
        if (!std.meta.eql(coordinator_origin, evidence.proof.root.origin)) return error.InvalidForcedClosure;
        for (self.economic_projection.applied_forced_executions[0..self.economic_projection.applied_forced_execution_count]) |known| if (known.forced.identity == identity) {
            const closure = try @import("forced_archive_proof.zig").validate(evidence, known);
            return self.economic_projection.prepareForcedArchive(identity, origin, self.authoritativeBarrier(), closure);
        };
        return error.UnknownEconomicForcedExecution;
    }

    pub fn prepareFundingArchive(self: *const TradingShard, identity: u64, origin: history.Origin, barrier: u64) !economics_module.FundingArchiveQualification {
        if (self.unresolvedEconomicGate() or self.pending_history_candidate != null or self.pending_safety_history_candidate != null or self.deferred_history_admission_count != 0) return error.FundingArchivePinned;
        if (barrier != self.authoritativeBarrier() or origin.account != self.exchange_account_identity or
            origin.stream.domain != .decision_log or origin.stream.id != (self.checkpoint orelse return error.OrderArchiveOriginUnavailable).stream) return error.InvalidFundingArchiveOrigin;
        return self.economic_projection.prepareFundingArchive(identity, origin, barrier);
    }

    pub fn prepareReconciliationWindowArchive(self: *const TradingShard, identity: u128, origin: history.Origin, barrier: u64) !ReconciliationWindowArchiveQualification {
        const window = self.pending_reconciliation_window orelse return error.ReconciliationWindowUnavailable;
        const evidence = window.original.event.account_reconciliation_result.account_economics orelse return error.InvalidReconciliationWindow;
        if (!evidence.bills_complete or evidence.query_count == 0 or evidence.query_count > evidence.query_sources.len or
            evidence.before_source == null or evidence.before_balance_count != evidence.balance_count or
            std.mem.allEqual(u8, &evidence.bill_chain_digest, 0)) return error.ReconciliationWindowPinned;
        if (!window.original.event.account_reconciliation_result.complete or window.original.envelope.scope != .account or
            window.original.envelope.exchange_account != origin.account or evidence.exchange_account != origin.account or
            !std.meta.eql(evidence.source, window.original.envelope.raw_evidence) or
            evidence.from_utc_ns != (if (self.reconciliation_cursor) |cursor| cursor.through_utc_ns else self.economic_baseline_utc_ns) or
            evidence.through_utc_ns < evidence.from_utc_ns or window.original.envelope.times.source_utc_ns != evidence.through_utc_ns or
            !self.reconciliationAnchorMatches(evidence) or !self.reconciliationClosingMatches(evidence) or
            evidence.covered_economic_fact_count > evidence.facts.len) return error.ReconciliationWindowPinned;
        const before_source = evidence.before_source.?;
        if (before_source.stream != evidence.source.stream or before_source.sequence == 0 or before_source.sequence >= evidence.source.sequence or
            std.mem.allEqual(u8, &before_source.digest, 0) or std.mem.allEqual(u8, &evidence.source.digest, 0)) return error.ReconciliationWindowPinned;
        var query_sequence = before_source.sequence;
        for (evidence.query_sources[0..evidence.query_count]) |query| {
            if (query.stream != evidence.source.stream or query.sequence <= query_sequence or query.sequence >= evidence.source.sequence or std.mem.allEqual(u8, &query.digest, 0)) return error.ReconciliationWindowPinned;
            query_sequence = query.sequence;
        }
        for (evidence.facts[0..evidence.covered_economic_fact_count], 0..) |fact, index| {
            if (!fact.fee_confirmed) return error.ReconciliationWindowPinned;
            for (evidence.facts[0..index]) |known| if (known.identity == fact.identity and known.kind == fact.kind) return error.ReconciliationWindowPinned;
        }
        if (identity != window.identity or barrier != self.authoritativeBarrier() or origin.account != self.exchange_account_identity or
            origin.stream.domain != .decision_log or origin.stream.id != (self.checkpoint orelse return error.OrderArchiveOriginUnavailable).stream or
            self.pending_history_candidate != null or self.pending_safety_history_candidate != null or self.deferred_history_admission_count != 0 or
            self.economic_projection.reconciliation_break or self.economic_projection.suspense_usdt_atoms != 0 or self.economic_projection.suspense_native_asset_count != 0 or
            self.unresolvedEconomicGate() or
            !std.meta.eql(window.previous_cursor, self.reconciliation_cursor) or window.economic_fact_count != try self.totalEconomicFactCount() or
            self.open_economic_unknown_time_count != 0 or self.open_economic_max_utc_ns > evidence.through_utc_ns or
            (self.open_economic_min_utc_ns != 0 and self.open_economic_min_utc_ns <= evidence.from_utc_ns) or
            self.open_economic_fact_count != evidence.covered_economic_fact_count or
            (window.original.envelope.times.monotonic_ns orelse 0) == 0 or (window.original.envelope.times.receive_utc_ns orelse 0) == 0)
            return error.ReconciliationWindowPinned;
        if (self.open_economic_fact_count > self.open_economic_facts.len) return error.ReconciliationWindowPinned;
        for (self.open_economic_facts[0..@intCast(self.open_economic_fact_count)]) |known| {
            var matched = false;
            for (evidence.facts[0..evidence.covered_economic_fact_count]) |fact| if (fact.kind == known.kind and fact.identity == known.identity) {
                if (!std.mem.eql(u8, &fact.digest, &known.digest)) return error.ReconciliationWindowPinned;
                matched = true;
            };
            if (!matched) return error.ReconciliationWindowPinned;
        }
        for (self.economic_projection.seen[0..self.economic_projection.seen_count]) |known| if (known.kind == .forced_execution) return error.ReconciliationWindowPinned;
        return .{ .origin = origin, .barrier = barrier, .projection_digest = self.economic_projection.digest(), .window = window };
    }

    fn applyForcedProjection(self: *TradingShard, forced: economics_module.VenueForcedExecution, source: economics_module.ForcedSource) !bool {
        try self.checkAssetAmounts(.{ .venue_forced_execution = forced }, true);
        var retained = false;
        for (self.economic_projection.applied_forced_executions[0..self.economic_projection.applied_forced_execution_count]) |known|
            if (known.forced.identity == forced.identity) {
                retained = true;
            };
        const time = if (source.core_times) |times| if (times.presence.source) times.source else null else null;
        if (!retained) try self.admitEconomicTime(time);
        const changed = try self.economic_projection.applyForcedWithSource(forced, source);
        if (changed) {
            for (self.economic_projection.applied_forced_executions[0..self.economic_projection.applied_forced_execution_count]) |known| if (known.forced.identity == forced.identity) {
                try self.rememberEconomicTime(forced.identity, .forced, known.payload_digest, time);
                break;
            };
        }
        try self.checkEconomicRanges();
        return changed;
    }

    fn applyFundingProjection(self: *TradingShard, funding: economics_module.FundingSettlement, source: economics_module.FundingSource) !bool {
        try self.checkAssetAmounts(funding.amount, true);
        var retained = false;
        for (self.economic_projection.applied_fundings[0..self.economic_projection.applied_funding_count]) |known| {
            if (known.funding.identity == funding.identity) {
                retained = true;
                break;
            }
        }
        if (!retained) try self.admitEconomicTime(source.exchange_time_utc_ns);
        const changed = try self.economic_projection.applyFundingWithSource(funding, source);
        if (changed) {
            for (self.economic_projection.applied_fundings[0..self.economic_projection.applied_funding_count]) |known| if (known.funding.identity == funding.identity) {
                try self.rememberEconomicTime(funding.identity, .funding, known.payload_digest, source.exchange_time_utc_ns);
                break;
            };
        }
        try self.checkEconomicRanges();
        return changed;
    }

    fn applyEconomicProjection(self: *TradingShard, event: economics.Event) !bool {
        return self.applyEconomicProjectionWithSource(event, .{});
    }

    fn applyEconomicProjectionWithSource(self: *TradingShard, event: economics.Event, source: economics_module.FillSource) !bool {
        // Mark observations precede monetary configuration in virgin genesis.
        if (event == .mark_price and self.asset_registry.get(self.economic_projection.settlement_asset) == null)
            return self.economic_projection.applyChanged(event);
        try self.checkAssetAmounts(event, event != .account_snapshot);
        if (event == .fill) try self.checkNativeCharges(event.fill.native_fee, event.fill.native_rebate);
        switch (event) {
            .fill => |fill| if (fill.product == .spot) {
                try self.asset_registry.checkAmount(.{ .asset = fill.base_atom_value.asset, .atoms = try std.math.mul(i128, fill.quantity.lots, fill.base_atom_value.atoms) }, true);
            },
            .venue_forced_execution => |forced| if (forced.product == .spot) {
                const entry = self.instrumentEntry(forced.quantity.instrument) orelse return error.UnknownOmsInstrument;
                const unit = try self.baseAtomsPerLot(entry);
                try self.asset_registry.checkAmount(.{ .asset = unit.asset, .atoms = try std.math.mul(i128, forced.quantity.lots, unit.atoms) }, true);
            },
            else => {},
        }
        const changed = switch (event) {
            .fill => |fill| if (fill.order_id != 0) try self.economic_projection.applyCanonicalFillWithSource(fill, economics_module.coreFillDigest(fill), source) else try self.economic_projection.applyChanged(event),
            else => try self.economic_projection.applyChanged(event),
        };
        if (changed and event == .venue_forced_execution) self.pending_reconciliation_window = null;
        try self.checkEconomicRanges();
        return changed;
    }

    fn checkNativeCharges(self: *const TradingShard, fee: ?canonical.AssetAmount, rebate: ?canonical.AssetAmount) !void {
        for ([_]?canonical.AssetAmount{ fee, rebate }, 0..) |optional_amount, index| {
            const amount = optional_amount orelse continue;
            try self.asset_registry.checkAmount(amount, true);
            const definition = self.asset_registry.get(amount.asset) orelse return error.UnknownAssetDefinition;
            const current = self.economic_projection.portfolio.nativeAsset(amount.asset);
            const accrued = if (current) |entry| if (index == 0) entry.fee_atoms else entry.rebate_atoms else 0;
            if (try std.math.add(i128, accrued, amount.atoms) > definition.definition.max_cumulative_atoms)
                return error.AssetAmountOutOfRange;
        }
    }

    fn checkEconomicRanges(self: *const TradingShard) !void {
        const quote = self.asset_registry.get(self.economic_projection.settlement_asset) orelse return error.UnknownAssetDefinition;
        for (self.asset_registry.entries[0..self.asset_registry.count]) |base| {
            if (base.definition.asset == quote.definition.asset) continue;
            var traded_atoms: i128 = 0;
            for (self.economic_projection.ledger[0..self.economic_projection.ledger_count]) |transaction| {
                if (transaction.layer != .portfolio) continue;
                for (transaction.postings[0..transaction.posting_count]) |posting| {
                    if (posting.unit != .base_atoms or posting.account != .trade or posting.asset != base.definition.asset) continue;
                    const absolute = if (posting.amount < 0) try std.math.sub(i128, 0, posting.amount) else posting.amount;
                    traded_atoms = try std.math.add(i128, traded_atoms, absolute);
                }
            }
            if (traded_atoms > base.definition.max_cumulative_atoms) return error.AssetAmountOutOfRange;
        }
        if (self.economic_projection.cumulative_funding_absolute_atoms > quote.definition.max_cumulative_atoms) return error.AssetAmountOutOfRange;
        for ([_]i128{ self.economic_projection.treasury_usdt_atoms, self.economic_projection.suspense_usdt_atoms }) |amount|
            try self.asset_registry.checkAmount(.{ .asset = quote.definition.asset, .atoms = amount }, false);
        for (self.economic_projection.treasury_native_assets[0..self.economic_projection.treasury_native_asset_count]) |amount|
            try self.asset_registry.checkAmount(amount, false);
        for (self.economic_projection.suspense_native_assets[0..self.economic_projection.suspense_native_asset_count]) |amount|
            try self.asset_registry.checkAmount(amount, false);
        for ([_]economics_module.Layer{ self.economic_projection.portfolio, self.economic_projection.exchange }) |layer| {
            for (layer.native_assets[0..layer.native_asset_count]) |native| {
                const definition = self.asset_registry.get(native.asset) orelse return error.UnknownAssetDefinition;
                try self.asset_registry.checkAmount(.{ .asset = native.asset, .atoms = native.balance_atoms }, false);
                if (native.fee_atoms > definition.definition.max_cumulative_atoms or native.rebate_atoms > definition.definition.max_cumulative_atoms)
                    return error.AssetAmountOutOfRange;
            }
            for (layer.instrument_positions[0..layer.instrument_position_count]) |position| {
                if (position.product == .spot and position.base_asset != 0) {
                    const base = self.asset_registry.get(position.base_asset) orelse return error.UnknownAssetDefinition;
                    if (position.base_fee_atoms > base.definition.max_cumulative_atoms or position.base_rebate_atoms > base.definition.max_cumulative_atoms)
                        return error.AssetAmountOutOfRange;
                }
                for ([_]i128{ position.position.open_cost_atoms, position.margin_atoms }) |amount|
                    try self.asset_registry.checkAmount(.{ .asset = quote.definition.asset, .atoms = amount }, false);
            }
            for ([_]i128{ layer.usdt_balance_atoms, layer.margin_atoms }) |amount|
                try self.asset_registry.checkAmount(.{ .asset = quote.definition.asset, .atoms = amount }, false);
            for ([_]i128{ layer.fee_atoms, layer.rebate_atoms, layer.funding_atoms, layer.penalty_atoms, layer.realized_pnl_atoms, layer.unrealized_pnl_atoms, layer.spot.open_cost_atoms, layer.swap.open_cost_atoms }) |amount| {
                const limit = quote.definition.max_cumulative_atoms;
                if (amount > limit or amount < -limit) return error.AssetAmountOutOfRange;
            }
        }
    }

    fn latestFact(self: *const TradingShard, kind: EventKind) ?Fact {
        var latest: ?Fact = null;
        for (self.trace.pinned[0..self.trace.pinned_len]) |fact| if (fact.kind == kind) {
            latest = fact;
        };
        for (self.trace.events[0..self.trace.len]) |fact| if (fact.kind == kind) {
            latest = fact;
        };
        return latest;
    }

    fn controlCommandAtBarrier(self: *const TradingShard, barrier: u64) ?operational.ControlCommand {
        const fact = self.trace.factAt(barrier) orelse return null;
        if (fact.kind != .control_command_applied) return null;
        for (self.control_fact_sequences[0..self.operational_state.command_count], 0..) |sequence, index|
            if (sequence == barrier) return self.operational_state.command_history[index].command;
        return null;
    }

    fn dispatchAuthorityRefs(self: *const TradingShard, instrument: canonical.InstrumentIdentity, now_monotonic_ns: u64, deadline_barrier: u64) !oms_module.DispatchAuthorityRefs {
        try self.trace.validate();
        var refs: oms_module.DispatchAuthorityRefs = .{
            .exchange_account = self.exchange_account_identity,
            .virtual_portfolio = self.portfolio_identity,
            .deadline_barrier = deadline_barrier,
        };
        if (self.authority_control_barrier != 0) {
            const command = self.controlCommandAtBarrier(self.authority_control_barrier) orelse return error.InvalidControlAuthority;
            if (!changesTradingAuthorization(command.kind)) return error.InvalidControlAuthority;
            refs.trading_authorization = .{ .identity = command.command_identity, .version = std.math.add(u64, command.expected_version, 1) catch 0, .barrier = self.authority_control_barrier };
        }
        if (self.latestFact(.primary_lease_granted)) |fact|
            refs.primary_lease = .{ .identity = self.fencing_token, .version = self.fencing_token, .barrier = fact.sequence };
        if (self.latestFact(.risk_lease_granted)) |fact|
            refs.risk_lease = .{ .identity = self.risk_lease_identity, .version = self.risk_lease_version, .barrier = fact.sequence };
        if (self.latestFact(.strategy_activated)) |fact|
            refs.config = .{ .identity = self.strategy_activation_identity, .version = self.strategy_config_version, .barrier = fact.sequence };
        if (self.instrument_registry.get(instrument)) |entry| {
            if (entry.margin_barrier != 0) {
                const fact = self.trace.factAt(entry.margin_barrier) orelse return error.InvalidControlAuthority;
                refs.margin_rules = .{ .identity = fact.identity, .version = entry.margin.version, .barrier = entry.margin_barrier };
            }
            if (entry.trading_barrier != 0) {
                const fact = self.trace.factAt(entry.trading_barrier) orelse return error.InvalidControlAuthority;
                refs.instrument_trading = .{ .identity = fact.identity, .version = entry.trading_version, .barrier = entry.trading_barrier };
            }
            if (entry.rules_barrier != 0) {
                const fact = self.trace.factAt(entry.rules_barrier) orelse return error.InvalidControlAuthority;
                refs.instrument_rules = .{ .identity = fact.identity, .version = entry.rules.version, .barrier = entry.rules_barrier };
            }
            if (entry.capability) |profile| {
                const fact = self.trace.factAt(entry.capability_barrier) orelse return error.InvalidControlAuthority;
                refs.capability = .{ .identity = fact.identity, .version = profile.version, .barrier = entry.capability_barrier };
                refs.adapter_session = profile.adapter_session;
                if (now_monotonic_ns != 0)
                    refs.dispatch_deadline_monotonic_ns = std.math.add(u64, now_monotonic_ns, profile.max_dispatch_age_ns) catch 0;
            }
        }
        return refs;
    }

    /// Current source-owned versions for Gateway recheck; no deadline or send
    /// permission is reconstructed from a replayed shard.
    pub fn currentDispatchAuthorityRefs(self: *const TradingShard, instrument: canonical.InstrumentIdentity) !oms_module.DispatchAuthorityRefs {
        return self.dispatchAuthorityRefs(instrument, 0, 0);
    }

    /// Only a complete, healthy account observation can prove current net
    /// ExchangePosition; an absent row in that complete snapshot means flat.
    pub fn currentNetExchangePosition(self: *const TradingShard, instrument: canonical.InstrumentIdentity) ?canonical.InstrumentQuantity {
        if (!self.canonical_account.valid or self.canonical_account.exchange_account != self.exchange_account_identity)
            return null;
        const entry = self.instrument_registry.get(instrument) orelse return null;
        var result: canonical.InstrumentQuantity = .{ .instrument = instrument, .rules_version = entry.rules.version, .lots = 0 };
        if (entry.product == .spot and entry.rules.base_asset != 0) {
            var found_balance = false;
            for (self.canonical_account.balances[0..self.canonical_account.balance_count]) |balance| {
                if (balance.asset != entry.rules.base_asset) continue;
                if (found_balance or balance.total.asset != entry.rules.base_asset or balance.total.atoms < 0)
                    return null;
                const unit = self.baseAtomsPerLot(entry) catch return null;
                if (@rem(balance.total.atoms, unit.atoms) != 0) return null;
                result.lots = @divExact(balance.total.atoms, unit.atoms);
                found_balance = true;
            }
            return result;
        }
        var found = false;
        for (self.canonical_account.positions[0..self.canonical_account.position_count]) |position| {
            if (position.instrument != instrument) continue;
            if (found or position.side != .net or position.quantity.instrument != instrument or
                position.quantity.rules_version != entry.rules.version)
                return null;
            result = position.quantity;
            found = true;
        }
        return result;
    }

    /// Native holdings retain sublot residuals; they are never order quantities.
    pub fn currentSpotAssetBalance(self: *const TradingShard, instrument: canonical.InstrumentIdentity) ?canonical.AssetAmount {
        if (!self.canonical_account.valid or self.canonical_account.exchange_account != self.exchange_account_identity) return null;
        const entry = self.instrument_registry.get(instrument) orelse return null;
        if (entry.product != .spot or entry.rules.base_asset == 0) return null;
        var result: canonical.AssetAmount = .{ .asset = entry.rules.base_asset, .atoms = 0 };
        var found = false;
        for (self.canonical_account.balances[0..self.canonical_account.balance_count]) |balance| {
            if (balance.asset != result.asset) continue;
            if (found or balance.total.asset != result.asset or balance.total.atoms < 0) return null;
            self.asset_registry.checkAmount(balance.total, false) catch return null;
            result = balance.total;
            found = true;
        }
        return result;
    }

    fn bindFreshCancellations(self: *TradingShard, now_monotonic_ns: u64) !void {
        for (self.oms.emitted()) |command| {
            if (command.operation != .cancel) continue;
            const authority = try self.dispatchAuthorityRefs(command.instrument, now_monotonic_ns, self.authoritativeBarrier());
            try self.oms.bindCancellationAuthority(command.command_id, authority);
        }
    }

    fn rejectIntent(self: *TradingShard, kind: EventKind, sequence: u64, reason: RejectReason) !void {
        self.last_reject_reason = reason;
        try self.trace.appendRejection(kind, sequence, reason);
    }

    fn rejectSubmittedIntent(self: *TradingShard, group: oms_module.IntentGroup, kind: EventKind, reason: RejectReason) !void {
        self.oms.rememberRejectedGroup(group) catch |err| switch (err) {
            error.IdentitySetFull => {
                try self.rejectIntent(.strategy_intent_rejected, group.first_intent_sequence, .identity_capacity_exhausted);
                return;
            },
            else => return err,
        };
        try self.rejectIntent(kind, group.first_intent_sequence, reason);
    }

    fn hostIntentIdentityToken(intent: host_gateway.OrderIntent) canonical.ClientOrderId {
        var hash = Sha256.init(.{});
        var u64_bytes: [8]u8 = undefined;
        var u128_bytes: [16]u8 = undefined;
        std.mem.writeInt(u64, &u64_bytes, intent.strategy_cursor, .little);
        hash.update(&u64_bytes);
        std.mem.writeInt(u64, &u64_bytes, intent.config_version, .little);
        hash.update(&u64_bytes);
        for ([_]u128{ intent.activation_identity, intent.portfolio_identity, intent.exchange_account_identity }) |identity| {
            std.mem.writeInt(u128, &u128_bytes, identity, .little);
            hash.update(&u128_bytes);
        }
        var digest: [Sha256.digest_length]u8 = undefined;
        hash.final(&digest);
        return canonical.ClientOrderId.init(digest[0..16]) catch unreachable;
    }

    fn originalHostIntentGroup(intent: host_gateway.OrderIntent) oms.IntentGroup {
        var group: oms_module.IntentGroup = .{ .first_intent_sequence = intent.intent_sequence, .count = 1 };
        group.members[0] = .{
            .intent_sequence = intent.intent_sequence,
            .strategy_instance = intent.strategy_identity,
            .operation = .place,
            .instrument = intent.instrument_identity,
            .side = if (intent.side == .buy) .buy else .sell,
            .portfolio_reduce_only = intent.portfolio_reduce_only,
            .quantity = intent.quantity,
            .limit_price = .{
                .instrument = intent.instrument_identity,
                .rules_version = 0,
                .ticks = intent.limit_price_micros,
            },
            .order_type = .limit,
            .time_in_force = switch (intent.time_in_force) {
                .good_til_canceled => .good_til_canceled,
                .immediate_or_cancel => .immediate_or_cancel,
            },
        };
        group.members[0].client_order_id = hostIntentIdentityToken(intent);
        return group;
    }

    fn submitOrderIntent(self: *TradingShard, intent: host_gateway.OrderIntent, now_monotonic_ns: u64, cursor_floor: ?u64) !?OrderCommand {
        if (!self.genesisReady()) return error.GenesisIncomplete;
        var group: oms_module.IntentGroup = .{ .first_intent_sequence = intent.intent_sequence, .count = 1 };
        group.members[0] = .{
            .intent_sequence = intent.intent_sequence,
            .strategy_instance = intent.strategy_identity,
            .operation = .place,
            .instrument = intent.instrument_identity,
            .side = if (intent.side == .buy) .buy else .sell,
            .portfolio_reduce_only = intent.portfolio_reduce_only,
            .quantity = intent.quantity,
            .limit_price = .{
                .instrument = intent.instrument_identity,
                .rules_version = 0,
                .ticks = intent.limit_price_micros,
            },
            .order_type = .limit,
            .time_in_force = switch (intent.time_in_force) {
                .good_til_canceled => .good_til_canceled,
                .immediate_or_cancel => .immediate_or_cancel,
            },
        };
        var original_group = group;
        original_group.members[0].client_order_id = hostIntentIdentityToken(intent);
        switch (try self.oms.groupIdentityStatus(original_group)) {
            .duplicate => return null,
            .conflict => {
                try self.rejectIntent(.oms_intent_conflict, intent.intent_sequence, .intent_identity_conflict);
                return null;
            },
            .fresh => {},
        }
        if (cursor_floor) |floor| if (intent.strategy_cursor <= floor) {
            try self.rejectSubmittedIntent(original_group, .strategy_intent_rejected, .invalid_cursor);
            return null;
        };
        if (!self.strategy_active or self.host_activation_identity == 0 or
            intent.strategy_cursor <= self.host_activation_barrier or
            intent.strategy_cursor <= self.host_activation_fact_sequence)
        {
            try self.rejectSubmittedIntent(original_group, .strategy_intent_rejected, .host_not_activated);
            return null;
        }
        if (self.host_activation_identity != intent.activation_identity) {
            try self.rejectSubmittedIntent(original_group, .strategy_intent_rejected, .identity_mismatch);
            return null;
        }
        if (!self.operational_state.effectiveTradingAuthority()) {
            try self.rejectSubmittedIntent(original_group, .strategy_intent_rejected, .authorization_closed);
            return null;
        }
        if (intent.strategy_identity != self.strategy_identity or
            intent.config_version != self.strategy_config_version or
            intent.activation_identity != self.strategy_activation_identity or
            intent.portfolio_identity != self.portfolio_identity or
            intent.exchange_account_identity != self.exchange_account_identity or
            self.instrumentEntry(intent.instrument_identity) == null)
        {
            try self.rejectSubmittedIntent(original_group, .strategy_intent_rejected, .identity_mismatch);
            return null;
        }
        const instrument_config = self.instrumentEntry(intent.instrument_identity).?;
        group.members[0].limit_price.rules_version = instrument_config.rules.version;
        if (intent.order_type != .limit or
            (intent.time_in_force != .good_til_canceled and intent.time_in_force != .immediate_or_cancel) or
            intent.quantity <= 0 or intent.limit_price_micros <= 0)
        {
            try self.rejectSubmittedIntent(original_group, .strategy_intent_rejected, .unsupported_order_spec);
            return null;
        }
        for (self.oms.orders[0..self.oms.order_count]) |order| if (order.instrument == intent.instrument_identity) switch (order.state) {
            .pending_submit, .unknown, .live, .partially_filled, .pending_amend, .pending_cancel => {
                try self.rejectSubmittedIntent(original_group, .strategy_intent_rejected, .open_order);
                return null;
            },
            else => {},
        };
        group.members[0].limit_price.ticks = priceTicks(try self.abiPriceAtoms(intent.limit_price_micros, instrument_config.rules.settlement_asset), instrument_config.margin.price_tick_atoms) catch {
            try self.rejectSubmittedIntent(original_group, .strategy_intent_rejected, .unsupported_order_spec);
            return null;
        };
        try self.trace.append(.order_intent, intent.intent_sequence);

        const requested_notional = try notionalAtomsScaled(
            intent.quantity,
            try self.abiPriceAtoms(intent.limit_price_micros, instrument_config.rules.settlement_asset),
            instrument_config.rules.quantity_denominator,
            instrument_config.rules.quantity_numerator,
        );
        self.last_risk_tier = try riskTier(requested_notional, self.asset_registry.get(instrument_config.rules.settlement_asset).?.definition.atomic_scale);
        if ((self.canonical_market.get(intent.instrument_identity) orelse return error.MissingInstrumentDefinition).health != .healthy) {
            try self.rejectSubmittedIntent(original_group, .risk_rejected_market_data, .market_data_gap);
            return null;
        }
        const qualified = self.qualifyOmsGroup(group) catch |err| switch (err) {
            error.MarketDataGap,
            error.StrategyLimitExceeded,
            error.VirtualPortfolioLimitExceeded,
            error.DecisionDomainLimitExceeded,
            error.ExchangeAccountLimitExceeded,
            error.GlobalLimitExceeded,
            error.PortfolioOpeningGateClosed,
            error.ExchangeOpeningGateClosed,
            error.InsufficientSpotAsset,
            error.PortfolioReduceOnlyViolation,
            error.UnsupportedOrderSpec,
            error.CapabilityUnsupported,
            error.MarginSafetyGateClosed,
            error.TradingNotAuthorized,
            error.DeRiskTargetViolation,
            error.StrategyCutoverFenced,
            => {
                const reason: RejectReason = switch (err) {
                    error.MarketDataGap => .market_data_gap,
                    error.StrategyLimitExceeded => .strategy_limit_exceeded,
                    error.VirtualPortfolioLimitExceeded => .portfolio_limit_exceeded,
                    error.DecisionDomainLimitExceeded => .decision_domain_limit_exceeded,
                    error.ExchangeAccountLimitExceeded => .exchange_account_limit_exceeded,
                    error.GlobalLimitExceeded => .global_limit_exceeded,
                    error.PortfolioOpeningGateClosed => .portfolio_opening_gate_closed,
                    error.ExchangeOpeningGateClosed => .exchange_opening_gate_closed,
                    error.InsufficientSpotAsset => .insufficient_spot_asset,
                    error.PortfolioReduceOnlyViolation => .portfolio_reduce_only_violation,
                    error.UnsupportedOrderSpec => .unsupported_order_spec,
                    error.CapabilityUnsupported => .capability_unsupported,
                    error.MarginSafetyGateClosed => .margin_safety_gate_closed,
                    error.TradingNotAuthorized, error.DeRiskTargetViolation, error.StrategyCutoverFenced => .authorization_closed,
                    else => unreachable,
                };
                try self.rejectSubmittedIntent(original_group, if (err == error.UnsupportedOrderSpec or err == error.CapabilityUnsupported or
                    err == error.TradingNotAuthorized or err == error.DeRiskTargetViolation or err == error.StrategyCutoverFenced or
                    err == error.MarginSafetyGateClosed) .strategy_intent_rejected else .risk_rejected_lease, reason);
                return null;
            },
            else => return err,
        };
        self.last_risk_required_atoms = qualified.group.members[0].reservation.atoms;
        self.last_reject_reason = .none;
        try self.trace.append(.risk_accepted, intent.intent_sequence);
        const decision_barrier: u64 = self.authoritativeBarrier();
        try self.trace.append(.risk_reservation_created, intent.intent_sequence);
        const refs = [_]oms_module.RiskFactRefs{.{ .decision = decision_barrier, .reservation = self.authoritativeBarrier(), .authority = try self.dispatchAuthorityRefs(intent.instrument_identity, now_monotonic_ns, decision_barrier) }};
        try self.oms.applyQualifiedGroup(qualified.group, original_group, &refs);
        try self.adjustMarginBuffersForReservationChange(qualified.reservation_atoms);
        const oms_command = self.oms.emitted()[0];
        self.oms.command_count = 0; // Compatibility output below is the single sendable command.
        try self.recalculateRisk(true);
        try self.trace.append(.order_command, intent.intent_sequence);
        return oms_command;
    }

    fn handleCanonical(self: *TradingShard, record: canonical.EventRecord, verified_original: bool, coverage: ?VerifiedAccountCoverage) !?OrderCommand {
        if (record.envelope.event_type != @intFromEnum(canonical.eventType(record.event)))
            return error.CanonicalEventTypeMismatch;
        if (record.event == .account_bootstrap_snapshot or record.event == .account_observed) {
            const valid_scope = if (record.event == .account_bootstrap_snapshot)
                record.envelope.scope == .account
            else switch (record.envelope.scope) {
                .account => switch (record.event.account_observed.value) {
                    .balance => |value| record.envelope.asset == null or record.envelope.asset == value.asset,
                    .position => |value| record.envelope.instrument == null or record.envelope.instrument == value.instrument,
                    .margin => |value| record.envelope.instrument == null or record.envelope.instrument == value.instrument,
                },
                .asset => switch (record.event.account_observed.value) {
                    .balance => |value| record.envelope.asset == value.asset,
                    else => false,
                },
                .instrument => switch (record.event.account_observed.value) {
                    .position => |value| record.envelope.instrument == value.instrument,
                    .margin => |value| value.instrument != null and record.envelope.instrument == value.instrument,
                    else => false,
                },
                .venue => false,
            };
            if (!valid_scope) return error.CanonicalScopeMismatch;
            for (self.instrument_registry.entries[0..self.instrument_registry.count]) |configured|
                if (record.envelope.venue != configured.venue) return error.CanonicalScopeMismatch;
        }
        const observed_instrument: ?canonical.InstrumentIdentity = switch (record.event) {
            .instrument_definition_observed => |value| value.instrument,
            .l2_book_snapshot => |value| value.instrument,
            .l2_book_delta => |value| value.instrument,
            .reference_price => |value| value.instrument,
            .market_data_health_changed => |value| value.instrument,
            else => null,
        };
        if (observed_instrument) |identity| {
            if (record.envelope.instrument) |scoped| if (scoped != identity) return error.CanonicalScopeMismatch;
            if (record.envelope.exchange_account) |account| if (self.exchange_account_identity != 0 and account != self.exchange_account_identity) return error.CanonicalScopeMismatch;
            if (self.instrumentEntry(identity)) |configured| if (record.envelope.venue != configured.venue) return error.CanonicalScopeMismatch;
        }
        if (try self.rememberCanonicalIngress(record, verified_original)) {
            if (self.releaseDeferredHistoryAdmission(.{ .venue = record })) try self.trace.append(.canonical_history_admission_released, record.envelope.identity.sequence);
            return null;
        }
        const fact_identity = record.envelope.identity.sequence;
        switch (record.event) {
            .economic_fault => |fault| {
                if (record.envelope.scope != .account or record.envelope.exchange_account != self.exchange_account_identity)
                    return error.CanonicalScopeMismatch;
                try self.latchEconomicFault(record, fault.reason);
            },
            .funding_settlement => |settlement| {
                if (record.envelope.exchange_account != self.exchange_account_identity or
                    settlement.exchange_account != self.exchange_account_identity) return error.CanonicalScopeMismatch;
                const configured = self.instrumentEntry(settlement.instrument) orelse return error.UnknownOmsInstrument;
                if (record.envelope.scope != .account or record.envelope.venue != configured.venue or
                    record.envelope.instrument != settlement.instrument or record.envelope.asset != settlement.amount.asset)
                    return error.CanonicalScopeMismatch;
                if (configured.product != .isolated_linear_usdt or
                    settlement.rules_version != configured.rules.version or
                    settlement.amount.asset != configured.rules.settlement_asset or
                    settlement.venue_bill_id == 0 or settlement.settlement_time_utc_ns == 0) return error.InvalidEconomicFact;
                if (self.economic_baseline_utc_ns == 0 or settlement.settlement_time_utc_ns <= self.economic_baseline_utc_ns)
                    return error.UnresolvedSettlementBoundary;
                try self.checkAssetAmounts(settlement.amount, true);
                const identity = std.math.cast(u64, settlement.identity) orelse return error.IdentityOutOfRange;
                // A historical bill does not prove portfolio holdings at its settlement time.
                const changed = try self.applyFundingProjection(.{ .identity = identity, .amount = settlement.amount, .canonical_digest = try canonicalPayloadDigest(record.event) }, .{
                    .canonical_funding = settlement,
                    .canonical_envelope = record.envelope,
                    .audit_time_utc_ns = record.envelope.times.audit_utc_ns,
                    .exchange_account = self.exchange_account_identity,
                    .instrument = settlement.instrument,
                    .rules_version = settlement.rules_version,
                    .exchange_time_utc_ns = settlement.settlement_time_utc_ns,
                    .received_time_utc_ns = record.envelope.times.receive_utc_ns orelse 0,
                    .received_monotonic_ns = record.envelope.times.monotonic_ns orelse 0,
                });
                if (changed) {
                    try self.recalculateRisk(false);
                    if (self.economic_projection.reconciliation_break and self.operational_state.initialized) try self.applyOperationalGate(.{
                        .gate_identity = identity,
                        .target_identity = self.operational_state.target_identity,
                        .kind = .latched,
                        .reason = .reconciliation_break,
                        .open = false,
                    });
                    try self.trace.append(.funding_settlement, identity);
                }
            },
            .order_dispatch_result => |result| {
                const command_id = std.math.cast(u64, result.command) orelse return error.IdentityOutOfRange;
                var batch: oms_module.DispatchBatch = .{ .count = 1 };
                batch.items[0] = .{
                    .command_id = command_id,
                    .state = switch (result.state) {
                        .not_sent => .not_sent,
                        .submitted => .submitted,
                        .unknown => .unknown,
                    },
                };
                try self.oms.applyDispatch(batch);
                if (self.dispatch_ingress_history_count == self.dispatch_ingress_history.len) return error.DispatchIngressCapacity;
                self.dispatch_ingress_history[self.dispatch_ingress_history_count] = .{
                    .body = try self.dispatchIngressBody(record),
                    .cursor = .{ .identity = record.envelope.identity, .raw_digest = record.envelope.raw_evidence.digest, .payload_digest = try canonicalPayloadDigest(record.event) },
                };
                self.dispatch_ingress_history_count += 1;
                self.dispatch_attempt_count = try std.math.add(u64, self.dispatch_attempt_count, 1);
                switch (result.state) {
                    .not_sent => {
                        try self.recalculateRisk(false);
                        try self.trace.append(.order_not_sent, fact_identity);
                    },
                    .submitted => try self.trace.append(.order_dispatched, fact_identity),
                    .unknown => {
                        try self.trace.append(.order_dispatch_unknown, fact_identity);
                    },
                }
            },
            .execution_report => |report| try self.applyCanonicalReport(report, fact_identity, record.envelope.times.monotonic_ns orelse 0),
            .fill => |fill| try self.applyCanonicalFill(fill, fact_identity),
            .reconciliation_started => try self.trace.append(.canonical_reconciliation_started, fact_identity),
            .account_reconciliation_started => try self.trace.append(.canonical_account_reconciliation_started, fact_identity),
            .instrument_definition_observed => {
                try self.canonical_market.apply(record.event);
                const definition = record.event.instrument_definition_observed;
                if (self.instrument_registry.get(definition.instrument)) |entry|
                    if (definition.rules_version == entry.rules.version)
                        try self.canonical_market.activateRules(definition.instrument, definition.rules_version);
                try self.trace.append(.canonical_instrument_definition, fact_identity);
            },
            .l2_book_snapshot => |book_snapshot| {
                if (book_snapshot.depth) |depth| {
                    if (record.envelope.times.receive_utc_ns == null or depth.visible_at_ns != record.envelope.times.receive_utc_ns.?) {
                        try self.canonical_market.invalidateBook(book_snapshot.instrument);
                        return error.InvalidDepthTime;
                    }
                }
                if (book_snapshot.best_bid_quantity == null or book_snapshot.best_ask_quantity == null or
                    ((book_snapshot.next_ask == null) != (book_snapshot.next_ask_quantity == null)))
                {
                    try self.canonical_market.invalidateBook(book_snapshot.instrument);
                    return error.IncompleteL2Book;
                }
                try self.canonical_market.apply(record.event);
                if (book_snapshot.instrument == self.instrument_identity) {
                    self.expected_source_sequence = try std.math.add(u64, book_snapshot.sequence, 1);
                    self.market_health = .healthy;
                    self.bid_price_ticks = std.math.cast(i64, book_snapshot.best_bid.ticks) orelse return error.PriceOutOfRange;
                    self.ask_1_price_ticks = std.math.cast(i64, book_snapshot.best_ask.ticks) orelse return error.PriceOutOfRange;
                    self.bid_quantity = std.math.cast(i64, book_snapshot.best_bid_quantity.?.lots) orelse return error.QuantityOutOfRange;
                    self.ask_1_quantity = std.math.cast(i64, book_snapshot.best_ask_quantity.?.lots) orelse return error.QuantityOutOfRange;
                    self.ask_2_price_ticks = if (book_snapshot.next_ask) |price| std.math.cast(i64, price.ticks) orelse return error.PriceOutOfRange else self.ask_1_price_ticks;
                    self.ask_2_quantity = if (book_snapshot.next_ask_quantity) |quantity| std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange else 0;
                }
                try self.trace.append(.l2_snapshot, fact_identity);
            },
            .l2_book_delta => |delta| {
                if (delta.best_bid_quantity == null or delta.best_ask_quantity == null or
                    ((delta.next_ask == null) != (delta.next_ask_quantity == null)))
                    return error.IncompleteL2Book;
                self.canonical_market.apply(record.event) catch |err| switch (err) {
                    error.MissingBookSnapshot, error.MarketGap, error.ConflictingBookDelta, error.BookSequenceGap => {
                        if (delta.instrument == self.instrument_identity) self.market_health = .gap;
                        try self.trace.append(.l2_delta, fact_identity);
                        try self.trace.append(.market_gap, 1);
                        return null;
                    },
                    else => return err,
                };
                if (delta.instrument == self.instrument_identity) {
                    self.expected_source_sequence = try std.math.add(u64, delta.sequence, 1);
                    self.bid_price_ticks = std.math.cast(i64, delta.best_bid.ticks) orelse return error.PriceOutOfRange;
                    self.ask_1_price_ticks = std.math.cast(i64, delta.best_ask.ticks) orelse return error.PriceOutOfRange;
                    if (delta.best_bid_quantity) |quantity| self.bid_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
                    if (delta.best_ask_quantity) |quantity| self.ask_1_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
                    if (delta.next_ask) |price| self.ask_2_price_ticks = std.math.cast(i64, price.ticks) orelse return error.PriceOutOfRange;
                    if (delta.next_ask_quantity) |quantity| self.ask_2_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
                }
                try self.trace.append(.l2_delta, fact_identity);
                // A delta is valid only while the projection is already
                // healthy. It never proves recovery after a gap; only the
                // complete snapshot branch above can reopen the gate.
            },
            .reference_price => |price| {
                try self.canonical_market.apply(record.event);
                if (price.kind == .mark) {
                    const instrument = self.instrument_registry.get(price.instrument) orelse return error.UnknownInstrument;
                    const mark_price = try std.math.mul(i128, price.price.ticks, instrument.margin.price_tick_atoms);
                    if (price.instrument == self.instrument_identity) self.mark_price_atoms = mark_price;
                    _ = try self.applyEconomicProjection(.{ .mark_price = .{
                        .instrument = price.instrument,
                        .product = instrument.product,
                        .price_atoms = mark_price,
                        .quantity_denominator = instrument.rules.quantity_denominator,
                        .quantity_numerator = instrument.rules.quantity_numerator,
                    } });
                    try self.trace.append(.mark_price, fact_identity);
                } else try self.trace.append(.canonical_index_price, fact_identity);
            },
            .funding_rate_published => |funding| {
                self.last_funding_rate = funding;
                try self.trace.append(.canonical_funding_rate, fact_identity);
            },
            .market_data_health_changed => |health| {
                try self.canonical_market.apply(record.event);
                if (health.instrument == self.instrument_identity) self.market_health = switch (health.health) {
                    .healthy => .healthy,
                    .awaiting_snapshot => .initializing,
                    .gap => .gap,
                };
                try self.trace.append(if (health.health == .healthy) .market_healthy else .market_gap, fact_identity);
            },
            .account_bootstrap_snapshot => |bootstrap_snapshot| {
                for (bootstrap_snapshot.balances[0..bootstrap_snapshot.balance_count]) |balance| try self.checkAssetAmounts(balance, false);
                for (bootstrap_snapshot.positions[0..bootstrap_snapshot.position_count]) |position| try self.checkAssetAmounts(position, false);
                for (bootstrap_snapshot.margins[0..bootstrap_snapshot.margin_count]) |margin| try self.checkAssetAmounts(margin, false);
                if (record.envelope.scope != .account or bootstrap_snapshot.exchange_account != record.envelope.exchange_account or
                    (self.exchange_account_identity != 0 and bootstrap_snapshot.exchange_account != self.exchange_account_identity))
                    return error.CanonicalScopeMismatch;
                try self.canonical_account.apply(record.event);
                self.account_balance_utc_ns = record.envelope.times.source_utc_ns orelse 0;
                try self.trace.append(.canonical_account_bootstrap, fact_identity);
            },
            .account_observed => |observation| {
                try self.checkAssetAmounts(observation.value, false);
                if (observation.exchange_account != record.envelope.exchange_account or
                    (self.exchange_account_identity != 0 and observation.exchange_account != self.exchange_account_identity))
                    return error.CanonicalScopeMismatch;
                try self.canonical_account.apply(record.event);
                if (observation.value == .balance and observation.value.balance.asset == self.economic_projection.settlement_asset)
                    self.account_balance_utc_ns = record.envelope.times.source_utc_ns orelse 0;
                try self.trace.append(.canonical_account_observed, fact_identity);
            },
            .venue_account_configuration_snapshot => |configuration| {
                self.last_venue_configuration = configuration;
                try self.trace.append(.canonical_venue_configuration, fact_identity);
            },
            .order_reconciliation_result => |result| {
                var status = result.status;
                if ((status == .unresolved) == result.complete) status = .unresolved;
                if (status != .unresolved and !reconciliationEvidenceValid(result, record.envelope)) status = .unresolved;
                if (result.order != 0) process_order: {
                    const previous_reservation = try self.activeReservationAtoms();
                    const order_id = std.math.cast(u64, result.order) orelse {
                        status = .unresolved;
                        break :process_order;
                    };
                    if (result.evidence) |evidence| if (evidence.scope.order != result.order) {
                        status = .unresolved;
                        break :process_order;
                    };
                    const instrument = self.oms.instrumentForOrder(order_id) orelse {
                        status = .unresolved;
                        break :process_order;
                    };
                    if (result.evidence) |evidence| if (evidence.scope.instrument != instrument) {
                        status = .unresolved;
                        break :process_order;
                    };
                    const rules = self.instrumentEntry(instrument) orelse return error.UnknownOmsInstrument;
                    const order = self.oms.orderById(order_id) orelse {
                        status = .unresolved;
                        break :process_order;
                    };
                    var revision = order.revision;
                    var cumulative_lots = order.cumulative_quantity;
                    var remaining_lots = try std.math.sub(i64, order.quantity, order.cumulative_quantity);
                    if (status != .unresolved) {
                        if (result.rules_version != rules.rules.version or result.cumulative_quantity == null or result.remaining_quantity == null) {
                            status = .unresolved;
                        } else {
                            const cumulative = result.cumulative_quantity.?;
                            const remaining = result.remaining_quantity.?;
                            if (cumulative.instrument != instrument or remaining.instrument != instrument or
                                cumulative.rules_version != rules.rules.version or remaining.rules_version != rules.rules.version or
                                std.math.cast(i64, cumulative.lots) == null or std.math.cast(i64, remaining.lots) == null)
                                status = .unresolved
                            else {
                                revision = result.revision;
                                cumulative_lots = @intCast(cumulative.lots);
                                remaining_lots = @intCast(remaining.lots);
                            }
                        }
                    }
                    if (status == .found_terminal and (result.terminal_status == null or switch (result.terminal_status.?) {
                        .filled, .canceled, .rejected => false,
                        else => true,
                    })) status = .unresolved;
                    if (status != .found_terminal and result.terminal_status != null) status = .unresolved;
                    if (status == .found_terminal and result.terminal_status.? == .filled and
                        (cumulative_lots != order.quantity or remaining_lots != 0)) status = .unresolved;
                    if (status != .unresolved) {
                        const total = std.math.add(i64, cumulative_lots, remaining_lots) catch -1;
                        if (cumulative_lots < 0 or remaining_lots < 0 or total < 0 or total > order.quantity or
                            (status == .found_live and total != order.quantity) or
                            (status == .confirmed_absent and (cumulative_lots != 0 or remaining_lots != order.quantity)))
                            status = .unresolved;
                    }
                    if (status == .confirmed_absent and (!self.oms.canConfirmAbsentFromSession(order_id, result.revision, result.evidence.?.absence.?.prior_session) or
                        (try self.economic_projection.appliedCanonicalFillQuantity(order_id)) != 0))
                        status = .unresolved;
                    if (status == .unresolved) {
                        revision = order.revision;
                        cumulative_lots = order.cumulative_quantity;
                        remaining_lots = try std.math.sub(i64, order.quantity, order.cumulative_quantity);
                    }
                    try self.oms.applyReconciliation(.{
                        .reconciliation_id = std.math.cast(u64, result.identity) orelse return error.IdentityOutOfRange,
                        .order_id = order_id,
                        .status = switch (status) {
                            .found_live => .found_live,
                            .found_terminal => .found_terminal,
                            .confirmed_absent => .confirmed_absent,
                            .unresolved => .unresolved,
                        },
                        .revision = revision,
                        .cumulative_quantity = cumulative_lots,
                        .remaining_quantity = remaining_lots,
                        .terminal_state = if (status == .found_terminal) if (result.terminal_status) |terminal| switch (terminal) {
                            .filled => .filled,
                            .canceled => .canceled,
                            .rejected => .rejected,
                            else => unreachable,
                        } else null else null,
                        .canonical_digest = try canonicalPayloadDigest(record.event),
                    });
                    if (status == .found_terminal) {
                        const reconciled_order = self.oms.orderById(order_id).?;
                        if (reconciled_order.created_at_utc_ns != 0)
                            try self.oms.noteTerminalObserved(order_id, record.envelope.times.receive_utc_ns orelse return error.InvalidOrderArchiveTime);
                        if (result.evidence.?.terminal_archive != null)
                            try self.oms.retainTerminalArchiveCoverage(order_id, result.evidence.?);
                    }
                    const reflected_reservation = (try self.confirmPendingReplacement(order_id, std.math.cast(u64, result.identity) orelse return error.IdentityOutOfRange, record.envelope.times.monotonic_ns orelse 0)) orelse previous_reservation;
                    try self.adjustMarginBuffersForReservationChange(reflected_reservation);
                } else status = .unresolved;
                if (status == .unresolved and self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = result.identity,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .latched,
                    .reason = .reconciliation_break,
                    .open = false,
                });
                try self.trace.append(.canonical_order_reconciliation, fact_identity);
            },
            .account_reconciliation_result => |result| {
                if (result.account_economics) |evidence| {
                    try self.applyNativeReconciliation(record, result, evidence, coverage);
                }
                if ((!result.complete or (result.account_economics == null and self.opening_balance_observed)) and self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = result.identity,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .latched,
                    .reason = .reconciliation_break,
                    .open = false,
                });
                try self.trace.append(.canonical_account_reconciliation, fact_identity);
            },
        }
        return null;
    }

    fn applyNativeReconciliation(self: *TradingShard, record: canonical.EventRecord, result: canonical.ReconciliationResult, evidence: canonical.AccountEconomicEvidence, coverage: ?VerifiedAccountCoverage) !void {
        if (coverage) |verified| {
            const root = self.business_history_root orelse return error.InvalidHistoryCandidate;
            if (!std.mem.eql(u8, &verified.root_digest, &root.root_digest) or
                !std.mem.eql(u8, &verified.input_digest, &try accountCoverageInputDigest(record))) return error.InvalidHistoryCandidate;
        }
        if (record.envelope.scope != .account or record.envelope.exchange_account != self.exchange_account_identity or
            evidence.exchange_account != self.exchange_account_identity or !std.meta.eql(evidence.source, record.envelope.raw_evidence))
            return error.CanonicalScopeMismatch;
        for (self.instrument_registry.entries[0..self.instrument_registry.count]) |entry|
            if (entry.venue != record.envelope.venue) return error.CanonicalScopeMismatch;
        if (!result.complete or !self.opening_balance_observed or self.economic_baseline_utc_ns == 0 or
            evidence.from_utc_ns != (if (self.reconciliation_cursor) |cursor| cursor.through_utc_ns else self.economic_baseline_utc_ns) or evidence.through_utc_ns < evidence.from_utc_ns or
            record.envelope.times.source_utc_ns != evidence.through_utc_ns)
        {
            _ = try self.economic_projection.retainCanonicalSnapshot(std.math.cast(u64, result.identity) orelse return error.IdentityOutOfRange, try canonicalPayloadDigest(record.event));
            try self.latchEconomicFault(record, .invalid_economic_fact);
            return;
        }
        if (evidence.balance_count == 0 or evidence.balance_count > evidence.balances.len or evidence.before_balance_count > evidence.before_balances.len) return error.IncompleteReconciliationEvidence;
        if (self.reconciliation_cursor != null) {
            if (self.open_economic_fact_count != evidence.covered_economic_fact_count or self.open_economic_fact_count > self.open_economic_facts.len or
                self.open_economic_unknown_time_count != 0 or self.open_economic_max_utc_ns > evidence.through_utc_ns or
                (self.open_economic_min_utc_ns != 0 and self.open_economic_min_utc_ns <= evidence.from_utc_ns)) return error.IncompleteReconciliationEvidence;
            for (self.open_economic_facts[0..@intCast(self.open_economic_fact_count)]) |known| {
                var matched = false;
                for (evidence.facts[0..evidence.covered_economic_fact_count]) |fact| if (fact.identity == known.identity and fact.kind == known.kind) {
                    if (!std.mem.eql(u8, &fact.digest, &known.digest)) return error.IncompleteReconciliationEvidence;
                    matched = true;
                };
                if (!matched) return error.IncompleteReconciliationEvidence;
            }
        }

        if (evidence.through_utc_ns > evidence.from_utc_ns and !self.reconciliationAnchorMatches(evidence)) return error.IncompleteReconciliationEvidence;
        var facts_match = true;
        if (evidence.through_utc_ns == evidence.from_utc_ns) {
            if (evidence.covered_economic_fact_count != 0 or (try self.totalEconomicFactCount()) != (if (self.reconciliation_cursor) |cursor| cursor.closed_economic_fact_count else 0)) {
                _ = try self.economic_projection.retainCanonicalSnapshot(std.math.cast(u64, result.identity) orelse return error.IdentityOutOfRange, try canonicalPayloadDigest(record.event));
                try self.latchEconomicFault(record, .invalid_economic_fact);
                return;
            }
        } else {
            const before = evidence.before_source orelse return error.IncompleteReconciliationEvidence;
            if (!evidence.bills_complete or
                evidence.covered_economic_fact_count > evidence.facts.len or evidence.query_count == 0 or
                evidence.query_count > evidence.query_sources.len or evidence.before_balance_count != evidence.balance_count or
                before.stream != evidence.source.stream or before.sequence == 0 or before.sequence >= evidence.source.sequence or
                std.mem.eql(u8, &evidence.bill_chain_digest, &@as([32]u8, @splat(0)))) return error.IncompleteReconciliationEvidence;
            var previous = before.sequence;
            for (evidence.query_sources[0..evidence.query_count]) |query| {
                if (query.stream != evidence.source.stream or query.sequence <= previous or query.sequence >= evidence.source.sequence or
                    std.mem.eql(u8, &query.digest, &@as([32]u8, @splat(0)))) return error.IncompleteReconciliationEvidence;
                previous = query.sequence;
            }
            const money_facts = try std.math.sub(u64, try self.totalEconomicFactCount(), if (self.reconciliation_cursor) |cursor| cursor.closed_economic_fact_count else 0);
            for (self.economic_projection.seen[0..self.economic_projection.seen_count]) |known| if (known.kind == .forced_execution) return error.IncompleteReconciliationEvidence;
            if (money_facts != evidence.covered_economic_fact_count) return error.IncompleteReconciliationEvidence;
            for (evidence.facts[0..evidence.covered_economic_fact_count], 0..) |fact, index| {
                if (self.reconciliation_cursor != null) switch (fact.kind) {
                    .fill => for (self.economic_projection.applied_fills[0..self.economic_projection.applied_fill_count]) |known| {
                        if (known.fill.identity != fact.identity) continue;
                        const time = if (known.source.canonical_fill) |original| original.venue_fill_time_utc_ns else null;
                        if (time) |utc| {
                            if (utc <= evidence.from_utc_ns or utc > evidence.through_utc_ns) return error.IncompleteReconciliationEvidence;
                        }
                    },
                    .forced => for (self.economic_projection.applied_forced_executions[0..self.economic_projection.applied_forced_execution_count]) |known| {
                        if (known.forced.identity == fact.identity) return error.IncompleteReconciliationEvidence;
                    },
                    .funding => for (self.economic_projection.applied_fundings[0..self.economic_projection.applied_funding_count]) |known| {
                        if (known.funding.identity != fact.identity) continue;
                        const utc = known.source.exchange_time_utc_ns orelse return error.IncompleteReconciliationEvidence;
                        if (utc <= evidence.from_utc_ns or utc > evidence.through_utc_ns) return error.IncompleteReconciliationEvidence;
                    },
                };
                for (evidence.facts[0..index]) |known| if (known.identity == fact.identity and known.kind == fact.kind) return error.IncompleteReconciliationEvidence;
                const applied = switch (fact.kind) {
                    // The private capability exists only after every cold reference in this exact input proves same.
                    .fill => (try self.economic_projection.lookupCanonicalFill(fact.identity, fact.digest)) == .duplicate or coverage != null,
                    .forced => coverage != null,
                    .funding => blk: {
                        var matched = false;
                        for (self.economic_projection.applied_fundings[0..self.economic_projection.applied_funding_count]) |known| {
                            if (known.funding.identity != fact.identity) continue;
                            if (!std.mem.eql(u8, &known.payload_digest, &fact.digest)) return error.ConflictingEconomicIdentity;
                            matched = true;
                        }
                        break :blk matched or coverage != null;
                    },
                };
                if (!applied) return error.IncompleteReconciliationEvidence;
                facts_match = facts_match and fact.fee_confirmed;
            }
            for (evidence.before_balances[0..evidence.before_balance_count]) |balance| {
                try self.checkAssetAmounts(balance, false);
                var found = false;
                for (evidence.balances[0..evidence.balance_count]) |closing| if (balance.asset == closing.asset) {
                    found = true;
                };
                if (!found) return error.IncompleteReconciliationEvidence;
            }
        }
        if (evidence.balance_count == 0 or evidence.balance_count > evidence.balances.len) return error.IncompleteReconciliationEvidence;
        for (evidence.balances[0..evidence.balance_count], evidence.asset_versions[0..evidence.balance_count]) |balance, version| {
            const definition = self.asset_registry.get(balance.asset) orelse return error.UnknownAssetDefinition;
            if (version != definition.definition.version) return error.IncompleteReconciliationEvidence;
            try self.checkAssetAmounts(balance, false);
        }
        const identity = std.math.cast(u64, result.identity) orelse return error.IdentityOutOfRange;
        _ = try self.economic_projection.reconcileNative(identity, evidence.balances[0..evidence.balance_count], try canonicalPayloadDigest(record.event), facts_match);
        if (!self.economic_projection.reconciliation_break and evidence.bills_complete and evidence.before_source != null and evidence.query_count != 0) {
            if (self.reconciliation_cursor != null and self.pending_reconciliation_window != null) return error.ReconciliationWindowPending;
            self.pending_reconciliation_window = .{
                .identity = result.identity,
                .original = record,
                .previous_cursor = self.reconciliation_cursor,
                .economic_fact_count = try self.totalEconomicFactCount(),
                .projection_digest = self.economic_projection.digest(),
            };
        }
        if (self.economic_projection.reconciliation_break and self.operational_state.initialized) try self.applyOperationalGate(.{
            .gate_identity = identity,
            .target_identity = self.operational_state.target_identity,
            .kind = .latched,
            .reason = .reconciliation_break,
            .open = false,
        });
    }

    fn latchEconomicFault(self: *TradingShard, record: canonical.EventRecord, reason: canonical.EconomicFaultReason) !void {
        self.economic_fault_count = try std.math.add(u64, self.economic_fault_count, 1);
        self.economic_fault_reason = reason;
        self.economic_fault_evidence = record.envelope.raw_evidence;
        self.oms.recovery_only = true;
        if (self.operational_state.initialized) self.applyOperationalGate(.{
            .gate_identity = account_data_gate_identity,
            .target_identity = self.operational_state.target_identity,
            .kind = .latched,
            .reason = .reconciliation_break,
            .open = false,
        }) catch |err| switch (err) {
            // Keep the original monetary fault even when no gate slot remains.
            error.SafetyGateSetFull => self.operational_state.trading_authorized = false,
            else => return err,
        };
        try self.trace.append(.canonical_account_invalidated, record.envelope.identity.sequence);
    }

    fn rememberCanonicalIngress(self: *TradingShard, record: canonical.EventRecord, verified_original: bool) !bool {
        const event_type = canonical.eventType(record.event);
        const payload_digest = try canonicalPayloadDigest(record.event);
        for (self.deferred_history_admissions[0..self.deferred_history_admission_count]) |admission| {
            if (std.meta.eql(admission.identity, record.envelope.identity) and
                (admission.event_type != record.envelope.event_type or !std.mem.eql(u8, &admission.raw_digest, &record.envelope.raw_evidence.digest) or
                    !std.mem.eql(u8, &admission.payload_digest, &payload_digest))) return error.ConflictingCanonicalIdentity;
        }
        var cursor_index: ?usize = null;
        for (self.canonical_ingress_cursors[0..self.canonical_ingress_cursor_count], 0..) |known, index| {
            if (known.identity.stream != record.envelope.identity.stream) continue;
            if (record.envelope.identity.sequence == known.identity.sequence) {
                if (known.event_type != event_type or
                    !std.mem.eql(u8, &known.raw_digest, &record.envelope.raw_evidence.digest) or
                    !std.mem.eql(u8, &known.payload_digest, &payload_digest))
                {
                    const account = if (self.exchange_account_identity != 0) self.exchange_account_identity else self.canonical_account.exchange_account orelse 0;
                    if (record.envelope.exchange_account == account and
                        (record.event == .account_observed or record.event == .account_bootstrap_snapshot))
                        try self.canonical_account.rejectIdentityConflict();
                    return error.ConflictingCanonicalIdentity;
                }
                return true;
            }
            cursor_index = index;
            break;
        }
        if (try self.semanticDuplicate(record)) return true;
        if (!verified_original) if (cursor_index) |index|
            if (record.envelope.identity.sequence < self.canonical_ingress_cursors[index].identity.sequence)
                return error.StaleCanonicalIdentity;
        const target_index = cursor_index orelse blk: {
            if (ingressAdmissionFull(self.canonical_ingress_cursor_count, self.canonical_ingress_cursors.len))
                return error.CanonicalStreamSetFull;
            const index = self.canonical_ingress_cursor_count;
            self.canonical_ingress_cursor_count += 1;
            break :blk index;
        };
        var hasher = Sha256.init(.{});
        hasher.update("CanonicalIngressV1\x00");
        hasher.update(&self.canonical_ingress_digest);
        var encoded: [@sizeOf(u128)]u8 = undefined;
        std.mem.writeInt(u128, &encoded, record.envelope.source_fact_identity, .little);
        hasher.update(&encoded);
        var stream: [@sizeOf(u128)]u8 = undefined;
        std.mem.writeInt(u128, &stream, record.envelope.identity.stream, .little);
        hasher.update(&stream);
        var sequence: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &sequence, record.envelope.identity.sequence, .little);
        hasher.update(&sequence);
        var kind: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &kind, @intFromEnum(event_type), .little);
        hasher.update(&kind);
        hasher.update(&record.envelope.raw_evidence.digest);
        hasher.update(&payload_digest);
        hasher.final(&self.canonical_ingress_digest);
        self.canonical_ingress_count = try std.math.add(u64, self.canonical_ingress_count, 1);
        // A proof may resolve behind later safety facts without lowering the source cursor.
        if (cursor_index == null or record.envelope.identity.sequence > self.canonical_ingress_cursors[target_index].identity.sequence)
            self.canonical_ingress_cursors[target_index] = .{
                .identity = record.envelope.identity,
                .event_type = event_type,
                .raw_digest = record.envelope.raw_evidence.digest,
                .payload_digest = payload_digest,
            };
        return false;
    }

    fn dispatchIngressBody(self: *const TradingShard, record: canonical.EventRecord) !DispatchIngressBody {
        if (record.event != .order_dispatch_result or record.envelope.schema_version != canonical.schema_version or
            record.envelope.exchange_account != self.exchange_account_identity or record.envelope.scope != .account)
            return error.CanonicalScopeMismatch;
        const command_id = std.math.cast(u64, record.event.order_dispatch_result.command) orelse return error.IdentityOutOfRange;
        var venue_configured = false;
        for (self.instrument_registry.entries[0..self.instrument_registry.count]) |entry|
            if (entry.venue == record.envelope.venue) {
                venue_configured = true;
                break;
            };
        if (!venue_configured) return error.CanonicalScopeMismatch;
        for (self.oms.command_history[0..self.oms.command_history_count]) |command|
            if (command.command_id == command_id) {
                try self.validateHistoryEnvelope(record, command.instrument);
                break;
            };
        return .{ .command = command_id, .state = record.event.order_dispatch_result.state, .venue = record.envelope.venue, .account = self.exchange_account_identity, .canonical_digest = try canonicalPayloadDigest(record.event) };
    }

    fn semanticDuplicate(self: *TradingShard, record: canonical.EventRecord) !bool {
        const account = if (self.exchange_account_identity != 0) self.exchange_account_identity else self.canonical_account.exchange_account orelse record.envelope.exchange_account;
        return switch (record.event) {
            .order_dispatch_result => |result| blk: {
                const body = try self.dispatchIngressBody(record);
                for (self.dispatch_ingress_history[0..self.dispatch_ingress_history_count]) |known| {
                    if (std.meta.eql(known.cursor.identity, record.envelope.identity) and
                        (!std.mem.eql(u8, &known.cursor.raw_digest, &record.envelope.raw_evidence.digest) or
                            !std.mem.eql(u8, &known.cursor.payload_digest, &body.canonical_digest))) return error.ConflictingCanonicalIdentity;
                }
                for (self.dispatch_ingress_history[0..self.dispatch_ingress_history_count]) |known| {
                    if (known.body.command == result.command and known.body.state == result.state) {
                        if (!std.meta.eql(known.body, body)) return error.ConflictingCanonicalIdentity;
                        break :blk true;
                    }
                }
                break :blk false;
            },
            .account_reconciliation_result => |result| blk: {
                if (result.account_economics == null) break :blk false;
                if (record.envelope.exchange_account != account or result.account_economics.?.exchange_account != account)
                    return error.CanonicalScopeMismatch;
                const identity = std.math.cast(u64, result.identity) orelse return error.IdentityOutOfRange;
                break :blk try self.economic_projection.lookupCanonicalFact(identity, .account_snapshot, try canonicalPayloadDigest(record.event));
            },
            .funding_settlement => |settlement| blk: {
                if (record.envelope.exchange_account != account or settlement.exchange_account != account)
                    return error.CanonicalScopeMismatch;
                const identity = std.math.cast(u64, settlement.identity) orelse return error.IdentityOutOfRange;
                break :blk try self.economic_projection.lookupCanonicalFunding(identity, try canonicalPayloadDigest(record.event));
            },
            .account_observed => |observation| blk: {
                if (record.envelope.exchange_account != account or
                    observation.exchange_account != account) return error.CanonicalScopeMismatch;
                break :blk try self.canonical_account.lookupObservation(observation);
            },
            .account_bootstrap_snapshot => |bootstrap_snapshot| blk: {
                if (record.envelope.exchange_account != account or
                    bootstrap_snapshot.exchange_account != account) return error.CanonicalScopeMismatch;
                if (self.canonical_account.bootstrap != bootstrap_snapshot.identity) break :blk false;
                try self.canonical_account.apply(record.event);
                break :blk true;
            },
            .execution_report => |report| blk: {
                const oms_report = self.omsReportFromCanonical(report) catch break :blk false;
                const known = self.oms.lookupReport(oms_report) catch |err| switch (err) {
                    error.ConflictingReportIdentity => return err,
                };
                break :blk known == .duplicate;
            },
            .fill => |fill| blk: {
                const fill_id = std.math.cast(u64, fill.identity) orelse return error.IdentityOutOfRange;
                const known = self.economic_projection.lookupCanonicalFill(fill_id, try canonicalPayloadDigest(.{ .fill = fill })) catch |err| switch (err) {
                    error.ConflictingEconomicIdentity => return error.ConflictingFillIdentity,
                };
                break :blk known == .duplicate;
            },
            else => false,
        };
    }

    fn reconciliationEvidenceValid(result: canonical.ReconciliationResult, envelope: canonical.EventEnvelope) bool {
        const evidence = result.evidence orelse return false;
        const scope = evidence.scope;
        if (result.identity == 0 or scope.exchange_account == 0 or scope.exchange_account != envelope.exchange_account or
            scope.instrument == 0 or scope.order == 0 or scope.order != result.order or scope.revision == 0 or
            scope.revision != result.revision or scope.from_utc_ns == 0 or scope.from_utc_ns > scope.through_utc_ns or
            evidence.observed_at_utc_ns < scope.through_utc_ns or
            evidence.observed_at_utc_ns > (envelope.times.receive_utc_ns orelse return false) or
            evidence.source.stream == 0 or evidence.source.sequence == 0 or
            std.mem.eql(u8, &evidence.source.digest, &@as([32]u8, @splat(0)))) return false;
        if (result.status != .confirmed_absent) return evidence.absence == null;
        const absent = evidence.absence orelse return false;
        return absent.prior_session != 0 and absent.prior_session != (envelope.adapter_session orelse return false) and
            absent.prior_session_inactive and absent.visibility_deadline_utc_ns != 0 and
            scope.from_utc_ns <= absent.visibility_deadline_utc_ns and
            absent.visibility_deadline_utc_ns <= scope.through_utc_ns and
            absent.order_history_complete and absent.terminal_history_complete and absent.fills_complete and absent.economics_complete;
    }

    fn omsReportFromCanonical(self: *const TradingShard, report: canonical.ExecutionReport) !oms_module.ExecutionReport {
        if (report.exchange_account != self.exchange_account_identity)
            return error.CanonicalScopeMismatch;
        const order_id = std.math.cast(u64, report.order) orelse return error.IdentityOutOfRange;
        const report_id = std.math.cast(u64, report.identity) orelse return error.IdentityOutOfRange;
        const instrument = self.oms.instrumentForOrder(order_id) orelse return error.UnknownOrder;
        if (instrument != report.instrument) return error.CanonicalScopeMismatch;
        const rules = self.instrumentEntry(report.instrument) orelse return error.UnknownOmsInstrument;
        if (report.cumulative_quantity.rules_version != rules.rules.version or
            report.remaining_quantity.rules_version != rules.rules.version)
            return error.StaleInstrumentRules;
        return .{
            .report_id = report_id,
            .order_id = order_id,
            .revision = report.revision,
            .status = switch (report.status) {
                .accepted => .accepted,
                .partially_filled => .partially_filled,
                .filled => .filled,
                .canceled => .canceled,
                .rejected => .rejected,
                .amended => .amended,
            },
            .cumulative_quantity = std.math.cast(i64, report.cumulative_quantity.lots) orelse return error.QuantityOutOfRange,
            .remaining_quantity = std.math.cast(i64, report.remaining_quantity.lots) orelse return error.QuantityOutOfRange,
            .canonical_digest = try canonicalPayloadDigest(.{ .execution_report = report }),
        };
    }

    fn applyCanonicalReport(self: *TradingShard, report: canonical.ExecutionReport, fact_identity: u64, now_monotonic_ns: u64) !void {
        const oms_report = try self.omsReportFromCanonical(report);
        switch (try self.oms.lookupReport(oms_report)) {
            .duplicate => return,
            .unknown => {},
        }
        const previous_reservation = try self.activeReservationAtoms();
        try self.oms.applyReport(oms_report);
        const reflected_reservation = (try self.confirmPendingReplacement(oms_report.order_id, oms_report.report_id, now_monotonic_ns)) orelse previous_reservation;
        try self.adjustMarginBuffersForReservationChange(reflected_reservation);
        try self.recalculateRisk(false);
        try self.trace.append(switch (report.status) {
            .accepted => .order_accepted,
            .partially_filled => .order_partially_filled,
            .filled => .order_filled,
            .canceled => .order_canceled,
            .rejected => .order_rejected,
            .amended => .order_amended,
        }, fact_identity);
    }

    fn abiPriceAtoms(self: *const TradingShard, micros: i64, asset: canonical.AssetIdentity) !i128 {
        const entry = self.asset_registry.get(asset) orelse return error.UnknownAssetDefinition;
        return (canonical.Decimal{ .coefficient = micros, .scale = 6 }).exactAtoms(entry.definition.atomic_scale);
    }

    fn requireSettlementConsumers(self: *const TradingShard) !void {
        if (self.asset_configuration_failed) return error.AssetPrecisionUnsupported;
        if (self.asset_registry.legacyConsumerCompatible()) return;
        for (self.instrument_registry.entries[0..self.instrument_registry.count]) |entry| {
            if (self.settlementConsumersCompatible(entry.instrument)) return;
        }
        return error.AssetPrecisionUnsupported;
    }

    /// The same current native evidence qualifies risk and authorizes dispatch.
    pub fn currentNativeRiskCash(self: *const TradingShard, instrument: canonical.InstrumentIdentity) !i128 {
        if (self.economic_fault_count != 0) return error.ExchangeOpeningGateClosed;
        const configured = self.instrumentEntry(instrument) orelse return error.UnknownOmsInstrument;
        var observed_exchange_cash = self.exchangeCash();
        if (self.canonical_account.bootstrap != null) {
            const account = &self.canonical_account;
            if (!account.valid or account.exchange_account != self.exchange_account_identity)
                return error.ExchangeOpeningGateClosed;
            const available = account.nativeAvailable(configured.rules.settlement_asset) orelse return error.ExchangeOpeningGateClosed;
            for (account.balances[0..account.balance_count]) |balance|
                if (account.nativeAvailable(balance.asset) == null) return error.ExchangeOpeningGateClosed;
            for (account.positions[0..account.position_count]) |position| {
                const positioned = self.instrumentEntry(position.instrument) orelse return error.ExchangeOpeningGateClosed;
                if (position.quantity.rules_version != positioned.rules.version) return error.ExchangeOpeningGateClosed;
                if (positioned.product != .spot and position.quantity.lots != 0)
                    _ = account.nativeMarginEvidence(position.instrument, positioned.rules.settlement_asset) orelse return error.ExchangeOpeningGateClosed;
            }
            if (configured.product != .spot)
                _ = account.nativeMarginEvidence(instrument, configured.rules.settlement_asset) orelse return error.ExchangeOpeningGateClosed;
            // USD valuations cannot substitute for native collateral evidence.
            for (account.margins[0..account.margin_count]) |margin| {
                if (margin.usd_valuation) |valuation| {
                    var has_value = false;
                    for ([_]?canonical.Decimal{ valuation.initial_margin, valuation.maintenance_margin, valuation.isolated_equity }) |value|
                        if (value) |amount| {
                            has_value = has_value or amount.coefficient != 0;
                        };
                    if (has_value and margin.amount == null) return error.ExchangeOpeningGateClosed;
                }
            }
            observed_exchange_cash = @min(observed_exchange_cash, available.atoms);
        }
        return observed_exchange_cash;
    }

    pub fn settlementConsumersCompatible(self: *const TradingShard, instrument: canonical.InstrumentIdentity) bool {
        if (self.asset_configuration_failed) return false;
        const entry = self.instrumentEntry(instrument) orelse return false;
        if (!entry.margin_configured) return false;
        if (!self.asset_registry.hasVenueCode(entry.rules.settlement_asset, entry.venue) or
            (entry.product == .spot and !self.asset_registry.hasVenueCode(entry.rules.base_asset, entry.venue))) return false;
        if (self.economic_projection.exchange.instrumentPosition(instrument)) |position| {
            if (position.quantity_denominator != 0 and
                (position.quantity_denominator != entry.rules.quantity_denominator or position.quantity_numerator != entry.rules.quantity_numerator)) return false;
        }
        self.validateTickRange(instrument, entry.margin) catch return false;
        if (entry.product == .spot) _ = self.baseAtomsPerLot(entry) catch return false;
        return self.asset_registry.consumerCompatible(entry.margin.native_settlement_atoms);
    }

    fn baseAtomsPerLot(self: *const TradingShard, configured: instrument_registry.Entry) !canonical.AssetAmount {
        const base = self.asset_registry.get(configured.rules.base_asset) orelse return error.UnknownAssetDefinition;
        const numerator = try (canonical.Decimal{ .coefficient = configured.rules.quantity_numerator, .scale = 0 }).exactAtoms(base.definition.atomic_scale);
        if (@rem(numerator, configured.rules.quantity_denominator) != 0) return error.InexactEconomicAmount;
        const atoms = @divExact(numerator, configured.rules.quantity_denominator);
        if (atoms <= 0) return error.InvalidInstrumentConfiguration;
        try self.asset_registry.checkAmount(.{ .asset = base.definition.asset, .atoms = atoms }, true);
        _ = try std.math.mul(i128, atoms, base.definition.max_quantity_lots);
        return .{ .asset = base.definition.asset, .atoms = atoms };
    }

    fn validateTickRange(self: *const TradingShard, instrument: canonical.InstrumentIdentity, rules: shard_event.MarginRules) !void {
        const configured = self.instrumentEntry(instrument) orelse return error.UnknownOmsInstrument;
        const entry = self.asset_registry.get(configured.rules.settlement_asset) orelse {
            if (rules.native_settlement_atoms) return error.UnknownAssetDefinition;
            return;
        };
        try self.asset_registry.checkAmount(.{ .asset = configured.rules.settlement_asset, .atoms = rules.price_tick_atoms }, true);
        const price = try std.math.mul(i128, entry.definition.max_price_ticks, rules.price_tick_atoms);
        _ = try std.math.mul(i128, try std.math.mul(i128, price, entry.definition.max_quantity_lots), configured.rules.quantity_numerator);
        _ = try std.math.mul(i128, entry.definition.max_cumulative_atoms, entry.definition.max_quantity_lots);
    }

    fn checkAssetAmounts(self: *const TradingShard, value: anytype, single: bool) !void {
        const T = @TypeOf(value);
        if (T == canonical.AssetAmount) return self.asset_registry.checkAmount(value, single);
        if (T == canonical.InstrumentQuantity or T == canonical.InstrumentPrice) {
            const instrument = self.instrumentEntry(value.instrument) orelse return error.UnknownOmsInstrument;
            const asset = self.asset_registry.get(instrument.rules.settlement_asset) orelse return error.UnknownAssetDefinition;
            const amount = if (T == canonical.InstrumentQuantity) value.lots else value.ticks;
            const limit = if (T == canonical.InstrumentQuantity) asset.definition.max_quantity_lots else asset.definition.max_price_ticks;
            if (amount > limit or amount < -@as(i128, limit)) return error.AssetAmountOutOfRange;
            if (T == canonical.InstrumentQuantity and instrument.product == .spot) {
                const base = self.asset_registry.get(instrument.rules.base_asset) orelse return error.UnknownAssetDefinition;
                if (amount > base.definition.max_quantity_lots or amount < -@as(i128, base.definition.max_quantity_lots))
                    return error.AssetAmountOutOfRange;
            }
            return;
        }
        switch (@typeInfo(T)) {
            .@"struct" => inline for (std.meta.fields(T)) |field| try self.checkAssetAmounts(@field(value, field.name), single),
            .optional => if (value) |item| {
                try self.checkAssetAmounts(item, single);
            },
            .@"union" => switch (value) {
                inline else => |item| try self.checkAssetAmounts(item, single),
            },
            else => {},
        }
    }

    fn applyCanonicalFill(self: *TradingShard, fill: canonical.Fill, fact_identity: u64) !void {
        if (!self.settlementConsumersCompatible(fill.instrument)) return error.AssetPrecisionUnsupported;
        try self.checkAssetAmounts(fill, true);
        if (fill.exchange_account != self.exchange_account_identity)
            return error.CanonicalScopeMismatch;
        const fill_id = std.math.cast(u64, fill.identity) orelse return error.IdentityOutOfRange;
        const payload_digest = try canonicalPayloadDigest(.{ .fill = fill });
        switch (try self.economic_projection.lookupCanonicalFill(fill_id, payload_digest)) {
            .duplicate => return,
            .unknown => {},
        }
        try self.admitEconomicTime(fill.venue_fill_time_utc_ns);
        const order_id = std.math.cast(u64, fill.order) orelse return error.IdentityOutOfRange;
        const order = self.oms.orderById(order_id) orelse return error.UnknownOrder;
        if (order.last_reconciliation_status == .confirmed_absent) return error.TerminalFactConflict;
        if (order.instrument != fill.instrument) return error.CanonicalScopeMismatch;
        const instrument_config = self.instrumentEntry(fill.instrument) orelse return error.UnknownOmsInstrument;
        if (fill.quantity.rules_version != instrument_config.rules.version or
            fill.price.rules_version != instrument_config.rules.version)
            return error.StaleInstrumentRules;
        const quantity = std.math.cast(i64, fill.quantity.lots) orelse return error.QuantityOutOfRange;
        if (instrument_config.product == .spot) {
            const unit = try self.baseAtomsPerLot(instrument_config);
            try self.asset_registry.checkAmount(.{ .asset = unit.asset, .atoms = try std.math.mul(i128, quantity, unit.atoms) }, true);
        }
        const price = std.math.cast(i64, fill.price.ticks) orelse return error.PriceOutOfRange;
        const applied_quantity = try self.economic_projection.appliedCanonicalFillQuantity(order_id);
        const next_filled = try std.math.add(i64, applied_quantity, quantity);
        if (quantity <= 0 or price <= 0 or next_filled > order.quantity) return error.InvalidFill;
        const fee = fill.fee orelse return error.MissingFillFee;
        const rebate = fill.rebate orelse canonical.AssetAmount{ .asset = self.economic_projection.settlement_asset, .atoms = 0 };
        if (fee.atoms < 0 or rebate.atoms < 0) return error.InvalidEconomicFact;
        var settlement_fee = canonical.AssetAmount{ .asset = self.economic_projection.settlement_asset, .atoms = 0 };
        var settlement_rebate = canonical.AssetAmount{ .asset = self.economic_projection.settlement_asset, .atoms = 0 };
        var base_fee = canonical.AssetAmount{ .asset = if (instrument_config.product == .spot) instrument_config.rules.base_asset else settlement_asset, .atoms = 0 };
        var base_rebate = base_fee;
        var native_fee: ?canonical.AssetAmount = null;
        var native_rebate: ?canonical.AssetAmount = null;
        if (fee.atoms != 0) {
            if (fee.asset == self.economic_projection.settlement_asset)
                settlement_fee = fee
            else if (instrument_config.product == .spot and fee.asset == instrument_config.rules.base_asset)
                base_fee = fee
            else
                native_fee = fee;
        }
        if (rebate.atoms != 0) {
            if (rebate.asset == self.economic_projection.settlement_asset)
                settlement_rebate = rebate
            else if (instrument_config.product == .spot and rebate.asset == instrument_config.rules.base_asset)
                base_rebate = rebate
            else
                native_rebate = rebate;
        }
        const economic_instrument = fill.instrument;
        try self.checkNativeCharges(native_fee, native_rebate);
        const changed = try self.economic_projection.applyCanonicalFillWithSource(.{
            .identity = fill_id,
            .order_id = order_id,
            .side = switch (fill.side) {
                .buy => .buy,
                .sell => .sell,
            },
            .quantity = .{ .instrument = economic_instrument, .rules_version = fill.quantity.rules_version, .lots = fill.quantity.lots },
            .price = .{ .instrument = economic_instrument, .rules_version = fill.price.rules_version, .ticks = fill.price.ticks },
            .price_tick_value = .{ .asset = instrument_config.rules.settlement_asset, .atoms = instrument_config.margin.price_tick_atoms },
            .quantity_denominator = instrument_config.rules.quantity_denominator,
            .quantity_numerator = instrument_config.rules.quantity_numerator,
            .fee = settlement_fee,
            .rebate = settlement_rebate,
            .base_fee = base_fee,
            .base_atom_value = if (instrument_config.product == .spot) try self.baseAtomsPerLot(instrument_config) else .{ .asset = settlement_asset, .atoms = 0 },
            .base_rebate = base_rebate,
            .native_fee = native_fee,
            .native_rebate = native_rebate,
            .portfolio_margin_ppm = if (instrument_config.margin_configured) instrument_config.margin.internal_initial_margin_ppm else self.internal_initial_margin_ppm,
            .exchange_margin_ppm = if (instrument_config.margin_configured) instrument_config.margin.venue_initial_margin_ppm else self.venue_initial_margin_ppm,
            .product = instrument_config.product,
        }, payload_digest, .{ .canonical_fill = fill, .exchange_account = self.exchange_account_identity, .portfolio = self.portfolio_identity, .strategy = order.strategy_instance });
        if (!changed) return;
        try self.rememberEconomicTime(fill_id, .fill, payload_digest, fill.venue_fill_time_utc_ns);
        try self.checkEconomicRanges();
        try self.recalculateRisk(false);
        try self.assertClosures();
        try self.trace.append(.fill, fact_identity);
        try self.trace.append(.fee_ledger_transaction, fact_identity);
        try self.trace.append(.risk_reservation_rebalanced, fact_identity);
    }

    fn revokeHostActivation(self: *TradingShard, identity: u128, fact_identity: u64) !void {
        std.debug.assert(self.host_activation_identity == identity);
        self.host_activation_identity = 0;
        self.host_activation_barrier = 0;
        self.host_activation_session = .{ .fencing = 0, .shard = 0, .generation = 0 };
        self.host_activation_fact_sequence = 0;
        self.host_activation_state_digest = @splat(0);
        try self.trace.append(.host_activation_revoked, fact_identity);
    }

    fn rejectColdCandidate(self: *TradingShard, identity: u64) !?OrderCommand {
        if (self.history_conflict_latched) return null;
        self.history_conflict_latched = true;
        self.oms.recovery_only = true;
        if (self.operational_state.initialized) try self.applyOperationalGate(.{ .gate_identity = identity, .target_identity = self.operational_state.target_identity, .kind = .latched, .reason = .reconciliation_break, .open = false });
        try self.trace.append(.history_candidate_conflict, identity);
        try self.trace.append(.canonical_order_reconciliation, identity);
        return null;
    }

    fn handleOmsGroup(self: *TradingShard, input: CoreEvent, group: oms.IntentGroup) !?OrderCommand {
        if (!self.genesisReady()) return error.GenesisIncomplete;
        switch (try self.oms.groupIdentityStatus(group)) {
            .duplicate => return null,
            .conflict => {
                try self.rejectIntent(.oms_intent_conflict, group.first_intent_sequence, .intent_identity_conflict);
                return null;
            },
            .fresh => {},
        }
        var candidate: TradingShard = undefined;
        copyTradingState(&candidate, self);
        const qualified = candidate.qualifyOmsGroup(group) catch |err| switch (err) {
            error.MarginSafetyGateClosed => {
                try candidate.rejectSubmittedIntent(group, .strategy_intent_rejected, .margin_safety_gate_closed);
                copyTradingState(self, &candidate);
                return null;
            },
            error.UnsupportedOrderSpec, error.CapabilityUnsupported => {
                try self.rejectSubmittedIntent(group, .strategy_intent_rejected, if (err == error.CapabilityUnsupported) .capability_unsupported else .unsupported_order_spec);
                return null;
            },
            error.MarketDataGap,
            error.StrategyLimitExceeded,
            error.VirtualPortfolioLimitExceeded,
            error.DecisionDomainLimitExceeded,
            error.ExchangeAccountLimitExceeded,
            error.GlobalLimitExceeded,
            error.PortfolioOpeningGateClosed,
            error.ExchangeOpeningGateClosed,
            error.InsufficientSpotAsset,
            error.PortfolioReduceOnlyViolation,
            error.TradingNotAuthorized,
            error.DeRiskTargetViolation,
            error.StrategyCutoverFenced,
            => {
                const reason: RejectReason = switch (err) {
                    error.MarketDataGap => .market_data_gap,
                    error.StrategyLimitExceeded => .strategy_limit_exceeded,
                    error.VirtualPortfolioLimitExceeded => .portfolio_limit_exceeded,
                    error.DecisionDomainLimitExceeded => .decision_domain_limit_exceeded,
                    error.ExchangeAccountLimitExceeded => .exchange_account_limit_exceeded,
                    error.GlobalLimitExceeded => .global_limit_exceeded,
                    error.PortfolioOpeningGateClosed => .portfolio_opening_gate_closed,
                    error.ExchangeOpeningGateClosed => .exchange_opening_gate_closed,
                    error.InsufficientSpotAsset => .insufficient_spot_asset,
                    error.PortfolioReduceOnlyViolation => .portfolio_reduce_only_violation,
                    error.TradingNotAuthorized, error.DeRiskTargetViolation, error.StrategyCutoverFenced => .authorization_closed,
                    else => unreachable,
                };
                try self.rejectSubmittedIntent(group, if (reason == .authorization_closed) .strategy_intent_rejected else .risk_rejected_lease, reason);
                return null;
            },
            else => return err,
        };
        var refs: [oms_module.max_group_members]oms_module.RiskFactRefs = undefined;
        for (qualified.group.members[0..qualified.group.count], 0..) |intent, index| {
            try candidate.trace.append(.risk_accepted, intent.intent_sequence);
            refs[index].decision = candidate.authoritativeBarrier();
            try candidate.trace.append(.risk_reservation_created, intent.intent_sequence);
            refs[index].reservation = candidate.authoritativeBarrier();
            refs[index].authority = try candidate.dispatchAuthorityRefs(intent.instrument, if (input.time_presence.monotonic) input.monotonic_time else 0, refs[index].decision);
        }
        try candidate.oms.applyQualifiedGroup(qualified.group, group, refs[0..qualified.group.count]);
        try candidate.adjustMarginBuffersForReservationChange(qualified.reservation_atoms);
        try candidate.trace.append(.oms_intent_group, group.first_intent_sequence);
        copyTradingState(self, &candidate);

        return null;
    }

    fn handleOmsDispatch(self: *TradingShard, input: CoreEvent, batch: oms.DispatchBatch) !?OrderCommand {
        var candidate: TradingShard = undefined;
        copyTradingState(&candidate, self);
        const previous_reservation = try candidate.activeReservationAtoms();
        try candidate.oms.applyDispatch(batch);
        try candidate.adjustMarginBuffersForReservationChange(previous_reservation);
        try candidate.trace.append(.oms_dispatch_batch, input.identity);
        copyTradingState(self, &candidate);

        return null;
    }

    fn handleAssetDefinition(self: *TradingShard, input: CoreEvent, definition: canonical.AssetDefinition) !?OrderCommand {
        const previous = self.asset_registry.get(definition.asset);
        var configured: TradingShard = undefined;
        copyTradingState(&configured, self);
        if (!try configured.asset_registry.activate(definition, try std.math.add(u64, self.authoritativeBarrier(), 1))) return null;
        if (configured.asset_registry.get(configured.economic_projection.settlement_asset) != null)
            try configured.checkEconomicRanges();
        // Partial virgin activation has no complete monetary namespace yet.
        if (configured.asset_registry.consumerCompatible(true)) {
            for (configured.canonical_account.balances[0..configured.canonical_account.balance_count]) |balance|
                try configured.checkAssetAmounts(balance, false);
            for (configured.canonical_account.positions[0..configured.canonical_account.position_count]) |position|
                try configured.checkAssetAmounts(position, false);
            for (configured.canonical_account.margins[0..configured.canonical_account.margin_count]) |margin|
                try configured.checkAssetAmounts(margin, false);
        }
        self.asset_registry = configured.asset_registry;
        try self.trace.append(.asset_definition_activated, input.identity);
        if (previous != null and previous.?.definition.version != definition.version) self.oms.recovery_only = true;
        return null;
    }

    fn observeColdOrderArchiveTimes(self: *TradingShard, previous_next_order_id: u64, input: CanonicalEvent) !void {
        const times = stableTimes(input);
        if (!times.presence.receive or times.receive == 0) return;
        for (self.oms.orders[0..self.oms.order_count]) |order| {
            if (order.id >= previous_next_order_id) try self.oms.noteOrderCreated(order.id, times.receive);
        }
        const order_id: ?u64 = switch (input) {
            .core => |event| switch (event.payload) {
                .oms_execution_report => |report| report.order_id,
                .oms_reconciliation_result => |result| result.order_id,
                else => null,
            },
            .venue => |event| switch (event.event) {
                .execution_report => |report| std.math.cast(u64, report.order),
                .order_reconciliation_result => |result| std.math.cast(u64, result.order),
                else => null,
            },
        };
        if (order_id) |id| if (self.oms.orderById(id)) |order| {
            if (order.created_at_utc_ns != 0 and switch (order.state) {
                .filled, .canceled, .rejected => true,
                else => false,
            }) try self.oms.noteTerminalObserved(id, times.receive);
        };
    }

    fn handleHistoryVerified(self: *TradingShard, input: CoreEvent) !?OrderCommand {
        if (self.pending_safety_history_candidate) |pending| if (pending.request.pending_id == input.payload.history_candidate_verified.request.pending_id) {
            const main = self.pending_history_candidate;
            const main_member = self.pending_history_member_index;
            self.pending_history_candidate = pending;
            self.pending_history_member_index = self.pending_safety_history_member_index;
            self.pending_safety_history_candidate = null;
            self.pending_safety_history_member_index = null;
            defer {
                self.pending_safety_history_candidate = self.pending_history_candidate;
                self.pending_safety_history_member_index = self.pending_history_member_index;
                self.pending_history_candidate = main;
                self.pending_history_member_index = main_member;
            }
            return self.finalizeHistoryCandidate(input);
        };
        return self.finalizeHistoryCandidate(input);
    }

    fn finalizeHistoryCandidate(self: *TradingShard, input: CoreEvent) !?OrderCommand {
        const pending = self.pending_history_candidate orelse return error.InvalidHistoryCandidate;
        const root = self.business_history_root orelse return error.InvalidHistoryCandidate;
        const verdict = try pending.finalize(&input.payload.history_candidate_verified, root);
        const original = try decodeStableInput(pending.originalRecord());
        const account_input = original == .venue and original.venue.event == .account_reconciliation_result;
        const account_coverage = account_input and pending.request.key.identity != .canonical_account_reconciliation;
        var coverage: ?VerifiedAccountCoverage = null;
        if (account_input and pending.request.key.identity == .canonical_account_reconciliation and verdict == .proven_first) {
            if (try self.coldAccountFactIndex(original, 0)) |member| {
                const semantic = (try self.historySemantic(original, member)) orelse return error.InvalidHistoryCandidate;
                self.pending_history_candidate.?.request.key.identity = semantic.identity;
                self.pending_history_candidate.?.request.candidate_payload_digest = semantic.digest;
                self.pending_history_member_index = member;
                try self.trace.append(.history_candidate_verified, input.identity);
                return null;
            }
        }
        if (account_coverage) {
            if (verdict != .same) return self.rejectColdCandidate(input.identity);
            const member = self.pending_history_member_index orelse return error.InvalidHistoryCandidate;
            if (try self.coldAccountFactIndex(original, @as(usize, member) + 1)) |next_member| {
                const semantic = (try self.historySemantic(original, next_member)) orelse return error.InvalidHistoryCandidate;
                self.pending_history_candidate.?.request.key.identity = semantic.identity;
                self.pending_history_candidate.?.request.candidate_payload_digest = semantic.digest;
                self.pending_history_member_index = next_member;
                try self.trace.append(.history_candidate_verified, input.identity);
                return null;
            }
            coverage = .{ .input_digest = try accountCoverageInputDigest(original.venue), .root_digest = root.root_digest };
        } else if (verdict == .same and self.pending_history_member_index == null) {
            _ = self.releaseDeferredHistoryAdmission(original);
            self.pending_history_candidate = null;
            self.pending_history_member_index = null;
            try self.trace.append(.history_candidate_verified, input.identity);
            return null;
        }
        if (!account_coverage and verdict != .proven_first) return self.rejectColdCandidate(input.identity);
        const group_count: ?u8 = if (original == .core) switch (original.core.payload) {
            .oms_intent_group => |group| group.count,
            .external_order_intent => 1,
            else => null,
        } else null;
        if (group_count != null and group_count.? > 1) {
            const next_member: u8 = if (self.pending_history_member_index) |index| index + 1 else 0;
            if (next_member < group_count.?) {
                const semantic = (try self.historySemantic(original, next_member)) orelse return error.InvalidHistoryCandidate;
                self.pending_history_candidate.?.request.key.identity = semantic.identity;
                self.pending_history_candidate.?.request.candidate_payload_digest = semantic.digest;
                self.pending_history_member_index = next_member;
                try self.trace.append(.history_candidate_verified, input.identity);
                return null;
            }
        }
        const order_id: ?u64 = switch (original) {
            .core => |event| switch (event.payload) {
                .oms_execution_report => |report| report.order_id,
                .oms_reconciliation_result => |result| result.order_id,
                else => null,
            },
            .venue => |event| switch (event.event) {
                .execution_report => |report| std.math.cast(u64, report.order),
                .order_reconciliation_result => |result| std.math.cast(u64, result.order),
                else => null,
            },
        };
        if (order_id) |id| if (self.oms.orderById(id) == null) return self.rejectColdCandidate(input.identity);
        if (original == .venue and original.venue.event == .order_dispatch_result) {
            const command_id = original.venue.event.order_dispatch_result.command;
            var retained = false;
            for (self.oms.command_history[0..self.oms.command_history_count]) |command|
                if (command.command_id == command_id) {
                    retained = true;
                    break;
                };
            if (!retained) return self.rejectColdCandidate(input.identity);
        }
        if (!pending.original_was_admissible) return self.rejectColdCandidate(input.identity);
        if (self.deferred_history_admission_count != 0 and !historySafetyInput(original)) return error.HistoryLookupPending;
        _ = self.releaseDeferredHistoryAdmission(original);
        self.pending_history_candidate = null;
        self.pending_history_member_index = null;
        try self.trace.append(.history_candidate_verified, input.identity);
        const previous_next_order_id = self.oms.next_order_id;
        const result = try self.applyUnfinalized(original, false, null, coverage);
        try self.observeColdOrderArchiveTimes(previous_next_order_id, original);
        return result.order_command;
    }

    fn applyVersionActivation(self: *TradingShard, activation: shard_event.VersionActivationEvent, identity: u64, verified: bool) !void {
        if (self.business_history_root != null and !verified) return error.ControlHistoryProofRequired;
        if (self.strategyFenced(activation.new_strategy_instance)) return error.StrategyCutoverFenced;
        if (activation.activation_identity == 0 or activation.new_release == 0 or activation.new_strategy_instance == 0 or
            activation.generation != try std.math.add(u64, self.release_generation, 1) or
            activation.old_release != self.active_release or
            activation.old_strategy_instance != self.active_strategy_instance or
            activation.barrier != try std.math.add(u64, self.authoritativeBarrier(), 1) or
            !std.mem.eql(u8, &activation.canonical_state_digest, &self.canonicalStateDigest()))
            return error.InvalidVersionActivation;
        self.release_generation = activation.generation;
        self.active_release = activation.new_release;
        self.active_strategy_instance = activation.new_strategy_instance;
        try self.trace.append(.version_activated, identity);
    }

    pub fn versionActivationHistoryRequest(self: *const TradingShard, original: CoreEvent) !history.LookupRequest {
        if (self.pending_history_candidate != null or self.pending_safety_history_candidate != null or self.deferred_history_admission_count != 0) return error.HistoryLookupPending;
        const root = self.business_history_root orelse return error.ControlHistoryProofRequired;
        const activation = original.payload.version_activation;
        var bytes: [128]u8 = undefined;
        return .{ .pending_id = activation.activation_identity, .key = .{ .origin = root.origin, .identity = .{ .strategy_fence = activation.new_strategy_instance } }, .candidate_payload_digest = history.hash(try snapshot_codec.encodeBare(&bytes, StrategyCutoverFence{ .strategy_instance = activation.new_strategy_instance })), .original_input_digest = try acceptedOriginalDigest(.{ .core = original }), .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
    }

    fn handle(self: *TradingShard, input: CoreEvent) !?OrderCommand {
        if (input.payload == .version_activation_history_verified) {
            const verified = input.payload.version_activation_history_verified;
            var original = input;
            original.payload = .{ .version_activation = verified.activation };
            const request = try self.versionActivationHistoryRequest(original);
            switch (try history.verifyResult(request, &verified.proof, self.business_history_root.?)) {
                .same, .conflict, .expired => return self.rejectColdCandidate(input.identity),
                .proven_first => try self.applyVersionActivation(verified.activation, input.identity, true),
            }
            return null;
        }
        if (input.payload == .history_safety_candidate_verified) {
            const verified = input.payload.history_safety_candidate_verified;
            const original = try decodeStableInput(verified.pending.originalRecord());
            const expected = (try self.historySafetyCandidateFor(original)) orelse return error.InvalidHistoryCandidate;
            if (!std.meta.eql(expected, verified.pending)) return error.InvalidHistoryCandidate;
            const main = self.pending_history_candidate;
            const safety = self.pending_safety_history_candidate;
            const main_member = self.pending_history_member_index;
            const safety_member = self.pending_safety_history_member_index;
            defer {
                self.pending_history_candidate = main;
                self.pending_safety_history_candidate = safety;
                self.pending_history_member_index = main_member;
                self.pending_safety_history_member_index = safety_member;
            }
            self.pending_history_candidate = verified.pending;
            self.pending_history_member_index = null;
            self.pending_safety_history_candidate = null;
            self.pending_safety_history_member_index = null;
            self.next_history_pending_id = try std.math.add(u128, self.next_history_pending_id, 1);
            return self.finalizeHistoryCandidate(.{ .identity = input.identity, .payload = .{ .history_candidate_verified = verified.proof } });
        }
        if (input.payload == .history_candidate_started) {
            const pending = input.payload.history_candidate_started;
            const original = try decodeStableInput(pending.originalRecord());
            const expected = (try self.historyCandidateFor(original)) orelse return error.InvalidHistoryCandidate;
            if (!std.meta.eql(expected, pending)) return error.InvalidHistoryCandidate;
            const account_member = if (pending.request.key.identity == .canonical_account_reconciliation) null else try self.coldAccountFactIndex(original, 0);
            if (self.pending_history_candidate != null) {
                if (!historySafetyInput(original) or self.pending_safety_history_candidate != null) return error.HistorySafetyCapacity;
                self.pending_safety_history_candidate = pending;
                self.pending_safety_history_member_index = account_member;
            } else {
                self.pending_history_candidate = pending;
                self.pending_history_member_index = account_member;
            }
            self.next_history_pending_id = try std.math.add(u128, self.next_history_pending_id, 1);
            try self.trace.append(.history_candidate_started, input.identity);
            if (!pending.original_was_admissible) self.trace.events[self.trace.len - 1].reject_reason = .stale_canonical_source;
            return null;
        }
        if (input.payload == .history_candidate_verified) return self.handleHistoryVerified(input);
        if (input.payload == .forced_archive_committed) {
            const commit = input.payload.forced_archive_committed;
            const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = (self.checkpoint orelse return error.OrderArchiveOriginUnavailable).stream }, .account = self.exchange_account_identity };
            const qualification = try self.prepareForcedArchive(commit.forced_id, origin, &commit.evidence);
            if (!std.mem.eql(u8, &commit.qualification_digest, &qualification.digest())) return error.InvalidForcedArchiveCommit;
            try self.economic_projection.commitForcedArchive(qualification, commit.receipt, self.business_history_root);
            self.business_history_root = commit.receipt.root;
            self.last_forced_archive = commit;
            self.last_forced_archive_input = .{ .identity = input.identity, .times = stableTimes(.{ .core = input }) };
            self.last_business_archive_kind = .forced;
            try self.trace.append(.forced_archive_committed, input.identity);
            return null;
        }
        if (input.payload == .control_archive_committed) {
            const commit = input.payload.control_archive_committed;
            const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = (self.checkpoint orelse return error.OrderArchiveOriginUnavailable).stream }, .account = self.exchange_account_identity };
            const qualification = try @import("control_history_batch.zig").qualify(self, origin, self.authoritativeBarrier());
            if (!std.mem.eql(u8, &commit.qualification_digest, &qualification.digest()) or commit.receipt.root.barrier != qualification.barrier) return error.InvalidControlArchiveCommit;
            _ = try history.verifyReceipt(commit.receipt, origin, qualification.digest(), self.business_history_root);
            try @import("control_history_batch.zig").release(self, qualification);
            self.business_history_root = commit.receipt.root;
            self.last_control_archive = commit;
            self.last_control_archive_input = .{ .identity = input.identity, .times = stableTimes(.{ .core = input }) };
            self.last_business_archive_kind = .control;
            try self.trace.append(.control_archive_committed, input.identity);
            return null;
        }
        if (input.payload == .funding_archive_committed) {
            const commit = input.payload.funding_archive_committed;
            if (self.pending_history_candidate != null or self.pending_safety_history_candidate != null or self.deferred_history_admission_count != 0) return error.HistoryLookupDeferred;
            const stream = (self.checkpoint orelse return error.OrderArchiveOriginUnavailable).stream;
            const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = stream }, .account = self.exchange_account_identity };
            const qualification = try self.prepareFundingArchive(commit.funding_id, origin, self.authoritativeBarrier());
            if (!std.mem.eql(u8, &commit.qualification_digest, &qualification.digest())) return error.InvalidFundingArchiveCommit;
            try self.economic_projection.commitFundingArchive(qualification, commit.receipt, self.business_history_root);
            self.business_history_root = commit.receipt.root;
            self.last_funding_archive = commit;
            self.last_funding_archive_input = .{ .identity = input.identity, .times = stableTimes(.{ .core = input }) };
            self.last_business_archive_kind = .funding;
            try self.trace.append(.funding_archive_committed, input.identity);
            return null;
        }
        if (input.payload == .reconciliation_archive_committed) {
            const commit = input.payload.reconciliation_archive_committed;
            const stream = (self.checkpoint orelse return error.OrderArchiveOriginUnavailable).stream;
            const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = stream }, .account = self.exchange_account_identity };
            const qualification = try self.prepareReconciliationWindowArchive(commit.window_id, origin, self.authoritativeBarrier());
            if (!std.mem.eql(u8, &commit.qualification_digest, &qualification.digest()) or commit.receipt.root.barrier != qualification.barrier) return error.InvalidReconciliationArchiveCommit;
            _ = try history.verifyReceipt(commit.receipt, origin, qualification.digest(), self.business_history_root);
            const window = qualification.window;
            const evidence = window.original.event.account_reconciliation_result.account_economics.?;
            self.reconciliation_cursor = .{ .identity = window.identity, .through_utc_ns = evidence.through_utc_ns, .closed_economic_fact_count = window.economic_fact_count, .balance_count = evidence.balance_count, .balances = evidence.balances, .root_digest = commit.receipt.root.root_digest };
            self.pending_reconciliation_window = null;
            self.open_economic_fact_count = 0;
            self.open_economic_min_utc_ns = 0;
            self.open_economic_max_utc_ns = 0;
            self.open_economic_unknown_time_count = 0;
            var kept: u8 = 0;
            for (self.economic_projection.seen[0..self.economic_projection.seen_count]) |known| {
                if (known.kind == .account_snapshot and known.identity == window.identity) continue;
                self.economic_projection.seen[kept] = known;
                kept += 1;
            }
            self.economic_projection.seen_count = kept;
            self.business_history_root = commit.receipt.root;
            self.last_reconciliation_archive = commit;
            self.last_reconciliation_archive_input = .{ .identity = input.identity, .times = stableTimes(.{ .core = input }) };
            self.last_business_archive_kind = .reconciliation;
            try self.trace.append(.reconciliation_archive_committed, input.identity);
            return null;
        }
        if (input.payload == .fill_archive_committed) {
            const commit = input.payload.fill_archive_committed;
            if (self.pending_history_candidate != null or self.pending_safety_history_candidate != null or self.deferred_history_admission_count != 0) return error.HistoryLookupDeferred;
            const stream = (self.checkpoint orelse return error.OrderArchiveOriginUnavailable).stream;
            const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = stream }, .account = self.exchange_account_identity };
            const qualification = try self.economic_projection.prepareFillArchive(commit.fill_id, origin, self.authoritativeBarrier());
            if (!std.mem.eql(u8, &commit.qualification_digest, &qualification.digest())) return error.InvalidFillArchiveCommit;
            try self.economic_projection.commitFillArchive(qualification, commit.receipt, self.business_history_root);
            self.business_history_root = commit.receipt.root;
            self.last_fill_archive = commit;
            self.last_business_archive_kind = .fill;
            try self.trace.append(.fill_archive_committed, input.identity);
            return null;
        }
        if (input.payload == .order_archive_committed) {
            const commit = input.payload.order_archive_committed;
            if (self.hasDeferredOrderHistory(commit.order_id)) return error.OrderArchivePinned;
            const qualification = try self.oms.prepareOrderArchive(commit.order_id, try self.economic_projection.appliedCanonicalFillQuantity(commit.order_id), self.exchange_account_identity);
            for (self.economic_projection.applied_fills[0..self.economic_projection.applied_fill_count]) |fill| if (fill.fill.order_id == commit.order_id) return error.OrderArchivePinned;
            const stream = (self.checkpoint orelse return error.OrderArchiveOriginUnavailable).stream;
            if (commit.applied_fill_quantity != qualification.applied_fill_quantity or
                !std.mem.eql(u8, &commit.qualification_digest, &qualification.digest()) or
                commit.receipt.root.origin.stream.domain != .decision_log or commit.receipt.root.origin.stream.id != stream or
                commit.receipt.root.origin.account != self.exchange_account_identity or
                commit.receipt.root.barrier != self.authoritativeBarrier() or
                !std.mem.eql(u8, &commit.receipt.qualification_digest, &commit.qualification_digest)) return error.InvalidOrderArchiveCommit;
            _ = try history.verifyReceipt(commit.receipt, commit.receipt.root.origin, commit.qualification_digest, self.business_history_root);
            var related_dispatches: [2048]u8 = @splat(0);
            for (self.oms.command_history[0..self.oms.command_history_count]) |command| if (command.order_id == commit.order_id) {
                const bit: usize = @intCast(command.command_id % (related_dispatches.len * 8));
                related_dispatches[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
            };
            var kept_dispatches: u16 = 0;
            for (self.dispatch_ingress_history[0..self.dispatch_ingress_history_count]) |entry| {
                var released = false;
                const bit: usize = @intCast(entry.body.command % (related_dispatches.len * 8));
                if (related_dispatches[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0)
                    for (self.oms.command_history[0..self.oms.command_history_count]) |command| if (command.command_id == entry.body.command) {
                        released = command.order_id == commit.order_id;
                        break;
                    };
                if (!released) {
                    self.dispatch_ingress_history[kept_dispatches] = entry;
                    kept_dispatches += 1;
                }
            }
            self.dispatch_ingress_history_count = kept_dispatches;
            try self.economic_projection.releaseOrderFillTotal(qualification, commit.receipt, self.business_history_root);
            try self.oms.commitOrderArchive(qualification);
            self.business_history_root = commit.receipt.root;
            self.last_order_archive = commit;
            self.last_business_archive_kind = .order;
            try self.trace.append(.order_archive_committed, input.identity);
            return null;
        }
        if (input.payload == .checkpoint_committed) {
            const receipt = input.payload.checkpoint_committed;
            if (self.checkpoint) |previous| if (std.meta.eql(previous, receipt)) return null;
            const expected = try self.checkpointReceipt(receipt.stream, receipt.generation, receipt.archive_root);
            if (!std.meta.eql(expected, receipt)) return error.InvalidCheckpointReceipt;
            var retained = try self.checkpointPins();
            retained.base_sequence = receipt.barrier;
            retained.base_history_head = receipt.history_head;
            retained.base_input_head = receipt.input_head;
            retained.len = 0;
            self.trace = retained;
            self.checkpoint = receipt;
            try self.trace.append(.checkpoint_committed, input.identity);
            return null;
        }
        switch (input.payload) {
            .exchange_balance, .opening_balance, .portfolio_transfer, .economic_fill, .funding_settlement, .venue_forced_execution, .economic_account_snapshot => try self.requireSettlementConsumers(),
            else => {},
        }
        switch (input.payload) {
            .checkpoint_committed => unreachable,
            .order_archive_committed, .fill_archive_committed, .funding_archive_committed, .reconciliation_archive_committed, .control_archive_committed, .forced_archive_committed, .version_activation_history_verified => unreachable,
            .history_candidate_started, .history_candidate_verified, .history_safety_candidate_verified => unreachable,
            .asset_definition_activated => |definition| return self.handleAssetDefinition(input, definition),
            .control_command => |command| {
                const keep_positions = command.kind == .stop_keep_positions;
                const preserved = if (keep_positions)
                    self.captureLifecycleEconomics()
                else
                    LifecycleEconomics{};
                const action = try self.operational_state.applyCommand(command, input.wall_time);
                if (!action.changed) return null;
                if (command.kind == .start_recovery) {
                    try self.applyOperationalGate(.{
                        .gate_identity = primary_lease_gate_identity,
                        .target_identity = command.target_identity,
                        .kind = .self_recovering,
                        .reason = .primary_lease,
                        .open = self.fencing_token != 0,
                        .continuity_proven = self.fencing_token != 0,
                    });
                    try self.applyOperationalGate(.{
                        .gate_identity = risk_lease_gate_identity,
                        .target_identity = command.target_identity,
                        .kind = .self_recovering,
                        .reason = .risk_lease,
                        .open = self.risk_lease_atoms > 0,
                        .continuity_proven = self.risk_lease_atoms > 0,
                    });
                }
                if (action.cancel_open_orders)
                    try self.oms.cancelOpenOrders(action.cancel_increasing_only);
                if (!self.operational_state.trading_authorized and self.host_activation_identity != 0)
                    try self.revokeHostActivation(self.host_activation_identity, input.identity);
                if (keep_positions) {
                    if (action.cancel_increasing_only or
                        self.operational_state.mode != .stopped or
                        preserved.de_risk_target_position != self.operational_state.target_position)
                        return error.KeepPositionsMisreadAsDeRisk;
                    try self.assertLifecycleEconomicsPreserved(preserved);
                    try self.assertClosures();
                }
                try self.trace.append(.control_command_applied, input.identity);
                self.control_fact_sequences[self.operational_state.command_count - 1] = self.authoritativeBarrier();
                if (changesTradingAuthorization(command.kind))
                    self.authority_control_barrier = self.authoritativeBarrier();
            },
            .recovery_completed => {
                try self.operational_state.recoveryCompleted();
                try self.trace.append(.recovery_completed, input.identity);
            },
            .safety_gate_change => |change| {
                if (change.kind == .self_recovering and change.open and change.continuity_proven)
                    return error.UnverifiedContinuityProof;
                try self.applyOperationalGate(change);
                try self.trace.append(.safety_gate_changed, input.identity);
            },
            .lifecycle_progress => |progress| {
                if (progress.position_quantity != self.portfolioPosition().quantity or
                    progress.open_orders_closed != self.oms.openOrdersClosed() or
                    progress.reconciliation_complete != !self.economic_projection.reconciliation_break or
                    self.portfolioPosition().quantity != self.exchangePosition().quantity or
                    try std.math.add(i128, self.portfolioCash(), self.treasuryCash()) != self.exchangeCash())
                    return error.InvalidLifecycleProgress;
                try self.assertClosures();
                try self.operational_state.applyProgress(progress);
                try self.trace.append(.lifecycle_progressed, input.identity);
            },
            .risk_warning => |warning| {
                try self.operational_state.applyRiskWarning(warning);
                try self.trace.append(.risk_warning_recorded, input.identity);
            },
            .lease_gate_change => |change| {
                if (change.kind != .self_recovering or
                    (change.reason != .primary_lease and change.reason != .risk_lease))
                    return error.InvalidLeaseGate;
                var normalized = change;
                normalized.gate_identity = if (change.reason == .primary_lease)
                    primary_lease_gate_identity
                else
                    risk_lease_gate_identity;
                try self.applyOperationalGate(normalized);
                try self.trace.append(.lease_gate_changed, input.identity);
            },
            .strategy_cutover_fence => |fence| {
                if (fence.strategy_instance == 0) return error.InvalidStrategyInstance;
                var known = false;
                for (self.fenced_strategy_instances[0..self.fenced_strategy_count]) |identity| {
                    if (identity == fence.strategy_instance) known = true;
                }
                if (!known) {
                    if (self.fenced_strategy_count == self.fenced_strategy_instances.len)
                        return error.StrategyFenceCapacityExceeded;
                    self.fenced_strategy_instances[self.fenced_strategy_count] = fence.strategy_instance;
                    self.fenced_strategy_count += 1;
                }
                try self.oms.cancelStrategyOrders(fence.strategy_instance);
                try self.trace.append(.strategy_cutover_fenced, input.identity);
            },
            .version_activation => |activation| try self.applyVersionActivation(activation, input.identity, false),
            .instrument_rules_activated => |rules| {
                if ((rules.product == .isolated_linear_usdt and rules.reservation_model != .leveraged) or
                    (rules.product == .spot and rules.reservation_model != .cash))
                    return error.IncompatibleProductReservationModel;
                const normalized = rules;
                const entry: instrument_registry.Entry = .{
                    .instrument = normalized.instrument_identity,
                    .venue = normalized.venue,
                    .product = if (normalized.product == .spot) .spot else .isolated_linear_usdt,
                    .rules = normalized,
                    .margin = .{ .version = 1 },
                };
                const added = try self.instrument_registry.register(entry);
                try self.canonical_market.apply(.{ .instrument_definition_observed = .{
                    .instrument = normalized.instrument_identity,
                    .rules_version = normalized.version,
                } });
                try self.canonical_market.activateRules(normalized.instrument_identity, normalized.version);
                if (self.instrument_rules_version == 0 or normalized.instrument_identity == self.instrument_identity) {
                    self.instrument_rules_version = normalized.version;
                    self.instrument_identity = normalized.instrument_identity;
                    self.quantity_denominator = normalized.quantity_denominator;
                    self.reservation_model = normalized.reservation_model;
                }
                if (added) {
                    try self.trace.append(.instrument_rules_activated, input.identity);
                    self.instrument_registry.getPtr(normalized.instrument_identity).?.rules_barrier = self.authoritativeBarrier();
                }
            },
            .capability_profile_activation => |profile| {
                const entry = self.instrument_registry.getPtr(profile.instrument) orelse return error.UnknownInstrument;
                if (input.identity == 0 or profile.exchange_account != self.exchange_account_identity or
                    profile.venue != entry.venue or profile.product != entry.rules.product or
                    profile.rules_version != entry.rules.version or
                    profile.config_version != self.strategy_config_version or
                    profile.version == 0 or profile.adapter_session == 0 or
                    profile.max_dispatch_age_ns == 0 or !profile.supports_place or !profile.supports_cancel)
                    return error.InvalidCapabilityProfile;
                if (entry.capability) |known| {
                    if (profile.version < known.version) return error.StaleCapabilityProfile;
                    if (profile.version == known.version) {
                        if (!std.meta.eql(profile, known)) return error.CapabilityProfileConflict;
                        return null;
                    }
                }
                entry.capability = profile;
                try self.trace.append(.capability_profile_activated, input.identity);
                entry.capability_barrier = self.authoritativeBarrier();
                if (entry.trading_version == 0) {
                    entry.trading_enabled = true;
                    entry.trading_version = 1;
                    entry.trading_barrier = entry.capability_barrier;
                }
            },
            .instrument_trading_authorization => |authorization| {
                const entry = self.instrument_registry.getPtr(authorization.instrument) orelse return error.UnknownInstrument;
                if (authorization.expected_version != std.math.maxInt(u64) and
                    entry.trading_version == authorization.expected_version + 1 and entry.trading_enabled == authorization.enabled)
                {
                    const prior = self.trace.factAt(entry.trading_barrier) orelse return error.InvalidControlAuthority;
                    if (prior.kind == .instrument_trading_authorized and prior.identity == input.identity and
                        authorization.exchange_account == self.exchange_account_identity and
                        authorization.strategy_activation_identity == self.strategy_activation_identity and
                        authorization.config_version == self.strategy_config_version) return null;
                }
                if (input.identity == 0 or authorization.exchange_account != self.exchange_account_identity or
                    authorization.strategy_activation_identity != self.strategy_activation_identity or
                    authorization.config_version != self.strategy_config_version or !entry.margin_configured or
                    authorization.expected_version != entry.trading_version) return error.InvalidControlAuthority;
                entry.trading_version = try std.math.add(u64, entry.trading_version, 1);
                entry.trading_enabled = authorization.enabled;
                try self.trace.append(.instrument_trading_authorized, input.identity);
                entry.trading_barrier = self.authoritativeBarrier();
            },
            .margin_rules_activated => |rules| {
                const instrument_id = if (rules.instrument != 0) rules.instrument else self.instrument_identity;
                if (self.instrument_rules_version == 0 or instrument_id == 0 or rules.version == 0 or rules.price_tick_atoms <= 0 or
                    rules.venue_initial_margin_ppm <= 0 or
                    rules.internal_initial_margin_ppm < rules.venue_initial_margin_ppm or
                    rules.internal_maintenance_margin_ppm <= 0 or
                    rules.internal_maintenance_margin_ppm > rules.internal_initial_margin_ppm or
                    rules.fee_ppm < 0 or
                    rules.opening_buffer_atoms < rules.warning_buffer_atoms or
                    rules.warning_buffer_atoms < rules.kill_buffer_atoms or
                    rules.kill_buffer_atoms < 0 or
                    (rules.opening_buffer_bps > 0 and rules.opening_buffer_bps < rules.warning_buffer_bps) or
                    rules.warning_buffer_bps < rules.kill_buffer_bps or
                    rules.kill_buffer_bps < 0 or
                    (rules.opening_liquidation_distance_ticks > 0 and rules.opening_liquidation_distance_ticks < rules.warning_liquidation_distance_ticks) or
                    rules.warning_liquidation_distance_ticks < rules.kill_liquidation_distance_ticks or
                    rules.kill_liquidation_distance_ticks < 0 or
                    self.margin_rules_version != 0 and rules.instrument == 0)
                    return error.InvalidMarginRules;
                if (self.instrument_registry.get(instrument_id) == null)
                    return error.UnknownInstrument;
                try self.validateTickRange(instrument_id, rules);
                const configured = try self.instrument_registry.configureMargin(instrument_id, rules);
                if (!configured) return null;
                if (instrument_id == self.instrument_identity) {
                    self.margin_rules_version = rules.version;
                    self.price_tick_atoms = rules.price_tick_atoms;
                    self.venue_initial_margin_ppm = rules.venue_initial_margin_ppm;
                    self.internal_initial_margin_ppm = rules.internal_initial_margin_ppm;
                    self.internal_maintenance_margin_ppm = rules.internal_maintenance_margin_ppm;
                    self.risk_fee_ppm = rules.fee_ppm;
                    self.opening_buffer_atoms = rules.opening_buffer_atoms;
                    self.opening_buffer_bps = rules.opening_buffer_bps;
                    self.opening_liquidation_distance_ticks = rules.opening_liquidation_distance_ticks;
                    self.warning_buffer_atoms = rules.warning_buffer_atoms;
                    self.kill_buffer_atoms = rules.kill_buffer_atoms;
                    self.warning_buffer_bps = rules.warning_buffer_bps;
                    self.kill_buffer_bps = rules.kill_buffer_bps;
                    self.warning_liquidation_distance_ticks = rules.warning_liquidation_distance_ticks;
                    self.kill_liquidation_distance_ticks = rules.kill_liquidation_distance_ticks;
                }
                try self.trace.append(.margin_rules_activated, input.identity);
                self.instrument_registry.getPtr(instrument_id).?.margin_barrier = self.authoritativeBarrier();
            },
            .account_coordinator_bound => |origin| {
                if (self.coordinator_history_origin) |known| {
                    if (!std.meta.eql(known, origin)) return error.InvalidCoordinatorBinding;
                    return null;
                }
                if (!self.account_configured or origin.account != self.exchange_account_identity or
                    origin.stream.domain != .control or origin.stream.id == 0 or input.identity != origin.stream.id or
                    self.economic_projection.cumulative_forced_count != 0) return error.InvalidCoordinatorBinding;
                self.coordinator_history_origin = origin;
                try self.trace.append(.account_coordinator_bound, input.identity);
                self.coordinator_binding_fact = self.authoritativeBarrier();
            },
            .account_configuration => |configuration| {
                if (self.margin_rules_version == 0 or configuration.exchange_account_identity == 0 or
                    self.account_configured)
                    return error.InvalidAccountConfiguration;
                self.account_configured = true;
                self.exchange_account_identity = configuration.exchange_account_identity;
                try self.trace.append(.account_configuration, input.identity);
            },
            .exchange_balance => |balance| {
                try self.asset_registry.checkAmount(.{ .asset = self.economic_projection.settlement_asset, .atoms = balance.cash_atoms }, false);
                if (!self.account_configured or balance.cash_atoms <= 0 or self.exchange_balance_observed)
                    return error.InvalidExchangeBalance;
                self.economic_projection.exchange.usdt_balance_atoms = balance.cash_atoms;
                self.exchange_balance_observed = true;
                try self.trace.append(.exchange_balance, input.identity);
            },
            .exchange_positions => {
                if (!self.exchange_balance_observed or self.exchange_positions_observed)
                    return error.InvalidExchangePositions;
                self.exchange_positions_observed = true;
                try self.trace.append(.exchange_positions, input.identity);
            },
            .opening_balance => |balance| {
                if (@as(usize, balance.native_balance_count) + 1 > self.economic_baseline_balances.len)
                    return error.EconomicBaselineCapacityExceeded;
                try self.asset_registry.checkAmount(.{ .asset = self.economic_projection.settlement_asset, .atoms = balance.cash_atoms }, false);
                if (!self.exchange_positions_observed or balance.cash_atoms <= 0 or
                    balance.cash_atoms != self.exchangeCash() or self.opening_balance_observed)
                    return error.InvalidOpeningBalance;
                if (balance.native_balance_count > balance.native_balances.len) return error.InvalidOpeningBalance;
                for (balance.native_balances[0..balance.native_balance_count]) |native| {
                    try self.asset_registry.checkAmount(native, false);
                    if (self.canonical_account.nativeAvailable(native.asset) == null) return error.InvalidOpeningBalance;
                    var matches = false;
                    for (self.canonical_account.balances[0..self.canonical_account.balance_count]) |observed| {
                        if (observed.asset == native.asset and std.meta.eql(observed.total, native)) matches = true;
                    }
                    if (!matches) return error.InvalidOpeningBalance;
                    for (self.instrument_registry.entries[0..self.instrument_registry.count]) |instrument|
                        if (instrument.rules.base_asset == native.asset) return error.InvalidOpeningBalance;
                }
                self.economic_projection.treasury_usdt_atoms = balance.cash_atoms;
                try self.economic_projection.openNativeBalances(balance.native_balances[0..balance.native_balance_count]);
                try self.checkEconomicRanges();
                self.economic_projection.ledger_summary = .{
                    .transaction_count = 1,
                    .portfolio_debits_atoms = balance.cash_atoms,
                    .portfolio_credits_atoms = balance.cash_atoms,
                    .exchange_debits_atoms = balance.cash_atoms,
                    .exchange_credits_atoms = balance.cash_atoms,
                };
                self.economic_baseline_utc_ns = if (self.canonical_account.bootstrap != null) self.account_balance_utc_ns else if (input.time_presence.source) input.source_time else 0;
                self.economic_baseline_balances[0] = .{ .asset = self.economic_projection.settlement_asset, .atoms = balance.cash_atoms };
                self.economic_baseline_balance_count = 1;
                for (balance.native_balances[0..balance.native_balance_count]) |native| {
                    self.economic_baseline_balances[self.economic_baseline_balance_count] = native;
                    self.economic_baseline_balance_count += 1;
                }
                self.opening_balance_observed = true;
                try self.trace.append(.opening_balance, input.identity);
            },
            .virtual_portfolio_activated => |activation| {
                if (!self.opening_balance_observed or activation.portfolio_identity == 0 or
                    self.virtual_portfolio_active)
                    return error.InvalidVirtualPortfolio;
                self.virtual_portfolio_active = true;
                self.portfolio_identity = activation.portfolio_identity;
                try self.trace.append(.virtual_portfolio_activated, input.identity);
            },
            .portfolio_transfer => |transfer| {
                try self.asset_registry.checkAmount(.{ .asset = self.economic_projection.settlement_asset, .atoms = transfer.amount_atoms }, true);
                if (!self.virtual_portfolio_active or transfer.amount_atoms <= 0 or
                    transfer.amount_atoms > self.treasuryCash() or self.portfolio_funded)
                    return error.InvalidPortfolioTransfer;
                self.economic_projection.treasury_usdt_atoms = try std.math.sub(
                    i128,
                    self.treasuryCash(),
                    transfer.amount_atoms,
                );
                self.economic_projection.portfolio.usdt_balance_atoms = try std.math.add(
                    i128,
                    self.portfolioCash(),
                    transfer.amount_atoms,
                );
                self.economic_projection.ledger_summary.portfolio_debits_atoms = try std.math.add(
                    i128,
                    self.economic_projection.ledger_summary.portfolio_debits_atoms,
                    transfer.amount_atoms,
                );
                self.economic_projection.ledger_summary.portfolio_credits_atoms = try std.math.add(
                    i128,
                    self.economic_projection.ledger_summary.portfolio_credits_atoms,
                    transfer.amount_atoms,
                );
                self.economic_projection.ledger_summary.portfolio_transfer_count = 1;
                self.portfolio_funded = true;
                try self.trace.append(.portfolio_transfer, input.identity);
            },
            .strategy_activated => |activation| {
                if (self.strategyFenced(activation.strategy_identity)) return error.StrategyCutoverFenced;
                if (!self.portfolio_funded or activation.strategy_identity == 0 or
                    activation.config_version == 0 or activation.activation_identity == 0 or
                    self.strategy_active)
                    return error.InvalidStrategyActivation;
                self.strategy_active = true;
                self.strategy_identity = activation.strategy_identity;
                self.strategy_config_version = activation.config_version;
                self.strategy_activation_identity = activation.activation_identity;
                try self.trace.append(.strategy_activated, input.identity);
            },
            .host_activated => |activation| {
                if (activation.strategy_identity != self.strategy_identity or
                    activation.config_version != self.strategy_config_version)
                    return error.InvalidHostActivation;
                if (self.host_activation_identity != 0) {
                    if (self.host_activation_identity != activation.activation_identity or
                        !std.meta.eql(self.host_activation_session, activation.session) or
                        self.host_activation_barrier != activation.activation_barrier or
                        !std.mem.eql(u8, &self.host_activation_state_digest, &activation.state_digest))
                        return error.HostActivationConflict;
                    return null;
                }
                if (!self.strategy_active or
                    activation.activation_identity == 0 or
                    activation.session.generation == 0 or
                    (!self.host_activation_seen and activation.activation_identity != self.strategy_activation_identity) or
                    activation.activation_barrier == std.math.maxInt(u64) or
                    !std.mem.eql(u8, &activation.state_digest, &self.canonicalStateDigest()))
                    return error.InvalidHostActivation;
                if (self.host_activation_seen and activation.activation_identity != (self.nextHostActivationIdentity() catch return error.StaleHostActivation))
                    return error.StaleHostActivation;
                self.host_activation_seen = true;
                self.strategy_activation_identity = activation.activation_identity;
                self.host_activation_identity = activation.activation_identity;
                self.host_activation_barrier = activation.activation_barrier;
                self.host_activation_session = activation.session;
                self.host_activation_state_digest = activation.state_digest;
                try self.trace.append(.host_activated, input.identity);
                self.host_activation_fact_sequence = self.authoritativeBarrier();
            },
            .host_activation_revoked => |revocation| {
                if (revocation.strategy_identity != self.strategy_identity or
                    revocation.activation_identity == 0 or
                    revocation.activation_identity != self.host_activation_identity)
                    return error.InvalidHostRevocation;
                try self.revokeHostActivation(revocation.activation_identity, input.identity);
            },
            .primary_lease_granted => |lease| {
                if (!self.strategy_active or lease.fencing_token == 0 or
                    (self.fencing_token != 0 and lease.fencing_token <= self.fencing_token))
                    return error.InvalidPrimaryLease;
                self.fencing_token = lease.fencing_token;
                if (self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = primary_lease_gate_identity,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .self_recovering,
                    .reason = .primary_lease,
                    .open = true,
                    .continuity_proven = true,
                });
                try self.trace.append(.primary_lease_granted, input.identity);
            },
            .risk_lease_granted => |lease| {
                const lease_identity = if (lease.lease_identity == 0) input.identity else lease.lease_identity;
                if (self.fencing_token == 0 or lease.version == 0 or
                    lease.version < self.risk_lease_version)
                    return error.InvalidRiskLease;
                if (lease.version == self.risk_lease_version) {
                    if (lease_identity != self.risk_lease_identity or
                        lease.valid_through_barrier != self.risk_lease_valid_through_barrier or
                        lease.amount_atoms != self.risk_lease_atoms or lease.open != (self.risk_lease_atoms > 0))
                        return error.RiskLeaseIdentityConflict;
                    return null;
                }
                if (lease.open and lease.amount_atoms <= 0) return error.InvalidRiskLease;
                if (!lease.open and lease.amount_atoms != 0) return error.InvalidRiskLease;
                self.risk_lease_identity = lease_identity;
                self.risk_lease_version = lease.version;
                self.risk_lease_valid_through_barrier = lease.valid_through_barrier;
                self.risk_lease_atoms = lease.amount_atoms;
                self.strategy_limit_atoms = if (lease.strategy_limit_atoms == 0) lease.amount_atoms else lease.strategy_limit_atoms;
                self.portfolio_limit_atoms = if (lease.portfolio_limit_atoms == 0) lease.amount_atoms else lease.portfolio_limit_atoms;
                self.exchange_account_limit_atoms = if (lease.exchange_account_limit_atoms == 0) lease.amount_atoms else lease.exchange_account_limit_atoms;
                self.global_limit_atoms = if (lease.global_limit_atoms == 0) lease.amount_atoms else lease.global_limit_atoms;
                if (self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = risk_lease_gate_identity,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .self_recovering,
                    .reason = .risk_lease,
                    .open = lease.open,
                    .continuity_proven = lease.open,
                });
                if (self.strategy_limit_atoms > self.portfolio_limit_atoms or
                    self.portfolio_limit_atoms > self.exchange_account_limit_atoms or
                    self.exchange_account_limit_atoms > self.global_limit_atoms or
                    self.risk_lease_atoms > self.exchange_account_limit_atoms)
                    return error.InvalidRiskLeaseHierarchy;
                try self.recalculateRisk(false);
                try self.assertClosures();
                try self.trace.append(.risk_lease_granted, input.identity);
            },
            .mark_price => |price| {
                if (price.price_atoms <= 0) return error.InvalidMarkPrice;
                const instrument = self.instrument_registry.get(price.instrument) orelse return error.UnknownInstrument;
                const mark_ticks = try priceTicks(price.price_atoms, instrument.margin.price_tick_atoms);
                try self.canonical_market.apply(.{ .reference_price = .{
                    .instrument = price.instrument,
                    .kind = .mark,
                    .price = .{ .instrument = price.instrument, .rules_version = instrument.rules.version, .ticks = mark_ticks },
                } });
                if (price.instrument == self.instrument_identity) self.mark_price_atoms = price.price_atoms;
                _ = try self.applyEconomicProjection(.{ .mark_price = .{
                    .instrument = price.instrument,
                    .product = instrument.product,
                    .price_atoms = price.price_atoms,
                    .quantity_denominator = instrument.rules.quantity_denominator,
                    .quantity_numerator = instrument.rules.quantity_numerator,
                } });
                try self.recalculateRisk(false);
                try self.assertClosures();
                try self.trace.append(.mark_price, input.identity);
                for (self.oms.orders[0..self.oms.order_count]) |order|
                    if (order.state == .filled) {
                        self.economic_projection.ledger_summary.projections_complete = true;
                        break;
                    };
            },
            .timer => |request| {
                if (request.quantity <= 0 or request.limit_price_micros <= 0) return error.InvalidOrderQuantity;
                try self.trace.append(.timer, input.identity);
                self.timer_pending = false;
                self.strategy_cursor = self.authoritativeBarrier();
                self.strategy_decision_count = try std.math.add(u64, self.strategy_decision_count, 1);
                return self.submitOrderIntent(.{
                    .strategy_identity = self.strategy_identity,
                    .intent_sequence = self.strategy_decision_count,
                    .strategy_cursor = self.strategy_cursor,
                    .config_version = self.strategy_config_version,
                    .activation_identity = self.strategy_activation_identity,
                    .portfolio_identity = self.portfolio_identity,
                    .exchange_account_identity = self.exchange_account_identity,
                    .instrument_identity = self.instrument_identity,
                    .side = request.side,
                    .order_type = .limit,
                    .time_in_force = request.time_in_force,
                    .portfolio_reduce_only = request.portfolio_reduce_only,
                    .quantity = request.quantity,
                    .limit_price_micros = request.limit_price_micros,
                }, if (input.time_presence.monotonic) input.monotonic_time else 0, null);
            },
            .external_order_intent => |intent| {
                const previous_cursor = self.strategy_cursor;
                const trace_before = self.trace.len;
                const outcome = try self.submitOrderIntent(intent, if (input.time_presence.monotonic) input.monotonic_time else 0, previous_cursor);
                if (self.trace.len != trace_before and intent.strategy_cursor > previous_cursor) {
                    self.strategy_cursor = intent.strategy_cursor;
                    self.strategy_decision_count = try std.math.add(u64, self.strategy_decision_count, 1);
                }
                return outcome;
            },
            .strategy_intent_rejected => |rejection| {
                try self.trace.append(.strategy_intent_rejected, rejection.intent_sequence);
            },
            .oms_intent_group => |group| return self.handleOmsGroup(input, group),
            .oms_dispatch_batch => |batch| return self.handleOmsDispatch(input, batch),
            .oms_execution_report => |report| {
                const previous_reservation = try self.activeReservationAtoms();
                try self.oms.applyReport(report);
                const reflected_reservation = (try self.confirmPendingReplacement(report.order_id, report.report_id, if (input.time_presence.monotonic) input.monotonic_time else 0)) orelse previous_reservation;
                try self.adjustMarginBuffersForReservationChange(reflected_reservation);
                try self.trace.append(.oms_execution_report, report.report_id);
            },
            .oms_reconciliation_result => |result| {
                if (result.status == .confirmed_absent) return error.IncompleteReconciliationEvidence;
                const previous_reservation = try self.activeReservationAtoms();
                try self.oms.applyReconciliation(result);
                if (result.status == .unresolved and self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = result.reconciliation_id,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .latched,
                    .reason = .reconciliation_break,
                    .open = false,
                });
                const reflected_reservation = (try self.confirmPendingReplacement(result.order_id, result.reconciliation_id, if (input.time_presence.monotonic) input.monotonic_time else 0)) orelse previous_reservation;
                try self.adjustMarginBuffersForReservationChange(reflected_reservation);
                try self.trace.append(.oms_reconciliation_result, result.reconciliation_id);
            },
            .economic_fill => |fill| {
                const economic_time: ?u64 = if (input.time_presence.source) input.source_time else null;
                var retained = false;
                for (self.economic_projection.canonical_fill_evidence[0..self.economic_projection.canonical_fill_evidence_count]) |known| {
                    if (known.identity == fill.fill_id) {
                        retained = true;
                        break;
                    }
                }
                if (!retained) try self.admitEconomicTime(economic_time);
                const order = self.oms.orderById(fill.order_id) orelse return error.UnknownOrder;
                if (order.last_reconciliation_status == .confirmed_absent) return error.TerminalFactConflict;
                const instrument = order.instrument;
                const instrument_config = self.instrumentEntry(instrument) orelse return error.UnknownOmsInstrument;
                if (!self.settlementConsumersCompatible(instrument)) return error.AssetPrecisionUnsupported;
                var source: economics_module.FillSource = .{ .exchange_account = self.exchange_account_identity, .portfolio = self.portfolio_identity, .strategy = order.strategy_instance };
                source.core_payload_len = @intCast((try snapshot_codec.encodeBare(&source.core_payload_bytes, fill)).len);
                const changed = try self.applyEconomicProjectionWithSource(.{ .fill = .{
                    .identity = fill.fill_id,
                    .order_id = fill.order_id,
                    .side = if (order.side == .buy) .buy else .sell,
                    .quantity = .{ .instrument = instrument, .rules_version = instrument_config.rules.version, .lots = fill.quantity },
                    .price = .{ .instrument = instrument, .rules_version = instrument_config.rules.version, .ticks = fill.price_ticks },
                    .price_tick_value = .{ .asset = instrument_config.rules.settlement_asset, .atoms = instrument_config.margin.price_tick_atoms },
                    .base_atom_value = if (instrument_config.product == .spot) try self.baseAtomsPerLot(instrument_config) else .{ .asset = settlement_asset, .atoms = 0 },
                    .quantity_denominator = instrument_config.rules.quantity_denominator,
                    .quantity_numerator = instrument_config.rules.quantity_numerator,
                    .fee = .{ .asset = self.economic_projection.settlement_asset, .atoms = fill.fee_atoms },
                    .rebate = .{ .asset = self.economic_projection.settlement_asset, .atoms = fill.rebate_atoms },
                    .portfolio_margin_ppm = instrument_config.margin.internal_initial_margin_ppm,
                    .exchange_margin_ppm = instrument_config.margin.venue_initial_margin_ppm,
                    .product = instrument_config.product,
                } }, source);
                if (changed) {
                    for (self.economic_projection.applied_fills[0..self.economic_projection.applied_fill_count]) |known| if (known.fill.identity == fill.fill_id) {
                        try self.rememberEconomicTime(fill.fill_id, .fill, known.payload_digest, economic_time);
                        break;
                    };
                    try self.recalculateRisk(false);
                    try self.trace.append(.economic_fill, fill.fill_id);
                }
            },
            .funding_settlement => |funding| {
                const instrument_config = self.singleProductEntry(.isolated_linear_usdt) orelse return error.UnknownOmsInstrument;
                var source: economics_module.FundingSource = .{
                    .core_event_identity = input.identity,
                    .core_times = .{ .source = input.source_time, .receive = input.receive_time, .monotonic = input.monotonic_time, .wall = input.wall_time, .presence = input.time_presence },
                    .audit_time_utc_ns = if (input.time_presence.wall) input.wall_time else null,
                    .exchange_account = self.exchange_account_identity,
                    .portfolio = self.portfolio_identity,
                    .strategy = self.strategy_identity,
                    .instrument = instrument_config.instrument,
                    .rules_version = instrument_config.rules.version,
                    .exchange_time_utc_ns = if (input.time_presence.source) input.source_time else null,
                    .received_time_utc_ns = if (input.time_presence.receive) input.receive_time else 0,
                    .received_monotonic_ns = if (input.time_presence.monotonic) input.monotonic_time else 0,
                };
                source.core_payload_len = @intCast((try snapshot_codec.encodeBare(&source.core_payload_bytes, funding)).len);
                const changed = try self.applyFundingProjection(.{ .identity = funding.settlement_id, .portfolio_ownership_proven = true, .amount = .{ .asset = self.economic_projection.settlement_asset, .atoms = funding.amount_atoms } }, source);
                if (changed) {
                    try self.recalculateRisk(false);
                    if (self.economic_projection.reconciliation_break and self.operational_state.initialized) try self.applyOperationalGate(.{
                        .gate_identity = funding.settlement_id,
                        .target_identity = self.operational_state.target_identity,
                        .kind = .latched,
                        .reason = .reconciliation_break,
                        .open = false,
                    });
                    try self.trace.append(.funding_settlement, funding.settlement_id);
                }
            },
            .venue_forced_execution => |forced| {
                const instrument_config = self.singleProductEntry(.isolated_linear_usdt) orelse return error.UnknownOmsInstrument;
                if (!self.settlementConsumersCompatible(instrument_config.instrument)) return error.AssetPrecisionUnsupported;
                var source: economics_module.ForcedSource = .{
                    .core_event_identity = input.identity,
                    .core_times = .{ .source = input.source_time, .receive = input.receive_time, .monotonic = input.monotonic_time, .wall = input.wall_time, .presence = input.time_presence },
                    .accepted_input_digest = try acceptedOriginalDigest(.{ .core = input }),
                    .exchange_account = self.exchange_account_identity,
                    .portfolio = self.portfolio_identity,
                    .strategy = self.strategy_identity,
                    .instrument = instrument_config.instrument,
                    .rules_version = instrument_config.rules.version,
                };
                source.core_payload_len = @intCast((try snapshot_codec.encodeBare(&source.core_payload_bytes, forced)).len);
                const changed = try self.applyForcedProjection(.{
                    .identity = forced.execution_id,
                    .source_identity = forced.source_identity,
                    .side = if (forced.side == .buy) .buy else .sell,
                    .quantity = .{ .instrument = instrument_config.instrument, .rules_version = instrument_config.rules.version, .lots = forced.quantity },
                    .price = .{ .instrument = instrument_config.instrument, .rules_version = instrument_config.rules.version, .ticks = forced.price_ticks },
                    .price_tick_value = .{ .asset = instrument_config.rules.settlement_asset, .atoms = instrument_config.margin.price_tick_atoms },
                    .quantity_denominator = instrument_config.rules.quantity_denominator,
                    .quantity_numerator = instrument_config.rules.quantity_numerator,
                    .fee = .{ .asset = self.economic_projection.settlement_asset, .atoms = forced.fee_atoms },
                    .penalty = .{ .asset = self.economic_projection.settlement_asset, .atoms = forced.penalty_atoms },
                    .expected_realized_pnl_atoms = forced.expected_realized_pnl_atoms,
                    .portfolio_margin_ppm = instrument_config.margin.internal_initial_margin_ppm,
                    .exchange_margin_ppm = instrument_config.margin.venue_initial_margin_ppm,
                    .product = instrument_config.product,
                }, source);
                if (changed) {
                    if (self.operational_state.initialized) {
                        try self.applyOperationalGate(.{
                            .gate_identity = forced.execution_id,
                            .target_identity = self.operational_state.target_identity,
                            .kind = .latched,
                            .reason = .venue_forced_execution,
                            .open = false,
                        });
                    }
                    try self.recalculateRisk(false);
                    try self.trace.append(.venue_forced_execution, forced.execution_id);
                }
            },
            .economic_account_snapshot => |account_snapshot| {
                const changed = try self.applyEconomicProjection(.{ .account_snapshot = .{
                    .identity = account_snapshot.snapshot_id,
                    .balance = .{ .asset = self.economic_projection.settlement_asset, .atoms = account_snapshot.usdt_balance_atoms },
                    .spot_asset_atoms = account_snapshot.spot_asset_atoms,
                    .swap_position_quantity = account_snapshot.swap_position_quantity,
                    .margin = .{ .asset = self.economic_projection.settlement_asset, .atoms = account_snapshot.margin_atoms },
                } });
                if (changed) {
                    if (self.operational_state.initialized and self.economic_projection.reconciliation_break) {
                        try self.applyOperationalGate(.{
                            .gate_identity = account_snapshot.snapshot_id,
                            .target_identity = self.operational_state.target_identity,
                            .kind = .latched,
                            .reason = .reconciliation_break,
                            .open = false,
                        });
                    }
                    try self.trace.append(.economic_account_snapshot, account_snapshot.snapshot_id);
                }
            },
        }
        return null;
    }
};

fn zeroUnused(comptime T: type, storage: []T) void {
    @memset(storage, std.mem.zeroes(T));
}

/// Emits precisely the old canonicalized snapshot view without copying Core
/// or clearing arrays whose unused contents are not authoritative.
const CoreSnapshotEncodingPolicy = struct {
    pub fn fieldIsZero(comptime T: type, comptime name: []const u8) bool {
        return T == oms_module.Oms and std.mem.eql(u8, name, "command_count");
    }
    pub fn counter(value: anytype, comptime name: []const u8) usize {
        if (comptime fieldIsZero(@TypeOf(value.*), name)) return 0;
        if (comptime @TypeOf(value.*) == TradingShard and std.mem.eql(u8, name, "open_economic_fact_count")) return @intCast(@min(value.open_economic_fact_count, value.open_economic_facts.len));
        return @field(value.*, name);
    }
    fn mappedTail(comptime name: []const u8, comptime mappings: anytype) ?[]const u8 {
        inline for (mappings) |mapping| if (std.mem.eql(u8, name, mapping[0])) return mapping[1];
        return null;
    }
    pub fn tailCounter(comptime T: type, comptime name: []const u8) ?[]const u8 {
        if (T == TradingShard) return mappedTail(name, .{ .{ "fenced_strategy_instances", "fenced_strategy_count" }, .{ "canonical_ingress_cursors", "canonical_ingress_cursor_count" }, .{ "open_economic_facts", "open_economic_fact_count" }, .{ "economic_baseline_balances", "economic_baseline_balance_count" } });
        if (T == ReconciliationCursor) return mappedTail(name, .{.{ "balances", "balance_count" }});
        if (T == @FieldType(TradingShard, "asset_registry")) return mappedTail(name, .{.{ "entries", "count" }});
        if (T == @FieldType(TradingShard, "instrument_registry")) return mappedTail(name, .{.{ "entries", "count" }});
        if (T == @FieldType(TradingShard, "canonical_market")) return mappedTail(name, .{.{ "entries", "count" }});
        if (T == @FieldType(TradingShard, "trace")) return mappedTail(name, .{ .{ "events", "len" }, .{ "pinned", "pinned_len" } });
        if (T == @FieldType(TradingShard, "operational_state")) return mappedTail(name, .{ .{ "gates", "gate_count" }, .{ "command_history", "command_count" }, .{ "latches", "latch_count" } });
        if (T == @FieldType(TradingShard, "economic_projection")) return mappedTail(name, .{ .{ "reconciliation_break_identities", "reconciliation_break_count" }, .{ "seen", "seen_count" }, .{ "canonical_fill_evidence", "canonical_fill_evidence_count" }, .{ "applied_fills", "applied_fill_count" }, .{ "applied_fundings", "applied_funding_count" }, .{ "applied_forced_executions", "applied_forced_execution_count" }, .{ "applied_fill_totals", "applied_fill_total_count" }, .{ "treasury_native_assets", "treasury_native_asset_count" }, .{ "suspense_native_assets", "suspense_native_asset_count" }, .{ "ledger", "ledger_count" } });
        if (T == economics_module.Layer) return mappedTail(name, .{ .{ "native_assets", "native_asset_count" }, .{ "instrument_positions", "instrument_position_count" } });
        if (T == economics_module.LedgerTransaction) return mappedTail(name, .{.{ "postings", "posting_count" }});
        if (T == @FieldType(TradingShard, "canonical_account")) return mappedTail(name, .{ .{ "seen", "seen_count" }, .{ "balances", "balance_count" }, .{ "positions", "position_count" }, .{ "margins", "margin_count" } });
        if (T == cold.PendingCandidate) return mappedTail(name, .{.{ "original_bytes", "original_len" }});
        return null;
    }
    pub fn zeroValue(comptime T: type) T {
        if (T == @typeInfo(@FieldType(@FieldType(TradingShard, "canonical_account"), "seen")).array.child) return .{
            .identity = 0,
            .exchange_account = 0,
            .bootstrap = 0,
            .source_stream = 0,
            .source_sequence = 0,
            .value = .{ .balance = .{
                .asset = 0,
                .value = .{
                    .asset = 0,
                    .total = .{ .asset = 0, .atoms = 0 },
                    .available = .{ .asset = 0, .atoms = 0 },
                    .held = .{ .asset = 0, .atoms = 0 },
                },
            } },
        };
        if (T == @typeInfo(@FieldType(TradingShard, "canonical_ingress_cursors")).array.child) return .{
            .identity = .{ .stream = 0, .sequence = 0 },
            .event_type = .order_dispatch_result,
            .raw_digest = @splat(0),
            .payload_digest = @splat(0),
        };
        return std.mem.zeroes(T);
    }
};

fn canonicalizeSnapshotState(shard: *TradingShard) void {
    inline for (.{ "pending_history_candidate", "pending_safety_history_candidate" }) |field| {
        if (@field(shard, field)) |*pending| {
            if (pending.original_len <= pending.original_bytes.len) @memset(pending.original_bytes[pending.original_len..], 0);
        }
    }
    zeroUnused(asset_registry.Entry, shard.asset_registry.entries[shard.asset_registry.count..]);
    zeroUnused(instrument_registry.Entry, shard.instrument_registry.entries[shard.instrument_registry.count..]);
    zeroUnused(market_projection.InstrumentProjection, shard.canonical_market.entries[shard.canonical_market.count..]);
    zeroUnused(Fact, shard.trace.events[shard.trace.len..]);
    zeroUnused(Fact, shard.trace.pinned[shard.trace.pinned_len..]);
    zeroUnused(oms_module.Order, shard.oms.orders[shard.oms.order_count..]);
    shard.oms.command_count = 0;
    zeroUnused(oms_module.Command, shard.oms.commands[0..]);
    zeroUnused(oms_module.Command, shard.oms.command_history[shard.oms.command_history_count..]);
    for (shard.dispatch_ingress_history[shard.dispatch_ingress_history_count..]) |*entry| entry.* = .{
        .body = std.mem.zeroes(DispatchIngressBody),
        .cursor = .{ .identity = .{ .stream = 0, .sequence = 0 }, .raw_digest = @splat(0), .payload_digest = @splat(0) },
    };
    zeroUnused(oms_module.ExecutionReport, shard.oms.report_history[shard.oms.report_history_count..]);
    zeroUnused(oms_module.ReconciliationResult, shard.oms.reconciliation_history[shard.oms.reconciliation_history_count..]);
    zeroUnused(oms_module.SeenIntent, shard.oms.intent_history[shard.oms.intent_history_count..]);
    zeroUnused(oms_module.Tombstone, shard.oms.tombstones[shard.oms.tombstone_count..]);
    zeroUnused(operational.SafetyGateChange, shard.operational_state.gates[shard.operational_state.gate_count..]);
    zeroUnused(@TypeOf(shard.operational_state.command_history[0]), shard.operational_state.command_history[shard.operational_state.command_count..]);
    zeroUnused(operational.Latch, shard.operational_state.latches[shard.operational_state.latch_count..]);
    zeroUnused(u64, shard.economic_projection.reconciliation_break_identities[shard.economic_projection.reconciliation_break_count..]);
    zeroUnused(@TypeOf(shard.economic_projection.seen[0]), shard.economic_projection.seen[shard.economic_projection.seen_count..]);
    zeroUnused(economics_module.CanonicalFactEvidence, shard.economic_projection.canonical_fill_evidence[shard.economic_projection.canonical_fill_evidence_count..]);
    zeroUnused(economics_module.AppliedForcedExecution, shard.economic_projection.applied_forced_executions[shard.economic_projection.applied_forced_execution_count..]);
    zeroUnused(economics_module.AppliedFunding, shard.economic_projection.applied_fundings[shard.economic_projection.applied_funding_count..]);
    zeroUnused(OpenEconomicFact, shard.open_economic_facts[@min(shard.open_economic_fact_count, shard.open_economic_facts.len)..]);
    zeroUnused(canonical.AssetAmount, shard.economic_baseline_balances[shard.economic_baseline_balance_count..]);
    if (shard.reconciliation_cursor) |*cursor| zeroUnused(canonical.AssetAmount, cursor.balances[cursor.balance_count..]);
    if (shard.pending_reconciliation_window) |*window| {
        if (window.previous_cursor) |*cursor| zeroUnused(canonical.AssetAmount, cursor.balances[cursor.balance_count..]);
    }
    zeroUnused(economics_module.AppliedFill, shard.economic_projection.applied_fills[shard.economic_projection.applied_fill_count..]);
    zeroUnused(economics_module.OrderFillTotal, shard.economic_projection.applied_fill_totals[shard.economic_projection.applied_fill_total_count..]);
    zeroUnused(economics_module.NativeAssetState, shard.economic_projection.portfolio.native_assets[shard.economic_projection.portfolio.native_asset_count..]);
    zeroUnused(economics_module.NativeAssetState, shard.economic_projection.exchange.native_assets[shard.economic_projection.exchange.native_asset_count..]);
    zeroUnused(economics_module.InstrumentPosition, shard.economic_projection.portfolio.instrument_positions[shard.economic_projection.portfolio.instrument_position_count..]);
    zeroUnused(economics_module.InstrumentPosition, shard.economic_projection.exchange.instrument_positions[shard.economic_projection.exchange.instrument_position_count..]);
    zeroUnused(canonical.AssetAmount, shard.economic_projection.treasury_native_assets[shard.economic_projection.treasury_native_asset_count..]);
    zeroUnused(canonical.AssetAmount, shard.economic_projection.suspense_native_assets[shard.economic_projection.suspense_native_asset_count..]);
    for (shard.economic_projection.ledger[0..shard.economic_projection.ledger_count]) |*transaction|
        zeroUnused(economics_module.LedgerPosting, transaction.postings[transaction.posting_count..]);
    zeroUnused(economics_module.LedgerTransaction, shard.economic_projection.ledger[shard.economic_projection.ledger_count..]);
    zeroUnused(u128, shard.fenced_strategy_instances[shard.fenced_strategy_count..]);
    for (shard.canonical_account.seen[shard.canonical_account.seen_count..]) |*observation| observation.* = .{
        .identity = 0,
        .exchange_account = 0,
        .bootstrap = 0,
        .source_stream = 0,
        .source_sequence = 0,
        .value = .{ .balance = .{
            .asset = 0,
            .value = .{
                .asset = 0,
                .total = .{ .asset = 0, .atoms = 0 },
                .available = .{ .asset = 0, .atoms = 0 },
                .held = .{ .asset = 0, .atoms = 0 },
            },
        } },
    };
    zeroUnused(canonical.AccountBalance, shard.canonical_account.balances[shard.canonical_account.balance_count..]);
    zeroUnused(canonical.AccountPosition, shard.canonical_account.positions[shard.canonical_account.position_count..]);
    zeroUnused(canonical.AccountMargin, shard.canonical_account.margins[shard.canonical_account.margin_count..]);
    for (shard.canonical_ingress_cursors[shard.canonical_ingress_cursor_count..]) |*identity| identity.* = .{
        .identity = .{ .stream = 0, .sequence = 0 },
        .event_type = .order_dispatch_result,
        .raw_digest = @splat(0),
        .payload_digest = @splat(0),
    };
}

fn validateArchiveCommitInput(shard: *const TradingShard, original: ?ArchiveCommitInput, barrier: u64, kind: EventKind, payload: CorePayload) !void {
    const input = original orelse return error.InvalidSnapshotState;
    const sequence = std.math.add(u64, barrier, 1) catch return error.InvalidSnapshotState;
    const fact = shard.trace.factAt(sequence) orelse return error.InvalidSnapshotState;
    if (fact.kind != kind or fact.identity != input.identity or !fact.input_first or input.times.presence.reserved != 0) return error.InvalidSnapshotState;
    const reconstructed: CanonicalEvent = .{ .core = .{ .identity = input.identity, .source_time = input.times.source, .receive_time = input.times.receive, .monotonic_time = input.times.monotonic, .wall_time = input.times.wall, .time_presence = input.times.presence, .payload = payload } };
    const digest = TradingShard.acceptedOriginalDigest(reconstructed) catch return error.InvalidSnapshotState;
    if (!std.mem.eql(u8, &digest, &fact.input_digest)) return error.InvalidSnapshotState;
}

fn validateSnapshotState(shard: *const TradingShard) !void {
    if (shard.deferred_history_admission_count > shard.deferred_history_admissions.len) return error.InvalidSnapshotState;
    for (shard.deferred_history_admissions[0..shard.deferred_history_admission_count], 0..) |admission, index| {
        if (admission.identity.stream == 0 or admission.identity.sequence == 0 or admission.fact_sequence == 0 or
            (admission.event_type != @intFromEnum(canonical.EventType.order_dispatch_result) and
                admission.event_type != @intFromEnum(canonical.EventType.fill) and
                admission.event_type != @intFromEnum(canonical.EventType.execution_report) and
                admission.event_type != @intFromEnum(canonical.EventType.order_reconciliation_result))) return error.InvalidSnapshotState;
        const fact = shard.trace.factAt(admission.fact_sequence) orelse return error.InvalidSnapshotState;
        if (fact.kind != .canonical_history_deferred or fact.identity != admission.identity.sequence or
            !std.mem.eql(u8, &fact.input_digest, &admission.original_input_digest) or std.mem.allEqual(u8, &admission.payload_digest, 0)) return error.InvalidSnapshotState;
        for (shard.deferred_history_admissions[0..index]) |prior|
            if (std.meta.eql(prior.identity, admission.identity)) return error.InvalidSnapshotState;
    }
    if (shard.dispatch_ingress_history_count > shard.dispatch_ingress_history.len) return error.InvalidSnapshotState;
    for (shard.dispatch_ingress_history[0..shard.dispatch_ingress_history_count], 0..) |entry, index| {
        if (entry.body.command == 0 or entry.body.account != shard.exchange_account_identity or entry.cursor.identity.stream == 0 or entry.cursor.identity.sequence == 0 or
            !std.mem.eql(u8, &entry.body.canonical_digest, &entry.cursor.payload_digest)) return error.InvalidSnapshotState;
        const expected_digest = try canonicalPayloadDigest(.{ .order_dispatch_result = .{ .command = entry.body.command, .state = entry.body.state } });
        if (!std.mem.eql(u8, &entry.body.canonical_digest, &expected_digest)) return error.InvalidSnapshotState;
        var retained = false;
        for (shard.oms.command_history[0..shard.oms.command_history_count]) |command| if (command.command_id == entry.body.command) {
            const instrument = shard.instrumentEntry(command.instrument) orelse return error.InvalidSnapshotState;
            if (instrument.venue != entry.body.venue) return error.InvalidSnapshotState;
            retained = true;
            break;
        };
        if (!retained) return error.InvalidSnapshotState;
        for (shard.dispatch_ingress_history[0..index]) |prior|
            if (prior.body.command == entry.body.command and prior.body.state == entry.body.state) return error.InvalidSnapshotState;
    }

    shard.trace.validate() catch return error.InvalidSnapshotState;
    if (shard.next_history_pending_id == 0) return error.InvalidSnapshotState;
    inline for (.{ .{ "pending_history_candidate", "pending_history_member_index" }, .{ "pending_safety_history_candidate", "pending_safety_history_member_index" } }) |fields| {
        if (@field(shard, fields[0])) |pending| {
            var pending_bytes: [cold.max_encoded_size]u8 = undefined;
            _ = cold.encodeCompact(&pending_bytes, &pending) catch return error.InvalidSnapshotState;
            const root = shard.business_history_root orelse return error.InvalidSnapshotState;
            if (pending.request.pending_id >= shard.next_history_pending_id or
                !std.meta.eql(pending.request.key.origin, root.origin) or pending.request.epoch != root.epoch or pending.request.barrier != root.barrier or
                !std.mem.eql(u8, &pending.request.root_digest, &root.root_digest)) return error.InvalidSnapshotState;
            const original = decodeStableInput(pending.originalRecord()) catch return error.InvalidSnapshotState;
            if (original == .core and !pending.original_was_admissible) return error.InvalidSnapshotState;
            if (comptime std.mem.eql(u8, fields[0], "pending_safety_history_candidate")) {
                if (!TradingShard.historySafetyInput(original)) return error.InvalidSnapshotState;
            }
            const semantic = (shard.historySemantic(original, @field(shard, fields[1])) catch return error.InvalidSnapshotState) orelse return error.InvalidSnapshotState;
            if (!std.meta.eql(semantic.identity, pending.request.key.identity) or !std.mem.eql(u8, &semantic.digest, &pending.request.candidate_payload_digest)) return error.InvalidSnapshotState;
            const fact = shard.trace.factAt(pending.original.sequence) orelse return error.InvalidSnapshotState;
            if (fact.kind != .history_candidate_started or
                (fact.reject_reason != .none and fact.reject_reason != .stale_canonical_source) or
                pending.original_was_admissible != (fact.reject_reason == .none)) return error.InvalidSnapshotState;
        } else if (@field(shard, fields[1]) != null) return error.InvalidSnapshotState;
    }
    if (shard.pending_history_candidate != null and shard.pending_safety_history_candidate != null and
        shard.pending_history_candidate.?.request.pending_id == shard.pending_safety_history_candidate.?.request.pending_id) return error.InvalidSnapshotState;
    if (shard.history_conflict_latched and ((shard.pending_history_candidate == null and shard.pending_safety_history_candidate == null) or !shard.oms.recovery_only or
        shard.operational_state.effectiveTradingAuthority())) return error.InvalidSnapshotState;
    if (shard.business_history_root) |root| {
        history.validateRoot(root) catch return error.InvalidSnapshotState;
        const kind = shard.last_business_archive_kind orelse return error.InvalidSnapshotState;
        const receipt = switch (kind) {
            .order => (shard.last_order_archive orelse return error.InvalidSnapshotState).receipt,
            .fill => (shard.last_fill_archive orelse return error.InvalidSnapshotState).receipt,
            .forced => (shard.last_forced_archive orelse return error.InvalidSnapshotState).receipt,
            .control => (shard.last_control_archive orelse return error.InvalidSnapshotState).receipt,
            .funding => (shard.last_funding_archive orelse return error.InvalidSnapshotState).receipt,
            .reconciliation => (shard.last_reconciliation_archive orelse return error.InvalidSnapshotState).receipt,
        };
        const qualification_digest = switch (kind) {
            .order => shard.last_order_archive.?.qualification_digest,
            .fill => shard.last_fill_archive.?.qualification_digest,
            .forced => shard.last_forced_archive.?.qualification_digest,
            .control => shard.last_control_archive.?.qualification_digest,
            .funding => shard.last_funding_archive.?.qualification_digest,
            .reconciliation => shard.last_reconciliation_archive.?.qualification_digest,
        };
        const checkpoint = shard.checkpoint orelse return error.InvalidSnapshotState;
        if (!std.meta.eql(root, receipt.root) or root.origin.stream.domain != .decision_log or
            root.origin.stream.id != checkpoint.stream or root.origin.account != shard.exchange_account_identity or
            root.barrier >= shard.authoritativeBarrier() or
            !std.mem.eql(u8, &root.qualification_digest, &qualification_digest)) return error.InvalidSnapshotState;
        if (shard.last_order_archive) |commit| if (shard.oms.orderById(commit.order_id) != null) return error.InvalidSnapshotState;
    } else if (shard.last_order_archive != null or shard.last_fill_archive != null or shard.last_funding_archive != null or shard.last_reconciliation_archive != null or shard.last_business_archive_kind != null) return error.InvalidSnapshotState;
    if (shard.coordinator_history_origin) |origin| {
        if (origin.account != shard.exchange_account_identity or origin.stream.domain != .control or origin.stream.id == 0 or shard.coordinator_binding_fact == 0) return error.InvalidSnapshotState;
        const fact = shard.trace.factAt(shard.coordinator_binding_fact) orelse return error.InvalidSnapshotState;
        if (fact.kind != .account_coordinator_bound or fact.identity != origin.stream.id) return error.InvalidSnapshotState;
    } else if (shard.coordinator_binding_fact != 0 or shard.last_forced_archive != null) return error.InvalidSnapshotState;
    if (shard.last_forced_archive) |commit| {
        try validateArchiveCommitInput(shard, shard.last_forced_archive_input, commit.receipt.root.barrier, .forced_archive_committed, .{ .forced_archive_committed = commit });
    } else if (shard.last_forced_archive_input != null) return error.InvalidSnapshotState;
    if (shard.last_control_archive) |commit| {
        try validateArchiveCommitInput(shard, shard.last_control_archive_input, commit.receipt.root.barrier, .control_archive_committed, .{ .control_archive_committed = commit });
        if (shard.archived_control_records == 0) return error.InvalidSnapshotState;
    } else if (shard.last_control_archive_input != null or shard.archived_control_records != 0) return error.InvalidSnapshotState;
    if (shard.last_funding_archive) |commit| {
        try validateArchiveCommitInput(shard, shard.last_funding_archive_input, commit.receipt.root.barrier, .funding_archive_committed, .{ .funding_archive_committed = commit });
    } else if (shard.last_funding_archive_input != null) return error.InvalidSnapshotState;
    if (shard.last_reconciliation_archive) |commit| {
        try validateArchiveCommitInput(shard, shard.last_reconciliation_archive_input, commit.receipt.root.barrier, .reconciliation_archive_committed, .{ .reconciliation_archive_committed = commit });
    } else if (shard.last_reconciliation_archive_input != null) return error.InvalidSnapshotState;
    if (shard.reconciliation_cursor) |cursor| {
        const committed = shard.last_reconciliation_archive orelse return error.InvalidSnapshotState;
        const total = shard.totalEconomicFactCount() catch return error.InvalidSnapshotState;
        if (cursor.identity != committed.window_id or cursor.through_utc_ns < shard.economic_baseline_utc_ns or
            cursor.balance_count == 0 or cursor.balance_count > cursor.balances.len or cursor.closed_economic_fact_count > total or
            shard.open_economic_fact_count != total - cursor.closed_economic_fact_count or
            !std.mem.eql(u8, &cursor.root_digest, &committed.receipt.root.root_digest)) return error.InvalidSnapshotState;
        for (cursor.balances[0..cursor.balance_count], 0..) |balance, index| {
            if (shard.asset_registry.get(balance.asset) == null) return error.InvalidSnapshotState;
            for (cursor.balances[0..index]) |previous| if (previous.asset == balance.asset) return error.InvalidSnapshotState;
        }
        if (shard.open_economic_unknown_time_count != 0 or
            (shard.open_economic_fact_count != 0 and shard.open_economic_min_utc_ns <= cursor.through_utc_ns)) return error.InvalidSnapshotState;
        if (shard.open_economic_fact_count == 0 and !shard.economic_projection.reconciliation_break) {
            var evidence: canonical.AccountEconomicEvidence = .{ .exchange_account = shard.exchange_account_identity, .scope = .spot_and_isolated_linear_usdt, .from_utc_ns = cursor.through_utc_ns, .through_utc_ns = cursor.through_utc_ns, .source = .{ .stream = 0, .sequence = 0, .digest = @splat(0) }, .balances = cursor.balances, .balance_count = cursor.balance_count };
            for (cursor.balances[0..cursor.balance_count], 0..) |balance, index| evidence.asset_versions[index] = (shard.asset_registry.get(balance.asset) orelse return error.InvalidSnapshotState).definition.version;
            if (!shard.reconciliationClosingMatches(evidence)) return error.InvalidSnapshotState;
        }
    } else {
        if (shard.last_reconciliation_archive != null or shard.open_economic_fact_count != (shard.totalEconomicFactCount() catch return error.InvalidSnapshotState))
            return error.InvalidSnapshotState;
    }
    if (shard.open_economic_commitment_sequence != 0) {
        const digest = shard.openEconomicFactsDigest();
        const fact = shard.trace.factAt(shard.open_economic_commitment_sequence) orelse return error.InvalidSnapshotState;
        const committed_digest = fact.economic_open_digest orelse return error.InvalidSnapshotState;
        if (fact.kind != .economic_open_commitment or fact.identity != shard.open_economic_fact_count or !std.mem.eql(u8, &digest, &committed_digest)) return error.InvalidSnapshotState;
    } else if (shard.open_economic_fact_count != 0 or shard.reconciliation_cursor != null) return error.InvalidSnapshotState;
    if (shard.open_economic_unknown_time_count > shard.open_economic_fact_count or
        shard.open_economic_min_utc_ns > shard.open_economic_max_utc_ns or
        (shard.open_economic_fact_count == 0 and (shard.open_economic_min_utc_ns != 0 or shard.open_economic_max_utc_ns != 0 or shard.open_economic_unknown_time_count != 0))) return error.InvalidSnapshotState;
    if (shard.open_economic_fact_count <= shard.open_economic_facts.len) {
        var unknown: u64 = 0;
        var earliest: u64 = 0;
        var latest: u64 = 0;
        for (shard.open_economic_facts[0..@intCast(shard.open_economic_fact_count)], 0..) |fact, index| {
            if (fact.identity == 0 or std.mem.allEqual(u8, &fact.digest, 0)) return error.InvalidSnapshotState;
            for (shard.open_economic_facts[0..index]) |previous| if (previous.identity == fact.identity and previous.kind == fact.kind) return error.InvalidSnapshotState;
            if (std.mem.allEqual(u8, &fact.accepted_input_digest, 0)) return error.InvalidSnapshotState;
            switch (fact.kind) {
                .forced => for (shard.economic_projection.applied_forced_executions[0..shard.economic_projection.applied_forced_execution_count]) |applied| {
                    if (applied.forced.identity == fact.identity and (!std.mem.eql(u8, &applied.payload_digest, &fact.digest) or
                        !std.mem.eql(u8, &applied.source.accepted_input_digest, &fact.accepted_input_digest))) return error.InvalidSnapshotState;
                },
                .funding => for (shard.economic_projection.applied_fundings[0..shard.economic_projection.applied_funding_count]) |applied| {
                    if (applied.funding.identity == fact.identity and (!std.mem.eql(u8, &applied.payload_digest, &fact.digest) or
                        !std.meta.eql(applied.source.exchange_time_utc_ns, fact.economic_time_utc_ns))) return error.InvalidSnapshotState;
                },
                .fill => for (shard.economic_projection.applied_fills[0..shard.economic_projection.applied_fill_count]) |applied| {
                    if (applied.fill.identity == fact.identity and !std.mem.eql(u8, &applied.payload_digest, &fact.digest)) return error.InvalidSnapshotState;
                },
            }
            const time = fact.economic_time_utc_ns orelse 0;
            if (time == 0) unknown += 1 else {
                if (earliest == 0 or time < earliest) earliest = time;
                latest = @max(latest, time);
            }
        }
        if (unknown != shard.open_economic_unknown_time_count or earliest != shard.open_economic_min_utc_ns or latest != shard.open_economic_max_utc_ns) return error.InvalidSnapshotState;
    }
    if (shard.pending_reconciliation_window) |window| {
        if (window.original.event != .account_reconciliation_result or window.original.event.account_reconciliation_result.identity != window.identity or
            !std.meta.eql(window.previous_cursor, shard.reconciliation_cursor) or
            window.economic_fact_count > (shard.totalEconomicFactCount() catch return error.InvalidSnapshotState)) return error.InvalidSnapshotState;
        const evidence = window.original.event.account_reconciliation_result.account_economics orelse return error.InvalidSnapshotState;
        if (evidence.balance_count == 0 or evidence.balance_count > evidence.balances.len or evidence.before_balance_count > evidence.before_balances.len or
            evidence.covered_economic_fact_count > evidence.facts.len or evidence.query_count > evidence.query_sources.len or
            evidence.from_utc_ns != (if (shard.reconciliation_cursor) |cursor| cursor.through_utc_ns else shard.economic_baseline_utc_ns) or
            evidence.through_utc_ns < evidence.from_utc_ns or !std.meta.eql(evidence.source, window.original.envelope.raw_evidence) or
            window.original.envelope.times.source_utc_ns != evidence.through_utc_ns) return error.InvalidSnapshotState;
        if (!shard.reconciliationAnchorMatches(evidence) or
            (window.economic_fact_count == (shard.totalEconomicFactCount() catch return error.InvalidSnapshotState) and !shard.reconciliationClosingMatches(evidence))) return error.InvalidSnapshotState;
    }
    if (shard.trace.len != 0 and !shard.trace.events[0].input_first) return error.InvalidSnapshotState;
    var group_digest: [32]u8 = @splat(0);
    for (shard.trace.events[0..shard.trace.len]) |fact| {
        if (std.mem.allEqual(u8, &fact.input_digest, 0)) return error.InvalidSnapshotState;
        if (fact.input_first) group_digest = fact.input_digest else if (!std.mem.eql(u8, &group_digest, &fact.input_digest)) return error.InvalidSnapshotState;
    }
    for (shard.trace.pinned[0..shard.trace.pinned_len]) |fact| if (std.mem.allEqual(u8, &fact.input_digest, 0)) return error.InvalidSnapshotState;
    if (shard.checkpoint) |receipt| {
        if (receipt.version != 1 or receipt.stream == 0 or receipt.generation == 0 or receipt.first_sequence == 0 or receipt.first_sequence > receipt.barrier or
            std.mem.allEqual(u8, &receipt.archive_root, 0) or receipt.barrier != shard.trace.base_sequence or
            !std.mem.eql(u8, &receipt.history_head, &shard.trace.base_history_head) or
            !std.mem.eql(u8, &receipt.input_head, &shard.trace.base_input_head) or
            !std.mem.eql(u8, &receipt.pinned_fact_root, &shard.trace.pinned_root) or
            !std.mem.eql(u8, &receipt.checkpoint_root, &checkpointRoot(receipt))) return error.InvalidSnapshotState;
    } else if (shard.trace.base_sequence != 0 or shard.trace.pinned_len != 0 or
        !std.mem.allEqual(u8, &shard.trace.base_history_head, 0) or !std.mem.allEqual(u8, &shard.trace.base_input_head, 0)) return error.InvalidSnapshotState;
    if (shard.economic_fault_count != 0 and (!shard.oms.recovery_only or shard.economic_fault_evidence.stream == 0 or shard.economic_fault_evidence.sequence == 0)) return error.InvalidSnapshotState;
    if (shard.trace.len > shard.trace.events.len or
        shard.instrument_registry.count > shard.instrument_registry.entries.len or
        shard.canonical_market.count > shard.canonical_market.entries.len or
        shard.oms.order_count > oms_module.max_orders or
        shard.oms.command_count > shard.oms.commands.len or
        shard.oms.command_history_count > shard.oms.command_history.len or
        shard.oms.report_history_count > shard.oms.report_history.len or
        shard.oms.reconciliation_history_count > shard.oms.reconciliation_history.len or
        shard.oms.intent_history_count > shard.oms.intent_history.len or
        shard.oms.tombstone_count > shard.oms.tombstones.len or
        shard.economic_projection.seen_count > shard.economic_projection.seen.len or
        shard.economic_projection.canonical_fill_evidence_count > shard.economic_projection.canonical_fill_evidence.len or
        shard.economic_baseline_balance_count > shard.economic_baseline_balances.len or
        shard.economic_projection.applied_funding_count > shard.economic_projection.applied_fundings.len or
        shard.economic_projection.applied_fill_count > shard.economic_projection.applied_fills.len or
        shard.economic_projection.applied_fill_total_count > shard.economic_projection.applied_fill_totals.len or
        shard.economic_projection.ledger_count > shard.economic_projection.ledger.len or
        shard.economic_projection.reconciliation_break_count > shard.economic_projection.reconciliation_break_identities.len or
        shard.economic_projection.portfolio.native_asset_count > economics_module.max_native_assets or
        shard.economic_projection.exchange.native_asset_count > economics_module.max_native_assets or
        shard.economic_projection.portfolio.instrument_position_count > economics_module.max_instrument_positions or
        shard.economic_projection.exchange.instrument_position_count > economics_module.max_instrument_positions or
        shard.economic_projection.treasury_native_asset_count > economics_module.max_native_assets or
        shard.economic_projection.suspense_native_asset_count > economics_module.max_native_assets or
        shard.operational_state.command_count > operational.max_commands or
        shard.operational_state.gate_count > operational.max_gates or
        shard.operational_state.latch_count > operational.max_latches or
        shard.canonical_account.seen_count > shard.canonical_account.seen.len or
        shard.canonical_account.balance_count > shard.canonical_account.balances.len or
        shard.canonical_account.position_count > shard.canonical_account.positions.len or
        shard.canonical_account.margin_count > shard.canonical_account.margins.len or
        shard.canonical_ingress_cursor_count > shard.canonical_ingress_cursors.len or
        shard.fenced_strategy_count > shard.fenced_strategy_instances.len)
        return error.InvalidSnapshotState;
    try shard.asset_registry.validate();
    try shard.canonical_account.validate();
    for (shard.control_fact_sequences[0..shard.operational_state.command_count], 0..) |sequence, index| {
        const fact = shard.trace.factAt(sequence) orelse return error.InvalidSnapshotState;
        if (fact.kind != .control_command_applied) return error.InvalidSnapshotState;
        for (shard.control_fact_sequences[0..index]) |previous| if (previous == sequence) return error.InvalidSnapshotState;
    }
    if (shard.host_activation_fact_sequence != 0) {
        const fact = shard.trace.factAt(shard.host_activation_fact_sequence) orelse return error.InvalidSnapshotState;
        if (fact.kind != .host_activated or shard.host_activation_identity == 0) return error.InvalidSnapshotState;
    }
    if (shard.asset_configuration_failed and !shard.oms.recovery_only) return error.InvalidSnapshotState;
    for (shard.asset_registry.entries[0..shard.asset_registry.count]) |entry| {
        if (entry.barrier > shard.authoritativeBarrier() or (shard.trace.factAt(entry.barrier) orelse return error.InvalidSnapshotState).kind != .asset_definition_activated)
            return error.InvalidSnapshotState;
    }
    try shard.instrument_registry.validate();
    if (shard.authority_control_barrier != 0) {
        const command = shard.controlCommandAtBarrier(shard.authority_control_barrier) orelse return error.InvalidSnapshotState;
        if (!changesTradingAuthorization(command.kind)) return error.InvalidSnapshotState;
    }
    for (shard.instrument_registry.entries[0..shard.instrument_registry.count]) |entry| {
        if (entry.rules_barrier == 0 or entry.rules_barrier > shard.authoritativeBarrier() or
            (shard.trace.factAt(entry.rules_barrier) orelse return error.InvalidSnapshotState).kind != .instrument_rules_activated)
            return error.InvalidSnapshotState;
        if (entry.capability) |profile| {
            if (entry.capability_barrier == 0 or entry.capability_barrier > shard.authoritativeBarrier() or
                (shard.trace.factAt(entry.capability_barrier) orelse return error.InvalidSnapshotState).kind != .capability_profile_activated or
                profile.exchange_account != shard.exchange_account_identity)
                return error.InvalidSnapshotState;
        }
        if (entry.margin_configured and (entry.margin_barrier == 0 or entry.margin_barrier > shard.authoritativeBarrier() or
            (shard.trace.factAt(entry.margin_barrier) orelse return error.InvalidSnapshotState).kind != .margin_rules_activated))
            return error.InvalidSnapshotState;
        if (entry.trading_version != 0) {
            const fact = shard.trace.factAt(entry.trading_barrier) orelse return error.InvalidSnapshotState;
            if (entry.trading_barrier > shard.authoritativeBarrier() or
                (fact.kind != .instrument_trading_authorized and fact.kind != .capability_profile_activated) or
                (fact.kind == .capability_profile_activated and entry.trading_version != 1)) return error.InvalidSnapshotState;
        }
    }
    for (shard.oms.orders[0..shard.oms.order_count], 0..) |order, index| {
        if (order.id == 0) return error.InvalidSnapshotState;
        for (shard.oms.orders[0..index]) |previous|
            if (previous.id == order.id) return error.InvalidSnapshotState;
    }
    for (shard.oms.command_history[0..shard.oms.command_history_count]) |command| {
        const decision = command.risk_decision_identity;
        const reservation = command.reservation_identity;
        if (decision == 0 and reservation == 0) continue; // legacy, never qualified to send
        if (decision == 0 or reservation == 0 or decision >= reservation or reservation > shard.authoritativeBarrier())
            return error.InvalidSnapshotState;
        const needs_facts = shard.commandNeedsDispatchFacts(command.order_id);
        if (needs_facts) {
            const decision_fact = shard.trace.factAt(decision) orelse return error.InvalidSnapshotState;
            const reservation_fact = shard.trace.factAt(reservation) orelse return error.InvalidSnapshotState;
            if (decision_fact.kind != .risk_accepted or reservation_fact.kind != .risk_reservation_created or
                decision_fact.identity != command.intent_sequence or reservation_fact.identity != command.intent_sequence)
                return error.InvalidSnapshotState;
        }
        const refs = command.authority;
        const typed_refs = .{
            .{ refs.trading_authorization, EventKind.control_command_applied },
            .{ refs.primary_lease, EventKind.primary_lease_granted },
            .{ refs.risk_lease, EventKind.risk_lease_granted },
            .{ refs.capability, EventKind.capability_profile_activated },
            .{ refs.instrument_rules, EventKind.instrument_rules_activated },
            .{ refs.margin_rules, EventKind.margin_rules_activated },
            .{ refs.config, EventKind.strategy_activated },
        };
        inline for (typed_refs) |pair| {
            const ref = pair[0];
            const kind = pair[1];
            if (ref.barrier == 0) {
                if (ref.identity != 0 or ref.version != 0) return error.InvalidSnapshotState;
            } else {
                if (ref.barrier > shard.authoritativeBarrier() or ref.identity == 0 or ref.version == 0) return error.InvalidSnapshotState;
                if (needs_facts and (shard.trace.factAt(ref.barrier) orelse return error.InvalidSnapshotState).kind != kind) return error.InvalidSnapshotState;
            }
        }
        const trading_ref = refs.instrument_trading;
        if (trading_ref.barrier == 0) {
            if (trading_ref.identity != 0 or trading_ref.version != 0) return error.InvalidSnapshotState;
        } else {
            if (trading_ref.barrier > shard.authoritativeBarrier() or trading_ref.identity == 0 or trading_ref.version == 0) return error.InvalidSnapshotState;
            if (needs_facts) {
                const fact = shard.trace.factAt(trading_ref.barrier) orelse return error.InvalidSnapshotState;
                if (fact.identity != trading_ref.identity or
                    (fact.kind != .instrument_trading_authorized and fact.kind != .capability_profile_activated) or
                    (fact.kind == .capability_profile_activated and trading_ref.version != 1)) return error.InvalidSnapshotState;
            }
        }
        if (needs_facts and refs.trading_authorization.barrier != 0) {
            const control = shard.controlCommandAtBarrier(refs.trading_authorization.barrier) orelse return error.InvalidSnapshotState;
            if (!changesTradingAuthorization(control.kind) or
                refs.trading_authorization.identity != control.command_identity or
                refs.trading_authorization.version != (std.math.add(u64, control.expected_version, 1) catch return error.InvalidSnapshotState))
                return error.InvalidSnapshotState;
        }
        if (needs_facts and refs.capability.barrier != 0 and (shard.trace.factAt(refs.capability.barrier) orelse return error.InvalidSnapshotState).identity != refs.capability.identity)
            return error.InvalidSnapshotState;
        if (needs_facts and refs.instrument_rules.barrier != 0 and (shard.trace.factAt(refs.instrument_rules.barrier) orelse return error.InvalidSnapshotState).identity != refs.instrument_rules.identity)
            return error.InvalidSnapshotState;
        if (needs_facts and refs.margin_rules.barrier != 0 and (shard.trace.factAt(refs.margin_rules.barrier) orelse return error.InvalidSnapshotState).identity != refs.margin_rules.identity)
            return error.InvalidSnapshotState;
        if (refs.dispatch_deadline_monotonic_ns != 0 and
            (refs.deadline_barrier == 0 or refs.deadline_barrier > shard.authoritativeBarrier()))
            return error.InvalidSnapshotState;
        if (refs.exchange_account != 0 and refs.exchange_account != shard.exchange_account_identity)
            return error.InvalidSnapshotState;
        if (refs.virtual_portfolio != 0 and refs.virtual_portfolio != shard.portfolio_identity)
            return error.InvalidSnapshotState;
    }
    for (shard.economic_projection.ledger[0..shard.economic_projection.ledger_count]) |transaction|
        if (transaction.posting_count > transaction.postings.len) return error.InvalidSnapshotState;
    try shard.economic_projection.assertClosed();
    for (shard.economic_projection.applied_fill_totals[0..shard.economic_projection.applied_fill_total_count]) |total| {
        const order = shard.oms.orderById(total.order_id) orelse return error.InvalidSnapshotState;
        if (total.quantity > order.quantity) return error.InvalidSnapshotState;
    }
    if (shard.asset_registry.get(shard.economic_projection.settlement_asset) != null)
        try shard.checkEconomicRanges();
}

const StableInputTag = enum(u8) { core = 1, venue = 2 };

const StableTimes = struct {
    source: u64,
    receive: u64,
    monotonic: u64,
    wall: u64,
    presence: journal.TimePresence,
};

fn stableTimes(input: CanonicalEvent) StableTimes {
    return switch (input) {
        .core => |event| .{
            .source = event.source_time,
            .receive = event.receive_time,
            .monotonic = event.monotonic_time,
            .wall = event.wall_time,
            .presence = event.time_presence,
        },
        .venue => |record| .{
            .source = record.envelope.times.source_utc_ns orelse 0,
            .receive = record.envelope.times.receive_utc_ns orelse 0,
            .monotonic = record.envelope.times.monotonic_ns orelse 0,
            .wall = record.envelope.times.audit_utc_ns orelse 0,
            .presence = .{
                .source = record.envelope.times.source_utc_ns != null,
                .receive = record.envelope.times.receive_utc_ns != null,
                .monotonic = record.envelope.times.monotonic_ns != null,
                .wall = record.envelope.times.audit_utc_ns != null,
            },
        },
    };
}

fn encodeStableInput(destination: []u8, input: CanonicalEvent) ![]const u8 {
    if (destination.len == 0) return error.InputPayloadTooLarge;
    return switch (input) {
        .core => |event| blk: {
            destination[0] = @intFromEnum(StableInputTag.core);
            const encoded = try encodeInput(destination[1..], event);
            break :blk destination[0 .. encoded.len + 1];
        },
        .venue => |record| blk: {
            destination[0] = @intFromEnum(StableInputTag.venue);
            const encoded = try canonical_event_codec.encode(destination[1..], record);
            break :blk destination[0 .. encoded.len + 1];
        },
    };
}

pub fn decodeStableInput(record: journal.Record) !CanonicalEvent {
    if (record.schema_version != schema_version) return error.UnsupportedSchema;
    if (record.payload.len == 0) return error.TruncatedInputPayload;
    const tag = std.enums.fromInt(StableInputTag, record.payload[0]) orelse return error.UnknownInputType;
    var nested = record;
    nested.payload = record.payload[1..];
    return switch (tag) {
        .core => .{ .core = try shard_event.decodeInput(nested) },
        .venue => .{ .venue = try canonical_event_codec.decode(nested.payload) },
    };
}

/// Appends one authoritative input and every resulting fact to one stable
/// journal format, regardless of whether the source was core or Venue.
fn appendStableFactGroup(
    decision_journal: *journal.Journal,
    input: CanonicalEvent,
    facts: []const Fact,
) !void {
    var storage: [journal.max_payload_size]u8 = undefined;
    const encoded_input = try encodeStableInput(&storage, input);
    const times = stableTimes(input);
    for (facts, 0..) |event, index| {
        var fact_bytes: [@sizeOf(u64) + 1 + 32]u8 = undefined;
        std.mem.writeInt(u64, fact_bytes[0..@sizeOf(u64)], event.identity, .little);
        fact_bytes[@sizeOf(u64)] = @intFromEnum(event.reject_reason);
        const fact_len: usize = if (event.economic_open_digest) |digest| blk: {
            @memcpy(fact_bytes[9..41], &digest);
            break :blk 41;
        } else 9;
        try decision_journal.append(.{
            .type_id = @intFromEnum(event.kind),
            .schema_version = schema_version,
            .flags = if (index == 0) journal.input_flag | (@as(u32, @intFromEnum(event.reject_reason)) << 8) else 0,
            .sequence = event.sequence,
            .source_time = times.source,
            .receive_time = times.receive,
            .monotonic_time = times.monotonic,
            .wall_time = times.wall,
            .time_presence = times.presence,
            .payload = if (index == 0) encoded_input else fact_bytes[0..fact_len],
        });
    }
}

pub fn applyStable(
    shard: *TradingShard,
    decision_journal: *journal.Journal,
    input: CanonicalEvent,
) !?OrderCommand {
    const before = decision_journal.last_sequence;
    var candidate: TradingShard = undefined;
    copyTradingState(&candidate, shard);
    const command = applyStableOnCandidate(&candidate, shard, decision_journal, input) catch |err| {
        if (decision_journal.last_sequence != before) copyTradingState(shard, &candidate);
        return err;
    };
    if (decision_journal.last_sequence != before) copyTradingState(shard, &candidate);
    return command;
}

/// The caller owns this unpublished candidate and its journal. A failed append
/// restores the journal; the caller must discard the candidate on failure.
pub fn applyStableOnCandidate(
    shard: *TradingShard,
    previous: *const TradingShard,
    decision_journal: *journal.Journal,
    input: CanonicalEvent,
) !?OrderCommand {
    const checkpoint = decision_journal.checkpoint();
    const before = shard.authoritativeBarrier();
    const account_failure_before = shard.canonical_account.failure;
    const market_failure_generation_before = shard.canonical_market.failure_generation;
    const oms_recovery_before = shard.oms.recovery_only;
    const asset_failed_before = shard.asset_configuration_failure_count;
    const economic_fault_before = shard.economic_fault_count;
    var publish_on_error = false;
    const result = shard.applyOwnedCandidate(previous, input, &publish_on_error) catch |err| {
        if (!publish_on_error) return err;
        // Account/market projection failure is itself a durable fact. Keep
        // the invalid candidate and journal its fact group before surfacing
        // the original observation error to the caller.
        if (shard.asset_configuration_failure_count != asset_failed_before or
            shard.canonical_account.failure != account_failure_before or
            shard.canonical_market.failure_generation != market_failure_generation_before or
            shard.oms.recovery_only != oms_recovery_before or
            shard.economic_fault_count != economic_fault_before or
            (err == error.HistorySafetyCapacity and shard.authoritativeBarrier() != before))
        {
            appendStableFactGroup(decision_journal, input, try shard.trace.factsAfter(before)) catch |journal_err| {
                decision_journal.restore(checkpoint);
                return journal_err;
            };
        }
        return err;
    };
    if (result.facts.len == 0) {
        // handleCanonical returns without a fact only for a verified ingress
        // duplicate; replay never needs to append the same source fact twice.
        if (input == .venue) return null;
        if (input == .core and input.core.payload == .asset_definition_activated) return null;
        if (input == .core and input.core.payload == .checkpoint_committed) return null;
        if (input == .core and input.core.payload == .account_coordinator_bound) return null;
        if (input == .core and input.core.payload == .instrument_trading_authorization) return null;
        if (input == .core and input.core.payload == .external_order_intent) return null;
        if (input == .core and input.core.payload == .oms_intent_group and
            (previous.oms.groupIdentityStatus(input.core.payload.oms_intent_group) catch .fresh) == .duplicate)
            return null;
        if (input == .core and (input.core.payload == .venue_forced_execution or input.core.payload == .funding_settlement)) return null;
        return error.InputProducedNoFact;
    }
    appendStableFactGroup(decision_journal, input, result.facts) catch |err| {
        decision_journal.restore(checkpoint);
        return err;
    };
    return result.order_command;
}

fn checkpointRoot(receipt: CheckpointReceipt) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("ShardCheckpointBindingV1\x00");
    inline for (std.meta.fields(CheckpointReceipt)) |field| {
        if (comptime !std.mem.eql(u8, field.name, "checkpoint_root")) {
            switch (@typeInfo(field.type)) {
                .int => digestInt(&hasher, field.type, @field(receipt, field.name)),
                .array => hasher.update(&@field(receipt, field.name)),
                else => unreachable,
            }
        }
    }
    var root: [32]u8 = undefined;
    hasher.final(&root);
    return root;
}

fn digestInt(hasher: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn digestBool(hasher: *Sha256, value: bool) void {
    digestInt(hasher, u8, @intFromBool(value));
}

fn digestOmsCommand(hasher: *Sha256, command: oms_module.Command) void {
    digestInt(hasher, u64, command.command_id);
    digestInt(hasher, u64, command.order_id);
    digestInt(hasher, u128, command.strategy_instance);
    digestInt(hasher, u32, command.revision);
    digestInt(hasher, u8, @intFromEnum(command.operation));
    digestInt(hasher, u128, command.instrument);
    digestInt(hasher, u8, @intFromEnum(command.side));
    digestBool(hasher, command.portfolio_reduce_only);
    digestBool(hasher, command.venue_reduce_only);
    digestInt(hasher, i64, command.quantity);
    digestInt(hasher, u128, command.limit_price.instrument);
    digestInt(hasher, u64, command.limit_price.rules_version);
    digestInt(hasher, i128, command.limit_price.ticks);
    digestInt(hasher, u64, command.predecessor_order_id);
    digestInt(hasher, u64, command.reservation.asset);
    digestInt(hasher, i128, command.reservation.atoms);
    digestInt(hasher, u8, @intFromEnum(command.order_type));
    digestInt(hasher, u8, @intFromEnum(command.time_in_force));
    digestBool(hasher, command.market_protection_price != null);
    if (command.market_protection_price) |price| {
        digestInt(hasher, u128, price.instrument);
        digestInt(hasher, u64, price.rules_version);
        digestInt(hasher, i128, price.ticks);
    }
    digestInt(hasher, u8, command.client_order_id.len);
    hasher.update(command.client_order_id.slice());
    digestInt(hasher, u64, command.intent_sequence);
    digestInt(hasher, u64, command.risk_decision_identity);
    digestInt(hasher, u64, command.reservation_identity);
    const refs = command.authority;
    digestInt(hasher, u128, refs.exchange_account);
    digestInt(hasher, u128, refs.virtual_portfolio);
    inline for (.{ refs.trading_authorization, refs.primary_lease, refs.risk_lease, refs.capability, refs.instrument_rules, refs.margin_rules, refs.instrument_trading, refs.config }) |ref| {
        digestInt(hasher, u128, ref.identity);
        digestInt(hasher, u64, ref.version);
        digestInt(hasher, u64, ref.barrier);
    }
    digestInt(hasher, u128, refs.adapter_session);
    digestInt(hasher, u64, refs.dispatch_deadline_monotonic_ns);
    digestInt(hasher, u64, refs.deadline_barrier);
}

fn digestBare(hasher: *Sha256, value: anytype) void {
    // A forced commit includes its independently authenticated cross-owner
    // closure. Its scratch follows the existing journal record bound.
    const size = if (@TypeOf(value) == ?shard_event.ForcedArchiveCommit) journal.max_payload_size else 4096;
    var bytes: [size]u8 = undefined;
    const encoded = snapshot_codec.encodeBare(&bytes, value) catch unreachable;
    hasher.update(encoded);
}

pub fn stateDigest(shard: TradingShard) [Sha256.digest_length]u8 {
    return stateDigestBorrowed(&shard);
}

fn stateDigestBorrowed(shard: *const TradingShard) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    const portfolio_position = shard.portfolioPosition();
    const exchange_position = shard.exchangePosition();
    const spot_portfolio_position = shard.spotPortfolioPosition();
    const spot_exchange_position = shard.spotExchangePosition();
    const ledger = shard.economic_projection.ledger_summary;
    hasher.update("StateDigestV11\x00");
    digestInt(&hasher, u16, schema_version);
    digestBare(&hasher, shard.business_history_root);
    digestInt(&hasher, u128, shard.next_history_pending_id);
    digestBool(&hasher, shard.history_conflict_latched);
    inline for (.{ .{ "pending_history_candidate", "pending_history_member_index" }, .{ "pending_safety_history_candidate", "pending_safety_history_member_index" } }) |fields| {
        digestBare(&hasher, @field(shard, fields[1]));
        if (@field(shard, fields[0])) |pending| {
            var bytes: [cold.max_encoded_size]u8 = undefined;
            hasher.update(cold.encodeCompact(&bytes, &pending) catch unreachable);
        } else hasher.update(&.{0});
    }
    digestBare(&hasher, shard.last_order_archive);
    digestBare(&hasher, shard.last_fill_archive);
    digestBare(&hasher, shard.last_funding_archive);
    digestBare(&hasher, shard.last_funding_archive_input);
    digestBare(&hasher, shard.last_reconciliation_archive);
    digestBare(&hasher, shard.last_reconciliation_archive_input);
    digestBare(&hasher, shard.reconciliation_cursor);
    digestBare(&hasher, shard.pending_reconciliation_window);
    digestInt(&hasher, u64, shard.open_economic_fact_count);
    digestInt(&hasher, u64, shard.open_economic_commitment_sequence);
    digestInt(&hasher, u64, shard.open_economic_min_utc_ns);
    digestInt(&hasher, u64, shard.open_economic_max_utc_ns);
    digestInt(&hasher, u64, shard.open_economic_unknown_time_count);
    for (shard.open_economic_facts[0..@min(shard.open_economic_fact_count, shard.open_economic_facts.len)]) |fact| digestBare(&hasher, fact);
    digestInt(&hasher, u8, shard.economic_baseline_balance_count);
    for (shard.economic_baseline_balances[0..shard.economic_baseline_balance_count]) |balance| digestBare(&hasher, balance);
    digestBare(&hasher, shard.last_business_archive_kind);
    digestBare(&hasher, shard.coordinator_history_origin);
    digestInt(&hasher, u64, shard.coordinator_binding_fact);
    digestBare(&hasher, shard.last_forced_archive);
    digestBare(&hasher, shard.last_forced_archive_input);
    digestBare(&hasher, shard.last_control_archive);
    digestBare(&hasher, shard.last_control_archive_input);
    digestInt(&hasher, u64, shard.archived_control_records);
    digestInt(&hasher, u8, shard.deferred_history_admission_count);
    for (shard.deferred_history_admissions[0..shard.deferred_history_admission_count]) |admission| digestBare(&hasher, admission);
    digestInt(&hasher, u16, shard.dispatch_ingress_history_count);
    for (shard.dispatch_ingress_history[0..shard.dispatch_ingress_history_count]) |entry| digestBare(&hasher, entry);
    digestAssetRegistry(&hasher, shard, true);
    digestInt(&hasher, u8, shard.instrument_registry.count);
    for (shard.instrument_registry.entries[0..shard.instrument_registry.count]) |entry| {
        digestInt(&hasher, u128, entry.instrument);
        digestInt(&hasher, u64, entry.venue);
        digestInt(&hasher, u8, @intFromEnum(entry.product));
        digestInt(&hasher, u32, entry.rules.version);
        digestInt(&hasher, i64, entry.rules.quantity_denominator);
        digestInt(&hasher, i64, entry.rules.quantity_numerator);
        digestInt(&hasher, u8, @intFromEnum(entry.rules.reservation_model));
        digestInt(&hasher, u8, @intFromEnum(entry.rules.product));
        digestInt(&hasher, u64, entry.rules.settlement_asset);
        digestInt(&hasher, u64, entry.rules.base_asset);
        digestInt(&hasher, u64, entry.rules_barrier);
        digestInt(&hasher, u64, entry.capability_barrier);
        digestBool(&hasher, entry.trading_enabled);
        digestInt(&hasher, u64, entry.trading_version);
        digestInt(&hasher, u64, entry.trading_barrier);
        digestBool(&hasher, entry.capability != null);
        if (entry.capability) |capability| {
            digestInt(&hasher, u128, capability.exchange_account);
            digestInt(&hasher, u128, capability.instrument);
            digestInt(&hasher, u64, capability.venue);
            digestInt(&hasher, u8, @intFromEnum(capability.environment));
            digestInt(&hasher, u8, @intFromEnum(capability.product));
            digestInt(&hasher, u64, capability.version);
            digestInt(&hasher, u64, capability.rules_version);
            digestInt(&hasher, u64, capability.config_version);
            digestInt(&hasher, u128, capability.adapter_session);
            digestInt(&hasher, u64, capability.max_dispatch_age_ns);
            digestBool(&hasher, capability.supports_place);
            digestBool(&hasher, capability.supports_cancel);
            digestBool(&hasher, capability.supports_native_amend);
            digestBool(&hasher, capability.supports_venue_reduce_only);
            digestBool(&hasher, capability.supports_post_only);
            digestBool(&hasher, capability.supports_market_protection);
        }
        digestBool(&hasher, entry.margin_configured);
        digestInt(&hasher, u64, entry.margin_barrier);
        digestInt(&hasher, u32, entry.margin.version);
        digestInt(&hasher, i128, entry.margin.price_tick_atoms);
        digestBool(&hasher, entry.margin.native_settlement_atoms);
        digestInt(&hasher, i64, entry.margin.venue_initial_margin_ppm);
        digestInt(&hasher, i64, entry.margin.internal_initial_margin_ppm);
        digestInt(&hasher, i64, entry.margin.internal_maintenance_margin_ppm);
        digestInt(&hasher, i64, entry.margin.fee_ppm);
        inline for (.{ entry.margin.opening_buffer_atoms, entry.margin.warning_buffer_atoms, entry.margin.kill_buffer_atoms }) |value| digestInt(&hasher, i128, value);
        inline for (.{ entry.margin.opening_buffer_bps, entry.margin.warning_buffer_bps, entry.margin.kill_buffer_bps, entry.margin.opening_liquidation_distance_ticks, entry.margin.warning_liquidation_distance_ticks, entry.margin.kill_liquidation_distance_ticks }) |value| digestInt(&hasher, i64, value);
    }
    if (shard.canonical_ingress_count != 0) {
        hasher.update("CanonicalIngressV1\x00");
        digestInt(&hasher, u64, shard.canonical_ingress_count);
        hasher.update(&shard.canonical_ingress_digest);
    }
    digestInt(&hasher, u32, shard.instrument_rules_version);
    digestInt(&hasher, u128, shard.instrument_identity);
    digestInt(&hasher, i64, shard.quantity_denominator);
    digestInt(&hasher, u8, @intFromEnum(shard.reservation_model));
    digestInt(&hasher, u32, shard.margin_rules_version);
    digestBool(&hasher, shard.account_configured);
    digestInt(&hasher, u128, shard.exchange_account_identity);
    digestBool(&hasher, shard.exchange_balance_observed);
    digestBool(&hasher, shard.exchange_positions_observed);
    digestBool(&hasher, shard.opening_balance_observed);
    digestInt(&hasher, u64, shard.account_balance_utc_ns);
    digestInt(&hasher, u64, shard.economic_baseline_utc_ns);
    digestBool(&hasher, shard.virtual_portfolio_active);
    digestInt(&hasher, u128, shard.portfolio_identity);
    digestBool(&hasher, shard.portfolio_funded);
    digestBool(&hasher, shard.strategy_active);
    digestInt(&hasher, u128, shard.strategy_identity);
    digestInt(&hasher, u64, shard.strategy_config_version);
    digestInt(&hasher, u64, shard.authority_control_barrier);
    digestInt(&hasher, u128, shard.strategy_activation_identity);
    digestInt(&hasher, u128, shard.host_activation_identity);
    digestInt(&hasher, u64, shard.host_activation_barrier);
    digestInt(&hasher, u64, shard.host_activation_session.fencing);
    digestInt(&hasher, u32, shard.host_activation_session.shard);
    digestInt(&hasher, u64, shard.host_activation_session.generation);
    digestInt(&hasher, u64, shard.host_activation_fact_sequence);
    hasher.update(&shard.host_activation_state_digest);
    digestBool(&hasher, shard.host_activation_seen);
    digestBool(&hasher, shard.operational_state.initialized);
    digestInt(&hasher, u128, shard.operational_state.target_identity);
    digestInt(&hasher, u64, shard.operational_state.version);
    digestInt(&hasher, u8, @intFromEnum(shard.operational_state.mode));
    digestBool(&hasher, shard.operational_state.trading_authorized);
    digestBool(&hasher, shard.operational_state.self_recovering_closed);
    digestBool(&hasher, shard.operational_state.warning_blocks_buy);
    digestBool(&hasher, shard.operational_state.warning_blocks_sell);
    digestInt(&hasher, u8, shard.operational_state.command_count);
    for (shard.operational_state.command_history[0..shard.operational_state.command_count]) |command| {
        digestInt(&hasher, u128, command.command.command_identity);
        digestInt(&hasher, u128, command.command.content_hash);
        digestInt(&hasher, u128, command.command.target_identity);
        digestInt(&hasher, u64, command.command.expected_version);
        digestInt(&hasher, u64, command.command.expires_at);
        digestInt(&hasher, u8, @intFromEnum(command.command.kind));
        digestInt(&hasher, i64, command.command.target_position);
        digestInt(&hasher, u128, command.command.referenced_latch_identity);
        digestBool(&hasher, command.command.risk_warning_acknowledged);
        digestInt(&hasher, u128, command.command.risk_warning_identity);
    }
    digestInt(&hasher, u8, shard.operational_state.latch_count);
    for (shard.operational_state.latches[0..shard.operational_state.latch_count]) |latch_record| {
        digestInt(&hasher, u128, latch_record.identity);
        digestInt(&hasher, u8, @intFromEnum(latch_record.reason));
        digestBool(&hasher, latch_record.resolved);
    }
    digestInt(&hasher, u128, shard.operational_state.active_operation_identity);
    digestInt(&hasher, u8, @intFromEnum(shard.operational_state.active_operation_kind));
    digestInt(&hasher, i64, shard.operational_state.target_position);
    digestBool(&hasher, shard.operational_state.continuity_intact);
    digestInt(&hasher, u128, shard.operational_state.last_risk_warning_identity);
    digestInt(&hasher, u8, shard.operational_state.gate_count);
    for (shard.operational_state.gates[0..shard.operational_state.gate_count]) |gate| {
        digestInt(&hasher, u128, gate.gate_identity);
        digestInt(&hasher, u128, gate.target_identity);
        digestInt(&hasher, u8, @intFromEnum(gate.kind));
        digestInt(&hasher, u8, @intFromEnum(gate.reason));
        digestBool(&hasher, gate.open);
        digestBool(&hasher, gate.continuity_proven);
        digestBool(&hasher, gate.blocks_buy);
        digestBool(&hasher, gate.blocks_sell);
    }
    if (shard.release_generation != 0) {
        hasher.update("VersionActivation\x00");
        digestInt(&hasher, u64, shard.release_generation);
        digestInt(&hasher, u64, shard.active_release);
        digestInt(&hasher, u128, shard.active_strategy_instance);
    }
    if (shard.fenced_strategy_count != 0) {
        digestInt(&hasher, u8, shard.fenced_strategy_count);
        for (shard.fenced_strategy_instances[0..shard.fenced_strategy_count]) |identity|
            digestInt(&hasher, u128, identity);
    }
    digestInt(&hasher, u16, shard.oms.order_count);
    for (shard.oms.orders[0..shard.oms.order_count]) |order| {
        digestInt(&hasher, u64, order.id);
        if (order.strategy_instance != 0) digestInt(&hasher, u128, order.strategy_instance);
        digestInt(&hasher, u128, order.instrument);
        digestInt(&hasher, u8, @intFromEnum(order.side));
        digestBool(&hasher, order.portfolio_reduce_only);
        digestBool(&hasher, order.venue_reduce_only);
        digestInt(&hasher, u32, order.revision);
        digestInt(&hasher, u8, @intFromEnum(order.state));
        digestInt(&hasher, i64, order.quantity);
        digestInt(&hasher, u128, order.limit_price.instrument);
        digestInt(&hasher, u64, order.limit_price.rules_version);
        digestInt(&hasher, i128, order.limit_price.ticks);
        digestInt(&hasher, i64, order.cumulative_quantity);
        digestInt(&hasher, u64, order.predecessor_order_id);
        digestInt(&hasher, u64, order.reservation.asset);
        digestInt(&hasher, i128, order.reservation.atoms);
        digestInt(&hasher, u64, order.confirmed_reservation.asset);
        digestInt(&hasher, i128, order.confirmed_reservation.atoms);
        digestInt(&hasher, i64, order.reservation_basis_quantity);
        digestInt(&hasher, u8, @intFromEnum(order.order_type));
        digestInt(&hasher, u8, @intFromEnum(order.time_in_force));
        digestBool(&hasher, order.market_protection_price != null);
        if (order.market_protection_price) |price| {
            digestInt(&hasher, u128, price.instrument);
            digestInt(&hasher, u64, price.rules_version);
            digestInt(&hasher, i128, price.ticks);
        }
        digestInt(&hasher, u8, order.client_order_id.len);
        hasher.update(order.client_order_id.slice());
        const pending_reservation = order.pending_reservation orelse canonical.AssetAmount{ .asset = 0, .atoms = 0 };
        digestBool(&hasher, order.pending_reservation != null);
        digestInt(&hasher, u64, pending_reservation.asset);
        digestInt(&hasher, i128, pending_reservation.atoms);
        if (order.pending_reservation) |_| {
            digestInt(&hasher, i64, order.confirmed_quantity);
            digestInt(&hasher, i64, order.pending_basis_quantity);
            digestBool(&hasher, order.pending_previous_spec != null);
            if (order.pending_previous_spec) |previous| {
                digestInt(&hasher, u128, previous.limit_price.instrument);
                digestInt(&hasher, u64, previous.limit_price.rules_version);
                digestInt(&hasher, i128, previous.limit_price.ticks);
                digestInt(&hasher, u8, @intFromEnum(previous.order_type));
                digestInt(&hasher, u8, @intFromEnum(previous.time_in_force));
                digestBool(&hasher, previous.market_protection_price != null);
                if (previous.market_protection_price) |price| {
                    digestInt(&hasher, u128, price.instrument);
                    digestInt(&hasher, u64, price.rules_version);
                    digestInt(&hasher, i128, price.ticks);
                }
            }
        }
        digestBool(&hasher, order.reservation_active);
        digestBool(&hasher, order.dispatch_submitted);
        digestInt(&hasher, u64, order.intent_sequence);
        digestInt(&hasher, u64, order.group_first_sequence);
        digestInt(&hasher, u8, @intFromEnum(order.group_policy));
        digestBool(&hasher, order.replacement != null);
        if (order.replacement) |replacement| {
            digestInt(&hasher, u128, replacement.instrument);
            digestInt(&hasher, u8, @intFromEnum(replacement.side));
            digestBool(&hasher, replacement.portfolio_reduce_only);
            digestBool(&hasher, replacement.venue_reduce_only);
            digestInt(&hasher, i64, replacement.quantity);
            digestInt(&hasher, u128, replacement.limit_price.instrument);
            digestInt(&hasher, u64, replacement.limit_price.rules_version);
            digestInt(&hasher, i128, replacement.limit_price.ticks);
            digestInt(&hasher, u64, replacement.reservation.asset);
            digestInt(&hasher, i128, replacement.reservation.atoms);
            digestInt(&hasher, u8, @intFromEnum(replacement.order_type));
            digestInt(&hasher, u8, @intFromEnum(replacement.time_in_force));
            digestBool(&hasher, replacement.market_protection_price != null);
            if (replacement.market_protection_price) |price| {
                digestInt(&hasher, u128, price.instrument);
                digestInt(&hasher, u64, price.rules_version);
                digestInt(&hasher, i128, price.ticks);
            }
            digestInt(&hasher, u8, replacement.client_order_id.len);
            hasher.update(replacement.client_order_id.slice());
            digestInt(&hasher, u32, replacement.expected_revision);
            digestInt(&hasher, i64, replacement.expected_cumulative_quantity);
        }
        digestInt(&hasher, u64, order.last_report_id);
        digestInt(&hasher, u32, order.last_report_revision);
        digestInt(&hasher, u8, @intFromEnum(order.last_report_status));
        digestInt(&hasher, i64, order.last_report_cumulative_quantity);
        digestInt(&hasher, i64, order.last_report_remaining_quantity);
        digestInt(&hasher, u64, order.last_reconciliation_id);
        digestInt(&hasher, u8, @intFromEnum(order.last_reconciliation_status));
        digestInt(&hasher, u32, order.last_reconciliation_revision);
        digestInt(&hasher, i64, order.last_reconciliation_cumulative_quantity);
        digestInt(&hasher, i64, order.last_reconciliation_remaining_quantity);
        digestInt(&hasher, u64, order.created_at_utc_ns);
        digestInt(&hasher, u64, order.terminal_observed_at_utc_ns);
        digestBare(&hasher, order.terminal_archive_evidence);
        digestBool(&hasher, order.archive_window_closed);
        hasher.update(&order.archive_audit_digest);
    }
    digestInt(&hasher, u64, shard.oms.next_order_id);
    digestInt(&hasher, u64, shard.oms.next_command_id);
    digestInt(&hasher, u16, shard.oms.command_history_count);
    for (shard.oms.command_history[0..shard.oms.command_history_count]) |command|
        digestOmsCommand(&hasher, command);
    digestInt(&hasher, u16, shard.oms.report_history_count);
    for (shard.oms.report_history[0..shard.oms.report_history_count]) |report| {
        digestInt(&hasher, u64, report.report_id);
        digestInt(&hasher, u64, report.order_id);
        digestInt(&hasher, u32, report.revision);
        digestInt(&hasher, u8, @intFromEnum(report.status));
        digestInt(&hasher, i64, report.cumulative_quantity);
        digestInt(&hasher, i64, report.remaining_quantity);
        hasher.update(&report.canonical_digest);
    }
    digestInt(&hasher, u16, shard.oms.reconciliation_history_count);
    for (shard.oms.reconciliation_history[0..shard.oms.reconciliation_history_count]) |result| {
        digestInt(&hasher, u64, result.reconciliation_id);
        digestInt(&hasher, u64, result.order_id);
        digestInt(&hasher, u8, @intFromEnum(result.status));
        digestInt(&hasher, u32, result.revision);
        digestInt(&hasher, i64, result.cumulative_quantity);
        digestInt(&hasher, i64, result.remaining_quantity);
        digestBool(&hasher, result.terminal_state != null);
        digestInt(&hasher, u8, if (result.terminal_state) |terminal| @intFromEnum(terminal) else 0);
        hasher.update(&result.canonical_digest);
    }
    digestInt(&hasher, u16, shard.oms.intent_history_count);
    for (shard.oms.intent_history[0..shard.oms.intent_history_count]) |known| {
        digestInt(&hasher, u64, known.group);
        digestInt(&hasher, u8, @intFromEnum(known.policy));
        digestInt(&hasher, u64, known.intent_sequence);
        digestInt(&hasher, u128, known.strategy_instance);
        hasher.update(&known.fingerprint);
    }
    digestInt(&hasher, u16, shard.oms.tombstone_count);
    for (shard.oms.tombstones[0..shard.oms.tombstone_count]) |tombstone| {
        digestInt(&hasher, u64, tombstone.order_id);
        digestInt(&hasher, u128, tombstone.strategy_instance);
        digestInt(&hasher, u128, tombstone.instrument);
        digestInt(&hasher, u32, tombstone.revision);
        digestInt(&hasher, u8, @intFromEnum(tombstone.state));
        digestInt(&hasher, i64, tombstone.quantity);
        digestInt(&hasher, i64, tombstone.cumulative_quantity);
        digestInt(&hasher, u64, tombstone.predecessor_order_id);
        digestInt(&hasher, u64, tombstone.group_first_sequence);
        digestInt(&hasher, u64, tombstone.last_report_id);
        digestInt(&hasher, u64, tombstone.last_reconciliation_id);
        digestInt(&hasher, u64, tombstone.intent_sequence);
        digestInt(&hasher, u8, tombstone.client_order_id.len);
        hasher.update(tombstone.client_order_id.slice());
        hasher.update(&tombstone.fact_digest);
    }
    digestEconomicFault(&hasher, shard);
    digestBool(&hasher, shard.oms.recovery_only);
    digestBool(&hasher, shard.oms.capacity_pressure);
    digestEconomicProjection(&hasher, shard.economic_projection);
    digestInt(&hasher, u64, shard.fencing_token);
    digestInt(&hasher, u64, shard.authoritativeBarrier());
    hasher.update(&shard.trace.history_head);
    hasher.update(&shard.trace.input_head);
    hasher.update(&shard.trace.pinned_root);
    digestBool(&hasher, shard.checkpoint != null);
    if (shard.checkpoint) |receipt| hasher.update(&receipt.checkpoint_root);
    for (shard.control_fact_sequences[0..shard.operational_state.command_count]) |sequence| digestInt(&hasher, u64, sequence);

    digestBool(&hasher, shard.expected_source_sequence != null);
    digestInt(&hasher, u64, shard.expected_source_sequence orelse 0);
    digestInt(&hasher, u8, @intFromEnum(shard.market_health));
    digestInt(&hasher, i64, shard.bid_price_ticks);
    digestInt(&hasher, i64, shard.bid_quantity);
    digestInt(&hasher, i64, shard.ask_1_price_ticks);
    digestInt(&hasher, i64, shard.ask_1_quantity);
    digestInt(&hasher, i64, shard.ask_2_price_ticks);
    digestInt(&hasher, i64, shard.ask_2_quantity);
    digestInt(&hasher, u64, shard.strategy_cursor);
    digestInt(&hasher, u64, shard.strategy_decision_count);
    digestBool(&hasher, shard.timer_pending);
    digestInt(&hasher, u64, shard.dispatch_attempt_count);
    digestInt(&hasher, u8, @intFromEnum(shard.last_reject_reason));
    digestInt(&hasher, i128, shard.last_risk_required_atoms);
    digestInt(&hasher, u8, shard.last_risk_tier);
    digestInt(&hasher, i128, shard.mark_price_atoms);
    digestInt(&hasher, i64, portfolio_position.quantity);
    digestInt(&hasher, i128, portfolio_position.open_cost_atoms);
    digestInt(&hasher, i64, exchange_position.quantity);
    digestInt(&hasher, i128, exchange_position.open_cost_atoms);
    digestInt(&hasher, i64, spot_portfolio_position.quantity);
    digestInt(&hasher, i128, spot_portfolio_position.open_cost_atoms);
    digestInt(&hasher, i64, spot_exchange_position.quantity);
    digestInt(&hasher, i128, spot_exchange_position.open_cost_atoms);
    digestInt(&hasher, i128, shard.portfolioCash());
    digestInt(&hasher, i128, shard.treasuryCash());
    digestInt(&hasher, i128, shard.exchangeCash());
    digestInt(&hasher, i128, shard.portfolioFee());
    digestInt(&hasher, i128, shard.exchangeFee());
    digestInt(&hasher, i128, shard.totalFees());
    digestInt(&hasher, i128, shard.realizedPnl());
    digestInt(&hasher, i128, shard.unrealizedPnl());
    digestInt(&hasher, i128, shard.risk_lease_atoms);
    digestInt(&hasher, u64, shard.risk_lease_identity);
    digestInt(&hasher, u64, shard.risk_lease_version);
    digestInt(&hasher, u64, shard.risk_lease_valid_through_barrier);
    digestInt(&hasher, i128, shard.strategy_limit_atoms);
    digestInt(&hasher, i128, shard.portfolio_limit_atoms);
    digestInt(&hasher, i128, shard.exchange_account_limit_atoms);
    digestInt(&hasher, i128, shard.global_limit_atoms);
    digestInt(&hasher, i128, shard.price_tick_atoms);
    digestInt(&hasher, i64, shard.venue_initial_margin_ppm);
    digestInt(&hasher, i64, shard.internal_initial_margin_ppm);
    digestInt(&hasher, i64, shard.internal_maintenance_margin_ppm);
    digestInt(&hasher, i64, shard.risk_fee_ppm);
    digestInt(&hasher, i128, shard.opening_buffer_atoms);
    digestInt(&hasher, i64, shard.opening_buffer_bps);
    digestInt(&hasher, i64, shard.opening_liquidation_distance_ticks);
    digestInt(&hasher, i128, shard.warning_buffer_atoms);
    digestInt(&hasher, i128, shard.kill_buffer_atoms);
    digestInt(&hasher, i64, shard.warning_buffer_bps);
    digestInt(&hasher, i64, shard.kill_buffer_bps);
    digestInt(&hasher, i64, shard.warning_liquidation_distance_ticks);
    digestInt(&hasher, i64, shard.kill_liquidation_distance_ticks);
    digestInt(&hasher, i128, shard.portfolio_margin_buffer_atoms);
    digestInt(&hasher, i128, shard.exchange_margin_buffer_atoms);
    digestInt(&hasher, i64, shard.portfolio_buffer_bps);
    digestInt(&hasher, i64, shard.exchange_buffer_bps);
    digestInt(&hasher, i64, shard.portfolio_liquidation_distance_ticks);
    digestInt(&hasher, i64, shard.exchange_liquidation_distance_ticks);
    digestInt(&hasher, u8, @intFromEnum(shard.portfolio_margin_gate));
    digestInt(&hasher, u8, @intFromEnum(shard.exchange_margin_gate));
    digestInt(&hasher, u64, ledger.transaction_count);
    digestInt(&hasher, u64, ledger.portfolio_transfer_count);
    digestInt(&hasher, i128, ledger.portfolio_debits_atoms);
    digestInt(&hasher, i128, ledger.portfolio_credits_atoms);
    digestInt(&hasher, i128, ledger.exchange_debits_atoms);
    digestInt(&hasher, i128, ledger.exchange_credits_atoms);
    digestBool(&hasher, ledger.projections_complete);
    const economics_digest = shard.economic_projection.digest();
    hasher.update(&economics_digest);
    digestCanonicalProjections(&hasher, shard);
    return hasher.finalResult();
}

test "state digest binds instrument trading margin and economic position authority" {
    const shard = try std.testing.allocator.create(TradingShard);
    defer std.testing.allocator.destroy(shard);
    shard.* = .{};
    _ = try shard.instrument_registry.register(.{
        .instrument = 10,
        .venue = 2,
        .product = .spot,
        .rules = .{ .version = 1, .instrument_identity = 10, .quantity_denominator = 1, .reservation_model = .cash, .product = .spot },
        .margin = .{ .version = 1 },
    });
    var before = stateDigest(shard.*);
    shard.instrument_registry.entries[0].trading_version = 2;
    try std.testing.expect(!std.mem.eql(u8, &before, &stateDigest(shard.*)));
    before = stateDigest(shard.*);
    shard.instrument_registry.entries[0].margin.opening_buffer_atoms = @as(i128, 1) << 80;
    try std.testing.expect(!std.mem.eql(u8, &before, &stateDigest(shard.*)));
    before = stateDigest(shard.*);
    shard.economic_projection.portfolio.instrument_position_count = 1;
    shard.economic_projection.portfolio.instrument_positions[0] = .{ .instrument = 10, .product = .spot };
    try std.testing.expect(!std.mem.eql(u8, &before, &stateDigest(shard.*)));
}

fn digestCanonicalProjections(hasher: *Sha256, shard: *const TradingShard) void {
    const account_digest = shard.canonical_account.digest();
    hasher.update(&account_digest);
    digestBool(hasher, shard.canonical_account.valid);
    digestBool(hasher, shard.canonical_account.failure != null);
    if (shard.canonical_account.failure) |failure| digestInt(hasher, u8, @intFromEnum(failure));
    digestInt(hasher, u16, shard.canonical_account.seen_count);
    digestInt(hasher, u8, shard.canonical_account.balance_count);
    digestInt(hasher, u8, shard.canonical_account.position_count);
    digestInt(hasher, u8, shard.canonical_account.margin_count);
    digestInt(hasher, u8, shard.canonical_market.count);
    digestInt(hasher, u64, shard.canonical_market.failure_generation);
    for (shard.canonical_market.entries[0..shard.canonical_market.count]) |market| {
        digestInt(hasher, u128, market.instrument);
        digestInt(hasher, u64, market.definition.rules_version);
        digestBool(hasher, market.active_rules_version != null);
        digestInt(hasher, u64, market.active_rules_version orelse 0);
        digestBool(hasher, market.last_book != null);
        if (market.last_book) |book| {
            digestInt(hasher, u64, book.sequence);
            digestInt(hasher, i128, book.best_bid.ticks);
            digestInt(hasher, i128, book.best_ask.ticks);
            // Depth, coverage, quantities and visibility are decision inputs.
            var book_bytes: [4096]u8 = undefined;
            const encoded_book = snapshot_codec.encodeBare(&book_bytes, book) catch unreachable;
            hasher.update(encoded_book);
        }
        digestInt(hasher, u8, @intFromEnum(market.health));
        digestBool(hasher, market.failure != null);
        if (market.failure) |failure| digestInt(hasher, u8, @intFromEnum(failure));
        digestBool(hasher, market.mark != null);
        if (market.mark) |mark| digestInt(hasher, i128, mark.ticks);
        digestBool(hasher, market.index != null);
        if (market.index) |index| digestInt(hasher, i128, index.ticks);
    }
}

fn digestEconomicProjection(hasher: *Sha256, projection: economics_module.Projection) void {
    const economic_digest = projection.digest();
    hasher.update(&economic_digest);
}

fn semanticStateDigest(shard: *const TradingShard) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("SemanticAuthorityDigestV1\x00");
    digestInt(&hasher, u64, shard.economic_baseline_utc_ns);
    digestInt(&hasher, u64, shard.account_balance_utc_ns);
    digestAssetRegistry(&hasher, shard, false);
    digestInt(&hasher, u16, shard.oms.order_count);
    for (shard.oms.orders[0..shard.oms.order_count]) |order| {
        digestInt(&hasher, u64, order.id);
        digestInt(&hasher, u32, order.revision);
        digestInt(&hasher, u8, @intFromEnum(order.state));
        digestInt(&hasher, i64, order.quantity);
        digestInt(&hasher, i64, order.cumulative_quantity);
        digestInt(&hasher, u64, order.reservation.asset);
        digestInt(&hasher, i128, order.reservation.atoms);
        digestInt(&hasher, u64, order.confirmed_reservation.asset);
        digestInt(&hasher, i128, order.confirmed_reservation.atoms);
        if (order.pending_reservation) |pending| {
            digestInt(&hasher, i64, order.confirmed_quantity);
            digestInt(&hasher, i64, order.reservation_basis_quantity);
            digestInt(&hasher, u64, pending.asset);
            digestInt(&hasher, i128, pending.atoms);
            digestInt(&hasher, i64, order.pending_basis_quantity);
            digestBool(&hasher, order.pending_previous_spec != null);
            if (order.pending_previous_spec) |previous| {
                digestInt(&hasher, u128, previous.limit_price.instrument);
                digestInt(&hasher, u64, previous.limit_price.rules_version);
                digestInt(&hasher, i128, previous.limit_price.ticks);
                digestInt(&hasher, u8, @intFromEnum(previous.order_type));
                digestInt(&hasher, u8, @intFromEnum(previous.time_in_force));
                digestBool(&hasher, previous.market_protection_price != null);
                if (previous.market_protection_price) |price| {
                    digestInt(&hasher, u128, price.instrument);
                    digestInt(&hasher, u64, price.rules_version);
                    digestInt(&hasher, i128, price.ticks);
                }
            }
        }
        digestBool(&hasher, order.reservation_active);
        digestBool(&hasher, order.dispatch_submitted);
        digestInt(&hasher, u64, order.last_report_id);
        digestInt(&hasher, u64, order.last_reconciliation_id);
    }
    digestEconomicFault(&hasher, shard);
    const economics_digest = shard.economic_projection.semanticDigest();
    hasher.update(&economics_digest);
    const account_digest = shard.canonical_account.semanticDigest();
    hasher.update(&account_digest);
    digestBool(&hasher, shard.canonical_account.valid);
    digestBool(&hasher, shard.canonical_account.failure != null);
    digestInt(&hasher, i128, shard.portfolioCash());
    digestInt(&hasher, i128, shard.exchangeCash());
    return hasher.finalResult();
}

const ReplayResult = struct {
    shard: TradingShard,
    status: journal.ScanStatus,
};

pub const StableRecovery = struct {
    shard: TradingShard,
    status: journal.ScanStatus,
};

fn validateReplayRecord(
    record: journal.Record,
    expected: Fact,
    input: CanonicalEvent,
    is_input: bool,
) !void {
    if (record.schema_version != schema_version) return error.UnsupportedSchema;
    const derived_len: usize = if (expected.economic_open_digest != null) 41 else 9;
    if (!is_input and (record.flags != 0 or record.payload.len != derived_len))
        return error.InvalidDerivedFactRecord;
    const kind = std.enums.fromInt(EventKind, record.type_id) orelse
        return error.UnknownEventType;
    if (record.sequence != expected.sequence or kind != expected.kind or
        (!is_input and (try eventIdentity(record.payload) != expected.identity or
            record.payload[@sizeOf(u64)] != @intFromEnum(expected.reject_reason))))
        return error.ReplayFactMismatch;
    if (!is_input) if (expected.economic_open_digest) |digest| {
        if (!std.mem.eql(u8, record.payload[9..41], &digest)) return error.ReplayFactMismatch;
    };
    const times = stableTimes(input);
    if (record.source_time != times.source or
        record.receive_time != times.receive or
        record.monotonic_time != times.monotonic or
        record.wall_time != times.wall or
        @as(u8, @bitCast(record.time_presence)) != @as(u8, @bitCast(times.presence)))
        return error.ReplayTimeMismatch;
    if (is_input) {
        if (record.flags != journal.input_flag | (@as(u32, @intFromEnum(expected.reject_reason)) << 8)) return error.ReplayFactMismatch;
    }
}

fn replay(bytes: []const u8) !ReplayResult {
    return replayConfigured(bytes, contract_denominator, .leveraged);
}

fn replayConfigured(bytes: []const u8, quantity_denominator: i64, reservation_model: ReservationModel) !ReplayResult {
    var reader = try journal.Reader.init(bytes);
    var recovered: ReplayResult = .{ .shard = .{
        .quantity_denominator = quantity_denominator,
        .reservation_model = reservation_model,
    }, .status = undefined };
    recovered.status = try replayReaderInto(&reader, &recovered.shard);
    return recovered;
}

/// Replays a stable journal and reports only its externally comparable digest.
/// It observes recovery; all state transitions remain inside `TradingShard.apply`.
pub fn replayDigest(
    bytes: []const u8,
    quantity_denominator: i64,
    reservation_model: ReservationModel,
) !struct { status: journal.ScanStatus, digest: [Sha256.digest_length]u8 } {
    const recovered = try replayConfigured(bytes, quantity_denominator, reservation_model);
    return .{ .status = recovered.status, .digest = recovered.shard.canonicalStateDigest() };
}

/// Replays authoritative CanonicalEvents from an explicit recovery point.
pub fn recoverStable(initial: TradingShard, bytes: []const u8) !StableRecovery {
    var recovered: StableRecovery = undefined;
    recovered.status = try recoverStableInto(&recovered.shard, &initial, bytes);
    return recovered;
}

/// Destination remains unpublished until replay succeeds; failed replay may modify it.
pub fn recoverStableInto(destination: *TradingShard, initial: *const TradingShard, bytes: []const u8) !journal.ScanStatus {
    var reader = try journal.Reader.init(bytes);
    copyTradingState(destination, initial);
    return replayReaderInto(&reader, destination);
}

fn replayReaderInto(reader: *journal.Reader, shard: *TradingShard) !journal.ScanStatus {
    var candidate: TradingShard = undefined;

    while (true) {
        const next = try reader.next();
        const first_record = switch (next) {
            .end => |status| return status,
            .record => |record| record,
        };
        if (first_record.flags & 0xff != journal.input_flag) return error.OrphanDerivedFact;
        @memcpy(std.mem.asBytes(&candidate), std.mem.asBytes(shard));
        const input = try decodeStableInput(first_record);
        const before = candidate.authoritativeBarrier();
        var replay_error: ?anyerror = null;
        // The restart admission fence guards new work, not already committed
        // historical inputs. Preserve the fence on the replay result.
        const admission_pending = candidate.recovery_admission_pending;
        candidate.recovery_admission_pending = false;
        // Replay already owns an unpublished copy. Reuse it instead of nesting
        // the public apply transaction and another full TradingShard copy.
        var publish_on_error = false;
        _ = candidate.applyOwnedCandidate(shard, input, &publish_on_error) catch |err| {
            if (!publish_on_error) copyTradingState(&candidate, shard);
            replay_error = err;
        };
        candidate.recovery_admission_pending = admission_pending;
        const generated = try candidate.trace.factsAfter(before);
        const rejected_canonical_report = if (replay_error) |err|
            (err == error.InvalidExecutionReport or err == error.StaleOrderRevision or
                err == error.TombstoneFactConflict or err == error.ArchivedFactOutsideRetention or err == error.TerminalFactConflict) and
                input == .venue and input.venue.event == .execution_report and candidate.oms.recovery_only and
                generated.len > 0 and generated[generated.len - 1].kind == .canonical_order_reconciliation
        else
            false;
        const deferred_admission = if (replay_error) |err| err == error.HistorySafetyCapacity and generated.len != 0 and generated[generated.len - 1].kind == .canonical_history_deferred else false;
        if (replay_error != null and !deferred_admission and candidate.canonical_account.failure == null and
            candidate.canonical_market.latestFailure() == null and candidate.economic_fault_count == shard.economic_fault_count and
            candidate.asset_configuration_failure_count == shard.asset_configuration_failure_count and !rejected_canonical_report)
            return replay_error.?;
        if (generated.len == 0) return error.InputProducedNoFact;

        for (generated, 0..) |expected, index| {
            const record = if (index == 0) first_record else switch (try reader.next()) {
                .record => |record| record,
                .end => |status| {
                    if (status == .truncated_tail)
                        return status;
                    return error.IncompleteFactGroup;
                },
            };
            try validateReplayRecord(record, expected, input, index == 0);
        }
        @memcpy(std.mem.asBytes(shard), std.mem.asBytes(&candidate));
    }
}

fn expectReplayError(bytes: []const u8, expected: anyerror) !void {
    if (replay(bytes)) |_| return error.ExpectedReplayFailure else |err| {
        if (err != expected) return err;
    }
}

pub fn assertExpectedDigest(
    digest: [Sha256.digest_length]u8,
    expected_hex: []const u8,
) !void {
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual_hex, expected_hex)) {
        std.debug.print("state digest mismatch: expected {s}, actual {s}\n", .{ expected_hex, actual_hex });
        return error.UnexpectedStateDigest;
    }
}

fn digestAssetRegistry(hasher: *Sha256, shard: *const TradingShard, include_barriers: bool) void {
    digestBool(hasher, shard.asset_configuration_failed);
    digestInt(hasher, u64, shard.asset_configuration_failure_count);
    digestInt(hasher, u8, shard.asset_registry.count);
    // Bounded configuration set; normalize by stable asset identity for semantic convergence.
    var previous: u64 = 0;
    for (0..shard.asset_registry.count) |_| {
        var next: ?asset_registry.Entry = null;
        for (shard.asset_registry.entries[0..shard.asset_registry.count]) |entry| {
            if (entry.definition.asset > previous and (next == null or entry.definition.asset < next.?.definition.asset)) next = entry;
        }
        const entry = next orelse unreachable;
        inline for (std.meta.fields(canonical.AssetDefinition)) |field| {
            const item = @field(entry.definition, field.name);
            switch (@typeInfo(field.type)) {
                .int => digestInt(hasher, field.type, item),
                .@"enum" => digestInt(hasher, u8, @intFromEnum(item)),
                .array => if (comptime std.mem.eql(u8, field.name, "code_bindings")) {
                    for (item) |binding| {
                        digestInt(hasher, u64, binding.venue);
                        digestInt(hasher, u8, binding.code_len);
                        hasher.update(&binding.code);
                    }
                } else hasher.update(&item),
                else => unreachable,
            }
        }
        if (include_barriers) digestInt(hasher, u64, entry.barrier);
        previous = entry.definition.asset;
    }
}

fn digestEconomicFault(hasher: *Sha256, shard: *const TradingShard) void {
    digestInt(hasher, u64, shard.economic_fault_count);
    if (shard.economic_fault_count != 0) {
        digestInt(hasher, u8, @intFromEnum(shard.economic_fault_reason));
        digestInt(hasher, u128, shard.economic_fault_evidence.stream);
        digestInt(hasher, u64, shard.economic_fault_evidence.sequence);
        hasher.update(&shard.economic_fault_evidence.digest);
    }
}

test "recovery retains admission fence and durable rejection without publishing truncated input" {
    const allocator = std.testing.allocator;
    const live = try allocator.create(TradingShard);
    defer allocator.destroy(live);
    live.* = .{};
    const initial = try allocator.create(TradingShard);
    defer allocator.destroy(initial);
    initial.* = .{ .recovery_admission_pending = true };
    const recovered = try allocator.create(TradingShard);
    defer allocator.destroy(recovered);
    var log = journal.Journal.init();
    const definition = asset_registry.testDefinitions(6, 8)[0];
    // Keep fixture setup transactions out of the recovery caller's stack frame.
    _ = try @call(.never_inline, applyStable, .{ live, &log, CanonicalEvent{ .core = .{ .identity = 1, .payload = .{ .asset_definition_activated = definition } } } });
    const prefix_digest = live.canonicalStateDigest();
    const prefix_len = log.len;
    var conflict = definition;
    conflict.source_digest = @splat(9);
    try std.testing.expectError(error.AssetDefinitionConflict, @call(.never_inline, applyStable, .{ live, &log, CanonicalEvent{ .core = .{ .identity = 2, .payload = .{ .asset_definition_activated = conflict } } } }));
    try log.seal();
    try std.testing.expectEqual(journal.ScanStatus.clean, try recoverStableInto(recovered, initial, log.bytes()));
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &recovered.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 1), recovered.asset_configuration_failure_count);
    try std.testing.expect(recovered.oms.recovery_only);
    try std.testing.expect(recovered.recovery_admission_pending);
    try std.testing.expectError(error.RecoveryAdmissionPending, @call(.never_inline, TradingShard.apply, .{ recovered, CanonicalEvent{ .core = .{ .identity = 3, .payload = .{ .timer = .{ .side = .buy, .time_in_force = .good_til_canceled, .portfolio_reduce_only = false, .quantity = 1, .limit_price_micros = 1 } } } } }));
    try std.testing.expectEqual(journal.ScanStatus.truncated_tail, try recoverStableInto(recovered, initial, log.bytes()[0 .. prefix_len + 1]));
    try std.testing.expectEqualSlices(u8, &prefix_digest, &recovered.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 0), recovered.asset_configuration_failure_count);
    try std.testing.expect(recovered.recovery_admission_pending);
}

test "asset definition activation rejects rescaling and survives snapshot" {
    var shard = TradingShard{};
    var log = journal.Journal.init();
    const definition: canonical.AssetDefinition = .{ .asset = 1, .atomic_scale = 12, .version = 1, .source_identity = 9, .source_digest = @splat(7), .source_kind = .test_fixture, .max_single_atoms = 1_000_000_000_000, .max_balance_atoms = 10_000_000_000_000, .max_cumulative_atoms = 100_000_000_000_000, .max_quantity_lots = 1000, .max_price_ticks = 1000, .max_rescale_power = 12, .max_postings = 4 };
    _ = try applyStable(&shard, &log, .{ .core = .{ .identity = 1, .payload = .{ .asset_definition_activated = definition } } });
    try std.testing.expectEqual(@as(u8, 12), shard.activatedAssets().get(1).?.definition.atomic_scale);
    try std.testing.expect(!shard.genesisReady());
    var changed = definition;
    changed.version = 2;
    changed.atomic_scale = 6;
    try std.testing.expectError(error.AssetPrecisionChange, applyStable(&shard, &log, .{ .core = .{ .identity = 2, .payload = .{ .asset_definition_activated = changed } } }));
    try std.testing.expectEqual(@as(u8, 12), shard.activatedAssets().get(1).?.definition.atomic_scale);
    try log.seal();
    var bytes: [@import("durable_store.zig").max_snapshot_bytes]u8 = undefined;
    const restored = try TradingShard.restoreSnapshot(try shard.snapshot(&log, shard.authoritativeBarrier(), &bytes));
    try std.testing.expectEqualDeep(shard.activatedAssets(), restored.shard.activatedAssets());
}

test "asset definition idempotence conflicts regression and invalid ranges are durable" {
    var shard = TradingShard{};
    var log = journal.Journal.init();
    var definition = asset_registry.testDefinitions(6, 8)[0];
    _ = try applyStable(&shard, &log, .{ .core = .{ .identity = 1, .payload = .{ .asset_definition_activated = definition } } });
    const before = shard.canonicalStateDigest();
    _ = try applyStable(&shard, &log, .{ .core = .{ .identity = 2, .payload = .{ .asset_definition_activated = definition } } });
    try std.testing.expectEqualSlices(u8, &before, &shard.canonicalStateDigest());
    var conflict = definition;
    conflict.source_digest = @splat(9);
    try std.testing.expectError(error.AssetDefinitionConflict, applyStable(&shard, &log, .{ .core = .{ .identity = 3, .payload = .{ .asset_definition_activated = conflict } } }));
    definition.version = 2;
    _ = try applyStable(&shard, &log, .{ .core = .{ .identity = 4, .payload = .{ .asset_definition_activated = definition } } });
    definition.version = 1;
    try std.testing.expectError(error.AssetDefinitionRegression, applyStable(&shard, &log, .{ .core = .{ .identity = 5, .payload = .{ .asset_definition_activated = definition } } }));
    var invalid = asset_registry.testDefinitions(6, 8)[1];
    invalid.max_postings = 5;
    try std.testing.expectError(error.InvalidAssetDefinition, applyStable(&shard, &log, .{ .core = .{ .identity = 6, .payload = .{ .asset_definition_activated = invalid } } }));
    invalid.max_postings = 4;
    invalid.max_rescale_power = 38;
    try std.testing.expectError(error.AssetRangeOverflow, applyStable(&shard, &log, .{ .core = .{ .identity = 7, .payload = .{ .asset_definition_activated = invalid } } }));
    invalid = asset_registry.testDefinitions(6, 8)[1];
    invalid.max_postings = 1;
    try std.testing.expectError(error.InvalidAssetDefinition, applyStable(&shard, &log, .{ .core = .{ .identity = 8, .payload = .{ .asset_definition_activated = invalid } } }));
    try std.testing.expectEqual(@as(u64, 5), shard.asset_configuration_failure_count);
    try std.testing.expect(shard.oms.recovery_only);
    try log.seal();
    const initial = try std.testing.allocator.create(TradingShard);
    defer std.testing.allocator.destroy(initial);
    initial.* = .{};
    const recovered = try std.testing.allocator.create(TradingShard);
    defer std.testing.allocator.destroy(recovered);
    try std.testing.expectEqual(journal.ScanStatus.clean, try recoverStableInto(recovered, initial, log.bytes()));
    try std.testing.expectEqualSlices(u8, &shard.canonicalStateDigest(), &recovered.canonicalStateDigest());
}

test "cold account reconciliation proves every archived Fill before applying and rejects incomplete coverage" {
    const fixture = @import("trading_shard_fixture.zig");
    const durable = @import("durable_store.zig");
    const allocator = std.testing.allocator;
    for ([_]enum { matching, absent, conflict, short }{ .matching, .absent, .conflict, .short }) |mode| {
        const shard = try allocator.create(TradingShard);
        defer allocator.destroy(shard);
        shard.* = .{};
        shard.exchange_account_identity = 2;
        shard.portfolio_identity = 1;
        shard.opening_balance_observed = true;
        shard.economic_baseline_utc_ns = 100;
        _ = try shard.asset_registry.activate(asset_registry.testDefinitions(6, 8)[0], 1);
        // This isolates coverage authentication; Owner tests create and archive the actual economic facts.
        shard.economic_projection.archived_fill_count = 2;
        shard.economic_projection.seen[0] = .{ .kind = .fill, .identity = 3, .fingerprint = 0, .canonical_digest = history.hash("hot Fill") };
        shard.economic_projection.seen_count = 1;
        shard.economic_projection.canonical_fill_evidence[0] = .{ .identity = 3, .order_id = 3, .quantity = 1, .digest = history.hash("hot Fill") };
        shard.economic_projection.canonical_fill_evidence_count = 1;
        shard.economic_projection.applied_fills[0] = .{ .fill = .{ .identity = 3, .order_id = 3, .side = .buy, .product = .spot, .quantity = .{ .instrument = 3, .rules_version = 1, .lots = 1 }, .price = .{ .instrument = 3, .rules_version = 1, .ticks = 1 }, .price_tick_value = .{ .asset = 1, .atoms = 1 }, .quantity_denominator = 1 }, .payload_digest = history.hash("hot Fill"), .canonical_accounted = true };
        shard.economic_projection.applied_fill_count = 1;
        shard.economic_projection.applied_fill_totals[0] = .{ .order_id = 3, .quantity = 1 };
        shard.economic_projection.applied_fill_total_count = 1;
        const memory = try allocator.create(durable.MemoryAdapter);
        defer allocator.destroy(memory);
        memory.* = .initWithAllocator(allocator);
        defer memory.deinit();
        const store = memory.interface();
        const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 901 }, .account = 2 };
        const first_digest = history.hash("first archived Fill");
        const second_digest = history.hash("second archived Fill");
        const records = [_]history.Record{
            .{ .bytes = &first_digest, .payload_digest = history.hash(&first_digest) },
            .{ .bytes = &second_digest, .payload_digest = history.hash(&second_digest) },
        };
        const entries = [_]history.Entry{
            .{ .key = .{ .origin = origin, .identity = .{ .fill_economic_digest = 1 } }, .record_index = 0 },
            .{ .key = .{ .origin = origin, .identity = .{ .fill_economic_digest = 2 } }, .record_index = 1 },
        };
        const receipt = try store.publishOrderHistory(undefined, .{ .origin = origin, .barrier = 1, .epoch = 1, .qualification_digest = history.hash("coverage qualification"), .records = &records, .entries = &entries });
        shard.business_history_root = receipt.root;
        var evidence: canonical.AccountEconomicEvidence = .{
            .exchange_account = 2,
            .scope = .spot_and_isolated_linear_usdt,
            .from_utc_ns = 100,
            .through_utc_ns = 200,
            .source = .{ .stream = 1, .sequence = 4, .digest = history.hash("closing snapshot") },
            .balance_count = 1,
            .before_balance_count = 1,
            .covered_economic_fact_count = if (mode == .short) 2 else 3,
            .before_source = .{ .stream = 1, .sequence = 1, .digest = history.hash("opening snapshot") },
            .query_count = 1,
            .bills_complete = true,
            .bill_chain_digest = history.hash("complete bills"),
        };
        evidence.balances[0] = .{ .asset = 1, .atoms = 0 };
        evidence.before_balances[0] = evidence.balances[0];
        evidence.asset_versions[0] = 1;
        evidence.query_sources[0] = .{ .stream = 1, .sequence = 2, .digest = history.hash("bill query") };
        evidence.facts[0] = .{ .identity = if (mode == .absent) 404 else 1, .kind = .fill, .digest = if (mode == .conflict) history.hash("conflicting Fill") else first_digest, .fee_confirmed = true };
        evidence.facts[1] = .{ .identity = 3, .kind = .fill, .digest = history.hash("hot Fill"), .fee_confirmed = true };
        evidence.facts[2] = .{ .identity = 2, .kind = .fill, .digest = second_digest, .fee_confirmed = true };
        var original = fixture.canonicalAt(1, 4, .{ .account_reconciliation_result = .{ .identity = 10, .complete = true, .account_economics = evidence } });
        original.venue.envelope.raw_evidence = evidence.source;
        original.venue.envelope.times.source_utc_ns = evidence.through_utc_ns;
        const bound: TradingShard.VerifiedAccountCoverage = .{ .input_digest = try TradingShard.accountCoverageInputDigest(original.venue), .root_digest = receipt.root.root_digest };
        var retimed = original.venue;
        retimed.envelope.times.receive_utc_ns = original.venue.envelope.times.receive_utc_ns.? + 1;
        try std.testing.expectError(error.InvalidHistoryCandidate, shard.applyNativeReconciliation(retimed, retimed.event.account_reconciliation_result, evidence, bound));
        var wrong_root = bound;
        wrong_root.root_digest[0] ^= 1;
        try std.testing.expectError(error.InvalidHistoryCandidate, shard.applyNativeReconciliation(original.venue, original.venue.event.account_reconciliation_result, evidence, wrong_root));
        _ = try shard.apply(original);
        try std.testing.expectEqual(@as(?u8, 0), shard.pending_history_member_index);
        const economic_digest = shard.economic_projection.digest();
        const first_proof = try store.queryOrderHistory(undefined, shard.pending_history_candidate.?.request);
        const proof_input: CanonicalEvent = .{ .core = .{ .identity = 1, .payload = .{ .history_candidate_verified = first_proof.proof } } };
        if (mode == .short) {
            const owned = try allocator.create(TradingShard);
            defer allocator.destroy(owned);
            copyTradingState(owned, shard);
            var publish = false;
            try std.testing.expectError(error.IncompleteReconciliationEvidence, owned.applyOwnedCandidate(shard, proof_input, &publish));
            try std.testing.expect(publish and owned.oms.recovery_only);
            try std.testing.expectEqual(shard.economic_fault_count + 1, owned.economic_fault_count);
            try std.testing.expectError(error.IncompleteReconciliationEvidence, shard.apply(proof_input));
            try std.testing.expect(shard.oms.recovery_only);
            try std.testing.expectEqual(@as(u64, 2), shard.economic_projection.archived_fill_count);
            continue;
        }
        _ = try shard.apply(proof_input);
        try std.testing.expectEqualSlices(u8, &economic_digest, &shard.economic_projection.digest());
        try std.testing.expectEqual(@as(u64, 0), shard.canonical_ingress_count);
        if (mode == .absent or mode == .conflict) {
            try std.testing.expect(shard.history_conflict_latched);
            try std.testing.expect(shard.oms.recovery_only);
            continue;
        }
        try std.testing.expectEqual(@as(?u8, 2), shard.pending_history_member_index);
        const second_proof = try store.queryOrderHistory(undefined, shard.pending_history_candidate.?.request);
        _ = try shard.apply(.{ .core = .{ .identity = 2, .payload = .{ .history_candidate_verified = second_proof.proof } } });
        try std.testing.expect(shard.pending_history_candidate == null);
        try std.testing.expectEqual(@as(u64, 1), shard.canonical_ingress_count);
        try std.testing.expectEqual(@as(u8, 2), shard.economic_projection.seen_count);
        try std.testing.expect(!shard.economic_projection.reconciliation_break);
        try std.testing.expectEqual(@as(u64, 2), shard.economic_projection.archived_fill_count);
        try std.testing.expectEqual(@as(u8, 0), shard.economic_projection.ledger_count);
        const before_duplicate = shard.canonicalStateDigest();
        _ = try shard.apply(original);
        try std.testing.expectEqualSlices(u8, &before_duplicate, &shard.canonicalStateDigest());
        try std.testing.expect(!shard.history_conflict_latched);
    }
}

test "cold core staging preserves candidate and blocks fresh risk before proof" {
    var shard = TradingShard{};
    shard.exchange_account_identity = 9;
    const root = coldCoreTestRoot();
    shard.business_history_root = root;
    var group: oms.IntentGroup = .{ .first_intent_sequence = 7, .count = 1 };
    group.members[0] = .{ .intent_sequence = 7, .strategy_instance = 3, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    const original: CanonicalEvent = .{ .core = .{ .identity = 10, .receive_time = 40, .time_presence = .{ .receive = true }, .payload = .{ .oms_intent_group = group } } };
    const pending = (try shard.historyCandidateFor(original)).?;
    _ = try shard.apply(.{ .core = .{ .identity = 11, .payload = .{ .history_candidate_started = pending } } });
    try std.testing.expect(shard.pending_history_candidate != null);
    try std.testing.expectEqual(@as(u64, 0), shard.canonical_ingress_count);
    try std.testing.expectEqual(@as(u8, 0), shard.oms.order_count);
    try std.testing.expectError(error.HistoryLookupPending, shard.apply(original));
}

fn coldCoreTestRoot() history.Root {
    var root: history.Root = .{ .origin = .{ .stream = .{ .domain = .decision_log, .id = 71 }, .account = 9 }, .generation = 1, .barrier = 1, .epoch = 1, .tree_offset = 0, .tree_digest = @splat(1), .previous_root = @splat(0), .batch_digest = @splat(2), .qualification_digest = @splat(3), .root_digest = @splat(0) };
    root.root_digest = history.rootDigest(root);
    return root;
}

// Avoid Debug's full-state assignment temporaries; the transaction still owns exactly one candidate copy.
fn copyTradingState(destination: *TradingShard, source: *const TradingShard) void {
    @memcpy(std.mem.asBytes(destination), std.mem.asBytes(source));
}

test "optimization borrowed canonical snapshot matches copy canonicalization without mutating source" {
    const allocator = std.testing.allocator;
    const source = try allocator.create(TradingShard);
    defer allocator.destroy(source);
    source.* = .{};
    source.fenced_strategy_count = 1;
    source.fenced_strategy_instances[0] = 17;
    source.fenced_strategy_instances[1] = 91;
    source.asset_registry.entries[0].definition.asset = 77;
    source.trace.events[0].identity = 42;
    source.canonical_account.seen[0].identity = 123;
    source.canonical_ingress_cursors[0].identity.sequence = 321;
    source.oms.command_count = 1;
    source.economic_projection.ledger_count = 1;
    source.economic_projection.ledger[0].posting_count = 1;
    source.economic_projection.ledger[0].postings[1] = std.mem.zeroes(economics_module.LedgerPosting);
    const original = try allocator.create(TradingShard);
    defer allocator.destroy(original);
    original.* = source.*;
    const canonical_copy = try allocator.create(TradingShard);
    defer allocator.destroy(canonical_copy);
    canonical_copy.* = source.*;
    canonicalizeSnapshotState(canonical_copy);
    const old_buffer = try allocator.alloc(u8, 32 * 1024 * 1024);
    defer allocator.free(old_buffer);
    const new_buffer = try allocator.alloc(u8, old_buffer.len);
    defer allocator.free(new_buffer);
    const metadata: snapshot_codec.Metadata = .{
        .state_schema = state_schema_version,
        .release_artifact = release_artifact_identity,
        .schema_registry = schema_registry_identity,
        .barrier = 1,
        .instrument_rules_version = source.instrument_rules_version,
        .margin_rules_version = source.margin_rules_version,
        .state_digest = @splat(9),
    };
    const old_bytes = try snapshot_codec.write(old_buffer, metadata, canonical_copy);
    const new_bytes = try snapshot_codec.writeWithPolicy(new_buffer, metadata, source, CoreSnapshotEncodingPolicy);
    try std.testing.expectEqualSlices(u8, old_bytes, new_bytes);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(original), std.mem.asBytes(source));
    const legacy_start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..3) |_| {
        canonical_copy.* = source.*;
        canonicalizeSnapshotState(canonical_copy);
        const encoded = try snapshot_codec.write(old_buffer, metadata, canonical_copy);
        try std.testing.expectEqualSlices(u8, encoded, new_bytes);
    }
    const legacy_end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    for (0..3) |_| {
        const encoded = try snapshot_codec.writeWithPolicy(new_buffer, metadata, source, CoreSnapshotEncodingPolicy);
        try std.testing.expectEqualSlices(u8, old_bytes, encoded);
    }
    const borrowed_end = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    std.debug.print("snapshot comparison: 3 identical encodings, legacy={d} us borrowed={d} us bytes={d}\n", .{
        @divTrunc(legacy_end - legacy_start, 1000),
        @divTrunc(borrowed_end - legacy_end, 1000),
        new_bytes.len,
    });
}

test "optimization owned stable candidate preserves public commits rejects duplicates and journal rollback" {
    const allocator = std.testing.allocator;
    const fixture = @import("trading_shard_fixture.zig");
    const public = try allocator.create(TradingShard);
    defer allocator.destroy(public);
    public.* = .{};
    const committed = try allocator.create(TradingShard);
    defer allocator.destroy(committed);
    committed.* = .{};
    const candidate = try allocator.create(TradingShard);
    defer allocator.destroy(candidate);
    var public_log = journal.Journal.init();
    var owned_log = journal.Journal.init();
    const genesis = fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged);
    for (genesis) |input| {
        const expected = try applyStable(public, &public_log, input);
        candidate.* = committed.*;
        const actual = try applyStableOnCandidate(candidate, committed, &owned_log, input);
        committed.* = candidate.*;
        try std.testing.expectEqualDeep(expected, actual);
        try std.testing.expectEqualSlices(u8, &public.canonicalStateDigest(), &committed.canonicalStateDigest());
        try std.testing.expectEqualSlices(u8, public_log.bytes(), owned_log.bytes());
    }
    const asset_input = for (genesis) |input| {
        if (input == .core and input.core.payload == .asset_definition_activated) break input;
    } else unreachable;
    // An exact asset-definition duplicate produces no additional durable fact.
    candidate.* = committed.*;
    _ = try applyStable(public, &public_log, asset_input);
    _ = try applyStableOnCandidate(candidate, committed, &owned_log, asset_input);
    try std.testing.expectEqualSlices(u8, &public.canonicalStateDigest(), &committed.canonicalStateDigest());
    try std.testing.expectEqualSlices(u8, public_log.bytes(), owned_log.bytes());
    // An authoritative rejection still commits its error fact group.
    var invalid = asset_input;
    invalid.core.identity += 1000;
    invalid.core.payload.asset_definition_activated.atomic_scale = 255;
    const before = owned_log.last_sequence;
    candidate.* = committed.*;
    var public_error: ?anyerror = null;
    _ = applyStable(public, &public_log, invalid) catch |err| blk: {
        public_error = err;
        break :blk null;
    };
    var owned_error: ?anyerror = null;
    _ = applyStableOnCandidate(candidate, committed, &owned_log, invalid) catch |err| blk: {
        owned_error = err;
        break :blk null;
    };
    if (owned_log.last_sequence != before) committed.* = candidate.*;
    try std.testing.expect(public_error != null);
    try std.testing.expectEqual(public_error, owned_error);
    try std.testing.expectEqualSlices(u8, &public.canonicalStateDigest(), &committed.canonicalStateDigest());
    try std.testing.expectEqualSlices(u8, public_log.bytes(), owned_log.bytes());
    try public_log.seal();
    try owned_log.seal();
    const digest_before = committed.canonicalStateDigest();
    candidate.* = committed.*;
    public_error = null;
    _ = applyStable(public, &public_log, invalid) catch |err| blk: {
        public_error = err;
        break :blk null;
    };
    owned_error = null;
    _ = applyStableOnCandidate(candidate, committed, &owned_log, invalid) catch |err| blk: {
        owned_error = err;
        break :blk null;
    };
    try std.testing.expect(public_error != null);
    try std.testing.expectEqual(public_error, owned_error);
    try std.testing.expectEqualSlices(u8, &digest_before, &public.canonicalStateDigest());
    try std.testing.expectEqualSlices(u8, public_log.bytes(), owned_log.bytes());
}

test "optimization owned Core and Venue rollback matches nested public candidates" {
    const allocator = std.testing.allocator;
    const fixture = @import("trading_shard_fixture.zig");
    const legacy = try allocator.create(TradingShard);
    defer allocator.destroy(legacy);
    legacy.* = .{};
    const committed = try allocator.create(TradingShard);
    defer allocator.destroy(committed);
    committed.* = .{};
    const candidate = try allocator.create(TradingShard);
    defer allocator.destroy(candidate);
    const Check = struct {
        fn step(old: *TradingShard, current: *TradingShard, work: *TradingShard, input: CanonicalEvent) !void {
            work.* = current.*;
            var expected_error: ?anyerror = null;
            _ = old.apply(input) catch |err| blk: {
                expected_error = err;
                break :blk ApplyResult{ .facts = &.{}, .order_command = null, .oms_commands = &.{} };
            };
            var publish = false;
            var actual_error: ?anyerror = null;
            _ = work.applyOwnedCandidate(current, input, &publish) catch |err| blk: {
                actual_error = err;
                break :blk ApplyResult{ .facts = &.{}, .order_command = null, .oms_commands = &.{} };
            };
            if (actual_error == null or publish) current.* = work.*;
            try std.testing.expectEqual(expected_error, actual_error);
            try std.testing.expectEqualSlices(u8, &old.canonicalStateDigest(), &current.canonicalStateDigest());
            try std.testing.expectEqualDeep(old.trace.events[0..old.trace.len], current.trace.events[0..current.trace.len]);
            try std.testing.expectEqualDeep(old.oms.emitted(), current.oms.emitted());
        }
    };
    for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged)) |input|
        try Check.step(legacy, committed, candidate, input);
    try Check.step(legacy, committed, candidate, fixture.snapshotAt(20, 1));
    try Check.step(legacy, committed, candidate, fixture.atGroup(21, .{ .identity = 21, .payload = .{ .mark_price = .{ .instrument = 3, .price_atoms = -1 } } }));
    var unsupported = fixture.snapshotAt(22, 2);
    unsupported.venue.envelope.schema_version += 1;
    try Check.step(legacy, committed, candidate, unsupported);
    // A discontinuous book invalidates market authority and publishes its fault.
    try Check.step(legacy, committed, candidate, fixture.deltaAt(23, 999, 1000, 49_800_000));
    try Check.step(legacy, committed, candidate, fixture.canonicalAt(24, 1001, .{ .execution_report = .{
        .identity = 1001,
        .order = 999,
        .client_order_id = .{},
        .instrument = 3,
        .exchange_account = 2,
        .revision = 1,
        .status = .accepted,
        .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 0 },
        .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 20 },
    } }));
}
