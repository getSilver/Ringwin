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

    pub fn canonicalStateDigest(self: ReplayTradingShard) [Sha256.digest_length]u8 {
        return self.shard.canonicalStateDigest();
    }
};

/// Strictly decoded authoritative snapshot and its exact journal barrier.
pub const SnapshotRestore = struct {
    shard: TradingShard,
    barrier: u64,
};

/// Recovered authoritative state and the stable tail scan result.
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

fn canonicalPayloadDigest(event: canonical.Payload) ![Sha256.digest_length]u8 {
    var payload_bytes: [canonical_event_codec.max_encoded_len]u8 = undefined;
    const payload = try canonical_event_codec.encodePayload(&payload_bytes, event);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    return digest;
}
const max_canonical_ingress_streams = 16;

pub const TradingShard = struct {
    /// Restart admission is separate from deterministic economic state: Owner
    /// re-arms it on every recovery. Snapshot encoding preserves the fence;
    /// canonical/semantic digests deliberately describe committed facts only.
    recovery_admission_pending: bool = false,
    trace: Trace = .{},
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
    asset_registry: asset_registry.Registry = .{},
    asset_configuration_failed: bool = false,
    asset_configuration_failure_count: u64 = 0,
    /// Single source of product/rules semantics. The scalar fields above are
    /// retained only as the normalized legacy active-instrument view.
    instrument_registry: instrument_registry.Registry = .{},

    /// The sole public core ingress seam. Both typed core events and canonical
    /// Venue records enter through this tagged event and commit transactionally.
    pub fn apply(self: *TradingShard, input: CanonicalEvent) !ApplyResult {
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
            .core => |event| self.applyCore(event),
            .venue => |event| self.applyVenue(event),
        };
    }

    fn applyVenue(self: *TradingShard, event: canonical.EventRecord) !ApplyResult {
        var candidate = self.*;
        const account_failure_before = candidate.canonical_account.failure;
        const market_failure_generation_before = candidate.canonical_market.failure_generation;
        const before = candidate.trace.len;
        candidate.oms.begin();
        const command = blk: {
            if (event.envelope.schema_version != canonical.schema_version) return error.UnsupportedSchema;
            break :blk candidate.handleCanonical(event);
        } catch |err| {
            // Projection invalidation is authoritative even when the public
            // apply call reports the rejected observation. This is the only
            // exception to the ordinary candidate-commit-on-success rule.
            if (err == error.TombstoneFactConflict or err == error.ArchivedFactOutsideRetention or err == error.TerminalFactConflict or
                (event.event == .execution_report and event.envelope.exchange_account == self.exchange_account_identity and
                    (err == error.InvalidExecutionReport or err == error.StaleOrderRevision)))
            {
                candidate.oms.recovery_only = true;
                if (candidate.operational_state.initialized) try candidate.applyOperationalGate(.{
                    .gate_identity = event.envelope.identity.sequence,
                    .target_identity = candidate.operational_state.target_identity,
                    .kind = .latched,
                    .reason = .reconciliation_break,
                    .open = false,
                });
                try candidate.trace.append(.canonical_order_reconciliation, event.envelope.identity.sequence);
                self.* = candidate;
            } else if ((event.event == .fill or event.event == .funding_settlement or
                (event.event == .account_reconciliation_result and event.event.account_reconciliation_result.account_economics != null)) and event.envelope.exchange_account == self.exchange_account_identity)
            {
                candidate = self.*;
                candidate.oms.begin();
                if (event.event == .account_reconciliation_result) {
                    if (std.math.cast(u64, event.event.account_reconciliation_result.identity)) |identity| {
                        // Preserve verified identity for an unresolved result. A full
                        // evidence store or existing conflict retains the original fault.
                        _ = candidate.economic_projection.retainCanonicalSnapshot(identity, try canonicalPayloadDigest(event.event)) catch false;
                    }
                }
                try candidate.latchEconomicFault(event, switch (err) {
                    error.Overflow, error.QuantityOutOfRange, error.PriceOutOfRange, error.AssetAmountOutOfRange => .overflow,
                    error.NativeAssetCapacityExceeded, error.LedgerCapacityExceeded, error.EconomicFactCapacityExceeded, error.SafetyGateSetFull => .capacity_exhausted,
                    error.UnknownAssetDefinition => .unknown_asset,
                    error.MissingFillFee => .missing_amount,
                    error.InexactEconomicAmount => .inexact_amount,
                    else => .invalid_economic_fact,
                });
                try candidate.bindFreshCancellations(event.envelope.times.monotonic_ns orelse 0);
                self.* = candidate;
            } else if ((event.event == .account_bootstrap_snapshot or event.event == .account_observed) and
                (err == error.UnknownAssetDefinition or err == error.AssetAmountOutOfRange))
            {
                candidate = self.*;
                candidate.oms.begin();
                try candidate.latchEconomicFault(event, if (err == error.UnknownAssetDefinition) .unknown_asset else .overflow);
                self.* = candidate;
            } else if (candidate.canonical_account.failure != account_failure_before) {
                try candidate.latchEconomicFault(event, .invalid_economic_fact);
                try candidate.bindFreshCancellations(event.envelope.times.monotonic_ns orelse 0);
                self.* = candidate;
            } else if (candidate.canonical_market.failure_generation != market_failure_generation_before) {
                if (candidate.operational_state.initialized) try candidate.applyOperationalGate(.{
                    .gate_identity = market_data_gate_identity,
                    .target_identity = candidate.operational_state.target_identity,
                    .kind = .self_recovering,
                    .reason = .market_data,
                    .open = false,
                });
                try candidate.trace.append(.canonical_market_invalidated, event.envelope.identity.sequence);
                self.* = candidate;
            }
            return err;
        };
        try candidate.bindFreshCancellations(event.envelope.times.monotonic_ns orelse 0);
        self.* = candidate;
        return .{
            .facts = self.trace.events[before..self.trace.len],
            .order_command = command,
            .oms_commands = self.oms.emitted(),
        };
    }

    fn applyCore(self: *TradingShard, event: CoreEvent) !ApplyResult {
        var candidate = self.*;
        const before = candidate.trace.len;
        candidate.oms.begin();
        const command = candidate.handle(event) catch |err| {
            if (event.payload == .asset_definition_activated) {
                candidate.asset_configuration_failed = true;
                candidate.asset_configuration_failure_count = try std.math.add(u64, self.asset_configuration_failure_count, 1);
                candidate.oms.recovery_only = true;
                try candidate.trace.append(.asset_definition_rejected, event.identity);
                self.* = candidate;
            }

            if (err == error.TombstoneFactConflict or err == error.ArchivedFactOutsideRetention or err == error.TerminalFactConflict) {
                candidate.oms.recovery_only = true;
                if (candidate.operational_state.initialized) try candidate.applyOperationalGate(.{
                    .gate_identity = event.identity,
                    .target_identity = candidate.operational_state.target_identity,
                    .kind = .latched,
                    .reason = .reconciliation_break,
                    .open = false,
                });
                try candidate.trace.append(.oms_reconciliation_result, event.identity);
                self.* = candidate;
            }
            return err;
        };
        try candidate.bindFreshCancellations(if (event.time_presence.monotonic) event.monotonic_time else 0);
        self.* = candidate;
        return .{
            .facts = self.trace.events[before..self.trace.len],
            .order_command = command,
            .oms_commands = self.oms.emitted(),
        };
    }

    pub fn canonicalStateDigest(self: TradingShard) [Sha256.digest_length]u8 {
        return stateDigest(self);
    }

    pub fn appliedHostActivation(self: *const TradingShard, stable_journal: *const journal.Journal) !host_gateway.AppliedActivation {
        if (self.host_activation_identity == 0 or self.host_activation_fact_sequence == 0 or
            stable_journal.last_sequence != self.trace.len or
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
    /// remains the ordered Trace/snapshot integrity digest.
    pub fn semanticAuthorityDigest(self: TradingShard) [Sha256.digest_length]u8 {
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
        self: TradingShard,
        stable_journal: *const journal.Journal,
        barrier: u64,
        destination: []u8,
    ) ![]const u8 {
        if (!stable_journal.sealed or barrier == 0 or
            barrier != stable_journal.last_sequence or self.trace.len != barrier)
            return error.InvalidSnapshotBarrier;
        var authoritative = self;
        canonicalizeSnapshotState(&authoritative);
        return snapshot_codec.write(destination, .{
            .state_schema = state_schema_version,
            .release_artifact = release_artifact_identity,
            .schema_registry = schema_registry_identity,
            .barrier = barrier,
            .instrument_rules_version = self.instrument_rules_version,
            .margin_rules_version = self.margin_rules_version,
            .state_digest = self.canonicalStateDigest(),
        }, authoritative);
    }

    /// Restores a validated snapshot through the side-effect-free replay seam.
    pub fn restoreSnapshot(encoded: []const u8) !SnapshotRestore {
        const decoded = try snapshot_codec.read(
            encoded,
            TradingShard,
            state_schema_version,
            release_artifact_identity,
            schema_registry_identity,
        );
        var recovered = decoded.value;
        recovered.oms.begin();
        try validateSnapshotState(&recovered);
        const metadata = decoded.metadata;
        const digest = recovered.canonicalStateDigest();
        if (metadata.barrier == 0 or recovered.trace.len != metadata.barrier or
            recovered.instrument_rules_version != metadata.instrument_rules_version or
            recovered.margin_rules_version != metadata.margin_rules_version or
            !std.mem.eql(u8, &metadata.state_digest, &digest))
            return error.InvalidSnapshotState;
        return .{ .shard = recovered, .barrier = metadata.barrier };
    }

    /// Restores a snapshot and semantically replays its immediately following journal segment.
    pub fn restore(encoded: []const u8, stable_tail: []const u8) !SnapshotRecovery {
        const restored = try restoreSnapshot(encoded);
        var reader = try journal.Reader.init(stable_tail);
        if (reader.next_sequence != restored.barrier + 1) return error.SnapshotJournalGap;
        const recovered = try replayReader(&reader, restored.shard);
        return .{ .shard = recovered.shard, .barrier = restored.barrier, .status = recovered.status };
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
        var pending = false;
        for (self.trace.events[0..self.trace.len]) |fact| switch (fact.kind) {
            .canonical_account_reconciliation_started => pending = true,
            .canonical_account_reconciliation => pending = false,
            else => {},
        };
        return pending;
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
        var group_sell_atoms: i128 = 0;
        for (qualified.members[0..qualified.count]) |*intent| {
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
                    if (order.instrument != intent.instrument or order.side != .sell) continue;
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
                    committed_sell_atoms = try std.math.add(i128, committed_sell_atoms, try std.math.mul(i128, remaining, unit.atoms));
                }
                for (self.oms.tombstones[0..self.oms.tombstone_count]) |archived| {
                    if (archived.instrument != intent.instrument) continue;
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
                        committed_sell_atoms = try std.math.add(i128, committed_sell_atoms, try std.math.mul(i128, remaining, unit.atoms));
                }
                group_sell_atoms = try std.math.add(i128, group_sell_atoms, try std.math.mul(i128, pending_lots, unit.atoms));
                const required = try std.math.add(i128, committed_sell_atoms, group_sell_atoms);
                if (required > self.economic_projection.portfolio.spot_asset_atoms or
                    required > self.economic_projection.exchange.spot_asset_atoms) return error.InsufficientSpotAsset;
            }
            try validateExactOmsSpec(intent.*, instrument_config);
            try self.checkAssetAmounts(canonical.InstrumentQuantity{ .instrument = intent.instrument, .rules_version = instrument_config.rules.version, .lots = intent.quantity }, true);
            try self.checkAssetAmounts(intent.limit_price, true);
            if (intent.market_protection_price) |price| try self.checkAssetAmounts(price, true);
            const portfolio_position_quantity = if (instrument_config.product == .spot)
                self.spotPortfolioPosition().quantity
            else
                self.portfolioPosition().quantity;
            const exchange_position_quantity = if (instrument_config.product == .spot)
                self.spotExchangePosition().quantity
            else
                self.exchangePosition().quantity;
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
        var candidate = self.*;
        var group: oms_module.IntentGroup = .{ .first_intent_sequence = replacement.intent_sequence, .count = 1 };
        group.members[0] = replacement;
        const qualified = candidate.qualifyOmsGroup(group) catch |err| switch (err) {
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
            => {
                try self.oms.discardReplacement(order_id);
                return null;
            },
            else => return err,
        };
        const intent = qualified.group.members[0];
        try candidate.trace.append(.risk_accepted, intent.intent_sequence);
        const decision_barrier: u64 = @intCast(candidate.trace.len);
        try candidate.trace.append(.risk_reservation_created, intent.intent_sequence);
        try candidate.oms.confirmReplacement(order_id, intent.reservation, intent.portfolio_reduce_only, intent.venue_reduce_only, intent.intent_sequence, .{
            .decision = decision_barrier,
            .reservation = @intCast(candidate.trace.len),
            .authority = try candidate.dispatchAuthorityRefs(intent.instrument, now_monotonic_ns, decision_barrier),
        });
        self.* = candidate;
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

    pub fn assertClosures(self: TradingShard) !void {
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

    fn applyEconomicProjection(self: *TradingShard, event: economics.Event) !bool {
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
            .fill => |fill| if (fill.order_id != 0) try self.economic_projection.applyCanonicalFill(fill, economics_module.coreFillDigest(fill)) else try self.economic_projection.applyChanged(event),
            else => try self.economic_projection.applyChanged(event),
        };
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
        if (self.economic_projection.base_asset != 0) {
            const base = self.asset_registry.get(self.economic_projection.base_asset) orelse return error.UnknownAssetDefinition;
            var traded_atoms: i128 = 0;
            for (self.economic_projection.ledger[0..self.economic_projection.ledger_count]) |transaction| {
                if (transaction.layer != .portfolio) continue;
                for (transaction.postings[0..transaction.posting_count]) |posting| {
                    if (posting.unit != .base_atoms or posting.account != .trade) continue;
                    const absolute = if (posting.amount < 0) try std.math.sub(i128, 0, posting.amount) else posting.amount;
                    traded_atoms = try std.math.add(i128, traded_atoms, absolute);
                }
            }
            if (traded_atoms > base.definition.max_cumulative_atoms) return error.AssetAmountOutOfRange;
        }
        var settled_funding_atoms: i128 = 0;
        for (self.economic_projection.ledger[0..self.economic_projection.ledger_count]) |transaction| {
            if (transaction.kind != .funding or transaction.layer != .exchange) continue;
            for (transaction.postings[0..transaction.posting_count]) |posting| {
                if (posting.account != .cash) continue;
                const absolute = if (posting.amount < 0) try std.math.sub(i128, 0, posting.amount) else posting.amount;
                settled_funding_atoms = try std.math.add(i128, settled_funding_atoms, absolute);
            }
        }
        if (settled_funding_atoms > quote.definition.max_cumulative_atoms) return error.AssetAmountOutOfRange;
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
            if (self.economic_projection.base_asset != 0) {
                const base = self.asset_registry.get(self.economic_projection.base_asset) orelse return error.UnknownAssetDefinition;
                try self.asset_registry.checkAmount(.{ .asset = base.definition.asset, .atoms = layer.spot_asset_atoms }, false);
                if (layer.base_fee_atoms > base.definition.max_cumulative_atoms or layer.base_rebate_atoms > base.definition.max_cumulative_atoms)
                    return error.AssetAmountOutOfRange;
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
        var index = self.trace.len;
        while (index > 0) {
            index -= 1;
            const fact = self.trace.events[index];
            if (fact.kind == kind) return fact;
        }
        return null;
    }

    fn controlCommandAtBarrier(self: *const TradingShard, barrier: u64) ?operational.ControlCommand {
        if (barrier == 0 or barrier > self.trace.len) return null;
        var command_index: usize = 0;
        for (self.trace.events[0..barrier], 0..) |fact, index| {
            if (fact.kind != .control_command_applied) continue;
            if (command_index >= self.operational_state.command_count) return null;
            const command = self.operational_state.command_history[command_index].command;
            if (index + 1 == barrier) return command;
            command_index += 1;
        }
        return null;
    }

    fn dispatchAuthorityRefs(self: *const TradingShard, instrument: canonical.InstrumentIdentity, now_monotonic_ns: u64, deadline_barrier: u64) !oms_module.DispatchAuthorityRefs {
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
            if (entry.rules_barrier != 0) {
                const fact = self.trace.events[entry.rules_barrier - 1];
                refs.instrument_rules = .{ .identity = fact.identity, .version = entry.rules.version, .barrier = entry.rules_barrier };
            }
            if (entry.capability) |profile| {
                const fact = self.trace.events[entry.capability_barrier - 1];
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
            const authority = try self.dispatchAuthorityRefs(command.instrument, now_monotonic_ns, @intCast(self.trace.len));
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
        if (self.market_health != .healthy) {
            try self.rejectSubmittedIntent(original_group, .risk_rejected_market_data, .market_data_gap);
            return null;
        }
        const qualified = self.qualifyOmsGroup(group) catch |err| switch (err) {
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
        const decision_barrier: u64 = @intCast(self.trace.len);
        try self.trace.append(.risk_reservation_created, intent.intent_sequence);
        const refs = [_]oms_module.RiskFactRefs{.{ .decision = decision_barrier, .reservation = @intCast(self.trace.len), .authority = try self.dispatchAuthorityRefs(intent.instrument_identity, now_monotonic_ns, decision_barrier) }};
        try self.oms.applyQualifiedGroup(qualified.group, original_group, &refs);
        try self.adjustMarginBuffersForReservationChange(qualified.reservation_atoms);
        const oms_command = self.oms.emitted()[0];
        self.oms.command_count = 0; // Compatibility output below is the single sendable command.
        try self.recalculateRisk(true);
        try self.trace.append(.order_command, intent.intent_sequence);
        return oms_command;
    }

    fn handleCanonical(self: *TradingShard, record: canonical.EventRecord) !?OrderCommand {
        if (record.envelope.event_type != @intFromEnum(canonical.eventType(record.event)))
            return error.CanonicalEventTypeMismatch;
        if (try self.rememberCanonicalIngress(record)) return null;
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
                const changed = try self.applyEconomicProjection(.{ .funding_settlement = .{ .identity = identity, .amount = settlement.amount, .canonical_digest = try canonicalPayloadDigest(record.event) } });
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
                if (book_snapshot.best_bid_quantity == null or book_snapshot.best_ask_quantity == null or
                    ((book_snapshot.next_ask == null) != (book_snapshot.next_ask_quantity == null)))
                    return error.IncompleteL2Book;
                try self.canonical_market.apply(record.event);
                self.expected_source_sequence = try std.math.add(u64, book_snapshot.sequence, 1);
                self.market_health = .healthy;
                self.bid_price_ticks = std.math.cast(i64, book_snapshot.best_bid.ticks) orelse return error.PriceOutOfRange;
                self.ask_1_price_ticks = std.math.cast(i64, book_snapshot.best_ask.ticks) orelse return error.PriceOutOfRange;
                self.bid_quantity = std.math.cast(i64, book_snapshot.best_bid_quantity.?.lots) orelse return error.QuantityOutOfRange;
                self.ask_1_quantity = std.math.cast(i64, book_snapshot.best_ask_quantity.?.lots) orelse return error.QuantityOutOfRange;
                self.ask_2_price_ticks = if (book_snapshot.next_ask) |price| std.math.cast(i64, price.ticks) orelse return error.PriceOutOfRange else self.ask_1_price_ticks;
                self.ask_2_quantity = if (book_snapshot.next_ask_quantity) |quantity| std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange else 0;
                if (self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = market_data_gate_identity,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .self_recovering,
                    .reason = .market_data,
                    .open = true,
                    .continuity_proven = true,
                });
                try self.trace.append(.l2_snapshot, fact_identity);
            },
            .l2_book_delta => |delta| {
                if (delta.best_bid_quantity == null or delta.best_ask_quantity == null or
                    ((delta.next_ask == null) != (delta.next_ask_quantity == null)))
                    return error.IncompleteL2Book;
                self.canonical_market.apply(record.event) catch |err| switch (err) {
                    error.MissingBookSnapshot, error.MarketGap, error.ConflictingBookDelta, error.BookSequenceGap => {
                        self.market_health = .gap;
                        if (self.operational_state.initialized) try self.applyOperationalGate(.{
                            .gate_identity = market_data_gate_identity,
                            .target_identity = self.operational_state.target_identity,
                            .kind = .self_recovering,
                            .reason = .market_data,
                            .open = false,
                        });
                        try self.trace.append(.l2_delta, fact_identity);
                        try self.trace.append(.market_gap, 1);
                        return null;
                    },
                    else => return err,
                };
                self.expected_source_sequence = try std.math.add(u64, delta.sequence, 1);
                self.bid_price_ticks = std.math.cast(i64, delta.best_bid.ticks) orelse return error.PriceOutOfRange;
                self.ask_1_price_ticks = std.math.cast(i64, delta.best_ask.ticks) orelse return error.PriceOutOfRange;
                if (delta.best_bid_quantity) |quantity| self.bid_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
                if (delta.best_ask_quantity) |quantity| self.ask_1_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
                if (delta.next_ask) |price| self.ask_2_price_ticks = std.math.cast(i64, price.ticks) orelse return error.PriceOutOfRange;
                if (delta.next_ask_quantity) |quantity| self.ask_2_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
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
                self.market_health = switch (health.health) {
                    .healthy => .healthy,
                    .awaiting_snapshot => .initializing,
                    .gap => .gap,
                };
                if (health.health != .healthy and self.operational_state.initialized)
                    try self.applyOperationalGate(.{
                        .gate_identity = market_data_gate_identity,
                        .target_identity = self.operational_state.target_identity,
                        .kind = .self_recovering,
                        .reason = .market_data,
                        .open = false,
                    });
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
                    try self.applyNativeReconciliation(record, result, evidence);
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

    fn applyNativeReconciliation(self: *TradingShard, record: canonical.EventRecord, result: canonical.ReconciliationResult, evidence: canonical.AccountEconomicEvidence) !void {
        if (record.envelope.scope != .account or record.envelope.exchange_account != self.exchange_account_identity or
            evidence.exchange_account != self.exchange_account_identity or !std.meta.eql(evidence.source, record.envelope.raw_evidence))
            return error.CanonicalScopeMismatch;
        for (self.instrument_registry.entries[0..self.instrument_registry.count]) |entry|
            if (entry.venue != record.envelope.venue) return error.CanonicalScopeMismatch;
        if (!result.complete or !self.opening_balance_observed or self.economic_baseline_utc_ns == 0 or
            evidence.from_utc_ns != self.economic_baseline_utc_ns or evidence.through_utc_ns < evidence.from_utc_ns or
            record.envelope.times.source_utc_ns != evidence.through_utc_ns)
        {
            _ = try self.economic_projection.retainCanonicalSnapshot(std.math.cast(u64, result.identity) orelse return error.IdentityOutOfRange, try canonicalPayloadDigest(record.event));
            try self.latchEconomicFault(record, .invalid_economic_fact);
            return;
        }
        if (evidence.balance_count == 0 or evidence.balance_count > evidence.balances.len or evidence.before_balance_count > evidence.before_balances.len) return error.IncompleteReconciliationEvidence;
        var facts_match = true;
        if (evidence.through_utc_ns == evidence.from_utc_ns) {
            if (evidence.covered_economic_fact_count != 0 or self.economic_projection.ledger_count != 0) {
                _ = try self.economic_projection.retainCanonicalSnapshot(std.math.cast(u64, result.identity) orelse return error.IdentityOutOfRange, try canonicalPayloadDigest(record.event));
                try self.latchEconomicFault(record, .invalid_economic_fact);
                return;
            }
        } else {
            const before = evidence.before_source orelse return error.IncompleteReconciliationEvidence;
            if (!evidence.bills_complete or evidence.covered_economic_fact_count == 0 or
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
            var money_facts: usize = 0;
            for (self.economic_projection.seen[0..self.economic_projection.seen_count]) |known| {
                if (known.kind == .forced_execution) return error.IncompleteReconciliationEvidence;
                if (known.kind == .fill or known.kind == .funding) money_facts += 1;
            }
            if (money_facts != evidence.covered_economic_fact_count) return error.IncompleteReconciliationEvidence;
            for (evidence.facts[0..evidence.covered_economic_fact_count], 0..) |fact, index| {
                for (evidence.facts[0..index]) |known| if (known.identity == fact.identity and known.kind == fact.kind) return error.IncompleteReconciliationEvidence;
                const applied = switch (fact.kind) {
                    .fill => (try self.economic_projection.lookupCanonicalFill(fact.identity, fact.digest)) == .duplicate,
                    .funding => try self.economic_projection.lookupCanonicalFunding(fact.identity, fact.digest),
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

    fn rememberCanonicalIngress(self: *TradingShard, record: canonical.EventRecord) !bool {
        const event_type = canonical.eventType(record.event);
        const payload_digest = try canonicalPayloadDigest(record.event);
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
        if (cursor_index) |index|
            if (record.envelope.identity.sequence < self.canonical_ingress_cursors[index].identity.sequence)
                return error.StaleCanonicalIdentity;
        const target_index = cursor_index orelse blk: {
            if (self.canonical_ingress_cursor_count == self.canonical_ingress_cursors.len)
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
        self.canonical_ingress_cursors[target_index] = .{
            .identity = record.envelope.identity,
            .event_type = event_type,
            .raw_digest = record.envelope.raw_evidence.digest,
            .payload_digest = payload_digest,
        };
        return false;
    }

    fn semanticDuplicate(self: *TradingShard, record: canonical.EventRecord) !bool {
        const account = if (self.exchange_account_identity != 0) self.exchange_account_identity else self.canonical_account.exchange_account orelse record.envelope.exchange_account;
        return switch (record.event) {
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
            if (configured.product == .spot) {
                const available = account.nativeAvailable(configured.rules.settlement_asset) orelse return error.ExchangeOpeningGateClosed;
                for (account.margins[0..account.margin_count]) |margin| {
                    if (margin.usd_valuation) |valuation| {
                        for ([_]?canonical.Decimal{ valuation.initial_margin, valuation.maintenance_margin, valuation.isolated_equity }) |value|
                            if (value) |amount| if (amount.coefficient != 0) return error.ExchangeOpeningGateClosed;
                    }
                }
                for (account.balances[0..account.balance_count]) |balance|
                    if (account.nativeAvailable(balance.asset) == null) return error.ExchangeOpeningGateClosed;
                for (account.positions[0..account.position_count]) |position| {
                    if (position.quantity.lots == 0) continue;
                    const positioned = self.instrumentEntry(position.instrument) orelse return error.ExchangeOpeningGateClosed;
                    if (positioned.product != .spot) return error.ExchangeOpeningGateClosed;
                }
                observed_exchange_cash = @min(observed_exchange_cash, available.atoms);
            } else {
                _ = account.nativeMarginEvidence(instrument, configured.rules.settlement_asset) orelse return error.ExchangeOpeningGateClosed;
                for (account.positions[0..account.position_count]) |position| {
                    if (position.quantity.lots == 0) continue;
                    const positioned = self.instrumentEntry(position.instrument) orelse return error.ExchangeOpeningGateClosed;
                    if (positioned.product != configured.product or positioned.rules.settlement_asset != configured.rules.settlement_asset)
                        return error.ExchangeOpeningGateClosed;
                }
                var available: ?i128 = null;
                for (account.balances[0..account.balance_count]) |balance| {
                    if (balance.asset != configured.rules.settlement_asset) continue;
                    if (available != null or balance.available.asset != balance.asset or balance.available.atoms < 0)
                        return error.ExchangeOpeningGateClosed;
                    for ([_]?canonical.AssetAmount{ balance.liability, balance.isolated_liability, balance.cross_liability }) |debt| {
                        const amount = debt orelse return error.ExchangeOpeningGateClosed;
                        if (amount.asset != balance.asset or amount.atoms != 0) return error.ExchangeOpeningGateClosed;
                    }
                    available = balance.available.atoms;
                }
                observed_exchange_cash = @min(observed_exchange_cash, available orelse return error.ExchangeOpeningGateClosed);
            }
        }
        return observed_exchange_cash;
    }

    pub fn settlementConsumersCompatible(self: *const TradingShard, instrument: canonical.InstrumentIdentity) bool {
        if (self.asset_configuration_failed) return false;
        const entry = self.instrumentEntry(instrument) orelse return false;
        if (!entry.margin_configured) return false;
        if (!self.asset_registry.hasVenueCode(entry.rules.settlement_asset, entry.venue) or
            (entry.product == .spot and !self.asset_registry.hasVenueCode(entry.rules.base_asset, entry.venue))) return false;
        const denominator = if (entry.product == .spot) self.economic_projection.spot_quantity_denominator else self.economic_projection.swap_quantity_denominator;
        const numerator = if (entry.product == .spot) self.economic_projection.spot_quantity_numerator else self.economic_projection.swap_quantity_numerator;
        if (denominator != 0 and
            (denominator != entry.rules.quantity_denominator or numerator != entry.rules.quantity_numerator)) return false;
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
        const changed = try self.economic_projection.applyCanonicalFill(.{
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
        }, payload_digest);
        if (!changed) return;
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

    fn handle(self: *TradingShard, input: CoreEvent) !?OrderCommand {
        switch (input.payload) {
            .exchange_balance, .opening_balance, .portfolio_transfer, .economic_fill, .funding_settlement, .venue_forced_execution, .economic_account_snapshot => try self.requireSettlementConsumers(),
            else => {},
        }
        switch (input.payload) {
            .asset_definition_activated => |definition| {
                const previous = self.asset_registry.get(definition.asset);
                var configured = self.*;
                if (!try configured.asset_registry.activate(definition, @intCast(self.trace.len + 1))) return null;
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
            },
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
                if (changesTradingAuthorization(command.kind))
                    self.authority_control_barrier = @intCast(self.trace.len);
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
            .version_activation => |activation| {
                if (activation.activation_identity == 0 or activation.new_release == 0 or
                    activation.generation != try std.math.add(u64, self.release_generation, 1) or
                    activation.old_release != self.active_release or
                    activation.old_strategy_instance != self.active_strategy_instance or
                    activation.barrier != try std.math.add(u64, @intCast(self.trace.len), 1) or
                    !std.mem.eql(u8, &activation.canonical_state_digest, &self.canonicalStateDigest()))
                    return error.InvalidVersionActivation;
                self.release_generation = activation.generation;
                self.active_release = activation.new_release;
                self.active_strategy_instance = activation.new_strategy_instance;
                var index: usize = 0;
                while (index < self.fenced_strategy_count) {
                    if (self.fenced_strategy_instances[index] == activation.old_strategy_instance) {
                        self.fenced_strategy_count -= 1;
                        self.fenced_strategy_instances[index] = self.fenced_strategy_instances[self.fenced_strategy_count];
                        self.fenced_strategy_instances[self.fenced_strategy_count] = 0;
                        break;
                    }
                    index += 1;
                }
                try self.trace.append(.version_activated, input.identity);
            },
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
                    self.instrument_registry.getPtr(normalized.instrument_identity).?.rules_barrier = @intCast(self.trace.len);
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
                entry.capability_barrier = @intCast(self.trace.len);
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
                self.host_activation_fact_sequence = @intCast(self.trace.len);
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
                self.strategy_cursor = self.trace.len;
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
            .oms_intent_group => |group| {
                if (!self.genesisReady()) return error.GenesisIncomplete;
                switch (try self.oms.groupIdentityStatus(group)) {
                    .duplicate => return null,
                    .conflict => {
                        try self.rejectIntent(.oms_intent_conflict, group.first_intent_sequence, .intent_identity_conflict);
                        return null;
                    },
                    .fresh => {},
                }
                var candidate = self.*;
                const qualified = candidate.qualifyOmsGroup(group) catch |err| switch (err) {
                    error.MarginSafetyGateClosed => {
                        try candidate.rejectSubmittedIntent(group, .strategy_intent_rejected, .margin_safety_gate_closed);
                        self.* = candidate;
                        return null;
                    },
                    error.UnsupportedOrderSpec, error.CapabilityUnsupported => {
                        try self.rejectSubmittedIntent(group, .strategy_intent_rejected, if (err == error.CapabilityUnsupported) .capability_unsupported else .unsupported_order_spec);
                        return null;
                    },
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
                    refs[index].decision = @intCast(candidate.trace.len);
                    try candidate.trace.append(.risk_reservation_created, intent.intent_sequence);
                    refs[index].reservation = @intCast(candidate.trace.len);
                    refs[index].authority = try candidate.dispatchAuthorityRefs(intent.instrument, if (input.time_presence.monotonic) input.monotonic_time else 0, refs[index].decision);
                }
                try candidate.oms.applyQualifiedGroup(qualified.group, group, refs[0..qualified.group.count]);
                try candidate.adjustMarginBuffersForReservationChange(qualified.reservation_atoms);
                try candidate.trace.append(.oms_intent_group, group.first_intent_sequence);
                self.* = candidate;
            },
            .oms_dispatch_batch => |batch| {
                var candidate = self.*;
                const previous_reservation = try candidate.activeReservationAtoms();
                try candidate.oms.applyDispatch(batch);
                try candidate.adjustMarginBuffersForReservationChange(previous_reservation);
                try candidate.trace.append(.oms_dispatch_batch, input.identity);
                self.* = candidate;
            },
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
                const order = self.oms.orderById(fill.order_id) orelse return error.UnknownOrder;
                if (order.last_reconciliation_status == .confirmed_absent) return error.TerminalFactConflict;
                const instrument = order.instrument;
                const instrument_config = self.instrumentEntry(instrument) orelse return error.UnknownOmsInstrument;
                if (!self.settlementConsumersCompatible(instrument)) return error.AssetPrecisionUnsupported;
                const changed = try self.applyEconomicProjection(.{ .fill = .{
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
                } });
                if (changed) {
                    try self.recalculateRisk(false);
                    try self.trace.append(.economic_fill, fill.fill_id);
                }
            },
            .funding_settlement => |funding| {
                const changed = try self.applyEconomicProjection(.{ .funding_settlement = .{ .identity = funding.settlement_id, .portfolio_ownership_proven = true, .amount = .{ .asset = self.economic_projection.settlement_asset, .atoms = funding.amount_atoms } } });
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
                const changed = try self.applyEconomicProjection(.{ .venue_forced_execution = .{
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
                } });
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

fn canonicalizeSnapshotState(shard: *TradingShard) void {
    zeroUnused(asset_registry.Entry, shard.asset_registry.entries[shard.asset_registry.count..]);
    zeroUnused(instrument_registry.Entry, shard.instrument_registry.entries[shard.instrument_registry.count..]);
    zeroUnused(market_projection.InstrumentProjection, shard.canonical_market.entries[shard.canonical_market.count..]);
    zeroUnused(Fact, shard.trace.events[shard.trace.len..]);
    zeroUnused(oms_module.Order, shard.oms.orders[shard.oms.order_count..]);
    shard.oms.command_count = 0;
    zeroUnused(oms_module.Command, shard.oms.commands[0..]);
    zeroUnused(oms_module.Command, shard.oms.command_history[shard.oms.command_history_count..]);
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
    zeroUnused(economics_module.NativeAssetState, shard.economic_projection.portfolio.native_assets[shard.economic_projection.portfolio.native_asset_count..]);
    zeroUnused(economics_module.NativeAssetState, shard.economic_projection.exchange.native_assets[shard.economic_projection.exchange.native_asset_count..]);
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

fn validateSnapshotState(shard: *const TradingShard) !void {
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
        shard.economic_projection.ledger_count > shard.economic_projection.ledger.len or
        shard.economic_projection.reconciliation_break_count > shard.economic_projection.reconciliation_break_identities.len or
        shard.economic_projection.portfolio.native_asset_count > economics_module.max_native_assets or
        shard.economic_projection.exchange.native_asset_count > economics_module.max_native_assets or
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
    if (shard.asset_configuration_failed and !shard.oms.recovery_only) return error.InvalidSnapshotState;
    for (shard.asset_registry.entries[0..shard.asset_registry.count]) |entry| {
        if (entry.barrier > shard.trace.len or shard.trace.events[entry.barrier - 1].kind != .asset_definition_activated)
            return error.InvalidSnapshotState;
    }
    try shard.instrument_registry.validate();
    if (shard.authority_control_barrier != 0) {
        const command = shard.controlCommandAtBarrier(shard.authority_control_barrier) orelse return error.InvalidSnapshotState;
        if (!changesTradingAuthorization(command.kind)) return error.InvalidSnapshotState;
    }
    for (shard.instrument_registry.entries[0..shard.instrument_registry.count]) |entry| {
        if (entry.rules_barrier == 0 or entry.rules_barrier > shard.trace.len or
            shard.trace.events[entry.rules_barrier - 1].kind != .instrument_rules_activated)
            return error.InvalidSnapshotState;
        if (entry.capability) |profile| {
            if (entry.capability_barrier == 0 or entry.capability_barrier > shard.trace.len or
                shard.trace.events[entry.capability_barrier - 1].kind != .capability_profile_activated or
                profile.exchange_account != shard.exchange_account_identity)
                return error.InvalidSnapshotState;
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
        if (decision == 0 or reservation == 0 or decision >= reservation or reservation > shard.trace.len)
            return error.InvalidSnapshotState;
        const decision_fact = shard.trace.events[decision - 1];
        const reservation_fact = shard.trace.events[reservation - 1];
        if (decision_fact.kind != .risk_accepted or reservation_fact.kind != .risk_reservation_created or
            decision_fact.identity != command.intent_sequence or reservation_fact.identity != command.intent_sequence)
            return error.InvalidSnapshotState;
        const refs = command.authority;
        const typed_refs = .{
            .{ refs.trading_authorization, EventKind.control_command_applied },
            .{ refs.primary_lease, EventKind.primary_lease_granted },
            .{ refs.risk_lease, EventKind.risk_lease_granted },
            .{ refs.capability, EventKind.capability_profile_activated },
            .{ refs.instrument_rules, EventKind.instrument_rules_activated },
            .{ refs.config, EventKind.strategy_activated },
        };
        inline for (typed_refs) |pair| {
            const ref = pair[0];
            const kind = pair[1];
            if (ref.barrier == 0) {
                if (ref.identity != 0 or ref.version != 0) return error.InvalidSnapshotState;
            } else if (ref.barrier > shard.trace.len or shard.trace.events[ref.barrier - 1].kind != kind or
                ref.identity == 0 or ref.version == 0)
                return error.InvalidSnapshotState;
        }
        if (refs.trading_authorization.barrier != 0) {
            const control = shard.controlCommandAtBarrier(refs.trading_authorization.barrier) orelse return error.InvalidSnapshotState;
            if (!changesTradingAuthorization(control.kind) or
                refs.trading_authorization.identity != control.command_identity or
                refs.trading_authorization.version != (std.math.add(u64, control.expected_version, 1) catch return error.InvalidSnapshotState))
                return error.InvalidSnapshotState;
        }
        if (refs.capability.barrier != 0 and shard.trace.events[refs.capability.barrier - 1].identity != refs.capability.identity)
            return error.InvalidSnapshotState;
        if (refs.instrument_rules.barrier != 0 and shard.trace.events[refs.instrument_rules.barrier - 1].identity != refs.instrument_rules.identity)
            return error.InvalidSnapshotState;
        if (refs.dispatch_deadline_monotonic_ns != 0 and
            (refs.deadline_barrier == 0 or refs.deadline_barrier > shard.trace.len))
            return error.InvalidSnapshotState;
        if (refs.exchange_account != 0 and refs.exchange_account != shard.exchange_account_identity)
            return error.InvalidSnapshotState;
        if (refs.virtual_portfolio != 0 and refs.virtual_portfolio != shard.portfolio_identity)
            return error.InvalidSnapshotState;
    }
    for (shard.economic_projection.ledger[0..shard.economic_projection.ledger_count]) |transaction|
        if (transaction.posting_count > transaction.postings.len) return error.InvalidSnapshotState;
    try shard.economic_projection.assertClosed();
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
        var fact_bytes: [@sizeOf(u64) + 1]u8 = undefined;
        std.mem.writeInt(u64, fact_bytes[0..@sizeOf(u64)], event.identity, .little);
        fact_bytes[@sizeOf(u64)] = @intFromEnum(event.reject_reason);
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
            .payload = if (index == 0) encoded_input else &fact_bytes,
        });
    }
}

pub fn applyStable(
    shard: *TradingShard,
    decision_journal: *journal.Journal,
    input: CanonicalEvent,
) !?OrderCommand {
    const checkpoint = decision_journal.checkpoint();
    const before = shard.trace.len;
    const account_failure_before = shard.canonical_account.failure;
    const market_failure_generation_before = shard.canonical_market.failure_generation;
    const oms_recovery_before = shard.oms.recovery_only;
    const asset_failed_before = shard.asset_configuration_failure_count;
    const economic_fault_before = shard.economic_fault_count;
    var candidate_shard = shard.*;
    const result = candidate_shard.apply(input) catch |err| {
        // Account/market projection failure is itself a durable fact. Keep
        // the invalid candidate and journal its fact group before surfacing
        // the original observation error to the caller.
        if (candidate_shard.asset_configuration_failure_count != asset_failed_before or
            candidate_shard.canonical_account.failure != account_failure_before or
            candidate_shard.canonical_market.failure_generation != market_failure_generation_before or
            candidate_shard.oms.recovery_only != oms_recovery_before or
            candidate_shard.economic_fault_count != economic_fault_before)
        {
            appendStableFactGroup(decision_journal, input, candidate_shard.trace.events[before..candidate_shard.trace.len]) catch |journal_err| {
                decision_journal.restore(checkpoint);
                return journal_err;
            };
            shard.* = candidate_shard;
        }
        return err;
    };
    if (result.facts.len == 0) {
        // handleCanonical returns without a fact only for a verified ingress
        // duplicate; replay never needs to append the same source fact twice.
        if (input == .venue) return null;
        if (input == .core and input.core.payload == .asset_definition_activated) return null;
        if (input == .core and input.core.payload == .external_order_intent) return null;
        if (input == .core and input.core.payload == .oms_intent_group and
            (shard.oms.groupIdentityStatus(input.core.payload.oms_intent_group) catch .fresh) == .duplicate)
            return null;
        if (input == .core and (input.core.payload == .venue_forced_execution or input.core.payload == .funding_settlement)) return null;
        return error.InputProducedNoFact;
    }
    appendStableFactGroup(decision_journal, input, result.facts) catch |err| {
        decision_journal.restore(checkpoint);
        return err;
    };
    shard.* = candidate_shard;
    return result.order_command;
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
    inline for (.{ refs.trading_authorization, refs.primary_lease, refs.risk_lease, refs.capability, refs.instrument_rules, refs.config }) |ref| {
        digestInt(hasher, u128, ref.identity);
        digestInt(hasher, u64, ref.version);
        digestInt(hasher, u64, ref.barrier);
    }
    digestInt(hasher, u128, refs.adapter_session);
    digestInt(hasher, u64, refs.dispatch_deadline_monotonic_ns);
    digestInt(hasher, u64, refs.deadline_barrier);
}

pub fn stateDigest(shard: TradingShard) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    const portfolio_position = shard.portfolioPosition();
    const exchange_position = shard.exchangePosition();
    const spot_portfolio_position = shard.spotPortfolioPosition();
    const spot_exchange_position = shard.spotExchangePosition();
    const ledger = shard.economic_projection.ledger_summary;
    hasher.update("StateDigestV5\x00");
    digestInt(&hasher, u16, schema_version);
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
        digestInt(&hasher, u32, entry.margin.version);
        digestInt(&hasher, i128, entry.margin.price_tick_atoms);
        digestBool(&hasher, entry.margin.native_settlement_atoms);
        digestInt(&hasher, i64, entry.margin.venue_initial_margin_ppm);
        digestInt(&hasher, i64, entry.margin.internal_initial_margin_ppm);
        digestInt(&hasher, i64, entry.margin.internal_maintenance_margin_ppm);
        digestInt(&hasher, i64, entry.margin.fee_ppm);
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
    digestInt(&hasher, u8, shard.oms.order_count);
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
        digestBool(&hasher, order.archive_window_closed);
        hasher.update(&order.archive_audit_digest);
    }
    digestInt(&hasher, u64, shard.oms.next_order_id);
    digestInt(&hasher, u64, shard.oms.next_command_id);
    digestInt(&hasher, u8, shard.oms.command_history_count);
    for (shard.oms.command_history[0..shard.oms.command_history_count]) |command|
        digestOmsCommand(&hasher, command);
    digestInt(&hasher, u8, shard.oms.report_history_count);
    for (shard.oms.report_history[0..shard.oms.report_history_count]) |report| {
        digestInt(&hasher, u64, report.report_id);
        digestInt(&hasher, u64, report.order_id);
        digestInt(&hasher, u32, report.revision);
        digestInt(&hasher, u8, @intFromEnum(report.status));
        digestInt(&hasher, i64, report.cumulative_quantity);
        digestInt(&hasher, i64, report.remaining_quantity);
        hasher.update(&report.canonical_digest);
    }
    digestInt(&hasher, u8, shard.oms.reconciliation_history_count);
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
    digestInt(&hasher, u8, shard.oms.intent_history_count);
    for (shard.oms.intent_history[0..shard.oms.intent_history_count]) |known| {
        digestInt(&hasher, u64, known.group);
        digestInt(&hasher, u8, @intFromEnum(known.policy));
        digestInt(&hasher, u64, known.intent_sequence);
        digestInt(&hasher, u128, known.strategy_instance);
        hasher.update(&known.fingerprint);
    }
    digestInt(&hasher, u8, shard.oms.tombstone_count);
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
    digestEconomicProjection(&hasher, shard.economic_projection);
    digestInt(&hasher, u64, shard.fencing_token);
    digestInt(&hasher, u64, shard.trace.len);
    for (shard.trace.events[0..shard.trace.len]) |event| {
        digestInt(&hasher, u64, event.sequence);
        digestInt(&hasher, u16, @intFromEnum(event.kind));
        digestInt(&hasher, u64, event.identity);
        digestInt(&hasher, u8, @intFromEnum(event.reject_reason));
    }

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
    digestCanonicalProjections(&hasher, shard);
    return hasher.finalResult();
}

fn digestCanonicalProjections(hasher: *Sha256, shard: TradingShard) void {
    const account_digest = shard.canonical_account.digest();
    hasher.update(&account_digest);
    digestBool(hasher, shard.canonical_account.valid);
    digestBool(hasher, shard.canonical_account.failure != null);
    if (shard.canonical_account.failure) |failure| digestInt(hasher, u8, @intFromEnum(failure));
    digestInt(hasher, u8, shard.canonical_account.seen_count);
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

fn semanticStateDigest(shard: TradingShard) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("SemanticAuthorityDigestV1\x00");
    digestInt(&hasher, u64, shard.economic_baseline_utc_ns);
    digestInt(&hasher, u64, shard.account_balance_utc_ns);
    digestAssetRegistry(&hasher, shard, false);
    digestInt(&hasher, u8, shard.oms.order_count);
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
    if (!is_input and (record.flags != 0 or record.payload.len != @sizeOf(u64) + 1))
        return error.InvalidDerivedFactRecord;
    const kind = std.enums.fromInt(EventKind, record.type_id) orelse
        return error.UnknownEventType;
    if (record.sequence != expected.sequence or kind != expected.kind or
        (!is_input and (try eventIdentity(record.payload) != expected.identity or
            record.payload[@sizeOf(u64)] != @intFromEnum(expected.reject_reason))))
        return error.ReplayFactMismatch;
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
    return replayReader(&reader, .{
        .quantity_denominator = quantity_denominator,
        .reservation_model = reservation_model,
    });
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
    var reader = try journal.Reader.init(bytes);
    const recovered = try replayReader(&reader, initial);
    return .{ .shard = recovered.shard, .status = recovered.status };
}

fn replayReader(reader: *journal.Reader, initial: TradingShard) !ReplayResult {
    var shard = initial;

    while (true) {
        const next = try reader.next();
        const first_record = switch (next) {
            .end => |status| return .{ .shard = shard, .status = status },
            .record => |record| record,
        };
        if (first_record.flags & 0xff != journal.input_flag) return error.OrphanDerivedFact;
        var candidate = shard;
        const input = try decodeStableInput(first_record);
        const before = candidate.trace.len;
        var replay_error: ?anyerror = null;
        _ = candidate.apply(input) catch |err| {
            replay_error = err;
        };
        const generated = candidate.trace.events[before..candidate.trace.len];
        const rejected_canonical_report = if (replay_error) |err|
            (err == error.InvalidExecutionReport or err == error.StaleOrderRevision or
                err == error.TombstoneFactConflict or err == error.ArchivedFactOutsideRetention or err == error.TerminalFactConflict) and
                input == .venue and input.venue.event == .execution_report and candidate.oms.recovery_only and
                generated.len > 0 and generated[generated.len - 1].kind == .canonical_order_reconciliation
        else
            false;
        if (replay_error != null and candidate.canonical_account.failure == null and
            candidate.canonical_market.latestFailure() == null and candidate.economic_fault_count == shard.economic_fault_count and
            candidate.asset_configuration_failure_count == shard.asset_configuration_failure_count and !rejected_canonical_report)
            return replay_error.?;
        if (generated.len == 0) return error.InputProducedNoFact;

        for (generated, 0..) |expected, index| {
            const record = if (index == 0) first_record else switch (try reader.next()) {
                .record => |record| record,
                .end => |status| {
                    if (status == .truncated_tail)
                        return .{ .shard = shard, .status = status };
                    return error.IncompleteFactGroup;
                },
            };
            try validateReplayRecord(record, expected, input, index == 0);
        }
        shard = candidate;
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

fn digestAssetRegistry(hasher: *Sha256, shard: TradingShard, include_barriers: bool) void {
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

fn digestEconomicFault(hasher: *Sha256, shard: TradingShard) void {
    digestInt(hasher, u64, shard.economic_fault_count);
    if (shard.economic_fault_count != 0) {
        digestInt(hasher, u8, @intFromEnum(shard.economic_fault_reason));
        digestInt(hasher, u128, shard.economic_fault_evidence.stream);
        digestInt(hasher, u64, shard.economic_fault_evidence.sequence);
        hasher.update(&shard.economic_fault_evidence.digest);
    }
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
    const restored = try TradingShard.restoreSnapshot(try shard.snapshot(&log, @intCast(shard.trace.len), &bytes));
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
    const recovered = try recoverStable(.{}, log.bytes());
    try std.testing.expectEqualSlices(u8, &shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
}
