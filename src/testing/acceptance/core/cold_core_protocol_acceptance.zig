//! Offline public Core protocol tests against real authenticated MemoryStore history roots.
const std = @import("std");
const trading = @import("../../../trading/trading_shard.zig");
const durable = @import("../../../persistence/durable_store.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const history = @import("../../../persistence/business_history.zig");
const batch = @import("../../../execution/order_history_batch.zig");

const Run = struct {
    owner: *demo.Owner,
    memory: *durable.MemoryAdapter,
    fn init() !Run {
        const memory = try std.testing.allocator.create(durable.MemoryAdapter);
        errdefer std.testing.allocator.destroy(memory);
        memory.* = .init();
        errdefer memory.deinit();
        const owner = try std.testing.allocator.create(demo.Owner);
        errdefer std.testing.allocator.destroy(owner);
        owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, .{ .domain = .decision_log, .id = 785 });
        try @import("../history/order_gateway_archive_acceptance.zig").initializeOwner(owner);
        return .{ .owner = owner, .memory = memory };
    }
    fn deinit(self: Run) void {
        self.memory.deinit();
        std.testing.allocator.destroy(self.owner);
        std.testing.allocator.destroy(self.memory);
    }
    fn apply(self: Run, input: trading.CanonicalEvent) !?trading.oms.Command {
        return trading.applyStable(&self.owner.shard, &self.owner.decision_journal, input);
    }
    fn archive(self: Run, group: trading.oms.IntentGroup) !trading.oms.Command {
        return self.archiveInput(groupInput(20, group), group.count);
    }
    fn archiveInput(self: Run, input: trading.CanonicalEvent, count: u8) !trading.oms.Command {
        const returned = try self.apply(input);
        var commands: [trading.oms.max_group_members]trading.oms.Command = undefined;
        if (returned) |command| {
            try std.testing.expectEqual(@as(u8, 1), count);
            commands[0] = command;
        } else {
            try std.testing.expectEqual(@as(usize, count), self.owner.shard.oms.emitted().len);
            @memcpy(commands[0..count], self.owner.shard.oms.emitted());
        }
        for (commands[0..count], 0..) |command, index| {
            try std.testing.expect(command.authority.complete());
            _ = try self.apply(fixture.atGroup(21, .{ .identity = 501 + index, .payload = .{ .oms_execution_report = .{ .report_id = 501 + index, .order_id = command.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = command.quantity } } }));
        }
        for (commands[0..count], 0..) |command, index| {
            const terminal = self.owner.shard.oms.orderById(command.order_id).?;
            var coverage = fixture.reconciliationEvidence(3022, 700 + index, command.order_id, 3, 1);
            coverage.scope.from_utc_ns = terminal.created_at_utc_ns;
            coverage.terminal_archive = .{ .visibility_deadline_utc_ns = terminal.terminal_observed_at_utc_ns + 30 * std.time.ns_per_s, .order_history_complete = true, .terminal_history_complete = true, .fills_complete = true, .economics_complete = true };
            _ = try self.apply(fixture.canonicalAt(3022, 700 + index, .{ .order_reconciliation_result = .{ .identity = 600 + index, .complete = true, .status = .found_terminal, .order = command.order_id, .revision = 1, .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 0 }, .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = command.quantity }, .terminal_status = .canceled, .rules_version = 1, .evidence = coverage } }));
        }
        for (commands[0..count]) |command| {
            const builder = try std.testing.allocator.create(batch.Builder);
            defer std.testing.allocator.destroy(builder);
            builder.* = try batch.build(&self.owner.shard, command.order_id, .{ .stream = self.owner.stream, .account = 2 });
            const view = try builder.batch(self.owner.shard.business_history_root, self.owner.shard.authoritativeBarrier(), 1);
            const receipt = try self.memory.interface().publishOrderHistory(undefined, view.value());
            _ = try self.apply(fixture.atGroup(3023, .{ .identity = 601, .payload = .{ .order_archive_committed = .{ .order_id = command.order_id, .applied_fill_quantity = 0, .qualification_digest = builder.qualification.digest(), .receipt = receipt } } }));
        }
        return commands[0];
    }
    fn proof(self: Run) !history.LookupProof {
        return (try self.memory.interface().queryOrderHistory(undefined, self.owner.shard.pending_history_candidate.?.request)).proof;
    }
    fn verify(self: Run, proof_value: history.LookupProof) !?trading.oms.Command {
        return self.apply(.{ .core = .{ .identity = 800, .payload = .{ .history_candidate_verified = proof_value } } });
    }
};

fn groupAt(first: u64, count: u8) trading.oms.IntentGroup {
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = first, .count = count };
    for (group.members[0..count], 0..) |*intent, index| intent.* = .{ .intent_sequence = first + index, .strategy_instance = 1, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    return group;
}
fn groupInput(time: u64, group: trading.oms.IntentGroup) trading.CanonicalEvent {
    return fixture.atGroup(time, .{ .identity = group.first_intent_sequence, .payload = .{ .oms_intent_group = group } });
}

test "cold core keeps dependent reports ordered while unrelated safety facts progress" {
    const run = try Run.init();
    defer run.deinit();
    _ = try run.archive(groupAt(101, 1));
    _ = try run.apply(fixture.snapshotAt(3099, 900));
    _ = try run.apply(groupInput(3100, groupAt(102, 1)));
    _ = try run.verify(try run.proof());
    const order_id = run.owner.shard.oms.emitted()[0].order_id;
    _ = try run.apply(fixture.atGroup(3101, .{ .identity = 901, .payload = .{ .oms_execution_report = .{ .report_id = 901, .order_id = order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 20 } } }));
    const pending = run.owner.shard.pending_history_candidate.?;
    try std.testing.expectError(error.HistorySafetyCapacity, run.apply(fixture.atGroup(3102, .{ .identity = 902, .payload = .{ .oms_execution_report = .{ .report_id = 902, .order_id = order_id, .revision = 1, .status = .partially_filled, .cumulative_quantity = 10, .remaining_quantity = 10 } } })));
    try std.testing.expectEqualDeep(pending, run.owner.shard.pending_history_candidate.?);
    try std.testing.expect(run.owner.shard.pending_safety_history_candidate == null);
    _ = try run.apply(fixture.snapshotAt(3103, 901));
    try std.testing.expectEqualDeep(pending, run.owner.shard.pending_history_candidate.?);
    _ = try run.verify(try run.proof());
    try std.testing.expectEqual(trading.oms.OrderState.live, run.owner.shard.oms.orderById(order_id).?.state);
    _ = try run.apply(fixture.atGroup(3104, .{ .identity = 902, .payload = .{ .oms_execution_report = .{ .report_id = 902, .order_id = order_id, .revision = 1, .status = .partially_filled, .cumulative_quantity = 10, .remaining_quantity = 10 } } }));
    _ = try run.verify(try run.proof());
    try std.testing.expectEqual(@as(i64, 10), run.owner.shard.oms.orderById(order_id).?.cumulative_quantity);
}

test "cold core first-business proof cannot admit an already stale canonical source sequence" {
    const run = try Run.init();
    defer run.deinit();
    _ = try run.archive(groupAt(101, 1));
    _ = try run.apply(groupInput(3100, groupAt(102, 1)));
    const fresh_group_proof = try run.proof();
    _ = try run.apply(fixture.atGroup(3100, .{ .identity = 800, .payload = .{ .history_candidate_verified = fresh_group_proof } }));
    const command = run.owner.shard.oms.emitted()[0];
    const before = run.owner.shard.oms.orderById(command.order_id).?;
    _ = try run.apply(fixture.canonicalAt(3101, 699, .{ .execution_report = .{
        .identity = 999,
        .order = command.order_id,
        .client_order_id = command.client_order_id,
        .instrument = 3,
        .exchange_account = 2,
        .revision = command.revision,
        .status = .accepted,
        .original_quantity = .{ .instrument = 3, .rules_version = 1, .lots = command.quantity },
        .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 0 },
        .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = command.quantity },
    } }));
    const first_business_proof = try run.proof();
    try std.testing.expectEqual(history.Verdict.proven_first, try history.verifyResult(first_business_proof.request, &first_business_proof, run.owner.shard.business_history_root.?));
    const altered = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(altered);
    @memcpy(std.mem.asBytes(altered), std.mem.asBytes(&run.owner.shard));
    altered.pending_history_candidate.?.original_was_admissible = true;
    const sealed = try std.testing.allocator.create(trading.journal.Journal);
    defer std.testing.allocator.destroy(sealed);
    sealed.* = run.owner.decision_journal;
    try sealed.seal();
    const bytes = try std.testing.allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.testing.allocator.free(bytes);
    const restored = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(restored);
    try std.testing.expectError(error.InvalidSnapshotState, trading.TradingShard.restoreSnapshotInto(restored, try altered.snapshot(sealed, altered.authoritativeBarrier(), bytes)));
    _ = try run.apply(fixture.atGroup(3101, .{ .identity = 801, .payload = .{ .history_candidate_verified = first_business_proof } }));
    try std.testing.expect(run.owner.shard.oms.recovery_only);
    const rejected_order = run.owner.shard.oms.orderById(command.order_id).?;
    try std.testing.expectEqual(before.last_report_id, rejected_order.last_report_id);
    try std.testing.expectEqual(before.cumulative_quantity, rejected_order.cumulative_quantity);
    try std.testing.expectEqual(before.quantity, rejected_order.quantity);
    try std.testing.expect(run.owner.shard.pending_history_candidate != null);
}

test "cold core wrong authenticated proof bindings preserve pending and economic state" {
    const run = try Run.init();
    defer run.deinit();
    const group = groupAt(101, 1);
    _ = try run.archive(group);
    _ = try run.apply(groupInput(3100, group));
    const proof_value = try run.proof();
    const pending = run.owner.shard.pending_history_candidate.?;
    const digest = run.owner.shard.canonicalStateDigest();
    const cursor = run.owner.shard.canonical_ingress_count;
    for (0..7) |case| {
        var invalid = proof_value;
        switch (case) {
            0 => invalid.request.root_digest[0] ^= 1,
            1 => invalid.request.epoch += 1,
            2 => invalid.request.barrier += 1,
            3 => invalid.request.pending_id += 1,
            4 => invalid.request.key.identity = .{ .intent = .{ .strategy = 1, .sequence = 102 } },
            5 => invalid.request.candidate_payload_digest[0] ^= 1,
            6 => invalid.request.original_input_digest[0] ^= 1,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidHistoryProof, run.verify(invalid));
        try std.testing.expectEqualDeep(pending, run.owner.shard.pending_history_candidate.?);
        try std.testing.expectEqualSlices(u8, &digest, &run.owner.shard.canonicalStateDigest());
        try std.testing.expectEqual(cursor, run.owner.shard.canonical_ingress_count);
    }
    _ = try run.verify(proof_value);
    try std.testing.expect(run.owner.shard.pending_history_candidate == null);
    try std.testing.expectEqual(@as(u64, 2), run.owner.shard.oms.next_order_id);
    try std.testing.expectEqual(cursor, run.owner.shard.canonical_ingress_count);
}

test "cold core covered first creates one order using original candidate times in the proof transaction" {
    const run = try Run.init();
    defer run.deinit();
    _ = try run.archive(groupAt(101, 1));
    _ = try run.apply(fixture.snapshotAt(3099, 900));
    const original = groupInput(3100, groupAt(102, 1));
    _ = try run.apply(original);
    const proof_value = try run.proof();
    try std.testing.expectEqual(history.Verdict.proven_first, try history.verifyResult(run.owner.shard.pending_history_candidate.?.request, &proof_value, run.owner.shard.business_history_root.?));
    const before = run.owner.shard.authoritativeBarrier();
    _ = try run.verify(proof_value);
    try std.testing.expectEqual(@as(u8, 1), run.owner.shard.oms.command_count);
    const command = run.owner.shard.oms.emitted()[0];
    try std.testing.expect(run.owner.shard.pending_history_candidate == null);
    try std.testing.expect(command.authority.complete());
    try std.testing.expectEqual(@as(u64, 2), command.order_id);
    try std.testing.expectEqual(@as(u64, 3), run.owner.shard.oms.next_order_id);
    try std.testing.expectEqual(original.core.receive_time, run.owner.shard.oms.orderById(command.order_id).?.created_at_utc_ns);
    const facts = try run.owner.shard.trace.factsAfter(before);
    try std.testing.expectEqual(trading.EventKind.history_candidate_verified, facts[0].kind);
    try std.testing.expect(facts.len > 1);
    _ = try run.apply(fixture.atGroup(3102, .{ .identity = 901, .payload = .{ .oms_execution_report = .{ .report_id = 901, .order_id = command.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = command.quantity } } }));
    _ = try run.verify(try run.proof());
    var cancel: trading.oms.IntentGroup = .{ .first_intent_sequence = 103, .count = 1 };
    cancel.members[0] = .{ .intent_sequence = 103, .strategy_instance = 1, .operation = .cancel, .instrument = 3, .target_order_id = command.order_id, .expected_revision = 1, .expected_cumulative_quantity = 0 };
    const cancel_input = groupInput(3103, cancel);
    _ = try run.apply(cancel_input);
    _ = try run.verify(try run.proof());
    const cancel_command = run.owner.shard.oms.emitted()[0];
    try std.testing.expectEqual(trading.oms.Operation.cancel, cancel_command.operation);
    try std.testing.expect(cancel_command.authority.complete());
    const capability = run.owner.shard.instrument_registry.get(3).?.capability.?;
    try std.testing.expectEqual(cancel_input.core.monotonic_time + capability.max_dispatch_age_ns, cancel_command.authority.dispatch_deadline_monotonic_ns);
}

test "cold core multi group duplicate is inert and missing group cannot reuse an archived member" {
    const run = try Run.init();
    defer run.deinit();
    const original = groupAt(101, 2);
    _ = try run.archive(original);
    const next = run.owner.shard.oms.next_order_id;
    const cursor = run.owner.shard.canonical_ingress_count;
    _ = try run.apply(groupInput(3100, original));
    const proof_value = try run.proof();
    try std.testing.expectEqual(history.Verdict.same, try history.verifyResult(run.owner.shard.pending_history_candidate.?.request, &proof_value, run.owner.shard.business_history_root.?));
    _ = try run.verify(proof_value);
    try std.testing.expect(run.owner.shard.pending_history_candidate == null);
    try std.testing.expectEqual(next, run.owner.shard.oms.next_order_id);
    try std.testing.expectEqual(cursor, run.owner.shard.canonical_ingress_count);
    _ = try run.apply(groupInput(3100, groupAt(100, 2)));
    _ = try run.verify(try run.proof());
    try std.testing.expectEqual(@as(u8, 0), run.owner.shard.pending_history_member_index.?);
    _ = try run.verify(try run.proof());
    try std.testing.expectEqual(@as(u8, 1), run.owner.shard.pending_history_member_index.?);
    _ = try run.verify(try run.proof());
    try std.testing.expect(run.owner.shard.history_conflict_latched);
    try std.testing.expect(run.owner.shard.pending_history_candidate != null);
    try std.testing.expect(run.owner.shard.oms.recovery_only);
    try std.testing.expect(!run.owner.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectEqual(next, run.owner.shard.oms.next_order_id);
    try std.testing.expectEqual(cursor, run.owner.shard.canonical_ingress_count);
}

fn hostIntent(first: u64) @import("../../../strategy/strategy_host_gateway.zig").OrderIntent {
    return .{ .strategy_identity = 1, .intent_sequence = first, .strategy_cursor = 0, .config_version = 1, .activation_identity = 1, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = 3, .side = .buy, .order_type = .limit, .time_in_force = .good_til_canceled, .portfolio_reduce_only = false, .quantity = 20, .limit_price_micros = 50_000_000 };
}

test "cold core external intent immutable payload survives new receipt times and conflicting quantity latches" {
    const run = try Run.init();
    defer run.deinit();
    var intent = hostIntent(101);
    intent.strategy_cursor = run.owner.shard.authoritativeBarrier();
    _ = try run.archiveInput(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .external_order_intent = intent } }), 1);
    const original = fixture.atGroup(3100, .{ .identity = 101, .payload = .{ .external_order_intent = intent } });
    _ = try run.apply(original);
    const before_cursor = run.owner.shard.strategy_cursor;
    _ = try run.verify(try run.proof());
    try std.testing.expect(run.owner.shard.pending_history_candidate == null);
    try std.testing.expectEqual(before_cursor, run.owner.shard.strategy_cursor);
    try std.testing.expectEqual(@as(u64, 2), run.owner.shard.oms.next_order_id);
    intent.quantity += 20;
    _ = try run.apply(fixture.atGroup(3100, .{ .identity = 101, .payload = .{ .external_order_intent = intent } }));
    _ = try run.verify(try run.proof());
    try std.testing.expect(run.owner.shard.history_conflict_latched);
    try std.testing.expectEqual(before_cursor, run.owner.shard.strategy_cursor);
    try std.testing.expectEqual(@as(u64, 2), run.owner.shard.oms.next_order_id);
}

fn expectInvalidSnapshot(run: Run, altered: *trading.TradingShard) !void {
    const bytes = try std.testing.allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.testing.allocator.free(bytes);
    const encoded = try altered.snapshot(&run.owner.decision_journal, altered.authoritativeBarrier(), bytes);
    const restored = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(restored);
    try std.testing.expectError(error.InvalidSnapshotState, trading.TradingShard.restoreSnapshotInto(restored, encoded));
}

test "cold core pending snapshot rejects semantic root counter and conflict latch corruption" {
    const run = try Run.init();
    defer run.deinit();
    const group = groupAt(101, 1);
    _ = try run.archive(group);
    _ = try run.apply(groupInput(3100, group));
    try run.owner.decision_journal.seal();
    const bytes = try std.testing.allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.testing.allocator.free(bytes);
    const restored = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(restored);
    _ = try trading.TradingShard.restoreSnapshotInto(restored, try run.owner.shard.snapshot(&run.owner.decision_journal, run.owner.shard.authoritativeBarrier(), bytes));
    try std.testing.expectEqualDeep(run.owner.shard.pending_history_candidate.?, restored.pending_history_candidate.?);
    const altered = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(altered);
    for (0..7) |case| {
        @memcpy(std.mem.asBytes(altered), std.mem.asBytes(&run.owner.shard));
        switch (case) {
            0 => altered.pending_history_candidate.?.request.pending_id = std.math.maxInt(u128),
            1 => altered.pending_history_candidate.?.request.epoch += 1,
            2 => altered.pending_history_candidate.?.request.root_digest[0] ^= 1,
            3 => altered.pending_history_candidate.?.request.key.identity = .{ .intent = .{ .strategy = 1, .sequence = 102 } },
            4 => altered.pending_history_candidate.?.request.candidate_payload_digest[0] ^= 1,
            5 => altered.history_conflict_latched = true,
            6 => altered.pending_history_candidate.?.original_was_admissible = false,
            else => unreachable,
        }
        try expectInvalidSnapshot(run, altered);
    }
}

test "cold core restore into publishes only complete verified proof fact groups" {
    const run = try Run.init();
    defer run.deinit();
    _ = try run.archive(groupAt(101, 1));
    _ = try run.apply(fixture.snapshotAt(3099, 900));
    _ = try run.apply(groupInput(3100, groupAt(102, 1)));
    const proof_value = try run.proof();
    const before = run.owner.shard.canonicalStateDigest();
    const pending = run.owner.shard.pending_history_candidate.?;
    const barrier = run.owner.shard.authoritativeBarrier();
    try run.owner.decision_journal.seal();
    const bytes = try std.testing.allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.testing.allocator.free(bytes);
    const snapshot = try run.owner.shard.snapshot(&run.owner.decision_journal, barrier, bytes);
    const tail = try std.testing.allocator.create(trading.journal.Journal);
    defer std.testing.allocator.destroy(tail);
    tail.* = trading.journal.Journal.initAt(barrier + 1);
    _ = try trading.applyStable(&run.owner.shard, tail, fixture.atGroup(3101, .{ .identity = 800, .payload = .{ .history_candidate_verified = proof_value } }));
    try std.testing.expect(run.owner.shard.pending_history_candidate == null);
    try std.testing.expect(run.owner.shard.authoritativeBarrier() > barrier + 1);
    try tail.seal();
    const restored = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(restored);
    const complete = try trading.TradingShard.restoreSegmentsInto(restored, snapshot, &.{tail.bytes()});
    try std.testing.expectEqual(trading.journal.ScanStatus.clean, complete.status);
    try std.testing.expectEqual(barrier, complete.barrier);
    try std.testing.expectEqualSlices(u8, &run.owner.shard.canonicalStateDigest(), &restored.canonicalStateDigest());
    const truncated = tail.bytes()[0 .. tail.bytes().len - trading.journal.footer_size - 1];
    const incomplete = try trading.TradingShard.restoreSegmentsInto(restored, snapshot, &.{truncated});
    try std.testing.expectEqual(trading.journal.ScanStatus.truncated_tail, incomplete.status);
    try std.testing.expectEqualDeep(pending, restored.pending_history_candidate.?);
    try std.testing.expectEqualSlices(u8, &before, &restored.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 2), restored.oms.next_order_id);
}
