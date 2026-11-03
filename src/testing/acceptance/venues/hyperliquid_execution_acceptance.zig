//! Synthetic offline Gateway -> adapter -> Owner evidence. No credentials or network.
const std = @import("std");
const hl = @import("../../../adapters/hyperliquid/hyperliquid_venue_adapter.zig");
const signer = @import("../../../adapters/hyperliquid/hyperliquid_signer.zig");
const c = @import("../../../model/canonical_event.zig");
const venue = @import("../../../execution/venue_adapter.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const raw = @import("../../../persistence/raw_ingress.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const times: hl.Times = .{ .receive_time_utc_ns = 1_800_000_000_100_000_000, .wall_time_utc_ns = 1_800_000_000_100_000_000, .monotonic_time_ns = 2 * std.time.ns_per_s };
const IO = struct {
    sink: raw.DurableSink,
    sends: u64 = 0,
    fn now(_: *anyopaque) hl.Times {
        return times;
    }
    fn sign(_: *anyopaque, request: signer.Request) !signer.SignedAction {
        return .{ .nonce = request.now_ms, .digest = @splat(1), .signature = .{ .r = @splat(1), .s = @splat(1), .v = 27 }, .session = request.session, .funding_account = @splat(2), .subaccount = null };
    }
    fn check(_: *anyopaque, _: u64, _: u64, _: bool) !void {}
    fn query(_: *anyopaque, _: []const u8) hl.TransportResult {
        return .{ .outcome = .proven_before_send, .session = 7, .times = times };
    }
    fn submit(ptr: *anyopaque, request: hl.SignedRequest) hl.TransportResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.sends += 1;
        std.debug.assert(std.mem.indexOf(u8, request.action_json, "0x") != null);
        return .{ .session = 7, .times = times, .outcome = .response, .bytes = "{\"status\":\"ok\",\"response\":{\"type\":\"order\",\"data\":{\"statuses\":[{\"resting\":{\"oid\":42}}]}}}" };
    }
    fn append(ptr: *anyopaque, record: hl.RawRecord, bytes: []const u8) hl.RawError!u64 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const sink = self.sink.interface();
        if (record.venue != 1 or record.account != 2 or record.session != 7) return error.Unavailable;
        return sink.append_fn(sink.ptr, .{ .origin = @intFromEnum(record.input), .source_session = @intCast(record.session), .receive_time_utc_ns = record.times.receive_time_utc_ns, .monotonic_time_ns = record.times.monotonic_time_ns, .wall_time_utc_ns = record.times.wall_time_utc_ns, .byte_len = record.byte_len, .sha256 = record.sha256 }, bytes);
    }
};

test "Hyperliquid Gateway durable CLOID and Owner report Fill permutations have equal economics" {
    const allocator = std.testing.allocator;
    var expected: ?@import("../../../trading/trading_shard.zig").EconomicSummary = null;
    for ([_]bool{ false, true }) |fill_first| {
        const memory = try allocator.create(durable.MemoryAdapter);
        defer allocator.destroy(memory);
        memory.* = .initWithAllocator(allocator);
        defer memory.deinit();
        const owner = try allocator.create(demo.Owner);
        defer allocator.destroy(owner);
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
        for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged)) |event| _ = try owner.apply(event);
        const digest = owner.shard.canonicalStateDigest();
        _ = try owner.apply(fixture.atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .session = .{ .fencing = 1, .shard = 0, .generation = 1 }, .activation_barrier = 0, .state_digest = digest } } }));
        try owner.sealBootstrap();
        _ = try owner.apply(fixture.atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = 3, .price_atoms = 50_000_000_000 } } }));
        _ = try owner.apply(fixture.canonicalAt(12, 99, .{ .instrument_definition_observed = .{ .instrument = 3, .rules_version = 1 } }));
        _ = try owner.apply(fixture.snapshotAt(13, 100));
        _ = try owner.apply(fixture.deltaAt(14, 100, 101, 49_850_000_000));
        _ = try owner.apply(fixture.atGroup(15, .{ .identity = 30, .payload = .{ .capability_profile_activation = .{ .exchange_account = 2, .instrument = 3, .venue = 1, .environment = .simulation, .product = .isolated_linear, .version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 7, .max_dispatch_age_ns = 10 * std.time.ns_per_s, .supports_place = true, .supports_cancel = true, .supports_native_amend = false, .supports_venue_reduce_only = false, .supports_post_only = false, .supports_market_protection = false } } }));
        var snapshot: c.AccountBootstrapSnapshot = .{ .identity = 1, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 2, .source_sequence = 1, .balance_count = 1, .position_count = 1, .margin_count = 1 };
        snapshot.balances[0] = .{ .asset = 1, .total = .{ .asset = 1, .atoms = 25_000_000_000 }, .available = .{ .asset = 1, .atoms = 25_000_000_000 }, .held = .{ .asset = 1, .atoms = 0 } };
        snapshot.balances[0].cash_balance = snapshot.balances[0].total;
        snapshot.balances[0].liability = .{ .asset = 1, .atoms = 0 };
        snapshot.balances[0].isolated_liability = .{ .asset = 1, .atoms = 0 };
        snapshot.balances[0].cross_liability = .{ .asset = 1, .atoms = 0 };
        snapshot.positions[0] = .{ .instrument = 3, .side = .net, .quantity = .{ .instrument = 3, .rules_version = 1, .lots = 0 } };
        snapshot.margins[0] = .{ .instrument = 3, .amount = .{ .asset = 1, .atoms = 25_000_000_000 }, .initial_margin = .{ .asset = 1, .atoms = 0 }, .maintenance_margin = .{ .asset = 1, .atoms = 0 }, .isolated_equity = .{ .asset = 1, .atoms = 25_000_000_000 } };
        var bootstrap = fixture.canonicalAt(16, 1, .{ .account_bootstrap_snapshot = snapshot });
        bootstrap.venue.envelope.identity.stream = 2;
        bootstrap.venue.envelope.source_stream = 2;
        _ = try owner.apply(bootstrap);
        const placed = try owner.apply(fixture.atGroup(17, .{ .identity = 100, .payload = .{ .timer = fixture.timer(100) } }));
        const command = placed orelse return error.MissingOrder;
        var io: IO = .{ .sink = try raw.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 7 }) };
        var budget: hl.Budget = .{};
        const bindings = [_]hl.Binding{.{ .instrument = 3, .coin = "BTC", .wire_asset = 3, .product = .isolated_linear, .size_decimals = 4, .quantity_scale = 4, .lot_atoms = 1, .price_scale = 6, .tick_atoms = 1 }};
        var implementation: hl.HyperliquidVenueAdapter = .{ .profile = .{ .venue = 1, .account = 2, .session = 7, .funding = @splat(2), .environment = .simulation, .bindings = &bindings, .version = 1, .rules_version = 1, .config_version = 1, .can_trade = true }, .clock = .{ .ptr = &io, .now_fn = IO.now }, .auth = .{ .ptr = &io, .sign_fn = IO.sign, .check_fn = IO.check }, .raw_sink = .{ .ptr = &io, .append_fn = IO.append }, .transport = .{ .ptr = &io, .submit_fn = IO.submit, .query_fn = IO.query }, .budget = &budget, .fencing_token = 1 };
        const adapter = implementation.adapter();
        try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 7, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
        const gateway = try allocator.create(execution.Gateway);
        defer allocator.destroy(gateway);
        gateway.init();
        const route: execution.Route = .{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 7 } };
        try gateway.add(route);
        var bootstrap_buffer: [4096]u8 = undefined;
        try gateway.bootstrapDurableDispatchWithBuffer(memory.interface(), undefined, .{ .domain = .control, .id = 92 }, &bootstrap_buffer);
        try gateway.observeAuthorityFromShard(&owner.shard, .{ .account = 2, .effective_trading_authority = owner.shard.operational_state.effectiveTradingAuthority(), .reservation_identity = command.reservation_identity, .reservation = command.reservation, .primary_lease_expires_at_monotonic_ns = 20 * std.time.ns_per_s, .fencing_token = 1, .exchange_position = owner.shard.currentNetExchangePosition(3).?, .authority_barrier = 1 });
        try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(&owner.shard, command.command_id, 2 * std.time.ns_per_s));
        try std.testing.expectEqual(@as(u64, 1), io.sends);
        const cloid = gateway.acceptedClientOrderId(2, command.command_id).?;
        try std.testing.expectEqual(@as(usize, 34), cloid.slice().len);
        const initial = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(c.DispatchState.submitted, initial.slice()[0].event.order_dispatch_result.state);
        try owner.applyAdapterBatch(initial);
        var frame: [2048]u8 = undefined;
        const report = try std.fmt.bufPrint(&frame, "[{{\"order\":{{\"coin\":\"BTC\",\"side\":\"B\",\"limitPx\":\"50100\",\"sz\":\"0\",\"origSz\":\"0.01\",\"oid\":42,\"cloid\":\"{s}\",\"timestamp\":1800000000000}},\"status\":\"filled\",\"statusTimestamp\":1800000000001}}]", .{cloid.slice()});
        const fill = "[{\"coin\":\"BTC\",\"px\":\"50100\",\"sz\":\"0.01\",\"side\":\"B\",\"time\":1800000000001,\"oid\":42,\"tid\":8,\"fee\":\"0.25\",\"feeToken\":\"USDT\",\"crossed\":true,\"closedPnl\":\"0\",\"dir\":\"Open Long\"}]";
        for (0..2) |index| {
            const is_fill = (index == 0) == fill_first;
            try implementation.ingest(allocator, 7, @splat(2), if (is_fill) .fills else .orders, times, if (is_fill) fill else report);
            try owner.applyAdapterBatch((try adapter.tryDrain()).?);
        }
        try std.testing.expectEqual(@as(i64, 100), try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
        try std.testing.expectEqual(@as(i64, 100), owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
        try std.testing.expectEqual(@as(i64, 250000), owner.shard.economicSummary().portfolio.fee_atoms);
        const economics = owner.shard.economicSummary();
        // Each virgin Gateway creates a fresh random namespace and therefore a different CLOID.
        if (expected) |value| try std.testing.expectEqualDeep(value, economics) else expected = economics;
        const before = owner.shard.canonicalStateDigest();
        try implementation.ingest(allocator, 7, @splat(2), .fills, times, fill);
        try owner.applyAdapterBatch((try adapter.tryDrain()).?);
        try std.testing.expectEqualSlices(u8, &before, &owner.shard.canonicalStateDigest());
        // Gateway recovery must retain the exact cloid and never re-enter transport.
        const recovered = try allocator.create(execution.Gateway);
        defer allocator.destroy(recovered);
        recovered.initWithDispatchSnapshotBuffer(&bootstrap_buffer);
        try recovered.add(route);
        try recovered.attachRecoveredDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
        try std.testing.expectEqualDeep(cloid, recovered.acceptedClientOrderId(2, command.command_id).?);
        try std.testing.expectEqual(@as(u64, 0), recovered.send_attempt_count);
    }
}
