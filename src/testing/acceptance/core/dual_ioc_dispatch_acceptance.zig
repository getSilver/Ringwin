//! Offline execution faults at the committed Owner / Gateway / VenueAdapter seams.
const std = @import("std");
const trading = @import("../../../trading/trading_shard.zig");
const canonical = trading.canonical;
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const venue = @import("../../../execution/venue_adapter.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const accounts = @import("multi_account_authority_acceptance.zig");
const FillConsumer = @import("../../support/execution_fact_consumer.zig").FillConsumer;

const Adapter = struct {
    account: u128,
    sends: usize = 0,
    result: venue.SendResult = .accepted,
    fail: bool = false,
    command: ?canonical.OrderCommand = null,
    pending: ?canonical.AdapterOutputBatch = null,

    fn interface(self: *@This()) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    fn start(_: *anyopaque, _: venue.VenueConfig) venue.StartError!void {}
    fn stop(_: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {}
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const output = self.pending;
        self.pending = null;
        return output;
    }
    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const command = request.order_command;
        std.debug.assert(command.exchange_account == self.account);
        std.debug.assert(command.time_in_force == .immediate_or_cancel);
        self.sends += 1;
        self.command = command;
        if (self.fail) return error.InvalidRequest;
        return self.result;
    }
};

const Harness = struct {
    memory: *durable.MemoryAdapter,
    owner: *demo.Owner,
    gateway: *execution.Gateway,
    adapters: [2]Adapter = .{ .{ .account = 20 }, .{ .account = 30 } },
    now: u64 = 0,

    fn init(self: *@This()) !void {
        const allocator = std.testing.allocator;
        self.memory = try allocator.create(durable.MemoryAdapter);
        errdefer allocator.destroy(self.memory);
        self.memory.* = .init();
        errdefer self.memory.deinit();
        self.owner = try allocator.create(demo.Owner);
        errdefer allocator.destroy(self.owner);
        self.gateway = try allocator.create(execution.Gateway);
        errdefer allocator.destroy(self.gateway);
        try demo.Owner.bootstrapInto(self.owner, self.memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
        try accounts.initializePythonOwner(self.owner);
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 2 };
        for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, 0..) |account, instrument, index| group.members[index] = .{
            .intent_sequence = index + 1,
            .strategy_instance = 9,
            .exchange_account = account,
            .operation = .place,
            .instrument = instrument,
            .side = if (index == 0) .buy else .sell,
            .time_in_force = .immediate_or_cancel,
            .quantity = 10000,
            .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
        };
        _ = try self.owner.apply(fixture.atGroup(45, .{ .identity = 1200, .payload = .{ .oms_intent_group = group } }));
        try std.testing.expectEqual(@as(u16, 2), self.owner.shard.oms.command_history_count);
        self.gateway.init();
        try self.gateway.bootstrapDurableDispatch(self.memory.interface(), undefined, .{ .domain = .control, .id = 92 });
        try self.routes(self.gateway);
        try self.gateway.pinDeploymentDigest(self.owner.shard.deployment.header.?.expected_digest);
        try observe(self.gateway, &self.owner.shard);
        self.now = self.owner.shard.oms.findCommand(1).?.authority.dispatch_deadline_monotonic_ns - std.time.ns_per_s;
    }

    fn routes(self: *@This(), gateway: *execution.Gateway) !void {
        for (&self.adapters, [_]u64{ 1, 21 }) |*adapter, identity| try gateway.add(.{
            .account = adapter.account,
            .adapter = adapter.interface(),
            .venue_identity = identity,
            .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 },
            .supported_products = execution.productMask(.isolated_linear_usdt),
        });
    }

    fn deinit(self: *@This()) void {
        self.memory.deinit();
        std.testing.allocator.destroy(self.gateway);
        std.testing.allocator.destroy(self.owner);
        std.testing.allocator.destroy(self.memory);
    }

    fn applyPrivate(self: *@This(), index: usize, sequence: u64, payload: canonical.Payload) !void {
        std.debug.assert(self.adapters[index].pending == null);
        var batch: canonical.AdapterOutputBatch = .{};
        try batch.append(privateRecord(self, index, sequence, payload));
        self.adapters[index].pending = batch;
        var outputs: [execution.max_routes]canonical.AdapterOutputBatch = undefined;
        const count = try self.gateway.drainFair(&outputs);
        try std.testing.expectEqual(@as(u8, 1), count);
        try self.owner.applyAdapterBatch(outputs[0]);
    }
};

fn observe(gateway: *execution.Gateway, shard: *const trading.TradingShard) !void {
    for (shard.oms.command_history[0..shard.oms.command_history_count]) |command| {
        var view: trading.TradingShard = undefined;
        try shard.copyAccountViewInto(&view, command.authority.exchange_account);
        try gateway.observeAuthorityFromShard(shard, .{
            .account = command.authority.exchange_account,
            .effective_trading_authority = view.operational_state.effectiveTradingAuthority(),
            .reservation_identity = command.reservation_identity,
            .reservation = command.reservation,
            .primary_lease_expires_at_monotonic_ns = 100 * std.time.ns_per_s,
            .fencing_token = 1,
            .exchange_position = view.currentNetExchangePosition(command.instrument).?,
            .authority_barrier = shard.authoritativeBarrier(),
        });
    }
}

test "06 dual IOC sends both accounts before any private report or Fill" {
    const partial: FillConsumer = .{ .applied_quantity = 3000, .possible_quantity = 2000 };
    try std.testing.expectEqual(@as(i64, 5000), try partial.additionalHedgeQuantity(10000));
    try std.testing.expectEqual(@as(i64, 0), try partial.additionalHedgeQuantity(2000));
    var h: Harness = undefined;
    h.adapters = .{ .{ .account = 20 }, .{ .account = 30 } };
    try h.init();
    defer h.deinit();
    const before = h.owner.shard.canonicalStateDigest();
    for ([_]u64{ 1, 2 }) |id| try std.testing.expectEqual(venue.SendResult.accepted, try h.gateway.sendFromShard(&h.owner.shard, id, h.now));
    for (h.adapters) |adapter| try std.testing.expectEqual(@as(usize, 1), adapter.sends);
    try std.testing.expectEqualSlices(u8, &before, &h.owner.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u16, 2), h.gateway.accepted_dispatch_count);
}

test "06 second IOC transport failure preserves first send and both reservations" {
    for ([_]venue.SendResult{ .backpressure, .stopped, .accepted }) |result| {
        var h: Harness = undefined;
        h.adapters = .{ .{ .account = 20 }, .{ .account = 30, .result = result, .fail = result == .accepted } };
        try h.init();
        defer h.deinit();
        const before = h.owner.shard.canonicalStateDigest();
        try std.testing.expectEqual(venue.SendResult.accepted, try h.gateway.sendFromShard(&h.owner.shard, 1, h.now));
        if (result == .accepted) try std.testing.expectError(error.NotSent, h.gateway.sendFromShard(&h.owner.shard, 2, h.now)) else try std.testing.expectEqual(result, try h.gateway.sendFromShard(&h.owner.shard, 2, h.now));
        try std.testing.expectEqualSlices(u8, &before, &h.owner.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u16, 1), h.gateway.accepted_dispatch_count);
        try std.testing.expectEqual(@as(u16, 1), h.gateway.uncertain_dispatch_count);
        for ([_]u128{ 20, 30 }) |account| try std.testing.expect((try h.owner.shard.oms.reservationsForAccount(1, account)).atoms > 0);
        try std.testing.expectEqual(@as(u8, 1), h.owner.shard.cycles.count);
        try expectRecoveredNoResend(&h);
    }
}

fn expectRecoveredNoResend(h: *Harness) !void {
    const allocator = std.testing.allocator;
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.recoverInto(owner, h.memory.interface(), undefined, h.owner.stream);
    try std.testing.expectEqualSlices(u8, &h.owner.shard.canonicalStateDigest(), &owner.shard.canonicalStateDigest());
    const gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try h.routes(gateway);
    try gateway.attachRecoveredDurableDispatch(h.memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    try gateway.pinDeploymentDigest(owner.shard.deployment.header.?.expected_digest);
    // Keep the live authority eligible: recovery admission alone must not mask a resend bug.
    try observe(gateway, &h.owner.shard);
    const sends = [2]usize{ h.adapters[0].sends, h.adapters[1].sends };
    const count: usize = if (h.adapters[0].sends == 0) 0 else if (h.adapters[1].sends == 0) 1 else 2;
    try std.testing.expectEqual(h.gateway.accepted_dispatch_count, gateway.accepted_dispatch_count);
    try std.testing.expectEqual(h.gateway.uncertain_dispatch_count, gateway.uncertain_dispatch_count);
    const ids = [_]u64{ 1, 2 };
    for (ids[0..count]) |id| {
        if (h.gateway.acceptedClientOrderIdFromShard(&h.owner.shard, id) != null)
            try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(&h.owner.shard, id, h.now))
        else
            try std.testing.expectError(error.NotSent, gateway.sendFromShard(&h.owner.shard, id, h.now));
    }
    try std.testing.expectEqual(sends, [2]usize{ h.adapters[0].sends, h.adapters[1].sends });
    for (h.gateway.accepted_dispatches[0..h.gateway.accepted_dispatch_count], gateway.accepted_dispatches[0..gateway.accepted_dispatch_count]) |expected, actual|
        try std.testing.expectEqualDeep(expected.proof, actual.proof);
    for (h.gateway.uncertain_dispatches[0..h.gateway.uncertain_dispatch_count], gateway.uncertain_dispatches[0..gateway.uncertain_dispatch_count]) |expected, actual|
        try std.testing.expectEqualDeep(expected.recovered_proof, actual.recovered_proof);
    try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
}

var fault_remaining: usize = 0;
fn failAppend(context: *anyopaque, io: std.Io, request: durable.Append) anyerror!void {
    if (fault_remaining == 1) return error.InjectedEio;
    fault_remaining -= 1;
    const memory: *durable.MemoryAdapter = @ptrCast(@alignCast(context));
    try memory.interface().append(io, request);
}
fn failCommit(context: *anyopaque, io: std.Io, stream: durable.StreamIdentity, barrier: u64) anyerror!void {
    if (fault_remaining == 1) return error.InjectedEio;
    fault_remaining -= 1;
    const memory: *durable.MemoryAdapter = @ptrCast(@alignCast(context));
    try memory.interface().commit(io, stream, barrier);
}

fn privateRecord(h: *const Harness, index: usize, sequence: u64, payload: canonical.Payload) canonical.EventRecord {
    var input = fixture.canonicalAt(46 + sequence, sequence, payload);
    input.venue.envelope.exchange_account = h.adapters[index].account;
    input.venue.envelope.venue = if (index == 0) 1 else 21;
    input.venue.envelope.identity.stream = 99;
    input.venue.envelope.source_stream = 99;
    input.venue.envelope.raw_evidence.stream = 99;
    input.venue.envelope.raw_evidence.digest = @splat(1);
    return input.venue;
}

test "06 Unknown and late dual IOC fills preserve possible quantity and unique strategy proposals" {
    try exerciseLateFills(false);
}

test "06 cancel in flight and Unknown restart retain late fills without a second hedge" {
    try exerciseLateFills(true);
}

fn exerciseLateFills(cancel_in_flight: bool) !void {
    var h: Harness = undefined;
    h.adapters = .{ .{ .account = 20 }, .{ .account = 30, .result = .backpressure } };
    try h.init();
    defer h.deinit();
    try std.testing.expectEqual(venue.SendResult.accepted, try h.gateway.sendFromShard(&h.owner.shard, 1, h.now));
    try std.testing.expectEqual(venue.SendResult.backpressure, try h.gateway.sendFromShard(&h.owner.shard, 2, h.now));
    for ([_]u128{ 20, 30 }, 0..) |account, index| {
        var dispatch: trading.oms.DispatchBatch = .{ .count = 1 };
        dispatch.items[0] = .{ .command_id = index + 1, .state = if (index == 0) .submitted else .unknown };
        _ = try h.owner.apply(fixture.atGroup(46, .{ .identity = 1500 + index, .account_scope = account, .payload = .{ .oms_dispatch_batch = dispatch } }));
    }
    var consumers: [2]FillConsumer = @splat(.{});
    for (&consumers, 0..) |*consumer, index| {
        const order = h.owner.shard.oms.orderById(index + 1).?;
        try consumer.observe(&h.owner.shard, order.exchange_account, order.id);
        try std.testing.expectEqual(@as(i64, 10000), consumer.possible_quantity);
        try std.testing.expectEqual(@as(usize, 0), consumer.proposals);
    }
    // A temporarily missing order is unresolved, not proof that its original send was absent.
    if (cancel_in_flight) {
        const query = privateRecord(&h, 1, 1, .{ .reconciliation_started = 1 });
        try h.applyPrivate(1, 1, .{ .order_reconciliation_result = .{
            .identity = 1,
            .order = 2,
            .revision = 1,
            .complete = false,
            .status = .unresolved,
            .rules_version = 1,
            .cumulative_quantity = .{ .instrument = 102, .rules_version = 1, .lots = 0 },
            .remaining_quantity = .{ .instrument = 102, .rules_version = 1, .lots = 10000 },
            .evidence = .{
                .scope = .{ .exchange_account = 30, .instrument = 102, .order = 2, .revision = 1, .from_utc_ns = h.owner.shard.oms.orderById(2).?.created_at_utc_ns, .through_utc_ns = query.envelope.times.source_utc_ns.? },
                .observed_at_utc_ns = query.envelope.times.source_utc_ns.?,
                .source = query.envelope.raw_evidence,
            },
        } });
        // The reconciliation safety latch may cancel the live sibling; it cannot hedge or roll it back.
        try std.testing.expectEqual(@as(u16, 3), h.owner.shard.oms.command_history_count);
        try std.testing.expectEqual(trading.oms.Operation.cancel, h.owner.shard.oms.findCommand(3).?.operation);
        try std.testing.expectEqual(trading.oms.OrderState.pending_cancel, h.owner.shard.oms.orderById(1).?.state);
    }
    try std.testing.expectError(error.UnreconciledDispatch, h.gateway.reconcileRecoveredDispatch(&h.owner.shard, 2));
    try std.testing.expectError(error.NotSent, h.gateway.sendFromShard(&h.owner.shard, 2, h.now));
    try h.owner.checkpoint();
    const unknown_owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(unknown_owner);
    try demo.Owner.recoverInto(unknown_owner, h.memory.interface(), undefined, h.owner.stream);
    var restored_consumer = consumers[1];
    try restored_consumer.observe(&unknown_owner.shard, 30, 2);
    try std.testing.expectEqual(@as(i64, 10000), restored_consumer.possible_quantity);
    try std.testing.expectEqual(@as(i64, 0), try restored_consumer.additionalHedgeQuantity(10000));
    try std.testing.expectError(error.InvalidTarget, restored_consumer.additionalHedgeQuantity(-1));
    try std.testing.expectEqual(trading.oms.OrderState.unknown, unknown_owner.shard.oms.orderById(2).?.state);
    try std.testing.expectEqual(@as(u8, 1), unknown_owner.shard.cycles.count);
    for (&consumers, 0..) |*consumer, index| {
        if (index == 1) {
            try consumer.observe(&h.owner.shard, 30, 2);
            try std.testing.expectEqual(@as(i64, 0), try consumer.additionalHedgeQuantity(consumers[0].applied_quantity));
            const unsafe_repair = reductionGroup(51, 10000, 10000);
            const command_count = h.owner.shard.oms.command_history_count;
            _ = try h.owner.apply(fixture.atGroup(49, .{ .identity = 1800, .payload = .{ .oms_intent_group = unsafe_repair } }));
            try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.portfolio_reduce_only_violation, h.owner.shard.last_reject_reason);
            try std.testing.expectEqual(command_count, h.owner.shard.oms.command_history_count);
        }
        const order = h.owner.shard.oms.orderById(index + 1).?;
        const venue_id: u64 = if (index == 0) 1 else 21;
        const report: canonical.Payload = .{ .execution_report = .{
            .identity = 2,
            .order = order.id,
            .client_order_id = order.client_order_id,
            .exchange_account = order.exchange_account,
            .instrument = order.instrument,
            .revision = 1,
            .status = .filled,
            .cumulative_quantity = .{ .instrument = order.instrument, .rules_version = 1, .lots = 10000 },
            .remaining_quantity = .{ .instrument = order.instrument, .rules_version = 1, .lots = 0 },
        } };
        const fill: canonical.Payload = .{ .fill = .{
            .identity = 1,
            .order = order.id,
            .client_order_id = order.client_order_id,
            .venue_order = try canonical.VenueOrderRef.init(venue_id, "dual-ioc"),
            .venue_trade = try canonical.VenueTradeRef.init(venue_id, "late-fill"),
            .exchange_account = order.exchange_account,
            .instrument = order.instrument,
            .side = if (index == 0) .buy else .sell,
            .quantity = .{ .instrument = order.instrument, .rules_version = 1, .lots = 10000 },
            .price = order.limit_price,
            .fee = .{ .asset = 1, .atoms = 0 },
            .liquidity = .taker,
        } };
        const events: [2]canonical.Payload = if (index == 0) .{ report, fill } else .{ fill, report };
        for (events, 0..) |payload, step| {
            try h.applyPrivate(index, 2 + step, payload);
            try consumer.observe(&h.owner.shard, order.exchange_account, order.id);
            const seen_fill = step == 1 or index == 1;
            try std.testing.expectEqual(@as(usize, if (seen_fill) 1 else 0), consumer.proposals);
            try std.testing.expectEqual(@as(i64, if (seen_fill) 0 else 10000), consumer.possible_quantity);
            try h.applyPrivate(index, 2 + step, payload);
            try consumer.observe(&h.owner.shard, order.exchange_account, order.id);
            try std.testing.expectEqual(@as(usize, if (seen_fill) 1 else 0), consumer.proposals);
        }
    }
    const initial_commands: u16 = if (cancel_in_flight) 3 else 2;
    try std.testing.expectEqual(initial_commands, h.owner.shard.oms.command_history_count);
    try std.testing.expectEqual(@as(u8, 1), h.owner.shard.cycles.count);
    try std.testing.expectError(error.FillArchivePinned, h.owner.archiveFillHistory(1, h.gateway));
    try h.owner.checkpoint();
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, h.memory.interface(), undefined, h.owner.stream);
    try std.testing.expectEqualSlices(u8, &h.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    for (&consumers, 0..) |*consumer, index| {
        try consumer.observe(&recovered.shard, h.adapters[index].account, index + 1);
        try std.testing.expectEqual(@as(usize, 1), consumer.proposals);
        try std.testing.expectEqual(@as(i64, 0), consumer.possible_quantity);
    }
    // Only an explicit new strategy intent can repair; policy emits no economic rollback.
    var repair = reductionGroup(1001, @divExact(consumers[0].applied_quantity, 2), @divExact(consumers[1].applied_quantity, 2));
    _ = try h.owner.apply(fixture.atGroup(55, .{ .identity = 2000, .payload = .{ .oms_intent_group = repair } }));
    try std.testing.expectEqual(initial_commands + 2, h.owner.shard.oms.command_history_count);
    try std.testing.expectEqual(@as(u8, 1), h.owner.shard.cycles.count);
    repair.first_intent_sequence = 1003;
    for (repair.members[0..2], 0..) |*member, index| {
        member.intent_sequence = 1003 + index;
        member.quantity = 6000;
    }
    _ = try h.owner.apply(fixture.atGroup(56, .{ .identity = 2001, .payload = .{ .oms_intent_group = repair } }));
    try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.portfolio_reduce_only_violation, h.owner.shard.last_reject_reason);
    try std.testing.expectEqual(initial_commands + 2, h.owner.shard.oms.command_history_count);
}

fn reductionGroup(sequence: u64, left: i64, right: i64) trading.oms.IntentGroup {
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = sequence, .count = 2 };
    for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }, [_]i64{ left, right }, 0..) |account, instrument, quantity, index| group.members[index] = .{
        .intent_sequence = sequence + index,
        .strategy_instance = 9,
        .exchange_account = account,
        .operation = .place,
        .instrument = instrument,
        .side = if (index == 0) .sell else .buy,
        .portfolio_reduce_only = true,
        .time_in_force = .immediate_or_cancel,
        .quantity = quantity,
        .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 100 },
    };
    return group;
}

test "06 dual IOC every dispatch intent and outcome append or commit boundary fails closed" {
    for ([_]bool{ false, true }) |at_commit| for (1..5) |boundary| {
        var h: Harness = undefined;
        h.adapters = .{ .{ .account = 20 }, .{ .account = 30 } };
        try h.init();
        defer h.deinit();
        const before = h.owner.shard.canonicalStateDigest();
        const store = h.memory.interface();
        var failing = store.vtable.*;
        if (at_commit) failing.commit = failCommit else failing.append = failAppend;
        h.gateway.durable_dispatch.?.store = .{ .context = store.context, .vtable = &failing };
        fault_remaining = boundary;
        const failed_id: u64 = if (boundary <= 2) 1 else 2;
        if (failed_id == 2) try std.testing.expectEqual(venue.SendResult.accepted, try h.gateway.sendFromShard(&h.owner.shard, 1, h.now));
        try std.testing.expectError(error.NotSent, h.gateway.sendFromShard(&h.owner.shard, failed_id, h.now));
        h.gateway.durable_dispatch.?.store = store;
        try std.testing.expectEqualSlices(u8, &before, &h.owner.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(usize, if (boundary <= 1) 0 else 1), h.adapters[0].sends);
        try std.testing.expectEqual(@as(usize, if (boundary <= 3) 0 else 1), h.adapters[1].sends);
        for ([_]u128{ 20, 30 }) |account| try std.testing.expect((try h.owner.shard.oms.reservationsForAccount(1, account)).atoms > 0);
        if (at_commit) {
            const recovered = try std.testing.allocator.create(execution.Gateway);
            defer std.testing.allocator.destroy(recovered);
            recovered.init();
            try h.routes(recovered);
            try std.testing.expectError(error.DurableDispatchUnavailable, recovered.attachRecoveredDurableDispatch(store, undefined, .{ .domain = .control, .id = 92 }));
            try std.testing.expectError(error.NotSent, recovered.sendFromShard(&h.owner.shard, failed_id, h.now));
        } else try expectRecoveredNoResend(&h);
    };
}
