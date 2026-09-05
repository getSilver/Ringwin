//! Explicit stable codec for canonical journal inputs.
//!
//! Event framing and union dispatch are frozen here rather than inferred from
//! the in-memory `EventRecord` layout. Bounded arrays encode only their active
//! elements.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const value_codec = @import("snapshot_codec.zig");

pub const encoding_version: u16 = 1;
pub const max_encoded_len: usize = 4096;

const BootstrapHeader = struct {
    identity: canonical.BootstrapSnapshotIdentity,
    exchange_account: canonical.ExchangeAccountIdentity,
    scope: canonical.AccountSnapshotScope,
    source_stream: canonical.VenueSourceStreamIdentity,
    source_sequence: canonical.VenueSourceSequence,
    balance_count: u8,
    position_count: u8,
    margin_count: u8,
};

const Cursor = struct {
    bytes: []u8,
    position: usize = 0,

    fn put(self: *Cursor, bytes: []const u8) !void {
        if (self.position + bytes.len > self.bytes.len) return error.CanonicalEventTooLarge;
        @memcpy(self.bytes[self.position..][0..bytes.len], bytes);
        self.position += bytes.len;
    }

    fn putInt(self: *Cursor, comptime T: type, value: T) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        try self.put(&bytes);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn take(self: *Reader, len: usize) ![]const u8 {
        if (self.position + len > self.bytes.len) return error.InvalidCanonicalEvent;
        const result = self.bytes[self.position..][0..len];
        self.position += len;
        return result;
    }

    fn takeInt(self: *Reader, comptime T: type) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        @memcpy(&bytes, try self.take(@sizeOf(T)));
        return std.mem.readInt(T, &bytes, .little);
    }
};

fn putValue(cursor: *Cursor, value: anytype) !void {
    var temporary: [max_encoded_len]u8 = undefined;
    const encoded = try value_codec.encodeBare(&temporary, value);
    if (encoded.len > std.math.maxInt(u16)) return error.CanonicalEventTooLarge;
    try cursor.putInt(u16, @intCast(encoded.len));
    try cursor.put(encoded);
}

fn takeValue(reader: *Reader, comptime T: type) !T {
    const len = try reader.takeInt(u16);
    return value_codec.decodeBare(try reader.take(len), T) catch return error.InvalidCanonicalEvent;
}

fn encodeBootstrap(cursor: *Cursor, snapshot: canonical.AccountBootstrapSnapshot) !void {
    if (snapshot.balance_count > snapshot.balances.len or
        snapshot.position_count > snapshot.positions.len or
        snapshot.margin_count > snapshot.margins.len)
        return error.InvalidAccountFactCount;
    try putValue(cursor, BootstrapHeader{
        .identity = snapshot.identity,
        .exchange_account = snapshot.exchange_account,
        .scope = snapshot.scope,
        .source_stream = snapshot.source_stream,
        .source_sequence = snapshot.source_sequence,
        .balance_count = snapshot.balance_count,
        .position_count = snapshot.position_count,
        .margin_count = snapshot.margin_count,
    });
    for (snapshot.balances[0..snapshot.balance_count]) |value| try putValue(cursor, value);
    for (snapshot.positions[0..snapshot.position_count]) |value| try putValue(cursor, value);
    for (snapshot.margins[0..snapshot.margin_count]) |value| try putValue(cursor, value);
}

fn decodeBootstrap(reader: *Reader) !canonical.AccountBootstrapSnapshot {
    const header = try takeValue(reader, BootstrapHeader);
    if (header.balance_count > canonical.max_account_facts or
        header.position_count > canonical.max_account_facts or
        header.margin_count > canonical.max_account_facts)
        return error.InvalidAccountFactCount;
    var snapshot: canonical.AccountBootstrapSnapshot = .{
        .identity = header.identity,
        .exchange_account = header.exchange_account,
        .scope = header.scope,
        .source_stream = header.source_stream,
        .source_sequence = header.source_sequence,
        .balance_count = header.balance_count,
        .position_count = header.position_count,
        .margin_count = header.margin_count,
    };
    for (snapshot.balances[0..snapshot.balance_count]) |*value| value.* = try takeValue(reader, canonical.AccountBalance);
    for (snapshot.positions[0..snapshot.position_count]) |*value| value.* = try takeValue(reader, canonical.AccountPosition);
    for (snapshot.margins[0..snapshot.margin_count]) |*value| value.* = try takeValue(reader, canonical.AccountMargin);
    for (snapshot.balances[snapshot.balance_count..]) |*value| value.* = std.mem.zeroes(canonical.AccountBalance);
    for (snapshot.positions[snapshot.position_count..]) |*value| value.* = std.mem.zeroes(canonical.AccountPosition);
    for (snapshot.margins[snapshot.margin_count..]) |*value| value.* = std.mem.zeroes(canonical.AccountMargin);
    return snapshot;
}

fn encodeEvent(cursor: *Cursor, event: canonical.CanonicalEvent) !void {
    switch (event) {
        .account_bootstrap_snapshot => |snapshot| try encodeBootstrap(cursor, snapshot),
        .order_dispatch_result => |value| try putValue(cursor, value),
        .execution_report => |value| try putValue(cursor, value),
        .fill => |value| try putValue(cursor, value),
        .reconciliation_started => |value| try putValue(cursor, value),
        .account_reconciliation_started => |value| try putValue(cursor, value),
        .instrument_definition_observed => |value| try putValue(cursor, value),
        .l2_book_snapshot => |value| try putValue(cursor, value),
        .l2_book_delta => |value| try putValue(cursor, value),
        .reference_price => |value| try putValue(cursor, value),
        .funding_rate_published => |value| try putValue(cursor, value),
        .market_data_health_changed => |value| try putValue(cursor, value),
        .account_observed => |value| try putValue(cursor, value),
        .venue_account_configuration_snapshot => |value| try putValue(cursor, value),
        .order_reconciliation_result => |value| try putValue(cursor, value),
        .account_reconciliation_result => |value| try putValue(cursor, value),
    }
}

/// Encodes only the canonical payload for identity and deduplication hashing.
pub fn encodePayload(destination: []u8, event: canonical.CanonicalEvent) ![]const u8 {
    var cursor: Cursor = .{ .bytes = destination };
    try cursor.putInt(u32, @intFromEnum(canonical.eventType(event)));
    try encodeEvent(&cursor, event);
    return destination[0..cursor.position];
}

pub fn encode(destination: []u8, record: canonical.EventRecord) ![]const u8 {
    if (record.envelope.schema_version != canonical.schema_version or
        record.envelope.event_type != @intFromEnum(canonical.eventType(record.event)))
        return error.InvalidCanonicalEnvelope;
    var cursor: Cursor = .{ .bytes = destination };
    try cursor.putInt(u16, encoding_version);
    try putValue(&cursor, record.envelope);
    try encodeEvent(&cursor, record.event);
    return destination[0..cursor.position];
}

pub fn decode(encoded: []const u8) !canonical.EventRecord {
    var reader: Reader = .{ .bytes = encoded };
    if (try reader.takeInt(u16) != encoding_version) return error.UnsupportedCanonicalEncoding;
    const envelope = try takeValue(&reader, canonical.EventEnvelope);
    const event_type = std.enums.fromInt(canonical.EventType, envelope.event_type) orelse return error.InvalidCanonicalEnvelope;
    const event: canonical.CanonicalEvent = switch (event_type) {
        .account_bootstrap_snapshot => .{ .account_bootstrap_snapshot = try decodeBootstrap(&reader) },
        .order_dispatch_result => .{ .order_dispatch_result = try takeValue(&reader, canonical.OrderDispatchResult) },
        .execution_report => .{ .execution_report = try takeValue(&reader, canonical.ExecutionReport) },
        .fill => .{ .fill = try takeValue(&reader, canonical.Fill) },
        .reconciliation_started => .{ .reconciliation_started = try takeValue(&reader, u128) },
        .account_reconciliation_started => .{ .account_reconciliation_started = try takeValue(&reader, u128) },
        .instrument_definition_observed => .{ .instrument_definition_observed = try takeValue(&reader, canonical.InstrumentDefinitionObserved) },
        .l2_book_snapshot => .{ .l2_book_snapshot = try takeValue(&reader, canonical.L2BookSnapshot) },
        .l2_book_delta => .{ .l2_book_delta = try takeValue(&reader, canonical.L2BookDelta) },
        .reference_price => .{ .reference_price = try takeValue(&reader, canonical.ReferencePrice) },
        .funding_rate_published => .{ .funding_rate_published = try takeValue(&reader, canonical.FundingRatePublished) },
        .market_data_health_changed => .{ .market_data_health_changed = try takeValue(&reader, canonical.MarketDataHealthChanged) },
        .account_observed => .{ .account_observed = try takeValue(&reader, canonical.AccountObservation) },
        .venue_account_configuration_snapshot => .{ .venue_account_configuration_snapshot = try takeValue(&reader, canonical.VenueAccountConfigurationSnapshot) },
        .order_reconciliation_result => .{ .order_reconciliation_result = try takeValue(&reader, canonical.ReconciliationResult) },
        .account_reconciliation_result => .{ .account_reconciliation_result = try takeValue(&reader, canonical.ReconciliationResult) },
    };
    if (reader.position != encoded.len or envelope.schema_version != canonical.schema_version or
        envelope.event_type != @intFromEnum(canonical.eventType(event)))
        return error.InvalidCanonicalEnvelope;
    return .{ .envelope = envelope, .event = event };
}

fn testEnvelope(event_type: canonical.EventType) canonical.EventEnvelope {
    return .{
        .event_type = @intFromEnum(event_type),
        .schema_version = canonical.schema_version,
        .identity = .{ .stream = 7, .sequence = 9 },
        .source_fact_identity = 11,
        .scope = .account,
        .venue = 1,
        .exchange_account = 2,
        .source_stream = 3,
        .source_sequence = 4,
        .times = .{ .source_utc_ns = 5, .receive_utc_ns = 6 },
        .raw_evidence = .{ .stream = 3, .sequence = 4, .digest = @splat(0xaa) },
    };
}

test "bootstrap encodes active facts without fixed-array tails" {
    var snapshot: canonical.AccountBootstrapSnapshot = .{
        .identity = 10,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 3,
        .source_sequence = 4,
        .balance_count = 1,
        .position_count = 0,
        .margin_count = 0,
    };
    snapshot.balances[0] = .{
        .asset = 5,
        .total = .{ .asset = 5, .atoms = 100 },
        .available = .{ .asset = 5, .atoms = 90 },
        .held = .{ .asset = 5, .atoms = 10 },
    };
    var encoded_storage: [max_encoded_len]u8 = undefined;
    const encoded = try encode(&encoded_storage, .{
        .envelope = testEnvelope(.account_bootstrap_snapshot),
        .event = .{ .account_bootstrap_snapshot = snapshot },
    });
    try std.testing.expect(encoded.len < 1024);
    const decoded = (try decode(encoded)).event.account_bootstrap_snapshot;
    try std.testing.expectEqual(@as(u8, 1), decoded.balance_count);
    try std.testing.expectEqualDeep(snapshot.balances[0], decoded.balances[0]);
    try std.testing.expectEqualDeep(std.mem.zeroes(canonical.AccountBalance), decoded.balances[1]);
}
