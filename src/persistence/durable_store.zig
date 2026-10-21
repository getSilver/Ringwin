//! Durable persistence seam for authoritative trading state.
//! Callers see streams, barriers, snapshots, and recovery only. File names,
//! sync ordering, manifests, and legal tail handling stay inside this module.

const builtin = @import("builtin");
const std = @import("std");
const journal = @import("journal.zig");
const production_contract = @import("../runtime/production_contract.zig");
pub const business_history = @import("business_history.zig");
const snapshot_codec = @import("snapshot_codec.zig");

const HistoryHead = struct {
    current: ?business_history.Receipt = null,
    previous: ?business_history.Receipt = null,
};
const HistoryHeads = struct {
    version: u16 = 2,
    entries: [8]HistoryHead = @splat(.{}),
};

const Sha256 = std.crypto.hash.sha2.Sha256;
const Crc32c = std.hash.crc.Crc32Iscsi;

// Synthetic shared-store topology: 4 shard logs + centralized raw + gateway +
// coordinator + spare. Separate capture owners use separate Store instances.
pub const max_streams = 8;
pub const max_segment_bytes = 192 * 1024;
pub const max_snapshot_bytes = 32 * 1024 * 1024;
const inline_snapshot_bytes = 1024 * 1024;
// shortcut: large snapshot overflow is temporary owned storage; streaming cache qualification belongs to ticket 09.
pub const max_manifest_entries = 32;

const manifest_magic: u32 = 0x544e414d; // MANT
const snapshot_magic: u32 = 0x504e5352; // RSNP
const format_schema: u16 = 1;
const manifest_schema: u16 = 3;
const manifest_header_len = 16;
const manifest_entry_len = 256;
const archive_page_len = 160;
const snapshot_header_len = 96;

const FileName = struct {
    bytes: [160]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const FileName) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const StreamDomain = enum(u8) {
    raw_ingress,
    decision_log,
    control,
};

pub const StreamIdentity = struct {
    domain: StreamDomain,
    id: u64,
};

pub const Append = struct {
    stream: StreamIdentity,
    record: journal.Record,
};

pub const RecoveryStatus = enum {
    ready,
    recovery_only,
};

pub const GateState = enum {
    open,
    closed,
};

pub const Fault = enum {
    none,
    short_write,
    interrupted,
    enospc,
    eio,
    read_only,
    sync_timeout,
    truncate,
    reorder,
    corruption,
};

pub const FaultPoint = enum { any, append, commit, seal, publish, rotate, snapshot_sync, archive_sync, root_publish, reclaim };

// Returned slices borrow adapter storage and remain valid until its next IO.
pub const Recovery = struct {
    status: RecoveryStatus,
    snapshot: []const u8,
    tail: []const u8,
    committed_barrier: u64,
    last_sequence: u64,
    segment_index: u32,
    segment_digest: [Sha256.digest_length]u8,
    archive_root: [32]u8 = @splat(0),
    archived_barrier: u64 = 0,
    active_segment: []const u8 = &.{},
    segment_sealed: bool = false,
    snapshot_barrier: u64 = 0,
    tail_segments: [3][]const u8 = .{ &.{}, &.{}, &.{} },
    tail_count: u8 = 0,
    gate: GateState,
};

pub const ArchiveReceipt = struct {
    stream: StreamIdentity,
    covered_first: u64 = 1,
    covered_last: u64,
    segment_count: u64,
    ordered_root: [32]u8,
    latest_first_sequence: u64,
    latest_last_sequence: u64,
    latest_byte_len: u32,
    latest_payload_digest: [32]u8,
    previous_root: [32]u8,
};

pub const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        append: *const fn (*anyopaque, std.Io, Append) anyerror!void,
        commit: *const fn (*anyopaque, std.Io, StreamIdentity, u64) anyerror!void,
        seal: *const fn (*anyopaque, std.Io, StreamIdentity) anyerror!void,
        rotate: *const fn (*anyopaque, std.Io, StreamIdentity) anyerror!void,
        publish: *const fn (*anyopaque, std.Io, StreamIdentity, u64, []const u8) anyerror!void,
        recover: *const fn (*anyopaque, std.Io, StreamIdentity) anyerror!Recovery,
        gate: *const fn (*anyopaque) GateState,
        archive_receipt: ?*const fn (*anyopaque, std.Io, StreamIdentity) anyerror!ArchiveReceipt = null,
        verify_archive_receipt: ?*const fn (*anyopaque, std.Io, StreamIdentity, u64, [32]u8) anyerror!bool = null,
        replay_segments_after: ?*const fn (*anyopaque, std.Io, StreamIdentity, u64, usize, SegmentConsumer) anyerror!void = null,
        replay_segments: ?*const fn (*anyopaque, std.Io, StreamIdentity, SegmentConsumer) anyerror!void = null,
        publish_order_history: ?*const fn (*anyopaque, std.Io, business_history.Batch) anyerror!business_history.Receipt = null,
        query_order_history: ?*const fn (*anyopaque, std.Io, business_history.LookupRequest) anyerror!business_history.LookupResult = null,
        recover_order_history: ?*const fn (*anyopaque, std.Io, business_history.Origin) anyerror!business_history.Receipt = null,
    };

    pub fn append(self: Store, io: std.Io, request: Append) !void {
        return self.vtable.append(self.context, io, request);
    }

    pub fn publishOrderHistory(self: Store, io: std.Io, batch: business_history.Batch) !business_history.Receipt {
        const publish = self.vtable.publish_order_history orelse return error.OrderHistoryUnavailable;
        return publish(self.context, io, batch);
    }

    pub fn queryOrderHistory(self: Store, io: std.Io, request: business_history.LookupRequest) !business_history.LookupResult {
        const query = self.vtable.query_order_history orelse return error.OrderHistoryUnavailable;
        return query(self.context, io, request);
    }

    pub fn recoverOrderHistory(self: Store, io: std.Io, origin: business_history.Origin) !business_history.Receipt {
        const recover_history = self.vtable.recover_order_history orelse return error.OrderHistoryUnavailable;
        return recover_history(self.context, io, origin);
    }

    pub fn commit(self: Store, io: std.Io, stream: StreamIdentity, barrier: u64) !void {
        return self.vtable.commit(self.context, io, stream, barrier);
    }

    pub fn seal(self: Store, io: std.Io, stream: StreamIdentity) !void {
        return self.vtable.seal(self.context, io, stream);
    }

    pub fn rotate(self: Store, io: std.Io, stream: StreamIdentity) !void {
        return self.vtable.rotate(self.context, io, stream);
    }

    pub fn publishSnapshot(self: Store, io: std.Io, stream: StreamIdentity, barrier: u64, bytes: []const u8) !void {
        return self.vtable.publish(self.context, io, stream, barrier, bytes);
    }

    pub fn recover(self: Store, io: std.Io, stream: StreamIdentity) !Recovery {
        return self.vtable.recover(self.context, io, stream);
    }

    pub fn archiveReceipt(self: Store, io: std.Io, stream: StreamIdentity) !ArchiveReceipt {
        const query = self.vtable.archive_receipt orelse return error.ArchiveReceiptUnavailable;
        return query(self.context, io, stream);
    }

    pub fn verifyArchiveReceipt(self: Store, io: std.Io, stream: StreamIdentity, barrier: u64, root: [32]u8) !bool {
        const query = self.vtable.verify_archive_receipt orelse return error.ArchiveReceiptUnavailable;
        return query(self.context, io, stream, barrier, root);
    }

    pub fn safetyGate(self: Store) GateState {
        return self.vtable.gate(self.context);
    }

    pub fn supportsSegmentReplay(self: Store) bool {
        return self.vtable.replay_segments != null;
    }

    pub fn replaySegmentsAfter(self: Store, io: std.Io, stream: StreamIdentity, barrier: u64, byte_budget: usize, consumer: SegmentConsumer) !void {
        const replay = self.vtable.replay_segments_after orelse return error.SegmentReplayUnavailable;
        return replay(self.context, io, stream, barrier, byte_budget, consumer);
    }

    pub fn replaySegments(self: Store, io: std.Io, stream: StreamIdentity, consumer: SegmentConsumer) !void {
        const replay = self.vtable.replay_segments orelse return error.SegmentReplayUnavailable;
        return replay(self.context, io, stream, consumer);
    }
};

pub const SegmentConsumer = struct {
    ptr: *anyopaque,
    consume_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn consume(self: SegmentConsumer, bytes: []const u8) !void {
        return self.consume_fn(self.ptr, bytes);
    }
};

const Stream = struct {
    used: bool = false,
    identity: StreamIdentity = .{ .domain = .control, .id = 0 },
    segment_index: u32 = 0,
    committed_barrier: u64 = 0,
    journal: journal.Journal = journal.Journal.init(),
};

const ManifestEntry = struct {
    used: bool = false,
    identity: StreamIdentity = .{ .domain = .control, .id = 0 },
    segment_index: u32 = 0,
    records: u32 = 0,
    first_sequence: u64 = 0,
    last_sequence: u64 = 0,
    committed_barrier: u64 = 0,
    byte_len: u32 = 0,
    digest: [Sha256.digest_length]u8 = @splat(0),
    archive_root: [32]u8 = @splat(0),
    archived_barrier: u64 = 0,
    snapshot_barrier: u64 = 0,
    snapshot_digest: [32]u8 = @splat(0),
    previous_snapshot_barrier: u64 = 0,
    previous_snapshot_digest: [32]u8 = @splat(0),
};

// A descriptor page is immutable and content-addressed. Its root covers the
// complete ordered sealed prefix, independently of the core's checkpoint root.
fn encodeEntry(entry: ManifestEntry, encoded: []u8) void {
    @memset(encoded, 0);
    encoded[0] = @intFromEnum(entry.identity.domain);
    put(u64, encoded, 8, entry.identity.id);
    put(u32, encoded, 16, entry.segment_index);
    put(u32, encoded, 20, entry.records);
    put(u64, encoded, 24, entry.first_sequence);
    put(u64, encoded, 32, entry.last_sequence);
    put(u64, encoded, 40, entry.committed_barrier);
    put(u32, encoded, 48, entry.byte_len);
    @memcpy(encoded[52..84], &entry.digest);
    if (encoded.len >= manifest_entry_len) {
        @memcpy(encoded[96..128], &entry.archive_root);
        put(u64, encoded, 128, entry.archived_barrier);
        put(u64, encoded, 136, entry.snapshot_barrier);
        @memcpy(encoded[144..176], &entry.snapshot_digest);
        put(u64, encoded, 176, entry.previous_snapshot_barrier);
        @memcpy(encoded[184..216], &entry.previous_snapshot_digest);
    }
}

fn decodeEntry(encoded: []const u8) !ManifestEntry {
    if (encoded[0] > @intFromEnum(StreamDomain.control)) return error.UnknownStreamDomain;
    var entry: ManifestEntry = .{ .used = true, .identity = .{ .domain = @enumFromInt(encoded[0]), .id = get(u64, encoded, 8) }, .segment_index = get(u32, encoded, 16), .records = get(u32, encoded, 20), .first_sequence = get(u64, encoded, 24), .last_sequence = get(u64, encoded, 32), .committed_barrier = get(u64, encoded, 40), .byte_len = get(u32, encoded, 48) };
    @memcpy(&entry.digest, encoded[52..84]);
    if (encoded.len >= manifest_entry_len) {
        @memcpy(&entry.archive_root, encoded[96..128]);
        entry.archived_barrier = get(u64, encoded, 128);
        entry.snapshot_barrier = get(u64, encoded, 136);
        @memcpy(&entry.snapshot_digest, encoded[144..176]);
        entry.previous_snapshot_barrier = get(u64, encoded, 176);
        @memcpy(&entry.previous_snapshot_digest, encoded[184..216]);
    }
    if (entry.byte_len > max_segment_bytes or entry.committed_barrier > entry.last_sequence or entry.records > max_segment_bytes / journal.record_header_size) return error.InvalidManifest;
    if (entry.records == 0) {
        if (entry.first_sequence != try std.math.add(u64, entry.last_sequence, 1)) return error.InvalidManifest;
    } else if (entry.first_sequence == 0 or entry.last_sequence < entry.first_sequence or entry.last_sequence - entry.first_sequence + 1 != entry.records) return error.InvalidManifest;
    if (encoded.len >= manifest_entry_len and (entry.snapshot_barrier > entry.last_sequence or entry.previous_snapshot_barrier > entry.snapshot_barrier or entry.archived_barrier > entry.last_sequence)) return error.InvalidManifest;
    return entry;
}

fn archivePage(entry: ManifestEntry) [archive_page_len]u8 {
    var bytes: [archive_page_len]u8 = @splat(0);
    encodeEntry(entry, bytes[0..96]);
    @memcpy(bytes[96..128], &entry.archive_root);
    @memcpy(bytes[128..160], &digest("Ringwin.SealedArchiveDescriptor.V1"));
    return bytes;
}

fn receiptFromPage(bytes: []const u8, root: [32]u8) !ArchiveReceipt {
    if (bytes.len != archive_page_len or !std.mem.eql(u8, &digest(bytes), &root) or !std.mem.eql(u8, bytes[128..160], &digest("Ringwin.SealedArchiveDescriptor.V1"))) return error.ArchiveRootConflict;
    const entry = try decodeEntry(bytes[0..96]);
    if (entry.records == 0 or entry.first_sequence == 0 or entry.last_sequence < entry.first_sequence or entry.last_sequence != entry.committed_barrier or entry.byte_len > max_segment_bytes) return error.InvalidArchiveDescriptor;
    var previous: [32]u8 = undefined;
    @memcpy(&previous, bytes[96..128]);
    return .{ .stream = entry.identity, .covered_last = entry.last_sequence, .segment_count = @as(u64, entry.segment_index) + 1, .ordered_root = root, .latest_first_sequence = entry.first_sequence, .latest_last_sequence = entry.last_sequence, .latest_byte_len = entry.byte_len, .latest_payload_digest = entry.digest, .previous_root = previous };
}

fn requireCurrentJournalSchema(record: journal.Record) !void {
    if (record.schema_version != production_contract.journal_schema_version) return error.UnsupportedJournalSchema;
}

fn verifySegmentMetadata(bytes: []const u8, receipt: ArchiveReceipt) !void {
    var reader = try journal.Reader.init(bytes);
    if (reader.next_sequence != receipt.latest_first_sequence) return error.ArchiveRootConflict;
    while (true) switch (try reader.next()) {
        .record => |record| try requireCurrentJournalSchema(record),
        .end => |status| {
            if (status != .clean or reader.last_sequence != receipt.latest_last_sequence or reader.records != receipt.latest_last_sequence - receipt.latest_first_sequence + 1) return error.ArchiveRootConflict;
            return;
        },
    };
}

const MemoryArchive = struct { page: [archive_page_len]u8, payload: []u8 };

fn sameStream(a: StreamIdentity, b: StreamIdentity) bool {
    return a.domain == b.domain and a.id == b.id;
}

fn digest(bytes: []const u8) [Sha256.digest_length]u8 {
    var result: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &result, .{});
    return result;
}

fn manifestChecksum(bytes: []const u8) u32 {
    var checksum = Crc32c.init();
    checksum.update(bytes[0..12]);
    if (bytes.len > manifest_header_len) checksum.update(bytes[manifest_header_len..]);
    return checksum.final();
}

fn put(comptime T: type, destination: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, destination[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, source: []const u8, offset: usize) T {
    return std.mem.readInt(T, source[offset..][0..@sizeOf(T)], .little);
}

fn faultError(fault: Fault) !void {
    return switch (fault) {
        .none => {},
        .short_write => error.InjectedShortWrite,
        .interrupted => error.InjectedInterrupted,
        .enospc => error.NoSpaceLeft,
        .eio => error.InputOutput,
        .read_only => error.ReadOnlyFileSystem,
        .sync_timeout => error.SyncTimeout,
        .truncate => error.InjectedTruncation,
        .reorder => error.InjectedReorder,
        .corruption => error.InjectedCorruption,
    };
}

fn slotCapacityReached(count: usize, capacity: usize) bool {
    return count >= capacity;
}

test "09 boundary Store directory guards reject full and excess counts without populating slots" {
    for ([_]usize{ max_streams, max_manifest_entries }) |capacity| {
        try std.testing.expect(!slotCapacityReached(capacity - 1, capacity));
        try std.testing.expect(slotCapacityReached(capacity, capacity));
        try std.testing.expect(slotCapacityReached(capacity + 1, capacity));
        try std.testing.expect(slotCapacityReached(std.math.maxInt(usize), capacity));
    }
}

fn findStream(streams: *[max_streams]Stream, identity: StreamIdentity, create: bool) !*Stream {
    var used: usize = 0;
    for (streams) |*stream| {
        if (stream.used and sameStream(stream.identity, identity)) return stream;
        used += @intFromBool(stream.used);
    }
    if (!create) return error.StreamNotFound;
    if (slotCapacityReached(used, max_streams)) return error.StreamCapacity;
    for (streams) |*stream| if (!stream.used) {
        stream.* = .{ .used = true, .identity = identity, .journal = journal.Journal.init() };
        return stream;
    };
    return error.StreamCapacity;
}

fn findManifest(entries: *[max_manifest_entries]ManifestEntry, identity: StreamIdentity, segment_index: u32, create: bool) !*ManifestEntry {
    var used: usize = 0;
    for (entries) |*entry| {
        if (entry.used and sameStream(entry.identity, identity) and entry.segment_index == segment_index) return entry;
        used += @intFromBool(entry.used);
    }
    if (!create) return error.ManifestEntryMissing;
    if (slotCapacityReached(used, max_manifest_entries)) return error.ManifestCapacity;
    for (entries) |*entry| if (!entry.used) {
        entry.* = .{ .used = true, .identity = identity, .segment_index = segment_index };
        return entry;
    };
    return error.ManifestCapacity;
}

fn verifyJournal(stream: *const Stream) !RecoveryStatus {
    var reader = try journal.Reader.init(stream.journal.bytes());
    while (true) switch (try reader.next()) {
        .record => |record| try requireCurrentJournalSchema(record),
        // A short final frame is a legal crash tail. The reader has already
        // verified every complete record before it, so replay may stop here.
        .end => break,
    };
    return .ready;
}

/// Borrow the committed prefix without hiding or modifying the physical crash suffix.
pub fn committedJournalPrefix(bytes: []const u8, committed_barrier: u64) ![]const u8 {
    var reader = try journal.Reader.init(bytes);
    while (true) {
        const offset = reader.offset;
        switch (try reader.next()) {
            .record => |record| if (record.sequence > committed_barrier) return bytes[0..offset],
            .end => |status| return if (status == .truncated_tail) bytes[0..reader.offset] else bytes,
        }
    }
}

fn recoveryWithTails(stream: *const Stream, entry: ManifestEntry, snapshot: []const u8, barrier: u64, archived: [2][]const u8, archived_count: u8, gate: GateState) !Recovery {
    _ = try verifyJournal(stream);
    if (snapshot.len == 0 or (archived_count == 0 and !snapshotTailIsContinuous(stream, barrier))) return error.SnapshotObjectUnavailable;
    const committed_active = try committedJournalPrefix(stream.journal.bytes(), stream.committed_barrier);
    const tail = if (barrier == stream.committed_barrier or stream.journal.records == 0) &.{} else committed_active;
    var tails: [3][]const u8 = .{ &.{}, &.{}, &.{} };
    for (0..archived_count) |index| tails[index] = archived[archived_count - index - 1];
    var count = archived_count;
    if (tail.len != 0) {
        tails[count] = tail;
        count += 1;
    }
    return .{ .status = .ready, .snapshot = snapshot, .tail = tail, .committed_barrier = stream.committed_barrier, .last_sequence = stream.journal.last_sequence, .segment_index = stream.segment_index, .segment_digest = digest(stream.journal.bytes()), .archive_root = entry.archive_root, .archived_barrier = entry.archived_barrier, .active_segment = stream.journal.bytes(), .segment_sealed = stream.journal.sealed, .snapshot_barrier = barrier, .tail_segments = tails, .tail_count = count, .gate = gate };
}

fn firstSequence(stream: *const Stream) u64 {
    return if (stream.journal.records == 0) stream.journal.last_sequence + 1 else stream.journal.last_sequence - stream.journal.records + 1;
}

fn snapshotTailIsContinuous(stream: *const Stream, barrier: u64) bool {
    return barrier != 0 and (barrier == stream.journal.last_sequence or (barrier != std.math.maxInt(u64) and firstSequence(stream) == barrier + 1));
}

fn virginJournalRecovery(stream: *const Stream, entry: ManifestEntry, gate: GateState) !Recovery {
    _ = try verifyJournal(stream);
    if (entry.snapshot_barrier != 0 or entry.previous_snapshot_barrier != 0 or entry.archived_barrier != 0 or !std.mem.eql(u8, &entry.archive_root, &@as([32]u8, @splat(0))) or !std.mem.eql(u8, &entry.snapshot_digest, &@as([32]u8, @splat(0))) or !std.mem.eql(u8, &entry.previous_snapshot_digest, &@as([32]u8, @splat(0))) or entry.segment_index != 0 or entry.last_sequence != stream.journal.last_sequence or entry.records != stream.journal.records or entry.committed_barrier != stream.committed_barrier or entry.committed_barrier > entry.last_sequence or entry.first_sequence != firstSequence(stream) or entry.byte_len != stream.journal.bytes().len or !std.mem.eql(u8, &entry.digest, &digest(stream.journal.bytes()))) return error.ManifestConflict;
    const tail = stream.journal.bytes();
    return .{ .status = .recovery_only, .snapshot = &.{}, .tail = tail, .committed_barrier = stream.committed_barrier, .last_sequence = stream.journal.last_sequence, .segment_index = stream.segment_index, .segment_digest = entry.digest, .active_segment = tail, .segment_sealed = stream.journal.sealed, .tail_segments = .{ tail, &.{}, &.{} }, .tail_count = 1, .gate = gate };
}

fn snapshotCacheView(inline_bytes: *[inline_snapshot_bytes]u8, large: *std.ArrayList(u8), len: usize) []u8 {
    return if (len <= inline_bytes.len) inline_bytes[0..len] else large.items[0..len];
}

fn snapshotCachePut(inline_bytes: *[inline_snapshot_bytes]u8, large: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    if (bytes.len > max_snapshot_bytes) return error.SnapshotTooLarge;
    if (bytes.len <= inline_bytes.len) {
        std.mem.copyForwards(u8, inline_bytes[0..bytes.len], bytes);
        large.deinit(allocator);
        large.* = .empty;
    } else {
        try large.resize(allocator, bytes.len);
        std.mem.copyForwards(u8, large.items, bytes);
    }
}

pub const MemoryAdapter = struct {
    streams: [max_streams]Stream = @splat(.{}),
    snapshots: [max_streams][inline_snapshot_bytes]u8 = undefined,
    large_snapshots: [max_streams]std.ArrayList(u8) = @splat(.empty),
    previous_snapshots: [max_streams][inline_snapshot_bytes]u8 = undefined,
    large_previous_snapshots: [max_streams]std.ArrayList(u8) = @splat(.empty),
    previous_snapshot_lens: [max_streams]usize = @splat(0),
    snapshot_lens: [max_streams]usize = @splat(0),
    snapshot_barriers: [max_streams]u64 = @splat(0),
    manifest: [max_manifest_entries]ManifestEntry = @splat(.{}),
    // MemoryAdapter is a deterministic test archive, not a production RSS proof.
    archive: std.ArrayList(MemoryArchive) = .empty,
    history_objects: std.ArrayList(u8) = .empty,
    history_roots: [max_streams]?business_history.Receipt = @splat(null),
    previous_history_roots: [max_streams]?business_history.Receipt = @splat(null),
    allocator: std.mem.Allocator = std.heap.page_allocator,
    archive_bytes: usize = 0,
    archive_quota: usize = 32 * 1024 * 1024,
    fault: Fault = .none,
    fault_point: FaultPoint = .any,
    gate: GateState = .open,

    pub fn init() MemoryAdapter {
        return .{};
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator) MemoryAdapter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryAdapter) void {
        for (self.archive.items) |item| self.allocator.free(item.payload);
        self.archive.deinit(self.allocator);
        self.history_objects.deinit(self.allocator);
        for (&self.large_snapshots) |*bytes| bytes.deinit(self.allocator);
        for (&self.large_previous_snapshots) |*bytes| bytes.deinit(self.allocator);
    }

    pub fn interface(self: *MemoryAdapter) Store {
        return .{ .context = self, .vtable = &memory_vtable };
    }

    pub fn injectFault(self: *MemoryAdapter, fault: Fault) void {
        self.fault = fault;
        self.fault_point = .any;
    }

    pub fn injectFaultAt(self: *MemoryAdapter, fault: Fault, point: FaultPoint) void {
        self.fault = fault;
        self.fault_point = point;
    }

    fn fail(self: *MemoryAdapter, point: FaultPoint) !void {
        if (self.fault_point != .any and self.fault_point != point) return;
        const fault = self.fault;
        faultError(fault) catch |err| {
            self.gate = .closed;
            return err;
        };
    }

    fn appendImpl(context: *anyopaque, _: std.Io, request: Append) anyerror!void {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        try self.fail(.append);
        if (request.record.schema_version != production_contract.journal_schema_version) {
            self.gate = .closed;
            return error.UnsupportedJournalSchema;
        }
        const stream = try findStream(&self.streams, request.stream, true);
        if (stream.journal.last_sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
        stream.journal.append(request.record) catch |err| {
            self.gate = .closed;
            return err;
        };
        const entry = try findManifest(&self.manifest, request.stream, stream.segment_index, true);
        entry.records = @intCast(stream.journal.records);
        entry.first_sequence = stream.journal.last_sequence - stream.journal.records + 1;
        entry.last_sequence = stream.journal.last_sequence;
        entry.committed_barrier = stream.committed_barrier;
        entry.byte_len = @intCast(stream.journal.bytes().len);
        entry.digest = digest(stream.journal.bytes());
    }

    fn commitImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity, barrier: u64) anyerror!void {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        try self.fail(.commit);
        const stream = try findStream(&self.streams, identity, false);
        if (barrier == 0 or barrier < stream.committed_barrier or barrier > stream.journal.last_sequence) {
            self.gate = .closed;
            return error.InvalidCommitBarrier;
        }
        stream.committed_barrier = barrier;
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, true);
        entry.committed_barrier = barrier;
    }

    fn sealImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity) anyerror!void {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        try self.fail(.seal);
        const stream = try findStream(&self.streams, identity, false);
        stream.journal.seal() catch |err| {
            self.gate = .closed;
            return err;
        };
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, true);
        entry.byte_len = @intCast(stream.journal.bytes().len);
        entry.digest = digest(stream.journal.bytes());
    }

    fn rotateImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity) anyerror!void {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        try self.fail(.rotate);
        const stream = try findStream(&self.streams, identity, false);
        if (!stream.journal.sealed) {
            self.gate = .closed;
            return error.SegmentMustBeSealedBeforeRotation;
        }
        const index = streamIndex(&self.streams, stream);
        if (self.snapshot_lens[index] == 0 or self.snapshot_barriers[index] != stream.journal.last_sequence) {
            self.gate = .closed;
            return error.SnapshotRequiredBeforeRotation;
        }
        const next_index = try std.math.add(u32, stream.segment_index, 1);
        const next_sequence = try std.math.add(u64, stream.journal.last_sequence, 1);
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        const page = archivePage(entry.*);
        _ = try receiptFromPage(&page, digest(&page));
        const bytes = stream.journal.bytes();
        const used = try std.math.add(usize, self.archive_bytes, self.history_objects.items.len);
        if (used > self.archive_quota or bytes.len > self.archive_quota - used) {
            self.gate = .closed;
            return error.NoSpaceLeft;
        }
        const owned = try self.allocator.dupe(u8, bytes);
        var transferred = false;
        errdefer if (!transferred) self.allocator.free(owned);
        try self.archive.append(self.allocator, .{ .page = page, .payload = owned });
        transferred = true;
        self.archive_bytes += bytes.len;
        entry.archive_root = digest(&page);
        entry.archived_barrier = stream.journal.last_sequence;
        entry.segment_index = next_index;
        entry.records = 0;
        entry.first_sequence = next_sequence;
        entry.last_sequence = stream.journal.last_sequence;
        stream.segment_index = next_index;
        stream.journal = journal.Journal.initAt(next_sequence);
        stream.committed_barrier = entry.archived_barrier;
        entry.byte_len = @intCast(stream.journal.bytes().len);
        entry.digest = digest(stream.journal.bytes());
        try self.fail(.reclaim);
    }

    fn publishImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity, barrier: u64, bytes: []const u8) anyerror!void {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        try self.fail(.publish);
        if (bytes.len == 0) return error.SnapshotPayloadEmpty;
        if (bytes.len > max_snapshot_bytes) {
            self.gate = .closed;
            return error.SnapshotTooLarge;
        }
        const stream = try findStream(&self.streams, identity, false);
        if (!stream.journal.sealed or stream.journal.last_sequence != barrier) {
            self.gate = .closed;
            return error.SnapshotBarrierNotSealed;
        }
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        if (barrier != stream.committed_barrier) return error.SnapshotBarrierNotCommitted;
        if (entry.snapshot_barrier == barrier) {
            if (!std.mem.eql(u8, &entry.snapshot_digest, &digest(bytes))) return error.SnapshotIdentityConflict;
            const index = streamIndex(&self.streams, stream);
            if (!std.mem.eql(u8, &digest(snapshotCacheView(&self.snapshots[index], &self.large_snapshots[index], self.snapshot_lens[index])), &entry.snapshot_digest)) return error.SnapshotObjectUnavailable;
            return;
        }
        const index = streamIndex(&self.streams, stream);
        var preserved_input: ?[]u8 = null;
        defer if (preserved_input) |copy| self.allocator.free(copy);
        var input = bytes;
        if (entry.snapshot_barrier != 0 and self.snapshot_lens[index] <= inline_snapshot_bytes) {
            const previous = snapshotCacheView(&self.previous_snapshots[index], &self.large_previous_snapshots[index], self.previous_snapshot_lens[index]);
            const input_start = @intFromPtr(bytes.ptr);
            const previous_start = @intFromPtr(previous.ptr);
            if (bytes.len != 0 and previous.len != 0 and input_start < previous_start + previous.len and previous_start < input_start + bytes.len) {
                // Preserving inline current may overwrite or free borrowed previous bytes.
                preserved_input = try self.allocator.dupe(u8, bytes);
                input = preserved_input.?;
            }
        }
        if (entry.snapshot_barrier != 0) {
            const current = snapshotCacheView(&self.snapshots[index], &self.large_snapshots[index], self.snapshot_lens[index]);
            if (current.len != 0 and std.mem.eql(u8, &digest(current), &entry.snapshot_digest)) {
                entry.previous_snapshot_barrier = entry.snapshot_barrier;
                entry.previous_snapshot_digest = entry.snapshot_digest;
                if (current.len > inline_snapshot_bytes) {
                    // Rotate owned overflow buffers: the old current remains a
                    // complete fallback even if allocation of the new current fails.
                    const previous_len = self.previous_snapshot_lens[index];
                    std.mem.swap(std.ArrayList(u8), &self.large_snapshots[index], &self.large_previous_snapshots[index]);
                    self.previous_snapshot_lens[index] = current.len;
                    self.snapshot_lens[index] = previous_len;
                } else {
                    try snapshotCachePut(&self.previous_snapshots[index], &self.large_previous_snapshots[index], self.allocator, current);
                    self.previous_snapshot_lens[index] = current.len;
                }
            } else {
                const previous = snapshotCacheView(&self.previous_snapshots[index], &self.large_previous_snapshots[index], self.previous_snapshot_lens[index]);
                if (entry.previous_snapshot_barrier == 0 or previous.len == 0 or !std.mem.eql(u8, &digest(previous), &entry.previous_snapshot_digest))
                    return error.SnapshotObjectUnavailable;
            }
        }
        entry.snapshot_barrier = barrier;
        entry.snapshot_digest = digest(input);
        try snapshotCachePut(&self.snapshots[index], &self.large_snapshots[index], self.allocator, input);
        self.snapshot_lens[index] = input.len;
        self.snapshot_barriers[index] = barrier;
    }

    fn recoverImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity) anyerror!Recovery {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        const stream = findStream(&self.streams, identity, false) catch return emptyRecovery(.closed);
        const index = streamIndex(&self.streams, stream);
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        if (entry.snapshot_barrier == 0) {
            if (self.snapshot_lens[index] != 0 or self.previous_snapshot_lens[index] != 0) {
                self.gate = .closed;
                return emptyRecovery(self.gate);
            }
            return virginJournalRecovery(stream, entry.*, self.gate) catch {
                self.gate = .closed;
                return emptyRecovery(self.gate);
            };
        }
        if (stream.segment_index != 0) {
            var found = false;
            for (self.archive.items) |item| if (std.mem.eql(u8, &digest(&item.page), &entry.archive_root)) {
                const receipt = try receiptFromPage(&item.page, entry.archive_root);
                if (!sameStream(receipt.stream, identity) or !std.mem.eql(u8, &digest(item.payload), &receipt.latest_payload_digest) or receipt.segment_count != stream.segment_index or receipt.covered_last != entry.archived_barrier) {
                    self.gate = .closed;
                    return emptyRecovery(self.gate);
                }
                verifySegmentMetadata(item.payload, receipt) catch {
                    self.gate = .closed;
                    return emptyRecovery(self.gate);
                };
                found = true;
            };
            if (!found) {
                self.gate = .closed;
                return emptyRecovery(self.gate);
            }
        }
        var snapshot = snapshotCacheView(&self.snapshots[index], &self.large_snapshots[index], self.snapshot_lens[index]);
        var barrier = self.snapshot_barriers[index];
        if (snapshot.len == 0 or !std.mem.eql(u8, &digest(snapshot), &entry.snapshot_digest)) {
            snapshot = snapshotCacheView(&self.previous_snapshots[index], &self.large_previous_snapshots[index], self.previous_snapshot_lens[index]);
            barrier = entry.previous_snapshot_barrier;
            if (snapshot.len == 0 or !std.mem.eql(u8, &digest(snapshot), &entry.previous_snapshot_digest)) {
                self.gate = .closed;
                return emptyRecovery(self.gate);
            }
        }
        var archives: [2][]const u8 = .{ &.{}, &.{} };
        var count: u8 = 0;
        if (!snapshotTailIsContinuous(stream, barrier)) {
            var root = entry.archive_root;
            var end_sequence = firstSequence(stream) - 1;
            while (end_sequence > barrier) {
                if (count == archives.len) return error.RecoveryTailBudgetExceeded;
                const item = try self.archiveItem(identity, root);
                const receipt = try receiptFromPage(&item.page, root);
                if (receipt.segment_count != stream.segment_index - count or receipt.covered_last != end_sequence or receipt.latest_first_sequence <= barrier or
                    !std.mem.eql(u8, &digest(item.payload), &receipt.latest_payload_digest)) return error.ArchiveRootConflict;
                try verifySegmentMetadata(item.payload, receipt);
                archives[count] = item.payload;
                count += 1;
                end_sequence = receipt.latest_first_sequence - 1;
                root = receipt.previous_root;
            }
            if (end_sequence != barrier) return error.ArchiveRootConflict;
        }
        return recoveryWithTails(stream, entry.*, snapshot, barrier, archives, count, self.gate) catch {
            self.gate = .closed;
            return emptyRecovery(self.gate);
        };
    }

    fn gateImpl(context: *anyopaque) GateState {
        return @as(*MemoryAdapter, @ptrCast(@alignCast(context))).gate;
    }

    // shortcut: old roots use a quota-bounded scan; production opens pages by content name.
    fn archiveItem(self: *MemoryAdapter, identity: StreamIdentity, root: [32]u8) !*const MemoryArchive {
        var index = self.archive.items.len;
        while (index != 0) {
            index -= 1;
            const item = &self.archive.items[index];
            if (std.mem.eql(u8, &digest(&item.page), &root)) {
                const receipt = try receiptFromPage(&item.page, root);
                if (!sameStream(receipt.stream, identity)) return error.ArchiveRootConflict;
                return item;
            }
        }
        return error.ArchiveRootConflict;
    }

    fn archiveReceiptImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity) anyerror!ArchiveReceipt {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        const stream = try findStream(&self.streams, identity, false);
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        if (stream.segment_index == 0) return error.ArchiveReceiptUnavailable;
        const item = try self.archiveItem(identity, entry.archive_root);
        const receipt = try receiptFromPage(&item.page, entry.archive_root);
        if (receipt.segment_count != stream.segment_index or receipt.covered_last != entry.archived_barrier or !std.mem.eql(u8, &digest(item.payload), &receipt.latest_payload_digest)) return error.ArchiveRootConflict;
        try verifySegmentMetadata(item.payload, receipt);
        return receipt;
    }

    fn verifyArchiveReceiptImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity, barrier: u64, root: [32]u8) anyerror!bool {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        const stream = try findStream(&self.streams, identity, false);
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        var cursor = entry.archive_root;
        var expected_count: u64 = stream.segment_index;
        var expected_barrier = entry.archived_barrier;
        while (expected_count != 0) : (expected_count -= 1) {
            const item = try self.archiveItem(identity, cursor);
            const receipt = try receiptFromPage(&item.page, cursor);
            if (receipt.segment_count != expected_count or receipt.covered_last != expected_barrier) return error.ArchiveRootConflict;
            if (receipt.covered_last == barrier) {
                if (!std.mem.eql(u8, &digest(item.payload), &receipt.latest_payload_digest)) return error.ArchiveRootConflict;
                try verifySegmentMetadata(item.payload, receipt);
                return std.mem.eql(u8, &cursor, &root);
            }
            if (receipt.covered_last < barrier) return false;
            cursor = receipt.previous_root;
            expected_barrier = receipt.latest_first_sequence - 1;
        }
        if (expected_barrier != 0 or !std.mem.eql(u8, &cursor, &@as([32]u8, @splat(0)))) return error.ArchiveRootConflict;
        return false;
    }

    fn replaySegmentsImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity, consumer: SegmentConsumer) anyerror!void {
        return replaySegmentsAfterImpl(context, io, identity, 0, std.math.maxInt(usize), consumer);
    }

    fn replaySegmentsAfterImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity, barrier: u64, byte_budget: usize, consumer: SegmentConsumer) anyerror!void {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        var consumer_failed = false;
        errdefer {
            if (!consumer_failed) self.gate = .closed;
        }
        if (self.gate != .open) return error.DurableStoreClosed;
        const stream = try findStream(&self.streams, identity, false);
        if (barrier > stream.committed_barrier) return error.InvalidReplayBarrier;
        const active = try findManifest(&self.manifest, identity, stream.segment_index, false);
        var total: usize = 0;
        for (self.archive.items) |item| {
            const receipt = try receiptFromPage(&item.page, digest(&item.page));
            if (sameStream(receipt.stream, identity) and receipt.covered_last > barrier) total = try std.math.add(usize, total, item.payload.len);
        }
        const include_active = stream.journal.records != 0 and stream.journal.last_sequence > barrier;
        if (include_active) {
            if (stream.journal.last_sequence != stream.committed_barrier) return error.UncommittedReplaySegment;
            total = try std.math.add(usize, total, stream.journal.bytes().len);
        }
        if (total > byte_budget) return error.ReplayByteBudgetExceeded;
        var previous: [32]u8 = @splat(0);
        var previous_barrier: u64 = 0;
        var count: u64 = 0;
        for (self.archive.items) |item| {
            const root = digest(&item.page);
            const receipt = try receiptFromPage(&item.page, root);
            if (!sameStream(receipt.stream, identity)) continue;
            if (!std.mem.eql(u8, &previous, &receipt.previous_root) or receipt.segment_count != count + 1 or receipt.latest_first_sequence != try std.math.add(u64, previous_barrier, 1)) return error.ArchiveRootConflict;
            if (receipt.covered_last > barrier) {
                if (!std.mem.eql(u8, &digest(item.payload), &receipt.latest_payload_digest)) return error.ArchiveRootConflict;
                try verifySegmentMetadata(item.payload, receipt);
                consumer.consume(item.payload) catch |err| {
                    consumer_failed = true;
                    return err;
                };
            }
            previous = root;
            previous_barrier = receipt.covered_last;
            count = try std.math.add(u64, count, 1);
        }
        if (count != stream.segment_index or !std.mem.eql(u8, &previous, &active.archive_root)) return error.ArchiveRootConflict;
        if (include_active) {
            _ = try verifyJournal(stream);
            consumer.consume(stream.journal.bytes()) catch |err| {
                consumer_failed = true;
                return err;
            };
        }
    }

    fn historyIndex(self: *MemoryAdapter, origin: business_history.Origin, create: bool) !usize {
        for (self.history_roots, 0..) |receipt, index| if (receipt) |known| {
            if (std.meta.eql(known.root.origin, origin)) return index;
        };
        if (create) for (self.history_roots, 0..) |receipt, index| {
            if (receipt == null) return index;
        };
        return error.OrderHistoryUnavailable;
    }

    fn readHistoryObject(context: *anyopaque, offset: u64, destination: []u8) anyerror!usize {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        if (offset > self.history_objects.items.len or destination.len > self.history_objects.items.len - offset)
            return error.InvalidHistoryObject;
        @memcpy(destination, self.history_objects.items[@intCast(offset)..][0..destination.len]);
        return destination.len;
    }

    fn writeHistoryObject(context: *anyopaque, bytes: []const u8) anyerror!u64 {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        try self.fail(.append);
        const used = try std.math.add(usize, self.archive_bytes, self.history_objects.items.len);
        if (used > self.archive_quota or bytes.len > self.archive_quota - used) return error.NoSpaceLeft;
        const offset: u64 = @intCast(self.history_objects.items.len);
        try self.history_objects.appendSlice(self.allocator, bytes);
        return offset;
    }

    fn historyObjects(self: *MemoryAdapter) business_history.Objects {
        return .{ .context = self, .read_fn = readHistoryObject, .write_fn = writeHistoryObject };
    }

    fn publishOrderHistoryImpl(context: *anyopaque, _: std.Io, batch: business_history.Batch) anyerror!business_history.Receipt {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        const index = try self.historyIndex(batch.origin, true);
        const expected_batch = try business_history.batchDigest(batch);
        if (self.history_roots[index]) |current| {
            if (std.mem.eql(u8, &current.batch_digest, &expected_batch)) {
                try business_history.verifyBatch(self.historyObjects(), current, batch);
                return current;
            }
            if (batch.previous_root == null or !std.meta.eql(batch.previous_root.?, current.root)) return error.StaleHistoryRoot;
        } else if (batch.previous_root != null) return error.StaleHistoryRoot;
        const receipt = try business_history.publish(self.historyObjects(), batch);
        try self.fail(.archive_sync);
        try business_history.verifyBatch(self.historyObjects(), receipt, batch);
        try self.fail(.root_publish);
        self.previous_history_roots[index] = self.history_roots[index];
        self.history_roots[index] = receipt;
        return receipt;
    }

    fn queryOrderHistoryImpl(context: *anyopaque, _: std.Io, request: business_history.LookupRequest) anyerror!business_history.LookupResult {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        if (self.gate != .open) return error.DurableStoreClosed;
        const index = try self.historyIndex(request.key.origin, false);
        const current = self.history_roots[index].?;
        const selected = if (std.mem.eql(u8, &current.root.root_digest, &request.root_digest)) current else if (self.previous_history_roots[index]) |previous|
            if (std.mem.eql(u8, &previous.root.root_digest, &request.root_digest)) previous else return error.StaleHistoryRoot
        else
            return error.StaleHistoryRoot;
        const result = try business_history.query(self.historyObjects(), selected.root, request);
        try requireCurrentAbsence(current.root, &result);
        return result;
    }

    fn recoverOrderHistoryImpl(context: *anyopaque, _: std.Io, origin: business_history.Origin) anyerror!business_history.Receipt {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        if (self.gate != .open) return error.DurableStoreClosed;
        const index = try self.historyIndex(origin, false);
        const receipt = self.history_roots[index].?;
        try business_history.verifyStoredRoot(self.historyObjects(), receipt.root);
        return receipt;
    }

    const memory_vtable: Store.VTable = .{ .append = appendImpl, .commit = commitImpl, .seal = sealImpl, .rotate = rotateImpl, .publish = publishImpl, .recover = recoverImpl, .gate = gateImpl, .archive_receipt = archiveReceiptImpl, .verify_archive_receipt = verifyArchiveReceiptImpl, .replay_segments = replaySegmentsImpl, .replay_segments_after = replaySegmentsAfterImpl, .publish_order_history = publishOrderHistoryImpl, .query_order_history = queryOrderHistoryImpl, .recover_order_history = recoverOrderHistoryImpl };
};

fn streamIndex(streams: *[max_streams]Stream, target: *const Stream) usize {
    return (@intFromPtr(target) - @intFromPtr(&streams[0])) / @sizeOf(Stream);
}

pub const LinuxFileAdapter = struct {
    dir: std.Io.Dir,
    scratch: [max_segment_bytes]u8 = undefined,
    replay_scratch: [max_segment_bytes]u8 = undefined,
    fallback_archives: [2][max_segment_bytes]u8 = undefined,
    streams: [max_streams]Stream = @splat(.{}),
    snapshots: [max_streams][inline_snapshot_bytes]u8 = undefined,
    large_snapshots: [max_streams]std.ArrayList(u8) = @splat(.empty),
    snapshot_lens: [max_streams]usize = @splat(0),
    snapshot_barriers: [max_streams]u64 = @splat(0),
    manifest: [max_manifest_entries]ManifestEntry = @splat(.{}),
    manifest_loaded: bool = false,
    fault: Fault = .none,
    fault_point: FaultPoint = .any,
    fault_skip: usize = 0,
    gate: GateState = .open,

    pub fn open(io: std.Io, absolute_path: []const u8) !LinuxFileAdapter {
        if (builtin.os.tag != .linux) return error.LinuxStoreRequired;
        return openPath(io, absolute_path);
    }

    pub fn openWindowsVerification(io: std.Io, absolute_path: []const u8) !LinuxFileAdapter {
        if (builtin.os.tag != .windows) return error.WindowsVerificationStoreRequired;
        return openPath(io, absolute_path);
    }

    pub fn initWindowsVerification(self: *LinuxFileAdapter, io: std.Io, absolute_path: []const u8) !void {
        if (builtin.os.tag != .windows) return error.WindowsVerificationStoreRequired;
        try self.initPath(io, absolute_path);
    }

    /// Caller owns initialized storage; avoids returning the large adapter by value.
    pub fn initLinux(self: *LinuxFileAdapter, io: std.Io, absolute_path: []const u8) !void {
        if (builtin.os.tag != .linux) return error.LinuxStoreRequired;
        try self.initPath(io, absolute_path);
    }

    fn initPath(self: *LinuxFileAdapter, io: std.Io, absolute_path: []const u8) !void {
        std.Io.Dir.createDirAbsolute(io, absolute_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        // Linux needs an actual directory descriptor for fsync, not O_PATH.
        self.dir = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = builtin.os.tag == .linux });
    }

    fn openPath(io: std.Io, absolute_path: []const u8) !LinuxFileAdapter {
        std.Io.Dir.createDirAbsolute(io, absolute_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return .{ .dir = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = builtin.os.tag == .linux }) };
    }

    pub fn deinit(self: *LinuxFileAdapter) void {
        for (&self.large_snapshots) |*bytes| bytes.deinit(std.heap.page_allocator);
    }

    pub fn close(self: *LinuxFileAdapter, io: std.Io) void {
        self.deinit();
        self.dir.close(io);
    }

    pub fn interface(self: *LinuxFileAdapter) Store {
        return .{ .context = self, .vtable = &file_vtable };
    }

    pub fn injectFault(self: *LinuxFileAdapter, fault: Fault) void {
        self.fault = fault;
        self.fault_point = .any;
        self.fault_skip = 0;
    }

    fn fail(self: *LinuxFileAdapter, fault: Fault) !void {
        faultError(fault) catch |err| {
            self.gate = .closed;
            return err;
        };
    }

    pub fn injectFaultAt(self: *LinuxFileAdapter, fault: Fault, point: FaultPoint) void {
        self.injectFaultAfter(fault, point, 0);
    }

    /// Deterministic fixture hook: target a later publication in one Owner operation.
    pub fn injectFaultAfter(self: *LinuxFileAdapter, fault: Fault, point: FaultPoint, skip: usize) void {
        self.fault = fault;
        self.fault_point = point;
        self.fault_skip = skip;
    }

    fn failAt(self: *LinuxFileAdapter, point: FaultPoint) !void {
        if (self.fault_point == .any or self.fault_point == point) {
            if (self.fault_skip != 0) {
                self.fault_skip -= 1;
                return;
            }
            try self.fail(self.fault);
        }
    }

    fn loadManifest(self: *LinuxFileAdapter, io: std.Io) !void {
        if (self.manifest_loaded) return;
        self.manifest = @splat(.{});
        var bytes: [manifest_header_len + max_manifest_entries * manifest_entry_len]u8 = undefined;
        const len = readInto(self.dir, io, "manifest.bin", &bytes) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (len < manifest_header_len or get(u32, bytes[0..], 0) != manifest_magic or get(u16, bytes[0..], 4) != manifest_schema or get(u16, bytes[0..], 6) != manifest_header_len) return error.InvalidManifest;
        const count = get(u32, bytes[0..], 8);
        if (count > max_manifest_entries or len != manifest_header_len + count * manifest_entry_len or get(u32, bytes[0..], 12) != manifestChecksum(bytes[0..len])) return error.InvalidManifest;
        for (0..count) |index| {
            const encoded = bytes[manifest_header_len + index * manifest_entry_len ..][0..manifest_entry_len];
            if (encoded[0] > @intFromEnum(StreamDomain.control)) return error.UnknownStreamDomain;
            self.manifest[index] = try decodeEntry(encoded);
        }
        self.manifest_loaded = true;
    }

    fn loadStream(self: *LinuxFileAdapter, io: std.Io, identity: StreamIdentity, create: bool) !*Stream {
        if (findStream(&self.streams, identity, false)) |stream| return stream else |_| {}
        try self.loadManifest(io);
        var selected: ?ManifestEntry = null;
        for (self.manifest) |entry| if (entry.used and sameStream(entry.identity, identity)) {
            if (selected != null) return error.ManifestConflict;
            selected = entry;
        };
        const stream = if (create or selected != null) try findStream(&self.streams, identity, true) else return error.StreamNotFound;
        errdefer stream.used = false;
        if (selected) |entry| {
            if (entry.segment_index != 0) {
                const receipt = try self.readArchive(io, identity, entry.archive_root);
                if (receipt.segment_count != entry.segment_index or receipt.covered_last != entry.archived_barrier or entry.first_sequence != try std.math.add(u64, receipt.covered_last, 1)) return error.ArchiveRootConflict;
            }
            const name = try segmentName(identity, entry.segment_index);
            const length = try readInto(self.dir, io, name.slice(), &self.scratch);
            if (length < entry.byte_len or !std.mem.eql(u8, &entry.digest, &digest(self.scratch[0..entry.byte_len]))) return error.ManifestConflict;
            stream.segment_index = entry.segment_index;
            stream.committed_barrier = entry.committed_barrier;
            try rebuildJournal(stream, self.scratch[0..entry.byte_len]);
        }
        return stream;
    }

    fn readArchive(self: *LinuxFileAdapter, io: std.Io, identity: StreamIdentity, root: [32]u8) !ArchiveReceipt {
        const name = try archiveName(root);
        var page: [archive_page_len]u8 = undefined;
        const len = try readInto(self.dir, io, name.slice(), &page);
        const receipt = try receiptFromPage(page[0..len], root);
        if (!sameStream(receipt.stream, identity)) return error.ArchiveRootConflict;
        return receipt;
    }

    fn verifyArchivePayload(self: *LinuxFileAdapter, io: std.Io, receipt: ArchiveReceipt) !void {
        const index = std.math.cast(u32, receipt.segment_count - 1) orelse return error.ArchiveRootConflict;
        const name = try segmentName(receipt.stream, index);
        const len = try readInto(self.dir, io, name.slice(), &self.scratch);
        if (len != receipt.latest_byte_len or !std.mem.eql(u8, &digest(self.scratch[0..len]), &receipt.latest_payload_digest)) return error.ArchiveRootConflict;
        try verifySegmentMetadata(self.scratch[0..len], receipt);
    }

    fn appendImpl(context: *anyopaque, io: std.Io, request: Append) anyerror!void {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        try self.failAt(.append);
        if (request.record.schema_version != production_contract.journal_schema_version) {
            self.gate = .closed;
            return error.UnsupportedJournalSchema;
        }
        const stream = self.loadStream(io, request.stream, true) catch |err| {
            self.gate = .closed;
            return err;
        };
        if (stream.journal.last_sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
        stream.journal.append(request.record) catch |err| {
            self.gate = .closed;
            return err;
        };
        self.persistSegment(io, stream, false) catch |err| {
            self.gate = .closed;
            return err;
        };
    }

    fn commitImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity, barrier: u64) anyerror!void {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        try self.failAt(.commit);
        const stream = self.loadStream(io, identity, false) catch |err| {
            self.gate = .closed;
            return err;
        };
        if (barrier == 0 or barrier < stream.committed_barrier or barrier > stream.journal.last_sequence) {
            self.gate = .closed;
            return error.InvalidCommitBarrier;
        }
        stream.committed_barrier = barrier;
        self.persistSegment(io, stream, true) catch |err| {
            self.gate = .closed;
            return err;
        };
    }

    fn sealImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity) anyerror!void {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        try self.failAt(.seal);
        const stream = self.loadStream(io, identity, false) catch |err| {
            self.gate = .closed;
            return err;
        };
        stream.journal.seal() catch |err| {
            self.gate = .closed;
            return err;
        };
        self.persistSegment(io, stream, true) catch |err| {
            self.gate = .closed;
            return err;
        };
    }

    fn rotateImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity) anyerror!void {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        try self.failAt(.rotate);
        const stream = self.loadStream(io, identity, false) catch |err| {
            self.gate = .closed;
            return err;
        };
        if (!stream.journal.sealed) {
            self.gate = .closed;
            return error.SegmentMustBeSealedBeforeRotation;
        }
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        if (entry.snapshot_barrier != stream.journal.last_sequence) {
            self.gate = .closed;
            return error.SnapshotRequiredBeforeRotation;
        }
        const next_index = try std.math.add(u32, stream.segment_index, 1);
        const next_sequence = try std.math.add(u64, stream.journal.last_sequence, 1);
        const page = archivePage(entry.*);
        _ = try receiptFromPage(&page, digest(&page));
        const page_name = try archiveName(digest(&page));
        writeAtomicFile(self.dir, io, page_name.slice(), &page, true) catch |err| {
            self.gate = .closed;
            return err;
        };
        try self.failAt(.archive_sync);
        const forward = try archiveIndexName(identity, stream.segment_index);
        const root = digest(&page);
        try writeAtomicFile(self.dir, io, forward.slice(), &root, true);
        const old_entry = entry.*;
        entry.archive_root = digest(&page);
        entry.archived_barrier = stream.journal.last_sequence;
        entry.segment_index = next_index;
        stream.segment_index = next_index;
        stream.journal = journal.Journal.initAt(next_sequence);
        self.persistSegment(io, stream, true) catch |err| {
            entry.* = old_entry;
            self.gate = .closed;
            return err;
        };
        try self.failAt(.reclaim);
    }

    fn publishImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity, barrier: u64, bytes: []const u8) anyerror!void {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        try self.failAt(.publish);
        if (bytes.len == 0) return error.SnapshotPayloadEmpty;
        if (bytes.len > max_snapshot_bytes) {
            self.gate = .closed;
            return error.SnapshotTooLarge;
        }
        const stream = self.loadStream(io, identity, false) catch |err| {
            self.gate = .closed;
            return err;
        };
        if (!stream.journal.sealed or stream.journal.last_sequence != barrier) {
            self.gate = .closed;
            return error.SnapshotBarrierNotSealed;
        }
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        if (barrier != stream.committed_barrier) return error.SnapshotBarrierNotCommitted;
        if (entry.snapshot_barrier == barrier) {
            if (!std.mem.eql(u8, &entry.snapshot_digest, &digest(bytes))) return error.SnapshotIdentityConflict;
            if (!try self.loadSnapshotObject(io, identity, streamIndex(&self.streams, stream), barrier, entry.snapshot_digest)) return error.SnapshotObjectUnavailable;
            return;
        }
        var header: [snapshot_header_len]u8 = @splat(0);
        put(u32, &header, 0, snapshot_magic);
        put(u16, &header, 4, format_schema);
        put(u16, &header, 6, snapshot_header_len);
        header[8] = @intFromEnum(identity.domain);
        put(u64, &header, 16, identity.id);
        put(u64, &header, 24, barrier);
        put(u32, &header, 32, @intCast(bytes.len));
        put(u32, &header, 36, Crc32c.hash(bytes));
        const snapshot_digest = digest(bytes);
        @memcpy(header[40..72], &snapshot_digest);
        put(u32, &header, 72, Crc32c.hash(header[0..72]));
        const name = try snapshotObjectName(identity, barrier, snapshot_digest);
        var temp_name: [176]u8 = undefined;
        const temp = try std.fmt.bufPrint(&temp_name, "{s}.tmp", .{name.slice()});
        writeSnapshotFile(self.dir, io, temp, &header, bytes) catch |err| {
            self.gate = .closed;
            return err;
        };
        try self.failAt(.snapshot_sync);
        self.dir.rename(temp, self.dir, name.slice(), io) catch |err| {
            self.gate = .closed;
            return err;
        };
        syncDirectory(self.dir) catch |err| {
            self.gate = .closed;
            return err;
        };

        const old_entry = entry.*;
        if (entry.snapshot_barrier != 0) {
            const index = streamIndex(&self.streams, stream);
            if (self.loadSnapshotObject(io, identity, index, entry.snapshot_barrier, entry.snapshot_digest) catch false) {
                entry.previous_snapshot_barrier = entry.snapshot_barrier;
                entry.previous_snapshot_digest = entry.snapshot_digest;
            } else if (entry.previous_snapshot_barrier == 0 or
                !(self.loadSnapshotObject(io, identity, index, entry.previous_snapshot_barrier, entry.previous_snapshot_digest) catch false))
                return error.SnapshotObjectUnavailable;
        }
        entry.snapshot_barrier = barrier;
        entry.snapshot_digest = snapshot_digest;
        self.writeManifest(io, true) catch |err| {
            entry.* = old_entry;
            self.gate = .closed;
            return err;
        };
        const index = streamIndex(&self.streams, stream);
        try snapshotCachePut(&self.snapshots[index], &self.large_snapshots[index], std.heap.page_allocator, bytes);
        self.snapshot_lens[index] = bytes.len;
        self.snapshot_barriers[index] = barrier;
        try self.failAt(.reclaim);
        const obsolete_barriers = [_]u64{ old_entry.snapshot_barrier, old_entry.previous_snapshot_barrier };
        const obsolete_digests = [_][32]u8{ old_entry.snapshot_digest, old_entry.previous_snapshot_digest };
        for (obsolete_barriers, obsolete_digests) |old_barrier, old_digest| {
            if (old_barrier == 0 or old_barrier == barrier or old_barrier == entry.previous_snapshot_barrier) continue;
            const obsolete = try snapshotObjectName(identity, old_barrier, old_digest);
            self.dir.deleteFile(io, obsolete.slice()) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    self.gate = .closed;
                    return err;
                },
            };
            try syncDirectory(self.dir);
        }
    }

    fn recoverImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity) anyerror!Recovery {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        // Recover the published disk root, never partially mutated working
        // metadata, and recheck even a manifest damaged while this adapter lives.
        for (&self.streams) |*resident| resident.used = false;
        self.manifest_loaded = false;
        self.snapshot_lens = @splat(0);
        self.snapshot_barriers = @splat(0);
        self.loadManifest(io) catch {
            self.gate = .closed;
            return emptyRecovery(self.gate);
        };
        const stream = self.loadStream(io, identity, false) catch {
            self.gate = .closed;
            return emptyRecovery(self.gate);
        };
        const index = streamIndex(&self.streams, stream);
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        if (entry.snapshot_barrier == 0) return virginJournalRecovery(stream, entry.*, self.gate) catch {
            self.gate = .closed;
            return emptyRecovery(self.gate);
        };
        if (entry.segment_index != 0) {
            const receipt = self.readArchive(io, identity, entry.archive_root) catch {
                self.gate = .closed;
                return emptyRecovery(self.gate);
            };
            self.verifyArchivePayload(io, receipt) catch {
                self.gate = .closed;
                return emptyRecovery(self.gate);
            };
        }
        var snapshot_ok = self.loadSnapshot(io, identity, stream, index) catch false;
        if (!snapshot_ok and entry.previous_snapshot_barrier != 0)
            snapshot_ok = self.loadSnapshotObject(io, identity, index, entry.previous_snapshot_barrier, entry.previous_snapshot_digest) catch false;
        if (!snapshot_ok) {
            self.gate = .closed;
            return emptyRecovery(self.gate);
        }
        const barrier = self.snapshot_barriers[index];
        var archives: [2][]const u8 = .{ &.{}, &.{} };
        var count: u8 = 0;
        if (!snapshotTailIsContinuous(stream, barrier)) {
            var root = entry.archive_root;
            var end_sequence = firstSequence(stream) - 1;
            while (end_sequence > barrier) {
                if (count == archives.len) return error.RecoveryTailBudgetExceeded;
                const receipt = try self.readArchive(io, identity, root);
                if (receipt.segment_count != stream.segment_index - count or receipt.covered_last != end_sequence or receipt.latest_first_sequence <= barrier)
                    return error.ArchiveRootConflict;
                try self.verifyArchivePayload(io, receipt);
                const bytes = self.scratch[0..receipt.latest_byte_len];
                try verifySegmentMetadata(bytes, receipt);
                @memcpy(self.fallback_archives[count][0..bytes.len], bytes);
                archives[count] = self.fallback_archives[count][0..bytes.len];
                count += 1;
                end_sequence = receipt.latest_first_sequence - 1;
                root = receipt.previous_root;
            }
            if (end_sequence != barrier) return error.ArchiveRootConflict;
        }
        return recoveryWithTails(stream, entry.*, snapshotCacheView(&self.snapshots[index], &self.large_snapshots[index], self.snapshot_lens[index]), barrier, archives, count, self.gate) catch {
            self.gate = .closed;
            return emptyRecovery(self.gate);
        };
    }

    fn gateImpl(context: *anyopaque) GateState {
        return @as(*LinuxFileAdapter, @ptrCast(@alignCast(context))).gate;
    }

    fn archiveReceiptImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity) anyerror!ArchiveReceipt {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        const stream = try self.loadStream(io, identity, false);
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        if (entry.segment_index == 0) return error.ArchiveReceiptUnavailable;
        const receipt = try self.readArchive(io, identity, entry.archive_root);
        try self.verifyArchivePayload(io, receipt);
        return receipt;
    }

    fn verifyArchiveReceiptImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity, barrier: u64, root: [32]u8) anyerror!bool {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        const stream = try self.loadStream(io, identity, false);
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        var cursor = entry.archive_root;
        var expected_count: u64 = entry.segment_index;
        while (expected_count != 0) : (expected_count -= 1) {
            const receipt = try self.readArchive(io, identity, cursor);
            if (receipt.segment_count != expected_count) return error.ArchiveRootConflict;
            if (receipt.covered_last == barrier) {
                try self.verifyArchivePayload(io, receipt);
                return std.mem.eql(u8, &cursor, &root);
            }
            if (receipt.covered_last < barrier) return false;
            cursor = receipt.previous_root;
        }
        return false;
    }

    fn replaySegmentsImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity, consumer: SegmentConsumer) anyerror!void {
        return replaySegmentsAfterImpl(context, io, identity, 0, std.math.maxInt(usize), consumer);
    }

    fn replaySegmentsAfterImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity, barrier: u64, byte_budget: usize, consumer: SegmentConsumer) anyerror!void {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        var consumer_failed = false;
        errdefer {
            if (!consumer_failed) self.gate = .closed;
        }
        if (self.gate != .open) return error.DurableStoreClosed;
        const stream = try self.loadStream(io, identity, false);
        if (barrier > stream.committed_barrier) return error.InvalidReplayBarrier;
        const active = try findManifest(&self.manifest, identity, stream.segment_index, false);
        // Walk only the descriptor suffix; payloads before the requested horizon
        // are never opened. A straddling first segment is delivered whole.
        var prefix_root = active.archive_root;
        var first_index = stream.segment_index;
        var suffix_first: u64 = try std.math.add(u64, active.archived_barrier, 1);
        while (first_index != 0) {
            const receipt = try self.readArchive(io, identity, prefix_root);
            if (receipt.segment_count != first_index or (try std.math.add(u64, receipt.covered_last, 1)) != suffix_first) return error.ArchiveRootConflict;
            if (receipt.covered_last <= barrier) break;
            first_index -= 1;
            prefix_root = receipt.previous_root;
            suffix_first = receipt.latest_first_sequence;
        }
        var previous = prefix_root;
        var previous_barrier: u64 = suffix_first - 1;
        var total: usize = 0;
        // Preflight metadata and total byte budget before invoking any consumer.
        for (first_index..stream.segment_index) |index| {
            const receipt = try self.readArchiveIndex(io, identity, @intCast(index));
            if (!std.mem.eql(u8, &receipt.previous_root, &previous) or receipt.latest_first_sequence != try std.math.add(u64, previous_barrier, 1)) return error.ArchiveRootConflict;
            total = try std.math.add(usize, total, receipt.latest_byte_len);
            previous = receipt.ordered_root;
            previous_barrier = receipt.covered_last;
        }
        if (!std.mem.eql(u8, &previous, &active.archive_root)) return error.ArchiveRootConflict;
        const include_active = stream.journal.records != 0 and stream.journal.last_sequence > barrier;
        if (include_active) {
            if (stream.journal.last_sequence != stream.committed_barrier) return error.UncommittedReplaySegment;
            total = try std.math.add(usize, total, stream.journal.bytes().len);
        }
        if (total > byte_budget) return error.ReplayByteBudgetExceeded;
        for (first_index..stream.segment_index) |index| {
            const receipt = try self.readArchiveIndex(io, identity, @intCast(index));
            try self.verifyArchivePayload(io, receipt);
            const bytes = self.scratch[0..receipt.latest_byte_len];
            // A private replay callback can write another stream through this
            // same Store, whose loadStream uses the ordinary read scratch.
            @memcpy(self.replay_scratch[0..bytes.len], bytes);
            consumer.consume(self.replay_scratch[0..bytes.len]) catch |err| {
                consumer_failed = true;
                return err;
            };
        }
        if (include_active) {
            if (firstSequence(stream) != try std.math.add(u64, previous_barrier, 1)) return error.ArchiveRootConflict;
            _ = try verifyJournal(stream);
            const bytes = stream.journal.bytes();
            @memcpy(self.replay_scratch[0..bytes.len], bytes);
            consumer.consume(self.replay_scratch[0..bytes.len]) catch |err| {
                consumer_failed = true;
                return err;
            };
        }
    }

    fn readArchiveIndex(self: *LinuxFileAdapter, io: std.Io, identity: StreamIdentity, index: u32) !ArchiveReceipt {
        const forward = try archiveIndexName(identity, index);
        var root: [32]u8 = undefined;
        if (try readInto(self.dir, io, forward.slice(), &root) != root.len) return error.ArchiveRootConflict;
        const receipt = try self.readArchive(io, identity, root);
        if (receipt.segment_count != @as(u64, index) + 1) return error.ArchiveRootConflict;
        return receipt;
    }

    const HistoryObjects = struct {
        adapter: *LinuxFileAdapter,
        io: std.Io,
        file: std.Io.File,
        end: u64,

        fn read(context: *anyopaque, offset: u64, bytes: []u8) anyerror!usize {
            const self: *HistoryObjects = @ptrCast(@alignCast(context));
            if (offset < 8 or offset > self.end or bytes.len > self.end - offset) return error.InvalidHistoryObject;
            return self.file.readPositionalAll(self.io, bytes, offset);
        }

        fn write(context: *anyopaque, bytes: []const u8) anyerror!u64 {
            const self: *HistoryObjects = @ptrCast(@alignCast(context));
            try self.adapter.failAt(.append);
            // shortcut: enforce allocated-volume quota and reclaim obsolete pages before ticket09 qualification.
            const quota: u64 = 8 * 1024 * 1024 * 1024 * 1024;
            if (self.end > quota or bytes.len > quota - self.end) return error.NoSpaceLeft;
            const offset = self.end;
            try self.file.writePositionalAll(self.io, bytes, offset);
            self.end = try std.math.add(u64, offset, bytes.len);
            return offset;
        }

        fn interface(self: *HistoryObjects) business_history.Objects {
            return .{ .context = self, .read_fn = read, .write_fn = write };
        }
    };

    fn readHistoryHeads(self: *LinuxFileAdapter, io: std.Io) !HistoryHeads {
        var bytes: [8192]u8 = undefined;
        const length = readInto(self.dir, io, "order-history.roots", &bytes) catch |err| switch (err) {
            error.FileNotFound => {
                const objects = self.dir.openFile(io, "order-history.objects", .{}) catch |open_error| switch (open_error) {
                    error.FileNotFound => return .{},
                    else => return open_error,
                };
                defer objects.close(io);
                // Nonempty history without its roots cannot establish virginity.
                if (try historyFileLength(objects, io) > 8) return error.InvalidHistoryRoot;
                return .{};
            },
            else => return err,
        };
        if (length < 40 or !std.mem.eql(u8, bytes[0..8], "RWOHHD01") or
            !std.mem.eql(u8, bytes[length - 32 .. length], &digest(bytes[0 .. length - 32]))) return error.InvalidHistoryRoot;
        const heads = try snapshot_codec.decodeBare(bytes[8 .. length - 32], HistoryHeads);
        if (heads.version != 2) return error.InvalidHistoryRoot;
        for (heads.entries, 0..) |head, index| {
            if (head.current) |current| {
                _ = try business_history.verifyReceipt(current, current.root.origin, current.qualification_digest, if (head.previous) |previous| previous.root else null);
                for (heads.entries[0..index]) |prior| if (prior.current) |known| {
                    if (std.meta.eql(current.root.origin, known.root.origin)) return error.InvalidHistoryRoot;
                };
            } else if (head.previous != null) return error.InvalidHistoryRoot;
        }
        return heads;
    }

    fn historyHeadIndex(heads: *const HistoryHeads, origin: business_history.Origin, create: bool) !usize {
        for (heads.entries, 0..) |head, index| if (head.current) |current| {
            if (std.meta.eql(current.root.origin, origin)) return index;
        };
        if (create) for (heads.entries, 0..) |head, index| {
            if (head.current == null) return index;
        };
        return error.OrderHistoryUnavailable;
    }

    fn checkHistoryObjects(file: std.Io.File, io: std.Io) !u64 {
        const length = try historyFileLength(file, io);
        var magic: [8]u8 = undefined;
        if (length < magic.len or try file.readPositionalAll(io, &magic, 0) != magic.len or
            !std.mem.eql(u8, &magic, "RWOHOB01")) return error.InvalidHistoryObject;
        return length;
    }

    fn publishOrderHistoryImpl(context: *anyopaque, io: std.Io, batch: business_history.Batch) anyerror!business_history.Receipt {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        errdefer self.gate = .closed;
        if (self.gate != .open) return error.DurableStoreClosed;
        const file = try self.dir.createFile(io, "order-history.objects", .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
        defer file.close(io);
        var heads = try self.readHistoryHeads(io);
        const index = try historyHeadIndex(&heads, batch.origin, true);
        const expected_batch = try business_history.batchDigest(batch);
        if (heads.entries[index].current) |current| {
            if (std.mem.eql(u8, &current.batch_digest, &expected_batch)) {
                var existing: HistoryObjects = .{ .adapter = self, .io = io, .file = file, .end = try checkHistoryObjects(file, io) };
                try business_history.verifyBatch(existing.interface(), current, batch);
                return current;
            }
            if (batch.previous_root == null or !std.meta.eql(batch.previous_root.?, current.root)) return error.StaleHistoryRoot;
        } else if (batch.previous_root != null) return error.StaleHistoryRoot;
        var length = try historyFileLength(file, io);
        if (length == 0) {
            for (heads.entries) |head| if (head.current != null) return error.InvalidHistoryObject;
            try file.writePositionalAll(io, "RWOHOB01", 0);
            length = 8;
        } else length = try checkHistoryObjects(file, io);
        var objects: HistoryObjects = .{ .adapter = self, .io = io, .file = file, .end = length };
        const receipt = try business_history.publish(objects.interface(), batch);
        try self.failAt(.archive_sync);
        try file.sync(io);
        try business_history.verifyBatch(objects.interface(), receipt, batch);
        heads.entries[index].previous = heads.entries[index].current;
        heads.entries[index].current = receipt;
        var encoded: [8192]u8 = undefined;
        @memcpy(encoded[0..8], "RWOHHD01");
        const payload = try snapshot_codec.encodeBare(encoded[8 .. encoded.len - 32], heads);
        const head_len = 8 + payload.len;
        @memcpy(encoded[head_len..][0..32], &digest(encoded[0..head_len]));
        try self.failAt(.snapshot_sync);
        try writeFile(self.dir, io, "order-history.roots.tmp", encoded[0 .. head_len + 32], true);
        try self.failAt(.root_publish);
        try self.dir.rename("order-history.roots.tmp", self.dir, "order-history.roots", io);
        try syncDirectory(self.dir);
        try self.failAt(.commit);
        return receipt;
    }

    fn queryOrderHistoryImpl(context: *anyopaque, io: std.Io, request: business_history.LookupRequest) anyerror!business_history.LookupResult {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        if (self.gate != .open) return error.DurableStoreClosed;
        const file = try self.dir.openFile(io, "order-history.objects", .{ .lock = .shared, .lock_nonblocking = true });
        defer file.close(io);
        const heads = try self.readHistoryHeads(io);
        const index = try historyHeadIndex(&heads, request.key.origin, false);
        const head = heads.entries[index];
        const selected = if (std.mem.eql(u8, &head.current.?.root.root_digest, &request.root_digest)) head.current.? else if (head.previous) |previous|
            if (std.mem.eql(u8, &previous.root.root_digest, &request.root_digest)) previous else return error.StaleHistoryRoot
        else
            return error.StaleHistoryRoot;
        var objects: HistoryObjects = .{ .adapter = self, .io = io, .file = file, .end = try checkHistoryObjects(file, io) };
        const result = try business_history.query(objects.interface(), selected.root, request);
        try requireCurrentAbsence(head.current.?.root, &result);
        return result;
    }

    fn recoverOrderHistoryImpl(context: *anyopaque, io: std.Io, origin: business_history.Origin) anyerror!business_history.Receipt {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        if (self.gate != .open) return error.DurableStoreClosed;
        const file = self.dir.openFile(io, "order-history.objects", .{ .lock = .shared, .lock_nonblocking = true }) catch |err| {
            if (err == error.FileNotFound) {
                // Before the first publication both sidecars are absent.
                // Absence is not an I/O failure and must not close a writer
                // that is recovering a valid state with no history root.
                const roots = self.dir.openFile(io, "order-history.roots", .{ .follow_symlinks = false }) catch |root_error| {
                    if (root_error == error.FileNotFound) return error.OrderHistoryUnavailable;
                    self.gate = .closed;
                    return root_error;
                };
                roots.close(io);
            }
            // A published root without its objects, and all other file errors,
            // still fail closed; no missing committed history is recreated.
            self.gate = .closed;
            return err;
        };
        errdefer self.gate = .closed;
        defer file.close(io);
        const heads = try self.readHistoryHeads(io);
        const index = try historyHeadIndex(&heads, origin, false);
        const receipt = heads.entries[index].current.?;
        var objects: HistoryObjects = .{ .adapter = self, .io = io, .file = file, .end = try checkHistoryObjects(file, io) };
        try business_history.verifyStoredRoot(objects.interface(), receipt.root);
        return receipt;
    }

    const file_vtable: Store.VTable = .{ .append = appendImpl, .commit = commitImpl, .seal = sealImpl, .rotate = rotateImpl, .publish = publishImpl, .recover = recoverImpl, .gate = gateImpl, .replay_segments = replaySegmentsImpl, .archive_receipt = archiveReceiptImpl, .verify_archive_receipt = verifyArchiveReceiptImpl, .replay_segments_after = replaySegmentsAfterImpl, .publish_order_history = publishOrderHistoryImpl, .query_order_history = queryOrderHistoryImpl, .recover_order_history = recoverOrderHistoryImpl };

    fn persistSegment(self: *LinuxFileAdapter, io: std.Io, stream: *Stream, sync: bool) !void {
        const identity = stream.identity;
        const name = try segmentName(identity, stream.segment_index);
        // Replacing a segment with an unsynchronised inode can lose an older
        // committed prefix on power failure, so segment publication is always
        // durable even when the following manifest update is only advisory.
        try writeAtomicFile(self.dir, io, name.slice(), stream.journal.bytes(), true);
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, true);
        entry.records = @intCast(stream.journal.records);
        entry.first_sequence = if (stream.journal.records == 0) stream.journal.last_sequence + 1 else stream.journal.last_sequence - stream.journal.records + 1;
        entry.last_sequence = stream.journal.last_sequence;
        entry.committed_barrier = stream.committed_barrier;
        entry.byte_len = @intCast(stream.journal.bytes().len);
        entry.digest = digest(stream.journal.bytes());
        try self.writeManifest(io, sync);
    }

    fn writeManifest(self: *LinuxFileAdapter, io: std.Io, sync: bool) !void {
        var bytes: [manifest_header_len + max_manifest_entries * manifest_entry_len]u8 = undefined;
        @memset(&bytes, 0);
        var count: usize = 0;
        for (self.manifest) |entry| {
            if (entry.used) count += 1;
        }
        put(u32, &bytes, 0, manifest_magic);
        put(u16, &bytes, 4, manifest_schema);
        put(u16, &bytes, 6, manifest_header_len);
        put(u32, &bytes, 8, @intCast(count));
        var index: usize = 0;
        for (self.manifest) |entry| if (entry.used) {
            const encoded = bytes[manifest_header_len + index * manifest_entry_len ..][0..manifest_entry_len];
            encodeEntry(entry, encoded);
            index += 1;
        };
        const encoded_len = manifest_header_len + count * manifest_entry_len;
        put(u32, &bytes, 12, manifestChecksum(bytes[0..encoded_len]));
        try writeFile(self.dir, io, "manifest.tmp", bytes[0..encoded_len], sync);
        try self.failAt(.root_publish);
        try self.dir.rename("manifest.tmp", self.dir, "manifest.bin", io);
        if (sync) try syncDirectory(self.dir);
    }

    fn loadSnapshot(self: *LinuxFileAdapter, io: std.Io, identity: StreamIdentity, stream: *Stream, index: usize) !bool {
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, false);
        if (entry.snapshot_barrier == 0) return false;
        return self.loadSnapshotObject(io, identity, index, entry.snapshot_barrier, entry.snapshot_digest);
    }

    fn loadSnapshotObject(self: *LinuxFileAdapter, io: std.Io, identity: StreamIdentity, index: usize, barrier: u64, expected_digest: [32]u8) !bool {
        const name = try snapshotObjectName(identity, barrier, expected_digest);
        var bytes: [snapshot_header_len + max_snapshot_bytes]u8 = undefined;
        const len = readInto(self.dir, io, name.slice(), &bytes) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        if (len < snapshot_header_len or get(u32, &bytes, 0) != snapshot_magic or get(u16, &bytes, 4) != format_schema or get(u16, &bytes, 6) != snapshot_header_len or bytes[8] > @intFromEnum(StreamDomain.control) or @as(StreamDomain, @enumFromInt(bytes[8])) != identity.domain or get(u64, &bytes, 16) != identity.id or get(u64, &bytes, 24) == 0 or get(u32, &bytes, 32) != len - snapshot_header_len or get(u32, &bytes, 36) != Crc32c.hash(bytes[snapshot_header_len..len]) or get(u32, &bytes, 72) != Crc32c.hash(bytes[0..72])) return false;
        const payload = bytes[snapshot_header_len..len];
        const expected = digest(payload);
        if (!std.mem.eql(u8, &expected, bytes[40..72]) or !std.mem.eql(u8, &expected, &expected_digest) or get(u64, &bytes, 24) != barrier) return false;
        try snapshotCachePut(&self.snapshots[index], &self.large_snapshots[index], std.heap.page_allocator, payload);
        self.snapshot_lens[index] = payload.len;
        self.snapshot_barriers[index] = get(u64, &bytes, 24);
        return true;
    }
};

fn emptyRecovery(gate: GateState) Recovery {
    return .{ .status = .recovery_only, .snapshot = &.{}, .tail = &.{}, .committed_barrier = 0, .last_sequence = 0, .segment_index = 0, .segment_digest = @splat(0), .gate = gate };
}

fn segmentName(identity: StreamIdentity, index: u32) !FileName {
    var result: FileName = .{};
    result.len = (try std.fmt.bufPrint(&result.bytes, "segment-{d}-{d}-{d}.log", .{ @intFromEnum(identity.domain), identity.id, index })).len;
    return result;
}

fn archiveIndexName(identity: StreamIdentity, index: u32) !FileName {
    var result: FileName = .{};
    result.len = (try std.fmt.bufPrint(&result.bytes, "archive-{d}-{d}-{d}.ref", .{ @intFromEnum(identity.domain), identity.id, index })).len;
    return result;
}

fn archiveName(root: [32]u8) !FileName {
    var result: FileName = .{};
    result.len = (try std.fmt.bufPrint(&result.bytes, "archive-{s}.bin", .{std.fmt.bytesToHex(root, .lower)})).len;
    return result;
}

fn snapshotObjectName(identity: StreamIdentity, barrier: u64, root: [32]u8) !FileName {
    var result: FileName = .{};
    result.len = (try std.fmt.bufPrint(&result.bytes, "snapshot-{d}-{d}-{d}-{s}.bin", .{ @intFromEnum(identity.domain), identity.id, barrier, std.fmt.bytesToHex(root, .lower) })).len;
    return result;
}

fn rebuildJournal(stream: *Stream, bytes: []const u8) !void {
    var reader = try journal.Reader.init(bytes);
    stream.journal = journal.Journal.initAt(reader.next_sequence);
    while (true) switch (try reader.next()) {
        .record => |record| {
            try requireCurrentJournalSchema(record);
            try stream.journal.append(record);
        },
        .end => |status| {
            if (status == .clean) try stream.journal.seal();
            break;
        },
    };
}

fn readInto(dir: std.Io.Dir, io: std.Io, name: []const u8, destination: []u8) !usize {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var offset: usize = 0;
    while (offset < destination.len) {
        const amount = file.readStreaming(io, &.{destination[offset..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (amount == 0) break;
        offset += amount;
    }
    if (offset == destination.len) {
        var extra: [1]u8 = undefined;
        const extra_len = file.readStreaming(io, &.{&extra}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (extra_len != 0) return error.FileTooLarge;
    }
    return offset;
}

fn writeFile(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8, sync: bool) !void {
    var file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    if (sync) try file.sync(io);
}

fn writeSnapshotFile(dir: std.Io.Dir, io: std.Io, name: []const u8, header: []const u8, payload: []const u8) !void {
    var file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, payload);
    try file.sync(io);
}

fn writeAtomicFile(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8, sync: bool) !void {
    var temporary_buffer: [176]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&temporary_buffer, "{s}.tmp", .{name});
    try writeFile(dir, io, temporary, bytes, sync);
    try dir.rename(temporary, dir, name, io);
    if (sync) try syncDirectory(dir);
}

/// History handles are privately owned by one synchronous Store operation.
/// lseek avoids statx (unavailable on legacy WSL1), restoring the original offset.
fn historyFileLength(file: std.Io.File, io: std.Io) !u64 {
    if (builtin.os.tag != .linux) return file.length(io);
    const linux = std.os.linux;
    const previous = linux.lseek(file.handle, 0, std.posix.SEEK.CUR);
    if (linux.errno(previous) != .SUCCESS) return error.HistoryFileLengthUnavailable;
    const length = linux.lseek(file.handle, 0, std.posix.SEEK.END);
    if (linux.errno(length) != .SUCCESS) return error.HistoryFileLengthUnavailable;
    const restored = linux.lseek(file.handle, @intCast(previous), std.posix.SEEK.SET);
    if (linux.errno(restored) != .SUCCESS) return error.HistoryFileLengthUnavailable;
    return @intCast(length);
}

fn syncDirectory(dir: std.Io.Dir) !void {
    if (builtin.os.tag == .linux) switch (std.os.linux.errno(std.os.linux.fsync(dir.handle))) {
        .SUCCESS => {},
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .ROFS => return error.ReadOnlyFileSystem,
        // Legacy WSL1 exposes a directory handle but rejects fsync(dir).
        // Target Linux uses the branch above; the fallback keeps native WSL
        // acceptance useful without hiding a file-sync failure.
        .INVAL, .OPNOTSUPP => std.posix.sync(),
        else => return error.DirectorySyncFailed,
    };
    if (builtin.os.tag == .windows) {
        _ = windows_flush(dir.handle);
    }
}

pub const WindowsFileAdapter = LinuxFileAdapter;

test "order history public store publish query verifies same conflict and covered first" {
    const h = business_history;
    var memory = MemoryAdapter.initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const store = memory.interface();
    const origin: h.Origin = .{ .stream = .{ .domain = .decision_log, .id = 770 }, .account = 9 };
    const key: h.Key = .{ .origin = origin, .identity = .{ .order = 1 } };
    const records = [_]h.Record{.{ .bytes = "complete archived order", .payload_digest = h.hash("complete archived order") }};
    const entries = [_]h.Entry{.{ .key = key, .record_index = 0 }};
    const receipt = try store.publishOrderHistory(undefined, .{ .origin = origin, .barrier = 12, .epoch = 1, .qualification_digest = h.hash("qualification"), .records = &records, .entries = &entries });
    var request: h.LookupRequest = .{ .pending_id = 99, .key = key, .candidate_payload_digest = records[0].payload_digest, .original_input_digest = h.hash("original ingress"), .root_digest = receipt.root.root_digest, .epoch = 1, .barrier = 12 };
    const proof = try store.queryOrderHistory(undefined, request);
    try std.testing.expectEqual(h.Verdict.same, try h.verifyResult(request, &proof.proof, receipt.root));
    try h.validateRecord(&proof);
    request.candidate_payload_digest = h.hash("changed payload");
    const conflict = try store.queryOrderHistory(undefined, request);
    try std.testing.expectEqual(h.Verdict.conflict, try h.verifyResult(request, &conflict.proof, receipt.root));
    request.key.identity = .{ .order = 2 };
    const absent = try store.queryOrderHistory(undefined, request);
    try std.testing.expectEqual(h.Verdict.proven_first, try h.verifyResult(request, &absent.proof, receipt.root));
    try std.testing.expectEqualDeep(receipt, try store.recoverOrderHistory(undefined, origin));
    var tampered = proof.proof;
    tampered.lower.?.siblings[0][0] ^= 1;
    try std.testing.expectError(error.InvalidHistoryProof, h.verifyResult(proof.proof.request, &tampered, receipt.root));
    var damaged_record = proof;
    damaged_record.record_bytes[0] ^= 1;
    try std.testing.expectError(error.InvalidHistoryRecord, h.validateRecord(&damaged_record));
}

test "order history public file store reopens the same authenticated root and duplicate body" {
    const h = business_history;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    const first = try allocator.create(LinuxFileAdapter);
    defer allocator.destroy(first);
    first.* = .{ .dir = temp.dir };
    const origin: h.Origin = .{ .stream = .{ .domain = .decision_log, .id = 772 }, .account = 9 };
    const key: h.Key = .{ .origin = origin, .identity = .{ .command = 11 } };
    const body = "complete accepted command proof without a send capability";
    const records = [_]h.Record{.{ .bytes = body, .payload_digest = h.hash(body) }};
    const entries = [_]h.Entry{.{ .key = key, .record_index = 0 }};
    const batch: h.Batch = .{ .origin = origin, .barrier = 12, .epoch = 1, .qualification_digest = h.hash("safe terminal order"), .records = &records, .entries = &entries };
    const receipt = try first.interface().publishOrderHistory(io, batch);
    const reopened = try allocator.create(LinuxFileAdapter);
    defer allocator.destroy(reopened);
    reopened.* = .{ .dir = temp.dir };
    const restored = try reopened.interface().recoverOrderHistory(io, origin);
    try std.testing.expectEqualDeep(receipt, restored);
    const request: h.LookupRequest = .{ .pending_id = 1, .key = key, .candidate_payload_digest = h.hash(body), .original_input_digest = h.hash("old command retry"), .root_digest = restored.root.root_digest, .epoch = 1, .barrier = 12 };
    const result = try reopened.interface().queryOrderHistory(io, request);
    try std.testing.expectEqual(h.Verdict.same, try h.verifyResult(request, &result.proof, receipt.root));
    try h.validateRecord(&result);
    try std.testing.expectEqualStrings(body, result.record_bytes[0..result.record_len]);
    try std.testing.expectEqualDeep(receipt, try reopened.interface().publishOrderHistory(io, batch));
    const damaged = try temp.dir.openFile(io, "order-history.objects", .{ .mode = .read_write });
    try damaged.writePositionalAll(io, "X", receipt.root.tree_offset);
    try damaged.sync(io);
    damaged.close(io);
    try std.testing.expectError(error.InvalidHistoryPage, reopened.interface().publishOrderHistory(io, batch));
    try std.testing.expectEqual(GateState.closed, reopened.interface().safetyGate());
}

fn requireCurrentAbsence(current: business_history.Root, result: *const business_history.LookupResult) !void {
    if (!std.mem.eql(u8, &current.root_digest, &result.proof.root.root_digest)) {
        switch (try business_history.verifyResult(result.proof.request, &result.proof, result.proof.root)) {
            .same, .conflict => {},
            .proven_first, .expired => return error.StaleHistoryRoot,
        }
    }
}

fn historyTestRequest(root: business_history.Root, command_id: u64) business_history.LookupRequest {
    const h = business_history;
    return .{
        .pending_id = command_id + 1,
        .key = .{ .origin = root.origin, .identity = .{ .command = command_id } },
        .candidate_payload_digest = h.hash("archived command body"),
        .original_input_digest = h.hash("stable original input"),
        .root_digest = root.root_digest,
        .epoch = root.epoch,
        .barrier = root.barrier,
    };
}

fn publishHistoryTestCommand(store: Store, io: std.Io, origin: business_history.Origin, previous: ?business_history.Root, command_id: u64) !business_history.Receipt {
    const h = business_history;
    const records = [_]h.Record{.{ .bytes = "archived command body", .payload_digest = h.hash("archived command body") }};
    const entries = [_]h.Entry{.{ .key = .{ .origin = origin, .identity = .{ .command = command_id } }, .record_index = 0 }};
    return store.publishOrderHistory(io, .{
        .origin = origin,
        .previous_root = previous,
        .barrier = if (previous) |old| old.barrier + 10 else 10,
        .epoch = 1,
        .qualification_digest = h.hash("terminal qualification"),
        .records = &records,
        .entries = &entries,
    });
}

test "order history file virgin absence keeps admission open but missing published objects closes it" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const adapter = try std.testing.allocator.create(LinuxFileAdapter);
    defer std.testing.allocator.destroy(adapter);
    adapter.* = .{ .dir = temp.dir };
    const store = adapter.interface();
    const origin: business_history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 10 }, .account = 2 };
    try std.testing.expectError(error.OrderHistoryUnavailable, store.recoverOrderHistory(std.testing.io, origin));
    try std.testing.expectEqual(GateState.open, store.safetyGate());
    const published = try publishHistoryTestCommand(store, std.testing.io, origin, null, 1);
    try std.testing.expectEqualDeep(published, try store.recoverOrderHistory(std.testing.io, origin));
    try temp.dir.deleteFile(std.testing.io, "order-history.objects");
    try std.testing.expectError(error.FileNotFound, store.recoverOrderHistory(std.testing.io, origin));
    try std.testing.expectEqual(GateState.closed, store.safetyGate());
}

test "order history file missing root cannot bootstrap over existing objects" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    const adapter = try std.testing.allocator.create(LinuxFileAdapter);
    defer std.testing.allocator.destroy(adapter);
    adapter.* = .{ .dir = temp.dir };
    const origin: business_history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 780 }, .account = 9 };
    _ = try publishHistoryTestCommand(adapter.interface(), io, origin, null, 1);
    try temp.dir.deleteFile(io, "order-history.roots");
    const reopened = try std.testing.allocator.create(LinuxFileAdapter);
    defer std.testing.allocator.destroy(reopened);
    reopened.* = .{ .dir = temp.dir };
    try std.testing.expectError(error.InvalidHistoryRoot, publishHistoryTestCommand(reopened.interface(), io, origin, null, 2));
}

test "order history file frozen previous root may prove duplicate but cannot prove fresh" {
    const h = business_history;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    const adapter = try std.testing.allocator.create(LinuxFileAdapter);
    defer std.testing.allocator.destroy(adapter);
    adapter.* = .{ .dir = temp.dir };
    const origin: h.Origin = .{ .stream = .{ .domain = .decision_log, .id = 781 }, .account = 9 };
    const old = try publishHistoryTestCommand(adapter.interface(), io, origin, null, 1);
    const next = try publishHistoryTestCommand(adapter.interface(), io, origin, old.root, 2);
    const old_duplicate_request = historyTestRequest(old.root, 1);
    const old_duplicate = try adapter.interface().queryOrderHistory(io, old_duplicate_request);
    try std.testing.expectEqual(h.Verdict.same, try h.verifyResult(old_duplicate_request, &old_duplicate.proof, old.root));
    try h.validateRecord(&old_duplicate);
    try std.testing.expectError(error.StaleHistoryRoot, adapter.interface().queryOrderHistory(io, historyTestRequest(old.root, 2)));
    const current_request = historyTestRequest(next.root, 2);
    const current = try adapter.interface().queryOrderHistory(io, current_request);
    try std.testing.expectEqual(h.Verdict.same, try h.verifyResult(current_request, &current.proof, next.root));
}

test "order history file publication fault boundaries reopen a complete old or new root" {
    const h = business_history;
    const io = std.testing.io;
    const points = [_]FaultPoint{ .append, .archive_sync, .snapshot_sync, .root_publish, .commit };
    for (points) |point| {
        var temp = std.testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        const adapter = try std.testing.allocator.create(LinuxFileAdapter);
        defer std.testing.allocator.destroy(adapter);
        adapter.* = .{ .dir = temp.dir };
        const origin: h.Origin = .{ .stream = .{ .domain = .decision_log, .id = 782 }, .account = 9 };
        const first = try publishHistoryTestCommand(adapter.interface(), io, origin, null, 1);
        const old = try publishHistoryTestCommand(adapter.interface(), io, origin, first.root, 2);
        adapter.injectFaultAt(.sync_timeout, point);
        try std.testing.expectError(error.SyncTimeout, publishHistoryTestCommand(adapter.interface(), io, origin, old.root, 3));
        try std.testing.expectEqual(GateState.closed, adapter.interface().safetyGate());
        const reopened = try std.testing.allocator.create(LinuxFileAdapter);
        defer std.testing.allocator.destroy(reopened);
        reopened.* = .{ .dir = temp.dir };
        const restored = try reopened.interface().recoverOrderHistory(io, origin);
        const published = point == .commit;
        try std.testing.expectEqual(if (published) @as(u64, 3) else 2, restored.root.generation);
        try std.testing.expectEqual(if (published) @as(u64, 30) else 20, restored.root.barrier);
        if (!published) try std.testing.expectEqualDeep(old, restored);
        const duplicate_request = historyTestRequest(restored.root, 1);
        const duplicate = try reopened.interface().queryOrderHistory(io, duplicate_request);
        try std.testing.expectEqual(h.Verdict.same, try h.verifyResult(duplicate_request, &duplicate.proof, restored.root));
        try h.validateRecord(&duplicate);
        const new_request = historyTestRequest(restored.root, 3);
        const new_result = try reopened.interface().queryOrderHistory(io, new_request);
        try std.testing.expectEqual(if (published) h.Verdict.same else .proven_first, try h.verifyResult(new_request, &new_result.proof, restored.root));
        if (published) try h.validateRecord(&new_result);
        const old_request = historyTestRequest(old.root, 2);
        const old_result = try reopened.interface().queryOrderHistory(io, old_request);
        try std.testing.expectEqual(h.Verdict.same, try h.verifyResult(old_request, &old_result.proof, old.root));
        try h.validateRecord(&old_result);
        // Retrying a committed publication cannot create a fourth generation.
        const retried = try publishHistoryTestCommand(reopened.interface(), io, origin, old.root, 3);
        try std.testing.expectEqual(@as(u64, 3), retried.root.generation);
        const again = try std.testing.allocator.create(LinuxFileAdapter);
        defer std.testing.allocator.destroy(again);
        again.* = .{ .dir = temp.dir };
        try std.testing.expectEqualDeep(retried, try again.interface().recoverOrderHistory(io, origin));
    }
}

test "order history file physical root damage missing object and truncated page fail closed" {
    const io = std.testing.io;
    const Damage = enum { root_truncated, root_corrupt, objects_missing, objects_truncated, page_corrupt, record_corrupt };
    for (std.enums.values(Damage)) |damage| {
        var temp = std.testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        const adapter = try std.testing.allocator.create(LinuxFileAdapter);
        defer std.testing.allocator.destroy(adapter);
        adapter.* = .{ .dir = temp.dir };
        const origin: business_history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 783 }, .account = 9 };
        const receipt = try publishHistoryTestCommand(adapter.interface(), io, origin, null, 1);
        const request = historyTestRequest(receipt.root, 1);
        const intact = try adapter.interface().queryOrderHistory(io, request);
        switch (damage) {
            .root_truncated => try writeFile(temp.dir, io, "order-history.roots", "RWOHHD01", true),
            .root_corrupt => {
                const file = try temp.dir.openFile(io, "order-history.roots", .{ .mode = .read_write });
                defer file.close(io);
                try file.writePositionalAll(io, "X", 16);
                try file.sync(io);
            },
            .objects_missing => try temp.dir.deleteFile(io, "order-history.objects"),
            .objects_truncated => try writeFile(temp.dir, io, "order-history.objects", "RWOHOB01", true),
            .page_corrupt, .record_corrupt => {
                const file = try temp.dir.openFile(io, "order-history.objects", .{ .mode = .read_write });
                defer file.close(io);
                const offset = if (damage == .page_corrupt) receipt.root.tree_offset else intact.proof.lower.?.item.offset;
                try file.writePositionalAll(io, "X", offset);
                try file.sync(io);
            },
        }
        const reopened = try std.testing.allocator.create(LinuxFileAdapter);
        defer std.testing.allocator.destroy(reopened);
        reopened.* = .{ .dir = temp.dir };
        switch (damage) {
            .root_truncated, .root_corrupt => try std.testing.expectError(error.InvalidHistoryRoot, reopened.interface().recoverOrderHistory(io, origin)),
            .objects_missing => try std.testing.expectError(error.FileNotFound, reopened.interface().recoverOrderHistory(io, origin)),
            .objects_truncated => try std.testing.expectError(error.InvalidHistoryObject, reopened.interface().recoverOrderHistory(io, origin)),
            .page_corrupt => try std.testing.expectError(error.InvalidHistoryPage, reopened.interface().recoverOrderHistory(io, origin)),
            .record_corrupt => {
                // Recovery loads the authenticated top page; cold bodies are
                // checked on demand rather than scanning retained history.
                try std.testing.expectEqualDeep(receipt, try reopened.interface().recoverOrderHistory(io, origin));
                try std.testing.expectError(error.InvalidHistoryRecord, reopened.interface().queryOrderHistory(io, request));
            },
        }
    }
}

test "order history file isolates eight owner origins and rejects foreign root requests" {
    const h = business_history;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const adapter = try std.testing.allocator.create(LinuxFileAdapter);
    defer std.testing.allocator.destroy(adapter);
    adapter.* = .{ .dir = temp.dir };
    var receipts: [max_streams]h.Receipt = undefined;
    for (&receipts, 0..) |*receipt, index| {
        const origin: h.Origin = .{ .stream = .{ .domain = .decision_log, .id = 800 + index }, .account = 9 };
        receipt.* = try publishHistoryTestCommand(adapter.interface(), io, origin, null, 1);
    }
    const reopened = try std.testing.allocator.create(LinuxFileAdapter);
    defer std.testing.allocator.destroy(reopened);
    reopened.* = .{ .dir = temp.dir };
    for (receipts) |receipt| {
        try std.testing.expectEqualDeep(receipt, try reopened.interface().recoverOrderHistory(io, receipt.root.origin));
        const request = historyTestRequest(receipt.root, 1);
        const result = try reopened.interface().queryOrderHistory(io, request);
        try std.testing.expectEqual(h.Verdict.same, try h.verifyResult(request, &result.proof, receipt.root));
        try h.validateRecord(&result);
    }
    var foreign = historyTestRequest(receipts[0].root, 1);
    foreign.key.origin = receipts[1].root.origin;
    try std.testing.expectError(error.StaleHistoryRoot, reopened.interface().queryOrderHistory(io, foreign));
    foreign.key.origin.stream.id = 999;
    try std.testing.expectError(error.OrderHistoryUnavailable, reopened.interface().queryOrderHistory(io, foreign));
    const extra: h.Origin = .{ .stream = .{ .domain = .decision_log, .id = 999 }, .account = 9 };
    try std.testing.expectError(error.OrderHistoryUnavailable, publishHistoryTestCommand(reopened.interface(), io, extra, null, 1));
    try std.testing.expectEqual(GateState.closed, reopened.interface().safetyGate());
    // History sidecars do not consume any additional journal Stream slots.
    for (adapter.streams) |stream| try std.testing.expect(!stream.used);
}

test "order history public store proves sibling boundaries after interleaved root generations" {
    const h = business_history;
    const allocator = std.testing.allocator;
    const memory = try allocator.create(MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const store = memory.interface();
    const origin: h.Origin = .{ .stream = .{ .domain = .decision_log, .id = 771 }, .account = 9 };
    var payloads: [192][8]u8 = undefined;
    var records: [96]h.Record = undefined;
    var entries: [96]h.Entry = undefined;
    var previous: ?h.Root = null;
    for (0..2) |round| {
        for (0..96) |index| {
            const id: u64 = @intCast(1 + 2 * index + round);
            std.mem.writeInt(u64, &payloads[id - 1], id, .little);
            records[index] = .{ .bytes = &payloads[id - 1], .payload_digest = h.hash(&payloads[id - 1]) };
            entries[index] = .{ .key = .{ .origin = origin, .identity = .{ .order = id } }, .record_index = @intCast(index) };
        }
        const receipt = try store.publishOrderHistory(undefined, .{
            .origin = origin,
            .previous_root = previous,
            .barrier = 100 + round,
            .epoch = 1,
            .qualification_digest = h.hash("complete terminal batch"),
            .records = &records,
            .entries = &entries,
        });
        try std.testing.expectEqual(@as(u64, round + 1), receipt.root.generation);
        previous = receipt.root;
        for (0..96 * (round + 1)) |index| {
            const id: u64 = @intCast(if (round == 0) 1 + 2 * index else index + 1);
            const request: h.LookupRequest = .{
                .pending_id = id,
                .key = .{ .origin = origin, .identity = .{ .order = id } },
                .candidate_payload_digest = h.hash(&payloads[id - 1]),
                .original_input_digest = h.hash("original replayable request"),
                .root_digest = receipt.root.root_digest,
                .epoch = 1,
                .barrier = receipt.root.barrier,
            };
            const result = try store.queryOrderHistory(undefined, request);
            try std.testing.expectEqual(h.Verdict.same, try h.verifyResult(request, &result.proof, receipt.root));
            try h.validateRecord(&result);
            try std.testing.expectEqual(id, std.mem.readInt(u64, result.record_bytes[0..8], .little));
            try std.testing.expect(result.proof.path_len > 0);
        }
        const absent_ids: []const u64 = if (round == 0) &.{ 0, 2, 24, 48, 94, 192, 193 } else &.{ 0, 193 };
        for (absent_ids) |id| {
            const request: h.LookupRequest = .{
                .pending_id = id + 1,
                .key = .{ .origin = origin, .identity = .{ .order = id } },
                .candidate_payload_digest = h.hash("new candidate"),
                .original_input_digest = h.hash("original replayable request"),
                .root_digest = receipt.root.root_digest,
                .epoch = 1,
                .barrier = receipt.root.barrier,
            };
            const result = try store.queryOrderHistory(undefined, request);
            try std.testing.expectEqual(h.Verdict.proven_first, try h.verifyResult(request, &result.proof, receipt.root));
            var changed = result.proof;
            changed.path[0].item.upper.bytes[0] ^= 1;
            try std.testing.expectError(error.InvalidHistoryProof, h.verifyResult(request, &changed, receipt.root));
        }
    }
}

const windows_nt = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn FlushFileBuffers(handle: std.os.windows.HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
} else struct {};

fn windows_flush(handle: std.os.windows.HANDLE) i32 {
    if (builtin.os.tag != .windows) return 1;
    return windows_nt.FlushFileBuffers(handle);
}

fn windows_last_error() u32 {
    if (builtin.os.tag != .windows) return 0;
    return windows_nt.GetLastError();
}

pub fn runLinuxAcceptance(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.LinuxStoreRequired;
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/ringwin-durable-store-{d}", .{std.os.linux.getpid()});
    cleanupStoreDir(init.io, path);
    try std.Io.Dir.createDirAbsolute(init.io, path, .default_dir);
    defer cleanupStoreDir(init.io, path);

    const streams = [_]StreamIdentity{
        .{ .domain = .raw_ingress, .id = 1 },
        .{ .domain = .decision_log, .id = 2 },
        .{ .domain = .control, .id = 3 },
    };
    var payloads = [_][1]u8{ .{1}, .{2}, .{3} };
    {
        var file_store = try LinuxFileAdapter.open(init.io, path);
        defer file_store.close(init.io);
        const store = file_store.interface();
        for (streams, 0..) |stream, index| {
            try store.append(init.io, .{ .stream = stream, .record = .{ .type_id = @intCast(index + 1), .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = 1, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &payloads[index] } });
            try store.commit(init.io, stream, 1);
            try store.seal(init.io, stream);
            var snapshot: [64]u8 = undefined;
            @memset(&snapshot, @as(u8, @intCast(index + 7)));
            try store.publishSnapshot(init.io, stream, 1, &snapshot);
            try store.rotate(init.io, stream);
            try store.append(init.io, .{ .stream = stream, .record = .{ .type_id = @intCast(index + 1), .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = 2, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &payloads[index] } });
            try store.commit(init.io, stream, 2);
            try store.seal(init.io, stream);
        }
    }

    var file_store = try LinuxFileAdapter.open(init.io, path);
    defer file_store.close(init.io);
    const store = file_store.interface();
    for (streams) |stream| {
        const recovered = try store.recover(init.io, stream);
        if (recovered.status != .ready or recovered.committed_barrier != 2 or recovered.last_sequence != 2 or recovered.snapshot.len != 64 or recovered.tail.len == 0) {
            return error.DurableRecoveryMismatch;
        }
    }

    var memory = MemoryAdapter.init();
    defer memory.deinit();
    const memory_store = memory.interface();
    memory.injectFault(.short_write);
    if (memory_store.commit(init.io, streams[0], 1)) |_| return error.FaultInjectionNotObserved else |err| if (err != error.InjectedShortWrite) return err;

    var stdout_buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.print("durable_store_acceptance: adapter=linux_file, streams=3, recovery=ready, committed_barriers=6, rotations=3, snapshot=atomic, manifest=verified, faults=memory\n", .{});
    try stdout.interface.flush();
}

fn cleanupStoreDir(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

fn exerciseFileStore(init: std.process.Init, store: Store) !void {
    const streams = [_]StreamIdentity{
        .{ .domain = .raw_ingress, .id = 1 },
        .{ .domain = .decision_log, .id = 2 },
        .{ .domain = .control, .id = 3 },
    };
    var payloads = [_][1]u8{ .{1}, .{2}, .{3} };
    for (streams, 0..) |stream, index| {
        try store.append(init.io, .{ .stream = stream, .record = .{ .type_id = @intCast(index + 1), .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = 1, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &payloads[index] } });
        try store.commit(init.io, stream, 1);
        try store.seal(init.io, stream);
        var snapshot: [64]u8 = undefined;
        @memset(&snapshot, @as(u8, @intCast(index + 7)));
        try store.publishSnapshot(init.io, stream, 1, &snapshot);
        try store.rotate(init.io, stream);
        try store.append(init.io, .{ .stream = stream, .record = .{ .type_id = @intCast(index + 1), .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = 2, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &payloads[index] } });
        try store.commit(init.io, stream, 2);
        try store.seal(init.io, stream);
    }
}

fn recoverFileStore(init: std.process.Init, store: Store) !void {
    const streams = [_]StreamIdentity{
        .{ .domain = .raw_ingress, .id = 1 },
        .{ .domain = .decision_log, .id = 2 },
        .{ .domain = .control, .id = 3 },
    };
    for (streams) |stream| {
        const recovered = try store.recover(init.io, stream);
        if (recovered.status != .ready or recovered.committed_barrier != 2 or recovered.last_sequence != 2 or recovered.snapshot.len != 64 or recovered.tail.len == 0) {
            return error.DurableRecoveryMismatch;
        }
    }
    var memory = MemoryAdapter.init();
    defer memory.deinit();
    const memory_store = memory.interface();
    memory.injectFault(.short_write);
    if (memory_store.commit(init.io, streams[0], 1)) |_| return error.FaultInjectionNotObserved else |err| if (err != error.InjectedShortWrite) return err;
}

pub fn runWindowsAcceptance(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) return error.WindowsVerificationStoreRequired;
    var path_buffer: [260]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "C:\\Windows\\Temp\\ringwin-durable-store-{d}", .{windows_nt.GetCurrentProcessId()});
    cleanupStoreDir(init.io, path);
    try std.Io.Dir.createDirAbsolute(init.io, path, .default_dir);
    defer cleanupStoreDir(init.io, path);
    {
        var file_store = try WindowsFileAdapter.openWindowsVerification(init.io, path);
        defer file_store.close(init.io);
        try exerciseFileStore(init, file_store.interface());
    }
    {
        var file_store = try WindowsFileAdapter.openWindowsVerification(init.io, path);
        defer file_store.close(init.io);
        try recoverFileStore(init, file_store.interface());
    }
    var stdout_buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.print(
        "durable_store_acceptance: adapter=windows_file, streams=3, recovery=ready, committed_barriers=6, rotations=3, snapshot=atomic, manifest=verified, faults=memory, power_loss_qualified=false\n",
        .{},
    );
    try stdout.interface.flush();
}

test "memory and file stores preserve sealed barrier and reject unsafe recovery" {
    var memory = MemoryAdapter.initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const store = memory.interface();
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 7 };
    const payload = [_]u8{ 1, 2, 3 };
    try store.append(undefined, .{ .stream = stream, .record = .{ .type_id = 1, .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = 1, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &payload } });
    try store.commit(undefined, stream, 1);
    try store.seal(undefined, stream);
    var snapshot: [128]u8 = undefined;
    @memset(&snapshot, 9);
    try store.publishSnapshot(undefined, stream, 1, &snapshot);
    const recovered = try store.recover(undefined, stream);
    try std.testing.expectEqual(RecoveryStatus.ready, recovered.status);
    try std.testing.expectEqual(@as(u64, 1), recovered.committed_barrier);
    try std.testing.expectEqualSlices(u8, &snapshot, recovered.snapshot);

    memory.injectFault(.eio);
    try std.testing.expectError(error.InputOutput, store.commit(undefined, stream, 1));
    try std.testing.expectEqual(GateState.closed, store.safetyGate());
}

test "memory fault injection always closes the safety gate" {
    const faults = [_]Fault{ .short_write, .interrupted, .enospc, .eio, .read_only, .sync_timeout, .truncate, .reorder, .corruption };
    const stream: StreamIdentity = .{ .domain = .control, .id = 9 };
    const payload = [_]u8{0};
    for (faults) |fault| {
        var adapter = MemoryAdapter.initWithAllocator(std.testing.allocator);
        defer adapter.deinit();
        adapter.injectFault(fault);
        const store = adapter.interface();
        if (store.append(undefined, .{ .stream = stream, .record = .{ .type_id = 1, .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = 1, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &payload } })) |_| return error.FaultInjectionNotObserved else |_| {}
        try std.testing.expectEqual(GateState.closed, store.safetyGate());
    }
}

test "manifest checksum covers entries as well as the header" {
    var encoded: [manifest_header_len + manifest_entry_len]u8 = @splat(0);
    put(u32, &encoded, 0, manifest_magic);
    put(u16, &encoded, 4, manifest_schema);
    put(u16, &encoded, 6, manifest_header_len);
    put(u32, &encoded, 8, 1);
    const before = manifestChecksum(&encoded);
    encoded[manifest_header_len + 52] ^= 1;
    try std.testing.expect(before != manifestChecksum(&encoded));
}

test "segment rotation requires a snapshot at the sealed barrier" {
    var memory = MemoryAdapter.initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const store = memory.interface();
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 44 };
    const payload = [_]u8{1};
    try store.append(undefined, .{ .stream = stream, .record = .{ .type_id = 1, .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = 1, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &payload } });
    try store.commit(undefined, stream, 1);
    try store.seal(undefined, stream);
    try std.testing.expectError(error.SnapshotRequiredBeforeRotation, store.rotate(undefined, stream));
    try std.testing.expectEqual(GateState.closed, store.safetyGate());
}

test "checkpoint store rotates 100 rounds without cumulative manifest exhaustion" {
    var memory = MemoryAdapter.init();
    defer memory.deinit();
    const store = memory.interface();
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 700 };
    const payload = [_]u8{7};
    for (1..101) |sequence| {
        try store.append(undefined, .{ .stream = stream, .record = .{ .type_id = 1, .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = sequence, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &payload } });
        try store.commit(undefined, stream, sequence);
        try store.seal(undefined, stream);
        try store.publishSnapshot(undefined, stream, sequence, &payload);
        try store.rotate(undefined, stream);
        const recovered = try store.recover(undefined, stream);
        try std.testing.expectEqual(RecoveryStatus.ready, recovered.status);
        try std.testing.expectEqual(@as(u64, sequence), recovered.last_sequence);
    }
    const resident = try findStream(&memory.streams, stream, false);
    const index = streamIndex(&memory.streams, resident);
    memory.snapshots[index][0] ^= 1;
    const previous = try store.recover(undefined, stream);
    try std.testing.expectEqual(RecoveryStatus.ready, previous.status);
    try std.testing.expectEqual(@as(u64, 99), previous.snapshot_barrier);
    try std.testing.expectEqual(@as(u8, 1), previous.tail_count);
    memory.archive.items[memory.archive.items.len - 1].payload[0] ^= 1;
    try std.testing.expectEqual(RecoveryStatus.recovery_only, (try store.recover(undefined, stream)).status);
}

fn appendCheckpointRecord(store: Store, io: std.Io, stream: StreamIdentity, sequence: u64) !void {
    try store.append(io, .{ .stream = stream, .record = .{ .type_id = 1, .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = sequence, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &.{7} } });
}

test "memory journal rotation counts retained business history in the shared archive quota" {
    const memory = try std.testing.allocator.create(MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const store = memory.interface();
    const origin: business_history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 779 }, .account = 9 };
    const records = [_]business_history.Record{.{ .bytes = "retained history", .payload_digest = business_history.hash("retained history") }};
    const entries = [_]business_history.Entry{.{ .key = .{ .origin = origin, .identity = .{ .order = 1 } }, .record_index = 0 }};
    _ = try store.publishOrderHistory(undefined, .{ .origin = origin, .barrier = 1, .epoch = 1, .qualification_digest = business_history.hash("quota qualification"), .records = &records, .entries = &entries });
    const stream: StreamIdentity = .{ .domain = .control, .id = 780 };
    try appendCheckpointRecord(store, undefined, stream, 1);
    try store.commit(undefined, stream, 1);
    try store.seal(undefined, stream);
    try store.publishSnapshot(undefined, stream, 1, &.{7});
    const sealed_bytes = (try store.recover(undefined, stream)).active_segment.len;
    const history_bytes = memory.history_objects.items.len;
    memory.archive_quota = history_bytes + sealed_bytes - 1;
    try std.testing.expectError(error.NoSpaceLeft, store.rotate(undefined, stream));
    try std.testing.expectEqual(GateState.closed, store.safetyGate());
    try std.testing.expectEqual(@as(usize, 0), memory.archive_bytes);
    try std.testing.expectEqual(history_bytes, memory.history_objects.items.len);
}

const CountSegments = struct {
    records: u64 = 0,
    fn consume(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *CountSegments = @ptrCast(@alignCast(ptr));
        var reader = try journal.Reader.init(bytes);
        while (true) switch (try reader.next()) {
            .record => |record| {
                try std.testing.expectEqual(self.records + 1, record.sequence);
                self.records += 1;
            },
            .end => break,
        };
    }
};

test "checkpoint store local file 100 rotations retain audit and two snapshot generations" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 900 };
    var adapter: LinuxFileAdapter = .{ .dir = temp.dir };
    const store = adapter.interface();
    var first_root: [32]u8 = undefined;
    for (1..101) |sequence| {
        try appendCheckpointRecord(store, io, stream, sequence);
        try store.commit(io, stream, sequence);
        try store.seal(io, stream);
        const snapshot = [_]u8{@intCast(sequence)};
        try store.publishSnapshot(io, stream, sequence, &snapshot);
        try store.rotate(io, stream);
        const receipt = try store.archiveReceipt(io, stream);
        try std.testing.expectEqual(@as(u64, sequence), receipt.covered_last);
        if (sequence == 1) first_root = receipt.ordered_root;
    }
    var reopened: LinuxFileAdapter = .{ .dir = temp.dir };
    const reopened_store = reopened.interface();
    const recovered = try reopened_store.recover(io, stream);
    try std.testing.expectEqual(RecoveryStatus.ready, recovered.status);
    try std.testing.expectEqual(@as(u64, 100), recovered.last_sequence);
    try std.testing.expect(try reopened_store.verifyArchiveReceipt(io, stream, 1, first_root));
    var counter: CountSegments = .{};
    try reopened_store.replaySegments(io, stream, .{ .ptr = &counter, .consume_fn = CountSegments.consume });
    try std.testing.expectEqual(@as(u64, 100), counter.records);
    const active = try findManifest(&reopened.manifest, stream, recovered.segment_index, false);
    const bad_snapshot = try snapshotObjectName(stream, active.snapshot_barrier, active.snapshot_digest);
    try writeFile(temp.dir, io, bad_snapshot.slice(), &.{0}, true);
    var fallback: LinuxFileAdapter = .{ .dir = temp.dir };
    const old = try fallback.interface().recover(io, stream);
    try std.testing.expectEqual(RecoveryStatus.ready, old.status);
    try std.testing.expectEqual(@as(u64, 99), old.snapshot_barrier);
    try std.testing.expectEqual(@as(u8, 1), old.tail_count);
    var tail_reader = try journal.Reader.init(old.tail_segments[0]);
    try std.testing.expectEqual(@as(u64, 100), (try tail_reader.next()).record.sequence);
    const missing = try segmentName(stream, 99);
    try temp.dir.deleteFile(io, missing.slice());
    var broken: LinuxFileAdapter = .{ .dir = temp.dir };
    try std.testing.expectEqual(RecoveryStatus.recovery_only, (try broken.interface().recover(io, stream)).status);
}

test "checkpoint store shared seven streams reclaim active metadata and replay memory history" {
    var memory = MemoryAdapter.init();
    memory.allocator = std.testing.allocator;
    defer memory.deinit();
    const store = memory.interface();
    for (1..101) |sequence| for (0..7) |id| {
        const stream: StreamIdentity = .{ .domain = if (id < 4) .decision_log else if (id == 4) .raw_ingress else .control, .id = id + 1 };
        try appendCheckpointRecord(store, undefined, stream, sequence);
        try store.commit(undefined, stream, sequence);
        try store.seal(undefined, stream);
        try store.publishSnapshot(undefined, stream, sequence, &.{7});
        try store.rotate(undefined, stream);
    };
    var used: usize = 0;
    for (memory.manifest) |entry| if (entry.used) {
        used += 1;
    };
    try std.testing.expectEqual(@as(usize, 7), used);
    std.debug.print("store_layout: stream_cache={d}, memory_adapter={d}, file_adapter={d}, manifest_bound={d}, archived_descriptor={d}, snapshot_bound={d}\n", .{ @sizeOf(Stream), @sizeOf(MemoryAdapter), @sizeOf(LinuxFileAdapter), manifest_header_len + max_manifest_entries * manifest_entry_len, archive_page_len + 32, max_snapshot_bytes });
    try std.testing.expect(@sizeOf(Stream) < 256 * 1024);
    try std.testing.expect(manifest_header_len + max_manifest_entries * manifest_entry_len < 16 * 1024 * 1024);
    for (0..7) |id| {
        const stream: StreamIdentity = .{ .domain = if (id < 4) .decision_log else if (id == 4) .raw_ingress else .control, .id = id + 1 };
        var counter: CountSegments = .{};
        try store.replaySegments(undefined, stream, .{ .ptr = &counter, .consume_fn = CountSegments.consume });
        try std.testing.expectEqual(@as(u64, 100), counter.records);
        const receipt = try store.archiveReceipt(undefined, stream);
        try std.testing.expect(try store.verifyArchiveReceipt(undefined, stream, 100, receipt.ordered_root));
    }
}

test "checkpoint store file fault boundaries select complete old or new roots" {
    const faults = [_]Fault{ .short_write, .sync_timeout, .enospc, .eio, .corruption };
    const points = [_]FaultPoint{ .append, .commit, .seal, .publish, .rotate, .snapshot_sync, .archive_sync, .root_publish, .reclaim };
    for (faults) |fault| for (points) |point| {
        var temp = std.testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        const io = std.testing.io;
        const stream: StreamIdentity = .{ .domain = .decision_log, .id = 20 };
        var adapter: LinuxFileAdapter = .{ .dir = temp.dir };
        const store = adapter.interface();
        try appendCheckpointRecord(store, io, stream, 1);
        try store.commit(io, stream, 1);
        try store.seal(io, stream);
        try store.publishSnapshot(io, stream, 1, &.{1});
        try store.rotate(io, stream);
        if (point == .append) {
            adapter.injectFaultAt(fault, point);
            try std.testing.expectError(faultErrorValue(fault), appendCheckpointRecord(store, io, stream, 2));
        } else {
            try appendCheckpointRecord(store, io, stream, 2);
            if (point == .commit) {
                adapter.injectFaultAt(fault, point);
                try std.testing.expectError(faultErrorValue(fault), store.commit(io, stream, 2));
            } else {
                try store.commit(io, stream, 2);
                if (point == .seal) {
                    adapter.injectFaultAt(fault, point);
                    try std.testing.expectError(faultErrorValue(fault), store.seal(io, stream));
                } else {
                    try store.seal(io, stream);
                    if (point == .publish or point == .snapshot_sync or point == .root_publish or point == .reclaim) {
                        adapter.injectFaultAt(fault, point);
                        try std.testing.expectError(faultErrorValue(fault), store.publishSnapshot(io, stream, 2, &.{2}));
                    } else {
                        try store.publishSnapshot(io, stream, 2, &.{2});
                        adapter.injectFaultAt(fault, point);
                        try std.testing.expectError(faultErrorValue(fault), store.rotate(io, stream));
                    }
                }
            }
        }
        try std.testing.expectEqual(GateState.closed, store.safetyGate());
        var reopened: LinuxFileAdapter = .{ .dir = temp.dir };
        const recovered = try reopened.interface().recover(io, stream);
        try std.testing.expectEqual(RecoveryStatus.ready, recovered.status);
        try std.testing.expect(recovered.last_sequence == 1 or recovered.last_sequence == 2);
        try std.testing.expect(recovered.snapshot_barrier == 1 or recovered.snapshot_barrier == 2);
        const receipt = try reopened.interface().archiveReceipt(io, stream);
        try std.testing.expect(receipt.covered_last == 1 or receipt.covered_last == 2);
        try std.testing.expect(try reopened.interface().verifyArchiveReceipt(io, stream, receipt.covered_last, receipt.ordered_root));
    };
}

fn faultErrorValue(fault: Fault) anyerror {
    faultError(fault) catch |err| return err;
    unreachable;
}

test "checkpoint store rejects overflow and conflicting snapshot identity without reclaiming roots" {
    var memory = MemoryAdapter.initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const store = memory.interface();
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 42 };
    try appendCheckpointRecord(store, undefined, stream, 1);
    try store.commit(undefined, stream, 1);
    try store.seal(undefined, stream);
    try store.publishSnapshot(undefined, stream, 1, &.{1});
    try store.publishSnapshot(undefined, stream, 1, &.{1});
    try std.testing.expectError(error.SnapshotIdentityConflict, store.publishSnapshot(undefined, stream, 1, &.{2}));
    try std.testing.expectEqualSlices(u8, &.{1}, (try store.recover(undefined, stream)).snapshot);
    const resident = try findStream(&memory.streams, stream, false);
    memory.gate = .open;
    resident.segment_index = std.math.maxInt(u32);
    const entry = &memory.manifest[0];
    entry.segment_index = resident.segment_index;
    try std.testing.expectError(error.Overflow, store.rotate(undefined, stream));
    try std.testing.expectEqual(@as(usize, 0), memory.archive.items.len);
    memory.gate = .open;
    resident.journal = journal.Journal.initAt(std.math.maxInt(u64));
    resident.journal.last_sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.SequenceExhausted, appendCheckpointRecord(store, undefined, stream, 0));
}

test "checkpoint store snapshot reclaim commits references before obsolete object deletion" {
    const io = std.testing.io;
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 77 };
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var adapter: LinuxFileAdapter = .{ .dir = temp.dir };
    const store = adapter.interface();
    for (1..4) |sequence| {
        try appendCheckpointRecord(store, io, stream, sequence);
        try store.commit(io, stream, sequence);
        try store.seal(io, stream);
        const body = [_]u8{@intCast(sequence)};
        if (sequence == 3) {
            adapter.injectFaultAt(.sync_timeout, .reclaim);
            try std.testing.expectError(error.SyncTimeout, store.publishSnapshot(io, stream, sequence, &body));
        } else {
            try store.publishSnapshot(io, stream, sequence, &body);
            try store.rotate(io, stream);
        }
    }
    const first_name = try snapshotObjectName(stream, 1, digest(&.{1}));
    var old_file = try temp.dir.openFile(io, first_name.slice(), .{});
    old_file.close(io);
    var reopened: LinuxFileAdapter = .{ .dir = temp.dir };
    var recovered = try reopened.interface().recover(io, stream);
    try std.testing.expectEqual(RecoveryStatus.ready, recovered.status);
    try std.testing.expectEqual(@as(u64, 3), recovered.snapshot_barrier);
    const entry = try findManifest(&reopened.manifest, stream, recovered.segment_index, false);
    try std.testing.expectEqual(@as(u64, 2), entry.previous_snapshot_barrier);
    const latest_name = try snapshotObjectName(stream, 3, digest(&.{3}));
    try writeFile(temp.dir, io, latest_name.slice(), &.{0}, true);
    var fallback: LinuxFileAdapter = .{ .dir = temp.dir };
    recovered = try fallback.interface().recover(io, stream);
    try std.testing.expectEqual(RecoveryStatus.ready, recovered.status);
    try std.testing.expectEqual(@as(u64, 2), recovered.snapshot_barrier);
    try std.testing.expectEqual(@as(u8, 1), recovered.tail_count);
}

test "checkpoint store bounded replay reads only requested horizon and rejects byte budget before delivery" {
    const io = std.testing.io;
    const stream: StreamIdentity = .{ .domain = .raw_ingress, .id = 91 };
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var adapter: LinuxFileAdapter = .{ .dir = temp.dir };
    const store = adapter.interface();
    for (1..101) |sequence| {
        try appendCheckpointRecord(store, io, stream, sequence);
        try store.commit(io, stream, sequence);
        try store.seal(io, stream);
        try store.publishSnapshot(io, stream, sequence, &.{1});
        try store.rotate(io, stream);
    }
    const outside_horizon = try segmentName(stream, 0);
    try writeFile(temp.dir, io, outside_horizon.slice(), &.{0}, true);
    var reopened: LinuxFileAdapter = .{ .dir = temp.dir };
    var counter: CountSegments = .{ .records = 98 };
    try reopened.interface().replaySegmentsAfter(io, stream, 98, 1024, .{ .ptr = &counter, .consume_fn = CountSegments.consume });
    try std.testing.expectEqual(@as(u64, 100), counter.records);
    var bounded: LinuxFileAdapter = .{ .dir = temp.dir };
    counter.records = 98;
    try std.testing.expectError(error.ReplayByteBudgetExceeded, bounded.interface().replaySegmentsAfter(io, stream, 98, 1, .{ .ptr = &counter, .consume_fn = CountSegments.consume }));
    try std.testing.expectEqual(@as(u64, 98), counter.records);
    try std.testing.expectEqual(GateState.closed, bounded.interface().safetyGate());
}

fn checkVirginCommittedRecovery(store: Store, io: std.Io, stream: StreamIdentity) !void {
    try appendCheckpointRecord(store, io, stream, 1);
    try appendCheckpointRecord(store, io, stream, 2);
    try store.commit(io, stream, 2);
    const recovered = try store.recover(io, stream);
    try std.testing.expectEqual(RecoveryStatus.recovery_only, recovered.status);
    try std.testing.expectEqual(GateState.open, recovered.gate);
    try std.testing.expectEqual(GateState.open, store.safetyGate());
    try std.testing.expectEqual(@as(u64, 2), recovered.committed_barrier);
    try std.testing.expectEqual(@as(u64, 2), recovered.last_sequence);
    try std.testing.expectEqual(@as(usize, 0), recovered.snapshot.len);
    var count: CountSegments = .{};
    try CountSegments.consume(&count, recovered.tail);
    try std.testing.expectEqual(@as(u64, 2), count.records);
    try appendCheckpointRecord(store, io, stream, 3);
}

test "checkpoint store virgin committed journal remains available before first snapshot" {
    const stream: StreamIdentity = .{ .domain = .raw_ingress, .id = 52 };
    var memory = MemoryAdapter.initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    try checkVirginCommittedRecovery(memory.interface(), undefined, stream);
    memory.manifest[0].archive_root = @splat(7);
    const invalid_memory = try memory.interface().recover(undefined, stream);
    try std.testing.expectEqual(GateState.closed, invalid_memory.gate);
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var file: LinuxFileAdapter = .{ .dir = temp.dir };
    try checkVirginCommittedRecovery(file.interface(), std.testing.io, stream);
    file.manifest[0].archived_barrier = 1;
    try file.writeManifest(std.testing.io, true);
    const invalid_file = try file.interface().recover(std.testing.io, stream);
    try std.testing.expectEqual(GateState.closed, invalid_file.gate);
}

const ReentrantSegmentCheck = struct {
    store: Store,
    io: std.Io,
    other_stream: StreamIdentity,
    fn consume(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *ReentrantSegmentCheck = @ptrCast(@alignCast(ptr));
        var reader = try journal.Reader.init(bytes);
        try std.testing.expectEqual(@as(u64, 1), (try reader.next()).record.sequence);
        try appendCheckpointRecord(self.store, self.io, self.other_stream, 4);
        try std.testing.expectEqual(@as(u64, 2), (try reader.next()).record.sequence);
        try std.testing.expectEqual(journal.ScanStatus.clean, (try reader.next()).end);
    }
};

test "checkpoint store archived replay remains stable across callback writes to another stream" {
    const io = std.testing.io;
    const raw: StreamIdentity = .{ .domain = .raw_ingress, .id = 120 };
    const decision: StreamIdentity = .{ .domain = .decision_log, .id = 121 };
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var adapter: LinuxFileAdapter = .{ .dir = temp.dir };
    const store = adapter.interface();
    try appendCheckpointRecord(store, io, decision, 1);
    try store.commit(io, decision, 1);
    try store.seal(io, decision);
    try store.publishSnapshot(io, decision, 1, &.{1});
    try store.rotate(io, decision);
    try appendCheckpointRecord(store, io, decision, 2);
    try appendCheckpointRecord(store, io, decision, 3);
    try store.commit(io, decision, 3);
    try appendCheckpointRecord(store, io, raw, 1);
    try appendCheckpointRecord(store, io, raw, 2);
    try store.commit(io, raw, 2);
    try store.seal(io, raw);
    try store.publishSnapshot(io, raw, 2, &.{2});
    try store.rotate(io, raw);
    var reopened: LinuxFileAdapter = .{ .dir = temp.dir };
    var checker: ReentrantSegmentCheck = .{ .store = reopened.interface(), .io = io, .other_stream = decision };
    try reopened.interface().replaySegmentsAfter(io, raw, 0, 1024, .{ .ptr = &checker, .consume_fn = ReentrantSegmentCheck.consume });
}

test "checkpoint store memory receipts require current root ancestry and stream namespace" {
    var memory = MemoryAdapter.initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const store = memory.interface();
    const raw: StreamIdentity = .{ .domain = .raw_ingress, .id = 121 };
    const decision: StreamIdentity = .{ .domain = .decision_log, .id = 121 };
    var old: ArchiveReceipt = undefined;
    for (1..3) |sequence| {
        try appendCheckpointRecord(store, undefined, raw, sequence);
        try store.commit(undefined, raw, sequence);
        try store.seal(undefined, raw);
        try store.publishSnapshot(undefined, raw, sequence, &.{1});
        try store.rotate(undefined, raw);
        if (sequence == 1) old = try store.archiveReceipt(undefined, raw);
    }
    const latest = try store.archiveReceipt(undefined, raw);
    try std.testing.expect(try store.verifyArchiveReceipt(undefined, raw, 1, old.ordered_root));
    try std.testing.expect(try store.verifyArchiveReceipt(undefined, raw, 2, latest.ordered_root));
    const entry = try findManifest(&memory.manifest, raw, 2, false);
    entry.archive_root = old.ordered_root;
    try std.testing.expectError(error.ArchiveRootConflict, store.verifyArchiveReceipt(undefined, raw, 2, latest.ordered_root));
    memory.gate = .open;
    entry.archive_root = latest.ordered_root;
    try appendCheckpointRecord(store, undefined, decision, 1);
    try store.commit(undefined, decision, 1);
    try store.seal(undefined, decision);
    try store.publishSnapshot(undefined, decision, 1, &.{1});
    try store.rotate(undefined, decision);
    try appendCheckpointRecord(store, undefined, decision, 2);
    try store.commit(undefined, decision, 2);
    try store.seal(undefined, decision);
    try store.publishSnapshot(undefined, decision, 2, &.{1});
    try store.rotate(undefined, decision);
    entry.archive_root = (try store.archiveReceipt(undefined, decision)).ordered_root;
    try std.testing.expectError(error.ArchiveRootConflict, store.archiveReceipt(undefined, raw));
    memory.gate = .open;
    try std.testing.expectEqual(RecoveryStatus.recovery_only, (try store.recover(undefined, raw)).status);
}

fn replaceCurrentRecordSchema(stream: *Stream) void {
    const record_offset = journal.segment_header_size;
    put(u16, &stream.journal.storage, record_offset + 10, production_contract.previous_journal_schema_version);
    put(u32, &stream.journal.storage, record_offset + 68, Crc32c.hash(stream.journal.storage[record_offset..][0..68]));
}

fn prepareSchemaRecoveryFixture(store: Store, io: std.Io, stream: StreamIdentity) !void {
    try appendCheckpointRecord(store, io, stream, 1);
    try store.commit(io, stream, 1);
    try store.seal(io, stream);
    try store.publishSnapshot(io, stream, 1, &.{1});
    try store.rotate(io, stream);
    try appendCheckpointRecord(store, io, stream, 2);
    try store.commit(io, stream, 2);
}

test "checkpoint store rejects unknown journal schema despite valid frame manifest and payload checksums" {
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 140 };
    var memory = MemoryAdapter.initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    try prepareSchemaRecoveryFixture(memory.interface(), undefined, stream);
    const resident = try findStream(&memory.streams, stream, false);
    replaceCurrentRecordSchema(resident);
    const entry = try findManifest(&memory.manifest, stream, 1, false);
    entry.digest = digest(resident.journal.bytes());
    const unknown = try memory.interface().recover(undefined, stream);
    try std.testing.expectEqual(RecoveryStatus.recovery_only, unknown.status);
    try std.testing.expectEqual(GateState.closed, unknown.gate);
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var file: LinuxFileAdapter = .{ .dir = temp.dir };
    try prepareSchemaRecoveryFixture(file.interface(), std.testing.io, stream);
    const file_resident = try findStream(&file.streams, stream, false);
    replaceCurrentRecordSchema(file_resident);
    try file.persistSegment(std.testing.io, file_resident, true);
    const bad_file = try file.interface().recover(std.testing.io, stream);
    try std.testing.expectEqual(RecoveryStatus.recovery_only, bad_file.status);
    try std.testing.expectEqual(GateState.closed, bad_file.gate);
}

test "checkpoint store publishes after fallback while preserving two valid generations" {
    const io = std.testing.io;
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 150 };
    var memory = MemoryAdapter.initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var file: LinuxFileAdapter = .{ .dir = temp.dir };
    const stores = [_]Store{ memory.interface(), file.interface() };
    for (stores, 0..) |store, adapter_index| {
        const store_io = if (adapter_index == 0) undefined else io;
        for (1..3) |sequence| {
            try appendCheckpointRecord(store, store_io, stream, sequence);
            try store.commit(store_io, stream, sequence);
            try store.seal(store_io, stream);
            const body = [_]u8{@intCast(sequence)};
            try store.publishSnapshot(store_io, stream, sequence, &body);
            try store.rotate(store_io, stream);
        }
        if (adapter_index == 0) memory.snapshots[0][0] ^= 1 else {
            const name = try snapshotObjectName(stream, 2, digest(&.{2}));
            try writeFile(temp.dir, io, name.slice(), &.{0}, true);
        }
        try std.testing.expectEqual(@as(u64, 1), (try store.recover(store_io, stream)).snapshot_barrier);
        try appendCheckpointRecord(store, store_io, stream, 3);
        try store.commit(store_io, stream, 3);
        try store.seal(store_io, stream);
        try store.publishSnapshot(store_io, stream, 3, &.{3});
        try store.rotate(store_io, stream);
        try appendCheckpointRecord(store, store_io, stream, 4);
        try store.commit(store_io, stream, 4);
        if (adapter_index == 0) memory.snapshots[0][0] ^= 1 else {
            const name = try snapshotObjectName(stream, 3, digest(&.{3}));
            try writeFile(temp.dir, io, name.slice(), &.{0}, true);
        }
        const fallback = try store.recover(store_io, stream);
        try std.testing.expectEqual(RecoveryStatus.ready, fallback.status);
        try std.testing.expectEqual(@as(u64, 1), fallback.snapshot_barrier);
        try std.testing.expectEqual(@as(u8, 3), fallback.tail_count);
        var count: CountSegments = .{ .records = 1 };
        for (fallback.tail_segments[0..fallback.tail_count]) |segment| try CountSegments.consume(&count, segment);
        try std.testing.expectEqual(@as(u64, 4), count.records);
    }
}

test "large resident snapshots survive memory publication and two file reopens" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, 1024 * 1024 + 1024);
    defer allocator.free(bytes);
    @memset(bytes, 71);
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 805 };
    const memory = try allocator.create(MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    try appendCheckpointRecord(memory.interface(), undefined, stream, 1);
    try memory.interface().commit(undefined, stream, 1);
    try memory.interface().seal(undefined, stream);
    try memory.interface().publishSnapshot(undefined, stream, 1, bytes);
    try std.testing.expectEqualSlices(u8, bytes, (try memory.interface().recover(undefined, stream)).snapshot);
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const file = try allocator.create(LinuxFileAdapter);
    defer allocator.destroy(file);
    file.* = .{ .dir = temp.dir };
    defer file.deinit();
    const io = std.testing.io;
    try appendCheckpointRecord(file.interface(), io, stream, 1);
    try file.interface().commit(io, stream, 1);
    try file.interface().seal(io, stream);
    try file.interface().publishSnapshot(io, stream, 1, bytes);
    try file.interface().publishSnapshot(io, stream, 1, bytes);
    const reopened = try allocator.create(LinuxFileAdapter);
    defer allocator.destroy(reopened);
    reopened.* = .{ .dir = temp.dir };
    defer reopened.deinit();
    try std.testing.expectEqualSlices(u8, bytes, (try reopened.interface().recover(io, stream)).snapshot);
    try reopened.interface().rotate(io, stream);
    try appendCheckpointRecord(reopened.interface(), io, stream, 2);
    try reopened.interface().commit(io, stream, 2);
    try reopened.interface().seal(io, stream);
    @memset(bytes, 93);
    try reopened.interface().publishSnapshot(io, stream, 2, bytes);
    const second_reopen = try allocator.create(LinuxFileAdapter);
    defer allocator.destroy(second_reopen);
    second_reopen.* = .{ .dir = temp.dir };
    defer second_reopen.deinit();
    const recovered = try second_reopen.interface().recover(io, stream);
    try std.testing.expectEqual(@as(u64, 2), recovered.snapshot_barrier);
    try std.testing.expectEqualSlices(u8, bytes, recovered.snapshot);
}

test "committed recovery prefix retains physical uncommitted suffix across file reopen" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const file = try allocator.create(LinuxFileAdapter);
    defer allocator.destroy(file);
    file.* = .{ .dir = temp.dir };
    defer file.deinit();
    const reopened = try allocator.create(LinuxFileAdapter);
    defer allocator.destroy(reopened);
    reopened.* = .{ .dir = temp.dir };
    defer reopened.deinit();
    const io = std.testing.io;
    for ([_]Store{ memory.interface(), file.interface() }, 0..) |store, index| {
        const store_io = if (index == 0) undefined else io;
        const stream: StreamIdentity = .{ .domain = .decision_log, .id = 806 };
        try appendCheckpointRecord(store, store_io, stream, 1);
        try store.commit(store_io, stream, 1);
        try store.seal(store_io, stream);
        try store.publishSnapshot(store_io, stream, 1, &.{71});
        try store.rotate(store_io, stream);
        try appendCheckpointRecord(store, store_io, stream, 2);
        try store.commit(store_io, stream, 2);
        try appendCheckpointRecord(store, store_io, stream, 3);
        const physical = try store.recover(store_io, stream);
        const original_digest = digest(physical.active_segment);
        const recovered = try (if (index == 0) store else reopened.interface()).recover(store_io, stream);
        try std.testing.expectEqual(@as(u64, 3), recovered.last_sequence);
        try std.testing.expectEqual(@as(u64, 2), recovered.committed_barrier);
        try std.testing.expectEqualSlices(u8, &original_digest, &digest(recovered.active_segment));
        var committed = try journal.Reader.init(recovered.tail);
        switch (try committed.next()) {
            .record => |record| try std.testing.expectEqual(@as(u64, 2), record.sequence),
            .end => return error.MissingCommittedRecord,
        }
        switch (try committed.next()) {
            .record => return error.ReplayedUncommittedRecord,
            .end => {},
        }
        var all = try journal.Reader.init(recovered.active_segment);
        _ = try all.next();
        switch (try all.next()) {
            .record => |record| try std.testing.expectEqual(@as(u64, 3), record.sequence),
            .end => return error.LostPhysicalSuffix,
        }
    }
}

test "committed recovery prefix excludes a partial crash frame without modifying bytes" {
    var log = journal.Journal.init();
    const record: journal.Record = .{ .type_id = 1, .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = 1, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &.{71} };
    try log.append(record);
    const committed_len = log.bytes().len;
    var next = record;
    next.sequence = 2;
    try log.append(next);
    const partial = log.bytes()[0 .. committed_len + 10];
    const before = digest(partial);
    const prefix = try committedJournalPrefix(partial, 1);
    try std.testing.expectEqual(committed_len, prefix.len);
    try std.testing.expectEqualSlices(u8, log.bytes()[0..committed_len], prefix);
    try std.testing.expectEqualSlices(u8, &before, &digest(partial));
}

test "optimization memory overflow snapshot rotation preserves borrowed buffers and inline transitions" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const store = memory.interface();
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 807 };
    const large = try allocator.alloc(u8, inline_snapshot_bytes + 1024);
    defer allocator.free(large);
    @memset(large, 71);
    for (1..8) |sequence| {
        try appendCheckpointRecord(store, undefined, stream, sequence);
        try store.commit(undefined, stream, sequence);
        try store.seal(undefined, stream);
        const bytes: []const u8 = switch (sequence) {
            1, 3 => large,
            2 => &.{93},
            4 => memory.large_snapshots[0].items,
            5 => &.{93},
            6 => memory.large_previous_snapshots[0].items,
            7 => memory.large_snapshots[0].items,
            else => unreachable,
        };
        try store.publishSnapshot(undefined, stream, sequence, bytes);
        const recovered = try store.recover(undefined, stream);
        try std.testing.expectEqual(sequence, recovered.snapshot_barrier);
        try std.testing.expectEqualSlices(u8, if (sequence == 2 or sequence == 5) &.{93} else large, recovered.snapshot);
        try store.rotate(undefined, stream);
    }
    memory.large_snapshots[0].items[0] ^= 1;
    const fallback = try store.recover(undefined, stream);
    try std.testing.expectEqual(@as(u64, 6), fallback.snapshot_barrier);
    try std.testing.expectEqualSlices(u8, large, fallback.snapshot);
}

test "optimization memory overflow snapshot allocation failure retains previous committed generation" {
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const memory = try allocator.create(MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(failing.allocator());
    defer memory.deinit();
    const store = memory.interface();
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 808 };
    const large = try allocator.alloc(u8, inline_snapshot_bytes + 1024);
    defer allocator.free(large);
    @memset(large, 71);
    try appendCheckpointRecord(store, undefined, stream, 1);
    try store.commit(undefined, stream, 1);
    try store.seal(undefined, stream);
    try store.publishSnapshot(undefined, stream, 1, large);
    try store.rotate(undefined, stream);
    try appendCheckpointRecord(store, undefined, stream, 2);
    try store.commit(undefined, stream, 2);
    try store.seal(undefined, stream);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, store.publishSnapshot(undefined, stream, 2, large));
    try std.testing.expectEqual(GateState.closed, store.safetyGate());
    const recovered = try store.recover(undefined, stream);
    try std.testing.expectEqual(@as(u64, 1), recovered.snapshot_barrier);
    try std.testing.expectEqualSlices(u8, large, recovered.snapshot);
}

test "optimization memory inline snapshot publication preserves borrowed previous input" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const store = memory.interface();
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 809 };
    for (1..4) |sequence| {
        try appendCheckpointRecord(store, undefined, stream, sequence);
        try store.commit(undefined, stream, sequence);
        try store.seal(undefined, stream);
        const bytes: []const u8 = switch (sequence) {
            1 => &.{71},
            2 => &.{93},
            3 => memory.previous_snapshots[0][0..1],
            else => unreachable,
        };
        try store.publishSnapshot(undefined, stream, sequence, bytes);
        try std.testing.expectEqualSlices(u8, if (sequence == 2) &.{93} else &.{71}, (try store.recover(undefined, stream)).snapshot);
        try store.rotate(undefined, stream);
    }
}
