const std = @import("std");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const allocation = @import("../../../trading/deployment_allocation.zig");
const trading = @import("../../../trading/trading_shard.zig");
const simulated = @import("../../../adapters/simulated/simulated_venue.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");

fn failCommit(_: *anyopaque, _: std.Io, _: durable.StreamIdentity, _: u64) anyerror!void {
    return error.InjectedEio;
}

pub fn initialize(owner: *demo.Owner, index: usize) !void {
    const domain = index + 1;
    const stream = index + 9101;
    const portfolio = index + 11;
    var rows: [21]allocation.Input = undefined;
    rows[0] = .{ .begin = .{ .identity = 7, .epoch = 1, .domain_count = 4, .account_count = 1, .asset_count = 1, .account_limit_count = 1, .ownership_count = 8, .slice_count = 4, .expected_digest = @splat(1) } };
    for (0..4) |n| {
        rows[1 + n] = .{ .domain = .{ .identity = n + 1, .stream = n + 9101, .portfolio = n + 11 } };
        rows[8 + n] = .{ .ownership = .{ .account = 2, .instrument = n + 1, .domain = n + 1 } };
        rows[12 + n] = .{ .ownership = .{ .account = 2, .instrument = n + 5, .domain = n + 1 } };
        rows[16 + n] = .{ .slice = .{ .account = 2, .asset = 1, .domain = n + 1, .atoms = 25 } };
    }
    rows[5] = .{ .account = .{ .identity = 2, .venue = 1 } };
    rows[6] = .{ .asset_limit = .{ .asset = 1, .atoms = 100 } };
    rows[7] = .{ .account_limit = .{ .account = 2, .asset = 1, .atoms = 100 } };
    rows[20] = .seal;
    var configuration: allocation.Configuration = .{};
    for (rows[0 .. rows.len - 1]) |row| try configuration.apply(row);
    rows[0].begin.expected_digest = configuration.contentDigest();
    try owner.pinDeploymentDigest(rows[0].begin.expected_digest);
    for (rows, 0..) |row, position|
        _ = try owner.apply(.{ .core = .{ .identity = position + 1, .payload = .{ .deployment_configuration = row } } });
    _ = try owner.apply(.{ .core = .{ .identity = 22, .payload = .{ .decision_domain_bound = .{ .domain = domain, .stream = stream } } } });
    for (@import("../../../trading/asset_registry.zig").testDefinitions(6, 8)) |definition|
        _ = try owner.apply(.{ .core = .{ .identity = definition.asset, .payload = .{ .asset_definition_activated = definition } } });
    const payloads = [_]trading.CorePayload{
        .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = domain, .quantity_denominator = 10000, .reservation_model = .leveraged, .product = .isolated_linear_usdt, .venue = 1 } },
        .{ .margin_rules_activated = .{ .version = 1, .instrument = domain } },
        .{ .account_configuration = .{ .exchange_account_identity = 2 } },
        .{ .exchange_balance = .{ .cash_atoms = 25 } },
        .exchange_positions,
        .{ .opening_balance = .{ .cash_atoms = 25 } },
        .{ .virtual_portfolio_activated = .{ .portfolio_identity = portfolio } },
        .{ .portfolio_transfer = .{ .amount_atoms = 25 } },
    };
    for (payloads, 0..) |payload, position|
        _ = try owner.apply(fixture.atGroup(10, .{ .identity = position + 20, .account_scope = 2, .payload = payload }));
    // Account observations include instruments owned by the other domains.
    for (1..9) |instrument| {
        if (instrument == domain) continue;
        _ = try owner.apply(fixture.atGroup(10, .{ .identity = instrument + 40, .account_scope = 2, .payload = .{ .instrument_rules_activated = .{
            .version = 1,
            .instrument_identity = instrument,
            .quantity_denominator = 10000,
            .reservation_model = .leveraged,
            .product = .isolated_linear_usdt,
            .venue = 1,
        } } }));
    }
    try owner.sealBootstrap();
}

test "03 one VenueAdapter broadcasts original facts through four durable Owners" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const owners = try allocator.alloc(demo.Owner, 4);
    defer allocator.free(owners);
    var coordinator = try coordination.CoordinatorOwner.init(.init(2, 100, 100), .{ .domain = .control, .id = 9199 }, memory.interface(), undefined);
    for (owners, 0..) |*owner, index| {
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = index + 9101 });
        try initialize(owner, index);
        try coordinator.apply(.{ .publish_summary = .{ .identity = index + 1, .summary = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 1, index + 1) } });
    }
    var source: simulated.SimulatedVenue = .{};
    var adapter = source.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1 });
    try std.testing.expectEqual(.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 100, .exchange_account = 2, .expected_session = 1 } }));
    const batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(usize, 6), batch.slice().len);
    for (batch.slice()) |record| try coordinator.acceptVenueFact(record);
    // Shard 0 pauses while other writers commit the complete account observation stream.
    for (owners[1..], 1..) |*owner, index| {
        for (batch.slice()) |record| {
            try std.testing.expectEqualDeep(record, (try coordinator.pendingVenueFact(@enumFromInt(index))).?);
            try std.testing.expect(try coordinator.deliverVenueFact(@enumFromInt(index), owner));
        }
        try std.testing.expect(!try coordinator.deliverVenueFact(@enumFromInt(index), owner));
        try std.testing.expectEqual(@as(i128, 25), owner.shard.economic_projection.portfolio.usdt_balance_atoms);
    }
    try coordinator.checkpoint();
    var recovered = try coordination.CoordinatorOwner.recover(coordinator.stream, memory.interface(), undefined);
    for (batch.slice()) |record| {
        try std.testing.expectEqualDeep(record, (try recovered.pendingVenueFact(.shard_0)).?);
        try std.testing.expect(try recovered.deliverVenueFact(.shard_0, &owners[0]));
    }
    try std.testing.expect(!try recovered.deliverVenueFact(.shard_0, &owners[0]));
    const sequence = recovered.sequence;
    for (batch.slice()) |record| try recovered.acceptVenueFact(record);
    try std.testing.expectEqual(sequence, recovered.sequence);
    try std.testing.expectEqual(@as(u64, 7), source.next_event_identity);
    try std.testing.expectEqual(@as(?@import("../../../model/canonical_event.zig").AdapterOutputBatch, null), try adapter.tryDrain());
    for (owners) |*owner| {
        try std.testing.expectEqual(@as(i128, 25), owner.shard.economic_projection.portfolio.usdt_balance_atoms);
        try std.testing.expectEqual(owners[0].shard.authoritativeBarrier(), owner.shard.authoritativeBarrier());
    }
    var funding = fixture.canonicalAt(40, 7, .{ .funding_settlement = .{
        .identity = 500,
        .exchange_account = 2,
        .instrument = 1,
        .rules_version = 1,
        .venue_bill_id = 500,
        .amount = .{ .asset = 1, .atoms = -3 },
        .settlement_time_utc_ns = fixture.atGroup(40, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
    } });
    funding.venue.envelope.instrument = 1;
    funding.venue.envelope.asset = 1;
    try recovered.acceptVenueFactFromOwners(funding.venue, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    for (owners[1..], 1..) |*owner, index|
        try std.testing.expect(!try recovered.deliverVenueFact(@enumFromInt(index), owner));
    // Crash after the target commit and before the coordinator acknowledgement.
    _ = try owners[0].apply(funding);
    try std.testing.expectEqual(@as(i128, 22), owners[0].shard.economic_projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, -3), owners[0].shard.economic_projection.portfolio.funding_atoms);
    const applied_barrier = owners[0].shard.authoritativeBarrier();
    const applied_digest = owners[0].shard.canonicalStateDigest();
    var retried = try coordination.CoordinatorOwner.recover(coordinator.stream, memory.interface(), undefined);
    try std.testing.expect(try retried.deliverVenueFact(.shard_0, &owners[0]));
    try std.testing.expectEqual(applied_barrier, owners[0].shard.authoritativeBarrier());
    try std.testing.expectEqualDeep(applied_digest, owners[0].shard.canonicalStateDigest());
    for (owners[1..]) |*owner|
        try std.testing.expectEqual(@as(i128, 25), owner.shard.economic_projection.portfolio.usdt_balance_atoms);
    var first_pending: trading.canonical.EventRecord = undefined;
    for (8..48) |cursor| {
        var queued = funding.venue;
        queued.envelope.identity.sequence = cursor;
        queued.envelope.source_sequence = cursor;
        queued.envelope.source_fact_identity = cursor + 1000;
        queued.envelope.raw_evidence.sequence = cursor;
        queued.event.funding_settlement.identity = cursor + 1000;
        queued.event.funding_settlement.venue_bill_id = cursor + 1000;
        if (cursor == 8) first_pending = queued;
        try retried.acceptVenueFactFromOwners(queued, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    }
    var independent = funding.venue;
    independent.envelope.identity.sequence = 48;
    independent.envelope.source_sequence = 48;
    independent.envelope.source_fact_identity = 1048;
    independent.envelope.raw_evidence.sequence = 48;
    independent.envelope.instrument = 2;
    independent.event.funding_settlement.identity = 1048;
    independent.event.funding_settlement.venue_bill_id = 1048;
    independent.event.funding_settlement.instrument = 2;
    independent.event.funding_settlement.amount.atoms = -2;
    try retried.acceptVenueFactFromOwners(independent, .{ &owners[0], &owners[1], &owners[2], &owners[3] });
    try std.testing.expect(try retried.deliverVenueFact(.shard_1, &owners[1]));
    try std.testing.expectEqual(@as(i128, 23), owners[1].shard.economic_projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, 22), owners[0].shard.economic_projection.portfolio.usdt_balance_atoms);
    try retried.checkpoint();
    var paused = try coordination.CoordinatorOwner.recover(coordinator.stream, memory.interface(), undefined);
    try std.testing.expectEqualDeep(first_pending, (try paused.pendingVenueFact(.shard_0)).?);
    try std.testing.expect(!try paused.deliverVenueFact(.shard_1, &owners[1]));
    var failing = memory.interface().vtable.*;
    failing.commit = failCommit;
    paused.store = .{ .context = memory, .vtable = &failing };
    try std.testing.expectError(error.InjectedEio, paused.deliverVenueFact(.shard_0, &owners[0]));
    const quarantined = try coordination.CoordinatorOwner.recover(coordinator.stream, memory.interface(), undefined);
    try std.testing.expect(quarantined.closed);
    try std.testing.expectEqual(@as(i128, 19), owners[0].shard.economic_projection.portfolio.usdt_balance_atoms);
    const restored = try allocator.create(demo.Owner);
    defer allocator.destroy(restored);
    for (owners) |*owner| {
        try owner.checkpoint();
        try demo.Owner.recoverInto(restored, memory.interface(), undefined, owner.stream);
        try std.testing.expectEqualDeep(owner.shard.economicSummary(), restored.shard.economicSummary());
        try std.testing.expectEqualDeep(owner.shard.canonical_account.digest(), restored.shard.canonical_account.digest());
        try std.testing.expectEqualDeep(
            owner.shard.operational_state.gates[0..owner.shard.operational_state.gate_count],
            restored.shard.operational_state.gates[0..restored.shard.operational_state.gate_count],
        );
        try std.testing.expect(restored.shard.recovery_admission_pending);
        try std.testing.expect(!restored.shard.operational_state.effectiveTradingAuthority());
    }
}

test "03 immutable deployment ownership attributes canonical funding" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 9101 });
    try initialize(owner, 0);
    var event = fixture.canonicalAt(30, 1, .{ .funding_settlement = .{
        .identity = 500,
        .exchange_account = 2,
        .instrument = 1,
        .rules_version = 1,
        .venue_bill_id = 500,
        .amount = .{ .asset = 1, .atoms = -3 },
        .settlement_time_utc_ns = fixture.atGroup(30, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
    } });
    event.venue.envelope.instrument = 1;
    event.venue.envelope.asset = 1;
    _ = try owner.apply(event);
    try std.testing.expectEqual(@as(i128, 22), owner.shard.economic_projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, -3), owner.shard.economic_projection.portfolio.funding_atoms);
    try std.testing.expectEqual(@as(i128, 0), owner.shard.economic_projection.suspense_usdt_atoms);
    try owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqual(@as(i128, 22), recovered.shard.economic_projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, -3), recovered.shard.economic_projection.portfolio.funding_atoms);
    var foreign = event;
    foreign.venue.envelope.identity.sequence = 2;
    foreign.venue.envelope.source_sequence = 2;
    foreign.venue.envelope.source_fact_identity = 501;
    foreign.venue.envelope.raw_evidence.sequence = 2;
    foreign.venue.envelope.instrument = 2;
    foreign.venue.event.funding_settlement.identity = 501;
    foreign.venue.event.funding_settlement.venue_bill_id = 501;
    foreign.venue.event.funding_settlement.instrument = 2;
    _ = try owner.apply(foreign);
    try std.testing.expectEqual(@as(i128, 22), owner.shard.economic_projection.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i128, -3), owner.shard.economic_projection.suspense_usdt_atoms);
    const digest = owner.shard.canonicalStateDigest();
    try std.testing.expectError(error.CanonicalScopeMismatch, owner.shard.apply(fixture.atGroup(40, .{ .identity = 90, .account_scope = 2, .payload = .{ .instrument_rules_activated = .{
        .version = 1,
        .instrument_identity = 9,
        .quantity_denominator = 10000,
        .reservation_model = .leveraged,
        .product = .isolated_linear_usdt,
        .venue = 1,
    } } })));
    try std.testing.expectEqualDeep(digest, owner.shard.canonicalStateDigest());
}
