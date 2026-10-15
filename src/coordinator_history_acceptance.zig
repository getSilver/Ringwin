//! Four real authoritative Owners share one coordinator; no Venue sends.
const std = @import("std");
const coordination = @import("account_coordinator.zig");
const acceptance = @import("order_gateway_archive_acceptance.zig");
const fixture = @import("trading_shard_fixture.zig");
const demo = @import("demo_authority.zig");
const canonical = @import("canonical_event.zig");
const windows = @import("reconciliation_archive_acceptance.zig");
const economics = @import("economics.zig");
const codec = @import("snapshot_codec.zig");
const history = @import("business_history.zig");
const execution = @import("execution_gateway.zig");

pub fn createForcedHarness(index: usize) !*acceptance.ArchiveHarness {
    const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, 90000 + index * 10);
    errdefer harness.destroy();
    // Bounded synthetic disk for complete four-shard source/proof retention.
    harness.backend.memory.archive_quota = 128 * 1024 * 1024;
    harness.stream.id += 10000;
    try demo.Owner.bootstrapInto(harness.owner, harness.backend.interface(), undefined, harness.stream);
    for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged)) |original| {
        var input = original;
        if (input.core.payload == .virtual_portfolio_activated) input.core.payload.virtual_portfolio_activated.portfolio_identity = index + 11;
        _ = try harness.owner.apply(input);
    }
    _ = try harness.owner.apply(fixture.atGroup(12, .{ .identity = 3, .payload = .{ .host_activated = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .session = .{ .fencing = 1, .shard = @intCast(index), .generation = 1 }, .activation_barrier = 0, .state_digest = harness.owner.shard.canonicalStateDigest() } } }));
    try acceptance.bootstrapArchiveAccountFor(harness.owner, &.{}, 3);
    var book = fixture.snapshotAt(15, 2);
    book.venue.envelope.identity.stream = 7;
    book.venue.envelope.source_stream = 7;
    book.venue.envelope.raw_evidence.stream = 7;
    _ = try harness.owner.apply(book);
    try harness.owner.sealBootstrap();
    const command = (try harness.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .timer = .{ .side = .buy, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 400, .limit_price_micros = 50_000_000 } } }))).?;
    harness.command = harness.owner.shard.oms.command_history[0];
    _ = try harness.owner.apply(fixture.atGroup(21, .{ .identity = 8001, .payload = .{ .economic_fill = .{ .fill_id = 8001, .order_id = command.order_id, .quantity = 400, .price_ticks = 50_000_000 } } }));
    _ = try harness.owner.apply(fixture.atGroup(22, .{ .identity = 8002, .payload = .{ .oms_execution_report = .{ .report_id = 8002, .order_id = command.order_id, .revision = 1, .status = .filled, .cumulative_quantity = 400, .remaining_quantity = 0 } } }));
    try acceptance.recordTerminalArchiveCoverageFor(harness.owner, harness.command, .filled, 400);
    try acceptance.archiveOrderFills(harness.owner, harness.gateway, command.order_id);
    _ = try harness.owner.archiveTerminalOrder(command.order_id, harness.gateway);
    return harness;
}

fn recoverShard(harness: *acceptance.ArchiveHarness) !void {
    try harness.owner.checkpoint();
    const before = harness.owner.shard.canonicalStateDigest();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream);
    try std.testing.expectEqualDeep(before, recovered.shard.canonicalStateDigest());
    @memcpy(std.mem.asBytes(harness.owner), std.mem.asBytes(recovered));
    harness.gateway.init();
    try harness.gateway.attachRecoveredDurableDispatch(harness.backend.interface(), undefined, harness.dispatch_stream);
}

pub fn createSingleAppliedForcedSource(harness: *acceptance.ArchiveHarness) !coordination.CoordinatorOwner {
    var owner = try coordination.CoordinatorOwner.init(coordination.AccountCoordinator.init(2, 10_000_000_000, 10_000_000_000), .{ .domain = .control, .id = 110001 }, harness.backend.interface(), undefined);
    try harness.owner.bindAccountCoordinator(&owner);
    try owner.apply(.{ .publish_summary = .{ .identity = 1, .summary = try coordination.shardSummaryFromShard(&harness.owner.shard, .shard_0, 1, 1) } });
    const clock = fixture.atGroup(4039, .{ .identity = 1, .payload = .recovery_completed }).core;
    try owner.acceptAccountFact(.{ .identity = 1000, .exchange_account = 2, .version = 1, .barrier = 1, .times = .{ .source = clock.source_time, .receive = clock.receive_time, .monotonic = clock.monotonic_time, .wall = clock.wall_time, .presence = clock.time_presence }, .payload = .{ .forced_execution = .{ .owner = null, .quantity = -1, .price_ticks = 50_000_000, .fee_atoms = 1, .penalty_atoms = 1 } } });
    var allocation: coordination.ForcedExecutionAllocation = .{ .identity = 2000, .forced_execution_identity = 1000, .count = 1 };
    allocation.slices[0] = .{ .owner = .shard_0, .quantity = -1, .position_delta = -1, .fee_atoms = 1, .penalty_atoms = 1 };
    try owner.allocateForcedExecution(allocation);
    const delivery = (try owner.coordinator.pendingForcedDeliveries())[0];
    try std.testing.expectError(error.ForcedDeliveryNotCommitted, owner.ackForcedDelivery(delivery, harness.owner));
    _ = try harness.owner.apply(.{ .core = try coordination.accountFactEvent(delivery) });
    try owner.ackForcedDelivery(delivery, harness.owner);
    return owner;
}

test "08 forced archive publication Core Gateway checkpoint and query faults retain full economics and never send" {
    for ([_]@TypeOf(@as(acceptance.ArchiveFaultMemory, undefined).stage){ .history_publish, .decision_commit, .gateway_append, .gateway_checkpoint }, 0..) |stage, index| {
        _ = index;
        std.debug.print("forced archive fault {s}\n", .{@tagName(stage)});
        const harness = try createForcedHarness(0);
        defer harness.destroy();
        var coordinator = try createSingleAppliedForcedSource(harness);
        _ = try coordinator.archiveForcedSource();
        try harness.owner.checkpoint();
        const before = harness.owner.shard.economicSummary();
        const committed = stage == .gateway_append or stage == .gateway_checkpoint;
        harness.backend.stage = stage;
        try std.testing.expectError(if (stage == .decision_commit) error.DecisionLogUnavailable else error.InjectedEio, harness.owner.archiveForcedExecutionHistory(8001, &coordinator, harness.gateway));
        try std.testing.expect(harness.owner.closed);
        const restored = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(restored);
        const store = harness.backend.memory.interface();
        try demo.Owner.recoverInto(restored, store, undefined, harness.stream);
        var after = restored.shard.economicSummary();
        after.ledger_transactions = before.ledger_transactions;
        try std.testing.expectEqualDeep(before, after);
        try std.testing.expectEqual(@as(u64, if (committed) 1 else 0), restored.shard.economic_projection.archived_forced_count);
        try std.testing.expectEqual(@as(u8, if (committed) 0 else 1), restored.shard.economic_projection.applied_forced_execution_count);
        const gateway = try std.testing.allocator.create(execution.Gateway);
        defer std.testing.allocator.destroy(gateway);
        gateway.init();
        try gateway.attachRecoveredDurableDispatch(store, undefined, harness.dispatch_stream);
        if (committed) try gateway.acknowledgeEconomicHistory(&restored.shard);
        try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
    }
}

test "08 coordinator source publication commit and recovery preserve closure masks and forbid premature release" {
    for ([_]@TypeOf(@as(acceptance.ArchiveFaultMemory, undefined).stage){ .history_publish, .gateway_append }, 0..) |stage, index| {
        _ = index;
        const harness = try createForcedHarness(0);
        defer harness.destroy();
        var owner = try createSingleAppliedForcedSource(harness);
        try owner.checkpoint();
        const before = owner.coordinator.digest();
        harness.backend.stage = stage;
        try std.testing.expectError(error.InjectedEio, owner.archiveForcedSource());
        try std.testing.expect(owner.closed);
        try std.testing.expectEqualDeep(before, owner.coordinator.digest());
        const restored = try coordination.CoordinatorOwner.recover(owner.stream, harness.backend.memory.interface(), undefined);
        try std.testing.expectEqualDeep(before, restored.coordinator.digest());
        try std.testing.expect(restored.coordinator.recovery_only);
        if (stage == .gateway_append) try std.testing.expect(restored.closed);
        try std.testing.expectEqual(@as(u8, 1), restored.coordinator.forced_allocation_count);
        try std.testing.expectEqual(@as(u8, 1), restored.coordinator.forced_allocations[0].delivered_mask);
        try std.testing.expectEqual(@as(u8, 1), harness.owner.shard.economic_projection.applied_forced_execution_count);
        try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
    }
}

test "08 four shared account Owners preserve 320 forced sources allocations postings and acknowledgements across history recovery" {
    var shards: [4]*acceptance.ArchiveHarness = undefined;
    for (&shards, 0..) |*shard, index| shard.* = try createForcedHarness(index);
    defer for (shards) |shard| shard.destroy();
    var owner = try coordination.CoordinatorOwner.init(coordination.AccountCoordinator.init(2, 10_000_000_000, 10_000_000_000), .{ .domain = .control, .id = 110000 }, shards[0].backend.interface(), undefined);
    for (shards) |shard| try shard.owner.bindAccountCoordinator(&owner);
    for (0..320) |round| {
        if (round % 32 == 0) std.debug.print("forced history window {d}\n", .{round / 32});
        for (shards, 0..) |shard, index| {
            const summary = try coordination.shardSummaryFromShard(&shard.owner.shard, @enumFromInt(index), round + 1, index + 1);
            try owner.apply(.{ .publish_summary = .{ .identity = 100 + round * 4 + index, .summary = summary } });
        }
        const clock = fixture.atGroup(4039 + round * 2, .{ .identity = 1, .payload = .recovery_completed }).core;
        const fact: coordination.AccountFact = .{ .identity = 1000 + round, .exchange_account = 2, .version = round + 1, .barrier = round + 1, .times = .{ .source = clock.source_time, .receive = clock.receive_time, .monotonic = clock.monotonic_time, .wall = clock.wall_time, .presence = clock.time_presence }, .payload = .{ .forced_execution = .{ .owner = null, .quantity = -4, .price_ticks = 50_000_000, .fee_atoms = 4, .penalty_atoms = 4 } } };
        try owner.acceptAccountFact(fact);
        var allocation: coordination.ForcedExecutionAllocation = .{ .identity = 2000 + round, .forced_execution_identity = fact.identity, .count = 4 };
        for (&allocation.slices, 0..) |*slice, index| slice.* = .{ .owner = @enumFromInt(index), .quantity = -1, .position_delta = -1, .fee_atoms = 1, .penalty_atoms = 1 };
        try owner.allocateForcedExecution(allocation);
        var deliveries: [4]coordination.Delivery = undefined;
        @memcpy(&deliveries, try owner.coordinator.pendingForcedDeliveries());
        try std.testing.expectError(error.ForcedSourceNotClosed, owner.archiveForcedSource());
        for (deliveries, 0..) |delivery, index| {
            try std.testing.expectEqual(@as(u8, @intCast(index)), @intFromEnum(delivery.shard_id));
            _ = try shards[index].owner.apply(.{ .core = try coordination.accountFactEvent(delivery) });
            try owner.ackForcedDelivery(delivery, shards[index].owner);
        }
        const closed = try owner.archiveForcedSource();
        try std.testing.expectEqual(@as(u8, 0), owner.coordinator.forced_allocation_count);
        for (shards, deliveries, 0..) |shard, delivery, index| {
            const id: u64 = @intCast(delivery.fact.identity);
            const applied = shard.owner.shard.economic_projection.applied_forced_executions[0];
            const ledger_before = shard.owner.shard.economic_projection.ledger;
            const ledger_count_before = shard.owner.shard.economic_projection.ledger_count;
            const economic_before = shard.owner.shard.economicSummary();
            const summary_before = shard.owner.shard.economic_projection.ledger_summary;
            const root = try shard.owner.archiveForcedExecutionHistory(id, &owner, shard.gateway);
            var economic_after = shard.owner.shard.economicSummary();
            economic_after.ledger_transactions = economic_before.ledger_transactions;
            try std.testing.expectEqualDeep(economic_before, economic_after);
            try std.testing.expectEqualDeep(summary_before, shard.owner.shard.economic_projection.ledger_summary);
            const request: history.LookupRequest = .{ .pending_id = id, .key = .{ .origin = root.origin, .identity = .{ .forced_detail = id } }, .candidate_payload_digest = @splat(0), .original_input_digest = root.qualification_digest, .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
            const result = try shard.backend.interface().queryOrderHistory(undefined, request);
            _ = try history.verifyResult(request, &result.proof, root);
            try history.validateRecord(&result);
            const qualification = try codec.decodeBare(result.record_bytes[0..result.record_len], economics.ForcedArchiveQualification);
            try std.testing.expectEqualDeep(applied, qualification.record.applied);
            try std.testing.expectEqualDeep(closed.root, qualification.closure.coordinator_root);
            try std.testing.expectEqual(@as(u8, 6), qualification.record.ledger_count);
            try std.testing.expectEqual(ledger_count_before, qualification.record.ledger_count);
            for (ledger_before[0..ledger_count_before], qualification.record.ledger[0..qualification.record.ledger_count]) |expected, actual| {
                try std.testing.expectEqual(expected.source_identity, actual.source_identity);
                try std.testing.expectEqual(expected.kind, actual.kind);
                try std.testing.expectEqual(expected.layer, actual.layer);
                try std.testing.expectEqual(expected.posting_count, actual.posting_count);
                try std.testing.expectEqualDeep(expected.postings[0..expected.posting_count], actual.postings[0..actual.posting_count]);
            }
            for (qualification.record.ledger[0..qualification.record.ledger_count]) |transaction| {
                var sum: i128 = 0;
                for (transaction.postings[0..transaction.posting_count]) |posting| sum += posting.amount;
                try std.testing.expectEqual(@as(i128, 0), sum);
            }
            const resolve = fixture.resolveLatchCommand(30000 + round * 4 + index, shard.owner.shard.operational_state.version, id);
            _ = try shard.owner.apply(resolve);
            _ = try shard.owner.apply(.{ .core = .{ .identity = id, .payload = .{ .safety_gate_change = .{ .gate_identity = id, .target_identity = 1, .kind = .latched, .reason = .venue_forced_execution, .open = true } } } });
            _ = try shard.owner.apply(fixture.lifecycleCommand(40000 + round * 4 + index, shard.owner.shard.operational_state.version, .stop_keep_positions));
            _ = try shard.owner.archiveControlHistory(shard.gateway);
            var facts: [2]canonical.EconomicFactRef = undefined;
            var count: usize = 0;
            if (round == 0) {
                // The original owned Fill is included exactly once in the initial window.
                const fill_request: history.LookupRequest = .{ .pending_id = id, .key = .{ .origin = root.origin, .identity = .{ .fill_economic_digest = 8001 } }, .candidate_payload_digest = @splat(0), .original_input_digest = root.qualification_digest, .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
                const fill_result = try shard.backend.interface().queryOrderHistory(undefined, fill_request);
                try history.validateRecord(&fill_result);
                facts[count] = .{ .identity = 8001, .kind = .fill, .digest = try codec.decodeBare(fill_result.record_bytes[0..fill_result.record_len], history.Digest), .fee_confirmed = true };
                count += 1;
            }
            facts[count] = .{ .identity = id, .kind = .forced, .digest = applied.payload_digest, .fee_confirmed = true };
            count += 1;
            const window = windows.windowInput(shard, 2000 + round, facts[0..count]);
            _ = try shard.owner.apply(window);
            _ = try shard.owner.archiveReconciliationWindowHistory(window.venue.event.account_reconciliation_result.identity, shard.gateway);
            try std.testing.expectEqual(@as(u64, round + 1), shard.owner.shard.economic_projection.archived_forced_count);
            try std.testing.expectEqual(@as(u64, round + 2), shard.owner.shard.reconciliation_cursor.?.closed_economic_fact_count);
            try std.testing.expectEqual(@as(i64, @intCast(399 - round)), shard.owner.shard.economicSummary().portfolio.swap.quantity);
            try std.testing.expectEqual(@as(u128, index + 11), shard.owner.shard.portfolio_identity);
            try std.testing.expectEqual(@as(u64, 0), shard.simulator.sends);
            if (round % 4 == 3) try recoverShard(shard);
        }
        if (round % 4 == 3) {
            const before = owner.coordinator.digest();
            try owner.checkpoint();
            owner = try coordination.CoordinatorOwner.recover(owner.stream, owner.store, owner.io);
            try std.testing.expectEqualDeep(before, owner.coordinator.digest());
        }
    }
    try std.testing.expectEqual(@as(usize, 0), (try owner.coordinator.pendingForcedDeliveries()).len);
}

test "08 forced closure rejects a valid same account proof from another Coordinator stream" {
    const harness = try createForcedHarness(0);
    defer harness.destroy();
    var expected = try createSingleAppliedForcedSource(harness);
    // A second writer can publish a valid, identical closed source for the same
    // account. Its own authentication cannot confer the configured writer's authority.
    var other = try coordination.CoordinatorOwner.init(expected.coordinator, .{ .domain = .control, .id = 110002 }, harness.backend.interface(), undefined);
    try harness.owner.bindAccountCoordinator(&expected);
    const before = harness.owner.shard.canonicalStateDigest();
    const receipt = try other.archiveForcedSource();
    const source = try expected.coordinator.prepareForcedSourceHistory();
    var bytes: [8192]u8 = undefined;
    const digest = history.hash(try codec.encodeBare(&bytes, source));
    const request: history.LookupRequest = .{ .pending_id = 8001, .key = .{ .origin = receipt.root.origin, .identity = .{ .coordinator_forced_source = 1000 } }, .candidate_payload_digest = digest, .original_input_digest = @splat(0), .root_digest = receipt.root.root_digest, .epoch = receipt.root.epoch, .barrier = receipt.root.barrier };
    const stored = try other.store.queryOrderHistory(other.io, request);
    try std.testing.expectEqual(history.Verdict.same, try history.verifyResult(request, &stored.proof, receipt.root));
    const evidence: @import("forced_archive_proof.zig").Evidence = .{ .proof = stored.proof, .source = source };
    try std.testing.expectError(error.InvalidForcedClosure, harness.owner.shard.prepareForcedArchive(8001, .{ .account = 2, .stream = harness.stream }, &evidence));
    try std.testing.expectError(error.InvalidCoordinatorBinding, harness.owner.archiveForcedExecutionHistory(8001, &other, harness.gateway));
    try std.testing.expectError(error.InvalidCoordinatorBinding, harness.owner.bindAccountCoordinator(&other));
    try std.testing.expectEqualDeep(before, harness.owner.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u8, 1), harness.owner.shard.economic_projection.applied_forced_execution_count);
    try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
}
