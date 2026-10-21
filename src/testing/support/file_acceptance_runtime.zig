//! Offline file fixtures use the same 64 MiB stack budget on Windows and Linux.
//! Legacy WSL1 cannot raise its 8 MiB main-thread hard limit using --stack.
const std = @import("std");

/// Observe regular-file length without statx, which legacy WSL1 lacks.
/// This opens a separate handle and cannot change the Store's file position.
pub fn fileBytes(dir: std.Io.Dir, io: std.Io, name: []const u8) !u64 {
    if (@import("builtin").os.tag != .linux) return (try dir.statFile(io, name, .{ .follow_symlinks = false })).size;
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const result = std.os.linux.lseek(file.handle, 0, std.posix.SEEK.END);
    return switch (std.os.linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.FileSizeObservationFailed,
    };
}

pub fn run(comptime entry: fn (std.process.Init, []const u8, []const u8) anyerror!void, init: std.process.Init, mode: []const u8, path: []const u8) !void {
    if (@import("builtin").os.tag != .linux) return entry(init, mode, path);
    const Context = struct {
        init: std.process.Init,
        mode: []const u8,
        path: []const u8,
        result: anyerror!void = {},

        fn invoke(self: *@This()) void {
            self.result = entry(self.init, self.mode, self.path);
        }
    };
    var context: Context = .{ .init = init, .mode = mode, .path = path };
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Context.invoke, .{&context});
    thread.join();
    return context.result;
}
