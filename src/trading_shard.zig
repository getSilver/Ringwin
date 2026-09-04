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

/// Current physical schema for AuthoritativeTradingState snapshots.
pub const state_schema_version: u32 = 4;
/// Release artifact producing the current snapshot schema.
pub const release_artifact_identity: u64 = 1;
/// Registry entry defining the current snapshot and journal schemas.
pub const schema_registry_identity: u64 = 2;
const client_order_id = "RWN-00000001-01-000000000001";
const settlement_asset: canonical.AssetIdentity = 1;
const spot_instrument: oms_module.Instrument = 1;
const swap_instrument: oms_module.Instrument = 2;
const money_scale: i64 = 1_000_000;
const contract_denominator: i64 = 10_000;
const fee_ppm: i64 = 750;
const market_data_gate_identity: u128 = 0x4d41524b455444415441;
const margin_warning_gate_identity: u128 = 0x4d415247494e5741524e;
const margin_kill_gate_identity: u128 = 0x4d415247494e4b494c4c;
const primary_lease_gate_identity: u128 = 0x5052494d4152594c45415345;
const risk_lease_gate_identity: u128 = 0x5249534b4c45415345;
const rate_scale: i64 = 1_000_000;
const leverage: i64 = 50;
const internal_margin_percent: i64 = 110;
const order_limit_price: i64 = 50_100_000_000;

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
pub const MarginRules = shard_event.MarginRules;
pub const AccountConfiguration = shard_event.AccountConfiguration;
pub const Balance = shard_event.Balance;
pub const VirtualPortfolioActivation = shard_event.VirtualPortfolioActivation;
pub const PortfolioTransfer = shard_event.PortfolioTransfer;
pub const StrategyActivation = shard_event.StrategyActivation;
pub const PrimaryLease = shard_event.PrimaryLease;
pub const RiskLease = shard_event.RiskLease;
pub const StrategyCutoverFence = shard_event.StrategyCutoverFence;
pub const StrategyStateTransition = shard_event.StrategyStateTransition;
pub const VersionActivationEvent = shard_event.VersionActivationEvent;
pub const CorePayload = shard_event.CorePayload;
pub const CoreTransition = shard_event.CoreTransition;
const InputEvent = shard_event.InputEvent;

const EncodedInput = shard_event.EncodedInput;
const encodeInput = shard_event.encodeInput;
const decodeInput = shard_event.decodeInput;
const eventIdentity = shard_event.eventIdentity;

pub fn decodeStableInput(record: journal.Record) !canonical.EventRecord {
    return coreRecordFromInput(try shard_event.decodeStableInput(record));
}

/// Lifts a typed core fact/command into the single canonical EventRecord seam.
pub fn coreRecord(input: CoreTransition) !canonical.EventRecord {
    const encoded = try encodeInput(input);
    var core: canonical.CoreInput = .{ .len = @intCast(encoded.len) };
    @memcpy(core.bytes[0..encoded.len], encoded.bytes[0..encoded.len]);
    return .{
        .envelope = .{
            .event_type = @intFromEnum(canonical.EventType.core_input),
            .schema_version = schema_version,
            .identity = .{ .stream = 0, .sequence = input.identity },
            .source_fact_identity = input.identity,
            .scope = .account,
            .venue = 0,
            .source_stream = 0,
            .source_sequence = input.identity,
            .times = .{},
            .raw_evidence = .{ .stream = 0, .sequence = input.identity, .digest = @splat(0) },
        },
        .event = .{ .core_input = core },
    };
}

fn coreRecordFromInput(input: InputEvent) !canonical.EventRecord {
    var record = try coreRecord(.{ .identity = input.identity, .payload = input.payload });
    record.envelope.times = .{
        .source_utc_ns = if (input.time_presence.source) input.source_time else null,
        .receive_utc_ns = if (input.time_presence.receive) input.receive_time else null,
        .monotonic_ns = if (input.time_presence.monotonic) input.monotonic_time else null,
        .audit_utc_ns = if (input.time_presence.wall) input.wall_time else null,
    };
    return record;
}

fn decodeCoreInput(envelope: canonical.EventEnvelope, encoded: canonical.CoreInput) !InputEvent {
    return decodeInput(.{
        .type_id = 0,
        .schema_version = envelope.schema_version,
        .flags = journal.input_flag,
        .sequence = envelope.identity.sequence,
        .source_time = envelope.times.source_utc_ns orelse 0,
        .receive_time = envelope.times.receive_utc_ns orelse 0,
        .monotonic_time = envelope.times.monotonic_ns orelse 0,
        .wall_time = envelope.times.audit_utc_ns orelse 0,
        .time_presence = .{
            .source = envelope.times.source_utc_ns != null,
            .receive = envelope.times.receive_utc_ns != null,
            .monotonic = envelope.times.monotonic_ns != null,
            .wall = envelope.times.audit_utc_ns != null,
        },
        .payload = encoded.slice(),
    });
}

pub const OrderCommand = struct {
    command_id: u64,
    order_id: u64,
    quantity: canonical.InstrumentQuantity,
    limit_price: canonical.InstrumentPrice,
    reservation: canonical.AssetAmount,
    client_id: []const u8,
};

pub const ApplyResult = struct {
    facts: []const Fact,
    order_command: ?OrderCommand,
    oms_commands: []const oms_module.Command,
};

pub const ReplayTradingShard = struct {
    shard: TradingShard = .{},

    pub fn apply(self: *ReplayTradingShard, event: canonical.EventRecord) ![]const Fact {
        return (try self.shard.apply(event)).facts;
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

pub const OrderState = enum(u8) {
    none,
    pending_submit,
    unknown,
    live,
    partially_filled,
    filled,
    canceled,
};

const Position = struct {
    quantity: i64 = 0,
    open_cost_micros: i64 = 0,
};

fn ceilDivPositive(numerator: i128, denominator: i128) !i64 {
    if (numerator < 0 or denominator <= 0) return error.InvalidPositiveDivision;
    return std.math.cast(i64, @divFloor(numerator + denominator - 1, denominator)) orelse
        error.Overflow;
}

fn notionalMicros(quantity: i64, price_micros: i64) !i64 {
    return notionalMicrosScaled(quantity, price_micros, contract_denominator);
}

fn notionalMicrosScaled(quantity: i64, price_micros: i64, quantity_denominator: i64) !i64 {
    if (quantity < 0 or price_micros <= 0 or quantity_denominator <= 0)
        return error.InvalidNotionalInput;
    return ceilDivPositive(
        @as(i128, quantity) * price_micros,
        quantity_denominator,
    );
}

fn feeMicros(notional_micros: i64) !i64 {
    return ceilDivPositive(@as(i128, notional_micros) * fee_ppm, rate_scale);
}

fn internalMarginMicros(notional_micros: i64) !i64 {
    const venue_margin = try ceilDivPositive(notional_micros, leverage);
    return ceilDivPositive(@as(i128, venue_margin) * internal_margin_percent, 100);
}

fn openOrderReservationMicros(remaining_quantity: i64, limit_price_micros: i64) !i64 {
    return openOrderReservationMicrosScaled(remaining_quantity, limit_price_micros, contract_denominator);
}

fn openOrderReservationMicrosScaled(remaining_quantity: i64, limit_price_micros: i64, quantity_denominator: i64) !i64 {
    if (remaining_quantity == 0) return 0;
    const notional = try notionalMicrosScaled(remaining_quantity, limit_price_micros, quantity_denominator);
    return try std.math.add(i64, try internalMarginMicros(notional), try feeMicros(notional));
}

fn riskTier(notional_micros: i64) !u8 {
    if (notional_micros <= 500_000 * money_scale) return 1;
    if (notional_micros <= 1_000_000 * money_scale) return 2;
    if (notional_micros <= 1_500_000 * money_scale) return 3;
    return error.RiskLimitExceeded;
}

const FillProjection = struct { fill_id: u64, quantity: i64, price_micros: i64 };
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
    order_counter: u64 = 0,
    timer_pending: bool = true,
    order_state: OrderState = .none,
    order_id: u64 = 0,
    order_command_id: u64 = 0,
    order_quantity: i64 = 0,
    order_limit_price_micros: i64 = 0,
    dispatch_attempt_count: u64 = 0,
    last_reject_reason: RejectReason = .none,
    last_risk_required_micros: i64 = 0,
    last_risk_tier: u8 = 0,
    filled_quantity: i64 = 0,
    mark_price_micros: i64 = 0,
    spot_portfolio_position: Position = .{},
    spot_exchange_position: Position = .{},
    portfolio_position: Position = .{},
    exchange_position: Position = .{},
    portfolio_cash_micros: i64 = 0,
    treasury_cash_micros: i64 = 0,
    exchange_cash_micros: i64 = 0,
    portfolio_fee_expense_micros: i64 = 0,
    exchange_fee_expense_micros: i64 = 0,
    total_fees_micros: i64 = 0,
    realized_pnl_micros: i64 = 0,
    unrealized_pnl_micros: i64 = 0,
    open_order_reservation_micros: i64 = 0,
    position_margin_requirement_micros: i64 = 0,
    risk_lease_micros: i64 = 0,
    risk_lease_remaining_micros: i64 = 0,
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
    portfolio_liquidation_distance_ticks: i64 = 0,
    exchange_liquidation_distance_ticks: i64 = 0,
    portfolio_margin_gate: risk_module.MarginGate = .healthy,
    exchange_margin_gate: risk_module.MarginGate = .healthy,
    ledger_transaction_count: u64 = 0,
    portfolio_transfer_count: u64 = 0,
    portfolio_ledger_debits_micros: i64 = 0,
    portfolio_ledger_credits_micros: i64 = 0,
    exchange_ledger_debits_micros: i64 = 0,
    exchange_ledger_credits_micros: i64 = 0,
    economic_projections_complete: bool = false,
    quantity_denominator: i64 = contract_denominator,
    reservation_model: ReservationModel = .leveraged,
    instrument_identity: u128 = 0,
    exchange_account_identity: u128 = 0,
    portfolio_identity: u128 = 0,
    strategy_identity: u128 = 0,
    strategy_config_version: u64 = 0,
    strategy_activation_identity: u128 = 0,
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

    /// The sole public Venue/market ingress seam. Canonical fields are
    /// projected directly; they are never narrowed through the legacy shard
    /// journal schema.
    pub fn apply(self: *TradingShard, event: canonical.EventRecord) !ApplyResult {
        var candidate = self.*;
        const before = candidate.trace.len;
        candidate.oms.begin();
        const command = switch (event.event) {
            .core_input => |encoded| blk: {
                if (event.envelope.schema_version != schema_version) return error.UnsupportedSchema;
                break :blk try candidate.handle(try decodeCoreInput(event.envelope, encoded));
            },
            else => blk: {
                if (event.envelope.schema_version != canonical.schema_version) return error.UnsupportedSchema;
                break :blk try candidate.handleCanonical(event);
            },
        };
        self.* = candidate;
        return .{
            .facts = self.trace.events[before..self.trace.len],
            .order_command = command,
            .oms_commands = self.oms.emitted(),
        };
    }

    fn applyInput(self: *TradingShard, event: InputEvent) !ApplyResult {
        var candidate = self.*;
        const before = candidate.trace.len;
        candidate.oms.begin();
        const command = try candidate.handle(event);
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

    pub fn genesisReady(self: *const TradingShard) bool {
        return self.instrument_rules_version != 0 and self.margin_rules_version != 0 and
            self.account_configured and self.exchange_balance_observed and
            self.exchange_positions_observed and self.opening_balance_observed and
            self.virtual_portfolio_active and self.portfolio_funded and self.strategy_active and
            self.fencing_token != 0 and self.risk_lease_micros > 0;
    }

    fn shardNotionalMicros(self: *const TradingShard, quantity: i64, price_micros: i64) !i64 {
        return notionalMicrosScaled(quantity, price_micros, self.quantity_denominator);
    }

    fn shardOpenOrderReservationMicros(self: *const TradingShard, quantity: i64, price_micros: i64) !i64 {
        const notional = try self.shardNotionalMicros(quantity, price_micros);
        return switch (self.reservation_model) {
            .leveraged => try std.math.add(i64, try internalMarginMicros(notional), try feeMicros(notional)),
            .cash => try std.math.add(i64, notional, try feeMicros(notional)),
        };
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

    fn riskRules(self: *const TradingShard, instrument: canonical.InstrumentIdentity) risk_module.Rules {
        return .{
            .settlement_asset = settlement_asset,
            .instrument = instrument,
            .rules_version = self.instrument_rules_version,
            .quantity_denominator = self.quantity_denominator,
            .price_tick_value = .{ .asset = settlement_asset, .atoms = self.price_tick_micros },
            .venue_initial_margin_ppm = self.venue_initial_margin_ppm,
            .internal_initial_margin_ppm = self.internal_initial_margin_ppm,
            .internal_maintenance_margin_ppm = self.internal_maintenance_margin_ppm,
            .fee_ppm = self.risk_fee_ppm,
            .opening_buffer = .{ .asset = settlement_asset, .atoms = self.opening_buffer_micros },
            .opening_buffer_bps = self.opening_buffer_bps,
            .opening_liquidation_distance_ticks = self.opening_liquidation_distance_ticks,
            .warning_buffer = .{ .asset = settlement_asset, .atoms = self.warning_buffer_micros },
            .kill_buffer = .{ .asset = settlement_asset, .atoms = self.kill_buffer_micros },
            .warning_buffer_bps = self.warning_buffer_bps,
            .kill_buffer_bps = self.kill_buffer_bps,
            .warning_liquidation_distance_ticks = self.warning_liquidation_distance_ticks,
            .kill_liquidation_distance_ticks = self.kill_liquidation_distance_ticks,
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
            const portfolio_position_quantity = switch (intent.instrument) {
                spot_instrument => self.spot_portfolio_position.quantity,
                swap_instrument => self.portfolio_position.quantity,
                else => return error.UnknownOmsInstrument,
            };
            const exchange_position_quantity = switch (intent.instrument) {
                spot_instrument => self.spot_exchange_position.quantity,
                swap_instrument => self.exchange_position.quantity,
                else => return error.UnknownOmsInstrument,
            };
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
            const assessment = try risk_module.assess(self.riskRules(intent.instrument), self.riskLimits(), .{
                .portfolio_cash = .{ .asset = settlement_asset, .atoms = self.portfolio_cash_micros },
                .exchange_cash = .{ .asset = settlement_asset, .atoms = self.exchange_cash_micros },
                .portfolio_position = .{ .instrument = intent.instrument, .rules_version = self.instrument_rules_version, .lots = portfolio_position_quantity },
                .exchange_position = .{ .instrument = intent.instrument, .rules_version = self.instrument_rules_version, .lots = exchange_position_quantity },
                .active_order_reservations = active,
                .replaced_order_reservation = replaced,
                .mark_price = .{ .instrument = intent.instrument, .rules_version = self.instrument_rules_version, .ticks = self.mark_price_micros },
            }, .{
                .product = if (intent.instrument == spot_instrument) .spot else .isolated_linear_usdt,
                .side = if (intent.side == .buy) .buy else .sell,
                .quantity = .{ .instrument = intent.instrument, .rules_version = self.instrument_rules_version, .lots = intent.quantity },
                .risk_price = .{ .instrument = intent.instrument, .rules_version = self.instrument_rules_version, .ticks = @max(intent.limit_price.ticks, self.mark_price_micros) },
                .portfolio_reduce_only = intent.portfolio_reduce_only,
            });
            intent.reservation = assessment.order_reservation;
            intent.portfolio_reduce_only = assessment.portfolio_reduce_only;
            intent.venue_reduce_only = assessment.venue_reduce_only;
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

    fn confirmPendingReplacement(self: *TradingShard, order_id: u64, sequence: u64) !void {
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
            => {
                try self.oms.discardReplacement(order_id);
                return;
            },
            else => return err,
        };
        const intent = qualified.members[0];
        try self.oms.confirmReplacement(order_id, intent.reservation, intent.portfolio_reduce_only, intent.venue_reduce_only);
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
                .portfolio_swap = self.portfolio_position,
                .exchange_swap = self.exchange_position,
                .portfolio_spot = self.spot_portfolio_position,
                .exchange_spot = self.spot_exchange_position,
            },
            .cash = .{
                .portfolio_micros = self.portfolio_cash_micros,
                .treasury_micros = self.treasury_cash_micros,
                .exchange_micros = self.exchange_cash_micros,
            },
            .fees = .{
                .portfolio_micros = self.portfolio_fee_expense_micros,
                .exchange_micros = self.exchange_fee_expense_micros,
                .total_micros = self.total_fees_micros,
            },
            .pnl = .{
                .realized_micros = self.realized_pnl_micros,
                .unrealized_micros = self.unrealized_pnl_micros,
            },
            .ledger = .{
                .transaction_count = self.ledger_transaction_count,
                .portfolio_transfer_count = self.portfolio_transfer_count,
                .portfolio_debits_micros = self.portfolio_ledger_debits_micros,
                .portfolio_credits_micros = self.portfolio_ledger_credits_micros,
                .exchange_debits_micros = self.exchange_ledger_debits_micros,
                .exchange_credits_micros = self.exchange_ledger_credits_micros,
                .projections_complete = self.economic_projections_complete,
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
        const position_quantity = if (self.portfolio_position.quantity < 0)
            try std.math.sub(i64, 0, self.portfolio_position.quantity)
        else
            self.portfolio_position.quantity;
        self.position_margin_requirement_micros = if (self.portfolio_position.quantity == 0)
            0
        else
            try internalMarginMicros(try self.shardNotionalMicros(
                position_quantity,
                self.mark_price_micros,
            ));

        const remaining_quantity = try std.math.sub(
            i64,
            self.order_quantity,
            self.filled_quantity,
        );
        self.open_order_reservation_micros = if (self.order_state == .none or
            self.order_state == .filled or self.order_state == .canceled)
            0
        else
            try self.shardOpenOrderReservationMicros(
                remaining_quantity,
                self.order_limit_price_micros,
            );

        const used = try std.math.add(
            i64,
            self.position_margin_requirement_micros,
            self.open_order_reservation_micros,
        );
        self.risk_lease_remaining_micros = try std.math.sub(i64, self.risk_lease_micros, used);
        if (fail_if_exceeded and self.risk_lease_remaining_micros < 0) return error.RiskLeaseExceeded;
    }

    pub fn assertClosures(self: TradingShard) !void {
        if (self.portfolio_position.quantity != self.exchange_position.quantity or
            self.portfolio_position.open_cost_micros != self.exchange_position.open_cost_micros)
            return error.PositionLayerMismatch;
        if (try std.math.add(
            i64,
            self.portfolio_cash_micros,
            self.treasury_cash_micros,
        ) != self.exchange_cash_micros)
            return error.CashLayerMismatch;
        if (self.portfolio_fee_expense_micros != self.exchange_fee_expense_micros or
            self.total_fees_micros != self.portfolio_fee_expense_micros)
            return error.FeeLayerMismatch;
        if (self.portfolio_ledger_debits_micros != self.portfolio_ledger_credits_micros or
            self.exchange_ledger_debits_micros != self.exchange_ledger_credits_micros)
            return error.LedgerPostingsDoNotClose;
        if (try std.math.add(
            i64,
            self.risk_lease_remaining_micros,
            try std.math.add(
                i64,
                self.open_order_reservation_micros,
                self.position_margin_requirement_micros,
            ),
        ) != self.risk_lease_micros)
            return error.RiskLeaseDoesNotClose;
    }

    fn applyFill(self: *TradingShard, fill: FillProjection) !void {
        const next_filled = try std.math.add(i64, self.filled_quantity, fill.quantity);
        if (fill.quantity <= 0 or fill.price_micros <= 0 or
            next_filled > self.order_quantity)
            return error.InvalidFill;

        self.filled_quantity = next_filled;
        self.syncCompatibilityEconomics();
        self.ledger_transaction_count = try std.math.add(u64, self.ledger_transaction_count, 1);
        try self.recalculateRisk(false);
        try self.assertClosures();
    }

    fn syncCompatibilityEconomics(self: *TradingShard) void {
        const projection = self.economic_projection;
        self.portfolio_position = .{ .quantity = projection.portfolio.swap.quantity, .open_cost_micros = projection.portfolio.swap.open_cost_micros };
        self.exchange_position = .{ .quantity = projection.exchange.swap.quantity, .open_cost_micros = projection.exchange.swap.open_cost_micros };
        self.spot_portfolio_position = .{ .quantity = projection.portfolio.spot.quantity, .open_cost_micros = projection.portfolio.spot.open_cost_micros };
        self.spot_exchange_position = .{ .quantity = projection.exchange.spot.quantity, .open_cost_micros = projection.exchange.spot.open_cost_micros };
        self.portfolio_cash_micros = projection.portfolio.usdt_balance_micros;
        self.treasury_cash_micros = projection.treasury_usdt_micros;
        self.exchange_cash_micros = projection.exchange.usdt_balance_micros;
        self.portfolio_fee_expense_micros = projection.portfolio.fee_micros;
        self.exchange_fee_expense_micros = projection.exchange.fee_micros;
        self.total_fees_micros = projection.portfolio.fee_micros;
        self.realized_pnl_micros = projection.portfolio.realized_pnl_micros;
        self.unrealized_pnl_micros = projection.portfolio.unrealized_pnl_micros;
    }

    fn applyEconomicProjection(self: *TradingShard, event: economics.Event) !bool {
        const changed = try self.economic_projection.applyChanged(event);
        if (changed) self.syncCompatibilityEconomics();
        return changed;
    }

    fn submitOrderIntent(self: *TradingShard, intent: host_gateway.OrderIntent) !?OrderCommand {
        if (intent.side != .buy or intent.order_type != .limit or
            (intent.time_in_force != .good_til_canceled and intent.time_in_force != .immediate_or_cancel) or
            intent.portfolio_reduce_only or
            intent.quantity <= 0 or intent.limit_price_micros <= 0)
            return error.InvalidOrderIntent;
        if (!self.genesisReady()) return error.GenesisIncomplete;
        if (!self.operational_state.effectiveTradingAuthority()) {
            self.last_reject_reason = .market_data_gap;
            try self.trace.append(.strategy_intent_rejected, intent.intent_sequence);
            return null;
        }
        if (intent.strategy_identity != self.strategy_identity or
            intent.config_version != self.strategy_config_version or
            intent.activation_identity != self.strategy_activation_identity or
            intent.portfolio_identity != self.portfolio_identity or
            intent.exchange_account_identity != self.exchange_account_identity or
            intent.instrument_identity != self.instrument_identity)
            return error.IntentAuthorityMismatch;
        if (self.order_state != .none) return error.IntentArrivedWithOpenOrder;
        try self.trace.append(.order_intent, intent.intent_sequence);

        const requested_notional = try self.shardNotionalMicros(
            intent.quantity,
            intent.limit_price_micros,
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
            .operation = .place,
            .instrument = if (self.reservation_model == .cash) spot_instrument else swap_instrument,
            .quantity = intent.quantity,
            .limit_price = .{ .instrument = if (self.reservation_model == .cash) spot_instrument else swap_instrument, .rules_version = self.instrument_rules_version, .ticks = intent.limit_price_micros },
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
                self.last_reject_reason = .global_risk_lease_exceeded;
                try self.trace.append(.risk_rejected_lease, intent.intent_sequence);
                return null;
            },
            else => return err,
        };
        self.last_risk_required_micros = std.math.cast(i64, qualified.members[0].reservation.atoms) orelse return error.Overflow;
        self.last_reject_reason = .none;
        try self.trace.append(.risk_accepted, intent.intent_sequence);
        try self.oms.applyGroup(qualified);
        try self.refreshLayeredReservations();
        const oms_command = self.oms.emitted()[0];
        self.oms.command_count = 0; // Compatibility output below is the single sendable command.
        self.order_state = .pending_submit;
        self.order_counter = oms_command.order_id;
        self.order_id = oms_command.order_id;
        self.order_command_id = oms_command.command_id;
        self.order_quantity = oms_command.quantity;
        self.order_limit_price_micros = std.math.cast(i64, oms_command.limit_price.ticks) orelse return error.Overflow;
        try self.recalculateRisk(true);
        try self.trace.append(.risk_reservation_created, intent.intent_sequence);
        try self.trace.append(.order_command, intent.intent_sequence);
        return .{
            .command_id = self.order_command_id,
            .order_id = self.order_id,
            .quantity = .{ .instrument = oms_command.instrument, .rules_version = self.instrument_rules_version, .lots = intent.quantity },
            .limit_price = oms_command.limit_price,
            .reservation = oms_command.reservation,
            .client_id = client_order_id,
        };
    }

    fn handleCanonical(self: *TradingShard, record: canonical.EventRecord) !?OrderCommand {
        if (record.envelope.event_type != @intFromEnum(canonical.eventType(record.event)))
            return error.CanonicalEventTypeMismatch;
        if (try self.rememberCanonicalIngress(record)) return null;
        const fact_identity = record.envelope.identity.sequence;
        switch (record.event) {
            .core_input => unreachable,
            .order_dispatch_result => |result| {
                const command_id = std.math.cast(u64, result.command) orelse return error.IdentityOutOfRange;
                if (command_id != self.order_command_id or self.order_state != .pending_submit)
                    return error.InvalidDispatchResult;
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
                        self.order_state = .canceled;
                        try self.recalculateRisk(false);
                        try self.trace.append(.order_not_sent, fact_identity);
                    },
                    .submitted => try self.trace.append(.order_dispatched, fact_identity),
                    .unknown => {
                        self.order_state = .unknown;
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
                if (self.instrument_rules_version != 0 and
                    definition.rules_version == self.instrument_rules_version and
                    definition.instrument == self.instrument_identity)
                    try self.canonical_market.activateRules(definition.instrument, definition.rules_version);
                try self.trace.append(.canonical_instrument_definition, fact_identity);
            },
            .l2_book_snapshot => |book_snapshot| {
                try self.canonical_market.apply(record.event);
                self.expected_source_sequence = book_snapshot.sequence + 1;
                self.market_health = .healthy;
                self.bid_price_micros = std.math.cast(i64, book_snapshot.best_bid.ticks) orelse return error.PriceOutOfRange;
                self.ask_1_price_micros = std.math.cast(i64, book_snapshot.best_ask.ticks) orelse return error.PriceOutOfRange;
                self.bid_quantity = if (book_snapshot.best_bid_quantity) |quantity| std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange else 1;
                self.ask_1_quantity = if (book_snapshot.best_ask_quantity) |quantity| std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange else 1;
                self.ask_2_price_micros = if (book_snapshot.next_ask) |price| std.math.cast(i64, price.ticks) orelse return error.PriceOutOfRange else self.ask_1_price_micros;
                self.ask_2_quantity = if (book_snapshot.next_ask_quantity) |quantity| std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange else 1;
                try self.trace.append(.l2_snapshot, fact_identity);
            },
            .l2_book_delta => |delta| {
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
                self.expected_source_sequence = delta.sequence + 1;
                self.bid_price_micros = std.math.cast(i64, delta.best_bid.ticks) orelse return error.PriceOutOfRange;
                self.ask_1_price_micros = std.math.cast(i64, delta.best_ask.ticks) orelse return error.PriceOutOfRange;
                if (delta.best_bid_quantity) |quantity| self.bid_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
                if (delta.best_ask_quantity) |quantity| self.ask_1_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
                if (delta.next_ask) |price| self.ask_2_price_micros = std.math.cast(i64, price.ticks) orelse return error.PriceOutOfRange;
                if (delta.next_ask_quantity) |quantity| self.ask_2_quantity = std.math.cast(i64, quantity.lots) orelse return error.QuantityOutOfRange;
                try self.trace.append(.l2_delta, fact_identity);
                if (self.market_health != .healthy) {
                    self.market_health = .healthy;
                    if (self.operational_state.initialized) try self.applyOperationalGate(.{
                        .gate_identity = market_data_gate_identity,
                        .target_identity = self.operational_state.target_identity,
                        .kind = .self_recovering,
                        .reason = .market_data,
                        .open = true,
                        .continuity_proven = true,
                    });
                    try self.trace.append(.market_healthy, 1);
                }
            },
            .reference_price => |price| {
                try self.canonical_market.apply(record.event);
                if (price.kind == .mark) {
                    self.mark_price_micros = std.math.cast(i64, price.price.ticks) orelse return error.PriceOutOfRange;
                    _ = try self.applyEconomicProjection(.{ .mark_price = self.mark_price_micros });
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
        if (report.exchange_account != self.exchange_account_identity or report.instrument != self.instrument_identity)
            return error.CanonicalScopeMismatch;
        const order_id = std.math.cast(u64, report.order) orelse return error.IdentityOutOfRange;
        const report_id = std.math.cast(u64, report.identity) orelse return error.IdentityOutOfRange;
        if (order_id != self.order_id) return error.UnknownOrder;
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
        self.last_canonical_report = report;
        self.order_state = switch (report.status) {
            .accepted, .amended => .live,
            .partially_filled => .partially_filled,
            .filled => .filled,
            .canceled, .rejected => .canceled,
        };
        if (report.status == .canceled or report.status == .rejected) try self.recalculateRisk(false);
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
        if (fill.exchange_account != self.exchange_account_identity or fill.instrument != self.instrument_identity)
            return error.CanonicalScopeMismatch;
        const order_id = std.math.cast(u64, fill.order) orelse return error.IdentityOutOfRange;
        const fill_id = std.math.cast(u64, fill.identity) orelse return error.IdentityOutOfRange;
        if (order_id != self.order_id) return error.UnknownOrder;
        if (self.last_canonical_fill) |known| if (known.identity == fill.identity) {
            if (!std.meta.eql(known, fill)) return error.ConflictingFillIdentity;
            return;
        };
        const quantity = std.math.cast(i64, fill.quantity.lots) orelse return error.QuantityOutOfRange;
        const price = std.math.cast(i64, fill.price.ticks) orelse return error.PriceOutOfRange;
        const fee = fill.fee orelse canonical.AssetAmount{ .asset = self.economic_projection.settlement_asset, .atoms = 0 };
        const rebate = fill.rebate orelse canonical.AssetAmount{ .asset = self.economic_projection.settlement_asset, .atoms = 0 };
        const economic_instrument = if (self.reservation_model == .cash) spot_instrument else swap_instrument;
        _ = try self.applyEconomicProjection(.{ .fill = .{
            .identity = fill_id,
            .side = switch (fill.side) {
                .buy => .buy,
                .sell => .sell,
            },
            .quantity = .{ .instrument = economic_instrument, .rules_version = fill.quantity.rules_version, .lots = fill.quantity.lots },
            .price = .{ .instrument = economic_instrument, .rules_version = fill.price.rules_version, .ticks = fill.price.ticks },
            .quantity_denominator = self.quantity_denominator,
            .fee = fee,
            .rebate = rebate,
            .portfolio_margin_ppm = self.internal_initial_margin_ppm,
            .exchange_margin_ppm = self.venue_initial_margin_ppm,
        } });
        self.last_canonical_fill = fill;
        try self.applyFill(.{ .fill_id = fill_id, .quantity = quantity, .price_micros = price });
        try self.trace.append(.fill, fact_identity);
        try self.trace.append(.fee_ledger_transaction, fact_identity);
        try self.trace.append(.risk_reservation_rebalanced, fact_identity);
    }

    fn handle(self: *TradingShard, input: InputEvent) !?OrderCommand {
        if (input.version != schema_version) return error.UnsupportedSchema;

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
                if (progress.position_quantity != self.portfolio_position.quantity or
                    progress.open_orders_closed != self.oms.openOrdersClosed() or
                    progress.reconciliation_complete != !self.economic_projection.reconciliation_break or
                    self.portfolio_position.quantity != self.exchange_position.quantity or
                    self.portfolio_cash_micros + self.treasury_cash_micros != self.exchange_cash_micros)
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
                    activation.generation != self.release_generation + 1 or
                    activation.old_release != self.active_release or
                    activation.old_strategy_instance != self.active_strategy_instance or
                    activation.barrier != self.trace.len + 1 or
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
                if (rules.version == 0 or rules.instrument_identity == 0 or
                    rules.quantity_denominator <= 0 or self.instrument_rules_version != 0)
                    return error.InvalidInstrumentRules;
                self.instrument_rules_version = rules.version;
                self.instrument_identity = rules.instrument_identity;
                self.quantity_denominator = rules.quantity_denominator;
                self.reservation_model = rules.reservation_model;
                try self.trace.append(.instrument_rules_activated, input.identity);
            },
            .margin_rules_activated => |rules| {
                if (self.instrument_rules_version == 0 or rules.version == 0 or rules.price_tick_micros <= 0 or
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
                    self.margin_rules_version != 0)
                    return error.InvalidMarginRules;
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
                self.exchange_cash_micros = balance.cash_micros;
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
                    balance.cash_micros != self.exchange_cash_micros or self.opening_balance_observed)
                    return error.InvalidOpeningBalance;
                self.treasury_cash_micros = balance.cash_micros;
                self.economic_projection.treasury_usdt_micros = balance.cash_micros;
                self.portfolio_ledger_debits_micros = balance.cash_micros;
                self.portfolio_ledger_credits_micros = balance.cash_micros;
                self.exchange_ledger_debits_micros = balance.cash_micros;
                self.exchange_ledger_credits_micros = balance.cash_micros;
                self.ledger_transaction_count = 1;
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
                    transfer.amount_micros > self.treasury_cash_micros or self.portfolio_funded)
                    return error.InvalidPortfolioTransfer;
                self.treasury_cash_micros = try std.math.sub(
                    i64,
                    self.treasury_cash_micros,
                    transfer.amount_micros,
                );
                self.portfolio_cash_micros = try std.math.add(
                    i64,
                    self.portfolio_cash_micros,
                    transfer.amount_micros,
                );
                self.economic_projection.treasury_usdt_micros = try std.math.sub(i64, self.economic_projection.treasury_usdt_micros, transfer.amount_micros);
                self.economic_projection.portfolio.usdt_balance_micros = try std.math.add(i64, self.economic_projection.portfolio.usdt_balance_micros, transfer.amount_micros);
                self.portfolio_ledger_debits_micros = try std.math.add(
                    i64,
                    self.portfolio_ledger_debits_micros,
                    transfer.amount_micros,
                );
                self.portfolio_ledger_credits_micros = try std.math.add(
                    i64,
                    self.portfolio_ledger_credits_micros,
                    transfer.amount_micros,
                );
                self.portfolio_transfer_count = 1;
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
            .primary_lease_granted => |lease| {
                if (!self.strategy_active or lease.fencing_token == 0 or self.fencing_token != 0)
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
                self.risk_lease_remaining_micros = lease.amount_micros;
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
                try self.assertClosures();
                try self.trace.append(.risk_lease_granted, input.identity);
            },
            .mark_price => |price| {
                if (price <= 0) return error.InvalidMarkPrice;
                self.mark_price_micros = price;
                _ = try self.applyEconomicProjection(.{ .mark_price = price });
                try self.recalculateRisk(false);
                try self.assertClosures();
                try self.trace.append(.mark_price, input.identity);
                if (self.order_state == .filled) self.economic_projections_complete = true;
            },
            .timer => |request| {
                if (request.quantity <= 0) return error.InvalidOrderQuantity;
                try self.trace.append(.timer, input.identity);
                self.timer_pending = false;
                self.strategy_cursor = self.trace.len;
                self.strategy_decision_count += 1;
                return self.submitOrderIntent(.{
                    .strategy_identity = self.strategy_identity,
                    .intent_sequence = 1,
                    .strategy_cursor = self.strategy_cursor,
                    .config_version = self.strategy_config_version,
                    .activation_identity = self.strategy_activation_identity,
                    .portfolio_identity = self.portfolio_identity,
                    .exchange_account_identity = self.exchange_account_identity,
                    .instrument_identity = self.instrument_identity,
                    .side = .buy,
                    .order_type = .limit,
                    .time_in_force = .good_til_canceled,
                    .portfolio_reduce_only = false,
                    .quantity = request.quantity,
                    .limit_price_micros = order_limit_price,
                });
            },
            .external_order_intent => |intent| {
                if (!self.strategy_active or intent.strategy_cursor <= self.strategy_cursor)
                    return error.InvalidStrategyCursor;
                self.strategy_cursor = intent.strategy_cursor;
                self.strategy_decision_count += 1;
                return self.submitOrderIntent(intent);
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
                try candidate.oms.applyGroup(qualified);
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
                try self.confirmPendingReplacement(report.order_id, report.report_id);
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
                try self.confirmPendingReplacement(result.order_id, result.reconciliation_id);
                try self.refreshLayeredReservations();
                try self.trace.append(.oms_reconciliation_result, result.reconciliation_id);
            },
            .economic_fill => |fill| {
                const order = self.oms.orderById(fill.order_id) orelse return error.UnknownOrder;
                const instrument = if (order.instrument == spot_instrument) spot_instrument else swap_instrument;
                const changed = try self.applyEconomicProjection(.{ .fill = .{
                    .identity = fill.fill_id,
                    .side = if (order.side == .buy) .buy else .sell,
                    .quantity = .{ .instrument = instrument, .rules_version = self.instrument_rules_version, .lots = fill.quantity },
                    .price = .{ .instrument = instrument, .rules_version = self.instrument_rules_version, .ticks = fill.price_micros },
                    .quantity_denominator = self.quantity_denominator,
                    .fee = .{ .asset = self.economic_projection.settlement_asset, .atoms = fill.fee_micros },
                    .rebate = .{ .asset = self.economic_projection.settlement_asset, .atoms = fill.rebate_micros },
                    .portfolio_margin_ppm = self.internal_initial_margin_ppm,
                    .exchange_margin_ppm = self.venue_initial_margin_ppm,
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
                const changed = try self.applyEconomicProjection(.{ .venue_forced_execution = .{
                    .identity = forced.execution_id,
                    .side = if (forced.side == .buy) .buy else .sell,
                    .quantity = .{ .instrument = swap_instrument, .rules_version = self.instrument_rules_version, .lots = forced.quantity },
                    .price = .{ .instrument = swap_instrument, .rules_version = self.instrument_rules_version, .ticks = forced.price_micros },
                    .quantity_denominator = self.quantity_denominator,
                    .fee = .{ .asset = self.economic_projection.settlement_asset, .atoms = forced.fee_micros },
                    .penalty = .{ .asset = self.economic_projection.settlement_asset, .atoms = forced.penalty_micros },
                    .portfolio_margin_ppm = self.internal_initial_margin_ppm,
                    .exchange_margin_ppm = self.venue_initial_margin_ppm,
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
    zeroUnused(Fact, shard.trace.events[shard.trace.len..]);
    zeroUnused(oms_module.Order, shard.oms.orders[shard.oms.order_count..]);
    shard.oms.command_count = 0;
    zeroUnused(oms_module.Command, shard.oms.commands[0..]);
    zeroUnused(oms_module.Command, shard.oms.command_history[shard.oms.command_history_count..]);
    zeroUnused(oms_module.ExecutionReport, shard.oms.report_history[shard.oms.report_history_count..]);
    zeroUnused(oms_module.ReconciliationResult, shard.oms.reconciliation_history[shard.oms.reconciliation_history_count..]);
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
        .event_type = .core_input,
        .raw_digest = @splat(0),
        .payload_digest = @splat(0),
    };
}

fn validateSnapshotState(shard: *const TradingShard) !void {
    if (shard.trace.len > shard.trace.events.len or
        shard.oms.order_count > oms_module.max_orders or
        shard.oms.command_count > shard.oms.commands.len or
        shard.oms.command_history_count > shard.oms.command_history.len or
        shard.oms.report_history_count > shard.oms.report_history.len or
        shard.oms.reconciliation_history_count > shard.oms.reconciliation_history.len or
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
    for (shard.oms.orders[0..shard.oms.order_count], 0..) |order, index| {
        if (order.id == 0) return error.InvalidSnapshotState;
        for (shard.oms.orders[0..index]) |previous|
            if (previous.id == order.id) return error.InvalidSnapshotState;
    }
    for (shard.economic_projection.ledger[0..shard.economic_projection.ledger_count]) |transaction|
        if (transaction.posting_count > transaction.postings.len) return error.InvalidSnapshotState;
}

/// Atomically applies one canonical EventRecord and appends every resulting
/// fact to the stable journal.
pub fn applyStable(
    shard: *TradingShard,
    decision_journal: *journal.Journal,
    input: canonical.EventRecord,
) !?OrderCommand {
    var candidate_shard = shard.*;
    const result = try candidate_shard.apply(input);
    if (result.facts.len == 0) return error.InputProducedNoFact;
    var canonical_bytes: [canonical_event_codec.max_encoded_len]u8 = undefined;
    const is_core = std.meta.activeTag(input.event) == .core_input;
    const encoded_input = if (is_core)
        input.event.core_input.slice()
    else
        try canonical_event_codec.encode(&canonical_bytes, input);
    const times = input.envelope.times;
    const time_presence: journal.TimePresence = .{
        .source = times.source_utc_ns != null,
        .receive = times.receive_utc_ns != null,
        .monotonic = times.monotonic_ns != null,
        .wall = times.audit_utc_ns != null,
    };

    const checkpoint = decision_journal.checkpoint();
    errdefer decision_journal.restore(checkpoint);
    for (result.facts, 0..) |event, index| {
        var identity_bytes: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &identity_bytes, event.identity, .little);
        try decision_journal.append(.{
            .type_id = @intFromEnum(event.kind),
            .schema_version = schema_version,
            .flags = if (index == 0) if (is_core) journal.input_flag else journal.canonical_input_flag else 0,
            .sequence = event.sequence,
            .source_time = times.source_utc_ns orelse 0,
            .receive_time = times.receive_utc_ns orelse 0,
            .monotonic_time = times.monotonic_ns orelse 0,
            .wall_time = times.audit_utc_ns orelse 0,
            .time_presence = time_presence,
            .payload = if (index == 0)
                encoded_input
            else
                &identity_bytes,
        });
    }
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

pub fn stateDigest(shard: TradingShard) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("StateDigestV3\x00");
    digestInt(&hasher, u16, schema_version);
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
    digestInt(&hasher, u128, shard.strategy_activation_identity);
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
    }
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
    digestInt(&hasher, u64, shard.order_counter);
    digestBool(&hasher, shard.timer_pending);
    digestInt(&hasher, u8, @intFromEnum(shard.order_state));
    digestInt(&hasher, u64, shard.order_id);
    digestInt(&hasher, u64, shard.order_command_id);
    digestInt(&hasher, i64, shard.order_quantity);
    digestInt(&hasher, i64, shard.order_limit_price_micros);
    digestInt(&hasher, u64, shard.dispatch_attempt_count);
    digestInt(&hasher, u8, @intFromEnum(shard.last_reject_reason));
    digestInt(&hasher, i64, shard.last_risk_required_micros);
    digestInt(&hasher, u8, shard.last_risk_tier);
    digestBool(&hasher, shard.order_id != 0);
    if (shard.order_id != 0) {
        digestInt(&hasher, u16, client_order_id.len);
        hasher.update(client_order_id);
    }
    digestInt(&hasher, i64, shard.filled_quantity);
    digestInt(&hasher, i64, shard.mark_price_micros);
    digestInt(&hasher, i64, shard.portfolio_position.quantity);
    digestInt(&hasher, i64, shard.portfolio_position.open_cost_micros);
    digestInt(&hasher, i64, shard.exchange_position.quantity);
    digestInt(&hasher, i64, shard.exchange_position.open_cost_micros);
    digestInt(&hasher, i64, shard.spot_portfolio_position.quantity);
    digestInt(&hasher, i64, shard.spot_portfolio_position.open_cost_micros);
    digestInt(&hasher, i64, shard.spot_exchange_position.quantity);
    digestInt(&hasher, i64, shard.spot_exchange_position.open_cost_micros);
    digestInt(&hasher, i64, shard.portfolio_cash_micros);
    digestInt(&hasher, i64, shard.treasury_cash_micros);
    digestInt(&hasher, i64, shard.exchange_cash_micros);
    digestInt(&hasher, i64, shard.portfolio_fee_expense_micros);
    digestInt(&hasher, i64, shard.exchange_fee_expense_micros);
    digestInt(&hasher, i64, shard.total_fees_micros);
    digestInt(&hasher, i64, shard.realized_pnl_micros);
    digestInt(&hasher, i64, shard.unrealized_pnl_micros);
    digestInt(&hasher, i64, shard.open_order_reservation_micros);
    digestInt(&hasher, i64, shard.position_margin_requirement_micros);
    digestInt(&hasher, i64, shard.risk_lease_micros);
    digestInt(&hasher, i64, shard.risk_lease_remaining_micros);
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
    digestInt(&hasher, u64, shard.ledger_transaction_count);
    digestInt(&hasher, u64, shard.portfolio_transfer_count);
    digestInt(&hasher, i64, shard.portfolio_ledger_debits_micros);
    digestInt(&hasher, i64, shard.portfolio_ledger_credits_micros);
    digestInt(&hasher, i64, shard.exchange_ledger_debits_micros);
    digestInt(&hasher, i64, shard.exchange_ledger_credits_micros);
    digestBool(&hasher, shard.economic_projections_complete);
    return hasher.finalResult();
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
    input: InputEvent,
    is_input: bool,
) !void {
    if (record.schema_version != schema_version) return error.UnsupportedSchema;
    const kind = std.enums.fromInt(EventKind, record.type_id) orelse
        return error.UnknownEventType;
    if (record.sequence != expected.sequence or kind != expected.kind or
        (!is_input and try eventIdentity(record.payload) != expected.identity))
        return error.ReplayFactMismatch;
    if (record.source_time != input.source_time or
        record.receive_time != input.receive_time or
        record.monotonic_time != input.monotonic_time or
        record.wall_time != input.wall_time or
        @as(u8, @bitCast(record.time_presence)) != @as(u8, @bitCast(input.time_presence)))
        return error.ReplayTimeMismatch;
    if (is_input) {
        if (record.flags != journal.input_flag) return error.InputFlagMissing;
    } else if (record.flags != 0 or record.payload.len != @sizeOf(u64)) {
        return error.InvalidDerivedFactRecord;
    }
}

fn validateCanonicalReplayRecord(
    record: journal.Record,
    expected: Fact,
    input: canonical.EventRecord,
    is_input: bool,
) !void {
    if (record.schema_version != schema_version) return error.UnsupportedSchema;
    const kind = std.enums.fromInt(EventKind, record.type_id) orelse return error.UnknownEventType;
    if (record.sequence != expected.sequence or kind != expected.kind) return error.ReplayFactMismatch;
    if (!is_input and try eventIdentity(record.payload) != expected.identity) return error.ReplayFactMismatch;
    const times = input.envelope.times;
    const presence: journal.TimePresence = .{
        .source = times.source_utc_ns != null,
        .receive = times.receive_utc_ns != null,
        .monotonic = times.monotonic_ns != null,
        .wall = times.audit_utc_ns != null,
    };
    if (record.source_time != (times.source_utc_ns orelse 0) or
        record.receive_time != (times.receive_utc_ns orelse 0) or
        record.monotonic_time != (times.monotonic_ns orelse 0) or
        record.wall_time != (times.audit_utc_ns orelse 0) or
        @as(u8, @bitCast(record.time_presence)) != @as(u8, @bitCast(presence)))
        return error.ReplayTimeMismatch;
    if (is_input) {
        if (record.flags != journal.canonical_input_flag) return error.InputFlagMissing;
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

/// Replays core and venue canonical inputs through the same `apply` seam from
/// an explicit recovery point.
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
        if (first_record.flags != journal.input_flag and first_record.flags != journal.canonical_input_flag)
            return error.OrphanDerivedFact;
        var candidate = shard;
        const core_input: ?InputEvent = if (first_record.flags == journal.input_flag) try decodeInput(first_record) else null;
        const canonical_input: ?canonical.EventRecord = if (first_record.flags == journal.canonical_input_flag)
            try canonical_event_codec.decode(first_record.payload)
        else
            null;
        const before = candidate.trace.len;
        if (core_input) |input| {
            _ = try candidate.apply(try coreRecordFromInput(input));
        } else {
            _ = try candidate.apply(canonical_input.?);
        }
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
            if (core_input) |input|
                try validateReplayRecord(record, expected, input, index == 0)
            else
                try validateCanonicalReplayRecord(record, expected, canonical_input.?, index == 0);
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
