const std = @import("std");
const builtin = @import("builtin");
const gateway_module = @import("../../strategy/strategy_host_gateway.zig");
const lifecycle = @import("../../strategy/strategy_host_lifecycle.zig");
const recovery_module = @import("../../strategy/strategy_host_recovery.zig");
const fixture = @import("../support/trading_shard_fixture.zig");

fn runCheck(init: std.process.Init, python: []const u8, script: []const u8) !void {
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
    try host.sendInput(init.io, replay_batch, published_ns);
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

    var output_storage: [512]u8 = undefined;
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
    var authority = try fixture.gatewayActivationFixtureForSession(authorization, plan.session);
    try gateway.activate(&authority.shard, &authority.decision_journal);
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
    try host.sendInput(init.io, active_batch, active_ns);
    try gateway.recordPublished(2, 6, active_ns);

    const output = try host.receiveOutput(init.io, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds), &output_storage);
    const decision = gateway.ingest(
        output,
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

fn get(comptime T: type, source: []const u8, offset: usize) T {
    return std.mem.readInt(T, source[offset..][0..@sizeOf(T)], .little);
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const python = args.next() orelse "python";
    const script = args.next() orelse "python/strategy_host.py";
    if (args.next() != null) return error.UnknownArgument;
    try runCheck(init, python, script);
    try runPortableCheckpoint(init, python, script);
    try runRealCheckpoint(init, python);
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print(
        "strategy_host_recovery: zig={s}, checkpoint=validated, replay=equivalent, pre_activation_intents=0, recovered_intent=stable\n",
        .{builtin.zig_version_string},
    );
    try stdout.interface.writeAll("cross_venue_checkpoint: host=validated, file_reopen=exact, model_replay=not_run, trading_authority=false\n");
    try stdout.interface.writeAll("real_strategy_checkpoint: schema=2, model_replay=exact, published_cut=7, barrier=14, file_reopen=exact, intent_sequence=5, trading_authority=false\n");
    try stdout.interface.flush();
}

fn runPortableCheckpoint(init: std.process.Init, python: []const u8, script: []const u8) !void {
    const plan = lifecycle.developmentPlan(0, 42, try lifecycle.discoverPythonAbi(init, python));
    const metadata: recovery_module.Metadata = .{
        .schema_registry = plan.compatibility.schema_registry,
        .strategy_instance = 1,
        .strategy_definition = 2,
        .state_schema = 0x43565354415445000000000000000001,
        .state_schema_version = 1,
        .strategy_config_version = 1,
        .strategy_cursor = 10,
        .next_intent_sequence = 3,
    };
    const payload = @embedFile("../fixtures/cross_venue_state_v1.json");
    const storage = try init.gpa.alloc(u8, 8192);
    defer init.gpa.free(storage);
    const checkpoint = try recovery_module.encodePayloadCheckpoint(storage, metadata, payload);
    var host = try lifecycle.ManagedHost.start(init, python, script, plan, "portable", &.{ "--strategy-identity", "1", "--config-version", "1" });
    defer host.deinit(init.io);
    try host.sendPlan(init.io);
    try expectLifecycle(.accepted, try host.receive(init.io, 1));
    try expectLifecycle(.accepted, try host.receive(init.io, 2));
    var frame: [8192]u8 = undefined;
    try host.beginRecovery(init.io, 10, checkpoint, &frame);
    try expectLifecycle(.accepted, try host.receive(init.io, 3));
    try host.requestCheckpoint(init.io, 1, metadata);
    const returned = try host.receiveCheckpoint(init.io, &frame);
    try std.testing.expectEqualSlices(u8, checkpoint, returned);
    try checkPortableFile(init, python, script, returned, metadata, null);
    try std.testing.expectEqual(lifecycle.State.recovered, host.supervisor.state);
    try std.testing.expectError(error.StaleCheckpointRequest, host.requestCheckpoint(init.io, 1, metadata));
    try host.shutdown(init.io, 4);
}

const Continuation = struct {
    events: []const gateway_module.EventEnvelope,
    metadata: recovery_module.Metadata,
    checkpoint: []const u8,
};

fn checkPortableFile(init: std.process.Init, python: []const u8, script: []const u8, checkpoint: []const u8, metadata: recovery_module.Metadata, continuation: ?Continuation) !void {
    const durable = @import("../../persistence/durable_store.zig");
    const checkpoints = @import("../../strategy/strategy_checkpoint_store.zig");
    var cwd_buffer: [1024]u8 = undefined;
    const cwd = cwd_buffer[0..try std.Io.Dir.cwd().realPath(init.io, &cwd_buffer)];
    var path_buffer: [2048]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/.scratch/build/task08-store-{d}", .{ cwd, std.Io.Clock.real.now(init.io).nanoseconds });
    const adapter = try init.gpa.create(durable.LinuxFileAdapter);
    defer init.gpa.destroy(adapter);
    adapter.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try adapter.initWindowsVerification(init.io, path) else try adapter.initLinux(init.io, path);
    var opened = true;
    defer if (opened) adapter.close(init.io);
    const repository = try checkpoints.Repository.init(adapter.interface(), 800, .{ 801, 802 });
    try repository.initialize(init.io);
    const publication = try repository.publish(init.io, checkpoint, metadata);
    try std.testing.expectEqual(@as(u64, 2), publication.sequence);
    adapter.close(init.io);
    opened = false;
    adapter.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try adapter.initWindowsVerification(init.io, path) else try adapter.initLinux(init.io, path);
    opened = true;
    const reopened = try checkpoints.Repository.init(adapter.interface(), 800, .{ 801, 802 });
    const restored = try reopened.restore(init.io, metadata);
    try std.testing.expectEqualSlices(u8, checkpoint, restored);
    var wrong = metadata;
    wrong.strategy_config_version += 1;
    try std.testing.expectError(error.CheckpointMismatch, reopened.restore(init.io, wrong));
    // A complete new content object without a committed catalog reference must
    // never replace the previously published checkpoint during reopen.
    const original = try recovery_module.decodePayloadCheckpoint(checkpoint, metadata);
    var next_metadata = metadata;
    next_metadata.strategy_cursor += 1;
    var next_storage: [8192]u8 = undefined;
    const next = try recovery_module.encodePayloadCheckpoint(&next_storage, next_metadata, original.payload);
    adapter.injectFaultAfter(.eio, .append, 1);
    try std.testing.expectError(error.InputOutput, reopened.publish(init.io, next, next_metadata));
    adapter.close(init.io);
    opened = false;
    adapter.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try adapter.initWindowsVerification(init.io, path) else try adapter.initLinux(init.io, path);
    opened = true;
    const after_fault = try checkpoints.Repository.init(adapter.interface(), 800, .{ 801, 802 });
    try std.testing.expectEqualDeep(publication, (try after_fault.latest(init.io)).?);
    const restored_content = try after_fault.restore(init.io, metadata);
    try std.testing.expectEqualSlices(u8, checkpoint, restored_content);
    var next_plan = lifecycle.developmentPlan(0, 43, try lifecycle.discoverPythonAbi(init, python));
    if (continuation != null) next_plan.input_capacity = 4096;
    var strategy_buffer: [48]u8 = undefined;
    const strategy_text = try std.fmt.bufPrint(&strategy_buffer, "{d}", .{metadata.strategy_instance});
    var next_host = try lifecycle.ManagedHost.start(init, python, script, next_plan, "portable", &.{ "--strategy-identity", strategy_text, "--config-version", "1" });
    defer next_host.deinit(init.io);
    try next_host.sendPlan(init.io);
    try expectLifecycle(.accepted, try next_host.receive(init.io, 1));
    try expectLifecycle(.accepted, try next_host.receive(init.io, 2));
    var recovery_frame: [8192]u8 = undefined;
    try next_host.beginRecovery(init.io, metadata.strategy_cursor, restored_content, &recovery_frame);
    try expectLifecycle(.accepted, try next_host.receive(init.io, 3));
    const restored_identity = try recovery_module.decodePayloadCheckpoint(checkpoint, metadata);
    try std.testing.expectEqualSlices(u8, &restored_identity.state_digest, &next_host.supervisor.last_recovered.?.state_digest);
    try next_host.requestCheckpoint(init.io, 1, metadata);
    try std.testing.expectEqualSlices(u8, checkpoint, try next_host.receiveCheckpoint(init.io, &recovery_frame));
    try std.testing.expectEqual(lifecycle.State.recovered, next_host.supervisor.state);
    if (continuation) |tail| {
        const now: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        var gateway = try realGateway(next_plan);
        var input: [4096]u8 = undefined;
        const batch = try gateway.encodeBatch(&input, 1, metadata.strategy_cursor + 1, tail.metadata.strategy_cursor, now, tail.events);
        try next_host.sendInput(init.io, batch, now);
        try next_host.requestCheckpoint(init.io, 2, tail.metadata);
        try std.testing.expectEqualSlices(u8, tail.checkpoint, try next_host.receiveCheckpoint(init.io, &recovery_frame));
        try std.testing.expectEqual(lifecycle.State.recovered, next_host.supervisor.state);
    }
    try next_host.shutdown(init.io, 4);
}

fn realGateway(plan: lifecycle.Plan) !gateway_module.Gateway {
    return gateway_module.Gateway.init(.{
        .schema_registry = plan.compatibility.schema_registry,
        .decision_domain = plan.decision_domain,
        .session = plan.session,
        .authorization = .{ .strategy_identity = 9, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 },
    }, &.{gateway_module.Subscription.of(9, &.{ .mark_price, .timer, .account })});
}

fn runRealCheckpoint(init: std.process.Init, python: []const u8) !void {
    const script = "python/test_arbitrage_host.py";
    var plan = lifecycle.developmentPlan(0, 44, try lifecycle.discoverPythonAbi(init, python));
    plan.input_capacity = 4096;
    const metadata: recovery_module.Metadata = .{
        .schema_registry = plan.compatibility.schema_registry,
        .strategy_instance = 9,
        .strategy_definition = 2,
        .state_schema = 0x43565354415445000000000000000001,
        .state_schema_version = 2,
        .strategy_config_version = 1,
        .strategy_cursor = 0,
        .next_intent_sequence = 1,
    };
    var initial_storage: [8192]u8 = undefined;
    const initial = try recovery_module.encodePayloadCheckpoint(&initial_storage, metadata, @embedFile("../fixtures/arbitrage_host_state_v2.json"));
    const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, @embedFile("../fixtures/arbitrage_host_inputs_v1.json"), .{});
    defer parsed.deinit();
    var payloads: [14][64]u8 = undefined;
    var events: [14]gateway_module.EventEnvelope = undefined;
    for (parsed.value.array.items, 0..) |row, i| {
        const values = row.array.items;
        const payload = try std.fmt.hexToBytes(&payloads[i], values[2].string);
        const sample = values[0].integer == 1;
        const sample_time: i64 = if (sample) @intCast(get(u64, payload, 0) * 1_000_000_000) else 0;
        events[i] = .{
            .event_type = @enumFromInt(values[0].integer),
            .time_presence = if (sample) 0x1f else 0,
            .shard_sequence = @intCast(values[1].integer),
            .source_time_ns = sample_time,
            .receive_time_ns = if (sample) sample_time + 1 else 0,
            .monotonic_time_ns = if (sample) sample_time + 2 else 0,
            .wall_time_utc_ns = sample_time,
            .payload = payload,
        };
    }
    var final_metadata = metadata;
    final_metadata.strategy_cursor = 14;
    final_metadata.next_intent_sequence = 5;
    var final_storage: [8192]u8 = undefined;
    for ([_]u64{ 14, 7 }, 0..) |barrier, index| {
        var current_plan = plan;
        current_plan.session.generation += index;
        var host = try lifecycle.ManagedHost.start(init, python, script, current_plan, "portable", &.{ "--strategy-identity", "9", "--config-version", "1" });
        defer host.deinit(init.io);
        try host.sendPlan(init.io);
        try expectLifecycle(.accepted, try host.receive(init.io, 1));
        try expectLifecycle(.accepted, try host.receive(init.io, 2));
        var frame: [8192]u8 = undefined;
        try host.beginRecovery(init.io, barrier, initial, &frame);
        var gateway = try realGateway(current_plan);
        var input: [4096]u8 = undefined;
        const now: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        const batch = try gateway.encodeBatch(&input, 1, 1, barrier, now, events[0..@intCast(barrier)]);
        try host.sendInput(init.io, batch, now);
        try expectLifecycle(.accepted, try host.receive(init.io, 3));
        var expected = metadata;
        expected.strategy_cursor = barrier;
        if (barrier == 14) expected.next_intent_sequence = 5;
        try host.requestCheckpoint(init.io, 1, expected);
        const checkpoint = try host.receiveCheckpoint(init.io, &frame);
        if (index == 0) {
            @memcpy(final_storage[0..checkpoint.len], checkpoint);
        } else {
            const final_len = get(u32, &final_storage, 12);
            try checkPortableFile(init, python, script, checkpoint, expected, .{
                .events = events[7..],
                .metadata = final_metadata,
                .checkpoint = final_storage[0..final_len],
            });
        }
        try std.testing.expectEqual(lifecycle.State.recovered, host.supervisor.state);
        try host.shutdown(init.io, 4);
    }
}
