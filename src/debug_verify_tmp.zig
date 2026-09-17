const std = @import("std");
const channel = @import("control_channel.zig");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const hex_path = args.next() orelse return error.PathRequired;
    const key_hex = args.next() orelse return error.KeyRequired;

    var key: [channel.key_len]u8 = undefined;
    if (key_hex.len != channel.key_len * 2) return error.BadKeyLength;
    _ = std.fmt.hexToBytes(&key, key_hex) catch return error.BadKeyHex;

    var file = try std.Io.Dir.cwd().openFile(init.io, hex_path, .{ .mode = .read_only });
    defer file.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);
    var hex_buf: [1024]u8 = undefined;
    var hex_len: usize = 0;
    while (true) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n' or byte == '\r' or byte == ' ') continue;
        if (hex_len == hex_buf.len) return error.HexTooLarge;
        hex_buf[hex_len] = byte;
        hex_len += 1;
    }
    var frame: [4 + channel.envelope_len]u8 = undefined;
    _ = std.fmt.hexToBytes(frame[0 .. hex_len / 2], hex_buf[0..hex_len]) catch return error.BadHex;
    var decoded: [channel.envelope_len + 4]u8 = undefined;
    _ = std.fmt.hexToBytes(decoded[0 .. hex_len / 2], hex_buf[0..hex_len]) catch return error.BadHex;
    const payload = if (hex_len / 2 == channel.envelope_len)
        decoded[0..channel.envelope_len]
    else
        decoded[4 .. 4 + channel.envelope_len];

    var out_buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);
    const out = &stdout.interface;

    try out.print("hexlen={d} head={s}\n", .{ hex_len, hex_buf[0..16] });
    if (channel.verify(payload, &key)) |command| {
        try out.print("verify OK kind={s} target={d} version={d} latch={d}\n", .{
            @tagName(command.kind), command.target_identity,
            command.expected_version, command.referenced_latch_identity,
        });
        channel.checkExpiry(command, 1_000_000) catch
            try out.print("expiry: EXPIRED\n", .{});
    } else |err| {
        try out.print("verify err: {s} payload0={d} len={d}\n", .{ @errorName(err), payload[0], payload.len });
    }
    try out.flush();
}



