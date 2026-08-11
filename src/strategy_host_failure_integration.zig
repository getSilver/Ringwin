const std = @import("std");
const builtin = @import("builtin");
const gateway_module = @import("strategy_host_gateway.zig");
const ipc = @import("strategy_host_ipc.zig");
const lifecycle = @import("strategy_host_lifecycle.zig");
const recovery_module = @import("strategy_host_recovery.zig");

fn runCheck(init: std.process.Init, python: []const u8, script: []const u8, bridge: []const u8) !void {
    const python_abi = try lifecycle.discoverPythonAbi(init, python);
    var plans = [_]lifecycle.Plan{
        lifecycle.developmentPlan(0, 1, python_abi),
        lifecycle.developmentPlan(1, 1, python_abi),
        lifecycle.developmentPlan(2, 1, python_abi),
        lifecycle.developmentPlan(3, 1, python_abi),
    };
    plans[1].output_slots = 2;

    var host0 = try startDataHost(
        init,
        python,
        script,
        plans[0],
        "strategy-fault",
        bridge,
        0x1001,
        0x2001,
        7,
        0xa001,
        1,
    );
    defer host0.deinit(init.io);
    var host1 = try startDataHost(
        init,
        python,
        script,
        plans[1],
        "trade",
        bridge,
        0x1101,
        0x2101,
        7,
        0,
        1,
    );
    defer host1.deinit(init.io);
    var host2 = try lifecycle.ManagedHost.start(init, python, script, plans[2], "crash", &.{});
    defer host2.deinit(init.io);
    var host3 = try startDataHost(
        init,
        python,
        script,
        plans[3],
        "trade",
        bridge,
        0x1301,
        0x2301,
        7,
        0,
        2,
    );
    defer host3.deinit(init.io);

    for ([_]*lifecycle.ManagedHost{ &host0, &host1, &host2, &host3 }) |host|
        try host.sendPlan(init.io);
    try handshake(&host0, init.io, 1, true);
    try handshake(&host1, init.io, 1, true);
    try handshake(&host2, init.io, 1, false);
    try handshake(&host3, init.io, 1, true);

    try runStrategyFault(init, &host0, plans[0]);
    try runOutputFull(&host1, plans[1], init.io);
    const old_host1_input = host1.input_mapping.raw;
    const old_host1_output = host1.output_mapping.raw;

    const crash_term = try host2.child.wait(init.io);
    host2.supervisor.processExited(switch (crash_term) {
        .exited => |code| code == 0,
        else => false,
    });
    try std.testing.expectEqual(lifecycle.State.failed, host2.supervisor.state);
    const old_host2_input = host2.input_mapping.raw;
    const old_host2_output = host2.output_mapping.raw;

    const healthy = try beginHealthyTrade(&host3, plans[3], init.io, 1, 1);

    var replacement_plan = lifecycle.developmentPlan(2, 2, python_abi);
    var replacement = try lifecycle.ManagedHost.start(
        init,
        python,
        script,
        replacement_plan,
        "normal",
        &.{},
    );
    defer replacement.deinit(init.io);
    try std.testing.expect(replacement.input_mapping.raw != old_host2_input);
    try std.testing.expect(replacement.output_mapping.raw != old_host2_output);
    try replacement.sendPlan(init.io);
    try handshake(&replacement, init.io, 10, true);
    try replacement.shutdown(init.io, 12);

    replacement_plan.session.generation = 3;
    var hung = try lifecycle.ManagedHost.start(
        init,
        python,
        script,
        replacement_plan,
        "hang",
        &.{},
    );
    defer hung.deinit(init.io);
    try hung.sendPlan(init.io);
    try handshake(&hung, init.io, 20, true);
    try std.testing.expectEqual(
        lifecycle.Result.timed_out,
        hung.supervisor.poll(21 + hung.supervisor.plan.hang_timeout_ns + 1),
    );
    hung.child.kill(init.io);

    try finishHealthyTrade(&host3, healthy, init.io, 2, 2);
    try host3.shutdown(init.io, 30);

    const invalid_plan = lifecycle.developmentPlan(1, 2, python_abi);
    var invalid_host = try startDataHost(
        init,
        python,
        script,
        invalid_plan,
        "trade",
        bridge,
        0x1101,
        0x2102,
        7,
        0,
        1,
    );
    defer invalid_host.deinit(init.io);
    try std.testing.expect(invalid_host.input_mapping.raw != old_host1_input);
    try std.testing.expect(invalid_host.output_mapping.raw != old_host1_output);
    try invalid_host.sendPlan(init.io);
    try handshake(&invalid_host, init.io, 40, true);
    try sendUnknownSchema(&invalid_host, invalid_plan, init.io);
    try std.testing.expectEqual(
        lifecycle.Result.accepted,
        try invalid_host.receive(init.io, 42),
    );
    try std.testing.expectEqual(lifecycle.State.failed, invalid_host.supervisor.state);
    try std.testing.expectEqual(@as(u16, 2), invalid_host.supervisor.recovery_required.?.reason);
    const invalid_term = try invalid_host.child.wait(init.io);
    switch (invalid_term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 24), code),
        else => return error.InvalidHostDidNotExit,
    }
}

fn runStrategyFault(init: std.process.Init, host: *lifecycle.ManagedHost, plan: lifecycle.Plan) !void {
    const authorization: gateway_module.Authorization = .{
        .strategy_identity = 0x1001,
        .config_version = 7,
        .activation_identity = 0x2001,
        .activation_barrier = 5,
    };
    const config = gatewayConfig(plan, authorization);
    const metadata: recovery_module.Metadata = .{
        .schema_registry = config.schema_registry,
        .strategy_instance = authorization.strategy_identity,
        .strategy_definition = 0x3001,
        .state_schema = 0x4001,
        .state_schema_version = 1,
        .strategy_config_version = 7,
        .strategy_cursor = 2,
        .next_intent_sequence = 5,
    };
    var checkpoint_storage: [512]u8 = undefined;
    const checkpoint = try recovery_module.encodeCheckpoint(
        &checkpoint_storage,
        metadata,
        .{ .accumulator = 30, .event_count = 2 },
    );
    var control_storage: [1024]u8 = undefined;
    try host.beginRecovery(init.io, 5, checkpoint, &control_storage);

    const subscriptions = [_]gateway_module.Subscription{
        gateway_module.Subscription.of(authorization.strategy_identity, &.{.timer}),
    };
    var gateway = try gateway_module.Gateway.init(config, &subscriptions);
    gateway.beginRecovery();
    var input = try host.input_mapping.ring(.input, plan.session);
    const output = try host.output_mapping.ring(.output, plan.session);
    const now = monotonicNow(init.io);
    const replay_payloads = [_][9]u8{
        eventPayload(30, false),
        eventPayload(40, true),
        eventPayload(50, false),
    };
    const replay_events = [_]gateway_module.EventEnvelope{
        event(3, now, &replay_payloads[0]),
        event(4, now, &replay_payloads[1]),
        event(5, now, &replay_payloads[2]),
    };
    var batch_storage: [1024]u8 = undefined;
    const replay_batch = try gateway.encodeBatch(&batch_storage, 1, 3, 5, now, &replay_events);
    try expectIpc(.ok, input.tryPublishMany(&.{replay_batch}));
    try gateway.recordPublished(1, 5, now);
    try std.testing.expectEqual(lifecycle.Result.accepted, try host.receive(init.io, now + 1));
    const recovered = host.supervisor.last_recovered orelse return error.MissingRecovery;
    try gateway.activate(authorization);
    try host.activate(init.io, .{
        .strategy_identity = authorization.strategy_identity,
        .activation_identity = authorization.activation_identity,
        .barrier = 5,
        .state_digest = recovered.state_digest,
    });

    const active_now = monotonicNow(init.io);
    const active_payload = eventPayload(60, true);
    const active_events = [_]gateway_module.EventEnvelope{
        event(6, active_now, &active_payload),
    };
    const active_batch = try gateway.encodeBatch(
        &batch_storage,
        2,
        6,
        6,
        active_now,
        &active_events,
    );
    try expectIpc(.ok, input.tryPublishMany(&.{active_batch}));
    try gateway.recordPublished(2, 6, active_now);
    try std.testing.expectEqual(
        lifecycle.Result.accepted,
        try host.receive(init.io, active_now + 1),
    );
    const fault = host.supervisor.last_fault orelse return error.MissingStrategyFault;
    try std.testing.expectEqual(@as(u128, 0xa001), fault.strategy_identity);
    try std.testing.expectEqual(@as(u64, 5), fault.last_valid_cursor);
    try std.testing.expectEqual(lifecycle.State.active, host.supervisor.state);

    var output_storage: [512]u8 = undefined;
    const frame = try readOutput(output, init.io, &output_storage);
    const decision = gateway.ingest(frame, monotonicNow(init.io));
    if (decision != .accepted or decision.accepted.strategy_identity != 0x1001 or
        decision.accepted.strategy_cursor != 6)
        return error.HealthyStrategyWasNotIsolated;
    try expectIpc(.empty, output.tryRead(&output_storage));
    try host.shutdown(init.io, active_now + 2);
}

fn runOutputFull(host: *lifecycle.ManagedHost, plan: lifecycle.Plan, io: std.Io) !void {
    const authorization: gateway_module.Authorization = .{
        .strategy_identity = 0x1101,
        .config_version = 7,
        .activation_identity = 0x2101,
        .activation_barrier = 0,
    };
    const config = gatewayConfig(plan, authorization);
    const subscriptions = [_]gateway_module.Subscription{
        gateway_module.Subscription.of(authorization.strategy_identity, &.{.timer}),
    };
    var gateway = try gateway_module.Gateway.init(config, &subscriptions);
    const now = monotonicNow(io);
    const payload = eventPayload(1, true);
    const events = [_]gateway_module.EventEnvelope{event(1, now, &payload)};
    var batch_storage: [512]u8 = undefined;
    const batch = try gateway.encodeBatch(&batch_storage, 1, 1, 1, now, &events);
    try gateway.recordPublished(1, 1, now);
    var frame_a_storage: [256]u8 = undefined;
    var frame_b_storage: [256]u8 = undefined;
    const frame_a = try gateway_module.encodeOutputFrame(
        &frame_a_storage,
        config,
        1,
        1,
        50,
        100,
        50_100_000_000,
    );
    const frame_b = try gateway_module.encodeOutputFrame(
        &frame_b_storage,
        config,
        1,
        1,
        51,
        100,
        50_100_000_000,
    );
    var output = try host.output_mapping.ring(.output, plan.session);
    try expectIpc(.ok, output.tryPublishMany(&.{ frame_a, frame_b }));
    var input = try host.input_mapping.ring(.input, plan.session);
    try expectIpc(.ok, input.tryPublishMany(&.{batch}));
    try std.testing.expectEqual(lifecycle.Result.accepted, try host.receive(io, now + 1));
    try std.testing.expectEqual(lifecycle.State.failed, host.supervisor.state);
    try std.testing.expectEqual(@as(u16, 3), host.supervisor.recovery_required.?.reason);
    gateway.beginRecovery();
    var old_storage: [512]u8 = undefined;
    const old_frame = try readOutput(output, io, &old_storage);
    try std.testing.expectEqual(
        gateway_module.RejectReason.unauthorized,
        gateway.ingest(old_frame, now + 2).rejected.reason,
    );
    const term = try host.child.wait(io);
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 24), code),
        else => return error.OutputFullHostDidNotExit,
    }
    host.supervisor.processExited(false);

    var next_config = config;
    next_config.session.generation += 1;
    next_config.authorization.activation_identity += 1;
    next_config.authorization.activation_barrier = 1;
    try gateway.beginSession(next_config);
    const next_now = now + 3;
    const next_events = [_]gateway_module.EventEnvelope{event(2, next_now, &payload)};
    const next_batch = try gateway.encodeBatch(
        &batch_storage,
        1,
        2,
        2,
        next_now,
        &next_events,
    );
    _ = next_batch;
    try gateway.recordPublished(1, 2, next_now);
    try gateway.activate(next_config.authorization);
    const retried = try gateway_module.encodeOutputFrame(
        &frame_a_storage,
        next_config,
        1,
        2,
        50,
        100,
        50_100_000_000,
    );
    try std.testing.expect(gateway.ingest(retried, next_now + 1) == .accepted);
    try std.testing.expectEqual(
        gateway_module.RejectReason.duplicate_identity,
        gateway.ingest(retried, next_now + 2).rejected.reason,
    );
}

const HealthyTrade = struct {
    gateway: gateway_module.Gateway,
    plan: lifecycle.Plan,
};

fn beginHealthyTrade(
    host: *lifecycle.ManagedHost,
    plan: lifecycle.Plan,
    io: std.Io,
    batch_sequence: u64,
    shard_sequence: u64,
) !HealthyTrade {
    const authorization: gateway_module.Authorization = .{
        .strategy_identity = 0x1301,
        .config_version = 7,
        .activation_identity = 0x2301,
        .activation_barrier = 0,
    };
    var fixture: HealthyTrade = .{
        .gateway = try gateway_module.Gateway.init(
            gatewayConfig(plan, authorization),
            &.{gateway_module.Subscription.of(authorization.strategy_identity, &.{.timer})},
        ),
        .plan = plan,
    };
    try publishAndAccept(host, &fixture.gateway, plan, io, batch_sequence, shard_sequence);
    return fixture;
}

fn finishHealthyTrade(
    host: *lifecycle.ManagedHost,
    fixture: HealthyTrade,
    io: std.Io,
    batch_sequence: u64,
    shard_sequence: u64,
) !void {
    var mutable = fixture;
    try publishAndAccept(host, &mutable.gateway, mutable.plan, io, batch_sequence, shard_sequence);
}

fn publishAndAccept(
    host: *lifecycle.ManagedHost,
    gateway: *gateway_module.Gateway,
    plan: lifecycle.Plan,
    io: std.Io,
    batch_sequence: u64,
    shard_sequence: u64,
) !void {
    const now = monotonicNow(io);
    const payload = eventPayload(1, true);
    const events = [_]gateway_module.EventEnvelope{event(shard_sequence, now, &payload)};
    var batch_storage: [512]u8 = undefined;
    const batch = try gateway.encodeBatch(
        &batch_storage,
        batch_sequence,
        shard_sequence,
        shard_sequence,
        now,
        &events,
    );
    var input = try host.input_mapping.ring(.input, plan.session);
    try expectIpc(.ok, input.tryPublishMany(&.{batch}));
    try gateway.recordPublished(batch_sequence, shard_sequence, now);
    const output = try host.output_mapping.ring(.output, plan.session);
    var output_storage: [512]u8 = undefined;
    const frame = try readOutput(output, io, &output_storage);
    const decision = gateway.ingest(frame, monotonicNow(io));
    if (decision != .accepted or decision.accepted.strategy_cursor != shard_sequence)
        return error.HealthyHostDidNotAdvance;
}

fn sendUnknownSchema(host: *lifecycle.ManagedHost, plan: lifecycle.Plan, io: std.Io) !void {
    const authorization: gateway_module.Authorization = .{
        .strategy_identity = 0x1101,
        .config_version = 7,
        .activation_identity = 0x2102,
        .activation_barrier = 0,
    };
    var gateway = try gateway_module.Gateway.init(
        gatewayConfig(plan, authorization),
        &.{gateway_module.Subscription.of(authorization.strategy_identity, &.{.timer})},
    );
    const now = monotonicNow(io);
    const payload = eventPayload(1, true);
    const events = [_]gateway_module.EventEnvelope{event(1, now, &payload)};
    var batch_storage: [512]u8 = undefined;
    const batch = try gateway.encodeBatch(&batch_storage, 1, 1, 1, now, &events);
    put(u16, batch, 128 + 10, 2);
    put(u32, batch, 124, wireCrc(batch));
    var input = try host.input_mapping.ring(.input, plan.session);
    try expectIpc(.ok, input.tryPublishMany(&.{batch}));
}

fn startDataHost(
    init: std.process.Init,
    python: []const u8,
    script: []const u8,
    plan: lifecycle.Plan,
    mode: []const u8,
    bridge: []const u8,
    strategy: u128,
    activation: u128,
    config_version: u64,
    fault_strategy: u128,
    trade_batches: u32,
) !lifecycle.ManagedHost {
    var strategy_text: [48]u8 = undefined;
    var activation_text: [48]u8 = undefined;
    var config_text: [24]u8 = undefined;
    var fault_text: [48]u8 = undefined;
    var batches_text: [24]u8 = undefined;
    var args: [12][]const u8 = undefined;
    var len: usize = 0;
    const base = [_][]const u8{
        "--bridge",
        bridge,
        "--strategy-identity",
        try std.fmt.bufPrint(&strategy_text, "0x{x}", .{strategy}),
        "--activation-identity",
        try std.fmt.bufPrint(&activation_text, "0x{x}", .{activation}),
        "--config-version",
        try std.fmt.bufPrint(&config_text, "{d}", .{config_version}),
        "--trade-batches",
        try std.fmt.bufPrint(&batches_text, "{d}", .{trade_batches}),
    };
    @memcpy(args[0..base.len], &base);
    len = base.len;
    if (fault_strategy != 0) {
        args[len] = "--fault-strategy-identity";
        args[len + 1] = try std.fmt.bufPrint(&fault_text, "0x{x}", .{fault_strategy});
        len += 2;
    }
    return lifecycle.ManagedHost.start(init, python, script, plan, mode, args[0..len]);
}

fn handshake(
    host: *lifecycle.ManagedHost,
    io: std.Io,
    now: i64,
    expect_heartbeat: bool,
) !void {
    try std.testing.expectEqual(lifecycle.Result.accepted, try host.receive(io, now));
    if (expect_heartbeat)
        try std.testing.expectEqual(lifecycle.Result.accepted, try host.receive(io, now + 1));
}

fn gatewayConfig(
    plan: lifecycle.Plan,
    authorization: gateway_module.Authorization,
) gateway_module.Config {
    return .{
        .schema_registry = plan.compatibility.schema_registry,
        .decision_domain = plan.decision_domain,
        .session = plan.session,
        .authorization = authorization,
    };
}

fn readOutput(ring: anytype, io: std.Io, storage: []u8) ![]const u8 {
    const deadline = monotonicNow(io) + std.time.ns_per_s;
    while (true) {
        const status = ring.tryRead(storage);
        if (status == .ok) {
            const len = get(u32, storage, 12);
            if (len > storage.len) return error.InvalidOutputLength;
            return storage[0..len];
        }
        if (status != .empty) return error.OutputReadFailed;
        if (monotonicNow(io) > deadline) return error.OutputTimeout;
        std.Thread.yield() catch {};
    }
}

fn event(
    sequence: u64,
    now: i64,
    payload: *const [9]u8,
) gateway_module.EventEnvelope {
    return .{
        .event_type = .timer,
        .shard_sequence = sequence,
        .source_time_ns = now,
        .receive_time_ns = now,
        .monotonic_time_ns = now,
        .wall_time_utc_ns = now,
        .payload = payload,
    };
}

fn eventPayload(delta: i64, emits: bool) [9]u8 {
    var payload: [9]u8 = undefined;
    put(i64, &payload, 0, delta);
    payload[8] = @intFromBool(emits);
    return payload;
}

fn monotonicNow(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn wireCrc(bytes: []const u8) u32 {
    var crc = std.hash.crc.Crc32Iscsi.init();
    crc.update(bytes[0..124]);
    crc.update(bytes[128..]);
    return crc.final();
}

fn expectIpc(expected: ipc.QshStatusV1, actual: ipc.QshStatusV1) !void {
    if (expected != actual) return error.UnexpectedIpcStatus;
}

fn put(comptime T: type, destination: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, destination[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, source: []const u8, offset: usize) T {
    return std.mem.readInt(T, source[offset..][0..@sizeOf(T)], .little);
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const bridge = args.next() orelse return error.MissingBridgePath;
    const python = args.next() orelse "python";
    const script = args.next() orelse "python/strategy_host.py";
    if (args.next() != null) return error.UnknownArgument;
    try runCheck(init, python, script, bridge);
    var buffer: [320]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print(
        "strategy_host_failures: zig={s}, hosts=4, strategy_fault=isolated, crash=rebuilt, hang=killed, output_full=fenced, input_invalid=fenced, healthy_cursor=continuous, duplicate_intents=0\n",
        .{builtin.zig_version_string},
    );
    try stdout.interface.flush();
}
