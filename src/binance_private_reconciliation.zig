//! Binance private ingress is committed before it is decoded. Only canonical
//! records leave this module; venue field names stay adapter-private.
const std = @import("std");
const canonical = @import("canonical_event.zig");
const raw = @import("binance_order_raw.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const btc_usdt_spot: canonical.InstrumentIdentity = 0x424e_00000001;
pub const btc_usdt_linear: canonical.InstrumentIdentity = 0x424e_00000002;
pub const btc: canonical.AssetIdentity = 0x425443;
pub const usdt: canonical.AssetIdentity = 0x55534454;
pub const InstrumentRules = struct { identity: canonical.InstrumentIdentity, rules_version: u64, tick_size: canonical.Decimal, lot_size: canonical.Decimal };
pub const Rules = struct { spot: InstrumentRules, linear: InstrumentRules };
pub const Binding = struct { venue: canonical.VenueIdentity, account: canonical.ExchangeAccountIdentity, session: canonical.AdapterSessionIdentity };
pub const Source = enum(u8) { ws, rest_spot_account, rest_linear_account, rest_orders, rest_fills };
pub const Page = struct { final: bool };
pub const Stage = enum(u8) { offline, buffering, reconciling, ready, failed };
pub const Readiness = struct { stage: Stage, session: canonical.AdapterSessionIdentity, raw_watermark: u64, bootstrap: ?canonical.BootstrapSnapshotIdentity };
const max_private_events = 96;
const max_seen_facts = 128;
const max_order_links = 32;
const max_pending_observations = 24;
const SeenFact = struct { key: [32]u8, content: [32]u8 };
const OrderLink = struct { order: canonical.OrderIdentity, client_order_id: canonical.ClientOrderId, status: ?canonical.ExecutionReportStatus = null };
const PendingObservation = union(enum) {
    balance: struct { value: canonical.AccountBalance, times: raw.Times, evidence: raw.RawEvidenceRef },
    position: struct { value: canonical.AccountPosition, times: raw.Times, evidence: raw.RawEvidenceRef },
    margin: struct { value: canonical.AccountMargin, times: raw.Times, evidence: raw.RawEvidenceRef },
};

pub const Reconciler = struct {
    raw_sink: raw.RawSink,
    rules: Rules,
    binding: ?Binding = null,
    stage: Stage = .offline,
    raw_watermark: u64 = 0,
    next_event_sequence: u64 = 1,
    account_sequence: u64 = 0,
    bootstrap: ?canonical.BootstrapSnapshotIdentity = null,
    balances_complete: bool = false,
    positions_complete: bool = false,
    margins_complete: bool = false,
    orders_complete: bool = false,
    fills_complete: bool = false,
    balances: [canonical.max_account_facts]canonical.AccountBalance = undefined,
    balance_count: u8 = 0,
    positions: [canonical.max_account_facts]canonical.AccountPosition = undefined,
    position_count: u8 = 0,
    margins: [canonical.max_account_facts]canonical.AccountMargin = undefined,
    margin_count: u8 = 0,
    seen: [max_seen_facts]SeenFact = undefined,
    seen_count: usize = 0,
    links: [max_order_links]OrderLink = undefined,
    link_count: usize = 0,
    buffered: [max_private_events]canonical.EventRecord = undefined,
    buffered_count: usize = 0,
    pending_observations: [max_pending_observations]PendingObservation = undefined,
    pending_observation_count: usize = 0,
    ready: [max_private_events]canonical.EventRecord = undefined,
    ready_count: usize = 0,
    ready_index: usize = 0,

    pub fn init(raw_sink: raw.RawSink, rules: Rules) Reconciler {
        return .{ .raw_sink = raw_sink, .rules = rules };
    }
    pub fn beginSession(self: *Reconciler, binding: Binding) void {
        const sink = self.raw_sink;
        const rules = self.rules;
        self.* = .{ .raw_sink = sink, .rules = rules, .binding = binding, .stage = .buffering };
    }
    /// A source gap discards all incomplete state. Reuse requires a fresh
    /// session and a complete bootstrap; stale buffered facts never leak out.
    pub fn sourceGap(self: *Reconciler) void {
        self.stage = .offline;
        self.bootstrap = null;
        self.buffered_count = 0;
        self.pending_observation_count = 0;
        self.ready_count = 0;
        self.ready_index = 0;
    }
    pub fn beginReconciliation(self: *Reconciler, watermark: u64) !void {
        if (self.stage != .buffering) return error.PrivateStreamNotReady;
        if (watermark < self.raw_watermark) return error.RegressingRawWatermark;
        self.raw_watermark = watermark;
        self.stage = .reconciling;
    }
    pub fn readiness(self: *const Reconciler) Readiness {
        return .{ .stage = self.stage, .session = (self.binding orelse Binding{ .venue = 0, .account = 0, .session = 0 }).session, .raw_watermark = self.raw_watermark, .bootstrap = self.bootstrap };
    }
    pub fn registerOrder(self: *Reconciler, order: canonical.OrderIdentity, client_order_id: canonical.ClientOrderId) !void {
        for (self.links[0..self.link_count]) |link| if (std.mem.eql(u8, link.client_order_id.slice(), client_order_id.slice())) {
            if (link.order != order) return error.ConflictingOrderLink;
            return;
        };
        if (self.link_count == self.links.len) return error.OrderLinkCapacity;
        self.links[self.link_count] = .{ .order = order, .client_order_id = client_order_id };
        self.link_count += 1;
    }
    /// This is the sole live/replay ingress point: a RawSink failure prevents
    /// parsing and state mutation, and committed bytes are deterministically decoded.
    pub fn ingest(self: *Reconciler, allocator: std.mem.Allocator, source: Source, page: ?Page, times: raw.Times, bytes: []const u8) !raw.RawEvidenceRef {
        const binding = self.binding orelse return error.StaleSession;
        if (bytes.len == 0 or bytes.len > 1024 * 1024 or bytes.len > std.math.maxInt(u32)) return error.InvalidFrame;
        var digest: [32]u8 = undefined;
        Sha256.hash(bytes, &digest, .{});
        const evidence = try self.raw_sink.append(.{ .source_session = @truncate(binding.session), .receive_time_utc_ns = times.receive_time_utc_ns, .monotonic_time_ns = times.monotonic_time_ns, .wall_time_utc_ns = times.wall_time_utc_ns, .byte_len = @intCast(bytes.len), .sha256 = digest }, bytes);
        self.raw_watermark = @max(self.raw_watermark, evidence.stream_sequence);
        if (self.stage == .offline or self.stage == .failed) return error.StaleSession;
        if (source == .ws and page != null) return error.InvalidPage;
        if (source != .ws and (page == null or self.stage != .reconciling)) return error.InvalidPage;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .parse_numbers = false }) catch return error.InvalidFrame;
        defer parsed.deinit();
        self.decode(source, page, times, evidence, parsed.value) catch |err| {
            self.stage = .failed;
            return err;
        };
        return evidence;
    }
    pub fn drain(self: *Reconciler) ?canonical.AdapterOutputBatch {
        if (self.ready_index == self.ready_count) return null;
        var batch: canonical.AdapterOutputBatch = .{};
        while (self.ready_index < self.ready_count and batch.len < canonical.max_events_per_adapter_batch) {
            batch.append(self.ready[self.ready_index]) catch break;
            self.ready_index += 1;
        }
        if (self.ready_index == self.ready_count) {
            self.ready_count = 0;
            self.ready_index = 0;
        }
        return batch;
    }
    pub fn hasPending(self: *const Reconciler) bool {
        return self.ready_index < self.ready_count;
    }
    pub fn resolveOrder(self: *const Reconciler, order: canonical.OrderIdentity) canonical.ReconciliationStatus {
        for (self.links[0..self.link_count]) |link| if (link.order == order) {
            return if (link.status) |status| switch (status) {
                .accepted, .partially_filled, .amended => .found_live,
                .filled, .canceled, .rejected => .found_terminal,
            } else if (self.stage == .ready) .confirmed_absent else .unresolved;
        };
        return .unresolved;
    }
    fn decode(self: *Reconciler, source: Source, page: ?Page, times: raw.Times, evidence: raw.RawEvidenceRef, value: std.json.Value) !void {
        switch (source) {
            .ws => try self.decodeWs(times, evidence, value),
            .rest_spot_account => try self.decodeSpotAccount(times, evidence, value),
            .rest_linear_account => try self.decodeLinearAccount(times, evidence, value),
            .rest_orders => try self.decodeRows(.report, false, times, evidence, value),
            .rest_fills => try self.decodeRows(.fill, false, times, evidence, value),
        }
        if (page) |current| if (current.final) switch (source) {
            .rest_spot_account, .rest_linear_account => {
                self.balances_complete = true;
                self.positions_complete = true;
                self.margins_complete = true;
            },
            .rest_orders => self.orders_complete = true,
            .rest_fills => self.fills_complete = true,
            .ws => unreachable,
        };
        try self.releaseBootstrap(evidence, times);
    }
    fn decodeWs(self: *Reconciler, times: raw.Times, evidence: raw.RawEvidenceRef, value: std.json.Value) !void {
        const object = try asObject(value);
        const event = try stringField(object, "e");
        if (std.mem.eql(u8, event, "executionReport")) {
            try self.decodeOrder(.report, false, times, evidence, object);
            if ((try optionalStringField(object, "t")) != null and !std.mem.eql(u8, try stringField(object, "t"), "-1")) try self.decodeOrder(.fill, false, times, evidence, object);
        } else if (std.mem.eql(u8, event, "ORDER_TRADE_UPDATE")) {
            const order = try asObject(try objectField(object, "o"));
            try self.decodeOrder(.report, true, times, evidence, order);
            if ((try optionalStringField(order, "t")) != null and !std.mem.eql(u8, try stringField(order, "t"), "0")) try self.decodeOrder(.fill, true, times, evidence, order);
        } else if (std.mem.eql(u8, event, "outboundAccountPosition")) try self.decodeSpotBalances(times, evidence, try asArray(try objectField(object, "B")), true) else if (std.mem.eql(u8, event, "ACCOUNT_UPDATE")) {
            const account = try asObject(try objectField(object, "a"));
            try self.decodeLinearAssets(times, evidence, try asArray(try objectField(account, "B")), true);
            try self.decodeLinearPositions(times, evidence, try asArray(try objectField(account, "P")), true);
        } else return error.UnsupportedPrivateEvent;
    }
    const Kind = enum { report, fill };
    fn decodeRows(self: *Reconciler, kind: Kind, linear: bool, times: raw.Times, evidence: raw.RawEvidenceRef, value: std.json.Value) !void {
        const rows = switch (value) {
            .array => |array| array.items,
            .object => |object| blk: {
                if (object.get("rows")) |rows| break :blk (try asArray(rows)).items;
                break :blk (try asArray(try objectField(object, if (kind == .report) "orders" else "fills"))).items;
            },
            else => return error.InvalidFrame,
        };
        for (rows) |row| try self.decodeOrder(kind, linear, times, evidence, try asObject(row));
    }
    fn decodeOrder(self: *Reconciler, kind: Kind, linear: bool, times: raw.Times, evidence: raw.RawEvidenceRef, object: std.json.ObjectMap) !void {
        const binding = self.binding orelse return error.StaleSession;
        const order_id = try anyStringField(object, &.{ "i", "orderId" });
        const client = try anyStringField(object, &.{ "c", "clientOrderId" });
        const link = self.findOrder(client) orelse return;
        const rules = try self.instrumentRules(try anyStringField(object, &.{ "s", "symbol" }), linear);
        const update_ms = try optionalU64Field(object, &.{ "T", "updateTime", "time" });
        const source_time = if (update_ms) |millis| try std.math.mul(u64, millis, 1_000_000) else null;
        if (kind == .report) {
            const status = try anyStringField(object, &.{ "X", "status" });
            const mapped_status = try statusFor(status);
            self.observeOrder(link.order, mapped_status);
            const cumulative_text = try anyStringField(object, &.{ "z", "executedQty" });
            const cumulative = try quantityFor(rules, cumulative_text);
            const original = try quantityFor(rules, try anyStringField(object, &.{ "q", "origQty" }));
            if (cumulative.lots > original.lots) return error.InvalidReportQuantity;
            const key = reportFactKey(order_id, status, cumulative_text, update_ms);
            if (try self.seenBefore(key, evidence.sha256)) return;
            const event: canonical.CanonicalEvent = .{ .execution_report = .{ .identity = digestIdentity(key), .order = link.order, .client_order_id = link.client_order_id, .venue_order = try canonical.VenueOrderRef.init(binding.venue, order_id), .instrument = rules.identity, .exchange_account = binding.account, .revision = 1, .side = try sideFor(try anyStringField(object, &.{ "S", "side" })), .order_type = try orderTypeFor(try anyStringField(object, &.{ "o", "type" })), .time_in_force = try tifFor(try anyStringField(object, &.{ "f", "timeInForce" })), .venue_reduce_only = try optionalBoolField(object, "R"), .position_mode_net = if (linear) true else null, .status = mapped_status, .original_quantity = original, .cumulative_quantity = cumulative, .remaining_quantity = .{ .instrument = rules.identity, .rules_version = rules.rules_version, .lots = original.lots - cumulative.lots }, .limit_price = try optionalPrice(rules, try anyStringField(object, &.{ "p", "price" })), .average_fill_price = if (try optionalStringAny(object, &.{ "ap", "avgPrice", "L" })) |value| try optionalPrice(rules, value) else null, .venue_update_time_utc_ns = source_time } };
            try self.emit(.account, rules.identity, null, digestIdentity(key), source_time, times, evidence, event);
        } else {
            const trade_id = try anyStringField(object, &.{ "t", "id" });
            if (std.mem.eql(u8, trade_id, "-1") or std.mem.eql(u8, trade_id, "0")) return;
            const key = try factKey("fill", &.{trade_id});
            if (try self.seenBefore(key, evidence.sha256)) return;
            const fee = try amountFor(try assetIdentity(try anyStringField(object, &.{ "N", "commissionAsset" })), try canonical.Decimal.parse(try anyStringField(object, &.{ "n", "commission" })));
            const event: canonical.CanonicalEvent = .{ .fill = .{ .identity = digestIdentity(key), .order = link.order, .client_order_id = link.client_order_id, .venue_order = try canonical.VenueOrderRef.init(binding.venue, order_id), .venue_trade = try canonical.VenueTradeRef.init(binding.venue, trade_id), .instrument = rules.identity, .exchange_account = binding.account, .side = try sideFor(try anyStringField(object, &.{ "S", "side" })), .quantity = try quantityFor(rules, try anyStringField(object, &.{ "l", "qty" })), .price = try priceFor(rules, try anyStringField(object, &.{ "L", "price" })), .fee = if (fee.atoms > 0) fee else null, .rebate = if (fee.atoms < 0) .{ .asset = fee.asset, .atoms = -fee.atoms } else null, .realized_pnl = if (try optionalStringAny(object, &.{ "rp", "realizedPnl" })) |value| try amountFor(usdt, try canonical.Decimal.parse(value)) else null, .liquidity = if (try makerFor(object)) .maker else .taker } };
            try self.emit(.account, rules.identity, null, digestIdentity(key), source_time, times, evidence, event);
        }
    }
    fn decodeSpotAccount(self: *Reconciler, times: raw.Times, evidence: raw.RawEvidenceRef, value: std.json.Value) !void {
        const object = try asObject(value);
        try self.decodeSpotBalances(times, evidence, try asArray(try objectField(object, "balances")), false);
    }
    fn decodeSpotBalances(self: *Reconciler, times: raw.Times, evidence: raw.RawEvidenceRef, rows: std.json.Array, observed: bool) !void {
        for (rows.items) |row| {
            const object = try asObject(row);
            const asset = try assetIdentity(try anyStringField(object, &.{ "a", "asset" }));
            const free = try amountFor(asset, try canonical.Decimal.parse(try anyStringField(object, &.{ "f", "free" })));
            const held = try amountFor(asset, try canonical.Decimal.parse(try anyStringField(object, &.{ "l", "locked" })));
            const value = canonical.AccountBalance{ .asset = asset, .total = .{ .asset = asset, .atoms = try std.math.add(i128, free.atoms, held.atoms) }, .available = free, .held = held };
            if (observed) try self.emitBalanceObserved(value, times, evidence) else try self.storeBalance(value);
        }
    }
    fn decodeLinearAccount(self: *Reconciler, times: raw.Times, evidence: raw.RawEvidenceRef, value: std.json.Value) !void {
        const object = try asObject(value);
        try self.decodeLinearAssets(times, evidence, try asArray(try objectField(object, "assets")), false);
        try self.decodeLinearPositions(times, evidence, try asArray(try objectField(object, "positions")), false);
        if (try optionalStringField(object, "totalWalletBalance")) |wallet| try self.storeMargin(.{
            .amount = try amountFor(usdt, try canonical.Decimal.parse(wallet)),
            .adjusted_equity = if (try optionalStringField(object, "totalMarginBalance")) |value_text| try amountFor(usdt, try canonical.Decimal.parse(value_text)) else null,
            .initial_margin = if (try optionalStringField(object, "totalInitialMargin")) |value_text| try amountFor(usdt, try canonical.Decimal.parse(value_text)) else null,
            .maintenance_margin = if (try optionalStringField(object, "totalMaintMargin")) |value_text| try amountFor(usdt, try canonical.Decimal.parse(value_text)) else null,
        });
    }
    fn decodeLinearAssets(self: *Reconciler, times: raw.Times, evidence: raw.RawEvidenceRef, rows: std.json.Array, observed: bool) !void {
        for (rows.items) |row| {
            const object = try asObject(row);
            const asset = try assetIdentity(try anyStringField(object, &.{ "a", "asset" }));
            const total = try amountFor(asset, try canonical.Decimal.parse(try anyStringField(object, &.{ "wb", "walletBalance", "totalWalletBalance" })));
            const available = try amountFor(asset, try canonical.Decimal.parse(try anyStringField(object, &.{ "cw", "availableBalance", "crossWalletBalance" })));
            const value = canonical.AccountBalance{ .asset = asset, .total = total, .available = available, .held = .{ .asset = asset, .atoms = try std.math.sub(i128, total.atoms, available.atoms) }, .cash_balance = total };
            if (observed) try self.emitBalanceObserved(value, times, evidence) else try self.storeBalance(value);
            if (asset == usdt) {
                const margin: canonical.AccountMargin = .{ .amount = total };
                if (observed) try self.emitMarginObserved(margin, times, evidence) else try self.storeMargin(margin);
            }
        }
    }
    fn decodeLinearPositions(self: *Reconciler, times: raw.Times, evidence: raw.RawEvidenceRef, rows: std.json.Array, observed: bool) !void {
        for (rows.items) |row| {
            const object = try asObject(row);
            const rules = try self.instrumentRules(try anyStringField(object, &.{ "s", "symbol" }), true);
            const signed = try quantityFor(rules, try anyStringField(object, &.{ "pa", "positionAmt" }));
            const side: canonical.PositionSide = if (signed.lots < 0) .short else .long;
            const quantity = canonical.InstrumentQuantity{ .instrument = rules.identity, .rules_version = rules.rules_version, .lots = if (signed.lots < 0) -signed.lots else signed.lots };
            const value = canonical.AccountPosition{ .instrument = rules.identity, .side = side, .quantity = quantity, .average_price = if (try optionalStringAny(object, &.{ "ep", "entryPrice" })) |text_value| try optionalPrice(rules, text_value) else null, .mark_price = if (try optionalStringAny(object, &.{ "mp", "markPrice" })) |text_value| try optionalPrice(rules, text_value) else null, .liquidation_price = if (try optionalStringAny(object, &.{ "lp", "liquidationPrice" })) |text_value| try optionalPrice(rules, text_value) else null, .margin = if (try optionalStringAny(object, &.{ "iw", "isolatedWallet" })) |text_value| try amountFor(usdt, try canonical.Decimal.parse(text_value)) else null, .leverage = if (try optionalStringField(object, "leverage")) |text_value| try canonical.Decimal.parse(text_value) else null, .unrealized_pnl = if (try optionalStringAny(object, &.{ "up", "unRealizedProfit" })) |text_value| try amountFor(usdt, try canonical.Decimal.parse(text_value)) else null };
            if (observed) try self.emitPositionObserved(value, times, evidence) else try self.storePosition(value);
        }
    }
    fn releaseBootstrap(self: *Reconciler, evidence: raw.RawEvidenceRef, times: raw.Times) !void {
        if (self.bootstrap != null or self.stage != .reconciling or !self.balances_complete or !self.positions_complete or !self.margins_complete or !self.orders_complete or !self.fills_complete) return;
        const binding = self.binding orelse return error.StaleSession;
        const identity = digestIdentity(evidence.sha256);
        var snapshot = std.mem.zeroes(canonical.AccountBootstrapSnapshot);
        snapshot.identity = identity;
        snapshot.exchange_account = binding.account;
        snapshot.scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true };
        snapshot.source_stream = privateStream(binding.session);
        snapshot.source_sequence = 0;
        snapshot.balance_count = self.balance_count;
        snapshot.position_count = self.position_count;
        snapshot.margin_count = self.margin_count;
        @memcpy(snapshot.balances[0..self.balance_count], self.balances[0..self.balance_count]);
        @memcpy(snapshot.positions[0..self.position_count], self.positions[0..self.position_count]);
        @memcpy(snapshot.margins[0..self.margin_count], self.margins[0..self.margin_count]);
        self.bootstrap = identity;
        self.stage = .ready;
        try self.appendReady(try self.record(.account, null, null, identity, null, times, evidence, .{ .account_bootstrap_snapshot = snapshot }));
        for (self.buffered[0..self.buffered_count]) |event| try self.appendReady(event);
        self.buffered_count = 0;
        for (self.pending_observations[0..self.pending_observation_count]) |pending| switch (pending) {
            .balance => |value| try self.emitBalanceObserved(value.value, value.times, value.evidence),
            .position => |value| try self.emitPositionObserved(value.value, value.times, value.evidence),
            .margin => |value| try self.emitMarginObserved(value.value, value.times, value.evidence),
        };
        self.pending_observation_count = 0;
    }
    fn emitBalanceObserved(self: *Reconciler, balance: canonical.AccountBalance, times: raw.Times, evidence: raw.RawEvidenceRef) !void {
        const bootstrap = self.bootstrap orelse return self.queueObservation(.{ .balance = .{ .value = balance, .times = times, .evidence = evidence } });
        self.account_sequence += 1;
        const identity = digestIdentity(evidence.sha256) +% self.account_sequence;
        const binding = self.binding orelse return error.StaleSession;
        try self.emit(.asset, null, balance.asset, identity, null, times, evidence, .{ .account_observed = .{ .identity = identity, .exchange_account = binding.account, .bootstrap = bootstrap, .source_stream = privateStream(binding.session), .source_sequence = self.account_sequence, .value = .{ .balance = .{ .asset = balance.asset, .value = balance } } } });
    }
    fn emitPositionObserved(self: *Reconciler, position: canonical.AccountPosition, times: raw.Times, evidence: raw.RawEvidenceRef) !void {
        const bootstrap = self.bootstrap orelse return self.queueObservation(.{ .position = .{ .value = position, .times = times, .evidence = evidence } });
        self.account_sequence += 1;
        const identity = digestIdentity(evidence.sha256) +% self.account_sequence;
        const binding = self.binding orelse return error.StaleSession;
        try self.emit(.instrument, position.instrument, null, identity, null, times, evidence, .{ .account_observed = .{ .identity = identity, .exchange_account = binding.account, .bootstrap = bootstrap, .source_stream = privateStream(binding.session), .source_sequence = self.account_sequence, .value = .{ .position = .{ .instrument = position.instrument, .side = position.side, .value = position, .removed = position.quantity.lots == 0 } } } });
    }
    fn emitMarginObserved(self: *Reconciler, margin: canonical.AccountMargin, times: raw.Times, evidence: raw.RawEvidenceRef) !void {
        const bootstrap = self.bootstrap orelse return self.queueObservation(.{ .margin = .{ .value = margin, .times = times, .evidence = evidence } });
        self.account_sequence += 1;
        const identity = digestIdentity(evidence.sha256) +% self.account_sequence;
        const binding = self.binding orelse return error.StaleSession;
        try self.emit(.account, margin.instrument, null, identity, null, times, evidence, .{ .account_observed = .{ .identity = identity, .exchange_account = binding.account, .bootstrap = bootstrap, .source_stream = privateStream(binding.session), .source_sequence = self.account_sequence, .value = .{ .margin = .{ .instrument = margin.instrument, .value = margin } } } });
    }
    fn queueObservation(self: *Reconciler, value: PendingObservation) !void {
        if (self.pending_observation_count == self.pending_observations.len) return error.PrivateBufferFull;
        self.pending_observations[self.pending_observation_count] = value;
        self.pending_observation_count += 1;
    }
    fn emit(self: *Reconciler, scope: canonical.CanonicalEventScope, instrument: ?canonical.InstrumentIdentity, asset: ?canonical.AssetIdentity, identity: u128, source_time: ?u64, times: raw.Times, evidence: raw.RawEvidenceRef, event: canonical.CanonicalEvent) !void {
        const emitted = try self.record(scope, instrument, asset, identity, source_time, times, evidence, event);
        if (self.stage == .ready) try self.appendReady(emitted) else {
            if (self.buffered_count == self.buffered.len) return error.PrivateBufferFull;
            self.buffered[self.buffered_count] = emitted;
            self.buffered_count += 1;
        }
    }
    fn record(self: *Reconciler, scope: canonical.CanonicalEventScope, instrument: ?canonical.InstrumentIdentity, asset: ?canonical.AssetIdentity, identity: u128, source_time: ?u64, times: raw.Times, evidence: raw.RawEvidenceRef, event: canonical.CanonicalEvent) !canonical.EventRecord {
        const binding = self.binding orelse return error.StaleSession;
        const sequence = self.next_event_sequence;
        self.next_event_sequence = try std.math.add(u64, sequence, 1);
        const stream = privateStream(binding.session);
        return .{ .envelope = .{ .event_type = @intFromEnum(canonical.eventType(event)), .schema_version = 1, .identity = .{ .stream = stream, .sequence = sequence }, .source_fact_identity = identity, .scope = scope, .venue = binding.venue, .exchange_account = binding.account, .instrument = instrument, .asset = asset, .source_stream = stream, .source_sequence = evidence.stream_sequence, .adapter_session = binding.session, .times = .{ .source_utc_ns = source_time, .receive_utc_ns = times.receive_time_utc_ns, .monotonic_ns = times.monotonic_time_ns, .audit_utc_ns = times.wall_time_utc_ns }, .raw_evidence = .{ .stream = stream, .sequence = evidence.stream_sequence, .digest = evidence.sha256 } }, .event = event };
    }
    fn appendReady(self: *Reconciler, event: canonical.EventRecord) !void {
        if (self.ready_count == self.ready.len) return error.PrivateOutputFull;
        self.ready[self.ready_count] = event;
        self.ready_count += 1;
    }
    fn storeBalance(self: *Reconciler, value: canonical.AccountBalance) !void {
        try store(canonical.AccountBalance, &self.balances, &self.balance_count, value, struct {
            fn same(a: canonical.AccountBalance, b: canonical.AccountBalance) bool {
                return a.asset == b.asset;
            }
        }.same);
    }
    fn storePosition(self: *Reconciler, value: canonical.AccountPosition) !void {
        try store(canonical.AccountPosition, &self.positions, &self.position_count, value, struct {
            fn same(a: canonical.AccountPosition, b: canonical.AccountPosition) bool {
                return a.instrument == b.instrument and a.side == b.side;
            }
        }.same);
    }
    fn storeMargin(self: *Reconciler, value: canonical.AccountMargin) !void {
        try store(canonical.AccountMargin, &self.margins, &self.margin_count, value, struct {
            fn same(a: canonical.AccountMargin, b: canonical.AccountMargin) bool {
                return a.instrument == b.instrument;
            }
        }.same);
    }
    fn findOrder(self: *const Reconciler, client: []const u8) ?OrderLink {
        for (self.links[0..self.link_count]) |link| if (std.mem.eql(u8, link.client_order_id.slice(), client)) return link;
        return null;
    }
    fn observeOrder(self: *Reconciler, order: canonical.OrderIdentity, status: canonical.ExecutionReportStatus) void {
        for (self.links[0..self.link_count]) |*link| if (link.order == order) {
            link.status = status;
            return;
        };
    }
    fn instrumentRules(self: *const Reconciler, symbol: []const u8, linear: bool) !InstrumentRules {
        if (!std.mem.eql(u8, symbol, "BTCUSDT")) return error.UnsupportedInstrument;
        return if (linear) self.rules.linear else self.rules.spot;
    }
    fn seenBefore(self: *Reconciler, key: [32]u8, content: [32]u8) !bool {
        for (self.seen[0..self.seen_count]) |seen| if (std.mem.eql(u8, &seen.key, &key)) {
            if (!std.mem.eql(u8, &seen.content, &content)) return error.ConflictingFact;
            return true;
        };
        if (self.seen_count == self.seen.len) return error.FactCapacity;
        self.seen[self.seen_count] = .{ .key = key, .content = content };
        self.seen_count += 1;
        return false;
    }
};

fn store(comptime T: type, values: *[canonical.max_account_facts]T, count: *u8, value: T, comptime same: fn (T, T) bool) !void {
    for (values[0..count.*], 0..) |known, index| if (same(known, value)) {
        values[index] = value;
        return;
    };
    if (count.* == values.len) return error.AccountFactCapacity;
    values[count.*] = value;
    count.* += 1;
}
fn asObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidJsonShape,
    };
}
fn asArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.InvalidJsonShape,
    };
}
fn objectField(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.MissingField;
}
fn text(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text_value| text_value,
        .number_string => |text_value| text_value,
        else => error.InvalidField,
    };
}
fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return text(try objectField(object, name));
}
fn optionalStringField(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        else => try text(value),
    };
}
fn optionalBoolField(object: std.json.ObjectMap, name: []const u8) !?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .bool => |truth| truth,
        .string, .number_string => std.mem.eql(u8, try text(value), "true"),
        else => error.InvalidField,
    };
}
fn anyStringField(object: std.json.ObjectMap, names: []const []const u8) ![]const u8 {
    for (names) |name| if (try optionalStringField(object, name)) |value| return value;
    return error.MissingField;
}
fn optionalStringAny(object: std.json.ObjectMap, names: []const []const u8) !?[]const u8 {
    for (names) |name| if (try optionalStringField(object, name)) |value| return value;
    return null;
}
fn optionalU64Field(object: std.json.ObjectMap, names: []const []const u8) !?u64 {
    if (try optionalStringAny(object, names)) |value| return try std.fmt.parseInt(u64, value, 10);
    return null;
}
fn reportFactKey(order_id: []const u8, status: []const u8, cumulative: []const u8, update_ms: ?u64) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update("report");
    const pieces: [3][]const u8 = .{ order_id, status, cumulative };
    for (&pieces) |piece| {
        hasher.update(&[_]u8{0});
        hasher.update(piece);
    }
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, update_ms orelse 0, .little);
    hasher.update(&encoded);
    return hasher.finalResult();
}
fn factKey(prefix: []const u8, pieces: []const []const u8) ![32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(prefix);
    for (pieces) |piece| {
        hasher.update(&[_]u8{0});
        hasher.update(piece);
    }
    return hasher.finalResult();
}
fn digestIdentity(digest: [32]u8) u128 {
    return std.mem.readInt(u128, digest[0..16], .little);
}
/// Private transport facts and command/control records have independent
/// canonical streams even when they share an AdapterSessionIdentity.
fn privateStream(session: canonical.AdapterSessionIdentity) canonical.StreamIdentity {
    return session ^ 0x4249_4e41_4e43_455f_5052_4956_4154_455f;
}
fn assetIdentity(code: []const u8) !canonical.AssetIdentity {
    if (std.mem.eql(u8, code, "USDT")) return usdt;
    if (std.mem.eql(u8, code, "BTC")) return btc;
    return error.UnsupportedAsset;
}
fn assetScale(asset: canonical.AssetIdentity) !u8 {
    return switch (asset) {
        usdt => 6,
        btc => 8,
        else => error.UnsupportedAsset,
    };
}
fn amountFor(asset: canonical.AssetIdentity, value: canonical.Decimal) !canonical.AssetAmount {
    return canonical.AssetAmount.fromDecimal(asset, value, try assetScale(asset));
}
fn quantityFor(rules: InstrumentRules, text_value: []const u8) !canonical.InstrumentQuantity {
    const increment = try rules.lot_size.exactAtoms(rules.lot_size.scale);
    return canonical.InstrumentQuantity.fromDecimal(rules.identity, rules.rules_version, try canonical.Decimal.parse(text_value), rules.lot_size.scale, increment);
}
fn priceFor(rules: InstrumentRules, text_value: []const u8) !canonical.InstrumentPrice {
    const increment = try rules.tick_size.exactAtoms(rules.tick_size.scale);
    return canonical.InstrumentPrice.fromDecimal(rules.identity, rules.rules_version, try canonical.Decimal.parse(text_value), rules.tick_size.scale, increment);
}
fn optionalPrice(rules: InstrumentRules, text_value: []const u8) !?canonical.InstrumentPrice {
    const value = try canonical.Decimal.parse(text_value);
    if (value.coefficient == 0) return null;
    const increment = try rules.tick_size.exactAtoms(rules.tick_size.scale);
    return try canonical.InstrumentPrice.fromDecimal(rules.identity, rules.rules_version, value, rules.tick_size.scale, increment);
}
fn sideFor(value: []const u8) !canonical.OrderSide {
    if (std.mem.eql(u8, value, "BUY")) return .buy;
    if (std.mem.eql(u8, value, "SELL")) return .sell;
    return error.UnsupportedValue;
}
fn orderTypeFor(value: []const u8) !canonical.OrderType {
    if (std.mem.eql(u8, value, "MARKET")) return .market;
    if (std.mem.eql(u8, value, "LIMIT")) return .limit;
    if (std.mem.eql(u8, value, "LIMIT_MAKER")) return .post_only;
    return error.UnsupportedValue;
}
fn tifFor(value: []const u8) !canonical.TimeInForce {
    if (std.mem.eql(u8, value, "GTC")) return .good_til_canceled;
    if (std.mem.eql(u8, value, "IOC")) return .immediate_or_cancel;
    if (std.mem.eql(u8, value, "FOK")) return .fill_or_kill;
    if (std.mem.eql(u8, value, "GTX")) return .post_only;
    return error.UnsupportedValue;
}
fn statusFor(value: []const u8) !canonical.ExecutionReportStatus {
    if (std.mem.eql(u8, value, "NEW")) return .accepted;
    if (std.mem.eql(u8, value, "PARTIALLY_FILLED")) return .partially_filled;
    if (std.mem.eql(u8, value, "FILLED")) return .filled;
    if (std.mem.eql(u8, value, "CANCELED") or std.mem.eql(u8, value, "EXPIRED")) return .canceled;
    if (std.mem.eql(u8, value, "REJECTED")) return .rejected;
    return error.UnsupportedValue;
}
fn makerFor(object: std.json.ObjectMap) !bool {
    if (try optionalBoolField(object, "m")) |value| return value;
    if (try optionalBoolField(object, "isMaker")) |value| return value;
    return error.MissingField;
}

const TestRaw = struct {
    calls: u64 = 0,
    fn interface(self: *TestRaw) raw.RawSink {
        return .{ .ptr = self, .append_fn = append };
    }
    fn append(ptr: *anyopaque, _: raw.RawIngressRecord, _: []const u8) raw.RawSinkError!u64 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return self.calls;
    }
};
fn testRules() Rules {
    const spot = InstrumentRules{ .identity = btc_usdt_spot, .rules_version = 8, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } };
    return .{ .spot = spot, .linear = .{ .identity = btc_usdt_linear, .rules_version = 8, .tick_size = spot.tick_size, .lot_size = spot.lot_size } };
}
fn start(reconciler: *Reconciler) !void {
    reconciler.beginSession(.{ .venue = 21, .account = 2, .session = 6 });
    try reconciler.registerOrder(9, try canonical.ClientOrderId.init("RWN-9"));
    try reconciler.beginReconciliation(0);
}
const fixture_times = raw.Times{ .receive_time_utc_ns = 1, .monotonic_time_ns = 2, .wall_time_utc_ns = 3 };
test "Binance private raw ingress precedes malformed decoding" {
    var sink = TestRaw{};
    var reconciler = Reconciler.init(sink.interface(), testRules());
    try start(&reconciler);
    try std.testing.expectError(error.InvalidFrame, reconciler.ingest(std.testing.allocator, .ws, null, fixture_times, "not-json"));
    try std.testing.expectEqual(@as(u64, 1), sink.calls);
}
test "Binance separates report and fill, maps economics, and dedupes Venue refs" {
    var sink = TestRaw{};
    var reconciler = Reconciler.init(sink.interface(), testRules());
    try start(&reconciler);
    const message = "{\"e\":\"executionReport\",\"E\":\"1\",\"s\":\"BTCUSDT\",\"c\":\"RWN-9\",\"S\":\"BUY\",\"o\":\"LIMIT\",\"f\":\"GTC\",\"q\":\"0.0100\",\"p\":\"50000.0\",\"X\":\"FILLED\",\"i\":\"42\",\"l\":\"0.0100\",\"z\":\"0.0100\",\"L\":\"50000.0\",\"n\":\"-0.000001\",\"N\":\"BTC\",\"T\":\"2\",\"t\":\"77\",\"m\":true}";
    _ = try reconciler.ingest(std.testing.allocator, .ws, null, fixture_times, message);
    _ = try reconciler.ingest(std.testing.allocator, .rest_spot_account, .{ .final = true }, fixture_times, "{\"balances\":[{\"asset\":\"USDT\",\"free\":\"10.000000\",\"locked\":\"0.000000\"}]}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_orders, .{ .final = true }, fixture_times, "[]");
    _ = try reconciler.ingest(std.testing.allocator, .rest_fills, .{ .final = true }, fixture_times, "[]");
    const output = reconciler.drain().?;
    try std.testing.expectEqual(@as(u8, 3), output.len);
    try std.testing.expect(output.events[0].event == .account_bootstrap_snapshot);
    try std.testing.expect(output.events[1].event == .execution_report);
    try std.testing.expect(output.events[2].event == .fill);
    try std.testing.expectEqual(canonical.LiquidityRole.maker, output.events[2].event.fill.liquidity);
    try std.testing.expectEqual(@as(i128, 100), output.events[2].event.fill.rebate.?.atoms);
    _ = try reconciler.ingest(std.testing.allocator, .ws, null, fixture_times, message);
    try std.testing.expect(reconciler.drain() == null);
}
test "Binance bootstrap waits for every paginated source and gap requires a new session" {
    var sink = TestRaw{};
    var reconciler = Reconciler.init(sink.interface(), testRules());
    try start(&reconciler);
    _ = try reconciler.ingest(std.testing.allocator, .ws, null, fixture_times, "{\"e\":\"outboundAccountPosition\",\"B\":[{\"a\":\"USDT\",\"f\":\"7.000000\",\"l\":\"0.000000\"}]}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_spot_account, .{ .final = true }, fixture_times, "{\"balances\":[]}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_orders, .{ .final = false }, fixture_times, "[]");
    try std.testing.expect(reconciler.drain() == null);
    _ = try reconciler.ingest(std.testing.allocator, .rest_orders, .{ .final = true }, fixture_times, "[]");
    _ = try reconciler.ingest(std.testing.allocator, .rest_fills, .{ .final = true }, fixture_times, "[]");
    const output = reconciler.drain().?;
    try std.testing.expectEqual(@as(u8, 2), output.len);
    try std.testing.expect(output.events[1].event == .account_observed);
    reconciler.sourceGap();
    try std.testing.expectError(error.StaleSession, reconciler.ingest(std.testing.allocator, .ws, null, fixture_times, "{}"));
}
test "Binance committed private ingress replays to identical canonical facts" {
    var live_sink = TestRaw{};
    var replay_sink = TestRaw{};
    var live = Reconciler.init(live_sink.interface(), testRules());
    var replay = Reconciler.init(replay_sink.interface(), testRules());
    try start(&live);
    try start(&replay);
    const report = "{\"e\":\"executionReport\",\"s\":\"BTCUSDT\",\"c\":\"RWN-9\",\"S\":\"BUY\",\"o\":\"LIMIT\",\"f\":\"GTC\",\"q\":\"0.0100\",\"p\":\"50000.0\",\"X\":\"NEW\",\"i\":\"42\",\"l\":\"0.0000\",\"z\":\"0.0000\",\"L\":\"0.0\",\"T\":\"2\",\"t\":\"-1\"}";
    for ([_][]const u8{ report, "{\"balances\":[]}", "[]", "[]" }, 0..) |bytes, index| {
        const source: Source = switch (index) {
            0 => .ws,
            1 => .rest_spot_account,
            2 => .rest_orders,
            else => .rest_fills,
        };
        const page: ?Page = if (source == .ws) null else .{ .final = true };
        _ = try live.ingest(std.testing.allocator, source, page, fixture_times, bytes);
        _ = try replay.ingest(std.testing.allocator, source, page, fixture_times, bytes);
    }
    const left = live.drain().?;
    const right = replay.drain().?;
    try std.testing.expectEqual(left.len, right.len);
    for (left.slice(), right.slice()) |live_event, replay_event|
        try std.testing.expect(std.meta.eql(live_event, replay_event));
}
test "Binance USD-M maps fee PnL venue time and complete margin snapshot" {
    var sink = TestRaw{};
    var reconciler = Reconciler.init(sink.interface(), testRules());
    try start(&reconciler);
    _ = try reconciler.ingest(std.testing.allocator, .ws, null, fixture_times, "{\"e\":\"ORDER_TRADE_UPDATE\",\"o\":{\"s\":\"BTCUSDT\",\"c\":\"RWN-9\",\"S\":\"SELL\",\"o\":\"LIMIT\",\"f\":\"GTC\",\"q\":\"0.0100\",\"p\":\"50000.0\",\"ap\":\"50000.0\",\"X\":\"FILLED\",\"i\":\"43\",\"l\":\"0.0100\",\"z\":\"0.0100\",\"L\":\"50000.0\",\"n\":\"0.100000\",\"N\":\"USDT\",\"T\":\"2\",\"t\":\"78\",\"m\":false,\"R\":true,\"rp\":\"1.250000\"}}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_linear_account, .{ .final = true }, fixture_times, "{\"assets\":[{\"asset\":\"USDT\",\"walletBalance\":\"20.000000\",\"availableBalance\":\"15.000000\"}],\"positions\":[],\"totalWalletBalance\":\"20.000000\",\"totalMarginBalance\":\"21.000000\",\"totalInitialMargin\":\"2.000000\",\"totalMaintMargin\":\"1.000000\"}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_orders, .{ .final = true }, fixture_times, "[]");
    _ = try reconciler.ingest(std.testing.allocator, .rest_fills, .{ .final = true }, fixture_times, "[]");
    const output = reconciler.drain().?;
    const snapshot = output.events[0].event.account_bootstrap_snapshot;
    try std.testing.expectEqual(@as(u8, 1), snapshot.margin_count);
    try std.testing.expectEqual(@as(i128, 2_000_000), snapshot.margins[0].initial_margin.?.atoms);
    const report = output.events[1].event.execution_report;
    try std.testing.expectEqual(@as(?u64, 2_000_000), report.venue_update_time_utc_ns);
    try std.testing.expect(report.venue_reduce_only.?);
    const fill = output.events[2].event.fill;
    try std.testing.expectEqual(@as(i128, 100_000), fill.fee.?.atoms);
    try std.testing.expectEqual(@as(i128, 1_250_000), fill.realized_pnl.?.atoms);
    try std.testing.expectEqual(canonical.LiquidityRole.taker, fill.liquidity);
}
