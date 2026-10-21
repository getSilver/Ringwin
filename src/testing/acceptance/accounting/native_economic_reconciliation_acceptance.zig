//! Offline public-seam evidence for venue fill recovery.  The raw frames below
//! are deliberately fed only to the OKX adapter; Owner receives canonical facts.

const std = @import("std");
const canonical = @import("../../../model/canonical_event.zig");
const durable = @import("../../../persistence/durable_store.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const failover = @import("../../../runtime/failover.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const venue = @import("../../../execution/venue_adapter.zig");
const okx = @import("../../../adapters/okx/okx_venue_adapter.zig");
const live = @import("../../../runtime/demo/okx_live_chain.zig");
const order = @import("../../../adapters/okx/okx_order_entry.zig");
const private = @import("../../../adapters/okx/okx_private_reconciliation.zig");
const host = @import("../../../strategy/strategy_host_gateway.zig");
const raw_ingress = @import("../../../persistence/raw_ingress.zig");

const private_times: private.Times = .{
    .receive_time_utc_ns = 1_800_000_000_000_000_001,
    .monotonic_time_ns = 10_000_001,
    .wall_time_utc_ns = 1_800_000_000_000_000_002,
};

const Clock = struct {
    value: u64 = 1,

    fn interface(self: *Clock) okx.Clock {
        return .{ .ptr = self, .now_fn = now };
    }

    fn now(ptr: *anyopaque) u64 {
        return @as(*Clock, @ptrCast(@alignCast(ptr))).value;
    }
};

const Transport = struct {
    sends: usize = 0,
    fn interface(self: *Transport) live.Transport {
        return .{ .ptr = self, .submit_fn = submit };
    }

    fn submit(ptr: *anyopaque, _: []const u8, _: []const u8) live.TransportResult {
        @as(*Transport, @ptrCast(@alignCast(ptr))).sends += 1;
        return .{ .outcome = .proven_before_send, .source_session = 1, .times = private_times };
    }
};

fn qualification() live.Qualification {
    return .{ .explicit_demo_live = true, .endpoint_is_demo = true, .simulated_header = true, .credentials_loaded = true, .clock_healthy = true, .account_qualified = true, .reconciliation_stable = true, .no_unknown_orders = true, .cleanup_armed = true };
}

fn profile() order.CapabilityProfile {
    return .{ .version = 1, .rules_version = 1, .config_version = 1, .gateway_session = 1, .qualification = .demo_qualified, .batch_max = 4, .place_limit = .{ .requests = 4, .window_ns = 100 }, .place_batch_limit = .{ .requests = 4, .window_ns = 100 }, .amend_limit = .{ .requests = 4, .window_ns = 100 }, .amend_batch_limit = .{ .requests = 4, .window_ns = 100 }, .cancel_limit = .{ .requests = 4, .window_ns = 100 }, .cancel_batch_limit = .{ .requests = 4, .window_ns = 100 }, .subaccount_place_amend_limit = .{ .requests = 4, .window_ns = 100 }, .limit = true, .protected_market_ioc = true, .ioc = true, .fok = true, .native_amend = true, .native_post_only = true, .swap_venue_reduce_only = true };
}

fn rules() okx.Rules {
    return .{ .spot = .{ .identity = okx.btc_usdt_spot, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 8 } }, .swap = .{ .identity = okx.btc_usdt_swap, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 2 } } };
}

fn ingestBootstrapRound(implementation: *okx.OkxVenueAdapter) !void {
    const sources = [_]private.IngressSource{ .rest_account_config, .rest_leverage, .rest_balance, .rest_positions, .rest_orders_pending, .rest_orders_history_spot, .rest_orders_history_swap, .rest_fills_history_spot, .rest_fills_history_swap };
    const frames = [_][]const u8{
        \\{"code":"0","data":[{"acctLv":"2","posMode":"net_mode","ctIsoMode":"automatic","autoLoan":false,"enableSpotBorrow":false,"perm":"read_only,trade"}]}
        ,
        \\{"code":"0","data":[{"instId":"BTC-USDT-SWAP","mgnMode":"isolated","posSide":"net","lever":"3"}]}
        ,
        \\{"code":"0","data":[{"uTime":"1800000000000","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"25","availBal":"25","eq":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
        ,
        \\{"code":"0","data":[]}
        ,
        \\{"code":"0","data":[]}
        ,
        \\{"code":"0","data":[]}
        ,
        \\{"code":"0","data":[]}
        ,
        \\{"code":"0","data":[]}
        ,
        \\{"code":"0","data":[]}
    };
    for (sources, frames) |source, frame|
        try std.testing.expect((try implementation.ingestPrivateRest(private_times, source, .{ .final = true }, frame)).rejection == null);
}

fn applyDrain(owner: *demo.Owner, adapter: venue.VenueAdapter) !bool {
    const batch = (try adapter.tryDrain()) orelse return false;
    try owner.applyAdapterBatch(batch);
    return true;
}

fn bootstrapNativePrivateAccount(owner: *demo.Owner, implementation: *okx.OkxVenueAdapter, cash_text: []const u8) !void {
    const adapter = implementation.adapter();
    try implementation.beginPrivateSession();
    const bootstrap = [_][]const u8{
        \\{"event":"subscribe","arg":{"channel":"orders","instType":"ANY"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"account"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"positions","instType":"ANY"}}
        ,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000000","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"25","availBal":"25","eq":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
        ,
        \\{"arg":{"channel":"positions"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[]}
    };
    for (bootstrap) |frame| try std.testing.expect((try implementation.ingestPrivateWs(private_times, frame)).rejection == null);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 1 } }));
    _ = try applyDrain(owner, adapter);
    try ingestBootstrapRound(implementation);
    _ = try applyDrain(owner, adapter);
    try ingestBootstrapRound(implementation);
    try std.testing.expect(try applyDrain(owner, adapter));
    var cash_frame: [1024]u8 = undefined;
    const cash = try std.fmt.bufPrint(&cash_frame,
        \\{{"arg":{{"channel":"account"}},"eventType":"update","curPage":1,"lastPage":true,"data":[{{"uTime":"1800000000001","totalEq":"{s}","adjEq":"{s}","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{{"ccy":"USDT","cashBal":"{s}","availBal":"{s}","eq":"{s}","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}}]}}]}}
    , .{ cash_text, cash_text, cash_text, cash_text, cash_text });
    try std.testing.expect((try implementation.ingestPrivateWs(private_times, cash)).rejection == null);
    try std.testing.expect(try applyDrain(owner, adapter));
}

const Case = enum { matching, difference, missing_range, late_fact, conflict, fault, unknown, interval, interval_difference, unapplied, bad_query, stale_balance, stale_debt, wrong_version, content_conflict, interval_third, interval_pages, interval_missing_tail, interval_bad_cursor, interval_recovery, interval_recovery_incomplete, matching_recovery };

fn exercise(mode: Case) !void {
    try exerciseStored(mode, null, undefined);
}

fn exerciseStored(mode: Case, supplied_store: ?durable.Store, io: std.Io) !void {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const store = supplied_store orelse memory.interface();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(store, io, stream);
    const pair = @import("../../../trading/asset_registry.zig").testDefinitions(12, 9);
    var definitions = [_]canonical.AssetDefinition{ pair[0], pair[1], pair[0] };
    const third: canonical.AssetIdentity = 0x424e42;
    definitions[2].asset = third;
    definitions[2].source_identity += third;
    definitions[2].code_bindings = @splat(.{});
    definitions[2].code_binding_count = 1;
    definitions[2].code_bindings[0] = try canonical.AssetCodeBinding.init(1, "BNB");
    const policy: demo.Policy = .{ .schema = 3, .startup = .virgin, .asset_definitions = &definitions, .lot_size = .{ .coefficient = 1, .scale = 7 }, .exchange_account = 2, .portfolio_identity = 1, .strategy_identity = 40, .activation_identity = 50, .config_version = 1, .portfolio_allocation_atoms = 90_000_000_000_000, .risk_limit_atoms = 80_000_000_000_000, .price_tick_atoms = 250_000_000_000, .native_settlement_atoms = true, .decision_stream_id = 91, .dispatch_stream_id = 92, .decision_domain = 1, .node_identity = 1 };
    try policy.activateAssetsForOfflineValidation(owner);
    var raw = try raw_ingress.DurableSink.init(store, io, .{ .domain = .raw_ingress, .id = 1 });
    var transport = Transport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = Clock{};
    var reconciler: private.Reconciler = .{};
    var specification = rules();
    specification.spot.lot_size = policy.lot_size;
    specification.spot.tick_size = .{ .coefficient = 25, .scale = 2 };
    var implementation = okx.OkxVenueAdapter.init(allocator, &chain, clock.interface(), profile(), specification);
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry, .native_settlement_atoms = true });
    try bootstrapNativePrivateAccount(owner, &implementation, "100");
    const opening_frame =
        \\{"arg":{"channel":"account"},"eventType":"update","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000002","totalEq":"100","adjEq":"100","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"100","availBal":"100","eq":"100","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"},{"ccy":"BNB","cashBal":"10","availBal":"10","eq":"10","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    ;
    try std.testing.expect((try implementation.ingestPrivateWs(private_times, opening_frame)).rejection == null);
    try std.testing.expect(try applyDrain(owner, adapter));
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try policy.initialize(owner, 50_000_000_000_000_000, &guard, 1, 1);
    if (mode == .interval_recovery or mode == .interval_recovery_incomplete or mode == .interval or mode == .interval_difference or mode == .unapplied or mode == .bad_query or mode == .interval_third or mode == .interval_pages or mode == .interval_missing_tail or mode == .interval_bad_cursor) {
        try exerciseInterval(owner, &implementation, &chain, store, io, stream, mode == .interval_difference, mode == .unapplied, mode == .bad_query, mode == .interval_third, if (mode == .interval_pages) .complete else if (mode == .interval_missing_tail) .missing_tail else if (mode == .interval_bad_cursor) .bad_cursor else .single, mode == .interval_recovery or mode == .interval_recovery_incomplete, mode == .interval_recovery_incomplete);
        return;
    }
    if (mode == .stale_balance or mode == .stale_debt) {
        var buffer: [1024]u8 = undefined;
        const update = try std.fmt.bufPrint(&buffer,
            \\{{"arg":{{"channel":"account"}},"eventType":"update","curPage":1,"lastPage":true,"data":[{{"uTime":"1800000000004","totalEq":"100","adjEq":"100","imr":"0","mmr":"0","isoEq":"0","details":[{{"ccy":"USDT","cashBal":"100","availBal":"3","eq":"100","frozenBal":"97","liab":"{s}","isoLiab":"0","crossLiab":"0"}}]}}]}}
        , .{if (mode == .stale_debt) "1" else "0"});
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, update)).rejection == null);
        _ = try applyDrain(owner, adapter);
    }
    if (mode == .fault) {
        const faulty =
            \\{"arg":{"channel":"account"},"eventType":"update","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000003","totalEq":"100","adjEq":"100","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"UNREGISTERED","cashBal":"1","availBal":"1","eq":"1","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
        ;
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, faulty)).rejection == null);
        try std.testing.expect(try applyDrain(owner, adapter));
    }
    if (mode == .late_fact or mode == .unknown) {
        _ = try owner.apply(.{ .core = .{ .identity = 70, .payload = .{ .risk_lease_granted = .{ .lease_identity = 70, .version = 2, .amount_atoms = 80_000_000_000_000, .valid_through_barrier = 1000 } } } });
        var definition = fixture.canonicalAt(21, 1, .{ .instrument_definition_observed = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1 } });
        definition.venue.envelope.identity.stream = 700;
        _ = try owner.apply(definition);
        var book = fixture.canonicalAt(22, 2, .{ .l2_book_snapshot = .{ .instrument = okx.btc_usdt_spot, .sequence = 1, .best_bid = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 199_999 }, .best_ask = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 200_000 }, .best_bid_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 1_000_000 }, .best_ask_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 1_000_000 } } });
        book.venue.envelope.identity.stream = 700;
        _ = try owner.apply(book);
        const oms = @import("../../../execution/oms.zig");
        var group: oms.IntentGroup = .{ .first_intent_sequence = 80, .count = 1 };
        group.members[0] = .{ .intent_sequence = 80, .operation = .place, .instrument = okx.btc_usdt_spot, .side = .buy, .quantity = 1, .limit_price = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 200_000 } };
        _ = try owner.apply(.{ .core = .{ .identity = 80, .payload = .{ .oms_intent_group = group } } });
        try std.testing.expectEqual(@as(u8, 1), owner.shard.oms.command_history_count);
        const command = owner.shard.oms.command_history[0];
        if (mode == .late_fact) {
            _ = try owner.apply(.{ .core = .{ .identity = 81, .payload = .{ .economic_fill = .{ .fill_id = 81, .order_id = command.order_id, .quantity = 1, .price_ticks = 200_000 } } } });
        } else {
            var unknown = fixture.canonicalAt(23, 3, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .unknown } });
            unknown.venue.envelope.identity.stream = 700;
            _ = try owner.apply(unknown);
        }
    }
    const before = owner.shard.economicSummary();
    const faults_before = owner.shard.economic_fault_count;
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 200, .exchange_account = 2, .expected_session = 1, .economic_boundary_utc_ns = 1_800_000_000_002_000_000 } }));
    try std.testing.expect(try applyDrain(owner, adapter));
    // A bootstrap-complete flag cannot terminate this independent snapshot request.
    try std.testing.expect((try adapter.tryDrain()) == null);
    var frame_buffer: [2048]u8 = undefined;
    const frame = try std.fmt.bufPrint(&frame_buffer,
        \\{{"code":"0","data":[{{"uTime":"{s}","totalEq":"100","adjEq":"100","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{{"ccy":"USDT","cashBal":"{s}","availBal":"{s}","eq":"{s}","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}},{{"ccy":"BNB","cashBal":"10","availBal":"10","eq":"10","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}}]}}]}}
    , .{ if (mode == .missing_range) "1800000000003" else "1800000000002", if (mode == .difference) "100.000000000001" else "100", if (mode == .difference) "100.000000000001" else "100", if (mode == .difference) "100.000000000001" else "100" });
    try std.testing.expect((try implementation.ingestPrivateRest(private_times, .rest_balance, .{ .final = true }, frame)).rejection == null);
    var batch = (try adapter.tryDrain()).?;
    if (mode == .wrong_version) for (batch.events[0..batch.len]) |*record| {
        if (record.event == .account_reconciliation_result) record.event.account_reconciliation_result.account_economics.?.asset_versions[0] += 1;
    };
    const result = reconciliationResult(batch);
    const evidence = result.account_economics.?;
    try std.testing.expectEqual(@as(u8, 2), evidence.balance_count);
    try std.testing.expectEqual(@as(i128, 10_000_000_000_000), evidence.balances[1].atoms);
    try std.testing.expectEqual(@as(u16, 0), evidence.covered_economic_fact_count);
    try std.testing.expect(evidence.source.sequence != 0);
    if (mode == .matching_recovery) try checkEconomicSweep(owner, &implementation, store, io, stream, batch, 0);
    if (mode == .wrong_version) try std.testing.expectError(error.IncompleteReconciliationEvidence, owner.applyAdapterBatch(batch)) else try owner.applyAdapterBatch(batch);
    if (mode == .wrong_version) {
        // Each source fact commits separately; consume the valid remaining tail.
        var tail = false;
        for (batch.slice()) |record| {
            if (record.event == .account_reconciliation_result) {
                tail = true;
                continue;
            }
            if (tail) _ = try owner.apply(.{ .venue = record });
        }
    }
    try std.testing.expectEqualDeep(before.portfolio, owner.shard.economicSummary().portfolio);
    try std.testing.expectEqualDeep(before.exchange, owner.shard.economicSummary().exchange);
    try std.testing.expectEqual(@as(u8, 0), owner.shard.economic_projection.ledger_count - before.ledger_transactions);
    if (mode == .difference) {
        try std.testing.expect(owner.shard.economicSummary().reconciliation_break);
        try std.testing.expect(!owner.shard.operational_state.effectiveTradingAuthority());
    } else if (mode == .missing_range or mode == .late_fact or mode == .wrong_version) {
        try std.testing.expect(owner.shard.economic_fault_count > faults_before);
        try std.testing.expect(owner.shard.oms.recovery_only);
    } else if (mode == .fault) {
        try std.testing.expectEqual(faults_before, owner.shard.economic_fault_count);
        try std.testing.expect(!owner.shard.integritySnapshot().account_valid);
        try std.testing.expect(owner.shard.oms.recovery_only);
    } else if (mode == .unknown) {
        try std.testing.expect(owner.shard.oms.blocksNewSend());
        try std.testing.expect(!owner.shard.oms.openOrdersClosed());
    } else {
        try std.testing.expect(!owner.shard.economicSummary().reconciliation_break);
    }
    const once = owner.shard.canonicalStateDigest();
    try owner.applyAdapterBatch(batch);
    try std.testing.expectEqualSlices(u8, &once, &owner.shard.canonicalStateDigest());
    if (mode == .content_conflict) {
        var changed: canonical.AdapterOutputBatch = .{};
        for (batch.slice()) |record| {
            if (record.event != .account_reconciliation_result) continue;
            changed.events[0] = record;
            changed.events[0].envelope.identity.sequence += 100;
            changed.events[0].event.account_reconciliation_result.account_economics.?.balances[0].atoms += 1;
            changed.len = 1;
        }
        try std.testing.expectError(error.ConflictingEconomicIdentity, owner.applyAdapterBatch(changed));
        try std.testing.expect(owner.shard.economic_fault_count != 0);
        try std.testing.expectEqualDeep(before.exchange, owner.shard.economicSummary().exchange);
    }
    if (mode == .conflict) {
        const changed =
            \\{"code":"0","data":[{"uTime":"1800000000002","totalEq":"100","adjEq":"100","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"101","availBal":"101","eq":"101","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"},{"ccy":"BNB","cashBal":"10","availBal":"10","eq":"10","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
        ;
        try std.testing.expect((try implementation.ingestPrivateRest(private_times, .rest_balance, .{ .final = true }, changed)).rejection == .conflicting_fact);
        try std.testing.expect(try applyDrain(owner, adapter));
        try std.testing.expect(owner.shard.oms.recovery_only);
        try std.testing.expectEqualDeep(before.exchange, owner.shard.economicSummary().exchange);
    }
    if (mode == .stale_balance) try std.testing.expectEqual(@as(i128, 3_000_000_000_000), try owner.shard.currentNativeRiskCash(okx.btc_usdt_spot));
    if (mode == .stale_debt) try std.testing.expectError(error.ExchangeOpeningGateClosed, owner.shard.currentNativeRiskCash(okx.btc_usdt_spot));
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, store, io, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    const bytes = try std.heap.page_allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.heap.page_allocator.free(bytes);
    const restored = try std.heap.page_allocator.create(@import("../../../trading/trading_shard.zig").SnapshotRestore);
    defer std.heap.page_allocator.destroy(restored);
    restored.barrier = try @import("../../../trading/trading_shard.zig").TradingShard.restoreSnapshotInto(&restored.shard, try owner.committedSnapshot(bytes));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
}

test "independent native economic reconciliation matches multiple Assets without ledger writes" {
    try exercise(.matching);
}
test "independent native economic reconciliation finds mirrored local one atom error" {
    try exercise(.difference);
}
test "independent native economic reconciliation missing range and late facts remain unresolved" {
    try exercise(.missing_range);
    try exercise(.late_fact);
}
test "independent native economic reconciliation source identity conflict is durable" {
    try exercise(.conflict);
}
test "independent native economic reconciliation cannot heal numeric faults or Unknown" {
    try exercise(.fault);
    try exercise(.unknown);
}

fn exerciseInterval(owner: *demo.Owner, implementation: *okx.OkxVenueAdapter, chain: *live.Chain, store: durable.Store, io: std.Io, stream: durable.StreamIdentity, difference: bool, unapplied: bool, bad_query: bool, third_fee: bool, pagination: enum { single, complete, missing_tail, bad_cursor }, recover_raw: bool, incomplete_recovery: bool) !void {
    const adapter = implementation.adapter();
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 300, .exchange_account = 2, .expected_session = 1, .economic_boundary_utc_ns = 1_800_000_000_002_000_000, .economic_through_utc_ns = 1_800_000_000_200_000_000 } }));
    _ = try applyDrain(owner, adapter);
    const opening =
        \\{"code":"0","data":[{"uTime":"1800000000002","totalEq":"100","adjEq":"100","imr":"0","mmr":"0","isoEq":"0","details":[{"ccy":"USDT","cashBal":"100","availBal":"100","eq":"100","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"},{"ccy":"BTC","cashBal":"0","availBal":"0","eq":"0","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"},{"ccy":"BNB","cashBal":"10","availBal":"10","eq":"10","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    ;
    try std.testing.expect((try implementation.ingestPrivateRest(private_times, .rest_balance, .{ .final = true }, opening)).rejection == null);
    _ = try applyDrain(owner, adapter);
    var observed = fixture.canonicalAt(21, 1, .{ .instrument_definition_observed = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1 } });
    observed.venue.envelope.identity.stream = 700;
    _ = try owner.apply(observed);
    var book = fixture.canonicalAt(22, 2, .{ .l2_book_snapshot = .{ .instrument = okx.btc_usdt_spot, .sequence = 1, .best_bid = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 199_999 }, .best_ask = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 200_000 }, .best_bid_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 1_000_000 }, .best_ask_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 1_000_000 } } });
    book.venue.envelope.identity.stream = 700;
    _ = try owner.apply(book);
    const oms = @import("../../../execution/oms.zig");
    var group: oms.IntentGroup = .{ .first_intent_sequence = 400, .count = 1 };
    group.members[0] = .{ .intent_sequence = 400, .operation = .place, .instrument = okx.btc_usdt_spot, .side = .buy, .quantity = 1, .limit_price = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 200_000 } };
    _ = try owner.apply(.{ .core = .{ .identity = 400, .payload = .{ .oms_intent_group = group } } });
    try std.testing.expectEqual(@as(u8, 1), owner.shard.oms.command_history_count);
    const command = owner.shard.oms.command_history[0];
    try implementation.rememberRecoveredOrder(command.order_id, command.client_order_id, false, .{ .instrument = command.instrument, .rules_version = 1, .lots = 1 }, command.revision);
    var bytes: [4096]u8 = undefined;
    const fill = try std.fmt.bufPrint(&bytes,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"7001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0000001","px":"50000","accFillSz":"0.0000001","avgPx":"50000","uTime":"1800000000100","tradeId":"8001","fillSz":"0.0000001","fillPx":"50000","fillFee":"-0.000000000001","fillFeeCcy":"{s}","fillTime":"1800000000100","execType":"T"}}]}}
    , .{ command.client_order_id.slice(), if (third_fee) "BNB" else "USDT" });
    try std.testing.expect((try implementation.ingestPrivateWs(private_times, fill)).rejection == null);
    const actual = (try adapter.tryDrain()).?;
    if (!unapplied) try owner.applyAdapterBatch(actual);
    const before = owner.shard.economicSummary();
    if (!unapplied) {
        try std.testing.expectEqual(@as(i128, if (third_fee) 99_995_000_000_000 else 99_994_999_999_999), before.exchange.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, 100), before.exchange.spot_asset_atoms);
        try std.testing.expectEqual(@as(i128, if (third_fee) 0 else 1), before.exchange.fee_atoms);
    }
    const cash = if (difference) "99.994999999998" else if (third_fee) "99.995" else "99.994999999999";
    const change = if (difference) "-0.005000000002" else if (third_fee) "-0.005" else "-0.005000000001";
    const fee = if (difference) "-0.000000000002" else if (third_fee) "0" else "-0.000000000001";
    const third_bill = if (third_fee)
        \\{"billId":"9103","type":"2","instType":"SPOT","instId":"BTC-USDT","tradeId":"8001","ccy":"BNB","bal":"9.999999999999","balChg":"-0.000000000001","fee":"-0.000000000001","posBal":"0","posBalChg":"0","ts":"1800000000200"},
    else
        "";
    var padding: [2048]u8 = undefined;
    var padding_len: usize = 0;
    if (pagination != .single) {
        // Query padding is retained raw but cannot become interval money.
        for (0..6) |index| {
            const row = try std.fmt.bufPrint(padding[padding_len..],
                \\{{"billId":"{d}","ts":"1800000000002","ccy":"OUTSIDE","bal":"not-money"}},
            , .{9108 - index});
            padding_len += row.len;
        }
    }
    const bills = try std.fmt.bufPrint(&bytes,
        \\{{"code":"0","data":[{s}{s}{{"billId":"9102","type":"2","instType":"SPOT","instId":"BTC-USDT","tradeId":"8001","ccy":"BTC","bal":"0.0000001","balChg":"0.0000001","fee":"0","posBal":"0","posBalChg":"0","ts":"1800000000200"}},{{"billId":"9101","type":"2","instType":"SPOT","instId":"BTC-USDT","tradeId":"8001","ccy":"USDT","bal":"{s}","balChg":"{s}","fee":"{s}","posBal":"0","posBalChg":"0","ts":"1800000000200"}}]}}
    , .{ padding[0..padding_len], third_bill, cash, change, fee });
    const page: private.Page = .{ .final = pagination == .single, .request_target = if (bad_query) "/api/v5/account/bills?begin=1800000000001&end=1800000000202&limit=8" else "/api/v5/account/bills?begin=1800000000001&end=1800000000201&limit=8" };
    const parsed = try implementation.ingestPrivateRest(private_times, .rest_account_bills, page, bills);
    var cursor_fault = false;
    if (!bad_query and (pagination == .complete or pagination == .bad_cursor)) {
        try std.testing.expect(parsed.rejection == null);
        const tail = try implementation.ingestPrivateRest(private_times, .rest_account_bills, .{
            .final = true,
            .requested_after = if (pagination == .bad_cursor) 9102 else 9101,
            .request_target = if (pagination == .bad_cursor) "/api/v5/account/bills?begin=1800000000001&end=1800000000201&limit=8&after=9102" else "/api/v5/account/bills?begin=1800000000001&end=1800000000201&limit=8&after=9101",
        }, "{\"code\":\"0\",\"data\":[]}");
        if (pagination == .bad_cursor) {
            try std.testing.expectEqual(private.RejectReason.invalid_page_cursor, tail.rejection.?);
            cursor_fault = true;
        } else try std.testing.expect(tail.rejection == null);
    }
    if (bad_query or cursor_fault) {
        if (bad_query) try std.testing.expectEqual(private.RejectReason.invalid_page_cursor, parsed.rejection.?);
        _ = try applyDrain(owner, adapter);
        try std.testing.expect(owner.shard.economic_fault_count != 0);
    } else {
        try std.testing.expect(parsed.rejection == null);
        try std.testing.expect((try adapter.tryDrain()) == null);
        const closing = try std.fmt.bufPrint(&bytes,
            \\{{"code":"0","data":[{{"uTime":"1800000000200","totalEq":"100","adjEq":"100","imr":"0","mmr":"0","isoEq":"0","details":[{{"ccy":"USDT","cashBal":"{s}","availBal":"{s}","eq":"{s}","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}},{{"ccy":"BTC","cashBal":"0.0000001","availBal":"0.0000001","eq":"0.0000001","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}},{{"ccy":"BNB","cashBal":"{s}","availBal":"{s}","eq":"{s}","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}}]}}]}}
        , .{ cash, cash, cash, if (third_fee) "9.999999999999" else "10", if (third_fee) "9.999999999999" else "10", if (third_fee) "9.999999999999" else "10" });
        try std.testing.expect((try implementation.ingestPrivateRest(private_times, .rest_balance, .{ .final = true }, closing)).rejection == null);
        const proof = (try adapter.tryDrain()).?;
        const result = reconciliationResult(proof);
        const evidence = result.account_economics.?;
        try std.testing.expectEqual(pagination != .missing_tail, result.complete);
        try std.testing.expectEqual(@as(u16, if (pagination == .missing_tail) 0 else 1), evidence.covered_economic_fact_count);
        try std.testing.expectEqual(@as(u8, if (pagination == .complete) 2 else 1), evidence.query_count);
        if (recover_raw) {
            try checkEconomicSweep(owner, implementation, store, io, stream, proof, if (incomplete_recovery) 1 else 0);
            if (incomplete_recovery) try checkEconomicSweep(owner, implementation, store, io, stream, proof, 2);
            if (!incomplete_recovery) try checkEconomicSweep(owner, implementation, store, io, stream, proof, 0);
        }
        if (unapplied) try std.testing.expectError(error.IncompleteReconciliationEvidence, owner.applyAdapterBatch(proof)) else try owner.applyAdapterBatch(proof);
        if (pagination == .missing_tail) try std.testing.expect(owner.shard.economic_fault_count != 0);
        if (pagination != .missing_tail) try std.testing.expectEqual(difference, !evidence.facts[0].fee_confirmed);
        try std.testing.expectEqual(difference, owner.shard.economicSummary().reconciliation_break);
        if (!unapplied and pagination != .missing_tail) {
            const once = owner.shard.canonicalStateDigest();
            try owner.applyAdapterBatch(proof);
            try std.testing.expectEqualSlices(u8, &once, &owner.shard.canonicalStateDigest());
        }
    }
    try std.testing.expectEqualDeep(before.portfolio, owner.shard.economicSummary().portfolio);
    try std.testing.expectEqualDeep(before.exchange, owner.shard.economicSummary().exchange);
    if (unapplied or bad_query or cursor_fault or difference or pagination == .missing_tail) try std.testing.expect(!owner.shard.operational_state.effectiveTradingAuthority());
    const recovered = try std.heap.page_allocator.create(demo.Owner);
    defer std.heap.page_allocator.destroy(recovered);
    try demo.Owner.recoverInto(recovered, store, io, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    const snapshot = try std.heap.page_allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.heap.page_allocator.free(snapshot);
    const restored = try std.heap.page_allocator.create(@import("../../../trading/trading_shard.zig").SnapshotRestore);
    defer std.heap.page_allocator.destroy(restored);
    restored.barrier = try @import("../../../trading/trading_shard.zig").TradingShard.restoreSnapshotInto(&restored.shard, try owner.committedSnapshot(snapshot));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
}

test "independent native nonempty bill interval closes actual microfee and base cash once" {
    try exercise(.interval);
    try exercise(.interval_difference);
}

test "independent native bill interval cannot cover an unapplied Fill or a different HTTP range" {
    try exercise(.unapplied);
    try exercise(.bad_query);
}

fn reconciliationResult(batch: canonical.AdapterOutputBatch) canonical.ReconciliationResult {
    for (batch.slice()) |record| if (record.event == .account_reconciliation_result) return record.event.account_reconciliation_result;
    unreachable;
}

test "independent older REST snapshots cannot restore newer unavailable cash or debt proof" {
    try exercise(.stale_balance);
    try exercise(.stale_debt);
}

test "independent native proof rejects wrong precision and conflicting canonical content durably" {
    try exercise(.wrong_version);
    try exercise(.content_conflict);
}

test "independent native bill interval reconciles third asset microfees without USD valuation" {
    try exercise(.interval_third);
}

test "independent native bill pagination retains padded rows and requires exact continuation and terminal page" {
    try exercise(.interval_pages);
    try exercise(.interval_missing_tail);
    try exercise(.interval_bad_cursor);
}

fn checkEconomicSweep(owner: *demo.Owner, original: *okx.OkxVenueAdapter, store: durable.Store, io: std.Io, stream: durable.StreamIdentity, proof: canonical.AdapterOutputBatch, raw_cut: u2) !void {
    const recovery = @import("../../../adapters/okx/okx_private_recovery.zig");
    const allocator = std.heap.page_allocator;
    const raw_stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 1 };
    const boundary = try store.recover(io, raw_stream);
    const expected = try std.heap.page_allocator.create(@import("../../../trading/trading_shard.zig").TradingShard);
    defer std.heap.page_allocator.destroy(expected);
    @memcpy(std.mem.asBytes(expected), std.mem.asBytes(&owner.shard));
    for (proof.slice()) |record| _ = try expected.apply(.{ .venue = record });
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    try demo.Owner.recoverWithIngressInto(recovered, store, io, stream, raw_stream);
    try std.testing.expect(recovered.shard.recovery_admission_pending);
    var sink = try raw_ingress.DurableSink.recover(store, io, raw_stream);
    var transport = Transport{};
    var chain: live.Chain = .{ .mode = .replay, .qualification = qualification(), .raw_sink = sink.interface(), .transport = transport.interface() };
    var clock = Clock{};
    const implementation = try allocator.create(okx.OkxVenueAdapter);
    defer allocator.destroy(implementation);
    implementation.* = okx.OkxVenueAdapter.init(allocator, &chain, clock.interface(), profile(), original.rules);
    const reconciler = try allocator.create(private.Reconciler);
    defer allocator.destroy(reconciler);
    reconciler.* = .{};
    implementation.attachPrivateReconciler(reconciler);
    var committed = try recovery.CommittedInputs.init(store, io, stream);
    try implementation.adapter().start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry, .native_settlement_atoms = true });
    try implementation.beginPrivateSession();
    if (owner.shard.oms.command_history_count != 0) {
        const command = owner.shard.oms.command_history[0];
        try implementation.rememberRecoveredOrder(command.order_id, command.client_order_id, false, .{ .instrument = command.instrument, .rules_version = 1, .lots = command.quantity }, command.revision);
    }
    var sweep: recovery.Sweep = .{ .implementation = implementation, .owner = recovered, .index = &committed, .reconciliation_identity = 99, .last_sequence = boundary.committed_barrier - raw_cut };
    if (raw_cut != 0) {
        try std.testing.expectError(error.IncompletePrivateRecovery, recovered.replayCommittedIngress(raw_stream, sweep.consumer()));
        try std.testing.expect(recovered.shard.recovery_admission_pending);
        try std.testing.expectEqualDeep(owner.shard.economicSummary(), recovered.shard.economicSummary());
    } else {
        try recovered.replayCommittedIngress(raw_stream, sweep.consumer());
        try std.testing.expect(!recovered.shard.recovery_admission_pending);
        try std.testing.expectEqualSlices(u8, &expected.semanticAuthorityDigest(), &recovered.shard.semanticAuthorityDigest());
        try std.testing.expectEqualSlices(u8, &expected.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        try std.testing.expectEqualDeep(expected.economicSummary(), recovered.shard.economicSummary());
        for (proof.slice()) |record| {
            if (record.event != .account_reconciliation_result) continue;
            var encoded: [@import("../../../persistence/canonical_event_codec.zig").max_encoded_len]u8 = undefined;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(try @import("../../../persistence/canonical_event_codec.zig").encodePayload(&encoded, record.event), &digest, .{});
            try std.testing.expect(try recovered.shard.economic_projection.lookupCanonicalFact(@intCast(record.event.account_reconciliation_result.identity), .account_snapshot, digest));
        }
        try std.testing.expectEqual(@as(u64, 0), recovered.shard.economic_fault_count);
        const after = try store.recover(io, raw_stream);
        try std.testing.expectEqual(boundary.committed_barrier, after.committed_barrier);
        try std.testing.expectEqual(@as(u64, boundary.last_sequence + 1), sink.next_sequence);
        owner.* = recovered.*;
    }
    try std.testing.expectEqual(@as(usize, 0), transport.sends);
    try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
}

test "independent native nonempty proof raw sweep preserves scope query and admission without sends" {
    if (@import("builtin").os.tag != .windows) return;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var path_buffer: [260]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "C:\\Windows\\Temp\\ringwin-economic-proof-{d}", .{std.Io.Clock.real.now(io).nanoseconds});
    try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    for ([_]Case{ .interval_recovery, .interval_recovery_incomplete, .matching_recovery }) |mode| {
        var case_buffer: [280]u8 = undefined;
        const case_path = try std.fmt.bufPrint(&case_buffer, "{s}\\{s}", .{ path, @tagName(mode) });
        const file_store = try std.heap.page_allocator.create(durable.WindowsFileAdapter);
        defer std.heap.page_allocator.destroy(file_store);
        @memset(std.mem.asBytes(file_store), 0);
        try file_store.initWindowsVerification(io, case_path);
        defer file_store.close(io);
        try exerciseStored(mode, file_store.interface(), io);
    }
}
