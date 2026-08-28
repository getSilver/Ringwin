const std = @import("std");
const builtin = @import("builtin");
/// Stable journal codec used by snapshot and semantic replay.
pub const journal = @import("journal.zig");
pub const oms = @import("oms.zig");
const oms_module = oms;
pub const risk = @import("risk.zig");
const risk_module = risk;
pub const economics = @import("economics.zig");
const economics_module = economics;
pub const operational = @import("operational.zig");
const host_gateway = @import("strategy_host_gateway.zig");
const venue_adapter = @import("venue_adapter.zig");
const okx_public_market = @import("okx_public_market.zig");
const okx_private_reconciliation = @import("okx_private_reconciliation.zig");
const okx_spot_projection = @import("okx_spot_projection.zig");
const okx_order_entry = @import("okx_order_entry.zig");
const okx_live_chain = @import("okx_live_chain.zig");
const okx_rest_auth = @import("okx_rest_auth.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Crc32c = std.hash.crc.Crc32Iscsi;

pub const schema_version: u16 = 4;
/// Current physical schema for AuthoritativeTradingState snapshots.
pub const state_schema_version: u32 = 2;
/// Release artifact producing the current snapshot schema.
pub const release_artifact_identity: u64 = 1;
/// Registry entry defining the current snapshot and journal schemas.
pub const schema_registry_identity: u64 = 2;
const snapshot_magic: u64 = 0x50414e53574e4952; // RINWSNAP
const snapshot_header_len: usize = 144;
const SnapshotHeader = packed struct {
    magic: u64,
    encoding_version: u16,
    header_len: u16,
    total_len: u32,
    state_schema: u32,
    release_artifact: u64,
    schema_registry: u64,
    barrier: u64,
    instrument_rules_version: u32,
    margin_rules_version: u32,
    payload_len: u32,
    payload_crc: u32,
    state_digest: u256,
    payload_digest: u256,
    header_crc: u32,
    reserved: u128 = 0,
};
comptime {
    std.debug.assert(@sizeOf(SnapshotHeader) == snapshot_header_len);
}

const SnapshotWriter = struct {
    bytes: []u8,
    position: usize = 0,

    fn put(self: *SnapshotWriter, value: anytype) !void {
        const T = @TypeOf(value);
        const width = if (T == usize or T == isize) @sizeOf(u64) else @sizeOf(T);
        if (self.position + width > self.bytes.len) return error.SnapshotTooLarge;
        if (T == usize) {
            std.mem.writeInt(u64, self.bytes[self.position..][0..width], @intCast(value), .little);
        } else if (T == isize) {
            std.mem.writeInt(i64, self.bytes[self.position..][0..width], @intCast(value), .little);
        } else {
            std.mem.writeInt(T, self.bytes[self.position..][0..width], value, .little);
        }
        self.position += width;
    }
};

const SnapshotReader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn get(self: *SnapshotReader, comptime T: type) !T {
        const width = if (T == usize or T == isize) @sizeOf(u64) else @sizeOf(T);
        if (self.position + width > self.bytes.len) return error.InvalidSnapshotLength;
        const value = if (T == usize)
            std.math.cast(usize, std.mem.readInt(u64, self.bytes[self.position..][0..width], .little)) orelse return error.InvalidSnapshotValue
        else if (T == isize)
            std.math.cast(isize, std.mem.readInt(i64, self.bytes[self.position..][0..width], .little)) orelse return error.InvalidSnapshotValue
        else
            std.mem.readInt(T, self.bytes[self.position..][0..width], .little);
        self.position += width;
        return value;
    }
};

fn snapshotEncode(writer: *SnapshotWriter, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try writer.put(@as(u8, if (value) 1 else 0)),
        .int => try writer.put(value),
        .@"enum" => try snapshotEncode(writer, @intFromEnum(value)),
        .array => for (value) |item| try snapshotEncode(writer, item),
        .optional => if (value) |item| {
            try writer.put(@as(u8, 1));
            try snapshotEncode(writer, item);
        } else try writer.put(@as(u8, 0)),
        .@"struct" => |info| inline for (info.fields) |field|
            try snapshotEncode(writer, @field(value, field.name)),
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("snapshot unions must be tagged");
            try snapshotEncode(writer, std.meta.activeTag(value));
            switch (value) {
                inline else => |payload, tag| {
                    _ = tag;
                    if (@TypeOf(payload) != void) try snapshotEncode(writer, payload);
                },
            }
            _ = Tag;
        },
        else => @compileError("unsupported snapshot field type: " ++ @typeName(T)),
    }
}

fn snapshotDecode(reader: *SnapshotReader, comptime T: type) !T {
    return switch (@typeInfo(T)) {
        .bool => switch (try reader.get(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidSnapshotValue,
        },
        .int => try reader.get(T),
        .@"enum" => |info| blk: {
            const raw = try snapshotDecode(reader, info.tag_type);
            inline for (info.fields) |field|
                if (raw == field.value) break :blk @field(T, field.name);
            return error.InvalidSnapshotValue;
        },
        .array => |info| blk: {
            var result: T = undefined;
            for (&result) |*item| item.* = try snapshotDecode(reader, info.child);
            break :blk result;
        },
        .optional => |info| switch (try reader.get(u8)) {
            0 => null,
            1 => try snapshotDecode(reader, info.child),
            else => error.InvalidSnapshotValue,
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.fields) |field|
                @field(result, field.name) = try snapshotDecode(reader, field.type);
            break :blk result;
        },
        .@"union" => |info| blk: {
            const Tag = info.tag_type orelse @compileError("snapshot unions must be tagged");
            const tag = try snapshotDecode(reader, Tag);
            inline for (info.fields) |field| {
                if (tag == @field(Tag, field.name)) {
                    const payload = if (field.type == void) {} else try snapshotDecode(reader, field.type);
                    break :blk @unionInit(T, field.name, payload);
                }
            }
            return error.InvalidSnapshotValue;
        },
        else => @compileError("unsupported snapshot field type: " ++ @typeName(T)),
    };
}
const client_order_id = "RWN-00000001-01-000000000001";
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
const happy_order_quantity: i64 = 100;
const order_limit_price: i64 = 50_100_000_000;
const initial_exchange_cash: i64 = 25_000 * money_scale;
const portfolio_allocation: i64 = 20_000 * money_scale;
const risk_lease_total: i64 = 10_000 * money_scale;
const expected_happy_digest = "05512551eb6da3d137e0476015e262f16df155035d2ac292db700e15edb10ef3";
const expected_market_gap_digest = "9bd0c661b449be191751ebc63648d884302e65292a3a2240f93ef4b2c1e2fe21";
const expected_risk_rejection_digest = "34aec497178098873f556d1e786f19b02576c5a7e9d568435fea40a4709dd6f9";
const expected_unknown_digest = "32d6ff5537d4adc99e57d159fde6c77cb353030929eafe63726bf71c7efaf661";
const expected_duplicate_digest = "14f3be1e51ef6aa7e16dd5cf5ca4aff2355e7d17d06a6d44ea27342b32d13f53";
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
};

pub const Fact = struct {
    sequence: u64,
    kind: EventKind,
    identity: u64,
};

const Trace = struct {
    events: [64]Fact = undefined,
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
pub const DispatchStatus = enum(u8) { submitted, unknown };
pub const ReconciliationStatus = enum(u8) { found_live };
const MarketHealth = enum(u8) { initializing, healthy, gap };
const RejectReason = enum(u8) { none, market_data_gap, global_risk_lease_exceeded };

pub const ExecutionReport = struct {
    report_id: u64,
    status: ExecutionStatus,
    cumulative_qty: i64,
    remaining_qty: i64,
};

pub const Fill = struct {
    fill_id: u64,
    quantity: i64,
    price_micros: i64,
};

pub const L2Snapshot = struct {
    source_sequence: u64,
    bid_price_micros: i64,
    bid_quantity: i64,
    ask_1_price_micros: i64,
    ask_1_quantity: i64,
    ask_2_price_micros: i64,
    ask_2_quantity: i64,
};

pub const L2Delta = struct {
    previous: u64,
    current: u64,
    bid_price_micros: i64,
    bid_quantity: i64,
};

pub const TimerRequest = struct {
    quantity: i64,
};

pub const ReconciliationResult = struct {
    reconciliation_id: u64,
    status: ReconciliationStatus,
    venue_order_id: u64,
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
};

pub const ReservationModel = enum(u8) { leveraged, cash };

pub const InstrumentRules = struct {
    version: u32,
    instrument_identity: u128,
    quantity_denominator: i64,
    reservation_model: ReservationModel,
};

pub const MarginRules = struct {
    version: u32,
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
pub const PrimaryLease = struct { fencing_token: u64 };
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

pub const Payload = union(PayloadTag) {
    instrument_rules_activated: InstrumentRules,
    margin_rules_activated: MarginRules,
    account_configuration: AccountConfiguration,
    exchange_balance: Balance,
    exchange_positions,
    opening_balance: Balance,
    virtual_portfolio_activated: VirtualPortfolioActivation,
    portfolio_transfer: PortfolioTransfer,
    strategy_activated: StrategyActivation,
    primary_lease_granted: PrimaryLease,
    risk_lease_granted: RiskLease,
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
};

pub const CanonicalEvent = struct {
    version: u16 = schema_version,
    identity: u64,
    source_time: u64 = 0,
    receive_time: u64 = 0,
    monotonic_time: u64 = 0,
    wall_time: u64 = 0,
    time_presence: journal.TimePresence = .{},
    payload: Payload,
};

const InputEvent = CanonicalEvent;

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

fn lifecycleCommand(command_identity: u128, expected_version: u64, kind: operational.CommandKind) InputEvent {
    return atGroup(40, .{ .identity = @intCast(1_000 + command_identity), .payload = .{ .control_command = .{
        .command_identity = command_identity,
        .content_hash = command_identity * 7_919,
        .target_identity = 1,
        .expected_version = expected_version,
        .expires_at = std.math.maxInt(u64),
        .kind = kind,
    } } });
}

fn deRiskCommand(command_identity: u128, expected_version: u64, target_position: i64, warning_identity: u128) InputEvent {
    var command_event = lifecycleCommand(command_identity, expected_version, .de_risk);
    command_event.payload.control_command.target_position = target_position;
    if (warning_identity != 0) {
        command_event.payload.control_command.risk_warning_acknowledged = true;
        command_event.payload.control_command.risk_warning_identity = warning_identity;
    }
    return command_event;
}

fn resolveLatchCommand(command_identity: u128, expected_version: u64, latch_identity: u128) InputEvent {
    var command_event = lifecycleCommand(command_identity, expected_version, .resolve_latch);
    command_event.payload.control_command.referenced_latch_identity = latch_identity;
    return command_event;
}

const EncodedInput = struct {
    bytes: [512]u8 = undefined,
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
        .instrument_rules_activated => |value| {
            try encoded.put(u32, value.version);
            try encoded.put(u128, value.instrument_identity);
            try encoded.put(i64, value.quantity_denominator);
            try encoded.put(u8, @intFromEnum(value.reservation_model));
        },
        .margin_rules_activated => |value| {
            try encoded.put(u32, value.version);
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
        .oms_intent_group => |value| {
            try encoded.put(u64, value.first_intent_sequence);
            try encoded.put(u8, @intFromEnum(value.policy));
            try encoded.put(u8, value.count);
            for (value.members[0..value.count]) |member| {
                try encoded.put(u64, member.intent_sequence);
                try encoded.put(u128, member.strategy_instance);
                try encoded.put(u8, @intFromEnum(member.operation));
                try encoded.put(u8, @intFromEnum(member.instrument));
                try encoded.put(u8, @intFromEnum(member.side));
                try encoded.put(u8, @intFromBool(member.portfolio_reduce_only));
                try encoded.put(u8, @intFromBool(member.venue_reduce_only));
                try encoded.put(u64, member.target_order_id);
                try encoded.put(u32, member.expected_revision);
                try encoded.put(i64, member.expected_cumulative_quantity);
                try encoded.put(i64, member.quantity);
                try encoded.put(i64, member.limit_price_micros);
                try encoded.put(u8, @intFromBool(member.native_amend));
                try encoded.put(u8, @intFromBool(member.allow_cancel_confirm_create));
                try encoded.put(i64, member.reservation_micros);
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

fn decodeInput(record: journal.Record) !InputEvent {
    if (record.schema_version != schema_version) return error.UnsupportedSchema;
    var offset: usize = 0;
    const identity = try readInputValue(u64, record.payload, &offset);
    const tag = std.enums.fromInt(
        PayloadTag,
        try readInputValue(u16, record.payload, &offset),
    ) orelse return error.UnknownInputType;
    const payload: Payload = switch (tag) {
        .instrument_rules_activated => .{ .instrument_rules_activated = .{
            .version = try readInputValue(u32, record.payload, &offset),
            .instrument_identity = try readInputValue(u128, record.payload, &offset),
            .quantity_denominator = try readInputValue(i64, record.payload, &offset),
            .reservation_model = std.enums.fromInt(
                ReservationModel,
                try readInputValue(u8, record.payload, &offset),
            ) orelse return error.UnknownReservationModel,
        } },
        .margin_rules_activated => .{ .margin_rules_activated = .{
            .version = try readInputValue(u32, record.payload, &offset),
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
        .oms_intent_group => blk: {
            var value: oms_module.IntentGroup = .{
                .first_intent_sequence = try readInputValue(u64, record.payload, &offset),
                .policy = std.enums.fromInt(oms_module.PartialExecutionPolicy, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownPartialExecutionPolicy,
                .count = try readInputValue(u8, record.payload, &offset),
            };
            if (value.count > oms_module.max_group_members) return error.InvalidIntentGroup;
            for (value.members[0..value.count]) |*member| member.* = .{
                .intent_sequence = try readInputValue(u64, record.payload, &offset),
                .strategy_instance = try readInputValue(u128, record.payload, &offset),
                .operation = std.enums.fromInt(oms_module.Operation, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownOmsOperation,
                .instrument = std.enums.fromInt(oms_module.Instrument, try readInputValue(u8, record.payload, &offset)) orelse return error.UnknownOmsInstrument,
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
                .limit_price_micros = try readInputValue(i64, record.payload, &offset),
                .native_amend = (try readInputValue(u8, record.payload, &offset)) == 1,
                .allow_cancel_confirm_create = (try readInputValue(u8, record.payload, &offset)) == 1,
                .reservation_micros = try readInputValue(i64, record.payload, &offset),
            };
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

/// Decodes one stable input record for side-effect-free recovery verification.
pub fn decodeStableInput(record: journal.Record) !CanonicalEvent {
    return decodeInput(record);
}

fn eventIdentity(payload: []const u8) !u64 {
    if (payload.len < @sizeOf(u64)) return error.MissingEventIdentity;
    return std.mem.readInt(u64, payload[0..@sizeOf(u64)], .little);
}

pub const OrderCommand = struct {
    command_id: u64,
    order_id: u64,
    quantity: i64,
    limit_price_micros: i64,
    reservation_micros: i64,
    client_id: []const u8,
};

pub const ApplyResult = struct {
    facts: []const Fact,
    order_command: ?OrderCommand,
    oms_commands: []const oms_module.Command,
};

pub const ReplayTradingShard = struct {
    shard: TradingShard = .{},

    pub fn apply(self: *ReplayTradingShard, event: CanonicalEvent) ![]const Fact {
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

    pub fn apply(self: *TradingShard, event: CanonicalEvent) !ApplyResult {
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
        if (destination.len < snapshot_header_len) return error.SnapshotTooLarge;
        var authoritative = self;
        canonicalizeSnapshotState(&authoritative);
        var writer: SnapshotWriter = .{ .bytes = destination[snapshot_header_len..] };
        try snapshotEncode(&writer, authoritative);
        const payload = destination[snapshot_header_len .. snapshot_header_len + writer.position];
        const total_len = snapshot_header_len + payload.len;
        if (payload.len > std.math.maxInt(u32)) return error.SnapshotTooLarge;
        const encoded = destination[0..total_len];
        const digest = self.canonicalStateDigest();
        var payload_digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(payload, &payload_digest, .{});
        var header: SnapshotHeader = .{
            .magic = snapshot_magic,
            .encoding_version = 1,
            .header_len = snapshot_header_len,
            .total_len = @intCast(total_len),
            .state_schema = state_schema_version,
            .release_artifact = release_artifact_identity,
            .schema_registry = schema_registry_identity,
            .barrier = barrier,
            .instrument_rules_version = self.instrument_rules_version,
            .margin_rules_version = self.margin_rules_version,
            .payload_len = @intCast(payload.len),
            .payload_crc = Crc32c.hash(payload),
            .state_digest = std.mem.readInt(u256, &digest, .little),
            .payload_digest = std.mem.readInt(u256, &payload_digest, .little),
            .header_crc = 0,
        };
        header.header_crc = Crc32c.hash(std.mem.asBytes(&header)[0..@offsetOf(SnapshotHeader, "header_crc")]);
        @memcpy(encoded[0..snapshot_header_len], std.mem.asBytes(&header));
        return encoded;
    }

    /// Restores a validated snapshot through the side-effect-free replay seam.
    pub fn restoreSnapshot(encoded: []const u8) !SnapshotRestore {
        if (encoded.len < snapshot_header_len) return error.InvalidSnapshotHeader;
        var header: SnapshotHeader = undefined;
        @memcpy(std.mem.asBytes(&header), encoded[0..snapshot_header_len]);
        if (header.magic != snapshot_magic or header.encoding_version != 1 or
            header.header_len != snapshot_header_len or header.total_len != encoded.len or
            header.state_schema != state_schema_version or
            header.release_artifact != release_artifact_identity or
            header.schema_registry != schema_registry_identity or
            header.header_crc != Crc32c.hash(encoded[0..@offsetOf(SnapshotHeader, "header_crc")]))
            return error.InvalidSnapshotHeader;
        if (header.payload_len != encoded.len - snapshot_header_len)
            return error.InvalidSnapshotLength;
        const payload = encoded[snapshot_header_len..];
        var payload_digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(payload, &payload_digest, .{});
        if (header.payload_crc != Crc32c.hash(payload) or
            header.payload_digest != std.mem.readInt(u256, &payload_digest, .little))
            return error.InvalidSnapshotPayload;
        var reader: SnapshotReader = .{ .bytes = payload };
        var recovered = try snapshotDecode(&reader, TradingShard);
        if (reader.position != payload.len) return error.InvalidSnapshotLength;
        recovered.oms.begin();
        try validateSnapshotState(&recovered);
        const barrier = header.barrier;
        const digest = recovered.canonicalStateDigest();
        if (recovered.trace.len != barrier or
            recovered.instrument_rules_version != header.instrument_rules_version or
            recovered.margin_rules_version != header.margin_rules_version or
            header.state_digest != std.mem.readInt(u256, &digest, .little))
            return error.InvalidSnapshotState;
        return .{ .shard = recovered, .barrier = barrier };
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
            .strategy_micros = self.strategy_limit_micros,
            .portfolio_micros = self.portfolio_limit_micros,
            .decision_domain_micros = self.risk_lease_micros,
            .exchange_account_micros = self.exchange_account_limit_micros,
            .global_micros = self.global_limit_micros,
        };
    }

    fn riskRules(self: *const TradingShard) risk_module.Rules {
        return .{
            .quantity_denominator = self.quantity_denominator,
            .price_tick_micros = self.price_tick_micros,
            .venue_initial_margin_ppm = self.venue_initial_margin_ppm,
            .internal_initial_margin_ppm = self.internal_initial_margin_ppm,
            .internal_maintenance_margin_ppm = self.internal_maintenance_margin_ppm,
            .fee_ppm = self.risk_fee_ppm,
            .opening_buffer_micros = self.opening_buffer_micros,
            .opening_buffer_bps = self.opening_buffer_bps,
            .opening_liquidation_distance_ticks = self.opening_liquidation_distance_ticks,
            .warning_buffer_micros = self.warning_buffer_micros,
            .kill_buffer_micros = self.kill_buffer_micros,
            .warning_buffer_bps = self.warning_buffer_bps,
            .kill_buffer_bps = self.kill_buffer_bps,
            .warning_liquidation_distance_ticks = self.warning_liquidation_distance_ticks,
            .kill_liquidation_distance_ticks = self.kill_liquidation_distance_ticks,
        };
    }

    fn qualifyOmsGroup(self: *TradingShard, group: oms_module.IntentGroup) !oms_module.IntentGroup {
        var qualified = group;
        var active = try self.oms.activeReservations();
        for (qualified.members[0..qualified.count]) |*intent| {
            for (self.fenced_strategy_instances[0..self.fenced_strategy_count]) |fenced|
                if (intent.strategy_instance == fenced and intent.operation != .cancel)
                    return error.StrategyCutoverFenced;
            if (intent.operation == .cancel) continue;
            var replaced: i64 = 0;
            if (intent.operation == .amend) {
                const target = self.oms.orderById(intent.target_order_id) orelse return error.UnknownOrder;
                if (target.reservation_active) replaced = target.reservation_micros;
            }
            const portfolio_position_quantity = switch (intent.instrument) {
                .btc_usdt_spot => self.spot_portfolio_position.quantity,
                .btc_usdt_swap => self.portfolio_position.quantity,
            };
            const exchange_position_quantity = switch (intent.instrument) {
                .btc_usdt_spot => self.spot_exchange_position.quantity,
                .btc_usdt_swap => self.exchange_position.quantity,
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
            const assessment = try risk_module.assess(self.riskRules(), self.riskLimits(), .{
                .portfolio_cash_micros = self.portfolio_cash_micros,
                .exchange_cash_micros = self.exchange_cash_micros,
                .portfolio_position_quantity = portfolio_position_quantity,
                .exchange_position_quantity = exchange_position_quantity,
                .active_order_reservations_micros = active,
                .replaced_order_reservation_micros = replaced,
                .mark_price_micros = self.mark_price_micros,
            }, .{
                .product = if (intent.instrument == .btc_usdt_spot) .spot else .isolated_linear_usdt,
                .side = if (intent.side == .buy) .buy else .sell,
                .quantity = intent.quantity,
                .risk_price_micros = @max(intent.limit_price_micros, self.mark_price_micros),
                .portfolio_reduce_only = intent.portfolio_reduce_only,
            });
            intent.reservation_micros = assessment.order_reservation_micros;
            intent.portfolio_reduce_only = assessment.portfolio_reduce_only;
            intent.venue_reduce_only = assessment.venue_reduce_only;
            active = assessment.total_reserved_micros;
            self.layered_risk_reserved_micros = assessment.total_reserved_micros;
            self.portfolio_margin_buffer_micros = assessment.portfolio_margin_buffer_micros;
            self.exchange_margin_buffer_micros = assessment.exchange_margin_buffer_micros;
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
        try self.oms.confirmReplacement(order_id, intent.reservation_micros, intent.portfolio_reduce_only, intent.venue_reduce_only);
    }

    fn refreshLayeredReservations(self: *TradingShard) !void {
        const previous = self.layered_risk_reserved_micros;
        const current = try self.oms.activeReservations();
        const change = try std.math.sub(i64, current, previous);
        self.layered_risk_reserved_micros = current;
        self.portfolio_margin_buffer_micros = try std.math.sub(i64, self.portfolio_margin_buffer_micros, change);
        self.exchange_margin_buffer_micros = try std.math.sub(i64, self.exchange_margin_buffer_micros, change);
    }

    fn applyOperationalGate(self: *TradingShard, change: operational.SafetyGateChange) !void {
        const action = try self.operational_state.applyGate(change);
        if (action.cancel_open_orders)
            try self.oms.cancelOpenOrders(action.cancel_increasing_only);
    }

    /// Authoritative economics that KeepPositions must preserve verbatim.
    const LifecycleEconomics = struct {
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

    fn captureLifecycleEconomics(self: *const TradingShard) LifecycleEconomics {
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
            .instrument = if (self.reservation_model == .cash) .btc_usdt_spot else .btc_usdt_swap,
            .quantity = intent.quantity,
            .limit_price_micros = intent.limit_price_micros,
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
        self.last_risk_required_micros = qualified.members[0].reservation_micros;
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
        self.order_limit_price_micros = oms_command.limit_price_micros;
        try self.recalculateRisk(true);
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
            .l2_snapshot => |book_snapshot| {
                if (book_snapshot.bid_price_micros <= 0 or book_snapshot.bid_quantity <= 0 or
                    book_snapshot.ask_1_price_micros <= 0 or book_snapshot.ask_1_quantity <= 0 or
                    book_snapshot.ask_2_price_micros <= book_snapshot.ask_1_price_micros or
                    book_snapshot.ask_2_quantity <= 0)
                    return error.InvalidBookSnapshot;
                self.expected_source_sequence = book_snapshot.source_sequence;
                self.bid_price_micros = book_snapshot.bid_price_micros;
                self.bid_quantity = book_snapshot.bid_quantity;
                self.ask_1_price_micros = book_snapshot.ask_1_price_micros;
                self.ask_1_quantity = book_snapshot.ask_1_quantity;
                self.ask_2_price_micros = book_snapshot.ask_2_price_micros;
                self.ask_2_quantity = book_snapshot.ask_2_quantity;
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
                    if (self.operational_state.initialized) try self.applyOperationalGate(.{
                        .gate_identity = market_data_gate_identity,
                        .target_identity = self.operational_state.target_identity,
                        .kind = .self_recovering,
                        .reason = .market_data,
                        .open = false,
                    });
                    try self.trace.append(.market_gap, 1);
                    return null;
                }
                self.expected_source_sequence = delta.current;
                self.bid_price_micros = delta.bid_price_micros;
                self.bid_quantity = delta.bid_quantity;
                try self.trace.append(.l2_delta, input.identity);
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
                const changed = try self.applyEconomicProjection(.{ .fill = .{
                    .identity = fill.fill_id,
                    .instrument = if (order.instrument == .btc_usdt_spot) .btc_usdt_spot else .btc_usdt_swap,
                    .side = if (order.side == .buy) .buy else .sell,
                    .quantity = fill.quantity,
                    .price_micros = fill.price_micros,
                    .quantity_denominator = self.quantity_denominator,
                    .fee_micros = fill.fee_micros,
                    .rebate_micros = fill.rebate_micros,
                    .portfolio_margin_ppm = self.internal_initial_margin_ppm,
                    .exchange_margin_ppm = self.venue_initial_margin_ppm,
                } });
                if (changed) {
                    try self.recalculateRisk(false);
                    try self.trace.append(.economic_fill, fill.fill_id);
                }
            },
            .funding_settlement => |funding| {
                const changed = try self.applyEconomicProjection(.{ .funding_settlement = .{ .identity = funding.settlement_id, .amount_micros = funding.amount_micros } });
                if (changed) try self.trace.append(.funding_settlement, funding.settlement_id);
            },
            .venue_forced_execution => |forced| {
                const changed = try self.applyEconomicProjection(.{ .venue_forced_execution = .{
                    .identity = forced.execution_id,
                    .side = if (forced.side == .buy) .buy else .sell,
                    .quantity = forced.quantity,
                    .price_micros = forced.price_micros,
                    .quantity_denominator = self.quantity_denominator,
                    .fee_micros = forced.fee_micros,
                    .penalty_micros = forced.penalty_micros,
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
                    .usdt_balance_micros = account_snapshot.usdt_balance_micros,
                    .spot_asset_quantity = account_snapshot.spot_asset_quantity,
                    .swap_position_quantity = account_snapshot.swap_position_quantity,
                    .margin_micros = account_snapshot.margin_micros,
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
            .order_dispatch_result => |status| {
                if (self.order_state != .pending_submit) return error.InvalidDispatchResult;
                self.dispatch_attempt_count = try std.math.add(
                    u64,
                    self.dispatch_attempt_count,
                    1,
                );
                switch (status) {
                    .submitted => {
                        var batch: oms_module.DispatchBatch = .{ .count = 1 };
                        batch.items[0] = .{ .command_id = self.order_command_id, .state = .submitted };
                        try self.oms.applyDispatch(batch);
                        try self.trace.append(.order_dispatched, input.identity);
                    },
                    .unknown => {
                        var batch: oms_module.DispatchBatch = .{ .count = 1 };
                        batch.items[0] = .{ .command_id = self.order_command_id, .state = .unknown };
                        try self.oms.applyDispatch(batch);
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
                try self.oms.applyReconciliation(.{
                    .reconciliation_id = result.reconciliation_id,
                    .order_id = self.order_id,
                    .status = .found_live,
                    .revision = 1,
                    .cumulative_quantity = self.filled_quantity,
                    .remaining_quantity = self.order_quantity - self.filled_quantity,
                });
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
                    try self.oms.applyReport(.{
                        .report_id = report.report_id,
                        .order_id = self.order_id,
                        .revision = 1,
                        .status = switch (report.status) {
                            .accepted => .accepted,
                            .partially_filled => .partially_filled,
                            .filled => .filled,
                            .canceled => .canceled,
                        },
                        .cumulative_quantity = report.cumulative_qty,
                        .remaining_quantity = report.remaining_qty,
                    });
                    self.order_state = switch (report.status) {
                        .accepted => .live,
                        .partially_filled => .partially_filled,
                        .filled => .filled,
                        .canceled => .canceled,
                    };
                    if (report.status == .canceled) {
                        try self.recalculateRisk(false);
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
                if (!is_new) return null;
                try self.trace.append(.fill, fill.fill_id);
                _ = try self.applyEconomicProjection(.{ .fill = .{
                    .identity = fill.fill_id,
                    .instrument = if (self.reservation_model == .cash) .btc_usdt_spot else .btc_usdt_swap,
                    .side = .buy,
                    .quantity = fill.quantity,
                    .price_micros = fill.price_micros,
                    .quantity_denominator = self.quantity_denominator,
                    .fee_micros = try feeMicros(try self.shardNotionalMicros(fill.quantity, fill.price_micros)),
                    .portfolio_margin_ppm = self.internal_initial_margin_ppm,
                    .exchange_margin_ppm = self.venue_initial_margin_ppm,
                } });
                try self.applyFill(fill);
                try self.trace.append(.fee_ledger_transaction, fill.fill_id);
                try self.trace.append(.risk_reservation_rebalanced, fill.fill_id);
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
    zeroUnused(Fill, shard.fill_facts[shard.fill_fact_count..]);
    zeroUnused(ExecutionReport, shard.report_facts[shard.report_fact_count..]);
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
}

fn validateSnapshotState(shard: *const TradingShard) !void {
    if (shard.trace.len > shard.trace.events.len or
        shard.fill_fact_count > shard.fill_facts.len or
        shard.report_fact_count > shard.report_facts.len or
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

const AdapterRequest = union(enum) {
    order_command: OrderCommand,
};

const AdapterOutputBatch = struct {
    dispatch_result: InputEvent,
    ingress: [5]InputEvent,
};

const VenueAdapter = venue_adapter.Interface(AdapterRequest, AdapterOutputBatch);

/// Legacy deterministic fixture for the pre-adapter TradingShard acceptance
/// path. The shared SimulatedVenue lives in simulated_venue.zig.
const LegacyFixtureVenue = struct {
    const State = enum { idle, running, stopped };

    state: State = .idle,
    pending: ?AdapterOutputBatch = null,

    fn adapter(self: *LegacyFixtureVenue) VenueAdapter {
        return .{ .ptr = self, .vtable = &.{
            .start = startOpaque,
            .try_send = trySendOpaque,
            .try_drain = tryDrainOpaque,
            .stop = stopOpaque,
        } };
    }

    fn startOpaque(ptr: *anyopaque, config: venue_adapter.Config) venue_adapter.StartError!void {
        const self: *LegacyFixtureVenue = @ptrCast(@alignCast(ptr));
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
        const self: *LegacyFixtureVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.state == .stopped) return .stopped;
        if (self.pending != null) return .backpressure;
        self.pending = switch (request) {
            .order_command => |command| makeOutput(command) catch return error.InvalidRequest,
        };
        return .accepted;
    }

    fn tryDrainOpaque(ptr: *anyopaque) venue_adapter.DrainError!?AdapterOutputBatch {
        const self: *LegacyFixtureVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const pending = self.pending orelse return null;
        self.pending = null;
        return pending;
    }

    fn stopOpaque(
        ptr: *anyopaque,
        deadline: venue_adapter.DrainDeadline,
    ) venue_adapter.StopError!void {
        const self: *LegacyFixtureVenue = @ptrCast(@alignCast(ptr));
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
    atGroup(1, .{ .identity = 1, .payload = .{ .instrument_rules_activated = .{
        .version = 1,
        .instrument_identity = 3,
        .quantity_denominator = contract_denominator,
        .reservation_model = .leveraged,
    } } }),
    atGroup(2, .{ .identity = 1, .payload = .{ .margin_rules_activated = .{ .version = 1 } } }),
    atGroup(3, .{ .identity = 1, .payload = .{ .account_configuration = .{ .exchange_account_identity = 2 } } }),
    atGroup(4, .{ .identity = 1, .payload = .{ .exchange_balance = .{ .cash_micros = initial_exchange_cash } } }),
    atGroup(5, .{ .identity = 1, .payload = .exchange_positions }),
    atGroup(6, .{ .identity = 1, .payload = .{ .opening_balance = .{ .cash_micros = initial_exchange_cash } } }),
    atGroup(7, .{ .identity = 1, .payload = .{ .virtual_portfolio_activated = .{ .portfolio_identity = 1 } } }),
    atGroup(8, .{ .identity = 1, .payload = .{ .portfolio_transfer = .{ .amount_micros = portfolio_allocation } } }),
    atGroup(9, .{ .identity = 1, .payload = .{ .strategy_activated = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 1,
    } } }),
    atGroup(10, .{ .identity = 1, .payload = .{ .primary_lease_granted = .{ .fencing_token = 1 } } }),
    atGroup(11, .{ .identity = 1, .payload = .{ .risk_lease_granted = .{ .amount_micros = risk_lease_total } } }),
    atGroup(11, .{ .identity = 1, .payload = .{ .control_command = .{
        .command_identity = 1,
        .content_hash = 1,
        .target_identity = 1,
        .expected_version = 0,
        .expires_at = std.math.maxInt(u64),
        .kind = .start_recovery,
    } } }),
    atGroup(11, .{ .identity = 1, .payload = .recovery_completed }),
    atGroup(11, .{ .identity = 2, .payload = .{ .control_command = .{
        .command_identity = 2,
        .content_hash = 2,
        .target_identity = 1,
        .expected_version = 2,
        .expires_at = std.math.maxInt(u64),
        .kind = .enable_trading,
    } } }),
};

const LiveRun = struct {
    shard: TradingShard,
    decision_journal: journal.Journal,
};

/// Atomically applies one canonical event and appends every resulting fact to stable journal.
pub fn applyStable(
    shard: *TradingShard,
    decision_journal: *journal.Journal,
    input: InputEvent,
) !?OrderCommand {
    var candidate_shard = shard.*;
    var candidate_journal = decision_journal.*;
    const result = try candidate_shard.apply(input);
    if (result.facts.len == 0) return error.InputProducedNoFact;
    const encoded_input = try encodeInput(input);

    for (result.facts, 0..) |event, index| {
        var identity_bytes: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &identity_bytes, event.identity, .little);
        try candidate_journal.append(.{
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
    shard.* = candidate_shard;
    decision_journal.* = candidate_journal;
    return result.order_command;
}

const applyLive = applyStable;

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

fn startScenarioAuthorized(
    authorization: host_gateway.Authorization,
    reservation_model: ReservationModel,
) !LiveRun {
    var run: LiveRun = .{
        .shard = .{},
        .decision_journal = journal.Journal.init(),
    };
    var configured_genesis = genesis;
    configured_genesis[0].payload.instrument_rules_activated.quantity_denominator = switch (reservation_model) {
        .leveraged => contract_denominator,
        .cash => 100_000_000,
    };
    configured_genesis[0].payload.instrument_rules_activated.reservation_model = reservation_model;
    configured_genesis[8].payload.strategy_activated = .{
        .strategy_identity = authorization.strategy_identity,
        .config_version = authorization.config_version,
        .activation_identity = authorization.activation_identity,
    };
    for (configured_genesis) |event| {
        if (try applyLive(&run.shard, &run.decision_journal, event) != null)
            return error.UnexpectedCommand;
    }
    return run;
}

fn startScenario() !LiveRun {
    return startScenarioAuthorized(.{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 1,
        .activation_barrier = 0,
    }, .leveraged);
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

pub const QualifiedHostOrder = struct {
    command_id: u64,
    order_id: u64,
    strategy_identity: u128,
    intent_sequence: u64,
    instrument_identity: u128,
    side: host_gateway.Side,
    time_in_force: host_gateway.TimeInForce,
    portfolio_reduce_only: bool,
    quantity: i64,
    limit_price_micros: i64,
    reservation_micros: i64,
};

pub const TradingShardHostIngress = struct {
    run: LiveRun,

    pub fn initHealthyFixture() !TradingShardHostIngress {
        var run = try startScenario();
        try applyHealthyPrelude(&run);
        return .{ .run = run };
    }

    pub fn initHealthyFixtureFor(authorization: host_gateway.Authorization) !TradingShardHostIngress {
        var run = try startScenarioAuthorized(authorization, .leveraged);
        try applyHealthyPrelude(&run);
        return .{ .run = run };
    }

    pub fn initHealthySpotFixture() !TradingShardHostIngress {
        return initHealthySpotFixtureFor(.{
            .strategy_identity = 1,
            .config_version = 1,
            .activation_identity = 1,
            .activation_barrier = 0,
        });
    }

    pub fn initHealthySpotFixtureFor(authorization: host_gateway.Authorization) !TradingShardHostIngress {
        var run = try startScenarioAuthorized(authorization, .cash);
        try applyHealthyPrelude(&run);
        return .{ .run = run };
    }

    pub fn applyDecision(self: *TradingShardHostIngress, decision: host_gateway.Decision) !bool {
        return (try self.applyDecisionCommand(decision)) != null;
    }

    pub fn applyDecisionCommand(self: *TradingShardHostIngress, decision: host_gateway.Decision) !?QualifiedHostOrder {
        const payload: Payload = switch (decision) {
            .accepted => |intent| .{ .external_order_intent = intent },
            .rejected => |rejection| .{ .strategy_intent_rejected = rejection },
        };
        const identity: u64 = switch (decision) {
            .accepted => |intent| intent.intent_sequence,
            .rejected => |rejection| rejection.intent_sequence,
        };
        const command = try applyLive(
            &self.run.shard,
            &self.run.decision_journal,
            atGroup(15, .{ .identity = identity, .payload = payload }),
        ) orelse return null;
        const intent = switch (decision) {
            .accepted => |value| value,
            .rejected => return error.RejectionProducedCommand,
        };
        return .{
            .command_id = command.command_id,
            .order_id = command.order_id,
            .strategy_identity = intent.strategy_identity,
            .intent_sequence = intent.intent_sequence,
            .instrument_identity = intent.instrument_identity,
            .side = intent.side,
            .time_in_force = intent.time_in_force,
            .portfolio_reduce_only = intent.portfolio_reduce_only,
            .quantity = command.quantity,
            .limit_price_micros = command.limit_price_micros,
            .reservation_micros = command.reservation_micros,
        };
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

    pub fn applyDispatchResult(self: *TradingShardHostIngress, identity: u64, status: DispatchStatus) !void {
        if ((try applyLive(
            &self.run.shard,
            &self.run.decision_journal,
            atGroup(16, .{ .identity = identity, .payload = .{ .order_dispatch_result = status } }),
        )) != null) return error.DispatchProducedCommand;
    }

    pub fn verifyReplay(self: *TradingShardHostIngress) !void {
        const quantity_denominator = self.run.shard.quantity_denominator;
        const reservation_model = self.run.shard.reservation_model;
        try self.run.decision_journal.seal();
        _ = try assertReplayEquivalentConfigured(self.run, quantity_denominator, reservation_model);
    }
};

fn finishScenario(run: *LiveRun) !LiveRun {
    try run.decision_journal.seal();
    return run.*;
}

fn runHappyPath() !LiveRun {
    var run = try startScenario();
    var simulated: LegacyFixtureVenue = .{};
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
    var simulated: LegacyFixtureVenue = .{};
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
    const before_duplicate_fill = run.shard.canonicalStateDigest();
    const duplicate_fill_result = try run.shard.apply(duplicateAtGroup(18, output.ingress[1]));
    if (duplicate_fill_result.facts.len != 0 or duplicate_fill_result.order_command != null or duplicate_fill_result.oms_commands.len != 0) return error.DuplicateFillChangedState;
    try std.testing.expectEqualSlices(u8, &before_duplicate_fill, &run.shard.canonicalStateDigest());
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
    hasher.update("StateDigestV3\x00");
    digestInt(&hasher, u16, schema_version);
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
        digestInt(&hasher, u8, @intFromEnum(order.instrument));
        digestInt(&hasher, u8, @intFromEnum(order.side));
        digestBool(&hasher, order.portfolio_reduce_only);
        digestBool(&hasher, order.venue_reduce_only);
        digestInt(&hasher, u32, order.revision);
        digestInt(&hasher, u8, @intFromEnum(order.state));
        digestInt(&hasher, i64, order.quantity);
        digestInt(&hasher, i64, order.limit_price_micros);
        digestInt(&hasher, i64, order.cumulative_quantity);
        digestInt(&hasher, u64, order.predecessor_order_id);
        digestInt(&hasher, i64, order.reservation_micros);
        digestInt(&hasher, i64, order.confirmed_reservation_micros);
        digestBool(&hasher, order.pending_reservation_micros != null);
        digestInt(&hasher, i64, order.pending_reservation_micros orelse 0);
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
    return replayConfigured(bytes, contract_denominator, .leveraged);
}

fn replayConfigured(bytes: []const u8, quantity_denominator: i64, reservation_model: ReservationModel) !ReplayResult {
    var reader = try journal.Reader.init(bytes);
    return replayReader(&reader, .{
        .quantity_denominator = quantity_denominator,
        .reservation_model = reservation_model,
    });
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
    return assertReplayEquivalentConfigured(run, contract_denominator, .leveraged);
}

fn assertReplayEquivalentConfigured(run: LiveRun, quantity_denominator: i64, reservation_model: ReservationModel) ![Sha256.digest_length]u8 {
    const live_digest = stateDigest(run.shard);
    const replayed = try replayConfigured(run.decision_journal.bytes(), quantity_denominator, reservation_model);
    if (replayed.status != .clean or
        !sameTrace(run.shard.trace, replayed.shard.trace) or
        !std.mem.eql(u8, &live_digest, &stateDigest(replayed.shard)))
    {
        const live_hex = std.fmt.bytesToHex(live_digest, .lower);
        const replay_hex = std.fmt.bytesToHex(stateDigest(replayed.shard), .lower);
        std.debug.print("replay mismatch live={s} replay={s} trace={d}/{d}\n", .{ &live_hex, &replay_hex, run.shard.trace.len, replayed.shard.trace.len });
        return error.ReplayNotEquivalent;
    }
    return live_digest;
}

fn assertExpectedDigest(
    digest: [Sha256.digest_length]u8,
    expected_hex: []const u8,
) !void {
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual_hex, expected_hex)) {
        std.debug.print("state digest mismatch: expected {s}, actual {s}\n", .{ expected_hex, actual_hex });
        return error.UnexpectedStateDigest;
    }
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
    if (truncated_record.status != .truncated_tail or truncated_record.shard.trace.len != 33)
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
    var unsupported_schema = first_record;
    unsupported_schema.schema_version = schema_version + 1;
    try unknown_schema.append(unsupported_schema);
    try unknown_schema.seal();
    try expectReplayError(unknown_schema.bytes(), error.UnsupportedSchema);

    const market_gap = try runMarketGap();
    try assertExpectedDigest(
        try assertReplayEquivalent(market_gap),
        expected_market_gap_digest,
    );
    if (market_gap.shard.trace.len != 25 or
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
    if (risk_rejection.shard.trace.len != 21 or
        risk_rejection.shard.last_reject_reason != .global_risk_lease_exceeded or
        risk_rejection.shard.last_risk_tier != 2 or
        risk_rejection.shard.last_risk_required_micros != 0 or
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
    if (unknown.shard.trace.len != 26 or unknown.shard.order_state != .live or
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
    if (duplicate.shard.trace.len != 35 or duplicate.shard.order_state != .filled or
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
        first.shard.trace.len != 34 or
        first.shard.trace.events[first.shard.trace.len - 1].sequence != 34 or
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
        first.shard.portfolio_ledger_debits_micros != 45_000_000_000 or
        first.shard.portfolio_ledger_credits_micros != 45_000_000_000 or
        first.shard.exchange_ledger_debits_micros != 25_000_000_000 or
        first.shard.exchange_ledger_credits_micros != 25_000_000_000)
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

test "configurable Genesis fails closed until authority is complete" {
    var incomplete: TradingShard = .{};
    try std.testing.expectError(error.GenesisIncomplete, incomplete.submitOrderIntent(.{
        .strategy_identity = 1,
        .intent_sequence = 1,
        .strategy_cursor = 1,
        .config_version = 1,
        .activation_identity = 1,
        .portfolio_identity = 1,
        .exchange_account_identity = 2,
        .instrument_identity = 3,
        .side = .buy,
        .order_type = .limit,
        .time_in_force = .good_til_canceled,
        .portfolio_reduce_only = false,
        .quantity = 1,
        .limit_price_micros = 1,
    }));

    var out_of_order: TradingShard = .{};
    try std.testing.expectError(error.InvalidMarginRules, out_of_order.apply(.{
        .identity = 1,
        .payload = .{ .margin_rules_activated = .{ .version = 1 } },
    }));

    var configured = try startScenarioAuthorized(.{
        .strategy_identity = 9,
        .config_version = 7,
        .activation_identity = 8,
        .activation_barrier = 0,
    }, .cash);
    try std.testing.expect(configured.shard.genesisReady());
    try std.testing.expectEqual(@as(u128, 9), configured.shard.strategy_identity);
    try std.testing.expectEqual(@as(i64, 100_000_000), configured.shard.quantity_denominator);
    try configured.decision_journal.seal();
    _ = try assertReplayEquivalentConfigured(configured, 100_000_000, .cash);
}

test "native and Python intents cross the same authority and risk seam" {
    const authorization: host_gateway.Authorization = .{
        .strategy_identity = 40,
        .config_version = 7,
        .activation_identity = 50,
        .activation_barrier = 0,
    };
    var native = try startScenarioAuthorized(authorization, .leveraged);
    var python = try startScenarioAuthorized(authorization, .leveraged);
    try applyHealthyPrelude(&native);
    try applyHealthyPrelude(&python);

    const native_command = (try native.shard.apply(atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }))).order_command.?;
    const python_command = (try python.shard.apply(atGroup(15, .{
        .identity = 1,
        .payload = .{ .external_order_intent = .{
            .strategy_identity = authorization.strategy_identity,
            .intent_sequence = 1,
            .strategy_cursor = python.shard.trace.len + 1,
            .config_version = authorization.config_version,
            .activation_identity = authorization.activation_identity,
            .portfolio_identity = 1,
            .exchange_account_identity = 2,
            .instrument_identity = 3,
            .side = .buy,
            .order_type = .limit,
            .time_in_force = .good_til_canceled,
            .portfolio_reduce_only = false,
            .quantity = happy_order_quantity,
            .limit_price_micros = order_limit_price,
        } },
    }))).order_command.?;
    try std.testing.expectEqual(native_command.quantity, python_command.quantity);
    try std.testing.expectEqual(native_command.limit_price_micros, python_command.limit_price_micros);
    try std.testing.expectEqual(native_command.reservation_micros, python_command.reservation_micros);

    var unauthorized = try startScenarioAuthorized(authorization, .leveraged);
    try applyHealthyPrelude(&unauthorized);
    try std.testing.expectError(error.IntentAuthorityMismatch, unauthorized.shard.apply(atGroup(15, .{
        .identity = 1,
        .payload = .{ .external_order_intent = .{
            .strategy_identity = 41,
            .intent_sequence = 1,
            .strategy_cursor = unauthorized.shard.trace.len + 1,
            .config_version = authorization.config_version,
            .activation_identity = authorization.activation_identity,
            .portfolio_identity = 1,
            .exchange_account_identity = 2,
            .instrument_identity = 3,
            .side = .buy,
            .order_type = .limit,
            .time_in_force = .good_til_canceled,
            .portfolio_reduce_only = false,
            .quantity = happy_order_quantity,
            .limit_price_micros = order_limit_price,
        } },
    })));
}

test "control commands authorize pause cancel and replay lifecycle deterministically" {
    var run = try startScenario();
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());

    const duplicate = try run.shard.apply(genesis[genesis.len - 1]);
    try std.testing.expectEqual(@as(usize, 0), duplicate.facts.len);
    try std.testing.expectError(error.ControlCommandWrongTarget, run.shard.apply(atGroup(12, .{ .identity = 9, .payload = .{ .control_command = .{
        .command_identity = 9,
        .content_hash = 9,
        .target_identity = 2,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .cancel_open_orders,
    } } })));
    try std.testing.expectError(error.ControlCommandExpired, run.shard.apply(atGroup(12, .{ .identity = 9, .payload = .{ .control_command = .{
        .command_identity = 9,
        .content_hash = 9,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = 1,
        .kind = .cancel_open_orders,
    } } })));

    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(12, .{ .identity = 3, .payload = .{ .control_command = .{
        .command_identity = 3,
        .content_hash = 3,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .trading_pause,
    } } }));
    try std.testing.expectEqual(operational.OperationalMode.draining, run.shard.operational_state.mode);
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(13, .{ .identity = 1, .payload = .{ .timer = .{ .quantity = 1 } } }))) == null);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(14, .{ .identity = 3, .payload = .{ .lifecycle_progress = .{
        .operation_identity = 3,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 0,
    } } }));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "layered gates latch kill while warning and self recovery stay narrow" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(12, .{ .identity = 10, .payload = .{ .safety_gate_change = .{
        .gate_identity = 10,
        .target_identity = 1,
        .kind = .warning,
        .reason = .margin_warning,
        .open = false,
        .blocks_buy = true,
        .blocks_sell = false,
    } } }));
    try std.testing.expect(!run.shard.operational_state.mayIncrease(true));
    try std.testing.expect(run.shard.operational_state.mayIncrease(false));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 11, .payload = .{ .safety_gate_change = .{
        .gate_identity = 11,
        .target_identity = 1,
        .kind = .self_recovering,
        .reason = .observability,
        .open = false,
    } } }));
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectError(error.UnverifiedContinuityProof, run.shard.apply(atGroup(14, .{ .identity = 11, .payload = .{ .safety_gate_change = .{
        .gate_identity = 11,
        .target_identity = 1,
        .kind = .self_recovering,
        .reason = .observability,
        .open = true,
        .continuity_proven = true,
    } } })));
    try run.shard.applyOperationalGate(.{
        .gate_identity = 11,
        .target_identity = 1,
        .kind = .self_recovering,
        .reason = .observability,
        .open = true,
        .continuity_proven = true,
    });
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    _ = try run.shard.apply(atGroup(15, .{ .identity = 12, .payload = .{ .safety_gate_change = .{
        .gate_identity = 12,
        .target_identity = 1,
        .kind = .latched,
        .reason = .margin_kill,
        .open = false,
    } } }));
    try std.testing.expect(!run.shard.operational_state.trading_authorized);
    _ = try run.shard.apply(atGroup(16, .{ .identity = 12, .payload = .{ .safety_gate_change = .{
        .gate_identity = 12,
        .target_identity = 1,
        .kind = .latched,
        .reason = .margin_kill,
        .open = true,
    } } }));
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.apply(atGroup(17, .{ .identity = 4, .payload = .{ .control_command = .{
        .command_identity = 4,
        .content_hash = 4,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .enable_trading,
    } } })));
}

test "de risk locks target and flatten requires warning" {
    var run = try startScenario();
    run.shard.portfolio_position.quantity = 10;
    run.shard.exchange_position.quantity = 10;
    run.shard.mark_price_micros = 50_000_000;
    try std.testing.expectError(error.RiskWarningRequired, run.shard.apply(atGroup(12, .{ .identity = 3, .payload = .{ .control_command = .{
        .command_identity = 3,
        .content_hash = 3,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .de_risk,
        .target_position = 0,
    } } })));
    _ = try run.shard.apply(atGroup(12, .{ .identity = 30, .payload = .{ .risk_warning = .{
        .warning_identity = 30,
        .target_identity = 1,
    } } }));
    _ = try run.shard.apply(atGroup(12, .{ .identity = 3, .payload = .{ .control_command = .{
        .command_identity = 3,
        .content_hash = 3,
        .target_identity = 1,
        .expected_version = 4,
        .expires_at = std.math.maxInt(u64),
        .kind = .de_risk,
        .target_position = 0,
        .risk_warning_acknowledged = true,
        .risk_warning_identity = 30,
    } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 100, .count = 1 };
    group.members[0] = .{ .intent_sequence = 100, .operation = .place, .instrument = .btc_usdt_swap, .side = .sell, .quantity = 5, .limit_price_micros = 50_000_000 };
    const reducing = try run.shard.apply(atGroup(13, .{ .identity = 100, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), reducing.oms_commands.len);
    group.members[0].side = .buy;
    try std.testing.expectError(error.DeRiskTargetViolation, run.shard.apply(atGroup(14, .{ .identity = 101, .payload = .{ .oms_intent_group = group } })));
}

fn placeIntentGroup(
    run: *LiveRun,
    group_index: u64,
    event_identity: u64,
    first_intent_sequence: u64,
    side: oms_module.Side,
    quantity: i64,
) !oms_module.Command {
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = first_intent_sequence, .count = 1 };
    group.members[0] = .{
        .intent_sequence = first_intent_sequence,
        .operation = .place,
        .instrument = .btc_usdt_swap,
        .side = side,
        .quantity = quantity,
        .limit_price_micros = order_limit_price,
    };
    const placed = try applyLive(&run.shard, &run.decision_journal, atGroup(group_index, .{
        .identity = event_identity,
        .payload = .{ .oms_intent_group = group },
    }));
    _ = placed;
    const emitted = run.shard.oms.emitted();
    if (emitted.len != 1) return error.UnexpectedCommandCount;
    return emitted[0];
}

fn expectKeepPositionsStopped(run: *const LiveRun, preserved: TradingShard.LifecycleEconomics) !void {
    try std.testing.expectEqual(@as(usize, 1), run.shard.oms.emitted().len);
    try std.testing.expectEqual(oms_module.Operation.cancel, run.shard.oms.emitted()[0].operation);
    try std.testing.expectEqual(operational.OperationalMode.stopped, run.shard.operational_state.mode);
    try std.testing.expect(!run.shard.operational_state.trading_authorized);
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expect(!run.shard.operational_state.mayReduceOnly());
    try std.testing.expectEqual(@as(u128, 0), run.shard.operational_state.active_operation_identity);
    try std.testing.expectEqualDeep(preserved, run.shard.captureLifecycleEconomics());
}

test "keep positions stops through shard seam preserving economics" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);

    const opened = try placeIntentGroup(&run, 15, 100, 100, .buy, happy_order_quantity);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{ .identity = 101, .payload = .{ .economic_fill = .{
        .fill_id = 101,
        .order_id = opened.order_id,
        .quantity = happy_order_quantity,
        .price_micros = 49_900_000_000,
        .fee_micros = 30,
    } } }));
    const preserved = run.shard.captureLifecycleEconomics();
    try std.testing.expect(preserved.positions.portfolio_swap.quantity != 0);
    try std.testing.expect(preserved.ledger.transaction_count != 0);

    try std.testing.expectError(error.ControlCommandWrongTarget, run.shard.apply(atGroup(17, .{ .identity = 900, .payload = .{ .control_command = .{
        .command_identity = 40,
        .content_hash = 40,
        .target_identity = 2,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .stop_keep_positions,
    } } })));
    try std.testing.expectError(error.ControlCommandExpired, run.shard.apply(atGroup(17, .{ .identity = 901, .payload = .{ .control_command = .{
        .command_identity = 40,
        .content_hash = 40,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = 1,
        .kind = .stop_keep_positions,
    } } })));
    try std.testing.expectError(error.ControlCommandVersionMismatch, run.shard.apply(lifecycleCommand(40, 999, .stop_keep_positions)));

    const stopped = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(40, 3, .stop_keep_positions));
    _ = stopped;
    try expectKeepPositionsStopped(&run, preserved);

    const duplicate_stop = try run.shard.apply(lifecycleCommand(40, 3, .stop_keep_positions));
    try std.testing.expectEqual(@as(usize, 0), duplicate_stop.facts.len);
    try std.testing.expectEqual(@as(usize, 0), run.shard.oms.emitted().len);

    var buy_group: oms_module.IntentGroup = .{ .first_intent_sequence = 110, .count = 1 };
    buy_group.members[0] = .{ .intent_sequence = 110, .operation = .place, .instrument = .btc_usdt_swap, .side = .buy, .quantity = 10, .limit_price_micros = order_limit_price };
    try std.testing.expectError(error.TradingNotAuthorized, run.shard.apply(atGroup(18, .{ .identity = 110, .payload = .{ .oms_intent_group = buy_group } })));
    var reduce_group: oms_module.IntentGroup = .{ .first_intent_sequence = 111, .count = 1 };
    reduce_group.members[0] = .{ .intent_sequence = 111, .operation = .place, .instrument = .btc_usdt_swap, .side = .sell, .portfolio_reduce_only = true, .quantity = 40, .limit_price_micros = order_limit_price };
    try std.testing.expectError(error.TradingNotAuthorized, run.shard.apply(atGroup(19, .{ .identity = 111, .payload = .{ .oms_intent_group = reduce_group } })));
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.apply(lifecycleCommand(41, 4, .enable_trading)));

    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(20, .{ .identity = 120, .payload = .{ .safety_gate_change = .{
        .gate_identity = 77,
        .target_identity = 1,
        .kind = .latched,
        .reason = .uncertain_order,
        .open = false,
    } } }));
    try std.testing.expect(run.shard.operational_state.latch_count > 0);

    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(42, 4, .start_recovery));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(21, .{ .identity = 121, .payload = .recovery_completed }));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.apply(lifecycleCommand(43, 6, .enable_trading)));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(49, 6, 77));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(50, 7, primary_lease_gate_identity));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(51, 8, risk_lease_gate_identity));
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(52, 9, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectEqual(preserved.positions.portfolio_swap.quantity, run.shard.portfolio_position.quantity);

    const resumed_reduce = try placeIntentGroup(&run, 22, 130, 130, .sell, 40);
    try std.testing.expect(resumed_reduce.portfolio_reduce_only);
    try std.testing.expectEqual(@as(i64, 40), resumed_reduce.quantity);

    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "full lifecycle trajectories authorize only prescribed risk cancel and reduce behavior" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);

    const first_order = try placeIntentGroup(&run, 15, 100, 100, .buy, happy_order_quantity);
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(3, 3, .cancel_open_orders));
    try std.testing.expectEqual(@as(usize, 1), run.shard.oms.emitted().len);
    try std.testing.expectEqual(oms_module.Operation.cancel, run.shard.oms.emitted()[0].operation);
    try std.testing.expectEqual(operational.OperationalMode.trading, run.shard.operational_state.mode);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{ .identity = 101, .payload = .{ .oms_execution_report = .{
        .report_id = 101,
        .order_id = first_order.order_id,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = 0,
        .remaining_quantity = happy_order_quantity,
    } } }));
    const requote_order = try placeIntentGroup(&run, 17, 101, 101, .buy, happy_order_quantity);
    try std.testing.expectEqual(operational.OperationalMode.trading, run.shard.operational_state.mode);

    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(4, 4, .trading_pause));
    try std.testing.expectEqual(operational.OperationalMode.draining, run.shard.operational_state.mode);
    try std.testing.expectError(error.InvalidLifecycleProgress, run.shard.apply(atGroup(18, .{ .identity = 103, .payload = .{ .lifecycle_progress = .{
        .operation_identity = 4,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 0,
    } } })));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(19, .{ .identity = 104, .payload = .{ .oms_execution_report = .{
        .report_id = 104,
        .order_id = requote_order.order_id,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = 0,
        .remaining_quantity = happy_order_quantity,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(20, .{ .identity = 105, .payload = .{ .lifecycle_progress = .{
        .operation_identity = 4,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 0,
    } } }));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);

    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(5, 6, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());

    const position_order = try placeIntentGroup(&run, 21, 102, 102, .buy, happy_order_quantity);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(22, .{ .identity = 107, .payload = .{ .economic_fill = .{
        .fill_id = 107,
        .order_id = position_order.order_id,
        .quantity = happy_order_quantity,
        .price_micros = 49_900_000_000,
        .fee_micros = 30,
    } } }));
    const preserved = run.shard.captureLifecycleEconomics();
    try std.testing.expectEqual(@as(i64, 100), preserved.positions.portfolio_swap.quantity);
    try std.testing.expectEqual(preserved.positions.portfolio_swap.quantity, preserved.positions.exchange_swap.quantity);

    const stopped = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(6, 7, .stop_keep_positions));
    _ = stopped;
    try expectKeepPositionsStopped(&run, preserved);
    var stop_buy_group: oms_module.IntentGroup = .{ .first_intent_sequence = 103, .count = 1 };
    stop_buy_group.members[0] = .{ .intent_sequence = 103, .operation = .place, .instrument = .btc_usdt_swap, .side = .buy, .quantity = 10, .limit_price_micros = order_limit_price };
    try std.testing.expectError(error.TradingNotAuthorized, run.shard.apply(atGroup(23, .{ .identity = 108, .payload = .{ .oms_intent_group = stop_buy_group } })));
    const duplicate_stop = try run.shard.apply(lifecycleCommand(6, 7, .stop_keep_positions));
    try std.testing.expectEqual(@as(usize, 0), duplicate_stop.facts.len);
    try std.testing.expectEqual(@as(usize, 0), run.shard.oms.emitted().len);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(24, .{ .identity = 121, .payload = .{ .oms_execution_report = .{
        .report_id = 121,
        .order_id = position_order.order_id,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = happy_order_quantity,
        .remaining_quantity = 0,
    } } }));

    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(7, 8, .start_recovery));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(24, .{ .identity = 109, .payload = .recovery_completed }));
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(8, 10, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectEqual(preserved.positions.portfolio_swap.quantity, run.shard.portfolio_position.quantity);

    _ = try applyLive(&run.shard, &run.decision_journal, deRiskCommand(9, 11, 40, 0));
    try std.testing.expectEqual(operational.OperationalMode.draining, run.shard.operational_state.mode);
    var increase_group: oms_module.IntentGroup = .{ .first_intent_sequence = 104, .count = 1 };
    increase_group.members[0] = .{ .intent_sequence = 104, .operation = .place, .instrument = .btc_usdt_swap, .side = .buy, .quantity = 10, .limit_price_micros = order_limit_price };
    try std.testing.expectError(error.DeRiskTargetViolation, run.shard.apply(atGroup(25, .{ .identity = 110, .payload = .{ .oms_intent_group = increase_group } })));
    const derisk_sell = try placeIntentGroup(&run, 26, 105, 105, .sell, 60);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(27, .{ .identity = 112, .payload = .{ .economic_fill = .{
        .fill_id = 112,
        .order_id = derisk_sell.order_id,
        .quantity = 60,
        .price_micros = 50_000_000_000,
        .fee_micros = 25,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(28, .{ .identity = 118, .payload = .{ .oms_execution_report = .{
        .report_id = 118,
        .order_id = derisk_sell.order_id,
        .revision = 1,
        .status = .filled,
        .cumulative_quantity = 60,
        .remaining_quantity = 0,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(29, .{ .identity = 113, .payload = .{ .lifecycle_progress = .{
        .operation_identity = 9,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 40,
    } } }));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);

    try std.testing.expectError(error.RiskWarningRequired, run.shard.apply(deRiskCommand(10, 13, 0, 0)));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(29, .{ .identity = 114, .payload = .{ .risk_warning = .{
        .warning_identity = 31,
        .target_identity = 1,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, deRiskCommand(10, 14, 0, 31));
    try std.testing.expectEqual(operational.OperationalMode.draining, run.shard.operational_state.mode);
    const flatten_sell = try placeIntentGroup(&run, 30, 106, 106, .sell, 40);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(31, .{ .identity = 116, .payload = .{ .economic_fill = .{
        .fill_id = 116,
        .order_id = flatten_sell.order_id,
        .quantity = 40,
        .price_micros = 50_000_000_000,
        .fee_micros = 20,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(32, .{ .identity = 119, .payload = .{ .oms_execution_report = .{
        .report_id = 119,
        .order_id = flatten_sell.order_id,
        .revision = 1,
        .status = .filled,
        .cumulative_quantity = 40,
        .remaining_quantity = 0,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(33, .{ .identity = 117, .payload = .{ .lifecycle_progress = .{
        .operation_identity = 10,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 0,
    } } }));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);

    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(11, 16, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(34, .{ .identity = 120, .payload = .{ .safety_gate_change = .{
        .gate_identity = margin_kill_gate_identity,
        .target_identity = 1,
        .kind = .latched,
        .reason = .margin_kill,
        .open = false,
    } } }));
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expect(run.shard.operational_state.mayReduceOnly());
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.apply(lifecycleCommand(12, 17, .enable_trading)));
    try std.testing.expectError(error.UnknownLatchIdentity, run.shard.apply(resolveLatchCommand(13, 17, 999)));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(13, 17, margin_kill_gate_identity));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);
    try std.testing.expect(!run.shard.operational_state.trading_authorized);
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(14, 18, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());

    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "venue facts and replay use apply without replay send capability" {
    comptime std.debug.assert(!@hasDecl(ReplayTradingShard, "trySend"));
    var live = try startScenario();
    try applyHealthyPrelude(&live);
    const command = (try live.shard.apply(atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }))).order_command.?;
    var simulated: LegacyFixtureVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{ .environment = .simulation, .request_capacity = 1, .output_capacity = 1 });
    try std.testing.expectEqual(venue_adapter.SendResult.accepted, try adapter.trySend(.{ .order_command = command }));
    const venue_output = (try adapter.tryDrain()).?;
    try std.testing.expect((try live.shard.apply(venue_output.dispatch_result)).order_command == null);
    for (venue_output.ingress) |event|
        try std.testing.expect((try live.shard.apply(event)).order_command == null);

    var replay_shard: ReplayTradingShard = .{};
    for (genesis) |event| _ = try replay_shard.apply(event);
    try applyHealthyPreludeReplay(&replay_shard);
    _ = try replay_shard.apply(atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }));
    _ = try replay_shard.apply(venue_output.dispatch_result);
    for (venue_output.ingress) |event| _ = try replay_shard.apply(event);
    try std.testing.expectEqualSlices(u8, &live.shard.canonicalStateDigest(), &replay_shard.canonicalStateDigest());
}

test "bounded multi instrument OMS closes lifecycle and partial policy" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 10, .policy = .independent, .count = 2 };
    group.members[0] = .{ .intent_sequence = 10, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 100, .limit_price_micros = 50_000_000, .reservation_micros = 5_000_000 };
    group.members[1] = .{ .intent_sequence = 11, .operation = .place, .instrument = .btc_usdt_swap, .quantity = 20, .limit_price_micros = 50_100_000, .reservation_micros = 1_000_000 };
    const placed = try run.shard.apply(atGroup(12, .{ .identity = 10, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 2), placed.oms_commands.len);
    try std.testing.expect(placed.oms_commands[0].instrument != placed.oms_commands[1].instrument);

    var dispatch: oms_module.DispatchBatch = .{ .count = 2 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .submitted };
    dispatch.items[1] = .{ .command_id = placed.oms_commands[1].command_id, .state = .unknown };
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    try std.testing.expectEqual(oms_module.OrderState.unknown, run.shard.oms.orders[1].state);
    try std.testing.expect(run.shard.oms.orders[1].reservation_active);
    _ = try run.shard.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{
        .reconciliation_id = 1,
        .order_id = 2,
        .status = .found_live,
        .revision = 1,
        .cumulative_quantity = 0,
        .remaining_quantity = 20,
    } } }));

    _ = try run.shard.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_execution_report = .{
        .report_id = 1,
        .order_id = 1,
        .revision = 1,
        .status = .accepted,
        .cumulative_quantity = 0,
        .remaining_quantity = 100,
    } } }));
    var amend: oms_module.IntentGroup = .{ .first_intent_sequence = 12, .count = 1 };
    amend.members[0] = .{ .intent_sequence = 12, .operation = .amend, .instrument = .btc_usdt_spot, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price_micros = 49_900_000, .reservation_micros = 4_000_000 };
    const amended = try run.shard.apply(atGroup(16, .{ .identity = 12, .payload = .{ .oms_intent_group = amend } }));
    try std.testing.expectEqual(oms_module.Operation.amend, amended.oms_commands[0].operation);
    try std.testing.expectEqual(@as(u32, 2), run.shard.oms.orders[0].revision);
    try std.testing.expectEqual(placed.oms_commands[0].reservation_micros, run.shard.oms.orders[0].reservation_micros);
    try std.testing.expectError(error.StaleOrderRevision, run.shard.apply(atGroup(17, .{ .identity = 13, .payload = .{ .oms_intent_group = amend } })));

    var cancel: oms_module.IntentGroup = .{ .first_intent_sequence = 13, .count = 1 };
    cancel.members[0] = .{ .intent_sequence = 13, .operation = .cancel, .instrument = .btc_usdt_swap, .target_order_id = 2, .expected_revision = 1 };
    const canceled = try run.shard.apply(atGroup(18, .{ .identity = 13, .payload = .{ .oms_intent_group = cancel } }));
    try std.testing.expectEqual(oms_module.Operation.cancel, canceled.oms_commands[0].operation);
    _ = try run.shard.apply(atGroup(19, .{ .identity = 2, .payload = .{ .oms_execution_report = .{
        .report_id = 2,
        .order_id = 2,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = 0,
        .remaining_quantity = 20,
    } } }));
    const digest = run.shard.canonicalStateDigest();
    var replayed: ReplayTradingShard = .{};
    for (genesis) |event| _ = try replayed.apply(event);
    _ = try replayed.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    _ = try replayed.apply(atGroup(12, .{ .identity = 10, .payload = .{ .oms_intent_group = group } }));
    _ = try replayed.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    _ = try replayed.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 2, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 20 } } }));
    _ = try replayed.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    _ = try replayed.apply(atGroup(16, .{ .identity = 12, .payload = .{ .oms_intent_group = amend } }));
    _ = try replayed.apply(atGroup(18, .{ .identity = 13, .payload = .{ .oms_intent_group = cancel } }));
    _ = try replayed.apply(atGroup(19, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 2, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 20 } } }));
    try std.testing.expectEqualSlices(u8, &digest, &replayed.canonicalStateDigest());
}

test "CancelConfirmCreate never overlaps and records predecessor" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 20, .count = 1 };
    place.members[0] = .{ .intent_sequence = 20, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 100, .limit_price_micros = 50_000_000, .reservation_micros = 5_000_000 };
    const placed = try run.shard.apply(atGroup(12, .{ .identity = 20, .payload = .{ .oms_intent_group = place } }));
    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .submitted };
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    _ = try run.shard.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));

    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 21, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 21, .operation = .amend, .instrument = .btc_usdt_spot, .target_order_id = 1, .expected_revision = 1, .quantity = 75, .limit_price_micros = 49_800_000, .native_amend = false, .allow_cancel_confirm_create = true, .reservation_micros = 3_750_000 };
    const cancel_first = try run.shard.apply(atGroup(15, .{ .identity = 21, .payload = .{ .oms_intent_group = replace } }));
    try std.testing.expectEqual(@as(usize, 1), cancel_first.oms_commands.len);
    try std.testing.expectEqual(oms_module.Operation.cancel, cancel_first.oms_commands[0].operation);
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try std.testing.expect(run.shard.oms.orders[0].reservation_active);
    var cancel_unknown: oms_module.DispatchBatch = .{ .count = 1 };
    cancel_unknown.items[0] = .{ .command_id = cancel_first.oms_commands[0].command_id, .state = .unknown };
    _ = try run.shard.apply(atGroup(16, .{ .identity = 2, .payload = .{ .oms_dispatch_batch = cancel_unknown } }));
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    _ = try run.shard.apply(atGroup(17, .{ .identity = 2, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 2, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 25, .remaining_quantity = 75 } } }));
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    const replacement = try run.shard.apply(atGroup(18, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 25, .remaining_quantity = 75 } } }));
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(u64, 1), run.shard.oms.orders[1].predecessor_order_id);
    try std.testing.expectEqual(oms_module.Operation.place, replacement.oms_commands[0].operation);
    try std.testing.expect(!run.shard.oms.orders[0].reservation_active);
    try std.testing.expect(run.shard.oms.orders[1].reservation_active);
    _ = try run.shard.apply(atGroup(19, .{ .identity = 3, .payload = .{ .oms_execution_report = .{ .report_id = 3, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 25, .remaining_quantity = 75 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    try std.testing.expectError(error.ConflictingReportIdentity, run.shard.apply(atGroup(20, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 100, .remaining_quantity = 0 } } })));
}

test "IntentGroup batch results remain itemized" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 30, .policy = .cancel_remaining, .count = 3 };
    for (group.members[0..3], 0..) |*member, index| member.* = .{ .intent_sequence = 30 + index, .operation = .place, .instrument = if (index == 1) .btc_usdt_swap else .btc_usdt_spot, .quantity = 10, .limit_price_micros = 50_000_000, .reservation_micros = 500_000 };
    const commands = try run.shard.apply(atGroup(12, .{ .identity = 30, .payload = .{ .oms_intent_group = group } }));
    var batch: oms_module.DispatchBatch = .{ .count = 3 };
    batch.items[0] = .{ .command_id = commands.oms_commands[0].command_id, .state = .submitted };
    batch.items[1] = .{ .command_id = commands.oms_commands[1].command_id, .state = .submitted, .definite_reject = true };
    batch.items[2] = .{ .command_id = commands.oms_commands[2].command_id, .state = .not_sent };
    const outcome = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = batch } }));
    try std.testing.expectEqual(oms_module.OrderState.pending_cancel, run.shard.oms.orders[0].state);
    try std.testing.expectEqual(oms_module.OrderState.rejected, run.shard.oms.orders[1].state);
    try std.testing.expectEqual(oms_module.OrderState.rejected, run.shard.oms.orders[2].state);
    try std.testing.expect(run.shard.oms.orders[0].reservation_active);
    try std.testing.expect(!run.shard.oms.orders[1].reservation_active);
    try std.testing.expect(!run.shard.oms.orders[2].reservation_active);
    try std.testing.expectEqual(@as(usize, 1), outcome.oms_commands.len);
    try std.testing.expectEqual(oms_module.Operation.cancel, outcome.oms_commands[0].operation);
}

test "layered risk owns reservations until authoritative absence" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 40, .count = 1 };
    group.members[0] = .{ .intent_sequence = 40, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 100, .limit_price_micros = 50_000_000, .reservation_micros = 1 };
    const placed = try run.shard.apply(atGroup(12, .{ .identity = 40, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(i64, 500_375), placed.oms_commands[0].reservation_micros);
    try std.testing.expectEqual(@as(i64, 500_375), run.shard.layered_risk_reserved_micros);

    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .unknown };
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    try std.testing.expectEqual(@as(i64, 500_375), run.shard.layered_risk_reserved_micros);
    _ = try run.shard.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .confirmed_absent, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(@as(i64, 0), run.shard.layered_risk_reserved_micros);

    var limited = try startScenario();
    _ = try limited.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    limited.shard.strategy_limit_micros = 500_000;
    try std.testing.expectError(error.StrategyLimitExceeded, limited.shard.apply(atGroup(12, .{ .identity = 40, .payload = .{ .oms_intent_group = group } })));
    try std.testing.expectEqual(@as(u8, 0), limited.shard.oms.order_count);
}

test "TradingShard preserves maintenance margin in the projected buffer" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 45, .count = 1 };
    group.members[0] = .{ .intent_sequence = 45, .operation = .place, .instrument = .btc_usdt_swap, .quantity = 100, .limit_price_micros = 50_000_000 };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 45, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(i64, 11_375), run.shard.layered_risk_reserved_micros);
    try std.testing.expectEqual(@as(i64, 19_999_982_750), run.shard.portfolio_margin_buffer_micros);
}

test "rejected IntentGroup leaves authoritative state unchanged" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    const before = run.shard.canonicalStateDigest();
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 50, .count = 2 };
    group.members[0] = .{ .intent_sequence = 50, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 10, .limit_price_micros = 50_000_000 };
    group.members[1] = .{ .intent_sequence = 51, .operation = .cancel, .instrument = .btc_usdt_spot, .target_order_id = 999, .expected_revision = 1 };
    try std.testing.expectError(error.UnknownOrder, run.shard.apply(atGroup(12, .{ .identity = 50, .payload = .{ .oms_intent_group = group } })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "rejected dispatch batch leaves authoritative state unchanged" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 55, .count = 1 };
    group.members[0] = .{ .intent_sequence = 55, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 10, .limit_price_micros = 50_000_000 };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 55, .payload = .{ .oms_intent_group = group } }));
    const before = run.shard.canonicalStateDigest();
    var batch: oms_module.DispatchBatch = .{ .count = 2 };
    batch.items[0] = .{ .command_id = 1, .state = .unknown };
    batch.items[1] = .{ .command_id = 999, .state = .submitted };
    try std.testing.expectError(error.UnknownCommand, run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = batch } })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "rejected execution report leaves authoritative state unchanged" {
    var run = try startScenario();
    const before = run.shard.canonicalStateDigest();
    try std.testing.expectError(error.UnknownOrder, run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .oms_execution_report = .{
        .report_id = 1,
        .order_id = 999,
        .revision = 1,
        .status = .accepted,
        .cumulative_quantity = 0,
        .remaining_quantity = 10,
    } } })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "authoritative reconciliation cannot regress a terminal order" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 60, .count = 1 };
    group.members[0] = .{ .intent_sequence = 60, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 10, .limit_price_micros = 50_000_000 };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 60, .payload = .{ .oms_intent_group = group } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    _ = try run.shard.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    _ = try run.shard.apply(atGroup(15, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectError(error.ConflictingReportIdentity, run.shard.apply(atGroup(16, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 10, .remaining_quantity = 0 } } })));
}

test "CancelConfirmCreate re-risks replacement against latest facts" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 70, .count = 1 };
    place.members[0] = .{ .intent_sequence = 70, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 100, .limit_price_micros = 50_000_000 };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 70, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 71, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 71, .operation = .amend, .instrument = .btc_usdt_spot, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price_micros = 49_000_000, .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try run.shard.apply(atGroup(14, .{ .identity = 71, .payload = .{ .oms_intent_group = replace } }));
    run.shard.strategy_limit_micros = 100;
    const result = try run.shard.apply(atGroup(15, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 0), result.oms_commands.len);
}

test "qualified command carries independently inferred reduce-only flags" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    run.shard.portfolio_position.quantity = 10;
    run.shard.exchange_position.quantity = -5;
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 75, .count = 1 };
    group.members[0] = .{ .intent_sequence = 75, .operation = .place, .instrument = .btc_usdt_swap, .side = .sell, .quantity = 8, .limit_price_micros = 50_000_000 };
    const result = try run.shard.apply(atGroup(12, .{ .identity = 75, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), result.oms_commands.len);
    try std.testing.expect(result.oms_commands[0].portfolio_reduce_only);
    try std.testing.expect(!result.oms_commands[0].venue_reduce_only);
}

test "SPOT asset risk is isolated from SWAP positions" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    run.shard.portfolio_position.quantity = 10;
    run.shard.exchange_position.quantity = 10;
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 79, .count = 1 };
    group.members[0] = .{ .intent_sequence = 79, .operation = .place, .instrument = .btc_usdt_spot, .side = .sell, .quantity = 1, .limit_price_micros = 50_000_000 };
    try std.testing.expectError(error.InsufficientSpotAsset, run.shard.apply(atGroup(12, .{ .identity = 79, .payload = .{ .oms_intent_group = group } })));
}

test "economic fills derive ownership from OMS and close Portfolio Exchange ledgers" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 79, .count = 1 };
    group.members[0] = .{ .intent_sequence = 79, .operation = .place, .instrument = .btc_usdt_swap, .side = .buy, .quantity = 10, .limit_price_micros = 50_000_000 };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 79, .payload = .{ .oms_intent_group = group } }));
    run.shard.risk_lease_micros = 1;
    run.shard.risk_lease_remaining_micros = 1;
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .economic_fill = .{ .fill_id = 1, .order_id = 1, .quantity = 4, .price_micros = 50_000_000, .fee_micros = 15 } } }));
    _ = try run.shard.apply(atGroup(14, .{ .identity = 2, .payload = .{ .economic_fill = .{ .fill_id = 2, .order_id = 1, .quantity = 6, .price_micros = 51_000_000, .fee_micros = 20, .rebate_micros = 5 } } }));
    const summary = run.shard.economicSummary();
    try std.testing.expectEqual(@as(i64, 10), summary.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, 50_600), summary.portfolio.swap.open_cost_micros);
    try std.testing.expectEqual(@as(i64, 1_114), summary.portfolio.margin_micros);
    try std.testing.expectEqual(@as(i64, 1_012), summary.exchange.margin_micros);
    try std.testing.expectEqual(@as(i64, 35), summary.portfolio.fee_micros);
    try std.testing.expectEqual(@as(i64, 5), summary.portfolio.rebate_micros);
    try std.testing.expectEqual(@as(u8, 10), summary.ledger_transactions);
    try std.testing.expect(run.shard.risk_lease_remaining_micros < 0);
    try std.testing.expectEqual(summary.portfolio.swap.quantity, run.shard.portfolio_position.quantity);
    try std.testing.expectEqual(summary.portfolio.usdt_balance_micros, run.shard.portfolio_cash_micros);
    try std.testing.expect(!summary.reconciliation_break);
}

test "funding forced execution and snapshots preserve auditable local economics" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    const before = run.shard.economicSummary();
    _ = try run.shard.apply(atGroup(12, .{ .identity = 10, .payload = .{ .funding_settlement = .{ .settlement_id = 10, .amount_micros = -25 } } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 11, .payload = .{ .venue_forced_execution = .{ .execution_id = 11, .side = .sell, .quantity = 2, .price_micros = 50_000_000, .fee_micros = 3, .penalty_micros = 2 } } }));
    const projected = run.shard.economicSummary();
    try std.testing.expectEqual(@as(i64, 0), projected.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, -2), projected.exchange.swap.quantity);
    try std.testing.expectEqual(@as(i64, -30), projected.suspense_usdt_micros);
    try std.testing.expectEqual(projected.exchange.swap.quantity, run.shard.exchange_position.quantity);
    try std.testing.expectEqual(projected.exchange.usdt_balance_micros, run.shard.exchange_cash_micros);
    try std.testing.expect(projected.reconciliation_break);
    try std.testing.expectEqual(@as(u8, 4), projected.ledger_transactions);

    const local_exchange = projected.exchange;
    _ = try run.shard.apply(atGroup(14, .{ .identity = 12, .payload = .{ .economic_account_snapshot = .{ .snapshot_id = 12, .usdt_balance_micros = before.exchange.usdt_balance_micros, .spot_asset_quantity = 99, .swap_position_quantity = 99, .margin_micros = 99 } } }));
    try std.testing.expectEqualDeep(local_exchange, run.shard.economicSummary().exchange);
    try std.testing.expectError(error.ConflictingEconomicIdentity, run.shard.apply(atGroup(15, .{ .identity = 10, .payload = .{ .funding_settlement = .{ .settlement_id = 10, .amount_micros = -26 } } })));
}

test "duplicate economic facts are no-op at the TradingShard seam" {
    var run = try startScenario();
    const funding = atGroup(11, .{ .identity = 30, .payload = .{ .funding_settlement = .{ .settlement_id = 30, .amount_micros = -5 } } });
    _ = try run.shard.apply(funding);
    const before = run.shard.canonicalStateDigest();
    const result = try run.shard.apply(funding);
    try std.testing.expectEqual(@as(usize, 0), result.facts.len);
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "CancelConfirmCreate accepts authoritative reconciliation as confirmation" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 76, .count = 1 };
    place.members[0] = .{ .intent_sequence = 76, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 100, .limit_price_micros = 50_000_000 };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 76, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 77, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 77, .operation = .amend, .instrument = .btc_usdt_spot, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price_micros = 49_000_000, .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try run.shard.apply(atGroup(14, .{ .identity = 77, .payload = .{ .oms_intent_group = replace } }));
    const result = try run.shard.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .confirmed_absent, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 1), result.oms_commands.len);
    try std.testing.expectEqual(@as(u64, 1), result.oms_commands[0].predecessor_order_id);
}

test "older reconciliation identity still rejects semantic conflict" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 78, .count = 1 };
    place.members[0] = .{ .intent_sequence = 78, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 10, .limit_price_micros = 50_000_000 };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 78, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .unresolved, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    _ = try run.shard.apply(atGroup(14, .{ .identity = 2, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 2, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectError(error.ConflictingReconciliationIdentity, run.shard.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } })));
}

test "multiple SPOT and SWAP orders independently close place amend and cancel" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 80, .count = 4 };
    place.members[0] = .{ .intent_sequence = 80, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 10, .limit_price_micros = 50_000_000 };
    place.members[1] = .{ .intent_sequence = 81, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 10, .limit_price_micros = 50_000_000 };
    place.members[2] = .{ .intent_sequence = 82, .operation = .place, .instrument = .btc_usdt_swap, .quantity = 10, .limit_price_micros = 50_000_000 };
    place.members[3] = .{ .intent_sequence = 83, .operation = .place, .instrument = .btc_usdt_swap, .quantity = 10, .limit_price_micros = 50_000_000 };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 80, .payload = .{ .oms_intent_group = place } }));
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |order_id, index| _ = try run.shard.apply(atGroup(13 + index, .{ .identity = 1 + index, .payload = .{ .oms_execution_report = .{ .report_id = 1 + index, .order_id = order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));

    var amend: oms_module.IntentGroup = .{ .first_intent_sequence = 84, .count = 4 };
    amend.members[0] = .{ .intent_sequence = 84, .operation = .amend, .instrument = .btc_usdt_spot, .target_order_id = 1, .expected_revision = 1, .quantity = 8, .limit_price_micros = 49_000_000 };
    amend.members[1] = .{ .intent_sequence = 85, .operation = .amend, .instrument = .btc_usdt_spot, .target_order_id = 2, .expected_revision = 1, .quantity = 8, .limit_price_micros = 49_000_000 };
    amend.members[2] = .{ .intent_sequence = 86, .operation = .amend, .instrument = .btc_usdt_swap, .target_order_id = 3, .expected_revision = 1, .quantity = 8, .limit_price_micros = 49_000_000 };
    amend.members[3] = .{ .intent_sequence = 87, .operation = .amend, .instrument = .btc_usdt_swap, .target_order_id = 4, .expected_revision = 1, .quantity = 8, .limit_price_micros = 49_000_000 };
    _ = try run.shard.apply(atGroup(17, .{ .identity = 84, .payload = .{ .oms_intent_group = amend } }));
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |order_id, index| _ = try run.shard.apply(atGroup(18 + index, .{ .identity = 5 + index, .payload = .{ .oms_execution_report = .{ .report_id = 5 + index, .order_id = order_id, .revision = 2, .status = .amended, .cumulative_quantity = 0, .remaining_quantity = 8 } } }));

    var cancel: oms_module.IntentGroup = .{ .first_intent_sequence = 88, .count = 4 };
    cancel.members[0] = .{ .intent_sequence = 88, .operation = .cancel, .instrument = .btc_usdt_spot, .target_order_id = 1, .expected_revision = 2 };
    cancel.members[1] = .{ .intent_sequence = 89, .operation = .cancel, .instrument = .btc_usdt_spot, .target_order_id = 2, .expected_revision = 2 };
    cancel.members[2] = .{ .intent_sequence = 90, .operation = .cancel, .instrument = .btc_usdt_swap, .target_order_id = 3, .expected_revision = 2 };
    cancel.members[3] = .{ .intent_sequence = 91, .operation = .cancel, .instrument = .btc_usdt_swap, .target_order_id = 4, .expected_revision = 2 };
    _ = try run.shard.apply(atGroup(22, .{ .identity = 88, .payload = .{ .oms_intent_group = cancel } }));
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |order_id, index| _ = try run.shard.apply(atGroup(23 + index, .{ .identity = 9 + index, .payload = .{ .oms_execution_report = .{ .report_id = 9 + index, .order_id = order_id, .revision = 2, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 8 } } }));
    for (run.shard.oms.orders[0..4]) |order| try std.testing.expectEqual(oms_module.OrderState.canceled, order.state);
    try std.testing.expectEqual(@as(i64, 0), run.shard.layered_risk_reserved_micros);
}

fn applyHealthyPreludeReplay(replay_shard: *ReplayTradingShard) !void {
    _ = try replay_shard.apply(atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000_000 } }));
    _ = try replay_shard.apply(snapshotAt(13, 100));
    _ = try replay_shard.apply(deltaAt(14, 100, 101, 49_850_000_000));
}

test "venue adapter seam is bounded and drain-safe" {
    var simulated: LegacyFixtureVenue = .{};
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

test "authoritative snapshot round trips at an exact shard barrier" {
    const run = try runHappyPath();
    var storage: [32 * 1024]u8 = undefined;
    const encoded = try run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence, &storage);
    const restored = try TradingShard.restoreSnapshot(encoded);

    try std.testing.expectEqual(run.decision_journal.last_sequence, restored.barrier);
    try std.testing.expectEqualSlices(u8, &run.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());

    var duplicate_storage: [32 * 1024]u8 = undefined;
    const duplicate = try run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence, &duplicate_storage);
    try std.testing.expectEqualSlices(u8, encoded, duplicate);

    const independent = try runHappyPath();
    var independent_storage: [32 * 1024]u8 = undefined;
    const independent_encoded = try independent.shard.snapshot(&independent.decision_journal, independent.decision_journal.last_sequence, &independent_storage);
    try std.testing.expectEqualSlices(u8, encoded, independent_encoded);

    var damaged_storage: [32 * 1024]u8 = undefined;
    @memcpy(damaged_storage[0..encoded.len], encoded);
    damaged_storage[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidSnapshotPayload, TradingShard.restoreSnapshot(damaged_storage[0..encoded.len]));
    try std.testing.expectError(error.InvalidSnapshotBarrier, run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence - 1, &duplicate_storage));
}

test "snapshot restore replays only the stable journal tail without send capability" {
    var prefix = try startScenario();
    try prefix.decision_journal.seal();
    var snapshot_storage: [32 * 1024]u8 = undefined;
    const encoded = try prefix.shard.snapshot(&prefix.decision_journal, prefix.decision_journal.last_sequence, &snapshot_storage);

    var live = prefix.shard;
    var tail = journal.Journal.initAt(prefix.decision_journal.last_sequence + 1);
    _ = try applyLive(&live, &tail, atGroup(12, .{ .identity = 9, .payload = .{ .mark_price = 50_000_000_000 } }));
    try tail.seal();

    const recovered = try TradingShard.restore(encoded, tail.bytes());
    try std.testing.expectEqual(journal.ScanStatus.clean, recovered.status);
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    comptime std.debug.assert(!@hasDecl(SnapshotRecovery, "trySend"));

    const truncated = try TradingShard.restore(encoded, tail.bytes()[0 .. tail.len - 1]);
    try std.testing.expectEqual(journal.ScanStatus.truncated_tail, truncated.status);
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &truncated.shard.canonicalStateDigest());

    var gap = journal.Journal.initAt(prefix.decision_journal.last_sequence + 2);
    try std.testing.expectError(error.SnapshotJournalGap, TradingShard.restore(encoded, gap.bytes()));
}

test "OKX spot authoritative projection" {
    _ = okx_spot_projection;
}

test "qualified SPOT IOC intent crosses Gateway and cash risk before OrderCommand" {
    const authorization: host_gateway.Authorization = .{
        .strategy_identity = 40,
        .config_version = 1,
        .activation_identity = 50,
        .activation_barrier = 10,
    };
    const config: host_gateway.Config = .{
        .schema_registry = 1,
        .decision_domain = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
        .authorization = authorization,
    };
    const subscriptions = [_]host_gateway.Subscription{
        host_gateway.Subscription.of(authorization.strategy_identity, &.{.mark_price}),
    };
    var gateway = try host_gateway.Gateway.init(config, &subscriptions);
    try gateway.recordPublished(1, 14, 100);
    var frame_storage: [256]u8 = undefined;
    const frame = try host_gateway.encodeOutputOrderFrame(&frame_storage, config, 1, 14, 7, .{
        .time_in_force = .immediate_or_cancel,
        .quantity = 5_000,
        .limit_price_micros = 63_500_000_000,
    });
    const decision = gateway.ingest(frame, 100);
    try std.testing.expect(decision == .accepted);
    var ingress = try TradingShardHostIngress.initHealthySpotFixtureFor(authorization);
    const command = (try ingress.applyDecisionCommand(decision)).?;
    try std.testing.expectEqual(host_gateway.TimeInForce.immediate_or_cancel, command.time_in_force);
    try std.testing.expectEqual(@as(i64, 5_000), command.quantity);
    try std.testing.expectEqual(@as(i64, 3_177_382), command.reservation_micros);
    try ingress.verifyReplay();
}
