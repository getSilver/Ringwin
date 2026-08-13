const std = @import("std");
const trading = @import("trading_shard.zig");
const strategy_recovery = @import("strategy_host_recovery.zig");

/// Restart admission phase; only ready may later accept a fresh EnableTrading.
pub const RecoveryPhase = enum(u8) { recovery_only, ready };

/// Exact Venue evidence required to close restart uncertainty.
pub const VenueEvidence = struct {
    open_orders_closed: bool,
    portfolio_quantity: i64,
    exchange_quantity: i64,
    portfolio_open_cost_micros: i64,
    exchange_open_cost_micros: i64,
    portfolio_cash_micros: i64,
    exchange_cash_micros: i64,
    margin_micros: i64,
    ledger_closed: bool,
    reconciliation_break: bool,
};

/// Bounded recovery state owning a restored shard until exact Venue reconciliation.
pub const RecoveryCoordinator = struct {
    shard: trading.TradingShard,
    barrier: u64,
    phase: RecoveryPhase = .recovery_only,
    last_reconciliation_identity: u64 = 0,
    last_evidence: VenueEvidence = undefined,

    /// Fences restored authority immediately; restart never inherits a live authorization.
    pub fn begin(restored: trading.TradingShard, barrier: u64) RecoveryCoordinator {
        var coordinator: RecoveryCoordinator = .{ .shard = restored, .barrier = barrier };
        coordinator.shard.operational_state.trading_authorized = false;
        coordinator.shard.operational_state.mode = .recovering;
        return coordinator;
    }

    /// Derives the exact economic and order evidence the Venue must corroborate.
    pub fn expectedVenueEvidence(self: *const RecoveryCoordinator) VenueEvidence {
        const economic = self.shard.economicSummary();
        return .{
            .open_orders_closed = self.shard.oms.openOrdersClosed(),
            .portfolio_quantity = economic.portfolio.swap.quantity,
            .exchange_quantity = economic.exchange.swap.quantity,
            .portfolio_open_cost_micros = economic.portfolio.swap.open_cost_micros,
            .exchange_open_cost_micros = economic.exchange.swap.open_cost_micros,
            .portfolio_cash_micros = self.shard.portfolio_cash_micros,
            .exchange_cash_micros = self.shard.exchange_cash_micros,
            .margin_micros = self.shard.position_margin_requirement_micros,
            .ledger_closed = self.shard.portfolio_ledger_debits_micros == self.shard.portfolio_ledger_credits_micros and
                self.shard.exchange_ledger_debits_micros == self.shard.exchange_ledger_credits_micros,
            .reconciliation_break = economic.reconciliation_break,
        };
    }

    /// Accepts one semantic reconciliation identity and enters Ready only on exact closure.
    pub fn reconcile(self: *RecoveryCoordinator, identity: u64, evidence: VenueEvidence) !void {
        if (identity == 0) return error.InvalidReconciliationIdentity;
        if (identity == self.last_reconciliation_identity) {
            if (!std.meta.eql(self.last_evidence, evidence)) return error.ReconciliationIdentityConflict;
            return;
        }
        if (identity < self.last_reconciliation_identity) return error.StaleReconciliationIdentity;
        if (!std.meta.eql(self.expectedVenueEvidence(), evidence) or !evidence.open_orders_closed or
            !evidence.ledger_closed or evidence.reconciliation_break)
            return error.VenueReconciliationMismatch;
        self.last_reconciliation_identity = identity;
        self.last_evidence = evidence;
        self.phase = .ready;
        self.shard.operational_state.mode = .ready;
        self.shard.operational_state.trading_authorized = false;
    }
};

/// Restores one published checkpoint and catches it up behind the core recovery fence.
pub fn catchUpStrategy(
    coordinator: *const RecoveryCoordinator,
    checkpoint: []const u8,
    expected: strategy_recovery.Metadata,
    events: []const strategy_recovery.ReplayEvent,
) !strategy_recovery.Recovered {
    if (coordinator.phase != .ready) return error.CoreRecoveryIncomplete;
    var recovery = try strategy_recovery.Recovery.begin(checkpoint, expected, coordinator.barrier);
    if (expected.strategy_cursor < coordinator.barrier) {
        if (events.len == 0) return error.StrategyHistoryGap;
        _ = try recovery.applyBatch(expected.strategy_cursor + 1, coordinator.barrier, events);
    } else if (events.len != 0) return error.StrategyReplayPastBarrier;
    const recovered = try recovery.finishRecovery();
    if (recovery.canTrade() or recovery.suppressed_intents == 0 and hasIntent(events)) {
        return error.StrategyRecoveryFenceFailed;
    }
    return recovered;
}

fn hasIntent(events: []const strategy_recovery.ReplayEvent) bool {
    for (events) |event| if (event.would_emit_intent) return true;
    return false;
}

/// Strategy-private-state handling declared by one candidate version.
pub const StrategyStateTransition = enum(u8) { keep, migrate, rebuild };
/// Cutover progresses only through explicit persisted barriers.
pub const CutoverPhase = enum(u8) { idle, candidate, quiescing, draining, recovery_only, active };

/// Immutable activation fact deciding the sole active version during replay.
pub const VersionActivationEvent = struct {
    activation_identity: u128,
    generation: u64,
    old_release: u64,
    new_release: u64,
    old_strategy_instance: u128,
    new_strategy_instance: u128,
    strategy_definition: u128,
    parameter_version: u64,
    state_schema_version: u32,
    transition: StrategyStateTransition,
    barrier: u64,
    canonical_state_digest: [32]u8,
};

/// One candidate validated without trading authority before atomic activation.
pub const Candidate = struct {
    release: u64,
    strategy_instance: u128,
    strategy_definition: u128,
    parameter_version: u64,
    state_schema_version: u32,
    transition: StrategyStateTransition,
    structure_valid: bool,
    economic_digest_valid: bool,
    strategy_invariants_valid: bool,
    history_complete: bool = true,
};

/// Bounded low-frequency cutover state; economic state remains in TradingShard.
pub const Cutover = struct {
    phase: CutoverPhase = .idle,
    generation: u64 = 0,
    active_release: u64 = 0,
    active_strategy_instance: u128 = 0,
    candidate: Candidate = undefined,
    quiesce_barrier: u64 = 0,
    activations: [8]VersionActivationEvent = undefined,
    activation_count: u8 = 0,

    /// Validates one candidate while leaving the active version authoritative.
    pub fn prepare(self: *Cutover, candidate: Candidate) !void {
        if (self.phase != .idle and self.phase != .active) return error.CutoverInProgress;
        if (candidate.release == 0 or candidate.strategy_instance == 0 or
            !candidate.structure_valid or !candidate.economic_digest_valid or
            !candidate.strategy_invariants_valid)
            return error.InvalidCutoverCandidate;
        if (candidate.transition == .rebuild and !candidate.history_complete)
            return error.CandidateWarmingUp;
        if (candidate.transition == .keep and self.activation_count != 0 and
            candidate.state_schema_version != self.activations[self.activation_count - 1].state_schema_version)
            return error.IncompatibleKeepSchema;
        self.candidate = candidate;
        self.phase = .candidate;
    }

    /// Stops new intent production at one exact ShardSequence.
    pub fn quiesce(self: *Cutover, barrier: u64) !void {
        if (self.phase != .candidate or barrier == 0) return error.InvalidCutoverTransition;
        self.quiesce_barrier = barrier;
        self.phase = .quiescing;
    }

    /// Proves CutoverDrain through authoritative order and Venue evidence.
    pub fn drain(self: *Cutover, evidence: VenueEvidence) !void {
        if (self.phase != .quiescing) return error.InvalidCutoverTransition;
        if (!evidence.open_orders_closed or !evidence.ledger_closed or evidence.reconciliation_break)
            return error.CutoverDrainIncomplete;
        self.phase = .draining;
    }

    /// Atomically records and activates a candidate at the later stable barrier.
    pub fn activate(
        self: *Cutover,
        activation_identity: u128,
        barrier: u64,
        digest: [32]u8,
        stable: bool,
    ) !VersionActivationEvent {
        if (self.phase != .draining or barrier < self.quiesce_barrier or activation_identity == 0)
            return error.InvalidCutoverTransition;
        if (!stable) {
            self.phase = .recovery_only;
            return error.ActivationNotStable;
        }
        if (self.activation_count == self.activations.len) return error.ActivationHistoryFull;
        const event: VersionActivationEvent = .{
            .activation_identity = activation_identity,
            .generation = self.generation + 1,
            .old_release = self.active_release,
            .new_release = self.candidate.release,
            .old_strategy_instance = self.active_strategy_instance,
            .new_strategy_instance = self.candidate.strategy_instance,
            .strategy_definition = self.candidate.strategy_definition,
            .parameter_version = self.candidate.parameter_version,
            .state_schema_version = self.candidate.state_schema_version,
            .transition = self.candidate.transition,
            .barrier = barrier,
            .canonical_state_digest = digest,
        };
        self.activations[self.activation_count] = event;
        self.activation_count += 1;
        self.generation = event.generation;
        self.active_release = event.new_release;
        self.active_strategy_instance = event.new_strategy_instance;
        self.phase = .active;
        return event;
    }

    /// Discards an uncommitted candidate; the current active version remains authoritative.
    pub fn failBeforeActivation(self: *Cutover) !void {
        switch (self.phase) {
            .candidate, .quiescing, .draining => self.phase = if (self.active_release == 0) .idle else .active,
            else => return error.InvalidCutoverTransition,
        }
        self.quiesce_barrier = 0;
    }

    /// Rebuilds the sole active version from stable activation facts.
    pub fn replayActivations(events: []const VersionActivationEvent) !Cutover {
        var replayed: Cutover = .{};
        for (events) |event| {
            if (replayed.activation_count == 0) {
                if (event.generation == 0) return error.InvalidActivationHistory;
                replayed.generation = event.generation - 1;
                replayed.active_release = event.old_release;
                replayed.active_strategy_instance = event.old_strategy_instance;
            }
            if (event.activation_identity == 0 or event.generation != replayed.generation + 1 or
                event.barrier == 0 or (replayed.activation_count != 0 and
                (event.old_release != replayed.active_release or
                    event.old_strategy_instance != replayed.active_strategy_instance or
                    event.barrier < replayed.activations[replayed.activation_count - 1].barrier)))
                return error.InvalidActivationHistory;
            if (replayed.activation_count == replayed.activations.len) return error.ActivationHistoryFull;
            replayed.activations[replayed.activation_count] = event;
            replayed.activation_count += 1;
            replayed.generation = event.generation;
            replayed.active_release = event.new_release;
            replayed.active_strategy_instance = event.new_strategy_instance;
        }
        replayed.phase = if (events.len == 0) .idle else .active;
        return replayed;
    }
};

test "restart recovery remains fenced until exact venue evidence closes" {
    var shard: trading.TradingShard = .{};
    shard.operational_state = trading.operational.State.init(7);
    shard.operational_state.mode = .trading;
    shard.operational_state.trading_authorized = true;
    shard.portfolio_cash_micros = 12;
    shard.exchange_cash_micros = 12;
    shard.risk_lease_micros = 9;
    shard.risk_lease_remaining_micros = 9;

    var recovery = RecoveryCoordinator.begin(shard, 11);
    try std.testing.expectEqual(RecoveryPhase.recovery_only, recovery.phase);
    try std.testing.expect(!recovery.shard.operational_state.trading_authorized);

    var mismatch = recovery.expectedVenueEvidence();
    mismatch.exchange_cash_micros += 1;
    try std.testing.expectError(error.VenueReconciliationMismatch, recovery.reconcile(1, mismatch));
    try std.testing.expectEqual(RecoveryPhase.recovery_only, recovery.phase);

    try recovery.reconcile(2, recovery.expectedVenueEvidence());
    try std.testing.expectEqual(RecoveryPhase.ready, recovery.phase);
    try std.testing.expectEqual(trading.operational.OperationalMode.ready, recovery.shard.operational_state.mode);
    try std.testing.expect(!recovery.shard.operational_state.trading_authorized);
    try recovery.reconcile(2, recovery.expectedVenueEvidence());
    try std.testing.expectError(error.ReconciliationIdentityConflict, recovery.reconcile(2, mismatch));
}

test "strategy checkpoint catches up to the core barrier without publishing intents" {
    var coordinator = RecoveryCoordinator.begin(.{}, 5);
    coordinator.phase = .ready;
    coordinator.shard.operational_state.mode = .ready;
    const metadata: strategy_recovery.Metadata = .{
        .schema_registry = 1,
        .strategy_instance = 2,
        .strategy_definition = 3,
        .state_schema = 4,
        .state_schema_version = 1,
        .strategy_config_version = 7,
        .strategy_cursor = 2,
        .next_intent_sequence = 5,
    };
    var storage: [512]u8 = undefined;
    const checkpoint = try strategy_recovery.encodeCheckpoint(&storage, metadata, .{ .accumulator = 30, .event_count = 2 });
    const recovered = try catchUpStrategy(&coordinator, checkpoint, metadata, &.{
        .{ .sequence = 3, .delta = 30, .would_emit_intent = false },
        .{ .sequence = 4, .delta = 40, .would_emit_intent = true },
        .{ .sequence = 5, .delta = 50, .would_emit_intent = false },
    });
    try std.testing.expectEqual(@as(u64, 5), recovered.cursor);
    try std.testing.expectEqual(@as(u64, 6), recovered.next_intent_sequence);

    var damaged: [512]u8 = undefined;
    @memcpy(damaged[0..checkpoint.len], checkpoint);
    damaged[checkpoint.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidCheckpoint, catchUpStrategy(&coordinator, damaged[0..checkpoint.len], metadata, &.{}));
    coordinator.phase = .recovery_only;
    try std.testing.expectError(error.CoreRecoveryIncomplete, catchUpStrategy(&coordinator, checkpoint, metadata, &.{}));
}

test "cutover drain activates exactly one version at a stable barrier" {
    var cutover: Cutover = .{ .generation = 4, .active_release = 10, .active_strategy_instance = 20 };
    try cutover.prepare(.{
        .release = 11,
        .strategy_instance = 21,
        .strategy_definition = 30,
        .parameter_version = 2,
        .state_schema_version = 1,
        .transition = .migrate,
        .structure_valid = true,
        .economic_digest_valid = true,
        .strategy_invariants_valid = true,
    });
    try cutover.quiesce(100);
    var evidence: VenueEvidence = std.mem.zeroes(VenueEvidence);
    evidence.open_orders_closed = true;
    evidence.ledger_closed = true;
    try cutover.drain(evidence);
    const digest: [32]u8 = @splat(7);
    const event = try cutover.activate(40, 101, digest, true);
    try std.testing.expectEqual(@as(u64, 11), cutover.active_release);
    try std.testing.expectEqual(@as(u128, 21), cutover.active_strategy_instance);
    try std.testing.expectEqual(@as(u64, 5), event.generation);
    try std.testing.expectEqual(CutoverPhase.active, cutover.phase);
}

test "cutover failures and forward rollback never regress economic state or generation" {
    var cutover: Cutover = .{ .generation = 4, .active_release = 10, .active_strategy_instance = 20, .phase = .active };
    const candidate: Candidate = .{
        .release = 11,
        .strategy_instance = 21,
        .strategy_definition = 30,
        .parameter_version = 2,
        .state_schema_version = 1,
        .transition = .keep,
        .structure_valid = true,
        .economic_digest_valid = true,
        .strategy_invariants_valid = true,
    };
    try cutover.prepare(candidate);
    try cutover.quiesce(100);
    try cutover.failBeforeActivation();
    try std.testing.expectEqual(@as(u64, 10), cutover.active_release);
    try std.testing.expectEqual(@as(u64, 4), cutover.generation);

    try cutover.prepare(candidate);
    try cutover.quiesce(100);
    var evidence: VenueEvidence = std.mem.zeroes(VenueEvidence);
    evidence.open_orders_closed = true;
    evidence.ledger_closed = true;
    try cutover.drain(evidence);
    const filled_state_digest: [32]u8 = @splat(9);
    try std.testing.expectError(error.ActivationNotStable, cutover.activate(40, 101, filled_state_digest, false));
    try std.testing.expectEqual(CutoverPhase.recovery_only, cutover.phase);
    try std.testing.expectEqual(@as(u64, 10), cutover.active_release);

    cutover.phase = .active;
    try cutover.prepare(candidate);
    try cutover.quiesce(102);
    try cutover.drain(evidence);
    const activated = try cutover.activate(41, 103, filled_state_digest, true);

    const rollback: Candidate = .{
        .release = 10,
        .strategy_instance = 22,
        .strategy_definition = 30,
        .parameter_version = 3,
        .state_schema_version = 1,
        .transition = .rebuild,
        .structure_valid = true,
        .economic_digest_valid = true,
        .strategy_invariants_valid = true,
    };
    try cutover.prepare(rollback);
    try cutover.quiesce(104);
    try cutover.drain(evidence);
    const rolled_back = try cutover.activate(42, 105, filled_state_digest, true);
    try std.testing.expectEqual(activated.generation + 1, rolled_back.generation);
    try std.testing.expectEqual(@as(u64, 10), rolled_back.new_release);
    try std.testing.expectEqual(@as(u128, 22), rolled_back.new_strategy_instance);
    try std.testing.expectEqualSlices(u8, &activated.canonical_state_digest, &rolled_back.canonical_state_digest);

    const replayed = try Cutover.replayActivations(cutover.activations[0..cutover.activation_count]);
    try std.testing.expectEqual(cutover.active_release, replayed.active_release);
    try std.testing.expectEqual(cutover.active_strategy_instance, replayed.active_strategy_instance);
    try std.testing.expectEqual(cutover.generation, replayed.generation);
}
