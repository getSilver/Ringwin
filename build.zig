const std = @import("std");

const expected_zig_version = "0.17.0-dev.315+5b647b792";
const native_registry = @import("src/strategy/native_registry.zig");
const native_manifest = @import("src/strategy/native_manifest.zig");

pub fn build(b: *std.Build) void {
    requirePinnedZig(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    native_registry.validate() catch |err| std.debug.panic("native strategy build rejected: {s}", .{@errorName(err)});
    const native_json = std.json.Stringify.valueAlloc(b.allocator, .{
        .format_version = 1,
        .runtime = "native_static",
        .zig_version = expected_zig_version,
        .target = target.result.zigTriple(b.allocator) catch @panic("out of memory"),
        .optimize = @tagName(optimize),
        .binary_path = if (target.result.os.tag == .windows) "bin/ringwin.exe" else "bin/ringwin",
        .definitions = native_manifest.definitions,
    }, .{ .whitespace = .indent_2 }) catch @panic("out of memory");
    const native_files = b.addWriteFiles();
    const native_json_path = native_files.add("native-strategies.json", native_json);
    b.getInstallStep().dependOn(&b.addInstallFile(native_json_path, "share/ringwin/native-strategies.json").step);
    for ([_][]const u8{ "native_observer_config.json", "native_observer_state.json" }) |file| {
        b.getInstallStep().dependOn(&b.addInstallFile(b.path(b.fmt("src/strategy/{s}", .{file})), b.fmt("share/ringwin/contracts/{s}", .{file})).step);
    }

    const native_acceptance = b.addExecutable(.{
        .name = "native-contract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const native_options = b.addOptions();
    native_options.addOption(usize, "index", 139);
    native_acceptance.root_module.addOptions("entry_options", native_options);
    const native_step = b.step("native-contract", "Verify native static registration and the minimal definition offline");
    native_step.dependOn(&b.addRunArtifact(native_acceptance).step);
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

    const candidate = b.addExecutable(.{
        .name = "ringwin-strategy-candidate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/strategy_candidate_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    candidate.stack_size = 64 * 1024 * 1024;
    b.installArtifact(candidate);

    const authority_probe = b.addExecutable(.{
        .name = "ringwin-strategy-authority-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/entry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const authority_options = b.addOptions();
    authority_options.addOption(usize, "index", 140);
    authority_probe.root_module.addOptions("entry_options", authority_options);
    authority_probe.stack_size = 512 * 1024 * 1024;
    const authority_step = b.step("strategy-authority-probe", "Build the offline package activation acceptance node");
    authority_step.dependOn(&b.addInstallArtifact(authority_probe, .{}).step);

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
    // Existing core state copies exceed the platform's default test stack.
    tests.stack_size = 512 * 1024 * 1024;
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

    const windows_okx_offline = b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-File", "tools\\verify-windows-okx-chain.ps1", "-Mode", "Offline" });
    const windows_okx_offline_step = b.step("windows-okx-offline", "Run fail-fast Windows OKX offline acceptance and write a scoped report");
    windows_okx_offline_step.dependOn(&windows_okx_offline.step);

    const windows_okx_readonly = b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-File", "tools\\verify-windows-okx-chain.ps1", "-Mode", "ReadOnly" });
    const windows_okx_readonly_step = b.step("windows-okx-readonly", "Run Windows OKX Demo read-only acceptance and write a scoped report");
    windows_okx_readonly_step.dependOn(&windows_okx_readonly.step);

    const windows_live_authorized = b.option(bool, "windows-demo-live-authorized", "Confirm fresh, bounded SystemOwner authorization for Windows OKX Demo orders") orelse false;
    const windows_okx_live_step = b.step("windows-okx-live", "Run separately authorized Windows OKX Demo order acceptance");
    if (windows_live_authorized) {
        const windows_okx_live = b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-File", "tools\\verify-windows-okx-chain.ps1", "-Mode", "DemoLive", "-SystemOwnerAuthorized" });
        windows_okx_live_step.dependOn(&windows_okx_live.step);
    } else {
        const refuse_live = b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-Command", "throw 'Windows Demo live requires fresh bounded SystemOwner authorization and -Dwindows-demo-live-authorized=true'" });
        windows_okx_live_step.dependOn(&refuse_live.step);
    }

    const windows_demo = b.addExecutable(.{
        .name = "ringwin-windows-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/windows_demo_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    windows_demo.stack_size = 64 * 1024 * 1024;
    windows_demo.root_module.addCSourceFile(.{ .file = b.path("src/adapters/okx/okx_curl_shim.c") });
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
