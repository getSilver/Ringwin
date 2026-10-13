//! Offline Windows file recovery of an unpublished economic fault.
//! Venue-private frames enter the OKX adapter; Owner receives canonical facts.

const builtin = @import("builtin");
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
const recovery = @import("okx_private_recovery.zig");

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

fn ingestBootstrapRound(implementation: *okx.OkxVenueAdapter, native: bool) !void {
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
    for (sources, frames) |source, frame| {
        var buffer: [2048]u8 = undefined;
        try std.testing.expect((try implementation.ingestPrivateRest(private_times, source, .{ .final = true }, nativeFrame(frame, native, &buffer))).rejection == null);
    }
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

fn failCommit(context: *anyopaque, io: std.Io, stream: durable.StreamIdentity, barrier: u64) !void {
    const adapter: *durable.WindowsFileAdapter = @ptrCast(@alignCast(context));
    adapter.injectFault(.eio);
    try adapter.interface().commit(io, stream, barrier);
}

fn checkRawFailure(io: std.Io, path: []const u8, file_store: *durable.WindowsFileAdapter, raw: *raw_ingress.DurableSink, implementation: *okx.OkxVenueAdapter, owner: *demo.Owner, input: []const u8, point: durable.FaultPoint, transport: *Transport) !void {
    const stream = owner.stream;
    const raw_stream = raw.stream;
    const before = try file_store.interface().recover(io, raw_stream);
    const expected = owner.shard.canonicalStateDigest();
    var vtable = raw.store.vtable.*;
    if (point == .append) file_store.injectFault(.eio) else {
        vtable.commit = failCommit;
        raw.store = .{ .context = file_store, .vtable = &vtable };
    }
    try std.testing.expectError(error.Unavailable, implementation.ingestPrivateWs(private_times, input));
    try std.testing.expectEqualSlices(u8, &expected, &owner.shard.canonicalStateDigest());
    try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
    try std.testing.expect((try implementation.adapter().tryDrain()) == null);
    file_store.close(io);
    for (0..2) |_| {
        const reopened = try std.heap.page_allocator.create(durable.WindowsFileAdapter);
        defer std.heap.page_allocator.destroy(reopened);
        @memset(std.mem.asBytes(reopened), 0);
        try reopened.initWindowsVerification(io, path);
        defer reopened.close(io);
        const source = try reopened.interface().recover(io, raw_stream);
        try std.testing.expectEqual(before.committed_barrier, source.committed_barrier);
        try std.testing.expectEqual(before.last_sequence + @as(u64, if (point == .commit) 1 else 0), source.last_sequence);
        if (point == .commit) {
            try std.testing.expectError(error.RawIngressUnavailable, raw_ingress.DurableSink.recover(reopened.interface(), io, raw_stream));
            const rejected_owner = try std.heap.page_allocator.create(demo.Owner);
            defer std.heap.page_allocator.destroy(rejected_owner);
            try std.testing.expectError(error.DecisionLogUnavailable, demo.Owner.recoverWithIngressInto(rejected_owner, reopened.interface(), io, stream, raw_stream));
        } else {
            const restored = try std.heap.page_allocator.create(demo.Owner);
            defer std.heap.page_allocator.destroy(restored);
            try demo.Owner.recoverWithIngressInto(restored, reopened.interface(), io, stream, raw_stream);
            try std.testing.expectEqualSlices(u8, &expected, &restored.shard.canonicalStateDigest());
            try std.testing.expect(restored.shard.recovery_admission_pending);
        }
        try std.testing.expectEqual(@as(usize, 0), transport.sends);
    }
}

fn checkNativeSchemaRejection(owner: *demo.Owner, store: durable.Store, io: std.Io, raw_stream: durable.StreamIdentity, event: canonical.EventRecord) !void {
    const trading = @import("trading_shard.zig");
    const codec = @import("snapshot_codec.zig");
    const contract = @import("production_contract.zig");
    const canonical_codec = @import("canonical_event_codec.zig");
    const source = try store.recover(io, raw_stream);
    const before = owner.shard.canonicalStateDigest();
    const original = try std.heap.page_allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.heap.page_allocator.free(original);
    const snapshot = try owner.committedSnapshot(original);
    const damaged = try std.heap.page_allocator.alloc(u8, durable.max_snapshot_bytes);
    defer std.heap.page_allocator.free(damaged);
    // Stable physical-header fields; reseal its checksum so rejection tests the
    // compatibility boundary, independently of transport integrity corruption.
    const variants = [_]enum { state, registry, artifact, encoding }{ .state, .registry, .artifact, .encoding };
    for (variants) |variant| {
        @memcpy(damaged[0..snapshot.len], snapshot);
        switch (variant) {
            .state => std.mem.writeInt(u32, damaged[16..20], contract.previous_state_schema_version, .little),
            .registry => std.mem.writeInt(u64, damaged[28..36], contract.schema_registry_identity - 1, .little),
            .artifact => std.mem.writeInt(u64, damaged[20..28], trading.release_artifact_identity + 1, .little),
            .encoding => std.mem.writeInt(u16, damaged[8..10], 0, .little),
        }
        std.mem.writeInt(u32, damaged[124..128], std.hash.crc.Crc32Iscsi.hash(damaged[0..124]), .little);
        const rejected_snapshot = try std.heap.page_allocator.create(trading.TradingShard);
        defer std.heap.page_allocator.destroy(rejected_snapshot);
        try std.testing.expectError(error.InvalidSnapshotHeader, trading.TradingShard.restoreSnapshotInto(rejected_snapshot, damaged[0..snapshot.len]));
    }
    @memcpy(damaged[0..snapshot.len], snapshot);
    damaged[codec.header_len] ^= 1;
    const rejected_payload = try std.heap.page_allocator.create(trading.TradingShard);
    defer std.heap.page_allocator.destroy(rejected_payload);
    try std.testing.expectError(error.InvalidSnapshotPayload, trading.TradingShard.restoreSnapshotInto(rejected_payload, damaged[0..snapshot.len]));
    const intact = try std.heap.page_allocator.create(@import("trading_shard.zig").SnapshotRestore);
    defer std.heap.page_allocator.destroy(intact);
    intact.barrier = try @import("trading_shard.zig").TradingShard.restoreSnapshotInto(&intact.shard, snapshot);
    try std.testing.expectEqualSlices(u8, &before, &intact.shard.canonicalStateDigest());
    var encoded: [canonical_codec.max_encoded_len]u8 = undefined;
    const valid = try canonical_codec.encode(&encoded, event);
    std.mem.writeInt(u16, encoded[0..2], canonical_codec.encoding_version - 1, .little);
    try std.testing.expectError(error.UnsupportedCanonicalEncoding, canonical_codec.decode(encoded[0..valid.len]));
    var old = event;
    old.envelope.schema_version = canonical.schema_version - 1;
    try std.testing.expectError(error.InvalidCanonicalEnvelope, canonical_codec.encode(&encoded, old));
    try std.testing.expectError(error.UnsupportedSchema, owner.shard.apply(.{ .venue = old }));
    var reader = try @import("journal.zig").Reader.init(owner.decision_journal.bytes());
    const first = try reader.next();
    try std.testing.expect(first == .record);
    var old_record = first.record;
    old_record.schema_version = contract.previous_journal_schema_version;
    try std.testing.expectError(error.UnsupportedSchema, trading.decodeStableInput(old_record));
    const preserved = try store.recover(io, raw_stream);
    try std.testing.expectEqual(source.last_sequence, preserved.last_sequence);
    try std.testing.expectEqual(source.committed_barrier, preserved.committed_barrier);
    try std.testing.expectEqualSlices(u8, &source.segment_digest, &preserved.segment_digest);
    try std.testing.expectEqualSlices(u8, &before, &owner.shard.canonicalStateDigest());
}

const FileCase = struct {
    native: bool = false,
    fault_fact: bool = false,
    committed_prefix: u2 = 0,
    point: ?durable.FaultPoint = null,
    raw_point: ?durable.FaultPoint = null,
    recovery_point: ?durable.FaultPoint = null,
    snapshot_point: ?durable.FaultPoint = null,
    publish_snapshot: bool = false,
};

fn nativeFrame(frame: []const u8, native: bool, buffer: []u8) []const u8 {
    if (!native) return frame;
    const count = std.mem.replace(u8, frame, "\"25\"", "\"25000000\"", buffer);
    return buffer[0 .. frame.len + count * 6];
}

fn checkFileRecovery(io: std.Io, path: []const u8, case: FileCase) !void {
    const native = case.native;
    const economic_fault = case.fault_fact;
    const point = case.point;
    const committed_prefix = case.committed_prefix;
    const expected_fee: i128 = if (native) 4_198_632_165 else 10_000;
    const allocator = std.heap.page_allocator;
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const raw_stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 1 };
    const file_store = try allocator.create(durable.WindowsFileAdapter);
    defer allocator.destroy(file_store);
    @memset(std.mem.asBytes(file_store), 0);

    try file_store.initWindowsVerification(io, path);
    var file_open = true;
    defer if (file_open) file_store.close(io);
    const store = file_store.interface();
    var raw = try raw_ingress.DurableSink.init(store, io, .{ .domain = .raw_ingress, .id = 1 });
    var transport = Transport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = Clock{};
    var reconciler: private.Reconciler = .{};
    var implementation = okx.OkxVenueAdapter.init(allocator, &chain, clock.interface(), profile(), rules());
    implementation.attachPrivateReconciler(&reconciler);
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(store, io, stream);
    var definitions = @import("asset_registry.zig").testDefinitions(12, 9);
    definitions[0].max_single_atoms = 30_000_000_000_000_000_000;
    definitions[0].max_balance_atoms = 30_000_000_000_000_000_000;
    definitions[0].max_cumulative_atoms = 100_000_000_000_000_000_000;
    var parsed = try demo.Policy.parse(allocator,
        \\{"schema":3,"lot_size":{"coefficient":1,"scale":8},"price_tick_atoms":100000,"startup":"virgin","exchange_account":2,"portfolio_identity":1,"strategy_identity":40,"activation_identity":50,"config_version":1,"portfolio_allocation_atoms":20000000,"risk_limit_atoms":15000000,"decision_stream_id":91,"dispatch_stream_id":92,"decision_domain":1,"node_identity":1}
    );
    defer parsed.deinit();
    if (native) {
        parsed.value.asset_definitions = &definitions;
        parsed.value.native_settlement_atoms = true;
        parsed.value.price_tick_atoms = 100_000_000_000;
        parsed.value.portfolio_allocation_atoms = 20_000_000_000_000_000_000;
        parsed.value.risk_limit_atoms = 15_000_000_000_000_000_000;
    }
    if (native) {
        try parsed.value.activateAssetsForOfflineValidation(owner);
    } else try @import("venue_adapter_contract.zig").activateTestAssets(owner);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry, .native_settlement_atoms = native });
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
    for (subscriptions) |frame| {
        var buffer: [2048]u8 = undefined;
        try std.testing.expect((try implementation.ingestPrivateWs(private_times, nativeFrame(frame, native, &buffer))).rejection == null);
    }
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 1 } }));
    try std.testing.expect(try applyDrain(owner, adapter));
    try ingestBootstrapRound(&implementation, native);
    try std.testing.expect(!try applyDrain(owner, adapter));
    try ingestBootstrapRound(&implementation, native);
    try std.testing.expect(try applyDrain(owner, adapter));
    try std.testing.expect(owner.shard.canonical_account.valid);

    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try parsed.value.initialize(owner, if (native) 50_000_000_000_000 else 50_000_000, &guard, 1, 1);
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
    const intent_sequence = owner.shard.authoritativeBarrier() + 1;
    const intent: host.OrderIntent = .{ .strategy_identity = 40, .intent_sequence = intent_sequence, .strategy_cursor = owner.shard.authoritativeBarrier(), .config_version = 1, .activation_identity = 50, .portfolio_identity = 1, .exchange_account_identity = 2, .instrument_identity = okx.btc_usdt_spot, .side = .buy, .order_type = .limit, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = false, .quantity = 20_000, .limit_price_micros = 50_000_000 };
    const command = (try owner.apply(.{ .core = .{ .identity = intent_sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = intent } } })) orelse return error.MissingDemoCommand;
    try implementation.rememberRecoveredOrder(command.order_id, command.client_order_id, command.portfolio_reduce_only, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
    if (economic_fault) _ = try owner.apply(fixtureOnSecondaryStream(20, 4, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .unknown } }));
    const economic_before = owner.shard.economicSummary();
    const pending_before = owner.shard.oms.orderById(command.order_id).?;
    var frame: [2048]u8 = undefined;
    const input = try std.fmt.bufPrint(&frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"{s}","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0002","px":"{s}","accFillSz":"{s}","avgPx":"{s}","uTime":"1800000000100","tradeId":"2001","fillSz":"{s}","fillPx":"{s}","fillFee":"{s}","fillFeeCcy":"USDT","fillTime":"1800000000100","execType":"M"}}]}}
    , .{ command.client_order_id.slice(), if (!economic_fault) "filled" else "partially_filled", if (!economic_fault) "50" else "50000", if (!economic_fault) "0.0002" else "0.0001", if (!economic_fault) "50" else "50000", if (!economic_fault) "0.0002" else "0.0001", if (!economic_fault) "50" else "50000", if (!economic_fault) (if (native) "-0.004198632165" else "-0.01") else (if (native) "-0.0000000000001" else "-0.0000001") });
    if (case.raw_point) |raw_point| {
        try checkRawFailure(io, path, file_store, &raw, &implementation, owner, input, raw_point, &transport);
        file_open = false;
        return;
    }
    const ingress = try implementation.ingestPrivateWs(private_times, input);
    try std.testing.expect(ingress.rejection == null);
    const output = (try adapter.tryDrain()) orelse return error.MissingEconomicFault;
    const expected = try std.heap.page_allocator.create(@import("trading_shard.zig").TradingShard);
    defer std.heap.page_allocator.destroy(expected);
    @memcpy(std.mem.asBytes(expected), std.mem.asBytes(&owner.shard));
    for (output.slice()) |record| _ = try expected.apply(.{ .venue = record });
    if (!economic_fault) {
        try std.testing.expectEqual(@as(usize, 2), output.slice().len);
        try std.testing.expectEqual(expected_fee, output.events[1].event.fill.fee.?.atoms);
    } else {
        try std.testing.expectEqual(@as(usize, 1), output.slice().len);
        try std.testing.expectEqual(canonical.EconomicFaultReason.inexact_amount, output.events[0].event.economic_fault.reason);
    }
    for (output.slice()[0..committed_prefix]) |record| _ = try owner.apply(.{ .venue = record });
    const economic_prefix = owner.shard.economicSummary();
    const raw_before = try store.recover(io, raw_stream);
    try std.testing.expectEqual(ingress.raw_evidence.stream_sequence, raw_before.committed_barrier);
    const owner_digest = owner.shard.canonicalStateDigest();
    if (native) try checkNativeSchemaRejection(owner, store, io, raw_stream, output.events[0]);
    var fault_vtable = store.vtable.*;
    if (point != null) {
        if (point == .append) {
            file_store.injectFault(.eio);
        } else {
            fault_vtable.commit = failCommit;
            owner.store = .{ .context = file_store, .vtable = &fault_vtable };
        }
        try std.testing.expectError(error.DecisionLogUnavailable, owner.applyAdapterBatch(output));
        try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
    }
    if (case.snapshot_point != null or case.publish_snapshot) {
        const storage = try std.heap.page_allocator.alloc(u8, durable.max_snapshot_bytes);
        defer std.heap.page_allocator.free(storage);
        const snapshot = try owner.committedSnapshot(storage);
        if (case.snapshot_point == .seal) {
            file_store.injectFault(.eio);
            try std.testing.expectError(error.InputOutput, store.seal(io, stream));
        } else {
            try store.seal(io, stream);
            if (case.snapshot_point == .publish) {
                file_store.injectFault(.eio);
                try std.testing.expectError(error.InputOutput, store.publishSnapshot(io, stream, owner.shard.authoritativeBarrier(), snapshot));
            } else {
                try store.publishSnapshot(io, stream, owner.shard.authoritativeBarrier(), snapshot);
                try store.rotate(io, stream);
            }
        }
        if (case.snapshot_point != null) try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
    }
    try std.testing.expectEqualDeep(economic_prefix, owner.shard.economicSummary());
    try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
    file_store.close(io);
    file_open = false;

    const reopened = try allocator.create(durable.WindowsFileAdapter);
    defer allocator.destroy(reopened);
    @memset(std.mem.asBytes(reopened), 0);

    try reopened.initWindowsVerification(io, path);
    var reopened_open = true;
    defer if (reopened_open) reopened.close(io);
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    if (point != .commit) {
        try demo.Owner.recoverWithIngressInto(recovered, reopened.interface(), io, stream, raw_stream);
        try std.testing.expectEqualSlices(u8, &owner_digest, &recovered.shard.canonicalStateDigest());
        try std.testing.expectEqualDeep(economic_prefix, recovered.shard.economicSummary());
        try std.testing.expectEqual(@as(i64, if (committed_prefix == 2) 20_000 else 0), try recovered.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
        // Recovery of a healthy decision prefix grants no dispatch authority
        // while its committed private ingress still contains an unapplied fault.
        const gateway = try std.heap.page_allocator.create(@import("execution_gateway.zig").Gateway);
        defer std.heap.page_allocator.destroy(gateway);
        gateway.init();
        try std.testing.expectError(error.DecisionLogUnavailable, recovered.send(gateway, &guard, command.command_id, 1));
        try std.testing.expect((try recovered.source()).recovery_admission_pending);
        const snapshot_buffer = try std.heap.page_allocator.alloc(u8, durable.max_snapshot_bytes);
        defer std.heap.page_allocator.free(snapshot_buffer);
        const pending_snapshot = try recovered.committedSnapshot(snapshot_buffer);
        const pending_copy = try std.heap.page_allocator.create(@import("trading_shard.zig").SnapshotRestore);
        defer std.heap.page_allocator.destroy(pending_copy);
        pending_copy.barrier = try @import("trading_shard.zig").TradingShard.restoreSnapshotInto(&pending_copy.shard, pending_snapshot);
        try std.testing.expect(pending_copy.shard.recovery_admission_pending);
        try std.testing.expectEqual(@as(usize, 0), transport.sends);
    } else {
        const rejected_owner = try std.heap.page_allocator.create(demo.Owner);
        defer std.heap.page_allocator.destroy(rejected_owner);
        try demo.Owner.recoverInto(rejected_owner, reopened.interface(), io, stream);
        try std.testing.expect(rejected_owner.closed and rejected_owner.shard.recovery_admission_pending);
        try std.testing.expectError(error.DecisionLogUnavailable, rejected_owner.source());
        try std.testing.expectEqualSlices(u8, &owner_digest, &rejected_owner.shard.canonicalStateDigest());
        const uncommitted = try reopened.interface().recover(io, stream);
        try std.testing.expect(uncommitted.last_sequence > uncommitted.committed_barrier);
    }
    var replay_raw = try raw_ingress.DurableSink.recover(reopened.interface(), io, raw_stream);
    var replay_chain: live.Chain = .{ .mode = .replay, .qualification = qualification(), .raw_sink = replay_raw.interface(), .transport = transport.interface() };
    var replay_reconciler: private.Reconciler = .{};
    var replay_adapter = okx.OkxVenueAdapter.init(allocator, &replay_chain, clock.interface(), profile(), rules());
    var committed = if (!economic_fault and point != .commit) try recovery.CommittedInputs.init(reopened.interface(), io, stream) else recovery.CommittedInputs{};
    replay_adapter.attachPrivateReconciler(&replay_reconciler);
    const replay_venue = replay_adapter.adapter();
    try replay_venue.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = if (point == .commit) owner.shard.activatedAssets() else recovered.shard.activatedAssets(), .instrument_definitions = if (point == .commit) owner.shard.instrument_registry else recovered.shard.instrument_registry, .native_settlement_atoms = native });
    try replay_adapter.beginPrivateSession();
    try replay_adapter.rememberRecoveredOrder(command.order_id, command.client_order_id, command.portfolio_reduce_only, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
    const Replay = struct {
        implementation: *okx.OkxVenueAdapter,
        owner: ?*demo.Owner,
        pending_sequence: u64,
        pending_digest: [32]u8,
        started: bool = false,
        pending_batches: usize = 0,
        apply_pending: bool,
        healthy: bool,
        expected_fee: i128,
        fn consume(ptr: *anyopaque, sequence: u64, record: @import("okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const times: private.Times = .{ .receive_time_utc_ns = record.receive_time_utc_ns, .monotonic_time_ns = record.monotonic_time_ns, .wall_time_utc_ns = record.wall_time_utc_ns };
            const evidence: private.RawEvidenceRef = .{ .stream_sequence = sequence, .sha256 = record.sha256 };
            const replay = self.implementation.adapter();
            if (record.origin == 0) {
                try std.testing.expect((try self.implementation.replayPrivateWs(times, evidence, bytes)).rejection == null);
                if (sequence == self.pending_sequence) {
                    const batch = (try replay.tryDrain()) orelse return error.MissingRecoveredFault;
                    if (self.healthy) {
                        try std.testing.expectEqual(@as(usize, 2), batch.slice().len);
                        try std.testing.expectEqual(@as(i128, 20_000), batch.events[1].event.fill.quantity.lots);
                        try std.testing.expectEqual(okx.usdt, batch.events[1].event.fill.fee.?.asset);
                        try std.testing.expectEqual(self.expected_fee, batch.events[1].event.fill.fee.?.atoms);
                    } else {
                        try std.testing.expectEqual(@as(usize, 1), batch.slice().len);
                        try std.testing.expectEqual(canonical.EconomicFaultReason.inexact_amount, batch.events[0].event.economic_fault.reason);
                    }
                    try std.testing.expectEqual(sequence, batch.events[0].envelope.raw_evidence.sequence);
                    try std.testing.expectEqualSlices(u8, &self.pending_digest, &batch.events[0].envelope.raw_evidence.digest);
                    if (self.apply_pending) try self.owner.?.applyAdapterBatch(batch);
                    self.pending_batches += 1;
                }
            } else {
                if (!self.started) {
                    try std.testing.expectEqual(venue.SendResult.accepted, try replay.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 1 } }));
                    _ = try replay.tryDrain();
                    self.started = true;
                }
                const source: private.IngressSource = @enumFromInt(record.origin - 1);
                try std.testing.expect((try self.implementation.replayPrivateRest(times, source, .{ .final = true }, evidence, bytes)).rejection == null);
                // Match the original bootstrap's drain boundaries. Earlier
                // canonical facts already belong to the committed Owner prefix.
                if (source == .rest_fills_history_swap) _ = try replay.tryDrain();
            }
        }
    };
    var replay: Replay = .{ .implementation = &replay_adapter, .owner = if (point != .commit) recovered else null, .pending_sequence = ingress.raw_evidence.stream_sequence, .pending_digest = ingress.raw_evidence.sha256, .apply_pending = point != .commit, .healthy = !economic_fault, .expected_fee = expected_fee };
    if (!economic_fault and point != .commit) {
        var sweep: recovery.Sweep = .{ .implementation = &replay_adapter, .owner = recovered, .index = &committed, .reconciliation_identity = 99, .last_sequence = raw_before.committed_barrier };
        if (case.recovery_point) |recovery_point| {
            var retry_vtable = reopened.interface().vtable.*;
            if (recovery_point == .append) reopened.injectFault(.eio) else {
                retry_vtable.commit = failCommit;
                recovered.store = .{ .context = reopened, .vtable = &retry_vtable };
            }
            try std.testing.expectError(error.DecisionLogUnavailable, recovered.replayCommittedIngress(raw_stream, sweep.consumer()));
            try std.testing.expectEqualDeep(economic_prefix, recovered.shard.economicSummary());
            try std.testing.expect(recovered.closed and recovered.shard.recovery_admission_pending);
            const pending_raw = try reopened.interface().recover(io, raw_stream);
            try std.testing.expectEqual(raw_before.last_sequence, pending_raw.last_sequence);
            try std.testing.expectEqual(raw_before.committed_barrier, pending_raw.committed_barrier);
            reopened.close(io);
            reopened_open = false;
            const twice = try allocator.create(durable.WindowsFileAdapter);
            defer allocator.destroy(twice);
            @memset(std.mem.asBytes(twice), 0);
            try twice.initWindowsVerification(io, path);
            defer twice.close(io);
            const twice_owner = try allocator.create(demo.Owner);
            defer allocator.destroy(twice_owner);
            if (recovery_point == .commit) {
                const rejected_owner = try std.heap.page_allocator.create(demo.Owner);
                defer std.heap.page_allocator.destroy(rejected_owner);
                try demo.Owner.recoverInto(rejected_owner, twice.interface(), io, stream);
                try std.testing.expect(rejected_owner.closed and rejected_owner.shard.recovery_admission_pending);
                try std.testing.expectError(error.DecisionLogUnavailable, rejected_owner.source());
                try std.testing.expectEqualSlices(u8, &owner_digest, &rejected_owner.shard.canonicalStateDigest());
                const unfinished = try twice.interface().recover(io, stream);
                try std.testing.expect(unfinished.last_sequence > unfinished.committed_barrier);
            } else {
                try demo.Owner.recoverWithIngressInto(twice_owner, twice.interface(), io, stream, raw_stream);
                try std.testing.expectEqualSlices(u8, &owner_digest, &twice_owner.shard.canonicalStateDigest());
                try std.testing.expectEqualDeep(economic_prefix, twice_owner.shard.economicSummary());
                try std.testing.expect(twice_owner.shard.recovery_admission_pending);
                const denied_gateway = try std.heap.page_allocator.create(@import("execution_gateway.zig").Gateway);
                defer std.heap.page_allocator.destroy(denied_gateway);
                denied_gateway.init();
                try std.testing.expectError(error.DecisionLogUnavailable, twice_owner.send(denied_gateway, &guard, command.command_id, 1));
            }
            const retained = try twice.interface().recover(io, raw_stream);
            try std.testing.expectEqual(raw_before.last_sequence, retained.last_sequence);
            try std.testing.expectEqual(raw_before.committed_barrier, retained.committed_barrier);
            try std.testing.expectEqual(@as(usize, 0), transport.sends);
            return;
        }
        try recovered.replayCommittedIngress(raw_stream, sweep.consumer());
    } else if (point != .commit)
        try recovered.replayCommittedIngress(raw_stream, .{ .ptr = &replay, .consume_fn = Replay.consume })
    else
        try raw_ingress.replayCommitted(reopened.interface(), io, raw_stream, .{ .ptr = &replay, .consume_fn = Replay.consume });
    if (economic_fault or point == .commit) try std.testing.expectEqual(@as(usize, 1), replay.pending_batches);
    if (!economic_fault and point != .commit) {
        try std.testing.expectEqualSlices(u8, &expected.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        try std.testing.expectEqual(recovered.checkpoint_pending, recovered.shard.recovery_admission_pending);
        try std.testing.expect(!recovered.shard.oms.recovery_only);
        try std.testing.expectEqual(@as(u64, 0), recovered.shard.economic_fault_count);
        try std.testing.expect(recovered.shard.operational_state.effectiveTradingAuthority());
        try std.testing.expectEqual(@as(i64, 20_000), try recovered.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
        try std.testing.expectEqual(expected_fee, recovered.shard.economicSummary().portfolio.fee_atoms);
        try std.testing.expectEqual(expected_fee, recovered.shard.economicSummary().exchange.fee_atoms);
        if (native) {
            try std.testing.expectEqual(@as(i128, 200_000), recovered.shard.economicSummary().portfolio.spot_asset_atoms);
            try std.testing.expectEqual(@as(i128, 19_999_999_985_801_367_835), recovered.shard.economicSummary().portfolio.usdt_balance_atoms);
            try std.testing.expectEqual(@as(i128, 24_999_999_985_801_367_835), recovered.shard.economicSummary().exchange.usdt_balance_atoms);
            try std.testing.expectEqualDeep(owner.shard.activatedAssets(), recovered.shard.activatedAssets());
        }
        try std.testing.expectEqual(@import("oms.zig").OrderState.filled, recovered.shard.oms.orderById(command.order_id).?.state);
        var next_intent = intent;
        next_intent.intent_sequence = recovered.shard.authoritativeBarrier() + 1;
        next_intent.strategy_cursor = recovered.shard.authoritativeBarrier();
        next_intent.quantity = 1_000;
        var next_input: @import("trading_shard.zig").CanonicalEvent = .{ .core = .{ .identity = next_intent.intent_sequence, .monotonic_time = 3, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = next_intent } } };
        if (case.snapshot_point == .publish) {
            // A sealed tail without its new published snapshot is read-only;
            // this test must not invent truncation or silently repair rotation.
            try std.testing.expectError(error.DecisionLogUnavailable, recovered.apply(next_input));
            try std.testing.expect(recovered.checkpoint_pending);
            try std.testing.expect((try recovered.source()).recovery_admission_pending);
            const pending_gateway = try std.heap.page_allocator.create(@import("execution_gateway.zig").Gateway);
            defer std.heap.page_allocator.destroy(pending_gateway);
            pending_gateway.init();
            try std.testing.expectError(error.DecisionLogUnavailable, recovered.send(pending_gateway, &guard, command.command_id, 3));
        }
        if (recovered.checkpoint_pending) try recovered.checkpoint();
        try std.testing.expect(!recovered.shard.recovery_admission_pending);
        next_input.core.identity = recovered.shard.authoritativeBarrier() + 1;
        next_input.core.payload.external_order_intent.intent_sequence = next_input.core.identity;
        next_input.core.payload.external_order_intent.strategy_cursor = recovered.shard.authoritativeBarrier();
        const next_command = (try recovered.apply(next_input)) orelse return error.MissingHealthyRecoveryCommand;
        try std.testing.expect(next_command.command_id != command.command_id);
        try std.testing.expectEqual(@as(i64, 1_000), next_command.quantity);
        try std.testing.expectEqual(@as(u64, 1), replay_chain.next_attempt_id);
        try std.testing.expectEqual(@as(usize, 0), transport.sends);
        const healthy_digest = recovered.shard.canonicalStateDigest();
        reopened.close(io);
        reopened_open = false;
        const healthy_store = try allocator.create(durable.WindowsFileAdapter);
        defer allocator.destroy(healthy_store);
        @memset(std.mem.asBytes(healthy_store), 0);

        try healthy_store.initWindowsVerification(io, path);
        defer healthy_store.close(io);
        const healthy_owner = try allocator.create(demo.Owner);
        defer allocator.destroy(healthy_owner);
        try demo.Owner.recoverWithIngressInto(healthy_owner, healthy_store.interface(), io, stream, raw_stream);
        try std.testing.expect(healthy_owner.shard.recovery_admission_pending);
        try std.testing.expectEqualSlices(u8, &healthy_digest, &healthy_owner.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(i64, 20_000), try healthy_owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
        try std.testing.expectEqual(expected_fee, healthy_owner.shard.economicSummary().portfolio.fee_atoms);
        try std.testing.expect(!healthy_owner.shard.oms.recovery_only);
        try std.testing.expectEqual(@as(u64, 0), healthy_owner.shard.economic_fault_count);
        var verified_index = try recovery.CommittedInputs.init(healthy_store.interface(), io, stream);
        try std.testing.expect(try verified_index.contains(output.events[1]));
        var conflicting = output.events[1];
        conflicting.event.fill.fee.?.atoms += 1;
        try std.testing.expectError(error.ConflictingRecoveredPrivateFact, verified_index.contains(conflicting));
        conflicting = output.events[1];
        conflicting.envelope.raw_evidence.digest[0] ^= 1;
        try std.testing.expectError(error.ConflictingRecoveredPrivateFact, verified_index.contains(conflicting));
        try std.testing.expectError(error.PrivateRecoveryHistoryUnavailable, recovery.CommittedInputs.init(healthy_store.interface(), io, .{ .domain = .raw_ingress, .id = 1 }));
        const before_repeat = healthy_owner.shard.canonicalStateDigest();
        var duplicate_index = try recovery.CommittedInputs.init(healthy_store.interface(), io, stream);
        var duplicate_raw = try raw_ingress.DurableSink.recover(healthy_store.interface(), io, raw_stream);
        var duplicate_chain: live.Chain = .{ .mode = .replay, .qualification = qualification(), .raw_sink = duplicate_raw.interface(), .transport = transport.interface() };
        var duplicate_reconciler: private.Reconciler = .{};
        var duplicate_adapter = okx.OkxVenueAdapter.init(allocator, &duplicate_chain, clock.interface(), profile(), rules());
        duplicate_adapter.attachPrivateReconciler(&duplicate_reconciler);
        try duplicate_adapter.adapter().start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = healthy_owner.shard.activatedAssets(), .instrument_definitions = healthy_owner.shard.instrument_registry, .native_settlement_atoms = native });
        try duplicate_adapter.beginPrivateSession();
        try duplicate_adapter.rememberRecoveredOrder(command.order_id, command.client_order_id, command.portfolio_reduce_only, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
        var duplicate_sweep: recovery.Sweep = .{ .implementation = &duplicate_adapter, .owner = healthy_owner, .index = &duplicate_index, .reconciliation_identity = 99, .last_sequence = raw_before.committed_barrier };
        try healthy_owner.replayCommittedIngress(raw_stream, duplicate_sweep.consumer());
        try std.testing.expectEqualSlices(u8, &before_repeat, &healthy_owner.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(i64, 20_000), try healthy_owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
        try std.testing.expectEqual(expected_fee, healthy_owner.shard.economicSummary().portfolio.fee_atoms);
        // Interrupt a fresh reconciliation after one committed REST frame.
        // Consuming every raw byte is insufficient when facts remain buffered.
        try std.testing.expectEqual(venue.SendResult.accepted, try duplicate_adapter.adapter().trySend(.{ .account_reconciliation = .{ .identity = 100, .exchange_account = 2, .expected_session = 1 } }));
        _ = try duplicate_adapter.adapter().tryDrain();
        _ = try duplicate_adapter.ingestPrivateRest(private_times, .rest_account_config, .{ .final = true },
            \\{"code":"0","data":[{"acctLv":"2","posMode":"net_mode","ctIsoMode":"automatic","autoLoan":false,"enableSpotBorrow":false,"perm":"read_only,trade"}]}
        );
        _ = try duplicate_adapter.adapter().tryDrain();
        const incomplete_owner = try allocator.create(demo.Owner);
        defer allocator.destroy(incomplete_owner);
        try demo.Owner.recoverWithIngressInto(incomplete_owner, healthy_store.interface(), io, stream, raw_stream);
        var incomplete_index = try recovery.CommittedInputs.init(healthy_store.interface(), io, stream);
        var incomplete_reconciler: private.Reconciler = .{};
        var incomplete_adapter = okx.OkxVenueAdapter.init(allocator, &duplicate_chain, clock.interface(), profile(), rules());
        incomplete_adapter.attachPrivateReconciler(&incomplete_reconciler);
        try incomplete_adapter.adapter().start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 4, .output_capacity = 4, .asset_definitions = incomplete_owner.shard.activatedAssets(), .instrument_definitions = incomplete_owner.shard.instrument_registry, .native_settlement_atoms = native });
        try incomplete_adapter.beginPrivateSession();
        try incomplete_adapter.rememberRecoveredOrder(command.order_id, command.client_order_id, command.portfolio_reduce_only, .{ .instrument = command.instrument, .rules_version = command.limit_price.rules_version, .lots = command.quantity }, command.revision);
        const incomplete_raw = try healthy_store.interface().recover(io, raw_stream);
        var incomplete_sweep: recovery.Sweep = .{ .implementation = &incomplete_adapter, .owner = incomplete_owner, .index = &incomplete_index, .reconciliation_identity = 99, .last_sequence = incomplete_raw.committed_barrier };
        try std.testing.expectError(error.IncompletePrivateRecovery, incomplete_owner.replayCommittedIngress(raw_stream, incomplete_sweep.consumer()));
        try std.testing.expect(incomplete_owner.shard.recovery_admission_pending);
        const incomplete_gateway = try std.heap.page_allocator.create(@import("execution_gateway.zig").Gateway);
        defer std.heap.page_allocator.destroy(incomplete_gateway);
        incomplete_gateway.init();
        try std.testing.expectError(error.DecisionLogUnavailable, incomplete_owner.send(incomplete_gateway, &guard, command.command_id, 1));
        try std.testing.expectEqual(@as(i64, 20_000), try incomplete_owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
        try std.testing.expectEqual(expected_fee, incomplete_owner.shard.economicSummary().portfolio.fee_atoms);
        try std.testing.expectEqual(@as(usize, 0), transport.sends);
        return;
    }
    if (economic_fault) for ([_]venue.VenueAdapter{ adapter, replay_venue }) |closed_adapter|
        try std.testing.expectEqual(venue.SendResult.backpressure, try closed_adapter.trySend(.{ .order_command = .{
            .identity = 999,
            .instrument = command.instrument,
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
    try std.testing.expectEqual(@as(usize, 0), transport.sends);
    if (point == .commit) {
        // Recovery retains the committed state behind a quarantine fence.
        // RawIngress remains evidence; the physical tail is never promoted or sent.
        try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
        const preserved_raw = try reopened.interface().recover(io, raw_stream);
        try std.testing.expectEqual(raw_before.committed_barrier, preserved_raw.committed_barrier);
        try std.testing.expectEqual(raw_before.last_sequence, preserved_raw.last_sequence);
        try std.testing.expectEqual(@as(u64, 1), replay_chain.next_attempt_id);
        try std.testing.expectEqual(@as(usize, 0), transport.sends);
        reopened.close(io);
        reopened_open = false;
        const closed_again = try allocator.create(durable.WindowsFileAdapter);
        defer allocator.destroy(closed_again);
        @memset(std.mem.asBytes(closed_again), 0);

        try closed_again.initWindowsVerification(io, path);
        defer closed_again.close(io);
        const rejected_owner = try std.heap.page_allocator.create(demo.Owner);
        defer std.heap.page_allocator.destroy(rejected_owner);
        try demo.Owner.recoverInto(rejected_owner, closed_again.interface(), io, stream);
        try std.testing.expect(rejected_owner.closed and rejected_owner.shard.recovery_admission_pending);
        try std.testing.expectError(error.DecisionLogUnavailable, rejected_owner.source());
        try std.testing.expectEqualSlices(u8, &owner_digest, &rejected_owner.shard.canonicalStateDigest());
        return;
    }
    try std.testing.expect(recovered.shard.oms.recovery_only);
    try std.testing.expect(!recovered.shard.recovery_admission_pending);
    try std.testing.expect(!recovered.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectEqual(canonical.EconomicFaultReason.inexact_amount, recovered.shard.economic_fault_reason);
    try std.testing.expectEqualDeep(economic_before, recovered.shard.economicSummary());
    try std.testing.expectEqual(@as(i64, 0), try recovered.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    try std.testing.expect(recovered.shard.oms.orderById(command.order_id).?.reservation_active);
    try std.testing.expect(recovered.shard.oms.blocksNewSend());
    try std.testing.expectEqualDeep(pending_before.reservation, recovered.shard.oms.orderById(command.order_id).?.reservation);
    const raw_after = try reopened.interface().recover(io, raw_stream);
    try std.testing.expectEqual(raw_before.committed_barrier, raw_after.committed_barrier);
    try std.testing.expectEqual(raw_before.last_sequence, raw_after.last_sequence);
    try std.testing.expectEqual(@as(u64, 1), replay_chain.next_attempt_id);
    try std.testing.expectEqual(@as(usize, 0), transport.sends);
    const fault_digest = recovered.shard.canonicalStateDigest();
    reopened.close(io);
    reopened_open = false;

    const final_store = try allocator.create(durable.WindowsFileAdapter);
    defer allocator.destroy(final_store);
    @memset(std.mem.asBytes(final_store), 0);

    try final_store.initWindowsVerification(io, path);
    defer final_store.close(io);
    const final_owner = try allocator.create(demo.Owner);
    defer allocator.destroy(final_owner);
    try demo.Owner.recoverInto(final_owner, final_store.interface(), io, stream);
    try std.testing.expect(final_owner.shard.recovery_admission_pending);
    try std.testing.expectEqualSlices(u8, &fault_digest, &final_owner.shard.canonicalStateDigest());
    try std.testing.expect(final_owner.shard.oms.recovery_only);
    try std.testing.expect(!final_owner.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectEqualDeep(economic_before, final_owner.shard.economicSummary());
    try std.testing.expect(final_owner.shard.oms.blocksNewSend());
    try std.testing.expectEqualDeep(pending_before.reservation, final_owner.shard.oms.orderById(command.order_id).?.reservation);
    try std.testing.expectEqual(@as(usize, 0), transport.sends);
}

test "Windows file reopen recovers or closes an uncommitted OKX economic fault without sends" {
    if (builtin.os.tag != .windows) return;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var path_buffer: [260]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "C:\\Windows\\Temp\\ringwin-economic-fault-{d}", .{std.Io.Clock.real.now(io).nanoseconds});
    try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    for ([_]?durable.FaultPoint{ .append, .commit, null }) |point| {
        var case_buffer: [280]u8 = undefined;
        const case_path = try std.fmt.bufPrint(&case_buffer, "{s}\\{s}", .{ path, if (point) |fault| @tagName(fault) else "healthy" });
        try checkFileRecovery(io, case_path, .{ .point = point, .fault_fact = point != null });
    }
}

test "Windows retained committed input recovery skips a same frame report and applies only the missing Fill" {
    if (builtin.os.tag != .windows) return;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var path_buffer: [260]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "C:\\Windows\\Temp\\ringwin-private-inputs-{d}", .{std.Io.Clock.real.now(io).nanoseconds});
    try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    for ([_]u2{ 1, 2 }) |prefix| {
        var case_buffer: [280]u8 = undefined;
        const case_path = try std.fmt.bufPrint(&case_buffer, "{s}\\{d}", .{ path, prefix });
        try checkFileRecovery(io, case_path, .{ .committed_prefix = prefix });
    }
}

test "Windows native file recovery preserves wide atoms partial facts faults and second reopen" {
    if (builtin.os.tag != .windows) return;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var path_buffer: [260]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "C:\\Windows\\Temp\\ringwin-native-crash-{d}", .{std.Io.Clock.real.now(io).nanoseconds});
    try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const cases = [_]FileCase{
        .{ .native = true, .raw_point = .append },
        .{ .native = true, .raw_point = .commit },
        .{ .native = true, .committed_prefix = 0 },
        .{ .native = true, .committed_prefix = 1 },
        .{ .native = true, .committed_prefix = 1, .recovery_point = .append },
        .{ .native = true, .committed_prefix = 1, .recovery_point = .commit },
        .{ .native = true, .committed_prefix = 2 },
        .{ .native = true, .committed_prefix = 2, .snapshot_point = .seal },
        .{ .native = true, .committed_prefix = 2, .snapshot_point = .publish },
        .{ .native = true, .committed_prefix = 2, .publish_snapshot = true },
        .{ .native = true, .fault_fact = true, .point = .append },
        .{ .native = true, .fault_fact = true, .point = .commit },
        .{ .native = true, .point = .append },
        .{ .native = true, .point = .commit },
        .{ .native = true, .point = .append, .committed_prefix = 1 },
        .{ .native = true, .point = .commit, .committed_prefix = 1 },
        .{ .native = true, .fault_fact = true },
        .{ .native = true, .fault_fact = true, .committed_prefix = 1 },
    };
    for (cases, 0..) |case, index| {
        var case_buffer: [280]u8 = undefined;
        const case_path = try std.fmt.bufPrint(&case_buffer, "{s}\\{d}", .{ path, index });
        try checkFileRecovery(io, case_path, case);
    }
}
