//! Small shared-account integration: four actual Owner publications, no SDK calls.
const std = @import("std");
const helpers = @import("../history/coordinator_history_acceptance.zig");
const acceptance = @import("../history/order_gateway_archive_acceptance.zig");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");

test "09 four actual Owners enforce one shared account ceiling and retain shard reservations through recovery" {
    const allocator = std.testing.allocator;
    var owners: [4]*acceptance.ArchiveHarness = undefined;
    var count: usize = 0;
    defer for (owners[0..count]) |harness| harness.destroy();
    var summaries: [4]coordination.ShardSummary = undefined;
    var gross: i128 = 0;
    for (&owners, 0..) |*slot, index| {
        slot.* = try helpers.createForcedHarness(index);
        count += 1;
        const owner = slot.*.owner;
        // The helper leaves a real economically settled/archived predecessor.
        // New live reservations come from a public intent, never from a DTO fixture.
        var book = fixture.snapshotAt(4040, 500);
        book.venue.envelope.identity.stream = 7;
        book.venue.envelope.source_stream = 7;
        book.venue.envelope.raw_evidence.stream = 7;
        _ = try owner.apply(book);
        _ = (try owner.apply(fixture.atGroup(4041, .{ .identity = 102, .payload = .{ .timer = .{
            .side = .buy,
            .time_in_force = .good_til_canceled,
            .portfolio_reduce_only = false,
            .quantity = 20,
            .limit_price_micros = 50_000_000,
        } } }))) orelse return error.MissingSharedAccountOrder;
        summaries[index] = try coordination.shardSummaryFromShard(&owner.shard, @enumFromInt(index), 1, index + 1);
        try std.testing.expectEqual(@as(u16, 1), summaries[index].open_orders);
        try std.testing.expectEqual(@as(u128, index + 11), summaries[index].virtual_portfolio);
        try std.testing.expect(summaries[index].reservation_atoms > 0);
        gross += summaries[index].reservation_atoms;
    }
    const store = owners[0].backend.interface();
    var denied = try coordination.CoordinatorOwner.init(.init(2, gross - 1, gross * 10), .{ .domain = .control, .id = 96201 }, store, undefined);
    for (summaries, 0..) |summary, index|
        try denied.apply(.{ .publish_summary = .{ .identity = index + 1, .summary = summary } });
    const barrier = denied.sequence;
    try std.testing.expectError(error.AccountSafetyCeilingExceeded, denied.apply(.{ .allocate_leases = .{ .version = 1, .valid_through_barrier = 1000 } }));
    try std.testing.expectEqual(barrier, denied.sequence);
    try std.testing.expectEqual(@as(u8, 0), denied.coordinator.lease_count);
    var admitted = try coordination.CoordinatorOwner.init(.init(2, gross * 2, gross * 10), .{ .domain = .control, .id = 96202 }, store, undefined);
    for (summaries, 0..) |summary, index|
        try admitted.apply(.{ .publish_summary = .{ .identity = index + 1, .summary = summary } });
    try admitted.apply(.{ .allocate_leases = .{ .version = 1, .valid_through_barrier = 1000 } });
    try admitted.checkpoint();
    var recovered = try coordination.CoordinatorOwner.recover(admitted.stream, store, undefined);
    try std.testing.expect(recovered.coordinator.recovery_only);
    try std.testing.expectEqual(gross, try recovered.coordinator.grossPortfolioMargin());
    try std.testing.expectError(error.CoordinatorRecoveryOnly, recovered.apply(.{ .allocate_leases = .{ .version = 2, .valid_through_barrier = 1000 } }));
    for (recovered.coordinator.leases, 0..) |lease, index| {
        try std.testing.expectEqual(@as(u128, 2), lease.exchange_account);
        try std.testing.expectEqual(@as(coordination.ShardId, @enumFromInt(index)), lease.shard_id);
        try std.testing.expectEqual(summaries[index].decision_domain, lease.decision_domain);
        try std.testing.expectEqual(summaries[index].reservation_atoms, lease.used_atoms);
        const owner = owners[index].owner;
        try owner.checkpoint();
        const restored = try allocator.create(demo.Owner);
        defer allocator.destroy(restored);
        try demo.Owner.recoverInto(restored, owners[index].backend.interface(), undefined, owners[index].stream);
        try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
        try std.testing.expectEqual(summaries[index].reservation_atoms, try restored.shard.activeReservationAtoms());
        try std.testing.expectEqual(@as(u64, 0), owners[index].gateway.send_attempt_count);
    }
    std.debug.print("continuous shared account owners=4 live=4 terminal=0 sdk_sends=0 gross={d} ceiling_reject=preserved recovered=equal\n", .{gross});
}
