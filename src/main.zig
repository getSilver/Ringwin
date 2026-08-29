const std = @import("std");
const trading_shard = @import("trading_shard.zig");
const recovery_cutover = @import("recovery_cutover.zig");
const account_coordinator = @import("account_coordinator.zig");
const four_shard_acceptance = @import("four_shard_acceptance.zig");
const canonical_event = @import("canonical_event.zig");
const market_feed_adapter = @import("market_feed_adapter.zig");
const simulated_venue = @import("simulated_venue.zig");
const venue_adapter_contract = @import("venue_adapter_contract.zig");
const simulated_lifecycle_projection = @import("simulated_lifecycle_projection.zig");
const execution_gateway = @import("execution_gateway.zig");
const simulated_market_feed = @import("simulated_market_feed.zig");
const market_projection = @import("market_projection.zig");
const account_projection = @import("account_projection.zig");
const okx_market_feed = @import("okx_market_feed.zig");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    if (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--four-shard-acceptance"))
            return runFourShardAcceptanceEntry(init);
        return error.UnknownArgument;
    }
    return trading_shard.main(init);
}

fn runFourShardAcceptanceEntry(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    const evidence = try four_shard_acceptance.runFourShardAcceptance();
    try out.print(
        "four_shard_acceptance: schema={d}, shards={d}, replay=equivalent, recovery_paths=3\n",
        .{ evidence.schema_version, evidence.shard_digests.len },
    );
    for (evidence.shard_digests, 0..) |digest, index| {
        const hex = std.fmt.bytesToHex(digest, .lower);
        try out.print("shard_{d}: barrier={d}, digest={s}\n", .{ index, evidence.shard_barriers[index], &hex });
    }
    const coordinator_hex = std.fmt.bytesToHex(evidence.coordinator_digest, .lower);
    const shared_hex = std.fmt.bytesToHex(evidence.shared_summary, .lower);
    try out.print("coordinator_barrier={d}, coordinator_digest={s}\n", .{ evidence.coordinator_barrier, &coordinator_hex });
    try out.print("shared_summary={s}\n", .{&shared_hex});
    try out.print(
        "side_effects: live_gateway_submissions={d}, replay_send_capability={}\n",
        .{ evidence.live_gateway_submissions, evidence.replay_send_capability },
    );
    try out.flush();
}

test {
    _ = trading_shard;
    _ = recovery_cutover;
    _ = account_coordinator;
    _ = four_shard_acceptance;
    _ = canonical_event;
    _ = market_feed_adapter;
    _ = simulated_venue;
    _ = venue_adapter_contract;
    _ = simulated_lifecycle_projection;
    _ = execution_gateway;
    _ = simulated_market_feed;
    _ = market_projection;
    _ = account_projection;
    _ = okx_market_feed;
}
