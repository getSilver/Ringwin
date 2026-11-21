//! Provision an isolated Writer for formal Linux role acceptance.
const std = @import("std");
const durable = @import("../../../persistence/durable_store.zig");
const Owner = @import("../../../runtime/demo/demo_authority.zig").Owner;
const fixture = @import("../core/multi_account_authority_acceptance.zig");

pub fn main(init: std.process.Init) !void {
    const Fixture = struct {
        failure: ?anyerror = null,

        fn run(self: *@This(), process: std.process.Init) void {
            provision(process) catch |err| {
                self.failure = err;
            };
        }
    };
    var fixture_run: Fixture = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 * 1024 }, Fixture.run, .{ &fixture_run, init });
    thread.join();
    if (fixture_run.failure) |failure| return failure;
}

fn provision(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingStateDirectory;
    if (args.next() != null or !std.fs.path.isAbsolute(path)) return error.InvalidStateDirectory;
    const store = try init.gpa.create(durable.LinuxFileAdapter);
    defer init.gpa.destroy(store);
    store.* = .{ .dir = undefined };
    try store.initLinux(init.io, path);
    defer store.close(init.io);
    const owner = try init.gpa.create(Owner);
    defer init.gpa.destroy(owner);
    try Owner.bootstrapInto(owner, store.interface(), init.io, .{ .domain = .decision_log, .id = 91 });
    try fixture.initializePythonOwner(owner);

    var text: [192]u8 = undefined;
    const config = try std.fmt.bufPrint(&text, "{{\"decision_stream\":91,\"deployment_digest\":\"{s}\"}}\n", .{std.fmt.bytesToHex(owner.deployment_anchor.?, .lower)});
    const file = try store.dir.createFile(init.io, "engine.json", .{ .exclusive = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, config);
}
