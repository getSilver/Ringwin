const std = @import("std");
const engine = @import("trading_shard.zig");
const shard_event = @import("trading_shard_event.zig");
const fixture = @import("trading_shard_fixture.zig");
const canonical = engine.canonical;
const execution_gateway = @import("execution_gateway.zig");
const oms_module = engine.oms;
const operational = engine.operational;
const simulated_venue = @import("simulated_venue.zig");
const host_gateway = @import("strategy_host_gateway.zig");
const host_lifecycle = @import("strategy_host_lifecycle.zig");
const production_contract = @import("production_contract.zig");

const TradingShard = engine.TradingShard;
const ReplayTradingShard = engine.ReplayTradingShard;
const CanonicalEvent = engine.CanonicalEvent;
const LiveRun = fixture.LiveRun;
const contract_denominator = fixture.contract_denominator;
const happy_order_quantity = fixture.happy_order_quantity;
const order_limit_price = fixture.order_limit_price;
const settlement_asset = fixture.settlement_asset;
const spot_instrument = fixture.spot_instrument;
const swap_instrument = fixture.swap_instrument;
const margin_kill_gate_identity = fixture.margin_kill_gate_identity;
const primary_lease_gate_identity = fixture.primary_lease_gate_identity;
const risk_lease_gate_identity = fixture.risk_lease_gate_identity;
const genesis = fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged);
const fixtureOmsPrice = fixture.omsPrice;
const fixtureReservation = fixture.reservation;
const lifecycleCommand = fixture.lifecycleCommand;
const deRiskCommand = fixture.deRiskCommand;
const resolveLatchCommand = fixture.resolveLatchCommand;
const startScenario = fixture.startScenario;
const startScenarioAuthorized = fixture.startScenarioAuthorized;
const applyLive = engine.applyStable;
const happyPathVenueFacts = fixture.happyVenueFacts;
const snapshotAt = fixture.snapshotAt;
const deltaAt = fixture.deltaAt;
const assertReplayEquivalent = fixture.assertReplayEquivalent;
const assertReplayEquivalentConfigured = fixture.assertReplayEquivalentConfigured;
const applyHealthyPrelude = fixture.applyHealthyPrelude;
const atGroup = fixture.atGroup;

test "Owner rejects tighter native bounds without losing committed registry or recoverable holdings" {
    const demo = @import("demo_authority.zig");
    const durable = @import("durable_store.zig");
    const assets = @import("asset_registry.zig");
    for ([_]bool{ false, true }) |third_asset| {
        const memory = try std.testing.allocator.create(durable.MemoryAdapter);
        defer std.testing.allocator.destroy(memory);
        memory.* = .init();
        const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 990 };
        var owner = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
        if (third_asset) {
            for (assets.testDefinitions(6, 8)) |definition|
                _ = try owner.apply(.{ .core = .{ .identity = definition.asset, .payload = .{ .asset_definition_activated = definition } } });
            var native = assets.testDefinitions(6, 8)[1];
            native.asset = 99;
            native.code_bindings = @splat(.{});
            native.code_binding_count = 1;
            native.code_bindings[0] = try canonical.AssetCodeBinding.init(1, "BNB");
            _ = try owner.apply(.{ .core = .{ .identity = 99, .payload = .{ .asset_definition_activated = native } } });
        }
        for (genesis) |original| {
            var event = original;
            if (third_asset and event.core.payload == .margin_rules_activated)
                event.core.payload.margin_rules_activated.native_settlement_atoms = true;
            if (third_asset and event.core.payload == .opening_balance) {
                var observed: canonical.AccountBootstrapSnapshot = .{ .identity = 90, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 1, .source_sequence = 0, .balance_count = 2, .position_count = 0, .margin_count = 0 };
                for ([_]canonical.AssetAmount{ .{ .asset = 1, .atoms = 25_000_000_000 }, .{ .asset = 99, .atoms = 1_000_000_000 } }, 0..) |balance, index|
                    observed.balances[index] = .{ .asset = balance.asset, .total = balance, .available = balance, .cash_balance = balance, .held = .{ .asset = balance.asset, .atoms = 0 }, .liability = .{ .asset = balance.asset, .atoms = 0 }, .isolated_liability = .{ .asset = balance.asset, .atoms = 0 }, .cross_liability = .{ .asset = balance.asset, .atoms = 0 } };
                _ = try owner.apply(fixture.canonicalAt(6, 90, .{ .account_bootstrap_snapshot = observed }));
                event.core.payload.opening_balance.native_balance_count = 1;
                event.core.payload.opening_balance.native_balances[0] = .{ .asset = 99, .atoms = 1_000_000_000 };
            }
            _ = try owner.apply(event);
        }
        try owner.sealBootstrap();
        const before_registry = owner.shard.activatedAssets();
        const before_economics = owner.shard.economicSummary();
        var narrower = before_registry.get(if (third_asset) 99 else 1).?.definition;
        narrower.version += 1;
        narrower.max_balance_atoms = if (third_asset) 500_000_000 else 10_000_000_000;
        narrower.max_single_atoms = narrower.max_balance_atoms;
        try std.testing.expectError(error.AssetAmountOutOfRange, owner.apply(.{ .core = .{ .identity = 991, .payload = .{ .asset_definition_activated = narrower } } }));
        try std.testing.expectEqualDeep(before_registry, owner.shard.activatedAssets());
        try std.testing.expectEqualDeep(before_economics, owner.shard.economicSummary());
        try std.testing.expect(owner.shard.asset_configuration_failed and owner.shard.oms.recovery_only and !owner.closed);
        const recovered = try demo.Owner.recover(memory.interface(), undefined, stream);
        try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        var bytes: [durable.max_snapshot_bytes]u8 = undefined;
        const restored = try TradingShard.restoreSnapshot(try owner.committedSnapshot(&bytes));
        try std.testing.expectEqualDeep(before_registry, restored.shard.activatedAssets());
        try std.testing.expectEqualDeep(before_economics, restored.shard.economicSummary());
    }
}

test "OMS command binds scoped capability and source-owned authority barriers" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    const profile: shard_event.CapabilityProfileActivation = .{
        .exchange_account = 2,
        .instrument = swap_instrument,
        .venue = 1,
        .environment = .simulation,
        .product = .isolated_linear_usdt,
        .version = 4,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 9,
        .max_dispatch_age_ns = std.time.ns_per_s,
        .supports_place = true,
        .supports_cancel = true,
        .supports_native_amend = false,
        .supports_venue_reduce_only = false,
        .supports_post_only = true,
        .supports_market_protection = true,
    };
    var wrong_account = profile;
    wrong_account.exchange_account = 999;
    try std.testing.expectError(error.InvalidCapabilityProfile, applyLive(&run.shard, &run.decision_journal, atGroup(14, .{ .identity = 50, .payload = .{ .capability_profile_activation = wrong_account } })));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(14, .{ .identity = 51, .payload = .{ .capability_profile_activation = profile } }));
    const command = (try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{ .identity = 52, .payload = .{ .timer = fixture.timer(happy_order_quantity) } }))) orelse return error.MissingOrderCommand;
    try std.testing.expect(command.authority.complete());
    try std.testing.expectEqual(@as(u128, 2), command.authority.exchange_account);
    try std.testing.expectEqual(@as(u128, 1), command.authority.virtual_portfolio);
    try std.testing.expectEqual(@as(u128, 2), command.authority.trading_authorization.identity);
    try std.testing.expectEqual(@as(u128, 1), command.authority.primary_lease.identity);
    try std.testing.expectEqual(@as(u64, 4), command.authority.capability.version);
    try std.testing.expectEqual(@as(u64, 9), command.authority.adapter_session);
    try std.testing.expectEqual(command.risk_decision_identity, command.authority.deadline_barrier);
    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = command.command_id, .state = .submitted };
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{ .identity = 53, .payload = .{ .oms_dispatch_batch = dispatch } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(17, .{ .identity = 54, .payload = .{ .control_command = .{
        .command_identity = 54,
        .content_hash = 54,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .trading_pause,
    } } }));
    const cancellations = run.shard.oms.emitted();
    try std.testing.expectEqual(@as(usize, 1), cancellations.len);
    try std.testing.expectEqual(oms_module.Operation.cancel, cancellations[0].operation);
    try std.testing.expect(cancellations[0].authority.complete());
    try std.testing.expectEqual(@as(u128, 54), cancellations[0].authority.trading_authorization.identity);
    try std.testing.expect(cancellations[0].authority.dispatch_deadline_monotonic_ns > command.authority.dispatch_deadline_monotonic_ns);
    var newer_profile = profile;
    newer_profile.version = 5;
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(18, .{ .identity = 55, .payload = .{ .capability_profile_activation = newer_profile } }));
    try std.testing.expectEqual(@as(u64, 4), run.shard.oms.command_history[0].authority.capability.version);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
    var snapshot_storage: [256 * 1024]u8 = undefined;
    const snapshot = try run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence, &snapshot_storage);
    const restored = try TradingShard.restoreSnapshot(snapshot);
    try std.testing.expectEqualSlices(u8, &run.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
}

test "CancelOpenOrders preserves the actual TradingAuthorization grant" {
    var run = try startScenario();
    const granted = try run.shard.currentDispatchAuthorityRefs(swap_instrument);
    try std.testing.expectEqual(@as(u128, 2), granted.trading_authorization.identity);
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(4, 3, .cancel_open_orders));
    const after_cancel = try run.shard.currentDispatchAuthorityRefs(swap_instrument);
    try std.testing.expectEqualDeep(granted.trading_authorization, after_cancel.trading_authorization);
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(5, 4, .trading_pause));
    const after_pause = try run.shard.currentDispatchAuthorityRefs(swap_instrument);
    try std.testing.expectEqual(@as(u128, 5), after_pause.trading_authorization.identity);
    try std.testing.expect(after_pause.trading_authorization.barrier > granted.trading_authorization.barrier);
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "unsupported OMS order semantics reject as replayable exact-only facts" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{ .identity = 70, .payload = .{ .capability_profile_activation = .{
        .exchange_account = 2,
        .instrument = swap_instrument,
        .venue = 1,
        .environment = .simulation,
        .product = .isolated_linear_usdt,
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 1,
        .max_dispatch_age_ns = std.time.ns_per_s,
        .supports_place = true,
        .supports_cancel = true,
        .supports_native_amend = false,
        .supports_venue_reduce_only = false,
        .supports_post_only = false,
        .supports_market_protection = false,
    } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 90, .count = 1 };
    group.members[0] = .{
        .intent_sequence = 90,
        .strategy_instance = 1,
        .operation = .place,
        .instrument = swap_instrument,
        .side = .buy,
        .quantity = 100,
        .limit_price = fixtureOmsPrice(swap_instrument, 501_000),
    };
    const Case = enum { post_only, venue_reduce_only, price_protection, market_unprotected, market_fok, wrong_rules };
    for ([_]Case{ .post_only, .venue_reduce_only, .price_protection, .market_unprotected, .market_fok, .wrong_rules }, 0..) |case, index| {
        group.first_intent_sequence = 90 + index;
        group.members[0].intent_sequence = group.first_intent_sequence;
        group.members[0].order_type = .limit;
        group.members[0].time_in_force = .good_til_canceled;
        group.members[0].venue_reduce_only = false;
        group.members[0].market_protection_price = null;
        group.members[0].limit_price.rules_version = 1;
        switch (case) {
            .post_only => {
                group.members[0].order_type = .post_only;
                group.members[0].time_in_force = .post_only;
            },
            .venue_reduce_only => group.members[0].venue_reduce_only = true,
            .price_protection => group.members[0].market_protection_price = fixtureOmsPrice(swap_instrument, 502_000),
            .market_unprotected => {
                group.members[0].order_type = .market;
                group.members[0].time_in_force = .immediate_or_cancel;
            },
            .market_fok => {
                group.members[0].order_type = .market;
                group.members[0].time_in_force = .fill_or_kill;
                group.members[0].market_protection_price = fixtureOmsPrice(swap_instrument, 502_000);
            },
            .wrong_rules => group.members[0].limit_price.rules_version = 99,
        }
        const before = run.shard.trace.len;
        try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(16 + index, .{ .identity = 90 + index, .payload = .{ .oms_intent_group = group } }))) == null);
        try std.testing.expectEqual(@as(usize, 0), run.shard.oms.order_count);
        try std.testing.expectEqual(if (case == .post_only or case == .venue_reduce_only) shard_event.RejectReason.capability_unsupported else .unsupported_order_spec, run.shard.last_reject_reason);
        try std.testing.expectEqual(before + 1, run.shard.trace.len);
        try std.testing.expectEqual(engine.EventKind.strategy_intent_rejected, run.shard.trace.events[before].kind);
    }
    var supported = run.shard.instrument_registry.get(swap_instrument).?.capability.?;
    supported.version = 2;
    supported.supports_post_only = true;
    supported.supports_market_protection = true;
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(23, .{ .identity = 100, .payload = .{ .capability_profile_activation = supported } }));
    group.first_intent_sequence = 100;
    group.members[0].intent_sequence = 100;
    group.members[0].order_type = .post_only;
    group.members[0].time_in_force = .post_only;
    group.members[0].venue_reduce_only = false;
    group.members[0].limit_price.rules_version = 1;
    group.members[0].market_protection_price = null;
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(24, .{ .identity = 101, .payload = .{ .oms_intent_group = group } }));
    const exact = run.shard.oms.emitted()[0];
    try std.testing.expectEqual(canonical.OrderType.post_only, exact.order_type);
    try std.testing.expectEqual(canonical.TimeInForce.post_only, exact.time_in_force);
    try std.testing.expectEqualDeep(group.members[0].market_protection_price, exact.market_protection_price);
    try std.testing.expect(!exact.venue_reduce_only);
    try std.testing.expect(exact.authority.complete());
    var amend = group;
    amend.first_intent_sequence = 101;
    amend.members[0].intent_sequence = 101;
    amend.members[0].operation = .amend;
    amend.members[0].target_order_id = exact.order_id;
    amend.members[0].expected_revision = exact.revision;
    amend.members[0].native_amend = true;
    const before_amend = run.shard.trace.len;
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(25, .{ .identity = 102, .payload = .{ .oms_intent_group = amend } }))) == null);
    try std.testing.expectEqual(before_amend + 1, run.shard.trace.len);
    try std.testing.expectEqual(shard_event.RejectReason.capability_unsupported, run.shard.last_reject_reason);
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
    var reader = try engine.journal.Reader.init(run.decision_journal.bytes());
    var forged = engine.journal.Journal.init();
    while (true) {
        switch (try reader.next()) {
            .end => break,
            .record => |record| {
                var changed = record;
                if (record.sequence == run.shard.trace.len) changed.flags ^= 1 << 8;
                try forged.append(changed);
            },
        }
    }
    try forged.seal();
    try std.testing.expectError(error.ReplayFactMismatch, engine.replayDigest(forged.bytes(), run.shard.quantity_denominator, run.shard.reservation_model));
}

test "inexact direct price keeps a stable reject without an OMS command" {
    var run: LiveRun = .{ .shard = .{}, .decision_journal = engine.journal.Journal.init() };
    var setup = genesis;
    setup[1].core.payload.margin_rules_activated.price_tick_atoms = 100_000;
    for (setup) |event| _ = try applyLive(&run.shard, &run.decision_journal, event);
    const digest = run.shard.canonicalStateDigest();
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
        .activation_barrier = 0,
        .state_digest = digest,
    } } }));
    try applyHealthyPrelude(&run);
    var request = fixture.timer(1);
    request.limit_price_micros = order_limit_price + 1;
    const before = run.shard.trace.len;
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{ .identity = 102, .payload = .{ .timer = request } }))) == null);
    try std.testing.expectEqual(before + 2, run.shard.trace.len);
    try std.testing.expectEqual(engine.EventKind.strategy_intent_rejected, run.shard.trace.events[before + 1].kind);
    try std.testing.expectEqual(shard_event.RejectReason.unsupported_order_spec, run.shard.last_reject_reason);
    try std.testing.expectEqual(@as(usize, 0), run.shard.oms.order_count);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "core mark micros become canonical ticks at the active venue tick" {
    var run: LiveRun = .{ .shard = .{}, .decision_journal = engine.journal.Journal.init() };
    var setup = genesis;
    setup[1].core.payload.margin_rules_activated.price_tick_atoms = 100_000;
    for (setup) |event| _ = try applyLive(&run.shard, &run.decision_journal, event);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    try std.testing.expectEqual(@as(i128, 500), run.shard.canonical_market.get(swap_instrument).?.mark.?.ticks);
    try std.testing.expectEqual(@as(i64, 50_000_000), run.shard.mark_price_atoms);
}

test "market gap rejects a native intent with a replayable reason" {
    var run = try startScenario();
    const before = run.shard.trace.len;
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(12, .{ .identity = 103, .payload = .{ .timer = fixture.timer(1) } }))) == null);
    try std.testing.expectEqual(shard_event.RejectReason.market_data_gap, run.shard.last_reject_reason);
    try std.testing.expectEqual(shard_event.RejectReason.market_data_gap, run.shard.trace.events[run.shard.trace.len - 1].reject_reason);
    try std.testing.expect(run.shard.trace.len > before);
    try std.testing.expectEqual(@as(u8, 0), run.shard.oms.order_count);
    try applyHealthyPrelude(&run);
    const before_retry = run.shard.trace.len;
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{ .identity = 106, .payload = .{ .external_order_intent = .{
        .strategy_identity = 1,
        .intent_sequence = 1,
        .strategy_cursor = run.shard.trace.len + 1,
        .config_version = 1,
        .activation_identity = 1,
        .portfolio_identity = 1,
        .exchange_account_identity = 2,
        .instrument_identity = swap_instrument,
        .side = .buy,
        .order_type = .limit,
        .time_in_force = .good_til_canceled,
        .portfolio_reduce_only = false,
        .quantity = 1,
        .limit_price_micros = order_limit_price,
    } } }))) == null);
    try std.testing.expectEqual(before_retry + 1, run.shard.trace.len);
    try std.testing.expectEqual(shard_event.RejectReason.intent_identity_conflict, run.shard.last_reject_reason);
    try std.testing.expectEqual(@as(u8, 0), run.shard.oms.order_count);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "risk lease limit rejects a native intent with a replayable reason" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{ .identity = 104, .payload = .{ .risk_lease_granted = .{
        .lease_identity = 104,
        .version = 2,
        .amount_atoms = 1_000,
        .strategy_limit_atoms = 50,
        .portfolio_limit_atoms = 1_000,
        .exchange_account_limit_atoms = 1_000,
        .global_limit_atoms = 1_000,
    } } }));
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{ .identity = 105, .payload = .{ .timer = fixture.timer(happy_order_quantity) } }))) == null);
    try std.testing.expectEqual(shard_event.RejectReason.strategy_limit_exceeded, run.shard.last_reject_reason);
    try std.testing.expectEqual(shard_event.RejectReason.strategy_limit_exceeded, run.shard.trace.events[run.shard.trace.len - 1].reject_reason);
    try std.testing.expectEqual(@as(u8, 0), run.shard.oms.order_count);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

fn applyGenesisReplay(replay: *ReplayTradingShard) !void {
    for (genesis) |event| _ = try replay.apply(event);
    const digest = replay.canonicalStateDigest();
    _ = try replay.apply(atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
        .activation_barrier = 0,
        .state_digest = digest,
    } } }));
}

fn establishSwapPosition(shard: *TradingShard, identity: u64, quantity: i64) !void {
    _ = try shard.apply(atGroup(identity, .{ .identity = identity, .payload = .{ .mark_price = .{
        .instrument = swap_instrument,
        .price_atoms = 50_000_000,
    } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = identity, .count = 1 };
    group.members[0] = .{
        .intent_sequence = identity,
        .operation = .place,
        .instrument = swap_instrument,
        .side = .buy,
        .quantity = quantity,
        .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000),
    };
    const placed = try shard.apply(atGroup(identity + 1, .{ .identity = identity, .payload = .{ .oms_intent_group = group } }));
    const order_id = placed.oms_commands[0].order_id;
    _ = try shard.apply(atGroup(identity + 2, .{ .identity = identity, .payload = .{ .oms_execution_report = .{
        .report_id = identity,
        .order_id = order_id,
        .revision = 1,
        .status = .filled,
        .cumulative_quantity = quantity,
        .remaining_quantity = 0,
    } } }));
    _ = try shard.apply(atGroup(identity + 3, .{ .identity = identity, .payload = .{ .economic_fill = .{
        .fill_id = identity,
        .order_id = order_id,
        .quantity = quantity,
        .price_ticks = 50_000_000,
    } } }));
}

test "stable CanonicalEvent decoder rejects malformed envelopes without state change" {
    var shard: TradingShard = .{};
    const before = shard.canonicalStateDigest();
    const core = atGroup(1, .{
        .identity = 1,
        .payload = .{ .timer = fixture.timer(1) },
    }).core;
    var payload: [engine.journal.max_payload_size]u8 = undefined;
    payload[0] = 1; // StableInputTag.core
    const encoded = try shard_event.encodeInput(payload[1..], core);
    var record: engine.journal.Record = .{
        .type_id = 0,
        .schema_version = engine.schema_version,
        .flags = engine.journal.input_flag,
        .sequence = 1,
        .source_time = 0,
        .receive_time = 0,
        .monotonic_time = 0,
        .wall_time = 0,
        .time_presence = .{},
        .payload = payload[0 .. encoded.len + 1],
    };

    record.schema_version = production_contract.previous_journal_schema_version;
    try std.testing.expectError(error.UnsupportedSchema, engine.decodeStableInput(record));
    record.schema_version = engine.schema_version;
    record.payload = payload[0..0];
    try std.testing.expectError(error.TruncatedInputPayload, engine.decodeStableInput(record));
    payload[0] = 255;
    record.payload = payload[0..1];
    try std.testing.expectError(error.UnknownInputType, engine.decodeStableInput(record));
    payload[0] = 1;
    record.payload = payload[0 .. encoded.len + 2];
    payload[encoded.len + 1] = 0;
    try std.testing.expectError(error.TrailingInputPayload, engine.decodeStableInput(record));
    try std.testing.expectError(error.InputPayloadTooLarge, shard_event.encodeInput(payload[0..0], core));
    try std.testing.expectEqualSlices(u8, &before, &shard.canonicalStateDigest());
}

test "configurable Genesis fails closed until authority is complete" {
    var mismatched: TradingShard = .{};
    var cash_as_linear = fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 1 }, .cash)[0];
    cash_as_linear.core.payload.instrument_rules_activated.product = .isolated_linear_usdt;
    const before_mismatch = mismatched.canonicalStateDigest();
    try std.testing.expectError(error.IncompatibleProductReservationModel, mismatched.apply(cash_as_linear));
    try std.testing.expectEqualSlices(u8, &before_mismatch, &mismatched.canonicalStateDigest());
    std.debug.print("core_input_rejection: product_model=IncompatibleProductReservationModel\n", .{});
    var incomplete: TradingShard = .{};
    try std.testing.expectError(error.GenesisIncomplete, incomplete.apply(atGroup(1, .{
        .identity = 1,
        .payload = .{ .oms_intent_group = .{ .first_intent_sequence = 1, .count = 0 } },
    })));

    var out_of_order: TradingShard = .{};
    try std.testing.expectError(error.InvalidMarginRules, out_of_order.apply(.{ .core = .{
        .identity = 1,
        .payload = .{ .margin_rules_activated = .{ .version = 1 } },
    } }));

    var configured = try startScenarioAuthorized(.{
        .strategy_identity = 9,
        .config_version = 7,
        .activation_identity = 8,
        .activation_barrier = 0,
    }, .cash);
    try std.testing.expect(configured.shard.genesisReady());
    try std.testing.expectEqual(@as(u128, 9), configured.shard.strategy_identity);
    try std.testing.expectEqual(@as(i64, 100_000_000), configured.shard.quantity_denominator);
    try configured.decision_journal.seal();
    _ = try assertReplayEquivalentConfigured(configured, 100_000_000, .cash);
}

test "native and Python intents cross the same authority and risk seam" {
    const authorization: host_gateway.Authorization = .{
        .strategy_identity = 40,
        .config_version = 7,
        .activation_identity = 50,
        .activation_barrier = 0,
    };
    var native = try startScenarioAuthorized(authorization, .leveraged);
    var python = try startScenarioAuthorized(authorization, .leveraged);
    try applyHealthyPrelude(&native);
    try applyHealthyPrelude(&python);

    const native_command = (try native.shard.apply(atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = fixture.timer(happy_order_quantity) },
    }))).order_command.?;
    const python_input = atGroup(15, .{
        .identity = 1,
        .payload = .{ .external_order_intent = .{
            .strategy_identity = authorization.strategy_identity,
            .intent_sequence = 1,
            .strategy_cursor = python.shard.trace.len + 1,
            .config_version = authorization.config_version,
            .activation_identity = authorization.activation_identity,
            .portfolio_identity = 1,
            .exchange_account_identity = 2,
            .instrument_identity = 3,
            .side = .buy,
            .order_type = .limit,
            .time_in_force = .good_til_canceled,
            .portfolio_reduce_only = false,
            .quantity = happy_order_quantity,
            .limit_price_micros = order_limit_price,
        } },
    });
    const python_command = (try applyLive(&python.shard, &python.decision_journal, python_input)).?;
    const before_duplicate = python.shard.canonicalStateDigest();
    const duplicate_python = try python.shard.apply(python_input);
    try std.testing.expectEqual(@as(usize, 0), duplicate_python.oms_commands.len);
    try std.testing.expectEqualSlices(u8, &before_duplicate, &python.shard.canonicalStateDigest());
    var retried_python = python_input;
    retried_python.core.identity = 2;
    retried_python.core.payload.external_order_intent.strategy_cursor += 1;
    try std.testing.expect((try applyLive(&python.shard, &python.decision_journal, retried_python)) == null);
    try std.testing.expectEqual(shard_event.RejectReason.intent_identity_conflict, python.shard.last_reject_reason);
    try std.testing.expectEqual(native_command.quantity, python_command.quantity);
    try std.testing.expectEqual(native_command.limit_price, python_command.limit_price);
    try std.testing.expectEqual(native_command.reservation, python_command.reservation);

    var blocked_by_order = python_input;
    blocked_by_order.core.identity = 3;
    blocked_by_order.core.payload.external_order_intent.intent_sequence = 2;
    blocked_by_order.core.payload.external_order_intent.strategy_cursor = python.shard.trace.len + 1;
    const before_open_order = python.shard.trace.len;
    try std.testing.expect((try applyLive(&python.shard, &python.decision_journal, blocked_by_order)) == null);
    try std.testing.expectEqual(shard_event.RejectReason.open_order, python.shard.trace.events[before_open_order].reject_reason);
    try std.testing.expectEqual(@as(u8, 1), python.shard.oms.order_count);
    try std.testing.expectEqual(@as(u64, 0), python.shard.dispatch_attempt_count);
    try python.decision_journal.seal();
    _ = try assertReplayEquivalent(python);

    var unauthorized = try startScenarioAuthorized(authorization, .leveraged);
    try applyHealthyPrelude(&unauthorized);
    const reject_before = unauthorized.shard.trace.len;
    const wrong_config = atGroup(15, .{
        .identity = 1,
        .payload = .{ .external_order_intent = .{
            .strategy_identity = authorization.strategy_identity,
            .intent_sequence = 1,
            .strategy_cursor = unauthorized.shard.trace.len + 1,
            .config_version = authorization.config_version + 1,
            .activation_identity = authorization.activation_identity,
            .portfolio_identity = 1,
            .exchange_account_identity = 2,
            .instrument_identity = 3,
            .side = .buy,
            .order_type = .limit,
            .time_in_force = .good_til_canceled,
            .portfolio_reduce_only = false,
            .quantity = happy_order_quantity,
            .limit_price_micros = order_limit_price,
        } },
    });
    try std.testing.expect((try applyLive(&unauthorized.shard, &unauthorized.decision_journal, wrong_config)) == null);
    try std.testing.expectEqual(reject_before + 1, unauthorized.shard.trace.len);
    try std.testing.expectEqual(engine.EventKind.strategy_intent_rejected, unauthorized.shard.trace.events[reject_before].kind);
    try std.testing.expectEqual(shard_event.RejectReason.identity_mismatch, unauthorized.shard.last_reject_reason);
    try std.testing.expectEqual(shard_event.RejectReason.identity_mismatch, unauthorized.shard.trace.events[reject_before].reject_reason);
    try std.testing.expectEqual(@as(usize, 0), unauthorized.shard.oms.order_count);
    var corrected = wrong_config;
    corrected.core.identity = 2;
    corrected.core.payload.external_order_intent.config_version = authorization.config_version;
    try std.testing.expect((try applyLive(&unauthorized.shard, &unauthorized.decision_journal, corrected)) == null);
    try std.testing.expectEqual(shard_event.RejectReason.intent_identity_conflict, unauthorized.shard.last_reject_reason);
    try std.testing.expectEqual(@as(u8, 0), unauthorized.shard.oms.order_count);
    try unauthorized.decision_journal.seal();
    _ = try assertReplayEquivalent(unauthorized);
    var rejected_snapshot_storage: [256 * 1024]u8 = undefined;
    const rejected_snapshot = try unauthorized.shard.snapshot(&unauthorized.decision_journal, unauthorized.decision_journal.last_sequence, &rejected_snapshot_storage);
    const restored_rejection = try TradingShard.restoreSnapshot(rejected_snapshot);
    try std.testing.expectEqual(shard_event.RejectReason.identity_mismatch, restored_rejection.shard.trace.events[reject_before].reject_reason);
}

test "host fault revokes the old activation before a replacement can trade" {
    var run = try startScenario();
    const config: host_gateway.Config = .{
        .schema_registry = 1,
        .decision_domain = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
        .authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 },
    };
    const subscriptions = [_]host_gateway.Subscription{host_gateway.Subscription.of(1, &.{.mark_price})};
    var gateway = try host_gateway.Gateway.init(config, &subscriptions);
    const old_proof = try run.shard.appliedHostActivation(&run.decision_journal);
    try std.testing.expectError(error.ActivationBarrierNotApplied, gateway.activate(&run.shard, &run.decision_journal));
    try gateway.recordPublished(1, old_proof.fact_sequence, 100);
    try gateway.activate(&run.shard, &run.decision_journal);
    try std.testing.expect(gateway.trading_enabled);
    const premature_intent = atGroup(12, .{ .identity = 79, .payload = .{ .external_order_intent = .{
        .strategy_identity = 1,
        .intent_sequence = 1,
        .strategy_cursor = old_proof.fact_sequence,
        .config_version = 1,
        .activation_identity = 1,
        .portfolio_identity = 1,
        .exchange_account_identity = 2,
        .instrument_identity = swap_instrument,
        .side = .buy,
        .order_type = .limit,
        .time_in_force = .good_til_canceled,
        .portfolio_reduce_only = false,
        .quantity = 1,
        .limit_price_micros = order_limit_price,
    } } });
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, premature_intent)) == null);
    try std.testing.expectEqual(shard_event.RejectReason.host_not_activated, run.shard.last_reject_reason);
    var premature_frame_storage: [256]u8 = undefined;
    const premature_frame = try host_gateway.encodeOutputFrame(&premature_frame_storage, config, 1, old_proof.fact_sequence, 1, 100, order_limit_price);
    try std.testing.expectEqual(host_gateway.RejectReason.invalid_cursor, gateway.ingest(premature_frame, 101).rejected.reason);
    const old_identity = run.shard.host_activation_identity;
    const old_cursor: u64 = @intCast(run.shard.trace.len + 1);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(12, .{ .identity = 80, .payload = .{ .host_activation_revoked = .{
        .strategy_identity = 1,
        .activation_identity = old_identity,
        .reason = .fault,
    } } }));
    gateway.beginRecovery();
    try std.testing.expectError(error.HostNotActivated, gateway.activate(&run.shard, &run.decision_journal));
    try std.testing.expectError(error.HostNotActivated, run.shard.appliedHostActivation(&run.decision_journal));
    try std.testing.expectEqual(@as(u128, 0), run.shard.host_activation_identity);
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectError(error.InvalidHostActivation, run.shard.apply(atGroup(13, .{ .identity = 81, .payload = .{ .host_activated = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 2,
        .session = .{ .fencing = 0, .shard = 0, .generation = 0 },
        .activation_barrier = 0,
        .state_digest = run.shard.canonicalStateDigest(),
    } } })));
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(13, .{ .identity = 81, .payload = .{ .external_order_intent = .{
        .strategy_identity = 1,
        .intent_sequence = 2,
        .strategy_cursor = old_cursor + 1,
        .config_version = 1,
        .activation_identity = old_identity,
        .portfolio_identity = 1,
        .exchange_account_identity = 2,
        .instrument_identity = swap_instrument,
        .side = .buy,
        .order_type = .limit,
        .time_in_force = .good_til_canceled,
        .portfolio_reduce_only = false,
        .quantity = 1,
        .limit_price_micros = order_limit_price,
    } } }))) == null);
    try std.testing.expectEqual(shard_event.RejectReason.host_not_activated, run.shard.last_reject_reason);
    const digest = run.shard.canonicalStateDigest();
    try std.testing.expectError(error.StaleHostActivation, run.shard.apply(atGroup(14, .{ .identity = 82, .payload = .{ .host_activated = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = old_identity,
        .session = config.session,
        .activation_barrier = 0,
        .state_digest = digest,
    } } })));
    const new_barrier: u64 = @intCast(run.shard.trace.len);
    var next_config = config;
    next_config.session.generation += 1;
    next_config.authorization.activation_identity = 2;
    next_config.authorization.activation_barrier = new_barrier;
    try gateway.beginSession(next_config, &run.shard, &run.decision_journal);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{ .identity = 83, .payload = .{ .host_activated = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 2,
        .session = next_config.session,
        .activation_barrier = new_barrier,
        .state_digest = digest,
    } } }));
    try std.testing.expectEqual(@as(u128, 2), run.shard.host_activation_identity);
    const new_proof = try run.shard.appliedHostActivation(&run.decision_journal);
    try std.testing.expectError(error.ActivationBarrierNotApplied, gateway.activate(&run.shard, &run.decision_journal));
    try gateway.recordPublished(1, new_proof.fact_sequence, 101);
    try gateway.activate(&run.shard, &run.decision_journal);
    try std.testing.expect(gateway.trading_enabled);
    var frame_storage: [256]u8 = undefined;
    const old_frame = try host_gateway.encodeOutputFrame(&frame_storage, config, 1, old_proof.fact_sequence, 1, 100, order_limit_price);
    try std.testing.expectEqual(host_gateway.RejectReason.old_session, gateway.ingest(old_frame, 102).rejected.reason);
    try applyHealthyPrelude(&run);
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{ .identity = 84, .payload = .{ .external_order_intent = .{
        .strategy_identity = 1,
        .intent_sequence = 3,
        .strategy_cursor = @intCast(run.shard.trace.len + 1),
        .config_version = 1,
        .activation_identity = 2,
        .portfolio_identity = 1,
        .exchange_account_identity = 2,
        .instrument_identity = swap_instrument,
        .side = .buy,
        .order_type = .limit,
        .time_in_force = .good_til_canceled,
        .portfolio_reduce_only = false,
        .quantity = happy_order_quantity,
        .limit_price_micros = order_limit_price,
    } } }))) != null);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(17, .{ .identity = 85, .payload = .{ .control_command = .{
        .command_identity = 85,
        .content_hash = 85,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .trading_pause,
    } } }));
    const paused_frame = try host_gateway.encodeOutputFrame(&frame_storage, next_config, 1, new_proof.fact_sequence, 2, 100, order_limit_price);
    try std.testing.expectEqual(host_gateway.RejectReason.unauthorized, gateway.ingest(paused_frame, 102).rejected.reason);
    try std.testing.expect(!gateway.trading_enabled);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "new HostSession revokes the old direct-trade identity" {
    var run = try startScenario();
    const config: host_gateway.Config = .{
        .schema_registry = 1,
        .decision_domain = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
        .authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 },
    };
    const subscriptions = [_]host_gateway.Subscription{host_gateway.Subscription.of(1, &.{.mark_price})};
    var gateway = try host_gateway.Gateway.init(config, &subscriptions);
    try gateway.recordPublished(1, @intCast(run.shard.trace.len + 1), 100);
    try gateway.activate(&run.shard, &run.decision_journal);
    var next = config;
    next.session.generation += 1;
    next.authorization.activation_identity = 2;
    gateway.beginRecovery();
    try gateway.beginSession(next, &run.shard, &run.decision_journal);
    try std.testing.expectEqual(@as(u128, 0), run.shard.host_activation_identity);
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(12, .{ .identity = 90, .payload = .{ .timer = fixture.timer(1) } }))) == null);
    try std.testing.expectEqual(shard_event.RejectReason.host_not_activated, run.shard.last_reject_reason);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "fresh Gateway revokes a replayed old Host activation before restart" {
    var original = try startScenario();
    try original.decision_journal.seal();
    var snapshot_storage: [64 * 1024]u8 = undefined;
    const snapshot = try original.shard.snapshot(&original.decision_journal, original.decision_journal.last_sequence, &snapshot_storage);
    const restored = try TradingShard.restoreSnapshot(snapshot);
    var recovered = restored.shard;
    var tail = engine.journal.Journal.initAt(restored.barrier + 1);
    const stale_config: host_gateway.Config = .{
        .schema_registry = 1,
        .decision_domain = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 2 },
        .authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 },
    };
    const subscriptions = [_]host_gateway.Subscription{host_gateway.Subscription.of(1, &.{.mark_price})};
    var stale_gateway = try host_gateway.Gateway.init(stale_config, &subscriptions);
    try stale_gateway.recordPublished(1, @intCast(recovered.trace.len + 1), 100);
    try std.testing.expectError(error.InvalidAuthorization, stale_gateway.activate(&recovered, &tail));
    const config: host_gateway.Config = .{
        .schema_registry = 1,
        .decision_domain = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
        .authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 999, .activation_barrier = 0 },
    };
    var fresh_gateway = try host_gateway.Gateway.init(config, &subscriptions);
    var next = config;
    next.session.generation += 1;
    next.authorization.activation_identity = 2;
    try fresh_gateway.beginSession(next, &recovered, &tail);
    try std.testing.expectEqual(@as(u128, 0), recovered.host_activation_identity);
    try std.testing.expect((try applyLive(&recovered, &tail, atGroup(12, .{ .identity = 91, .payload = .{ .timer = fixture.timer(1) } }))) == null);
    try std.testing.expectEqual(shard_event.RejectReason.host_not_activated, recovered.last_reject_reason);
    try tail.seal();
    const replayed = try TradingShard.restore(snapshot, tail.bytes());
    try std.testing.expectEqualSlices(u8, &recovered.canonicalStateDigest(), &replayed.shard.canonicalStateDigest());
}

test "active Host exit and timeout journal revocation blocks direct trade" {
    inline for (.{ false, true }) |timeout| {
        var run = try startScenario();
        const config: host_gateway.Config = .{
            .schema_registry = 1,
            .decision_domain = 1,
            .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
            .authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 },
        };
        const subscriptions = [_]host_gateway.Subscription{host_gateway.Subscription.of(1, &.{.mark_price})};
        var gateway = try host_gateway.Gateway.init(config, &subscriptions);
        try gateway.recordPublished(1, @intCast(run.shard.trace.len + 1), 100);
        try gateway.activate(&run.shard, &run.decision_journal);
        var supervisor = try host_lifecycle.HostSupervisor.init(host_lifecycle.developmentPlan(0, 1, 0x0003_0900), 0);
        supervisor.state = .active;
        if (timeout) {
            try std.testing.expectEqual(host_lifecycle.Result.timed_out, supervisor.poll(supervisor.plan.hang_timeout_ns + 1));
        } else {
            supervisor.processExited(false);
        }
        try std.testing.expect(try host_lifecycle.revokeHostAuthority(&supervisor, &gateway, &run.shard, &run.decision_journal, 92, .fault));
        try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(12, .{ .identity = 93, .payload = .{ .timer = fixture.timer(1) } }))) == null);
        try std.testing.expectEqual(shard_event.RejectReason.host_not_activated, run.shard.last_reject_reason);
        try run.decision_journal.seal();
        _ = try assertReplayEquivalent(run);
    }
}

test "control commands authorize pause cancel and replay lifecycle deterministically" {
    var run = try startScenario();
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());

    const duplicate = try run.shard.apply(genesis[genesis.len - 1]);
    try std.testing.expectEqual(@as(usize, 0), duplicate.facts.len);
    try std.testing.expectError(error.ControlCommandWrongTarget, run.shard.apply(atGroup(12, .{ .identity = 9, .payload = .{ .control_command = .{
        .command_identity = 9,
        .content_hash = 9,
        .target_identity = 2,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .cancel_open_orders,
    } } })));
    try std.testing.expectError(error.ControlCommandExpired, run.shard.apply(atGroup(12, .{ .identity = 9, .payload = .{ .control_command = .{
        .command_identity = 9,
        .content_hash = 9,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = 1,
        .kind = .cancel_open_orders,
    } } })));

    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(12, .{ .identity = 3, .payload = .{ .control_command = .{
        .command_identity = 3,
        .content_hash = 3,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .trading_pause,
    } } }));
    try std.testing.expectEqual(operational.OperationalMode.draining, run.shard.operational_state.mode);
    try std.testing.expectEqual(@as(u128, 0), run.shard.host_activation_identity);
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(13, .{ .identity = 1, .payload = .{ .timer = fixture.timer(1) } }))) == null);
    try std.testing.expectEqual(shard_event.RejectReason.host_not_activated, run.shard.last_reject_reason);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(14, .{ .identity = 3, .payload = .{ .lifecycle_progress = .{
        .operation_identity = 3,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 0,
    } } }));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "layered gates latch kill while warning and self recovery stay narrow" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(12, .{ .identity = 10, .payload = .{ .safety_gate_change = .{
        .gate_identity = 10,
        .target_identity = 1,
        .kind = .warning,
        .reason = .margin_warning,
        .open = false,
        .blocks_buy = true,
        .blocks_sell = false,
    } } }));
    try std.testing.expect(!run.shard.operational_state.mayIncrease(true));
    try std.testing.expect(run.shard.operational_state.mayIncrease(false));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 11, .payload = .{ .safety_gate_change = .{
        .gate_identity = 11,
        .target_identity = 1,
        .kind = .self_recovering,
        .reason = .observability,
        .open = false,
    } } }));
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectError(error.UnverifiedContinuityProof, run.shard.apply(atGroup(14, .{ .identity = 11, .payload = .{ .safety_gate_change = .{
        .gate_identity = 11,
        .target_identity = 1,
        .kind = .self_recovering,
        .reason = .observability,
        .open = true,
        .continuity_proven = true,
    } } })));
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
    _ = try run.shard.apply(atGroup(15, .{ .identity = 12, .payload = .{ .safety_gate_change = .{
        .gate_identity = 12,
        .target_identity = 1,
        .kind = .latched,
        .reason = .margin_kill,
        .open = false,
    } } }));
    try std.testing.expect(!run.shard.operational_state.trading_authorized);
    _ = try run.shard.apply(atGroup(16, .{ .identity = 12, .payload = .{ .safety_gate_change = .{
        .gate_identity = 12,
        .target_identity = 1,
        .kind = .latched,
        .reason = .margin_kill,
        .open = true,
    } } }));
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.apply(atGroup(17, .{ .identity = 4, .payload = .{ .control_command = .{
        .command_identity = 4,
        .content_hash = 4,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .enable_trading,
    } } })));
}

test "de risk locks target and flatten requires warning" {
    var run = try startScenario();
    try establishSwapPosition(&run.shard, 500, 10);
    try std.testing.expectError(error.RiskWarningRequired, run.shard.apply(atGroup(12, .{ .identity = 3, .payload = .{ .control_command = .{
        .command_identity = 3,
        .content_hash = 3,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .de_risk,
        .target_position = 0,
    } } })));
    _ = try run.shard.apply(atGroup(12, .{ .identity = 30, .payload = .{ .risk_warning = .{
        .warning_identity = 30,
        .target_identity = 1,
    } } }));
    _ = try run.shard.apply(atGroup(12, .{ .identity = 3, .payload = .{ .control_command = .{
        .command_identity = 3,
        .content_hash = 3,
        .target_identity = 1,
        .expected_version = 4,
        .expires_at = std.math.maxInt(u64),
        .kind = .de_risk,
        .target_position = 0,
        .risk_warning_acknowledged = true,
        .risk_warning_identity = 30,
    } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 100, .count = 1 };
    group.members[0] = .{ .intent_sequence = 100, .operation = .place, .instrument = swap_instrument, .side = .sell, .quantity = 5, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    const reducing = try run.shard.apply(atGroup(13, .{ .identity = 100, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), reducing.oms_commands.len);
    group.members[0].side = .buy;
    group.first_intent_sequence = 101;
    group.members[0].intent_sequence = 101;
    try std.testing.expectEqual(shard_event.RejectReason.authorization_closed, (try run.shard.apply(atGroup(14, .{ .identity = 101, .payload = .{ .oms_intent_group = group } }))).facts[0].reject_reason);
}

fn placeIntentGroup(
    run: *LiveRun,
    group_index: u64,
    event_identity: u64,
    first_intent_sequence: u64,
    side: oms_module.Side,
    quantity: i64,
) !oms_module.Command {
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = first_intent_sequence, .count = 1 };
    group.members[0] = .{
        .intent_sequence = first_intent_sequence,
        .operation = .place,
        .instrument = swap_instrument,
        .side = side,
        .quantity = quantity,
        .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price),
    };
    const placed = try applyLive(&run.shard, &run.decision_journal, atGroup(group_index, .{
        .identity = event_identity,
        .payload = .{ .oms_intent_group = group },
    }));
    _ = placed;
    const emitted = run.shard.oms.emitted();
    if (emitted.len != 1) return error.UnexpectedCommandCount;
    return emitted[0];
}

fn expectKeepPositionsStopped(run: *const LiveRun, preserved: TradingShard.LifecycleEconomics) !void {
    try std.testing.expectEqual(@as(usize, 1), run.shard.oms.emitted().len);
    try std.testing.expectEqual(oms_module.Operation.cancel, run.shard.oms.emitted()[0].operation);
    try std.testing.expectEqual(operational.OperationalMode.stopped, run.shard.operational_state.mode);
    try std.testing.expect(!run.shard.operational_state.trading_authorized);
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expect(!run.shard.operational_state.mayReduceOnly());
    try std.testing.expectEqual(@as(u128, 0), run.shard.operational_state.active_operation_identity);
    try std.testing.expectEqualDeep(preserved, run.shard.captureLifecycleEconomics());
}

test "keep positions stops through shard seam preserving economics" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);

    const opened = try placeIntentGroup(&run, 15, 100, 100, .buy, happy_order_quantity);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{ .identity = 101, .payload = .{ .economic_fill = .{
        .fill_id = 101,
        .order_id = opened.order_id,
        .quantity = happy_order_quantity,
        .price_ticks = 49_900_000_000,
        .fee_atoms = 30,
    } } }));
    const preserved = run.shard.captureLifecycleEconomics();
    try std.testing.expect(preserved.positions.portfolio_swap.quantity != 0);
    try std.testing.expect(preserved.ledger.transaction_count != 0);

    try std.testing.expectError(error.ControlCommandWrongTarget, run.shard.apply(atGroup(17, .{ .identity = 900, .payload = .{ .control_command = .{
        .command_identity = 40,
        .content_hash = 40,
        .target_identity = 2,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .stop_keep_positions,
    } } })));
    try std.testing.expectError(error.ControlCommandExpired, run.shard.apply(atGroup(17, .{ .identity = 901, .payload = .{ .control_command = .{
        .command_identity = 40,
        .content_hash = 40,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = 1,
        .kind = .stop_keep_positions,
    } } })));
    try std.testing.expectError(error.ControlCommandVersionMismatch, run.shard.apply(lifecycleCommand(40, 999, .stop_keep_positions)));

    const stopped = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(40, 3, .stop_keep_positions));
    _ = stopped;
    try expectKeepPositionsStopped(&run, preserved);

    // A stopped shard may preserve a position, but the cancellation it issued
    // must still be reconciled before a later session sends another order.
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(18, .{ .identity = 102, .payload = .{ .oms_execution_report = .{
        .report_id = 102,
        .order_id = opened.order_id,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = happy_order_quantity,
        .remaining_quantity = 0,
    } } }));

    const duplicate_stop = try run.shard.apply(lifecycleCommand(40, 3, .stop_keep_positions));
    try std.testing.expectEqual(@as(usize, 0), duplicate_stop.facts.len);
    try std.testing.expectEqual(@as(usize, 0), run.shard.oms.emitted().len);

    var buy_group: oms_module.IntentGroup = .{ .first_intent_sequence = 110, .count = 1 };
    buy_group.members[0] = .{ .intent_sequence = 110, .operation = .place, .instrument = swap_instrument, .side = .buy, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price) };
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(18, .{ .identity = 110, .payload = .{ .oms_intent_group = buy_group } }))) == null);
    try std.testing.expectEqual(shard_event.RejectReason.authorization_closed, run.shard.last_reject_reason);
    var reduce_group: oms_module.IntentGroup = .{ .first_intent_sequence = 111, .count = 1 };
    reduce_group.members[0] = .{ .intent_sequence = 111, .operation = .place, .instrument = swap_instrument, .side = .sell, .portfolio_reduce_only = true, .quantity = 40, .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price) };
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(19, .{ .identity = 111, .payload = .{ .oms_intent_group = reduce_group } }))) == null);
    try std.testing.expectEqual(shard_event.RejectReason.authorization_closed, run.shard.last_reject_reason);
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.apply(lifecycleCommand(41, 4, .enable_trading)));

    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(20, .{ .identity = 120, .payload = .{ .safety_gate_change = .{
        .gate_identity = 77,
        .target_identity = 1,
        .kind = .latched,
        .reason = .uncertain_order,
        .open = false,
    } } }));
    try std.testing.expect(run.shard.operational_state.latch_count > 0);

    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(42, 4, .start_recovery));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(21, .{ .identity = 121, .payload = .recovery_completed }));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.apply(lifecycleCommand(43, 6, .enable_trading)));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(49, 6, 77));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(50, 7, primary_lease_gate_identity));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(51, 8, risk_lease_gate_identity));
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(52, 9, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectEqual(preserved.positions.portfolio_swap.quantity, run.shard.economicSummary().portfolio.swap.quantity);

    const resumed_reduce = try placeIntentGroup(&run, 22, 130, 130, .sell, 40);
    try std.testing.expect(resumed_reduce.portfolio_reduce_only);
    try std.testing.expectEqual(@as(i64, 40), resumed_reduce.quantity);

    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "full lifecycle trajectories authorize only prescribed risk cancel and reduce behavior" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);

    const first_order = try placeIntentGroup(&run, 15, 100, 100, .buy, happy_order_quantity);
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(3, 3, .cancel_open_orders));
    try std.testing.expectEqual(@as(usize, 1), run.shard.oms.emitted().len);
    try std.testing.expectEqual(oms_module.Operation.cancel, run.shard.oms.emitted()[0].operation);
    try std.testing.expectEqual(operational.OperationalMode.trading, run.shard.operational_state.mode);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{ .identity = 101, .payload = .{ .oms_execution_report = .{
        .report_id = 101,
        .order_id = first_order.order_id,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = 0,
        .remaining_quantity = happy_order_quantity,
    } } }));
    const requote_order = try placeIntentGroup(&run, 17, 101, 101, .buy, happy_order_quantity);
    try std.testing.expectEqual(operational.OperationalMode.trading, run.shard.operational_state.mode);

    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(4, 4, .trading_pause));
    try std.testing.expectEqual(operational.OperationalMode.draining, run.shard.operational_state.mode);
    try std.testing.expectError(error.InvalidLifecycleProgress, run.shard.apply(atGroup(18, .{ .identity = 103, .payload = .{ .lifecycle_progress = .{
        .operation_identity = 4,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 0,
    } } })));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(19, .{ .identity = 104, .payload = .{ .oms_execution_report = .{
        .report_id = 104,
        .order_id = requote_order.order_id,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = 0,
        .remaining_quantity = happy_order_quantity,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(20, .{ .identity = 105, .payload = .{ .lifecycle_progress = .{
        .operation_identity = 4,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 0,
    } } }));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);

    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(5, 6, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());

    const position_order = try placeIntentGroup(&run, 21, 102, 102, .buy, happy_order_quantity);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(22, .{ .identity = 107, .payload = .{ .economic_fill = .{
        .fill_id = 107,
        .order_id = position_order.order_id,
        .quantity = happy_order_quantity,
        .price_ticks = 49_900_000_000,
        .fee_atoms = 30,
    } } }));
    const preserved = run.shard.captureLifecycleEconomics();
    try std.testing.expectEqual(@as(i64, 100), preserved.positions.portfolio_swap.quantity);
    try std.testing.expectEqual(preserved.positions.portfolio_swap.quantity, preserved.positions.exchange_swap.quantity);

    const stopped = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(6, 7, .stop_keep_positions));
    _ = stopped;
    try expectKeepPositionsStopped(&run, preserved);
    var stop_buy_group: oms_module.IntentGroup = .{ .first_intent_sequence = 103, .count = 1 };
    stop_buy_group.members[0] = .{ .intent_sequence = 103, .operation = .place, .instrument = swap_instrument, .side = .buy, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price) };
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(23, .{ .identity = 108, .payload = .{ .oms_intent_group = stop_buy_group } }))) == null);
    try std.testing.expectEqual(shard_event.RejectReason.authorization_closed, run.shard.last_reject_reason);
    const duplicate_stop = try run.shard.apply(lifecycleCommand(6, 7, .stop_keep_positions));
    try std.testing.expectEqual(@as(usize, 0), duplicate_stop.facts.len);
    try std.testing.expectEqual(@as(usize, 0), run.shard.oms.emitted().len);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(24, .{ .identity = 121, .payload = .{ .oms_execution_report = .{
        .report_id = 121,
        .order_id = position_order.order_id,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = happy_order_quantity,
        .remaining_quantity = 0,
    } } }));

    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(7, 8, .start_recovery));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(24, .{ .identity = 109, .payload = .recovery_completed }));
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(8, 10, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectEqual(preserved.positions.portfolio_swap.quantity, run.shard.economicSummary().portfolio.swap.quantity);

    _ = try applyLive(&run.shard, &run.decision_journal, deRiskCommand(9, 11, 40, 0));
    try std.testing.expectEqual(operational.OperationalMode.draining, run.shard.operational_state.mode);
    var increase_group: oms_module.IntentGroup = .{ .first_intent_sequence = 104, .count = 1 };
    increase_group.members[0] = .{ .intent_sequence = 104, .operation = .place, .instrument = swap_instrument, .side = .buy, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price) };
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(25, .{ .identity = 110, .payload = .{ .oms_intent_group = increase_group } }))) == null);
    try std.testing.expectEqual(shard_event.RejectReason.authorization_closed, run.shard.last_reject_reason);
    const derisk_sell = try placeIntentGroup(&run, 26, 105, 105, .sell, 60);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(27, .{ .identity = 112, .payload = .{ .economic_fill = .{
        .fill_id = 112,
        .order_id = derisk_sell.order_id,
        .quantity = 60,
        .price_ticks = 50_000_000_000,
        .fee_atoms = 25,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(28, .{ .identity = 118, .payload = .{ .oms_execution_report = .{
        .report_id = 118,
        .order_id = derisk_sell.order_id,
        .revision = 1,
        .status = .filled,
        .cumulative_quantity = 60,
        .remaining_quantity = 0,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(29, .{ .identity = 113, .payload = .{ .lifecycle_progress = .{
        .operation_identity = 9,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 40,
    } } }));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);

    try std.testing.expectError(error.RiskWarningRequired, run.shard.apply(deRiskCommand(10, 13, 0, 0)));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(29, .{ .identity = 114, .payload = .{ .risk_warning = .{
        .warning_identity = 31,
        .target_identity = 1,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, deRiskCommand(10, 14, 0, 31));
    try std.testing.expectEqual(operational.OperationalMode.draining, run.shard.operational_state.mode);
    const flatten_sell = try placeIntentGroup(&run, 30, 106, 106, .sell, 40);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(31, .{ .identity = 116, .payload = .{ .economic_fill = .{
        .fill_id = 116,
        .order_id = flatten_sell.order_id,
        .quantity = 40,
        .price_ticks = 50_000_000_000,
        .fee_atoms = 20,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(32, .{ .identity = 119, .payload = .{ .oms_execution_report = .{
        .report_id = 119,
        .order_id = flatten_sell.order_id,
        .revision = 1,
        .status = .filled,
        .cumulative_quantity = 40,
        .remaining_quantity = 0,
    } } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(33, .{ .identity = 117, .payload = .{ .lifecycle_progress = .{
        .operation_identity = 10,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 0,
    } } }));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);

    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(11, 16, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(34, .{ .identity = 120, .payload = .{ .safety_gate_change = .{
        .gate_identity = margin_kill_gate_identity,
        .target_identity = 1,
        .kind = .latched,
        .reason = .margin_kill,
        .open = false,
    } } }));
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expect(run.shard.operational_state.mayReduceOnly());
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.apply(lifecycleCommand(12, 17, .enable_trading)));
    try std.testing.expectError(error.UnknownLatchIdentity, run.shard.apply(resolveLatchCommand(13, 17, 999)));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(13, 17, margin_kill_gate_identity));
    try std.testing.expectEqual(operational.OperationalMode.ready, run.shard.operational_state.mode);
    try std.testing.expect(!run.shard.operational_state.trading_authorized);
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(14, 18, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());

    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "venue facts and replay use apply without replay send capability" {
    comptime std.debug.assert(!@hasDecl(ReplayTradingShard, "trySend"));
    var live = try startScenario();
    try applyHealthyPrelude(&live);
    const command = (try live.shard.apply(atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = fixture.timer(happy_order_quantity) },
    }))).order_command.?;
    const facts = try happyPathVenueFacts(command);
    for (facts) |event|
        try std.testing.expect((try live.shard.apply(event)).order_command == null);

    var replay_shard: ReplayTradingShard = .{};
    try applyGenesisReplay(&replay_shard);
    try applyHealthyPreludeReplay(&replay_shard);
    _ = try replay_shard.apply(atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = fixture.timer(happy_order_quantity) },
    }));
    for (facts) |event| _ = try replay_shard.apply(event);
    try std.testing.expectEqualSlices(u8, &live.shard.canonicalStateDigest(), &replay_shard.canonicalStateDigest());
}

test "shared canonical adapter facts enter the TradingShard state seam" {
    const Fixture = struct {
        fn record(sequence: u64, event: canonical.Payload) engine.CanonicalEvent {
            return .{ .venue = .{ .envelope = .{
                .event_type = @intFromEnum(canonical.eventType(event)),
                .schema_version = canonical.schema_version,
                .identity = .{ .stream = 2, .sequence = sequence },
                .source_fact_identity = sequence,
                .scope = .account,
                .venue = 1,
                .exchange_account = 2,
                .source_stream = 2,
                .source_sequence = sequence,
                .adapter_session = 4,
                .times = .{ .receive_utc_ns = sequence, .monotonic_ns = sequence, .audit_utc_ns = sequence },
                .raw_evidence = .{ .stream = 2, .sequence = sequence, .digest = @splat(0) },
            }, .event = event } };
        }
    };

    var run = try startScenario();
    try applyHealthyPrelude(&run);
    const command = (try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = fixture.timer(happy_order_quantity) },
    }))) orelse return error.MissingOrderCommand;
    const client_order = command.client_order_id;
    const venue_order = try canonical.VenueOrderRef.init(1, "shared-order-1");
    const instrument = run.shard.instrument_identity;
    const quantity = canonical.InstrumentQuantity{ .instrument = instrument, .rules_version = run.shard.instrument_rules_version, .lots = happy_order_quantity };
    const price = canonical.InstrumentPrice{ .instrument = instrument, .rules_version = run.shard.instrument_rules_version, .ticks = order_limit_price };

    try std.testing.expect((try engine.applyStable(&run.shard, &run.decision_journal, Fixture.record(1, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .submitted } }))) == null);
    const accepted_report: canonical.ExecutionReport = .{
        .identity = 2,
        .order = command.order_id,
        .client_order_id = client_order,
        .venue_order = venue_order,
        .instrument = instrument,
        .exchange_account = 2,
        .revision = 1,
        .side = .buy,
        .order_type = .limit,
        .time_in_force = .good_til_canceled,
        .venue_reduce_only = false,
        .position_mode_net = true,
        .margin_mode_isolated = true,
        .leverage = .{ .coefficient = 50, .scale = 0 },
        .status = .accepted,
        .reject_reason = .other_venue_reject,
        .portfolio_reduce_only = false,
        .position_side = .long,
        .original_quantity = quantity,
        .cumulative_quantity = .{ .instrument = instrument, .rules_version = run.shard.instrument_rules_version, .lots = 0 },
        .remaining_quantity = quantity,
        .limit_price = price,
        .average_fill_price = price,
        .venue_create_time_utc_ns = 98,
        .venue_update_time_utc_ns = 99,
    };
    try std.testing.expect((try engine.applyStable(&run.shard, &run.decision_journal, Fixture.record(2, .{ .execution_report = accepted_report }))) == null);
    const accepted_digest = run.shard.canonicalStateDigest();
    var conflicting_report = accepted_report;
    conflicting_report.venue_update_time_utc_ns = 101;
    try std.testing.expectError(error.ConflictingCanonicalIdentity, run.shard.apply(Fixture.record(2, .{ .execution_report = conflicting_report })));
    try std.testing.expectEqualSlices(u8, &accepted_digest, &run.shard.canonicalStateDigest());
    try std.testing.expect((try run.shard.apply(Fixture.record(3, .{ .execution_report = accepted_report }))).facts.len == 0);
    try std.testing.expectEqualSlices(u8, &accepted_digest, &run.shard.canonicalStateDigest());
    try std.testing.expectError(error.ConflictingReportIdentity, run.shard.apply(Fixture.record(3, .{ .execution_report = conflicting_report })));
    try std.testing.expectEqualSlices(u8, &accepted_digest, &run.shard.canonicalStateDigest());
    var incomplete_book = Fixture.record(21, .{ .l2_book_snapshot = .{
        .instrument = instrument,
        .sequence = 21,
        .best_bid = price,
        .best_ask = price,
    } });
    incomplete_book.venue.envelope.scope = .instrument;
    incomplete_book.venue.envelope.instrument = instrument;
    try std.testing.expectError(error.IncompleteL2Book, run.shard.apply(incomplete_book));
    try std.testing.expectEqualSlices(u8, &accepted_digest, &run.shard.canonicalStateDigest());
    var unsupported_schema = Fixture.record(20, .{ .reconciliation_started = 20 });
    unsupported_schema.venue.envelope.schema_version = canonical.schema_version + 1;
    try std.testing.expectError(error.UnsupportedSchema, run.shard.apply(unsupported_schema));
    try std.testing.expectEqualSlices(u8, &accepted_digest, &run.shard.canonicalStateDigest());
    const canonical_fill: canonical.Fill = .{
        .identity = 3,
        .order = command.order_id,
        .client_order_id = client_order,
        .venue_order = venue_order,
        .venue_trade = try canonical.VenueTradeRef.init(1, "shared-trade-1"),
        .instrument = instrument,
        .exchange_account = 2,
        .side = .buy,
        .quantity = quantity,
        .price = price,
        .fee = .{ .asset = settlement_asset, .atoms = 12 },
        .rebate = .{ .asset = settlement_asset, .atoms = 2 },
        .realized_pnl = .{ .asset = settlement_asset, .atoms = 7 },
        .liquidity = .maker,
        .venue_fill_time_utc_ns = 100,
    };
    var missing_fee = canonical_fill;
    missing_fee.fee = null;
    var rejected_shard = run.shard;
    const before_rejection = rejected_shard.economicSummary();
    try std.testing.expectError(error.MissingFillFee, rejected_shard.apply(Fixture.record(22, .{ .fill = missing_fee })));
    try std.testing.expect(rejected_shard.oms.recovery_only);
    try std.testing.expectEqual(@as(u64, 1), rejected_shard.economic_fault_count);
    try std.testing.expectEqual(canonical.EconomicFaultReason.missing_amount, rejected_shard.economic_fault_reason);
    try std.testing.expect(std.meta.eql(before_rejection, rejected_shard.economicSummary()));
    try std.testing.expectEqualSlices(u8, &accepted_digest, &run.shard.canonicalStateDigest());
    std.debug.print("core_input_rejection: l2=IncompleteL2Book fill_fee=MissingFillFee\n", .{});
    var overfill = run.shard;
    var partial_fill = canonical_fill;
    partial_fill.identity = 4;
    partial_fill.quantity.lots = 50;
    _ = try overfill.apply(Fixture.record(3, .{ .fill = partial_fill }));
    var excessive_fill = partial_fill;
    excessive_fill.identity = 5;
    excessive_fill.quantity.lots = 51;
    try std.testing.expectError(error.InvalidFill, overfill.apply(Fixture.record(4, .{ .fill = excessive_fill })));

    var filled_report = accepted_report;
    filled_report.identity = 6;
    filled_report.status = .filled;
    filled_report.cumulative_quantity.lots = happy_order_quantity;
    filled_report.remaining_quantity.lots = 0;
    try std.testing.expect((try engine.applyStable(&run.shard, &run.decision_journal, Fixture.record(3, .{ .execution_report = filled_report }))) == null);
    try std.testing.expectEqual(oms_module.OrderState.filled, run.shard.oms.orderById(command.order_id).?.state);

    try std.testing.expect((try engine.applyStable(&run.shard, &run.decision_journal, Fixture.record(4, .{ .fill = canonical_fill }))) == null);
    const fill_digest = run.shard.canonicalStateDigest();
    try std.testing.expect((try run.shard.apply(Fixture.record(5, .{ .fill = canonical_fill }))).facts.len == 0);
    try std.testing.expectEqualSlices(u8, &fill_digest, &run.shard.canonicalStateDigest());
    var conflicting_fill = canonical_fill;
    conflicting_fill.venue_fill_time_utc_ns = 101;
    var conflicting_shard = run.shard;
    const before_conflict = conflicting_shard.economicSummary();
    try std.testing.expectError(error.ConflictingFillIdentity, conflicting_shard.apply(Fixture.record(5, .{ .fill = conflicting_fill })));
    try std.testing.expect(conflicting_shard.oms.recovery_only);
    try std.testing.expectEqual(@as(u64, 1), conflicting_shard.economic_fault_count);
    try std.testing.expect(std.meta.eql(before_conflict, conflicting_shard.economicSummary()));
    try std.testing.expectEqualSlices(u8, &fill_digest, &run.shard.canonicalStateDigest());
    const normalized_report = run.shard.oms.report_history[run.shard.oms.report_history_count - 1];
    try std.testing.expectEqual(command.order_id, normalized_report.order_id);
    try std.testing.expectEqual(oms_module.ReportStatus.filled, normalized_report.status);
    const economics = run.shard.economicSummary();
    try std.testing.expectEqual(@as(i64, happy_order_quantity), economics.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, 12), economics.portfolio.fee_atoms);
    try std.testing.expectEqual(@as(i64, 2), economics.portfolio.rebate_atoms);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
    var snapshot_storage: [256 * 1024]u8 = undefined;
    const snapshot = try run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence, &snapshot_storage);
    const restored = try TradingShard.restoreSnapshot(snapshot);
    try std.testing.expectEqualSlices(u8, &run.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
}

const PrivateFactPermutation = struct {
    name: []const u8,
    /// Distinct Fill postings stay ordered: their weighted-cost accounting is
    /// itself authoritative, so only report arrival positions may move.
    order: [6]u8,
};

const private_fact_permutations = [_]PrivateFactPermutation{
    .{ .name = "report-fill-report-fill-report", .order = .{ 0, 1, 2, 3, 4, 5 } },
    .{ .name = "partial-report-before-first-fill", .order = .{ 0, 1, 3, 2, 4, 5 } },
    .{ .name = "terminal-report-before-second-fill", .order = .{ 0, 1, 2, 3, 5, 4 } },
    .{ .name = "both-reports-before-second-fill", .order = .{ 0, 1, 3, 2, 5, 4 } },
};

fn stampPrivateFact(event: *CanonicalEvent, sequence: u64) void {
    event.venue.envelope.identity.sequence = sequence;
    event.venue.envelope.source_sequence = sequence;
    event.venue.envelope.raw_evidence.sequence = sequence;
}

fn privateFactsWithSplit(command: engine.OrderCommand, first_fill_quantity: i128) ![6]CanonicalEvent {
    if (first_fill_quantity <= 0 or first_fill_quantity >= happy_order_quantity) return error.InvalidFillSplit;
    var facts = try happyPathVenueFacts(command);
    const second_fill_quantity = happy_order_quantity - first_fill_quantity;
    facts[2].venue.event.fill.quantity.lots = first_fill_quantity;
    facts[3].venue.event.execution_report.cumulative_quantity.lots = first_fill_quantity;
    facts[3].venue.event.execution_report.remaining_quantity.lots = second_fill_quantity;
    facts[4].venue.event.fill.quantity.lots = second_fill_quantity;
    return facts;
}

fn privateFactPermutationRun(permutation: PrivateFactPermutation, first_fill_quantity: i128) !LiveRun {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    const command = (try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = fixture.timer(happy_order_quantity) },
    }))) orelse return error.MissingOrderCommand;
    const facts = try privateFactsWithSplit(command, first_fill_quantity);
    for (permutation.order, 0..) |index, arrival| {
        var event = facts[index];
        stampPrivateFact(&event, 200 + arrival);
        if (try applyLive(&run.shard, &run.decision_journal, event) != null) return error.UnexpectedOrderCommand;
    }
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
    return run;
}

fn privateFactArrival(permutation: PrivateFactPermutation, wanted: u8) u64 {
    for (permutation.order, 0..) |index, arrival|
        if (index == wanted) return 200 + arrival;
    unreachable;
}

test "legal private fact permutations preserve semantic authority while retaining audit order" {
    comptime std.debug.assert(!@hasDecl(ReplayTradingShard, "trySend"));
    const baseline = try privateFactPermutationRun(private_fact_permutations[0], 40);
    const baseline_semantic = baseline.shard.semanticAuthorityDigest();
    const baseline_canonical = baseline.shard.canonicalStateDigest();

    for (private_fact_permutations, 0..) |permutation, row| {
        var run = try privateFactPermutationRun(permutation, 40);
        const semantic = run.shard.semanticAuthorityDigest();
        try std.testing.expectEqualSlices(u8, &baseline_semantic, &semantic);
        if (row != 0) try std.testing.expect(!std.mem.eql(u8, &baseline_canonical, &run.shard.canonicalStateDigest()));
        try std.testing.expectEqual(@as(i64, happy_order_quantity), try run.shard.economic_projection.appliedCanonicalFillQuantity(1));

        const before_conflict = run.shard.canonicalStateDigest();
        const command = run.shard.oms.command_history[0];
        var conflicting = (try privateFactsWithSplit(command, 40))[2];
        stampPrivateFact(&conflicting, privateFactArrival(permutation, 2));
        conflicting.venue.event.fill.price.ticks += 1;
        try std.testing.expectError(error.ConflictingFillIdentity, run.shard.apply(conflicting));
        try std.testing.expectEqualSlices(u8, &before_conflict, &run.shard.canonicalStateDigest());
    }
}

test "fixed-seed private fact fuzz retains the table-driven permutation invariant" {
    const seed_start: u64 = 0x06_2026_0922;
    const max_cases: u8 = 32;
    const max_events: u8 = 6;
    var seed = seed_start;
    for (0..max_cases) |case_index| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const split: i128 = 1 + @as(i128, @intCast(seed % (happy_order_quantity - 1)));
        const permutation_index: usize = 1 + @as(usize, @intCast((seed >> 32) % (private_fact_permutations.len - 1)));
        const baseline = privateFactPermutationRun(private_fact_permutations[0], split) catch |err| {
            std.debug.print("private-fact-fuzz seed={d} case={d} split={d} events={d} baseline\n", .{ seed_start, case_index, split, max_events });
            return err;
        };
        const permuted = privateFactPermutationRun(private_fact_permutations[permutation_index], split) catch |err| {
            std.debug.print("private-fact-fuzz seed={d} case={d} split={d} events={d} order={s}\n", .{ seed_start, case_index, split, max_events, private_fact_permutations[permutation_index].name });
            return err;
        };
        if (!std.mem.eql(u8, &baseline.shard.semanticAuthorityDigest(), &permuted.shard.semanticAuthorityDigest())) {
            std.debug.print("private-fact-fuzz seed={d} case={d} split={d} events={d} order={s}\n", .{ seed_start, case_index, split, max_events, private_fact_permutations[permutation_index].name });
            return error.SemanticPermutationMismatch;
        }
        try std.testing.expect(!std.mem.eql(u8, &baseline.shard.canonicalStateDigest(), &permuted.shard.canonicalStateDigest()));
        try std.testing.expectEqual(@as(i64, happy_order_quantity), try permuted.shard.economic_projection.appliedCanonicalFillQuantity(1));
    }
}

fn canceledLateFillRun(order: [6]u8) !LiveRun {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    const command = (try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = fixture.timer(happy_order_quantity) },
    }))) orelse return error.MissingOrderCommand;
    const facts = try privateFactsWithSplit(command, 40);
    var canceled = facts[5];
    canceled.venue.event.execution_report.identity = 3;
    canceled.venue.event.execution_report.revision = 3;
    canceled.venue.event.execution_report.status = .canceled;
    canceled.venue.event.execution_report.cumulative_quantity.lots = 40;
    canceled.venue.event.execution_report.remaining_quantity.lots = 60;
    const reconciliation = fixture.canonicalAt(19, 108, .{ .order_reconciliation_result = .{
        .identity = 4,
        .complete = true,
        .status = .found_terminal,
        .order = command.order_id,
        .revision = 3,
        .cumulative_quantity = .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = 40 },
        .remaining_quantity = .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = 60 },
        .terminal_status = .canceled,
        .rules_version = command.limit_price.rules_version,
        .evidence = fixture.reconciliationEvidence(19, 108, command.order_id, command.instrument, 3),
    } });
    const events = [_]CanonicalEvent{ facts[0], facts[1], facts[3], canceled, reconciliation, facts[2] };
    for (order, 0..) |index, arrival| {
        var event = events[index];
        stampPrivateFact(&event, 300 + arrival);
        if (try applyLive(&run.shard, &run.decision_journal, event) != null) return error.UnexpectedOrderCommand;
    }
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
    return run;
}

test "cancel reconciliation accepts one late Fill without duplicate economics" {
    const before_terminal = try canceledLateFillRun(.{ 0, 1, 2, 5, 3, 4 });
    const after_terminal = try canceledLateFillRun(.{ 0, 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(oms_module.OrderState.canceled, before_terminal.shard.oms.orderById(1).?.state);
    try std.testing.expectEqual(oms_module.OrderState.canceled, after_terminal.shard.oms.orderById(1).?.state);
    try std.testing.expectEqual(@as(i64, 40), try before_terminal.shard.economic_projection.appliedCanonicalFillQuantity(1));
    try std.testing.expectEqual(@as(i64, 40), try after_terminal.shard.economic_projection.appliedCanonicalFillQuantity(1));
    try std.testing.expectEqualSlices(u8, &before_terminal.shard.semanticAuthorityDigest(), &after_terminal.shard.semanticAuthorityDigest());
    try std.testing.expect(!std.mem.eql(u8, &before_terminal.shard.canonicalStateDigest(), &after_terminal.shard.canonicalStateDigest()));
}

test "account bootstrap snapshot is normalized before stable journal replay" {
    const Envelope = struct {
        fn record(sequence: u64, event: canonical.Payload) engine.CanonicalEvent {
            return .{ .venue = .{ .envelope = .{
                .event_type = @intFromEnum(canonical.eventType(event)),
                .schema_version = canonical.schema_version,
                .identity = .{ .stream = 7, .sequence = sequence },
                .source_fact_identity = sequence,
                .scope = .account,
                .venue = 1,
                .exchange_account = 2,
                .source_stream = 7,
                .source_sequence = sequence,
                .adapter_session = 1,
                .times = .{ .receive_utc_ns = sequence, .monotonic_ns = sequence, .audit_utc_ns = sequence },
                .raw_evidence = .{ .stream = 7, .sequence = sequence, .digest = @splat(0) },
            }, .event = event } };
        }
    };

    var run = try startScenario();
    const snapshot: canonical.AccountBootstrapSnapshot = .{
        .identity = 77,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 7,
        .source_sequence = 1,
        .balance_count = 0,
        .position_count = 0,
        .margin_count = 0,
    };
    _ = try applyLive(&run.shard, &run.decision_journal, Envelope.record(1, .{ .account_bootstrap_snapshot = snapshot }));
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);

    var invalid = snapshot;
    invalid.balance_count = canonical.max_account_facts + 1;
    const before = run.shard.canonicalStateDigest();
    try std.testing.expectError(error.InvalidAccountFactCount, run.shard.apply(Envelope.record(2, .{ .account_bootstrap_snapshot = invalid })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "an existing account failure does not commit an unrelated rejected event" {
    const Envelope = struct {
        fn record(sequence: u64, event: canonical.Payload) engine.CanonicalEvent {
            return .{ .venue = .{ .envelope = .{
                .event_type = @intFromEnum(canonical.eventType(event)),
                .schema_version = canonical.schema_version,
                .identity = .{ .stream = 7, .sequence = sequence },
                .source_fact_identity = sequence,
                .scope = .account,
                .venue = 1,
                .exchange_account = 2,
                .source_stream = 7,
                .source_sequence = sequence,
                .adapter_session = 1,
                .times = .{ .receive_utc_ns = sequence, .monotonic_ns = sequence, .audit_utc_ns = sequence },
                .raw_evidence = .{ .stream = 7, .sequence = sequence, .digest = @splat(0) },
            }, .event = event } };
        }
    };

    var run = try startScenario();
    const snapshot: canonical.AccountBootstrapSnapshot = .{
        .identity = 77,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 7,
        .source_sequence = 1,
        .balance_count = 0,
        .position_count = 0,
        .margin_count = 0,
    };
    _ = try applyLive(&run.shard, &run.decision_journal, Envelope.record(1, .{ .account_bootstrap_snapshot = snapshot }));
    const amount: canonical.AssetAmount = .{ .asset = settlement_asset, .atoms = 0 };
    const balance: canonical.AccountBalance = .{ .asset = settlement_asset, .total = amount, .available = amount, .held = amount };
    const gap: canonical.AccountObservation = .{
        .identity = 2,
        .exchange_account = 2,
        .bootstrap = snapshot.identity,
        .source_stream = snapshot.source_stream,
        .source_sequence = 3,
        .value = .{ .balance = .{ .asset = settlement_asset, .value = balance } },
    };
    try std.testing.expectError(error.SourceSequenceGap, applyLive(&run.shard, &run.decision_journal, Envelope.record(2, .{ .account_observed = gap })));
    try std.testing.expect(run.shard.integritySnapshot().account_failure == .sequence_gap);
    const failed_digest = run.shard.canonicalStateDigest();

    const unrelated = fixture.canonicalAt(13, 99, .{ .reference_price = .{
        .instrument = 999,
        .kind = .mark,
        .price = .{ .instrument = 999, .rules_version = 1, .ticks = 50_000_000 },
    } });
    try std.testing.expectError(error.MissingInstrumentDefinition, applyLive(&run.shard, &run.decision_journal, unrelated));
    try std.testing.expectEqualSlices(u8, &failed_digest, &run.shard.canonicalStateDigest());
    try run.decision_journal.seal();
    const replay_digest = try fixture.replayDigest(run);
    try std.testing.expectEqualSlices(u8, &run.shard.canonicalStateDigest(), &replay_digest);
}

test "canonical not-sent is terminal without entering the legacy shard schema" {
    const Fixture = struct {
        fn record(command: u64) engine.CanonicalEvent {
            const event: canonical.Payload = .{ .order_dispatch_result = .{ .command = command, .state = .not_sent, .reason = .capability_unsupported } };
            return .{ .venue = .{ .envelope = .{
                .event_type = @intFromEnum(canonical.eventType(event)),
                .schema_version = canonical.schema_version,
                .identity = .{ .stream = 2, .sequence = 1 },
                .source_fact_identity = 1,
                .scope = .account,
                .venue = 1,
                .exchange_account = 2,
                .source_stream = 2,
                .source_sequence = 1,
                .adapter_session = 4,
                .times = .{ .monotonic_ns = 1 },
                .raw_evidence = .{ .stream = 2, .sequence = 1, .digest = @splat(0) },
            }, .event = event } };
        }
    };
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    const command = (try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{ .identity = 1, .payload = .{ .timer = fixture.timer(happy_order_quantity) } }))) orelse return error.MissingOrderCommand;
    _ = try run.shard.apply(Fixture.record(command.command_id));
    try std.testing.expectEqual(oms_module.OrderState.rejected, run.shard.oms.orders[0].state);
    try std.testing.expectEqual(oms_module.OrderState.rejected, run.shard.oms.orders[0].state);
}

test "bounded multi instrument OMS closes lifecycle and partial policy" {
    var run = try startScenario();
    const native_amend_capability = atGroup(10, .{ .identity = 100, .payload = .{ .capability_profile_activation = .{
        .exchange_account = 2,
        .instrument = spot_instrument,
        .venue = 1,
        .environment = .simulation,
        .product = .spot,
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 1,
        .max_dispatch_age_ns = std.time.ns_per_s,
        .supports_place = true,
        .supports_cancel = true,
        .supports_native_amend = true,
        .supports_venue_reduce_only = false,
        .supports_post_only = false,
        .supports_market_protection = false,
    } } });
    _ = try run.shard.apply(native_amend_capability);
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 10, .policy = .independent, .count = 2 };
    group.members[0] = .{ .intent_sequence = 10, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000), .reservation = fixtureReservation(5_000_000) };
    group.members[1] = .{ .intent_sequence = 11, .operation = .place, .instrument = swap_instrument, .quantity = 20, .limit_price = fixtureOmsPrice(swap_instrument, 50_100_000), .reservation = fixtureReservation(1_000_000) };
    const placed = try run.shard.apply(atGroup(12, .{ .identity = 10, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 2), placed.oms_commands.len);
    try std.testing.expect(placed.oms_commands[0].instrument != placed.oms_commands[1].instrument);

    var dispatch: oms_module.DispatchBatch = .{ .count = 2 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .submitted };
    dispatch.items[1] = .{ .command_id = placed.oms_commands[1].command_id, .state = .unknown };
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    try std.testing.expectEqual(oms_module.OrderState.unknown, run.shard.oms.orders[1].state);
    try std.testing.expect(run.shard.oms.orders[1].reservation_active);
    _ = try run.shard.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{
        .reconciliation_id = 1,
        .order_id = 2,
        .status = .found_live,
        .revision = 1,
        .cumulative_quantity = 0,
        .remaining_quantity = 20,
    } } }));

    _ = try run.shard.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_execution_report = .{
        .report_id = 1,
        .order_id = 1,
        .revision = 1,
        .status = .accepted,
        .cumulative_quantity = 0,
        .remaining_quantity = 100,
    } } }));
    var amend: oms_module.IntentGroup = .{ .first_intent_sequence = 12, .count = 1 };
    amend.members[0] = .{ .intent_sequence = 12, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_900_000), .reservation = fixtureReservation(4_000_000) };
    const amended = try run.shard.apply(atGroup(16, .{ .identity = 12, .payload = .{ .oms_intent_group = amend } }));
    try std.testing.expectEqual(oms_module.Operation.amend, amended.oms_commands[0].operation);
    try std.testing.expectEqual(@as(u32, 2), run.shard.oms.orders[0].revision);
    try std.testing.expectEqual(placed.oms_commands[0].reservation.atoms, run.shard.oms.orders[0].reservation.atoms);
    const duplicate_amend = try run.shard.apply(atGroup(17, .{ .identity = 13, .payload = .{ .oms_intent_group = amend } }));
    try std.testing.expectEqual(@as(usize, 0), duplicate_amend.oms_commands.len);
    _ = try run.shard.apply(atGroup(18, .{ .identity = 3, .payload = .{ .oms_execution_report = .{ .report_id = 3, .order_id = 1, .revision = 1, .status = .partially_filled, .cumulative_quantity = 20, .remaining_quantity = 80 } } }));
    try std.testing.expectEqual(oms_module.OrderState.pending_amend, run.shard.oms.orders[0].state);
    _ = try run.shard.apply(atGroup(19, .{ .identity = 4, .payload = .{ .oms_execution_report = .{ .report_id = 4, .order_id = 1, .revision = 2, .status = .rejected, .cumulative_quantity = 20, .remaining_quantity = 80 } } }));
    try std.testing.expectEqual(oms_module.OrderState.partially_filled, run.shard.oms.orders[0].state);
    try std.testing.expectEqual(@as(i64, 100), run.shard.oms.orders[0].quantity);
    try std.testing.expectEqual(@as(i128, 41), run.shard.oms.orders[0].reservation.atoms);

    var cancel: oms_module.IntentGroup = .{ .first_intent_sequence = 13, .count = 1 };
    cancel.members[0] = .{ .intent_sequence = 13, .operation = .cancel, .instrument = swap_instrument, .target_order_id = 2, .expected_revision = 1 };
    const canceled = try run.shard.apply(atGroup(20, .{ .identity = 13, .payload = .{ .oms_intent_group = cancel } }));
    try std.testing.expectEqual(oms_module.Operation.cancel, canceled.oms_commands[0].operation);
    _ = try run.shard.apply(atGroup(21, .{ .identity = 2, .payload = .{ .oms_execution_report = .{
        .report_id = 2,
        .order_id = 2,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = 0,
        .remaining_quantity = 20,
    } } }));
    const digest = run.shard.canonicalStateDigest();
    var replayed: ReplayTradingShard = .{};
    try applyGenesisReplay(&replayed);
    _ = try replayed.apply(native_amend_capability);
    _ = try replayed.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    _ = try replayed.apply(atGroup(12, .{ .identity = 10, .payload = .{ .oms_intent_group = group } }));
    _ = try replayed.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    _ = try replayed.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 2, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 20 } } }));
    _ = try replayed.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    _ = try replayed.apply(atGroup(16, .{ .identity = 12, .payload = .{ .oms_intent_group = amend } }));
    _ = try replayed.apply(atGroup(18, .{ .identity = 3, .payload = .{ .oms_execution_report = .{ .report_id = 3, .order_id = 1, .revision = 1, .status = .partially_filled, .cumulative_quantity = 20, .remaining_quantity = 80 } } }));
    _ = try replayed.apply(atGroup(19, .{ .identity = 4, .payload = .{ .oms_execution_report = .{ .report_id = 4, .order_id = 1, .revision = 2, .status = .rejected, .cumulative_quantity = 20, .remaining_quantity = 80 } } }));
    _ = try replayed.apply(atGroup(20, .{ .identity = 13, .payload = .{ .oms_intent_group = cancel } }));
    _ = try replayed.apply(atGroup(21, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 2, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 20 } } }));
    try std.testing.expectEqualSlices(u8, &digest, &replayed.canonicalStateDigest());
}

test "SPOT and linear instruments close economics and replay independently" {
    var prefix = try startScenario();
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 200, .policy = .independent, .count = 2 };
    group.members[0] = .{ .intent_sequence = 200, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 30_000_000) };
    group.members[1] = .{ .intent_sequence = 201, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    const place = atGroup(12, .{ .identity = 200, .payload = .{ .oms_intent_group = group } });
    _ = try applyLive(&prefix.shard, &prefix.decision_journal, place);
    const commands = prefix.shard.oms.emitted();
    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqual(spot_instrument, commands[0].instrument);
    try std.testing.expectEqual(swap_instrument, commands[1].instrument);
    try std.testing.expect(commands[0].reservation.atoms != commands[1].reservation.atoms);

    try prefix.decision_journal.seal();
    var snapshot_storage: [64 * 1024]u8 = undefined;
    const snapshot = try prefix.shard.snapshot(&prefix.decision_journal, prefix.decision_journal.last_sequence, &snapshot_storage);
    var forged = prefix.shard;
    forged.oms.command_history[0].risk_decision_identity = forged.oms.command_history[0].reservation_identity;
    var forged_storage: [64 * 1024]u8 = undefined;
    const forged_snapshot = try forged.snapshot(&prefix.decision_journal, prefix.decision_journal.last_sequence, &forged_storage);
    try std.testing.expectError(error.InvalidSnapshotState, TradingShard.restoreSnapshot(forged_snapshot));
    const tail_events = [_]CanonicalEvent{
        atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .partially_filled, .cumulative_quantity = 40, .remaining_quantity = 60 } } }),
        atGroup(14, .{ .identity = 1, .payload = .{ .economic_fill = .{ .fill_id = 1, .order_id = 1, .quantity = 40, .price_ticks = 30_000_000 } } }),
        atGroup(15, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 100, .remaining_quantity = 0 } } }),
        atGroup(16, .{ .identity = 2, .payload = .{ .economic_fill = .{ .fill_id = 2, .order_id = 1, .quantity = 60, .price_ticks = 30_000_000 } } }),
        atGroup(17, .{ .identity = 3, .payload = .{ .oms_execution_report = .{ .report_id = 3, .order_id = 2, .revision = 1, .status = .filled, .cumulative_quantity = 10, .remaining_quantity = 0 } } }),
        atGroup(18, .{ .identity = 3, .payload = .{ .economic_fill = .{ .fill_id = 3, .order_id = 2, .quantity = 10, .price_ticks = 50_000_000 } } }),
        atGroup(19, .{ .identity = 5, .payload = .{ .mark_price = .{ .instrument = spot_instrument, .price_atoms = 40_000_000 } } }),
        atGroup(20, .{ .identity = 6, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 60_000_000 } } }),
    };

    var live = prefix.shard;
    var tail = engine.journal.Journal.initAt(prefix.decision_journal.last_sequence + 1);
    for (tail_events) |event| _ = try engine.applyStable(&live, &tail, event);
    try tail.seal();
    try std.testing.expectEqual(oms_module.OrderState.filled, live.oms.orders[0].state);
    try std.testing.expectEqual(oms_module.OrderState.filled, live.oms.orders[1].state);
    try std.testing.expectEqual(@as(i64, 100), live.economicSummary().portfolio.spot.quantity);
    try std.testing.expectEqual(@as(i64, 10), live.economicSummary().portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, 10_010), live.economicSummary().portfolio.unrealized_pnl_atoms);

    var replayed: ReplayTradingShard = .{};
    try applyGenesisReplay(&replayed);
    _ = try replayed.apply(place);
    for (tail_events) |event| _ = try replayed.apply(event);
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &replayed.canonicalStateDigest());
    const recovered = try TradingShard.restore(snapshot, tail.bytes());
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());

    const before_mismatch = live.canonicalStateDigest();
    const economics_before_mismatch = live.economicSummary();
    const wrong_fill = fixture.canonicalAt(21, 500, .{ .fill = .{
        .identity = 500,
        .order = 1,
        .client_order_id = try canonical.ClientOrderId.init("spot-order"),
        .venue_order = try canonical.VenueOrderRef.init(1, "spot-venue-order"),
        .venue_trade = try canonical.VenueTradeRef.init(1, "wrong-swap-fill"),
        .instrument = swap_instrument,
        .exchange_account = 2,
        .side = .buy,
        .quantity = .{ .instrument = swap_instrument, .rules_version = 1, .lots = 1 },
        .price = .{ .instrument = swap_instrument, .rules_version = 1, .ticks = 60_000_000 },
        .liquidity = .taker,
    } });
    try std.testing.expectError(error.CanonicalScopeMismatch, live.apply(wrong_fill));
    try std.testing.expectEqualDeep(economics_before_mismatch, live.economicSummary());
    try std.testing.expectEqual(@as(u64, 1), live.economic_fault_count);
    try std.testing.expectEqual(canonical.EconomicFaultReason.invalid_economic_fact, live.economic_fault_reason);
    try std.testing.expect(live.oms.recovery_only);
    try std.testing.expect(!std.mem.eql(u8, &before_mismatch, &live.canonicalStateDigest()));
}

test "OMS outbox crosses the sole Gateway and SimulatedVenue seam" {
    var live = try startScenario();
    const capability = atGroup(12, .{ .identity = 219, .payload = .{ .capability_profile_activation = .{
        .exchange_account = 2,
        .instrument = swap_instrument,
        .venue = 1,
        .environment = .simulation,
        .product = .isolated_linear_usdt,
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 1,
        .max_dispatch_age_ns = std.time.ns_per_s,
        .supports_place = true,
        .supports_cancel = true,
        .supports_native_amend = false,
        .supports_venue_reduce_only = false,
        .supports_post_only = false,
        .supports_market_protection = false,
    } } });
    _ = try live.shard.apply(capability);
    var account_bootstrap = fixture.canonicalAt(12, 1, .{ .account_bootstrap_snapshot = .{
        .identity = 1,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 2,
        .source_sequence = 1,
        .balance_count = 0,
        .position_count = 0,
        .margin_count = 0,
    } });
    account_bootstrap.venue.envelope.identity.stream = 2;
    account_bootstrap.venue.event.account_bootstrap_snapshot.balance_count = 1;
    account_bootstrap.venue.event.account_bootstrap_snapshot.balances[0] = .{
        .asset = settlement_asset,
        .total = .{ .asset = settlement_asset, .atoms = 25_000_000_000 },
        .available = .{ .asset = settlement_asset, .atoms = 25_000_000_000 },
        .held = .{ .asset = settlement_asset, .atoms = 0 },
        .cash_balance = .{ .asset = settlement_asset, .atoms = 25_000_000_000 },
        .liability = .{ .asset = settlement_asset, .atoms = 0 },
        .isolated_liability = .{ .asset = settlement_asset, .atoms = 0 },
        .cross_liability = .{ .asset = settlement_asset, .atoms = 0 },
    };
    account_bootstrap.venue.event.account_bootstrap_snapshot.margin_count = 1;
    account_bootstrap.venue.event.account_bootstrap_snapshot.margins[0] = .{
        .instrument = swap_instrument,
        .amount = .{ .asset = settlement_asset, .atoms = 25_000_000_000 },
        .initial_margin = .{ .asset = settlement_asset, .atoms = 0 },
        .maintenance_margin = .{ .asset = settlement_asset, .atoms = 0 },
        .isolated_equity = .{ .asset = settlement_asset, .atoms = 25_000_000_000 },
    };
    account_bootstrap.venue.envelope.source_stream = 2;
    account_bootstrap.venue.envelope.raw_evidence.stream = 2;
    _ = try live.shard.apply(account_bootstrap);
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 220, .count = 1 };
    group.members[0] = .{ .intent_sequence = 220, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    const place = atGroup(12, .{ .identity = 220, .payload = .{ .oms_intent_group = group } });
    const limited = try std.testing.allocator.create(TradingShard);
    defer std.testing.allocator.destroy(limited);
    for ([_]bool{ true, false }) |limit_quantity| {
        limited.* = live.shard;
        var definition = limited.activatedAssets().get(settlement_asset).?.definition;
        definition.version += 1;
        if (limit_quantity) definition.max_quantity_lots = 9 else definition.max_price_ticks = 49_999_999;
        _ = try limited.apply(atGroup(12, .{ .identity = 218, .payload = .{ .asset_definition_activated = definition } }));
        const before_range_failure = limited.economicSummary();
        try std.testing.expectError(error.AssetAmountOutOfRange, limited.apply(place));
        try std.testing.expectEqual(@as(usize, 0), limited.oms.emitted().len);
        try std.testing.expectEqual(@as(usize, 0), limited.oms.order_count);
        try std.testing.expectEqualDeep(before_range_failure, limited.economicSummary());
        try std.testing.expectError(error.AssetAmountOutOfRange, limited.apply(atGroup(13, .{ .identity = 221, .payload = .{ .venue_forced_execution = .{ .execution_id = 221, .side = .buy, .quantity = 10, .price_ticks = 50_000_000 } } })));
        try std.testing.expectEqualDeep(before_range_failure, limited.economicSummary());
    }
    const placed = try live.shard.apply(place);
    try std.testing.expectEqual(@as(usize, 1), placed.oms_commands.len);
    const proved = placed.oms_commands[0];
    for ([_]bool{ true, false }) |limit_quantity| {
        limited.* = live.shard;
        var definition = limited.activatedAssets().get(settlement_asset).?.definition;
        definition.version += 1;
        if (limit_quantity) definition.max_quantity_lots = 9 else definition.max_price_ticks = 49_999_999;
        _ = try limited.apply(atGroup(12, .{ .identity = 218, .payload = .{ .asset_definition_activated = definition } }));
        const before_range_failure = limited.economicSummary();
        try std.testing.expectError(error.AssetAmountOutOfRange, limited.apply(atGroup(13, .{ .identity = 221, .payload = .{ .economic_fill = .{ .fill_id = 221, .order_id = proved.order_id, .quantity = 10, .price_ticks = 50_000_000 } } })));
        try std.testing.expectEqualDeep(before_range_failure, limited.economicSummary());
    }
    try std.testing.expect(proved.risk_decision_identity != proved.reservation_identity);
    try std.testing.expectEqual(shard_event.EventKind.risk_accepted, live.shard.trace.events[proved.risk_decision_identity - 1].kind);
    try std.testing.expectEqual(shard_event.EventKind.risk_reservation_created, live.shard.trace.events[proved.reservation_identity - 1].kind);

    var implementation: simulated_venue.SimulatedVenue = .{};
    var adapter = implementation.adapter();
    var native_vtable = adapter.vtable.*;
    native_vtable.prepare_client_order_id = struct {
        fn prepare(_: *anyopaque, namespace: [16]u8, account: canonical.ExchangeAccountIdentity, order_id: u64, _: canonical.ClientOrderId) !canonical.ClientOrderId {
            var text: [64]u8 = undefined;
            return canonical.ClientOrderId.init(try std.fmt.bufPrint(&text, "native-{x}-{x}-{x}", .{ namespace[0], account, order_id }));
        }
    }.prepare;
    adapter.vtable = &native_vtable;
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = live.shard.activatedAssets() });
    var gateway: execution_gateway.Gateway = .{};
    try gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    const current_authority: execution_gateway.AuthorityFacts = .{
        .account = 2,
        .effective_trading_authority = true,
        .reservation_identity = placed.oms_commands[0].reservation_identity,
        .reservation = placed.oms_commands[0].reservation,
        .primary_lease_expires_at_monotonic_ns = 3 * std.time.ns_per_s,
        .fencing_token = 1,
        .exchange_position = .{ .instrument = swap_instrument, .rules_version = 1, .lots = 0 },
        .authority_barrier = 1,
    };
    try gateway.observeAuthority(current_authority);
    const fault_memory = try std.testing.allocator.create(@import("durable_store.zig").MemoryAdapter);
    defer std.testing.allocator.destroy(fault_memory);
    fault_memory.* = .init();
    var fault_gateway: execution_gateway.Gateway = .{};
    try fault_gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    var wrong_position = current_authority;
    wrong_position.exchange_position.lots = 1;
    try fault_gateway.observeAuthority(wrong_position);
    try fault_gateway.bootstrapDurableDispatch(fault_memory.interface(), undefined, .{ .domain = .control, .id = 78 });
    try std.testing.expectError(error.NotSent, fault_gateway.sendFromShard(&live.shard, proved.command_id, 2 * std.time.ns_per_s));
    var corrected_position = current_authority;
    corrected_position.authority_barrier = 2;
    try fault_gateway.observeAuthority(corrected_position);
    fault_memory.injectFault(.eio);
    try std.testing.expectError(error.NotSent, fault_gateway.sendFromShard(&live.shard, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 0), fault_gateway.send_attempt_count);
    const durable_memory = try std.testing.allocator.create(@import("durable_store.zig").MemoryAdapter);
    defer std.testing.allocator.destroy(durable_memory);
    durable_memory.* = .init();
    const durable_store = durable_memory.interface();
    const stream: @import("durable_store.zig").StreamIdentity = .{ .domain = .control, .id = 77 };
    try gateway.bootstrapDurableDispatch(durable_store, undefined, stream);
    const failed_config = try std.testing.allocator.create(TradingShard);
    defer std.testing.allocator.destroy(failed_config);
    failed_config.* = live.shard;
    var conflicting_asset = failed_config.activatedAssets().get(settlement_asset).?.definition;
    conflicting_asset.source_digest = @splat(0x99);
    try std.testing.expectError(error.AssetDefinitionConflict, failed_config.apply(.{ .core = .{ .identity = 400, .payload = .{ .asset_definition_activated = conflicting_asset } } }));
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(failed_config, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
    try std.testing.expectEqual(@as(u64, 1), (try durable_store.recover(undefined, stream)).committed_barrier);
    failed_config.* = live.shard;
    var tighter_asset = failed_config.activatedAssets().get(settlement_asset).?.definition;
    tighter_asset.version += 1;
    tighter_asset.max_single_atoms = 10_000_000_000;
    tighter_asset.max_balance_atoms = 10_000_000_000;
    try std.testing.expectError(error.AssetAmountOutOfRange, failed_config.apply(.{ .core = .{ .identity = 401, .payload = .{ .asset_definition_activated = tighter_asset } } }));
    try std.testing.expectEqualDeep(live.shard.activatedAssets(), failed_config.activatedAssets());
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(failed_config, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
    var paused = live.shard;
    _ = try paused.apply(lifecycleCommand(4, 3, .trading_pause));
    try std.testing.expect(!std.meta.eql(proved.authority.trading_authorization, (try paused.currentDispatchAuthorityRefs(swap_instrument)).trading_authorization));
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(&paused, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
    const lease_barrier = live.shard.risk_lease_valid_through_barrier;
    live.shard.risk_lease_valid_through_barrier = live.shard.trace.len - 1;
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(&live.shard, proved.command_id, 2 * std.time.ns_per_s));
    live.shard.risk_lease_valid_through_barrier = lease_barrier;
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(&live.shard, proved.command_id, 3 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 1), (try durable_store.recover(undefined, stream)).committed_barrier);
    try std.testing.expectEqual(.accepted, try gateway.sendFromShard(&live.shard, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 2), (try durable_store.recover(undefined, stream)).committed_barrier);
    try std.testing.expectEqual(@as(u64, 1), gateway.send_attempt_count);
    var recovered_gateway: execution_gateway.Gateway = .{};
    try recovered_gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    try recovered_gateway.attachRecoveredDurableDispatch(durable_store, undefined, stream);
    try std.testing.expect(!std.mem.eql(u8, proved.client_order_id.slice(), recovered_gateway.uncertain_dispatches[0].client_order_id.slice()));
    try std.testing.expect(std.mem.startsWith(u8, recovered_gateway.uncertain_dispatches[0].client_order_id.slice(), "native-"));
    try std.testing.expectError(error.NotSent, recovered_gateway.sendFromShard(&live.shard, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectError(error.UnreconciledDispatch, recovered_gateway.reconcileRecoveredDispatch(&live.shard, proved.command_id));
    try std.testing.expectEqual(@as(u64, 0), recovered_gateway.send_attempt_count);
    var output: [execution_gateway.max_routes]canonical.AdapterOutputBatch = undefined;
    try std.testing.expectEqual(@as(u8, 1), try gateway.drainFair(&output));
    for (output[0].slice()) |event| _ = try live.shard.apply(.{ .venue = event });
    try std.testing.expectEqual(oms_module.OrderState.filled, live.shard.oms.orders[0].state);
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(&live.shard, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 1), gateway.send_attempt_count);
    try std.testing.expectEqual(@as(i64, 10), live.shard.economicSummary().portfolio.swap.quantity);
    const reconciliation = atGroup(20, .{ .identity = 300, .payload = .{ .oms_reconciliation_result = .{
        .reconciliation_id = 300,
        .order_id = proved.order_id,
        .status = .found_terminal,
        .revision = proved.revision,
        .cumulative_quantity = 10,
        .remaining_quantity = 0,
        .terminal_state = .filled,
    } } });
    _ = try live.shard.apply(reconciliation);
    try recovered_gateway.reconcileRecoveredDispatch(&live.shard, proved.command_id);
    try recovered_gateway.reconcileRecoveredDispatch(&live.shard, proved.command_id);
    try std.testing.expectEqual(@as(u64, 3), (try durable_store.recover(undefined, stream)).committed_barrier);
    var recovered_again: execution_gateway.Gateway = .{};
    try recovered_again.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    try recovered_again.attachRecoveredDurableDispatch(durable_store, undefined, stream);
    try recovered_again.reconcileRecoveredDispatch(&live.shard, proved.command_id);
    try std.testing.expectError(error.NotSent, recovered_again.sendFromShard(&live.shard, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 0), recovered_again.send_attempt_count);

    var replayed: ReplayTradingShard = .{};
    try applyGenesisReplay(&replayed);
    _ = try replayed.apply(capability);
    _ = try replayed.apply(account_bootstrap);
    _ = try replayed.apply(place);
    for (output[0].slice()) |event| _ = try replayed.apply(.{ .venue = event });
    _ = try replayed.apply(reconciliation);
    try std.testing.expectEqualSlices(u8, &live.shard.canonicalStateDigest(), &replayed.canonicalStateDigest());
    comptime std.debug.assert(!@hasField(ReplayTradingShard, "gateway"));
    std.debug.print("core_safety_invariants: dispatch_persist=pass replay_no_send=pass reduce_only_fencing=pass\n", .{});
}

test "CancelConfirmCreate discards stale replacement after an intervening fill" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 20, .count = 1 };
    place.members[0] = .{ .intent_sequence = 20, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000), .reservation = fixtureReservation(5_000_000) };
    const placed = try run.shard.apply(atGroup(12, .{ .identity = 20, .payload = .{ .oms_intent_group = place } }));
    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .submitted };
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    _ = try run.shard.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));

    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 21, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 21, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 75, .limit_price = fixtureOmsPrice(spot_instrument, 49_800_000), .native_amend = false, .allow_cancel_confirm_create = true, .reservation = fixtureReservation(3_750_000) };
    const cancel_first = try run.shard.apply(atGroup(15, .{ .identity = 21, .payload = .{ .oms_intent_group = replace } }));
    try std.testing.expectEqual(@as(usize, 1), cancel_first.oms_commands.len);
    try std.testing.expectEqual(oms_module.Operation.cancel, cancel_first.oms_commands[0].operation);
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try std.testing.expect(run.shard.oms.orders[0].reservation_active);
    var cancel_unknown: oms_module.DispatchBatch = .{ .count = 1 };
    cancel_unknown.items[0] = .{ .command_id = cancel_first.oms_commands[0].command_id, .state = .unknown };
    _ = try run.shard.apply(atGroup(16, .{ .identity = 2, .payload = .{ .oms_dispatch_batch = cancel_unknown } }));
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    _ = try run.shard.apply(atGroup(17, .{ .identity = 2, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 2, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 25, .remaining_quantity = 75 } } }));
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    const replacement = try run.shard.apply(atGroup(18, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 25, .remaining_quantity = 75 } } }));
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 0), replacement.oms_commands.len);
    try std.testing.expect(run.shard.oms.orders[0].replacement == null);
    try std.testing.expect(!run.shard.oms.orders[0].reservation_active);
    try std.testing.expectError(error.TerminalFactConflict, run.shard.apply(atGroup(19, .{ .identity = 3, .payload = .{ .oms_execution_report = .{ .report_id = 3, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 25, .remaining_quantity = 75 } } })));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    try std.testing.expectError(error.ConflictingReportIdentity, run.shard.apply(atGroup(20, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 100, .remaining_quantity = 0 } } })));
}

test "OMS group identity is checked before new risk and conflict survives replay" {
    var run = try startScenario();
    _ = try fixture.apply(&run, atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 300, .count = 2 };
    group.members[0] = .{ .intent_sequence = 300, .strategy_instance = 1, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    group.members[1] = .{ .intent_sequence = 301, .strategy_instance = 1, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try fixture.apply(&run, atGroup(12, .{ .identity = 300, .payload = .{ .oms_intent_group = group } }));
    _ = try fixture.apply(&run, atGroup(13, .{ .identity = 301, .payload = .{ .risk_lease_granted = .{
        .lease_identity = 301,
        .version = 2,
        .amount_atoms = 1,
        .strategy_limit_atoms = 1,
        .portfolio_limit_atoms = 1,
        .exchange_account_limit_atoms = 1,
        .global_limit_atoms = 1,
    } } }));
    const before_duplicate = run.shard.canonicalStateDigest();
    const journal_sequence = run.decision_journal.last_sequence;
    try std.testing.expect((try fixture.apply(&run, atGroup(14, .{ .identity = 302, .payload = .{ .oms_intent_group = group } }))) == null);
    try std.testing.expectEqual(journal_sequence, run.decision_journal.last_sequence);
    try std.testing.expectEqualSlices(u8, &before_duplicate, &run.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);

    var changed = group;
    changed.members[1].quantity = 11;
    try std.testing.expect((try fixture.apply(&run, atGroup(15, .{ .identity = 303, .payload = .{ .oms_intent_group = changed } }))) == null);
    try std.testing.expectEqual(shard_event.EventKind.oms_intent_conflict, run.shard.trace.events[run.shard.trace.len - 1].kind);
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    var truncated = group;
    truncated.count = 1;
    try std.testing.expect((try fixture.apply(&run, atGroup(16, .{ .identity = 304, .payload = .{ .oms_intent_group = truncated } }))) == null);
    try std.testing.expectEqual(shard_event.EventKind.oms_intent_conflict, run.shard.trace.events[run.shard.trace.len - 1].kind);
    try run.decision_journal.seal();
    const digest = try fixture.assertReplayEquivalent(run);
    var snapshot_storage: [64 * 1024]u8 = undefined;
    const snapshot = try run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence, &snapshot_storage);
    var restored = (try TradingShard.restoreSnapshot(snapshot)).shard;
    try std.testing.expectEqualSlices(u8, &digest, &restored.canonicalStateDigest());
    const restored_before = restored.canonicalStateDigest();
    _ = try restored.apply(atGroup(17, .{ .identity = 305, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqualSlices(u8, &restored_before, &restored.canonicalStateDigest());
    var live_after = run.shard;
    const repeated_conflict = atGroup(18, .{ .identity = 306, .payload = .{ .oms_intent_group = changed } });
    _ = try live_after.apply(repeated_conflict);
    _ = try restored.apply(repeated_conflict);
    try std.testing.expectEqualSlices(u8, &live_after.canonicalStateDigest(), &restored.canonicalStateDigest());
}

test "partial fill keeps another PendingCancel blocking CCC" {
    var run = try startScenario();
    _ = try fixture.apply(&run, atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 310, .count = 2 };
    group.members[0] = .{ .intent_sequence = 310, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    group.members[1] = .{ .intent_sequence = 311, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try fixture.apply(&run, atGroup(12, .{ .identity = 310, .payload = .{ .oms_intent_group = group } }));
    _ = try fixture.apply(&run, atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    _ = try fixture.apply(&run, atGroup(14, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 2, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    var amend: oms_module.IntentGroup = .{ .first_intent_sequence = 312, .count = 1 };
    amend.members[0] = .{ .intent_sequence = 312, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000), .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try fixture.apply(&run, atGroup(15, .{ .identity = 312, .payload = .{ .oms_intent_group = amend } }));
    var cancel: oms_module.IntentGroup = .{ .first_intent_sequence = 313, .count = 1 };
    cancel.members[0] = .{ .intent_sequence = 313, .operation = .cancel, .instrument = swap_instrument, .target_order_id = 2, .expected_revision = 1 };
    _ = try fixture.apply(&run, atGroup(16, .{ .identity = 313, .payload = .{ .oms_intent_group = cancel } }));
    _ = try fixture.apply(&run, atGroup(17, .{ .identity = 3, .payload = .{ .oms_execution_report = .{ .report_id = 3, .order_id = 2, .revision = 1, .status = .partially_filled, .cumulative_quantity = 5, .remaining_quantity = 5 } } }));
    try std.testing.expectEqual(oms_module.OrderState.pending_cancel, run.shard.oms.orderById(2).?.state);
    try std.testing.expect(run.shard.oms.blocksNewSend());
    const closed = try fixture.apply(&run, atGroup(18, .{ .identity = 4, .payload = .{ .oms_execution_report = .{ .report_id = 4, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expect(closed == null);
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orderById(1).?.state);
    try std.testing.expect(run.shard.oms.orderById(1).?.replacement == null);
    try run.decision_journal.seal();
    _ = try fixture.assertReplayEquivalent(run);
}

test "IntentGroup batch results remain itemized" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 30, .policy = .cancel_remaining, .count = 3 };
    for (group.members[0..3], 0..) |*member, index| {
        const instrument = if (index == 1) swap_instrument else spot_instrument;
        member.* = .{ .intent_sequence = 30 + index, .operation = .place, .instrument = instrument, .quantity = 10, .limit_price = fixtureOmsPrice(instrument, 50_000_000), .reservation = fixtureReservation(500_000) };
    }
    const commands = try run.shard.apply(atGroup(12, .{ .identity = 30, .payload = .{ .oms_intent_group = group } }));
    var batch: oms_module.DispatchBatch = .{ .count = 3 };
    batch.items[0] = .{ .command_id = commands.oms_commands[0].command_id, .state = .submitted };
    batch.items[1] = .{ .command_id = commands.oms_commands[1].command_id, .state = .submitted, .definite_reject = true };
    batch.items[2] = .{ .command_id = commands.oms_commands[2].command_id, .state = .not_sent };
    const outcome = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = batch } }));
    try std.testing.expectEqual(oms_module.OrderState.pending_cancel, run.shard.oms.orders[0].state);
    try std.testing.expectEqual(oms_module.OrderState.rejected, run.shard.oms.orders[1].state);
    try std.testing.expectEqual(oms_module.OrderState.rejected, run.shard.oms.orders[2].state);
    try std.testing.expect(run.shard.oms.orders[0].reservation_active);
    try std.testing.expect(!run.shard.oms.orders[1].reservation_active);
    try std.testing.expect(!run.shard.oms.orders[2].reservation_active);
    try std.testing.expectEqual(@as(usize, 1), outcome.oms_commands.len);
    try std.testing.expectEqual(oms_module.Operation.cancel, outcome.oms_commands[0].operation);
}

test "layered risk retains unknown reservations until authoritative terminal evidence" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 40, .count = 1 };
    group.members[0] = .{ .intent_sequence = 40, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000), .reservation = fixtureReservation(1) };
    const placed = try run.shard.apply(atGroup(12, .{ .identity = 40, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(i128, 51), run.shard.oms.orders[0].reservation.atoms);
    try std.testing.expectEqual(@as(i64, 51), try run.shard.activeReservationAtoms());

    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .unknown };
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    try std.testing.expectEqual(@as(i64, 51), try run.shard.activeReservationAtoms());
    try std.testing.expectError(error.IncompleteReconciliationEvidence, run.shard.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .confirmed_absent, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 100 } } })));
    try std.testing.expectEqual(@as(i64, 51), try run.shard.activeReservationAtoms());
    _ = try run.shard.apply(atGroup(15, .{ .identity = 2, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 2, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 100, .terminal_state = .canceled } } }));
    try std.testing.expectEqual(@as(i64, 0), try run.shard.activeReservationAtoms());

    var limited = try startScenario();
    _ = try limited.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    _ = try limited.shard.apply(atGroup(12, .{ .identity = 2, .payload = .{ .risk_lease_granted = .{
        .lease_identity = 2,
        .version = 2,
        .amount_atoms = 1_000,
        .strategy_limit_atoms = 50,
        .portfolio_limit_atoms = 1_000,
        .exchange_account_limit_atoms = 1_000,
        .global_limit_atoms = 1_000,
    } } }));
    try std.testing.expectEqual(shard_event.RejectReason.strategy_limit_exceeded, (try limited.shard.apply(atGroup(12, .{ .identity = 40, .payload = .{ .oms_intent_group = group } }))).facts[0].reject_reason);
    try std.testing.expectEqual(@as(u8, 0), limited.shard.oms.order_count);
}

test "unknown OMS dispatch blocks a later place until the order is resolved" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var first: oms_module.IntentGroup = .{ .first_intent_sequence = 90, .count = 1 };
    first.members[0] = .{
        .intent_sequence = 90,
        .operation = .place,
        .instrument = spot_instrument,
        .quantity = 10,
        .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000),
    };
    const placed = try run.shard.apply(atGroup(12, .{ .identity = 90, .payload = .{ .oms_intent_group = first } }));
    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .unknown };
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));

    const before = run.shard.canonicalStateDigest();
    var next: oms_module.IntentGroup = .{ .first_intent_sequence = 91, .count = 1 };
    next.members[0] = .{
        .intent_sequence = 91,
        .operation = .place,
        .instrument = swap_instrument,
        .quantity = 10,
        .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000),
    };
    try std.testing.expectError(error.UncertainOrderBlocksSend, run.shard.apply(atGroup(14, .{
        .identity = 91,
        .payload = .{ .oms_intent_group = next },
    })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
}

test "TradingShard preserves maintenance margin in the projected buffer" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 45, .count = 1 };
    group.members[0] = .{ .intent_sequence = 45, .operation = .place, .instrument = swap_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 45, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(i64, 11_375), try run.shard.activeReservationAtoms());
    try std.testing.expectEqual(@as(i64, 19_999_982_750), run.shard.portfolio_margin_buffer_atoms);
}

test "rejected IntentGroup leaves authoritative state unchanged" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    const before = run.shard.canonicalStateDigest();
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 50, .count = 2 };
    group.members[0] = .{ .intent_sequence = 50, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    group.members[1] = .{ .intent_sequence = 51, .operation = .cancel, .instrument = spot_instrument, .target_order_id = 999, .expected_revision = 1 };
    try std.testing.expectError(error.UnknownOrder, run.shard.apply(atGroup(12, .{ .identity = 50, .payload = .{ .oms_intent_group = group } })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "rejected dispatch batch leaves authoritative state unchanged" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 55, .count = 1 };
    group.members[0] = .{ .intent_sequence = 55, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 55, .payload = .{ .oms_intent_group = group } }));
    const before = run.shard.canonicalStateDigest();
    var batch: oms_module.DispatchBatch = .{ .count = 2 };
    batch.items[0] = .{ .command_id = 1, .state = .unknown };
    batch.items[1] = .{ .command_id = 999, .state = .submitted };
    try std.testing.expectError(error.UnknownCommand, run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = batch } })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "rejected execution report leaves authoritative state unchanged" {
    var run = try startScenario();
    const before = run.shard.canonicalStateDigest();
    try std.testing.expectError(error.UnknownOrder, run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .oms_execution_report = .{
        .report_id = 1,
        .order_id = 999,
        .revision = 1,
        .status = .accepted,
        .cumulative_quantity = 0,
        .remaining_quantity = 10,
    } } })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "authoritative reconciliation cannot regress a terminal order" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 60, .count = 1 };
    group.members[0] = .{ .intent_sequence = 60, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 60, .payload = .{ .oms_intent_group = group } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    try std.testing.expectError(error.TerminalFactConflict, run.shard.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } })));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    try std.testing.expectError(error.TerminalFactConflict, run.shard.apply(atGroup(15, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10 } } })));
}

test "CancelConfirmCreate re-risks replacement against latest facts" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 70, .count = 1 };
    place.members[0] = .{ .intent_sequence = 70, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 70, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 71, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 71, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000), .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try run.shard.apply(atGroup(14, .{ .identity = 71, .payload = .{ .oms_intent_group = replace } }));
    _ = try run.shard.apply(atGroup(15, .{ .identity = 72, .payload = .{ .risk_lease_granted = .{
        .lease_identity = 72,
        .version = 2,
        .amount_atoms = 1_000,
        .strategy_limit_atoms = 10,
        .portfolio_limit_atoms = 1_000,
        .exchange_account_limit_atoms = 1_000,
        .global_limit_atoms = 1_000,
    } } }));
    const result = try run.shard.apply(atGroup(15, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 0), result.oms_commands.len);
}

test "CancelConfirmCreate cannot recreate a fenced strategy" {
    var run = try startScenario();
    _ = try fixture.apply(&run, atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 80, .count = 1 };
    place.members[0] = .{ .intent_sequence = 80, .strategy_instance = 1, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try fixture.apply(&run, atGroup(12, .{ .identity = 80, .payload = .{ .oms_intent_group = place } }));
    _ = try fixture.apply(&run, atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 81, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 81, .strategy_instance = 1, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000), .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try fixture.apply(&run, atGroup(14, .{ .identity = 81, .payload = .{ .oms_intent_group = replace } }));
    _ = try fixture.apply(&run, atGroup(15, .{ .identity = 82, .payload = .{ .strategy_cutover_fence = .{ .strategy_instance = 1 } } }));
    _ = try fixture.apply(&run, fixture.canonicalAt(16, 904, .{ .execution_report = .{
        .identity = 904,
        .order = 1,
        .client_order_id = try canonical.ClientOrderId.init("RWN-1"),
        .instrument = spot_instrument,
        .exchange_account = 2,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 0 },
        .remaining_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 100 },
    } }));
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try std.testing.expect(run.shard.oms.orders[0].replacement == null);
    try run.decision_journal.seal();
    _ = try fixture.assertReplayEquivalent(run);
}

test "forced position divergence blocks new qualification" {
    var run = try startScenario();
    try establishSwapPosition(&run.shard, 600, 10);
    _ = try run.shard.apply(atGroup(604, .{ .identity = 601, .payload = .{ .venue_forced_execution = .{
        .execution_id = 601,
        .side = .sell,
        .quantity = 15,
        .price_ticks = 50_000_000,
    } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 75, .count = 1 };
    group.members[0] = .{ .intent_sequence = 75, .operation = .place, .instrument = swap_instrument, .side = .sell, .quantity = 8, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    try std.testing.expectEqual(shard_event.RejectReason.authorization_closed, (try run.shard.apply(atGroup(12, .{ .identity = 75, .payload = .{ .oms_intent_group = group } }))).facts[0].reject_reason);
    try std.testing.expectEqual(@as(i64, 10), run.shard.economicSummary().portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, -5), run.shard.economicSummary().exchange.swap.quantity);
}

test "SPOT asset risk is isolated from SWAP positions" {
    var run = try startScenario();
    try establishSwapPosition(&run.shard, 700, 10);
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 79, .count = 1 };
    group.members[0] = .{ .intent_sequence = 79, .operation = .place, .instrument = spot_instrument, .side = .sell, .quantity = 1, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    try std.testing.expectEqual(shard_event.RejectReason.insufficient_spot_asset, (try run.shard.apply(atGroup(12, .{ .identity = 79, .payload = .{ .oms_intent_group = group } }))).facts[0].reject_reason);
}

test "economic fills derive ownership from OMS and close Portfolio Exchange ledgers" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 79, .count = 1 };
    group.members[0] = .{ .intent_sequence = 79, .operation = .place, .instrument = swap_instrument, .side = .buy, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 79, .payload = .{ .oms_intent_group = group } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .economic_fill = .{ .fill_id = 1, .order_id = 1, .quantity = 4, .price_ticks = 50_000_000, .fee_atoms = 15 } } }));
    _ = try run.shard.apply(atGroup(14, .{ .identity = 2, .payload = .{ .economic_fill = .{ .fill_id = 2, .order_id = 1, .quantity = 6, .price_ticks = 51_000_000, .fee_atoms = 20, .rebate_atoms = 5 } } }));
    const summary = run.shard.economicSummary();
    try std.testing.expectEqual(@as(i64, 10), summary.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, 50_600), summary.portfolio.swap.open_cost_atoms);
    try std.testing.expectEqual(@as(i64, 1_114), summary.portfolio.margin_atoms);
    try std.testing.expectEqual(@as(i64, 1_012), summary.exchange.margin_atoms);
    try std.testing.expectEqual(@as(i64, 35), summary.portfolio.fee_atoms);
    try std.testing.expectEqual(@as(i64, 5), summary.portfolio.rebate_atoms);
    try std.testing.expectEqual(@as(u8, 10), summary.ledger_transactions);
    try std.testing.expect(try run.shard.riskLeaseRemainingAtoms() < run.shard.risk_lease_atoms);
    try std.testing.expectEqual(summary.portfolio.swap.quantity, run.shard.economicSummary().portfolio.swap.quantity);
    try std.testing.expectEqual(summary.portfolio.usdt_balance_atoms, run.shard.economicSummary().portfolio.usdt_balance_atoms);
    try std.testing.expect(!summary.reconciliation_break);
}

test "funding forced execution and snapshots preserve auditable local economics" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    const before = run.shard.economicSummary();
    _ = try run.shard.apply(atGroup(12, .{ .identity = 10, .payload = .{ .funding_settlement = .{ .settlement_id = 10, .amount_atoms = -25 } } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 11, .payload = .{ .venue_forced_execution = .{ .execution_id = 11, .side = .sell, .quantity = 2, .price_ticks = 50_000_000, .fee_atoms = 3, .penalty_atoms = 2 } } }));
    const projected = run.shard.economicSummary();
    try std.testing.expectEqual(@as(i64, 0), projected.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, -2), projected.exchange.swap.quantity);
    try std.testing.expectEqual(@as(i64, -30), projected.suspense_usdt_atoms);
    try std.testing.expectEqual(projected.exchange.swap.quantity, run.shard.economicSummary().exchange.swap.quantity);
    try std.testing.expectEqual(projected.exchange.usdt_balance_atoms, run.shard.economicSummary().exchange.usdt_balance_atoms);
    try std.testing.expect(projected.reconciliation_break);
    try std.testing.expectEqual(@as(u8, 4), projected.ledger_transactions);

    const local_exchange = projected.exchange;
    _ = try run.shard.apply(atGroup(14, .{ .identity = 12, .payload = .{ .economic_account_snapshot = .{ .snapshot_id = 12, .usdt_balance_atoms = before.exchange.usdt_balance_atoms, .spot_asset_atoms = 99, .swap_position_quantity = 99, .margin_atoms = 99 } } }));
    try std.testing.expectEqualDeep(local_exchange, run.shard.economicSummary().exchange);
    try std.testing.expectError(error.ConflictingEconomicIdentity, run.shard.apply(atGroup(15, .{ .identity = 10, .payload = .{ .funding_settlement = .{ .settlement_id = 10, .amount_atoms = -26 } } })));
}

test "duplicate economic facts are no-op at the TradingShard seam" {
    var run = try startScenario();
    const funding = atGroup(11, .{ .identity = 30, .payload = .{ .funding_settlement = .{ .settlement_id = 30, .amount_atoms = -5 } } });
    _ = try run.shard.apply(funding);
    const before = run.shard.canonicalStateDigest();
    const result = try run.shard.apply(funding);
    try std.testing.expectEqual(@as(usize, 0), result.facts.len);
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "CancelConfirmCreate accepts authoritative reconciliation as confirmation" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 76, .count = 1 };
    place.members[0] = .{ .intent_sequence = 76, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 76, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 77, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 77, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000), .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try run.shard.apply(atGroup(14, .{ .identity = 77, .payload = .{ .oms_intent_group = replace } }));
    const result = try run.shard.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 100, .terminal_state = .canceled } } }));
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 1), result.oms_commands.len);
    try std.testing.expectEqual(@as(u64, 1), result.oms_commands[0].predecessor_order_id);
}

test "canonical absence without source proof preserves the unknown order and reservation" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 176, .count = 1 };
    group.members[0] = .{ .intent_sequence = 176, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 176, .payload = .{ .oms_intent_group = group } }));
    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = 1, .state = .unknown };
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    const reserved = try run.shard.activeReservationAtoms();
    _ = try run.shard.apply(fixture.canonicalAt(14, 901, .{ .order_reconciliation_result = .{
        .identity = 901,
        .complete = true,
        .status = .confirmed_absent,
        .order = 1,
        .revision = 1,
        .cumulative_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 0 },
        .remaining_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 10 },
        .rules_version = 1,
    } }));
    try std.testing.expectEqual(oms_module.OrderState.unknown, run.shard.oms.orderById(1).?.state);
    try std.testing.expectEqual(reserved, try run.shard.activeReservationAtoms());
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
}

test "complete canonical absence closes only an unknown place and rejects late venue facts" {
    var run = try startScenario();
    _ = try fixture.apply(&run, atGroup(11, .{ .identity = 1800, .payload = .{ .capability_profile_activation = .{
        .exchange_account = 2,
        .instrument = spot_instrument,
        .venue = 1,
        .environment = .simulation,
        .product = .spot,
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 9,
        .max_dispatch_age_ns = std.time.ns_per_s,
        .supports_place = true,
        .supports_cancel = true,
        .supports_native_amend = false,
        .supports_venue_reduce_only = false,
        .supports_post_only = false,
        .supports_market_protection = false,
    } } }));
    _ = try fixture.apply(&run, atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 177, .count = 1 };
    group.members[0] = .{ .intent_sequence = 177, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try fixture.apply(&run, atGroup(12, .{ .identity = 177, .payload = .{ .oms_intent_group = group } }));
    const command = run.shard.oms.command_history[0];
    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = command.command_id, .state = .unknown };
    _ = try fixture.apply(&run, atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    var absent: canonical.ReconciliationResult = .{
        .identity = 910,
        .complete = true,
        .status = .confirmed_absent,
        .order = command.order_id,
        .revision = command.revision,
        .cumulative_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 0 },
        .remaining_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 10 },
        .rules_version = 1,
        .evidence = fixture.completeAbsenceEvidence(14, 910, command.order_id, spot_instrument, command.revision),
    };
    const incomplete = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    for (incomplete) |case| {
        var candidate = run.shard;
        var claim = absent;
        switch (case) {
            0 => claim.evidence.?.scope.order = 2,
            1 => claim.evidence.?.absence.?.prior_session_inactive = false,
            2 => claim.evidence.?.absence.?.visibility_deadline_utc_ns = std.math.maxInt(u64),
            3 => claim.evidence.?.absence.?.fills_complete = false,
            4 => claim.evidence.?.source.digest = @splat(0),
            5 => claim.evidence.?.absence.?.prior_session = 1,
            6 => claim.rules_version = 99,
            7 => claim.cumulative_quantity.?.instrument = swap_instrument,
            8 => claim.remaining_quantity.?.lots = 20,
            9 => claim.order = 2,
            10 => claim.evidence.?.scope.instrument = swap_instrument,
            11 => claim.evidence.?.absence.?.prior_session = 8,
            else => unreachable,
        }
        _ = try candidate.apply(fixture.canonicalAt(14, 910, .{ .order_reconciliation_result = claim }));
        try std.testing.expectEqual(oms_module.OrderState.unknown, candidate.oms.orderById(command.order_id).?.state);
        try std.testing.expect(candidate.oms.orderById(command.order_id).?.reservation_active);
        try std.testing.expect(!candidate.operational_state.effectiveTradingAuthority());
    }
    const event = fixture.canonicalAt(14, 910, .{ .order_reconciliation_result = absent });
    _ = try fixture.apply(&run, event);
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orderById(command.order_id).?.state);
    try std.testing.expectEqual(@as(i64, 0), try run.shard.activeReservationAtoms());
    try std.testing.expectEqual(@as(i64, 0), try run.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    const digest = run.shard.canonicalStateDigest();
    _ = try run.shard.apply(event);
    try std.testing.expectEqualSlices(u8, &digest, &run.shard.canonicalStateDigest());
    absent.evidence.?.source.digest = @splat(2);
    try std.testing.expectError(error.ConflictingCanonicalIdentity, run.shard.apply(fixture.canonicalAt(14, 910, .{ .order_reconciliation_result = absent })));
    const venue_order = try canonical.VenueOrderRef.init(1, "late-order");
    var after_report = run.shard;
    try std.testing.expectError(error.TerminalFactConflict, after_report.apply(fixture.canonicalAt(15, 911, .{ .execution_report = .{
        .identity = 911,
        .order = command.order_id,
        .client_order_id = command.client_order_id,
        .instrument = spot_instrument,
        .exchange_account = 2,
        .revision = command.revision,
        .status = .accepted,
        .cumulative_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 0 },
        .remaining_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 10 },
    } })));
    var after_fill = run.shard;
    try std.testing.expectError(error.TerminalFactConflict, after_fill.apply(fixture.canonicalAt(15, 912, .{ .fill = .{
        .identity = 912,
        .order = command.order_id,
        .client_order_id = command.client_order_id,
        .venue_order = venue_order,
        .venue_trade = try canonical.VenueTradeRef.init(1, "late-trade"),
        .instrument = spot_instrument,
        .exchange_account = 2,
        .side = .buy,
        .quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 1 },
        .price = .{ .instrument = spot_instrument, .rules_version = 1, .ticks = 50_000_000 },
        .liquidity = .taker,
    } })));
    try std.testing.expectEqual(@as(i64, 0), try after_fill.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    var after_core_fill = run.shard;
    try std.testing.expectError(error.TerminalFactConflict, after_core_fill.apply(atGroup(15, .{ .identity = 913, .payload = .{ .economic_fill = .{
        .fill_id = 913,
        .order_id = command.order_id,
        .quantity = 1,
        .price_ticks = 50_000_000,
    } } })));
    try run.decision_journal.seal();
    try std.testing.expectEqualSlices(u8, &digest, &try fixture.assertReplayEquivalent(run));
}

test "canonical terminal reconciliation confirms a CCC replacement" {
    var run = try startScenario();
    _ = try fixture.apply(&run, atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 180, .count = 1 };
    place.members[0] = .{ .intent_sequence = 180, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try fixture.apply(&run, atGroup(12, .{ .identity = 180, .payload = .{ .oms_intent_group = place } }));
    _ = try fixture.apply(&run, atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 181, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 181, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000), .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try fixture.apply(&run, atGroup(14, .{ .identity = 181, .payload = .{ .oms_intent_group = replace } }));
    _ = try fixture.apply(&run, fixture.canonicalAt(15, 902, .{ .order_reconciliation_result = .{
        .identity = 902,
        .complete = true,
        .status = .found_terminal,
        .order = 1,
        .revision = 1,
        .cumulative_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 0 },
        .remaining_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 100 },
        .terminal_status = .canceled,
        .rules_version = 1,
        .evidence = fixture.reconciliationEvidence(15, 902, 1, spot_instrument, 1),
    } }));
    const commands = run.shard.oms.emitted();
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 1), commands.len);
    try std.testing.expectEqual(@as(u64, 1), commands[0].predecessor_order_id);
    try run.decision_journal.seal();
    _ = try fixture.assertReplayEquivalent(run);
}

test "canonical cancel report confirms a CCC replacement" {
    var run = try startScenario();
    _ = try fixture.apply(&run, atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 190, .count = 1 };
    place.members[0] = .{ .intent_sequence = 190, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try fixture.apply(&run, atGroup(12, .{ .identity = 190, .payload = .{ .oms_intent_group = place } }));
    _ = try fixture.apply(&run, atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 191, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 191, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000), .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try fixture.apply(&run, atGroup(14, .{ .identity = 191, .payload = .{ .oms_intent_group = replace } }));
    _ = try fixture.apply(&run, fixture.canonicalAt(15, 903, .{ .execution_report = .{
        .identity = 903,
        .order = 1,
        .client_order_id = try canonical.ClientOrderId.init("RWN-1"),
        .instrument = spot_instrument,
        .exchange_account = 2,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 0 },
        .remaining_quantity = .{ .instrument = spot_instrument, .rules_version = 1, .lots = 100 },
    } }));
    const commands = run.shard.oms.emitted();
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 1), commands.len);
    try std.testing.expectEqual(@as(u64, 1), commands[0].predecessor_order_id);
    try run.decision_journal.seal();
    _ = try fixture.assertReplayEquivalent(run);
}

test "older reconciliation identity still rejects semantic conflict" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 78, .count = 1 };
    place.members[0] = .{ .intent_sequence = 78, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 78, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .unresolved, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    _ = try run.shard.apply(atGroup(14, .{ .identity = 2, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 2, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectError(error.ConflictingReconciliationIdentity, run.shard.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } })));
}

test "multiple SPOT and SWAP orders independently close place amend and cancel" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 80, .count = 4 };
    place.members[0] = .{ .intent_sequence = 80, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    place.members[1] = .{ .intent_sequence = 81, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    place.members[2] = .{ .intent_sequence = 82, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    place.members[3] = .{ .intent_sequence = 83, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 80, .payload = .{ .oms_intent_group = place } }));
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |order_id, index| _ = try run.shard.apply(atGroup(13 + index, .{ .identity = 1 + index, .payload = .{ .oms_execution_report = .{ .report_id = 1 + index, .order_id = order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));

    var amend_capability: shard_event.CapabilityProfileActivation = .{
        .exchange_account = 2,
        .instrument = spot_instrument,
        .venue = 1,
        .environment = .simulation,
        .product = .spot,
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 1,
        .max_dispatch_age_ns = std.time.ns_per_s,
        .supports_place = true,
        .supports_cancel = true,
        .supports_native_amend = true,
        .supports_venue_reduce_only = false,
        .supports_post_only = false,
        .supports_market_protection = false,
    };
    _ = try run.shard.apply(atGroup(16, .{ .identity = 100, .payload = .{ .capability_profile_activation = amend_capability } }));
    amend_capability.instrument = swap_instrument;
    amend_capability.product = .isolated_linear_usdt;
    _ = try run.shard.apply(atGroup(16, .{ .identity = 101, .payload = .{ .capability_profile_activation = amend_capability } }));

    var amend: oms_module.IntentGroup = .{ .first_intent_sequence = 84, .count = 4 };
    amend.members[0] = .{ .intent_sequence = 84, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 8, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000) };
    amend.members[1] = .{ .intent_sequence = 85, .operation = .amend, .instrument = spot_instrument, .target_order_id = 2, .expected_revision = 1, .quantity = 8, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000) };
    amend.members[2] = .{ .intent_sequence = 86, .operation = .amend, .instrument = swap_instrument, .target_order_id = 3, .expected_revision = 1, .quantity = 8, .limit_price = fixtureOmsPrice(swap_instrument, 49_000_000) };
    amend.members[3] = .{ .intent_sequence = 87, .operation = .amend, .instrument = swap_instrument, .target_order_id = 4, .expected_revision = 1, .quantity = 8, .limit_price = fixtureOmsPrice(swap_instrument, 49_000_000) };
    _ = try run.shard.apply(atGroup(17, .{ .identity = 84, .payload = .{ .oms_intent_group = amend } }));
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |order_id, index| _ = try run.shard.apply(atGroup(18 + index, .{ .identity = 5 + index, .payload = .{ .oms_execution_report = .{ .report_id = 5 + index, .order_id = order_id, .revision = 2, .status = .amended, .cumulative_quantity = 0, .remaining_quantity = 8 } } }));

    var cancel: oms_module.IntentGroup = .{ .first_intent_sequence = 88, .count = 4 };
    cancel.members[0] = .{ .intent_sequence = 88, .operation = .cancel, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 2 };
    cancel.members[1] = .{ .intent_sequence = 89, .operation = .cancel, .instrument = spot_instrument, .target_order_id = 2, .expected_revision = 2 };
    cancel.members[2] = .{ .intent_sequence = 90, .operation = .cancel, .instrument = swap_instrument, .target_order_id = 3, .expected_revision = 2 };
    cancel.members[3] = .{ .intent_sequence = 91, .operation = .cancel, .instrument = swap_instrument, .target_order_id = 4, .expected_revision = 2 };
    _ = try run.shard.apply(atGroup(22, .{ .identity = 88, .payload = .{ .oms_intent_group = cancel } }));
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |order_id, index| _ = try run.shard.apply(atGroup(23 + index, .{ .identity = 9 + index, .payload = .{ .oms_execution_report = .{ .report_id = 9 + index, .order_id = order_id, .revision = 2, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 8 } } }));
    for (run.shard.oms.orders[0..4]) |order| try std.testing.expectEqual(oms_module.OrderState.canceled, order.state);
    try std.testing.expectEqual(@as(i64, 0), try run.shard.activeReservationAtoms());
}

test "core safety invariants replay CCC intent conflict suspense and archive windows" {
    var run = try startScenario();
    try std.testing.expect(run.shard.host_activation_identity != 0);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000 } } }));

    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 400, .count = 1 };
    place.members[0] = .{ .intent_sequence = 400, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000), .reservation = fixtureReservation(5_000_000) };
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(12, .{ .identity = 400, .payload = .{ .oms_intent_group = place } }));
    const first_command = run.shard.oms.command_history[run.shard.oms.command_history_count - 1];
    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = first_command.command_id, .state = .submitted };
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(13, .{ .identity = 401, .payload = .{ .oms_dispatch_batch = dispatch } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(14, .{ .identity = 402, .payload = .{ .oms_execution_report = .{ .report_id = 401, .order_id = first_command.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 401, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 401, .operation = .amend, .instrument = spot_instrument, .target_order_id = first_command.order_id, .expected_revision = 1, .quantity = 75, .limit_price = fixtureOmsPrice(spot_instrument, 49_800_000), .native_amend = false, .allow_cancel_confirm_create = true, .reservation = fixtureReservation(3_750_000) };
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{ .identity = 403, .payload = .{ .oms_intent_group = replace } }));
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{ .identity = 404, .payload = .{ .oms_execution_report = .{ .report_id = 402, .order_id = first_command.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(first_command.order_id, run.shard.oms.orders[1].predecessor_order_id);

    var conflicting = place;
    conflicting.members[0].quantity = 80;
    const order_count_before_conflict = run.shard.oms.order_count;
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(17, .{ .identity = 405, .payload = .{ .oms_intent_group = conflicting } }))) == null);
    try std.testing.expectEqual(order_count_before_conflict, run.shard.oms.order_count);
    try std.testing.expectEqual(shard_event.EventKind.oms_intent_conflict, run.shard.trace.events[run.shard.trace.len - 1].kind);

    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(18, .{ .identity = 406, .payload = .{ .venue_forced_execution = .{ .execution_id = 406, .side = .sell, .quantity = 2, .price_ticks = 50_000_000, .fee_atoms = 3, .penalty_atoms = 2 } } }));
    try std.testing.expectEqual(@as(i64, -2), run.shard.economicSummary().exchange.swap.quantity);
    try std.testing.expect(run.shard.economicSummary().suspense_usdt_atoms != 0);

    var archive = try startScenario();
    var sequence: u64 = 1;
    while (sequence <= oms_module.max_orders + 1) : (sequence += 1) {
        var group: oms_module.IntentGroup = .{ .first_intent_sequence = 500 + sequence, .count = 1 };
        group.members[0] = .{ .intent_sequence = 500 + sequence, .operation = .place, .instrument = spot_instrument, .quantity = 1, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
        _ = try applyLive(&archive.shard, &archive.decision_journal, atGroup(20 + sequence, .{ .identity = 500 + sequence, .payload = .{ .oms_intent_group = group } }));
        const command_value = archive.shard.oms.command_history[archive.shard.oms.command_history_count - 1];
        _ = try applyLive(&archive.shard, &archive.decision_journal, atGroup(60 + sequence, .{ .identity = 700 + sequence, .payload = .{ .oms_execution_report = .{ .report_id = 700 + sequence, .order_id = command_value.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 1 } } }));
        _ = try applyLive(&archive.shard, &archive.decision_journal, atGroup(80 + sequence, .{ .identity = 800 + sequence, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 800 + sequence, .order_id = command_value.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 1, .terminal_state = .canceled } } }));
    }
    try std.testing.expectEqual(@as(u8, 1), archive.shard.oms.tombstone_count);
    try std.testing.expect(archive.shard.oms.orderById(1) == null);
    const archived = archive.shard.oms.tombstones[0];
    try std.testing.expectEqual(@as(u64, 501), archived.intent_sequence);
    try std.testing.expect(!std.mem.eql(u8, &archived.fact_digest, &@as([32]u8, @splat(0))));
    try archive.decision_journal.seal();
    var snapshot_storage: [256 * 1024]u8 = undefined;
    const snapshot = try archive.shard.snapshot(&archive.decision_journal, archive.decision_journal.last_sequence, &snapshot_storage);
    var restored = try TradingShard.restoreSnapshot(snapshot);
    try std.testing.expectEqual(archived.intent_sequence, restored.shard.oms.tombstones[0].intent_sequence);
    try std.testing.expectEqualSlices(u8, &archive.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    const before_late = restored.shard.canonicalStateDigest();
    try restored.shard.oms.applyReport(.{ .report_id = 701, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 1 });
    try std.testing.expectEqualSlices(u8, &before_late, &restored.shard.canonicalStateDigest());
    try std.testing.expectError(error.TombstoneFactConflict, restored.shard.oms.applyReport(.{ .report_id = 701, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 1, .remaining_quantity = 0 }));
    try std.testing.expect(restored.shard.oms.recovery_only);

    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
    _ = try assertReplayEquivalent(archive);
    comptime std.debug.assert(!@hasField(ReplayTradingShard, "gateway"));
    std.debug.print("core_safety_invariants: ccc=pass intent_conflict=pass suspense=pass tombstone_archive=pass host_activated=pass\n", .{});
}

fn applyHealthyPreludeReplay(replay_shard: *ReplayTradingShard) !void {
    _ = try replay_shard.apply(atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000_000 } } }));
    _ = try replay_shard.apply(fixture.canonicalAt(12, 99, .{ .instrument_definition_observed = .{ .instrument = 3, .rules_version = 1 } }));
    _ = try replay_shard.apply(snapshotAt(13, 100));
    _ = try replay_shard.apply(deltaAt(14, 100, 101, 49_850_000_000));
}

test "direct core spot fill enforces native base single amount before economic commit" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 79, .count = 1 };
    group.members[0] = .{ .intent_sequence = 79, .operation = .place, .instrument = spot_instrument, .side = .buy, .quantity = 2, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    const placed = try run.shard.apply(atGroup(12, .{ .identity = 79, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), placed.oms_commands.len);
    var definition = run.shard.asset_registry.get(0x425443).?.definition;
    definition.version = 2;
    definition.max_single_atoms = 1; // BTC8 and spot lot1e-8: one atom per lot.
    _ = try run.shard.apply(atGroup(13, .{ .identity = 2, .payload = .{ .asset_definition_activated = definition } }));
    const before = run.shard.economicSummary();
    const digest = run.shard.canonicalStateDigest();
    try std.testing.expectError(error.AssetAmountOutOfRange, run.shard.apply(atGroup(14, .{ .identity = 1, .payload = .{ .economic_fill = .{ .fill_id = 1, .order_id = placed.oms_commands[0].order_id, .quantity = 2, .price_ticks = 50_000_000 } } })));
    try std.testing.expectEqualDeep(before, run.shard.economicSummary());
    try std.testing.expectEqualSlices(u8, &digest, &run.shard.canonicalStateDigest());
}

test "direct core spot sells release only their uniquely applied inventory" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 800, .count = 1 };
    group.members[0] = .{ .intent_sequence = 800, .operation = .place, .instrument = spot_instrument, .side = .buy, .quantity = 3, .limit_price = fixtureOmsPrice(spot_instrument, 100_000_000) };
    const bought = try run.shard.apply(atGroup(12, .{ .identity = 800, .payload = .{ .oms_intent_group = group } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 801, .payload = .{ .economic_fill = .{ .fill_id = 801, .order_id = bought.oms_commands[0].order_id, .quantity = 3, .price_ticks = 100_000_000 } } }));
    group.first_intent_sequence = 802;
    group.members[0].intent_sequence = 802;
    group.members[0].side = .sell;
    group.members[0].quantity = 1;
    const sold = try run.shard.apply(atGroup(14, .{ .identity = 802, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), sold.oms_commands.len);
    _ = try run.shard.apply(atGroup(15, .{ .identity = 803, .payload = .{ .economic_fill = .{ .fill_id = 803, .order_id = sold.oms_commands[0].order_id, .quantity = 1, .price_ticks = 100_000_000 } } }));
    try std.testing.expectEqual(@as(i128, 2), run.shard.economicSummary().portfolio.spot_asset_atoms);
    group.first_intent_sequence = 804;
    group.members[0].intent_sequence = 804;
    group.members[0].quantity = 2;
    const remaining = try run.shard.apply(atGroup(16, .{ .identity = 804, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), remaining.oms_commands.len);
}

test "spot decreasing native amend reserves confirmed inventory until venue confirmation" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    _ = try run.shard.apply(atGroup(11, .{ .identity = 899, .payload = .{ .capability_profile_activation = .{
        .exchange_account = 2,
        .instrument = spot_instrument,
        .venue = 1,
        .environment = .simulation,
        .product = .spot,
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 1,
        .max_dispatch_age_ns = std.time.ns_per_s,
        .supports_place = true,
        .supports_cancel = true,
        .supports_native_amend = true,
        .supports_venue_reduce_only = false,
        .supports_post_only = false,
        .supports_market_protection = false,
    } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 900, .count = 1 };
    group.members[0] = .{ .intent_sequence = 900, .operation = .place, .instrument = spot_instrument, .side = .buy, .quantity = 2, .limit_price = fixtureOmsPrice(spot_instrument, 100_000_000) };
    const bought = try run.shard.apply(atGroup(12, .{ .identity = 900, .payload = .{ .oms_intent_group = group } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 901, .payload = .{ .economic_fill = .{ .fill_id = 901, .order_id = bought.oms_commands[0].order_id, .quantity = 2, .price_ticks = 100_000_000 } } }));
    group.first_intent_sequence = 902;
    group.members[0].intent_sequence = 902;
    group.members[0].side = .sell;
    const placed = try run.shard.apply(atGroup(14, .{ .identity = 902, .payload = .{ .oms_intent_group = group } }));
    const order_id = placed.oms_commands[0].order_id;
    _ = try run.shard.apply(atGroup(15, .{ .identity = 903, .payload = .{ .oms_execution_report = .{ .report_id = 903, .order_id = order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 2 } } }));
    var amend: oms_module.IntentGroup = .{ .first_intent_sequence = 904, .count = 1 };
    amend.members[0] = .{ .intent_sequence = 904, .operation = .amend, .instrument = spot_instrument, .target_order_id = order_id, .expected_revision = 1, .side = .sell, .quantity = 1, .limit_price = fixtureOmsPrice(spot_instrument, 100_000_000), .native_amend = true };
    const amended = try run.shard.apply(atGroup(16, .{ .identity = 904, .payload = .{ .oms_intent_group = amend } }));
    try std.testing.expectEqual(@as(usize, 1), amended.oms_commands.len);
    group.first_intent_sequence = 905;
    group.members[0].intent_sequence = 905;
    group.members[0].quantity = 1;
    const pending = try run.shard.apply(atGroup(17, .{ .identity = 905, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 0), pending.oms_commands.len);
    try std.testing.expectEqual(shard_event.RejectReason.insufficient_spot_asset, pending.facts[0].reject_reason);
    _ = try run.shard.apply(atGroup(18, .{ .identity = 906, .payload = .{ .oms_execution_report = .{ .report_id = 906, .order_id = order_id, .revision = 2, .status = .amended, .cumulative_quantity = 0, .remaining_quantity = 1 } } }));
    group.first_intent_sequence = 907;
    group.members[0].intent_sequence = 907;
    const confirmed = try run.shard.apply(atGroup(19, .{ .identity = 907, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), confirmed.oms_commands.len);
}
