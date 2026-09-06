//! Linux production role dispatcher and its bounded Unix-domain control seam.
//!
//! This module owns process lifecycle only. TradingShard remains an in-memory
//! state machine; credentials and venue sockets are deliberately absent here.

const std = @import("std");
const builtin = @import("builtin");

pub const max_control_queue = 8;
pub const max_frame_bytes = 1;

pub const Role = enum { engine, market_feed, execution_gateway, telemetry, control_fence };
pub const Phase = enum { stopped, starting, ready, recovering, trading, draining, forced_stop, failed };
pub const Venue = enum { simulated };
pub const Command = enum(u8) { drain = 'D', stop = 'S' };
pub const Status = enum(u8) { hello = 'H', ready = 'R', draining = 'G', stopped = 'T', forced_stop = 'F', failed = 'X' };

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
    phase: Phase = .stopped,
    generation: u64 = 0,
    trading_authorized: bool = false,
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
        for (&self.roles) |*role| {
            role.phase = .trading;
            role.trading_authorized = true;
        }
    }

    pub fn beginDrain(self: *ChainState) !void {
        if (self.phase != .trading and self.phase != .ready) return error.InvalidRoleTransition;
        self.phase = .draining;
        self.risk_authorized = false;
        for (&self.roles) |*role| {
            role.phase = .draining;
            role.trading_authorized = false;
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
            role.trading_authorized = false;
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

fn waitForCommand(stream: *std.Io.net.Stream, io: std.Io, draining: bool) !?Command {
    if (comptime builtin.os.tag == .linux) {
        var descriptors: [1]std.posix.pollfd = .{.{
            .fd = stream.socket.handle,
            .events = std.os.linux.POLL.IN,
            .revents = 0,
        }};
        const timeout_ms: i32 = if (draining) 5_000 else -1;
        const ready = std.posix.poll(&descriptors, timeout_ms) catch |err| {
            if (termination_requested.load(.seq_cst)) return null;
            return err;
        };
        if (ready == 0) return error.DrainDeadline;
    }
    return readCommand(stream, io);
}

pub fn runRole(init: std.process.Init, role: Role, socket_path: []const u8, generation: u64) !void {
    if (comptime builtin.os.tag != .linux) return error.LinuxOnlyProductionRole;
    if (socket_path.len == 0 or generation == 0) return error.InvalidRoleConfiguration;
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
    try stdout.interface.print("production_role: role={s}, generation={d}, ipc=unix, venue=SimulatedVenue\n", .{ roleName(role), generation });
    try stdout.interface.flush();

    var stream = try server.accept(init.io);
    defer stream.close(init.io);
    active_socket.store(stream.socket.handle, .seq_cst);
    defer active_socket.store(-1, .seq_cst);
    try writeStatus(&stream, init.io, .hello);
    try writeStatus(&stream, init.io, .ready);

    var draining = false;
    while (true) {
        const command = waitForCommand(&stream, init.io, draining) catch |err| {
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
            try writeStatus(&stream, init.io, .draining);
            break;
        };
        switch (command) {
            .drain => {
                draining = true;
                try writeStatus(&stream, init.io, .draining);
            },
            .stop => {
                try writeStatus(&stream, init.io, .stopped);
                return;
            },
        }
    }

    if (termination_requested.load(.seq_cst)) {
        try writeStatus(&stream, init.io, .forced_stop);
        try writeStatus(&stream, init.io, .stopped);
    }
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
    defer {
        for (streams[0..started]) |*stream| stream.close(init.io);
        for (children[0..started]) |*child| child.kill(init.io);
    }

    for (roles, 0..) |role, index| {
        children[index] = try spawnRole(init, executable, role, path_slices[index], 1);
        started += 1;
        streams[index] = try connectRole(init, path_slices[index]);
        try expectStatus(&streams[index], init.io, .hello);
        try expectStatus(&streams[index], init.io, .ready);
        try chain.startRole(role, 1);
    }
    if (chain.phase != .recovering or chain.venue != .simulated) return error.RoleChainNotReady;
    try chain.completeRecovery();
    if (!chain.allReady()) return error.RoleChainNotReady;
    try chain.enableTrading();
    try chain.beginDrain();
    for (&streams) |*stream| {
        try sendCommand(stream, init.io, .drain);
        try expectStatus(stream, init.io, .draining);
    }
    for (&streams) |*stream| {
        try sendCommand(stream, init.io, .stop);
        try expectStatus(stream, init.io, .stopped);
    }
    for (&children) |*child| {
        const term = try child.wait(init.io);
        if (term != .exited or term.exited != 0) return error.RoleExitedUnexpectedly;
    }
    try chain.stop();

    var forced_child = try spawnRole(init, executable, .engine, path_slices[0], 2);
    var forced_stream = try connectRole(init, path_slices[0]);
    defer forced_stream.close(init.io);
    try expectStatus(&forced_stream, init.io, .hello);
    try expectStatus(&forced_stream, init.io, .ready);
    try std.posix.kill(forced_child.id.?, std.posix.SIG.TERM);
    try expectStatus(&forced_stream, init.io, .draining);
    try expectStatus(&forced_stream, init.io, .forced_stop);
    try expectStatus(&forced_stream, init.io, .stopped);
    const forced_term = try forced_child.wait(init.io);
    if (forced_term != .exited or forced_term.exited != 0) return error.ForcedStopFailed;
    chain.forceStop();
    if (chain.risk_authorized or !chain.forced_stop) return error.SafetyGateNotRevoked;

    var restart_child = try spawnRole(init, executable, .engine, path_slices[0], 3);
    var restart_stream = try connectRole(init, path_slices[0]);
    defer restart_stream.close(init.io);
    try expectStatus(&restart_stream, init.io, .hello);
    try expectStatus(&restart_stream, init.io, .ready);
    try sendCommand(&restart_stream, init.io, .stop);
    try expectStatus(&restart_stream, init.io, .stopped);
    const restart_term = try restart_child.wait(init.io);
    if (restart_term != .exited or restart_term.exited != 0) return error.RestartRecoveryFailed;

    var output_buffer: [512]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output.interface.print(
        "production_chain: venue=SimulatedVenue roles=5 recovering=5 ready=5 drain=5 forced_stop=1 restart_generation=3 risk_authorized=false ipc=unix bounded_queue={d}\n",
        .{max_control_queue},
    );
    try output.interface.flush();
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
