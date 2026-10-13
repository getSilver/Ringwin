//! Offline native-account facts through real Adapters, Owner and durable recovery.
const std = @import("std");
const canonical = @import("canonical_event.zig");
const durable = @import("durable_store.zig");
const demo = @import("demo_authority.zig");
const trading = @import("trading_shard.zig");
const binance = @import("binance_venue_adapter.zig");
const bybit = @import("bybit_venue_adapter.zig");
const raw_ingress = @import("raw_ingress.zig");
const Kind = enum { binance, bybit };

// These two private protocols expose distinct raw sink types with the same metadata.
fn rawSink(comptime Private: type, sink: *raw_ingress.DurableSink) Private.RawSink {
    return .{ .ptr = sink, .append_fn = struct {
        fn append(ptr: *anyopaque, record: Private.RawIngressRecord, bytes: []const u8) Private.RawSinkError!u64 {
            const target: *raw_ingress.DurableSink = @ptrCast(@alignCast(ptr));
            const evidence = try target.interface().append(.{ .source_session = record.source_session, .receive_time_utc_ns = record.receive_time_utc_ns, .monotonic_time_ns = record.monotonic_time_ns, .wall_time_utc_ns = record.wall_time_utc_ns, .byte_len = record.byte_len, .sha256 = record.sha256 }, bytes);
            return evidence.stream_sequence;
        }
    }.append };
}

fn exercise(comptime kind: Kind) !void {
    const Implementation = if (kind == .binance) binance.BinanceVenueAdapter else bybit.BybitVenueAdapter;
    const Private = if (kind == .binance) @import("binance_private_reconciliation.zig") else @import("bybit_private_reconciliation.zig");
    const Raw = if (kind == .binance) @import("binance_order_raw.zig") else Private;
    const AdapterModule = if (kind == .binance) binance else bybit;
    const venue_id: u64 = if (kind == .binance) 21 else 42;
    const TestIo = struct {
        calls: u64 = 0,
        fn now(_: *anyopaque) u64 {
            return 1;
        }
        fn sign(_: *anyopaque, _: u64, _: []const u8) ![32]u8 {
            return @splat(1);
        }
        fn submit(ptr: *anyopaque, _: AdapterModule.SignedRequest) AdapterModule.TransportResult {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return .{ .outcome = .proven_before_send, .source_session = 6, .times = .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 2, .wall_time_utc_ns = 3 } };
        }
    };
    const gpa = std.heap.page_allocator;
    const memory = try gpa.create(durable.MemoryAdapter);
    defer gpa.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = venue_id };
    var raw = try raw_ingress.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = venue_id });
    const owner = try gpa.create(demo.Owner);
    defer gpa.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    try @import("venue_adapter_contract.zig").activateTestAssets(owner);
    const profile: AdapterModule.CapabilityProfile = .{
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .session = 6,
        .spot = .{ .identity = Private.btc_usdt_spot, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } },
        .linear = .{ .identity = Private.btc_usdt_linear, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } },
    };
    for ([_]canonical.InstrumentIdentity{ Private.btc_usdt_spot, Private.btc_usdt_linear }, 0..) |instrument, index| {
        _ = try owner.apply(.{ .core = .{ .identity = 10 + index * 2, .payload = .{ .instrument_rules_activated = .{
            .version = 1,
            .instrument_identity = instrument,
            .quantity_denominator = 10_000,
            .reservation_model = if (index == 0) .cash else .leveraged,
            .product = if (index == 0) .spot else .isolated_linear_usdt,
            .venue = venue_id,
            .settlement_asset = 1,
            .base_asset = if (index == 0) Private.btc else 0,
        } } } });
        _ = try owner.apply(.{ .core = .{ .identity = 11 + index * 2, .payload = .{ .margin_rules_activated = .{ .version = 1, .instrument = instrument, .price_tick_atoms = 100_000, .native_settlement_atoms = true } } } });
    }
    _ = try owner.apply(.{ .core = .{ .identity = 20, .payload = .{ .account_configuration = .{ .exchange_account_identity = 2 } } } });
    var io = TestIo{};
    const reconciler = try gpa.create(Private.Reconciler);
    defer gpa.destroy(reconciler);
    reconciler.* = Private.Reconciler.init(rawSink(Raw, &raw), .{
        .spot = .{ .identity = profile.spot.identity, .rules_version = 1, .tick_size = profile.spot.tick_size, .lot_size = profile.spot.lot_size },
        .linear = .{ .identity = profile.linear.identity, .rules_version = 1, .tick_size = profile.linear.tick_size, .lot_size = profile.linear.lot_size },
    });
    var implementation = Implementation.init(.{ .ptr = &io, .now_fn = TestIo.now }, profile, .{ .ptr = &io, .sign_fn = TestIo.sign }, rawSink(Raw, &raw), .{ .ptr = &io, .submit_fn = TestIo.submit });
    implementation.attachPrivateReconciler(reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = venue_id, .environment = .demo, .exchange_account = 2, .adapter_session = 6, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry, .native_settlement_atoms = true });
    try implementation.beginPrivateReconciliation();
    const times: Raw.Times = .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 2, .wall_time_utc_ns = 3 };
    if (kind == .binance) {
        _ = try implementation.ingestPrivate(gpa, .rest_linear_account, .{ .final = true }, times,
            \\{"multiAssetsMargin":false,"assets":[{"asset":"USDT","walletBalance":"20","availableBalance":"15"},{"asset":"BTC","walletBalance":"0.1","availableBalance":"0.09"}],"positions":[],"totalWalletBalance":"20","totalMarginBalance":"20","totalInitialMargin":"0","totalMaintMargin":"0"}
        );
        _ = try implementation.ingestPrivate(gpa, .rest_orders, .{ .final = true }, times, "[]");
        _ = try implementation.ingestPrivate(gpa, .rest_fills, .{ .final = true }, times, "[]");
    } else {
        // Current UNIFIED wallet cannot prove native availability/product scope.
        const before = owner.shard.economicSummary();
        try owner.sealBootstrap();
        try std.testing.expectError(error.UnsupportedWalletScope, implementation.ingestPrivate(gpa, .rest_wallet, .{ .final = true }, times,
            \\{"result":{"list":[{"accountType":"UNIFIED","coin":[{"coin":"USDT","walletBalance":"20","spotBorrow":"0","borrowAmount":"0","locked":"5"}]}]}}
        ));
        while (try adapter.tryDrain()) |batch| try owner.applyAdapterBatch(batch);
        try std.testing.expectEqualDeep(before, owner.shard.economicSummary());
        try std.testing.expectEqual(@as(u8, 0), owner.shard.canonical_account.balance_count);
        try std.testing.expectEqual(@as(u64, 1), owner.shard.economic_fault_count);
        try std.testing.expect(owner.shard.oms.recovery_only);
        const digest = owner.shard.canonicalStateDigest();
        const recovered = try gpa.create(demo.Owner);
        defer gpa.destroy(recovered);
        try demo.Owner.recoverInto(recovered, memory.interface(), undefined, stream);
        try std.testing.expectEqualSlices(u8, &digest, &recovered.shard.canonicalStateDigest());
        const bytes = try gpa.alloc(u8, durable.max_snapshot_bytes);
        defer gpa.free(bytes);
        const restored = try gpa.create(trading.TradingShard);
        defer gpa.destroy(restored);
        _ = try trading.TradingShard.restoreSnapshotInto(restored, try owner.committedSnapshot(bytes));
        try std.testing.expectEqualSlices(u8, &digest, &restored.canonicalStateDigest());
        try std.testing.expectEqual(@as(u64, 0), io.calls);
        return;
    }
    const bootstrap = (try adapter.tryDrain()).?;
    try owner.applyAdapterBatch(bootstrap);
    try std.testing.expect(owner.shard.canonical_account.valid);
    const economic_before = owner.shard.economicSummary();
    try owner.sealBootstrap();
    if (kind == .binance) {
        _ = try implementation.ingestPrivate(gpa, .ws, null, times,
            \\{"e":"ACCOUNT_UPDATE","a":{"B":[{"a":"USDT","wb":"21.000001","cw":"16.000001"},{"a":"BTC","wb":"0.10000001","cw":"0.09"}],"P":[{"s":"BTCUSDT","pa":"0.0100","ep":"50000.0","iw":"2.000001","up":"0.000001"}]}}
        );
    }
    const continuous = (try adapter.tryDrain()).?;
    try owner.applyAdapterBatch(continuous);
    try std.testing.expect(owner.shard.canonical_account.valid);
    try std.testing.expectEqual(@as(u64, 4), owner.shard.canonical_account.last_sequence);
    try std.testing.expectEqual(@as(i128, 21_000_001), owner.shard.canonical_account.balances[0].total.atoms);
    try std.testing.expectEqual(@as(i128, 10_000_001), owner.shard.canonical_account.balances[1].total.atoms);
    try std.testing.expectEqual(@as(i128, 2_000_001), owner.shard.canonical_account.positions[0].margin.?.atoms);
    try std.testing.expectEqualDeep(economic_before, owner.shard.economicSummary());
    const once = owner.shard.canonicalStateDigest();
    try owner.applyAdapterBatch(continuous);
    try std.testing.expectEqualSlices(u8, &once, &owner.shard.canonicalStateDigest());
    try owner.applyAdapterBatch(bootstrap);
    try std.testing.expectEqualSlices(u8, &once, &owner.shard.canonicalStateDigest());
    for ([_]usize{ 0, 3 }) |conflict_index| {
        const conflict_memory = try gpa.create(durable.MemoryAdapter);
        defer gpa.destroy(conflict_memory);
        // ponytail: branch borrows immutable archive; clone payloads if this branch rotates.
        @memcpy(std.mem.asBytes(conflict_memory), std.mem.asBytes(memory));
        const conflicting_owner = try gpa.create(demo.Owner);
        defer gpa.destroy(conflicting_owner);
        try demo.Owner.recoverInto(conflicting_owner, conflict_memory.interface(), undefined, stream);
        var conflicting = canonical.AdapterOutputBatch{};
        var changed = continuous.slice()[conflict_index];
        if (conflict_index == 0) changed.event.account_observed.value.balance.value.total.atoms += 1 else changed.event.account_observed.value.position.value.margin.?.atoms += 1;
        try conflicting.append(changed);
        if (conflict_index == 0) {
            try std.testing.expectError(error.ConflictingObservationIdentity, conflicting_owner.applyAdapterBatch(conflicting));
        } else {
            try std.testing.expectError(error.ConflictingCanonicalIdentity, conflicting_owner.applyAdapterBatch(conflicting));
        }
        try std.testing.expect(!conflicting_owner.shard.canonical_account.valid);
        try std.testing.expect(conflicting_owner.shard.oms.recovery_only);
        const conflict_digest = conflicting_owner.shard.canonicalStateDigest();
        const recovered_conflict = try gpa.create(demo.Owner);
        defer gpa.destroy(recovered_conflict);
        try demo.Owner.recoverInto(recovered_conflict, conflict_memory.interface(), undefined, stream);
        try std.testing.expectEqualSlices(u8, &conflict_digest, &recovered_conflict.shard.canonicalStateDigest());
    }
    const recovered = try gpa.create(demo.Owner);
    defer gpa.destroy(recovered);
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &once, &recovered.shard.canonicalStateDigest());
    const bytes = try gpa.alloc(u8, durable.max_snapshot_bytes);
    defer gpa.free(bytes);
    const restored = try gpa.create(trading.TradingShard);
    defer gpa.destroy(restored);
    _ = try trading.TradingShard.restoreSnapshotInto(restored, try owner.committedSnapshot(bytes));
    try std.testing.expectEqualSlices(u8, &once, &restored.canonicalStateDigest());
    // Omit an emitted account observation to inject a real logical-source gap.
    if (kind == .binance) {
        _ = try implementation.ingestPrivate(gpa, .ws, null, times,
            \\{"e":"ACCOUNT_UPDATE","a":{"B":[{"a":"USDT","wb":"22","cw":"17"}],"P":[]}}
        );
    }
    const dropped = (try adapter.tryDrain()).?;
    var gap_batch = canonical.AdapterOutputBatch{};
    try gap_batch.append(dropped.slice()[1]);
    try std.testing.expectError(error.SourceSequenceGap, owner.applyAdapterBatch(gap_batch));
    try std.testing.expect(!owner.shard.canonical_account.valid);
    try std.testing.expect(owner.shard.oms.recovery_only);
    const failed = owner.shard.canonicalStateDigest();
    try demo.Owner.recoverInto(recovered, memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &failed, &recovered.shard.canonicalStateDigest());
    _ = try trading.TradingShard.restoreSnapshotInto(restored, try owner.committedSnapshot(bytes));
    try std.testing.expectEqualSlices(u8, &failed, &restored.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 0), io.calls);
}

fn check(comptime kind: Kind) !void {
    const Worker = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            exercise(kind) catch |err| {
                self.failure = err;
            };
        }
    };
    var worker = Worker{};
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 * 1024 }, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
}

test "native account continuity Binance Adapter Owner snapshot and replay" {
    try check(.binance);
}

test "native account continuity Bybit unsupported wallet scope persists without inventing availability" {
    try check(.bybit);
}
