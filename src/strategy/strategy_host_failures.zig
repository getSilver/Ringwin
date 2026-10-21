const std = @import("std");
const recovery = @import("strategy_host_recovery.zig");

pub const Strategy = struct {
    identity: u128,
    cursor: u64,
    value: i64,
    next_intent_sequence: u64,
    enabled: bool = true,
};

pub const Intent = struct {
    strategy_identity: u128,
    sequence: u64,
};

pub const Fault = struct {
    strategy_identity: u128,
    cursor: u64,
    phase: u16 = 1,
    reason: u16 = 1,
};

pub const BatchOutcome = struct {
    intents: [4]Intent = undefined,
    intent_count: usize = 0,
    fault: ?Fault = null,
};

pub const StrategySet = struct {
    strategies: [2]Strategy,

    pub fn apply(
        self: *StrategySet,
        sequence: u64,
        fault_strategy: ?u128,
    ) !BatchOutcome {
        var outcome: BatchOutcome = .{};
        for (&self.strategies) |*strategy| {
            if (!strategy.enabled) continue;
            if (strategy.cursor == std.math.maxInt(u64) or sequence != strategy.cursor + 1)
                return error.SequenceGap;

            var candidate = strategy.*;
            candidate.value = try std.math.add(i64, candidate.value, 1);
            const intent: Intent = .{
                .strategy_identity = candidate.identity,
                .sequence = candidate.next_intent_sequence,
            };
            candidate.next_intent_sequence = try std.math.add(
                u64,
                candidate.next_intent_sequence,
                1,
            );

            if (fault_strategy != null and candidate.identity == fault_strategy.?) {
                strategy.enabled = false;
                outcome.fault = .{
                    .strategy_identity = strategy.identity,
                    .cursor = strategy.cursor,
                };
                continue;
            }
            candidate.cursor = sequence;
            strategy.* = candidate;
            outcome.intents[outcome.intent_count] = intent;
            outcome.intent_count += 1;
        }
        return outcome;
    }
};

pub const CheckpointCandidate = struct {
    container: []const u8,
    metadata: recovery.Metadata,
};

pub const CheckpointChoice = union(enum) {
    checkpoint: usize,
    rebuild,
    disabled,
};

pub fn chooseCheckpoint(
    candidates_newest_first: []const CheckpointCandidate,
    target: recovery.Metadata,
    supports_rebuild: bool,
    history_complete: bool,
) CheckpointChoice {
    for (candidates_newest_first, 0..) |candidate, index| {
        _ = recovery.decodeCheckpoint(candidate.container, candidate.metadata) catch continue;
        if (sameStrategy(candidate.metadata, target)) return .{ .checkpoint = index };
    }
    return if (supports_rebuild and history_complete) .rebuild else .disabled;
}

fn sameStrategy(actual: recovery.Metadata, target: recovery.Metadata) bool {
    return actual.schema_registry == target.schema_registry and
        actual.strategy_instance == target.strategy_instance and
        actual.strategy_definition == target.strategy_definition and
        actual.state_schema == target.state_schema and
        actual.state_schema_version == target.state_schema_version and
        actual.strategy_config_version == target.strategy_config_version;
}

test "strategy exception is transactional and checkpoint fallback is explicit" {
    var runtime: StrategySet = .{ .strategies = .{
        .{ .identity = 1, .cursor = 104, .value = 10, .next_intent_sequence = 7 },
        .{ .identity = 2, .cursor = 104, .value = 20, .next_intent_sequence = 9 },
    } };
    const outcome = try runtime.apply(105, 1);
    try std.testing.expectEqual(@as(usize, 1), outcome.intent_count);
    try std.testing.expectEqual(@as(u128, 2), outcome.intents[0].strategy_identity);
    try std.testing.expectEqual(@as(u64, 9), outcome.intents[0].sequence);
    try std.testing.expectEqual(@as(u64, 104), runtime.strategies[0].cursor);
    try std.testing.expectEqual(@as(i64, 10), runtime.strategies[0].value);
    try std.testing.expect(!runtime.strategies[0].enabled);
    try std.testing.expectEqual(@as(u64, 105), runtime.strategies[1].cursor);
    try std.testing.expectEqual(@as(i64, 21), runtime.strategies[1].value);

    const metadata: recovery.Metadata = .{
        .schema_registry = 1,
        .strategy_instance = 2,
        .strategy_definition = 3,
        .state_schema = 4,
        .state_schema_version = 1,
        .strategy_config_version = 5,
        .strategy_cursor = 100,
        .next_intent_sequence = 7,
    };
    var older_storage: [512]u8 = undefined;
    const older = try recovery.encodeCheckpoint(
        &older_storage,
        metadata,
        .{ .accumulator = 1, .event_count = 2 },
    );
    var newer_metadata = metadata;
    newer_metadata.strategy_cursor = 120;
    newer_metadata.next_intent_sequence = 8;
    var newer_storage: [512]u8 = undefined;
    const newer = try recovery.encodeCheckpoint(
        &newer_storage,
        newer_metadata,
        .{ .accumulator = 3, .event_count = 4 },
    );
    var header_damage = newer_storage;
    header_damage[0] ^= 1;
    var payload_damage = newer_storage;
    payload_damage[192] ^= 1;
    var wrong_schema_metadata = newer_metadata;
    wrong_schema_metadata.state_schema += 1;
    var wrong_schema_storage: [512]u8 = undefined;
    const wrong_schema = try recovery.encodeCheckpoint(
        &wrong_schema_storage,
        wrong_schema_metadata,
        .{ .accumulator = 3, .event_count = 4 },
    );
    var wrong_next_metadata = newer_metadata;
    wrong_next_metadata.next_intent_sequence += 1;
    const damaged = [_]CheckpointCandidate{
        .{ .container = header_damage[0..newer.len], .metadata = newer_metadata },
        .{ .container = payload_damage[0..newer.len], .metadata = newer_metadata },
        .{ .container = newer[0 .. newer.len - 1], .metadata = newer_metadata },
        .{ .container = wrong_schema, .metadata = wrong_schema_metadata },
        .{ .container = newer, .metadata = wrong_next_metadata },
    };
    for (damaged) |bad| {
        const candidates = [_]CheckpointCandidate{
            bad,
            .{ .container = older, .metadata = metadata },
        };
        try std.testing.expectEqual(
            @as(usize, 1),
            chooseCheckpoint(&candidates, metadata, false, false).checkpoint,
        );
    }
    try std.testing.expect(
        chooseCheckpoint(damaged[0..1], metadata, true, true) == .rebuild,
    );
    try std.testing.expect(
        chooseCheckpoint(damaged[0..1], metadata, true, false) == .disabled,
    );
}
