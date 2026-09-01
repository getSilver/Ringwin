const std = @import("std");
const engine = @import("trading_shard.zig");
const canonical = engine.canonical;
const oms_module = engine.oms;
const operational = engine.operational;
const host_gateway = @import("strategy_host_gateway.zig");

const TradingShard = engine.TradingShard;
const ReplayTradingShard = engine.ReplayTradingShard;
const ShardEvent = engine.ShardEvent;
const LiveRun = engine.LiveRun;
const OrderState = engine.test_support.OrderStateType;
const contract_denominator = engine.test_support.contract_quantity_denominator;
const happy_order_quantity = engine.test_support.happy_quantity;
const order_limit_price = engine.test_support.limit_price;
const settlement_asset = engine.test_support.settlement;
const spot_instrument = engine.test_support.spot;
const swap_instrument = engine.test_support.swap;
const margin_kill_gate_identity = engine.test_support.margin_kill_gate;
const primary_lease_gate_identity = engine.test_support.primary_lease_gate;
const risk_lease_gate_identity = engine.test_support.risk_lease_gate;
const genesis = engine.test_support.genesis_events;
const fixtureOmsPrice = engine.test_support.omsPrice;
const fixtureReservation = engine.test_support.reservation;
const lifecycleCommand = engine.test_support.lifecycle;
const deRiskCommand = engine.test_support.deRisk;
const resolveLatchCommand = engine.test_support.resolveLatch;
const startScenario = engine.test_support.start;
const startScenarioAuthorized = engine.test_support.startAuthorized;
const applyLive = engine.test_support.applyJournaled;
const happyPathVenueFacts = engine.test_support.healthyVenueFacts;
const snapshotAt = engine.test_support.snapshot;
const deltaAt = engine.test_support.delta;
const assertReplayEquivalent = engine.assertReplayEquivalent;
const assertReplayEquivalentConfigured = engine.test_support.replayEquivalentConfigured;
const applyHealthyPrelude = engine.applyHealthyPrelude;
const atGroup = engine.atGroup;

test "configurable Genesis fails closed until authority is complete" {
    var incomplete: TradingShard = .{};
    try std.testing.expectError(error.GenesisIncomplete, engine.test_support.submitIntent(&incomplete, .{
        .strategy_identity = 1,
        .intent_sequence = 1,
        .strategy_cursor = 1,
        .config_version = 1,
        .activation_identity = 1,
        .portfolio_identity = 1,
        .exchange_account_identity = 2,
        .instrument_identity = 3,
        .side = .buy,
        .order_type = .limit,
        .time_in_force = .good_til_canceled,
        .portfolio_reduce_only = false,
        .quantity = 1,
        .limit_price_micros = 1,
    }));

    var out_of_order: TradingShard = .{};
    try std.testing.expectError(error.InvalidMarginRules, out_of_order.applyInternal(ShardEvent{
        .identity = 1,
        .payload = .{ .margin_rules_activated = .{ .version = 1 } },
    }));

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

    const native_command = (try native.shard.applyInternal(atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }))).order_command.?;
    const python_command = (try python.shard.applyInternal(atGroup(15, .{
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
    }))).order_command.?;
    try std.testing.expectEqual(native_command.quantity, python_command.quantity);
    try std.testing.expectEqual(native_command.limit_price, python_command.limit_price);
    try std.testing.expectEqual(native_command.reservation, python_command.reservation);

    var unauthorized = try startScenarioAuthorized(authorization, .leveraged);
    try applyHealthyPrelude(&unauthorized);
    try std.testing.expectError(error.IntentAuthorityMismatch, unauthorized.shard.applyInternal(atGroup(15, .{
        .identity = 1,
        .payload = .{ .external_order_intent = .{
            .strategy_identity = 41,
            .intent_sequence = 1,
            .strategy_cursor = unauthorized.shard.trace.len + 1,
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
    })));
}

test "control commands authorize pause cancel and replay lifecycle deterministically" {
    var run = try startScenario();
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());

    const duplicate = try run.shard.applyInternal(genesis[genesis.len - 1]);
    try std.testing.expectEqual(@as(usize, 0), duplicate.facts.len);
    try std.testing.expectError(error.ControlCommandWrongTarget, run.shard.applyInternal(atGroup(12, .{ .identity = 9, .payload = .{ .control_command = .{
        .command_identity = 9,
        .content_hash = 9,
        .target_identity = 2,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .cancel_open_orders,
    } } })));
    try std.testing.expectError(error.ControlCommandExpired, run.shard.applyInternal(atGroup(12, .{ .identity = 9, .payload = .{ .control_command = .{
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
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(13, .{ .identity = 1, .payload = .{ .timer = .{ .quantity = 1 } } }))) == null);
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
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 10, .payload = .{ .safety_gate_change = .{
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
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 11, .payload = .{ .safety_gate_change = .{
        .gate_identity = 11,
        .target_identity = 1,
        .kind = .self_recovering,
        .reason = .observability,
        .open = false,
    } } }));
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectError(error.UnverifiedContinuityProof, run.shard.applyInternal(atGroup(14, .{ .identity = 11, .payload = .{ .safety_gate_change = .{
        .gate_identity = 11,
        .target_identity = 1,
        .kind = .self_recovering,
        .reason = .observability,
        .open = true,
        .continuity_proven = true,
    } } })));
    try engine.test_support.applyGate(&run.shard, .{
        .gate_identity = 11,
        .target_identity = 1,
        .kind = .self_recovering,
        .reason = .observability,
        .open = true,
        .continuity_proven = true,
    });
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    _ = try run.shard.applyInternal(atGroup(15, .{ .identity = 12, .payload = .{ .safety_gate_change = .{
        .gate_identity = 12,
        .target_identity = 1,
        .kind = .latched,
        .reason = .margin_kill,
        .open = false,
    } } }));
    try std.testing.expect(!run.shard.operational_state.trading_authorized);
    _ = try run.shard.applyInternal(atGroup(16, .{ .identity = 12, .payload = .{ .safety_gate_change = .{
        .gate_identity = 12,
        .target_identity = 1,
        .kind = .latched,
        .reason = .margin_kill,
        .open = true,
    } } }));
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.applyInternal(atGroup(17, .{ .identity = 4, .payload = .{ .control_command = .{
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
    run.shard.portfolio_position.quantity = 10;
    run.shard.exchange_position.quantity = 10;
    run.shard.mark_price_micros = 50_000_000;
    try std.testing.expectError(error.RiskWarningRequired, run.shard.applyInternal(atGroup(12, .{ .identity = 3, .payload = .{ .control_command = .{
        .command_identity = 3,
        .content_hash = 3,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .de_risk,
        .target_position = 0,
    } } })));
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 30, .payload = .{ .risk_warning = .{
        .warning_identity = 30,
        .target_identity = 1,
    } } }));
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 3, .payload = .{ .control_command = .{
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
    const reducing = try run.shard.applyInternal(atGroup(13, .{ .identity = 100, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), reducing.oms_commands.len);
    group.members[0].side = .buy;
    try std.testing.expectError(error.DeRiskTargetViolation, run.shard.applyInternal(atGroup(14, .{ .identity = 101, .payload = .{ .oms_intent_group = group } })));
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

fn expectKeepPositionsStopped(run: *const LiveRun, preserved: engine.test_support.EconomicsSnapshot) !void {
    try std.testing.expectEqual(@as(usize, 1), run.shard.oms.emitted().len);
    try std.testing.expectEqual(oms_module.Operation.cancel, run.shard.oms.emitted()[0].operation);
    try std.testing.expectEqual(operational.OperationalMode.stopped, run.shard.operational_state.mode);
    try std.testing.expect(!run.shard.operational_state.trading_authorized);
    try std.testing.expect(!run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expect(!run.shard.operational_state.mayReduceOnly());
    try std.testing.expectEqual(@as(u128, 0), run.shard.operational_state.active_operation_identity);
    try std.testing.expectEqualDeep(preserved, engine.test_support.captureEconomics(&run.shard));
}

test "keep positions stops through shard seam preserving economics" {
    var run = try startScenario();
    try applyHealthyPrelude(&run);

    const opened = try placeIntentGroup(&run, 15, 100, 100, .buy, happy_order_quantity);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(16, .{ .identity = 101, .payload = .{ .economic_fill = .{
        .fill_id = 101,
        .order_id = opened.order_id,
        .quantity = happy_order_quantity,
        .price_micros = 49_900_000_000,
        .fee_micros = 30,
    } } }));
    const preserved = engine.test_support.captureEconomics(&run.shard);
    try std.testing.expect(preserved.positions.portfolio_swap.quantity != 0);
    try std.testing.expect(preserved.ledger.transaction_count != 0);

    try std.testing.expectError(error.ControlCommandWrongTarget, run.shard.applyInternal(atGroup(17, .{ .identity = 900, .payload = .{ .control_command = .{
        .command_identity = 40,
        .content_hash = 40,
        .target_identity = 2,
        .expected_version = 3,
        .expires_at = std.math.maxInt(u64),
        .kind = .stop_keep_positions,
    } } })));
    try std.testing.expectError(error.ControlCommandExpired, run.shard.applyInternal(atGroup(17, .{ .identity = 901, .payload = .{ .control_command = .{
        .command_identity = 40,
        .content_hash = 40,
        .target_identity = 1,
        .expected_version = 3,
        .expires_at = 1,
        .kind = .stop_keep_positions,
    } } })));
    try std.testing.expectError(error.ControlCommandVersionMismatch, run.shard.applyInternal(lifecycleCommand(40, 999, .stop_keep_positions)));

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

    const duplicate_stop = try run.shard.applyInternal(lifecycleCommand(40, 3, .stop_keep_positions));
    try std.testing.expectEqual(@as(usize, 0), duplicate_stop.facts.len);
    try std.testing.expectEqual(@as(usize, 0), run.shard.oms.emitted().len);

    var buy_group: oms_module.IntentGroup = .{ .first_intent_sequence = 110, .count = 1 };
    buy_group.members[0] = .{ .intent_sequence = 110, .operation = .place, .instrument = swap_instrument, .side = .buy, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price) };
    try std.testing.expectError(error.TradingNotAuthorized, run.shard.applyInternal(atGroup(18, .{ .identity = 110, .payload = .{ .oms_intent_group = buy_group } })));
    var reduce_group: oms_module.IntentGroup = .{ .first_intent_sequence = 111, .count = 1 };
    reduce_group.members[0] = .{ .intent_sequence = 111, .operation = .place, .instrument = swap_instrument, .side = .sell, .portfolio_reduce_only = true, .quantity = 40, .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price) };
    try std.testing.expectError(error.TradingNotAuthorized, run.shard.applyInternal(atGroup(19, .{ .identity = 111, .payload = .{ .oms_intent_group = reduce_group } })));
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.applyInternal(lifecycleCommand(41, 4, .enable_trading)));

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
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.applyInternal(lifecycleCommand(43, 6, .enable_trading)));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(49, 6, 77));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(50, 7, primary_lease_gate_identity));
    _ = try applyLive(&run.shard, &run.decision_journal, resolveLatchCommand(51, 8, risk_lease_gate_identity));
    _ = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(52, 9, .enable_trading));
    try std.testing.expect(run.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectEqual(preserved.positions.portfolio_swap.quantity, run.shard.portfolio_position.quantity);

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
    try std.testing.expectError(error.InvalidLifecycleProgress, run.shard.applyInternal(atGroup(18, .{ .identity = 103, .payload = .{ .lifecycle_progress = .{
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
        .price_micros = 49_900_000_000,
        .fee_micros = 30,
    } } }));
    const preserved = engine.test_support.captureEconomics(&run.shard);
    try std.testing.expectEqual(@as(i64, 100), preserved.positions.portfolio_swap.quantity);
    try std.testing.expectEqual(preserved.positions.portfolio_swap.quantity, preserved.positions.exchange_swap.quantity);

    const stopped = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(6, 7, .stop_keep_positions));
    _ = stopped;
    try expectKeepPositionsStopped(&run, preserved);
    var stop_buy_group: oms_module.IntentGroup = .{ .first_intent_sequence = 103, .count = 1 };
    stop_buy_group.members[0] = .{ .intent_sequence = 103, .operation = .place, .instrument = swap_instrument, .side = .buy, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price) };
    try std.testing.expectError(error.TradingNotAuthorized, run.shard.applyInternal(atGroup(23, .{ .identity = 108, .payload = .{ .oms_intent_group = stop_buy_group } })));
    const duplicate_stop = try run.shard.applyInternal(lifecycleCommand(6, 7, .stop_keep_positions));
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
    try std.testing.expectEqual(preserved.positions.portfolio_swap.quantity, run.shard.portfolio_position.quantity);

    _ = try applyLive(&run.shard, &run.decision_journal, deRiskCommand(9, 11, 40, 0));
    try std.testing.expectEqual(operational.OperationalMode.draining, run.shard.operational_state.mode);
    var increase_group: oms_module.IntentGroup = .{ .first_intent_sequence = 104, .count = 1 };
    increase_group.members[0] = .{ .intent_sequence = 104, .operation = .place, .instrument = swap_instrument, .side = .buy, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price) };
    try std.testing.expectError(error.DeRiskTargetViolation, run.shard.applyInternal(atGroup(25, .{ .identity = 110, .payload = .{ .oms_intent_group = increase_group } })));
    const derisk_sell = try placeIntentGroup(&run, 26, 105, 105, .sell, 60);
    _ = try applyLive(&run.shard, &run.decision_journal, atGroup(27, .{ .identity = 112, .payload = .{ .economic_fill = .{
        .fill_id = 112,
        .order_id = derisk_sell.order_id,
        .quantity = 60,
        .price_micros = 50_000_000_000,
        .fee_micros = 25,
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

    try std.testing.expectError(error.RiskWarningRequired, run.shard.applyInternal(deRiskCommand(10, 13, 0, 0)));
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
        .price_micros = 50_000_000_000,
        .fee_micros = 20,
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
    try std.testing.expectError(error.TradingSafetyGateClosed, run.shard.applyInternal(lifecycleCommand(12, 17, .enable_trading)));
    try std.testing.expectError(error.UnknownLatchIdentity, run.shard.applyInternal(resolveLatchCommand(13, 17, 999)));
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
    const command = (try live.shard.applyInternal(atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }))).order_command.?;
    const facts = try happyPathVenueFacts(command);
    for (facts) |event|
        try std.testing.expect((try live.shard.applyInternal(event)).order_command == null);

    var replay_shard: ReplayTradingShard = .{};
    for (genesis) |event| _ = try replay_shard.apply(event);
    try applyHealthyPreludeReplay(&replay_shard);
    _ = try replay_shard.apply(atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }));
    for (facts) |event| _ = try replay_shard.apply(event);
    try std.testing.expectEqualSlices(u8, &live.shard.canonicalStateDigest(), &replay_shard.canonicalStateDigest());
}

test "shared canonical adapter facts enter the TradingShard state seam" {
    const Fixture = struct {
        fn record(sequence: u64, event: canonical.CanonicalEvent) canonical.EventRecord {
            return .{ .envelope = .{
                .event_type = @intFromEnum(canonical.eventType(event)),
                .schema_version = 1,
                .identity = .{ .stream = 1, .sequence = sequence },
                .source_fact_identity = sequence,
                .scope = .account,
                .venue = 1,
                .exchange_account = 2,
                .source_stream = 1,
                .source_sequence = sequence,
                .adapter_session = 4,
                .times = .{ .receive_utc_ns = sequence, .monotonic_ns = sequence, .audit_utc_ns = sequence },
                .raw_evidence = .{ .stream = 1, .sequence = sequence, .digest = @splat(0) },
            }, .event = event };
        }
    };

    var run = try startScenario();
    try applyHealthyPrelude(&run);
    const command = (try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{
        .identity = 1,
        .payload = .{ .timer = .{ .quantity = happy_order_quantity } },
    }))) orelse return error.MissingOrderCommand;
    const client_order = try canonical.ClientOrderId.init(command.client_id);
    const venue_order = try canonical.VenueOrderRef.init(1, "shared-order-1");
    const instrument = run.shard.instrument_identity;
    const quantity = canonical.InstrumentQuantity{ .instrument = instrument, .rules_version = run.shard.instrument_rules_version, .lots = happy_order_quantity };
    const price = canonical.InstrumentPrice{ .instrument = instrument, .rules_version = run.shard.instrument_rules_version, .ticks = order_limit_price };

    try std.testing.expect((try run.shard.apply(Fixture.record(1, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .submitted } }))).order_command == null);
    try std.testing.expect((try run.shard.apply(Fixture.record(2, .{ .execution_report = .{
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
        .original_quantity = quantity,
        .cumulative_quantity = .{ .instrument = instrument, .rules_version = run.shard.instrument_rules_version, .lots = 0 },
        .remaining_quantity = quantity,
        .limit_price = price,
        .average_fill_price = price,
        .venue_update_time_utc_ns = 99,
    } }))).order_command == null);
    try std.testing.expect((try run.shard.apply(Fixture.record(3, .{ .fill = .{
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
    } }))).order_command == null);
    try std.testing.expectEqual(@as(i64, happy_order_quantity), run.shard.portfolio_position.quantity);
    try std.testing.expectEqual(canonical.LiquidityRole.maker, run.shard.last_canonical_fill.?.liquidity);
    try std.testing.expectEqual(@as(i128, 12), run.shard.last_canonical_fill.?.fee.?.atoms);
    try std.testing.expectEqual(@as(i128, 2), run.shard.last_canonical_fill.?.rebate.?.atoms);
    try std.testing.expectEqual(@as(i128, 7), run.shard.last_canonical_fill.?.realized_pnl.?.atoms);
    try std.testing.expectEqual(@as(?u64, 99), run.shard.last_canonical_report.?.venue_update_time_utc_ns);
    try std.testing.expect(run.shard.last_canonical_report.?.margin_mode_isolated.?);
}

test "canonical not-sent is terminal without entering the legacy shard schema" {
    const Fixture = struct {
        fn record(command: u64) canonical.EventRecord {
            const event: canonical.CanonicalEvent = .{ .order_dispatch_result = .{ .command = command, .state = .not_sent, .reason = .capability_unsupported } };
            return .{ .envelope = .{
                .event_type = @intFromEnum(canonical.eventType(event)),
                .schema_version = 1,
                .identity = .{ .stream = 1, .sequence = 1 },
                .source_fact_identity = 1,
                .scope = .account,
                .venue = 1,
                .exchange_account = 2,
                .source_stream = 1,
                .source_sequence = 1,
                .adapter_session = 4,
                .times = .{ .monotonic_ns = 1 },
                .raw_evidence = .{ .stream = 1, .sequence = 1, .digest = @splat(0) },
            }, .event = event };
        }
    };
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    const command = (try applyLive(&run.shard, &run.decision_journal, atGroup(15, .{ .identity = 1, .payload = .{ .timer = .{ .quantity = happy_order_quantity } } }))) orelse return error.MissingOrderCommand;
    _ = try run.shard.apply(Fixture.record(command.command_id));
    try std.testing.expectEqual(OrderState.canceled, run.shard.order_state);
    try std.testing.expectEqual(oms_module.OrderState.rejected, run.shard.oms.orders[0].state);
}

test "bounded multi instrument OMS closes lifecycle and partial policy" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 10, .policy = .independent, .count = 2 };
    group.members[0] = .{ .intent_sequence = 10, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000), .reservation = fixtureReservation(5_000_000) };
    group.members[1] = .{ .intent_sequence = 11, .operation = .place, .instrument = swap_instrument, .quantity = 20, .limit_price = fixtureOmsPrice(swap_instrument, 50_100_000), .reservation = fixtureReservation(1_000_000) };
    const placed = try run.shard.applyInternal(atGroup(12, .{ .identity = 10, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 2), placed.oms_commands.len);
    try std.testing.expect(placed.oms_commands[0].instrument != placed.oms_commands[1].instrument);

    var dispatch: oms_module.DispatchBatch = .{ .count = 2 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .submitted };
    dispatch.items[1] = .{ .command_id = placed.oms_commands[1].command_id, .state = .unknown };
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    try std.testing.expectEqual(oms_module.OrderState.unknown, run.shard.oms.orders[1].state);
    try std.testing.expect(run.shard.oms.orders[1].reservation_active);
    _ = try run.shard.applyInternal(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{
        .reconciliation_id = 1,
        .order_id = 2,
        .status = .found_live,
        .revision = 1,
        .cumulative_quantity = 0,
        .remaining_quantity = 20,
    } } }));

    _ = try run.shard.applyInternal(atGroup(15, .{ .identity = 1, .payload = .{ .oms_execution_report = .{
        .report_id = 1,
        .order_id = 1,
        .revision = 1,
        .status = .accepted,
        .cumulative_quantity = 0,
        .remaining_quantity = 100,
    } } }));
    var amend: oms_module.IntentGroup = .{ .first_intent_sequence = 12, .count = 1 };
    amend.members[0] = .{ .intent_sequence = 12, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_900_000), .reservation = fixtureReservation(4_000_000) };
    const amended = try run.shard.applyInternal(atGroup(16, .{ .identity = 12, .payload = .{ .oms_intent_group = amend } }));
    try std.testing.expectEqual(oms_module.Operation.amend, amended.oms_commands[0].operation);
    try std.testing.expectEqual(@as(u32, 2), run.shard.oms.orders[0].revision);
    try std.testing.expectEqual(placed.oms_commands[0].reservation.atoms, run.shard.oms.orders[0].reservation.atoms);
    try std.testing.expectError(error.StaleOrderRevision, run.shard.applyInternal(atGroup(17, .{ .identity = 13, .payload = .{ .oms_intent_group = amend } })));

    var cancel: oms_module.IntentGroup = .{ .first_intent_sequence = 13, .count = 1 };
    cancel.members[0] = .{ .intent_sequence = 13, .operation = .cancel, .instrument = swap_instrument, .target_order_id = 2, .expected_revision = 1 };
    const canceled = try run.shard.applyInternal(atGroup(18, .{ .identity = 13, .payload = .{ .oms_intent_group = cancel } }));
    try std.testing.expectEqual(oms_module.Operation.cancel, canceled.oms_commands[0].operation);
    _ = try run.shard.applyInternal(atGroup(19, .{ .identity = 2, .payload = .{ .oms_execution_report = .{
        .report_id = 2,
        .order_id = 2,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = 0,
        .remaining_quantity = 20,
    } } }));
    const digest = run.shard.canonicalStateDigest();
    var replayed: ReplayTradingShard = .{};
    for (genesis) |event| _ = try replayed.apply(event);
    _ = try replayed.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    _ = try replayed.apply(atGroup(12, .{ .identity = 10, .payload = .{ .oms_intent_group = group } }));
    _ = try replayed.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    _ = try replayed.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 2, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 20 } } }));
    _ = try replayed.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    _ = try replayed.apply(atGroup(16, .{ .identity = 12, .payload = .{ .oms_intent_group = amend } }));
    _ = try replayed.apply(atGroup(18, .{ .identity = 13, .payload = .{ .oms_intent_group = cancel } }));
    _ = try replayed.apply(atGroup(19, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 2, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 20 } } }));
    try std.testing.expectEqualSlices(u8, &digest, &replayed.canonicalStateDigest());
}

test "CancelConfirmCreate never overlaps and records predecessor" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 20, .count = 1 };
    place.members[0] = .{ .intent_sequence = 20, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000), .reservation = fixtureReservation(5_000_000) };
    const placed = try run.shard.applyInternal(atGroup(12, .{ .identity = 20, .payload = .{ .oms_intent_group = place } }));
    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .submitted };
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    _ = try run.shard.applyInternal(atGroup(14, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));

    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 21, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 21, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 75, .limit_price = fixtureOmsPrice(spot_instrument, 49_800_000), .native_amend = false, .allow_cancel_confirm_create = true, .reservation = fixtureReservation(3_750_000) };
    const cancel_first = try run.shard.applyInternal(atGroup(15, .{ .identity = 21, .payload = .{ .oms_intent_group = replace } }));
    try std.testing.expectEqual(@as(usize, 1), cancel_first.oms_commands.len);
    try std.testing.expectEqual(oms_module.Operation.cancel, cancel_first.oms_commands[0].operation);
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try std.testing.expect(run.shard.oms.orders[0].reservation_active);
    var cancel_unknown: oms_module.DispatchBatch = .{ .count = 1 };
    cancel_unknown.items[0] = .{ .command_id = cancel_first.oms_commands[0].command_id, .state = .unknown };
    _ = try run.shard.applyInternal(atGroup(16, .{ .identity = 2, .payload = .{ .oms_dispatch_batch = cancel_unknown } }));
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    _ = try run.shard.applyInternal(atGroup(17, .{ .identity = 2, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 2, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 25, .remaining_quantity = 75 } } }));
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    const replacement = try run.shard.applyInternal(atGroup(18, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 25, .remaining_quantity = 75 } } }));
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(u64, 1), run.shard.oms.orders[1].predecessor_order_id);
    try std.testing.expectEqual(oms_module.Operation.place, replacement.oms_commands[0].operation);
    try std.testing.expect(!run.shard.oms.orders[0].reservation_active);
    try std.testing.expect(run.shard.oms.orders[1].reservation_active);
    _ = try run.shard.applyInternal(atGroup(19, .{ .identity = 3, .payload = .{ .oms_execution_report = .{ .report_id = 3, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 25, .remaining_quantity = 75 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    try std.testing.expectError(error.ConflictingReportIdentity, run.shard.applyInternal(atGroup(20, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 100, .remaining_quantity = 0 } } })));
}

test "IntentGroup batch results remain itemized" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 30, .policy = .cancel_remaining, .count = 3 };
    for (group.members[0..3], 0..) |*member, index| {
        const instrument = if (index == 1) swap_instrument else spot_instrument;
        member.* = .{ .intent_sequence = 30 + index, .operation = .place, .instrument = instrument, .quantity = 10, .limit_price = fixtureOmsPrice(instrument, 50_000_000), .reservation = fixtureReservation(500_000) };
    }
    const commands = try run.shard.applyInternal(atGroup(12, .{ .identity = 30, .payload = .{ .oms_intent_group = group } }));
    var batch: oms_module.DispatchBatch = .{ .count = 3 };
    batch.items[0] = .{ .command_id = commands.oms_commands[0].command_id, .state = .submitted };
    batch.items[1] = .{ .command_id = commands.oms_commands[1].command_id, .state = .submitted, .definite_reject = true };
    batch.items[2] = .{ .command_id = commands.oms_commands[2].command_id, .state = .not_sent };
    const outcome = try run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = batch } }));
    try std.testing.expectEqual(oms_module.OrderState.pending_cancel, run.shard.oms.orders[0].state);
    try std.testing.expectEqual(oms_module.OrderState.rejected, run.shard.oms.orders[1].state);
    try std.testing.expectEqual(oms_module.OrderState.rejected, run.shard.oms.orders[2].state);
    try std.testing.expect(run.shard.oms.orders[0].reservation_active);
    try std.testing.expect(!run.shard.oms.orders[1].reservation_active);
    try std.testing.expect(!run.shard.oms.orders[2].reservation_active);
    try std.testing.expectEqual(@as(usize, 1), outcome.oms_commands.len);
    try std.testing.expectEqual(oms_module.Operation.cancel, outcome.oms_commands[0].operation);
}

test "layered risk owns reservations until authoritative absence" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 40, .count = 1 };
    group.members[0] = .{ .intent_sequence = 40, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000), .reservation = fixtureReservation(1) };
    const placed = try run.shard.applyInternal(atGroup(12, .{ .identity = 40, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(i128, 500_375), run.shard.oms.orders[0].reservation.atoms);
    try std.testing.expectEqual(@as(i64, 500_375), run.shard.layered_risk_reserved_micros);

    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .unknown };
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    try std.testing.expectEqual(@as(i64, 500_375), run.shard.layered_risk_reserved_micros);
    _ = try run.shard.applyInternal(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .confirmed_absent, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(@as(i64, 0), run.shard.layered_risk_reserved_micros);

    var limited = try startScenario();
    _ = try limited.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    limited.shard.strategy_limit_micros = 500_000;
    try std.testing.expectError(error.StrategyLimitExceeded, limited.shard.applyInternal(atGroup(12, .{ .identity = 40, .payload = .{ .oms_intent_group = group } })));
    try std.testing.expectEqual(@as(u8, 0), limited.shard.oms.order_count);
}

test "unknown OMS dispatch blocks a later place until the order is resolved" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var first: oms_module.IntentGroup = .{ .first_intent_sequence = 90, .count = 1 };
    first.members[0] = .{
        .intent_sequence = 90,
        .operation = .place,
        .instrument = spot_instrument,
        .quantity = 10,
        .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000),
    };
    const placed = try run.shard.applyInternal(atGroup(12, .{ .identity = 90, .payload = .{ .oms_intent_group = first } }));
    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .unknown };
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));

    const before = run.shard.canonicalStateDigest();
    var next: oms_module.IntentGroup = .{ .first_intent_sequence = 91, .count = 1 };
    next.members[0] = .{
        .intent_sequence = 91,
        .operation = .place,
        .instrument = swap_instrument,
        .quantity = 10,
        .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000),
    };
    try std.testing.expectError(error.UncertainOrderBlocksSend, run.shard.applyInternal(atGroup(14, .{
        .identity = 91,
        .payload = .{ .oms_intent_group = next },
    })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
}

test "TradingShard preserves maintenance margin in the projected buffer" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 45, .count = 1 };
    group.members[0] = .{ .intent_sequence = 45, .operation = .place, .instrument = swap_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 45, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(i64, 11_375), run.shard.layered_risk_reserved_micros);
    try std.testing.expectEqual(@as(i64, 19_999_982_750), run.shard.portfolio_margin_buffer_micros);
}

test "rejected IntentGroup leaves authoritative state unchanged" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    const before = run.shard.canonicalStateDigest();
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 50, .count = 2 };
    group.members[0] = .{ .intent_sequence = 50, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    group.members[1] = .{ .intent_sequence = 51, .operation = .cancel, .instrument = spot_instrument, .target_order_id = 999, .expected_revision = 1 };
    try std.testing.expectError(error.UnknownOrder, run.shard.applyInternal(atGroup(12, .{ .identity = 50, .payload = .{ .oms_intent_group = group } })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "rejected dispatch batch leaves authoritative state unchanged" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 55, .count = 1 };
    group.members[0] = .{ .intent_sequence = 55, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 55, .payload = .{ .oms_intent_group = group } }));
    const before = run.shard.canonicalStateDigest();
    var batch: oms_module.DispatchBatch = .{ .count = 2 };
    batch.items[0] = .{ .command_id = 1, .state = .unknown };
    batch.items[1] = .{ .command_id = 999, .state = .submitted };
    try std.testing.expectError(error.UnknownCommand, run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = batch } })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "rejected execution report leaves authoritative state unchanged" {
    var run = try startScenario();
    const before = run.shard.canonicalStateDigest();
    try std.testing.expectError(error.UnknownOrder, run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .oms_execution_report = .{
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
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 60, .count = 1 };
    group.members[0] = .{ .intent_sequence = 60, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 60, .payload = .{ .oms_intent_group = group } }));
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    _ = try run.shard.applyInternal(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    _ = try run.shard.applyInternal(atGroup(15, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectError(error.ConflictingReportIdentity, run.shard.applyInternal(atGroup(16, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 10, .remaining_quantity = 0 } } })));
}

test "CancelConfirmCreate re-risks replacement against latest facts" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 70, .count = 1 };
    place.members[0] = .{ .intent_sequence = 70, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 70, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 71, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 71, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000), .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try run.shard.applyInternal(atGroup(14, .{ .identity = 71, .payload = .{ .oms_intent_group = replace } }));
    run.shard.strategy_limit_micros = 100;
    const result = try run.shard.applyInternal(atGroup(15, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 0), result.oms_commands.len);
}

test "qualified command carries independently inferred reduce-only flags" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    run.shard.portfolio_position.quantity = 10;
    run.shard.exchange_position.quantity = -5;
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 75, .count = 1 };
    group.members[0] = .{ .intent_sequence = 75, .operation = .place, .instrument = swap_instrument, .side = .sell, .quantity = 8, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    const result = try run.shard.applyInternal(atGroup(12, .{ .identity = 75, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), result.oms_commands.len);
    try std.testing.expect(result.oms_commands[0].portfolio_reduce_only);
    try std.testing.expect(!result.oms_commands[0].venue_reduce_only);
}

test "SPOT asset risk is isolated from SWAP positions" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    run.shard.portfolio_position.quantity = 10;
    run.shard.exchange_position.quantity = 10;
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 79, .count = 1 };
    group.members[0] = .{ .intent_sequence = 79, .operation = .place, .instrument = spot_instrument, .side = .sell, .quantity = 1, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    try std.testing.expectError(error.InsufficientSpotAsset, run.shard.applyInternal(atGroup(12, .{ .identity = 79, .payload = .{ .oms_intent_group = group } })));
}

test "economic fills derive ownership from OMS and close Portfolio Exchange ledgers" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 79, .count = 1 };
    group.members[0] = .{ .intent_sequence = 79, .operation = .place, .instrument = swap_instrument, .side = .buy, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 79, .payload = .{ .oms_intent_group = group } }));
    run.shard.risk_lease_micros = 1;
    run.shard.risk_lease_remaining_micros = 1;
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .economic_fill = .{ .fill_id = 1, .order_id = 1, .quantity = 4, .price_micros = 50_000_000, .fee_micros = 15 } } }));
    _ = try run.shard.applyInternal(atGroup(14, .{ .identity = 2, .payload = .{ .economic_fill = .{ .fill_id = 2, .order_id = 1, .quantity = 6, .price_micros = 51_000_000, .fee_micros = 20, .rebate_micros = 5 } } }));
    const summary = run.shard.economicSummary();
    try std.testing.expectEqual(@as(i64, 10), summary.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, 50_600), summary.portfolio.swap.open_cost_micros);
    try std.testing.expectEqual(@as(i64, 1_114), summary.portfolio.margin_micros);
    try std.testing.expectEqual(@as(i64, 1_012), summary.exchange.margin_micros);
    try std.testing.expectEqual(@as(i64, 35), summary.portfolio.fee_micros);
    try std.testing.expectEqual(@as(i64, 5), summary.portfolio.rebate_micros);
    try std.testing.expectEqual(@as(u8, 10), summary.ledger_transactions);
    try std.testing.expect(run.shard.risk_lease_remaining_micros < 0);
    try std.testing.expectEqual(summary.portfolio.swap.quantity, run.shard.portfolio_position.quantity);
    try std.testing.expectEqual(summary.portfolio.usdt_balance_micros, run.shard.portfolio_cash_micros);
    try std.testing.expect(!summary.reconciliation_break);
}

test "funding forced execution and snapshots preserve auditable local economics" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    const before = run.shard.economicSummary();
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 10, .payload = .{ .funding_settlement = .{ .settlement_id = 10, .amount_micros = -25 } } }));
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 11, .payload = .{ .venue_forced_execution = .{ .execution_id = 11, .side = .sell, .quantity = 2, .price_micros = 50_000_000, .fee_micros = 3, .penalty_micros = 2 } } }));
    const projected = run.shard.economicSummary();
    try std.testing.expectEqual(@as(i64, 0), projected.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, -2), projected.exchange.swap.quantity);
    try std.testing.expectEqual(@as(i64, -30), projected.suspense_usdt_micros);
    try std.testing.expectEqual(projected.exchange.swap.quantity, run.shard.exchange_position.quantity);
    try std.testing.expectEqual(projected.exchange.usdt_balance_micros, run.shard.exchange_cash_micros);
    try std.testing.expect(projected.reconciliation_break);
    try std.testing.expectEqual(@as(u8, 4), projected.ledger_transactions);

    const local_exchange = projected.exchange;
    _ = try run.shard.applyInternal(atGroup(14, .{ .identity = 12, .payload = .{ .economic_account_snapshot = .{ .snapshot_id = 12, .usdt_balance_micros = before.exchange.usdt_balance_micros, .spot_asset_quantity = 99, .swap_position_quantity = 99, .margin_micros = 99 } } }));
    try std.testing.expectEqualDeep(local_exchange, run.shard.economicSummary().exchange);
    try std.testing.expectError(error.ConflictingEconomicIdentity, run.shard.applyInternal(atGroup(15, .{ .identity = 10, .payload = .{ .funding_settlement = .{ .settlement_id = 10, .amount_micros = -26 } } })));
}

test "duplicate economic facts are no-op at the TradingShard seam" {
    var run = try startScenario();
    const funding = atGroup(11, .{ .identity = 30, .payload = .{ .funding_settlement = .{ .settlement_id = 30, .amount_micros = -5 } } });
    _ = try run.shard.applyInternal(funding);
    const before = run.shard.canonicalStateDigest();
    const result = try run.shard.applyInternal(funding);
    try std.testing.expectEqual(@as(usize, 0), result.facts.len);
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "CancelConfirmCreate accepts authoritative reconciliation as confirmation" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 76, .count = 1 };
    place.members[0] = .{ .intent_sequence = 76, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 76, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 77, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 77, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000), .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try run.shard.applyInternal(atGroup(14, .{ .identity = 77, .payload = .{ .oms_intent_group = replace } }));
    const result = try run.shard.applyInternal(atGroup(15, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .confirmed_absent, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 1), result.oms_commands.len);
    try std.testing.expectEqual(@as(u64, 1), result.oms_commands[0].predecessor_order_id);
}

test "older reconciliation identity still rejects semantic conflict" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 78, .count = 1 };
    place.members[0] = .{ .intent_sequence = 78, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 78, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.applyInternal(atGroup(13, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .unresolved, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    _ = try run.shard.applyInternal(atGroup(14, .{ .identity = 2, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 2, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectError(error.ConflictingReconciliationIdentity, run.shard.applyInternal(atGroup(15, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } })));
}

test "multiple SPOT and SWAP orders independently close place amend and cancel" {
    var run = try startScenario();
    _ = try run.shard.applyInternal(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000 } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 80, .count = 4 };
    place.members[0] = .{ .intent_sequence = 80, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    place.members[1] = .{ .intent_sequence = 81, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    place.members[2] = .{ .intent_sequence = 82, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    place.members[3] = .{ .intent_sequence = 83, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try run.shard.applyInternal(atGroup(12, .{ .identity = 80, .payload = .{ .oms_intent_group = place } }));
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |order_id, index| _ = try run.shard.applyInternal(atGroup(13 + index, .{ .identity = 1 + index, .payload = .{ .oms_execution_report = .{ .report_id = 1 + index, .order_id = order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));

    var amend: oms_module.IntentGroup = .{ .first_intent_sequence = 84, .count = 4 };
    amend.members[0] = .{ .intent_sequence = 84, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 8, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000) };
    amend.members[1] = .{ .intent_sequence = 85, .operation = .amend, .instrument = spot_instrument, .target_order_id = 2, .expected_revision = 1, .quantity = 8, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000) };
    amend.members[2] = .{ .intent_sequence = 86, .operation = .amend, .instrument = swap_instrument, .target_order_id = 3, .expected_revision = 1, .quantity = 8, .limit_price = fixtureOmsPrice(swap_instrument, 49_000_000) };
    amend.members[3] = .{ .intent_sequence = 87, .operation = .amend, .instrument = swap_instrument, .target_order_id = 4, .expected_revision = 1, .quantity = 8, .limit_price = fixtureOmsPrice(swap_instrument, 49_000_000) };
    _ = try run.shard.applyInternal(atGroup(17, .{ .identity = 84, .payload = .{ .oms_intent_group = amend } }));
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |order_id, index| _ = try run.shard.applyInternal(atGroup(18 + index, .{ .identity = 5 + index, .payload = .{ .oms_execution_report = .{ .report_id = 5 + index, .order_id = order_id, .revision = 2, .status = .amended, .cumulative_quantity = 0, .remaining_quantity = 8 } } }));

    var cancel: oms_module.IntentGroup = .{ .first_intent_sequence = 88, .count = 4 };
    cancel.members[0] = .{ .intent_sequence = 88, .operation = .cancel, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 2 };
    cancel.members[1] = .{ .intent_sequence = 89, .operation = .cancel, .instrument = spot_instrument, .target_order_id = 2, .expected_revision = 2 };
    cancel.members[2] = .{ .intent_sequence = 90, .operation = .cancel, .instrument = swap_instrument, .target_order_id = 3, .expected_revision = 2 };
    cancel.members[3] = .{ .intent_sequence = 91, .operation = .cancel, .instrument = swap_instrument, .target_order_id = 4, .expected_revision = 2 };
    _ = try run.shard.applyInternal(atGroup(22, .{ .identity = 88, .payload = .{ .oms_intent_group = cancel } }));
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |order_id, index| _ = try run.shard.applyInternal(atGroup(23 + index, .{ .identity = 9 + index, .payload = .{ .oms_execution_report = .{ .report_id = 9 + index, .order_id = order_id, .revision = 2, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 8 } } }));
    for (run.shard.oms.orders[0..4]) |order| try std.testing.expectEqual(oms_module.OrderState.canceled, order.state);
    try std.testing.expectEqual(@as(i64, 0), run.shard.layered_risk_reserved_micros);
}

fn applyHealthyPreludeReplay(replay_shard: *ReplayTradingShard) !void {
    _ = try replay_shard.apply(atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000_000 } }));
    _ = try replay_shard.apply(snapshotAt(13, 100));
    _ = try replay_shard.apply(deltaAt(14, 100, 101, 49_850_000_000));
}
