//! Pure single-Funding archive preparation; returned views borrow the stationary Builder.
const std = @import("std");
const economics = @import("economics.zig");
const history = @import("../persistence/business_history.zig");
const codec = @import("../persistence/snapshot_codec.zig");

pub const Builder = struct {
    qualification: economics.FundingArchiveQualification,
    bytes: [2 * history.max_record_bytes]u8 = undefined,
    detail_len: u32 = 0,
    semantic_len: u32 = 0,
    semantic_identity: ?history.Identity = null,

    pub fn addSemantic(self: *Builder, identity: history.Identity, value: anytype) !void {
        var bytes: [history.max_record_bytes]u8 = undefined;
        try self.addSemanticBytes(identity, try codec.encodeBare(&bytes, value));
    }

    pub fn addSemanticBytes(self: *Builder, identity: history.Identity, encoded: []const u8) !void {
        const funding_id = self.qualification.record.applied.funding.identity;
        switch (identity) {
            .canonical_funding => |id| if (id != funding_id or self.qualification.record.applied.source.canonical_funding == null) return error.InvalidFundingHistoryIdentity,
            .core_funding => |id| if (id != funding_id or self.qualification.record.applied.source.canonical_funding != null) return error.InvalidFundingHistoryIdentity,
            else => return error.InvalidFundingHistoryIdentity,
        }
        if (self.semantic_identity != null or encoded.len == 0 or encoded.len > history.max_record_bytes) return error.InvalidFundingHistorySemantic;
        @memcpy(self.bytes[self.detail_len..][0..encoded.len], encoded);
        self.semantic_len = @intCast(encoded.len);
        self.semantic_identity = identity;
    }

    pub fn batch(self: *const Builder, previous_root: ?history.Root, epoch: u64) !BatchView {
        if (epoch == 0 or self.semantic_identity == null) return error.InvalidFundingHistorySemantic;
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
                .{ .key = try history.scopedKey(self.qualification.origin, .{ .funding_detail = self.qualification.record.applied.funding.identity }, self.qualification.record.applied.source.exchange_account), .record_index = 0 },
                .{ .key = try history.scopedKey(self.qualification.origin, self.semantic_identity.?, self.qualification.record.applied.source.exchange_account), .record_index = 1 },
                .{ .key = try history.scopedKey(self.qualification.origin, .{ .funding_economic_digest = self.qualification.record.applied.funding.identity }, self.qualification.record.applied.source.exchange_account), .record_index = 2 },
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
    var result: Builder = .{ .qualification = try projection.prepareFundingArchive(identity, origin, barrier) };
    result.detail_len = @intCast((try codec.encodeBare(result.bytes[0..history.max_record_bytes], result.qualification)).len);
    if (result.qualification.record.applied.source.canonical_funding) |funding| {
        var semantic: [history.max_record_bytes]u8 = undefined;
        const bytes = try @import("../persistence/canonical_event_codec.zig").encodePayload(&semantic, .{ .funding_settlement = funding });
        try result.addSemanticBytes(.{ .canonical_funding = identity }, bytes);
    } else if (result.qualification.record.applied.source.core_payload_len != 0) {
        const source = &result.qualification.record.applied.source;
        try result.addSemanticBytes(.{ .core_funding = identity }, source.core_payload_bytes[0..source.core_payload_len]);
    }
    return result;
}

test "07 funding Store records preserve complete postings zero identity source clocks and cumulative settlement" {
    const allocator = std.testing.allocator;
    const projection = try allocator.create(economics.Projection);
    defer allocator.destroy(projection);
    projection.* = .{};
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .product = .isolated_linear_usdt, .quantity = .{ .instrument = 1, .rules_version = 1, .lots = 3 }, .price = .{ .instrument = 1, .rules_version = 1, .ticks = 100 }, .price_tick_value = .{ .asset = 1, .atoms = 1 }, .quantity_denominator = 1 } });
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 9 }, .account = 7 };
    const memory = try allocator.create(@import("../persistence/durable_store.zig").MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = @import("../persistence/durable_store.zig").MemoryAdapter.initWithAllocator(allocator);
    defer memory.deinit();
    const builder = try allocator.create(Builder);
    defer allocator.destroy(builder);
    var previous_root: ?history.Root = null;
    for ([_]i128{ -5, 0 }, 0..) |amount, index| {
        const identity: u64 = @intCast(index + 2);
        const original: @import("../trading/trading_shard_event.zig").FundingSettlement = .{ .settlement_id = identity, .amount_atoms = amount };
        var source: economics.FundingSource = .{ .exchange_account = 7, .portfolio = 8, .strategy = 9, .instrument = 1, .rules_version = 1, .exchange_time_utc_ns = 100 + identity, .received_time_utc_ns = 200 + identity, .received_monotonic_ns = 300 + identity };
        source.core_event_identity = identity;
        source.core_times = .{ .source = 100 + identity, .receive = 200 + identity, .monotonic = 300 + identity, .wall = 0, .presence = .{ .source = true, .receive = true, .monotonic = true } };
        source.core_payload_len = @intCast((try codec.encodeBare(&source.core_payload_bytes, original)).len);
        const funding: economics.FundingSettlement = .{ .identity = identity, .amount = .{ .asset = 1, .atoms = amount }, .portfolio_ownership_proven = true };
        try std.testing.expect(try projection.applyFundingWithSource(funding, source));
        try std.testing.expect(!try projection.applyFundingWithSource(funding, source));
        const portfolio = projection.portfolio;
        const exchange = projection.exchange;
        builder.* = try build(projection, identity, origin, identity + 10);
        const expected_ledger_count: u8 = if (amount == 0) 0 else 2;
        try std.testing.expectEqual(expected_ledger_count, builder.qualification.record.ledger_count);
        try std.testing.expect(!std.mem.eql(u8, &builder.qualification.record.applied.source_digest, &builder.qualification.record.applied.payload_digest));
        const view = try builder.batch(previous_root, identity);
        const receipt = try memory.interface().publishOrderHistory(undefined, view.value());
        var invalid = receipt;
        invalid.qualification_digest = @splat(0);
        const digest_before = projection.digest();
        try std.testing.expectError(error.InvalidHistoryReceipt, projection.commitFundingArchive(builder.qualification, invalid, previous_root));
        try std.testing.expectEqualSlices(u8, &digest_before, &projection.digest());
        const request: history.LookupRequest = .{ .pending_id = identity, .key = .{ .origin = origin, .identity = .{ .funding_detail = identity } }, .candidate_payload_digest = view.records[0].payload_digest, .original_input_digest = history.hash("input"), .root_digest = receipt.root.root_digest, .epoch = identity, .barrier = identity + 10 };
        const result = try memory.interface().queryOrderHistory(undefined, request);
        try history.validateRecord(&result);
        const qualification = try codec.decodeBare(result.record_bytes[0..result.record_len], economics.FundingArchiveQualification);
        try std.testing.expectEqualSlices(u8, &builder.qualification.digest(), &qualification.digest());
        try std.testing.expectEqualDeep(source, qualification.record.applied.source);
        try std.testing.expectEqualDeep(funding, qualification.record.applied.funding);
        try std.testing.expect(qualification.record.applied.portfolio_applied);
        try std.testing.expectEqual(expected_ledger_count, qualification.record.ledger_count);
        for (qualification.record.ledger[0..qualification.record.ledger_count], 0..) |transaction, layer| {
            try std.testing.expectEqual(@as(economics.LedgerLayer, @enumFromInt(layer)), transaction.layer);
            try std.testing.expectEqualDeep(economics.LedgerPosting{ .account = .cash, .unit = .settlement_atoms, .asset = 1, .amount = amount }, transaction.postings[0]);
            try std.testing.expectEqualDeep(economics.LedgerPosting{ .account = .funding_pnl, .unit = .settlement_atoms, .asset = 1, .amount = -amount }, transaction.postings[1]);
        }
        try projection.commitFundingArchive(builder.qualification, receipt, previous_root);
        try std.testing.expectEqualDeep(portfolio, projection.portfolio);
        try std.testing.expectEqualDeep(exchange, projection.exchange);
        try std.testing.expectEqual(@as(u8, 0), projection.applied_funding_count);
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), projection.archived_funding_count);
        try std.testing.expectEqual(@as(i128, 5), projection.cumulative_funding_absolute_atoms);
        try std.testing.expectEqual(@as(i128, 5), projection.archived_funding_absolute_atoms);
        try projection.assertClosed();
        previous_root = receipt.root;
    }
}

test "07 funding archive pins unknown canonical ownership missing source clocks and changed balanced ledgers" {
    const allocator = std.testing.allocator;
    const projection = try allocator.create(economics.Projection);
    defer allocator.destroy(projection);
    projection.* = .{};
    try projection.apply(.{ .fill = .{ .identity = 1, .side = .buy, .product = .isolated_linear_usdt, .quantity = .{ .instrument = 1, .rules_version = 1, .lots = 3 }, .price = .{ .instrument = 1, .rules_version = 1, .ticks = 100 }, .price_tick_value = .{ .asset = 1, .atoms = 1 }, .quantity_denominator = 1 } });
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 9 }, .account = 7 };
    const original: @import("../trading/trading_shard_event.zig").FundingSettlement = .{ .settlement_id = 2, .amount_atoms = 5 };
    var source: economics.FundingSource = .{ .exchange_account = 7, .portfolio = 8, .strategy = 9, .instrument = 1, .rules_version = 1, .received_time_utc_ns = 202, .received_monotonic_ns = 302 };
    source.core_event_identity = 2;
    source.core_times = .{ .source = 102, .receive = 202, .monotonic = 302, .wall = 0, .presence = .{ .receive = true, .monotonic = true } };
    source.core_payload_len = @intCast((try codec.encodeBare(&source.core_payload_bytes, original)).len);
    const funding: economics.FundingSettlement = .{ .identity = 2, .amount = .{ .asset = 1, .atoms = 5 }, .portfolio_ownership_proven = true };
    _ = try projection.applyFundingWithSource(funding, source);
    try std.testing.expectError(error.FundingArchivePinned, projection.prepareFundingArchive(2, origin, 12));
    source.exchange_time_utc_ns = 102;
    source.core_times.?.presence.source = true;
    try std.testing.expectError(error.ConflictingEconomicIdentity, projection.applyFundingWithSource(funding, source));
    projection.applied_fundings[0].source.exchange_time_utc_ns = 102;
    projection.applied_fundings[0].source.core_times.?.presence.source = true;
    _ = try projection.prepareFundingArchive(2, origin, 12);
    for (projection.ledger[0..projection.ledger_count]) |*transaction| if (transaction.kind == .funding) {
        transaction.postings[0].amount = 6;
        transaction.postings[1].amount = -6;
    };
    try std.testing.expectError(error.InvalidEconomicFact, projection.prepareFundingArchive(2, origin, 12));

    projection.* = .{};
    const canonical_funding: @import("../model/canonical_event.zig").FundingSettlement = .{ .identity = 3, .exchange_account = 7, .instrument = 1, .rules_version = 1, .venue_bill_id = 77, .amount = .{ .asset = 1, .atoms = 0 }, .settlement_time_utc_ns = 103 };
    var canonical_source: economics.FundingSource = .{ .canonical_funding = canonical_funding, .exchange_account = 7, .instrument = 1, .rules_version = 1, .exchange_time_utc_ns = 103, .received_time_utc_ns = 203, .received_monotonic_ns = 303 };
    const canonical_digest = try economics.fundingSourceDigest(.{ .identity = 3, .amount = canonical_funding.amount }, canonical_source);
    _ = try projection.applyFundingWithSource(.{ .identity = 3, .amount = canonical_funding.amount, .canonical_digest = canonical_digest }, canonical_source);
    try std.testing.expectEqual(@as(u8, 1), projection.applied_funding_count);
    try std.testing.expectEqual(@as(u8, 0), projection.ledger_count);
    try std.testing.expect(projection.reconciliation_break);
    try std.testing.expectError(error.FundingArchivePinned, projection.prepareFundingArchive(3, origin, 13));
    canonical_source.portfolio = 8;
    try std.testing.expectError(error.InvalidEconomicFact, projection.applyFundingWithSource(.{ .identity = 3, .amount = canonical_funding.amount, .canonical_digest = canonical_digest, .portfolio_ownership_proven = true }, canonical_source));
}
