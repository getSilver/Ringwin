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

const contract_denominator: i64 = 10_000;
const initial_exchange_cash: i64 = 25_000_000_000;
const portfolio_allocation: i64 = 20_000_000_000;
const risk_lease_total: i64 = 10_000_000_000;
const fixture_utc_base: u64 = 1_767_225_600_000_000_000;
const fixture_monotonic_base: u64 = 1_000_000_000;

pub const LiveRun = struct {
    shard: engine.TradingShard,
    decision_journal: journal.Journal,
};

fn atGroup(group_index: u64, input: engine.CoreEvent) engine.CoreEvent {
    var timed = input;
    timed.source_time = fixture_utc_base + group_index * 10 * std.time.ns_per_ms;
    timed.receive_time = timed.source_time + std.time.ns_per_ms;
    timed.monotonic_time = fixture_monotonic_base +
        group_index * 10 * std.time.ns_per_ms + std.time.ns_per_ms;
    timed.wall_time = timed.receive_time + std.time.ns_per_ms;
    timed.time_presence = .{ .source = true, .receive = true, .monotonic = true, .wall = true };
    return timed;
}

fn snapshotAt(group: u64, source_sequence: u64) engine.CoreEvent {
    return atGroup(group, .{ .identity = source_sequence, .payload = .{ .l2_snapshot = .{
        .source_sequence = source_sequence,
        .bid_price_micros = 49_800_000_000,
        .bid_quantity = 1_000,
        .ask_1_price_micros = 49_900_000_000,
        .ask_1_quantity = 40,
        .ask_2_price_micros = 50_100_000_000,
        .ask_2_quantity = 60,
    } } });
}

fn deltaAt(group: u64, previous: u64, current: u64) engine.CoreEvent {
    return atGroup(group, .{ .identity = current, .payload = .{ .l2_delta = .{
        .previous = previous,
        .current = current,
        .bid_price_micros = 49_850_000_000,
        .bid_quantity = 1_000,
    } } });
}

fn apply(run: *LiveRun, event: engine.CoreEvent) !?engine.OrderCommand {
    return engine.applyStable(&run.shard, &run.decision_journal, event);
}

fn start(authorization: host_gateway.Authorization, reservation_model: engine.ReservationModel) !LiveRun {
    var run: LiveRun = .{ .shard = .{}, .decision_journal = journal.Journal.init() };
    const denominator: i64 = switch (reservation_model) {
        .leveraged => contract_denominator,
        .cash => 100_000_000,
    };
    const genesis = [_]engine.CoreEvent{
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
    for (genesis) |event| if (try apply(&run, event) != null) return error.UnexpectedCommand;
    const prelude = [_]engine.CoreEvent{
        atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = 50_000_000_000 } }),
        snapshotAt(13, 100),
        deltaAt(14, 100, 101),
    };
    for (prelude) |event| if (try apply(&run, event) != null) return error.UnexpectedCommand;
    return run;
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
        return .{ .run = try start(authorization, .leveraged) };
    }

    pub fn initHealthySpotFixtureFor(authorization: host_gateway.Authorization) !TradingShardHostIngress {
        return .{ .run = try start(authorization, .cash) };
    }

    pub fn applyDecision(self: *TradingShardHostIngress, decision: host_gateway.Decision) !bool {
        return (try self.applyDecisionCommand(decision)) != null;
    }

    pub fn applyDecisionCommand(self: *TradingShardHostIngress, decision: host_gateway.Decision) !?QualifiedHostOrder {
        const payload: engine.Payload = switch (decision) {
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

    pub fn applyDispatchResult(self: *TradingShardHostIngress, identity: u64, status: engine.DispatchStatus) !void {
        if ((try apply(&self.run, atGroup(16, .{ .identity = identity, .payload = .{ .order_dispatch_result = status } }))) != null)
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
