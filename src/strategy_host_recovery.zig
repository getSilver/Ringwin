const std = @import("std");
const journal = @import("journal.zig");

const Crc32c = std.hash.crc.Crc32Iscsi;
const Sha256 = std.crypto.hash.sha2.Sha256;
const header_len: usize = 192;
const max_payload_len: usize = 8 * 1024 * 1024;
const stale_batch_ns: i64 = 50_000_000;
const magic = "QSSC".*;
const state_domain = "QSSD\x01";

pub const Metadata = struct {
    schema_registry: u128,
    strategy_instance: u128,
    strategy_definition: u128,
    state_schema: u128,
    state_schema_version: u32,
    strategy_config_version: u64,
    strategy_cursor: u64,
    next_intent_sequence: u64,
};

pub const PortableState = struct {
    accumulator: i64,
    event_count: u64,
};

pub const Checkpoint = struct {
    metadata: Metadata,
    state: PortableState,
    identity: [32]u8,
};

pub const ReplayEvent = struct {
    sequence: u64,
    delta: i64,
    would_emit_intent: bool,
};

pub const IntentIdentity = struct {
    strategy_instance: u128,
    sequence: u64,
};

pub const BatchResult = struct {
    intents: [64]IntentIdentity = undefined,
    intent_count: usize = 0,
};

pub const Phase = enum {
    recovering,
    awaiting_activation,
    catching_up,
    active,
    needs_snapshot,
};

pub const Recovered = struct {
    cursor: u64,
    next_intent_sequence: u64,
    state_digest: [32]u8,
};

pub const Recovery = struct {
    metadata: Metadata,
    state: PortableState,
    phase: Phase = .recovering,
    recovery_barrier: u64,
    activation_barrier: u64 = 0,
    activation_identity: u128 = 0,
    suppressed_intents: u64 = 0,

    pub fn begin(container: []const u8, expected: Metadata, barrier: u64) !Recovery {
        const checkpoint = try decodeCheckpoint(container, expected);
        if (barrier < checkpoint.metadata.strategy_cursor) return error.InvalidBarrier;
        return .{
            .metadata = checkpoint.metadata,
            .state = checkpoint.state,
            .recovery_barrier = barrier,
        };
    }

    pub fn apply(self: *Recovery, event: ReplayEvent) !?IntentIdentity {
        const result = try self.applyBatch(event.sequence, event.sequence, &.{event});
        return if (result.intent_count == 0) null else result.intents[0];
    }

    pub fn applyBatch(
        self: *Recovery,
        first_sequence: u64,
        last_sequence: u64,
        events: []const ReplayEvent,
    ) !BatchResult {
        if (self.phase == .needs_snapshot or self.phase == .awaiting_activation)
            return error.InvalidRecoveryPhase;
        if (self.metadata.strategy_cursor == std.math.maxInt(u64) or
            first_sequence != self.metadata.strategy_cursor + 1 or
            first_sequence > last_sequence or
            (self.phase == .recovering and last_sequence > self.recovery_barrier) or
            (self.phase == .catching_up and last_sequence > self.activation_barrier))
        {
            self.phase = .needs_snapshot;
            return error.SequenceGap;
        }
        var previous: ?u64 = null;
        for (events) |event| {
            if (event.sequence < first_sequence or event.sequence > last_sequence or
                (previous != null and event.sequence <= previous.?))
            {
                self.phase = .needs_snapshot;
                return error.InvalidReplayEvent;
            }
            previous = event.sequence;
        }

        var candidate = self.*;
        var result: BatchResult = .{};
        const allow_output = candidate.phase == .active;
        for (events) |event| {
            candidate.state.accumulator = std.math.add(
                i64,
                candidate.state.accumulator,
                event.delta,
            ) catch {
                self.phase = .needs_snapshot;
                return error.StateOverflow;
            };
            candidate.state.event_count = std.math.add(
                u64,
                candidate.state.event_count,
                1,
            ) catch {
                self.phase = .needs_snapshot;
                return error.StateOverflow;
            };
            if (!event.would_emit_intent) continue;
            const identity: IntentIdentity = .{
                .strategy_instance = candidate.metadata.strategy_instance,
                .sequence = candidate.metadata.next_intent_sequence,
            };
            candidate.metadata.next_intent_sequence = std.math.add(
                u64,
                candidate.metadata.next_intent_sequence,
                1,
            ) catch {
                self.phase = .needs_snapshot;
                return error.StateOverflow;
            };
            if (allow_output) {
                if (result.intent_count == result.intents.len) {
                    self.phase = .needs_snapshot;
                    return error.TooManyIntents;
                }
                result.intents[result.intent_count] = identity;
                result.intent_count += 1;
            } else {
                candidate.suppressed_intents = std.math.add(
                    u64,
                    candidate.suppressed_intents,
                    1,
                ) catch {
                    self.phase = .needs_snapshot;
                    return error.StateOverflow;
                };
            }
        }
        candidate.metadata.strategy_cursor = last_sequence;
        if (candidate.phase == .catching_up and last_sequence == candidate.activation_barrier)
            candidate.phase = .active;
        if (allow_output and first_sequence <= candidate.activation_barrier) {
            self.phase = .needs_snapshot;
            return error.InvalidActivation;
        }
        self.* = candidate;
        return result;
    }

    pub fn finishRecovery(self: *Recovery) !Recovered {
        if (self.phase != .recovering or self.metadata.strategy_cursor != self.recovery_barrier)
            return error.BarrierNotReached;
        self.phase = .awaiting_activation;
        return self.report();
    }

    pub fn authorize(
        self: *Recovery,
        activation_identity: u128,
        activation_barrier: u64,
        expected_digest: [32]u8,
    ) !void {
        if (self.phase != .awaiting_activation or activation_identity == 0 or
            activation_barrier < self.metadata.strategy_cursor or
            !std.mem.eql(u8, &expected_digest, &self.report().state_digest))
            return error.InvalidActivation;
        self.activation_identity = activation_identity;
        self.activation_barrier = activation_barrier;
        self.phase = if (activation_barrier == self.metadata.strategy_cursor)
            .active
        else
            .catching_up;
    }

    pub fn markInputInvalid(self: *Recovery) void {
        self.phase = .needs_snapshot;
    }

    pub fn checkBatchAge(self: *Recovery, published_ns: i64, now_ns: i64) !void {
        if (published_ns < 0 or now_ns < published_ns or
            now_ns - published_ns > stale_batch_ns)
        {
            self.markInputInvalid();
            return error.StaleBatch;
        }
    }

    pub fn canTrade(self: Recovery) bool {
        return self.phase == .active;
    }

    pub fn report(self: Recovery) Recovered {
        var payload_storage: [96]u8 = undefined;
        const payload = encodeState(&payload_storage, self.state) catch unreachable;
        return .{
            .cursor = self.metadata.strategy_cursor,
            .next_intent_sequence = self.metadata.next_intent_sequence,
            .state_digest = stateDigest(self.metadata, payload),
        };
    }
};

pub fn encodeCheckpoint(destination: []u8, metadata: Metadata, state: PortableState) ![]u8 {
    if (metadata.next_intent_sequence == 0) return error.InvalidIntentSequence;
    var payload_storage: [96]u8 = undefined;
    const payload = try encodeState(&payload_storage, state);
    const total_len = header_len + payload.len;
    if (destination.len < total_len) return error.CheckpointTooLarge;
    const container = destination[0..total_len];
    @memset(container[0..header_len], 0);
    @memcpy(container[0..4], &magic);
    put(u16, container, 4, 1);
    put(u16, container, 6, header_len);
    put(u32, container, 12, @intCast(total_len));
    put(u128, container, 16, metadata.schema_registry);
    put(u128, container, 32, metadata.strategy_instance);
    put(u128, container, 48, metadata.strategy_definition);
    put(u128, container, 64, metadata.state_schema);
    put(u32, container, 80, metadata.state_schema_version);
    put(u16, container, 84, 1);
    put(u64, container, 88, metadata.strategy_config_version);
    put(u64, container, 96, metadata.strategy_cursor);
    put(u64, container, 104, metadata.next_intent_sequence);
    put(u32, container, 112, @intCast(payload.len));
    put(u32, container, 116, Crc32c.hash(payload));
    @memcpy(container[header_len..], payload);
    var identity: [32]u8 = undefined;
    var sha = Sha256.init(.{});
    sha.update(container[0..120]);
    sha.update(payload);
    sha.final(&identity);
    @memcpy(container[120..152], &identity);
    put(u32, container, 188, Crc32c.hash(container[0..188]));
    return container;
}

pub fn decodeCheckpoint(container: []const u8, expected: Metadata) !Checkpoint {
    if (container.len < header_len or container.len > header_len + max_payload_len or
        !std.mem.eql(u8, container[0..4], &magic) or
        get(u16, container, 4) != 1 or get(u16, container, 6) != header_len or
        get(u32, container, 8) != 0 or get(u32, container, 12) != container.len or
        get(u16, container, 84) != 1 or get(u16, container, 86) != 0 or
        get(u32, container, 112) != container.len - header_len or
        !allZero(container[152..188]) or
        get(u32, container, 188) != Crc32c.hash(container[0..188]))
        return error.InvalidCheckpoint;
    const payload = container[header_len..];
    if (get(u32, container, 116) != Crc32c.hash(payload)) return error.InvalidCheckpoint;
    var identity: [32]u8 = undefined;
    var sha = Sha256.init(.{});
    sha.update(container[0..120]);
    sha.update(payload);
    sha.final(&identity);
    if (!std.mem.eql(u8, &identity, container[120..152])) return error.InvalidCheckpoint;

    const metadata: Metadata = .{
        .schema_registry = get(u128, container, 16),
        .strategy_instance = get(u128, container, 32),
        .strategy_definition = get(u128, container, 48),
        .state_schema = get(u128, container, 64),
        .state_schema_version = get(u32, container, 80),
        .strategy_config_version = get(u64, container, 88),
        .strategy_cursor = get(u64, container, 96),
        .next_intent_sequence = get(u64, container, 104),
    };
    if (!sameMetadata(metadata, expected) or metadata.next_intent_sequence == 0)
        return error.CheckpointMismatch;
    return .{
        .metadata = metadata,
        .state = try decodeState(payload),
        .identity = identity,
    };
}

pub fn replayJournal(recovery: *Recovery, bytes: []const u8) !void {
    var reader = try journal.Reader.init(bytes);
    while (true) switch (try reader.next()) {
        .record => |record| {
            if (record.sequence <= recovery.metadata.strategy_cursor or
                record.sequence > recovery.recovery_barrier or
                record.flags & journal.input_flag == 0)
                continue;
            if (record.payload.len != 9) {
                recovery.markInputInvalid();
                return error.InvalidReplayEvent;
            }
            const event: ReplayEvent = .{
                .sequence = record.sequence,
                .delta = get(i64, record.payload, 0),
                .would_emit_intent = switch (record.payload[8]) {
                    0 => false,
                    1 => true,
                    else => {
                        recovery.markInputInvalid();
                        return error.InvalidReplayEvent;
                    },
                },
            };
            _ = try recovery.applyBatch(
                recovery.metadata.strategy_cursor + 1,
                record.sequence,
                &.{event},
            );
        },
        .end => |status| {
            if (status != .clean) {
                recovery.markInputInvalid();
                return error.IncompleteReplayLog;
            }
            return;
        },
    };
}

fn encodeState(destination: []u8, state: PortableState) ![]u8 {
    return std.fmt.bufPrint(
        destination,
        "{{\"accumulator\":{d},\"event_count\":{d}}}",
        .{ state.accumulator, state.event_count },
    );
}

fn decodeState(payload: []const u8) !PortableState {
    const prefix = "{\"accumulator\":";
    const middle = ",\"event_count\":";
    if (!std.mem.startsWith(u8, payload, prefix) or !std.mem.endsWith(u8, payload, "}"))
        return error.InvalidPortableState;
    const split = std.mem.indexOfPos(u8, payload, prefix.len, middle) orelse
        return error.InvalidPortableState;
    const state: PortableState = .{
        .accumulator = try std.fmt.parseInt(i64, payload[prefix.len..split], 10),
        .event_count = try std.fmt.parseInt(
            u64,
            payload[split + middle.len .. payload.len - 1],
            10,
        ),
    };
    var canonical_storage: [96]u8 = undefined;
    const canonical = try encodeState(&canonical_storage, state);
    if (!std.mem.eql(u8, payload, canonical)) return error.NonCanonicalPortableState;
    return state;
}

fn stateDigest(metadata: Metadata, payload: []const u8) [32]u8 {
    var sha = Sha256.init(.{});
    sha.update(state_domain);
    hashInt(&sha, u128, metadata.schema_registry);
    hashInt(&sha, u128, metadata.strategy_instance);
    hashInt(&sha, u128, metadata.strategy_definition);
    hashInt(&sha, u128, metadata.state_schema);
    hashInt(&sha, u32, metadata.state_schema_version);
    hashInt(&sha, u64, metadata.strategy_config_version);
    hashInt(&sha, u64, metadata.strategy_cursor);
    hashInt(&sha, u64, metadata.next_intent_sequence);
    hashInt(&sha, u32, @intCast(payload.len));
    sha.update(payload);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    return digest;
}

fn hashInt(sha: *Sha256, comptime T: type, value: T) void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    sha.update(&encoded);
}

fn sameMetadata(actual: Metadata, expected: Metadata) bool {
    return actual.schema_registry == expected.schema_registry and
        actual.strategy_instance == expected.strategy_instance and
        actual.strategy_definition == expected.strategy_definition and
        actual.state_schema == expected.state_schema and
        actual.state_schema_version == expected.state_schema_version and
        actual.strategy_config_version == expected.strategy_config_version and
        actual.strategy_cursor == expected.strategy_cursor and
        actual.next_intent_sequence == expected.next_intent_sequence;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn put(comptime T: type, destination: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, destination[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, source: []const u8, offset: usize) T {
    return std.mem.readInt(T, source[offset..][0..@sizeOf(T)], .little);
}

test "checkpoint replay is deterministic and fenced until cutover" {
    const metadata: Metadata = .{
        .schema_registry = 1,
        .strategy_instance = 2,
        .strategy_definition = 3,
        .state_schema = 4,
        .state_schema_version = 1,
        .strategy_config_version = 7,
        .strategy_cursor = 2,
        .next_intent_sequence = 5,
    };
    var checkpoint_storage: [512]u8 = undefined;
    const checkpoint = try encodeCheckpoint(&checkpoint_storage, metadata, .{
        .accumulator = 30,
        .event_count = 2,
    });
    var same_storage: [512]u8 = undefined;
    const same_checkpoint = try encodeCheckpoint(&same_storage, metadata, .{
        .accumulator = 30,
        .event_count = 2,
    });
    try std.testing.expectEqualSlices(u8, checkpoint, same_checkpoint);

    var log = journal.Journal.init();
    for (1..7) |sequence| {
        var payload: [9]u8 = undefined;
        put(i64, &payload, 0, @intCast(sequence * 10));
        payload[8] = if (sequence == 4 or sequence == 6) 1 else 0;
        try log.append(.{
            .type_id = 1,
            .schema_version = 1,
            .flags = journal.input_flag,
            .sequence = sequence,
            .source_time = 0,
            .receive_time = 0,
            .monotonic_time = 0,
            .wall_time = 0,
            .time_presence = .{},
            .payload = &payload,
        });
    }
    try log.seal();

    var first = try Recovery.begin(checkpoint, metadata, 5);
    try replayJournal(&first, log.bytes());
    const first_report = try first.finishRecovery();
    try std.testing.expectEqual(@as(u64, 1), first.suppressed_intents);
    try first.authorize(9, 6, first_report.state_digest);
    try std.testing.expect(!first.canTrade());
    try std.testing.expect((try first.apply(.{
        .sequence = 6,
        .delta = 60,
        .would_emit_intent = true,
    })) == null);
    try std.testing.expect(first.canTrade());
    const first_live = (try first.apply(.{
        .sequence = 7,
        .delta = 70,
        .would_emit_intent = true,
    })).?;

    var second = try Recovery.begin(checkpoint, metadata, 5);
    try replayJournal(&second, log.bytes());
    const second_report = try second.finishRecovery();
    try second.authorize(9, 6, second_report.state_digest);
    _ = try second.apply(.{ .sequence = 6, .delta = 60, .would_emit_intent = true });
    const second_live = (try second.apply(.{
        .sequence = 7,
        .delta = 70,
        .would_emit_intent = true,
    })).?;
    try std.testing.expectEqual(first_live, second_live);
    try std.testing.expectEqualDeep(first.report(), second.report());

    var damaged: [512]u8 = undefined;
    @memcpy(damaged[0..checkpoint.len], checkpoint);
    damaged[header_len] ^= 1;
    try std.testing.expectError(
        error.InvalidCheckpoint,
        decodeCheckpoint(damaged[0..checkpoint.len], metadata),
    );

    var gap = try Recovery.begin(checkpoint, metadata, 5);
    try std.testing.expectError(error.SequenceGap, gap.apply(.{
        .sequence = 4,
        .delta = 1,
        .would_emit_intent = true,
    }));
    try std.testing.expectEqual(Phase.needs_snapshot, gap.phase);
    try std.testing.expect(!gap.canTrade());

    var fresh = try Recovery.begin(checkpoint, metadata, 5);
    try fresh.checkBatchAge(100, 50_000_100);
    var stale = try Recovery.begin(checkpoint, metadata, 5);
    try std.testing.expectError(error.StaleBatch, stale.checkBatchAge(100, 50_000_101));
    try std.testing.expectEqual(Phase.needs_snapshot, stale.phase);

    var filtered = try Recovery.begin(checkpoint, metadata, 5);
    _ = try filtered.applyBatch(3, 5, &.{.{
        .sequence = 4,
        .delta = 40,
        .would_emit_intent = false,
    }});
    try std.testing.expectEqual(@as(u64, 5), (try filtered.finishRecovery()).cursor);
}
