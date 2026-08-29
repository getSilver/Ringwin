const std = @import("std");
const trading_shard = @import("trading_shard.zig");
const recovery_cutover = @import("recovery_cutover.zig");
const account_coordinator = @import("account_coordinator.zig");
const four_shard_acceptance = @import("four_shard_acceptance.zig");

pub fn main(init: std.process.Init) !void {
    return trading_shard.main(init);
}

test {
    _ = trading_shard;
    _ = recovery_cutover;
    _ = account_coordinator;
    _ = four_shard_acceptance;
}
