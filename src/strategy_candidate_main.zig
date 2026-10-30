//! Internal, signed runtime component invoked exclusively by the Web loader.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const request = args.next() orelse return error.MissingCandidateRequest;
    if (args.next() != null) return error.UnknownArgument;
    try @import("strategy/strategy_candidate.zig").run(init, request);
}
