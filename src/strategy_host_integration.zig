const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("trading_shard_fixture.zig");
const gateway_module = @import("strategy_host_gateway.zig");
const ipc = @import("strategy_host_ipc.zig");
const lifecycle = @import("strategy_host_lifecycle.zig");

fn runCheck(init: std.process.Init, python: []const u8, script: []const u8, bridge: []const u8) !void {
    const python_abi = try lifecycle.discoverPythonAbi(init, python);
    const plan = lifecycle.developmentPlan(0, 31, python_abi);
    const authorization: gateway_module.Authorization = .{
        .strategy_identity = 0x1001,
        .config_version = 7,
        .activation_identity = 0x2002,
        .activation_barrier = 10,
    };
    const config: gateway_module.Config = .{
        .schema_registry = plan.compatibility.schema_registry,
        .decision_domain = plan.decision_domain,
        .session = plan.session,
        .authorization = authorization,
    };

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
        "trade",
        &extra_args,
    );
    defer host.deinit(init.io);
    try host.sendPlan(init.io);
    try expectLifecycle(.accepted, try host.receive(init.io, 1));
    try expectLifecycle(.accepted, try host.receive(init.io, 2));

    const subscriptions = [_]gateway_module.Subscription{
        gateway_module.Subscription.of(authorization.strategy_identity, &.{ .mark_price, .l2_delta }),
        gateway_module.Subscription.of(0x1002, &.{.l2_delta}),
    };
    var gateway = try gateway_module.Gateway.init(config, &subscriptions);
    const mark_payload = [_]u8{1};
    const fill_payload = [_]u8{2};
    const account_payload = [_]u8{3};
    const l2_payload = [_]u8{4};
    const published_ns: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    const events = [_]gateway_module.EventEnvelope{
        event(.mark_price, 11, published_ns, &mark_payload),
        event(.fill, 12, published_ns, &fill_payload),
        event(.account, 13, published_ns, &account_payload),
        event(.l2_delta, 14, published_ns, &l2_payload),
    };
    var batch_storage: [1024]u8 = undefined;
    const batch = try gateway.encodeBatch(&batch_storage, 1, 11, 14, published_ns, &events);
    try std.testing.expectEqual(@as(u32, 2), try gateway_module.eventCount(batch));
    var input_owner = try host.input_mapping.ring(.input, plan.session);
    try expectIpc(.ok, input_owner.tryPublishMany(&.{batch}));
    try gateway.recordPublished(1, 14, published_ns);

    var output_owner = try host.output_mapping.ring(.output, plan.session);
    var output_storage: [512]u8 = undefined;
    const deadline = published_ns + std.time.ns_per_s;
    while (true) {
        const status = output_owner.tryRead(&output_storage);
        if (status == .ok) break;
        if (status != .empty) return error.OutputReadFailed;
        if (@as(i64, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds)) > deadline)
            return error.OutputTimeout;
        std.Thread.yield() catch {};
    }
    const output_len = get(u32, &output_storage, 12);
    const frame = output_storage[0..output_len];
    const accepted = gateway.ingest(
        frame,
        @intCast(std.Io.Clock.awake.now(init.io).nanoseconds),
    );
    try std.testing.expect(accepted == .accepted);

    var ingress = try fixture.TradingShardHostIngress.initHealthyFixtureFor(authorization);
    try std.testing.expect(try ingress.applyDecision(accepted));

    try applyRejected(&ingress, gateway.ingest(frame, published_ns + 1), .duplicate_identity);
    var variant_storage: [256]u8 = undefined;
    var variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        config,
        1,
        14,
        1,
        101,
        50_100_000_000,
    );
    try applyRejected(&ingress, gateway.ingest(variant, published_ns + 2), .conflicting_identity);

    var old_config = config;
    old_config.session.generation -= 1;
    variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        old_config,
        1,
        14,
        2,
        100,
        50_100_000_000,
    );
    try applyRejected(&ingress, gateway.ingest(variant, published_ns + 3), .old_session);

    variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        config,
        1,
        13,
        3,
        100,
        50_100_000_000,
    );
    try applyRejected(&ingress, gateway.ingest(variant, published_ns + 4), .invalid_cursor);

    var unknown_schema = config;
    unknown_schema.schema_registry += 1;
    variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        unknown_schema,
        1,
        14,
        4,
        100,
        50_100_000_000,
    );
    try applyRejected(&ingress, gateway.ingest(variant, published_ns + 5), .unknown_schema);

    var unauthorized = config;
    unauthorized.authorization.activation_identity += 1;
    variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        unauthorized,
        1,
        14,
        5,
        100,
        50_100_000_000,
    );
    try applyRejected(&ingress, gateway.ingest(variant, published_ns + 6), .unauthorized);

    variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        config,
        1,
        14,
        6,
        100,
        50_100_000_000,
    );
    try applyRejected(&ingress, gateway.ingest(variant, published_ns + 100_000_001), .stale);

    const summary = ingress.summary();
    try std.testing.expectEqual(@as(usize, 1), summary.order_intents);
    try std.testing.expectEqual(@as(usize, 1), summary.risk_accepts);
    try std.testing.expectEqual(@as(usize, 1), summary.order_commands);
    try std.testing.expectEqual(@as(usize, 7), summary.host_rejections);
    try std.testing.expectEqual(@as(i64, 100), summary.order_quantity);
    try std.testing.expectEqual(@as(i64, 50_100_000_000), summary.order_limit_price_micros);
    try std.testing.expectEqual(@as(i64, 11_397_750), summary.reservation_micros);
    try ingress.verifyReplay();
    try host.shutdown(init.io, 3);
}

fn event(
    event_type: gateway_module.EventType,
    sequence: u64,
    now_ns: i64,
    payload: []const u8,
) gateway_module.EventEnvelope {
    return .{
        .event_type = event_type,
        .shard_sequence = sequence,
        .source_time_ns = now_ns,
        .receive_time_ns = now_ns,
        .monotonic_time_ns = now_ns,
        .wall_time_utc_ns = now_ns,
        .payload = payload,
    };
}

fn applyRejected(
    ingress: *fixture.TradingShardHostIngress,
    decision: gateway_module.Decision,
    expected: gateway_module.RejectReason,
) !void {
    if (decision != .rejected or decision.rejected.reason != expected)
        return error.UnexpectedRejectReason;
    if (try ingress.applyDecision(decision)) return error.RejectionProducedCommand;
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
        "strategy_host_integration: zig={s}, subscriptions=merged, python_intent=accepted, native_risk_path=ok, stable_rejections=7\n",
        .{builtin.zig_version_string},
    );
    try stdout.interface.flush();
}
