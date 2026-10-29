const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var one: [1]u8 = undefined;
    const n = std.Io.File.stdin().readStreaming(init.io, &.{&one}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    if (n != 0) return error.CompilerInheritedCredentialBytes;
    var bytes: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &bytes);
    try stdout.interface.writeAll("build_stdin_empty=true\n");
    try stdout.interface.flush();
}
