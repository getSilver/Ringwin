const std = @import("std");
const trading = @import("trading_shard.zig");
const strategy_recovery = @import("strategy_host_recovery.zig");

/// Restart admission phase; only ready may later accept a fresh EnableTrading.
pub const RecoveryPhase = enum(u8) { recovery_only, ready };

/// Exact Venue evidence required to close restart uncertainty.
pub const VenueEvidence = struct {
    orders: [trading.oms.max_orders]VenueOrderEvidence = undefined,
    order_count: u8 = 0,
    open_orders_closed: bool,
    portfolio_quantity: i64,
    exchange_quantity: i64,
    portfolio_spot_quantity: i64,
    exchange_spot_quantity: i64,
    portfolio_open_cost_micros: i64,
    exchange_open_cost_micros: i64,
    portfolio_spot_open_cost_micros: i64,
    exchange_spot_open_cost_micros: i64,
    portfolio_cash_micros: i64,
    exchange_cash_micros: i64,
    portfolio_fee_micros: i64,
    exchange_fee_micros: i64,
    suspense_micros: i64,
    active_reservations_micros: i64,
    margin_micros: i64,
    ledger_closed: bool,
    reconciliation_break: bool,
};

/// One authoritative Venue observation for an order owned by this shard.
pub const VenueOrderEvidence = struct {
    order_id: u64,
    status: trading.oms.ReconciliationStatus,
    revision: u32,
    cumulative_quantity: i64,
    remaining_quantity: i64,
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
        var evidence: VenueEvidence = .{
            .open_orders_closed = self.shard.oms.openOrdersClosed(),
            .portfolio_quantity = economic.portfolio.swap.quantity,
            .exchange_quantity = economic.exchange.swap.quantity,
            .portfolio_spot_quantity = economic.portfolio.spot_asset_quantity,
            .exchange_spot_quantity = economic.exchange.spot_asset_quantity,
            .portfolio_open_cost_micros = economic.portfolio.swap.open_cost_micros,
            .exchange_open_cost_micros = economic.exchange.swap.open_cost_micros,
            .portfolio_spot_open_cost_micros = economic.portfolio.spot.open_cost_micros,
            .exchange_spot_open_cost_micros = economic.exchange.spot.open_cost_micros,
            .portfolio_cash_micros = self.shard.portfolio_cash_micros,
            .exchange_cash_micros = self.shard.exchange_cash_micros,
            .portfolio_fee_micros = economic.portfolio.fee_micros,
            .exchange_fee_micros = economic.exchange.fee_micros,
            .suspense_micros = economic.suspense_usdt_micros,
            .active_reservations_micros = self.shard.oms.activeReservations() catch std.math.maxInt(i64),
            .margin_micros = self.shard.position_margin_requirement_micros,
            .ledger_closed = self.shard.portfolio_ledger_debits_micros == self.shard.portfolio_ledger_credits_micros and
                self.shard.exchange_ledger_debits_micros == self.shard.exchange_ledger_credits_micros,
            .reconciliation_break = economic.reconciliation_break,
        };
        for (self.shard.oms.orders[0..self.shard.oms.order_count]) |order| {
            evidence.orders[evidence.order_count] = .{
                .order_id = order.id,
                .status = switch (order.state) {
                    .filled, .canceled, .rejected => .found_terminal,
                    else => .found_live,
                },
                .revision = order.revision,
                .cumulative_quantity = order.cumulative_quantity,
                .remaining_quantity = order.quantity - order.cumulative_quantity,
            };
            evidence.order_count += 1;
        }
        return evidence;
    }

    /// Accepts one semantic reconciliation identity and enters Ready only on exact closure.
    pub fn reconcile(self: *RecoveryCoordinator, identity: u64, evidence: VenueEvidence) !void {
        if (identity == 0) return error.InvalidReconciliationIdentity;
        if (identity == self.last_reconciliation_identity) {
            if (!sameVenueEvidence(self.last_evidence, evidence)) return error.ReconciliationIdentityConflict;
            return;
        }
        if (identity < self.last_reconciliation_identity) return error.StaleReconciliationIdentity;
        if (!venueEvidenceCloses(self.shard, evidence)) return error.VenueReconciliationMismatch;
        self.last_reconciliation_identity = identity;
        self.last_evidence = evidence;
        self.phase = .ready;
        self.shard.operational_state.mode = .ready;
        self.shard.operational_state.trading_authorized = false;
    }

    /// Persists reconciliation failure as a canonical latched gate before returning it.
    pub fn reconcileStable(
        self: *RecoveryCoordinator,
        stable_journal: *trading.journal.Journal,
        identity: u64,
        evidence: VenueEvidence,
    ) !void {
        self.reconcile(identity, evidence) catch |err| {
            if (err == error.VenueReconciliationMismatch) {
                _ = try trading.applyStable(&self.shard, stable_journal, .{
                    .identity = identity,
                    .payload = .{ .safety_gate_change = .{
                        .gate_identity = identity,
                        .target_identity = self.shard.operational_state.target_identity,
                        .kind = .latched,
                        .reason = .reconciliation_break,
                        .open = false,
                    } },
                });
            }
            return err;
        };
    }
};

fn venueEvidenceCloses(shard: trading.TradingShard, evidence: VenueEvidence) bool {
    const coordinator: RecoveryCoordinator = .{ .shard = shard, .barrier = 1 };
    const expected = coordinator.expectedVenueEvidence();
    if (evidence.order_count != shard.oms.order_count or
        evidence.portfolio_quantity != expected.portfolio_quantity or
        evidence.exchange_quantity != expected.exchange_quantity or
        evidence.portfolio_spot_quantity != expected.portfolio_spot_quantity or
        evidence.exchange_spot_quantity != expected.exchange_spot_quantity or
        evidence.portfolio_open_cost_micros != expected.portfolio_open_cost_micros or
        evidence.exchange_open_cost_micros != expected.exchange_open_cost_micros or
        evidence.portfolio_spot_open_cost_micros != expected.portfolio_spot_open_cost_micros or
        evidence.exchange_spot_open_cost_micros != expected.exchange_spot_open_cost_micros or
        evidence.portfolio_cash_micros != expected.portfolio_cash_micros or
        evidence.exchange_cash_micros != expected.exchange_cash_micros or
        evidence.portfolio_fee_micros != expected.portfolio_fee_micros or
        evidence.exchange_fee_micros != expected.exchange_fee_micros or
        evidence.suspense_micros != expected.suspense_micros or
        evidence.active_reservations_micros != expected.active_reservations_micros or
        evidence.margin_micros != expected.margin_micros or
        !evidence.ledger_closed or evidence.reconciliation_break)
        return false;
    for (evidence.orders[0..evidence.order_count], 0..) |observed, index| {
        const order = shard.oms.orderById(observed.order_id) orelse return false;
        for (evidence.orders[0..index]) |previous| if (previous.order_id == observed.order_id) return false;
        if (observed.revision != order.revision or
            observed.cumulative_quantity != order.cumulative_quantity or
            observed.remaining_quantity != order.quantity - order.cumulative_quantity)
            return false;
        switch (observed.status) {
            .found_terminal, .confirmed_absent => switch (order.state) {
                .filled, .canceled, .rejected => {},
                else => return false,
            },
            .found_live => switch (order.state) {
                .pending_submit, .unknown, .live, .partially_filled, .pending_amend, .pending_cancel => {},
                else => return false,
            },
            .unresolved => return false,
        }
    }
    return true;
}

fn sameVenueEvidence(left: VenueEvidence, right: VenueEvidence) bool {
    if (left.order_count != right.order_count) return false;
    for (left.orders[0..left.order_count], right.orders[0..right.order_count]) |left_order, right_order|
        if (!std.meta.eql(left_order, right_order)) return false;
    return left.open_orders_closed == right.open_orders_closed and
        left.portfolio_quantity == right.portfolio_quantity and left.exchange_quantity == right.exchange_quantity and
        left.portfolio_spot_quantity == right.portfolio_spot_quantity and left.exchange_spot_quantity == right.exchange_spot_quantity and
        left.portfolio_open_cost_micros == right.portfolio_open_cost_micros and
        left.exchange_open_cost_micros == right.exchange_open_cost_micros and
        left.portfolio_spot_open_cost_micros == right.portfolio_spot_open_cost_micros and
        left.exchange_spot_open_cost_micros == right.exchange_spot_open_cost_micros and
        left.portfolio_cash_micros == right.portfolio_cash_micros and
        left.exchange_cash_micros == right.exchange_cash_micros and
        left.portfolio_fee_micros == right.portfolio_fee_micros and left.exchange_fee_micros == right.exchange_fee_micros and
        left.suspense_micros == right.suspense_micros and left.active_reservations_micros == right.active_reservations_micros and
        left.margin_micros == right.margin_micros and
        left.ledger_closed == right.ledger_closed and left.reconciliation_break == right.reconciliation_break;
}

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

/// Published checkpoint candidate ordered from newest cursor to oldest.
pub const PublishedCheckpoint = struct {
    container: []const u8,
    metadata: strategy_recovery.Metadata,
};

/// Selects the newest valid published checkpoint and falls back deterministically.
pub fn catchUpPublishedStrategy(
    coordinator: *const RecoveryCoordinator,
    candidates: []const PublishedCheckpoint,
    events: []const strategy_recovery.ReplayEvent,
) !strategy_recovery.Recovered {
    var previous_cursor: ?u64 = null;
    for (candidates) |candidate| {
        if (previous_cursor) |cursor| if (candidate.metadata.strategy_cursor >= cursor)
            return error.CheckpointsNotNewestFirst;
        previous_cursor = candidate.metadata.strategy_cursor;
        const start = candidate.metadata.strategy_cursor + 1;
        var first_index: usize = 0;
        while (first_index < events.len and events[first_index].sequence < start) : (first_index += 1) {}
        return catchUpStrategy(coordinator, candidate.container, candidate.metadata, events[first_index..]) catch |err| switch (err) {
            error.InvalidCheckpoint, error.CheckpointMismatch => continue,
            else => return err,
        };
    }
    return error.NoValidStrategyCheckpoint;
}

fn hasIntent(events: []const strategy_recovery.ReplayEvent) bool {
    for (events) |event| if (event.would_emit_intent) return true;
    return false;
}

/// Strategy-private-state handling declared by one candidate version.
pub const StrategyStateTransition = enum(u8) { keep, migrate, rebuild };
/// Scope of intent fencing and cancellation for a cutover.
pub const CutoverScope = enum(u8) { decision_domain, strategy_instance };
/// Cutover progresses only through explicit persisted barriers.
pub const CutoverPhase = enum(u8) { idle, candidate, quiescing, draining, recovery_only, active };

/// Immutable activation fact deciding the sole active version during replay.
pub const VersionActivationEvent = trading.VersionActivationEvent;

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
    candidate_digest: [32]u8 = @splat(0),
    candidate_barrier: u64 = 0,
    scope: CutoverScope = .decision_domain,

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

    /// Records that the candidate consumed authoritative facts through the final barrier.
    pub fn catchUpCandidate(self: *Cutover, shard: trading.TradingShard) !void {
        if (self.phase != .draining) return error.InvalidCutoverTransition;
        self.candidate_barrier = shard.trace.len;
        self.candidate_digest = shard.canonicalStateDigest();
    }

    /// Stops new intent production at one exact ShardSequence.
    fn quiesce(self: *Cutover, barrier: u64) !void {
        if (self.phase != .candidate or barrier == 0) return error.InvalidCutoverTransition;
        self.quiesce_barrier = barrier;
        self.phase = .quiescing;
    }

    /// Revokes intent authority and emits authoritative cancels for CutoverDrain scope.
    pub fn quiesceShard(
        self: *Cutover,
        shard: *trading.TradingShard,
        stable_journal: *trading.journal.Journal,
        command_identity: u128,
    ) ![]const trading.oms.Command {
        if (self.phase != .candidate) return error.InvalidCutoverTransition;
        const barrier = shard.trace.len + 1;
        _ = try trading.applyStable(shard, stable_journal, .{
            .identity = @truncate(command_identity),
            .payload = .{ .control_command = .{
                .command_identity = command_identity,
                .content_hash = command_identity,
                .target_identity = shard.operational_state.target_identity,
                .expected_version = shard.operational_state.version,
                .expires_at = std.math.maxInt(u64),
                .kind = .trading_pause,
            } },
        });
        self.quiesce_barrier = barrier;
        self.phase = .quiescing;
        return shard.oms.emitted();
    }

    /// Fences and cancels only the candidate strategy while unrelated strategies continue.
    pub fn quiesceStrategy(
        self: *Cutover,
        shard: *trading.TradingShard,
        stable_journal: *trading.journal.Journal,
        strategy_instance: u128,
    ) ![]const trading.oms.Command {
        if (self.phase != .candidate or strategy_instance == 0) return error.InvalidCutoverTransition;
        _ = try trading.applyStable(shard, stable_journal, .{
            .identity = @truncate(strategy_instance),
            .payload = .{ .strategy_cutover_fence = .{ .strategy_instance = strategy_instance } },
        });
        self.scope = .strategy_instance;
        self.quiesce_barrier = shard.trace.len;
        self.phase = .quiescing;
        return shard.oms.emitted();
    }

    /// Proves CutoverDrain through authoritative order and Venue evidence.
    pub fn drain(self: *Cutover, shard: trading.TradingShard, evidence: VenueEvidence) !void {
        if (self.phase != .quiescing) return error.InvalidCutoverTransition;
        if (!shard.oms.openOrdersClosed() or !evidence.open_orders_closed or
            !venueEvidenceCloses(shard, evidence))
            return error.CutoverDrainIncomplete;
        self.phase = .draining;
    }

    /// Persists activation through TradingShard.apply and stable journal before committing cutover state.
    pub fn activateStable(
        self: *Cutover,
        shard: *trading.TradingShard,
        stable_journal: *trading.journal.Journal,
        activation_identity: u128,
    ) !VersionActivationEvent {
        if (self.phase != .draining) return error.InvalidCutoverTransition;
        const digest = shard.canonicalStateDigest();
        if (self.candidate_barrier != shard.trace.len or !std.mem.eql(u8, &self.candidate_digest, &digest))
            return error.CandidateBehindCutoverBarrier;
        const barrier = shard.trace.len + 1;
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
            .transition = @enumFromInt(@intFromEnum(self.candidate.transition)),
            .barrier = barrier,
            .canonical_state_digest = digest,
        };
        _ = try trading.applyStable(shard, stable_journal, .{
            .identity = @truncate(activation_identity),
            .payload = .{ .version_activation = event },
        });
        if (stable_journal.last_sequence != barrier) return error.ActivationNotStable;
        self.activations[self.activation_count] = event;
        self.activation_count += 1;
        self.generation = event.generation;
        self.active_release = event.new_release;
        self.active_strategy_instance = event.new_strategy_instance;
        self.phase = .active;
        return event;
    }

    /// Reconstructs durable pending-cancel work after a crash between commit and send.
    pub fn recoverCancelOutbox(
        self: *Cutover,
        shard: *const trading.TradingShard,
        destination: []trading.oms.Command,
    ) ![]const trading.oms.Command {
        if (self.phase != .quiescing and self.phase != .draining) return error.InvalidCutoverTransition;
        return shard.oms.pendingCancelCommands(destination);
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
    var stable_journal = trading.journal.Journal.init();
    _ = try trading.applyStable(&shard, &stable_journal, .{
        .identity = 90,
        .payload = .{ .control_command = .{
            .command_identity = 90,
            .content_hash = 90,
            .target_identity = 7,
            .expected_version = 0,
            .expires_at = std.math.maxInt(u64),
            .kind = .start_recovery,
        } },
    });
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
    try std.testing.expectError(error.VenueReconciliationMismatch, recovery.reconcileStable(&stable_journal, 1, mismatch));
    try std.testing.expectEqual(RecoveryPhase.recovery_only, recovery.phase);
    try std.testing.expectEqual(@as(u8, 1), recovery.shard.operational_state.latch_count);
    try std.testing.expectEqual(@as(u64, 2), stable_journal.last_sequence);
    try stable_journal.seal();
    var reader = try trading.journal.Reader.init(stable_journal.bytes());
    var replayed: trading.ReplayTradingShard = .{};
    while (true) switch (try reader.next()) {
        .record => |record| _ = try replayed.apply(try trading.decodeStableInput(record)),
        .end => break,
    };
    try std.testing.expectEqual(recovery.shard.operational_state.latch_count, replayed.shard.operational_state.latch_count);

    recovery = RecoveryCoordinator.begin(shard, 11);
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

test "strategy recovery falls back from a damaged newest published checkpoint" {
    var coordinator = RecoveryCoordinator.begin(.{}, 5);
    coordinator.phase = .ready;
    const older: strategy_recovery.Metadata = .{
        .schema_registry = 1,
        .strategy_instance = 2,
        .strategy_definition = 3,
        .state_schema = 4,
        .state_schema_version = 1,
        .strategy_config_version = 7,
        .strategy_cursor = 2,
        .next_intent_sequence = 5,
    };
    var older_storage: [512]u8 = undefined;
    const older_checkpoint = try strategy_recovery.encodeCheckpoint(&older_storage, older, .{ .accumulator = 30, .event_count = 2 });
    var newest_storage: [512]u8 = undefined;
    const newest_metadata = blk: {
        var value = older;
        value.strategy_cursor = 4;
        value.next_intent_sequence = 6;
        break :blk value;
    };
    const newest = try strategy_recovery.encodeCheckpoint(&newest_storage, newest_metadata, .{ .accumulator = 100, .event_count = 4 });
    newest_storage[newest.len - 1] ^= 1;
    const recovered = try catchUpPublishedStrategy(&coordinator, &.{
        .{ .container = newest_storage[0..newest.len], .metadata = newest_metadata },
        .{ .container = older_checkpoint, .metadata = older },
    }, &.{
        .{ .sequence = 3, .delta = 30, .would_emit_intent = false },
        .{ .sequence = 4, .delta = 40, .would_emit_intent = true },
        .{ .sequence = 5, .delta = 50, .would_emit_intent = false },
    });
    try std.testing.expectEqual(@as(u64, 5), recovered.cursor);
}

test "cutover drain activates exactly one version at a stable barrier" {
    var shard: trading.TradingShard = .{ .release_generation = 4, .active_release = 10, .active_strategy_instance = 20 };
    var stable_journal = trading.journal.Journal.init();
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
    try cutover.drain(shard, evidence);
    try cutover.catchUpCandidate(shard);
    const event = try cutover.activateStable(&shard, &stable_journal, 40);
    try std.testing.expectEqual(@as(u64, 11), cutover.active_release);
    try std.testing.expectEqual(@as(u128, 21), cutover.active_strategy_instance);
    try std.testing.expectEqual(@as(u64, 5), event.generation);
    try std.testing.expectEqual(CutoverPhase.active, cutover.phase);
}

test "cutover activation is a stable canonical fact before authority switches" {
    var shard: trading.TradingShard = .{};
    var stable_journal = trading.journal.Journal.init();
    var cutover: Cutover = .{ .generation = 0, .active_release = 0, .active_strategy_instance = 0 };
    try cutover.prepare(.{
        .release = 11,
        .strategy_instance = 21,
        .strategy_definition = 30,
        .parameter_version = 2,
        .state_schema_version = 1,
        .transition = .keep,
        .structure_valid = true,
        .economic_digest_valid = true,
        .strategy_invariants_valid = true,
    });
    try cutover.quiesce(1);
    var evidence: VenueEvidence = std.mem.zeroes(VenueEvidence);
    evidence.open_orders_closed = true;
    evidence.ledger_closed = true;
    try cutover.drain(shard, evidence);
    try cutover.catchUpCandidate(shard);
    const activation = try cutover.activateStable(&shard, &stable_journal, 40);
    try std.testing.expectEqual(@as(u64, 1), stable_journal.last_sequence);
    try std.testing.expectEqual(@as(u64, 11), shard.active_release);
    try std.testing.expectEqual(activation.new_release, cutover.active_release);
    try stable_journal.seal();
    var replayed: trading.ReplayTradingShard = .{};
    var reader = try trading.journal.Reader.init(stable_journal.bytes());
    const record = switch (try reader.next()) {
        .record => |value| value,
        .end => return error.MissingActivation,
    };
    const input = try trading.decodeStableInput(record);
    _ = try replayed.apply(input);
    try std.testing.expectEqual(shard.active_release, replayed.shard.active_release);
}

test "strategy cutover persists a scoped fence and leaves unrelated orders live" {
    var shard: trading.TradingShard = .{};
    var journal = trading.journal.Journal.init();
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 2 };
    group.members[0] = .{ .intent_sequence = 1, .strategy_instance = 11, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 1, .limit_price_micros = 2, .reservation_micros = 2 };
    group.members[1] = .{ .intent_sequence = 2, .strategy_instance = 12, .operation = .place, .instrument = .btc_usdt_spot, .quantity = 1, .limit_price_micros = 2, .reservation_micros = 2 };
    try shard.oms.applyGroup(group);
    var cutover: Cutover = .{};
    try cutover.prepare(.{ .release = 1, .strategy_instance = 21, .strategy_definition = 1, .parameter_version = 1, .state_schema_version = 1, .transition = .keep, .structure_valid = true, .economic_digest_valid = true, .strategy_invariants_valid = true });
    const commands = try cutover.quiesceStrategy(&shard, &journal, 11);
    try std.testing.expectEqual(@as(usize, 1), commands.len);
    try std.testing.expectEqual(@as(u128, 11), commands[0].strategy_instance);
    try std.testing.expectEqual(trading.oms.OrderState.pending_cancel, shard.oms.orders[0].state);
    try std.testing.expectEqual(trading.oms.OrderState.pending_submit, shard.oms.orders[1].state);
    try std.testing.expectEqual(@as(u64, 1), journal.last_sequence);
}

test "cutover failures and forward rollback never regress economic state or generation" {
    var shard: trading.TradingShard = .{ .release_generation = 4, .active_release = 10, .active_strategy_instance = 20 };
    shard.economic_projection.portfolio.spot.quantity = 3;
    shard.economic_projection.portfolio.spot.open_cost_micros = 150;
    shard.economic_projection.portfolio.fee_micros = 7;
    shard.economic_projection.exchange.spot = shard.economic_projection.portfolio.spot;
    shard.economic_projection.exchange.fee_micros = 7;
    var stable_journal = trading.journal.Journal.init();
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
    const evidence = (RecoveryCoordinator{ .shard = shard, .barrier = 1 }).expectedVenueEvidence();
    try cutover.drain(shard, evidence);
    try cutover.failBeforeActivation();
    try std.testing.expectEqual(@as(u64, 10), cutover.active_release);

    cutover.phase = .active;
    try cutover.prepare(candidate);
    try cutover.quiesce(102);
    try cutover.drain(shard, evidence);
    try cutover.catchUpCandidate(shard);
    const activated = try cutover.activateStable(&shard, &stable_journal, 41);

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
    try cutover.drain(shard, evidence);
    try cutover.catchUpCandidate(shard);
    const rolled_back = try cutover.activateStable(&shard, &stable_journal, 42);
    try std.testing.expectEqual(activated.generation + 1, rolled_back.generation);
    try std.testing.expectEqual(@as(u64, 10), rolled_back.new_release);
    try std.testing.expectEqual(@as(u128, 22), rolled_back.new_strategy_instance);
    try std.testing.expectEqual(@as(i64, 3), shard.economic_projection.portfolio.spot.quantity);
    try std.testing.expectEqual(@as(i64, 150), shard.economic_projection.portfolio.spot.open_cost_micros);
    try std.testing.expectEqual(@as(i64, 7), shard.economic_projection.portfolio.fee_micros);

    const replayed = try Cutover.replayActivations(cutover.activations[0..cutover.activation_count]);
    try std.testing.expectEqual(cutover.active_release, replayed.active_release);
    try std.testing.expectEqual(cutover.active_strategy_instance, replayed.active_strategy_instance);
    try std.testing.expectEqual(cutover.generation, replayed.generation);
}
