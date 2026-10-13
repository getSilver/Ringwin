const std = @import("std");
const canonical = @import("canonical_event.zig");
const demo = @import("demo_authority.zig");
const durable = @import("durable_store.zig");
const fixture = @import("trading_shard_fixture.zig");

test "Order archive terminal reconciliation cannot close the window before unique Fill economics" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, .{ .domain = .decision_log, .id = 505 });
    const genesis = fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged);
    for (genesis) |event| _ = try owner.apply(event);
    _ = try owner.apply(fixture.atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
        .activation_barrier = 0,
        .state_digest = owner.shard.canonicalStateDigest(),
    } } }));
    try owner.sealBootstrap();
    _ = try owner.apply(fixture.atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = 3, .price_atoms = 50_000_000_000 } } }));
    _ = try owner.apply(fixture.canonicalAt(12, 99, .{ .instrument_definition_observed = .{ .instrument = 3, .rules_version = 1 } }));
    _ = try owner.apply(fixture.snapshotAt(13, 100));
    _ = try owner.apply(fixture.deltaAt(14, 100, 101, 49_850_000_000));
    const command = (try owner.apply(fixture.atGroup(15, .{ .identity = 1, .payload = .{ .timer = fixture.timer(fixture.happy_order_quantity) } }))) orelse return error.MissingOrderCommand;
    const facts = try fixture.happyVenueFacts(command);
    var reports: canonical.AdapterOutputBatch = .{};
    try reports.append(facts[0].venue);
    try reports.append(facts[1].venue);
    try reports.append(fixture.canonicalAt(18, 104, facts[5].venue.event).venue);
    try owner.applyAdapterBatch(reports);
    _ = try owner.apply(fixture.atGroup(19, .{ .identity = 1, .payload = .{ .oms_reconciliation_result = .{
        .reconciliation_id = 1,
        .order_id = command.order_id,
        .status = .found_terminal,
        .revision = command.revision,
        .cumulative_quantity = command.quantity,
        .remaining_quantity = 0,
        .terminal_state = .filled,
    } } }));
    const source = try owner.source();
    const terminal = source.oms.orderById(command.order_id) orelse return error.MissingTerminalOrder;
    try std.testing.expectEqual(fixture.atGroup(15, .{ .identity = 1, .payload = .recovery_completed }).core.receive_time, terminal.created_at_utc_ns);
    try std.testing.expectEqual(fixture.atGroup(18, .{ .identity = 1, .payload = .recovery_completed }).core.receive_time, terminal.terminal_observed_at_utc_ns);
    try std.testing.expectEqual(@as(i64, 0), try source.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    try std.testing.expectEqual(command.quantity, terminal.cumulative_quantity);
    try std.testing.expect(!terminal.reservation_active);
    try std.testing.expect(!terminal.archive_window_closed);
    try owner.checkpoint();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    const restored = (try recovered.source()).oms.orderById(command.order_id) orelse return error.MissingTerminalOrder;
    try std.testing.expect(!restored.archive_window_closed);
    try std.testing.expectEqualSlices(u8, &source.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    _ = try owner.apply(fixture.canonicalAt(20, 202, facts[2].venue.event));
    _ = try owner.apply(fixture.canonicalAt(20, 203, facts[4].venue.event));
    try std.testing.expectError(error.OrderArchiveNotQualified, owner.shard.oms.prepareOrderArchive(command.order_id, command.quantity, 2));
    var coverage = fixture.reconciliationEvidence(3019, 204, command.order_id, 3, command.revision);
    coverage.scope.from_utc_ns = terminal.created_at_utc_ns;
    coverage.terminal_archive = .{
        .visibility_deadline_utc_ns = terminal.terminal_observed_at_utc_ns + 30 * std.time.ns_per_s,
        .order_history_complete = true,
        .terminal_history_complete = true,
        .fills_complete = true,
        .economics_complete = true,
    };
    _ = try owner.apply(fixture.canonicalAt(3019, 204, .{ .order_reconciliation_result = .{
        .identity = 2,
        .complete = true,
        .status = .found_terminal,
        .order = command.order_id,
        .revision = command.revision,
        .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = command.quantity },
        .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 0 },
        .terminal_status = .filled,
        .rules_version = 1,
        .evidence = coverage,
    } }));
    const qualified = try owner.shard.oms.prepareOrderArchive(command.order_id, try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id), 2);
    try std.testing.expectEqual(terminal.terminal_observed_at_utc_ns, qualified.order.terminal_observed_at_utc_ns);
    try std.testing.expectEqual(command.quantity, qualified.applied_fill_quantity);
    const absent_gateway = try allocator.create(@import("execution_gateway.zig").Gateway);
    defer allocator.destroy(absent_gateway);
    absent_gateway.init();
    try std.testing.expectError(error.DispatchArchiveEvidenceMissing, owner.archiveTerminalOrder(command.order_id, absent_gateway));
    try std.testing.expect(owner.shard.oms.orderById(command.order_id) != null);
    try std.testing.expect(!owner.closed);
}
