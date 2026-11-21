//! Durable decision owner for the formal Linux engine role.
const std = @import("std");
const durable = @import("../persistence/durable_store.zig");
const journal = @import("../persistence/journal.zig");
const codec = @import("../persistence/canonical_event_codec.zig");
const trading = @import("../trading/trading_shard.zig");
const Owner = @import("demo/demo_authority.zig").Owner;

pub const max_input_bytes = codec.max_encoded_len - 1;
pub const max_record_bytes = journal.max_payload_size;

const Config = struct {
    decision_stream: u64,
    deployment_digest: []const u8,
};

pub const Engine = struct {
    owner: *Owner,
    file_store: *durable.LinuxFileAdapter,

    pub fn open(init: std.process.Init, dir: std.Io.Dir, state_path: []const u8) !Engine {
        var config_buffer: [1025]u8 = undefined;
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
        return .{ .owner = owner, .file_store = file_store };
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
