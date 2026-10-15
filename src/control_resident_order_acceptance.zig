//! Control retirement with a resident, unsent order and its original authority.
const std = @import("std");
const acceptance = @import("order_gateway_archive_acceptance.zig");
const demo = @import("demo_authority.zig");
const fixture = @import("trading_shard_fixture.zig");
const trading = @import("trading_shard.zig");

fn expectPinnedAuthority(shard: *const trading.TradingShard, original: trading.oms.FactRef, current: u128) !void {
    var original_present = false;
    var current_present = false;
    for (shard.operational_state.command_history[0..shard.operational_state.command_count], 0..) |record, index| {
        if (record.command.command_identity == original.identity) {
            try std.testing.expectEqual(original.barrier, shard.control_fact_sequences[index]);
            try std.testing.expectEqual(original.version, record.command.expected_version + 1);
            original_present = true;
        }
        if (record.command.command_identity == current) current_present = true;
    }
    try std.testing.expect(original_present);
    try std.testing.expect(current_present);
    try std.testing.expectEqual(@as(u8, 2), shard.operational_state.command_count);
    try std.testing.expectEqual(@as(usize, 1), shard.oms.order_count);
    try std.testing.expect(shard.oms.orders[0].reservation_active);
    try std.testing.expect(!shard.operational_state.trading_authorized);
}

test "08 resident order pins its old authorization while unrelated completed control commands cross capacity" {
    const harness = try acceptance.ArchiveHarness.createBase(std.testing.allocator, 170001);
    defer harness.destroy();
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 1 };
    group.members[0] = .{ .intent_sequence = 101, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    _ = try harness.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .oms_intent_group = group } }));
    const original = harness.owner.shard.oms.command_history[0].authority.trading_authorization;
    try std.testing.expect(original.identity != 0);
    const stop_identity = 700;
    _ = try harness.owner.apply(fixture.lifecycleCommand(stop_identity, harness.owner.shard.operational_state.version, .stop_keep_positions));
    try std.testing.expect(original.barrier != harness.owner.shard.authority_control_barrier);
    try harness.owner.checkpoint();
    const before_archived = harness.owner.shard.archived_control_records;
    for (0..40) |index| {
        _ = try harness.owner.apply(fixture.lifecycleCommand(1000 + index, harness.owner.shard.operational_state.version, .cancel_open_orders));
        _ = try harness.owner.archiveControlHistory(harness.gateway);
        try expectPinnedAuthority(&harness.owner.shard, original, stop_identity);
        if (index % 8 == 7) try harness.owner.checkpoint();
    }
    try std.testing.expect(harness.owner.shard.archived_control_records >= before_archived + 40);
    const digest = harness.owner.shard.canonicalStateDigest();
    const restored = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(restored);
    try demo.Owner.recoverInto(restored, harness.backend.interface(), undefined, harness.stream);
    try std.testing.expectEqualDeep(digest, restored.shard.canonicalStateDigest());
    try expectPinnedAuthority(&restored.shard, original, stop_identity);
    try std.testing.expectEqual(@as(u64, 0), harness.gateway.send_attempt_count);
    try std.testing.expectEqual(@as(u64, 0), harness.simulator.sends);
}
