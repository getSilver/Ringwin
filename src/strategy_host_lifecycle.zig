const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("strategy_host_ipc.zig");

const Crc32c = std.hash.crc.Crc32Iscsi;
const Sha256 = std.crypto.hash.sha2.Sha256;
const control_header_len: usize = 64;
const max_control_payload: usize = 65_536;
const max_checkpoint_payload: usize = 8 * 1024 * 1024 + 192 + 8;
const plan_len: usize = 176;
const hello_len: usize = 160;
const control_magic = "QSHC".*;
const protocol_version: u16 = 1;
const schema_registry_id: u128 = 0x0102030405060708090a0b0c0d0e0f10;
const host_build_identity: u128 = 0x1112131415161718191a1b1c1d1e1f20;
const strategy_manifest: [32]u8 = @splat(0x31);
const checkpoint_manifest: [32]u8 = @splat(0x42);

const MessageType = enum(u16) {
    session_plan = 1,
    begin_recovery = 2,
    activate_strategy = 3,
    shutdown = 6,
    host_hello = 101,
    strategy_recovered = 102,
    strategy_faulted = 103,
    recovery_required = 104,
    host_heartbeat = 106,
    shutdown_ack = 107,
};

pub const State = enum {
    stopped,
    starting,
    ready_for_recovery,
    recovering,
    recovered,
    active,
    stopping,
    failed,
};

pub const EvidenceKind = enum { intent, confirmation, checkpoint };

pub const Result = enum {
    accepted,
    stale_session,
    incompatible,
    protocol_error,
    timed_out,
    force_kill,
    no_change,
};

pub const Compatibility = struct {
    protocol: u16,
    schema_registry: u128,
    host_build: u128,
    python_abi: u32,
    strategy_manifest: [32]u8,
    checkpoint_manifest: [32]u8,
};

pub const Plan = struct {
    decision_domain: u128,
    session: ipc.Session,
    compatibility: Compatibility,
    input_slots: u32,
    input_capacity: u32,
    output_slots: u32,
    output_capacity: u32,
    heartbeat_interval_ns: i64,
    startup_timeout_ns: i64,
    hang_timeout_ns: i64,
    shutdown_grace_ns: i64,
};

pub const StrategyRecovered = struct {
    strategy_identity: u128,
    config_version: u64,
    state_schema_identity: u128,
    state_schema_version: u32,
    cursor: u64,
    next_intent_sequence: u64,
    state_digest: [32]u8,
};

pub const Activation = struct {
    strategy_identity: u128,
    activation_identity: u128,
    barrier: u64,
    state_digest: [32]u8,
};

pub const StrategyFault = struct {
    strategy_identity: u128,
    phase: u16,
    reason: u16,
    last_valid_cursor: u64,
    diagnostic_len: u16,
    diagnostic_digest: [32]u8,
};

pub const RecoveryRequired = struct {
    scope: u16,
    reason: u16,
    last_batch_sequence: u64,
    last_valid_cursor: u64,
};

pub const HostSupervisor = struct {
    plan: Plan,
    state: State = .starting,
    next_host_sequence: u64 = 1,
    next_zig_sequence: u64 = 1,
    phase_started_ns: i64,
    last_heartbeat_ns: i64 = 0,
    shutdown_deadline_ns: i64 = 0,
    last_recovered: ?StrategyRecovered = null,
    last_fault: ?StrategyFault = null,
    recovery_required: ?RecoveryRequired = null,

    pub fn init(plan: Plan, now_ns: i64) !HostSupervisor {
        if (plan.session.generation == 0 or
            plan.input_slots < 2 or plan.output_slots < 2 or
            plan.input_capacity == 0 or plan.output_capacity == 0 or
            plan.heartbeat_interval_ns <= 0 or
            plan.startup_timeout_ns <= 0 or
            plan.hang_timeout_ns <= plan.heartbeat_interval_ns or
            plan.shutdown_grace_ns <= 0)
            return error.InvalidSessionPlan;
        return .{ .plan = plan, .phase_started_ns = now_ns };
    }

    pub fn acceptHostFrame(self: *HostSupervisor, frame: []const u8, now_ns: i64) Result {
        const decoded = decodeControl(frame) catch {
            self.state = .failed;
            return .protocol_error;
        };
        if (!sameSession(decoded.session, self.plan.session)) return .stale_session;
        if (decoded.sequence != self.next_host_sequence) {
            self.state = .failed;
            return .protocol_error;
        }

        const result: Result = switch (decoded.message_type) {
            .host_hello => self.acceptHello(decoded.payload, now_ns),
            .strategy_recovered => self.acceptStrategyRecovered(decoded.payload),
            .strategy_faulted => self.acceptStrategyFaulted(decoded.payload),
            .recovery_required => self.acceptRecoveryRequired(decoded.payload),
            .host_heartbeat => self.acceptHeartbeat(decoded.payload, now_ns),
            .shutdown_ack => self.acceptShutdownAck(decoded.payload),
            else => blk: {
                self.state = .failed;
                break :blk .protocol_error;
            },
        };
        if (result == .accepted) self.next_host_sequence += 1;
        return result;
    }

    pub fn beginShutdown(self: *HostSupervisor, now_ns: i64) !void {
        if (self.state != .ready_for_recovery and self.state != .recovered and
            self.state != .active)
            return error.InvalidState;
        self.state = .stopping;
        self.shutdown_deadline_ns = std.math.add(i64, now_ns, self.plan.shutdown_grace_ns) catch
            std.math.maxInt(i64);
    }

    pub fn poll(self: *HostSupervisor, now_ns: i64) Result {
        return switch (self.state) {
            .starting => if (now_ns -| self.phase_started_ns > self.plan.startup_timeout_ns) blk: {
                self.state = .failed;
                break :blk .timed_out;
            } else .no_change,
            .ready_for_recovery, .recovering, .recovered, .active => if (now_ns -| self.last_heartbeat_ns > self.plan.hang_timeout_ns) blk: {
                self.state = .failed;
                break :blk .timed_out;
            } else .no_change,
            .stopping => if (now_ns > self.shutdown_deadline_ns) blk: {
                self.state = .failed;
                break :blk .force_kill;
            } else .no_change,
            else => .no_change,
        };
    }

    pub fn processExited(self: *HostSupervisor, clean: bool) void {
        self.state = if (clean and self.state == .stopped) .stopped else .failed;
    }

    pub fn restart(self: *HostSupervisor, generation: u64, now_ns: i64) !void {
        if (self.state != .failed and self.state != .stopped) return error.InvalidState;
        if (generation <= self.plan.session.generation) return error.GenerationDidNotAdvance;
        self.plan.session.generation = generation;
        self.state = .starting;
        self.next_host_sequence = 1;
        self.next_zig_sequence = 1;
        self.phase_started_ns = now_ns;
        self.last_heartbeat_ns = 0;
        self.shutdown_deadline_ns = 0;
        self.last_recovered = null;
        self.last_fault = null;
        self.recovery_required = null;
    }

    pub fn validatesEnvelope(self: HostSupervisor, kind: EvidenceKind, session: ipc.Session) bool {
        if (!sameSession(session, self.plan.session)) return false;
        return switch (kind) {
            .intent, .confirmation => self.state == .active,
            .checkpoint => self.state == .ready_for_recovery or self.state == .recovering or
                self.state == .recovered or self.state == .active,
        };
    }

    pub fn encodePlanFrame(self: *HostSupervisor, destination: []u8) ![]u8 {
        if (self.state != .starting or self.next_zig_sequence != 1) return error.InvalidState;
        var payload: [plan_len]u8 = undefined;
        encodePlan(self.plan, &payload);
        const frame = try encodeControl(destination, .session_plan, self.plan.session, 1, &payload);
        self.next_zig_sequence = 2;
        return frame;
    }

    pub fn encodeShutdownFrame(self: *HostSupervisor, destination: []u8) ![]u8 {
        if (self.state != .stopping) return error.InvalidState;
        var payload: [16]u8 = @splat(0);
        put(u16, &payload, 0, 1);
        put(i64, &payload, 8, self.shutdown_deadline_ns);
        const frame = try encodeControl(
            destination,
            .shutdown,
            self.plan.session,
            self.next_zig_sequence,
            &payload,
        );
        self.next_zig_sequence += 1;
        return frame;
    }

    pub fn encodeBeginRecoveryFrame(
        self: *HostSupervisor,
        destination: []u8,
        barrier: u64,
        checkpoint: []const u8,
    ) ![]u8 {
        if (self.state != .ready_for_recovery or checkpoint.len == 0 or
            checkpoint.len + 8 > max_checkpoint_payload)
            return error.InvalidState;
        const total_len = control_header_len + 8 + checkpoint.len;
        if (destination.len < total_len) return error.ControlFrameTooLarge;
        const frame = destination[0..total_len];
        @memset(frame[0..control_header_len], 0);
        put(u64, frame, control_header_len, barrier);
        @memcpy(frame[control_header_len + 8 ..], checkpoint);
        encodeControlHeader(
            frame,
            .begin_recovery,
            self.plan.session,
            self.next_zig_sequence,
            8 + checkpoint.len,
        );
        self.next_zig_sequence += 1;
        self.state = .recovering;
        return frame;
    }

    pub fn encodeActivateFrame(
        self: *HostSupervisor,
        destination: []u8,
        activation: Activation,
    ) ![]u8 {
        if (self.state != .recovered or activation.activation_identity == 0)
            return error.InvalidState;
        var payload: [72]u8 = @splat(0);
        put(u128, &payload, 0, activation.strategy_identity);
        put(u128, &payload, 16, activation.activation_identity);
        put(u64, &payload, 32, activation.barrier);
        @memcpy(payload[40..72], &activation.state_digest);
        const frame = try encodeControl(
            destination,
            .activate_strategy,
            self.plan.session,
            self.next_zig_sequence,
            &payload,
        );
        self.next_zig_sequence += 1;
        self.state = .active;
        return frame;
    }

    fn acceptHello(self: *HostSupervisor, payload: []const u8, now_ns: i64) Result {
        if (self.state != .starting or payload.len != hello_len) {
            self.state = .failed;
            return .protocol_error;
        }
        var expected_plan: [plan_len]u8 = undefined;
        encodePlan(self.plan, &expected_plan);
        var expected_digest: [32]u8 = undefined;
        Sha256.hash(&expected_plan, &expected_digest, .{});
        const compatible =
            get(u128, payload, 0) == self.plan.compatibility.host_build and
            get(u128, payload, 16) == self.plan.compatibility.schema_registry and
            get(u64, payload, 32) == self.plan.session.fencing and
            get(u32, payload, 40) == self.plan.session.shard and
            get(u16, payload, 44) == self.plan.compatibility.protocol and
            get(u16, payload, 46) == 0 and
            get(u64, payload, 48) == self.plan.session.generation and
            get(u32, payload, 56) == self.plan.compatibility.python_abi and
            get(u32, payload, 60) == 0 and
            std.mem.eql(u8, payload[64..96], &self.plan.compatibility.strategy_manifest) and
            std.mem.eql(u8, payload[96..128], &self.plan.compatibility.checkpoint_manifest) and
            std.mem.eql(u8, payload[128..160], &expected_digest);
        if (!compatible) {
            self.state = .failed;
            return .incompatible;
        }
        self.state = .ready_for_recovery;
        self.last_heartbeat_ns = now_ns;
        return .accepted;
    }

    fn acceptHeartbeat(self: *HostSupervisor, payload: []const u8, now_ns: i64) Result {
        if ((self.state != .ready_for_recovery and self.state != .recovering and
            self.state != .recovered and self.state != .active) or
            payload.len != 16 or now_ns < self.last_heartbeat_ns)
        {
            self.state = .failed;
            return .protocol_error;
        }
        self.last_heartbeat_ns = now_ns;
        return .accepted;
    }

    fn acceptStrategyRecovered(self: *HostSupervisor, payload: []const u8) Result {
        if (self.state != .recovering or payload.len != 96 or
            get(u32, payload, 44) != 0 or get(u64, payload, 56) == 0)
        {
            self.state = .failed;
            return .protocol_error;
        }
        self.last_recovered = .{
            .strategy_identity = get(u128, payload, 0),
            .config_version = get(u64, payload, 16),
            .state_schema_identity = get(u128, payload, 24),
            .state_schema_version = get(u32, payload, 40),
            .cursor = get(u64, payload, 48),
            .next_intent_sequence = get(u64, payload, 56),
            .state_digest = payload[64..96].*,
        };
        self.state = .recovered;
        return .accepted;
    }

    fn acceptStrategyFaulted(self: *HostSupervisor, payload: []const u8) Result {
        if (self.state != .active or payload.len < 40 or payload.len > 40 + 4 * 1024 or
            get(u32, payload, 20) != 0 or get(u32, payload, 32) != 0 or
            get(u16, payload, 36) != payload.len - 40 or get(u16, payload, 38) != 0)
        {
            self.state = .failed;
            return .protocol_error;
        }
        var digest: [32]u8 = undefined;
        Sha256.hash(payload[40..], &digest, .{});
        self.last_fault = .{
            .strategy_identity = get(u128, payload, 0),
            .phase = get(u16, payload, 16),
            .reason = get(u16, payload, 18),
            .last_valid_cursor = get(u64, payload, 24),
            .diagnostic_len = get(u16, payload, 36),
            .diagnostic_digest = digest,
        };
        return .accepted;
    }

    fn acceptRecoveryRequired(self: *HostSupervisor, payload: []const u8) Result {
        if ((self.state != .ready_for_recovery and self.state != .recovering and
            self.state != .recovered and self.state != .active) or
            payload.len != 24 or get(u32, payload, 4) != 0)
        {
            self.state = .failed;
            return .protocol_error;
        }
        self.recovery_required = .{
            .scope = get(u16, payload, 0),
            .reason = get(u16, payload, 2),
            .last_batch_sequence = get(u64, payload, 8),
            .last_valid_cursor = get(u64, payload, 16),
        };
        self.state = .failed;
        return .accepted;
    }

    fn acceptShutdownAck(self: *HostSupervisor, payload: []const u8) Result {
        if (self.state != .stopping or payload.len != 0) {
            self.state = .failed;
            return .protocol_error;
        }
        self.state = .stopped;
        return .accepted;
    }
};

const DecodedControl = struct {
    message_type: MessageType,
    session: ipc.Session,
    sequence: u64,
    payload: []const u8,
};

fn encodePlan(plan: Plan, destination: *[plan_len]u8) void {
    @memset(destination, 0);
    put(u128, destination, 0, plan.decision_domain);
    put(u128, destination, 16, plan.compatibility.schema_registry);
    put(u128, destination, 32, plan.compatibility.host_build);
    put(u64, destination, 48, plan.session.fencing);
    put(u32, destination, 56, plan.session.shard);
    put(u16, destination, 60, plan.compatibility.protocol);
    put(u64, destination, 64, plan.session.generation);
    put(u32, destination, 72, plan.compatibility.python_abi);
    put(u32, destination, 76, plan.input_slots);
    put(u32, destination, 80, plan.input_capacity);
    put(u32, destination, 84, plan.output_slots);
    put(u32, destination, 88, plan.output_capacity);
    put(u32, destination, 92, @intCast(@divExact(plan.heartbeat_interval_ns, std.time.ns_per_ms)));
    put(u32, destination, 96, @intCast(@divExact(plan.hang_timeout_ns, std.time.ns_per_ms)));
    put(u32, destination, 100, @intCast(@divExact(plan.shutdown_grace_ns, std.time.ns_per_ms)));
    put(u32, destination, 104, @intCast(@divExact(plan.startup_timeout_ns, std.time.ns_per_ms)));
    @memcpy(destination[112..144], &plan.compatibility.strategy_manifest);
    @memcpy(destination[144..176], &plan.compatibility.checkpoint_manifest);
}

fn encodeHello(plan: Plan, actual: Compatibility, destination: *[hello_len]u8) void {
    @memset(destination, 0);
    put(u128, destination, 0, actual.host_build);
    put(u128, destination, 16, actual.schema_registry);
    put(u64, destination, 32, plan.session.fencing);
    put(u32, destination, 40, plan.session.shard);
    put(u16, destination, 44, actual.protocol);
    put(u64, destination, 48, plan.session.generation);
    put(u32, destination, 56, actual.python_abi);
    @memcpy(destination[64..96], &actual.strategy_manifest);
    @memcpy(destination[96..128], &actual.checkpoint_manifest);
    var plan_payload: [plan_len]u8 = undefined;
    encodePlan(plan, &plan_payload);
    Sha256.hash(&plan_payload, destination[128..160], .{});
}

fn encodeControl(
    destination: []u8,
    message_type: MessageType,
    session: ipc.Session,
    sequence: u64,
    payload: []const u8,
) ![]u8 {
    const total_len = control_header_len + payload.len;
    if (payload.len > max_control_payload or destination.len < total_len) return error.ControlFrameTooLarge;
    const frame = destination[0..total_len];
    @memset(frame[0..control_header_len], 0);
    @memcpy(frame[control_header_len..], payload);
    encodeControlHeader(frame, message_type, session, sequence, payload.len);
    return frame;
}

fn encodeControlHeader(
    frame: []u8,
    message_type: MessageType,
    session: ipc.Session,
    sequence: u64,
    payload_len: usize,
) void {
    @memcpy(frame[0..4], &control_magic);
    put(u16, frame, 4, protocol_version);
    put(u16, frame, 6, control_header_len);
    put(u16, frame, 8, @intFromEnum(message_type));
    put(u16, frame, 10, 1);
    put(u32, frame, 16, @intCast(frame.len));
    put(u32, frame, 20, @intCast(payload_len));
    put(u64, frame, 24, session.fencing);
    put(u32, frame, 32, session.shard);
    put(u64, frame, 40, session.generation);
    put(u64, frame, 48, sequence);
    put(u32, frame, 56, Crc32c.hash(frame[control_header_len..]));
    put(u32, frame, 60, Crc32c.hash(frame[0..60]));
}

fn decodeControl(frame: []const u8) !DecodedControl {
    if (frame.len < control_header_len or frame.len > control_header_len + max_control_payload or
        !std.mem.eql(u8, frame[0..4], &control_magic) or
        get(u16, frame, 4) != protocol_version or get(u16, frame, 6) != control_header_len or
        get(u16, frame, 10) != 1 or get(u32, frame, 12) != 0 or
        get(u32, frame, 16) != frame.len or get(u32, frame, 20) != frame.len - control_header_len or
        get(u32, frame, 36) != 0 or Crc32c.hash(frame[0..60]) != get(u32, frame, 60) or
        Crc32c.hash(frame[64..]) != get(u32, frame, 56))
        return error.InvalidControlFrame;
    return .{
        .message_type = std.enums.fromInt(MessageType, get(u16, frame, 8)) orelse
            return error.InvalidControlFrame,
        .session = .{
            .fencing = get(u64, frame, 24),
            .shard = get(u32, frame, 32),
            .generation = get(u64, frame, 40),
        },
        .sequence = get(u64, frame, 48),
        .payload = frame[64..],
    };
}

pub const ManagedHost = struct {
    child: std.process.Child,
    input_mapping: ipc.OwnedMapping,
    output_mapping: ipc.OwnedMapping,
    supervisor: HostSupervisor,

    pub fn start(
        init: std.process.Init,
        python: []const u8,
        script: []const u8,
        plan: Plan,
        mode: []const u8,
        extra_args: []const []const u8,
    ) !ManagedHost {
        var input_mapping = try ipc.OwnedMapping.create(.input, plan.session, plan.input_slots, plan.input_capacity);
        errdefer input_mapping.deinit();
        var output_mapping = try ipc.OwnedMapping.create(.output, plan.session, plan.output_slots, plan.output_capacity);
        errdefer output_mapping.deinit();
        var input_text: [32]u8 = undefined;
        var output_text: [32]u8 = undefined;
        var argv: [24][]const u8 = undefined;
        if (8 + extra_args.len > argv.len) return error.TooManyHostArguments;
        argv[0..8].* = .{
            python,
            script,
            "--mode",
            mode,
            "--input-mapping",
            try std.fmt.bufPrint(&input_text, "{d}", .{input_mapping.raw}),
            "--output-mapping",
            try std.fmt.bufPrint(&output_text, "{d}", .{output_mapping.raw}),
        };
        @memcpy(argv[8..][0..extra_args.len], extra_args);
        const child = try std.process.spawn(init.io, .{
            .argv = argv[0 .. 8 + extra_args.len],
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .create_no_window = true,
        });
        return .{
            .child = child,
            .input_mapping = input_mapping,
            .output_mapping = output_mapping,
            .supervisor = try HostSupervisor.init(plan, 0),
        };
    }

    pub fn sendPlan(self: *ManagedHost, io: std.Io) !void {
        var frame_storage: [4 + control_header_len + plan_len]u8 = undefined;
        const frame = try self.supervisor.encodePlanFrame(frame_storage[4..]);
        put(u32, &frame_storage, 0, @intCast(frame.len));
        try self.child.stdin.?.writeStreamingAll(io, frame_storage[0 .. 4 + frame.len]);
    }

    pub fn receive(self: *ManagedHost, io: std.Io, now_ns: i64) !Result {
        var frame_storage: [control_header_len + max_control_payload]u8 = undefined;
        const frame = try readPipeFrame(self.child.stdout.?, io, &frame_storage);
        return self.supervisor.acceptHostFrame(frame, now_ns);
    }

    pub fn beginRecovery(
        self: *ManagedHost,
        io: std.Io,
        barrier: u64,
        checkpoint: []const u8,
        frame_storage: []u8,
    ) !void {
        const frame = try self.supervisor.encodeBeginRecoveryFrame(
            frame_storage,
            barrier,
            checkpoint,
        );
        try writePipeFrame(self.child.stdin.?, io, frame);
    }

    pub fn activate(
        self: *ManagedHost,
        io: std.Io,
        activation: Activation,
    ) !void {
        var frame_storage: [control_header_len + 72]u8 = undefined;
        const frame = try self.supervisor.encodeActivateFrame(&frame_storage, activation);
        try writePipeFrame(self.child.stdin.?, io, frame);
    }

    pub fn shutdown(self: *ManagedHost, io: std.Io, now_ns: i64) !void {
        try self.supervisor.beginShutdown(now_ns);
        var frame_storage: [4 + control_header_len + 16]u8 = undefined;
        const frame = try self.supervisor.encodeShutdownFrame(frame_storage[4..]);
        put(u32, &frame_storage, 0, @intCast(frame.len));
        try self.child.stdin.?.writeStreamingAll(io, frame_storage[0 .. 4 + frame.len]);
        try expectResult(.accepted, try self.receive(io, now_ns + 1));
        const term = try self.child.wait(io);
        const clean = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        self.supervisor.processExited(clean);
        try std.testing.expectEqual(State.stopped, self.supervisor.state);
    }

    pub fn deinit(self: *ManagedHost, io: std.Io) void {
        self.child.kill(io);
        self.input_mapping.deinit();
        self.output_mapping.deinit();
    }
};

fn writePipeFrame(file: std.Io.File, io: std.Io, frame: []const u8) !void {
    var prefix: [4]u8 = undefined;
    put(u32, &prefix, 0, @intCast(frame.len));
    try file.writeStreamingAll(io, &prefix);
    try file.writeStreamingAll(io, frame);
}

fn readPipeFrame(file: std.Io.File, io: std.Io, storage: []u8) ![]u8 {
    var prefix: [4]u8 = undefined;
    try readExact(file, io, &prefix);
    const len = get(u32, &prefix, 0);
    if (len < control_header_len or len > storage.len) return error.InvalidControlFrame;
    try readExact(file, io, storage[0..len]);
    return storage[0..len];
}

fn readExact(file: std.Io.File, io: std.Io, destination: []u8) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const buffers = [_][]u8{destination[offset..]};
        offset += try file.readStreaming(io, &buffers);
    }
}

pub fn developmentPlan(shard: u32, generation: u64, python_abi: u32) Plan {
    return .{
        .decision_domain = @as(u128, 0xaabbccddeeff00112233445566778899) + shard,
        .session = .{ .fencing = 77, .shard = shard, .generation = generation },
        .compatibility = .{
            .protocol = protocol_version,
            .schema_registry = schema_registry_id,
            .host_build = host_build_identity,
            .python_abi = python_abi,
            .strategy_manifest = strategy_manifest,
            .checkpoint_manifest = checkpoint_manifest,
        },
        .input_slots = 4,
        .input_capacity = 512,
        .output_slots = 4,
        .output_capacity = 512,
        .heartbeat_interval_ns = 10 * std.time.ns_per_ms,
        .startup_timeout_ns = 100 * std.time.ns_per_ms,
        .hang_timeout_ns = 50 * std.time.ns_per_ms,
        .shutdown_grace_ns = 20 * std.time.ns_per_ms,
    };
}

fn pureChecks(python_abi: u32) !void {
    const actual = developmentPlan(1, 1, python_abi).compatibility;
    var index: usize = 0;
    while (index < 6) : (index += 1) {
        var plan = developmentPlan(1, 1, python_abi);
        switch (index) {
            0 => plan.compatibility.protocol += 1,
            1 => plan.compatibility.schema_registry += 1,
            2 => plan.compatibility.host_build += 1,
            3 => plan.compatibility.python_abi += 1,
            4 => plan.compatibility.strategy_manifest[0] ^= 1,
            5 => plan.compatibility.checkpoint_manifest[0] ^= 1,
            else => unreachable,
        }
        var supervisor = try HostSupervisor.init(plan, 0);
        var hello_payload: [hello_len]u8 = undefined;
        encodeHello(plan, actual, &hello_payload);
        var frame_storage: [control_header_len + hello_len]u8 = undefined;
        const frame = try encodeControl(&frame_storage, .host_hello, plan.session, 1, &hello_payload);
        try expectResult(.incompatible, supervisor.acceptHostFrame(frame, 1));
        try std.testing.expectEqual(State.failed, supervisor.state);
    }

    var plan = developmentPlan(1, 1, python_abi);
    var startup_timeout = try HostSupervisor.init(plan, 0);
    try expectResult(.timed_out, startup_timeout.poll(plan.startup_timeout_ns + 1));
    try std.testing.expectEqual(State.failed, startup_timeout.state);

    var supervisor = try HostSupervisor.init(plan, 0);
    var hello_payload: [hello_len]u8 = undefined;
    encodeHello(plan, plan.compatibility, &hello_payload);
    var frame_storage: [control_header_len + hello_len]u8 = undefined;
    var frame = try encodeControl(&frame_storage, .host_hello, plan.session, 1, &hello_payload);
    try expectResult(.accepted, supervisor.acceptHostFrame(frame, 10));
    try std.testing.expectEqual(State.ready_for_recovery, supervisor.state);
    try std.testing.expect(!supervisor.validatesEnvelope(.intent, .{
        .fencing = plan.session.fencing,
        .shard = plan.session.shard,
        .generation = 0,
    }));

    var old_frame_storage: [control_header_len + 16]u8 = undefined;
    var heartbeat_payload: [16]u8 = @splat(0);
    frame = try encodeControl(&old_frame_storage, .host_heartbeat, .{
        .fencing = plan.session.fencing,
        .shard = plan.session.shard,
        .generation = 0,
    }, 2, &heartbeat_payload);
    try expectResult(.stale_session, supervisor.acceptHostFrame(frame, 11));
    try std.testing.expectEqual(State.ready_for_recovery, supervisor.state);
    try expectResult(.timed_out, supervisor.poll(10 + plan.hang_timeout_ns + 1));
    try supervisor.restart(2, 100);
    plan.session.generation = 2;
    try std.testing.expectEqual(State.starting, supervisor.state);
}

pub fn discoverPythonAbi(init: std.process.Init, python: []const u8) !u32 {
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ python, "-c", "import sys; print((sys.version_info.major << 16) | (sys.version_info.minor << 8))" },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PythonFailed,
        else => return error.PythonFailed,
    }
    return std.fmt.parseInt(u32, std.mem.trim(u8, result.stdout, " \r\n\t"), 10);
}

fn integrationChecks(init: std.process.Init, python: []const u8, script: []const u8, python_abi: u32) !void {
    var hosts: [4]?ManagedHost = @splat(null);
    defer for (&hosts) |*host| if (host.*) |*running| running.deinit(init.io);
    for (&hosts, 0..) |*host, shard| {
        host.* = try ManagedHost.start(
            init,
            python,
            script,
            developmentPlan(@intCast(shard), 1, python_abi),
            "normal",
            &.{},
        );
    }
    for (&hosts) |*host| {
        const running = &host.*.?;
        try running.sendPlan(init.io);
        try expectResult(.accepted, try running.receive(init.io, 1));
        try expectResult(.accepted, try running.receive(init.io, 2));
        try std.testing.expectEqual(State.ready_for_recovery, running.supervisor.state);
    }
    for (&hosts) |*host| try host.*.?.shutdown(init.io, 3);

    var old_session: ipc.Session = undefined;
    {
        var crashed = try ManagedHost.start(
            init,
            python,
            script,
            developmentPlan(0, 9, python_abi),
            "crash",
            &.{},
        );
        defer crashed.deinit(init.io);
        try crashed.sendPlan(init.io);
        try expectResult(.accepted, try crashed.receive(init.io, 10));
        const crash_term = try crashed.child.wait(init.io);
        crashed.supervisor.processExited(switch (crash_term) {
            .exited => |code| code == 0,
            else => false,
        });
        try std.testing.expectEqual(State.failed, crashed.supervisor.state);
        old_session = crashed.supervisor.plan.session;
    }

    var rebuilt = try ManagedHost.start(
        init,
        python,
        script,
        developmentPlan(0, 10, python_abi),
        "normal",
        &.{},
    );
    defer rebuilt.deinit(init.io);
    try rebuilt.sendPlan(init.io);
    try expectResult(.accepted, try rebuilt.receive(init.io, 11));
    try expectResult(.accepted, try rebuilt.receive(init.io, 12));
    var old_heartbeat_payload: [16]u8 = @splat(0);
    var old_frame_storage: [control_header_len + 16]u8 = undefined;
    const old_frame = try encodeControl(
        &old_frame_storage,
        .host_heartbeat,
        old_session,
        rebuilt.supervisor.next_host_sequence,
        &old_heartbeat_payload,
    );
    try expectResult(.stale_session, rebuilt.supervisor.acceptHostFrame(old_frame, 12));
    try std.testing.expectEqual(State.ready_for_recovery, rebuilt.supervisor.state);
    inline for (.{ EvidenceKind.intent, EvidenceKind.confirmation, EvidenceKind.checkpoint }) |kind|
        try std.testing.expect(!rebuilt.supervisor.validatesEnvelope(kind, old_session));
    try rebuilt.shutdown(init.io, 13);

    {
        var hung = try ManagedHost.start(
            init,
            python,
            script,
            developmentPlan(2, 20, python_abi),
            "hang",
            &.{},
        );
        defer hung.deinit(init.io);
        try hung.sendPlan(init.io);
        try expectResult(.accepted, try hung.receive(init.io, 20));
        try expectResult(.accepted, try hung.receive(init.io, 21));
        try expectResult(.timed_out, hung.supervisor.poll(21 + hung.supervisor.plan.hang_timeout_ns + 1));
        hung.child.kill(init.io);
    }

    var after_hang = try ManagedHost.start(
        init,
        python,
        script,
        developmentPlan(2, 21, python_abi),
        "normal",
        &.{},
    );
    defer after_hang.deinit(init.io);
    try after_hang.sendPlan(init.io);
    try expectResult(.accepted, try after_hang.receive(init.io, 30));
    try expectResult(.accepted, try after_hang.receive(init.io, 31));
    try after_hang.shutdown(init.io, 32);
}

fn expectResult(expected: Result, actual: Result) !void {
    if (expected != actual) {
        std.debug.print("expected lifecycle result {s}, got {s}\n", .{ @tagName(expected), @tagName(actual) });
        return error.UnexpectedLifecycleResult;
    }
}

fn sameSession(left: ipc.Session, right: ipc.Session) bool {
    return left.fencing == right.fencing and left.shard == right.shard and
        left.generation == right.generation;
}

fn put(comptime T: type, destination: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, destination[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, source: []const u8, offset: usize) T {
    return std.mem.readInt(T, source[offset..][0..@sizeOf(T)], .little);
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const python = args.next() orelse "python";
    const script = args.next() orelse "python/strategy_host.py";
    if (args.next() != null) return error.UnknownArgument;
    const python_abi = try discoverPythonAbi(init, python);
    try pureChecks(python_abi);
    try integrationChecks(init, python, script, python_abi);
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print(
        "strategy_host_lifecycle: zig={s}, python_abi=0x{x}, hosts=4, handshake=ok, stop=ok, crash_rebuild=ok, hang_rebuild=ok, stale_session=blocked\n",
        .{ builtin.zig_version_string, python_abi },
    );
    try stdout.interface.flush();
}

test "supervisor compatibility, timeout, restart and stale-session fencing" {
    try pureChecks(0x0003_0900);
}
