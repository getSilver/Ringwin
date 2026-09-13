const std = @import("std");
const canonical = @import("canonical_event.zig");

pub const max_orders = 8;
pub const max_group_members = 4;
pub const max_commands = 8;
const max_command_history = 32;
const max_fact_history = 32;
const max_intent_history = 64;
pub const max_tombstones = 2;

pub const Instrument = canonical.InstrumentIdentity;
pub const Quantity = canonical.InstrumentQuantity;
pub const Price = canonical.InstrumentPrice;
pub const Reservation = canonical.AssetAmount;
pub const Side = enum(u8) { buy, sell };
pub const Operation = enum(u8) { place, amend, cancel };
pub const PartialExecutionPolicy = enum(u8) { independent, cancel_remaining };
pub const DispatchState = enum(u8) { not_sent, submitted, unknown };
pub const OrderState = enum(u8) {
    pending_submit,
    unknown,
    live,
    partially_filled,
    pending_amend,
    pending_cancel,
    filled,
    canceled,
    rejected,
};
pub const ReportStatus = enum(u8) { accepted, partially_filled, filled, canceled, rejected, amended };
pub const ReconciliationStatus = enum(u8) { found_live, found_terminal, confirmed_absent, unresolved };
pub const TerminalState = enum(u8) { filled, canceled, rejected };

pub const Intent = struct {
    intent_sequence: u64,
    strategy_instance: u128 = 0,
    operation: Operation,
    instrument: Instrument,
    side: Side = .buy,
    portfolio_reduce_only: bool = false,
    venue_reduce_only: bool = false,
    target_order_id: u64 = 0,
    expected_revision: u32 = 0,
    expected_cumulative_quantity: i64 = 0,
    quantity: i64 = 0,
    limit_price: Price = .{ .instrument = 0, .rules_version = 0, .ticks = 0 },
    native_amend: bool = true,
    allow_cancel_confirm_create: bool = false,
    reservation: Reservation = .{ .asset = 0, .atoms = 0 },
    order_type: canonical.OrderType = .limit,
    time_in_force: canonical.TimeInForce = .good_til_canceled,
    market_protection_price: ?Price = null,
    client_order_id: canonical.ClientOrderId = .{},
};

pub const IntentGroup = struct {
    first_intent_sequence: u64,
    policy: PartialExecutionPolicy = .independent,
    members: [max_group_members]Intent = undefined,
    count: u8,
};

pub const DispatchItem = struct {
    command_id: u64,
    state: DispatchState,
    definite_reject: bool = false,
};

pub const DispatchBatch = struct {
    items: [max_commands]DispatchItem = undefined,
    count: u8,
};

pub const ExecutionReport = struct {
    report_id: u64,
    order_id: u64,
    revision: u32,
    status: ReportStatus,
    cumulative_quantity: i64,
    remaining_quantity: i64,
};

pub const ReconciliationResult = struct {
    reconciliation_id: u64,
    order_id: u64,
    status: ReconciliationStatus,
    revision: u32,
    cumulative_quantity: i64,
    remaining_quantity: i64,
    terminal_state: ?TerminalState = null,
};

pub const Command = struct {
    command_id: u64,
    order_id: u64,
    strategy_instance: u128,
    revision: u32,
    operation: Operation,
    instrument: Instrument,
    side: Side,
    portfolio_reduce_only: bool,
    venue_reduce_only: bool,
    quantity: i64,
    limit_price: Price,
    predecessor_order_id: u64 = 0,
    reservation: Reservation,
    order_type: canonical.OrderType = .limit,
    time_in_force: canonical.TimeInForce = .good_til_canceled,
    market_protection_price: ?Price = null,
    client_order_id: canonical.ClientOrderId = .{},
    intent_sequence: u64 = 0,
    risk_decision_identity: u64 = 0,
    reservation_identity: u64 = 0,
};

pub const Order = struct {
    id: u64,
    strategy_instance: u128,
    instrument: Instrument,
    side: Side,
    portfolio_reduce_only: bool,
    venue_reduce_only: bool,
    revision: u32 = 1,
    state: OrderState = .pending_submit,
    quantity: i64,
    limit_price: Price,
    cumulative_quantity: i64 = 0,
    predecessor_order_id: u64 = 0,
    reservation: Reservation,
    confirmed_reservation: Reservation,
    reservation_basis_quantity: i64,
    pending_reservation: ?Reservation = null,
    order_type: canonical.OrderType = .limit,
    time_in_force: canonical.TimeInForce = .good_til_canceled,
    market_protection_price: ?Price = null,
    client_order_id: canonical.ClientOrderId,
    reservation_active: bool = true,
    dispatch_submitted: bool = false,
    group_first_sequence: u64,
    group_policy: PartialExecutionPolicy,
    replacement: ?Replacement = null,
    last_report_id: u64 = 0,
    last_report_revision: u32 = 0,
    last_report_status: ReportStatus = .accepted,
    last_report_cumulative_quantity: i64 = 0,
    last_report_remaining_quantity: i64 = 0,
    last_reconciliation_id: u64 = 0,
    last_reconciliation_status: ReconciliationStatus = .unresolved,
    last_reconciliation_revision: u32 = 0,
    last_reconciliation_cumulative_quantity: i64 = 0,
    last_reconciliation_remaining_quantity: i64 = 0,
};

pub const Tombstone = struct {
    order_id: u64,
    strategy_instance: u128,
    instrument: Instrument,
    revision: u32,
    state: OrderState,
    quantity: i64,
    cumulative_quantity: i64,
    predecessor_order_id: u64,
    group_first_sequence: u64,
    last_report_id: u64,
    last_reconciliation_id: u64,
    last_report: ?ExecutionReport,
    last_reconciliation: ?ReconciliationResult,
    intent_sequence: u64,
    client_order_id: canonical.ClientOrderId,
    fact_digest: [32]u8,
};

const Replacement = struct { instrument: Instrument, side: Side, portfolio_reduce_only: bool, venue_reduce_only: bool, quantity: i64, limit_price: Price, reservation: Reservation, order_type: canonical.OrderType, time_in_force: canonical.TimeInForce, market_protection_price: ?Price, client_order_id: canonical.ClientOrderId };
pub const SeenIntent = struct { strategy_instance: u128, intent_sequence: u64, group: u64, policy: PartialExecutionPolicy, fingerprint: u64 };

pub const Oms = struct {
    orders: [max_orders]Order = undefined,
    order_count: u8 = 0,
    commands: [max_commands]Command = undefined,
    command_count: u8 = 0,
    command_history: [max_command_history]Command = undefined,
    command_history_count: u8 = 0,
    report_history: [max_fact_history]ExecutionReport = undefined,
    report_history_count: u8 = 0,
    reconciliation_history: [max_fact_history]ReconciliationResult = undefined,
    reconciliation_history_count: u8 = 0,
    intent_history: [max_intent_history]SeenIntent = undefined,
    intent_history_count: u8 = 0,
    tombstones: [max_tombstones]Tombstone = undefined,
    tombstone_count: u8 = 0,
    recovery_only: bool = false,
    next_order_id: u64 = 1,
    next_command_id: u64 = 1,

    pub fn begin(self: *Oms) void {
        self.command_count = 0;
    }

    pub fn emitted(self: *const Oms) []const Command {
        return self.commands[0..self.command_count];
    }

    /// Rebuilds the durable cancel outbox after replay without changing order state.
    pub fn pendingCancelCommands(self: *const Oms, destination: []Command) ![]const Command {
        var count: usize = 0;
        for (self.orders[0..self.order_count]) |order| {
            if (order.state != .pending_cancel) continue;
            var index = self.command_history_count;
            while (index != 0) {
                index -= 1;
                const command = self.command_history[index];
                if (command.order_id == order.id and command.operation == .cancel) {
                    if (count == destination.len) return error.CommandCapacityExceeded;
                    destination[count] = command;
                    count += 1;
                    break;
                }
            }
        }
        return destination[0..count];
    }

    /// Emits at most one cancel for every non-terminal order in scope.
    pub fn cancelOpenOrders(self: *Oms, increasing_only: bool) !void {
        for (self.orders[0..self.order_count]) |*order| {
            if (order.state == .filled or order.state == .canceled or order.state == .rejected or
                order.state == .pending_cancel or
                (increasing_only and order.portfolio_reduce_only and order.venue_reduce_only))
                continue;
            order.state = .pending_cancel;
            try self.emit(order.*, .cancel, order.group_first_sequence);
        }
    }

    /// Cancels only orders owned by one strategy instance.
    pub fn cancelStrategyOrders(self: *Oms, strategy_instance: u128) !void {
        if (strategy_instance == 0) return error.InvalidStrategyInstance;
        for (self.orders[0..self.order_count]) |*order| {
            if (order.strategy_instance != strategy_instance or order.state == .filled or
                order.state == .canceled or order.state == .rejected or order.state == .pending_cancel)
                continue;
            order.state = .pending_cancel;
            try self.emit(order.*, .cancel, order.group_first_sequence);
        }
    }

    pub fn activeReservations(self: *const Oms, asset: canonical.AssetIdentity) !Reservation {
        var total: Reservation = .{ .asset = asset, .atoms = 0 };
        for (self.orders[0..self.order_count]) |order| {
            if (!order.reservation_active) continue;
            if (total.asset != order.reservation.asset) return error.MixedReservationAssets;
            total.atoms = try std.math.add(i128, total.atoms, order.reservation.atoms);
        }
        return total;
    }

    /// True only when authoritative order state contains no live or unknown order.
    pub fn openOrdersClosed(self: *const Oms) bool {
        for (self.orders[0..self.order_count]) |order| switch (order.state) {
            .filled, .canceled, .rejected => {},
            else => return false,
        };
        return true;
    }

    /// Unknown and PendingCancel must not overlap a later place or amend send.
    pub fn blocksNewSend(self: *const Oms) bool {
        for (self.orders[0..self.order_count]) |order| switch (order.state) {
            .unknown, .pending_cancel => return true,
            else => {},
        };
        return false;
    }

    pub fn orderById(self: *const Oms, id: u64) ?Order {
        for (self.orders[0..self.order_count]) |order| if (order.id == id) return order;
        return null;
    }

    pub fn instrumentForOrder(self: *const Oms, id: u64) ?Instrument {
        if (self.orderById(id)) |order| return order.instrument;
        if (self.tombstoneById(id)) |tombstone| return tombstone.instrument;
        return null;
    }

    pub fn groupKnown(self: *const Oms, group: IntentGroup) bool {
        if (group.count == 0 or group.count > max_group_members) return false;
        var known_count: u8 = 0;
        for (group.members[0..group.count]) |intent| {
            for (self.intent_history[0..self.intent_history_count]) |known| {
                if (known.strategy_instance == intent.strategy_instance and known.intent_sequence == intent.intent_sequence and
                    known.group == group.first_intent_sequence and known.policy == group.policy and known.fingerprint == intentFingerprint(intent))
                {
                    known_count += 1;
                    break;
                }
            }
        }
        return known_count == group.count;
    }

    pub fn applyGroup(self: *Oms, group: IntentGroup) !void {
        var candidate = self.*;
        candidate.applyGroupInPlace(group) catch |err| {
            // Capacity exhaustion is an authoritative safety transition even
            // though the rejected intent group itself is not committed.
            if (candidate.recovery_only) self.recovery_only = true;
            return err;
        };
        self.* = candidate;
    }

    fn applyGroupInPlace(self: *Oms, group: IntentGroup) !void {
        if (group.count == 0 or group.count > max_group_members) return error.InvalidIntentGroup;
        var duplicate_count: u8 = 0;
        for (group.members[0..group.count], 0..) |intent, index| {
            if (intent.intent_sequence != try std.math.add(u64, group.first_intent_sequence, index))
                return error.NonConsecutiveIntentGroup;
            for (self.intent_history[0..self.intent_history_count]) |known| {
                if (known.strategy_instance != intent.strategy_instance or known.intent_sequence != intent.intent_sequence) continue;
                if (known.fingerprint != intentFingerprint(intent) or known.group != group.first_intent_sequence or known.policy != group.policy)
                    return error.ConflictingIntentIdentity;
                duplicate_count += 1;
                break;
            }
        }
        if (duplicate_count == group.count) return;
        if (duplicate_count != 0) return error.PartialDuplicateIntentGroup;
        if (self.intent_history_count + group.count > max_intent_history) {
            self.recovery_only = true;
            return error.IdentitySetFull;
        }
        if (self.blocksNewSend()) {
            for (group.members[0..group.count]) |intent| switch (intent.operation) {
                .place, .amend => return error.UncertainOrderBlocksSend,
                .cancel => {},
            };
        }
        for (group.members[0..group.count]) |intent| {
            self.applyIntent(intent, group.first_intent_sequence, group.policy) catch |err| {
                if (group.policy == .cancel_remaining) try self.cancelGroup(group.first_intent_sequence);
                return err;
            };
            self.intent_history[self.intent_history_count] = .{ .strategy_instance = intent.strategy_instance, .intent_sequence = intent.intent_sequence, .group = group.first_intent_sequence, .policy = group.policy, .fingerprint = intentFingerprint(intent) };
            self.intent_history_count += 1;
        }
    }

    fn applyIntent(self: *Oms, intent: Intent, group: u64, policy: PartialExecutionPolicy) !void {
        switch (intent.operation) {
            .place => {
                if (intent.quantity <= 0 or intent.limit_price.ticks <= 0 or intent.reservation.atoms <= 0 or intent.limit_price.instrument != intent.instrument) return error.InvalidOrderSpec;
                const order = try self.createOrder(intent.strategy_instance, intent.instrument, intent.side, intent.portfolio_reduce_only, intent.venue_reduce_only, intent.quantity, intent.limit_price, intent.reservation, intent.client_order_id, 0, group, policy);
                order.order_type = intent.order_type;
                order.time_in_force = intent.time_in_force;
                order.market_protection_price = intent.market_protection_price;
                try self.emit(order.*, .place, intent.intent_sequence);
            },
            .amend => {
                const order = try self.mutableOrder(intent.target_order_id);
                try validateTarget(order, intent);
                if (intent.quantity <= 0 or intent.limit_price.ticks <= 0 or intent.limit_price.instrument != intent.instrument) return error.InvalidOrderSpec;
                if (intent.native_amend) {
                    order.revision = try std.math.add(u32, order.revision, 1);
                    order.state = .pending_amend;
                    order.quantity = try std.math.add(i64, order.cumulative_quantity, intent.quantity);
                    order.limit_price = intent.limit_price;
                    order.order_type = intent.order_type;
                    order.time_in_force = intent.time_in_force;
                    order.market_protection_price = intent.market_protection_price;
                    order.pending_reservation = intent.reservation;
                    if (order.reservation.asset != intent.reservation.asset) return error.MixedReservationAssets;
                    if (intent.reservation.atoms > order.reservation.atoms) order.reservation = intent.reservation;
                    try self.emit(order.*, .amend, intent.intent_sequence);
                } else {
                    if (!intent.allow_cancel_confirm_create) return error.CancelConfirmCreateNotAuthorized;
                    order.state = .pending_cancel;
                    if (intent.reservation.atoms <= 0) return error.InvalidOrderSpec;
                    order.replacement = .{ .instrument = order.instrument, .side = intent.side, .portfolio_reduce_only = intent.portfolio_reduce_only, .venue_reduce_only = intent.venue_reduce_only, .quantity = intent.quantity, .limit_price = intent.limit_price, .reservation = intent.reservation, .order_type = intent.order_type, .time_in_force = intent.time_in_force, .market_protection_price = intent.market_protection_price, .client_order_id = intent.client_order_id };
                    try self.emit(order.*, .cancel, intent.intent_sequence);
                }
            },
            .cancel => {
                const order = try self.mutableOrder(intent.target_order_id);
                try validateTarget(order, intent);
                order.state = .pending_cancel;
                try self.emit(order.*, .cancel, intent.intent_sequence);
            },
        }
    }

    pub fn applyDispatch(self: *Oms, batch: DispatchBatch) !void {
        var candidate = self.*;
        try candidate.applyDispatchInPlace(batch);
        self.* = candidate;
    }

    fn applyDispatchInPlace(self: *Oms, batch: DispatchBatch) !void {
        if (batch.count == 0 or batch.count > max_commands) return error.InvalidDispatchBatch;
        for (batch.items[0..batch.count]) |item| {
            const command_value = self.findCommand(item.command_id) orelse return error.UnknownCommand;
            const order = try self.mutableOrder(command_value.order_id);
            switch (item.state) {
                .unknown => {
                    order.state = .unknown;
                    order.dispatch_submitted = true;
                },
                .submitted => {
                    order.dispatch_submitted = true;
                    if (item.definite_reject) {
                        self.rejectCommand(order, command_value.operation);
                        if (order.group_policy == .cancel_remaining) try self.cancelGroup(order.group_first_sequence);
                    }
                },
                .not_sent => {
                    self.rejectCommand(order, command_value.operation);
                    if (order.group_policy == .cancel_remaining) try self.cancelGroup(order.group_first_sequence);
                },
            }
        }
    }

    pub fn applyReport(self: *Oms, report: ExecutionReport) !void {
        var candidate = self.*;
        candidate.applyReportInPlace(report) catch |err| {
            if (candidate.recovery_only) self.recovery_only = true;
            return err;
        };
        self.* = candidate;
    }

    fn applyReportInPlace(self: *Oms, report: ExecutionReport) !void {
        for (self.report_history[0..self.report_history_count]) |known| {
            if (known.order_id == report.order_id and known.report_id == report.report_id) {
                if (!std.meta.eql(known, report)) {
                    if (self.tombstoneById(report.order_id) != null) {
                        self.recovery_only = true;
                        return error.TombstoneFactConflict;
                    }
                    return error.ConflictingReportIdentity;
                }
                return;
            }
        }
        if (self.report_history_count == max_fact_history) {
            self.recovery_only = true;
            return error.IdentitySetFull;
        }
        const order = self.mutableOrder(report.order_id) catch {
            if (self.tombstoneById(report.order_id)) |tombstone| {
                if (tombstone.last_report) |known| if (std.meta.eql(known, report)) return;
                self.recovery_only = true;
                return error.TombstoneFactConflict;
            }
            if (report.order_id < self.next_order_id) {
                self.recovery_only = true;
                return error.ArchivedFactOutsideRetention;
            }
            return error.UnknownOrder;
        };
        self.report_history[self.report_history_count] = report;
        self.report_history_count += 1;
        if (report.report_id < order.last_report_id) return;
        if (report.report_id == order.last_report_id) {
            if (report.revision != order.last_report_revision or report.status != order.last_report_status or
                report.cumulative_quantity != order.last_report_cumulative_quantity or
                report.remaining_quantity != order.last_report_remaining_quantity)
                return error.ConflictingReportIdentity;
            return;
        }
        if (order.state == .filled or order.state == .canceled or order.state == .rejected) {
            self.recovery_only = true;
            return error.TerminalFactConflict;
        }
        const reported_quantity = std.math.add(i64, report.cumulative_quantity, report.remaining_quantity) catch return error.Overflow;
        if (report.cumulative_quantity < order.cumulative_quantity or report.remaining_quantity < 0 or
            reported_quantity > order.quantity or
            (report.status == .filled and (report.cumulative_quantity != order.quantity or report.remaining_quantity != 0)))
            return error.InvalidExecutionReport;
        if (report.status == .amended and report.revision != order.revision) return error.StaleOrderRevision;
        if (report.status == .rejected and order.state == .pending_amend) {
            rememberReport(order, report);
            self.rejectCommand(order, .amend);
            return;
        }
        if (report.status == .rejected and order.state == .pending_cancel) {
            rememberReport(order, report);
            self.rejectCommand(order, .cancel);
            return;
        }
        rememberReport(order, report);
        order.cumulative_quantity = report.cumulative_quantity;
        order.state = switch (report.status) {
            .accepted => .live,
            .partially_filled => .partially_filled,
            .filled => .filled,
            .canceled => .canceled,
            .rejected => .rejected,
            .amended => .live,
        };
        if (report.status == .filled or report.status == .canceled or report.status == .rejected) {
            order.reservation_active = false;
            order.reservation.atoms = 0;
        } else {
            try rebalanceReservation(order, report.remaining_quantity);
        }
        if (report.status == .amended) {
            order.confirmed_reservation = order.pending_reservation orelse order.confirmed_reservation;
            order.reservation = order.confirmed_reservation;
            order.reservation_basis_quantity = report.remaining_quantity;
            order.pending_reservation = null;
        }
        if (report.status == .filled) order.replacement = null;
    }

    pub fn applyReconciliation(self: *Oms, result: ReconciliationResult) !void {
        var candidate = self.*;
        candidate.applyReconciliationInPlace(result) catch |err| {
            if (candidate.recovery_only) self.recovery_only = true;
            return err;
        };
        self.* = candidate;
    }

    fn applyReconciliationInPlace(self: *Oms, result: ReconciliationResult) !void {
        for (self.reconciliation_history[0..self.reconciliation_history_count]) |known| {
            if (known.order_id == result.order_id and known.reconciliation_id == result.reconciliation_id) {
                if (!std.meta.eql(known, result)) {
                    if (self.tombstoneById(result.order_id) != null) {
                        self.recovery_only = true;
                        return error.TombstoneFactConflict;
                    }
                    return error.ConflictingReconciliationIdentity;
                }
                return;
            }
        }
        const order = self.mutableOrder(result.order_id) catch {
            if (self.tombstoneById(result.order_id)) |tombstone| {
                if (tombstone.last_reconciliation) |known| if (std.meta.eql(known, result)) return;
                self.recovery_only = true;
                return error.TombstoneFactConflict;
            }
            if (result.order_id < self.next_order_id) {
                self.recovery_only = true;
                return error.ArchivedFactOutsideRetention;
            }
            return error.UnknownOrder;
        };
        const reconciled_quantity = std.math.add(i64, result.cumulative_quantity, result.remaining_quantity) catch return error.Overflow;
        if (result.cumulative_quantity < 0 or result.remaining_quantity < 0) return error.InvalidReconciliationResult;
        if (reconciled_quantity > order.quantity) return error.ConflictingReconciliationEvidence;
        switch (result.status) {
            .unresolved => if (result.terminal_state != null) return error.ConflictingReconciliationEvidence,
            .found_live => if (result.terminal_state != null or reconciled_quantity != order.quantity) return error.ConflictingReconciliationEvidence,
            .found_terminal => {
                if (result.terminal_state == null) return error.IncompleteReconciliationEvidence;
                if (result.terminal_state.? == .filled and
                    (result.cumulative_quantity != order.quantity or result.remaining_quantity != 0))
                    return error.ConflictingReconciliationEvidence;
            },
            .confirmed_absent => if (result.terminal_state != null or result.cumulative_quantity != 0 or result.remaining_quantity != order.quantity) return error.ConflictingReconciliationEvidence,
        }
        if (self.reconciliation_history_count == max_fact_history) {
            self.recovery_only = true;
            return error.IdentitySetFull;
        }
        self.reconciliation_history[self.reconciliation_history_count] = result;
        self.reconciliation_history_count += 1;
        if (result.reconciliation_id < order.last_reconciliation_id) return;
        if (result.reconciliation_id == order.last_reconciliation_id) {
            if (result.status != order.last_reconciliation_status or result.revision != order.last_reconciliation_revision or
                result.cumulative_quantity != order.last_reconciliation_cumulative_quantity or
                result.remaining_quantity != order.last_reconciliation_remaining_quantity)
                return error.ConflictingReconciliationIdentity;
            return;
        }
        if (order.state == .filled or order.state == .canceled or order.state == .rejected) {
            const expected: TerminalState = switch (order.state) {
                .filled => .filled,
                .canceled => .canceled,
                .rejected => .rejected,
                else => unreachable,
            };
            if (result.status != .found_terminal or result.terminal_state.? != expected or
                result.cumulative_quantity != order.cumulative_quantity or
                result.remaining_quantity != order.quantity - order.cumulative_quantity or
                order.last_reconciliation_id != 0)
            {
                self.recovery_only = true;
                return error.TerminalFactConflict;
            }
        }
        order.last_reconciliation_id = result.reconciliation_id;
        order.last_reconciliation_status = result.status;
        order.last_reconciliation_revision = result.revision;
        order.last_reconciliation_cumulative_quantity = result.cumulative_quantity;
        order.last_reconciliation_remaining_quantity = result.remaining_quantity;
        if (order.state == .filled or order.state == .canceled or order.state == .rejected) return;
        switch (result.status) {
            .unresolved => order.state = .unknown,
            .found_live => {
                order.revision = result.revision;
                order.cumulative_quantity = result.cumulative_quantity;
                order.quantity = try std.math.add(i64, result.cumulative_quantity, result.remaining_quantity);
                order.state = if (result.cumulative_quantity == 0) .live else .partially_filled;
                try rebalanceReservation(order, result.remaining_quantity);
            },
            .found_terminal => {
                order.cumulative_quantity = result.cumulative_quantity;
                order.state = switch (result.terminal_state.?) {
                    .filled => .filled,
                    .canceled => .canceled,
                    .rejected => .rejected,
                };
                order.reservation_active = false;
                order.reservation.atoms = 0;
            },
            .confirmed_absent => {
                order.state = .canceled;
                order.reservation_active = false;
                order.reservation.atoms = 0;
            },
        }
    }

    pub fn replacementIntent(self: *const Oms, order_id: u64, sequence: u64) !?Intent {
        const order = self.orderById(order_id) orelse return error.UnknownOrder;
        const replacement = order.replacement orelse return null;
        if (order.state != .canceled) return null;
        return .{
            .intent_sequence = sequence,
            .strategy_instance = order.strategy_instance,
            .operation = .place,
            .instrument = replacement.instrument,
            .side = replacement.side,
            .portfolio_reduce_only = replacement.portfolio_reduce_only,
            .quantity = replacement.quantity,
            .limit_price = replacement.limit_price,
            .order_type = replacement.order_type,
            .time_in_force = replacement.time_in_force,
            .market_protection_price = replacement.market_protection_price,
        };
    }

    pub fn confirmReplacement(self: *Oms, order_id: u64, reservation: Reservation, portfolio_reduce_only: bool, venue_reduce_only: bool) !void {
        const predecessor = try self.mutableOrder(order_id);
        if (predecessor.state != .canceled or predecessor.replacement == null) return error.ReplacementNotReady;
        if (self.blocksNewSend()) return error.UncertainOrderBlocksSend;
        predecessor.replacement.?.reservation = reservation;
        predecessor.replacement.?.portfolio_reduce_only = portfolio_reduce_only;
        predecessor.replacement.?.venue_reduce_only = venue_reduce_only;
        try self.createReplacement(predecessor);
    }

    pub fn discardReplacement(self: *Oms, order_id: u64) !void {
        const predecessor = try self.mutableOrder(order_id);
        predecessor.replacement = null;
    }

    fn createOrder(self: *Oms, strategy_instance: u128, instrument: Instrument, side: Side, portfolio_reduce_only: bool, venue_reduce_only: bool, quantity: i64, price: Price, reservation: Reservation, requested_client_order_id: canonical.ClientOrderId, predecessor: u64, group: u64, policy: PartialExecutionPolicy) !*Order {
        if (self.recovery_only) return error.OmsRecoveryOnly;
        if (self.order_count == max_orders) self.compactOne() catch |err| {
            self.recovery_only = true;
            return err;
        };
        const index = self.order_count;
        self.order_count += 1;
        var client_order_id = requested_client_order_id;
        if (client_order_id.len == 0) {
            var storage: [64]u8 = undefined;
            client_order_id = try canonical.ClientOrderId.init(try std.fmt.bufPrint(&storage, "RWN-{d}", .{self.next_order_id}));
        }
        self.orders[index] = .{ .id = self.next_order_id, .strategy_instance = strategy_instance, .instrument = instrument, .side = side, .portfolio_reduce_only = portfolio_reduce_only, .venue_reduce_only = venue_reduce_only, .quantity = quantity, .limit_price = price, .reservation = reservation, .confirmed_reservation = reservation, .reservation_basis_quantity = quantity, .predecessor_order_id = predecessor, .group_first_sequence = group, .group_policy = policy, .client_order_id = client_order_id };
        self.next_order_id = try std.math.add(u64, self.next_order_id, 1);
        return &self.orders[index];
    }

    fn emit(self: *Oms, order: Order, operation: Operation, intent_sequence: u64) !void {
        if (self.command_count == max_commands or self.command_history_count == max_command_history) {
            self.recovery_only = true;
            return error.CommandCapacityExceeded;
        }
        const command_value: Command = .{ .command_id = self.next_command_id, .order_id = order.id, .strategy_instance = order.strategy_instance, .revision = order.revision, .operation = operation, .instrument = order.instrument, .side = order.side, .portfolio_reduce_only = order.portfolio_reduce_only, .venue_reduce_only = order.venue_reduce_only, .quantity = try std.math.sub(i64, order.quantity, order.cumulative_quantity), .limit_price = order.limit_price, .predecessor_order_id = order.predecessor_order_id, .reservation = order.reservation, .order_type = order.order_type, .time_in_force = order.time_in_force, .market_protection_price = order.market_protection_price, .client_order_id = order.client_order_id, .intent_sequence = intent_sequence, .risk_decision_identity = order.group_first_sequence, .reservation_identity = order.group_first_sequence };
        self.commands[self.command_count] = command_value;
        self.command_count += 1;
        self.command_history[self.command_history_count] = command_value;
        self.command_history_count += 1;
        self.next_command_id = try std.math.add(u64, self.next_command_id, 1);
    }

    fn createReplacement(self: *Oms, predecessor: *Order) !void {
        const replacement = predecessor.replacement.?;
        predecessor.replacement = null;
        const next = try self.createOrder(predecessor.strategy_instance, replacement.instrument, replacement.side, replacement.portfolio_reduce_only, replacement.venue_reduce_only, replacement.quantity, replacement.limit_price, replacement.reservation, replacement.client_order_id, predecessor.id, predecessor.group_first_sequence, predecessor.group_policy);
        next.order_type = replacement.order_type;
        next.time_in_force = replacement.time_in_force;
        next.market_protection_price = replacement.market_protection_price;
        try self.emit(next.*, .place, predecessor.group_first_sequence);
    }

    fn rejectCommand(_: *Oms, order: *Order, operation: Operation) void {
        switch (operation) {
            .place => {
                order.state = .rejected;
                order.reservation_active = false;
            },
            .amend => {
                order.state = if (order.cumulative_quantity == 0) .live else .partially_filled;
                order.reservation = order.confirmed_reservation;
                order.pending_reservation = null;
            },
            .cancel => order.state = if (order.cumulative_quantity == 0) .live else .partially_filled,
        }
    }

    fn cancelGroup(self: *Oms, group: u64) !void {
        var index: usize = 0;
        while (index < self.order_count) : (index += 1) {
            const order = &self.orders[index];
            if (order.group_first_sequence == group) switch (order.state) {
                .pending_submit, .pending_amend => {
                    if (order.dispatch_submitted) {
                        order.state = .pending_cancel;
                        try self.emit(order.*, .cancel, order.group_first_sequence);
                    } else {
                        order.state = .rejected;
                        order.reservation_active = false;
                    }
                },
                .live, .partially_filled => {
                    order.state = .pending_cancel;
                    try self.emit(order.*, .cancel, order.group_first_sequence);
                },
                else => {},
            };
        }
    }

    fn mutableOrder(self: *Oms, id: u64) !*Order {
        for (self.orders[0..self.order_count]) |*order| if (order.id == id) return order;
        return error.UnknownOrder;
    }

    fn tombstoneById(self: *const Oms, id: u64) ?Tombstone {
        for (self.tombstones[0..self.tombstone_count]) |tombstone| if (tombstone.order_id == id) return tombstone;
        return null;
    }

    fn compactOne(self: *Oms) !void {
        if (self.tombstone_count == max_tombstones) return error.TombstoneCapacityExceeded;
        var index: usize = 0;
        while (index < self.order_count) : (index += 1) {
            const order = self.orders[index];
            if (order.reservation_active or order.replacement != null) continue;
            switch (order.state) {
                .filled, .canceled, .rejected => {},
                else => continue,
            }
            const last_report = try self.lastReportEvidence(order);
            const last_reconciliation = try self.lastReconciliationEvidence(order);
            self.tombstones[self.tombstone_count] = .{
                .order_id = order.id,
                .strategy_instance = order.strategy_instance,
                .instrument = order.instrument,
                .revision = order.revision,
                .state = order.state,
                .quantity = order.quantity,
                .cumulative_quantity = order.cumulative_quantity,
                .predecessor_order_id = order.predecessor_order_id,
                .group_first_sequence = order.group_first_sequence,
                .last_report_id = order.last_report_id,
                .last_reconciliation_id = order.last_reconciliation_id,
                .last_report = last_report,
                .last_reconciliation = last_reconciliation,
                .intent_sequence = order.group_first_sequence,
                .client_order_id = order.client_order_id,
                .fact_digest = orderFactDigest(order, last_report, last_reconciliation),
            };
            self.tombstone_count += 1;
            var move = index;
            while (move + 1 < self.order_count) : (move += 1) self.orders[move] = self.orders[move + 1];
            self.order_count -= 1;
            return;
        }
        return error.OrderCapacityExceeded;
    }

    fn lastReportEvidence(self: *const Oms, order: Order) !?ExecutionReport {
        if (order.last_report_id == 0) return null;
        for (self.report_history[0..self.report_history_count]) |known|
            if (known.order_id == order.id and known.report_id == order.last_report_id and
                known.revision == order.last_report_revision and known.status == order.last_report_status and
                known.cumulative_quantity == order.last_report_cumulative_quantity and
                known.remaining_quantity == order.last_report_remaining_quantity)
                return known;
        return error.MissingTerminalAuditEvidence;
    }

    fn lastReconciliationEvidence(self: *const Oms, order: Order) !?ReconciliationResult {
        if (order.last_reconciliation_id == 0) return null;
        for (self.reconciliation_history[0..self.reconciliation_history_count]) |known|
            if (known.order_id == order.id and known.reconciliation_id == order.last_reconciliation_id and
                known.status == order.last_reconciliation_status and known.revision == order.last_reconciliation_revision and
                known.cumulative_quantity == order.last_reconciliation_cumulative_quantity and
                known.remaining_quantity == order.last_reconciliation_remaining_quantity)
                return known;
        return error.MissingTerminalAuditEvidence;
    }

    fn findCommand(self: *const Oms, id: u64) ?Command {
        for (self.command_history[0..self.command_history_count]) |command_value| if (command_value.command_id == id) return command_value;
        return null;
    }
};

fn validateTarget(order: *const Order, intent: Intent) !void {
    if (order.revision != intent.expected_revision or order.cumulative_quantity != intent.expected_cumulative_quantity)
        return error.StaleOrderRevision;
    switch (order.state) {
        .live, .partially_filled => {},
        else => return error.OrderNotMutable,
    }
}

fn rebalanceReservation(order: *Order, remaining_quantity: i64) !void {
    if (remaining_quantity < 0 or order.reservation_basis_quantity <= 0 or order.confirmed_reservation.atoms < 0)
        return error.InvalidReservationBasis;
    if (remaining_quantity == 0) {
        order.reservation.atoms = 0;
        return;
    }
    const numerator = try std.math.mul(i128, order.confirmed_reservation.atoms, remaining_quantity);
    order.reservation.atoms = @divFloor(try std.math.add(i128, numerator, order.reservation_basis_quantity - 1), order.reservation_basis_quantity);
}

fn intentFingerprint(intent: Intent) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&intent.intent_sequence));
    hash.update(std.mem.asBytes(&intent.strategy_instance));
    hash.update(&.{@intFromEnum(intent.operation)});
    hash.update(std.mem.asBytes(&intent.instrument));
    hash.update(&.{ @intFromEnum(intent.side), @intFromBool(intent.portfolio_reduce_only), @intFromBool(intent.venue_reduce_only) });
    hash.update(std.mem.asBytes(&intent.target_order_id));
    hash.update(std.mem.asBytes(&intent.expected_revision));
    hash.update(std.mem.asBytes(&intent.expected_cumulative_quantity));
    hash.update(std.mem.asBytes(&intent.quantity));
    hash.update(std.mem.asBytes(&intent.limit_price.instrument));
    hash.update(std.mem.asBytes(&intent.limit_price.rules_version));
    hash.update(std.mem.asBytes(&intent.limit_price.ticks));
    hash.update(&.{ @intFromBool(intent.native_amend), @intFromBool(intent.allow_cancel_confirm_create) });
    hash.update(std.mem.asBytes(&intent.reservation.asset));
    hash.update(std.mem.asBytes(&intent.reservation.atoms));
    hash.update(&.{ @intFromEnum(intent.order_type), @intFromEnum(intent.time_in_force), @intFromBool(intent.market_protection_price != null) });
    if (intent.market_protection_price) |price| {
        hash.update(std.mem.asBytes(&price.instrument));
        hash.update(std.mem.asBytes(&price.rules_version));
        hash.update(std.mem.asBytes(&price.ticks));
    }
    hash.update(intent.client_order_id.slice());
    return hash.final();
}

fn orderFactDigest(order: Order, last_report: ?ExecutionReport, last_reconciliation: ?ReconciliationResult) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(std.mem.asBytes(&order.id));
    hash.update(std.mem.asBytes(&order.revision));
    hash.update(&.{@intFromEnum(order.state)});
    hash.update(std.mem.asBytes(&order.quantity));
    hash.update(std.mem.asBytes(&order.cumulative_quantity));
    hash.update(std.mem.asBytes(&order.last_report_id));
    hash.update(std.mem.asBytes(&order.last_reconciliation_id));
    hash.update(&.{@intFromBool(last_report != null)});
    if (last_report) |report| {
        hash.update(std.mem.asBytes(&report.report_id));
        hash.update(std.mem.asBytes(&report.order_id));
        hash.update(std.mem.asBytes(&report.revision));
        hash.update(&.{@intFromEnum(report.status)});
        hash.update(std.mem.asBytes(&report.cumulative_quantity));
        hash.update(std.mem.asBytes(&report.remaining_quantity));
    }
    hash.update(&.{@intFromBool(last_reconciliation != null)});
    if (last_reconciliation) |result| {
        hash.update(std.mem.asBytes(&result.reconciliation_id));
        hash.update(std.mem.asBytes(&result.order_id));
        hash.update(&.{@intFromEnum(result.status)});
        hash.update(std.mem.asBytes(&result.revision));
        hash.update(std.mem.asBytes(&result.cumulative_quantity));
        hash.update(std.mem.asBytes(&result.remaining_quantity));
        hash.update(&.{@intFromBool(result.terminal_state != null)});
        hash.update(&.{if (result.terminal_state) |terminal| @intFromEnum(terminal) else 0});
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

test "unknown order rejects a later place without changing identity" {
    var state: Oms = .{};
    var first: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    first.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try state.applyGroup(first);
    var dispatch: DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = state.emitted()[0].command_id, .state = .unknown };
    try state.applyDispatch(dispatch);
    var second: IntentGroup = .{ .first_intent_sequence = 2, .count = 1 };
    second.members[0] = .{ .intent_sequence = 2, .operation = .place, .instrument = 2, .quantity = 1, .limit_price = .{ .instrument = 2, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 4 } };
    try std.testing.expectError(error.UncertainOrderBlocksSend, state.applyGroup(second));
    try std.testing.expectEqual(@as(u8, 1), state.order_count);
}

test "OMS commands retain each member intent identity" {
    var state: Oms = .{};
    var group: IntentGroup = .{ .first_intent_sequence = 7, .count = 2 };
    group.members[0] = .{ .intent_sequence = 7, .operation = .place, .instrument = 1, .quantity = 1, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 3 } };
    group.members[1] = .{ .intent_sequence = 8, .operation = .place, .instrument = 2, .quantity = 1, .limit_price = .{ .instrument = 2, .rules_version = 1, .ticks = 4 }, .reservation = .{ .asset = 1, .atoms = 4 } };
    try state.applyGroup(group);
    try std.testing.expectEqual(@as(u64, 7), state.emitted()[0].intent_sequence);
    try std.testing.expectEqual(@as(u64, 8), state.emitted()[1].intent_sequence);
}

test "pending cancel outbox is reconstructed after replay" {
    var state: Oms = .{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try state.applyGroup(group);
    state.begin();
    try state.cancelOpenOrders(false);
    const cancel = state.emitted()[0];
    var replayed = state;
    replayed.begin();
    var storage: [max_orders]Command = undefined;
    const recovered = try replayed.pendingCancelCommands(&storage);
    try std.testing.expectEqual(@as(usize, 1), recovered.len);
    try std.testing.expectEqual(cancel.command_id, recovered[0].command_id);
    try std.testing.expectEqual(Operation.cancel, recovered[0].operation);
}

test "OMS rejects a price for another instrument and preserves reservation assets" {
    var state: Oms = .{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{
        .intent_sequence = 1,
        .operation = .place,
        .instrument = 1,
        .quantity = 1,
        .limit_price = .{ .instrument = 2, .rules_version = 1, .ticks = 1 },
        .reservation = .{ .asset = 3, .atoms = 4 },
    };
    try std.testing.expectError(error.InvalidOrderSpec, state.applyGroup(group));

    group.members[0].limit_price.instrument = 1;
    try state.applyGroup(group);
    const reservations = try state.activeReservations(3);
    try std.testing.expectEqual(@as(canonical.AssetIdentity, 3), reservations.asset);
    try std.testing.expectEqual(@as(i128, 4), reservations.atoms);
    try std.testing.expectError(error.MixedReservationAssets, state.activeReservations(1));
}

test "OMS rejects overflowing authoritative quantities" {
    var state = Oms{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 1, .quantity = std.math.maxInt(i64), .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try state.applyGroup(group);
    var dispatch: DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = 1, .state = .submitted };
    try state.applyDispatch(dispatch);
    try std.testing.expectError(error.Overflow, state.applyReport(.{
        .report_id = 1,
        .order_id = 1,
        .revision = 0,
        .status = .partially_filled,
        .cumulative_quantity = std.math.maxInt(i64),
        .remaining_quantity = 1,
    }));
}

test "ConfirmedAbsent cannot become a fill and releases reservation" {
    var state = Oms{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try state.applyGroup(group);
    var dispatch: DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = 1, .state = .unknown };
    try state.applyDispatch(dispatch);
    try state.applyReconciliation(.{ .reconciliation_id = 1, .order_id = 1, .status = .confirmed_absent, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try std.testing.expectEqual(OrderState.canceled, state.orders[0].state);
    try std.testing.expect(!state.orders[0].reservation_active);
}

test "FoundTerminal requires an explicit terminal category" {
    var state = Oms{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try state.applyGroup(group);
    try std.testing.expectError(error.IncompleteReconciliationEvidence, state.applyReconciliation(.{ .reconciliation_id = 1, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 2, .remaining_quantity = 0 }));
}

test "hot terminal facts reject semantic changes and invalid filled quantities" {
    var state = Oms{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try state.applyGroup(group);
    try std.testing.expectError(error.InvalidExecutionReport, state.applyReport(.{ .report_id = 1, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 1, .remaining_quantity = 1 }));
    try state.applyReport(.{ .report_id = 1, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReport(.{ .report_id = 1, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try std.testing.expectError(error.TerminalFactConflict, state.applyReport(.{ .report_id = 2, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 2, .remaining_quantity = 0 }));
    try std.testing.expect(state.recovery_only);
}

test "OrderIntentIdentity is idempotent and conflicts fail closed" {
    var state = Oms{};
    var group: IntentGroup = .{ .first_intent_sequence = 7, .count = 1 };
    group.members[0] = .{ .intent_sequence = 7, .strategy_instance = 9, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try state.applyGroup(group);
    const order_count = state.order_count;
    const command_count = state.command_count;
    try state.applyGroup(group);
    try std.testing.expectEqual(order_count, state.order_count);
    try std.testing.expectEqual(command_count, state.command_count);
    group.members[0].quantity = 3;
    try std.testing.expectError(error.ConflictingIntentIdentity, state.applyGroup(group));
}

test "terminal orders compact to replayable tombstones without overwriting active state" {
    var state = Oms{};
    for (1..max_orders + 2) |raw_sequence| {
        state.begin();
        const sequence: u64 = @intCast(raw_sequence);
        var group: IntentGroup = .{ .first_intent_sequence = sequence, .count = 1 };
        group.members[0] = .{ .intent_sequence = sequence, .strategy_instance = 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
        try state.applyGroup(group);
        const order_id = state.emitted()[0].order_id;
        var dispatch: DispatchBatch = .{ .count = 1 };
        dispatch.items[0] = .{ .command_id = state.emitted()[0].command_id, .state = .submitted };
        try state.applyDispatch(dispatch);
        try state.applyReport(.{ .report_id = sequence, .order_id = order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
        if (order_id == 1) try state.applyReconciliation(.{ .reconciliation_id = 100, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    }
    try std.testing.expectEqual(@as(u8, max_orders), state.order_count);
    try std.testing.expectEqual(@as(u8, 1), state.tombstone_count);
    try std.testing.expect(state.orderById(1) == null);
    try std.testing.expect(!state.recovery_only);
    try std.testing.expectEqual(@as(u64, 1), state.tombstones[0].intent_sequence);
    try std.testing.expectEqualStrings("RWN-1", state.tombstones[0].client_order_id.slice());
    try std.testing.expect(!std.mem.eql(u8, &state.tombstones[0].fact_digest, &@as([32]u8, @splat(0))));
    try state.applyReport(.{ .report_id = 1, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReconciliation(.{ .reconciliation_id = 100, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try std.testing.expectError(error.TombstoneFactConflict, state.applyReconciliation(.{ .reconciliation_id = 100, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .filled }));
    try std.testing.expectError(error.TombstoneFactConflict, state.applyReport(.{ .report_id = 0, .order_id = 1, .revision = 2, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 }));
    try std.testing.expectError(error.TombstoneFactConflict, state.applyReconciliation(.{ .reconciliation_id = 0, .order_id = 1, .status = .found_terminal, .revision = 99, .cumulative_quantity = 0, .remaining_quantity = 0, .terminal_state = .filled }));
    try std.testing.expectError(error.TombstoneFactConflict, state.applyReport(.{ .report_id = 99, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 2, .remaining_quantity = 0 }));
    try std.testing.expect(state.recovery_only);
}

test "tombstone capacity exhaustion enters RecoveryOnly without evicting active evidence" {
    var state = Oms{};
    var sequence: u64 = 1;
    while (sequence <= max_orders + max_tombstones) : (sequence += 1) {
        state.begin();
        var group: IntentGroup = .{ .first_intent_sequence = sequence, .count = 1 };
        group.members[0] = .{ .intent_sequence = sequence, .strategy_instance = 1, .operation = .place, .instrument = 1, .quantity = 1, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 1 }, .reservation = .{ .asset = 1, .atoms = 1 } };
        try state.applyGroup(group);
        const command_value = state.emitted()[0];
        var dispatch: DispatchBatch = .{ .count = 1 };
        dispatch.items[0] = .{ .command_id = command_value.command_id, .state = .submitted };
        try state.applyDispatch(dispatch);
        try state.applyReport(.{ .report_id = sequence, .order_id = command_value.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 1 });
    }
    state.begin();
    var overflow: IntentGroup = .{ .first_intent_sequence = sequence, .count = 1 };
    overflow.members[0] = .{ .intent_sequence = sequence, .strategy_instance = 1, .operation = .place, .instrument = 1, .quantity = 1, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 1 }, .reservation = .{ .asset = 1, .atoms = 1 } };
    try std.testing.expectError(error.TombstoneCapacityExceeded, state.applyGroup(overflow));
    try std.testing.expect(state.recovery_only);
    try std.testing.expectEqual(@as(u8, max_orders), state.order_count);
    try std.testing.expectEqual(@as(u8, max_tombstones), state.tombstone_count);
}

fn rememberReport(order: *Order, report: ExecutionReport) void {
    order.last_report_id = report.report_id;
    order.last_report_revision = report.revision;
    order.last_report_status = report.status;
    order.last_report_cumulative_quantity = report.cumulative_quantity;
    order.last_report_remaining_quantity = report.remaining_quantity;
}
