//! Durable decision owner for the formal Linux engine role.
const std = @import("std");
const durable = @import("../persistence/durable_store.zig");
const journal = @import("../persistence/journal.zig");
const codec = @import("../persistence/canonical_event_codec.zig");
const trading = @import("../trading/trading_shard.zig");
const Owner = @import("demo/demo_authority.zig").Owner;

pub const max_input_bytes = codec.max_encoded_len - 1;
pub const max_record_bytes = journal.max_payload_size;

pub const RecoverySource = struct {
    venue: u64,
    raw_stream: u64,
    session: u64,

    pub fn valid(self: RecoverySource) bool {
        return self.venue != 0 and self.raw_stream != 0 and self.session != 0;
    }
};

const max_recovery_sources = 32;

const Config = struct {
    decision_stream: u64,
    deployment_digest: []const u8,
    recovery_sources: []const RecoverySource = &.{},
};

pub const Engine = struct {
    owner: *Owner,
    file_store: *durable.LinuxFileAdapter,
    sources: [max_recovery_sources]RecoverySource = undefined,
    source_count: usize = 0,
    recovered_sources: u32 = 0,

    pub fn open(init: std.process.Init, dir: std.Io.Dir, state_path: []const u8) !Engine {
        var config_buffer: [4097]u8 = undefined;
        const bytes = try dir.readFile(init.io, "engine.json", &config_buffer);
        if (bytes.len == config_buffer.len) return error.InvalidEngineConfiguration;
        const parsed = try std.json.parseFromSlice(Config, init.gpa, bytes, .{});
        defer parsed.deinit();
        const config = parsed.value;
        if (config.decision_stream == 0 or config.deployment_digest.len != 64)
            return error.InvalidEngineConfiguration;
        var digest: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&digest, config.deployment_digest);

        const file_store = try init.gpa.create(durable.LinuxFileAdapter);
        errdefer init.gpa.destroy(file_store);
        file_store.* = .{ .dir = undefined };
        try file_store.initLinux(init.io, state_path);
        errdefer file_store.close(init.io);
        const owner = try init.gpa.create(Owner);
        errdefer init.gpa.destroy(owner);
        try recover(owner, file_store.interface(), init.io, config.decision_stream, digest);
        try revokeHosts(owner);
        var engine: Engine = .{ .owner = owner, .file_store = file_store };
        for (config.recovery_sources) |source| {
            if (!source.valid() or engine.source_count == engine.sources.len) return error.InvalidEngineConfiguration;
            for (engine.sources[0..engine.source_count]) |previous|
                if (previous.raw_stream == source.raw_stream or previous.session == source.session)
                    return error.InvalidEngineConfiguration;
            engine.sources[engine.source_count] = source;
            engine.source_count += 1;
        }
        return engine;
    }

    pub fn sourceIndex(self: *const Engine, source: RecoverySource) ?u5 {
        for (self.sources[0..self.source_count], 0..) |expected, index|
            if (std.meta.eql(source, expected)) return @intCast(index);
        return null;
    }

    pub fn finishSource(self: *Engine, index: u5, sweep: RecoverySweep) !void {
        if (sweep.last_event == 0 or sweep.last_raw > sweep.raw_barrier or sweep.raw_barrier == 0)
            return error.IncompleteVenueRecovery;
        // A regressed or incomplete replay must not exclude an already committed event.
        const shard = try self.owner.source();
        for (shard.canonical_ingress_cursors[0..shard.canonical_ingress_cursor_count]) |cursor| {
            if (cursor.identity.stream == sweep.source.session and cursor.identity.sequence > sweep.last_event)
                return error.IncompleteVenueRecovery;
        }
        const recovered_sources = self.recovered_sources | (@as(u32, 1) << index);
        if (@popCount(recovered_sources) == self.source_count) {
            if (self.owner.checkpoint_pending) return error.IncompleteVenueRecovery;
            try self.owner.completeIngressRecovery();
        }
        self.recovered_sources = recovered_sources;
    }

    pub fn close(self: Engine, init: std.process.Init) void {
        init.gpa.destroy(self.owner);
        self.file_store.close(init.io);
        init.gpa.destroy(self.file_store);
    }
};

pub fn recover(owner: *Owner, store: durable.Store, io: std.Io, decision_stream: u64, digest: [32]u8) !void {
    try Owner.recoverInto(owner, store, io, .{ .domain = .decision_log, .id = decision_stream });
    errdefer owner.closed = true;
    const shard = try owner.source();
    if (!shard.deployment.sealed or shard.decision_domain_identity == 0) return error.DeploymentConfigurationRequired;
    try owner.pinDeploymentDigest(digest);
    if (owner.checkpoint_pending) try owner.checkpoint();
}

pub const RecoverySweep = struct {
    source: RecoverySource,
    raw_barrier: u64,
    last_raw: u64 = 0,
    last_event: u64 = 0,

    committed: std.AutoHashMapUnmanaged(u64, [32]u8) = .empty,

    pub fn deinit(self: *RecoverySweep, allocator: std.mem.Allocator) void {
        self.committed.deinit(allocator);
    }

    pub fn loadCommitted(self: *RecoverySweep, owner: *const Owner, allocator: std.mem.Allocator) !void {
        const shard = try owner.source();
        for (shard.canonical_ingress_cursors[0..shard.canonical_ingress_cursor_count]) |cursor| {
            if (cursor.identity.stream == self.source.session) break;
        } else return;

        const Index = struct {
            sweep: *RecoverySweep,
            allocator: std.mem.Allocator,

            fn segment(ptr: *anyopaque, bytes: []const u8) !void {
                const index: *@This() = @ptrCast(@alignCast(ptr));
                var reader = try journal.Reader.init(bytes);
                while (true) switch (try reader.next()) {
                    .end => return,
                    .record => |record| {
                        if (record.flags & journal.input_flag == 0) continue;
                        const input = try trading.decodeStableInput(record);
                        if (input != .venue or input.venue.envelope.identity.stream != index.sweep.source.session) continue;
                        var buffer: [codec.max_encoded_len]u8 = undefined;
                        const hash = frameDigest(try codec.encode(&buffer, input.venue));
                        const entry = try index.sweep.committed.getOrPut(index.allocator, input.venue.envelope.identity.sequence);
                        if (entry.found_existing and !std.mem.eql(u8, entry.value_ptr, &hash))
                            return error.ConflictingCanonicalIdentity;
                        entry.value_ptr.* = hash;
                    },
                };
            }
        };
        var index: Index = .{ .sweep = self, .allocator = allocator };
        try owner.store.replaySegments(owner.io, owner.stream, .{ .ptr = &index, .consume_fn = Index.segment });
    }

    pub fn apply(self: *RecoverySweep, owner: *Owner, frame: []const u8) !void {
        const event = try codec.decode(frame);
        const envelope = event.envelope;
        const raw = envelope.raw_evidence;
        if (envelope.venue != self.source.venue or envelope.identity.stream != self.source.session or
            envelope.adapter_session != self.source.session or raw.stream != self.source.raw_stream or
            raw.sequence == 0 or raw.sequence < self.last_raw or raw.sequence > self.raw_barrier or
            std.mem.allEqual(u8, &raw.digest, 0) or
            envelope.identity.sequence != try std.math.add(u64, self.last_event, 1))
            return error.InvalidVenueRecoveryFrame;
        if (self.committed.get(envelope.identity.sequence)) |hash| {
            if (!std.mem.eql(u8, &hash, &frameDigest(frame))) return error.ConflictingCanonicalIdentity;
        } else _ = try owner.apply(.{ .venue = event });
        self.last_raw = raw.sequence;
        self.last_event = envelope.identity.sequence;
    }
};

fn frameDigest(frame: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(frame, &digest, .{});
    return digest;
}

/// The upstream role retains the input in its durable capture until this
/// operation returns a committed decision barrier.
pub fn ingest(owner: *Owner, frame: []const u8) !u64 {
    if (frame.len == 0 or frame.len > max_input_bytes) return error.InvalidCanonicalFrame;
    const event = try codec.decode(frame);
    _ = try owner.apply(.{ .venue = event });
    return (try owner.source()).authoritativeBarrier();
}

pub fn revokeHosts(owner: *Owner) !void {
    const shard = try owner.source();
    var cursor: usize = 0;
    while (cursor <= shard.portfolio_authority_count) : (cursor += 1) {
        const authority = if (cursor == 0)
            shard.strategyAuthority(shard.strategy_identity)
        else
            shard.portfolio_authorities[cursor - 1];
        if (authority.host_activation_identity == 0) continue;
        _ = try owner.apply(.{ .core = .{
            .identity = try std.math.add(u64, shard.authoritativeBarrier(), 1),
            .payload = .{ .host_activation_revoked = .{
                .strategy_identity = authority.strategy_identity,
                .activation_identity = authority.host_activation_identity,
                .reason = .control,
            } },
        } });
    }
}

pub const max_authority_bytes = 256 * 1024;

pub fn readPairTradingList(owner: *const Owner, gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const Request = struct {
        operation: enum { pair_trading_list },
        strategy_identity: []const u8,
        scope_accounts: []const []const u8,
    };
    const shard = try owner.source();
    const parsed = try std.json.parseFromSlice(Request, gpa, bytes, .{});
    defer parsed.deinit();
    if (parsed.value.strategy_identity.len != 32) return error.StrategyIdentityMismatch;
    const identity = try std.fmt.parseInt(u128, parsed.value.strategy_identity, 16);
    if (identity == 0 or !shard.strategyAuthority(identity).strategy_active) return error.StrategyIdentityMismatch;
    return @import("../strategy/strategy_package_authority.zig").pairTradingList(gpa, shard, identity, parsed.value.scope_accounts);
}

pub const CommittedRecord = struct {
    cursor: u64,
    record: ?journal.Record = null,
};

/// Preserve the full decision sequence, including cold proof and derived facts.
pub fn nextCommittedRecord(owner: *const Owner, after: u64, buffer: []u8) !CommittedRecord {
    const barrier = (try owner.source()).authoritativeBarrier();
    if (after > barrier) return error.CursorAheadOfCommit;
    if (after == barrier) return .{ .cursor = barrier };
    const Search = struct {
        after: u64,
        through: u64,
        buffer: []u8,
        result: ?journal.Record = null,

        fn segment(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            var reader = try journal.Reader.init(bytes);
            while (true) switch (try reader.next()) {
                .end => return,
                .record => |record| {
                    if (record.sequence <= self.after) continue;
                    if (record.sequence > self.through or record.sequence != self.after + 1)
                        return error.CommittedSequenceGap;
                    if (record.payload.len > self.buffer.len) return error.CommittedRecordBufferTooSmall;
                    const payload = self.buffer[0..record.payload.len];
                    @memcpy(payload, record.payload);
                    self.result = record;
                    self.result.?.payload = payload;
                    return error.CommittedRecordFound;
                },
            };
        }
    };
    var search: Search = .{ .after = after, .through = barrier, .buffer = buffer };
    owner.store.replaySegmentsAfter(owner.io, owner.stream, after, std.math.maxInt(usize), .{
        .ptr = &search,
        .consume_fn = Search.segment,
    }) catch |err| switch (err) {
        error.CommittedRecordFound => return .{ .cursor = search.result.?.sequence, .record = search.result.? },
        else => return err,
    };
    return error.CommittedSequenceGap;
}
