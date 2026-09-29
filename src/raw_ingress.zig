//! Durable byte-preserving RawIngress sink.  It is deliberately independent
//! of any Venue decoder: adapters record a route, metadata and original bytes;
//! restart code chooses the same adapter entry point to parse them again.

const std = @import("std");
const builtin = @import("builtin");
const durable = @import("durable_store.zig");
const journal = @import("journal.zig");
const market = @import("okx_public_market.zig");
const production_contract = @import("production_contract.zig");

const schema_version: u16 = 1;
const record_type: u16 = 0x5249; // RI
const header_bytes = 72;

pub const max_frame_bytes = journal.max_payload_size - header_bytes;

pub const DurableSink = struct {
    store: durable.Store,
    io: std.Io,
    stream: durable.StreamIdentity,
    next_sequence: u64 = 1,
    segment_bytes: usize = journal.segment_header_size,

    pub fn init(store: durable.Store, io: std.Io, stream: durable.StreamIdentity) !DurableSink {
        if (stream.domain != .raw_ingress or stream.id == 0 or store.safetyGate() != .open)
            return error.RawIngressUnavailable;
        return .{ .store = store, .io = io, .stream = stream };
    }

    pub fn recover(store: durable.Store, io: std.Io, stream: durable.StreamIdentity) !DurableSink {
        if (stream.domain != .raw_ingress or stream.id == 0 or store.safetyGate() != .open)
            return error.RawIngressUnavailable;
        const recovered = store.recover(io, stream) catch return error.RawIngressUnavailable;
        if (recovered.gate != .open or recovered.last_sequence != recovered.committed_barrier)
            return error.RawIngressUnavailable;
        return .{ .store = store, .io = io, .stream = stream, .next_sequence = std.math.add(u64, recovered.last_sequence, 1) catch return error.RawIngressUnavailable, .segment_bytes = if (recovered.tail.len == 0) journal.segment_header_size else recovered.tail.len };
    }

    pub fn interface(self: *DurableSink) market.RawSink {
        return .{ .ptr = self, .append_fn = append };
    }

    fn append(ptr: *anyopaque, record: market.RawIngressRecord, bytes: []const u8) market.RawSinkError!u64 {
        const self: *DurableSink = @ptrCast(@alignCast(ptr));
        if (bytes.len > max_frame_bytes or bytes.len > std.math.maxInt(u32) or
            record.byte_len != @as(u32, @intCast(bytes.len)) or self.store.safetyGate() != .open)
            return error.Unavailable;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &record.sha256)) return error.Unavailable;

        var payload: [journal.max_payload_size]u8 = undefined;
        put(u16, &payload, 0, schema_version);
        put(u16, &payload, 2, record.origin);
        put(u32, &payload, 4, record.byte_len);
        put(u64, &payload, 8, record.source_session);
        put(u64, &payload, 16, record.receive_time_utc_ns);
        put(u64, &payload, 24, record.monotonic_time_ns);
        put(u64, &payload, 32, record.wall_time_utc_ns);
        @memcpy(payload[40..72], &record.sha256);
        @memcpy(payload[header_bytes..][0..bytes.len], bytes);
        const encoded_length = journal.record_header_size + header_bytes + bytes.len;
        if (self.segment_bytes + encoded_length + journal.footer_size > durable.max_segment_bytes) {
            if (!self.store.supportsSegmentReplay() or self.next_sequence == 1) return error.Unavailable;
            self.store.seal(self.io, self.stream) catch return error.Unavailable;
            var checkpoint: [8]u8 = undefined;
            std.mem.writeInt(u64, &checkpoint, self.next_sequence - 1, .little);
            self.store.publishSnapshot(self.io, self.stream, self.next_sequence - 1, &checkpoint) catch return error.Unavailable;
            self.store.rotate(self.io, self.stream) catch return error.Unavailable;
            self.segment_bytes = journal.segment_header_size;
        }
        const sequence = self.next_sequence;
        self.store.append(self.io, .{ .stream = self.stream, .record = .{
            .type_id = record_type,
            .schema_version = production_contract.journal_schema_version,
            .flags = journal.input_flag,
            .sequence = sequence,
            .source_time = 0,
            .receive_time = record.receive_time_utc_ns,
            .monotonic_time = record.monotonic_time_ns,
            .wall_time = record.wall_time_utc_ns,
            .time_presence = .{ .receive = true, .monotonic = true, .wall = true },
            .payload = payload[0 .. header_bytes + bytes.len],
        } }) catch return error.Unavailable;
        self.store.commit(self.io, self.stream, sequence) catch return error.Unavailable;
        self.next_sequence = std.math.add(u64, sequence, 1) catch return error.Unavailable;
        self.segment_bytes += encoded_length;
        return sequence;
    }
};

pub const ReplayConsumer = struct {
    ptr: *anyopaque,
    consume_fn: *const fn (*anyopaque, u64, market.RawIngressRecord, []const u8) anyerror!void,

    pub fn consume(self: ReplayConsumer, sequence: u64, record: market.RawIngressRecord, bytes: []const u8) !void {
        return self.consume_fn(self.ptr, sequence, record, bytes);
    }
};

pub fn replayCommitted(store: durable.Store, io: std.Io, stream: durable.StreamIdentity, consumer: ReplayConsumer) !void {
    if (stream.domain != .raw_ingress or store.safetyGate() != .open) return error.RawIngressUnavailable;
    const recovered = try store.recover(io, stream);
    if (recovered.gate != .open or recovered.last_sequence == 0 or recovered.last_sequence != recovered.committed_barrier)
        return error.RawIngressUnavailable;
    const Walker = struct {
        consumer: ReplayConsumer,
        next_sequence: u64 = 1,
        fn segment(ptr: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var reader = try journal.Reader.init(bytes);
            while (true) switch (try reader.next()) {
                .end => break,
                .record => |entry| {
                    if (entry.sequence != self.next_sequence) return error.InvalidRawIngress;
                    if (entry.type_id != record_type or entry.schema_version != production_contract.journal_schema_version or entry.payload.len < header_bytes)
                        return error.InvalidRawIngress;
                    if (get(u16, entry.payload, 0) != schema_version) return error.InvalidRawIngress;
                    const length: usize = get(u32, entry.payload, 4);
                    if (length > max_frame_bytes or entry.payload.len != header_bytes + length) return error.InvalidRawIngress;
                    const frame = entry.payload[header_bytes..];
                    var digest: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(frame, &digest, .{});
                    if (!std.mem.eql(u8, &digest, entry.payload[40..72])) return error.InvalidRawIngress;
                    try self.consumer.consume(entry.sequence, .{
                        .source_session = get(u64, entry.payload, 8),
                        .origin = get(u16, entry.payload, 2),
                        .receive_time_utc_ns = get(u64, entry.payload, 16),
                        .monotonic_time_ns = get(u64, entry.payload, 24),
                        .wall_time_utc_ns = get(u64, entry.payload, 32),
                        .byte_len = @intCast(length),
                        .sha256 = digest,
                    }, frame);
                    self.next_sequence = try std.math.add(u64, self.next_sequence, 1);
                },
            };
        }
    };
    var walker: Walker = .{ .consumer = consumer };
    if (store.supportsSegmentReplay())
        try store.replaySegments(io, stream, .{ .ptr = &walker, .consume_fn = Walker.segment })
    else
        try Walker.segment(&walker, recovered.tail);
    if (walker.next_sequence != recovered.last_sequence + 1) return error.InvalidRawIngress;
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

test "durable raw ingress replays committed bytes and fails closed on storage fault" {
    var memory = durable.MemoryAdapter.init();
    const stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 7 };
    var sink = try DurableSink.init(memory.interface(), undefined, stream);
    const bytes = "{\"frame\":1}";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try std.testing.expectEqual(@as(u64, 1), (try sink.interface().append(.{
        .source_session = 4,
        .origin = 2,
        .receive_time_utc_ns = 10,
        .monotonic_time_ns = 11,
        .wall_time_utc_ns = 12,
        .byte_len = @intCast(bytes.len),
        .sha256 = digest,
    }, bytes)).stream_sequence);
    const Counter = struct {
        count: u64 = 0,
        fn consume(ptr: *anyopaque, _: u64, record: market.RawIngressRecord, replayed: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expectEqual(@as(u16, 2), record.origin);
            try std.testing.expectEqualStrings("{\"frame\":1}", replayed);
            self.count += 1;
        }
    };
    var counter = Counter{};
    try replayCommitted(memory.interface(), undefined, stream, .{ .ptr = &counter, .consume_fn = Counter.consume });
    try std.testing.expectEqual(@as(u64, 1), counter.count);
    memory.injectFault(.eio);
    try std.testing.expectError(error.Unavailable, sink.interface().append(.{
        .source_session = 4,
        .origin = 2,
        .receive_time_utc_ns = 10,
        .monotonic_time_ns = 11,
        .wall_time_utc_ns = 12,
        .byte_len = @intCast(bytes.len),
        .sha256 = digest,
    }, bytes));
    try std.testing.expectEqual(durable.GateState.closed, memory.interface().safetyGate());
}

test "raw ingress retains a Demo bootstrap larger than the old 16 KiB segment" {
    var memory = durable.MemoryAdapter.init();
    const stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 9 };
    var sink = try DurableSink.init(memory.interface(), undefined, stream);
    const bytes: [600]u8 = @splat('x');
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
    for (0..32) |_| _ = try sink.interface().append(.{
        .source_session = 1,
        .origin = 2,
        .receive_time_utc_ns = 1,
        .monotonic_time_ns = 1,
        .wall_time_utc_ns = 1,
        .byte_len = bytes.len,
        .sha256 = digest,
    }, &bytes);
    const Counter = struct {
        count: usize = 0,
        fn consume(ptr: *anyopaque, _: u64, _: market.RawIngressRecord, replayed: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expectEqual(@as(usize, 600), replayed.len);
            self.count += 1;
        }
    };
    var counter = Counter{};
    try replayCommitted(memory.interface(), undefined, stream, .{ .ptr = &counter, .consume_fn = Counter.consume });
    try std.testing.expectEqual(@as(usize, 32), counter.count);
}

test "Windows raw ingress rotates, reopens, and replays every committed segment" {
    if (builtin.os.tag != .windows) return;
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.check() catch |err| {
                self.failure = err;
            };
        }
        fn check(_: *@This()) !void {
            var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var path_buffer: [260]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "C:\\Windows\\Temp\\ringwin-raw-rotate-{d}", .{std.Io.Clock.real.now(io).nanoseconds});
            try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
            defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
            const stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 77 };
            const frame: [3900]u8 = @splat('x');
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(&frame, &digest, .{});
            {
                var file = try durable.WindowsFileAdapter.openWindowsVerification(io, path);
                defer file.close(io);
                var sink = try DurableSink.init(file.interface(), io, stream);
                for (0..60) |_| _ = try sink.interface().append(.{
                    .source_session = 1,
                    .origin = 2,
                    .receive_time_utc_ns = 1,
                    .monotonic_time_ns = 1,
                    .wall_time_utc_ns = 1,
                    .byte_len = frame.len,
                    .sha256 = digest,
                }, &frame);
            }
            var reopened = try durable.WindowsFileAdapter.openWindowsVerification(io, path);
            defer reopened.close(io);
            var resumed = try DurableSink.recover(reopened.interface(), io, stream);
            try std.testing.expectEqual(@as(u64, 61), resumed.next_sequence);
            _ = try resumed.interface().append(.{ .source_session = 1, .origin = 2, .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1, .byte_len = frame.len, .sha256 = digest }, &frame);
            const Counter = struct {
                count: u64 = 0,
                fn consume(ptr: *anyopaque, sequence: u64, _: market.RawIngressRecord, replayed: []const u8) !void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    try std.testing.expectEqual(self.count + 1, sequence);
                    try std.testing.expectEqual(@as(usize, 3900), replayed.len);
                    self.count += 1;
                }
            };
            var counter = Counter{};
            try replayCommitted(reopened.interface(), io, stream, .{ .ptr = &counter, .consume_fn = Counter.consume });
            try std.testing.expectEqual(@as(u64, 61), counter.count);
        }
    };
    var context = Context{};
    const worker = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Context.run, .{&context});
    worker.join();
    if (context.failure) |err| return err;
}
