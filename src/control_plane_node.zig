//! Demo trading node: owns two fixture TradingShards on disk, pulls signed
//! commands from the control-plane channel, applies them through each shard's
//! authoritative journal, and persists the segments so the control plane's
//! read-only projection can tail them.
//!
//! Modes:
//!   setup <runtime_dir>              create genesis journals and exit
//!   serve <runtime_dir> <port> [ms]  pull/apply loop (default 500 ms)

const std = @import("std");
const trading = @import("trading_shard.zig");
const journal = @import("journal.zig");
const operational = @import("operational.zig");
const channel = @import("control_channel.zig");

const fixture_time_base: u64 = 1_000_000;
const contract_denominator: i64 = 10_000;

const ShardFixture = struct {
    target_identity: u128,
    file_name: []const u8,
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

fn writeJournalFile(io: std.Io, dir: std.Io.Dir, fixture: *ShardFixture) !void {
    var file = try dir.createFile(io, fixture.file_name, .{ .truncate = true });
    defer file.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.interface.writeAll(fixture.journal.bytes());
    try writer.interface.flush();
}

fn setup(io: std.Io, runtime_dir: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, runtime_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().createDirPathOpen(io, runtime_dir, .{}),
        else => return err,
    };
    defer dir.close(io);
    const authorization: trading.host_gateway.Authorization = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 1,
        .activation_barrier = 0,
    };
    var fixtures = [_]ShardFixture{
        .{ .target_identity = 1, .file_name = "shard-1.journal", .journal = trading.journal.Journal.init() },
        .{ .target_identity = 2, .file_name = "shard-2.journal", .journal = trading.journal.Journal.init() },
        .{ .target_identity = 3, .file_name = "shard-3.journal", .journal = trading.journal.Journal.init() },
        .{ .target_identity = 4, .file_name = "shard-4.journal", .journal = trading.journal.Journal.init() },
    };
    for (&fixtures) |*fixture| {
        try trading.applyCanonicalGenesis(&fixture.shard, &fixture.journal, authorization, .leveraged, fixture.target_identity);
        try writeJournalFile(io, dir, fixture);
    }
}

/// Rebuilds in-memory state from a persisted segment; shares the exact
/// recovery replay path.
fn loadFixture(io: std.Io, dir: std.Io.Dir, target_identity: u128, file_name: []const u8) !?ShardFixture {
    var file = dir.openFile(io, file_name, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var bytes: [64 * 1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (len == bytes.len) return error.JournalTooLarge;
        bytes[len] = byte;
        len += 1;
    }
    const replayed = try trading.replayForProjection(bytes[0..len], contract_denominator, .leveraged);
    var segment: trading.journal.Journal = .{};
    @memcpy(segment.storage[0..len], bytes[0..len]);
    segment.len = len;
    var scan = try journal.Reader.init(bytes[0..len]);
    while (true) {
        const next = try scan.next();
        switch (next) {
            .end => break,
            .record => |record| {
                segment.records += 1;
                segment.last_sequence = record.sequence;
            },
        }
    }
    return ShardFixture{
        .target_identity = target_identity,
        .file_name = file_name,
        .shard = replayed.shard,
        .journal = segment,
        // Continue input identities past anything already journaled.
        .next_identity = scan.last_sequence + 1000,
        .now = fixture_time_base + scan.last_sequence,
    };
}

fn maybeLifecycleProgress(fixture: *ShardFixture) !void {
    const operation_identity = fixture.shard.operational_state.active_operation_identity;
    if (operation_identity == 0) return;
    if (!fixture.shard.oms.openOrdersClosed()) return;
    if (fixture.shard.economicSummary().reconciliation_break) return;
    defer fixture.next_identity += 1;
    _ = try trading.applyStable(&fixture.shard, &fixture.journal, .{
        .identity = fixture.next_identity,
        .source_time = fixture.now,
        .receive_time = fixture.now,
        .monotonic_time = fixture.now,
        .wall_time = fixture.now,
        .time_presence = .{ .source = true, .receive = true, .monotonic = true, .wall = true },
        .payload = .{ .lifecycle_progress = .{
            .operation_identity = operation_identity,
            .target_identity = fixture.target_identity,
            .open_orders_closed = true,
            .reconciliation_complete = true,
            .position_quantity = fixture.shard.portfolio_position.quantity,
        } },
    });
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse return error.ModeRequired;
    const runtime_dir = args.next() orelse return error.RuntimeDirRequired;

    if (std.mem.eql(u8, mode, "setup")) {
        try setup(init.io, runtime_dir);
        return;
    }
    if (!std.mem.eql(u8, mode, "serve")) return error.UnknownMode;
    const port = std.fmt.parseInt(u16, args.next() orelse return error.PortRequired, 10) catch return error.BadPort;
    const poll_ms: u64 = if (args.next()) |v|
        std.fmt.parseInt(u64, v, 10) catch return error.BadInterval
    else
        500;

    var dir = try std.Io.Dir.cwd().openDir(init.io, runtime_dir, .{});
    defer dir.close(init.io);

    var fixtures = [_]ShardFixture{
        .{ .target_identity = 1, .file_name = "shard-1.journal", .journal = trading.journal.Journal.init() },
        .{ .target_identity = 2, .file_name = "shard-2.journal", .journal = trading.journal.Journal.init() },
        .{ .target_identity = 3, .file_name = "shard-3.journal", .journal = trading.journal.Journal.init() },
        .{ .target_identity = 4, .file_name = "shard-4.journal", .journal = trading.journal.Journal.init() },
    };
    var routes: [fixtures.len]channel.Route = undefined;
    for (&fixtures, 0..) |*fixture, index| {
        if (try loadFixture(init.io, dir, fixture.target_identity, fixture.file_name)) |loaded|
            fixture.* = loaded;
        routes[index] = .{ .target_identity = fixture.target_identity, .applier = fixture.applier() };
    }
    const router = channel.Router{ .routes = &routes };

    var key_hex_buffer: [64]u8 = undefined;
    const key_hex = init.environ_map.get("CONTROL_CHANNEL_KEY") orelse return error.ChannelKeyRequired;
    if (key_hex.len != 64) return error.BadKeyLength;
    @memcpy(&key_hex_buffer, key_hex);
    var key: [channel.key_len]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, &key_hex_buffer) catch return error.BadKeyHex;

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stdout_buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;
    try out.print("control_plane_node serving targets 1..4 poll={d}ms\n", .{poll_ms});
    try out.flush();

    var stats_total: channel.Stats = .{};
    while (true) {
        var stream = address.connect(init.io, .{ .mode = .stream, .protocol = .tcp }) catch {
            init.io.sleep(.{ .nanoseconds = poll_ms * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        defer stream.close(init.io);
        var stats: channel.Stats = .{};
        channel.pullOnce(init.io, stream, &key, fixture_time_base, &router, &stats) catch {};
        stats_total.accepted += stats.accepted;
        stats_total.duplicate += stats.duplicate;
        stats_total.expired += stats.expired;
        stats_total.rejected += stats.rejected;
        if (stats.accepted > 0 or stats.rejected > 0 or stats.expired > 0 or stats.duplicate > 0) {
            for (&fixtures) |*fixture| maybeLifecycleProgress(fixture) catch {};
            for (&fixtures) |*fixture| try writeJournalFile(init.io, dir, fixture);
            try out.print("poll accepted={d} duplicate={d} expired={d} rejected={d}\n", .{
                stats.accepted, stats.duplicate, stats.expired, stats.rejected,
            });
            try out.flush();
        }
        init.io.sleep(.{ .nanoseconds = poll_ms * std.time.ns_per_ms }, .awake) catch {};
    }
}



