//! Real offline shared Gateway and VenueAdapter ownership delivery.
const std = @import("std");
const simulated = @import("../../../adapters/simulated/simulated_venue.zig");
const canonical = @import("../../../model/canonical_event.zig");

test "03 shared Gateway VenueAdapter prepares origin-qualified wire client IDs" {
    var simulator: simulated.SimulatedVenue = .{};
    const adapter = simulator.adapter();
    const raw = try canonical.ClientOrderId.init("RWN-1");
    const first = try adapter.prepareClientOrderId(@splat(1), 2, 1, raw);
    const second = try adapter.prepareClientOrderId(@splat(2), 2, 1, raw);
    try std.testing.expect(!std.meta.eql(first, second));
}
const trading = @import("../../../trading/trading_shard.zig");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const host = @import("../../../strategy/strategy_host_gateway.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const setup = @import("shared_venue_delivery_acceptance.zig");
const history = @import("../../../persistence/business_history.zig");

fn failHistoryQuery(_: *anyopaque, _: std.Io, _: history.LookupRequest) anyerror!history.LookupResult {
    return error.InjectedHistoryEio;
}

pub fn admit(owner: *demo.Owner, index: usize) !void {
    const domain = index + 1;
    const controls = [_]trading.CorePayload{
        .{ .strategy_activated = .{ .strategy_identity = domain, .config_version = 1, .activation_identity = 1 } },
        .{ .primary_lease_granted = .{ .fencing_token = domain } },
        .{ .risk_lease_granted = .{ .amount_atoms = 25 } },
        .{ .control_command = .{ .command_identity = 900, .content_hash = 900, .target_identity = domain, .expected_version = 0, .expires_at = std.math.maxInt(u64), .kind = .start_recovery } },
        .recovery_completed,
        .{ .control_command = .{ .command_identity = 901, .content_hash = 901, .target_identity = domain, .expected_version = 2, .expires_at = std.math.maxInt(u64), .kind = .enable_trading } },
    };
    for (controls, 0..) |payload, n| {
        var input = fixture.atGroup(41, .{ .identity = n + 900, .payload = payload });
        if (payload == .risk_lease_granted) {
            input.core.account_scope = 2;
            input.core.payload.risk_lease_granted.allocation = .{
                .configuration_digest = owner.shard.deployment.header.?.expected_digest,
                .account = 2,
                .asset = 1,
                .domain = domain,
                .stream = index + 9101,
            };
        }
        _ = try owner.apply(input);
    }
    for ([_]u128{ domain, domain + 4 }) |instrument| {
        _ = try owner.apply(fixture.atGroup(42, .{ .identity = @intCast(1000 + instrument), .account_scope = 2, .payload = .{ .margin_rules_activated = .{ .version = 2, .instrument = instrument } } }));
        _ = try owner.apply(fixture.atGroup(42, .{ .identity = @intCast(1100 + instrument), .account_scope = 2, .payload = .{ .capability_profile_activation = .{
            .exchange_account = 2,
            .instrument = instrument,
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
        var book = fixture.canonicalAt(43, 1, .{ .l2_book_snapshot = .{
            .instrument = instrument,
            .sequence = 1,
            .best_bid = .{ .instrument = instrument, .rules_version = 1, .ticks = 9 },
            .best_ask = .{ .instrument = instrument, .rules_version = 1, .ticks = 10 },
            .best_bid_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 100000 },
            .best_ask_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 100000 },
        } });
        book.venue.envelope.scope = .instrument;
        book.venue.envelope.exchange_account = null;
        book.venue.envelope.instrument = instrument;
        book.venue.envelope.identity.stream = 1000 + instrument;
        book.venue.envelope.source_stream = 1000 + instrument;
        _ = try owner.apply(book);
        _ = try owner.apply(fixture.atGroup(44, .{ .identity = @intCast(1200 + instrument), .account_scope = 2, .payload = .{ .mark_price = .{ .instrument = instrument, .price_atoms = 10 } } }));
    }
    const barrier = owner.shard.authoritativeBarrier();
    const config: host.Config = .{
        .schema_registry = trading.schema_registry_identity,
        .decision_domain = domain,
        .session = .{ .fencing = domain, .shard = @intCast(domain), .generation = 1 },
        .authorization = .{ .strategy_identity = domain, .config_version = 1, .activation_identity = 1, .activation_barrier = barrier },
    };
    _ = try owner.apply(fixture.atGroup(45, .{ .identity = 1300, .payload = .{ .host_activated = .{ .strategy_identity = domain, .config_version = 1, .activation_identity = 1, .activation_barrier = barrier, .session = config.session, .state_digest = owner.shard.canonicalStateDigest() } } }));
    const orders = [_]host.OutputOrder{
        .{ .portfolio_identity = index + 11, .exchange_account_identity = 2, .instrument_identity = domain, .quantity = 10000, .limit_price_micros = 10 },
        .{ .portfolio_identity = index + 11, .exchange_account_identity = 2, .instrument_identity = domain + 4, .quantity = 10000, .limit_price_micros = 10 },
    };
    var buffer: [host.max_group_frame_len]u8 = undefined;
    const frame = try host.encodeOutputGroupFrame(&buffer, config, 1, owner.shard.authoritativeBarrier() + 1, 1, &orders);
    var candidate: host.GroupCandidate = .{ .len = @intCast(frame.len) };
    @memcpy(candidate.bytes[0..frame.len], frame);
    _ = try owner.apply(fixture.atGroup(45, .{ .identity = 1301, .payload = .{ .external_intent_group = candidate } }));
    try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.none, owner.shard.last_reject_reason);
    try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.command_history_count);
}

test "03 fee origin history failure closes the shared account writer" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const owners = try allocator.alloc(demo.Owner, 4);
    defer allocator.free(owners);
    var coordinator = try coordination.CoordinatorOwner.init(.init(2, 100, 100), .{ .domain = .control, .id = 9391 }, memory.interface(), undefined);
    for (owners, 0..) |*owner, index| {
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = index + 9101 });
        try setup.initialize(owner, index);
        try coordinator.apply(.{ .publish_summary = .{ .identity = index + 1, .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 1, index + 1) } });
    }
    try coordinator.checkpoint();
    const original: canonical.Fill = .{
        .identity = 99,
        .order = 1,
        .client_order_id = try canonical.ClientOrderId.init("unknown"),
        .venue_order = try canonical.VenueOrderRef.init(1, "unknown"),
        .venue_trade = try canonical.VenueTradeRef.init(1, "unknown"),
        .instrument = 1,
        .exchange_account = 2,
        .side = .buy,
        .quantity = .{ .instrument = 1, .rules_version = 1, .lots = 1 },
        .price = .{ .instrument = 1, .rules_version = 1, .ticks = 10 },
        .fee = .{ .asset = 1, .atoms = 0 },
        .liquidity = .taker,
    };
    const source: canonical.RawEvidenceRef = .{ .stream = 1, .sequence = 1, .digest = @splat(1) };
    var fee = fixture.canonicalAt(47, 1, .{ .fee_adjustment = .{
        .identity = 1,
        .fill_identity = 99,
        .exchange_account = 2,
        .portfolio = 11,
        .strategy = 1,
        .cycle_first_sequence = 1,
        .original = .{ .original = original, .portfolio = 11, .strategy = 1, .cycle_first_sequence = 1 },
        .source_version = 1,
        .previous_fee_version = 0,
        .new_fee = .{ .asset = 1, .atoms = 1 },
        .source = source,
        .effective_time_utc_ns = fixture.atGroup(47, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
    } });
    fee.venue.envelope.instrument = 1;
    fee.venue.envelope.asset = 1;
    fee.venue.envelope.raw_evidence = source;
    var failing = memory.interface().vtable.*;
    failing.query_order_history = failHistoryQuery;
    owners[0].store = .{ .context = memory, .vtable = &failing };
    try std.testing.expectError(error.InjectedHistoryEio, coordinator.acceptVenueFactFromOwners(fee.venue, .{ &owners[0], &owners[1], &owners[2], &owners[3] }));
    try std.testing.expect(coordinator.closed);
    try std.testing.expectError(error.CoordinatorWriterClosed, coordinator.acceptVenueFact(fee.venue));
    const recovered = try coordination.CoordinatorOwner.recover(coordinator.stream, memory.interface(), undefined);
    try std.testing.expect(recovered.coordinator.venue_ingress.broken);
    try std.testing.expect(recovered.coordinator.margin_gate.latched);
}

pub fn observe(gateway: *execution.Gateway, owner: *const demo.Owner, command_id: u64) !u64 {
    const command = owner.shard.oms.findCommand(command_id).?;
    try gateway.observeAuthorityFromShard(&owner.shard, .{
        .account = 2,
        .effective_trading_authority = owner.shard.operational_state.effectiveTradingAuthority(),
        .reservation_identity = command.reservation_identity,
        .reservation = command.reservation,
        .primary_lease_expires_at_monotonic_ns = 100 * std.time.ns_per_s,
        .fencing_token = owner.shard.fencing_token,
        .exchange_position = owner.shard.currentNetExchangePosition(command.instrument).?,
        .authority_barrier = owner.shard.authoritativeBarrier(),
    });
    return command.authority.dispatch_deadline_monotonic_ns - 1;
}

test "03 actual shared Gateway routes colliding local orders through one VenueAdapter" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const owners = try allocator.alloc(demo.Owner, 4);
    defer allocator.free(owners);
    var bootstrap: canonical.AccountBootstrapSnapshot = .{
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
    bootstrap.balances[0] = .{ .asset = 1, .total = cash, .available = cash, .held = zero, .cash_balance = cash, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
    for (bootstrap.margins[0..8], 1..) |*margin, instrument|
        margin.* = .{ .instrument = instrument, .amount = zero, .initial_margin = zero, .maintenance_margin = zero, .isolated_equity = zero };
    var baseline = fixture.canonicalAt(39, 1, .{ .account_bootstrap_snapshot = bootstrap });
    baseline.venue.envelope.identity.stream = 999;
    baseline.venue.envelope.source_stream = 999;
    for (owners, 0..) |*owner, index| {
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = index + 9101 });
        try setup.initialize(owner, index);
        _ = try owner.apply(baseline);
        try admit(owner, index);
    }
    const gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 9290 });
    try gateway.pinDeploymentDigest(owners[0].shard.deployment.header.?.expected_digest);
    var definitions = owners[0].shard.instrument_registry;
    for (owners, 1..) |*owner, domain| {
        for ([_]u128{ domain, domain + 4 }) |instrument|
            _ = try definitions.configureMargin(instrument, owner.shard.registryInstrument(instrument).?.margin);
    }
    var simulator: simulated.SimulatedVenue = .{ .receipt_times = .{ .source_utc_ns = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core.source_time, .receive_utc_ns = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core.receive_time, .monotonic_ns = 1461000000, .audit_utc_ns = fixture.atGroup(46, .{ .identity = 0, .payload = .recovery_completed }).core.wall_time } };
    var adapter = simulator.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owners[0].shard.asset_registry, .instrument_definitions = definitions });
    const route: execution.Route = .{ .account = 2, .adapter = adapter, .venue_identity = 1, .supported_products = execution.productMask(.isolated_linear_usdt), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } };
    try gateway.add(route);
    var coordinator = try coordination.CoordinatorOwner.init(.init(2, 100, 100), .{ .domain = .control, .id = 9291 }, memory.interface(), undefined);
    for (owners, 0..) |*owner, index| try coordinator.apply(.{ .publish_summary = .{ .identity = index + 1, .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 1, index + 1) } });
    try coordinator.checkpoint();
    var batches: [4]canonical.AdapterOutputBatch = undefined;
    var wire: [4]canonical.ClientOrderId = undefined;
    for (owners, 0..) |*owner, index| {
        const command = owner.shard.oms.findCommand(1).?;
        try std.testing.expectEqual(@as(u64, 1), command.order_id);
        try std.testing.expectEqualStrings("RWN-1", command.client_order_id.slice());
        try coordinator.recordGateway(.{ .exchange_account = 2, .shard_id = @enumFromInt(index), .fencing_token = owner.shard.fencing_token, .command = command });
        const now = try observe(gateway, owner, 1);
        try std.testing.expectEqual(.accepted, try gateway.sendFromShard(&owner.shard, 1, now));
        wire[index] = gateway.acceptedClientOrderIdFromShard(&owner.shard, 1).?;
        batches[index] = (try adapter.tryDrain()).?;
    }
    for (wire, 0..) |id, index| {
        for (wire[0..index]) |previous| try std.testing.expect(!std.meta.eql(previous, id));
    }
    for (batches, 0..) |batch, index| {
        var before: [4][32]u8 = undefined;
        for (owners, 0..) |*owner, n| before[n] = owner.shard.canonicalStateDigest();
        const before_reservation = try owners[index].shard.activeReservationAtoms();
        for (batch.slice()) |record| {
            try coordinator.acceptVenueFactFromGateway(record, gateway, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
            try std.testing.expect(!coordinator.coordinator.venue_ingress.broken);
            try std.testing.expect(try coordinator.deliverVenueFact(@enumFromInt(index), &owners[index]));
            for (owners, 0..) |*owner, n| {
                if (n != index) try std.testing.expectEqualDeep(before[n], owner.shard.canonicalStateDigest());
            }
        }
        try std.testing.expectEqual(@as(i64, 10000), try owners[index].shard.economic_projection.appliedCanonicalFillQuantity(1));
        // Each untouched order retains one margin atom and one fee-buffer atom.
        try std.testing.expectEqual(@as(i128, 2), try owners[index].shard.activeReservationAtoms());
        try std.testing.expectEqual(@as(i128, 4), before_reservation);
        try std.testing.expect(owners[index].shard.oms.orderById(1).?.state == .filled);
        try std.testing.expectEqual(@as(i128, 25), owners[index].shard.economic_projection.portfolio.usdt_balance_atoms);
    }
    const origin = owners[0].shard.economic_projection.feeOrigin(3).?;
    try std.testing.expectEqual(@as(u128, 11), origin.portfolio);
    try std.testing.expectEqual(@as(u128, 1), origin.strategy);
    try std.testing.expectEqual(@as(u64, 1), origin.cycle_first_sequence);
    const fee_source: canonical.RawEvidenceRef = .{ .stream = 1, .sequence = 25, .digest = @splat(2) };
    var fee = fixture.canonicalAt(47, 25, .{ .fee_adjustment = .{
        .identity = 25,
        .original = origin,
        .fill_identity = 3,
        .exchange_account = 2,
        .portfolio = 11,
        .strategy = 1,
        .cycle_first_sequence = 1,
        .source_version = 1,
        .previous_fee_version = 0,
        .new_fee = .{ .asset = 1, .atoms = 1 },
        .source = fee_source,
        .effective_time_utc_ns = fixture.atGroup(47, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
    } });
    fee.venue.envelope.instrument = 1;
    fee.venue.envelope.asset = 1;
    fee.venue.envelope.raw_evidence = fee_source;
    try coordinator.acceptVenueFactFromOwners(fee.venue, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    try std.testing.expect(try coordinator.deliverVenueFact(.shard_0, &owners[0]));
    try std.testing.expectEqual(@as(i128, 24), owners[0].shard.economic_projection.portfolio.usdt_balance_atoms);
    for (owners[1..], 1..) |*owner, index| {
        try std.testing.expect(!try coordinator.deliverVenueFact(@enumFromInt(index), owner));
        try std.testing.expectEqual(@as(i128, 25), owner.shard.economic_projection.portfolio.usdt_balance_atoms);
    }
    const after_fee = owners[0].shard.canonicalStateDigest();
    try coordinator.acceptVenueFactFromOwners(fee.venue, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    try std.testing.expect(!try coordinator.deliverVenueFact(.shard_0, &owners[0]));
    try std.testing.expectEqualDeep(after_fee, owners[0].shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 25), simulator.next_event_identity);
    try std.testing.expect((try adapter.tryDrain()) == null);
    try coordinator.checkpoint();
    var replayed = try coordination.CoordinatorOwner.recover(coordinator.stream, memory.interface(), undefined);
    try std.testing.expectEqualDeep(coordinator.coordinator.digest(), replayed.coordinator.digest());
    const restored = try allocator.create(demo.Owner);
    defer allocator.destroy(restored);
    for (owners, 0..) |*owner, index| {
        try owner.checkpoint();
        try demo.Owner.recoverInto(restored, memory.interface(), undefined, owner.stream);
        try std.testing.expectEqualDeep(owner.shard.economicSummary(), restored.shard.economicSummary());
        try std.testing.expect(restored.shard.oms.orderById(1).?.state == .filled);
        try std.testing.expectEqual(@as(i128, 2), try restored.shard.activeReservationAtoms());
        try std.testing.expect((try replayed.pendingVenueFact(@enumFromInt(index))) == null);
        try std.testing.expect(restored.shard.recovery_admission_pending);
        const retry_time = try observe(gateway, restored, 2);
        try std.testing.expectError(error.NotSent, gateway.sendFromShard(&restored.shard, 2, retry_time));
    }
    const recovered_gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(recovered_gateway);
    recovered_gateway.init();
    try recovered_gateway.add(route);
    try recovered_gateway.attachRecoveredDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 9290 });
    for (owners, 0..) |*owner, index|
        try std.testing.expectEqualDeep(wire[index], recovered_gateway.acceptedClientOrderIdFromShard(&owner.shard, 1).?);
    try std.testing.expectEqual(@as(u64, 25), simulator.next_event_identity);
    try std.testing.expect((try adapter.tryDrain()) == null);
    var forged = batches[0].events[2];
    try std.testing.expect(forged.event == .fill);
    forged.envelope.identity.sequence = 26;
    forged.envelope.source_sequence = 26;
    forged.envelope.source_fact_identity = 26;
    forged.envelope.raw_evidence = .{ .stream = 1, .sequence = 26, .digest = @splat(3) };
    forged.event.fill.identity = 26;
    forged.event.fill.order = 2;
    var before_forgery: [4][32]u8 = undefined;
    for (owners, 0..) |*owner, index| before_forgery[index] = owner.shard.canonicalStateDigest();
    try replayed.acceptVenueFactFromGateway(forged, gateway, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    try std.testing.expectEqual(@as(u128, 26), replayed.coordinator.reconciliation_break_identity);
    try std.testing.expect(replayed.coordinator.margin_gate.latched);
    var suspense: [1]canonical.EventRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), (try replayed.venueSuspense(&suspense)).len);
    try std.testing.expectEqualDeep(forged.event, suspense[0].event);
    for (owners, 0..) |*owner, index|
        try std.testing.expectEqualDeep(before_forgery[index], owner.shard.canonicalStateDigest());
}
