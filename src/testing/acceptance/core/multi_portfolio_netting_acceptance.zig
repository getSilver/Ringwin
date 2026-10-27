//! Direction offset through two complete groups and one shared execution adapter.
const std = @import("std");
const canonical = @import("../../../model/canonical_event.zig");
const trading = @import("../../../trading/trading_shard.zig");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const host = @import("../../../strategy/strategy_host_gateway.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const simulated = @import("../../../adapters/simulated/simulated_venue.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const setup = @import("shared_venue_delivery_acceptance.zig");
const gateway_fixture = @import("shared_gateway_venue_acceptance.zig");

test "04 account summary includes funded portfolios without duplicating account cash" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try @import("multi_portfolio_authority_acceptance.zig").initializeEconomicsOwner(owner);
    const summary = try coordination.shardSummaryFromShardForAccount(&owner.shard, 20, .shard_0, 1, 1);
    try std.testing.expectEqual(@as(i128, 600), summary.cash_atoms);
    try std.testing.expectEqual(@as(i128, 0), summary.reservation_atoms);
    try std.testing.expectEqual(@as(i128, 1_000), owner.shard.accountState(20).?.economic_projection.exchange.usdt_balance_atoms);
}

fn apply(owner: *demo.Owner, account: ?u128, payload: trading.CorePayload) !void {
    _ = try owner.apply(fixture.atGroup(45, .{ .identity = owner.shard.authoritativeBarrier() + 10_000, .account_scope = account, .payload = payload }));
}

noinline fn placeGroups(owner: *demo.Owner, comptime forced_case: bool) !void {
    try gateway_fixture.prepareTrading(owner, 0, 1);
    for ([_]u128{ 1, 5 }) |instrument| {
        const entry = owner.shard.registryInstrument(instrument) orelse return error.TestMissingInstrument;
        var margin = entry.margin;
        margin.version = 3;
        margin.venue_initial_margin_ppm = 100_000;
        margin.internal_initial_margin_ppm = 100_000;
        margin.internal_maintenance_margin_ppm = 50_000;
        margin.fee_ppm = 0;
        margin.native_settlement_atoms = true;
        margin.native = .{ .model = .isolated_linear_usdt_v1, .tier_identity = 1, .notional_lower_atoms = 0, .notional_upper_atoms = 100_000, .initial_margin_ppm = 100_000, .maintenance_ppm = 50_000, .maintenance_deduction_atoms = 0, .close_fee_ppm = 0, .margin_rounding_atoms = 1, .price_rounding_ticks = 1 };
        try apply(owner, 2, .{ .margin_rules_activated = margin });
    }
    try apply(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 15, .strategy_identity = 5, .config_version = 2, .activation_identity = 1 } });
    const session: @import("../../../strategy/strategy_host_ipc.zig").Session = .{ .fencing = 1, .shard = 1, .generation = 1 };
    var configs: [2]host.Config = undefined;
    var gateways: [2]host.Gateway = undefined;
    for ([_]u128{ 1, 5 }, 0..) |strategy, index| {
        const strategy_config_version: u64 = if (index == 0) 1 else 2;
        for ([_]u128{ 1, 5 }) |instrument| try apply(owner, 2, .{ .instrument_trading_authorization = .{
            .strategy_identity = strategy,
            .exchange_account = 2,
            .instrument = instrument,
            .strategy_activation_identity = 1,
            .config_version = strategy_config_version,
            .expected_version = 1,
            .enabled = true,
        } });
        const barrier = owner.shard.authoritativeBarrier();
        configs[index] = .{ .schema_registry = trading.schema_registry_identity, .decision_domain = 1, .session = session, .authorization = .{ .strategy_identity = strategy, .config_version = strategy_config_version, .activation_identity = 1, .activation_barrier = barrier } };
        try apply(owner, null, .{ .host_activated = .{ .strategy_identity = strategy, .config_version = strategy_config_version, .activation_identity = 1, .session = session, .activation_barrier = barrier, .state_digest = owner.shard.canonicalStateDigest() } });
        gateways[index] = try host.Gateway.init(configs[index], &.{host.Subscription.of(strategy, &.{.timer})});
    }
    for (&gateways, configs, [_]u128{ 11, 15 }, 0..) |*gateway, config, portfolio, index| {
        try apply(owner, 2, .{ .mark_price = .{ .instrument = 1, .price_atoms = 10 } });
        const cursor = owner.shard.authoritativeBarrier();
        var batch: [256]u8 = undefined;
        _ = try gateway.encodeBatch(&batch, 1, cursor, cursor, 100, &.{.{ .event_type = .timer, .shard_sequence = cursor, .source_time_ns = 100, .receive_time_ns = 100, .monotonic_time_ns = 100, .wall_time_utc_ns = 100, .payload = &.{} }});
        try gateway.recordPublished(1, cursor, 100);
        try gateway.activate(&owner.shard, &owner.decision_journal);
        var orders: [2]host.OutputOrder = undefined;
        for ([_]u128{ 1, 5 }, 0..) |instrument, leg| orders[leg] = .{
            .portfolio_identity = portfolio,
            .exchange_account_identity = 2,
            .instrument_identity = instrument,
            .side = if ((index == 0 or forced_case) == (leg == 0)) .buy else .sell,
            .quantity = if (index == 0) 30_000 else if (forced_case and leg == 0) 20_000 else 10_000,
            .limit_price_micros = if (forced_case and index == 1) 12 else 10,
        };
        var frame_bytes: [host.max_group_frame_len]u8 = undefined;
        const frame = try host.encodeOutputGroupFrame(&frame_bytes, config, 1, cursor, 1, &orders);
        const decision = gateway.ingest(frame, 101);
        try std.testing.expect(decision == .accepted_group);
        try apply(owner, null, decision.corePayload());
        try std.testing.expectEqual(.none, owner.shard.last_reject_reason);
        try std.testing.expectEqual(@as(u16, @intCast(2 * (index + 1))), owner.shard.oms.order_count);
    }
}

fn broadcast(coordinator: *coordination.CoordinatorOwner, owners: []demo.Owner, payload: canonical.Payload) !canonical.EventRecord {
    const ingress = coordinator.coordinator.venue_ingress;
    const sequence = ingress.sequence + 1;
    var record = fixture.canonicalAt(60, sequence, payload).venue;
    record.envelope.identity.stream = ingress.stream;
    record.envelope.source_stream = ingress.source_stream;
    record.envelope.source_fact_identity = switch (payload) {
        .account_bootstrap_snapshot => |snapshot| snapshot.identity,
        .venue_account_configuration_snapshot => |configuration| configuration.identity,
        else => unreachable,
    };
    record.envelope.scope = .account;
    record.envelope.instrument = null;
    record.envelope.asset = null;
    try coordinator.acceptVenueFact(record);
    for (owners, 0..) |*owner, index| try std.testing.expect(try coordinator.deliverVenueFact(@enumFromInt(index), owner));
    return record;
}

noinline fn verifyNativeMargin(coordinator: *coordination.CoordinatorOwner, owners: []demo.Owner, comptime recovery_case: bool) !void {
    const lease = owners[0].shard.risk_lease_atoms;
    const remaining = try owners[0].shard.riskLeaseRemainingAtoms();
    const template = owners[0].shard.registryInstrument(1) orelse return error.TestMissingNativeInstrument;
    for (1..9) |instrument| {
        var entry = template;
        entry.instrument = instrument;
        entry.rules.instrument_identity = instrument;
        entry.margin.instrument = instrument;
        try coordinator.apply(.{ .native_margin_configuration = entry });
    }
    const zero: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
    const cash: canonical.AssetAmount = .{ .asset = 1, .atoms = 100 };
    var snapshot: canonical.AccountBootstrapSnapshot = .{
        .identity = 30_001,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = coordinator.coordinator.venue_ingress.source_stream,
        .source_sequence = 0,
        .balance_count = 1,
        .position_count = 2,
        .margin_count = 8,
    };
    snapshot.balances[0] = .{ .asset = 1, .total = cash, .available = .{ .asset = 1, .atoms = 96 }, .held = .{ .asset = 1, .atoms = 4 }, .cash_balance = cash, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
    for (snapshot.margins[0..8], 1..) |*margin, instrument| margin.* = .{ .instrument = instrument, .amount = zero, .initial_margin = zero, .maintenance_margin = zero, .isolated_equity = zero };
    for ([_]u128{ 1, 5 }, 0..) |instrument, index| {
        snapshot.positions[index] = .{
            .instrument = instrument,
            .side = .net,
            .quantity = .{ .instrument = instrument, .rules_version = 1, .lots = if (index == 0) 20_000 else -20_000 },
            .average_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 10 },
            .mark_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 10 },
            .liquidation_price = .{ .instrument = instrument, .rules_version = 1, .ticks = if (index == 0) 9 else 11 },
            .leverage = .{ .coefficient = 10, .scale = 0 },
            .unrealized_pnl = zero,
            .risk_tier = 1,
        };
        snapshot.margins[@intCast(instrument - 1)] = .{ .instrument = instrument, .amount = .{ .asset = 1, .atoms = 2 }, .initial_margin = .{ .asset = 1, .atoms = 2 }, .maintenance_margin = .{ .asset = 1, .atoms = 1 }, .isolated_equity = .{ .asset = 1, .atoms = 2 } };
    }
    const original = try broadcast(coordinator, owners, .{ .account_bootstrap_snapshot = snapshot });
    _ = try broadcast(coordinator, owners, .{ .venue_account_configuration_snapshot = .{ .identity = 30_002, .exchange_account = 2, .value = .{ .account = .{ .position_mode_net = true, .contract_isolated_autonomy = true, .auto_loan = false, .spot_borrow_enabled = false, .can_read = true, .can_trade = true, .can_withdraw = false } } } });
    for (1..9) |instrument| _ = try broadcast(coordinator, owners, .{ .venue_account_configuration_snapshot = .{ .identity = 30_002 + instrument, .exchange_account = 2, .value = .{ .isolated_leverage = .{ .instrument = instrument, .position_mode_net = true, .margin_mode_isolated = true, .leverage = .{ .coefficient = 10, .scale = 0 } } } } });
    try coordinator.apply(.{ .margin_observation = .{ .identity = 30_100, .barrier = coordinator.coordinator.barrier + 1, .venue_net_margin_atoms = 0, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 } });
    try std.testing.expectEqual(coordination.MarginReconciliationState.healthy, coordinator.coordinator.margin_reconciliation_state);
    try std.testing.expectEqual(@as(i128, 8), try coordinator.coordinator.grossPortfolioMargin());
    try std.testing.expectEqual(@as(i128, 4), coordinator.coordinator.account_netting_benefit_atoms);
    try std.testing.expectEqual(lease, owners[0].shard.risk_lease_atoms);
    try std.testing.expectEqual(remaining, try owners[0].shard.riskLeaseRemainingAtoms());
    try std.testing.expectEqual(@as(i128, 17), remaining);
    try coordinator.acceptVenueFact(original);
    try std.testing.expectEqual(@as(i128, 4), coordinator.coordinator.account_netting_benefit_atoms);
    try std.testing.expectEqual(@as(i128, 0), try owners[0].shard.activeReservationAtoms());
    if (recovery_case) {
        try coordinator.apply(.{ .allocate_leases = .{ .version = 2, .valid_through_barrier = coordinator.coordinator.barrier + 1_000 } });
        var total: i128 = 0;
        for (coordinator.coordinator.leases) |grant| {
            const index = @intFromEnum(grant.shard_id);
            _ = try owners[index].apply(.{ .core = try coordination.riskLeaseEventForShard(grant, grant.shard_id, &owners[index].shard) });
            try std.testing.expectEqual(@as(i128, 25), owners[index].shard.risk_lease_atoms);
            total += grant.limit_atoms;
        }
        try std.testing.expectEqual(@as(i128, 100), total);
    }
    try coordinator.checkpoint();
    const restored = try coordination.CoordinatorOwner.recover(coordinator.stream, coordinator.store, undefined);
    try std.testing.expectEqualDeep(coordinator.coordinator.digest(), restored.coordinator.digest());
    for (owners) |*owner| {
        try owner.checkpoint();
        const recovered = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(recovered);
        try demo.Owner.recoverInto(recovered, owner.store, undefined, owner.stream);
        try std.testing.expectEqualDeep(owner.shard.canonicalStateDigest(), recovered.shard.canonicalStateDigest());
    }
    if (recovery_case) try proveNativeOwnerRecovery(coordinator, owners, original);
}

noinline fn proveNativeOwnerRecovery(coordinator: *coordination.CoordinatorOwner, owners: []demo.Owner, original: canonical.EventRecord) !void {
    const allocator = std.testing.allocator;
    const restored = try allocator.create(coordination.CoordinatorOwner);
    defer allocator.destroy(restored);
    try recoverCoordinatorInto(restored, coordinator);
    const recovered = try allocator.alloc(demo.Owner, 4);
    defer allocator.free(recovered);
    for (recovered, owners) |*owner, *live| {
        try demo.Owner.recoverInto(owner, live.store, undefined, live.stream);
        try std.testing.expectEqualDeep(live.shard.economicSummary(), owner.shard.economicSummary());
        try std.testing.expectEqual(@as(u64, 2), owner.shard.risk_lease_version);
        try std.testing.expectEqual(@as(usize, 0), owner.shard.oms.emitted().len);
        owner.shard.operational_state.trading_authorized = false;
        owner.shard.operational_state.mode = .recovering;
    }
    try std.testing.expectError(error.FreshNativeBootstrapRequired, restored.completeRecovery());
    try restored.acceptVenueFact(original);
    try std.testing.expectError(error.FreshNativeBootstrapRequired, restored.completeRecovery());
    var fresh = original.event.account_bootstrap_snapshot;
    fresh.identity = 30_050;
    _ = try broadcast(restored, recovered, .{ .account_bootstrap_snapshot = fresh });
    try std.testing.expectError(error.FreshMarginObservationRequired, restored.completeRecovery());
    for (recovered, 0..) |*owner, index| try restored.apply(.{ .publish_summary = .{
        .identity = 1_000 + index,
        .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 3, index + 1),
    } });
    try restored.apply(.{ .margin_observation = .{ .identity = 30_101, .barrier = restored.coordinator.barrier + 1, .venue_net_margin_atoms = 0, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 } });
    try restored.completeRecovery();
    try std.testing.expect(!restored.coordinator.recovery_only);
    try std.testing.expectEqual(@as(i128, 8), try restored.coordinator.grossPortfolioMargin());
    try std.testing.expectEqual(@as(i128, 4), restored.coordinator.account_netting_benefit_atoms);
    for (recovered) |*owner| {
        try std.testing.expectEqual(trading.operational.OperationalMode.recovering, owner.shard.operational_state.mode);
        try std.testing.expect(!owner.shard.operational_state.trading_authorized);
        try std.testing.expectEqual(@as(i128, 0), try owner.shard.activeReservationAtoms());
        try std.testing.expectEqual(@as(usize, 0), owner.shard.oms.emitted().len);
    }
    try restored.checkpoint();
    try recoverCoordinatorInto(restored, coordinator);
    try std.testing.expectError(error.FreshNativeBootstrapRequired, restored.completeRecovery());
}

noinline fn recoverCoordinatorInto(destination: *coordination.CoordinatorOwner, previous: *const coordination.CoordinatorOwner) !void {
    destination.* = try coordination.CoordinatorOwner.recover(previous.stream, previous.store, undefined);
}

noinline fn verifySecondaryFee(coordinator: *coordination.CoordinatorOwner, owners: []demo.Owner) !void {
    const projection = &owners[0].shard.economic_projection;
    var origin: ?canonical.FeeOrigin = null;
    for (projection.applied_fills[0..projection.applied_fill_count]) |applied| {
        if (applied.source.portfolio == 15) {
            origin = projection.feeOrigin(applied.fill.identity);
            break;
        }
    }
    const original = origin orelse return error.TestMissingSecondaryFillOrigin;
    const before_primary = projection.portfolioLayer(11).?.usdt_balance_atoms;
    const before_secondary = projection.portfolioLayer(15).?.usdt_balance_atoms;
    const source: canonical.RawEvidenceRef = .{ .stream = 1, .sequence = 40_001, .digest = @splat(7) };
    const ingress = coordinator.coordinator.venue_ingress;
    var fee = fixture.canonicalAt(61, ingress.sequence + 1, .{ .fee_adjustment = .{
        .identity = 40_001,
        .fill_identity = original.original.identity,
        .exchange_account = 2,
        .portfolio = 15,
        .strategy = 5,
        .cycle_first_sequence = 1,
        .original = original,
        .source_version = 1,
        .previous_fee_version = 0,
        .new_fee = .{ .asset = 1, .atoms = 1 },
        .source = source,
        .effective_time_utc_ns = fixture.atGroup(61, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
    } });
    fee.venue.envelope.identity.stream = ingress.stream;
    fee.venue.envelope.source_stream = ingress.source_stream;
    fee.venue.envelope.source_fact_identity = 40_001;
    fee.venue.envelope.instrument = original.original.instrument;
    fee.venue.envelope.asset = 1;
    fee.venue.envelope.raw_evidence = source;
    try coordinator.acceptVenueFactFromOwners(fee.venue, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    try std.testing.expect(try coordinator.deliverVenueFact(.shard_0, &owners[0]));
    try std.testing.expectEqual(before_primary, owners[0].shard.economic_projection.portfolioLayer(11).?.usdt_balance_atoms);
    try std.testing.expectEqual(before_secondary - 1, owners[0].shard.economic_projection.portfolioLayer(15).?.usdt_balance_atoms);
    for (owners[1..], 1..) |*owner, index| try std.testing.expect(!try coordinator.deliverVenueFact(@enumFromInt(index), owner));
    try owners[0].checkpoint();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, owners[0].store, undefined, owners[0].stream);
    try std.testing.expectEqualDeep(owners[0].shard.canonicalStateDigest(), recovered.shard.canonicalStateDigest());
}

test "04 four Owners retain real opposing portfolio fills and gross margin" {
    try exercisePortfolioFills(false, false);
}

test "04 four Owners archive portfolio B forced native PnL independently" {
    try exercisePortfolioFills(true, false);
}

fn exercisePortfolioFills(comptime forced_case: bool, comptime recovery_case: bool) !void {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const owners = try allocator.alloc(demo.Owner, 4);
    defer allocator.free(owners);
    for (owners, 0..) |*owner, index| {
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 9101 + index });
        try setup.initializeMultiPortfolio(owner, index);
    }
    var baseline: canonical.AccountBootstrapSnapshot = .{
        .identity = 90,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 999,
        .source_sequence = 0,
        .balance_count = 1,
        .position_count = 0,
        .margin_count = 8,
    };
    const zero: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
    const cash: canonical.AssetAmount = .{ .asset = 1, .atoms = 100 };
    baseline.balances[0] = .{ .asset = 1, .total = cash, .available = cash, .held = zero, .cash_balance = cash, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
    for (baseline.margins[0..8], 1..) |*margin, instrument| margin.* = .{ .instrument = instrument, .amount = zero, .initial_margin = zero, .maintenance_margin = zero, .isolated_equity = zero };
    var baseline_record = fixture.canonicalAt(39, 1, .{ .account_bootstrap_snapshot = baseline });
    baseline_record.venue.envelope.identity.stream = 999;
    baseline_record.venue.envelope.source_stream = 999;
    for (owners) |*owner| _ = try owner.apply(baseline_record);
    if (recovery_case) for (owners[1..], 1..) |*owner, index| try gateway_fixture.prepareTrading(owner, index, 1);
    try placeGroups(&owners[0], forced_case);
    if (recovery_case) for (owners[1..], 1..) |*owner, index| {
        for ([_]u128{ index + 1, index + 5 }) |instrument| {
            var margin = owners[0].shard.registryInstrument(1).?.margin;
            margin.instrument = instrument;
            try apply(owner, 2, .{ .margin_rules_activated = margin });
        }
    };
    try std.testing.expect(owners[0].shard.economic_projection.portfolioLayer(15) != null);
    for (owners[0].shard.oms.orders[0..4], 0..) |order, index| {
        try std.testing.expectEqual(@as(u128, if (index < 2) 11 else 15), order.portfolio);
    }
    const gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(gateway);
    const dispatch_storage = try allocator.alloc(u8, durable.max_snapshot_bytes);
    defer allocator.free(dispatch_storage);
    gateway.initWithDispatchSnapshotBuffer(dispatch_storage);
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 9700 });
    try gateway.pinDeploymentDigest(owners[0].shard.deployment.header.?.expected_digest);
    const when = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core;
    const simulator = try allocator.create(simulated.SimulatedVenue);
    defer allocator.destroy(simulator);
    initializeSimulatorInto(simulator, .{ .source_utc_ns = when.source_time, .receive_utc_ns = when.receive_time, .monotonic_ns = when.monotonic_time, .audit_utc_ns = when.wall_time });
    var adapter = simulator.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owners[0].shard.asset_registry, .instrument_definitions = owners[0].shard.instrument_registry });
    try gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .supported_products = execution.productMask(.isolated_linear_usdt), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    const coordinator = try allocator.create(coordination.CoordinatorOwner);
    defer allocator.destroy(coordinator);
    try initializeCoordinatorInto(coordinator, memory.interface());
    for (owners, 0..) |*owner, index| try coordinator.apply(.{ .publish_summary = .{ .identity = index + 1, .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 1, index + 1) } });
    for (1..5) |command_id| {
        const command = owners[0].shard.oms.findCommand(command_id) orelse return error.TestMissingCommand;
        try coordinator.recordGateway(.{ .exchange_account = 2, .shard_id = .shard_0, .fencing_token = 1, .command = command });
        const now = try gateway_fixture.observe(gateway, &owners[0], command_id);
        try std.testing.expectEqual(.accepted, try gateway.sendFromShard(&owners[0].shard, command_id, now));
        const batch = (try adapter.tryDrain()) orelse return error.TestMissingAdapterOutput;
        for (batch.slice()) |record| {
            try coordinator.acceptVenueFactFromGateway(record, gateway, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
            try std.testing.expect(try coordinator.deliverVenueFact(.shard_0, &owners[0]));
        }
    }
    const projection = &owners[0].shard.economic_projection;
    const primary = projection.portfolioLayer(11) orelse return error.TestMissingPrimaryPortfolioAfterDelivery;
    try std.testing.expectEqual(@as(i64, 30_000), primary.positionForInstrument(1).quantity);
    const secondary = projection.portfolioLayer(15) orelse return error.TestMissingSecondaryPortfolioAfterDelivery;
    try std.testing.expectEqual(@as(i64, if (forced_case) 20_000 else -10_000), secondary.positionForInstrument(1).quantity);
    try std.testing.expectEqual(@as(i64, if (forced_case) 50_000 else 20_000), projection.exchange.positionForInstrument(1).quantity);
    try std.testing.expectEqual(@as(i128, 0), try owners[0].shard.activeReservationAtoms());
    for (owners, 0..) |*owner, index| try coordinator.apply(.{ .publish_summary = .{ .identity = index + 101, .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 2, index + 1) } });
    try std.testing.expectEqual(@as(i128, if (forced_case) 11 else 8), try coordinator.coordinator.grossPortfolioMargin());
    try std.testing.expectEqual(@as(i128, 0), projection.netting_settlement_atoms);
    for (owners[1..]) |*owner| {
        try std.testing.expect(owner.shard.economic_projection.portfolioLayer(15) == null);
        try std.testing.expectEqual(@as(i64, 0), owner.shard.economic_projection.exchange.positionForInstrument(1).quantity);
    }
    if (forced_case) return verifyPortfolioForced(coordinator, owners, gateway);
    try verifyNativeMargin(coordinator, owners, recovery_case);
    if (!recovery_case) try verifySecondaryFee(coordinator, owners);
}

noinline fn verifyPortfolioForced(coordinator: *coordination.CoordinatorOwner, owners: []demo.Owner, gateway: *execution.Gateway) !void {
    try owners[0].bindAccountCoordinator(coordinator);
    const before_a = owners[0].shard.economic_projection.portfolioLayer(11).?.*;
    const before_b = owners[0].shard.economic_projection.portfolioLayer(15).?.usdt_balance_atoms;
    const before_exchange = owners[0].shard.economic_projection.exchange.usdt_balance_atoms;
    const forced: canonical.ForcedExecution = .{
        .identity = 40_001,
        .execution_time_utc_ns = fixture.atGroup(47, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
        .exchange_account = 2,
        .instrument = 1,
        .rules_version = 1,
        .kind = .liquidation,
        .venue_execution = try canonical.VenueTradeRef.init(1, "portfolio-b-liquidation"),
        .quantity = .{ .instrument = 1, .rules_version = 1, .lots = 20_000 },
        .side = .sell,
        .price = .{ .instrument = 1, .rules_version = 1, .ticks = 11 },
        .fee = .{ .asset = 1, .atoms = 0 },
        .penalty = .{ .asset = 1, .atoms = 0 },
        .realized_pnl = .{ .asset = 1, .atoms = 1 },
    };
    var record = fixture.canonicalAt(47, coordinator.coordinator.venue_ingress.sequence + 1, .{ .forced_execution = forced }).venue;
    record.envelope.instrument = 1;
    record.envelope.source_fact_identity = forced.identity;
    try coordinator.acceptForcedVenueFact(record, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    var allocation: coordination.ForcedExecutionAllocation = .{ .identity = 40_002, .forced_execution_identity = forced.identity, .count = 1 };
    allocation.slices[0] = .{ .owner = .shard_0, .portfolio = 15, .quantity = -20_000, .position_delta = -20_000, .realized_pnl_atoms = 1 };
    try coordinator.allocateForcedExecution(allocation);
    const delivery = (try coordinator.coordinator.pendingForcedDeliveries())[0];
    try std.testing.expectError(error.ForcedDeliveryNotCommitted, coordinator.ackForcedDelivery(delivery, &owners[0]));
    try std.testing.expectError(error.CrossShardDelivery, coordinator.ackForcedDelivery(delivery, &owners[1]));
    const core = try coordination.accountFactEvent(delivery);
    _ = try owners[0].apply(.{ .core = core });
    const projection = &owners[0].shard.economic_projection;
    try std.testing.expectEqualDeep(before_a, projection.portfolioLayer(11).?.*);
    try std.testing.expectEqual(before_b - 2, projection.portfolioLayer(15).?.usdt_balance_atoms);
    try std.testing.expectEqual(before_exchange + 1, projection.exchange.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, 3), projection.netting_settlement_atoms);
    try std.testing.expectEqual(@as(u128, 5), projection.applied_forced_executions[0].source.strategy);
    const forced_id = projection.applied_forced_executions[0].forced.identity;
    try owners[0].checkpoint();
    const recovered_owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered_owner);
    try demo.Owner.recoverInto(recovered_owner, owners[0].store, undefined, owners[0].stream);
    try std.testing.expectEqualDeep(owners[0].shard.canonicalStateDigest(), recovered_owner.shard.canonicalStateDigest());
    try coordinator.ackForcedDelivery(delivery, &owners[0]);
    try std.testing.expectEqual(@as(usize, 0), (try coordinator.coordinator.pendingForcedDeliveries()).len);
    _ = try coordinator.archiveForcedSource();
    _ = try owners[0].archiveForcedExecutionHistory(forced_id, coordinator, gateway);
    try std.testing.expectEqual(@as(u8, 0), projection.applied_forced_execution_count);
    const economic_after = projection.digest();
    const commands_after = owners[0].shard.oms.command_count;
    const sends_after = gateway.send_attempt_count;
    _ = try owners[0].apply(.{ .core = core });
    try std.testing.expectEqualDeep(economic_after, projection.digest());
    try std.testing.expectEqual(commands_after, owners[0].shard.oms.command_count);
    try std.testing.expectEqual(sends_after, gateway.send_attempt_count);
    try owners[0].checkpoint();
    const after = owners[0].shard.canonicalStateDigest();
    try demo.Owner.recoverInto(recovered_owner, owners[0].store, undefined, owners[0].stream);
    try std.testing.expectEqualDeep(after, recovered_owner.shard.canonicalStateDigest());
    try coordinator.checkpoint();
    const recovered_coordinator = try coordination.CoordinatorOwner.recover(coordinator.stream, coordinator.store, undefined);
    try std.testing.expectEqualDeep(coordinator.coordinator.digest(), recovered_coordinator.coordinator.digest());
    var conflict = core;
    conflict.payload.venue_forced_execution.price_ticks += 1;
    _ = try recovered_owner.apply(.{ .core = conflict });
    try std.testing.expect(recovered_owner.shard.history_conflict_latched);
    try std.testing.expectEqualDeep(economic_after, recovered_owner.shard.economic_projection.digest());
    try std.testing.expectEqual(sends_after, gateway.send_attempt_count);
}

noinline fn initializeCoordinatorInto(coordinator: *coordination.CoordinatorOwner, store: durable.Store) !void {
    coordinator.* = try coordination.CoordinatorOwner.init(.init(2, 100, 100), .{ .domain = .control, .id = 9701 }, store, undefined);
}

noinline fn initializeSimulatorInto(simulator: *simulated.SimulatedVenue, times: @FieldType(simulated.SimulatedVenue, "receipt_times")) void {
    simulator.* = .{ .receipt_times = times };
}

test "07 four recovered Owners require fresh native account and margin evidence without sending" {
    try exercisePortfolioFills(false, true);
}
