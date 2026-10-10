//! Ticket 04: offline seam fixtures; these four routes do not qualify online protocols.
const std = @import("std");
const trading = @import("trading_shard.zig");
const demo = @import("demo_authority.zig");
const durable = @import("durable_store.zig");
const canonical = @import("canonical_event.zig");
const market = @import("market_feed_adapter.zig");
const venue = @import("venue_adapter.zig");
const execution = @import("execution_gateway.zig");
const fixture = @import("trading_shard_fixture.zig");
const assets = @import("asset_registry.zig");
const host = @import("strategy_host_gateway.zig");
const venues = [_]canonical.VenueIdentity{ 1, 21, 42, 84 };
const cash: i128 = 25_000_000_000;

// Keep the large in-memory archive initializer outside the acceptance frame.
noinline fn initializeStore(store: *durable.MemoryAdapter) void {
    store.* = .init();
}

fn instrument(route: usize, index: usize) u128 {
    return (@as(u128, venues[route]) << 64) | (@as(u128, if (index < 75) 1 else 2) << 32) | (1000 + index % 75);
}
fn selected(index: usize) bool {
    return index < 16 or (index >= 75 and index < 91);
}
fn tick(index: usize) i128 {
    return @intCast(100 + index);
}
fn askTicks(index: usize) i128 {
    return @as(i128, @intCast(2 + index)) * priceStep(index);
}
fn priceStep(index: usize) i128 {
    return if (index < 75) 100_000_000 else 10_000;
}
fn product(index: usize) canonical.Product {
    return if (index < 75) .spot else .isolated_linear_usdt;
}

const Source = struct {
    venue_identity: canonical.VenueIdentity,
    account: u128 = 0,
    stream: u128,
    sequence: u64 = 0,
    pending: ?canonical.AdapterOutputBatch = null,
    fn emit(self: *Source, payload: canonical.Payload, target: u128) !void {
        if (self.pending != null) return error.OutputPending;
        self.sequence += 1;
        var record = fixture.canonicalAt(self.sequence, self.sequence, payload).venue;
        record.envelope.venue = self.venue_identity;
        record.envelope.exchange_account = if (self.account == 0) null else self.account;
        record.envelope.scope = if (self.account == 0) .instrument else .account;
        record.envelope.instrument = if (target == 0) null else target;
        record.envelope.identity.stream = self.stream;
        record.envelope.source_stream = self.stream;
        record.envelope.raw_evidence.stream = self.stream;
        var batch: canonical.AdapterOutputBatch = .{};
        try batch.append(record);
        self.pending = batch;
    }
    fn take(self: *Source) ?canonical.AdapterOutputBatch {
        const batch = self.pending;
        self.pending = null;
        return batch;
    }
};

const OfflineFeed = struct {
    source: Source,
    started: bool = false,
    fn adapter(self: *@This()) market.MarketFeedAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_drain = drain, .stop = stop } };
    }
    fn start(ptr: *anyopaque, config: market.Config) market.StartError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.started) return error.AlreadyStarted;
        if (config.venue != self.source.venue_identity or config.environment != .simulation) return error.InvalidConfig;
        self.started = true;
    }
    fn drain(ptr: *anyopaque) market.DrainError!?canonical.AdapterOutputBatch {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        return self.source.take();
    }
    fn stop(ptr: *anyopaque, _: market.DrainDeadline) market.StopError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.source.pending != null) return error.OutputPending;
        self.started = false;
    }
};

const RestingVenue = struct {
    source: Source,
    sends: usize = 0,
    started: bool = false,
    order_clients: [64]canonical.ClientOrderId = undefined,
    order_count: u8 = 0,
    fn adapter(self: *@This()) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.started) return error.AlreadyStarted;
        if (config.venue != self.source.venue_identity or config.exchange_account != self.source.account or config.environment != .simulation) return error.InvalidConfig;
        self.started = true;
    }
    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        if (request != .order_command or self.source.pending != null) return error.InvalidRequest;
        const command = request.order_command;
        if (command.exchange_account != self.source.account) return error.InvalidRequest;
        const order = if (command.operation == .place) value: {
            if (self.order_count == self.order_clients.len) return error.InvalidRequest;
            self.order_clients[self.order_count] = command.client_order_id;
            self.order_count += 1;
            break :value self.order_count;
        } else value: {
            for (self.order_clients[0..self.order_count], 0..) |client, index|
                if (std.meta.eql(client, command.client_order_id)) break :value @as(u8, @intCast(index + 1));
            return error.InvalidRequest;
        };
        const qty = command.quantity orelse if (command.operation == .cancel)
            canonical.InstrumentQuantity{ .instrument = command.instrument, .rules_version = command.rules_version, .lots = 0 }
        else
            return error.InvalidRequest;
        self.source.emit(.{ .execution_report = .{
            .identity = self.source.sequence + 1,
            .order = order,
            .client_order_id = command.client_order_id,
            .instrument = command.instrument,
            .exchange_account = command.exchange_account,
            .revision = command.revision,
            .side = command.side,
            .status = if (command.operation == .cancel) .canceled else .accepted,
            .cumulative_quantity = .{ .instrument = command.instrument, .rules_version = command.rules_version, .lots = 0 },
            .remaining_quantity = .{ .instrument = command.instrument, .rules_version = command.rules_version, .lots = if (command.operation == .cancel) 0 else qty.lots },
        } }, command.instrument) catch return error.InvalidRequest;
        self.sends += 1;
        return .accepted;
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        return self.source.take();
    }
    fn stop(ptr: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.source.pending != null) return error.OutputPending;
        self.started = false;
    }
};

fn maintain(owner: *demo.Owner) !void {
    if (owner.ready and owner.shard.trace.len >= 216) try owner.checkpoint();
}
fn apply(owner: *demo.Owner, payload: trading.CorePayload, identity: u64) !?trading.OrderCommand {
    try maintain(owner);
    return owner.apply(.{ .core = .{ .identity = identity, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = payload } });
}
fn public(owner: *demo.Owner, feed: *OfflineFeed, payload: canonical.Payload, target: u128) !void {
    try maintain(owner);
    try feed.source.emit(payload, target);
    try owner.applyAdapterBatch((try feed.adapter().tryDrain()).?);
}
fn private(owner: *demo.Owner, adapter: *RestingVenue, payload: canonical.Payload) !void {
    try maintain(owner);
    try adapter.source.emit(payload, 0);
    try owner.applyAdapterBatch((try adapter.adapter().tryDrain()).?);
}
fn snapshot(owner: *demo.Owner, feed: *OfflineFeed, route: usize, index: usize, sequence: u64) !void {
    const id = instrument(route, index);
    try public(owner, feed, .{ .l2_book_snapshot = .{
        .instrument = id,
        .sequence = sequence,
        .best_bid = .{ .instrument = id, .rules_version = 1, .ticks = askTicks(index) - priceStep(index) },
        .best_ask = .{ .instrument = id, .rules_version = 1, .ticks = askTicks(index) },
        .best_bid_quantity = .{ .instrument = id, .rules_version = 1, .lots = 1000 + index },
        .best_ask_quantity = .{ .instrument = id, .rules_version = 1, .lots = 2000 + index },
    } }, id);
}
fn capability(route: usize, index: usize) @import("trading_shard_event.zig").CapabilityProfileActivation {
    return .{ .exchange_account = 100 + route, .instrument = instrument(route, index), .venue = venues[route], .environment = .simulation, .product = product(index), .version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .max_dispatch_age_ns = 1_000_000, .supports_place = true, .supports_cancel = true, .supports_native_amend = false, .supports_venue_reduce_only = true, .supports_post_only = false, .supports_market_protection = false };
}
fn intent(owner: *const demo.Owner, route: usize, index: usize, sequence: u64) host.OrderIntent {
    return .{ .strategy_identity = 1, .intent_sequence = sequence, .strategy_cursor = owner.shard.authoritativeBarrier(), .config_version = 1, .activation_identity = 1, .portfolio_identity = 1, .exchange_account_identity = 100 + route, .instrument_identity = instrument(route, index), .side = .buy, .order_type = .limit, .time_in_force = .good_til_canceled, .portfolio_reduce_only = false, .quantity = 100, .limit_price_micros = @intCast(askTicks(index) * tick(index)) };
}
fn toggle(owner: *demo.Owner, route: usize, index: usize, enabled: bool, identity: u64) !void {
    _ = try apply(owner, .{ .instrument_trading_authorization = .{
        .exchange_account = 100 + route,
        .instrument = instrument(route, index),
        .strategy_activation_identity = 1,
        .config_version = 1,
        .expected_version = owner.shard.instrument_registry.get(instrument(route, index)).?.trading_version,
        .enabled = enabled,
    } }, identity);
}
fn dispatch(owner: *demo.Owner, gateway: *execution.Gateway, adapter: *RestingVenue, command: trading.OrderCommand) !void {
    const pos = owner.shard.currentNetExchangePosition(command.instrument) orelse return error.MissingAccountPosition;
    try gateway.observeAuthority(.{ .account = owner.shard.exchange_account_identity, .effective_trading_authority = owner.shard.operational_state.effectiveTradingAuthority(), .reservation_identity = command.reservation_identity, .reservation = command.reservation, .primary_lease_expires_at_monotonic_ns = std.math.maxInt(u64), .fencing_token = 1, .exchange_position = pos, .authority_barrier = owner.shard.authoritativeBarrier() });
    const result = gateway.sendFromShard(try owner.source(), command.command_id, 2) catch |err| {
        std.debug.print("observation_dispatch: instrument={d} command={d} operation={s} error={s}\n", .{ command.instrument, command.command_id, @tagName(command.operation), @errorName(err) });
        return err;
    };
    try std.testing.expectEqual(venue.SendResult.accepted, result);
    try maintain(owner);
    try owner.applyAdapterBatch((try adapter.adapter().tryDrain()).?);
}

fn partialFill(owner: *demo.Owner, adapter: *RestingVenue, command: trading.OrderCommand, route: usize, index: usize) !void {
    var reference: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&reference, "observation-{d}", .{index});
    const fill: canonical.Payload = .{ .fill = .{
        .identity = adapter.source.sequence + 1,
        .order = command.order_id,
        .client_order_id = command.client_order_id,
        .venue_order = try canonical.VenueOrderRef.init(venues[route], text),
        .venue_trade = try canonical.VenueTradeRef.init(venues[route], text),
        .instrument = command.instrument,
        .exchange_account = 100 + route,
        .side = .buy,
        .quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = 10 },
        .price = .{ .instrument = command.instrument, .rules_version = 1, .ticks = askTicks(index) },
        .fee = if (index == 1) .{ .asset = 1000, .atoms = 1 } else .{ .asset = 1, .atoms = 0 },
        .liquidity = .taker,
    } };
    try private(owner, adapter, fill);
    const economic = &owner.shard.economic_projection;
    try std.testing.expectEqual(@as(i64, 10), economic.portfolio.positionForInstrument(command.instrument).quantity);
    try std.testing.expectEqual(@as(i64, 10), economic.exchange.positionForInstrument(command.instrument).quantity);
    if (index < 75) try std.testing.expectEqual(@as(i128, 10 * (1 + index % 3)), economic.portfolio.spotInventoryAtoms(1000 + index));
    if (index == 1) {
        try std.testing.expectEqual(@as(i128, 9), economic.portfolio.spotInventoryAtoms(1000));
        try std.testing.expectEqual(@as(i128, 9), economic.exchange.spotInventoryAtoms(1000));
        const transactions = economic.ledger_count;
        try private(owner, adapter, fill);
        try std.testing.expectEqual(transactions, owner.shard.economic_projection.ledger_count);
        try std.testing.expectEqual(@as(i128, 9), owner.shard.economic_projection.portfolio.spotInventoryAtoms(1000));
        try std.testing.expectEqual(@as(i64, 10), owner.shard.economic_projection.portfolio.positionForInstrument(command.instrument).quantity);
    }
}

test "Observation capacity public fifth instrument configuration precedes 500 combination acceptance" {
    const allocator = std.testing.allocator;
    const shard = try allocator.create(trading.TradingShard);
    defer allocator.destroy(shard);
    shard.* = .{};
    for (0..5) |index| _ = try shard.apply(.{ .core = .{ .identity = index + 1, .payload = .{ .instrument_rules_activated = .{
        .version = 1,
        .instrument_identity = instrument(0, index),
        .quantity_denominator = 100_000_000,
        .reservation_model = .cash,
        .product = .spot,
        .venue = 1,
        .base_asset = 1000 + index,
    } } } });
    try std.testing.expectEqual(@as(u8, 5), shard.instrument_registry.count);
}

test "Observation capacity account Venue scope rejects fresh and duplicate public facts without mutation" {
    const allocator = std.testing.allocator;
    const run = try allocator.create(fixture.LiveRun);
    defer allocator.destroy(run);
    run.* = try fixture.startScenario();
    const amount: canonical.AssetAmount = .{ .asset = 1, .atoms = cash };
    const zero: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
    var bootstrap: canonical.AccountBootstrapSnapshot = .{
        .identity = 1,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 1,
        .source_sequence = 1,
        .balance_count = 1,
        .position_count = 0,
        .margin_count = 0,
    };
    bootstrap.balances[0] = .{ .asset = 1, .total = amount, .available = amount, .held = zero };
    const accepted = fixture.canonicalAt(20, 1, .{ .account_bootstrap_snapshot = bootstrap });
    _ = try run.shard.apply(accepted);
    const updated: canonical.AssetAmount = .{ .asset = 1, .atoms = cash - 1 };
    var balance_update = fixture.canonicalAt(21, 2, .{ .account_observed = .{
        .identity = 2,
        .exchange_account = 2,
        .bootstrap = 1,
        .source_stream = 1,
        .source_sequence = 2,
        .value = .{ .balance = .{ .asset = 1, .value = .{
            .asset = 1,
            .total = updated,
            .available = updated,
            .held = zero,
        } } },
    } });
    balance_update.venue.envelope.scope = .asset;
    balance_update.venue.envelope.asset = 1;
    _ = try run.shard.apply(balance_update);
    var position_update = fixture.canonicalAt(22, 3, .{ .account_observed = .{
        .identity = 3,
        .exchange_account = 2,
        .bootstrap = 1,
        .source_stream = 1,
        .source_sequence = 3,
        .value = .{ .position = .{ .instrument = fixture.swap_instrument, .side = .net, .value = .{
            .instrument = fixture.swap_instrument,
            .side = .net,
            .quantity = .{ .instrument = fixture.swap_instrument, .rules_version = 1, .lots = 7 },
        } } },
    } });
    position_update.venue.envelope.scope = .instrument;
    position_update.venue.envelope.instrument = fixture.swap_instrument;
    _ = try run.shard.apply(position_update);
    var margin_update = fixture.canonicalAt(23, 4, .{ .account_observed = .{
        .identity = 4,
        .exchange_account = 2,
        .bootstrap = 1,
        .source_stream = 1,
        .source_sequence = 4,
        .value = .{ .margin = .{ .instrument = fixture.swap_instrument, .value = .{
            .instrument = fixture.swap_instrument,
            .amount = zero,
            .adjusted_equity = amount,
            .initial_margin = zero,
            .maintenance_margin = zero,
            .isolated_equity = amount,
        } } },
    } });
    margin_update.venue.envelope.scope = .instrument;
    margin_update.venue.envelope.instrument = fixture.swap_instrument;
    _ = try run.shard.apply(margin_update);
    try std.testing.expectEqual(cash - 1, run.shard.canonical_account.balances[0].total.atoms);
    try std.testing.expectEqual(@as(i128, 7), run.shard.canonical_account.positions[0].quantity.lots);
    const barrier = run.shard.authoritativeBarrier();
    const digest = run.shard.canonicalStateDigest();

    var next_balance = balance_update.venue.event.account_observed;
    next_balance.identity = 5;
    next_balance.source_sequence = 5;
    const next = fixture.canonicalAt(24, 5, .{ .account_observed = next_balance });
    var foreign_observation = next;
    foreign_observation.venue.envelope.venue = 21;
    bootstrap.identity = 2;
    bootstrap.source_sequence = 5;
    var foreign_bootstrap = fixture.canonicalAt(24, 5, .{ .account_bootstrap_snapshot = bootstrap });
    foreign_bootstrap.venue.envelope.venue = 21;
    var foreign_duplicate = accepted;
    foreign_duplicate.venue.envelope.venue = 21;
    var invalid_scope = next;
    invalid_scope.venue.envelope.scope = .venue;
    var wrong_asset = next;
    wrong_asset.venue.envelope.scope = .asset;
    wrong_asset.venue.envelope.asset = 0x425443;
    var next_position = position_update.venue.event.account_observed;
    next_position.identity = 5;
    next_position.source_sequence = 5;
    var wrong_instrument = fixture.canonicalAt(24, 5, .{ .account_observed = next_position });
    wrong_instrument.venue.envelope.scope = .instrument;
    wrong_instrument.venue.envelope.instrument = fixture.spot_instrument;
    var wrong_payload_scope = next;
    wrong_payload_scope.venue.envelope.scope = .instrument;
    wrong_payload_scope.venue.envelope.instrument = fixture.swap_instrument;
    for ([_]trading.CanonicalEvent{ foreign_observation, foreign_bootstrap, foreign_duplicate, invalid_scope, wrong_asset, wrong_instrument, wrong_payload_scope }) |event| {
        try std.testing.expectError(error.CanonicalScopeMismatch, run.shard.apply(event));
        try std.testing.expectEqual(barrier, run.shard.authoritativeBarrier());
        try std.testing.expectEqualSlices(u8, &digest, &run.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u8, 1), run.shard.canonical_account.balance_count);
        try std.testing.expectEqual(@as(u8, 1), run.shard.canonical_account.position_count);
        try std.testing.expectEqual(@as(u8, 1), run.shard.canonical_account.margin_count);
    }
}

test "Observation capacity 500 combinations four continuous Owners retain 128 selected resting orders" {
    const allocator = std.testing.allocator;
    const owners = try allocator.alloc(demo.Owner, 4);
    defer allocator.free(owners);
    const stores = try allocator.alloc(durable.MemoryAdapter, 4);
    defer allocator.free(stores);
    const gateways = try allocator.alloc(execution.Gateway, 4);
    defer allocator.free(gateways);
    var feeds: [4]OfflineFeed = undefined;
    var adapters: [4]RestingVenue = undefined;
    const snapshot_bytes = try allocator.alloc(u8, durable.max_snapshot_bytes);
    defer allocator.free(snapshot_bytes);
    var max_encoded: usize = 0;
    for (0..4) |route| {
        initializeStore(&stores[route]);
        owners[route] = try demo.Owner.bootstrap(stores[route].interface(), undefined, .{ .domain = .decision_log, .id = 100 + route });
        gateways[route] = .{};
        feeds[route] = .{ .source = .{ .venue_identity = venues[route], .stream = 200 + route } };
        adapters[route] = .{ .source = .{ .venue_identity = venues[route], .account = 100 + route, .stream = 300 + route } };
    }
    defer for (stores) |*store| store.deinit();
    for (0..4) |route| {
        const owner = &owners[route];
        const feed = &feeds[route];
        const adapter = &adapters[route];
        try feed.adapter().start(.{ .venue = venues[route], .environment = .simulation, .subscription_set = 1, .config_version = 1, .session = 1, .output_capacity = 1 });
        try adapter.adapter().start(.{ .venue = venues[route], .environment = .simulation, .exchange_account = 100 + route, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1 });
        // Bootstrap admission is sealed early; subsequent configuration uses the same live Owner.
        _ = try apply(owner, .{ .instrument_rules_activated = .{
            .version = 1,
            .instrument_identity = instrument(route, 0),
            .quantity_denominator = 100_000_000,
            .reservation_model = .cash,
            .product = .spot,
            .venue = venues[route],
            .base_asset = 1000,
        } }, 1);
        try owner.sealBootstrap();
        for (0..76) |index| {
            var definition = assets.testDefinitions(6, 8)[if (index == 0) 0 else 1];
            definition.asset = if (index == 0) 1 else 999 + index;
            definition.source_identity = definition.asset;
            definition.code_bindings = @splat(.{});
            definition.code_binding_count = 4;
            var code_buffer: [16]u8 = undefined;
            const code = if (index == 0) "USDT" else try std.fmt.bufPrint(&code_buffer, "BASE{d}", .{index});
            for (venues, 0..) |venue_id, binding| definition.code_bindings[binding] = try canonical.AssetCodeBinding.init(venue_id, code);
            _ = try apply(owner, .{ .asset_definition_activated = definition }, index + 1);
        }
        for (0..125) |index| {
            const id = instrument(route, index);
            if (index != 0) _ = try apply(owner, .{ .instrument_rules_activated = .{
                .version = 1,
                .instrument_identity = id,
                .quantity_denominator = if (index < 75) 100_000_000 else 10_000,
                .quantity_numerator = @intCast(1 + index % 3),
                .reservation_model = if (index < 75) .cash else .leveraged,
                .product = product(index),
                .venue = venues[route],
                .base_asset = 1000 + index % 75,
            } }, 1000 + index);
            _ = try apply(owner, .{ .margin_rules_activated = .{ .version = 1, .instrument = id, .native_settlement_atoms = true, .price_tick_atoms = tick(index) } }, 2000 + index);
            try snapshot(owner, feed, route, index, 1);
            try public(owner, feed, .{ .reference_price = .{ .instrument = id, .kind = .mark, .price = .{ .instrument = id, .rules_version = 1, .ticks = askTicks(index) - priceStep(index) } } }, id);
        }
        for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 1 }, .cash)) |original| {
            var event = original.core;
            switch (event.payload) {
                .instrument_rules_activated, .margin_rules_activated, .asset_definition_activated, .mark_price, .instrument_trading_authorization => continue,
                .account_configuration => |*value| value.exchange_account_identity = 100 + route,
                else => {},
            }
            _ = try apply(owner, event.payload, event.identity);
        }
        var bootstrap: canonical.AccountBootstrapSnapshot = .{ .identity = 1, .exchange_account = 100 + route, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = adapter.source.stream, .source_sequence = adapter.source.sequence + 1, .balance_count = 1, .position_count = 0, .margin_count = 0 };
        const amount: canonical.AssetAmount = .{ .asset = 1, .atoms = cash };
        const zero: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
        bootstrap.balances[0] = .{ .asset = 1, .total = amount, .available = amount, .held = zero, .cash_balance = amount, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
        try private(owner, adapter, .{ .account_bootstrap_snapshot = bootstrap });
        for (0..75) |index| {
            const native_zero: canonical.AssetAmount = .{ .asset = 1000 + index, .atoms = 0 };
            try private(owner, adapter, .{ .account_observed = .{
                .identity = adapter.source.sequence + 1,
                .exchange_account = 100 + route,
                .bootstrap = 1,
                .source_stream = adapter.source.stream,
                .source_sequence = adapter.source.sequence + 1,
                .value = .{ .balance = .{ .asset = native_zero.asset, .value = .{
                    .asset = native_zero.asset,
                    .total = native_zero,
                    .available = native_zero,
                    .held = native_zero,
                    .cash_balance = native_zero,
                    .liability = native_zero,
                    .isolated_liability = native_zero,
                    .cross_liability = native_zero,
                } } },
            } });
        }
        for (0..125) |index| try private(owner, adapter, .{ .account_observed = .{
            .identity = adapter.source.sequence + 1,
            .exchange_account = 100 + route,
            .bootstrap = 1,
            .source_stream = adapter.source.stream,
            .source_sequence = adapter.source.sequence + 1,
            .value = .{ .position = .{ .instrument = instrument(route, index), .side = .net, .value = .{
                .instrument = instrument(route, index),
                .side = .net,
                .quantity = .{ .instrument = instrument(route, index), .rules_version = 1, .lots = 0 },
            } } },
        } });
        for (75..125) |index| try private(owner, adapter, .{ .account_observed = .{
            .identity = adapter.source.sequence + 1,
            .exchange_account = 100 + route,
            .bootstrap = 1,
            .source_stream = adapter.source.stream,
            .source_sequence = adapter.source.sequence + 1,
            .value = .{ .margin = .{ .instrument = instrument(route, index), .value = .{
                .instrument = instrument(route, index),
                .amount = zero,
                .adjusted_equity = amount,
                .initial_margin = zero,
                .maintenance_margin = zero,
                .isolated_equity = amount,
            } } },
        } });
        try std.testing.expectEqual(@as(u8, 76), owner.shard.canonical_account.balance_count);
        try std.testing.expectEqual(@as(u8, 125), owner.shard.canonical_account.position_count);
        try std.testing.expectEqual(@as(u8, 50), owner.shard.canonical_account.margin_count);
        try std.testing.expectEqual(@as(u8, 0), owner.shard.oms.order_count);
        for (0..125) |index| if (selected(index)) {
            _ = try apply(owner, .{ .capability_profile_activation = capability(route, index) }, 3000 + index);
            const authorization: trading.CorePayload = .{ .instrument_trading_authorization = .{
                .exchange_account = 100 + route,
                .instrument = instrument(route, index),
                .strategy_activation_identity = 1,
                .config_version = 1,
                .expected_version = owner.shard.instrument_registry.get(instrument(route, index)).?.trading_version,
                .enabled = true,
            } };
            _ = try apply(owner, authorization, 3500 + index);
            if (index == 0) {
                const authorized_barrier = owner.shard.authoritativeBarrier();
                const authorized_digest = owner.shard.canonicalStateDigest();
                _ = try apply(owner, authorization, 3500 + index);
                try std.testing.expectEqual(authorized_barrier, owner.shard.authoritativeBarrier());
                try std.testing.expectEqualSlices(u8, &authorized_digest, &owner.shard.canonicalStateDigest());
            }
        };
        const barrier = owner.shard.authoritativeBarrier();
        const digest = owner.shard.canonicalStateDigest();
        _ = try apply(owner, .{ .host_activated = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .session = .{ .fencing = 1, .shard = @intCast(route), .generation = 1 }, .activation_barrier = barrier, .state_digest = digest } }, 4000);
        try gateways[route].add(.{ .account = 100 + route, .adapter = adapter.adapter(), .venue_identity = venues[route], .environment = .simulation, .supported_products = 3, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1, .supports_venue_reduce_only = true } });
        try gateways[route].bootstrapDurableDispatch(stores[route].interface(), undefined, .{ .domain = .control, .id = 400 + route });
    }
    // Continuous zero-order observation traverses many resident windows without resetting any source sequence.
    for (2..10) |round| for (0..4) |route| {
        for (0..125) |index| try snapshot(&owners[route], &feeds[route], route, index, round);
        try std.testing.expectEqual(@as(u8, 0), owners[route].shard.oms.order_count);
        try std.testing.expectEqual(@as(usize, 0), adapters[route].sends);
    };
    for (0..4) |route| {
        const owner = &owners[route];
        // Healthy B cannot clear A's gap or grant A a send permission.
        const a = instrument(route, 0);
        try public(owner, &feeds[route], .{ .market_data_health_changed = .{ .instrument = a, .health = .gap } }, a);
        try snapshot(owner, &feeds[route], route, 1, 10);
        try std.testing.expectEqual(canonical.MarketDataHealth.gap, owner.shard.canonical_market.get(a).?.health);
        try std.testing.expect((try apply(owner, .{ .external_order_intent = intent(owner, route, 0, 9000) }, 9000)) == null);
        try std.testing.expectEqual(@as(u8, 0), owner.shard.oms.order_count);
        try snapshot(owner, &feeds[route], route, 0, 10);
        for (0..125) |index| {
            const entry = owner.shard.instrument_registry.get(instrument(route, index)).?;
            try std.testing.expectEqual(selected(index), entry.trading_enabled);
            if (!selected(index)) try std.testing.expect(entry.capability == null);
            try std.testing.expectEqual(canonical.MarketDataHealth.healthy, owner.shard.canonical_market.get(entry.instrument).?.health);
        }
        for (0..125) |index| if (selected(index)) {
            const sequence = 10_000 + index;
            const command = (try apply(owner, .{ .external_order_intent = intent(owner, route, index, sequence) }, sequence)) orelse return error.MissingSelectedOrder;
            if (index == 90) {
                try dispatch(owner, &gateways[route], &adapters[route], command);
                try toggle(owner, route, index, false, 20_000);
                try std.testing.expectError(error.NotSent, gateways[route].sendFromShard(&owner.shard, command.command_id, 2));
                try std.testing.expect((try apply(owner, .{ .external_order_intent = intent(owner, route, index, 20_001) }, 20_001)) == null);
                try snapshot(owner, &feeds[route], route, index, 10);
                try std.testing.expectEqual(canonical.MarketDataHealth.healthy, owner.shard.canonical_market.get(command.instrument).?.health);
                var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 20_002, .count = 1 };
                group.members[0] = .{ .intent_sequence = 20_002, .operation = .cancel, .instrument = command.instrument, .target_order_id = command.order_id, .expected_revision = command.revision };
                _ = try apply(owner, .{ .oms_intent_group = group }, 20_002);
                const cancellation = owner.shard.oms.emitted()[0];
                try dispatch(owner, &gateways[route], &adapters[route], cancellation);
                try toggle(owner, route, index, true, 20_003);
                try std.testing.expectEqual(@as(u64, 1), owner.shard.instrument_registry.get(command.instrument).?.capability.?.version);
                const fresh = (try apply(owner, .{ .external_order_intent = intent(owner, route, index, 20_004) }, 20_004)) orelse return error.MissingResumedOrder;
                try dispatch(owner, &gateways[route], &adapters[route], fresh);
                continue;
            }
            try dispatch(owner, &gateways[route], &adapters[route], command);
            if (index == 0 or index == 1 or index == 75 or index == 76)
                try partialFill(owner, &adapters[route], command, route, index);
        };
        try std.testing.expectEqual(@as(u8, 33), owner.shard.oms.order_count);
        try std.testing.expectEqual(@as(usize, 34), adapters[route].sends);
        var live_orders: usize = 0;
        for (owner.shard.oms.orders[0..owner.shard.oms.order_count]) |order| {
            if (order.state == .live) live_orders += 1 else try std.testing.expectEqual(trading.oms.OrderState.canceled, order.state);
        }
        try std.testing.expectEqual(@as(usize, 32), live_orders);
        try owner.checkpoint();
        const encoded = try owner.committedSnapshot(snapshot_bytes);
        max_encoded = @max(max_encoded, encoded.len);
        const restored = try allocator.create(demo.Owner);
        defer allocator.destroy(restored);
        restored.* = try demo.Owner.recover(stores[route].interface(), undefined, owner.stream);
        try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u8, 125), restored.shard.instrument_registry.count);
        try std.testing.expectEqual(@as(u8, 76), restored.shard.canonical_account.balance_count);
        try std.testing.expectEqual(@as(u8, 125), restored.shard.canonical_account.position_count);
        try std.testing.expectEqual(@as(u8, 50), restored.shard.canonical_account.margin_count);
        try std.testing.expectEqual(@as(u8, 33), restored.shard.oms.order_count);
        for ([_]usize{ 0, 1, 75, 76 }) |index|
            try std.testing.expectEqual(@as(i64, 10), restored.shard.economic_projection.portfolio.positionForInstrument(instrument(route, index)).quantity);
        try std.testing.expectEqual(@as(i128, 9), restored.shard.economic_projection.portfolio.spotInventoryAtoms(1000));
        try std.testing.expectEqual(@as(i128, 9), restored.shard.economic_projection.exchange.spotInventoryAtoms(1000));
        try std.testing.expectError(error.NotSent, gateways[route].sendFromShard(&restored.shard, restored.shard.oms.command_history[0].command_id, 2));
        try std.testing.expect(feeds[route].source.sequence > 1000);
        var foreign = fixture.canonicalAt(40_000, feeds[route].source.sequence + 1, .{ .market_data_health_changed = .{
            .instrument = instrument(route, 0),
            .health = .gap,
        } });
        foreign.venue.envelope.venue = venues[(route + 1) % venues.len];
        foreign.venue.envelope.exchange_account = null;
        const before_scope = restored.shard.canonicalStateDigest();
        try std.testing.expectError(error.CanonicalScopeMismatch, restored.shard.apply(foreign));
        foreign.venue.envelope.venue = venues[route];
        foreign.venue.envelope.exchange_account = 100 + (route + 1) % venues.len;
        try std.testing.expectError(error.CanonicalScopeMismatch, restored.shard.apply(foreign));
        try std.testing.expectEqualSlices(u8, &before_scope, &restored.shard.canonicalStateDigest());
        // The 126th configuration fails before changing authoritative state.
        const before_overflow = restored.shard.canonicalStateDigest();
        try std.testing.expectError(error.InstrumentRegistryFull, restored.shard.apply(.{ .core = .{ .identity = 30_000, .payload = .{ .instrument_rules_activated = .{
            .version = 1,
            .instrument_identity = instrument(route, 125),
            .quantity_denominator = 10_000,
            .reservation_model = .leveraged,
            .product = .isolated_linear_usdt,
            .venue = venues[route],
            .base_asset = 1050,
        } } } }));
        try std.testing.expectEqualSlices(u8, &before_overflow, &restored.shard.canonicalStateDigest());
    }
    std.debug.print("observation_capacity: combinations=500 selected_live=128 owners=4 max_snapshot_bytes={d} shard_bytes={d}\n", .{ max_encoded, @sizeOf(trading.TradingShard) });
}
