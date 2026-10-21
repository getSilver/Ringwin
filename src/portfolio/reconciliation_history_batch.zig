//! Pure preparation of one completely reconciled account window.
const shard = @import("../trading/trading_shard.zig");
const history = @import("../persistence/business_history.zig");
const codec = @import("../persistence/snapshot_codec.zig");

pub const Builder = struct {
    qualification: shard.ReconciliationWindowArchiveQualification,
    bytes: [2 * history.max_record_bytes]u8 = undefined,
    len: u32 = 0,
    semantic_len: u32 = 0,

    pub fn batch(self: *const Builder, previous_root: ?history.Root, epoch: u64) !BatchView {
        if (epoch == 0) return error.InvalidReconciliationHistoryEpoch;
        const detail = self.bytes[0..self.len];
        const semantic = self.bytes[self.len..][0..self.semantic_len];
        return .{
            .origin = self.qualification.origin,
            .previous_root = previous_root,
            .barrier = self.qualification.barrier,
            .epoch = epoch,
            .qualification_digest = self.qualification.digest(),
            .records = .{ .{ .bytes = detail, .payload_digest = history.hash(detail) }, .{ .bytes = semantic, .payload_digest = history.hash(semantic) } },
            .entries = .{ .{ .key = .{ .origin = self.qualification.origin, .identity = .{ .reconciliation_window = self.qualification.window.identity } }, .record_index = 0 }, .{ .key = .{ .origin = self.qualification.origin, .identity = .{ .canonical_account_reconciliation = self.qualification.window.identity } }, .record_index = 1 } },
        };
    }
};

pub const BatchView = struct {
    origin: history.Origin,
    previous_root: ?history.Root,
    barrier: u64,
    epoch: u64,
    qualification_digest: history.Digest,
    records: [2]history.Record,
    entries: [2]history.Entry,

    pub fn value(self: *const BatchView) history.Batch {
        return .{ .origin = self.origin, .previous_root = self.previous_root, .barrier = self.barrier, .epoch = self.epoch, .qualification_digest = self.qualification_digest, .records = &self.records, .entries = &self.entries };
    }
};

pub fn build(current: *const shard.TradingShard, identity: u128, origin: history.Origin, barrier: u64) !Builder {
    var result: Builder = .{ .qualification = try current.prepareReconciliationWindowArchive(identity, origin, barrier) };
    result.len = @intCast((try codec.encodeBare(result.bytes[0..history.max_record_bytes], result.qualification)).len);
    result.semantic_len = @intCast((try @import("../persistence/canonical_event_codec.zig").encodePayload(result.bytes[result.len..], result.qualification.window.original.event)).len);
    return result;
}
