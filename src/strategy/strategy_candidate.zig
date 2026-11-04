//! Internal Web candidate adapter. Reuses HostSupervisor; never constructs a Gateway.
const std = @import("std");
const builtin = @import("builtin");
const lifecycle = @import("strategy_host_lifecycle.zig");
const checkpoints = @import("strategy_checkpoint_store.zig");
const codec = @import("strategy_host_recovery.zig");
const durable = @import("../persistence/durable_store.zig");

extern "kernel32" fn GetProcessId(std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;

const Request = struct {
    strategy_manifest: []const u8,
    checkpoint_manifest: []const u8,
    python: []const u8,
    host: []const u8,
    generation: u64,
    shard: u32,
    fencing: u64,
    barrier: u64,
    batches: []const []const u8,
    checkpoint_directory: []const u8,
    recover: bool,
    checkpoint_cursor: u64,
    source_checkpoint_directory: ?[]const u8 = null,
    source_config_version: ?u64 = null,
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
        limits: struct { max_callback_ns: u64, max_warmup_ns: u64, max_private_state_bytes: usize },
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

fn awaitCommand(io: std.Io, storage: []u8) ![]const u8 {
    var header: [4]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &.{});
    reader.interface.readSliceAll(&header) catch |err| switch (err) {
        error.EndOfStream => return &.{},
        else => return err,
    };
    const len = std.mem.readInt(u32, &header, .little);
    if (len == 0 or len > storage.len) return error.InvalidRuntimeCommand;
    try reader.interface.readSliceAll(storage[0..len]);
    return storage[0..len];
}

fn awaitHostExit(io: std.Io, stdout: std.Io.File) !void {
    var unexpected: [1]u8 = undefined;
    const buffers = [_][]u8{&unexpected};
    if (try stdout.readStreaming(io, &buffers) != 0) return error.UnexpectedCandidateOutput;
}

const Instance = struct {
    adapter: *durable.LinuxFileAdapter,
    repository: checkpoints.Repository,
    expected: codec.Metadata,
    host: lifecycle.ManagedHost,
    ready: lifecycle.StrategyRecovered,
    storage: []u8,
    plan: lifecycle.Plan,

    fn initialize(init: std.process.Init, request: Request, child: std.process.Child) !Instance {
        const adapter = try init.gpa.create(durable.LinuxFileAdapter);
        errdefer init.gpa.destroy(adapter);
        adapter.* = .{ .dir = undefined };
        if (builtin.os.tag == .windows) {
            try adapter.initWindowsVerification(init.io, request.checkpoint_directory);
        } else {
            try adapter.initLinux(init.io, request.checkpoint_directory);
        }
        errdefer adapter.close(init.io);
        const repository = try checkpoints.Repository.init(adapter.interface(), 800, .{ 801, 802 });
        if (!request.recover or request.source_checkpoint_directory != null) try repository.initialize(init.io);
        var expected: codec.Metadata = .{
            .schema_registry = try hexIdentity(request.manifest.compatibility.schema_registry),
            .strategy_instance = try hexIdentity(request.binding.strategy_identity),
            .strategy_definition = try hexIdentity(request.binding.definition_identity),
            .state_schema = try hexIdentity(request.manifest.state_schema.identity),
            .state_schema_version = request.manifest.state_schema.version,
            .strategy_config_version = request.binding.config_version,
            .strategy_cursor = request.checkpoint_cursor,
            .next_intent_sequence = 1,
        };
        var checkpoint: []const u8 = &.{};
        const source_adapter = try init.gpa.create(durable.LinuxFileAdapter);
        defer init.gpa.destroy(source_adapter);
        source_adapter.* = .{ .dir = undefined };
        var source_open = false;
        defer if (source_open) source_adapter.close(init.io);
        if (request.recover) {
            const source_repository = if (request.source_checkpoint_directory) |directory| blk: {
                if (builtin.os.tag == .windows) try source_adapter.initWindowsVerification(init.io, directory) else try source_adapter.initLinux(init.io, directory);
                source_open = true;
                break :blk try checkpoints.Repository.init(source_adapter.interface(), 800, .{ 801, 802 });
            } else repository;
            const published = (try source_repository.latest(init.io)) orelse return error.NoPublishedCheckpoint;
            if (published.metadata.strategy_cursor < request.checkpoint_cursor or
                published.metadata.strategy_cursor > request.barrier) return error.CheckpointBarrierMismatch;
            expected.strategy_cursor = published.metadata.strategy_cursor;
            expected.next_intent_sequence = published.metadata.next_intent_sequence;
            var source_expected = expected;
            source_expected.strategy_config_version = request.source_config_version orelse expected.strategy_config_version;
            checkpoint = try source_repository.restore(init.io, source_expected);
            if (checkpoint.len > 192 + request.manifest.limits.max_private_state_bytes) return error.CheckpointTooLarge;
        }
        var output_buffer: [512]u8 = undefined;
        var output = std.Io.File.stdout().writer(init.io, &output_buffer);
        var plan = lifecycle.developmentPlan(request.shard, request.generation, request.manifest.compatibility.python_abi);
        if (request.fencing == 0) return error.InvalidFencingToken;
        plan.session.fencing = request.fencing;
        plan.decision_domain = try hexIdentity(request.binding.decision_domain);
        plan.compatibility.host_build = try hexIdentity(request.manifest.compatibility.host_build);
        plan.compatibility.schema_registry = try hexIdentity(request.manifest.compatibility.schema_registry);
        plan.compatibility.protocol = request.manifest.compatibility.host_protocol;
        _ = try std.fmt.hexToBytes(&plan.compatibility.strategy_manifest, request.strategy_manifest);
        _ = try std.fmt.hexToBytes(&plan.compatibility.checkpoint_manifest, request.checkpoint_manifest);
        plan.input_capacity = 1_048_576;
        plan.output_capacity = 262_144;
        // The package watchdog owns callback/warmup budgets and group termination.
        plan.hang_timeout_ns = (std.math.cast(i64, request.manifest.limits.max_callback_ns) orelse std.math.maxInt(i64)) +| plan.hang_timeout_ns;
        plan.startup_timeout_ns = (std.math.cast(i64, request.manifest.limits.max_warmup_ns) orelse std.math.maxInt(i64)) +| plan.startup_timeout_ns;
        const started = now(init.io);
        var host: lifecycle.ManagedHost = .{ .child = child, .supervisor = try lifecycle.HostSupervisor.init(plan, 0), .owns_child = false };
        try host.sendPlan(init.io);
        if (try host.receive(init.io, now(init.io)) != .accepted) return error.CandidateHandshakeFailed;
        const frame = try init.gpa.alloc(u8, 72 + checkpoint.len);
        defer init.gpa.free(frame);
        try output.interface.print("{{\"phase\":\"initialize\",\"cursor\":{d}}}\n", .{expected.strategy_cursor});
        try output.interface.flush();
        const initialization_started = now(init.io);
        try host.beginRecovery(init.io, request.barrier, checkpoint, frame);
        host.last_input_cursor = expected.strategy_cursor;
        if (try host.receive(init.io, now(init.io)) != .accepted or host.supervisor.state != .recovering)
            return error.CandidateInitializationFailed;
        if (now(init.io) - initialization_started > request.manifest.limits.max_callback_ns) return error.CallbackBudgetExhausted;
        for (request.batches) |encoded| {
            if (encoded.len > 2 * plan.input_capacity or encoded.len < 256) return error.InvalidCandidateBatch;
            const batch_storage = try init.gpa.alloc(u8, encoded.len / 2);
            defer init.gpa.free(batch_storage);
            _ = try std.fmt.hexToBytes(batch_storage, encoded);
            var batch = batch_storage;
            if (std.mem.readInt(u64, batch[88..96], .little) <= expected.strategy_cursor) continue;
            if (std.mem.readInt(u64, batch[80..88], .little) <= expected.strategy_cursor) {
                std.mem.writeInt(u64, batch[80..88], expected.strategy_cursor + 1, .little);
                if (std.mem.readInt(u32, batch[104..108], .little) == 1 and
                    batch.len >= 192 and std.mem.readInt(u64, batch[144..152], .little) <= expected.strategy_cursor)
                {
                    batch = batch_storage[0..128];
                    std.mem.writeInt(u32, batch[12..16], 128, .little);
                    std.mem.writeInt(u32, batch[104..108], 0, .little);
                    std.mem.writeInt(u32, batch[108..112], 0, .little);
                }
            }
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
            try output.interface.print("{{\"phase\":\"replay\",\"cursor\":{d}}}\n", .{host.last_input_cursor.?});
            try output.interface.flush();
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
        expected.strategy_cursor = ready.cursor;
        expected.next_intent_sequence = ready.next_intent_sequence;
        try output.interface.writeAll("{\"phase\":\"checkpoint\"}\n");
        try output.interface.flush();
        try host.requestCheckpoint(init.io, 1, expected);
        const storage = try init.gpa.alloc(u8, 64 + 8 + 192 + request.manifest.limits.max_private_state_bytes);
        errdefer init.gpa.free(storage);
        const container = try host.receiveCheckpoint(init.io, storage);
        const decoded = try codec.decodePayloadCheckpoint(container, expected);
        if (!std.mem.eql(u8, &decoded.state_digest, &ready.state_digest)) return error.CheckpointDigestMismatch;
        const published = try repository.publish(init.io, container, expected);
        const content_identity = std.fmt.bytesToHex(published.content_identity, .lower);
        const digest = std.fmt.bytesToHex(ready.state_digest, .lower);
        const host_pid: u64 = if (builtin.os.tag == .windows) GetProcessId(host.child.id.?) else @intCast(host.child.id.?);
        if (host_pid == 0) return error.InvalidHostProcessId;
        try output.interface.print("{{\"strategy_identity\":\"{s}\",\"cursor\":{d},\"next_intent_sequence\":{d},\"next_input_batch\":{d},\"host_generation\":{d},\"host_pid\":{d},\"state_digest\":\"{s}\",\"trading_authorized\":false,\"checkpoint\":{{\"cursor\":{d},\"publication\":{d},\"content_identity\":\"{s}\"}}}}\n", .{ request.binding.strategy_identity, ready.cursor, ready.next_intent_sequence, host.next_input_batch, plan.session.generation, host_pid, digest, ready.cursor, published.sequence, content_identity });
        try output.interface.flush();
        return .{ .adapter = adapter, .repository = repository, .expected = expected, .host = host, .ready = ready, .storage = storage, .plan = plan };
    }

    fn deinit(self: *Instance, init: std.process.Init) void {
        init.gpa.free(self.storage);
        self.adapter.close(init.io);
        init.gpa.destroy(self.adapter);
    }

    fn execute(self: *Instance, init: std.process.Init, command_bytes: []const u8) !void {
        var expected = self.expected;
        defer self.expected = expected;
        const host = &self.host;
        const ready = self.ready;
        const storage = self.storage;
        const repository = self.repository;
        const plan = self.plan;
        var output_buffer: [512]u8 = undefined;
        var output = std.Io.File.stdout().writer(init.io, &output_buffer);
        const Command = struct {
            strategy_identity: ?[]const u8 = null,
            activation: ?struct { identity: []const u8, barrier: u64, state_digest: []const u8 } = null,
            batch: []const u8 = "",
            max_outputs: u64 = 0,
            checkpoint: bool = false,
        };
        const command = try std.json.parseFromSlice(Command, init.gpa, command_bytes, .{});
        defer command.deinit();
        const value = command.value;
        if (value.checkpoint) {
            expected.strategy_cursor = host.last_input_cursor.?;
            const checkpoint_request = host.last_checkpoint_request + 1;
            try host.requestCurrentCheckpoint(init.io, checkpoint_request, expected);
            const current = try host.receiveCheckpoint(init.io, storage);
            expected.next_intent_sequence = std.mem.readInt(u64, current[104..112], .little);
            const validated = try codec.decodePayloadCheckpoint(current, expected);
            const saved = try repository.publish(init.io, current, expected);
            const content = std.fmt.bytesToHex(saved.content_identity, .lower);
            const state_digest = std.fmt.bytesToHex(validated.state_digest, .lower);
            try output.interface.print("{{\"cursor\":{d},\"outputs\":0,\"next_intent_sequence\":{d},\"state_digest\":\"{s}\",\"checkpoint\":{{\"cursor\":{d},\"publication\":{d},\"content_identity\":\"{s}\"}}}}\n", .{ expected.strategy_cursor, expected.next_intent_sequence, state_digest, expected.strategy_cursor, saved.sequence, content });
            try output.interface.flush();
            return;
        }
        if (value.activation) |activation| {
            var activation_digest: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&activation_digest, activation.state_digest);
            try host.activate(init.io, .{ .strategy_identity = ready.strategy_identity, .activation_identity = try hexIdentity(activation.identity), .barrier = activation.barrier, .state_digest = activation_digest });
        }
        if (value.batch.len > 2 * plan.input_capacity or value.batch.len < 256) return error.InvalidRuntimeBatch;
        const batch = try init.gpa.alloc(u8, value.batch.len / 2);
        defer init.gpa.free(batch);
        _ = try std.fmt.hexToBytes(batch, value.batch);
        host.sendInput(init.io, batch, now(init.io)) catch |err| {
            const validation = @import("strategy_host_ipc.zig").validateBatchAt(batch, host.supervisor.plan.session, host.next_input_batch, host.last_input_cursor, now(init.io));
            std.log.err("runtime input rejected: {s}, expected_batch={d}, last_cursor={?d}", .{ @tagName(validation.status), host.next_input_batch, host.last_input_cursor });
            return err;
        };
        const count = try host.receiveBatchAck(init.io, now(init.io), value.max_outputs);
        var frame_buffer: [512]u8 = undefined;
        for (0..count) |_| {
            const payload = try host.receiveOutput(init.io, now(init.io), &frame_buffer);
            try output.interface.print("{{\"output\":\"{x}\"}}\n", .{payload});
            try output.interface.flush();
        }
        try output.interface.print("{{\"cursor\":{d},\"outputs\":{d}}}\n", .{ host.last_input_cursor.?, count });
        try output.interface.flush();
    }
};

pub fn run(init: std.process.Init, request_path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, request_path, init.gpa, .limited(256 * 1024));
    defer init.gpa.free(data);
    const envelope = try std.json.parseFromSlice(struct { instances: ?[]Request = null }, init.gpa, data, .{ .ignore_unknown_fields = true });
    defer envelope.deinit();
    const single = if (envelope.value.instances == null) try std.json.parseFromSlice(Request, init.gpa, data, .{ .ignore_unknown_fields = true }) else null;
    defer if (single) |value| value.deinit();
    const requests = envelope.value.instances orelse &.{single.?.value};
    if (requests.len == 0 or requests.len > 16) return error.HostInstanceCapacityExceeded;
    for (requests, 0..) |request, i| {
        for (requests[0..i]) |previous| {
            if (request.generation == previous.generation or std.mem.eql(u8, request.binding.strategy_identity, previous.binding.strategy_identity)) return error.DuplicateHostMember;
        }
        if (!std.mem.eql(u8, request.python, requests[0].python) or !std.mem.eql(u8, request.host, requests[0].host) or
            request.fencing != requests[0].fencing or request.shard != requests[0].shard or
            !std.mem.eql(u8, request.binding.decision_domain, requests[0].binding.decision_domain)) return error.IncompatibleHostPlacement;
    }
    var process = try lifecycle.ManagedHost.start(init, requests[0].python, requests[0].host, lifecycle.developmentPlan(requests[0].shard, requests[0].generation, requests[0].manifest.compatibility.python_abi), "candidate", &.{request_path});
    defer process.deinit(init.io);
    var instances: [16]Instance = undefined;
    var count: usize = 0;
    defer for (instances[0..count]) |*instance| instance.deinit(init);
    for (requests) |request| {
        instances[count] = try Instance.initialize(init, request, process.child);
        count += 1;
    }
    const Event = union(enum) { command: anyerror![]const u8, exited: anyerror!void };
    const command_storage = try init.gpa.alloc(u8, 256 * 1024);
    defer init.gpa.free(command_storage);
    while (true) {
        var events: [2]Event = undefined;
        var select = std.Io.Select(Event).init(init.io, &events);
        defer select.cancelDiscard();
        try select.concurrent(.exited, awaitHostExit, .{ init.io, process.child.stdout.? });
        try select.concurrent(.command, awaitCommand, .{ init.io, command_storage });
        const event = try select.await();
        select.cancelDiscard();
        switch (event) {
            .exited => return error.CandidateHostExited,
            .command => |result| {
                const bytes = try result;
                if (bytes.len == 0) return;
                const command = try std.json.parseFromSlice(struct { strategy_identity: ?[]const u8 = null }, init.gpa, bytes, .{ .ignore_unknown_fields = true });
                defer command.deinit();
                const identity = command.value.strategy_identity orelse if (count == 1) requests[0].binding.strategy_identity else return error.StrategyIdentityRequired;
                var matched = false;
                for (requests, instances[0..count]) |request, *instance| {
                    if (!std.mem.eql(u8, request.binding.strategy_identity, identity)) continue;
                    try instance.execute(init, bytes);
                    matched = true;
                    break;
                }
                if (!matched) return error.UnknownHostMember;
            },
        }
    }
}
