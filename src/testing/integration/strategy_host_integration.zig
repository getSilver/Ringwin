const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("../support/trading_shard_fixture.zig");
const gateway_module = @import("../../strategy/strategy_host_gateway.zig");
const lifecycle = @import("../../strategy/strategy_host_lifecycle.zig");

fn runCheck(init: std.process.Init, python: []const u8, script: []const u8) !void {
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

    const ingress = try init.gpa.create(fixture.TradingShardHostIngress);
    defer init.gpa.destroy(ingress);
    try fixture.TradingShardHostIngress.initHealthyFixtureForSessionInto(ingress, authorization, plan.session);
    const activation_digest = ingress.run.shard.canonicalStateDigest();
    try host.activate(init.io, .{
        .strategy_identity = authorization.strategy_identity,
        .activation_identity = authorization.activation_identity,
        .barrier = authorization.activation_barrier,
        .state_digest = activation_digest,
    });

    const subscriptions = [_]gateway_module.Subscription{
        gateway_module.Subscription.of(authorization.strategy_identity, &.{ .mark_price, .l2_delta }),
        gateway_module.Subscription.of(0x1002, &.{.l2_delta}),
    };
    var gateway = try gateway_module.Gateway.init(config, &subscriptions);
    const first_sequence: u64 = @intCast(try std.math.add(u64, ingress.run.shard.authoritativeBarrier(), 1));
    const last_sequence = first_sequence + 3;
    const mark_payload = [_]u8{1};
    const fill_payload = [_]u8{2};
    const account_payload = [_]u8{3};
    const l2_payload = [_]u8{4};
    const published_ns: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    const events = [_]gateway_module.EventEnvelope{
        event(.mark_price, first_sequence, published_ns, &mark_payload),
        event(.fill, first_sequence + 1, published_ns, &fill_payload),
        event(.account, first_sequence + 2, published_ns, &account_payload),
        event(.l2_delta, last_sequence, published_ns, &l2_payload),
    };
    var batch_storage: [1024]u8 = undefined;
    const batch = try gateway.encodeBatch(&batch_storage, 1, first_sequence, last_sequence, published_ns, &events);
    try std.testing.expectEqual(@as(u32, 2), try gateway_module.eventCount(batch));
    try host.sendInput(init.io, batch, published_ns);
    try gateway.recordPublished(1, last_sequence, published_ns);
    try gateway.activate(&ingress.run.shard, &ingress.run.decision_journal);

    var output_storage: [512]u8 = undefined;
    const frame = try host.receiveOutput(init.io, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds), &output_storage);
    const accepted = gateway.ingest(
        frame,
        @intCast(std.Io.Clock.awake.now(init.io).nanoseconds),
    );
    try std.testing.expect(accepted == .accepted);

    try std.testing.expect(try ingress.applyDecision(accepted));

    try applyRejected(ingress, gateway.ingest(frame, published_ns + 1), .duplicate_identity);
    var variant_storage: [256]u8 = undefined;
    var variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        config,
        1,
        last_sequence,
        1,
        101,
        50_100_000_000,
    );
    try applyRejected(ingress, gateway.ingest(variant, published_ns + 2), .conflicting_identity);

    var old_config = config;
    old_config.session.generation -= 1;
    variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        old_config,
        1,
        last_sequence,
        2,
        100,
        50_100_000_000,
    );
    try applyRejected(ingress, gateway.ingest(variant, published_ns + 3), .old_session);

    variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        config,
        1,
        last_sequence - 1,
        3,
        100,
        50_100_000_000,
    );
    try applyRejected(ingress, gateway.ingest(variant, published_ns + 4), .invalid_cursor);

    var unknown_schema = config;
    unknown_schema.schema_registry += 1;
    variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        unknown_schema,
        1,
        last_sequence,
        4,
        100,
        50_100_000_000,
    );
    try applyRejected(ingress, gateway.ingest(variant, published_ns + 5), .unknown_schema);

    var unauthorized = config;
    unauthorized.authorization.activation_identity += 1;
    variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        unauthorized,
        1,
        last_sequence,
        5,
        100,
        50_100_000_000,
    );
    try applyRejected(ingress, gateway.ingest(variant, published_ns + 6), .unauthorized);

    variant = try gateway_module.encodeOutputFrame(
        &variant_storage,
        config,
        1,
        last_sequence,
        6,
        100,
        50_100_000_000,
    );
    try applyRejected(ingress, gateway.ingest(variant, published_ns + 100_000_001), .stale);

    const summary = try ingress.summary();
    try std.testing.expectEqual(@as(usize, 1), summary.order_intents);
    try std.testing.expectEqual(@as(usize, 1), summary.risk_accepts);
    try std.testing.expectEqual(@as(usize, 1), summary.order_commands);
    try std.testing.expectEqual(@as(usize, 7), summary.host_rejections);
    try std.testing.expectEqual(@as(i64, 100), summary.order_quantity);
    try std.testing.expectEqual(@as(i64, 50_100_000_000), summary.order_limit_price_micros);
    try std.testing.expectEqual(@as(i64, 11_397_750), summary.reservation_atoms);
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

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const python = args.next() orelse "python";
    const script = args.next() orelse "python/strategy_host.py";
    if (args.next() != null) return error.UnknownArgument;
    try runMultiAccountGroupCheck(init, python, script, false);
    try runMultiAccountGroupCheck(init, python, script, true);
    try runGroupCheck(init, python, script);
    try runCheck(init, python, script);
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print(
        "strategy_host_integration: zig={s}, subscriptions=merged, python_intent=accepted, native_risk_path=ok, stable_rejections=7\n",
        .{builtin.zig_version_string},
    );
    try stdout.interface.flush();
}

fn runGroupCheck(init: std.process.Init, python: []const u8, script: []const u8) !void {
    const plan = lifecycle.developmentPlan(0, 31, try lifecycle.discoverPythonAbi(init, python));
    const authorization: gateway_module.Authorization = .{ .strategy_identity = 0x1001, .config_version = 7, .activation_identity = 0x2002, .activation_barrier = 10 };
    const config: gateway_module.Config = .{ .schema_registry = plan.compatibility.schema_registry, .decision_domain = plan.decision_domain, .session = plan.session, .authorization = authorization };
    var host = try lifecycle.ManagedHost.start(init, python, script, plan, "trade", &.{ "--strategy-identity", "0x1001", "--activation-identity", "0x2002", "--config-version", "7", "--intent-group" });
    defer host.deinit(init.io);
    try host.sendPlan(init.io);
    try expectLifecycle(.accepted, try host.receive(init.io, 1));
    try expectLifecycle(.accepted, try host.receive(init.io, 2));
    const ingress = try init.gpa.create(fixture.TradingShardHostIngress);
    defer init.gpa.destroy(ingress);
    try fixture.TradingShardHostIngress.initHealthyFixtureForSessionInto(ingress, authorization, plan.session);
    try host.activate(init.io, .{ .strategy_identity = authorization.strategy_identity, .activation_identity = authorization.activation_identity, .barrier = authorization.activation_barrier, .state_digest = ingress.run.shard.canonicalStateDigest() });
    var gateway = try gateway_module.Gateway.init(config, &.{gateway_module.Subscription.of(authorization.strategy_identity, &.{.mark_price})});
    const cursor = ingress.run.shard.authoritativeBarrier() + 1;
    const now: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    var batch_storage: [512]u8 = undefined;
    const batch = try gateway.encodeBatch(&batch_storage, 1, cursor, cursor, now, &.{event(.mark_price, cursor, now, &.{1})});
    try host.sendInput(init.io, batch, now);
    try gateway.recordPublished(1, cursor, now);
    try gateway.activate(&ingress.run.shard, &ingress.run.decision_journal);
    var output: [512]u8 = undefined;
    const frame = try host.receiveOutput(init.io, now, &output);
    const decision = gateway.ingest(frame, now + 1);
    try std.testing.expect(decision == .accepted_group);
    const group = try gateway_module.decodeIntentGroup(decision.accepted_group.frame());
    try std.testing.expectEqual(@as(u8, 2), group.count);
    try std.testing.expectEqual(@as(u128, 2), group.members[0].exchange_account_identity);
    try std.testing.expectEqual(@as(u128, 4), group.members[1].exchange_account_identity);
    try std.testing.expectEqual(@as(u64, 2), group.members[1].intent_sequence);
    try std.testing.expect(!try ingress.applyDecision(decision));
    try std.testing.expectEqual(@as(usize, 2), ingress.run.shard.oms.intent_history_count);
    try std.testing.expectEqual(@import("../../trading/trading_shard_event.zig").RejectReason.joint_admission_unavailable, ingress.run.shard.last_reject_reason);
    const barrier = ingress.run.shard.authoritativeBarrier();
    try std.testing.expect(!try ingress.applyDecision(gateway.ingest(frame, now + 2)));
    try std.testing.expectEqual(barrier, ingress.run.shard.authoritativeBarrier());
    var retry_storage: [512]u8 = undefined;
    const retry_orders = [_]gateway_module.OutputOrder{
        .{ .quantity = group.members[0].quantity, .limit_price_micros = group.members[0].limit_price_micros },
        .{ .exchange_account_identity = 4, .side = .sell, .quantity = group.members[1].quantity, .limit_price_micros = group.members[1].limit_price_micros },
    };
    try gateway.recordPublished(2, cursor + 1, now + 1);
    const renewed_envelope = try gateway_module.encodeOutputGroupFrame(&retry_storage, config, 2, cursor + 1, 1, &retry_orders);
    try std.testing.expect(!try ingress.applyDecision(gateway.ingest(renewed_envelope, now + 2)));
    try std.testing.expectEqual(barrier, ingress.run.shard.authoritativeBarrier());
    const summary = try ingress.summary();
    try std.testing.expectEqual(@as(usize, 0), summary.order_commands);
    try std.testing.expectEqual(@as(usize, 0), summary.risk_accepts);
    try std.testing.expectEqual(@as(i64, 0), summary.reservation_atoms);
    try checkGroupFailures(init, ingress, &gateway, config, cursor, now, frame);
    try ingress.verifyReplay();
    try checkGroupFileRecovery(init, ingress);
    try host.shutdown(init.io, 3);
}

fn checkGroupFileRecovery(init: std.process.Init, ingress: *fixture.TradingShardHostIngress) !void {
    const durable = @import("../../persistence/durable_store.zig");
    const journal = @import("../../persistence/journal.zig");
    const engine = @import("../../trading/trading_shard.zig");
    var cwd_buffer: [1024]u8 = undefined;
    const cwd = cwd_buffer[0..try std.Io.Dir.cwd().realPath(init.io, &cwd_buffer)];
    var path_buffer: [2048]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/.scratch/build/task04-store-{d}", .{ cwd, std.Io.Clock.real.now(init.io).nanoseconds });
    const adapter = try init.gpa.create(durable.LinuxFileAdapter);
    defer init.gpa.destroy(adapter);
    adapter.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try adapter.initWindowsVerification(init.io, path) else try adapter.initLinux(init.io, path);
    var opened = true;
    defer if (opened) adapter.close(init.io);
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 404 };
    var reader = try journal.Reader.init(ingress.run.decision_journal.bytes());
    while (true) switch (try reader.next()) {
        .record => |record| try adapter.interface().append(init.io, .{ .stream = stream, .record = record }),
        .end => break,
    };
    try adapter.interface().commit(init.io, stream, ingress.run.shard.authoritativeBarrier());
    try adapter.interface().seal(init.io, stream);
    const snapshot_storage = try init.gpa.alloc(u8, durable.max_snapshot_bytes);
    defer init.gpa.free(snapshot_storage);
    const snapshot = try ingress.run.shard.snapshot(&ingress.run.decision_journal, ingress.run.shard.authoritativeBarrier(), snapshot_storage);
    try adapter.interface().publishSnapshot(init.io, stream, ingress.run.shard.authoritativeBarrier(), snapshot);
    adapter.close(init.io);
    opened = false;
    adapter.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try adapter.initWindowsVerification(init.io, path) else try adapter.initLinux(init.io, path);
    opened = true;
    const recovered = try adapter.interface().recover(init.io, stream);
    try std.testing.expectEqual(durable.RecoveryStatus.ready, recovered.status);
    const initial = try init.gpa.create(engine.TradingShard);
    defer init.gpa.destroy(initial);
    initial.* = .{ .quantity_denominator = ingress.run.shard.quantity_denominator, .reservation_model = ingress.run.shard.reservation_model };
    const restored = try init.gpa.create(engine.TradingShard);
    defer init.gpa.destroy(restored);
    try std.testing.expectEqual(journal.ScanStatus.clean, try engine.recoverStableInto(restored, initial, recovered.active_segment));
    try std.testing.expectEqualSlices(u8, &ingress.run.shard.canonicalStateDigest(), &restored.canonicalStateDigest());
    _ = try engine.TradingShard.restoreSnapshotInto(restored, recovered.snapshot);
    try std.testing.expectEqualSlices(u8, &ingress.run.shard.canonicalStateDigest(), &restored.canonicalStateDigest());
    try std.testing.expectEqual(@as(usize, 8), restored.oms.intent_history_count);
    std.debug.print("host_group_file_recovery: identities=8, commands=0, path={s}\n", .{path});
}

fn checkGroupFailures(init: std.process.Init, ingress: *fixture.TradingShardHostIngress, gateway: *gateway_module.Gateway, config: gateway_module.Config, cursor: u64, now: i64, original: []const u8) !void {
    const engine = @import("../../trading/trading_shard.zig");
    const reasons = @import("../../trading/trading_shard_event.zig").RejectReason;
    const orders = [_]gateway_module.OutputOrder{
        .{ .quantity = 100, .limit_price_micros = 50_100_000_000 },
        .{ .exchange_account_identity = 4, .side = .sell, .quantity = 100, .limit_price_micros = 50_100_000_000 },
    };
    var storage: [512]u8 = undefined;
    // A half frame and a CRC-valid half group never become a single intent.
    try applyRejected(ingress, gateway.ingest(original[0 .. original.len - 1], now + 1), .malformed);
    @memcpy(storage[0..208], original[0..208]);
    std.mem.writeInt(u32, storage[12..16], 208, .little);
    refreshOutputCrc(storage[0..208]);
    try applyRejected(ingress, gateway.ingest(storage[0..208], now + 1), .malformed);
    var frame = try gateway_module.encodeOutputGroupFrame(&storage, config, 1, cursor, 2, &orders);
    try std.testing.expect(!try ingress.applyDecision(gateway.ingest(frame, now + 1)));
    try std.testing.expectEqual(reasons.intent_identity_conflict, ingress.run.shard.last_reject_reason);
    try std.testing.expectEqual(@as(usize, 2), ingress.run.shard.oms.intent_history_count);

    // Authorized freshness/cursor failures consume the complete business set.
    frame = try gateway_module.encodeOutputGroupFrame(&storage, config, 1, cursor, 3, &orders);
    try applyRejected(ingress, gateway.ingest(frame, now + 100_000_001), .stale);
    try std.testing.expectEqual(reasons.host_output_stale, ingress.run.shard.last_reject_reason);
    try std.testing.expectEqual(@as(usize, 4), ingress.run.shard.oms.intent_history_count);
    const before_retry = ingress.run.shard.authoritativeBarrier();
    try std.testing.expect(!try ingress.applyDecision(gateway.ingest(frame, now + 1)));
    try std.testing.expectEqual(before_retry, ingress.run.shard.authoritativeBarrier());
    frame = try gateway_module.encodeOutputGroupFrame(&storage, config, 1, cursor - 1, 5, &orders);
    try applyRejected(ingress, gateway.ingest(frame, now + 1), .invalid_cursor);
    try std.testing.expectEqual(@as(usize, 6), ingress.run.shard.oms.intent_history_count);

    // Foreign authorization cannot poison this strategy's sequence space.
    var changed = config;
    changed.session.generation -= 1;
    frame = try gateway_module.encodeOutputGroupFrame(&storage, changed, 1, cursor, 7, &orders);
    try applyRejected(ingress, gateway.ingest(frame, now + 1), .old_session);
    changed = config;
    changed.schema_registry += 1;
    frame = try gateway_module.encodeOutputGroupFrame(&storage, changed, 1, cursor, 7, &orders);
    try applyRejected(ingress, gateway.ingest(frame, now + 1), .unknown_schema);
    changed = config;
    changed.authorization.activation_identity += 1;
    frame = try gateway_module.encodeOutputGroupFrame(&storage, changed, 1, cursor, 7, &orders);
    try applyRejected(ingress, gateway.ingest(frame, now + 1), .unauthorized);
    changed = config;
    changed.authorization.strategy_identity += 1;
    frame = try gateway_module.encodeOutputGroupFrame(&storage, changed, 1, cursor, 7, &orders);
    try applyRejected(ingress, gateway.ingest(frame, now + 1), .unauthorized);
    changed = config;
    changed.authorization.config_version += 1;
    frame = try gateway_module.encodeOutputGroupFrame(&storage, changed, 1, cursor, 7, &orders);
    try applyRejected(ingress, gateway.ingest(frame, now + 1), .unauthorized);
    try std.testing.expectEqual(@as(usize, 6), ingress.run.shard.oms.intent_history_count);

    // Exact cardinality, consecutive sequences and overflow are wire contracts.
    frame = try gateway_module.encodeOutputGroupFrame(&storage, config, 1, cursor, 7, &orders);
    std.mem.writeInt(u64, frame[216..224], 9, .little);
    refreshOutputCrc(frame);
    try applyRejected(ingress, gateway.ingest(frame, now + 1), .malformed);
    try std.testing.expectError(error.FrameTooLarge, gateway_module.encodeOutputGroupFrame(storage[0..207], config, 1, cursor, 7, &orders));
    try std.testing.expectError(error.Overflow, gateway_module.encodeOutputGroupFrame(&storage, config, 1, cursor, std.math.maxInt(u64), &orders));
    const too_many = [_]gateway_module.OutputOrder{ orders[0], orders[0], orders[0], orders[0], orders[0] };
    try std.testing.expectError(error.InvalidIntentGroup, gateway_module.encodeOutputGroupFrame(&storage, config, 1, cursor, 7, &too_many));
    frame = try gateway_module.encodeOutputGroupFrame(&storage, config, 1, cursor, 7, &orders);
    std.mem.writeInt(u32, frame[100..104], 5, .little);
    refreshOutputCrc(frame);
    try applyRejected(ingress, gateway.ingest(frame, now + 1), .malformed);

    // A failed stable append rolls the entire candidate back, including identity.
    frame = try gateway_module.encodeOutputGroupFrame(&storage, config, 1, cursor, 7, &orders);
    const fresh = gateway.ingest(frame, now + 1);
    const digest = ingress.run.shard.canonicalStateDigest();
    const checkpoint = ingress.run.decision_journal.checkpoint();
    try ingress.run.decision_journal.seal();
    try std.testing.expectError(error.JournalSealed, ingress.applyDecision(fresh));
    try std.testing.expectEqualSlices(u8, &digest, &ingress.run.shard.canonicalStateDigest());
    ingress.run.decision_journal.restore(checkpoint);
    try std.testing.expect(!try ingress.applyDecision(fresh));
    try std.testing.expectEqual(@as(usize, 8), ingress.run.shard.oms.intent_history_count);

    // Snapshot restore carries the entire rejected identity set, not the
    // Gateway's ephemeral seen cache. A new gateway may resend the same bytes.
    const post_candidate_checkpoint = ingress.run.decision_journal.checkpoint();
    try ingress.run.decision_journal.seal();
    const snapshot_storage = try init.gpa.alloc(u8, @import("../../persistence/durable_store.zig").max_snapshot_bytes);
    defer init.gpa.free(snapshot_storage);
    const snapshot = try ingress.run.shard.snapshot(&ingress.run.decision_journal, ingress.run.shard.authoritativeBarrier(), snapshot_storage);
    const restored = try init.gpa.create(engine.TradingShard);
    defer init.gpa.destroy(restored);
    _ = try engine.TradingShard.restoreSnapshotInto(restored, snapshot);
    const restored_digest = restored.canonicalStateDigest();
    var next_journal = @import("../../persistence/journal.zig").Journal.initAt(restored.authoritativeBarrier() + 1);
    try std.testing.expect((try engine.applyStable(restored, &next_journal, .{ .core = .{ .identity = 7, .payload = .{ .external_intent_group = fresh.accepted_group } } })) == null);
    try std.testing.expectEqualSlices(u8, &restored_digest, &restored.canonicalStateDigest());
    // Replace the authorization session through public authoritative facts.
    // The same business group remains a duplicate under the new activation.
    _ = try engine.applyStable(restored, &next_journal, .{ .core = .{ .identity = restored.authoritativeBarrier() + 1, .payload = .{ .host_activation_revoked = .{ .strategy_identity = config.authorization.strategy_identity, .activation_identity = config.authorization.activation_identity, .reason = .session_replaced } } } });
    var next_config = config;
    next_config.session.generation += 1;
    next_config.authorization.activation_identity = try restored.nextHostActivationIdentity();
    next_config.authorization.activation_barrier = restored.authoritativeBarrier();
    _ = try engine.applyStable(restored, &next_journal, .{ .core = .{ .identity = restored.authoritativeBarrier() + 1, .payload = .{ .host_activated = .{ .strategy_identity = next_config.authorization.strategy_identity, .config_version = next_config.authorization.config_version, .activation_identity = next_config.authorization.activation_identity, .activation_barrier = next_config.authorization.activation_barrier, .session = next_config.session, .state_digest = restored.canonicalStateDigest() } } } });
    var next_gateway = try gateway_module.Gateway.init(next_config, &.{gateway_module.Subscription.of(config.authorization.strategy_identity, &.{.mark_price})});
    const next_cursor = restored.authoritativeBarrier() + 1;
    try next_gateway.recordPublished(1, next_cursor, now);
    try next_gateway.activate(restored, &next_journal);
    frame = try gateway_module.encodeOutputGroupFrame(&storage, next_config, 1, next_cursor, 7, &orders);
    const renewed = next_gateway.ingest(frame, now + 1);
    const renewed_digest = restored.canonicalStateDigest();
    try std.testing.expect((try engine.applyStable(restored, &next_journal, .{ .core = .{ .identity = 7, .payload = renewed.corePayload() } })) == null);
    try std.testing.expectEqualSlices(u8, &renewed_digest, &restored.canonicalStateDigest());
    // Exhaust public fact admission without editing counters. The next group
    // cannot leave its first member behind when its rejection fact won't fit.
    while (true) {
        _ = engine.applyStable(restored, &next_journal, .{ .core = .{ .identity = restored.authoritativeBarrier() + 1, .payload = .{ .strategy_intent_rejected = .{ .reason = .malformed, .strategy_identity = 0x1001, .intent_sequence = 0 } } } }) catch |err| {
            if (err == error.TraceFull) break;
            return err;
        };
    }
    const full_digest = restored.canonicalStateDigest();
    frame = try gateway_module.encodeOutputGroupFrame(&storage, next_config, 1, next_cursor, 9, &orders);
    const full_candidate = next_gateway.ingest(frame, now + 1).accepted_group;
    try std.testing.expectError(error.TraceFull, engine.applyStable(restored, &next_journal, .{ .core = .{ .identity = 9, .payload = .{ .external_intent_group = full_candidate } } }));
    try std.testing.expectEqualSlices(u8, &full_digest, &restored.canonicalStateDigest());
    try std.testing.expectEqual(@as(usize, 8), restored.oms.intent_history_count);
    ingress.run.decision_journal.restore(post_candidate_checkpoint);
    try std.testing.expect(!try ingress.applyDecision(fresh));
}

fn refreshOutputCrc(frame: []u8) void {
    var crc = std.hash.crc.Crc32Iscsi.init();
    crc.update(frame[0..124]);
    crc.update(frame[128..]);
    std.mem.writeInt(u32, frame[124..128], crc.final(), .little);
}

fn runMultiAccountGroupCheck(init: std.process.Init, python: []const u8, script: []const u8, post_only: bool) !void {
    const engine = @import("../../trading/trading_shard.zig");
    const demo = @import("../../runtime/demo/demo_authority.zig");
    const durable = @import("../../persistence/durable_store.zig");
    const multi = @import("../acceptance/core/multi_account_authority_acceptance.zig");
    var path_buffer: [2048]u8 = undefined;
    var cwd_buffer: [1024]u8 = undefined;
    const cwd = cwd_buffer[0..try std.Io.Dir.cwd().realPath(init.io, &cwd_buffer)];
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/.scratch/build/task05-store-{d}", .{ cwd, std.Io.Clock.real.now(init.io).nanoseconds });
    const adapter = try init.gpa.create(durable.LinuxFileAdapter);
    defer init.gpa.destroy(adapter);
    adapter.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try adapter.initWindowsVerification(init.io, path) else try adapter.initLinux(init.io, path);
    defer adapter.close(init.io);
    const owner = try init.gpa.create(demo.Owner);
    defer init.gpa.destroy(owner);
    try demo.Owner.bootstrapInto(owner, adapter.interface(), init.io, .{ .domain = .decision_log, .id = 91 });
    try multi.initializePythonOwner(owner);
    if (post_only) for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| {
        var view: engine.TradingShard = undefined;
        try owner.shard.copyAccountViewInto(&view, account);
        var profile = view.registryInstrument(instrument).?.capability.?;
        profile.version = 2;
        profile.supports_post_only = true;
        _ = try owner.apply(fixture.atGroup(44, .{ .identity = @intCast(2000 + instrument), .account_scope = account, .payload = .{ .capability_profile_activation = profile } }));
    };
    var plan = lifecycle.developmentPlan(0, 31, try lifecycle.discoverPythonAbi(init, python));
    plan.decision_domain = 1;
    const authorization: gateway_module.Authorization = .{ .strategy_identity = 9, .config_version = 1, .activation_identity = 1, .activation_barrier = owner.shard.authoritativeBarrier() };
    const config: gateway_module.Config = .{ .schema_registry = plan.compatibility.schema_registry, .decision_domain = 1, .session = plan.session, .authorization = authorization };
    var host = try lifecycle.ManagedHost.start(init, python, script, plan, "trade", &.{
        "--strategy-identity",  "9",                     "--activation-identity",       "1",                            "--intent-group",
        "--portfolio-identity", "10",                    "--exchange-account-identity", "20",                           "--second-exchange-account-identity",
        "30",                   "--instrument-identity", "101",                         "--second-instrument-identity", "102",
        "--quantity",           "10000",                 "--limit-price",               "100",                          if (post_only) "--time-in-force=post-only" else "--time-in-force=gtc",
    });
    defer host.deinit(init.io);
    try host.sendPlan(init.io);
    try expectLifecycle(.accepted, try host.receive(init.io, 1));
    try expectLifecycle(.accepted, try host.receive(init.io, 2));
    const activation_digest = owner.shard.canonicalStateDigest();
    _ = try owner.apply(.{ .core = .{ .identity = owner.shard.authoritativeBarrier() + 1, .payload = .{ .host_activated = .{
        .strategy_identity = 9,
        .config_version = 1,
        .activation_identity = 1,
        .activation_barrier = authorization.activation_barrier,
        .session = plan.session,
        .state_digest = activation_digest,
    } } } });
    try host.activate(init.io, .{ .strategy_identity = 9, .activation_identity = 1, .barrier = authorization.activation_barrier, .state_digest = activation_digest });
    var gateway = try gateway_module.Gateway.init(config, &.{gateway_module.Subscription.of(9, &.{.mark_price})});
    const cursor = owner.shard.authoritativeBarrier() + 1;
    const now: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
    var batch_storage: [512]u8 = undefined;
    const batch = try gateway.encodeBatch(&batch_storage, 1, cursor, cursor, now, &.{event(.mark_price, cursor, now, &.{1})});
    try host.sendInput(init.io, batch, now);
    try gateway.recordPublished(1, cursor, now);
    try gateway.activate(&owner.shard, &owner.decision_journal);
    var output: [512]u8 = undefined;
    const frame = try host.receiveOutput(init.io, now, &output);
    const decision = gateway.ingest(frame, now + 1);
    try std.testing.expect(decision == .accepted_group);
    _ = try owner.apply(fixture.atGroup(45, .{ .identity = cursor, .payload = .{ .external_intent_group = decision.accepted_group } }));
    try std.testing.expectEqual(@as(usize, 2), owner.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 2), owner.shard.oms.command_history_count);
    try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
    try std.testing.expectEqual(@as(u128, 20), owner.shard.oms.orders[0].exchange_account);
    try std.testing.expectEqual(@as(u128, 30), owner.shard.oms.orders[1].exchange_account);
    for (owner.shard.oms.command_history[0..owner.shard.oms.command_history_count]) |command| {
        try std.testing.expectEqual(if (post_only) engine.canonical.OrderType.post_only else .limit, command.order_type);
        try std.testing.expectEqual(if (post_only) engine.canonical.TimeInForce.post_only else .good_til_canceled, command.time_in_force);
        try std.testing.expectEqual(@as(u64, if (post_only) 2 else 1), command.authority.capability.version);
    }
    const accepted_digest = owner.shard.canonicalStateDigest();
    _ = try owner.apply(fixture.atGroup(45, .{ .identity = cursor + 1, .payload = .{ .external_intent_group = decision.accepted_group } }));
    try std.testing.expectEqualSlices(u8, &accepted_digest, &owner.shard.canonicalStateDigest());
    try owner.checkpoint();
    const digest = owner.shard.canonicalStateDigest();
    try host.shutdown(init.io, 3);
    adapter.close(init.io);
    adapter.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try adapter.initWindowsVerification(init.io, path) else try adapter.initLinux(init.io, path);
    const restored = try init.gpa.create(demo.Owner);
    defer init.gpa.destroy(restored);
    try demo.Owner.recoverInto(restored, adapter.interface(), init.io, owner.stream);
    try std.testing.expectEqualSlices(u8, &digest, &restored.shard.canonicalStateDigest());
    try std.testing.expectEqualDeep(owner.shard.oms.findCommand(1).?, restored.shard.oms.findCommand(1).?);
    std.debug.print("host_multi_account_file_recovery: accounts=2, commands=2, cycles=1, native_post_only={}, duplicate=stable, path={s}\n", .{ post_only, path });
}
