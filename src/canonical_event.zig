//! Stable, Venue-neutral values that cross the Adapter seams.
//!
//! These values deliberately contain no transport object, Venue field name, or
//! mutable TradingShard state. Venue implementations translate into this
//! module; TradingShard adoption is an incremental, provisional-schema change.

const std = @import("std");

pub const VenueIdentity = u64;
pub const AssetIdentity = u64;
pub const ExchangeAccountIdentity = u128;
pub const InstrumentIdentity = u128;
pub const OrderIdentity = u128;
pub const ClientOrderId = OpaqueRef(64);
pub const VenueOrderRef = VenueScopedRef(64);
pub const VenueTradeRef = VenueScopedRef(64);
pub const AdapterSessionIdentity = u128;
pub const BootstrapSnapshotIdentity = u128;
pub const StreamIdentity = u128;
pub const StreamSequence = u64;
pub const VenueSourceStreamIdentity = u128;
pub const VenueSourceSequence = u64;
pub const SourceFactIdentity = u128;

pub const EventIdentity = struct {
    stream: StreamIdentity,
    sequence: StreamSequence,
};

pub fn OpaqueRef(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: std.math.IntFittingRange(0, capacity) = 0,

        pub fn init(value: []const u8) !@This() {
            if (value.len == 0 or value.len > capacity) return error.InvalidOpaqueRef;
            var result: @This() = .{ .len = @intCast(value.len) };
            @memcpy(result.bytes[0..value.len], value);
            return result;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub fn VenueScopedRef(comptime capacity: usize) type {
    return struct {
        venue: VenueIdentity,
        value: OpaqueRef(capacity),

        pub fn init(venue: VenueIdentity, value: []const u8) !@This() {
            return .{ .venue = venue, .value = try OpaqueRef(capacity).init(value) };
        }
    };
}

pub const Decimal = struct {
    coefficient: i128,
    scale: u8,

    /// Parses ordinary Venue decimal text without float conversion or rounding.
    pub fn parse(text: []const u8) !Decimal {
        if (text.len == 0) return error.InvalidDecimal;
        var cursor: usize = 0;
        var negative = false;
        if (text[cursor] == '-' or text[cursor] == '+') {
            negative = text[cursor] == '-';
            cursor += 1;
            if (cursor == text.len) return error.InvalidDecimal;
        }

        var coefficient: i128 = 0;
        var scale: u8 = 0;
        var fractional = false;
        var digit_count: usize = 0;
        while (cursor < text.len) : (cursor += 1) {
            const byte = text[cursor];
            if (byte == '.') {
                if (fractional) return error.InvalidDecimal;
                fractional = true;
                continue;
            }
            if (byte < '0' or byte > '9') return error.InvalidDecimal;
            coefficient = std.math.mul(i128, coefficient, 10) catch return error.DecimalOverflow;
            coefficient = std.math.add(i128, coefficient, byte - '0') catch return error.DecimalOverflow;
            if (fractional) scale = std.math.add(u8, scale, 1) catch return error.DecimalOverflow;
            digit_count += 1;
        }
        if (digit_count == 0) return error.InvalidDecimal;
        return .{ .coefficient = if (negative) -coefficient else coefficient, .scale = scale };
    }

    /// Converts only exactly representable decimals to active-rule atomic units.
    pub fn exactAtoms(self: Decimal, atomic_scale: u8) !i128 {
        if (self.scale == atomic_scale) return self.coefficient;
        if (self.scale < atomic_scale) {
            const multiplier = try pow10(atomic_scale - self.scale);
            return std.math.mul(i128, self.coefficient, multiplier) catch error.DecimalOverflow;
        }
        const divisor = try pow10(self.scale - atomic_scale);
        if (@rem(self.coefficient, divisor) != 0) return error.InexactDecimal;
        return @divTrunc(self.coefficient, divisor);
    }
};

fn pow10(exponent: u8) !i128 {
    var result: i128 = 1;
    var index: u8 = 0;
    while (index < exponent) : (index += 1)
        result = std.math.mul(i128, result, 10) catch return error.DecimalOverflow;
    return result;
}

pub const AssetAmount = struct {
    asset: AssetIdentity,
    atoms: i128,

    pub fn fromDecimal(asset: AssetIdentity, value: Decimal, atomic_scale: u8) !AssetAmount {
        return .{ .asset = asset, .atoms = try value.exactAtoms(atomic_scale) };
    }
};
pub const InstrumentPrice = struct {
    instrument: InstrumentIdentity,
    rules_version: u64,
    ticks: i128,

    pub fn fromDecimal(instrument: InstrumentIdentity, rules_version: u64, value: Decimal, tick_scale: u8, tick_atoms: i128) !InstrumentPrice {
        const atoms = try value.exactAtoms(tick_scale);
        if (tick_atoms <= 0 or @rem(atoms, tick_atoms) != 0) return error.InexactInstrumentPrice;
        return .{ .instrument = instrument, .rules_version = rules_version, .ticks = @divTrunc(atoms, tick_atoms) };
    }
};
pub const InstrumentQuantity = struct {
    instrument: InstrumentIdentity,
    rules_version: u64,
    lots: i128,

    pub fn fromDecimal(instrument: InstrumentIdentity, rules_version: u64, value: Decimal, lot_scale: u8, lot_atoms: i128) !InstrumentQuantity {
        const atoms = try value.exactAtoms(lot_scale);
        if (lot_atoms <= 0 or @rem(atoms, lot_atoms) != 0) return error.InexactInstrumentQuantity;
        return .{ .instrument = instrument, .rules_version = rules_version, .lots = @divTrunc(atoms, lot_atoms) };
    }
};

pub const RawEvidenceRef = struct {
    stream: VenueSourceStreamIdentity,
    sequence: VenueSourceSequence,
    digest: [32]u8,
};

pub const Times = struct {
    source_utc_ns: ?u64 = null,
    receive_utc_ns: ?u64 = null,
    monotonic_ns: ?u64 = null,
    audit_utc_ns: ?u64 = null,
};

pub const CanonicalEventScope = enum(u8) { venue, account, instrument, asset };

pub const EventEnvelope = struct {
    event_type: u32,
    schema_version: u16,
    identity: EventIdentity,
    source_fact_identity: SourceFactIdentity,
    scope: CanonicalEventScope,
    venue: VenueIdentity,
    exchange_account: ?ExchangeAccountIdentity = null,
    instrument: ?InstrumentIdentity = null,
    asset: ?AssetIdentity = null,
    source_stream: VenueSourceStreamIdentity,
    source_sequence: VenueSourceSequence,
    source_previous_sequence: ?VenueSourceSequence = null,
    source_cross_sequence: ?VenueSourceSequence = null,
    adapter_session: ?AdapterSessionIdentity = null,
    bootstrap_snapshot: ?BootstrapSnapshotIdentity = null,
    times: Times,
    raw_evidence: RawEvidenceRef,
};

pub const CanonicalRejectReason = enum(u8) {
    capability_unsupported,
    unsupported_instrument,
    unsupported_value,
    stale_version,
    deadline_expired,
    adapter_backpressure,
    venue_unavailable,
    other_venue_reject,
};

pub const DispatchState = enum(u8) { not_sent, submitted, unknown };
pub const OrderOperation = enum(u8) { place, amend, cancel };
pub const OrderSide = enum(u8) { buy, sell };
pub const OrderType = enum(u8) { market, limit, post_only, fok, ioc };
pub const LiquidityRole = enum(u8) { maker, taker };
pub const ExecutionReportStatus = enum(u8) { accepted, partially_filled, filled, canceled, rejected, amended };

pub const OrderCommand = struct {
    identity: OrderIdentity,
    exchange_account: ExchangeAccountIdentity,
    instrument: InstrumentIdentity,
    client_order_id: ClientOrderId,
    capability_version: u64,
    rules_version: u64,
    config_version: u64,
    adapter_session: AdapterSessionIdentity,
    dispatch_deadline_monotonic_ns: u64,
    operation: OrderOperation = .place,
    side: OrderSide = .buy,
    revision: u32 = 1,
    order_type: OrderType = .limit,
    time_in_force: TimeInForce = .good_til_canceled,
    portfolio_reduce_only: bool = false,
    venue_reduce_only: bool = false,
    venue_order: ?VenueOrderRef = null,
    quantity: ?InstrumentQuantity = null,
    limit_price: ?InstrumentPrice = null,
    market_protection_price: ?InstrumentPrice = null,
    fee_asset: ?AssetIdentity = null,
    fee_atoms: i128 = 0,
    rebate_asset: ?AssetIdentity = null,
    rebate_atoms: i128 = 0,
    realized_pnl_asset: ?AssetIdentity = null,
    realized_pnl_atoms: i128 = 0,
    liquidity: LiquidityRole = .taker,
};

pub const max_order_commands_per_batch = 4;
pub const OrderCommandBatch = struct {
    commands: [max_order_commands_per_batch]OrderCommand = undefined,
    len: u8 = 0,

    pub fn append(self: *OrderCommandBatch, command: OrderCommand) !void {
        if (self.len == self.commands.len) return error.OrderBatchFull;
        self.commands[self.len] = command;
        self.len += 1;
    }

    pub fn slice(self: *const OrderCommandBatch) []const OrderCommand {
        return self.commands[0..self.len];
    }
};

pub const OrderReconciliationRequest = struct {
    identity: u128,
    exchange_account: ExchangeAccountIdentity,
    order: OrderIdentity,
    venue_order: ?VenueOrderRef = null,
    visibility_delay_elapsed: bool = false,
    prior_session_inactive: bool = false,
};

pub const AccountReconciliationRequest = struct {
    identity: u128,
    exchange_account: ExchangeAccountIdentity,
    expected_session: AdapterSessionIdentity,
};

pub const AdapterRequest = union(enum) {
    order_command: OrderCommand,
    order_batch: OrderCommandBatch,
    order_reconciliation: OrderReconciliationRequest,
    account_reconciliation: AccountReconciliationRequest,
};

pub const OrderDispatchResult = struct {
    command: OrderIdentity,
    state: DispatchState,
    reason: ?CanonicalRejectReason = null,
};
pub const InstrumentDefinitionObserved = struct { instrument: InstrumentIdentity, rules_version: u64 };
pub const L2BookSnapshot = struct { instrument: InstrumentIdentity, sequence: VenueSourceSequence, best_bid: InstrumentPrice, best_ask: InstrumentPrice };
pub const L2BookDelta = struct { instrument: InstrumentIdentity, previous_sequence: VenueSourceSequence, sequence: VenueSourceSequence, best_bid: InstrumentPrice, best_ask: InstrumentPrice };
pub const ReferencePriceKind = enum(u8) { mark, index };
pub const ReferencePrice = struct { instrument: InstrumentIdentity, kind: ReferencePriceKind, price: InstrumentPrice };
pub const FundingRatePublished = struct { instrument: InstrumentIdentity, rate_ppm: i64, funding_time_utc_ns: u64 };
pub const MarketDataHealth = enum(u8) { awaiting_snapshot, healthy, gap };
pub const MarketDataHealthChanged = struct { instrument: InstrumentIdentity, health: MarketDataHealth };

pub const PositionSide = enum(u8) { long, short };
pub const AccountBalance = struct {
    asset: AssetIdentity,
    total: AssetAmount,
    available: AssetAmount,
    held: AssetAmount,
    liability: ?AssetAmount = null,
    cash_balance: ?AssetAmount = null,
    isolated_liability: ?AssetAmount = null,
    cross_liability: ?AssetAmount = null,
};
pub const AccountPosition = struct {
    instrument: InstrumentIdentity,
    side: PositionSide,
    quantity: InstrumentQuantity,
    average_price: ?InstrumentPrice = null,
    mark_price: ?InstrumentPrice = null,
    liquidation_price: ?InstrumentPrice = null,
    margin: ?AssetAmount = null,
    leverage: ?Decimal = null,
    unrealized_pnl: ?AssetAmount = null,
};
pub const AccountMargin = struct {
    instrument: ?InstrumentIdentity = null,
    amount: AssetAmount,
    adjusted_equity: ?AssetAmount = null,
    initial_margin: ?AssetAmount = null,
    maintenance_margin: ?AssetAmount = null,
    isolated_equity: ?AssetAmount = null,
    margin_ratio: ?Decimal = null,
};
pub const max_account_facts = 8;
pub const AccountSnapshotScope = struct { balances_complete: bool, positions_complete: bool, margins_complete: bool };

pub const AccountBootstrapSnapshot = struct {
    identity: BootstrapSnapshotIdentity,
    exchange_account: ExchangeAccountIdentity,
    scope: AccountSnapshotScope,
    source_stream: VenueSourceStreamIdentity,
    source_sequence: VenueSourceSequence,
    balances: [max_account_facts]AccountBalance = undefined,
    balance_count: u8,
    positions: [max_account_facts]AccountPosition = undefined,
    position_count: u8,
    margins: [max_account_facts]AccountMargin = undefined,
    margin_count: u8,
};

pub const AccountObserved = union(enum) {
    balance: struct { asset: AssetIdentity, value: AccountBalance, removed: bool = false },
    position: struct { instrument: InstrumentIdentity, side: PositionSide, value: AccountPosition, removed: bool = false },
    margin: struct { instrument: ?InstrumentIdentity = null, value: AccountMargin, removed: bool = false },
};

pub const AccountObservation = struct {
    identity: SourceFactIdentity,
    exchange_account: ExchangeAccountIdentity,
    bootstrap: BootstrapSnapshotIdentity,
    source_stream: VenueSourceStreamIdentity,
    source_sequence: VenueSourceSequence,
    value: AccountObserved,
};

pub const ReconciliationStatus = enum(u8) { found_live, found_terminal, confirmed_absent, unresolved };
pub const ReconciliationResult = struct {
    identity: u128,
    complete: bool,
    status: ReconciliationStatus = .unresolved,
};

pub const ExecutionReport = struct {
    identity: SourceFactIdentity,
    order: OrderIdentity,
    client_order_id: ClientOrderId,
    venue_order: ?VenueOrderRef = null,
    instrument: InstrumentIdentity,
    exchange_account: ExchangeAccountIdentity,
    revision: u32,
    side: OrderSide = .buy,
    order_type: ?OrderType = null,
    time_in_force: ?TimeInForce = null,
    venue_reduce_only: ?bool = null,
    position_mode_net: ?bool = null,
    margin_mode_isolated: ?bool = null,
    leverage: ?Decimal = null,
    status: ExecutionReportStatus,
    original_quantity: ?InstrumentQuantity = null,
    cumulative_quantity: InstrumentQuantity,
    remaining_quantity: InstrumentQuantity,
    limit_price: ?InstrumentPrice = null,
    average_fill_price: ?InstrumentPrice = null,
    venue_update_time_utc_ns: ?u64 = null,
};

pub const Fill = struct {
    identity: SourceFactIdentity,
    order: OrderIdentity,
    client_order_id: ClientOrderId,
    venue_order: VenueOrderRef,
    venue_trade: VenueTradeRef,
    instrument: InstrumentIdentity,
    exchange_account: ExchangeAccountIdentity,
    side: OrderSide,
    quantity: InstrumentQuantity,
    price: InstrumentPrice,
    fee: ?AssetAmount = null,
    rebate: ?AssetAmount = null,
    realized_pnl: ?AssetAmount = null,
    liquidity: LiquidityRole,
};

pub const VenueAccountConfigurationSnapshot = struct {
    identity: SourceFactIdentity,
    exchange_account: ExchangeAccountIdentity,
    value: union(enum) {
        account: struct {
            position_mode_net: bool,
            contract_isolated_autonomy: bool,
            auto_loan: bool,
            spot_borrow_enabled: bool,
            can_read: bool,
            can_trade: bool,
            can_withdraw: bool,
        },
        isolated_leverage: struct {
            instrument: InstrumentIdentity,
            position_mode_net: bool,
            margin_mode_isolated: bool,
            leverage: Decimal,
        },
    },
};

pub const CanonicalEvent = union(enum) {
    order_dispatch_result: OrderDispatchResult,
    execution_report: ExecutionReport,
    fill: Fill,
    reconciliation_started: u128,
    account_reconciliation_started: u128,
    instrument_definition_observed: InstrumentDefinitionObserved,
    l2_book_snapshot: L2BookSnapshot,
    l2_book_delta: L2BookDelta,
    reference_price: ReferencePrice,
    funding_rate_published: FundingRatePublished,
    market_data_health_changed: MarketDataHealthChanged,
    account_bootstrap_snapshot: AccountBootstrapSnapshot,
    account_observed: AccountObservation,
    venue_account_configuration_snapshot: VenueAccountConfigurationSnapshot,
    order_reconciliation_result: ReconciliationResult,
    account_reconciliation_result: ReconciliationResult,
};

pub const EventType = enum(u32) {
    order_dispatch_result = 1,
    execution_report = 3,
    fill = 4,
    reconciliation_started = 5,
    account_reconciliation_started = 6,
    account_bootstrap_snapshot = 11,
    account_observed = 12,
    venue_account_configuration_snapshot = 13,
    order_reconciliation_result = 14,
    account_reconciliation_result = 15,
    instrument_definition_observed = 16,
    l2_book_snapshot = 17,
    l2_book_delta = 18,
    reference_price = 19,
    funding_rate_published = 20,
    market_data_health_changed = 21,
};

pub const TimeInForce = enum(u8) { good_til_canceled, immediate_or_cancel, fill_or_kill, post_only };

pub fn eventType(event: CanonicalEvent) EventType {
    return switch (event) {
        .order_dispatch_result => .order_dispatch_result,
        .execution_report => .execution_report,
        .fill => .fill,
        .reconciliation_started => .reconciliation_started,
        .account_reconciliation_started => .account_reconciliation_started,
        .account_bootstrap_snapshot => .account_bootstrap_snapshot,
        .account_observed => .account_observed,
        .venue_account_configuration_snapshot => .venue_account_configuration_snapshot,
        .order_reconciliation_result => .order_reconciliation_result,
        .account_reconciliation_result => .account_reconciliation_result,
        .instrument_definition_observed => .instrument_definition_observed,
        .l2_book_snapshot => .l2_book_snapshot,
        .l2_book_delta => .l2_book_delta,
        .reference_price => .reference_price,
        .funding_rate_published => .funding_rate_published,
        .market_data_health_changed => .market_data_health_changed,
    };
}

pub const EventRecord = struct { envelope: EventEnvelope, event: CanonicalEvent };
pub const max_events_per_adapter_batch = 32;
pub const AdapterOutputBatch = struct {
    events: [max_events_per_adapter_batch]EventRecord = undefined,
    len: u8 = 0,

    pub fn append(self: *AdapterOutputBatch, event: EventRecord) !void {
        if (self.len == self.events.len) return error.AdapterOutputFull;
        self.events[self.len] = event;
        self.len += 1;
    }

    pub fn slice(self: *const AdapterOutputBatch) []const EventRecord {
        return self.events[0..self.len];
    }
};

test "decimal conversion is lossless and exact" {
    const value = try Decimal.parse("-12.3400");
    try std.testing.expectEqual(@as(i128, -123400), value.coefficient);
    try std.testing.expectEqual(@as(u8, 4), value.scale);
    try std.testing.expectEqual(@as(i128, -1234), try value.exactAtoms(2));
    try std.testing.expectEqual(@as(i128, -1234), (try AssetAmount.fromDecimal(3, value, 2)).atoms);
    try std.testing.expectEqual(@as(i128, -24680), (try InstrumentPrice.fromDecimal(4, 5, value, 4, 5)).ticks);
    try std.testing.expectEqual(@as(i128, -617), (try InstrumentQuantity.fromDecimal(4, 5, value, 2, 2)).lots);
    try std.testing.expectError(error.InexactDecimal, (try Decimal.parse("1.001")).exactAtoms(2));
    try std.testing.expectError(error.InexactInstrumentPrice, InstrumentPrice.fromDecimal(4, 5, try Decimal.parse("0.01"), 2, 5));
}

test "opaque venue references are bounded" {
    const order = try VenueOrderRef.init(3, "venue-order-1");
    try std.testing.expectEqual(@as(VenueIdentity, 3), order.venue);
    try std.testing.expectEqualStrings("venue-order-1", order.value.slice());
    try std.testing.expectError(error.InvalidOpaqueRef, VenueTradeRef.init(3, ""));
}
