//! One-shot Demo-only credential import. This grants no production admission.
const std = @import("std");
const builtin = @import("builtin");
const auth = @import("okx_rest_auth.zig");
const protected = @import("protected_memory.zig");
pub const Purpose = enum(u8) { observation = 1, execution = 2 };
pub const account: u64 = 2;
pub const header_length = 22;

pub fn rejectLegacy(environ: anytype) !void {
    for ([_][]const u8{ "RINGWIN_OKX_KEY", "RINGWIN_OKX_SECRET", "RINGWIN_OKX_PASSPHRASE" }) |name|
        if (environ.get(name) != null) return error.LegacyCredentialEnvironmentRejected;
}

pub fn read(io: std.Io, file: std.Io.File, purpose: Purpose, expected_account: u64) !auth.Credentials {
    try inspect(io, file);
    var header: [header_length]u8 = undefined;
    try readExact(io, file, &header);
    if (!std.mem.eql(u8, header[0..4], "RWDC") or header[4] != 1 or header[7] != 0) return error.InvalidCredentialFrame;
    if (header[5] != 1) return error.DemoCredentialEnvironmentRequired;
    if (header[6] != @intFromEnum(purpose)) return error.CredentialPurposeMismatch;
    if (std.mem.readInt(u64, header[8..16], .little) != expected_account or expected_account != account) return error.CredentialAccountMismatch;
    var lengths: [3]u16 = undefined;
    for (&lengths, 0..) |*length, index| {
        length.* = std.mem.readInt(u16, header[16 + index * 2 ..][0..2], .little);
        if (length.* == 0 or length.* > 128) return error.InvalidCredentialLength;
    }
    var owner = try auth.Credentials.initEmpty();
    errdefer owner.deinit();
    const fields = try owner.writableFields();
    for ([_][]u8{ fields.api_key, fields.secret_key, fields.passphrase }, lengths) |field, length| try readExact(io, file, field[0..length]);
    var scratch = try protected.Buffer.init(1);
    defer scratch.deinit();
    const amount = file.readStreaming(io, &.{try scratch.writable()}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    if (amount != 0) return error.TrailingCredentialData;
    try owner.sealLengths(lengths[0], lengths[1], lengths[2]);
    return owner;
}

pub fn forward(io: std.Io, file: std.Io.File, owner: *const auth.Credentials, purpose: Purpose, expected_account: u64) !void {
    try inspect(io, file);
    if (!owner.sealed or expected_account != account) return error.InvalidCredentialFrame;
    var header: [header_length]u8 = @splat(0);
    @memcpy(header[0..4], "RWDC");
    header[4] = 1;
    header[5] = 1;
    header[6] = @intFromEnum(purpose);
    std.mem.writeInt(u64, header[8..16], expected_account, .little);
    for (owner.lengths, 0..) |length, index| std.mem.writeInt(u16, header[16 + index * 2 ..][0..2], length, .little);
    try file.writeStreamingAll(io, &header);
    for (owner.lengths, 0..) |length, index| try file.writeStreamingAll(io, owner.buffer.bytes()[index * 128 ..][0..length]);
}

fn readExact(io: std.Io, file: std.Io.File, destination: []u8) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const amount = file.readStreaming(io, &.{destination[offset..]}) catch |err| switch (err) {
            error.EndOfStream => return error.TruncatedCredentialFrame,
            else => return err,
        };
        if (amount == 0) return error.TruncatedCredentialFrame;
        offset += amount;
    }
}

pub fn inspect(io: std.Io, file: std.Io.File) !void {
    if (builtin.os.tag == .windows) {
        if (Win.GetFileType(file.handle) != 3) return error.RestrictedCredentialStreamRequired;
    } else if (builtin.os.tag == .linux) {
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/proc/self/fd/{d}", .{file.handle});
        var target: [256]u8 = undefined;
        const length = try std.Io.Dir.cwd().readLink(io, path, &target);
        if (!std.mem.startsWith(u8, target[0..length], "pipe:[") and !std.mem.startsWith(u8, target[0..length], "socket:[")) return error.RestrictedCredentialStreamRequired;
    } else return error.UnsupportedCredentialInput;
}

const Win = struct {
    extern "kernel32" fn GetFileType(std.os.windows.HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn CreatePipe(*std.os.windows.HANDLE, *std.os.windows.HANDLE, ?*anyopaque, u32) callconv(.winapi) i32;
};

/// Offline synthetic child probe, never constructs a network transport.
pub fn main(init: std.process.Init) !void {
    try rejectLegacy(init.environ_map);
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    const executable = args.next() orelse return error.MissingExecutable;
    const mode = args.next() orelse "";
    if (std.mem.eql(u8, mode, "--exit-early")) return;
    const observation = std.mem.eql(u8, mode, "--observation") or std.mem.eql(u8, mode, "--windows-demo-readonly") or std.mem.eql(u8, mode, "--prepare-only") or std.mem.indexOf(u8, executable, "private-smoke") != null;
    if (std.mem.eql(u8, mode, "--no-input")) {
        inspect(init.io, std.Io.File.stdin()) catch {
            var bytes: [64]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &bytes);
            try stdout.interface.writeAll("uncredentialed_role=isolated\n");
            try stdout.interface.flush();
            return;
        };
        return error.UnexpectedCredentialStream;
    }
    var owner = try read(init.io, std.Io.File.stdin(), if (observation) .observation else .execution, account);
    defer owner.deinit();
    if (std.mem.eql(u8, mode, "--forward-early-exit")) {
        var child = try std.process.spawn(init.io, .{ .argv = &.{ executable, "--exit-early" }, .stdin = .pipe, .stdout = .inherit, .stderr = .inherit, .environ_map = init.environ_map });
        defer {
            if (child.stdin) |input| input.close(init.io);
            child.kill(init.io);
        }
        _ = try child.wait(init.io);
        try forward(init.io, child.stdin orelse return error.CredentialPipeFailed, &owner, .execution, account);
        return error.ExpectedCredentialForwardFailure;
    }
    if (std.mem.eql(u8, mode, "--forward")) {
        for (0..3) |_| {
            var isolated = try std.process.spawn(init.io, .{ .argv = &.{ executable, "--no-input" }, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit, .environ_map = init.environ_map });
            defer isolated.kill(init.io);
            const term = try isolated.wait(init.io);
            if (term != .exited or term.exited != 0) return error.UncredentialedRoleFailed;
        }
        var child = try std.process.spawn(init.io, .{ .argv = &.{executable}, .stdin = .pipe, .stdout = .inherit, .stderr = .inherit, .environ_map = init.environ_map });
        defer child.kill(init.io);
        const input = child.stdin orelse return error.CredentialPipeFailed;
        try forward(init.io, input, &owner, .execution, account);
        input.close(init.io);
        child.stdin = null;
        owner.deinit();
        const result = try child.wait(init.io);
        if (result != .exited or result.exited != 0) return error.CredentialChildFailed;
        return;
    }
    var headers = try auth.headers(&owner, "2026-10-18T00:00:00.000Z", "GET", "/api/v5/account/config", "");
    defer headers.clear();
    var output: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output);
    try stdout.interface.writeAll("credential_input=accepted network=false\n");
    try stdout.interface.flush();
}

test "Demo restricted credential frame imports directly into protected owner" {
    var original = try auth.Credentials.init("synthetic-key", "synthetic-secret", "synthetic-pass");
    defer original.deinit();
    var descriptors: [2]std.Io.File = undefined;
    if (builtin.os.tag == .windows) {
        var reader: std.os.windows.HANDLE = undefined;
        var writer: std.os.windows.HANDLE = undefined;
        if (Win.CreatePipe(&reader, &writer, null, 0) == 0) return error.PipeFailed;
        descriptors = .{ .{ .handle = reader, .flags = .{ .nonblocking = false } }, .{ .handle = writer, .flags = .{ .nonblocking = false } } };
    } else {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.os.linux.errno(std.os.linux.pipe(&fds)) != .SUCCESS) return error.PipeFailed;
        descriptors = .{ .{ .handle = fds[0], .flags = .{ .nonblocking = false } }, .{ .handle = fds[1], .flags = .{ .nonblocking = false } } };
    }
    defer descriptors[0].close(std.testing.io);
    try forward(std.testing.io, descriptors[1], &original, .execution, account);
    descriptors[1].close(std.testing.io);
    var owner = try read(std.testing.io, descriptors[0], .execution, account);
    defer owner.deinit();
    try std.testing.expect(owner.sealed);
    try std.testing.expect(owner.protection().locked);
}
