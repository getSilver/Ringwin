//! Pure preparation after the Owner independently certifies coordinator closure.
//! Returned views borrow a stationary Builder, as the other economic batches do.
const std = @import("std");
const economics = @import("economics.zig");
const history = @import("business_history.zig");
const codec = @import("snapshot_codec.zig");

pub const Builder = struct {
    qualification: economics.ForcedArchiveQualification,
    bytes: [2 * history.max_record_bytes]u8 = undefined,
    detail_len: u32 = 0,
    semantic_len: u32 = 0,

    pub fn batch(self: *const Builder, previous_root: ?history.Root, epoch: u64) !BatchView {
        if (epoch == 0 or self.detail_len == 0 or self.semantic_len == 0) return error.InvalidForcedHistorySemantic;
        if (previous_root) |previous| {
            try history.validateRoot(previous);
            if (!std.meta.eql(previous.origin, self.qualification.origin) or previous.retired or previous.barrier > self.qualification.barrier or previous.epoch > epoch) return error.StaleHistoryRoot;
        }
        const detail = self.bytes[0..self.detail_len];
        const semantic = self.bytes[self.detail_len..][0..self.semantic_len];
        const applied = &self.qualification.record.applied;
        return .{
            .origin = self.qualification.origin,
            .previous_root = previous_root,
            .barrier = self.qualification.barrier,
            .epoch = epoch,
            .qualification_digest = self.qualification.digest(),
            .records = .{ .{ .bytes = detail, .payload_digest = history.hash(detail) }, .{ .bytes = semantic, .payload_digest = history.hash(semantic) }, .{ .bytes = &applied.payload_digest, .payload_digest = history.hash(&applied.payload_digest) } },
            .entries = .{
                .{ .key = .{ .origin = self.qualification.origin, .identity = .{ .forced_detail = applied.forced.identity } }, .record_index = 0 },
                .{ .key = .{ .origin = self.qualification.origin, .identity = .{ .core_forced = applied.forced.identity } }, .record_index = 1 },
                .{ .key = .{ .origin = self.qualification.origin, .identity = .{ .forced_economic_digest = applied.forced.identity } }, .record_index = 2 },
            },
        };
    }
};

pub const BatchView = struct {
    origin: history.Origin,
    previous_root: ?history.Root,
    barrier: u64,
    epoch: u64,
    qualification_digest: history.Digest,
    records: [3]history.Record,
    entries: [3]history.Entry,

    pub fn value(self: *const BatchView) history.Batch {
        return .{ .origin = self.origin, .previous_root = self.previous_root, .barrier = self.barrier, .epoch = self.epoch, .qualification_digest = self.qualification_digest, .records = &self.records, .entries = &self.entries };
    }
};

pub fn build(projection: *const economics.Projection, identity: u64, origin: history.Origin, barrier: u64, closure: economics.ForcedArchiveClosure) !Builder {
    var result: Builder = .{ .qualification = try projection.prepareForcedArchive(identity, origin, barrier, closure) };
    result.detail_len = @intCast((try codec.encodeBare(result.bytes[0..history.max_record_bytes], result.qualification)).len);
    const source = &result.qualification.record.applied.source;
    if (source.core_payload_len == 0) return error.InvalidForcedHistorySemantic;
    @memcpy(result.bytes[result.detail_len..][0..source.core_payload_len], source.core_payload_bytes[0..source.core_payload_len]);
    result.semantic_len = source.core_payload_len;
    return result;
}
