const std = @import("std");
extern "kernel32" fn FlushFileBuffers(std.os.windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn SetLastError(u32) callconv(.winapi) void;

pub fn main(init: std.process.Init) !void {
    const directory = "D:/github/Ringwin-core-continuous-capacity/.scratch/core-continuous-capacity/10-file-semantics-nativeprobe/data";
    try std.Io.Dir.createDirAbsolute(init.io, directory, .default_dir);
    const dir = try std.Io.Dir.openDirAbsolute(init.io, directory, .{});
    defer dir.close(init.io);
    for ([_][]const u8{ "old", "new" }, 0..) |body, index| {
        var file = try dir.createFile(init.io, "publish.tmp", .{ .truncate = true });
        try file.writeStreamingAll(init.io, body);
        try file.sync(init.io);
        SetLastError(0);
        const file_flush = FlushFileBuffers(file.handle);
        const file_error = GetLastError();
        file.close(init.io);
        try dir.rename("publish.tmp", dir, "published.bin", init.io);
        SetLastError(0);
        const dir_flush = FlushFileBuffers(dir.handle);
        const dir_error = GetLastError();
        std.debug.print("{{\"generation\":{d},\"file_sync\":\"ok\",\"file_flush_result\":{d},\"file_flush_error\":{d},\"rename_replace\":\"ok\",\"directory_flush_result\":{d},\"directory_flush_error\":{d}}}\n", .{ index, file_flush, file_error, dir_flush, dir_error });
    }
    const file = try dir.openFile(init.io, "published.bin", .{});
    defer file.close(init.io);
    var bytes: [3]u8 = undefined;
    const length = try file.readStreaming(init.io, &.{&bytes});
    if (length != 3 or !std.mem.eql(u8, &bytes, "new")) return error.ReopenMismatch;
    std.debug.print("{{\"reopen_latest_body\":\"ok\",\"scope\":\"ordinary_functional_only\"}}\n", .{});
}
