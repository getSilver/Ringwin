//! Bybit V5 private facts. Raw bytes are committed before protocol decoding.
const std = @import("std");
const canonical = @import("canonical_event.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const btc_usdt_spot: canonical.InstrumentIdentity = 0x4259_00000001;
pub const btc_usdt_linear: canonical.InstrumentIdentity = 0x4259_00000002;
pub const btc: canonical.AssetIdentity = 0x425443;
pub const usdt: canonical.AssetIdentity = 0x55534454;

pub const Times = struct { receive_time_utc_ns: u64, monotonic_time_ns: u64, wall_time_utc_ns: u64 };
pub const RawIngressRecord = struct { source_session: u64, receive_time_utc_ns: u64, monotonic_time_ns: u64, wall_time_utc_ns: u64, byte_len: u32, sha256: [32]u8 };
pub const RawEvidenceRef = struct { stream_sequence: u64, sha256: [32]u8 };
pub const RawSinkError = error{ Unavailable, Backpressure };
pub const RawSink = struct {
    ptr: *anyopaque,
    append_fn: *const fn (*anyopaque, RawIngressRecord, []const u8) RawSinkError!u64,
    pub fn append(self: RawSink, record: RawIngressRecord, bytes: []const u8) RawSinkError!RawEvidenceRef {
        return .{ .stream_sequence = try self.append_fn(self.ptr, record, bytes), .sha256 = record.sha256 };
    }
};

pub const InstrumentRules = struct { identity: canonical.InstrumentIdentity, rules_version: u64, tick_size: canonical.Decimal, lot_size: canonical.Decimal };
pub const Rules = struct { spot: InstrumentRules, linear: InstrumentRules };
pub const Binding = struct { venue: canonical.VenueIdentity, account: canonical.ExchangeAccountIdentity, session: canonical.AdapterSessionIdentity };
pub const Source = enum(u8) { ws, rest_wallet, rest_positions, rest_orders, rest_executions };
pub const Page = struct { final: bool };
pub const Stage = enum(u8) { offline, buffering, reconciling, ready, failed };
pub const Readiness = struct { stage: Stage, session: canonical.AdapterSessionIdentity, raw_watermark: u64, bootstrap: ?canonical.BootstrapSnapshotIdentity };

const max_events = 96;
const max_links = 32;
const max_seen = 128;
const Link = struct { order: canonical.OrderIdentity, client: canonical.ClientOrderId, status: ?canonical.ExecutionReportStatus = null };

pub const Reconciler = struct {
    raw_sink: RawSink,
    rules: Rules,
    binding: ?Binding = null,
    stage: Stage = .offline,
    raw_watermark: u64 = 0,
    bootstrap: ?canonical.BootstrapSnapshotIdentity = null,
    next_sequence: u64 = 1,
    balances_complete: bool = false,
    positions_complete: bool = false,
    orders_complete: bool = false,
    executions_complete: bool = false,
    balances: [canonical.max_account_facts]canonical.AccountBalance = undefined,
    balance_count: u8 = 0,
    positions: [canonical.max_account_facts]canonical.AccountPosition = undefined,
    position_count: u8 = 0,
    margins: [canonical.max_account_facts]canonical.AccountMargin = undefined,
    margin_count: u8 = 0,
    links: [max_links]Link = undefined,
    link_count: usize = 0,
    seen: [max_seen][32]u8 = undefined,
    seen_count: usize = 0,
    buffered: [max_events]canonical.EventRecord = undefined,
    buffered_count: usize = 0,
    ready: [max_events]canonical.EventRecord = undefined,
    ready_count: usize = 0,
    ready_index: usize = 0,

    pub fn init(raw_sink: RawSink, rules: Rules) Reconciler {
        return .{ .raw_sink = raw_sink, .rules = rules };
    }
    pub fn beginSession(self: *Reconciler, binding: Binding) void {
        const sink = self.raw_sink;
        const rules = self.rules;
        self.* = .{ .raw_sink = sink, .rules = rules, .binding = binding, .stage = .buffering };
    }
    pub fn sourceGap(self: *Reconciler) void {
        self.stage = .offline;
        self.bootstrap = null;
        self.buffered_count = 0;
        self.ready_count = 0;
        self.ready_index = 0;
    }
    pub fn beginReconciliation(self: *Reconciler, watermark: u64) !void {
        if (self.stage != .buffering or watermark < self.raw_watermark) return error.PrivateStreamNotReady;
        self.raw_watermark = watermark;
        self.stage = .reconciling;
    }
    pub fn readiness(self: *const Reconciler) Readiness {
        return .{ .stage = self.stage, .session = if (self.binding) |value| value.session else 0, .raw_watermark = self.raw_watermark, .bootstrap = self.bootstrap };
    }
    pub fn registerOrder(self: *Reconciler, order: canonical.OrderIdentity, client: canonical.ClientOrderId) !void {
        for (self.links[0..self.link_count]) |link| if (std.mem.eql(u8, link.client.slice(), client.slice())) {
            if (link.order != order) return error.ConflictingOrderLink;
            return;
        };
        if (self.link_count == self.links.len) return error.OrderLinkCapacity;
        self.links[self.link_count] = .{ .order = order, .client = client };
        self.link_count += 1;
    }
    pub fn resolveOrder(self: *const Reconciler, order: canonical.OrderIdentity) canonical.ReconciliationStatus {
        for (self.links[0..self.link_count]) |link| if (link.order == order) return if (link.status) |status| switch (status) {
            .accepted, .partially_filled, .amended => .found_live,
            .filled, .canceled, .rejected => .found_terminal,
        } else if (self.stage == .ready) .confirmed_absent else .unresolved;
        return .unresolved;
    }
    pub fn hasPending(self: *const Reconciler) bool {
        return self.ready_index < self.ready_count;
    }
    pub fn drain(self: *Reconciler) ?canonical.AdapterOutputBatch {
        if (!self.hasPending()) return null;
        var result: canonical.AdapterOutputBatch = .{};
        while (self.ready_index < self.ready_count and result.len < canonical.max_events_per_adapter_batch) {
            result.append(self.ready[self.ready_index]) catch break;
            self.ready_index += 1;
        }
        if (!self.hasPending()) {
            self.ready_count = 0;
            self.ready_index = 0;
        }
        return result;
    }
    pub fn ingest(self: *Reconciler, allocator: std.mem.Allocator, source: Source, page: ?Page, times: Times, bytes: []const u8) !RawEvidenceRef {
        const binding = self.binding orelse return error.StaleSession;
        if (bytes.len == 0 or bytes.len > 1024 * 1024 or bytes.len > std.math.maxInt(u32)) return error.InvalidFrame;
        var digest: [32]u8 = undefined;
        Sha256.hash(bytes, &digest, .{});
        const evidence = try self.raw_sink.append(.{ .source_session = @truncate(binding.session), .receive_time_utc_ns = times.receive_time_utc_ns, .monotonic_time_ns = times.monotonic_time_ns, .wall_time_utc_ns = times.wall_time_utc_ns, .byte_len = @intCast(bytes.len), .sha256 = digest }, bytes);
        self.raw_watermark = @max(self.raw_watermark, evidence.stream_sequence);
        if (self.stage == .offline or self.stage == .failed) return error.StaleSession;
        if ((source == .ws) != (page == null)) return error.InvalidPage;
        if (source != .ws and self.stage != .reconciling) return error.PrivateStreamNotReady;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .parse_numbers = false }) catch return error.InvalidFrame;
        defer parsed.deinit();
        self.decode(source, page, times, evidence, parsed.value) catch |err| {
            self.stage = .failed;
            return err;
        };
        return evidence;
    }

    fn decode(self: *Reconciler, source: Source, page: ?Page, times: Times, evidence: RawEvidenceRef, value: std.json.Value) !void {
        switch (source) {
            .ws => try self.decodeWs(times, evidence, value),
            .rest_wallet => try self.decodeWallet(false, times, evidence, value),
            .rest_positions => try self.decodePositions(false, times, evidence, value),
            .rest_orders => try self.decodeOrders(times, evidence, value),
            .rest_executions => try self.decodeExecutions(times, evidence, value),
        }
        if (page) |current| if (current.final) switch (source) {
            .rest_wallet => {
                self.balances_complete = true;
                self.margins_complete();
            },
            .rest_positions => self.positions_complete = true,
            .rest_orders => self.orders_complete = true,
            .rest_executions => self.executions_complete = true,
            .ws => unreachable,
        };
        try self.releaseBootstrap(times, evidence);
    }
    fn decodeWs(self: *Reconciler, times: Times, evidence: RawEvidenceRef, value: std.json.Value) !void {
        const root = try object(value);
        const topic = try string(root, "topic");
        if (std.mem.eql(u8, topic, "order")) return self.decodeOrders(times, evidence, value);
        if (std.mem.eql(u8, topic, "execution")) return self.decodeExecutions(times, evidence, value);
        if (std.mem.eql(u8, topic, "wallet")) return self.decodeWallet(true, times, evidence, value);
        if (std.mem.eql(u8, topic, "position")) return self.decodePositions(true, times, evidence, value);
        return error.UnsupportedPrivateTopic;
    }
    fn decodeOrders(self: *Reconciler, times: Times, evidence: RawEvidenceRef, value: std.json.Value) !void {
        const root = try object(value);
        const rows = try rowsFor(root);
        for (rows) |row| {
            const item = try object(row);
            const client = try string(item, "orderLinkId");
            const link = self.findLink(client) orelse continue;
            const status_text = try string(item, "orderStatus");
            const status = try reportStatus(status_text);
            self.setStatus(link.order, status);
            const order_id = try string(item, "orderId");
            const cumulative = try string(item, "cumExecQty");
            const key = keyFor(&.{ "report", order_id, status_text, cumulative, (try optionalString(item, "updatedTime")) orelse "" });
            if (try self.seenBefore(key)) continue;
            const rules = try self.rulesFor(item);
            const original = try quantity(rules, try string(item, "qty"));
            const executed = try quantity(rules, cumulative);
            if (executed.lots > original.lots) return error.InvalidReportQuantity;
            const update = try optionalMillis(item, "updatedTime");
            try self.emit(.account, rules.identity, null, identity(key), update, times, evidence, .{ .execution_report = .{ .identity = identity(key), .order = link.order, .client_order_id = link.client, .venue_order = try canonical.VenueOrderRef.init((self.binding orelse return error.StaleSession).venue, order_id), .instrument = rules.identity, .exchange_account = (self.binding orelse return error.StaleSession).account, .revision = 1, .side = try side(try string(item, "side")), .order_type = try orderType(try string(item, "orderType")), .time_in_force = try tif(try string(item, "timeInForce")), .venue_reduce_only = try optionalBool(item, "reduceOnly"), .position_mode_net = true, .status = status, .original_quantity = original, .cumulative_quantity = executed, .remaining_quantity = .{ .instrument = rules.identity, .rules_version = rules.rules_version, .lots = original.lots - executed.lots }, .limit_price = try optionalPrice(rules, (try optionalString(item, "price")) orelse "0"), .average_fill_price = try optionalPrice(rules, (try optionalString(item, "avgPrice")) orelse "0"), .venue_update_time_utc_ns = update } });
        }
    }
    fn decodeExecutions(self: *Reconciler, times: Times, evidence: RawEvidenceRef, value: std.json.Value) !void {
        const root = try object(value);
        const rows = try rowsFor(root);
        for (rows) |row| {
            const item = try object(row);
            const client = try string(item, "orderLinkId");
            const link = self.findLink(client) orelse continue;
            const execution_id = try string(item, "execId");
            const key = keyFor(&.{ "fill", execution_id });
            if (try self.seenBefore(key)) continue;
            const rules = try self.rulesFor(item);
            const fee = if (try optionalString(item, "execFee")) |value_text| try amount(try asset((try optionalString(item, "feeCurrency")) orelse "USDT"), value_text) else null;
            const pnl = if (try optionalString(item, "execPnl")) |value_text| try amount(usdt, value_text) else null;
            try self.emit(.account, rules.identity, null, identity(key), try optionalMillis(item, "execTime"), times, evidence, .{ .fill = .{ .identity = identity(key), .order = link.order, .client_order_id = link.client, .venue_order = try canonical.VenueOrderRef.init((self.binding orelse return error.StaleSession).venue, try string(item, "orderId")), .venue_trade = try canonical.VenueTradeRef.init((self.binding orelse return error.StaleSession).venue, execution_id), .instrument = rules.identity, .exchange_account = (self.binding orelse return error.StaleSession).account, .side = try side(try string(item, "side")), .quantity = try quantity(rules, try string(item, "execQty")), .price = try price(rules, try string(item, "execPrice")), .fee = if (fee) |value_fee| if (value_fee.atoms > 0) value_fee else null else null, .rebate = if (fee) |value_fee| if (value_fee.atoms < 0) .{ .asset = value_fee.asset, .atoms = -value_fee.atoms } else null else null, .realized_pnl = pnl, .liquidity = if (try boolField(item, "isMaker")) .maker else .taker } });
        }
    }
    fn decodeWallet(self: *Reconciler, observed: bool, times: Times, evidence: RawEvidenceRef, value: std.json.Value) !void {
        const root = try object(value);
        const accounts = try rowsFor(root);
        const emit_observation = observed and self.bootstrap != null;
        for (accounts) |account_value| {
            const account = try object(account_value);
            const coins = try array(try field(account, "coin"));
            for (coins.items) |coin_value| {
                const coin = try object(coin_value);
                const asset_id = try asset(try string(coin, "coin"));
                const total = try amount(asset_id, try string(coin, "walletBalance"));
                const available = try amount(asset_id, (try optionalString(coin, "availableToWithdraw")) orelse try string(coin, "walletBalance"));
                const balance = canonical.AccountBalance{ .asset = asset_id, .total = total, .available = available, .held = .{ .asset = asset_id, .atoms = total.atoms - available.atoms }, .liability = if (try optionalString(coin, "borrowAmount")) |borrowed| try amount(asset_id, borrowed) else null, .cash_balance = total };
                if (emit_observation) try self.emitObservedBalance(balance, times, evidence) else try self.storeBalance(balance);
                if (asset_id == usdt) {
                    const margin: canonical.AccountMargin = .{ .amount = total, .adjusted_equity = if (try optionalString(account, "totalEquity")) |equity| try amount(usdt, equity) else null, .initial_margin = if (try optionalString(account, "totalInitialMargin")) |initial| try amount(usdt, initial) else null, .maintenance_margin = if (try optionalString(account, "totalMaintenanceMargin")) |maintenance| try amount(usdt, maintenance) else null };
                    if (emit_observation) try self.emitObservedMargin(margin, times, evidence) else try self.storeMargin(margin);
                }
            }
        }
    }
    fn decodePositions(self: *Reconciler, observed: bool, times: Times, evidence: RawEvidenceRef, value: std.json.Value) !void {
        const root = try object(value);
        const rows = try rowsFor(root);
        const emit_observation = observed and self.bootstrap != null;
        for (rows) |row| {
            const item = try object(row);
            const rules = try self.rulesFor(item);
            if (rules.identity != btc_usdt_linear) continue;
            const side_text = (try optionalString(item, "side")) orelse continue;
            if (side_text.len == 0) continue;
            const position = canonical.AccountPosition{ .instrument = rules.identity, .side = if (std.mem.eql(u8, side_text, "Buy")) .long else if (std.mem.eql(u8, side_text, "Sell")) .short else return error.UnsupportedValue, .quantity = try quantity(rules, try string(item, "size")), .average_price = try optionalPrice(rules, (try optionalString(item, "entryPrice")) orelse "0"), .mark_price = try optionalPrice(rules, (try optionalString(item, "markPrice")) orelse "0"), .liquidation_price = try optionalPrice(rules, (try optionalString(item, "liqPrice")) orelse "0"), .margin = if (try optionalString(item, "positionIM")) |margin| try amount(usdt, margin) else null, .leverage = if (try optionalString(item, "leverage")) |leverage| try canonical.Decimal.parse(leverage) else null, .unrealized_pnl = if (try optionalString(item, "unrealisedPnl")) |pnl| try amount(usdt, pnl) else null };
            if (emit_observation) try self.emitObservedPosition(position, times, evidence) else try self.storePosition(position);
        }
    }
    fn releaseBootstrap(self: *Reconciler, times: Times, evidence: RawEvidenceRef) !void {
        if (self.stage != .reconciling or self.bootstrap != null or !self.balances_complete or !self.positions_complete or !self.orders_complete or !self.executions_complete) return;
        const binding = self.binding orelse return error.StaleSession;
        const snapshot_id = identity(evidence.sha256);
        var snapshot = std.mem.zeroes(canonical.AccountBootstrapSnapshot);
        snapshot.identity = snapshot_id;
        snapshot.exchange_account = binding.account;
        snapshot.scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true };
        snapshot.source_stream = privateStream(binding.session);
        snapshot.source_sequence = evidence.stream_sequence;
        snapshot.balance_count = self.balance_count;
        snapshot.position_count = self.position_count;
        snapshot.margin_count = self.margin_count;
        @memcpy(snapshot.balances[0..self.balance_count], self.balances[0..self.balance_count]);
        @memcpy(snapshot.positions[0..self.position_count], self.positions[0..self.position_count]);
        @memcpy(snapshot.margins[0..self.margin_count], self.margins[0..self.margin_count]);
        self.bootstrap = snapshot_id;
        self.stage = .ready;
        try self.appendReady(try self.record(.account, null, null, snapshot_id, null, times, evidence, .{ .account_bootstrap_snapshot = snapshot }));
        for (self.buffered[0..self.buffered_count]) |event| try self.appendReady(event);
        self.buffered_count = 0;
    }
    fn margins_complete(self: *Reconciler) void {
        _ = self;
    }
    fn emitObservedBalance(self: *Reconciler, value: canonical.AccountBalance, times: Times, evidence: RawEvidenceRef) !void {
        const bootstrap = self.bootstrap orelse return error.BootstrapRequired;
        const key = identity(evidence.sha256) +% self.next_sequence;
        try self.emit(.asset, null, value.asset, key, null, times, evidence, .{ .account_observed = .{ .identity = key, .exchange_account = (self.binding orelse return error.StaleSession).account, .bootstrap = bootstrap, .source_stream = privateStream((self.binding orelse return error.StaleSession).session), .source_sequence = evidence.stream_sequence, .value = .{ .balance = .{ .asset = value.asset, .value = value } } } });
    }
    fn emitObservedPosition(self: *Reconciler, value: canonical.AccountPosition, times: Times, evidence: RawEvidenceRef) !void {
        const bootstrap = self.bootstrap orelse return error.BootstrapRequired;
        const key = identity(evidence.sha256) +% self.next_sequence;
        try self.emit(.instrument, value.instrument, null, key, null, times, evidence, .{ .account_observed = .{ .identity = key, .exchange_account = (self.binding orelse return error.StaleSession).account, .bootstrap = bootstrap, .source_stream = privateStream((self.binding orelse return error.StaleSession).session), .source_sequence = evidence.stream_sequence, .value = .{ .position = .{ .instrument = value.instrument, .side = value.side, .value = value, .removed = value.quantity.lots == 0 } } } });
    }
    fn emitObservedMargin(self: *Reconciler, value: canonical.AccountMargin, times: Times, evidence: RawEvidenceRef) !void {
        const bootstrap = self.bootstrap orelse return error.BootstrapRequired;
        const key = identity(evidence.sha256) +% self.next_sequence;
        try self.emit(.account, value.instrument, null, key, null, times, evidence, .{ .account_observed = .{ .identity = key, .exchange_account = (self.binding orelse return error.StaleSession).account, .bootstrap = bootstrap, .source_stream = privateStream((self.binding orelse return error.StaleSession).session), .source_sequence = evidence.stream_sequence, .value = .{ .margin = .{ .instrument = value.instrument, .value = value } } } });
    }
    fn emit(self: *Reconciler, scope: canonical.CanonicalEventScope, instrument: ?canonical.InstrumentIdentity, asset_id: ?canonical.AssetIdentity, source_id: u128, source_time: ?u64, times: Times, evidence: RawEvidenceRef, event: canonical.CanonicalEvent) !void {
        const emitted = try self.record(scope, instrument, asset_id, source_id, source_time, times, evidence, event);
        if (self.stage == .ready) try self.appendReady(emitted) else {
            if (self.buffered_count == self.buffered.len) return error.PrivateOutputFull;
            self.buffered[self.buffered_count] = emitted;
            self.buffered_count += 1;
        }
    }
    fn record(self: *Reconciler, scope: canonical.CanonicalEventScope, instrument: ?canonical.InstrumentIdentity, asset_id: ?canonical.AssetIdentity, source_id: u128, source_time: ?u64, times: Times, evidence: RawEvidenceRef, event: canonical.CanonicalEvent) !canonical.EventRecord {
        const binding = self.binding orelse return error.StaleSession;
        const sequence = self.next_sequence;
        self.next_sequence = try std.math.add(u64, sequence, 1);
        const stream = privateStream(binding.session);
        return .{ .envelope = .{ .event_type = @intFromEnum(canonical.eventType(event)), .schema_version = 1, .identity = .{ .stream = stream, .sequence = sequence }, .source_fact_identity = source_id, .scope = scope, .venue = binding.venue, .exchange_account = binding.account, .instrument = instrument, .asset = asset_id, .source_stream = stream, .source_sequence = evidence.stream_sequence, .adapter_session = binding.session, .times = .{ .source_utc_ns = source_time, .receive_utc_ns = times.receive_time_utc_ns, .monotonic_ns = times.monotonic_time_ns, .audit_utc_ns = times.wall_time_utc_ns }, .raw_evidence = .{ .stream = stream, .sequence = evidence.stream_sequence, .digest = evidence.sha256 } }, .event = event };
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
    fn findLink(self: *const Reconciler, client: []const u8) ?Link {
        for (self.links[0..self.link_count]) |link| if (std.mem.eql(u8, link.client.slice(), client)) return link;
        return null;
    }
    fn setStatus(self: *Reconciler, order: canonical.OrderIdentity, status: canonical.ExecutionReportStatus) void {
        for (self.links[0..self.link_count]) |*link| if (link.order == order) {
            link.status = status;
            return;
        };
    }
    fn rulesFor(self: *const Reconciler, item: std.json.ObjectMap) !InstrumentRules {
        if (!std.mem.eql(u8, try string(item, "symbol"), "BTCUSDT")) return error.UnsupportedInstrument;
        const category = (try optionalString(item, "category")) orelse "linear";
        if (std.mem.eql(u8, category, "spot")) return self.rules.spot;
        if (std.mem.eql(u8, category, "linear")) return self.rules.linear;
        return error.UnsupportedInstrument;
    }
    fn seenBefore(self: *Reconciler, key: [32]u8) !bool {
        for (self.seen[0..self.seen_count]) |known| if (std.mem.eql(u8, &known, &key)) return true;
        if (self.seen_count == self.seen.len) return error.FactCapacity;
        self.seen[self.seen_count] = key;
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
fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |item| item,
        else => error.InvalidFrame,
    };
}
fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |item| item,
        else => error.InvalidFrame,
    };
}
fn field(value: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return value.get(name) orelse error.MissingField;
}
fn text(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |item| item,
        .number_string => |item| item,
        else => error.InvalidField,
    };
}
fn string(value: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return text(try field(value, name));
}
fn optionalString(value: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const item = value.get(name) orelse return null;
    return switch (item) {
        .null => null,
        else => try text(item),
    };
}
fn boolField(value: std.json.ObjectMap, name: []const u8) !bool {
    return switch (try field(value, name)) {
        .bool => |item| item,
        else => error.InvalidField,
    };
}
fn optionalBool(value: std.json.ObjectMap, name: []const u8) !?bool {
    return if (value.get(name)) |item| switch (item) {
        .null => null,
        .bool => |truth| truth,
        else => error.InvalidField,
    } else null;
}
fn rowsFor(root: std.json.ObjectMap) ![]const std.json.Value {
    if (root.get("data")) |data| return (try array(data)).items;
    const result = try object(try field(root, "result"));
    return (try array(try field(result, "list"))).items;
}
fn millis(value: []const u8) !u64 {
    return std.math.mul(u64, try std.fmt.parseInt(u64, value, 10), std.time.ns_per_ms);
}
fn optionalMillis(item: std.json.ObjectMap, name: []const u8) !?u64 {
    return if (try optionalString(item, name)) |value| try millis(value) else null;
}
fn keyFor(parts: []const []const u8) [32]u8 {
    var hash = Sha256.init(.{});
    for (parts) |part| {
        hash.update(part);
        hash.update(&[_]u8{0});
    }
    return hash.finalResult();
}
fn identity(digest: [32]u8) u128 {
    return std.mem.readInt(u128, digest[0..16], .little);
}
fn privateStream(session: canonical.AdapterSessionIdentity) canonical.StreamIdentity {
    return session ^ 0x4259_4259_5052_4956_4154_455f_0000_0000;
}
fn asset(code: []const u8) !canonical.AssetIdentity {
    if (std.mem.eql(u8, code, "BTC")) return btc;
    if (std.mem.eql(u8, code, "USDT")) return usdt;
    return error.UnsupportedAsset;
}
fn scale(asset_id: canonical.AssetIdentity) !u8 {
    return switch (asset_id) {
        btc => 8,
        usdt => 6,
        else => error.UnsupportedAsset,
    };
}
fn amount(asset_id: canonical.AssetIdentity, value: []const u8) !canonical.AssetAmount {
    return canonical.AssetAmount.fromDecimal(asset_id, try canonical.Decimal.parse(value), try scale(asset_id));
}
fn quantity(rules: InstrumentRules, value: []const u8) !canonical.InstrumentQuantity {
    return canonical.InstrumentQuantity.fromDecimal(rules.identity, rules.rules_version, try canonical.Decimal.parse(value), rules.lot_size.scale, try rules.lot_size.exactAtoms(rules.lot_size.scale));
}
fn price(rules: InstrumentRules, value: []const u8) !canonical.InstrumentPrice {
    return canonical.InstrumentPrice.fromDecimal(rules.identity, rules.rules_version, try canonical.Decimal.parse(value), rules.tick_size.scale, try rules.tick_size.exactAtoms(rules.tick_size.scale));
}
fn optionalPrice(rules: InstrumentRules, value: []const u8) !?canonical.InstrumentPrice {
    const decimal = try canonical.Decimal.parse(value);
    return if (decimal.coefficient == 0) null else try canonical.InstrumentPrice.fromDecimal(rules.identity, rules.rules_version, decimal, rules.tick_size.scale, try rules.tick_size.exactAtoms(rules.tick_size.scale));
}
fn side(value: []const u8) !canonical.OrderSide {
    if (std.mem.eql(u8, value, "Buy")) return .buy;
    if (std.mem.eql(u8, value, "Sell")) return .sell;
    return error.UnsupportedValue;
}
fn orderType(value: []const u8) !canonical.OrderType {
    if (std.mem.eql(u8, value, "Limit")) return .limit;
    if (std.mem.eql(u8, value, "Market")) return .market;
    return error.UnsupportedValue;
}
fn tif(value: []const u8) !canonical.TimeInForce {
    if (std.mem.eql(u8, value, "GTC")) return .good_til_canceled;
    if (std.mem.eql(u8, value, "IOC")) return .immediate_or_cancel;
    if (std.mem.eql(u8, value, "FOK")) return .fill_or_kill;
    if (std.mem.eql(u8, value, "PostOnly")) return .post_only;
    return error.UnsupportedValue;
}
fn reportStatus(value: []const u8) !canonical.ExecutionReportStatus {
    if (std.mem.eql(u8, value, "New")) return .accepted;
    if (std.mem.eql(u8, value, "PartiallyFilled")) return .partially_filled;
    if (std.mem.eql(u8, value, "Filled")) return .filled;
    if (std.mem.eql(u8, value, "Cancelled")) return .canceled;
    if (std.mem.eql(u8, value, "Rejected")) return .rejected;
    return error.UnsupportedValue;
}

const TestRaw = struct {
    calls: u64 = 0,
    fn sink(self: *TestRaw) RawSink {
        return .{ .ptr = self, .append_fn = append };
    }
    fn append(ptr: *anyopaque, _: RawIngressRecord, _: []const u8) RawSinkError!u64 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return self.calls;
    }
};
fn testRules() Rules {
    const spot = InstrumentRules{ .identity = btc_usdt_spot, .rules_version = 1, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } };
    return .{ .spot = spot, .linear = .{ .identity = btc_usdt_linear, .rules_version = 1, .tick_size = spot.tick_size, .lot_size = spot.lot_size } };
}
fn startTest(reconciler: *Reconciler) !void {
    reconciler.beginSession(.{ .venue = 42, .account = 2, .session = 7 });
    try reconciler.registerOrder(9, try canonical.ClientOrderId.init("RWN-9"));
    try reconciler.beginReconciliation(0);
}
const test_times = Times{ .receive_time_utc_ns = 1, .monotonic_time_ns = 2, .wall_time_utc_ns = 3 };
test "Bybit raw ingress precedes invalid private frames" {
    var raw = TestRaw{};
    var reconciler = Reconciler.init(raw.sink(), testRules());
    try startTest(&reconciler);
    try std.testing.expectError(error.InvalidFrame, reconciler.ingest(std.testing.allocator, .ws, null, test_times, "bad"));
    try std.testing.expectEqual(@as(u64, 1), raw.calls);
}
test "Bybit separates deduplicated reports and fills from economic facts" {
    var raw = TestRaw{};
    var reconciler = Reconciler.init(raw.sink(), testRules());
    try startTest(&reconciler);
    const order = "{\"topic\":\"order\",\"data\":[{\"category\":\"linear\",\"symbol\":\"BTCUSDT\",\"orderId\":\"42\",\"orderLinkId\":\"RWN-9\",\"side\":\"Buy\",\"orderType\":\"Limit\",\"timeInForce\":\"GTC\",\"orderStatus\":\"Filled\",\"qty\":\"0.0100\",\"cumExecQty\":\"0.0100\",\"price\":\"50000.0\",\"avgPrice\":\"50000.0\",\"updatedTime\":\"2\",\"reduceOnly\":false}]}";
    const execution = "{\"topic\":\"execution\",\"data\":[{\"category\":\"linear\",\"symbol\":\"BTCUSDT\",\"orderId\":\"42\",\"orderLinkId\":\"RWN-9\",\"execId\":\"77\",\"side\":\"Buy\",\"execQty\":\"0.0100\",\"execPrice\":\"50000.0\",\"execFee\":\"0.010000\",\"feeCurrency\":\"USDT\",\"execPnl\":\"0\",\"execTime\":\"2\",\"isMaker\":true}]}";
    _ = try reconciler.ingest(std.testing.allocator, .ws, null, test_times, order);
    _ = try reconciler.ingest(std.testing.allocator, .ws, null, test_times, execution);
    _ = try reconciler.ingest(std.testing.allocator, .ws, null, test_times, execution);
    _ = try reconciler.ingest(std.testing.allocator, .rest_wallet, .{ .final = true }, test_times, "{\"result\":{\"list\":[{\"coin\":[{\"coin\":\"USDT\",\"walletBalance\":\"10.000000\",\"availableToWithdraw\":\"9.000000\"}]}]}}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_positions, .{ .final = true }, test_times, "{\"result\":{\"list\":[]}}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_orders, .{ .final = true }, test_times, "{\"result\":{\"list\":[]}}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_executions, .{ .final = true }, test_times, "{\"result\":{\"list\":[]}}");
    var count: usize = 0;
    var fills: usize = 0;
    while (reconciler.drain()) |batch| for (batch.slice()) |event| {
        count += 1;
        if (event.event == .fill) fills += 1;
    };
    try std.testing.expect(count >= 3);
    try std.testing.expectEqual(@as(usize, 1), fills);
}

test "Bybit emits absolute observations only after a complete bootstrap" {
    var raw = TestRaw{};
    var reconciler = Reconciler.init(raw.sink(), testRules());
    try startTest(&reconciler);
    _ = try reconciler.ingest(std.testing.allocator, .rest_wallet, .{ .final = true }, test_times, "{\"result\":{\"list\":[{\"coin\":[{\"coin\":\"USDT\",\"walletBalance\":\"10.000000\",\"availableToWithdraw\":\"9.000000\"}]}]}}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_positions, .{ .final = true }, test_times, "{\"result\":{\"list\":[]}}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_orders, .{ .final = true }, test_times, "{\"result\":{\"list\":[]}}");
    _ = try reconciler.ingest(std.testing.allocator, .rest_executions, .{ .final = true }, test_times, "{\"result\":{\"list\":[]}}");
    _ = reconciler.drain();
    _ = try reconciler.ingest(std.testing.allocator, .ws, null, test_times, "{\"topic\":\"wallet\",\"data\":[{\"coin\":[{\"coin\":\"USDT\",\"walletBalance\":\"11.000000\",\"availableToWithdraw\":\"10.000000\"}]}]}");
    const output = reconciler.drain().?;
    try std.testing.expectEqual(canonical.EventType.account_observed, canonical.eventType(output.slice()[0].event));
    try std.testing.expectEqual(raw.calls, output.slice()[0].envelope.source_sequence);
}
