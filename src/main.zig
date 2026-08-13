const std = @import("std");
const trading_shard = @import("trading_shard.zig");
const recovery_cutover = @import("recovery_cutover.zig");

pub fn main(init: std.process.Init) !void {
    return trading_shard.main(init);
}

test {
    _ = trading_shard;
    _ = recovery_cutover;
}
