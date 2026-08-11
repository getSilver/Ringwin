//! Side-effect boundary for the fixed OKX Demo vertical chain.
//! Replay and dry-run modes cannot reach the transport vtable. A live attempt
//! requires a fresh fail-closed qualification and commits any venue response
//! to RawIngress before interpreting per-item dispatch results.

const std = @import("std");
const market = @import("okx_public_market.zig");
const order = @import("okx_order_entry.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_notional_usdt_micros: u64 = 25_000_000;

pub const RunMode = enum { replay, demo_dry_run, demo_live };

pub const Qualification = struct {
    explicit_demo_live: bool,
    endpoint_is_demo: bool,
    simulated_header: bool,
    credentials_loaded: bool,
    clock_healthy: bool,
    account_qualified: bool,
    reconciliation_stable: bool,
    no_unknown_orders: bool,
    cleanup_armed: bool,
};

pub const AuthorizedCommand = struct {
    command: order.OrderCommand,
    reserved_notional_usdt_micros: u64,
};

pub const TransportResult = struct {
    outcome: order.TransportOutcome,
    response: ?[]const u8 = null,
    source_session: u64,
    times: market.Times,
};

pub const Transport = struct {
    ptr: *anyopaque,
    submit_fn: *const fn (*anyopaque, []const u8, []const u8) TransportResult,

    pub fn submit(self: Transport, path: []const u8, body: []const u8) TransportResult {
        return self.submit_fn(self.ptr, path, body);
    }
};

pub const AttemptResult = struct {
    dispatch: order.ResultBatch,
    raw_evidence: ?market.RawEvidenceRef,
};

pub const Chain = struct {
    mode: RunMode,
    qualification: Qualification,
    raw_sink: market.RawSink,
    transport: Transport,
    next_attempt_id: u64 = 1,

    pub fn dispatch(
        self: *Chain,
        gpa: std.mem.Allocator,
        commands: []const AuthorizedCommand,
    ) !AttemptResult {
        try self.authorize(commands);
        if (commands.len == 0 or commands.len > order.max_batch_items)
            return error.InvalidBatch;

        var batch: order.TransportBatch = .{};
        for (commands, 0..) |authorized, index| batch.commands[index] = authorized.command;
        batch.count = @intCast(commands.len);
        const request = try order.encode(&batch);
        const attempt_base = self.next_attempt_id;
        self.next_attempt_id = try std.math.add(u64, attempt_base, commands.len);

        const response = self.transport.submit(request.path(), request.bytes());
        var evidence: ?market.RawEvidenceRef = null;
        if (response.response) |bytes| {
            if (bytes.len > market.max_raw_frame_bytes) return error.ResponseTooLarge;
            var digest: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(bytes, &digest, .{});
            evidence = try self.raw_sink.append(.{
                .source_session = response.source_session,
                .receive_time_utc_ns = response.times.receive_time_utc_ns,
                .monotonic_time_ns = response.times.monotonic_time_ns,
                .wall_time_utc_ns = response.times.wall_time_utc_ns,
                .byte_len = @intCast(bytes.len),
                .sha256 = digest,
            }, bytes);
        }
        if (response.outcome == .response and evidence == null)
            return error.ResponseMissingRawEvidence;

        return .{
            .dispatch = try order.classifyResponse(
                gpa,
                &request,
                attempt_base,
                response.outcome,
                response.response,
            ),
            .raw_evidence = evidence,
        };
    }

    fn authorize(self: *const Chain, commands: []const AuthorizedCommand) !void {
        if (self.mode != .demo_live) return error.SideEffectsDisabled;
        const q = self.qualification;
        if (!q.explicit_demo_live or !q.endpoint_is_demo or !q.simulated_header or
            !q.credentials_loaded or !q.clock_healthy or !q.account_qualified or
            !q.reconciliation_stable or !q.no_unknown_orders or !q.cleanup_armed)
            return error.DemoNotQualified;
        var total: u64 = 0;
        for (commands) |authorized| {
            if (authorized.command.instrument != .btc_usdt_spot and
                authorized.command.instrument != .btc_usdt_swap)
                return error.InstrumentNotAllowed;
            if (authorized.reserved_notional_usdt_micros == 0 or
                authorized.reserved_notional_usdt_micros > max_notional_usdt_micros)
                return error.NotionalLimitExceeded;
            total = std.math.add(u64, total, authorized.reserved_notional_usdt_micros) catch
                return error.NotionalLimitExceeded;
            if (total > max_notional_usdt_micros) return error.NotionalLimitExceeded;
        }
    }
};

const TestTransport = struct {
    calls: u32 = 0,
    outcome: order.TransportOutcome = .response,
    response: ?[]const u8 = "{\"code\":\"0\",\"data\":[{\"sCode\":\"0\",\"ordId\":\"1\"}]}",

    fn interface(self: *TestTransport) Transport {
        return .{ .ptr = self, .submit_fn = submit };
    }

    fn submit(ptr: *anyopaque, path: []const u8, body: []const u8) TransportResult {
        const self: *TestTransport = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        std.debug.assert(std.mem.eql(u8, path, "/api/v5/trade/order"));
        std.debug.assert(body.len != 0);
        return .{
            .outcome = self.outcome,
            .response = self.response,
            .source_session = 9,
            .times = .{
                .receive_time_utc_ns = 10,
                .monotonic_time_ns = 11,
                .wall_time_utc_ns = 12,
            },
        };
    }
};

const TestRawSink = struct {
    calls: u32 = 0,

    fn interface(self: *TestRawSink) market.RawSink {
        return .{ .ptr = self, .append_fn = append };
    }

    fn append(ptr: *anyopaque, record: market.RawIngressRecord, bytes: []const u8) market.RawSinkError!u64 {
        const self: *TestRawSink = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        std.debug.assert(record.byte_len == bytes.len);
        return self.calls;
    }
};

fn qualified() Qualification {
    return .{
        .explicit_demo_live = true,
        .endpoint_is_demo = true,
        .simulated_header = true,
        .credentials_loaded = true,
        .clock_healthy = true,
        .account_qualified = true,
        .reconciliation_stable = true,
        .no_unknown_orders = true,
        .cleanup_armed = true,
    };
}

fn command() AuthorizedCommand {
    return .{
        .reserved_notional_usdt_micros = 1_000_000,
        .command = .{
            .command_id = 1,
            .order_id = 2,
            .order_revision = 1,
            .shard_sequence = 3,
            .instrument = .btc_usdt_spot,
            .client_order_id = order.clientOrderId(2),
            .venue_order_id = null,
            .capability_version = 1,
            .rules_version = 1,
            .config_version = 1,
            .gateway_session = 1,
            .dispatch_deadline_monotonic_ns = 100,
            .risk_reservation_id = 4,
            .payload = .{ .place = .{
                .side = .buy,
                .kind = .limit_gtc,
                .quantity = .{ .coefficient = 1, .scale = 4 },
                .limit_price = .{ .coefficient = 50_000, .scale = 0 },
                .market_protection_price = null,
                .portfolio_reduce_only = false,
                .venue_reduce_only = false,
            } },
        },
    };
}

test "replay and dry-run can never invoke the transport" {
    var transport: TestTransport = .{};
    var raw: TestRawSink = .{};
    const authorized = [_]AuthorizedCommand{command()};
    for ([_]RunMode{ .replay, .demo_dry_run }) |mode| {
        var chain: Chain = .{
            .mode = mode,
            .qualification = qualified(),
            .raw_sink = raw.interface(),
            .transport = transport.interface(),
        };
        try std.testing.expectError(
            error.SideEffectsDisabled,
            chain.dispatch(std.testing.allocator, &authorized),
        );
    }
    try std.testing.expectEqual(@as(u32, 0), transport.calls);
    try std.testing.expectEqual(@as(u32, 0), raw.calls);
}

test "qualified Demo response is raw-committed before dispatch classification" {
    var transport: TestTransport = .{};
    var raw: TestRawSink = .{};
    var chain: Chain = .{
        .mode = .demo_live,
        .qualification = qualified(),
        .raw_sink = raw.interface(),
        .transport = transport.interface(),
    };
    const commands = [_]AuthorizedCommand{command()};
    const result = try chain.dispatch(std.testing.allocator, &commands);
    try std.testing.expectEqual(@as(u32, 1), transport.calls);
    try std.testing.expectEqual(@as(u32, 1), raw.calls);
    try std.testing.expect(result.raw_evidence != null);
    try std.testing.expectEqual(order.DispatchState.submitted, result.dispatch.items[0].state);
}

test "qualification and aggregate notional fail closed before transport" {
    var transport: TestTransport = .{};
    var raw: TestRawSink = .{};
    var chain: Chain = .{
        .mode = .demo_live,
        .qualification = qualified(),
        .raw_sink = raw.interface(),
        .transport = transport.interface(),
    };
    chain.qualification.cleanup_armed = false;
    const one = [_]AuthorizedCommand{command()};
    try std.testing.expectError(error.DemoNotQualified, chain.dispatch(std.testing.allocator, &one));
    chain.qualification.cleanup_armed = true;
    var too_large = command();
    too_large.reserved_notional_usdt_micros = max_notional_usdt_micros + 1;
    const oversized = [_]AuthorizedCommand{too_large};
    try std.testing.expectError(error.NotionalLimitExceeded, chain.dispatch(std.testing.allocator, &oversized));
    try std.testing.expectEqual(@as(u32, 0), transport.calls);
}

test "uncertain submission and rejected cleanup are never replayed automatically" {
    var raw: TestRawSink = .{};
    var uncertain_transport: TestTransport = .{
        .outcome = .write_or_response_uncertain,
        .response = null,
    };
    var uncertain_chain: Chain = .{
        .mode = .demo_live,
        .qualification = qualified(),
        .raw_sink = raw.interface(),
        .transport = uncertain_transport.interface(),
    };
    const commands = [_]AuthorizedCommand{command()};
    const uncertain = try uncertain_chain.dispatch(std.testing.allocator, &commands);
    try std.testing.expectEqual(order.DispatchState.unknown, uncertain.dispatch.items[0].state);
    try std.testing.expectEqual(@as(u32, 1), uncertain_transport.calls);
    uncertain_chain.qualification.no_unknown_orders = false;
    try std.testing.expectError(
        error.DemoNotQualified,
        uncertain_chain.dispatch(std.testing.allocator, &commands),
    );
    try std.testing.expectEqual(@as(u32, 1), uncertain_transport.calls);

    var cleanup_transport: TestTransport = .{
        .response = "{\"code\":\"1\",\"data\":[{\"sCode\":\"51020\",\"ordId\":\"\"}]}",
    };
    var cleanup_chain: Chain = .{
        .mode = .demo_live,
        .qualification = qualified(),
        .raw_sink = raw.interface(),
        .transport = cleanup_transport.interface(),
    };
    var cleanup = command();
    cleanup.command.payload.place.side = .sell;
    cleanup.command.payload.place.portfolio_reduce_only = true;
    const cleanup_commands = [_]AuthorizedCommand{cleanup};
    const rejected = try cleanup_chain.dispatch(std.testing.allocator, &cleanup_commands);
    try std.testing.expectEqual(order.DispatchState.submitted, rejected.dispatch.items[0].state);
    try std.testing.expectEqual(order.RejectReason.other_venue_reject, rejected.dispatch.items[0].reason.?);
    try std.testing.expectEqual(@as(u32, 1), cleanup_transport.calls);
}
