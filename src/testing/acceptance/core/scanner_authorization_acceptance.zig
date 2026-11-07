//! Offline scanner request -> durable TradingShard authority -> recovery.
const std = @import("std");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const trading = @import("../../../trading/trading_shard.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const existing = @import("multi_account_authority_acceptance.zig");
const approval = @import("../../../trading/pair_trading_authorization.zig");

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
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try existing.initializePythonOwner(owner);
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

fn exercisePairMutation(comptime scenario: enum { ordinary, partial, replacement, replacement_reduction }) !void {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try existing.initializePythonOwner(owner);
    try configurePairAssetsForScenario(owner, false);
    var request: approval.Request = .{ .identity = 98765, .strategy = 9, .portfolio = 10, .activation = 1, .config_version = 1, .expected_version = 0, .legs = .{
        .{ .venue = 1, .environment = .simulation, .account = 20, .instrument = 101, .rules_version = 2 },
        .{ .venue = 21, .environment = .simulation, .account = 30, .instrument = 102, .rules_version = 2 },
    }, .direction = 1, .mode = .taker_taker, .enabled = true };
    _ = try owner.apply(fixture.atGroup(45, .{ .identity = 98765, .payload = .{ .pair_trading_authorization = request } }));
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
    _ = try owner.apply(fixture.atGroup(46, .{ .identity = 11000, .payload = .{ .oms_intent_group = group } }));
    if (owner.shard.oms.order_count != 2) std.debug.print("scanner opening rejected: {s}\n", .{@tagName(owner.shard.last_reject_reason)});
    try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
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
}
