//! Binance execution implementation of the shared VenueAdapter seam.
//!
//! Venue request fields, credentials, signatures, limits, and response JSON
//! remain here. Callers supply only canonical OrderCommand values.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const venue = @import("venue_adapter.zig");
const contract = @import("venue_adapter_contract.zig");
const raw = @import("binance_order_raw.zig");
const private = @import("binance_private_reconciliation.zig");

pub const btc_usdt_spot: canonical.InstrumentIdentity = 0x424e_00000001;
pub const btc_usdt_linear: canonical.InstrumentIdentity = 0x424e_00000002;

pub const InstrumentRules = struct { identity: canonical.InstrumentIdentity, tick_size: canonical.Decimal, lot_size: canonical.Decimal };
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
pub const TransportResult = struct { outcome: TransportOutcome, response: ?[]const u8 = null, source_session: u64, times: raw.Times };
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
    bytes: [512]u8 = undefined,
    len: usize,
    fn body(self: *const Encoded) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const BinanceVenueAdapter = struct {
    clock: Clock,
    profile: CapabilityProfile,
    auth: Authenticator,
    raw_sink: raw.RawSink,
    transport: Transport,
    state: State = .idle,
    binding: ?Binding = null,
    pending: ?canonical.AdapterOutputBatch = null,
    next_event_sequence: u64 = 1,
    rate: Rate = .{},
    unknown_outstanding: bool = false,
    private_reconciler: ?*private.Reconciler = null,
    pending_account_reconciliation: ?u128 = null,

    pub const Clock = struct {
        ptr: *anyopaque,
        now_fn: *const fn (*anyopaque) u64,
        pub fn now(self: Clock) u64 {
            return self.now_fn(self.ptr);
        }
    };
    pub fn init(clock: Clock, capability_profile: CapabilityProfile, auth: Authenticator, raw_sink: raw.RawSink, transport: Transport) BinanceVenueAdapter {
        return .{ .clock = clock, .profile = capability_profile, .auth = auth, .raw_sink = raw_sink, .transport = transport };
    }
    pub fn adapter(self: *BinanceVenueAdapter) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    /// The transport remains private; callers can only retrieve the resulting
    /// CanonicalEvent records through the shared adapter drain seam.
    pub fn attachPrivateReconciler(self: *BinanceVenueAdapter, reconciler: *private.Reconciler) void {
        self.private_reconciler = reconciler;
    }
    pub fn beginPrivateReconciliation(self: *BinanceVenueAdapter) !void {
        if (self.state != .running) return error.NotStarted;
        const reconciler = self.private_reconciler orelse return error.PrivateReconcilerMissing;
        try reconciler.beginReconciliation(reconciler.readiness().raw_watermark);
    }
    pub fn beginPrivateSession(self: *BinanceVenueAdapter) !void {
        const binding = self.binding orelse return error.NotStarted;
        const reconciler = self.private_reconciler orelse return error.PrivateReconcilerMissing;
        reconciler.beginSession(.{ .venue = binding.venue, .account = binding.account, .session = binding.session });
    }
    pub fn ingestPrivate(self: *BinanceVenueAdapter, allocator: std.mem.Allocator, source: private.Source, page: ?private.Page, times: raw.Times, bytes: []const u8) !raw.RawEvidenceRef {
        if (self.state != .running) return error.NotStarted;
        return (self.private_reconciler orelse return error.PrivateReconcilerMissing).ingest(allocator, source, page, times, bytes);
    }
    pub fn privateSourceGap(self: *BinanceVenueAdapter) void {
        if (self.private_reconciler) |reconciler| reconciler.sourceGap();
    }

    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *BinanceVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.environment != .demo or config.venue == 0 or config.exchange_account == 0 or config.adapter_session == 0 or config.adapter_session > std.math.maxInt(u64) or config.request_capacity == 0 or config.output_capacity < canonical.max_order_commands_per_batch or self.profile.session != @as(u64, @intCast(config.adapter_session))) return error.InvalidConfig;
        self.binding = .{ .venue = config.venue, .account = config.exchange_account, .session = config.adapter_session };
        if (self.private_reconciler) |reconciler|
            reconciler.beginSession(.{ .venue = config.venue, .account = config.exchange_account, .session = config.adapter_session });
        self.state = .running;
    }
    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *BinanceVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.state == .stopped) return .stopped;
        if (self.pending != null) return .backpressure;
        switch (request) {
            .order_reconciliation => |reconciliation| return self.reconcileOrder(reconciliation),
            .account_reconciliation => |reconciliation| return self.reconcileAccount(reconciliation),
            else => {},
        }
        var commands: [canonical.max_order_commands_per_batch]canonical.OrderCommand = undefined;
        const count: usize = switch (request) {
            .order_command => |value| blk: {
                commands[0] = value;
                break :blk 1;
            },
            .order_batch => |batch| blk: {
                if (batch.len == 0) return error.InvalidRequest;
                @memcpy(commands[0..batch.len], batch.slice());
                break :blk batch.len;
            },
            else => return error.InvalidRequest,
        };
        var output: canonical.AdapterOutputBatch = .{};
        if (count > self.profile.batch_max or count > canonical.max_order_commands_per_batch) {
            for (commands[0..count]) |command| self.append(&output, command, .not_sent, .adapter_backpressure, null);
            self.pending = output;
            return .accepted;
        }
        if (!self.rateAvailable(self.clock.now())) {
            for (commands[0..count]) |command| self.append(&output, command, .not_sent, .adapter_backpressure, null);
            self.pending = output;
            return .accepted;
        }
        for (commands[0..count]) |command| if (self.validate(command)) |reason| {
            self.append(&output, command, .not_sent, reason, null);
        } else {
            self.dispatchOne(&output, command);
        };
        self.consumeRate(self.clock.now());
        self.pending = output;
        return .accepted;
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *BinanceVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const pending = self.pending;
        self.pending = null;
        if (pending != null) return pending;
        if (self.private_reconciler) |reconciler| if (reconciler.drain()) |private_output| {
            var output = private_output;
            if (self.pending_account_reconciliation != null) for (output.slice()) |record| if (record.event == .account_bootstrap_snapshot) {
                self.appendEvent(&output, self.pending_account_reconciliation.?, .{ .account_reconciliation_result = .{ .identity = self.pending_account_reconciliation.?, .complete = true, .status = .found_terminal } });
                self.pending_account_reconciliation = null;
                break;
            };
            return output;
        };
        return null;
    }
    fn stop(ptr: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {
        const self: *BinanceVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null or (self.private_reconciler != null and self.private_reconciler.?.hasPending())) return error.OutputPending;
        self.state = .stopped;
    }

    fn validate(self: *const BinanceVenueAdapter, command: canonical.OrderCommand) ?canonical.CanonicalRejectReason {
        const binding = self.binding orelse return .unsupported_value;
        if (self.unknown_outstanding) return .venue_unavailable;
        if (command.exchange_account != binding.account) return .unsupported_value;
        if (command.capability_version != self.profile.version or command.rules_version != self.profile.rules_version or command.config_version != self.profile.config_version or command.adapter_session != binding.session) return .stale_version;
        if (command.dispatch_deadline_monotonic_ns <= self.clock.now()) return .deadline_expired;
        const instrument_rules = self.rules(command.instrument) orelse return .unsupported_instrument;
        if (command.operation != .cancel) {
            const quantity = command.quantity orelse return .unsupported_value;
            if (quantity.instrument != command.instrument or quantity.rules_version != command.rules_version or quantity.lots <= 0) return .unsupported_value;
        }
        if (command.operation == .amend and !self.profile.native_amend) return .capability_unsupported;
        if (command.operation != .place and (command.venue_order == null or command.venue_order.?.venue != binding.venue)) return .unsupported_value;
        if (command.order_type == .post_only and !self.profile.native_post_only) return .capability_unsupported;
        if (command.venue_reduce_only and (command.instrument != btc_usdt_linear or !self.profile.venue_reduce_only_linear)) return .capability_unsupported;
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
        }
        if (command.limit_price) |price| if (price.instrument != instrument_rules.identity or price.rules_version != command.rules_version or price.ticks <= 0) return .unsupported_value;
        return null;
    }
    fn dispatchOne(self: *BinanceVenueAdapter, output: *canonical.AdapterOutputBatch, command: canonical.OrderCommand) void {
        if (command.operation == .place) if (self.private_reconciler) |reconciler|
            reconciler.registerOrder(command.identity, command.client_order_id) catch {
                self.append(output, command, .not_sent, .adapter_backpressure, null);
                return;
            };
        const encoded = self.encode(command) catch {
            self.append(output, command, .not_sent, .unsupported_value, null);
            return;
        };
        const timestamp = self.clock.now();
        const signature = self.auth.sign(timestamp, encoded.body()) catch {
            self.append(output, command, .not_sent, .venue_unavailable, null);
            return;
        };
        const response = self.transport.submit(.{ .path = encoded.path, .body = encoded.body(), .timestamp_ns = timestamp, .signature = signature });
        const evidence = self.commitResponse(response) catch {
            self.append(output, command, .unknown, null, null);
            self.unknown_outstanding = true;
            return;
        };
        const result = classify(response.outcome, response.response);
        if (result == .unknown) self.unknown_outstanding = true;
        self.append(output, command, result, if (result == .not_sent) .other_venue_reject else null, evidence);
    }
    fn reconcileOrder(self: *BinanceVenueAdapter, request: canonical.OrderReconciliationRequest) venue.SendError!venue.SendResult {
        const binding = self.binding orelse return error.InvalidRequest;
        if (request.exchange_account != binding.account) return error.InvalidRequest;
        var output: canonical.AdapterOutputBatch = .{};
        self.appendEvent(&output, request.identity, .{ .reconciliation_started = request.identity });
        const status = if (self.private_reconciler) |reconciler| reconciler.resolveOrder(request.order) else canonical.ReconciliationStatus.unresolved;
        if (status != .unresolved) self.unknown_outstanding = false;
        self.appendEvent(&output, request.identity, .{ .order_reconciliation_result = .{ .identity = request.identity, .complete = status != .unresolved, .status = status } });
        self.pending = output;
        return .accepted;
    }
    fn reconcileAccount(self: *BinanceVenueAdapter, request: canonical.AccountReconciliationRequest) venue.SendError!venue.SendResult {
        const binding = self.binding orelse return error.InvalidRequest;
        if (request.exchange_account != binding.account or request.expected_session != binding.session) return error.InvalidRequest;
        var output: canonical.AdapterOutputBatch = .{};
        self.appendEvent(&output, request.identity, .{ .account_reconciliation_started = request.identity });
        const reconciler = self.private_reconciler orelse {
            self.appendEvent(&output, request.identity, .{ .account_reconciliation_result = .{ .identity = request.identity, .complete = false, .status = .unresolved } });
            self.pending = output;
            return .accepted;
        };
        if (reconciler.readiness().stage == .buffering)
            reconciler.beginReconciliation(reconciler.readiness().raw_watermark) catch return error.InvalidRequest;
        self.pending_account_reconciliation = request.identity;
        self.pending = output;
        return .accepted;
    }
    fn commitResponse(self: *BinanceVenueAdapter, response: TransportResult) !?raw.RawEvidenceRef {
        const bytes = response.response orelse return if (response.outcome == .response) error.MissingResponse else null;
        if (bytes.len == 0 or bytes.len > 1024 * 1024 or bytes.len > std.math.maxInt(u32)) return error.InvalidResponse;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return try self.raw_sink.append(.{ .source_session = response.source_session, .receive_time_utc_ns = response.times.receive_time_utc_ns, .monotonic_time_ns = response.times.monotonic_time_ns, .wall_time_utc_ns = response.times.wall_time_utc_ns, .byte_len = @intCast(bytes.len), .sha256 = digest }, bytes);
    }
    fn encode(self: *const BinanceVenueAdapter, command: canonical.OrderCommand) !Encoded {
        const instrument_rules = self.rules(command.instrument) orelse return error.UnsupportedInstrument;
        var result: Encoded = .{ .path = if (command.instrument == btc_usdt_linear) "/fapi/v1/order" else "/api/v3/order", .len = 0 };
        const symbol = "BTCUSDT";
        const operation = switch (command.operation) {
            .place => "place",
            .amend => "amend",
            .cancel => "cancel",
        };
        var quantity_buffer: [64]u8 = undefined;
        const quantity = if (command.quantity) |value| try decimalText(&quantity_buffer, value.lots, instrument_rules.lot_size) else "";
        var price_buffer: [64]u8 = undefined;
        const price = if (command.limit_price) |value| try decimalText(&price_buffer, value.ticks, instrument_rules.tick_size) else "";
        const side = switch (command.side) {
            .buy => "BUY",
            .sell => "SELL",
        };
        const kind = switch (command.order_type) {
            .market => "MARKET",
            .limit => "LIMIT",
            .post_only => "LIMIT_MAKER",
            .fok => "LIMIT",
            .ioc => "LIMIT",
        };
        const tif = switch (command.time_in_force) {
            .good_til_canceled => "GTC",
            .immediate_or_cancel => "IOC",
            .fill_or_kill => "FOK",
            .post_only => "GTX",
        };
        const text = try std.fmt.bufPrint(&result.bytes, "{{\"symbol\":\"{s}\",\"clientOrderId\":\"{s}\",\"operation\":\"{s}\",\"side\":\"{s}\",\"type\":\"{s}\",\"timeInForce\":\"{s}\",\"quantity\":\"{s}\",\"price\":\"{s}\",\"reduceOnly\":{}}}", .{ symbol, command.client_order_id.slice(), operation, side, kind, tif, quantity, price, command.venue_reduce_only });
        result.len = text.len;
        return result;
    }
    fn rules(self: *const BinanceVenueAdapter, identity: canonical.InstrumentIdentity) ?InstrumentRules {
        if (identity == self.profile.spot.identity) return self.profile.spot;
        if (identity == self.profile.linear.identity) return self.profile.linear;
        return null;
    }
    fn rateAvailable(self: *const BinanceVenueAdapter, now: u64) bool {
        return self.rate.count < self.profile.requests_per_window or now -| self.rate.window_start >= self.profile.window_ns;
    }
    fn consumeRate(self: *BinanceVenueAdapter, now: u64) void {
        if (now -| self.rate.window_start >= self.profile.window_ns) self.rate = .{ .window_start = now, .count = 1 } else self.rate.count += 1;
    }
    fn append(self: *BinanceVenueAdapter, output: *canonical.AdapterOutputBatch, command: canonical.OrderCommand, state: canonical.DispatchState, reason: ?canonical.CanonicalRejectReason, evidence: ?raw.RawEvidenceRef) void {
        const binding = self.binding orelse return;
        const sequence = self.next_event_sequence;
        self.next_event_sequence +%= 1;
        output.append(.{ .envelope = .{ .event_type = @intFromEnum(canonical.EventType.order_dispatch_result), .schema_version = 1, .identity = .{ .stream = binding.session, .sequence = sequence }, .source_fact_identity = command.identity, .scope = .account, .venue = binding.venue, .exchange_account = binding.account, .instrument = command.instrument, .source_stream = binding.session, .source_sequence = sequence, .adapter_session = binding.session, .times = .{ .monotonic_ns = self.clock.now() }, .raw_evidence = if (evidence) |value| .{ .stream = binding.session, .sequence = value.stream_sequence, .digest = value.sha256 } else .{ .stream = binding.session, .sequence = sequence, .digest = @splat(0) } }, .event = .{ .order_dispatch_result = .{ .command = command.identity, .state = state, .reason = reason } } }) catch return;
    }
    fn appendEvent(self: *BinanceVenueAdapter, output: *canonical.AdapterOutputBatch, source_fact_identity: u128, event: canonical.CanonicalEvent) void {
        const binding = self.binding orelse return;
        const sequence = self.next_event_sequence;
        self.next_event_sequence +%= 1;
        output.append(.{ .envelope = .{ .event_type = @intFromEnum(canonical.eventType(event)), .schema_version = 1, .identity = .{ .stream = binding.session, .sequence = sequence }, .source_fact_identity = source_fact_identity, .scope = .account, .venue = binding.venue, .exchange_account = binding.account, .source_stream = binding.session, .source_sequence = sequence, .adapter_session = binding.session, .times = .{ .monotonic_ns = self.clock.now() }, .raw_evidence = .{ .stream = binding.session, .sequence = sequence, .digest = @splat(0) } }, .event = event }) catch return;
    }
};

fn decimalText(buffer: *[64]u8, units: i128, increment: canonical.Decimal) ![]const u8 {
    const value = try std.math.mul(i128, units, increment.coefficient);
    const sign: []const u8 = if (value < 0) "-" else "";
    const absolute = if (value < 0) -value else value;
    const divisor = try pow10(increment.scale);
    const whole = try std.fmt.bufPrint(buffer, "{s}{d}", .{ sign, @divTrunc(absolute, divisor) });
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
    var result: i128 = 1;
    var index: u8 = 0;
    while (index < scale) : (index += 1) result = try std.math.mul(i128, result, 10);
    return result;
}
fn classify(outcome: TransportOutcome, response: ?[]const u8) canonical.DispatchState {
    if (outcome == .proven_before_send) return .not_sent;
    if (outcome == .write_or_response_uncertain) return .unknown;
    const bytes = response orelse return .unknown;
    return if (std.mem.indexOf(u8, bytes, "\"code\":0") != null) .submitted else .not_sent;
}

const TestClock = struct {
    now: u64 = 1,
    fn interface(self: *TestClock) BinanceVenueAdapter.Clock {
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
    fn interface(self: *TestRaw) raw.RawSink {
        return .{ .ptr = self, .append_fn = append };
    }
    fn append(ptr: *anyopaque, _: raw.RawIngressRecord, _: []const u8) raw.RawSinkError!u64 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return self.calls;
    }
};
const TestTransport = struct {
    calls: u64 = 0,
    outcome: TransportOutcome = .response,
    response: ?[]const u8 = "{\"code\":0,\"orderId\":\"1\"}",
    fn interface(self: *TestTransport) Transport {
        return .{ .ptr = self, .submit_fn = submit };
    }
    fn submit(ptr: *anyopaque, request: SignedRequest) TransportResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        std.debug.assert(request.signature[0] == 1 and request.body.len > 0);
        if (std.mem.indexOf(u8, request.body, "\"operation\":\"place\"") != null)
            std.debug.assert(std.mem.indexOf(u8, request.body, "\"quantity\":\"0.0001\"") != null);
        return .{ .outcome = self.outcome, .response = self.response, .source_session = 6, .times = .{ .receive_time_utc_ns = 2, .monotonic_time_ns = 3, .wall_time_utc_ns = 4 } };
    }
};
fn testProfile() CapabilityProfile {
    const rules = InstrumentRules{ .identity = btc_usdt_spot, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } };
    return .{ .version = 7, .rules_version = 8, .config_version = 9, .session = 6, .spot = rules, .linear = .{ .identity = btc_usdt_linear, .tick_size = rules.tick_size, .lot_size = rules.lot_size } };
}
fn testCommand(identity: u128) !canonical.OrderCommand {
    return .{ .identity = identity, .exchange_account = 2, .instrument = btc_usdt_spot, .client_order_id = try canonical.ClientOrderId.init("BINANCE21"), .capability_version = 7, .rules_version = 8, .config_version = 9, .adapter_session = 6, .dispatch_deadline_monotonic_ns = 10, .quantity = .{ .instrument = btc_usdt_spot, .rules_version = 8, .lots = 1 }, .limit_price = .{ .instrument = btc_usdt_spot, .rules_version = 8, .ticks = 500_000 } };
}
fn privateRules(profile: CapabilityProfile) private.Rules {
    return .{
        .spot = .{ .identity = profile.spot.identity, .rules_version = profile.rules_version, .tick_size = profile.spot.tick_size, .lot_size = profile.spot.lot_size },
        .linear = .{ .identity = profile.linear.identity, .rules_version = profile.rules_version, .tick_size = profile.linear.tick_size, .lot_size = profile.linear.lot_size },
    };
}
fn startTest(adapter: venue.VenueAdapter) !void {
    try adapter.start(.{ .venue = 21, .environment = .demo, .exchange_account = 2, .adapter_session = 6, .request_capacity = 4, .output_capacity = 4 });
}

test "Binance canonical commands authenticate, raw-commit, and dispatch independently" {
    var clock = TestClock{};
    var auth = TestAuth{};
    var sink = TestRaw{};
    var transport = TestTransport{};
    var implementation = BinanceVenueAdapter.init(clock.interface(), testProfile(), auth.interface(), sink.interface(), transport.interface());
    const adapter = implementation.adapter();
    try startTest(adapter);
    var batch: canonical.OrderCommandBatch = .{};
    try batch.append(try testCommand(1));
    var second = try testCommand(2);
    second.operation = .cancel;
    second.venue_order = try canonical.VenueOrderRef.init(21, "order-2");
    try batch.append(second);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_batch = batch }));
    const output = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 2), output.len);
    try std.testing.expectEqual(canonical.DispatchState.submitted, output.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(@as(u64, 2), sink.calls);
    try std.testing.expectEqual(@as(u64, 2), transport.calls);
    try adapter.stop(.{ .monotonic_ns = 1 });
}
test "Binance rejects stale and expired commands and latches unknown without retry" {
    var clock = TestClock{};
    var auth = TestAuth{};
    var sink = TestRaw{};
    var transport = TestTransport{ .outcome = .write_or_response_uncertain, .response = null };
    var implementation = BinanceVenueAdapter.init(clock.interface(), testProfile(), auth.interface(), sink.interface(), transport.interface());
    const adapter = implementation.adapter();
    try startTest(adapter);
    var stale = try testCommand(1);
    stale.config_version = 10;
    _ = try adapter.trySend(.{ .order_command = stale });
    const rejected = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.CanonicalRejectReason.stale_version, rejected.events[0].event.order_dispatch_result.reason.?);
    _ = try adapter.trySend(.{ .order_command = try testCommand(2) });
    const unknown = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.DispatchState.unknown, unknown.events[0].event.order_dispatch_result.state);
    _ = try adapter.trySend(.{ .order_command = try testCommand(3) });
    const blocked = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.DispatchState.not_sent, blocked.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(@as(u64, 1), transport.calls);
}

test "Binance validates TIF, post-only, reduce-only, amend, and deadline before transport" {
    var clock = TestClock{};
    var auth = TestAuth{};
    var sink = TestRaw{};
    var transport = TestTransport{};
    var capability_profile = testProfile();
    capability_profile.native_post_only = false;
    var implementation = BinanceVenueAdapter.init(clock.interface(), capability_profile, auth.interface(), sink.interface(), transport.interface());
    const adapter = implementation.adapter();
    try startTest(adapter);
    var post = try testCommand(1);
    post.order_type = .post_only;
    post.time_in_force = .post_only;
    _ = try adapter.trySend(.{ .order_command = post });
    try std.testing.expectEqual(canonical.CanonicalRejectReason.capability_unsupported, (try adapter.tryDrain()).?.events[0].event.order_dispatch_result.reason.?);
    var amend = try testCommand(2);
    amend.operation = .amend;
    _ = try adapter.trySend(.{ .order_command = amend });
    try std.testing.expectEqual(canonical.CanonicalRejectReason.unsupported_value, (try adapter.tryDrain()).?.events[0].event.order_dispatch_result.reason.?);
    var expired = try testCommand(3);
    expired.dispatch_deadline_monotonic_ns = 1;
    _ = try adapter.trySend(.{ .order_command = expired });
    try std.testing.expectEqual(canonical.CanonicalRejectReason.deadline_expired, (try adapter.tryDrain()).?.events[0].event.order_dispatch_result.reason.?);
    try std.testing.expectEqual(@as(u64, 0), transport.calls);
}
test "Binance implementation exercises the shared VenueAdapter contract" {
    var clock = TestClock{};
    var auth = TestAuth{};
    var sink = TestRaw{};
    var transport = TestTransport{};
    var implementation = BinanceVenueAdapter.init(clock.interface(), testProfile(), auth.interface(), sink.interface(), transport.interface());
    try contract.exerciseWith(implementation.adapter(), .{ .venue = 21, .environment = .demo, .exchange_account = 2, .adapter_session = 6, .request_capacity = 4, .output_capacity = 4 }, .{ .order_command = try testCommand(1) });
}

test "Binance private bootstrap drains through the shared VenueAdapter seam" {
    var clock = TestClock{};
    var auth = TestAuth{};
    var sink = TestRaw{};
    var transport = TestTransport{};
    const profile = testProfile();
    var reconciler = private.Reconciler.init(sink.interface(), privateRules(profile));
    var implementation = BinanceVenueAdapter.init(clock.interface(), profile, auth.interface(), sink.interface(), transport.interface());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try startTest(adapter);
    try implementation.beginPrivateReconciliation();
    try reconciler.registerOrder(9, try canonical.ClientOrderId.init("RWN-9"));
    const times = raw.Times{ .receive_time_utc_ns = 1, .monotonic_time_ns = 2, .wall_time_utc_ns = 3 };
    _ = try implementation.ingestPrivate(std.testing.allocator, .rest_spot_account, .{ .final = true }, times, "{\"balances\":[]}");
    _ = try implementation.ingestPrivate(std.testing.allocator, .rest_orders, .{ .final = true }, times, "[]");
    _ = try implementation.ingestPrivate(std.testing.allocator, .rest_fills, .{ .final = true }, times, "[]");
    const output = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 1), output.len);
    try std.testing.expect(output.events[0].event == .account_bootstrap_snapshot);
    _ = try adapter.trySend(.{ .order_reconciliation = .{ .identity = 99, .exchange_account = 2, .order = 9 } });
    const resolved = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 2), resolved.len);
    try std.testing.expect(output.events[0].envelope.identity.stream != resolved.events[0].envelope.identity.stream);
    try std.testing.expectEqual(canonical.ReconciliationStatus.confirmed_absent, resolved.events[1].event.order_reconciliation_result.status);
}
