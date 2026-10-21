//! Frontier 09 bounded safety ingress through committed Owner/Gateway/Store seams.
const std = @import("std");
const acceptance = @import("../history/order_gateway_archive_acceptance.zig");
const canonical = @import("../../../model/canonical_event.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const trading = @import("../../../trading/trading_shard.zig");
const venue = @import("../../../execution/venue_adapter.zig");

fn place(sequence: u64) trading.oms.IntentGroup {
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = sequence, .count = 1 };
    group.members[0] = .{ .intent_sequence = sequence, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    return group;
}

fn recover(destination: *demo.Owner, harness: *acceptance.ArchiveHarness) !void {
    try demo.Owner.recoverInto(destination, harness.backend.interface(), undefined, harness.stream);
}

fn isolatedRecord(stream: u64, payload: canonical.Payload) canonical.EventRecord {
    var record = fixture.canonicalAt(21, 1, payload).venue;
    record.envelope.identity.stream = stream;
    record.envelope.source_stream = stream;
    record.envelope.raw_evidence.stream = stream;
    return record;
}

test "continuous backpressure closed risk still accepts legal reports protective cancel reconciliation and faults" {
    const allocator = std.testing.allocator;
    const harness = try acceptance.ArchiveHarness.createBase(allocator, 1900);
    defer harness.destroy();
    const simulator = try allocator.create(acceptance.RestingSimulator);
    defer allocator.destroy(simulator);
    simulator.* = .{};
    try harness.bindAdapter(simulator.adapter());
    _ = try harness.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .oms_intent_group = place(101) } }));
    const command = harness.owner.shard.oms.emitted()[0];
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, command.command_id, 2 * std.time.ns_per_s));
    _ = try harness.owner.apply(.{ .venue = isolatedRecord(9, .{ .economic_fault = .{ .reason = .decoder_rejected } }) });
    try std.testing.expect(harness.owner.shard.oms.recovery_only);
    var batch = (try simulator.adapter().tryDrain()).?;
    try batch.append(isolatedRecord(10, .{ .reconciliation_started = 500 }));
    try batch.append(isolatedRecord(11, .{ .economic_fault = .{ .reason = .decoder_rejected } }));
    try harness.owner.applyAdapterBatch(batch);
    try std.testing.expectEqual(trading.oms.OrderState.pending_cancel, harness.owner.shard.oms.orderById(command.order_id).?.state);
    try std.testing.expect(harness.owner.shard.oms.orderById(command.order_id).?.reservation_active);
    var cancellation: ?trading.oms.Command = null;
    for (harness.owner.shard.oms.command_history[0..harness.owner.shard.oms.command_history_count]) |candidate| {
        if (candidate.order_id == command.order_id and candidate.operation == .cancel) cancellation = candidate;
    }
    const protective = cancellation orelse return error.MissingProtectiveCancel;
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, protective.command_id, 2 * std.time.ns_per_s));
    try harness.owner.applyAdapterBatch((try simulator.adapter().tryDrain()).?);
    try std.testing.expectEqual(trading.oms.OrderState.canceled, harness.owner.shard.oms.orderById(command.order_id).?.state);
    try std.testing.expectEqual(@as(i128, 0), (try harness.owner.shard.oms.activeReservations(1)).atoms);
    try std.testing.expectEqual(@as(u64, 2), harness.owner.shard.economic_fault_count);
    try harness.owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try @call(.never_inline, recover, .{ recovered, harness });
    try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try std.testing.expect(harness.gateway.acceptedClientOrderIdFromShard(&recovered.shard, protective.command_id) != null);
    try std.testing.expectError(error.NotSent, recovered.send(harness.gateway, &harness.guard, protective.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 2), simulator.sends);
}

test "continuous backpressure history timeout retains both lanes while fills reconciliation and faults progress then retries recover" {
    const allocator = std.testing.allocator;
    const harness = try acceptance.ArchiveHarness.create(allocator, 1902);
    defer harness.destroy();
    try acceptance.archiveOrderFills(harness.owner, harness.gateway, harness.command.order_id);
    _ = try harness.owner.archiveTerminalOrder(harness.command.order_id, harness.gateway);
    _ = try harness.owner.apply(fixture.atGroup(22, .{ .identity = 102, .payload = .{ .oms_intent_group = place(102) } }));
    const command = harness.owner.shard.oms.emitted()[0];
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, command.command_id, 2 * std.time.ns_per_s));
    var batch = (try harness.simulator.adapter().tryDrain()).?;
    harness.backend.timeout_intent_sequence = 101;
    for (batch.slice()) |record| if (record.event == .execution_report) {
        harness.backend.timeout_report_identity = record.event.execution_report.identity;
        break;
    };
    try std.testing.expectError(error.HistoryLookupDeferred, harness.owner.apply(fixture.atGroup(23, .{ .identity = 103, .payload = .{ .oms_intent_group = place(101) } })));
    const pending_risk = harness.owner.shard.pending_history_candidate.?;
    try batch.append(isolatedRecord(10, .{ .reconciliation_started = 501 }));
    try batch.append(isolatedRecord(11, .{ .economic_fault = .{ .reason = .decoder_rejected } }));
    const retained = batch;
    try std.testing.expectError(error.HistoryLookupDeferred, harness.owner.applyAdapterBatch(batch));
    try std.testing.expectEqualDeep(retained.slice(), batch.slice());
    try std.testing.expectEqualDeep(pending_risk, harness.owner.shard.pending_history_candidate.?);
    const pending_safety = harness.owner.shard.pending_safety_history_candidate.?;
    try std.testing.expect(harness.owner.shard.hasDeferredOrderHistory(command.order_id));
    try std.testing.expect(harness.owner.shard.oms.orderById(command.order_id).?.reservation_active);
    try std.testing.expectEqual(@as(i64, 0), harness.owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
    try std.testing.expectEqual(@as(i64, 20), try harness.owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    try std.testing.expectEqual(@as(u64, 1), harness.owner.shard.economic_fault_count);
    try harness.owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try @call(.never_inline, recover, .{ recovered, harness });
    try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try std.testing.expectEqualDeep(pending_safety, recovered.shard.pending_safety_history_candidate.?);
    try std.testing.expectEqualSlices(u8, &harness.owner.shard.economic_projection.digest(), &recovered.shard.economic_projection.digest());
    harness.backend.timeout_intent_sequence = null;
    harness.backend.timeout_report_identity = null;
    _ = try recovered.resolveColdCandidate();
    _ = try recovered.resolveColdCandidate();
    try recovered.applyAdapterBatch(retained);
    try std.testing.expectEqual(@as(u8, 0), recovered.shard.deferred_history_admission_count);
    try std.testing.expectEqual(@as(i64, 20), recovered.shard.oms.orderById(command.order_id).?.cumulative_quantity);
    try std.testing.expectEqual(@as(i64, 20), try recovered.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    try std.testing.expectEqual(@as(u64, 1), recovered.shard.economic_fault_count);
    try std.testing.expectError(error.DecisionLogUnavailable, recovered.send(harness.gateway, &harness.guard, command.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 2), harness.simulator.sends);
}

test "continuous backpressure Unknown accepted command survives Store recovery with zero resend" {
    const allocator = std.testing.allocator;
    const harness = try acceptance.ArchiveHarness.createBase(allocator, 1904);
    defer harness.destroy();
    const simulator = try allocator.create(acceptance.RestingSimulator);
    defer allocator.destroy(simulator);
    simulator.* = .{};
    try harness.bindAdapter(simulator.adapter());
    _ = try harness.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .oms_intent_group = place(101) } }));
    const command = harness.owner.shard.oms.emitted()[0];
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, command.command_id, 2 * std.time.ns_per_s));
    const output = (try simulator.adapter().tryDrain()).?;
    var uncertain = output.events[0];
    uncertain.event.order_dispatch_result.state = .unknown;
    _ = try harness.owner.apply(.{ .venue = uncertain });
    const reservation = try harness.owner.shard.oms.activeReservations(1);
    try std.testing.expectEqual(trading.oms.OrderState.unknown, harness.owner.shard.oms.orderById(command.order_id).?.state);
    try std.testing.expect(reservation.atoms > 0);
    try harness.owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try @call(.never_inline, recover, .{ recovered, harness });
    try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try std.testing.expectEqual(trading.oms.OrderState.unknown, recovered.shard.oms.orderById(command.order_id).?.state);
    try std.testing.expectEqualDeep(reservation, try recovered.shard.oms.activeReservations(1));
    try std.testing.expectError(error.DecisionLogUnavailable, recovered.send(harness.gateway, &harness.guard, command.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 1), simulator.sends);
}

test "continuous backpressure inadmissible Fill preserves caller input and unprocessed suffix with committed economics on recovery" {
    const allocator = std.testing.allocator;
    const harness = try acceptance.ArchiveHarness.createBase(allocator, 1906);
    defer harness.destroy();
    try harness.bindAdapter(harness.simulator.adapter());
    _ = try harness.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .oms_intent_group = place(101) } }));
    const command = harness.owner.shard.oms.emitted()[0];
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, command.command_id, 2 * std.time.ns_per_s));
    var batch = (try harness.simulator.adapter().tryDrain()).?;
    batch.events[2].event.fill.fee = null;
    try batch.append(isolatedRecord(10, .{ .economic_fault = .{ .reason = .decoder_rejected } }));
    const retained = batch;
    const economic_digest = harness.owner.shard.economic_projection.digest();
    try std.testing.expectError(error.MissingFillFee, harness.owner.applyAdapterBatch(batch));
    try std.testing.expectEqualDeep(retained.slice(), batch.slice());
    try std.testing.expect(harness.owner.shard.oms.recovery_only);
    try std.testing.expect(harness.owner.shard.oms.orderById(command.order_id).?.reservation_active);
    try std.testing.expectEqual(@as(i64, 0), harness.owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
    try std.testing.expectEqual(@as(i64, 0), try harness.owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    try std.testing.expectEqual(@as(u64, 1), harness.owner.shard.economic_fault_count);
    try std.testing.expectEqualSlices(u8, &economic_digest, &harness.owner.shard.economic_projection.digest());
    try harness.owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try @call(.never_inline, recover, .{ recovered, harness });
    try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try std.testing.expectEqualSlices(u8, &economic_digest, &recovered.shard.economic_projection.digest());
    try std.testing.expect(recovered.shard.oms.orderById(command.order_id).?.reservation_active);
    try std.testing.expectError(error.DecisionLogUnavailable, recovered.send(harness.gateway, &harness.guard, command.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 1), harness.simulator.sends);
}
