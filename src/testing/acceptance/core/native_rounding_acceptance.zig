const std = @import("std");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const setup = @import("shared_venue_delivery_acceptance.zig");
const shared = @import("shared_gateway_venue_acceptance.zig");

test "04 native quantum reserves ten atoms per place through four real Owners" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const owners = try allocator.alloc(demo.Owner, 4);
    defer allocator.free(owners);
    for (owners, 0..) |*owner, index| {
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = index + 9101 });
        try setup.initialize(owner, index);
        try shared.admitWithQuantum(owner, index, 10);
        try std.testing.expectEqual(@as(i128, 10), owner.shard.oms.findCommand(1).?.reservation.atoms);
        try std.testing.expectEqual(@as(i128, 12), try owner.shard.activeReservationAtoms());
        try owner.checkpoint();
        const restored = try allocator.create(demo.Owner);
        defer allocator.destroy(restored);
        try demo.Owner.recoverInto(restored, memory.interface(), undefined, owner.stream);
        try std.testing.expectEqual(@as(i128, 12), try restored.shard.activeReservationAtoms());
        try std.testing.expectEqualDeep(owner.shard.canonicalStateDigest(), restored.shard.canonicalStateDigest());
    }
}
