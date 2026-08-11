const std = @import("std");

const Crc32c = std.hash.crc.Crc32Iscsi;
const segment_magic: u32 = 0x474c5351; // QSLG
const record_magic: u32 = 0x544e5651; // QVNT
const footer_magic: u32 = 0x444e4551; // QEND
const segment_header_len = 64;
const record_header_len = 72;
const footer_len = 32;
const max_payload_len = 2048;

pub const input_flag: u32 = 1;
pub const segment_header_size = segment_header_len;
pub const record_header_size = record_header_len;

pub const Record = struct {
    type_id: u16,
    schema_version: u16,
    flags: u32,
    sequence: u64,
    source_time: u64,
    receive_time: u64,
    monotonic_time: u64,
    wall_time: u64,
    time_presence: TimePresence,
    payload: []const u8,
};

pub const TimePresence = packed struct(u8) {
    source: bool = false,
    receive: bool = false,
    monotonic: bool = false,
    wall: bool = false,
    reserved: u4 = 0,
};

pub const ScanStatus = enum { clean, truncated_tail };

pub const Next = union(enum) {
    record: Record,
    end: ScanStatus,
};

fn put(comptime T: type, destination: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, destination[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, source: []const u8, offset: usize) T {
    return std.mem.readInt(T, source[offset..][0..@sizeOf(T)], .little);
}

pub const Journal = struct {
    storage: [16 * 1024]u8 = undefined,
    len: usize = segment_header_len,
    records: u64 = 0,
    last_sequence: u64 = 0,
    sealed: bool = false,

    pub fn init() Journal {
        var self: Journal = .{};
        const header = self.storage[0..segment_header_len];
        @memset(header, 0);
        put(u32, header, 0, segment_magic);
        put(u16, header, 4, 2);
        put(u16, header, 6, segment_header_len);
        put(u64, header, 8, 1);
        put(u64, header, 24, 1);
        put(u32, header, 60, Crc32c.hash(header[0..60]));
        return self;
    }

    pub fn append(self: *Journal, record: Record) !void {
        if (self.sealed) return error.JournalSealed;
        if (record.payload.len > max_payload_len) return error.PayloadTooLarge;
        if (record.sequence != self.last_sequence + 1) return error.SequenceGap;

        const record_len = record_header_len + record.payload.len;
        if (self.storage.len - self.len < record_len + footer_len) return error.JournalFull;
        const encoded = self.storage[self.len..][0..record_len];
        @memset(encoded[0..record_header_len], 0);
        put(u32, encoded, 0, record_magic);
        put(u32, encoded, 4, @intCast(record_len));
        put(u16, encoded, 8, record.type_id);
        put(u16, encoded, 10, record.schema_version);
        put(u32, encoded, 12, record.flags);
        put(u64, encoded, 16, record.sequence);
        put(u64, encoded, 24, record.source_time);
        put(u64, encoded, 32, record.receive_time);
        put(u64, encoded, 40, record.monotonic_time);
        put(u64, encoded, 48, record.wall_time);
        encoded[56] = @bitCast(record.time_presence);
        @memcpy(encoded[record_header_len..], record.payload);
        put(u32, encoded, 64, Crc32c.hash(encoded[record_header_len..]));
        put(u32, encoded, 68, Crc32c.hash(encoded[0..68]));

        self.len += record_len;
        self.records += 1;
        self.last_sequence = record.sequence;
    }

    pub fn seal(self: *Journal) !void {
        if (self.sealed) return error.JournalSealed;
        if (self.storage.len - self.len < footer_len) return error.JournalFull;
        const footer = self.storage[self.len..][0..footer_len];
        @memset(footer, 0);
        put(u32, footer, 0, footer_magic);
        put(u32, footer, 4, footer_len);
        put(u64, footer, 8, self.records);
        put(u64, footer, 16, self.last_sequence);
        put(u32, footer, 28, Crc32c.hash(footer[0..28]));
        self.len += footer_len;
        self.sealed = true;
    }

    pub fn bytes(self: *const Journal) []const u8 {
        return self.storage[0..self.len];
    }
};

pub const Reader = struct {
    bytes: []const u8,
    offset: usize = segment_header_len,
    records: u64 = 0,
    last_sequence: u64 = 0,
    next_sequence: u64,
    done: bool = false,

    pub fn init(bytes: []const u8) !Reader {
        if (bytes.len < segment_header_len) return error.TruncatedSegmentHeader;
        const header = bytes[0..segment_header_len];
        if (get(u32, header, 0) != segment_magic or
            get(u16, header, 4) != 2 or
            get(u16, header, 6) != segment_header_len or
            get(u32, header, 60) != Crc32c.hash(header[0..60]))
            return error.InvalidSegmentHeader;
        const first_sequence = get(u64, header, 24);
        if (first_sequence == 0) return error.InvalidFirstSequence;
        return .{
            .bytes = bytes,
            .next_sequence = first_sequence,
            .last_sequence = first_sequence - 1,
        };
    }

    pub fn next(self: *Reader) !Next {
        if (self.done) return error.ReaderFinished;
        const remaining = self.bytes.len - self.offset;
        if (remaining == 0) {
            self.done = true;
            return .{ .end = .truncated_tail };
        }

        if (remaining >= 4 and get(u32, self.bytes[self.offset..], 0) == footer_magic) {
            if (remaining < footer_len) {
                self.done = true;
                return .{ .end = .truncated_tail };
            }
            const footer = self.bytes[self.offset..][0..footer_len];
            if (get(u32, footer, 4) != footer_len or
                get(u64, footer, 8) != self.records or
                get(u64, footer, 16) != self.last_sequence or
                get(u32, footer, 28) != Crc32c.hash(footer[0..28]))
                return error.InvalidFooter;
            self.offset += footer_len;
            self.done = true;
            return .{ .end = .clean };
        }

        if (remaining < record_header_len) {
            self.done = true;
            return .{ .end = .truncated_tail };
        }
        const header = self.bytes[self.offset..][0..record_header_len];
        if (get(u32, header, 0) != record_magic) return error.InvalidRecordMagic;
        const encoded_len: usize = get(u32, header, 4);
        if (encoded_len < record_header_len or encoded_len > record_header_len + max_payload_len)
            return error.InvalidRecordLength;
        if (remaining < encoded_len) {
            self.done = true;
            return .{ .end = .truncated_tail };
        }
        if (get(u32, header, 68) != Crc32c.hash(header[0..68]))
            return error.InvalidHeaderChecksum;

        const sequence = get(u64, header, 16);
        if (sequence != self.next_sequence) return error.SequenceGap;
        const encoded = self.bytes[self.offset..][0..encoded_len];
        const payload = encoded[record_header_len..];
        if (get(u32, header, 64) != Crc32c.hash(payload))
            return error.InvalidPayloadChecksum;

        const record: Record = .{
            .type_id = get(u16, header, 8),
            .schema_version = get(u16, header, 10),
            .flags = get(u32, header, 12),
            .sequence = sequence,
            .source_time = get(u64, header, 24),
            .receive_time = get(u64, header, 32),
            .monotonic_time = get(u64, header, 40),
            .wall_time = get(u64, header, 48),
            .time_presence = @bitCast(header[56]),
            .payload = payload,
        };
        self.offset += encoded_len;
        self.records += 1;
        self.last_sequence = sequence;
        self.next_sequence += 1;
        return .{ .record = record };
    }
};

pub fn selfCheck() !void {
    const first_payload = [_]u8{ 1, 2 };
    const second_payload = [_]u8{3};
    var journal = Journal.init();
    try journal.append(.{
        .type_id = 1,
        .schema_version = 1,
        .flags = input_flag,
        .sequence = 1,
        .source_time = 10,
        .receive_time = 11,
        .monotonic_time = 12,
        .wall_time = 13,
        .time_presence = .{ .source = true, .receive = true, .monotonic = true, .wall = true },
        .payload = &first_payload,
    });
    try journal.append(.{
        .type_id = 2,
        .schema_version = 1,
        .flags = 0,
        .sequence = 2,
        .source_time = 10,
        .receive_time = 11,
        .monotonic_time = 12,
        .wall_time = 13,
        .time_presence = .{ .source = true, .receive = true, .monotonic = true, .wall = true },
        .payload = &second_payload,
    });
    try journal.seal();

    var clean = try Reader.init(journal.bytes());
    if ((try clean.next()) != .record or (try clean.next()) != .record or
        (try clean.next()).end != .clean)
        return error.CleanScanFailed;

    var truncated = try Reader.init(journal.bytes()[0 .. journal.len - 1]);
    if ((try truncated.next()) != .record or (try truncated.next()) != .record or
        (try truncated.next()).end != .truncated_tail)
        return error.TruncatedTailNotDetected;

    var corrupted = journal;
    corrupted.storage[segment_header_len + record_header_len] ^= 1;
    var corrupt_reader = try Reader.init(corrupted.bytes());
    if (corrupt_reader.next()) |_| return error.CorruptionNotDetected else |err| {
        if (err != error.InvalidPayloadChecksum) return err;
    }

    var gap = journal;
    const second_offset = segment_header_len + record_header_len + first_payload.len;
    put(u64, gap.storage[second_offset..], 16, 3);
    put(
        u32,
        gap.storage[second_offset..],
        68,
        Crc32c.hash(gap.storage[second_offset..][0..68]),
    );
    var gap_reader = try Reader.init(gap.bytes());
    _ = try gap_reader.next();
    if (gap_reader.next()) |_| return error.SequenceGapNotDetected else |err| {
        if (err != error.SequenceGap) return err;
    }
}

test "stable journal detects tail, corruption, and sequence gap" {
    try selfCheck();
}
