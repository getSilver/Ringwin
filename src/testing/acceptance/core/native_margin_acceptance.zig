const std = @import("std");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const canonical = @import("../../../model/canonical_event.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");

fn broadcast(coordinator: *coordination.CoordinatorOwner, owners: []demo.Owner, sequence: u64, payload: canonical.Payload) !void {
    var record = fixture.canonicalAt(60, sequence, payload).venue;
    record.envelope.identity.stream = 6000;
    record.envelope.source_stream = 6000;
    record.envelope.source_fact_identity = 6000 + sequence;
    record.envelope.scope = .account;
    record.envelope.instrument = null;
    record.envelope.asset = null;
    try coordinator.acceptVenueFact(record);
    for (owners, 0..) |*owner, index| try std.testing.expect(try coordinator.deliverVenueFact(@enumFromInt(index), owner));
}

/// Extends the real four-Owner shared Gateway/report/fill acceptance without a second execution fixture.
pub fn verify(owners: []demo.Owner, store: durable.Store) !void {
    var coordinator = try coordination.CoordinatorOwner.init(.init(2, 100, 100), .{ .domain = .control, .id = 6000 }, store, undefined);
    for (owners, 1..) |*owner, domain| {
        for ([_]u128{ domain, domain + 4 }) |instrument| {
            var margin = owner.shard.instrument_registry.get(instrument).?.margin;
            margin.version = 3;
            margin.native_settlement_atoms = true;
            margin.native = .{ .model = .isolated_linear_v1, .tier_identity = 1, .notional_lower_atoms = 0, .notional_upper_atoms = 100000, .initial_margin_ppm = 20000, .maintenance_ppm = 11000, .maintenance_deduction_atoms = 0, .close_fee_ppm = 0, .margin_rounding_atoms = 1, .price_rounding_ticks = 1 };
            margin.native.?.margin_rounding_atoms = 10;
            _ = try owner.apply(fixture.atGroup(59, .{ .identity = @intCast(6000 + instrument), .account_scope = 2, .payload = .{ .margin_rules_activated = margin } }));
            if (instrument == domain) {
                try std.testing.expectEqual(@as(i128, 10), owner.shard.economic_projection.portfolio.instrumentPosition(instrument).?.margin_atoms);
                const restored_position = try std.testing.allocator.create(demo.Owner);
                defer std.testing.allocator.destroy(restored_position);
                try owner.checkpoint();
                try demo.Owner.recoverInto(restored_position, store, undefined, owner.stream);
                try std.testing.expectEqual(@as(i128, 10), restored_position.shard.economic_projection.portfolio.instrumentPosition(instrument).?.margin_atoms);
            }
            margin.version = 4;
            margin.native.?.margin_rounding_atoms = 1;
            _ = try owner.apply(fixture.atGroup(59, .{ .identity = @intCast(6500 + instrument), .account_scope = 2, .payload = .{ .margin_rules_activated = margin } }));
            try coordinator.apply(.{ .native_margin_configuration = owner.shard.instrument_registry.get(instrument).? });
        }
        try coordinator.apply(.{ .publish_summary = .{ .identity = domain, .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(domain - 1), 1, domain) } });
    }
    var snapshot: canonical.AccountBootstrapSnapshot = .{ .identity = 6001, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 6000, .source_sequence = 0, .balance_count = 1, .position_count = 4, .margin_count = 4 };
    const zero: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
    const cash: canonical.AssetAmount = .{ .asset = 1, .atoms = 99 };
    snapshot.balances[0] = .{ .asset = 1, .total = cash, .available = .{ .asset = 1, .atoms = 91 }, .held = .{ .asset = 1, .atoms = 8 }, .cash_balance = cash, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
    for (1..5) |instrument| {
        snapshot.positions[instrument - 1] = .{ .instrument = instrument, .side = .long, .quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 10000 }, .average_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 10 }, .mark_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 10 }, .liquidation_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 8 }, .leverage = .{ .coefficient = 50, .scale = 0 }, .unrealized_pnl = zero, .risk_tier = 1 };
        snapshot.margins[instrument - 1] = .{ .instrument = instrument, .amount = .{ .asset = 1, .atoms = 2 }, .initial_margin = .{ .asset = 1, .atoms = 1 }, .maintenance_margin = .{ .asset = 1, .atoms = 1 }, .isolated_equity = .{ .asset = 1, .atoms = 2 } };
    }
    try broadcast(&coordinator, owners, 1, .{ .account_bootstrap_snapshot = snapshot });
    try broadcast(&coordinator, owners, 2, .{ .venue_account_configuration_snapshot = .{ .identity = 6002, .exchange_account = 2, .value = .{ .account = .{ .position_mode_net = true, .contract_isolated_autonomy = true, .auto_loan = false, .spot_borrow_enabled = false, .can_read = true, .can_trade = true, .can_withdraw = false } } } });
    for (1..9) |instrument| try broadcast(&coordinator, owners, instrument + 2, .{ .venue_account_configuration_snapshot = .{ .identity = 6002 + instrument, .exchange_account = 2, .value = .{ .isolated_leverage = .{ .instrument = instrument, .position_mode_net = true, .margin_mode_isolated = true, .leverage = .{ .coefficient = 50, .scale = 0 } } } } });
    for (owners, 0..) |*owner, index| {
        const summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 2, index + 1);
        try std.testing.expectEqual(@as(i128, 2), try owner.shard.activeReservationAtoms());
        try std.testing.expectEqual(@as(i128, 3), summary.reservation_atoms);
        try coordinator.apply(.{ .publish_summary = .{ .identity = index + 11, .summary = summary } });
    }
    try coordinator.apply(.{ .margin_observation = .{ .identity = 6000, .barrier = coordinator.coordinator.barrier + 1, .venue_net_margin_atoms = 0, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 } });
    try std.testing.expectEqual(coordination.MarginReconciliationState.healthy, coordinator.coordinator.margin_reconciliation_state);
    try std.testing.expectEqual(@as(i128, 12), try coordinator.coordinator.grossPortfolioMargin());
    try std.testing.expectEqual(@as(i128, 8), coordinator.coordinator.account_netting_benefit_atoms);
    try coordinator.checkpoint();
    const restored = try coordination.CoordinatorOwner.recover(coordinator.stream, store, undefined);
    try std.testing.expectEqualDeep(coordinator.coordinator.digest(), restored.coordinator.digest());
    for (owners) |*owner| try std.testing.expectEqual(@as(i128, 2), try owner.shard.activeReservationAtoms());
    snapshot.identity = 7000;
    snapshot.positions[0].quantity.lots = 10001;
    try broadcast(&coordinator, owners, 11, .{ .account_bootstrap_snapshot = snapshot });
    try coordinator.apply(.{ .margin_observation = .{ .identity = 7000, .barrier = coordinator.coordinator.last_margin_observation.?.barrier + 1, .venue_net_margin_atoms = 0, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 } });
    try std.testing.expect(coordinator.coordinator.margin_gate.latched);
    for (coordinator.coordinator.accountGateDeliveries(coordinator.coordinator.margin_gate), 0..) |delivery, index| {
        const event = try coordination.accountGateEvent(delivery, owners[index].shard.operational_state.target_identity);
        _ = try owners[index].apply(fixture.atGroup(61, event));
        try std.testing.expect(!owners[index].shard.operational_state.effectiveTradingAuthority());
        try std.testing.expect(owners[index].shard.operational_state.mayReduceOnly());
        try std.testing.expectEqual(.pending_cancel, owners[index].shard.oms.orderById(2).?.state);
        try std.testing.expectEqual(.cancel, owners[index].shard.oms.findCommand(3).?.operation);
        try std.testing.expectEqual(@as(i128, 2), try owners[index].shard.activeReservationAtoms());
    }
    snapshot.identity = 7001;
    snapshot.positions[0].quantity.lots = 10000;
    try broadcast(&coordinator, owners, 12, .{ .account_bootstrap_snapshot = snapshot });
    try coordinator.apply(.{ .margin_observation = .{ .identity = 7001, .barrier = coordinator.coordinator.last_margin_observation.?.barrier + 1, .venue_net_margin_atoms = 0, .venue_swap_quantity = 0, .margin_mode = .isolated, .rules_version = 1 } });
    try std.testing.expectEqual(coordination.MarginReconciliationState.healthy, coordinator.coordinator.margin_reconciliation_state);
    try std.testing.expect(coordinator.coordinator.margin_gate.latched);
    try coordinator.apply(.{ .resolve_margin_gate = 7001 });
    for (coordinator.coordinator.accountGateDeliveries(coordinator.coordinator.margin_gate), 0..) |delivery, index| {
        const event = try coordination.accountGateEvent(delivery, owners[index].shard.operational_state.target_identity);
        _ = try owners[index].apply(fixture.atGroup(62, event));
        try std.testing.expect(!owners[index].shard.operational_state.effectiveTradingAuthority());
        var resolve = fixture.resolveLatchCommand(7100, owners[index].shard.operational_state.version, delivery.gate.identity);
        resolve.core.payload.control_command.target_identity = owners[index].shard.operational_state.target_identity;
        _ = try owners[index].apply(resolve);
        try std.testing.expect(!owners[index].shard.operational_state.effectiveTradingAuthority());
        var resume_input = fixture.lifecycleCommand(7101, owners[index].shard.operational_state.version, .enable_trading);
        resume_input.core.payload.control_command.target_identity = owners[index].shard.operational_state.target_identity;
        _ = try owners[index].apply(resume_input);
        try std.testing.expect(owners[index].shard.operational_state.effectiveTradingAuthority());
        try std.testing.expectEqual(@as(i128, 2), try owners[index].shard.activeReservationAtoms());
    }
    try coordinator.checkpoint();
    const final_coordinator = try coordination.CoordinatorOwner.recover(coordinator.stream, store, undefined);
    try std.testing.expectEqualDeep(coordinator.coordinator.digest(), final_coordinator.coordinator.digest());
    const recovered_owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered_owner);
    for (owners) |*owner| {
        try owner.checkpoint();
        try demo.Owner.recoverInto(recovered_owner, store, undefined, owner.stream);
        try std.testing.expectEqualDeep(owner.shard.canonicalStateDigest(), recovered_owner.shard.canonicalStateDigest());
        try std.testing.expectEqualDeep(owner.shard.economicSummary(), recovered_owner.shard.economicSummary());
        try std.testing.expectEqual(@as(i128, 2), try recovered_owner.shard.activeReservationAtoms());
    }
}
