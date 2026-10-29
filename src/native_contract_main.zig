//! Explicit offline build acceptance, without release or trading authority.
const std = @import("std");
const registry = @import("trading/trading_shard.zig").TradingShard.native_definitions;

pub fn main() !void {
    try registry.validate();
    const identity = 0xa21994db11534bf5b193c5aa89000001;
    const definition = registry.find(identity) orelse return error.MissingDefinition;
    if (!std.mem.eql(u8, definition.entrypoint, "native_observer") or registry.find(0) != null) return error.WrongDefinition;
    const Impl = registry.implementation(identity);
    const config: Impl.Config = .{ .instrument = 3, .max_observations = 2 };
    var state = try Impl.create(config);
    try Impl.onReferencePrice(config, &state, 7, .{
        .instrument = 3,
        .kind = .mark,
        .price = .{ .instrument = 3, .rules_version = 1, .ticks = 42 },
    });
    try Impl.validate(config, state);
    if (state.cursor != 7 or state.observations != 1) return error.InvalidObservation;
    const saved = state;
    try std.testing.expectError(error.InvalidInput, Impl.onReferencePrice(config, &state, 7, .{
        .instrument = 3,
        .kind = .mark,
        .price = .{ .instrument = 3, .rules_version = 1, .ticks = 42 },
    }));
    try std.testing.expectEqualDeep(saved, state);
    try std.testing.expectError(error.InvalidConfig, Impl.create(.{ .instrument = 0, .max_observations = 2 }));
    std.debug.print("native_contract=passed definition={s} observations=1 output=none\n", .{definition.definition_identity});
}

test "native definition is located and exercised through its static registration" {
    try main();
}
