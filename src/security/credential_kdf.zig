//! Fixed-format CredentialStore KDF. Password and derived_key are borrowed from
//! already protected caller-owned memory. No secret is returned by value.
const std = @import("std");
const builtin = @import("builtin");
const protected = @import("protected_memory.zig");
const argon2 = @import("credential_crypto/argon2.zig");

pub const workspace_bytes = 19 * 1024 * 1024 + @sizeOf(argon2.Scratch) + @alignOf(argon2.Scratch);

pub fn derive(io: std.Io, password: []const u8, salt: []const u8, derived_key: *[32]u8) !void {
    errdefer std.crypto.secureZero(u8, derived_key);
    var workspace = try protected.Buffer.init(workspace_bytes);
    defer workspace.deinit();
    try fill(io, password, salt, derived_key, &workspace);
}

pub fn deriveWithTestingBackend(io: std.Io, password: []const u8, salt: []const u8, derived_key: *[32]u8, backend: protected.Backend) !void {
    if (!builtin.is_test) @compileError("KDF test backend is test-only");
    errdefer std.crypto.secureZero(u8, derived_key);
    var workspace = try protected.Buffer.initForTesting(workspace_bytes, backend);
    defer workspace.deinit();
    try fill(io, password, salt, derived_key, &workspace);
}

fn fill(io: std.Io, password: []const u8, salt: []const u8, derived_key: *[32]u8, workspace: *protected.Buffer) !void {
    var allocator = std.heap.FixedBufferAllocator.init(try workspace.writable());
    try argon2.kdf(allocator.allocator(), derived_key, password, salt, .owasp_2id, .argon2id, io);
}

test "credential KDF preserves existing OWASP Argon2id key and erases workspace" {
    var observer = protected.TestingBackend{};
    var result: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &result);
    var original: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &original);
    try std.crypto.pwhash.argon2.kdf(std.testing.allocator, &original, "synthetic-password", "synthetic-salt-16", .owasp_2id, .argon2id, std.testing.io);
    try deriveWithTestingBackend(std.testing.io, "synthetic-password", "synthetic-salt-16", &result, observer.backend());
    try std.testing.expectEqualSlices(u8, &original, &result);
    try std.testing.expectEqual(@as(usize, 1), observer.released);
    try std.testing.expect(observer.erased);
}

test "credential KDF failure erases output and never bypasses protection" {
    var observer = protected.TestingBackend{ .fail = .lock };
    var result: [32]u8 = @splat(0x72);
    try std.testing.expectError(error.MemoryLockFailed, deriveWithTestingBackend(std.testing.io, "synthetic", "salt-salt", &result, observer.backend()));
    try std.testing.expect(std.mem.allEqual(u8, &result, 0));
    try std.testing.expect(observer.erased);
    try std.testing.expectEqual(@as(usize, 1), observer.released);
    observer = .{};
    @memset(&result, 0x41);
    try std.testing.expectError(error.WeakParameters, deriveWithTestingBackend(std.testing.io, "synthetic", "short", &result, observer.backend()));
    try std.testing.expect(std.mem.allEqual(u8, &result, 0));
    try std.testing.expect(observer.erased);
    try std.testing.expectEqual(@as(usize, 1), observer.released);
}

test "credential KDF native locks full workspace or refuses insufficient budget" {
    if (builtin.os.tag == .windows) try protected.configureNativeLockBudget(24 * 1024 * 1024);
    var password = try protected.Buffer.init(18);
    defer password.deinit();
    @memcpy(try password.writable(), "synthetic-password");
    try password.freeze();
    var key = try protected.Buffer.init(32);
    defer key.deinit();
    const destination: *[32]u8 = (try key.writable())[0..32];
    if (builtin.os.tag == .linux and (try std.posix.getrlimit(.MEMLOCK)).cur < workspace_bytes + 2 * std.heap.pageSize()) {
        try std.testing.expectError(error.MemoryLockFailed, derive(std.testing.io, password.bytes(), "synthetic-salt-16", destination));
        try std.testing.expect(std.mem.allEqual(u8, key.bytes(), 0));
        std.debug.print("native KDF refused insufficient RLIMIT_MEMLOCK as required\n", .{});
        return;
    }
    try derive(std.testing.io, password.bytes(), "synthetic-salt-16", destination);
    try key.freeze();
    try std.testing.expect(key.report().locked);
    try std.testing.expect(!std.mem.allEqual(u8, key.bytes(), 0));
}

test "credential Argon2id matches RFC 9106 section 5.3 vector" {
    const password: [32]u8 = @splat(1);
    const salt: [16]u8 = @splat(2);
    const secret: [8]u8 = @splat(3);
    const ad: [12]u8 = @splat(4);
    var observer = protected.TestingBackend{};
    var workspace = try protected.Buffer.initForTesting(32 * 1024 + @sizeOf(argon2.Scratch) + @alignOf(argon2.Scratch), observer.backend());
    var allocator = std.heap.FixedBufferAllocator.init(try workspace.writable());
    var result: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &result);
    try argon2.kdf(allocator.allocator(), &result, &password, &salt, .{ .t = 3, .m = 32, .p = 4, .secret = &secret, .ad = &ad }, .argon2id, std.testing.io);
    const expected = [_]u8{ 0x0d, 0x64, 0x0d, 0xf5, 0x8d, 0x78, 0x76, 0x6c, 0x08, 0xc0, 0x37, 0xa3, 0x4a, 0x8b, 0x53, 0xc9, 0xd0, 0x1e, 0xf0, 0x45, 0x2d, 0x75, 0xb6, 0x5e, 0xb5, 0x25, 0x20, 0xe9, 0x6b, 0x01, 0xe6, 0x59 };
    try std.testing.expectEqualSlices(u8, &expected, &result);
    workspace.deinit();
    try std.testing.expect(observer.erased);
}

test "credential KDF allocates crypto scratch from protected allocator and releases on OOM" {
    var observer = protected.TestingBackend{};
    var workspace = try protected.Buffer.initForTesting(64 * 1024, observer.backend());
    defer workspace.deinit();
    var region = std.heap.FixedBufferAllocator.init(try workspace.writable());
    var allocator = std.testing.FailingAllocator.init(region.allocator(), .{ .fail_index = 1 });
    var result: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &result);
    try std.testing.expectError(error.OutOfMemory, argon2.kdf(allocator.allocator(), &result, "synthetic", "salt-salt", .{ .t = 1, .m = 32, .p = 1 }, .argon2id, std.testing.io));
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}
