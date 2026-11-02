//! Public tape wire contract for Host input, without account or Fill semantics.
const std = @import("std");
const c = @import("../model/canonical_event.zig");
pub const wire_len = 96;

pub fn encode(destination: []u8, trade: c.MarketTrade) ![]const u8 {
    try trade.validate();
    if (destination.len < wire_len) return error.NoSpaceLeft;
    const bytes = destination[0..wire_len];
    @memset(bytes, 0);
    std.mem.writeInt(u128, bytes[0..16], trade.instrument, .little);
    std.mem.writeInt(u128, bytes[16..32], trade.trade_identity, .little);
    std.mem.writeInt(u64, bytes[32..40], trade.price.rules_version, .little);
    std.mem.writeInt(i128, bytes[40..56], trade.price.ticks, .little);
    std.mem.writeInt(i128, bytes[56..72], trade.quantity.lots, .little);
    std.mem.writeInt(u64, bytes[72..80], trade.source_time_utc_ns, .little);
    bytes[80] = if (trade.side == .buy) 0 else 1;
    return bytes;
}

pub fn decode(bytes: []const u8) !c.MarketTrade {
    if (bytes.len != wire_len or bytes[80] > 1) return error.InvalidMarketTrade;
    for (bytes[81..]) |byte| if (byte != 0) return error.InvalidMarketTrade;
    const instrument = std.mem.readInt(u128, bytes[0..16], .little);
    const version = std.mem.readInt(u64, bytes[32..40], .little);
    const trade: c.MarketTrade = .{
        .instrument = instrument,
        .trade_identity = std.mem.readInt(u128, bytes[16..32], .little),
        .price = .{ .instrument = instrument, .rules_version = version, .ticks = std.mem.readInt(i128, bytes[40..56], .little) },
        .quantity = .{ .instrument = instrument, .rules_version = version, .lots = std.mem.readInt(i128, bytes[56..72], .little) },
        .source_time_utc_ns = std.mem.readInt(u64, bytes[72..80], .little),
        .side = if (bytes[80] == 0) .buy else .sell,
    };
    try trade.validate();
    return trade;
}

test "public trade wire rejects malformed evidence without Fill semantics" {
    const trade: c.MarketTrade = .{ .instrument = 10, .trade_identity = 99, .price = .{ .instrument = 10, .rules_version = 3, .ticks = 123 }, .quantity = .{ .instrument = 10, .rules_version = 3, .lots = 7 }, .side = .buy, .source_time_utc_ns = 1000 };
    var bytes: [wire_len]u8 = undefined;
    try std.testing.expectEqualDeep(trade, try decode(try encode(&bytes, trade)));
    bytes[81] = 1;
    try std.testing.expectError(error.InvalidMarketTrade, decode(&bytes));
}
