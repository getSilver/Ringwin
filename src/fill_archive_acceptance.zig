//! Small public Owner/Gateway checks for economic fill history reclamation.
const std = @import("std");
const acceptance = @import("order_gateway_archive_acceptance.zig");
const canonical = @import("canonical_event.zig");
const demo = @import("demo_authority.zig");
const execution = @import("execution_gateway.zig");
const fixture = @import("trading_shard_fixture.zig");
const trading = @import("trading_shard.zig");
const venue = @import("venue_adapter.zig");
const history = @import("business_history.zig");

fn coreFillCoverage(harness: *acceptance.ArchiveHarness, sequence: u64, identity: u128, fill_id: u64, digest: history.Digest) trading.CanonicalEvent {
    const projection = &harness.owner.shard.economic_projection;
    var evidence: canonical.AccountEconomicEvidence = .{
        .exchange_account = 2,
        .scope = .spot_and_isolated_linear_usdt,
        .from_utc_ns = harness.owner.shard.economic_baseline_utc_ns,
        .through_utc_ns = 1,
        .source = .{ .stream = 7, .sequence = sequence, .digest = history.hash("complete account snapshot") },
        .before_source = .{ .stream = 7, .sequence = 1, .digest = history.hash("opening account snapshot") },
        .query_count = 1,
        .balance_count = 2,
        .before_balance_count = 2,
        .covered_economic_fact_count = 1,
        .bills_complete = true,
        .bill_chain_digest = history.hash("complete economic interval"),
    };
    evidence.query_sources[0] = .{ .stream = 7, .sequence = sequence - 1, .digest = history.hash("complete economic query") };
    evidence.facts[0] = .{ .identity = fill_id, .kind = .fill, .digest = digest, .fee_confirmed = true };
    evidence.before_balances[0] = .{ .asset = 1, .atoms = 25_000_000_000 };
    evidence.before_balances[1] = .{ .asset = 0x425443, .atoms = 0 };
    evidence.balances[0] = .{ .asset = 1, .atoms = projection.exchange.usdt_balance_atoms };
    evidence.balances[1] = .{ .asset = 0x425443, .atoms = projection.exchange.nativeAsset(0x425443).?.balance_atoms };
    evidence.asset_versions[0] = 1;
    evidence.asset_versions[1] = 1;
    var input = fixture.canonicalAt(100 + sequence, sequence, .{ .account_reconciliation_result = .{ .identity = identity, .complete = true, .account_economics = evidence } });
    input.venue.envelope.identity.stream = 7;
    input.venue.envelope.source_stream = 7;
    input.venue.envelope.raw_evidence = evidence.source;
    input.venue.event.account_reconciliation_result.account_economics.?.through_utc_ns = input.venue.envelope.times.source_utc_ns.?;
    return input;
}

test "Owner fill archive preserves Core fill economic coverage through cold proof and recovery" {
    const allocator = std.testing.allocator;
    const harness = try acceptance.ArchiveHarness.createBase(allocator, 1670);
    defer harness.destroy();
    var simulator: acceptance.RestingSimulator = .{};
    try harness.bindAdapter(simulator.adapter());
    const command = try place(harness, &simulator, 101);
    _ = try harness.owner.apply(fixture.atGroup(24, .{ .identity = 8001, .payload = .{ .economic_fill = .{ .fill_id = 8001, .order_id = command.order_id, .quantity = 2, .price_ticks = 50_000_000 } } }));
    const digest = harness.owner.shard.economic_projection.canonical_fill_evidence[0].digest;
    try std.testing.expectEqual(@as(i128, 24_999_999_999), harness.owner.shard.economic_projection.exchange.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, 2), harness.owner.shard.economic_projection.exchange.nativeAsset(0x425443).?.balance_atoms);
    _ = try harness.owner.apply(coreFillCoverage(harness, 3, 8201, 8001, digest));
    try std.testing.expect(!harness.owner.shard.economic_projection.reconciliation_break);
    const portfolio = harness.owner.shard.economic_projection.portfolio;
    const exchange = harness.owner.shard.economic_projection.exchange;
    const ledger_summary = harness.owner.shard.economic_projection.ledger_summary;
    _ = try harness.owner.archiveFillHistory(8001, harness.gateway);
    _ = try harness.owner.apply(coreFillCoverage(harness, 5, 8202, 8001, digest));
    try std.testing.expect(!harness.owner.shard.history_conflict_latched);
    try std.testing.expect(!harness.owner.shard.economic_projection.reconciliation_break);
    try std.testing.expectEqualDeep(portfolio, harness.owner.shard.economic_projection.portfolio);
    try std.testing.expectEqualDeep(exchange, harness.owner.shard.economic_projection.exchange);
    try std.testing.expectEqualDeep(ledger_summary, harness.owner.shard.economic_projection.ledger_summary);
    try harness.owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream);
    try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(i64, 2), try recovered.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    try std.testing.expectEqual(@as(i64, 0), recovered.shard.oms.orderById(command.order_id).?.cumulative_quantity);
    try std.testing.expectEqual(@as(u64, 1), simulator.sends);
}

test "Owner fill snapshot rejects inconsistent cumulative quantity and resident evidence" {
    const allocator = std.testing.allocator;
    const harness = try acceptance.ArchiveHarness.createBase(allocator, 1660);
    defer harness.destroy();
    var simulator: acceptance.RestingSimulator = .{};
    try harness.bindAdapter(simulator.adapter());
    const command = try place(harness, &simulator, 101);
    _ = try harness.owner.apply(try fillInput(harness, command, 1, 6001, 18, 1));
    const storage = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(storage);
    const restored = try allocator.create(trading.TradingShard);
    defer allocator.destroy(restored);
    const projection = &harness.owner.shard.economic_projection;
    const digest = projection.applied_fills[0].payload_digest;
    var sealed = harness.owner.decision_journal;
    try sealed.seal();
    for (0..4) |mode| {
        switch (mode) {
            0 => projection.applied_fill_totals[0].quantity = 1,
            1 => projection.applied_fill_total_count = 0,
            2 => projection.applied_fills[0].payload_digest[0] ^= 1,
            3 => {
                projection.applied_fill_totals[1] = .{ .order_id = 999, .quantity = 1, .archived_quantity = 1 };
                projection.applied_fill_total_count = 2;
            },
            else => unreachable,
        }
        const encoded = try harness.owner.shard.snapshot(&sealed, harness.owner.shard.authoritativeBarrier(), storage);
        // Payload substitution is rejected by the open-fact cross-check before
        // the economic projection validates cumulative quantities.
        try std.testing.expectError(if (mode == 2 or mode == 3) error.InvalidSnapshotState else error.InvalidEconomicFact, trading.TradingShard.restoreSnapshotInto(restored, encoded));
        projection.applied_fill_totals[0].quantity = 18;
        projection.applied_fill_total_count = 1;
        projection.applied_fills[0].payload_digest = digest;
    }
    var encoded = try harness.owner.shard.snapshot(&sealed, harness.owner.shard.authoritativeBarrier(), storage);
    _ = try trading.TradingShard.restoreSnapshotInto(restored, encoded);
    try std.testing.expectEqual(@as(i64, 18), try restored.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    _ = try harness.owner.archiveFillHistory(6001, harness.gateway);
    sealed = harness.owner.decision_journal;
    try sealed.seal();
    encoded = try harness.owner.shard.snapshot(&sealed, harness.owner.shard.authoritativeBarrier(), storage);
    _ = try trading.TradingShard.restoreSnapshotInto(restored, encoded);
    try std.testing.expectEqual(@as(i64, 18), try restored.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    try std.testing.expectEqual(@as(u8, 0), restored.economic_projection.applied_fill_count);
    projection.applied_fill_totals[0].quantity = 1;
    encoded = try harness.owner.shard.snapshot(&sealed, harness.owner.shard.authoritativeBarrier(), storage);
    try std.testing.expectError(error.InvalidEconomicFact, trading.TradingShard.restoreSnapshotInto(restored, encoded));
    projection.applied_fill_totals[0].quantity = 18;
    try std.testing.expectEqual(@as(u64, 1), simulator.sends);
}

fn place(harness: *acceptance.ArchiveHarness, simulator: *acceptance.RestingSimulator, identity: u64) !trading.oms.Command {
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = identity, .count = 1 };
    group.members[0] = .{ .intent_sequence = identity, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    _ = try harness.owner.apply(fixture.atGroup(20 + identity - 101, .{ .identity = identity, .payload = .{ .oms_intent_group = group } }));
    const command = harness.owner.shard.oms.emitted()[0];
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, command.command_id, 2 * std.time.ns_per_s));
    try harness.owner.applyAdapterBatch((try simulator.adapter().tryDrain()).?);
    return command;
}

fn fillInput(harness: *acceptance.ArchiveHarness, command: trading.oms.Command, sequence: u64, identity: u64, lots: i64, asset: canonical.AssetIdentity) !trading.CanonicalEvent {
    var trade_buffer: [32]u8 = undefined;
    var order_buffer: [32]u8 = undefined;
    return privateInput(sequence, .{ .fill = .{
        .identity = identity,
        .order = command.order_id,
        .client_order_id = harness.gateway.acceptedClientOrderIdFromShard(&harness.owner.shard, command.command_id).?,
        .venue_order = try canonical.VenueOrderRef.init(1, try std.fmt.bufPrint(&order_buffer, "archive-order-{d}", .{command.order_id})),
        .venue_trade = try canonical.VenueTradeRef.init(1, try std.fmt.bufPrint(&trade_buffer, "archive-trade-{d}", .{identity})),
        .instrument = 3,
        .exchange_account = 2,
        .side = .buy,
        .quantity = .{ .instrument = 3, .rules_version = 1, .lots = lots },
        .price = fixture.omsPrice(3, 50_000_000),
        .fee = .{ .asset = asset, .atoms = 3 },
        .rebate = .{ .asset = asset, .atoms = 1 },
        .liquidity = .taker,
    } });
}

fn terminalCoverage(harness: *acceptance.ArchiveHarness, command: trading.oms.Command, sequence: u64) !void {
    const client = harness.gateway.acceptedClientOrderIdFromShard(&harness.owner.shard, command.command_id).?;
    _ = try harness.owner.apply(privateInput(sequence, .{ .execution_report = .{
        .identity = 9000 + sequence,
        .order = command.order_id,
        .client_order_id = client,
        .instrument = 3,
        .exchange_account = 2,
        .revision = command.revision,
        .status = .filled,
        .original_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 20 },
        .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 20 },
        .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 0 },
    } }));
    const order = harness.owner.shard.oms.orderById(command.order_id).?;
    const deadline = order.terminal_observed_at_utc_ns + 30 * std.time.ns_per_s;
    const digest = @import("business_history.zig").hash("complete fill archive terminal coverage");
    var input = privateInput(sequence + 1, .{ .order_reconciliation_result = .{
        .identity = 10000 + sequence,
        .complete = true,
        .status = .found_terminal,
        .order = command.order_id,
        .revision = command.revision,
        .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 20 },
        .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 0 },
        .terminal_status = .filled,
        .rules_version = 1,
        .evidence = .{
            .scope = .{ .exchange_account = 2, .instrument = 3, .order = command.order_id, .revision = command.revision, .from_utc_ns = order.created_at_utc_ns, .through_utc_ns = deadline },
            .observed_at_utc_ns = deadline,
            .source = .{ .stream = 8, .sequence = sequence + 1, .digest = digest },
            .terminal_archive = .{ .visibility_deadline_utc_ns = deadline, .order_history_complete = true, .terminal_history_complete = true, .fills_complete = true, .economics_complete = true },
        },
    } });
    input.venue.envelope.raw_evidence.digest = digest;
    input.venue.envelope.times.source_utc_ns = deadline;
    input.venue.envelope.times.receive_utc_ns = deadline;
    _ = try harness.owner.apply(input);
}

fn privateInput(sequence: u64, payload: canonical.Payload) trading.CanonicalEvent {
    var input = fixture.canonicalAt(100 + sequence, sequence, payload);
    input.venue.envelope.identity.stream = 8;
    input.venue.envelope.source_stream = 8;
    input.venue.envelope.raw_evidence.stream = 8;
    return input;
}

test "Owner reclaims ten partial fill windows without losing per order quantity and recovers cold facts without sending" {
    const allocator = std.testing.allocator;
    const harness = try acceptance.ArchiveHarness.createBase(allocator, 1600);
    defer harness.destroy();
    var simulator: acceptance.RestingSimulator = .{};
    try harness.bindAdapter(simulator.adapter());
    var commands: [2]trading.oms.Command = undefined;
    for (&commands, 0..) |*command, index| {
        const identity: u64 = 101 + index;
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = identity, .count = 1 };
        group.members[0] = .{ .intent_sequence = identity, .operation = .place, .instrument = 3, .quantity = 40, .limit_price = fixture.omsPrice(3, 50_000_000) };
        _ = try harness.owner.apply(fixture.atGroup(20 + index, .{ .identity = identity, .payload = .{ .oms_intent_group = group } }));
        command.* = harness.owner.shard.oms.emitted()[0];
        try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, command.command_id, 2 * std.time.ns_per_s));
        try harness.owner.applyAdapterBatch((try simulator.adapter().tryDrain()).?);
    }
    try std.testing.expectEqual(@as(u64, 2), simulator.sends);
    var source_sequence: u64 = 1;
    var first_fill: ?trading.CanonicalEvent = null;
    for (0..10) |window| {
        for (commands, 0..) |command, index| {
            // Two lots make one settlement atom at this fixture's price and denominator.
            const cumulative: i64 = @intCast(2 * (window + 1));
            const fill_id: u64 = 1000 + 2 * window + index;
            const client = harness.gateway.acceptedClientOrderIdFromShard(&harness.owner.shard, command.command_id).?;
            var trade_buffer: [32]u8 = undefined;
            const trade = try canonical.VenueTradeRef.init(1, try std.fmt.bufPrint(&trade_buffer, "fill-archive-{d}", .{fill_id}));
            const report_payload: canonical.Payload = .{ .execution_report = .{
                .identity = 2000 + fill_id,
                .order = command.order_id,
                .client_order_id = client,
                .instrument = 3,
                .exchange_account = 2,
                .revision = command.revision,
                .status = .partially_filled,
                .original_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 40 },
                .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = cumulative },
                .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 40 - cumulative },
            } };
            const fill_payload: canonical.Payload = .{ .fill = .{
                .identity = fill_id,
                .order = command.order_id,
                .client_order_id = client,
                .venue_order = try canonical.VenueOrderRef.init(1, "fill-archive-order"),
                .venue_trade = trade,
                .instrument = 3,
                .exchange_account = 2,
                .side = .buy,
                .quantity = .{ .instrument = 3, .rules_version = 1, .lots = 2 },
                .price = fixture.omsPrice(3, 50_000_000),
                .fee = .{ .asset = 1, .atoms = 3 },
                .rebate = .{ .asset = 1, .atoms = 1 },
                .liquidity = .taker,
            } };
            if (window % 2 == 0) {
                _ = try harness.owner.apply(privateInput(source_sequence, report_payload));
                source_sequence += 1;
                try std.testing.expectEqual(cumulative - 2, try harness.owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
            }
            const fill_input = privateInput(source_sequence, fill_payload);
            source_sequence += 1;
            _ = try harness.owner.apply(fill_input);
            if (first_fill == null) first_fill = fill_input;
            try std.testing.expectEqual(cumulative, try harness.owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
            if (window % 2 != 0) {
                try std.testing.expectEqual(cumulative - 2, harness.owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
                _ = try harness.owner.apply(privateInput(source_sequence, report_payload));
                source_sequence += 1;
            }
            const portfolio = harness.owner.shard.economic_projection.portfolio;
            const exchange = harness.owner.shard.economic_projection.exchange;
            const next_order = harness.owner.shard.oms.next_order_id;
            const next_command = harness.owner.shard.oms.next_command_id;
            _ = try harness.owner.archiveFillHistory(fill_id, harness.gateway);
            try std.testing.expectEqualDeep(portfolio, harness.owner.shard.economic_projection.portfolio);
            try std.testing.expectEqualDeep(exchange, harness.owner.shard.economic_projection.exchange);
            try std.testing.expectEqual(cumulative, try harness.owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
            try std.testing.expectEqual(cumulative, harness.owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
            try std.testing.expectEqual(next_order, harness.owner.shard.oms.next_order_id);
            try std.testing.expectEqual(next_command, harness.owner.shard.oms.next_command_id);
            try std.testing.expectEqual(@as(u8, 0), harness.owner.shard.economic_projection.applied_fill_count);
            try harness.owner.checkpoint();
            try harness.gateway.checkpointDurableDispatch();
        }
    }
    // The bounded detail view retains sixteen entries while the complete
    // authoritative high-water count still covers all twenty archived fills.
    try std.testing.expectEqual(@as(u64, 20), harness.owner.shard.open_economic_fact_count);
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream);
    try std.testing.expectEqual(@as(u64, 20), recovered.shard.open_economic_fact_count);
    const gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.add(harness.route);
    try gateway.attachRecoveredDurableDispatch(harness.backend.interface(), undefined, harness.dispatch_stream);
    try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try recovered.resumeFillArchive(gateway);
    for (commands) |command| {
        try std.testing.expectEqual(@as(i64, 20), try recovered.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
        try std.testing.expectEqual(@as(i64, 20), recovered.shard.oms.orderById(command.order_id).?.cumulative_quantity);
        try std.testing.expectEqual(harness.gateway.acceptedClientOrderIdFromShard(&harness.owner.shard, command.command_id), gateway.acceptedClientOrderIdFromShard(&recovered.shard, command.command_id));
    }
    const economics = recovered.shard.economic_projection.semanticDigest();
    const next_order = recovered.shard.oms.next_order_id;
    const next_command = recovered.shard.oms.next_command_id;
    const command_history_count = recovered.shard.oms.command_history_count;
    _ = try recovered.apply(first_fill.?);
    try std.testing.expectEqualSlices(u8, &economics, &recovered.shard.economic_projection.semanticDigest());
    try std.testing.expect(!recovered.shard.history_conflict_latched);
    try std.testing.expectEqual(next_order, recovered.shard.oms.next_order_id);
    try std.testing.expectEqual(next_command, recovered.shard.oms.next_command_id);
    try std.testing.expectEqual(command_history_count, recovered.shard.oms.command_history_count);
    var conflict = first_fill.?;
    conflict.venue.event.fill.fee.?.atoms += 1;
    _ = try recovered.apply(conflict);
    try std.testing.expect(recovered.shard.history_conflict_latched and recovered.shard.oms.recovery_only);
    try std.testing.expectEqualSlices(u8, &economics, &recovered.shard.economic_projection.semanticDigest());
    try std.testing.expectEqual(next_order, recovered.shard.oms.next_order_id);
    try std.testing.expectEqual(next_command + 2, recovered.shard.oms.next_command_id);
    try std.testing.expectEqual(command_history_count + 2, recovered.shard.oms.command_history_count);
    for (recovered.shard.oms.command_history[command_history_count..recovered.shard.oms.command_history_count], commands, 0..) |cancellation, original, index| {
        try std.testing.expectEqual(trading.oms.Operation.cancel, cancellation.operation);
        try std.testing.expectEqual(original.order_id, cancellation.order_id);
        try std.testing.expectEqual(next_command + index, cancellation.command_id);
        try std.testing.expectEqual(trading.oms.OrderState.pending_cancel, recovered.shard.oms.orderById(original.order_id).?.state);
    }
    try std.testing.expectEqual(@as(u64, 2), simulator.sends);
}

test "07 Owner archives repeated third asset fees and rebates with complete ledger and closed window" {
    const allocator = std.testing.allocator;
    const third: canonical.AssetIdentity = 0x424e42;
    var definition = @import("asset_registry.zig").testDefinitions(6, 8)[0];
    definition.asset = third;
    definition.source_identity += third;
    definition.code_bindings = @splat(.{});
    definition.code_binding_count = 1;
    definition.code_bindings[0] = try canonical.AssetCodeBinding.init(1, "BNB");
    const opening = [_]canonical.AssetAmount{.{ .asset = third, .atoms = 10 }};
    const harness = try acceptance.ArchiveHarness.createBaseWithNativeBalances(allocator, 1610, &.{definition}, &opening);
    defer harness.destroy();
    try std.testing.expect(harness.owner.shard.genesisReady());
    try std.testing.expect(harness.owner.shard.settlementConsumersCompatible(3));
    try std.testing.expectEqual(@as(i128, 10), harness.owner.shard.economic_projection.exchange.nativeAsset(third).?.balance_atoms);
    try std.testing.expectEqual(@as(i128, 0), harness.owner.shard.economic_projection.portfolio.nativeAsset(third).?.balance_atoms);
    try std.testing.expectEqual(@as(u8, 1), harness.owner.shard.economic_projection.treasury_native_asset_count);
    try std.testing.expectEqualDeep(opening[0], harness.owner.shard.economic_projection.treasury_native_assets[0]);
    var simulator: acceptance.RestingSimulator = .{};
    try harness.bindAdapter(simulator.adapter());
    const command = try place(harness, &simulator, 101);
    var first = try fillInput(harness, command, 1, 3001, 2, third);
    first.venue.event.fill.venue_fill_time_utc_ns = first.venue.envelope.times.source_utc_ns;
    var facts: [2]canonical.EconomicFactRef = undefined;
    for (0..2) |index| {
        var input = if (index == 0) first else try fillInput(harness, command, 2, 3002, 2, third);
        input.venue.event.fill.venue_fill_time_utc_ns = input.venue.envelope.times.source_utc_ns;
        _ = try harness.owner.apply(input);
        facts[index] = .{ .identity = 3001 + index, .kind = .fill, .digest = harness.owner.shard.economic_projection.canonical_fill_evidence[0].digest, .fee_confirmed = true };
        const portfolio = harness.owner.shard.economic_projection.portfolio;
        const exchange = harness.owner.shard.economic_projection.exchange;
        const root = try harness.owner.archiveFillHistory(3001 + index, harness.gateway);
        const stored = try harness.backend.interface().queryOrderHistory(undefined, .{ .pending_id = 1, .key = .{ .origin = root.origin, .identity = .{ .fill_detail = 3001 + index } }, .candidate_payload_digest = @splat(0), .original_input_digest = root.qualification_digest, .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier });
        try history.validateRecord(&stored);
        const record = (try @import("snapshot_codec.zig").decodeBare(stored.record_bytes[0..stored.record_len], @import("economics.zig").FillArchiveQualification)).record;
        var native_transactions: u8 = 0;
        for (record.ledger[0..record.ledger_count]) |transaction| {
            if (transaction.postings[0].asset != third or transaction.postings[0].unit != .native_asset_atoms) continue;
            native_transactions += 1;
            try std.testing.expectEqual(@as(u8, 2), transaction.posting_count);
            try std.testing.expectEqual(@as(i128, 0), transaction.postings[0].amount + transaction.postings[1].amount);
            try std.testing.expectEqual(third, transaction.postings[1].asset);
            switch (transaction.postings[1].account) {
                .fee_expense => try std.testing.expectEqual(@as(i128, -3), transaction.postings[0].amount),
                .rebate_income => try std.testing.expectEqual(@as(i128, 1), transaction.postings[0].amount),
                else => return error.UnexpectedNativePosting,
            }
        }
        try std.testing.expectEqual(@as(u8, 4), native_transactions);
        try std.testing.expectEqualDeep(portfolio, harness.owner.shard.economic_projection.portfolio);
        try std.testing.expectEqualDeep(exchange, harness.owner.shard.economic_projection.exchange);
    }
    try std.testing.expectEqual(@as(i64, 4), try harness.owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    try std.testing.expectEqual(@as(i64, 0), harness.owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
    const native = harness.owner.shard.economic_projection.portfolio.nativeAsset(third).?;
    try std.testing.expectEqual(@as(i128, 6), native.fee_atoms);
    try std.testing.expectEqual(@as(i128, 2), native.rebate_atoms);
    try std.testing.expectEqual(@as(i128, -4), native.balance_atoms);
    const exchange_native = harness.owner.shard.economic_projection.exchange.nativeAsset(third).?;
    try std.testing.expectEqual(@as(i128, 6), exchange_native.fee_atoms);
    try std.testing.expectEqual(@as(i128, 2), exchange_native.rebate_atoms);
    try std.testing.expectEqual(@as(i128, 6), exchange_native.balance_atoms);
    try std.testing.expectEqualDeep(opening[0], harness.owner.shard.economic_projection.treasury_native_assets[0]);
    var account_window = @import("reconciliation_archive_acceptance.zig").windowInput(harness, 0, &facts);
    const closing = fixture.canonicalAt(200, 10, .{ .account_reconciliation_result = .{ .identity = 10000, .complete = true } });
    account_window.venue.envelope.times = closing.venue.envelope.times;
    var evidence = &account_window.venue.event.account_reconciliation_result.account_economics.?;
    evidence.through_utc_ns = closing.venue.envelope.times.source_utc_ns.?;
    evidence.balance_count = 3;
    evidence.before_balance_count = 3;
    evidence.before_balances[2] = opening[0];
    evidence.balances[1].atoms = 4;
    evidence.balances[2] = .{ .asset = third, .atoms = 6 };
    evidence.asset_versions[2] = definition.version;
    _ = try harness.owner.apply(account_window);
    _ = try harness.owner.archiveReconciliationWindowHistory(10000, harness.gateway);
    try harness.owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream);
    try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try std.testing.expectEqualDeep(native, recovered.shard.economic_projection.portfolio.nativeAsset(third).?);
    try std.testing.expectEqualDeep(exchange_native, recovered.shard.economic_projection.exchange.nativeAsset(third).?);
    try std.testing.expectEqualDeep(opening[0], recovered.shard.economic_projection.treasury_native_assets[0]);
    const portfolio = recovered.shard.economic_projection.portfolio;
    const exchange = recovered.shard.economic_projection.exchange;
    _ = try recovered.apply(first);
    try std.testing.expectEqualDeep(portfolio, recovered.shard.economic_projection.portfolio);
    try std.testing.expectEqualDeep(exchange, recovered.shard.economic_projection.exchange);
    try std.testing.expectEqual(@as(i64, 4), try recovered.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    try std.testing.expectEqual(@as(u64, 1), simulator.sends);
}

test "Owner fill archive publication and Gateway failure boundaries retain recoverable economic facts" {
    const allocator = std.testing.allocator;
    for ([_]@TypeOf(@as(acceptance.ArchiveFaultMemory, undefined).stage){ .history_publish, .decision_commit, .gateway_append, .gateway_checkpoint }, 0..) |stage, index| {
        const harness = try acceptance.ArchiveHarness.createBase(allocator, 1620 + 2 * index);
        defer harness.destroy();
        var simulator: acceptance.RestingSimulator = .{};
        try harness.bindAdapter(simulator.adapter());
        const command = try place(harness, &simulator, 101);
        _ = try harness.owner.apply(try fillInput(harness, command, 1, 4001, 2, 1));
        try harness.owner.checkpoint();
        const portfolio = harness.owner.shard.economic_projection.portfolio;
        const exchange = harness.owner.shard.economic_projection.exchange;
        const before = harness.owner.shard.canonicalStateDigest();
        const committed = stage == .gateway_append or stage == .gateway_checkpoint;
        harness.backend.stage = stage;
        try std.testing.expectError(switch (stage) {
            .decision_commit => error.DecisionLogUnavailable,
            .gateway_append => error.InjectedEio,
            else => error.InjectedEio,
        }, harness.owner.archiveFillHistory(4001, harness.gateway));
        try std.testing.expect(harness.owner.closed);
        try std.testing.expectEqualDeep(portfolio, harness.owner.shard.economic_projection.portfolio);
        try std.testing.expectEqualDeep(exchange, harness.owner.shard.economic_projection.exchange);
        try std.testing.expectEqual(committed, harness.owner.shard.business_history_root != null);
        try std.testing.expectEqual(@as(u8, if (committed) 0 else 1), harness.owner.shard.economic_projection.applied_fill_count);
        const recovered = try allocator.create(demo.Owner);
        defer allocator.destroy(recovered);
        const store = harness.backend.memory.interface();
        try demo.Owner.recoverInto(recovered, store, undefined, harness.stream);
        const gateway = try allocator.create(execution.Gateway);
        defer allocator.destroy(gateway);
        gateway.init();
        try gateway.add(harness.route);
        try gateway.attachRecoveredDurableDispatch(store, undefined, harness.dispatch_stream);
        try std.testing.expectEqualDeep(portfolio, recovered.shard.economic_projection.portfolio);
        try std.testing.expectEqualDeep(exchange, recovered.shard.economic_projection.exchange);
        try std.testing.expectEqual(@as(i64, 2), try recovered.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
        try std.testing.expectEqual(harness.gateway.acceptedClientOrderIdFromShard(&harness.owner.shard, command.command_id), gateway.acceptedClientOrderIdFromShard(&recovered.shard, command.command_id));
        if (committed) {
            try recovered.resumeFillArchive(gateway);
            const completed = try store.recover(undefined, harness.dispatch_stream);
            try recovered.resumeFillArchive(gateway);
            const repeated = try store.recover(undefined, harness.dispatch_stream);
            try std.testing.expectEqual(completed.last_sequence, repeated.last_sequence);
            try std.testing.expectEqual(completed.committed_barrier, repeated.committed_barrier);
            try std.testing.expectEqual(completed.segment_index, repeated.segment_index);
        } else {
            try std.testing.expectEqual(@as(u8, 1), recovered.shard.economic_projection.applied_fill_count);
            try std.testing.expect(recovered.shard.business_history_root == null);
            if (stage == .decision_commit) {
                try std.testing.expect(recovered.closed);
                try std.testing.expectError(error.DecisionLogUnavailable, recovered.source());
                const persisted = try store.recover(undefined, harness.stream);
                try std.testing.expect(persisted.last_sequence > persisted.committed_barrier);
            } else try std.testing.expectEqualSlices(u8, &before, &recovered.shard.canonicalStateDigest());
        }
        try std.testing.expectEqual(@as(u64, 1), simulator.sends);
    }
}

test "Owner order then fill then order archive lineage recovers old ownership without sending" {
    const allocator = std.testing.allocator;
    const harness = try acceptance.ArchiveHarness.createBase(allocator, 1640);
    defer harness.destroy();
    var simulator: acceptance.RestingSimulator = .{};
    try harness.bindAdapter(simulator.adapter());
    const first_command = try place(harness, &simulator, 101);
    const second_command = try place(harness, &simulator, 102);
    const first_fill = try fillInput(harness, first_command, 1, 5001, 20, 1);
    _ = try harness.owner.apply(first_fill);
    try terminalCoverage(harness, first_command, 2);
    try std.testing.expectError(error.OrderArchivePinned, harness.owner.archiveTerminalOrder(first_command.order_id, harness.gateway));
    _ = try harness.owner.archiveFillHistory(5001, harness.gateway);
    const order_root = try harness.owner.archiveTerminalOrder(first_command.order_id, harness.gateway);
    const second_fill = try fillInput(harness, second_command, 4, 5002, 20, 1);
    _ = try harness.owner.apply(second_fill);
    try terminalCoverage(harness, second_command, 5);
    const fill_root = try harness.owner.archiveFillHistory(5002, harness.gateway);
    try std.testing.expectEqualSlices(u8, &order_root.root_digest, &fill_root.previous_root);
    const final_root = try harness.owner.archiveTerminalOrder(second_command.order_id, harness.gateway);
    try std.testing.expectEqualSlices(u8, &fill_root.root_digest, &final_root.previous_root);
    try std.testing.expectEqual(@as(u16, 0), harness.owner.shard.oms.order_count);
    try std.testing.expectEqual(@as(u16, 0), harness.gateway.accepted_dispatch_count);
    try harness.owner.checkpoint();
    try harness.gateway.checkpointDurableDispatch();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream);
    const gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.add(harness.route);
    try gateway.attachRecoveredDurableDispatch(harness.backend.interface(), undefined, harness.dispatch_stream);
    try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try recovered.resumeOrderArchive(gateway);
    const portfolio = recovered.shard.economic_projection.portfolio;
    const exchange = recovered.shard.economic_projection.exchange;
    const next_order = recovered.shard.oms.next_order_id;
    const next_command = recovered.shard.oms.next_command_id;
    for ([_]trading.CanonicalEvent{ first_fill, second_fill }) |input| _ = try recovered.apply(input);
    try std.testing.expect(!recovered.shard.history_conflict_latched);
    try std.testing.expectEqualDeep(portfolio, recovered.shard.economic_projection.portfolio);
    try std.testing.expectEqualDeep(exchange, recovered.shard.economic_projection.exchange);
    var conflict = first_fill;
    conflict.venue.event.fill.rebate.?.atoms += 1;
    _ = try recovered.apply(conflict);
    try std.testing.expect(recovered.shard.history_conflict_latched and recovered.shard.oms.recovery_only);
    try std.testing.expectEqualDeep(portfolio, recovered.shard.economic_projection.portfolio);
    try std.testing.expectEqualDeep(exchange, recovered.shard.economic_projection.exchange);
    try std.testing.expectEqual(next_order, recovered.shard.oms.next_order_id);
    try std.testing.expectEqual(next_command, recovered.shard.oms.next_command_id);
    try std.testing.expectEqual(@as(u64, 2), simulator.sends);
}
