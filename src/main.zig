const std = @import("std");
const trading_shard = @import("trading_shard.zig");
const recovery_cutover = @import("recovery_cutover.zig");
const account_coordinator = @import("account_coordinator.zig");
const four_shard_acceptance = @import("four_shard_acceptance.zig");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--four-shard-acceptance"))
            return runFourShardAcceptanceEntry(init);
        return trading_shard.main(init);
    }
    return trading_shard.main(init);
}

fn runFourShardAcceptanceEntry(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    const evidence = try four_shard_acceptance.runFourShardAcceptance();
    try out.print(
        "four_shard_acceptance: shards={d}, replay=equivalent, recovery_paths=3\n",
        .{evidence.shard_digests.len},
    );
    for (evidence.shard_digests, 0..) |digest, index| {
        const hex = std.fmt.bytesToHex(digest, .lower);
        try out.print("shard_{d}: barrier={d}, digest={s}\n", .{ index, evidence.barrier, &hex });
    }
    const coordinator_hex = std.fmt.bytesToHex(evidence.coordinator_digest, .lower);
    const shared_hex = std.fmt.bytesToHex(evidence.shared_summary, .lower);
    try out.print("coordinator_digest={s}\n", .{&coordinator_hex});
    try out.print("shared_summary={s}\n", .{&shared_hex});
    try out.flush();
}

test {
    _ = trading_shard;
    _ = recovery_cutover;
    _ = account_coordinator;
    _ = four_shard_acceptance;
}
