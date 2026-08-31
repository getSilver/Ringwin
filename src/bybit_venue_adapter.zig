//! Bybit V5 execution adapter; raw protocol details do not leave this module.
const std = @import("std");
const canonical = @import("canonical_event.zig");
const venue = @import("venue_adapter.zig");
const contract = @import("venue_adapter_contract.zig");
const private = @import("bybit_private_reconciliation.zig");

pub const InstrumentRules = struct { identity: canonical.InstrumentIdentity, tick_size: canonical.Decimal, lot_size: canonical.Decimal };
/// Explicit authority for a bounded Bybit TestnetRun. It never qualifies
/// production trading or Linux performance.
pub const TestnetAdmission = struct {
    explicit_enable: bool = false,
    endpoint_is_testnet: bool = false,
    credential_can_read: bool = false,
    credential_can_trade: bool = false,
    credential_can_withdraw: bool = true,
    max_order_notional_usdt_micros: u64 = 25_000_000,

    pub fn permitsPlace(self: TestnetAdmission) bool {
        return self.explicit_enable and self.endpoint_is_testnet and self.credential_can_read and self.credential_can_trade and !self.credential_can_withdraw and self.max_order_notional_usdt_micros > 0;
    }
};
pub const CapabilityProfile = struct {
    version: u64,
    rules_version: u64,
    config_version: u64,
    session: u64,
    spot: InstrumentRules,
    linear: InstrumentRules,
    batch_max: u8 = canonical.max_order_commands_per_batch,
    native_amend: bool = true,
    native_post_only: bool = true,
    venue_reduce_only_linear: bool = true,
    can_read: bool = true,
    can_trade: bool = true,
    testnet_admission: TestnetAdmission = .{},
    requests_per_window: u8 = 4,
    window_ns: u64 = std.time.ns_per_s,
};
pub const Authenticator = struct {
    ptr: *anyopaque,
    sign_fn: *const fn (*anyopaque, u64, []const u8) anyerror![32]u8,
    pub fn sign(self: Authenticator, timestamp: u64, body: []const u8) ![32]u8 {
        return self.sign_fn(self.ptr, timestamp, body);
    }
};
pub const TransportOutcome = enum { proven_before_send, response, write_or_response_uncertain };
pub const SignedRequest = struct { path: []const u8, body: []const u8, timestamp_ns: u64, signature: [32]u8 };
pub const TransportResult = struct { outcome: TransportOutcome, response: ?[]const u8 = null, source_session: u64, times: private.Times };
pub const Transport = struct {
    ptr: *anyopaque,
    submit_fn: *const fn (*anyopaque, SignedRequest) TransportResult,
    pub fn submit(self: Transport, request: SignedRequest) TransportResult {
        return self.submit_fn(self.ptr, request);
    }
};

const State = enum { idle, running, stopped };
const Binding = struct { venue: canonical.VenueIdentity, account: canonical.ExchangeAccountIdentity, session: canonical.AdapterSessionIdentity };
const Rate = struct { window_start: u64 = 0, count: u8 = 0 };
const Encoded = struct {
    path: []const u8,
    bytes: [768]u8 = undefined,
    len: usize = 0,
    fn body(self: *const Encoded) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const BybitVenueAdapter = struct {
    clock: Clock,
    profile: CapabilityProfile,
    auth: Authenticator,
    raw_sink: private.RawSink,
    transport: Transport,
    state: State = .idle,
    binding: ?Binding = null,
    pending: ?canonical.AdapterOutputBatch = null,
    next_sequence: u64 = 1,
    rate: Rate = .{},
    unknown_outstanding: bool = false,
    reconciler: ?*private.Reconciler = null,
    pending_account_reconciliation: ?u128 = null,

    pub const Clock = struct {
        ptr: *anyopaque,
        now_fn: *const fn (*anyopaque) u64,
        pub fn now(self: Clock) u64 {
            return self.now_fn(self.ptr);
        }
    };
    pub fn init(clock: Clock, profile: CapabilityProfile, auth: Authenticator, raw_sink: private.RawSink, transport: Transport) BybitVenueAdapter {
        return .{ .clock = clock, .profile = profile, .auth = auth, .raw_sink = raw_sink, .transport = transport };
    }
    pub fn adapter(self: *BybitVenueAdapter) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    pub fn attachPrivateReconciler(self: *BybitVenueAdapter, reconciler: *private.Reconciler) void {
        self.reconciler = reconciler;
    }
    pub fn beginPrivateSession(self: *BybitVenueAdapter) !void {
        const binding = self.binding orelse return error.NotStarted;
        (self.reconciler orelse return error.PrivateReconcilerMissing).beginSession(.{ .venue = binding.venue, .account = binding.account, .session = binding.session });
    }
    pub fn beginPrivateReconciliation(self: *BybitVenueAdapter) !void {
        if (self.state != .running) return error.NotStarted;
        const reconciler = self.reconciler orelse return error.PrivateReconcilerMissing;
        try reconciler.beginReconciliation(reconciler.readiness().raw_watermark);
    }
    pub fn ingestPrivate(self: *BybitVenueAdapter, allocator: std.mem.Allocator, source: private.Source, page: ?private.Page, times: private.Times, bytes: []const u8) !private.RawEvidenceRef {
        if (self.state != .running) return error.NotStarted;
        return (self.reconciler orelse return error.PrivateReconcilerMissing).ingest(allocator, source, page, times, bytes);
    }
    pub fn privateSourceGap(self: *BybitVenueAdapter) void {
        if (self.reconciler) |value| value.sourceGap();
    }

    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *BybitVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.environment != .demo or config.venue == 0 or config.exchange_account == 0 or config.adapter_session == 0 or config.adapter_session > std.math.maxInt(u64) or config.request_capacity == 0 or config.output_capacity < canonical.max_order_commands_per_batch or self.profile.session != @as(u64, @intCast(config.adapter_session))) return error.InvalidConfig;
        self.binding = .{ .venue = config.venue, .account = config.exchange_account, .session = config.adapter_session };
        if (self.reconciler) |value| value.beginSession(.{ .venue = config.venue, .account = config.exchange_account, .session = config.adapter_session });
        self.state = .running;
    }
    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *BybitVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.state == .stopped) return .stopped;
        if (self.pending != null) return .backpressure;
        switch (request) {
            .order_reconciliation => |value| return self.reconcileOrder(value),
            .account_reconciliation => |value| return self.reconcileAccount(value),
            else => {},
        }
        var commands: [canonical.max_order_commands_per_batch]canonical.OrderCommand = undefined;
        const count: usize = switch (request) {
            .order_command => |value| blk: {
                commands[0] = value;
                break :blk 1;
            },
            .order_batch => |value| blk: {
                if (value.len == 0) return error.InvalidRequest;
                @memcpy(commands[0..value.len], value.slice());
                break :blk value.len;
            },
            else => return error.InvalidRequest,
        };
        var output: canonical.AdapterOutputBatch = .{};
        if (count > self.profile.batch_max or !self.rateAvailable(self.clock.now())) {
            for (commands[0..count]) |command| self.appendDispatch(&output, command, .not_sent, .adapter_backpressure, null);
            self.pending = output;
            return .accepted;
        }
        if (!self.batchWithinNotional(commands[0..count])) {
            for (commands[0..count]) |command| self.appendDispatch(&output, command, .not_sent, .unsupported_value, null);
            self.pending = output;
            return .accepted;
        }
        for (commands[0..count]) |command| if (self.validate(command)) |reason| self.appendDispatch(&output, command, .not_sent, reason, null) else self.dispatch(&output, command);
        self.consumeRate(self.clock.now());
        self.pending = output;
        return .accepted;
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *BybitVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const pending = self.pending;
        self.pending = null;
        if (pending != null) return pending;
        if (self.reconciler) |value| if (value.drain()) |private_output| {
            var output = private_output;
            if (self.pending_account_reconciliation) |identity| for (output.slice()) |record| if (record.event == .account_bootstrap_snapshot) {
                self.appendEvent(&output, identity, .{ .account_reconciliation_result = .{ .identity = identity, .complete = true, .status = .found_terminal } });
                self.pending_account_reconciliation = null;
                break;
            };
            return output;
        };
        return null;
    }
    fn stop(ptr: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {
        const self: *BybitVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null or (self.reconciler != null and self.reconciler.?.hasPending())) return error.OutputPending;
        self.state = .stopped;
    }
    fn validate(self: *const BybitVenueAdapter, command: canonical.OrderCommand) ?canonical.CanonicalRejectReason {
        const binding = self.binding orelse return .unsupported_value;
        if (self.unknown_outstanding or !self.profile.can_read or !self.profile.can_trade or !self.profile.testnet_admission.permitsPlace()) return .venue_unavailable;
        if (command.exchange_account != binding.account or command.capability_version != self.profile.version or command.rules_version != self.profile.rules_version or command.config_version != self.profile.config_version or command.adapter_session != binding.session) return .stale_version;
        if (command.dispatch_deadline_monotonic_ns <= self.clock.now()) return .deadline_expired;
        const rules = self.rulesFor(command.instrument) orelse return .unsupported_instrument;
        if (command.operation == .amend and !self.profile.native_amend) return .capability_unsupported;
        if (command.operation != .place and (command.venue_order == null or command.venue_order.?.venue != binding.venue)) return .unsupported_value;
        if (command.order_type == .post_only and !self.profile.native_post_only) return .capability_unsupported;
        if (command.venue_reduce_only and (command.instrument != private.btc_usdt_linear or !self.profile.venue_reduce_only_linear)) return .capability_unsupported;
        if (command.operation != .cancel) {
            const quantity = command.quantity orelse return .unsupported_value;
            if (quantity.instrument != rules.identity or quantity.rules_version != self.profile.rules_version or quantity.lots <= 0) return .unsupported_value;
        }
        if (command.limit_price) |value| if (value.instrument != rules.identity or value.rules_version != self.profile.rules_version or value.ticks <= 0) return .unsupported_value;
        if (command.operation == .place) {
            const expected: canonical.TimeInForce = switch (command.order_type) {
                .market, .ioc => .immediate_or_cancel,
                .fok => .fill_or_kill,
                .post_only => .post_only,
                .limit => .good_til_canceled,
            };
            if (command.time_in_force != expected) return .unsupported_value;
            if (command.order_type == .market) {
                if (command.limit_price != null or command.market_protection_price == null) return .unsupported_value;
            } else if (command.limit_price == null or command.market_protection_price != null) return .unsupported_value;
            const price = command.limit_price orelse command.market_protection_price orelse return .unsupported_value;
            if ((self.notionalMicros(command.quantity orelse return .unsupported_value, price, rules) orelse return .unsupported_value) > self.profile.testnet_admission.max_order_notional_usdt_micros) return .unsupported_value;
        }
        return null;
    }
    fn notionalMicros(self: *const BybitVenueAdapter, quantity: canonical.InstrumentQuantity, price_value: canonical.InstrumentPrice, rules: InstrumentRules) ?u64 {
        _ = self;
        if (quantity.lots <= 0 or price_value.ticks <= 0) return null;
        var numerator = std.math.mul(i128, quantity.lots, rules.lot_size.coefficient) catch return null;
        numerator = std.math.mul(i128, numerator, price_value.ticks) catch return null;
        numerator = std.math.mul(i128, numerator, rules.tick_size.coefficient) catch return null;
        const scale = std.math.add(u8, rules.lot_size.scale, rules.tick_size.scale) catch return null;
        if (scale <= 6) return std.math.cast(u64, std.math.mul(i128, numerator, powerOfTen(6 - scale) orelse return null) catch return null);
        const divisor = powerOfTen(scale - 6) orelse return null;
        return std.math.cast(u64, @divFloor(std.math.add(i128, numerator, divisor - 1) catch return null, divisor));
    }
    fn batchWithinNotional(self: *const BybitVenueAdapter, commands: []const canonical.OrderCommand) bool {
        var total: u64 = 0;
        for (commands) |command| {
            if (command.operation != .place) continue;
            const rules = self.rulesFor(command.instrument) orelse return false;
            const quantity = command.quantity orelse return false;
            const price = command.limit_price orelse command.market_protection_price orelse return false;
            total = std.math.add(u64, total, self.notionalMicros(quantity, price, rules) orelse return false) catch return false;
            if (total > self.profile.testnet_admission.max_order_notional_usdt_micros) return false;
        }
        return true;
    }
    fn dispatch(self: *BybitVenueAdapter, output: *canonical.AdapterOutputBatch, command: canonical.OrderCommand) void {
        if (command.operation == .place) if (self.reconciler) |value| value.registerOrder(command.identity, command.client_order_id) catch {
            self.appendDispatch(output, command, .not_sent, .adapter_backpressure, null);
            return;
        };
        const encoded = self.encode(command) catch {
            self.appendDispatch(output, command, .not_sent, .unsupported_value, null);
            return;
        };
        const timestamp = self.clock.now();
        const signature = self.auth.sign(timestamp, encoded.body()) catch {
            self.appendDispatch(output, command, .not_sent, .venue_unavailable, null);
            return;
        };
        const response = self.transport.submit(.{ .path = encoded.path, .body = encoded.body(), .timestamp_ns = timestamp, .signature = signature });
        const evidence = self.commitResponse(response) catch {
            self.unknown_outstanding = true;
            self.appendDispatch(output, command, .unknown, null, null);
            return;
        };
        const state = classify(response.outcome, response.response);
        if (state == .unknown) self.unknown_outstanding = true;
        self.appendDispatch(output, command, state, if (state == .not_sent) .other_venue_reject else null, evidence);
    }
    fn reconcileOrder(self: *BybitVenueAdapter, request: canonical.OrderReconciliationRequest) venue.SendError!venue.SendResult {
        const binding = self.binding orelse return error.InvalidRequest;
        if (request.exchange_account != binding.account) return error.InvalidRequest;
        var output: canonical.AdapterOutputBatch = .{};
        self.appendEvent(&output, request.identity, .{ .reconciliation_started = request.identity });
        const status = if (self.reconciler) |value| value.resolveOrder(request.order) else .unresolved;
        if (status != .unresolved) self.unknown_outstanding = false;
        self.appendEvent(&output, request.identity, .{ .order_reconciliation_result = .{ .identity = request.identity, .complete = status != .unresolved, .status = status } });
        self.pending = output;
        return .accepted;
    }
    fn reconcileAccount(self: *BybitVenueAdapter, request: canonical.AccountReconciliationRequest) venue.SendError!venue.SendResult {
        const binding = self.binding orelse return error.InvalidRequest;
        if (request.exchange_account != binding.account or request.expected_session != binding.session) return error.InvalidRequest;
        var output: canonical.AdapterOutputBatch = .{};
        self.appendEvent(&output, request.identity, .{ .account_reconciliation_started = request.identity });
        const reconciler = self.reconciler orelse {
            self.appendEvent(&output, request.identity, .{ .account_reconciliation_result = .{ .identity = request.identity, .complete = false, .status = .unresolved } });
            self.pending = output;
            return .accepted;
        };
        if (reconciler.readiness().stage == .buffering) reconciler.beginReconciliation(reconciler.readiness().raw_watermark) catch return error.InvalidRequest;
        self.pending_account_reconciliation = request.identity;
        self.pending = output;
        return .accepted;
    }
    fn commitResponse(self: *BybitVenueAdapter, response: TransportResult) !?private.RawEvidenceRef {
        const bytes = response.response orelse return if (response.outcome == .response) error.MissingResponse else null;
        if (bytes.len == 0 or bytes.len > 1024 * 1024 or bytes.len > std.math.maxInt(u32)) return error.InvalidResponse;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return try self.raw_sink.append(.{ .source_session = response.source_session, .receive_time_utc_ns = response.times.receive_time_utc_ns, .monotonic_time_ns = response.times.monotonic_time_ns, .wall_time_utc_ns = response.times.wall_time_utc_ns, .byte_len = @intCast(bytes.len), .sha256 = digest }, bytes);
    }
    fn encode(self: *const BybitVenueAdapter, command: canonical.OrderCommand) !Encoded {
        const rules = self.rulesFor(command.instrument) orelse return error.UnsupportedInstrument;
        var result: Encoded = .{ .path = switch (command.operation) {
            .place => "/v5/order/create",
            .amend => "/v5/order/amend",
            .cancel => "/v5/order/cancel",
        } };
        var quantity_text: [64]u8 = undefined;
        var price_text: [64]u8 = undefined;
        const quantity_value = if (command.quantity) |value| try decimalText(&quantity_text, value.lots, rules.lot_size) else "";
        const price_value = if (command.limit_price) |value| try decimalText(&price_text, value.ticks, rules.tick_size) else "";
        const category = if (command.instrument == private.btc_usdt_spot) "spot" else "linear";
        const body = try std.fmt.bufPrint(&result.bytes, "{{\"category\":\"{s}\",\"symbol\":\"BTCUSDT\",\"orderLinkId\":\"{s}\",\"orderId\":\"{s}\",\"side\":\"{s}\",\"orderType\":\"{s}\",\"timeInForce\":\"{s}\",\"qty\":\"{s}\",\"price\":\"{s}\",\"reduceOnly\":{}}}", .{ category, command.client_order_id.slice(), if (command.venue_order) |value| value.value.slice() else "", switch (command.side) {
            .buy => "Buy",
            .sell => "Sell",
        }, switch (command.order_type) {
            .market => "Market",
            else => "Limit",
        }, switch (command.time_in_force) {
            .good_til_canceled => "GTC",
            .immediate_or_cancel => "IOC",
            .fill_or_kill => "FOK",
            .post_only => "PostOnly",
        }, quantity_value, price_value, command.venue_reduce_only });
        result.len = body.len;
        return result;
    }
    fn rulesFor(self: *const BybitVenueAdapter, instrument: canonical.InstrumentIdentity) ?InstrumentRules {
        if (instrument == self.profile.spot.identity) return self.profile.spot;
        if (instrument == self.profile.linear.identity) return self.profile.linear;
        return null;
    }
    fn rateAvailable(self: *const BybitVenueAdapter, now: u64) bool {
        return self.rate.count < self.profile.requests_per_window or now -| self.rate.window_start >= self.profile.window_ns;
    }
    fn consumeRate(self: *BybitVenueAdapter, now: u64) void {
        if (now -| self.rate.window_start >= self.profile.window_ns) self.rate = .{ .window_start = now, .count = 1 } else self.rate.count += 1;
    }
    fn appendDispatch(self: *BybitVenueAdapter, output: *canonical.AdapterOutputBatch, command: canonical.OrderCommand, state: canonical.DispatchState, reason: ?canonical.CanonicalRejectReason, evidence: ?private.RawEvidenceRef) void {
        self.append(output, command.identity, command.instrument, .{ .order_dispatch_result = .{ .command = command.identity, .state = state, .reason = reason } }, evidence);
    }
    fn appendEvent(self: *BybitVenueAdapter, output: *canonical.AdapterOutputBatch, source: u128, event: canonical.CanonicalEvent) void {
        self.append(output, source, null, event, null);
    }
    fn append(self: *BybitVenueAdapter, output: *canonical.AdapterOutputBatch, source: u128, instrument: ?canonical.InstrumentIdentity, event: canonical.CanonicalEvent, evidence: ?private.RawEvidenceRef) void {
        const binding = self.binding orelse return;
        const sequence = self.next_sequence;
        self.next_sequence +%= 1;
        output.append(.{ .envelope = .{ .event_type = @intFromEnum(canonical.eventType(event)), .schema_version = 1, .identity = .{ .stream = binding.session, .sequence = sequence }, .source_fact_identity = source, .scope = .account, .venue = binding.venue, .exchange_account = binding.account, .instrument = instrument, .source_stream = binding.session, .source_sequence = sequence, .adapter_session = binding.session, .times = .{ .monotonic_ns = self.clock.now() }, .raw_evidence = if (evidence) |value| .{ .stream = binding.session, .sequence = value.stream_sequence, .digest = value.sha256 } else .{ .stream = binding.session, .sequence = sequence, .digest = @splat(0) } }, .event = event }) catch return;
    }
};

fn decimalText(buffer: *[64]u8, units: i128, increment: canonical.Decimal) ![]const u8 {
    const value = try std.math.mul(i128, units, increment.coefficient);
    const absolute = if (value < 0) -value else value;
    const divisor = try pow10(increment.scale);
    const whole = try std.fmt.bufPrint(buffer, "{s}{d}", .{ if (value < 0) "-" else "", @divTrunc(absolute, divisor) });
    if (increment.scale == 0) return whole;
    var offset = whole.len;
    if (offset + 1 + increment.scale > buffer.len) return error.DecimalTooLong;
    buffer[offset] = '.';
    offset += 1;
    const remainder = @rem(absolute, divisor);
    var index: u8 = 0;
    while (index < increment.scale) : (index += 1) {
        const place = try pow10(increment.scale - index - 1);
        buffer[offset] = @intCast('0' + @mod(@divTrunc(remainder, place), 10));
        offset += 1;
    }
    return buffer[0..offset];
}
fn pow10(scale: u8) !i128 {
    var value: i128 = 1;
    for (0..scale) |_| value = try std.math.mul(i128, value, 10);
    return value;
}
fn powerOfTen(exponent: u8) ?i128 {
    var value: i128 = 1;
    for (0..exponent) |_| value = std.math.mul(i128, value, 10) catch return null;
    return value;
}
fn classify(outcome: TransportOutcome, response: ?[]const u8) canonical.DispatchState {
    if (outcome == .proven_before_send) return .not_sent;
    if (outcome == .write_or_response_uncertain) return .unknown;
    return if (response) |bytes| if (std.mem.indexOf(u8, bytes, "\"retCode\":0") != null) .submitted else .not_sent else .unknown;
}

const TestClock = struct {
    now: u64 = 1,
    fn interface(self: *TestClock) BybitVenueAdapter.Clock {
        return .{ .ptr = self, .now_fn = nowFn };
    }
    fn nowFn(ptr: *anyopaque) u64 {
        return (@as(*@This(), @ptrCast(@alignCast(ptr)))).now;
    }
};
const TestAuth = struct {
    fn interface(self: *TestAuth) Authenticator {
        return .{ .ptr = self, .sign_fn = sign };
    }
    fn sign(_: *anyopaque, _: u64, _: []const u8) ![32]u8 {
        return @splat(1);
    }
};
const TestRaw = struct {
    calls: u64 = 0,
    fn sink(self: *TestRaw) private.RawSink {
        return .{ .ptr = self, .append_fn = append };
    }
    fn append(ptr: *anyopaque, _: private.RawIngressRecord, _: []const u8) private.RawSinkError!u64 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return self.calls;
    }
};
const TestTransport = struct {
    calls: u64 = 0,
    outcome: TransportOutcome = .response,
    response: ?[]const u8 = "{\"retCode\":0}",
    fn interface(self: *TestTransport) Transport {
        return .{ .ptr = self, .submit_fn = submit };
    }
    fn submit(ptr: *anyopaque, request: SignedRequest) TransportResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        std.debug.assert(request.body.len > 0 and request.signature[0] == 1);
        return .{ .outcome = self.outcome, .response = self.response, .source_session = 6, .times = .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 2, .wall_time_utc_ns = 3 } };
    }
};
fn testProfile() CapabilityProfile {
    const spot = InstrumentRules{ .identity = private.btc_usdt_spot, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } };
    return .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 3, .spot = spot, .linear = .{ .identity = private.btc_usdt_linear, .tick_size = spot.tick_size, .lot_size = spot.lot_size }, .testnet_admission = .{ .explicit_enable = true, .endpoint_is_testnet = true, .credential_can_read = true, .credential_can_trade = true, .credential_can_withdraw = false } };
}
fn testCommand() !canonical.OrderCommand {
    return .{
        .identity = 7,
        .exchange_account = 2,
        .instrument = private.btc_usdt_spot,
        .client_order_id = try canonical.ClientOrderId.init("RWN-7"),
        .capability_version = 1,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 3,
        .dispatch_deadline_monotonic_ns = 2,
        .quantity = .{ .instrument = private.btc_usdt_spot, .rules_version = 1, .lots = 1 },
        .limit_price = .{ .instrument = private.btc_usdt_spot, .rules_version = 1, .ticks = 500000 },
    };
}
fn testAdapter(clock: *TestClock, auth: *TestAuth, raw: *TestRaw, transport: *TestTransport) BybitVenueAdapter {
    return BybitVenueAdapter.init(clock.interface(), testProfile(), auth.interface(), raw.sink(), transport.interface());
}
test "Bybit sends canonical commands only after response raw commit" {
    var clock = TestClock{};
    var auth = TestAuth{};
    var raw = TestRaw{};
    var transport = TestTransport{};
    var adapter = testAdapter(&clock, &auth, &raw, &transport);
    try adapter.adapter().start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 4 });
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.adapter().trySend(.{ .order_command = try testCommand() }));
    const output = (try adapter.adapter().tryDrain()).?;
    try std.testing.expectEqual(canonical.DispatchState.submitted, output.slice()[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(@as(u64, 1), raw.calls);
}
test "Bybit Testnet sends require explicit no-withdraw admission and bounded notional" {
    var clock = TestClock{};
    var auth = TestAuth{};
    var raw = TestRaw{};
    var transport = TestTransport{};
    var profile = testProfile();
    profile.testnet_admission = .{};
    var adapter = BybitVenueAdapter.init(clock.interface(), profile, auth.interface(), raw.sink(), transport.interface());
    try adapter.adapter().start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 4 });
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.adapter().trySend(.{ .order_command = try testCommand() }));
    try std.testing.expectEqual(canonical.DispatchState.not_sent, (try adapter.adapter().tryDrain()).?.slice()[0].event.order_dispatch_result.state);
    profile = testProfile();
    profile.testnet_admission.max_order_notional_usdt_micros = 1;
    adapter = BybitVenueAdapter.init(clock.interface(), profile, auth.interface(), raw.sink(), transport.interface());
    try adapter.adapter().start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 4 });
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.adapter().trySend(.{ .order_command = try testCommand() }));
    try std.testing.expectEqual(canonical.CanonicalRejectReason.unsupported_value, (try adapter.adapter().tryDrain()).?.slice()[0].event.order_dispatch_result.reason.?);
}
test "Bybit unknown dispatch remains closed until private reconciliation resolves it" {
    var clock = TestClock{};
    var auth = TestAuth{};
    var raw = TestRaw{};
    var transport = TestTransport{ .outcome = .write_or_response_uncertain, .response = null };
    var reconciler = private.Reconciler.init(raw.sink(), .{ .spot = .{ .identity = private.btc_usdt_spot, .rules_version = 1, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } }, .linear = .{ .identity = private.btc_usdt_linear, .rules_version = 1, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } } });
    var adapter = testAdapter(&clock, &auth, &raw, &transport);
    adapter.attachPrivateReconciler(&reconciler);
    try adapter.adapter().start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 4 });
    try adapter.beginPrivateReconciliation();
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.adapter().trySend(.{ .order_command = try testCommand() }));
    try std.testing.expectEqual(canonical.DispatchState.unknown, (try adapter.adapter().tryDrain()).?.slice()[0].event.order_dispatch_result.state);
    _ = try adapter.ingestPrivate(std.testing.allocator, .rest_orders, .{ .final = true }, .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 2, .wall_time_utc_ns = 3 }, "{\"result\":{\"list\":[{\"category\":\"spot\",\"symbol\":\"BTCUSDT\",\"orderId\":\"42\",\"orderLinkId\":\"RWN-7\",\"side\":\"Buy\",\"orderType\":\"Limit\",\"timeInForce\":\"GTC\",\"orderStatus\":\"Filled\",\"qty\":\"0.0001\",\"cumExecQty\":\"0.0001\",\"price\":\"50000.0\",\"avgPrice\":\"50000.0\",\"updatedTime\":\"2\",\"reduceOnly\":false}]}}");
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.adapter().trySend(.{ .order_reconciliation = .{ .identity = 11, .exchange_account = 2, .order = 7 } }));
    const result = (try adapter.adapter().tryDrain()).?;
    try std.testing.expectEqual(canonical.ReconciliationStatus.found_terminal, result.slice()[1].event.order_reconciliation_result.status);
}
test "Bybit adapter has the common VenueAdapter lifecycle" {
    var clock = TestClock{};
    var auth = TestAuth{};
    var raw = TestRaw{};
    var transport = TestTransport{};
    var adapter = testAdapter(&clock, &auth, &raw, &transport);
    try contract.exerciseWith(adapter.adapter(), .{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 4 }, .{ .order_command = try testCommand() });
}
