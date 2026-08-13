const std = @import("std");
const trading = @import("trading_shard.zig");

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
