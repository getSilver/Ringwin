//! OKX execution implementation of the shared VenueAdapter seam.
//!
//! The protocol codec, priority scheduler, and qualified Demo transport remain
//! Venue-private. Only canonical requests and canonical dispatch facts cross
//! this boundary.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const live = @import("okx_live_chain.zig");
const order = @import("okx_order_entry.zig");
const venue = @import("venue_adapter.zig");
const contract = @import("venue_adapter_contract.zig");

pub const btc_usdt_spot: canonical.InstrumentIdentity = 0x4f4b58_00000001;
pub const btc_usdt_swap: canonical.InstrumentIdentity = 0x4f4b58_00000002;

pub const Clock = struct {
    ptr: *anyopaque,
    now_fn: *const fn (*anyopaque) u64,

    pub fn now(self: Clock) u64 {
        return self.now_fn(self.ptr);
    }
};

pub const InstrumentRules = struct {
    identity: canonical.InstrumentIdentity,
    tick_size: canonical.Decimal,
    lot_size: canonical.Decimal,
};

pub const Rules = struct {
    spot: InstrumentRules,
    swap: InstrumentRules,
};

const State = enum { idle, running, stopped };
const Binding = struct {
    venue: canonical.VenueIdentity,
    account: canonical.ExchangeAccountIdentity,
    session: canonical.AdapterSessionIdentity,
};
const Pending = struct {
    legacy_id: u64,
    command: canonical.OrderCommand,
    notional_usdt_micros: u64,
};
const pending_capacity = order.normal_queue_capacity + order.safety_queue_capacity;

pub const OkxVenueAdapter = struct {
    allocator: std.mem.Allocator,
    chain: *live.Chain,
    clock: Clock,
    profile: order.CapabilityProfile,
    rules: Rules,
    state: State = .idle,
    binding: ?Binding = null,
    scheduler: ?order.Scheduler = null,
    pending_output: ?canonical.AdapterOutputBatch = null,
    pending: [pending_capacity]Pending = undefined,
    pending_count: u8 = 0,
    next_legacy_id: u64 = 1,
    next_event_sequence: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, chain: *live.Chain, clock: Clock, capability_profile: order.CapabilityProfile, instrument_rules: Rules) OkxVenueAdapter {
        return .{ .allocator = allocator, .chain = chain, .clock = clock, .profile = capability_profile, .rules = instrument_rules };
    }

    pub fn adapter(self: *OkxVenueAdapter) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }

    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *OkxVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.environment != .demo or config.venue == 0 or config.exchange_account == 0 or config.adapter_session == 0 or
            config.adapter_session > std.math.maxInt(u64) or config.request_capacity == 0 or config.output_capacity == 0 or
            self.profile.gateway_session != @as(u64, @intCast(config.adapter_session)))
            return error.InvalidConfig;
        self.scheduler = order.Scheduler.init(self.profile) catch return error.InvalidConfig;
        self.binding = .{ .venue = config.venue, .account = config.exchange_account, .session = config.adapter_session };
        self.state = .running;
    }

    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *OkxVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.state == .stopped) return .stopped;
        if (self.pending_output != null) return .backpressure;
        switch (request) {
            .order_command => |command| try self.enqueue(command),
            .order_batch => |commands| {
                if (commands.len == 0) return error.InvalidRequest;
                for (commands.slice()) |command| try self.enqueue(command);
            },
            else => return error.InvalidRequest,
        }
        self.pump();
        return .accepted;
    }

    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *OkxVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        self.pump();
        const output = self.pending_output;
        self.pending_output = null;
        return output;
    }

    fn stop(ptr: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {
        const self: *OkxVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.pending_output != null or self.pending_count != 0) return error.OutputPending;
        self.state = .stopped;
    }

    fn enqueue(self: *OkxVenueAdapter, command: canonical.OrderCommand) venue.SendError!void {
        const binding = self.binding orelse return error.InvalidRequest;
        if (command.exchange_account != binding.account) return error.InvalidRequest;
        const legacy_id = self.allocateLegacyId() catch {
            self.appendResult(command, .not_sent, .adapter_backpressure, null);
            return;
        };
        const translated = self.translate(command, legacy_id) catch |err| {
            self.appendResult(command, .not_sent, translateError(err), null);
            return;
        };
        const scheduler = &(self.scheduler orelse return error.InvalidRequest);
        const guard = self.guardFor(&translated.command);
        switch (scheduler.enqueue(translated.command, guard, self.clock.now())) {
            .queued => self.appendPending(.{ .legacy_id = legacy_id, .command = command, .notional_usdt_micros = translated.notional_usdt_micros }) catch
                self.appendResult(command, .not_sent, .adapter_backpressure, null),
            .dispatch => |result| self.appendResult(command, dispatchState(result.state), rejectReason(result.reason), null),
        }
    }

    fn pump(self: *OkxVenueAdapter) void {
        if (self.state != .running or self.pending_output != null) return;
        const scheduler = &(self.scheduler orelse return);
        const next = scheduler.next(self.clock.now(), self.guardSource()) orelse return;
        switch (next) {
            .dispatch => |result| {
                const pending = self.takePending(result.command_id) orelse return;
                self.appendResult(pending.command, dispatchState(result.state), rejectReason(result.reason), null);
            },
            .batch => |batch| self.dispatchBatch(batch),
        }
    }

    fn dispatchBatch(self: *OkxVenueAdapter, batch: order.TransportBatch) void {
        var commands: [order.max_batch_items]live.AuthorizedCommand = undefined;
        for (batch.slice(), 0..) |legacy, index| {
            const pending = self.findPending(legacy.command_id) orelse return;
            commands[index] = .{ .command = legacy, .reserved_notional_usdt_micros = pending.notional_usdt_micros };
        }
        const attempt = self.chain.dispatch(self.allocator, commands[0..batch.count]) catch |err| {
            const state: canonical.DispatchState = switch (err) {
                error.SideEffectsDisabled, error.DemoNotQualified, error.NotionalLimitExceeded, error.InstrumentNotAllowed => .not_sent,
                else => .unknown,
            };
            const reason: ?canonical.CanonicalRejectReason = if (state == .not_sent) .venue_unavailable else null;
            for (batch.slice()) |legacy| if (self.takePending(legacy.command_id)) |pending|
                self.appendResult(pending.command, state, reason, null);
            return;
        };
        for (attempt.dispatch.items[0..attempt.dispatch.count]) |result| if (self.takePending(result.command_id)) |pending|
            self.appendResult(pending.command, dispatchState(result.state), rejectReason(result.reason), attempt.raw_evidence);
    }

    fn translate(self: *const OkxVenueAdapter, command: canonical.OrderCommand, legacy_id: u64) !struct { command: order.OrderCommand, notional_usdt_micros: u64 } {
        const binding = self.binding orelse return error.InvalidBinding;
        const mapped = self.mapInstrument(command.instrument) orelse return error.UnsupportedInstrument;
        if (command.adapter_session > std.math.maxInt(u64)) return error.StaleVersion;
        const client_order_id = try order.ClientOrderId.init(command.client_order_id.slice());
        var result: order.OrderCommand = .{
            .command_id = legacy_id,
            .order_id = legacy_id,
            .order_revision = command.revision,
            .shard_sequence = legacy_id,
            .instrument = mapped.instrument,
            .client_order_id = client_order_id,
            .venue_order_id = try self.venueOrder(command.venue_order, binding.venue),
            .capability_version = command.capability_version,
            .rules_version = command.rules_version,
            .config_version = command.config_version,
            .gateway_session = @intCast(command.adapter_session),
            .dispatch_deadline_monotonic_ns = command.dispatch_deadline_monotonic_ns,
            .risk_reservation_id = 1,
            .payload = undefined,
        };
        switch (command.operation) {
            .place => {
                const quantity = command.quantity orelse return error.UnsupportedValue;
                const price = command.limit_price orelse return error.UnsupportedValue;
                if (quantity.rules_version != command.rules_version or price.rules_version != command.rules_version)
                    return error.StaleVersion;
                try validateValues(command, mapped.rules);
                const quantity_decimal = try decimalFor(quantity.lots, mapped.rules.lot_size);
                const price_decimal = try decimalFor(price.ticks, mapped.rules.tick_size);
                result.payload = .{ .place = .{ .side = switch (command.side) {
                    .buy => .buy,
                    .sell => .sell,
                }, .kind = .limit_gtc, .quantity = quantity_decimal, .limit_price = price_decimal, .market_protection_price = null, .portfolio_reduce_only = false, .venue_reduce_only = false } };
                return .{ .command = result, .notional_usdt_micros = try notionalMicros(quantity_decimal, price_decimal) };
            },
            .amend => {
                const quantity = command.quantity orelse return error.UnsupportedValue;
                if (quantity.rules_version != command.rules_version) return error.StaleVersion;
                try validateQuantity(quantity, mapped.rules);
                result.payload = .{ .amend = .{ .request_id = order.amendRequestId(command.identity), .target_remaining_quantity = try decimalFor(quantity.lots, mapped.rules.lot_size), .cumulative_filled_quantity = .{ .coefficient = 0, .scale = 0 }, .new_limit_price = if (command.limit_price) |price| blk: {
                    if (price.rules_version != command.rules_version) return error.StaleVersion;
                    try validatePrice(price, mapped.rules);
                    break :blk try decimalFor(price.ticks, mapped.rules.tick_size);
                } else null, .increases_risk = false } };
                return .{ .command = result, .notional_usdt_micros = 1 };
            },
            .cancel => {
                result.payload = .{ .cancel = .{} };
                return .{ .command = result, .notional_usdt_micros = 1 };
            },
        }
    }

    fn mapInstrument(self: *const OkxVenueAdapter, identity: canonical.InstrumentIdentity) ?struct { instrument: order.Instrument, rules: InstrumentRules } {
        if (identity == self.rules.spot.identity) return .{ .instrument = .btc_usdt_spot, .rules = self.rules.spot };
        if (identity == self.rules.swap.identity) return .{ .instrument = .btc_usdt_swap, .rules = self.rules.swap };
        return null;
    }

    fn venueOrder(_: *const OkxVenueAdapter, reference: ?canonical.VenueOrderRef, venue_identity: canonical.VenueIdentity) !?order.VenueOrderId {
        const value = reference orelse return null;
        if (value.venue != venue_identity) return error.InvalidVenueOrder;
        return @enumFromInt(try std.fmt.parseInt(u64, value.value.slice(), 10));
    }

    fn guardFor(self: *const OkxVenueAdapter, command: *const order.OrderCommand) order.Guard {
        return .{ .order_entry_ready = true, .risk_reservation_valid = true, .capability_version = self.profile.version, .rules_version = self.profile.rules_version, .config_version = self.profile.config_version, .gateway_session = self.profile.gateway_session, .current_order_revision = command.order_revision, .cumulative_filled_quantity = .{ .coefficient = 0, .scale = 0 } };
    }

    fn guardSource(self: *OkxVenueAdapter) order.GuardSource {
        return .{ .ptr = self, .load_fn = loadGuard };
    }

    fn loadGuard(ptr: *anyopaque, command: *const order.OrderCommand) ?order.Guard {
        const self: *OkxVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.findPending(command.command_id) == null) return null;
        return self.guardFor(command);
    }

    fn appendPending(self: *OkxVenueAdapter, pending: Pending) !void {
        if (self.pending_count == self.pending.len) return error.Full;
        self.pending[self.pending_count] = pending;
        self.pending_count += 1;
    }

    fn findPending(self: *const OkxVenueAdapter, legacy_id: u64) ?*const Pending {
        for (self.pending[0..self.pending_count]) |*pending| if (pending.legacy_id == legacy_id) return pending;
        return null;
    }

    fn takePending(self: *OkxVenueAdapter, legacy_id: u64) ?Pending {
        for (self.pending[0..self.pending_count], 0..) |pending, index| if (pending.legacy_id == legacy_id) {
            var cursor = index;
            while (cursor + 1 < self.pending_count) : (cursor += 1) self.pending[cursor] = self.pending[cursor + 1];
            self.pending_count -= 1;
            return pending;
        };
        return null;
    }

    fn allocateLegacyId(self: *OkxVenueAdapter) !u64 {
        const identity = self.next_legacy_id;
        self.next_legacy_id = try std.math.add(u64, identity, 1);
        return identity;
    }

    fn appendResult(self: *OkxVenueAdapter, command: canonical.OrderCommand, state: canonical.DispatchState, reason: ?canonical.CanonicalRejectReason, raw: ?@import("okx_public_market.zig").RawEvidenceRef) void {
        var output = self.pending_output orelse canonical.AdapterOutputBatch{};
        const binding = self.binding orelse return;
        const sequence = self.next_event_sequence;
        self.next_event_sequence +%= 1;
        output.append(.{ .envelope = .{
            .event_type = 1,
            .schema_version = 1,
            .identity = .{ .stream = binding.session, .sequence = sequence },
            .source_fact_identity = command.identity,
            .scope = .account,
            .venue = binding.venue,
            .exchange_account = binding.account,
            .instrument = command.instrument,
            .source_stream = binding.session,
            .source_sequence = sequence,
            .adapter_session = binding.session,
            .times = .{ .monotonic_ns = self.clock.now() },
            .raw_evidence = if (raw) |evidence| .{ .stream = binding.session, .sequence = evidence.stream_sequence, .digest = evidence.sha256 } else .{ .stream = binding.session, .sequence = sequence, .digest = @splat(0) },
        }, .event = .{ .order_dispatch_result = .{ .command = command.identity, .state = state, .reason = reason } } }) catch return;
        self.pending_output = output;
    }
};

fn validateValues(command: canonical.OrderCommand, instrument_rules: InstrumentRules) !void {
    try validateQuantity(command.quantity orelse return error.UnsupportedValue, instrument_rules);
    try validatePrice(command.limit_price orelse return error.UnsupportedValue, instrument_rules);
}

fn validateQuantity(quantity: canonical.InstrumentQuantity, instrument_rules: InstrumentRules) !void {
    if (quantity.instrument != instrument_rules.identity or quantity.rules_version == 0 or quantity.lots <= 0) return error.UnsupportedValue;
}

fn validatePrice(price: canonical.InstrumentPrice, instrument_rules: InstrumentRules) !void {
    if (price.instrument != instrument_rules.identity or price.rules_version == 0 or price.ticks <= 0) return error.UnsupportedValue;
}

fn decimalFor(units: i128, increment: canonical.Decimal) !order.Decimal {
    return .{ .coefficient = try std.math.mul(i128, units, increment.coefficient), .scale = increment.scale };
}

fn notionalMicros(quantity: order.Decimal, price: order.Decimal) !u64 {
    const product = canonical.Decimal{ .coefficient = try std.math.mul(i128, quantity.coefficient, price.coefficient), .scale = try std.math.add(u8, quantity.scale, price.scale) };
    const micros = try product.exactAtoms(6);
    if (micros <= 0) return error.InvalidNotional;
    return std.math.cast(u64, micros) orelse error.InvalidNotional;
}

fn dispatchState(value: order.DispatchState) canonical.DispatchState {
    return switch (value) {
        .not_sent => .not_sent,
        .submitted => .submitted,
        .unknown => .unknown,
    };
}

fn rejectReason(value: ?order.RejectReason) ?canonical.CanonicalRejectReason {
    return switch (value orelse return null) {
        .capability_unsupported => .capability_unsupported,
        .deadline_expired => .deadline_expired,
        .adapter_backpressure, .rate_limited => .adapter_backpressure,
        .venue_unavailable, .order_entry_not_ready => .venue_unavailable,
        .invalid_spec, .invalid_risk_reservation, .stale_order_revision, .capability_version_changed => .stale_version,
        else => .other_venue_reject,
    };
}

fn translateError(err: anyerror) canonical.CanonicalRejectReason {
    return switch (err) {
        error.UnsupportedInstrument => .unsupported_instrument,
        error.StaleVersion => .stale_version,
        error.InvalidVenueOrder, error.InvalidCharacter, error.Overflow => .unsupported_value,
        else => .unsupported_value,
    };
}

const TestClock = struct {
    value: u64 = 1,
    fn interface(self: *TestClock) Clock {
        return .{ .ptr = self, .now_fn = now };
    }
    fn now(ptr: *anyopaque) u64 {
        return (@as(*TestClock, @ptrCast(@alignCast(ptr)))).value;
    }
};

const TestRawSink = struct {
    calls: u64 = 0,
    fn interface(self: *TestRawSink) @import("okx_public_market.zig").RawSink {
        return .{ .ptr = self, .append_fn = append };
    }
    fn append(ptr: *anyopaque, _: @import("okx_public_market.zig").RawIngressRecord, _: []const u8) @import("okx_public_market.zig").RawSinkError!u64 {
        const self: *TestRawSink = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return self.calls;
    }
};

const TestTransport = struct {
    calls: u64 = 0,
    outcome: order.TransportOutcome = .response,
    response: ?[]const u8 = "{\"code\":\"0\",\"data\":[{\"sCode\":\"0\",\"ordId\":\"1\"}]}",
    fn interface(self: *TestTransport) live.Transport {
        return .{ .ptr = self, .submit_fn = submit };
    }
    fn submit(ptr: *anyopaque, _: []const u8, _: []const u8) live.TransportResult {
        const self: *TestTransport = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return .{ .outcome = self.outcome, .response = self.response, .source_session = 5, .times = .{ .receive_time_utc_ns = 2, .monotonic_time_ns = 3, .wall_time_utc_ns = 4 } };
    }
};

fn qualification() live.Qualification {
    return .{ .explicit_demo_live = true, .endpoint_is_demo = true, .simulated_header = true, .credentials_loaded = true, .clock_healthy = true, .account_qualified = true, .reconciliation_stable = true, .no_unknown_orders = true, .cleanup_armed = true };
}

fn testProfile() order.CapabilityProfile {
    return .{ .version = 7, .rules_version = 8, .config_version = 9, .gateway_session = 6, .qualification = .demo_qualified, .batch_max = 4, .place_limit = .{ .requests = 4, .window_ns = 100 }, .place_batch_limit = .{ .requests = 4, .window_ns = 100 }, .amend_limit = .{ .requests = 4, .window_ns = 100 }, .amend_batch_limit = .{ .requests = 4, .window_ns = 100 }, .cancel_limit = .{ .requests = 4, .window_ns = 100 }, .cancel_batch_limit = .{ .requests = 4, .window_ns = 100 }, .subaccount_place_amend_limit = .{ .requests = 4, .window_ns = 100 }, .limit = true, .protected_market_ioc = true, .ioc = true, .fok = true, .native_amend = true, .native_post_only = true, .swap_venue_reduce_only = true };
}

fn testRules() Rules {
    return .{ .spot = .{ .identity = btc_usdt_spot, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } }, .swap = .{ .identity = btc_usdt_swap, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 2 } } };
}

fn testCommand(identity: u128) !canonical.OrderCommand {
    return .{ .identity = identity, .exchange_account = 2, .instrument = btc_usdt_spot, .client_order_id = try canonical.ClientOrderId.init("OKX15A"), .capability_version = 7, .rules_version = 8, .config_version = 9, .adapter_session = 6, .dispatch_deadline_monotonic_ns = 10, .quantity = .{ .instrument = btc_usdt_spot, .rules_version = 8, .lots = 1 }, .limit_price = .{ .instrument = btc_usdt_spot, .rules_version = 8, .ticks = 500_000 } };
}

fn startTest(adapter: venue.VenueAdapter) !void {
    try adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 6, .request_capacity = 4, .output_capacity = 4 });
}

test "OKX venue adapter translates canonical commands and itemizes a batch" {
    var raw = TestRawSink{};
    var transport = TestTransport{ .response = "{\"code\":\"0\",\"data\":[{\"sCode\":\"0\",\"ordId\":\"1\"},{\"sCode\":\"0\",\"ordId\":\"2\"}]}" };
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    const adapter = implementation.adapter();
    try startTest(adapter);
    var batch = canonical.OrderCommandBatch{};
    try batch.append(try testCommand(100));
    try batch.append(try testCommand(101));
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_batch = batch }));
    const output = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 2), output.len);
    try std.testing.expectEqual(canonical.DispatchState.submitted, output.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(@as(canonical.OrderIdentity, 100), output.events[0].event.order_dispatch_result.command);
    try std.testing.expectEqual(@as(canonical.OrderIdentity, 101), output.events[1].event.order_dispatch_result.command);
    try std.testing.expectEqual(@as(u64, 1), transport.calls);
    try std.testing.expectEqual(@as(u64, 1), raw.calls);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "OKX venue adapter preserves not-sent and unknown without retrying transport" {
    var raw = TestRawSink{};
    var transport = TestTransport{ .outcome = .write_or_response_uncertain, .response = null };
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    const adapter = implementation.adapter();
    try startTest(adapter);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = try testCommand(200) }));
    const unknown = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.DispatchState.unknown, unknown.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(@as(u64, 1), transport.calls);

    var expired = try testCommand(201);
    expired.dispatch_deadline_monotonic_ns = 1;
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = expired }));
    const not_sent = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.DispatchState.not_sent, not_sent.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(canonical.CanonicalRejectReason.deadline_expired, not_sent.events[0].event.order_dispatch_result.reason.?);
    try std.testing.expectEqual(@as(u64, 1), transport.calls);

    var stale = try testCommand(202);
    stale.rules_version = 99;
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = stale }));
    const stale_result = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.CanonicalRejectReason.stale_version, stale_result.events[0].event.order_dispatch_result.reason.?);
    try std.testing.expectEqual(@as(u64, 1), transport.calls);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "replay and dry-run OKX adapters cannot call transport" {
    for ([_]live.RunMode{ .replay, .demo_dry_run }) |mode| {
        var raw = TestRawSink{};
        var transport = TestTransport{};
        var chain: live.Chain = .{ .mode = mode, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
        var clock = TestClock{};
        var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
        const adapter = implementation.adapter();
        try startTest(adapter);
        try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = try testCommand(300) }));
        const output = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(canonical.DispatchState.not_sent, output.events[0].event.order_dispatch_result.state);
        try std.testing.expectEqual(@as(u64, 0), transport.calls);
        try adapter.stop(.{ .monotonic_ns = 1 });
    }

    var raw = TestRawSink{};
    var transport = TestTransport{};
    var unavailable = qualification();
    unavailable.cleanup_armed = false;
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = unavailable, .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    const adapter = implementation.adapter();
    try startTest(adapter);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = try testCommand(301) }));
    try std.testing.expectEqual(canonical.DispatchState.not_sent, (try adapter.tryDrain()).?.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(@as(u64, 0), transport.calls);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "OKX adapter reuses the shared VenueAdapter contract" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    try contract.exerciseWith(implementation.adapter(), .{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 6, .request_capacity = 1, .output_capacity = 1 }, .{ .order_command = try testCommand(400) });
}

test "amend and cancel use the canonical VenueOrderRef without leaking an OKX order identity" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    const adapter = implementation.adapter();
    try startTest(adapter);
    var amend = try testCommand(500);
    amend.operation = .amend;
    amend.venue_order = try canonical.VenueOrderRef.init(1, "21");
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = amend }));
    try std.testing.expectEqual(canonical.DispatchState.submitted, (try adapter.tryDrain()).?.events[0].event.order_dispatch_result.state);

    var cancel = try testCommand(501);
    cancel.operation = .cancel;
    cancel.venue_order = try canonical.VenueOrderRef.init(1, "21");
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = cancel }));
    try std.testing.expectEqual(canonical.DispatchState.submitted, (try adapter.tryDrain()).?.events[0].event.order_dispatch_result.state);
    try adapter.stop(.{ .monotonic_ns = 1 });
}
