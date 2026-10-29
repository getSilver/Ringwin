//! Standalone synthetic public-API probe, executed with child-only memlock=0.
const std = @import("std");
const aead = @import("aead");

pub fn main() !void {
    if ((try std.posix.getrlimit(.MEMLOCK)).cur != 0) return error.ExpectedZeroMemlockLimit;
    const key: [32]u8 = @splat(0x23);
    const nonce: [24]u8 = @splat(0x42);
    var ciphertext: [4]u8 = @splat(0x75);
    var tag: [16]u8 = @splat(0x73);
    aead.encrypt(&ciphertext, &tag, "test", "metadata", nonce, &key) catch |err| {
        if (err != error.MemoryLockFailed) return err;
        if (!std.mem.allEqual(u8, &ciphertext, 0) or !std.mem.allEqual(u8, &tag, 0)) return error.CallerOutputNotErased;
        std.debug.print("native memlock=0 refused before secret scratch; caller ciphertext/tag cleared\n", .{});
        return;
    };
    return error.ExpectedNativeLockFailure;
}
