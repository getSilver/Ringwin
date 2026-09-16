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
    open_cost_micros: i64 = 0,
};

fn ceilDivPositive(numerator: i128, denominator: i128) !i64 {
    if (numerator < 0 or denominator <= 0) return error.InvalidPositiveDivision;
    const rounded = try std.math.sub(i128, try std.math.add(i128, numerator, denominator), 1);
    return std.math.cast(i64, @divFloor(rounded, denominator)) orelse
        error.Overflow;
}

fn notionalMicrosScaled(quantity: i64, price_micros: i64, quantity_denominator: i64) !i64 {
    if (quantity < 0 or price_micros <= 0 or quantity_denominator <= 0)
        return error.InvalidNotionalInput;
    return ceilDivPositive(try std.math.mul(i128, quantity, price_micros), quantity_denominator);
}

fn riskTier(notional_micros: i64) !u8 {
    if (notional_micros <= 500_000 * money_scale) return 1;
    if (notional_micros <= 1_000_000 * money_scale) return 2;
    if (notional_micros <= 1_500_000 * money_scale) return 3;
    return error.RiskLimitExceeded;
}

const FillProjection = struct { fill_id: u64, order_id: u64 = 0, quantity: i64, price_micros: i64 };
const CanonicalIngressCursor = struct {
    identity: canonical.EventIdentity,
    event_type: canonical.EventType,
    raw_digest: [Sha256.digest_length]u8,
    payload_digest: [Sha256.digest_length]u8,
};
const max_canonical_ingress_streams = 16;

pub const TradingShard = struct {
    trace: Trace = .{},
    instrument_rules_version: u32 = 0,
    margin_rules_version: u32 = 0,
    account_configured: bool = false,
    virtual_portfolio_active: bool = false,
    strategy_active: bool = false,
    fencing_token: u64 = 0,
    expected_source_sequence: ?u64 = null,
    market_health: MarketHealth = .initializing,
    bid_price_micros: i64 = 0,
    bid_quantity: i64 = 0,
    ask_1_price_micros: i64 = 0,
    ask_1_quantity: i64 = 0,
    ask_2_price_micros: i64 = 0,
    ask_2_quantity: i64 = 0,
    strategy_cursor: u64 = 0,
    strategy_decision_count: u64 = 0,
    timer_pending: bool = true,
    dispatch_attempt_count: u64 = 0,
    last_reject_reason: RejectReason = .none,
    last_risk_required_micros: i64 = 0,
    last_risk_tier: u8 = 0,
    mark_price_micros: i64 = 0,
    risk_lease_micros: i64 = 0,
    risk_lease_identity: u64 = 0,
    risk_lease_version: u64 = 0,
    risk_lease_valid_through_barrier: u64 = 0,
    strategy_limit_micros: i64 = 0,
    portfolio_limit_micros: i64 = 0,
    exchange_account_limit_micros: i64 = 0,
    global_limit_micros: i64 = 0,
    price_tick_micros: i64 = 0,
    venue_initial_margin_ppm: i64 = 0,
    internal_initial_margin_ppm: i64 = 0,
    internal_maintenance_margin_ppm: i64 = 0,
    risk_fee_ppm: i64 = 0,
    opening_buffer_micros: i64 = 0,
    opening_buffer_bps: i64 = 0,
    opening_liquidation_distance_ticks: i64 = 0,
    warning_buffer_micros: i64 = 0,
    kill_buffer_micros: i64 = 0,
    warning_buffer_bps: i64 = 0,
    kill_buffer_bps: i64 = 0,
    warning_liquidation_distance_ticks: i64 = 0,
    kill_liquidation_distance_ticks: i64 = 0,
    layered_risk_reserved_micros: i64 = 0,
    portfolio_margin_buffer_micros: i64 = 0,
    exchange_margin_buffer_micros: i64 = 0,
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
    host_activation_state_digest: [32]u8 = @splat(0),
    exchange_balance_observed: bool = false,
    exchange_positions_observed: bool = false,
    opening_balance_observed: bool = false,
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
    last_canonical_report: ?canonical.ExecutionReport = null,
    last_canonical_fill: ?canonical.Fill = null,
    last_funding_rate: ?canonical.FundingRatePublished = null,
    last_venue_configuration: ?canonical.VenueAccountConfigurationSnapshot = null,
    canonical_ingress_count: u64 = 0,
    canonical_ingress_digest: [Sha256.digest_length]u8 = @splat(0),
    canonical_ingress_cursors: [max_canonical_ingress_streams]CanonicalIngressCursor = undefined,
    canonical_ingress_cursor_count: u8 = 0,
    /// Single source of product/rules semantics. The scalar fields above are
    /// retained only as the normalized legacy active-instrument view.
    instrument_registry: instrument_registry.Registry = .{},

    /// The sole public core ingress seam. Both typed core events and canonical
    /// Venue records enter through this tagged event and commit transactionally.
    pub fn apply(self: *TradingShard, input: CanonicalEvent) !ApplyResult {
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
            if (err == error.TombstoneFactConflict or err == error.ArchivedFactOutsideRetention or err == error.TerminalFactConflict) {
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
            } else if (candidate.canonical_account.failure != account_failure_before) {
                if (candidate.operational_state.initialized) try candidate.applyOperationalGate(.{
                    .gate_identity = account_data_gate_identity,
                    .target_identity = candidate.operational_state.target_identity,
                    .kind = .latched,
                    .reason = .reconciliation_break,
                    .open = false,
                });
                try candidate.trace.append(.canonical_account_invalidated, event.envelope.identity.sequence);
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
            .treasury_usdt_micros = self.economic_projection.treasury_usdt_micros,
            .suspense_usdt_micros = self.economic_projection.suspense_usdt_micros,
            .ledger_transactions = self.economic_projection.ledger_count,
            .reconciliation_break = self.economic_projection.reconciliation_break,
        };
    }

    /// Remaining lease headroom derived from the authoritative economic and
    /// OMS reservation owners; it is never snapshotted as competing state.
    pub fn riskLeaseRemainingMicros(self: *const TradingShard) !i64 {
        return std.math.sub(
            i64,
            self.risk_lease_micros,
            try std.math.add(i64, self.economic_projection.portfolio.margin_micros, self.layered_risk_reserved_micros),
        );
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
            .account_valid = self.canonical_account.valid,
            .account_failure = self.canonical_account.failure,
            .market_health = self.canonical_market.aggregateHealth(),
            .market_failure = self.canonical_market.latestFailure(),
            .effective_trading_authority = self.operational_state.effectiveTradingAuthority(),
            .canonical_state_digest = self.canonicalStateDigest(),
        };
    }

    pub fn genesisReady(self: *const TradingShard) bool {
        return self.instrument_registry.count != 0 and self.instrument_rules_version != 0 and self.margin_rules_version != 0 and
            self.account_configured and self.exchange_balance_observed and
            self.exchange_positions_observed and self.opening_balance_observed and
            self.virtual_portfolio_active and self.portfolio_funded and self.strategy_active and
            self.fencing_token != 0 and self.risk_lease_micros > 0;
    }

    fn portfolioPosition(self: *const TradingShard) Position {
        return .{ .quantity = self.economic_projection.portfolio.swap.quantity, .open_cost_micros = self.economic_projection.portfolio.swap.open_cost_micros };
    }

    fn exchangePosition(self: *const TradingShard) Position {
        return .{ .quantity = self.economic_projection.exchange.swap.quantity, .open_cost_micros = self.economic_projection.exchange.swap.open_cost_micros };
    }

    fn spotPortfolioPosition(self: *const TradingShard) Position {
        return .{ .quantity = self.economic_projection.portfolio.spot.quantity, .open_cost_micros = self.economic_projection.portfolio.spot.open_cost_micros };
    }

    fn spotExchangePosition(self: *const TradingShard) Position {
        return .{ .quantity = self.economic_projection.exchange.spot.quantity, .open_cost_micros = self.economic_projection.exchange.spot.open_cost_micros };
    }

    fn portfolioCash(self: *const TradingShard) i64 {
        return self.economic_projection.portfolio.usdt_balance_micros;
    }
    fn treasuryCash(self: *const TradingShard) i64 {
        return self.economic_projection.treasury_usdt_micros;
    }
    fn exchangeCash(self: *const TradingShard) i64 {
        return self.economic_projection.exchange.usdt_balance_micros;
    }
    fn portfolioFee(self: *const TradingShard) i64 {
        return self.economic_projection.portfolio.fee_micros;
    }
    fn exchangeFee(self: *const TradingShard) i64 {
        return self.economic_projection.exchange.fee_micros;
    }
    fn totalFees(self: *const TradingShard) i64 {
        return self.portfolioFee();
    }
    fn realizedPnl(self: *const TradingShard) i64 {
        return self.economic_projection.portfolio.realized_pnl_micros;
    }
    fn unrealizedPnl(self: *const TradingShard) i64 {
        return self.economic_projection.portfolio.unrealized_pnl_micros;
    }

    fn riskLimits(self: *const TradingShard) risk_module.Limits {
        return .{
            .strategy = .{ .asset = settlement_asset, .atoms = self.strategy_limit_micros },
            .portfolio = .{ .asset = settlement_asset, .atoms = self.portfolio_limit_micros },
            .decision_domain = .{ .asset = settlement_asset, .atoms = self.risk_lease_micros },
            .exchange_account = .{ .asset = settlement_asset, .atoms = self.exchange_account_limit_micros },
            .global = .{ .asset = settlement_asset, .atoms = self.global_limit_micros },
        };
    }

    fn riskRules(self: *const TradingShard, instrument_id: canonical.InstrumentIdentity) risk_module.Rules {
        const registered = self.instrument_registry.get(instrument_id);
        const rules_version = if (registered) |entry| entry.rules.version else self.instrument_rules_version;
        const quantity_denominator = if (registered) |entry| entry.rules.quantity_denominator else self.quantity_denominator;
        const margin = if (registered) |entry| entry.margin else shard_event.MarginRules{ .version = self.margin_rules_version, .price_tick_micros = self.price_tick_micros, .venue_initial_margin_ppm = self.venue_initial_margin_ppm, .internal_initial_margin_ppm = self.internal_initial_margin_ppm, .internal_maintenance_margin_ppm = self.internal_maintenance_margin_ppm, .fee_ppm = self.risk_fee_ppm, .opening_buffer_micros = self.opening_buffer_micros, .opening_buffer_bps = self.opening_buffer_bps, .opening_liquidation_distance_ticks = self.opening_liquidation_distance_ticks, .warning_buffer_micros = self.warning_buffer_micros, .kill_buffer_micros = self.kill_buffer_micros, .warning_buffer_bps = self.warning_buffer_bps, .kill_buffer_bps = self.kill_buffer_bps, .warning_liquidation_distance_ticks = self.warning_liquidation_distance_ticks, .kill_liquidation_distance_ticks = self.kill_liquidation_distance_ticks };
        return .{
            .settlement_asset = if (registered) |entry| entry.rules.settlement_asset else settlement_asset,
            .instrument = instrument_id,
            .rules_version = rules_version,
            .quantity_denominator = quantity_denominator,
            .price_tick_value = .{ .asset = if (registered) |entry| entry.rules.settlement_asset else settlement_asset, .atoms = margin.price_tick_micros },
            .venue_initial_margin_ppm = margin.venue_initial_margin_ppm,
            .internal_initial_margin_ppm = margin.internal_initial_margin_ppm,
            .internal_maintenance_margin_ppm = margin.internal_maintenance_margin_ppm,
            .fee_ppm = margin.fee_ppm,
            .opening_buffer = .{ .asset = if (registered) |entry| entry.rules.settlement_asset else settlement_asset, .atoms = margin.opening_buffer_micros },
            .opening_buffer_bps = margin.opening_buffer_bps,
            .opening_liquidation_distance_ticks = margin.opening_liquidation_distance_ticks,
            .warning_buffer = .{ .asset = if (registered) |entry| entry.rules.settlement_asset else settlement_asset, .atoms = margin.warning_buffer_micros },
            .kill_buffer = .{ .asset = if (registered) |entry| entry.rules.settlement_asset else settlement_asset, .atoms = margin.kill_buffer_micros },
            .warning_buffer_bps = margin.warning_buffer_bps,
            .kill_buffer_bps = margin.kill_buffer_bps,
            .warning_liquidation_distance_ticks = margin.warning_liquidation_distance_ticks,
            .kill_liquidation_distance_ticks = margin.kill_liquidation_distance_ticks,
        };
    }

    fn qualifyOmsGroup(self: *TradingShard, group: oms_module.IntentGroup) !oms_module.IntentGroup {
        var qualified = group;
        var active = try self.oms.activeReservations(settlement_asset);
        for (qualified.members[0..qualified.count]) |*intent| {
            for (self.fenced_strategy_instances[0..self.fenced_strategy_count]) |fenced|
                if (intent.strategy_instance == fenced and intent.operation != .cancel)
                    return error.StrategyCutoverFenced;
            if (intent.operation == .cancel) continue;
            var replaced: canonical.AssetAmount = .{ .asset = settlement_asset, .atoms = 0 };
            if (intent.operation == .amend) {
                const target = self.oms.orderById(intent.target_order_id) orelse return error.UnknownOrder;
                if (target.reservation_active) replaced = target.reservation;
            }
            const instrument_config = self.instrumentEntry(intent.instrument) orelse return error.UnknownOmsInstrument;
            if (!instrument_config.margin_configured) return error.InstrumentRulesInactive;
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
            const mark_price = std.math.cast(i64, mark.ticks) orelse return error.PriceOutOfRange;
            const assessment = try risk_module.assess(self.riskRules(intent.instrument), self.riskLimits(), .{
                .portfolio_cash = .{ .asset = settlement_asset, .atoms = self.portfolioCash() },
                .exchange_cash = .{ .asset = settlement_asset, .atoms = self.exchangeCash() },
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
            intent.venue_reduce_only = assessment.venue_reduce_only and
                (if (instrument_config.capability) |capability| capability.supports_venue_reduce_only else true);
            active = assessment.total_reserved;
            self.layered_risk_reserved_micros = std.math.cast(i64, active.atoms) orelse return error.Overflow;
            self.portfolio_margin_buffer_micros = std.math.cast(i64, assessment.portfolio_margin_buffer.atoms) orelse return error.Overflow;
            self.exchange_margin_buffer_micros = std.math.cast(i64, assessment.exchange_margin_buffer.atoms) orelse return error.Overflow;
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
        return qualified;
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

    fn confirmPendingReplacement(self: *TradingShard, order_id: u64, sequence: u64, now_monotonic_ns: u64) !void {
        const replacement = (try self.oms.replacementIntent(order_id, sequence)) orelse return;
        var group: oms_module.IntentGroup = .{ .first_intent_sequence = replacement.intent_sequence, .count = 1 };
        group.members[0] = replacement;
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
            error.MarginSafetyGateClosed,
            error.StrategyCutoverFenced,
            => {
                try self.oms.discardReplacement(order_id);
                return;
            },
            else => return err,
        };
        const intent = qualified.members[0];
        try self.trace.append(.risk_accepted, intent.intent_sequence);
        const decision_barrier: u64 = @intCast(self.trace.len);
        try self.trace.append(.risk_reservation_created, intent.intent_sequence);
        try self.oms.confirmReplacement(order_id, intent.reservation, intent.portfolio_reduce_only, intent.venue_reduce_only, intent.intent_sequence, .{
            .decision = decision_barrier,
            .reservation = @intCast(self.trace.len),
            .authority = try self.dispatchAuthorityRefs(intent.instrument, now_monotonic_ns, decision_barrier),
        });
    }

    fn refreshLayeredReservations(self: *TradingShard) !void {
        const previous = self.layered_risk_reserved_micros;
        const current = try self.oms.activeReservations(settlement_asset);
        const current_atoms = std.math.cast(i64, current.atoms) orelse return error.Overflow;
        const change = try std.math.sub(i64, current_atoms, previous);
        self.layered_risk_reserved_micros = current_atoms;
        self.portfolio_margin_buffer_micros = try std.math.sub(i64, self.portfolio_margin_buffer_micros, change);
        self.exchange_margin_buffer_micros = try std.math.sub(i64, self.exchange_margin_buffer_micros, change);
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
            portfolio_micros: i64 = 0,
            treasury_micros: i64 = 0,
            exchange_micros: i64 = 0,
        } = .{},
        fees: struct {
            portfolio_micros: i64 = 0,
            exchange_micros: i64 = 0,
            total_micros: i64 = 0,
        } = .{},
        pnl: struct {
            realized_micros: i64 = 0,
            unrealized_micros: i64 = 0,
        } = .{},
        ledger: struct {
            transaction_count: u64 = 0,
            portfolio_transfer_count: u64 = 0,
            portfolio_debits_micros: i64 = 0,
            portfolio_credits_micros: i64 = 0,
            exchange_debits_micros: i64 = 0,
            exchange_credits_micros: i64 = 0,
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
                .portfolio_micros = self.portfolioCash(),
                .treasury_micros = self.treasuryCash(),
                .exchange_micros = self.exchangeCash(),
            },
            .fees = .{
                .portfolio_micros = self.portfolioFee(),
                .exchange_micros = self.exchangeFee(),
                .total_micros = self.totalFees(),
            },
            .pnl = .{
                .realized_micros = self.realizedPnl(),
                .unrealized_micros = self.unrealizedPnl(),
            },
            .ledger = .{
                .transaction_count = self.economic_projection.ledger_summary.transaction_count,
                .portfolio_transfer_count = self.economic_projection.ledger_summary.portfolio_transfer_count,
                .portfolio_debits_micros = self.economic_projection.ledger_summary.portfolio_debits_micros,
                .portfolio_credits_micros = self.economic_projection.ledger_summary.portfolio_credits_micros,
                .exchange_debits_micros = self.economic_projection.ledger_summary.exchange_debits_micros,
                .exchange_credits_micros = self.economic_projection.ledger_summary.exchange_credits_micros,
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
            i64,
            self.economic_projection.portfolio.margin_micros,
            self.layered_risk_reserved_micros,
        );
        const remaining = try std.math.sub(i64, self.risk_lease_micros, used);
        if (fail_if_exceeded and remaining < 0) return error.RiskLeaseExceeded;
    }

    pub fn assertClosures(self: TradingShard) !void {
        const portfolio_position = self.portfolioPosition();
        const exchange_position = self.exchangePosition();
        if (portfolio_position.quantity != exchange_position.quantity or
            portfolio_position.open_cost_micros != exchange_position.open_cost_micros)
            return error.PositionLayerMismatch;
        if (try std.math.add(
            i64,
            self.portfolioCash(),
            self.treasuryCash(),
        ) != self.exchangeCash())
            return error.CashLayerMismatch;
        if (self.portfolioFee() != self.exchangeFee() or
            self.totalFees() != self.portfolioFee())
            return error.FeeLayerMismatch;
        const ledger = self.economic_projection.ledger_summary;
        if (ledger.portfolio_debits_micros != ledger.portfolio_credits_micros or
            ledger.exchange_debits_micros != ledger.exchange_credits_micros)
            return error.LedgerPostingsDoNotClose;
        if (try std.math.add(i64, try self.riskLeaseRemainingMicros(), try std.math.add(
            i64,
            self.layered_risk_reserved_micros,
            self.economic_projection.portfolio.margin_micros,
        )) != self.risk_lease_micros)
            return error.RiskLeaseDoesNotClose;
    }

    fn applyFill(self: *TradingShard, fill: FillProjection) !void {
        if (fill.order_id == 0) return error.UnknownOrder;
        const order_id = fill.order_id;
        const order = self.oms.orderById(order_id) orelse return error.UnknownOrder;
        const next_filled = try std.math.add(i64, order.cumulative_quantity, fill.quantity);
        if (fill.quantity <= 0 or fill.price_micros <= 0 or
            next_filled > order.quantity)
            return error.InvalidFill;

        // Canonical execution reports normally advance OMS cumulative
        // quantity first. Legacy economic_fill callers have no report, so
        // retain the compatibility scalar only for the legacy active order.
        self.economic_projection.ledger_summary.transaction_count = try std.math.add(u64, self.economic_projection.ledger_summary.transaction_count, 1);
        try self.recalculateRisk(false);
        try self.assertClosures();
    }

    fn applyEconomicProjection(self: *TradingShard, event: economics.Event) !bool {
        return self.economic_projection.applyChanged(event);
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

    fn dispatchAuthorityRefs(self: *const TradingShard, instrument: canonical.InstrumentIdentity, now_monotonic_ns: u64, deadline_barrier: u64) !oms_module.DispatchAuthorityRefs {
        var refs: oms_module.DispatchAuthorityRefs = .{
            .exchange_account = self.exchange_account_identity,
            .virtual_portfolio = self.portfolio_identity,
            .deadline_barrier = deadline_barrier,
        };
        if (self.authority_control_barrier != 0 and self.operational_state.command_count != 0) {
            const command = self.operational_state.command_history[self.operational_state.command_count - 1].command;
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
                result.lots = balance.total.atoms;
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

    fn bindFreshCancellations(self: *TradingShard, now_monotonic_ns: u64) !void {
        for (self.oms.emitted()) |command| {
            if (command.operation != .cancel) continue;
            const authority = try self.dispatchAuthorityRefs(command.instrument, now_monotonic_ns, @intCast(self.trace.len));
            try self.oms.bindCancellationAuthority(command.command_id, authority);
        }
    }

    fn submitOrderIntent(self: *TradingShard, intent: host_gateway.OrderIntent, now_monotonic_ns: u64) !?OrderCommand {
        if (intent.order_type != .limit or
            (intent.time_in_force != .good_til_canceled and intent.time_in_force != .immediate_or_cancel) or
            intent.quantity <= 0 or intent.limit_price_micros <= 0)
            return error.InvalidOrderIntent;
        if (!self.genesisReady()) return error.GenesisIncomplete;
        if (self.host_activation_identity != intent.activation_identity or
            intent.strategy_cursor <= self.host_activation_barrier)
            return error.HostNotActivated;
        if (!self.operational_state.effectiveTradingAuthority()) {
            self.last_reject_reason = .authorization_closed;
            try self.trace.append(.strategy_intent_rejected, intent.intent_sequence);
            return null;
        }
        if (intent.strategy_identity != self.strategy_identity or
            intent.config_version != self.strategy_config_version or
            intent.activation_identity != self.strategy_activation_identity or
            intent.portfolio_identity != self.portfolio_identity or
            intent.exchange_account_identity != self.exchange_account_identity or
            self.instrumentEntry(intent.instrument_identity) == null)
            return error.IntentAuthorityMismatch;
        for (self.oms.orders[0..self.oms.order_count]) |order| if (order.instrument == intent.instrument_identity) switch (order.state) {
            .pending_submit, .unknown, .live, .partially_filled, .pending_amend, .pending_cancel => return error.IntentArrivedWithOpenOrder,
            else => {},
        };
        try self.trace.append(.order_intent, intent.intent_sequence);

        const instrument_config = self.instrumentEntry(intent.instrument_identity) orelse
            return error.UnknownOmsInstrument;
        const requested_notional = try notionalMicrosScaled(
            intent.quantity,
            intent.limit_price_micros,
            instrument_config.rules.quantity_denominator,
        );
        self.last_risk_tier = try riskTier(requested_notional);
        if (self.market_health != .healthy) {
            self.last_reject_reason = .market_data_gap;
            try self.trace.append(.risk_rejected_market_data, intent.intent_sequence);
            return null;
        }
        var group: oms_module.IntentGroup = .{ .first_intent_sequence = intent.intent_sequence, .count = 1 };
        group.members[0] = .{
            .intent_sequence = intent.intent_sequence,
            .strategy_instance = intent.strategy_identity,
            .operation = .place,
            .instrument = intent.instrument_identity,
            .side = if (intent.side == .buy) .buy else .sell,
            .portfolio_reduce_only = intent.portfolio_reduce_only,
            .quantity = intent.quantity,
            .limit_price = .{ .instrument = intent.instrument_identity, .rules_version = instrument_config.rules.version, .ticks = intent.limit_price_micros },
            .order_type = .limit,
            .time_in_force = switch (intent.time_in_force) {
                .good_til_canceled => .good_til_canceled,
                .immediate_or_cancel => .immediate_or_cancel,
            },
        };
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
            => {
                self.last_reject_reason = switch (err) {
                    error.StrategyLimitExceeded => .strategy_limit_exceeded,
                    error.VirtualPortfolioLimitExceeded => .portfolio_limit_exceeded,
                    error.DecisionDomainLimitExceeded => .decision_domain_limit_exceeded,
                    error.ExchangeAccountLimitExceeded => .exchange_account_limit_exceeded,
                    error.GlobalLimitExceeded => .global_limit_exceeded,
                    error.PortfolioOpeningGateClosed => .portfolio_opening_gate_closed,
                    error.ExchangeOpeningGateClosed => .exchange_opening_gate_closed,
                    error.InsufficientSpotAsset => .insufficient_spot_asset,
                    error.PortfolioReduceOnlyViolation => .portfolio_reduce_only_violation,
                    else => unreachable,
                };
                try self.trace.append(.risk_rejected_lease, intent.intent_sequence);
                return null;
            },
            else => return err,
        };
        self.last_risk_required_micros = std.math.cast(i64, qualified.members[0].reservation.atoms) orelse return error.Overflow;
        self.last_reject_reason = .none;
        try self.trace.append(.risk_accepted, intent.intent_sequence);
        const decision_barrier: u64 = @intCast(self.trace.len);
        try self.trace.append(.risk_reservation_created, intent.intent_sequence);
        const refs = [_]oms_module.RiskFactRefs{.{ .decision = decision_barrier, .reservation = @intCast(self.trace.len), .authority = try self.dispatchAuthorityRefs(intent.instrument_identity, now_monotonic_ns, decision_barrier) }};
        try self.oms.applyQualifiedGroup(qualified, &refs);
        try self.refreshLayeredReservations();
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
            .execution_report => |report| try self.applyCanonicalReport(report, fact_identity),
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
                self.bid_price_micros = std.math.cast(i64, book_snapshot.best_bid.ticks) orelse return error.PriceOutOfRange;
                self.ask_1_price_micros = std.math.cast(i64, book_snapshot.best_ask.ticks) orelse return error.PriceOutOfRange;
                self.bid_quantity = std.math.cast(i64, book_snapshot.best_bid_quantity.?.lots) orelse return error.QuantityOutOfRange;
                self.ask_1_quantity = std.math.cast(i64, book_snapshot.best_ask_quantity.?.lots) orelse return error.QuantityOutOfRange;
                self.ask_2_price_micros = if (book_snapshot.next_ask) |price| std.math.cast(i64, price.ticks) orelse return error.PriceOutOfRange else self.ask_1_price_micros;
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
                self.bid_price_micros = std.math.cast(i64, delta.best_bid.ticks) orelse return error.PriceOutOfRange;
                self.ask_1_price_micros = std.math.cast(i64, delta.best_ask.ticks) orelse return error.PriceOutOfRange;
                if (delta.best_bid_quantity) |quantity| self.bid_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
                if (delta.best_ask_quantity) |quantity| self.ask_1_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
                if (delta.next_ask) |price| self.ask_2_price_micros = std.math.cast(i64, price.ticks) orelse return error.PriceOutOfRange;
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
                    const mark_price = std.math.cast(i64, price.price.ticks) orelse return error.PriceOutOfRange;
                    if (price.instrument == self.instrument_identity) self.mark_price_micros = mark_price;
                    _ = try self.applyEconomicProjection(.{ .mark_price = .{
                        .product = instrument.product,
                        .price_micros = mark_price,
                        .quantity_denominator = instrument.rules.quantity_denominator,
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
            .account_bootstrap_snapshot => {
                try self.canonical_account.apply(record.event);
                try self.trace.append(.canonical_account_bootstrap, fact_identity);
            },
            .account_observed => {
                try self.canonical_account.apply(record.event);
                try self.trace.append(.canonical_account_observed, fact_identity);
            },
            .venue_account_configuration_snapshot => |configuration| {
                self.last_venue_configuration = configuration;
                try self.trace.append(.canonical_venue_configuration, fact_identity);
            },
            .order_reconciliation_result => |result| {
                if ((result.status == .unresolved) == result.complete) return error.ConflictingReconciliationEvidence;
                if (result.order != 0) {
                    const order_id = std.math.cast(u64, result.order) orelse return error.IdentityOutOfRange;
                    const instrument = self.oms.instrumentForOrder(order_id) orelse return error.UnknownOrder;
                    const rules = self.instrumentEntry(instrument) orelse return error.UnknownOmsInstrument;
                    if (result.rules_version != rules.rules.version) return error.StaleInstrumentRules;
                    const cumulative = result.cumulative_quantity orelse return error.IncompleteReconciliationEvidence;
                    const remaining = result.remaining_quantity orelse return error.IncompleteReconciliationEvidence;
                    if (cumulative.instrument != instrument or remaining.instrument != instrument or
                        cumulative.rules_version != rules.rules.version or remaining.rules_version != rules.rules.version)
                        return error.CanonicalScopeMismatch;
                    try self.oms.applyReconciliation(.{
                        .reconciliation_id = std.math.cast(u64, result.identity) orelse return error.IdentityOutOfRange,
                        .order_id = order_id,
                        .status = switch (result.status) {
                            .found_live => .found_live,
                            .found_terminal => .found_terminal,
                            .confirmed_absent => .confirmed_absent,
                            .unresolved => .unresolved,
                        },
                        .revision = result.revision,
                        .cumulative_quantity = std.math.cast(i64, cumulative.lots) orelse return error.QuantityOutOfRange,
                        .remaining_quantity = std.math.cast(i64, remaining.lots) orelse return error.QuantityOutOfRange,
                        .terminal_state = if (result.terminal_status) |terminal| switch (terminal) {
                            .filled => .filled,
                            .canceled => .canceled,
                            .rejected => .rejected,
                            else => return error.InvalidTerminalReconciliation,
                        } else null,
                    });
                    try self.refreshLayeredReservations();
                } else if (result.status != .unresolved) return error.IncompleteReconciliationEvidence;
                if (result.status == .unresolved and self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = result.identity,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .latched,
                    .reason = .reconciliation_break,
                    .open = false,
                });
                try self.trace.append(.canonical_order_reconciliation, fact_identity);
            },
            .account_reconciliation_result => |result| {
                if (!result.complete and self.operational_state.initialized) try self.applyOperationalGate(.{
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

    fn rememberCanonicalIngress(self: *TradingShard, record: canonical.EventRecord) !bool {
        const event_type = canonical.eventType(record.event);
        var payload_bytes: [canonical_event_codec.max_encoded_len]u8 = undefined;
        const payload = try canonical_event_codec.encodePayload(&payload_bytes, record.event);
        var payload_digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(payload, &payload_digest, .{});
        switch (record.event) {
            .execution_report => |report| if (self.last_canonical_report) |known| {
                if (known.identity == report.identity) {
                    if (!std.meta.eql(known, report)) return error.ConflictingReportIdentity;
                    return true;
                }
            },
            .fill => |fill| if (self.last_canonical_fill) |known| {
                if (known.identity == fill.identity) {
                    if (!std.meta.eql(known, fill)) return error.ConflictingFillIdentity;
                    return true;
                }
            },
            else => {},
        }
        var cursor_index: ?usize = null;
        for (self.canonical_ingress_cursors[0..self.canonical_ingress_cursor_count], 0..) |known, index| {
            if (known.identity.stream != record.envelope.identity.stream) continue;
            if (record.envelope.identity.sequence < known.identity.sequence)
                return error.StaleCanonicalIdentity;
            if (record.envelope.identity.sequence == known.identity.sequence) {
                if (known.event_type != event_type or
                    !std.mem.eql(u8, &known.raw_digest, &record.envelope.raw_evidence.digest) or
                    !std.mem.eql(u8, &known.payload_digest, &payload_digest))
                    return error.ConflictingCanonicalIdentity;
                return true;
            }
            cursor_index = index;
            break;
        }
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

    fn applyCanonicalReport(self: *TradingShard, report: canonical.ExecutionReport, fact_identity: u64) !void {
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
        if (self.last_canonical_report) |known| if (known.identity == report.identity) {
            if (!std.meta.eql(known, report)) return error.ConflictingReportIdentity;
            return;
        };
        const cumulative = std.math.cast(i64, report.cumulative_quantity.lots) orelse return error.QuantityOutOfRange;
        const remaining = std.math.cast(i64, report.remaining_quantity.lots) orelse return error.QuantityOutOfRange;
        try self.oms.applyReport(.{
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
            .cumulative_quantity = cumulative,
            .remaining_quantity = remaining,
        });
        try self.refreshLayeredReservations();
        try self.recalculateRisk(false);
        self.last_canonical_report = report;
        try self.trace.append(switch (report.status) {
            .accepted => .order_accepted,
            .partially_filled => .order_partially_filled,
            .filled => .order_filled,
            .canceled => .order_canceled,
            .rejected => .order_rejected,
            .amended => .order_amended,
        }, fact_identity);
    }

    fn applyCanonicalFill(self: *TradingShard, fill: canonical.Fill, fact_identity: u64) !void {
        if (fill.exchange_account != self.exchange_account_identity)
            return error.CanonicalScopeMismatch;
        const order_id = std.math.cast(u64, fill.order) orelse return error.IdentityOutOfRange;
        const fill_id = std.math.cast(u64, fill.identity) orelse return error.IdentityOutOfRange;
        const order = self.oms.orderById(order_id) orelse return error.UnknownOrder;
        if (order.instrument != fill.instrument) return error.CanonicalScopeMismatch;
        const instrument_config = self.instrumentEntry(fill.instrument) orelse return error.UnknownOmsInstrument;
        if (fill.quantity.rules_version != instrument_config.rules.version or
            fill.price.rules_version != instrument_config.rules.version)
            return error.StaleInstrumentRules;
        if (self.last_canonical_fill) |known| if (known.identity == fill.identity) {
            if (!std.meta.eql(known, fill)) return error.ConflictingFillIdentity;
            return;
        };
        const quantity = std.math.cast(i64, fill.quantity.lots) orelse return error.QuantityOutOfRange;
        const price = std.math.cast(i64, fill.price.ticks) orelse return error.PriceOutOfRange;
        const fee = fill.fee orelse return error.MissingFillFee;
        const rebate = fill.rebate orelse canonical.AssetAmount{ .asset = self.economic_projection.settlement_asset, .atoms = 0 };
        if (fee.atoms < 0 or rebate.atoms < 0) return error.InvalidEconomicFact;
        var settlement_fee = canonical.AssetAmount{ .asset = self.economic_projection.settlement_asset, .atoms = 0 };
        var settlement_rebate = canonical.AssetAmount{ .asset = self.economic_projection.settlement_asset, .atoms = 0 };
        var base_fee_quantity: i64 = 0;
        var base_rebate_quantity: i64 = 0;
        if (fee.atoms != 0) {
            if (fee.asset == self.economic_projection.settlement_asset)
                settlement_fee = fee
            else if (instrument_config.product == .spot and fee.asset == instrument_config.rules.base_asset)
                base_fee_quantity = std.math.cast(i64, fee.atoms) orelse return error.Overflow
            else
                return error.InvalidEconomicFact;
        }
        if (rebate.atoms != 0) {
            if (rebate.asset == self.economic_projection.settlement_asset)
                settlement_rebate = rebate
            else if (instrument_config.product == .spot and rebate.asset == instrument_config.rules.base_asset)
                base_rebate_quantity = std.math.cast(i64, rebate.atoms) orelse return error.Overflow
            else
                return error.InvalidEconomicFact;
        }
        const economic_instrument = fill.instrument;
        _ = try self.applyEconomicProjection(.{ .fill = .{
            .identity = fill_id,
            .side = switch (fill.side) {
                .buy => .buy,
                .sell => .sell,
            },
            .quantity = .{ .instrument = economic_instrument, .rules_version = fill.quantity.rules_version, .lots = fill.quantity.lots },
            .price = .{ .instrument = economic_instrument, .rules_version = fill.price.rules_version, .ticks = fill.price.ticks },
            .quantity_denominator = instrument_config.rules.quantity_denominator,
            .fee = settlement_fee,
            .rebate = settlement_rebate,
            .base_fee_quantity = base_fee_quantity,
            .base_rebate_quantity = base_rebate_quantity,
            .portfolio_margin_ppm = if (instrument_config.margin_configured) instrument_config.margin.internal_initial_margin_ppm else self.internal_initial_margin_ppm,
            .exchange_margin_ppm = if (instrument_config.margin_configured) instrument_config.margin.venue_initial_margin_ppm else self.venue_initial_margin_ppm,
            .product = instrument_config.product,
        } });
        self.last_canonical_fill = fill;
        try self.applyFill(.{ .fill_id = fill_id, .order_id = order_id, .quantity = quantity, .price_micros = price });
        try self.trace.append(.fill, fact_identity);
        try self.trace.append(.fee_ledger_transaction, fact_identity);
        try self.trace.append(.risk_reservation_rebalanced, fact_identity);
    }

    fn handle(self: *TradingShard, input: CoreEvent) !?OrderCommand {
        switch (input.payload) {
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
                        .open = self.risk_lease_micros > 0,
                        .continuity_proven = self.risk_lease_micros > 0,
                    });
                }
                if (action.cancel_open_orders)
                    try self.oms.cancelOpenOrders(action.cancel_increasing_only);
                if (keep_positions) {
                    if (action.cancel_increasing_only or
                        self.operational_state.mode != .stopped or
                        preserved.de_risk_target_position != self.operational_state.target_position)
                        return error.KeepPositionsMisreadAsDeRisk;
                    try self.assertLifecycleEconomicsPreserved(preserved);
                    try self.assertClosures();
                }
                try self.trace.append(.control_command_applied, input.identity);
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
                    try std.math.add(i64, self.portfolioCash(), self.treasuryCash()) != self.exchangeCash())
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
                if (self.instrument_rules_version == 0 or instrument_id == 0 or rules.version == 0 or rules.price_tick_micros <= 0 or
                    rules.venue_initial_margin_ppm <= 0 or
                    rules.internal_initial_margin_ppm < rules.venue_initial_margin_ppm or
                    rules.internal_maintenance_margin_ppm <= 0 or
                    rules.internal_maintenance_margin_ppm > rules.internal_initial_margin_ppm or
                    rules.fee_ppm < 0 or
                    rules.opening_buffer_micros < rules.warning_buffer_micros or
                    rules.warning_buffer_micros < rules.kill_buffer_micros or
                    rules.kill_buffer_micros < 0 or
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
                const configured = try self.instrument_registry.configureMargin(instrument_id, rules);
                if (!configured) return null;
                if (instrument_id == self.instrument_identity) {
                    self.margin_rules_version = rules.version;
                    self.price_tick_micros = rules.price_tick_micros;
                    self.venue_initial_margin_ppm = rules.venue_initial_margin_ppm;
                    self.internal_initial_margin_ppm = rules.internal_initial_margin_ppm;
                    self.internal_maintenance_margin_ppm = rules.internal_maintenance_margin_ppm;
                    self.risk_fee_ppm = rules.fee_ppm;
                    self.opening_buffer_micros = rules.opening_buffer_micros;
                    self.opening_buffer_bps = rules.opening_buffer_bps;
                    self.opening_liquidation_distance_ticks = rules.opening_liquidation_distance_ticks;
                    self.warning_buffer_micros = rules.warning_buffer_micros;
                    self.kill_buffer_micros = rules.kill_buffer_micros;
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
                if (!self.account_configured or balance.cash_micros <= 0 or self.exchange_balance_observed)
                    return error.InvalidExchangeBalance;
                self.economic_projection.exchange.usdt_balance_micros = balance.cash_micros;
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
                if (!self.exchange_positions_observed or balance.cash_micros <= 0 or
                    balance.cash_micros != self.exchangeCash() or self.opening_balance_observed)
                    return error.InvalidOpeningBalance;
                self.economic_projection.treasury_usdt_micros = balance.cash_micros;
                self.economic_projection.ledger_summary = .{
                    .transaction_count = 1,
                    .portfolio_debits_micros = balance.cash_micros,
                    .portfolio_credits_micros = balance.cash_micros,
                    .exchange_debits_micros = balance.cash_micros,
                    .exchange_credits_micros = balance.cash_micros,
                };
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
                if (!self.virtual_portfolio_active or transfer.amount_micros <= 0 or
                    transfer.amount_micros > self.treasuryCash() or self.portfolio_funded)
                    return error.InvalidPortfolioTransfer;
                self.economic_projection.treasury_usdt_micros = try std.math.sub(
                    i64,
                    self.treasuryCash(),
                    transfer.amount_micros,
                );
                self.economic_projection.portfolio.usdt_balance_micros = try std.math.add(
                    i64,
                    self.portfolioCash(),
                    transfer.amount_micros,
                );
                self.economic_projection.ledger_summary.portfolio_debits_micros = try std.math.add(
                    i64,
                    self.economic_projection.ledger_summary.portfolio_debits_micros,
                    transfer.amount_micros,
                );
                self.economic_projection.ledger_summary.portfolio_credits_micros = try std.math.add(
                    i64,
                    self.economic_projection.ledger_summary.portfolio_credits_micros,
                    transfer.amount_micros,
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
                if (self.host_activation_identity != 0) {
                    if (self.host_activation_identity != activation.activation_identity or
                        self.host_activation_barrier != activation.activation_barrier or
                        !std.mem.eql(u8, &self.host_activation_state_digest, &activation.state_digest))
                        return error.HostActivationConflict;
                    return null;
                }
                if (!self.strategy_active or
                    activation.strategy_identity != self.strategy_identity or
                    activation.config_version != self.strategy_config_version or
                    activation.activation_identity != self.strategy_activation_identity or
                    activation.activation_barrier == std.math.maxInt(u64) or
                    !std.mem.eql(u8, &activation.state_digest, &self.canonicalStateDigest()))
                    return error.InvalidHostActivation;
                self.host_activation_identity = activation.activation_identity;
                self.host_activation_barrier = activation.activation_barrier;
                self.host_activation_state_digest = activation.state_digest;
                try self.trace.append(.host_activated, input.identity);
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
                        lease.amount_micros != self.risk_lease_micros or lease.open != (self.risk_lease_micros > 0))
                        return error.RiskLeaseIdentityConflict;
                    return null;
                }
                if (lease.open and lease.amount_micros <= 0) return error.InvalidRiskLease;
                if (!lease.open and lease.amount_micros != 0) return error.InvalidRiskLease;
                self.risk_lease_identity = lease_identity;
                self.risk_lease_version = lease.version;
                self.risk_lease_valid_through_barrier = lease.valid_through_barrier;
                self.risk_lease_micros = lease.amount_micros;
                self.strategy_limit_micros = if (lease.strategy_limit_micros == 0) lease.amount_micros else lease.strategy_limit_micros;
                self.portfolio_limit_micros = if (lease.portfolio_limit_micros == 0) lease.amount_micros else lease.portfolio_limit_micros;
                self.exchange_account_limit_micros = if (lease.exchange_account_limit_micros == 0) lease.amount_micros else lease.exchange_account_limit_micros;
                self.global_limit_micros = if (lease.global_limit_micros == 0) lease.amount_micros else lease.global_limit_micros;
                if (self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = risk_lease_gate_identity,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .self_recovering,
                    .reason = .risk_lease,
                    .open = lease.open,
                    .continuity_proven = lease.open,
                });
                if (self.strategy_limit_micros > self.portfolio_limit_micros or
                    self.portfolio_limit_micros > self.exchange_account_limit_micros or
                    self.exchange_account_limit_micros > self.global_limit_micros or
                    self.risk_lease_micros > self.exchange_account_limit_micros)
                    return error.InvalidRiskLeaseHierarchy;
                try self.recalculateRisk(false);
                try self.assertClosures();
                try self.trace.append(.risk_lease_granted, input.identity);
            },
            .mark_price => |price| {
                if (price.price_micros <= 0) return error.InvalidMarkPrice;
                const instrument = self.instrument_registry.get(price.instrument) orelse return error.UnknownInstrument;
                try self.canonical_market.apply(.{ .reference_price = .{
                    .instrument = price.instrument,
                    .kind = .mark,
                    .price = .{ .instrument = price.instrument, .rules_version = instrument.rules.version, .ticks = price.price_micros },
                } });
                if (price.instrument == self.instrument_identity) self.mark_price_micros = price.price_micros;
                _ = try self.applyEconomicProjection(.{ .mark_price = .{
                    .product = instrument.product,
                    .price_micros = price.price_micros,
                    .quantity_denominator = instrument.rules.quantity_denominator,
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
                }, if (input.time_presence.monotonic) input.monotonic_time else 0);
            },
            .external_order_intent => |intent| {
                if (!self.strategy_active or intent.strategy_cursor <= self.strategy_cursor)
                    return error.InvalidStrategyCursor;
                self.strategy_cursor = intent.strategy_cursor;
                self.strategy_decision_count = try std.math.add(u64, self.strategy_decision_count, 1);
                return self.submitOrderIntent(intent, if (input.time_presence.monotonic) input.monotonic_time else 0);
            },
            .strategy_intent_rejected => |rejection| {
                try self.trace.append(.strategy_intent_rejected, rejection.intent_sequence);
            },
            .oms_intent_group => |group| {
                if (!self.genesisReady()) return error.GenesisIncomplete;
                var candidate = self.*;
                const qualified = candidate.qualifyOmsGroup(group) catch |err| switch (err) {
                    error.MarginSafetyGateClosed => {
                        try candidate.trace.append(.strategy_intent_rejected, group.first_intent_sequence);
                        self.* = candidate;
                        return null;
                    },
                    else => return err,
                };
                const duplicate = candidate.oms.groupKnown(qualified);
                if (duplicate) return null;
                var refs: [oms_module.max_group_members]oms_module.RiskFactRefs = undefined;
                for (qualified.members[0..qualified.count], 0..) |intent, index| {
                    try candidate.trace.append(.risk_accepted, intent.intent_sequence);
                    refs[index].decision = @intCast(candidate.trace.len);
                    try candidate.trace.append(.risk_reservation_created, intent.intent_sequence);
                    refs[index].reservation = @intCast(candidate.trace.len);
                    refs[index].authority = try candidate.dispatchAuthorityRefs(intent.instrument, if (input.time_presence.monotonic) input.monotonic_time else 0, refs[index].decision);
                }
                try candidate.oms.applyQualifiedGroup(qualified, refs[0..qualified.count]);
                try candidate.refreshLayeredReservations();
                try candidate.trace.append(.oms_intent_group, group.first_intent_sequence);
                self.* = candidate;
            },
            .oms_dispatch_batch => |batch| {
                var candidate = self.*;
                try candidate.oms.applyDispatch(batch);
                try candidate.refreshLayeredReservations();
                try candidate.trace.append(.oms_dispatch_batch, input.identity);
                self.* = candidate;
            },
            .oms_execution_report => |report| {
                try self.oms.applyReport(report);
                try self.confirmPendingReplacement(report.order_id, report.report_id, if (input.time_presence.monotonic) input.monotonic_time else 0);
                try self.refreshLayeredReservations();
                try self.trace.append(.oms_execution_report, report.report_id);
            },
            .oms_reconciliation_result => |result| {
                try self.oms.applyReconciliation(result);
                if (result.status == .unresolved and self.operational_state.initialized) try self.applyOperationalGate(.{
                    .gate_identity = result.reconciliation_id,
                    .target_identity = self.operational_state.target_identity,
                    .kind = .latched,
                    .reason = .reconciliation_break,
                    .open = false,
                });
                try self.confirmPendingReplacement(result.order_id, result.reconciliation_id, if (input.time_presence.monotonic) input.monotonic_time else 0);
                try self.refreshLayeredReservations();
                try self.trace.append(.oms_reconciliation_result, result.reconciliation_id);
            },
            .economic_fill => |fill| {
                const order = self.oms.orderById(fill.order_id) orelse return error.UnknownOrder;
                const instrument = order.instrument;
                const instrument_config = self.instrumentEntry(instrument) orelse return error.UnknownOmsInstrument;
                const changed = try self.applyEconomicProjection(.{ .fill = .{
                    .identity = fill.fill_id,
                    .side = if (order.side == .buy) .buy else .sell,
                    .quantity = .{ .instrument = instrument, .rules_version = instrument_config.rules.version, .lots = fill.quantity },
                    .price = .{ .instrument = instrument, .rules_version = instrument_config.rules.version, .ticks = fill.price_micros },
                    .quantity_denominator = instrument_config.rules.quantity_denominator,
                    .fee = .{ .asset = self.economic_projection.settlement_asset, .atoms = fill.fee_micros },
                    .rebate = .{ .asset = self.economic_projection.settlement_asset, .atoms = fill.rebate_micros },
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
                const changed = try self.applyEconomicProjection(.{ .funding_settlement = .{ .identity = funding.settlement_id, .amount = .{ .asset = self.economic_projection.settlement_asset, .atoms = funding.amount_micros } } });
                if (changed) try self.trace.append(.funding_settlement, funding.settlement_id);
            },
            .venue_forced_execution => |forced| {
                const instrument_config = self.singleProductEntry(.isolated_linear_usdt) orelse return error.UnknownOmsInstrument;
                const changed = try self.applyEconomicProjection(.{ .venue_forced_execution = .{
                    .identity = forced.execution_id,
                    .side = if (forced.side == .buy) .buy else .sell,
                    .quantity = .{ .instrument = instrument_config.instrument, .rules_version = instrument_config.rules.version, .lots = forced.quantity },
                    .price = .{ .instrument = instrument_config.instrument, .rules_version = instrument_config.rules.version, .ticks = forced.price_micros },
                    .quantity_denominator = instrument_config.rules.quantity_denominator,
                    .fee = .{ .asset = self.economic_projection.settlement_asset, .atoms = forced.fee_micros },
                    .penalty = .{ .asset = self.economic_projection.settlement_asset, .atoms = forced.penalty_micros },
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
                    .balance = .{ .asset = self.economic_projection.settlement_asset, .atoms = account_snapshot.usdt_balance_micros },
                    .spot_asset_quantity = account_snapshot.spot_asset_quantity,
                    .swap_position_quantity = account_snapshot.swap_position_quantity,
                    .margin = .{ .asset = self.economic_projection.settlement_asset, .atoms = account_snapshot.margin_micros },
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
        shard.economic_projection.ledger_count > shard.economic_projection.ledger.len or
        shard.economic_projection.reconciliation_break_count > shard.economic_projection.reconciliation_break_identities.len or
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
    try shard.instrument_registry.validate();
    if (shard.authority_control_barrier != 0 and
        (shard.authority_control_barrier > shard.trace.len or
            shard.trace.events[shard.authority_control_barrier - 1].kind != .control_command_applied))
        return error.InvalidSnapshotState;
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
        var identity_bytes: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &identity_bytes, event.identity, .little);
        try decision_journal.append(.{
            .type_id = @intFromEnum(event.kind),
            .schema_version = schema_version,
            .flags = if (index == 0) journal.input_flag else 0,
            .sequence = event.sequence,
            .source_time = times.source,
            .receive_time = times.receive,
            .monotonic_time = times.monotonic,
            .wall_time = times.wall,
            .time_presence = times.presence,
            .payload = if (index == 0) encoded_input else &identity_bytes,
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
    var candidate_shard = shard.*;
    const result = candidate_shard.apply(input) catch |err| {
        // Account/market projection failure is itself a durable fact. Keep
        // the invalid candidate and journal its fact group before surfacing
        // the original observation error to the caller.
        if (candidate_shard.canonical_account.failure != account_failure_before or
            candidate_shard.canonical_market.failure_generation != market_failure_generation_before or
            candidate_shard.oms.recovery_only != oms_recovery_before)
        {
            appendStableFactGroup(decision_journal, input, candidate_shard.trace.events[before..candidate_shard.trace.len]) catch |journal_err| {
                decision_journal.restore(checkpoint);
                return journal_err;
            };
            shard.* = candidate_shard;
        }
        return err;
    };
    if (result.facts.len == 0) return error.InputProducedNoFact;
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
    digestInt(&hasher, u8, shard.instrument_registry.count);
    for (shard.instrument_registry.entries[0..shard.instrument_registry.count]) |entry| {
        digestInt(&hasher, u128, entry.instrument);
        digestInt(&hasher, u64, entry.venue);
        digestInt(&hasher, u8, @intFromEnum(entry.product));
        digestInt(&hasher, u32, entry.rules.version);
        digestInt(&hasher, i64, entry.rules.quantity_denominator);
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
        digestInt(&hasher, i64, entry.margin.price_tick_micros);
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
    hasher.update(&shard.host_activation_state_digest);
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
        digestBool(&hasher, order.reservation_active);
        digestBool(&hasher, order.dispatch_submitted);
        digestInt(&hasher, u64, order.group_first_sequence);
        digestInt(&hasher, u8, @intFromEnum(order.group_policy));
        digestBool(&hasher, order.replacement != null);
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
    }
    digestInt(&hasher, u8, shard.oms.intent_history_count);
    for (shard.oms.intent_history[0..shard.oms.intent_history_count]) |known| {
        digestInt(&hasher, u64, known.group);
        digestInt(&hasher, u8, @intFromEnum(known.policy));
        digestInt(&hasher, u64, known.intent_sequence);
        digestInt(&hasher, u128, known.strategy_instance);
        digestInt(&hasher, u64, known.fingerprint);
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
    digestBool(&hasher, shard.oms.recovery_only);
    digestEconomicProjection(&hasher, shard.economic_projection);
    digestInt(&hasher, u64, shard.fencing_token);
    digestInt(&hasher, u64, shard.trace.len);
    for (shard.trace.events[0..shard.trace.len]) |event| {
        digestInt(&hasher, u64, event.sequence);
        digestInt(&hasher, u16, @intFromEnum(event.kind));
        digestInt(&hasher, u64, event.identity);
    }

    digestBool(&hasher, shard.expected_source_sequence != null);
    digestInt(&hasher, u64, shard.expected_source_sequence orelse 0);
    digestInt(&hasher, u8, @intFromEnum(shard.market_health));
    digestInt(&hasher, i64, shard.bid_price_micros);
    digestInt(&hasher, i64, shard.bid_quantity);
    digestInt(&hasher, i64, shard.ask_1_price_micros);
    digestInt(&hasher, i64, shard.ask_1_quantity);
    digestInt(&hasher, i64, shard.ask_2_price_micros);
    digestInt(&hasher, i64, shard.ask_2_quantity);
    digestInt(&hasher, u64, shard.strategy_cursor);
    digestInt(&hasher, u64, shard.strategy_decision_count);
    digestBool(&hasher, shard.timer_pending);
    digestInt(&hasher, u64, shard.dispatch_attempt_count);
    digestInt(&hasher, u8, @intFromEnum(shard.last_reject_reason));
    digestInt(&hasher, i64, shard.last_risk_required_micros);
    digestInt(&hasher, u8, shard.last_risk_tier);
    digestInt(&hasher, i64, shard.mark_price_micros);
    digestInt(&hasher, i64, portfolio_position.quantity);
    digestInt(&hasher, i64, portfolio_position.open_cost_micros);
    digestInt(&hasher, i64, exchange_position.quantity);
    digestInt(&hasher, i64, exchange_position.open_cost_micros);
    digestInt(&hasher, i64, spot_portfolio_position.quantity);
    digestInt(&hasher, i64, spot_portfolio_position.open_cost_micros);
    digestInt(&hasher, i64, spot_exchange_position.quantity);
    digestInt(&hasher, i64, spot_exchange_position.open_cost_micros);
    digestInt(&hasher, i64, shard.portfolioCash());
    digestInt(&hasher, i64, shard.treasuryCash());
    digestInt(&hasher, i64, shard.exchangeCash());
    digestInt(&hasher, i64, shard.portfolioFee());
    digestInt(&hasher, i64, shard.exchangeFee());
    digestInt(&hasher, i64, shard.totalFees());
    digestInt(&hasher, i64, shard.realizedPnl());
    digestInt(&hasher, i64, shard.unrealizedPnl());
    digestInt(&hasher, i64, shard.risk_lease_micros);
    digestInt(&hasher, u64, shard.risk_lease_identity);
    digestInt(&hasher, u64, shard.risk_lease_version);
    digestInt(&hasher, u64, shard.risk_lease_valid_through_barrier);
    digestInt(&hasher, i64, shard.strategy_limit_micros);
    digestInt(&hasher, i64, shard.portfolio_limit_micros);
    digestInt(&hasher, i64, shard.exchange_account_limit_micros);
    digestInt(&hasher, i64, shard.global_limit_micros);
    digestInt(&hasher, i64, shard.price_tick_micros);
    digestInt(&hasher, i64, shard.venue_initial_margin_ppm);
    digestInt(&hasher, i64, shard.internal_initial_margin_ppm);
    digestInt(&hasher, i64, shard.internal_maintenance_margin_ppm);
    digestInt(&hasher, i64, shard.risk_fee_ppm);
    digestInt(&hasher, i64, shard.opening_buffer_micros);
    digestInt(&hasher, i64, shard.opening_buffer_bps);
    digestInt(&hasher, i64, shard.opening_liquidation_distance_ticks);
    digestInt(&hasher, i64, shard.warning_buffer_micros);
    digestInt(&hasher, i64, shard.kill_buffer_micros);
    digestInt(&hasher, i64, shard.warning_buffer_bps);
    digestInt(&hasher, i64, shard.kill_buffer_bps);
    digestInt(&hasher, i64, shard.warning_liquidation_distance_ticks);
    digestInt(&hasher, i64, shard.kill_liquidation_distance_ticks);
    digestInt(&hasher, i64, shard.layered_risk_reserved_micros);
    digestInt(&hasher, i64, shard.portfolio_margin_buffer_micros);
    digestInt(&hasher, i64, shard.exchange_margin_buffer_micros);
    digestInt(&hasher, i64, shard.portfolio_buffer_bps);
    digestInt(&hasher, i64, shard.exchange_buffer_bps);
    digestInt(&hasher, i64, shard.portfolio_liquidation_distance_ticks);
    digestInt(&hasher, i64, shard.exchange_liquidation_distance_ticks);
    digestInt(&hasher, u8, @intFromEnum(shard.portfolio_margin_gate));
    digestInt(&hasher, u8, @intFromEnum(shard.exchange_margin_gate));
    digestInt(&hasher, u64, ledger.transaction_count);
    digestInt(&hasher, u64, ledger.portfolio_transfer_count);
    digestInt(&hasher, i64, ledger.portfolio_debits_micros);
    digestInt(&hasher, i64, ledger.portfolio_credits_micros);
    digestInt(&hasher, i64, ledger.exchange_debits_micros);
    digestInt(&hasher, i64, ledger.exchange_credits_micros);
    digestBool(&hasher, ledger.projections_complete);
    digestCanonicalProjections(&hasher, shard);
    return hasher.finalResult();
}

fn digestCanonicalProjections(hasher: *Sha256, shard: TradingShard) void {
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
    const kind = std.enums.fromInt(EventKind, record.type_id) orelse
        return error.UnknownEventType;
    if (record.sequence != expected.sequence or kind != expected.kind or
        (!is_input and try eventIdentity(record.payload) != expected.identity))
        return error.ReplayFactMismatch;
    const times = stableTimes(input);
    if (record.source_time != times.source or
        record.receive_time != times.receive or
        record.monotonic_time != times.monotonic or
        record.wall_time != times.wall or
        @as(u8, @bitCast(record.time_presence)) != @as(u8, @bitCast(times.presence)))
        return error.ReplayTimeMismatch;
    if (is_input) {
        if (record.flags != journal.input_flag) return error.InputFlagMissing;
    } else if (record.flags != 0 or record.payload.len != @sizeOf(u64)) {
        return error.InvalidDerivedFactRecord;
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
        if (first_record.flags != journal.input_flag) return error.OrphanDerivedFact;
        var candidate = shard;
        const input = try decodeStableInput(first_record);
        const before = candidate.trace.len;
        var replay_error: ?anyerror = null;
        _ = candidate.apply(input) catch |err| {
            replay_error = err;
        };
        if (replay_error != null and candidate.canonical_account.failure == null and
            candidate.canonical_market.latestFailure() == null)
            return replay_error.?;
        const generated = candidate.trace.events[before..candidate.trace.len];
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
