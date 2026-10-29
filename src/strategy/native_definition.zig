//! Metadata shared by static registration and the independent build manifest.
const std = @import("std");

pub const Schema = struct { identity: []const u8, version: u32, path: []const u8, sha256: []const u8 };
pub const Compatibility = struct {
    native_api: u32,
    canonical_schema: u16,
    schema_registry: u64,
    journal_schema: u16,
    core_state_schema: u32,
};
pub const Definition = struct {
    definition_identity: []const u8,
    name: []const u8,
    entrypoint: []const u8,
    algorithm_path: []const u8,
    algorithm_sha256: []const u8,
    config_schema: Schema,
    state_schema: Schema,
    compatibility: Compatibility,
    subscription: u32,
    output: enum { none },
};

pub fn sha256(comptime bytes: []const u8) []const u8 {
    const digest = comptime blk: {
        @setEvalBranchQuota(100_000);
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
        break :blk result;
    };
    return &std.fmt.bytesToHex(digest, .lower);
}

pub fn identity(bytes: []const u8) !u128 {
    if (bytes.len != 32) return error.InvalidDefinition;
    for (bytes) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return error.InvalidDefinition;
    const value = std.fmt.parseInt(u128, bytes, 16) catch return error.InvalidDefinition;
    if (value == 0) return error.InvalidDefinition;
    return value;
}
