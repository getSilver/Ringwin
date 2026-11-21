//! Linux production role dispatcher and its bounded Unix-domain control seam.
//!
//! The engine owns its durable TradingShard. Venue sockets and credentials
//! remain outside the engine process.

const std = @import("std");
const builtin = @import("builtin");
const business = @import("../testing/support/linux_role_business.zig");
const simulated = @import("../adapters/simulated/simulated_venue.zig");
const production_engine = @import("production_engine.zig");

pub const max_control_queue = 8;
pub const max_frame_bytes = 1;

pub const Role = enum { engine, market_feed, execution_gateway, telemetry, control_fence };
pub const Phase = enum { stopped, starting, ready, recovering, trading, draining, forced_stop, failed };
pub const RolePhase = enum { stopped, starting, ready, recovering, draining, forced_stop, failed };
pub const Venue = enum { simulated };
pub const Command = enum(u8) { enable_risk = 'A', drain = 'D', stop = 'S', business = 'B', settle = 'L', ingest_canonical = 'I', read_committed = 'C', read_strategy_authority = 'P', recover_venue = 'U' };
pub const Status = enum(u8) { hello = 'H', ready = 'R', risk_enabled = 'A', draining = 'G', stopped = 'T', forced_stop = 'F', failed = 'X', recovery_only = 'V' };

pub const BoundedQueue = struct {
    values: [max_control_queue]Command = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn push(self: *BoundedQueue, value: Command) !void {
        if (self.count == self.values.len) return error.Backpressure;
        self.values[self.tail] = value;
        self.tail = (self.tail + 1) % self.values.len;
        self.count += 1;
    }

    pub fn pop(self: *BoundedQueue) ?Command {
        if (self.count == 0) return null;
        const value = self.values[self.head];
        self.head = (self.head + 1) % self.values.len;
        self.count -= 1;
        return value;
    }
};

pub const RoleState = struct {
    phase: RolePhase = .stopped,
    generation: u64 = 0,
    risk_gate_open: bool = false,
};

pub const ChainState = struct {
    roles: [5]RoleState = @splat(.{}),
    venue: Venue = .simulated,
    phase: Phase = .stopped,
    forced_stop: bool = false,
    risk_authorized: bool = false,

    pub fn startRole(self: *ChainState, role: Role, generation: u64) !void {
        const state = &self.roles[@intFromEnum(role)];
        if (generation == 0 or state.phase != .stopped) return error.InvalidRoleTransition;
        state.* = .{ .phase = .recovering, .generation = generation };
        self.phase = .recovering;
    }

    pub fn completeRecovery(self: *ChainState) !void {
        for (self.roles) |role| if (role.phase != .recovering) return error.RecoveryIncomplete;
        for (&self.roles) |*role| role.phase = .ready;
        self.phase = .ready;
    }

    pub fn allReady(self: *const ChainState) bool {
        for (self.roles) |role| if (role.phase != .ready) return false;
        return true;
    }

    pub fn enableTrading(self: *ChainState) !void {
        if (!self.allReady() or self.phase != .ready or self.forced_stop) return error.SafetyGateClosed;
        self.phase = .trading;
        self.risk_authorized = true;
        for (&self.roles, 0..) |*role, index| {
            role.risk_gate_open = enforcesRiskGate(@enumFromInt(index));
        }
    }

    pub fn beginDrain(self: *ChainState) !void {
        if (self.phase != .trading and self.phase != .ready) return error.InvalidRoleTransition;
        self.phase = .draining;
        self.risk_authorized = false;
        for (&self.roles) |*role| {
            role.phase = .draining;
            role.risk_gate_open = false;
        }
    }

    pub fn stop(self: *ChainState) !void {
        if (self.phase != .draining) return error.InvalidRoleTransition;
        self.phase = .stopped;
        for (&self.roles) |*role| role.phase = .stopped;
    }

    pub fn forceStop(self: *ChainState) void {
        self.phase = .forced_stop;
        self.forced_stop = true;
        self.risk_authorized = false;
        for (&self.roles) |*role| {
            role.phase = .forced_stop;
            role.risk_gate_open = false;
        }
    }

    pub fn observeFailure(self: *ChainState, role: Role) void {
        self.roles[@intFromEnum(role)].phase = .failed;
        self.phase = .failed;
        self.risk_authorized = false;
    }
};

pub fn roleName(role: Role) []const u8 {
    return @tagName(role);
}

fn enforcesRiskGate(role: Role) bool {
    return role == .engine or role == .execution_gateway;
}

pub fn parseRole(value: []const u8) !Role {
    inline for (std.meta.fields(Role)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @field(Role, field.name);
    }
    return error.UnknownRole;
}

var termination_requested = std.atomic.Value(bool).init(false);
var active_socket: std.atomic.Value(std.posix.fd_t) = std.atomic.Value(std.posix.fd_t).init(-1);

fn onTerm(signal: std.posix.SIG) callconv(.c) void {
    _ = signal;
    termination_requested.store(true, .seq_cst);
    if (comptime builtin.os.tag == .linux) {
        const socket = active_socket.load(.seq_cst);
        if (socket >= 0) _ = std.os.linux.shutdown(socket, std.os.linux.SHUT.RD);
    }
}

fn installTermHandler() !void {
    if (comptime builtin.os.tag != .linux) return error.LinuxOnlyProductionRole;
    termination_requested.store(false, .seq_cst);
    var action: std.posix.Sigaction = .{
        .handler = .{ .handler = onTerm },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

fn writeStatus(stream: *std.Io.net.Stream, io: std.Io, status: Status) !void {
    var buffer: [max_frame_bytes]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(&.{@intFromEnum(status)});
    try writer.interface.flush();
}

fn readCommand(stream: *std.Io.net.Stream, io: std.Io) !?Command {
    var byte: [max_frame_bytes]u8 = undefined;
    while (true) {
        var buffers: [1][]u8 = .{byte[0..]};
        const n = stream.read(io, &buffers) catch |err| {
            if (termination_requested.load(.seq_cst)) return null;
            return err;
        };
        if (n == 0) return null;
        return std.enums.fromInt(Command, byte[0]) orelse error.InvalidControlFrame;
    }
}

fn readExact(stream: *std.Io.net.Stream, io: std.Io, bytes: []u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        var buffers = [_][]u8{remaining};
        const count = try stream.read(io, &buffers);
        if (count == 0) return error.IncompleteEngineFrame;
        remaining = remaining[count..];
    }
}

fn readFrameInt(stream: *std.Io.net.Stream, io: std.Io, comptime T: type) !T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    try readExact(stream, io, &bytes);
    return std.mem.readInt(T, &bytes, .little);
}

fn waitForCommand(stream: *std.Io.net.Stream, io: std.Io, drain_deadline: ?i96) !?Command {
    if (comptime builtin.os.tag == .linux) {
        var descriptors: [1]std.posix.pollfd = .{.{
            .fd = stream.socket.handle,
            .events = std.os.linux.POLL.IN,
            .revents = 0,
        }};
        const timeout_ms: i32 = if (drain_deadline) |deadline| blk: {
            const remaining = deadline - std.Io.Clock.awake.now(io).nanoseconds;
            if (remaining <= 0) return error.DrainDeadline;
            break :blk @intCast(@divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms));
        } else -1;
        const ready = std.posix.poll(&descriptors, timeout_ms) catch |err| {
            if (termination_requested.load(.seq_cst)) return null;
            return err;
        };
        if (ready == 0) return error.DrainDeadline;
    }
    return readCommand(stream, io);
}

pub const Startup = union(enum) { fixture_generation: u64, state_dir: []const u8 };

fn advanceGeneration(io: std.Io, dir: std.Io.Dir) !u64 {
    var bytes: [9]u8 = undefined;
    const current = if (dir.readFile(io, "generation", &bytes)) |stored| blk: {
        if (stored.len != 8) return error.CorruptRoleGeneration;
        const value = std.mem.readInt(u64, stored[0..8], .little);
        if (value == 0) return error.CorruptRoleGeneration;
        break :blk value;
    } else |err| switch (err) {
        error.FileNotFound => 0,
        else => return err,
    };
    const next = try std.math.add(u64, current, 1);
    std.mem.writeInt(u64, bytes[0..8], next, .little);
    {
        const file = try dir.createFile(io, "generation.tmp", .{ .permissions = @enumFromInt(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes[0..8]);
        try file.sync(io);
    }
    try dir.rename("generation.tmp", dir, "generation", io);
    if (std.os.linux.errno(std.os.linux.fsync(dir.handle)) != .SUCCESS) return error.GenerationDirectorySyncFailed;
    return next;
}

fn verifyController(stream: std.Io.net.Stream, fixture: bool, parent: std.os.linux.pid_t) !void {
    const linux = std.os.linux;
    const Credentials = extern struct { pid: linux.pid_t, uid: linux.uid_t, gid: linux.gid_t };
    var credentials: Credentials = undefined;
    var length: linux.socklen_t = @sizeOf(Credentials);
    if (linux.errno(linux.getsockopt(stream.socket.handle, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&credentials), &length)) != .SUCCESS or
        length != @sizeOf(Credentials) or credentials.pid <= 0)
        return error.ControllerCredentialsUnavailable;
    if (fixture) {
        if (parent <= 1 or credentials.pid != parent or credentials.uid != linux.geteuid()) return error.UntrustedRoleController;
    } else if (credentials.uid != 0) return error.UntrustedRoleController;
}

pub fn runRole(init: std.process.Init, role: Role, socket_path: []const u8, startup: Startup) !void {
    if (comptime builtin.os.tag != .linux) return error.LinuxOnlyProductionRole;
    if ((role != .engine and role != .market_feed) or startup == .fixture_generation) return serveRole(init, role, socket_path, startup);

    // Durable recovery uses large fixed-size journal, shard and adapter values.
    const Runner = struct {
        failure: ?anyerror = null,

        fn run(self: *@This(), process: std.process.Init, owner_role: Role, path: []const u8, mode: Startup) void {
            serveRole(process, owner_role, path, mode) catch |err| {
                self.failure = err;
            };
        }
    };
    var runner: Runner = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 * 1024 }, Runner.run, .{ &runner, init, role, socket_path, startup });
    thread.join();
    if (runner.failure) |failure| return failure;
}

fn serveRole(init: std.process.Init, role: Role, socket_path: []const u8, startup: Startup) !void {
    if (comptime builtin.os.tag != .linux) return error.LinuxOnlyProductionRole;
    if (!std.fs.path.isAbsolute(socket_path)) return error.InvalidRoleConfiguration;
    const parent = std.os.linux.getppid();
    const fixture = startup == .fixture_generation;
    const state_dir = if (fixture) null else try std.Io.Dir.openDirAbsolute(init.io, startup.state_dir, .{ .iterate = true });
    defer if (state_dir) |dir| dir.close(init.io);
    const owner = if (state_dir) |dir| try dir.createFile(init.io, "role.lock", .{
        .truncate = false,
        .permissions = @enumFromInt(0o600),
    }) else null;
    defer if (owner) |file| file.close(init.io);
    if (owner) |file| if (!try file.tryLock(init.io, .exclusive)) return error.RoleAlreadyRunning;
    const generation = if (state_dir) |dir| try advanceGeneration(init.io, dir) else startup.fixture_generation;
    if (generation == 0) return error.InvalidRoleConfiguration;
    var live_engine = if (role == .engine and state_dir != null)
        try production_engine.Engine.open(init, state_dir.?, startup.state_dir)
    else
        null;
    defer if (live_engine) |engine| engine.close(init);
    try installTermHandler();
    const address = try std.Io.net.UnixAddress.init(socket_path);
    std.Io.Dir.cwd().deleteFile(init.io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var server = try address.listen(init.io, .{ .kernel_backlog = 1 });
    defer server.deinit(init.io);
    defer std.Io.Dir.cwd().deleteFile(init.io, socket_path) catch {};

    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.print("production_role: role={s}, generation={d}, ipc=unix\n", .{ roleName(role), generation });
    if (live_engine != null and live_engine.?.source_count == 0)
        try stdout.interface.writeAll("production_role: venue_recovery=VenueRecoveryNotConfigured\n");
    try stdout.interface.flush();

    active_socket.store(server.socket.handle, .seq_cst);
    defer active_socket.store(-1, .seq_cst);
    var stream = server.accept(init.io) catch |err| {
        if (termination_requested.load(.seq_cst)) return;
        return err;
    };
    defer stream.close(init.io);
    active_socket.store(stream.socket.handle, .seq_cst);
    try verifyController(stream, fixture, parent);
    try writeStatus(&stream, init.io, .hello);
    try writeStatus(&stream, init.io, if (live_engine != null) .recovery_only else .ready);

    var draining = false;
    var drain_deadline: ?i96 = null;
    var risk_gate_open = false;
    var engine: ?*business.Engine = null;
    defer if (engine) |owner_| owner_.deinit(init);
    var backend: simulated.SimulatedVenue = .{};
    var business_started = false;
    while (true) {
        const command = waitForCommand(&stream, init.io, drain_deadline) catch |err| {
            if (err == error.DrainDeadline) {
                try writeStatus(&stream, init.io, .forced_stop);
                try writeStatus(&stream, init.io, .stopped);
                return;
            }
            writeStatus(&stream, init.io, .failed) catch {};
            return err;
        } orelse {
            if (!termination_requested.load(.seq_cst)) {
                try writeStatus(&stream, init.io, .failed);
                return error.RoleIpcDisconnected;
            }
            risk_gate_open = false;
            draining = true;
            try writeStatus(&stream, init.io, .draining);
            // Role-specific output draining is not wired yet. Reporting a
            // graceful stop here would turn missing evidence into success.
            try writeStatus(&stream, init.io, .forced_stop);
            try writeStatus(&stream, init.io, .stopped);
            return;
        };
        switch (command) {
            .enable_risk => {
                if (!fixture) {
                    try writeStatus(&stream, init.io, .failed);
                    return error.SignedControlFactRequired;
                }
                if (!enforcesRiskGate(role) or draining or risk_gate_open)
                    return error.InvalidRoleTransition;
                risk_gate_open = true;
                try writeStatus(&stream, init.io, .risk_enabled);
            },
            .drain => {
                if (draining) {
                    try writeStatus(&stream, init.io, .failed);
                    return error.InvalidRoleTransition;
                }
                risk_gate_open = false;
                draining = true;
                drain_deadline = std.Io.Clock.awake.now(init.io).nanoseconds + 5 * std.time.ns_per_s;
                if (engine) |owner_| try owner_.revoke(init);
                if (live_engine) |active_engine| try production_engine.revokeHosts(active_engine.owner);
                try writeStatus(&stream, init.io, .draining);
            },
            .stop => {
                if (!draining) {
                    try writeStatus(&stream, init.io, .failed);
                    return error.InvalidRoleTransition;
                }
                if ((engine != null and engine.?.pending) or backend.pending != null) {
                    try writeStatus(&stream, init.io, .forced_stop);
                    return error.BusinessOutputPending;
                }
                if (live_engine) |active_engine| {
                    if (!(try active_engine.owner.source()).oms.openOrdersClosed()) {
                        try writeStatus(&stream, init.io, .forced_stop);
                        return error.BusinessOutputPending;
                    }
                    if (active_engine.owner.decision_journal.records != 0) try active_engine.owner.checkpoint();
                }
                if (role == .execution_gateway and business_started)
                    try backend.adapter().stop(.{ .monotonic_ns = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds) });
                try writeStatus(&stream, init.io, .stopped);
                return;
            },
            .business => {
                if (!fixture or draining or business_started or (enforcesRiskGate(role) and !risk_gate_open))
                    return error.InvalidBusinessTransition;
                business_started = true;
                switch (role) {
                    .control_fence => try business.writeFrame(stream, init.io, &.{1}),
                    .market_feed => {
                        var mark: [8]u8 = undefined;
                        std.mem.writeInt(u64, &mark, 50_000_000_000, .little);
                        try business.writeFrame(stream, init.io, &mark);
                    },
                    .engine => {
                        var input: [9]u8 = undefined;
                        if ((try business.readFrame(stream, init.io, &input)).len != input.len)
                            return error.InvalidBusinessFrame;
                        engine = try business.Engine.start(init, stream, generation, socket_path);
                        try engine.?.submit(init, std.mem.readInt(u64, input[0..8], .little), input[8]);
                        try business.writeFrame(stream, init.io, "A");
                    },
                    .execution_gateway => {
                        var input: [business.max_frame]u8 = undefined;
                        try business.execute(init, &backend, try business.readFrame(stream, init.io, &input));
                        try business.writeFrame(stream, init.io, "A");
                    },
                    .telemetry => return error.InvalidBusinessTransition,
                }
            },
            .settle => {
                if (!fixture or !draining) return error.InvalidBusinessTransition;
                switch (role) {
                    .engine => {
                        const owner_ = engine orelse return error.NoDispatchPending;
                        try owner_.settle(init, try business.readBatch(stream, init.io));
                        try business.writeFrame(stream, init.io, "A");
                    },
                    .execution_gateway => {
                        const batch = try backend.adapter().tryDrain() orelse return error.NoDispatchPending;
                        try business.writeBatch(stream, init.io, &batch);
                    },
                    .telemetry => {
                        if (business_started) return error.InvalidBusinessTransition;
                        const batch = try business.readBatch(stream, init.io);
                        var fills: u8 = 0;
                        var lots: i128 = 0;
                        for (batch.slice()) |event| if (event.event == .fill) {
                            fills += 1;
                            lots = try std.math.add(i128, lots, event.event.fill.quantity.lots);
                        };
                        if (fills != 2 or lots != 10) return error.UnexpectedSimulatedFills;
                        business_started = true;
                        try business.writeFrame(stream, init.io, &.{fills});
                    },
                    else => return error.InvalidBusinessTransition,
                }
            },
            .recover_venue => {
                if (fixture or draining) return error.InvalidRoleTransition;
                switch (role) {
                    .engine => {
                        const recovered = try recoverVenue(&live_engine.?, &stream, init);
                        try writeStatus(&stream, init.io, if (recovered) .ready else .recovery_only);
                    },
                    .market_feed => try @import("production_market_recovery.zig").replay(init, state_dir.?, startup.state_dir, stream),
                    else => return error.InvalidRoleTransition,
                }
            },
            .read_strategy_authority => {
                const active_engine = live_engine orelse return error.EngineUnavailable;
                const size = try readFrameInt(&stream, init.io, u32);
                if (size == 0 or size > production_engine.max_authority_bytes) return error.InvalidAuthorityFrame;
                const request = try init.gpa.alloc(u8, size);
                defer init.gpa.free(request);
                try readExact(&stream, init.io, request);
                const response = production_engine.readStrategyAuthority(active_engine.owner, init.gpa, request) catch |err|
                    try std.json.Stringify.valueAlloc(init.gpa, .{ .@"error" = @errorName(err) }, .{});
                defer init.gpa.free(response);
                if (response.len > production_engine.max_authority_bytes) return error.InvalidAuthorityFrame;
                var output_buffer: [256]u8 = undefined;
                var output = stream.writer(init.io, &output_buffer);
                try output.interface.writeInt(u32, @intCast(response.len), .little);
                try output.interface.writeAll(response);
                try output.interface.flush();
            },
            .ingest_canonical, .read_committed => {
                const active_engine = live_engine orelse return error.EngineUnavailable;
                var frame: [production_engine.max_record_bytes]u8 = undefined;
                const result: production_engine.CommittedRecord = if (command == .ingest_canonical) blk: {
                    if (draining or active_engine.owner.shard.recovery_admission_pending) return error.VenueRecoveryIncomplete;
                    const size = try readFrameInt(&stream, init.io, u32);
                    if (size == 0 or size > production_engine.max_input_bytes) return error.InvalidCanonicalFrame;
                    try readExact(&stream, init.io, frame[0..size]);
                    break :blk .{ .cursor = try production_engine.ingest(active_engine.owner, frame[0..size]) };
                } else try production_engine.nextCommittedRecord(active_engine.owner, try readFrameInt(&stream, init.io, u64), &frame);
                var output_buffer: [256]u8 = undefined;
                var output = stream.writer(init.io, &output_buffer);
                try output.interface.writeInt(u64, result.cursor, .little);
                try output.interface.writeInt(u32, if (result.record) |record| @intCast(record.payload.len) else 0, .little);
                if (result.record) |record| {
                    try output.interface.writeInt(u16, record.type_id, .little);
                    try output.interface.writeInt(u16, record.schema_version, .little);
                    try output.interface.writeInt(u32, record.flags, .little);
                    for ([_]u64{ record.source_time, record.receive_time, record.monotonic_time, record.wall_time }) |time|
                        try output.interface.writeInt(u64, time, .little);
                    try output.interface.writeByte(@bitCast(record.time_presence));
                    try output.interface.writeAll(record.payload);
                }
                try output.interface.flush();
            },
        }
    }
}

fn recoverVenue(engine: *production_engine.Engine, stream: *std.Io.net.Stream, init: std.process.Init) !bool {
    if (!engine.owner.shard.recovery_admission_pending) return error.InvalidRoleTransition;
    const source: production_engine.RecoverySource = .{
        .venue = try readFrameInt(stream, init.io, u64),
        .raw_stream = try readFrameInt(stream, init.io, u64),
        .session = try readFrameInt(stream, init.io, u64),
    };
    var sweep: production_engine.RecoverySweep = .{ .source = source, .raw_barrier = try readFrameInt(stream, init.io, u64) };
    const index = engine.sourceIndex(source);
    defer sweep.deinit(init.gpa);
    var valid = index != null and sweep.raw_barrier != 0;
    if (valid) sweep.loadCommitted(engine.owner, init.gpa) catch |err| {
        std.log.warn("engine committed Venue prefix: {s}", .{@errorName(err)});
        valid = false;
    };
    var frame: [production_engine.max_input_bytes]u8 = undefined;
    while (true) {
        const size = try readFrameInt(stream, init.io, u32);
        if (size == 0) break;
        if (size == std.math.maxInt(u32)) {
            valid = false;
            break;
        }
        if (size > frame.len) return error.InvalidCanonicalFrame;
        try readExact(stream, init.io, frame[0..size]);
        if (valid) sweep.apply(engine.owner, frame[0..size]) catch |err| {
            std.log.warn("engine Venue recovery: {s}", .{@errorName(err)});
            valid = false;
        };
    }
    if (valid) engine.finishSource(index.?, sweep) catch |err| {
        std.log.warn("engine Venue recovery completion: {s}", .{@errorName(err)});
        valid = false;
    };
    if (!valid) engine.recovered_sources = 0;
    return !engine.owner.shard.recovery_admission_pending;
}

fn connectRole(init: std.process.Init, socket_path: []const u8) !std.Io.net.Stream {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (address.connect(init.io)) |stream| return stream else |_| init.io.sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
    }
    return error.RoleSocketTimeout;
}

fn readStatus(stream: *std.Io.net.Stream, io: std.Io) !Status {
    var byte: [max_frame_bytes]u8 = undefined;
    while (true) {
        var buffers: [1][]u8 = .{byte[0..]};
        const n = try stream.read(io, &buffers);
        if (n == 0) return error.EndOfStream;
        return std.enums.fromInt(Status, byte[0]) orelse error.InvalidStatus;
    }
}

fn sendCommand(stream: *std.Io.net.Stream, io: std.Io, command: Command) !void {
    var buffer: [max_frame_bytes]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(&.{@intFromEnum(command)});
    try writer.interface.flush();
}

fn spawnRole(init: std.process.Init, executable: []const u8, role: Role, socket_path: []const u8, generation: u64) !std.process.Child {
    var generation_text: [24]u8 = undefined;
    const generation_arg = try std.fmt.bufPrint(&generation_text, "{d}", .{generation});
    return std.process.spawn(init.io, .{ .argv = &.{ executable, "--production-role", roleName(role), "--socket", socket_path, "--generation", generation_arg }, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit });
}

fn expectStatus(stream: *std.Io.net.Stream, io: std.Io, expected: Status) !void {
    const actual = try readStatus(stream, io);
    if (actual != expected) return error.UnexpectedRoleStatus;
}

pub fn runIntegration(init: std.process.Init, executable: []const u8) !void {
    if (comptime builtin.os.tag != .linux) {
        var buffer: [128]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        try stdout.interface.writeAll("production_chain: skipped (Linux-only native process acceptance)\n");
        try stdout.interface.flush();
        return;
    }

    var chain = ChainState{};
    const roles = [_]Role{ .engine, .market_feed, .execution_gateway, .telemetry, .control_fence };
    var paths: [roles.len][108]u8 = undefined;
    var path_slices: [roles.len][]const u8 = undefined;
    const pid = std.os.linux.getpid();
    for (&paths, 0..) |*path, index| {
        path_slices[index] = try std.fmt.bufPrint(path, "/tmp/ringwin-chain-{d}-{d}.sock", .{ pid, index });
    }
    var children: [roles.len]std.process.Child = undefined;
    var streams: [roles.len]std.Io.net.Stream = undefined;
    var started: usize = 0;
    var connected: usize = 0;
    defer {
        for (streams[0..connected]) |*stream| stream.close(init.io);
        for (children[0..started]) |*child| child.kill(init.io);
    }

    for (roles, 0..) |role, index| {
        children[index] = try spawnRole(init, executable, role, path_slices[index], 1);
        started += 1;
        streams[index] = try connectRole(init, path_slices[index]);
        connected += 1;
        try expectStatus(&streams[index], init.io, .hello);
        try expectStatus(&streams[index], init.io, .ready);
        try chain.startRole(role, 1);
    }
    if (chain.phase != .recovering or chain.venue != .simulated) return error.RoleChainNotReady;
    try chain.completeRecovery();
    if (!chain.allReady()) return error.RoleChainNotReady;
    try chain.enableTrading();
    for (&streams, roles) |*stream, role| {
        if (!enforcesRiskGate(role)) continue;
        try sendCommand(stream, init.io, .enable_risk);
        try expectStatus(stream, init.io, .risk_enabled);
    }
    const engine_stream = &streams[@intFromEnum(Role.engine)];
    const market_stream = &streams[@intFromEnum(Role.market_feed)];
    const fence_stream = &streams[@intFromEnum(Role.control_fence)];
    const gateway_stream = &streams[@intFromEnum(Role.execution_gateway)];
    const telemetry_stream = &streams[@intFromEnum(Role.telemetry)];
    var state_path: [128]u8 = undefined;
    const engine_state = try std.fmt.bufPrint(&state_path, "{s}.state", .{path_slices[0]});
    var input: [9]u8 = undefined;
    try sendCommand(market_stream, init.io, .business);
    if ((try business.readFrame(market_stream.*, init.io, input[0..8])).len != 8) return error.InvalidBusinessFrame;
    try sendCommand(fence_stream, init.io, .business);
    _ = try business.readFrame(fence_stream.*, init.io, input[8..9]);
    try sendCommand(engine_stream, init.io, .business);
    try business.writeFrame(engine_stream.*, init.io, &input);
    var request: [business.max_frame]u8 = undefined;
    const submission = try business.readFrame(engine_stream.*, init.io, &request);
    try sendCommand(gateway_stream, init.io, .business);
    try business.writeFrame(gateway_stream.*, init.io, submission);
    var ack: [1]u8 = undefined;
    if (!std.mem.eql(u8, try business.readFrame(gateway_stream.*, init.io, &ack), "A")) return error.DispatchNotAccepted;
    try business.writeFrame(engine_stream.*, init.io, "A");
    if (!std.mem.eql(u8, try business.readFrame(engine_stream.*, init.io, &ack), "A")) return error.DispatchNotCommitted;
    try chain.beginDrain();
    for (&streams) |*stream| {
        try sendCommand(stream, init.io, .drain);
        try expectStatus(stream, init.io, .draining);
    }
    try sendCommand(gateway_stream, init.io, .settle);
    const result = try business.readBatch(gateway_stream.*, init.io);
    try sendCommand(engine_stream, init.io, .settle);
    try business.writeBatch(engine_stream.*, init.io, &result);
    if (!std.mem.eql(u8, try business.readFrame(engine_stream.*, init.io, &ack), "A")) return error.FillNotCommitted;
    try sendCommand(telemetry_stream, init.io, .settle);
    try business.writeBatch(telemetry_stream.*, init.io, &result);
    _ = try business.readFrame(telemetry_stream.*, init.io, &ack);
    if (ack[0] != 2) return error.FillNotObserved;
    for (&streams) |*stream| {
        try sendCommand(stream, init.io, .stop);
        try expectStatus(stream, init.io, .stopped);
    }
    for (&children) |*child| {
        const term = try child.wait(init.io);
        if (term != .exited or term.exited != 0) return error.RoleExitedUnexpectedly;
    }
    try chain.stop();
    try std.Io.Dir.cwd().deleteTree(init.io, engine_state);

    var forced_child = try spawnRole(init, executable, .engine, path_slices[0], 2);
    defer forced_child.kill(init.io);
    var forced_stream = try connectRole(init, path_slices[0]);
    defer forced_stream.close(init.io);
    try expectStatus(&forced_stream, init.io, .hello);
    try expectStatus(&forced_stream, init.io, .ready);
    try sendCommand(&forced_stream, init.io, .enable_risk);
    try expectStatus(&forced_stream, init.io, .risk_enabled);
    try sendCommand(&forced_stream, init.io, .drain);
    try expectStatus(&forced_stream, init.io, .draining);
    try expectStatus(&forced_stream, init.io, .forced_stop);
    try expectStatus(&forced_stream, init.io, .stopped);
    const forced_term = try forced_child.wait(init.io);
    if (forced_term != .exited or forced_term.exited != 0) return error.ForcedStopFailed;
    chain.forceStop();
    if (chain.risk_authorized or !chain.forced_stop) return error.SafetyGateNotRevoked;

    var restart_child = try spawnRole(init, executable, .engine, path_slices[0], 3);
    defer restart_child.kill(init.io);
    var restart_stream = try connectRole(init, path_slices[0]);
    defer restart_stream.close(init.io);
    try expectStatus(&restart_stream, init.io, .hello);
    try expectStatus(&restart_stream, init.io, .ready);
    try sendCommand(&restart_stream, init.io, .enable_risk);
    try expectStatus(&restart_stream, init.io, .risk_enabled);
    try std.posix.kill(restart_child.id.?, std.posix.SIG.TERM);
    try expectStatus(&restart_stream, init.io, .draining);
    try expectStatus(&restart_stream, init.io, .forced_stop);
    try expectStatus(&restart_stream, init.io, .stopped);
    const restart_term = try restart_child.wait(init.io);
    if (restart_term != .exited or restart_term.exited != 0) return error.RestartRecoveryFailed;

    var output_buffer: [512]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output.interface.print(
        "production_chain: venue=SimulatedVenue roles=5 recovering=5 ready=5 drain=5 forced_stop=1 restart_generation=3 risk_authorized=false ipc=unix bounded_queue={d} host=python durable_fills=2\n",
        .{max_control_queue},
    );
    try output.interface.flush();
}

test "formal engine recovers its Writer and reads canonical observations only after commit" {
    const durable = @import("../persistence/durable_store.zig");
    const codec = @import("../persistence/canonical_event_codec.zig");
    const Owner = @import("demo/demo_authority.zig").Owner;
    const fixture = @import("../testing/support/trading_shard_fixture.zig");
    const account = @import("../testing/acceptance/core/multi_account_authority_acceptance.zig");
    const allocator = std.testing.allocator;
    var directory = std.testing.tmpDir(.{ .iterate = true });
    defer directory.cleanup();
    const storage = try allocator.create(durable.LinuxFileAdapter);
    defer allocator.destroy(storage);
    storage.* = .{ .dir = directory.dir };
    defer storage.deinit();
    const owner = try allocator.create(Owner);
    defer allocator.destroy(owner);
    const decision_stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    try Owner.bootstrapInto(owner, storage.interface(), std.testing.io, decision_stream);
    try account.initializePythonOwner(owner);
    const digest = owner.deployment_anchor.?;
    const before = owner.shard.authoritativeBarrier();

    const recovered = try allocator.create(Owner);
    defer allocator.destroy(recovered);
    try std.testing.expectError(error.DeploymentDigestMismatch, production_engine.recover(recovered, storage.interface(), std.testing.io, decision_stream.id, @splat(1)));
    try std.testing.expectError(error.DecisionLogUnavailable, recovered.source());
    try production_engine.recover(recovered, storage.interface(), std.testing.io, decision_stream.id, digest);
    try std.testing.expect(recovered.shard.recovery_admission_pending);
    const list_request =
        \\{"operation":"pair_trading_list","strategy_identity":"00000000000000000000000000000009","scope_accounts":["00000000000000000000000000000014","0000000000000000000000000000001e"]}
    ;
    const pair_list = try production_engine.readStrategyAuthority(recovered, allocator, list_request);
    defer allocator.free(pair_list);
    try std.testing.expectEqualStrings("{\"pairs\":[]}", pair_list);
    var buffer: [production_engine.max_record_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidCanonicalFrame, production_engine.ingest(recovered, &.{}));
    try std.testing.expect((try production_engine.nextCommittedRecord(recovered, before, &buffer)).record == null);
    try std.testing.expectError(error.CursorAheadOfCommit, production_engine.nextCommittedRecord(recovered, before + 1, &buffer));

    var event = fixture.canonicalAt(46, 1, .{ .reference_price = .{
        .instrument = 101,
        .kind = .index,
        .price = .{ .instrument = 101, .rules_version = 1, .ticks = 42 },
    } });
    event.venue.envelope.scope = .instrument;
    event.venue.envelope.exchange_account = null;
    event.venue.envelope.instrument = 101;
    event.venue.envelope.identity.stream = 9000;
    event.venue.envelope.source_stream = 9000;
    event.venue.envelope.adapter_session = 9000;
    event.venue.envelope.raw_evidence = .{ .stream = 9000, .sequence = 1, .digest = @splat(1) };
    const frame = try codec.encode(&buffer, event.venue);
    const source: production_engine.RecoverySource = .{ .venue = event.venue.envelope.venue, .raw_stream = 9000, .session = 9000 };
    var sweep: production_engine.RecoverySweep = .{ .source = source, .raw_barrier = 1 };
    try sweep.apply(recovered, frame);
    const committed = recovered.shard.authoritativeBarrier();
    try std.testing.expect(committed > before);
    try std.testing.expectEqual(committed, (try storage.interface().recover(std.testing.io, decision_stream)).committed_barrier);
    var repeat: production_engine.RecoverySweep = .{ .source = source, .raw_barrier = 1 };
    defer repeat.deinit(allocator);
    try repeat.loadCommitted(recovered, allocator);
    try repeat.apply(recovered, frame);
    try std.testing.expectEqual(committed, recovered.shard.authoritativeBarrier());
    repeat.last_event = 0;
    repeat.last_raw = 0;
    var conflicting = event.venue;
    conflicting.envelope.raw_evidence.digest = @splat(2);
    try std.testing.expectError(error.ConflictingCanonicalIdentity, repeat.apply(recovered, try codec.encode(&buffer, conflicting)));
    try recovered.checkpoint();

    storage.deinit();
    storage.* = .{ .dir = directory.dir };
    try production_engine.recover(owner, storage.interface(), std.testing.io, decision_stream.id, digest);
    const input = try production_engine.nextCommittedRecord(owner, before, &buffer);
    try std.testing.expectEqual(before + 1, input.cursor);
    const decoded = (try @import("../trading/trading_shard.zig").decodeStableInput(input.record.?)).venue;
    try std.testing.expectEqualDeep(event.venue.envelope.identity, decoded.envelope.identity);
    try std.testing.expectEqual(@as(i128, 42), decoded.event.reference_price.price.ticks);
    var cursor = input.cursor;
    while (cursor < owner.shard.authoritativeBarrier()) {
        const next = try production_engine.nextCommittedRecord(owner, cursor, &buffer);
        try std.testing.expectEqual(cursor + 1, next.cursor);
        try std.testing.expect(next.record != null);
        cursor = next.cursor;
    }
    try std.testing.expect((try production_engine.nextCommittedRecord(owner, cursor, &buffer)).record == null);
    try std.testing.expect(owner.shard.recovery_admission_pending);

    try @import("../testing/acceptance/core/scanner_authorization_acceptance.zig").configurePairAssets(owner);
    _ = try owner.apply(fixture.atGroup(46, .{ .identity = 98765, .payload = .{ .pair_trading_authorization = .{
        .identity = 98765,
        .strategy = 9,
        .portfolio = 10,
        .activation = 1,
        .config_version = 1,
        .expected_version = 0,
        .legs = .{
            .{ .venue = 1, .environment = .simulation, .account = 20, .instrument = 101, .rules_version = 2 },
            .{ .venue = 21, .environment = .simulation, .account = 30, .instrument = 102, .rules_version = 2 },
        },
        .direction = 1,
        .mode = .taker_taker,
        .enabled = true,
    } } }));
    const populated = try production_engine.readStrategyAuthority(owner, allocator, list_request);
    defer allocator.free(populated);
    const projected = try std.json.parseFromSlice(struct {
        pairs: []const struct { identity: []const u8 },
    }, allocator, populated, .{ .ignore_unknown_fields = true });
    defer projected.deinit();
    try std.testing.expectEqual(@as(usize, 1), projected.value.pairs.len);
    try std.testing.expectEqualStrings("000000000000000000000000000181cd", projected.value.pairs[0].identity);
}

test "bounded role IPC fails closed and drains FIFO" {
    var queue: BoundedQueue = .{};
    for (0..max_control_queue) |_| try queue.push(.drain);
    try std.testing.expectError(error.Backpressure, queue.push(.stop));
    for (0..max_control_queue) |_| try std.testing.expectEqual(Command.drain, queue.pop().?);
    try std.testing.expect(queue.pop() == null);
}

test "role chain revokes risk before draining and force stop" {
    var chain = ChainState{};
    for (std.enums.values(Role)) |role| try chain.startRole(role, 1);
    try chain.completeRecovery();
    try chain.enableTrading();
    try std.testing.expect(chain.risk_authorized);
    var authorized_roles: usize = 0;
    for (chain.roles) |role| authorized_roles += @intFromBool(role.risk_gate_open);
    try std.testing.expectEqual(@as(usize, 2), authorized_roles);
    try chain.beginDrain();
    try std.testing.expect(!chain.risk_authorized);
    try chain.stop();
    chain.forceStop();
    try std.testing.expectEqual(Phase.forced_stop, chain.phase);
}

test "missing or failed role keeps the chain fail closed" {
    var chain = ChainState{};
    const roles = std.enums.values(Role);
    for (roles[0 .. roles.len - 1]) |role| try chain.startRole(role, 1);
    try std.testing.expectError(error.RecoveryIncomplete, chain.completeRecovery());
    try std.testing.expectError(error.SafetyGateClosed, chain.enableTrading());
    chain.observeFailure(.telemetry);
    try std.testing.expectEqual(Phase.failed, chain.phase);
    try std.testing.expect(!chain.risk_authorized);
}
