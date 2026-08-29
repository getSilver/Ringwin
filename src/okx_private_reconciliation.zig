//! Fail-closed OKX Demo private-fact decoder and REST+WS reconciliation barrier.
//! Complete messages are committed to RawIngress before parsing. REST bootstrap
//! facts are released before buffered WS facts; a disconnect or ambiguity revokes
//! readiness and requires a fresh session plus complete endpoint-specific bootstrap.

const std = @import("std");
const market = @import("okx_public_market.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Decimal = market.Decimal;
pub const Instrument = market.Instrument;
pub const Times = market.Times;
pub const RawSink = market.RawSink;
pub const RawSinkError = market.RawSinkError;
pub const RawEvidenceRef = market.RawEvidenceRef;
pub const EventEnvelope = market.EventEnvelope;

pub const max_page_rows = 20;
pub const max_events_per_ingress = max_page_rows * 2;
pub const max_bootstrap_events = 160;
pub const max_ws_events = 128;
pub const max_seen_facts = 512;

pub fn FixedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: std.math.IntFittingRange(0, capacity),

        pub fn init(text: []const u8) !@This() {
            if (text.len > capacity) return error.InvalidField;
            var result: @This() = .{ .len = @intCast(text.len) };
            @memcpy(result.bytes[0..text.len], text);
            return result;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const VenueOrderId = enum(u64) { _ };
pub const VenueTradeId = enum(i64) { _ };
pub const VenueBillId = enum(u64) { _ };
pub const VenuePositionId = enum(u64) { _ };
pub const ClientOrderId = FixedText(32);
pub const AssetCode = FixedText(16);

pub const Side = enum(u8) { buy, sell };
pub const PositionSide = enum(u8) { net };
pub const MarginMode = enum(u8) { isolated };
pub const OrderType = enum(u8) { market, limit, post_only, fok, ioc };
pub const ExecutionStatus = enum(u8) { live, partially_filled, filled, canceled };
pub const Liquidity = enum(u8) { maker, taker };

pub const ExecutionReport = struct {
    venue_order_id: VenueOrderId,
    client_order_id: ClientOrderId,
    instrument: Instrument,
    side: Side,
    order_type: OrderType,
    status: ExecutionStatus,
    quantity: Decimal,
    limit_price: ?Decimal,
    cumulative_filled_quantity: Decimal,
    average_fill_price: ?Decimal,
    request_id: FixedText(32),
    last_trade_id: ?VenueTradeId,
    venue_update_time_utc_ns: u64,
    owned_by_ringwin: bool,
};

pub const Fill = struct {
    venue_trade_id: VenueTradeId,
    venue_bill_id: ?VenueBillId,
    venue_order_id: VenueOrderId,
    client_order_id: ClientOrderId,
    instrument: Instrument,
    side: Side,
    quantity: Decimal,
    price: Decimal,
    fee: Decimal,
    fee_asset: AssetCode,
    rebate: ?Decimal = null,
    rebate_asset: ?AssetCode = null,
    realized_pnl: ?Decimal,
    liquidity: ?Liquidity,
    venue_fill_time_utc_ns: u64,
    owned_by_ringwin: bool,
};

pub const SnapshotScope = enum(u8) { full_rest, ws_reported };

pub const Balance = struct {
    asset: AssetCode,
    cash_balance: ?Decimal,
    available_balance: ?Decimal,
    equity: ?Decimal,
    frozen_balance: ?Decimal,
    liability: ?Decimal,
    isolated_liability: ?Decimal,
    cross_liability: ?Decimal,
};

pub const ExchangeBalanceSnapshot = struct {
    scope: SnapshotScope,
    venue_update_time_utc_ns: u64,
    balances: [8]Balance = undefined,
    balance_count: u8 = 0,
};

pub const Position = struct {
    venue_position_id: VenuePositionId,
    instrument: Instrument,
    margin_mode: MarginMode,
    position_side: PositionSide,
    quantity: Decimal,
    average_price: ?Decimal,
    mark_price: ?Decimal,
    liquidation_price: ?Decimal,
    margin: ?Decimal,
    leverage: ?Decimal,
    unrealized_pnl: ?Decimal,
    venue_update_time_utc_ns: u64,
};

pub const ExchangePositionSnapshot = struct {
    scope: SnapshotScope,
    positions: [8]Position = undefined,
    position_count: u8 = 0,
    includes_zero_positions: bool,
};

pub const ExchangeMarginSnapshot = struct {
    scope: SnapshotScope,
    venue_update_time_utc_ns: u64,
    total_equity_usd: ?Decimal,
    adjusted_equity_usd: ?Decimal,
    initial_margin_usd: ?Decimal,
    maintenance_margin_usd: ?Decimal,
    margin_ratio: ?Decimal,
    isolated_equity_usd: ?Decimal,
};

pub const AccountLevel = enum(u8) { futures };
pub const PositionMode = enum(u8) { net };
pub const ContractIsolatedMode = enum(u8) { automatic, autonomy };

pub const VenueAccountConfigurationSnapshot = union(enum) {
    account: struct {
        account_level: AccountLevel,
        position_mode: PositionMode,
        contract_isolated_mode: ContractIsolatedMode,
        auto_loan: bool,
        spot_borrow_enabled: bool,
        can_read: bool,
        can_trade: bool,
        can_withdraw: bool,
    },
    isolated_leverage: struct {
        instrument: Instrument,
        margin_mode: MarginMode,
        position_side: PositionSide,
        leverage: Decimal,
    },
};

pub const EventPayload = union(enum) {
    execution_report: ExecutionReport,
    fill: Fill,
    exchange_balance_snapshot: ExchangeBalanceSnapshot,
    exchange_position_snapshot: ExchangePositionSnapshot,
    exchange_margin_snapshot: ExchangeMarginSnapshot,
    venue_account_configuration_snapshot: VenueAccountConfigurationSnapshot,
};

pub const PrivateEvent = struct {
    envelope: EventEnvelope,
    payload: EventPayload,
};

pub const PrivateChannel = enum(u8) { orders, account, positions };

pub const IngressSource = enum(u8) {
    ws_orders,
    ws_account,
    ws_positions,
    rest_account_config,
    rest_leverage,
    rest_balance,
    rest_positions,
    rest_orders_pending,
    rest_orders_history_spot,
    rest_orders_history_swap,
    rest_fills_history_spot,
    rest_fills_history_swap,

    fn isWebSocket(self: IngressSource) bool {
        return switch (self) {
            .ws_orders, .ws_account, .ws_positions => true,
            else => false,
        };
    }
};

pub const Page = struct {
    requested_after: ?u64 = null,
    final: bool,
};

pub const RejectReason = enum(u8) {
    stale_session,
    malformed_json,
    malformed_envelope,
    venue_error,
    source_mismatch,
    unsupported_instrument,
    unsupported_value,
    invalid_field,
    page_too_large,
    invalid_page_cursor,
    conflicting_fact,
    bootstrap_buffer_full,
};

pub const IngressBatch = struct {
    raw_evidence: RawEvidenceRef,
    events: [max_events_per_ingress]PrivateEvent = undefined,
    event_count: u8 = 0,
    rejection: ?RejectReason = null,
    buffered: bool = false,
    oldest_cursor: ?u64 = null,

    pub fn eventSlice(self: *const IngressBatch) []const PrivateEvent {
        return self.events[0..self.event_count];
    }

    fn append(self: *IngressBatch, event: PrivateEvent) !void {
        if (self.event_count == self.events.len) return error.BufferFull;
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

pub const Readiness = struct {
    private_stream_ready: bool,
    reconciliation_ready: bool,
    session: u64,
    bootstrap_watermark: ?u64,
};

pub const ReconciliationReady = struct {
    session: u64,
    bootstrap_watermark: u64,
    last_raw_sequence: u64,
};

pub const UnknownResolution = enum(u8) {
    found_live,
    found_terminal,
    confirmed_absent,
    still_unknown,
};

const Stage = enum(u8) { offline, subscribing, buffering, reconciling, ready, failed };

const SeenFact = struct {
    identity: [Sha256.digest_length]u8,
    content: [Sha256.digest_length]u8,
};

const RequiredRest = enum(u8) {
    account_config,
    leverage,
    balance,
    positions,
    orders_pending,
    orders_history_spot,
    orders_history_swap,
    fills_history_spot,
    fills_history_swap,
};

const required_rest_count = @typeInfo(RequiredRest).@"enum".fields.len;

const EndpointState = struct {
    started: bool = false,
    complete: bool = false,
    last_oldest_cursor: ?u64 = null,
    digest: [Sha256.digest_length]u8 = @splat(0),
    page_count: u16 = 0,
};

const WsSnapshotState = struct {
    next_page: u32 = 1,
    complete: bool = false,
};

pub const Reconciler = struct {
    stage: Stage = .offline,
    session: u64 = 0,
    subscriptions: [3]bool = .{ false, false, false },
    rest: [required_rest_count]EndpointState = @splat(.{}),
    stable_rest_digests: [required_rest_count][Sha256.digest_length]u8 = undefined,
    stability_round: u8 = 1,
    ws_snapshots: [2]WsSnapshotState = .{ .{}, .{} },
    bootstrap_watermark: ?u64 = null,
    last_raw_sequence: u64 = 0,
    unresolved_unknowns: usize = 0,
    unattributed_fact_seen: bool = false,
    seen: [max_seen_facts]SeenFact = undefined,
    seen_count: usize = 0,
    bootstrap_events: [max_bootstrap_events]PrivateEvent = undefined,
    bootstrap_event_count: usize = 0,
    ws_events: [max_ws_events]PrivateEvent = undefined,
    ws_event_count: usize = 0,
    drain_bootstrap_index: usize = 0,
    drain_ws_index: usize = 0,

    pub fn beginSession(self: *Reconciler, session: u64) void {
        self.* = .{ .stage = .subscribing, .session = session };
    }

    pub fn subscriptionAcknowledged(self: *Reconciler, channel: PrivateChannel) !void {
        if (self.stage != .subscribing and self.stage != .buffering)
            return error.InvalidStage;
        self.subscriptions[@intFromEnum(channel)] = true;
        self.updatePrivateStreamStage();
    }

    pub fn beginReconciliation(self: *Reconciler, raw_watermark: u64) !void {
        if (self.stage != .buffering) return error.PrivateStreamNotReady;
        self.bootstrap_watermark = raw_watermark;
        self.stage = .reconciling;
    }

    pub fn disconnect(self: *Reconciler) void {
        self.stage = .offline;
        self.subscriptions = .{ false, false, false };
        self.bootstrap_watermark = null;
        self.bootstrap_event_count = 0;
        self.ws_event_count = 0;
        self.drain_bootstrap_index = 0;
        self.drain_ws_index = 0;
    }

    pub fn registerUnknown(self: *Reconciler) !void {
        self.unresolved_unknowns = try std.math.add(usize, self.unresolved_unknowns, 1);
        if (self.stage == .ready) {
            self.stage = .reconciling;
            self.rest = @splat(.{});
            self.stability_round = 1;
            self.bootstrap_watermark = self.last_raw_sequence;
        }
    }

    pub fn resolveUnknown(self: *Reconciler, result: UnknownResolution) !void {
        if (self.unresolved_unknowns == 0) return error.NoUnresolvedUnknown;
        if (result == .still_unknown) return;
        self.unresolved_unknowns -= 1;
    }

    pub fn readiness(self: *const Reconciler) Readiness {
        return .{
            .private_stream_ready = self.stage == .buffering or
                self.stage == .reconciling or self.stage == .ready,
            .reconciliation_ready = self.stage == .ready,
            .session = self.session,
            .bootstrap_watermark = self.bootstrap_watermark,
        };
    }

    pub fn rawWatermark(self: *const Reconciler) u64 {
        return self.last_raw_sequence;
    }

    pub fn tryComplete(self: *Reconciler) !?ReconciliationReady {
        if (self.stage == .failed) return error.ReconciliationFailed;
        if (self.stage != .reconciling) return null;
        for (self.rest) |endpoint| if (!endpoint.complete) return null;
        if (self.stability_round == 1) {
            for (self.rest, 0..) |endpoint, index| {
                self.stable_rest_digests[index] = endpoint.digest;
                self.rest[index] = .{};
            }
            self.stability_round = 2;
            return null;
        }
        for (self.rest, 0..) |endpoint, index| {
            if (!std.mem.eql(u8, &endpoint.digest, &self.stable_rest_digests[index])) {
                self.stage = .failed;
                return error.UnstableRestBootstrap;
            }
        }
        if (self.unresolved_unknowns != 0 or self.unattributed_fact_seen) return null;
        self.stage = .ready;
        return .{
            .session = self.session,
            .bootstrap_watermark = self.bootstrap_watermark orelse
                return error.MissingBootstrapWatermark,
            .last_raw_sequence = self.last_raw_sequence,
        };
    }

    pub fn drainReconciled(self: *Reconciler) ?PrivateEvent {
        if (self.stage != .ready) return null;
        if (self.drain_bootstrap_index < self.bootstrap_event_count) {
            defer self.drain_bootstrap_index += 1;
            return self.bootstrap_events[self.drain_bootstrap_index];
        }
        if (self.drain_ws_index < self.ws_event_count) {
            defer self.drain_ws_index += 1;
            return self.ws_events[self.drain_ws_index];
        }
        return null;
    }

    pub fn ingest(
        self: *Reconciler,
        gpa: std.mem.Allocator,
        raw_sink: RawSink,
        source_session: u64,
        times: Times,
        source: IngressSource,
        page: ?Page,
        raw: []const u8,
    ) (RawSinkError || error{ OutOfMemory, FrameTooLarge })!IngressBatch {
        var batch = try self.commitRaw(raw_sink, source_session, times, raw);
        return self.ingestCommitted(gpa, source_session, times, source, page, raw, &batch);
    }

    pub fn ingestWsMessage(
        self: *Reconciler,
        gpa: std.mem.Allocator,
        raw_sink: RawSink,
        source_session: u64,
        times: Times,
        raw: []const u8,
    ) (RawSinkError || error{ OutOfMemory, FrameTooLarge })!IngressBatch {
        var batch = try self.commitRaw(raw_sink, source_session, times, raw);
        if (source_session != self.session or self.stage == .offline) {
            batch.rejection = .stale_session;
            return batch;
        }
        if (self.stage == .failed) {
            batch.rejection = .conflicting_fact;
            return batch;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch
            return self.reject(&batch, .malformed_json);
        defer parsed.deinit();
        const object = asObject(parsed.value) catch return self.reject(&batch, .malformed_envelope);
        if (optionalStringField(object, "event") catch return self.reject(&batch, .invalid_field)) |event| {
            if (optionalStringField(object, "code") catch return self.reject(&batch, .invalid_field)) |code|
                if (!std.mem.eql(u8, code, "0")) return self.reject(&batch, .venue_error);
            if (std.mem.eql(u8, event, "login")) return batch;
            if (std.mem.eql(u8, event, "error")) return self.reject(&batch, .venue_error);
            if (std.mem.eql(u8, event, "subscribe")) {
                const channel = wsChannel(object) catch return self.reject(&batch, .malformed_envelope);
                self.subscriptionAcknowledged(channel) catch return self.reject(&batch, .invalid_field);
                return batch;
            }
            return batch;
        }
        const channel = wsChannel(object) catch return self.reject(&batch, .source_mismatch);
        const source: IngressSource = switch (channel) {
            .orders => .ws_orders,
            .account => .ws_account,
            .positions => .ws_positions,
        };
        return self.ingestParsed(parsed.value, times, source, &batch);
    }

    fn commitRaw(
        self: *Reconciler,
        raw_sink: RawSink,
        source_session: u64,
        times: Times,
        raw: []const u8,
    ) (RawSinkError || error{FrameTooLarge})!IngressBatch {
        if (raw.len > market.max_raw_frame_bytes or raw.len > std.math.maxInt(u32))
            return error.FrameTooLarge;
        var raw_hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(raw, &raw_hash, .{});
        const evidence = try raw_sink.append(.{
            .source_session = source_session,
            .receive_time_utc_ns = times.receive_time_utc_ns,
            .monotonic_time_ns = times.monotonic_time_ns,
            .wall_time_utc_ns = times.wall_time_utc_ns,
            .byte_len = @intCast(raw.len),
            .sha256 = raw_hash,
        }, raw);
        self.last_raw_sequence = @max(self.last_raw_sequence, evidence.stream_sequence);
        return .{ .raw_evidence = evidence };
    }

    fn ingestCommitted(
        self: *Reconciler,
        gpa: std.mem.Allocator,
        source_session: u64,
        times: Times,
        source: IngressSource,
        page: ?Page,
        raw: []const u8,
        batch: *IngressBatch,
    ) error{OutOfMemory}!IngressBatch {
        if (source_session != self.session or self.stage == .offline) {
            batch.rejection = .stale_session;
            return batch.*;
        }
        if (self.stage == .failed) {
            batch.rejection = .conflicting_fact;
            return batch.*;
        }
        if (source.isWebSocket()) {
            if (page != null) {
                batch.rejection = .invalid_field;
                return batch.*;
            }
        } else if (self.stage != .reconciling or page == null) {
            batch.rejection = .invalid_field;
            return batch.*;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch {
            return self.reject(batch, .malformed_json);
        };
        defer parsed.deinit();
        self.decode(parsed.value, source, times, batch.raw_evidence, batch) catch |err| {
            return self.reject(batch, mapDecodeError(err));
        };
        if (!source.isWebSocket()) {
            self.recordPage(source, page.?, batch.raw_evidence.sha256, batch) catch |err| {
                return self.reject(batch, mapDecodeError(err));
            };
        }

        if (self.stage == .ready) return batch.*;
        batch.buffered = true;
        self.bufferBatch(source, batch) catch {
            return self.reject(batch, .bootstrap_buffer_full);
        };
        batch.event_count = 0;
        return batch.*;
    }

    fn ingestParsed(self: *Reconciler, root: std.json.Value, times: Times, source: IngressSource, batch: *IngressBatch) IngressBatch {
        self.decode(root, source, times, batch.raw_evidence, batch) catch |err|
            return self.reject(batch, mapDecodeError(err));
        if (self.stage == .ready) return batch.*;
        batch.buffered = true;
        self.bufferBatch(source, batch) catch return self.reject(batch, .bootstrap_buffer_full);
        batch.event_count = 0;
        return batch.*;
    }

    fn reject(self: *Reconciler, batch: *IngressBatch, reason: RejectReason) IngressBatch {
        self.stage = .failed;
        batch.rejection = reason;
        batch.event_count = 0;
        return batch.*;
    }

    fn bufferBatch(self: *Reconciler, source: IngressSource, batch: *const IngressBatch) !void {
        if (source.isWebSocket()) {
            if (self.ws_events.len - self.ws_event_count < batch.event_count)
                return error.BufferFull;
            for (batch.eventSlice()) |event| {
                self.ws_events[self.ws_event_count] = event;
                self.ws_event_count += 1;
            }
        } else {
            if (self.bootstrap_events.len - self.bootstrap_event_count < batch.event_count)
                return error.BufferFull;
            for (batch.eventSlice()) |event| {
                self.bootstrap_events[self.bootstrap_event_count] = event;
                self.bootstrap_event_count += 1;
            }
        }
    }

    fn decode(
        self: *Reconciler,
        root: std.json.Value,
        source: IngressSource,
        times: Times,
        evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        const object = try asObject(root);
        const data = if (source.isWebSocket()) blk: {
            const arg = try asObject(try field(object, "arg"));
            const expected = switch (source) {
                .ws_orders => "orders",
                .ws_account => "account",
                .ws_positions => "positions",
                else => unreachable,
            };
            if (!std.mem.eql(u8, try stringField(arg, "channel"), expected))
                return error.SourceMismatch;
            if (source == .ws_account or source == .ws_positions)
                try self.recordWsSnapshotPage(source, object);
            break :blk try asArray(try field(object, "data"));
        } else blk: {
            if (!std.mem.eql(u8, try stringField(object, "code"), "0"))
                return error.VenueError;
            break :blk try asArray(try field(object, "data"));
        };
        if (data.items.len > max_page_rows) return error.PageTooLarge;

        switch (source) {
            .ws_orders,
            .rest_orders_pending,
            .rest_orders_history_spot,
            .rest_orders_history_swap,
            => for (data.items) |item| try self.decodeOrder(
                try asObject(item),
                source,
                times,
                evidence,
                batch,
            ),
            .rest_fills_history_spot,
            .rest_fills_history_swap,
            => for (data.items) |item| try self.decodeFill(
                try asObject(item),
                source,
                times,
                evidence,
                batch,
            ),
            .ws_account, .rest_balance => try self.decodeBalance(
                data,
                source == .rest_balance,
                times,
                evidence,
                batch,
            ),
            .ws_positions, .rest_positions => try self.decodePositions(
                data,
                source == .rest_positions,
                times,
                evidence,
                batch,
            ),
            .rest_account_config => try self.decodeConfig(data, times, evidence, batch),
            .rest_leverage => try self.decodeLeverage(data, times, evidence, batch),
        }
    }

    fn decodeOrder(
        self: *Reconciler,
        row: std.json.ObjectMap,
        source: IngressSource,
        times: Times,
        evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        const instrument = try parseInstrument(try stringField(row, "instId"));
        try validateSourceInstrument(source, instrument);
        const venue_order_id = try idField(VenueOrderId, row, "ordId");
        const client_order_id = try ClientOrderId.init(try stringField(row, "clOrdId"));
        const update_time = try millisField(row, "uTime");
        const report: ExecutionReport = .{
            .venue_order_id = venue_order_id,
            .client_order_id = client_order_id,
            .instrument = instrument,
            .side = try parseSide(try stringField(row, "side")),
            .order_type = try parseOrderType(try stringField(row, "ordType")),
            .status = try parseExecutionStatus(try stringField(row, "state")),
            .quantity = try decimalField(row, "sz"),
            .limit_price = try optionalDecimalField(row, "px"),
            .cumulative_filled_quantity = try decimalField(row, "accFillSz"),
            .average_fill_price = try optionalDecimalField(row, "avgPx"),
            .request_id = try FixedText(32).init(
                (try optionalStringField(row, "reqId")) orelse "",
            ),
            .last_trade_id = if (try optionalStringField(row, "tradeId")) |trade_id|
                try parseId(VenueTradeId, trade_id)
            else
                null,
            .venue_update_time_utc_ns = update_time,
            .owned_by_ringwin = isOwnedClientId(client_order_id.slice()),
        };
        if (!report.owned_by_ringwin and
            (report.status == .live or report.status == .partially_filled))
            self.unattributed_fact_seen = true;
        batch.oldest_cursor = minCursor(batch.oldest_cursor, @intFromEnum(venue_order_id));
        const identity = reportIdentity(&report);
        if (!try self.remember(identity, hashReport(&report))) {
            try batch.append(makeEvent(times, update_time, evidence, identity, .{
                .execution_report = report,
            }));
        }

        // REST order history exposes only the latest fill-shaped fields and
        // cumulative fees. Authoritative historical fills come from fills-history.
        if (source != .ws_orders) return;

        const trade_text = try optionalStringField(row, "tradeId") orelse return;
        if (trade_text.len == 0) return;
        const fill_size = try optionalDecimalField(row, "fillSz") orelse return error.InvalidField;
        const fill_price = try optionalDecimalField(row, "fillPx") orelse return error.InvalidField;
        if (fill_size.coefficient == 0) return;
        const fill_time = try optionalMillisField(row, "fillTime") orelse update_time;
        const fee = (try optionalDecimalField(row, "fillFee")) orelse
            (try optionalDecimalField(row, "fee")) orelse Decimal{ .coefficient = 0, .scale = 0 };
        const fee_ccy = (try optionalStringField(row, "fillFeeCcy")) orelse
            (try optionalStringField(row, "feeCcy")) orelse "";
        const fill: Fill = .{
            .venue_trade_id = try parseId(VenueTradeId, trade_text),
            .venue_bill_id = null,
            .venue_order_id = venue_order_id,
            .client_order_id = client_order_id,
            .instrument = instrument,
            .side = report.side,
            .quantity = fill_size,
            .price = fill_price,
            .fee = fee,
            .fee_asset = try AssetCode.init(fee_ccy),
            .rebate = try optionalDecimalField(row, "rebate"),
            .rebate_asset = if (try optionalStringField(row, "rebateCcy")) |asset|
                try AssetCode.init(asset)
            else
                null,
            .realized_pnl = try optionalDecimalField(row, "fillPnl"),
            .liquidity = try optionalLiquidity(row),
            .venue_fill_time_utc_ns = fill_time,
            .owned_by_ringwin = report.owned_by_ringwin,
        };
        try self.appendFill(fill, times, evidence, batch);
    }

    fn decodeFill(
        self: *Reconciler,
        row: std.json.ObjectMap,
        source: IngressSource,
        times: Times,
        evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        const client_order_id = try ClientOrderId.init(
            (try optionalStringField(row, "clOrdId")) orelse "",
        );
        const instrument = try parseInstrument(try stringField(row, "instId"));
        try validateSourceInstrument(source, instrument);
        const fill: Fill = .{
            .venue_trade_id = try idField(VenueTradeId, row, "tradeId"),
            .venue_bill_id = try idField(VenueBillId, row, "billId"),
            .venue_order_id = try idField(VenueOrderId, row, "ordId"),
            .client_order_id = client_order_id,
            .instrument = instrument,
            .side = try parseSide(try stringField(row, "side")),
            .quantity = try decimalField(row, "fillSz"),
            .price = try decimalField(row, "fillPx"),
            .fee = (try optionalDecimalField(row, "fee")) orelse
                (try optionalDecimalField(row, "fillFee")) orelse return error.InvalidField,
            .fee_asset = try AssetCode.init(
                (try optionalStringField(row, "feeCcy")) orelse
                    (try optionalStringField(row, "fillFeeCcy")) orelse return error.InvalidField,
            ),
            .rebate = try optionalDecimalField(row, "rebate"),
            .rebate_asset = if (try optionalStringField(row, "rebateCcy")) |asset|
                try AssetCode.init(asset)
            else
                null,
            .realized_pnl = (try optionalDecimalField(row, "fillPnl")) orelse
                (try optionalDecimalField(row, "pnl")),
            .liquidity = try optionalLiquidity(row),
            .venue_fill_time_utc_ns = (try optionalMillisField(row, "fillTime")) orelse
                try millisField(row, "ts"),
            .owned_by_ringwin = isOwnedClientId(client_order_id.slice()),
        };
        batch.oldest_cursor = minCursor(
            batch.oldest_cursor,
            @intFromEnum(fill.venue_bill_id.?),
        );
        try self.appendFill(fill, times, evidence, batch);
    }

    fn appendFill(
        self: *Reconciler,
        fill: Fill,
        times: Times,
        evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        const identity = fillIdentity(fill.instrument, fill.venue_trade_id);
        if (fill.venue_bill_id) |bill_id| {
            _ = try self.remember(fillBillIdentity(fill.instrument, fill.venue_trade_id), hashBillId(bill_id));
            _ = try self.remember(billIdentity(bill_id), identity);
        }
        if (!try self.remember(identity, hashFill(&fill))) {
            try batch.append(makeEvent(
                times,
                fill.venue_fill_time_utc_ns,
                evidence,
                identity,
                .{ .fill = fill },
            ));
        }
    }

    fn decodeBalance(
        self: *Reconciler,
        data: std.json.Array,
        is_rest: bool,
        times: Times,
        evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        if (data.items.len != 1) return error.InvalidField;
        const row = try asObject(data.items[0]);
        const update_time = try millisField(row, "uTime");
        var snapshot: ExchangeBalanceSnapshot = .{
            .scope = if (is_rest) .full_rest else .ws_reported,
            .venue_update_time_utc_ns = update_time,
        };
        const details = try asArray(try field(row, "details"));
        if (details.items.len > snapshot.balances.len) return error.PageTooLarge;
        for (details.items) |item| {
            const detail = try asObject(item);
            snapshot.balances[snapshot.balance_count] = .{
                .asset = try AssetCode.init(try stringField(detail, "ccy")),
                .cash_balance = try optionalDecimalField(detail, "cashBal"),
                .available_balance = try optionalDecimalField(detail, "availBal"),
                .equity = try optionalDecimalField(detail, "eq"),
                .frozen_balance = try optionalDecimalField(detail, "frozenBal"),
                .liability = try optionalDecimalField(detail, "liab"),
                .isolated_liability = try optionalDecimalField(detail, "isoLiab"),
                .cross_liability = try optionalDecimalField(detail, "crossLiab"),
            };
            snapshot.balance_count += 1;
        }
        const balance_identity = scopedTimeIdentity("balance", snapshot.scope, update_time);
        const balance_duplicate = try self.remember(balance_identity, hashBalance(&snapshot));
        if (!balance_duplicate or is_rest)
            try batch.append(makeEvent(times, update_time, evidence, balance_identity, .{
                .exchange_balance_snapshot = snapshot,
            }));

        const margin: ExchangeMarginSnapshot = .{
            .scope = snapshot.scope,
            .venue_update_time_utc_ns = update_time,
            .total_equity_usd = try optionalDecimalField(row, "totalEq"),
            .adjusted_equity_usd = try optionalDecimalField(row, "adjEq"),
            .initial_margin_usd = try optionalDecimalField(row, "imr"),
            .maintenance_margin_usd = try optionalDecimalField(row, "mmr"),
            .margin_ratio = try optionalDecimalField(row, "mgnRatio"),
            .isolated_equity_usd = try optionalDecimalField(row, "isoEq"),
        };
        const margin_identity = scopedTimeIdentity("margin", snapshot.scope, update_time);
        const margin_duplicate = try self.remember(margin_identity, hashMargin(&margin));
        if (!margin_duplicate or is_rest)
            try batch.append(makeEvent(times, update_time, evidence, margin_identity, .{
                .exchange_margin_snapshot = margin,
            }));
    }

    fn decodePositions(
        self: *Reconciler,
        data: std.json.Array,
        is_rest: bool,
        times: Times,
        evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        var snapshot: ExchangePositionSnapshot = .{
            .scope = if (is_rest) .full_rest else .ws_reported,
            .includes_zero_positions = !is_rest,
        };
        if (data.items.len > snapshot.positions.len) return error.PageTooLarge;
        var latest_time: u64 = 0;
        for (data.items) |item| {
            const row = try asObject(item);
            const update_time = try millisField(row, "uTime");
            latest_time = @max(latest_time, update_time);
            snapshot.positions[snapshot.position_count] = .{
                .venue_position_id = try idField(VenuePositionId, row, "posId"),
                .instrument = try parseInstrument(try stringField(row, "instId")),
                .margin_mode = try parseMarginMode(try stringField(row, "mgnMode")),
                .position_side = try parsePositionSide(try stringField(row, "posSide")),
                .quantity = try decimalField(row, "pos"),
                .average_price = try optionalDecimalField(row, "avgPx"),
                .mark_price = try optionalDecimalField(row, "markPx"),
                .liquidation_price = try optionalDecimalField(row, "liqPx"),
                .margin = try optionalDecimalField(row, "margin"),
                .leverage = try optionalDecimalField(row, "lever"),
                .unrealized_pnl = try optionalDecimalField(row, "upl"),
                .venue_update_time_utc_ns = update_time,
            };
            snapshot.position_count += 1;
        }
        const identity = scopedTimeIdentity("positions", snapshot.scope, latest_time);
        if (!try self.remember(identity, hashPositions(&snapshot)))
            try batch.append(makeEvent(times, if (latest_time == 0) null else latest_time, evidence, identity, .{
                .exchange_position_snapshot = snapshot,
            }));
    }

    fn decodeConfig(
        self: *Reconciler,
        data: std.json.Array,
        times: Times,
        evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        if (data.items.len != 1) return error.InvalidField;
        const row = try asObject(data.items[0]);
        const permissions = try stringField(row, "perm");
        const config: VenueAccountConfigurationSnapshot = .{ .account = .{
            .account_level = if (std.mem.eql(u8, try stringField(row, "acctLv"), "2"))
                .futures
            else
                return error.UnsupportedValue,
            .position_mode = if (std.mem.eql(u8, try stringField(row, "posMode"), "net_mode"))
                .net
            else
                return error.UnsupportedValue,
            .contract_isolated_mode = try parseContractIsolatedMode(
                try stringField(row, "ctIsoMode"),
            ),
            .auto_loan = try boolField(row, "autoLoan"),
            .spot_borrow_enabled = try boolField(row, "enableSpotBorrow"),
            .can_read = containsCsv(permissions, "read") or containsCsv(permissions, "read_only"),
            .can_trade = containsCsv(permissions, "trade"),
            .can_withdraw = containsCsv(permissions, "withdraw"),
        } };
        const content = hashConfig(&config);
        const identity = contentIdentity("account-config", content);
        if (!try self.remember(identity, content))
            try batch.append(makeEvent(times, null, evidence, identity, .{
                .venue_account_configuration_snapshot = config,
            }));
    }

    fn decodeLeverage(
        self: *Reconciler,
        data: std.json.Array,
        times: Times,
        evidence: RawEvidenceRef,
        batch: *IngressBatch,
    ) !void {
        if (data.items.len != 1) return error.InvalidField;
        const row = try asObject(data.items[0]);
        const config: VenueAccountConfigurationSnapshot = .{ .isolated_leverage = .{
            .instrument = try parseInstrument(try stringField(row, "instId")),
            .margin_mode = try parseMarginMode(try stringField(row, "mgnMode")),
            .position_side = try parsePositionSide(try stringField(row, "posSide")),
            .leverage = try decimalField(row, "lever"),
        } };
        const content = hashConfig(&config);
        const identity = contentIdentity("isolated-leverage", content);
        if (!try self.remember(identity, content))
            try batch.append(makeEvent(times, null, evidence, identity, .{
                .venue_account_configuration_snapshot = config,
            }));
    }

    fn remember(
        self: *Reconciler,
        identity: [Sha256.digest_length]u8,
        content: [Sha256.digest_length]u8,
    ) !bool {
        for (self.seen[0..self.seen_count]) |seen| {
            if (!std.mem.eql(u8, &seen.identity, &identity)) continue;
            if (!std.mem.eql(u8, &seen.content, &content)) return error.ConflictingFact;
            return true;
        }
        if (self.seen_count == self.seen.len) return error.BufferFull;
        self.seen[self.seen_count] = .{ .identity = identity, .content = content };
        self.seen_count += 1;
        return false;
    }

    fn recordPage(
        self: *Reconciler,
        source: IngressSource,
        page: Page,
        raw_hash: [Sha256.digest_length]u8,
        batch: *const IngressBatch,
    ) !void {
        const endpoint = &self.rest[@intFromEnum(restEndpoint(source))];
        if (endpoint.complete) return error.InvalidPageCursor;
        endpoint.started = true;
        const oldest = batch.oldest_cursor;
        if (page.requested_after) |after| {
            if (endpoint.last_oldest_cursor == null or endpoint.last_oldest_cursor.? != after)
                return error.InvalidPageCursor;
            if (oldest) |cursor| if (cursor >= after) return error.InvalidPageCursor;
        } else if (endpoint.last_oldest_cursor != null) {
            return error.InvalidPageCursor;
        }
        if (!page.final and oldest == null) return error.InvalidPageCursor;
        endpoint.last_oldest_cursor = oldest orelse endpoint.last_oldest_cursor;
        endpoint.complete = page.final;
        var hasher = Sha256.init(.{});
        hasher.update(&endpoint.digest);
        hasher.update(&restPageDigest(source, raw_hash, batch));
        endpoint.digest = hasher.finalResult();
        endpoint.page_count += 1;
    }

    fn recordWsSnapshotPage(
        self: *Reconciler,
        source: IngressSource,
        object: std.json.ObjectMap,
    ) !void {
        const event_type = try stringField(object, "eventType");
        if (!std.mem.eql(u8, event_type, "snapshot")) return;
        const index: usize = if (source == .ws_account) 0 else 1;
        const page = try unsignedField(object, "curPage");
        const last_page = try boolField(object, "lastPage");
        const snapshot = &self.ws_snapshots[index];
        if (snapshot.complete) {
            if (page != 1) return error.InvalidPageCursor;
            snapshot.next_page = 1;
            snapshot.complete = false;
        }
        if (page != snapshot.next_page) return error.InvalidPageCursor;
        snapshot.next_page += 1;
        snapshot.complete = last_page;
        self.updatePrivateStreamStage();
    }

    fn updatePrivateStreamStage(self: *Reconciler) void {
        if (self.stage != .subscribing and self.stage != .buffering) return;
        if (allTrue(&self.subscriptions) and
            self.ws_snapshots[0].complete and self.ws_snapshots[1].complete)
            self.stage = .buffering;
    }
};

fn restPageDigest(
    source: IngressSource,
    raw_hash: [Sha256.digest_length]u8,
    batch: *const IngressBatch,
) [Sha256.digest_length]u8 {
    if (source != .rest_balance) return raw_hash;
    var hasher = Sha256.init(.{});
    for (batch.eventSlice()) |event| switch (event.payload) {
        .exchange_balance_snapshot => |snapshot| hasher.update(&hashBalance(&snapshot)),
        else => {},
    };
    return hasher.finalResult();
}

fn allTrue(values: []const bool) bool {
    for (values) |value| if (!value) return false;
    return true;
}

fn mapDecodeError(err: anyerror) RejectReason {
    return switch (err) {
        error.MalformedEnvelope => .malformed_envelope,
        error.VenueError => .venue_error,
        error.SourceMismatch => .source_mismatch,
        error.UnsupportedInstrument => .unsupported_instrument,
        error.UnsupportedValue => .unsupported_value,
        error.PageTooLarge => .page_too_large,
        error.InvalidPageCursor => .invalid_page_cursor,
        error.ConflictingFact => .conflicting_fact,
        error.BufferFull => .bootstrap_buffer_full,
        else => .invalid_field,
    };
}

fn restEndpoint(source: IngressSource) RequiredRest {
    return switch (source) {
        .rest_account_config => .account_config,
        .rest_leverage => .leverage,
        .rest_balance => .balance,
        .rest_positions => .positions,
        .rest_orders_pending => .orders_pending,
        .rest_orders_history_spot => .orders_history_spot,
        .rest_orders_history_swap => .orders_history_swap,
        .rest_fills_history_spot => .fills_history_spot,
        .rest_fills_history_swap => .fills_history_swap,
        else => unreachable,
    };
}

fn minCursor(current: ?u64, candidate: u64) ?u64 {
    return if (current) |known| @min(known, candidate) else candidate;
}

fn asObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.MalformedEnvelope,
    };
}

fn asArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.MalformedEnvelope,
    };
}

fn field(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MalformedEnvelope;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (try field(object, name)) {
        .string => |text| text,
        else => error.InvalidField,
    };
}

fn optionalStringField(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        .null => null,
        else => error.InvalidField,
    };
}

fn wsChannel(object: std.json.ObjectMap) !PrivateChannel {
    const arg = try asObject(try field(object, "arg"));
    const channel = try stringField(arg, "channel");
    if (std.mem.eql(u8, channel, "orders")) return .orders;
    if (std.mem.eql(u8, channel, "account")) return .account;
    if (std.mem.eql(u8, channel, "positions")) return .positions;
    return error.InvalidField;
}

fn boolField(object: std.json.ObjectMap, name: []const u8) !bool {
    return switch (try field(object, name)) {
        .bool => |value| value,
        else => error.InvalidField,
    };
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) !u32 {
    return switch (try field(object, name)) {
        .integer => |value| if (value >= 0)
            std.math.cast(u32, value) orelse error.InvalidField
        else
            error.InvalidField,
        .string => |text| std.fmt.parseInt(u32, text, 10) catch error.InvalidField,
        else => error.InvalidField,
    };
}

fn decimalField(object: std.json.ObjectMap, name: []const u8) !Decimal {
    return Decimal.parse(try stringField(object, name));
}

fn optionalDecimalField(object: std.json.ObjectMap, name: []const u8) !?Decimal {
    const text = try optionalStringField(object, name) orelse return null;
    return @as(?Decimal, try Decimal.parse(text));
}

fn decimalOrZero(object: std.json.ObjectMap, name: []const u8) !Decimal {
    return (try optionalDecimalField(object, name)) orelse .{ .coefficient = 0, .scale = 0 };
}

fn millisField(object: std.json.ObjectMap, name: []const u8) !u64 {
    const millis = std.fmt.parseInt(u64, try stringField(object, name), 10) catch
        return error.InvalidField;
    return std.math.mul(u64, millis, std.time.ns_per_ms) catch error.InvalidField;
}

fn optionalMillisField(object: std.json.ObjectMap, name: []const u8) !?u64 {
    const text = try optionalStringField(object, name) orelse return null;
    const millis = std.fmt.parseInt(u64, text, 10) catch return error.InvalidField;
    return @as(?u64, std.math.mul(u64, millis, std.time.ns_per_ms) catch
        return error.InvalidField);
}

fn parseId(comptime Id: type, text: []const u8) !Id {
    const Tag = @typeInfo(Id).@"enum".tag_type;
    const value = std.fmt.parseInt(Tag, text, 10) catch return error.InvalidField;
    if (value == 0) return error.InvalidField;
    return @enumFromInt(value);
}

fn idField(comptime Id: type, object: std.json.ObjectMap, name: []const u8) !Id {
    return parseId(Id, try stringField(object, name));
}

fn parseInstrument(text: []const u8) !Instrument {
    if (std.mem.eql(u8, text, "BTC-USDT")) return .btc_usdt_spot;
    if (std.mem.eql(u8, text, "BTC-USDT-SWAP")) return .btc_usdt_swap;
    return error.UnsupportedInstrument;
}

fn validateSourceInstrument(source: IngressSource, instrument: Instrument) !void {
    const expected: ?Instrument = switch (source) {
        .rest_orders_history_spot, .rest_fills_history_spot => .btc_usdt_spot,
        .rest_orders_history_swap, .rest_fills_history_swap => .btc_usdt_swap,
        else => null,
    };
    if (expected) |value| if (instrument != value) return error.SourceMismatch;
}

fn parseSide(text: []const u8) !Side {
    if (std.mem.eql(u8, text, "buy")) return .buy;
    if (std.mem.eql(u8, text, "sell")) return .sell;
    return error.UnsupportedValue;
}

fn parsePositionSide(text: []const u8) !PositionSide {
    if (std.mem.eql(u8, text, "net")) return .net;
    return error.UnsupportedValue;
}

fn parseMarginMode(text: []const u8) !MarginMode {
    if (std.mem.eql(u8, text, "isolated")) return .isolated;
    return error.UnsupportedValue;
}

fn parseOrderType(text: []const u8) !OrderType {
    inline for (@typeInfo(OrderType).@"enum".fields) |enum_field| {
        if (std.mem.eql(u8, text, enum_field.name)) return @enumFromInt(enum_field.value);
    }
    return error.UnsupportedValue;
}

fn parseExecutionStatus(text: []const u8) !ExecutionStatus {
    if (std.mem.eql(u8, text, "live")) return .live;
    if (std.mem.eql(u8, text, "partially_filled")) return .partially_filled;
    if (std.mem.eql(u8, text, "filled")) return .filled;
    if (std.mem.eql(u8, text, "canceled") or std.mem.eql(u8, text, "mmp_canceled"))
        return .canceled;
    return error.UnsupportedValue;
}

fn optionalLiquidity(object: std.json.ObjectMap) !?Liquidity {
    const text = (try optionalStringField(object, "execType")) orelse return null;
    if (std.mem.eql(u8, text, "M")) return .maker;
    if (std.mem.eql(u8, text, "T")) return .taker;
    return error.UnsupportedValue;
}

fn parseContractIsolatedMode(text: []const u8) !ContractIsolatedMode {
    if (std.mem.eql(u8, text, "automatic")) return .automatic;
    if (std.mem.eql(u8, text, "autonomy")) return .autonomy;
    return error.UnsupportedValue;
}

fn containsCsv(csv: []const u8, expected: []const u8) bool {
    var values = std.mem.splitScalar(u8, csv, ',');
    while (values.next()) |value| {
        if (std.mem.eql(u8, std.mem.trim(u8, value, " \t"), expected)) return true;
    }
    return false;
}

fn isOwnedClientId(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "RWN");
}

fn makeEvent(
    times: Times,
    source_time_utc_ns: ?u64,
    evidence: RawEvidenceRef,
    identity: [Sha256.digest_length]u8,
    payload: EventPayload,
) PrivateEvent {
    return .{
        .envelope = .{
            .source_time_utc_ns = source_time_utc_ns,
            .receive_time_utc_ns = times.receive_time_utc_ns,
            .monotonic_time_ns = times.monotonic_time_ns,
            .wall_time_utc_ns = times.wall_time_utc_ns,
            .raw_evidence = evidence,
            .source_fact_identity = identity,
        },
        .payload = payload,
    };
}

fn reportIdentity(report: *const ExecutionReport) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("execution-report");
    hashU64(&hasher, @intFromEnum(report.venue_order_id));
    hasher.update(&.{@intFromEnum(report.status)});
    if (report.status != .filled and report.status != .canceled) {
        hashDecimal(&hasher, report.cumulative_filled_quantity);
        hashOptionalDecimal(&hasher, report.limit_price);
        hasher.update(report.request_id.slice());
        if (report.last_trade_id) |trade_id| hashI64(&hasher, @intFromEnum(trade_id));
    }
    return hasher.finalResult();
}

fn fillIdentity(instrument: Instrument, trade_id: VenueTradeId) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("fill");
    hasher.update(&.{@intFromEnum(instrument)});
    hashI64(&hasher, @intFromEnum(trade_id));
    return hasher.finalResult();
}

fn fillBillIdentity(instrument: Instrument, trade_id: VenueTradeId) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("fill-bill");
    hasher.update(&.{@intFromEnum(instrument)});
    hashI64(&hasher, @intFromEnum(trade_id));
    return hasher.finalResult();
}

fn billIdentity(bill_id: VenueBillId) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("bill");
    hashU64(&hasher, @intFromEnum(bill_id));
    return hasher.finalResult();
}

fn hashBillId(bill_id: VenueBillId) [32]u8 {
    var hasher = Sha256.init(.{});
    hashU64(&hasher, @intFromEnum(bill_id));
    return hasher.finalResult();
}

fn scopedTimeIdentity(prefix: []const u8, scope: SnapshotScope, update_time: u64) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(prefix);
    hasher.update(&.{@intFromEnum(scope)});
    hashU64(&hasher, update_time);
    return hasher.finalResult();
}

fn contentIdentity(prefix: []const u8, content: [32]u8) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(prefix);
    hasher.update(&content);
    return hasher.finalResult();
}

fn hashReport(report: *const ExecutionReport) [32]u8 {
    var hasher = Sha256.init(.{});
    hashU64(&hasher, @intFromEnum(report.venue_order_id));
    hasher.update(report.client_order_id.slice());
    hasher.update(&.{
        @intFromEnum(report.instrument),
        @intFromEnum(report.side),
        @intFromEnum(report.order_type),
        @intFromEnum(report.status),
    });
    hashDecimal(&hasher, report.quantity);
    hashOptionalDecimal(&hasher, report.limit_price);
    hashDecimal(&hasher, report.cumulative_filled_quantity);
    hashOptionalDecimal(&hasher, report.average_fill_price);
    hasher.update(report.request_id.slice());
    if (report.last_trade_id) |trade_id| hashI64(&hasher, @intFromEnum(trade_id));
    hasher.update(&.{@intFromBool(report.owned_by_ringwin)});
    return hasher.finalResult();
}

fn hashFill(fill: *const Fill) [32]u8 {
    var hasher = Sha256.init(.{});
    hashI64(&hasher, @intFromEnum(fill.venue_trade_id));
    hashU64(&hasher, @intFromEnum(fill.venue_order_id));
    hasher.update(fill.client_order_id.slice());
    hasher.update(&.{ @intFromEnum(fill.instrument), @intFromEnum(fill.side) });
    hashDecimal(&hasher, fill.quantity);
    hashDecimal(&hasher, fill.price);
    hashDecimal(&hasher, fill.fee);
    hasher.update(fill.fee_asset.slice());
    hashOptionalDecimal(&hasher, fill.rebate);
    if (fill.rebate_asset) |asset| hasher.update(asset.slice()) else hasher.update(&.{});
    hashOptionalDecimal(&hasher, fill.realized_pnl);
    if (fill.liquidity) |liquidity| hasher.update(&.{ 1, @intFromEnum(liquidity) }) else hasher.update(&.{0});
    hashU64(&hasher, fill.venue_fill_time_utc_ns);
    hasher.update(&.{@intFromBool(fill.owned_by_ringwin)});
    return hasher.finalResult();
}

fn hashConfig(config: *const VenueAccountConfigurationSnapshot) [32]u8 {
    var hasher = Sha256.init(.{});
    switch (config.*) {
        .account => |account| hasher.update(&.{
            0,
            @intFromEnum(account.account_level),
            @intFromEnum(account.position_mode),
            @intFromEnum(account.contract_isolated_mode),
            @intFromBool(account.auto_loan),
            @intFromBool(account.spot_borrow_enabled),
            @intFromBool(account.can_read),
            @intFromBool(account.can_trade),
            @intFromBool(account.can_withdraw),
        }),
        .isolated_leverage => |leverage| {
            hasher.update(&.{
                1,
                @intFromEnum(leverage.instrument),
                @intFromEnum(leverage.margin_mode),
                @intFromEnum(leverage.position_side),
            });
            hashDecimal(&hasher, leverage.leverage);
        },
    }
    return hasher.finalResult();
}

fn hashBalance(snapshot: *const ExchangeBalanceSnapshot) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(&.{ @intFromEnum(snapshot.scope), snapshot.balance_count });
    for (snapshot.balances[0..snapshot.balance_count]) |balance| {
        hasher.update(balance.asset.slice());
        hashOptionalDecimal(&hasher, balance.cash_balance);
        hashOptionalDecimal(&hasher, balance.available_balance);
        hashOptionalDecimal(&hasher, balance.equity);
        hashOptionalDecimal(&hasher, balance.frozen_balance);
        hashOptionalDecimal(&hasher, balance.liability);
        hashOptionalDecimal(&hasher, balance.isolated_liability);
        hashOptionalDecimal(&hasher, balance.cross_liability);
    }
    return hasher.finalResult();
}

fn hashMargin(snapshot: *const ExchangeMarginSnapshot) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(&.{@intFromEnum(snapshot.scope)});
    hashOptionalDecimal(&hasher, snapshot.total_equity_usd);
    hashOptionalDecimal(&hasher, snapshot.adjusted_equity_usd);
    hashOptionalDecimal(&hasher, snapshot.initial_margin_usd);
    hashOptionalDecimal(&hasher, snapshot.maintenance_margin_usd);
    hashOptionalDecimal(&hasher, snapshot.margin_ratio);
    hashOptionalDecimal(&hasher, snapshot.isolated_equity_usd);
    return hasher.finalResult();
}

fn hashPositions(snapshot: *const ExchangePositionSnapshot) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(&.{
        @intFromEnum(snapshot.scope),
        snapshot.position_count,
        @intFromBool(snapshot.includes_zero_positions),
    });
    for (snapshot.positions[0..snapshot.position_count]) |position| {
        hashU64(&hasher, @intFromEnum(position.venue_position_id));
        hasher.update(&.{
            @intFromEnum(position.instrument),
            @intFromEnum(position.margin_mode),
            @intFromEnum(position.position_side),
        });
        hashDecimal(&hasher, position.quantity);
        hashOptionalDecimal(&hasher, position.average_price);
        hashOptionalDecimal(&hasher, position.mark_price);
        hashOptionalDecimal(&hasher, position.liquidation_price);
        hashOptionalDecimal(&hasher, position.margin);
        hashOptionalDecimal(&hasher, position.leverage);
        hashOptionalDecimal(&hasher, position.unrealized_pnl);
    }
    return hasher.finalResult();
}

fn hashDecimal(hasher: *Sha256, value: Decimal) void {
    var coefficient: [16]u8 = undefined;
    std.mem.writeInt(i128, &coefficient, value.coefficient, .little);
    hasher.update(&coefficient);
    hasher.update(&.{value.scale});
}

fn hashOptionalDecimal(hasher: *Sha256, value: ?Decimal) void {
    if (value) |decimal| {
        hasher.update(&.{1});
        hashDecimal(hasher, decimal);
    } else {
        hasher.update(&.{0});
    }
}

fn hashU64(hasher: *Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn hashI64(hasher: *Sha256, value: i64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, value, .little);
    hasher.update(&bytes);
}

const TestRawSink = struct {
    append_count: u64 = 0,
    fail: bool = false,

    fn sink(self: *TestRawSink) RawSink {
        return .{ .ptr = self, .append_fn = append };
    }

    fn append(
        ptr: *anyopaque,
        record: market.RawIngressRecord,
        bytes: []const u8,
    ) RawSinkError!u64 {
        const self: *TestRawSink = @ptrCast(@alignCast(ptr));
        if (self.fail) return error.Backpressure;
        var actual: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &actual, .{});
        if (!std.mem.eql(u8, &actual, &record.sha256)) return error.Unavailable;
        self.append_count += 1;
        return self.append_count;
    }
};

const test_times: Times = .{
    .receive_time_utc_ns = 1_800_000_000_000_000_001,
    .monotonic_time_ns = 10_000_001,
    .wall_time_utc_ns = 1_800_000_000_000_000_002,
};

fn ingestTest(
    reconciler: *Reconciler,
    sink: *TestRawSink,
    source: IngressSource,
    page: ?Page,
    raw: []const u8,
) !IngressBatch {
    return reconciler.ingest(
        std.testing.allocator,
        sink.sink(),
        7,
        test_times,
        source,
        page,
        raw,
    );
}

fn establishPrivateStream(reconciler: *Reconciler, sink: *TestRawSink) !void {
    reconciler.beginSession(7);
    try reconciler.subscriptionAcknowledged(.orders);
    try reconciler.subscriptionAcknowledged(.account);
    try reconciler.subscriptionAcknowledged(.positions);
    _ = try ingestTest(reconciler, sink, .ws_account, null,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000000","totalEq":"","adjEq":"","imr":"","mmr":"","mgnRatio":"","isoEq":"","details":[]}]}
    );
    _ = try ingestTest(reconciler, sink, .ws_positions, null,
        \\{"arg":{"channel":"positions"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[]}
    );
    try std.testing.expect(reconciler.readiness().private_stream_ready);
}

test "unified private WS ingress raw-commits login ACKs and snapshots before routing" {
    var reconciler: Reconciler = .{};
    var sink: TestRawSink = .{};
    reconciler.beginSession(7);
    const frames = [_][]const u8{
        \\{"event":"login","code":"0"}
        ,
        \\{"event":"subscribe","arg":{"channel":"orders","instType":"ANY"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"account"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"positions","instType":"ANY"}}
        ,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000000","totalEq":"","adjEq":"","imr":"","mmr":"","mgnRatio":"","isoEq":"","details":[]}]}
        ,
        \\{"arg":{"channel":"positions"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[]}
        ,
    };
    for (frames) |frame| {
        const batch = try reconciler.ingestWsMessage(
            std.testing.allocator,
            sink.sink(),
            7,
            test_times,
            frame,
        );
        try std.testing.expect(batch.rejection == null);
    }
    try std.testing.expectEqual(@as(u64, frames.len), sink.append_count);
    try std.testing.expect(reconciler.readiness().private_stream_ready);
}

test "unified private WS ingress rejects a nonzero venue event after raw commit" {
    var reconciler: Reconciler = .{};
    var sink: TestRawSink = .{};
    reconciler.beginSession(8);
    const batch = try reconciler.ingestWsMessage(
        std.testing.allocator,
        sink.sink(),
        8,
        test_times,
        \\{"event":"login","code":"60009","msg":"Login failed"}
        ,
    );
    try std.testing.expectEqual(@as(u64, 1), sink.append_count);
    try std.testing.expectEqual(RejectReason.venue_error, batch.rejection.?);
}

const rest_sources = [_]IngressSource{
    .rest_account_config,
    .rest_leverage,
    .rest_balance,
    .rest_positions,
    .rest_orders_pending,
    .rest_orders_history_spot,
    .rest_orders_history_swap,
    .rest_fills_history_spot,
    .rest_fills_history_swap,
};

const rest_fixtures = [_][]const u8{
    \\{"code":"0","data":[{"acctLv":"2","posMode":"net_mode","ctIsoMode":"automatic","autoLoan":false,"enableSpotBorrow":false,"perm":"read_only,trade"}]}
    ,
    \\{"code":"0","data":[{"instId":"BTC-USDT-SWAP","mgnMode":"isolated","posSide":"net","lever":"3"}]}
    ,
    \\{"code":"0","data":[{"uTime":"1800000000000","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"25","details":[{"ccy":"USDT","cashBal":"25","availBal":"25","eq":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    ,
    \\{"code":"0","data":[]}
    ,
    \\{"code":"0","data":[]}
    ,
    \\{"code":"0","data":[]}
    ,
    \\{"code":"0","data":[]}
    ,
    \\{"code":"0","data":[]}
    ,
    \\{"code":"0","data":[]}
};

fn ingestRestRound(reconciler: *Reconciler, sink: *TestRawSink) !void {
    for (rest_sources, rest_fixtures) |source, raw| {
        const batch = try ingestTest(reconciler, sink, source, .{ .final = true }, raw);
        try std.testing.expectEqual(@as(?RejectReason, null), batch.rejection);
        try std.testing.expect(batch.buffered);
    }
}

test "raw evidence precedes private decode failure" {
    var reconciler: Reconciler = .{};
    var sink: TestRawSink = .{};
    reconciler.beginSession(7);
    const batch = try ingestTest(&reconciler, &sink, .ws_orders, null, "not json");
    try std.testing.expectEqual(@as(u64, 1), sink.append_count);
    try std.testing.expectEqual(RejectReason.malformed_json, batch.rejection.?);
    try std.testing.expect(!reconciler.readiness().reconciliation_ready);
}

test "private snapshots and two stable REST reads open then disconnect revokes barrier" {
    var reconciler: Reconciler = .{};
    var sink: TestRawSink = .{};
    try establishPrivateStream(&reconciler, &sink);
    try reconciler.beginReconciliation(sink.append_count);

    try ingestRestRound(&reconciler, &sink);
    try std.testing.expect((try reconciler.tryComplete()) == null);
    try ingestRestRound(&reconciler, &sink);
    const ready = (try reconciler.tryComplete()).?;
    try std.testing.expectEqual(@as(u64, 7), ready.session);
    try std.testing.expect(reconciler.readiness().reconciliation_ready);

    var saw_config = false;
    while (reconciler.drainReconciled()) |event| switch (event.payload) {
        .venue_account_configuration_snapshot => saw_config = true,
        else => {},
    };
    try std.testing.expect(saw_config);
    reconciler.disconnect();
    try std.testing.expect(!reconciler.readiness().private_stream_ready);
    try std.testing.expect(!reconciler.readiness().reconciliation_ready);
}

test "Unknown requires stable rebootstrap and an explicit reconciliation result" {
    var reconciler: Reconciler = .{};
    var sink: TestRawSink = .{};
    try establishPrivateStream(&reconciler, &sink);
    try reconciler.beginReconciliation(sink.append_count);
    try ingestRestRound(&reconciler, &sink);
    try std.testing.expect((try reconciler.tryComplete()) == null);
    try ingestRestRound(&reconciler, &sink);
    _ = (try reconciler.tryComplete()).?;

    try reconciler.registerUnknown();
    try std.testing.expect(!reconciler.readiness().reconciliation_ready);
    try reconciler.resolveUnknown(.still_unknown);
    try ingestRestRound(&reconciler, &sink);
    try std.testing.expect((try reconciler.tryComplete()) == null);
    try ingestRestRound(&reconciler, &sink);
    try std.testing.expect((try reconciler.tryComplete()) == null);

    try reconciler.resolveUnknown(.confirmed_absent);
    try std.testing.expect((try reconciler.tryComplete()) != null);
    try std.testing.expectError(error.NoUnresolvedUnknown, reconciler.resolveUnknown(.confirmed_absent));
}

test "REST pagination requires the exact descending endpoint cursor" {
    var reconciler: Reconciler = .{};
    var sink: TestRawSink = .{};
    try establishPrivateStream(&reconciler, &sink);
    try reconciler.beginReconciliation(sink.append_count);

    const first = try ingestTest(&reconciler, &sink, .rest_orders_history_spot, .{ .final = false },
        \\{"code":"0","data":[{"instId":"BTC-USDT","ordId":"200","clOrdId":"RWNTEST0200","side":"buy","ordType":"limit","state":"filled","sz":"0.0002","px":"50000","accFillSz":"0.0002","avgPx":"50000","uTime":"1800000000200","tradeId":"","reqId":""}]}
    );
    try std.testing.expectEqual(@as(?RejectReason, null), first.rejection);
    const final = try ingestTest(&reconciler, &sink, .rest_orders_history_spot, .{ .requested_after = 200, .final = true },
        \\{"code":"0","data":[{"instId":"BTC-USDT","ordId":"100","clOrdId":"RWNTEST0100","side":"buy","ordType":"limit","state":"canceled","sz":"0.0002","px":"50000","accFillSz":"0","avgPx":"","uTime":"1800000000100","tradeId":"","reqId":""}]}
    );
    try std.testing.expectEqual(@as(?RejectReason, null), final.rejection);

    var invalid: Reconciler = .{};
    var invalid_sink: TestRawSink = .{};
    try establishPrivateStream(&invalid, &invalid_sink);
    try invalid.beginReconciliation(invalid_sink.append_count);
    _ = try ingestTest(&invalid, &invalid_sink, .rest_orders_history_spot, .{ .final = false },
        \\{"code":"0","data":[{"instId":"BTC-USDT","ordId":"200","clOrdId":"RWNTEST0200","side":"buy","ordType":"limit","state":"filled","sz":"0.0002","px":"50000","accFillSz":"0.0002","avgPx":"50000","uTime":"1800000000200","tradeId":"","reqId":""}]}
    );
    const skipped = try ingestTest(&invalid, &invalid_sink, .rest_orders_history_spot, .{ .requested_after = 199, .final = true },
        \\{"code":"0","data":[]}
    );
    try std.testing.expectEqual(RejectReason.invalid_page_cursor, skipped.rejection.?);
}

test "REST balance stability ignores observation uTime but not economic values" {
    var batch: IngressBatch = .{
        .raw_evidence = .{ .stream_sequence = 1, .sha256 = @splat(1) },
    };
    var snapshot: ExchangeBalanceSnapshot = .{
        .scope = .full_rest,
        .venue_update_time_utc_ns = 1,
    };
    snapshot.balances[0] = .{
        .asset = try AssetCode.init("USDT"),
        .cash_balance = try Decimal.parse("25"),
        .available_balance = try Decimal.parse("25"),
        .equity = try Decimal.parse("25"),
        .frozen_balance = try Decimal.parse("0"),
        .liability = try Decimal.parse("0"),
        .isolated_liability = try Decimal.parse("0"),
        .cross_liability = try Decimal.parse("0"),
    };
    snapshot.balance_count = 1;
    try batch.append(makeEvent(
        .{ .receive_time_utc_ns = 2, .monotonic_time_ns = 3, .wall_time_utc_ns = 4 },
        1,
        batch.raw_evidence,
        @splat(2),
        .{ .exchange_balance_snapshot = snapshot },
    ));
    const first = restPageDigest(.rest_balance, @splat(3), &batch);
    batch.events[0].payload.exchange_balance_snapshot.venue_update_time_utc_ns = 2;
    const later_observation = restPageDigest(.rest_balance, @splat(4), &batch);
    try std.testing.expectEqualSlices(u8, &first, &later_observation);
    batch.events[0].payload.exchange_balance_snapshot.balances[0].cash_balance = try Decimal.parse("24");
    const changed = restPageDigest(.rest_balance, @splat(5), &batch);
    try std.testing.expect(!std.mem.eql(u8, &first, &changed));
}

test "orders duplicate with a changed update time is semantically idempotent" {
    var reconciler: Reconciler = .{};
    var sink: TestRawSink = .{};
    try establishPrivateStream(&reconciler, &sink);
    const initial_event_count = reconciler.ws_event_count;
    const first = try ingestTest(&reconciler, &sink, .ws_orders, null,
        \\{"arg":{"channel":"orders"},"data":[{"instId":"BTC-USDT-SWAP","ordId":"1001","clOrdId":"RWN-0001","side":"buy","ordType":"limit","state":"live","sz":"1","px":"50000","accFillSz":"0","avgPx":"","uTime":"1800000000100","tradeId":"","reqId":""}]}
    );
    const duplicate = try ingestTest(&reconciler, &sink, .ws_orders, null,
        \\{"arg":{"channel":"orders"},"data":[{"instId":"BTC-USDT-SWAP","ordId":"1001","clOrdId":"RWN-0001","side":"buy","ordType":"limit","state":"live","sz":"1","px":"50000","accFillSz":"0","avgPx":"","uTime":"1800000000200","tradeId":"","reqId":""}]}
    );
    try std.testing.expect(first.buffered);
    try std.testing.expect(duplicate.buffered);
    try std.testing.expectEqual(initial_event_count + 1, reconciler.ws_event_count);
    try std.testing.expectEqual(@as(?RejectReason, null), duplicate.rejection);
}

test "account snapshot after initial private-stream page starts a new observation" {
    var reconciler: Reconciler = .{};
    var sink: TestRawSink = .{};
    try establishPrivateStream(&reconciler, &sink);

    const batch = try ingestTest(&reconciler, &sink, .ws_account, null,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000001","totalEq":"","adjEq":"","imr":"","mmr":"","mgnRatio":"","isoEq":"","details":[]}]}
    );
    try std.testing.expectEqual(@as(?RejectReason, null), batch.rejection);
}

test "REST bill identity enriches an otherwise identical WS fill" {
    var reconciler: Reconciler = .{};
    const fill: Fill = .{
        .venue_trade_id = @enumFromInt(2001),
        .venue_bill_id = null,
        .venue_order_id = @enumFromInt(1001),
        .client_order_id = try ClientOrderId.init("RWNTEST1"),
        .instrument = .btc_usdt_spot,
        .side = .buy,
        .quantity = try Decimal.parse("0.00005"),
        .price = try Decimal.parse("63500"),
        .fee = try Decimal.parse("-0.00000005"),
        .fee_asset = try AssetCode.init("BTC"),
        .realized_pnl = try Decimal.parse("0"),
        .liquidity = .taker,
        .venue_fill_time_utc_ns = 1_800_000_000_100_000_000,
        .owned_by_ringwin = true,
    };
    var ws_batch: IngressBatch = .{ .raw_evidence = .{ .stream_sequence = 1, .sha256 = @splat(1) } };
    try reconciler.appendFill(fill, test_times, ws_batch.raw_evidence, &ws_batch);

    var rest_fill = fill;
    rest_fill.venue_bill_id = @enumFromInt(3001);
    var rest_batch: IngressBatch = .{ .raw_evidence = .{ .stream_sequence = 2, .sha256 = @splat(2) } };
    try reconciler.appendFill(rest_fill, test_times, rest_batch.raw_evidence, &rest_batch);
    try std.testing.expectEqual(@as(u8, 0), rest_batch.event_count);
}
