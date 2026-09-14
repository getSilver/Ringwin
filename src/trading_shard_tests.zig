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

fn applyGenesisReplay(replay: *ReplayTradingShard) !void {
    for (genesis) |event| _ = try replay.apply(event);
    const digest = replay.canonicalStateDigest();
    _ = try replay.apply(atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 1,
        .activation_barrier = 0,
        .state_digest = digest,
    } } }));
}

fn establishSwapPosition(shard: *TradingShard, identity: u64, quantity: i64) !void {
    _ = try shard.apply(atGroup(identity, .{ .identity = identity, .payload = .{ .mark_price = .{
        .instrument = swap_instrument,
        .price_micros = 50_000_000,
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
        .price_micros = 50_000_000,
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
    const python_command = (try python.shard.apply(atGroup(15, .{
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
    try std.testing.expectError(error.IntentAuthorityMismatch, unauthorized.shard.apply(atGroup(15, .{
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
    try std.testing.expect((try applyLive(&run.shard, &run.decision_journal, atGroup(13, .{ .identity = 1, .payload = .{ .timer = fixture.timer(1) } }))) == null);
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
    try std.testing.expectError(error.DeRiskTargetViolation, run.shard.apply(atGroup(14, .{ .identity = 101, .payload = .{ .oms_intent_group = group } })));
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
        .price_micros = 49_900_000_000,
        .fee_micros = 30,
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
    try std.testing.expectError(error.TradingNotAuthorized, run.shard.apply(atGroup(18, .{ .identity = 110, .payload = .{ .oms_intent_group = buy_group } })));
    var reduce_group: oms_module.IntentGroup = .{ .first_intent_sequence = 111, .count = 1 };
    reduce_group.members[0] = .{ .intent_sequence = 111, .operation = .place, .instrument = swap_instrument, .side = .sell, .portfolio_reduce_only = true, .quantity = 40, .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price) };
    try std.testing.expectError(error.TradingNotAuthorized, run.shard.apply(atGroup(19, .{ .identity = 111, .payload = .{ .oms_intent_group = reduce_group } })));
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
        .price_micros = 49_900_000_000,
        .fee_micros = 30,
    } } }));
    const preserved = run.shard.captureLifecycleEconomics();
    try std.testing.expectEqual(@as(i64, 100), preserved.positions.portfolio_swap.quantity);
    try std.testing.expectEqual(preserved.positions.portfolio_swap.quantity, preserved.positions.exchange_swap.quantity);

    const stopped = try applyLive(&run.shard, &run.decision_journal, lifecycleCommand(6, 7, .stop_keep_positions));
    _ = stopped;
    try expectKeepPositionsStopped(&run, preserved);
    var stop_buy_group: oms_module.IntentGroup = .{ .first_intent_sequence = 103, .count = 1 };
    stop_buy_group.members[0] = .{ .intent_sequence = 103, .operation = .place, .instrument = swap_instrument, .side = .buy, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, order_limit_price) };
    try std.testing.expectError(error.TradingNotAuthorized, run.shard.apply(atGroup(23, .{ .identity = 108, .payload = .{ .oms_intent_group = stop_buy_group } })));
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
    try std.testing.expectError(error.DeRiskTargetViolation, run.shard.apply(atGroup(25, .{ .identity = 110, .payload = .{ .oms_intent_group = increase_group } })));
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
                .schema_version = 1,
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
    try std.testing.expect((try engine.applyStable(&run.shard, &run.decision_journal, Fixture.record(2, .{ .execution_report = .{
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
    } }))) == null);
    const accepted_digest = run.shard.canonicalStateDigest();
    var conflicting_report = run.shard.last_canonical_report.?;
    conflicting_report.venue_update_time_utc_ns = 101;
    try std.testing.expectError(error.ConflictingReportIdentity, run.shard.apply(Fixture.record(2, .{ .execution_report = conflicting_report })));
    try std.testing.expectEqualSlices(u8, &accepted_digest, &run.shard.canonicalStateDigest());
    var unsupported_schema = Fixture.record(20, .{ .reconciliation_started = 20 });
    unsupported_schema.venue.envelope.schema_version = 2;
    try std.testing.expectError(error.UnsupportedSchema, run.shard.apply(unsupported_schema));
    try std.testing.expectEqualSlices(u8, &accepted_digest, &run.shard.canonicalStateDigest());
    try std.testing.expect((try engine.applyStable(&run.shard, &run.decision_journal, Fixture.record(3, .{ .fill = .{
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
    } }))) == null);
    try std.testing.expectEqual(@as(i64, happy_order_quantity), run.shard.economicSummary().portfolio.swap.quantity);
    try std.testing.expectEqual(canonical.LiquidityRole.maker, run.shard.last_canonical_fill.?.liquidity);
    try std.testing.expectEqual(@as(i128, 12), run.shard.last_canonical_fill.?.fee.?.atoms);
    try std.testing.expectEqual(@as(i128, 2), run.shard.last_canonical_fill.?.rebate.?.atoms);
    try std.testing.expectEqual(@as(i128, 7), run.shard.last_canonical_fill.?.realized_pnl.?.atoms);
    try std.testing.expectEqual(@as(?u64, 100), run.shard.last_canonical_fill.?.venue_fill_time_utc_ns);
    try std.testing.expectEqual(@as(?u64, 99), run.shard.last_canonical_report.?.venue_update_time_utc_ns);
    try std.testing.expectEqual(@as(?u64, 98), run.shard.last_canonical_report.?.venue_create_time_utc_ns);
    try std.testing.expectEqual(canonical.PositionSide.long, run.shard.last_canonical_report.?.position_side.?);
    try std.testing.expectEqual(canonical.CanonicalRejectReason.other_venue_reject, run.shard.last_canonical_report.?.reject_reason.?);
    try std.testing.expectEqual(false, run.shard.last_canonical_report.?.portfolio_reduce_only.?);
    try std.testing.expect(run.shard.last_canonical_report.?.margin_mode_isolated.?);
    try run.decision_journal.seal();
    _ = try assertReplayEquivalent(run);
}

test "account bootstrap snapshot is normalized before stable journal replay" {
    const Envelope = struct {
        fn record(sequence: u64, event: canonical.Payload) engine.CanonicalEvent {
            return .{ .venue = .{ .envelope = .{
                .event_type = @intFromEnum(canonical.eventType(event)),
                .schema_version = 1,
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
                .schema_version = 1,
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
                .schema_version = 1,
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
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
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

    var cancel: oms_module.IntentGroup = .{ .first_intent_sequence = 13, .count = 1 };
    cancel.members[0] = .{ .intent_sequence = 13, .operation = .cancel, .instrument = swap_instrument, .target_order_id = 2, .expected_revision = 1 };
    const canceled = try run.shard.apply(atGroup(18, .{ .identity = 13, .payload = .{ .oms_intent_group = cancel } }));
    try std.testing.expectEqual(oms_module.Operation.cancel, canceled.oms_commands[0].operation);
    _ = try run.shard.apply(atGroup(19, .{ .identity = 2, .payload = .{ .oms_execution_report = .{
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
    _ = try replayed.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    _ = try replayed.apply(atGroup(12, .{ .identity = 10, .payload = .{ .oms_intent_group = group } }));
    _ = try replayed.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    _ = try replayed.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 2, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 20 } } }));
    _ = try replayed.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    _ = try replayed.apply(atGroup(16, .{ .identity = 12, .payload = .{ .oms_intent_group = amend } }));
    _ = try replayed.apply(atGroup(18, .{ .identity = 13, .payload = .{ .oms_intent_group = cancel } }));
    _ = try replayed.apply(atGroup(19, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 2, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 20 } } }));
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
        atGroup(14, .{ .identity = 1, .payload = .{ .economic_fill = .{ .fill_id = 1, .order_id = 1, .quantity = 40, .price_micros = 30_000_000 } } }),
        atGroup(15, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 100, .remaining_quantity = 0 } } }),
        atGroup(16, .{ .identity = 2, .payload = .{ .economic_fill = .{ .fill_id = 2, .order_id = 1, .quantity = 60, .price_micros = 30_000_000 } } }),
        atGroup(17, .{ .identity = 3, .payload = .{ .oms_execution_report = .{ .report_id = 3, .order_id = 2, .revision = 1, .status = .filled, .cumulative_quantity = 10, .remaining_quantity = 0 } } }),
        atGroup(18, .{ .identity = 3, .payload = .{ .economic_fill = .{ .fill_id = 3, .order_id = 2, .quantity = 10, .price_micros = 50_000_000 } } }),
        atGroup(19, .{ .identity = 5, .payload = .{ .mark_price = .{ .instrument = spot_instrument, .price_micros = 40_000_000 } } }),
        atGroup(20, .{ .identity = 6, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 60_000_000 } } }),
    };

    var live = prefix.shard;
    var tail = engine.journal.Journal.initAt(prefix.decision_journal.last_sequence + 1);
    for (tail_events) |event| _ = try engine.applyStable(&live, &tail, event);
    try tail.seal();
    try std.testing.expectEqual(oms_module.OrderState.filled, live.oms.orders[0].state);
    try std.testing.expectEqual(oms_module.OrderState.filled, live.oms.orders[1].state);
    try std.testing.expectEqual(@as(i64, 100), live.economicSummary().portfolio.spot.quantity);
    try std.testing.expectEqual(@as(i64, 10), live.economicSummary().portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, 10_010), live.economicSummary().portfolio.unrealized_pnl_micros);

    var replayed: ReplayTradingShard = .{};
    try applyGenesisReplay(&replayed);
    _ = try replayed.apply(place);
    for (tail_events) |event| _ = try replayed.apply(event);
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &replayed.canonicalStateDigest());
    const recovered = try TradingShard.restore(snapshot, tail.bytes());
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());

    const before_mismatch = live.canonicalStateDigest();
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
    try std.testing.expectEqualSlices(u8, &before_mismatch, &live.canonicalStateDigest());
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
    account_bootstrap.venue.envelope.source_stream = 2;
    account_bootstrap.venue.envelope.raw_evidence.stream = 2;
    _ = try live.shard.apply(account_bootstrap);
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 220, .count = 1 };
    group.members[0] = .{ .intent_sequence = 220, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    const place = atGroup(12, .{ .identity = 220, .payload = .{ .oms_intent_group = group } });
    const placed = try live.shard.apply(place);
    try std.testing.expectEqual(@as(usize, 1), placed.oms_commands.len);
    const proved = placed.oms_commands[0];
    try std.testing.expect(proved.risk_decision_identity != proved.reservation_identity);
    try std.testing.expectEqual(shard_event.EventKind.risk_accepted, live.shard.trace.events[proved.risk_decision_identity - 1].kind);
    try std.testing.expectEqual(shard_event.EventKind.risk_reservation_created, live.shard.trace.events[proved.reservation_identity - 1].kind);

    var implementation: simulated_venue.SimulatedVenue = .{};
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1 });
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
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(&live.shard, proved.command_id, 3 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 1), (try durable_store.recover(undefined, stream)).committed_barrier);
    try std.testing.expectEqual(.accepted, try gateway.sendFromShard(&live.shard, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 2), (try durable_store.recover(undefined, stream)).committed_barrier);
    try std.testing.expectEqual(@as(u64, 1), gateway.send_attempt_count);
    var recovered_gateway: execution_gateway.Gateway = .{};
    try recovered_gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    try recovered_gateway.attachRecoveredDurableDispatch(durable_store, undefined, stream);
    try std.testing.expectError(error.NotSent, recovered_gateway.sendFromShard(&live.shard, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 0), recovered_gateway.send_attempt_count);
    var output: [execution_gateway.max_routes]canonical.AdapterOutputBatch = undefined;
    try std.testing.expectEqual(@as(u8, 1), try gateway.drainFair(&output));
    for (output[0].slice()) |event| _ = try live.shard.apply(.{ .venue = event });
    try std.testing.expectEqual(oms_module.OrderState.filled, live.shard.oms.orders[0].state);
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(&live.shard, proved.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 1), gateway.send_attempt_count);
    try std.testing.expectEqual(@as(i64, 10), live.shard.economicSummary().portfolio.swap.quantity);

    var replayed: ReplayTradingShard = .{};
    try applyGenesisReplay(&replayed);
    _ = try replayed.apply(capability);
    _ = try replayed.apply(account_bootstrap);
    _ = try replayed.apply(place);
    for (output[0].slice()) |event| _ = try replayed.apply(.{ .venue = event });
    try std.testing.expectEqualSlices(u8, &live.shard.canonicalStateDigest(), &replayed.canonicalStateDigest());
    comptime std.debug.assert(!@hasField(ReplayTradingShard, "gateway"));
}

test "CancelConfirmCreate never overlaps and records predecessor" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
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
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(u64, 1), run.shard.oms.orders[1].predecessor_order_id);
    try std.testing.expectEqual(oms_module.Operation.place, replacement.oms_commands[0].operation);
    try std.testing.expect(!run.shard.oms.orders[0].reservation_active);
    try std.testing.expect(run.shard.oms.orders[1].reservation_active);
    try std.testing.expectError(error.TerminalFactConflict, run.shard.apply(atGroup(19, .{ .identity = 3, .payload = .{ .oms_execution_report = .{ .report_id = 3, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 25, .remaining_quantity = 75 } } })));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    try std.testing.expectError(error.ConflictingReportIdentity, run.shard.apply(atGroup(20, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 100, .remaining_quantity = 0 } } })));
}

test "IntentGroup batch results remain itemized" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
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

test "layered risk owns reservations until authoritative absence" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 40, .count = 1 };
    group.members[0] = .{ .intent_sequence = 40, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000), .reservation = fixtureReservation(1) };
    const placed = try run.shard.apply(atGroup(12, .{ .identity = 40, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(i128, 51), run.shard.oms.orders[0].reservation.atoms);
    try std.testing.expectEqual(@as(i64, 51), run.shard.layered_risk_reserved_micros);

    var dispatch: oms_module.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = placed.oms_commands[0].command_id, .state = .unknown };
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_dispatch_batch = dispatch } }));
    try std.testing.expectEqual(@as(i64, 51), run.shard.layered_risk_reserved_micros);
    _ = try run.shard.apply(atGroup(14, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .confirmed_absent, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(@as(i64, 0), run.shard.layered_risk_reserved_micros);

    var limited = try startScenario();
    _ = try limited.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    _ = try limited.shard.apply(atGroup(12, .{ .identity = 2, .payload = .{ .risk_lease_granted = .{
        .lease_identity = 2,
        .version = 2,
        .amount_micros = 1_000,
        .strategy_limit_micros = 50,
        .portfolio_limit_micros = 1_000,
        .exchange_account_limit_micros = 1_000,
        .global_limit_micros = 1_000,
    } } }));
    try std.testing.expectError(error.StrategyLimitExceeded, limited.shard.apply(atGroup(12, .{ .identity = 40, .payload = .{ .oms_intent_group = group } })));
    try std.testing.expectEqual(@as(u8, 0), limited.shard.oms.order_count);
}

test "unknown OMS dispatch blocks a later place until the order is resolved" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
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
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 45, .count = 1 };
    group.members[0] = .{ .intent_sequence = 45, .operation = .place, .instrument = swap_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 45, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(i64, 11_375), run.shard.layered_risk_reserved_micros);
    try std.testing.expectEqual(@as(i64, 19_999_982_750), run.shard.portfolio_margin_buffer_micros);
}

test "rejected IntentGroup leaves authoritative state unchanged" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    const before = run.shard.canonicalStateDigest();
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 50, .count = 2 };
    group.members[0] = .{ .intent_sequence = 50, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    group.members[1] = .{ .intent_sequence = 51, .operation = .cancel, .instrument = spot_instrument, .target_order_id = 999, .expected_revision = 1 };
    try std.testing.expectError(error.UnknownOrder, run.shard.apply(atGroup(12, .{ .identity = 50, .payload = .{ .oms_intent_group = group } })));
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "rejected dispatch batch leaves authoritative state unchanged" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
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
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
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
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
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
        .amount_micros = 1_000,
        .strategy_limit_micros = 10,
        .portfolio_limit_micros = 1_000,
        .exchange_account_limit_micros = 1_000,
        .global_limit_micros = 1_000,
    } } }));
    const result = try run.shard.apply(atGroup(15, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(oms_module.OrderState.canceled, run.shard.oms.orders[0].state);
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 0), result.oms_commands.len);
}

test "CancelConfirmCreate cannot recreate a fenced strategy" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 80, .count = 1 };
    place.members[0] = .{ .intent_sequence = 80, .strategy_instance = 1, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 80, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 81, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 81, .strategy_instance = 1, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000), .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try run.shard.apply(atGroup(14, .{ .identity = 81, .payload = .{ .oms_intent_group = replace } }));
    _ = try run.shard.apply(atGroup(15, .{ .identity = 82, .payload = .{ .strategy_cutover_fence = .{ .strategy_instance = 1 } } }));
    _ = try run.shard.apply(atGroup(16, .{ .identity = 2, .payload = .{ .oms_execution_report = .{ .report_id = 2, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(@as(u8, 1), run.shard.oms.order_count);
    try std.testing.expect(run.shard.oms.orders[0].replacement == null);
}

test "forced position divergence blocks new qualification" {
    var run = try startScenario();
    try establishSwapPosition(&run.shard, 600, 10);
    _ = try run.shard.apply(atGroup(604, .{ .identity = 601, .payload = .{ .venue_forced_execution = .{
        .execution_id = 601,
        .side = .sell,
        .quantity = 15,
        .price_micros = 50_000_000,
    } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 75, .count = 1 };
    group.members[0] = .{ .intent_sequence = 75, .operation = .place, .instrument = swap_instrument, .side = .sell, .quantity = 8, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    try std.testing.expectError(error.TradingNotAuthorized, run.shard.apply(atGroup(12, .{ .identity = 75, .payload = .{ .oms_intent_group = group } })));
    try std.testing.expectEqual(@as(i64, 10), run.shard.economicSummary().portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, -5), run.shard.economicSummary().exchange.swap.quantity);
}

test "SPOT asset risk is isolated from SWAP positions" {
    var run = try startScenario();
    try establishSwapPosition(&run.shard, 700, 10);
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 79, .count = 1 };
    group.members[0] = .{ .intent_sequence = 79, .operation = .place, .instrument = spot_instrument, .side = .sell, .quantity = 1, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    try std.testing.expectError(error.InsufficientSpotAsset, run.shard.apply(atGroup(12, .{ .identity = 79, .payload = .{ .oms_intent_group = group } })));
}

test "economic fills derive ownership from OMS and close Portfolio Exchange ledgers" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    var group: oms_module.IntentGroup = .{ .first_intent_sequence = 79, .count = 1 };
    group.members[0] = .{ .intent_sequence = 79, .operation = .place, .instrument = swap_instrument, .side = .buy, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 79, .payload = .{ .oms_intent_group = group } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .economic_fill = .{ .fill_id = 1, .order_id = 1, .quantity = 4, .price_micros = 50_000_000, .fee_micros = 15 } } }));
    _ = try run.shard.apply(atGroup(14, .{ .identity = 2, .payload = .{ .economic_fill = .{ .fill_id = 2, .order_id = 1, .quantity = 6, .price_micros = 51_000_000, .fee_micros = 20, .rebate_micros = 5 } } }));
    const summary = run.shard.economicSummary();
    try std.testing.expectEqual(@as(i64, 10), summary.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, 50_600), summary.portfolio.swap.open_cost_micros);
    try std.testing.expectEqual(@as(i64, 1_114), summary.portfolio.margin_micros);
    try std.testing.expectEqual(@as(i64, 1_012), summary.exchange.margin_micros);
    try std.testing.expectEqual(@as(i64, 35), summary.portfolio.fee_micros);
    try std.testing.expectEqual(@as(i64, 5), summary.portfolio.rebate_micros);
    try std.testing.expectEqual(@as(u8, 10), summary.ledger_transactions);
    try std.testing.expect(try run.shard.riskLeaseRemainingMicros() < run.shard.risk_lease_micros);
    try std.testing.expectEqual(summary.portfolio.swap.quantity, run.shard.economicSummary().portfolio.swap.quantity);
    try std.testing.expectEqual(summary.portfolio.usdt_balance_micros, run.shard.economicSummary().portfolio.usdt_balance_micros);
    try std.testing.expect(!summary.reconciliation_break);
}

test "funding forced execution and snapshots preserve auditable local economics" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    const before = run.shard.economicSummary();
    _ = try run.shard.apply(atGroup(12, .{ .identity = 10, .payload = .{ .funding_settlement = .{ .settlement_id = 10, .amount_micros = -25 } } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 11, .payload = .{ .venue_forced_execution = .{ .execution_id = 11, .side = .sell, .quantity = 2, .price_micros = 50_000_000, .fee_micros = 3, .penalty_micros = 2 } } }));
    const projected = run.shard.economicSummary();
    try std.testing.expectEqual(@as(i64, 0), projected.portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, -2), projected.exchange.swap.quantity);
    try std.testing.expectEqual(@as(i64, -30), projected.suspense_usdt_micros);
    try std.testing.expectEqual(projected.exchange.swap.quantity, run.shard.economicSummary().exchange.swap.quantity);
    try std.testing.expectEqual(projected.exchange.usdt_balance_micros, run.shard.economicSummary().exchange.usdt_balance_micros);
    try std.testing.expect(projected.reconciliation_break);
    try std.testing.expectEqual(@as(u8, 4), projected.ledger_transactions);

    const local_exchange = projected.exchange;
    _ = try run.shard.apply(atGroup(14, .{ .identity = 12, .payload = .{ .economic_account_snapshot = .{ .snapshot_id = 12, .usdt_balance_micros = before.exchange.usdt_balance_micros, .spot_asset_quantity = 99, .swap_position_quantity = 99, .margin_micros = 99 } } }));
    try std.testing.expectEqualDeep(local_exchange, run.shard.economicSummary().exchange);
    try std.testing.expectError(error.ConflictingEconomicIdentity, run.shard.apply(atGroup(15, .{ .identity = 10, .payload = .{ .funding_settlement = .{ .settlement_id = 10, .amount_micros = -26 } } })));
}

test "duplicate economic facts are no-op at the TradingShard seam" {
    var run = try startScenario();
    const funding = atGroup(11, .{ .identity = 30, .payload = .{ .funding_settlement = .{ .settlement_id = 30, .amount_micros = -5 } } });
    _ = try run.shard.apply(funding);
    const before = run.shard.canonicalStateDigest();
    const result = try run.shard.apply(funding);
    try std.testing.expectEqual(@as(usize, 0), result.facts.len);
    try std.testing.expectEqualSlices(u8, &before, &run.shard.canonicalStateDigest());
}

test "CancelConfirmCreate accepts authoritative reconciliation as confirmation" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 76, .count = 1 };
    place.members[0] = .{ .intent_sequence = 76, .operation = .place, .instrument = spot_instrument, .quantity = 100, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 76, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    var replace: oms_module.IntentGroup = .{ .first_intent_sequence = 77, .count = 1 };
    replace.members[0] = .{ .intent_sequence = 77, .operation = .amend, .instrument = spot_instrument, .target_order_id = 1, .expected_revision = 1, .quantity = 80, .limit_price = fixtureOmsPrice(spot_instrument, 49_000_000), .native_amend = false, .allow_cancel_confirm_create = true };
    _ = try run.shard.apply(atGroup(14, .{ .identity = 77, .payload = .{ .oms_intent_group = replace } }));
    const result = try run.shard.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .confirmed_absent, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    try std.testing.expectEqual(@as(u8, 2), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(usize, 1), result.oms_commands.len);
    try std.testing.expectEqual(@as(u64, 1), result.oms_commands[0].predecessor_order_id);
}

test "older reconciliation identity still rejects semantic conflict" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 78, .count = 1 };
    place.members[0] = .{ .intent_sequence = 78, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 78, .payload = .{ .oms_intent_group = place } }));
    _ = try run.shard.apply(atGroup(13, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .unresolved, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    _ = try run.shard.apply(atGroup(14, .{ .identity = 2, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 2, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));
    try std.testing.expectError(error.ConflictingReconciliationIdentity, run.shard.apply(atGroup(15, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{ .reconciliation_id = 1, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 } } })));
}

test "multiple SPOT and SWAP orders independently close place amend and cancel" {
    var run = try startScenario();
    _ = try run.shard.apply(atGroup(11, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000 } } }));
    var place: oms_module.IntentGroup = .{ .first_intent_sequence = 80, .count = 4 };
    place.members[0] = .{ .intent_sequence = 80, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    place.members[1] = .{ .intent_sequence = 81, .operation = .place, .instrument = spot_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(spot_instrument, 50_000_000) };
    place.members[2] = .{ .intent_sequence = 82, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    place.members[3] = .{ .intent_sequence = 83, .operation = .place, .instrument = swap_instrument, .quantity = 10, .limit_price = fixtureOmsPrice(swap_instrument, 50_000_000) };
    _ = try run.shard.apply(atGroup(12, .{ .identity = 80, .payload = .{ .oms_intent_group = place } }));
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |order_id, index| _ = try run.shard.apply(atGroup(13 + index, .{ .identity = 1 + index, .payload = .{ .oms_execution_report = .{ .report_id = 1 + index, .order_id = order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10 } } }));

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
    try std.testing.expectEqual(@as(i64, 0), run.shard.layered_risk_reserved_micros);
}

fn applyHealthyPreludeReplay(replay_shard: *ReplayTradingShard) !void {
    _ = try replay_shard.apply(atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_micros = 50_000_000_000 } } }));
    _ = try replay_shard.apply(fixture.canonicalAt(12, 99, .{ .instrument_definition_observed = .{ .instrument = 3, .rules_version = 1 } }));
    _ = try replay_shard.apply(snapshotAt(13, 100));
    _ = try replay_shard.apply(deltaAt(14, 100, 101, 49_850_000_000));
}
