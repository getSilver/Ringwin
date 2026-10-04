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
    try adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4 });
    try implementation.beginPrivateSession();

    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);

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
        \\{"schema":1,"startup":"virgin","exchange_account":2,"portfolio_identity":1,"strategy_identity":40,"activation_identity":50,"config_version":1,"portfolio_allocation_micros":20000000,"risk_limit_micros":10000000,"decision_stream_id":91,"dispatch_stream_id":92,"decision_domain":1,"node_identity":1}
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
    const after_report = try allocator.create(demo.Owner);
    defer allocator.destroy(after_report);
    after_report.* = try demo.Owner.recover(memory.interface(), undefined, stream);
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
    try tail_adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4 });
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
    after_fill.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &fill_digest, &after_fill.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(i64, 10_000), try after_fill.shard.economic_projection.appliedCanonicalFillQuantity(@intCast(command.order_id)));
    owner.* = after_report.*;
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
    const full_intent: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = full_sequence, .strategy_cursor = owner.shard.trace.len, .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = .buy, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 10_000, .limit_price_micros = 50_000_000 };
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
    try std.testing.expectEqualSlices(u8, &before_duplicate, &owner.shard.canonicalStateDigest());
    var recovered_raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 2 });
    var recovered_chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = recovered_raw.interface(), .transport = transport.interface() };
    var recovered_clock = Clock{};
    var recovered_reconciler: private.Reconciler = .{};
    var recovered_implementation = okx.OkxVenueAdapter.init(allocator, &recovered_chain, recovered_clock.interface(), profile(), rules());
    recovered_implementation.attachPrivateReconciler(&recovered_reconciler);
    const recovered_adapter = recovered_implementation.adapter();
    try recovered_adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4 });
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
    try std.testing.expectEqual(@as(i64, 29_900), owner.shard.economicSummary().portfolio.spot.quantity);
    try std.testing.expectEqual(@as(i64, 10_000), owner.shard.economicSummary().portfolio.fee_micros);
    try std.testing.expectEqual(@as(i64, 1_000), owner.shard.economicSummary().portfolio.rebate_micros);

    const live_digest = owner.shard.canonicalStateDigest();
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &live_digest, &(try recovered.source()).canonicalStateDigest());
    const Replay = struct {
        count: u64 = 0,
        saw_rest_route: bool = false,

        fn consume(ptr: *anyopaque, _: u64, record: @import("okx_public_market.zig").RawIngressRecord, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
            self.saw_rest_route = self.saw_rest_route or record.origin != 0;
        }
    };
    var replay = Replay{};
    try raw_ingress.replayCommitted(memory.interface(), undefined, raw_stream, .{ .ptr = &replay, .consume_fn = Replay.consume });
    try std.testing.expect(replay.count > 0 and replay.saw_rest_route);
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
    try adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4 });
    try implementation.beginPrivateSession();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
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
        \\{"schema":1,"startup":"virgin","exchange_account":2,"portfolio_identity":1,"strategy_identity":40,"activation_identity":50,"config_version":1,"portfolio_allocation_micros":20000000,"risk_limit_micros":10000000,"decision_stream_id":91,"dispatch_stream_id":92,"decision_domain":1,"node_identity":1}
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
    var frame: [2048]u8 = undefined;
    const input = if (rest) try std.fmt.bufPrint(&frame,
        \\{{"code":"0","data":[{{"instId":"BTC-USDT","ordId":"1001","billId":"3001","clOrdId":"{s}","side":"buy","tradeId":"2001","fillSz":"0.0001","fillPx":"50000","fee":"{s}","feeCcy":"{s}","fillTime":"1800000000100","execType":"M"}}]}}
    , .{ command.client_order_id.slice(), fee.?, asset }) else if (fee) |amount| try std.fmt.bufPrint(&frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"partially_filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0002","px":"50000","accFillSz":"0.0001","avgPx":"50000","uTime":"1800000000100","tradeId":"2001","fillSz":"0.0001","fillPx":"50000","fillFee":"{s}","fillFeeCcy":"{s}","fee":"-0.01","feeCcy":"USDT","rebate":"{s}","rebateCcy":"USDT","fillTime":"1800000000100","execType":"M"}}]}}
    , .{ command.client_order_id.slice(), amount, asset, "0.02" }) else
        \\{"arg":{"channel":"account"},"eventType":"update","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000001","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"25.123456789","eq":"25.123456789","availBal":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    ;
    const ingress = if (rest) try implementation.ingestPrivateRest(private_times, .rest_fills_history_spot, .{ .final = true }, input) else try implementation.ingestPrivateWs(private_times, input);
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
        try std.testing.expect(output.events[1].event == .fill);
        try std.testing.expect(output.events[1].event.fill.rebate == null);
        output.events[1].event.fill.fee.?.atoms = std.math.maxInt(i128);
        try std.testing.expectError(error.Overflow, owner.applyAdapterBatch(output));
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
    if (fee == null) {
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
        try std.testing.expectError(error.NotSent, gateway.sendFromShard(&owner.shard, command.command_id, 2));
        try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(&owner.shard, cancel.command_id, 2));
        try std.testing.expectEqual(@as(u64, 2), chain.next_attempt_id);
    }
}

test "OKX ready inexact account fact persists a fail closed result without reconciliation" {
    try checkReadyEconomicFault(null, "USDT", .inexact_amount, null, false, null, false);
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
    };
    for (cases) |case| for ([_]bool{ false, true }) |rest| {
        if (rest and case.rejection == null) continue;
        try checkReadyEconomicFault(case.fee, case.asset, case.reason, case.rejection, false, null, rest);
    };
}

test "core rejected canonical economic amount persists without partial accounting or send authority" {
    try checkReadyEconomicFault("-0.01", "USDT", .overflow, null, true, null, false);
}

test "OKX economic fault append and commit failures retain raw facts and close sending" {
    for ([_]durable.FaultPoint{ .append, .commit }) |point|
        try checkReadyEconomicFault("-0.0000001", "USDT", .inexact_amount, null, false, point, false);
}
