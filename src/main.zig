const std = @import("std");
const builtin = @import("builtin");
const journal = @import("journal.zig");
const host_gateway = @import("strategy_host_gateway.zig");
const venue_adapter = @import("venue_adapter.zig");
const okx_public_market = @import("okx_public_market.zig");
const okx_private_reconciliation = @import("okx_private_reconciliation.zig");
const okx_spot_projection = @import("okx_spot_projection.zig");
const okx_order_entry = @import("okx_order_entry.zig");
const okx_live_chain = @import("okx_live_chain.zig");
const okx_rest_auth = @import("okx_rest_auth.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const schema_version: u16 = 1;
const client_order_id = "RWN-00000001-01-000000000001";
const money_scale: i64 = 1_000_000;
const contract_denominator: i64 = 10_000;
const fee_ppm: i64 = 750;
const rate_scale: i64 = 1_000_000;
const leverage: i64 = 50;
const internal_margin_percent: i64 = 110;
const happy_order_quantity: i64 = 100;
const order_limit_price: i64 = 50_100_000_000;
const initial_exchange_cash: i64 = 25_000 * money_scale;
const portfolio_allocation: i64 = 20_000 * money_scale;
const risk_lease_total: i64 = 10_000 * money_scale;
const expected_happy_digest = "9951db6c2ea314b42fa0ce5887225cb4d026a95358b2ca026984dc59330adb08";
const expected_market_gap_digest = "e857b9c12bdea00ea176249c2c8686057b0c618ef60ad7b111df05efbdeda5d4";
const expected_risk_rejection_digest = "b5fe808878d1394479092619a00a99c562c3a89f111de3d4a79964e7045caebd";
const expected_unknown_digest = "a61e0e5e863601fe44daf55806a506591ec7c6081216000ebda8c5e0686c029c";
const expected_duplicate_digest = "7bb91e2c0f375481a7d62f772ac68953dc0b97fcb913ba994a53ce01ae3d0040";
const fixture_utc_base: u64 = 1_767_225_600_000_000_000;
const fixture_monotonic_base: u64 = 1_000_000_000;
const benchmark_samples: usize = 1_000_000;
const benchmark_warmup: usize = 50_000;

const EventKind = enum(u16) {
    instrument_rules_activated,
    margin_rules_activated,
    account_configuration,
    exchange_balance,
    exchange_positions,
    opening_balance,
    virtual_portfolio_activated,
    portfolio_transfer,
    strategy_activated,
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
};

const Event = struct {
    sequence: u64,
    kind: EventKind,
    identity: u64,
};

const Trace = struct {
    events: [64]Event = undefined,
    len: usize = 0,

    fn append(self: *Trace, kind: EventKind, identity: u64) !void {
        if (self.len == self.events.len) return error.TraceFull;
        self.events[self.len] = .{
            .sequence = self.len + 1,
            .kind = kind,
            .identity = identity,
        };
        self.len += 1;
    }
};

const ExecutionStatus = enum(u8) { accepted, partially_filled, filled, canceled };
const DispatchStatus = enum(u8) { submitted, unknown };
const ReconciliationStatus = enum(u8) { found_live };
const MarketHealth = enum(u8) { initializing, healthy, gap };
const RejectReason = enum(u8) { none, market_data_gap, global_risk_lease_exceeded };

const ExecutionReport = struct {
    report_id: u64,
    status: ExecutionStatus,
    cumulative_qty: i64,
    remaining_qty: i64,
};

const Fill = struct {
    fill_id: u64,
    quantity: i64,
    price_micros: i64,
};

const L2Snapshot = struct {
    source_sequence: u64,
    bid_price_micros: i64,
    bid_quantity: i64,
    ask_1_price_micros: i64,
    ask_1_quantity: i64,
    ask_2_price_micros: i64,
    ask_2_quantity: i64,
};

const L2Delta = struct {
    previous: u64,
    current: u64,
    bid_price_micros: i64,
    bid_quantity: i64,
};

const TimerRequest = struct {
    quantity: i64,
};

const ReconciliationResult = struct {
    reconciliation_id: u64,
    status: ReconciliationStatus,
    venue_order_id: u64,
};

const PayloadTag = enum(u16) {
    instrument_rules_activated,
    margin_rules_activated,
    account_configuration,
    exchange_balance,
    exchange_positions,
    opening_balance,
    virtual_portfolio_activated,
    portfolio_transfer,
    strategy_activated,
    primary_lease_granted,
    risk_lease_granted,
    mark_price,
    l2_snapshot,
    l2_delta,
    timer,
    order_dispatch_result,
    order_reconciliation_result,
    execution_report,
    fill,
    external_order_intent,
    strategy_intent_rejected,
};

const Payload = union(PayloadTag) {
    instrument_rules_activated,
    margin_rules_activated,
    account_configuration,
    exchange_balance,
    exchange_positions,
    opening_balance,
    virtual_portfolio_activated,
    portfolio_transfer,
    strategy_activated,
    primary_lease_granted,
    risk_lease_granted,
    mark_price: i64,
    l2_snapshot: L2Snapshot,
    l2_delta: L2Delta,
    timer: TimerRequest,
    order_dispatch_result: DispatchStatus,
    order_reconciliation_result: ReconciliationResult,
    execution_report: ExecutionReport,
    fill: Fill,
    external_order_intent: host_gateway.OrderIntent,
    strategy_intent_rejected: host_gateway.Rejection,
};

const InputEvent = struct {
    version: u16 = schema_version,
    identity: u64,
    source_time: u64 = 0,
    receive_time: u64 = 0,
    monotonic_time: u64 = 0,
    wall_time: u64 = 0,
    time_presence: journal.TimePresence = .{},
    payload: Payload,
};

fn atGroup(group_index: u64, input: InputEvent) InputEvent {
    var timed = input;
    timed.source_time = fixture_utc_base + group_index * 10 * std.time.ns_per_ms;
    timed.receive_time = timed.source_time + std.time.ns_per_ms;
    timed.monotonic_time = fixture_monotonic_base +
        group_index * 10 * std.time.ns_per_ms + std.time.ns_per_ms;
    timed.wall_time = timed.receive_time + std.time.ns_per_ms;
    timed.time_presence = .{
        .source = true,
        .receive = true,
        .monotonic = true,
        .wall = true,
    };
    return timed;
}

const EncodedInput = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,

    fn put(self: *EncodedInput, comptime T: type, value: T) !void {
        if (self.bytes.len - self.len < @sizeOf(T)) return error.InputPayloadTooLarge;
        std.mem.writeInt(T, self.bytes[self.len..][0..@sizeOf(T)], value, .little);
        self.len += @sizeOf(T);
    }
};

fn encodeInput(input: InputEvent) !EncodedInput {
    var encoded: EncodedInput = .{};
    try encoded.put(u64, input.identity);
    try encoded.put(u16, @intFromEnum(std.meta.activeTag(input.payload)));
    switch (input.payload) {
        .mark_price => |value| try encoded.put(i64, value),
        .l2_snapshot => |value| {
            try encoded.put(u64, value.source_sequence);
            try encoded.put(i64, value.bid_price_micros);
            try encoded.put(i64, value.bid_quantity);
            try encoded.put(i64, value.ask_1_price_micros);
            try encoded.put(i64, value.ask_1_quantity);
            try encoded.put(i64, value.ask_2_price_micros);
            try encoded.put(i64, value.ask_2_quantity);
        },
        .l2_delta => |value| {
            try encoded.put(u64, value.previous);
            try encoded.put(u64, value.current);
            try encoded.put(i64, value.bid_price_micros);
            try encoded.put(i64, value.bid_quantity);
        },
        .timer => |value| try encoded.put(i64, value.quantity),
        .order_dispatch_result => |value| try encoded.put(u8, @intFromEnum(value)),
        .order_reconciliation_result => |value| {
            try encoded.put(u64, value.reconciliation_id);
            try encoded.put(u8, @intFromEnum(value.status));
            try encoded.put(u64, value.venue_order_id);
        },
        .execution_report => |value| {
            try encoded.put(u64, value.report_id);
            try encoded.put(u8, @intFromEnum(value.status));
            try encoded.put(i64, value.cumulative_qty);
            try encoded.put(i64, value.remaining_qty);
        },
        .fill => |value| {
            try encoded.put(u64, value.fill_id);
            try encoded.put(i64, value.quantity);
            try encoded.put(i64, value.price_micros);
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

fn decodeInput(record: journal.Record) !InputEvent {
    if (record.schema_version != schema_version) return error.UnsupportedSchema;
    var offset: usize = 0;
    const identity = try readInputValue(u64, record.payload, &offset);
    const tag = std.enums.fromInt(
        PayloadTag,
        try readInputValue(u16, record.payload, &offset),
    ) orelse return error.UnknownInputType;
    const payload: Payload = switch (tag) {
        .instrument_rules_activated => .instrument_rules_activated,
        .margin_rules_activated => .margin_rules_activated,
        .account_configuration => .account_configuration,
        .exchange_balance => .exchange_balance,
        .exchange_positions => .exchange_positions,
        .opening_balance => .opening_balance,
        .virtual_portfolio_activated => .virtual_portfolio_activated,
        .portfolio_transfer => .portfolio_transfer,
        .strategy_activated => .strategy_activated,
        .primary_lease_granted => .primary_lease_granted,
        .risk_lease_granted => .risk_lease_granted,
        .mark_price => .{ .mark_price = try readInputValue(i64, record.payload, &offset) },
        .l2_snapshot => .{ .l2_snapshot = .{
            .source_sequence = try readInputValue(u64, record.payload, &offset),
            .bid_price_micros = try readInputValue(i64, record.payload, &offset),
            .bid_quantity = try readInputValue(i64, record.payload, &offset),
            .ask_1_price_micros = try readInputValue(i64, record.payload, &offset),
            .ask_1_quantity = try readInputValue(i64, record.payload, &offset),
            .ask_2_price_micros = try readInputValue(i64, record.payload, &offset),
            .ask_2_quantity = try readInputValue(i64, record.payload, &offset),
        } },
        .l2_delta => .{ .l2_delta = .{
            .previous = try readInputValue(u64, record.payload, &offset),
            .current = try readInputValue(u64, record.payload, &offset),
            .bid_price_micros = try readInputValue(i64, record.payload, &offset),
            .bid_quantity = try readInputValue(i64, record.payload, &offset),
        } },
        .timer => .{ .timer = .{
            .quantity = try readInputValue(i64, record.payload, &offset),
        } },
        .order_dispatch_result => .{ .order_dispatch_result = std.enums.fromInt(
            DispatchStatus,
            try readInputValue(u8, record.payload, &offset),
        ) orelse return error.UnknownDispatchStatus },
        .order_reconciliation_result => .{ .order_reconciliation_result = .{
            .reconciliation_id = try readInputValue(u64, record.payload, &offset),
            .status = std.enums.fromInt(
                ReconciliationStatus,
                try readInputValue(u8, record.payload, &offset),
            ) orelse return error.UnknownReconciliationStatus,
            .venue_order_id = try readInputValue(u64, record.payload, &offset),
        } },
        .execution_report => .{ .execution_report = .{
            .report_id = try readInputValue(u64, record.payload, &offset),
            .status = std.enums.fromInt(
                ExecutionStatus,
                try readInputValue(u8, record.payload, &offset),
            ) orelse return error.UnknownExecutionStatus,
            .cumulative_qty = try readInputValue(i64, record.payload, &offset),
            .remaining_qty = try readInputValue(i64, record.payload, &offset),
        } },
        .fill => .{ .fill = .{
            .fill_id = try readInputValue(u64, record.payload, &offset),
            .quantity = try readInputValue(i64, record.payload, &offset),
            .price_micros = try readInputValue(i64, record.payload, &offset),
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
    };
    if (offset != record.payload.len) return error.TrailingInputPayload;
    return .{
        .version = record.schema_version,
        .identity = identity,
        .source_time = record.source_time,
        .receive_time = record.receive_time,
        .monotonic_time = record.monotonic_time,
        .wall_time = record.wall_time,
        .time_presence = record.time_presence,
        .payload = payload,
    };
}

fn eventIdentity(payload: []const u8) !u64 {
    if (payload.len < @sizeOf(u64)) return error.MissingEventIdentity;
    return std.mem.readInt(u64, payload[0..@sizeOf(u64)], .little);
}

const OrderCommand = struct {
    command_id: u64,
    order_id: u64,
    quantity: i64,
    limit_price_micros: i64,
    reservation_micros: i64,
    client_id: []const u8,
};

const OrderState = enum(u8) {
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
    if (quantity < 0 or price_micros <= 0) return error.InvalidNotionalInput;
    return ceilDivPositive(
        @as(i128, quantity) * price_micros,
        contract_denominator,
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
    if (remaining_quantity == 0) return 0;
    const notional = try notionalMicros(remaining_quantity, limit_price_micros);
    return try std.math.add(i64, try internalMarginMicros(notional), try feeMicros(notional));
}

fn riskTier(notional_micros: i64) !u8 {
    if (notional_micros <= 500_000 * money_scale) return 1;
    if (notional_micros <= 1_000_000 * money_scale) return 2;
    if (notional_micros <= 1_500_000 * money_scale) return 3;
    return error.RiskLimitExceeded;
}

fn reportEventKind(status: ExecutionStatus) EventKind {
    return switch (status) {
        .accepted => .order_accepted,
        .partially_filled => .order_partially_filled,
        .filled => .order_filled,
        .canceled => .order_canceled,
    };
}

fn rememberFill(facts: *[8]Fill, count: *usize, fill: Fill) !bool {
    var index: usize = 0;
    while (index < count.* and facts[index].fill_id < fill.fill_id) : (index += 1) {}
    if (index < count.* and facts[index].fill_id == fill.fill_id) {
        if (facts[index].quantity != fill.quantity or
            facts[index].price_micros != fill.price_micros)
            return error.ConflictingFillIdentity;
        return false;
    }
    if (count.* == facts.len) return error.IdentitySetFull;
    var move = count.*;
    while (move > index) : (move -= 1) facts[move] = facts[move - 1];
    facts[index] = fill;
    count.* += 1;
    return true;
}

fn rememberReport(
    facts: *[8]ExecutionReport,
    count: *usize,
    report: ExecutionReport,
) !bool {
    var index: usize = 0;
    while (index < count.* and facts[index].report_id < report.report_id) : (index += 1) {}
    if (index < count.* and facts[index].report_id == report.report_id) {
        if (facts[index].status != report.status or
            facts[index].cumulative_qty != report.cumulative_qty or
            facts[index].remaining_qty != report.remaining_qty)
            return error.ConflictingReportIdentity;
        return false;
    }
    if (count.* == facts.len) return error.IdentitySetFull;
    var move = count.*;
    while (move > index) : (move -= 1) facts[move] = facts[move - 1];
    facts[index] = report;
    count.* += 1;
    return true;
}

const TradingShard = struct {
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
    reconciliation_id: u64 = 0,
    venue_order_id: u64 = 0,
    last_reject_reason: RejectReason = .none,
    last_risk_required_micros: i64 = 0,
    last_risk_tier: u8 = 0,
    filled_quantity: i64 = 0,
    fill_facts: [8]Fill = undefined,
    fill_fact_count: usize = 0,
    report_facts: [8]ExecutionReport = undefined,
    report_fact_count: usize = 0,
    mark_price_micros: i64 = 0,
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
    ledger_transaction_count: u64 = 0,
    portfolio_transfer_count: u64 = 0,
    portfolio_ledger_debits_micros: i64 = 0,
    portfolio_ledger_credits_micros: i64 = 0,
    exchange_ledger_debits_micros: i64 = 0,
    exchange_ledger_credits_micros: i64 = 0,
    economic_projections_complete: bool = false,

    fn revalue(self: *TradingShard) !void {
        if (self.portfolio_position.quantity == 0) {
            self.unrealized_pnl_micros = 0;
            return;
        }
        const mark_value = try notionalMicros(
            self.portfolio_position.quantity,
            self.mark_price_micros,
        );
        self.unrealized_pnl_micros = try std.math.sub(
            i64,
            mark_value,
            self.portfolio_position.open_cost_micros,
        );
    }

    fn recalculateRisk(self: *TradingShard) !void {
        self.position_margin_requirement_micros = if (self.portfolio_position.quantity == 0)
            0
        else
            try internalMarginMicros(try notionalMicros(
                self.portfolio_position.quantity,
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
            try openOrderReservationMicros(
                remaining_quantity,
                self.order_limit_price_micros,
            );

        const used = try std.math.add(
            i64,
            self.position_margin_requirement_micros,
            self.open_order_reservation_micros,
        );
        self.risk_lease_remaining_micros = try std.math.sub(i64, self.risk_lease_micros, used);
        if (self.risk_lease_remaining_micros < 0) return error.RiskLeaseExceeded;
    }

    fn assertClosures(self: TradingShard) !void {
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

    fn applyFill(self: *TradingShard, fill: Fill) !void {
        const next_filled = try std.math.add(i64, self.filled_quantity, fill.quantity);
        if (fill.quantity <= 0 or fill.price_micros <= 0 or
            next_filled > self.order_quantity)
            return error.InvalidFill;

        const fill_cost = try notionalMicros(fill.quantity, fill.price_micros);
        const fee = try feeMicros(fill_cost);
        self.filled_quantity = next_filled;
        self.portfolio_position.quantity = next_filled;
        self.exchange_position.quantity = next_filled;
        self.portfolio_position.open_cost_micros = try std.math.add(
            i64,
            self.portfolio_position.open_cost_micros,
            fill_cost,
        );
        self.exchange_position.open_cost_micros = self.portfolio_position.open_cost_micros;

        self.total_fees_micros = try std.math.add(i64, self.total_fees_micros, fee);
        self.portfolio_cash_micros = try std.math.sub(i64, self.portfolio_cash_micros, fee);
        self.exchange_cash_micros = try std.math.sub(i64, self.exchange_cash_micros, fee);
        self.portfolio_fee_expense_micros = try std.math.add(
            i64,
            self.portfolio_fee_expense_micros,
            fee,
        );
        self.exchange_fee_expense_micros = try std.math.add(
            i64,
            self.exchange_fee_expense_micros,
            fee,
        );
        self.portfolio_ledger_debits_micros = try std.math.add(
            i64,
            self.portfolio_ledger_debits_micros,
            fee,
        );
        self.portfolio_ledger_credits_micros = try std.math.add(
            i64,
            self.portfolio_ledger_credits_micros,
            fee,
        );
        self.exchange_ledger_debits_micros = try std.math.add(
            i64,
            self.exchange_ledger_debits_micros,
            fee,
        );
        self.exchange_ledger_credits_micros = try std.math.add(
            i64,
            self.exchange_ledger_credits_micros,
            fee,
        );
        self.ledger_transaction_count = try std.math.add(u64, self.ledger_transaction_count, 1);

        try self.revalue();
        try self.recalculateRisk();
        try self.assertClosures();
    }

    fn submitOrderIntent(self: *TradingShard, intent: host_gateway.OrderIntent) !?OrderCommand {
        if (intent.side != .buy or intent.order_type != .limit or
            intent.time_in_force != .good_til_canceled or intent.portfolio_reduce_only or
            intent.quantity <= 0 or intent.limit_price_micros <= 0)
            return error.InvalidOrderIntent;
        if (self.order_state != .none) return error.IntentArrivedWithOpenOrder;
        try self.trace.append(.order_intent, intent.intent_sequence);

        const requested_notional = try notionalMicros(
            intent.quantity,
            intent.limit_price_micros,
        );
        self.last_risk_tier = try riskTier(requested_notional);
        self.last_risk_required_micros = try openOrderReservationMicros(
            intent.quantity,
            intent.limit_price_micros,
        );
        if (self.market_health != .healthy) {
            self.last_reject_reason = .market_data_gap;
            try self.trace.append(.risk_rejected_market_data, intent.intent_sequence);
            return null;
        }
        if (self.last_risk_required_micros > self.risk_lease_micros) {
            self.last_reject_reason = .global_risk_lease_exceeded;
            try self.trace.append(.risk_rejected_lease, intent.intent_sequence);
            return null;
        }

        self.last_reject_reason = .none;
        try self.trace.append(.risk_accepted, intent.intent_sequence);
        self.order_state = .pending_submit;
        self.order_counter += 1;
        self.order_id = self.order_counter;
        self.order_command_id = self.order_counter;
        self.order_quantity = intent.quantity;
        self.order_limit_price_micros = intent.limit_price_micros;
        try self.recalculateRisk();
        try self.trace.append(.risk_reservation_created, intent.intent_sequence);
        try self.trace.append(.order_command, intent.intent_sequence);
        return .{
            .command_id = self.order_command_id,
            .order_id = self.order_id,
            .quantity = intent.quantity,
            .limit_price_micros = intent.limit_price_micros,
            .reservation_micros = self.open_order_reservation_micros,
            .client_id = client_order_id,
        };
    }

    fn handle(self: *TradingShard, input: InputEvent) !?OrderCommand {
        if (input.version != schema_version) return error.UnsupportedSchema;

        switch (input.payload) {
            .instrument_rules_activated => {
                self.instrument_rules_version = 1;
                try self.trace.append(.instrument_rules_activated, input.identity);
            },
            .margin_rules_activated => {
                self.margin_rules_version = 1;
                try self.trace.append(.margin_rules_activated, input.identity);
            },
            .account_configuration => {
                self.account_configured = true;
                try self.trace.append(.account_configuration, input.identity);
            },
            .exchange_balance => {
                self.exchange_cash_micros = initial_exchange_cash;
                try self.trace.append(.exchange_balance, input.identity);
            },
            .exchange_positions => try self.trace.append(.exchange_positions, input.identity),
            .opening_balance => {
                self.treasury_cash_micros = initial_exchange_cash;
                self.portfolio_ledger_debits_micros = initial_exchange_cash;
                self.portfolio_ledger_credits_micros = initial_exchange_cash;
                self.exchange_ledger_debits_micros = initial_exchange_cash;
                self.exchange_ledger_credits_micros = initial_exchange_cash;
                self.ledger_transaction_count = 1;
                try self.trace.append(.opening_balance, input.identity);
            },
            .virtual_portfolio_activated => {
                self.virtual_portfolio_active = true;
                try self.trace.append(.virtual_portfolio_activated, input.identity);
            },
            .portfolio_transfer => {
                self.treasury_cash_micros = try std.math.sub(
                    i64,
                    self.treasury_cash_micros,
                    portfolio_allocation,
                );
                self.portfolio_cash_micros = try std.math.add(
                    i64,
                    self.portfolio_cash_micros,
                    portfolio_allocation,
                );
                self.portfolio_ledger_debits_micros = try std.math.add(
                    i64,
                    self.portfolio_ledger_debits_micros,
                    portfolio_allocation,
                );
                self.portfolio_ledger_credits_micros = try std.math.add(
                    i64,
                    self.portfolio_ledger_credits_micros,
                    portfolio_allocation,
                );
                self.portfolio_transfer_count = 1;
                try self.trace.append(.portfolio_transfer, input.identity);
            },
            .strategy_activated => {
                self.strategy_active = true;
                try self.trace.append(.strategy_activated, input.identity);
            },
            .primary_lease_granted => {
                self.fencing_token = 1;
                try self.trace.append(.primary_lease_granted, input.identity);
            },
            .risk_lease_granted => {
                self.risk_lease_micros = risk_lease_total;
                self.risk_lease_remaining_micros = risk_lease_total;
                try self.assertClosures();
                try self.trace.append(.risk_lease_granted, input.identity);
            },
            .mark_price => |price| {
                if (price <= 0) return error.InvalidMarkPrice;
                self.mark_price_micros = price;
                try self.revalue();
                try self.recalculateRisk();
                try self.assertClosures();
                try self.trace.append(.mark_price, input.identity);
                if (self.order_state == .filled) self.economic_projections_complete = true;
            },
            .l2_snapshot => |snapshot| {
                if (snapshot.bid_price_micros <= 0 or snapshot.bid_quantity <= 0 or
                    snapshot.ask_1_price_micros <= 0 or snapshot.ask_1_quantity <= 0 or
                    snapshot.ask_2_price_micros <= snapshot.ask_1_price_micros or
                    snapshot.ask_2_quantity <= 0)
                    return error.InvalidBookSnapshot;
                self.expected_source_sequence = snapshot.source_sequence;
                self.bid_price_micros = snapshot.bid_price_micros;
                self.bid_quantity = snapshot.bid_quantity;
                self.ask_1_price_micros = snapshot.ask_1_price_micros;
                self.ask_1_quantity = snapshot.ask_1_quantity;
                self.ask_2_price_micros = snapshot.ask_2_price_micros;
                self.ask_2_quantity = snapshot.ask_2_quantity;
                try self.trace.append(.l2_snapshot, input.identity);
            },
            .l2_delta => |delta| {
                if (delta.bid_price_micros <= 0 or delta.bid_quantity <= 0)
                    return error.InvalidBookDelta;
                if (self.expected_source_sequence != delta.previous or
                    delta.current != delta.previous + 1)
                {
                    try self.trace.append(.l2_delta, input.identity);
                    self.market_health = .gap;
                    try self.trace.append(.market_gap, 1);
                    return null;
                }
                self.expected_source_sequence = delta.current;
                self.bid_price_micros = delta.bid_price_micros;
                self.bid_quantity = delta.bid_quantity;
                try self.trace.append(.l2_delta, input.identity);
                if (self.market_health != .healthy) {
                    self.market_health = .healthy;
                    try self.trace.append(.market_healthy, 1);
                }
            },
            .timer => |request| {
                if (request.quantity <= 0) return error.InvalidOrderQuantity;
                try self.trace.append(.timer, input.identity);
                self.timer_pending = false;
                self.strategy_cursor = self.trace.len;
                self.strategy_decision_count += 1;
                return self.submitOrderIntent(.{
                    .strategy_identity = 1,
                    .intent_sequence = 1,
                    .strategy_cursor = self.strategy_cursor,
                    .config_version = 1,
                    .activation_identity = 1,
                    .portfolio_identity = 1,
                    .exchange_account_identity = 2,
                    .instrument_identity = 3,
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
            .order_dispatch_result => |status| {
                if (self.order_state != .pending_submit) return error.InvalidDispatchResult;
                self.dispatch_attempt_count = try std.math.add(
                    u64,
                    self.dispatch_attempt_count,
                    1,
                );
                switch (status) {
                    .submitted => try self.trace.append(.order_dispatched, input.identity),
                    .unknown => {
                        self.order_state = .unknown;
                        try self.trace.append(.order_dispatch_unknown, input.identity);
                    },
                }
            },
            .order_reconciliation_result => |result| {
                if (self.reconciliation_id != 0) {
                    if (self.reconciliation_id != result.reconciliation_id or
                        self.venue_order_id != result.venue_order_id or
                        result.status != .found_live)
                        return error.ConflictingReconciliationIdentity;
                    try self.trace.append(.order_reconciled_live, result.reconciliation_id);
                    return null;
                }
                if (self.order_state != .unknown or result.status != .found_live)
                    return error.InvalidReconciliationResult;
                self.reconciliation_id = result.reconciliation_id;
                self.venue_order_id = result.venue_order_id;
                try self.trace.append(.order_reconciled_live, result.reconciliation_id);
            },
            .execution_report => |report| {
                switch (report.status) {
                    .accepted => {
                        if (report.cumulative_qty != 0 or
                            report.remaining_qty != self.order_quantity)
                            return error.InvalidExecutionReport;
                    },
                    .partially_filled => {
                        if (report.cumulative_qty != self.filled_quantity or
                            report.remaining_qty !=
                                self.order_quantity - self.filled_quantity or
                            self.filled_quantity == 0)
                            return error.InvalidExecutionReport;
                    },
                    .filled => {
                        if (report.cumulative_qty != self.order_quantity or
                            report.remaining_qty != 0 or
                            self.filled_quantity != self.order_quantity)
                            return error.InvalidExecutionReport;
                    },
                    .canceled => {
                        if (report.cumulative_qty != self.filled_quantity or
                            report.remaining_qty !=
                                self.order_quantity - self.filled_quantity)
                            return error.InvalidExecutionReport;
                    },
                }
                const is_new = try rememberReport(
                    &self.report_facts,
                    &self.report_fact_count,
                    report,
                );
                try self.trace.append(reportEventKind(report.status), report.report_id);
                if (is_new) {
                    self.order_state = switch (report.status) {
                        .accepted => .live,
                        .partially_filled => .partially_filled,
                        .filled => .filled,
                        .canceled => .canceled,
                    };
                    if (report.status == .canceled) {
                        try self.recalculateRisk();
                        try self.trace.append(.risk_reservation_rebalanced, report.report_id);
                    }
                }
            },
            .fill => |fill| {
                if (fill.quantity <= 0 or fill.price_micros <= 0)
                    return error.InvalidFill;
                const is_new = try rememberFill(
                    &self.fill_facts,
                    &self.fill_fact_count,
                    fill,
                );
                try self.trace.append(.fill, fill.fill_id);
                if (!is_new) return null;
                try self.applyFill(fill);
                try self.trace.append(.fee_ledger_transaction, fill.fill_id);
                try self.trace.append(.risk_reservation_rebalanced, fill.fill_id);
            },
        }
        return null;
    }
};

const AdapterRequest = union(enum) {
    order_command: OrderCommand,
};

const AdapterOutputBatch = struct {
    dispatch_result: InputEvent,
    ingress: [5]InputEvent,
};

const VenueAdapter = venue_adapter.Interface(AdapterRequest, AdapterOutputBatch);

const SimulatedVenue = struct {
    const State = enum { idle, running, stopped };

    state: State = .idle,
    pending: ?AdapterOutputBatch = null,

    fn adapter(self: *SimulatedVenue) VenueAdapter {
        return .{ .ptr = self, .vtable = &.{
            .start = startOpaque,
            .try_send = trySendOpaque,
            .try_drain = tryDrainOpaque,
            .stop = stopOpaque,
        } };
    }

    fn startOpaque(ptr: *anyopaque, config: venue_adapter.Config) venue_adapter.StartError!void {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.environment != .simulation or
            config.request_capacity != 1 or config.output_capacity != 1)
            return error.InvalidConfig;
        self.state = .running;
    }

    fn trySendOpaque(
        ptr: *anyopaque,
        request: AdapterRequest,
    ) venue_adapter.SendError!venue_adapter.SendResult {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.state == .stopped) return .stopped;
        if (self.pending != null) return .backpressure;
        self.pending = switch (request) {
            .order_command => |command| makeOutput(command) catch return error.InvalidRequest,
        };
        return .accepted;
    }

    fn tryDrainOpaque(ptr: *anyopaque) venue_adapter.DrainError!?AdapterOutputBatch {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const pending = self.pending orelse return null;
        self.pending = null;
        return pending;
    }

    fn stopOpaque(
        ptr: *anyopaque,
        deadline: venue_adapter.DrainDeadline,
    ) venue_adapter.StopError!void {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        _ = deadline;
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.state = .stopped;
    }

    fn makeOutput(command: OrderCommand) !AdapterOutputBatch {
        if (command.command_id != 1 or command.order_id != 1 or
            command.quantity != happy_order_quantity or
            command.limit_price_micros != 50_100_000_000 or
            command.reservation_micros != 11_397_750 or
            !std.mem.eql(u8, command.client_id, client_order_id))
            return error.InvalidOrderCommand;

        return .{
            .dispatch_result = atGroup(15, .{
                .identity = 1,
                .payload = .{ .order_dispatch_result = .submitted },
            }),
            .ingress = .{
                atGroup(16, .{ .identity = 1, .payload = .{ .execution_report = .{
                    .report_id = 1,
                    .status = .accepted,
                    .cumulative_qty = 0,
                    .remaining_qty = 100,
                } } }),
                atGroup(17, .{ .identity = 1, .payload = .{ .fill = .{
                    .fill_id = 1,
                    .quantity = 40,
                    .price_micros = 49_900_000_000,
                } } }),
                atGroup(17, .{ .identity = 2, .payload = .{ .execution_report = .{
                    .report_id = 2,
                    .status = .partially_filled,
                    .cumulative_qty = 40,
                    .remaining_qty = 60,
                } } }),
                atGroup(18, .{ .identity = 2, .payload = .{ .fill = .{
                    .fill_id = 2,
                    .quantity = 60,
                    .price_micros = 50_100_000_000,
                } } }),
                atGroup(18, .{ .identity = 3, .payload = .{ .execution_report = .{
                    .report_id = 3,
                    .status = .filled,
                    .cumulative_qty = 100,
                    .remaining_qty = 0,
                } } }),
            },
        };
    }
};

const genesis = [_]InputEvent{
    atGroup(1, .{ .identity = 1, .payload = .instrument_rules_activated }),
    atGroup(2, .{ .identity = 1, .payload = .margin_rules_activated }),
    atGroup(3, .{ .identity = 1, .payload = .account_configuration }),
    atGroup(4, .{ .identity = 1, .payload = .exchange_balance }),
    atGroup(5, .{ .identity = 1, .payload = .exchange_positions }),
    atGroup(6, .{ .identity = 1, .payload = .opening_balance }),
    atGroup(7, .{ .identity = 1, .payload = .virtual_portfolio_activated }),
    atGroup(8, .{ .identity = 1, .payload = .portfolio_transfer }),
    atGroup(9, .{ .identity = 1, .payload = .strategy_activated }),
    atGroup(10, .{ .identity = 1, .payload = .primary_lease_granted }),
    atGroup(11, .{ .identity = 1, .payload = .risk_lease_granted }),
};

const LiveRun = struct {
    shard: TradingShard,
    decision_journal: journal.Journal,
};

fn applyLive(
    shard: *TradingShard,
    decision_journal: *journal.Journal,
    input: InputEvent,
) !?OrderCommand {
    const before = shard.trace.len;
    const command = try shard.handle(input);
    if (shard.trace.len == before) return error.InputProducedNoFact;
    const encoded_input = try encodeInput(input);

    for (shard.trace.events[before..shard.trace.len], 0..) |event, index| {
        var identity_bytes: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &identity_bytes, event.identity, .little);
        try decision_journal.append(.{
            .type_id = @intFromEnum(event.kind),
            .schema_version = schema_version,
            .flags = if (index == 0) journal.input_flag else 0,
            .sequence = event.sequence,
            .source_time = input.source_time,
            .receive_time = input.receive_time,
            .monotonic_time = input.monotonic_time,
            .wall_time = input.wall_time,
            .time_presence = input.time_presence,
            .payload = if (index == 0)
                encoded_input.bytes[0..encoded_input.len]
            else
                &identity_bytes,
        });
    }
    return command;
}

fn snapshotAt(group: u64, source_sequence: u64) InputEvent {
    return atGroup(group, .{ .identity = source_sequence, .payload = .{ .l2_snapshot = .{
        .source_sequence = source_sequence,
        .bid_price_micros = 49_800_000_000,
        .bid_quantity = 1_000,
        .ask_1_price_micros = 49_900_000_000,
        .ask_1_quantity = 40,
        .ask_2_price_micros = 50_100_000_000,
        .ask_2_quantity = 60,
    } } });
}

fn deltaAt(
    group: u64,
    previous: u64,
    current: u64,
    bid_price_micros: i64,
) InputEvent {
    return atGroup(group, .{ .identity = current, .payload = .{ .l2_delta = .{
        .previous = previous,
        .current = current,
        .bid_price_micros = bid_price_micros,
        .bid_quantity = 1_000,
    } } });
}

fn startScenario() !LiveRun {
    var run: LiveRun = .{
        .shard = .{},
        .decision_journal = journal.Journal.init(),
    };
    for (genesis) |event| {
        if (try applyLive(&run.shard, &run.decision_journal, event) != null)
            return error.UnexpectedCommand;
    }
    return run;
}

fn applyHealthyPrelude(run: *LiveRun) !void {
    const prelude = [_]InputEvent{
        atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000_000 } }),
        snapshotAt(13, 100),
        deltaAt(14, 100, 101, 49_850_000_000),
    };
    for (prelude) |event| {
        if (try applyLive(&run.shard, &run.decision_journal, event) != null)
            return error.UnexpectedCommand;
    }
}

pub const HostIngressSummary = struct {
    order_intents: usize,
    risk_accepts: usize,
    order_commands: usize,
    host_rejections: usize,
    journal_records: u64,
    order_quantity: i64,
    order_limit_price_micros: i64,
    reservation_micros: i64,
};

pub const TradingShardHostIngress = struct {
    run: LiveRun,

    pub fn initHealthyFixture() !TradingShardHostIngress {
        var run = try startScenario();
        try applyHealthyPrelude(&run);
        return .{ .run = run };
    }

    pub fn applyDecision(self: *TradingShardHostIngress, decision: host_gateway.Decision) !bool {
        const payload: Payload = switch (decision) {
            .accepted => |intent| .{ .external_order_intent = intent },
            .rejected => |rejection| .{ .strategy_intent_rejected = rejection },
        };
        const identity: u64 = switch (decision) {
            .accepted => |intent| intent.intent_sequence,
            .rejected => |rejection| rejection.intent_sequence,
        };
        return (try applyLive(
            &self.run.shard,
            &self.run.decision_journal,
            atGroup(15, .{ .identity = identity, .payload = payload }),
        )) != null;
    }

    pub fn summary(self: TradingShardHostIngress) HostIngressSummary {
        var order_intents: usize = 0;
        var risk_accepts: usize = 0;
        var order_commands: usize = 0;
        var host_rejections: usize = 0;
        for (self.run.shard.trace.events[0..self.run.shard.trace.len]) |event| switch (event.kind) {
            .order_intent => order_intents += 1,
            .risk_accepted => risk_accepts += 1,
            .order_command => order_commands += 1,
            .strategy_intent_rejected => host_rejections += 1,
            else => {},
        };
        return .{
            .order_intents = order_intents,
            .risk_accepts = risk_accepts,
            .order_commands = order_commands,
            .host_rejections = host_rejections,
            .journal_records = self.run.decision_journal.records,
            .order_quantity = self.run.shard.order_quantity,
            .order_limit_price_micros = self.run.shard.order_limit_price_micros,
            .reservation_micros = self.run.shard.open_order_reservation_micros,
        };
    }

    pub fn verifyReplay(self: *TradingShardHostIngress) !void {
        try self.run.decision_journal.seal();
        _ = try assertReplayEquivalent(self.run);
    }
};

fn finishScenario(run: *LiveRun) !LiveRun {
    try run.decision_journal.seal();
    return run.*;
}

fn runHappyPath() !LiveRun {
    var run = try startScenario();
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{
        .environment = .simulation,
        .request_capacity = 1,
        .output_capacity = 1,
    });
    try applyHealthyPrelude(&run);
    const command = (try applyLive(
        &run.shard,
        &run.decision_journal,
        atGroup(15, .{ .identity = 1, .payload = .{
            .timer = .{ .quantity = happy_order_quantity },
        } }),
    )) orelse return error.MissingOrderCommand;
    if (try adapter.trySend(.{ .order_command = command }) != .accepted)
        return error.AdapterDidNotAccept;
    const output = (try adapter.tryDrain()) orelse return error.MissingAdapterOutput;
    if (try applyLive(&run.shard, &run.decision_journal, output.dispatch_result) != null)
        return error.UnexpectedCommand;
    for (output.ingress, 0..) |event, index| {
        if (try applyLive(&run.shard, &run.decision_journal, event) != null)
            return error.UnexpectedCommand;
        if (index == 1) try assertPartialState(run.shard);
    }
    try adapter.stop(.{ .monotonic_ns = fixture_monotonic_base + 20_000_000 });
    if (try applyLive(&run.shard, &run.decision_journal, atGroup(19, .{
        .identity = 2,
        .payload = .{ .mark_price = 50_200_000_000 },
    })) != null)
        return error.UnexpectedCommand;

    return finishScenario(&run);
}

fn runMarketGap() !LiveRun {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    if (try applyLive(
        &run.shard,
        &run.decision_journal,
        deltaAt(15, 102, 103, 49_860_000_000),
    ) != null)
        return error.UnexpectedCommand;
    if (try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    })) != null)
        return error.CommandEscapedMarketGap;
    if (try applyLive(
        &run.shard,
        &run.decision_journal,
        snapshotAt(17, 200),
    ) != null)
        return error.UnexpectedCommand;
    if (try applyLive(
        &run.shard,
        &run.decision_journal,
        deltaAt(18, 200, 201, 49_850_000_000),
    ) != null)
        return error.UnexpectedCommand;
    return finishScenario(&run);
}

fn runRiskRejection() !LiveRun {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    if (try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = 100_001 } },
    })) != null)
        return error.CommandEscapedRiskRejection;
    return finishScenario(&run);
}

const LatencyHistogram = struct {
    const bucket_width_ns: u64 = 500;
    const bucket_count = 40_000;
    const tail_bucket_width_ns: u64 = std.time.ns_per_ms;
    const tail_bucket_count = 1_000;
    const primary_range_ns = bucket_width_ns * bucket_count;

    buckets: [bucket_count]u64 = @splat(0),
    tail_buckets: [tail_bucket_count]u64 = @splat(0),
    samples: u64 = 0,
    overflow: u64 = 0,
    max_ns: u64 = 0,

    fn record(self: *LatencyHistogram, nanoseconds: u64) void {
        self.samples += 1;
        self.max_ns = @max(self.max_ns, nanoseconds);
        const index = nanoseconds / bucket_width_ns;
        if (index < self.buckets.len) {
            self.buckets[index] += 1;
            return;
        }
        const tail_index = (nanoseconds - primary_range_ns) / tail_bucket_width_ns;
        if (tail_index < self.tail_buckets.len)
            self.tail_buckets[tail_index] += 1
        else
            self.overflow += 1;
    }

    fn percentile(self: *const LatencyHistogram, numerator: u64, denominator: u64) !u64 {
        if (self.samples == 0 or self.overflow != 0) return error.InvalidHistogram;
        const target = @divFloor(self.samples * numerator + denominator - 1, denominator);
        var seen: u64 = 0;
        for (self.buckets, 0..) |count, index| {
            seen += count;
            if (seen >= target) return (index + 1) * bucket_width_ns;
        }
        for (self.tail_buckets, 0..) |count, index| {
            seen += count;
            if (seen >= target)
                return primary_range_ns + (index + 1) * tail_bucket_width_ns;
        }
        return error.InvalidHistogram;
    }

    fn merge(self: *LatencyHistogram, other: *const LatencyHistogram) void {
        for (&self.buckets, other.buckets) |*destination, count| destination.* += count;
        for (&self.tail_buckets, other.tail_buckets) |*destination, count|
            destination.* += count;
        self.samples += other.samples;
        self.overflow += other.overflow;
        self.max_ns = @max(self.max_ns, other.max_ns);
    }
};

const BenchmarkTelemetry = struct {
    events: u64 = 0,
    commands: u64 = 0,
    correctness_failures: u64 = 0,
    queue_current: usize = 0,
    queue_high_water: usize = 0,
    queue_capacity: usize,

    fn enqueue(self: *BenchmarkTelemetry) !void {
        if (self.queue_current == self.queue_capacity) return error.BenchmarkQueueFull;
        self.queue_current += 1;
        self.queue_high_water = @max(self.queue_high_water, self.queue_current);
    }

    fn dequeue(self: *BenchmarkTelemetry) void {
        std.debug.assert(self.queue_current > 0);
        self.queue_current -= 1;
    }
};

const BenchmarkResult = struct {
    name: []const u8,
    histogram: LatencyHistogram,
    telemetry: BenchmarkTelemetry,
    elapsed_ns: u64,
};

const MarketBenchmarkWork = struct {
    input: InputEvent,
    enqueued_ns: u64,
};

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn initializedBenchmarkRun() !LiveRun {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    run.shard.trace.len = 0;
    run.decision_journal = journal.Journal.init();
    return run;
}

fn runMarketBenchmark(
    io: std.Io,
    name: []const u8,
    samples: usize,
    burst_size: usize,
) !BenchmarkResult {
    const queue_capacity = 128;
    if (burst_size == 0 or burst_size > queue_capacity) return error.InvalidBurstSize;
    var run = try initializedBenchmarkRun();
    var queued: [queue_capacity]MarketBenchmarkWork = undefined;
    var histogram: LatencyHistogram = .{};
    var telemetry: BenchmarkTelemetry = .{ .queue_capacity = queue_capacity };
    var source_sequence: u64 = 101;
    var completed: usize = 0;
    const run_started = nowNs(io);

    while (completed < samples) {
        const batch_size = @min(burst_size, samples - completed);
        if (run.shard.trace.len + batch_size > run.shard.trace.events.len) {
            run.shard.trace.len = 0;
            run.decision_journal = journal.Journal.init();
        }
        const journal_records_before = run.decision_journal.records;
        for (queued[0..batch_size]) |*work| {
            const previous = source_sequence;
            source_sequence += 1;
            work.* = .{
                .input = deltaAt(
                    15 + source_sequence,
                    previous,
                    source_sequence,
                    49_850_000_000 + @as(i64, @intCast(source_sequence % 10)),
                ),
                .enqueued_ns = nowNs(io),
            };
            try telemetry.enqueue();
        }
        for (queued[0..batch_size], 0..) |work, index| {
            if (try applyLive(&run.shard, &run.decision_journal, work.input) != null)
                return error.UnexpectedCommand;
            const finished_ns = nowNs(io);
            histogram.record(finished_ns - work.enqueued_ns);
            telemetry.dequeue();
            telemetry.events += 1;
            if (run.shard.market_health != .healthy or
                run.shard.expected_source_sequence != source_sequence - batch_size + index + 1 or
                run.decision_journal.records != journal_records_before + index + 1)
                return error.BenchmarkCorrectnessFailure;
        }
        completed += batch_size;
    }
    return .{
        .name = name,
        .histogram = histogram,
        .telemetry = telemetry,
        .elapsed_ns = nowNs(io) - run_started,
    };
}

const OrderBenchmarkWork = struct {
    shard: TradingShard,
    decision_journal: journal.Journal,
    input: InputEvent,
    enqueued_ns: u64,
};

fn runOrderBenchmark(io: std.Io, samples: usize, burst_size: usize) !BenchmarkResult {
    const queue_capacity = 16;
    if (burst_size == 0 or burst_size > queue_capacity) return error.InvalidBurstSize;
    const base = try initializedBenchmarkRun();
    var queued: [queue_capacity]OrderBenchmarkWork = undefined;
    var histogram: LatencyHistogram = .{};
    var telemetry: BenchmarkTelemetry = .{ .queue_capacity = queue_capacity };
    var completed: usize = 0;
    const run_started = nowNs(io);

    while (completed < samples) {
        const batch_size = @min(burst_size, samples - completed);
        for (queued[0..batch_size], 0..) |*work, index| {
            work.* = .{
                .shard = base.shard,
                .decision_journal = journal.Journal.init(),
                .input = atGroup(completed + index + 15, .{
                    .identity = completed + index + 1,
                    .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
                }),
                .enqueued_ns = nowNs(io),
            };
            try telemetry.enqueue();
        }
        for (queued[0..batch_size]) |*work| {
            const command = (try applyLive(
                &work.shard,
                &work.decision_journal,
                work.input,
            )) orelse return error.MissingOrderCommand;
            const finished_ns = nowNs(io);
            histogram.record(finished_ns - work.enqueued_ns);
            telemetry.dequeue();
            telemetry.events += 1;
            telemetry.commands += 1;
            if (command.reservation_micros != 11_397_750 or
                work.shard.order_state != .pending_submit or
                work.decision_journal.records != 5)
                return error.BenchmarkCorrectnessFailure;
        }
        completed += batch_size;
    }
    return .{
        .name = "order-burst",
        .histogram = histogram,
        .telemetry = telemetry,
        .elapsed_ns = nowNs(io) - run_started,
    };
}

fn runRecoveryBenchmark(io: std.Io, samples: usize) !BenchmarkResult {
    var run = try initializedBenchmarkRun();
    var histogram: LatencyHistogram = .{};
    var telemetry: BenchmarkTelemetry = .{ .queue_capacity = 6 };
    var completed: usize = 0;
    var source_sequence: u64 = 101;
    const run_started = nowNs(io);

    while (completed < samples) {
        const cycle = @min(@as(usize, 3), samples - completed);
        const snapshot_sequence = source_sequence + 100;
        const inputs = [_]InputEvent{
            deltaAt(15 + completed, source_sequence + 1, source_sequence + 2, 49_860_000_000),
            snapshotAt(16 + completed, snapshot_sequence),
            deltaAt(
                17 + completed,
                snapshot_sequence,
                snapshot_sequence + 1,
                49_850_000_000,
            ),
        };
        run.shard.trace.len = 0;
        run.decision_journal = journal.Journal.init();
        var enqueued: [3]u64 = undefined;
        for (inputs[0..cycle], 0..) |_, index| {
            enqueued[index] = nowNs(io);
            try telemetry.enqueue();
        }
        for (inputs[0..cycle], 0..) |input, index| {
            if (try applyLive(&run.shard, &run.decision_journal, input) != null)
                return error.UnexpectedCommand;
            histogram.record(nowNs(io) - enqueued[index]);
            telemetry.dequeue();
            telemetry.events += 1;
            const expected_records = [_]u64{ 2, 3, 5 };
            if (run.decision_journal.records != expected_records[index])
                return error.BenchmarkCorrectnessFailure;
        }
        source_sequence = snapshot_sequence + 1;
        completed += cycle;
    }
    if (run.shard.market_health != .healthy) return error.RecoveryDidNotComplete;
    return .{
        .name = "exception-recovery",
        .histogram = histogram,
        .telemetry = telemetry,
        .elapsed_ns = nowNs(io) - run_started,
    };
}

fn printBenchmarkResult(
    out: *std.Io.Writer,
    result: *const BenchmarkResult,
    raw: bool,
) !void {
    const throughput = @divFloor(
        result.telemetry.events * std.time.ns_per_s,
        result.elapsed_ns,
    );
    try out.print(
        "{s}: samples={d} p50_ns={d} p99_ns={d} p999_ns={d} max_ns={d} throughput_eps={d} queue_hwm={d}/{d} overflow={d} correctness_failures={d}\n",
        .{
            result.name,
            result.histogram.samples,
            try result.histogram.percentile(50, 100),
            try result.histogram.percentile(99, 100),
            try result.histogram.percentile(999, 1000),
            result.histogram.max_ns,
            throughput,
            result.telemetry.queue_high_water,
            result.telemetry.queue_capacity,
            result.histogram.overflow,
            result.telemetry.correctness_failures,
        },
    );
    if (raw) {
        try out.print("{s}.raw_bucket_ns_upper=count:", .{result.name});
        for (result.histogram.buckets, 0..) |count, index| {
            if (count != 0) try out.print(" {d}={d}", .{
                (index + 1) * LatencyHistogram.bucket_width_ns,
                count,
            });
        }
        for (result.histogram.tail_buckets, 0..) |count, index| {
            if (count != 0) try out.print(" {d}={d}", .{
                LatencyHistogram.primary_range_ns +
                    (index + 1) * LatencyHistogram.tail_bucket_width_ns,
                count,
            });
        }
        try out.writeByte('\n');
    }
}

fn benchmark(init: std.process.Init, raw: bool) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;

    _ = try runMarketBenchmark(init.io, "warmup", benchmark_warmup, 1);
    const steady = try runMarketBenchmark(init.io, "steady", benchmark_samples, 1);
    const market_burst = try runMarketBenchmark(
        init.io,
        "market-burst",
        benchmark_samples,
        64,
    );
    const order_burst = try runOrderBenchmark(init.io, benchmark_samples, 8);
    const recovery = try runRecoveryBenchmark(init.io, benchmark_samples + 2);
    try out.print(
        "single_shard_benchmark: zig={s} mode={s} os={s} samples_per_scenario={d} timer=monotonic queue=bounded journal=crc32c telemetry=fixed_histogram correctness=continuous network=excluded\n",
        .{
            builtin.zig_version_string,
            @tagName(builtin.mode),
            @tagName(builtin.os.tag),
            benchmark_samples,
        },
    );
    try printBenchmarkResult(out, &steady, raw);
    try printBenchmarkResult(out, &market_burst, raw);
    try printBenchmarkResult(out, &order_burst, raw);
    try printBenchmarkResult(out, &recovery, raw);
    try out.flush();
}

const ShardInbox = struct {
    const capacity = 8;

    events: [capacity]InputEvent = undefined,
    head: usize = 0,
    len: usize = 0,
    high_water: usize = 0,

    fn push(self: *ShardInbox, event: InputEvent) !void {
        if (self.len == self.events.len) return error.ShardQueueFull;
        self.events[(self.head + self.len) % self.events.len] = event;
        self.len += 1;
        self.high_water = @max(self.high_water, self.len);
    }

    fn pop(self: *ShardInbox) ?InputEvent {
        if (self.len == 0) return null;
        const event = self.events[self.head];
        self.head = (self.head + 1) % self.events.len;
        self.len -= 1;
        return event;
    }
};

const QualifiedShard = struct {
    decision_domain: u8,
    run: LiveRun,
    inbox: ShardInbox = .{},
};

const SharedMarketRouter = struct {
    normalized_events: u64 = 0,
    routed_deliveries: u64 = 0,

    fn route(
        self: *SharedMarketRouter,
        shards: *[4]QualifiedShard,
        target_domain: u8,
        normalized_event: InputEvent,
    ) !void {
        self.normalized_events += 1;
        if (target_domain >= shards.len) return error.UnknownDecisionDomain;
        try shards[target_domain].inbox.push(normalized_event);
        self.routed_deliveries += 1;
    }
};

fn drainOne(shard: *QualifiedShard) !void {
    const input = shard.inbox.pop() orelse return error.EmptyShardQueue;
    if (try applyLive(&shard.run.shard, &shard.run.decision_journal, input) != null)
        return error.UnexpectedCommand;
}

fn assertFourShardIsolation() ![4][Sha256.digest_length]u8 {
    var digests: [4][Sha256.digest_length]u8 = undefined;
    for (&digests) |*digest| {
        const run = try runHappyPath();
        digest.* = try assertReplayEquivalent(run);
        try assertExpectedDigest(digest.*, expected_happy_digest);
    }

    var shards: [4]QualifiedShard = undefined;
    for (&shards, 0..) |*shard, index| {
        shard.* = .{
            .decision_domain = @intCast(index),
            .run = try initializedBenchmarkRun(),
        };
    }
    var router: SharedMarketRouter = .{};

    try router.route(
        &shards,
        0,
        deltaAt(15, 102, 103, 49_860_000_000),
    );
    try drainOne(&shards[0]);
    if (shards[0].run.shard.market_health != .gap or
        shards[0].run.shard.trace.len != 2)
        return error.GapIsolationFailed;

    try shards[0].inbox.push(atGroup(16, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }));
    while (shards[0].inbox.len < ShardInbox.capacity) {
        try shards[0].inbox.push(deltaAt(16, 103, 104, 49_860_000_000));
    }
    if (shards[0].inbox.push(deltaAt(17, 104, 105, 49_860_000_000))) |_|
        return error.QueueSaturationNotDetected
    else |err| if (err != error.ShardQueueFull) return err;

    for (1..4) |index| {
        try router.route(
            &shards,
            @intCast(index),
            deltaAt(15, 101, 102, 49_850_000_000 + @as(i64, @intCast(index))),
        );
    }
    for (1..4) |index| try drainOne(&shards[index]);

    if (router.normalized_events != 4 or router.routed_deliveries != 4 or
        shards[0].inbox.len != ShardInbox.capacity or
        shards[0].inbox.high_water != ShardInbox.capacity)
        return error.RouterIsolationFailed;
    for (1..4) |index| {
        if (shards[index].run.shard.market_health != .healthy or
            shards[index].run.shard.expected_source_sequence != 102 or
            shards[index].run.shard.trace.len != 1 or
            shards[index].run.decision_journal.records != 1 or
            shards[index].inbox.len != 0)
            return error.HealthyShardWasAffected;
    }
    return digests;
}

const FourShardWorker = struct {
    io: std.Io,
    queue: *SpscQueue,
    ready: *std.atomic.Value(u8),
    start: *std.atomic.Value(bool),
    result: ?BenchmarkResult = null,
    failure: ?anyerror = null,

    fn run(self: *FourShardWorker) void {
        _ = runMarketBenchmark(self.io, "warmup", benchmark_warmup, 1) catch |err| {
            self.failure = err;
            _ = self.ready.fetchAdd(1, .release);
            return;
        };
        _ = self.ready.fetchAdd(1, .release);
        while (!self.start.load(.acquire)) std.Thread.yield() catch {};
        self.result = runRoutedShardBenchmark(self) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const SpscQueue = struct {
    const capacity = 4_096;

    items: [capacity]MarketBenchmarkWork = undefined,
    read_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    write_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    high_water: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    full_observations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn push(self: *SpscQueue, work: MarketBenchmarkWork) bool {
        const write_index = self.write_index.load(.monotonic);
        const read_index = self.read_index.load(.acquire);
        if (write_index - read_index == self.items.len) {
            _ = self.full_observations.fetchAdd(1, .monotonic);
            return false;
        }
        self.items[write_index % self.items.len] = work;
        self.write_index.store(write_index + 1, .release);
        _ = self.high_water.fetchMax(write_index - read_index + 1, .monotonic);
        return true;
    }

    fn pop(self: *SpscQueue) ?MarketBenchmarkWork {
        const read_index = self.read_index.load(.monotonic);
        const write_index = self.write_index.load(.acquire);
        if (read_index == write_index) return null;
        const work = self.items[read_index % self.items.len];
        self.read_index.store(read_index + 1, .release);
        return work;
    }
};

fn runRoutedShardBenchmark(worker: *FourShardWorker) !BenchmarkResult {
    var run = try initializedBenchmarkRun();
    var histogram: LatencyHistogram = .{};
    var telemetry: BenchmarkTelemetry = .{ .queue_capacity = SpscQueue.capacity };
    var expected_source_sequence: u64 = 101;
    const started_ns = nowNs(worker.io);

    while (telemetry.events < benchmark_samples) {
        const work = worker.queue.pop() orelse {
            std.Thread.yield() catch {};
            continue;
        };
        if (run.shard.trace.len == run.shard.trace.events.len) {
            run.shard.trace.len = 0;
            run.decision_journal = journal.Journal.init();
        }
        const records_before = run.decision_journal.records;
        if (try applyLive(&run.shard, &run.decision_journal, work.input) != null)
            return error.UnexpectedCommand;
        histogram.record(nowNs(worker.io) - work.enqueued_ns);
        telemetry.events += 1;
        expected_source_sequence += 1;
        if (run.shard.market_health != .healthy or
            run.shard.expected_source_sequence != expected_source_sequence or
            run.decision_journal.records != records_before + 1)
            return error.BenchmarkCorrectnessFailure;
    }
    telemetry.queue_high_water = worker.queue.high_water.load(.acquire);
    return .{
        .name = "four-shard-routed",
        .histogram = histogram,
        .telemetry = telemetry,
        .elapsed_ns = nowNs(worker.io) - started_ns,
    };
}

fn percentChangeBasisPoints(current: u64, baseline: u64) i64 {
    return @intCast(@divTrunc(
        (@as(i128, current) - baseline) * 10_000,
        baseline,
    ));
}

fn benchmarkFourShards(init: std.process.Init, raw: bool) !void {
    const target_events_per_second: u64 = 2_000_000;
    const digests = try assertFourShardIsolation();
    const single = try runMarketBenchmark(
        init.io,
        "single-shard-reference",
        benchmark_samples,
        1,
    );

    var ready = std.atomic.Value(u8).init(0);
    var start = std.atomic.Value(bool).init(false);
    const workers = try init.gpa.alloc(FourShardWorker, 4);
    defer init.gpa.free(workers);
    const queues = try init.gpa.alloc(SpscQueue, 4);
    defer init.gpa.free(queues);
    for (queues) |*queue| queue.* = .{};
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        start.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (workers, 0..) |*worker, index| {
        worker.* = .{
            .io = init.io,
            .queue = &queues[index],
            .ready = &ready,
            .start = &start,
        };
        threads[index] = try std.Thread.spawn(
            .{ .stack_size = 2 * 1024 * 1024 },
            FourShardWorker.run,
            .{worker},
        );
        spawned += 1;
    }
    while (ready.load(.acquire) != 4) std.Thread.yield() catch {};
    for (workers) |*worker| if (worker.failure) |err| return err;

    const started_ns = nowNs(init.io);
    start.store(true, .release);
    var source_sequences: [4]u64 = @splat(101);
    var routed_events: u64 = 0;
    var producer_late_max_ns: u64 = 0;
    while (routed_events < 4 * benchmark_samples) : (routed_events += 1) {
        const scheduled_ns = started_ns +
            @divFloor(routed_events * std.time.ns_per_s, target_events_per_second);
        var actual_ns = nowNs(init.io);
        while (actual_ns < scheduled_ns) {
            std.atomic.spinLoopHint();
            actual_ns = nowNs(init.io);
        }
        producer_late_max_ns = @max(producer_late_max_ns, actual_ns - scheduled_ns);
        const target: usize = @intCast(routed_events % 4);
        const previous = source_sequences[target];
        source_sequences[target] += 1;
        const work: MarketBenchmarkWork = .{
            .input = deltaAt(
                15 + routed_events,
                previous,
                source_sequences[target],
                49_850_000_000 + @as(i64, @intCast(routed_events % 10)),
            ),
            .enqueued_ns = actual_ns,
        };
        while (!queues[target].push(work)) std.Thread.yield() catch {};
    }
    for (threads) |thread| thread.join();
    spawned = 0;
    const elapsed_ns = nowNs(init.io) - started_ns;

    var merged: LatencyHistogram = .{};
    var total_events: u64 = 0;
    for (workers) |*worker| {
        if (worker.failure) |err| return err;
        const result = worker.result orelse return error.MissingShardBenchmarkResult;
        merged.merge(&result.histogram);
        total_events += result.telemetry.events;
    }
    const aggregate_throughput = @divFloor(
        total_events * std.time.ns_per_s,
        elapsed_ns,
    );
    const single_p99 = try single.histogram.percentile(99, 100);
    const merged_p99 = try merged.percentile(99, 100);
    const single_throughput = @divFloor(
        single.telemetry.events * std.time.ns_per_s,
        single.elapsed_ns,
    );
    const owned_bytes_per_shard = @sizeOf(TradingShard) +
        @sizeOf(journal.Journal) +
        @sizeOf(SpscQueue) +
        @sizeOf(LatencyHistogram) +
        @sizeOf(BenchmarkTelemetry);
    var queue_full_observations: u64 = 0;
    for (queues) |*queue|
        queue_full_observations += queue.full_observations.load(.acquire);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    try out.print(
        "four_shard_qualification: zig={s} mode={s} os={s} shards=4 samples_per_shard={d} shared_router=1 execution_gateway_scope=shared_periphery risk_allocator_scope=shared_periphery correctness=continuous network=excluded\n",
        .{
            builtin.zig_version_string,
            @tagName(builtin.mode),
            @tagName(builtin.os.tag),
            benchmark_samples,
        },
    );
    for (digests, 0..) |digest, index| {
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        try out.print(
            "shard={d} decision_domain={d} replay=equivalent digest={s}\n",
            .{ index, index, &digest_hex },
        );
    }
    try out.print(
        "isolation=ok targeted_fanout=ok stalled_shard=0 gap_local=ok queue_saturation_local=ok healthy_shards_ordered=3\n",
        .{},
    );
    try printBenchmarkResult(out, &single, raw);
    for (workers) |*worker|
        try printBenchmarkResult(out, &worker.result.?, raw);
    try out.print(
        "four_shard_merged: samples={d} target_throughput_eps={d} p50_ns={d} p99_ns={d} p999_ns={d} max_ns={d} aggregate_throughput_eps={d} producer_late_max_ns={d} p99_change_bp={d} throughput_change_bp={d} queue_full_observations={d} core_state_bytes={d} journal_bytes={d} queue_bytes={d} histogram_bytes={d} owned_bytes_per_shard={d} owned_bytes_four={d}\n",
        .{
            merged.samples,
            target_events_per_second,
            try merged.percentile(50, 100),
            merged_p99,
            try merged.percentile(999, 1000),
            merged.max_ns,
            aggregate_throughput,
            producer_late_max_ns,
            percentChangeBasisPoints(merged_p99, single_p99),
            percentChangeBasisPoints(aggregate_throughput, single_throughput),
            queue_full_observations,
            @sizeOf(TradingShard),
            @sizeOf(journal.Journal),
            @sizeOf(SpscQueue),
            @sizeOf(LatencyHistogram),
            owned_bytes_per_shard,
            owned_bytes_per_shard * 4,
        },
    );
    try out.flush();
}

fn runUnknownReconciliation() !LiveRun {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    _ = (try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }))) orelse return error.MissingOrderCommand;
    if (try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{
        .identity = 1,
        .payload = .{ .order_dispatch_result = .unknown },
    })) != null)
        return error.UnexpectedCommand;
    if (try applyLive(&run.shard, &run.decision_journal, atGroup(17, .{
        .identity = 1,
        .payload = .{ .order_reconciliation_result = .{
            .reconciliation_id = 1,
            .status = .found_live,
            .venue_order_id = 9_001,
        } },
    })) != null)
        return error.UnexpectedCommand;
    if (try applyLive(&run.shard, &run.decision_journal, atGroup(17, .{
        .identity = 1,
        .payload = .{ .execution_report = .{
            .report_id = 1,
            .status = .accepted,
            .cumulative_qty = 0,
            .remaining_qty = happy_order_quantity,
        } },
    })) != null)
        return error.UnexpectedCommand;
    return finishScenario(&run);
}

fn duplicateAtGroup(group: u64, original: InputEvent) InputEvent {
    var duplicate = atGroup(group, original);
    duplicate.source_time = original.source_time;
    return duplicate;
}

fn runDuplicateReport() !LiveRun {
    var run = try startScenario();
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{
        .environment = .simulation,
        .request_capacity = 1,
        .output_capacity = 1,
    });
    try applyHealthyPrelude(&run);
    const command = (try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }))) orelse return error.MissingOrderCommand;
    if (try adapter.trySend(.{ .order_command = command }) != .accepted)
        return error.AdapterDidNotAccept;
    const output = (try adapter.tryDrain()) orelse return error.MissingAdapterOutput;
    if (try applyLive(&run.shard, &run.decision_journal, output.dispatch_result) != null)
        return error.UnexpectedCommand;
    for (output.ingress[0..3]) |event| {
        if (try applyLive(&run.shard, &run.decision_journal, event) != null)
            return error.UnexpectedCommand;
    }
    try assertPartialState(run.shard);
    if (try applyLive(
        &run.shard,
        &run.decision_journal,
        duplicateAtGroup(18, output.ingress[1]),
    ) != null)
        return error.UnexpectedCommand;
    if (try applyLive(
        &run.shard,
        &run.decision_journal,
        duplicateAtGroup(18, output.ingress[2]),
    ) != null)
        return error.UnexpectedCommand;
    try assertPartialState(run.shard);
    if (run.shard.ledger_transaction_count != 2)
        return error.DuplicateCreatedLedgerTransaction;

    if (try applyLive(
        &run.shard,
        &run.decision_journal,
        atGroup(19, output.ingress[3]),
    ) != null)
        return error.UnexpectedCommand;
    if (try applyLive(
        &run.shard,
        &run.decision_journal,
        atGroup(19, output.ingress[4]),
    ) != null)
        return error.UnexpectedCommand;
    if (try applyLive(&run.shard, &run.decision_journal, atGroup(20, .{
        .identity = 2,
        .payload = .{ .mark_price = 50_200_000_000 },
    })) != null)
        return error.UnexpectedCommand;
    try adapter.stop(.{ .monotonic_ns = fixture_monotonic_base + 20_000_000 });
    return finishScenario(&run);
}

fn assertPartialState(shard: TradingShard) !void {
    if (shard.portfolio_position.quantity != 40 or
        shard.portfolio_position.open_cost_micros != 199_600_000 or
        shard.exchange_position.quantity != 40 or
        shard.exchange_position.open_cost_micros != 199_600_000 or
        shard.total_fees_micros != 149_700 or
        shard.portfolio_cash_micros != 19_999_850_300 or
        shard.exchange_cash_micros != 24_999_850_300 or
        shard.position_margin_requirement_micros != 4_400_000 or
        shard.open_order_reservation_micros != 6_838_650 or
        shard.risk_lease_remaining_micros != 9_988_761_350)
        return error.PartialEconomicProjectionMismatch;
}

fn sameTrace(left: Trace, right: Trace) bool {
    if (left.len != right.len) return false;
    for (left.events[0..left.len], right.events[0..right.len]) |a, b| {
        if (a.sequence != b.sequence or a.kind != b.kind or a.identity != b.identity)
            return false;
    }
    return true;
}

fn digestInt(hasher: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

fn digestBool(hasher: *Sha256, value: bool) void {
    digestInt(hasher, u8, @intFromBool(value));
}

fn stateDigest(shard: TradingShard) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("StateDigestV1\x00");
    digestInt(&hasher, u16, schema_version);
    digestInt(&hasher, u32, shard.instrument_rules_version);
    digestInt(&hasher, u32, shard.margin_rules_version);
    digestBool(&hasher, shard.account_configured);
    digestBool(&hasher, shard.virtual_portfolio_active);
    digestBool(&hasher, shard.strategy_active);
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
    digestInt(&hasher, u64, shard.reconciliation_id);
    digestInt(&hasher, u64, shard.venue_order_id);
    digestInt(&hasher, u8, @intFromEnum(shard.last_reject_reason));
    digestInt(&hasher, i64, shard.last_risk_required_micros);
    digestInt(&hasher, u8, shard.last_risk_tier);
    digestBool(&hasher, shard.order_id != 0);
    if (shard.order_id != 0) {
        digestInt(&hasher, u16, client_order_id.len);
        hasher.update(client_order_id);
    }
    digestInt(&hasher, i64, shard.filled_quantity);
    digestInt(&hasher, u64, shard.fill_fact_count);
    for (shard.fill_facts[0..shard.fill_fact_count]) |fill| {
        digestInt(&hasher, u64, fill.fill_id);
        digestInt(&hasher, i64, fill.quantity);
        digestInt(&hasher, i64, fill.price_micros);
    }
    digestInt(&hasher, u64, shard.report_fact_count);
    for (shard.report_facts[0..shard.report_fact_count]) |report| {
        digestInt(&hasher, u64, report.report_id);
        digestInt(&hasher, u8, @intFromEnum(report.status));
        digestInt(&hasher, i64, report.cumulative_qty);
        digestInt(&hasher, i64, report.remaining_qty);
    }
    digestInt(&hasher, i64, shard.mark_price_micros);
    digestInt(&hasher, i64, shard.portfolio_position.quantity);
    digestInt(&hasher, i64, shard.portfolio_position.open_cost_micros);
    digestInt(&hasher, i64, shard.exchange_position.quantity);
    digestInt(&hasher, i64, shard.exchange_position.open_cost_micros);
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
    digestInt(&hasher, u64, shard.ledger_transaction_count);
    digestInt(&hasher, u64, shard.portfolio_transfer_count);
    digestInt(&hasher, i64, shard.portfolio_ledger_debits_micros);
    digestInt(&hasher, i64, shard.portfolio_ledger_credits_micros);
    digestInt(&hasher, i64, shard.exchange_ledger_debits_micros);
    digestInt(&hasher, i64, shard.exchange_ledger_credits_micros);
    digestBool(&hasher, shard.economic_projections_complete);
    return hasher.finalResult();
}

const ReplayResult = struct {
    shard: TradingShard,
    status: journal.ScanStatus,
};

fn validateReplayRecord(
    record: journal.Record,
    expected: Event,
    input: InputEvent,
    is_input: bool,
) !void {
    if (record.schema_version != schema_version) return error.UnsupportedSchema;
    const kind = std.enums.fromInt(EventKind, record.type_id) orelse
        return error.UnknownEventType;
    if (record.sequence != expected.sequence or kind != expected.kind or
        try eventIdentity(record.payload) != expected.identity)
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

fn replay(bytes: []const u8) !ReplayResult {
    var reader = try journal.Reader.init(bytes);
    var shard: TradingShard = .{};

    while (true) {
        const next = try reader.next();
        const first_record = switch (next) {
            .end => |status| return .{ .shard = shard, .status = status },
            .record => |record| record,
        };
        if (first_record.flags != journal.input_flag) return error.OrphanDerivedFact;
        const input = try decodeInput(first_record);

        var candidate = shard;
        const before = candidate.trace.len;
        _ = try candidate.handle(input);
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

fn assertReplayEquivalent(run: LiveRun) ![Sha256.digest_length]u8 {
    const live_digest = stateDigest(run.shard);
    const replayed = try replay(run.decision_journal.bytes());
    if (replayed.status != .clean or
        !sameTrace(run.shard.trace, replayed.shard.trace) or
        !std.mem.eql(u8, &live_digest, &stateDigest(replayed.shard)))
        return error.ReplayNotEquivalent;
    return live_digest;
}

fn assertExpectedDigest(
    digest: [Sha256.digest_length]u8,
    expected_hex: []const u8,
) !void {
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual_hex, expected_hex))
        return error.UnexpectedStateDigest;
}

fn selfCheck() !LiveRun {
    try journal.selfCheck();
    const first = try runHappyPath();
    const second = try runHappyPath();
    if (!sameTrace(first.shard.trace, second.shard.trace))
        return error.NonDeterministicTrace;
    const first_digest = stateDigest(first.shard);
    const second_digest = stateDigest(second.shard);
    if (!std.mem.eql(u8, &first_digest, &second_digest))
        return error.NonDeterministicStateDigest;
    try assertExpectedDigest(first_digest, expected_happy_digest);

    const replayed = try replay(first.decision_journal.bytes());
    if (replayed.status != .clean or
        !sameTrace(first.shard.trace, replayed.shard.trace) or
        !std.mem.eql(u8, &first_digest, &stateDigest(replayed.shard)))
        return error.ReplayNotEquivalent;

    const truncated_footer = try replay(
        first.decision_journal.bytes()[0 .. first.decision_journal.len - 1],
    );
    if (truncated_footer.status != .truncated_tail or
        !std.mem.eql(u8, &first_digest, &stateDigest(truncated_footer.shard)))
        return error.TruncatedFooterRecoveryMismatch;
    const truncated_record = try replay(
        first.decision_journal.bytes()[0 .. first.decision_journal.len - 40],
    );
    if (truncated_record.status != .truncated_tail or truncated_record.shard.trace.len != 30)
        return error.TruncatedRecordRecoveryMismatch;

    var corrupted = first.decision_journal;
    corrupted.storage[journal.segment_header_size + journal.record_header_size] ^= 1;
    try expectReplayError(corrupted.bytes(), error.InvalidPayloadChecksum);

    var live_reader = try journal.Reader.init(first.decision_journal.bytes());
    const first_record = switch (try live_reader.next()) {
        .record => |record| record,
        .end => return error.MissingFirstRecord,
    };
    var unknown_schema = journal.Journal.init();
    var schema_two = first_record;
    schema_two.schema_version = 2;
    try unknown_schema.append(schema_two);
    try unknown_schema.seal();
    try expectReplayError(unknown_schema.bytes(), error.UnsupportedSchema);

    const market_gap = try runMarketGap();
    try assertExpectedDigest(
        try assertReplayEquivalent(market_gap),
        expected_market_gap_digest,
    );
    if (market_gap.shard.trace.len != 23 or
        market_gap.shard.market_health != .healthy or
        market_gap.shard.expected_source_sequence != 201 or
        market_gap.shard.last_reject_reason != .market_data_gap or
        market_gap.shard.order_state != .none or
        market_gap.shard.order_counter != 0 or
        market_gap.shard.open_order_reservation_micros != 0 or
        market_gap.shard.risk_lease_remaining_micros != risk_lease_total or
        market_gap.shard.portfolio_position.quantity != 0 or
        market_gap.shard.total_fees_micros != 0)
        return error.MarketGapTraceMismatch;

    const risk_rejection = try runRiskRejection();
    try assertExpectedDigest(
        try assertReplayEquivalent(risk_rejection),
        expected_risk_rejection_digest,
    );
    if (risk_rejection.shard.trace.len != 18 or
        risk_rejection.shard.last_reject_reason != .global_risk_lease_exceeded or
        risk_rejection.shard.last_risk_tier != 2 or
        risk_rejection.shard.last_risk_required_micros != 11_397_863_978 or
        risk_rejection.shard.order_state != .none or
        risk_rejection.shard.order_counter != 0 or
        risk_rejection.shard.open_order_reservation_micros != 0 or
        risk_rejection.shard.risk_lease_remaining_micros != risk_lease_total)
        return error.RiskRejectionTraceMismatch;

    const unknown = try runUnknownReconciliation();
    try assertExpectedDigest(
        try assertReplayEquivalent(unknown),
        expected_unknown_digest,
    );
    if (unknown.shard.trace.len != 23 or unknown.shard.order_state != .live or
        unknown.shard.order_counter != 1 or unknown.shard.dispatch_attempt_count != 1 or
        unknown.shard.reconciliation_id != 1 or unknown.shard.venue_order_id != 9_001 or
        unknown.shard.open_order_reservation_micros != 11_397_750 or
        unknown.shard.risk_lease_remaining_micros != 9_988_602_250 or
        unknown.shard.portfolio_position.quantity != 0 or
        unknown.shard.total_fees_micros != 0)
        return error.UnknownReconciliationTraceMismatch;

    var duplicate_reconciliation = unknown.shard;
    const before_reconciliation_reservation =
        duplicate_reconciliation.open_order_reservation_micros;
    if (try duplicate_reconciliation.handle(atGroup(18, .{
        .identity = 1,
        .payload = .{ .order_reconciliation_result = .{
            .reconciliation_id = 1,
            .status = .found_live,
            .venue_order_id = 9_001,
        } },
    })) != null)
        return error.UnexpectedCommand;
    if (duplicate_reconciliation.order_state != .live or
        duplicate_reconciliation.open_order_reservation_micros !=
            before_reconciliation_reservation)
        return error.DuplicateReconciliationChangedState;

    var canceled = unknown.shard;
    const cancel_report = atGroup(18, .{
        .identity = 2,
        .payload = .{ .execution_report = .{
            .report_id = 2,
            .status = .canceled,
            .cumulative_qty = 0,
            .remaining_qty = happy_order_quantity,
        } },
    });
    if (try canceled.handle(cancel_report) != null) return error.UnexpectedCommand;
    if (canceled.order_state != .canceled or
        canceled.open_order_reservation_micros != 0 or
        canceled.risk_lease_remaining_micros != risk_lease_total)
        return error.CancelDidNotReleaseReservation;
    const cancel_trace_len = canceled.trace.len;
    if (try canceled.handle(duplicateAtGroup(19, cancel_report)) != null)
        return error.UnexpectedCommand;
    if (canceled.trace.len != cancel_trace_len + 1 or
        canceled.order_state != .canceled or
        canceled.open_order_reservation_micros != 0 or
        canceled.risk_lease_remaining_micros != risk_lease_total)
        return error.DuplicateCancelChangedState;

    const duplicate = try runDuplicateReport();
    try assertExpectedDigest(
        try assertReplayEquivalent(duplicate),
        expected_duplicate_digest,
    );
    if (duplicate.shard.trace.len != 33 or duplicate.shard.order_state != .filled or
        duplicate.shard.fill_fact_count != 2 or duplicate.shard.report_fact_count != 3 or
        duplicate.shard.portfolio_position.quantity != first.shard.portfolio_position.quantity or
        duplicate.shard.portfolio_position.open_cost_micros !=
            first.shard.portfolio_position.open_cost_micros or
        duplicate.shard.total_fees_micros != first.shard.total_fees_micros or
        duplicate.shard.portfolio_cash_micros != first.shard.portfolio_cash_micros or
        duplicate.shard.unrealized_pnl_micros != first.shard.unrealized_pnl_micros or
        duplicate.shard.ledger_transaction_count != first.shard.ledger_transaction_count)
        return error.DuplicateReportTraceMismatch;

    var conflicting_fill = duplicate.shard;
    if (conflicting_fill.handle(atGroup(21, .{
        .identity = 1,
        .payload = .{ .fill = .{
            .fill_id = 1,
            .quantity = 41,
            .price_micros = 49_900_000_000,
        } },
    }))) |_| return error.ConflictingFillAccepted else |err| {
        if (err != error.ConflictingFillIdentity) return err;
    }

    if (first.shard.order_state != .filled or first.shard.filled_quantity != 100 or
        first.shard.trace.len != 31 or
        first.shard.trace.events[first.shard.trace.len - 1].sequence != 31 or
        !first.shard.economic_projections_complete)
        return error.IncompleteHappyPath;
    if (first.shard.portfolio_position.quantity != 100 or
        first.shard.portfolio_position.open_cost_micros != 500_200_000 or
        first.shard.exchange_position.quantity != 100 or
        first.shard.exchange_position.open_cost_micros != 500_200_000 or
        first.shard.total_fees_micros != 375_150 or
        first.shard.portfolio_cash_micros != 19_999_624_850 or
        first.shard.treasury_cash_micros != 5_000_000_000 or
        first.shard.exchange_cash_micros != 24_999_624_850 or
        first.shard.realized_pnl_micros != 0 or
        first.shard.unrealized_pnl_micros != 1_800_000 or
        first.shard.open_order_reservation_micros != 0 or
        first.shard.position_margin_requirement_micros != 11_044_000 or
        first.shard.risk_lease_remaining_micros != 9_988_956_000 or
        first.shard.ledger_transaction_count != 3 or
        first.shard.portfolio_transfer_count != 1 or
        first.shard.portfolio_ledger_debits_micros != 45_000_375_150 or
        first.shard.portfolio_ledger_credits_micros != 45_000_375_150 or
        first.shard.exchange_ledger_debits_micros != 25_000_375_150 or
        first.shard.exchange_ledger_credits_micros != 25_000_375_150)
        return error.FinalEconomicProjectionMismatch;
    try first.shard.assertClosures();
    return first;
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--benchmark")) return benchmark(init, false);
        if (std.mem.eql(u8, argument, "--benchmark-raw")) return benchmark(init, true);
        if (std.mem.eql(u8, argument, "--benchmark-four-shard"))
            return benchmarkFourShards(init, false);
        if (std.mem.eql(u8, argument, "--benchmark-four-shard-raw"))
            return benchmarkFourShards(init, true);
        return error.UnknownArgument;
    }

    const result = try selfCheck();
    const digest_hex = std.fmt.bytesToHex(stateDigest(result.shard), .lower);
    const market_gap = try runMarketGap();
    const risk_rejection = try runRiskRejection();
    const unknown = try runUnknownReconciliation();
    const duplicate = try runDuplicateReport();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;

    try out.print(
        "trading_engine: zig={s}, mode={s}, self_check=ok\n",
        .{ builtin.zig_version_string, @tagName(builtin.mode) },
    );
    for (result.shard.trace.events[0..result.shard.trace.len]) |event| {
        try out.print("{d:0>2} {s} id={d}\n", .{
            event.sequence,
            @tagName(event.kind),
            event.identity,
        });
    }
    try out.print(
        "happy_path: events={d}, order={s}, qty={d}, open_cost={d}, fees={d}, upl={d}, risk_remaining={d}, ledger=closed, economic_projections=complete\ndigest={s}\n",
        .{
            result.shard.trace.len,
            @tagName(result.shard.order_state),
            result.shard.filled_quantity,
            result.shard.portfolio_position.open_cost_micros,
            result.shard.total_fees_micros,
            result.shard.unrealized_pnl_micros,
            result.shard.risk_lease_remaining_micros,
            &digest_hex,
        },
    );
    try out.print(
        "journal_records={d}, journal_bytes={d}, replay=equivalent, recovery_checks=ok\n",
        .{ result.decision_journal.records, result.decision_journal.len },
    );
    const scenarios = [_]struct { name: []const u8, run: *const LiveRun }{
        .{ .name = "market-gap-v1", .run = &market_gap },
        .{ .name = "risk-rejection-v1", .run = &risk_rejection },
        .{ .name = "unknown-reconciliation-v1", .run = &unknown },
        .{ .name = "duplicate-report-v1", .run = &duplicate },
    };
    for (scenarios) |scenario| {
        const scenario_digest = std.fmt.bytesToHex(stateDigest(scenario.run.shard), .lower);
        try out.print("{s}: events={d}, replay=equivalent, digest={s}\n", .{
            scenario.name,
            scenario.run.shard.trace.len,
            &scenario_digest,
        });
    }
    try out.flush();
}

test "all authoritative acceptance traces close and replay" {
    _ = okx_public_market;
    _ = okx_private_reconciliation;
    _ = okx_order_entry;
    _ = okx_live_chain;
    _ = okx_rest_auth;
    _ = try selfCheck();
}

test "venue adapter seam is bounded and drain-safe" {
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try std.testing.expectError(error.NotStarted, adapter.tryDrain());
    try adapter.start(.{
        .environment = .simulation,
        .request_capacity = 1,
        .output_capacity = 1,
    });
    try std.testing.expectError(error.AlreadyStarted, adapter.start(.{
        .environment = .simulation,
        .request_capacity = 1,
        .output_capacity = 1,
    }));

    const command: OrderCommand = .{
        .command_id = 1,
        .order_id = 1,
        .quantity = happy_order_quantity,
        .limit_price_micros = order_limit_price,
        .reservation_micros = 11_397_750,
        .client_id = client_order_id,
    };
    try std.testing.expectEqual(
        venue_adapter.SendResult.accepted,
        try adapter.trySend(.{ .order_command = command }),
    );
    try std.testing.expectEqual(
        venue_adapter.SendResult.backpressure,
        try adapter.trySend(.{ .order_command = command }),
    );
    try std.testing.expectError(
        error.OutputPending,
        adapter.stop(.{ .monotonic_ns = fixture_monotonic_base }),
    );

    try std.testing.expect((try adapter.tryDrain()) != null);
    try std.testing.expect((try adapter.tryDrain()) == null);
    try adapter.stop(.{ .monotonic_ns = fixture_monotonic_base });
    try std.testing.expectEqual(
        venue_adapter.SendResult.stopped,
        try adapter.trySend(.{ .order_command = command }),
    );
}

test "four shards replay and isolate overload" {
    _ = try assertFourShardIsolation();
}

test "OKX spot authoritative projection" {
    _ = okx_spot_projection;
}
