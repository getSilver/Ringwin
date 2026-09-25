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

pub fn exactOrderTiming(order_type: canonical.OrderType, time_in_force: canonical.TimeInForce) bool {
    return switch (order_type) {
        .post_only => time_in_force == .post_only,
        .ioc => time_in_force == .immediate_or_cancel,
        .fok => time_in_force == .fill_or_kill,
        .market => time_in_force == .immediate_or_cancel,
        .limit => time_in_force != .post_only,
    };
}

pub fn exactOrderSpec(order_type: canonical.OrderType, time_in_force: canonical.TimeInForce, has_market_protection: bool) bool {
    return exactOrderTiming(order_type, time_in_force) and (has_market_protection == (order_type == .market));
}
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

/// Stable trace sequences of the accepted RiskDecision and established
/// RiskReservation facts. An unqualified legacy outbox has zero references.
pub const FactRef = struct { identity: u128 = 0, version: u64 = 0, barrier: u64 = 0 };
/// References to source-owned facts, not a replayable authorization grant.
pub const DispatchAuthorityRefs = struct {
    exchange_account: canonical.ExchangeAccountIdentity = 0,
    virtual_portfolio: u128 = 0,
    trading_authorization: FactRef = .{},
    primary_lease: FactRef = .{},
    risk_lease: FactRef = .{},
    capability: FactRef = .{},
    instrument_rules: FactRef = .{},
    config: FactRef = .{},
    adapter_session: canonical.AdapterSessionIdentity = 0,
    dispatch_deadline_monotonic_ns: u64 = 0,
    deadline_barrier: u64 = 0,

    pub fn complete(self: @This()) bool {
        return self.exchange_account != 0 and self.virtual_portfolio != 0 and
            self.trading_authorization.identity != 0 and self.trading_authorization.version != 0 and self.trading_authorization.barrier != 0 and
            self.primary_lease.identity != 0 and self.primary_lease.version != 0 and self.primary_lease.barrier != 0 and
            self.risk_lease.identity != 0 and self.risk_lease.version != 0 and self.risk_lease.barrier != 0 and
            self.capability.identity != 0 and self.capability.version != 0 and self.capability.barrier != 0 and
            self.instrument_rules.identity != 0 and self.instrument_rules.version != 0 and self.instrument_rules.barrier != 0 and
            self.config.identity != 0 and self.config.version != 0 and self.config.barrier != 0 and
            self.adapter_session != 0 and self.dispatch_deadline_monotonic_ns != 0 and self.deadline_barrier != 0;
    }
};
pub const RiskFactRefs = struct {
    decision: u64 = 0,
    reservation: u64 = 0,
    authority: DispatchAuthorityRefs = .{},
};

pub const ExecutionReport = struct {
    report_id: u64,
    order_id: u64,
    revision: u32,
    status: ReportStatus,
    cumulative_quantity: i64,
    remaining_quantity: i64,
    canonical_digest: [32]u8 = @splat(0),
};

pub const ReconciliationResult = struct {
    reconciliation_id: u64,
    order_id: u64,
    status: ReconciliationStatus,
    revision: u32,
    cumulative_quantity: i64,
    remaining_quantity: i64,
    terminal_state: ?TerminalState = null,
    canonical_digest: [32]u8 = @splat(0),
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
    authority: DispatchAuthorityRefs = .{},
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
    confirmed_quantity: i64,
    reservation_basis_quantity: i64,
    pending_reservation: ?Reservation = null,
    pending_basis_quantity: i64 = 0,
    pending_previous_spec: ?struct { limit_price: Price, order_type: canonical.OrderType, time_in_force: canonical.TimeInForce, market_protection_price: ?Price } = null,
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
    archive_window_closed: bool = false,
    archive_audit_digest: [32]u8 = @splat(0),
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

const Replacement = struct { instrument: Instrument, side: Side, portfolio_reduce_only: bool, venue_reduce_only: bool, quantity: i64, limit_price: Price, reservation: Reservation, order_type: canonical.OrderType, time_in_force: canonical.TimeInForce, market_protection_price: ?Price, client_order_id: canonical.ClientOrderId, expected_revision: u32, expected_cumulative_quantity: i64 };
pub const SeenIntent = struct { strategy_instance: u128, intent_sequence: u64, group: u64, policy: PartialExecutionPolicy, fingerprint: [16]u8 };

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
            if (order.state == .filled or order.state == .canceled or order.state == .rejected or order.state == .unknown or
                order.state == .pending_cancel or
                (increasing_only and order.portfolio_reduce_only and order.venue_reduce_only))
                continue;
            order.state = .pending_cancel;
            const origin = self.originForOrder(order.id);
            try self.emit(order.*, .cancel, origin.intent_sequence, origin.refs);
        }
    }

    /// Cancels only orders owned by one strategy instance.
    pub fn cancelStrategyOrders(self: *Oms, strategy_instance: u128) !void {
        if (strategy_instance == 0) return error.InvalidStrategyInstance;
        for (self.orders[0..self.order_count]) |*order| {
            if (order.strategy_instance != strategy_instance or order.state == .unknown or order.state == .filled or
                order.state == .canceled or order.state == .rejected or order.state == .pending_cancel)
                continue;
            order.state = .pending_cancel;
            const origin = self.originForOrder(order.id);
            try self.emit(order.*, .cancel, origin.intent_sequence, origin.refs);
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

    pub const GroupIdentityStatus = enum { fresh, duplicate, conflict };

    pub fn groupIdentityStatus(self: *const Oms, group: IntentGroup) !GroupIdentityStatus {
        if (group.count == 0 or group.count > max_group_members) return error.InvalidIntentGroup;
        var known_count: u8 = 0;
        for (group.members[0..group.count], 0..) |intent, index| {
            if (intent.intent_sequence != try std.math.add(u64, group.first_intent_sequence, index) or
                intent.strategy_instance != group.members[0].strategy_instance)
                return error.NonConsecutiveIntentGroup;
            for (self.intent_history[0..self.intent_history_count]) |known| {
                if (known.strategy_instance != intent.strategy_instance or known.intent_sequence != intent.intent_sequence) continue;
                if (known.group != group.first_intent_sequence or known.policy != group.policy or
                    !std.mem.eql(u8, &known.fingerprint, &intentFingerprint(intent, group.count))) return .conflict;
                known_count += 1;
                break;
            }
        }
        if (known_count == group.count) return .duplicate;
        return if (known_count == 0) .fresh else .conflict;
    }

    pub fn applyGroup(self: *Oms, group: IntentGroup) !void {
        return self.applyGroupWithRefs(group, group, &.{});
    }

    pub fn applyQualifiedGroup(self: *Oms, group: IntentGroup, original: IntentGroup, refs: []const RiskFactRefs) !void {
        switch (try self.groupIdentityStatus(original)) {
            .duplicate => return,
            .conflict => return error.ConflictingIntentIdentity,
            .fresh => {},
        }
        if (refs.len != group.count) return error.InvalidRiskFactRefs;
        for (refs) |ref| if (ref.decision == 0 or ref.reservation == 0 or ref.decision == ref.reservation)
            return error.InvalidRiskFactRefs;
        return self.applyGroupWithRefs(group, original, refs);
    }

    fn applyGroupWithRefs(self: *Oms, group: IntentGroup, original: IntentGroup, refs: []const RiskFactRefs) !void {
        var candidate = self.*;
        candidate.applyGroupInPlace(group, original, refs) catch |err| {
            // Capacity exhaustion is an authoritative safety transition even
            // though the rejected intent group itself is not committed.
            if (candidate.recovery_only) self.recovery_only = true;
            return err;
        };
        self.* = candidate;
    }

    fn applyGroupInPlace(self: *Oms, group: IntentGroup, original: IntentGroup, refs: []const RiskFactRefs) !void {
        if (group.count == 0 or group.count > max_group_members) return error.InvalidIntentGroup;
        if (group.count != original.count or group.first_intent_sequence != original.first_intent_sequence or group.policy != original.policy)
            return error.InvalidIntentGroup;
        switch (try self.groupIdentityStatus(original)) {
            .duplicate => return,
            .conflict => return error.ConflictingIntentIdentity,
            .fresh => {},
        }
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
        for (group.members[0..group.count], 0..) |intent, index| {
            self.applyIntent(intent, group.first_intent_sequence, group.policy, if (refs.len == 0) .{} else refs[index]) catch |err| {
                if (group.policy == .cancel_remaining) try self.cancelGroup(group.first_intent_sequence);
                return err;
            };
            self.intent_history[self.intent_history_count] = .{ .strategy_instance = intent.strategy_instance, .intent_sequence = intent.intent_sequence, .group = group.first_intent_sequence, .policy = group.policy, .fingerprint = intentFingerprint(original.members[index], original.count) };
            self.intent_history_count += 1;
        }
    }

    fn applyIntent(self: *Oms, intent: Intent, group: u64, policy: PartialExecutionPolicy, refs: RiskFactRefs) !void {
        switch (intent.operation) {
            .place => {
                if (!exactOrderSpec(intent.order_type, intent.time_in_force, intent.market_protection_price != null)) return error.InvalidOrderSpec;
                if (intent.quantity <= 0 or intent.limit_price.ticks <= 0 or intent.reservation.atoms <= 0 or intent.limit_price.instrument != intent.instrument) return error.InvalidOrderSpec;
                const order = try self.createOrder(intent.strategy_instance, intent.instrument, intent.side, intent.portfolio_reduce_only, intent.venue_reduce_only, intent.quantity, intent.limit_price, intent.reservation, intent.client_order_id, 0, group, policy);
                order.order_type = intent.order_type;
                order.time_in_force = intent.time_in_force;
                order.market_protection_price = intent.market_protection_price;
                try self.emit(order.*, .place, intent.intent_sequence, refs);
            },
            .amend => {
                if (!exactOrderSpec(intent.order_type, intent.time_in_force, intent.market_protection_price != null)) return error.InvalidOrderSpec;
                const order = try self.mutableOrder(intent.target_order_id);
                try validateTarget(order, intent);
                if (intent.quantity <= 0 or intent.limit_price.ticks <= 0 or intent.limit_price.instrument != intent.instrument) return error.InvalidOrderSpec;
                if (intent.native_amend) {
                    order.revision = try std.math.add(u32, order.revision, 1);
                    order.state = .pending_amend;
                    order.pending_previous_spec = .{ .limit_price = order.limit_price, .order_type = order.order_type, .time_in_force = order.time_in_force, .market_protection_price = order.market_protection_price };
                    order.quantity = try std.math.add(i64, order.cumulative_quantity, intent.quantity);
                    order.limit_price = intent.limit_price;
                    order.order_type = intent.order_type;
                    order.time_in_force = intent.time_in_force;
                    order.market_protection_price = intent.market_protection_price;
                    order.pending_reservation = intent.reservation;
                    order.pending_basis_quantity = intent.quantity;
                    if (order.reservation.asset != intent.reservation.asset) return error.MixedReservationAssets;
                    try rebalanceReservation(order, order.confirmed_quantity - order.cumulative_quantity);
                    try self.emit(order.*, .amend, intent.intent_sequence, refs);
                } else {
                    if (!intent.allow_cancel_confirm_create) return error.CancelConfirmCreateNotAuthorized;
                    order.state = .pending_cancel;
                    if (intent.reservation.atoms <= 0) return error.InvalidOrderSpec;
                    order.replacement = .{ .instrument = order.instrument, .side = intent.side, .portfolio_reduce_only = intent.portfolio_reduce_only, .venue_reduce_only = intent.venue_reduce_only, .quantity = intent.quantity, .limit_price = intent.limit_price, .reservation = intent.reservation, .order_type = intent.order_type, .time_in_force = intent.time_in_force, .market_protection_price = intent.market_protection_price, .client_order_id = intent.client_order_id, .expected_revision = intent.expected_revision, .expected_cumulative_quantity = intent.expected_cumulative_quantity };
                    try self.emit(order.*, .cancel, intent.intent_sequence, refs);
                }
            },
            .cancel => {
                const order = try self.mutableOrder(intent.target_order_id);
                try validateTarget(order, intent);
                order.state = .pending_cancel;
                try self.emit(order.*, .cancel, intent.intent_sequence, refs);
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
                        try self.rejectCommand(order, command_value.operation);
                        if (order.group_policy == .cancel_remaining) try self.cancelGroup(order.group_first_sequence);
                    }
                },
                .not_sent => {
                    try self.rejectCommand(order, command_value.operation);
                    if (order.group_policy == .cancel_remaining) try self.cancelGroup(order.group_first_sequence);
                },
            }
        }
    }

    pub const ReportIdentity = enum { unknown, duplicate };

    /// Canonical and core reports share this identity seam. TradingShard must
    /// not keep a second last-report scalar.
    pub fn lookupReport(self: *const Oms, report: ExecutionReport) !ReportIdentity {
        for (self.report_history[0..self.report_history_count]) |known| {
            if (known.order_id != report.order_id or known.report_id != report.report_id) continue;
            if (!std.meta.eql(known, report)) return error.ConflictingReportIdentity;
            return .duplicate;
        }
        return .unknown;
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
        const pending_amend = order.pending_reservation != null;
        if (pending_amend and report.revision > order.revision) return error.StaleOrderRevision;
        const old_revision_report = pending_amend and report.revision < order.revision;
        const pending_max_total = if (pending_amend) std.math.add(i64, order.cumulative_quantity, order.pending_basis_quantity) catch return error.Overflow else 0;
        if (report.cumulative_quantity < order.cumulative_quantity or report.remaining_quantity < 0 or
            (old_revision_report and reported_quantity > order.confirmed_quantity) or
            (!pending_amend and reported_quantity > order.quantity) or
            (pending_amend and !old_revision_report and report.status != .rejected and
                (reported_quantity < order.quantity or reported_quantity > pending_max_total or report.remaining_quantity > order.pending_basis_quantity)) or
            (report.status == .filled and (report.remaining_quantity != 0 or
                (old_revision_report and report.cumulative_quantity != order.confirmed_quantity) or
                (!pending_amend and report.cumulative_quantity != order.quantity))))
            return error.InvalidExecutionReport;
        if (report.status == .amended and report.revision != order.revision) return error.StaleOrderRevision;
        if (report.status == .amended and report.remaining_quantity == 0) return error.InvalidExecutionReport;
        if (report.status == .rejected and pending_amend and !old_revision_report) {
            if (reported_quantity > order.confirmed_quantity) return error.InvalidExecutionReport;
            rememberReport(order, report);
            order.cumulative_quantity = report.cumulative_quantity;
            try self.rejectCommand(order, .amend);
            return;
        }
        if (report.status == .rejected and order.state == .pending_cancel) {
            rememberReport(order, report);
            try self.rejectCommand(order, .cancel);
            return;
        }
        rememberReport(order, report);
        const amend_unknown = pending_amend and order.state == .unknown;
        order.cumulative_quantity = report.cumulative_quantity;
        const cancel_unsettled = self.cancelUnsettled(order.*);
        order.state = switch (report.status) {
            .accepted => if (cancel_unsettled) .pending_cancel else if (amend_unknown) .unknown else if (pending_amend) .pending_amend else .live,
            .partially_filled => if (cancel_unsettled) .pending_cancel else if (amend_unknown) .unknown else if (pending_amend) .pending_amend else .partially_filled,
            .filled => .filled,
            .canceled => .canceled,
            .rejected => .rejected,
            .amended => if (cancel_unsettled) .pending_cancel else .live,
        };
        if (report.status == .filled or report.status == .canceled or report.status == .rejected) {
            order.reservation_active = false;
            order.reservation.atoms = 0;
            order.pending_reservation = null;
            order.pending_basis_quantity = 0;
            order.pending_previous_spec = null;
        } else if (report.status != .amended) {
            try rebalanceReservation(order, if (pending_amend) @max(0, order.confirmed_quantity - report.cumulative_quantity) else report.remaining_quantity);
        }
        if (report.status == .amended) {
            if (order.pending_reservation) |pending| {
                order.confirmed_reservation = pending;
                order.confirmed_reservation.atoms = try scaledReservation(pending.atoms, report.remaining_quantity, order.pending_basis_quantity);
            }
            order.confirmed_quantity = reported_quantity;
            order.quantity = reported_quantity;
            order.reservation_basis_quantity = report.remaining_quantity;
            order.pending_reservation = null;
            order.pending_basis_quantity = 0;
            order.pending_previous_spec = null;
            try rebalanceReservation(order, report.remaining_quantity);
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

    pub fn canConfirmAbsent(self: *const Oms, order_id: u64, revision: u32) bool {
        const order = self.orderById(order_id) orelse return false;
        const command_value = self.findCommandForOrder(order_id) orelse return false;
        for (self.reconciliation_history[0..self.reconciliation_history_count]) |known|
            if (known.order_id == order_id and known.status != .unresolved) return false;
        return order.state == .unknown and order.dispatch_submitted and order.last_report_id == 0 and
            order.cumulative_quantity == 0 and order.revision == revision and
            command_value.operation == .place and command_value.revision == revision;
    }

    pub fn canConfirmAbsentFromSession(self: *const Oms, order_id: u64, revision: u32, prior_session: canonical.AdapterSessionIdentity) bool {
        if (!self.canConfirmAbsent(order_id, revision) or prior_session == 0) return false;
        return self.findCommandForOrder(order_id).?.authority.adapter_session == prior_session;
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
        if (result.status != .unresolved and result.cumulative_quantity < order.cumulative_quantity) return error.ConflictingReconciliationEvidence;
        const pending_amend = order.pending_reservation != null;
        if (pending_amend and result.revision > order.revision) return error.StaleOrderRevision;
        const old_revision = pending_amend and result.revision < order.revision;
        const pending_max_total = if (pending_amend) std.math.add(i64, order.cumulative_quantity, order.pending_basis_quantity) catch return error.Overflow else 0;
        if ((old_revision and reconciled_quantity > order.confirmed_quantity) or
            (!pending_amend and reconciled_quantity > order.quantity) or
            (pending_amend and !old_revision and
                (reconciled_quantity < order.quantity or reconciled_quantity > pending_max_total or result.remaining_quantity > order.pending_basis_quantity)))
            return error.ConflictingReconciliationEvidence;
        switch (result.status) {
            .unresolved => if (result.terminal_state != null) return error.ConflictingReconciliationEvidence,
            .found_live => if (result.terminal_state != null or result.remaining_quantity == 0 or
                (old_revision and reconciled_quantity != order.confirmed_quantity) or
                (!pending_amend and reconciled_quantity != order.quantity)) return error.ConflictingReconciliationEvidence,
            .found_terminal => {
                if (result.terminal_state == null) return error.IncompleteReconciliationEvidence;
                if (result.terminal_state.? == .filled and
                    (result.cumulative_quantity != (if (old_revision) order.confirmed_quantity else order.quantity) or result.remaining_quantity != 0))
                    return error.ConflictingReconciliationEvidence;
            },
            .confirmed_absent => {
                if (result.terminal_state != null or result.cumulative_quantity != 0 or result.remaining_quantity != order.quantity or
                    !self.canConfirmAbsent(result.order_id, result.revision))
                    return error.ConflictingReconciliationEvidence;
            },
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
        if (order.state == .filled or order.state == .canceled or order.state == .rejected) {
            if (result.status == .found_terminal or result.status == .confirmed_absent)
                try commitArchiveQualification(self, order);
            return;
        }
        switch (result.status) {
            .unresolved => order.state = .unknown,
            .found_live => {
                const cancel_unsettled = self.cancelUnsettled(order.*);
                const amend_unknown = pending_amend and old_revision and order.state == .unknown;
                if (!old_revision) order.revision = result.revision;
                order.cumulative_quantity = result.cumulative_quantity;
                if (!old_revision) order.quantity = try std.math.add(i64, result.cumulative_quantity, result.remaining_quantity);
                if (!pending_amend) order.confirmed_quantity = order.quantity;
                if (pending_amend and !old_revision) {
                    order.confirmed_reservation = order.pending_reservation.?;
                    order.confirmed_reservation.atoms = try scaledReservation(order.confirmed_reservation.atoms, result.remaining_quantity, order.pending_basis_quantity);
                    order.confirmed_quantity = order.quantity;
                    order.reservation_basis_quantity = result.remaining_quantity;
                    order.pending_reservation = null;
                    order.pending_basis_quantity = 0;
                    order.pending_previous_spec = null;
                }
                order.state = if (cancel_unsettled) .pending_cancel else if (amend_unknown) .unknown else if (order.pending_reservation != null) .pending_amend else if (result.cumulative_quantity == 0) .live else .partially_filled;
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
                order.pending_reservation = null;
                order.pending_basis_quantity = 0;
                order.pending_previous_spec = null;
                try commitArchiveQualification(self, order);
            },
            .confirmed_absent => {
                order.state = .canceled;
                order.reservation_active = false;
                order.reservation.atoms = 0;
                try commitArchiveQualification(self, order);
            },
        }
    }

    pub fn replacementIntent(self: *const Oms, order_id: u64, sequence: u64) !?Intent {
        const order = self.orderById(order_id) orelse return null;
        const replacement = order.replacement orelse return null;
        if (order.state != .canceled) return null;
        if (order.revision != replacement.expected_revision or order.cumulative_quantity != replacement.expected_cumulative_quantity)
            return error.StaleReplacementEvidence;
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

    pub fn confirmReplacement(self: *Oms, order_id: u64, reservation: Reservation, portfolio_reduce_only: bool, venue_reduce_only: bool, intent_sequence: u64, refs: RiskFactRefs) !void {
        var candidate = self.*;
        try candidate.confirmReplacementInPlace(order_id, reservation, portfolio_reduce_only, venue_reduce_only, intent_sequence, refs);
        self.* = candidate;
    }

    fn confirmReplacementInPlace(self: *Oms, order_id: u64, reservation: Reservation, portfolio_reduce_only: bool, venue_reduce_only: bool, intent_sequence: u64, refs: RiskFactRefs) !void {
        const predecessor = try self.mutableOrder(order_id);
        if (predecessor.state != .canceled or predecessor.replacement == null) return error.ReplacementNotReady;
        if (self.blocksNewSend()) return error.UncertainOrderBlocksSend;
        if (predecessor.revision != predecessor.replacement.?.expected_revision or
            predecessor.cumulative_quantity != predecessor.replacement.?.expected_cumulative_quantity)
            return error.StaleReplacementEvidence;
        predecessor.replacement.?.reservation = reservation;
        predecessor.replacement.?.portfolio_reduce_only = portfolio_reduce_only;
        predecessor.replacement.?.venue_reduce_only = venue_reduce_only;
        try self.createReplacement(predecessor, intent_sequence, refs);
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
        self.orders[index] = .{ .id = self.next_order_id, .strategy_instance = strategy_instance, .instrument = instrument, .side = side, .portfolio_reduce_only = portfolio_reduce_only, .venue_reduce_only = venue_reduce_only, .quantity = quantity, .limit_price = price, .reservation = reservation, .confirmed_reservation = reservation, .confirmed_quantity = quantity, .reservation_basis_quantity = quantity, .predecessor_order_id = predecessor, .group_first_sequence = group, .group_policy = policy, .client_order_id = client_order_id };
        self.next_order_id = try std.math.add(u64, self.next_order_id, 1);
        return &self.orders[index];
    }

    fn emit(self: *Oms, order: Order, operation: Operation, intent_sequence: u64, refs: RiskFactRefs) !void {
        if (self.command_count == max_commands or self.command_history_count == max_command_history) {
            self.recovery_only = true;
            return error.CommandCapacityExceeded;
        }
        const command_value: Command = .{ .command_id = self.next_command_id, .order_id = order.id, .strategy_instance = order.strategy_instance, .revision = order.revision, .operation = operation, .instrument = order.instrument, .side = order.side, .portfolio_reduce_only = order.portfolio_reduce_only, .venue_reduce_only = order.venue_reduce_only, .quantity = try std.math.sub(i64, order.quantity, order.cumulative_quantity), .limit_price = order.limit_price, .predecessor_order_id = order.predecessor_order_id, .reservation = order.reservation, .order_type = order.order_type, .time_in_force = order.time_in_force, .market_protection_price = order.market_protection_price, .client_order_id = order.client_order_id, .intent_sequence = intent_sequence, .risk_decision_identity = refs.decision, .reservation_identity = refs.reservation, .authority = refs.authority };
        self.commands[self.command_count] = command_value;
        self.command_count += 1;
        self.command_history[self.command_history_count] = command_value;
        self.command_history_count += 1;
        self.next_command_id = try std.math.add(u64, self.next_command_id, 1);
    }

    /// Finalize a newly emitted safety cancellation before the shard commits it.
    pub fn bindCancellationAuthority(self: *Oms, command_id: u64, authority: DispatchAuthorityRefs) !void {
        for (self.commands[0..self.command_count]) |*command| {
            if (command.command_id != command_id) continue;
            if (command.operation != .cancel) return error.NotCancellation;
            command.authority = authority;
            for (self.command_history[0..self.command_history_count]) |*historical| {
                if (historical.command_id == command_id) {
                    historical.authority = authority;
                    return;
                }
            }
            return error.MissingCommandHistory;
        }
        return error.UnknownCommand;
    }

    fn createReplacement(self: *Oms, predecessor: *Order, intent_sequence: u64, refs: RiskFactRefs) !void {
        const replacement = predecessor.replacement.?;
        predecessor.replacement = null;
        const next = try self.createOrder(predecessor.strategy_instance, replacement.instrument, replacement.side, replacement.portfolio_reduce_only, replacement.venue_reduce_only, replacement.quantity, replacement.limit_price, replacement.reservation, replacement.client_order_id, predecessor.id, predecessor.group_first_sequence, predecessor.group_policy);
        next.order_type = replacement.order_type;
        next.time_in_force = replacement.time_in_force;
        next.market_protection_price = replacement.market_protection_price;
        try self.emit(next.*, .place, intent_sequence, refs);
    }

    fn rejectCommand(_: *Oms, order: *Order, operation: Operation) !void {
        switch (operation) {
            .place => {
                order.state = .rejected;
                order.reservation_active = false;
            },
            .amend => {
                if (order.pending_reservation == null) return;
                order.state = if (order.cumulative_quantity == 0) .live else .partially_filled;
                order.quantity = order.confirmed_quantity;
                order.revision -= 1;
                if (order.pending_previous_spec) |previous| {
                    order.limit_price = previous.limit_price;
                    order.order_type = previous.order_type;
                    order.time_in_force = previous.time_in_force;
                    order.market_protection_price = previous.market_protection_price;
                }
                order.pending_reservation = null;
                order.pending_basis_quantity = 0;
                order.pending_previous_spec = null;
                try rebalanceReservation(order, @max(0, order.confirmed_quantity - order.cumulative_quantity));
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
                        const origin = self.originForOrder(order.id);
                        try self.emit(order.*, .cancel, origin.intent_sequence, origin.refs);
                    } else {
                        order.state = .rejected;
                        order.reservation_active = false;
                    }
                },
                .live, .partially_filled => {
                    order.state = .pending_cancel;
                    const origin = self.originForOrder(order.id);
                    try self.emit(order.*, .cancel, origin.intent_sequence, origin.refs);
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
            if (!self.isArchiveEligible(order)) continue;
            const last_report = try self.lastReportEvidence(order);
            const last_reconciliation = try self.lastReconciliationEvidence(order);
            const digest = orderFactDigest(order, last_report, last_reconciliation);
            if (!std.mem.eql(u8, &digest, &order.archive_audit_digest)) {
                self.recovery_only = true;
                return error.ArchiveAuditDigestMismatch;
            }
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

    fn isArchiveEligible(self: *const Oms, order: Order) bool {
        switch (order.state) {
            .filled, .canceled, .rejected => {},
            else => return false,
        }
        if (order.reservation_active or order.replacement != null or !order.archive_window_closed)
            return false;
        if (std.mem.eql(u8, &order.archive_audit_digest, &@as([32]u8, @splat(0))))
            return false;
        for (self.orders[0..self.order_count]) |other| {
            if (other.id != order.id and other.predecessor_order_id == order.id) return false;
        }
        return true;
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

    fn findCommandForOrder(self: *const Oms, order_id: u64) ?Command {
        var index = self.command_history_count;
        while (index != 0) {
            index -= 1;
            const command_value = self.command_history[index];
            if (command_value.order_id == order_id) return command_value;
        }
        return null;
    }

    fn cancelUnsettled(self: *const Oms, order: Order) bool {
        if (order.state == .pending_cancel) return true;
        if (order.state != .unknown) return false;
        const command_value = self.findCommandForOrder(order.id) orelse return false;
        return command_value.operation == .cancel;
    }

    fn originForOrder(self: *const Oms, order_id: u64) struct { intent_sequence: u64, refs: RiskFactRefs } {
        var index = self.command_history_count;
        while (index != 0) {
            index -= 1;
            const command_value = self.command_history[index];
            if (command_value.order_id == order_id) return .{
                .intent_sequence = command_value.intent_sequence,
                .refs = .{ .decision = command_value.risk_decision_identity, .reservation = command_value.reservation_identity, .authority = command_value.authority },
            };
        }
        return .{ .intent_sequence = 0, .refs = .{} };
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
    const old = try scaledReservation(order.confirmed_reservation.atoms, remaining_quantity, order.reservation_basis_quantity);
    var required = old;
    if (order.pending_reservation) |pending| {
        if (pending.atoms < 0 or order.pending_basis_quantity <= 0) return error.InvalidReservationBasis;
        required = @max(old, pending.atoms);
    }
    order.reservation.atoms = required;
}

fn scaledReservation(atoms: i128, remaining: i64, basis: i64) !i128 {
    if (atoms < 0 or remaining < 0 or basis <= 0) return error.InvalidReservationBasis;
    const numerator = try std.math.mul(i128, atoms, remaining);
    return @divFloor(try std.math.add(i128, numerator, basis - 1), basis);
}

fn intentFingerprint(intent: Intent, group_count: u8) [16]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&.{group_count});
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
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest[0..16].*;
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
        hash.update(&result.canonical_digest);
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

test "OMS commands bind distinct risk and reservation fact barriers" {
    var state: Oms = .{};
    var group: IntentGroup = .{ .first_intent_sequence = 7, .count = 2 };
    group.members[0] = .{ .intent_sequence = 7, .operation = .place, .instrument = 1, .quantity = 1, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 3 } };
    group.members[1] = .{ .intent_sequence = 8, .operation = .place, .instrument = 2, .quantity = 1, .limit_price = .{ .instrument = 2, .rules_version = 1, .ticks = 4 }, .reservation = .{ .asset = 1, .atoms = 4 } };
    try state.applyQualifiedGroup(group, group, &.{ .{ .decision = 3, .reservation = 4 }, .{ .decision = 5, .reservation = 6 } });
    try std.testing.expectEqual(@as(u64, 3), state.emitted()[0].risk_decision_identity);
    try std.testing.expectEqual(@as(u64, 4), state.emitted()[0].reservation_identity);
    try std.testing.expectEqual(@as(u64, 5), state.emitted()[1].risk_decision_identity);
    try std.testing.expectEqual(@as(u64, 6), state.emitted()[1].reservation_identity);

    var legacy: Oms = .{};
    try legacy.applyGroup(group);
    try std.testing.expectEqual(@as(u64, 0), legacy.emitted()[0].risk_decision_identity);
    try std.testing.expectEqual(@as(u64, 0), legacy.emitted()[0].reservation_identity);
}

test "OMS command keeps each exact order type and safety field" {
    const cases = [_]struct { order_type: canonical.OrderType, tif: canonical.TimeInForce }{
        .{ .order_type = .market, .tif = .immediate_or_cancel },
        .{ .order_type = .limit, .tif = .good_til_canceled },
        .{ .order_type = .post_only, .tif = .post_only },
        .{ .order_type = .ioc, .tif = .immediate_or_cancel },
        .{ .order_type = .fok, .tif = .fill_or_kill },
    };
    for (cases) |case| {
        var state: Oms = .{};
        var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
        group.members[0] = .{
            .intent_sequence = 1,
            .operation = .place,
            .instrument = 1,
            .side = .sell,
            .portfolio_reduce_only = true,
            .venue_reduce_only = true,
            .quantity = 3,
            .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 50 },
            .reservation = .{ .asset = 1, .atoms = 150 },
            .order_type = case.order_type,
            .time_in_force = case.tif,
            .market_protection_price = if (case.order_type == .market) .{ .instrument = 1, .rules_version = 1, .ticks = 49 } else null,
        };
        try state.applyGroup(group);
        const command = state.emitted()[0];
        try std.testing.expectEqual(Side.sell, command.side);
        try std.testing.expectEqual(@as(i64, 3), command.quantity);
        try std.testing.expect(command.portfolio_reduce_only and command.venue_reduce_only);
        try std.testing.expectEqual(case.order_type, command.order_type);
        try std.testing.expectEqual(case.tif, command.time_in_force);
        try std.testing.expectEqualDeep(group.members[0].market_protection_price, command.market_protection_price);
    }
    try std.testing.expect(!exactOrderTiming(.post_only, .good_til_canceled));
    try std.testing.expect(!exactOrderTiming(.limit, .post_only));
    try std.testing.expect(!exactOrderTiming(.market, .fill_or_kill));
    try std.testing.expect(!exactOrderSpec(.market, .immediate_or_cancel, false));
    try std.testing.expect(!exactOrderSpec(.limit, .good_til_canceled, true));
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

test "pending amend keeps old and new remaining exposure through fills and rejection" {
    var state: Oms = .{};
    const placed = try placeSubmitted(&state, 1, 10);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10 });
    state.begin();
    var group: IntentGroup = .{ .first_intent_sequence = 2, .count = 1 };
    group.members[0] = .{ .intent_sequence = 2, .strategy_instance = 1, .operation = .amend, .instrument = 1, .target_order_id = placed.order_id, .expected_revision = 1, .quantity = 20, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 2 }, .reservation = .{ .asset = 1, .atoms = 20 } };
    try state.applyGroup(group);
    try std.testing.expectEqual(@as(i128, 20), (try state.activeReservations(1)).atoms);
    try state.applyReport(.{ .report_id = 2, .order_id = placed.order_id, .revision = 1, .status = .partially_filled, .cumulative_quantity = 2, .remaining_quantity = 8 });
    try std.testing.expectEqual(OrderState.pending_amend, state.orderById(placed.order_id).?.state);
    try std.testing.expectEqual(@as(i128, 20), (try state.activeReservations(1)).atoms);
    try state.applyReport(.{ .report_id = 3, .order_id = placed.order_id, .revision = 2, .status = .rejected, .cumulative_quantity = 2, .remaining_quantity = 8 });
    try std.testing.expectEqual(OrderState.partially_filled, state.orderById(placed.order_id).?.state);
    try std.testing.expectEqual(@as(i64, 10), state.orderById(placed.order_id).?.quantity);
    try std.testing.expectEqual(@as(u32, 1), state.orderById(placed.order_id).?.revision);
    try std.testing.expectEqual(@as(i128, 1), state.orderById(placed.order_id).?.limit_price.ticks);
    try std.testing.expectEqual(@as(i128, 8), (try state.activeReservations(1)).atoms);
}

test "pending amend confirmation, Unknown and replay keep conservative reservations" {
    var state: Oms = .{};
    const placed = try placeSubmitted(&state, 1, 10);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10 });
    state.begin();
    var group: IntentGroup = .{ .first_intent_sequence = 2, .count = 1 };
    group.members[0] = .{ .intent_sequence = 2, .strategy_instance = 1, .operation = .amend, .instrument = 1, .target_order_id = placed.order_id, .expected_revision = 1, .quantity = 20, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 2 }, .reservation = .{ .asset = 1, .atoms = 20 } };
    try state.applyGroup(group);
    var dispatch: DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = state.emitted()[0].command_id, .state = .unknown };
    try state.applyDispatch(dispatch);
    try state.applyReport(.{ .report_id = 2, .order_id = placed.order_id, .revision = 1, .status = .partially_filled, .cumulative_quantity = 2, .remaining_quantity = 8 });
    try std.testing.expectEqual(OrderState.unknown, state.orderById(placed.order_id).?.state);
    try std.testing.expect(state.blocksNewSend());
    try std.testing.expectEqual(@as(i128, 20), (try state.activeReservations(1)).atoms);
    try std.testing.expectError(error.ConflictingReconciliationEvidence, state.applyReconciliation(.{ .reconciliation_id = 1, .order_id = placed.order_id, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 10 }));
    try std.testing.expectError(error.ConflictingReconciliationEvidence, state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = placed.order_id, .status = .found_live, .revision = 2, .cumulative_quantity = 2, .remaining_quantity = 1 }));
    try std.testing.expectError(error.InvalidExecutionReport, state.applyReport(.{ .report_id = 3, .order_id = placed.order_id, .revision = 2, .status = .filled, .cumulative_quantity = 3, .remaining_quantity = 0 }));
    try std.testing.expectEqual(@as(i128, 20), (try state.activeReservations(1)).atoms);
    const snapshot = state;
    try state.applyReport(.{ .report_id = 3, .order_id = placed.order_id, .revision = 2, .status = .amended, .cumulative_quantity = 2, .remaining_quantity = 18 });
    try std.testing.expectEqual(@as(i128, 18), (try state.activeReservations(1)).atoms);
    try std.testing.expectEqual(@as(i64, 20), state.orderById(placed.order_id).?.quantity);
    var recovered = snapshot;
    try recovered.applyReport(.{ .report_id = 3, .order_id = placed.order_id, .revision = 2, .status = .amended, .cumulative_quantity = 2, .remaining_quantity = 18 });
    try std.testing.expectEqual(state.orderById(placed.order_id).?.reservation.atoms, recovered.orderById(placed.order_id).?.reservation.atoms);
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

test "an earlier live reconciliation forbids later absence for the same place" {
    var state = Oms{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try state.applyGroup(group);
    var dispatch: DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = 1, .state = .unknown };
    try state.applyDispatch(dispatch);
    try state.applyReconciliation(.{ .reconciliation_id = 1, .order_id = 1, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyDispatch(dispatch);
    try std.testing.expectError(error.ConflictingReconciliationEvidence, state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = 1, .status = .confirmed_absent, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2 }));
    try std.testing.expect(state.orders[0].reservation_active);
}

test "FoundTerminal requires an explicit terminal category" {
    var state = Oms{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try state.applyGroup(group);
    try std.testing.expectError(error.IncompleteReconciliationEvidence, state.applyReconciliation(.{ .reconciliation_id = 1, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 2, .remaining_quantity = 0 }));
}

test "canonical report digest is part of report identity" {
    var state = Oms{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try state.applyGroup(group);
    var report: ExecutionReport = .{
        .report_id = 1,
        .order_id = 1,
        .revision = 1,
        .status = .canceled,
        .cumulative_quantity = 0,
        .remaining_quantity = 2,
        .canonical_digest = @splat(1),
    };
    try state.applyReport(report);
    try std.testing.expectEqual(Oms.ReportIdentity.duplicate, try state.lookupReport(report));
    report.canonical_digest = @splat(2);
    try std.testing.expectError(error.ConflictingReportIdentity, state.lookupReport(report));
    try std.testing.expectError(error.ConflictingReportIdentity, state.applyReport(report));
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
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@FieldType(SeenIntent, "fingerprint")));
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
    try std.testing.expect(state.orderById(2) != null);
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
    while (sequence <= max_orders) : (sequence += 1) {
        const placed = try placeSubmitted(&state, sequence, 1);
        try state.applyReport(.{ .report_id = sequence, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 1 });
        try state.applyReconciliation(.{
            .reconciliation_id = 100 + sequence,
            .order_id = placed.order_id,
            .status = .found_terminal,
            .revision = 1,
            .cumulative_quantity = 0,
            .remaining_quantity = 1,
            .terminal_state = .canceled,
        });
    }
    while (sequence <= max_orders + max_tombstones) : (sequence += 1) {
        const placed = try placeSubmitted(&state, sequence, 1);
        try state.applyReport(.{ .report_id = sequence, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 1 });
        try state.applyReconciliation(.{
            .reconciliation_id = 100 + sequence,
            .order_id = placed.order_id,
            .status = .found_terminal,
            .revision = 1,
            .cumulative_quantity = 0,
            .remaining_quantity = 1,
            .terminal_state = .canceled,
        });
    }
    state.begin();
    var overflow: IntentGroup = .{ .first_intent_sequence = sequence, .count = 1 };
    overflow.members[0] = .{ .intent_sequence = sequence, .strategy_instance = 1, .operation = .place, .instrument = 1, .quantity = 1, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 1 }, .reservation = .{ .asset = 1, .atoms = 1 } };
    try std.testing.expectError(error.TombstoneCapacityExceeded, state.applyGroup(overflow));
    try std.testing.expect(state.recovery_only);
    try std.testing.expectEqual(@as(u8, max_orders), state.order_count);
    try std.testing.expectEqual(@as(u8, max_tombstones), state.tombstone_count);
}

test "canceled orders without archive window stay hot under capacity pressure" {
    var state = Oms{};
    var sequence: u64 = 1;
    while (sequence <= max_orders) : (sequence += 1) {
        const placed = try placeSubmitted(&state, sequence, 2);
        try state.applyReport(.{ .report_id = sequence, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
        try std.testing.expect(!state.orderById(placed.order_id).?.archive_window_closed);
    }
    try std.testing.expectError(error.OrderCapacityExceeded, placeSubmitted(&state, sequence, 2));
    try std.testing.expect(state.recovery_only);
    try std.testing.expectEqual(@as(u8, max_orders), state.order_count);
    try std.testing.expectEqual(@as(u8, 0), state.tombstone_count);
}

test "live unknown and pending_cancel orders never compact" {
    var live = Oms{};
    var sequence: u64 = 1;
    while (sequence <= max_orders) : (sequence += 1) {
        _ = try placeSubmitted(&live, sequence, 2);
    }
    try std.testing.expectError(error.OrderCapacityExceeded, placeSubmitted(&live, sequence, 2));
    try std.testing.expect(live.recovery_only);
    try std.testing.expectEqual(@as(u8, 0), live.tombstone_count);
    for (live.orders[0..live.order_count]) |order| try std.testing.expectEqual(OrderState.pending_submit, order.state);

    var unknown = Oms{};
    const unknown_placed = try placeSubmitted(&unknown, 1, 2);
    var unknown_dispatch: DispatchBatch = .{ .count = 1 };
    unknown_dispatch.items[0] = .{ .command_id = unknown_placed.command_id, .state = .unknown };
    try unknown.applyDispatch(unknown_dispatch);
    try std.testing.expectError(error.UncertainOrderBlocksSend, placeSubmitted(&unknown, 2, 2));
    try std.testing.expectEqual(OrderState.unknown, unknown.orderById(unknown_placed.order_id).?.state);
    try std.testing.expectEqual(@as(u8, 1), unknown.order_count);
    try std.testing.expectEqual(@as(u8, 0), unknown.tombstone_count);

    var pending = Oms{};
    const pending_placed = try placeSubmitted(&pending, 1, 2);
    try pending.applyReport(.{ .report_id = 1, .order_id = pending_placed.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 2 });
    pending.begin();
    var cancel: IntentGroup = .{ .first_intent_sequence = 90, .count = 1 };
    cancel.members[0] = .{
        .intent_sequence = 90,
        .strategy_instance = 1,
        .operation = .cancel,
        .instrument = 1,
        .target_order_id = pending_placed.order_id,
        .expected_revision = 1,
    };
    try pending.applyGroup(cancel);
    try std.testing.expectEqual(OrderState.pending_cancel, pending.orderById(pending_placed.order_id).?.state);
    try std.testing.expectError(error.UncertainOrderBlocksSend, placeSubmitted(&pending, 2, 2));
    try std.testing.expectEqual(OrderState.pending_cancel, pending.orderById(pending_placed.order_id).?.state);
    try std.testing.expectEqual(@as(u8, 1), pending.order_count);
    try std.testing.expectEqual(@as(u8, 0), pending.tombstone_count);
}

test "ccc predecessor stays hot while successor is live" {
    var state = Oms{};
    const placed = try placeSubmitted(&state, 1, 2);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 2 });
    state.begin();
    var replace: IntentGroup = .{ .first_intent_sequence = 2, .count = 1 };
    replace.members[0] = .{
        .intent_sequence = 2,
        .strategy_instance = 1,
        .operation = .amend,
        .instrument = 1,
        .target_order_id = placed.order_id,
        .expected_revision = 1,
        .quantity = 2,
        .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 4 },
        .native_amend = false,
        .allow_cancel_confirm_create = true,
        .reservation = .{ .asset = 1, .atoms = 6 },
    };
    try state.applyGroup(replace);
    try state.applyReport(.{ .report_id = 2, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReconciliation(.{
        .reconciliation_id = 10,
        .order_id = placed.order_id,
        .status = .found_terminal,
        .revision = 1,
        .cumulative_quantity = 0,
        .remaining_quantity = 2,
        .terminal_state = .canceled,
    });
    try std.testing.expect(state.orderById(placed.order_id).?.archive_window_closed);
    try std.testing.expect(state.orderById(placed.order_id).?.replacement != null);
    try state.confirmReplacement(placed.order_id, .{ .asset = 1, .atoms = 6 }, false, false, 2, .{});
    const successor = state.orderById(2) orelse return error.MissingReplacement;
    try std.testing.expectEqual(placed.order_id, successor.predecessor_order_id);
    var sequence: u64 = 3;
    while (sequence <= max_orders) : (sequence += 1) _ = try placeSubmitted(&state, sequence, 2);
    try std.testing.expectError(error.OrderCapacityExceeded, placeSubmitted(&state, sequence, 2));
    try std.testing.expect(state.orderById(placed.order_id) != null);
    try std.testing.expectEqual(@as(u8, 0), state.tombstone_count);
}

test "compact refuses a mutated audit digest after the archive window closes" {
    var state = Oms{};
    var sequence: u64 = 1;
    while (sequence <= max_orders) : (sequence += 1) {
        const placed = try placeSubmitted(&state, sequence, 2);
        try state.applyReport(.{ .report_id = sequence, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
        try state.applyReconciliation(.{
            .reconciliation_id = 200 + sequence,
            .order_id = placed.order_id,
            .status = .found_terminal,
            .revision = 1,
            .cumulative_quantity = 0,
            .remaining_quantity = 2,
            .terminal_state = .canceled,
        });
    }
    state.orders[0].quantity = 99;
    try std.testing.expectError(error.ArchiveAuditDigestMismatch, placeSubmitted(&state, sequence, 2));
    try std.testing.expect(state.recovery_only);
    try std.testing.expectEqual(@as(u8, max_orders), state.order_count);
    try std.testing.expectEqual(@as(u8, 0), state.tombstone_count);
}

fn placeSubmitted(state: *Oms, sequence: u64, quantity: i64) !struct { order_id: u64, command_id: u64 } {
    state.begin();
    var group: IntentGroup = .{ .first_intent_sequence = sequence, .count = 1 };
    group.members[0] = .{
        .intent_sequence = sequence,
        .strategy_instance = 1,
        .operation = .place,
        .instrument = 1,
        .quantity = quantity,
        .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 1 },
        .reservation = .{ .asset = 1, .atoms = quantity },
    };
    try state.applyGroup(group);
    const command_value = state.emitted()[0];
    var dispatch: DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = command_value.command_id, .state = .submitted };
    try state.applyDispatch(dispatch);
    return .{ .order_id = command_value.order_id, .command_id = command_value.command_id };
}

fn commitArchiveQualification(self: *Oms, order: *Order) !void {
    switch (order.state) {
        .filled, .canceled, .rejected => {},
        else => return,
    }
    if (order.reservation_active) return;
    const last_report = try self.lastReportEvidence(order.*);
    const last_reconciliation = try self.lastReconciliationEvidence(order.*) orelse return;
    const digest = orderFactDigest(order.*, last_report, last_reconciliation);
    if (order.archive_window_closed) {
        if (!std.mem.eql(u8, &order.archive_audit_digest, &digest)) {
            self.recovery_only = true;
            return error.ArchiveAuditDigestMismatch;
        }
        return;
    }
    order.archive_audit_digest = digest;
    order.archive_window_closed = true;
}

fn rememberReport(order: *Order, report: ExecutionReport) void {
    order.last_report_id = report.report_id;
    order.last_report_revision = report.revision;
    order.last_report_status = report.status;
    order.last_report_cumulative_quantity = report.cumulative_quantity;
    order.last_report_remaining_quantity = report.remaining_quantity;
}
