//! Public Coordinator Owner recovery and fault boundaries; no transport sends.
const std = @import("std");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const durable = @import("../../../persistence/durable_store.zig");
const history = @import("../../../persistence/business_history.zig");
const codec = @import("../../../persistence/snapshot_codec.zig");
const helpers = @import("../history/coordinator_history_acceptance.zig");

fn summary(index: usize, sequence: u64) coordination.ShardSummary {
    return .{ .shard_id = @enumFromInt(index), .decision_domain = index + 1, .virtual_portfolio = index + 11, .exchange_account = 900, .shard_sequence = sequence, .rules_version = 1, .lease_version = 1, .reservation_atoms = 10, .spot_quantity = 0, .swap_quantity = 0, .cash_atoms = 1000, .open_orders = 0, .unknown_orders = 0, .local_gate_closed = false };
}
fn healthy(identity: u128, barrier: u64) coordination.CoordinationEvent {
    return .{ .margin_observation = .{ .identity = identity, .barrier = barrier, .venue_net_margin_atoms = 0, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 } };
}
fn publishFour(owner: *coordination.CoordinatorOwner, sequence: u64) !void {
    for (0..4) |index| try owner.apply(.{ .publish_summary = .{ .identity = sequence * 4 + index, .summary = summary(index, sequence) } });
}

test "08 coordination safety ten four-shard lease cycles require fresh recovery admission and preserve versions" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    var owner = try coordination.CoordinatorOwner.init(.init(900, 4000, 4000), .{ .domain = .control, .id = 99001 }, memory.interface(), undefined);
    try publishFour(&owner, 1);
    try owner.apply(healthy(1, 4));
    try owner.apply(.{ .allocate_leases = .{ .version = 1, .valid_through_barrier = 1000 } });
    var previous_version: u64 = 1;
    for (0..10) |cycle| {
        try publishFour(&owner, cycle + 2);
        try owner.apply(.{ .allocate_leases = .{ .version = previous_version + 1, .valid_through_barrier = 1000 } });
        try owner.apply(.{ .tighten_leases = .{ .valid_through_barrier = 1000, .requested_limits = @splat(900 - @as(i128, @intCast(cycle))) } });
        previous_version = owner.coordinator.leases[0].version;
        const before = owner.coordinator.digest();
        const sequence = owner.sequence;
        const leases = owner.coordinator.leases;
        try owner.checkpoint();
        owner = try coordination.CoordinatorOwner.recover(owner.stream, memory.interface(), undefined);
        try std.testing.expectEqualDeep(before, owner.coordinator.digest());
        try std.testing.expectEqual(sequence, owner.sequence);
        try std.testing.expectEqualDeep(leases, owner.coordinator.leases);
        try std.testing.expect(owner.coordinator.recovery_only);
        try std.testing.expectError(error.CoordinatorRecoveryOnly, owner.apply(.{ .allocate_leases = .{ .version = previous_version + 1, .valid_through_barrier = 1000 } }));
        try std.testing.expectError(error.CoordinatorRecoveryOnly, owner.apply(.{ .tighten_leases = .{ .valid_through_barrier = 1000, .requested_limits = @splat(1) } }));
        try std.testing.expectEqual(sequence, owner.sequence);
        try std.testing.expectError(error.FreshMarginObservationRequired, owner.completeRecovery());
        try owner.apply(healthy(cycle + 2, owner.coordinator.barrier));
        try owner.completeRecovery();
        try std.testing.expect(!owner.coordinator.recovery_only);
        for (owner.coordinator.leases, 0..) |lease, index| {
            try std.testing.expectEqual(@as(u128, index + 1), lease.decision_domain);
            try std.testing.expectEqual(@as(u128, 900), lease.exchange_account);
            try std.testing.expectEqual(previous_version, lease.version);
            try std.testing.expectEqual(@as(i128, 10), lease.used_atoms);
            try std.testing.expect(lease.limit_atoms <= 900);
        }
        try std.testing.expectError(error.StaleRiskLease, owner.apply(.{ .allocate_leases = .{ .version = previous_version - 1, .valid_through_barrier = 1000 } }));
    }
}

test "08 coordination safety expired lease cannot gain authority through snapshot or fresh margin" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    var owner = try coordination.CoordinatorOwner.init(.init(900, 4000, 4000), .{ .domain = .control, .id = 99002 }, memory.interface(), undefined);
    try publishFour(&owner, 1);
    try owner.apply(healthy(1, 4));
    try owner.apply(.{ .allocate_leases = .{ .version = 7, .valid_through_barrier = 4 } });
    const original = owner.coordinator.leases;
    try publishFour(&owner, 2);
    try owner.checkpoint();
    owner = try coordination.CoordinatorOwner.recover(owner.stream, memory.interface(), undefined);
    try owner.apply(healthy(2, 8));
    try std.testing.expectError(error.RiskLeaseExpired, owner.completeRecovery());
    try std.testing.expectError(error.CoordinatorRecoveryOnly, owner.apply(.{ .allocate_leases = .{ .version = 8, .valid_through_barrier = 100 } }));
    try std.testing.expectEqualDeep(original, owner.coordinator.leases);
    try std.testing.expect(owner.coordinator.recovery_only);
    try std.testing.expectEqual(@as(u64, 7), owner.coordinator.leases[0].version);
}

// An I/O boundary failure leaves the persisted MemoryAdapter available to the
// next process. The failed Owner is latched and discarded; no store gate reset.
fn failCommit(_: *anyopaque, _: std.Io, _: durable.StreamIdentity, _: u64) anyerror!void {
    return error.InputOutput;
}
fn failSeal(_: *anyopaque, _: std.Io, _: durable.StreamIdentity) anyerror!void {
    return error.InputOutput;
}
fn failPublish(_: *anyopaque, _: std.Io, _: durable.StreamIdentity, _: u64, _: []const u8) anyerror!void {
    return error.InputOutput;
}
fn failRotate(_: *anyopaque, _: std.Io, _: durable.StreamIdentity) anyerror!void {
    return error.InputOutput;
}
fn failAfterRotate(ptr: *anyopaque, io: std.Io, stream: durable.StreamIdentity) anyerror!void {
    const memory: *durable.MemoryAdapter = @ptrCast(@alignCast(ptr));
    try memory.interface().rotate(io, stream);
    return error.InputOutput;
}

fn sourceFault(point: durable.FaultPoint) !void {
    const harness = try helpers.createForcedHarness(0);
    defer harness.destroy();
    var owner = try helpers.createSingleAppliedForcedSource(harness);
    const source = try owner.coordinator.prepareForcedSourceHistory();
    const economic = harness.owner.shard.economicSummary();
    try owner.checkpoint();
    var fault_vtable = harness.backend.memory.interface().vtable.*;
    switch (point) {
        .commit => fault_vtable.commit = failCommit,
        .seal => fault_vtable.seal = failSeal,
        .publish => fault_vtable.publish = failPublish,
        .rotate => fault_vtable.rotate = failRotate,
        .reclaim => fault_vtable.rotate = failAfterRotate,
        else => unreachable,
    }
    const fault_store: durable.Store = .{ .context = &harness.backend.memory, .vtable = &fault_vtable };
    if (point == .commit) {
        owner.store = fault_store;
        try std.testing.expectError(error.InputOutput, owner.archiveForcedSource());
        try std.testing.expectEqualDeep(source, try owner.coordinator.prepareForcedSourceHistory());
    } else {
        _ = try owner.archiveForcedSource();
        owner.store = fault_store;
        try std.testing.expectError(error.InputOutput, owner.checkpoint());
        try std.testing.expectEqual(@as(u8, 0), owner.coordinator.forced_allocation_count);
    }
    try std.testing.expect(owner.closed);
    const recovered = try coordination.CoordinatorOwner.recover(owner.stream, harness.backend.memory.interface(), undefined);
    try std.testing.expect(recovered.coordinator.recovery_only);
    if (point == .commit) {
        try std.testing.expectEqualDeep(source, try recovered.coordinator.prepareForcedSourceHistory());
    } else {
        const root = recovered.coordinator.history_root.?;
        const request: history.LookupRequest = .{ .pending_id = 1, .key = .{ .origin = root.origin, .identity = .{ .coordinator_forced_source = source.source.identity } }, .candidate_payload_digest = @splat(0), .original_input_digest = root.qualification_digest, .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
        const result = try harness.backend.memory.interface().queryOrderHistory(undefined, request);
        try history.validateRecord(&result);
        try std.testing.expectEqualDeep(source, try codec.decodeBare(result.record_bytes[0..result.record_len], coordination.ForcedSourceHistory));
    }
    try std.testing.expectEqualDeep(economic, harness.owner.shard.economicSummary());
    try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.send_attempt_count);
}

test "08 coordination safety source commit fault preserves closure economics and recovery" {
    try sourceFault(.commit);
}

test "08 coordination safety source seal fault preserves closure economics and recovery" {
    try sourceFault(.seal);
}

test "08 coordination safety source publish fault preserves closure economics and recovery" {
    try sourceFault(.publish);
}

test "08 coordination safety source rotate fault preserves closure economics and recovery" {
    try sourceFault(.rotate);
}

test "08 coordination safety source reclaim fault preserves closure economics and recovery" {
    try sourceFault(.reclaim);
}

test "08 coordination safety hot and cold source allocation duplicates never repeat economics" {
    const harness = try helpers.createForcedHarness(0);
    defer harness.destroy();
    var owner = try helpers.createSingleAppliedForcedSource(harness);
    const source = try owner.coordinator.prepareForcedSourceHistory();
    const economic = harness.owner.shard.economicSummary();
    try owner.acceptAccountFact(source.source);
    try owner.allocateForcedExecution(source.allocations[0].allocation);
    try std.testing.expectEqualDeep(source, try owner.coordinator.prepareForcedSourceHistory());
    _ = try owner.archiveForcedSource();
    const root = owner.coordinator.history_root;
    try owner.acceptAccountFact(source.source);
    try owner.allocateForcedExecution(source.allocations[0].allocation);
    try std.testing.expectEqualDeep(root, owner.coordinator.history_root);
    try std.testing.expectEqual(@as(u8, 0), owner.coordinator.forced_allocation_count);
    try std.testing.expectEqualDeep(economic, harness.owner.shard.economicSummary());
    var conflict = source.allocations[0].allocation;
    conflict.slices[0].fee_atoms += 1;
    try std.testing.expectError(error.ForcedExecutionAllocationConflict, owner.allocateForcedExecution(conflict));
    try std.testing.expect(owner.closed);
    try std.testing.expectEqualDeep(economic, harness.owner.shard.economicSummary());
    try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
}

test "08 coordination safety source conflict and missing history keep risk closed" {
    for ([_]bool{ false, true }) |timeout| {
        const harness = try helpers.createForcedHarness(0);
        defer harness.destroy();
        var owner = try helpers.createSingleAppliedForcedSource(harness);
        const source = try owner.coordinator.prepareForcedSourceHistory();
        const economic = harness.owner.shard.economicSummary();
        _ = try owner.archiveForcedSource();
        if (timeout) {
            harness.backend.stage = .recovery_history_query;
            try std.testing.expectError(error.InjectedQueryTimeout, owner.acceptAccountFact(source.source));
        } else {
            var conflict = source.source;
            conflict.payload.forced_execution.fee_atoms += 1;
            try std.testing.expectError(error.AccountFactIdentityConflict, owner.acceptAccountFact(conflict));
        }
        try std.testing.expect(owner.closed);
        try std.testing.expectEqual(@as(u8, 0), owner.coordinator.forced_allocation_count);
        try std.testing.expectEqualDeep(economic, harness.owner.shard.economicSummary());
        try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
    }
}

test "08 coordination safety invalid source and allocation proofs cannot bind another account" {
    for ([_]bool{ false, true }) |allocation_candidate| {
        const harness = try helpers.createForcedHarness(0);
        defer harness.destroy();
        var owner = try helpers.createSingleAppliedForcedSource(harness);
        const source = try owner.coordinator.prepareForcedSourceHistory();
        _ = try owner.archiveForcedSource();
        const root = owner.coordinator.history_root.?;
        const before = owner.coordinator.digest();
        if (allocation_candidate) {
            const allocation = source.allocations[0].allocation;
            const request = owner.coordinator.allocationHistoryRequest(allocation, owner.sequence + 1);
            var result = try owner.store.queryOrderHistory(undefined, request);
            result.proof.request.key.origin.account += 1;
            try std.testing.expectError(error.InvalidHistoryProof, owner.apply(.{ .forced_history_checked = .{ .allocation = allocation, .proof = result.proof } }));
        } else {
            const request = owner.coordinator.accountFactHistoryRequest(source.source, owner.sequence + 1);
            var result = try owner.store.queryOrderHistory(undefined, request);
            result.proof.request.key.origin.stream.id += 1;
            try std.testing.expectError(error.InvalidHistoryProof, owner.apply(.{ .forced_source_checked = .{ .fact = source.source, .proof = result.proof } }));
        }
        try std.testing.expect(owner.closed);
        try std.testing.expectEqualDeep(root, owner.coordinator.history_root.?);
        try std.testing.expectEqualDeep(before, owner.coordinator.digest());
        try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
    }
}

test "08 coordination safety gateway missing proof and unavailable lookup provide no routing authority" {
    for ([_]bool{ false, true }) |timeout| {
        const harness = try helpers.createForcedHarness(0);
        defer harness.destroy();
        var owner = try helpers.createSingleAppliedForcedSource(harness);
        _ = try owner.archiveForcedSource();
        const request: coordination.GatewayRequest = .{ .exchange_account = 2, .shard_id = .shard_0, .fencing_token = 2, .command = harness.command };
        if (timeout) {
            harness.backend.stage = .recovery_history_query;
            try std.testing.expectError(error.InjectedQueryTimeout, owner.recordGateway(request));
        } else {
            try std.testing.expectError(error.CoordinatorHistoryProofRequired, owner.apply(.{ .gateway_record = .{ .request = request } }));
        }
        try std.testing.expect(owner.closed);
        try std.testing.expectEqual(@as(u8, 0), owner.coordinator.gateway_ownership.count);
        try std.testing.expectEqual(@as(u64, 0), owner.coordinator.gateway_ownership.latest_fencing_tokens[0]);
        try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
    }
}

test "08 coordination safety control namespaces reject economic keys and gateway cross account owner" {
    const control: history.Origin = .{ .stream = .{ .domain = .control, .id = 55 }, .account = 900 };
    try std.testing.expectError(error.InvalidHistoryKey, history.encodeKey(.{ .origin = control, .identity = .{ .order = 1 } }));
    const decision: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 55 }, .account = 900 };
    try std.testing.expectError(error.InvalidHistoryKey, history.encodeKey(.{ .origin = decision, .identity = .{ .coordinator_account_fact = 1 } }));
    const harness = try helpers.createForcedHarness(0);
    defer harness.destroy();
    var owner = try helpers.createSingleAppliedForcedSource(harness);
    const request: coordination.GatewayRequest = .{ .exchange_account = 999, .shard_id = .shard_0, .fencing_token = 2, .command = harness.command };
    try std.testing.expectError(error.CrossAccountGatewayRequest, owner.recordGateway(request));
    try std.testing.expectEqual(@as(u8, 0), owner.coordinator.gateway_ownership.count);
    try std.testing.expectEqual(@as(u64, 0), owner.coordinator.gateway_ownership.latest_fencing_tokens[0]);
    try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
}

test "08 coordination safety retired gateway cold conflict retains fencing high water and never sends" {
    const acceptance = @import("../history/order_gateway_archive_acceptance.zig");
    const fixture = @import("../../support/trading_shard_fixture.zig");
    const trading = @import("../../../trading/trading_shard.zig");
    const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, 99100);
    defer harness.destroy();
    var owner = try coordination.CoordinatorOwner.init(.init(2, 10000000000, 10000000000), .{ .domain = .control, .id = 99103 }, harness.backend.interface(), undefined);
    _ = try harness.owner.apply(fixture.atGroup(19, .{ .identity = 2, .payload = .{ .primary_lease_granted = .{ .fencing_token = 2 } } }));
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 1 };
    group.members[0] = .{ .intent_sequence = 101, .operation = .place, .instrument = 3, .quantity = 1, .limit_price = fixture.omsPrice(3, 50000000) };
    _ = try harness.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .oms_intent_group = group } }));
    const command = harness.owner.shard.oms.emitted()[0];
    try owner.apply(.{ .publish_summary = .{ .identity = 1, .summary = try coordination.shardSummaryFromShard(&harness.owner.shard, .shard_0, 1, 1) } });
    const request: coordination.GatewayRequest = .{ .exchange_account = 2, .shard_id = .shard_0, .fencing_token = 2, .command = command };
    try owner.recordGateway(request);
    try std.testing.expectError(error.DuplicateCommandIdentity, owner.recordGateway(request));
    try std.testing.expectEqual(@as(u8, 1), owner.coordinator.gateway_ownership.count);
    try std.testing.expectError(error.OrderArchiveNotQualified, owner.retireGateway(.shard_0, command.command_id, harness.owner));
    _ = try harness.owner.apply(fixture.atGroup(21, .{ .identity = 102, .payload = .{ .oms_execution_report = .{ .report_id = 102, .order_id = command.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 1 } } }));
    try acceptance.recordTerminalArchiveCoverageFor(harness.owner, command, .canceled, 0);
    try owner.retireGateway(.shard_0, command.command_id, harness.owner);
    try owner.checkpoint();
    owner = try coordination.CoordinatorOwner.recover(owner.stream, harness.backend.interface(), undefined);
    try std.testing.expectEqual(@as(u8, 0), owner.coordinator.gateway_ownership.count);
    try std.testing.expectEqual(@as(u64, 2), owner.coordinator.gateway_ownership.latest_fencing_tokens[0]);
    try std.testing.expectError(error.DuplicateCommandIdentity, owner.recordGateway(request));
    var conflict = request;
    conflict.command.quantity += 1;
    try std.testing.expectError(error.GatewayOutcomeIdentityConflict, owner.recordGateway(conflict));
    try std.testing.expect(owner.closed);
    try std.testing.expectEqual(@as(u8, 0), owner.coordinator.gateway_ownership.count);
    try std.testing.expectEqual(@as(u64, 2), owner.coordinator.gateway_ownership.latest_fencing_tokens[0]);
    try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.send_attempt_count);
}

test "08 coordination safety first checkpoint absent retains only committed prefix and physical suffix" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    var owner = try coordination.CoordinatorOwner.init(.init(900, 4000, 4000), .{ .domain = .control, .id = 99200 }, memory.interface(), undefined);
    try owner.apply(.{ .publish_summary = .{ .identity = 1, .summary = summary(0, 1) } });
    const before = owner.coordinator.digest();
    const sequence = owner.sequence;
    var faults = memory.interface().vtable.*;
    faults.commit = failCommit;
    owner.store = .{ .context = memory, .vtable = &faults };
    try std.testing.expectError(error.InputOutput, owner.apply(.{ .publish_summary = .{ .identity = 2, .summary = summary(0, 2) } }));
    const persisted = try memory.interface().recover(undefined, owner.stream);
    const physical_digest = history.hash(persisted.active_segment);
    try std.testing.expect(persisted.last_sequence > persisted.committed_barrier);
    try std.testing.expectEqual(@as(usize, 0), persisted.snapshot.len);
    var recovered = try coordination.CoordinatorOwner.recover(owner.stream, memory.interface(), undefined);
    try std.testing.expectEqualDeep(before, recovered.coordinator.digest());
    try std.testing.expectEqual(sequence, recovered.sequence);
    try std.testing.expectEqual(@as(u64, 1), recovered.coordinator.summaries[0].value.shard_sequence);
    try std.testing.expect(recovered.closed);
    try std.testing.expect(recovered.coordinator.recovery_only);
    try std.testing.expectError(error.CoordinatorWriterClosed, recovered.apply(.{ .publish_summary = .{ .identity = 3, .summary = summary(0, 2) } }));
    const after = try memory.interface().recover(undefined, owner.stream);
    try std.testing.expectEqual(persisted.last_sequence, after.last_sequence);
    try std.testing.expectEqualDeep(physical_digest, history.hash(after.active_segment));
}

test "08 coordination safety hot source and allocation conflicts pin complete economic evidence" {
    for ([_]bool{ false, true }) |allocation_candidate| {
        const harness = try helpers.createForcedHarness(0);
        defer harness.destroy();
        var owner = try helpers.createSingleAppliedForcedSource(harness);
        const source = try owner.coordinator.prepareForcedSourceHistory();
        const sequence = owner.sequence;
        const economic = harness.owner.shard.economicSummary();
        if (allocation_candidate) {
            var allocation = source.allocations[0].allocation;
            allocation.slices[0].fee_atoms += 1;
            try std.testing.expectError(error.ForcedExecutionAllocationConflict, owner.allocateForcedExecution(allocation));
        } else {
            var fact = source.source;
            fact.payload.forced_execution.fee_atoms += 1;
            try std.testing.expectError(error.AccountFactIdentityConflict, owner.acceptAccountFact(fact));
        }
        try std.testing.expect(owner.closed);
        try std.testing.expectEqual(sequence, owner.sequence);
        try std.testing.expectEqualDeep(source, try owner.coordinator.prepareForcedSourceHistory());
        try std.testing.expectEqualDeep(economic, harness.owner.shard.economicSummary());
        try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
    }
}
