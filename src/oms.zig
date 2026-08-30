const std = @import("std");
const canonical = @import("canonical_event.zig");

pub const max_orders = 8;
pub const max_group_members = 4;
pub const max_commands = 8;
const max_command_history = 32;
const max_fact_history = 32;

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
    pending_reservation: ?Reservation = null,
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

const Replacement = struct { instrument: Instrument, side: Side, portfolio_reduce_only: bool, venue_reduce_only: bool, quantity: i64, limit_price: Price, reservation: Reservation };

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
            try self.emit(order.*, .cancel);
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
            try self.emit(order.*, .cancel);
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

    pub fn applyGroup(self: *Oms, group: IntentGroup) !void {
        if (group.count == 0 or group.count > max_group_members) return error.InvalidIntentGroup;
        if (self.blocksNewSend()) {
            for (group.members[0..group.count]) |intent| switch (intent.operation) {
                .place, .amend => return error.UncertainOrderBlocksSend,
                .cancel => {},
            };
        }
        for (group.members[0..group.count], 0..) |intent, index| {
            if (intent.intent_sequence != group.first_intent_sequence + index)
                return error.NonConsecutiveIntentGroup;
            self.applyIntent(intent, group.first_intent_sequence, group.policy) catch |err| {
                if (group.policy == .cancel_remaining) try self.cancelGroup(group.first_intent_sequence);
                return err;
            };
        }
    }

    fn applyIntent(self: *Oms, intent: Intent, group: u64, policy: PartialExecutionPolicy) !void {
        switch (intent.operation) {
            .place => {
                if (intent.quantity <= 0 or intent.limit_price.ticks <= 0 or intent.reservation.atoms <= 0 or intent.limit_price.instrument != intent.instrument) return error.InvalidOrderSpec;
                const order = try self.createOrder(intent.strategy_instance, intent.instrument, intent.side, intent.portfolio_reduce_only, intent.venue_reduce_only, intent.quantity, intent.limit_price, intent.reservation, 0, group, policy);
                try self.emit(order.*, .place);
            },
            .amend => {
                const order = try self.mutableOrder(intent.target_order_id);
                try validateTarget(order, intent);
                if (intent.quantity <= 0 or intent.limit_price.ticks <= 0 or intent.limit_price.instrument != intent.instrument) return error.InvalidOrderSpec;
                if (intent.native_amend) {
                    order.revision += 1;
                    order.state = .pending_amend;
                    order.quantity = order.cumulative_quantity + intent.quantity;
                    order.limit_price = intent.limit_price;
                    order.pending_reservation = intent.reservation;
                    if (order.reservation.asset != intent.reservation.asset) return error.MixedReservationAssets;
                    if (intent.reservation.atoms > order.reservation.atoms) order.reservation = intent.reservation;
                    try self.emit(order.*, .amend);
                } else {
                    if (!intent.allow_cancel_confirm_create) return error.CancelConfirmCreateNotAuthorized;
                    order.state = .pending_cancel;
                    if (intent.reservation.atoms <= 0) return error.InvalidOrderSpec;
                    order.replacement = .{ .instrument = order.instrument, .side = intent.side, .portfolio_reduce_only = intent.portfolio_reduce_only, .venue_reduce_only = intent.venue_reduce_only, .quantity = intent.quantity, .limit_price = intent.limit_price, .reservation = intent.reservation };
                    try self.emit(order.*, .cancel);
                }
            },
            .cancel => {
                const order = try self.mutableOrder(intent.target_order_id);
                try validateTarget(order, intent);
                order.state = .pending_cancel;
                try self.emit(order.*, .cancel);
            },
        }
    }

    pub fn applyDispatch(self: *Oms, batch: DispatchBatch) !void {
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
        for (self.report_history[0..self.report_history_count]) |known| {
            if (known.order_id == report.order_id and known.report_id == report.report_id) {
                if (!std.meta.eql(known, report)) return error.ConflictingReportIdentity;
                return;
            }
        }
        if (self.report_history_count == max_fact_history) return error.IdentitySetFull;
        self.report_history[self.report_history_count] = report;
        self.report_history_count += 1;
        const order = try self.mutableOrder(report.order_id);
        if (report.report_id < order.last_report_id) return;
        if (report.report_id == order.last_report_id) {
            if (report.revision != order.last_report_revision or report.status != order.last_report_status or
                report.cumulative_quantity != order.last_report_cumulative_quantity or
                report.remaining_quantity != order.last_report_remaining_quantity)
                return error.ConflictingReportIdentity;
            return;
        }
        if (order.state == .filled or order.state == .canceled or order.state == .rejected) {
            rememberReport(order, report);
            return;
        }
        if (report.cumulative_quantity < order.cumulative_quantity or report.remaining_quantity < 0 or
            report.cumulative_quantity + report.remaining_quantity > order.quantity)
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
        if (report.status == .canceled or report.status == .rejected)
            order.reservation_active = false;
        if (report.status == .amended) {
            order.confirmed_reservation = order.pending_reservation orelse order.confirmed_reservation;
            order.reservation = order.confirmed_reservation;
            order.pending_reservation = null;
        }
        if (report.status == .filled) order.replacement = null;
    }

    pub fn applyReconciliation(self: *Oms, result: ReconciliationResult) !void {
        for (self.reconciliation_history[0..self.reconciliation_history_count]) |known| {
            if (known.order_id == result.order_id and known.reconciliation_id == result.reconciliation_id) {
                if (!std.meta.eql(known, result)) return error.ConflictingReconciliationIdentity;
                return;
            }
        }
        if (self.reconciliation_history_count == max_fact_history) return error.IdentitySetFull;
        self.reconciliation_history[self.reconciliation_history_count] = result;
        self.reconciliation_history_count += 1;
        const order = try self.mutableOrder(result.order_id);
        if (result.reconciliation_id < order.last_reconciliation_id) return;
        if (result.reconciliation_id == order.last_reconciliation_id) {
            if (result.status != order.last_reconciliation_status or result.revision != order.last_reconciliation_revision or
                result.cumulative_quantity != order.last_reconciliation_cumulative_quantity or
                result.remaining_quantity != order.last_reconciliation_remaining_quantity)
                return error.ConflictingReconciliationIdentity;
            return;
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
                order.quantity = result.cumulative_quantity + result.remaining_quantity;
                order.state = if (result.cumulative_quantity == 0) .live else .partially_filled;
            },
            .found_terminal, .confirmed_absent => {
                order.state = if (result.remaining_quantity == 0 and result.cumulative_quantity == order.quantity) .filled else .canceled;
                order.reservation_active = order.state == .filled;
            },
        }
    }

    pub fn replacementIntent(self: *const Oms, order_id: u64, sequence: u64) !?Intent {
        const order = self.orderById(order_id) orelse return error.UnknownOrder;
        const replacement = order.replacement orelse return null;
        if (order.state != .canceled) return null;
        return .{
            .intent_sequence = sequence,
            .operation = .place,
            .instrument = replacement.instrument,
            .side = replacement.side,
            .portfolio_reduce_only = replacement.portfolio_reduce_only,
            .quantity = replacement.quantity,
            .limit_price = replacement.limit_price,
        };
    }

    pub fn confirmReplacement(self: *Oms, order_id: u64, reservation: Reservation, portfolio_reduce_only: bool, venue_reduce_only: bool) !void {
        const predecessor = try self.mutableOrder(order_id);
        if (predecessor.state != .canceled or predecessor.replacement == null) return error.ReplacementNotReady;
        predecessor.replacement.?.reservation = reservation;
        predecessor.replacement.?.portfolio_reduce_only = portfolio_reduce_only;
        predecessor.replacement.?.venue_reduce_only = venue_reduce_only;
        try self.createReplacement(predecessor);
    }

    pub fn discardReplacement(self: *Oms, order_id: u64) !void {
        const predecessor = try self.mutableOrder(order_id);
        predecessor.replacement = null;
    }

    fn createOrder(self: *Oms, strategy_instance: u128, instrument: Instrument, side: Side, portfolio_reduce_only: bool, venue_reduce_only: bool, quantity: i64, price: Price, reservation: Reservation, predecessor: u64, group: u64, policy: PartialExecutionPolicy) !*Order {
        if (self.order_count == max_orders) return error.OrderCapacityExceeded;
        const index = self.order_count;
        self.order_count += 1;
        self.orders[index] = .{ .id = self.next_order_id, .strategy_instance = strategy_instance, .instrument = instrument, .side = side, .portfolio_reduce_only = portfolio_reduce_only, .venue_reduce_only = venue_reduce_only, .quantity = quantity, .limit_price = price, .reservation = reservation, .confirmed_reservation = reservation, .predecessor_order_id = predecessor, .group_first_sequence = group, .group_policy = policy };
        self.next_order_id += 1;
        return &self.orders[index];
    }

    fn emit(self: *Oms, order: Order, operation: Operation) !void {
        if (self.command_count == max_commands or self.command_history_count == max_command_history) return error.CommandCapacityExceeded;
        const command_value: Command = .{ .command_id = self.next_command_id, .order_id = order.id, .strategy_instance = order.strategy_instance, .revision = order.revision, .operation = operation, .instrument = order.instrument, .side = order.side, .portfolio_reduce_only = order.portfolio_reduce_only, .venue_reduce_only = order.venue_reduce_only, .quantity = order.quantity - order.cumulative_quantity, .limit_price = order.limit_price, .predecessor_order_id = order.predecessor_order_id, .reservation = order.reservation };
        self.commands[self.command_count] = command_value;
        self.command_count += 1;
        self.command_history[self.command_history_count] = command_value;
        self.command_history_count += 1;
        self.next_command_id += 1;
    }

    fn createReplacement(self: *Oms, predecessor: *Order) !void {
        const replacement = predecessor.replacement.?;
        predecessor.replacement = null;
        const next = try self.createOrder(predecessor.strategy_instance, replacement.instrument, replacement.side, replacement.portfolio_reduce_only, replacement.venue_reduce_only, replacement.quantity, replacement.limit_price, replacement.reservation, predecessor.id, predecessor.group_first_sequence, predecessor.group_policy);
        try self.emit(next.*, .place);
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
                        try self.emit(order.*, .cancel);
                    } else {
                        order.state = .rejected;
                        order.reservation_active = false;
                    }
                },
                .live, .partially_filled => {
                    order.state = .pending_cancel;
                    try self.emit(order.*, .cancel);
                },
                else => {},
            };
        }
    }

    fn mutableOrder(self: *Oms, id: u64) !*Order {
        for (self.orders[0..self.order_count]) |*order| if (order.id == id) return order;
        return error.UnknownOrder;
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

fn rememberReport(order: *Order, report: ExecutionReport) void {
    order.last_report_id = report.report_id;
    order.last_report_revision = report.revision;
    order.last_report_status = report.status;
    order.last_report_cumulative_quantity = report.cumulative_quantity;
    order.last_report_remaining_quantity = report.remaining_quantity;
}
