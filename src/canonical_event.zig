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
    quantity: ?InstrumentQuantity = null,
    limit_price: ?InstrumentPrice = null,
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

pub const ExecutionReport = struct {
    identity: SourceFactIdentity,
    order: OrderIdentity,
    client_order_id: ClientOrderId,
    venue_order: ?VenueOrderRef = null,
    instrument: InstrumentIdentity,
    exchange_account: ExchangeAccountIdentity,
    revision: u32,
    status: ExecutionReportStatus,
    cumulative_quantity: InstrumentQuantity,
    remaining_quantity: InstrumentQuantity,
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

pub const CanonicalEvent = union(enum) {
    order_dispatch_result: OrderDispatchResult,
    execution_report: ExecutionReport,
    fill: Fill,
    reconciliation_started: u128,
    account_reconciliation_started: u128,
};

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
