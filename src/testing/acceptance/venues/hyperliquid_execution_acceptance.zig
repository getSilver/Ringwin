//! Synthetic offline Gateway -> adapter -> Owner evidence. No credentials or network.
const std = @import("std");
const runtime = @import("../../../runtime/hyperliquid_runtime.zig");
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
const offline_io = @import("../../support/hyperliquid_runtime_io.zig");
const IO = offline_io.IO;
const times = offline_io.times;

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

test "Hyperliquid runtime cross venue Host USDC joint admission IOC maker Unknown and recovery" {
    try runOffline(std.testing.allocator);
}

/// Existing executable's offline fixture; no credential or socket owners exist.
pub fn runOffline(a: std.mem.Allocator) !void {
    const Context = struct {
        allocator: std.mem.Allocator,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            exerciseCrossVenue(self.allocator) catch |err| {
                self.failure = err;
            };
        }
    };
    var context: Context = .{ .allocator = a };
    const thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, Context.run, .{&context});
    thread.join();
    if (context.failure) |err| return err;
}

fn exerciseCrossVenue(a: std.mem.Allocator) !void {
    for ([_]u64{ 1, 3 }) |settlement| for ([_]bool{ false, true }) |spot| for ([_]bool{ false, true }) |maker| for ([_]@FieldType(hl.TransportResult, "outcome"){ .response, .proven_before_send, .uncertain }) |outcome| {
        const memory = try a.create(durable.MemoryAdapter);
        defer a.destroy(memory);
        memory.* = .initWithAllocator(a);
        defer memory.deinit();
        const owner = try a.create(demo.Owner);
        defer a.destroy(owner);
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
        const accounts = @import("../core/multi_account_authority_acceptance.zig");
        if (spot) try accounts.initializeSpotLinearOwnerWithSettlement(owner, settlement) else try accounts.initializePythonOwnerWithSettlement(owner, settlement);
        var capability = owner.shard.registryInstrument(101).?.capability.?;
        {
            capability.version = 2;
            capability.adapter_session = 7;
            capability.supports_post_only = maker;
            _ = try owner.apply(fixture.atGroup(44, .{ .identity = 2000, .account_scope = 20, .payload = .{ .capability_profile_activation = capability } }));
        }
        const gateway = try a.create(execution.Gateway);
        defer a.destroy(gateway);
        gateway.init();
        var io: IO = .{ .sink = try raw.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 7 }), .session = 7, .outcome = outcome };
        var budget: hl.Budget = .{};
        const bindings = [_]hl.Binding{.{ .instrument = 101, .coin = if (spot) "@3" else "BTC", .wire_asset = if (spot) 10003 else 3, .product = if (spot) .spot else .isolated_linear, .size_decimals = 4, .quantity_scale = 4, .lot_atoms = 1, .price_scale = 6, .tick_atoms = 1 }};
        const feeds = [_]runtime.FeedConfiguration{.{ .binding = .{ .instrument = 101, .coin = if (spot) "@3" else "BTC", .product = if (spot) .spot else .isolated_linear, .base_token = 1, .base_token_id = "offline-base", .quote_token_id = "offline-quote", .universe_index = 3, .size_decimals = 4, .rules_version = 1, .expected_metadata_digest = @splat(1), .quantity_scale = 4, .lot_atoms = 1, .price_scale = 6, .tick_atoms = 1 }, .subscription_set = 70, .session = 60 }};
        const assembly = try a.create(runtime.Runtime);
        defer a.destroy(assembly);
        try runtime.Runtime.initInto(assembly, a, .{ .epoch_startup = .virgin, .profile = .{ .venue = 1, .account = 20, .session = 7, .funding = @splat(2), .environment = .simulation, .bindings = &bindings, .version = capability.version, .rules_version = 1, .config_version = 1 }, .feeds = &feeds }, .{ .offline = .{ .transport = .{ .ptr = &io, .submit_fn = IO.submit, .query_fn = IO.query }, .authorizer = .{ .ptr = &io, .sign_fn = IO.sign, .check_fn = IO.check } } }, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, try raw.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 8 }), .{ .domain = .control, .id = 94 });
        const peer_view = try a.create(engine.TradingShard);
        defer a.destroy(peer_view);
        try owner.shard.copyAccountViewInto(peer_view, 30);
        var counterpart: @import("../../../adapters/simulated/simulated_venue.zig").SimulatedVenue = .{ .next_event_identity = 2 };
        try counterpart.adapter().start(.{ .venue = 21, .environment = .simulation, .exchange_account = 30, .adapter_session = 1, .request_capacity = 1, .output_capacity = 32, .asset_definitions = peer_view.activatedAssets(), .instrument_definitions = peer_view.instrument_registry, .native_settlement_atoms = settlement != 1 });
        try gateway.add(.{ .account = 30, .venue_identity = 21, .adapter = counterpart.adapter(), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 }, .supported_products = execution.productMask(.isolated_linear) });
        var bootstrap: [4096]u8 = undefined;
        try gateway.bootstrapDurableDispatchWithBuffer(memory.interface(), undefined, .{ .domain = .control, .id = 92 }, &bootstrap);
        try gateway.pinDeploymentDigest(owner.shard.deployment.header.?.expected_digest);
        const host = @import("../../../strategy/strategy_host_gateway.zig");
        const barrier = owner.shard.authoritativeBarrier();
        const config: host.Config = .{ .schema_registry = engine.schema_registry_identity, .decision_domain = 1, .session = .{ .fencing = 1, .shard = 1, .generation = 1 }, .authorization = .{ .strategy_identity = 9, .config_version = 1, .activation_identity = 1, .activation_barrier = barrier } };
        _ = try owner.apply(fixture.atGroup(45, .{ .identity = 3000, .payload = .{ .host_activated = .{ .strategy_identity = 9, .config_version = 1, .activation_identity = 1, .activation_barrier = barrier, .session = config.session, .state_digest = owner.shard.canonicalStateDigest() } } }));
        var bridge = try host.Gateway.init(config, &.{host.Subscription.of(9, &.{.mark_price})});
        const cursor = owner.shard.authoritativeBarrier() + 1;
        try bridge.recordPublished(1, cursor, 100);
        try bridge.activate(&owner.shard, &owner.decision_journal);
        var storage: [host.max_group_frame_len]u8 = undefined;
        const orders = [_]host.OutputOrder{
            .{ .portfolio_identity = 10, .exchange_account_identity = 20, .instrument_identity = 101, .order_type = if (maker) .post_only else .limit, .time_in_force = if (maker) .post_only else .immediate_or_cancel, .quantity = 1, .limit_price_micros = 10000 },
            .{ .portfolio_identity = 10, .exchange_account_identity = 30, .instrument_identity = 102, .side = .sell, .time_in_force = .immediate_or_cancel, .quantity = 1, .limit_price_micros = 10000 },
        };
        const frame = try host.encodeOutputGroupFrame(&storage, config, 1, cursor, 1, &orders);
        const accepted = bridge.ingest(frame, 101);
        try std.testing.expect(accepted == .accepted_group);
        _ = try owner.apply(fixture.atGroup(46, .{ .identity = 4000, .payload = .{ .external_intent_group = accepted.accepted_group } }));
        try std.testing.expectEqual(@as(u16, 2), owner.shard.oms.command_history_count);
        try std.testing.expectEqual(@as(u8, 1), owner.shard.cycles.count);
        for (owner.shard.oms.command_history[0..2]) |command| try std.testing.expectEqual(settlement, command.reservation.asset);
        try @import("../core/dual_ioc_dispatch_acceptance.zig").observe(gateway, &owner.shard);
        const now = owner.shard.oms.findCommand(1).?.authority.dispatch_deadline_monotonic_ns - 1;
        io.current.monotonic_time_ns = now;
        counterpart.receipt_times = .{ .receive_utc_ns = times.receive_time_utc_ns, .monotonic_ns = now, .audit_utc_ns = times.wall_time_utc_ns };
        try std.testing.expectEqual(venue.SendResult.accepted, try assembly.send(1, now));
        try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(&owner.shard, 2, now));
        try std.testing.expectEqual(@as(u64, 1), io.sends);
        try assembly.drain();
        try owner.applyAdapterBatch((try counterpart.adapter().tryDrain()).?);
        if (outcome == .uncertain) try std.testing.expectEqual(engine.oms.OrderState.unknown, owner.shard.oms.orderById(1).?.state);
        try owner.checkpoint();
        const before = owner.shard.canonicalStateDigest();
        const recovered = try a.create(demo.Owner);
        defer a.destroy(recovered);
        try demo.Owner.recoverInto(recovered, memory.interface(), undefined, owner.stream);
        try std.testing.expectEqualSlices(u8, &before, &recovered.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u8, 1), recovered.shard.cycles.count);
        try std.testing.expectEqual(@as(u64, 1), io.sends);
    };
}

test "Hyperliquid runtime approved configuration durable epochs and read only isolation" {
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            exerciseAssembly() catch |err| {
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                self.failure = err;
            };
        }
    };
    var context: Context = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, Context.run, .{&context});
    thread.join();
    if (context.failure) |err| return err;
}

fn exerciseAssembly() !void {
    const a = std.testing.allocator;
    const memory = try a.create(durable.MemoryAdapter);
    defer a.destroy(memory);
    memory.* = .initWithAllocator(a);
    defer memory.deinit();
    const owner = try a.create(demo.Owner);
    defer a.destroy(owner);
    try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged)) |event| _ = try owner.apply(event);
    var activation: engine.CoreEvent = .{ .identity = 100, .payload = .{ .capability_profile_activation = .{ .exchange_account = 2, .instrument = 3, .venue = 1, .environment = .simulation, .product = .isolated_linear, .version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 7, .max_dispatch_age_ns = 10 * std.time.ns_per_s, .supports_place = true, .supports_cancel = true, .supports_native_amend = false, .supports_venue_reduce_only = true, .supports_post_only = true, .supports_market_protection = false } } };
    _ = try owner.apply(.{ .core = activation });
    var io: IO = .{ .sink = try raw.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 7 }) };
    const bindings = [_]hl.Binding{.{ .instrument = 3, .coin = "BTC", .wire_asset = 3, .product = .isolated_linear, .size_decimals = 4, .quantity_scale = 4, .lot_atoms = 1, .price_scale = 6, .tick_atoms = 1 }};
    const feeds = [_]runtime.FeedConfiguration{.{ .binding = .{ .instrument = 3, .coin = "BTC", .product = .isolated_linear, .universe_index = 3, .size_decimals = 4, .rules_version = 1, .expected_metadata_digest = @splat(1), .quantity_scale = 4, .lot_atoms = 1, .price_scale = 6, .tick_atoms = 1 }, .subscription_set = 70, .session = 60 }};
    var configuration: runtime.Configuration = .{ .epoch_startup = .virgin, .profile = .{ .venue = 1, .account = 2, .session = 7, .funding = @splat(2), .environment = .simulation, .bindings = &bindings, .version = 1, .rules_version = 1, .config_version = 1 }, .feeds = &feeds };
    const json = try std.json.Stringify.valueAlloc(a, configuration, .{});
    defer a.free(json);
    var approved: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &approved, .{});
    const parsed = try runtime.Configuration.parse(a, json, approved);
    defer parsed.deinit();
    try std.testing.expectError(error.ConfigurationNotApproved, runtime.Configuration.parse(a, json, @splat(0)));
    approved[0] ^= 1;
    try std.testing.expectError(error.ConfigurationNotApproved, runtime.Configuration.parse(a, json, approved));
    var wrong_binding = bindings;
    wrong_binding[0].wire_asset += 1;
    var wrong = configuration;
    wrong.profile.bindings = &wrong_binding;
    try std.testing.expectError(error.InvalidConfiguration, wrong.validate());
    var budget: hl.Budget = .{};
    const assembly = try a.create(runtime.Runtime);
    defer a.destroy(assembly);
    const gateway = try a.create(execution.Gateway);
    defer a.destroy(gateway);
    gateway.init();
    const resources: runtime.Resources = .{ .offline = .{ .transport = .{ .ptr = &io, .submit_fn = IO.submit, .query_fn = IO.query }, .authorizer = .{ .ptr = &io, .sign_fn = IO.sign, .check_fn = IO.check } } };
    const market_raw = try raw.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 8 });
    try runtime.Runtime.initInto(assembly, a, parsed.value, resources, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, market_raw, .{ .domain = .control, .id = 94 });
    try std.testing.expectEqual(@as(u64, 1), try assembly.subscribe(a, 0, .{ .receive_time_utc_ns = times.receive_time_utc_ns, .monotonic_time_ns = times.monotonic_time_ns, .wall_time_utc_ns = times.wall_time_utc_ns }));
    // Crash after committed market capture, before applying its pending facts.
    for (owner.shard.canonical_ingress_cursors[0..owner.shard.canonical_ingress_cursor_count]) |cursor| try std.testing.expect(cursor.identity.stream != 60);
    try std.testing.expectEqual(@as(u64, 0), io.sends);
    configuration.epoch_startup = .recover;
    for ([_]bool{ false, true }, 0..) |after_snapshot, index| {
        var crash = memory.interface().vtable.*;
        if (after_snapshot) crash.rotate = crashEpochRotate else crash.publish = crashEpochPublish;
        assembly.private_raw.store = .{ .context = memory, .vtable = &crash };
        try std.testing.expectError(error.EpochUnavailable, assembly.reserveEpoch(0, times.monotonic_time_ns));
        gateway.init();
        try runtime.Runtime.initInto(assembly, a, configuration, resources, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, try raw.DurableSink.recover(memory.interface(), undefined, market_raw.stream), .{ .domain = .control, .id = 94 });
        try std.testing.expectEqual(@as(u64, 3) + 2 * index, try assembly.subscribe(a, 0, .{ .receive_time_utc_ns = times.receive_time_utc_ns, .monotonic_time_ns = times.monotonic_time_ns, .wall_time_utc_ns = times.wall_time_utc_ns }));
        try assembly.drain();
    }
    const replay = try a.create(runtime.MarketReplay);
    defer a.destroy(replay);
    try runtime.MarketReplay.initInto(replay, configuration, owner, a);
    const before_replay = owner.shard.canonicalStateDigest();
    try raw.replayCommitted(memory.interface(), undefined, market_raw.stream, replay.consumer());
    try replay.finish();
    try std.testing.expectEqualSlices(u8, &before_replay, &owner.shard.canonicalStateDigest());
    var wrong_configuration = configuration;
    wrong_configuration.profile.version += 1;
    try runtime.MarketReplay.initInto(replay, wrong_configuration, owner, a);
    try std.testing.expectError(error.ConfigurationNotApproved, raw.replayCommitted(memory.interface(), undefined, market_raw.stream, replay.consumer()));
    // A different incarnation consumes the durable high-water mark, not zero.
    gateway.init();
    try runtime.Runtime.initInto(assembly, a, configuration, resources, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, try raw.DurableSink.recover(memory.interface(), undefined, market_raw.stream), .{ .domain = .control, .id = 94 });
    try std.testing.expectEqual(@as(u64, 6), try assembly.subscribe(a, 0, .{ .receive_time_utc_ns = times.receive_time_utc_ns, .monotonic_time_ns = times.monotonic_time_ns, .wall_time_utc_ns = times.wall_time_utc_ns }));
    try assembly.drain();
    try std.testing.expectError(error.StaleSession, assembly.feeds[0].ingest(a, 1, .book, .{ .receive_time_utc_ns = times.receive_time_utc_ns, .monotonic_time_ns = times.monotonic_time_ns, .wall_time_utc_ns = times.wall_time_utc_ns }, "{}"));
    try assembly.drain();
    try std.testing.expectError(error.MissingField, assembly.feeds[0].ingest(a, 6, .metadata, .{ .receive_time_utc_ns = times.receive_time_utc_ns, .monotonic_time_ns = times.monotonic_time_ns, .wall_time_utc_ns = times.wall_time_utc_ns }, "{}"));
    try assembly.drain();
    try runtime.MarketReplay.initInto(replay, configuration, owner, a);
    const rejected_digest = owner.shard.canonicalStateDigest();
    try raw.replayCommitted(memory.interface(), undefined, market_raw.stream, replay.consumer());
    try replay.finish();
    try std.testing.expectEqualSlices(u8, &rejected_digest, &owner.shard.canonicalStateDigest());
    gateway.init();
    configuration.profile.environment = .demo;
    try std.testing.expectError(error.InvalidConfiguration, runtime.Runtime.initInto(assembly, a, configuration, resources, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, market_raw, .{ .domain = .control, .id = 94 }));
    configuration.profile.environment = .testnet;
    var unavailable_wallet: hl.WalletAuthorization = undefined;
    const denied: runtime.Resources = .{ .testnet_write = .{ .transport = resources.offline.transport, .wallet = &unavailable_wallet, .hyperliquid_testnet_write_authorized = false, .expires_monotonic_ns = times.monotonic_time_ns + 1 } };
    try std.testing.expectError(error.TestnetWriteNotAuthorized, runtime.Runtime.initInto(assembly, a, configuration, denied, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, market_raw, .{ .domain = .control, .id = 94 }));
    var expired = denied;
    expired.testnet_write.hyperliquid_testnet_write_authorized = true;
    expired.testnet_write.expires_monotonic_ns = times.monotonic_time_ns;
    try std.testing.expectError(error.TestnetWriteNotAuthorized, runtime.Runtime.initInto(assembly, a, configuration, expired, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, market_raw, .{ .domain = .control, .id = 94 }));
    const readonly: runtime.Resources = .{ .read_only = resources.offline.transport };
    try std.testing.expectError(error.CapabilityMismatch, runtime.Runtime.initInto(assembly, a, configuration, readonly, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, market_raw, .{ .domain = .control, .id = 94 }));
    activation.identity += 1;
    activation.payload.capability_profile_activation.version = 2;
    activation.payload.capability_profile_activation.environment = .testnet;
    _ = try owner.apply(.{ .core = activation });
    configuration.profile.version = 2;
    const authorization = owner.shard.registryInstrument(3).?.tradingAuthorization(1);
    _ = try owner.apply(.{ .core = .{ .identity = 200, .payload = .{ .instrument_trading_authorization = .{ .strategy_identity = 1, .exchange_account = 2, .instrument = 3, .strategy_activation_identity = 1, .config_version = 1, .expected_version = authorization.version, .enabled = false } } } });
    activation.identity += 1;
    activation.payload.capability_profile_activation.version = 3;
    _ = try owner.apply(.{ .core = activation });
    configuration.profile.version = 3;
    try std.testing.expect(!owner.shard.registryInstrument(3).?.tradingAuthorization(1).enabled);
    const readonly_market = try raw.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 10 });
    try runtime.Runtime.initInto(assembly, a, configuration, readonly, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, readonly_market, .{ .domain = .control, .id = 94 });
    try std.testing.expectError(error.ReadOnly, assembly.send(1, times.monotonic_time_ns));
    try std.testing.expect(!assembly.private.profile.can_trade);
    try std.testing.expectEqual(@as(u64, 0), io.sends);
    gateway.init();
    configuration.profile.session += 1;
    try std.testing.expectError(error.CapabilityMismatch, runtime.Runtime.initInto(assembly, a, configuration, readonly, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, market_raw, .{ .domain = .control, .id = 94 }));
}

fn crashEpochPublish(_: *anyopaque, _: std.Io, _: durable.StreamIdentity, _: u64, _: []const u8) anyerror!void {
    return error.InjectedCrash;
}
fn crashEpochRotate(_: *anyopaque, _: std.Io, _: durable.StreamIdentity) anyerror!void {
    return error.InjectedCrash;
}

test "Hyperliquid Gateway durable CLOID Owner raw crash recovery and snapshot tails converge in both Fill orders" {
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            exerciseRecovery() catch |err| {
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
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
    var expected: [4]?engine.EconomicSummary = @splat(null);
    for ([_][]const u8{ "0.25", "0", "-0.001", "-0.000001" }, 0..) |fee_text, fee_index| for ([_]bool{ false, true }) |fill_first| {
        const memory = try allocator.create(durable.MemoryAdapter);
        defer allocator.destroy(memory);
        memory.* = .initWithAllocator(allocator);
        defer memory.deinit();
        const owner = try allocator.create(demo.Owner);
        defer allocator.destroy(owner);
        try demo.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
        for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged)) |event| _ = try owner.apply(event);
        for (owner.shard.instrument_registry.entries[0..owner.shard.instrument_registry.count]) |configured| {
            var margin = configured.margin;
            margin.instrument = configured.instrument;
            margin.version += 1;
            margin.native_settlement_atoms = true;
            _ = try owner.apply(fixture.atGroup(11, .{ .identity = @intCast(configured.instrument), .payload = .{ .margin_rules_activated = margin } }));
        }
        var usdc = @import("../../../trading/asset_registry.zig").testDefinitions(6, 8)[0];
        usdc.asset = 5;
        usdc.code_bindings = @splat(.{});
        usdc.code_binding_count = 1;
        usdc.code_bindings[0] = try c.AssetCodeBinding.init(1, "USDC");
        _ = try owner.apply(fixture.atGroup(11, .{ .identity = 5, .payload = .{ .asset_definition_activated = usdc } }));
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
        const gateway = try allocator.create(execution.Gateway);
        defer allocator.destroy(gateway);
        gateway.init();
        const feeds = [_]runtime.FeedConfiguration{.{ .binding = .{ .instrument = 3, .coin = "BTC", .product = .isolated_linear, .universe_index = 3, .size_decimals = 4, .rules_version = 1, .expected_metadata_digest = @splat(1), .quantity_scale = 4, .lot_atoms = 1, .price_scale = 6, .tick_atoms = 1 }, .subscription_set = 70, .session = 60 }};
        const assembly = try allocator.create(runtime.Runtime);
        defer allocator.destroy(assembly);
        try runtime.Runtime.initInto(assembly, allocator, .{ .epoch_startup = .virgin, .profile = .{ .venue = 1, .account = 2, .session = 7, .funding = @splat(2), .environment = .simulation, .bindings = &bindings, .version = 1, .rules_version = 1, .config_version = 1, .bootstrap_identity = 1 }, .feeds = &feeds }, .{ .offline = .{ .transport = .{ .ptr = &io, .submit_fn = IO.submit, .query_fn = IO.query }, .authorizer = .{ .ptr = &io, .sign_fn = IO.sign, .check_fn = IO.check } } }, owner, gateway, .{ .ptr = &io, .now_fn = IO.now }, &budget, io.sink, try raw.DurableSink.init(memory.interface(), undefined, .{ .domain = .raw_ingress, .id = 8 }), .{ .domain = .control, .id = 94 });
        const implementation = &assembly.private;
        const adapter = implementation.adapter();
        const route = gateway.routes[0];
        var bootstrap_buffer: [4096]u8 = undefined;
        try gateway.bootstrapDurableDispatchWithBuffer(memory.interface(), undefined, .{ .domain = .control, .id = 92 }, &bootstrap_buffer);
        try gateway.observeAuthorityFromShard(&owner.shard, .{ .account = 2, .effective_trading_authority = owner.shard.operational_state.effectiveTradingAuthority(), .reservation_identity = command.reservation_identity, .reservation = command.reservation, .primary_lease_expires_at_monotonic_ns = 20 * std.time.ns_per_s, .fencing_token = 1, .exchange_position = owner.shard.currentNetExchangePosition(3).?, .authority_barrier = 1 });
        try std.testing.expectEqual(venue.SendResult.accepted, try assembly.send(command.command_id, 2 * std.time.ns_per_s));
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
        try demo.Owner.recoverWithIngressInto(dispatch_recovered, memory.interface(), undefined, owner.stream, assembly.private_raw.stream);
        var dispatch_decoder: hl.HyperliquidVenueAdapter = .{ .profile = implementation.profile, .clock = implementation.clock, .auth = implementation.auth, .raw_sink = implementation.raw_sink, .transport = implementation.transport, .budget = &budget, .fencing_token = 1, .replay_only = true };
        try dispatch_decoder.adapter().start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 7, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
        var dispatch_sweep: Sweep = .{ .decoder = &dispatch_decoder, .owner = dispatch_recovered, .expected = &initial, .last_raw_sequence = implementation.raw_sequence };
        try dispatch_recovered.replayCommittedIngress(assembly.private_raw.stream, .{ .ptr = &dispatch_sweep, .consume_fn = Sweep.consume });
        try std.testing.expectEqual(initial.len, dispatch_sweep.count);
        try std.testing.expectEqualSlices(u8, &expected_dispatch.canonicalStateDigest(), &dispatch_recovered.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u64, 1), io.sends);
        @memcpy(std.mem.asBytes(owner), std.mem.asBytes(dispatch_recovered));
        var seed_buffer: [192 * 1024]u8 = undefined;
        const seed = try implementation.exportResumeCheckpoint(&seed_buffer);
        try assembly.private_raw.checkpoint();
        const raw_receipt = try memory.interface().archiveReceipt(undefined, assembly.private_raw.stream);
        var seed_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(seed, &seed_digest, .{});
        const prefix_raw_sequence = implementation.raw_sequence;
        try owner.checkpointPrivate(.{ .decision_stream = owner.stream.id, .decision_barrier = owner.shard.authoritativeBarrier(), .core_digest = owner.shard.canonicalStateDigest(), .raw_stream = assembly.private_raw.stream, .raw_sequence = prefix_raw_sequence, .raw_digest = initial.slice()[0].envelope.raw_evidence.digest, .raw_archive_root = raw_receipt.ordered_root, .adapter_session = 7, .canonical_stream = 7, .canonical_sequence = implementation.sequence, .seed_digest = seed_digest }, seed);
        const reference = try allocator.create(engine.TradingShard);
        defer allocator.destroy(reference);
        @memcpy(std.mem.asBytes(reference), std.mem.asBytes(&owner.shard));
        const snapshot_bytes = try allocator.alloc(u8, durable.max_snapshot_bytes);
        defer allocator.free(snapshot_bytes);
        const snapshot_before_facts = try owner.committedSnapshot(snapshot_bytes);
        var tail = engine.journal.Journal.initAt(owner.shard.authoritativeBarrier() + 1);
        var frame: [2048]u8 = undefined;
        const report = try std.fmt.bufPrint(&frame, "[{{\"order\":{{\"coin\":\"BTC\",\"side\":\"B\",\"limitPx\":\"50100\",\"sz\":\"0\",\"origSz\":\"0.01\",\"oid\":42,\"cloid\":\"{s}\",\"timestamp\":1800000000000}},\"status\":\"filled\",\"statusTimestamp\":1800000000001}}]", .{cloid.slice()});
        const fill_template = "[{\"coin\":\"BTC\",\"px\":\"50100\",\"sz\":\"0.01\",\"side\":\"B\",\"time\":1800000000001,\"oid\":42,\"tid\":8,\"fee\":\"0.25\",\"feeToken\":\"USDT\",\"crossed\":true,\"closedPnl\":\"0\",\"dir\":\"Open Long\"}]";
        const fee_frame = try std.mem.replaceOwned(u8, allocator, fill_template, "0.25", fee_text);
        defer allocator.free(fee_frame);
        const fee_asset: u64 = if (fee_index >= 2) 5 else 1;
        const fill = try std.mem.replaceOwned(u8, allocator, fee_frame, "USDT", if (fee_asset == 5) "USDC" else "USDT");
        defer allocator.free(fill);
        const expected_fee: i128 = if (std.mem.eql(u8, fee_text, "0.25")) 250000 else 0;
        const expected_rebate: i128 = if (std.mem.eql(u8, fee_text, "-0.001")) 1000 else if (std.mem.eql(u8, fee_text, "-0.000001")) 1 else 0;
        var fill_identity: u64 = 0;
        var original_fill: c.AdapterOutputBatch = .{};
        for (0..2) |index| {
            const is_fill = (index == 0) == fill_first;
            try implementation.ingest(allocator, 7, @splat(2), if (is_fill) .fills else .orders, times, if (is_fill) fill else report);
            const batch = (try adapter.tryDrain()).?;
            for (batch.slice()) |record| {
                if (record.event == .fill) {
                    try original_fill.append(record);
                    fill_identity = @intCast(record.event.fill.identity);
                    try std.testing.expectEqualDeep(c.AssetAmount{ .asset = fee_asset, .atoms = expected_fee }, record.event.fill.fee.?);
                    if (expected_rebate > 0) try std.testing.expectEqualDeep(c.AssetAmount{ .asset = fee_asset, .atoms = expected_rebate }, record.event.fill.rebate.?);
                }
                _ = try engine.applyStable(reference, &tail, .{ .venue = record });
            }
            // Keep a raw-only crash and an online Owner application in each arrival order.
            if (index == 1) try owner.applyAdapterBatch(batch);
            // Retire the old Owner and recover the committed prefix plus raw tail.
            const restarted = try allocator.create(demo.Owner);
            defer allocator.destroy(restarted);
            try demo.Owner.recoverWithIngressInto(restarted, memory.interface(), undefined, owner.stream, assembly.private_raw.stream);
            var decoder: hl.HyperliquidVenueAdapter = .{ .profile = implementation.profile, .clock = implementation.clock, .auth = implementation.auth, .raw_sink = implementation.raw_sink, .transport = implementation.transport, .budget = &budget, .fencing_token = 1, .replay_only = true };
            try decoder.adapter().start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 7, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
            const view = try demo.recoverPrivateCheckpoint(memory.interface(), undefined, owner.stream);
            try decoder.restoreResumeCheckpoint(view.seed);
            restarted.private_seed_restored = true;
            var sweep: Sweep = .{ .decoder = &decoder, .owner = restarted, .committed_sequence = Sweep.appliedThrough(restarted) };
            const sends_before = io.sends;
            const raw_before = assembly.private_raw.next_sequence;
            try restarted.replayCommittedIngress(assembly.private_raw.stream, .{ .ptr = &sweep, .consume_fn = Sweep.consume });
            try std.testing.expectEqual(sends_before, io.sends);
            try std.testing.expectEqual(raw_before, assembly.private_raw.next_sequence);
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
        try std.testing.expectEqual(expected_fee, owner.shard.economicSummary().portfolio.fee_atoms);
        try std.testing.expectEqual(@as(i128, 0), owner.shard.economicSummary().portfolio.rebate_atoms);
        if (fee_asset == 5) {
            const native = owner.shard.economic_projection.portfolio.nativeAsset(5).?;
            try std.testing.expectEqual(expected_rebate, native.rebate_atoms);
            try std.testing.expectEqual(expected_rebate, native.balance_atoms);
            try std.testing.expectEqual(@as(i128, 0), native.fee_atoms);
            try std.testing.expectEqual(expected_rebate, owner.shard.economic_projection.exchange.nativeAsset(5).?.rebate_atoms);
        }
        const economics = owner.shard.economicSummary();
        // Each virgin Gateway creates a fresh random namespace and therefore a different CLOID.
        if (expected[fee_index]) |value| try std.testing.expectEqualDeep(value, economics) else expected[fee_index] = economics;
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

        const archived_economics = owner.shard.economic_projection.semanticDigest();
        try owner.applyAdapterBatch(original_fill);
        try std.testing.expectEqualSlices(u8, &archived_economics, &owner.shard.economic_projection.semanticDigest());
        try std.testing.expect(!owner.shard.history_conflict_latched);

        // Exercise an actual recovery query and its safety result through the same durable public chain.
        const recovery_seed = try implementation.exportResumeCheckpoint(&seed_buffer);
        try assembly.private_raw.checkpoint();
        const recovery_raw_receipt = try memory.interface().archiveReceipt(undefined, assembly.private_raw.stream);
        std.crypto.hash.sha2.Sha256.hash(recovery_seed, &seed_digest, .{});
        var last_raw_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(fill, &last_raw_digest, .{});
        try owner.checkpointPrivate(.{ .decision_stream = owner.stream.id, .decision_barrier = owner.shard.authoritativeBarrier(), .core_digest = owner.shard.canonicalStateDigest(), .raw_stream = assembly.private_raw.stream, .raw_sequence = implementation.raw_sequence, .raw_digest = last_raw_digest, .raw_archive_root = recovery_raw_receipt.ordered_root, .adapter_session = 7, .canonical_stream = 7, .canonical_sequence = implementation.sequence, .seed_digest = seed_digest }, recovery_seed);
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
        try demo.Owner.recoverWithIngressInto(fault_recovered, memory.interface(), undefined, owner.stream, assembly.private_raw.stream);
        var fault_decoder: hl.HyperliquidVenueAdapter = .{ .profile = implementation.profile, .clock = implementation.clock, .auth = implementation.auth, .raw_sink = implementation.raw_sink, .transport = implementation.transport, .budget = &budget, .fencing_token = 1, .replay_only = true };
        try fault_decoder.adapter().start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 7, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
        try fault_decoder.restoreResumeCheckpoint((try demo.recoverPrivateCheckpoint(memory.interface(), undefined, owner.stream)).seed);
        fault_recovered.private_seed_restored = true;
        var fault_sweep: Sweep = .{ .decoder = &fault_decoder, .owner = fault_recovered, .expected = &observed, .committed_sequence = Sweep.appliedThrough(fault_recovered) };
        const raw_before_recovery = assembly.private_raw.next_sequence;
        try fault_recovered.replayCommittedIngress(assembly.private_raw.stream, .{ .ptr = &fault_sweep, .consume_fn = Sweep.consume });
        try std.testing.expectEqual(observed.len, fault_sweep.count);
        try fault_decoder.finishReplay();
        try std.testing.expectEqualSlices(u8, &fault_digest, &fault_recovered.shard.canonicalStateDigest());
        try std.testing.expect(!fault_recovered.shard.operational_state.effectiveTradingAuthority());
        try std.testing.expectEqual(raw_before_recovery, assembly.private_raw.next_sequence);
        try std.testing.expectEqual(@as(u64, 1), io.sends);
        const economics_before_conflict = fault_recovered.shard.economic_projection.semanticDigest();
        var conflict = original_fill;
        conflict.events[0].event.fill.fee.?.atoms += 1;
        try fault_recovered.applyAdapterBatch(conflict);
        try std.testing.expect(fault_recovered.shard.history_conflict_latched);
        try std.testing.expectEqualSlices(u8, &economics_before_conflict, &fault_recovered.shard.economic_projection.semanticDigest());
    };
}
