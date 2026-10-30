//! Internal Web candidate adapter. Reuses HostSupervisor; never constructs a Gateway.
const std = @import("std");
const builtin = @import("builtin");
const lifecycle = @import("strategy_host_lifecycle.zig");

extern "kernel32" fn GetProcessId(std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;

const Request = struct {
    python: []const u8,
    host: []const u8,
    generation: u64,
    shard: u32,
    barrier: u64,
    batches: []const []const u8,
    binding: struct {
        strategy_identity: []const u8,
        definition_identity: []const u8,
        decision_domain: []const u8,
        config_version: u64,
        config_sha256: []const u8,
        package_manifest_sha256: []const u8,
    },
    manifest: struct {
        compatibility: struct {
            host_build: []const u8,
            schema_registry: []const u8,
            python_abi: u32,
            host_protocol: u16,
        },
        state_schema: struct { identity: []const u8, version: u32 },
        limits: struct { max_callback_ns: u64, max_warmup_ns: u64 },
    },
};

fn now(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn hexIdentity(value: []const u8) !u128 {
    if (value.len != 32) return error.InvalidIdentity;
    const result = try std.fmt.parseInt(u128, value, 16);
    if (result == 0) return error.InvalidIdentity;
    return result;
}

fn awaitStop(io: std.Io) !void {
    var stop: [1]u8 = undefined;
    const buffers = [_][]u8{&stop};
    _ = try std.Io.File.stdin().readStreaming(io, &buffers);
}

fn awaitHostExit(io: std.Io, stdout: std.Io.File) !void {
    var unexpected: [1]u8 = undefined;
    const buffers = [_][]u8{&unexpected};
    if (try stdout.readStreaming(io, &buffers) != 0) return error.UnexpectedCandidateOutput;
}

pub fn run(init: std.process.Init, request_path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, request_path, init.gpa, .limited(256 * 1024));
    defer init.gpa.free(data);
    const parsed = try std.json.parseFromSlice(Request, init.gpa, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const request = parsed.value;
    var output_buffer: [512]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    var plan = lifecycle.developmentPlan(request.shard, request.generation, request.manifest.compatibility.python_abi);
    plan.decision_domain = try hexIdentity(request.binding.decision_domain);
    plan.compatibility.host_build = try hexIdentity(request.manifest.compatibility.host_build);
    plan.compatibility.schema_registry = try hexIdentity(request.manifest.compatibility.schema_registry);
    plan.compatibility.protocol = request.manifest.compatibility.host_protocol;
    _ = try std.fmt.hexToBytes(&plan.compatibility.strategy_manifest, request.binding.package_manifest_sha256);
    _ = try std.fmt.hexToBytes(&plan.compatibility.checkpoint_manifest, request.binding.config_sha256);
    plan.input_capacity = 1_048_576;
    plan.output_capacity = 262_144;
    const started = now(init.io);
    var host = try lifecycle.ManagedHost.start(init, request.python, request.host, plan, "candidate", &.{request_path});
    defer host.deinit(init.io);
    try host.sendPlan(init.io);
    if (try host.receive(init.io, now(init.io)) != .accepted) return error.CandidateHandshakeFailed;
    var frame: [72]u8 = undefined;
    try output.interface.writeAll("{\"phase\":\"initialize\"}\n");
    try output.interface.flush();
    const initialization_started = now(init.io);
    // Empty state is explicit initialization of a new identity, never recovery.
    try host.beginRecovery(init.io, request.barrier, &.{}, &frame);
    if (try host.receive(init.io, now(init.io)) != .accepted or host.supervisor.state != .recovering)
        return error.CandidateInitializationFailed;
    if (now(init.io) - initialization_started > request.manifest.limits.max_callback_ns) return error.CallbackBudgetExhausted;
    for (request.batches) |encoded| {
        if (encoded.len > 2 * plan.input_capacity or encoded.len < 256) return error.InvalidCandidateBatch;
        const batch = try init.gpa.alloc(u8, encoded.len / 2);
        defer init.gpa.free(batch);
        _ = try std.fmt.hexToBytes(batch, encoded);
        std.mem.writeInt(u128, batch[16..32], plan.compatibility.schema_registry, .little);
        std.mem.writeInt(u128, batch[32..48], plan.decision_domain, .little);
        std.mem.writeInt(u64, batch[48..56], plan.session.fencing, .little);
        std.mem.writeInt(u32, batch[56..60], plan.session.shard, .little);
        std.mem.writeInt(u64, batch[64..72], plan.session.generation, .little);
        std.mem.writeInt(u64, batch[72..80], host.next_input_batch, .little);
        const callback_started = now(init.io);
        try output.interface.writeAll("{\"phase\":\"callback\"}\n");
        try output.interface.flush();
        std.mem.writeInt(i64, batch[96..104], callback_started, .little);
        var crc = std.hash.crc.Crc32Iscsi.init();
        crc.update(batch[0..124]);
        crc.update(batch[128..]);
        std.mem.writeInt(u32, batch[124..128], crc.final(), .little);
        if (std.mem.readInt(u64, batch[80..88], .little) != (host.last_input_cursor orelse 0) + 1 or
            std.mem.readInt(u32, batch[104..108], .little) > 1) return error.InvalidCandidateCoverage;
        try host.sendInput(init.io, batch, callback_started);
        if (try host.receive(init.io, now(init.io)) != .accepted or host.supervisor.state != .recovering)
            return error.CandidateCallbackFailed;
        if (now(init.io) - callback_started > request.manifest.limits.max_callback_ns) return error.CallbackBudgetExhausted;
    }
    const validation_started = now(init.io);
    try output.interface.writeAll("{\"phase\":\"validate\"}\n");
    try output.interface.flush();
    if (try host.receive(init.io, validation_started) != .accepted or host.supervisor.state != .recovered)
        return error.CandidateNotReady;
    if (now(init.io) - validation_started > request.manifest.limits.max_callback_ns) return error.CallbackBudgetExhausted;
    if (now(init.io) - started > request.manifest.limits.max_warmup_ns) return error.WarmupBudgetExhausted;
    const ready = host.supervisor.last_recovered orelse return error.CandidateNotReady;
    if (ready.strategy_identity != try hexIdentity(request.binding.strategy_identity) or
        ready.config_version != request.binding.config_version or ready.cursor != request.barrier or
        ready.state_schema_identity != try hexIdentity(request.manifest.state_schema.identity) or
        ready.state_schema_version != request.manifest.state_schema.version) return error.CandidateIdentityMismatch;
    const digest = std.fmt.bytesToHex(ready.state_digest, .lower);
    const host_pid: u64 = if (builtin.os.tag == .windows) GetProcessId(host.child.id.?) else @intCast(host.child.id.?);
    if (host_pid == 0) return error.InvalidHostProcessId;
    try output.interface.print("{{\"cursor\":{d},\"next_intent_sequence\":{d},\"host_generation\":{d},\"host_pid\":{d},\"state_digest\":\"{s}\",\"trading_authorized\":false}}\n", .{ ready.cursor, ready.next_intent_sequence, plan.session.generation, host_pid, digest });
    try output.interface.flush();
    const Event = union(enum) { stop: anyerror!void, exited: anyerror!void };
    var events: [2]Event = undefined;
    var select = std.Io.Select(Event).init(init.io, &events);
    defer select.cancelDiscard();
    // Canceling Child.wait destroys its ownership in the pinned Zig runtime.
    // Observe EOF without consuming the process handle needed for cleanup.
    try select.concurrent(.exited, awaitHostExit, .{ init.io, host.child.stdout.? });
    try select.concurrent(.stop, awaitStop, .{init.io});
    const event = try select.await();
    select.cancelDiscard();
    switch (event) {
        .exited => return error.CandidateHostExited,
        .stop => |result| try result,
    }
    if (host.child.id == null) return error.CandidateHostExited;
    try host.shutdown(init.io, now(init.io));
}
