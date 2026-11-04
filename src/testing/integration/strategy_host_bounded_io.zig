const std = @import("std");
const lifecycle = @import("../../strategy/strategy_host_lifecycle.zig");
const gateway_module = @import("../../strategy/strategy_host_gateway.zig");
const fixture = @import("../support/trading_shard_fixture.zig");

fn handshake(host: *lifecycle.ManagedHost, io: std.Io) !void {
    try host.sendPlan(io);
    try std.testing.expectEqual(lifecycle.Result.accepted, try host.receive(io, 1));
    try std.testing.expectEqual(lifecycle.Result.accepted, try host.receive(io, 2));
}

fn expectTimeout(host: *lifecycle.ManagedHost, io: std.Io, mode: []const u8) !void {
    var storage: [512]u8 = undefined;
    if (std.mem.eql(u8, mode, "ack-hang") or std.mem.eql(u8, mode, "shutdown")) {
        try std.testing.expectError(error.HostTimeout, host.shutdown(io, 3));
    } else if (std.mem.eql(u8, mode, "checkpoint")) {
        try host.activate(io, .{ .strategy_identity = 1, .activation_identity = 1, .barrier = 0, .state_digest = @splat(0) });
        try host.requestCheckpoint(io, 1, .{
            .schema_registry = host.supervisor.plan.compatibility.schema_registry,
            .strategy_instance = 1,
            .strategy_definition = 1,
            .state_schema = 1,
            .state_schema_version = 1,
            .strategy_config_version = 1,
            .strategy_cursor = 0,
            .next_intent_sequence = 1,
        });
        try std.testing.expectError(error.HostTimeout, host.receiveCheckpoint(io, &storage));
    } else if (std.mem.eql(u8, mode, "write")) {
        const checkpoint = try std.heap.page_allocator.alloc(u8, 256 * 1024);
        defer std.heap.page_allocator.free(checkpoint);
        @memset(checkpoint, 0);
        const frame = try std.heap.page_allocator.alloc(u8, checkpoint.len + 72);
        defer std.heap.page_allocator.free(frame);
        try std.testing.expectError(error.HostTimeout, host.beginRecovery(io, 0, checkpoint, frame));
    } else {
        const plan = host.supervisor.plan;
        const authorization: gateway_module.Authorization = .{ .strategy_identity = 0x1101, .config_version = 7, .activation_identity = 0x2101, .activation_barrier = 0 };
        const config: gateway_module.Config = .{ .schema_registry = plan.compatibility.schema_registry, .decision_domain = plan.decision_domain, .session = plan.session, .authorization = authorization };
        var gateway = try gateway_module.Gateway.init(config, &.{gateway_module.Subscription.of(authorization.strategy_identity, &.{.timer})});
        var authority = try fixture.gatewayActivationFixtureForSession(authorization, plan.session);
        try host.activate(io, .{ .strategy_identity = authorization.strategy_identity, .activation_identity = authorization.activation_identity, .barrier = 0, .state_digest = @splat(0x42) });
        const batch = try gateway.encodeBatch(&storage, 1, 1, 1, 10, &.{});
        try gateway.recordPublished(1, 1, 10);
        try gateway.activate(&authority.shard, &authority.decision_journal);
        try host.sendInput(io, batch, 10);
        if (std.mem.eql(u8, mode, "batch")) {
            try std.testing.expectError(error.HostTimeout, host.receiveBatchAck(io, 11, 1));
        } else {
            try std.testing.expectError(error.HostTimeout, host.receiveOutput(io, 11, &storage));
        }
        try std.testing.expect(try lifecycle.revokeHostAuthority(&host.supervisor, &gateway, &authority.shard, &authority.decision_journal, 2, .fault));
        try std.testing.expectEqual(@as(u128, 0), authority.shard.host_activation_identity);
        const old = try gateway_module.encodeOutputFrame(&storage, config, 1, 1, 10, 100, 50_100_000_000);
        try std.testing.expectEqual(gateway_module.RejectReason.unauthorized, gateway.ingest(old, 12).rejected.reason);
        try std.testing.expectError(error.InvalidState, host.receiveOutput(io, 12, &storage));
    }
    try std.testing.expectEqual(lifecycle.State.failed, host.supervisor.state);
    try std.testing.expect(!host.supervisor.validatesEnvelope(.intent, host.supervisor.plan.session));
    try std.testing.expect(host.child.id == null);
}

pub fn main(init: std.process.Init) !void {
    const abi = try lifecycle.discoverPythonAbi(init, "python");
    for ([_][]const u8{ "silent", "prefix", "partial", "trickle" }) |mode| {
        var plan = lifecycle.developmentPlan(0, 1, abi);
        plan.startup_timeout_ns = 300 * std.time.ns_per_ms;
        var child = try lifecycle.ManagedHost.start(init, "python", "python/test_strategy_host_bounded_child.py", plan, mode, &.{});
        defer child.deinit(init.io);
        try child.sendPlan(init.io);
        const started = std.Io.Clock.awake.now(init.io);
        try std.testing.expectError(error.HostTimeout, child.receive(init.io, 0));
        try std.testing.expect(std.Io.Clock.awake.now(init.io).nanoseconds - started.nanoseconds < 2 * std.time.ns_per_s);
        try std.testing.expectEqual(lifecycle.State.failed, child.supervisor.state);
        try std.testing.expect(!child.supervisor.validatesEnvelope(.intent, plan.session));
        try std.testing.expect(child.child.id == null);
    }
    for ([_][]const u8{ "batch", "output", "checkpoint", "write", "shutdown", "ack-hang" }, 0..) |mode, index| {
        var plan = lifecycle.developmentPlan(0, 2 + index, abi);
        plan.hang_timeout_ns = 300 * std.time.ns_per_ms;
        plan.shutdown_grace_ns = 300 * std.time.ns_per_ms;
        var child = try lifecycle.ManagedHost.start(init, "python", "python/test_strategy_host_bounded_child.py", plan, mode, &.{});
        defer child.deinit(init.io);
        try handshake(&child, init.io);
        var healthy = try lifecycle.ManagedHost.start(init, "python", "python/strategy_host.py", lifecycle.developmentPlan(1, 1, abi), "normal", &.{});
        defer healthy.deinit(init.io);
        try handshake(&healthy, init.io);
        const started = std.Io.Clock.awake.now(init.io);
        var pending = try init.io.concurrent(expectTimeout, .{ &child, init.io, mode });
        defer pending.cancel(init.io) catch {};
        try healthy.shutdown(init.io, 3);
        try pending.await(init.io);
        try std.testing.expect(std.Io.Clock.awake.now(init.io).nanoseconds - started.nanoseconds < 2 * std.time.ns_per_s);
        try std.testing.expectEqual(lifecycle.State.stopped, healthy.supervisor.state);
    }
    std.debug.print("strategy_host_bounded_io=passed\n", .{});
}
