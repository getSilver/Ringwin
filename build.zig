const std = @import("std");

const expected_zig_version = "0.17.0-dev.315+5b647b792";

pub fn build(b: *std.Build) void {
    requirePinnedZig(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ringwin",
        .root_module = main_module,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the deterministic acceptance fixture");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the offline Zig regression suite");
    test_step.dependOn(&run_tests.step);

    const core_wave = b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-File", "tools\\verify-core-wave.ps1" });
    const core_wave_step = b.step("core-wave", "Run the fail-fast offline core acceptance wave");
    core_wave_step.dependOn(&core_wave.step);

    const demo_live = b.option(bool, "demo-live", "Run the Demo wave with explicitly authorized order execution") orelse false;
    const demo_wave = b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-File", "tools\\verify-okx-demo-wave.ps1" });
    if (demo_live) demo_wave.addArg("-DemoLive");
    const demo_wave_step = b.step("demo-wave", "Run the explicit OKX Demo acceptance wave");
    demo_wave_step.dependOn(&demo_wave.step);
}

fn requirePinnedZig(b: *std.Build) void {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "zig", "version" },
    }) catch |err| std.debug.panic("could not run `zig version`: {s}", .{@errorName(err)});
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    const version = std.mem.trim(u8, result.stdout, " \t\r\n");
    switch (result.term) {
        .exited => |code| if (code == 0 and std.mem.eql(u8, version, expected_zig_version)) return,
        else => {},
    }
    std.debug.panic("expected Zig {s}, got {s}", .{ expected_zig_version, version });
}
