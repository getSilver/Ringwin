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
const engine = @import("../../../trading/trading_shard.zig");
const times: hl.Times = .{ .receive_time_utc_ns = 1_800_000_000_100_000_000, .wall_time_utc_ns = 1_800_000_000_100_000_000, .monotonic_time_ns = 2 * std.time.ns_per_s };
const IO = struct {
    sink: raw.DurableSink,
    sends: u64 = 0,
    recover_funding: bool = false,
    fn now(_: *anyopaque) hl.Times {
        return times;
    }
    fn sign(_: *anyopaque, request: signer.Request) !signer.SignedAction {
        return .{ .nonce = request.now_ms, .digest = @splat(1), .signature = .{ .r = @splat(1), .s = @splat(1), .v = 27 }, .session = request.session, .funding_account = @splat(2), .subaccount = null };
    }
    fn check(_: *anyopaque, _: u64, _: u64, _: bool) !void {}
    fn query(ptr: *anyopaque, bytes: []const u8) hl.TransportResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const response = if (std.mem.indexOf(u8, bytes, "orderStatus") != null) "{\"status\":\"unknownOid\"}" else if (std.mem.indexOf(u8, bytes, "userAbstraction") != null) "\"default\"" else if (std.mem.indexOf(u8, bytes, "\"clearinghouseState\"") != null) "{\"assetPositions\":[]}" else if (std.mem.indexOf(u8, bytes, "spotClearinghouseState") != null) "{\"balances\":[]}" else if (self.recover_funding and std.mem.indexOf(u8, bytes, "\"userFunding\"") != null) "[{\"time\":1800000000001,\"delta\":{\"type\":\"funding\",\"usdc\":\"-0.01\"}}]" else "[]";
        return .{ .outcome = .response, .bytes = response, .session = 7, .times = times };
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

const Sweep = struct {
    decoder: *hl.HyperliquidVenueAdapter,
    owner: *demo.Owner,
    expected: ?*const c.AdapterOutputBatch = null,
    count: usize = 0,
    committed_sequence: u64 = 0,
    last_raw_sequence: u64 = 0,
    fn appliedThrough(owner: *const demo.Owner) u64 {
        for (owner.shard.canonical_ingress_cursors[0..owner.shard.canonical_ingress_cursor_count]) |cursor| if (cursor.scope.venue == 1 and cursor.scope.account == 2 and cursor.identity.stream == 7) return cursor.identity.sequence;
        return 0;
    }
    fn consume(ptr: *anyopaque, sequence: u64, record: @import("../../../adapters/okx/okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (record.source_session != 7) return error.StaleSession;
        try self.decoder.replay(std.enums.fromInt(hl.Input, record.origin) orelse return error.InvalidReplayRoute, .{ .receive_time_utc_ns = record.receive_time_utc_ns, .monotonic_time_ns = record.monotonic_time_ns, .wall_time_utc_ns = record.wall_time_utc_ns }, .{ .stream = 7, .sequence = sequence, .digest = record.sha256 }, bytes);
        while (try self.decoder.adapter().tryDrain()) |facts| {
            for (facts.slice()) |fact| {
                if (self.expected) |expected| {
                    if (self.count >= expected.len) return error.UnexpectedReplayedFact;
                    try std.testing.expectEqualDeep(expected.slice()[self.count], fact);
                }
                self.count += 1;
            }
            var tail: c.AdapterOutputBatch = .{};
            for (facts.slice()) |fact| if (fact.envelope.identity.sequence > self.committed_sequence) {
                try tail.append(fact);
            };
            try self.owner.applyAdapterBatch(tail);
        }
        if (sequence == self.last_raw_sequence) try self.decoder.finishReplay();
    }
};

test "Hyperliquid Gateway durable CLOID Owner raw crash recovery and snapshot tails converge in both Fill orders" {
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            exerciseRecovery() catch |err| {
                self.failure = err;
            };
        }
    };
    var context: Context = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, Context.run, .{&context});
    thread.join();
    if (context.failure) |err| return err;
}

fn exerciseRecovery() !void {
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
        var implementation: hl.HyperliquidVenueAdapter = .{ .profile = .{ .venue = 1, .account = 2, .session = 7, .funding = @splat(2), .environment = .simulation, .bindings = &bindings, .version = 1, .rules_version = 1, .config_version = 1, .can_trade = true, .bootstrap_identity = 1 }, .clock = .{ .ptr = &io, .now_fn = IO.now }, .auth = .{ .ptr = &io, .sign_fn = IO.sign, .check_fn = IO.check }, .raw_sink = .{ .ptr = &io, .append_fn = IO.append }, .transport = .{ .ptr = &io, .submit_fn = IO.submit, .query_fn = IO.query }, .budget = &budget, .fencing_token = 1 };
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
        const expected_dispatch = try allocator.create(engine.TradingShard);
        defer allocator.destroy(expected_dispatch);
        @memcpy(std.mem.asBytes(expected_dispatch), std.mem.asBytes(&owner.shard));
        var dispatch_log = engine.journal.Journal.initAt(owner.shard.authoritativeBarrier() + 1);
        for (initial.slice()) |record| _ = try engine.applyStable(expected_dispatch, &dispatch_log, .{ .venue = record });
        const dispatch_recovered = try allocator.create(demo.Owner);
        defer allocator.destroy(dispatch_recovered);
        try demo.Owner.recoverWithIngressInto(dispatch_recovered, memory.interface(), undefined, owner.stream, io.sink.stream);
        var dispatch_decoder: hl.HyperliquidVenueAdapter = .{ .profile = implementation.profile, .clock = implementation.clock, .auth = implementation.auth, .raw_sink = implementation.raw_sink, .transport = implementation.transport, .budget = &budget, .fencing_token = 1, .replay_only = true };
        try dispatch_decoder.adapter().start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 7, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
        var dispatch_sweep: Sweep = .{ .decoder = &dispatch_decoder, .owner = dispatch_recovered, .expected = &initial, .last_raw_sequence = implementation.raw_sequence };
        try dispatch_recovered.replayCommittedIngress(io.sink.stream, .{ .ptr = &dispatch_sweep, .consume_fn = Sweep.consume });
        try std.testing.expectEqual(initial.len, dispatch_sweep.count);
        try std.testing.expectEqualSlices(u8, &expected_dispatch.canonicalStateDigest(), &dispatch_recovered.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u64, 1), io.sends);
        @memcpy(std.mem.asBytes(owner), std.mem.asBytes(dispatch_recovered));
        var seed_buffer: [192 * 1024]u8 = undefined;
        const seed = try implementation.exportResumeCheckpoint(&seed_buffer);
        try io.sink.checkpoint();
        const raw_receipt = try memory.interface().archiveReceipt(undefined, io.sink.stream);
        var seed_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(seed, &seed_digest, .{});
        const prefix_raw_sequence = implementation.raw_sequence;
        try owner.checkpointPrivate(.{ .decision_stream = owner.stream.id, .decision_barrier = owner.shard.authoritativeBarrier(), .core_digest = owner.shard.canonicalStateDigest(), .raw_stream = io.sink.stream, .raw_sequence = prefix_raw_sequence, .raw_digest = initial.slice()[0].envelope.raw_evidence.digest, .raw_archive_root = raw_receipt.ordered_root, .adapter_session = 7, .canonical_stream = 7, .canonical_sequence = implementation.sequence, .seed_digest = seed_digest }, seed);
        const reference = try allocator.create(engine.TradingShard);
        defer allocator.destroy(reference);
        @memcpy(std.mem.asBytes(reference), std.mem.asBytes(&owner.shard));
        const snapshot_bytes = try allocator.alloc(u8, durable.max_snapshot_bytes);
        defer allocator.free(snapshot_bytes);
        const snapshot_before_facts = try owner.committedSnapshot(snapshot_bytes);
        var tail = engine.journal.Journal.initAt(owner.shard.authoritativeBarrier() + 1);
        var frame: [2048]u8 = undefined;
        const report = try std.fmt.bufPrint(&frame, "[{{\"order\":{{\"coin\":\"BTC\",\"side\":\"B\",\"limitPx\":\"50100\",\"sz\":\"0\",\"origSz\":\"0.01\",\"oid\":42,\"cloid\":\"{s}\",\"timestamp\":1800000000000}},\"status\":\"filled\",\"statusTimestamp\":1800000000001}}]", .{cloid.slice()});
        const fill = "[{\"coin\":\"BTC\",\"px\":\"50100\",\"sz\":\"0.01\",\"side\":\"B\",\"time\":1800000000001,\"oid\":42,\"tid\":8,\"fee\":\"0.25\",\"feeToken\":\"USDT\",\"crossed\":true,\"closedPnl\":\"0\",\"dir\":\"Open Long\"}]";
        var fill_identity: u64 = 0;
        for (0..2) |index| {
            const is_fill = (index == 0) == fill_first;
            try implementation.ingest(allocator, 7, @splat(2), if (is_fill) .fills else .orders, times, if (is_fill) fill else report);
            const batch = (try adapter.tryDrain()).?;
            for (batch.slice()) |record| {
                if (record.event == .fill) fill_identity = @intCast(record.event.fill.identity);
                _ = try engine.applyStable(reference, &tail, .{ .venue = record });
            }
            // Crash after durable raw capture, before applying the batch. Retire the old Owner.
            const restarted = try allocator.create(demo.Owner);
            defer allocator.destroy(restarted);
            try demo.Owner.recoverWithIngressInto(restarted, memory.interface(), undefined, owner.stream, io.sink.stream);
            var decoder: hl.HyperliquidVenueAdapter = .{ .profile = implementation.profile, .clock = implementation.clock, .auth = implementation.auth, .raw_sink = implementation.raw_sink, .transport = implementation.transport, .budget = &budget, .fencing_token = 1, .replay_only = true };
            try decoder.adapter().start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 7, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
            const view = try demo.recoverPrivateCheckpoint(memory.interface(), undefined, owner.stream);
            try decoder.restoreResumeCheckpoint(view.seed);
            restarted.private_seed_restored = true;
            var sweep: Sweep = .{ .decoder = &decoder, .owner = restarted, .committed_sequence = Sweep.appliedThrough(restarted) };
            const sends_before = io.sends;
            const raw_before = io.sink.next_sequence;
            try restarted.replayCommittedIngress(io.sink.stream, .{ .ptr = &sweep, .consume_fn = Sweep.consume });
            try std.testing.expectEqual(sends_before, io.sends);
            try std.testing.expectEqual(raw_before, io.sink.next_sequence);
            try std.testing.expectEqualSlices(u8, &reference.canonicalStateDigest(), &restarted.shard.canonicalStateDigest());
            @memcpy(std.mem.asBytes(owner), std.mem.asBytes(restarted));
        }
        try tail.seal();
        const snapshot_restored = try allocator.create(engine.TradingShard);
        defer allocator.destroy(snapshot_restored);
        _ = try engine.TradingShard.restoreSegmentsInto(snapshot_restored, snapshot_before_facts, &.{tail.bytes()});
        try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &snapshot_restored.canonicalStateDigest());
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
        _ = try owner.archiveFillHistory(fill_identity, recovered);
        const archived_digest = owner.shard.canonicalStateDigest();
        try implementation.ingest(allocator, 7, @splat(2), .fills, times, fill);
        try owner.applyAdapterBatch((try adapter.tryDrain()).?);
        try std.testing.expectEqualSlices(u8, &archived_digest, &owner.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(i64, 100), try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));

        // Exercise an actual recovery query and its safety result through the same durable public chain.
        const recovery_seed = try implementation.exportResumeCheckpoint(&seed_buffer);
        try io.sink.checkpoint();
        const recovery_raw_receipt = try memory.interface().archiveReceipt(undefined, io.sink.stream);
        std.crypto.hash.sha2.Sha256.hash(recovery_seed, &seed_digest, .{});
        var last_raw_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(fill, &last_raw_digest, .{});
        try owner.checkpointPrivate(.{ .decision_stream = owner.stream.id, .decision_barrier = owner.shard.authoritativeBarrier(), .core_digest = owner.shard.canonicalStateDigest(), .raw_stream = io.sink.stream, .raw_sequence = implementation.raw_sequence, .raw_digest = last_raw_digest, .raw_archive_root = recovery_raw_receipt.ordered_root, .adapter_session = 7, .canonical_stream = 7, .canonical_sequence = implementation.sequence, .seed_digest = seed_digest }, recovery_seed);
        io.recover_funding = fill_first;
        var observed: c.AdapterOutputBatch = .{};
        _ = try adapter.trySend(.{ .order_reconciliation = .{ .identity = 898, .exchange_account = 2, .order = command.order_id } });
        const unresolved_order = (try adapter.tryDrain()).?;
        for (unresolved_order.slice()) |fact| try observed.append(fact);
        try std.testing.expectEqual(c.ReconciliationStatus.found_terminal, unresolved_order.slice()[0].event.order_reconciliation_result.status);
        try owner.applyAdapterBatch(unresolved_order);
        _ = try adapter.trySend(.{ .account_reconciliation = .{ .identity = 899, .exchange_account = 2, .expected_session = 7 } });
        const unscoped_account = (try adapter.tryDrain()).?;
        for (unscoped_account.slice()) |fact| try observed.append(fact);
        try owner.applyAdapterBatch(unscoped_account);
        _ = try adapter.trySend(.{ .account_reconciliation = .{ .identity = 900, .exchange_account = 2, .expected_session = 7, .economic_boundary_utc_ns = 1800000000000 * std.time.ns_per_ms, .economic_through_utc_ns = 1800000000010 * std.time.ns_per_ms } });
        while (try adapter.tryDrain()) |facts| {
            for (facts.slice()) |fact| try observed.append(fact);
            try owner.applyAdapterBatch(facts);
        }
        try std.testing.expectError(error.UnsupportedFact, implementation.ingest(allocator, 7, @splat(2), .funding, times, "[]"));
        const unsupported = (try adapter.tryDrain()).?;
        for (unsupported.slice()) |fact| try observed.append(fact);
        try owner.applyAdapterBatch(unsupported);
        try implementation.disconnected(times);
        const disconnected = (try adapter.tryDrain()).?;
        for (disconnected.slice()) |fact| try observed.append(fact);
        try owner.applyAdapterBatch(disconnected);
        try std.testing.expect(!owner.shard.operational_state.effectiveTradingAuthority());
        const fault_digest = owner.shard.canonicalStateDigest();
        const fault_recovered = try allocator.create(demo.Owner);
        defer allocator.destroy(fault_recovered);
        try demo.Owner.recoverWithIngressInto(fault_recovered, memory.interface(), undefined, owner.stream, io.sink.stream);
        var fault_decoder: hl.HyperliquidVenueAdapter = .{ .profile = implementation.profile, .clock = implementation.clock, .auth = implementation.auth, .raw_sink = implementation.raw_sink, .transport = implementation.transport, .budget = &budget, .fencing_token = 1, .replay_only = true };
        try fault_decoder.adapter().start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 7, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
        try fault_decoder.restoreResumeCheckpoint((try demo.recoverPrivateCheckpoint(memory.interface(), undefined, owner.stream)).seed);
        fault_recovered.private_seed_restored = true;
        var fault_sweep: Sweep = .{ .decoder = &fault_decoder, .owner = fault_recovered, .expected = &observed, .committed_sequence = Sweep.appliedThrough(fault_recovered) };
        const raw_before_recovery = io.sink.next_sequence;
        try fault_recovered.replayCommittedIngress(io.sink.stream, .{ .ptr = &fault_sweep, .consume_fn = Sweep.consume });
        try std.testing.expectEqual(observed.len, fault_sweep.count);
        try fault_decoder.finishReplay();
        try std.testing.expectEqualSlices(u8, &fault_digest, &fault_recovered.shard.canonicalStateDigest());
        try std.testing.expect(!fault_recovered.shard.operational_state.effectiveTradingAuthority());
        try std.testing.expectEqual(raw_before_recovery, io.sink.next_sequence);
        try std.testing.expectEqual(@as(u64, 1), io.sends);
    }
}
