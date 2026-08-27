const std = @import("std");
const trading = @import("trading_shard.zig");
const coordination = @import("account_coordinator.zig");

const ShardId = coordination.ShardId;
const max_shards = coordination.max_shards;
const Sha256 = std.crypto.hash.sha2.Sha256;

const money_scale: i64 = 1_000_000;
const initial_cash: i64 = 25_000 * money_scale;
const allocation: i64 = 20_000 * money_scale;
const genesis_lease_amount: i64 = 10_000 * money_scale;
const ceiling_micros: i64 = 40_000 * money_scale;
const quantity_denominator: i64 = 10_000;
const mark_price_micros: i64 = 50_000_000_000;
const order_price_micros: i64 = 50_100_000_000;
const fill_price_micros: i64 = 49_900_000_000;
const order_quantity: i64 = 100;
const place_fee_micros: i64 = 400_000;
const exchange_account: u128 = 900;
/// Frozen schema version for emitted four-shard acceptance evidence.
pub const acceptance_schema_version: u16 = 1;
const expected_shared_summary_v1 = "e652a69fc3977ddb395edb6f0f2e6a7efc32d9e07d529c712aea33be6f09e6c2";

const OpLog = struct {
    const Entry = union(enum) {
        publish: struct { identity: u128, summary: coordination.ShardSummary },
        allocate: struct { version: u64, valid_through: u64 },
        fact: coordination.AccountFact,
        reconcile: coordination.MarginObservation,
    };
    entries: [64]Entry = undefined,
    len: usize = 0,

    fn record(self: *OpLog, entry: Entry) !void {
        if (self.len == self.entries.len) return error.OpLogFull;
        self.entries[self.len] = entry;
        self.len += 1;
    }
};

const World = struct {
    shards: [max_shards]trading.TradingShard,
    journals: [max_shards]trading.journal.Journal,
    commands: [max_shards]trading.oms.Command = undefined,
    coordinator: coordination.AccountCoordinator,
    gateway: coordination.SharedExecutionGateway = .{},
    ops: OpLog = .{},
    summary_sequences: [max_shards]u64 = @splat(0),
    next_identity: u128 = 100,

    fn init() World {
        return .{
            .shards = undefined,
            .journals = undefined,
            .coordinator = coordination.AccountCoordinator.init(exchange_account, ceiling_micros, ceiling_micros),
        };
    }

    fn apply(self: *World, index: usize, event: trading.CanonicalEvent) !void {
        _ = try trading.applyStable(&self.shards[index], &self.journals[index], event);
    }

    fn nextId(self: *World) u128 {
        const id = self.next_identity;
        self.next_identity += 1;
        return id;
    }

    fn publishDerivedSummary(self: *World, index: usize) !void {
        const identity = self.nextId();
        const sequence = self.summary_sequences[index] + 1;
        const summary = try coordination.shardSummaryFromShard(
            &self.shards[index],
            @enumFromInt(index),
            sequence,
            @intCast(index + 1),
        );
        _ = try self.coordinator.publishSummary(identity, summary);
        self.summary_sequences[index] = sequence;
        try self.ops.record(.{ .publish = .{ .identity = identity, .summary = summary } });
    }

    fn projectedObservation(self: *World, identity: u128) !coordination.MarginObservation {
        var swap_quantity: i64 = 0;
        var spot_quantity: i64 = 0;
        var swap_margin: i64 = 0;
        var spot_margin: i64 = 0;
        var risk_tier: u8 = 0;
        var distance: i64 = std.math.maxInt(i64);
        for (self.coordinator.summaries) |record| {
            if (!record.present) return error.IncompleteShardSummaries;
            swap_quantity = try std.math.add(i64, swap_quantity, record.value.swap_quantity);
            spot_quantity = try std.math.add(i64, spot_quantity, record.value.spot_quantity);
            swap_margin = try std.math.add(i64, swap_margin, record.value.exchange_margin_micros);
            spot_margin = try std.math.add(i64, spot_margin, record.value.spot_margin_micros);
            risk_tier = @max(risk_tier, record.value.risk_tier);
            distance = @min(distance, record.value.liquidation_distance_ticks);
        }
        return .{
            .identity = identity,
            .barrier = self.coordinator.barrier,
            .venue_net_margin_micros = try std.math.add(i64, spot_margin, swap_margin),
            .venue_swap_quantity = swap_quantity,
            .venue_spot_quantity = spot_quantity,
            .venue_spot_margin_micros = spot_margin,
            .venue_swap_margin_micros = swap_margin,
            .margin_mode = .isolated,
            .rules_version = 1,
            .venue_risk_tier = risk_tier,
            .venue_liquidation_distance_ticks = distance,
        };
    }

    fn acceptFact(self: *World, fact: coordination.AccountFact) !void {
        const deliveries = try self.coordinator.acceptAccountFact(fact);
        try self.ops.record(.{ .fact = fact });
        for (deliveries) |delivery|
            try coordination.applyAccountFactStable(
                delivery,
                delivery.shard_id,
                &self.shards[@intFromEnum(delivery.shard_id)],
                &self.journals[@intFromEnum(delivery.shard_id)],
            );
    }
};

var shard_snapshot_storage: [max_shards][256 * 1024]u8 = undefined;
var coordinator_snapshot_storage: [16384]u8 = undefined;
var tail_journals: [max_shards]trading.journal.Journal = undefined;

fn genesisEvents(index: usize) [14]trading.CanonicalEvent {
    const target: u128 = @intCast(index + 1);
    return .{
        .{ .identity = 1, .payload = .{ .instrument_rules_activated = .{
            .version = 1,
            .instrument_identity = 3,
            .quantity_denominator = quantity_denominator,
            .reservation_model = .leveraged,
        } } },
        .{ .identity = 1, .payload = .{ .margin_rules_activated = .{ .version = 1 } } },
        .{ .identity = 1, .payload = .{ .account_configuration = .{ .exchange_account_identity = exchange_account } } },
        .{ .identity = 1, .payload = .{ .exchange_balance = .{ .cash_micros = initial_cash } } },
        .{ .identity = 1, .payload = .exchange_positions },
        .{ .identity = 1, .payload = .{ .opening_balance = .{ .cash_micros = initial_cash } } },
        .{ .identity = 1, .payload = .{ .virtual_portfolio_activated = .{ .portfolio_identity = index + 11 } } },
        .{ .identity = 1, .payload = .{ .portfolio_transfer = .{ .amount_micros = allocation } } },
        .{ .identity = 1, .payload = .{ .strategy_activated = .{
            .strategy_identity = target,
            .config_version = 1,
            .activation_identity = target,
        } } },
        .{ .identity = 1, .payload = .{ .primary_lease_granted = .{ .fencing_token = index + 1 } } },
        .{ .identity = 1, .payload = .{ .risk_lease_granted = .{ .amount_micros = genesis_lease_amount } } },
        .{ .identity = 1, .payload = .{ .control_command = .{
            .command_identity = 1,
            .content_hash = 1,
            .target_identity = target,
            .expected_version = 0,
            .expires_at = std.math.maxInt(u64),
            .kind = .start_recovery,
        } } },
        .{ .identity = 1, .payload = .recovery_completed },
        .{ .identity = 2, .payload = .{ .control_command = .{
            .command_identity = 2,
            .content_hash = 2,
            .target_identity = target,
            .expected_version = 2,
            .expires_at = std.math.maxInt(u64),
            .kind = .enable_trading,
        } } },
    };
}

fn replayJournalSegment(shard: *trading.TradingShard, bytes: []const u8) !void {
    var reader = try trading.journal.Reader.init(bytes);
    while (true) {
        switch (try reader.next()) {
            .record => |record| {
                if (record.flags & trading.journal.input_flag != 0)
                    _ = try shard.apply(try trading.decodeStableInput(record));
            },
            .end => |status| {
                if (status != .clean) return error.TruncatedShardTail;
                return;
            },
        }
    }
}

fn replayShardFromJournal(bytes: []const u8) !trading.TradingShard {
    var shard: trading.TradingShard = .{};
    try replayJournalSegment(&shard, bytes);
    return shard;
}

fn replayCoordination(live: *const World) !coordination.AccountCoordinator {
    var coordinator = coordination.AccountCoordinator.init(exchange_account, ceiling_micros, ceiling_micros);
    for (live.ops.entries[0..live.ops.len]) |entry| switch (entry) {
        .publish => |p| _ = try coordinator.publishSummary(p.identity, p.summary),
        .allocate => |a| _ = try coordinator.allocateLeases(a.version, a.valid_through),
        .fact => |fact| _ = try coordinator.acceptAccountFact(fact),
        .reconcile => |observation| _ = try coordinator.reconcileMargin(observation),
    };
    return coordinator;
}

fn fence(shard: *trading.TradingShard) void {
    shard.operational_state.trading_authorized = false;
    shard.operational_state.mode = .recovering;
}

fn sharedSummary(
    barrier: u64,
    shards: []const trading.TradingShard,
    coordinator_digest: *const [Sha256.digest_length]u8,
) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    var encoded_barrier: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded_barrier, barrier, .little);
    hasher.update(&encoded_barrier);
    for (shards) |shard| hasher.update(&shard.canonicalStateDigest());
    hasher.update(coordinator_digest);
    var result: [Sha256.digest_length]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn assertLedgersClosed(world: *const World) !void {
    for (0..max_shards) |index| {
        const shard = &world.shards[index];
        try std.testing.expectEqual(
            shard.economicSummary().portfolio.usdt_balance_micros +
                shard.treasury_cash_micros +
                shard.economicSummary().suspense_usdt_micros,
            shard.economicSummary().exchange.usdt_balance_micros,
        );
        try std.testing.expectEqual(
            shard.economicSummary().portfolio.swap.quantity,
            shard.economicSummary().exchange.swap.quantity,
        );
        try std.testing.expectEqual(world.journals[index].last_sequence, shard.trace.len);
    }
}

/// Versioned deterministic evidence emitted by the four-shard acceptance entry.
pub const FourShardEvidence = struct {
    schema_version: u16,
    coordinator_barrier: u64,
    shard_barriers: [max_shards]u64,
    shard_digests: [max_shards][Sha256.digest_length]u8,
    coordinator_digest: [Sha256.digest_length]u8,
    shared_summary: [Sha256.digest_length]u8,
    live_gateway_submissions: u8,
    replay_send_capability: bool,
};

/// Runs the fail-fast four-shard live, replay, snapshot-tail, and recovery fixture.
pub fn runFourShardAcceptance() !FourShardEvidence {
    const replay_send_capability = @hasField(coordination.AccountRecovery, "gateway") or
        @hasDecl(coordination.AccountRecovery, "trySend");
    comptime std.debug.assert(!replay_send_capability);
    var world = World.init();
    for (&world.shards, &world.journals, 0..) |*shard, *journal, index| {
        shard.* = .{};
        journal.* = trading.journal.Journal.init();
        const events = genesisEvents(index);
        for (events) |event| _ = try trading.applyStable(shard, journal, event);
        try std.testing.expect(shard.genesisReady());
        try std.testing.expect(shard.operational_state.effectiveTradingAuthority());
    }

    for (0..max_shards) |index| {
        try world.apply(index, .{ .identity = 5, .payload = .{ .mark_price = mark_price_micros } });
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 10, .count = 1 };
        group.members[0] = .{
            .intent_sequence = 10,
            .operation = .place,
            .instrument = .btc_usdt_swap,
            .side = if (index == max_shards - 1) .sell else .buy,
            .quantity = order_quantity,
            .limit_price_micros = order_price_micros,
            .reservation_micros = 11_400_000,
        };
        const placed = try trading.applyStable(&world.shards[index], &world.journals[index], .{
            .identity = 6,
            .payload = .{ .oms_intent_group = group },
        });
        try std.testing.expect(placed == null);
        const emitted = world.shards[index].oms.emitted();
        try std.testing.expectEqual(@as(usize, 1), emitted.len);
        world.commands[index] = emitted[0];
    }

    for (0..max_shards) |index| {
        const receipt = try world.gateway.submit(.{
            .exchange_account = exchange_account,
            .shard_id = @enumFromInt(index),
            .fencing_token = @intCast(index + 1),
            .command = world.commands[index],
        });
        try std.testing.expectEqual(@as(ShardId, @enumFromInt(index)), receipt.shard_id);
    }
    try std.testing.expectError(error.DuplicateCommandIdentity, world.gateway.submit(.{
        .exchange_account = exchange_account,
        .shard_id = .shard_0,
        .fencing_token = 1,
        .command = world.commands[0],
    }));
    try std.testing.expectError(error.CrossAccountGatewayRequest, world.gateway.submit(.{
        .exchange_account = 901,
        .shard_id = .shard_0,
        .fencing_token = 99,
        .command = world.commands[0],
    }));

    for (0..max_shards) |index| {
        const outcome: coordination.GatewayOutcome = .{
            .exchange_account = exchange_account,
            .shard_id = @enumFromInt(index),
            .command_id = world.commands[index].command_id,
            .order_id = world.commands[index].order_id,
            .revision = world.commands[index].revision,
            .fencing_token = @intCast(index + 1),
            .state = .submitted,
        };
        _ = try world.gateway.complete(outcome);
        try world.gateway.applyOutcomeStable(outcome, @enumFromInt(index), &world.shards[index], &world.journals[index]);
        try std.testing.expectError(error.CrossShardDelivery, world.gateway.applyOutcomeStable(
            outcome,
            @enumFromInt((index + 1) % max_shards),
            &world.shards[(index + 1) % max_shards],
            &world.journals[(index + 1) % max_shards],
        ));
        try world.apply(index, .{ .identity = @intCast(20 + index), .payload = .{ .oms_execution_report = .{
            .report_id = @intCast(index + 1),
            .order_id = world.commands[index].order_id,
            .revision = 1,
            .status = .accepted,
            .cumulative_quantity = 0,
            .remaining_quantity = order_quantity,
        } } });
    }
    const unknown_outcome = try world.gateway.complete(.{
        .exchange_account = exchange_account,
        .shard_id = .shard_2,
        .command_id = world.commands[2].command_id,
        .order_id = world.commands[2].order_id,
        .revision = world.commands[2].revision,
        .fencing_token = 3,
        .state = .unknown,
    });
    try std.testing.expectEqual(trading.oms.DispatchState.unknown, unknown_outcome.state);
    var conflicting = coordination.GatewayOutcome{
        .exchange_account = exchange_account,
        .shard_id = .shard_0,
        .command_id = world.commands[0].command_id,
        .order_id = world.commands[0].order_id + 1,
        .revision = 1,
        .fencing_token = 1,
        .state = .submitted,
    };
    try std.testing.expectError(error.GatewayOutcomeIdentityConflict, world.gateway.complete(conflicting));
    conflicting.state = .not_sent;
    try std.testing.expectError(error.GatewayOutcomeIdentityConflict, world.gateway.outcomeEvent(conflicting));

    for (0..max_shards) |index| {
        try world.apply(index, .{ .identity = @intCast(30 + index), .payload = .{ .economic_fill = .{
            .fill_id = @intCast(40 + index),
            .order_id = world.commands[index].order_id,
            .quantity = 40,
            .price_micros = fill_price_micros,
            .fee_micros = place_fee_micros,
        } } });
    }
    try world.apply(0, .{ .identity = 35, .payload = .{ .economic_fill = .{
        .fill_id = 45,
        .order_id = world.commands[0].order_id,
        .quantity = 60,
        .price_micros = fill_price_micros,
        .fee_micros = place_fee_micros,
    } } });
    try assertLedgersClosed(&world);
    try std.testing.expectEqual(order_quantity, world.shards[0].economicSummary().portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i64, 40), world.shards[1].economicSummary().exchange.swap.quantity);
    try std.testing.expectEqual(@as(i64, 40), world.shards[2].economicSummary().exchange.swap.quantity);
    try std.testing.expectEqual(@as(i64, -40), world.shards[3].economicSummary().exchange.swap.quantity);

    for (0..max_shards) |index| try world.publishDerivedSummary(index);
    const allocated_version: u64 = 2;
    const valid_through: u64 = world.coordinator.barrier + 50;
    const leases = try world.coordinator.allocateLeases(allocated_version, valid_through);
    try world.ops.record(.{ .allocate = .{ .version = allocated_version, .valid_through = valid_through } });
    const gross = try world.coordinator.grossPortfolioMargin();
    var limit_total: i64 = 0;
    var used_total: i64 = 0;
    for (leases) |lease| {
        limit_total = try std.math.add(i64, limit_total, lease.limit_micros);
        used_total = try std.math.add(i64, used_total, lease.used_micros);
        try std.testing.expect(lease.open);
        try std.testing.expect(lease.used_micros <= lease.limit_micros);
    }
    try std.testing.expectEqual(used_total, gross);
    try std.testing.expect(gross <= ceiling_micros);
    try std.testing.expect(limit_total <= ceiling_micros);

    const snapshot_fact: coordination.AccountFact = .{
        .identity = world.nextId(),
        .exchange_account = exchange_account,
        .version = 1,
        .barrier = 1,
        .payload = .{ .account_snapshot = .{
            .cash_micros = initial_cash - place_fee_micros,
            .spot_quantity = 0,
            .swap_quantity = 0,
            .margin_micros = 0,
        } },
    };
    try world.acceptFact(snapshot_fact);
    try std.testing.expectEqual(@as(usize, 0), (try world.coordinator.acceptAccountFact(snapshot_fact)).len);
    for (0..max_shards) |index|
        try std.testing.expect(world.shards[index].economicSummary().reconciliation_break);

    for (0..max_shards) |index| try world.publishDerivedSummary(index);
    const healthy_observation = try world.projectedObservation(world.nextId());
    try world.ops.record(.{ .reconcile = healthy_observation });
    const healthy_gate = try world.coordinator.reconcileMargin(healthy_observation);
    try std.testing.expect(healthy_gate.open);
    try std.testing.expect(!healthy_gate.latched);
    try std.testing.expect(world.coordinator.account_netting_benefit_micros > 0);
    for (world.coordinator.leases[0..world.coordinator.lease_count]) |lease|
        try std.testing.expect(lease.used_micros <= lease.limit_micros);

    const pre_fault_digests: [max_shards][Sha256.digest_length]u8 = .{
        world.shards[0].canonicalStateDigest(),
        world.shards[1].canonicalStateDigest(),
        world.shards[2].canonicalStateDigest(),
        world.shards[3].canonicalStateDigest(),
    };
    try world.acceptFact(.{
        .identity = world.nextId(),
        .exchange_account = exchange_account,
        .version = 2,
        .barrier = 2,
        .payload = .{ .forced_execution = .{
            .owner = .shard_1,
            .quantity = -2,
            .price_micros = fill_price_micros,
            .fee_micros = 1,
        } },
    });
    try std.testing.expect(!world.shards[1].operational_state.effectiveTradingAuthority());
    try std.testing.expectEqualSlices(u8, &pre_fault_digests[0], &world.shards[0].canonicalStateDigest());
    try std.testing.expectEqualSlices(u8, &pre_fault_digests[2], &world.shards[2].canonicalStateDigest());
    try std.testing.expectEqualSlices(u8, &pre_fault_digests[3], &world.shards[3].canonicalStateDigest());

    try world.acceptFact(.{
        .identity = world.nextId(),
        .exchange_account = exchange_account,
        .version = 3,
        .barrier = 3,
        .payload = .{ .forced_execution = .{
            .owner = null,
            .quantity = 1,
            .price_micros = fill_price_micros,
            .fee_micros = 1,
        } },
    });
    try std.testing.expect(world.shards[0].economicSummary().suspense_usdt_micros != 0);
    try std.testing.expect(world.shards[0].economicSummary().reconciliation_break);
    try std.testing.expectEqualSlices(u8, &pre_fault_digests[2], &world.shards[2].canonicalStateDigest());

    for (0..max_shards) |index| try world.publishDerivedSummary(index);

    var broken_observation = try world.projectedObservation(world.nextId());
    broken_observation.venue_swap_quantity += 1;
    try world.ops.record(.{ .reconcile = broken_observation });
    const broken_gate = try world.coordinator.reconcileMargin(broken_observation);
    try std.testing.expect(!broken_gate.open);
    try std.testing.expect(broken_gate.latched);
    for (world.coordinator.leases[0..world.coordinator.lease_count]) |lease| {
        try std.testing.expect(lease.open);
        try std.testing.expectEqual(lease.used_micros, lease.limit_micros);
    }

    const gate_deliveries = world.coordinator.accountGateDeliveries(broken_gate);
    for (gate_deliveries) |delivery|
        try coordination.applyAccountGateStable(
            delivery,
            delivery.shard_id,
            &world.shards[@intFromEnum(delivery.shard_id)],
            &world.journals[@intFromEnum(delivery.shard_id)],
        );
    for (0..max_shards) |index| {
        try std.testing.expect(!world.shards[index].operational_state.effectiveTradingAuthority());
        try std.testing.expect(world.shards[index].operational_state.mayReduceOnly());
    }

    try std.testing.expectEqual(trading.oms.OrderState.pending_cancel, world.shards[1].oms.orders[0].state);
    try world.apply(1, .{ .identity = 41, .payload = .{ .oms_execution_report = .{
        .report_id = 42,
        .order_id = world.commands[1].order_id,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = 0,
        .remaining_quantity = order_quantity,
    } } });
    try std.testing.expectEqual(trading.oms.OrderState.canceled, world.shards[1].oms.orders[0].state);

    var reduce_group: trading.oms.IntentGroup = .{ .first_intent_sequence = 21, .count = 1 };
    reduce_group.members[0] = .{
        .intent_sequence = 21,
        .operation = .place,
        .instrument = .btc_usdt_swap,
        .side = .sell,
        .portfolio_reduce_only = true,
        .quantity = 38,
        .limit_price_micros = fill_price_micros,
        .reservation_micros = 200_000,
    };
    _ = try trading.applyStable(&world.shards[1], &world.journals[1], .{ .identity = 43, .payload = .{ .oms_intent_group = reduce_group } });
    const reducing = world.shards[1].oms.emitted();
    try std.testing.expectEqual(@as(usize, 1), reducing.len);
    try std.testing.expectEqual(trading.oms.Operation.place, reducing[0].operation);

    for (0..max_shards) |index| try world.publishDerivedSummary(index);

    for (&world.journals) |*journal| try journal.seal();
    var live_barriers: [max_shards]u64 = undefined;
    var shard_snapshots: [max_shards][]const u8 = undefined;
    var shard_tails: [max_shards][]const u8 = undefined;
    for (0..max_shards) |index| {
        live_barriers[index] = world.shards[index].trace.len;
        shard_snapshots[index] = try world.shards[index].snapshot(&world.journals[index], live_barriers[index], &shard_snapshot_storage[index]);
        tail_journals[index] = trading.journal.Journal.initAt(live_barriers[index] + 1);
    }
    const coordinator_snapshot = try world.coordinator.snapshot(&coordinator_snapshot_storage);

    // The recovery point is the five sealed snapshots. Both tails advance only after it.
    _ = try trading.applyStable(&world.shards[1], &tail_journals[1], .{
        .identity = 500,
        .payload = .{ .l2_snapshot = .{
            .source_sequence = 1,
            .bid_price_micros = mark_price_micros - 100_000_000,
            .bid_quantity = 1_000,
            .ask_1_price_micros = mark_price_micros + 100_000_000,
            .ask_1_quantity = 1_000,
            .ask_2_price_micros = mark_price_micros + 200_000_000,
            .ask_2_quantity = 1_000,
        } },
    });
    const tail_summary_identity = world.nextId();
    const tail_summary_sequence = world.summary_sequences[1] + 1;
    const tail_summary = try coordination.shardSummaryFromShard(&world.shards[1], .shard_1, tail_summary_sequence, 2);
    var coordinator_tail = coordination.CoordinationJournal.initAt(1);
    const tail_event: coordination.CoordinationEvent = .{ .publish_summary = .{
        .identity = tail_summary_identity,
        .summary = tail_summary,
    } };
    try coordinator_tail.append(tail_event);
    _ = try world.coordinator.publishSummary(tail_summary_identity, tail_summary);
    world.summary_sequences[1] = tail_summary_sequence;
    try world.ops.record(.{ .publish = .{ .identity = tail_summary_identity, .summary = tail_summary } });
    try coordinator_tail.seal();
    for (0..max_shards) |index| {
        try tail_journals[index].seal();
        shard_tails[index] = tail_journals[index].bytes();
    }

    var replayed_shards: [max_shards]trading.TradingShard = undefined;
    for (0..max_shards) |index| {
        replayed_shards[index] = try replayShardFromJournal(world.journals[index].bytes());
        try replayJournalSegment(&replayed_shards[index], shard_tails[index]);
    }
    for (0..max_shards) |index|
        try std.testing.expectEqualSlices(
            u8,
            &world.shards[index].canonicalStateDigest(),
            &replayed_shards[index].canonicalStateDigest(),
        );
    const replayed_coordinator = try replayCoordination(&world);
    try std.testing.expectEqualSlices(u8, &world.coordinator.digest(), &replayed_coordinator.digest());
    try std.testing.expectEqual(world.coordinator.barrier, replayed_coordinator.barrier);

    var path_b = try coordination.AccountRecovery.beginWithCoordinatorTail(coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, shard_tails);
    try std.testing.expect(path_b.coordinator.recovery_only);
    try std.testing.expectEqualSlices(u8, &world.coordinator.digest(), &path_b.coordinator.digest());
    try std.testing.expectEqual(world.coordinator.barrier, path_b.coordinator.barrier);
    try std.testing.expectError(error.CoordinatorRecoveryOnly, path_b.coordinator.allocateLeases(99, path_b.coordinator.barrier + 1));
    for (0..max_shards) |index| {
        try std.testing.expectEqual(trading.operational.OperationalMode.recovering, path_b.shards[index].operational_state.mode);
        try std.testing.expect(!path_b.shards[index].operational_state.effectiveTradingAuthority());
        try std.testing.expectEqual(world.shards[index].oms.order_count, path_b.shards[index].oms.order_count);
    }
    try std.testing.expectError(error.FreshMarginObservationRequired, path_b.completeCoordinatorRecovery());
    var recovery_observation = try world.projectedObservation(9001);
    recovery_observation.barrier = path_b.coordinator.barrier;
    const latched_recovery = try path_b.coordinator.reconcileMargin(recovery_observation);
    try std.testing.expect(latched_recovery.latched);
    try std.testing.expectError(error.MarginReconciliationRequired, path_b.completeCoordinatorRecovery());

    var path_success = try coordination.AccountRecovery.beginWithCoordinatorTail(coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, shard_tails);
    _ = try path_success.coordinator.reconcileMargin(recovery_observation);
    _ = try path_success.coordinator.resolveMarginGate(recovery_observation.identity);
    try path_success.completeCoordinatorRecovery();
    try std.testing.expect(!path_success.coordinator.recovery_only);
    try std.testing.expectEqual(try world.coordinator.grossPortfolioMargin(), try path_success.coordinator.grossPortfolioMargin());
    try std.testing.expectEqual(
        @max((try path_success.coordinator.grossPortfolioMargin()) - recovery_observation.venue_net_margin_micros, 0),
        path_success.coordinator.account_netting_benefit_micros,
    );
    for (0..max_shards) |index| {
        try std.testing.expectEqual(world.shards[index].oms.order_count, path_success.shards[index].oms.order_count);
        try std.testing.expectEqual(@as(usize, 0), path_success.shards[index].oms.emitted().len);
    }

    var path_c = try coordination.AccountRecovery.beginWithCoordinatorTail(coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, shard_tails);
    try std.testing.expectEqualSlices(u8, &world.coordinator.digest(), &path_c.coordinator.digest());
    const mid_crash_observation = recovery_observation;
    _ = try path_c.coordinator.reconcileMargin(mid_crash_observation);
    path_c = try coordination.AccountRecovery.beginWithCoordinatorTail(coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, shard_tails);
    try std.testing.expectEqualSlices(u8, &world.coordinator.digest(), &path_c.coordinator.digest());
    try std.testing.expectError(error.FreshMarginObservationRequired, path_c.completeCoordinatorRecovery());
    _ = try path_c.coordinator.reconcileMargin(mid_crash_observation);
    try std.testing.expectError(error.MarginReconciliationRequired, path_c.completeCoordinatorRecovery());
    try std.testing.expectEqualSlices(u8, &path_b.coordinator.digest(), &path_c.coordinator.digest());

    var evidence_coordinator = replayed_coordinator;
    _ = try evidence_coordinator.reconcileMargin(recovery_observation);

    for (&replayed_shards) |*shard| fence(shard);
    var fenced_live: [max_shards]trading.TradingShard = world.shards;
    for (&fenced_live) |*shard| fence(shard);
    for (0..max_shards) |index| {
        try std.testing.expectEqualSlices(
            u8,
            &fenced_live[index].canonicalStateDigest(),
            &replayed_shards[index].canonicalStateDigest(),
        );
        try std.testing.expectEqualSlices(
            u8,
            &fenced_live[index].canonicalStateDigest(),
            &path_b.shards[index].canonicalStateDigest(),
        );
        try std.testing.expectEqualSlices(
            u8,
            &path_b.shards[index].canonicalStateDigest(),
            &path_c.shards[index].canonicalStateDigest(),
        );
    }

    const shared_a = sharedSummary(evidence_coordinator.barrier, &replayed_shards, &evidence_coordinator.digest());
    const shared_b = sharedSummary(path_b.coordinator.barrier, &path_b.shards, &path_b.coordinator.digest());
    const shared_c = sharedSummary(path_c.coordinator.barrier, &path_c.shards, &path_c.coordinator.digest());
    try std.testing.expectEqualSlices(u8, &shared_a, &shared_b);
    try std.testing.expectEqualSlices(u8, &shared_b, &shared_c);
    const shared_hex = std.fmt.bytesToHex(shared_a, .lower);
    if (!std.mem.eql(u8, expected_shared_summary_v1, &shared_hex))
        return error.FourShardEvidenceDrift;
    try std.testing.expectEqual(@as(u8, max_shards), world.gateway.count);

    var shard_digests: [max_shards][Sha256.digest_length]u8 = undefined;
    var shard_barriers: [max_shards]u64 = undefined;
    for (0..max_shards) |index| {
        shard_digests[index] = fenced_live[index].canonicalStateDigest();
        shard_barriers[index] = fenced_live[index].trace.len;
    }
    return .{
        .schema_version = acceptance_schema_version,
        .coordinator_barrier = path_b.coordinator.barrier,
        .shard_barriers = shard_barriers,
        .shard_digests = shard_digests,
        .coordinator_digest = evidence_coordinator.digest(),
        .shared_summary = shared_a,
        .live_gateway_submissions = world.gateway.count,
        .replay_send_capability = replay_send_capability,
    };
}

test "four-shard acceptance entry stops at the first broken assertion" {
    _ = try runFourShardAcceptance();
}
