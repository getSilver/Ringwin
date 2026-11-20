//! Offline scanner request -> durable TradingShard authority -> recovery.
const std = @import("std");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const trading = @import("../../../trading/trading_shard.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const existing = @import("multi_account_authority_acceptance.zig");
const approval = @import("../../../trading/pair_trading_authorization.zig");
const raw_ingress = @import("../../../persistence/raw_ingress.zig");
const market = @import("../../../adapters/okx/okx_public_market.zig");
const history = @import("../../../persistence/business_history.zig");

pub fn configurePairAssets(owner: *demo.Owner) !void {
    return configurePairAssetsForScenario(owner, true);
}

fn configurePairAssetsForScenario(owner: *demo.Owner, expanded_economics: bool) !void {
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| {
        const entry = owner.shard.pairInstrument(account, instrument).?;
        var rules = entry.rules;
        rules.version += 1;
        rules.base_asset = 0x425443;
        if (expanded_economics) rules.quantity_denominator = 1;
        _ = try owner.apply(fixture.atGroup(44, .{ .identity = owner.shard.authoritativeBarrier() + 1, .account_scope = account, .payload = .{ .instrument_rules_activated = rules } }));
        var margin = entry.margin;
        margin.version += 1;
        if (expanded_economics) margin.price_tick_atoms = 100_000;
        _ = try owner.apply(fixture.atGroup(44, .{ .identity = owner.shard.authoritativeBarrier() + 1, .account_scope = account, .payload = .{ .margin_rules_activated = margin } }));
        var capability = entry.capability.?;
        capability.version += 1;
        capability.rules_version = rules.version;
        if (!expanded_economics) capability.supports_native_amend = true;
        _ = try owner.apply(fixture.atGroup(44, .{ .identity = owner.shard.authoritativeBarrier() + 1, .account_scope = account, .payload = .{ .capability_profile_activation = capability } }));
    }
}

test "scanner pair approval validates identities and survives durable recovery" {
    try exercisePairApproval(false);
}

test "scanner mixed USDT USDC pair approval preserves native accounts through recovery" {
    try exercisePairApproval(true);
}

fn exercisePairApproval(mixed: bool) !void {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    if (mixed) try existing.initializeMixedStablecoinOwner(owner) else try existing.initializePythonOwner(owner);
    // The legacy fixture leaves linear exposure assets unspecified. Register
    // their real canonical base before approving an economic pairing.
    try configurePairAssets(owner);
    var request: approval.Request = .{ .identity = 98765, .strategy = 9, .portfolio = 10, .activation = 1, .config_version = 1, .expected_version = 0, .legs = .{
        .{ .venue = 1, .environment = .simulation, .account = 20, .instrument = 101, .rules_version = 2 },
        .{ .venue = 21, .environment = .simulation, .account = 30, .instrument = 102, .rules_version = 2 },
    }, .direction = 1, .mode = .taker_taker, .enabled = true };
    const before = owner.shard.canonicalStateDigest();
    for (0..5) |scenario| {
        var bad = request;
        switch (scenario) {
            0 => bad.legs[1].account = 999,
            1 => bad.legs[1].rules_version = 1,
            2 => bad.portfolio = 999,
            3 => bad.config_version = 999,
            4 => bad.legs[1].environment = .demo,
            else => unreachable,
        }
        if (owner.shard.apply(fixture.atGroup(45, .{ .identity = 98765, .payload = .{ .pair_trading_authorization = bad } }))) |_| {
            return error.ExpectedPairRejection;
        } else |_| {}
        try std.testing.expectEqualSlices(u8, &before, &owner.shard.canonicalStateDigest());
    }
    const event = fixture.atGroup(45, .{ .identity = 98765, .payload = .{ .pair_trading_authorization = request } });
    _ = try owner.apply(event);
    try std.testing.expectEqual(@as(u64, 1), owner.shard.pair_authorizations.version);
    const accepted = owner.shard.canonicalStateDigest();
    _ = try owner.apply(event);
    try std.testing.expectEqualSlices(u8, &accepted, &owner.shard.canonicalStateDigest());
    request.identity += 1;
    request.expected_version = 1;
    request.enabled = false;
    const orders = owner.shard.oms.order_count;
    _ = try owner.apply(fixture.atGroup(46, .{ .identity = 98766, .payload = .{ .pair_trading_authorization = request } }));
    try std.testing.expectEqual(orders, owner.shard.oms.order_count);
    try owner.checkpoint();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqual(@as(u64, 2), recovered.shard.pair_authorizations.version);
    try std.testing.expectEqual(@as(u64, 1), recovered.shard.accountState(20).?.economic_projection.settlement_asset);
    try std.testing.expectEqual(@as(u64, if (mixed) 3 else 1), recovered.shard.accountState(30).?.economic_projection.settlement_asset);
    try std.testing.expectEqual(@as(i128, 600), recovered.shard.accountState(30).?.economic_projection.portfolio.settlement_balance_atoms);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
}

test "scanner revoked pair rejects risk increasing amend but preserves reductions and cancel" {
    try exercisePairMutation(.ordinary);
}

test "scanner revoked pair compares amendments to partially filled remaining quantity" {
    try exercisePairMutation(.partial);
}

test "scanner rechecks pair approval after cancel confirmation before replacement" {
    try exercisePairMutation(.replacement);
}

test "scanner revoked pair preserves reducing cancel confirm create amendment" {
    try exercisePairMutation(.replacement_reduction);
}

test "strategy FX projects committed mixed settlement cash after durable recovery" {
    try exercisePairMutation(.stablecoin_fx);
}

fn exercisePairMutation(comptime scenario: enum { ordinary, partial, replacement, replacement_reduction, stablecoin_fx }) !void {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    if (scenario == .stablecoin_fx) try existing.initializeMixedStablecoinOwner(owner) else try existing.initializePythonOwner(owner);
    try configurePairAssetsForScenario(owner, false);
    var request: approval.Request = .{ .identity = 98765, .strategy = 9, .portfolio = 10, .activation = 1, .config_version = 1, .expected_version = 0, .legs = .{
        .{ .venue = 1, .environment = .simulation, .account = 20, .instrument = 101, .rules_version = 2 },
        .{ .venue = 21, .environment = .simulation, .account = 30, .instrument = 102, .rules_version = 2 },
    }, .direction = 1, .mode = .taker_taker, .enabled = true };
    for ([_]u128{ 101, 102 }, [_]u64{ 1, 21 }) |instrument, venue| {
        var book = fixture.canonicalAt(45, 2, .{ .l2_book_snapshot = .{ .instrument = instrument, .sequence = 2, .best_bid = .{ .instrument = instrument, .rules_version = 2, .ticks = 99 }, .best_ask = .{ .instrument = instrument, .rules_version = 2, .ticks = 100 }, .best_bid_quantity = .{ .instrument = instrument, .rules_version = 2, .lots = 100000 }, .best_ask_quantity = .{ .instrument = instrument, .rules_version = 2, .lots = 100000 } } });
        book.venue.envelope.scope = .instrument;
        book.venue.envelope.exchange_account = null;
        book.venue.envelope.instrument = instrument;
        book.venue.envelope.venue = venue;
        book.venue.envelope.identity.stream = 1000 + instrument;
        book.venue.envelope.source_stream = @intCast(1000 + instrument);
        _ = try owner.apply(book);
        _ = try owner.apply(fixture.atGroup(45, .{ .identity = @intCast(15000 + instrument), .account_scope = if (instrument == 101) 20 else 30, .payload = .{ .mark_price = .{ .instrument = instrument, .price_atoms = 100 } } }));
    }
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 11000, .count = 2 };
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, 0..) |account, instrument, index| group.members[index] = .{ .exchange_account = account, .portfolio = 10, .intent_sequence = 11000 + index, .strategy_instance = 9, .operation = .place, .instrument = instrument, .side = if (index == 0) .buy else .sell, .quantity = 10000, .limit_price = .{ .instrument = instrument, .rules_version = 2, .ticks = 100 }, .time_in_force = .immediate_or_cancel };
    if (scenario == .ordinary) {
        try std.testing.expect(owner.shard.pairTradingListEmpty(9));
        _ = try owner.apply(fixture.atGroup(45, .{ .identity = 98764, .payload = .{ .pair_trading_scope_bound = 9 } }));
        try expectOpeningRejected(owner, group, 10000, 45);
    }
    _ = try owner.apply(fixture.atGroup(45, .{ .identity = 98765, .payload = .{ .pair_trading_authorization = request } }));
    try std.testing.expect(!owner.shard.pairTradingListEmpty(9));
    _ = try owner.apply(fixture.atGroup(46, .{ .identity = 11000, .payload = .{ .oms_intent_group = group } }));
    if (owner.shard.oms.order_count != 2) std.debug.print("scanner opening rejected: {s}\n", .{@tagName(owner.shard.last_reject_reason)});
    try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
    if (scenario == .stablecoin_fx) return exerciseCommittedFx(owner, memory.interface());
    for ([_]u128{ 20, 30 }, 0..) |account, index| _ = try owner.apply(fixture.atGroup(47, .{ .identity = 12000 + index, .account_scope = account, .payload = .{ .oms_execution_report = .{ .report_id = 12000 + index, .order_id = index + 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10000 } } }));
    if (scenario == .partial) _ = try owner.apply(fixture.atGroup(47, .{ .identity = 12500, .account_scope = 20, .payload = .{ .oms_execution_report = .{ .report_id = 12500, .order_id = 1, .revision = 1, .status = .partially_filled, .cumulative_quantity = 9000, .remaining_quantity = 1000 } } }));
    var amendment: trading.oms.IntentGroup = .{ .first_intent_sequence = 13000, .count = 1 };
    amendment.members[0] = group.members[0];
    amendment.members[0].operation = .amend;
    amendment.members[0].target_order_id = 1;
    amendment.members[0].expected_revision = 1;
    amendment.members[0].intent_sequence = 13000;
    amendment.members[0].quantity = if (scenario == .partial) 2000 else if (scenario == .replacement_reduction) 9000 else 10001;
    amendment.members[0].expected_cumulative_quantity = if (scenario == .partial) 9000 else 0;
    if (scenario == .replacement or scenario == .replacement_reduction) {
        amendment.members[0].native_amend = false;
        amendment.members[0].allow_cancel_confirm_create = true;
        _ = try owner.apply(fixture.atGroup(48, .{ .identity = 13000, .payload = .{ .oms_intent_group = amendment } }));
        try std.testing.expectEqual(trading.oms.OrderState.pending_cancel, owner.shard.oms.orderById(1).?.state);
    }
    request.identity += 1;
    request.expected_version = 1;
    request.enabled = false;
    _ = try owner.apply(fixture.atGroup(48, .{ .identity = 98766, .payload = .{ .pair_trading_authorization = request } }));
    if (scenario == .ordinary) {
        try std.testing.expect(owner.shard.pairTradingListEmpty(9));
        try expectOpeningRejected(owner, group, 12600, 48);
    }
    if (scenario == .replacement or scenario == .replacement_reduction) {
        _ = try owner.apply(fixture.atGroup(49, .{ .identity = 14000, .account_scope = 20, .payload = .{ .oms_execution_report = .{ .report_id = 14000, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 10000 } } }));
        try std.testing.expectEqual(@as(u16, if (scenario == .replacement_reduction) 3 else 2), owner.shard.oms.order_count);
        try std.testing.expect(owner.shard.oms.orderById(1).?.replacement == null);
        if (scenario == .replacement_reduction) try std.testing.expectEqual(@as(i64, 9000), owner.shard.oms.orderById(3).?.quantity);
        return;
    }
    if (scenario == .ordinary) {
        var spoof = amendment;
        spoof.first_intent_sequence = 12900;
        spoof.members[0].intent_sequence = 12900;
        spoof.members[0].side = .sell;
        _ = try owner.apply(fixture.atGroup(49, .{ .identity = 12900, .payload = .{ .oms_intent_group = spoof } }));
        try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.unsupported_order_spec, owner.shard.last_reject_reason);
        spoof.first_intent_sequence += 1;
        spoof.members[0].intent_sequence += 1;
        spoof.members[0].side = .buy;
        spoof.members[0].portfolio_reduce_only = true;
        _ = try owner.apply(fixture.atGroup(49, .{ .identity = 12901, .payload = .{ .oms_intent_group = spoof } }));
        try std.testing.expect(owner.shard.last_reject_reason != .none);
        try std.testing.expectEqual(@as(u32, 1), owner.shard.oms.orderById(1).?.revision);
    }
    _ = try owner.apply(fixture.atGroup(49, .{ .identity = 13000, .payload = .{ .oms_intent_group = amendment } }));
    try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.authorization_closed, owner.shard.last_reject_reason);
    try std.testing.expectEqual(@as(i64, 10000), owner.shard.oms.orderById(1).?.quantity);
    if (scenario == .partial) return;
    amendment.first_intent_sequence = 13001;
    amendment.members[0].intent_sequence = 13001;
    amendment.members[0].quantity = 9000;
    _ = try owner.apply(fixture.atGroup(50, .{ .identity = 13001, .payload = .{ .oms_intent_group = amendment } }));
    try std.testing.expectEqual(@as(i64, 9000), owner.shard.oms.orderById(1).?.quantity);
    _ = try owner.apply(fixture.atGroup(51, .{ .identity = 13050, .account_scope = 20, .payload = .{ .oms_execution_report = .{ .report_id = 13050, .order_id = 1, .revision = 2, .status = .amended, .cumulative_quantity = 0, .remaining_quantity = 9000 } } }));
    var cancel = amendment;
    cancel.first_intent_sequence = 13002;
    cancel.members[0].intent_sequence = 13002;
    cancel.members[0].operation = .cancel;
    cancel.members[0].expected_revision = owner.shard.oms.orderById(1).?.revision;
    _ = try owner.apply(fixture.atGroup(52, .{ .identity = 13002, .payload = .{ .oms_intent_group = cancel } }));
    try std.testing.expectEqual(trading.oms.OrderState.pending_cancel, owner.shard.oms.orderById(1).?.state);

    const order = owner.shard.oms.orderById(1).?;
    var fill = fixture.canonicalAt(53, 3, .{ .fill = .{
        .identity = 10,
        .order = order.id,
        .client_order_id = order.client_order_id,
        .venue_order = try trading.canonical.VenueOrderRef.init(1, "pair-order"),
        .venue_trade = try trading.canonical.VenueTradeRef.init(1, "pair-fill"),
        .instrument = 101,
        .exchange_account = 20,
        .side = .buy,
        .quantity = .{ .instrument = 101, .rules_version = 2, .lots = 5000 },
        .price = group.members[0].limit_price,
        .fee = .{ .asset = 1, .atoms = 0 },
        .venue_fill_time_utc_ns = fixture.atGroup(53, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
        .liquidity = .taker,
    } });
    fill.venue.envelope.exchange_account = 20;
    _ = try owner.apply(fill);
    try std.testing.expectEqual(@as(i64, 5000), owner.shard.accountState(20).?.economic_projection.portfolio.positionForInstrument(101).quantity);
    _ = try owner.apply(fixture.atGroup(53, .{ .identity = 13060, .account_scope = 20, .payload = .{ .oms_execution_report = .{
        .report_id = 13060,
        .order_id = 1,
        .revision = order.revision,
        .status = .canceled,
        .cumulative_quantity = 5000,
        .remaining_quantity = 4000,
    } } }));
    var reduction: trading.oms.IntentGroup = .{ .first_intent_sequence = 13003, .count = 1 };
    reduction.members[0] = group.members[0];
    reduction.members[0].intent_sequence = 13003;
    reduction.members[0].side = .sell;
    reduction.members[0].quantity = 5000;
    reduction.members[0].portfolio_reduce_only = true;
    _ = try owner.apply(fixture.atGroup(54, .{ .identity = 13003, .payload = .{ .oms_intent_group = reduction } }));
    if (owner.shard.oms.order_count != 3) std.debug.print("pair reduction rejected: {s}\n", .{@tagName(owner.shard.last_reject_reason)});
    try std.testing.expectEqual(@as(u16, 3), owner.shard.oms.order_count);
    try std.testing.expect(owner.shard.oms.orderById(3).?.portfolio_reduce_only);

    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try recovered.pinDeploymentDigest(owner.deployment_anchor.?);
    try std.testing.expect(recovered.shard.pairTradingScopeBound(9));
    try std.testing.expect(recovered.shard.pairTradingListEmpty(9));
    const stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 92 };
    const acknowledgement = "offline transport acknowledgement";
    var sink = try raw_ingress.DurableSink.init(memory.interface(), undefined, stream);
    _ = try sink.interface().append(.{ .source_session = 1, .byte_len = acknowledgement.len, .sha256 = history.hash(acknowledgement), .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1 }, acknowledgement);
    const Sweep = struct {
        fn consume(_: *anyopaque, _: u64, _: market.RawIngressRecord, bytes: []const u8) !void {
            try std.testing.expectEqualStrings(acknowledgement, bytes);
        }
    };
    try recovered.bindRecoveryIngress(memory.interface(), stream);
    try recovered.replayCommittedIngress(stream, .{ .ptr = recovered, .consume_fn = Sweep.consume });
    try recovered.checkpoint();
    try expectOpeningRejected(recovered, group, 14000, 55);
}

fn exerciseCommittedFx(owner: *demo.Owner, store: durable.Store) !void {
    const fx = @import("../../../runtime/strategy_fx_projection.zig");
    const allocator = std.testing.allocator;
    const order = owner.shard.oms.orderById(2).?;
    const at = fixture.atGroup(47, .{ .identity = 0, .payload = .recovery_completed }).core.source_time;
    var fill = fixture.canonicalAt(47, 2, .{ .fill = .{
        .identity = 71,
        .order = order.id,
        .client_order_id = order.client_order_id,
        .venue_order = try trading.canonical.VenueOrderRef.init(21, "fx-order"),
        .venue_trade = try trading.canonical.VenueTradeRef.init(21, "fx-fill"),
        .instrument = 102,
        .exchange_account = 30,
        .side = .sell,
        .quantity = .{ .instrument = 102, .rules_version = 2, .lots = 10000 },
        .price = order.limit_price,
        .fee = .{ .asset = 3, .atoms = 10 },
        .liquidity = .taker,
        .venue_fill_time_utc_ns = at,
    } });
    fill.venue.envelope.exchange_account = 30;
    fill.venue.envelope.venue = 21;
    _ = try owner.apply(fill);
    _ = try owner.apply(fill);
    const funding_at = at + 10 * std.time.ns_per_ms;
    var funding = fixture.canonicalAt(48, 3, .{ .funding_settlement = .{
        .identity = 72,
        .exchange_account = 30,
        .instrument = 102,
        .rules_version = 2,
        .venue_bill_id = 72,
        .amount = .{ .asset = 3, .atoms = 1_000_000_010 },
        .settlement_time_utc_ns = funding_at,
    } });
    funding.venue.envelope.exchange_account = 30;
    funding.venue.envelope.venue = 21;
    funding.venue.envelope.instrument = 102;
    funding.venue.envelope.asset = 3;
    _ = try owner.apply(funding);
    var before = try fx.project(allocator, try owner.source(), &owner.decision_journal, 9, 11000);
    defer before.deinit(allocator);
    try std.testing.expect(before.complete);
    try std.testing.expectEqual(@as(usize, 2), before.flows.items.len);
    try std.testing.expectEqual(@as(i128, -10), before.flows.items[0].atoms);
    try std.testing.expectEqual(@as(i128, 1_000_000_010), before.flows.items[1].atoms);
    try owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, store, undefined, owner.stream);
    var after = try fx.project(allocator, try recovered.source(), &recovered.decision_journal, 9, 11000);
    defer after.deinit(allocator);
    try std.testing.expectEqual(before.complete, after.complete);
    try std.testing.expectEqualDeep(before.flows.items, after.flows.items);
    const reject_write = struct {
        fn commit(_: *anyopaque, _: trading.CorePayload) !void {
            return error.UnexpectedFxWrite;
        }
    }.commit;
    var authority: @import("../../../strategy/strategy_package_authority.zig").Authority = .{
        .shard = &recovered.shard,
        .journal = &recovered.decision_journal,
        .context = recovered,
        .commit = reject_write,
        .strategy = 9,
        .config_version = 1,
        .schema_registry = 1,
        .decision_domain = recovered.shard.operational_state.target_identity,
        .fencing = recovered.shard.fencing_token,
        .shard_id = 1,
        .max_outputs = 2,
    };
    const wire = try authority.request(allocator, "{\"operation\":\"cycle_fx_projection\",\"strategy_identity\":\"00000000000000000000000000000009\",\"cycle_first_sequence\":11000}", &@splat(0), std.testing.io);
    defer allocator.free(wire);
    const expected = try after.json(allocator);
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, wire);
    std.debug.print("\nstrategy_fx_projection={s}\n", .{wire});
}

fn expectOpeningRejected(owner: *demo.Owner, original: trading.oms.IntentGroup, sequence: u64, now: u64) !void {
    var group = original;
    group.first_intent_sequence = sequence;
    for (group.members[0..group.count], 0..) |*member, index| member.intent_sequence = sequence + index;
    const orders = owner.shard.oms.order_count;
    _ = try owner.apply(fixture.atGroup(now, .{ .identity = sequence, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.authorization_closed, owner.shard.last_reject_reason);
    try std.testing.expectEqual(orders, owner.shard.oms.order_count);
}
