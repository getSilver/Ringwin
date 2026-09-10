//! Durable persistence seam for authoritative trading state.
//! Callers see streams, barriers, snapshots, and recovery only. File names,
//! sync ordering, manifests, and legal tail handling stay inside this module.

const builtin = @import("builtin");
const std = @import("std");
const journal = @import("journal.zig");
const production_contract = @import("production_contract.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Crc32c = std.hash.crc.Crc32Iscsi;

pub const max_streams = 8;
pub const max_segment_bytes = 16 * 1024;
pub const max_snapshot_bytes = 48 * 1024;
pub const max_manifest_entries = 32;

const manifest_magic: u32 = 0x544e414d; // MANT
const snapshot_magic: u32 = 0x504e5352; // RSNP
const format_schema: u16 = 1;
const manifest_schema: u16 = 2;
const manifest_header_len = 16;
const manifest_entry_len = 96;
const snapshot_header_len = 96;

const FileName = struct {
    bytes: [96]u8 = undefined,
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

pub const Recovery = struct {
    status: RecoveryStatus,
    snapshot: []const u8,
    tail: []const u8,
    committed_barrier: u64,
    last_sequence: u64,
    segment_index: u32,
    segment_digest: [Sha256.digest_length]u8,
    gate: GateState,
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
    };

    pub fn append(self: Store, io: std.Io, request: Append) !void {
        return self.vtable.append(self.context, io, request);
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

    pub fn safetyGate(self: Store) GateState {
        return self.vtable.gate(self.context);
    }
};

const Stream = struct {
    used: bool = false,
    identity: StreamIdentity = .{ .domain = .control, .id = 0 },
    segment_index: u32 = 0,
    committed_barrier: u64 = 0,
    journal: journal.Journal = journal.Journal.init(),
    raw: [max_segment_bytes]u8 = undefined,
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
};

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

fn findStream(streams: *[max_streams]Stream, identity: StreamIdentity, create: bool) !*Stream {
    for (streams) |*stream| if (stream.used and sameStream(stream.identity, identity)) return stream;
    if (!create) return error.StreamNotFound;
    for (streams) |*stream| if (!stream.used) {
        stream.* = .{ .used = true, .identity = identity, .journal = journal.Journal.init() };
        return stream;
    };
    return error.StreamCapacity;
}

fn findManifest(entries: *[max_manifest_entries]ManifestEntry, identity: StreamIdentity, segment_index: u32, create: bool) !*ManifestEntry {
    for (entries) |*entry| if (entry.used and sameStream(entry.identity, identity) and entry.segment_index == segment_index) return entry;
    if (!create) return error.ManifestEntryMissing;
    for (entries) |*entry| if (!entry.used) {
        entry.* = .{ .used = true, .identity = identity, .segment_index = segment_index };
        return entry;
    };
    return error.ManifestCapacity;
}

fn verifyJournal(stream: *const Stream) !RecoveryStatus {
    var reader = try journal.Reader.init(stream.journal.bytes());
    while (true) switch (try reader.next()) {
        .record => {},
        // A short final frame is a legal crash tail. The reader has already
        // verified every complete record before it, so replay may stop here.
        .end => break,
    };
    return .ready;
}

fn firstSequence(stream: *const Stream) u64 {
    return if (stream.journal.records == 0) stream.journal.last_sequence + 1 else stream.journal.last_sequence - stream.journal.records + 1;
}

fn snapshotTailIsContinuous(stream: *const Stream, barrier: u64) bool {
    return barrier != 0 and (barrier == stream.journal.last_sequence or firstSequence(stream) == barrier + 1);
}

pub const MemoryAdapter = struct {
    streams: [max_streams]Stream = @splat(.{}),
    snapshots: [max_streams][max_snapshot_bytes]u8 = undefined,
    snapshot_lens: [max_streams]usize = @splat(0),
    snapshot_barriers: [max_streams]u64 = @splat(0),
    manifest: [max_manifest_entries]ManifestEntry = @splat(.{}),
    fault: Fault = .none,
    gate: GateState = .open,

    pub fn init() MemoryAdapter {
        return .{};
    }

    pub fn interface(self: *MemoryAdapter) Store {
        return .{ .context = self, .vtable = &memory_vtable };
    }

    pub fn injectFault(self: *MemoryAdapter, fault: Fault) void {
        self.fault = fault;
    }

    fn fail(self: *MemoryAdapter, fault: Fault) !void {
        faultError(fault) catch |err| {
            self.gate = .closed;
            return err;
        };
    }

    fn appendImpl(context: *anyopaque, _: std.Io, request: Append) anyerror!void {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        try self.fail(self.fault);
        if (request.record.schema_version != production_contract.journal_schema_version) {
            self.gate = .closed;
            return error.UnsupportedJournalSchema;
        }
        const stream = try findStream(&self.streams, request.stream, true);
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
        try self.fail(self.fault);
        const stream = try findStream(&self.streams, identity, false);
        if (barrier == 0 or barrier > stream.journal.last_sequence) {
            self.gate = .closed;
            return error.InvalidCommitBarrier;
        }
        stream.committed_barrier = barrier;
        const entry = try findManifest(&self.manifest, identity, stream.segment_index, true);
        entry.committed_barrier = barrier;
    }

    fn sealImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity) anyerror!void {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        try self.fail(self.fault);
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
        stream.segment_index += 1;
        stream.journal = journal.Journal.initAt(stream.journal.last_sequence + 1);
    }

    fn publishImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity, barrier: u64, bytes: []const u8) anyerror!void {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        try self.fail(self.fault);
        if (bytes.len > max_snapshot_bytes) {
            self.gate = .closed;
            return error.SnapshotTooLarge;
        }
        const stream = try findStream(&self.streams, identity, false);
        if (!stream.journal.sealed or stream.journal.last_sequence != barrier) {
            self.gate = .closed;
            return error.SnapshotBarrierNotSealed;
        }
        const index = streamIndex(&self.streams, stream);
        @memcpy(self.snapshots[index][0..bytes.len], bytes);
        self.snapshot_lens[index] = bytes.len;
        self.snapshot_barriers[index] = barrier;
    }

    fn recoverImpl(context: *anyopaque, _: std.Io, identity: StreamIdentity) anyerror!Recovery {
        const self: *MemoryAdapter = @ptrCast(@alignCast(context));
        const stream = findStream(&self.streams, identity, false) catch return .{
            .status = .recovery_only,
            .snapshot = &.{},
            .tail = &.{},
            .committed_barrier = 0,
            .last_sequence = 0,
            .segment_index = 0,
            .segment_digest = @splat(0),
            .gate = .closed,
        };
        const index = streamIndex(&self.streams, stream);
        const scan = verifyJournal(stream) catch {
            self.gate = .closed;
            return .{ .status = .recovery_only, .snapshot = &.{}, .tail = stream.journal.bytes(), .committed_barrier = stream.committed_barrier, .last_sequence = stream.journal.last_sequence, .segment_index = stream.segment_index, .segment_digest = digest(stream.journal.bytes()), .gate = self.gate };
        };
        const ready = self.snapshot_lens[index] != 0 and scan == .ready and snapshotTailIsContinuous(stream, self.snapshot_barriers[index]);
        return .{
            .status = if (ready) .ready else .recovery_only,
            .snapshot = self.snapshots[index][0..self.snapshot_lens[index]],
            .tail = if (self.snapshot_barriers[index] == stream.journal.last_sequence) &.{} else stream.journal.bytes(),
            .committed_barrier = stream.committed_barrier,
            .last_sequence = stream.journal.last_sequence,
            .segment_index = stream.segment_index,
            .segment_digest = digest(stream.journal.bytes()),
            .gate = self.gate,
        };
    }

    fn gateImpl(context: *anyopaque) GateState {
        return @as(*MemoryAdapter, @ptrCast(@alignCast(context))).gate;
    }

    const memory_vtable: Store.VTable = .{ .append = appendImpl, .commit = commitImpl, .seal = sealImpl, .rotate = rotateImpl, .publish = publishImpl, .recover = recoverImpl, .gate = gateImpl };
};

fn streamIndex(streams: *[max_streams]Stream, target: *const Stream) usize {
    return (@intFromPtr(target) - @intFromPtr(&streams[0])) / @sizeOf(Stream);
}

pub const LinuxFileAdapter = struct {
    dir: std.Io.Dir,
    streams: [max_streams]Stream = @splat(.{}),
    snapshots: [max_streams][max_snapshot_bytes]u8 = undefined,
    snapshot_lens: [max_streams]usize = @splat(0),
    snapshot_barriers: [max_streams]u64 = @splat(0),
    manifest: [max_manifest_entries]ManifestEntry = @splat(.{}),
    manifest_loaded: bool = false,
    fault: Fault = .none,
    gate: GateState = .open,

    pub fn open(io: std.Io, absolute_path: []const u8) !LinuxFileAdapter {
        if (builtin.os.tag != .linux) return error.LinuxStoreRequired;
        std.Io.Dir.createDirAbsolute(io, absolute_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return .{ .dir = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{}) };
    }

    pub fn close(self: *LinuxFileAdapter, io: std.Io) void {
        self.dir.close(io);
    }

    pub fn interface(self: *LinuxFileAdapter) Store {
        return .{ .context = self, .vtable = &file_vtable };
    }

    pub fn injectFault(self: *LinuxFileAdapter, fault: Fault) void {
        self.fault = fault;
    }

    fn fail(self: *LinuxFileAdapter, fault: Fault) !void {
        faultError(fault) catch |err| {
            self.gate = .closed;
            return err;
        };
    }

    fn loadManifest(self: *LinuxFileAdapter, io: std.Io) !void {
        if (self.manifest_loaded) return;
        self.manifest_loaded = true;
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
            self.decodeManifestEntry(&self.manifest[index], encoded);
        }
    }

    fn decodeManifestEntry(_: *LinuxFileAdapter, entry: *ManifestEntry, encoded: []const u8) void {
        entry.* = .{ .used = true, .identity = .{ .domain = @enumFromInt(encoded[0]), .id = get(u64, encoded, 8) }, .segment_index = get(u32, encoded, 16), .records = get(u32, encoded, 20), .first_sequence = get(u64, encoded, 24), .last_sequence = get(u64, encoded, 32), .committed_barrier = get(u64, encoded, 40), .byte_len = get(u32, encoded, 48), .digest = undefined };
        @memcpy(&entry.digest, encoded[52..84]);
    }

    fn loadStream(self: *LinuxFileAdapter, io: std.Io, identity: StreamIdentity, create: bool) !*Stream {
        if (findStream(&self.streams, identity, false)) |stream| return stream else |_| {}
        try self.loadManifest(io);
        var selected: ?ManifestEntry = null;
        for (self.manifest) |entry| {
            if (entry.used and sameStream(entry.identity, identity) and (selected == null or entry.segment_index > selected.?.segment_index)) selected = entry;
        }
        const stream = if (create or selected != null)
            try findStream(&self.streams, identity, true)
        else
            return error.StreamNotFound;
        if (selected) |entry| {
            var index: u32 = 0;
            while (index <= entry.segment_index) : (index += 1) {
                var segment: ?ManifestEntry = null;
                for (self.manifest) |candidate| {
                    if (candidate.used and sameStream(candidate.identity, identity) and candidate.segment_index == index) {
                        segment = candidate;
                        break;
                    }
                }
                const current = segment orelse return error.ManifestConflict;
                const name = try segmentName(identity, index);
                const length = try readInto(self.dir, io, name.slice(), &stream.raw);
                if (length < current.byte_len or !std.mem.eql(u8, &current.digest, &digest(stream.raw[0..current.byte_len]))) return error.ManifestConflict;
                if (index == entry.segment_index) {
                    stream.segment_index = index;
                    stream.committed_barrier = current.committed_barrier;
                    // Bytes beyond the manifest are an uncommitted crash tail.
                    // The stable manifest length is the only recovery boundary.
                    try rebuildJournal(stream, stream.raw[0..current.byte_len]);
                }
            }
        }
        return stream;
    }

    fn appendImpl(context: *anyopaque, io: std.Io, request: Append) anyerror!void {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        try self.fail(self.fault);
        if (request.record.schema_version != production_contract.journal_schema_version) {
            self.gate = .closed;
            return error.UnsupportedJournalSchema;
        }
        const stream = self.loadStream(io, request.stream, true) catch |err| {
            self.gate = .closed;
            return err;
        };
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
        try self.fail(self.fault);
        const stream = self.loadStream(io, identity, false) catch |err| {
            self.gate = .closed;
            return err;
        };
        if (barrier == 0 or barrier > stream.journal.last_sequence) {
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
        try self.fail(self.fault);
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
        const stream = self.loadStream(io, identity, false) catch |err| {
            self.gate = .closed;
            return err;
        };
        if (!stream.journal.sealed) {
            self.gate = .closed;
            return error.SegmentMustBeSealedBeforeRotation;
        }
        const snapshot_index = streamIndex(&self.streams, stream);
        if (self.snapshot_lens[snapshot_index] == 0)
            _ = self.loadSnapshot(io, identity, stream, snapshot_index) catch false;
        if (self.snapshot_lens[snapshot_index] == 0 or self.snapshot_barriers[snapshot_index] != stream.journal.last_sequence) {
            self.gate = .closed;
            return error.SnapshotRequiredBeforeRotation;
        }
        stream.segment_index += 1;
        stream.journal = journal.Journal.initAt(stream.journal.last_sequence + 1);
        self.persistSegment(io, stream, true) catch |err| {
            self.gate = .closed;
            return err;
        };
    }

    fn publishImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity, barrier: u64, bytes: []const u8) anyerror!void {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        try self.fail(self.fault);
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
        var encoded: [snapshot_header_len + max_snapshot_bytes]u8 = undefined;
        @memset(encoded[0..snapshot_header_len], 0);
        put(u32, &encoded, 0, snapshot_magic);
        put(u16, &encoded, 4, format_schema);
        put(u16, &encoded, 6, snapshot_header_len);
        encoded[8] = @intFromEnum(identity.domain);
        put(u64, &encoded, 16, identity.id);
        put(u64, &encoded, 24, barrier);
        put(u32, &encoded, 32, @intCast(bytes.len));
        put(u32, &encoded, 36, Crc32c.hash(bytes));
        const snapshot_digest = digest(bytes);
        @memcpy(encoded[40..72], &snapshot_digest);
        put(u32, &encoded, 72, Crc32c.hash(encoded[0..72]));
        @memcpy(encoded[snapshot_header_len .. snapshot_header_len + bytes.len], bytes);
        const name = try snapshotName(identity);
        var temp_name: [96]u8 = undefined;
        const temp = try std.fmt.bufPrint(&temp_name, "{s}.tmp", .{name.slice()});
        writeFile(self.dir, io, temp, encoded[0 .. snapshot_header_len + bytes.len], true) catch |err| {
            self.gate = .closed;
            return err;
        };
        self.dir.rename(temp, self.dir, name.slice(), io) catch |err| {
            self.gate = .closed;
            return err;
        };
        syncDirectory(self.dir) catch |err| {
            self.gate = .closed;
            return err;
        };
        const index = streamIndex(&self.streams, stream);
        @memcpy(self.snapshots[index][0..bytes.len], bytes);
        self.snapshot_lens[index] = bytes.len;
        self.snapshot_barriers[index] = barrier;
    }

    fn recoverImpl(context: *anyopaque, io: std.Io, identity: StreamIdentity) anyerror!Recovery {
        const self: *LinuxFileAdapter = @ptrCast(@alignCast(context));
        self.loadManifest(io) catch {
            self.gate = .closed;
            return emptyRecovery(self.gate);
        };
        const stream = self.loadStream(io, identity, false) catch {
            self.gate = .closed;
            return emptyRecovery(self.gate);
        };
        const index = streamIndex(&self.streams, stream);
        const snapshot_ok = self.loadSnapshot(io, identity, stream, index) catch blk: {
            self.gate = .closed;
            break :blk false;
        };
        const scan = verifyJournal(stream) catch {
            self.gate = .closed;
            return .{ .status = .recovery_only, .snapshot = &.{}, .tail = stream.journal.bytes(), .committed_barrier = stream.committed_barrier, .last_sequence = stream.journal.last_sequence, .segment_index = stream.segment_index, .segment_digest = digest(stream.journal.bytes()), .gate = self.gate };
        };
        const ready = snapshot_ok and scan == .ready and snapshotTailIsContinuous(stream, self.snapshot_barriers[index]);
        return .{ .status = if (ready) .ready else .recovery_only, .snapshot = self.snapshots[index][0..self.snapshot_lens[index]], .tail = if (self.snapshot_barriers[index] == stream.journal.last_sequence) &.{} else stream.journal.bytes(), .committed_barrier = stream.committed_barrier, .last_sequence = stream.journal.last_sequence, .segment_index = stream.segment_index, .segment_digest = digest(stream.journal.bytes()), .gate = self.gate };
    }

    fn gateImpl(context: *anyopaque) GateState {
        return @as(*LinuxFileAdapter, @ptrCast(@alignCast(context))).gate;
    }

    const file_vtable: Store.VTable = .{ .append = appendImpl, .commit = commitImpl, .seal = sealImpl, .rotate = rotateImpl, .publish = publishImpl, .recover = recoverImpl, .gate = gateImpl };

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
            encoded[0] = @intFromEnum(entry.identity.domain);
            put(u64, encoded, 8, entry.identity.id);
            put(u32, encoded, 16, entry.segment_index);
            put(u32, encoded, 20, entry.records);
            put(u64, encoded, 24, entry.first_sequence);
            put(u64, encoded, 32, entry.last_sequence);
            put(u64, encoded, 40, entry.committed_barrier);
            put(u32, encoded, 48, entry.byte_len);
            @memcpy(encoded[52..84], &entry.digest);
            index += 1;
        };
        const encoded_len = manifest_header_len + count * manifest_entry_len;
        put(u32, &bytes, 12, manifestChecksum(bytes[0..encoded_len]));
        try writeFile(self.dir, io, "manifest.tmp", bytes[0..encoded_len], sync);
        try self.dir.rename("manifest.tmp", self.dir, "manifest.bin", io);
        if (sync) try syncDirectory(self.dir);
    }

    fn loadSnapshot(self: *LinuxFileAdapter, io: std.Io, identity: StreamIdentity, _: *Stream, index: usize) !bool {
        const name = try snapshotName(identity);
        var bytes: [snapshot_header_len + max_snapshot_bytes]u8 = undefined;
        const len = readInto(self.dir, io, name.slice(), &bytes) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        if (len < snapshot_header_len or get(u32, &bytes, 0) != snapshot_magic or get(u16, &bytes, 4) != format_schema or get(u16, &bytes, 6) != snapshot_header_len or bytes[8] > @intFromEnum(StreamDomain.control) or @as(StreamDomain, @enumFromInt(bytes[8])) != identity.domain or get(u64, &bytes, 16) != identity.id or get(u64, &bytes, 24) == 0 or get(u32, &bytes, 32) != len - snapshot_header_len or get(u32, &bytes, 36) != Crc32c.hash(bytes[snapshot_header_len..len]) or get(u32, &bytes, 72) != Crc32c.hash(bytes[0..72])) return false;
        const payload = bytes[snapshot_header_len..len];
        const expected = digest(payload);
        if (!std.mem.eql(u8, &expected, bytes[40..72])) return false;
        @memcpy(self.snapshots[index][0..payload.len], payload);
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

fn snapshotName(identity: StreamIdentity) !FileName {
    var result: FileName = .{};
    result.len = (try std.fmt.bufPrint(&result.bytes, "snapshot-{d}-{d}.bin", .{ @intFromEnum(identity.domain), identity.id })).len;
    return result;
}

fn rebuildJournal(stream: *Stream, bytes: []const u8) !void {
    var reader = try journal.Reader.init(bytes);
    stream.journal = journal.Journal.initAt(reader.next_sequence);
    while (true) switch (try reader.next()) {
        .record => |record| try stream.journal.append(record),
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
        if ((try file.readStreaming(io, &.{&extra})) != 0) return error.FileTooLarge;
    }
    return offset;
}

fn writeFile(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8, sync: bool) !void {
    var file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    if (sync) try file.sync(io);
}

fn writeAtomicFile(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8, sync: bool) !void {
    var temporary_buffer: [112]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&temporary_buffer, "{s}.tmp", .{name});
    try writeFile(dir, io, temporary, bytes, sync);
    try dir.rename(temporary, dir, name, io);
    if (sync) try syncDirectory(dir);
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
        .INVAL, .BADF, .OPNOTSUPP => std.posix.sync(),
        else => return error.DirectorySyncFailed,
    };
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

test "memory and file stores preserve sealed barrier and reject unsafe recovery" {
    var memory = MemoryAdapter.init();
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
        var adapter = MemoryAdapter.init();
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
    var memory = MemoryAdapter.init();
    const store = memory.interface();
    const stream: StreamIdentity = .{ .domain = .decision_log, .id = 44 };
    const payload = [_]u8{1};
    try store.append(undefined, .{ .stream = stream, .record = .{ .type_id = 1, .schema_version = production_contract.journal_schema_version, .flags = 0, .sequence = 1, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = &payload } });
    try store.commit(undefined, stream, 1);
    try store.seal(undefined, stream);
    try std.testing.expectError(error.SnapshotRequiredBeforeRotation, store.rotate(undefined, stream));
    try std.testing.expectEqual(GateState.closed, store.safetyGate());
}
