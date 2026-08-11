const std = @import("std");
const builtin = @import("builtin");

const Crc32c = std.hash.crc.Crc32Iscsi;
const header_len: usize = 256;
const slot_header_len: usize = 8;
const cache_line: usize = 64;
const batch_header_len: usize = 128;
const event_header_len: usize = 64;
const output_header_len: usize = 128;
const max_batch_len: usize = 1_048_576;
const max_event_count: u32 = 4_096;
const max_output_len: usize = 262_144;
const max_publish_many: u32 = 64;
const stale_batch_ns: i64 = 50_000_000;
const abi_version: u32 = 0x0001_0000;
const ring_magic = "QSHR".*;
const batch_magic = "QSHB".*;
const output_magic = "QSHO".*;

pub const Direction = enum(u32) { input = 1, output = 2 };

pub const Session = struct {
    fencing: u64,
    shard: u32,
    generation: u64,
};

pub const QshStatusV1 = enum(i32) {
    ok = 0,
    empty = 1,
    full = 2,
    stale = 3,
    session_expired = 4,
    invalid = 5,
    protocol_error = 6,
    closed = 7,
};

pub const QshBufferV1 = extern struct {
    data: ?[*]const u8,
    len: u32,
    reserved: u32,
};

const RingHeader = extern struct {
    magic: [4]u8,
    layout_version: u16,
    header_size: u16,
    direction: u32,
    slot_count: u32,
    slot_capacity: u32,
    slot_stride: u32,
    mapping_len: u64,
    fencing: u64,
    shard: u32,
    reserved0: [12]u8,
    generation: u64,
    producer: std.atomic.Value(u64),
    producer_padding: [56]u8,
    consumer: std.atomic.Value(u64),
    consumer_padding: [56]u8,
    lifecycle: std.atomic.Value(u32),
    reserved1: [60]u8,
};

comptime {
    std.debug.assert(@sizeOf(RingHeader) == header_len);
    std.debug.assert(@offsetOf(RingHeader, "producer") == 64);
    std.debug.assert(@offsetOf(RingHeader, "consumer") == 128);
    std.debug.assert(@offsetOf(RingHeader, "lifecycle") == 192);
}

const MappedBytes = []align(std.heap.page_size_min) u8;

pub const OwnedMapping = struct {
    raw: usize,
    bytes: MappedBytes,

    pub fn create(direction: Direction, session: Session, slot_count: u32, slot_capacity: u32) !OwnedMapping {
        if (slot_count < 2 or slot_capacity == 0) return error.InvalidRingDimensions;
        const stride = std.mem.alignForward(usize, slot_header_len + slot_capacity, cache_line);
        const len = std.math.add(usize, header_len, try std.math.mul(usize, slot_count, stride)) catch
            return error.MappingTooLarge;
        if (len > std.math.maxInt(u32)) return error.MappingTooLarge;

        var owned = try createAnonymous(len);
        errdefer owned.deinit();
        @memset(owned.bytes, 0);
        header(owned.bytes).* = .{
            .magic = ring_magic,
            .layout_version = 1,
            .header_size = header_len,
            .direction = @intFromEnum(direction),
            .slot_count = slot_count,
            .slot_capacity = slot_capacity,
            .slot_stride = @intCast(stride),
            .mapping_len = len,
            .fencing = session.fencing,
            .shard = session.shard,
            .reserved0 = @splat(0),
            .generation = session.generation,
            .producer = std.atomic.Value(u64).init(0),
            .producer_padding = @splat(0),
            .consumer = std.atomic.Value(u64).init(0),
            .consumer_padding = @splat(0),
            .lifecycle = std.atomic.Value(u32).init(0),
            .reserved1 = @splat(0),
        };
        return owned;
    }

    pub fn ring(self: *OwnedMapping, direction: Direction, session: Session) !Ring {
        return Ring.open(self.bytes, direction, session);
    }

    pub fn expire(self: *OwnedMapping) void {
        header(self.bytes).lifecycle.store(1, .release);
    }

    pub fn deinit(self: *OwnedMapping) void {
        self.expire();
        destroyAnonymous(self.raw, self.bytes);
        self.* = undefined;
    }
};

const Ring = struct {
    bytes: MappedBytes,
    h: *RingHeader,

    fn open(bytes: MappedBytes, direction: Direction, session: Session) !Ring {
        if (bytes.len < header_len) return error.InvalidMapping;
        const h = header(bytes);
        if (!std.mem.eql(u8, &h.magic, &ring_magic) or
            h.layout_version != 1 or
            h.header_size != header_len or
            h.direction != @intFromEnum(direction) or
            h.fencing != session.fencing or
            h.shard != session.shard or
            h.generation != session.generation)
            return error.SessionExpired;
        const expected = std.math.add(
            usize,
            header_len,
            std.math.mul(usize, h.slot_count, h.slot_stride) catch return error.InvalidMapping,
        ) catch return error.InvalidMapping;
        if (h.slot_count < 2 or h.slot_capacity == 0 or
            h.slot_stride < slot_header_len + h.slot_capacity or
            h.mapping_len != expected or expected != bytes.len)
            return error.InvalidMapping;
        if (h.lifecycle.load(.acquire) != 0) return error.Closed;
        return .{ .bytes = bytes, .h = h };
    }

    fn failClosed(self: Ring) void {
        self.h.lifecycle.store(1, .release);
    }

    fn cursors(self: Ring) !struct { producer: u64, consumer: u64 } {
        if (self.h.lifecycle.load(.acquire) != 0) return error.Closed;
        const producer = self.h.producer.load(.acquire);
        const consumer = self.h.consumer.load(.acquire);
        if (producer < consumer or producer - consumer > self.h.slot_count) {
            self.failClosed();
            return error.CorruptCursors;
        }
        return .{ .producer = producer, .consumer = consumer };
    }

    fn slot(self: Ring, sequence: u64) []u8 {
        const index: usize = @intCast(sequence % self.h.slot_count);
        const start = header_len + index * self.h.slot_stride;
        return self.bytes[start..][0..self.h.slot_stride];
    }

    pub fn tryPublishMany(self: Ring, buffers: []const []const u8) QshStatusV1 {
        if (buffers.len == 0 or buffers.len > max_publish_many) return .invalid;
        const cursors_now = self.cursors() catch |err| return statusForError(err);
        if (buffers.len > self.h.slot_count - (cursors_now.producer - cursors_now.consumer))
            return .full;
        for (buffers) |buffer| {
            if (buffer.len == 0 or buffer.len > self.h.slot_capacity) return .invalid;
        }
        for (buffers, 0..) |buffer, offset| {
            const slot_bytes = self.slot(cursors_now.producer + offset);
            put(u32, slot_bytes, 0, @intCast(buffer.len));
            put(u32, slot_bytes, 4, 0);
            @memcpy(slot_bytes[slot_header_len..][0..buffer.len], buffer);
        }
        self.h.producer.store(cursors_now.producer + buffers.len, .release);
        return .ok;
    }

    fn peek(self: Ring) union(enum) { status: QshStatusV1, bytes: []const u8 } {
        const cursors_now = self.cursors() catch |err| return .{ .status = statusForError(err) };
        if (cursors_now.producer == cursors_now.consumer) return .{ .status = .empty };
        const slot_bytes = self.slot(cursors_now.consumer);
        const len = get(u32, slot_bytes, 0);
        if (get(u32, slot_bytes, 4) != 0 or len == 0 or len > self.h.slot_capacity) {
            self.failClosed();
            return .{ .status = .protocol_error };
        }
        return .{ .bytes = slot_bytes[slot_header_len..][0..len] };
    }

    fn consume(self: Ring) void {
        const consumer = self.h.consumer.load(.monotonic);
        self.h.consumer.store(consumer + 1, .release);
    }

    pub fn tryRead(self: Ring, destination: []u8) QshStatusV1 {
        return switch (self.peek()) {
            .status => |status| status,
            .bytes => |bytes| if (destination.len < bytes.len)
                .invalid
            else blk: {
                @memcpy(destination[0..bytes.len], bytes);
                self.consume();
                break :blk .ok;
            },
        };
    }
};

pub const QshHandle = struct {
    input_mapping: MappedBytes,
    output_mapping: MappedBytes,
    input: Ring,
    output: Ring,
    session: Session,
    next_batch_sequence: u64 = 1,
    last_shard_sequence: ?u64 = null,
};

pub export fn qsh_abi_version() callconv(.c) u32 {
    return abi_version;
}

pub export fn qsh_open_v1(
    input_mapping: usize,
    output_mapping: usize,
    engine_fencing_token: u64,
    trading_shard_id: u32,
    host_generation: u64,
    out_handle: ?*?*QshHandle,
) callconv(.c) QshStatusV1 {
    const out = out_handle orelse return .invalid;
    out.* = null;
    if (input_mapping == 0 or output_mapping == 0 or input_mapping == output_mapping) return .invalid;
    const session: Session = .{
        .fencing = engine_fencing_token,
        .shard = trading_shard_id,
        .generation = host_generation,
    };
    const input_bytes = mapExisting(input_mapping) catch |err| return statusForError(err);
    errdefer unmapExisting(input_bytes);
    const output_bytes = mapExisting(output_mapping) catch |err| return statusForError(err);
    errdefer unmapExisting(output_bytes);
    const input = Ring.open(input_bytes, .input, session) catch |err| return statusForError(err);
    const output = Ring.open(output_bytes, .output, session) catch |err| return statusForError(err);
    const handle_value = std.heap.page_allocator.create(QshHandle) catch return .invalid;
    handle_value.* = .{
        .input_mapping = input_bytes,
        .output_mapping = output_bytes,
        .input = input,
        .output = output,
        .session = session,
    };
    out.* = handle_value;
    return .ok;
}

pub export fn qsh_read_input_v1(
    handle_value: ?*QshHandle,
    destination: ?[*]u8,
    destination_capacity: u32,
    out_len: ?*u32,
) callconv(.c) QshStatusV1 {
    const output_len = out_len orelse return .invalid;
    output_len.* = 0;
    const h = handle_value orelse return .invalid;
    const dst = destination orelse return .invalid;
    const item = switch (h.input.peek()) {
        .status => |status| return status,
        .bytes => |bytes| bytes,
    };
    const validation = validateBatch(item, h.session, h.next_batch_sequence, h.last_shard_sequence);
    if (validation.status != .ok) {
        h.input.failClosed();
        return validation.status;
    }
    if (destination_capacity < item.len) return .invalid;
    @memcpy(dst[0..item.len], item);
    h.input.consume();
    h.next_batch_sequence += 1;
    h.last_shard_sequence = validation.last_shard_sequence;
    output_len.* = @intCast(item.len);
    return .ok;
}

pub export fn qsh_publish_many_v1(
    handle_value: ?*QshHandle,
    frames: ?[*]const QshBufferV1,
    frame_count: u32,
) callconv(.c) QshStatusV1 {
    const h = handle_value orelse return .invalid;
    const source = frames orelse return .invalid;
    if (frame_count == 0 or frame_count > max_publish_many) return .invalid;
    var slices: [max_publish_many][]const u8 = undefined;
    for (source[0..frame_count], 0..) |descriptor, index| {
        if (descriptor.reserved != 0 or descriptor.data == null or descriptor.len == 0)
            return .invalid;
        const bytes = descriptor.data.?[0..descriptor.len];
        const status = validateOutput(bytes, h.session, h.next_batch_sequence - 1);
        if (status != .ok) {
            h.output.failClosed();
            return status;
        }
        slices[index] = bytes;
    }
    return h.output.tryPublishMany(slices[0..frame_count]);
}

pub export fn qsh_close_v1(handle_value: ?*QshHandle) callconv(.c) void {
    const h = handle_value orelse return;
    unmapExisting(h.input_mapping);
    unmapExisting(h.output_mapping);
    std.heap.page_allocator.destroy(h);
}

const BatchValidation = struct {
    status: QshStatusV1,
    last_shard_sequence: u64 = 0,
};

fn validateBatch(
    bytes: []const u8,
    session: Session,
    expected_batch_sequence: u64,
    previous_last_shard_sequence: ?u64,
) BatchValidation {
    const now = monotonicNowNs() catch return .{ .status = .protocol_error };
    return validateBatchAt(
        bytes,
        session,
        expected_batch_sequence,
        previous_last_shard_sequence,
        now,
    );
}

fn validateBatchAt(
    bytes: []const u8,
    session: Session,
    expected_batch_sequence: u64,
    previous_last_shard_sequence: ?u64,
    now: i64,
) BatchValidation {
    if (bytes.len < batch_header_len or bytes.len > max_batch_len or
        !std.mem.eql(u8, bytes[0..4], &batch_magic) or
        get(u16, bytes, 4) != 1 or get(u16, bytes, 6) != batch_header_len or
        get(u32, bytes, 8) != 0 or get(u32, bytes, 12) != bytes.len or
        get(u64, bytes, 48) != session.fencing or get(u32, bytes, 56) != session.shard or
        get(u32, bytes, 60) != 0 or get(u64, bytes, 64) != session.generation or
        get(u64, bytes, 72) != expected_batch_sequence or
        get(u32, bytes, 104) > max_event_count or
        get(u32, bytes, 108) != bytes.len - batch_header_len or
        !allZero(bytes[112..124]) or wireCrc(bytes) != get(u32, bytes, 124))
        return .{ .status = .protocol_error };

    const first = get(u64, bytes, 80);
    const last = get(u64, bytes, 88);
    if (first > last or (previous_last_shard_sequence != null and
        (previous_last_shard_sequence.? == std.math.maxInt(u64) or
            first != previous_last_shard_sequence.? + 1)))
        return .{ .status = .protocol_error };

    const published = get(i64, bytes, 96);
    if (published < 0 or now < published or now - published > stale_batch_ns)
        return .{ .status = .stale };

    var offset: usize = batch_header_len;
    var records: u32 = 0;
    var previous_sequence: ?u64 = null;
    while (offset < bytes.len) {
        if (bytes.len - offset < event_header_len) return .{ .status = .protocol_error };
        const record_len = get(u32, bytes, offset);
        const payload_len = get(u32, bytes, offset + 4);
        if (record_len < event_header_len or record_len % 8 != 0 or
            record_len > bytes.len - offset or
            payload_len > record_len - event_header_len or
            get(u32, bytes, offset + 12) & ~@as(u32, 0x1f) != 0 or
            get(u64, bytes, offset + 56) != 0 or
            !allZero(bytes[offset + event_header_len + payload_len .. offset + record_len]))
            return .{ .status = .protocol_error };
        const sequence = get(u64, bytes, offset + 16);
        if (sequence < first or sequence > last or
            (previous_sequence != null and sequence <= previous_sequence.?))
            return .{ .status = .protocol_error };
        previous_sequence = sequence;
        records += 1;
        offset += record_len;
    }
    if (offset != bytes.len or records != get(u32, bytes, 104))
        return .{ .status = .protocol_error };
    return .{ .status = .ok, .last_shard_sequence = last };
}

fn validateOutput(bytes: []const u8, session: Session, last_input_batch: u64) QshStatusV1 {
    if (bytes.len < output_header_len or bytes.len > max_output_len or
        !std.mem.eql(u8, bytes[0..4], &output_magic) or
        get(u16, bytes, 4) != 1 or get(u16, bytes, 6) != output_header_len or
        get(u32, bytes, 8) != 0 or get(u32, bytes, 12) != bytes.len or
        get(u64, bytes, 32) != session.fencing or get(u32, bytes, 40) != session.shard or
        get(u32, bytes, 44) != 0 or get(u64, bytes, 48) != session.generation or
        get(u64, bytes, 56) == 0 or get(u64, bytes, 56) > last_input_batch or
        get(u32, bytes, 100) == 0 or get(u32, bytes, 100) > 64 or
        get(u32, bytes, 104) != bytes.len - output_header_len or
        wireCrc(bytes) != get(u32, bytes, 124))
        return .protocol_error;
    return .ok;
}

fn wireCrc(bytes: []const u8) u32 {
    var crc = Crc32c.init();
    crc.update(bytes[0..124]);
    crc.update(bytes[128..]);
    return crc.final();
}

fn header(bytes: MappedBytes) *RingHeader {
    return @ptrCast(bytes.ptr);
}

fn put(comptime T: type, destination: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, destination[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, source: []const u8, offset: usize) T {
    return std.mem.readInt(T, source[offset..][0..@sizeOf(T)], .little);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn statusForError(err: anyerror) QshStatusV1 {
    return switch (err) {
        error.SessionExpired => .session_expired,
        error.Closed => .closed,
        error.InvalidMapping, error.CorruptCursors => .protocol_error,
        else => .invalid,
    };
}

fn makeBatch(destination: []u8, session: Session, batch_sequence: u64, shard_sequence: u64, now: i64) []u8 {
    const len = batch_header_len + event_header_len;
    @memset(destination[0..len], 0);
    @memcpy(destination[0..4], &batch_magic);
    put(u16, destination, 4, 1);
    put(u16, destination, 6, batch_header_len);
    put(u32, destination, 12, len);
    put(u128, destination, 16, 1);
    put(u128, destination, 32, 2);
    put(u64, destination, 48, session.fencing);
    put(u32, destination, 56, session.shard);
    put(u64, destination, 64, session.generation);
    put(u64, destination, 72, batch_sequence);
    put(u64, destination, 80, shard_sequence);
    put(u64, destination, 88, shard_sequence);
    put(i64, destination, 96, now);
    put(u32, destination, 104, 1);
    put(u32, destination, 108, event_header_len);
    put(u32, destination, 128, event_header_len);
    put(u16, destination, 136, 1);
    put(u16, destination, 138, 1);
    put(u64, destination, 144, shard_sequence);
    put(u32, destination, 124, wireCrc(destination[0..len]));
    return destination[0..len];
}

fn makeOutput(destination: []u8, session: Session, source_batch: u64, value: u8) []u8 {
    const len = output_header_len + 1;
    @memset(destination[0..len], 0);
    @memcpy(destination[0..4], &output_magic);
    put(u16, destination, 4, 1);
    put(u16, destination, 6, output_header_len);
    put(u32, destination, 12, len);
    put(u128, destination, 16, 1);
    put(u64, destination, 32, session.fencing);
    put(u32, destination, 40, session.shard);
    put(u64, destination, 48, session.generation);
    put(u64, destination, 56, source_batch);
    put(u128, destination, 64, 3);
    put(u64, destination, 80, 1);
    put(u64, destination, 88, 1);
    put(u16, destination, 96, 1);
    put(u16, destination, 98, 1);
    put(u32, destination, 100, 1);
    put(u32, destination, 104, 1);
    put(u128, destination, 108, 4);
    destination[128] = value;
    put(u32, destination, 124, wireCrc(destination[0..len]));
    return destination[0..len];
}

fn localChecks() !void {
    const session: Session = .{ .fencing = 41, .shard = 2, .generation = 7 };
    var input_mapping = try OwnedMapping.create(.input, session, 2, 512);
    defer input_mapping.deinit();
    var output_mapping = try OwnedMapping.create(.output, session, 2, 512);
    defer output_mapping.deinit();
    var input_owner = try input_mapping.ring(.input, session);
    var output_owner = try output_mapping.ring(.output, session);
    var host: ?*QshHandle = null;
    try expectStatus(.ok, qsh_open_v1(
        input_mapping.raw,
        output_mapping.raw,
        session.fencing,
        session.shard,
        session.generation,
        &host,
    ));
    defer qsh_close_v1(host);

    var batch_storage: [2][256]u8 = undefined;
    const now = try monotonicNowNs();
    const batch1 = makeBatch(&batch_storage[0], session, 1, 10, now);
    const batch2 = makeBatch(&batch_storage[1], session, 2, 11, now);
    try expectStatus(.ok, validateBatchAt(batch1, session, 1, null, now + stale_batch_ns).status);
    try expectStatus(.stale, validateBatchAt(batch1, session, 1, null, now + stale_batch_ns + 1).status);
    try expectStatus(.protocol_error, validateBatchAt(batch2, session, 1, null, now).status);
    try expectStatus(.protocol_error, validateBatchAt(batch2, session, 2, 9, now).status);
    try expectStatus(.ok, input_owner.tryPublishMany(&.{ batch1, batch2 }));
    try expectStatus(.full, input_owner.tryPublishMany(&.{batch1}));
    var read_buffer: [512]u8 = undefined;
    var read_len: u32 = 99;
    try expectStatus(.ok, qsh_read_input_v1(host, &read_buffer, read_buffer.len, &read_len));
    try std.testing.expectEqualSlices(u8, batch1, read_buffer[0..read_len]);
    try expectStatus(.ok, qsh_read_input_v1(host, &read_buffer, read_buffer.len, &read_len));
    try std.testing.expectEqualSlices(u8, batch2, read_buffer[0..read_len]);
    try expectStatus(.empty, qsh_read_input_v1(host, &read_buffer, read_buffer.len, &read_len));
    try std.testing.expectEqual(@as(u32, 0), read_len);

    var output_storage: [2][256]u8 = undefined;
    const output1 = makeOutput(&output_storage[0], session, 2, 11);
    const output2 = makeOutput(&output_storage[1], session, 2, 12);
    const descriptors = [_]QshBufferV1{
        .{ .data = output1.ptr, .len = @intCast(output1.len), .reserved = 0 },
        .{ .data = output2.ptr, .len = @intCast(output2.len), .reserved = 0 },
    };
    try expectStatus(.ok, qsh_publish_many_v1(host, &descriptors, descriptors.len));
    try expectStatus(.full, qsh_publish_many_v1(host, descriptors[0..1].ptr, 1));
    try expectStatus(.ok, output_owner.tryRead(&read_buffer));
    try std.testing.expectEqualSlices(u8, output1, read_buffer[0..output1.len]);
    try expectStatus(.ok, output_owner.tryRead(&read_buffer));
    try std.testing.expectEqualSlices(u8, output2, read_buffer[0..output2.len]);
    try expectStatus(.empty, output_owner.tryRead(&read_buffer));

    // Reuse the two physical slots several times to prove wrap-around.
    var sequence: u64 = 3;
    while (sequence < 9) : (sequence += 1) {
        const batch = makeBatch(&batch_storage[0], session, sequence, 9 + sequence, try monotonicNowNs());
        try expectStatus(.ok, input_owner.tryPublishMany(&.{batch}));
        try expectStatus(.ok, qsh_read_input_v1(host, &read_buffer, read_buffer.len, &read_len));
    }

    var corrupt_input = try OwnedMapping.create(.input, session, 2, 512);
    defer corrupt_input.deinit();
    var corrupt_output = try OwnedMapping.create(.output, session, 2, 512);
    defer corrupt_output.deinit();
    var corrupt_owner = try corrupt_input.ring(.input, session);
    var corrupt_host: ?*QshHandle = null;
    try expectStatus(.ok, qsh_open_v1(
        corrupt_input.raw,
        corrupt_output.raw,
        session.fencing,
        session.shard,
        session.generation,
        &corrupt_host,
    ));
    defer qsh_close_v1(corrupt_host);
    const corrupt_batch = makeBatch(&batch_storage[0], session, 1, 1, try monotonicNowNs());
    try expectStatus(.ok, corrupt_owner.tryPublishMany(&.{corrupt_batch}));
    corrupt_owner.slot(0)[slot_header_len + 128] ^= 1;
    try expectStatus(.protocol_error, qsh_read_input_v1(corrupt_host, &read_buffer, read_buffer.len, &read_len));
    try expectStatus(.closed, qsh_read_input_v1(corrupt_host, &read_buffer, read_buffer.len, &read_len));

    var old_input = try OwnedMapping.create(.input, .{ .fencing = 41, .shard = 2, .generation = 6 }, 2, 512);
    defer old_input.deinit();
    var old_output = try OwnedMapping.create(.output, .{ .fencing = 41, .shard = 2, .generation = 6 }, 2, 512);
    defer old_output.deinit();
    var old_host: ?*QshHandle = null;
    try expectStatus(.session_expired, qsh_open_v1(
        old_input.raw,
        old_output.raw,
        session.fencing,
        session.shard,
        session.generation,
        &old_host,
    ));
    try std.testing.expect(old_host == null);
}

fn childCheck(io: std.Io, input_raw: usize, output_raw: usize, session: Session) !void {
    // Keep process startup slower than the production stale boundary so this check proves
    // that batch age starts after Host readiness, not before a cold child launch.
    try std.Io.Clock.Duration.sleep(
        .{ .clock = .awake, .raw = .fromNanoseconds(75 * std.time.ns_per_ms) },
        io,
    );
    var host: ?*QshHandle = null;
    try expectStatus(.ok, qsh_open_v1(
        input_raw,
        output_raw,
        session.fencing,
        session.shard,
        session.generation,
        &host,
    ));
    defer qsh_close_v1(host);
    try std.Io.File.stdout().writeStreamingAll(io, "R");
    var batch: [512]u8 = undefined;
    var len: u32 = 0;
    while (true) {
        const status = qsh_read_input_v1(host, &batch, batch.len, &len);
        if (status == .ok) break;
        if (status != .empty) return expectStatus(.ok, status);
        std.Thread.yield() catch {};
    }
    var output_storage: [256]u8 = undefined;
    const output = makeOutput(&output_storage, session, 1, batch[136]);
    const descriptors = [_]QshBufferV1{.{
        .data = output.ptr,
        .len = @intCast(output.len),
        .reserved = 0,
    }};
    try expectStatus(.ok, qsh_publish_many_v1(host, &descriptors, 1));
}

fn crossProcessCheck(init: std.process.Init, executable: []const u8) !void {
    const session: Session = .{ .fencing = 91, .shard = 3, .generation = 12 };
    var input_mapping = try OwnedMapping.create(.input, session, 2, 512);
    defer input_mapping.deinit();
    var output_mapping = try OwnedMapping.create(.output, session, 2, 512);
    defer output_mapping.deinit();
    var input_owner = try input_mapping.ring(.input, session);
    var output_owner = try output_mapping.ring(.output, session);
    var batch_storage: [256]u8 = undefined;

    var raw_input_text: [32]u8 = undefined;
    var raw_output_text: [32]u8 = undefined;
    var fencing_text: [32]u8 = undefined;
    var shard_text: [16]u8 = undefined;
    var generation_text: [32]u8 = undefined;
    const argv = [_][]const u8{
        executable,
        "--child",
        try std.fmt.bufPrint(&raw_input_text, "{d}", .{input_mapping.raw}),
        try std.fmt.bufPrint(&raw_output_text, "{d}", .{output_mapping.raw}),
        try std.fmt.bufPrint(&fencing_text, "{d}", .{session.fencing}),
        try std.fmt.bufPrint(&shard_text, "{d}", .{session.shard}),
        try std.fmt.bufPrint(&generation_text, "{d}", .{session.generation}),
    };
    var child = try std.process.spawn(init.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
        .create_no_window = true,
    });
    var ready: [1]u8 = undefined;
    var ready_len: usize = 0;
    while (ready_len != ready.len) {
        const buffers = [_][]u8{ready[ready_len..]};
        ready_len += try child.stdout.?.readStreaming(init.io, &buffers);
    }
    if (ready[0] != 'R') return error.ChildNotReady;
    const batch = makeBatch(&batch_storage, session, 1, 1, try monotonicNowNs());
    try expectStatus(.ok, input_owner.tryPublishMany(&.{batch}));
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }
    var output: [512]u8 = undefined;
    try expectStatus(.ok, output_owner.tryRead(&output));
    try std.testing.expectEqual(@as(u8, 1), output[128]);
}

fn expectStatus(expected: QshStatusV1, actual: QshStatusV1) !void {
    if (expected != actual) {
        std.debug.print("expected status {s}, got {s}\n", .{ @tagName(expected), @tagName(actual) });
        return error.UnexpectedStatus;
    }
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    const executable = args.next() orelse return error.MissingExecutable;
    if (args.next()) |argument| {
        if (!std.mem.eql(u8, argument, "--child")) return error.UnknownArgument;
        const input_raw = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        const output_raw = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
        const session: Session = .{
            .fencing = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10),
            .shard = try std.fmt.parseInt(u32, args.next() orelse return error.MissingArgument, 10),
            .generation = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10),
        };
        if (args.next() != null) return error.UnknownArgument;
        return childCheck(init.io, input_raw, output_raw, session);
    }
    try localChecks();
    try crossProcessCheck(init, executable);
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print(
        "strategy_host_ipc: zig={s}, mode={s}, self_check=ok, cross_process=ok\n",
        .{ builtin.zig_version_string, @tagName(builtin.mode) },
    );
    try stdout.interface.flush();
}

test "bounded rings and frozen bridge fail closed" {
    try localChecks();
}

fn monotonicNowNs() !i64 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            const windows = std.os.windows;
            var counter: windows.LARGE_INTEGER = 0;
            var frequency: windows.LARGE_INTEGER = 0;
            if (!windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() or
                !windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or frequency <= 0)
                return error.ClockUnavailable;
            break :blk @intCast(@divTrunc(@as(i128, counter) * std.time.ns_per_s, frequency));
        },
        .linux => blk: {
            const linux = std.os.linux;
            var value: linux.timespec = undefined;
            if (std.posix.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS)
                return error.ClockUnavailable;
            break :blk @intCast(@as(i128, value.sec) * std.time.ns_per_s + value.nsec);
        },
        else => @compileError("StrategyHost IPC supports Linux and Windows only"),
    };
}

const SecurityAttributes = extern struct {
    length: u32,
    descriptor: ?*anyopaque,
    inherit: std.os.windows.BOOL,
};

extern "kernel32" fn CreateFileMappingW(
    file: std.os.windows.HANDLE,
    attributes: ?*SecurityAttributes,
    protection: u32,
    maximum_size_high: u32,
    maximum_size_low: u32,
    name: ?[*:0]const u16,
) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn MapViewOfFile(
    mapping: std.os.windows.HANDLE,
    desired_access: u32,
    offset_high: u32,
    offset_low: u32,
    bytes_to_map: usize,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(address: *const anyopaque) callconv(.winapi) std.os.windows.BOOL;
const MemoryBasicInformation = extern struct {
    base_address: ?*anyopaque,
    allocation_base: ?*anyopaque,
    allocation_protect: u32,
    partition_id: u16,
    region_size: usize,
    state: u32,
    protection: u32,
    kind: u32,
};
extern "kernel32" fn VirtualQuery(
    address: *const anyopaque,
    information: *MemoryBasicInformation,
    information_len: usize,
) callconv(.winapi) usize;

fn createAnonymous(len: usize) !OwnedMapping {
    return switch (builtin.os.tag) {
        .windows => blk: {
            var attributes: SecurityAttributes = .{
                .length = @sizeOf(SecurityAttributes),
                .descriptor = null,
                .inherit = .TRUE,
            };
            const handle_value = CreateFileMappingW(
                std.os.windows.INVALID_HANDLE_VALUE,
                &attributes,
                0x04,
                @intCast(@as(u64, len) >> 32),
                @truncate(len),
                null,
            ) orelse return error.MappingCreateFailed;
            errdefer std.os.windows.CloseHandle(handle_value);
            const pointer = MapViewOfFile(handle_value, 0x000F001F, 0, 0, len) orelse
                return error.MappingOpenFailed;
            const bytes = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(pointer)))[0..len];
            break :blk .{ .raw = @intFromPtr(handle_value), .bytes = bytes };
        },
        .linux => blk: {
            const fd = try std.posix.memfd_create("qsh-ring", 0);
            errdefer _ = std.os.linux.close(fd);
            if (std.posix.errno(std.os.linux.ftruncate(fd, @intCast(len))) != .SUCCESS)
                return error.MappingCreateFailed;
            const bytes = try std.posix.mmap(
                null,
                len,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .SHARED },
                fd,
                0,
            );
            break :blk .{ .raw = @intCast(fd), .bytes = bytes };
        },
        else => @compileError("StrategyHost IPC supports Linux and Windows only"),
    };
}

fn destroyAnonymous(raw: usize, bytes: MappedBytes) void {
    switch (builtin.os.tag) {
        .windows => {
            _ = UnmapViewOfFile(bytes.ptr);
            std.os.windows.CloseHandle(@ptrFromInt(raw));
        },
        .linux => {
            std.posix.munmap(bytes);
            _ = std.os.linux.close(@intCast(raw));
        },
        else => unreachable,
    }
}

fn mapExisting(raw: usize) !MappedBytes {
    return switch (builtin.os.tag) {
        .windows => blk: {
            const pointer = MapViewOfFile(@ptrFromInt(raw), 0x000F001F, 0, 0, 0) orelse
                return error.InvalidMapping;
            errdefer _ = UnmapViewOfFile(pointer);
            var information: MemoryBasicInformation = undefined;
            if (VirtualQuery(pointer, &information, @sizeOf(MemoryBasicInformation)) !=
                @sizeOf(MemoryBasicInformation))
                return error.InvalidMapping;
            const h: *const RingHeader = @ptrCast(@alignCast(pointer));
            if (h.mapping_len < header_len or h.mapping_len > information.region_size or
                h.mapping_len > std.math.maxInt(u32))
                return error.InvalidMapping;
            break :blk @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(pointer)))[0..@intCast(h.mapping_len)];
        },
        .linux => blk: {
            const fd: std.posix.fd_t = @intCast(raw);
            var information: std.os.linux.Statx = undefined;
            if (std.posix.errno(std.os.linux.statx(
                fd,
                "",
                std.os.linux.AT.EMPTY_PATH,
                .{ .SIZE = true },
                &information,
            )) != .SUCCESS or !information.mask.SIZE)
                return error.InvalidMapping;
            const mapping_len = information.size;
            if (mapping_len < header_len or mapping_len > std.math.maxInt(u32))
                return error.InvalidMapping;
            break :blk try std.posix.mmap(
                null,
                @intCast(mapping_len),
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .SHARED },
                fd,
                0,
            );
        },
        else => @compileError("StrategyHost IPC supports Linux and Windows only"),
    };
}

fn unmapExisting(bytes: MappedBytes) void {
    switch (builtin.os.tag) {
        .windows => _ = UnmapViewOfFile(bytes.ptr),
        .linux => std.posix.munmap(bytes),
        else => unreachable,
    }
}
