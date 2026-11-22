//! Offline normal-cycle exercise of the formal Host and committed Writer.
const std = @import("std");
const builtin = @import("builtin");
const engine = @import("../../runtime/production_engine.zig");
const formal = @import("../../runtime/production_strategy_host.zig");
const Owner = @import("../../runtime/demo/demo_authority.zig").Owner;
const durable = @import("../../persistence/durable_store.zig");
const execution = @import("../../execution/execution_gateway.zig");
const trading = @import("../../trading/trading_shard.zig");
const canonical = trading.canonical;
const fixture = @import("../support/trading_shard_fixture.zig");
const accounts = @import("../acceptance/core/multi_account_authority_acceptance.zig");
const dual = @import("../acceptance/core/dual_ioc_dispatch_acceptance.zig");
const pair = @import("../../trading/pair_trading_authorization.zig");

pub fn run(init: std.process.Init, python: []const u8, executable_gateway: ?[]const u8) !void {
    return runScenario(init, python, executable_gateway, false, null);
}

pub fn runQuery(init: std.process.Init, python: []const u8, executable_gateway: ?[]const u8) !void {
    return runScenario(init, python, executable_gateway, true, null);
}

pub fn runMaker(init: std.process.Init, python: []const u8) !void {
    for (0..2) |maker| try runScenario(init, python, null, false, maker);
}

fn runScenario(init: std.process.Init, python: []const u8, executable_gateway: ?[]const u8, query: bool, maker: ?usize) !void {
    const Runner = struct {
        failure: ?anyerror = null,

        fn runFixture(self: *@This(), process: std.process.Init, executable: []const u8, gateway: ?[]const u8, queries: bool, maker_leg: ?usize) void {
            exercise(process, executable, gateway, queries, maker_leg) catch |err| {
                self.failure = err;
            };
        }
    };
    var runner: Runner = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 * 1024 }, Runner.runFixture, .{ &runner, init, python, executable_gateway, query, maker });
    thread.join();
    if (runner.failure) |err| return err;
}

fn exercise(init: std.process.Init, python: []const u8, executable_gateway: ?[]const u8, query: bool, maker: ?usize) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    defer gpa.free(cwd);
    const path = try std.fmt.allocPrint(gpa, "{s}/.scratch/build/dual-ioc-formal-{d}", .{ cwd, std.Io.Clock.real.now(io).nanoseconds });
    defer gpa.free(path);
    const store = try gpa.create(durable.LinuxFileAdapter);
    defer gpa.destroy(store);
    store.* = .{ .dir = undefined };
    if (builtin.os.tag == .windows) try store.initWindowsVerification(io, path) else try store.initLinux(io, path);
    defer store.close(io);
    const owner = try gpa.create(Owner);
    defer gpa.destroy(owner);
    try Owner.bootstrapInto(owner, store.interface(), io, .{ .domain = .decision_log, .id = 91 });
    try accounts.initializeMixedStablecoinOwner(owner);
    try @import("../acceptance/core/scanner_authorization_acceptance.zig").configurePairAssetsForScenario(owner, false);
    for ([_]u128{ 101, 102 }, [_]u64{ 1, 21 }) |instrument, venue| {
        var book = fixture.canonicalAt(45, 2, .{ .l2_book_snapshot = .{
            .instrument = instrument,
            .sequence = 2,
            .best_bid = .{ .instrument = instrument, .rules_version = 2, .ticks = 99 },
            .best_ask = .{ .instrument = instrument, .rules_version = 2, .ticks = if (maker == null) 100 else 101 },
            .best_bid_quantity = .{ .instrument = instrument, .rules_version = 2, .lots = 100000 },
            .best_ask_quantity = .{ .instrument = instrument, .rules_version = 2, .lots = 100000 },
        } });
        scopeInstrument(&book, instrument, venue, @intCast(1000 + instrument));
        _ = try owner.apply(book);
        _ = try owner.apply(fixture.atGroup(45, .{
            .identity = @intCast(15000 + instrument),
            .account_scope = if (instrument == 101) 20 else 30,
            .payload = .{ .mark_price = .{ .instrument = instrument, .price_atoms = 100 } },
        }));
        if (executable_gateway != null or maker != null) {
            const account: u128 = if (instrument == 101) 20 else 30;
            var capability = owner.shard.pairInstrument(account, instrument).?.capability.?;
            capability.version += 1;
            capability.max_dispatch_age_ns = 15 * std.time.ns_per_s;
            if (maker != null) capability.supports_post_only = true;
            _ = try owner.apply(fixture.atGroup(45, .{
                .identity = @intCast(16000 + instrument),
                .account_scope = account,
                .payload = .{ .capability_profile_activation = capability },
            }));
        }
    }
    try std.testing.expect(owner.shard.pairTradingListEmpty(9));
    if (maker) |index| {
        const request: pair.Request = .{ .identity = 98765, .strategy = 9, .portfolio = 10, .activation = 1, .config_version = 1, .expected_version = 0, .legs = .{
            .{ .venue = 1, .environment = .simulation, .account = 20, .instrument = 101, .rules_version = 2 },
            .{ .venue = 21, .environment = .simulation, .account = 30, .instrument = 102, .rules_version = 2 },
        }, .direction = 1, .mode = if (index == 0) .maker_first else .maker_second, .enabled = true };
        _ = try owner.apply(fixture.atGroup(45, .{ .identity = 98765, .payload = .{ .pair_trading_authorization = request } }));
    } else try approveFromWeb(init, owner, python, path);
    const approved = owner.shard.effectivePairAuthorization(9, 0) orelse return error.PairNotApproved;
    try std.testing.expectEqual(@as(u128, 98765), approved.request.identity);
    try std.testing.expectEqual(@as(u128, 20), approved.request.legs[0].account);
    try std.testing.expectEqual(@as(u128, 30), approved.request.legs[1].account);

    var cursor_buffer: [20]u8 = undefined;
    const cursor = try std.fmt.bufPrint(&cursor_buffer, "{d}", .{owner.shard.authoritativeBarrier()});
    try store.dir.writeFile(io, .{ .sub_path = "engine.json", .data = "{}" });
    if (maker) |index| {
        try runPython(init, &.{ python, "python/verify_production_strategy_chain.py", "--prepare-maker", path, cursor, if (index == 0) "0" else "1" });
    } else try runPython(init, &.{ python, "python/verify_production_strategy_chain.py", if (query) "--prepare-dual-ioc-query" else "--prepare-dual-ioc", path, cursor });
    const config_bytes = try store.dir.readFileAlloc(io, "engine.json", gpa, .limited(16384));
    defer gpa.free(config_bytes);
    const config = try std.json.parseFromSlice(struct { strategy_host: formal.Config }, gpa, config_bytes, .{});
    defer config.deinit();
    const host = try formal.Host.start(init, owner, 1, config.value.strategy_host);
    defer host.close(init);
    try std.testing.expectEqual(@as(?u128, 9), try host.readyStrategy(owner));
    if (maker) |index| return exerciseMaker(init, path, owner, host, config.value.strategy_host, approved.request.legs, index);
    if (builtin.os.tag != .linux and executable_gateway != null) return error.UnsupportedGatewayPlatform;
    var remote: ?RemoteGateway = if (builtin.os.tag == .linux)
        if (executable_gateway) |executable| try RemoteGateway.start(init, executable, path, owner.shard.deployment.header.?.expected_digest) else null
    else
        null;
    defer if (remote) |*process| process.close(init.io);

    try store.dir.rename("fees-2.json", store.dir, "manual-fees.json", io);
    for (1..4) |step| {
        if (step == 3) try store.dir.rename("fees-3.json", store.dir, "manual-fees.json", io);
        const before = owner.shard.authoritativeBarrier();
        try publishTrade(owner, host, step);
        if (step < 3) try std.testing.expectEqual(before + 1, owner.shard.authoritativeBarrier());
        if (step == 3 and owner.shard.oms.order_count != 2)
            std.debug.print("opening rejected: {s}\n", .{@tagName(owner.shard.last_reject_reason)});
        try std.testing.expectEqual(@as(u16, if (step == 3) 2 else 0), owner.shard.oms.order_count);
    }
    const first_sequence = 7;
    try std.testing.expect(owner.shard.cycles.find(9, first_sequence) != null);
    if (query) {
        try exerciseQuery(init, path, owner, host, config.value.strategy_host, if (remote) |*process| process else null);
        if (remote) |*process| try process.finish(io);
        return;
    }

    const gateway = try gpa.create(execution.Gateway);
    defer gpa.destroy(gateway);
    gateway.init();
    try gateway.bootstrapDurableDispatch(store.interface(), io, .{ .domain = .control, .id = 92 });
    try gateway.pinDeploymentDigest(owner.shard.deployment.header.?.expected_digest);
    var adapters = [_]dual.Adapter{ .{ .account = 20 }, .{ .account = 30 } };
    for (&adapters, approved.request.legs) |*adapter, leg| try gateway.add(.{
        .account = leg.account,
        .adapter = adapter.interface(),
        .venue_identity = leg.venue,
        .environment = @enumFromInt(@intFromEnum(leg.environment)),
        .capability = .{ .version = 2, .rules_version = 2, .config_version = 1, .session = 1, .supports_native_amend = true },
        .supported_products = execution.productMask(.isolated_linear),
    });
    if (builtin.os.tag == .linux and remote != null) {
        const process = &remote.?;
        try process.fillPair(gpa, owner, approved.request.legs, false);
        // The independent simulation emits the full lifecycle, including
        // dispatch outcomes and partial execution before terminal reports.
        try owner.checkpoint();
    } else try fillPair(gpa, owner, gateway, &adapters, approved.request.legs, false);
    try publishTrade(owner, host, 4);
    try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
    if (builtin.os.tag == .linux and remote != null)
        try remote.?.fillPair(gpa, owner, approved.request.legs, true)
    else
        try fillPair(gpa, owner, gateway, &adapters, approved.request.legs, true);

    for (approved.request.legs) |leg| try accounts.reconcileDomainAccount(owner, leg.account, gateway);
    for (approved.request.legs, [_]u64{ 1, 3 }, [_]i128{ 394, 594 }) |leg, asset, expected| {
        const economics = &owner.shard.accountState(leg.account).?.economic_projection;
        try std.testing.expectEqual(asset, economics.settlement_asset);
        try std.testing.expectEqual(expected, economics.portfolioLayer(10).?.settlement_balance_atoms);
    }
    const closure = try owner.shard.qualifyCycleClosure(9, first_sequence);
    _ = try owner.apply(.{ .core = .{
        .identity = 98000,
        .source_time = @intCast(std.Io.Clock.real.now(io).nanoseconds),
        .time_presence = .{ .source = true },
        .payload = .{ .cycle_closed = closure },
    } });
    var fx = try @import("../../runtime/strategy_fx_projection.zig").project(gpa, try owner.source(), &owner.decision_journal, 9, first_sequence);
    defer fx.deinit(gpa);
    try std.testing.expect(fx.closed and fx.complete);
    var fees: i128 = 0;
    var rebates: i128 = 0;
    for (fx.flows.items) |flow| {
        if (flow.atoms < 0) fees += flow.atoms else rebates += flow.atoms;
    }
    try std.testing.expectEqual(@as(i128, -10), fees);
    try std.testing.expectEqual(@as(i128, 4), rebates);
    const projection = try fx.json(gpa);
    defer gpa.free(projection);
    try store.dir.writeFile(io, .{ .sub_path = "cycle-fx.json", .data = projection });
    try runPython(init, &.{ python, "python/verify_production_strategy_chain.py", "--verify-dual-ioc-fx", path });
    if (remote) |*process| try process.finish(io);
    std.debug.print("formal_dual_ioc: approval={d} first_intent={d} orders=4 fee=-10 rebate=4 asset=3 closed=true\n", .{ approved.request.identity, first_sequence });
}

fn exerciseMaker(init: std.process.Init, path: []const u8, owner: *Owner, host: *formal.Host, host_config: formal.Config, legs: [2]pair.Leg, maker: usize) !void {
    const gateway = try init.gpa.create(execution.Gateway);
    defer init.gpa.destroy(gateway);
    gateway.init();
    try gateway.bootstrapDurableDispatch(owner.store, init.io, .{ .domain = .control, .id = 92 });
    try gateway.pinDeploymentDigest(owner.shard.deployment.header.?.expected_digest);
    var adapters = [_]dual.Adapter{ .{ .account = 20, .allows_maker = true }, .{ .account = 30, .allows_maker = true } };
    for (&adapters, legs) |*adapter, leg| try gateway.add(.{
        .account = leg.account,
        .adapter = adapter.interface(),
        .venue_identity = leg.venue,
        .environment = .simulation,
        .capability = .{ .version = 3, .rules_version = 2, .config_version = 1, .session = 1, .supports_native_amend = true, .supports_post_only = true },
        .supported_products = execution.productMask(.isolated_linear),
    });
    const hedge = 1 - maker;
    try publishTrade(owner, host, 3);
    const original = try makerPlace(owner, gateway, &adapters[maker], 7, 10000, 100, .post_only);
    try makerReport(owner, legs[maker], original, 2, .accepted, 0, 10000);
    try makerFill(owner, legs[maker], original, 3, 2000);
    try makerReport(owner, legs[maker], original, 4, .partially_filled, 2000, 8000);
    try host.pump(owner);
    const cancel = owner.shard.oms.findCommand(2) orelse return error.MissingMakerCancel;
    try std.testing.expectEqual(.cancel, cancel.operation);
    try sendMakerCommand(owner, gateway, cancel);
    const request = adapters[maker].command.?;
    try std.testing.expectEqual(.cancel, request.operation);
    try std.testing.expectEqual(original.id, request.orderIdentity());
    try std.testing.expectEqualDeep(original.client_order_id, request.client_order_id);
    try std.testing.expectEqual(@as(usize, 0), adapters[hedge].sends);
    const first_hedge = try makerPlace(owner, gateway, &adapters[hedge], 8, 2000, 100, .immediate_or_cancel);
    try makerFill(owner, legs[maker], original, 5, 1000);
    try makerReport(owner, legs[maker], original, 6, .partially_filled, 3000, 7000);
    try host.pump(owner);
    try std.testing.expectEqual(@as(u16, 3), owner.shard.oms.order_count);
    try std.testing.expectEqual(.pending_cancel, owner.shard.oms.orderById(original.id).?.state);
    const second_hedge = try makerPlace(owner, gateway, &adapters[hedge], 9, 1000, 100, .immediate_or_cancel);

    var dispatch: trading.oms.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = cancel.command_id, .state = .unknown };
    _ = try owner.apply(fixture.atGroup(50, .{ .identity = 98001, .account_scope = legs[maker].account, .payload = .{ .oms_dispatch_batch = dispatch } }));
    try host.pump(owner);
    const query = (try host.takeOrderQuery(owner)) orelse return error.MissingFormalOrderQuery;
    try owner.checkpoint();
    const restarted = try restartHost(init, path, owner, host, host_config, 10);
    defer restarted.close(init);
    const recovered_query = (try restarted.takeOrderQuery(owner)) orelse return error.MissingRecoveredFormalQuery;
    try std.testing.expectEqual(@as(u64, 7), recovered_query.first_sequence);
    try std.testing.expectEqual(@as(u64, 7), recovered_query.intent_sequence);
    try std.testing.expect(recovered_query.cursor > query.cursor);
    try std.testing.expectEqual(.accepted, try gateway.queryCycleOrder(try owner.source(), 9, 7, 7, recovered_query.cursor));
    try std.testing.expectEqual(original.id, adapters[maker].query.?.order);
    try std.testing.expectEqualDeep(try canonical.VenueOrderRef.init(legs[maker].venue, "maker-order-1"), adapters[maker].query.?.venue_order.?);
    try std.testing.expect(adapters[hedge].query == null);

    try makerReport(owner, legs[maker], original, 7, .canceled, 4000, 0);
    try restarted.pump(owner);
    try std.testing.expectEqual(@as(u16, 3), owner.shard.oms.order_count);
    try makerFill(owner, legs[maker], original, 8, 1000);
    try restarted.pump(owner);
    try std.testing.expectEqual(@as(u16, 4), owner.shard.oms.order_count);
    const late_hedge = try makerPlace(owner, gateway, &adapters[hedge], 10, 1000, 100, .immediate_or_cancel);
    for ([_]trading.oms.Order{ first_hedge, second_hedge, late_hedge }, 0..) |order, index| {
        const lots = order.quantity;
        try makerFill(owner, legs[hedge], order, 2 + 2 * index, lots);
        try makerReport(owner, legs[hedge], order, 3 + 2 * index, .filled, lots, 0);
        try restarted.pump(owner);
    }
    const replacement = try makerPlace(owner, gateway, &adapters[maker], 11, 6000, if (maker == 0) 95 else 105, .post_only);
    try std.testing.expectEqual(original.id, replacement.predecessor_order_id);
    try std.testing.expect(!std.meta.eql(replacement.client_order_id, original.client_order_id));
    try makerFill(owner, legs[maker], replacement, 9, 6000);
    try makerReport(owner, legs[maker], replacement, 10, .filled, 6000, 0);
    try restarted.pump(owner);
    const final_hedge = try makerPlace(owner, gateway, &adapters[hedge], 12, 6000, 100, .immediate_or_cancel);
    try makerFill(owner, legs[hedge], final_hedge, 8, 6000);
    try makerReport(owner, legs[hedge], final_hedge, 9, .filled, 6000, 0);
    try restarted.pump(owner);

    for (legs, 0..) |leg, index| try makerPosition(owner, leg, 11, if (index == 0) 10000 else -10000);
    try owner.checkpoint();
    try publishTrade(owner, restarted, 4);
    for (legs, 0..) |leg, index| {
        const exit = try makerPlace(owner, gateway, &adapters[index], 13 + index, 10000, 100, .immediate_or_cancel);
        try std.testing.expect(exit.portfolio_reduce_only);
        try makerFill(owner, leg, exit, 12, 10000);
        try makerReport(owner, leg, exit, 13, .filled, 10000, 0);
        try makerPosition(owner, leg, 14, 0);
        const account = owner.shard.accountState(leg.account).?;
        const layer = account.economic_projection.portfolioLayer(10).?;
        try std.testing.expectEqual(@as(i128, 0), layer.positionForInstrument(leg.instrument).quantity);
        const initial: i128 = if (index == 0) 400 else 600;
        const realized: i128 = if (index == maker) 3 else 0;
        try std.testing.expectEqual(initial - 5 + realized, layer.settlement_balance_atoms);
        try accounts.reconcileDomainAccount(owner, leg.account, gateway);
    }
    const closure = try owner.shard.qualifyCycleClosure(9, 7);
    _ = try owner.apply(.{ .core = .{ .identity = 98002, .payload = .{ .cycle_closed = closure } } });
    const recovered = try init.gpa.create(Owner);
    defer init.gpa.destroy(recovered);
    try Owner.recoverInto(recovered, owner.store, init.io, owner.stream);
    try std.testing.expectEqualDeep(owner.shard.canonicalStateDigest(), recovered.shard.canonicalStateDigest());
    std.debug.print("formal_maker: account={d} order={d} late_fill=1000 replacement=6000 hedge=10000 closed=true\n", .{ legs[maker].account, original.id });
}

fn sendMakerCommand(owner: *Owner, gateway: *execution.Gateway, command: trading.oms.Command) !void {
    const view = try std.heap.page_allocator.create(trading.TradingShard);
    defer std.heap.page_allocator.destroy(view);
    try owner.shard.copyAccountViewInto(view, command.authority.exchange_account);
    try gateway.observeAuthorityFromShard(try owner.source(), .{
        .account = command.authority.exchange_account,
        .effective_trading_authority = view.operational_state.effectiveTradingAuthority(),
        .reservation_identity = command.reservation_identity,
        .reservation = command.reservation,
        .primary_lease_expires_at_monotonic_ns = command.authority.dispatch_deadline_monotonic_ns,
        .fencing_token = owner.shard.fencing_token,
        .exchange_position = view.currentNetExchangePosition(command.instrument).?,
        .authority_barrier = owner.shard.authoritativeBarrier(),
    });
    try std.testing.expectEqual(.accepted, try gateway.sendFromShard(try owner.source(), command.command_id, command.authority.dispatch_deadline_monotonic_ns - std.time.ns_per_ms));
}

fn makerPosition(owner: *Owner, leg: pair.Leg, sequence: u64, lots: i64) !void {
    const account = owner.shard.accountState(leg.account).?;
    try applyMakerFact(owner, leg, sequence, .{ .account_observed = .{
        .identity = sequence,
        .exchange_account = leg.account,
        .bootstrap = account.canonical_account.bootstrap.?,
        .source_stream = account.canonical_account.source_stream.?,
        .source_sequence = account.canonical_account.last_sequence + 1,
        .value = .{ .position = .{ .instrument = leg.instrument, .side = .net, .value = .{
            .instrument = leg.instrument,
            .side = .net,
            .quantity = .{ .instrument = leg.instrument, .rules_version = 2, .lots = lots },
        } } },
    } });
}

fn makerPlace(owner: *Owner, gateway: *execution.Gateway, adapter: *dual.Adapter, intent: u64, lots: i64, ticks: i128, tif: canonical.TimeInForce) !trading.oms.Order {
    const place = try owner.shard.cycleOrderCommand(9, 7, intent);
    try sendMakerCommand(owner, gateway, place);
    const wire = adapter.command.?;
    try std.testing.expectEqual(place.order_id, wire.orderIdentity());
    try std.testing.expectEqual(tif, wire.time_in_force);
    try std.testing.expectEqual(lots, wire.quantity.?.lots);
    try std.testing.expectEqual(ticks, wire.limit_price.?.ticks);
    return owner.shard.oms.orderById(place.order_id).?;
}

fn makerReport(owner: *Owner, leg: pair.Leg, order: trading.oms.Order, sequence: u64, status: canonical.ExecutionReportStatus, cumulative: i64, remaining: i64) !void {
    try applyMakerFact(owner, leg, sequence, .{ .execution_report = .{
        .identity = sequence,
        .order = order.id,
        .client_order_id = order.client_order_id,
        .instrument = leg.instrument,
        .exchange_account = leg.account,
        .revision = order.revision,
        .status = status,
        .cumulative_quantity = .{ .instrument = leg.instrument, .rules_version = 2, .lots = cumulative },
        .remaining_quantity = .{ .instrument = leg.instrument, .rules_version = 2, .lots = remaining },
    } });
}

fn makerFill(owner: *Owner, leg: pair.Leg, order: trading.oms.Order, sequence: u64, lots: i64) !void {
    var storage: [64]u8 = undefined;
    var trade_storage: [64]u8 = undefined;
    const at: u64 = @intCast(std.Io.Clock.real.now(owner.io).nanoseconds);
    try applyMakerFact(owner, leg, sequence, .{ .fill = .{
        .identity = sequence,
        .order = order.id,
        .client_order_id = order.client_order_id,
        .venue_order = try canonical.VenueOrderRef.init(leg.venue, try std.fmt.bufPrint(&storage, "maker-order-{d}", .{order.id})),
        .venue_trade = try canonical.VenueTradeRef.init(leg.venue, try std.fmt.bufPrint(&trade_storage, "maker-trade-{d}", .{sequence})),
        .instrument = leg.instrument,
        .exchange_account = leg.account,
        .side = if (order.side == .buy) .buy else .sell,
        .quantity = .{ .instrument = leg.instrument, .rules_version = 2, .lots = lots },
        .price = order.limit_price,
        .fee = .{ .asset = if (leg.account == 20) 1 else 3, .atoms = 1 },
        .liquidity = if (order.time_in_force == .post_only) .maker else .taker,
        .venue_fill_time_utc_ns = at,
    } });
}

fn applyMakerFact(owner: *Owner, leg: pair.Leg, sequence: u64, data: canonical.Payload) !void {
    var fact = fixture.canonicalAt(50, sequence, data);
    fact.venue.envelope.exchange_account = leg.account;
    fact.venue.envelope.venue = leg.venue;
    const at: u64 = @intCast(std.Io.Clock.real.now(owner.io).nanoseconds);
    fact.venue.envelope.times.source_utc_ns = at;
    fact.venue.envelope.times.receive_utc_ns = at;
    fact.venue.envelope.times.audit_utc_ns = at;
    _ = try owner.apply(fact);
}

fn exerciseQuery(init: std.process.Init, path: []const u8, owner: *Owner, host: *formal.Host, host_config: formal.Config, remote: ?*RemoteGateway) !void {
    const gateway_role = @import("../../runtime/production_gateway.zig").GatewayRole;
    var dispatch: trading.oms.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = 2, .state = .unknown };
    _ = try owner.apply(fixture.atGroup(50, .{ .identity = 98001, .account_scope = 30, .payload = .{ .oms_dispatch_batch = dispatch } }));
    try host.pump(owner);
    const query = (try host.takeOrderQuery(owner)) orelse return error.MissingFormalOrderQuery;
    try std.testing.expectEqual(@as(u64, 7), query.first_sequence);
    try std.testing.expectEqual(@as(u64, 8), query.intent_sequence);
    const restarted = try restartHost(init, path, owner, host, host_config, 9);
    defer restarted.close(init);
    const recovered_query = (try restarted.takeOrderQuery(owner)) orelse return error.MissingRecoveredFormalQuery;
    try std.testing.expectEqual(query.first_sequence, recovered_query.first_sequence);
    try std.testing.expectEqual(query.intent_sequence, recovered_query.intent_sequence);
    try std.testing.expect(recovered_query.cursor > query.cursor);
    try std.testing.expectEqual(null, try host.takeOrderQuery(owner));
    var root = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    defer root.close(init.io);
    const storage = try init.gpa.alloc(u8, durable.max_snapshot_bytes);
    defer init.gpa.free(storage);
    const snapshot = try owner.committedSnapshot(storage);
    if (builtin.os.tag == .linux and remote != null) {
        const process = remote.?;
        try commitUnresolvedQuery(owner, recovered_query.cursor, try process.queryOrder(init.io, snapshot, recovered_query));
        try process.settleOrderQuery(init.io, try owner.committedSnapshot(storage), recovered_query);
    } else {
        var config: [256]u8 = undefined;
        try root.writeFile(init.io, .{ .sub_path = "gateway.json", .data = try std.fmt.bufPrint(&config, "{{\"environment\":\"simulation\",\"deployment_digest\":\"{s}\",\"dispatch_stream\":92,\"initialize_dispatch\":true}}", .{std.fmt.bytesToHex(owner.shard.deployment.header.?.expected_digest, .lower)}) });
        const gateway = (try gateway_role.open(init, root, path)) orelse return error.GatewayUnavailable;
        defer gateway.close(init);
        try commitUnresolvedQuery(owner, recovered_query.cursor, try gateway.queryCycleOrder(init.io, snapshot, recovered_query));
        try gateway.settleCycleQuery(try owner.committedSnapshot(storage), recovered_query);
    }
    try restarted.pump(owner);
    try std.testing.expectEqual(null, try restarted.takeOrderQuery(owner));
    try std.testing.expectEqual(.unknown, owner.shard.oms.orderById(2).?.state);
    try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.order_count);
    std.debug.print("formal_ioc_query: cycle=7 intent=8 order=2 status=unresolved orders=2\n", .{});
}

fn restartHost(init: std.process.Init, path: []const u8, owner: *Owner, host: *formal.Host, host_config: formal.Config, next_intent_sequence: u64) !*formal.Host {
    var root = try std.Io.Dir.openDirAbsolute(init.io, path, .{});
    defer root.close(init.io);
    var checkpoint_storage: [8192]u8 = undefined;
    const metadata: @import("../../strategy/strategy_host_recovery.zig").Metadata = .{
        .schema_registry = host.gateway.config.schema_registry,
        .strategy_instance = 9,
        .strategy_definition = 42,
        .state_schema = 61,
        .state_schema_version = 1,
        .strategy_config_version = 1,
        .strategy_cursor = host.cursor,
        .next_intent_sequence = next_intent_sequence,
    };
    try host.process.requestCheckpoint(init.io, 2, metadata);
    const checkpoint = try host.process.receiveCheckpoint(init.io, &checkpoint_storage);
    try root.writeFile(init.io, .{ .sub_path = "checkpoint.bin", .data = checkpoint });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(checkpoint, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    var restart_config = host_config;
    restart_config.checkpoint_sha256 = &digest_hex;
    try engine.revokeHosts(owner);
    return formal.Host.start(init, owner, 2, restart_config);
}

fn commitUnresolvedQuery(owner: *Owner, query_cursor: u64, batch: canonical.AdapterOutputBatch) !void {
    try std.testing.expectEqual(@as(u8, 2), batch.len);
    const result = batch.events[1].event.order_reconciliation_result;
    try std.testing.expectEqual(@as(u128, query_cursor), result.identity);
    try std.testing.expectEqual(.unresolved, result.status);
    try owner.applyAdapterBatch(batch);
}

fn runPython(init: std.process.Init, argv: []const []const u8) !void {
    const result = try std.process.run(init.gpa, init.io, .{ .argv = argv });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    if (result.term != .exited or result.term.exited != 0) return error.StrategyFixtureFailed;
}

const RemoteGateway = struct {
    child: std.process.Child,
    stream: std.Io.net.Stream,

    fn queryOrder(self: *RemoteGateway, io: std.Io, snapshot: []const u8, query: @import("../../strategy/strategy_host_gateway.zig").OrderQuery) !canonical.AdapterOutputBatch {
        try self.sendQuery(io, 'Z', snapshot, query);
        return @import("../support/linux_role_business.zig").readBatch(self.stream, io);
    }

    fn settleOrderQuery(self: *RemoteGateway, io: std.Io, snapshot: []const u8, query: @import("../../strategy/strategy_host_gateway.zig").OrderQuery) !void {
        try self.sendQuery(io, 'K', snapshot, query);
        var bytes: [1]u8 = undefined;
        var reader = self.stream.reader(io, &bytes);
        if (try reader.interface.takeByte() != 'K') return error.InvalidQuerySettlement;
    }

    fn sendQuery(self: *RemoteGateway, io: std.Io, command: u8, snapshot: []const u8, query: @import("../../strategy/strategy_host_gateway.zig").OrderQuery) !void {
        var output = self.stream.writer(io, &.{});
        try output.interface.writeByte(command);
        try output.interface.writeInt(u128, query.strategy, .little);
        for ([_]u64{ query.first_sequence, query.intent_sequence, query.cursor }) |value|
            try output.interface.writeInt(u64, value, .little);
        try output.interface.writeInt(u32, @intCast(snapshot.len), .little);
        try output.interface.writeAll(snapshot);
        try output.interface.flush();
    }

    fn start(init: std.process.Init, executable: []const u8, state: []const u8, digest: [32]u8) !RemoteGateway {
        const io = init.io;
        var dir_path: [2048]u8 = undefined;
        const path = try std.fmt.bufPrint(&dir_path, "{s}/gateway", .{state});
        try std.Io.Dir.cwd().createDir(io, path, @enumFromInt(0o700));
        var dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
        defer dir.close(io);
        var config: [256]u8 = undefined;
        try dir.writeFile(io, .{ .sub_path = "gateway.json", .data = try std.fmt.bufPrint(&config, "{{\"environment\":\"simulation\",\"deployment_digest\":\"{s}\",\"dispatch_stream\":92,\"initialize_dispatch\":true,\"ioc_fee_atoms\":10,\"reducing_ioc_rebate_atoms\":4}}", .{std.fmt.bytesToHex(digest, .lower)}) });
        var socket_path: [2048]u8 = undefined;
        const socket = try std.fmt.bufPrint(&socket_path, "{s}/g.sock", .{path});
        var child = try std.process.spawn(io, .{
            .argv = &.{ executable, "--production-role", "execution_gateway", "--socket", socket, "--state-dir", path },
        });
        errdefer child.kill(io);
        const address = try std.Io.net.UnixAddress.init(socket);
        for (0..200) |_| {
            const stream = address.connect(io) catch {
                try io.sleep(.fromMilliseconds(20), .awake);
                continue;
            };
            errdefer stream.close(io);
            var buffer: [8]u8 = undefined;
            var reader = stream.reader(io, &buffer);
            if (!std.mem.eql(u8, try reader.interface.take(2), "HR")) return error.GatewayUnavailable;
            return .{ .child = child, .stream = stream };
        }
        return error.GatewayUnavailable;
    }

    fn close(self: *RemoteGateway, io: std.Io) void {
        self.stream.close(io);
        self.child.kill(io);
    }

    fn finish(self: *RemoteGateway, io: std.Io) !void {
        var buffer: [8]u8 = undefined;
        var reader = self.stream.reader(io, &buffer);
        var writer = self.stream.writer(io, &.{});
        try writer.interface.writeByte('D');
        try writer.interface.flush();
        try std.testing.expectEqual(@as(u8, 'G'), try reader.interface.takeByte());
        try writer.interface.writeByte('S');
        try writer.interface.flush();
        try std.testing.expectEqual(@as(u8, 'T'), try reader.interface.takeByte());
        const termination = try self.child.wait(io);
        try std.testing.expect(termination == .exited and termination.exited == 0);
    }

    fn fillPair(self: *RemoteGateway, gpa: std.mem.Allocator, owner: *Owner, legs: [2]@import("../../trading/pair_trading_authorization.zig").Leg, reducing: bool) !void {
        const business = @import("../support/linux_role_business.zig");
        const storage = try gpa.alloc(u8, durable.max_snapshot_bytes);
        defer gpa.free(storage);
        const first: u64 = if (reducing) 3 else 1;
        for (legs, 0..) |leg, index| {
            const order = owner.shard.oms.orderById(first + index).?;
            const snapshot = try owner.committedSnapshot(storage);
            var writer = self.stream.writer(owner.io, &.{});
            try writer.interface.writeByte('Y');
            try writer.interface.writeInt(u64, first + index, .little);
            try writer.interface.writeInt(u32, @intCast(snapshot.len), .little);
            try writer.interface.writeAll(snapshot);
            try writer.interface.flush();
            const batch = try business.readBatch(self.stream, owner.io);
            var lots: i128 = 0;
            var sequence: u64 = 0;
            for (batch.slice()) |record| {
                try std.testing.expectEqual(leg.venue, record.envelope.venue);
                try std.testing.expectEqual(@as(?u128, leg.account), record.envelope.exchange_account);
                sequence = record.envelope.identity.sequence;
                if (record.event == .fill) {
                    const fill = record.event.fill;
                    try std.testing.expectEqual(order.id, fill.order);
                    try std.testing.expectEqual(leg.instrument, fill.instrument);
                    try std.testing.expectEqualDeep(order.limit_price, fill.price);
                    try std.testing.expectEqual(@as(canonical.OrderSide, if (order.side == .buy) .buy else .sell), fill.side);
                    lots += fill.quantity.lots;
                }
            }
            try std.testing.expectEqual(@as(i128, 10000), lots);
            owner.applyAdapterBatch(batch) catch |err| {
                std.debug.print("routed receipt commit command={d} barrier={d}: {s}\n", .{ first + index, owner.shard.authoritativeBarrier(), @errorName(err) });
                return err;
            };
            const state = owner.shard.accountState(leg.account).?;
            const position: i64 = if (reducing) 0 else if (index == 0) 10000 else -10000;
            try std.testing.expectEqual(position, state.economic_projection.portfolioLayer(10).?.positionForInstrument(leg.instrument).quantity);
            var observed = fixture.canonicalAt(54, sequence + 1, .{ .account_observed = .{
                .identity = order.id,
                .exchange_account = leg.account,
                .bootstrap = state.canonical_account.bootstrap.?,
                .source_stream = state.canonical_account.source_stream.?,
                .source_sequence = state.canonical_account.last_sequence + 1,
                .value = .{ .position = .{ .instrument = leg.instrument, .side = .net, .value = .{
                    .instrument = leg.instrument,
                    .side = .net,
                    .quantity = .{ .instrument = leg.instrument, .rules_version = leg.rules_version, .lots = position },
                } } },
            } });
            observed.venue.envelope.times = batch.slice()[batch.len - 1].envelope.times;
            observed.venue.envelope.exchange_account = leg.account;
            observed.venue.envelope.venue = leg.venue;
            _ = try owner.apply(observed);
        }
    }
};

fn approveFromWeb(init: std.process.Init, owner: *Owner, python: []const u8, path: []const u8) !void {
    var web = try std.process.spawn(init.io, .{
        .argv = &.{ python, "python/verify_production_strategy_chain.py", "--approve-dual-ioc", path },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer web.kill(init.io);
    const input = try init.gpa.alloc(u8, engine.max_authority_bytes);
    defer init.gpa.free(input);
    var reader = web.stdout.?.reader(init.io, input);
    var output: [1024]u8 = undefined;
    var writer = web.stdin.?.writer(init.io, &output);
    while (true) {
        const operation = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const size = try reader.interface.takeInt(u32, .little);
        if (size == 0 or size > input.len) return error.InvalidAuthorityFrame;
        const request = try reader.interface.take(size);
        const response = try switch (operation) {
            'P' => engine.readStrategyAuthority(owner, init.gpa, request, null),
            'Q' => engine.changePairApproval(owner, init.gpa, request),
            else => error.InvalidAuthorityFrame,
        };
        defer init.gpa.free(response);
        try writer.interface.writeInt(u32, @intCast(response.len), .little);
        try writer.interface.writeAll(response);
        try writer.interface.flush();
    }
    const terminated = try web.wait(init.io);
    if (terminated != .exited or terminated.exited != 0) return error.WebApprovalFixtureFailed;
}

fn scopeInstrument(input: *trading.CanonicalEvent, instrument: u128, venue: u64, stream: u64) void {
    input.venue.envelope.scope = .instrument;
    input.venue.envelope.exchange_account = null;
    input.venue.envelope.instrument = instrument;
    input.venue.envelope.venue = venue;
    input.venue.envelope.identity.stream = stream;
    input.venue.envelope.source_stream = stream;
}

fn publishTrade(owner: *Owner, host: *formal.Host, step: u64) !void {
    const at = fixture.atGroup(45 + step, .{ .identity = 0, .payload = .recovery_completed }).core.source_time;
    var trade = fixture.canonicalAt(45 + step, step, .{ .market_trade = .{
        .instrument = 101,
        .trade_identity = step,
        .price = .{ .instrument = 101, .rules_version = 2, .ticks = 100 },
        .quantity = .{ .instrument = 101, .rules_version = 2, .lots = 1 },
        .side = .buy,
        .source_time_utc_ns = at,
    } });
    scopeInstrument(&trade, 101, 1, 9000);
    _ = try owner.apply(trade);
    try host.pump(owner);
    try std.testing.expectEqual(owner.shard.authoritativeBarrier(), host.cursor);
}

fn fillPair(gpa: std.mem.Allocator, owner: *Owner, gateway: *execution.Gateway, adapters: *[2]dual.Adapter, legs: [2]@import("../../trading/pair_trading_authorization.zig").Leg, reducing: bool) !void {
    const view = try gpa.create(trading.TradingShard);
    defer gpa.destroy(view);
    const first: u64 = if (reducing) 3 else 1;
    for (legs, 0..) |leg, index| {
        const id = first + index;
        const command = owner.shard.oms.findCommand(id).?;
        try owner.shard.copyAccountViewInto(view, leg.account);
        try gateway.observeAuthorityFromShard(&owner.shard, .{
            .account = leg.account,
            .effective_trading_authority = view.operational_state.effectiveTradingAuthority(),
            .reservation_identity = command.reservation_identity,
            .reservation = command.reservation,
            .primary_lease_expires_at_monotonic_ns = command.authority.dispatch_deadline_monotonic_ns,
            .fencing_token = owner.shard.fencing_token,
            .exchange_position = view.currentNetExchangePosition(leg.instrument).?,
            .authority_barrier = owner.shard.authoritativeBarrier(),
        });
        try std.testing.expectEqual(@import("../../execution/venue_adapter.zig").SendResult.accepted, try gateway.sendFromShard(&owner.shard, id, command.authority.dispatch_deadline_monotonic_ns - std.time.ns_per_ms));
    }
    for (adapters, legs, 0..) |adapter, leg, index| {
        const order = owner.shard.oms.orderById(first + index).?;
        const command = adapter.command.?;
        try std.testing.expectEqual(order.id, command.orderIdentity());
        try std.testing.expectEqualDeep(order.client_order_id, command.client_order_id);
        try std.testing.expectEqual(leg.account, command.exchange_account);
        try std.testing.expectEqual(leg.instrument, command.instrument);
        try std.testing.expectEqual(@as(i128, 100), command.limit_price.?.ticks);
        try std.testing.expectEqual(@as(i64, 10000), command.quantity.?.lots);
        try std.testing.expectEqual(@as(canonical.OrderSide, if ((index == 0) != reducing) .buy else .sell), command.side);
        const asset: u64 = if (index == 0) 1 else 3;
        const sequence: u64 = if (reducing) 5 else 2;
        const group: u64 = if (reducing) 54 else 50;
        var fill = fixture.canonicalAt(group, sequence, .{ .fill = .{
            .identity = order.id,
            .order = order.id,
            .client_order_id = order.client_order_id,
            .venue_order = try canonical.VenueOrderRef.init(leg.venue, if (reducing) "exit" else "entry"),
            .venue_trade = try canonical.VenueTradeRef.init(leg.venue, if (reducing) "exit-fill" else "entry-fill"),
            .instrument = leg.instrument,
            .exchange_account = leg.account,
            .side = command.side,
            .quantity = command.quantity.?,
            .price = command.limit_price.?,
            .fee = .{ .asset = asset, .atoms = if (reducing) 0 else 10 },
            .rebate = if (reducing) .{ .asset = asset, .atoms = 4 } else null,
            .liquidity = .taker,
            .venue_fill_time_utc_ns = fixture.atGroup(group, .{ .identity = 0, .payload = .recovery_completed }).core.source_time,
        } });
        fill.venue.envelope.exchange_account = leg.account;
        fill.venue.envelope.venue = leg.venue;
        const at: u64 = @intCast(std.Io.Clock.real.now(owner.io).nanoseconds);
        fill.venue.envelope.times.source_utc_ns = at;
        fill.venue.envelope.times.receive_utc_ns = at;
        fill.venue.envelope.times.audit_utc_ns = at;
        fill.venue.event.fill.venue_fill_time_utc_ns = at;
        _ = try owner.apply(fill);
        var report = fixture.canonicalAt(group, sequence + 1, .{ .execution_report = .{
            .identity = order.id,
            .order = order.id,
            .client_order_id = order.client_order_id,
            .instrument = leg.instrument,
            .exchange_account = leg.account,
            .revision = 1,
            .status = .filled,
            .cumulative_quantity = command.quantity.?,
            .remaining_quantity = .{ .instrument = leg.instrument, .rules_version = 2, .lots = 0 },
        } });
        report.venue.envelope.exchange_account = leg.account;
        report.venue.envelope.venue = leg.venue;
        report.venue.envelope.times = fill.venue.envelope.times;
        _ = try owner.apply(report);
        const layer = owner.shard.accountState(leg.account).?.economic_projection.portfolioLayer(10).?;
        const position: i64 = if (reducing) 0 else if (index == 0) 10000 else -10000;
        try std.testing.expectEqual(position, layer.positionForInstrument(leg.instrument).quantity);
        try owner.shard.copyAccountViewInto(view, leg.account);
        var observed = fixture.canonicalAt(group, sequence + 2, .{ .account_observed = .{
            .identity = order.id,
            .exchange_account = leg.account,
            .bootstrap = view.canonical_account.bootstrap.?,
            .source_stream = view.canonical_account.source_stream.?,
            .source_sequence = view.canonical_account.last_sequence + 1,
            .value = .{ .position = .{
                .instrument = leg.instrument,
                .side = .net,
                .value = .{
                    .instrument = leg.instrument,
                    .side = .net,
                    .quantity = .{ .instrument = leg.instrument, .rules_version = 2, .lots = position },
                },
            } },
        } });
        observed.venue.envelope.exchange_account = leg.account;
        observed.venue.envelope.venue = leg.venue;
        _ = try owner.apply(observed);
    }
}
