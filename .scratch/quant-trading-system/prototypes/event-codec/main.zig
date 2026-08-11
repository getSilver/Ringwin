const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Crc32c = std.hash.crc.Crc32Iscsi;

const segment_header_len = 64;
const record_header_len = 56;
const segment_footer_len = 32;
const max_payload_len = 256;
const max_record_len = record_header_len + max_payload_len;

const segment_magic: u32 = 0x474c5351; // "QSLG"
const record_magic: u32 = 0x544e5651; // "QVNT"
const footer_magic: u32 = 0x444e4551; // "QEND"

const ScanStatus = enum { clean, truncated_tail };

const ScanResult = struct {
    status: ScanStatus,
    records: u64,
    last_seq: u64,
    valid_bytes: usize,
};

fn put(comptime T: type, dst: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, dst[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, src: []const u8, offset: usize) T {
    return std.mem.readInt(T, src[offset..][0..@sizeOf(T)], .little);
}

fn payloadLen(seq: u64) usize {
    const bucket = seq % 100;
    return if (bucket < 70) 32 else if (bucket < 95) 96 else 256;
}

fn encodeSegmentHeader(dst: []u8, first_seq: u64) []const u8 {
    const out = dst[0..segment_header_len];
    @memset(out, 0);
    put(u32, out, 0, segment_magic);
    put(u16, out, 4, 1);
    put(u16, out, 6, segment_header_len);
    put(u64, out, 8, 1);
    put(u64, out, 16, 1_700_000_000_000_000_000);
    put(u64, out, 24, first_seq);
    put(u32, out, 60, Crc32c.hash(out[0..60]));
    return out;
}

fn encodeRecord(dst: []u8, seq: u64) []const u8 {
    const payload_len = payloadLen(seq);
    const record_len = record_header_len + payload_len;
    const out = dst[0..record_len];
    @memset(out, 0);

    put(u32, out, 0, record_magic);
    put(u32, out, 4, @intCast(record_len));
    put(u16, out, 8, @intCast(1 + seq % 7));
    put(u16, out, 10, 1);
    put(u32, out, 12, 0);
    put(u64, out, 16, seq);
    put(u64, out, 24, 1_700_000_000_000_000_000 + seq);
    put(u64, out, 32, 1_700_000_000_000_001_000 + seq);
    put(u64, out, 40, 10_000_000 + seq);

    const payload = out[record_header_len..];
    for (payload, 0..) |*byte, i| byte.* = @truncate(seq +% i);
    put(u32, out, 48, Crc32c.hash(payload));
    put(u32, out, 52, Crc32c.hash(out[0..52]));
    return out;
}

fn encodeFooter(dst: []u8, records: u64, last_seq: u64) []const u8 {
    const out = dst[0..segment_footer_len];
    @memset(out, 0);
    put(u32, out, 0, footer_magic);
    put(u32, out, 4, segment_footer_len);
    put(u64, out, 8, records);
    put(u64, out, 16, last_seq);
    put(u32, out, 28, Crc32c.hash(out[0..28]));
    return out;
}

fn scan(bytes: []const u8) !ScanResult {
    if (bytes.len < segment_header_len) return .{
        .status = .truncated_tail,
        .records = 0,
        .last_seq = 0,
        .valid_bytes = 0,
    };
    const segment_header = bytes[0..segment_header_len];
    if (get(u32, segment_header, 0) != segment_magic or
        get(u16, segment_header, 4) != 1 or
        get(u16, segment_header, 6) != segment_header_len or
        get(u32, segment_header, 60) != Crc32c.hash(segment_header[0..60]))
        return error.InvalidSegmentHeader;

    var offset: usize = segment_header_len;
    var records: u64 = 0;
    var last_seq: u64 = 0;

    while (true) {
        if (bytes.len - offset >= segment_footer_len and
            get(u32, bytes[offset..], 0) == footer_magic)
        {
            const footer = bytes[offset..][0..segment_footer_len];
            if (get(u32, footer, 4) != segment_footer_len or
                get(u32, footer, 28) != Crc32c.hash(footer[0..28]) or
                get(u64, footer, 8) != records or
                get(u64, footer, 16) != last_seq)
                return error.InvalidSegmentFooter;
            return .{
                .status = .clean,
                .records = records,
                .last_seq = last_seq,
                .valid_bytes = offset + segment_footer_len,
            };
        }

        if (bytes.len - offset < record_header_len) return .{
            .status = .truncated_tail,
            .records = records,
            .last_seq = last_seq,
            .valid_bytes = offset,
        };

        const header = bytes[offset..][0..record_header_len];
        if (get(u32, header, 0) != record_magic) return error.InvalidRecordMagic;
        const record_len: usize = get(u32, header, 4);
        if (record_len < record_header_len or record_len > max_record_len)
            return error.InvalidRecordLength;
        if (bytes.len - offset < record_len) return .{
            .status = .truncated_tail,
            .records = records,
            .last_seq = last_seq,
            .valid_bytes = offset,
        };
        if (get(u32, header, 52) != Crc32c.hash(header[0..52]))
            return error.InvalidRecordHeaderChecksum;

        const seq = get(u64, header, 16);
        if (records != 0 and seq != last_seq + 1) return error.SequenceGap;
        const record = bytes[offset..][0..record_len];
        if (get(u32, header, 48) != Crc32c.hash(record[record_header_len..]))
            return error.InvalidPayloadChecksum;

        records += 1;
        last_seq = seq;
        offset += record_len;
    }
}

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn seconds(elapsed_ns: i96) f64 {
    return @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
}

fn printRate(out: *Io.Writer, name: []const u8, events: u64, bytes: usize, elapsed_ns: i96) !void {
    const elapsed = seconds(elapsed_ns);
    try out.print(
        "{s}: {d:.3}s, {d:.2} M events/s, {d:.2} MiB/s\n",
        .{
            name,
            elapsed,
            @as(f64, @floatFromInt(events)) / elapsed / 1_000_000.0,
            @as(f64, @floatFromInt(bytes)) / elapsed / 1024.0 / 1024.0,
        },
    );
}

fn selfCheck(allocator: std.mem.Allocator) !void {
    var segment: std.ArrayList(u8) = .empty;
    defer segment.deinit(allocator);
    var scratch: [max_record_len]u8 = undefined;

    const header = encodeSegmentHeader(&scratch, 1);
    try segment.appendSlice(allocator, header);
    for (1..6) |seq| {
        const record = encodeRecord(&scratch, seq);
        try segment.appendSlice(allocator, record);
    }
    try segment.appendSlice(allocator, encodeFooter(&scratch, 5, 5));

    const ok = try scan(segment.items);
    if (ok.status != .clean or ok.records != 5) return error.SelfCheckFailed;

    const truncated = try scan(segment.items[0 .. segment.items.len - 9]);
    if (truncated.status != .truncated_tail or truncated.records != 5)
        return error.SelfCheckFailed;

    segment.items[segment_header_len + record_header_len] ^= 1;
    if (scan(segment.items)) |_| return error.SelfCheckFailed else |err| {
        if (err != error.InvalidPayloadChecksum) return err;
    }
}

fn runBenchmark(
    io: Io,
    allocator: std.mem.Allocator,
    out: *Io.Writer,
    event_count: u64,
    path: []const u8,
) !void {
    try selfCheck(allocator);
    try out.print("self_check: ok\n", .{});

    var scratch: [max_record_len]u8 = undefined;
    var encoded_bytes: usize = 0;
    var checksum_sink: u32 = 0;
    const encode_start = now(io);
    for (1..event_count + 1) |seq| {
        const record = encodeRecord(&scratch, seq);
        encoded_bytes += record.len;
        checksum_sink +%= get(u32, record, 48);
    }
    const encode_elapsed = now(io) - encode_start;
    std.mem.doNotOptimizeAway(checksum_sink);
    try printRate(out, "encode_crc32c", event_count, encoded_bytes, encode_elapsed);

    const cwd = Io.Dir.cwd();
    const write_start = now(io);
    {
        const file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        var file_buffer: [256 * 1024]u8 = undefined;
        var writer = file.writer(io, &file_buffer);
        const file_out = &writer.interface;

        const segment_header = encodeSegmentHeader(&scratch, 1);
        try file_out.writeAll(segment_header);
        for (1..event_count + 1) |seq| {
            const record = encodeRecord(&scratch, seq);
            try file_out.writeAll(record);
        }
        try file_out.writeAll(encodeFooter(&scratch, event_count, event_count));
        try file_out.flush();
        try file.sync(io);
    }
    const write_elapsed = now(io) - write_start;
    const file_bytes = segment_header_len + encoded_bytes + segment_footer_len;
    try printRate(out, "encode_write_flush_sync", event_count, file_bytes, write_elapsed);

    const scan_start = now(io);
    const bytes = try cwd.readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    const recovered = try scan(bytes);
    const scan_elapsed = now(io) - scan_start;
    if (recovered.status != .clean or recovered.records != event_count)
        return error.RecoveryMismatch;
    try printRate(out, "read_full_recovery_scan", event_count, bytes.len, scan_elapsed);

    const truncated = try scan(bytes[0 .. bytes.len - 17]);
    if (truncated.status != .truncated_tail or truncated.records != event_count)
        return error.TruncatedTailNotRecovered;

    bytes[segment_header_len + record_header_len] ^= 1;
    const corruption_detected = if (scan(bytes)) |_| false else |err|
        err == error.InvalidPayloadChecksum;
    if (!corruption_detected) return error.CorruptionNotDetected;

    try out.print(
        "recovery_checks: truncated_tail=ok, single_byte_corruption=ok\nbytes_per_event: {d:.2}\n",
        .{@as(f64, @floatFromInt(file_bytes)) / @as(f64, @floatFromInt(event_count))},
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var event_count: u64 = 1_000_000;
    var path: []const u8 = ".scratch/quant-trading-system/prototypes/event-codec/benchmark.qlog";
    var keep = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--events")) {
            i += 1;
            if (i == args.len) return error.MissingEventCount;
            event_count = try std.fmt.parseUnsigned(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--path")) {
            i += 1;
            if (i == args.len) return error.MissingPath;
            path = args[i];
        } else if (std.mem.eql(u8, args[i], "--keep")) {
            keep = true;
        } else {
            return error.UnknownArgument;
        }
    }
    if (event_count == 0) return error.EventCountMustBePositive;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print(
        "event_codec_prototype: events={d}, zig={s}, mode={s}\n",
        .{ event_count, builtin.zig_version_string, @tagName(builtin.mode) },
    );
    try runBenchmark(io, allocator, out, event_count, path);
    try out.flush();

    if (!keep) Io.Dir.cwd().deleteFile(io, path) catch {};
}
