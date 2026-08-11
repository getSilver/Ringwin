const std = @import("std");
const builtin = @import("builtin");
const gateway_module = @import("strategy_host_gateway.zig");
const ipc = @import("strategy_host_ipc.zig");
const lifecycle = @import("strategy_host_lifecycle.zig");
const recovery_module = @import("strategy_host_recovery.zig");

fn runCheck(init: std.process.Init, python: []const u8, script: []const u8, bridge: []const u8) !void {
    const python_abi = try lifecycle.discoverPythonAbi(init, python);
    const plan = lifecycle.developmentPlan(0, 41, python_abi);
    const authorization: gateway_module.Authorization = .{
        .strategy_identity = 0x1001,
        .config_version = 7,
        .activation_identity = 0x2002,
        .activation_barrier = 5,
    };
    const config: gateway_module.Config = .{
        .schema_registry = plan.compatibility.schema_registry,
        .decision_domain = plan.decision_domain,
        .session = plan.session,
        .authorization = authorization,
    };
    const metadata: recovery_module.Metadata = .{
        .schema_registry = config.schema_registry,
        .strategy_instance = authorization.strategy_identity,
        .strategy_definition = 0x3003,
        .state_schema = 0x4004,
        .state_schema_version = 1,
        .strategy_config_version = authorization.config_version,
        .strategy_cursor = 2,
        .next_intent_sequence = 5,
    };
    var checkpoint_storage: [512]u8 = undefined;
    const checkpoint = try recovery_module.encodeCheckpoint(&checkpoint_storage, metadata, .{
        .accumulator = 30,
        .event_count = 2,
    });

    var strategy_text: [48]u8 = undefined;
    var activation_text: [48]u8 = undefined;
    var config_text: [24]u8 = undefined;
    const extra_args = [_][]const u8{
        "--bridge",
        bridge,
        "--strategy-identity",
        try std.fmt.bufPrint(&strategy_text, "0x{x}", .{authorization.strategy_identity}),
        "--activation-identity",
        try std.fmt.bufPrint(&activation_text, "0x{x}", .{authorization.activation_identity}),
        "--config-version",
        try std.fmt.bufPrint(&config_text, "{d}", .{authorization.config_version}),
    };
    var host = try lifecycle.ManagedHost.start(
        init,
        python,
        script,
        plan,
        "recovery",
        &extra_args,
    );
    defer host.deinit(init.io);
    try host.sendPlan(init.io);
    try expectLifecycle(.accepted, try host.receive(init.io, 1));
    try expectLifecycle(.accepted, try host.receive(init.io, 2));

    var recovery_frame: [1024]u8 = undefined;
    try host.beginRecovery(init.io, 5, checkpoint, &recovery_frame);

    const subscriptions = [_]gateway_module.Subscription{
        gateway_module.Subscription.of(authorization.strategy_identity, &.{.timer}),
    };
    var gateway = try gateway_module.Gateway.init(config, &subscriptions);
    gateway.beginRecovery();
    const published_ns: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    const replay_payloads = [_][9]u8{
        eventPayload(30, false),
        eventPayload(40, true),
        eventPayload(50, false),
    };
    const replay_events = [_]gateway_module.EventEnvelope{
        event(3, published_ns, &replay_payloads[0]),
        event(4, published_ns, &replay_payloads[1]),
        event(5, published_ns, &replay_payloads[2]),
    };
    var replay_batch_storage: [1024]u8 = undefined;
    const replay_batch = try gateway.encodeBatch(
        &replay_batch_storage,
        1,
        3,
        5,
        published_ns,
        &replay_events,
    );
    var input_owner = try host.input_mapping.ring(.input, plan.session);
    try expectIpc(.ok, input_owner.tryPublishMany(&.{replay_batch}));
    try gateway.recordPublished(1, 5, published_ns);

    try expectLifecycle(.accepted, try host.receive(init.io, published_ns + 1));
    const recovered = host.supervisor.last_recovered orelse return error.MissingRecoveryEvidence;

    var reference = try recovery_module.Recovery.begin(checkpoint, metadata, 5);
    for (replay_events) |replay_event| {
        _ = try reference.apply(.{
            .sequence = replay_event.shard_sequence,
            .delta = get(i64, replay_event.payload, 0),
            .would_emit_intent = replay_event.payload[8] == 1,
        });
    }
    const expected = try reference.finishRecovery();
    if (recovered.strategy_identity != metadata.strategy_instance or
        recovered.config_version != metadata.strategy_config_version or
        recovered.state_schema_identity != metadata.state_schema or
        recovered.state_schema_version != metadata.state_schema_version or
        recovered.cursor != expected.cursor or
        recovered.next_intent_sequence != expected.next_intent_sequence or
        !std.mem.eql(u8, &recovered.state_digest, &expected.state_digest))
        return error.RecoveryEvidenceMismatch;

    var output_owner = try host.output_mapping.ring(.output, plan.session);
    var output_storage: [512]u8 = undefined;
    try expectIpc(.empty, output_owner.tryRead(&output_storage));
    var forbidden_storage: [256]u8 = undefined;
    const forbidden = try gateway_module.encodeOutputFrame(
        &forbidden_storage,
        config,
        1,
        5,
        expected.next_intent_sequence,
        100,
        50_100_000_000,
    );
    const forbidden_decision = gateway.ingest(forbidden, published_ns + 1);
    if (forbidden_decision != .rejected or
        forbidden_decision.rejected.reason != .unauthorized)
        return error.RecoveryIntentWasNotFenced;

    try reference.authorize(
        authorization.activation_identity,
        authorization.activation_barrier,
        expected.state_digest,
    );
    try gateway.activate(authorization);
    try host.activate(init.io, .{
        .strategy_identity = authorization.strategy_identity,
        .activation_identity = authorization.activation_identity,
        .barrier = authorization.activation_barrier,
        .state_digest = expected.state_digest,
    });

    const active_ns: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    const active_payload = eventPayload(60, true);
    const active_events = [_]gateway_module.EventEnvelope{
        event(6, active_ns, &active_payload),
    };
    var active_batch_storage: [512]u8 = undefined;
    const active_batch = try gateway.encodeBatch(
        &active_batch_storage,
        2,
        6,
        6,
        active_ns,
        &active_events,
    );
    try expectIpc(.ok, input_owner.tryPublishMany(&.{active_batch}));
    try gateway.recordPublished(2, 6, active_ns);

    const deadline = active_ns + std.time.ns_per_s;
    while (true) {
        const status = output_owner.tryRead(&output_storage);
        if (status == .ok) break;
        if (status != .empty) return error.OutputReadFailed;
        if (@as(i64, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds)) > deadline)
            return error.OutputTimeout;
        std.Thread.yield() catch {};
    }
    const output_len = get(u32, &output_storage, 12);
    const decision = gateway.ingest(
        output_storage[0..output_len],
        @intCast(std.Io.Clock.awake.now(init.io).nanoseconds),
    );
    if (decision != .accepted) return error.RecoveredIntentRejected;
    const expected_identity = (try reference.apply(.{
        .sequence = 6,
        .delta = 60,
        .would_emit_intent = true,
    })).?;
    try std.testing.expectEqual(expected_identity.sequence, decision.accepted.intent_sequence);
    try std.testing.expectEqual(expected_identity.strategy_instance, decision.accepted.strategy_identity);
    try std.testing.expectEqual(@as(u64, 6), decision.accepted.strategy_cursor);
    try host.shutdown(init.io, active_ns + 1);
}

fn event(
    sequence: u64,
    now_ns: i64,
    payload: *const [9]u8,
) gateway_module.EventEnvelope {
    return .{
        .event_type = .timer,
        .shard_sequence = sequence,
        .source_time_ns = now_ns,
        .receive_time_ns = now_ns,
        .monotonic_time_ns = now_ns,
        .wall_time_utc_ns = now_ns,
        .payload = payload,
    };
}

fn eventPayload(delta: i64, emits: bool) [9]u8 {
    var payload: [9]u8 = undefined;
    std.mem.writeInt(i64, payload[0..8], delta, .little);
    payload[8] = @intFromBool(emits);
    return payload;
}

fn expectLifecycle(expected: lifecycle.Result, actual: lifecycle.Result) !void {
    if (expected != actual) return error.UnexpectedLifecycleResult;
}

fn expectIpc(expected: ipc.QshStatusV1, actual: ipc.QshStatusV1) !void {
    if (expected != actual) return error.UnexpectedIpcStatus;
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
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print(
        "strategy_host_recovery: zig={s}, checkpoint=validated, replay=equivalent, pre_activation_intents=0, recovered_intent=stable\n",
        .{builtin.zig_version_string},
    );
    try stdout.interface.flush();
}
