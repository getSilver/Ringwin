//! Continuous account windows through the public Owner/Store/Gateway seams.
const std = @import("std");
const acceptance = @import("order_gateway_archive_acceptance.zig");
const funding_acceptance = @import("funding_archive_acceptance.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const canonical = @import("../../../model/canonical_event.zig");
const trading = @import("../../../trading/trading_shard.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const history = @import("../../../persistence/business_history.zig");
const codec = @import("../../../persistence/snapshot_codec.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const economics = @import("../../../portfolio/economics.zig");

pub fn windowInput(harness: *acceptance.ArchiveHarness, round: u64, facts: []const canonical.EconomicFactRef) trading.CanonicalEvent {
    const current = &harness.owner.shard;
    const sequence = 10 + round * 3;
    var evidence: canonical.AccountEconomicEvidence = .{
        .exchange_account = 2,
        .scope = .spot_and_isolated_linear_usdt,
        .from_utc_ns = if (current.reconciliation_cursor) |cursor| cursor.through_utc_ns else current.economic_baseline_utc_ns,
        .through_utc_ns = 1,
        .source = .{ .stream = 7, .sequence = sequence, .digest = history.hash("complete account after") },
        .before_source = .{ .stream = 7, .sequence = sequence - 2, .digest = history.hash("complete account before") },
        .balance_count = 2,
        .before_balance_count = 2,
        .covered_economic_fact_count = @intCast(facts.len),
        .query_count = 1,
        .bills_complete = true,
        .bill_chain_digest = history.hash("all bills in exact interval"),
    };
    evidence.before_balances[0] = .{ .asset = 1, .atoms = 25_000_000_000 };
    evidence.before_balances[1] = .{ .asset = 0x425443, .atoms = 0 };
    if (current.reconciliation_cursor) |cursor| {
        evidence.before_balance_count = cursor.balance_count;
        @memcpy(evidence.before_balances[0..cursor.balance_count], cursor.balances[0..cursor.balance_count]);
    }
    evidence.balances[0] = .{ .asset = 1, .atoms = current.economic_projection.exchange.usdt_balance_atoms };
    evidence.balances[1] = .{ .asset = 0x425443, .atoms = 0 };
    evidence.asset_versions[0] = 1;
    evidence.asset_versions[1] = 1;
    if (current.economic_projection.exchange.nativeAsset(funding_acceptance.third_asset)) |native| {
        evidence.balance_count = 3;
        evidence.before_balance_count = 3;
        if (current.reconciliation_cursor == null) {
            var found = false;
            for (current.economic_baseline_balances[0..current.economic_baseline_balance_count]) |balance| if (balance.asset == funding_acceptance.third_asset) {
                evidence.before_balances[2] = balance;
                found = true;
            };
            std.debug.assert(found);
        }
        evidence.balances[2] = .{ .asset = funding_acceptance.third_asset, .atoms = native.balance_atoms };
        evidence.asset_versions[2] = current.asset_registry.get(funding_acceptance.third_asset).?.definition.version;
    }
    evidence.query_sources[0] = .{ .stream = 7, .sequence = sequence - 1, .digest = history.hash("all economic queries") };
    @memcpy(evidence.facts[0..facts.len], facts);
    var input = fixture.canonicalAt(40 + 2 * round, sequence, .{ .account_reconciliation_result = .{ .identity = 10000 + round, .complete = true, .account_economics = evidence } });
    input.venue.envelope.identity.stream = 7;
    input.venue.envelope.source_stream = 7;
    input.venue.envelope.raw_evidence = evidence.source;
    input.venue.event.account_reconciliation_result.account_economics.?.through_utc_ns = input.venue.envelope.times.source_utc_ns.?;
    return input;
}

fn fundingInput(round: u64) trading.CanonicalEvent {
    const identity = 9000 + round;
    return fixture.atGroup(39 + 2 * round, .{ .identity = identity, .payload = .{ .funding_settlement = .{ .settlement_id = identity, .amount_atoms = if (round == 4) 0 else -7 } } });
}

test "07 Owner ten closed funding windows preserve holdings economics and exact cold history across checkpoints" {
    const allocator = std.testing.allocator;
    var simulator: acceptance.RestingSimulator = .{};
    const harness = try funding_acceptance.createFundingHarnessWithNativeFees(1900, &simulator);
    defer harness.destroy();
    const baseline = harness.owner.shard.economic_baseline_utc_ns;
    const initial = harness.owner.shard.economicSummary();
    try expectNativeEconomics(&harness.owner.shard);
    const baseline_balances = harness.owner.shard.economic_baseline_balances;
    const baseline_count = harness.owner.shard.economic_baseline_balance_count;
    const fill_digest = harness.owner.shard.economic_projection.canonical_fill_evidence[0].digest;
    const expected_fill = try allocator.create(economics.FillArchiveRecord);
    defer allocator.destroy(expected_fill);
    expected_fill.* = (try harness.owner.shard.economic_projection.prepareFillArchive(8001, .{ .stream = harness.stream, .account = 2 }, harness.owner.shard.authoritativeBarrier())).record;
    var first_window: ?trading.CanonicalEvent = null;
    for (0..10) |round| {
        _ = try harness.owner.apply(fundingInput(round));
        const applied = harness.owner.shard.economic_projection.applied_fundings[0];
        var facts: [2]canonical.EconomicFactRef = undefined;
        var count: usize = 0;
        if (round == 0) {
            facts[count] = .{ .identity = 8001, .kind = .fill, .digest = fill_digest, .fee_confirmed = true };
            count += 1;
            const fill_root = try harness.owner.archiveFillHistory(8001, harness.gateway);
            try expectArchivedNativeFill(harness, fill_root, expected_fill);
            _ = try harness.owner.apply(fixture.atGroup(22, .{ .identity = 8002, .payload = .{ .oms_execution_report = .{ .report_id = 8002, .order_id = harness.command.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 2, .remaining_quantity = 18 } } }));
            try acceptance.recordTerminalArchiveCoverageFor(harness.owner, harness.command, .canceled, 2);
            _ = try harness.owner.archiveTerminalOrder(harness.command.order_id, harness.gateway);
            try std.testing.expectEqual(@as(u16, 0), harness.owner.shard.oms.order_count);
        }
        facts[count] = .{ .identity = applied.funding.identity, .kind = .funding, .digest = applied.payload_digest, .fee_confirmed = true };
        count += 1;
        const funding_root = try harness.owner.archiveFundingHistory(applied.funding.identity, harness.gateway);
        try expectArchivedFunding(harness, funding_root, applied);
        const input = windowInput(harness, round, facts[0..count]);
        if (round == 0) first_window = input;
        _ = try harness.owner.apply(input);
        try std.testing.expect(!harness.owner.shard.economic_projection.reconciliation_break);
        const before = harness.owner.shard.economicSummary();
        const ledger = harness.owner.shard.economic_projection.ledger_summary;
        const root = try harness.owner.archiveReconciliationWindowHistory(10000 + round, harness.gateway);
        try std.testing.expectEqualDeep(before, harness.owner.shard.economicSummary());
        try std.testing.expectEqualDeep(ledger, harness.owner.shard.economic_projection.ledger_summary);
        try std.testing.expectEqual(@as(u64, round + 2), harness.owner.shard.reconciliation_cursor.?.closed_economic_fact_count);
        try std.testing.expectEqual(baseline, harness.owner.shard.economic_baseline_utc_ns);
        try std.testing.expectEqual(baseline_count, harness.owner.shard.economic_baseline_balance_count);
        try std.testing.expectEqualDeep(baseline_balances, harness.owner.shard.economic_baseline_balances);
        try expectHeldEconomics(initial, &harness.owner.shard, round);
        try expectNativeEconomics(&harness.owner.shard);
        const result = try archivedRecord(harness, root, .{ .reconciliation_window = 10000 + round });
        const stored = try codec.decodeBare(result.record_bytes[0..result.record_len], trading.ReconciliationWindowArchiveQualification);
        try std.testing.expectEqualDeep(input.venue, stored.window.original);
        try harness.owner.checkpoint();
        try harness.gateway.checkpointDurableDispatch();
        const recovered = try allocator.create(demo.Owner);
        defer allocator.destroy(recovered);
        try demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream);
        try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        try std.testing.expectEqualDeep(harness.owner.shard.reconciliation_cursor, recovered.shard.reconciliation_cursor);
        try std.testing.expectEqualDeep(before, recovered.shard.economicSummary());
        try std.testing.expectEqualDeep(ledger, recovered.shard.economic_projection.ledger_summary);
        try std.testing.expectEqualDeep(baseline_balances, recovered.shard.economic_baseline_balances);
        try expectHeldEconomics(initial, &recovered.shard, round);
        try expectNativeEconomics(&recovered.shard);
        try std.testing.expectEqual(@as(u8, 3), recovered.shard.reconciliation_cursor.?.balance_count);
        try std.testing.expectEqual(@as(i128, 8), recovered.shard.reconciliation_cursor.?.balances[2].atoms);
        try std.testing.expectEqual(@as(u64, 0), recovered.shard.open_economic_fact_count);
        const recovered_gateway = try allocator.create(execution.Gateway);
        defer allocator.destroy(recovered_gateway);
        recovered_gateway.init();
        try recovered_gateway.add(harness.route);
        try recovered_gateway.attachRecoveredDurableDispatch(harness.backend.interface(), undefined, harness.dispatch_stream);
        try recovered.resumeReconciliationWindowArchive(recovered_gateway);
        try std.testing.expectEqual(@as(u64, 1), simulator.sends);
        try std.testing.expectEqual(@as(u64, 0), recovered_gateway.send_attempt_count);
        try expectArchivedNativeFill(harness, root, expected_fill);
    }
    const final = harness.owner.shard.economicSummary();
    try std.testing.expectEqual(initial.portfolio.swap.quantity, final.portfolio.swap.quantity);
    try std.testing.expectEqual(initial.portfolio.swap.open_cost_atoms, final.portfolio.swap.open_cost_atoms);
    try std.testing.expectEqual(initial.portfolio.margin_atoms, final.portfolio.margin_atoms);
    try std.testing.expectEqual(@as(i128, -63), final.portfolio.funding_atoms);
    try std.testing.expectEqual(initial.portfolio.realized_pnl_atoms, final.portfolio.realized_pnl_atoms);
    const before_duplicate = harness.owner.shard.economicSummary();
    _ = try harness.owner.apply(fundingInput(0));
    try std.testing.expectEqualDeep(before_duplicate, harness.owner.shard.economicSummary());
    var duplicate_window = first_window.?;
    duplicate_window.venue.envelope.identity.sequence = 200;
    duplicate_window.venue.envelope.source_sequence = 200;
    _ = try harness.owner.apply(duplicate_window);
    try std.testing.expect(!harness.owner.shard.history_conflict_latched);
    try std.testing.expectEqualDeep(before_duplicate, harness.owner.shard.economicSummary());
    try std.testing.expectEqual(@as(u16, 0), harness.owner.shard.oms.order_count);
}

fn expectNativeEconomics(current: *const trading.TradingShard) !void {
    const third = funding_acceptance.third_asset;
    const portfolio = current.economic_projection.portfolio.nativeAsset(third).?;
    const exchange = current.economic_projection.exchange.nativeAsset(third).?;
    try std.testing.expectEqual(@as(i128, -2), portfolio.balance_atoms);
    try std.testing.expectEqual(@as(i128, 8), exchange.balance_atoms);
    for ([_]economics.NativeAssetState{ portfolio, exchange }) |native| {
        try std.testing.expectEqual(@as(i128, 3), native.fee_atoms);
        try std.testing.expectEqual(@as(i128, 1), native.rebate_atoms);
    }
    try std.testing.expectEqual(@as(u8, 1), current.economic_projection.treasury_native_asset_count);
    try std.testing.expectEqualDeep(canonical.AssetAmount{ .asset = third, .atoms = 10 }, current.economic_projection.treasury_native_assets[0]);
}

fn expectHeldEconomics(initial: trading.EconomicSummary, current: *const trading.TradingShard, round: usize) !void {
    const now = current.economicSummary();
    const count: i128 = @intCast(round + 1 - @as(usize, if (round >= 4) 1 else 0));
    for ([_]economics.Layer{ now.portfolio, now.exchange }, [_]economics.Layer{ initial.portfolio, initial.exchange }) |actual, before| {
        try std.testing.expectEqual(@as(i64, 2), actual.swap.quantity);
        try std.testing.expectEqual(before.swap.open_cost_atoms, actual.swap.open_cost_atoms);
        try std.testing.expectEqual(before.margin_atoms, actual.margin_atoms);
        try std.testing.expectEqual(before.realized_pnl_atoms, actual.realized_pnl_atoms);
        try std.testing.expectEqual(before.unrealized_pnl_atoms, actual.unrealized_pnl_atoms);
        try std.testing.expectEqual(-7 * count, actual.funding_atoms);
        try std.testing.expectEqual(before.usdt_balance_atoms - 7 * count, actual.usdt_balance_atoms);
    }
    try std.testing.expectEqual(@as(u16, 0), current.oms.order_count);
    try std.testing.expectEqual(@as(u64, round + 2), current.reconciliation_cursor.?.closed_economic_fact_count);
    try current.economic_projection.assertClosed();
}

fn archivedRecord(harness: *acceptance.ArchiveHarness, root: history.Root, identity: history.Identity) !history.LookupResult {
    const request: history.LookupRequest = .{ .pending_id = 1, .key = .{ .origin = root.origin, .identity = identity }, .candidate_payload_digest = @splat(0), .original_input_digest = history.hash("combined native funding audit"), .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
    const result = try harness.backend.interface().queryOrderHistory(undefined, request);
    const verdict = try history.verifyResult(request, &result.proof, root);
    try std.testing.expect(verdict == .same or verdict == .conflict);
    try history.validateRecord(&result);
    return result;
}

fn expectArchivedNativeFill(harness: *acceptance.ArchiveHarness, root: history.Root, expected: *const economics.FillArchiveRecord) !void {
    const stored = try archivedRecord(harness, root, .{ .fill_detail = 8001 });
    const qualification = try codec.decodeBare(stored.record_bytes[0..stored.record_len], economics.FillArchiveQualification);
    const record = qualification.record;
    try std.testing.expectEqualDeep(expected.*, record);
    var native_transactions: u8 = 0;
    var seen = [_][2]bool{ .{ false, false }, .{ false, false } };
    for (record.ledger[0..record.ledger_count]) |transaction| {
        if (transaction.postings[0].asset != funding_acceptance.third_asset or transaction.postings[0].unit != .native_asset_atoms) continue;
        native_transactions += 1;
        try std.testing.expectEqual(@as(u8, 2), transaction.posting_count);
        try std.testing.expectEqual(economics.LedgerAccount.cash, transaction.postings[0].account);
        try std.testing.expectEqual(funding_acceptance.third_asset, transaction.postings[1].asset);
        try std.testing.expectEqual(economics.LedgerUnit.native_asset_atoms, transaction.postings[1].unit);
        try std.testing.expectEqual(@as(i128, 0), transaction.postings[0].amount + transaction.postings[1].amount);
        const kind: usize = switch (transaction.postings[1].account) {
            .fee_expense => blk: {
                try std.testing.expectEqual(@as(i128, -3), transaction.postings[0].amount);
                break :blk 0;
            },
            .rebate_income => blk: {
                try std.testing.expectEqual(@as(i128, 1), transaction.postings[0].amount);
                break :blk 1;
            },
            else => return error.UnexpectedNativePosting,
        };
        const layer = @intFromEnum(transaction.layer);
        try std.testing.expect(!seen[layer][kind]);
        seen[layer][kind] = true;
    }
    try std.testing.expectEqual(@as(u8, 4), native_transactions);
    try std.testing.expectEqualDeep([_][2]bool{ .{ true, true }, .{ true, true } }, seen);
}

fn expectArchivedFunding(harness: *acceptance.ArchiveHarness, root: history.Root, applied: economics.AppliedFunding) !void {
    const stored = try archivedRecord(harness, root, .{ .funding_detail = applied.funding.identity });
    const qualification = try codec.decodeBare(stored.record_bytes[0..stored.record_len], economics.FundingArchiveQualification);
    try std.testing.expectEqualDeep(applied, qualification.record.applied);
    const amount = applied.funding.amount.atoms;
    try std.testing.expectEqual(@as(u8, if (amount == 0) 0 else 2), qualification.record.ledger_count);
    var layers = [_]bool{ false, false };
    for (qualification.record.ledger[0..qualification.record.ledger_count]) |transaction| {
        try std.testing.expectEqual(economics.FactKind.funding, transaction.kind);
        try std.testing.expectEqual(applied.funding.identity, transaction.source_identity);
        const layer = @intFromEnum(transaction.layer);
        try std.testing.expect(!layers[layer]);
        layers[layer] = true;
        try std.testing.expectEqual(@as(u8, 2), transaction.posting_count);
        try std.testing.expectEqualDeep(economics.LedgerPosting{ .account = .cash, .unit = .settlement_atoms, .asset = 1, .amount = amount }, transaction.postings[0]);
        try std.testing.expectEqualDeep(economics.LedgerPosting{ .account = .funding_pnl, .unit = .settlement_atoms, .asset = 1, .amount = -amount }, transaction.postings[1]);
    }
    if (amount != 0) try std.testing.expectEqualDeep([_]bool{ true, true }, layers);
}

test "07 Owner complete empty windows advance with zero holdings and no economic facts" {
    const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, 1950);
    defer harness.destroy();
    for (0..10) |round| {
        _ = try harness.owner.apply(windowInput(harness, round, &.{}));
        _ = try harness.owner.archiveReconciliationWindowHistory(10000 + round, harness.gateway);
        try harness.owner.checkpoint();
    }
    try std.testing.expectEqual(@as(u64, 0), harness.owner.shard.reconciliation_cursor.?.closed_economic_fact_count);
    try std.testing.expectEqual(@as(i64, 0), harness.owner.shard.economic_projection.portfolio.swap.quantity);
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream);
    try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
}
