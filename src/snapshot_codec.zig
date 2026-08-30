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
    if (metadata.barrier == 0 or destination.len < header_len) return error.SnapshotTooLarge;
    var writer: Writer = .{ .bytes = destination[header_len..] };
    try encodeValue(&writer, value);
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

pub fn read(encoded: []const u8, comptime T: type, expected_state_schema: u32, expected_release_artifact: u64, expected_schema_registry: u64) !struct { value: T, metadata: Metadata } {
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
    const value = try decodeValue(&reader, T);
    if (reader.position != payload.len) return error.InvalidSnapshotLength;
    var state_digest: [Sha256.digest_length]u8 = undefined;
    std.mem.writeInt(u256, &state_digest, header.state_digest, .little);
    return .{ .value = value, .metadata = .{
        .state_schema = header.state_schema,
        .release_artifact = header.release_artifact,
        .schema_registry = header.schema_registry,
        .barrier = header.barrier,
        .instrument_rules_version = header.instrument_rules_version,
        .margin_rules_version = header.margin_rules_version,
        .state_digest = state_digest,
    } };
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

fn encodeValue(writer: *Writer, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try writer.put(@as(u8, if (value) 1 else 0)),
        .int => try writer.put(value),
        .@"enum" => try encodeValue(writer, @intFromEnum(value)),
        .array => for (value) |item| try encodeValue(writer, item),
        .optional => if (value) |item| {
            try writer.put(@as(u8, 1));
            try encodeValue(writer, item);
        } else try writer.put(@as(u8, 0)),
        .@"struct" => |info| inline for (info.fields) |field|
            try encodeValue(writer, @field(value, field.name)),
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("snapshot unions must be tagged");
            try encodeValue(writer, std.meta.activeTag(value));
            switch (value) {
                inline else => |payload, tag| {
                    _ = tag;
                    if (@TypeOf(payload) != void) try encodeValue(writer, payload);
                },
            }
            _ = Tag;
        },
        else => @compileError("unsupported snapshot field type: " ++ @typeName(T)),
    }
}

fn decodeValue(reader: *Reader, comptime T: type) !T {
    return switch (@typeInfo(T)) {
        .bool => switch (try reader.get(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidSnapshotValue,
        },
        .int => try reader.get(T),
        .@"enum" => |info| blk: {
            const raw = try decodeValue(reader, info.tag_type);
            inline for (info.fields) |field|
                if (raw == field.value) break :blk @field(T, field.name);
            return error.InvalidSnapshotValue;
        },
        .array => |info| blk: {
            var result: T = undefined;
            for (&result) |*item| item.* = try decodeValue(reader, info.child);
            break :blk result;
        },
        .optional => |info| switch (try reader.get(u8)) {
            0 => null,
            1 => try decodeValue(reader, info.child),
            else => error.InvalidSnapshotValue,
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.fields) |field|
                @field(result, field.name) = try decodeValue(reader, field.type);
            break :blk result;
        },
        .@"union" => |info| blk: {
            const Tag = info.tag_type orelse @compileError("snapshot unions must be tagged");
            const tag = try decodeValue(reader, Tag);
            inline for (info.fields) |field| if (tag == @field(Tag, field.name)) {
                const payload = if (field.type == void) {} else try decodeValue(reader, field.type);
                break :blk @unionInit(T, field.name, payload);
            };
            return error.InvalidSnapshotValue;
        },
        else => @compileError("unsupported snapshot field type: " ++ @typeName(T)),
    };
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
