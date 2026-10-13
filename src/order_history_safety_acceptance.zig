//! Safety ingress continues independently of a deferred business-history lookup.
const std = @import("std");
const acceptance = @import("order_gateway_archive_acceptance.zig");
const demo = @import("demo_authority.zig");
const trading = @import("trading_shard.zig");
const fixture = @import("trading_shard_fixture.zig");
const venue = @import("venue_adapter.zig");

fn recoverOwnerInto(destination: *demo.Owner, harness: *acceptance.ArchiveHarness) !void {
    try demo.Owner.recoverInto(destination, harness.backend.interface(), undefined, harness.stream);
}

fn place(sequence: u64) trading.oms.IntentGroup {
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = sequence, .count = 1 };
    group.members[0] = .{ .intent_sequence = sequence, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    return group;
}

test "Owner preserves deferred history while canonical fills progress and both pending lanes recover" {
    const allocator = std.testing.allocator;
    const harness = try acceptance.ArchiveHarness.create(allocator, 1180);
    defer harness.destroy();
    const old_dispatch = harness.owner.shard.dispatch_ingress_history[0].body;
    _ = try harness.owner.archiveTerminalOrder(harness.command.order_id, harness.gateway);
    try std.testing.expectEqual(@as(u16, 0), harness.owner.shard.dispatch_ingress_history_count);
    const old_high_water = harness.owner.shard.oms.next_command_id;
    _ = try harness.owner.apply(fixture.canonicalAt(22, 900, .{ .order_dispatch_result = .{ .command = old_dispatch.command, .state = old_dispatch.state } }));
    try std.testing.expectEqual(old_high_water, harness.owner.shard.oms.next_command_id);
    try std.testing.expectEqual(@as(u64, 1), harness.simulator.sends);
    _ = try harness.owner.apply(fixture.atGroup(22, .{ .identity = 102, .payload = .{ .oms_intent_group = place(102) } }));
    const next = harness.owner.shard.oms.emitted()[0];
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, next.command_id, 2 * std.time.ns_per_s));
    const batch = (try harness.simulator.adapter().tryDrain()).?;
    var first_report: ?u128 = null;
    for (batch.slice()) |record| if (record.event == .execution_report) {
        first_report = record.event.execution_report.identity;
        break;
    };
    harness.backend.timeout_intent_sequence = 101;
    harness.backend.timeout_report_identity = first_report orelse return error.MissingAdapterReport;
    try std.testing.expectError(error.HistoryLookupDeferred, harness.owner.apply(fixture.atGroup(23, .{ .identity = 103, .payload = .{ .oms_intent_group = place(101) } })));
    const original = harness.owner.shard.pending_history_candidate.?;
    try harness.owner.checkpoint();
    try std.testing.expectError(error.HistoryLookupDeferred, harness.owner.applyAdapterBatch(batch));
    try std.testing.expect(!harness.owner.closed);
    try std.testing.expectEqualDeep(original, harness.owner.shard.pending_history_candidate.?);
    const safety = harness.owner.shard.pending_safety_history_candidate orelse return error.MissingSafetyCandidate;
    const admission_count = harness.owner.shard.deferred_history_admission_count;
    try std.testing.expect(admission_count != 0);
    try std.testing.expect(harness.owner.shard.hasDeferredOrderHistory(next.order_id));
    try std.testing.expectError(error.OrderArchivePinned, @import("order_history_batch.zig").build(&harness.owner.shard, next.order_id, .{ .stream = harness.stream, .account = 2 }));
    const admissions = try allocator.dupe(@TypeOf(harness.owner.shard.deferred_history_admissions[0]), harness.owner.shard.deferred_history_admissions[0..admission_count]);
    defer allocator.free(admissions);
    try std.testing.expect(safety.request.pending_id != original.request.pending_id);
    try std.testing.expectEqual(@as(i64, 20), try harness.owner.shard.economic_projection.appliedCanonicalFillQuantity(next.order_id));
    try std.testing.expectEqual(@as(i64, 0), harness.owner.shard.oms.orderById(next.order_id).?.cumulative_quantity);
    const digest = harness.owner.shard.canonicalStateDigest();
    const tail_recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(tail_recovered);
    try @call(.never_inline, recoverOwnerInto, .{ tail_recovered, harness });
    try std.testing.expectEqualSlices(u8, &digest, &tail_recovered.shard.canonicalStateDigest());
    try std.testing.expectEqualDeep(admissions, tail_recovered.shard.deferred_history_admissions[0..admission_count]);
    try std.testing.expectError(error.HistoryLookupDeferred, harness.owner.apply(fixture.atGroup(24, .{ .identity = 104, .payload = .{ .oms_intent_group = place(104) } })));
    try std.testing.expectEqualSlices(u8, &digest, &harness.owner.shard.canonicalStateDigest());
    try harness.owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    var transferred = false;
    errdefer if (!transferred) allocator.destroy(recovered);
    try @call(.never_inline, recoverOwnerInto, .{ recovered, harness });
    try std.testing.expectEqualDeep(original, recovered.shard.pending_history_candidate.?);
    try std.testing.expectEqualDeep(safety, recovered.shard.pending_safety_history_candidate.?);
    try std.testing.expectEqual(admission_count, recovered.shard.deferred_history_admission_count);
    try std.testing.expectEqualDeep(admissions, recovered.shard.deferred_history_admissions[0..admission_count]);
    allocator.destroy(harness.owner);
    harness.owner = recovered;
    transferred = true;
    harness.backend.timeout_report_identity = null;
    _ = try harness.owner.resolveColdCandidate();
    try std.testing.expectEqualDeep(original, harness.owner.shard.pending_history_candidate.?);
    try std.testing.expect(harness.owner.shard.pending_safety_history_candidate == null);
    try std.testing.expectEqual(@as(i64, 0), harness.owner.shard.oms.orderById(next.order_id).?.cumulative_quantity);
    try std.testing.expectEqual(trading.oms.OrderState.live, harness.owner.shard.oms.orderById(next.order_id).?.state);
    harness.backend.timeout_intent_sequence = null;
    _ = try harness.owner.resolveColdCandidate();
    try std.testing.expect(harness.owner.shard.pending_history_candidate == null);
    try std.testing.expect(harness.owner.shard.pending_safety_history_candidate == null);
    try std.testing.expect(harness.owner.shard.deferred_history_admission_count != 0);
    try std.testing.expectError(error.HistoryLookupDeferred, harness.owner.apply(fixture.atGroup(25, .{ .identity = 105, .payload = .{ .oms_intent_group = place(105) } })));
    try harness.owner.applyAdapterBatch(batch);
    try std.testing.expectEqual(@as(u8, 0), harness.owner.shard.deferred_history_admission_count);
    try std.testing.expect(harness.owner.shard.pending_history_candidate == null);
    try std.testing.expectEqual(@as(i64, 20), harness.owner.shard.oms.orderById(next.order_id).?.cumulative_quantity);
    try std.testing.expectEqual(@as(i64, 20), try harness.owner.shard.economic_projection.appliedCanonicalFillQuantity(next.order_id));
    try std.testing.expectEqual(@as(u64, 2), harness.simulator.sends);
    harness.backend.timeout_intent_sequence = null;
    _ = try harness.owner.resolveColdCandidate();
    try std.testing.expect(harness.owner.shard.pending_history_candidate == null);
    try std.testing.expect(harness.owner.shard.pending_safety_history_candidate == null);
    try std.testing.expectEqual(@as(u64, 3), harness.owner.shard.oms.next_order_id);

    // Preserve the bounded backlog on overload; no later fact or send can pass this fence.
    harness.backend.timeout_intent_sequence = 101;
    try std.testing.expectError(error.HistoryLookupDeferred, harness.owner.apply(fixture.atGroup(26, .{ .identity = 105, .payload = .{ .oms_intent_group = place(101) } })));
    var terminal_report: ?@import("canonical_event.zig").EventRecord = null;
    for (batch.slice()) |record| if (record.event == .execution_report and record.event.execution_report.status == .filled) {
        terminal_report = record;
        break;
    };
    var deferred_report = terminal_report orelse return error.MissingTerminalReport;
    harness.backend.timeout_report_identity = 10_000;
    for (0..65) |index| {
        const sequence = 1000 + @as(u64, @intCast(index));
        deferred_report.envelope.identity.sequence = sequence;
        deferred_report.envelope.source_sequence = sequence;
        deferred_report.envelope.source_fact_identity = sequence;
        deferred_report.envelope.raw_evidence.sequence = sequence;
        deferred_report.event.execution_report.identity = 10_000 + index;
        try std.testing.expectError(if (index == 0) error.HistoryLookupDeferred else error.HistorySafetyCapacity, harness.owner.apply(.{ .venue = deferred_report }));
    }
    try std.testing.expectEqual(@as(u8, 64), harness.owner.shard.deferred_history_admission_count);
    var full_digest = harness.owner.shard.canonicalStateDigest();
    const altered_owner = try allocator.create(demo.Owner);
    defer allocator.destroy(altered_owner);
    @memcpy(std.mem.asBytes(altered_owner), std.mem.asBytes(harness.owner));
    var altered_retry = deferred_report;
    altered_retry.envelope.times.receive_utc_ns = altered_retry.envelope.times.receive_utc_ns.? + 1;
    try std.testing.expectError(error.ConflictingCanonicalIdentity, altered_owner.apply(.{ .venue = altered_retry }));
    try std.testing.expect(altered_owner.closed);
    try std.testing.expectEqual(@as(u8, 64), altered_owner.shard.deferred_history_admission_count);
    try std.testing.expectEqualSlices(u8, &full_digest, &altered_owner.shard.canonicalStateDigest());
    try std.testing.expectEqualDeep(harness.owner.shard.deferred_history_admissions[63], altered_owner.shard.deferred_history_admissions[63]);
    try harness.owner.checkpoint();
    // Checkpoint maintenance is itself an ordered authoritative fact.
    full_digest = harness.owner.shard.canonicalStateDigest();
    const admission_recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(admission_recovered);
    try @call(.never_inline, recoverOwnerInto, .{ admission_recovered, harness });
    try std.testing.expectEqualSlices(u8, &full_digest, &admission_recovered.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u8, 64), admission_recovered.shard.deferred_history_admission_count);
    deferred_report.envelope.identity.sequence += 1;
    deferred_report.envelope.source_sequence += 1;
    deferred_report.envelope.source_fact_identity += 1;
    deferred_report.envelope.raw_evidence.sequence += 1;
    deferred_report.event.execution_report.identity += 1;
    try std.testing.expectError(error.HistoryAdmissionCapacity, harness.owner.apply(.{ .venue = deferred_report }));
    try std.testing.expectEqualSlices(u8, &full_digest, &harness.owner.shard.canonicalStateDigest());
    try std.testing.expectError(error.DecisionLogUnavailable, harness.owner.source());
    try std.testing.expectEqual(@as(u64, 2), harness.simulator.sends);
}
