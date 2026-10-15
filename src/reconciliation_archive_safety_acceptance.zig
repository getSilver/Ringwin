//! Failure closure and durable cursor handoff through public application seams.
const std = @import("std");
const acceptance = @import("order_gateway_archive_acceptance.zig");
const windows = @import("reconciliation_archive_acceptance.zig");
const funding = @import("funding_archive_acceptance.zig");
const fixture = @import("trading_shard_fixture.zig");
const canonical = @import("canonical_event.zig");
const trading = @import("trading_shard.zig");
const demo = @import("demo_authority.zig");
const execution = @import("execution_gateway.zig");

test "07 Closed window same is inert and conflicts or late new funding fail closed" {
    for (0..3) |mode| {
        const harness = if (mode == 0) try acceptance.ArchiveHarness.createBase(std.testing.allocator, 2000) else try funding.createFundingHarness(2000 + 2 * mode);
        defer harness.destroy();
        const fact: canonical.EconomicFactRef = .{ .identity = 8001, .kind = .fill, .digest = if (mode == 0) @splat(0) else harness.owner.shard.economic_projection.canonical_fill_evidence[0].digest, .fee_confirmed = true };
        const input = windows.windowInput(harness, 0, if (mode == 0) &.{} else &.{fact});
        _ = try harness.owner.apply(input);
        _ = try harness.owner.archiveReconciliationWindowHistory(10000, harness.gateway);
        const before = harness.owner.shard.economicSummary();
        if (mode == 0) {
            var conflict = input;
            conflict.venue.envelope.identity.sequence = 200;
            conflict.venue.envelope.source_sequence = 200;
            conflict.venue.event.account_reconciliation_result.account_economics.?.balances[0].atoms -= 1;
            _ = try harness.owner.apply(conflict);
            try std.testing.expect(harness.owner.shard.history_conflict_latched);
        } else {
            var late = fixture.atGroup(39, .{ .identity = 9901, .payload = .{ .funding_settlement = .{ .settlement_id = 9901, .amount_atoms = -7 } } });
            if (mode == 2) late.core.time_presence.source = false;
            try std.testing.expectError(if (mode == 1) error.LateEconomicFact else error.UnresolvedSettlementBoundary, harness.owner.apply(late));
        }
        try std.testing.expectEqualDeep(before, harness.owner.shard.economicSummary());
        try std.testing.expect(harness.owner.shard.oms.recovery_only);
        try std.testing.expectEqual(@as(u64, 0), harness.gateway.send_attempt_count);
    }
}

test "07 Window archive fault boundaries recover old or new complete cursor without dispatch" {
    for ([_]@TypeOf(@as(acceptance.ArchiveFaultMemory, undefined).stage){ .history_publish, .decision_commit, .gateway_append, .gateway_checkpoint }, 0..) |stage, index| {
        const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, 2020 + 2 * index);
        defer harness.destroy();
        _ = try harness.owner.apply(windows.windowInput(harness, 0, &.{}));
        try harness.owner.checkpoint();
        const before = harness.owner.shard.economicSummary();
        harness.backend.stage = stage;
        try std.testing.expectError(if (stage == .decision_commit) error.DecisionLogUnavailable else error.InjectedEio, harness.owner.archiveReconciliationWindowHistory(10000, harness.gateway));
        try std.testing.expect(harness.owner.closed);
        const recovered = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(recovered);
        const store = harness.backend.memory.interface();
        try demo.Owner.recoverInto(recovered, store, undefined, harness.stream);
        const committed = stage == .gateway_append or stage == .gateway_checkpoint;
        try std.testing.expectEqual(committed, recovered.shard.reconciliation_cursor != null);
        try std.testing.expectEqual(!committed, recovered.shard.pending_reconciliation_window != null);
        try std.testing.expectEqualDeep(before, recovered.shard.economicSummary());
        const gateway = try std.testing.allocator.create(execution.Gateway);
        defer std.testing.allocator.destroy(gateway);
        gateway.init();
        try gateway.attachRecoveredDurableDispatch(store, undefined, harness.dispatch_stream);
        if (committed) {
            try recovered.resumeReconciliationWindowArchive(gateway);
            const first = try store.recover(undefined, harness.dispatch_stream);
            try recovered.resumeReconciliationWindowArchive(gateway);
            try std.testing.expectEqual(first.last_sequence, (try store.recover(undefined, harness.dispatch_stream)).last_sequence);
        }
        try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
    }
}

test "07 Window omission before balance tamper and missing bill completeness preserve the economic boundary" {
    for (0..4) |mode| {
        const harness = try funding.createFundingHarness(2050 + 2 * mode);
        defer harness.destroy();
        const fill_digest = harness.owner.shard.economic_projection.canonical_fill_evidence[0].digest;
        const fact: canonical.EconomicFactRef = .{ .identity = 8001, .kind = .fill, .digest = fill_digest, .fee_confirmed = true };
        var input = windows.windowInput(harness, 0, &.{fact});
        var evidence = &input.venue.event.account_reconciliation_result.account_economics.?;
        switch (mode) {
            0 => evidence.covered_economic_fact_count = 0,
            1 => evidence.before_balances[0].atoms -= 1,
            2 => evidence.balance_count = 1,
            3 => evidence.bills_complete = false,
            else => unreachable,
        }
        const before = harness.owner.shard.economicSummary();
        try std.testing.expectError(error.IncompleteReconciliationEvidence, harness.owner.apply(input));
        try std.testing.expect(harness.owner.shard.oms.recovery_only);
        try std.testing.expectEqualDeep(before.portfolio, harness.owner.shard.economicSummary().portfolio);
        try std.testing.expectEqualDeep(before.exchange, harness.owner.shard.economicSummary().exchange);
        try std.testing.expect(harness.owner.shard.reconciliation_cursor == null);
    }
}

test "07 Window checkpoint publication and unavailable recovery history fail closed with durable cursor intact" {
    for (0..2) |mode| {
        const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, 2120 + mode * 2);
        defer harness.destroy();
        _ = try harness.owner.apply(windows.windowInput(harness, 0, &.{}));
        _ = try harness.owner.archiveReconciliationWindowHistory(10000, harness.gateway);
        const cursor = harness.owner.shard.reconciliation_cursor;
        const before = harness.owner.shard.economicSummary();
        if (mode == 0) {
            harness.backend.stage = .owner_checkpoint;
            try std.testing.expectError(error.DecisionLogUnavailable, harness.owner.checkpoint());
            try std.testing.expect(harness.owner.closed);
        } else {
            try harness.owner.checkpoint();
            harness.backend.stage = .recovery_history_query;
        }
        const recovered = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(recovered);
        if (mode == 1) {
            try std.testing.expectError(error.DecisionLogUnavailable, demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream));
            try std.testing.expectError(error.DecisionLogUnavailable, recovered.source());
        }
        try demo.Owner.recoverInto(recovered, harness.backend.memory.interface(), undefined, harness.stream);
        try std.testing.expectEqualDeep(cursor, recovered.shard.reconciliation_cursor);
        try std.testing.expectEqualDeep(before, recovered.shard.economicSummary());
        try std.testing.expectEqual(@as(u64, 0), harness.gateway.send_attempt_count);
    }
}

test "07 Rehashed cursor and pending window tampering cannot certify a false economic boundary" {
    const allocator = std.testing.allocator;
    const harness = try acceptance.ArchiveHarness.createBase(allocator, 2130);
    defer harness.destroy();
    _ = try harness.owner.apply(windows.windowInput(harness, 0, &.{}));
    const pending = harness.owner.shard.pending_reconciliation_window.?;
    const destination = try allocator.create(trading.TradingShard);
    defer allocator.destroy(destination);
    const storage = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(storage);
    var sealed = harness.owner.decision_journal;
    try sealed.seal();
    harness.owner.shard.pending_reconciliation_window.?.original.event.account_reconciliation_result.account_economics.?.before_balances[0].atoms -= 1;
    var encoded = try harness.owner.shard.snapshot(&sealed, harness.owner.shard.authoritativeBarrier(), storage);
    try std.testing.expectError(error.InvalidSnapshotState, trading.TradingShard.restoreSnapshotInto(destination, encoded));
    harness.owner.shard.pending_reconciliation_window = pending;
    _ = try harness.owner.archiveReconciliationWindowHistory(10000, harness.gateway);
    const original = harness.owner.shard.reconciliation_cursor.?;
    sealed = harness.owner.decision_journal;
    try sealed.seal();
    for (0..4) |mode| {
        harness.owner.shard.reconciliation_cursor = original;
        switch (mode) {
            0 => harness.owner.shard.reconciliation_cursor.?.balances[0].atoms -= 1,
            1 => harness.owner.shard.reconciliation_cursor.?.closed_economic_fact_count += 1,
            2 => harness.owner.shard.reconciliation_cursor.?.root_digest[0] ^= 1,
            3 => harness.owner.shard.reconciliation_cursor.?.through_utc_ns = 0,
            else => unreachable,
        }
        encoded = try harness.owner.shard.snapshot(&sealed, harness.owner.shard.authoritativeBarrier(), storage);
        try std.testing.expectError(error.InvalidSnapshotState, trading.TradingShard.restoreSnapshotInto(destination, encoded));
    }
    harness.owner.shard.reconciliation_cursor = original;
    encoded = try harness.owner.shard.snapshot(&sealed, harness.owner.shard.authoritativeBarrier(), storage);
    _ = try trading.TradingShard.restoreSnapshotInto(destination, encoded);
    try std.testing.expectEqualDeep(original, destination.reconciliation_cursor.?);
}

test "07 Open economic commitments reject rehashed hot cold identity and original time substitution" {
    const allocator = std.testing.allocator;
    const harness = try funding.createFundingHarness(2150);
    defer harness.destroy();
    _ = try harness.owner.apply(fixture.atGroup(39, .{ .identity = 9000, .payload = .{ .funding_settlement = .{ .settlement_id = 9000, .amount_atoms = -7 } } }));
    const old = harness.owner.shard.economic_projection.applied_fundings[0];
    _ = try harness.owner.archiveFundingHistory(old.funding.identity, harness.gateway);
    const fill = harness.owner.shard.economic_projection.canonical_fill_evidence[0];
    _ = try harness.owner.apply(windows.windowInput(harness, 0, &.{
        .{ .identity = fill.identity, .kind = .fill, .digest = fill.digest, .fee_confirmed = true },
        .{ .identity = old.funding.identity, .kind = .funding, .digest = old.payload_digest, .fee_confirmed = true },
    }));
    _ = try harness.owner.archiveReconciliationWindowHistory(10000, harness.gateway);
    _ = try harness.owner.apply(fixture.atGroup(41, .{ .identity = 9001, .payload = .{ .funding_settlement = .{ .settlement_id = 9001, .amount_atoms = -7 } } }));
    const destination = try allocator.create(trading.TradingShard);
    defer allocator.destroy(destination);
    const storage = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(storage);
    for (0..2) |cold| {
        if (cold == 1) _ = try harness.owner.archiveFundingHistory(9001, harness.gateway);
        // Retire the original input group so validation also exercises pinned facts.
        try harness.owner.checkpoint();
        const original = harness.owner.shard.open_economic_facts[0];
        for (0..3) |mode| {
            harness.owner.shard.open_economic_facts[0] = original;
            switch (mode) {
                0 => {
                    harness.owner.shard.open_economic_facts[0].identity = old.funding.identity;
                    harness.owner.shard.open_economic_facts[0].digest = old.payload_digest;
                },
                1 => {
                    harness.owner.shard.open_economic_facts[0].economic_time_utc_ns = original.economic_time_utc_ns.? + 1;
                    harness.owner.shard.open_economic_min_utc_ns += 1;
                    harness.owner.shard.open_economic_max_utc_ns += 1;
                },
                2 => harness.owner.shard.open_economic_facts[0].accepted_input_digest[0] ^= 1,
                else => unreachable,
            }
            var sealed = harness.owner.decision_journal;
            try sealed.seal();
            const encoded = try harness.owner.shard.snapshot(&sealed, harness.owner.shard.authoritativeBarrier(), storage);
            try std.testing.expectError(error.InvalidSnapshotState, trading.TradingShard.restoreSnapshotInto(destination, encoded));
            harness.owner.shard.open_economic_min_utc_ns = original.economic_time_utc_ns.?;
            harness.owner.shard.open_economic_max_utc_ns = original.economic_time_utc_ns.?;
        }
        harness.owner.shard.open_economic_facts[0] = original;
        const recovered = try allocator.create(demo.Owner);
        defer allocator.destroy(recovered);
        try demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream);
        try std.testing.expectEqualDeep(original, recovered.shard.open_economic_facts[0]);
        try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    }
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.send_attempt_count);
}

test "07 Opening native balance count reserves the settlement baseline slot before mutation" {
    const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, 2160);
    defer harness.destroy();
    var balance: @import("trading_shard_event.zig").OpeningBalance = .{ .cash_atoms = 1 };
    balance.native_balance_count = @intCast(harness.owner.shard.economic_baseline_balances.len);
    const before = harness.owner.shard.canonicalStateDigest();
    try std.testing.expectError(error.EconomicBaselineCapacityExceeded, harness.owner.apply(fixture.atGroup(30, .{ .identity = 99999, .payload = .{ .opening_balance = balance } })));
    try std.testing.expectEqualSlices(u8, &before, &harness.owner.shard.canonicalStateDigest());
}

test "07 Single economic commitment journal authenticates all 32 bytes and rejects truncated payload" {
    const allocator = std.testing.allocator;
    const harness = try funding.createFundingHarness(2180);
    defer harness.destroy();
    const initial = try allocator.create(trading.TradingShard);
    defer allocator.destroy(initial);
    @memcpy(std.mem.asBytes(initial), std.mem.asBytes(&harness.owner.shard));
    const applied = try allocator.create(trading.TradingShard);
    defer allocator.destroy(applied);
    @memcpy(std.mem.asBytes(applied), std.mem.asBytes(initial));
    const destination = try allocator.create(trading.TradingShard);
    defer allocator.destroy(destination);
    const source = try allocator.create(trading.journal.Journal);
    defer allocator.destroy(source);
    source.* = trading.journal.Journal.initAt(initial.authoritativeBarrier() + 1);
    _ = try trading.applyStable(applied, source, fixture.atGroup(39, .{ .identity = 9200, .payload = .{ .funding_settlement = .{ .settlement_id = 9200, .amount_atoms = -7 } } }));
    try source.seal();
    _ = try trading.recoverStableInto(destination, initial, source.bytes());
    try std.testing.expectEqualSlices(u8, &applied.canonicalStateDigest(), &destination.canonicalStateDigest());
    const altered = try allocator.create(trading.journal.Journal);
    defer allocator.destroy(altered);
    for (0..3) |mode| {
        altered.* = trading.journal.Journal.initAt(initial.authoritativeBarrier() + 1);
        var reader = try trading.journal.Reader.init(source.bytes());
        var changed = false;
        while (true) switch (try reader.next()) {
            .record => |record| {
                var replacement = record;
                var payload: [41]u8 = undefined;
                if (record.type_id == @intFromEnum(trading.EventKind.economic_open_commitment)) {
                    try std.testing.expectEqual(@as(usize, 41), record.payload.len);
                    @memcpy(&payload, record.payload);
                    if (mode != 0) payload[if (mode == 1) 9 else 40] ^= 1;
                    replacement.payload = payload[0..if (mode == 0) @as(usize, 40) else 41];
                    changed = true;
                }
                // Re-encode the journal's checksums: rejection must come from
                // independent semantic replay, rather than transport corruption.
                try altered.append(replacement);
            },
            .end => break,
        };
        try std.testing.expect(changed);
        try altered.seal();
        try std.testing.expectError(if (mode == 0) error.InvalidDerivedFactRecord else error.ReplayFactMismatch, trading.recoverStableInto(destination, initial, altered.bytes()));
    }
}
