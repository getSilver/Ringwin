//! Bounded checkpoint content and committed publication references. Store owns
//! durability; Python never supplies a path, stream identity, or commit proof.
const std = @import("std");
const durable = @import("../persistence/durable_store.zig");
const journal = @import("../persistence/journal.zig");
const production = @import("../runtime/production_contract.zig");
const codec = @import("strategy_host_recovery.zig");

const record_len = 200;
const type_id = 0x4350;

pub const Published = struct {
    sequence: u64,
    content_stream: u64,
    content_barrier: u64,
    metadata: codec.Metadata,
    content_identity: [32]u8,
    state_digest: [32]u8,
};

pub const Repository = struct {
    store: durable.Store,
    catalog: u64,
    content_slots: [2]u64,

    pub fn init(store: durable.Store, catalog: u64, slots: [2]u64) !Repository {
        if (catalog == 0 or slots[0] == 0 or slots[1] == 0 or
            catalog == slots[0] or catalog == slots[1] or slots[0] == slots[1])
            return error.InvalidCheckpointNamespace;
        return .{ .store = store, .catalog = catalog, .content_slots = slots };
    }

    /// Provision a new, exclusively assigned namespace. Never call this to
    /// repair a missing/corrupt existing catalog; append identity conflicts fail.
    pub fn initialize(self: Repository, io: std.Io) !void {
        for ([_]u64{ self.catalog, self.content_slots[0], self.content_slots[1] }) |id| {
            try self.append(io, id, 1, "QSC0");
            try self.store.commit(io, stream(id), 1);
            try self.store.seal(io, stream(id));
            try self.store.publishSnapshot(io, stream(id), 1, "QSC0");
            try self.store.rotate(io, stream(id));
        }
    }

    /// Single-writer API. The owner supplies metadata independently of the
    /// untrusted container; a returned record is durable, not trading authority.
    pub fn publish(self: Repository, io: std.Io, container: []const u8, expected: codec.Metadata) !Published {
        const candidate = try codec.decodePayloadCheckpoint(container, expected);
        const current = try self.latest(io);
        if (current) |old| {
            if (old.metadata.strategy_instance != expected.strategy_instance or
                expected.strategy_cursor < old.metadata.strategy_cursor)
                return error.StaleCheckpointPublication;
            if (expected.strategy_cursor == old.metadata.strategy_cursor) {
                if (!std.mem.eql(u8, &old.content_identity, &candidate.identity))
                    return error.CheckpointPublicationConflict;
                // Check the referenced content as well; a duplicate cannot
                // certify an unavailable object merely from catalog metadata.
                _ = try self.restore(io, expected);
                return old;
            }
        }
        const slot = if (current != null and current.?.content_stream == self.content_slots[0])
            self.content_slots[1]
        else
            self.content_slots[0];
        const object = try self.store.recover(io, stream(slot));
        if (object.status != .ready or object.last_sequence != object.committed_barrier)
            return error.CheckpointStoreUnavailable;
        const publication: Published = .{
            .sequence = if (current) |old| try std.math.add(u64, old.sequence, 1) else 2,
            .content_stream = slot,
            .content_barrier = try std.math.add(u64, object.last_sequence, 1),
            .metadata = candidate.metadata,
            .content_identity = candidate.identity,
            .state_digest = candidate.state_digest,
        };
        var bytes: [record_len]u8 = undefined;
        encode(&bytes, publication);
        try self.append(io, slot, publication.content_barrier, &bytes);
        try self.store.commit(io, stream(slot), publication.content_barrier);
        try self.store.seal(io, stream(slot));
        try self.store.publishSnapshot(io, stream(slot), publication.content_barrier, container);
        try self.store.rotate(io, stream(slot));

        const catalog_state = try self.store.recover(io, stream(self.catalog));
        if (catalog_state.status != .ready or catalog_state.last_sequence != catalog_state.committed_barrier or
            (std.math.add(u64, catalog_state.last_sequence, 1) catch return error.CheckpointStoreUnavailable) != publication.sequence)
            return error.CheckpointStoreUnavailable;
        try self.append(io, self.catalog, publication.sequence, &bytes);
        // This is the publication boundary. Failure after this commit may be
        // uncertain to the caller; latest/restore resolve it without re-emission.
        try self.store.commit(io, stream(self.catalog), publication.sequence);
        try self.store.seal(io, stream(self.catalog));
        try self.store.publishSnapshot(io, stream(self.catalog), publication.sequence, &bytes);
        try self.store.rotate(io, stream(self.catalog));
        return publication;
    }

    /// Copies the fixed reference before further Store I/O invalidates borrows.
    pub fn latest(self: Repository, io: std.Io) !?Published {
        const recovered = try self.store.recover(io, stream(self.catalog));
        if (recovered.status != .ready) return error.CheckpointStoreUnavailable;
        var result: ?Published = null;
        if (recovered.snapshot.len != 0) {
            if (recovered.snapshot_barrier == 1 and std.mem.eql(u8, recovered.snapshot, "QSC0")) {
                // Explicit provisioned genesis is not a published checkpoint.
            } else {
                result = try decode(recovered.snapshot);
                if (result.?.sequence != recovered.snapshot_barrier) return error.InvalidCheckpointPublication;
            }
        }
        if (recovered.tail.len != 0) {
            var reader = try journal.Reader.init(recovered.tail);
            while (true) switch (try reader.next()) {
                .record => |record| {
                    if (record.sequence > recovered.committed_barrier) continue;
                    if (record.type_id != type_id or record.schema_version != production.journal_schema_version)
                        return error.InvalidCheckpointPublication;
                    if (record.sequence == 1 and std.mem.eql(u8, record.payload, "QSC0")) continue;
                    const next = try decode(record.payload);
                    if (next.sequence != record.sequence) return error.InvalidCheckpointPublication;
                    if (result == null or next.sequence > result.?.sequence) result = next;
                },
                .end => |status| {
                    if ((status != .clean and status != .truncated_tail) or reader.offset != recovered.tail.len)
                        return error.InvalidCheckpointPublication;
                    break;
                },
            };
        }
        if (result) |published| {
            if (published.sequence != recovered.committed_barrier or
                (published.content_stream != self.content_slots[0] and published.content_stream != self.content_slots[1]))
                return error.InvalidCheckpointPublication;
        } else if (recovered.committed_barrier != 1) return error.InvalidCheckpointPublication;
        return result;
    }

    /// Content borrows Store storage until its next I/O. Only the current
    /// committed reference is eligible, never a staged slot or a guessed latest.
    pub fn restore(self: Repository, io: std.Io, expected: codec.Metadata) ![]const u8 {
        const published = (try self.latest(io)) orelse return error.NoPublishedCheckpoint;
        const object = try self.store.recover(io, stream(published.content_stream));
        if (object.status != .ready or object.snapshot_barrier != published.content_barrier)
            return error.CheckpointContentUnavailable;
        const checkpoint = try codec.decodePayloadCheckpoint(object.snapshot, expected);
        if (!std.meta.eql(checkpoint.metadata, published.metadata) or
            !std.mem.eql(u8, &checkpoint.identity, &published.content_identity) or
            !std.mem.eql(u8, &checkpoint.state_digest, &published.state_digest))
            return error.CheckpointContentUnavailable;
        return object.snapshot;
    }

    fn append(self: Repository, io: std.Io, id: u64, sequence: u64, payload: []const u8) !void {
        try self.store.append(io, .{ .stream = stream(id), .record = .{
            .type_id = type_id,
            .schema_version = production.journal_schema_version,
            .flags = 0,
            .sequence = sequence,
            .source_time = 0,
            .receive_time = 0,
            .monotonic_time = 0,
            .wall_time = 0,
            .time_presence = .{},
            .payload = payload,
        } });
    }
};

fn stream(id: u64) durable.StreamIdentity {
    return .{ .domain = .control, .id = id };
}

fn encode(bytes: *[record_len]u8, value: Published) void {
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "QSP1");
    put(u16, bytes, 4, 1);
    put(u16, bytes, 6, record_len);
    put(u64, bytes, 8, value.sequence);
    put(u64, bytes, 16, value.content_stream);
    put(u64, bytes, 24, value.content_barrier);
    put(u128, bytes, 32, value.metadata.schema_registry);
    put(u128, bytes, 48, value.metadata.strategy_instance);
    put(u128, bytes, 64, value.metadata.strategy_definition);
    put(u128, bytes, 80, value.metadata.state_schema);
    put(u32, bytes, 96, value.metadata.state_schema_version);
    put(u64, bytes, 104, value.metadata.strategy_config_version);
    put(u64, bytes, 112, value.metadata.strategy_cursor);
    put(u64, bytes, 120, value.metadata.next_intent_sequence);
    @memcpy(bytes[128..160], &value.content_identity);
    @memcpy(bytes[160..192], &value.state_digest);
}

fn decode(bytes: []const u8) !Published {
    if (bytes.len != record_len or !std.mem.eql(u8, bytes[0..4], "QSP1") or
        get(u16, bytes, 4) != 1 or get(u16, bytes, 6) != record_len or
        get(u32, bytes, 100) != 0 or get(u64, bytes, 192) != 0 or
        get(u64, bytes, 8) == 0 or get(u64, bytes, 16) == 0 or
        get(u64, bytes, 24) == 0 or get(u64, bytes, 120) == 0)
        return error.InvalidCheckpointPublication;
    return .{
        .sequence = get(u64, bytes, 8),
        .content_stream = get(u64, bytes, 16),
        .content_barrier = get(u64, bytes, 24),
        .metadata = .{
            .schema_registry = get(u128, bytes, 32),
            .strategy_instance = get(u128, bytes, 48),
            .strategy_definition = get(u128, bytes, 64),
            .state_schema = get(u128, bytes, 80),
            .state_schema_version = get(u32, bytes, 96),
            .strategy_config_version = get(u64, bytes, 104),
            .strategy_cursor = get(u64, bytes, 112),
            .next_intent_sequence = get(u64, bytes, 120),
        },
        .content_identity = bytes[128..160].*,
        .state_digest = bytes[160..192].*,
    };
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

test "checkpoint publication keeps current content through staging failure and deduplicates committed identity" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const repository = try Repository.init(memory.interface(), 700, .{ 701, 702 });
    try repository.initialize(undefined);
    var metadata: codec.Metadata = .{ .schema_registry = 1, .strategy_instance = 2, .strategy_definition = 3, .state_schema = 4, .state_schema_version = 1, .strategy_config_version = 1, .strategy_cursor = 1, .next_intent_sequence = 1 };
    var bytes: [512]u8 = undefined;
    var first: Published = undefined;
    for (1..21) |cursor| {
        metadata.strategy_cursor = cursor;
        const checkpoint = try codec.encodeCheckpoint(&bytes, metadata, .{ .accumulator = @intCast(cursor), .event_count = cursor });
        const published = try repository.publish(undefined, checkpoint, metadata);
        if (cursor == 1) first = published;
        try std.testing.expectEqual(cursor + 1, published.sequence);
        try std.testing.expectEqualDeep(published, try repository.publish(undefined, checkpoint, metadata));
        const restored = try repository.restore(undefined, metadata);
        try std.testing.expectEqualSlices(u8, checkpoint, restored);
    }
    try std.testing.expectEqual(@as(u64, 2), first.sequence);
    metadata.strategy_cursor = 21;
    const checkpoint = try codec.encodeCheckpoint(&bytes, metadata, .{ .accumulator = 21, .event_count = 21 });
    memory.injectFaultAt(.eio, .publish);
    try std.testing.expectError(error.InputOutput, repository.publish(undefined, checkpoint, metadata));
    // No new catalog reference was committed when content publication failed.
    try std.testing.expectEqual(@as(u64, 21), (try repository.latest(undefined)).?.sequence);
}
