const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("strategy_host_ipc.zig");
const lifecycle = @import("strategy_host_lifecycle.zig");

const host_count = 4;
const strategies_per_host = 25;
const default_batches_per_scenario = 1_400;
const events_per_batch = 10;
const bucket_ns = 50_000;
const bucket_count = 2_000;
const tail_bucket_ns = 1_000_000;
const tail_count = 1_000;

const Scenario = enum { normal, gc_exception, slow, crash, recovery };

const Histogram = struct {
    buckets: [bucket_count]u64 = @splat(0),
    tail: [tail_count]u64 = @splat(0),
    samples: u64 = 0,
    maximum_ns: u64 = 0,

    fn record(self: *Histogram, latency_ns: u64, count: u32) void {
        if (count == 0) return;
        const primary_range = bucket_ns * bucket_count;
        if (latency_ns < primary_range) {
            self.buckets[@intCast(latency_ns / bucket_ns)] += count;
        } else {
            const index = @min((latency_ns - primary_range) / tail_bucket_ns, tail_count - 1);
            self.tail[@intCast(index)] += count;
        }
        self.samples += count;
        self.maximum_ns = @max(self.maximum_ns, latency_ns);
    }

    fn percentile(self: *const Histogram, numerator: u64, denominator: u64) u64 {
        const target = @max(@as(u64, 1), (self.samples * numerator + denominator - 1) / denominator);
        var seen: u64 = 0;
        for (self.buckets, 0..) |count, index| {
            seen += count;
            if (seen >= target) return (index + 1) * bucket_ns;
        }
        for (self.tail, 0..) |count, index| {
            seen += count;
            if (seen >= target) return bucket_count * bucket_ns + (index + 1) * tail_bucket_ns;
        }
        return self.maximum_ns;
    }
};

const Result = struct {
    all: Histogram = .{},
    healthy: Histogram = .{},
    elapsed_ns: u64 = 0,
    input_full: u64 = 0,
    rejected: u64 = 0,
    stale: u64 = 0,
    intents: u64 = 0,
    queue_hwm: u32 = 1,
};

fn runScenario(
    init: std.process.Init,
    bridge: []const u8,
    python: []const u8,
    script: []const u8,
    scenario: Scenario,
    batch_total: u32,
) !Result {
    const python_abi = try lifecycle.discoverPythonAbi(init, python);
    var plans: [host_count]lifecycle.Plan = undefined;
    var hosts: [host_count]?lifecycle.ManagedHost = @splat(null);
    defer for (&hosts) |*host| if (host.*) |*running| running.deinit(init.io);

    var batches_text: [24]u8 = undefined;
    const batch_count = try std.fmt.bufPrint(&batches_text, "{d}", .{batch_total});
    var strategies_text: [24]u8 = undefined;
    const strategy_count = try std.fmt.bufPrint(&strategies_text, "{d}", .{strategies_per_host});
    for (&hosts, &plans, 0..) |*host, *plan, index| {
        plan.* = lifecycle.developmentPlan(@intCast(index), 1, python_abi);
        plan.input_capacity = 1024;
        const scenario_name = if (scenario == .crash) "normal" else @tagName(scenario);
        const common = [_][]const u8{
            "--bridge",
            bridge,
            "--benchmark-strategies",
            strategy_count,
            "--benchmark-batches",
            batch_count,
            "--benchmark-scenario",
            scenario_name,
        };
        var extra: [9][]const u8 = undefined;
        @memcpy(extra[0..common.len], &common);
        var extra_len = common.len;
        if (index == 0 and scenario != .normal and scenario != .crash) {
            extra[extra_len] = "--benchmark-perturbed";
            extra_len += 1;
        }
        host.* = try lifecycle.ManagedHost.start(
            init,
            python,
            script,
            plan.*,
            if (index == 0 and scenario == .crash) "crash" else "benchmark",
            if (index == 0 and scenario == .crash) &.{} else extra[0..extra_len],
        );
    }
    for (&hosts) |*host| try host.*.?.sendPlan(init.io);
    for (&hosts, 0..) |*host, index| {
        const running = &host.*.?;
        try expectLifecycle(.accepted, try running.receive(init.io, monotonicNow(init.io)));
        if (!(scenario == .crash and index == 0))
            try expectLifecycle(.accepted, try running.receive(init.io, monotonicNow(init.io)));
    }
    if (scenario == .crash) {
        const term = try hosts[0].?.child.wait(init.io);
        hosts[0].?.supervisor.processExited(switch (term) {
            .exited => |code| code == 0,
            else => false,
        });
        if (hosts[0].?.supervisor.state != .failed) return error.CrashWasNotIsolated;
    }

    var result: Result = .{};
    var batch_storage: [host_count][128 + 64 * events_per_batch]u8 = undefined;
    var output_storage: [host_count][512]u8 = undefined;
    const started = monotonicNow(init.io);
    var batch_index: u64 = 1;
    while (batch_index <= batch_total) : (batch_index += 1) {
        var published_at: [host_count]i64 = @splat(0);
        var pending: [host_count]bool = @splat(true);
        if (scenario == .crash) pending[0] = false;
        for (&hosts, &plans, 0..) |*host, *plan, index| {
            if (!pending[index]) continue;
            published_at[index] = monotonicNow(init.io);
            const batch = makeBatch(
                &batch_storage[index],
                plan.*,
                batch_index,
                published_at[index],
            );
            var input = try host.*.?.input_mapping.ring(.input, plan.session);
            const status = input.tryPublishMany(&.{batch});
            if (status == .full) result.input_full += 1;
            try expectIpc(.ok, status);
        }

        var remaining: usize = if (scenario == .crash) host_count - 1 else host_count;
        const deadline = monotonicNow(init.io) + 5 * std.time.ns_per_s;
        while (remaining != 0) {
            for (&hosts, &plans, 0..) |*host, *plan, index| {
                if (!pending[index]) continue;
                var output = try host.*.?.output_mapping.ring(.output, plan.session);
                const status = output.tryRead(&output_storage[index]);
                if (status == .empty) continue;
                if (status != .ok) {
                    result.rejected += 1;
                    return error.OutputRejected;
                }
                const received = monotonicNow(init.io);
                const frame_len = get(u32, &output_storage[index], 12);
                if (frame_len < 148 or frame_len > output_storage[index].len)
                    return error.InvalidBenchmarkFrame;
                const callbacks = get(u32, &output_storage[index], 128);
                const intents = get(u32, &output_storage[index], 136);
                const latency: u64 = @intCast(received - published_at[index]);
                result.all.record(latency, callbacks);
                if (index != 0 or scenario == .normal) result.healthy.record(latency, callbacks);
                result.intents += intents;
                pending[index] = false;
                remaining -= 1;
            }
            if (remaining != 0 and monotonicNow(init.io) > deadline) return error.HostOutputTimeout;
            if (remaining != 0) try std.Io.Clock.Duration.sleep(
                .{ .clock = .awake, .raw = .fromMilliseconds(1) },
                init.io,
            );
        }
    }
    result.elapsed_ns = @intCast(monotonicNow(init.io) - started);
    for (&hosts, 0..) |*host, index| {
        if (scenario == .crash and index == 0) continue;
        try host.*.?.shutdown(init.io, monotonicNow(init.io));
    }
    if (result.all.samples < 1_000_000 or
        result.all.percentile(99, 100) > 50 * std.time.ns_per_ms or
        result.all.percentile(999, 1000) > 100 * std.time.ns_per_ms or
        result.intents != 0 or result.stale != 0 or result.rejected != 0)
        return error.CapacityContractFailed;
    return result;
}

fn makeBatch(
    destination: *[128 + 64 * events_per_batch]u8,
    plan: lifecycle.Plan,
    sequence: u64,
    now: i64,
) []const u8 {
    @memset(destination, 0);
    @memcpy(destination[0..4], "QSHB");
    put(u16, destination, 4, 1);
    put(u16, destination, 6, 128);
    put(u32, destination, 12, destination.len);
    put(u128, destination, 16, plan.compatibility.schema_registry);
    put(u128, destination, 32, plan.decision_domain);
    put(u64, destination, 48, plan.session.fencing);
    put(u32, destination, 56, plan.session.shard);
    put(u64, destination, 64, plan.session.generation);
    put(u64, destination, 72, sequence);
    put(u64, destination, 80, sequence);
    put(u64, destination, 88, sequence * events_per_batch);
    put(i64, destination, 96, now);
    put(u64, destination, 80, (sequence - 1) * events_per_batch + 1);
    put(u32, destination, 104, events_per_batch);
    put(u32, destination, 108, 64 * events_per_batch);
    for (0..events_per_batch) |event_index| {
        const offset = 128 + 64 * event_index;
        put(u32, destination, offset, 64);
        put(u16, destination, offset + 8, 4);
        put(u16, destination, offset + 10, 1);
        put(u64, destination, offset + 16, (sequence - 1) * events_per_batch + event_index + 1);
        put(i64, destination, offset + 24, now);
        put(i64, destination, offset + 32, now);
        put(i64, destination, offset + 40, now);
        put(i64, destination, offset + 48, now);
    }
    put(u32, destination, 124, wireCrc(destination));
    return destination;
}

fn printResult(writer: anytype, scenario: Scenario, result: Result) !void {
    const throughput = @as(u64, @intFromFloat(
        @as(f64, @floatFromInt(result.all.samples)) * @as(f64, std.time.ns_per_s) /
            @as(f64, @floatFromInt(result.elapsed_ns)),
    ));
    try writer.print(
        "scenario={s} samples={d} p50_us={d} p99_us={d} p99_9_us={d} max_us={d} throughput_decisions_s={d} healthy_p99_us={d} healthy_p99_9_us={d} queue_hwm={d} input_full={d} rejected={d} stale={d} recovery_intents={d}\n",
        .{
            @tagName(scenario),
            result.all.samples,
            result.all.percentile(50, 100) / std.time.ns_per_us,
            result.all.percentile(99, 100) / std.time.ns_per_us,
            result.all.percentile(999, 1000) / std.time.ns_per_us,
            result.all.maximum_ns / std.time.ns_per_us,
            throughput,
            result.healthy.percentile(99, 100) / std.time.ns_per_us,
            result.healthy.percentile(999, 1000) / std.time.ns_per_us,
            result.queue_hwm,
            result.input_full,
            result.rejected,
            result.stale,
            result.intents,
        },
    );
}

fn monotonicNow(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn wireCrc(bytes: []const u8) u32 {
    var crc = std.hash.crc.Crc32Iscsi.init();
    crc.update(bytes[0..124]);
    crc.update(bytes[128..]);
    return crc.final();
}

fn put(comptime T: type, destination: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, destination[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, source: []const u8, offset: usize) T {
    return std.mem.readInt(T, source[offset..][0..@sizeOf(T)], .little);
}

fn expectIpc(expected: ipc.QshStatusV1, actual: ipc.QshStatusV1) !void {
    if (expected != actual) return error.UnexpectedIpcStatus;
}

fn expectLifecycle(expected: lifecycle.Result, actual: lifecycle.Result) !void {
    if (expected != actual) return error.UnexpectedLifecycleResult;
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const bridge = args.next() orelse return error.MissingBridgePath;
    const python = args.next() orelse "python";
    const script = args.next() orelse "python/strategy_host.py";
    const selected_scenario = if (args.next()) |name|
        std.meta.stringToEnum(Scenario, name) orelse return error.UnknownScenario
    else
        null;
    const batch_total = if (args.next()) |text|
        try std.fmt.parseInt(u32, text, 10)
    else
        default_batches_per_scenario;
    if (batch_total == 0) return error.InvalidBatchCount;
    if (args.next() != null) return error.UnknownArgument;

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print(
        "python_strategy_host_capacity: zig={s} mode={s} os={s} hosts=4 strategies_per_host=25 samples_per_distribution>=1000000 latency=monotonic network=excluded\n",
        .{ builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.os.tag) },
    );
    try stdout.interface.flush();
    for ([_]Scenario{ .normal, .gc_exception, .slow, .crash, .recovery }) |scenario| {
        if (selected_scenario != null and selected_scenario.? != scenario) continue;
        try stdout.interface.print("scenario={s} state=running batches={d}\n", .{
            @tagName(scenario),
            batch_total,
        });
        try stdout.interface.flush();
        const result = try runScenario(init, bridge, python, script, scenario, batch_total);
        try printResult(&stdout.interface, scenario, result);
        try stdout.interface.flush();
    }
}
