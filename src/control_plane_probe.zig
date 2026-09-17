//! Probe host for the control-plane command channel acceptance: bootstraps
//! two TradingShards to trading mode, pulls signed command envelopes from
//! either the TCP control plane or an emergency drop directory, applies them
//! through each shard's authoritative journal, and prints a stable summary.

const std = @import("std");
const trading = @import("trading_shard.zig");
const channel = @import("control_channel.zig");

const fixture_time_base: u64 = 1_000_000;

const ShardFixture = struct {
    target_identity: u128,
    shard: trading.TradingShard = .{},
    journal: trading.journal.Journal,
    next_identity: u64 = 5000,
    now: u64 = fixture_time_base,

    fn applyCommand(self: *ShardFixture, command: channel.ControlCommand) anyerror!void {
        defer self.next_identity += 1;
        _ = try trading.applyStable(&self.shard, &self.journal, .{
            .identity = self.next_identity,
            .source_time = self.now,
            .receive_time = self.now,
            .monotonic_time = self.now,
            .wall_time = self.now,
            .time_presence = .{ .source = true, .receive = true, .monotonic = true, .wall = true },
            .payload = .{ .control_command = command },
        });
    }

    fn applier(self: *ShardFixture) channel.ShardApplier {
        return .{ .context = self, .apply = applierApply };
    }

    fn applierApply(context: *anyopaque, command: channel.ControlCommand) anyerror!void {
        const self: *ShardFixture = @ptrCast(@alignCast(context));
        return self.applyCommand(command);
    }
};

fn bootstrapTrading(fixture: *ShardFixture) !void {
    fixture.shard.fencing_token = 7;
    fixture.shard.risk_lease_micros = 100_000;
    try fixture.applyCommand(.{ .command_identity = 1, .content_hash = 1, .target_identity = fixture.target_identity, .expected_version = 0, .expires_at = std.math.maxInt(u64), .kind = .start_recovery });
    const recovery_identity = fixture.next_identity;
    fixture.next_identity += 1;
    _ = try trading.applyStable(&fixture.shard, &fixture.journal, .{
        .identity = recovery_identity,
        .source_time = fixture.now,
        .receive_time = fixture.now,
        .monotonic_time = fixture.now,
        .wall_time = fixture.now,
        .time_presence = .{ .source = true, .receive = true, .monotonic = true, .wall = true },
        .payload = .recovery_completed,
    });
    try fixture.applyCommand(.{ .command_identity = 2, .content_hash = 2, .target_identity = fixture.target_identity, .expected_version = 2, .expires_at = std.math.maxInt(u64), .kind = .enable_trading });
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse return error.ModeRequired;
    const location = args.next() orelse return error.LocationRequired;
    const key_hex = args.next() orelse return error.KeyRequired;

    var key: [channel.key_len]u8 = undefined;
    if (key_hex.len != channel.key_len * 2) return error.BadKeyLength;
    _ = std.fmt.hexToBytes(&key, key_hex) catch return error.BadKeyHex;

    var primary = ShardFixture{ .target_identity = 100, .journal = trading.journal.Journal.init() };
    var secondary = ShardFixture{ .target_identity = 200, .journal = trading.journal.Journal.init() };
    try bootstrapTrading(&primary);
    try bootstrapTrading(&secondary);

    var routes = [_]channel.Route{
        .{ .target_identity = primary.target_identity, .applier = primary.applier() },
        .{ .target_identity = secondary.target_identity, .applier = secondary.applier() },
    };
    const router = channel.Router{ .routes = &routes };
    var stats: channel.Stats = .{};
    const now = fixture_time_base + 5;

    if (std.mem.eql(u8, mode, "tcp")) {
        const port = std.fmt.parseInt(u16, location, 10) catch return error.BadPort;
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        var stream = try address.connect(init.io, .{ .mode = .stream, .protocol = .tcp });
        defer stream.close(init.io);
        try channel.pullOnce(init.io, stream, &key, now, &router, &stats);
    } else if (std.mem.eql(u8, mode, "dir")) {
        var dir = try std.Io.Dir.cwd().openDir(init.io, location, .{ .iterate = true });
        defer dir.close(init.io);
        try channel.drainDropDirectory(init.io, dir, &key, now, &router, &stats);
    } else {
        return error.UnknownMode;
    }

    var buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    try out.print("control_plane_probe accepted={d} duplicate={d} expired={d} rejected={d} authority_100={} authority_200={}\n", .{
        stats.accepted,
        stats.duplicate,
        stats.expired,
        stats.rejected,
        primary.shard.operational_state.effectiveTradingAuthority(),
        secondary.shard.operational_state.effectiveTradingAuthority(),
    });
    try out.flush();
}
