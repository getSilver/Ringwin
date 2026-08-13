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
