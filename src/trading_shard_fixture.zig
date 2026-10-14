//! Deterministic TradingShard acceptance fixture.
//!
//! This module owns fixed scenario data.  It drives the production state
//! machine exclusively through `applyStable`, whose only transition is
//! `TradingShard.apply`.

const std = @import("std");
const durable = @import("durable_store.zig");
const canonical = @import("canonical_event.zig");
const journal = @import("journal.zig");
const host_gateway = @import("strategy_host_gateway.zig");
const engine = @import("trading_shard.zig");

pub const contract_denominator: i64 = 10_000;
const initial_exchange_cash: i64 = 25_000_000_000;
const portfolio_allocation: i64 = 20_000_000_000;
const risk_lease_total: i64 = 10_000_000_000;
const fixture_utc_base: u64 = 1_767_225_600_000_000_000;
const fixture_monotonic_base: u64 = 1_000_000_000;
pub const happy_order_quantity: i64 = 100;
pub const expected_happy_digest = "d0a8c165caee929ca632249526ad6197ddccf954e4d63782415ff6882ad9b95b";
const expected_trajectory_digests = [_][]const u8{
    expected_happy_digest,
    "630d4448dc5154be61015a5bbf245c72ae06a196bf1cc59096958067c790c182",
    "d6e80b2e7e96fe152ce0a081aecf6aecdf87fa2d02a95ad34ecbd45029c8c295",
    "11973690001f9106d2996d8c2fe30e87862f3fbbf08b6bf2ce469b635d901138",
    "fbbba568c8a66ff854326566acc71c518601f9dea90d2feba8b287556cdf1870",
};
pub const order_limit_price: i64 = 50_100_000_000;

pub fn timer(quantity_value: i64) engine.TimerRequest {
    return .{
        .side = .buy,
        .time_in_force = .good_til_canceled,
        .portfolio_reduce_only = false,
        .quantity = quantity_value,
        .limit_price_micros = order_limit_price,
    };
}
pub const settlement_asset: canonical.AssetIdentity = 1;
pub const swap_instrument: engine.oms.Instrument = 3;
pub const spot_instrument: engine.oms.Instrument = 4;
pub const margin_kill_gate_identity: u128 = 0x4d415247494e4b494c4c;
pub const primary_lease_gate_identity: u128 = 0x5052494d4152594c45415345;
pub const risk_lease_gate_identity: u128 = 0x5249534b4c45415345;

pub fn omsPrice(instrument: engine.oms.Instrument, ticks: i64) engine.oms.Price {
    return .{ .instrument = instrument, .rules_version = 1, .ticks = ticks };
}

pub fn reservation(atoms: i64) engine.oms.Reservation {
    return .{ .asset = settlement_asset, .atoms = atoms };
}

pub const LiveRun = struct {
    shard: engine.TradingShard,
    decision_journal: journal.Journal,
};

pub fn atGroup(group_index: u64, input: engine.CoreEvent) engine.CanonicalEvent {
    var event = input;
    const source_time = fixture_utc_base + group_index * 10 * std.time.ns_per_ms;
    event.source_time = source_time;
    event.receive_time = source_time + std.time.ns_per_ms;
    event.monotonic_time = fixture_monotonic_base + group_index * 10 * std.time.ns_per_ms + std.time.ns_per_ms;
    event.wall_time = source_time + 2 * std.time.ns_per_ms;
    event.time_presence = .{
        .source = true,
        .receive = true,
        .monotonic = true,
        .wall = true,
    };
    return .{ .core = event };
}

pub fn canonicalAt(group_index: u64, source_sequence: u64, event: canonical.Payload) engine.CanonicalEvent {
    const source_time = fixture_utc_base + group_index * 10 * std.time.ns_per_ms;
    return .{ .venue = .{ .envelope = .{
        .event_type = @intFromEnum(canonical.eventType(event)),
        .schema_version = canonical.schema_version,
        .identity = .{ .stream = 1, .sequence = source_sequence },
        .source_fact_identity = source_sequence,
        .scope = .account,
        .venue = 1,
        .exchange_account = 2,
        .source_stream = 1,
        .source_sequence = source_sequence,
        .adapter_session = 1,
        .times = .{
            .source_utc_ns = source_time,
            .receive_utc_ns = source_time + std.time.ns_per_ms,
            .monotonic_ns = fixture_monotonic_base + group_index * 10 * std.time.ns_per_ms + std.time.ns_per_ms,
            .audit_utc_ns = source_time + 2 * std.time.ns_per_ms,
        },
        .raw_evidence = .{ .stream = 1, .sequence = source_sequence, .digest = @splat(0) },
    }, .event = event } };
}

pub fn reconciliationEvidence(group_index: u64, source_sequence: u64, order: canonical.OrderIdentity, instrument: canonical.InstrumentIdentity, revision: u32) canonical.ReconciliationEvidence {
    const observed = fixture_utc_base + group_index * 10 * std.time.ns_per_ms + std.time.ns_per_ms;
    return .{
        .scope = .{ .exchange_account = 2, .instrument = instrument, .order = order, .revision = revision, .from_utc_ns = observed, .through_utc_ns = observed },
        .observed_at_utc_ns = observed,
        .source = .{ .stream = 1, .sequence = source_sequence, .digest = @splat(1) },
    };
}

pub fn completeAbsenceEvidence(group_index: u64, source_sequence: u64, order: canonical.OrderIdentity, instrument: canonical.InstrumentIdentity, revision: u32) canonical.ReconciliationEvidence {
    var evidence = reconciliationEvidence(group_index, source_sequence, order, instrument, revision);
    evidence.absence = .{
        .prior_session = 9,
        .prior_session_inactive = true,
        .visibility_deadline_utc_ns = evidence.observed_at_utc_ns,
        .order_history_complete = true,
        .terminal_history_complete = true,
        .fills_complete = true,
        .economics_complete = true,
    };
    return evidence;
}

fn quantity(lots: i128) canonical.InstrumentQuantity {
    return .{ .instrument = 3, .rules_version = 1, .lots = lots };
}

fn price(ticks: i128) canonical.InstrumentPrice {
    return .{ .instrument = 3, .rules_version = 1, .ticks = ticks };
}

pub fn snapshotAt(group: u64, source_sequence: u64) engine.CanonicalEvent {
    return canonicalAt(group, source_sequence, .{ .l2_book_snapshot = .{
        .instrument = 3,
        .sequence = source_sequence,
        .best_bid = price(49_800_000_000),
        .best_ask = price(49_900_000_000),
        .best_bid_quantity = quantity(1_000),
        .best_ask_quantity = quantity(40),
        .next_ask = price(50_100_000_000),
        .next_ask_quantity = quantity(60),
    } });
}

pub fn deltaAt(group: u64, previous: u64, current: u64, bid_price_micros: i64) engine.CanonicalEvent {
    return canonicalAt(group, current, .{ .l2_book_delta = .{
        .instrument = 3,
        .previous_sequence = previous,
        .sequence = current,
        .best_bid = price(bid_price_micros),
        .best_ask = price(49_900_000_000),
        .best_bid_quantity = quantity(1_000),
        .best_ask_quantity = quantity(40),
        .next_ask = price(50_100_000_000),
        .next_ask_quantity = quantity(60),
    } });
}

pub fn apply(run: *LiveRun, event: engine.CanonicalEvent) !?engine.OrderCommand {
    // Keep the transactional candidate in one frame across nested fixture callers.
    return @call(.never_inline, engine.applyStable, .{ &run.shard, &run.decision_journal, event });
}

pub fn lifecycleCommand(command_identity: u128, expected_version: u64, kind: engine.operational.CommandKind) engine.CanonicalEvent {
    return atGroup(40, .{ .identity = @intCast(1_000 + command_identity), .payload = .{ .control_command = .{
        .command_identity = command_identity,
        .content_hash = command_identity * 7_919,
        .target_identity = 1,
        .expected_version = expected_version,
        .expires_at = std.math.maxInt(u64),
        .kind = kind,
    } } });
}

pub fn deRiskCommand(command_identity: u128, expected_version: u64, target_position: i64, warning_identity: u128) engine.CanonicalEvent {
    var input: engine.CoreEvent = .{ .identity = @intCast(1_000 + command_identity), .payload = .{ .control_command = .{
        .command_identity = command_identity,
        .content_hash = command_identity * 7_919,
        .target_identity = 1,
        .expected_version = expected_version,
        .expires_at = std.math.maxInt(u64),
        .kind = .de_risk,
    } } };
    input.payload.control_command.target_position = target_position;
    if (warning_identity != 0) {
        input.payload.control_command.risk_warning_acknowledged = true;
        input.payload.control_command.risk_warning_identity = warning_identity;
    }
    return atGroup(40, input);
}

pub fn resolveLatchCommand(command_identity: u128, expected_version: u64, latch_identity: u128) engine.CanonicalEvent {
    var input: engine.CoreEvent = .{ .identity = @intCast(1_000 + command_identity), .payload = .{ .control_command = .{
        .command_identity = command_identity,
        .content_hash = command_identity * 7_919,
        .target_identity = 1,
        .expected_version = expected_version,
        .expires_at = std.math.maxInt(u64),
        .kind = .resolve_latch,
    } } };
    input.payload.control_command.referenced_latch_identity = latch_identity;
    return atGroup(40, input);
}

pub fn genesisEvents(authorization: host_gateway.Authorization, reservation_model: engine.ReservationModel) [22]engine.CanonicalEvent {
    const assets = @import("asset_registry.zig").testDefinitions(6, 8);
    const denominator: i64 = switch (reservation_model) {
        .leveraged => contract_denominator,
        .cash => 100_000_000,
    };
    return .{
        atGroup(1, .{ .identity = 1, .payload = .{ .instrument_rules_activated = .{
            .version = 1,
            .instrument_identity = 3,
            .quantity_denominator = denominator,
            .reservation_model = reservation_model,
            .product = if (reservation_model == .cash) .spot else .isolated_linear_usdt,
            .base_asset = if (reservation_model == .cash) 0x425443 else 0,
            .venue = 1,
        } } }),
        atGroup(2, .{ .identity = 1, .payload = .{ .margin_rules_activated = .{ .version = 1 } } }),
        atGroup(2, .{ .identity = 2, .payload = .{ .instrument_rules_activated = .{
            .version = 1,
            .instrument_identity = spot_instrument,
            .quantity_denominator = 100_000_000,
            .reservation_model = .cash,
            .product = .spot,
            .base_asset = 0x425443,
            .venue = 1,
        } } }),
        atGroup(2, .{ .identity = 2, .payload = .{ .margin_rules_activated = .{
            .version = 1,
            .instrument = spot_instrument,
        } } }),
        atGroup(2, .{ .identity = 3, .payload = .{ .mark_price = .{
            .instrument = swap_instrument,
            .price_atoms = 50_000_000,
        } } }),
        atGroup(2, .{ .identity = 4, .payload = .{ .mark_price = .{
            .instrument = spot_instrument,
            .price_atoms = 50_000_000,
        } } }),
        atGroup(3, .{ .identity = 1, .payload = .{ .account_configuration = .{ .exchange_account_identity = 2 } } }),
        atGroup(3, .{ .identity = assets[0].asset, .payload = .{ .asset_definition_activated = assets[0] } }),
        atGroup(3, .{ .identity = assets[1].asset, .payload = .{ .asset_definition_activated = assets[1] } }),
        atGroup(4, .{ .identity = 1, .payload = .{ .exchange_balance = .{ .cash_atoms = initial_exchange_cash } } }),
        atGroup(5, .{ .identity = 1, .payload = .exchange_positions }),
        atGroup(6, .{ .identity = 1, .payload = .{ .opening_balance = .{ .cash_atoms = initial_exchange_cash } } }),
        atGroup(7, .{ .identity = 1, .payload = .{ .virtual_portfolio_activated = .{ .portfolio_identity = 1 } } }),
        atGroup(8, .{ .identity = 1, .payload = .{ .portfolio_transfer = .{ .amount_atoms = portfolio_allocation } } }),
        atGroup(9, .{ .identity = 1, .payload = .{ .strategy_activated = .{
            .strategy_identity = authorization.strategy_identity,
            .config_version = authorization.config_version,
            .activation_identity = authorization.activation_identity,
        } } }),
        atGroup(10, .{ .identity = 1, .payload = .{ .primary_lease_granted = .{ .fencing_token = 1 } } }),
        atGroup(11, .{ .identity = 1, .payload = .{ .risk_lease_granted = .{ .amount_atoms = risk_lease_total } } }),
        atGroup(11, .{ .identity = 1, .payload = .{ .control_command = .{
            .command_identity = 1,
            .content_hash = 1,
            .target_identity = 1,
            .expected_version = 0,
            .expires_at = std.math.maxInt(u64),
            .kind = .start_recovery,
        } } }),
        atGroup(11, .{ .identity = 1, .payload = .recovery_completed }),
        atGroup(11, .{ .identity = 30, .payload = .{ .instrument_trading_authorization = .{
            .exchange_account = 2,
            .instrument = swap_instrument,
            .strategy_activation_identity = authorization.activation_identity,
            .config_version = authorization.config_version,
            .expected_version = 0,
            .enabled = true,
        } } }),
        atGroup(11, .{ .identity = 31, .payload = .{ .instrument_trading_authorization = .{
            .exchange_account = 2,
            .instrument = spot_instrument,
            .strategy_activation_identity = authorization.activation_identity,
            .config_version = authorization.config_version,
            .expected_version = 0,
            .enabled = true,
        } } }),
        atGroup(11, .{ .identity = 2, .payload = .{ .control_command = .{
            .command_identity = 2,
            .content_hash = 2,
            .target_identity = 1,
            .expected_version = 2,
            .expires_at = std.math.maxInt(u64),
            .kind = .enable_trading,
        } } }),
    };
}

pub fn startScenarioAuthorized(authorization: host_gateway.Authorization, reservation_model: engine.ReservationModel) !LiveRun {
    var run: LiveRun = undefined;
    try startScenarioInto(&run, authorization, reservation_model, .{ .fencing = 1, .shard = 0, .generation = 1 });
    return run;
}

pub fn startScenarioAuthorizedForSession(authorization: host_gateway.Authorization, reservation_model: engine.ReservationModel, session: @import("strategy_host_ipc.zig").Session) !LiveRun {
    var run: LiveRun = undefined;
    try startScenarioInto(&run, authorization, reservation_model, session);
    return run;
}

pub fn startScenarioInto(run: *LiveRun, authorization: host_gateway.Authorization, reservation_model: engine.ReservationModel, session: @import("strategy_host_ipc.zig").Session) !void {
    run.* = .{ .shard = .{}, .decision_journal = journal.Journal.init() };
    const genesis = genesisEvents(authorization, reservation_model);
    for (genesis) |event| if (try apply(run, event) != null) return error.UnexpectedCommand;
    const host_digest = run.shard.canonicalStateDigest();
    if (try apply(run, atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{
        .strategy_identity = authorization.strategy_identity,
        .config_version = authorization.config_version,
        .activation_identity = authorization.activation_identity,
        .session = session,
        .activation_barrier = authorization.activation_barrier,
        .state_digest = host_digest,
    } } })) != null) return error.UnexpectedCommand;
}

pub fn startScenario() !LiveRun {
    var run: LiveRun = undefined;
    try initializeScenario(&run);
    return run;
}

pub fn initializeScenario(run: *LiveRun) !void {
    try startScenarioInto(run, defaultAuthorization(), .leveraged, .{ .fencing = 1, .shard = 0, .generation = 1 });
}

/// A one-fact HostActivated tail for isolated Gateway/pipe integration checks.
/// Full genesis and replay acceptance use startScenarioAuthorized above.
pub fn gatewayActivationFixture(authorization: host_gateway.Authorization) !LiveRun {
    return gatewayActivationFixtureForSession(authorization, .{ .fencing = 1, .shard = 0, .generation = 1 });
}

pub fn gatewayActivationFixtureForSession(authorization: host_gateway.Authorization, session: @import("strategy_host_ipc.zig").Session) !LiveRun {
    var run: LiveRun = undefined;
    try gatewayActivationFixtureForSessionInto(&run, authorization, session);
    return run;
}

pub fn gatewayActivationFixtureForSessionInto(run: *LiveRun, authorization: host_gateway.Authorization, session: @import("strategy_host_ipc.zig").Session) !void {
    run.* = .{
        .shard = .{
            .strategy_active = true,
            .strategy_identity = authorization.strategy_identity,
            .strategy_config_version = authorization.config_version,
            .strategy_activation_identity = authorization.activation_identity,
        },
        .decision_journal = journal.Journal.init(),
    };
    const digest = run.shard.canonicalStateDigest();
    _ = try apply(run, atGroup(1, .{ .identity = 1, .payload = .{ .host_activated = .{
        .strategy_identity = authorization.strategy_identity,
        .config_version = authorization.config_version,
        .activation_identity = authorization.activation_identity,
        .session = session,
        .activation_barrier = authorization.activation_barrier,
        .state_digest = digest,
    } } }));
}

pub fn applyHealthyPrelude(run: *LiveRun) !void {
    if (try apply(run, atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000_000 } } })) != null)
        return error.UnexpectedCommand;
    const prelude = [_]engine.CanonicalEvent{
        canonicalAt(12, 99, .{ .instrument_definition_observed = .{ .instrument = 3, .rules_version = 1 } }),
        snapshotAt(13, 100),
        deltaAt(14, 100, 101, 49_850_000_000),
    };
    for (prelude) |event| if (try apply(run, event) != null) return error.UnexpectedCommand;
}

fn defaultAuthorization() host_gateway.Authorization {
    return .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 1,
        .activation_barrier = 0,
    };
}

fn healthyRun() !LiveRun {
    var run: LiveRun = undefined;
    try healthyRunInto(&run);
    return run;
}

fn healthyRunInto(run: *LiveRun) !void {
    try startScenarioInto(run, defaultAuthorization(), .leveraged, .{ .fencing = 1, .shard = 0, .generation = 1 });
    try applyHealthyPrelude(run);
}

fn healthyScenarioAuthorizedInto(run: *LiveRun, authorization: host_gateway.Authorization, reservation_model: engine.ReservationModel, session: @import("strategy_host_ipc.zig").Session) !void {
    try startScenarioInto(run, authorization, reservation_model, session);
    try applyHealthyPrelude(run);
}

pub fn initializedBenchmarkRun() !LiveRun {
    return healthyRun();
}

pub fn initializedBenchmarkRunInto(run: *LiveRun) !void {
    try healthyRunInto(run);
}

pub fn replayDigest(run: *const LiveRun) ![32]u8 {
    return replayDigestConfigured(run, run.shard.quantity_denominator, run.shard.reservation_model);
}

fn replayDigestConfigured(run: *const LiveRun, quantity_denominator: i64, reservation_model: engine.ReservationModel) ![32]u8 {
    const initial = try std.heap.page_allocator.create(engine.TradingShard);
    defer std.heap.page_allocator.destroy(initial);
    initial.* = .{ .quantity_denominator = quantity_denominator, .reservation_model = reservation_model };
    const recovered = try std.heap.page_allocator.create(engine.TradingShard);
    defer std.heap.page_allocator.destroy(recovered);
    const status = try engine.recoverStableInto(recovered, initial, run.decision_journal.bytes());
    if (status != .clean) return error.ReplayNotEquivalent;
    return recovered.canonicalStateDigest();
}

pub fn assertReplayEquivalentConfigured(run: *const LiveRun, quantity_denominator: i64, reservation_model: engine.ReservationModel) ![32]u8 {
    const live_digest = run.shard.canonicalStateDigest();
    const replay_digest = try replayDigestConfigured(run, quantity_denominator, reservation_model);
    if (!std.mem.eql(u8, &live_digest, &replay_digest)) return error.ReplayNotEquivalent;
    return live_digest;
}

pub fn assertReplayEquivalent(run: *const LiveRun) ![32]u8 {
    return assertReplayEquivalentConfigured(run, contract_denominator, .leveraged);
}

pub fn happyVenueFacts(command: engine.OrderCommand) ![6]engine.CanonicalEvent {
    if (command.command_id != 1 or command.order_id != 1 or
        command.quantity != happy_order_quantity or
        command.limit_price.ticks != 50_100_000_000 or
        command.reservation.atoms != 11_397_750)
        return error.InvalidOrderCommand;
    const client = command.client_order_id;
    const venue_order = try canonical.VenueOrderRef.init(1, "fixture-order-1");
    const first_trade = try canonical.VenueTradeRef.init(1, "fixture-trade-1");
    const second_trade = try canonical.VenueTradeRef.init(1, "fixture-trade-2");
    const Report = struct {
        fn make(identity: u128, status: canonical.ExecutionReportStatus, cumulative: i128, remaining: i128, client_order: canonical.ClientOrderId, order_ref: canonical.VenueOrderRef, revision: u32) canonical.ExecutionReport {
            return .{
                .identity = identity,
                .order = 1,
                .client_order_id = client_order,
                .venue_order = order_ref,
                .instrument = 3,
                .exchange_account = 2,
                .revision = revision,
                .side = .buy,
                .order_type = .limit,
                .time_in_force = .good_til_canceled,
                .status = status,
                .original_quantity = quantity(100),
                .cumulative_quantity = quantity(cumulative),
                .remaining_quantity = quantity(remaining),
                .limit_price = price(order_limit_price),
            };
        }
    };
    return .{
        canonicalAt(15, 102, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .submitted } }),
        canonicalAt(16, 103, .{ .execution_report = Report.make(1, .accepted, 0, 100, client, venue_order, command.revision) }),
        canonicalAt(17, 104, .{ .fill = .{
            .identity = 1,
            .order = 1,
            .client_order_id = client,
            .venue_order = venue_order,
            .venue_trade = first_trade,
            .instrument = 3,
            .exchange_account = 2,
            .side = .buy,
            .quantity = quantity(40),
            .price = price(49_900_000_000),
            .fee = .{ .asset = settlement_asset, .atoms = 149_700 },
            .liquidity = .taker,
        } }),
        canonicalAt(17, 105, .{ .execution_report = Report.make(2, .partially_filled, 40, 60, client, venue_order, command.revision) }),
        canonicalAt(18, 106, .{ .fill = .{
            .identity = 2,
            .order = 1,
            .client_order_id = client,
            .venue_order = venue_order,
            .venue_trade = second_trade,
            .instrument = 3,
            .exchange_account = 2,
            .side = .buy,
            .quantity = quantity(60),
            .price = price(50_100_000_000),
            .fee = .{ .asset = settlement_asset, .atoms = 225_450 },
            .liquidity = .taker,
        } }),
        canonicalAt(18, 107, .{ .execution_report = Report.make(3, .filled, 100, 0, client, venue_order, command.revision) }),
    };
}

fn assertPartialState(shard: *const engine.TradingShard) !void {
    const economic = shard.economicSummary();
    const order = shard.oms.orderById(1) orelse return error.PartialEconomicProjectionMismatch;
    const report_applied = order.state == .partially_filled;
    const expected_reservation: i64 = if (report_applied) 6_838_650 else 11_397_750;
    const expected_remaining: i64 = if (report_applied) 9_988_770_150 else 9_984_211_050;
    if (economic.portfolio.swap.quantity != 40 or
        economic.portfolio.swap.open_cost_atoms != 199_600_000 or
        economic.exchange.swap.quantity != 40 or
        economic.exchange.swap.open_cost_atoms != 199_600_000 or
        economic.portfolio.fee_atoms != 149_700 or
        economic.portfolio.usdt_balance_atoms != 19_999_850_300 or
        economic.exchange.usdt_balance_atoms != 24_999_850_300 or
        shard.economic_projection.portfolio.margin_atoms != 4_391_200 or
        // The fill ledger is not allowed to guess OMS remaining quantity:
        // reservation changes only once the authoritative report is applied.
        try shard.activeReservationAtoms() != expected_reservation or
        try shard.riskLeaseRemainingAtoms() != expected_remaining)
    {
        std.debug.print("partial state: position_margin={d} reservation={d} remaining={d}\n", .{ shard.economic_projection.portfolio.margin_atoms, try shard.activeReservationAtoms(), try shard.riskLeaseRemainingAtoms() });
        return error.PartialEconomicProjectionMismatch;
    }
}

pub fn runHappyPath() !LiveRun {
    var run: LiveRun = undefined;
    try runHappyPathInto(&run);
    return run;
}

pub fn runHappyPathInto(run: *LiveRun) !void {
    try healthyRunInto(run);
    const command = (try apply(run, atGroup(15, .{ .identity = 1, .payload = .{ .timer = timer(happy_order_quantity) } }))) orelse return error.MissingOrderCommand;
    const facts = try happyVenueFacts(command);
    for (facts, 0..) |event, index| {
        if (try apply(run, event) != null) return error.UnexpectedCommand;
        if (index == 2) try assertPartialState(&run.shard);
    }
    if (try apply(run, atGroup(19, .{ .identity = 2, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_200_000_000 } } })) != null)
        return error.UnexpectedCommand;
    try run.decision_journal.seal();
}

pub fn runMarketGap() !LiveRun {
    var run: LiveRun = undefined;
    try runMarketGapInto(&run);
    return run;
}

fn runMarketGapInto(run: *LiveRun) !void {
    try healthyRunInto(run);
    if (try apply(run, deltaAt(15, 102, 103, 49_860_000_000)) != null) return error.UnexpectedCommand;
    if (try apply(run, atGroup(16, .{ .identity = 1, .payload = .{ .timer = timer(happy_order_quantity) } })) != null)
        return error.CommandEscapedMarketGap;
    if (try apply(run, snapshotAt(17, 200)) != null) return error.UnexpectedCommand;
    if (try apply(run, deltaAt(18, 200, 201, 49_850_000_000)) != null) return error.UnexpectedCommand;
    try run.decision_journal.seal();
}

pub fn runRiskRejection() !LiveRun {
    var run: LiveRun = undefined;
    try runRiskRejectionInto(&run);
    return run;
}

fn runRiskRejectionInto(run: *LiveRun) !void {
    try healthyRunInto(run);
    if (try apply(run, atGroup(15, .{ .identity = 1, .payload = .{ .timer = timer(100_001) } })) != null)
        return error.CommandEscapedRiskRejection;
    try run.decision_journal.seal();
}

pub fn runUnknownReconciliation() !LiveRun {
    var run: LiveRun = undefined;
    try runUnknownReconciliationInto(&run);
    return run;
}

fn runUnknownReconciliationInto(run: *LiveRun) !void {
    try healthyRunInto(run);
    const command = (try apply(run, atGroup(15, .{ .identity = 1, .payload = .{ .timer = timer(happy_order_quantity) } }))) orelse return error.MissingOrderCommand;
    const facts = try happyVenueFacts(command);
    if (try apply(run, canonicalAt(16, 102, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .unknown } })) != null) return error.UnexpectedCommand;
    if (try apply(run, canonicalAt(17, 103, .{ .order_reconciliation_result = .{
        .identity = 1,
        .complete = true,
        .status = .found_live,
        .order = command.order_id,
        .revision = 1,
        .cumulative_quantity = .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = 0 },
        .remaining_quantity = .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity },
        .rules_version = command.limit_price.rules_version,
        .evidence = reconciliationEvidence(17, 103, command.order_id, command.instrument, 1),
    } })) != null) return error.UnexpectedCommand;
    var accepted = facts[1];
    accepted.venue.envelope.identity.sequence = 104;
    accepted.venue.envelope.source_sequence = 104;
    accepted.venue.envelope.raw_evidence.sequence = 104;
    if (try apply(run, accepted) != null) return error.UnexpectedCommand;
    try run.decision_journal.seal();
}

pub fn runDuplicateReport() !LiveRun {
    var run: LiveRun = undefined;
    try runDuplicateReportInto(&run);
    return run;
}

fn runDuplicateReportInto(run: *LiveRun) !void {
    try healthyRunInto(run);
    const command = (try apply(run, atGroup(15, .{ .identity = 1, .payload = .{ .timer = timer(happy_order_quantity) } }))) orelse return error.MissingOrderCommand;
    const facts = try happyVenueFacts(command);
    for (facts[0..4]) |event| if (try apply(run, event) != null) return error.UnexpectedCommand;
    try assertPartialState(&run.shard);
    const before_duplicate_fill = run.shard.canonicalStateDigest();
    const duplicate_fill = try run.shard.apply(facts[2]);
    if (duplicate_fill.facts.len != 0 or duplicate_fill.order_command != null or duplicate_fill.oms_commands.len != 0)
        return error.DuplicateFillChangedState;
    if (!std.mem.eql(u8, &before_duplicate_fill, &run.shard.canonicalStateDigest()))
        return error.DuplicateFillChangedState;
    try assertPartialState(&run.shard);
    if (try apply(run, facts[4]) != null) return error.UnexpectedCommand;
    if (try apply(run, facts[5]) != null) return error.UnexpectedCommand;
    if (try apply(run, atGroup(20, .{ .identity = 2, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_200_000_000 } } })) != null)
        return error.UnexpectedCommand;
    try run.decision_journal.seal();
}

fn verifyScenario(run: *const LiveRun) !void {
    _ = try assertReplayEquivalentConfigured(run, run.shard.quantity_denominator, run.shard.reservation_model);
}

/// Runs the deterministic acceptance fixture outside the production state module.
pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |argument| {
        if (!std.mem.eql(u8, argument, "--offline-fixture") or args.next() != null)
            return error.UnknownArgument;
    }
    try journal.selfCheck();
    const runs = try init.gpa.alloc(LiveRun, 5);
    defer init.gpa.free(runs);
    const happy = &runs[0];
    const market_gap = &runs[1];
    const risk_rejection = &runs[2];
    const unknown = &runs[3];
    const duplicate = &runs[4];
    try runHappyPathInto(happy);
    try runMarketGapInto(market_gap);
    try runRiskRejectionInto(risk_rejection);
    try runUnknownReconciliationInto(unknown);
    try runDuplicateReportInto(duplicate);
    for (runs) |*run| try verifyScenario(run);
    try happy.shard.assertClosures();

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    const digest_hex = std.fmt.bytesToHex(happy.shard.canonicalStateDigest(), .lower);
    try out.print("trading_engine: zig={s}, mode={s}, self_check=ok\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode) });
    for (happy.shard.trace.events[0..happy.shard.trace.len]) |event|
        try out.print("{d:0>2} {s} id={d}\n", .{ event.sequence, @tagName(event.kind), event.identity });
    const economic = happy.shard.economicSummary();
    const final_order = happy.shard.oms.orderById(1) orelse return error.MissingOrder;
    try out.print("happy_path: events={d}, order={s}, qty={d}, open_cost={d}, fees={d}, upl={d}, risk_remaining={d}, ledger=closed, economic_projections=complete\ndigest={s}\n", .{ happy.shard.trace.len, @tagName(final_order.state), final_order.cumulative_quantity, economic.portfolio.swap.open_cost_atoms, economic.portfolio.fee_atoms, economic.portfolio.unrealized_pnl_atoms, try happy.shard.riskLeaseRemainingAtoms(), &digest_hex });
    try out.print("journal_records={d}, journal_bytes={d}, replay=equivalent, recovery_checks=ok\n", .{ happy.decision_journal.records, happy.decision_journal.len });
    const scenarios = [_]struct { name: []const u8, run: *const LiveRun }{
        .{ .name = "market-gap-v1", .run = market_gap },          .{ .name = "risk-rejection-v1", .run = risk_rejection },
        .{ .name = "unknown-reconciliation-v1", .run = unknown }, .{ .name = "duplicate-report-v1", .run = duplicate },
    };
    for (scenarios) |scenario| {
        const digest = std.fmt.bytesToHex(scenario.run.shard.canonicalStateDigest(), .lower);
        try out.print("{s}: events={d}, replay=equivalent, digest={s}\n", .{ scenario.name, scenario.run.shard.trace.len, &digest });
    }
    try out.flush();
}

pub const HostIngressSummary = struct {
    order_intents: usize,
    risk_accepts: usize,
    order_commands: usize,
    host_rejections: usize,
    journal_records: u64,
    order_quantity: i64,
    order_limit_price_micros: i64,
    reservation_atoms: i64,
};

pub const QualifiedHostOrder = struct {
    command_id: u64,
    order_id: u64,
    strategy_identity: u128,
    intent_sequence: u64,
    instrument_identity: u128,
    side: host_gateway.Side,
    time_in_force: host_gateway.TimeInForce,
    portfolio_reduce_only: bool,
    quantity: canonical.InstrumentQuantity,
    limit_price: canonical.InstrumentPrice,
    reservation: canonical.AssetAmount,
};

pub const TradingShardHostIngress = struct {
    run: LiveRun,

    pub fn initHealthyFixtureFor(authorization: host_gateway.Authorization) !TradingShardHostIngress {
        var result: TradingShardHostIngress = undefined;
        try initHealthyFixtureForInto(&result, authorization);
        return result;
    }

    pub fn initHealthyFixtureForInto(self: *TradingShardHostIngress, authorization: host_gateway.Authorization) !void {
        try healthyScenarioAuthorizedInto(&self.run, authorization, .leveraged, .{ .fencing = 1, .shard = 0, .generation = 1 });
    }

    pub fn initHealthyFixtureForSession(authorization: host_gateway.Authorization, session: @import("strategy_host_ipc.zig").Session) !TradingShardHostIngress {
        var result: TradingShardHostIngress = undefined;
        try initHealthyFixtureForSessionInto(&result, authorization, session);
        return result;
    }

    pub fn initHealthyFixtureForSessionInto(self: *TradingShardHostIngress, authorization: host_gateway.Authorization, session: @import("strategy_host_ipc.zig").Session) !void {
        try healthyScenarioAuthorizedInto(&self.run, authorization, .leveraged, session);
    }

    pub fn initHealthySpotFixtureFor(authorization: host_gateway.Authorization) !TradingShardHostIngress {
        var result: TradingShardHostIngress = undefined;
        try initHealthySpotFixtureForInto(&result, authorization);
        return result;
    }

    pub fn initHealthySpotFixtureForInto(self: *TradingShardHostIngress, authorization: host_gateway.Authorization) !void {
        try healthyScenarioAuthorizedInto(&self.run, authorization, .cash, .{ .fencing = 1, .shard = 0, .generation = 1 });
    }

    pub fn applyDecision(self: *TradingShardHostIngress, decision: host_gateway.Decision) !bool {
        return (try self.applyDecisionCommand(decision)) != null;
    }

    pub fn applyDecisionCommand(self: *TradingShardHostIngress, decision: host_gateway.Decision) !?QualifiedHostOrder {
        const payload: engine.CorePayload = switch (decision) {
            .accepted => |intent| .{ .external_order_intent = intent },
            .rejected => |rejection| .{ .strategy_intent_rejected = rejection },
        };
        const identity: u64 = switch (decision) {
            .accepted => |intent| intent.intent_sequence,
            .rejected => |rejection| rejection.intent_sequence,
        };
        const command = try apply(&self.run, atGroup(15, .{ .identity = identity, .payload = payload })) orelse return null;
        const intent = switch (decision) {
            .accepted => |value| value,
            .rejected => return error.RejectionProducedCommand,
        };
        return .{
            .command_id = command.command_id,
            .order_id = command.order_id,
            .strategy_identity = intent.strategy_identity,
            .intent_sequence = intent.intent_sequence,
            .instrument_identity = intent.instrument_identity,
            .side = intent.side,
            .time_in_force = intent.time_in_force,
            .portfolio_reduce_only = intent.portfolio_reduce_only,
            .quantity = .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity },
            .limit_price = command.limit_price,
            .reservation = command.reservation,
        };
    }

    pub fn summary(self: *const TradingShardHostIngress) !HostIngressSummary {
        const order = self.run.shard.oms.orderById(1);
        var result: HostIngressSummary = .{
            .order_intents = 0,
            .risk_accepts = 0,
            .order_commands = 0,
            .host_rejections = 0,
            .journal_records = self.run.decision_journal.records,
            .order_quantity = if (order) |value| value.quantity else 0,
            .order_limit_price_micros = if (order) |value| std.math.cast(i64, value.limit_price.ticks) orelse 0 else 0,
            .reservation_atoms = std.math.cast(i64, try self.run.shard.activeReservationAtoms()) orelse return error.HostIngressSummaryOverflow,
        };
        for (self.run.shard.trace.events[0..self.run.shard.trace.len]) |event| switch (event.kind) {
            .order_intent => result.order_intents += 1,
            .risk_accepted => result.risk_accepts += 1,
            .order_command => result.order_commands += 1,
            .strategy_intent_rejected => result.host_rejections += 1,
            else => {},
        };
        return result;
    }

    pub fn applyDispatchResult(self: *TradingShardHostIngress, identity: u64, status: canonical.DispatchState) !void {
        if (self.run.shard.oms.command_history_count == 0) return error.MissingOrderCommand;
        const command_id = self.run.shard.oms.command_history[self.run.shard.oms.command_history_count - 1].command_id;
        if ((try apply(&self.run, canonicalAt(16, identity, .{ .order_dispatch_result = .{ .command = command_id, .state = status } }))) != null)
            return error.DispatchProducedCommand;
    }

    pub fn verifyReplay(self: *TradingShardHostIngress) !void {
        try self.run.decision_journal.seal();
        const replayed = try replayDigestConfigured(&self.run, self.run.shard.quantity_denominator, self.run.shard.reservation_model);
        if (!std.mem.eql(u8, &self.run.shard.canonicalStateDigest(), &replayed))
            return error.ReplayNotEquivalent;
    }
};

test "qualified SPOT IOC intent crosses Gateway and cash risk before OrderCommand" {
    const authorization: host_gateway.Authorization = .{
        .strategy_identity = 40,
        .config_version = 1,
        .activation_identity = 50,
        .activation_barrier = 10,
    };
    const config: host_gateway.Config = .{
        .schema_registry = 1,
        .decision_domain = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
        .authorization = authorization,
    };
    const subscriptions = [_]host_gateway.Subscription{
        host_gateway.Subscription.of(authorization.strategy_identity, &.{.mark_price}),
    };
    const ingress = try std.testing.allocator.create(TradingShardHostIngress);
    defer std.testing.allocator.destroy(ingress);
    try TradingShardHostIngress.initHealthySpotFixtureForInto(ingress, authorization);
    const cursor: u64 = @intCast(ingress.run.shard.authoritativeBarrier() + 1);
    var gateway = try host_gateway.Gateway.init(config, &subscriptions);
    try gateway.recordPublished(1, cursor, 100);
    try gateway.activate(&ingress.run.shard, &ingress.run.decision_journal);
    var frame_storage: [256]u8 = undefined;
    const frame = try host_gateway.encodeOutputOrderFrame(&frame_storage, config, 1, cursor, 7, .{
        .time_in_force = .immediate_or_cancel,
        .quantity = 5_000,
        .limit_price_micros = 63_500_000_000,
    });
    const decision = gateway.ingest(frame, 100);
    try std.testing.expect(decision == .accepted);
    const command = (try ingress.applyDecisionCommand(decision)).?;
    try std.testing.expectEqual(host_gateway.TimeInForce.immediate_or_cancel, command.time_in_force);
    try std.testing.expectEqual(@as(i128, 5_000), command.quantity.lots);
    try std.testing.expectEqual(@as(i128, 3_177_382), command.reservation.atoms);
    try ingress.verifyReplay();
}

test "fixed trajectories retain their sealed barriers and recovery digests" {
    const trajectories = [_]*const fn (*LiveRun) anyerror!void{
        runHappyPathInto,
        runMarketGapInto,
        runRiskRejectionInto,
        runUnknownReconciliationInto,
        runDuplicateReportInto,
    };
    const run = try std.testing.allocator.create(LiveRun);
    defer std.testing.allocator.destroy(run);
    const initial = try std.testing.allocator.create(engine.TradingShard);
    defer std.testing.allocator.destroy(initial);
    const recovered = try std.testing.allocator.create(engine.TradingShard);
    defer std.testing.allocator.destroy(recovered);
    var digests: [trajectories.len][64]u8 = undefined;
    for (trajectories, 0..) |trajectory, index| {
        try trajectory(run);
        try std.testing.expect(run.decision_journal.sealed);
        try std.testing.expectEqual(run.decision_journal.last_sequence, run.shard.authoritativeBarrier());
        switch (index) {
            0, 4 => {
                const order = run.shard.oms.orderById(1).?;
                try std.testing.expectEqual(engine.oms.OrderState.filled, order.state);
                try std.testing.expectEqual(@as(i64, 100), order.cumulative_quantity);
                const economic = run.shard.economicSummary();
                try std.testing.expectEqual(@as(i64, 100), economic.portfolio.swap.quantity);
                try std.testing.expectEqual(@as(i64, 500_200_000), economic.portfolio.swap.open_cost_atoms);
                try std.testing.expectEqual(@as(i64, 375_150), economic.portfolio.fee_atoms);
                try std.testing.expectEqual(@as(i64, 1_800_000), economic.portfolio.unrealized_pnl_atoms);
                try run.shard.assertClosures();
            },
            1, 2 => try std.testing.expectEqual(@as(u16, 0), run.shard.oms.order_count),
            3 => {
                const order = run.shard.oms.orderById(1).?;
                try std.testing.expectEqual(engine.oms.OrderState.live, order.state);
                try std.testing.expectEqual(@as(i64, 0), order.cumulative_quantity);
                try std.testing.expectEqual(@as(i64, 100), order.quantity);
            },
            else => unreachable,
        }
        initial.* = .{ .quantity_denominator = run.shard.quantity_denominator, .reservation_model = run.shard.reservation_model };
        try std.testing.expectEqual(journal.ScanStatus.clean, try engine.recoverStableInto(recovered, initial, run.decision_journal.bytes()));
        try std.testing.expectEqualSlices(u8, &run.shard.canonicalStateDigest(), &recovered.canonicalStateDigest());
        digests[index] = std.fmt.bytesToHex(run.shard.canonicalStateDigest(), .lower);
        std.debug.print("validated trajectory {d}: barrier={d}, digest={s}\n", .{ index, run.shard.authoritativeBarrier(), &digests[index] });
    }
    for (digests, 0..) |digest, index| try std.testing.expectEqualSlices(u8, expected_trajectory_digests[index], &digest);
}

test "authoritative snapshot round trips at an exact shard barrier" {
    const run = try std.testing.allocator.create(LiveRun);
    defer std.testing.allocator.destroy(run);
    try runHappyPathInto(run);
    const storage = try std.testing.allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.testing.allocator.free(storage);
    const encoded = try run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence, storage);
    const restored = try std.testing.allocator.create(engine.TradingShard);
    defer std.testing.allocator.destroy(restored);
    const barrier = try engine.TradingShard.restoreSnapshotInto(restored, encoded);
    try std.testing.expectEqual(run.decision_journal.last_sequence, barrier);
    try std.testing.expectEqualSlices(u8, &run.shard.canonicalStateDigest(), &restored.canonicalStateDigest());

    const duplicate_storage = try std.testing.allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.testing.allocator.free(duplicate_storage);
    const duplicate = try run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence, duplicate_storage);
    try std.testing.expectEqualSlices(u8, encoded, duplicate);
    const independent = try std.testing.allocator.create(LiveRun);
    defer std.testing.allocator.destroy(independent);
    try runHappyPathInto(independent);
    const independent_storage = try std.testing.allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.testing.allocator.free(independent_storage);
    const independent_encoded = try independent.shard.snapshot(&independent.decision_journal, independent.decision_journal.last_sequence, independent_storage);
    try std.testing.expectEqualSlices(u8, encoded, independent_encoded);
    const damaged_storage = try std.testing.allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.testing.allocator.free(damaged_storage);
    @memcpy(damaged_storage[0..encoded.len], encoded);
    damaged_storage[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidSnapshotPayload, engine.TradingShard.restoreSnapshotInto(restored, damaged_storage[0..encoded.len]));
    try std.testing.expectError(error.InvalidSnapshotBarrier, run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence - 1, duplicate_storage));
}

test "snapshot restore replays only the stable journal tail without send capability" {
    const prefix = try std.testing.allocator.create(LiveRun);
    defer std.testing.allocator.destroy(prefix);
    try healthyRunInto(prefix);
    try prefix.decision_journal.seal();
    const snapshot_storage = try std.testing.allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.testing.allocator.free(snapshot_storage);
    const encoded = try prefix.shard.snapshot(&prefix.decision_journal, prefix.decision_journal.last_sequence, snapshot_storage);
    const live = try std.testing.allocator.create(engine.TradingShard);
    defer std.testing.allocator.destroy(live);
    @memcpy(std.mem.asBytes(live), std.mem.asBytes(&prefix.shard));
    var tail = journal.Journal.initAt(prefix.decision_journal.last_sequence + 1);
    _ = try engine.applyStable(live, &tail, atGroup(12, .{ .identity = 9, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = 50_000_000_000 } } }));
    try tail.seal();
    const recovered = try std.testing.allocator.create(engine.TradingShard);
    defer std.testing.allocator.destroy(recovered);
    const recovery = try engine.TradingShard.restoreSegmentsInto(recovered, encoded, &.{tail.bytes()});
    try std.testing.expectEqual(journal.ScanStatus.clean, recovery.status);
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &recovered.canonicalStateDigest());
    comptime std.debug.assert(!@hasDecl(engine.SnapshotRecovery, "trySend"));
    const truncated = try engine.TradingShard.restoreSegmentsInto(recovered, encoded, &.{tail.bytes()[0 .. tail.len - 1]});
    try std.testing.expectEqual(journal.ScanStatus.truncated_tail, truncated.status);
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &recovered.canonicalStateDigest());
    var gap = journal.Journal.initAt(prefix.decision_journal.last_sequence + 2);
    try std.testing.expectError(error.SnapshotJournalGap, engine.TradingShard.restoreSegmentsInto(recovered, encoded, &.{gap.bytes()}));
}
