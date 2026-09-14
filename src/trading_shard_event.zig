//! Versioned TradingShard input schema and stable journal codec.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const economics_module = @import("economics.zig");
const host_gateway = @import("strategy_host_gateway.zig");
const journal = @import("journal.zig");
const oms_module = @import("oms.zig");
const operational = @import("operational.zig");
const production_contract = @import("production_contract.zig");

pub const schema_version: u16 = production_contract.journal_schema_version;

pub const EventKind = enum(u16) {
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
};

pub const Fact = struct {
    sequence: u64,
    kind: EventKind,
    identity: u64,
};

pub const Trace = struct {
    events: [64]Fact = undefined,
    len: usize = 0,

    pub fn append(self: *Trace, kind: EventKind, identity: u64) !void {
        if (self.len == self.events.len) return error.TraceFull;
        self.events[self.len] = .{
            .sequence = self.len + 1,
            .kind = kind,
            .identity = identity,
        };
        self.len += 1;
    }
};

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
    price_micros: i64,
    fee_micros: i64 = 0,
    rebate_micros: i64 = 0,
};

pub const FundingSettlement = struct { settlement_id: u64, amount_micros: i64 };
pub const VenueForcedExecution = struct {
    execution_id: u64,
    side: oms_module.Side,
    quantity: i64,
    price_micros: i64,
    fee_micros: i64 = 0,
    penalty_micros: i64 = 0,
};
pub const EconomicAccountSnapshot = struct {
    snapshot_id: u64,
    usdt_balance_micros: i64,
    spot_asset_quantity: i64,
    swap_position_quantity: i64,
    margin_micros: i64,
};

pub const EconomicSummary = struct {
    portfolio: economics_module.Layer,
    exchange: economics_module.Layer,
    treasury_usdt_micros: i64,
    suspense_usdt_micros: i64,
    ledger_transactions: u8,
    reconciliation_break: bool,
};

pub const PayloadTag = enum(u16) {
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
};

pub const ReservationModel = enum(u8) { leveraged, cash };
pub const Product = canonical.Product;

pub const InstrumentRules = struct {
    version: u32,
    instrument_identity: u128,
    quantity_denominator: i64,
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
    instrument: canonical.InstrumentIdentity = 0,
    price_tick_micros: i64 = 1,
    venue_initial_margin_ppm: i64 = 20_000,
    internal_initial_margin_ppm: i64 = 22_000,
    internal_maintenance_margin_ppm: i64 = 11_000,
    fee_ppm: i64 = 750,
    opening_buffer_micros: i64 = 0,
    opening_buffer_bps: i64 = 0,
    opening_liquidation_distance_ticks: i64 = 0,
    warning_buffer_micros: i64 = 0,
    kill_buffer_micros: i64 = 0,
    warning_buffer_bps: i64 = 0,
    kill_buffer_bps: i64 = 0,
    warning_liquidation_distance_ticks: i64 = 0,
    kill_liquidation_distance_ticks: i64 = 0,
};
pub const AccountConfiguration = struct { exchange_account_identity: u128 };
pub const Balance = struct { cash_micros: i64 };
pub const VirtualPortfolioActivation = struct { portfolio_identity: u128 };
pub const PortfolioTransfer = struct { amount_micros: i64 };
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
    activation_barrier: u64,
    state_digest: [32]u8,
};
pub const PrimaryLease = struct { fencing_token: u64 };
pub const MarkPrice = struct { instrument: canonical.InstrumentIdentity, price_micros: i64 };
pub const RiskLease = struct {
    lease_identity: u64 = 0,
    version: u64 = 1,
    valid_through_barrier: u64 = std.math.maxInt(u64),
    open: bool = true,
    amount_micros: i64,
    strategy_limit_micros: i64 = 0,
    portfolio_limit_micros: i64 = 0,
    exchange_account_limit_micros: i64 = 0,
    global_limit_micros: i64 = 0,
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

pub const CorePayload = union(PayloadTag) {
    instrument_rules_activated: InstrumentRules,
    margin_rules_activated: MarginRules,
    account_configuration: AccountConfiguration,
    exchange_balance: Balance,
    exchange_positions,
    opening_balance: Balance,
    virtual_portfolio_activated: VirtualPortfolioActivation,
    portfolio_transfer: PortfolioTransfer,
    strategy_activated: StrategyActivation,
    host_activated: HostActivated,
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
};

/// Typed core-originated event carried by the authoritative CanonicalEvent.
pub const CoreEvent = struct {
    identity: u64,
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
    switch (input.payload) {
        .instrument_rules_activated => |value| {
            try encoded.put(u32, value.version);
            try encoded.put(u128, value.instrument_identity);
            try encoded.put(i64, value.quantity_denominator);
            try encoded.put(u8, @intFromEnum(value.reservation_model));
            try encoded.put(u8, @intFromEnum(value.product));
            try encoded.put(u64, value.venue);
            try encoded.put(u64, value.settlement_asset);
            try encoded.put(u64, value.base_asset);
        },
        .margin_rules_activated => |value| {
            try encoded.put(u32, value.version);
            try encoded.put(u128, value.instrument);
            try encoded.put(i64, value.price_tick_micros);
            try encoded.put(i64, value.venue_initial_margin_ppm);
            try encoded.put(i64, value.internal_initial_margin_ppm);
            try encoded.put(i64, value.internal_maintenance_margin_ppm);
            try encoded.put(i64, value.fee_ppm);
            try encoded.put(i64, value.opening_buffer_micros);
            try encoded.put(i64, value.opening_buffer_bps);
            try encoded.put(i64, value.opening_liquidation_distance_ticks);
            try encoded.put(i64, value.warning_buffer_micros);
            try encoded.put(i64, value.kill_buffer_micros);
            try encoded.put(i64, value.warning_buffer_bps);
            try encoded.put(i64, value.kill_buffer_bps);
            try encoded.put(i64, value.warning_liquidation_distance_ticks);
            try encoded.put(i64, value.kill_liquidation_distance_ticks);
        },
        .account_configuration => |value| try encoded.put(u128, value.exchange_account_identity),
        .exchange_balance, .opening_balance => |value| try encoded.put(i64, value.cash_micros),
        .virtual_portfolio_activated => |value| try encoded.put(u128, value.portfolio_identity),
        .portfolio_transfer => |value| try encoded.put(i64, value.amount_micros),
        .strategy_activated => |value| {
            try encoded.put(u128, value.strategy_identity);
            try encoded.put(u64, value.config_version);
            try encoded.put(u128, value.activation_identity);
        },
        .host_activated => |value| {
            try encoded.put(u128, value.strategy_identity);
            try encoded.put(u64, value.config_version);
            try encoded.put(u128, value.activation_identity);
            try encoded.put(u64, value.activation_barrier);
            for (value.state_digest) |byte| try encoded.put(u8, byte);
        },
        .primary_lease_granted => |value| try encoded.put(u64, value.fencing_token),
        .risk_lease_granted => |value| {
            try encoded.put(u64, value.lease_identity);
            try encoded.put(u64, value.version);
            try encoded.put(u64, value.valid_through_barrier);
            try encoded.put(u8, @intFromBool(value.open));
            try encoded.put(i64, value.amount_micros);
            try encoded.put(i64, value.strategy_limit_micros);
            try encoded.put(i64, value.portfolio_limit_micros);
            try encoded.put(i64, value.exchange_account_limit_micros);
            try encoded.put(i64, value.global_limit_micros);
        },
        .mark_price => |value| {
            try encoded.put(u128, value.instrument);
            try encoded.put(i64, value.price_micros);
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
            try encoded.put(u64, value.first_intent_sequence);
            try encoded.put(u8, @intFromEnum(value.policy));
            try encoded.put(u8, value.count);
            for (value.members[0..value.count]) |member| {
                try encoded.put(u64, member.intent_sequence);
                try encoded.put(u128, member.strategy_instance);
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
            try encoded.put(i64, value.price_micros);
            try encoded.put(i64, value.fee_micros);
            try encoded.put(i64, value.rebate_micros);
        },
        .funding_settlement => |value| {
            try encoded.put(u64, value.settlement_id);
            try encoded.put(i64, value.amount_micros);
        },
        .venue_forced_execution => |value| {
            try encoded.put(u64, value.execution_id);
            try encoded.put(u8, @intFromEnum(value.side));
            try encoded.put(i64, value.quantity);
            try encoded.put(i64, value.price_micros);
            try encoded.put(i64, value.fee_micros);
            try encoded.put(i64, value.penalty_micros);
        },
        .economic_account_snapshot => |value| {
            try encoded.put(u64, value.snapshot_id);
            try encoded.put(i64, value.usdt_balance_micros);
            try encoded.put(i64, value.spot_asset_quantity);
            try encoded.put(i64, value.swap_position_quantity);
            try encoded.put(i64, value.margin_micros);
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
    const payload: CorePayload = switch (tag) {
        .instrument_rules_activated => .{ .instrument_rules_activated = .{
            .version = try readInputValue(u32, record.payload, &offset),
            .instrument_identity = try readInputValue(u128, record.payload, &offset),
            .quantity_denominator = try readInputValue(i64, record.payload, &offset),
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
            .version = try readInputValue(u32, record.payload, &offset),
            .instrument = try readInputValue(u128, record.payload, &offset),
            .price_tick_micros = try readInputValue(i64, record.payload, &offset),
            .venue_initial_margin_ppm = try readInputValue(i64, record.payload, &offset),
            .internal_initial_margin_ppm = try readInputValue(i64, record.payload, &offset),
            .internal_maintenance_margin_ppm = try readInputValue(i64, record.payload, &offset),
            .fee_ppm = try readInputValue(i64, record.payload, &offset),
            .opening_buffer_micros = try readInputValue(i64, record.payload, &offset),
            .opening_buffer_bps = try readInputValue(i64, record.payload, &offset),
            .opening_liquidation_distance_ticks = try readInputValue(i64, record.payload, &offset),
            .warning_buffer_micros = try readInputValue(i64, record.payload, &offset),
            .kill_buffer_micros = try readInputValue(i64, record.payload, &offset),
            .warning_buffer_bps = try readInputValue(i64, record.payload, &offset),
            .kill_buffer_bps = try readInputValue(i64, record.payload, &offset),
            .warning_liquidation_distance_ticks = try readInputValue(i64, record.payload, &offset),
            .kill_liquidation_distance_ticks = try readInputValue(i64, record.payload, &offset),
        } },
        .account_configuration => .{ .account_configuration = .{
            .exchange_account_identity = try readInputValue(u128, record.payload, &offset),
        } },
        .exchange_balance => .{ .exchange_balance = .{
            .cash_micros = try readInputValue(i64, record.payload, &offset),
        } },
        .exchange_positions => .exchange_positions,
        .opening_balance => .{ .opening_balance = .{
            .cash_micros = try readInputValue(i64, record.payload, &offset),
        } },
        .virtual_portfolio_activated => .{ .virtual_portfolio_activated = .{
            .portfolio_identity = try readInputValue(u128, record.payload, &offset),
        } },
        .portfolio_transfer => .{ .portfolio_transfer = .{
            .amount_micros = try readInputValue(i64, record.payload, &offset),
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
            .activation_barrier = try readInputValue(u64, record.payload, &offset),
            .state_digest = blk: {
                var digest: [32]u8 = undefined;
                for (&digest) |*byte| byte.* = try readInputValue(u8, record.payload, &offset);
                break :blk digest;
            },
        } },
        .primary_lease_granted => .{ .primary_lease_granted = .{
            .fencing_token = try readInputValue(u64, record.payload, &offset),
        } },
        .risk_lease_granted => .{ .risk_lease_granted = .{
            .lease_identity = try readInputValue(u64, record.payload, &offset),
            .version = try readInputValue(u64, record.payload, &offset),
            .valid_through_barrier = try readInputValue(u64, record.payload, &offset),
            .open = try readInputBool(record.payload, &offset),
            .amount_micros = try readInputValue(i64, record.payload, &offset),
            .strategy_limit_micros = try readInputValue(i64, record.payload, &offset),
            .portfolio_limit_micros = try readInputValue(i64, record.payload, &offset),
            .exchange_account_limit_micros = try readInputValue(i64, record.payload, &offset),
            .global_limit_micros = try readInputValue(i64, record.payload, &offset),
        } },
        .mark_price => .{ .mark_price = .{
            .instrument = try readInputValue(u128, record.payload, &offset),
            .price_micros = try readInputValue(i64, record.payload, &offset),
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
            .price_micros = try readInputValue(i64, record.payload, &offset),
            .fee_micros = try readInputValue(i64, record.payload, &offset),
            .rebate_micros = try readInputValue(i64, record.payload, &offset),
        } },
        .funding_settlement => .{ .funding_settlement = .{
            .settlement_id = try readInputValue(u64, record.payload, &offset),
            .amount_micros = try readInputValue(i64, record.payload, &offset),
        } },
        .venue_forced_execution => .{ .venue_forced_execution = .{
            .execution_id = try readInputValue(u64, record.payload, &offset),
            .side = std.enums.fromInt(oms_module.Side, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownOmsSide,
            .quantity = try readInputValue(i64, record.payload, &offset),
            .price_micros = try readInputValue(i64, record.payload, &offset),
            .fee_micros = try readInputValue(i64, record.payload, &offset),
            .penalty_micros = try readInputValue(i64, record.payload, &offset),
        } },
        .economic_account_snapshot => .{ .economic_account_snapshot = .{
            .snapshot_id = try readInputValue(u64, record.payload, &offset),
            .usdt_balance_micros = try readInputValue(i64, record.payload, &offset),
            .spot_asset_quantity = try readInputValue(i64, record.payload, &offset),
            .swap_position_quantity = try readInputValue(i64, record.payload, &offset),
            .margin_micros = try readInputValue(i64, record.payload, &offset),
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
    };
    if (offset != record.payload.len) return error.TrailingInputPayload;
    return .{
        .identity = identity,
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
