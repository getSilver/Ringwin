//! Bounded L2 evidence and conservative quotes. No execution or maker eligibility.
const std = @import("std");
const c = @import("canonical_event.zig");
pub const wire_len = 64 + 2 * c.max_depth_levels * 40;
pub const Side = enum { buy, sell };
pub const FeeAsset = enum { base, quote };
pub const Quote = struct { gross_lots: i128, base_lots: i128, quote_tick_lots: i128 };

pub fn validate(book: c.L2BookSnapshot) !void {
    const depth = book.depth orelse return error.MissingDepth;
    if (!book.complete) return error.IncompleteBookSnapshot;
    if (book.instrument == 0 or book.best_bid.instrument != book.instrument or book.best_ask.instrument != book.instrument or
        book.best_bid.rules_version == 0 or book.best_bid.rules_version != book.best_ask.rules_version)
        return error.InvalidDepthScope;
    if (depth.bid_count == 0 or depth.ask_count == 0) return error.IncompleteBookSnapshot;
    if (depth.bid_count > c.max_depth_levels or depth.ask_count > c.max_depth_levels) return error.DepthCapacityExceeded;
    try validateSide(&depth.bids, depth.bid_count, .sell);
    try validateSide(&depth.asks, depth.ask_count, .buy);
    if (depth.bids[0].ticks >= depth.asks[0].ticks or depth.bids[0].ticks != book.best_bid.ticks or depth.asks[0].ticks != book.best_ask.ticks)
        return error.InvalidDepthLevel;
    try validateTop(book.best_bid_quantity, book, depth.bids[0].lots);
    try validateTop(book.best_ask_quantity, book, depth.asks[0].lots);
    if (book.next_ask) |px| {
        if (depth.ask_count < 2 or px.instrument != book.instrument or px.rules_version != book.best_bid.rules_version or px.ticks != depth.asks[1].ticks) return error.InvalidDepthScope;
        try validateTop(book.next_ask_quantity, book, depth.asks[1].lots);
    } else if (book.next_ask_quantity != null) return error.InvalidDepthScope;
}
fn validateTop(quantity: ?c.InstrumentQuantity, book: c.L2BookSnapshot, lots: ?i128) !void {
    if (quantity) |q| {
        if (q.instrument != book.instrument or q.rules_version != book.best_bid.rules_version or lots == null or q.lots != lots.?) return error.InvalidDepthScope;
    } else if (lots != null) return error.InvalidDepthScope;
}
fn validateSide(levels: *const [c.max_depth_levels]c.DepthLevel, count: u8, side: Side) !void {
    for (levels, 0..) |level, i| {
        if (i >= count) {
            if (level.ticks != 0 or level.lots != null) return error.InvalidDepthTail;
            continue;
        }
        if (level.ticks <= 0 or (level.lots != null and level.lots.? < 0)) return error.InvalidDepthLevel;
        if (i != 0 and (if (side == .buy) level.ticks <= levels[i - 1].ticks else level.ticks >= levels[i - 1].ticks)) return error.InvalidDepthLevel;
    }
}
/// Quote currency is measured in price-tick * quantity-lot units. Fee rounds
/// against the taker; base_lots is net receipt (buy) or required debit (sell).
/// A zero level supplies zero; missing quantity cannot prove any consumption.
pub fn quote(book: c.L2BookSnapshot, side: Side, lots: i128, protection_ticks: i128, fee_ppm: u32, fee_asset: FeeAsset) !Quote {
    try validate(book);
    if (lots <= 0 or protection_ticks <= 0 or fee_ppm >= 1_000_000) return error.InvalidDepthRequest;
    const depth = book.depth.?;
    const levels = if (side == .buy) depth.asks[0..depth.ask_count] else depth.bids[0..depth.bid_count];
    var remaining = lots;
    var amount: i256 = 0;
    for (levels) |level| {
        if (remaining == 0) break;
        if (if (side == .buy) level.ticks > protection_ticks else level.ticks < protection_ticks) return error.InsufficientDepth;
        const available = level.lots orelse return error.InsufficientDepth;
        const used = @min(remaining, available);
        amount = std.math.add(i256, amount, @as(i256, used) * level.ticks) catch return error.DepthOverflow;
        remaining -= used;
    }
    if (remaining != 0) return error.InsufficientDepth;
    if (amount > std.math.maxInt(i128)) return error.DepthOverflow;
    const fee_basis: i256 = if (fee_asset == .base) lots else amount;
    const scaled_fee = std.math.mul(i256, fee_basis, fee_ppm) catch return error.DepthOverflow;
    const fee = @divTrunc(std.math.add(i256, scaled_fee, 999_999) catch return error.DepthOverflow, 1_000_000);
    const base: i256 = if (fee_asset == .base) (if (side == .buy) @as(i256, lots) - fee else @as(i256, lots) + fee) else lots;
    const quote_amount = if (fee_asset == .quote) (if (side == .buy) amount + fee else amount - fee) else amount;
    return .{ .gross_lots = lots, .base_lots = std.math.cast(i128, base) orelse return error.DepthOverflow, .quote_tick_lots = std.math.cast(i128, quote_amount) orelse return error.DepthOverflow };
}

pub fn encode(destination: []u8, book: c.L2BookSnapshot) ![]const u8 {
    try validate(book);
    if (destination.len < wire_len) return error.DepthCapacityExceeded;
    const bytes = destination[0..wire_len];
    @memset(bytes, 0);
    const depth = book.depth.?;
    put(u128, bytes, 0, book.instrument);
    put(u64, bytes, 16, book.best_bid.rules_version);
    put(u64, bytes, 24, book.sequence);
    put(u64, bytes, 32, depth.visible_at_ns);
    bytes[40] = depth.bid_count;
    bytes[41] = depth.ask_count;
    bytes[42] = @intFromBool(depth.bids_truncated);
    bytes[43] = @intFromBool(depth.asks_truncated);
    for ([_][c.max_depth_levels]c.DepthLevel{ depth.bids, depth.asks }, 0..) |levels, side| {
        for (levels, 0..) |level, i| {
            const offset = 64 + (side * c.max_depth_levels + i) * 40;
            put(i128, bytes, offset, level.ticks);
            bytes[offset + 16] = @intFromBool(level.lots != null);
            put(i128, bytes, offset + 24, level.lots orelse 0);
        }
    }
    return bytes;
}
pub fn decode(bytes: []const u8) !c.L2BookSnapshot {
    if (bytes.len != wire_len or bytes[42] > 1 or bytes[43] > 1 or !zero(bytes[44..64])) return error.InvalidDepthWire;
    var depth: c.BookDepth = .{ .visible_at_ns = get(u64, bytes, 32), .bid_count = bytes[40], .ask_count = bytes[41], .bids_truncated = bytes[42] == 1, .asks_truncated = bytes[43] == 1 };
    for (0..2) |side| for (0..c.max_depth_levels) |i| {
        const offset = 64 + (side * c.max_depth_levels + i) * 40;
        if (bytes[offset + 16] > 1 or !zero(bytes[offset + 17 .. offset + 24])) return error.InvalidDepthWire;
        const lots = get(i128, bytes, offset + 24);
        if (bytes[offset + 16] == 0 and lots != 0) return error.InvalidDepthWire;
        const level: c.DepthLevel = .{ .ticks = get(i128, bytes, offset), .lots = if (bytes[offset + 16] == 1) lots else null };
        if (side == 0) depth.bids[i] = level else depth.asks[i] = level;
    };
    const instrument = get(u128, bytes, 0);
    const rules = get(u64, bytes, 16);
    const book: c.L2BookSnapshot = .{ .instrument = instrument, .sequence = get(u64, bytes, 24), .depth = depth, .best_bid = .{ .instrument = instrument, .rules_version = rules, .ticks = depth.bids[0].ticks }, .best_ask = .{ .instrument = instrument, .rules_version = rules, .ticks = depth.asks[0].ticks }, .best_bid_quantity = if (depth.bids[0].lots) |n| .{ .instrument = instrument, .rules_version = rules, .lots = n } else null, .best_ask_quantity = if (depth.asks[0].lots) |n| .{ .instrument = instrument, .rules_version = rules, .lots = n } else null, .next_ask = if (depth.ask_count > 1) .{ .instrument = instrument, .rules_version = rules, .ticks = depth.asks[1].ticks } else null, .next_ask_quantity = if (depth.ask_count > 1 and depth.asks[1].lots != null) .{ .instrument = instrument, .rules_version = rules, .lots = depth.asks[1].lots.? } else null };
    try validate(book);
    return book;
}
fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
fn zero(bytes: []const u8) bool {
    for (bytes) |b| if (b != 0) return false;
    return true;
}
