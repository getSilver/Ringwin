//! Deterministic TradingShard acceptance fixture.
//!
//! This module owns fixed scenario data.  It drives the production state
//! machine exclusively through `applyStable`, whose only transition is
//! `TradingShard.apply`.

const std = @import("std");
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
pub const expected_happy_digest = "06fbeb256cfb02360c40668a8ccc34de0d4c8a532a1e0b1ebd4ff50b683c1048";
const expected_trajectory_digests = [_][]const u8{
    expected_happy_digest,
    "b95c50d8d0b8c79b2b82f5191bb4ee031bac8369ebf4f838ff1bc80f86da4cdc",
    "dded7fe60cc6693de322664fbf66b00ee05d177e990c3830644961a6ad514850",
    "103e070525340114edb9fae1bd5c3b880f29c01b990f0fdf4ed3dd45adb938d4",
    expected_happy_digest,
};
pub const order_limit_price: i64 = 50_100_000_000;
pub const settlement_asset: canonical.AssetIdentity = 1;
pub const spot_instrument: engine.oms.Instrument = 1;
pub const swap_instrument: engine.oms.Instrument = 2;
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

pub fn atGroup(group_index: u64, input: engine.CoreTransition) engine.CoreTransition {
    var transition = input;
    const source_time = fixture_utc_base + group_index * 10 * std.time.ns_per_ms;
    transition.source_time = source_time;
    transition.receive_time = source_time + std.time.ns_per_ms;
    transition.monotonic_time = fixture_monotonic_base + group_index * 10 * std.time.ns_per_ms + std.time.ns_per_ms;
    transition.wall_time = source_time + 2 * std.time.ns_per_ms;
    transition.time_presence = .{
        .source = true,
        .receive = true,
        .monotonic = true,
        .wall = true,
    };
    return transition;
}

pub fn canonicalAt(group_index: u64, source_sequence: u64, event: canonical.CanonicalEvent) canonical.EventRecord {
    const source_time = fixture_utc_base + group_index * 10 * std.time.ns_per_ms;
    return .{ .envelope = .{
        .event_type = @intFromEnum(canonical.eventType(event)),
        .schema_version = 1,
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
    }, .event = event };
}

fn quantity(lots: i128) canonical.InstrumentQuantity {
    return .{ .instrument = 3, .rules_version = 1, .lots = lots };
}

fn price(ticks: i128) canonical.InstrumentPrice {
    return .{ .instrument = 3, .rules_version = 1, .ticks = ticks };
}

pub fn snapshotAt(group: u64, source_sequence: u64) canonical.EventRecord {
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

pub fn deltaAt(group: u64, previous: u64, current: u64, bid_price_micros: i64) canonical.EventRecord {
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

pub fn apply(run: *LiveRun, event: anytype) !?engine.OrderCommand {
    return switch (@TypeOf(event)) {
        engine.CoreTransition => engine.applyTypedStable(&run.shard, &run.decision_journal, event),
        canonical.EventRecord => engine.applyStable(&run.shard, &run.decision_journal, event),
        else => @compileError("fixture.apply expects a typed transition or canonical event"),
    };
}

pub fn lifecycleCommand(command_identity: u128, expected_version: u64, kind: engine.operational.CommandKind) engine.CoreTransition {
    return atGroup(40, .{ .identity = @intCast(1_000 + command_identity), .payload = .{ .control_command = .{
        .command_identity = command_identity,
        .content_hash = command_identity * 7_919,
        .target_identity = 1,
        .expected_version = expected_version,
        .expires_at = std.math.maxInt(u64),
        .kind = kind,
    } } });
}

pub fn deRiskCommand(command_identity: u128, expected_version: u64, target_position: i64, warning_identity: u128) engine.CoreTransition {
    var input: engine.CoreTransition = .{ .identity = @intCast(1_000 + command_identity), .payload = .{ .control_command = .{
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

pub fn resolveLatchCommand(command_identity: u128, expected_version: u64, latch_identity: u128) engine.CoreTransition {
    var input: engine.CoreTransition = .{ .identity = @intCast(1_000 + command_identity), .payload = .{ .control_command = .{
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

fn finish(run: *LiveRun) !LiveRun {
    try run.decision_journal.seal();
    return run.*;
}

pub fn genesisEvents(authorization: host_gateway.Authorization, reservation_model: engine.ReservationModel) [14]engine.CoreTransition {
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
        } } }),
        atGroup(2, .{ .identity = 1, .payload = .{ .margin_rules_activated = .{ .version = 1 } } }),
        atGroup(3, .{ .identity = 1, .payload = .{ .account_configuration = .{ .exchange_account_identity = 2 } } }),
        atGroup(4, .{ .identity = 1, .payload = .{ .exchange_balance = .{ .cash_micros = initial_exchange_cash } } }),
        atGroup(5, .{ .identity = 1, .payload = .exchange_positions }),
        atGroup(6, .{ .identity = 1, .payload = .{ .opening_balance = .{ .cash_micros = initial_exchange_cash } } }),
        atGroup(7, .{ .identity = 1, .payload = .{ .virtual_portfolio_activated = .{ .portfolio_identity = 1 } } }),
        atGroup(8, .{ .identity = 1, .payload = .{ .portfolio_transfer = .{ .amount_micros = portfolio_allocation } } }),
        atGroup(9, .{ .identity = 1, .payload = .{ .strategy_activated = .{
            .strategy_identity = authorization.strategy_identity,
            .config_version = authorization.config_version,
            .activation_identity = authorization.activation_identity,
        } } }),
        atGroup(10, .{ .identity = 1, .payload = .{ .primary_lease_granted = .{ .fencing_token = 1 } } }),
        atGroup(11, .{ .identity = 1, .payload = .{ .risk_lease_granted = .{ .amount_micros = risk_lease_total } } }),
        atGroup(11, .{ .identity = 1, .payload = .{ .control_command = .{
            .command_identity = 1,
            .content_hash = 1,
            .target_identity = 1,
            .expected_version = 0,
            .expires_at = std.math.maxInt(u64),
            .kind = .start_recovery,
        } } }),
        atGroup(11, .{ .identity = 1, .payload = .recovery_completed }),
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
    var run: LiveRun = .{ .shard = .{}, .decision_journal = journal.Journal.init() };
    const genesis = genesisEvents(authorization, reservation_model);
    for (genesis) |event| if (try apply(&run, event) != null) return error.UnexpectedCommand;
    return run;
}

pub fn startScenario() !LiveRun {
    return startScenarioAuthorized(defaultAuthorization(), .leveraged);
}

pub fn applyHealthyPrelude(run: *LiveRun) !void {
    if (try apply(run, atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000_000 } })) != null)
        return error.UnexpectedCommand;
    const prelude = [_]canonical.EventRecord{
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
    var run = try startScenario();
    try applyHealthyPrelude(&run);
    return run;
}

fn healthyScenarioAuthorized(authorization: host_gateway.Authorization, reservation_model: engine.ReservationModel) !LiveRun {
    var run = try startScenarioAuthorized(authorization, reservation_model);
    try applyHealthyPrelude(&run);
    return run;
}

pub fn initializedBenchmarkRun() !LiveRun {
    var run = try healthyRun();
    run.shard.trace.len = 0;
    run.decision_journal = journal.Journal.init();
    return run;
}

pub fn replayDigest(run: LiveRun) ![32]u8 {
    const replayed = try engine.replayDigest(
        run.decision_journal.bytes(),
        run.shard.quantity_denominator,
        run.shard.reservation_model,
    );
    if (replayed.status != .clean) return error.ReplayNotEquivalent;
    return replayed.digest;
}

pub fn assertReplayEquivalentConfigured(run: LiveRun, quantity_denominator: i64, reservation_model: engine.ReservationModel) ![32]u8 {
    const live_digest = run.shard.canonicalStateDigest();
    const replayed = try engine.replayDigest(run.decision_journal.bytes(), quantity_denominator, reservation_model);
    if (replayed.status != .clean or !std.mem.eql(u8, &live_digest, &replayed.digest))
        return error.ReplayNotEquivalent;
    return live_digest;
}

pub fn assertReplayEquivalent(run: LiveRun) ![32]u8 {
    return assertReplayEquivalentConfigured(run, contract_denominator, .leveraged);
}

pub fn happyVenueFacts(command: engine.OrderCommand) ![6]canonical.EventRecord {
    if (command.command_id != 1 or command.order_id != 1 or
        command.quantity.lots != happy_order_quantity or
        command.limit_price.ticks != 50_100_000_000 or
        command.reservation.atoms != 11_397_750)
        return error.InvalidOrderCommand;
    const client = try canonical.ClientOrderId.init(command.client_id);
    const venue_order = try canonical.VenueOrderRef.init(1, "fixture-order-1");
    const first_trade = try canonical.VenueTradeRef.init(1, "fixture-trade-1");
    const second_trade = try canonical.VenueTradeRef.init(1, "fixture-trade-2");
    const Report = struct {
        fn make(identity: u128, status: canonical.ExecutionReportStatus, cumulative: i128, remaining: i128, client_order: canonical.ClientOrderId, order_ref: canonical.VenueOrderRef) canonical.ExecutionReport {
            return .{
                .identity = identity,
                .order = 1,
                .client_order_id = client_order,
                .venue_order = order_ref,
                .instrument = 3,
                .exchange_account = 2,
                .revision = @intCast(identity),
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
        canonicalAt(16, 103, .{ .execution_report = Report.make(1, .accepted, 0, 100, client, venue_order) }),
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
        canonicalAt(17, 105, .{ .execution_report = Report.make(2, .partially_filled, 40, 60, client, venue_order) }),
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
        canonicalAt(18, 107, .{ .execution_report = Report.make(3, .filled, 100, 0, client, venue_order) }),
    };
}

fn assertPartialState(shard: engine.TradingShard) !void {
    const economic = shard.economicSummary();
    if (economic.portfolio.swap.quantity != 40 or
        economic.portfolio.swap.open_cost_micros != 199_600_000 or
        economic.exchange.swap.quantity != 40 or
        economic.exchange.swap.open_cost_micros != 199_600_000 or
        economic.portfolio.fee_micros != 149_700 or
        economic.portfolio.usdt_balance_micros != 19_999_850_300 or
        economic.exchange.usdt_balance_micros != 24_999_850_300 or
        shard.position_margin_requirement_micros != 4_400_000 or
        shard.open_order_reservation_micros != 6_838_650 or
        shard.risk_lease_remaining_micros != 9_988_761_350)
        return error.PartialEconomicProjectionMismatch;
}

pub fn runHappyPath() !LiveRun {
    var run = try healthyRun();
    const command = (try apply(&run, atGroup(15, .{ .identity = 1, .payload = .{ .timer = .{ .quantity = happy_order_quantity } } }))) orelse return error.MissingOrderCommand;
    const facts = try happyVenueFacts(command);
    for (facts, 0..) |event, index| {
        if (try apply(&run, event) != null) return error.UnexpectedCommand;
        if (index == 2) try assertPartialState(run.shard);
    }
    if (try apply(&run, atGroup(19, .{ .identity = 2, .payload = .{ .mark_price = 50_200_000_000 } })) != null)
        return error.UnexpectedCommand;
    return finish(&run);
}

pub fn runMarketGap() !LiveRun {
    var run = try healthyRun();
    if (try apply(&run, deltaAt(15, 102, 103, 49_860_000_000)) != null) return error.UnexpectedCommand;
    if (try apply(&run, atGroup(16, .{ .identity = 1, .payload = .{ .timer = .{ .quantity = happy_order_quantity } } })) != null)
        return error.CommandEscapedMarketGap;
    if (try apply(&run, snapshotAt(17, 200)) != null) return error.UnexpectedCommand;
    if (try apply(&run, deltaAt(18, 200, 201, 49_850_000_000)) != null) return error.UnexpectedCommand;
    return finish(&run);
}

pub fn runRiskRejection() !LiveRun {
    var run = try healthyRun();
    if (try apply(&run, atGroup(15, .{ .identity = 1, .payload = .{ .timer = .{ .quantity = 100_001 } } })) != null)
        return error.CommandEscapedRiskRejection;
    return finish(&run);
}

pub fn runUnknownReconciliation() !LiveRun {
    var run = try healthyRun();
    const command = (try apply(&run, atGroup(15, .{ .identity = 1, .payload = .{ .timer = .{ .quantity = happy_order_quantity } } }))) orelse return error.MissingOrderCommand;
    const facts = try happyVenueFacts(command);
    if (try apply(&run, canonicalAt(16, 102, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .unknown } })) != null) return error.UnexpectedCommand;
    if (try apply(&run, canonicalAt(17, 103, .{ .order_reconciliation_result = .{ .identity = 1, .complete = true, .status = .found_live } })) != null) return error.UnexpectedCommand;
    var accepted = facts[1];
    accepted.envelope.identity.sequence = 104;
    accepted.envelope.source_sequence = 104;
    accepted.envelope.raw_evidence.sequence = 104;
    if (try apply(&run, accepted) != null) return error.UnexpectedCommand;
    return finish(&run);
}

pub fn runDuplicateReport() !LiveRun {
    var run = try healthyRun();
    const command = (try apply(&run, atGroup(15, .{ .identity = 1, .payload = .{ .timer = .{ .quantity = happy_order_quantity } } }))) orelse return error.MissingOrderCommand;
    const facts = try happyVenueFacts(command);
    for (facts[0..4]) |event| if (try apply(&run, event) != null) return error.UnexpectedCommand;
    try assertPartialState(run.shard);
    const before_duplicate_fill = run.shard.canonicalStateDigest();
    const duplicate_fill = try run.shard.apply(facts[2]);
    if (duplicate_fill.facts.len != 0 or duplicate_fill.order_command != null or duplicate_fill.oms_commands.len != 0)
        return error.DuplicateFillChangedState;
    if (!std.mem.eql(u8, &before_duplicate_fill, &run.shard.canonicalStateDigest()))
        return error.DuplicateFillChangedState;
    try assertPartialState(run.shard);
    if (run.shard.economic_projection.ledger_summary.transaction_count != 2) return error.DuplicateCreatedLedgerTransaction;
    if (try apply(&run, facts[4]) != null) return error.UnexpectedCommand;
    if (try apply(&run, facts[5]) != null) return error.UnexpectedCommand;
    if (try apply(&run, atGroup(20, .{ .identity = 2, .payload = .{ .mark_price = 50_200_000_000 } })) != null)
        return error.UnexpectedCommand;
    return finish(&run);
}

fn verifyScenario(run: LiveRun) !void {
    const replayed = try engine.replayDigest(
        run.decision_journal.bytes(),
        run.shard.quantity_denominator,
        run.shard.reservation_model,
    );
    if (replayed.status != .clean or
        !std.mem.eql(u8, &run.shard.canonicalStateDigest(), &replayed.digest))
        return error.ReplayNotEquivalent;
}

/// Runs the deterministic acceptance fixture outside the production state module.
pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    if (args.next() != null) {
        return error.UnknownArgument;
    }
    try journal.selfCheck();
    const happy = try runHappyPath();
    const market_gap = try runMarketGap();
    const risk_rejection = try runRiskRejection();
    const unknown = try runUnknownReconciliation();
    const duplicate = try runDuplicateReport();
    for ([_]LiveRun{ happy, market_gap, risk_rejection, unknown, duplicate }) |run| try verifyScenario(run);
    try happy.shard.assertClosures();

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    const digest_hex = std.fmt.bytesToHex(engine.stateDigest(happy.shard), .lower);
    try out.print("trading_engine: zig={s}, mode={s}, self_check=ok\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode) });
    for (happy.shard.trace.events[0..happy.shard.trace.len]) |event|
        try out.print("{d:0>2} {s} id={d}\n", .{ event.sequence, @tagName(event.kind), event.identity });
    const economic = happy.shard.economicSummary();
    try out.print("happy_path: events={d}, order={s}, qty={d}, open_cost={d}, fees={d}, upl={d}, risk_remaining={d}, ledger=closed, economic_projections=complete\ndigest={s}\n", .{ happy.shard.trace.len, @tagName(happy.shard.order_state), happy.shard.filled_quantity, economic.portfolio.swap.open_cost_micros, economic.portfolio.fee_micros, economic.portfolio.unrealized_pnl_micros, happy.shard.risk_lease_remaining_micros, &digest_hex });
    try out.print("journal_records={d}, journal_bytes={d}, replay=equivalent, recovery_checks=ok\n", .{ happy.decision_journal.records, happy.decision_journal.len });
    const scenarios = [_]struct { name: []const u8, run: *const LiveRun }{
        .{ .name = "market-gap-v1", .run = &market_gap },          .{ .name = "risk-rejection-v1", .run = &risk_rejection },
        .{ .name = "unknown-reconciliation-v1", .run = &unknown }, .{ .name = "duplicate-report-v1", .run = &duplicate },
    };
    for (scenarios) |scenario| {
        const digest = std.fmt.bytesToHex(engine.stateDigest(scenario.run.shard), .lower);
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
    reservation_micros: i64,
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
        return .{ .run = try healthyScenarioAuthorized(authorization, .leveraged) };
    }

    pub fn initHealthySpotFixtureFor(authorization: host_gateway.Authorization) !TradingShardHostIngress {
        return .{ .run = try healthyScenarioAuthorized(authorization, .cash) };
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
            .quantity = command.quantity,
            .limit_price = command.limit_price,
            .reservation = command.reservation,
        };
    }

    pub fn summary(self: TradingShardHostIngress) HostIngressSummary {
        var result: HostIngressSummary = .{
            .order_intents = 0,
            .risk_accepts = 0,
            .order_commands = 0,
            .host_rejections = 0,
            .journal_records = self.run.decision_journal.records,
            .order_quantity = self.run.shard.order_quantity,
            .order_limit_price_micros = self.run.shard.order_limit_price_micros,
            .reservation_micros = self.run.shard.open_order_reservation_micros,
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
        if ((try apply(&self.run, canonicalAt(16, identity, .{ .order_dispatch_result = .{ .command = self.run.shard.order_command_id, .state = status } }))) != null)
            return error.DispatchProducedCommand;
    }

    pub fn verifyReplay(self: *TradingShardHostIngress) !void {
        try self.run.decision_journal.seal();
        const replayed = try engine.replayDigest(
            self.run.decision_journal.bytes(),
            self.run.shard.quantity_denominator,
            self.run.shard.reservation_model,
        );
        if (replayed.status != .clean or
            !std.mem.eql(u8, &self.run.shard.canonicalStateDigest(), &replayed.digest))
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
    var gateway = try host_gateway.Gateway.init(config, &subscriptions);
    try gateway.recordPublished(1, 14, 100);
    var frame_storage: [256]u8 = undefined;
    const frame = try host_gateway.encodeOutputOrderFrame(&frame_storage, config, 1, 14, 7, .{
        .time_in_force = .immediate_or_cancel,
        .quantity = 5_000,
        .limit_price_micros = 63_500_000_000,
    });
    const decision = gateway.ingest(frame, 100);
    try std.testing.expect(decision == .accepted);
    var ingress = try TradingShardHostIngress.initHealthySpotFixtureFor(authorization);
    const command = (try ingress.applyDecisionCommand(decision)).?;
    try std.testing.expectEqual(host_gateway.TimeInForce.immediate_or_cancel, command.time_in_force);
    try std.testing.expectEqual(@as(i128, 5_000), command.quantity.lots);
    try std.testing.expectEqual(@as(i128, 3_177_382), command.reservation.atoms);
    try ingress.verifyReplay();
}

test "fixed trajectories retain their sealed barriers and recovery digests" {
    const runs = [_]LiveRun{
        try runHappyPath(),
        try runMarketGap(),
        try runRiskRejection(),
        try runUnknownReconciliation(),
        try runDuplicateReport(),
    };
    for (runs, 0..) |run, index| {
        try std.testing.expect(run.decision_journal.sealed);
        const replayed = try engine.replayDigest(
            run.decision_journal.bytes(),
            run.shard.quantity_denominator,
            run.shard.reservation_model,
        );
        try std.testing.expectEqual(journal.ScanStatus.clean, replayed.status);
        try std.testing.expectEqualSlices(u8, &run.shard.canonicalStateDigest(), &replayed.digest);
        const digest_hex = std.fmt.bytesToHex(run.shard.canonicalStateDigest(), .lower);
        try std.testing.expectEqualSlices(u8, expected_trajectory_digests[index], &digest_hex);
    }
}

test "authoritative snapshot round trips at an exact shard barrier" {
    const run = try runHappyPath();
    var storage: [32 * 1024]u8 = undefined;
    const encoded = try run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence, &storage);
    const restored = try engine.TradingShard.restoreSnapshot(encoded);
    try std.testing.expectEqual(run.decision_journal.last_sequence, restored.barrier);
    try std.testing.expectEqualSlices(u8, &run.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());

    var duplicate_storage: [32 * 1024]u8 = undefined;
    const duplicate = try run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence, &duplicate_storage);
    try std.testing.expectEqualSlices(u8, encoded, duplicate);
    const independent = try runHappyPath();
    var independent_storage: [32 * 1024]u8 = undefined;
    const independent_encoded = try independent.shard.snapshot(&independent.decision_journal, independent.decision_journal.last_sequence, &independent_storage);
    try std.testing.expectEqualSlices(u8, encoded, independent_encoded);
    var damaged_storage: [32 * 1024]u8 = undefined;
    @memcpy(damaged_storage[0..encoded.len], encoded);
    damaged_storage[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidSnapshotPayload, engine.TradingShard.restoreSnapshot(damaged_storage[0..encoded.len]));
    try std.testing.expectError(error.InvalidSnapshotBarrier, run.shard.snapshot(&run.decision_journal, run.decision_journal.last_sequence - 1, &duplicate_storage));
}

test "snapshot restore replays only the stable journal tail without send capability" {
    var prefix = try healthyScenarioAuthorized(defaultAuthorization(), .leveraged);
    try prefix.decision_journal.seal();
    var snapshot_storage: [32 * 1024]u8 = undefined;
    const encoded = try prefix.shard.snapshot(&prefix.decision_journal, prefix.decision_journal.last_sequence, &snapshot_storage);
    var live = prefix.shard;
    var tail = journal.Journal.initAt(prefix.decision_journal.last_sequence + 1);
    _ = try engine.applyStable(&live, &tail, atGroup(12, .{ .identity = 9, .payload = .{ .mark_price = 50_000_000_000 } }));
    try tail.seal();
    const recovered = try engine.TradingShard.restore(encoded, tail.bytes());
    try std.testing.expectEqual(journal.ScanStatus.clean, recovered.status);
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    comptime std.debug.assert(!@hasDecl(engine.SnapshotRecovery, "trySend"));
    const truncated = try engine.TradingShard.restore(encoded, tail.bytes()[0 .. tail.len - 1]);
    try std.testing.expectEqual(journal.ScanStatus.truncated_tail, truncated.status);
    try std.testing.expectEqualSlices(u8, &live.canonicalStateDigest(), &truncated.shard.canonicalStateDigest());
    var gap = journal.Journal.initAt(prefix.decision_journal.last_sequence + 2);
    try std.testing.expectError(error.SnapshotJournalGap, engine.TradingShard.restore(encoded, gap.bytes()));
}
