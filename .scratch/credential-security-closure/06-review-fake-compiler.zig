const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var one: [1]u8 = undefined;
    const n = std.Io.File.stdin().readStreaming(init.io, &.{&one}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    if (n != 0) return error.CompilerInheritedCredentialBytes;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse "";
    if (std.mem.eql(u8, command, "fail")) std.process.exit(41);
    var bytes: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &bytes);
    if (std.mem.eql(u8, command, "version")) {
        try stdout.interface.writeAll("0.17.0-dev.315+5b647b792\n");
    } else {
        try stdout.interface.writeAll("bounded_verify_reached_fmt=true compiler_stdin_empty=true\n");
    }
    try stdout.interface.flush();
    if (std.mem.eql(u8, command, "fmt")) std.process.exit(73);
}
