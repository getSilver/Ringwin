const std = @import("std");

/// Bounded histories keep replay state allocation-free.
pub const max_commands = 32;
pub const max_latches = 16;
pub const max_gates = 16;

/// Lifecycle phase; safety gates and authorization remain separate state.
pub const OperationalMode = enum(u8) { stopped, recovering, ready, trading, draining };
/// Supported operator lifecycle requests.
pub const CommandKind = enum(u8) {
    start_recovery,
    enable_trading,
    trading_pause,
    cancel_open_orders,
    stop_keep_positions,
    de_risk,
    resolve_latch,
};
/// Recovery semantics for one safety gate.
pub const GateKind = enum(u8) { self_recovering, latched, warning };
/// Stable reason classification used in audit and replay.
pub const GateReason = enum(u8) {
    market_data,
    primary_lease,
    risk_lease,
    margin_warning,
    margin_kill,
    reconciliation_break,
    venue_forced_execution,
    uncertain_order,
    identity,
    observability,
};

/// Signed, versioned request accepted at the TradingShard event seam.
pub const ControlCommand = struct {
    command_identity: u128,
    content_hash: u128,
    target_identity: u128,
    expected_version: u64,
    expires_at: u64,
    kind: CommandKind,
    target_position: i64 = 0,
    referenced_latch_identity: u128 = 0,
    risk_warning_acknowledged: bool = false,
    risk_warning_identity: u128 = 0,
};

/// Immutable observation of one independently identified safety gate.
pub const SafetyGateChange = struct {
    gate_identity: u128,
    target_identity: u128,
    kind: GateKind,
    reason: GateReason,
    open: bool,
    continuity_proven: bool = false,
    blocks_buy: bool = true,
    blocks_sell: bool = true,
};

/// Authoritative progress evidence; TradingShard verifies it against projections.
pub const LifecycleProgress = struct {
    operation_identity: u128,
    target_identity: u128,
    open_orders_closed: bool,
    reconciliation_complete: bool,
    position_quantity: i64,
};

/// Explicit side effects the owning TradingShard must apply.
pub const Action = struct {
    changed: bool = false,
    cancel_open_orders: bool = false,
    cancel_increasing_only: bool = false,
};

const CommandRecord = struct { command: ControlCommand };
/// One preserved latched failure and its resolution state.
pub const Latch = struct {
    identity: u128,
    reason: GateReason,
    resolved: bool = false,
};

/// Bounded operational projection owned by one TradingShard.
pub const State = struct {
    initialized: bool = false,
    target_identity: u128 = 0,
    version: u64 = 0,
    mode: OperationalMode = .stopped,
    trading_authorized: bool = false,
    self_recovering_closed: bool = false,
    warning_blocks_buy: bool = false,
    warning_blocks_sell: bool = false,
    gates: [max_gates]SafetyGateChange = undefined,
    gate_count: u8 = 0,
    command_history: [max_commands]CommandRecord = undefined,
    command_count: u8 = 0,
    latches: [max_latches]Latch = undefined,
    latch_count: u8 = 0,
    active_operation_identity: u128 = 0,
    active_operation_kind: CommandKind = .start_recovery,
    target_position: i64 = 0,
    continuity_intact: bool = true,
    last_risk_warning_identity: u128 = 0,

    /// Creates stopped operational state for one exact target.
    pub fn init(target_identity: u128) State {
        return .{ .initialized = true, .target_identity = target_identity };
    }

    /// Derives current authority; it is never persisted as a second truth.
    pub fn effectiveTradingAuthority(self: *const State) bool {
        return self.mode == .trading and self.trading_authorized and
            !self.self_recovering_closed and !self.hasUnresolvedLatch();
    }

    /// Returns whether the requested direction may increase exposure.
    pub fn mayIncrease(self: *const State, buy: bool) bool {
        return self.effectiveTradingAuthority() and
            !(if (buy) self.warning_blocks_buy else self.warning_blocks_sell);
    }

    /// Keeps cancel/reconciliation and qualified reducing traffic available.
    pub fn mayReduceOnly(self: *const State) bool {
        return self.mode == .draining or self.hasUnresolvedLatch();
    }

    /// Applies one command idempotently after target, expiry and version checks.
    pub fn applyCommand(self: *State, command: ControlCommand, now: u64) !Action {
        if (!self.initialized) self.* = State.init(command.target_identity);
        if (command.target_identity != self.target_identity)
            return error.ControlCommandWrongTarget;
        if (command.command_identity == 0 or command.content_hash == 0)
            return error.InvalidControlCommand;
        if (now > command.expires_at) return error.ControlCommandExpired;
        if (self.findCommand(command.command_identity)) |record| {
            if (!std.meta.eql(record.command, command)) return error.ControlCommandIdentityConflict;
            return .{};
        }
        if (command.expected_version != self.version) return error.ControlCommandVersionMismatch;
        if (self.command_count == max_commands) return error.ControlCommandHistoryFull;

        var action: Action = .{ .changed = true };
        switch (command.kind) {
            .start_recovery => {
                if (self.mode != .stopped) return error.InvalidOperationalTransition;
                self.mode = .recovering;
            },
            .enable_trading => {
                if (self.mode != .ready or self.self_recovering_closed or self.hasUnresolvedLatch())
                    return error.TradingSafetyGateClosed;
                self.trading_authorized = true;
                self.mode = .trading;
            },
            .cancel_open_orders => action.cancel_open_orders = true,
            .trading_pause => {
                try self.startOperation(command.command_identity, .trading_pause);
                self.trading_authorized = false;
                self.mode = .draining;
                action.cancel_open_orders = true;
            },
            .stop_keep_positions => {
                if (self.active_operation_identity != 0) return error.LifecycleOperationConflict;
                self.trading_authorized = false;
                self.mode = .stopped;
                action.cancel_open_orders = true;
            },
            .de_risk => {
                if (command.target_position == 0 and
                    (command.risk_warning_identity == 0 or
                        command.risk_warning_identity != self.last_risk_warning_identity))
                    return error.RiskWarningRequired;
                try self.startOperation(command.command_identity, .de_risk);
                self.trading_authorized = false;
                self.mode = .draining;
                self.target_position = command.target_position;
                action.cancel_open_orders = true;
                action.cancel_increasing_only = true;
            },
            .resolve_latch => {
                const latch_record = self.findLatch(command.referenced_latch_identity) orelse
                    return error.UnknownLatchIdentity;
                if (latch_record.resolved) return error.LatchAlreadyResolved;
                latch_record.resolved = true;
                self.trading_authorized = false;
                if (self.mode != .draining and self.mode != .stopped) self.mode = .ready;
            },
        }
        self.command_history[self.command_count] = .{ .command = command };
        self.command_count += 1;
        self.version += 1;
        return action;
    }

    /// Marks deterministic state reconstruction complete.
    pub fn recoveryCompleted(self: *State) !void {
        if (self.mode != .recovering) return error.InvalidOperationalTransition;
        self.mode = .ready;
        self.version += 1;
    }

    /// Records the durable warning that a later Flatten command must reference.
    pub fn applyRiskWarning(self: *State, warning: RiskWarning) !void {
        if (warning.target_identity != self.target_identity or warning.warning_identity == 0)
            return error.RiskWarningWrongTarget;
        self.last_risk_warning_identity = warning.warning_identity;
        self.version += 1;
    }

    /// Applies a gate observation while preserving latches and continuity loss.
    pub fn applyGate(self: *State, change: SafetyGateChange) !Action {
        if (change.target_identity != self.target_identity or change.gate_identity == 0)
            return error.SafetyGateWrongTarget;
        var gate_index: ?usize = null;
        for (self.gates[0..self.gate_count], 0..) |gate, index| if (gate.gate_identity == change.gate_identity) {
            if (gate.kind != change.kind or gate.reason != change.reason)
                return error.SafetyGateIdentityConflict;
            gate_index = index;
            break;
        };
        if (gate_index) |index| self.gates[index] = change else {
            if (self.gate_count == max_gates) return error.SafetyGateSetFull;
            self.gates[self.gate_count] = change;
            self.gate_count += 1;
        }
        var action: Action = .{ .changed = true };
        switch (change.kind) {
            .warning => {},
            .self_recovering => {
                if (change.open) {
                    if (!change.continuity_proven) {
                        try self.latch(change.gate_identity, change.reason);
                        self.trading_authorized = false;
                        if (self.mode == .trading) self.mode = .ready;
                    } else if (!self.continuity_intact) {
                        try self.latch(change.gate_identity, change.reason);
                        self.trading_authorized = false;
                        if (self.mode == .trading) self.mode = .ready;
                    }
                }
            },
            .latched => {
                if (!change.open) {
                    self.continuity_intact = false;
                    try self.latch(change.gate_identity, change.reason);
                    self.trading_authorized = false;
                    if (self.mode == .trading) self.mode = .ready;
                    action.cancel_open_orders = true;
                    action.cancel_increasing_only = true;
                }
                // An observed cause clearing never clears its latch.
            },
        }
        self.recalculateGates();
        return action;
    }

    /// Advances an active lifecycle only from verified progress evidence.
    pub fn applyProgress(self: *State, progress: LifecycleProgress) !void {
        if (progress.target_identity != self.target_identity or
            progress.operation_identity != self.active_operation_identity)
            return error.LifecycleOperationMismatch;
        if (!progress.open_orders_closed or !progress.reconciliation_complete) return;
        if (self.active_operation_kind == .de_risk and progress.position_quantity != self.target_position)
            return;
        self.active_operation_identity = 0;
        self.mode = .ready;
        self.version += 1;
    }

    fn startOperation(self: *State, identity: u128, kind: CommandKind) !void {
        if (self.active_operation_identity != 0) return error.LifecycleOperationConflict;
        self.active_operation_identity = identity;
        self.active_operation_kind = kind;
    }

    fn findCommand(self: *const State, identity: u128) ?CommandRecord {
        for (self.command_history[0..self.command_count]) |record|
            if (record.command.command_identity == identity) return record;
        return null;
    }

    fn findLatch(self: *State, identity: u128) ?*Latch {
        for (self.latches[0..self.latch_count]) |*latch_record|
            if (latch_record.identity == identity) return latch_record;
        return null;
    }

    fn hasUnresolvedLatch(self: *const State) bool {
        for (self.latches[0..self.latch_count]) |latch_record|
            if (!latch_record.resolved) return true;
        return false;
    }

    fn recalculateGates(self: *State) void {
        self.self_recovering_closed = false;
        self.warning_blocks_buy = false;
        self.warning_blocks_sell = false;
        for (self.gates[0..self.gate_count]) |gate| {
            if (gate.open) continue;
            if (gate.kind == .self_recovering) self.self_recovering_closed = true;
            if (gate.kind == .warning) {
                self.warning_blocks_buy = self.warning_blocks_buy or gate.blocks_buy;
                self.warning_blocks_sell = self.warning_blocks_sell or gate.blocks_sell;
            }
        }
    }

    fn latch(self: *State, identity: u128, reason: GateReason) !void {
        if (self.findLatch(identity)) |existing| {
            if (existing.reason != reason) return error.LatchIdentityConflict;
            return;
        }
        if (self.latch_count == max_latches) return error.LatchHistoryFull;
        self.latches[self.latch_count] = .{ .identity = identity, .reason = reason };
        self.latch_count += 1;
    }
};

test "control authorization and latched recovery remain orthogonal" {
    var state = State.init(7);
    _ = try state.applyCommand(.{ .command_identity = 1, .content_hash = 1, .target_identity = 7, .expected_version = 0, .expires_at = 10, .kind = .start_recovery }, 1);
    try state.recoveryCompleted();
    _ = try state.applyCommand(.{ .command_identity = 2, .content_hash = 2, .target_identity = 7, .expected_version = 2, .expires_at = 10, .kind = .enable_trading }, 1);
    try std.testing.expect(state.effectiveTradingAuthority());
    _ = try state.applyGate(.{ .gate_identity = 9, .target_identity = 7, .kind = .latched, .reason = .reconciliation_break, .open = false });
    try std.testing.expect(!state.effectiveTradingAuthority());
    _ = try state.applyCommand(.{ .command_identity = 3, .content_hash = 3, .target_identity = 7, .expected_version = 3, .expires_at = 10, .kind = .resolve_latch, .referenced_latch_identity = 9 }, 1);
    try std.testing.expectEqual(OperationalMode.ready, state.mode);
    try std.testing.expect(!state.trading_authorized);
}
/// Durable warning presented before a high-risk operation.
pub const RiskWarning = struct { warning_identity: u128, target_identity: u128 };
