//! Projection probe: builds deterministic fixture journals through the core's
//! canonical genesis seam (or projects an externally supplied hex-encoded
//! segment) and prints the read-only JSON views consumed by the control plane.

const std = @import("std");
const trading = @import("trading_shard.zig");
const operational = @import("operational.zig");
const projection = @import("control_projection.zig");

const fixture_time_base: u64 = 1_000_000;

fn appendControlCommand(
    shard: *trading.TradingShard,
    journal: *trading.journal.Journal,
    identity: u64,
    command: operational.ControlCommand,
) !void {
    _ = try trading.applyStable(shard, journal, .{
        .identity = identity,
        .source_time = fixture_time_base,
        .receive_time = fixture_time_base,
        .monotonic_time = fixture_time_base,
        .wall_time = fixture_time_base,
        .time_presence = .{ .source = true, .receive = true, .monotonic = true, .wall = true },
        .payload = .{ .control_command = command },
    });
}

fn runDemo(writer: anytype) !void {
    const authorization: trading.host_gateway.Authorization = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 1,
        .activation_barrier = 0,
    };

    // Shard A: authorized, then operator kill switch revokes authority.
    var killed_shard: trading.TradingShard = .{};
    var killed_journal = trading.journal.Journal.init();
    try trading.applyCanonicalGenesis(&killed_shard, &killed_journal, authorization, .leveraged, 1);
    try appendControlCommand(&killed_shard, &killed_journal, 5000, .{
        .command_identity = 10,
        .content_hash = 10,
        .target_identity = 1,
        .expected_version = killed_shard.operational_state.version,
        .expires_at = std.math.maxInt(u64),
        .kind = .kill_switch,
        .referenced_latch_identity = 77,
    });

    // Shard B: plain genesis, still authorized.
    var live_shard: trading.TradingShard = .{};
    var live_journal = trading.journal.Journal.init();
    try trading.applyCanonicalGenesis(&live_shard, &live_journal, authorization, .leveraged, 1);

    try writer.writeAll("[");
    try projection.writeOutcomeJson(
        projection.projectJournal(killed_journal.bytes(), trading.contractDenominator(), .leveraged),
        writer,
    );
    try writer.writeAll(",");
    try projection.writeOutcomeJson(
        projection.projectJournal(live_journal.bytes(), trading.contractDenominator(), .leveraged),
        writer,
    );
    try writer.writeAll("]\n");
}

fn runProjectHexFile(io: std.Io, path: []const u8, writer: anytype) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var hex_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &hex_buffer);
    var hex: [32 * 1024]u8 = undefined;
    var hex_len: usize = 0;
    while (true) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n' or byte == '\r' or byte == ' ') continue;
        if (hex_len == hex.len) return error.HexTooLarge;
        hex[hex_len] = byte;
        hex_len += 1;
    }
    var bytes_buffer: [32 * 1024]u8 = undefined;
    const decoded_len = hex_len / 2;
    _ = std.fmt.hexToBytes(bytes_buffer[0..decoded_len], hex[0..hex_len]) catch return error.BadHex;
    try projection.writeOutcomeJson(
        projection.projectJournal(bytes_buffer[0..decoded_len], trading.contractDenominator(), .leveraged),
        writer,
    );
    try writer.writeAll("\n");
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse return error.ModeRequired;

    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;

    if (std.mem.eql(u8, mode, "demo")) {
        try runDemo(out);
    } else if (std.mem.eql(u8, mode, "dump")) {
        // Prints the fixture journal hex so consumers can exercise `project`.
        const authorization: trading.host_gateway.Authorization = .{
            .strategy_identity = 1,
            .config_version = 1,
            .activation_identity = 1,
            .activation_barrier = 0,
        };
        var shard: trading.TradingShard = .{};
        var journal = trading.journal.Journal.init();
        try trading.applyCanonicalGenesis(&shard, &journal, authorization, .leveraged, 1);
        var hex_buffer: [64 * 1024]u8 = undefined;
        var hex_len: usize = 0;
        const digits = "0123456789abcdef";
        for (journal.bytes()) |byte| {
            if (hex_len + 2 > hex_buffer.len) return error.HexTooLarge;
            hex_buffer[hex_len] = digits[byte >> 4];
            hex_buffer[hex_len + 1] = digits[byte & 0xF];
            hex_len += 2;
        }
        try out.print("{s}\n", .{hex_buffer[0..hex_len]});
    } else if (std.mem.eql(u8, mode, "project")) {
        const path = args.next() orelse return error.PathRequired;
        try runProjectHexFile(init.io, path, out);
    } else {
        return error.UnknownMode;
    }
    try out.flush();
}
