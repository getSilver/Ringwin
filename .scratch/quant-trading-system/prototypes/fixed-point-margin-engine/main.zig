const std = @import("std");
const builtin = @import("builtin");
const margin = @import("model.zig");
const Io = std.Io;

const gate_tiers = [_]margin.Tier{
    .{ .upper_notional = 500_000 * margin.money_scale, .imr_ppm = 5_000, .mmr_ppm = 3_000, .deduction = 0 },
    .{ .upper_notional = 1_000_000 * margin.money_scale, .imr_ppm = 6_666, .mmr_ppm = 3_500, .deduction = 250 * margin.money_scale },
    .{ .upper_notional = 1_500_000 * margin.money_scale, .imr_ppm = 8_000, .mmr_ppm = 4_000, .deduction = 750 * margin.money_scale },
};

const rules = margin.Rules{
    .tiers = &gate_tiers,
    .contract_num = 1,
    .contract_den = 10_000,
    .price_tick = 100_000,
    .fee_ppm = 750,
    .leverage_milli = 50_000,
};

fn usdt(value: i64) i64 {
    return value * margin.money_scale;
}

fn printMoney(out: *Io.Writer, value: i64) !void {
    const negative = value < 0;
    const absolute: i128 = if (negative) -@as(i128, value) else value;
    const fraction = @mod(absolute, margin.money_scale);
    try out.print("{s}{d}.", .{ if (negative) "-" else "", @divFloor(absolute, margin.money_scale) });
    if (fraction < 100_000) try out.print("0", .{});
    if (fraction < 10_000) try out.print("0", .{});
    if (fraction < 1_000) try out.print("0", .{});
    if (fraction < 100) try out.print("0", .{});
    if (fraction < 10) try out.print("0", .{});
    try out.print("{d}", .{fraction});
}

fn printPrice(out: *Io.Writer, value: i64) !void {
    try out.print("{d}.{d}", .{
        @divFloor(value, margin.money_scale),
        @divFloor(@mod(value, margin.money_scale), 100_000),
    });
}

fn render(out: *Io.Writer, portfolio: margin.State, exchange: margin.State) !void {
    const pa = try margin.assess(rules, portfolio);
    const ea = try margin.assess(rules, exchange);
    const liq = try margin.liquidation(rules, exchange);
    const current_gate = if (pa.margin_buffer <= ea.margin_buffer) "Portfolio" else "Exchange";
    const projected_gate = if (pa.projected_margin_buffer <= ea.projected_margin_buffer)
        "Portfolio"
    else
        "Exchange";

    try out.print("\nGate BTC_USDT sample | leverage=50.000x | mark=", .{});
    try printPrice(out, portfolio.mark_price);
    try out.print(" | portfolio qty={d}, exchange qty={d}\n", .{ portfolio.qty, exchange.qty });
    try out.print("layer current: tier  notional       MM             equity         buffer\n", .{});
    for ([_]struct { []const u8, margin.Assessment }{
        .{ "portfolio", pa },
        .{ "exchange ", ea },
    }) |row| {
        try out.print("{s}       {d}  ", .{ row[0], row[1].current_tier + 1 });
        try printMoney(out, row[1].position_notional);
        try out.print("  ", .{});
        try printMoney(out, row[1].maintenance_margin);
        try out.print("  ", .{});
        try printMoney(out, row[1].equity);
        try out.print("  ", .{});
        try printMoney(out, row[1].margin_buffer);
        try out.print("\n", .{});
    }
    try out.print("\nlayer opening: IM_tier  worst_notional  IM             order_fees     reserve_slack  projected(side/qty/buffer)\n", .{});
    for ([_]struct { []const u8, margin.Assessment }{
        .{ "portfolio", pa },
        .{ "exchange ", ea },
    }) |row| {
        try out.print("{s}           {d}  ", .{ row[0], row[1].worst_im_tier + 1 });
        try printMoney(out, row[1].worst_notional);
        try out.print("  ", .{});
        try printMoney(out, row[1].initial_margin);
        try out.print("  ", .{});
        try printMoney(out, row[1].order_fee_reserve);
        try out.print("  ", .{});
        try printMoney(out, row[1].reservation_surplus);
        try out.print("  {s}/{d}/", .{ @tagName(row[1].projected_side), row[1].projected_qty });
        try printMoney(out, row[1].projected_margin_buffer);
        try out.print("\n", .{});
    }
    try out.print(
        "\ncurrent_governing={s}; projected_governing={s}; exchange_liquidation=",
        .{ current_gate, projected_gate },
    );
    if (liq) |value| {
        try printPrice(out, value.price);
        try out.print(", distance={d} ticks/{d} bps\n", .{ value.distance_ticks, value.distance_bps });
    } else try out.print("none/unknown\n", .{});
    try out.print("[j/k] mark -/+100  [b] buy +10k  [s] sell +10k  [r] reduce-only split  [f] forced allocation  [q] quit\n> ", .{});
}

fn showReduceOnly(out: *Io.Writer) !void {
    const flags = margin.reduceOnlyFlags(10, 2, -5, -13);
    try out.print(
        "\nSell 8 contracts: virtual portfolio +10 -> +2, exchange account -5 -> -13\nPortfolioReduceOnly={any}, VenueReduceOnly={any}\n",
        .{ flags.portfolio, flags.venue },
    );
}

fn showAllocation(out: *Io.Writer) !void {
    const contributors = [_]margin.Contributor{
        .{ .id = 101, .qty = 3 },
        .{ .id = 102, .qty = 2 },
        .{ .id = 103, .qty = 1 },
    };
    var storage: [contributors.len]margin.Allocation = undefined;
    const result = try margin.allocateForced(&contributors, 1, .{
        .qty = 4,
        .realized_pnl = -120_000_001,
        .fee = -3_000_001,
        .penalty = -1_000_001,
    }, &storage);
    try out.print("\nForced execution totals: qty=4 pnl=-120.000001 fee=-3.000001 penalty=-1.000001\n", .{});
    for (result) |item| {
        try out.print("#{d}: qty={d} pnl=", .{ item.id, item.qty });
        try printMoney(out, item.realized_pnl);
        try out.print(" fee=", .{});
        try printMoney(out, item.fee);
        try out.print(" penalty=", .{});
        try printMoney(out, item.penalty);
        try out.print("\n", .{});
    }
    try out.print("largest-remainder allocation closes every component exactly\n", .{});
}

fn selfCheck() !void {
    const boundary = margin.State{
        .qty = 100_000,
        .entry_price = usdt(50_000),
        .mark_price = usdt(50_000),
        .margin = usdt(10_000),
    };
    const at_boundary = try margin.assess(rules, boundary);
    if (at_boundary.current_tier != 0 or at_boundary.worst_im_tier != 0)
        return error.TierBoundaryFailed;
    var crossed = boundary;
    crossed.qty += 1;
    if ((try margin.assess(rules, crossed)).worst_im_tier != 1) return error.TierCrossingFailed;

    var with_orders = boundary;
    with_orders.qty = 90_000;
    with_orders.open_buy_qty = 20_001;
    with_orders.open_sell_qty = 5_000;
    with_orders.buy_worst_price = usdt(50_100);
    with_orders.sell_worst_price = usdt(49_900);
    const assessed_orders = try margin.assess(rules, with_orders);
    if (assessed_orders.current_tier != 0 or assessed_orders.worst_im_tier != 1)
        return error.WorstOrderFailed;
    if (assessed_orders.effective_imr_ppm != 20_000) return error.AccountLeverageIgnored;
    if (assessed_orders.order_fee_reserve != 93_866_258)
        return error.AllOrderFeesNotReserved;
    if (assessed_orders.projected_side != .buy or
        assessed_orders.projected_margin_buffer >= assessed_orders.margin_buffer)
        return error.ProjectedBufferMissing;
    with_orders.buy_portfolio_reduce_only = true;
    if (margin.assess(rules, with_orders)) |_| return error.InvalidReduceOnlyAccepted else |err| {
        if (err != error.InvalidPortfolioReduceOnly) return err;
    }
    with_orders.buy_portfolio_reduce_only = false;
    with_orders.open_buy_qty = 0;
    with_orders.sell_portfolio_reduce_only = true;
    const reduce_only = try margin.assess(rules, with_orders);
    if (reduce_only.worst_notional != reduce_only.position_notional or
        reduce_only.order_fee_reserve == 0) return error.ReduceOnlyReservationFailed;

    var no_orders = boundary;
    no_orders.buy_worst_price = usdt(60_000);
    if ((try margin.assess(rules, no_orders)).worst_notional !=
        (try margin.assess(rules, boundary)).worst_notional) return error.StaleWorstPriceFailed;

    const flags = margin.reduceOnlyFlags(10, 2, -5, -13);
    if (!flags.portfolio or flags.venue) return error.ReduceOnlyFailed;

    const contributors = [_]margin.Contributor{
        .{ .id = 101, .qty = 3 },
        .{ .id = 102, .qty = 2 },
        .{ .id = 103, .qty = 1 },
    };
    var storage: [3]margin.Allocation = undefined;
    const forced = margin.ForcedEconomics{
        .qty = 4,
        .realized_pnl = -120_000_001,
        .fee = -3_000_001,
        .penalty = -1_000_001,
    };
    const allocation = try margin.allocateForced(&contributors, 1, forced, &storage);
    if (allocation[0].qty != 2 or allocation[1].qty != 1 or allocation[2].qty != 1)
        return error.AllocationFailed;
    var closed = margin.ForcedEconomics{ .qty = 0, .realized_pnl = 0, .fee = 0, .penalty = 0 };
    for (allocation) |item| {
        closed.qty += item.qty;
        closed.realized_pnl += item.realized_pnl;
        closed.fee += item.fee;
        closed.penalty += item.penalty;
    }
    if (!std.meta.eql(closed, forced)) return error.EconomicAllocationDidNotClose;

    var liquidating = boundary;
    liquidating.qty = 10_000;
    liquidating.margin = usdt(500);
    const liq = (try margin.liquidation(rules, liquidating)) orelse return error.LiquidationFailed;
    if (liq.price >= liquidating.mark_price or
        try margin.liquidation(rules, .{
            .qty = 0,
            .entry_price = usdt(50_000),
            .mark_price = usdt(50_000),
            .margin = 0,
        }) != null) return error.LiquidationFailed;
}

fn benchmark(io: Io, out: *Io.Writer, iterations: u64) !void {
    var state = margin.State{
        .qty = 90_000,
        .entry_price = usdt(49_500),
        .mark_price = usdt(50_000),
        .open_buy_qty = 20_001,
        .open_sell_qty = 5_000,
        .buy_worst_price = usdt(50_100),
        .sell_worst_price = usdt(49_900),
        .margin = usdt(20_000),
    };
    var sink: i64 = 0;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |i| {
        state.open_sell_qty = @intCast(5_000 + i % 17);
        const result = try margin.assess(rules, state);
        sink +%= result.margin_buffer +% result.projected_margin_buffer +% result.reservation_surplus;
    }
    const elapsed: i96 = Io.Clock.awake.now(io).nanoseconds - start;
    std.mem.doNotOptimizeAway(sink);
    const elapsed_u: u128 = @intCast(elapsed);
    try out.print(
        "benchmark: {d} assessments, {d} ns/op, {d} ops/s\n",
        .{ iterations, @divFloor(elapsed_u, iterations), @divFloor(@as(u128, iterations) * std.time.ns_per_s, elapsed_u) },
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try selfCheck();
    if (args.len > 1 and std.mem.eql(u8, args[1], "--check")) {
        try out.print("self_check: ok\n", .{});
        try out.flush();
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--bench")) {
        const iterations = if (args.len > 2) try std.fmt.parseUnsigned(u64, args[2], 10) else 1_000_000;
        try benchmark(io, out, iterations);
        try out.flush();
        return;
    }
    if (args.len > 1) return error.UnknownArgument;

    var portfolio = margin.State{
        .qty = 90_000,
        .entry_price = usdt(49_500),
        .mark_price = usdt(50_000),
        .open_buy_qty = 20_001,
        .open_sell_qty = 5_000,
        .buy_worst_price = usdt(50_100),
        .sell_worst_price = usdt(49_900),
        .margin = usdt(20_000),
    };
    var exchange = portfolio;
    exchange.margin = usdt(18_000);

    var stdin_buffer: [256]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
    try out.print(
        "fixed_point_margin_prototype: zig={s}, mode={s}, self_check=ok\n",
        .{ builtin.zig_version_string, @tagName(builtin.mode) },
    );
    try render(out, portfolio, exchange);
    try out.flush();
    while (true) {
        const line = (try stdin_reader.interface.takeDelimiter('\n')) orelse break;
        const command = std.mem.trim(u8, line, " \r\n");
        if (command.len == 0) continue;
        switch (command[0]) {
            'q' => break,
            'j' => {
                portfolio.mark_price -= usdt(100);
                exchange.mark_price = portfolio.mark_price;
            },
            'k' => {
                portfolio.mark_price += usdt(100);
                exchange.mark_price = portfolio.mark_price;
            },
            'b' => {
                portfolio.open_buy_qty += 10_000;
                exchange.open_buy_qty += 10_000;
            },
            's' => {
                portfolio.open_sell_qty += 10_000;
                exchange.open_sell_qty += 10_000;
            },
            'r' => try showReduceOnly(out),
            'f' => try showAllocation(out),
            else => try out.print("\nunknown command\n", .{}),
        }
        try render(out, portfolio, exchange);
        try out.flush();
    }
    try out.print("\nbye\n", .{});
    try out.flush();
}
