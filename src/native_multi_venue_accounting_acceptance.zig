//! Offline actual-private-Adapter -> Owner precision evidence. No network authority.
const std = @import("std");
const canonical = @import("canonical_event.zig");
const durable = @import("durable_store.zig");
const demo = @import("demo_authority.zig");
const fixture = @import("trading_shard_fixture.zig");
const venue = @import("venue_adapter.zig");
const raw = @import("raw_ingress.zig");
const binance = @import("binance_venue_adapter.zig");
const binance_private = @import("binance_private_reconciliation.zig");
const binance_raw = @import("binance_order_raw.zig");
const bybit = @import("bybit_venue_adapter.zig");
const bybit_private = @import("bybit_private_reconciliation.zig");
const Kind = enum { binance, bybit };
const Case = enum { quote, base, quote_rebate, base_rebate, third_fee, third_rebate, zero, long_tail, unknown, inexact, overflow, extra_fees, unknown_no_pending, wallet_scope, report_first, store_append, store_commit, conflict, malformed_ws, single_fee };
const third: u128 = 0x424e42;
fn fixedTimes(comptime T: type) T {
    return .{ .receive_time_utc_ns = 1800000000000000000, .monotonic_time_ns = 2, .wall_time_utc_ns = 1800000000000000000 };
}

const Io = struct {
    raw_sink: *raw.DurableSink,
    origin: u16 = 0,
    sends: usize = 0,
    fn now(_: *anyopaque) u64 {
        return 1;
    }
    fn sign(_: *anyopaque, _: u64, _: []const u8) ![32]u8 {
        return @splat(0);
    }
    fn binanceSend(ptr: *anyopaque, _: binance.SignedRequest) binance.TransportResult {
        @as(*Io, @ptrCast(@alignCast(ptr))).sends += 1;
        return .{ .outcome = .proven_before_send, .source_session = 1, .times = fixedTimes(binance_raw.Times) };
    }
    fn bybitSend(ptr: *anyopaque, _: bybit.SignedRequest) bybit.TransportResult {
        @as(*Io, @ptrCast(@alignCast(ptr))).sends += 1;
        return .{ .outcome = .proven_before_send, .source_session = 1, .times = fixedTimes(bybit_private.Times) };
    }
    fn appendBinance(ptr: *anyopaque, record: binance_raw.RawIngressRecord, bytes: []const u8) binance_raw.RawSinkError!u64 {
        return append(ptr, record, bytes);
    }
    fn appendBybit(ptr: *anyopaque, record: bybit_private.RawIngressRecord, bytes: []const u8) bybit_private.RawSinkError!u64 {
        return append(ptr, record, bytes);
    }
    fn append(ptr: *anyopaque, record: anytype, bytes: []const u8) error{ Unavailable, Backpressure }!u64 {
        const self: *Io = @ptrCast(@alignCast(ptr));
        const evidence = self.raw_sink.interface().append(.{ .origin = self.origin, .source_session = record.source_session, .receive_time_utc_ns = record.receive_time_utc_ns, .monotonic_time_ns = record.monotonic_time_ns, .wall_time_utc_ns = record.wall_time_utc_ns, .byte_len = record.byte_len, .sha256 = record.sha256 }, bytes) catch return error.Unavailable;
        return evidence.stream_sequence;
    }
};

fn drain(owner: *demo.Owner, adapter: venue.VenueAdapter) !void {
    while (try adapter.tryDrain()) |batch| try owner.applyAdapterBatch(batch);
}

fn exercise(comptime kind: Kind, case: Case) ![32]u8 {
    const extra_fees = case == .extra_fees;
    const base_fee = case == .base or case == .base_rebate;
    const third_fee = case == .third_fee or case == .third_rebate;
    const rebate = case == .quote_rebate or case == .base_rebate or case == .third_rebate;
    const failure = extra_fees or case == .unknown or case == .unknown_no_pending or case == .inexact or case == .overflow or case == .wallet_scope or case == .malformed_ws or case == .single_fee;
    const fee_code = if (case == .unknown or case == .unknown_no_pending) "UNCONFIGURED" else if (base_fee) "BTC" else if (third_fee or case == .single_fee) "BNB" else "USDT";
    const fee_text = if (case == .single_fee) "0.000000000101" else if (case == .zero) "0" else if (case == .unknown) "0.000000000001" else if (case == .inexact) "0.0000000000001" else if (case == .overflow) "1701411834604692317316873037158841057280" else if (case == .long_tail) "+000.00000000000100000000000000000000000000000000000000000000000000000000000000" else if (base_fee) (if (rebate) "-0.000000001" else "0.000000001") else if (rebate) "-0.000000000001" else "0.000000000001";
    const Module = if (kind == .binance) binance else bybit;
    const input_times = fixedTimes(if (kind == .binance) binance_raw.Times else bybit_private.Times);
    const Private = if (kind == .binance) binance_private else bybit_private;
    const Adapter = if (kind == .binance) binance.BinanceVenueAdapter else bybit.BybitVenueAdapter;
    const venue_id: u128 = if (kind == .binance) 21 else 42;
    const instrument = Private.btc_usdt_spot;
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    const definitions = @import("asset_registry.zig").testDefinitions(12, 9);
    for (definitions) |definition| _ = try owner.apply(.{ .core = .{ .identity = definition.asset, .payload = .{ .asset_definition_activated = definition } } });
    var extra = definitions[0];
    extra.asset = third;
    extra.source_identity = third;
    if (case == .single_fee) extra.max_single_atoms = 100;
    for (extra.code_bindings[0..extra.code_binding_count]) |*code| code.* = try canonical.AssetCodeBinding.init(code.venue, "BNB");
    _ = try owner.apply(.{ .core = .{ .identity = third, .payload = .{ .asset_definition_activated = extra } } });
    if (third_fee) {
        // Trusted offline accounting prelude; this does not qualify either Venue's wallet scope.
        var opening: canonical.AccountBootstrapSnapshot = .{ .identity = 777, .exchange_account = 2, .source_stream = 777, .source_sequence = 1, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .balance_count = 3, .position_count = 0, .margin_count = 0 };
        const amount: canonical.AssetAmount = .{ .asset = third, .atoms = 10000000000000 };
        const zero: canonical.AssetAmount = .{ .asset = third, .atoms = 0 };
        opening.balances[0] = .{ .asset = third, .total = amount, .available = amount, .held = zero, .cash_balance = amount, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
        const cash: canonical.AssetAmount = .{ .asset = 1, .atoms = 100000000000000 };
        const cash_zero: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
        opening.balances[1] = .{ .asset = 1, .total = cash, .available = cash, .held = cash_zero, .cash_balance = cash, .liability = cash_zero, .isolated_liability = cash_zero, .cross_liability = cash_zero };
        const base_zero: canonical.AssetAmount = .{ .asset = 0x425443, .atoms = 0 };
        opening.balances[2] = .{ .asset = 0x425443, .total = base_zero, .available = base_zero, .held = base_zero, .cash_balance = base_zero, .liability = base_zero, .isolated_liability = base_zero, .cross_liability = base_zero };
        var source = fixture.canonicalAt(19, 1, .{ .account_bootstrap_snapshot = opening });
        source.venue.envelope.identity.stream = 777;
        source.venue.envelope.source_stream = 777;
        source.venue.envelope.venue = venue_id;
        _ = try owner.apply(source);
    }
    for (fixture.genesisEvents(.{ .strategy_identity = 40, .config_version = 1, .activation_identity = 50, .activation_barrier = 1 }, .cash)) |original| {
        var event = original;
        switch (event.core.payload) {
            .instrument_rules_activated => |*rules| {
                if (rules.instrument_identity == fixture.spot_instrument) continue;
                if (rules.instrument_identity == 3) {
                    rules.instrument_identity = instrument;
                    rules.quantity_denominator = 10000000;
                    rules.quantity_numerator = 2;
                }
                rules.venue = venue_id;
            },
            .margin_rules_activated => |*margin| {
                if (margin.instrument == fixture.spot_instrument) continue;
                if (margin.instrument == 3) margin.instrument = instrument;
                margin.native_settlement_atoms = true;
                margin.price_tick_atoms = 250000000000;
            },
            .mark_price => |*mark| {
                if (mark.instrument == fixture.spot_instrument) continue;
                if (mark.instrument == 3) mark.instrument = instrument;
                mark.price_atoms = 50000000000000000;
            },
            .asset_definition_activated => |*definition| definition.* = if (definition.asset == 1) definitions[0] else definitions[1],
            .exchange_balance => |*balance| balance.cash_atoms = 100000000000000,
            .opening_balance => |*balance| {
                balance.cash_atoms = 100000000000000;
                if (third_fee) {
                    balance.native_balance_count = 1;
                    balance.native_balances[0] = .{ .asset = third, .atoms = 10000000000000 };
                }
            },
            .portfolio_transfer => |*transfer| transfer.amount_atoms = 90000000000000,
            .risk_lease_granted => |*lease| lease.amount_atoms = 80000000000000,
            else => {},
        }
        _ = owner.apply(event) catch |err| {
            std.debug.print("native multi prelude kind={s} error={s}\n", .{ @tagName(event.core.payload), @errorName(err) });
            return err;
        };
    }
    var book = fixture.canonicalAt(18, 1, .{ .l2_book_snapshot = .{ .instrument = instrument, .sequence = 1, .best_bid = .{ .instrument = instrument, .rules_version = 1, .ticks = 199999 }, .best_ask = .{ .instrument = instrument, .rules_version = 1, .ticks = 200000 }, .best_bid_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 100 }, .best_ask_quantity = .{ .instrument = instrument, .rules_version = 1, .lots = 100 } } });
    book.venue.envelope.identity.stream = 999;
    book.venue.envelope.source_stream = 999;
    book.venue.envelope.venue = venue_id;
    _ = try owner.apply(book);
    var group: @import("oms.zig").IntentGroup = .{ .first_intent_sequence = 90, .count = 1 };
    group.members[0] = .{ .intent_sequence = 90, .operation = .place, .instrument = instrument, .side = .buy, .quantity = 1, .limit_price = .{ .instrument = instrument, .rules_version = 1, .ticks = 200000 } };
    _ = try owner.apply(.{ .core = .{ .identity = 90, .payload = .{ .oms_intent_group = group } } });
    try std.testing.expectEqual(@as(u8, 1), owner.shard.oms.command_history_count);
    const command = owner.shard.oms.command_history[0];
    try owner.sealBootstrap();
    var sink = try raw.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 1 });
    var io: Io = .{ .raw_sink = &sink };
    const private_sink = if (kind == .binance) binance_raw.RawSink{ .ptr = &io, .append_fn = Io.appendBinance } else bybit_private.RawSink{ .ptr = &io, .append_fn = Io.appendBybit };
    const profile: Module.CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1, .spot = .{ .identity = instrument, .tick_size = .{ .coefficient = 25, .scale = 2 }, .lot_size = .{ .coefficient = 2, .scale = 7 } }, .linear = .{ .identity = Private.btc_usdt_linear, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } } };
    var implementation = Adapter.init(.{ .ptr = &io, .now_fn = Io.now }, profile, .{ .ptr = &io, .sign_fn = Io.sign }, private_sink, .{ .ptr = &io, .submit_fn = if (kind == .binance) Io.binanceSend else Io.bybitSend });
    var reconciler = Private.Reconciler.init(private_sink, .{ .spot = .{ .identity = instrument, .rules_version = 1, .tick_size = profile.spot.tick_size, .lot_size = profile.spot.lot_size }, .linear = .{ .identity = Private.btc_usdt_linear, .rules_version = 1, .tick_size = profile.linear.tick_size, .lot_size = profile.linear.lot_size } });
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = venue_id, .exchange_account = 2, .adapter_session = 1, .environment = .demo, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry, .native_settlement_atoms = true });
    try implementation.beginPrivateReconciliation();
    if (case != .unknown_no_pending and case != .single_fee) try reconciler.registerOrder(command.order_id, command.client_order_id, false);
    if (kind == .binance) {
        _ = try implementation.ingestPrivate(allocator, .rest_spot_account, .{ .final = true, .request_target = "/api/v3/account" }, input_times, "{\"accountType\":\"SPOT\",\"updateTime\":1800000000000,\"balances\":[{\"asset\":\"USDT\",\"free\":\"100\",\"locked\":\"0\"},{\"asset\":\"BTC\",\"free\":\"0\",\"locked\":\"0\"},{\"asset\":\"BNB\",\"free\":\"10\",\"locked\":\"0\"}]}");
        _ = try implementation.ingestPrivate(allocator, .rest_orders, .{ .final = true }, input_times, "[]");
        _ = try implementation.ingestPrivate(allocator, .rest_fills, .{ .final = true }, input_times, "[]");
    } else {
        _ = try implementation.ingestPrivate(allocator, .rest_wallet, .{ .final = true }, input_times, "{\"result\":{\"list\":[]}}");
        _ = try implementation.ingestPrivate(allocator, .rest_positions, .{ .final = true }, input_times, "{\"result\":{\"list\":[]}}");
        _ = try implementation.ingestPrivate(allocator, .rest_orders, .{ .final = true }, input_times, "{\"result\":{\"list\":[]}}");
        _ = try implementation.ingestPrivate(allocator, .rest_executions, .{ .final = true }, input_times, "{\"result\":{\"list\":[]}}");
    }
    try drain(owner, adapter);
    var bytes: [2048]u8 = undefined;
    const frame = if (kind == .binance) try std.fmt.bufPrint(&bytes,
        \\{{"e":"executionReport","E":"1800000000100","s":"BTCUSDT","c":"{s}","S":"BUY","o":"LIMIT","f":"GTC","q":"0.0000002","p":"50000","X":"FILLED","i":"42","l":"0.0000002","z":"0.0000002","L":"50000","n":"{s}","N":"{s}","T":"1800000000100","t":"77","m":true}}
    , .{ command.client_order_id.slice(), fee_text, fee_code }) else try std.fmt.bufPrint(&bytes,
        \\{{"topic":"execution","data":[{{"category":"spot","symbol":"BTCUSDT","orderId":"42","orderLinkId":"{s}","execId":"77","side":"Buy","execQty":"0.0000002","execPrice":"50000","execFee":"{s}","feeCurrency":"{s}","execPnl":"0","execTime":"1800000000100","isMaker":true{s}}}]}}
    , .{ command.client_order_id.slice(), fee_text, fee_code, if (extra_fees) ",\"extraFees\":[{\"feeCoin\":\"USDT\",\"fee\":\"0.1\"}]" else "" });
    var order_bytes: [1024]u8 = undefined;
    const order_frame = try std.fmt.bufPrint(&order_bytes,
        \\{{"topic":"order","data":[{{"category":"spot","symbol":"BTCUSDT","orderId":"42","orderLinkId":"{s}","side":"Buy","orderType":"Limit","timeInForce":"GTC","orderStatus":"Filled","qty":"0.0000002","cumExecQty":"0.0000002","price":"50000","avgPrice":"50000","updatedTime":"1800000000100","reduceOnly":false}}]}}
    , .{command.client_order_id.slice()});
    if (kind == .bybit and case == .report_first) {
        _ = try implementation.ingestPrivate(allocator, .ws, null, input_times, order_frame);
        try drain(owner, adapter);
    }
    const before = owner.shard.economicSummary();
    if (case == .store_append or case == .store_commit) {
        _ = try implementation.ingestPrivate(allocator, .ws, null, input_times, frame);
        const batch = (try adapter.tryDrain()).?;
        memory.injectFaultAt(.eio, if (case == .store_append) .append else .commit);
        try std.testing.expectError(error.DecisionLogUnavailable, owner.applyAdapterBatch(batch));
        try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
        try std.testing.expectError(error.DecisionLogUnavailable, demo.Owner.recover(memory.interface(), undefined, stream));
        const preserved = try memory.interface().recover(undefined, .{ .domain = .raw_ingress, .id = 1 });
        try std.testing.expectEqual(preserved.last_sequence, preserved.committed_barrier);
        try std.testing.expect(preserved.committed_barrier != 0);
        try std.testing.expectEqual(@as(usize, 0), io.sends);
        return owner.shard.semanticAuthorityDigest();
    }
    if (failure) {
        const expected_error = if (extra_fees) error.UnsupportedFeeComponents else if (case == .unknown or case == .unknown_no_pending) error.UnsupportedAsset else if (case == .inexact) error.InexactDecimal else if (case == .wallet_scope) error.UnsupportedWalletScope else if (case == .malformed_ws) error.InvalidFrame else if (case == .single_fee) error.AssetAmountOutOfRange else error.DecimalOverflow;
        try std.testing.expectError(expected_error, implementation.ingestPrivate(allocator, .ws, null, input_times, if (case == .malformed_ws) "{" else if (case == .wallet_scope) "{\"topic\":\"wallet\",\"data\":[{\"accountType\":\"UNIFIED\",\"coin\":[{\"coin\":\"USDT\",\"walletBalance\":\"100\",\"spotBorrow\":\"0\",\"borrowAmount\":\"0\",\"locked\":\"0\"}]}]}" else frame));
        try drain(owner, adapter);
        try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
        try std.testing.expectEqual(@as(u64, 1), owner.shard.economic_fault_count);
        try std.testing.expect(owner.shard.oms.recovery_only);
    } else {
        _ = try implementation.ingestPrivate(allocator, .ws, null, input_times, frame);
        try drain(owner, adapter);
        if (kind == .bybit and case != .report_first) {
            _ = try implementation.ingestPrivate(allocator, .ws, null, input_times, order_frame);
            try drain(owner, adapter);
        }
        try std.testing.expectEqual(@as(i64, 1), owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
        try std.testing.expectEqual(@as(i128, if (!base_fee and !third_fee and !rebate and case != .zero) 1 else 0), owner.shard.economicSummary().portfolio.fee_atoms);
        try std.testing.expectEqual(@as(i128, if (base_fee) (if (rebate) 201 else 199) else 200), owner.shard.economicSummary().portfolio.spot_asset_atoms);
        try std.testing.expectEqual(@as(i128, if (base_fee or third_fee or case == .zero) 89990000000000 else if (rebate) 89990000000001 else 89989999999999), owner.shard.economicSummary().portfolio.usdt_balance_atoms);
    }
    if (third_fee) {
        const economic = owner.shard.economicSummary();
        try std.testing.expectEqual(@as(i128, if (rebate) 10000000000001 else 9999999999999), economic.exchange.native_assets[0].balance_atoms);
        try std.testing.expectEqual(@as(i128, if (rebate) 1 else -1), economic.portfolio.native_assets[0].balance_atoms);
        try std.testing.expect(!economic.valuation_complete);
        try owner.shard.assertClosures();
    }
    const once = owner.shard.canonicalStateDigest();
    if (!failure) {
        _ = try implementation.ingestPrivate(allocator, .ws, null, input_times, frame);
        try drain(owner, adapter);
    }
    try std.testing.expectEqualSlices(u8, &once, &owner.shard.canonicalStateDigest());
    if (case == .conflict) {
        const before_conflict = owner.shard.economicSummary();
        const fee_at = std.mem.indexOf(u8, frame, "0.000000000001").?;
        bytes[fee_at + 13] = '2';
        try std.testing.expectError(error.ConflictingFact, implementation.ingestPrivate(allocator, .ws, null, input_times, frame));
        try drain(owner, adapter);
        try std.testing.expectEqualDeep(before_conflict, owner.shard.economicSummary());
        try std.testing.expect(owner.shard.oms.recovery_only);
        try std.testing.expectEqual(@as(u64, 1), owner.shard.economic_fault_count);
    }
    const final_digest = owner.shard.canonicalStateDigest();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &final_digest, &recovered.shard.canonicalStateDigest());
    var snapshot: [durable.max_snapshot_bytes]u8 = undefined;
    const restored = try @import("trading_shard.zig").TradingShard.restoreSnapshot(try owner.committedSnapshot(&snapshot));
    try std.testing.expectEqualSlices(u8, &final_digest, &restored.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(usize, 0), io.sends);
    var config_bytes: [32768]u8 = undefined;
    const config = try @import("snapshot_codec.zig").encodeBare(&config_bytes, owner.shard.asset_registry);
    var config_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(config, &config_digest, .{});
    const committed_raw = try memory.interface().recover(undefined, .{ .domain = .raw_ingress, .id = 1 });
    std.debug.print("precision13 venue={s} case={s} assets_sha256={s} decision_barrier={d} raw_barrier={d} canonical={s} semantic={s} sends=0\n", .{ @tagName(kind), @tagName(case), std.fmt.bytesToHex(config_digest, .lower), owner.shard.trace.len, committed_raw.committed_barrier, std.fmt.bytesToHex(final_digest, .lower), std.fmt.bytesToHex(owner.shard.semanticAuthorityDigest(), .lower) });
    return owner.shard.semanticAuthorityDigest();
}

test "native multi Venue actual Binance and Bybit microfees reach the same Owner ledger and replay" {
    _ = try exercise(.binance, .quote);
    _ = try exercise(.bybit, .quote);
}

test "native multi Venue Bybit extra fee components remain unresolved instead of omitting cash charges" {
    _ = try exercise(.bybit, .extra_fees);
}

test "native multi Venue shared base quote fee rebate zero and normalized long tail matrix" {
    inline for ([_]Kind{ .binance, .bybit }) |kind| for ([_]Case{ .base, .quote_rebate, .base_rebate, .third_fee, .third_rebate, .zero, .long_tail }) |case| {
        _ = try exercise(kind, case);
    };
}

test "native multi Venue shared unknown subatom and overflow faults recover without partial accounting" {
    inline for ([_]Kind{ .binance, .bybit }) |kind| for ([_]Case{ .unknown, .unknown_no_pending, .inexact, .overflow }) |case| {
        _ = try exercise(kind, case);
    };
}

test "native multi Venue Bybit modern wallet scope faults persist and order report may precede unique fill" {
    _ = try exercise(.bybit, .wallet_scope);
    const fill_first = try exercise(.bybit, .quote);
    const report_first = try exercise(.bybit, .report_first);
    try std.testing.expectEqualSlices(u8, &fill_first, &report_first);
}

test "native multi Venue decision append and commit failure preserve source and prevent replay sends" {
    inline for ([_]Kind{ .binance, .bybit }) |kind| for ([_]Case{ .store_append, .store_commit }) |case| {
        _ = try exercise(kind, case);
    };
}

test "native multi Venue conflicting economic identity preserves original ledger and restart fence" {
    inline for ([_]Kind{ .binance, .bybit }) |kind| {
        _ = try exercise(kind, .conflict);
    }
}

test "native multi Venue malformed private frame persists decoder rejection through restart" {
    inline for ([_]Kind{ .binance, .bybit }) |kind| {
        _ = try exercise(kind, .malformed_ws);
    }
}

test "native multi Venue unlinked fee obeys single limit separately from account balance limit" {
    inline for ([_]Kind{ .binance, .bybit }) |kind| {
        _ = try exercise(kind, .single_fee);
    }
}
