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
    const selection = args.next();
    if (args.next() != null) return error.UnknownArgument;
    if (selection) |value| {
        if (std.mem.eql(u8, value, "--formal-dual-ioc-only"))
            return @import("production_dual_ioc_integration.zig").run(init, python, null);
        if (std.mem.eql(u8, value, "--routed-dual-ioc-only"))
            return @import("production_dual_ioc_integration.zig").run(init, python, script);
        if (std.mem.eql(u8, value, "--ioc-recovery-only"))
            return runCycleRecovery(init, python, .reconciling, .keep, .ioc_failure);
        if (!std.mem.eql(u8, value, "--public-depth-only")) return error.UnknownArgument;
        return runCycleRecovery(init, python, .holding, .keep, .public_depth);
    }
    try runCycleRecovery(init, python, .holding, .keep, .public_depth);
    try runCheck(init, python, script);
    try runPortableCheckpoint(init, python, script);
    try runRealCheckpoint(init, python);
    for (std.enums.values(CyclePhase)) |phase| try runCycleRecovery(init, python, phase, .keep, .normal);
    try runCycleRecovery(init, python, .holding, .migrate, .normal);
    try runCycleRecovery(init, python, .holding, .rebuild, .normal);
    try runCycleRecovery(init, python, .holding, .keep, .downtime);
    try runCycleRecovery(init, python, .holding, .keep, .loss);
    try runCycleRecovery(init, python, .reconciling, .keep, .maker);
    try runCycleRecovery(init, python, .exiting, .keep, .risk);
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print(
        "strategy_host_recovery: zig={s}, checkpoint=validated, replay=equivalent, pre_activation_intents=0, recovered_intent=stable\n",
        .{builtin.zig_version_string},
    );
    try stdout.interface.writeAll("cross_venue_checkpoint: host=validated, file_reopen=exact, model_replay=not_run, trading_authority=false\n");
    try stdout.interface.writeAll("real_strategy_checkpoint: schema=2, model_replay=exact, published_cut=7, barrier=14, file_reopen=exact, intent_sequence=5, trading_authority=false\n");
    try stdout.interface.writeAll("cycle_recovery: accounts=2, original_cycle=1, publication=file_reopen, activation=committed, old_session=fenced, opening_authority=false\n");
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

const CyclePhase = enum { entering, repairing, holding, exiting, reconciling };

const CycleTransition = enum { keep, migrate, rebuild };

const CycleScenario = enum { normal, downtime, loss, maker, risk, public_depth, ioc_failure };

// Offline canonical feed: protocol normalization is qualified separately by the OKX tests.
const ContractFeed = struct {
    pending: ?@import("../../model/canonical_event.zig").AdapterOutputBatch = null,
    fn adapter(self: *@This()) @import("../../market/market_feed_adapter.zig").MarketFeedAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_drain = drain, .stop = stop } };
    }
    fn start(_: *anyopaque, _: @import("../../market/market_feed_adapter.zig").Config) @import("../../market/market_feed_adapter.zig").StartError!void {}
    fn drain(ptr: *anyopaque) @import("../../market/market_feed_adapter.zig").DrainError!?@import("../../model/canonical_event.zig").AdapterOutputBatch {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const result = self.pending;
        self.pending = null;
        return result;
    }
    fn stop(_: *anyopaque, _: @import("../../market/market_feed_adapter.zig").DrainDeadline) @import("../../market/market_feed_adapter.zig").StopError!void {}
};

const PublicStart = struct {
    candidate: gateway_module.GroupCandidate,
    checkpoint: []u8,
    depth_wires: [2][@import("../../market/depth_snapshot.zig").wire_len]u8,
};

fn publicDepthStart(init: std.process.Init, python: []const u8, input: *CycleIngress, plan: lifecycle.Plan, fee_path: []const u8) !PublicStart {
    const canonical = @import("../../model/canonical_event.zig");
    const depth = @import("../../market/depth_snapshot.zig");
    const owner = input.owner;
    var events: [2]gateway_module.EventEnvelope = undefined;
    var wires: [2][depth.wire_len]u8 = undefined;
    for ([_]u128{ 101, 102 }, [_]u64{ 1, 21 }, 0..) |instrument, venue, index| {
        var feed: ContractFeed = .{};
        const adapter = feed.adapter();
        try adapter.start(.{ .venue = venue, .environment = .simulation, .subscription_set = 1, .config_version = 1, .session = 1, .output_capacity = 2 });
        defer adapter.stop(.{ .monotonic_ns = 0 }) catch {};
        const bid: i128 = if (index == 0) 100 else 109;
        var levels: canonical.BookDepth = .{ .visible_at_ns = 1_767_225_600_450_000_000, .bid_count = 1, .ask_count = 1 };
        levels.bids[0] = .{ .ticks = bid, .lots = 10000 };
        levels.asks[0] = .{ .ticks = bid + 1, .lots = 10000 };
        var record = fixture.canonicalAt(45, 2, .{ .l2_book_snapshot = .{
            .instrument = instrument,
            .sequence = 1_767_225_600_450_000_000,
            .depth = levels,
            .best_bid = .{ .instrument = instrument, .rules_version = 1, .ticks = bid },
            .best_ask = .{ .instrument = instrument, .rules_version = 1, .ticks = bid + 1 },
            .best_bid_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 10000 },
            .best_ask_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 10000 },
        } });
        record.venue.envelope.scope = .instrument;
        record.venue.envelope.times.receive_utc_ns = levels.visible_at_ns;
        record.venue.envelope.exchange_account = null;
        record.venue.envelope.instrument = instrument;
        record.venue.envelope.venue = venue;
        record.venue.envelope.identity.stream = 1000 + instrument;
        record.venue.envelope.source_stream = @intCast(1000 + instrument);
        var batch: canonical.AdapterOutputBatch = .{};
        try batch.append(record.venue);
        feed.pending = batch;
        const drained = (try adapter.tryDrain()).?;
        for (drained.events[0..drained.len]) |event_record| _ = try input.apply(.{ .venue = event_record });
        events[index] = try gateway_module.depthSnapshotInput(&owner.shard.canonical_market, instrument, owner.shard.authoritativeBarrier(), &wires[index], 0, 1_767_225_600_450_000_000);
    }
    var metadata: recovery_module.Metadata = .{
        .schema_registry = plan.compatibility.schema_registry,
        .strategy_instance = 9,
        .strategy_definition = 2,
        .state_schema = 0x43565354415445000000000000000001,
        .state_schema_version = 2,
        .strategy_config_version = 1,
        .strategy_cursor = 0,
        .next_intent_sequence = 1,
    };
    var frame: [8192]u8 = undefined;
    var initial_storage: [4096]u8 = undefined;
    const initial = try recovery_module.encodePayloadCheckpoint(&initial_storage, metadata, @embedFile("../fixtures/strategy_cycle_recovery_v2.json"));
    const fee_a = "{\"venue\":\"1\",\"account\":\"20\",\"product\":\"linear\",\"fee_asset\":\"1\",\"maker_percent\":\"0\",\"taker_percent\":\"0\"}";
    const fee_b = "{\"venue\":\"21\",\"account\":\"30\",\"product\":\"linear\",\"fee_asset\":\"1\",\"maker_percent\":\"0\",\"taker_percent\":\"0\"}";
    const revisions = [_][]const u8{
        "[" ++ fee_a ++ "," ++ fee_b ++ "]",
        "[" ++ fee_a ++ "]",
        "[" ++ fee_a ++ "," ++ fee_b ++ "]",
    };
    try publishFeeFixture(init.io, fee_path, revisions[0..1]);
    var host = try lifecycle.ManagedHost.start(init, python, "python/test_strategy_cycle_recovery.py", plan, "portable", &.{ "--core", "--strategy-identity", "9", "--activation-identity", "1", "--public-books", "--manual-fees", fee_path });
    defer host.deinit(init.io);
    try host.sendPlan(init.io);
    try expectLifecycle(.accepted, try host.receive(init.io, 1));
    try expectLifecycle(.accepted, try host.receive(init.io, 2));
    metadata.strategy_cursor = owner.shard.authoritativeBarrier();
    try host.beginRecovery(init.io, metadata.strategy_cursor, initial, &frame);
    var gateway = try gateway_module.Gateway.init(.{
        .schema_registry = plan.compatibility.schema_registry,
        .decision_domain = plan.decision_domain,
        .session = plan.session,
        .authorization = .{ .strategy_identity = 9, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 },
    }, &.{gateway_module.Subscription.of(9, &.{ .depth_snapshot, .timer })});
    var batch_storage: [4096]u8 = undefined;
    var now: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    try host.sendInput(init.io, try gateway.encodeBatch(&batch_storage, 1, 1, metadata.strategy_cursor, now, &events), now);
    try gateway.recordPublished(1, metadata.strategy_cursor, now);
    try expectLifecycle(.accepted, try host.receive(init.io, 3));
    try host.requestCheckpoint(init.io, 1, metadata);
    const before = try recovery_module.decodePayloadCheckpoint(try host.receiveCheckpoint(init.io, &frame), metadata);
    const activation: lifecycle.Activation = .{ .strategy_identity = 9, .activation_identity = 1, .barrier = metadata.strategy_cursor + 1, .state_digest = before.state_digest };
    _ = try input.apply(fixture.atGroup(45, .{ .identity = 9000, .payload = .{ .host_activated = .{
        .strategy_identity = 9,
        .config_version = 1,
        .activation_identity = 1,
        .session = plan.session,
        .activation_barrier = activation.barrier,
        .state_digest = owner.shard.canonicalStateDigest(),
    } } }));
    try host.activate(init.io, activation);
    gateway.config.authorization.activation_barrier = activation.barrier;
    now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    try host.sendInput(init.io, try gateway.encodeBatch(&batch_storage, 2, activation.barrier, activation.barrier, now, &.{}), now);
    try gateway.recordPublished(2, activation.barrier, now);
    try gateway.activate(&owner.shard, &owner.decision_journal);
    try publishFeeFixture(init.io, fee_path, revisions[0..2]);
    for ([_][]const u8{ "start-fees:1", "start-fees:2", "start-fees:3" }, 0..) |payload, index| {
        if (index == 2) try publishFeeFixture(init.io, fee_path, &revisions);
        _ = try input.apply(fixture.atGroup(45, .{ .identity = 9190 + index, .account_scope = 20, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } }));
        metadata.strategy_cursor = owner.shard.authoritativeBarrier();
        const start: gateway_module.EventEnvelope = .{ .event_type = .timer, .shard_sequence = metadata.strategy_cursor, .source_time_ns = 0, .receive_time_ns = 0, .monotonic_time_ns = 0, .wall_time_utc_ns = 0, .payload = payload };
        now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        try host.sendInput(init.io, try gateway.encodeBatch(&batch_storage, 3 + index, metadata.strategy_cursor, metadata.strategy_cursor, now, &.{start}), now);
        try gateway.recordPublished(3 + index, metadata.strategy_cursor, now);
        if (index < 2) {
            // A proposal would precede the checkpoint on the same pipe.
            try host.requestCheckpoint(init.io, 2 + index, metadata);
            _ = try recovery_module.decodePayloadCheckpoint(try host.receiveCheckpoint(init.io, &frame), metadata);
        }
    }
    const output = try host.receiveOutput(init.io, now, &frame);
    const decision = gateway.ingest(output, now + 1);
    try std.testing.expect(decision == .accepted_group);
    const group = try gateway_module.decodeIntentGroup(decision.accepted_group.frame());
    try std.testing.expectEqual(@as(u8, 2), group.count);
    try std.testing.expectEqual(@as(u128, 20), group.members[0].exchange_account_identity);
    try std.testing.expectEqual(@as(u128, 30), group.members[1].exchange_account_identity);
    metadata.next_intent_sequence = 3;
    try host.requestCheckpoint(init.io, 4, metadata);
    const saved = try init.gpa.dupe(u8, try host.receiveCheckpoint(init.io, &frame));
    std.debug.print("10 public depth: input_sha256={s}/{s} output=complete_group members=2 next_intent=3 start_cursor={d}\n", .{ std.fmt.bytesToHex(@import("../../persistence/business_history.zig").hash(&wires[0]), .lower), std.fmt.bytesToHex(@import("../../persistence/business_history.zig").hash(&wires[1]), .lower), metadata.strategy_cursor });
    return .{ .candidate = decision.accepted_group, .checkpoint = saved, .depth_wires = wires };
}

fn publishFeeFixture(io: std.Io, path: []const u8, revisions: []const []const u8) !void {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{{\"schema\":\"manual_fee_schedules_v1\",\"version\":\"{d}\",\"revisions\":[", .{revisions.len});
    for (revisions, 0..) |rows, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(rows);
    }
    try writer.writeAll("]}");
    // Delivery is synchronous. The child consumes this revision only after the next input.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = writer.buffered() });
}

fn runCycleRecovery(init: std.process.Init, python: []const u8, phase: CyclePhase, transition: CycleTransition, scenario: CycleScenario) !void {
    const expired = scenario == .downtime;
    const loss = scenario == .loss;
    const maker_mode = scenario == .maker;
    const ioc_failure = scenario == .ioc_failure;
    const durable = @import("../../persistence/durable_store.zig");
    const demo = @import("../../runtime/demo/demo_authority.zig");
    const multi = @import("../acceptance/core/multi_account_authority_acceptance.zig");
    const engine = @import("../../trading/trading_shard.zig");
    const recovery = @import("../../runtime/strategy_cycle_recovery.zig");
    const checkpoints = @import("../../strategy/strategy_checkpoint_store.zig");
    const execution = @import("../../execution/execution_gateway.zig");
    const script = "python/test_strategy_cycle_recovery.py";
    var path_buffer: [2048]u8 = undefined;
    var cwd_buffer: [1024]u8 = undefined;
    const cwd = cwd_buffer[0..try std.Io.Dir.cwd().realPath(init.io, &cwd_buffer)];
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/.scratch/build/task09b-store-{d}", .{ cwd, std.Io.Clock.real.now(init.io).nanoseconds });
    const adapter = try init.gpa.create(durable.LinuxFileAdapter);
    defer init.gpa.destroy(adapter);
    adapter.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try adapter.initWindowsVerification(init.io, path) else try adapter.initLinux(init.io, path);
    defer adapter.close(init.io);
    const owner = try init.gpa.create(demo.Owner);
    defer init.gpa.destroy(owner);
    try demo.Owner.bootstrapInto(owner, adapter.interface(), init.io, .{ .domain = .decision_log, .id = 91 });
    if (ioc_failure) try multi.initializePythonOwnerWithSettlement(owner, 3) else try multi.initializePythonOwner(owner);
    var input: CycleIngress = .{ .owner = owner, .sink = try @import("../../persistence/raw_ingress.zig").DurableSink.init(adapter.interface(), init.io, .{ .domain = .raw_ingress, .id = 93 }) };
    if (maker_mode) {
        const view = try init.gpa.create(engine.TradingShard);
        defer init.gpa.destroy(view);
        try owner.shard.copyAccountViewInto(view, 20);
        var profile = view.registryInstrument(101).?.capability.?;
        profile.version = 2;
        profile.supports_post_only = true;
        _ = try input.apply(fixture.atGroup(44, .{ .identity = 9090, .account_scope = 20, .payload = .{ .capability_profile_activation = profile } }));
    }
    var old_plan = lifecycle.developmentPlan(0, 70, try lifecycle.discoverPythonAbi(init, python));
    old_plan.session.fencing = owner.shard.fencing_token;
    old_plan.decision_domain = 1;
    if (scenario == .public_depth) old_plan.input_capacity = 4096;
    if (scenario != .public_depth) _ = try input.apply(fixture.atGroup(44, .{ .identity = 9000, .payload = .{ .host_activated = .{
        .strategy_identity = 9,
        .config_version = 1,
        .activation_identity = 1,
        .session = old_plan.session,
        .activation_barrier = owner.shard.authoritativeBarrier() + 1,
        .state_digest = owner.shard.canonicalStateDigest(),
    } } }));
    var fee_path_storage: [2048]u8 = undefined;
    const public_start = if (scenario == .public_depth) try publicDepthStart(init, python, &input, old_plan, try std.fmt.bufPrint(&fee_path_storage, "{s}/manual-fees.json", .{path})) else null;
    defer if (public_start) |started| init.gpa.free(started.checkpoint);
    const start_sequence = if (public_start != null) owner.shard.authoritativeBarrier() else owner.shard.authoritativeBarrier() + 1;
    if (public_start == null) _ = try input.apply(fixture.atGroup(45, .{ .identity = 9001, .account_scope = 20, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } }));
    var metadata: recovery_module.Metadata = .{
        .schema_registry = old_plan.compatibility.schema_registry,
        .strategy_instance = 9,
        .strategy_definition = 2,
        .state_schema = 0x43565354415445000000000000000001,
        .state_schema_version = 2,
        .strategy_config_version = 1,
        .strategy_cursor = 0,
        .next_intent_sequence = 1,
    };
    var initial_storage: [4096]u8 = undefined;
    const payload: []const u8 = if (maker_mode) @embedFile("../fixtures/strategy_maker_recovery_v2.json") else @embedFile("../fixtures/strategy_cycle_recovery_v2.json");
    const initial = try recovery_module.encodePayloadCheckpoint(&initial_storage, metadata, payload);
    const old_args: []const []const u8 = if (maker_mode) &.{ "--core", "--strategy-identity", "9", "--core-maker" } else &.{ "--core", "--strategy-identity", "9" };
    var old_host = try lifecycle.ManagedHost.start(init, python, script, old_plan, "portable", old_args);
    defer old_host.deinit(init.io);
    try old_host.sendPlan(init.io);
    try expectLifecycle(.accepted, try old_host.receive(init.io, 1));
    try expectLifecycle(.accepted, try old_host.receive(init.io, 2));
    var frame: [8192]u8 = undefined;
    metadata.strategy_cursor = owner.shard.authoritativeBarrier();
    try old_host.beginRecovery(init.io, metadata.strategy_cursor, initial, &frame);
    var old_gateway = try realGateway(old_plan);
    var batch_storage: [4096]u8 = undefined;
    var now: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    const start_event: gateway_module.EventEnvelope = .{ .event_type = .timer, .shard_sequence = start_sequence, .source_time_ns = 0, .receive_time_ns = 0, .monotonic_time_ns = 0, .wall_time_utc_ns = 0, .payload = if (scenario == .risk) "start-risk" else "start" };
    try old_host.sendInput(init.io, try old_gateway.encodeBatch(&batch_storage, 1, 1, metadata.strategy_cursor, now, &.{start_event}), now);
    try old_gateway.recordPublished(1, metadata.strategy_cursor, now);
    try expectLifecycle(.accepted, try old_host.receive(init.io, 3));
    metadata.next_intent_sequence = if (maker_mode) 2 else 3;
    try old_host.requestCheckpoint(init.io, 1, metadata);
    var old_content = try init.gpa.dupe(u8, try old_host.receiveCheckpoint(init.io, &frame));
    defer init.gpa.free(old_content);
    if (public_start) |started| try std.testing.expectEqualSlices(u8, old_content, started.checkpoint);
    const repository = try checkpoints.Repository.init(adapter.interface(), 800, .{ 801, 802 });
    try repository.initialize(init.io);

    var group: engine.oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 2 };
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, 0..) |account, instrument, index| group.members[index] = .{
        .intent_sequence = 1 + index,
        .strategy_instance = 9,
        .portfolio = 10,
        .exchange_account = account,
        .operation = .place,
        .instrument = instrument,
        .side = if (index == 0) .buy else .sell,
        .quantity = if (maker_mode and index == 1) 3000 else 10000,
        .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = if (index == 0) 100 else 110 },
        .order_type = if (maker_mode and index == 0) .post_only else .limit,
        .time_in_force = if (maker_mode and index == 0) .post_only else .immediate_or_cancel,
    };
    _ = try input.apply(fixture.atGroup(45, .{ .identity = 9002, .payload = if (public_start) |started| .{ .external_intent_group = started.candidate } else .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
    if (public_start != null or ioc_failure) {
        const dual = @import("../acceptance/core/dual_ioc_dispatch_acceptance.zig");
        var adapters = [_]dual.Adapter{ .{ .account = 20 }, .{ .account = 30, .result = if (ioc_failure) .backpressure else .accepted } };
        const dispatcher = try init.gpa.create(execution.Gateway);
        defer init.gpa.destroy(dispatcher);
        dispatcher.init();
        try dispatcher.bootstrapDurableDispatch(adapter.interface(), init.io, .{ .domain = .control, .id = 92 });
        for (&adapters, [_]u64{ 1, 21 }) |*target, venue| try dispatcher.add(.{
            .account = target.account,
            .adapter = target.interface(),
            .venue_identity = venue,
            .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 },
            .supported_products = execution.productMask(.isolated_linear),
        });
        try dispatcher.pinDeploymentDigest(owner.shard.deployment.header.?.expected_digest);
        try dual.observe(dispatcher, &owner.shard);
        const dispatch_now = owner.shard.oms.findCommand(1).?.authority.dispatch_deadline_monotonic_ns - std.time.ns_per_s;
        try std.testing.expectEqual(.accepted, try dispatcher.sendFromShard(&owner.shard, 1, dispatch_now));
        const second_result: @import("../../execution/venue_adapter.zig").SendResult = if (ioc_failure) .backpressure else .accepted;
        try std.testing.expectEqual(second_result, try dispatcher.sendFromShard(&owner.shard, 2, dispatch_now));
        for (adapters, [_]u128{ 101, 102 }, [_]i128{ 100, 110 }, 0..) |target, instrument, ticks, index| {
            try std.testing.expectEqual(@as(usize, 1), target.sends);
            const command = target.command.?;
            const order = owner.shard.oms.orderById(index + 1).?;
            try std.testing.expectEqual(target.account, command.exchange_account);
            try std.testing.expectEqual(instrument, command.instrument);
            try std.testing.expectEqual(order.id, command.orderIdentity());
            try std.testing.expectEqualDeep(order.client_order_id, command.client_order_id);
            try std.testing.expectEqual(@as(engine.canonical.OrderSide, if (index == 0) .buy else .sell), command.side);
            try std.testing.expectEqual(engine.canonical.TimeInForce.immediate_or_cancel, command.time_in_force);
            try std.testing.expectEqual(@as(i64, 10000), command.quantity.?.lots);
            const price = command.limit_price.?;
            try std.testing.expectEqual(@as(u64, 1), price.rules_version);
            try std.testing.expectEqual(ticks, price.ticks);
        }
    }
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, [_]u64{ 1, 21 }, 0..) |account, instrument, venue, index| {
        const order = owner.shard.oms.orderById(index + 1).?;
        var report = fixture.canonicalAt(46, 2, .{ .execution_report = .{
            .identity = 1,
            .order = order.id,
            .client_order_id = order.client_order_id,
            .instrument = instrument,
            .exchange_account = account,
            .revision = 1,
            .status = .accepted,
            .cumulative_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 0 },
            .remaining_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = order.quantity },
        } });
        report.venue.envelope.exchange_account = account;
        report.venue.envelope.venue = venue;
        _ = try input.apply(report);
    }
    if (phase != .entering) {
        for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, [_]u64{ 1, 21 }, 0..) |account, instrument, venue, index| {
            const order = owner.shard.oms.orderById(index + 1).?;
            const filled: i64 = if (maker_mode) (if (index == 0) 3000 else 0) else if (loss) (if (index == 0) 10000 else 5000) else if (phase == .repairing) (if (index == 0) 10000 else 6000) else if (phase == .reconciling and index == 1) 0 else 5000;
            var pending_fill: ?engine.CanonicalEvent = null;
            if (filled != 0) {
                var fill = fixture.canonicalAt(46, 3, .{ .fill = .{
                    .identity = 1,
                    .order = order.id,
                    .client_order_id = order.client_order_id,
                    .venue_order = try engine.canonical.VenueOrderRef.init(venue, "recover-original"),
                    .venue_trade = try engine.canonical.VenueTradeRef.init(venue, "recover-original-fill"),
                    .instrument = instrument,
                    .exchange_account = account,
                    .side = if (index == 0) .buy else .sell,
                    .quantity = .{ .instrument = instrument, .rules_version = 1, .lots = filled },
                    .price = .{ .instrument = instrument, .rules_version = 1, .ticks = if (index == 0) 100 else 110 },
                    .fee = .{ .asset = if (ioc_failure) 3 else 1, .atoms = if (ioc_failure) 5 else 0 },
                    .liquidity = .taker,
                    .venue_fill_time_utc_ns = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
                } });
                fill.venue.envelope.exchange_account = account;
                fill.venue.envelope.venue = venue;
                if (public_start != null or ioc_failure) pending_fill = fill else _ = try input.apply(fill);
            }
            var terminal = fixture.canonicalAt(46, 4, .{ .execution_report = .{
                .identity = 2,
                .order = order.id,
                .client_order_id = order.client_order_id,
                .instrument = instrument,
                .exchange_account = account,
                .revision = 1,
                .status = if (maker_mode or (phase == .reconciling and index == 1)) .accepted else .canceled,
                .cumulative_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = filled },
                .remaining_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = order.quantity - filled },
            } });
            terminal.venue.envelope.exchange_account = account;
            terminal.venue.envelope.venue = venue;
            if (public_start != null or ioc_failure) {
                terminal.venue.envelope.identity.sequence = 3;
                terminal.venue.envelope.source_sequence = 3;
            }
            _ = try input.apply(terminal);
            if (pending_fill) |*fill| {
                var before_fill: [176]u8 = undefined;
                try cycleProjection(owner, 1_767_225_600_460_000_000, &before_fill);
                try std.testing.expectEqual(@as(u64, 0), get(u64, &before_fill, 8 + 16 * index));
                try std.testing.expectEqual(@as(u64, 5000), get(u64, &before_fill, 16 + 16 * index));
                try std.testing.expectEqual(@as(u64, 2), get(u64, &before_fill, 64 + 8 * index));
                fill.venue.envelope.identity.sequence = 4;
                fill.venue.envelope.source_sequence = 4;
                _ = try input.apply(fill.*);
                fill.venue.envelope.identity.sequence = 5;
                fill.venue.envelope.source_sequence = 5;
                _ = try input.apply(fill.*);
                try cycleProjection(owner, 1_767_225_600_460_000_000, &before_fill);
                try std.testing.expectEqual(@as(u64, 5000), get(u64, &before_fill, 8 + 16 * index));
            }
        }
        if (phase == .reconciling and !maker_mode) {
            var dispatch: engine.oms.DispatchBatch = .{ .count = 1 };
            dispatch.items[0] = .{ .command_id = 2, .state = .unknown };
            _ = try input.apply(fixture.atGroup(46, .{ .identity = 9010, .account_scope = 30, .payload = .{ .oms_dispatch_batch = dispatch } }));
        }
        if (ioc_failure) try observeIocPosition(&input, 46, 6, 5000);
        const old_cursor = metadata.strategy_cursor;
        metadata.strategy_cursor = owner.shard.authoritativeBarrier();
        var before_projection: [176]u8 = undefined;
        const before_utc = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core.wall_time;
        try cycleProjection(owner, before_utc, &before_projection);
        if (loss or maker_mode) std.mem.writeInt(u64, before_projection[80..88], if (loss) 2 else 16, .little);
        const phase_event: gateway_module.EventEnvelope = .{ .event_type = .account, .time_presence = 0x11, .shard_sequence = metadata.strategy_cursor, .source_time_ns = @intCast(before_utc), .receive_time_ns = 0, .monotonic_time_ns = 0, .wall_time_utc_ns = @intCast(before_utc), .payload = &before_projection };
        now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        try old_host.sendInput(init.io, try old_gateway.encodeBatch(&batch_storage, 2, old_cursor + 1, metadata.strategy_cursor, now, &.{phase_event}), now);
        try old_gateway.recordPublished(2, metadata.strategy_cursor, now);
        if (loss or maker_mode) metadata.next_intent_sequence = if (loss) 4 else 3;
        try old_host.requestCheckpoint(init.io, 2, metadata);
        const updated_content = try init.gpa.dupe(u8, try old_host.receiveCheckpoint(init.io, &frame));
        init.gpa.free(old_content);
        old_content = updated_content;
        if (loss) {
            var reduction: engine.oms.IntentGroup = .{ .first_intent_sequence = 3, .count = 1 };
            reduction.members[0] = .{ .strategy_instance = 9, .intent_sequence = 3, .portfolio = 10, .exchange_account = 20, .instrument = 101, .operation = .place, .side = .sell, .portfolio_reduce_only = true, .quantity = 5000, .limit_price = .{ .instrument = 101, .rules_version = 1, .ticks = 90 }, .time_in_force = .immediate_or_cancel };
            _ = try input.apply(fixture.atGroup(46, .{ .identity = 9016, .payload = .{ .oms_intent_group = reduction } }));
            const reducing_order = owner.shard.oms.orderById(3).?;
            var trim_fill = fixture.canonicalAt(46, 5, .{ .fill = .{
                .identity = 2,
                .order = 3,
                .client_order_id = reducing_order.client_order_id,
                .venue_order = try engine.canonical.VenueOrderRef.init(1, "repair-trim"),
                .venue_trade = try engine.canonical.VenueTradeRef.init(1, "repair-trim-loss"),
                .instrument = 101,
                .exchange_account = 20,
                .side = .sell,
                .quantity = .{ .instrument = 101, .rules_version = 1, .lots = 5000 },
                .price = .{ .instrument = 101, .rules_version = 1, .ticks = 98 },
                .fee = .{ .asset = 1, .atoms = 0 },
                .liquidity = .taker,
                .venue_fill_time_utc_ns = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
            } });
            trim_fill.venue.envelope.exchange_account = 20;
            _ = try input.apply(trim_fill);
            var trim_report = fixture.canonicalAt(46, 6, .{ .execution_report = .{
                .identity = 3,
                .order = 3,
                .client_order_id = reducing_order.client_order_id,
                .instrument = 101,
                .exchange_account = 20,
                .revision = 1,
                .status = .filled,
                .cumulative_quantity = .{ .instrument = 101, .rules_version = 1, .lots = 5000 },
                .remaining_quantity = .{ .instrument = 101, .rules_version = 1, .lots = 0 },
            } });
            trim_report.venue.envelope.exchange_account = 20;
            _ = try input.apply(trim_report);
            try std.testing.expectEqual(@as(i128, -1), owner.shard.accountState(20).?.economic_projection.portfolioLayer(10).?.realized_pnl_atoms);
            const previous = metadata.strategy_cursor;
            metadata.strategy_cursor = owner.shard.authoritativeBarrier();
            try cycleProjection(owner, before_utc, &before_projection);
            var held_event = phase_event;
            held_event.shard_sequence = metadata.strategy_cursor;
            now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
            try old_host.sendInput(init.io, try old_gateway.encodeBatch(&batch_storage, 3, previous + 1, metadata.strategy_cursor, now, &.{held_event}), now);
            try old_gateway.recordPublished(3, metadata.strategy_cursor, now);
            try old_host.requestCheckpoint(init.io, 3, metadata);
            const held_content = try init.gpa.dupe(u8, try old_host.receiveCheckpoint(init.io, &frame));
            init.gpa.free(old_content);
            old_content = held_content;
        }
        if (maker_mode) {
            var dispatch: engine.oms.DispatchBatch = .{ .count = 1 };
            dispatch.items[0] = .{ .command_id = 2, .state = .unknown };
            _ = try input.apply(fixture.atGroup(46, .{ .identity = 9091, .account_scope = 30, .payload = .{ .oms_dispatch_batch = dispatch } }));
            _ = try input.apply(fixture.atGroup(46, .{ .identity = 9092, .payload = .{ .control_command = .{
                .command_identity = 9092,
                .content_hash = 9092,
                .target_identity = owner.shard.operational_state.target_identity,
                .expected_version = owner.shard.operational_state.version,
                .expires_at = std.math.maxInt(u64),
                .kind = .cancel_open_orders,
            } } }));
            const maker_order = owner.shard.oms.orderById(1).?;
            try std.testing.expectEqual(engine.oms.OrderState.pending_cancel, maker_order.state);
            var cancel_fill = fixture.canonicalAt(46, 5, .{ .fill = .{
                .identity = 2,
                .order = 1,
                .client_order_id = maker_order.client_order_id,
                .venue_order = try engine.canonical.VenueOrderRef.init(1, "maker-original"),
                .venue_trade = try engine.canonical.VenueTradeRef.init(1, "maker-cancel-fill"),
                .instrument = 101,
                .exchange_account = 20,
                .side = .buy,
                .quantity = .{ .instrument = 101, .rules_version = 1, .lots = 2000 },
                .price = .{ .instrument = 101, .rules_version = 1, .ticks = 100 },
                .fee = .{ .asset = 1, .atoms = 0 },
                .liquidity = .maker,
                .venue_fill_time_utc_ns = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
            } });
            cancel_fill.venue.envelope.exchange_account = 20;
            _ = try input.apply(cancel_fill);
            var cancel_report = fixture.canonicalAt(46, 6, .{ .execution_report = .{
                .identity = 3,
                .order = 1,
                .client_order_id = maker_order.client_order_id,
                .instrument = 101,
                .exchange_account = 20,
                .revision = 1,
                .status = .partially_filled,
                .cumulative_quantity = .{ .instrument = 101, .rules_version = 1, .lots = 5000 },
                .remaining_quantity = .{ .instrument = 101, .rules_version = 1, .lots = 5000 },
            } });
            cancel_report.venue.envelope.exchange_account = 20;
            _ = try input.apply(cancel_report);
            const previous = metadata.strategy_cursor;
            metadata.strategy_cursor = owner.shard.authoritativeBarrier();
            try cycleProjection(owner, before_utc, &before_projection);
            var unknown_event = phase_event;
            unknown_event.shard_sequence = metadata.strategy_cursor;
            now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
            try old_host.sendInput(init.io, try old_gateway.encodeBatch(&batch_storage, 3, previous + 1, metadata.strategy_cursor, now, &.{unknown_event}), now);
            try old_gateway.recordPublished(3, metadata.strategy_cursor, now);
            try old_host.requestCheckpoint(init.io, 3, metadata);
            const unknown_content = try init.gpa.dupe(u8, try old_host.receiveCheckpoint(init.io, &frame));
            init.gpa.free(old_content);
            old_content = unknown_content;
        }
        if ((phase == .exiting or phase == .reconciling) and !maker_mode) {
            _ = try input.apply(fixture.atGroup(46, .{ .identity = 9011, .payload = .{ .safety_gate_change = .{
                .gate_identity = 9011,
                .target_identity = owner.shard.operational_state.target_identity,
                .kind = .latched,
                .reason = .margin_kill,
                .open = false,
            } } }));
            const previous = metadata.strategy_cursor;
            metadata.strategy_cursor = owner.shard.authoritativeBarrier();
            try cycleProjection(owner, before_utc, &before_projection);
            var risk_event = phase_event;
            risk_event.shard_sequence = metadata.strategy_cursor;
            now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
            try old_host.sendInput(init.io, try old_gateway.encodeBatch(&batch_storage, 3, previous + 1, metadata.strategy_cursor, now, &.{risk_event}), now);
            try old_gateway.recordPublished(3, metadata.strategy_cursor, now);
            try old_host.requestCheckpoint(init.io, 3, metadata);
            const risk_content = try init.gpa.dupe(u8, try old_host.receiveCheckpoint(init.io, &frame));
            init.gpa.free(old_content);
            old_content = risk_content;
        }
    }
    const old_decoded = try recovery_module.decodePayloadCheckpoint(old_content, metadata);
    const old_json = try std.json.parseFromSlice(std.json.Value, init.gpa, old_decoded.payload, .{ .allocate = .alloc_always });
    defer old_json.deinit();
    const old_phase = (try privateComponent(old_json.value, "cycle")).object.get("state").?.object.get("phase").?.string;
    try std.testing.expectEqualStrings(@tagName(phase), old_phase);
    if (transition != .keep) {
        const encoded = try init.gpa.alloc(u8, std.base64.standard.Encoder.calcSize(old_content.len));
        defer init.gpa.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, old_content);
        const converted = try std.process.run(init.gpa, init.io, .{ .argv = &.{ python, script, "--convert", @tagName(transition), encoded } });
        defer init.gpa.free(converted.stdout);
        defer init.gpa.free(converted.stderr);
        if (converted.term != .exited or converted.term.exited != 0) {
            std.debug.print("transition failed: {s}\n", .{converted.stderr});
            return error.PythonFailed;
        }
        const migrated_content = try init.gpa.dupe(u8, converted.stdout);
        init.gpa.free(old_content);
        old_content = migrated_content;
        metadata.strategy_definition = 3;
    }
    _ = try repository.publish(init.io, old_content, metadata);
    var old_batch_number: u64 = if (phase == .entering) 1 else if (phase == .exiting or phase == .reconciling or loss) 3 else 2;
    _ = try input.apply(fixture.atGroup(47, .{ .identity = 9003, .payload = .{ .control_command = .{
        .command_identity = 9003,
        .content_hash = 9003,
        .target_identity = owner.shard.operational_state.target_identity,
        .expected_version = owner.shard.operational_state.version,
        .expires_at = std.math.maxInt(u64),
        .kind = .trading_pause,
    } } }));
    try owner.checkpoint();
    const original_cycle = owner.shard.cycles.find(9, 1).?;
    const deployment_digest = owner.shard.deployment.header.?.expected_digest;
    const persisted_core_digest = owner.shard.canonicalStateDigest();
    adapter.close(init.io);
    adapter.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try adapter.initWindowsVerification(init.io, path) else try adapter.initLinux(init.io, path);
    try demo.Owner.recoverInto(owner, adapter.interface(), init.io, owner.stream);
    if (public_start) |started| {
        try std.testing.expectEqualSlices(u8, &persisted_core_digest, &owner.shard.canonicalStateDigest());
        for ([_]u128{ 101, 102 }, started.depth_wires) |instrument, wire| {
            var storage: [@import("../../market/depth_snapshot.zig").wire_len]u8 = undefined;
            const restored_depth = try gateway_module.depthSnapshotInput(&owner.shard.canonical_market, instrument, owner.shard.authoritativeBarrier(), &storage, 0, 0);
            try std.testing.expectEqualSlices(u8, &wire, restored_depth.payload);
        }
    }
    try owner.pinDeploymentDigest(deployment_digest);
    try std.testing.expectError(error.CoreRecoveryIncomplete, recovery.Recovery.begin(init.gpa, owner, 9, .{ .fencing = owner.shard.fencing_token, .shard = 0, .generation = 71 }));
    const recovered_digest = owner.shard.canonicalStateDigest();
    try input.replay();
    try std.testing.expectEqualSlices(u8, &recovered_digest, &owner.shard.canonicalStateDigest());
    _ = try input.apply(fixture.atGroup(48, .{ .identity = 9004, .account_scope = 20, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } }));
    var plan = old_plan;
    plan.session.generation += 1;
    const coordinator = try recovery.Recovery.begin(init.gpa, owner, 9, plan.session);
    defer coordinator.deinit();
    const execution_gateway = try init.gpa.create(execution.Gateway);
    defer init.gpa.destroy(execution_gateway);
    execution_gateway.init();
    if (ioc_failure) try execution_gateway.pinDeploymentDigest(deployment_digest);
    var recovered_adapters = [_]@import("../acceptance/core/dual_ioc_dispatch_acceptance.zig").Adapter{ .{ .account = 20 }, .{ .account = 30 } };
    if (public_start != null or ioc_failure) {
        for (&recovered_adapters, [_]u64{ 1, 21 }) |*target, venue| try execution_gateway.add(.{
            .account = target.account,
            .adapter = target.interface(),
            .venue_identity = venue,
            .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 },
            .supported_products = execution.productMask(.isolated_linear),
        });
    }
    if (public_start != null or ioc_failure) {
        try execution_gateway.attachRecoveredDurableDispatch(adapter.interface(), init.io, .{ .domain = .control, .id = 92 });
        try std.testing.expectEqual(@as(usize, if (ioc_failure) 1 else 2), execution_gateway.accepted_dispatch_count);
        try std.testing.expectEqual(@as(usize, if (ioc_failure) 1 else 0), execution_gateway.uncertain_dispatch_count);
        for (recovered_adapters) |target| try std.testing.expectEqual(@as(usize, 0), target.sends);
    } else try execution_gateway.bootstrapDurableDispatch(adapter.interface(), init.io, .{ .domain = .control, .id = 92 });
    for ([_]u128{ 20, 30 }) |account| try multi.reconcileDomainAccount(owner, account, execution_gateway);
    if (expired) _ = try input.apply(fixture.atGroup(2000, .{ .identity = 9012, .account_scope = 20, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } }));
    const reopened = try checkpoints.Repository.init(adapter.interface(), 800, .{ 801, 802 });
    const restored = try init.gpa.dupe(u8, try reopened.restore(init.io, metadata));
    defer init.gpa.free(restored);
    try std.testing.expectEqualSlices(u8, old_content, restored);
    const recovered_args: []const []const u8 = if (maker_mode) &.{ "--core", "--strategy-identity", "9", "--activation-identity", "2", "--core-maker" } else &.{ "--core", "--strategy-identity", "9", "--activation-identity", "2", "--core-definition", if (transition == .keep) "2" else "3" };
    var host = try lifecycle.ManagedHost.start(init, python, script, plan, "portable", recovered_args);
    defer host.deinit(init.io);
    try host.sendPlan(init.io);
    try expectLifecycle(.accepted, try host.receive(init.io, 1));
    try expectLifecycle(.accepted, try host.receive(init.io, 2));
    const first = metadata.strategy_cursor + 1;
    metadata.strategy_cursor = owner.shard.authoritativeBarrier();
    try host.beginRecovery(init.io, metadata.strategy_cursor, restored, &frame);
    const utc = try coordinator.currentUtc(owner);
    var projection: [176]u8 = undefined;
    try cycleProjection(owner, utc, &projection);
    const projected: gateway_module.EventEnvelope = .{ .event_type = .account, .time_presence = 0x11, .shard_sequence = metadata.strategy_cursor, .source_time_ns = @intCast(utc), .receive_time_ns = 0, .monotonic_time_ns = 0, .wall_time_utc_ns = @intCast(utc), .payload = &projection };
    var gateway = try realGateway(plan);
    now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    try host.sendInput(init.io, try gateway.encodeBatch(&batch_storage, 1, first, metadata.strategy_cursor, now, &.{projected}), now);
    try gateway.recordPublished(1, metadata.strategy_cursor, now);
    try expectLifecycle(.accepted, try host.receive(init.io, 3));
    try host.requestCheckpoint(init.io, 1, metadata);
    var resolved_owned: ?[]u8 = null;
    defer if (resolved_owned) |bytes| init.gpa.free(bytes);
    var content = try host.receiveCheckpoint(init.io, &frame);
    const retained_content = try init.gpa.dupe(u8, content);
    defer init.gpa.free(retained_content);
    old_batch_number += 1;
    now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    try old_host.sendInput(init.io, try old_gateway.encodeBatch(&batch_storage, old_batch_number, first, metadata.strategy_cursor, now, &.{projected}), now);
    try old_gateway.recordPublished(old_batch_number, metadata.strategy_cursor, now);
    var continuous_metadata = metadata;
    continuous_metadata.strategy_definition = 2;
    try old_host.requestCheckpoint(init.io, 4, continuous_metadata);
    const continuous = try old_host.receiveCheckpoint(init.io, &frame);
    const recovered_payload = (try recovery_module.decodePayloadCheckpoint(retained_content, metadata)).payload;
    const continuous_payload = (try recovery_module.decodePayloadCheckpoint(continuous, continuous_metadata)).payload;
    if (transition != .keep) {
        const recovered_json = try std.json.parseFromSlice(std.json.Value, init.gpa, recovered_payload, .{});
        defer recovered_json.deinit();
        const continuous_json = try std.json.parseFromSlice(std.json.Value, init.gpa, continuous_payload, .{});
        defer continuous_json.deinit();
        const recovered_cycle = try std.json.Stringify.valueAlloc(init.gpa, try privateComponent(recovered_json.value, "cycle"), .{});
        defer init.gpa.free(recovered_cycle);
        const continuous_cycle = try std.json.Stringify.valueAlloc(init.gpa, try privateComponent(continuous_json.value, "cycle"), .{});
        defer init.gpa.free(continuous_cycle);
        try std.testing.expectEqualSlices(u8, recovered_cycle, continuous_cycle);
        const recovered_filter = try privateComponent(recovered_json.value, "filter");
        const continuous_filter = try privateComponent(continuous_json.value, "filter");
        try std.testing.expect(!std.mem.eql(u8, recovered_filter.object.get("dependency").?.string, continuous_filter.object.get("dependency").?.string));
        if (transition == .migrate) {
            const recovered_model = try std.json.Stringify.valueAlloc(init.gpa, recovered_filter.object.get("state").?, .{});
            defer init.gpa.free(recovered_model);
            const continuous_model = try std.json.Stringify.valueAlloc(init.gpa, continuous_filter.object.get("state").?, .{});
            defer init.gpa.free(continuous_model);
            try std.testing.expectEqualSlices(u8, recovered_model, continuous_model);
        }
    } else try std.testing.expectEqualSlices(u8, recovered_payload, continuous_payload);
    content = retained_content;

    var dependency: [32]u8 = undefined;
    const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, payload, .{});
    defer parsed.deinit();
    _ = try std.fmt.hexToBytes(&dependency, (try privateComponent(parsed.value, "cycle")).object.get("dependency").?.string);
    var projection_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&projection, &projection_digest, .{});
    var binding: recovery.Binding = .{
        .component = "cycle",
        .legs = .{ .{ .account = 20, .instrument = 101, .direction = .buy, .rules_version = 1, .base_atomic_scale = 4 }, .{ .account = 30, .instrument = 102, .direction = .sell, .rules_version = 1, .base_atomic_scale = 4 } },
        .first_sequence = 1,
        .dependency = dependency,
        .group_digest = original_cycle.content_digest,
        .projection_digest = projection_digest,
        .holding_deadline_utc_ns = 1_767_225_610_450_000_000,
        .repair_deadline_utc_ns = 1_767_225_610_449_999_999,
        .exit_deadline_utc_ns = 1_767_225_610_450_001_000,
    };
    if (maker_mode) {
        try std.testing.expectError(error.UnresolvedRecoveryOrder, coordinator.qualify(init.gpa, owner, content, metadata, &.{binding}, .utc));
        try std.testing.expectError(error.RecoveryNotQualified, coordinator.activate(owner));
        const maker_json = try std.json.parseFromSlice(std.json.Value, init.gpa, (try recovery_module.decodePayloadCheckpoint(content, metadata)).payload, .{});
        defer maker_json.deinit();
        const state = (try privateComponent(maker_json.value, "cycle")).object.get("state").?.object;
        try std.testing.expect(state.get("cancel_requested").?.bool);
        try std.testing.expectEqual(@as(i64, 1), state.get("repair_used").?.integer);
        try std.testing.expectEqual(@as(i64, 3), state.get("next_sequence").?.integer);
        try std.testing.expectEqual(@as(i64, 1_767_225_600_450_000_000), state.get("quote_started_ns").?.object.get("value").?.integer);
        try std.testing.expectEqual(@as(i64, 5000), owner.shard.accountState(20).?.economic_projection.portfolioLayer(10).?.positionForInstrument(101).quantity);
        try std.testing.expectEqual(engine.oms.OrderState.pending_cancel, owner.shard.oms.orderById(1).?.state);
        try std.testing.expectEqual(engine.oms.OrderState.unknown, owner.shard.oms.orderById(2).?.state);
        try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
        try std.testing.expectEqual(@as(u128, 0), owner.shard.strategyAuthority(9).host_activation_identity);
        try old_host.shutdown(init.io, 4);
        try host.shutdown(init.io, 4);
        std.debug.print("09b maker cancel-fill + Unknown hedge: continuous == recovered, original identities, activation refused, no blind hedge; cut={d} recovery_barrier={d} projection_sha256={s} recovered_private_sha256={s}\n", .{ old_decoded.metadata.strategy_cursor, metadata.strategy_cursor, std.fmt.bytesToHex(binding.projection_digest, .lower), std.fmt.bytesToHex((try recovery_module.decodePayloadCheckpoint(content, metadata)).state_digest, .lower) });
        return;
    }
    if (phase == .reconciling) {
        try std.testing.expectError(error.UnresolvedRecoveryOrder, coordinator.qualify(init.gpa, owner, content, metadata, &.{binding}, .utc));
        try std.testing.expectError(error.RecoveryNotQualified, coordinator.activate(owner));
        if (ioc_failure) {
            try resolveIocRejection(&input, execution_gateway, &recovered_adapters[1]);
        } else {
            const order = owner.shard.oms.orderById(2).?;
            var resolved = fixture.canonicalAt(61, 5, .{ .execution_report = .{
                .identity = 3,
                .order = order.id,
                .client_order_id = order.client_order_id,
                .instrument = 102,
                .exchange_account = 30,
                .revision = 1,
                .status = .canceled,
                .cumulative_quantity = .{ .instrument = 102, .rules_version = 1, .lots = 0 },
                .remaining_quantity = .{ .instrument = 102, .rules_version = 1, .lots = 10000 },
            } });
            resolved.venue.envelope.exchange_account = 30;
            resolved.venue.envelope.venue = 21;
            _ = try input.apply(resolved);
        }
        const previous = metadata.strategy_cursor;
        metadata.strategy_cursor = owner.shard.authoritativeBarrier();
        const resolved_utc = try coordinator.currentUtc(owner);
        try cycleProjection(owner, resolved_utc, &projection);
        var resolved_event = projected;
        resolved_event.shard_sequence = metadata.strategy_cursor;
        resolved_event.source_time_ns = @intCast(resolved_utc);
        resolved_event.wall_time_utc_ns = @intCast(resolved_utc);
        now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        try host.sendInput(init.io, try gateway.encodeBatch(&batch_storage, 2, previous + 1, metadata.strategy_cursor, now, &.{resolved_event}), now);
        try gateway.recordPublished(2, metadata.strategy_cursor, now);
        try host.requestCheckpoint(init.io, 2, metadata);
        content = try host.receiveCheckpoint(init.io, &frame);
        const resolved_content = try init.gpa.dupe(u8, content);
        defer init.gpa.free(resolved_content);
        old_batch_number += 1;
        now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        try old_host.sendInput(init.io, try old_gateway.encodeBatch(&batch_storage, old_batch_number, previous + 1, metadata.strategy_cursor, now, &.{resolved_event}), now);
        try old_gateway.recordPublished(old_batch_number, metadata.strategy_cursor, now);
        try old_host.requestCheckpoint(init.io, 5, metadata);
        try std.testing.expectEqualSlices(u8, resolved_content, try old_host.receiveCheckpoint(init.io, &frame));
        resolved_owned = try init.gpa.dupe(u8, resolved_content);
        content = resolved_owned.?;

        std.crypto.hash.sha2.Sha256.hash(&projection, &binding.projection_digest, .{});
    }
    try std.testing.expectError(error.InvalidRecoveryQualification, coordinator.qualify(init.gpa, owner, content, metadata, &.{binding}, .unverified));
    try std.testing.expectError(error.InvalidCycleBindings, coordinator.qualify(init.gpa, owner, content, metadata, &.{ binding, binding }, .utc));
    var invalid_binding = binding;
    invalid_binding.dependency = @splat(0);
    try std.testing.expectError(error.FrozenPlanMismatch, coordinator.qualify(init.gpa, owner, content, metadata, &.{invalid_binding}, .utc));
    invalid_binding = binding;
    invalid_binding.projection_digest = @splat(1);
    try std.testing.expectError(error.EconomicProjectionMismatch, coordinator.qualify(init.gpa, owner, content, metadata, &.{invalid_binding}, .utc));
    const decoded_content = try recovery_module.decodePayloadCheckpoint(content, metadata);
    const linked_json = try std.json.parseFromSlice(std.json.Value, init.gpa, decoded_content.payload, .{});
    defer linked_json.deinit();
    const linked_budget = (try privateComponent(linked_json.value, "budget")).object.get("state").?.object;
    try std.testing.expectEqual(@as(i64, 2), linked_budget.get("evaluations_used").?.integer);
    try std.testing.expectEqual(@as(i64, 1_767_225_600_450_000_010), linked_budget.get("deadline_ns").?.object.get("value").?.integer);
    try std.testing.expectEqualStrings("none", linked_budget.get("opportunity").?.object.get("tag").?.string);
    const linked_signal = (try privateComponent(linked_json.value, "signal")).object.get("state").?.object;
    const original_signal = (try privateComponent(old_json.value, "signal")).object.get("state").?.object;
    const original_association = if (phase == .entering) original_signal.get("pending").? else original_signal.get("active").?;
    try std.testing.expectEqualStrings(original_association.object.get("value").?.string, linked_signal.get("active").?.object.get("value").?.string);
    try std.testing.expectEqualStrings("none", linked_signal.get("pending").?.object.get("tag").?.string);
    var daily_loss_preserved = false;
    for (linked_signal.get("reasons").?.array.items) |reason| {
        const key = reason.object.get("key").?.string;
        if (std.mem.eql(u8, key, "daily_loss")) daily_loss_preserved = true;
        try std.testing.expect(!std.mem.eql(u8, key, "restart"));
    }
    try std.testing.expectEqual(scenario == .risk, daily_loss_preserved);
    const linked_monitor = (try privateComponent(linked_json.value, "monitor")).object.get("state").?.object;
    try std.testing.expectEqualStrings(if (scenario == .risk) "InvalidLatched" else "Normal", linked_monitor.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 2), linked_monitor.get("sequences").?.array.items[0].object.get("value").?.integer);
    const linked_filter = (try privateComponent(linked_json.value, "filter")).object.get("state").?.object.get("_state").?.object;
    try std.testing.expectEqual(@as(i64, if (transition == .rebuild) 0 else 1), linked_filter.get("count").?.integer);

    if (expired) {
        const expired_json = try std.json.parseFromSlice(std.json.Value, init.gpa, decoded_content.payload, .{});
        defer expired_json.deinit();
        const state = (try privateComponent(expired_json.value, "cycle")).object.get("state").?.object;
        try std.testing.expectEqualStrings("exiting", state.get("phase").?.string);
        try std.testing.expectEqualStrings("deadline", state.get("first_exit").?.object.get("value").?.object.get("reason").?.string);
        try std.testing.expectEqual(@as(i64, 4), state.get("target_atoms").?.object.get("value").?.integer);
    }

    var invalid_metadata = metadata;
    invalid_metadata.next_intent_sequence = 1;
    var invalid_storage: [8192]u8 = undefined;
    const regressed = try recovery_module.encodePayloadCheckpoint(&invalid_storage, invalid_metadata, decoded_content.payload);
    try std.testing.expectError(error.IntentSequenceRegression, coordinator.qualify(init.gpa, owner, regressed, invalid_metadata, &.{binding}, .utc));
    const unadmitted_payload = try std.mem.replaceOwned(u8, init.gpa, decoded_content.payload, "\"sequence\":2", "\"sequence\":99");
    defer init.gpa.free(unadmitted_payload);
    invalid_metadata = metadata;
    invalid_metadata.next_intent_sequence = 100;
    const unadmitted_progress = try std.mem.replaceOwned(u8, init.gpa, unadmitted_payload, if (loss) "\"next_sequence\":4" else "\"next_sequence\":3", "\"next_sequence\":100");
    defer init.gpa.free(unadmitted_progress);
    const unadmitted = try recovery_module.encodePayloadCheckpoint(&invalid_storage, invalid_metadata, unadmitted_progress);
    try std.testing.expectError(error.UnresolvedPrivateIntent, coordinator.qualify(init.gpa, owner, unadmitted, invalid_metadata, &.{binding}, .utc));
    if (phase == .holding and !expired) {
        const unequal_payload = try std.mem.replaceOwned(u8, init.gpa, decoded_content.payload, "\"numerator\":5000", "\"numerator\":4000");
        defer init.gpa.free(unequal_payload);
        const unequal = try recovery_module.encodePayloadCheckpoint(&invalid_storage, metadata, unequal_payload);
        try std.testing.expectError(error.CycleEconomicMismatch, coordinator.qualify(init.gpa, owner, unequal, metadata, &.{binding}, .utc));
        invalid_binding = binding;
        invalid_binding.legs[0].base_atomic_scale = 255;
        try std.testing.expectError(error.DecimalRescaleOutOfRange, coordinator.qualify(init.gpa, owner, content, metadata, &.{invalid_binding}, .utc));
        invalid_binding.legs[0].base_atomic_scale = 38;
        try std.testing.expectError(error.Overflow, coordinator.qualify(init.gpa, owner, content, metadata, &.{invalid_binding}, .utc));
    }
    if (phase == .entering) {
        const invalid_phase = try std.mem.replaceOwned(u8, init.gpa, decoded_content.payload, "\"phase\":\"entering\"", "\"phase\":\"holding\"");
        defer init.gpa.free(invalid_phase);
        const false_holding = try recovery_module.encodePayloadCheckpoint(&invalid_storage, metadata, invalid_phase);
        try std.testing.expectError(error.CycleEconomicMismatch, coordinator.qualify(init.gpa, owner, false_holding, metadata, &.{binding}, .utc));
    }
    try std.testing.expectError(error.RecoveryNotQualified, coordinator.activate(owner));
    const qualification = try coordinator.qualify(init.gpa, owner, content, metadata, &.{binding}, .utc);
    const activation = try coordinator.activate(owner);
    try std.testing.expectEqual(@as(u128, 2), activation.activation_identity);
    try host.activate(init.io, activation);
    gateway.config.authorization = .{ .strategy_identity = 9, .config_version = 1, .activation_identity = activation.activation_identity, .activation_barrier = activation.barrier };
    now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    try host.sendInput(init.io, try gateway.encodeBatch(&batch_storage, if (phase == .reconciling) 3 else 2, activation.barrier, activation.barrier, now, &.{}), now);
    try gateway.recordPublished(if (phase == .reconciling) 3 else 2, activation.barrier, now);
    try gateway.activate(&owner.shard, &owner.decision_journal);
    metadata.strategy_cursor = activation.barrier;
    try host.requestCheckpoint(init.io, 3, metadata);
    _ = try host.receiveCheckpoint(init.io, &frame);
    try std.testing.expectEqualDeep(original_cycle, owner.shard.cycles.find(9, 1).?);
    try std.testing.expectEqual(@as(usize, if (loss) 3 else 2), owner.shard.oms.intent_history_count);
    try std.testing.expect(!owner.shard.operational_state.trading_authorized);
    if (ioc_failure) {
        _ = try input.apply(fixture.atGroup(62, .{ .identity = 9020, .account_scope = 20, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } }));
        const repair_cursor = owner.shard.authoritativeBarrier();
        const repair_utc = try coordinator.currentUtc(owner);
        try cycleProjection(owner, repair_utc, &projection);
        std.mem.writeInt(u64, projection[80..88], 2, .little);
        var repair_event = projected;
        repair_event.shard_sequence = repair_cursor;
        repair_event.source_time_ns = @intCast(repair_utc);
        repair_event.wall_time_utc_ns = @intCast(repair_utc);
        now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        try host.sendInput(init.io, try gateway.encodeBatch(&batch_storage, 4, activation.barrier + 1, repair_cursor, now, &.{repair_event}), now);
        try gateway.recordPublished(4, repair_cursor, now);
        var repair_wire: [1024]u8 = undefined;
        const decision = gateway.ingest(try host.receiveOutput(init.io, now, &repair_wire), now + 1);
        try std.testing.expect(decision == .accepted_group);
        const proposals = try gateway_module.decodeIntentGroup(decision.accepted_group.frame());
        try std.testing.expectEqual(@as(u8, 1), proposals.count);
        const repair = proposals.members[0];
        try std.testing.expectEqual(@as(u64, 3), repair.intent_sequence);
        try std.testing.expectEqual(@as(u128, 20), repair.exchange_account_identity);
        try std.testing.expectEqual(@as(i64, 5000), repair.quantity);
        try std.testing.expect(repair.portfolio_reduce_only);
        const intent = fixture.atGroup(62, .{ .identity = 9030, .payload = decision.corePayload() });
        _ = try input.apply(intent);
        _ = try input.apply(intent);
        try std.testing.expectEqual(@as(u16, 3), owner.shard.oms.order_count);
        try std.testing.expectEqualDeep(original_cycle, owner.shard.cycles.find(9, 1).?);
        metadata.strategy_cursor = owner.shard.authoritativeBarrier();
        metadata.next_intent_sequence += 1;
        try cycleProjection(owner, repair_utc, &projection);
        std.mem.writeInt(u64, projection[80..88], 2, .little);
        repair_event.shard_sequence = metadata.strategy_cursor;
        now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        try host.sendInput(init.io, try gateway.encodeBatch(&batch_storage, 5, repair_cursor + 1, metadata.strategy_cursor, now, &.{repair_event}), now);
        try gateway.recordPublished(5, metadata.strategy_cursor, now);
        try host.requestCheckpoint(init.io, 4, metadata);
        _ = try host.receiveCheckpoint(init.io, &frame);
        try finishIocRepair(init, python, adapter.dir, path, &input, execution_gateway, &recovered_adapters[0]);
    }
    if ((phase == .exiting and scenario != .risk) or loss) {
        const steps: usize = if (loss) 2 else 1;
        const original_order_count = owner.shard.oms.order_count;
        for (0..steps) |step| {
            _ = try input.apply(fixture.atGroup(61 + step, .{ .identity = 9020 + step, .account_scope = 20, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } }));
            const previous = metadata.strategy_cursor;
            metadata.strategy_cursor = owner.shard.authoritativeBarrier();
            const safe_utc = try coordinator.currentUtc(owner);
            try cycleProjection(owner, safe_utc, &projection);
            const flags = std.mem.readInt(u64, projection[80..88], .little) | 2 | (if (loss) @as(u64, if (step == 0) 4 else 8) else 0);
            std.mem.writeInt(u64, projection[80..88], flags, .little);
            const safe_event: gateway_module.EventEnvelope = .{ .event_type = .account, .time_presence = 0x11, .shard_sequence = metadata.strategy_cursor, .source_time_ns = @intCast(safe_utc), .receive_time_ns = 0, .monotonic_time_ns = 0, .wall_time_utc_ns = @intCast(safe_utc), .payload = &projection };
            now = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
            try host.sendInput(init.io, try gateway.encodeBatch(&batch_storage, 3 + step, previous + 1, metadata.strategy_cursor, now, &.{safe_event}), now);
            try gateway.recordPublished(3 + step, metadata.strategy_cursor, now);
            if (!(loss and step == 0)) {
                var safe_output: [1024]u8 = undefined;
                const safe_frame = try host.receiveOutput(init.io, now, &safe_output);
                const decision = gateway.ingest(safe_frame, now + 1);
                try std.testing.expect(decision == .accepted_group);
                const proposals = try gateway_module.decodeIntentGroup(decision.accepted_group.frame());
                try std.testing.expectEqual(metadata.next_intent_sequence, proposals.members[0].intent_sequence);
                for (proposals.members[0..proposals.count]) |intent| try std.testing.expect(intent.portfolio_reduce_only);
                _ = try input.apply(fixture.atGroup(61 + step, .{ .identity = 9030 + step, .payload = decision.corePayload() }));
                try std.testing.expectEqual(original_order_count + 2, owner.shard.oms.order_count);
                try std.testing.expectEqualDeep(original_cycle, owner.shard.cycles.find(9, 1).?);
                try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
                metadata.next_intent_sequence += 2;
            }
            try host.requestCheckpoint(init.io, 4 + step, metadata);
            const safe_checkpoint = try host.receiveCheckpoint(init.io, &frame);
            const safe_body = (try recovery_module.decodePayloadCheckpoint(safe_checkpoint, metadata)).payload;
            const safe_json = try std.json.parseFromSlice(std.json.Value, init.gpa, safe_body, .{});
            defer safe_json.deinit();
            const safe_state = (try privateComponent(safe_json.value, "cycle")).object.get("state").?.object;
            if (loss and step == 0) {
                try std.testing.expectEqualStrings("holding", safe_state.get("phase").?.string);
                try std.testing.expectEqual(original_order_count, owner.shard.oms.order_count);
            } else {
                try std.testing.expectEqualStrings("exiting", safe_state.get("phase").?.string);
                try std.testing.expectEqualStrings(if (loss) "take_profit" else "manual", safe_state.get("first_exit").?.object.get("value").?.object.get("reason").?.string);
            }
            try std.testing.expectEqual(@as(i64, 4), safe_state.get("target_atoms").?.object.get("value").?.integer);
        }
    }
    var old_config = gateway.config;
    old_config.session = old_plan.session;
    old_config.authorization.activation_identity = 1;
    var output: [256]u8 = undefined;
    const late = try gateway_module.encodeOutputFrame(&output, old_config, 1, activation.barrier, 1, 10000, 100);
    try std.testing.expectEqual(gateway_module.RejectReason.old_session, gateway.ingest(late, now).rejected.reason);
    old_config.session = plan.session;
    const stale_activation = try gateway_module.encodeOutputFrame(&output, old_config, 2, activation.barrier, 99, 10000, 100);
    try std.testing.expectEqual(gateway_module.RejectReason.unauthorized, gateway.ingest(stale_activation, now).rejected.reason);
    try old_host.shutdown(init.io, 4);
    try host.shutdown(init.io, 4);
    if (phase == .exiting) {
        const a_economics = owner.shard.accountState(20).?.economic_projection.semanticDigest();
        const b_economics = owner.shard.accountState(30).?.economic_projection.semanticDigest();
        _ = try input.apply(.{ .core = .{ .identity = 9013, .payload = .{ .strategy_cutover_fence = .{ .strategy_instance = 9 } } } });
        _ = try input.apply(.{ .core = .{ .identity = 9014, .payload = .{ .version_activation = .{
            .activation_identity = 9014,
            .generation = owner.shard.release_generation + 1,
            .old_release = owner.shard.active_release,
            .new_release = 9014,
            .old_strategy_instance = owner.shard.active_strategy_instance,
            .new_strategy_instance = 99,
            .strategy_definition = 3,
            .parameter_version = 1,
            .state_schema_version = 2,
            .transition = .keep,
            .barrier = owner.shard.authoritativeBarrier() + 1,
            .canonical_state_digest = owner.shard.canonicalStateDigest(),
        } } } });
        try std.testing.expectError(error.CoreRecoveryIncomplete, recovery.Recovery.begin(init.gpa, owner, 99, plan.session));
        try owner.checkpoint();
        try demo.Owner.recoverInto(owner, adapter.interface(), init.io, owner.stream);
        try owner.pinDeploymentDigest(deployment_digest);
        try std.testing.expectEqualDeep(original_cycle, owner.shard.cycles.find(9, 1).?);
        try std.testing.expectEqualSlices(u8, &a_economics, &owner.shard.accountState(20).?.economic_projection.semanticDigest());
        try std.testing.expectEqualSlices(u8, &b_economics, &owner.shard.accountState(30).?.economic_projection.semanticDigest());
        try std.testing.expect(owner.shard.strategyFenced(9));
    }
    std.debug.print("09b real core phase {s}/{s}/{s}: cycle=equivalent, committed activation, cut={d} activation_barrier={d} next_intent={d} orders={d} cycles={d} opening=false; projection_sha256={s} checkpoint_private_sha256={s} qualified_private_sha256={s} qualified_core_sha256={s}\n", .{ @tagName(phase), @tagName(transition), @tagName(scenario), old_decoded.metadata.strategy_cursor, activation.barrier, metadata.next_intent_sequence, owner.shard.oms.order_count, owner.shard.cycles.count, std.fmt.bytesToHex(binding.projection_digest, .lower), std.fmt.bytesToHex(old_decoded.state_digest, .lower), std.fmt.bytesToHex(qualification.private_digest, .lower), std.fmt.bytesToHex(qualification.core_digest, .lower) });
}

fn resolveIocRejection(input: *CycleIngress, gateway: *@import("../../execution/execution_gateway.zig").Gateway, adapter: *@import("../acceptance/core/dual_ioc_dispatch_acceptance.zig").Adapter) !void {
    const canonical = @import("../../model/canonical_event.zig");
    const shard = &input.owner.shard;
    const order = shard.oms.orderById(2).?;
    try std.testing.expectError(error.UnreconciledDispatch, gateway.reconcileRecoveredDispatch(shard, 2));
    try std.testing.expectEqual(.accepted, try gateway.queryCycleOrder(shard, 9, 1, 2, 3));
    try std.testing.expectEqualDeep(canonical.OrderReconciliationRequest{
        .identity = 3,
        .exchange_account = 30,
        .order = order.id,
    }, adapter.query.?);
    try std.testing.expectEqual(@as(usize, 0), adapter.sends);
    var evidence = fixture.reconciliationEvidence(61, 5, order.id, 102, order.revision);
    evidence.scope.exchange_account = 30;
    evidence.scope.from_utc_ns = order.created_at_utc_ns;
    var resolved = fixture.canonicalAt(61, 5, .{ .order_reconciliation_result = .{
        .identity = 3,
        .order = order.id,
        .revision = order.revision,
        .complete = true,
        .status = .found_terminal,
        .terminal_status = .rejected,
        .rules_version = 1,
        .cumulative_quantity = .{ .instrument = 102, .rules_version = 1, .lots = 0 },
        .remaining_quantity = .{ .instrument = 102, .rules_version = 1, .lots = 0 },
        .evidence = evidence,
    } });
    resolved.venue.envelope.exchange_account = 30;
    resolved.venue.envelope.venue = 21;
    resolved.venue.envelope.raw_evidence = evidence.source;
    var results: canonical.AdapterOutputBatch = .{};
    try results.append(resolved.venue);
    adapter.pending = results;
    try drainCycleAdapter(input, gateway);
    try std.testing.expectEqual(.rejected, shard.oms.orderById(2).?.state);
    try std.testing.expectError(error.StaleOrderQuery, gateway.queryCycleOrder(shard, 9, 1, 2, 3));
    try gateway.reconcileRecoveredDispatch(shard, 2);
    try std.testing.expectEqual(@as(u64, 3), gateway.uncertain_dispatches[0].reconciliation_id);
}

fn drainCycleAdapter(input: *CycleIngress, gateway: *@import("../../execution/execution_gateway.zig").Gateway) !void {
    const execution = @import("../../execution/execution_gateway.zig");
    var batches: [execution.max_routes]@import("../../model/canonical_event.zig").AdapterOutputBatch = undefined;
    try std.testing.expectEqual(@as(u8, 1), try gateway.drainFair(&batches));
    for (batches[0].slice()) |record| _ = try input.apply(.{ .venue = record });
}

fn observeIocPosition(input: *CycleIngress, group: u64, sequence: u64, lots: i64) !void {
    const account = input.owner.shard.canonical_account;
    var observed = fixture.canonicalAt(group, sequence, .{ .account_observed = .{
        .identity = sequence,
        .exchange_account = 20,
        .bootstrap = account.bootstrap.?,
        .source_stream = account.source_stream.?,
        .source_sequence = account.last_sequence + 1,
        .value = .{ .position = .{
            .instrument = 101,
            .side = .net,
            .value = .{ .instrument = 101, .side = .net, .quantity = .{ .instrument = 101, .rules_version = 1, .lots = lots } },
        } },
    } });
    observed.venue.envelope.exchange_account = 20;
    _ = try input.apply(observed);
}

fn finishIocRepair(init: std.process.Init, python: []const u8, dir: std.Io.Dir, path: []const u8, input: *CycleIngress, gateway: *@import("../../execution/execution_gateway.zig").Gateway, adapter: *@import("../acceptance/core/dual_ioc_dispatch_acceptance.zig").Adapter) !void {
    const owner = input.owner;
    const dual = @import("../acceptance/core/dual_ioc_dispatch_acceptance.zig");
    const multi = @import("../acceptance/core/multi_account_authority_acceptance.zig");
    const canonical = @import("../../model/canonical_event.zig");
    const order = owner.shard.oms.orderById(3).?;
    const command = for (owner.shard.oms.command_history[0..owner.shard.oms.command_history_count]) |entry| {
        if (entry.order_id == order.id and entry.operation == .place) break entry;
    } else return error.MissingRepairCommand;
    try dual.observe(gateway, &owner.shard);
    const now = fixture.atGroup(62, .{ .identity = 0, .payload = .recovery_completed }).core.monotonic_time;
    try std.testing.expectEqual(.accepted, try gateway.sendFromShard(&owner.shard, command.command_id, now));
    try std.testing.expectEqual(@as(usize, 1), adapter.sends);
    try std.testing.expectEqualDeep(order.client_order_id, adapter.command.?.client_order_id);
    var terminal = fixture.canonicalAt(63, 7, .{ .execution_report = .{
        .identity = 3,
        .order = order.id,
        .client_order_id = order.client_order_id,
        .exchange_account = 20,
        .instrument = 101,
        .revision = 1,
        .status = .filled,
        .cumulative_quantity = .{ .instrument = 101, .rules_version = 1, .lots = 5000 },
        .remaining_quantity = .{ .instrument = 101, .rules_version = 1, .lots = 0 },
    } });
    terminal.venue.envelope.exchange_account = 20;
    var fill = fixture.canonicalAt(63, 8, .{ .fill = .{
        .identity = 2,
        .order = order.id,
        .client_order_id = order.client_order_id,
        .venue_order = try canonical.VenueOrderRef.init(1, "ioc-repair"),
        .venue_trade = try canonical.VenueTradeRef.init(1, "ioc-repair-fill"),
        .exchange_account = 20,
        .instrument = 101,
        .side = .sell,
        .quantity = .{ .instrument = 101, .rules_version = 1, .lots = 5000 },
        .price = .{ .instrument = 101, .rules_version = 1, .ticks = 100 },
        .fee = .{ .asset = 3, .atoms = 2 },
        .liquidity = .taker,
        .venue_fill_time_utc_ns = terminal.venue.envelope.times.source_utc_ns.?,
    } });
    fill.venue.envelope.exchange_account = 20;
    var results: canonical.AdapterOutputBatch = .{};
    try results.append(terminal.venue);
    try results.append(fill.venue);
    adapter.pending = results;
    try drainCycleAdapter(input, gateway);
    fill.venue.envelope.identity.sequence = 9;
    fill.venue.envelope.source_sequence = 9;
    _ = try input.apply(fill);
    try observeIocPosition(input, 63, 10, 0);
    const economics = &owner.shard.accountState(20).?.economic_projection;
    try std.testing.expectEqual(@as(u64, 3), economics.settlement_asset);
    try std.testing.expectEqual(@as(i64, 5000), try economics.appliedCanonicalFillQuantity(order.id));
    try std.testing.expectEqual(@as(i128, 393), economics.portfolioLayer(10).?.settlement_balance_atoms);
    try std.testing.expectEqual(@as(i128, 600), owner.shard.accountState(30).?.economic_projection.portfolioLayer(10).?.settlement_balance_atoms);
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| {
        const projection = &owner.shard.accountState(account).?.economic_projection;
        try std.testing.expectEqual(@as(i64, 0), projection.portfolioLayer(10).?.positionForInstrument(instrument).quantity);
        try multi.reconcileDomainAccount(owner, account, gateway);
    }
    const closure = try owner.shard.qualifyCycleClosure(9, 1);
    _ = try input.apply(fixture.atGroup(65, .{ .identity = 9031, .payload = .{ .cycle_closed = closure } }));
    var fx = try @import("../../runtime/strategy_fx_projection.zig").project(init.gpa, &owner.shard, &owner.decision_journal, 9, 1);
    defer fx.deinit(init.gpa);
    try std.testing.expect(fx.closed and fx.complete);
    try std.testing.expectEqual(@as(usize, 2), fx.flows.items.len);
    for (fx.flows.items, [_]i128{ -5, -2 }) |flow, amount| {
        try std.testing.expectEqual(@as(u64, 3), flow.asset);
        try std.testing.expectEqual(@as(u128, 20), flow.account);
        try std.testing.expectEqual(amount, flow.atoms);
    }
    const projection = try fx.json(init.gpa);
    defer init.gpa.free(projection);
    try dir.writeFile(init.io, .{ .sub_path = "cycle-fx.json", .data = projection });
    const result = try std.process.run(init.gpa, init.io, .{ .argv = &.{
        python, "python/verify_production_strategy_chain.py", "--verify-dual-ioc-fx", path, "7", "500000000",
    } });
    defer init.gpa.free(result.stderr);
    defer init.gpa.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}", .{result.stderr});
        return error.IocRepairFxMismatch;
    }
}

fn cycleProjection(owner: *const @import("../../runtime/demo/demo_authority.zig").Owner, utc: u64, projection: *[176]u8) !void {
    @memset(projection, 0);
    std.mem.writeInt(u64, projection[0..8], utc, .little);
    var nav: i128 = 0;
    var realized: i128 = 0;
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, 0..) |account, instrument, index| {
        const order = owner.shard.oms.orderById(index + 1).?;
        const terminal = order.state == .filled or order.state == .canceled or order.state == .rejected;
        const economics = &owner.shard.accountState(account).?.economic_projection;
        const applied = try economics.appliedCanonicalFillQuantity(order.id);
        const possible = @max(0, (if (terminal) order.cumulative_quantity else order.quantity) - applied);
        std.mem.writeInt(u64, projection[8 + 16 * index ..][0..8], @intCast(applied), .little);
        std.mem.writeInt(u64, projection[16 + 16 * index ..][0..8], @intCast(possible), .little);
        const portfolio = economics.portfolioLayer(10).?;
        nav += portfolio.settlement_balance_atoms;
        realized += portfolio.realized_pnl_atoms;
        const quantity = portfolio.positionForInstrument(instrument).quantity;
        std.mem.writeInt(u64, projection[48 + 8 * index ..][0..8], @intCast(@abs(quantity)), .little);
        std.mem.writeInt(u64, projection[64 + 8 * index ..][0..8], if (order.state == .unknown or (terminal and possible != 0)) 2 else if (terminal) 1 else 0, .little);
    }
    std.mem.writeInt(u64, projection[40..48], @intCast(nav), .little);
    std.mem.writeInt(u64, projection[88..96], @intCast(@max(0, -realized)), .little);
    var additional: usize = 0;
    for (owner.shard.oms.command_history[0..owner.shard.oms.command_history_count]) |command| {
        if (command.operation != .place or command.intent_sequence <= 2) continue;
        if (additional == 2) return error.ProjectionCapacity;
        const order = owner.shard.oms.orderById(command.order_id).?;
        const terminal = order.state == .filled or order.state == .canceled or order.state == .rejected;
        const applied = try owner.shard.accountState(order.exchange_account).?.economic_projection.appliedCanonicalFillQuantity(order.id);
        const possible = @max(0, (if (terminal) order.cumulative_quantity else order.quantity) - applied);
        const offset = 96 + 40 * additional;
        std.mem.writeInt(u64, projection[offset..][0..8], command.intent_sequence, .little);
        std.mem.writeInt(u64, projection[offset + 8 ..][0..8], if (order.exchange_account == 20) 0 else 1, .little);
        std.mem.writeInt(u64, projection[offset + 16 ..][0..8], @intCast(applied), .little);
        std.mem.writeInt(u64, projection[offset + 24 ..][0..8], @intCast(possible), .little);
        std.mem.writeInt(u64, projection[offset + 32 ..][0..8], if (order.state == .unknown or (terminal and possible != 0)) 2 else if (terminal) 1 else 0, .little);
        additional += 1;
    }
    for (owner.shard.operational_state.gates[0..owner.shard.operational_state.gate_count]) |gate| {
        if (!gate.open and gate.reason == .margin_kill) std.mem.writeInt(u64, projection[80..88], 1, .little);
    }
}

fn privateComponent(value: std.json.Value, name: []const u8) !std.json.Value {
    for (value.object.get("components").?.array.items) |row| {
        if (std.mem.eql(u8, row.object.get("name").?.string, name)) return row;
    }
    return error.MissingPrivateComponent;
}

const CycleIngress = struct {
    owner: *@import("../../runtime/demo/demo_authority.zig").Owner,
    sink: @import("../../persistence/raw_ingress.zig").DurableSink,

    fn apply(self: *@This(), canonical: @import("../../trading/trading_shard.zig").CanonicalEvent) !?@import("../../trading/trading_shard.zig").OrderCommand {
        if (canonical == .venue) {
            var buffer: [16384]u8 = undefined;
            const bytes = try @import("../../persistence/snapshot_codec.zig").encodeBare(&buffer, canonical);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            const times = canonical.venue.envelope.times;
            _ = try self.sink.interface().append(.{ .origin = 0x09b, .source_session = std.math.cast(u64, canonical.venue.envelope.adapter_session orelse return error.InvalidFixtureIngress) orelse return error.InvalidFixtureIngress, .receive_time_utc_ns = times.receive_utc_ns.?, .monotonic_time_ns = times.monotonic_ns.?, .wall_time_utc_ns = times.audit_utc_ns.?, .byte_len = @intCast(bytes.len), .sha256 = digest }, bytes);
        }
        return self.owner.apply(canonical);
    }

    fn replay(self: *@This()) !void {
        try self.owner.bindRecoveryIngress(self.sink.store, self.sink.stream);
        try self.owner.replayCommittedIngress(self.sink.stream, .{ .ptr = self, .consume_fn = consume });
    }

    fn consume(context: *anyopaque, _: u64, record: @import("../../adapters/okx/okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (record.origin != 0x09b) return error.InvalidFixtureIngress;
        const canonical = try @import("../../persistence/snapshot_codec.zig").decodeBare(bytes, @import("../../trading/trading_shard.zig").CanonicalEvent);
        if (canonical != .venue) return error.InvalidFixtureIngress;
        _ = try self.owner.apply(canonical);
    }
};
