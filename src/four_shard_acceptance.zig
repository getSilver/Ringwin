const std = @import("std");
const trading = @import("trading_shard.zig");
const coordination = @import("account_coordinator.zig");
const production_contract = @import("production_contract.zig");

const ShardId = coordination.ShardId;
const max_shards = coordination.max_shards;
const Sha256 = std.crypto.hash.sha2.Sha256;
const swap_instrument: trading.oms.Instrument = 3;
const settlement_asset: trading.canonical.AssetIdentity = 1;

const money_scale: i128 = 1_000_000;
const initial_cash: i128 = 25_000 * money_scale;
const allocation: i128 = 20_000 * money_scale;
const genesis_lease_amount: i128 = 10_000 * money_scale;
const ceiling_atoms: i128 = 40_000 * money_scale;
const quantity_denominator: i64 = 10_000;
const mark_price_atoms: i128 = 50_000_000_000;
const order_price_ticks: i64 = 50_100_000_000;
const fill_price_ticks: i64 = 49_900_000_000;
const order_quantity: i64 = 100;
const place_fee_atoms: i128 = 400_000;
const exchange_account: u128 = 900;
/// Frozen schema version for emitted four-shard acceptance evidence.
pub const acceptance_schema_version: u16 = production_contract.acceptance_schema_version;
// StateDigestV11 / journal40 / depth schema14 + Coordinator v9;
// recaptured only after economics and three-path recovery equality.
const expected_shared_summary = "3e300e599dd3cff0360d7f21ee359d10781d18a11bf13babca14969b472e4e3e";

fn applyCoreStable(shard: *trading.TradingShard, stable_journal: *trading.journal.Journal, input: trading.CoreEvent) !?trading.OrderCommand {
    return trading.applyStable(shard, stable_journal, .{ .core = input });
}

const OpLog = struct {
    const Entry = union(enum) {
        publish: struct { identity: u128, summary: coordination.ShardSummary },
        allocate: struct { version: u64, valid_through: u64 },
        fact: coordination.AccountFact,
        forced_allocation: coordination.ForcedExecutionAllocation,
        forced_ack: struct { allocation_identity: u128, slice_index: u8 },
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
    coordination_journal: coordination.CoordinationJournal = coordination.CoordinationJournal.initAt(1),
    ownership: coordination.GatewayOwnership = .{},
    ops: OpLog = .{},
    summary_sequences: [max_shards]u64 = @splat(0),
    next_identity: u128 = 100,

    fn initInto(self: *World) void {
        self.coordinator = coordination.AccountCoordinator.init(exchange_account, ceiling_atoms, ceiling_atoms);
        self.coordination_journal = coordination.CoordinationJournal.initAt(1);
        self.ownership = .{};
        self.ops = .{};
        self.summary_sequences = @splat(0);
        self.next_identity = 100;
    }

    fn apply(self: *World, index: usize, event: trading.CoreEvent) !void {
        _ = try applyCoreStable(&self.shards[index], &self.journals[index], event);
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
        var spot_asset_atoms: i128 = 0;
        var swap_margin: i128 = 0;
        var spot_margin: i128 = 0;
        var risk_tier: u8 = 0;
        var distance: i64 = std.math.maxInt(i64);
        for (self.coordinator.summaries) |record| {
            if (!record.present) return error.IncompleteShardSummaries;
            swap_quantity = try std.math.add(i64, swap_quantity, record.value.swap_quantity);
            spot_asset_atoms = try std.math.add(i128, spot_asset_atoms, record.value.spot_asset_atoms);
            swap_margin = try std.math.add(i128, swap_margin, record.value.exchange_margin_atoms);
            spot_margin = try std.math.add(i128, spot_margin, record.value.spot_margin_atoms);
            risk_tier = @max(risk_tier, record.value.risk_tier);
            distance = @min(distance, record.value.liquidation_distance_ticks);
        }
        return .{
            .identity = identity,
            .barrier = self.coordinator.barrier,
            .venue_net_margin_atoms = try std.math.add(i128, spot_margin, swap_margin),
            .venue_swap_quantity = swap_quantity,
            .venue_spot_asset_atoms = spot_asset_atoms,
            .venue_spot_margin_atoms = spot_margin,
            .venue_swap_margin_atoms = swap_margin,
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

    fn allocateForced(self: *World, allocation_fact: coordination.ForcedExecutionAllocation) !void {
        const deliveries = try self.coordinator.commitForcedAllocation(&self.coordination_journal, allocation_fact);
        try self.ops.record(.{ .forced_allocation = allocation_fact });
        for (deliveries) |delivery| {
            try coordination.applyForcedDeliveryStable(&self.coordinator, &self.coordination_journal, delivery, delivery.shard_id, &self.shards[@intFromEnum(delivery.shard_id)], &self.journals[@intFromEnum(delivery.shard_id)]);
            try self.ops.record(.{ .forced_ack = .{ .allocation_identity = delivery.allocation_identity, .slice_index = delivery.slice_index } });
        }
    }
};

var shard_snapshot_storage: [max_shards][@import("durable_store.zig").max_snapshot_bytes]u8 = undefined;
var coordinator_snapshot_storage: [16384]u8 = undefined;
var tail_journals: [max_shards]trading.journal.Journal = undefined;

fn genesisEvents(index: usize) [15]trading.CoreEvent {
    const target: u128 = @intCast(index + 1);
    return .{
        .{ .identity = 1, .payload = .{ .instrument_rules_activated = .{
            .venue = 1,
            .version = 1,
            .instrument_identity = 3,
            .quantity_denominator = quantity_denominator,
            .reservation_model = .leveraged,
        } } },
        .{ .identity = 1, .payload = .{ .margin_rules_activated = .{ .version = 1 } } },
        .{ .identity = 1, .payload = .{ .account_configuration = .{ .exchange_account_identity = exchange_account } } },
        .{ .identity = 1, .payload = .{ .exchange_balance = .{ .cash_atoms = initial_cash } } },
        .{ .identity = 1, .payload = .exchange_positions },
        .{ .identity = 1, .payload = .{ .opening_balance = .{ .cash_atoms = initial_cash } } },
        .{ .identity = 1, .payload = .{ .virtual_portfolio_activated = .{ .portfolio_identity = index + 11 } } },
        .{ .identity = 1, .payload = .{ .portfolio_transfer = .{ .amount_atoms = allocation } } },
        .{ .identity = 1, .payload = .{ .strategy_activated = .{
            .strategy_identity = target,
            .config_version = 1,
            .activation_identity = target,
        } } },
        .{ .identity = 1, .payload = .{ .primary_lease_granted = .{ .fencing_token = index + 1 } } },
        .{ .identity = 1, .payload = .{ .risk_lease_granted = .{ .amount_atoms = genesis_lease_amount } } },
        .{ .identity = 1, .payload = .{ .control_command = .{
            .command_identity = 1,
            .content_hash = 1,
            .target_identity = target,
            .expected_version = 0,
            .expires_at = std.math.maxInt(u64),
            .kind = .start_recovery,
        } } },
        .{ .identity = 1, .payload = .recovery_completed },
        .{ .identity = 4, .payload = .{ .instrument_trading_authorization = .{
            .exchange_account = exchange_account,
            .instrument = swap_instrument,
            .strategy_activation_identity = target,
            .config_version = 1,
            .expected_version = 0,
            .enabled = true,
        } } },
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

fn replayShardFromJournalInto(destination: *trading.TradingShard, initial: *const trading.TradingShard, bytes: []const u8) !void {
    const status = try trading.recoverStableInto(destination, initial, bytes);
    if (status != .clean) return error.TruncatedShardTail;
}

fn replayCoordination(live: *const World) !coordination.AccountCoordinator {
    var coordinator = coordination.AccountCoordinator.init(exchange_account, ceiling_atoms, ceiling_atoms);
    var ack_journal = coordination.CoordinationJournal.initAt(1);
    for (live.ops.entries[0..live.ops.len]) |entry| switch (entry) {
        .publish => |p| _ = try coordinator.publishSummary(p.identity, p.summary),
        .allocate => |a| _ = try coordinator.allocateLeases(a.version, a.valid_through),
        .fact => |fact| _ = try coordinator.acceptAccountFact(fact),
        .forced_allocation => |allocation_fact| _ = try coordinator.allocateForcedExecution(allocation_fact),
        .forced_ack => |ack| {
            for (try coordinator.pendingForcedDeliveries()) |delivery| {
                if (delivery.allocation_identity != ack.allocation_identity or delivery.slice_index != ack.slice_index) continue;
                try coordinator.ackForcedDeliveryFromShard(&ack_journal, delivery, &live.shards[@intFromEnum(delivery.shard_id)]);
                break;
            }
        },
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
            shard.economicSummary().portfolio.usdt_balance_atoms +
                shard.economicSummary().treasury_usdt_atoms +
                shard.economicSummary().suspense_usdt_atoms,
            shard.economicSummary().exchange.usdt_balance_atoms,
        );
        try std.testing.expectEqual(
            shard.economicSummary().portfolio.swap.quantity,
            shard.economicSummary().exchange.swap.quantity,
        );
        try std.testing.expectEqual(world.journals[index].last_sequence, shard.authoritativeBarrier());
    }
}

/// Versioned deterministic evidence emitted by the four-shard acceptance entry.
pub const FourShardEvidence = struct {
    schema_version: u16,
    journal_schema_version: u16,
    state_schema_version: u32,
    coordinator_barrier: u64,
    shard_barriers: [max_shards]u64,
    shard_digests: [max_shards][Sha256.digest_length]u8,
    coordinator_digest: [Sha256.digest_length]u8,
    shared_summary: [Sha256.digest_length]u8,
    owned_command_count: u8,
    replay_send_capability: bool,
};

/// Runs the fail-fast four-shard live, replay, snapshot-tail, and recovery fixture.
pub fn runFourShardAcceptance() !FourShardEvidence {
    const replay_send_capability = @hasField(coordination.AccountRecovery, "gateway") or
        @hasDecl(coordination.AccountRecovery, "trySend");
    comptime std.debug.assert(!replay_send_capability);
    const allocator = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
    const world = try allocator.create(World);
    defer allocator.destroy(world);
    world.initInto();
    for (&world.shards, &world.journals, 0..) |*shard, *journal, index| {
        shard.* = .{};
        journal.* = trading.journal.Journal.init();
        for (@import("asset_registry.zig").testDefinitions(6, 8)) |definition|
            _ = try applyCoreStable(shard, journal, .{ .identity = definition.asset, .payload = .{ .asset_definition_activated = definition } });
        const events = genesisEvents(index);
        for (events) |event| _ = try applyCoreStable(shard, journal, event);
        const host_digest = shard.canonicalStateDigest();
        _ = try applyCoreStable(shard, journal, .{ .identity = 3, .payload = .{ .host_activated = .{
            .strategy_identity = index + 1,
            .config_version = 1,
            .activation_identity = index + 1,
            .session = .{ .fencing = 1, .shard = @intCast(index), .generation = 1 },
            .activation_barrier = 0,
            .state_digest = host_digest,
        } } });
        // The shared offline feed starts at one and observes the same book in every shard.
        var snapshot = @import("trading_shard_fixture.zig").snapshotAt(11, 1);
        snapshot.venue.envelope.identity.stream = 9;
        snapshot.venue.envelope.source_stream = 9;
        snapshot.venue.envelope.raw_evidence.stream = 9;
        snapshot.venue.envelope.scope = .instrument;
        snapshot.venue.envelope.instrument = swap_instrument;
        snapshot.venue.envelope.exchange_account = exchange_account;
        _ = try trading.applyStable(shard, journal, snapshot);
        try std.testing.expect(shard.genesisReady());
        try std.testing.expect(shard.operational_state.effectiveTradingAuthority());
    }

    for (0..max_shards) |index| {
        try world.apply(index, .{ .identity = 5, .payload = .{ .mark_price = .{ .instrument = swap_instrument, .price_atoms = mark_price_atoms } } });
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 10, .count = 1 };
        group.members[0] = .{
            .intent_sequence = 10,
            .operation = .place,
            .instrument = swap_instrument,
            .side = if (index == max_shards - 1) .sell else .buy,
            .quantity = order_quantity,
            .limit_price = .{ .instrument = swap_instrument, .rules_version = 1, .ticks = order_price_ticks },
            .reservation = .{ .asset = settlement_asset, .atoms = 11_400_000 },
        };
        const placed = try applyCoreStable(&world.shards[index], &world.journals[index], .{
            .identity = 6,
            .payload = .{ .oms_intent_group = group },
        });
        try std.testing.expect(placed == null);
        const emitted = world.shards[index].oms.emitted();
        try std.testing.expectEqual(@as(usize, 1), emitted.len);
        world.commands[index] = emitted[0];
    }

    for (0..max_shards) |index| {
        const receipt = try world.ownership.record(.{
            .exchange_account = exchange_account,
            .shard_id = @enumFromInt(index),
            .fencing_token = @intCast(index + 1),
            .command = world.commands[index],
        });
        try std.testing.expectEqual(@as(ShardId, @enumFromInt(index)), receipt.shard_id);
    }
    try std.testing.expectError(error.DuplicateCommandIdentity, world.ownership.record(.{
        .exchange_account = exchange_account,
        .shard_id = .shard_0,
        .fencing_token = 1,
        .command = world.commands[0],
    }));
    try std.testing.expectError(error.CrossAccountGatewayRequest, world.ownership.record(.{
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
        _ = try world.ownership.complete(outcome);
        try world.ownership.applyOutcomeStable(outcome, @enumFromInt(index), &world.shards[index], &world.journals[index]);
        try std.testing.expectError(error.CrossShardDelivery, world.ownership.applyOutcomeStable(
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
    const unknown_outcome = try world.ownership.complete(.{
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
    try std.testing.expectError(error.GatewayOutcomeIdentityConflict, world.ownership.complete(conflicting));
    conflicting.state = .not_sent;
    try std.testing.expectError(error.GatewayOutcomeIdentityConflict, world.ownership.outcomeEvent(conflicting));

    for (0..max_shards) |index| {
        try world.apply(index, .{ .identity = @intCast(30 + index), .payload = .{ .economic_fill = .{
            .fill_id = @intCast(40 + index),
            .order_id = world.commands[index].order_id,
            .quantity = 40,
            .price_ticks = fill_price_ticks,
            .fee_atoms = place_fee_atoms,
        } } });
    }
    try world.apply(0, .{ .identity = 35, .payload = .{ .economic_fill = .{
        .fill_id = 45,
        .order_id = world.commands[0].order_id,
        .quantity = 60,
        .price_ticks = fill_price_ticks,
        .fee_atoms = place_fee_atoms,
    } } });
    try assertLedgersClosed(world);
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
    var limit_total: i128 = 0;
    var used_total: i128 = 0;
    for (leases) |lease| {
        limit_total = try std.math.add(i128, limit_total, lease.limit_atoms);
        used_total = try std.math.add(i128, used_total, lease.used_atoms);
        try std.testing.expect(lease.open);
        try std.testing.expect(lease.used_atoms <= lease.limit_atoms);
    }
    try std.testing.expectEqual(used_total, gross);
    try std.testing.expect(gross <= ceiling_atoms);
    try std.testing.expect(limit_total <= ceiling_atoms);

    const snapshot_fact: coordination.AccountFact = .{
        .identity = world.nextId(),
        .exchange_account = exchange_account,
        .version = 1,
        .barrier = 1,
        .payload = .{ .account_snapshot = .{
            .cash_atoms = initial_cash - place_fee_atoms,
            .spot_asset_atoms = 0,
            .swap_quantity = 0,
            .margin_atoms = 0,
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
    try std.testing.expect(world.coordinator.account_netting_benefit_atoms > 0);
    for (world.coordinator.leases[0..world.coordinator.lease_count]) |lease|
        try std.testing.expect(lease.used_atoms <= lease.limit_atoms);

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
            .price_ticks = fill_price_ticks,
            .fee_atoms = 1,
        } },
    });
    var forced_allocation: coordination.ForcedExecutionAllocation = .{
        .identity = world.nextId(),
        .forced_execution_identity = world.coordinator.forced_execution_source.?.identity,
        .count = 1,
    };
    forced_allocation.slices[0] = .{ .owner = .shard_1, .quantity = -2, .position_delta = -2, .fee_atoms = 1 };
    try world.allocateForced(forced_allocation);
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
            .price_ticks = fill_price_ticks,
            .fee_atoms = 1,
        } },
    });
    try std.testing.expect(world.coordinator.suspense_forced_execution != null);
    try std.testing.expect(world.coordinator.margin_gate.latched);
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
        try std.testing.expectEqual(lease.used_atoms, lease.limit_atoms);
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
        .instrument = swap_instrument,
        .side = .sell,
        .portfolio_reduce_only = true,
        .quantity = 38,
        .limit_price = .{ .instrument = swap_instrument, .rules_version = 1, .ticks = fill_price_ticks },
        .reservation = .{ .asset = settlement_asset, .atoms = 200_000 },
    };
    _ = try applyCoreStable(&world.shards[1], &world.journals[1], .{ .identity = 43, .payload = .{ .oms_intent_group = reduce_group } });
    const reducing = world.shards[1].oms.emitted();
    try std.testing.expectEqual(@as(usize, 1), reducing.len);
    try std.testing.expectEqual(trading.oms.Operation.place, reducing[0].operation);

    for (0..max_shards) |index| try world.publishDerivedSummary(index);

    for (&world.journals) |*journal| try journal.seal();
    var live_barriers: [max_shards]u64 = undefined;
    var shard_snapshots: [max_shards][]const u8 = undefined;
    var shard_tails: [max_shards][]const u8 = undefined;
    for (0..max_shards) |index| {
        live_barriers[index] = world.shards[index].authoritativeBarrier();
        shard_snapshots[index] = try world.shards[index].snapshot(&world.journals[index], live_barriers[index], &shard_snapshot_storage[index]);
        tail_journals[index] = trading.journal.Journal.initAt(live_barriers[index] + 1);
    }
    const coordinator_snapshot = try world.coordinator.snapshot(&coordinator_snapshot_storage);

    // The recovery point is the five sealed snapshots. Both tails advance only after it.
    const canonical_envelope: trading.canonical.EventEnvelope = .{
        .event_type = @intFromEnum(trading.canonical.EventType.instrument_definition_observed),
        .schema_version = trading.canonical.schema_version,
        .identity = .{ .stream = 2, .sequence = 500 },
        .source_fact_identity = 500,
        .scope = .instrument,
        .venue = 1,
        .exchange_account = exchange_account,
        .source_stream = 2,
        .source_sequence = 500,
        .adapter_session = 1,
        .times = .{ .monotonic_ns = 500 },
        .raw_evidence = .{ .stream = 2, .sequence = 500, .digest = @splat(0) },
    };
    const instrument_definition: trading.canonical.EventRecord = .{
        .envelope = canonical_envelope,
        .event = .{ .instrument_definition_observed = .{ .instrument = 3, .rules_version = 1 } },
    };
    _ = try trading.applyStable(&world.shards[1], &tail_journals[1], .{ .venue = instrument_definition });
    var snapshot_envelope = canonical_envelope;
    snapshot_envelope.event_type = @intFromEnum(trading.canonical.EventType.l2_book_snapshot);
    snapshot_envelope.identity = .{ .stream = 9, .sequence = 2 };
    snapshot_envelope.source_fact_identity = 2;
    snapshot_envelope.source_stream = 9;
    snapshot_envelope.source_sequence = 2;
    snapshot_envelope.raw_evidence = .{ .stream = 9, .sequence = 2, .digest = @splat(0) };
    const book_snapshot: trading.canonical.EventRecord = .{
        .envelope = snapshot_envelope,
        .event = .{ .l2_book_snapshot = .{
            .instrument = 3,
            .sequence = 2,
            .best_bid = .{ .instrument = 3, .rules_version = 1, .ticks = mark_price_atoms - 100_000_000 },
            .best_ask = .{ .instrument = 3, .rules_version = 1, .ticks = mark_price_atoms + 100_000_000 },
            .best_bid_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 1_000 },
            .best_ask_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 1_000 },
            .next_ask = .{ .instrument = 3, .rules_version = 1, .ticks = mark_price_atoms + 200_000_000 },
            .next_ask_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 1_000 },
        } },
    };
    _ = try trading.applyStable(&world.shards[1], &tail_journals[1], .{ .venue = book_snapshot });
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

    const replayed_shards = try allocator.create([max_shards]trading.TradingShard);
    defer allocator.destroy(replayed_shards);
    const replay_initial = try allocator.create(trading.TradingShard);
    defer allocator.destroy(replay_initial);
    for (0..max_shards) |index| {
        replay_initial.* = .{};
        try replayShardFromJournalInto(&replayed_shards[index], replay_initial, world.journals[index].bytes());
        @memcpy(std.mem.asBytes(replay_initial), std.mem.asBytes(&replayed_shards[index]));
        try replayShardFromJournalInto(&replayed_shards[index], replay_initial, shard_tails[index]);
    }
    for (0..max_shards) |index|
        try std.testing.expectEqualSlices(
            u8,
            &world.shards[index].canonicalStateDigest(),
            &replayed_shards[index].canonicalStateDigest(),
        );
    const replayed_coordinator = try replayCoordination(world);
    try std.testing.expectEqualSlices(u8, &world.coordinator.digest(), &replayed_coordinator.digest());
    try std.testing.expectEqual(world.coordinator.barrier, replayed_coordinator.barrier);

    const path_b = try allocator.create(coordination.AccountRecovery);
    defer allocator.destroy(path_b);
    try coordination.AccountRecovery.beginWithCoordinatorTailInto(path_b, coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, shard_tails);
    try std.testing.expect(path_b.coordinator.recovery_only);
    try std.testing.expectEqualSlices(u8, &world.coordinator.digest(), &path_b.coordinator.digest());
    try std.testing.expectEqual(world.coordinator.barrier, path_b.coordinator.barrier);
    try std.testing.expectError(error.CoordinatorRecoveryOnly, path_b.coordinator.allocateLeases(99, path_b.coordinator.barrier + 1));
    for (0..max_shards) |index| {
        try std.testing.expectEqual(trading.operational.OperationalMode.recovering, path_b.shards[index].operational_state.mode);
        try std.testing.expect(!path_b.shards[index].operational_state.effectiveTradingAuthority());
        try std.testing.expectEqual(world.shards[index].oms.order_count, path_b.shards[index].oms.order_count);
    }
    try std.testing.expectError(error.ForcedExecutionReconciliationBreak, path_b.completeCoordinatorRecovery());
    var recovery_observation = try world.projectedObservation(9001);
    recovery_observation.barrier = path_b.coordinator.barrier;
    const latched_recovery = try path_b.coordinator.reconcileMargin(recovery_observation);
    try std.testing.expect(latched_recovery.latched);
    try std.testing.expectError(error.ForcedExecutionReconciliationBreak, path_b.completeCoordinatorRecovery());

    const path_success = try allocator.create(coordination.AccountRecovery);
    defer allocator.destroy(path_success);
    try coordination.AccountRecovery.beginWithCoordinatorTailInto(path_success, coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, shard_tails);
    _ = try path_success.coordinator.reconcileMargin(recovery_observation);
    try std.testing.expectError(error.ForcedExecutionReconciliationBreak, path_success.coordinator.resolveMarginGate(recovery_observation.identity));
    try std.testing.expectError(error.ForcedExecutionReconciliationBreak, path_success.completeCoordinatorRecovery());
    try std.testing.expect(path_success.coordinator.recovery_only);
    try std.testing.expectEqual(try world.coordinator.grossPortfolioMargin(), try path_success.coordinator.grossPortfolioMargin());
    try std.testing.expectEqual(
        @max((try path_success.coordinator.grossPortfolioMargin()) - recovery_observation.venue_net_margin_atoms, 0),
        path_success.coordinator.account_netting_benefit_atoms,
    );
    for (0..max_shards) |index| {
        try std.testing.expectEqual(world.shards[index].oms.order_count, path_success.shards[index].oms.order_count);
        try std.testing.expectEqual(@as(usize, 0), path_success.shards[index].oms.emitted().len);
    }

    const path_c = try allocator.create(coordination.AccountRecovery);
    defer allocator.destroy(path_c);
    try coordination.AccountRecovery.beginWithCoordinatorTailInto(path_c, coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, shard_tails);
    try std.testing.expectEqualSlices(u8, &world.coordinator.digest(), &path_c.coordinator.digest());
    const mid_crash_observation = recovery_observation;
    _ = try path_c.coordinator.reconcileMargin(mid_crash_observation);
    try coordination.AccountRecovery.beginWithCoordinatorTailInto(path_c, coordinator_snapshot, coordinator_tail.bytes(), shard_snapshots, shard_tails);
    try std.testing.expectEqualSlices(u8, &world.coordinator.digest(), &path_c.coordinator.digest());
    try std.testing.expectError(error.ForcedExecutionReconciliationBreak, path_c.completeCoordinatorRecovery());
    _ = try path_c.coordinator.reconcileMargin(mid_crash_observation);
    try std.testing.expectError(error.ForcedExecutionReconciliationBreak, path_c.completeCoordinatorRecovery());
    try std.testing.expectEqualSlices(u8, &path_b.coordinator.digest(), &path_c.coordinator.digest());

    var evidence_coordinator = replayed_coordinator;
    _ = try evidence_coordinator.reconcileMargin(recovery_observation);

    for (replayed_shards) |*shard| fence(shard);
    const fenced_live = try allocator.create([max_shards]trading.TradingShard);
    defer allocator.destroy(fenced_live);
    @memcpy(std.mem.asBytes(fenced_live), std.mem.asBytes(&world.shards));
    for (fenced_live) |*shard| fence(shard);
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

    const shared_a = sharedSummary(evidence_coordinator.barrier, replayed_shards, &evidence_coordinator.digest());
    const shared_b = sharedSummary(path_b.coordinator.barrier, &path_b.shards, &path_b.coordinator.digest());
    const shared_c = sharedSummary(path_c.coordinator.barrier, &path_c.shards, &path_c.coordinator.digest());
    try std.testing.expectEqualSlices(u8, &shared_a, &shared_b);
    try std.testing.expectEqualSlices(u8, &shared_b, &shared_c);
    try std.testing.expectEqual(@as(u8, max_shards), world.ownership.count);
    const shared_hex = std.fmt.bytesToHex(shared_a, .lower);
    if (!std.mem.eql(u8, expected_shared_summary, &shared_hex)) {
        std.debug.print("four-shard evidence mismatch: expected {s}, actual {s}\n", .{ expected_shared_summary, &shared_hex });
        return error.FourShardEvidenceDrift;
    }

    var shard_digests: [max_shards][Sha256.digest_length]u8 = undefined;
    var shard_barriers: [max_shards]u64 = undefined;
    for (0..max_shards) |index| {
        shard_digests[index] = fenced_live[index].canonicalStateDigest();
        shard_barriers[index] = fenced_live[index].authoritativeBarrier();
    }
    return .{
        .schema_version = acceptance_schema_version,
        .journal_schema_version = production_contract.journal_schema_version,
        .state_schema_version = production_contract.state_schema_version,
        .coordinator_barrier = path_b.coordinator.barrier,
        .shard_barriers = shard_barriers,
        .shard_digests = shard_digests,
        .coordinator_digest = evidence_coordinator.digest(),
        .shared_summary = shared_a,
        .owned_command_count = world.ownership.count,
        .replay_send_capability = replay_send_capability,
    };
}

test "four-shard acceptance entry stops at the first broken assertion" {
    _ = try runFourShardAcceptance();
}
