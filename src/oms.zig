const std = @import("std");
const canonical = @import("canonical_event.zig");

pub const max_live_orders = 1024;
pub const max_retained_terminal_orders = 4096;
// Existing live slots retain authoritative terminal facts during pressure;
// admission budgets remain independent and no slot is silently recycled.
pub const max_orders = max_live_orders + max_retained_terminal_orders;
pub const max_group_members = 4;
pub const max_commands = 8;
pub const max_command_history = 2 * max_orders;
pub const max_fact_history = 3 * max_orders;
pub const max_intent_history = 2 * max_orders;
pub const max_tombstones = 2;

fn orderCapacityReached(live_count: usize, total_count: usize) bool {
    return live_count >= max_live_orders or total_count == max_orders;
}

test "OMS order capacity guard checks numeric boundaries without order population" {
    try std.testing.expect(!orderCapacityReached(1023, max_orders - 1));
    try std.testing.expect(orderCapacityReached(1024, max_orders - 1));
    try std.testing.expect(orderCapacityReached(0, max_orders));
    try std.testing.expect(!orderCapacityReached(0, max_orders - 1));
}

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
    margin_rules: FactRef = .{},
    instrument_trading: FactRef = .{},
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
            self.margin_rules.identity != 0 and self.margin_rules.version != 0 and self.margin_rules.barrier != 0 and
            self.instrument_trading.identity != 0 and self.instrument_trading.version != 0 and self.instrument_trading.barrier != 0 and
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
    intent_sequence: u64,
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
    created_at_utc_ns: u64 = 0,
    terminal_observed_at_utc_ns: u64 = 0,
    terminal_archive_evidence: ?canonical.ReconciliationEvidence = null,
    archive_window_closed: bool = false,
    archive_audit_digest: [32]u8 = @splat(0),
};

pub const OrderArchiveQualification = struct {
    order: Order,
    last_report: ?ExecutionReport,
    last_reconciliation: ?ReconciliationResult,
    applied_fill_quantity: i64,
    exchange_account: canonical.ExchangeAccountIdentity,
    reference_digest: [32]u8,

    pub fn digest(self: @This()) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("OrderArchiveQualificationV1");
        archiveHashValue(&hash, self);
        var result: [32]u8 = undefined;
        hash.final(&result);
        return result;
    }
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

// Negative membership skips unrelated history; every positive still uses the
// original exact lookup, including intentional bit collisions.
const IntentMembership = struct {
    bits: [2048]u8 = @splat(0),

    fn bit(sequence: u64) usize {
        return @intCast((sequence ^ (sequence >> 32)) & (2048 * 8 - 1));
    }

    fn add(self: *IntentMembership, sequence: u64) void {
        const index = bit(sequence);
        self.bits[index / 8] |= @as(u8, 1) << @as(u3, @intCast(index % 8));
    }

    fn maybeContains(self: *const IntentMembership, sequence: u64) bool {
        const index = bit(sequence);
        return self.bits[index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8))) != 0;
    }
};

// These transactions append histories; only existing order rows need an undo copy.
const MutationUndo = struct {
    const max_rows = max_commands * (max_group_members + 1);
    const Header = struct {
        order_count: u16,
        command_count: u8,
        command_history_count: u16,
        report_history_count: u16,
        reconciliation_history_count: u16,
        intent_history_count: u16,
        tombstone_count: u16,
        recovery_only: bool,
        capacity_pressure: bool,
        next_order_id: u64,
        next_command_id: u64,
    };

    header: Header,
    indices: [max_rows]u16,
    rows: [max_rows]Order,
    count: usize,

    fn init(self: *MutationUndo, state: *const Oms) void {
        self.count = 0;
        inline for (std.meta.fields(Header)) |field| @field(self.header, field.name) = @field(state, field.name);
    }

    fn captureOrder(self: *MutationUndo, state: *const Oms, id: u64) bool {
        const index = state.orderIndex(id) orelse return true;
        for (self.indices[0..self.count]) |known| if (known == index) return true;
        if (self.count == max_rows) return false;
        self.indices[self.count] = @intCast(index);
        self.rows[self.count] = state.orders[index];
        self.count += 1;
        return true;
    }

    fn captureGroup(self: *MutationUndo, state: *const Oms, group: u64) bool {
        for (state.orders[0..state.order_count]) |*order| {
            if (order.group_first_sequence == group and !self.captureOrder(state, order.id)) return false;
        }
        return true;
    }

    fn rollback(self: *const MutationUndo, state: *Oms) void {
        for (self.indices[0..self.count], self.rows[0..self.count]) |index, row| state.orders[index] = row;
        inline for (std.meta.fields(Header)) |field| @field(state, field.name) = @field(self.header, field.name);
    }
};

pub const Oms = struct {
    orders: [max_orders]Order = undefined,
    order_count: u16 = 0,
    commands: [max_commands]Command = undefined,
    command_count: u8 = 0,
    command_history: [max_command_history]Command = undefined,
    command_history_count: u16 = 0,
    report_history: [max_fact_history]ExecutionReport = undefined,
    report_history_count: u16 = 0,
    reconciliation_history: [max_fact_history]ReconciliationResult = undefined,
    reconciliation_history_count: u16 = 0,
    intent_history: [max_intent_history]SeenIntent = undefined,
    intent_history_count: u16 = 0,
    tombstones: [max_tombstones]Tombstone = undefined,
    tombstone_count: u16 = 0,
    recovery_only: bool = false,
    capacity_pressure: bool = false,
    next_order_id: u64 = 1,
    next_command_id: u64 = 1,

    pub fn liveOrderCount(self: *const Oms) u16 {
        var count: u16 = 0;
        for (self.orders[0..self.order_count]) |*order| if (!retainedTerminal(order)) {
            count += 1;
        };
        return count;
    }

    pub fn retainedTerminalOrderCount(self: *const Oms) u16 {
        return self.order_count - self.liveOrderCount();
    }

    fn retainCapacityPressure(self: *Oms) void {
        if (self.order_count <= max_retained_terminal_orders) return;
        if (self.retainedTerminalOrderCount() > max_retained_terminal_orders) self.capacity_pressure = true;
    }

    pub fn noteOrderCreated(self: *Oms, order_id: u64, utc_ns: u64) !void {
        const order = try self.mutableOrder(order_id);
        if (utc_ns == 0) return error.InvalidOrderArchiveTime;
        if (order.created_at_utc_ns != 0 and order.created_at_utc_ns != utc_ns) return error.ConflictingOrderArchiveTime;
        order.created_at_utc_ns = utc_ns;
    }

    pub fn noteTerminalObserved(self: *Oms, order_id: u64, utc_ns: u64) !void {
        const order = try self.mutableOrder(order_id);
        if (!safeTerminal(order.*) or utc_ns == 0 or order.created_at_utc_ns == 0 or utc_ns < order.created_at_utc_ns)
            return error.InvalidOrderArchiveTime;
        if (order.terminal_observed_at_utc_ns == 0) order.terminal_observed_at_utc_ns = utc_ns;
    }

    pub fn retainTerminalArchiveCoverage(self: *Oms, order_id: u64, evidence: canonical.ReconciliationEvidence) !void {
        const order = try self.mutableOrder(order_id);
        try validateTerminalArchiveCoverage(order.*, evidence, evidence.scope.exchange_account);
        order.terminal_archive_evidence = evidence;
    }

    pub fn prepareOrderArchive(self: *const Oms, order_id: u64, applied_fill_quantity: i64, exchange_account: canonical.ExchangeAccountIdentity) !OrderArchiveQualification {
        const order = self.orderById(order_id) orelse return error.UnknownOrder;
        if (self.recovery_only) return error.OrderArchiveNotQualified;
        if (!safeTerminal(order) or order.reservation_active or order.reservation.atoms != 0 or
            order.pending_reservation != null or order.pending_previous_spec != null or
            order.pending_basis_quantity != 0 or order.replacement != null or
            applied_fill_quantity < 0 or applied_fill_quantity != order.cumulative_quantity)
            return error.OrderArchiveNotQualified;
        const evidence = order.terminal_archive_evidence orelse return error.OrderArchiveNotQualified;
        try validateTerminalArchiveCoverage(order, evidence, exchange_account);
        for (self.orders[0..self.order_count]) |other| {
            if (other.id == order.id) continue;
            if (other.predecessor_order_id == order.id or
                (other.strategy_instance == order.strategy_instance and other.group_first_sequence == order.group_first_sequence and
                    (!safeTerminal(other) or other.reservation_active or other.reservation.atoms != 0 or
                        other.pending_reservation != null or other.pending_previous_spec != null or
                        other.pending_basis_quantity != 0 or other.replacement != null)))
                return error.OrderArchiveReferenced;
        }
        const report = try self.lastReportEvidence(order);
        const reconciliation = try self.lastReconciliationEvidence(order);
        if (reconciliation == null or reconciliation.?.status != .found_terminal or
            reconciliation.?.cumulative_quantity != order.cumulative_quantity)
            return error.OrderArchiveNotQualified;
        return .{ .order = order, .last_report = report, .last_reconciliation = reconciliation, .applied_fill_quantity = applied_fill_quantity, .exchange_account = exchange_account, .reference_digest = self.archiveReferenceDigest(order) };
    }

    /// Core calls this only after validating the durable business-history root fact.
    pub fn commitOrderArchive(self: *Oms, qualification: OrderArchiveQualification) !void {
        const current = try self.prepareOrderArchive(qualification.order.id, qualification.applied_fill_quantity, qualification.exchange_account);
        if (!std.mem.eql(u8, &current.digest(), &qualification.digest())) return error.StaleOrderArchiveQualification;
        const order = qualification.order;
        const membership = self.orderIntentMembership(order.id);
        var index: usize = 0;
        while (index < self.intent_history_count) {
            const intent = self.intent_history[index];
            if (!self.intentReferencesOrder(intent, order, &membership)) {
                index += 1;
                continue;
            }
            var referenced = false;
            for (self.orders[0..self.order_count]) |other| {
                if (other.id != order.id and other.strategy_instance == intent.strategy_instance and other.group_first_sequence == intent.group) referenced = true;
            }
            for (self.command_history[0..self.command_history_count]) |command| {
                if (command.order_id != order.id and command.strategy_instance == intent.strategy_instance and command.intent_sequence == intent.intent_sequence) referenced = true;
            }
            if (!referenced) removeArchiveEntry(SeenIntent, &self.intent_history, &self.intent_history_count, index) else index += 1;
        }
        index = 0;
        while (index < self.order_count) {
            if (self.orders[index].id == order.id) {
                removeArchiveEntry(Order, &self.orders, &self.order_count, index);
                break;
            }
            index += 1;
        }
        index = 0;
        while (index < self.command_count) {
            if (self.commands[index].order_id == order.id) removeArchiveEntry(Command, &self.commands, &self.command_count, index) else index += 1;
        }
        index = 0;
        while (index < self.command_history_count) {
            if (self.command_history[index].order_id == order.id) removeArchiveEntry(Command, &self.command_history, &self.command_history_count, index) else index += 1;
        }
        index = 0;
        while (index < self.report_history_count) {
            if (self.report_history[index].order_id == order.id) removeArchiveEntry(ExecutionReport, &self.report_history, &self.report_history_count, index) else index += 1;
        }
        index = 0;
        while (index < self.reconciliation_history_count) {
            if (self.reconciliation_history[index].order_id == order.id) removeArchiveEntry(ReconciliationResult, &self.reconciliation_history, &self.reconciliation_history_count, index) else index += 1;
        }
        index = 0;
        while (index < self.tombstone_count) {
            if (self.tombstones[index].order_id == order.id) removeArchiveEntry(Tombstone, &self.tombstones, &self.tombstone_count, index) else index += 1;
        }
    }

    fn orderIntentMembership(self: *const Oms, order_id: u64) IntentMembership {
        var membership: IntentMembership = .{};
        for (self.command_history[0..self.command_history_count]) |*command| {
            if (command.order_id == order_id) membership.add(command.intent_sequence);
        }
        return membership;
    }

    fn intentReferencesOrder(self: *const Oms, intent: SeenIntent, order: Order, membership: *const IntentMembership) bool {
        if (intent.strategy_instance != order.strategy_instance) return false;
        if (intent.group == order.group_first_sequence or intent.intent_sequence == order.intent_sequence) return true;
        if (!membership.maybeContains(intent.intent_sequence)) return false;
        for (self.command_history[0..self.command_history_count]) |*command| {
            if (command.order_id == order.id and command.intent_sequence == intent.intent_sequence) return true;
        }
        return false;
    }

    fn archiveReferenceDigest(self: *const Oms, order: Order) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("OmsArchiveReferencesV1");
        const membership = self.orderIntentMembership(order.id);
        for (self.command_history[0..self.command_history_count]) |command| {
            if (command.order_id == order.id) {
                hash.update(&.{1});
                archiveHashValue(&hash, command);
            }
        }
        for (self.intent_history[0..self.intent_history_count]) |intent| {
            if (self.intentReferencesOrder(intent, order, &membership)) {
                hash.update(&.{2});
                archiveHashValue(&hash, intent);
            }
        }
        for (self.report_history[0..self.report_history_count]) |report| {
            if (report.order_id == order.id) {
                hash.update(&.{3});
                archiveHashValue(&hash, report);
            }
        }
        for (self.reconciliation_history[0..self.reconciliation_history_count]) |reconciliation| {
            if (reconciliation.order_id == order.id) {
                hash.update(&.{4});
                archiveHashValue(&hash, reconciliation);
            }
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return digest;
    }

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
        if (self.capacity_pressure) return true;
        for (self.orders[0..self.order_count]) |order| switch (order.state) {
            .unknown, .pending_cancel => return true,
            else => {},
        };
        return false;
    }

    pub fn orderById(self: *const Oms, id: u64) ?Order {
        const index = self.orderIndex(id) orelse return null;
        return self.orders[index];
    }

    fn orderIndex(self: *const Oms, id: u64) ?usize {
        // shortcut: sparse ID windows use a bounded scan; index if qualified lookup latency requires it.
        if (self.order_count != 0 and id >= self.orders[0].id) {
            const hint = id - self.orders[0].id;
            if (hint < self.order_count and self.orders[@intCast(hint)].id == id) return @intCast(hint);
        }
        for (self.orders[0..self.order_count], 0..) |*order, index| if (order.id == id) return index;
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

    pub fn rememberRejectedGroup(self: *Oms, group: IntentGroup) !void {
        switch (try self.groupIdentityStatus(group)) {
            .duplicate => return,
            .conflict => return error.ConflictingIntentIdentity,
            .fresh => {},
        }
        if (self.intent_history_count + group.count > max_intent_history) {
            self.recovery_only = true;
            return error.IdentitySetFull;
        }
        for (group.members[0..group.count]) |intent| {
            self.intent_history[self.intent_history_count] = .{ .strategy_instance = intent.strategy_instance, .intent_sequence = intent.intent_sequence, .group = group.first_intent_sequence, .policy = group.policy, .fingerprint = intentFingerprint(intent, group.count) };
            self.intent_history_count += 1;
        }
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
        var undo: MutationUndo = undefined;
        undo.init(self);
        if (group.count == 0 or group.count > max_group_members)
            return @call(.never_inline, applyGroupWithRefsCopy, .{ self, group, original, refs });
        for (group.members[0..group.count]) |intent| {
            if (!undo.captureOrder(self, intent.target_order_id))
                return @call(.never_inline, applyGroupWithRefsCopy, .{ self, group, original, refs });
        }
        // Numeric group identities may span more rows than one bounded intent group.
        if (group.policy == .cancel_remaining and !undo.captureGroup(self, group.first_intent_sequence))
            return @call(.never_inline, applyGroupWithRefsCopy, .{ self, group, original, refs });
        self.applyGroupInPlace(group, original, refs) catch |err| {
            const recovery_only = self.recovery_only;
            const capacity_pressure = self.capacity_pressure;
            undo.rollback(self);
            self.recovery_only = self.recovery_only or recovery_only;
            self.capacity_pressure = self.capacity_pressure or capacity_pressure;
            return err;
        };
    }

    fn applyGroupWithRefsCopy(self: *Oms, group: IntentGroup, original: IntentGroup, refs: []const RiskFactRefs) !void {
        var candidate = self.*;
        candidate.applyGroupInPlace(group, original, refs) catch |err| {
            // Capacity exhaustion is an authoritative safety transition even
            // though the rejected intent group itself is not committed.
            if (candidate.recovery_only) self.recovery_only = true;
            if (candidate.capacity_pressure) self.capacity_pressure = true;
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
                const order = try self.createOrder(intent.strategy_instance, intent.instrument, intent.side, intent.portfolio_reduce_only, intent.venue_reduce_only, intent.quantity, intent.limit_price, intent.reservation, intent.client_order_id, 0, intent.intent_sequence, group, policy);
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
        var undo: MutationUndo = undefined;
        undo.init(self);
        if (batch.count == 0 or batch.count > max_commands)
            return @call(.never_inline, applyDispatchCopy, .{ self, batch });
        for (batch.items[0..batch.count]) |item| {
            const command = self.findCommand(item.command_id) orelse continue;
            if (!undo.captureOrder(self, command.order_id))
                return @call(.never_inline, applyDispatchCopy, .{ self, batch });
            const order = self.orderById(command.order_id) orelse continue;
            if (order.group_policy == .cancel_remaining and !undo.captureGroup(self, order.group_first_sequence))
                return @call(.never_inline, applyDispatchCopy, .{ self, batch });
        }
        self.applyDispatchInPlace(batch) catch |err| {
            undo.rollback(self);
            return err;
        };
        self.retainCapacityPressure();
    }

    fn applyDispatchCopy(self: *Oms, batch: DispatchBatch) !void {
        var candidate = self.*;
        try candidate.applyDispatchInPlace(batch);
        candidate.retainCapacityPressure();
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
        var undo: MutationUndo = undefined;
        undo.init(self);
        const captured = undo.captureOrder(self, report.order_id);
        std.debug.assert(captured);
        self.applyReportInPlace(report) catch |err| {
            const recovery_only = self.recovery_only;
            undo.rollback(self);
            self.recovery_only = self.recovery_only or recovery_only;
            return err;
        };
        self.retainCapacityPressure();
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
        const canonical_report = !std.mem.allEqual(u8, &report.canonical_digest, 0);
        if (!canonical_report and report.report_id < order.last_report_id) return;
        if (report.report_id == order.last_report_id) {
            if (report.revision != order.last_report_revision or report.status != order.last_report_status or
                report.cumulative_quantity != order.last_report_cumulative_quantity or
                report.remaining_quantity != order.last_report_remaining_quantity)
                return error.ConflictingReportIdentity;
            return;
        }
        const reported_quantity = std.math.add(i64, report.cumulative_quantity, report.remaining_quantity) catch return error.Overflow;
        const pending_amend = order.pending_reservation != null;
        if (canonical_report and !pending_amend and report.revision < order.revision) {
            var historical_quantity: ?i64 = null;
            for (self.command_history[0..self.command_history_count]) |known| {
                if (known.order_id == report.order_id and known.revision == report.revision and known.operation == .place)
                    historical_quantity = known.quantity;
            }
            for (self.report_history[0 .. self.report_history_count - 1]) |known| {
                if (known.order_id == report.order_id and known.revision == report.revision and known.status == .amended)
                    historical_quantity = try std.math.add(i64, known.cumulative_quantity, known.remaining_quantity);
            }
            const historical_total = historical_quantity orelse return error.StaleOrderRevision;
            if (report.cumulative_quantity < 0 or report.remaining_quantity < 0 or reported_quantity > historical_total)
                return error.InvalidExecutionReport;
            if ((report.status == .accepted or report.status == .partially_filled) and
                report.cumulative_quantity <= order.cumulative_quantity) return;
            return error.InvalidExecutionReport;
        }
        if (pending_amend and report.revision > order.revision) return error.StaleOrderRevision;
        const old_revision_report = pending_amend and report.revision < order.revision;
        const pending_max_total = if (pending_amend) std.math.add(i64, order.cumulative_quantity, order.pending_basis_quantity) catch return error.Overflow else 0;
        if (report.cumulative_quantity < 0 or (!canonical_report and report.cumulative_quantity < order.cumulative_quantity) or report.remaining_quantity < 0 or
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
        if (canonical_report) {
            if (report.cumulative_quantity < 0 or report.remaining_quantity < 0)
                return error.InvalidExecutionReport;
            if (report.revision > order.revision) return error.StaleOrderRevision;
            // Canonical identities are content digests. Progress comes from Venue
            // revision/cumulative state, never from the numeric digest value.
            if (report.cumulative_quantity < order.cumulative_quantity) {
                if (report.status == .filled or report.status == .canceled or report.status == .rejected) return error.InvalidExecutionReport;
                return;
            }
            if (report.cumulative_quantity == order.cumulative_quantity) {
                if (report.revision < order.last_report_revision) return;
                if (report.revision == order.last_report_revision and report.status == .accepted and
                    order.last_report_status != .accepted) return;
                if (report.revision == order.last_report_revision and report.status == order.last_report_status and
                    report.remaining_quantity == order.last_report_remaining_quantity)
                {
                    // Equivalent source evidence chooses a stable representative.
                    if (report.report_id > order.last_report_id) rememberReport(order, report);
                    return;
                }
            }
        }
        if (order.state == .filled or order.state == .canceled or order.state == .rejected) {
            self.recovery_only = true;
            return error.TerminalFactConflict;
        }
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
        var undo: MutationUndo = undefined;
        undo.init(self);
        const captured = undo.captureOrder(self, result.order_id);
        std.debug.assert(captured);
        self.applyReconciliationInPlace(result) catch |err| {
            const recovery_only = self.recovery_only;
            undo.rollback(self);
            self.recovery_only = self.recovery_only or recovery_only;
            return err;
        };
        self.retainCapacityPressure();
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
                result.revision != order.revision)
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
                try rememberTerminalAudit(self, order);
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
                try rememberTerminalAudit(self, order);
            },
            .confirmed_absent => {
                order.state = .canceled;
                order.reservation_active = false;
                order.reservation.atoms = 0;
                try rememberTerminalAudit(self, order);
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
        var undo: MutationUndo = undefined;
        undo.init(self);
        const captured = undo.captureOrder(self, order_id);
        std.debug.assert(captured);
        self.confirmReplacementInPlace(order_id, reservation, portfolio_reduce_only, venue_reduce_only, intent_sequence, refs) catch |err| {
            undo.rollback(self);
            return err;
        };
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

    fn createOrder(self: *Oms, strategy_instance: u128, instrument: Instrument, side: Side, portfolio_reduce_only: bool, venue_reduce_only: bool, quantity: i64, price: Price, reservation: Reservation, requested_client_order_id: canonical.ClientOrderId, predecessor: u64, intent_sequence: u64, group: u64, policy: PartialExecutionPolicy) !*Order {
        if (self.recovery_only) return error.OmsRecoveryOnly;
        const live_count = self.liveOrderCount();
        if (orderCapacityReached(live_count, self.order_count)) {
            self.capacity_pressure = true;
            return error.OrderCapacityExceeded;
        }
        if (self.order_count - live_count >= max_retained_terminal_orders) {
            self.capacity_pressure = true;
            return error.TerminalCapacityExceeded;
        }
        const index = self.order_count;
        self.order_count += 1;
        var client_order_id = requested_client_order_id;
        if (client_order_id.len == 0) {
            var storage: [64]u8 = undefined;
            client_order_id = try canonical.ClientOrderId.init(try std.fmt.bufPrint(&storage, "RWN-{d}", .{self.next_order_id}));
        }
        self.orders[index] = .{ .id = self.next_order_id, .strategy_instance = strategy_instance, .instrument = instrument, .side = side, .portfolio_reduce_only = portfolio_reduce_only, .venue_reduce_only = venue_reduce_only, .quantity = quantity, .limit_price = price, .reservation = reservation, .confirmed_reservation = reservation, .confirmed_quantity = quantity, .reservation_basis_quantity = quantity, .predecessor_order_id = predecessor, .intent_sequence = intent_sequence, .group_first_sequence = group, .group_policy = policy, .client_order_id = client_order_id };
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
        const next = try self.createOrder(predecessor.strategy_instance, replacement.instrument, replacement.side, replacement.portfolio_reduce_only, replacement.venue_reduce_only, replacement.quantity, replacement.limit_price, replacement.reservation, replacement.client_order_id, predecessor.id, intent_sequence, predecessor.group_first_sequence, predecessor.group_policy);
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
        const index = self.orderIndex(id) orelse return error.UnknownOrder;
        return &self.orders[index];
    }

    fn tombstoneById(self: *const Oms, id: u64) ?Tombstone {
        for (self.tombstones[0..self.tombstone_count]) |tombstone| if (tombstone.order_id == id) return tombstone;
        return null;
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

pub fn intentFingerprint(intent: Intent, group_count: u8) [16]u8 {
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
    hash.update(std.mem.asBytes(&order.strategy_instance));
    hash.update(std.mem.asBytes(&order.instrument));
    hash.update(std.mem.asBytes(&order.intent_sequence));
    hash.update(std.mem.asBytes(&order.group_first_sequence));
    hash.update(std.mem.asBytes(&order.predecessor_order_id));
    hash.update(&.{order.client_order_id.len});
    hash.update(order.client_order_id.slice());
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
        hash.update(&report.canonical_digest);
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

test "optimization OMS late group report and replacement failures restore resident authority" {
    const state = try std.testing.allocator.create(Oms);
    defer std.testing.allocator.destroy(state);
    state.* = .{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 2 };
    group.members[0] = .{ .intent_sequence = 1, .strategy_instance = 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    group.members[1] = group.members[0];
    group.members[1].intent_sequence = 2;
    group.members[1].quantity = 0;
    try std.testing.expectError(error.InvalidOrderSpec, state.applyGroup(group));
    try std.testing.expectEqual(@as(u16, 0), state.order_count);
    try std.testing.expectEqual(@as(u16, 0), state.command_history_count);
    try std.testing.expectEqual(@as(u16, 0), state.intent_history_count);
    try std.testing.expectEqual(@as(u64, 1), state.next_order_id);
    try std.testing.expectEqual(@as(u64, 1), state.next_command_id);
    const placed = try placeSubmitted(state, 1, 2);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 2 });
    const original = state.orderById(placed.order_id).?;
    try std.testing.expectError(error.InvalidExecutionReport, state.applyReport(.{ .report_id = 2, .order_id = placed.order_id, .revision = 1, .status = .partially_filled, .cumulative_quantity = 3, .remaining_quantity = 0 }));
    try std.testing.expectEqualDeep(original, state.orderById(placed.order_id).?);
    try std.testing.expectEqual(@as(u16, 1), state.report_history_count);
    try state.applyReport(.{ .report_id = 2, .order_id = placed.order_id, .revision = 1, .status = .partially_filled, .cumulative_quantity = 1, .remaining_quantity = 1 });
    try std.testing.expectEqual(@as(u16, 2), state.report_history_count);
    state.begin();
    var amend: IntentGroup = .{ .first_intent_sequence = 2, .count = 1 };
    amend.members[0] = .{ .intent_sequence = 2, .strategy_instance = 1, .operation = .amend, .instrument = 1, .target_order_id = placed.order_id, .expected_revision = 1, .expected_cumulative_quantity = 1, .quantity = 1, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 3 }, .native_amend = false, .allow_cancel_confirm_create = true };
    try state.applyGroup(amend);
    try state.applyReport(.{ .report_id = 3, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 1, .remaining_quantity = 1 });
    const predecessor = state.orderById(placed.order_id).?;
    const command_count = state.command_history_count;
    state.next_command_id = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, state.confirmReplacement(placed.order_id, .{ .asset = 1, .atoms = 3 }, false, false, 2, .{}));
    try std.testing.expectEqualDeep(predecessor, state.orderById(placed.order_id).?);
    try std.testing.expectEqual(@as(u16, 1), state.order_count);
    try std.testing.expectEqual(command_count, state.command_history_count);
    try std.testing.expectEqual(@as(u64, 2), state.next_order_id);
    try std.testing.expectEqual(std.math.maxInt(u64), state.next_command_id);
}

test "optimization OMS dispatch rolls back cross strategy group cancellation at small and large scope" {
    const state = try std.testing.allocator.create(Oms);
    defer std.testing.allocator.destroy(state);
    for ([_]usize{ 3, 41 }) |order_count| {
        state.* = .{};
        for (0..order_count) |index| {
            state.begin();
            var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1, .policy = .cancel_remaining };
            group.members[0] = .{ .intent_sequence = 1, .strategy_instance = index + 1, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
            try state.applyGroup(group);
        }
        state.begin();
        var dispatch: DispatchBatch = .{ .count = 2 };
        dispatch.items[0] = .{ .command_id = 1, .state = .not_sent };
        dispatch.items[1] = .{ .command_id = 9999, .state = .unknown };
        try std.testing.expectError(error.UnknownCommand, state.applyDispatch(dispatch));
        for (state.orders[0..state.order_count]) |order| {
            try std.testing.expectEqual(OrderState.pending_submit, order.state);
            try std.testing.expect(order.reservation_active);
            try std.testing.expect(!order.dispatch_submitted);
        }
        try std.testing.expectEqual(@as(u8, 0), state.command_count);
        try std.testing.expectEqual(@as(u16, @intCast(order_count)), state.command_history_count);
        try std.testing.expectEqual(@as(u64, @intCast(order_count + 1)), state.next_command_id);
        try std.testing.expect(!state.recovery_only and !state.capacity_pressure);
        dispatch.count = 1;
        try state.applyDispatch(dispatch);
        for (state.orders[0..state.order_count]) |order| {
            try std.testing.expectEqual(OrderState.rejected, order.state);
            try std.testing.expect(!order.reservation_active);
        }
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
    try std.testing.expectEqual(@as(u16, 1), state.order_count);
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

test "canonical report identities do not order cumulative execution state" {
    var state = Oms{};
    var group: IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 1, .quantity = 3, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 9 } };
    try state.applyGroup(group);
    try state.applyReport(.{ .report_id = 90, .order_id = 1, .revision = 1, .status = .partially_filled, .cumulative_quantity = 1, .remaining_quantity = 2, .canonical_digest = @splat(1) });
    try state.applyReport(.{ .report_id = 10, .order_id = 1, .revision = 1, .status = .partially_filled, .cumulative_quantity = 2, .remaining_quantity = 1, .canonical_digest = @splat(2) });
    try std.testing.expectEqual(@as(i64, 2), state.orderById(1).?.cumulative_quantity);
    try std.testing.expectError(error.InvalidExecutionReport, state.applyReport(.{ .report_id = 11, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 1, .remaining_quantity = 0, .canonical_digest = @splat(6) }));
    try std.testing.expectError(error.InvalidExecutionReport, state.applyReport(.{ .report_id = 12, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 1, .remaining_quantity = 2, .canonical_digest = @splat(7) }));
    try std.testing.expectEqual(@as(i64, 2), state.orderById(1).?.cumulative_quantity);
    const terminal: ExecutionReport = .{ .report_id = 5, .order_id = 1, .revision = 1, .status = .filled, .cumulative_quantity = 3, .remaining_quantity = 0, .canonical_digest = @splat(3) };
    try state.applyReport(terminal);
    try state.applyReport(.{ .report_id = 100, .order_id = 1, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 3, .canonical_digest = @splat(4) });
    try state.applyReport(terminal);
    try std.testing.expectEqual(@as(i64, 3), state.orderById(1).?.cumulative_quantity);
    try std.testing.expectEqual(OrderState.filled, state.orderById(1).?.state);
    var conflicting = terminal;
    conflicting.canonical_digest = @splat(5);
    try std.testing.expectError(error.ConflictingReportIdentity, state.applyReport(conflicting));
}

test "canonical late accepted report retains the historical quantity after decreasing amend" {
    var state = Oms{};
    const placed = try placeSubmitted(&state, 1, 10);
    try state.applyReport(.{ .report_id = 90, .order_id = placed.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10, .canonical_digest = @splat(1) });
    state.begin();
    var group: IntentGroup = .{ .first_intent_sequence = 2, .count = 1 };
    group.members[0] = .{ .intent_sequence = 2, .strategy_instance = 1, .operation = .amend, .instrument = 1, .target_order_id = placed.order_id, .expected_revision = 1, .quantity = 5, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 2 }, .reservation = .{ .asset = 1, .atoms = 5 } };
    try state.applyGroup(group);
    try state.applyReport(.{ .report_id = 10, .order_id = placed.order_id, .revision = 2, .status = .amended, .cumulative_quantity = 0, .remaining_quantity = 5, .canonical_digest = @splat(2) });
    try state.applyReport(.{ .report_id = 100, .order_id = placed.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 10, .canonical_digest = @splat(3) });
    try std.testing.expectEqual(@as(i64, 5), state.orderById(placed.order_id).?.quantity);
    try std.testing.expectEqual(@as(u32, 2), state.orderById(placed.order_id).?.revision);
    try std.testing.expectEqual(@as(u64, 10), state.orderById(placed.order_id).?.last_report_id);
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

test "explicit terminal archive preserves unrelated active orders and monotonic identities" {
    var state = Oms{};
    const first = try placeSubmitted(&state, 1, 2);
    try state.applyReport(.{ .report_id = 1, .order_id = first.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = first.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    for (2..11) |sequence| _ = try placeSubmitted(&state, @intCast(sequence), 2);
    try qualifyTestTerminal(&state, first.order_id);
    const qualified = try state.prepareOrderArchive(first.order_id, 0, 9);
    try state.commitOrderArchive(qualified);
    try std.testing.expect(state.orderById(first.order_id) == null);
    try std.testing.expect(state.orderById(2) != null);
    try std.testing.expectEqual(@as(u16, 9), state.order_count);
    const next = try placeSubmitted(&state, 11, 2);
    try std.testing.expectEqual(@as(u64, 11), next.order_id);
    try std.testing.expectEqual(@as(u16, 10), state.order_count);
    try std.testing.expectEqual(@as(u16, 0), state.tombstone_count);
    try std.testing.expectError(error.ArchivedFactOutsideRetention, state.applyReport(.{ .report_id = 1, .order_id = first.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 }));
}

test "order lookup and report updates preserve identity across an archived middle slot" {
    var state = Oms{};
    const first = try placeSubmitted(&state, 1, 2);
    const middle = try placeSubmitted(&state, 2, 2);
    const last = try placeSubmitted(&state, 3, 2);
    try state.applyReport(.{ .report_id = 1, .order_id = middle.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = middle.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try qualifyTestTerminal(&state, middle.order_id);
    try state.commitOrderArchive(try state.prepareOrderArchive(middle.order_id, 0, 9));
    try std.testing.expectEqual(first.order_id, state.orderById(first.order_id).?.id);
    try std.testing.expectEqual(last.order_id, state.orderById(last.order_id).?.id);
    try std.testing.expect(state.orderById(middle.order_id) == null);
    try std.testing.expect(state.orderById(0) == null);
    try std.testing.expect(state.orderById(std.math.maxInt(u64)) == null);
    try state.applyReport(.{ .report_id = 3, .order_id = last.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try std.testing.expectEqual(OrderState.live, state.orderById(last.order_id).?.state);
    try std.testing.expectEqual(OrderState.pending_submit, state.orderById(first.order_id).?.state);
}

test "group archive retains member identities until all active references close" {
    var state = Oms{};
    var group: IntentGroup = .{ .first_intent_sequence = 7, .count = 2 };
    for (group.members[0..2], 0..) |*intent, index| intent.* = .{
        .intent_sequence = 7 + @as(u64, @intCast(index)),
        .strategy_instance = 9,
        .operation = .place,
        .instrument = 1,
        .quantity = 1,
        .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 },
        .reservation = .{ .asset = 1, .atoms = 3 },
    };
    try state.applyGroup(group);
    var dispatch: DispatchBatch = .{ .count = 2 };
    for (state.emitted()[0..2], 0..) |command, index| dispatch.items[index] = .{ .command_id = command.command_id, .state = .submitted };
    try state.applyDispatch(dispatch);
    try state.applyReport(.{ .report_id = 80, .order_id = 2, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 1 });
    try state.applyReconciliation(.{ .reconciliation_id = 81, .order_id = 2, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 1, .terminal_state = .canceled });
    try qualifyTestTerminal(&state, 2);
    try std.testing.expectError(error.OrderArchiveReferenced, state.prepareOrderArchive(2, 0, 9));
    try state.applyReport(.{ .report_id = 82, .order_id = 1, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 1 });
    try state.applyReconciliation(.{ .reconciliation_id = 83, .order_id = 1, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 1, .terminal_state = .canceled });
    const qualified = try state.prepareOrderArchive(2, 0, 9);
    try std.testing.expectEqual(@as(u64, 8), qualified.order.intent_sequence);
    try std.testing.expectEqual(@as(u64, 7), qualified.order.group_first_sequence);
    try state.commitOrderArchive(qualified);
    try std.testing.expect(state.orderById(1) != null);
    try std.testing.expectEqual(@as(u16, 2), state.intent_history_count);
    try state.applyGroup(group);
    try std.testing.expectEqual(@as(u16, 1), state.order_count);
    group.members[1].quantity = 2;
    try std.testing.expectError(error.ConflictingIntentIdentity, state.applyGroup(group));
    try qualifyTestTerminal(&state, 1);
    try state.commitOrderArchive(try state.prepareOrderArchive(1, 0, 9));
    try std.testing.expectEqual(@as(u16, 0), state.intent_history_count);
}

test "explicit archive frees repeated lifecycles without spending tombstone capacity" {
    var state = Oms{};
    for (1..36) |raw_sequence| {
        const sequence: u64 = @intCast(raw_sequence);
        const placed = try placeSubmitted(&state, sequence, 1);
        try state.applyReport(.{ .report_id = sequence, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 1 });
        try state.applyReconciliation(.{ .reconciliation_id = 100 + sequence, .order_id = placed.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 1, .terminal_state = .canceled });
        try qualifyTestTerminal(&state, placed.order_id);
        try state.commitOrderArchive(try state.prepareOrderArchive(placed.order_id, 0, 9));
        try std.testing.expectEqual(@as(u16, 0), state.order_count);
        try std.testing.expectEqual(@as(u16, 0), state.tombstone_count);
        try std.testing.expect(!state.recovery_only);
    }
    for (1..11) |raw_sequence| _ = try placeSubmitted(&state, 100 + @as(u64, @intCast(raw_sequence)), 1);
    // Inject an existing pressure latch; this functional case does not fill the production capacity.
    state.capacity_pressure = true;
    const next_order = state.next_order_id;
    const next_command = state.next_command_id;
    try std.testing.expectError(error.UncertainOrderBlocksSend, placeSubmitted(&state, 1000000, 1));
    try std.testing.expect(state.capacity_pressure);
    try std.testing.expectEqual(@as(u16, 10), state.order_count);
    try std.testing.expectEqual(next_order, state.next_order_id);
    try std.testing.expectEqual(next_command, state.next_command_id);
}

test "canceled orders without archive window stay hot under an injected pressure latch" {
    var state = Oms{};
    var sequence: u64 = 1;
    while (sequence <= 10) : (sequence += 1) {
        const placed = try placeSubmitted(&state, sequence, 2);
        try state.applyReport(.{ .report_id = sequence, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
        try std.testing.expect(!state.orderById(placed.order_id).?.archive_window_closed);
    }
    // Inject an existing pressure latch without fabricating a full terminal population.
    state.capacity_pressure = true;
    const next_order = state.next_order_id;
    const next_command = state.next_command_id;
    try std.testing.expectError(error.UncertainOrderBlocksSend, placeSubmitted(&state, sequence, 2));
    try std.testing.expect(state.capacity_pressure);
    try std.testing.expectEqual(@as(u16, 10), state.order_count);
    try std.testing.expectEqual(next_order, state.next_order_id);
    try std.testing.expectEqual(next_command, state.next_command_id);
    try std.testing.expectEqual(@as(u16, 0), state.tombstone_count);
}

test "live unknown and pending_cancel orders never compact" {
    var live = Oms{};
    var sequence: u64 = 1;
    while (sequence <= 8) : (sequence += 1) {
        _ = try placeSubmitted(&live, sequence, 2);
    }
    // Fault injection closes new risk while the real live population remains small.
    live.capacity_pressure = true;
    const next_order = live.next_order_id;
    const next_command = live.next_command_id;
    try std.testing.expectError(error.UncertainOrderBlocksSend, placeSubmitted(&live, sequence, 2));
    try std.testing.expect(live.capacity_pressure);
    try std.testing.expectEqual(@as(u16, 8), live.liveOrderCount());
    try std.testing.expectEqual(next_order, live.next_order_id);
    try std.testing.expectEqual(next_command, live.next_command_id);
    try std.testing.expectEqual(@as(u16, 0), live.tombstone_count);
    for (live.orders[0..live.order_count]) |order| try std.testing.expectEqual(OrderState.pending_submit, order.state);

    var unknown = Oms{};
    const unknown_placed = try placeSubmitted(&unknown, 1, 2);
    var unknown_dispatch: DispatchBatch = .{ .count = 1 };
    unknown_dispatch.items[0] = .{ .command_id = unknown_placed.command_id, .state = .unknown };
    try unknown.applyDispatch(unknown_dispatch);
    try std.testing.expectError(error.UncertainOrderBlocksSend, placeSubmitted(&unknown, 2, 2));
    try std.testing.expectEqual(OrderState.unknown, unknown.orderById(unknown_placed.order_id).?.state);
    try std.testing.expectEqual(@as(u16, 1), unknown.order_count);
    try std.testing.expectEqual(@as(u16, 0), unknown.tombstone_count);

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
    try std.testing.expectEqual(@as(u16, 1), pending.order_count);
    try std.testing.expectEqual(@as(u16, 0), pending.tombstone_count);
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
    try std.testing.expect(!state.orderById(placed.order_id).?.archive_window_closed);
    try std.testing.expect(state.orderById(placed.order_id).?.replacement != null);
    try state.confirmReplacement(placed.order_id, .{ .asset = 1, .atoms = 6 }, false, false, 2, .{});
    const successor = state.orderById(2) orelse return error.MissingReplacement;
    try std.testing.expectEqual(placed.order_id, successor.predecessor_order_id);
    try std.testing.expectEqual(@as(u64, 2), successor.intent_sequence);
    var archived = state;
    try archived.applyReport(.{ .report_id = 3, .order_id = successor.id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try archived.applyReconciliation(.{ .reconciliation_id = 11, .order_id = successor.id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try qualifyTestTerminal(&archived, placed.order_id);
    try qualifyTestTerminal(&archived, successor.id);
    try std.testing.expectError(error.OrderArchiveReferenced, archived.prepareOrderArchive(placed.order_id, 0, 9));
    const successor_qualification = try archived.prepareOrderArchive(successor.id, 0, 9);
    try std.testing.expectEqual(placed.order_id, successor_qualification.order.predecessor_order_id);
    try std.testing.expectEqual(@as(u64, 2), successor_qualification.order.intent_sequence);
    try archived.commitOrderArchive(successor_qualification);
    try std.testing.expect(archived.orderById(placed.order_id) != null);
    try archived.commitOrderArchive(try archived.prepareOrderArchive(placed.order_id, 0, 9));
    try std.testing.expectEqual(@as(u16, 0), archived.order_count);
    var sequence: u64 = 3;
    while (sequence <= 10) : (sequence += 1) _ = try placeSubmitted(&state, sequence, 2);
    // Fault injection cannot authorize eviction of a still-referenced predecessor.
    state.capacity_pressure = true;
    const next_order = state.next_order_id;
    const next_command = state.next_command_id;
    try std.testing.expectError(error.UncertainOrderBlocksSend, placeSubmitted(&state, sequence, 2));
    try std.testing.expectEqual(next_order, state.next_order_id);
    try std.testing.expectEqual(next_command, state.next_command_id);
    try std.testing.expect(state.orderById(placed.order_id) != null);
    try std.testing.expectEqual(@as(u16, 0), state.tombstone_count);
}

test "archive commit refuses mutated intent evidence without evicting hot state" {
    var state = Oms{};
    const placed = try placeSubmitted(&state, 1, 2);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = placed.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try qualifyTestTerminal(&state, placed.order_id);
    const qualified = try state.prepareOrderArchive(placed.order_id, 0, 9);
    state.intent_history[0].fingerprint[0] ^= 1;
    try std.testing.expectError(error.StaleOrderArchiveQualification, state.commitOrderArchive(qualified));
    try std.testing.expectEqual(@as(u16, 1), state.order_count);
    try std.testing.expectEqual(@as(u16, 0), state.tombstone_count);
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

fn rememberTerminalAudit(self: *Oms, order: *Order) !void {
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
}

fn rememberReport(order: *Order, report: ExecutionReport) void {
    order.last_report_id = report.report_id;
    order.last_report_revision = report.revision;
    order.last_report_status = report.status;
    order.last_report_cumulative_quantity = report.cumulative_quantity;
    order.last_report_remaining_quantity = report.remaining_quantity;
}

test "OMS terminal archive requires complete coverage and applied fills" {
    var state = Oms{};
    const placed = try placeSubmitted(&state, 1, 2);
    try state.noteOrderCreated(placed.order_id, 100);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .filled, .cumulative_quantity = 2, .remaining_quantity = 0 });
    try state.noteTerminalObserved(placed.order_id, 200);
    try state.noteTerminalObserved(placed.order_id, 300);
    try state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = placed.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 2, .remaining_quantity = 0, .terminal_state = .filled });
    try std.testing.expectError(error.OrderArchiveNotQualified, state.prepareOrderArchive(placed.order_id, 2, 9));
    const evidence = testTerminalArchiveEvidence(placed.order_id);
    try state.retainTerminalArchiveCoverage(placed.order_id, evidence);
    try std.testing.expectError(error.OrderArchiveNotQualified, state.prepareOrderArchive(placed.order_id, 0, 9));
    const qualified = try state.prepareOrderArchive(placed.order_id, 2, 9);
    try std.testing.expectEqual(@as(u64, 200), qualified.order.terminal_observed_at_utc_ns);
    try std.testing.expectEqual(@as(i64, 2), qualified.applied_fill_quantity);
    try std.testing.expectEqual(@as(i64, 2), qualified.order.cumulative_quantity);
    try std.testing.expectEqual(@as(u16, 1), state.order_count);
}

fn testTerminalArchiveEvidence(order_id: u64) canonical.ReconciliationEvidence {
    return .{
        .scope = .{ .exchange_account = 9, .instrument = 1, .order = order_id, .revision = 1, .from_utc_ns = 100, .through_utc_ns = 30_000_000_200 },
        .observed_at_utc_ns = 30_000_000_200,
        .source = .{ .stream = 1, .sequence = 1, .digest = @splat(1) },
        .terminal_archive = .{ .visibility_deadline_utc_ns = 30_000_000_200, .order_history_complete = true, .terminal_history_complete = true, .fills_complete = true, .economics_complete = true },
    };
}

fn safeTerminal(order: Order) bool {
    return switch (order.state) {
        .filled, .canceled, .rejected => true,
        else => false,
    };
}

fn retainedTerminal(order: *const Order) bool {
    const terminal = switch (order.state) {
        .filled, .canceled, .rejected => true,
        else => false,
    };
    return terminal and !order.reservation_active and order.reservation.atoms == 0 and
        order.pending_reservation == null and order.pending_previous_spec == null and
        order.pending_basis_quantity == 0 and order.replacement == null;
}

fn validateTerminalArchiveCoverage(order: Order, evidence: canonical.ReconciliationEvidence, exchange_account: canonical.ExchangeAccountIdentity) !void {
    const coverage = evidence.terminal_archive orelse return error.OrderArchiveNotQualified;
    // shortcut: 30 seconds is the frozen synthetic lateness bound; qualify real Venue guarantees separately.
    const deadline = std.math.add(u64, order.terminal_observed_at_utc_ns, 30 * std.time.ns_per_s) catch return error.OrderArchiveNotQualified;
    if (!safeTerminal(order) or order.created_at_utc_ns == 0 or order.terminal_observed_at_utc_ns == 0 or
        exchange_account == 0 or evidence.scope.exchange_account != exchange_account or
        evidence.scope.order != order.id or evidence.scope.instrument != order.instrument or evidence.scope.revision != order.revision or
        evidence.scope.from_utc_ns > order.created_at_utc_ns or evidence.scope.through_utc_ns < coverage.visibility_deadline_utc_ns or
        coverage.visibility_deadline_utc_ns < deadline or evidence.observed_at_utc_ns < evidence.scope.through_utc_ns or
        evidence.source.stream == 0 or evidence.source.sequence == 0 or std.mem.eql(u8, &evidence.source.digest, &@as([32]u8, @splat(0))) or
        !coverage.order_history_complete or !coverage.terminal_history_complete or !coverage.fills_complete or !coverage.economics_complete)
        return error.OrderArchiveNotQualified;
}

fn archiveHashValue(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    const T = @TypeOf(value);
    if (T == canonical.ClientOrderId) {
        archiveHashValue(hash, value.len);
        hash.update(value.slice());
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => inline for (std.meta.fields(T)) |field| archiveHashValue(hash, @field(value, field.name)),
        .optional => {
            hash.update(&.{@intFromBool(value != null)});
            if (value) |present| archiveHashValue(hash, present);
        },
        .@"enum" => archiveHashValue(hash, @intFromEnum(value)),
        .bool => hash.update(&.{@intFromBool(value)}),
        .int => {
            var bytes: [@sizeOf(T)]u8 = undefined;
            const Encoded = @Int(@typeInfo(T).int.signedness, @sizeOf(T) * 8);
            std.mem.writeInt(Encoded, &bytes, value, .little);
            hash.update(&bytes);
        },
        .array => for (value) |element| archiveHashValue(hash, element),
        else => @compileError("unsupported archive field"),
    }
}

test "OMS explicit archive commit frees hot evidence and rejects a stale qualification" {
    var state = Oms{};
    const placed = try placeSubmitted(&state, 1, 2);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = placed.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try state.noteOrderCreated(placed.order_id, 100);
    try state.noteTerminalObserved(placed.order_id, 200);
    try state.retainTerminalArchiveCoverage(placed.order_id, testTerminalArchiveEvidence(placed.order_id));
    const qualified = try state.prepareOrderArchive(placed.order_id, 0, 9);
    var stale = qualified;
    stale.order.intent_sequence += 1;
    try std.testing.expectError(error.StaleOrderArchiveQualification, state.commitOrderArchive(stale));
    try std.testing.expectEqual(@as(u16, 1), state.order_count);
    try state.commitOrderArchive(qualified);
    try std.testing.expectEqual(@as(u16, 0), state.order_count);
    try std.testing.expectEqual(@as(u16, 0), state.command_history_count);
    try std.testing.expectEqual(@as(u16, 0), state.report_history_count);
    try std.testing.expectEqual(@as(u16, 0), state.reconciliation_history_count);
    try std.testing.expectEqual(@as(u16, 0), state.intent_history_count);
    try std.testing.expectEqual(@as(u16, 0), state.tombstone_count);
    const next = try placeSubmitted(&state, 2, 2);
    try std.testing.expectEqual(@as(u64, 2), next.order_id);
    try std.testing.expectEqual(@as(u64, 2), next.command_id);
}

fn removeArchiveEntry(comptime T: type, entries: []T, count: anytype, index: usize) void {
    var move = index;
    while (move + 1 < count.*) : (move += 1) entries[move] = entries[move + 1];
    count.* -= 1;
}

test "OMS functional admission never substitutes implicit compaction for durable archive commit" {
    var state = Oms{};
    const first = try placeSubmitted(&state, 1, 2);
    try state.applyReport(.{ .report_id = 1, .order_id = first.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = first.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try state.noteOrderCreated(first.order_id, 100);
    try state.noteTerminalObserved(first.order_id, 200);
    try state.retainTerminalArchiveCoverage(first.order_id, testTerminalArchiveEvidence(first.order_id));
    state.orders[0].archive_window_closed = true;
    for (2..11) |sequence| _ = try placeSubmitted(&state, @intCast(sequence), 2);
    try std.testing.expectEqual(@as(u16, 10), state.order_count);
    try std.testing.expect(state.orderById(first.order_id) != null);
    // Fault injection exercises closed admission without asserting a full-capacity population.
    state.capacity_pressure = true;
    const next_order = state.next_order_id;
    const next_command = state.next_command_id;
    try std.testing.expectError(error.UncertainOrderBlocksSend, placeSubmitted(&state, 11, 2));
    try std.testing.expectEqual(next_order, state.next_order_id);
    try std.testing.expectEqual(next_command, state.next_command_id);
    try std.testing.expect(state.orderById(first.order_id) != null);
    try std.testing.expectEqual(@as(u16, 0), state.tombstone_count);
}

fn qualifyTestTerminal(state: *Oms, order_id: u64) !void {
    try state.noteOrderCreated(order_id, 100);
    try state.noteTerminalObserved(order_id, 200);
    try state.retainTerminalArchiveCoverage(order_id, testTerminalArchiveEvidence(order_id));
}

test "OMS archive coverage rejects incomplete or early queries without replacing valid evidence" {
    var state = Oms{};
    const placed = try placeSubmitted(&state, 1, 2);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = placed.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try qualifyTestTerminal(&state, placed.order_id);
    const original = (try state.prepareOrderArchive(placed.order_id, 0, 9)).digest();
    for (0..12) |case| {
        var evidence = testTerminalArchiveEvidence(placed.order_id);
        switch (case) {
            0 => evidence.terminal_archive.?.order_history_complete = false,
            1 => evidence.terminal_archive.?.terminal_history_complete = false,
            2 => evidence.terminal_archive.?.fills_complete = false,
            3 => evidence.terminal_archive.?.economics_complete = false,
            4 => evidence.terminal_archive.?.visibility_deadline_utc_ns -= 1,
            5 => evidence.scope.from_utc_ns += 1,
            6 => evidence.scope.through_utc_ns -= 1,
            7 => evidence.observed_at_utc_ns -= 1,
            8 => evidence.scope.order += 1,
            9 => evidence.scope.revision += 1,
            10 => evidence.scope.instrument += 1,
            11 => evidence.source.digest = @splat(0),
            else => unreachable,
        }
        try std.testing.expectError(error.OrderArchiveNotQualified, state.retainTerminalArchiveCoverage(placed.order_id, evidence));
        try std.testing.expectEqualSlices(u8, &original, &(try state.prepareOrderArchive(placed.order_id, 0, 9)).digest());
    }
    try std.testing.expectError(error.OrderArchiveNotQualified, state.prepareOrderArchive(placed.order_id, 0, 8));
}

test "OMS terminal conflict blocks archive qualification and preserves hot evidence" {
    var state = Oms{};
    const placed = try placeSubmitted(&state, 1, 2);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = placed.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try qualifyTestTerminal(&state, placed.order_id);
    try std.testing.expectError(error.TerminalFactConflict, state.applyReconciliation(.{ .reconciliation_id = 3, .order_id = placed.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 1, .remaining_quantity = 1, .terminal_state = .canceled }));
    try std.testing.expectError(error.OrderArchiveNotQualified, state.prepareOrderArchive(placed.order_id, 0, 9));
    try std.testing.expectEqual(@as(u16, 1), state.order_count);
    try std.testing.expectEqual(@as(i64, 0), state.orderById(placed.order_id).?.cumulative_quantity);
}

test "OMS later complete terminal reconciliation preserves first terminal observation" {
    var state = Oms{};
    const placed = try placeSubmitted(&state, 1, 2);
    try state.noteOrderCreated(placed.order_id, 100);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.noteTerminalObserved(placed.order_id, 200);
    try state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = placed.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try state.applyReconciliation(.{ .reconciliation_id = 3, .order_id = placed.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try state.noteTerminalObserved(placed.order_id, 30_000_000_200);
    try state.retainTerminalArchiveCoverage(placed.order_id, testTerminalArchiveEvidence(placed.order_id));
    const qualified = try state.prepareOrderArchive(placed.order_id, 0, 9);
    try std.testing.expectEqual(@as(u64, 3), qualified.last_reconciliation.?.reconciliation_id);
    try std.testing.expectEqual(@as(u64, 200), qualified.order.terminal_observed_at_utc_ns);
}

test "OMS archive qualification rejects every unfinished reservation branch" {
    var state = Oms{};
    const placed = try placeSubmitted(&state, 1, 2);
    try state.applyReport(.{ .report_id = 1, .order_id = placed.order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try state.applyReconciliation(.{ .reconciliation_id = 2, .order_id = placed.order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try qualifyTestTerminal(&state, placed.order_id);
    const closed = state.orders[0];
    for (0..6) |case| {
        state.orders[0] = closed;
        switch (case) {
            0 => state.orders[0].reservation_active = true,
            1 => state.orders[0].reservation.atoms = 1,
            2 => state.orders[0].pending_reservation = .{ .asset = 1, .atoms = 1 },
            3 => state.orders[0].pending_basis_quantity = 1,
            4 => state.orders[0].state = .unknown,
            5 => state.orders[0].state = .pending_cancel,
            else => unreachable,
        }
        try std.testing.expectError(error.OrderArchiveNotQualified, state.prepareOrderArchive(placed.order_id, 0, 9));
        try std.testing.expectEqual(@as(u16, 1), state.order_count);
    }
}
