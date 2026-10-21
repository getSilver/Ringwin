const std = @import("std");
const oms = @import("../../../execution/oms.zig");

test "OMS capacity exact offline layout" {
    std.debug.print("OMS capacity bytes: Oms={d}, Order={d}x{d}, Command={d}x{d}, Report={d}x{d}, Reconciliation={d}x{d}, SeenIntent={d}x{d}, Qualification={d}, align={d}\n", .{
        @sizeOf(oms.Oms),        @sizeOf(oms.Order),                oms.max_orders,
        @sizeOf(oms.Command),    oms.max_command_history,           @sizeOf(oms.ExecutionReport),
        oms.max_fact_history,    @sizeOf(oms.ReconciliationResult), oms.max_fact_history,
        @sizeOf(oms.SeenIntent), oms.max_intent_history,            @sizeOf(oms.OrderArchiveQualification),
        @alignOf(oms.Oms),
    });
    try std.testing.expectEqual(u16, @FieldType(oms.Oms, "order_count"));
    try std.testing.expectEqual(u16, @FieldType(oms.Oms, "command_history_count"));
    try std.testing.expectEqual(u16, @FieldType(oms.Oms, "report_history_count"));
    try std.testing.expectEqual(u16, @FieldType(oms.Oms, "reconciliation_history_count"));
    try std.testing.expectEqual(u16, @FieldType(oms.Oms, "intent_history_count"));
    try std.testing.expectEqual(u8, @FieldType(oms.Oms, "command_count"));
}

const Cycle = struct {
    state: *oms.Oms,
    sequence: u64 = 1,
    fact: u64 = 1,

    fn place(self: *Cycle) !u64 {
        self.state.begin();
        var group: oms.IntentGroup = .{ .first_intent_sequence = self.sequence, .count = 1 };
        group.members[0] = .{ .intent_sequence = self.sequence, .strategy_instance = 7, .operation = .place, .instrument = 1, .quantity = 2, .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
        self.sequence += 1;
        try self.state.applyGroup(group);
        const command = self.state.emitted()[0];
        var dispatch: oms.DispatchBatch = .{ .count = 1 };
        dispatch.items[0] = .{ .command_id = command.command_id, .state = .submitted };
        try self.state.applyDispatch(dispatch);
        try self.state.applyReport(.{ .report_id = self.fact, .order_id = command.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 2 });
        self.fact += 1;
        try self.state.noteOrderCreated(command.order_id, 100);
        return command.order_id;
    }

    fn terminal(self: *Cycle, order_id: u64) !void {
        const command_id = try self.cancel(order_id);
        var dispatch: oms.DispatchBatch = .{ .count = 1 };
        dispatch.items[0] = .{ .command_id = command_id, .state = .submitted };
        try self.state.applyDispatch(dispatch);
        try self.state.applyReport(.{ .report_id = self.fact, .order_id = order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
        self.fact += 1;
        try self.state.applyReconciliation(.{ .reconciliation_id = self.fact, .order_id = order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
        self.fact += 1;
        try self.state.noteTerminalObserved(order_id, 200);
        try self.state.retainTerminalArchiveCoverage(order_id, .{
            .scope = .{ .exchange_account = 9, .instrument = 1, .order = order_id, .revision = 1, .from_utc_ns = 100, .through_utc_ns = 30_000_000_200 },
            .observed_at_utc_ns = 30_000_000_200,
            .source = .{ .stream = 1, .sequence = self.fact, .digest = @splat(1) },
            .terminal_archive = .{ .visibility_deadline_utc_ns = 30_000_000_200, .order_history_complete = true, .terminal_history_complete = true, .fills_complete = true, .economics_complete = true },
        });
    }

    fn cancel(self: *Cycle, order_id: u64) !u64 {
        self.state.begin();
        var group: oms.IntentGroup = .{ .first_intent_sequence = self.sequence, .count = 1 };
        group.members[0] = .{ .intent_sequence = self.sequence, .strategy_instance = 7, .operation = .cancel, .instrument = 1, .target_order_id = order_id, .expected_revision = 1, .expected_cumulative_quantity = 0 };
        self.sequence += 1;
        try self.state.applyGroup(group);
        return self.state.emitted()[0].command_id;
    }

    fn archive(self: *Cycle, order_id: u64) !void {
        try self.state.commitOrderArchive(try self.state.prepareOrderArchive(order_id, 0, 9));
    }
};

test "OMS functional archive four shards retain 25 live and 25 terminal then complete ten rounds" {
    const states = try std.testing.allocator.alloc(oms.Oms, 4);
    defer std.testing.allocator.free(states);
    var cycles: [4]Cycle = undefined;
    for (states, &cycles) |*state, *cycle| {
        state.* = .{};
        cycle.* = .{ .state = state };
        for (0..25) |_| try cycle.terminal(try cycle.place());
        for (0..25) |_| _ = try cycle.place();
    }
    // Assert all four simultaneously retain both populations before reclaiming any.
    for (states, 0..) |*state, shard_index| {
        try std.testing.expectEqual(@as(u16, 25), state.liveOrderCount());
        try std.testing.expectEqual(@as(u16, 25), state.retainedTerminalOrderCount());
        try std.testing.expectEqual(@as(u16, 50), state.order_count);
        std.debug.print("OMS functional shard {d}: live={d}, retained={d}, completed=25\n", .{ shard_index, state.liveOrderCount(), state.retainedTerminalOrderCount() });
    }
    for (&cycles) |*cycle| for (1..26) |order_id| try cycle.archive(order_id);
    var cumulative: usize = 25;
    for (0..10) |round| {
        for (states, &cycles) |*state, *cycle| {
            var retired: [5]u64 = undefined;
            for (&retired, 0..) |*id, index| id.* = state.orders[index].id;
            for (retired) |id| try cycle.terminal(id);
            try std.testing.expectEqual(@as(u16, 20), state.liveOrderCount());
            try std.testing.expectEqual(@as(u16, 5), state.retainedTerminalOrderCount());
            for (retired) |id| try cycle.archive(id);
            for (retired) |_| _ = try cycle.place();
        }
        cumulative += 5;
        for (states, 0..) |*state, shard_index| {
            try std.testing.expectEqual(@as(u16, 25), state.liveOrderCount());
            try std.testing.expectEqual(@as(u16, 0), state.retainedTerminalOrderCount());
            try std.testing.expect(!state.capacity_pressure and !state.recovery_only);
            std.debug.print("OMS functional shard {d}: round={d}, live={d}, retained={d}, completed={d}\n", .{ shard_index, round + 1, state.liveOrderCount(), state.retainedTerminalOrderCount(), cumulative });
        }
    }
    try std.testing.expectEqual(@as(usize, 75), cumulative);
    for (states) |*state| try std.testing.expectEqual(@as(u64, 101), state.next_order_id);
}

test "OMS independent capacity membership collision keeps digest and unrelated live identity" {
    const state = try std.testing.allocator.create(oms.Oms);
    defer std.testing.allocator.destroy(state);
    state.* = .{};
    var cycle: Cycle = .{ .state = state };
    const terminal = try cycle.place();
    try cycle.terminal(terminal);
    const original = try state.prepareOrderArchive(terminal, 0, 9);
    // This valid new stable sequence intentionally shares the filter bit of 1.
    cycle.sequence = 1 + 16384;
    const unrelated = try cycle.place();
    const with_collision = try state.prepareOrderArchive(terminal, 0, 9);
    try std.testing.expectEqualSlices(u8, &original.digest(), &with_collision.digest());
    try state.commitOrderArchive(with_collision);
    try std.testing.expect(state.orderById(terminal) == null);
    try std.testing.expect(state.orderById(unrelated) != null);
    try std.testing.expectEqual(@as(u16, 1), state.intent_history_count);
    try std.testing.expectEqual(@as(u64, 16385), state.intent_history[0].intent_sequence);
}

test "OMS functional Unknown and PendingCancel remain pinned and reject new orders without identity reuse" {
    const state = try std.testing.allocator.create(oms.Oms);
    defer std.testing.allocator.destroy(state);
    state.* = .{};
    var cycle: Cycle = .{ .state = state };
    for (0..8) |_| _ = try cycle.place();
    for (1..5) |id| {
        var batch: oms.DispatchBatch = .{ .count = 1 };
        batch.items[0] = .{ .command_id = id, .state = .unknown };
        try state.applyDispatch(batch);
    }
    for (5..9) |id| _ = try cycle.cancel(id);
    const next_order = state.next_order_id;
    const next_command = state.next_command_id;
    try std.testing.expectError(error.UncertainOrderBlocksSend, cycle.place());
    try std.testing.expect(!state.capacity_pressure and !state.recovery_only);
    try std.testing.expectEqual(next_order, state.next_order_id);
    try std.testing.expectEqual(next_command, state.next_command_id);
    try std.testing.expectEqual(@as(u16, 8), state.liveOrderCount());
    try std.testing.expectEqual(@as(u16, 0), state.retainedTerminalOrderCount());
    for (1..5) |id| try std.testing.expectEqual(oms.OrderState.unknown, state.orderById(id).?.state);
    for (5..9) |id| try std.testing.expectEqual(oms.OrderState.pending_cancel, state.orderById(id).?.state);
    try std.testing.expectError(error.OrderArchiveNotQualified, state.prepareOrderArchive(1, 0, 9));
    try std.testing.expectError(error.OrderArchiveNotQualified, state.prepareOrderArchive(5, 0, 9));
}

test "OMS functional latched pressure permits protective cancel and archival without clearing safety" {
    const state = try std.testing.allocator.create(oms.Oms);
    defer std.testing.allocator.destroy(state);
    state.* = .{};
    var cycle: Cycle = .{ .state = state };
    const first_live = try cycle.place();
    const second_live = try cycle.place();
    const retained = try cycle.place();
    try cycle.terminal(retained);
    try std.testing.expectEqual(@as(u16, 1), state.retainedTerminalOrderCount());
    try std.testing.expect(!state.capacity_pressure);
    // Inject an existing pressure latch without constructing a full-capacity population.
    state.capacity_pressure = true;
    const next_order_before_pressure = state.next_order_id;
    const next_command_before_pressure = state.next_command_id;
    try std.testing.expectError(error.UncertainOrderBlocksSend, cycle.place());
    try std.testing.expectEqual(next_order_before_pressure, state.next_order_id);
    try std.testing.expectEqual(next_command_before_pressure, state.next_command_id);
    try std.testing.expect(state.capacity_pressure and !state.recovery_only);
    try cycle.terminal(first_live);
    try std.testing.expect(state.capacity_pressure and !state.recovery_only);
    try cycle.terminal(second_live);
    try std.testing.expectEqual(@as(u16, 3), state.retainedTerminalOrderCount());
    try std.testing.expectEqual(@as(u16, 0), state.liveOrderCount());
    try std.testing.expectEqual(oms.OrderState.canceled, state.orderById(first_live).?.state);
    try std.testing.expectEqual(oms.OrderState.canceled, state.orderById(second_live).?.state);
    const rejected_order = state.next_order_id;
    try std.testing.expectError(error.UncertainOrderBlocksSend, cycle.place());
    try std.testing.expectEqual(rejected_order, state.next_order_id);
    try cycle.archive(first_live);
    try cycle.archive(second_live);
    try std.testing.expectEqual(@as(u16, 1), state.retainedTerminalOrderCount());
    // Reclaiming capacity is not authorization to clear any safety latch.
    try std.testing.expect(state.capacity_pressure);
    state.recovery_only = true;
    try std.testing.expectError(error.OrderArchiveNotQualified, state.prepareOrderArchive(retained, 0, 9));
}
