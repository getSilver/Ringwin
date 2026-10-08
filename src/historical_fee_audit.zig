//! Read-only checks of exported legacy fee evidence, never a legacy state decoder.
//! A consistent bundle proves its joins, not authenticity of an original store.
const std = @import("std");
const canonical = @import("canonical_event.zig");

pub const max_input_bytes = 64 * 1024;
pub const max_records = 8;
pub const legacy_revision = "9939110dddbaab0e97c8cfb461f9e35a537d12dd";
pub const Input = struct { format: u16, records: []const Record };
pub const Raw = struct { bytes: []const u8, sha256: []const u8, stream: u64, sequence: u64, exchange_account: u64 };
pub const LegacyFill = struct {
    identity: u64,
    order: u64,
    exchange_account: u64,
    instrument: []const u8,
    venue_order: []const u8,
    client_order_id: []const u8,
    venue_trade: []const u8,
    fee_asset: []const u8,
    fee_atoms: []const u8,
    raw_stream: u64,
    raw_sequence: u64,
    raw_sha256: []const u8,
};
pub const Order = struct {
    identity: u64,
    exchange_account: u64,
    portfolio: u64,
    instrument: []const u8,
    venue_order: []const u8,
    client_order_id: []const u8,
};
pub const Posting = struct { account: enum { cash, fee_expense }, unit: enum { settlement_atoms }, amount: []const u8 };
pub const Transaction = struct { source_identity: u64, kind: enum { fill }, layer: enum { portfolio, exchange }, postings: []const Posting };
pub const Coverage = struct { from_utc_ns: u64, through_utc_ns: u64 };
pub const Record = struct {
    source_kind: enum { fixed_fixture, sealed_export },
    source_label: []const u8,
    execution_revision: []const u8,
    journal_schema: u16,
    state_schema: u32,
    schema_registry: u64,
    asset: []const u8,
    original_value: ?[]const u8 = null,
    posted_cash_atoms: ?[]const u8 = null,
    posted_scale: u8,
    comparison_scale: u8,
    // This legacy schema did not record AssetVersion. Never borrow today's one.
    asset_version: ?u64 = null,
    raw: ?Raw = null,
    fill: ?LegacyFill = null,
    order: ?Order = null,
    transactions: []const Transaction = &.{},
    coverage: ?Coverage = null,
};
pub const Reason = enum { missing_raw, unsupported_old_interpretation, missing_join, source_mismatch, amount_source_uncertain, incomplete_range, invalid_amount, overflow, unbalanced_postings };
pub const Result = struct {
    source_kind: @FieldType(Record, "source_kind"),
    source_label: []const u8,
    execution_revision: []const u8,
    journal_schema: u16,
    state_schema: u32,
    schema_registry: u64,
    asset: []const u8,
    asset_version: ?u64,
    precision_source: ?[]const u8 = null,
    legacy_posting_unit: []const u8 = "settlement_atoms",
    posted_scale: u8,
    comparison_scale: u8,
    original_value: ?[]const u8,
    posted_cash_atoms: ?[]const u8,
    source_join: enum { fixed_fixture_consistent, exported_bundle_consistent, unverifiable } = .unverifiable,
    reason: ?Reason = null,
    original_store_integrity: []const u8 = "not_checked",
    source_transaction_identity: ?u64 = null,
    raw_evidence: ?struct { stream: u64, sequence: u64, sha256: []const u8 } = null,
    canonical_fill_identity: ?u64 = null,
    order_identity: ?u64 = null,
    exchange_account: ?u64 = null,
    instrument: ?[]const u8 = null,
    venue_trade: ?[]const u8 = null,
    coverage: ?Coverage = null,
    portfolio: ?u64 = null,
    internal_postings_closed: ?bool = null,
    true_cash_atoms: ?i128 = null,
    posted_cash_comparison_atoms: ?i128 = null,
    // Positive means legacy cash was reduced more than the independent fee.
    cash_difference_atoms: ?i128 = null,
    correction: []const u8 = "separate_authorization_required_for_append_only_reversal_or_correction_referencing_original_transaction",
    online_qualification: []const u8 = "not_run",
    production_qualification: bool = false,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Input) {
    if (bytes.len >= max_input_bytes) return error.HistoricalInputTooLarge;
    var parsed = try std.json.parseFromSlice(Input, allocator, bytes, .{ .max_value_len = 16 * 1024 });
    errdefer parsed.deinit();
    if (parsed.value.format != 1 or parsed.value.records.len == 0 or parsed.value.records.len > max_records) return error.InvalidHistoricalInput;
    for (parsed.value.records) |record| {
        if (record.source_label.len > 256 or record.execution_revision.len > 64 or record.asset.len > 32 or record.transactions.len > 2) return error.InvalidHistoricalInput;
    }
    return parsed;
}

pub fn audit(allocator: std.mem.Allocator, record: Record) Result {
    var result: Result = .{
        .source_kind = record.source_kind,
        .source_label = record.source_label,
        .execution_revision = record.execution_revision,
        .journal_schema = record.journal_schema,
        .state_schema = record.state_schema,
        .schema_registry = record.schema_registry,
        .asset = record.asset,
        .asset_version = record.asset_version,
        .posted_scale = record.posted_scale,
        .comparison_scale = record.comparison_scale,
        .original_value = record.original_value,
        .posted_cash_atoms = record.posted_cash_atoms,
    };
    verify(allocator, record, &result) catch |err| {
        result.reason = switch (err) {
            error.MissingRaw => .missing_raw,
            error.UnsupportedOldInterpretation => .unsupported_old_interpretation,
            error.MissingJoin => .missing_join,
            error.SourceMismatch => .source_mismatch,
            error.AmountSourceUncertain => .amount_source_uncertain,
            error.IncompleteRange => .incomplete_range,
            error.Overflow, error.DecimalOverflow, error.DecimalScalingOverflow => .overflow,
            error.UnbalancedPostings => .unbalanced_postings,
            else => .invalid_amount,
        };
        return result;
    };
    result.source_join = if (record.source_kind == .fixed_fixture) .fixed_fixture_consistent else .exported_bundle_consistent;
    return result;
}

fn field(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.AmountSourceUncertain;
    return if (value == .string) value.string else error.AmountSourceUncertain;
}

fn equal(left: []const u8, right: []const u8) !void {
    if (!std.mem.eql(u8, left, right)) return error.SourceMismatch;
}

fn verify(allocator: std.mem.Allocator, record: Record, result: *Result) !void {
    // Only the explicitly evidenced historical USDT micros interpretation is
    // supported. Other old encodings remain evidence, never migrated state.
    if (!std.mem.eql(u8, record.execution_revision, legacy_revision) or record.journal_schema != 22 or record.state_schema != 25 or
        record.schema_registry != 19 or !std.mem.eql(u8, record.asset, "USDT") or record.posted_scale != 6 or record.asset_version != null)
        return error.UnsupportedOldInterpretation;
    if (record.comparison_scale < record.posted_scale or record.comparison_scale > canonical.Decimal.max_scale) return error.UnsupportedOldInterpretation;
    result.precision_source = "legacy_execution_revision_assetScale";
    const raw = record.raw orelse return error.MissingRaw;
    const fill = record.fill orelse return error.MissingJoin;
    const order = record.order orelse return error.MissingJoin;
    const coverage = record.coverage orelse return error.IncompleteRange;
    const original = record.original_value orelse return error.AmountSourceUncertain;
    const posted = record.posted_cash_atoms orelse return error.MissingJoin;
    if (raw.bytes.len > 16 * 1024 or raw.stream == 0 or raw.sequence == 0 or raw.exchange_account == 0 or
        fill.identity == 0 or order.identity == 0 or order.portfolio == 0 or record.transactions.len != 2) return error.MissingJoin;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw.bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try equal(raw.sha256, &hex);
    try equal(fill.raw_sha256, &hex);
    if (fill.raw_stream != raw.stream or fill.raw_sequence != raw.sequence or fill.order != order.identity or
        fill.exchange_account != order.exchange_account or raw.exchange_account != order.exchange_account) return error.SourceMismatch;
    try equal(fill.instrument, order.instrument);
    try equal(fill.venue_order, order.venue_order);
    try equal(fill.client_order_id, order.client_order_id);
    try equal(fill.fee_asset, record.asset);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw.bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.AmountSourceUncertain;
    const arg = parsed.value.object.get("arg") orelse return error.AmountSourceUncertain;
    if (arg != .object) return error.AmountSourceUncertain;
    try equal(try field(arg.object, "channel"), "orders");
    const data = parsed.value.object.get("data") orelse return error.AmountSourceUncertain;
    if (data != .array or data.array.items.len == 0 or data.array.items.len > 32 or
        fill.instrument.len == 0 or fill.venue_order.len == 0 or fill.client_order_id.len == 0 or fill.venue_trade.len == 0)
        return error.AmountSourceUncertain;
    var selected: ?std.json.ObjectMap = null;
    for (data.array.items) |candidate| {
        if (candidate != .object) continue;
        const object = candidate.object;
        if (!std.mem.eql(u8, field(object, "instId") catch continue, fill.instrument) or
            !std.mem.eql(u8, field(object, "ordId") catch continue, fill.venue_order) or
            !std.mem.eql(u8, field(object, "clOrdId") catch continue, fill.client_order_id) or
            !std.mem.eql(u8, field(object, "tradeId") catch continue, fill.venue_trade)) continue;
        if (selected != null) return error.AmountSourceUncertain;
        selected = object;
    }
    const row = selected orelse return error.SourceMismatch;
    try equal(try field(row, "instId"), fill.instrument);
    try equal(try field(row, "ordId"), fill.venue_order);
    try equal(try field(row, "clOrdId"), fill.client_order_id);
    try equal(try field(row, "tradeId"), fill.venue_trade);
    if (fill.venue_trade.len == 0 or (try canonical.Decimal.parse(try field(row, "fillSz"))).coefficient <= 0) return error.AmountSourceUncertain;
    // Never substitute order-level cumulative fee for a per-execution field.
    try equal(try field(row, "fillFeeCcy"), record.asset);
    const actual = try canonical.Decimal.parse(try field(row, "fillFee"));
    if (!std.meta.eql(actual, try canonical.Decimal.parse(original)) or actual.coefficient >= 0) return error.AmountSourceUncertain;
    const milliseconds = try std.fmt.parseInt(u64, try field(row, "fillTime"), 10);
    const time = try std.math.mul(u64, milliseconds, std.time.ns_per_ms);
    if (coverage.from_utc_ns > coverage.through_utc_ns or time < coverage.from_utc_ns or time > coverage.through_utc_ns) return error.IncompleteRange;
    // Old posting width was i64. Scale belongs to that encoding, independently
    // of the comparison scale used below for this report.
    const old_cash = try std.fmt.parseInt(i64, posted, 10);
    const old_fee = try std.fmt.parseInt(i64, fill.fee_atoms, 10);
    if (old_fee <= 0 or old_cash != try std.math.sub(i64, 0, old_fee)) return error.SourceMismatch;
    var layers: [2]bool = @splat(false);
    for (record.transactions) |transaction| {
        if (transaction.source_identity != fill.identity or transaction.postings.len != 2) return error.SourceMismatch;
        const layer: usize = @intFromEnum(transaction.layer);
        if (layers[layer]) return error.SourceMismatch;
        layers[layer] = true;
        var cash_found = false;
        var expense_found = false;
        var sum: i128 = 0;
        for (transaction.postings) |posting| {
            const amount = try std.fmt.parseInt(i64, posting.amount, 10);
            sum = try std.math.add(i128, sum, amount);
            switch (posting.account) {
                .cash => {
                    if (cash_found or amount != old_cash) return error.SourceMismatch;
                    cash_found = true;
                },
                .fee_expense => {
                    if (expense_found or amount != old_fee) return error.SourceMismatch;
                    expense_found = true;
                },
            }
        }
        if (!cash_found or !expense_found or sum != 0) return error.UnbalancedPostings;
    }
    const true_cash = try actual.exactAtoms(record.comparison_scale);
    const old_comparison = try (canonical.Decimal{ .coefficient = old_cash, .scale = record.posted_scale }).exactAtoms(record.comparison_scale);
    const difference = try std.math.sub(i128, true_cash, old_comparison);
    result.source_transaction_identity = fill.identity;
    result.raw_evidence = .{ .stream = raw.stream, .sequence = raw.sequence, .sha256 = raw.sha256 };
    result.canonical_fill_identity = fill.identity;
    result.order_identity = order.identity;
    result.exchange_account = order.exchange_account;
    result.instrument = fill.instrument;
    result.venue_trade = fill.venue_trade;
    result.coverage = coverage;
    result.portfolio = order.portfolio;
    result.internal_postings_closed = true;
    result.true_cash_atoms = true_cash;
    result.posted_cash_comparison_atoms = old_comparison;
    result.cash_difference_atoms = difference;
}

test "historical fee audit preserves independent fixed values old posting scale and mirrored closure" {
    var parsed = try parse(std.testing.allocator, @embedFile("historical_fee_audit_samples.json"));
    defer parsed.deinit();
    const expected_actual = [_]i128{ -4_198_632_165, -4_237_238_520 };
    const expected_posted = [_]i128{ -4_199_000_000, -4_238_000_000 };
    const expected_difference = [_]i128{ 367_835, 761_480 };
    for (parsed.value.records[0..2], 0..) |record, index| {
        const result = audit(std.testing.allocator, record);
        try std.testing.expectEqual(@FieldType(Result, "source_join").fixed_fixture_consistent, result.source_join);
        try std.testing.expectEqual(expected_actual[index], result.true_cash_atoms.?);
        try std.testing.expectEqual(expected_posted[index], result.posted_cash_comparison_atoms.?);
        try std.testing.expectEqual(expected_difference[index], result.cash_difference_atoms.?);
        try std.testing.expect(result.internal_postings_closed.?);
        try std.testing.expect(result.asset_version == null);
        try std.testing.expect(!result.production_qualification);
    }
    const historical = audit(std.testing.allocator, parsed.value.records[2]);
    try std.testing.expectEqual(Reason.missing_raw, historical.reason.?);
    try std.testing.expect(historical.cash_difference_atoms == null);
}

test "historical fee audit cannot trust incomplete mismatched or new scale joins" {
    var parsed = try parse(std.testing.allocator, @embedFile("historical_fee_audit_samples.json"));
    defer parsed.deinit();
    const original = parsed.value.records[0];
    var changed = original;
    changed.journal_schema += 1;
    try std.testing.expectEqual(Reason.unsupported_old_interpretation, audit(std.testing.allocator, changed).reason.?);
    changed = original;
    changed.asset_version = 1;
    try std.testing.expectEqual(Reason.unsupported_old_interpretation, audit(std.testing.allocator, changed).reason.?);
    changed = original;
    changed.posted_scale = 12;
    try std.testing.expectEqual(Reason.unsupported_old_interpretation, audit(std.testing.allocator, changed).reason.?);
    changed = original;
    changed.raw.?.sha256 = "bad";
    try std.testing.expectEqual(Reason.source_mismatch, audit(std.testing.allocator, changed).reason.?);
    changed = original;
    changed.order.?.exchange_account += 1;
    try std.testing.expectEqual(Reason.source_mismatch, audit(std.testing.allocator, changed).reason.?);
    changed = original;
    changed.fill.?.venue_trade = "another-trade";
    try std.testing.expectEqual(Reason.source_mismatch, audit(std.testing.allocator, changed).reason.?);
    changed = original;
    changed.coverage.?.through_utc_ns = 1;
    try std.testing.expectEqual(Reason.incomplete_range, audit(std.testing.allocator, changed).reason.?);
    changed = original;
    changed.posted_cash_atoms = "9223372036854775808";
    try std.testing.expectEqual(Reason.overflow, audit(std.testing.allocator, changed).reason.?);
    changed = original;
    changed.transactions = original.transactions[0..1];
    try std.testing.expectEqual(Reason.missing_join, audit(std.testing.allocator, changed).reason.?);
    changed = original;
    changed.fill.?.fee_atoms = "4198";
    try std.testing.expectEqual(Reason.source_mismatch, audit(std.testing.allocator, changed).reason.?);
    changed = original;
    changed.raw.?.bytes = "{\"arg\":{\"channel\":\"orders\"},\"data\":[{\"instId\":\"BTC-USDT\",\"ordId\":\"1001\",\"clOrdId\":\"RWN-FIXED-AUDIT-1\",\"tradeId\":\"2001\",\"fillSz\":\"0.0001\",\"fee\":\"-0.004198632165\",\"fillFeeCcy\":\"USDT\",\"fillTime\":\"1800000000100\"}]}";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(changed.raw.?.bytes, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    changed.raw.?.sha256 = &hash;
    changed.fill.?.raw_sha256 = &hash;
    const cumulative = audit(std.testing.allocator, changed);
    try std.testing.expectEqual(Reason.amount_source_uncertain, cumulative.reason.?);
    try std.testing.expect(cumulative.cash_difference_atoms == null);
    try std.testing.expectError(error.UnknownField, parse(std.testing.allocator, "{\"format\":1,\"records\":[],\"verified\":true}"));
    try std.testing.expectError(error.InvalidHistoricalInput, parse(std.testing.allocator, "{\"format\":2,\"records\":[]}"));
}

test "historical fee audit selects one exact execution from a batched raw frame and rejects ambiguous joins" {
    var parsed = try parse(std.testing.allocator, @embedFile("historical_fee_audit_samples.json"));
    defer parsed.deinit();
    var record = parsed.value.records[0];
    const original = record.raw.?.bytes;
    const start = std.mem.indexOf(u8, original, "[{").? + 1;
    const end = std.mem.lastIndexOf(u8, original, "]}").?;
    var bytes: [4096]u8 = undefined;
    const batched = try std.fmt.bufPrint(&bytes, "{{\"arg\":{{\"channel\":\"orders\"}},\"data\":[{{\"tradeId\":\"other\"}},{s}]}}", .{original[start..end]});
    record.raw.?.bytes = batched;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(batched, &digest, .{});
    var hex = std.fmt.bytesToHex(digest, .lower);
    record.raw.?.sha256 = &hex;
    record.fill.?.raw_sha256 = &hex;
    const result = audit(std.testing.allocator, record);
    try std.testing.expectEqual(@as(?i128, 367835), result.cash_difference_atoms);
    const ambiguous = try std.fmt.bufPrint(&bytes, "{{\"arg\":{{\"channel\":\"orders\"}},\"data\":[{s},{s}]}}", .{ original[start..end], original[start..end] });
    record.raw.?.bytes = ambiguous;
    std.crypto.hash.sha2.Sha256.hash(ambiguous, &digest, .{});
    hex = std.fmt.bytesToHex(digest, .lower);
    const refused = audit(std.testing.allocator, record);
    try std.testing.expectEqual(Reason.amount_source_uncertain, refused.reason.?);
    try std.testing.expect(refused.cash_difference_atoms == null);
}
