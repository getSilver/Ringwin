const std = @import("std");
const allocation = @import("../../../trading/deployment_allocation.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const existing = @import("multi_account_authority_acceptance.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const trading = @import("../../../trading/trading_shard.zig");

test "04 forced secondary portfolio preserves strategy provenance through recovery" {
    try exercisePortfolioForced(.provenance);
}

test "04 forced snapshot rejects a substituted portfolio source" {
    try exercisePortfolioForced(.tamper);
}

test "04 forced native PnL keeps portfolio cost difference in netting settlement" {
    try exercisePortfolioForced(.pnl);
}

fn exercisePortfolioForced(comptime scenario: enum { provenance, tamper, pnl }) !void {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try cycleConfiguration();
    try existing.initializePythonOwnerForConfiguration(owner, &manifest);
    for ([_]u128{ 20, 30 }) |account| {
        try applyHostCore(owner, account, .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } });
        try applyHostCore(owner, account, .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 100 } });
    }
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } });
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| try applyHostCore(owner, account, .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = account, .instrument = instrument, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = true } });
    for ([_]u128{ 9, 19 }, [_]u128{ 10, 11 }, 0..) |strategy, portfolio, index| {
        var group = portfolioGroup(strategy, portfolio, 51001 + index * 2);
        for (group.members[0..2]) |*member| {
            member.quantity = if (scenario == .pnl and index == 0) 40000 else 10000;
            if (scenario != .pnl) member.side = .buy;
            if (scenario == .pnl and index == 1) member.limit_price.ticks = 120;
        }
        _ = try owner.apply(fixture.atGroup(50 + index * 2, .{ .identity = 52001 + index, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@as(u16, @intCast(2 * (index + 1))), owner.shard.oms.order_count);
        try applyForcedOpeningFill(owner, 1 + index * 2, 53001 + index, if (scenario == .pnl and index == 0) 30000 else 10000, if (scenario == .pnl and index == 1) 120 else 100, 100 + index);
    }
    if (scenario == .pnl) try applyForcedOpeningFill(owner, 1, 53003, 10000, 80, 102);
    const before_a = owner.shard.economic_projection.portfolioLayer(10).?.*;
    const before_b = owner.shard.economic_projection.portfolioLayer(11).?.*;
    const before_exchange = owner.shard.economic_projection.exchange.usdt_balance_atoms;
    const before_netting = owner.shard.economic_projection.netting_settlement_atoms;
    const forced: trading.CoreEvent = fixture.atGroup(60, .{ .identity = 54001, .account_scope = 20, .payload = .{ .venue_forced_execution = .{
        .portfolio_identity = if (scenario == .pnl) 10 else 11,
        .instrument = 101,
        .rules_version = 1,
        .execution_id = 54001,
        .side = .sell,
        .quantity = if (scenario == .pnl) 30000 else 10000,
        .price_ticks = if (scenario == .pnl) 110 else 100,
        .expected_realized_pnl_atoms = if (scenario == .pnl) 50 else 0,
    } } }).core;
    _ = try owner.apply(.{ .core = forced });
    const projection = &owner.shard.economic_projection;
    if (scenario == .pnl) {
        try std.testing.expectEqual(before_a.usdt_balance_atoms + 45, projection.portfolioLayer(10).?.usdt_balance_atoms);
        try std.testing.expectEqual(before_exchange + 50, projection.exchange.usdt_balance_atoms);
        try std.testing.expectEqual(before_netting + 5, projection.netting_settlement_atoms);
        try std.testing.expectEqualDeep(before_b, projection.portfolioLayer(11).?.*);
    } else {
        try std.testing.expectEqualDeep(before_a, projection.portfolioLayer(10).?.*);
        try std.testing.expectEqual(@as(i64, 0), projection.portfolioLayer(11).?.swap.quantity);
    }
    try owner.checkpoint();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    const before_retry = recovered.shard.canonicalStateDigest();
    _ = try recovered.apply(.{ .core = forced });
    try std.testing.expectEqualSlices(u8, &before_retry, &recovered.shard.canonicalStateDigest());
    if (scenario == .provenance) {
        try std.testing.expectEqual(@as(u128, 19), projection.applied_forced_executions[0].source.strategy);
        try applyHostCore(owner, null, .{ .strategy_cutover_fence = .{ .strategy_instance = 19 } });
        const economic_before = projection.digest();
        _ = try owner.apply(.{ .core = forced });
        try std.testing.expectEqualDeep(economic_before, projection.digest());
        try owner.checkpoint();
        try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
        try std.testing.expectEqualDeep(owner.shard.canonicalStateDigest(), recovered.shard.canonicalStateDigest());
    }
    if (scenario == .tamper) {
        try owner.decision_journal.seal();
        const bytes = try std.testing.allocator.alloc(u8, 32 * 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        const source = &projection.applied_forced_executions[0].source;
        const original = source.*;
        defer source.* = original;
        for (0..4) |field| {
            source.* = original;
            if (field == 3) source.exchange_account = 30 else if (field == 1) source.strategy = 9 else source.portfolio = 10;
            if (field == 2) source.strategy = 0;
            const invalid = try owner.shard.snapshot(&owner.decision_journal, owner.decision_journal.last_sequence, bytes);
            try std.testing.expectError(if (field == 2) error.InvalidEconomicFact else error.InvalidSnapshotState, trading.TradingShard.restoreSnapshotInto(&recovered.shard, invalid));
        }
    }
}

fn applyForcedOpeningFill(owner: *demo.Owner, order_id: u64, identity: u64, quantity: i64, price: i128, sequence: u64) !void {
    const order = owner.shard.oms.orderById(order_id).?;
    var event = fixture.canonicalAt(51 + sequence, sequence, .{ .fill = .{
        .identity = identity,
        .order = order_id,
        .client_order_id = order.client_order_id,
        .venue_order = try trading.canonical.VenueOrderRef.init(1, if (order_id == 1) "forced-a-order" else "forced-b-order"),
        .venue_trade = try trading.canonical.VenueTradeRef.init(1, if (identity == 53001) "forced-a-first" else if (identity == 53002) "forced-b-fill" else "forced-a-last"),
        .instrument = 101,
        .exchange_account = 20,
        .side = if (order.side == .buy) .buy else .sell,
        .quantity = .{ .instrument = 101, .rules_version = 1, .lots = quantity },
        .price = .{ .instrument = 101, .rules_version = 1, .ticks = price },
        .fee = .{ .asset = 1, .atoms = 0 },
        .liquidity = .taker,
    } });
    event.venue.envelope.exchange_account = 20;
    event.venue.envelope.venue = 1;
    _ = try owner.apply(event);
}

test "04 TradingShard public intent freezes portfolio on order and command" {
    const run = try std.testing.allocator.create(fixture.LiveRun);
    defer std.testing.allocator.destroy(run);
    try fixture.initializedBenchmarkRunInto(run);
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .strategy_instance = 1, .portfolio = 1, .operation = .place, .instrument = 3, .quantity = 100, .limit_price = fixture.omsPrice(3, fixture.order_limit_price), .reservation = fixture.reservation(1) };
    _ = try run.shard.apply(fixture.atGroup(16, .{ .identity = 50, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(u16, 1), run.shard.oms.order_count);
    try std.testing.expectEqual(@as(u128, 1), run.shard.oms.orders[0].portfolio);
    try std.testing.expectEqual(@as(u128, 1), run.shard.oms.emitted()[0].portfolio);
    _ = try run.shard.apply(fixture.atGroup(17, .{ .identity = 51, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 100 } } }));
    const original_order = run.shard.oms.orders[0];
    const original_command = run.shard.oms.command_history[0];
    const original_command_count = run.shard.oms.command_count;
    const original_history_count = run.shard.oms.command_history_count;
    const original_reservation = try run.shard.oms.activeReservations(original_order.reservation.asset);
    for ([_]trading.oms.Operation{ .amend, .cancel }) |operation| {
        var mutation = group;
        mutation.first_intent_sequence = 2;
        mutation.members[0].intent_sequence = 2;
        mutation.members[0].portfolio = 2;
        mutation.members[0].operation = operation;
        mutation.members[0].target_order_id = 1;
        mutation.members[0].expected_revision = 1;
        const expected = if (operation == .cancel) error.OrderPortfolioMismatch else error.InvalidVirtualPortfolio;
        try std.testing.expectError(expected, run.shard.apply(fixture.atGroup(18, .{ .identity = 52, .payload = .{ .oms_intent_group = mutation } })));
        try std.testing.expect(std.meta.eql(original_order, run.shard.oms.orders[0]));
        try std.testing.expect(std.meta.eql(original_command, run.shard.oms.command_history[0]));
        try std.testing.expectEqual(original_command_count, run.shard.oms.command_count);
        try std.testing.expectEqual(original_history_count, run.shard.oms.command_history_count);
        try std.testing.expectEqual(original_reservation, try run.shard.oms.activeReservations(original_order.reservation.asset));
    }
}

pub fn configuration() !allocation.Configuration {
    const original = try existing.configurationRows();
    var rows: [17]allocation.Input = undefined;
    @memcpy(rows[0..13], original[0..13]);
    rows[0].begin.portfolio_count = 1;
    rows[0].begin.portfolio_slice_count = 2;
    rows[13] = .{ .portfolio = .{ .identity = 11, .domain = 1 } };
    rows[14] = .{ .portfolio_slice = .{ .account = 20, .asset = 1, .portfolio = 10, .atoms = 40 } };
    rows[15] = .{ .portfolio_slice = .{ .account = 20, .asset = 1, .portfolio = 11, .atoms = 20 } };
    rows[16] = .seal;
    var manifest: allocation.Configuration = .{};
    for (rows[0..16]) |row| try manifest.apply(row);
    rows[0].begin.expected_digest = manifest.contentDigest();
    manifest.header.?.expected_digest = rows[0].begin.expected_digest;
    return manifest;
}

pub fn expectImmutableFillSourceSnapshot(owner: *demo.Owner, other_portfolio: u128, other_strategy: u128) !void {
    try std.testing.expect(owner.shard.economic_projection.applied_fill_count != 0);
    try owner.decision_journal.seal();
    const bytes = try std.testing.allocator.alloc(u8, 32 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    const restored = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(restored);
    const valid = try owner.shard.snapshot(&owner.decision_journal, owner.decision_journal.last_sequence, bytes);
    _ = try trading.TradingShard.restoreSnapshotInto(restored, valid);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.canonicalStateDigest());
    const source = &owner.shard.economic_projection.applied_fills[0].source;
    const original = source.*;
    defer source.* = original;
    try std.testing.expect(original.portfolio != other_portfolio and original.strategy != other_strategy);
    for (0..2) |field| {
        source.* = original;
        if (field == 0) source.portfolio = other_portfolio else source.strategy = other_strategy;
        const damaged = try owner.shard.snapshot(&owner.decision_journal, owner.decision_journal.last_sequence, bytes);
        try std.testing.expectError(error.InvalidSnapshotState, trading.TradingShard.restoreSnapshotInto(restored, damaged));
    }
}

test "04 secondary portfolio Gateway evidence archives and cold retries without sending" {
    try exercisePortfolioDispatchArchive(20);
}

test "04 secondary account portfolio Gateway evidence archives and recovers without sending" {
    try exercisePortfolioDispatchArchive(30);
}

fn exercisePortfolioDispatchArchive(comptime account: u128) !void {
    const host = @import("../../../strategy/strategy_host_gateway.zig");
    const execution = @import("../../../execution/execution_gateway.zig");
    const archive = @import("../history/order_gateway_archive_acceptance.zig");
    const history = @import("../../../persistence/business_history.zig");
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try cycleConfiguration();
    try existing.initializePythonOwnerForConfiguration(owner, &manifest);
    const venue_identity: u64 = if (account == 20) 1 else 21;
    const instruments = if (account == 20) [_]u128{ 101, 103 } else [_]u128{ 102, 104 };
    try applyHostCore(owner, account, .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } });
    try applyHostCore(owner, account, .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 100 } });
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } });
    for (instruments) |instrument| try applyHostCore(owner, account, .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = account, .instrument = instrument, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = true } });
    const config: host.Config = .{ .schema_registry = trading.schema_registry_identity, .decision_domain = 1, .session = .{ .fencing = 1, .shard = 1, .generation = 1 }, .authorization = .{ .strategy_identity = 19, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 } };
    try applyHostCore(owner, null, .{ .host_activated = .{ .strategy_identity = 19, .config_version = 1, .activation_identity = 1, .session = config.session, .activation_barrier = 0, .state_digest = owner.shard.canonicalStateDigest() } });
    try applyHostCore(owner, account, .{ .mark_price = .{ .instrument = instruments[0], .price_atoms = 100 } });
    try owner.checkpoint();
    var bridge = try host.Gateway.init(config, &.{host.Subscription.of(19, &.{.timer})});
    const cursor = owner.shard.authoritativeBarrier();
    var batch_bytes: [256]u8 = undefined;
    _ = try bridge.encodeBatch(&batch_bytes, 1, cursor, cursor, 100, &.{.{ .event_type = .timer, .shard_sequence = cursor, .source_time_ns = 100, .receive_time_ns = 100, .monotonic_time_ns = 100, .wall_time_utc_ns = 100, .payload = &.{} }});
    try bridge.recordPublished(1, cursor, 100);
    try bridge.activate(&owner.shard, &owner.decision_journal);
    var orders: [2]host.OutputOrder = undefined;
    for (instruments, 0..) |instrument, index| orders[index] = .{ .portfolio_identity = 11, .exchange_account_identity = account, .instrument_identity = instrument, .side = if (index == 0) .buy else .sell, .quantity = 1000, .limit_price_micros = 100 };
    var frame_bytes: [host.max_group_frame_len]u8 = undefined;
    const frame = try host.encodeOutputGroupFrame(&frame_bytes, config, 1, cursor, 1, &orders);
    const decision = bridge.ingest(frame, 101);
    try std.testing.expect(decision == .accepted_group);
    _ = try owner.apply(fixture.atGroup(50, .{ .identity = 50000, .payload = decision.corePayload() }));
    try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
    const gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    try gateway.pinDeploymentDigest(manifest.header.?.expected_digest);
    var simulator: archive.RestingSimulator = .{ .next_sequence = 1000 };
    const adapter = simulator.adapter();
    try adapter.start(.{ .venue = venue_identity, .environment = .simulation, .exchange_account = account, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1 });
    try gateway.add(.{ .account = account, .adapter = adapter, .venue_identity = venue_identity, .supported_products = execution.productMask(.isolated_linear_usdt), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    const account_view = try allocator.create(trading.TradingShard);
    defer allocator.destroy(account_view);
    for (0..2) |round| {
        if (round == 1) {
            try owner.checkpoint();
            for (0..2) |index| {
                const order = owner.shard.oms.orders[index];
                var cancel: trading.oms.IntentGroup = .{ .first_intent_sequence = 3 + index, .count = 1 };
                cancel.members[0] = .{ .intent_sequence = 3 + index, .strategy_instance = 19, .portfolio = 11, .exchange_account = account, .operation = .cancel, .instrument = order.instrument, .target_order_id = order.id, .expected_revision = order.revision };
                _ = try owner.apply(fixture.atGroup(53, .{ .identity = 50001 + index, .payload = .{ .oms_intent_group = cancel } }));
            }
        }
        const when = fixture.atGroup(52 + round * 2, .{ .identity = 0, .payload = .recovery_completed }).core;
        simulator.receive_utc_ns = when.source_time;
        simulator.receive_monotonic_ns = when.monotonic_time;
        for (0..2) |index| {
            const command_id = round * 2 + index + 1;
            const command = owner.shard.oms.findCommand(command_id).?;
            try owner.shard.copyAccountViewInto(account_view, account);
            try gateway.observeAuthorityFromShard(&owner.shard, .{ .account = account, .effective_trading_authority = account_view.operational_state.effectiveTradingAuthority(), .reservation_identity = command.reservation_identity, .reservation = command.reservation, .primary_lease_expires_at_monotonic_ns = 100 * std.time.ns_per_s, .fencing_token = 1, .exchange_position = account_view.currentNetExchangePosition(command.instrument).?, .authority_barrier = owner.shard.authoritativeBarrier() });
            try std.testing.expectEqual(.accepted, try gateway.sendFromShard(&owner.shard, command_id, command.authority.dispatch_deadline_monotonic_ns - 1));
            try owner.applyAdapterBatch((try adapter.tryDrain()).?);
        }
    }
    try existing.reconcileDomainAccount(owner, account, gateway);
    try applyHostCore(owner, null, .{ .cycle_closed = try owner.shard.qualifyCycleClosure(19, 1) });
    const command = owner.shard.oms.findCommand(1).?;
    const deadline = simulator.receive_utc_ns + 30 * std.time.ns_per_s;
    const source: trading.canonical.RawEvidenceRef = .{ .stream = 7, .sequence = 10_000, .digest = history.hash("complete secondary portfolio terminal history") };
    var terminal = fixture.canonicalAt(4000, 10_000, .{ .order_reconciliation_result = .{ .identity = 10_000, .complete = true, .status = .found_terminal, .order = command.order_id, .revision = command.revision, .cumulative_quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = 0 }, .remaining_quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = 1000 }, .terminal_status = .canceled, .rules_version = 1, .evidence = .{ .scope = .{ .exchange_account = account, .instrument = command.instrument, .order = command.order_id, .revision = 1, .from_utc_ns = owner.shard.oms.orders[0].created_at_utc_ns, .through_utc_ns = deadline }, .observed_at_utc_ns = deadline, .source = source, .terminal_archive = .{ .visibility_deadline_utc_ns = deadline, .order_history_complete = true, .terminal_history_complete = true, .fills_complete = true, .economics_complete = true } } } });
    terminal.venue.envelope.exchange_account = account;
    terminal.venue.envelope.venue = venue_identity;
    terminal.venue.envelope.identity.stream = 7;
    terminal.venue.envelope.source_stream = 7;
    terminal.venue.envelope.raw_evidence = source;
    terminal.venue.envelope.times.source_utc_ns = deadline;
    terminal.venue.envelope.times.receive_utc_ns = deadline;
    _ = try owner.apply(terminal);
    var evidence_bytes: [4]execution.DispatchEvidence = undefined;
    const evidence = try gateway.exportOrderDispatchEvidence(&owner.shard, command.order_id, &evidence_bytes);
    try std.testing.expectEqual(@as(usize, 2), evidence.len);
    for (evidence) |entry| try std.testing.expectEqual(@as(u128, 11), entry.proof.origin.portfolio);
    var encoded: [history.max_record_bytes]u8 = undefined;
    const evidence_digest = history.hash(try @import("../../../persistence/snapshot_codec.zig").encodeBare(&encoded, evidence[0]));
    const accepted_before = gateway.accepted_dispatch_count;
    const root = try owner.archiveTerminalOrder(command.order_id, gateway);
    try std.testing.expectEqual(accepted_before - 2, gateway.accepted_dispatch_count);
    try std.testing.expect(owner.shard.oms.orderById(command.order_id) == null);
    try std.testing.expectEqual(@as(u128, 11), owner.shard.oms.orderById(2).?.portfolio);
    for (gateway.accepted_dispatches[0..gateway.accepted_dispatch_count]) |entry| {
        try std.testing.expectEqual(@as(u64, 2), entry.proof.command.order_id);
        try std.testing.expectEqual(@as(u128, 11), entry.origin.portfolio);
    }
    const request: history.LookupRequest = .{ .pending_id = 1, .key = try history.scopedKey(root.origin, .{ .dispatch_command = evidence[0].proof.command.command_id }, account), .candidate_payload_digest = evidence_digest, .original_input_digest = history.hash("same secondary portfolio retry"), .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
    const result = try memory.interface().queryOrderHistory(undefined, request);
    try std.testing.expectEqual(.accepted, try gateway.retryArchivedDispatch(&owner.shard, request, &result));
    var foreign = request;
    foreign.key.origin.account = account;
    try std.testing.expectError(error.NotSent, gateway.retryArchivedDispatch(&owner.shard, foreign, &result));
    try owner.checkpoint();
    const recovered_owner = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered_owner);
    try demo.Owner.recoverInto(recovered_owner, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered_owner.shard.canonicalStateDigest());
    const recovered = try allocator.create(execution.Gateway);
    defer allocator.destroy(recovered);
    recovered.init();
    try recovered.add(gateway.routes[0]);
    try recovered.attachRecoveredDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    try std.testing.expectEqual(.accepted, try recovered.retryArchivedDispatch(&recovered_owner.shard, request, &result));
    var conflicting = request;
    conflicting.pending_id = 2;
    conflicting.candidate_payload_digest = history.hash("conflicting secondary portfolio command");
    const conflict = try memory.interface().queryOrderHistory(undefined, conflicting);
    try std.testing.expectError(error.NotSent, gateway.retryArchivedDispatch(&owner.shard, conflicting, &conflict));
    try std.testing.expectEqual(.latched, gateway.routes[0].safety_gate);
    try std.testing.expectEqual(@as(u64, 4), simulator.sends);
}

pub fn initializeEconomicsOwner(owner: *demo.Owner) !void {
    const manifest = try configuration();
    try owner.pinDeploymentDigest(manifest.header.?.expected_digest);
    try owner.installDeployment(&manifest);
    var identity = owner.shard.authoritativeBarrier() + 1;
    const global = [_]trading.CorePayload{
        .{ .decision_domain_bound = .{ .domain = 1, .stream = 91 } },
    };
    for (global) |payload| {
        _ = try owner.apply(.{ .core = .{ .identity = identity, .payload = payload } });
        identity += 1;
    }
    for (@import("../../../trading/asset_registry.zig").testDefinitions(6, 8)) |definition| {
        _ = try owner.apply(.{ .core = .{ .identity = identity, .payload = .{ .asset_definition_activated = definition } } });
        identity += 1;
    }
    const payloads = [_]trading.CorePayload{
        .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = 101, .quantity_denominator = 1, .reservation_model = .leveraged, .product = .isolated_linear_usdt, .venue = 1 } },
        .{ .margin_rules_activated = .{ .version = 1, .instrument = 101 } },
        .{ .account_configuration = .{ .exchange_account_identity = 20 } },
        .{ .exchange_balance = .{ .cash_atoms = 1000 } },
        .exchange_positions,
        .{ .opening_balance = .{ .cash_atoms = 1000 } },
        .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } },
        .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 200 } },
        .{ .virtual_portfolio_activated = .{ .portfolio_identity = 10 } },
        .{ .portfolio_transfer = .{ .portfolio_identity = 10, .amount_atoms = 400 } },
    };
    for (payloads) |payload| {
        _ = owner.apply(fixture.atGroup(10, .{ .identity = identity, .account_scope = 20, .payload = payload })) catch |err| {
            std.debug.print("portfolio setup {s}: {s}\n", .{ @tagName(payload), @errorName(err) });
            return err;
        };
        identity += 1;
    }
}

test "04 Owner activates and funds independent portfolio layers through Core snapshot" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try initializeEconomicsOwner(owner);
    const projection = &owner.shard.accountState(20).?.economic_projection;
    try std.testing.expectEqual(@as(u128, 10), projection.primary_portfolio_identity);
    try std.testing.expect(projection.portfolioLayer(10).?.funded);
    try std.testing.expect(projection.portfolioLayer(11).?.funded);
    try std.testing.expectEqual(@as(i128, 400), projection.portfolioLayer(10).?.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, 200), projection.portfolioLayer(11).?.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, 400), projection.treasury_usdt_atoms);
    const buffer = try std.testing.allocator.alloc(u8, 32 * 1024 * 1024);
    defer std.testing.allocator.free(buffer);
    try owner.decision_journal.seal();
    const snapshot = try owner.shard.snapshot(&owner.decision_journal, owner.decision_journal.last_sequence, buffer);
    const restored = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(restored);
    _ = try trading.TradingShard.restoreSnapshotInto(restored, snapshot);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.canonicalStateDigest());
    owner.shard.economic_projection.primary_portfolio_identity = 12;
    const invalid = try owner.shard.snapshot(&owner.decision_journal, owner.decision_journal.last_sequence, buffer);
    try std.testing.expectError(error.InvalidSnapshotState, trading.TradingShard.restoreSnapshotInto(restored, invalid));
}

test "04 three portfolio economics have canonical identity order across activation and recovery" {
    const original = try existing.configurationRows();
    var manifest: allocation.Configuration = .{};
    for (original[0..13], 0..) |original_row, index| {
        var row = original_row;
        if (index == 0) {
            row.begin.portfolio_count = 2;
            row.begin.portfolio_slice_count = 6;
        }
        try manifest.apply(row);
    }
    for ([_]u128{ 11, 12 }) |portfolio| try manifest.apply(.{ .portfolio = .{ .identity = portfolio, .domain = 1 } });
    for ([_]u128{ 20, 30 }) |account| for ([_]u128{ 10, 11, 12 }) |portfolio| {
        try manifest.apply(.{ .portfolio_slice = .{ .account = account, .asset = 1, .portfolio = portfolio, .atoms = if (portfolio != 10) 10 else if (account == 20) 40 else 20 } });
    };
    manifest.header.?.expected_digest = manifest.contentDigest();
    try manifest.apply(.seal);
    var expected: ?[2][32]u8 = null;
    for ([_][2]u128{ .{ 11, 12 }, .{ 12, 11 } }) |activation_order| {
        const memory = try std.testing.allocator.create(durable.MemoryAdapter);
        defer std.testing.allocator.destroy(memory);
        memory.* = .init();
        defer memory.deinit();
        const owner = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(owner);
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
        try existing.initializePythonOwnerForConfiguration(owner, &manifest);
        for (activation_order) |portfolio| for ([_]u128{ 20, 30 }) |account| {
            try applyHostCore(owner, account, .{ .virtual_portfolio_activated = .{ .portfolio_identity = portfolio } });
            try applyHostCore(owner, account, .{ .portfolio_transfer = .{ .portfolio_identity = portfolio, .amount_atoms = if (portfolio == 11) 200 else 100 } });
        };
        try owner.checkpoint();
        const recovered = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(recovered);
        try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
        try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        var digests: [2][32]u8 = undefined;
        for ([_]u128{ 20, 30 }, 0..) |account, index| {
            const projection = &recovered.shard.accountState(account).?.economic_projection;
            try std.testing.expectEqual(@as(u128, 10), projection.primary_portfolio_identity);
            try std.testing.expectEqual(@as(i128, if (account == 20) 400 else 600), projection.portfolioLayer(10).?.usdt_balance_atoms);
            try std.testing.expectEqual(@as(i128, 200), projection.portfolioLayer(11).?.usdt_balance_atoms);
            try std.testing.expectEqual(@as(i128, 100), projection.portfolioLayer(12).?.usdt_balance_atoms);
            try std.testing.expectEqual(@as(i128, if (account == 20) 300 else 1100), projection.treasury_usdt_atoms);
            digests[index] = projection.semanticDigest();
        }
        if (expected) |baseline| {
            for (baseline, digests) |left, right| try std.testing.expectEqualSlices(u8, &left, &right);
        } else expected = digests;
    }
}

test "04 configured Owner preserves two portfolio memberships and independent budgets" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try configuration();
    for (0..2) |missing| {
        var incomplete = manifest;
        incomplete.portfolio_slices[0] = manifest.portfolio_slices[1 - missing];
        incomplete.portfolio_slice_count = 1;
        incomplete.header.?.portfolio_slice_count = 1;
        incomplete.header.?.expected_digest = incomplete.contentDigest();
        const rejected = try allocator.create(demo.Owner);
        defer allocator.destroy(rejected);
        try demo.Owner.bootstrapInto(rejected, memory.interface(), undefined, owner.stream);
        try rejected.pinDeploymentDigest(incomplete.header.?.expected_digest);
        try std.testing.expectError(error.InvalidDeploymentSlice, rejected.installDeployment(&incomplete));
        try std.testing.expectEqual(@as(u64, 0), rejected.shard.authoritativeBarrier());
    }
    try owner.pinDeploymentDigest(manifest.header.?.expected_digest);
    try owner.installDeployment(&manifest);
    try std.testing.expect(owner.shard.deployment.ownsPortfolio(1, 10));
    try std.testing.expect(owner.shard.deployment.ownsPortfolio(1, 11));
    try std.testing.expect(!owner.shard.deployment.ownsPortfolio(2, 11));
    try std.testing.expectEqual(@as(?i128, 40), owner.shard.deployment.portfolioSliceLimit(20, 1, 10));
    try std.testing.expectEqual(@as(?i128, 20), owner.shard.deployment.portfolioSliceLimit(20, 1, 11));
    try std.testing.expectEqual(@as(?i128, null), owner.shard.deployment.portfolioSliceLimit(30, 1, 10));
    try std.testing.expectEqual(@as(?i128, null), owner.shard.deployment.portfolioSliceLimit(30, 1, 11));
    try std.testing.expectEqual(@as(?u128, 1), owner.shard.deployment.owner(20, 101));
    var invalid = manifest;
    invalid.portfolio_slices[1].atoms = 21;
    try std.testing.expectError(error.PortfolioBudgetOversubscribed, invalid.validateComplete());
    invalid = manifest;
    invalid.ownerships[1] = invalid.ownerships[0];
    try std.testing.expectError(error.ConflictingDeploymentOwnership, invalid.validateComplete());
    try std.testing.expectError(error.DecisionLogUnavailable, owner.checkpoint());
    try owner.decision_journal.seal();
    const recovered = try allocator.create(trading.TradingShard);
    defer allocator.destroy(recovered);
    const bytes = try allocator.alloc(u8, 32 * 1024 * 1024);
    defer allocator.free(bytes);
    const snapshot = try owner.shard.snapshot(&owner.decision_journal, owner.decision_journal.last_sequence, bytes);
    _ = try trading.TradingShard.restoreSnapshotInto(recovered, snapshot);
    try std.testing.expect(recovered.deployment.ownsPortfolio(1, 11));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.canonicalStateDigest());
}

test "04 two portfolio Host authorities share session and revoke independently" {
    const host = @import("../../../strategy/strategy_host_gateway.zig");
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try configuration();
    try owner.pinDeploymentDigest(manifest.header.?.expected_digest);
    try owner.installDeployment(&manifest);
    try applyHostCore(owner, null, .{ .decision_domain_bound = .{ .domain = 1, .stream = 91 } });
    for (@import("../../../trading/asset_registry.zig").testDefinitions(6, 8)) |definition|
        try applyHostCore(owner, null, .{ .asset_definition_activated = definition });
    const initialization = [_]trading.CorePayload{
        .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = 101, .quantity_denominator = 10000, .reservation_model = .leveraged, .product = .isolated_linear_usdt, .venue = 1 } },
        .{ .margin_rules_activated = .{ .version = 1, .instrument = 101 } },
        .{ .account_configuration = .{ .exchange_account_identity = 20 } },
        .{ .exchange_balance = .{ .cash_atoms = 1000 } },
        .exchange_positions,
        .{ .opening_balance = .{ .cash_atoms = 1000 } },
        .{ .virtual_portfolio_activated = .{ .portfolio_identity = 10 } },
        .{ .portfolio_transfer = .{ .portfolio_identity = 10, .amount_atoms = 40 } },
        .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } },
        .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 20 } },
    };
    for (initialization) |payload| try applyHostCore(owner, 20, payload);
    const session: @import("../../../strategy/strategy_host_ipc.zig").Session = .{ .fencing = 1, .shard = 1, .generation = 1 };
    for ([_]u128{ 19, 9 }, [_]u128{ 11, 10 }) |strategy, portfolio| {
        try applyHostCore(owner, null, .{ .strategy_activated = .{ .strategy_identity = strategy, .portfolio_identity = portfolio, .config_version = 1, .activation_identity = 1 } });
        try applyHostCore(owner, null, .{ .host_activated = .{ .strategy_identity = strategy, .config_version = 1, .activation_identity = 1, .session = session, .activation_barrier = 0, .state_digest = owner.shard.canonicalStateDigest() } });
    }
    try std.testing.expectEqual(@as(u128, 11), owner.shard.strategyAuthority(19).portfolio_identity);
    var configs: [2]host.Config = undefined;
    var gateways: [2]host.Gateway = undefined;
    for ([_]u128{ 9, 19 }, 0..) |strategy, i| {
        configs[i] = .{ .schema_registry = 10, .decision_domain = 1, .session = session, .authorization = .{ .strategy_identity = strategy, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 } };
        gateways[i] = try host.Gateway.init(configs[i], &.{host.Subscription.of(strategy, &.{.timer})});
    }
    try applyHostCore(owner, null, .{ .primary_lease_granted = .{ .fencing_token = 1 } });
    const cursor = owner.shard.authoritativeBarrier();
    var storage: [256]u8 = undefined;
    for (&gateways, configs, [_]u128{ 10, 11 }) |*gateway, config, portfolio| {
        var batch_storage: [256]u8 = undefined;
        _ = try gateway.encodeBatch(&batch_storage, 1, cursor, cursor, 100, &.{.{ .event_type = .timer, .shard_sequence = cursor, .source_time_ns = 100, .receive_time_ns = 100, .monotonic_time_ns = 100, .wall_time_utc_ns = 100, .payload = &.{} }});
        try gateway.recordPublished(1, cursor, 100);
        try gateway.activate(&owner.shard, &owner.decision_journal);
        const frame = try host.encodeOutputOrderFrame(&storage, config, 1, cursor, 1, .{ .portfolio_identity = portfolio, .exchange_account_identity = 20, .instrument_identity = 101, .quantity = 1, .limit_price_micros = 1 });
        try std.testing.expect(gateway.ingest(frame, 101) == .accepted);
    }
    // A frame claiming B's strategy with A's portfolio must fail at the Gateway seam.
    const wrong = try host.encodeOutputOrderFrame(&storage, configs[1], 1, cursor, 2, .{ .portfolio_identity = 10, .exchange_account_identity = 20, .instrument_identity = 101, .quantity = 1, .limit_price_micros = 1 });
    try std.testing.expect(gateways[1].ingest(wrong, 101) == .rejected);
    try applyHostCore(owner, null, .{ .host_activation_revoked = .{ .strategy_identity = 9, .activation_identity = 1, .reason = .fault } });
    try std.testing.expectError(error.HostNotActivated, owner.shard.appliedHostActivationForStrategy(&owner.decision_journal, 9));
    _ = try owner.shard.appliedHostActivationForStrategy(&owner.decision_journal, 19);
    const a_after = try host.encodeOutputOrderFrame(&storage, configs[0], 1, cursor, 2, .{ .portfolio_identity = 10, .exchange_account_identity = 20, .instrument_identity = 101, .quantity = 1, .limit_price_micros = 1 });
    try std.testing.expect(gateways[0].ingest(a_after, 101) == .rejected);
    const b_after = try host.encodeOutputOrderFrame(&storage, configs[1], 1, cursor, 2, .{ .portfolio_identity = 11, .exchange_account_identity = 20, .instrument_identity = 101, .quantity = 1, .limit_price_micros = 1 });
    try std.testing.expect(gateways[1].ingest(b_after, 101) == .accepted);

    try applyHostCore(owner, null, .{ .host_activated = .{ .strategy_identity = 9, .config_version = 1, .activation_identity = 2, .session = session, .activation_barrier = 0, .state_digest = owner.shard.canonicalStateDigest() } });
    _ = try owner.shard.appliedHostActivationForStrategy(&owner.decision_journal, 9);
    try applyHostCore(owner, null, .{ .host_activation_revoked = .{ .strategy_identity = 19, .activation_identity = 1, .reason = .fault, .session = session } });
    try std.testing.expectError(error.HostNotActivated, owner.shard.appliedHostActivationForStrategy(&owner.decision_journal, 9));
    try std.testing.expectError(error.HostNotActivated, owner.shard.appliedHostActivationForStrategy(&owner.decision_journal, 19));
    try owner.sealBootstrap();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqual(@as(u128, 11), recovered.shard.strategyAuthority(19).portfolio_identity);
    try std.testing.expectError(error.HostNotActivated, recovered.shard.appliedHostActivationForStrategy(&recovered.decision_journal, 9));
    try std.testing.expectError(error.HostNotActivated, recovered.shard.appliedHostActivationForStrategy(&recovered.decision_journal, 19));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try std.testing.expectError(error.InvalidStrategyActivation, applyHostCore(owner, null, .{ .strategy_activated = .{ .strategy_identity = 29, .portfolio_identity = 11, .config_version = 1, .activation_identity = 1 } }));
}

fn applyHostCore(owner: *demo.Owner, account: ?u128, payload: trading.CorePayload) !void {
    _ = try owner.apply(fixture.atGroup(10, .{ .identity = owner.shard.authoritativeBarrier() + 1, .account_scope = account, .payload = payload }));
}

test "04 physical capability configuration is independent of portfolio strategy versions" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try initializeEconomicsOwner(owner);
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 2, .activation_identity = 1 } });
    var profile: @import("../../../trading/trading_shard_event.zig").CapabilityProfileActivation = .{
        .exchange_account = 20,
        .instrument = 101,
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
    };
    try applyHostCore(owner, 20, .{ .capability_profile_activation = profile });
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 10, .strategy_identity = 9, .config_version = 1, .activation_identity = 1 } });
    profile.version = 2;
    profile.config_version = 3;
    try applyHostCore(owner, 20, .{ .capability_profile_activation = profile });
    try std.testing.expectEqual(@as(u64, 3), owner.shard.registryInstrument(101).?.capability.?.config_version);
    try std.testing.expectEqual(@as(u64, 1), owner.shard.strategyAuthority(9).strategy_config_version);
    try std.testing.expectEqual(@as(u64, 2), owner.shard.strategyAuthority(19).strategy_config_version);
    try owner.sealBootstrap();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    profile.version = 3;
    profile.config_version = 0;
    try std.testing.expectError(error.InvalidCapabilityProfile, applyHostCore(owner, 20, .{ .capability_profile_activation = profile }));
}

test "04 global control closure revokes every portfolio Host activation" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try cycleConfiguration();
    try existing.initializePythonOwnerForConfiguration(owner, &manifest);
    try applyHostCore(owner, 20, .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } });
    try applyHostCore(owner, 20, .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 100 } });
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } });
    const session: @import("../../../strategy/strategy_host_ipc.zig").Session = .{ .fencing = 1, .shard = 1, .generation = 1 };
    for ([_]u128{ 9, 19 }) |strategy| {
        try applyHostCore(owner, null, .{ .host_activated = .{ .strategy_identity = strategy, .config_version = 1, .activation_identity = 1, .session = session, .activation_barrier = 0, .state_digest = owner.shard.canonicalStateDigest() } });
        _ = try owner.shard.appliedHostActivationForStrategy(&owner.decision_journal, strategy);
    }
    try applyHostCore(owner, null, .{ .control_command = .{ .command_identity = 9001, .content_hash = 9001, .target_identity = 1, .expected_version = owner.shard.operational_state.version, .expires_at = std.math.maxInt(u64), .kind = .stop_keep_positions } });
    for ([_]u128{ 9, 19 }) |strategy| {
        try std.testing.expectError(error.HostNotActivated, owner.shard.appliedHostActivationForStrategy(&owner.decision_journal, strategy));
        try std.testing.expectEqual(@as(u128, 2), try owner.shard.nextHostActivationIdentityForStrategy(strategy));
    }
    try applyHostCore(owner, null, .{ .control_command = .{ .command_identity = 9002, .content_hash = 9002, .target_identity = 1, .expected_version = owner.shard.operational_state.version, .expires_at = std.math.maxInt(u64), .kind = .start_recovery } });
    try applyHostCore(owner, null, .recovery_completed);
    try applyHostCore(owner, null, .{ .control_command = .{ .command_identity = 9003, .content_hash = 9003, .target_identity = 1, .expected_version = owner.shard.operational_state.version, .expires_at = std.math.maxInt(u64), .kind = .enable_trading } });
    for ([_]u128{ 9, 19 }) |strategy|
        try std.testing.expectError(error.HostNotActivated, owner.shard.appliedHostActivationForStrategy(&owner.decision_journal, strategy));
    try owner.checkpoint();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    for ([_]u128{ 9, 19 }) |strategy|
        try std.testing.expectError(error.HostNotActivated, recovered.shard.appliedHostActivationForStrategy(&recovered.decision_journal, strategy));
}

test "04 lifecycle progress preserves every funded portfolio when flat" {
    try exerciseLifecycleProgress(false);
}

test "04 startup lets portfolio B submit a complete Host group before the primary strategy exists" {
    try exerciseInitialHostAuthorization(false);
}

test "04 startup denies a later strategy implicit capability authorization" {
    try exerciseInitialHostAuthorization(true);
}

test "04 startup activates a strategy funded only in a secondary account" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try cycleConfiguration();
    try existing.initializePythonOwnerForConfiguration(owner, &manifest);
    try applyHostCore(owner, 30, .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } });
    try applyHostCore(owner, 30, .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 100 } });
    try std.testing.expect(owner.shard.accountState(20).?.economic_projection.portfolioLayer(11) == null);
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } });
    try std.testing.expect(owner.shard.strategyAuthority(19).strategy_active);
    try std.testing.expectEqual(@as(u128, 11), owner.shard.strategyAuthority(19).portfolio_identity);
    try std.testing.expect(owner.shard.accountState(30).?.economic_projection.portfolioLayer(11).?.funded);
    try owner.checkpoint();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
}

fn exerciseInitialHostAuthorization(primary_started: bool) !void {
    const host = @import("../../../strategy/strategy_host_gateway.zig");
    const gateway_fixture = @import("shared_gateway_venue_acceptance.zig");
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 9101 });
    try @import("shared_venue_delivery_acceptance.zig").initializeMultiPortfolio(owner, 0);
    var baseline: trading.canonical.AccountBootstrapSnapshot = .{ .identity = 90, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 999, .source_sequence = 1, .balance_count = 1, .position_count = 0, .margin_count = 8 };
    const zero: trading.canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
    const cash: trading.canonical.AssetAmount = .{ .asset = 1, .atoms = 100 };
    baseline.balances[0] = .{ .asset = 1, .total = cash, .available = cash, .held = zero, .cash_balance = cash, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
    for (baseline.margins[0..8], 1..) |*margin, instrument| margin.* = .{ .instrument = instrument, .amount = zero, .initial_margin = zero, .maintenance_margin = zero, .isolated_equity = zero };
    var record = fixture.canonicalAt(39, 1, .{ .account_bootstrap_snapshot = baseline });
    record.venue.envelope.identity.stream = 999;
    record.venue.envelope.source_stream = 999;
    _ = try owner.apply(record);
    if (primary_started) try gateway_fixture.prepareTrading(owner, 0, 1);
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 15, .strategy_identity = 5, .config_version = 2, .activation_identity = 1 } });
    if (!primary_started) {
        const controls = [_]trading.CorePayload{
            .{ .primary_lease_granted = .{ .fencing_token = 1 } },
            .{ .risk_lease_granted = .{ .amount_atoms = 25, .allocation = .{ .configuration_digest = owner.shard.deployment.header.?.expected_digest, .account = 2, .asset = 1, .domain = 1, .stream = 9101 } } },
            .{ .control_command = .{ .command_identity = 900, .content_hash = 900, .target_identity = 1, .expected_version = 0, .expires_at = std.math.maxInt(u64), .kind = .start_recovery } },
            .recovery_completed,
            .{ .control_command = .{ .command_identity = 901, .content_hash = 901, .target_identity = 1, .expected_version = 2, .expires_at = std.math.maxInt(u64), .kind = .enable_trading } },
        };
        for (controls) |payload| try applyHostCore(owner, if (payload == .risk_lease_granted) @as(?u128, 2) else null, payload);
        try gateway_fixture.prepareInstruments(owner, 0, 1);
    }
    const barrier = owner.shard.authoritativeBarrier();
    const config: host.Config = .{ .schema_registry = trading.schema_registry_identity, .decision_domain = 1, .session = .{ .fencing = 1, .shard = 1, .generation = 1 }, .authorization = .{ .strategy_identity = 5, .config_version = 2, .activation_identity = 1, .activation_barrier = barrier } };
    try applyHostCore(owner, null, .{ .host_activated = .{ .strategy_identity = 5, .config_version = 2, .activation_identity = 1, .session = config.session, .activation_barrier = barrier, .state_digest = owner.shard.canonicalStateDigest() } });
    try applyHostCore(owner, 2, .{ .mark_price = .{ .instrument = 1, .price_atoms = 10 } });
    const cursor = owner.shard.authoritativeBarrier();
    var gateway = try host.Gateway.init(config, &.{host.Subscription.of(5, &.{.timer})});
    var batch: [256]u8 = undefined;
    _ = try gateway.encodeBatch(&batch, 1, cursor, cursor, 100, &.{.{ .event_type = .timer, .shard_sequence = cursor, .source_time_ns = 100, .receive_time_ns = 100, .monotonic_time_ns = 100, .wall_time_utc_ns = 100, .payload = &.{} }});
    try gateway.recordPublished(1, cursor, 100);
    try gateway.activate(&owner.shard, &owner.decision_journal);
    try std.testing.expect(owner.shard.genesisReady());
    const orders = [_]host.OutputOrder{
        .{ .portfolio_identity = 15, .exchange_account_identity = 2, .instrument_identity = 1, .side = .buy, .quantity = 10000, .limit_price_micros = 10 },
        .{ .portfolio_identity = 15, .exchange_account_identity = 2, .instrument_identity = 5, .side = .sell, .quantity = 10000, .limit_price_micros = 10 },
    };
    var storage: [host.max_group_frame_len]u8 = undefined;
    const frame = try host.encodeOutputGroupFrame(&storage, config, 1, cursor, 1, &orders);
    const decision = gateway.ingest(frame, 101);
    try std.testing.expect(decision == .accepted_group);
    _ = try owner.apply(fixture.atGroup(45, .{ .identity = owner.shard.authoritativeBarrier() + 1, .payload = decision.corePayload() }));
    try std.testing.expectEqual(@as(u16, if (primary_started) 0 else 2), owner.shard.oms.order_count);
    try std.testing.expectEqual(primary_started, owner.shard.registryInstrument(1).?.trading_enabled);
    if (primary_started) {
        try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.authorization_closed, owner.shard.last_reject_reason);
        try applyHostCore(owner, 2, .{ .instrument_trading_authorization = .{ .strategy_identity = 1, .exchange_account = 2, .instrument = 1, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = false } });
        try std.testing.expect(!owner.shard.registryInstrument(1).?.trading_enabled);
        try std.testing.expectEqual(@as(u64, 1), owner.shard.registryInstrument(1).?.tradingAuthorization(5).version);
        try owner.checkpoint();
        for ([_]u128{ 1, 5 }) |instrument|
            try applyHostCore(owner, 2, .{ .instrument_trading_authorization = .{ .strategy_identity = 5, .exchange_account = 2, .instrument = instrument, .strategy_activation_identity = 1, .config_version = 2, .expected_version = 1, .enabled = true } });
        const next_cursor = owner.shard.authoritativeBarrier();
        _ = try gateway.encodeBatch(&batch, 2, cursor + 1, next_cursor, 102, &.{.{ .event_type = .timer, .shard_sequence = next_cursor, .source_time_ns = 102, .receive_time_ns = 102, .monotonic_time_ns = 102, .wall_time_utc_ns = 102, .payload = &.{} }});
        try gateway.recordPublished(2, next_cursor, 102);
        const retry = try host.encodeOutputGroupFrame(&storage, config, 2, next_cursor, 3, &orders);
        const accepted = gateway.ingest(retry, 103);
        try std.testing.expect(accepted == .accepted_group);
        _ = try owner.apply(fixture.atGroup(45, .{ .identity = owner.shard.authoritativeBarrier() + 1, .payload = accepted.corePayload() }));
        try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
    }
    try std.testing.expectEqual(primary_started, owner.shard.strategy_active);
    try owner.checkpoint();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    if (primary_started) {
        owner.shard.instrument_registry.getPtr(1).?.unscoped_trading_authorization = true;
        try owner.decision_journal.seal();
        const buffer = try std.testing.allocator.alloc(u8, durable.max_snapshot_bytes);
        defer std.testing.allocator.free(buffer);
        const damaged = try owner.shard.snapshot(&owner.decision_journal, owner.shard.authoritativeBarrier(), buffer);
        try std.testing.expectError(error.InvalidSnapshotState, trading.TradingShard.restoreSnapshotInto(&recovered.shard, damaged));
    }
}

test "04 lifecycle progress cannot complete DeRisk while only portfolio B has positions" {
    try exerciseLifecycleProgress(true);
}

fn exerciseLifecycleProgress(filled: bool) !void {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try cycleConfiguration();
    try existing.initializePythonOwnerForConfiguration(owner, &manifest);
    for ([_]u128{ 20, 30 }) |account| {
        try applyHostCore(owner, account, .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } });
        try applyHostCore(owner, account, .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 100 } });
    }
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } });
    if (filled) {
        for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument|
            try applyHostCore(owner, account, .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = account, .instrument = instrument, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = true } });
        var group = portfolioGroup(19, 11, 61001);
        for (group.members[0..2]) |*member| member.quantity = 1000;
        _ = try owner.apply(fixture.atGroup(50, .{ .identity = 61000, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
        for (0..2) |index| {
            const order = owner.shard.oms.orders[index];
            _ = try owner.apply(fixture.atGroup(51 + index * 2, .{ .identity = owner.shard.authoritativeBarrier() + 1, .account_scope = order.exchange_account, .payload = .{ .economic_fill = .{ .fill_id = 62001 + index, .order_id = order.id, .quantity = 1000, .price_ticks = 100 } } }));
            _ = try owner.apply(fixture.atGroup(52 + index * 2, .{ .identity = owner.shard.authoritativeBarrier() + 1, .account_scope = order.exchange_account, .payload = .{ .oms_execution_report = .{ .report_id = 63001 + index, .order_id = order.id, .revision = 1, .status = .filled, .cumulative_quantity = 1000, .remaining_quantity = 0 } } }));
        }
    }
    try owner.checkpoint();
    if (filled) try applyHostCore(owner, null, .{ .risk_warning = .{ .warning_identity = 64000, .target_identity = 1 } });
    try applyHostCore(owner, null, .{ .control_command = .{ .command_identity = 64001, .content_hash = 64001, .target_identity = 1, .expected_version = owner.shard.operational_state.version, .expires_at = std.math.maxInt(u64), .kind = if (filled) .de_risk else .trading_pause, .risk_warning_identity = if (filled) 64000 else 0 } });
    const progress: @import("../../../trading/operational.zig").LifecycleProgress = .{
        .operation_identity = 64001,
        .target_identity = 1,
        .open_orders_closed = true,
        .reconciliation_complete = true,
        .position_quantity = 0,
    };
    try applyHostCore(owner, null, .{ .lifecycle_progress = progress });
    try std.testing.expectEqual(if (filled) @import("../../../trading/operational.zig").OperationalMode.draining else .ready, owner.shard.operational_state.mode);
    for ([_]u128{ 20, 30 }, [_]i128{ 400, 600 }) |account, primary_cash| {
        const projection = &owner.shard.accountState(account).?.economic_projection;
        try std.testing.expectEqual(primary_cash, projection.portfolioLayer(10).?.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, 100), projection.portfolioLayer(11).?.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i64, 0), projection.portfolioLayer(10).?.swap.quantity);
    }
    if (filled) try std.testing.expectEqual(@as(u128, 64001), owner.shard.operational_state.active_operation_identity);
}

test "04 complete groups in two portfolios keep independent cycle ownership" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    const manifest = try cycleConfiguration();
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try existing.initializePythonOwnerForConfiguration(owner, &manifest);
    for ([_]u128{ 20, 30 }) |account| {
        try applyHostCore(owner, account, .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } });
        try applyHostCore(owner, account, .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 100 } });
    }
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } });
    // Disabling B's instrument must close B while A remains authorized.
    try applyHostCore(owner, 30, .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = 30, .instrument = 102, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = true } });
    try applyHostCore(owner, 20, .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = 20, .instrument = 101, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = false } });
    const disabled = portfolioGroup(19, 11, 9991);
    _ = try owner.apply(fixture.atGroup(49, .{ .identity = 19999, .payload = .{ .oms_intent_group = disabled } }));
    try std.testing.expectEqual(@as(u16, 0), owner.shard.oms.order_count);
    for ([_]u128{ 9, 19 }, [_]u128{ 10, 11 }, 0..) |strategy, portfolio, index| {
        if (index == 1) try applyHostCore(owner, 20, .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = 20, .instrument = 101, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 2, .enabled = true } });
        const group = portfolioGroup(strategy, portfolio, 10001 + index * 2);
        _ = try owner.apply(fixture.atGroup(50, .{ .identity = 20001 + index, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@as(u16, @intCast(2 * (index + 1))), owner.shard.oms.order_count);
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), owner.shard.cycles.count);
    }
    const conflicting = portfolioGroup(9, 10, 10005);
    _ = try owner.apply(fixture.atGroup(51, .{ .identity = 20003, .payload = .{ .oms_intent_group = conflicting } }));
    try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
    try std.testing.expectEqual(@as(u8, 2), owner.shard.cycles.count);
    for (owner.shard.oms.orders[0..4], 0..) |order, index| {
        try std.testing.expectEqual(@as(u128, if (index < 2) 10 else 11), order.portfolio);
        try std.testing.expectEqual(order.portfolio, owner.shard.oms.command_history[index].authority.virtual_portfolio);
    }
    _ = try owner.apply(fixture.atGroup(52, .{ .identity = 21000, .account_scope = 20, .payload = .{ .oms_execution_report = .{ .report_id = 1, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10000 } } }));
    const original = owner.shard.oms.orderById(1).?;
    const history_count = owner.shard.oms.command_history_count;
    const reservation = try owner.shard.oms.reservationsForPortfolio(20, 10, 1);
    try owner.checkpoint();
    try std.testing.expectEqualDeep(original, owner.shard.oms.orderById(1).?);
    try std.testing.expectEqual(history_count, owner.shard.oms.command_history_count);
    try std.testing.expectEqualDeep(reservation, try owner.shard.oms.reservationsForPortfolio(20, 10, 1));
    for (0..3) |index| {
        var mutation: trading.oms.IntentGroup = .{ .first_intent_sequence = 30001 + index, .count = 1 };
        mutation.members[0] = .{ .intent_sequence = mutation.first_intent_sequence, .strategy_instance = 19, .portfolio = 11, .exchange_account = 20, .operation = if (index == 1) .cancel else .amend, .instrument = 101, .target_order_id = 1, .expected_revision = 1, .quantity = 10000, .native_amend = index != 2, .allow_cancel_confirm_create = index == 2, .limit_price = .{ .instrument = 101, .rules_version = 1, .ticks = 100 } };
        _ = try owner.apply(fixture.atGroup(53 + index, .{ .identity = 21001 + index, .payload = .{ .oms_intent_group = mutation } }));
        try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.invalid_scope, owner.shard.last_reject_reason);
        try std.testing.expectEqualDeep(original, owner.shard.oms.orderById(1).?);
        try std.testing.expectEqual(history_count, owner.shard.oms.command_history_count);
        try std.testing.expectEqualDeep(reservation, try owner.shard.oms.reservationsForPortfolio(20, 10, 1));
    }
    try owner.checkpoint();
}

fn portfolioGroup(strategy: u128, portfolio: u128, sequence: u64) trading.oms.IntentGroup {
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = sequence, .count = 2 };
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, 0..) |account, instrument, index| {
        group.members[index] = .{ .intent_sequence = sequence + index, .strategy_instance = strategy, .portfolio = portfolio, .exchange_account = account, .operation = .place, .instrument = instrument, .side = if ((portfolio == 10) == (index == 0)) .buy else .sell, .quantity = 10000, .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 } };
    }
    return group;
}

test "04 portfolio B closes its cycle while portfolio A keeps positions on both accounts" {
    try exercisePortfolioCycleClosure(.perpetual);
}

test "04 portfolio B residual backs a new cycle while portfolio A keeps spot inventory" {
    try exercisePortfolioCycleClosure(.residual);
}

test "04 a portfolio reduction cannot increase an account with unknown dispatch" {
    try exercisePortfolioCycleClosure(.unknown_dispatch);
}

test "04 manual freeze selects portfolio B residual and its native inventory" {
    try exercisePortfolioCycleClosure(.manual_freeze);
}

test "04 canonical spot fills select portfolio B position before residual inventory" {
    try exercisePortfolioCycleClosure(.unequal_spot);
}

fn exercisePortfolioCycleClosure(comptime scenario: enum { perpetual, residual, unknown_dispatch, manual_freeze, unequal_spot }) !void {
    const spot = scenario == .residual or scenario == .manual_freeze or scenario == .unequal_spot;
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try cycleConfiguration();
    if (spot) try existing.initializeSpotOwnerForConfiguration(owner, &manifest) else try existing.initializePythonOwnerForConfiguration(owner, &manifest);
    for ([_]u128{ 20, 30 }) |account| {
        try applyHostCore(owner, account, .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } });
        try applyHostCore(owner, account, .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 100 } });
    }
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } });
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| try applyHostCore(owner, account, .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = account, .instrument = instrument, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = true } });
    for (0..3) |round| {
        var group = portfolioGroup(if (round == 0) 9 else 19, if (round == 0) 10 else 11, 33001 + round * 2);
        for (group.members[0..2]) |*member| {
            member.quantity = if (scenario == .unequal_spot and round != 0) 2000 else 1000;
            if (spot) {
                member.side = .buy;
                member.limit_price.ticks = 10;
            }
            if (round == 2) {
                member.side = if (member.side == .buy) .sell else .buy;
                member.portfolio_reduce_only = true;
            }
        }
        if (scenario == .unknown_dispatch and round == 2) {
            var other = portfolioGroup(9, 10, 35001);
            for (other.members[0..2]) |*member| {
                member.side = if (member.side == .buy) .sell else .buy;
                member.quantity = 1;
                member.portfolio_reduce_only = true;
            }
            _ = try owner.apply(fixture.atGroup(54, .{ .identity = 45001, .payload = .{ .oms_intent_group = other } }));
            try std.testing.expectEqual(@as(u16, 6), owner.shard.oms.order_count);
            var dispatch: trading.oms.DispatchBatch = .{ .count = 1 };
            dispatch.items[0] = .{ .command_id = owner.shard.oms.command_history[4].command_id, .state = .unknown };
            try applyHostCore(owner, 20, .{ .oms_dispatch_batch = dispatch });
            try std.testing.expect(owner.shard.oms.blocksNewSend());
            try std.testing.expect(owner.shard.operational_state.effectiveTradingAuthority());
            _ = try owner.apply(fixture.atGroup(54, .{ .identity = 45002, .payload = .{ .oms_intent_group = group } }));
            try std.testing.expectEqual(@as(u16, 6), owner.shard.oms.order_count);
            try std.testing.expectEqual(@as(u16, 6), owner.shard.oms.command_history_count);
            try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.authorization_closed, owner.shard.last_reject_reason);
            return;
        }
        if (round == 2 and !spot) {
            var gate: @import("../../../trading/operational.zig").SafetyGateChange = .{ .gate_identity = 45001, .target_identity = 1, .kind = .self_recovering, .reason = .risk_lease, .open = false };
            try applyHostCore(owner, null, .{ .lease_gate_change = gate });
            _ = try owner.apply(fixture.atGroup(54, .{ .identity = 43999, .payload = .{ .oms_intent_group = group } }));
            try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
            try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.authorization_closed, owner.shard.last_reject_reason);
            gate.open = true;
            gate.continuity_proven = true;
            try applyHostCore(owner, null, .{ .lease_gate_change = gate });
            group.first_intent_sequence += 2;
            for (group.members[0..2]) |*member| member.intent_sequence += 2;
            var lease: @import("../../../trading/trading_shard_event.zig").RiskLease = .{
                .version = 2,
                .amount_atoms = 60,
                .valid_through_barrier = owner.shard.authoritativeBarrier(),
                .allocation = .{ .configuration_digest = manifest.header.?.expected_digest, .account = 20, .asset = 1, .domain = 1, .stream = 91 },
            };
            try applyHostCore(owner, 20, .{ .risk_lease_granted = lease });
            _ = try owner.apply(fixture.atGroup(54, .{ .identity = 43998, .payload = .{ .oms_intent_group = group } }));
            try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
            try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.authorization_closed, owner.shard.last_reject_reason);
            lease.version = 3;
            lease.valid_through_barrier = std.math.maxInt(u64);
            try applyHostCore(owner, 20, .{ .risk_lease_granted = lease });
            group.first_intent_sequence += 2;
            for (group.members[0..2]) |*member| member.intent_sequence += 2;
        }
        _ = try owner.apply(fixture.atGroup(50 + round * 2, .{ .identity = 43001 + round, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@as(u16, @intCast(2 * (round + 1))), owner.shard.oms.order_count);
        for (0..2) |index| {
            const order = owner.shard.oms.orders[round * 2 + index];
            if (round == 2) {
                try std.testing.expect(order.portfolio_reduce_only);
                try std.testing.expect(!order.venue_reduce_only);
            }
            const venue: u64 = if (order.exchange_account == 20) 1 else 21;
            const payloads = [_]trading.canonical.Payload{
                .{ .fill = .{
                    .identity = order.id,
                    .order = order.id,
                    .client_order_id = order.client_order_id,
                    .venue_order = try trading.canonical.VenueOrderRef.init(venue, if (round == 0) "vp-a-cycle-order" else if (round == 1) "vp-b-cycle-order" else "vp-b-close-order"),
                    .venue_trade = try trading.canonical.VenueTradeRef.init(venue, if (round == 0) "vp-a-open" else if (round == 1) "vp-b-open" else "vp-b-close"),
                    .instrument = order.instrument,
                    .exchange_account = order.exchange_account,
                    .side = if (order.side == .buy) .buy else .sell,
                    .quantity = .{ .instrument = order.instrument, .rules_version = 1, .lots = order.quantity },
                    .price = .{ .instrument = order.instrument, .rules_version = 1, .ticks = if (spot) 10 else 100 },
                    .fee = .{ .asset = 1, .atoms = 0 },
                    .liquidity = .taker,
                    .rebate = if (spot and round == 2) .{ .asset = 0x425443, .atoms = 1 } else null,
                    .venue_fill_time_utc_ns = fixture.atGroup(51 + round * 2, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
                } },
                .{ .execution_report = .{
                    .identity = 44001 + order.id,
                    .order = order.id,
                    .client_order_id = order.client_order_id,
                    .instrument = order.instrument,
                    .exchange_account = order.exchange_account,
                    .revision = 1,
                    .status = .filled,
                    .cumulative_quantity = .{ .instrument = order.instrument, .rules_version = 1, .lots = order.quantity },
                    .remaining_quantity = .{ .instrument = order.instrument, .rules_version = 1, .lots = 0 },
                } },
            };
            for (payloads, 0..) |payload, offset| {
                var event = fixture.canonicalAt(51 + round * 2, 2 + round * 2 + offset, payload);
                event.venue.envelope.exchange_account = order.exchange_account;
                event.venue.envelope.venue = venue;
                _ = try owner.apply(event);
            }
        }
    }
    const gateway = try std.testing.allocator.create(@import("../../../execution/execution_gateway.zig").Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    for ([_]u128{ 20, 30 }) |account| try existing.reconcileDomainAccount(owner, account, gateway);
    const close_time = fixture.atGroup(61, .{ .identity = 0, .payload = .recovery_completed }).core.source_time;
    if (spot) try applyHostCore(owner, null, .{ .spot_residual_rule = .{ .asset = 0x425443, .asset_version = 1, .version = 1, .max_atoms = 1, .max_total_atoms = 2 } });
    const proof = if (spot) try owner.shard.qualifyCycleResidualClosure(19, 33003, close_time) else try owner.shard.qualifyCycleClosure(19, 33003);
    _ = try owner.apply(fixture.atGroup(61, .{ .identity = owner.shard.authoritativeBarrier() + 1, .payload = .{ .cycle_closed = proof } }));
    try std.testing.expect(owner.shard.cycles.completed(19, 33003) != null);
    try std.testing.expect(owner.shard.cycles.find(9, 33001) != null);
    try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
    for ([_]u128{ 20, 30 }, [_]i64{ 1000, -1000 }) |account, quantity| {
        const projection = &owner.shard.accountState(account).?.economic_projection;
        if (spot) {
            try std.testing.expectEqual(@as(i64, 1000), projection.portfolioLayer(10).?.spot.quantity);
            try std.testing.expectEqual(@as(i64, 0), projection.portfolioLayer(11).?.spot.quantity);
            try std.testing.expectEqual(@as(i128, 10_000_000), projection.portfolioLayer(10).?.spotInventoryAtoms(0x425443));
            try std.testing.expectEqual(@as(i128, 1), projection.portfolioLayer(11).?.spotInventoryAtoms(0x425443));
            try std.testing.expectEqual(@as(i128, 10_000_001), projection.exchange.spotInventoryAtoms(0x425443));
        } else {
            try std.testing.expectEqual(quantity, projection.portfolioLayer(10).?.swap.quantity);
            try std.testing.expectEqual(@as(i64, 0), projection.portfolioLayer(11).?.swap.quantity);
            try std.testing.expectEqual(quantity, projection.exchange.swap.quantity);
        }
    }
    try owner.checkpoint();
    if (spot) {
        var next = portfolioGroup(19, 11, 33009);
        for (next.members[0..2]) |*member| {
            member.side = .buy;
            member.quantity = 1000;
            member.limit_price.ticks = 10;
        }
        _ = try owner.apply(fixture.atGroup(62, .{ .identity = owner.shard.authoritativeBarrier() + 1, .payload = .{ .oms_intent_group = next } }));
        try std.testing.expectEqual(@as(u16, 8), owner.shard.oms.order_count);
        for ([_]u128{ 20, 30 }) |account| {
            try std.testing.expectEqual(@as(i128, 0), try owner.shard.cycles.reservedAtoms(account, 11, 0x425443));
            try std.testing.expectEqual(@as(i128, 1), try owner.shard.cycles.outstandingAtoms(account, 11, 0x425443));
        }
        if (scenario == .manual_freeze) {
            const live = owner.shard.residualState(19, 33003, 0).?;
            const freeze = fixture.atGroup(63, .{ .identity = 47001, .payload = .{ .control_command = .{
                .command_identity = 47001,
                .content_hash = 47001,
                .target_identity = owner.shard.operational_state.target_identity,
                .expected_version = owner.shard.operational_state.version,
                .expires_at = std.math.maxInt(u64),
                .kind = .freeze_residual,
                .residual = .{ .strategy = 19, .first_sequence = 33003, .member = 0, .expected_version = live.version, .original_fact = live.original_fact, .atoms = 1 },
            } } });
            _ = try owner.apply(freeze);
            try std.testing.expectEqual(@as(i128, 1), try owner.shard.cycles.reservedAtoms(20, 11, 0x425443));
            try std.testing.expectEqual(@as(i128, 0), try owner.shard.cycles.reservedAtoms(30, 11, 0x425443));
            try std.testing.expectEqual(@as(i128, 0), try owner.shard.cycles.reservedAtoms(20, 10, 0x425443));
            const before = owner.shard.canonicalStateDigest();
            _ = try owner.apply(freeze);
            try std.testing.expectEqualSlices(u8, &before, &owner.shard.canonicalStateDigest());
            try owner.checkpoint();
        }
    } else {
        try std.testing.expectError(error.FillArchivePinned, owner.archiveFillHistoryForAccount(20, 1, gateway));
        for ([_]u128{ 20, 30 }, [_]u64{ 3, 4 }) |account, fill_id| {
            const before = owner.shard.accountState(account).?.economic_projection;
            _ = try owner.archiveFillHistoryForAccount(account, fill_id, gateway);
            const after = owner.shard.accountState(account).?.economic_projection;
            try std.testing.expect(std.meta.eql(before.portfolioLayer(10).?.*, after.portfolioLayer(10).?.*));
            try std.testing.expect(std.meta.eql(before.portfolioLayer(11).?.*, after.portfolioLayer(11).?.*));
            try std.testing.expect(std.meta.eql(before.exchange, after.exchange));
            try std.testing.expectEqual(before.archived_fill_count + 1, after.archived_fill_count);
        }
        try std.testing.expect(owner.shard.cycles.find(9, 33001) != null);
        try owner.checkpoint();
        const recovered = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(recovered);
        try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
        try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        try expectImmutableFillSourceSnapshot(owner, 11, 19);
    }
}

pub fn cycleConfiguration() !allocation.Configuration {
    const original = try existing.configurationRows();
    var rows: [19]allocation.Input = undefined;
    @memcpy(rows[0..13], original[0..13]);
    rows[0].begin.portfolio_count = 1;
    rows[0].begin.portfolio_slice_count = 4;
    rows[13] = .{ .portfolio = .{ .identity = 11, .domain = 1 } };
    rows[14] = .{ .portfolio_slice = .{ .account = 20, .asset = 1, .portfolio = 10, .atoms = 40 } };
    rows[15] = .{ .portfolio_slice = .{ .account = 20, .asset = 1, .portfolio = 11, .atoms = 20 } };
    rows[16] = .{ .portfolio_slice = .{ .account = 30, .asset = 1, .portfolio = 10, .atoms = 20 } };
    rows[17] = .{ .portfolio_slice = .{ .account = 30, .asset = 1, .portfolio = 11, .atoms = 20 } };
    rows[18] = .seal;
    var result: allocation.Configuration = .{};
    for (rows[0..18]) |row| try result.apply(row);
    result.header.?.expected_digest = result.contentDigest();
    try result.apply(.seal);
    return result;
}

test "04 spot sells reserve each portfolio inventory and the physical account independently" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try cycleConfiguration();
    try existing.initializeSpotOwnerForConfiguration(owner, &manifest);
    for ([_]u128{ 20, 30 }) |account| {
        try applyHostCore(owner, account, .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } });
        try applyHostCore(owner, account, .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 100 } });
    }
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } });
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| try applyHostCore(owner, account, .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = account, .instrument = instrument, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = true } });
    for (0..4) |index| {
        const portfolio: u128 = if (index % 2 == 0) 10 else 11;
        var group = portfolioGroup(if (portfolio == 10) 9 else 19, portfolio, 30001 + index * 2);
        for (group.members[0..2]) |*member| {
            member.quantity = 1000;
            member.limit_price.ticks = 10;
            member.side = if (index < 2) .buy else .sell;
            member.portfolio_reduce_only = index >= 2;
        }
        _ = try owner.apply(fixture.atGroup(50 + index, .{ .identity = 40001 + index, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@as(u16, @intCast(2 * (index + 1))), owner.shard.oms.order_count);
        if (index < 2) for (0..2) |member| {
            const order = owner.shard.oms.orders[index * 2 + member];
            const venue: u64 = if (order.exchange_account == 20) 1 else 21;
            var fill = fixture.canonicalAt(50 + index, 2 + index, .{ .fill = .{
                .identity = 50001 + order.id,
                .order = order.id,
                .client_order_id = order.client_order_id,
                .instrument = order.instrument,
                .exchange_account = order.exchange_account,
                .venue_order = try trading.canonical.VenueOrderRef.init(venue, if (index == 0) "vp-a-spot-order" else "vp-b-spot-order"),
                .venue_trade = try trading.canonical.VenueTradeRef.init(venue, if (index == 0) "vp-a-buy" else "vp-b-buy"),
                .side = .buy,
                .quantity = .{ .instrument = order.instrument, .rules_version = 1, .lots = 1000 },
                .price = .{ .instrument = order.instrument, .rules_version = 1, .ticks = 10 },
                .fee = .{ .asset = 1, .atoms = 0 },
                .venue_fill_time_utc_ns = fixture.atGroup(50 + index, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
                .liquidity = .taker,
            } });
            fill.venue.envelope.exchange_account = order.exchange_account;
            fill.venue.envelope.venue = venue;
            _ = try owner.apply(fill);
        };
    }
}

test "04 another portfolio reservation does not consume a small portfolios cash buffer" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try cycleConfiguration();
    try existing.initializePythonOwnerForConfiguration(owner, &manifest);
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| {
        try applyHostCore(owner, account, .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } });
        try applyHostCore(owner, account, .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 7 } });
        try applyHostCore(owner, account, .{ .margin_rules_activated = .{ .version = 2, .instrument = instrument, .internal_initial_margin_ppm = 1_000_000, .fee_ppm = 0 } });
    }
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } });
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| try applyHostCore(owner, account, .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = account, .instrument = instrument, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = true } });
    for ([_]u128{ 10, 11 }, [_]i64{ 2000, 200 }, 0..) |portfolio, quantity, index| {
        var group = portfolioGroup(if (portfolio == 10) 9 else 19, portfolio, 32001 + index * 2);
        group.members[0].quantity = quantity;
        group.members[1].quantity = if (index == 0) 1000 else 200;
        _ = try owner.apply(fixture.atGroup(50 + index, .{ .identity = 42001 + index, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@as(u16, @intCast(2 * (index + 1))), owner.shard.oms.order_count);
    }
    try std.testing.expectEqual(@as(i128, 20), (try owner.shard.oms.reservationsForPortfolio(20, 10, 1)).atoms);
    try std.testing.expectEqual(@as(i128, 2), (try owner.shard.oms.reservationsForPortfolio(20, 11, 1)).atoms);
    try std.testing.expectEqual(@as(i128, 7), owner.shard.accountState(20).?.economic_projection.portfolioLayer(11).?.usdt_balance_atoms);
}

test "04 Core funding preserves a unique portfolio and suspends an unactivated multi portfolio domain" {
    for ([_]bool{ true, false }) |multiple| {
        const memory = try std.testing.allocator.create(durable.MemoryAdapter);
        defer std.testing.allocator.destroy(memory);
        memory.* = .init();
        defer memory.deinit();
        const owner = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(owner);
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
        var manifest: allocation.Configuration = .{};
        if (multiple) {
            manifest = try cycleConfiguration();
        } else for (try existing.configurationRows()) |row| try manifest.apply(row);
        try existing.initializePythonOwnerForConfiguration(owner, &manifest);
        var group = portfolioGroup(9, 10, 34001);
        for (group.members[0..2]) |*member| member.quantity = 1000;
        _ = try owner.apply(fixture.atGroup(50, .{ .identity = 46001, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
        const order = owner.shard.oms.orders[0];
        var fill = fixture.canonicalAt(51, 2, .{ .fill = .{
            .identity = 46002,
            .order = order.id,
            .client_order_id = order.client_order_id,
            .instrument = 101,
            .exchange_account = 20,
            .venue_order = try trading.canonical.VenueOrderRef.init(1, "core-funding-order"),
            .venue_trade = try trading.canonical.VenueTradeRef.init(1, "core-funding-fill"),
            .side = .buy,
            .quantity = .{ .instrument = 101, .rules_version = 1, .lots = 1000 },
            .price = .{ .instrument = 101, .rules_version = 1, .ticks = 100 },
            .fee = .{ .asset = 1, .atoms = 0 },
            .venue_fill_time_utc_ns = fixture.atGroup(51, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
            .liquidity = .taker,
        } });
        fill.venue.envelope.exchange_account = 20;
        _ = try owner.apply(fill);
        const funding = fixture.atGroup(52, .{ .identity = 46003, .account_scope = 20, .payload = .{ .funding_settlement = .{ .settlement_id = 46003, .amount_atoms = 5, .instrument = 101 } } });
        _ = try owner.apply(funding);
        const projection = &owner.shard.accountState(20).?.economic_projection;
        try std.testing.expectEqual(@as(u8, 0), projection.extra_portfolio_count);
        try std.testing.expectEqual(@as(i128, if (multiple) 400 else 405), projection.portfolioLayer(10).?.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, 1005), projection.exchange.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, if (multiple) 5 else 0), projection.suspense_usdt_atoms);
        const before = owner.shard.canonicalStateDigest();
        _ = try owner.apply(funding);
        try std.testing.expectEqualSlices(u8, &before, &owner.shard.canonicalStateDigest());
        if (multiple) {
            try owner.decision_journal.seal();
            const bytes = try std.testing.allocator.alloc(u8, 32 * 1024 * 1024);
            defer std.testing.allocator.free(bytes);
            const restored = try std.testing.allocator.create(trading.TradingShard);
            defer std.testing.allocator.destroy(restored);
            const valid = try owner.shard.snapshot(&owner.decision_journal, owner.decision_journal.last_sequence, bytes);
            _ = try trading.TradingShard.restoreSnapshotInto(restored, valid);
            const source = &owner.shard.economic_projection.applied_fundings[0].source;
            const original = source.*;
            defer source.* = original;
            source.portfolio = 10;
            const damaged = try owner.shard.snapshot(&owner.decision_journal, owner.decision_journal.last_sequence, bytes);
            try std.testing.expectError(error.InvalidSnapshotState, trading.TradingShard.restoreSnapshotInto(restored, damaged));
        }
    }
}

test "04 portfolio risk slices remain independent beneath one shared Domain lease" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    const manifest = try cycleConfiguration();
    try existing.initializePythonOwnerForConfiguration(owner, &manifest);
    for ([_]u128{ 20, 30 }) |account| {
        try applyHostCore(owner, account, .{ .virtual_portfolio_activated = .{ .portfolio_identity = 11 } });
        try applyHostCore(owner, account, .{ .portfolio_transfer = .{ .portfolio_identity = 11, .amount_atoms = 200 } });
    }
    try applyHostCore(owner, null, .{ .strategy_activated = .{ .portfolio_identity = 11, .strategy_identity = 19, .config_version = 1, .activation_identity = 1 } });
    for ([_]u128{ 101, 102, 103, 104 }) |instrument| try applyHostCore(owner, if (instrument % 2 == 1) 20 else 30, .{ .instrument_trading_authorization = .{ .strategy_identity = 19, .exchange_account = if (instrument % 2 == 1) 20 else 30, .instrument = instrument, .strategy_activation_identity = 1, .config_version = 1, .expected_version = 1, .enabled = true } });
    for ([_]u128{ 101, 102, 103, 104 }) |instrument| try applyHostCore(owner, if (instrument % 2 == 1) 20 else 30, .{ .margin_rules_activated = .{ .version = 2, .instrument = instrument, .internal_initial_margin_ppm = 1_000_000, .fee_ppm = 0 } });
    for (0..3) |index| {
        const portfolio: u128 = if (index == 0) 10 else 11;
        var group = portfolioGroup(if (portfolio == 10) 9 else 19, portfolio, 31001 + index * 2);
        for (group.members[0..2]) |*member| {
            member.quantity = if (index < 2) 1000 else 2000;
            if (index == 2) {
                member.instrument += 2;
                member.limit_price.instrument += 2;
            }
        }
        _ = try owner.apply(fixture.atGroup(50 + index, .{ .identity = 41001 + index, .payload = .{ .oms_intent_group = group } }));
        if (index < 2) try std.testing.expectEqual(@as(u16, @intCast(2 * (index + 1))), owner.shard.oms.order_count);
    }
    try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
    try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.portfolio_limit_exceeded, owner.shard.last_reject_reason);
    try applyHostCore(owner, 20, .{ .risk_lease_granted = .{ .version = 2, .amount_atoms = 25, .allocation = .{ .configuration_digest = manifest.header.?.expected_digest, .account = 20, .asset = 1, .domain = 1, .stream = 91 } } });
    var group = portfolioGroup(9, 10, 31007);
    for (group.members[0..2]) |*member| {
        member.quantity = 1000;
        member.instrument += 2;
        member.limit_price.instrument += 2;
    }
    _ = try owner.apply(fixture.atGroup(54, .{ .identity = 41004, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
    try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.decision_domain_limit_exceeded, owner.shard.last_reject_reason);
}
