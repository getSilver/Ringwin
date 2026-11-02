const std = @import("std");
const canonical = @import("../../../model/canonical_event.zig");
const codec = @import("../../../persistence/canonical_event_codec.zig");

test "03 forced canonical source preserves unknown economic evidence" {
    const forced: canonical.ForcedExecution = .{
        .identity = 700,
        .exchange_account = 2,
        .instrument = 5,
        .rules_version = 1,
        .kind = .partial_liquidation,
        .venue_execution = try canonical.VenueTradeRef.init(1, "-7"),
        .quantity = .{ .instrument = 5, .rules_version = 1, .lots = 3 },
        .side = .sell,
        .price = .{ .instrument = 5, .rules_version = 1, .ticks = 10 },
        .execution_time_utc_ns = 100,
    };
    const record: canonical.EventRecord = .{ .envelope = .{ .event_type = 25, .schema_version = canonical.schema_version, .identity = .{ .stream = 1, .sequence = 1 }, .source_fact_identity = 700, .scope = .account, .venue = 1, .exchange_account = 2, .instrument = 5, .source_stream = 1, .source_sequence = 1, .times = .{}, .raw_evidence = .{ .stream = 1, .sequence = 1, .digest = @splat(0) } }, .event = .{ .forced_execution = forced } };
    var bytes: [8192]u8 = undefined;
    try std.testing.expectEqualDeep(record, try codec.decode(try codec.encode(&bytes, record)));
    try std.testing.expect(forced.fee == null and forced.penalty == null and forced.realized_pnl == null);
}
const coordination = @import("../../../portfolio/account_coordinator.zig");
const durable = @import("../../../persistence/durable_store.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const setup = @import("shared_venue_delivery_acceptance.zig");

test "03 incomplete forced source is durable account Suspense without ledger mutation" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const owners = try std.testing.allocator.alloc(demo.Owner, 4);
    defer std.testing.allocator.free(owners);
    var coordinator = try coordination.CoordinatorOwner.init(.init(2, 100, 100), .{ .domain = .control, .id = 9399 }, memory.interface(), undefined);
    var before: [4][32]u8 = undefined;
    for (owners, 0..) |*owner, index| {
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 9101 + index });
        try setup.initialize(owner, index);
        try coordinator.apply(.{ .publish_summary = .{ .identity = index + 1, .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 1, index + 1) } });
        before[index] = owner.shard.canonicalStateDigest();
    }
    try coordinator.checkpoint();
    const forced: canonical.ForcedExecution = .{
        .identity = 700,
        .exchange_account = 2,
        .instrument = 5,
        .rules_version = 1,
        .kind = .adl,
        .venue_execution = try canonical.VenueTradeRef.init(1, "-7"),
        .quantity = .{ .instrument = 5, .rules_version = 1, .lots = 3 },
        .side = .sell,
        .price = .{ .instrument = 5, .rules_version = 1, .ticks = 10 },
        .execution_time_utc_ns = 100,
    };
    var record = @import("../../support/trading_shard_fixture.zig").canonicalAt(47, 1, .{ .forced_execution = forced }).venue;
    record.envelope.instrument = 5;
    record.envelope.source_fact_identity = forced.identity;
    var foreign_source = record;
    foreign_source.event.forced_execution.venue_execution.venue = 2;
    try std.testing.expectError(error.InvalidEconomicFact, coordinator.acceptVenueFactFromOwners(foreign_source, .{ &owners[0], &owners[1], &owners[2], &owners[3] }));
    try coordinator.acceptVenueFactFromOwners(record, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    try std.testing.expect(coordinator.coordinator.forced_execution_source == null);
    try std.testing.expect(coordinator.coordinator.margin_gate.latched);
    var suspense: [1]canonical.EventRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), (try coordinator.venueSuspense(&suspense)).len);
    try std.testing.expectEqualDeep(record, suspense[0]);
    for (owners, 0..) |*owner, index| try std.testing.expectEqualDeep(before[index], owner.shard.canonicalStateDigest());
    try coordinator.checkpoint();
    var recovered = try coordination.CoordinatorOwner.recover(coordinator.stream, memory.interface(), undefined);
    try std.testing.expectEqual(@as(usize, 1), (try recovered.venueSuspense(&suspense)).len);
    try std.testing.expectEqualDeep(record, suspense[0]);
    var later = record;
    later.envelope.identity.sequence = 2;
    later.envelope.source_sequence = 2;
    later.envelope.source_fact_identity = 701;
    later.event.forced_execution.identity = 701;
    later.event.forced_execution.fee = .{ .asset = 1, .atoms = 0 };
    later.event.forced_execution.penalty = .{ .asset = 1, .atoms = 0 };
    later.event.forced_execution.realized_pnl = .{ .asset = 1, .atoms = 0 };
    try std.testing.expectError(error.ForcedContributionBarrierPending, recovered.acceptForcedVenueFact(later, .{ &owners[0], &owners[1], &owners[2], &owners[3] }));
    try std.testing.expect(recovered.coordinator.forced_execution_source == null);
}
const gateway_fixture = @import("shared_gateway_venue_acceptance.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const simulated = @import("../../../adapters/simulated/simulated_venue.zig");

test "03 complete forced source closes only its instrument through typed allocation and durable acknowledgement" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const owners = try allocator.alloc(demo.Owner, 4);
    defer allocator.free(owners);
    var bootstrap: canonical.AccountBootstrapSnapshot = .{ .identity = 90, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 999, .source_sequence = 0, .balance_count = 1, .position_count = 0, .margin_count = 8 };
    const zero: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
    const cash: canonical.AssetAmount = .{ .asset = 1, .atoms = 100 };
    bootstrap.balances[0] = .{ .asset = 1, .total = cash, .available = cash, .held = zero, .cash_balance = cash, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
    for (bootstrap.margins[0..8], 1..) |*margin, instrument| margin.* = .{ .instrument = instrument, .amount = zero, .initial_margin = zero, .maintenance_margin = zero, .isolated_equity = zero };
    var baseline = fixture.canonicalAt(39, 1, .{ .account_bootstrap_snapshot = bootstrap });
    baseline.venue.envelope.identity.stream = 999;
    baseline.venue.envelope.source_stream = 999;
    for (owners, 0..) |*owner, index| {
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = index + 9101 });
        try setup.initialize(owner, index);
        _ = try owner.apply(baseline);
        if (index == 0) try gateway_fixture.admit(owner, index);
    }
    const gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 9490 });
    try gateway.pinDeploymentDigest(owners[0].shard.deployment.header.?.expected_digest);
    const when = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core;
    var simulator: simulated.SimulatedVenue = .{ .receipt_times = .{ .source_utc_ns = when.source_time, .receive_utc_ns = when.receive_time, .monotonic_ns = when.monotonic_time, .audit_utc_ns = when.wall_time } };
    var adapter = simulator.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owners[0].shard.asset_registry, .instrument_definitions = owners[0].shard.instrument_registry });
    try gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .supported_products = execution.productMask(.isolated_linear), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    var coordinator = try coordination.CoordinatorOwner.init(.init(2, 100, 100), .{ .domain = .control, .id = 9491 }, memory.interface(), undefined);
    for (owners, 0..) |*owner, index| try coordinator.apply(.{ .publish_summary = .{ .identity = index + 1, .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 1, index + 1) } });
    try coordinator.checkpoint();
    for ([_]u64{ 1, 2 }) |command_id| {
        const command = owners[0].shard.oms.findCommand(command_id).?;
        try coordinator.recordGateway(.{ .exchange_account = 2, .shard_id = .shard_0, .fencing_token = 1, .command = command });
        const now = try gateway_fixture.observe(gateway, &owners[0], command_id);
        try std.testing.expectEqual(.accepted, try gateway.sendFromShard(&owners[0].shard, command_id, now));
        const batch = (try adapter.tryDrain()).?;
        for (batch.slice()) |source| {
            try coordinator.acceptVenueFactFromGateway(source, gateway, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
            try std.testing.expect(try coordinator.deliverVenueFact(.shard_0, &owners[0]));
        }
    }
    const other_instrument = owners[0].shard.economic_projection.portfolio.instrumentPosition(1).?;
    const original_quantity = owners[0].shard.economic_projection.portfolio.instrumentPosition(5).?.position.quantity;
    try std.testing.expect(original_quantity > 0);
    try owners[0].bindAccountCoordinator(&coordinator);
    const forced: canonical.ForcedExecution = .{ .identity = 700, .exchange_account = 2, .instrument = 5, .rules_version = 1, .kind = .liquidation, .venue_execution = try canonical.VenueTradeRef.init(1, "-7"), .quantity = .{ .instrument = 5, .rules_version = 1, .lots = original_quantity }, .side = .sell, .price = .{ .instrument = 5, .rules_version = 1, .ticks = 10 }, .execution_time_utc_ns = fixture.atGroup(47, .{ .identity = 0, .payload = .recovery_completed }).core.source_time, .fee = .{ .asset = 1, .atoms = 1 }, .penalty = .{ .asset = 1, .atoms = 2 }, .realized_pnl = .{ .asset = 1, .atoms = 0 } };
    var record = fixture.canonicalAt(47, simulator.next_event_identity, .{ .forced_execution = forced }).venue;
    record.envelope.instrument = 5;
    record.envelope.source_fact_identity = forced.identity;
    try coordinator.acceptForcedVenueFact(record, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    try std.testing.expectEqual(original_quantity, coordinator.coordinator.forced_source_positions[0]);
    try std.testing.expectEqual(@as(i64, 0), coordinator.coordinator.forced_source_positions[1]);
    const later = fixture.canonicalAt(48, record.envelope.identity.sequence + 1, .{ .account_reconciliation_started = 801 }).venue;
    try coordinator.acceptVenueFact(later);
    try std.testing.expect((try coordinator.pendingVenueFact(.shard_0)) == null);
    var allocation: coordination.ForcedExecutionAllocation = .{ .identity = 701, .forced_execution_identity = 700, .count = 1 };
    allocation.slices[0] = .{ .owner = .shard_0, .quantity = -original_quantity, .position_delta = -original_quantity, .realized_pnl_atoms = 0, .fee_atoms = 1, .penalty_atoms = 2 };
    try coordinator.allocateForcedExecution(allocation);
    const delivery = (try coordinator.coordinator.pendingForcedDeliveries())[0];
    _ = try owners[0].apply(.{ .core = try coordination.accountFactEvent(delivery) });
    const applied_economics = owners[0].shard.economicSummary();
    try owners[0].checkpoint();
    const after = owners[0].shard.canonicalStateDigest();
    try demo.Owner.recoverInto(&owners[0], memory.interface(), undefined, owners[0].stream);
    try std.testing.expectEqualDeep(after, owners[0].shard.canonicalStateDigest());
    try std.testing.expectEqualDeep(applied_economics, owners[0].shard.economicSummary());
    try coordinator.checkpoint();
    var recovered = try coordination.CoordinatorOwner.recover(coordinator.stream, memory.interface(), undefined);
    _ = try owners[0].apply(.{ .core = try coordination.accountFactEvent((try recovered.coordinator.pendingForcedDeliveries())[0]) });
    try std.testing.expectEqualDeep(after, owners[0].shard.canonicalStateDigest());
    try recovered.ackForcedDelivery(delivery, &owners[0]);
    try std.testing.expectEqual(@as(usize, 0), (try recovered.coordinator.pendingForcedDeliveries()).len);
    try std.testing.expectEqual(@as(i64, 0), owners[0].shard.economic_projection.portfolio.instrumentPosition(5).?.position.quantity);
    try std.testing.expectEqualDeep(other_instrument, owners[0].shard.economic_projection.portfolio.instrumentPosition(1).?);
    try std.testing.expectEqual(@as(i128, 22), owners[0].shard.economic_projection.portfolio.settlement_balance_atoms);
    for (owners[1..]) |*owner| try std.testing.expectEqual(@as(i128, 25), owner.shard.economic_projection.portfolio.settlement_balance_atoms);
    _ = try recovered.archiveForcedSource();
    try recovered.acceptAccountFact(.{ .identity = 702, .exchange_account = 2, .version = 1, .barrier = 2, .payload = .{ .account_snapshot = .{ .cash_atoms = 100, .swap_quantity = 0, .margin_atoms = 0 } } });
    const closed = recovered.coordinator.digest();
    try recovered.acceptForcedVenueFact(record, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    try std.testing.expectEqualDeep(closed, recovered.coordinator.digest());
    try std.testing.expectEqualDeep(after, owners[0].shard.canonicalStateDigest());
    try std.testing.expectEqualDeep(later, (try recovered.pendingVenueFact(.shard_0)).?);
    try proveForcedGateRecovery(&recovered, owners, record.envelope.identity.sequence + 2);
}

fn broadcastRecovery(coordinator: *coordination.CoordinatorOwner, owners: []demo.Owner, sequence: u64, payload: canonical.Payload) !void {
    var record = fixture.canonicalAt(60, sequence, payload).venue;
    record.envelope.scope = .account;
    record.envelope.instrument = null;
    record.envelope.asset = null;
    try coordinator.acceptVenueFact(record);
    for (owners, 0..) |*owner, index| try std.testing.expect(try coordinator.deliverVenueFact(@enumFromInt(index), owner));
}

fn proveForcedGateRecovery(coordinator: *coordination.CoordinatorOwner, owners: []demo.Owner, first_sequence: u64) !void {
    // The archived forced source alone cannot reopen the ingress gate.
    try std.testing.expectError(error.AccountDeliveryPending, coordinator.resolveVenueGate(9000));
    for (owners, 0..) |*owner, index| try std.testing.expect(try coordinator.deliverVenueFact(@enumFromInt(index), owner));
    try std.testing.expectError(error.FreshAccountResolutionRequired, coordinator.resolveVenueGate(9000));
    for (owners, 0..) |*owner, index| {
        for ([_]u128{ index + 1, index + 5 }) |instrument| {
            var margin = owner.shard.instrument_registry.get(instrument).?.margin;
            margin.version = 3;
            margin.instrument = instrument;
            margin.native_settlement_atoms = true;
            margin.native = .{ .model = .isolated_linear_v1, .tier_identity = 1, .notional_lower_atoms = 0, .notional_upper_atoms = 100000, .initial_margin_ppm = 20000, .maintenance_ppm = 11000, .maintenance_deduction_atoms = 0, .close_fee_ppm = 0, .margin_rounding_atoms = 1, .price_rounding_ticks = 1 };
            _ = try owner.apply(fixture.atGroup(59, .{ .identity = @intCast(6000 + instrument), .account_scope = 2, .payload = .{ .margin_rules_activated = margin } }));
            try coordinator.apply(.{ .native_margin_configuration = owner.shard.instrument_registry.get(instrument).? });
        }
        try coordinator.apply(.{ .publish_summary = .{ .identity = index + 9000, .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 2, index + 1) } });
    }
    var snapshot: canonical.AccountBootstrapSnapshot = .{ .identity = 9000, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 1, .source_sequence = first_sequence, .balance_count = 1, .position_count = 1, .margin_count = 8 };
    const zero: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
    const cash: canonical.AssetAmount = .{ .asset = 1, .atoms = 97 };
    snapshot.balances[0] = .{ .asset = 1, .total = cash, .available = cash, .held = zero, .cash_balance = cash, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
    snapshot.positions[0] = .{ .instrument = 1, .side = .long, .quantity = .{ .instrument = 1, .rules_version = 1, .lots = 10000 }, .average_price = .{ .instrument = 1, .rules_version = 1, .ticks = 10 }, .mark_price = .{ .instrument = 1, .rules_version = 1, .ticks = 10 }, .liquidation_price = .{ .instrument = 1, .rules_version = 1, .ticks = 8 }, .leverage = .{ .coefficient = 50, .scale = 0 }, .unrealized_pnl = zero, .risk_tier = 1 };
    for (snapshot.margins[0..8], 1..) |*margin, instrument| margin.* = .{ .instrument = instrument, .amount = if (instrument == 1) .{ .asset = 1, .atoms = 2 } else zero, .initial_margin = if (instrument == 1) .{ .asset = 1, .atoms = 1 } else zero, .maintenance_margin = if (instrument == 1) .{ .asset = 1, .atoms = 1 } else zero, .isolated_equity = if (instrument == 1) .{ .asset = 1, .atoms = 2 } else zero };
    try broadcastRecovery(coordinator, owners, first_sequence, .{ .account_bootstrap_snapshot = snapshot });
    try broadcastRecovery(coordinator, owners, first_sequence + 1, .{ .venue_account_configuration_snapshot = .{ .identity = 9001, .exchange_account = 2, .value = .{ .account = .{ .position_mode_net = true, .contract_isolated_autonomy = true, .auto_loan = false, .spot_borrow_enabled = false, .can_read = true, .can_trade = true, .can_withdraw = false } } } });
    for (1..9) |instrument| try broadcastRecovery(coordinator, owners, first_sequence + instrument + 1, .{ .venue_account_configuration_snapshot = .{ .identity = 9001 + instrument, .exchange_account = 2, .value = .{ .isolated_leverage = .{ .instrument = instrument, .position_mode_net = true, .margin_mode_isolated = true, .leverage = .{ .coefficient = 50, .scale = 0 } } } } });
    try coordinator.apply(.{ .margin_observation = .{ .identity = 9000, .barrier = coordinator.coordinator.barrier, .venue_net_margin_atoms = 1, .venue_swap_quantity = 10000, .margin_mode = .isolated, .rules_version = 1 } });
    try std.testing.expectEqual(coordination.MarginReconciliationState.healthy, coordinator.coordinator.margin_reconciliation_state);
    const economic = owners[0].shard.economicSummary();
    try std.testing.expectError(error.FreshAccountResolutionRequired, coordinator.resolveVenueGate(8999));
    const store = coordinator.store;
    var unavailable = store.vtable.*;
    unavailable.query_order_history = unavailableClosure;
    coordinator.store = .{ .context = store.context, .vtable = &unavailable };
    try std.testing.expectError(error.ClosureHistoryUnavailable, coordinator.resolveVenueGate(9000));
    try std.testing.expect(coordinator.coordinator.venue_ingress.broken);
    coordinator.store = store;
    try coordinator.resolveVenueGate(9000);
    try std.testing.expect(!coordinator.coordinator.venue_ingress.broken);
    try std.testing.expect(coordinator.coordinator.margin_gate.latched);
    try coordinator.apply(.{ .resolve_margin_gate = 9000 });
    try std.testing.expect(coordinator.coordinator.margin_gate.open);
    try std.testing.expect(!owners[0].shard.operational_state.trading_authorized);
    try std.testing.expectEqualDeep(economic, owners[0].shard.economicSummary());
    const digest = coordinator.coordinator.digest();
    try coordinator.checkpoint();
    const recovered = try coordination.CoordinatorOwner.recover(coordinator.stream, coordinator.store, coordinator.io);
    try std.testing.expectEqualDeep(digest, recovered.coordinator.digest());
    try std.testing.expect(!recovered.coordinator.venue_ingress.broken);
}

fn unavailableClosure(_: *anyopaque, _: std.Io, _: @import("../../../persistence/business_history.zig").LookupRequest) anyerror!@import("../../../persistence/business_history.zig").LookupResult {
    return error.ClosureHistoryUnavailable;
}
