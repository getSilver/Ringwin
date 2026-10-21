//! Sequential routing retirement at the shared-account public Owner boundary.
const std = @import("std");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const acceptance = @import("../history/order_gateway_archive_acceptance.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const history = @import("../../../persistence/business_history.zig");
const raw = @import("../../../persistence/raw_ingress.zig");
const market = @import("../../../adapters/okx/okx_public_market.zig");
const durable = @import("../../../persistence/durable_store.zig");
const codec = @import("../../../persistence/snapshot_codec.zig");

fn cover(harness: *acceptance.ArchiveHarness, round: u64) !void {
    const command = harness.command;
    const utc = fixture.atGroup(4000 + round * 5000, .{ .identity = 1, .payload = .recovery_completed }).core.source_time;
    const sequence = 100 + round;
    const evidence: @import("../../../model/canonical_event.zig").ReconciliationEvidence = .{
        .scope = .{ .exchange_account = 2, .instrument = 3, .order = command.order_id, .revision = 1, .from_utc_ns = harness.owner.shard.oms.orderById(command.order_id).?.created_at_utc_ns, .through_utc_ns = utc },
        .observed_at_utc_ns = utc,
        .source = .{ .stream = 7, .sequence = sequence, .digest = history.hash("complete offline terminal coverage") },
        .terminal_archive = .{ .visibility_deadline_utc_ns = utc, .order_history_complete = true, .terminal_history_complete = true, .fills_complete = true, .economics_complete = true },
    };
    var input = fixture.canonicalAt(4000 + round * 5000, sequence, .{ .order_reconciliation_result = .{ .identity = 50000 + round, .complete = true, .status = .found_terminal, .order = command.order_id, .revision = 1, .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 0 }, .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 1 }, .terminal_status = .canceled, .rules_version = 1, .evidence = evidence } });
    input.venue.envelope.identity.stream = 7;
    input.venue.envelope.source_stream = 7;
    input.venue.envelope.raw_evidence = evidence.source;
    _ = try harness.owner.apply(input);
}

const acknowledgement = "offline transport acknowledgement without economic events";
const Sweep = struct {
    fn consume(_: *anyopaque, _: u64, _: market.RawIngressRecord, bytes: []const u8) !void {
        if (!std.mem.eql(u8, bytes, acknowledgement)) return error.UnexpectedRawFixture;
    }
};

fn recoverAndSweep(harness: *acceptance.ArchiveHarness, ingress: durable.StreamIdentity) !void {
    try harness.owner.checkpoint();
    const digest = harness.owner.shard.canonicalStateDigest();
    const restored = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(restored);
    try demo.Owner.recoverInto(restored, harness.backend.interface(), undefined, harness.stream);
    try std.testing.expectEqualDeep(digest, restored.shard.canonicalStateDigest());
    try std.testing.expect(restored.shard.recovery_admission_pending);
    try restored.bindRecoveryIngress(harness.backend.interface(), ingress);
    try restored.replayCommittedIngress(ingress, .{ .ptr = harness, .consume_fn = Sweep.consume });
    try std.testing.expect(!restored.shard.recovery_admission_pending);
    @memcpy(std.mem.asBytes(harness.owner), std.mem.asBytes(restored));
    harness.gateway.init();
    try harness.gateway.attachRecoveredDurableDispatch(harness.backend.interface(), undefined, harness.dispatch_stream);
}

test "08 shared gateway retires 320 terminal routes keeps fencing high water and rejects old commands after recovery" {
    const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, 120000);
    defer harness.destroy();
    // Explicit bounded synthetic disk budget; no live/terminal capacity change.
    harness.backend.memory.archive_quota = 64 * 1024 * 1024;
    const ingress: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 120002 };
    var sink = try raw.DurableSink.init(harness.backend.interface(), undefined, ingress);
    _ = try sink.interface().append(.{ .source_session = 1, .byte_len = acknowledgement.len, .sha256 = history.hash(acknowledgement), .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1 }, acknowledgement);
    var owner = try coordination.CoordinatorOwner.init(coordination.AccountCoordinator.init(2, 10_000_000_000, 10_000_000_000), .{ .domain = .control, .id = 120003 }, harness.backend.interface(), undefined);
    var first: coordination.GatewayRequest = undefined;
    for (0..320) |round| {
        if (round % 32 == 0) std.debug.print("gateway history window {d}\n", .{round / 32});
        _ = try harness.owner.apply(fixture.atGroup(100 + round * 5000, .{ .identity = round + 2, .payload = .{ .primary_lease_granted = .{ .fencing_token = round + 2 } } }));
        var group: @import("../../../trading/trading_shard.zig").oms.IntentGroup = .{ .first_intent_sequence = 1000 + round, .count = 1 };
        group.members[0] = .{ .intent_sequence = 1000 + round, .operation = .place, .instrument = 3, .quantity = 1, .limit_price = fixture.omsPrice(3, 50_000_000) };
        _ = try harness.owner.apply(fixture.atGroup(100 + round * 5000, .{ .identity = 1000 + round, .payload = .{ .oms_intent_group = group } }));
        harness.command = harness.owner.shard.oms.emitted()[0];
        const summary = try coordination.shardSummaryFromShard(&harness.owner.shard, .shard_0, round + 1, 1);
        try owner.apply(.{ .publish_summary = .{ .identity = round + 1, .summary = summary } });
        const request: coordination.GatewayRequest = .{ .exchange_account = 2, .shard_id = .shard_0, .fencing_token = round + 2, .command = harness.command };
        if (round == 0) first = request;
        try owner.recordGateway(request);
        if (round == 0) try std.testing.expectError(error.OrderArchiveNotQualified, owner.retireGateway(.shard_0, harness.command.command_id, harness.owner));
        _ = try harness.owner.apply(fixture.atGroup(101 + round * 5000, .{ .identity = 10000 + round, .payload = .{ .oms_execution_report = .{
            .report_id = 10000 + round,
            .order_id = harness.command.order_id,
            .revision = 1,
            .status = .canceled,
            .cumulative_quantity = 0,
            .remaining_quantity = 1,
        } } }));
        try cover(harness, round);
        try owner.retireGateway(.shard_0, harness.command.command_id, harness.owner);
        try std.testing.expectEqual(@as(u8, 0), owner.coordinator.gateway_ownership.count);
        const root = owner.coordinator.history_root.?;
        const lookup: history.LookupRequest = .{ .pending_id = round + 1, .key = .{ .origin = root.origin, .identity = .{ .coordinator_gateway_closure = .{ .shard = 0, .command = harness.command.command_id } } }, .candidate_payload_digest = root.qualification_digest, .original_input_digest = root.qualification_digest, .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
        const result = try owner.store.queryOrderHistory(undefined, lookup);
        try std.testing.expectEqual(history.Verdict.same, try history.verifyResult(lookup, &result.proof, root));
        try history.validateRecord(&result);
        const closure = try codec.decodeBare(result.record_bytes[0..result.record_len], coordination.GatewayRetirement);
        try std.testing.expectEqual(harness.command.order_id, closure.order.order.id);
        try std.testing.expectEqual(@as(u64, round + 2), closure.record.fencing_token);
        _ = try harness.owner.archiveTerminalOrder(harness.command.order_id, harness.gateway);
        try std.testing.expectEqual(@as(u16, 0), harness.owner.shard.oms.order_count);
        if (round % 4 == 3) {
            try recoverAndSweep(harness, ingress);
            const before = owner.coordinator.digest();
            try owner.checkpoint();
            owner = try coordination.CoordinatorOwner.recover(owner.stream, owner.store, owner.io);
            try std.testing.expectEqualDeep(before, owner.coordinator.digest());
            try std.testing.expectEqual(@as(u64, round + 2), owner.coordinator.gateway_ownership.latest_fencing_tokens[0]);
        }
    }
    try std.testing.expectError(error.DuplicateCommandIdentity, owner.recordGateway(first));
    try std.testing.expectEqual(@as(u8, 0), owner.coordinator.gateway_ownership.count);
    try std.testing.expectEqual(@as(u64, 321), owner.coordinator.gateway_ownership.latest_fencing_tokens[0]);
    try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
    const before = harness.owner.shard.canonicalStateDigest();
    try std.testing.expectError(error.InvalidPrimaryLease, harness.owner.apply(.{ .core = .{ .identity = 1, .payload = .{ .primary_lease_granted = .{ .fencing_token = 1 } } } }));
    try std.testing.expectEqualDeep(before, harness.owner.shard.canonicalStateDigest());
}
