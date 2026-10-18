const std = @import("std");
const credentials = @import("credentials");

const Win = struct {
    extern "kernel32" fn CreatePipe(*std.os.windows.HANDLE, *std.os.windows.HANDLE, ?*anyopaque, u32) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(std.os.windows.HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
};

fn passwordPipe() !std.Io.File {
    var read: std.os.windows.HANDLE = undefined;
    var write: std.os.windows.HANDLE = undefined;
    if (Win.CreatePipe(&read, &write, null, 0) == 0) return error.CreatePipeFailed;
    const reader: std.Io.File = .{ .handle = read, .flags = .{ .nonblocking = false } };
    errdefer reader.close(std.testing.io);
    const writer: std.Io.File = .{ .handle = write, .flags = .{ .nonblocking = false } };
    defer writer.close(std.testing.io);
    const password = "synthetic-review-password\n";
    var written: u32 = 0;
    if (Win.WriteFile(write, password.ptr, password.len, &written, null) == 0 or written != password.len)
        return error.WritePipeFailed;
    return reader;
}

fn stage(store: *credentials.CredentialStore, metadata: credentials.Metadata) !void {
    const pipe = try passwordPipe();
    defer pipe.close(std.testing.io);
    var password: [credentials.max_password]u8 = undefined;
    var material = try credentials.SecretMaterial.init("review-key", "review-secret", "review-pass");
    defer material.clear();
    try store.stage(std.testing.io, metadata, &material, pipe, .restricted_fd, &password);
    try std.testing.expect(std.mem.allEqual(u8, &password, 0));
    try std.testing.expect(std.mem.allEqual(u8, &material.secret_key, 0));
}

fn transition(store: *credentials.CredentialStore, metadata: credentials.Metadata, comptime operation: enum { activate, revoke }) !void {
    const pipe = try passwordPipe();
    defer pipe.close(std.testing.io);
    var password: [credentials.max_password]u8 = undefined;
    switch (operation) {
        .activate => try store.activate(std.testing.io, .observation, pipe, .restricted_fd, &password, metadata),
        .revoke => try store.revoke(std.testing.io, .observation, pipe, .restricted_fd, &password, metadata),
    }
}

test "review public stage resurrects same revoked credential identity" {
    const path = "D:/github/Ringwin/.scratch/credential-security-audit-20261018/synthetic-store";
    var store = try credentials.CredentialStore.open(std.testing.io, std.testing.allocator, path);
    defer store.close(std.testing.io);
    const staged = try credentials.Metadata.init(.observation, 7, .production, 4_000_000_000, "review-obs", "review-node", "203.0.113.7");
    try stage(&store, staged);
    try transition(&store, staged, .activate);
    var active = staged;
    active.state = .active;
    active.generation += 1;
    try transition(&store, active, .revoke);
    try stage(&store, staged);
    try transition(&store, staged, .activate);
    const pipe = try passwordPipe();
    defer pipe.close(std.testing.io);
    var password: [credentials.max_password]u8 = undefined;
    const runtime = credentials.RuntimeContext{ .account = 7, .environment = .production, .endpoint_environment = .production, .node_id = "review-node", .egress_ip = "203.0.113.7" };
    const admission = try store.admitObservationReadOnly(std.testing.io, pipe, .restricted_fd, &password, active, runtime, 1, .{});
    try std.testing.expect(admission.isReady());
    std.debug.print("review_revoked_identity_reactivated=true generation_reset=3_to_2\n", .{});
}

test "review HMAC final retains reversible raw key pad" {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    const key = "synthetic-hmac-review-secret";
    var hmac = Hmac.init(key);
    hmac.update("synthetic request");
    var digest: [32]u8 = undefined;
    hmac.final(&digest);
    var recovered: [key.len]u8 = undefined;
    for (&recovered, 0..) |*byte, index| byte.* = hmac.o_key_pad[index] ^ 0x5c;
    try std.testing.expectEqualSlices(u8, key, &recovered);
    std.debug.print("review_hmac_raw_secret_recoverable_after_final=true\n", .{});
    std.crypto.secureZero(u8, std.mem.asBytes(&hmac));
}

test "review Argon2 released workspace reconstructs derived key" {
    const params = std.crypto.pwhash.argon2.Params.owasp_2id;
    const memory_bytes = params.m * 1024;
    const backing = try std.heap.page_allocator.alloc(u8, memory_bytes);
    defer std.heap.page_allocator.free(backing);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try std.crypto.pwhash.argon2.kdf(allocator.allocator(), &key, "synthetic-kdf-password", "synthetic-salt!!", params, .argon2id, std.testing.io);
    var recovered: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &recovered);
    var hash = std.crypto.hash.blake2.Blake2b256.init(.{});
    hash.update(&.{ 32, 0, 0, 0 });
    hash.update(backing[memory_bytes - 1024 .. memory_bytes]);
    hash.final(&recovered);
    const reconstructable = std.mem.eql(u8, &key, &recovered);
    const poisoned = std.mem.allEqual(u8, backing, 0xaa);
    std.debug.print("review_kdf_key_recovered_from_released_workspace={any} allocator_debug_poison={any} mode={s}\n", .{ reconstructable, poisoned, @tagName(@import("builtin").mode) });
    if (@import("builtin").mode == .ReleaseFast) {
        try std.testing.expect(reconstructable);
    } else {
        try std.testing.expect(!reconstructable and poisoned);
    }
    std.crypto.secureZero(u8, backing);
}
