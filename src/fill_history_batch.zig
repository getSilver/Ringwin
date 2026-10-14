//! Pure single-Fill archive preparation; returned views borrow the stationary Builder.
const std = @import("std");
const economics = @import("economics.zig");
const history = @import("business_history.zig");
const codec = @import("snapshot_codec.zig");

pub const Builder = struct {
    qualification: economics.FillArchiveQualification,
    bytes: [2 * history.max_record_bytes]u8 = undefined,
    detail_len: u32 = 0,
    semantic_len: u32 = 0,
    semantic_identity: ?history.Identity = null,

    pub fn addSemantic(self: *Builder, identity: history.Identity, value: anytype) !void {
        var bytes: [history.max_record_bytes]u8 = undefined;
        try self.addSemanticBytes(identity, try codec.encodeBare(&bytes, value));
    }

    pub fn addSemanticBytes(self: *Builder, identity: history.Identity, encoded: []const u8) !void {
        const fill_id = self.qualification.record.applied.fill.identity;
        switch (identity) {
            .canonical_fill => |id| if (id != fill_id or self.qualification.record.applied.source.canonical_fill == null) return error.InvalidFillHistoryIdentity,
            .core_fill => |id| if (id != fill_id or self.qualification.record.applied.source.canonical_fill != null) return error.InvalidFillHistoryIdentity,
            else => return error.InvalidFillHistoryIdentity,
        }
        if (self.semantic_identity != null or encoded.len == 0 or encoded.len > history.max_record_bytes) return error.InvalidFillHistorySemantic;
        @memcpy(self.bytes[self.detail_len..][0..encoded.len], encoded);
        self.semantic_len = @intCast(encoded.len);
        self.semantic_identity = identity;
    }

    pub fn batch(self: *const Builder, previous_root: ?history.Root, epoch: u64) !BatchView {
        if (epoch == 0 or self.semantic_identity == null) return error.InvalidFillHistorySemantic;
        if (previous_root) |previous| {
            try history.validateRoot(previous);
            if (!std.meta.eql(previous.origin, self.qualification.origin) or previous.retired or
                previous.barrier > self.qualification.barrier or previous.epoch > epoch) return error.StaleHistoryRoot;
        }
        const detail = self.bytes[0..self.detail_len];
        const semantic = self.bytes[self.detail_len..][0..self.semantic_len];
        const economic_digest = &self.qualification.record.applied.payload_digest;
        return .{
            .origin = self.qualification.origin,
            .previous_root = previous_root,
            .barrier = self.qualification.barrier,
            .epoch = epoch,
            .qualification_digest = self.qualification.digest(),
            .records = .{ .{ .bytes = detail, .payload_digest = history.hash(detail) }, .{ .bytes = semantic, .payload_digest = history.hash(semantic) }, .{ .bytes = economic_digest, .payload_digest = history.hash(economic_digest) } },
            .entries = .{
                .{ .key = .{ .origin = self.qualification.origin, .identity = .{ .fill_detail = self.qualification.record.applied.fill.identity } }, .record_index = 0 },
                .{ .key = .{ .origin = self.qualification.origin, .identity = self.semantic_identity.? }, .record_index = 1 },
                .{ .key = .{ .origin = self.qualification.origin, .identity = .{ .fill_economic_digest = self.qualification.record.applied.fill.identity } }, .record_index = 2 },
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

pub fn build(projection: *const economics.Projection, identity: u64, origin: history.Origin, barrier: u64) !Builder {
    var result: Builder = .{ .qualification = try projection.prepareFillArchive(identity, origin, barrier) };
    result.detail_len = @intCast((try codec.encodeBare(result.bytes[0..history.max_record_bytes], result.qualification)).len);
    if (result.qualification.record.applied.source.canonical_fill) |fill| {
        var semantic: [history.max_record_bytes]u8 = undefined;
        const bytes = try @import("canonical_event_codec.zig").encodePayload(&semantic, .{ .fill = fill });
        try result.addSemanticBytes(.{ .canonical_fill = identity }, bytes);
    } else if (result.qualification.record.applied.source.core_payload_len != 0) {
        const source = &result.qualification.record.applied.source;
        try result.addSemanticBytes(.{ .core_fill = identity }, source.core_payload_bytes[0..source.core_payload_len]);
    }
    return result;
}

test "Fill archive validated store receipt preserves unique cumulative and complete economic ledger" {
    const allocator = std.testing.allocator;
    const projection = try allocator.create(economics.Projection);
    defer allocator.destroy(projection);
    projection.* = .{};
    const fill: economics.Fill = .{ .identity = 1, .order_id = 2, .side = .buy, .product = .isolated_linear_usdt, .quantity = .{ .instrument = 1, .rules_version = 1, .lots = 3 }, .price = .{ .instrument = 1, .rules_version = 1, .ticks = 100 }, .price_tick_value = .{ .asset = 1, .atoms = 1 }, .quantity_denominator = 1, .fee = .{ .asset = 1, .atoms = 2 } };
    _ = try projection.applyCanonicalFill(fill, economics.coreFillDigest(fill));
    const before_portfolio = projection.portfolio;
    const before_exchange = projection.exchange;
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 9 }, .account = 7 };
    const builder = try allocator.create(Builder);
    defer allocator.destroy(builder);
    builder.* = try build(projection, 1, origin, 10);
    try std.testing.expectEqual(@as(u8, 4), builder.qualification.record.ledger_count);
    try builder.addSemantic(.{ .core_fill = 1 }, fill);
    const memory = try allocator.create(@import("durable_store.zig").MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = @import("durable_store.zig").MemoryAdapter.initWithAllocator(allocator);
    defer memory.deinit();
    const view = try builder.batch(null, 1);
    const receipt = try memory.interface().publishOrderHistory(undefined, view.value());
    var invalid = receipt;
    invalid.qualification_digest = @splat(0);
    try std.testing.expectError(error.InvalidHistoryReceipt, projection.commitFillArchive(builder.qualification, invalid, null));
    try std.testing.expectEqual(@as(u8, 4), projection.ledger_count);
    try projection.commitFillArchive(builder.qualification, receipt, null);
    try std.testing.expectEqual(@as(i64, 3), try projection.appliedCanonicalFillQuantity(2));
    try std.testing.expectEqual(@as(u8, 0), projection.ledger_count);
    try std.testing.expectEqual(@as(u8, 0), projection.applied_fill_count);
    try std.testing.expectEqual(@as(u64, 1), projection.archived_fill_count);
    try std.testing.expectEqualDeep(before_portfolio, projection.portfolio);
    try std.testing.expectEqualDeep(before_exchange, projection.exchange);
    const request: history.LookupRequest = .{ .pending_id = 1, .key = .{ .origin = origin, .identity = .{ .fill_detail = 1 } }, .candidate_payload_digest = view.records[0].payload_digest, .original_input_digest = history.hash("input"), .root_digest = receipt.root.root_digest, .epoch = 1, .barrier = 10 };
    const result = try memory.interface().queryOrderHistory(undefined, request);
    try history.validateRecord(&result);
    const qualification = try codec.decodeBare(result.record_bytes[0..result.record_len], economics.FillArchiveQualification);
    try std.testing.expectEqualSlices(u8, &builder.qualification.digest(), &qualification.digest());
    try std.testing.expectEqualDeep(fill, qualification.record.applied.fill);
    try std.testing.expectEqual(@as(u8, 4), qualification.record.ledger_count);
    try std.testing.expectEqualDeep(economics.LedgerPosting{ .account = .cash, .unit = .settlement_atoms, .asset = 1, .amount = -2 }, qualification.record.ledger[2].postings[0]);
    try std.testing.expectEqualDeep(economics.LedgerPosting{ .account = .fee_expense, .unit = .settlement_atoms, .asset = 1, .amount = 2 }, qualification.record.ledger[3].postings[1]);
    try projection.assertClosed();
}
