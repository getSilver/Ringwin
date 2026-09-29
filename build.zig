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
    exe.stack_size = 64 * 1024 * 1024;
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

    const windows_durable = b.addRunArtifact(exe);
    windows_durable.addArg("--windows-durable-store-test");
    const windows_durable_step = b.step("windows-durable", "Run the Windows DurableStore verification adapter");
    windows_durable_step.dependOn(&windows_durable.step);

    const windows_credential = b.addRunArtifact(exe);
    windows_credential.addArg("--windows-credential-store-test");
    const windows_credential_step = b.step("windows-credential", "Run the Windows CredentialStore verification adapter");
    windows_credential_step.dependOn(&windows_credential.step);

    const windows_chain = b.addRunArtifact(exe);
    windows_chain.addArg("--windows-chain-test");
    const windows_chain_step = b.step("windows-chain", "Run the Windows verification process chain");
    windows_chain_step.dependOn(&windows_chain.step);

    const windows_demo = b.addExecutable(.{
        .name = "ringwin-windows-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/windows_demo_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    windows_demo.stack_size = 64 * 1024 * 1024;
    windows_demo.root_module.addCSourceFile(.{ .file = b.path("src/okx_curl_shim.c") });
    windows_demo.root_module.addIncludePath(b.path(".scratch/build/bootstrap/curl-source/curl-8.21.0/include"));
    windows_demo.root_module.addLibraryPath(b.path(".scratch/build/libcurl-8.21.0-windows-x86_64-schannel/lib"));
    windows_demo.root_module.link_libc = true;
    for ([_][]const u8{ "curl", "ws2_32", "crypt32", "secur32", "advapi32", "bcrypt", "wldap32", "normaliz", "iphlpapi" }) |library|
        windows_demo.root_module.linkSystemLibrary(library, .{});
    const windows_demo_step = b.step("windows-demo-bin", "Build the credential-gated Windows OKX Demo transport binary");
    const install_windows_demo = b.addInstallArtifact(windows_demo, .{});
    windows_demo_step.dependOn(&install_windows_demo.step);
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
