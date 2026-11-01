//! Typed in-node execution of the v1 observation-only static entrypoint.
const std = @import("std");
const builtin = @import("builtin");
const registry = @import("native_registry.zig");
const contract = @import("native_definition.zig");
const observer = @import("native_observer.zig");
const trading = @import("../trading/trading_shard.zig");

pub const Build = struct {
    format_version: u32,
    runtime: []const u8,
    zig_version: []const u8,
    target: []const u8,
    optimize: []const u8,
    binary_path: []const u8,
    definitions: []const contract.Definition,
};

pub fn verifyBuild(gpa: std.mem.Allocator, bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(Build, gpa, bytes, .{});
    defer parsed.deinit();
    const build = parsed.value;
    const target = try builtin.target.zigTriple(gpa);
    defer gpa.free(target);
    if (build.format_version != 1 or !std.mem.eql(u8, build.runtime, "native_static") or
        !std.mem.eql(u8, build.zig_version, builtin.zig_version_string) or
        !std.mem.eql(u8, build.target, target) or !std.mem.eql(u8, build.optimize, @tagName(builtin.mode)) or
        !std.mem.eql(u8, build.binary_path, if (builtin.os.tag == .windows) "bin/ringwin.exe" else "bin/ringwin") or
        build.definitions.len != registry.registrations.len) return error.NativeBuildMismatch;
    inline for (registry.registrations, 0..) |registration, index| {
        const actual = try std.json.Stringify.valueAlloc(gpa, registration.definition, .{});
        defer gpa.free(actual);
        const expected = try std.json.Stringify.valueAlloc(gpa, build.definitions[index], .{});
        defer gpa.free(expected);
        if (!std.mem.eql(u8, actual, expected)) return error.NativeBuildMismatch;
    }
}

pub const Instance = struct {
    definition: u128,
    config: observer.Config,
    state: observer.State,
    cursor: u64 = 0,

    pub fn create(gpa: std.mem.Allocator, definition: u128, config_json: []const u8) !Instance {
        @setEvalBranchQuota(10_000);
        inline for (registry.registrations) |registration| {
            if (definition == comptime (contract.identity(registration.definition.definition_identity) catch unreachable)) {
                if (comptime registration.implementation == observer) {
                    const config = try std.json.parseFromSlice(observer.Config, gpa, config_json, .{});
                    defer config.deinit();
                    const state = try observer.create(config.value);
                    try observer.validate(config.value, state);
                    return .{ .definition = definition, .config = config.value, .state = state };
                } else return error.UnsupportedNativeEntrypoint;
            }
        }
        return error.NativeDefinitionNotRegistered;
    }

    pub fn catchUp(self: *Instance, journal: *const trading.journal.Journal, barrier: u64) !void {
        var candidate = self.*;
        var reader = try trading.journal.Reader.init(journal.bytes());
        // Without a supported native checkpoint, a complete journal is required.
        if (reader.next_sequence != 1) return error.NativeRecoveryLogUnavailable;
        while (true) switch (try reader.next()) {
            .record => |record| {
                if (record.sequence <= candidate.cursor or record.sequence > barrier or
                    record.flags & trading.journal.input_flag == 0 or record.flags >> 8 != 0) continue;
                const input = try trading.decodeStableInput(record);
                if (input == .venue and input.venue.event == .reference_price) {
                    const price = input.venue.event.reference_price;
                    if (price.instrument == candidate.config.instrument)
                        try observer.onReferencePrice(candidate.config, &candidate.state, record.sequence, price);
                }
            },
            .end => |status| {
                if ((status != .clean and reader.offset != journal.bytes().len) or reader.last_sequence < barrier) return error.NativeRecoveryLogUnavailable;
                break;
            },
        };
        try observer.validate(candidate.config, candidate.state);
        candidate.cursor = barrier;
        self.* = candidate;
    }
};
