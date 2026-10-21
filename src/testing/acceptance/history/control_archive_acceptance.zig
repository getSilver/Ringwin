//! Public control history acceptance. No network or Venue orders.
const std = @import("std");
const acceptance = @import("order_gateway_archive_acceptance.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const history = @import("../../../persistence/business_history.zig");

fn recover(harness: *acceptance.ArchiveHarness) !void {
    try harness.owner.checkpoint();
    const digest = harness.owner.shard.canonicalStateDigest();
    const restored = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(restored);
    try demo.Owner.recoverInto(restored, harness.backend.interface(), undefined, harness.stream);
    try std.testing.expectEqualDeep(digest, restored.shard.canonicalStateDigest());
    @memcpy(std.mem.asBytes(harness.owner), std.mem.asBytes(restored));
    try harness.gateway.checkpointDurableDispatch();
    harness.gateway.init();
    try harness.gateway.attachRecoveredDurableDispatch(harness.backend.interface(), undefined, harness.dispatch_stream);
}

test "08 control history faults preserve authority active pins and committed roots without sending" {
    for ([_]@TypeOf(@as(acceptance.ArchiveFaultMemory, undefined).stage){ .history_publish, .decision_commit, .gateway_append, .gateway_checkpoint }, 0..) |stage, index| {
        const harness = try create(8900 + index * 2);
        defer harness.destroy();
        _ = try harness.owner.apply(fixture.lifecycleCommand(500, harness.owner.shard.operational_state.version, .cancel_open_orders));
        try harness.owner.checkpoint();
        const before = harness.owner.shard.operational_state;
        const committed = stage == .gateway_append or stage == .gateway_checkpoint;
        harness.backend.stage = stage;
        try std.testing.expectError(if (stage == .decision_commit) error.DecisionLogUnavailable else error.InjectedEio, harness.owner.archiveControlHistory(harness.gateway));
        try std.testing.expect(harness.owner.closed);
        const restored = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(restored);
        const store = harness.backend.memory.interface();
        try demo.Owner.recoverInto(restored, store, undefined, harness.stream);
        try std.testing.expectEqual(before.version, restored.shard.operational_state.version);
        try std.testing.expectEqual(before.mode, restored.shard.operational_state.mode);
        try std.testing.expectEqual(before.trading_authorized, restored.shard.operational_state.trading_authorized);
        try std.testing.expectEqual(@as(u64, 1), restored.shard.fencing_token);
        try std.testing.expectEqual(committed, restored.shard.last_control_archive != null);
        if (!committed) try std.testing.expectEqual(before.command_count, restored.shard.operational_state.command_count);
        const gateway = try std.testing.allocator.create(execution.Gateway);
        defer std.testing.allocator.destroy(gateway);
        gateway.init();
        try gateway.attachRecoveredDurableDispatch(store, undefined, harness.dispatch_stream);
        if (committed) {
            try gateway.acknowledgeEconomicHistory(&restored.shard);
            const once = try store.recover(undefined, harness.dispatch_stream);
            try gateway.acknowledgeEconomicHistory(&restored.shard);
            try std.testing.expectEqual(once.last_sequence, (try store.recover(undefined, harness.dispatch_stream)).last_sequence);
        }
        try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
    }
}

fn unavailable(_: *anyopaque, _: std.Io, _: history.LookupRequest) anyerror!history.LookupResult {
    return error.SyncTimeout;
}

test "08 control cold duplicate expiry conflict and unavailable proof never revive authority" {
    const harness = try create(8950);
    defer harness.destroy();
    const command = fixture.lifecycleCommand(600, harness.owner.shard.operational_state.version, .cancel_open_orders);
    _ = try harness.owner.apply(command);
    _ = try harness.owner.archiveControlHistory(harness.gateway);
    const version = harness.owner.shard.operational_state.version;
    _ = try harness.owner.apply(command);
    try std.testing.expectEqual(version, harness.owner.shard.operational_state.version);
    var expired = command;
    expired.core.wall_time = expired.core.payload.control_command.expires_at;
    expired.core.payload.control_command.expires_at -= 1;
    try std.testing.expectError(error.ControlCommandExpired, harness.owner.apply(expired));
    try std.testing.expectEqual(version, harness.owner.shard.operational_state.version);
    // Expiry validation is a rejected caller input; use a separate writer for proof failures.
    const other = try create(8960);
    defer other.destroy();
    const original = fixture.lifecycleCommand(700, other.owner.shard.operational_state.version, .cancel_open_orders);
    _ = try other.owner.apply(original);
    _ = try other.owner.archiveControlHistory(other.gateway);
    var vtable = other.owner.store.vtable.*;
    vtable.query_order_history = unavailable;
    other.owner.store.vtable = &vtable;
    try std.testing.expectError(error.HistoryLookupDeferred, other.owner.apply(original));
    try std.testing.expect(other.owner.shard.pending_safety_history_candidate != null or other.owner.shard.pending_history_candidate != null);
    try std.testing.expectEqual(@as(u64, 0), other.gateway.send_attempt_count);
    other.owner.store = other.backend.interface();
    _ = try other.owner.resolveColdCandidate();
    var conflict = original;
    conflict.core.payload.control_command.content_hash += 1;
    _ = try other.owner.apply(conflict);
    try std.testing.expect(other.owner.shard.history_conflict_latched);
    try std.testing.expect(!other.owner.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expect(other.owner.shard.oms.recovery_only);
    try recover(other);
    try std.testing.expect(other.owner.shard.history_conflict_latched);
}

test "08 eighty committed Core cutovers continue independent activation history and retire old fences" {
    const cutover = @import("../../../runtime/cutover_history.zig");
    const event = @import("../../../trading/trading_shard_event.zig");
    const harness = try create(8970);
    defer harness.destroy();
    var owner = try cutover.Owner.init(harness.backend.interface(), .{ .stream = .{ .domain = .control, .id = 200000 }, .account = 2 });
    var first: event.VersionActivationEvent = undefined;
    for (1..81) |generation| {
        const previous = harness.owner.shard.active_strategy_instance;
        if (previous != 0) _ = try harness.owner.apply(.{ .core = .{ .identity = generation, .payload = .{ .strategy_cutover_fence = .{ .strategy_instance = previous } } } });
        const activation: event.VersionActivationEvent = .{ .activation_identity = generation, .generation = generation, .old_release = harness.owner.shard.active_release, .new_release = generation + 100, .old_strategy_instance = previous, .new_strategy_instance = generation + 1000, .strategy_definition = 1, .parameter_version = 1, .state_schema_version = @import("../../../trading/trading_shard.zig").state_schema_version, .transition = .keep, .barrier = harness.owner.shard.authoritativeBarrier() + 1, .canonical_state_digest = harness.owner.shard.canonicalStateDigest() };
        if (generation == 1) first = activation;
        _ = try harness.owner.apply(.{ .core = .{ .identity = generation, .payload = .{ .version_activation = activation } } });
        try std.testing.expectEqual(@as(u64, generation), harness.owner.shard.release_generation);
        try owner.recordActivation(undefined, activation);
        _ = try harness.owner.archiveControlHistory(harness.gateway);
        try std.testing.expectEqual(@as(u8, 0), harness.owner.shard.fenced_strategy_count);
        if (generation % 8 == 0) {
            try owner.archive(undefined);
            try owner.checkpoint(undefined);
            owner = try cutover.Owner.recover(harness.backend.interface(), undefined, owner.origin);
            try recover(harness);
            try std.testing.expectEqual(owner.state.generation, harness.owner.shard.release_generation);
            try std.testing.expectEqual(owner.state.active_release, harness.owner.shard.active_release);
            try std.testing.expectEqual(owner.state.active_strategy_instance, harness.owner.shard.active_strategy_instance);
            try std.testing.expectEqual(owner.state.active_state_schema_version, @import("../../../trading/trading_shard.zig").state_schema_version);
        }
    }
    try owner.recordActivation(undefined, first);
    try std.testing.expectEqual(@as(u64, 80), owner.state.generation);
    var retired = first;
    retired.activation_identity = 81;
    retired.generation = 81;
    retired.old_release = harness.owner.shard.active_release;
    retired.old_strategy_instance = harness.owner.shard.active_strategy_instance;
    retired.barrier = harness.owner.shard.authoritativeBarrier() + 1;
    retired.canonical_state_digest = harness.owner.shard.canonicalStateDigest();
    _ = try harness.owner.apply(.{ .core = .{ .identity = 81, .payload = .{ .version_activation = retired } } });
    try std.testing.expectEqual(@as(u64, 80), harness.owner.shard.release_generation);
    try std.testing.expect(harness.owner.shard.history_conflict_latched);
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.send_attempt_count);
}

test "08 archived EnableTrading never restores stopped authority and expired authorization stays rejected" {
    const harness = try create(8980);
    defer harness.destroy();
    _ = try harness.owner.apply(fixture.lifecycleCommand(9000, harness.owner.shard.operational_state.version, .trading_pause));
    _ = try harness.owner.apply(.{ .core = .{ .identity = 9000, .payload = .{ .lifecycle_progress = .{ .operation_identity = 9000, .target_identity = 1, .open_orders_closed = true, .reconciliation_complete = true, .position_quantity = 0 } } } });
    var enable = fixture.lifecycleCommand(9001, harness.owner.shard.operational_state.version, .enable_trading);
    enable.core.wall_time = 1;
    enable.core.payload.control_command.expires_at = 100;
    _ = try harness.owner.apply(enable);
    _ = try harness.owner.apply(fixture.lifecycleCommand(9002, harness.owner.shard.operational_state.version, .stop_keep_positions));
    _ = try harness.owner.archiveControlHistory(harness.gateway);
    const version = harness.owner.shard.operational_state.version;
    _ = try harness.owner.apply(enable);
    try std.testing.expectEqual(version, harness.owner.shard.operational_state.version);
    try std.testing.expect(!harness.owner.shard.operational_state.trading_authorized);
    try std.testing.expectEqual(@import("../../../trading/operational.zig").OperationalMode.stopped, harness.owner.shard.operational_state.mode);
    try recover(harness);
    _ = try harness.owner.apply(enable);
    try std.testing.expect(!harness.owner.shard.operational_state.trading_authorized);
    enable.core.wall_time = 101;
    try std.testing.expectError(error.ControlCommandExpired, harness.owner.apply(enable));
    try std.testing.expectEqual(version, harness.owner.shard.operational_state.version);
    try std.testing.expect(!harness.owner.shard.operational_state.effectiveTradingAuthority());
}

test "08 control archive preserves an active operation and unresolved closed gate through recovery" {
    const harness = try create(8990);
    defer harness.destroy();
    _ = try harness.owner.apply(fixture.lifecycleCommand(700, harness.owner.shard.operational_state.version, .trading_pause));
    _ = try harness.owner.apply(.{ .core = .{ .identity = 800, .payload = .{ .safety_gate_change = .{ .gate_identity = 800, .target_identity = 1, .kind = .latched, .reason = .reconciliation_break, .open = false } } } });
    _ = try harness.owner.archiveControlHistory(harness.gateway);
    try std.testing.expectEqual(@as(u128, 700), harness.owner.shard.operational_state.active_operation_identity);
    try std.testing.expectEqual(@as(u8, 1), harness.owner.shard.operational_state.latch_count);
    try std.testing.expect(!harness.owner.shard.operational_state.latches[0].resolved);
    try std.testing.expectError(error.ControlHistoryPinned, harness.owner.archiveControlHistory(harness.gateway));
    try recover(harness);
    try std.testing.expectEqual(@as(u128, 700), harness.owner.shard.operational_state.active_operation_identity);
    try std.testing.expectEqual(@as(u8, 1), harness.owner.shard.operational_state.latch_count);
    try std.testing.expect(!harness.owner.shard.operational_state.effectiveTradingAuthority());
}

fn create(id: u64) !*acceptance.ArchiveHarness {
    const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, id);
    errdefer harness.destroy();
    harness.stream.id += 20000;
    try demo.Owner.bootstrapInto(harness.owner, harness.backend.interface(), undefined, harness.stream);
    for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged)) |event| _ = try harness.owner.apply(event);
    try harness.owner.sealBootstrap();
    return harness;
}

test "Owner control history crosses command gate latch and strategy fence bounds through recovery" {
    const harness = try create(8801);
    defer harness.destroy();
    for (0..10) |round| {
        std.debug.print("control commands round {d}\n", .{round});
        for (0..32) |offset| {
            const id: u64 = 1000 + round * 32 + offset;
            _ = try harness.owner.apply(.{ .core = .{ .identity = id, .wall_time = 1, .payload = .{ .control_command = .{ .command_identity = id, .content_hash = id, .target_identity = 1, .expected_version = harness.owner.shard.operational_state.version, .expires_at = 99999, .kind = .cancel_open_orders } } } });
            // Reclaim each completed record; authority command from Genesis stays pinned.
            _ = try harness.owner.archiveControlHistory(harness.gateway);
            if (offset % 8 == 7) try harness.owner.checkpoint();
        }
        try recover(harness);
    }
    try std.testing.expect(harness.owner.shard.archived_control_records >= 320);

    for (0..10) |round| {
        std.debug.print("control pause/resume round {d}\n", .{round});
        const pause_id = 5000 + round * 2;
        _ = try harness.owner.apply(fixture.lifecycleCommand(pause_id, harness.owner.shard.operational_state.version, .trading_pause));
        try std.testing.expect(!harness.owner.shard.operational_state.trading_authorized);
        _ = try harness.owner.apply(.{ .core = .{ .identity = pause_id, .payload = .{ .lifecycle_progress = .{ .operation_identity = pause_id, .target_identity = 1, .open_orders_closed = true, .reconciliation_complete = true, .position_quantity = 0 } } } });
        _ = try harness.owner.apply(fixture.lifecycleCommand(pause_id + 1, harness.owner.shard.operational_state.version, .enable_trading));
        try std.testing.expect(harness.owner.shard.operational_state.effectiveTradingAuthority());
        _ = try harness.owner.archiveControlHistory(harness.gateway);
        try recover(harness);
    }

    for (0..10) |round| {
        std.debug.print("control gates/latches round {d}\n", .{round});
        for (0..16) |offset| {
            const id: u64 = 10000 + round * 16 + offset;
            _ = try harness.owner.apply(.{ .core = .{ .identity = id, .payload = .{ .safety_gate_change = .{ .gate_identity = id, .target_identity = 1, .kind = .latched, .reason = .reconciliation_break, .open = false } } } });
            try std.testing.expect(!harness.owner.shard.operational_state.effectiveTradingAuthority());
            var resolve = fixture.lifecycleCommand(id + 10000, harness.owner.shard.operational_state.version, .resolve_latch);
            resolve.core.payload.control_command.referenced_latch_identity = id;
            _ = try harness.owner.apply(resolve);
            _ = try harness.owner.apply(.{ .core = .{ .identity = id, .payload = .{ .safety_gate_change = .{ .gate_identity = id, .target_identity = 1, .kind = .latched, .reason = .reconciliation_break, .open = true } } } });
            // Explicit reauthorization replaces the resolving command's authority reference.
            _ = try harness.owner.apply(fixture.lifecycleCommand(id + 20000, harness.owner.shard.operational_state.version, .enable_trading));
            _ = try harness.owner.archiveControlHistory(harness.gateway);
            try std.testing.expectEqual(@as(u8, 0), harness.owner.shard.operational_state.latch_count);
            if (offset % 4 == 3) try harness.owner.checkpoint();
        }
        try recover(harness);
    }
    for (0..10) |round| {
        std.debug.print("control fences round {d}\n", .{round});
        for (0..8) |offset| {
            const id: u64 = 30000 + round * 8 + offset;
            _ = try harness.owner.apply(.{ .core = .{ .identity = id, .payload = .{ .strategy_cutover_fence = .{ .strategy_instance = id } } } });
        }
        _ = try harness.owner.archiveControlHistory(harness.gateway);
        try std.testing.expectEqual(@as(u8, 0), harness.owner.shard.fenced_strategy_count);
        try recover(harness);
    }
    const version = harness.owner.shard.operational_state.version;
    _ = try harness.owner.apply(.{ .core = .{ .identity = 1000, .wall_time = 1, .payload = .{ .control_command = .{ .command_identity = 1000, .content_hash = 1000, .target_identity = 1, .expected_version = 3, .expires_at = 99999, .kind = .cancel_open_orders } } } });
    try std.testing.expectEqual(version, harness.owner.shard.operational_state.version);
    _ = try harness.owner.apply(.{ .core = .{ .identity = 30000, .payload = .{ .strategy_activated = .{ .strategy_identity = 30000, .activation_identity = 44, .config_version = 1 } } } });
    try std.testing.expectEqual(@as(u128, 1), harness.owner.shard.strategy_identity);
    try std.testing.expectEqual(@as(u64, 1), harness.owner.shard.fencing_token);
}
