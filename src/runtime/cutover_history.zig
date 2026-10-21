const std = @import("std");
const durable = @import("../persistence/durable_store.zig");
const recovery = @import("recovery_cutover.zig");
const history = @import("../persistence/business_history.zig");
const codec = @import("../persistence/snapshot_codec.zig");
const journal = @import("../persistence/journal.zig");
const contract = @import("production_contract.zig");
const empty_test_store: durable.MemoryAdapter = .{};

fn initializeTestStore(adapter: *durable.MemoryAdapter) void {
    @memcpy(std.mem.asBytes(adapter), std.mem.asBytes(&empty_test_store));
    adapter.allocator = std.testing.allocator;
}

const State = struct {
    version: u16 = 1,
    origin: history.Origin,
    sequence: u64 = 0,
    previous_digest: history.Digest = @splat(0),
    archived_generation: u64 = 0,
    root: ?history.Root = null,
    cutover: recovery.Cutover = .{},
};

/// Single writer for a configured existing control stream. Core activations are
/// already committed before ingestion here; this owner never grants trading or
/// performs Core I/O. A failed write closes the owner until recovered read-only.
pub const Owner = struct {
    store: durable.Store,
    origin: history.Origin,
    state: recovery.Cutover = .{},
    committed: State,
    digest: history.Digest = @splat(0),
    closed: bool = false,

    pub fn init(store: durable.Store, origin: history.Origin) !Owner {
        if (origin.stream.domain != .control or origin.stream.id == 0 or origin.account == 0)
            return error.InvalidCutoverOrigin;
        return .{ .store = store, .origin = origin, .committed = .{ .origin = origin } };
    }

    /// Saves an incomplete prepare/quiesce/drain transition without erasing it
    /// when activation details are subsequently archived.
    pub fn saveProgress(self: *Owner, io: std.Io, state: recovery.Cutover) !void {
        if (state.generation != self.state.generation or state.active_release != self.state.active_release or
            state.active_strategy_instance != self.state.active_strategy_instance or
            state.active_state_schema_version != self.state.active_state_schema_version or
            state.active_barrier != self.state.active_barrier or state.activation_count != self.state.activation_count or
            !std.meta.eql(state.activations, self.state.activations)) return error.InvalidActivationHistory;
        var next = self.committed;
        next.cutover = state;
        try self.commitState(io, next);
    }

    /// Ingests a committed activation fact. History absence can never make an old
    /// generation current, and a same cold identity never replays its effects.
    pub fn recordActivation(self: *Owner, io: std.Io, event: recovery.VersionActivationEvent) !void {
        if (self.closed) return error.CutoverHistoryClosed;
        for (self.state.activations[0..self.state.activation_count]) |known| {
            if (known.activation_identity != event.activation_identity) continue;
            if (!std.meta.eql(known, event)) return error.ActivationIdentityConflict;
            return;
        }
        if (self.committed.root) |root| {
            var bytes: [1024]u8 = undefined;
            const event_bytes = try codec.encodeBare(&bytes, event);
            const request: history.LookupRequest = .{
                .pending_id = event.activation_identity,
                .key = .{ .origin = self.origin, .identity = .{ .version_activation = event.activation_identity } },
                .candidate_payload_digest = history.hash(event_bytes),
                .original_input_digest = history.hash(event_bytes),
                .root_digest = root.root_digest,
                .epoch = root.epoch,
                .barrier = root.barrier,
            };
            const result = self.store.queryOrderHistory(io, request) catch |err| {
                self.closed = true;
                return err;
            };
            switch (try history.verifyResult(request, &result.proof, root)) {
                .same => {
                    try history.validateRecord(&result);
                    return;
                },
                .conflict => return error.ActivationIdentityConflict,
                .expired => return error.ActivationHistoryUnavailable,
                .proven_first => {},
            }
        }
        var next = self.committed;
        _ = try next.cutover.replayActivation(event);
        try self.commitState(io, next);
    }

    /// Store publishes immutable authenticated records first. Only a durable
    /// full-state control commit releases the resident details, with all current
    /// authority and any incomplete cutover left intact.
    pub fn archive(self: *Owner, io: std.Io) !void {
        if (self.closed) return error.CutoverHistoryClosed;
        const count = self.state.activation_count;
        if (count == 0) return;
        var buffers: [8][1024]u8 = undefined;
        var records: [8]history.Record = undefined;
        var entries: [8]history.Entry = undefined;
        for (self.state.activations[0..count], 0..) |event, index| {
            const bytes = try codec.encodeBare(&buffers[index], event);
            records[index] = .{ .bytes = bytes, .payload_digest = history.hash(bytes) };
            entries[index] = .{ .key = .{ .origin = self.origin, .identity = .{ .version_activation = event.activation_identity } }, .record_index = @intCast(index) };
        }
        var encoded: [8192]u8 = undefined;
        const qualification = history.hash(try codec.encodeBare(&encoded, self.committed));
        const receipt = self.store.publishOrderHistory(io, .{
            .origin = self.origin,
            .previous_root = self.committed.root,
            .barrier = self.state.active_barrier,
            .epoch = if (self.committed.root) |root| try std.math.add(u64, root.epoch, 1) else 1,
            .qualification_digest = qualification,
            .records = records[0..count],
            .entries = entries[0..count],
        }) catch |err| {
            self.closed = true;
            return err;
        };
        const root = try history.verifyReceipt(receipt, self.origin, qualification, self.committed.root);
        var next = self.committed;
        next.root = root;
        next.archived_generation = self.state.generation;
        next.cutover.activation_count = 0;
        next.cutover.activations = @splat(std.mem.zeroes(recovery.VersionActivationEvent));
        try self.commitState(io, next);
    }

    fn commitState(self: *Owner, io: std.Io, value: State) !void {
        if (self.closed) return error.CutoverHistoryClosed;
        errdefer self.closed = true;
        var next = value;
        next.sequence = try std.math.add(u64, self.committed.sequence, 1);
        next.previous_digest = self.digest;
        try validate(next, self.origin);
        var bytes: [8192]u8 = undefined;
        const encoded = try codec.encodeBare(&bytes, next);
        try self.store.append(io, .{ .stream = self.origin.stream, .record = .{
            .type_id = 0x7808,
            .schema_version = contract.journal_schema_version,
            .flags = journal.input_flag,
            .sequence = next.sequence,
            .source_time = 0,
            .receive_time = 0,
            .monotonic_time = 0,
            .wall_time = 0,
            .time_presence = .{},
            .payload = encoded,
        } });
        try self.store.commit(io, self.origin.stream, next.sequence);
        self.committed = next;
        self.state = next.cutover;
        self.digest = history.hash(encoded);
    }

    pub fn checkpoint(self: *Owner, io: std.Io) !void {
        if (self.closed or self.committed.sequence == 0) return error.CutoverHistoryClosed;
        errdefer self.closed = true;
        var bytes: [8192]u8 = undefined;
        const encoded = try codec.encodeBare(&bytes, self.committed);
        try self.store.seal(io, self.origin.stream);
        try self.store.publishSnapshot(io, self.origin.stream, self.committed.sequence, encoded);
        try self.store.rotate(io, self.origin.stream);
    }

    pub fn recover(store: durable.Store, io: std.Io, origin: history.Origin) !Owner {
        var owner = try init(store, origin);
        const restored = try store.recover(io, origin.stream);
        if (restored.snapshot.len != 0) {
            owner.committed = try codec.decodeBare(restored.snapshot, State);
            try validate(owner.committed, origin);
            if (owner.committed.sequence != restored.snapshot_barrier) return error.InvalidCutoverCheckpoint;
            owner.digest = history.hash(restored.snapshot);
        }
        for (restored.tail_segments[0..restored.tail_count]) |segment| {
            var reader = try journal.Reader.init(segment);
            while (true) switch (try reader.next()) {
                .end => break,
                .record => |record| {
                    if (record.sequence <= owner.committed.sequence) continue;
                    if (record.sequence > restored.committed_barrier) break;
                    if (record.type_id != 0x7808 or record.schema_version != contract.journal_schema_version or
                        record.sequence != try std.math.add(u64, owner.committed.sequence, 1)) return error.InvalidCutoverCheckpoint;
                    const next = try codec.decodeBare(record.payload, State);
                    try validate(next, origin);
                    if (next.sequence != record.sequence or !std.mem.eql(u8, &next.previous_digest, &owner.digest) or
                        next.cutover.generation < owner.committed.cutover.generation or
                        next.archived_generation < owner.committed.archived_generation) return error.InvalidCutoverCheckpoint;
                    owner.committed = next;
                    owner.digest = history.hash(record.payload);
                },
            };
        }
        if (owner.committed.sequence != restored.committed_barrier) return error.InvalidCutoverCheckpoint;
        owner.state = owner.committed.cutover;
        owner.closed = restored.last_sequence != restored.committed_barrier or restored.gate == .closed;
        // Never adopt a merely published history root as committed authority.
        if (!owner.closed) {
            if (store.recoverOrderHistory(io, origin)) |current| {
                if (owner.committed.root) |root| {
                    if (!std.mem.eql(u8, &current.root.root_digest, &root.root_digest)) owner.closed = true;
                } else owner.closed = true;
            } else |err| {
                if (owner.committed.root != null or err != error.OrderHistoryUnavailable) owner.closed = true;
            }
        }
        return owner;
    }
};

fn validate(state: State, origin: history.Origin) !void {
    const cutover = state.cutover;
    if (state.version != 1 or !std.meta.eql(state.origin, origin) or cutover.activation_count > 8 or
        cutover.generation != try std.math.add(u64, state.archived_generation, cutover.activation_count)) return error.InvalidCutoverCheckpoint;
    if (state.root) |root| {
        try history.validateRoot(root);
        if (!std.meta.eql(root.origin, origin) or root.barrier > cutover.active_barrier or state.archived_generation == 0)
            return error.InvalidCutoverCheckpoint;
    } else if (state.archived_generation != 0) return error.InvalidCutoverCheckpoint;
    if (cutover.activation_count != 0) {
        const last = cutover.activations[cutover.activation_count - 1];
        if (last.generation != cutover.generation or last.new_release != cutover.active_release or
            last.new_strategy_instance != cutover.active_strategy_instance or last.state_schema_version != cutover.active_state_schema_version or
            last.barrier != cutover.active_barrier) return error.InvalidCutoverCheckpoint;
    }
}

test "cutover history persists ten reclaimed windows without restoring old authority" {
    const adapter = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(adapter);
    initializeTestStore(adapter);
    defer adapter.deinit();
    const origin: history.Origin = .{ .stream = .{ .domain = .control, .id = 828 }, .account = 9 };
    var owner = try Owner.init(adapter.interface(), origin);
    for (0..10) |round| {
        for (0..8) |_| {
            const generation = owner.state.generation + 1;
            try owner.recordActivation(undefined, .{
                .activation_identity = generation,
                .generation = generation,
                .old_release = owner.state.active_release,
                .new_release = generation + 100,
                .old_strategy_instance = owner.state.active_strategy_instance,
                .new_strategy_instance = generation + 200,
                .strategy_definition = 3,
                .parameter_version = generation,
                .state_schema_version = 7,
                .transition = .migrate,
                .barrier = generation * 3,
                .canonical_state_digest = history.hash("committed core barrier"),
            });
        }
        try owner.archive(undefined);
        try std.testing.expectEqual(@as(u8, 0), owner.state.activation_count);
        try owner.checkpoint(undefined);
        owner = try Owner.recover(adapter.interface(), undefined, origin);
        try std.testing.expectEqual(@as(u64, (round + 1) * 8), owner.state.generation);
        try std.testing.expectEqual(@as(u32, 7), owner.state.active_state_schema_version);
    }
    try std.testing.expectEqual(@as(u64, 80), owner.state.generation);
    const old = testActivation(1, 0, 0);
    try owner.recordActivation(undefined, old);
    try std.testing.expectEqual(@as(u64, 80), owner.state.generation);
    var conflict = old;
    conflict.new_release += 1;
    try std.testing.expectError(error.ActivationIdentityConflict, owner.recordActivation(undefined, conflict));
}

fn testActivation(generation: u64, release: u64, instance: u128) recovery.VersionActivationEvent {
    return .{
        .activation_identity = generation,
        .generation = generation,
        .old_release = release,
        .new_release = generation + 100,
        .old_strategy_instance = instance,
        .new_strategy_instance = generation + 200,
        .strategy_definition = 3,
        .parameter_version = generation,
        .state_schema_version = 7,
        .transition = .migrate,
        .barrier = generation * 3,
        .canonical_state_digest = history.hash("committed core barrier"),
    };
}

test "cutover history keeps unfinished transition and schema after releasing details" {
    const adapter = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(adapter);
    initializeTestStore(adapter);
    defer adapter.deinit();
    const origin: history.Origin = .{ .stream = .{ .domain = .control, .id = 829 }, .account = 9 };
    var owner = try Owner.init(adapter.interface(), origin);
    try owner.recordActivation(undefined, testActivation(1, 0, 0));
    var pending = owner.state;
    try pending.prepare(.{
        .release = 200,
        .strategy_instance = 300,
        .strategy_definition = 3,
        .parameter_version = 2,
        .state_schema_version = 7,
        .transition = .keep,
        .structure_valid = true,
        .economic_digest_valid = true,
        .strategy_invariants_valid = true,
    });
    try owner.saveProgress(undefined, pending);
    try owner.archive(undefined);
    try owner.checkpoint(undefined);
    owner = try Owner.recover(adapter.interface(), undefined, origin);
    try std.testing.expectEqual(recovery.CutoverPhase.candidate, owner.state.phase);
    try std.testing.expectEqual(@as(u64, 200), owner.state.candidate.release);
    try std.testing.expectEqual(@as(u64, 1), owner.state.generation);
    try std.testing.expectEqual(@as(u32, 7), owner.state.active_state_schema_version);
    try owner.state.failBeforeActivation();
    var incompatible = pending.candidate;
    incompatible.state_schema_version = 8;
    try std.testing.expectError(error.IncompatibleKeepSchema, owner.state.prepare(incompatible));
    var stale = testActivation(1, 0, 0);
    stale.activation_identity = 900;
    try std.testing.expectError(error.InvalidActivationHistory, owner.recordActivation(undefined, stale));
    var foreign = origin;
    foreign.account += 1;
    try std.testing.expectError(error.InvalidCutoverCheckpoint, Owner.recover(adapter.interface(), undefined, foreign));
}

test "cutover history publication and commit faults retain committed authority and details" {
    for ([_]durable.FaultPoint{ .archive_sync, .root_publish, .append, .commit }) |point| {
        const adapter = try std.testing.allocator.create(durable.MemoryAdapter);
        defer std.testing.allocator.destroy(adapter);
        initializeTestStore(adapter);
        defer adapter.deinit();
        const origin: history.Origin = .{ .stream = .{ .domain = .control, .id = 830 }, .account = 9 };
        var owner = try Owner.init(adapter.interface(), origin);
        try owner.recordActivation(undefined, testActivation(1, 0, 0));
        try owner.checkpoint(undefined);
        adapter.injectFaultAt(.sync_timeout, point);
        try std.testing.expectError(error.SyncTimeout, owner.archive(undefined));
        try std.testing.expect(owner.closed);
        try std.testing.expectEqual(@as(u8, 1), owner.state.activation_count);
        try std.testing.expectEqual(@as(u64, 1), owner.state.generation);
        const restored = try Owner.recover(adapter.interface(), undefined, origin);
        try std.testing.expect(restored.closed);
        try std.testing.expectEqual(@as(u8, 1), restored.state.activation_count);
        try std.testing.expectEqual(@as(u64, 101), restored.state.active_release);
        try std.testing.expectEqual(@as(u64, 1), restored.state.generation);
    }
}

test "cutover history checkpoint faults preserve latest committed generation" {
    for ([_]durable.FaultPoint{ .seal, .publish, .rotate, .reclaim }) |point| {
        const adapter = try std.testing.allocator.create(durable.MemoryAdapter);
        defer std.testing.allocator.destroy(adapter);
        initializeTestStore(adapter);
        defer adapter.deinit();
        const origin: history.Origin = .{ .stream = .{ .domain = .control, .id = 831 }, .account = 9 };
        var owner = try Owner.init(adapter.interface(), origin);
        try owner.recordActivation(undefined, testActivation(1, 0, 0));
        try owner.archive(undefined);
        adapter.injectFaultAt(.sync_timeout, point);
        try std.testing.expectError(error.SyncTimeout, owner.checkpoint(undefined));
        const restored = try Owner.recover(adapter.interface(), undefined, origin);
        try std.testing.expect(restored.closed);
        try std.testing.expectEqual(@as(u64, 1), restored.state.generation);
        try std.testing.expectEqual(@as(u64, 101), restored.state.active_release);
    }
}
