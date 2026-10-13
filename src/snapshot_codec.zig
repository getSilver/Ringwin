//! Physical authoritative-snapshot codec.
//! TradingShard owns state transitions and semantic validation; this module owns
//! only bounded binary encoding, integrity checks, and schema metadata.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Crc32c = std.hash.crc.Crc32Iscsi;
const magic: u64 = 0x50414e53574e4952; // RINWSNAP

pub const header_len: usize = 144;

const Header = packed struct {
    magic: u64,
    encoding_version: u16,
    header_len: u16,
    total_len: u32,
    state_schema: u32,
    release_artifact: u64,
    schema_registry: u64,
    barrier: u64,
    instrument_rules_version: u32,
    margin_rules_version: u32,
    payload_len: u32,
    payload_crc: u32,
    state_digest: u256,
    payload_digest: u256,
    header_crc: u32,
    reserved: u128 = 0,
};
comptime {
    std.debug.assert(@sizeOf(Header) == header_len);
}

pub const Metadata = struct {
    state_schema: u32,
    release_artifact: u64,
    schema_registry: u64,
    barrier: u64,
    instrument_rules_version: u32,
    margin_rules_version: u32,
    state_digest: [Sha256.digest_length]u8,
};

pub fn write(destination: []u8, metadata: Metadata, value: anytype) ![]const u8 {
    return writeWithPolicy(destination, metadata, value, IdentityEncodingPolicy);
}

/// Policy describes canonical field views without copying the source object.
pub fn writeWithPolicy(destination: []u8, metadata: Metadata, value: anytype, comptime Policy: type) ![]const u8 {
    if (metadata.barrier == 0 or destination.len < header_len) return error.SnapshotTooLarge;
    var writer: Writer = .{ .bytes = destination[header_len..] };
    if (comptime @typeInfo(@TypeOf(value)) == .pointer) {
        try encodeBorrowedWithPolicy(&writer, value, Policy);
    } else try encodeBorrowedWithPolicy(&writer, &value, Policy);
    const payload = destination[header_len .. header_len + writer.position];
    const total_len = header_len + payload.len;
    if (payload.len > std.math.maxInt(u32)) return error.SnapshotTooLarge;

    var payload_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &payload_digest, .{});
    var header: Header = .{
        .magic = magic,
        .encoding_version = 1,
        .header_len = header_len,
        .total_len = @intCast(total_len),
        .state_schema = metadata.state_schema,
        .release_artifact = metadata.release_artifact,
        .schema_registry = metadata.schema_registry,
        .barrier = metadata.barrier,
        .instrument_rules_version = metadata.instrument_rules_version,
        .margin_rules_version = metadata.margin_rules_version,
        .payload_len = @intCast(payload.len),
        .payload_crc = Crc32c.hash(payload),
        .state_digest = std.mem.readInt(u256, &metadata.state_digest, .little),
        .payload_digest = std.mem.readInt(u256, &payload_digest, .little),
        .header_crc = 0,
    };
    header.header_crc = Crc32c.hash(std.mem.asBytes(&header)[0..@offsetOf(Header, "header_crc")]);
    const encoded = destination[0..total_len];
    @memcpy(encoded[0..header_len], std.mem.asBytes(&header));
    return encoded;
}

pub fn ReadResult(comptime T: type) type {
    return struct { value: T, metadata: Metadata };
}

pub fn read(encoded: []const u8, comptime T: type, expected_state_schema: u32, expected_release_artifact: u64, expected_schema_registry: u64) !ReadResult(T) {
    var result: ReadResult(T) = undefined;
    result.metadata = try readInto(encoded, &result.value, expected_state_schema, expected_release_artifact, expected_schema_registry);
    return result;
}

/// Decodes into caller-owned scratch; a failed candidate must never be published.
pub fn readInto(encoded: []const u8, destination: anytype, expected_state_schema: u32, expected_release_artifact: u64, expected_schema_registry: u64) !Metadata {
    if (encoded.len < header_len) return error.InvalidSnapshotHeader;
    var header: Header = undefined;
    @memcpy(std.mem.asBytes(&header), encoded[0..header_len]);
    if (header.magic != magic or header.encoding_version != 1 or
        header.header_len != header_len or header.total_len != encoded.len or
        header.state_schema != expected_state_schema or
        header.release_artifact != expected_release_artifact or
        header.schema_registry != expected_schema_registry or
        header.header_crc != Crc32c.hash(encoded[0..@offsetOf(Header, "header_crc")]))
        return error.InvalidSnapshotHeader;
    if (header.payload_len != encoded.len - header_len) return error.InvalidSnapshotLength;
    const payload = encoded[header_len..];
    var payload_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &payload_digest, .{});
    if (header.payload_crc != Crc32c.hash(payload) or
        header.payload_digest != std.mem.readInt(u256, &payload_digest, .little))
        return error.InvalidSnapshotPayload;

    var reader: Reader = .{ .bytes = payload };
    try decodeValueInto(&reader, destination);
    if (reader.position != payload.len) return error.InvalidSnapshotLength;
    var state_digest: [Sha256.digest_length]u8 = undefined;
    std.mem.writeInt(u256, &state_digest, header.state_digest, .little);
    return .{
        .state_schema = header.state_schema,
        .release_artifact = header.release_artifact,
        .schema_registry = header.schema_registry,
        .barrier = header.barrier,
        .instrument_rules_version = header.instrument_rules_version,
        .margin_rules_version = header.margin_rules_version,
        .state_digest = state_digest,
    };
}

/// Encodes a bounded value without the snapshot header. Used by the stable
/// event journal, which already supplies framing and integrity checks.
pub fn encodeBare(destination: []u8, value: anytype) ![]const u8 {
    var writer: Writer = .{ .bytes = destination };
    try encodeValue(&writer, value);
    return destination[0..writer.position];
}

/// Decodes one complete bounded value from a journal payload.
pub fn decodeBare(encoded: []const u8, comptime T: type) !T {
    var reader: Reader = .{ .bytes = encoded };
    var value: T = undefined;
    try decodeValueInto(&reader, &value);
    if (reader.position != encoded.len) return error.InvalidSnapshotLength;
    return value;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn put(self: *Writer, value: anytype) !void {
        const T = @TypeOf(value);
        const width = if (T == usize or T == isize) @sizeOf(u64) else @sizeOf(T);
        if (self.position + width > self.bytes.len) return error.SnapshotTooLarge;
        if (T == usize) {
            std.mem.writeInt(u64, self.bytes[self.position..][0..width], @intCast(value), .little);
        } else if (T == isize) {
            std.mem.writeInt(i64, self.bytes[self.position..][0..width], @intCast(value), .little);
        } else {
            std.mem.writeInt(T, self.bytes[self.position..][0..width], value, .little);
        }
        self.position += width;
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn get(self: *Reader, comptime T: type) !T {
        const width = if (T == usize or T == isize) @sizeOf(u64) else @sizeOf(T);
        if (self.position + width > self.bytes.len) return error.InvalidSnapshotLength;
        const value = if (T == usize)
            std.math.cast(usize, std.mem.readInt(u64, self.bytes[self.position..][0..width], .little)) orelse return error.InvalidSnapshotValue
        else if (T == isize)
            std.math.cast(isize, std.mem.readInt(i64, self.bytes[self.position..][0..width], .little)) orelse return error.InvalidSnapshotValue
        else
            std.mem.readInt(T, self.bytes[self.position..][0..width], .little);
        self.position += width;
        return value;
    }
};

fn omsArrayCount(comptime T: type, comptime name: []const u8) ?[]const u8 {
    if (@hasField(T, "deferred_history_admission_count") and comptime std.mem.eql(u8, name, "deferred_history_admissions")) return "deferred_history_admission_count";
    if (@hasField(T, "dispatch_ingress_history_count") and comptime std.mem.eql(u8, name, "dispatch_ingress_history")) return "dispatch_ingress_history_count";
    if (!@hasField(T, "next_order_id") or !@hasField(T, "next_command_id")) return null;
    inline for (.{
        .{ "orders", "order_count" },                                  .{ "commands", "command_count" },
        .{ "command_history", "command_history_count" },               .{ "report_history", "report_history_count" },
        .{ "reconciliation_history", "reconciliation_history_count" }, .{ "intent_history", "intent_history_count" },
        .{ "tombstones", "tombstone_count" },
    }) |mapping| if (std.mem.eql(u8, name, mapping[0])) return mapping[1];
    return null;
}

fn encodeValue(writer: *Writer, value: anytype) !void {
    if (comptime @typeInfo(@TypeOf(value)) == .pointer) {
        if (comptime @typeInfo(@TypeOf(value)).pointer.size != .one) @compileError("snapshot input must be one borrowed value");
        try encodeBorrowed(writer, value);
    } else try encodeBorrowed(writer, &value);
}

const IdentityEncodingPolicy = struct {
    pub fn fieldIsZero(comptime T: type, comptime name: []const u8) bool {
        _ = T;
        _ = name;
        return false;
    }
    pub fn counter(value: anytype, comptime name: []const u8) usize {
        return @field(value.*, name);
    }
    pub fn tailCounter(comptime T: type, comptime name: []const u8) ?[]const u8 {
        _ = T;
        _ = name;
        return null;
    }
    pub fn zeroValue(comptime T: type) T {
        return std.mem.zeroes(T);
    }
};

fn encodeBorrowed(writer: *Writer, value: anytype) !void {
    try encodeBorrowedWithPolicy(writer, value, IdentityEncodingPolicy);
}

fn encodeBorrowedWithPolicy(writer: *Writer, value: anytype, comptime Policy: type) !void {
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    switch (@typeInfo(T)) {
        .bool => try writer.put(@as(u8, if (value.*) 1 else 0)),
        .int => |info| if (info.bits % 8 == 0)
            try writer.put(value.*)
        else if (info.signedness == .signed)
            try writer.put(@as(i64, @intCast(value.*)))
        else
            try writer.put(@as(u64, @intCast(value.*))),
        .@"enum" => |info| if (@typeInfo(info.tag_type).int.bits % 8 == 0)
            try writer.put(@intFromEnum(value.*))
        else
            try writer.put(@as(u64, @intCast(@intFromEnum(value.*)))),
        .array => for (value) |*item| try encodeBorrowedWithPolicy(writer, item, Policy),
        .optional => if (value.*) |*item| {
            try writer.put(@as(u8, 1));
            try encodeBorrowedWithPolicy(writer, item, Policy);
        } else try writer.put(@as(u8, 0)),
        .@"struct" => |info| inline for (info.fields) |field| {
            if (comptime Policy.fieldIsZero(T, field.name)) {
                const zero: field.type = std.mem.zeroes(field.type);
                try encodeBorrowedWithPolicy(writer, &zero, Policy);
            } else if (comptime omsArrayCount(T, field.name)) |counter| {
                const count = Policy.counter(value, counter);
                const items = &@field(value.*, field.name);
                if (count > items.len) return error.InvalidSnapshotValue;
                try writer.put(@as(u32, @intCast(count)));
                for (items[0..count]) |*item| try encodeBorrowedWithPolicy(writer, item, Policy);
            } else if (comptime @typeInfo(field.type) == .array) {
                if (comptime Policy.tailCounter(T, field.name)) |counter_name| {
                    const count: usize = @field(value.*, counter_name);
                    const items = &@field(value.*, field.name);
                    if (count > items.len) return error.InvalidSnapshotValue;
                    for (items[0..count]) |*item| try encodeBorrowedWithPolicy(writer, item, Policy);
                    if (count != items.len) {
                        const zero = Policy.zeroValue(@typeInfo(field.type).array.child);
                        const start = writer.position;
                        try encodeBorrowedWithPolicy(writer, &zero, Policy);
                        const zero_bytes = writer.bytes[start..writer.position];
                        for (count + 1..items.len) |_| {
                            if (zero_bytes.len > writer.bytes.len - writer.position) return error.SnapshotTooLarge;
                            @memcpy(writer.bytes[writer.position..][0..zero_bytes.len], zero_bytes);
                            writer.position += zero_bytes.len;
                        }
                    }
                } else try encodeBorrowedWithPolicy(writer, &@field(value.*, field.name), Policy);
            } else try encodeBorrowedWithPolicy(writer, &@field(value.*, field.name), Policy);
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("snapshot unions must be tagged");
            const tag = std.meta.activeTag(value.*);
            try encodeValue(writer, tag);
            inline for (info.fields) |field| if (tag == @field(Tag, field.name)) {
                if (field.type != void) try encodeBorrowedWithPolicy(writer, &@field(value.*, field.name), Policy);
            };
        },
        else => @compileError("unsupported snapshot field type: " ++ @typeName(T)),
    }
}

fn decodeValueInto(reader: *Reader, destination: anytype) !void {
    const T = @typeInfo(@TypeOf(destination)).pointer.child;
    switch (@typeInfo(T)) {
        .bool => destination.* = switch (try reader.get(u8)) {
            0 => false,
            1 => true,
            else => return error.InvalidSnapshotValue,
        },
        .int => |info| destination.* = if (info.bits % 8 == 0)
            try reader.get(T)
        else if (info.signedness == .signed)
            std.math.cast(T, try reader.get(i64)) orelse return error.InvalidSnapshotValue
        else
            std.math.cast(T, try reader.get(u64)) orelse return error.InvalidSnapshotValue,
        .@"enum" => |info| {
            const raw = if (@typeInfo(info.tag_type).int.bits % 8 == 0)
                try reader.get(info.tag_type)
            else
                try reader.get(u64);
            inline for (info.fields) |field| if (raw == field.value) {
                destination.* = @field(T, field.name);
                return;
            };
            return error.InvalidSnapshotValue;
        },
        .array => {
            for (destination) |*item| try decodeValueInto(reader, item);
        },
        .optional => |info| switch (try reader.get(u8)) {
            0 => destination.* = null,
            1 => {
                destination.* = @as(info.child, undefined);
                try decodeValueInto(reader, &destination.*.?);
            },
            else => return error.InvalidSnapshotValue,
        },
        .@"struct" => |info| {
            var active_lengths: [info.fields.len]?u32 = @splat(null);
            inline for (info.fields, 0..) |field, index| {
                if (comptime omsArrayCount(T, field.name)) |_| {
                    const count = try reader.get(u32);
                    const items = &@field(destination.*, field.name);
                    if (count > items.len) return error.InvalidSnapshotValue;
                    active_lengths[index] = count;
                    for (items[0..count]) |*item| try decodeValueInto(reader, item);
                    const Child = @typeInfo(field.type).array.child;
                    for (items[count..]) |*item| item.* = std.mem.zeroes(Child);
                } else try decodeValueInto(reader, &@field(destination.*, field.name));
            }
            inline for (info.fields, 0..) |field, index| {
                if (comptime omsArrayCount(T, field.name)) |counter|
                    if (@field(destination.*, counter) != active_lengths[index].?) return error.InvalidSnapshotValue;
            }
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("snapshot unions must be tagged");
            var tag: Tag = undefined;
            try decodeValueInto(reader, &tag);
            inline for (info.fields) |field| if (tag == @field(Tag, field.name)) {
                destination.* = @unionInit(T, field.name, if (field.type == void) {} else undefined);
                if (field.type != void) try decodeValueInto(reader, &@field(destination.*, field.name));
                return;
            };
            return error.InvalidSnapshotValue;
        },
        else => @compileError("unsupported snapshot field type: " ++ @typeName(T)),
    }
}

test "snapshot codec rejects truncation CRC corruption and invalid enum values" {
    const StateKind = enum(u8) { idle, active };
    const State = struct { enabled: bool, state: StateKind };
    var bytes: [256]u8 = undefined;
    const encoded = try write(&bytes, .{ .state_schema = 1, .release_artifact = 2, .schema_registry = 3, .barrier = 4, .instrument_rules_version = 5, .margin_rules_version = 6, .state_digest = @splat(7) }, State{ .enabled = true, .state = .active });
    const decoded = try read(encoded, State, 1, 2, 3);
    try std.testing.expect(decoded.value.enabled);
    try std.testing.expectEqual(StateKind.active, decoded.value.state);
    try std.testing.expectError(error.InvalidSnapshotHeader, read(encoded[0 .. header_len - 1], State, 1, 2, 3));
    try std.testing.expectError(error.InvalidSnapshotHeader, read(encoded, State, 9, 2, 3));
    var corrupt: [256]u8 = undefined;
    @memcpy(corrupt[0..encoded.len], encoded);
    corrupt[header_len] ^= 1;
    try std.testing.expectError(error.InvalidSnapshotPayload, read(corrupt[0..encoded.len], State, 1, 2, 3));

    @memcpy(corrupt[0..encoded.len], encoded);
    corrupt[header_len + 1] = 9;
    var header: Header = undefined;
    @memcpy(std.mem.asBytes(&header), corrupt[0..header_len]);
    const payload = corrupt[header_len..encoded.len];
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    header.payload_crc = Crc32c.hash(payload);
    header.payload_digest = std.mem.readInt(u256, &digest, .little);
    header.header_crc = 0;
    header.header_crc = Crc32c.hash(std.mem.asBytes(&header)[0..@offsetOf(Header, "header_crc")]);
    @memcpy(corrupt[0..header_len], std.mem.asBytes(&header));
    try std.testing.expectError(error.InvalidSnapshotValue, read(corrupt[0..encoded.len], State, 1, 2, 3));
}

test "in place decoding round trips nested arrays optional and union payloads" {
    const Payload = union(enum) { absent: void, rows: [125]struct { active: bool, quantity: i7, mark: ?i128 } };
    var expected: Payload = .{ .rows = undefined };
    for (&expected.rows, 0..) |*row, index| row.* = .{
        .active = index % 2 == 0,
        .quantity = -17,
        .mark = if (index % 3 == 0) @as(i128, 1) << 80 else null,
    };
    var bytes: [8192]u8 = undefined;
    const encoded = try encodeBare(&bytes, expected);
    try std.testing.expectEqualDeep(expected, try decodeBare(encoded, Payload));
    try std.testing.expectError(error.InvalidSnapshotLength, decodeBare(encoded[0 .. encoded.len - 1], Payload));
    try std.testing.expectError(error.InvalidSnapshotLength, decodeBare(bytes[0 .. encoded.len + 1], Payload));
    const absent = try encodeBare(&bytes, Payload{ .absent = {} });
    try std.testing.expectEqualDeep(Payload{ .absent = {} }, try decodeBare(absent, Payload));
    bytes[0] = 9;
    try std.testing.expectError(error.InvalidSnapshotValue, decodeBare(absent, Payload));
}

test "OMS snapshot encodes active records without reserving unused terminal capacity" {
    const oms = @import("oms.zig");
    var source: oms.Oms = .{};
    var bytes: [4096]u8 = undefined;
    const encoded = try encodeBare(&bytes, source);
    try std.testing.expect(encoded.len < 128);
    const restored = try decodeBare(encoded, oms.Oms);
    try std.testing.expectEqual(source.next_order_id, restored.next_order_id);
    try std.testing.expectEqual(source.order_count, restored.order_count);
    source.next_order_id = 7;
    const updated = try encodeBare(&bytes, source);
    try std.testing.expectEqual(@as(u64, 7), (try decodeBare(updated, oms.Oms)).next_order_id);
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    try std.testing.expectError(error.InvalidSnapshotValue, decodeBare(updated, oms.Oms));
    _ = try encodeBare(&bytes, &source);
    std.mem.writeInt(u32, bytes[0..4], oms.max_orders + 1, .little);
    try std.testing.expectError(error.InvalidSnapshotValue, decodeBare(updated, oms.Oms));
}
