//! Offline scanner request -> durable TradingShard authority -> recovery.
const std = @import("std");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const trading = @import("../../../trading/trading_shard.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const existing = @import("multi_account_authority_acceptance.zig");
const approval = @import("../../../trading/pair_trading_authorization.zig");

pub fn configurePairAssets(owner: *demo.Owner) !void {
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| {
        const entry = owner.shard.pairInstrument(account, instrument).?;
        var rules = entry.rules;
        rules.version += 1;
        rules.base_asset = 0x425443;
        rules.quantity_denominator = 1;
        _ = try owner.apply(fixture.atGroup(44, .{ .identity = owner.shard.authoritativeBarrier() + 1, .account_scope = account, .payload = .{ .instrument_rules_activated = rules } }));
        var margin = entry.margin;
        margin.version += 1;
        margin.price_tick_atoms = 100_000;
        _ = try owner.apply(fixture.atGroup(44, .{ .identity = owner.shard.authoritativeBarrier() + 1, .account_scope = account, .payload = .{ .margin_rules_activated = margin } }));
        var capability = entry.capability.?;
        capability.version += 1;
        capability.rules_version = rules.version;
        _ = try owner.apply(fixture.atGroup(44, .{ .identity = owner.shard.authoritativeBarrier() + 1, .account_scope = account, .payload = .{ .capability_profile_activation = capability } }));
    }
}

test "scanner pair approval validates identities and survives durable recovery" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try existing.initializePythonOwner(owner);
    // The legacy fixture leaves linear exposure assets unspecified. Register
    // their real canonical base before approving an economic pairing.
    try configurePairAssets(owner);
    var request: approval.Request = .{ .identity = 98765, .strategy = 9, .portfolio = 10, .activation = 1, .config_version = 1, .expected_version = 0, .legs = .{
        .{ .venue = 1, .environment = .simulation, .account = 20, .instrument = 101, .rules_version = 2 },
        .{ .venue = 21, .environment = .simulation, .account = 30, .instrument = 102, .rules_version = 2 },
    }, .direction = 1, .mode = .taker_taker, .enabled = true };
    const before = owner.shard.canonicalStateDigest();
    for (0..5) |scenario| {
        var bad = request;
        switch (scenario) {
            0 => bad.legs[1].account = 999,
            1 => bad.legs[1].rules_version = 1,
            2 => bad.portfolio = 999,
            3 => bad.config_version = 999,
            4 => bad.legs[1].environment = .demo,
            else => unreachable,
        }
        if (owner.shard.apply(fixture.atGroup(45, .{ .identity = 98765, .payload = .{ .pair_trading_authorization = bad } }))) |_| {
            return error.ExpectedPairRejection;
        } else |_| {}
        try std.testing.expectEqualSlices(u8, &before, &owner.shard.canonicalStateDigest());
    }
    const event = fixture.atGroup(45, .{ .identity = 98765, .payload = .{ .pair_trading_authorization = request } });
    _ = try owner.apply(event);
    try std.testing.expectEqual(@as(u64, 1), owner.shard.pair_authorizations.version);
    const accepted = owner.shard.canonicalStateDigest();
    _ = try owner.apply(event);
    try std.testing.expectEqualSlices(u8, &accepted, &owner.shard.canonicalStateDigest());
    request.identity += 1;
    request.expected_version = 1;
    request.enabled = false;
    const orders = owner.shard.oms.order_count;
    _ = try owner.apply(fixture.atGroup(46, .{ .identity = 98766, .payload = .{ .pair_trading_authorization = request } }));
    try std.testing.expectEqual(orders, owner.shard.oms.order_count);
    try owner.checkpoint();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
    try std.testing.expectEqual(@as(u64, 2), recovered.shard.pair_authorizations.version);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
}
