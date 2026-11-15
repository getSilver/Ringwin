//! Bounded public capture over DurableStore RawIngress, including large metadata frames.
const std = @import("std");
const raw = @import("raw_ingress.zig");
const durable = @import("durable_store.zig");
const protocol = @import("../adapters/okx/okx_public_market.zig");
pub const max_capture_bytes = 4 * 1024 * 1024;
const header_origin: u16 = 0x5348;
const chunk_origin: u16 = 0x5342;
const Header = struct { schema: u16 = 1, length: u32, chunks: u16, digest: [32]u8, metadata: []const u8 };

pub const Sink = struct {
    durable_sink: raw.DurableSink,
    budget: u64,
    max_bytes: usize = 120 * 1024,
    written: u64 = 0,
    failed: bool = false,
    digest: [32]u8 = @splat(0),

    pub fn append(self: *Sink, allocator: std.mem.Allocator, metadata: []const u8, record: protocol.RawIngressRecord, bytes: []const u8) protocol.RawSinkError!u64 {
        if (self.failed or bytes.len == 0 or bytes.len > @min(self.max_bytes, max_capture_bytes) or metadata.len > 8192) return error.Unavailable;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (record.byte_len != bytes.len or !std.mem.eql(u8, &digest, &record.sha256)) return error.Unavailable;
        const header = std.json.Stringify.valueAlloc(allocator, Header{ .length = @intCast(bytes.len), .chunks = @intCast(std.math.divCeil(usize, bytes.len, raw.max_frame_bytes) catch unreachable), .digest = record.sha256, .metadata = metadata }, .{}) catch return error.Unavailable;
        defer allocator.free(header);
        const needed = header.len + bytes.len + 2048;
        if (needed > self.budget -| self.written) {
            self.failed = true;
            return error.Unavailable;
        }
        self.appendRecord(record, header_origin, header) catch {
            self.failed = true;
            return error.Unavailable;
        };
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + raw.max_frame_bytes);
            self.appendRecord(record, chunk_origin, bytes[offset..end]) catch {
                self.failed = true;
                return error.Unavailable;
            };
            offset = end;
        }
        self.written += needed;
        self.digest = record.sha256;
        return self.durable_sink.next_sequence - 1;
    }
    fn appendRecord(self: *Sink, original: protocol.RawIngressRecord, origin: u16, bytes: []const u8) !void {
        var record = original;
        record.origin = origin;
        record.byte_len = @intCast(bytes.len);
        std.crypto.hash.sha2.Sha256.hash(bytes, &record.sha256, .{});
        const sink = self.durable_sink.interface();
        _ = try sink.append_fn(sink.ptr, record, bytes);
    }
};

/// Reassemble committed captures through the existing validated RawIngress replay seam.
pub const Audit = struct {
    allocator: std.mem.Allocator,
    captures: u64 = 0,
    records: u64 = 0,
    remaining: u16 = 0,
    expected_length: usize = 0,
    length: usize = 0,
    expected_digest: [32]u8 = @splat(0),
    last_digest: [32]u8 = @splat(0),
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    pub fn consumer(self: *Audit) raw.ReplayConsumer {
        return .{ .ptr = self, .consume_fn = consume };
    }
    fn consume(ptr: *anyopaque, _: u64, record: protocol.RawIngressRecord, bytes: []const u8) !void {
        const self: *Audit = @ptrCast(@alignCast(ptr));
        self.records += 1;
        if (record.origin == header_origin) {
            if (self.remaining != 0) return error.IncompleteCapture;
            const header = try std.json.parseFromSlice(Header, self.allocator, bytes, .{});
            defer header.deinit();
            const h = header.value;
            if (h.schema != 1 or h.length == 0 or h.length > max_capture_bytes or h.chunks != try std.math.divCeil(usize, h.length, raw.max_frame_bytes)) return error.InvalidCapture;
            self.remaining = h.chunks;
            self.expected_length = h.length;
            self.length = 0;
            self.expected_digest = h.digest;
            self.hasher = .init(.{});
        } else if (record.origin == chunk_origin) {
            if (self.remaining == 0) return error.InvalidCapture;
            self.hasher.update(bytes);
            self.length += bytes.len;
            self.remaining -= 1;
            if (self.remaining == 0) {
                const digest = self.hasher.finalResult();
                if (self.length != self.expected_length or !std.mem.eql(u8, &digest, &self.expected_digest)) return error.InvalidCapture;
                self.captures += 1;
                self.last_digest = digest;
            }
        } else return error.InvalidCapture;
    }
    pub fn run(self: *Audit, store: durable.Store, io: std.Io, stream: durable.StreamIdentity) !void {
        try raw.replayCommitted(store, io, stream, self.consumer());
        if (self.remaining != 0) return error.IncompleteCapture;
    }
};

test "public captures reassemble large protocol bytes through committed RawIngress" {
    const allocator = std.testing.allocator;
    const store = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(store);
    store.* = .initWithAllocator(allocator);
    defer store.deinit();
    var sink: Sink = .{ .durable_sink = try raw.DurableSink.init(store.interface(), std.testing.io, .{ .domain = .raw_ingress, .id = 7 }), .budget = 100000 };
    const bytes = try allocator.alloc(u8, raw.max_frame_bytes + 100);
    defer allocator.free(bytes);
    @memset(bytes, 'x');
    var record: protocol.RawIngressRecord = .{ .source_session = 9, .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1, .byte_len = @intCast(bytes.len), .sha256 = undefined };
    std.crypto.hash.sha2.Sha256.hash(bytes, &record.sha256, .{});
    try std.testing.expectEqual(@as(u64, 3), try sink.append(allocator, "synthetic_protocol_fixture", record, bytes));
    var audit: Audit = .{ .allocator = allocator };
    try audit.run(store.interface(), std.testing.io, sink.durable_sink.stream);
    try std.testing.expectEqual(@as(u64, 1), audit.captures);
    try std.testing.expectEqualSlices(u8, &record.sha256, &audit.last_digest);
    sink.budget = sink.written;
    try std.testing.expectError(error.Unavailable, sink.append(allocator, "fixture", record, bytes));
    try std.testing.expect(sink.failed);
}
