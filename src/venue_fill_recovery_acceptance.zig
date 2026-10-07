//! Offline public-seam evidence for venue fill recovery.  The raw frames below
//! are deliberately fed only to the OKX adapter; Owner receives canonical facts.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const durable = @import("durable_store.zig");
const demo = @import("demo_authority.zig");
const failover = @import("failover.zig");
const fixture = @import("trading_shard_fixture.zig");
const venue = @import("venue_adapter.zig");
const okx = @import("okx_venue_adapter.zig");
const live = @import("okx_live_chain.zig");
const order = @import("okx_order_entry.zig");
const private = @import("okx_private_reconciliation.zig");
const host = @import("strategy_host_gateway.zig");
const raw_ingress = @import("raw_ingress.zig");

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
    fn interface(self: *Transport) live.Transport {
        return .{ .ptr = self, .submit_fn = submit };
    }

    fn submit(_: *anyopaque, _: []const u8, _: []const u8) live.TransportResult {
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

/// The market and dispatch prelude is a separate canonical source from the
/// private adapter session, so its fixture cursors cannot make raw private
/// evidence look stale.
fn fixtureOnSecondaryStream(group: u64, sequence: u64, event: canonical.Payload) @import("trading_shard.zig").CanonicalEvent {
    var result = fixture.canonicalAt(group, sequence, event);
    result.venue.envelope.identity.stream = 2;
    result.venue.envelope.source_stream = 2;
    result.venue.envelope.raw_evidence.stream = 2;
    return result;
}

fn snapshotOnSecondaryStream(group: u64, sequence: u64) @import("trading_shard.zig").CanonicalEvent {
    var result = fixture.snapshotAt(group, sequence);
    result.venue.envelope.identity.stream = 2;
    result.venue.envelope.source_stream = 2;
    result.venue.envelope.raw_evidence.stream = 2;
    return result;
}

fn replayCommittedOkx(implementation: *okx.OkxVenueAdapter, raw_store: durable.Store, raw_stream: durable.StreamIdentity) !usize {
    const adapter = implementation.adapter();
    const Context = struct {
        implementation: *okx.OkxVenueAdapter,
        adapter: venue.VenueAdapter,
        reconciliation_started: bool = false,
        output_count: usize = 0,

        fn drain(self: *@This()) !void {
            if (try self.adapter.tryDrain()) |output| self.output_count += output.slice().len;
        }

        fn consume(ptr: *anyopaque, evidence_sequence: u64, record: @import("okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const times: private.Times = .{
                .receive_time_utc_ns = record.receive_time_utc_ns,
                .monotonic_time_ns = record.monotonic_time_ns,
                .wall_time_utc_ns = record.wall_time_utc_ns,
            };
            const evidence: private.RawEvidenceRef = .{ .stream_sequence = evidence_sequence, .sha256 = record.sha256 };
            if (record.origin == 0) {
                try std.testing.expect((try self.implementation.replayPrivateWs(times, evidence, bytes)).rejection == null);
                try self.drain();
                return;
            }
            if (record.origin - 1 > @intFromEnum(private.IngressSource.rest_fills_history_swap))
                return error.InvalidReplayRoute;
            if (!self.reconciliation_started) {
                try std.testing.expectEqual(venue.SendResult.accepted, try self.adapter.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 1 } }));
                self.reconciliation_started = true;
                try self.drain();
            }
            const source: private.IngressSource = @enumFromInt(record.origin - 1);
            try std.testing.expect((try self.implementation.replayPrivateRest(times, source, .{ .final = true }, evidence, bytes)).rejection == null);
            try self.drain();
        }
    };
    var context: Context = .{ .implementation = implementation, .adapter = adapter };
    try raw_ingress.replayCommitted(raw_store, undefined, raw_stream, .{ .ptr = &context, .consume_fn = Context.consume });
    try std.testing.expect(context.reconciliation_started);
    return context.output_count;
}

/// Reconstruct only the raw prefix that ended at a two-fact private frame.
/// Earlier replayed facts rebuild adapter state; only the still-uncommitted
/// Fill crosses the Owner recovery boundary.
fn replayCommittedFillTail(implementation: *okx.OkxVenueAdapter, raw_store: durable.Store, raw_stream: durable.StreamIdentity, last_sequence: u64, expected_fill: canonical.EventRecord) !void {
    const adapter = implementation.adapter();
    const Context = struct {
        implementation: *okx.OkxVenueAdapter,
        adapter: venue.VenueAdapter,
        last_sequence: u64,
        expected_fill: canonical.EventRecord,
        reconciliation_started: bool = false,

        fn drain(self: *@This(), sequence: u64) !void {
            const output = (try self.adapter.tryDrain()) orelse return;
            if (sequence != self.last_sequence) return;
            try std.testing.expectEqual(@as(usize, 2), output.slice().len);
            try std.testing.expect(output.slice()[0].event == .execution_report);
            try std.testing.expect(output.slice()[1].event == .fill);
            try std.testing.expect(std.meta.eql(self.expected_fill.envelope, output.slice()[1].envelope));
            try std.testing.expect(std.meta.eql(self.expected_fill.event, output.slice()[1].event));
        }

        fn consume(ptr: *anyopaque, sequence: u64, record: @import("okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (sequence > self.last_sequence) return;
            const times: private.Times = .{
                .receive_time_utc_ns = record.receive_time_utc_ns,
                .monotonic_time_ns = record.monotonic_time_ns,
                .wall_time_utc_ns = record.wall_time_utc_ns,
            };
            const evidence: private.RawEvidenceRef = .{ .stream_sequence = sequence, .sha256 = record.sha256 };
            if (record.origin == 0) {
                try std.testing.expect((try self.implementation.replayPrivateWs(times, evidence, bytes)).rejection == null);
                return self.drain(sequence);
            }
            if (record.origin - 1 > @intFromEnum(private.IngressSource.rest_fills_history_swap)) return error.InvalidReplayRoute;
            if (!self.reconciliation_started) {
                try std.testing.expectEqual(venue.SendResult.accepted, try self.adapter.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 1 } }));
                self.reconciliation_started = true;
                try self.drain(sequence);
            }
            const source: private.IngressSource = @enumFromInt(record.origin - 1);
            try std.testing.expect((try self.implementation.replayPrivateRest(times, source, .{ .final = true }, evidence, bytes)).rejection == null);
            try self.drain(sequence);
        }
    };
    var context: Context = .{ .implementation = implementation, .adapter = adapter, .last_sequence = last_sequence, .expected_fill = expected_fill };
    try raw_ingress.replayCommitted(raw_store, undefined, raw_stream, .{ .ptr = &context, .consume_fn = Context.consume });
    try std.testing.expect(context.reconciliation_started);
}

fn executeRawPrivateFillRecovery() !void {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const raw_stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 1 };
    var raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, raw_stream);
    var transport = Transport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = Clock{};
    var reconciler: private.Reconciler = .{};
    var implementation = okx.OkxVenueAdapter.init(allocator, &chain, clock.interface(), profile(), rules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    try @import("venue_adapter_contract.zig").activateTestAssets(owner);
    try adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
    try implementation.beginPrivateSession();

    const subscriptions = [_][]const u8{
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
    for (subscriptions) |frame| try std.testing.expect((try implementation.ingestPrivateWs(private_times, frame)).rejection == null);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 1 } }));
    try std.testing.expect(try applyDrain(owner, adapter));
    try ingestBootstrapRound(&implementation);
    try std.testing.expect(!try applyDrain(owner, adapter));
    try ingestBootstrapRound(&implementation);
    try std.testing.expect(try applyDrain(owner, adapter));
    try std.testing.expect(owner.shard.canonical_account.valid);

    var parsed = try demo.Policy.parse(allocator,
        \\{"schema":3,"lot_size":{"coefficient":1,"scale":8},"price_tick_atoms":100000,"startup":"virgin","exchange_account":2,"portfolio_identity":1,"strategy_identity":40,"activation_identity":50,"config_version":1,"portfolio_allocation_atoms":20000000,"risk_limit_atoms":15000000,"decision_stream_id":91,"dispatch_stream_id":92,"decision_domain":1,"node_identity":1}
    );
    defer parsed.deinit();
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try parsed.value.initialize(owner, 50_000_000_000, &guard, 1, 1);
    _ = try owner.apply(fixtureOnSecondaryStream(18, 2, .{ .instrument_definition_observed = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1 } }));
    var book = snapshotOnSecondaryStream(19, 3);
    book.venue.event.l2_book_snapshot.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_bid.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_ask.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_bid_quantity.?.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_ask_quantity.?.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.next_ask.?.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.next_ask_quantity.?.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_bid.ticks = 499_999;
    book.venue.event.l2_book_snapshot.best_ask.ticks = 500_000;
    book.venue.event.l2_book_snapshot.next_ask.?.ticks = 500_001;
    _ = try owner.apply(book);

    const sequence = owner.shard.trace.len + 1;
    const intent: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = sequence, .strategy_cursor = owner.shard.trace.len, .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = .buy, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 20_000, .limit_price_micros = 50_000_000_000 };
    const command = (try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = intent } } })) orelse return error.MissingDemoCommand;
    try implementation.rememberRecoveredOrder(command.order_id, command.client_order_id, command.portfolio_reduce_only, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
    _ = try owner.apply(fixtureOnSecondaryStream(20, 4, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .submitted } }));

    var frame: [1024]u8 = undefined;
    const first = try std.fmt.bufPrint(&frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"partially_filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0002","px":"50000","accFillSz":"0.0001","avgPx":"50000","uTime":"1800000000100","tradeId":"2001","fillSz":"0.0001","fillPx":"50000","fillFee":"-0.000001","fillFeeCcy":"BTC","fillTime":"1800000000100","execType":"M"}}]}}
    , .{command.client_order_id.slice()});
    const first_ingress = try implementation.ingestPrivateWs(private_times, first);
    try std.testing.expect(first_ingress.rejection == null);
    const first_batch = (try adapter.tryDrain()) orelse return error.MissingPrivateBatch;
    try std.testing.expectEqual(@as(usize, 2), first_batch.slice().len);
    try std.testing.expect(first_batch.slice()[0].event == .execution_report);
    try std.testing.expect(first_batch.slice()[1].event == .fill);
    _ = try owner.apply(.{ .venue = first_batch.slice()[0] });
    // The interrupted recovery branch owns a separate copy of the committed
    // store; two live Owners must not append through stale journal cursors.
    const tail_memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(tail_memory);
    tail_memory.* = memory.*;
    const after_report = try allocator.create(demo.Owner);
    defer allocator.destroy(after_report);
    after_report.* = try demo.Owner.recover(tail_memory.interface(), undefined, stream);
    const report_digest = after_report.shard.canonicalStateDigest();
    const raw_replayed_after_report = try allocator.create(demo.Owner);
    defer allocator.destroy(raw_replayed_after_report);
    raw_replayed_after_report.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    var tail_raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 3 });
    var tail_chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = tail_raw.interface(), .transport = transport.interface() };
    var tail_clock = Clock{};
    var tail_reconciler: private.Reconciler = .{};
    var tail_implementation = okx.OkxVenueAdapter.init(allocator, &tail_chain, tail_clock.interface(), profile(), rules());
    tail_implementation.attachPrivateReconciler(&tail_reconciler);
    const tail_adapter = tail_implementation.adapter();
    try tail_adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = after_report.shard.activatedAssets(), .instrument_definitions = after_report.shard.instrument_registry });
    try tail_implementation.beginPrivateSession();
    try tail_implementation.rememberRecoveredOrder(command.order_id, command.client_order_id, command.portfolio_reduce_only, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
    try replayCommittedFillTail(&tail_implementation, memory.interface(), raw_stream, first_ingress.raw_evidence.stream_sequence, first_batch.slice()[1]);
    try std.testing.expectEqual(@as(u64, 1), tail_raw.next_sequence);
    try std.testing.expectEqualSlices(u8, &report_digest, &raw_replayed_after_report.shard.canonicalStateDigest());
    const CountingRaw = struct {
        calls: u64 = 0,

        fn interface(self: *@This()) private.RawSink {
            return .{ .ptr = self, .append_fn = append };
        }

        fn append(ptr: *anyopaque, _: @import("okx_public_market.zig").RawIngressRecord, _: []const u8) private.RawSinkError!u64 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return self.calls;
        }
    };
    var capacity_raw = CountingRaw{};
    tail_chain.raw_sink = capacity_raw.interface();
    var capacity_index: u64 = 0;
    while (capacity_index < 45) : (capacity_index += 1) {
        var client_bytes: [32]u8 = undefined;
        const client = try std.fmt.bufPrint(&client_bytes, "RWN{d:0>8}", .{capacity_index + 10_000});
        const client_order_id = try canonical.ClientOrderId.init(client);
        try tail_implementation.rememberRecoveredOrder(@intCast(capacity_index + 10_000), client_order_id, false, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = 10_000 }, 1);
        var capacity_frame: [768]u8 = undefined;
        const raw_capacity_frame = try std.fmt.bufPrint(&capacity_frame,
            \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"{d}","clOrdId":"{s}","side":"buy","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0001","px":"50000","accFillSz":"0.0001","avgPx":"50000","uTime":"1800000000400","tradeId":"{d}","fillSz":"0.0001","fillPx":"50000","fillFee":"0","fillFeeCcy":"USDT","fillTime":"1800000000400","execType":"T"}}]}}
        , .{ capacity_index + 10_000, client, capacity_index + 20_000 });
        try std.testing.expect((try tail_implementation.ingestPrivateWs(private_times, raw_capacity_frame)).rejection == null);
    }
    const raw_before_capacity_rejection = capacity_raw.calls;
    var deferred_frame: [1024]u8 = undefined;
    const deferred_fault = try std.fmt.bufPrint(&deferred_frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"partially_filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0002","px":"50000","accFillSz":"0.0001","avgPx":"50000","uTime":"1800000000500","tradeId":"99999","fillSz":"0.0001","fillPx":"50000","fillFee":"-0.0000001","fillFeeCcy":"USDT","fillTime":"1800000000500","execType":"T"}}]}}
    , .{command.client_order_id.slice()});
    try std.testing.expectError(error.OutputPending, tail_implementation.ingestPrivateWs(private_times, deferred_fault));
    try std.testing.expectEqual(raw_before_capacity_rejection, capacity_raw.calls);
    var drained_capacity_events: usize = 0;
    while (try tail_adapter.tryDrain()) |output| drained_capacity_events += output.slice().len;
    try std.testing.expectEqual(@as(usize, 90), drained_capacity_events);
    const accepted_fault = try tail_implementation.ingestPrivateWs(private_times, deferred_fault);
    try std.testing.expect(accepted_fault.rejection == null);
    const deferred_output = (try tail_adapter.tryDrain()) orelse return error.MissingEconomicFault;
    var saw_deferred_fault = false;
    for (deferred_output.slice()) |record| if (record.event == .economic_fault) {
        try std.testing.expectEqual(canonical.EconomicFaultReason.inexact_amount, record.event.economic_fault.reason);
        try std.testing.expectEqual(accepted_fault.raw_evidence.stream_sequence, record.envelope.raw_evidence.sequence);
        saw_deferred_fault = true;
    };
    try std.testing.expect(saw_deferred_fault);
    var fill_tail: canonical.AdapterOutputBatch = .{};
    try fill_tail.append(first_batch.slice()[1]);
    try after_report.applyAdapterBatch(fill_tail);
    try std.testing.expectEqual(@as(i64, 10_000), try after_report.shard.economic_projection.appliedCanonicalFillQuantity(@intCast(command.order_id)));
    const fill_digest = after_report.shard.canonicalStateDigest();
    try std.testing.expect(!std.mem.eql(u8, &report_digest, &fill_digest));
    const after_fill = try allocator.create(demo.Owner);
    defer allocator.destroy(after_fill);
    after_fill.* = try demo.Owner.recover(tail_memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &fill_digest, &after_fill.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(i64, 10_000), try after_fill.shard.economic_projection.appliedCanonicalFillQuantity(@intCast(command.order_id)));
    // The recovered Owner remains behind its process admission fence. Continue
    // the live Owner after committing the same missing Fill independently.
    try owner.applyAdapterBatch(fill_tail);
    try std.testing.expectEqualSlices(u8, &fill_digest, &owner.shard.canonicalStateDigest());
    const second = try std.fmt.bufPrint(&frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0002","px":"50000","accFillSz":"0.0002","avgPx":"50000","uTime":"1800000000200","tradeId":"2002","fillSz":"0.0001","fillPx":"50000","fillFee":"-0.01","fillFeeCcy":"USDT","rebate":"0.001","rebateCcy":"USDT","fillTime":"1800000000200","execType":"T"}}]}}
    , .{command.client_order_id.slice()});
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_reconciliation = .{ .identity = 101, .exchange_account = 2, .order = command.order_id, .venue_order = try canonical.VenueOrderRef.init(1, "1001") } }));
    try std.testing.expect(try applyDrain(owner, adapter));
    try std.testing.expect((try implementation.ingestPrivateWs(private_times, second)).rejection == null);
    try std.testing.expect(try applyDrain(owner, adapter));
    const reconciled_batch = (try adapter.tryDrain()) orelse return error.MissingOrderReconciliation;
    var saw_reconciliation = false;
    for (reconciled_batch.slice()) |record| {
        if (record.event != .order_reconciliation_result) continue;
        if (record.event.order_reconciliation_result.status != .found_terminal) return error.NotTerminalReconciliation;
        if (record.event.order_reconciliation_result.evidence == null) return error.MissingReconciliationEvidence;
        saw_reconciliation = true;
    }
    if (!saw_reconciliation) return error.MissingReconciliationResult;
    try owner.applyAdapterBatch(reconciled_batch);
    const reconciled_digest = owner.shard.canonicalStateDigest();
    const reconciled_owner = try allocator.create(demo.Owner);
    defer allocator.destroy(reconciled_owner);
    reconciled_owner.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &reconciled_digest, &reconciled_owner.shard.canonicalStateDigest());

    const full_sequence = owner.shard.trace.len + 1;
    const full_intent: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = full_sequence, .strategy_cursor = owner.shard.trace.len, .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = .buy, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 10_000, .limit_price_micros = 50_000_000_000 };
    const full_command = (try owner.apply(.{ .core = .{ .identity = full_sequence, .monotonic_time = 3, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = full_intent } } })) orelse return error.MissingDemoCommand;
    try implementation.rememberRecoveredOrder(full_command.order_id, full_command.client_order_id, full_command.portfolio_reduce_only, .{ .instrument = full_command.instrument, .rules_version = full_command.limit_price.rules_version, .lots = full_command.quantity }, full_command.revision);
    _ = try owner.apply(fixtureOnSecondaryStream(21, 5, .{ .order_dispatch_result = .{ .command = full_command.command_id, .state = .submitted } }));
    var full_frame: [1024]u8 = undefined;
    const full = try std.fmt.bufPrint(&full_frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1002","clOrdId":"{s}","side":"buy","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0001","px":"50000","accFillSz":"0.0001","avgPx":"50000","uTime":"1800000000300","tradeId":"3001","fillSz":"0.0001","fillPx":"50000","fillFee":"0.001","fillFeeCcy":"USDT","fillTime":"1800000000300","execType":"T"}}]}}
    , .{full_command.client_order_id.slice()});
    try std.testing.expect((try implementation.ingestPrivateWs(private_times, full)).rejection == null);
    try std.testing.expect(try applyDrain(owner, adapter));

    const account_before_refresh = owner.shard.canonical_account;
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 100, .exchange_account = 2, .expected_session = 1 } }));
    const pending_reconciliation = (try adapter.tryDrain()) orelse return error.MissingAccountReconciliationStart;
    try std.testing.expectEqual(@as(usize, 1), pending_reconciliation.slice().len);
    try std.testing.expect(pending_reconciliation.slice()[0].event == .account_reconciliation_started);
    try owner.applyAdapterBatch(pending_reconciliation);
    try std.testing.expect(owner.shard.accountReconciliationPending());
    try std.testing.expect(std.meta.eql(account_before_refresh, owner.shard.canonical_account));
    const pending_digest = owner.shard.canonicalStateDigest();
    const pending_recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(pending_recovered);
    pending_recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expect(pending_recovered.shard.accountReconciliationPending());
    try std.testing.expect(std.meta.eql(account_before_refresh, pending_recovered.shard.canonical_account));
    try std.testing.expectEqualSlices(u8, &pending_digest, &pending_recovered.shard.canonicalStateDigest());

    const before_duplicate = owner.shard.canonicalStateDigest();
    try std.testing.expect((try implementation.ingestPrivateWs(private_times, second)).rejection == null);
    try std.testing.expect(!try applyDrain(owner, adapter));
    // Different source bytes retain the same report/fill identity and content.
    var equivalent_bytes: [2048]u8 = undefined;
    const equivalent_count = std.mem.replace(u8, second, "0.0002", "+000.000200000000000000000000000000000000000000000000000", &equivalent_bytes);
    try std.testing.expectEqual(@as(usize, 2), equivalent_count);
    const equivalent_len = second.len + equivalent_count * ("+000.000200000000000000000000000000000000000000000000000".len - "0.0002".len);
    const equivalent = equivalent_bytes[0..equivalent_len];
    const equivalent_ingress = try implementation.ingestPrivateWs(private_times, equivalent);
    try std.testing.expect(equivalent_ingress.rejection == null);
    try std.testing.expect(!try applyDrain(owner, adapter));
    try std.testing.expectEqualSlices(u8, &before_duplicate, &owner.shard.canonicalStateDigest());
    var recovered_raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 2 });
    var recovered_chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = recovered_raw.interface(), .transport = transport.interface() };
    var recovered_clock = Clock{};
    var recovered_reconciler: private.Reconciler = .{};
    var recovered_implementation = okx.OkxVenueAdapter.init(allocator, &recovered_chain, recovered_clock.interface(), profile(), rules());
    recovered_implementation.attachPrivateReconciler(&recovered_reconciler);
    const recovered_adapter = recovered_implementation.adapter();
    try recovered_adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
    try recovered_implementation.beginPrivateSession();
    try recovered_implementation.rememberRecoveredOrder(command.order_id, command.client_order_id, command.portfolio_reduce_only, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
    try recovered_implementation.rememberRecoveredOrder(full_command.order_id, full_command.client_order_id, full_command.portfolio_reduce_only, .{ .instrument = full_command.instrument, .rules_version = full_command.limit_price.rules_version, .lots = full_command.quantity }, full_command.revision);
    try std.testing.expect((try replayCommittedOkx(&recovered_implementation, memory.interface(), raw_stream)) > 0);
    try std.testing.expect((try recovered_adapter.tryDrain()) == null);
    try std.testing.expectEqual(@as(u64, 1), recovered_raw.next_sequence);
    try std.testing.expectEqual(venue.SendResult.accepted, try recovered_adapter.trySend(.{ .account_reconciliation = .{ .identity = 100, .exchange_account = 2, .expected_session = 1 } }));
    const recovered_pending = (try recovered_adapter.tryDrain()) orelse return error.MissingRecoveredAccountReconciliationStart;
    try std.testing.expectEqual(@as(usize, 1), recovered_pending.slice().len);
    try std.testing.expect(recovered_pending.slice()[0].event == .account_reconciliation_started);
    var conflicting_frame: [1024]u8 = undefined;
    const conflicting = try std.fmt.bufPrint(&conflicting_frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0002","px":"50000","accFillSz":"0.0002","avgPx":"50000","uTime":"1800000000200","tradeId":"2002","fillSz":"0.0001","fillPx":"50001","fillFee":"-0.01","fillFeeCcy":"USDT","rebate":"0.001","rebateCcy":"USDT","fillTime":"1800000000200","execType":"T"}}]}}
    , .{command.client_order_id.slice()});
    const conflicting_ingress = try recovered_implementation.ingestPrivateWs(private_times, conflicting);
    try std.testing.expectEqual(private.RejectReason.conflicting_fact, conflicting_ingress.rejection.?);
    try std.testing.expectEqual(@as(u8, 0), conflicting_ingress.event_count);
    try std.testing.expectEqualSlices(u8, &before_duplicate, &owner.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(i64, 20_000), try owner.shard.economic_projection.appliedCanonicalFillQuantity(@intCast(command.order_id)));
    try std.testing.expectEqual(@as(i64, 10_000), try owner.shard.economic_projection.appliedCanonicalFillQuantity(@intCast(full_command.order_id)));
    try std.testing.expectEqual(@import("oms.zig").OrderState.filled, owner.shard.oms.orderById(command.order_id).?.state);
    try std.testing.expectEqual(@import("oms.zig").OrderState.filled, owner.shard.oms.orderById(full_command.order_id).?.state);
    try owner.shard.economic_projection.assertClosed();
    try std.testing.expectEqual(@as(i64, 30_000), owner.shard.economicSummary().portfolio.spot.quantity);
    try std.testing.expectEqual(@as(i128, 29_900), owner.shard.economicSummary().portfolio.spot_asset_atoms);
    try std.testing.expectEqual(@as(i128, 100), owner.shard.economicSummary().portfolio.base_fee_atoms);
    try std.testing.expectEqual(@as(i64, 10_000), owner.shard.economicSummary().portfolio.fee_atoms);
    try std.testing.expectEqual(@as(i64, 1_000), owner.shard.economicSummary().portfolio.rebate_atoms);

    const live_digest = owner.shard.canonicalStateDigest();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &live_digest, &(try recovered.source()).canonicalStateDigest());
    const Replay = struct {
        count: u64 = 0,
        saw_rest_route: bool = false,
        saw_original: bool = false,
        saw_equivalent: bool = false,

        fn consume(ptr: *anyopaque, _: u64, record: @import("okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
            self.saw_rest_route = self.saw_rest_route or record.origin != 0;
            self.saw_original = self.saw_original or std.mem.indexOf(u8, bytes, "\"accFillSz\":\"0.0002\"") != null;
            self.saw_equivalent = self.saw_equivalent or std.mem.indexOf(u8, bytes, "+000.000200000000000000000000000000000000000000000000000") != null;
        }
    };
    var replay = Replay{};
    try raw_ingress.replayCommitted(memory.interface(), undefined, raw_stream, .{ .ptr = &replay, .consume_fn = Replay.consume });
    try std.testing.expect(replay.count > 0 and replay.saw_rest_route);
    try std.testing.expect(replay.saw_original and replay.saw_equivalent);
    try std.testing.expectEqual(@as(u64, 0), chain.next_attempt_id - 1);
}

test "OKX raw private fills traverse adapter Owner durable recovery without decoder leakage" {
    const Context = struct {
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            executeRawPrivateFillRecovery() catch |err| {
                std.debug.print("venue fill recovery worker failed: {s}\n", .{@errorName(err)});
                self.failure = err;
            };
        }
    };
    var context = Context{};
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Context.run, .{&context});
    thread.join();
    if (context.failure) |err| {
        std.debug.panic("venue fill recovery failed: {s}", .{@errorName(err)});
    }
}

fn checkReadyEconomicFault(fee: ?[]const u8, asset: []const u8, expected: canonical.EconomicFaultReason, rejection: ?private.RejectReason, core_reject: bool, persist_fault: ?durable.FaultPoint, rest: bool) !void {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    var raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 1 });
    var transport = Transport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = Clock{};
    var reconciler: private.Reconciler = .{};
    var implementation = okx.OkxVenueAdapter.init(allocator, &chain, clock.interface(), profile(), rules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    try @import("venue_adapter_contract.zig").activateTestAssets(owner);
    try adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
    try implementation.beginPrivateSession();
    const subscriptions = [_][]const u8{
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
    for (subscriptions) |frame| try std.testing.expect((try implementation.ingestPrivateWs(private_times, frame)).rejection == null);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 1 } }));
    try std.testing.expect(try applyDrain(owner, adapter));
    try ingestBootstrapRound(&implementation);
    try std.testing.expect(!try applyDrain(owner, adapter));
    try ingestBootstrapRound(&implementation);
    try std.testing.expect(try applyDrain(owner, adapter));
    try std.testing.expect(owner.shard.canonical_account.valid);

    var parsed = try demo.Policy.parse(allocator,
        \\{"schema":3,"lot_size":{"coefficient":1,"scale":8},"price_tick_atoms":100000,"startup":"virgin","exchange_account":2,"portfolio_identity":1,"strategy_identity":40,"activation_identity":50,"config_version":1,"portfolio_allocation_atoms":20000000,"risk_limit_atoms":15000000,"decision_stream_id":91,"dispatch_stream_id":92,"decision_domain":1,"node_identity":1}
    );
    defer parsed.deinit();
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try parsed.value.initialize(owner, 50_000_000, &guard, 1, 1);
    _ = try owner.apply(fixtureOnSecondaryStream(18, 2, .{ .instrument_definition_observed = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1 } }));
    var book = snapshotOnSecondaryStream(19, 3);
    book.venue.event.l2_book_snapshot.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_bid.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_ask.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_bid_quantity.?.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_ask_quantity.?.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.next_ask.?.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.next_ask_quantity.?.instrument = okx.btc_usdt_spot;
    _ = try owner.apply(book);
    const sequence = owner.shard.trace.len + 1;
    const intent: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = sequence, .strategy_cursor = owner.shard.trace.len, .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = .buy, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 20_000, .limit_price_micros = 50_000_000 };
    const command = (try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = intent } } })) orelse return error.MissingDemoCommand;
    try implementation.rememberRecoveredOrder(command.order_id, command.client_order_id, command.portfolio_reduce_only, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
    const preserve_unknown = fee != null and !core_reject;
    _ = try owner.apply(fixtureOnSecondaryStream(20, 4, .{ .order_dispatch_result = .{ .command = command.command_id, .state = if (preserve_unknown) .unknown else .submitted } }));
    if (rest) {
        try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 100, .exchange_account = 2, .expected_session = 1 } }));
        try std.testing.expect(try applyDrain(owner, adapter));
    }
    const economic_before = owner.shard.economicSummary();
    const reservation_before = owner.shard.oms.orderById(command.order_id).?.reservation;
    const account_before = owner.shard.canonical_account.digest();
    var frame: [2048]u8 = undefined;
    const input = if (rest) try std.fmt.bufPrint(&frame,
        \\{{"code":"0","data":[{{"instId":"BTC-USDT","ordId":"1001","billId":"3001","clOrdId":"{s}","side":"buy","tradeId":"2001","fillSz":"0.0001","fillPx":"50000","fee":"{s}","feeCcy":"{s}","fillTime":"1800000000100","execType":"M"}}]}}
    , .{ command.client_order_id.slice(), fee.?, asset }) else if (fee) |amount| try std.fmt.bufPrint(&frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"partially_filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0002","px":"50000","accFillSz":"0.0001","avgPx":"50000","uTime":"1800000000100","tradeId":"2001","fillSz":"0.0001","fillPx":"50000","fillFee":"{s}","fillFeeCcy":"{s}","fee":"-0.01","feeCcy":"USDT","rebate":"{s}","rebateCcy":"USDT","fillTime":"1800000000100","execType":"M"}}]}}
    , .{ command.client_order_id.slice(), amount, asset, "0.02" }) else
        \\{"arg":{"channel":"account"},"eventType":"update","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000001","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"25.123456789","eq":"25.123456789","availBal":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    ;
    const account_input =
        \\{"arg":{"channel":"account"},"eventType":"update","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000001","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"25","eq":"25","availBal":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    ;
    const ingress = if (rest) try implementation.ingestPrivateRest(private_times, .rest_fills_history_spot, .{ .final = true }, input) else try implementation.ingestPrivateWs(private_times, if (core_reject and fee == null) account_input else input);
    try std.testing.expectEqual(rejection, ingress.rejection);
    var output = (try adapter.tryDrain()) orelse return error.MissingEconomicFault;
    if (persist_fault) |point| {
        memory.injectFaultAt(.eio, point);
        try std.testing.expectError(error.DecisionLogUnavailable, owner.applyAdapterBatch(output));
        try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
        try std.testing.expectEqualDeep(economic_before, owner.shard.economicSummary());
        try std.testing.expectError(error.DecisionLogUnavailable, demo.Owner.recover(memory.interface(), undefined, stream));
        const pending_raw = try memory.interface().recover(undefined, .{ .domain = .raw_ingress, .id = 1 });
        try std.testing.expectEqual(ingress.raw_evidence.stream_sequence, pending_raw.committed_barrier);
        try std.testing.expectEqual(pending_raw.last_sequence, pending_raw.committed_barrier);
        try std.testing.expectEqual(venue.SendResult.backpressure, try adapter.trySend(.{ .order_command = .{
            .identity = 999,
            .instrument = okx.btc_usdt_spot,
            .exchange_account = 2,
            .client_order_id = command.client_order_id,
            .operation = .place,
            .side = .buy,
            .order_type = .limit,
            .time_in_force = .good_til_canceled,
            .quantity = .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity },
            .limit_price = command.limit_price,
            .adapter_session = 1,
            .rules_version = 1,
            .capability_version = 1,
            .config_version = 1,
            .dispatch_deadline_monotonic_ns = 100,
        } }));
        try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
        return;
    }
    var fault: ?canonical.EventRecord = null;
    for (output.slice()) |record| if (record.event == .economic_fault) {
        fault = record;
    };
    if (core_reject) {
        if (fee == null) {
            try std.testing.expect(output.events[0].event == .account_observed);
            const digest_before = owner.shard.canonicalStateDigest();
            var foreign = output.events[0];
            foreign.envelope.exchange_account = 3;
            foreign.event.account_observed.exchange_account = 3;
            try std.testing.expectError(error.CanonicalScopeMismatch, owner.shard.apply(.{ .venue = foreign }));
            try std.testing.expectEqualSlices(u8, &digest_before, &owner.shard.canonicalStateDigest());
            output.events[0].event.account_observed.source_sequence += 5;
            try std.testing.expectError(error.SourceSequenceGap, owner.applyAdapterBatch(output));
        } else {
            try std.testing.expect(output.events[1].event == .fill);
            try std.testing.expect(output.events[1].event.fill.rebate == null);
            output.events[1].event.fill.fee.?.atoms = std.math.maxInt(i128);
            try std.testing.expectError(error.AssetAmountOutOfRange, owner.applyAdapterBatch(output));
        }
        try std.testing.expectEqual(expected, owner.shard.economic_fault_reason);
        try std.testing.expect(!owner.closed);
        for (owner.shard.oms.emitted()) |cancel| try std.testing.expect(cancel.authority.complete());
    } else {
        const rejected_fact = fault orelse return error.MissingEconomicFault;
        try std.testing.expectEqual(expected, rejected_fact.event.economic_fault.reason);
        try std.testing.expectEqual(ingress.raw_evidence.stream_sequence, rejected_fact.envelope.raw_evidence.sequence);
        try owner.applyAdapterBatch(output);
    }
    try std.testing.expect(owner.shard.oms.recovery_only);
    const unresolved_order = owner.shard.oms.orderById(command.order_id).?;
    try std.testing.expect(!owner.shard.integritySnapshot().account_valid);
    try std.testing.expectError(error.ExchangeOpeningGateClosed, owner.shard.currentNativeRiskCash(command.instrument));
    if (!core_reject) try std.testing.expectEqualSlices(u8, &account_before, &owner.shard.canonical_account.digest());
    try std.testing.expect(unresolved_order.reservation_active);
    if (preserve_unknown) {
        try std.testing.expectEqualDeep(reservation_before, unresolved_order.reservation);
        try std.testing.expect(owner.shard.oms.blocksNewSend());
        try std.testing.expect(!owner.shard.oms.openOrdersClosed());
    }
    try std.testing.expect(!owner.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectEqualDeep(economic_before, owner.shard.economicSummary());
    try std.testing.expectEqual(@as(i64, 0), try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expect(recovered.shard.oms.recovery_only);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    var snapshot_buffer: [durable.max_snapshot_bytes]u8 = undefined;
    const snapshot = try owner.committedSnapshot(&snapshot_buffer);
    const restored = try @import("trading_shard.zig").TradingShard.restoreSnapshot(snapshot);
    try std.testing.expect(!recovered.shard.integritySnapshot().account_valid);
    try std.testing.expect(!restored.shard.integritySnapshot().account_valid);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
    if (preserve_unknown) {
        try implementation.beginPrivateSession();
        try std.testing.expectEqual(venue.SendResult.backpressure, try adapter.trySend(.{ .order_command = .{
            .identity = 999,
            .instrument = command.instrument,
            .exchange_account = 2,
            .client_order_id = command.client_order_id,
            .operation = .place,
            .side = .buy,
            .order_type = .limit,
            .time_in_force = .good_til_canceled,
            .portfolio_reduce_only = true,
            .quantity = .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity },
            .limit_price = command.limit_price,
            .adapter_session = 1,
            .rules_version = 1,
            .capability_version = 1,
            .config_version = 1,
            .dispatch_deadline_monotonic_ns = 100,
        } }));
        try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
        try std.testing.expect(recovered.shard.oms.recovery_only);
    }
    if (fee == null and !core_reject) {
        var gateway: @import("execution_gateway.zig").Gateway = .{};
        try gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .environment = .demo, .lease_guard = &guard, .capability = .{
            .version = 1,
            .rules_version = 1,
            .config_version = 1,
            .session = 1,
            .supports_post_only = true,
            .supports_market_protection = true,
        } });
        try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
        const pending = owner.shard.oms.orderById(command.order_id).?;
        try std.testing.expect(pending.reservation_active);
        var cancellation: ?@import("oms.zig").Command = null;
        for (owner.shard.oms.command_history[0..owner.shard.oms.command_history_count]) |known| if (known.operation == .cancel) {
            cancellation = known;
        };
        const cancel = cancellation orelse return error.MissingSafetyCancellation;
        try gateway.observeAuthority(.{
            .account = 2,
            .effective_trading_authority = false,
            .reservation_identity = cancel.reservation_identity,
            .reservation = cancel.reservation,
            .primary_lease_expires_at_monotonic_ns = lease.expires_at_ns,
            .fencing_token = lease.token,
            .exchange_position = owner.shard.currentNetExchangePosition(cancel.instrument).?,
            .authority_barrier = owner.shard.trace.len,
        });
        try std.testing.expectError(error.NotSent, gateway.sendFromShard(&recovered.shard, command.command_id, 2));
        const cancellation_snapshot = try recovered.committedSnapshot(&snapshot_buffer);
        try std.testing.expectEqual(venue.SendResult.accepted, try demo.sendFromCommittedSnapshot(cancellation_snapshot, recovered.shard.trace.len, recovered.shard.canonicalStateDigest(), &gateway, &guard, cancel.command_id, 2));
        try std.testing.expectEqual(@as(u64, 2), chain.next_attempt_id);
    }
}

test "OKX ready inexact account fact persists a fail closed result without reconciliation" {
    try checkReadyEconomicFault(null, "USDT", .inexact_amount, null, false, null, false);
}

test "OKX activated high precision account facts survive Owner replay without old unit economics" {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    for (@import("asset_registry.zig").testDefinitions(12, 9)) |definition|
        _ = try owner.apply(.{ .core = .{ .identity = definition.asset, .payload = .{ .asset_definition_activated = definition } } });
    const economics_before = owner.shard.economicSummary();
    var raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 1 });
    var transport = Transport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = Clock{};
    var reconciler: private.Reconciler = .{};
    var implementation = okx.OkxVenueAdapter.init(allocator, &chain, clock.interface(), profile(), rules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
    try implementation.beginPrivateSession();
    const frames = [_][]const u8{
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
    for (frames) |frame| try std.testing.expect((try implementation.ingestPrivateWs(private_times, frame)).rejection == null);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 1 } }));
    try std.testing.expect(try applyDrain(owner, adapter));
    try ingestBootstrapRound(&implementation);
    try std.testing.expect(!try applyDrain(owner, adapter));
    try ingestBootstrapRound(&implementation);
    try std.testing.expect(try applyDrain(owner, adapter));
    const observation =
        \\{"arg":{"channel":"account"},"eventType":"update","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000001","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"25.000000000001","availBal":"25.000000000001","eq":"25.000000000001","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"},{"ccy":"BTC","cashBal":"0.000000001","availBal":"0.000000001","eq":"0.000000001","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    ;
    try std.testing.expect((try implementation.ingestPrivateWs(private_times, observation)).rejection == null);
    try std.testing.expect(try applyDrain(owner, adapter));
    try std.testing.expectEqual(@as(u8, 2), owner.shard.canonical_account.balance_count);
    for (owner.shard.canonical_account.balances[0..2]) |balance| {
        const expected: i128 = switch (balance.asset) {
            okx.usdt => 25_000_000_000_001,
            okx.btc => 1,
            else => return error.UnexpectedAsset,
        };
        try std.testing.expectEqual(expected, balance.total.atoms);
        try std.testing.expectEqual(expected, balance.available.atoms);
    }
    try std.testing.expectEqualDeep(economics_before, owner.shard.economicSummary());
    try std.testing.expect(!owner.shard.settlementConsumersCompatible(okx.btc_usdt_spot));
    try std.testing.expect(!owner.shard.genesisReady());
    try std.testing.expectEqual(@as(u64, 0), owner.shard.economic_fault_count);
    try owner.sealBootstrap();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try std.testing.expectEqualDeep(owner.shard.activatedAssets(), recovered.shard.activatedAssets());
    var bytes: [durable.max_snapshot_bytes]u8 = undefined;
    const restored = try @import("trading_shard.zig").TradingShard.restoreSnapshot(try owner.committedSnapshot(&bytes));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
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

fn checkNativeSettlementFees(case: enum { long, tiny, wide, overflow, conflict, inexact, malformed }) !void {
    const malformed = case == .malformed;
    const inexact = case == .inexact;
    const tiny = case == .tiny;
    const wide = case == .wide;
    const overflow = case == .overflow;
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    var definitions = @import("asset_registry.zig").testDefinitions(if (inexact) 6 else if (wide) 18 else 12, 8);
    if (wide) {
        definitions[0].max_single_atoms = 100_000_000_000_000_000_000;
        definitions[0].max_balance_atoms = 100_000_000_000_000_000_000;
        definitions[0].max_cumulative_atoms = 100_000_000_000_000_000_000;
    }
    if (overflow) {
        definitions[0].max_single_atoms = 100_000_000_000_000;
        definitions[0].max_balance_atoms = 100_000_000_000_000;
        definitions[0].max_cumulative_atoms = 100_000_000_000_000;
    }
    const policy: demo.Policy = .{
        .schema = 3,
        .lot_size = .{ .coefficient = 1, .scale = 8 },
        .startup = .virgin,
        .asset_definitions = &definitions,
        .exchange_account = 2,
        .portfolio_identity = 1,
        .strategy_identity = 40,
        .activation_identity = 50,
        .config_version = 1,
        .portfolio_allocation_atoms = if (inexact) 90_000_000 else if (wide) 90_000_000_000_000_000_000 else 90_000_000_000_000,
        .risk_limit_atoms = if (inexact) 80_000_000 else if (wide) 80_000_000_000_000_000_000 else 80_000_000_000_000,
        .price_tick_atoms = if (inexact) 100_000 else if (wide) 100_000_000_000_000_000 else 100_000_000_000,
        .native_settlement_atoms = true,
        .decision_stream_id = 91,
        .dispatch_stream_id = 92,
        .decision_domain = 1,
        .node_identity = 1,
    };
    try policy.activateAssetsForOfflineValidation(owner);
    var raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 1 });
    var transport = Transport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = Clock{};
    var reconciler: private.Reconciler = .{};
    var implementation = okx.OkxVenueAdapter.init(allocator, &chain, clock.interface(), profile(), rules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry, .native_settlement_atoms = true });
    try bootstrapNativePrivateAccount(owner, &implementation, "100");
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try policy.initialize(owner, if (inexact) 50_000_000_000 else if (wide) 50_000_000_000_000_000_000_000 else 50_000_000_000_000_000, &guard, 1, 1);
    try std.testing.expect(owner.shard.settlementConsumersCompatible(okx.btc_usdt_spot));
    try std.testing.expect(!owner.shard.oms.recovery_only);
    _ = try owner.apply(fixtureOnSecondaryStream(18, 2, .{ .instrument_definition_observed = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1 } }));
    _ = try owner.apply(fixtureOnSecondaryStream(19, 3, .{ .l2_book_snapshot = .{
        .instrument = okx.btc_usdt_spot,
        .sequence = 3,
        .best_bid = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 499_999 },
        .best_ask = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 500_000 },
        .best_bid_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 1_000_000 },
        .best_ask_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 1_000_000 },
    } }));
    const count: usize = if (inexact or malformed) 1 else if (overflow) 2 else if (tiny) 10 else 4;
    const sequence = owner.shard.trace.len + 1;
    const intent: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = sequence, .strategy_cursor = owner.shard.trace.len, .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = .buy, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = if (malformed) 40_000 else if (inexact) 1 else @intCast(count * 10_000), .limit_price_micros = 50_000_000_000 };
    const command = (try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = intent } } })) orelse return error.MissingDemoCommand;
    try implementation.rememberRecoveredOrder(command.order_id, command.client_order_id, false, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
    _ = try owner.apply(fixtureOnSecondaryStream(20, 4, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .submitted } }));
    const long_fees = [_][]const u8{ "-0.004198632165", "-0.00423723852", "0.0000001", "0" };
    const fee_atoms: [4]i128 = if (wide) .{ 4_198_632_165_000_000, 4_237_238_520_000_000, 0, 0 } else .{ 4_198_632_165, 4_237_238_520, 0, 0 };
    var frame: [1536]u8 = undefined;
    for (0..count) |index| {
        var cumulative: [16]u8 = undefined;
        const cumulative_text = if (inexact) "0.00000001" else if (index == 9) "0.001" else try std.fmt.bufPrint(&cumulative, "0.000{d}", .{index + 1});
        const input = try std.fmt.bufPrint(&frame,
            \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"{s}","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"{s}","px":"50000","accFillSz":"{s}","avgPx":"{s}","uTime":"{d}","tradeId":"{d}","fillSz":"{s}","fillPx":"{s}","fillFee":"{s}","fillFeeCcy":"USDT","fillTime":"{d}","execType":"T"}}]}}
        , .{ command.client_order_id.slice(), if (!malformed and index + 1 == count) "filled" else "partially_filled", if (inexact) "0.00000001" else if (overflow) "0.0002" else if (tiny) "0.001" else "0.0004", cumulative_text, if (inexact) "0.1" else "50000", @as(u64, 1_800_000_000_100) + index, 2001 + index, if (inexact) "0.00000001" else "0.0001", if (inexact) "0.1" else "50000", if (inexact) "0" else if (overflow) "-60" else if (tiny) "-0.0000001" else long_fees[index], @as(u64, 1_800_000_000_100) + index });
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, input)).rejection == null);
        const output = (try adapter.tryDrain()) orelse return error.MissingPrivateBatch;
        for (output.slice()) |record| if (record.event == .fill) {
            try std.testing.expectEqual(if (inexact) @as(i128, 0) else if (overflow) @as(i128, 60_000_000_000_000) else if (tiny) @as(i128, if (wide) 100_000_000_000 else 100_000) else fee_atoms[index], record.event.fill.fee.?.atoms);
            try std.testing.expectEqual(@as(i128, if (inexact) 1 else 10_000), record.event.fill.quantity.lots);
            if (!tiny and !overflow and !inexact and index == 2)
                try std.testing.expectEqual(@as(i128, if (wide) 100_000_000_000 else 100_000), record.event.fill.rebate.?.atoms);
        };
        if (inexact or (overflow and index == 1)) {
            const before = owner.shard.economicSummary();
            try std.testing.expectError(if (inexact) error.InexactEconomicAmount else error.AssetAmountOutOfRange, owner.applyAdapterBatch(output));
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
            try std.testing.expectEqual(@as(u64, 1), owner.shard.economic_fault_count);
            try std.testing.expect(owner.shard.oms.recovery_only);
            continue;
        }
        try owner.applyAdapterBatch(output);
        const digest = owner.shard.canonicalStateDigest();
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, input)).rejection == null);
        while (try adapter.tryDrain()) |duplicate| try owner.applyAdapterBatch(duplicate);
        try std.testing.expectEqualSlices(u8, &digest, &owner.shard.canonicalStateDigest());
    }
    const economic = owner.shard.economicSummary();
    try std.testing.expectEqual(if (malformed) @as(i128, 4_198_632_165) else if (inexact) @as(i128, 0) else if (overflow) @as(i128, 60_000_000_000_000) else if (wide) @as(i128, if (tiny) 1_000_000_000_000 else 8_435_870_685_000_000) else if (tiny) @as(i128, 1_000_000) else 8_435_870_685, economic.portfolio.fee_atoms);
    try std.testing.expectEqual(if (malformed or inexact or overflow or tiny) @as(i128, 0) else if (wide) @as(i128, 100_000_000_000) else 100_000, economic.portfolio.rebate_atoms);
    try std.testing.expectEqual(if (malformed) @as(i128, 84_995_801_367_835) else if (inexact) @as(i128, 90_000_000) else if (overflow) @as(i128, 25_000_000_000_000) else if (wide) @as(i128, if (tiny) 39_999_999_000_000_000_000 else 69_991_564_229_315_000_000) else if (tiny) @as(i128, 39_999_999_000_000) else 69_991_564_229_315, economic.portfolio.usdt_balance_atoms);
    try std.testing.expectEqual(if (malformed) @as(i128, 94_995_801_367_835) else if (inexact) @as(i128, 100_000_000) else if (overflow) @as(i128, 35_000_000_000_000) else if (wide) @as(i128, if (tiny) 49_999_999_000_000_000_000 else 79_991_564_229_315_000_000) else if (tiny) @as(i128, 49_999_999_000_000) else 79_991_564_229_315, economic.exchange.usdt_balance_atoms);
    try std.testing.expectEqual(@as(i64, if (inexact) 1 else @intCast(count * 10_000)), owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
    try std.testing.expectEqual(@as(i64, if (inexact) 0 else if (overflow) 10_000 else @intCast(count * 10_000)), try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    for ([_]@import("economics.zig").LedgerLayer{ .portfolio, .exchange }) |layer| {
        var posted_fees: i128 = 0;
        var posted_rebates: i128 = 0;
        const projection = &owner.shard.economic_projection;
        for (projection.ledger[0..projection.ledger_count]) |transaction| {
            if (transaction.layer != layer) continue;
            for (transaction.postings[0..transaction.posting_count]) |posting| {
                if (posting.account != .fee_expense and posting.account != .rebate_income) continue;
                try std.testing.expectEqual(@import("economics.zig").LedgerUnit.settlement_atoms, posting.unit);
                try std.testing.expectEqual(@as(u8, 2), transaction.posting_count);
                if (posting.account == .fee_expense) posted_fees = try std.math.add(i128, posted_fees, posting.amount) else posted_rebates = try std.math.sub(i128, posted_rebates, posting.amount);
            }
        }
        try std.testing.expectEqual(economic.portfolio.fee_atoms, posted_fees);
        try std.testing.expectEqual(economic.portfolio.rebate_atoms, posted_rebates);
    }
    if (case == .conflict) {
        const before = owner.shard.economicSummary();
        const conflicting = try std.fmt.bufPrint(&frame,
            \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0004","px":"50000","accFillSz":"0.0004","avgPx":"50000","uTime":"1800000000103","tradeId":"2004","fillSz":"0.0001","fillPx":"50000","fillFee":"0.0000001","fillFeeCcy":"USDT","fillTime":"1800000000103","execType":"T"}}]}}
        , .{command.client_order_id.slice()});
        const rejected = try implementation.ingestPrivateWs(private_times, conflicting);
        try std.testing.expectEqual(private.RejectReason.conflicting_fact, rejected.rejection.?);
        try std.testing.expect(try applyDrain(owner, adapter));
        try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
        try std.testing.expectEqual(@as(u64, 1), owner.shard.economic_fault_count);
        try std.testing.expect(owner.shard.oms.recovery_only);
    }
    if (malformed) {
        const before = owner.shard.economicSummary();
        const input = try std.fmt.bufPrint(&frame,
            \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0004","px":"50000","accFillSz":"0.0001","avgPx":"50000","uTime":"1800000000104","tradeId":"","fillSz":"0","fillPx":"","fillFee":"","fillFeeCcy":"","fillTime":"","execType":""}}]}}
        , .{command.client_order_id.slice()});
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, input)).rejection == null);
        const output = (try adapter.tryDrain()) orelse return error.MissingPrivateBatch;
        try std.testing.expectError(error.InvalidExecutionReport, owner.applyAdapterBatch(output));
        try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
        try std.testing.expect(owner.shard.oms.recovery_only);
        try std.testing.expect(!owner.closed);
        try std.testing.expectEqual(@as(i64, 10_000), owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
        const fault_digest = owner.shard.canonicalStateDigest();
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, input)).rejection == null);
        while (try adapter.tryDrain()) |duplicate| try owner.applyAdapterBatch(duplicate);
        try std.testing.expectEqualSlices(u8, &fault_digest, &owner.shard.canonicalStateDigest());
    }
    try owner.shard.assertClosures();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    var bytes: [durable.max_snapshot_bytes]u8 = undefined;
    const restored = try @import("trading_shard.zig").TradingShard.restoreSnapshot(try owner.committedSnapshot(&bytes));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
}

test "OKX native settlement long fees rebates and explicit zero close Owner ledger and recover" {
    try checkNativeSettlementFees(.long);
}

test "OKX native settlement ten micro fees accumulate exactly through Owner and replay" {
    try checkNativeSettlementFees(.tiny);
}

test "OKX native settlement balances beyond i64 close Owner ledger and replay" {
    try checkNativeSettlementFees(.wide);
}

test "OKX native settlement cumulative fee overflow preserves reports and rejects partial ledger commit" {
    try checkNativeSettlementFees(.overflow);
}

test "OKX native settlement fee identity conflict retains exact ledger and recovery fault" {
    try checkNativeSettlementFees(.conflict);
}

test "OKX native settlement actual subatom notional faults instead of applying risk rounding" {
    try checkNativeSettlementFees(.inexact);
}

test "OKX native settlement malformed terminal report closes Owner authority without changing ledger" {
    try checkNativeSettlementFees(.malformed);
}

fn checkNativeBaseFees(nonunit: bool, mode: enum { normal, legacy_precision, conflict, overflow, missing_authority, mismatched_profile, wide, cumulative, missing_cash, unavailable_cash, usd_precision, native_liabilities }) !void {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    const wide = mode == .wide;
    const cumulative = mode == .cumulative;
    var definitions = @import("asset_registry.zig").testDefinitions(if (wide) 14 else 12, if (wide) 18 else if (mode == .legacy_precision) 8 else 9);
    if (wide) {
        definitions[0].max_single_atoms = 1_000_000_000_000_000_000_000;
        definitions[0].max_balance_atoms = 1_000_000_000_000_000_000_000;
        definitions[0].max_cumulative_atoms = 1_000_000_000_000_000_000_000;
        definitions[1].max_single_atoms = 100_000_000_000_000_000_000;
        definitions[1].max_balance_atoms = 100_000_000_000_000_000_000;
        definitions[1].max_cumulative_atoms = 100_000_000_000_000_000_000;
    } else if (cumulative) {
        definitions[1].max_single_atoms = 200;
        definitions[1].max_balance_atoms = 200;
        definitions[1].max_cumulative_atoms = 200;
    }
    const policy: demo.Policy = .{
        .schema = 3,
        .startup = .virgin,
        .asset_definitions = &definitions,
        .lot_size = if (wide) .{ .coefficient = 20, .scale = 0 } else if (nonunit) .{ .coefficient = 25, .scale = 8 } else .{ .coefficient = 1, .scale = 7 },
        .exchange_account = 2,
        .portfolio_identity = 1,
        .strategy_identity = 40,
        .activation_identity = 50,
        .config_version = 1,
        .portfolio_allocation_atoms = if (wide) 180_000_000_000_000_000_000 else 90_000_000_000_000,
        .risk_limit_atoms = if (wide) 160_000_000_000_000_000_000 else 80_000_000_000_000,
        .price_tick_atoms = if (wide) 25_000_000_000_000 else 250_000_000_000,
        .native_settlement_atoms = true,
        .decision_stream_id = 91,
        .dispatch_stream_id = 92,
        .decision_domain = 1,
        .node_identity = 1,
    };
    try policy.activateAssetsForOfflineValidation(owner);
    var raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 1 });
    var transport = Transport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = Clock{};
    var reconciler: private.Reconciler = .{};
    var lot_rules = rules();
    lot_rules.spot.lot_size = policy.lot_size;
    lot_rules.spot.tick_size = .{ .coefficient = 25, .scale = 2 };
    if (mode == .mismatched_profile) lot_rules.spot.lot_size = .{ .coefficient = 1, .scale = 8 };
    var implementation = okx.OkxVenueAdapter.init(allocator, &chain, clock.interface(), profile(), lot_rules);
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    const config: venue.VenueConfig = .{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = if (mode == .missing_authority) .{} else owner.shard.instrument_registry, .native_settlement_atoms = true };
    if (mode == .missing_authority or mode == .mismatched_profile) {
        const digest = owner.shard.canonicalStateDigest();
        try std.testing.expectError(error.InvalidConfig, adapter.start(config));
        try std.testing.expectEqualSlices(u8, &digest, &owner.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u64, 1), raw.next_sequence);
        try std.testing.expectEqual(@as(u8, 0), owner.shard.economic_projection.ledger_count);
        try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
        return;
    }
    try adapter.start(config);
    try bootstrapNativePrivateAccount(owner, &implementation, if (wide) "2000000" else "100");
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try policy.initialize(owner, if (wide) 5_000_000_000_000_000_000 else 50_000_000_000_000_000, &guard, 1, 1);
    try std.testing.expect(owner.shard.settlementConsumersCompatible(okx.btc_usdt_spot));
    try std.testing.expect(!owner.shard.oms.recovery_only);
    _ = try owner.apply(fixtureOnSecondaryStream(18, 2, .{ .instrument_definition_observed = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1 } }));
    _ = try owner.apply(fixtureOnSecondaryStream(19, 3, .{ .l2_book_snapshot = .{
        .instrument = okx.btc_usdt_spot,
        .sequence = 3,
        .best_bid = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 199_999 },
        .best_ask = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 200_000 },
        .best_bid_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 1_000_000 },
        .best_ask_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 1_000_000 },
    } }));
    const account_case = mode == .missing_cash or mode == .unavailable_cash or mode == .usd_precision or mode == .native_liabilities;
    var pending_command: ?@import("oms.zig").Command = null;
    var dispatch_gateways: [2]@import("execution_gateway.zig").Gateway = @splat(.{});
    if (mode == .missing_cash) {
        const sequence = owner.shard.trace.len + 1;
        const accepted: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = sequence, .strategy_cursor = owner.shard.trace.len, .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = .buy, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 1, .limit_price_micros = 50_000_000_000 };
        pending_command = (try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = accepted } } })) orelse return error.MissingDemoCommand;
        for (&dispatch_gateways, 0..) |*gateway, index| {
            try gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .environment = .demo, .lease_guard = &guard, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1, .supports_post_only = true, .supports_market_protection = true } });
            try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 93 + index });
            try gateway.observeAuthority(.{ .account = 2, .effective_trading_authority = true, .reservation_identity = pending_command.?.reservation_identity, .reservation = pending_command.?.reservation, .primary_lease_expires_at_monotonic_ns = lease.expires_at_ns, .fencing_token = lease.token, .exchange_position = owner.shard.currentNetExchangePosition(okx.btc_usdt_spot).?, .authority_barrier = owner.shard.trace.len });
        }
        try std.testing.expectEqual(venue.SendResult.accepted, try dispatch_gateways[0].sendFromShard(&owner.shard, pending_command.?.command_id, 2));
        try std.testing.expectEqual(@as(u64, 1), dispatch_gateways[0].send_attempt_count);
        // The control probe proves this command dispatchable; keep the Owner's
        // accepted outbox unchanged for the independent degraded-source probe.
        while (try adapter.tryDrain()) |_| {}
    }
    if (account_case) {
        const before = owner.shard.economicSummary();
        var observed_frame: [2048]u8 = undefined;
        const observed = if (mode == .native_liabilities)
            \\{"arg":{"channel":"account"},"eventType":"update","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000002","totalEq":"100","adjEq":"100","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"100","availBal":"90.000000000001","eq":"99.999999999999","frozenBal":"9.999999999998","liab":"0.000000000001","isoLiab":"0.000000000003","crossLiab":"0.000000000002"},{"ccy":"BTC","cashBal":"0.000000504","availBal":"0.0000004","eq":"0.000000501","frozenBal":"0.000000101","liab":"0.000000001","isoLiab":"0.000000003","crossLiab":"0.000000002"}]}]}
        else
            try std.fmt.bufPrint(&observed_frame,
                \\{{"arg":{{"channel":"account"}},"eventType":"update","curPage":1,"lastPage":true,"data":[{{"uTime":"1800000000002","totalEq":"{s}","adjEq":"100","imr":"{s}","mmr":"{s}","mgnRatio":"","isoEq":"0","details":[{{"ccy":"USDT","availBal":"{s}","eq":"100","frozenBal":"{s}","liab":"0","isoLiab":"0","crossLiab":"0"{s}}}]}}]}}
            , .{ if (mode == .usd_precision) "100.123456789012345678" else "100", if (mode == .usd_precision) "0.000000000000000001" else "0", if (mode == .usd_precision) "0.000000000000000002" else "0", if (mode == .unavailable_cash) "0" else "100", if (mode == .unavailable_cash) "100" else "0", if (mode == .missing_cash) "" else ",\"cashBal\":\"100\"" });
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, observed)).rejection == null);
        try std.testing.expect(try applyDrain(owner, adapter));
        try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
        try std.testing.expect(owner.shard.canonical_account.valid);
        if (mode == .native_liabilities) {
            try std.testing.expectEqual(@as(u8, 2), owner.shard.canonical_account.balance_count);
            for (owner.shard.canonical_account.balances[0..2]) |balance| {
                try std.testing.expectEqual(@as(i128, 1), balance.liability.?.atoms);
                try std.testing.expectEqual(@as(i128, 3), balance.isolated_liability.?.atoms);
                try std.testing.expectEqual(@as(i128, 2), balance.cross_liability.?.atoms);
                if (balance.asset == okx.usdt) {
                    try std.testing.expectEqual(@as(i128, 99_999_999_999_999), balance.total.atoms);
                    try std.testing.expectEqual(@as(i128, 100_000_000_000_000), balance.cash_balance.?.atoms);
                    try std.testing.expectEqual(@as(i128, 90_000_000_000_001), balance.available.atoms);
                    try std.testing.expectEqual(@as(i128, 9_999_999_999_998), balance.held.atoms);
                } else if (balance.asset == okx.btc) {
                    try std.testing.expectEqual(@as(i128, 501), balance.total.atoms);
                    try std.testing.expectEqual(@as(i128, 504), balance.cash_balance.?.atoms);
                    try std.testing.expectEqual(@as(i128, 400), balance.available.atoms);
                    try std.testing.expectEqual(@as(i128, 101), balance.held.atoms);
                } else return error.UnexpectedNativeAsset;
            }
        }
        const margin = owner.shard.canonical_account.margins[0];
        try std.testing.expect(margin.amount == null);
        const usd = margin.usd_valuation orelse return error.MissingUsdSourceValuation;
        if (mode == .usd_precision) {
            try std.testing.expectEqual(@as(i128, 100_123_456_789_012_345_678), usd.total_equity.?.coefficient);
            try std.testing.expectEqual(@as(u8, 18), usd.total_equity.?.scale);
            try std.testing.expectEqual(@as(i128, 1), usd.initial_margin.?.coefficient);
            try std.testing.expectEqual(@as(u8, 18), usd.initial_margin.?.scale);
            try std.testing.expectEqual(@as(i128, 2), usd.maintenance_margin.?.coefficient);
        }
        const sequence = owner.shard.trace.len + 1;
        const attempted: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = sequence, .strategy_cursor = owner.shard.trace.len, .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = .buy, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 1, .limit_price_micros = 50_000_000_000 };
        try std.testing.expect((try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = attempted } } })) == null);
        try std.testing.expectEqual(if (pending_command != null) @import("trading_shard_event.zig").RejectReason.open_order else .exchange_opening_gate_closed, owner.shard.last_reject_reason);
        try std.testing.expectEqual(@as(u8, if (pending_command != null) 1 else 0), owner.shard.oms.order_count);
        if (pending_command) |pending| {
            const attempts = chain.next_attempt_id;
            try std.testing.expectError(error.NotSent, dispatch_gateways[1].sendFromShard(&owner.shard, pending.command_id, 2));
            try std.testing.expectEqual(@as(u64, 0), dispatch_gateways[1].send_attempt_count);
            try std.testing.expectEqual(attempts, chain.next_attempt_id);
        }
        try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
    }
    const fault = mode == .legacy_precision or mode == .overflow;
    const count: usize = if (account_case) 0 else if (fault or wide) 1 else 3;
    const quantity_text = if (wide) "20" else if (nonunit) "0.00000025" else "0.0000001";
    var frame: [2048]u8 = undefined;
    var last_command: @import("oms.zig").Command = undefined;
    for (0..count) |index| {
        if (index == 1) {
            const before = owner.shard.economicSummary();
            const sequence = owner.shard.trace.len + 1;
            const oversized: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = sequence, .strategy_cursor = owner.shard.trace.len, .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = .sell, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 1, .limit_price_micros = 50_000_000_000 };
            try std.testing.expect((try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = oversized } } })) == null);
            try std.testing.expectEqual(@import("trading_shard_event.zig").RejectReason.insufficient_spot_asset, owner.shard.last_reject_reason);
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
        }
        if (index == 2) {
            const before = owner.shard.economicSummary();
            const order_count = owner.shard.oms.order_count;
            const command_count = owner.shard.oms.command_history_count;
            const sequence = owner.shard.trace.len + 1;
            var group: @import("oms.zig").IntentGroup = .{ .first_intent_sequence = sequence, .count = 2 };
            for (0..2) |member| group.members[member] = .{ .intent_sequence = sequence + member, .operation = .place, .instrument = okx.btc_usdt_spot, .side = .sell, .quantity = 2, .limit_price = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 200_000 } };
            try std.testing.expect((try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .oms_intent_group = group } } })) == null);
            try std.testing.expectEqual(@import("trading_shard_event.zig").RejectReason.insufficient_spot_asset, owner.shard.last_reject_reason);
            try std.testing.expectEqual(order_count, owner.shard.oms.order_count);
            try std.testing.expectEqual(command_count, owner.shard.oms.command_history_count);
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
        }
        const sequence = owner.shard.trace.len + 1;
        const intent: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = sequence, .strategy_cursor = owner.shard.trace.len, .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = if (index == 2) .sell else .buy, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 1, .limit_price_micros = 50_000_000_000 };
        const command = (try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = intent } } })) orelse return error.MissingDemoCommand;
        last_command = command;
        try std.testing.expectEqual(@as(i64, 1), command.quantity);
        try std.testing.expectEqual(@as(i128, 200_000), command.limit_price.ticks);
        if (index != 2) try std.testing.expectEqual(@as(i128, if (wide) 100_075_000_000_000_000_000 else if (nonunit) 12_509_375_000 else 5_003_750_000), command.reservation.atoms);
        try implementation.rememberRecoveredOrder(command.order_id, command.client_order_id, false, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
        _ = try owner.apply(fixtureOnSecondaryStream(20 + index, 4 + index, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .submitted } }));
        const input = try std.fmt.bufPrint(&frame,
            \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"{d}","clOrdId":"{s}","side":"{s}","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"{s}","px":"50000","accFillSz":"{s}","avgPx":"50000","uTime":"{d}","tradeId":"{d}","fillSz":"{s}","fillPx":"50000","fillFee":"{s}","fillFeeCcy":"BTC","fillTime":"{d}","execType":"T"}}]}}
        , .{ 1001 + index, command.client_order_id.slice(), if (index == 2) "sell" else "buy", quantity_text, quantity_text, @as(u64, 1_800_000_000_100) + index, 3001 + index, quantity_text, if (mode == .overflow) "-170141183460469231731687303715884105728" else if (wide) "-0.000000000000000001" else if (index == 1) "0.000000001" else "-0.000000001", @as(u64, 1_800_000_000_100) + index });
        const ingress = try implementation.ingestPrivateWs(private_times, input);
        const output = (try adapter.tryDrain()) orelse return error.MissingPrivateBatch;
        if (fault) {
            try std.testing.expectEqual(@as(usize, 1), output.slice().len);
            try std.testing.expectEqual(if (mode == .overflow) canonical.EconomicFaultReason.overflow else .inexact_amount, output.events[0].event.economic_fault.reason);
            const before = owner.shard.economicSummary();
            try owner.applyAdapterBatch(output);
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
            try std.testing.expect(owner.shard.oms.recovery_only);
            try std.testing.expectEqual(@as(u64, 1), owner.shard.economic_fault_count);
            continue;
        }
        try std.testing.expect(ingress.rejection == null);
        for (output.slice()) |record| if (record.event == .fill) {
            try std.testing.expectEqual(@as(i128, 1), record.event.fill.quantity.lots);
            try std.testing.expectEqual(@as(i128, 200_000), record.event.fill.price.ticks);
            try std.testing.expectEqual(okx.btc, record.event.fill.fee.?.asset);
            try std.testing.expectEqual(@as(i128, if (index == 1) 0 else 1), record.event.fill.fee.?.atoms);
            if (index == 1) try std.testing.expectEqual(@as(i128, 1), record.event.fill.rebate.?.atoms);
        };
        if (index == 2 and !cumulative) {
            // Terminal report precedes the economic Fill; the unposted sale still owns inventory.
            var reports: canonical.AdapterOutputBatch = .{};
            for (output.slice()) |record| if (record.event == .execution_report) try reports.append(record);
            try std.testing.expectEqual(@as(u8, 1), reports.len);
            const before = owner.shard.economicSummary();
            try owner.applyAdapterBatch(reports);
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
            try std.testing.expectEqual(@as(i64, 1), owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
            try std.testing.expectEqual(@as(i64, 0), try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
            const next_sequence = owner.shard.trace.len + 1;
            var oversell = intent;
            oversell.intent_sequence = next_sequence;
            oversell.strategy_cursor = owner.shard.trace.len;
            oversell.quantity = 2;
            try std.testing.expect((try owner.apply(.{ .core = .{ .identity = next_sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = oversell } } })) == null);
            try std.testing.expectEqual(@import("trading_shard_event.zig").RejectReason.insufficient_spot_asset, owner.shard.last_reject_reason);
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
        }
        if (cumulative and index == 2) {
            const before = owner.shard.economicSummary();
            try std.testing.expectError(error.AssetAmountOutOfRange, owner.applyAdapterBatch(output));
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
            try std.testing.expect(owner.shard.oms.recovery_only);
            try std.testing.expectEqual(@as(u64, 1), owner.shard.economic_fault_count);
            break;
        }
        try owner.applyAdapterBatch(output);
        const digest = owner.shard.canonicalStateDigest();
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, input)).rejection == null);
        while (try adapter.tryDrain()) |duplicate| try owner.applyAdapterBatch(duplicate);
        try std.testing.expectEqualSlices(u8, &digest, &owner.shard.canonicalStateDigest());
        const base: [3]i128 = if (wide) .{ 19_999_999_999_999_999_999, 0, 0 } else if (nonunit) .{ 249, 500, 249 } else .{ 99, 200, 99 };
        const economic = owner.shard.economicSummary();
        try std.testing.expectEqual(base[index], economic.portfolio.spot_asset_atoms);
        try std.testing.expectEqual(base[index], economic.exchange.spot_asset_atoms);
        try std.testing.expectEqual(@as(i64, if (index == 1) 2 else 1), economic.portfolio.spot.quantity);
        try std.testing.expectEqual(@as(i128, if (index == 1) 1 else if (index == 2) 2 else 1), economic.portfolio.base_fee_atoms);
        try std.testing.expectEqual(@as(i128, if (index == 0) 0 else 1), economic.portfolio.base_rebate_atoms);
        try std.testing.expectEqual(@as(i64, 1), owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
        try std.testing.expectEqual(@as(i64, 1), try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
        // Independent account source confirms native inventory without turning it into a position in lots.
        const cash: [3][]const u8 = if (wide) .{ "1000000", "", "" } else if (nonunit) .{ "99.9875", "99.975", "99.9875" } else .{ "99.995", "99.99", "99.995" };
        const btc: [3][]const u8 = if (wide) .{ "19.999999999999999999", "", "" } else if (nonunit) .{ "0.000000249", "0.0000005", "0.000000249" } else .{ "0.000000099", "0.0000002", "0.000000099" };
        const account = try std.fmt.bufPrint(&frame,
            \\{{"arg":{{"channel":"account"}},"eventType":"update","curPage":1,"lastPage":true,"data":[{{"uTime":"{d}","totalEq":"{s}","adjEq":"{s}","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{{"ccy":"USDT","cashBal":"{s}","availBal":"{s}","eq":"{s}","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}},{{"ccy":"BTC","cashBal":"{s}","availBal":"{s}","eq":"{s}","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}}]}}]}}
        , .{ @as(u64, 1_800_000_000_200) + index, if (wide) "1999999.99999999999995" else if (index == 1) "100" else "99.99995", if (wide) "1999999.99999999999995" else if (index == 1) "100" else "99.99995", cash[index], cash[index], cash[index], btc[index], btc[index], btc[index] });
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, account)).rejection == null);
        try std.testing.expect(try applyDrain(owner, adapter));
        const observed = owner.shard.currentSpotAssetBalance(okx.btc_usdt_spot) orelse return error.MissingNativeBaseBalance;
        try std.testing.expectEqual(okx.btc, observed.asset);
        try std.testing.expectEqual(base[index], observed.atoms);
        if (index == 1) {
            const position = owner.shard.currentNetExchangePosition(okx.btc_usdt_spot) orelse return error.MissingRepresentableSpotPosition;
            try std.testing.expectEqual(@as(i128, 2), position.lots);
        } else try std.testing.expect(owner.shard.currentNetExchangePosition(okx.btc_usdt_spot) == null);
    }
    if (!fault and !account_case) {
        const economic = owner.shard.economicSummary();
        try std.testing.expectEqual(@as(i128, if (wide) 80_000_000_000_000_000_000 else if (cumulative) 89_990_000_000_000 else if (nonunit) 89_987_500_000_000 else 89_995_000_000_000), economic.portfolio.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, if (wide) 100_000_000_000_000_000_000 else if (cumulative) 99_990_000_000_000 else if (nonunit) 99_987_500_000_000 else 99_995_000_000_000), economic.exchange.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, if (wide) 100_000_000_000_000_000_000 else if (cumulative) 10_000_000_000 else if (nonunit) 12_500_000_000 else 5_000_000_000), economic.portfolio.spot.open_cost_atoms);
        try std.testing.expectEqual(@as(i128, 0), economic.portfolio.realized_pnl_atoms);
        for ([_]@import("economics.zig").LedgerLayer{ .portfolio, .exchange }) |layer| {
            var balance: i128 = 0;
            var fees: i128 = 0;
            var rebates: i128 = 0;
            const projection = &owner.shard.economic_projection;
            for (projection.ledger[0..projection.ledger_count]) |transaction| {
                if (transaction.layer != layer) continue;
                for (transaction.postings[0..transaction.posting_count]) |posting| {
                    if (posting.unit != .base_atoms) continue;
                    try std.testing.expectEqual(okx.btc, posting.asset);
                    if (posting.account == .spot_asset) balance = try std.math.add(i128, balance, posting.amount);
                    if (posting.account == .fee_expense) fees = try std.math.add(i128, fees, posting.amount);
                    if (posting.account == .rebate_income) rebates = try std.math.sub(i128, rebates, posting.amount);
                }
            }
            try std.testing.expectEqual(@as(i128, if (wide) 19_999_999_999_999_999_999 else if (cumulative) 200 else if (nonunit) 249 else 99), balance);
            try std.testing.expectEqual(@as(i128, if (wide or cumulative) 1 else 2), fees);
            try std.testing.expectEqual(@as(i128, if (wide) 0 else 1), rebates);
        }
        if (mode == .conflict) {
            const before = owner.shard.economicSummary();
            const input = try std.fmt.bufPrint(&frame,
                \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1003","clOrdId":"{s}","side":"sell","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"{s}","px":"50000","accFillSz":"{s}","avgPx":"50000","uTime":"1800000000102","tradeId":"3003","fillSz":"{s}","fillPx":"50000","fillFee":"-0.000000002","fillFeeCcy":"BTC","fillTime":"1800000000102","execType":"T"}}]}}
            , .{ last_command.client_order_id.slice(), quantity_text, quantity_text, quantity_text });
            try std.testing.expectEqual(private.RejectReason.conflicting_fact, (try implementation.ingestPrivateWs(private_times, input)).rejection.?);
            try std.testing.expect(try applyDrain(owner, adapter));
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
            try std.testing.expect(owner.shard.oms.recovery_only);
        }
    }
    try owner.shard.assertClosures();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    var bytes: [durable.max_snapshot_bytes]u8 = undefined;
    const restored = try @import("trading_shard.zig").TradingShard.restoreSnapshot(try owner.committedSnapshot(&bytes));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, if (mode == .missing_cash) 2 else 1), chain.next_attempt_id);
}

test "OKX native base atom fees rebates preserve gross lots cost and sublot inventory" {
    try checkNativeBaseFees(false, .normal);
}

test "OKX native base nonunit lot and tick keep exact buy sell inventory" {
    try checkNativeBaseFees(true, .normal);
}

test "OKX native base eight digit precision rejects a ninth digit fee durably" {
    try checkNativeBaseFees(false, .legacy_precision);
}

test "OKX native base fee conflict preserves ledger and recovers authority fence" {
    try checkNativeBaseFees(true, .conflict);
}

test "OKX native base checked extreme keeps raw fault and no partial ledger" {
    try checkNativeBaseFees(true, .overflow);
}

test "OKX native base startup requires committed lot and tick authority before monetary decode" {
    try checkNativeBaseFees(false, .missing_authority);
    try checkNativeBaseFees(false, .mismatched_profile);
}

test "OKX native base balance beyond i64 remains exact through postings source observations and recovery" {
    try checkNativeBaseFees(false, .wide);
}

test "OKX native base cumulative traded range rejects netted third fill before ledger commit" {
    try checkNativeBaseFees(false, .cumulative);
}

test "activated balance limits reject cumulative Suspense growth before Owner commit" {
    const allocator = std.testing.allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    var definitions = @import("asset_registry.zig").testDefinitions(6, 8);
    for (&definitions) |*definition| {
        definition.max_single_atoms = 100;
        definition.max_balance_atoms = 100;
        definition.max_cumulative_atoms = 1000;
        _ = try owner.apply(.{ .core = .{ .identity = definition.asset, .payload = .{ .asset_definition_activated = definition.* } } });
    }
    const trading = @import("trading_shard.zig");
    const bootstrap = [_]trading.CorePayload{
        .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = 3, .quantity_denominator = 10_000, .reservation_model = .leveraged, .product = .isolated_linear_usdt, .venue = 1 } },
        .{ .margin_rules_activated = .{ .version = 1 } },
        .{ .account_configuration = .{ .exchange_account_identity = 2 } },
        .{ .exchange_balance = .{ .cash_atoms = 100 } },
        .exchange_positions,
        .{ .opening_balance = .{ .cash_atoms = 100 } },
        .{ .funding_settlement = .{ .settlement_id = 10, .amount_atoms = -100 } },
    };
    for (bootstrap, 0..) |payload, index|
        _ = try owner.apply(.{ .core = .{ .identity = index + 3, .payload = payload } });
    try std.testing.expectEqual(@as(i64, -100), owner.shard.economicSummary().suspense_usdt_atoms);
    const before = owner.shard.economicSummary();
    const digest = owner.shard.canonicalStateDigest();
    try owner.sealBootstrap();
    try std.testing.expectError(error.AssetAmountOutOfRange, owner.apply(.{ .core = .{ .identity = 11, .payload = .{ .funding_settlement = .{ .settlement_id = 11, .amount_atoms = -100 } } } }));
    try std.testing.expect(owner.closed);
    try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
    try std.testing.expectEqualSlices(u8, &digest, &owner.shard.canonicalStateDigest());
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &digest, &recovered.shard.canonicalStateDigest());
    var bytes: [durable.max_snapshot_bytes]u8 = undefined;
    const restored = try trading.TradingShard.restoreSnapshot(try recovered.committedSnapshot(&bytes));
    try std.testing.expectEqualSlices(u8, &digest, &restored.shard.canonicalStateDigest());
}

test "OKX ready economic faults distinguish micro fees rebates assets and decoder failures" {
    const Case = struct { fee: []const u8, asset: []const u8 = "USDT", reason: canonical.EconomicFaultReason, rejection: ?private.RejectReason = null };
    const cases = [_]Case{
        .{ .fee = "-0.004198632165", .reason = .inexact_amount },
        .{ .fee = "-0.00423723852", .reason = .inexact_amount },
        .{ .fee = "-0.0000001", .reason = .inexact_amount },
        .{ .fee = "0.0000001", .reason = .inexact_amount },
        .{ .fee = "-0.000000001", .asset = "BTC", .reason = .inexact_amount },
        .{ .fee = "-0.1", .asset = "BNB", .reason = .unknown_asset },
        .{ .fee = "", .reason = .missing_amount, .rejection = .missing_amount },
        .{ .fee = "0", .asset = "", .reason = .missing_asset, .rejection = .missing_asset },
        .{ .fee = "bad", .reason = .malformed_amount, .rejection = .malformed_amount },
        .{ .fee = "170141183460469231731687303715884105728", .reason = .overflow, .rejection = .amount_overflow },
        .{ .fee = "-170141183460469231731687303715884105728", .reason = .overflow },
        .{ .fee = "-170141183460469231731687303715884.105728", .reason = .overflow },
        .{ .fee = "0.000000000000000000000000000000000000001", .reason = .overflow, .rejection = .amount_overflow },
        .{ .fee = &@as([canonical.Decimal.max_text_bytes + 1]u8, @splat('0')), .reason = .overflow, .rejection = .amount_overflow },
    };
    for (cases) |case| for ([_]bool{ false, true }) |rest| {
        if (rest and case.rejection == null) continue;
        try checkReadyEconomicFault(case.fee, case.asset, case.reason, case.rejection, false, null, rest);
    };
}

test "core rejected canonical economic amount persists without partial accounting or send authority" {
    try checkReadyEconomicFault("-0.01", "USDT", .overflow, null, true, null, false);
    try checkReadyEconomicFault(null, "USDT", .invalid_economic_fact, null, true, null, false);
}

test "OKX economic fault append and commit failures retain raw facts and close sending" {
    for ([_]durable.FaultPoint{ .append, .commit }) |point|
        try checkReadyEconomicFault("-0.0000001", "USDT", .inexact_amount, null, false, point, false);
}

test "OKX native account missing cash facts cannot use USD equity as available funds" {
    try checkNativeBaseFees(false, .missing_cash);
}

test "OKX native account held cash blocks risk despite unchanged local ledger and USD equity" {
    try checkNativeBaseFees(false, .unavailable_cash);
}

test "OKX native account USD valuation retains finer decimals without fabricating USDT margin" {
    try checkNativeBaseFees(false, .usd_precision);
}

fn checkNativeThirdFees(mode: enum { normal, wide, unknown, inexact, conflict, cumulative, capacity }) !void {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    const pair = @import("asset_registry.zig").testDefinitions(12, 9);
    var definitions: [3]canonical.AssetDefinition = .{ pair[0], pair[1], pair[0] };
    const third: canonical.AssetIdentity = 0x424e42;
    definitions[2].asset = third;
    definitions[2].source_identity = 0x74657374 + third;
    definitions[2].code_bindings = @splat(.{});
    definitions[2].code_binding_count = 1;
    definitions[2].code_bindings[0] = try canonical.AssetCodeBinding.init(1, "BNB");
    if (mode == .wide) {
        definitions[2].atomic_scale = 18;
        definitions[2].max_rescale_power = 18;
        definitions[2].max_single_atoms = 100_000_000_000_000_000_000;
        definitions[2].max_balance_atoms = 100_000_000_000_000_000_000;
        definitions[2].max_cumulative_atoms = 100_000_000_000_000_000_000;
    } else if (mode == .cumulative) {
        definitions[2].max_single_atoms = 40_000_000_000_000;
        definitions[2].max_balance_atoms = 40_000_000_000_000;
        definitions[2].max_cumulative_atoms = 40_000_000_000_000;
    }
    const policy: demo.Policy = .{
        .schema = 3,
        .startup = .virgin,
        .asset_definitions = definitions[0..if (mode == .unknown) 2 else 3],
        .lot_size = .{ .coefficient = 1, .scale = 7 },
        .exchange_account = 2,
        .portfolio_identity = 1,
        .strategy_identity = 40,
        .activation_identity = 50,
        .config_version = 1,
        .portfolio_allocation_atoms = 90_000_000_000_000,
        .risk_limit_atoms = 80_000_000_000_000,
        .price_tick_atoms = 250_000_000_000,
        .native_settlement_atoms = true,
        .decision_stream_id = 91,
        .dispatch_stream_id = 92,
        .decision_domain = 1,
        .node_identity = 1,
    };
    try policy.activateAssetsForOfflineValidation(owner);
    var raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 1 });
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
    var frame: [2048]u8 = undefined;
    const opening: i128 = if (mode == .wide) 20_000_000_000_000_000_000 else if (mode == .cumulative) 40_000_000_000_000 else 10_000_000_000_000;
    if (mode != .unknown) {
        const balance_text = if (mode == .wide) "20" else if (mode == .cumulative) "40" else "10";
        const account = try std.fmt.bufPrint(&frame,
            \\{{"arg":{{"channel":"account"}},"eventType":"update","curPage":1,"lastPage":true,"data":[{{"uTime":"1800000000002","totalEq":"100","adjEq":"100","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{{"ccy":"USDT","cashBal":"100","availBal":"100","eq":"100","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}},{{"ccy":"BNB","cashBal":"{s}","availBal":"{s}","eq":"{s}","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}}]}}]}}
        , .{ balance_text, balance_text, balance_text });
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, account)).rejection == null);
        try std.testing.expect(try applyDrain(owner, adapter));
    }
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try policy.initialize(owner, 50_000_000_000_000_000, &guard, 1, 1);
    _ = try owner.apply(.{ .core = .{ .identity = 71, .payload = .{ .risk_lease_granted = .{ .lease_identity = 71, .version = 2, .amount_atoms = 80_000_000_000_000, .valid_through_barrier = 1000 } } } });
    _ = try owner.apply(fixtureOnSecondaryStream(18, 2, .{ .instrument_definition_observed = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1 } }));
    _ = try owner.apply(fixtureOnSecondaryStream(19, 3, .{ .l2_book_snapshot = .{
        .instrument = okx.btc_usdt_spot,
        .sequence = 3,
        .best_bid = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 199_999 },
        .best_ask = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 200_000 },
        .best_bid_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 1_000_000 },
        .best_ask_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 1_000_000 },
    } }));
    const count: usize = switch (mode) {
        .wide, .unknown, .inexact => 1,
        .cumulative => 2,
        .capacity => 12,
        else => 3,
    };
    var capacity_command: ?@import("oms.zig").Command = null;
    var applied: i64 = 0;
    var fees: i128 = 0;
    var rebates: i128 = 0;
    for (0..count) |index| {
        const sequence = owner.shard.trace.len + 1;
        const intent: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = sequence, .strategy_cursor = owner.shard.trace.len, .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = .buy, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = if (mode == .capacity) 12 else 1, .limit_price_micros = 50_000_000_000 };
        const command = if (mode == .capacity and index != 0) capacity_command.? else (try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = intent } } })) orelse return error.MissingDemoCommand;
        if (mode == .capacity) capacity_command = command;
        try implementation.rememberRecoveredOrder(command.order_id, command.client_order_id, false, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
        if (mode != .capacity or index == 0) _ = try owner.apply(fixtureOnSecondaryStream(20 + index, 4 + index, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .submitted } }));
        const fee_text = if (mode == .wide) "-10" else if (mode == .cumulative) "-25" else if (mode == .inexact) "-0.0000000000001" else if (mode == .capacity or index == 0) "-0.000000000001" else if (index == 1) "0.000000000001" else "0";
        var accumulated: [32]u8 = undefined;
        const cumulative_quantity = if (mode == .capacity) try std.fmt.bufPrint(&accumulated, "0.{d:0>7}", .{index + 1}) else "0.0000001";
        const input = try std.fmt.bufPrint(&frame,
            \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"{d}","clOrdId":"{s}","side":"buy","ordType":"limit","state":"{s}","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"{s}","px":"50000","accFillSz":"{s}","avgPx":"50000","uTime":"{d}","tradeId":"{d}","fillSz":"0.0000001","fillPx":"50000","fillFee":"{s}","fillFeeCcy":"BNB","fillTime":"{d}","execType":"T"}}]}}
        , .{ if (mode == .capacity) 7001 else 7001 + index, command.client_order_id.slice(), if (mode == .capacity) "partially_filled" else "filled", if (mode == .capacity) "0.0000012" else "0.0000001", cumulative_quantity, @as(u64, 1_800_000_000_100) + index, 8001 + index, fee_text, @as(u64, 1_800_000_000_100) + index });
        const ingress = try implementation.ingestPrivateWs(private_times, input);
        const output = (try adapter.tryDrain()) orelse return error.MissingPrivateBatch;
        const before = owner.shard.economicSummary();
        if (mode == .unknown or mode == .inexact) {
            try std.testing.expectEqual(@as(usize, 1), output.slice().len);
            try std.testing.expectEqual(if (mode == .unknown) canonical.EconomicFaultReason.unknown_asset else .inexact_amount, output.events[0].event.economic_fault.reason);
            try owner.applyAdapterBatch(output);
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
            try std.testing.expect(owner.shard.oms.recovery_only);
            break;
        }
        try std.testing.expect(ingress.rejection == null);
        if (mode == .cumulative and index == 1) {
            try std.testing.expectError(error.AssetAmountOutOfRange, owner.applyAdapterBatch(output));
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
            try std.testing.expect(owner.shard.oms.recovery_only);
            try std.testing.expectEqual(@as(i64, 1), owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
            try std.testing.expectEqual(@as(i64, 0), try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
            break;
        }
        if (mode == .capacity and index == 10) {
            try std.testing.expectError(error.LedgerCapacityExceeded, owner.applyAdapterBatch(output));
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
            try std.testing.expect(owner.shard.oms.recovery_only);
            try std.testing.expectEqual(@as(i64, 11), owner.shard.oms.orderById(command.order_id).?.cumulative_quantity);
            try std.testing.expectEqual(@as(i64, 10), try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
            try std.testing.expectEqual(canonical.EconomicFaultReason.capacity_exhausted, owner.shard.economic_fault_reason);
            break;
        }
        try owner.applyAdapterBatch(output);
        applied += 1;
        if (mode == .wide) fees = 10_000_000_000_000_000_000 else if (mode == .cumulative) fees = 25_000_000_000_000 else if (mode == .capacity or index == 0) fees += 1 else if (index == 1) rebates = 1;
        const economic = owner.shard.economicSummary();
        const portfolio = economic.portfolio.nativeAsset(third) orelse return error.MissingNativeFeeAsset;
        const exchange = economic.exchange.nativeAsset(third) orelse return error.MissingNativeFeeAsset;
        try std.testing.expectEqual(-fees + rebates, portfolio.balance_atoms);
        try std.testing.expectEqual(opening - fees + rebates, exchange.balance_atoms);
        try std.testing.expectEqual(fees, portfolio.fee_atoms);
        try std.testing.expectEqual(rebates, portfolio.rebate_atoms);
        try std.testing.expectEqual(fees, exchange.fee_atoms);
        try std.testing.expectEqual(rebates, exchange.rebate_atoms);
        try std.testing.expectEqual(applied, economic.portfolio.spot.quantity);
        try std.testing.expectEqual(@as(i128, applied) * 100, economic.portfolio.spot_asset_atoms);
        try std.testing.expectEqual(@as(i128, applied) * 5_000_000_000, economic.portfolio.spot.open_cost_atoms);
        try std.testing.expectEqual(@as(i128, 90_000_000_000_000) - @as(i128, applied) * 5_000_000_000, economic.portfolio.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, 0), economic.portfolio.fee_atoms);
        try std.testing.expectEqual(@as(i128, 0), economic.portfolio.base_fee_atoms);
        try std.testing.expectEqual(opening, economic.treasury_native_assets[0].atoms);
        try std.testing.expectEqual(@as(u8, 0), economic.suspense_native_asset_count);
        try std.testing.expect(!economic.valuation_complete);
        const digest = owner.shard.canonicalStateDigest();
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, input)).rejection == null);
        while (try adapter.tryDrain()) |duplicate| try owner.applyAdapterBatch(duplicate);
        try std.testing.expectEqualSlices(u8, &digest, &owner.shard.canonicalStateDigest());
        if (mode == .conflict and index == 2) {
            const changed = try std.fmt.bufPrint(&frame,
                \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"7003","clOrdId":"{s}","side":"buy","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0000001","px":"50000","accFillSz":"0.0000001","avgPx":"50000","uTime":"1800000000102","tradeId":"8003","fillSz":"0.0000001","fillPx":"50000","fillFee":"-0.000000000002","fillFeeCcy":"BNB","fillTime":"1800000000102","execType":"T"}}]}}
            , .{command.client_order_id.slice()});
            try std.testing.expectEqual(private.RejectReason.conflicting_fact, (try implementation.ingestPrivateWs(private_times, changed)).rejection.?);
            try std.testing.expect(try applyDrain(owner, adapter));
            try std.testing.expectEqualDeep(economic, owner.shard.economicSummary());
            try std.testing.expect(owner.shard.oms.recovery_only);
        }
    }
    if (applied != 0) {
        for ([_]@import("economics.zig").LedgerLayer{ .portfolio, .exchange }) |layer| {
            var charged: i128 = 0;
            var returned: i128 = 0;
            for (owner.shard.economic_projection.ledger[0..owner.shard.economic_projection.ledger_count]) |transaction| {
                if (transaction.layer != layer) continue;
                for (transaction.postings[0..transaction.posting_count]) |posting| {
                    if (posting.unit != .native_asset_atoms) continue;
                    try std.testing.expectEqual(third, posting.asset);
                    if (posting.account == .fee_expense) charged += posting.amount;
                    if (posting.account == .rebate_income) returned -= posting.amount;
                }
            }
            try std.testing.expectEqual(fees, charged);
            try std.testing.expectEqual(rebates, returned);
        }
    }
    try owner.shard.assertClosures();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    var bytes: [durable.max_snapshot_bytes]u8 = undefined;
    const restored = try @import("trading_shard.zig").TradingShard.restoreSnapshot(try owner.committedSnapshot(&bytes));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
}

test "OKX native third asset fees rebates zero retain portfolio ownership original postings and unvalued status" {
    try checkNativeThirdFees(.normal);
}

test "OKX native third asset amounts beyond i64 preserve opening Treasury ownership and exact fees" {
    try checkNativeThirdFees(.wide);
}

test "OKX native third asset unknown and subatom fees keep unresolved facts without ledger commit" {
    try checkNativeThirdFees(.unknown);
    try checkNativeThirdFees(.inexact);
}

test "OKX native third asset conflict retains original ledger and recovered failure fence" {
    try checkNativeThirdFees(.conflict);
}

test "OKX native third asset cumulative fees cannot exceed activated bounds after net balance changes" {
    try checkNativeThirdFees(.cumulative);
}

test "OKX native third asset ledger capacity preserves all preceding economics and unresolved fill" {
    try checkNativeThirdFees(.capacity);
}

test "OKX native account balances cash held and each liability retain independent exact asset units" {
    try checkNativeBaseFees(false, .native_liabilities);
}

fn checkNativeFundingBills(mode: enum { normal, unknown, inexact, range, conflict, historical, cumulative }) !void {
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    const definitions = @import("asset_registry.zig").testDefinitions(12, 9);
    const policy: demo.Policy = .{ .schema = 3, .startup = .virgin, .asset_definitions = &definitions, .lot_size = .{ .coefficient = 1, .scale = 7 }, .exchange_account = 2, .portfolio_identity = 1, .strategy_identity = 40, .activation_identity = 50, .config_version = 1, .portfolio_allocation_atoms = 90_000_000_000_000, .risk_limit_atoms = 80_000_000_000_000, .price_tick_atoms = 250_000_000_000, .native_settlement_atoms = true, .decision_stream_id = 91, .dispatch_stream_id = 92, .decision_domain = 1, .node_identity = 1 };
    try policy.activateAssetsForOfflineValidation(owner);
    _ = try owner.apply(.{ .core = .{ .identity = 100, .payload = .{ .instrument_rules_activated = .{
        .version = 1,
        .instrument_identity = okx.btc_usdt_swap,
        .quantity_denominator = 100,
        .reservation_model = .leveraged,
        .product = .isolated_linear_usdt,
        .venue = 1,
        .settlement_asset = okx.usdt,
    } } } });
    _ = try owner.apply(.{ .core = .{ .identity = 101, .payload = .{ .margin_rules_activated = .{
        .version = 1,
        .instrument = okx.btc_usdt_swap,
        .price_tick_atoms = 100_000_000_000,
        .native_settlement_atoms = true,
    } } } });
    var raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 1 });
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
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try policy.initialize(owner, 50_000_000_000_000_000, &guard, 1, 1);
    if (mode == .range or mode == .cumulative) {
        var narrower = definitions[0];
        narrower.version = 2;
        narrower.max_single_atoms = if (mode == .range) 4_000_000_000 else 100_000_000_000_000;
        if (mode == .cumulative) {
            narrower.max_balance_atoms = 100_000_000_000_000;
            narrower.max_cumulative_atoms = 100_000_000_000_000;
        }
        _ = try owner.apply(.{ .core = .{ .identity = 102, .payload = .{ .asset_definition_activated = narrower } } });
    }
    const frames = [_][]const u8{
        \\{"code":"0","data":[{"billId":"9001","type":"8","subType":"173","instType":"SWAP","instId":"BTC-USDT-SWAP","ccy":"USDT","pnl":"-0.004198632165","fee":"0","balChg":"0","posBalChg":"-0.004198632165","px":"50000","mgnMode":"","ts":"1800000000200"}]}
        ,
        \\{"code":"0","data":[{"billId":"9002","type":"8","subType":"174","instType":"SWAP","instId":"BTC-USDT-SWAP","ccy":"USDT","pnl":"0.00423723852","fee":"0","balChg":"0","posBalChg":"0.00423723852","px":"50000","mgnMode":"","ts":"1800000000201"}]}
    };
    const totals = if (mode == .cumulative) [_]i128{ -60_000_000_000_000, 0 } else [_]i128{ -4_198_632_165, 38_606_355 };
    for (frames, 0..) |original_frame, index| {
        const frame = if (mode == .unknown)
            \\{"code":"0","data":[{"billId":"9001","type":"8","subType":"173","instType":"SWAP","instId":"BTC-USDT-SWAP","ccy":"UNREGISTERED","pnl":"-0.004198632165","fee":"0","ts":"1800000000200"}]}
        else if (mode == .inexact)
            \\{"code":"0","data":[{"billId":"9001","type":"8","subType":"173","instType":"SWAP","instId":"BTC-USDT-SWAP","ccy":"USDT","pnl":"-0.0000000000001","fee":"0","ts":"1800000000200"}]}
        else if (mode == .historical)
            \\{"code":"0","data":[{"billId":"9001","type":"8","subType":"173","instType":"SWAP","instId":"BTC-USDT-SWAP","ccy":"USDT","pnl":"-0.004198632165","fee":"0","ts":"1800000000001"}]}
        else if (mode == .cumulative and index == 0)
            \\{"code":"0","data":[{"billId":"9001","type":"8","subType":"173","instType":"SWAP","instId":"BTC-USDT-SWAP","ccy":"USDT","pnl":"-60","fee":"0","ts":"1800000000200"}]}
        else if (mode == .cumulative)
            \\{"code":"0","data":[{"billId":"9002","type":"8","subType":"174","instType":"SWAP","instId":"BTC-USDT-SWAP","ccy":"USDT","pnl":"60","fee":"0","ts":"1800000000201"}]}
        else
            original_frame;
        try std.testing.expect((try implementation.ingestPrivateRest(private_times, .rest_account_bills, .{ .final = true }, frame)).rejection == null);
        const output = (try adapter.tryDrain()).?;
        const before = owner.shard.economicSummary();
        try std.testing.expectEqual(@as(u8, 1), output.len);
        if (mode == .unknown or mode == .inexact) {
            try std.testing.expect(output.events[0].event == .economic_fault);
            try std.testing.expectEqual(if (mode == .unknown) canonical.EconomicFaultReason.unknown_asset else .inexact_amount, output.events[0].event.economic_fault.reason);
            try owner.applyAdapterBatch(output);
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
            try std.testing.expect(owner.shard.oms.recovery_only and owner.shard.economic_fault_count != 0);
            break;
        }
        if (mode == .range or mode == .historical or (mode == .cumulative and index == 1)) {
            try std.testing.expectError(if (mode == .historical) error.UnresolvedSettlementBoundary else error.AssetAmountOutOfRange, owner.applyAdapterBatch(output));
            try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
            try std.testing.expect(owner.shard.oms.recovery_only);
            break;
        }
        try std.testing.expect(output.events[0].event == .funding_settlement);
        try owner.applyAdapterBatch(output);
        const economic = owner.shard.economicSummary();
        try std.testing.expectEqual(@as(i128, 100_000_000_000_000) + totals[index], economic.exchange.usdt_balance_atoms);
        try std.testing.expectEqual(@as(i128, 90_000_000_000_000), economic.portfolio.usdt_balance_atoms);
        try std.testing.expectEqual(totals[index], economic.suspense_usdt_atoms);
        try std.testing.expectEqual(totals[index], economic.exchange.funding_atoms);
        try std.testing.expectEqual(@as(i128, 0), economic.portfolio.funding_atoms);
        try std.testing.expectEqual(@as(i128, 0), economic.portfolio.realized_pnl_atoms);
        try std.testing.expect(economic.reconciliation_break and !owner.shard.operational_state.effectiveTradingAuthority());
        const once = owner.shard.canonicalStateDigest();
        try owner.applyAdapterBatch(output);
        try std.testing.expectEqualSlices(u8, &once, &owner.shard.canonicalStateDigest());
        try std.testing.expect((try implementation.ingestPrivateRest(private_times, .rest_account_bills, .{ .final = true }, frame)).rejection == null);
        try std.testing.expect((try adapter.tryDrain()) == null);
        try owner.shard.assertClosures();
        if (mode == .conflict) {
            var changed = output;
            changed.events[0].event.funding_settlement.venue_bill_id += 1;
            changed.events[0].envelope.identity.sequence += 1;
            try std.testing.expectError(error.ConflictingEconomicIdentity, owner.applyAdapterBatch(changed));
            try std.testing.expectEqualDeep(economic, owner.shard.economicSummary());
            try std.testing.expect(owner.shard.oms.recovery_only);
            break;
        }
    }
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    var bytes: [durable.max_snapshot_bytes]u8 = undefined;
    const restored = try @import("trading_shard.zig").TradingShard.restoreSnapshot(try owner.committedSnapshot(&bytes));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
}

test "OKX native funding bills retain actual payments in Suspense without fabricating portfolio PnL" {
    try checkNativeFundingBills(.normal);
}

test "OKX native funding unknown inexact and range retain unresolved source without economic commit" {
    try checkNativeFundingBills(.unknown);
    try checkNativeFundingBills(.inexact);
    try checkNativeFundingBills(.range);
}

test "OKX native funding full metadata conflict retains ledger and recoverable failure fence" {
    try checkNativeFundingBills(.conflict);
}

test "OKX funding included in opening baseline stays unresolved without a second cash entry" {
    try checkNativeFundingBills(.historical);
}

test "OKX opposite funding payments cannot hide cumulative native overflow by netting" {
    try checkNativeFundingBills(.cumulative);
}
