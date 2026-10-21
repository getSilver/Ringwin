//! Public funding archive fault boundaries; no Venue calls are required.
const std = @import("std");
const canonical = @import("../../../model/canonical_event.zig");
const acceptance = @import("order_gateway_archive_acceptance.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const trading = @import("../../../trading/trading_shard.zig");
const history = @import("../../../persistence/business_history.zig");
const economics = @import("../../../portfolio/economics.zig");
const codec = @import("../../../persistence/snapshot_codec.zig");

pub fn createFundingHarness(id: u64) !*acceptance.ArchiveHarness {
    return createFundingHarnessWithAdapter(id, null);
}

pub fn createFundingHarnessWithAdapter(id: u64, simulator: ?*acceptance.RestingSimulator) !*acceptance.ArchiveHarness {
    return createFundingHarnessOptions(id, simulator, false);
}

pub const third_asset: canonical.AssetIdentity = 0x424e42;

pub fn createFundingHarnessWithNativeFees(id: u64, simulator: *acceptance.RestingSimulator) !*acceptance.ArchiveHarness {
    return createFundingHarnessOptions(id, simulator, true);
}

fn createFundingHarnessOptions(id: u64, simulator: ?*acceptance.RestingSimulator, native_fees: bool) !*acceptance.ArchiveHarness {
    const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, id);
    errdefer harness.destroy();
    // A distinct virgin decision identity keeps the reusable harness ownership.
    harness.stream.id += 10000;
    try demo.Owner.bootstrapInto(harness.owner, harness.backend.interface(), undefined, harness.stream);
    const opening = [_]canonical.AssetAmount{.{ .asset = third_asset, .atoms = 10 }};
    for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged)) |original| {
        var input = original;
        if (native_fees) switch (input.core.payload) {
            .opening_balance => |*balance| {
                for (harness.owner.shard.instrument_registry.entries[0..harness.owner.shard.instrument_registry.count]) |configured| {
                    var margin = configured.margin;
                    margin.instrument = configured.instrument;
                    margin.version += 1;
                    margin.native_settlement_atoms = true;
                    _ = try harness.owner.apply(fixture.atGroup(6, .{ .identity = std.math.cast(u64, configured.instrument) orelse return error.IdentityOutOfRange, .payload = .{ .margin_rules_activated = margin } }));
                }
                var definition = @import("../../../trading/asset_registry.zig").testDefinitions(6, 8)[0];
                definition.asset = third_asset;
                definition.source_identity += third_asset;
                definition.code_bindings = @splat(.{});
                definition.code_binding_count = 1;
                definition.code_bindings[0] = try canonical.AssetCodeBinding.init(1, "BNB");
                _ = try harness.owner.apply(fixture.atGroup(6, .{ .identity = third_asset, .payload = .{ .asset_definition_activated = definition } }));
                try acceptance.bootstrapArchiveAccountFor(harness.owner, &opening, 3);
                balance.native_balances[0] = opening[0];
                balance.native_balance_count = 1;
            },
            else => {},
        };
        _ = try harness.owner.apply(input);
    }
    _ = try harness.owner.apply(fixture.atGroup(12, .{ .identity = 3, .payload = .{ .host_activated = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .session = .{ .fencing = 1, .shard = 0, .generation = 1 }, .activation_barrier = 0, .state_digest = harness.owner.shard.canonicalStateDigest() } } }));
    _ = try harness.owner.apply(fixture.atGroup(13, .{ .identity = 4, .payload = .{ .capability_profile_activation = .{ .exchange_account = 2, .instrument = 3, .venue = 1, .environment = .simulation, .product = .isolated_linear_usdt, .version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .max_dispatch_age_ns = 10 * std.time.ns_per_s, .supports_place = true, .supports_cancel = true, .supports_native_amend = false, .supports_venue_reduce_only = false, .supports_post_only = false, .supports_market_protection = false } } }));
    if (!native_fees) try acceptance.bootstrapArchiveAccountFor(harness.owner, &.{}, 3);
    var book = fixture.snapshotAt(15, 2);
    book.venue.envelope.identity.stream = 7;
    book.venue.envelope.source_stream = 7;
    book.venue.envelope.raw_evidence.stream = 7;
    _ = try harness.owner.apply(book);
    try harness.owner.sealBootstrap();
    if (simulator) |adapter| try harness.bindAdapter(adapter.adapter());
    const command = (try harness.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .timer = .{ .side = .buy, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 20, .limit_price_micros = 50_000_000 } } }))) orelse return error.ExpectedOrder;
    harness.command = harness.owner.shard.oms.command_history[0];
    if (simulator) |adapter| {
        try harness.gateway.observeAuthorityFromShard(&harness.owner.shard, .{
            .account = 2,
            .effective_trading_authority = harness.owner.shard.operational_state.effectiveTradingAuthority(),
            .reservation_identity = harness.command.reservation_identity,
            .reservation = harness.command.reservation,
            .primary_lease_expires_at_monotonic_ns = harness.lease.expires_at_ns,
            .fencing_token = harness.lease.token,
            .exchange_position = harness.owner.shard.currentNetExchangePosition(3).?,
            .authority_barrier = harness.owner.shard.authoritativeBarrier(),
        });
        try std.testing.expectEqual(@import("../../../execution/venue_adapter.zig").SendResult.accepted, try harness.gateway.sendFromShard(&harness.owner.shard, harness.command.command_id, 2 * std.time.ns_per_s));
        try harness.owner.applyAdapterBatch((try adapter.adapter().tryDrain()).?);
        var fill = fixture.canonicalAt(21, 3, .{ .fill = .{
            .identity = 8001,
            .order = command.order_id,
            .client_order_id = harness.gateway.acceptedClientOrderIdFromShard(&harness.owner.shard, harness.command.command_id).?,
            .venue_order = try @import("../../../model/canonical_event.zig").VenueOrderRef.init(1, "funding-held-order"),
            .venue_trade = try @import("../../../model/canonical_event.zig").VenueTradeRef.init(1, "funding-held-fill"),
            .instrument = 3,
            .exchange_account = 2,
            .side = .buy,
            .quantity = .{ .instrument = 3, .rules_version = 1, .lots = 2 },
            .price = fixture.omsPrice(3, 50_000_000),
            .fee = .{ .asset = 1, .atoms = 0 },
            .liquidity = .taker,
        } });
        if (native_fees) {
            fill.venue.event.fill.fee = .{ .asset = third_asset, .atoms = 3 };
            fill.venue.event.fill.rebate = .{ .asset = third_asset, .atoms = 1 };
        }
        fill.venue.event.fill.venue_fill_time_utc_ns = fill.venue.envelope.times.source_utc_ns;
        fill.venue.envelope.instrument = 3;
        _ = try harness.owner.apply(fill);
    } else {
        _ = try harness.owner.apply(fixture.atGroup(21, .{ .identity = 8001, .payload = .{ .economic_fill = .{ .fill_id = 8001, .order_id = command.order_id, .quantity = 2, .price_ticks = 50_000_000 } } }));
    }
    return harness;
}

fn funding(identity: u64, amount: i128) trading.CanonicalEvent {
    return fixture.atGroup(25, .{ .identity = identity, .payload = .{ .funding_settlement = .{ .settlement_id = identity, .amount_atoms = amount } } });
}

test "07 Owner funding archive authenticates complete ledger and zero amount identity through recovery" {
    for ([_]i128{ -37, 0 }) |amount| {
        const harness = try createFundingHarness(if (amount == 0) 1810 else 1800);
        defer harness.destroy();
        _ = try harness.owner.apply(funding(9001, amount));
        const before = harness.owner.shard.economicSummary();
        const summary = harness.owner.shard.economic_projection.ledger_summary;
        const root = try harness.owner.archiveFundingHistory(9001, harness.gateway);
        try expectEconomics(before, harness.owner.shard.economicSummary());
        try std.testing.expectEqualDeep(summary, harness.owner.shard.economic_projection.ledger_summary);
        try std.testing.expectEqual(@as(u8, 0), harness.owner.shard.economic_projection.applied_funding_count);
        const result = try harness.backend.interface().queryOrderHistory(undefined, .{ .pending_id = 1, .key = .{ .origin = root.origin, .identity = .{ .funding_detail = 9001 } }, .candidate_payload_digest = @splat(0), .original_input_digest = root.qualification_digest, .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier });
        try history.validateRecord(&result);
        const qualification = try codec.decodeBare(result.record_bytes[0..result.record_len], economics.FundingArchiveQualification);
        try std.testing.expectEqual(amount, qualification.record.applied.funding.amount.atoms);
        try std.testing.expectEqual(@as(u8, if (amount == 0) 0 else 2), qualification.record.ledger_count);
        for (qualification.record.ledger[0..qualification.record.ledger_count]) |transaction| {
            var total: i128 = 0;
            for (transaction.postings[0..transaction.posting_count]) |posting| total += posting.amount;
            try std.testing.expectEqual(@as(i128, 0), total);
        }
        _ = try harness.owner.apply(funding(9001, amount));
        try expectEconomics(before, harness.owner.shard.economicSummary());
        try harness.owner.checkpoint();
        const recovered = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(recovered);
        try demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream);
        try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u64, 0), harness.gateway.send_attempt_count);
    }
}

test "07 Owner funding archive faults preserve old or committed economic state and never dispatch" {
    for ([_]@TypeOf(@as(acceptance.ArchiveFaultMemory, undefined).stage){ .history_publish, .decision_commit, .gateway_append, .gateway_checkpoint }, 0..) |stage, index| {
        const harness = try createFundingHarness(1820 + 2 * index);
        defer harness.destroy();
        _ = try harness.owner.apply(funding(9001, -37));
        try harness.owner.checkpoint();
        const before = harness.owner.shard.economicSummary();
        const committed = stage == .gateway_append or stage == .gateway_checkpoint;
        harness.backend.stage = stage;
        try std.testing.expectError(if (stage == .decision_commit) error.DecisionLogUnavailable else error.InjectedEio, harness.owner.archiveFundingHistory(9001, harness.gateway));
        try std.testing.expect(harness.owner.closed);
        const recovered = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(recovered);
        const store = harness.backend.memory.interface();
        try demo.Owner.recoverInto(recovered, store, undefined, harness.stream);
        try expectEconomics(before, recovered.shard.economicSummary());
        try std.testing.expectEqual(@as(u8, if (committed) 0 else 1), recovered.shard.economic_projection.applied_funding_count);
        const gateway = try std.testing.allocator.create(execution.Gateway);
        defer std.testing.allocator.destroy(gateway);
        gateway.init();
        try gateway.attachRecoveredDurableDispatch(store, undefined, harness.dispatch_stream);
        if (committed) {
            try recovered.resumeFundingArchive(gateway);
            const durable_before = try store.recover(undefined, harness.dispatch_stream);
            try recovered.resumeFundingArchive(gateway);
            const durable_after = try store.recover(undefined, harness.dispatch_stream);
            try std.testing.expectEqual(durable_before.last_sequence, durable_after.last_sequence);
        }
        try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
    }
}

fn expectEconomics(expected: trading.EconomicSummary, actual: trading.EconomicSummary) !void {
    var comparison = actual;
    comparison.ledger_transactions = expected.ledger_transactions;
    try std.testing.expectEqualDeep(expected, comparison);
}

test "07 Owner funding hot and cold conflicts preserve economics and latch authority" {
    for ([_]bool{ false, true }, 0..) |cold, index| {
        const harness = try createFundingHarness(2100 + index * 2);
        defer harness.destroy();
        _ = try harness.owner.apply(funding(9001, -7));
        if (cold) _ = try harness.owner.archiveFundingHistory(9001, harness.gateway);
        const before = harness.owner.shard.economicSummary();
        if (cold) {
            _ = try harness.owner.apply(funding(9001, -8));
            try std.testing.expect(harness.owner.shard.history_conflict_latched);
        } else try std.testing.expectError(error.ConflictingEconomicIdentity, harness.owner.apply(funding(9001, -8)));
        try std.testing.expect(harness.owner.shard.oms.recovery_only);
        try std.testing.expectEqualDeep(before.portfolio, harness.owner.shard.economicSummary().portfolio);
        try std.testing.expectEqualDeep(before.exchange, harness.owner.shard.economicSummary().exchange);
        if (!cold) try std.testing.expectError(error.FundingArchivePinned, harness.owner.archiveFundingHistory(9001, harness.gateway));
        try std.testing.expectEqual(@as(u64, 0), harness.gateway.send_attempt_count);
    }
}

test "07 Owner pins missing funding source time and unknown canonical settlement ownership" {
    const allocator = std.testing.allocator;
    for (0..2) |mode| {
        const harness = try createFundingHarness(2110 + mode * 2);
        defer harness.destroy();
        if (mode == 0) {
            var input = funding(9001, -7);
            input.core.time_presence.source = false;
            _ = try harness.owner.apply(input);
            const applied = harness.owner.shard.economic_projection.applied_fundings[0];
            try std.testing.expect(applied.source.exchange_time_utc_ns == null);
            try std.testing.expectEqual(input.core.source_time, applied.source.core_times.?.source);
            const facts = [_]canonical.EconomicFactRef{
                .{ .identity = 8001, .kind = .fill, .digest = harness.owner.shard.economic_projection.canonical_fill_evidence[0].digest, .fee_confirmed = true },
                .{ .identity = 9001, .kind = .funding, .digest = applied.payload_digest, .fee_confirmed = true },
            };
            _ = try harness.owner.apply(@import("reconciliation_archive_acceptance.zig").windowInput(harness, 0, &facts));
            try std.testing.expectError(error.ReconciliationWindowPinned, harness.owner.archiveReconciliationWindowHistory(10000, harness.gateway));
        } else {
            var input = fixture.canonicalAt(26, 1, .{ .funding_settlement = .{ .identity = 9001, .exchange_account = 2, .instrument = 3, .rules_version = 1, .venue_bill_id = 77, .amount = .{ .asset = 1, .atoms = -7 }, .settlement_time_utc_ns = funding(9001, -7).core.source_time } });
            input.venue.envelope.identity.stream = 8;
            input.venue.envelope.source_stream = 8;
            input.venue.envelope.raw_evidence.stream = 8;
            input.venue.envelope.instrument = 3;
            input.venue.envelope.asset = 1;
            _ = try harness.owner.apply(input);
            try std.testing.expectEqual(@as(i128, -7), harness.owner.shard.economic_projection.suspense_usdt_atoms);
            try std.testing.expectEqual(@as(i128, 0), harness.owner.shard.economic_projection.portfolio.funding_atoms);
            try std.testing.expectEqual(@as(u128, 0), harness.owner.shard.economic_projection.applied_fundings[0].source.portfolio);
        }
        try std.testing.expectError(error.FundingArchivePinned, harness.owner.archiveFundingHistory(9001, harness.gateway));
        try harness.owner.checkpoint();
        const recovered = try allocator.create(demo.Owner);
        defer allocator.destroy(recovered);
        try demo.Owner.recoverInto(recovered, harness.backend.interface(), undefined, harness.stream);
        try std.testing.expectEqualSlices(u8, &harness.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u8, 1), recovered.shard.economic_projection.applied_funding_count);
        try std.testing.expect(recovered.shard.reconciliation_cursor == null);
    }
}
