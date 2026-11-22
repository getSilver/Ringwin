//! Read-only active cycle view at a committed Writer barrier.
const std = @import("std");
const trading = @import("../trading/trading_shard.zig");

pub const Order = struct {
    intent_sequence: u64,
    order_id: u64,
    account: u128,
    instrument: u128,
    revision: u32,
    state: trading.oms.OrderState,
    quantity: i64,
    reported_lots: i64,
    applied_lots: i64,
    possible_lots: i64,
    queryable: bool,
};

pub fn orderView(shard: *const trading.TradingShard, order: trading.oms.Order) !Order {
    const account = shard.accountState(order.exchange_account) orelse return error.UnknownCycleAccount;
    const applied = try account.economic_projection.appliedCanonicalFillQuantity(order.id);
    const terminal = switch (order.state) {
        .filled, .canceled, .rejected => true,
        else => false,
    };
    const possible = @max(0, (if (terminal) order.cumulative_quantity else @max(order.quantity, order.confirmed_quantity)) - applied);
    return .{
        .intent_sequence = order.intent_sequence,
        .order_id = order.id,
        .account = order.exchange_account,
        .instrument = order.instrument,
        .revision = order.revision,
        .state = order.state,
        .quantity = order.quantity,
        .reported_lots = order.cumulative_quantity,
        .applied_lots = applied,
        .possible_lots = possible,
        .queryable = if (terminal) possible != 0 else order.state != .pending_submit,
    };
}

const Leg = struct {
    account: u128,
    instrument: u128,
    rules_version: u32,
    position_lots: i128,
    economics_available: bool,
};

const Cycle = struct {
    first_sequence: u64,
    portfolio: u128,
    legs: []const Leg,
    orders: []const Order,
};

pub fn encode(shard: *const trading.TradingShard, strategy: u128, recovery: bool, storage: []u8) !?[]const u8 {
    const occupancy = @import("../trading/cycle_occupancy.zig");
    var cycles: [occupancy.max_cycles]Cycle = undefined;
    var legs: [occupancy.max_cycles][occupancy.max_members]Leg = undefined;
    var orders: [trading.oms.max_orders]Order = undefined;
    var cycle_count: usize = 0;
    var order_count: usize = 0;
    for (shard.cycles.records[0..shard.cycles.count]) |cycle| {
        if (cycle.strategy != strategy) continue;
        const first = order_count;
        for (shard.oms.command_history[0..shard.oms.command_history_count]) |command| {
            if (command.operation != .place or command.strategy_instance != strategy or
                command.authority.cycle.identity != cycle.first_sequence or command.authority.cycle.barrier != cycle.fact_sequence) continue;
            const order = shard.oms.orderById(command.order_id) orelse return error.MissingActiveCycleOrder;
            if (order_count == orders.len) return error.CycleProjectionCapacity;
            orders[order_count] = try orderView(shard, order);
            order_count += 1;
        }
        for (cycle.members[0..cycle.count], legs[cycle_count][0..cycle.count]) |member, *leg| {
            const account = shard.accountState(member.account) orelse return error.UnknownCycleAccount;
            const portfolio = account.economic_projection.portfolioLayer(cycle.portfolio) orelse return error.UnknownCyclePortfolio;
            const instrument = shard.pairInstrument(member.account, member.instrument) orelse return error.UnknownCycleInstrument;
            leg.* = .{
                .account = member.account,
                .instrument = member.instrument,
                .rules_version = instrument.rules.version,
                .position_lots = portfolio.positionForInstrument(member.instrument).quantity,
                .economics_available = account.economic_fault_count == 0 and
                    !account.economic_projection.reconciliation_break and account.open_economic_unknown_time_count == 0,
            };
        }
        cycles[cycle_count] = .{
            .first_sequence = cycle.first_sequence,
            .portfolio = cycle.portfolio,
            .legs = legs[cycle_count][0..cycle.count],
            .orders = orders[first..order_count],
        };
        cycle_count += 1;
    }
    if (cycle_count == 0) return null;
    var writer = std.Io.Writer.fixed(storage);
    try std.json.Stringify.value(.{ .barrier = shard.authoritativeBarrier(), .recovery = recovery, .cycles = cycles[0..cycle_count] }, .{}, &writer);
    return writer.buffered();
}
