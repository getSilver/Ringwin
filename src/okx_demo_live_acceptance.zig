//! Explicit, bounded OKX Demo fill-and-cleanup acceptance.
//! This executable is intentionally separate from replay-capable product code.

const std = @import("std");
const builtin = @import("builtin");
const account_projection = @import("account_projection.zig");
const canonical = @import("canonical_event.zig");
const auth = @import("okx_rest_auth.zig");
const curl = @import("okx_curl_transport.zig");
const live = @import("okx_live_chain.zig");
const market = @import("okx_public_market.zig");
const okx_market_feed = @import("okx_market_feed.zig");
const order = @import("okx_order_entry.zig");
const private = @import("okx_private_reconciliation.zig");
const okx_adapter = @import("okx_venue_adapter.zig");
const lifecycle = @import("simulated_lifecycle_projection.zig");
const execution = @import("execution_gateway.zig");
const demo_authority = @import("demo_authority.zig");
const durable = @import("durable_store.zig");
const raw_ingress = @import("raw_ingress.zig");
const private_recovery = @import("okx_private_recovery.zig");
const failover = @import("failover.zig");
const oms = @import("oms.zig");
const strategy = @import("strategy_host_gateway.zig");
const venue = @import("venue_adapter.zig");

const buy_quantity_atoms: i64 = 5_000; // 0.00005 BTC; five times the current Demo minimum
const min_quantity_atoms: i64 = 1_000; // current BTC-USDT minSz 0.00001
const source_session: u64 = 1;
const demo_venue: canonical.VenueIdentity = 1;
const demo_account: canonical.ExchangeAccountIdentity = 2;
// ponytail: fixed headroom covers this bounded one-buy/one-cleanup tool; replace it when Trace is checkpointed.
const demo_order_trace_reserve: usize = 16;
const demo_round_trip_trace_reserve: usize = demo_order_trace_reserve * 2;

pub const RestEndpoint = struct {
    source: private.IngressSource,
    path: []const u8,
    cursor: enum { none, order_id, bill_id } = .none,
    page_size: usize = 20,
};

pub const rest_endpoints = [_]RestEndpoint{
    .{ .source = .rest_account_config, .path = "/api/v5/account/config" },
    .{ .source = .rest_leverage, .path = "/api/v5/account/leverage-info?instId=BTC-USDT-SWAP&mgnMode=isolated" },
    .{ .source = .rest_balance, .path = "/api/v5/account/balance?ccy=BTC,USDT" },
    .{ .source = .rest_positions, .path = "/api/v5/account/positions?instId=BTC-USDT-SWAP" },
    .{ .source = .rest_orders_pending, .path = "/api/v5/trade/orders-pending?limit=3", .cursor = .order_id, .page_size = 3 },
    .{ .source = .rest_orders_history_spot, .path = "/api/v5/trade/orders-history?instType=SPOT&limit=3", .cursor = .order_id, .page_size = 3 },
    .{ .source = .rest_orders_history_swap, .path = "/api/v5/trade/orders-history?instType=SWAP&limit=3", .cursor = .order_id, .page_size = 3 },
    .{ .source = .rest_fills_history_spot, .path = "/api/v5/trade/fills-history?instType=SPOT&limit=3", .cursor = .bill_id, .page_size = 3 },
    .{ .source = .rest_fills_history_swap, .path = "/api/v5/trade/fills-history?instType=SWAP&limit=3", .cursor = .bill_id, .page_size = 3 },
};

pub fn main(init: std.process.Init) !void {
    const mode = try runMode(init);
    if (mode == .prepare_only) return runPrepareOnly(init);
    if (builtin.os.tag != .linux) return error.LinuxDemoRequired;
    return runLinuxAuthoritative(init, mode);
}

fn runPrepareOnly(init: std.process.Init) !void {
    const key = init.environ_map.get("RINGWIN_OKX_KEY") orelse return error.MissingCredential;
    const secret = init.environ_map.get("RINGWIN_OKX_SECRET") orelse return error.MissingCredential;
    const passphrase = init.environ_map.get("RINGWIN_OKX_PASSPHRASE") orelse return error.MissingCredential;
    const rest_base_url = init.environ_map.get("RINGWIN_OKX_REST_BASE_URL") orelse return error.MissingEndpointProfile;
    const entity = init.environ_map.get("RINGWIN_OKX_ENTITY") orelse return error.MissingEndpointProfile;
    var endpoint = try curl.demoEndpointProfile(rest_base_url, entity);
    if (init.environ_map.get("RINGWIN_OKX_PRIVATE_WS_URL")) |url|
        endpoint = try curl.withDemoPrivateWs(endpoint, url);
    try progress(init.io, endpoint.private_ws_url);
    const proxy_z: ?[:0]u8 = if (init.environ_map.get("HTTPS_PROXY") orelse init.environ_map.get("ALL_PROXY")) |proxy| blk: {
        const copy = try init.gpa.allocSentinel(u8, proxy.len, 0);
        @memcpy(copy, proxy);
        break :blk copy;
    } else null;
    defer if (proxy_z) |value| init.gpa.free(value);

    var runtime = try curl.Runtime.init();
    defer runtime.deinit();
    var owner = try curl.TransportOwner.initWithEndpoint(
        try auth.Credentials.init(key, secret, passphrase),
        proxy_z,
        source_session,
        endpoint,
    );
    defer owner.deinit();
    var raw: RawSink = .{};
    var reconciler: private.Reconciler = .{};
    var chain: live.Chain = .{
        .mode = .demo_live,
        .qualification = qualified(),
        .raw_sink = raw.interface(),
        .transport = owner.transport(),
    };
    var adapter_clock: AdapterClock = .{};
    var implementation = okx_adapter.OkxVenueAdapter.init(init.gpa, &chain, adapter_clock.interface(), demoProfile(), demoRules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = demo_venue, .environment = .demo, .exchange_account = demo_account, .adapter_session = source_session, .request_capacity = 4, .output_capacity = 4 });
    var projection: DemoProjection = .{};

    try establishReady(init, &owner, &implementation, &reconciler, null);
    try projection.drain(adapter);
    try progress(init.io, "bootstrap");
    try progress(init.io, "baseline");

    if (hasNonzeroBtcBaseline(&projection)) return error.NonzeroBaselineBtc;

    const prices = try ticker(init, &owner);
    const limits = try priceLimits(init, &owner);
    const buy_price_tenths = try protectedBuyPrice(prices, limits);
    try requireNotional(buy_quantity_atoms, buy_price_tenths);
    try progress(init.io, "observation_only");
}

pub fn readDemoPolicy(init: std.process.Init) !std.json.Parsed(demo_authority.Policy) {
    const path = init.environ_map.get("RINGWIN_DEMO_POLICY_PATH") orelse return error.MissingDemoPolicy;
    var file = try std.Io.Dir.openFileAbsolute(init.io, path, .{});
    defer file.close(init.io);
    var bytes: [4096]u8 = undefined;
    var length: usize = 0;
    while (length < bytes.len) {
        const amount = file.readStreaming(init.io, &.{bytes[length..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (amount == 0) break;
        length += amount;
    }
    if (length == bytes.len) return error.DemoPolicyTooLarge;
    return demo_authority.Policy.parse(init.gpa, bytes[0..length]);
}

/// Linux-only explicit Demo path. A policy selects virgin or recovery; no
/// missing-file inference, fixture shard, or caller-built send proof is used.
fn runLinuxAuthoritative(init: std.process.Init, mode: RunMode) !void {
    if (builtin.os.tag != .linux) return error.LinuxDemoRequired;
    var parsed = try readDemoPolicy(init);
    defer parsed.deinit();
    const policy = parsed.value;
    if (policy.exchange_account != demo_account or policy.portfolio_identity != 1 or policy.config_version != 1)
        return error.UnsupportedDemoPolicy;
    if ((mode == .demo_live) != (policy.startup == .virgin)) return error.DemoModePolicyMismatch;
    const state_dir = init.environ_map.get("RINGWIN_DEMO_STATE_DIR") orelse return error.MissingDemoStateDirectory;
    if (!std.fs.path.isAbsolute(state_dir)) return error.InvalidDemoStateDirectory;
    const lease_dir = try std.fs.path.join(init.gpa, &.{ state_dir, "lease" });
    defer init.gpa.free(lease_dir);
    var lease_store = try failover.LinuxFencingStore.open(init.io, lease_dir);
    defer lease_store.close();
    var authority = try lease_store.load();
    const file_store = try init.gpa.create(durable.LinuxFileAdapter);
    defer init.gpa.destroy(file_store);
    file_store.* = try durable.LinuxFileAdapter.open(init.io, state_dir);
    defer file_store.close(init.io);
    const decision_stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = policy.decision_stream_id };
    const dispatch_stream: durable.StreamIdentity = .{ .domain = .control, .id = policy.dispatch_stream_id };
    const private_stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 93 };
    const decision_owner = try init.gpa.create(demo_authority.Owner);
    defer init.gpa.destroy(decision_owner);
    decision_owner.* = switch (policy.startup) {
        .virgin => try demo_authority.Owner.bootstrap(file_store.interface(), init.io, decision_stream),
        .recover => try demo_authority.Owner.recoverWithIngress(file_store.interface(), init.io, decision_stream, private_stream),
    };
    try policy.activateAssets(decision_owner);
    if (policy.startup == .recover and
        (decision_owner.shard.exchange_account_identity != policy.exchange_account or
            decision_owner.shard.portfolio_identity != policy.portfolio_identity or
            decision_owner.shard.strategy_identity != policy.strategy_identity or
            decision_owner.shard.strategy_activation_identity != policy.activation_identity or
            decision_owner.shard.strategy_config_version != policy.config_version))
        return error.RecoveredDemoPolicyMismatch;
    if (policy.startup == .recover and !demoTraceCapacityAvailable(
        decision_owner.shard.authoritativeBarrier(),
        decision_owner.shard.trace.events.len,
        demo_order_trace_reserve,
    )) return error.InsufficientDemoTraceCapacity;
    const gateway = try init.gpa.create(execution.Gateway);
    defer init.gpa.destroy(gateway);
    gateway.* = .{};
    switch (policy.startup) {
        .virgin => try gateway.bootstrapDurableDispatch(file_store.interface(), init.io, dispatch_stream),
        .recover => try gateway.attachRecoveredDurableDispatch(file_store.interface(), init.io, dispatch_stream),
    }
    const key = init.environ_map.get("RINGWIN_OKX_KEY") orelse return error.MissingCredential;
    const secret = init.environ_map.get("RINGWIN_OKX_SECRET") orelse return error.MissingCredential;
    const passphrase = init.environ_map.get("RINGWIN_OKX_PASSPHRASE") orelse return error.MissingCredential;
    const base_url = init.environ_map.get("RINGWIN_OKX_REST_BASE_URL") orelse return error.MissingEndpointProfile;
    const entity = init.environ_map.get("RINGWIN_OKX_ENTITY") orelse return error.MissingEndpointProfile;
    var endpoint = try curl.demoEndpointProfile(base_url, entity);
    if (init.environ_map.get("RINGWIN_OKX_PRIVATE_WS_URL")) |url|
        endpoint = try curl.withDemoPrivateWs(endpoint, url);
    var runtime = try curl.Runtime.init();
    defer runtime.deinit();
    const transport = try init.gpa.create(curl.TransportOwner);
    defer init.gpa.destroy(transport);
    transport.* = try curl.TransportOwner.initWithEndpoint(try auth.Credentials.init(key, secret, passphrase), null, source_session, endpoint);
    defer transport.deinit();
    var raw = switch (policy.startup) {
        .virgin => try raw_ingress.DurableSink.init(file_store.interface(), init.io, private_stream),
        .recover => try raw_ingress.DurableSink.recover(file_store.interface(), init.io, private_stream),
    };
    const reconciler = try init.gpa.create(private.Reconciler);
    defer init.gpa.destroy(reconciler);
    reconciler.* = .{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualified(), .raw_sink = raw.interface(), .transport = transport.transport() };
    var adapter_clock: AdapterClock = .{};
    const implementation = try init.gpa.create(okx_adapter.OkxVenueAdapter);
    defer init.gpa.destroy(implementation);
    implementation.* = okx_adapter.OkxVenueAdapter.init(init.gpa, &chain, adapter_clock.interface(), demoProfile(), demoRules());
    if (policy.startup == .recover) try implementation.resumeAfter(try canonicalSequence(decision_owner, source_session));
    implementation.attachPrivateReconciler(reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = demo_venue, .environment = .demo, .exchange_account = demo_account, .adapter_session = source_session, .request_capacity = 4, .output_capacity = 4, .asset_definitions = decision_owner.shard.activatedAssets(), .instrument_definitions = decision_owner.shard.instrument_registry, .native_settlement_atoms = if (decision_owner.shard.instrument_registry.get(okx_adapter.btc_usdt_spot)) |configured| configured.margin.native_settlement_atoms else false });
    const projection = try init.gpa.create(DemoProjection);
    defer init.gpa.destroy(projection);
    projection.* = .{};
    if (policy.startup == .recover) {
        for (decision_owner.shard.oms.orders[0..decision_owner.shard.oms.order_count]) |owned| {
            var client_id = owned.client_order_id;
            for (gateway.uncertain_dispatches[0..gateway.uncertain_dispatch_count]) |item| {
                for (decision_owner.shard.oms.command_history[0..decision_owner.shard.oms.command_history_count]) |command| {
                    if (command.command_id == item.command_id and command.order_id == owned.id)
                        client_id = item.client_order_id;
                }
            }
            try implementation.rememberRecoveredOrder(owned.id, client_id, owned.portfolio_reduce_only, .{
                .instrument = owned.instrument,
                .rules_version = owned.limit_price.rules_version,
                .lots = owned.quantity,
            }, owned.revision);
        }
        const committed = try init.gpa.create(private_recovery.CommittedInputs);
        defer init.gpa.destroy(committed);
        committed.* = try private_recovery.CommittedInputs.init(file_store.interface(), init.io, decision_stream);
        chain.mode = .replay;
        try implementation.beginPrivateSession();
        var sweep: private_recovery.Sweep = .{ .implementation = implementation, .owner = decision_owner, .index = committed, .session = source_session, .last_sequence = raw.next_sequence - 1 };
        try decision_owner.replayCommittedIngress(private_stream, sweep.consumer());
        chain.mode = .demo_live;
        for (gateway.uncertain_dispatches[0..gateway.uncertain_dispatch_count]) |item| {
            if (item.reconciliation_id != 0) continue;
            var recovered_command: ?oms.Command = null;
            for (decision_owner.shard.oms.command_history[0..decision_owner.shard.oms.command_history_count]) |command|
                if (command.command_id == item.command_id) {
                    recovered_command = command;
                    break;
                };
            const command = recovered_command orelse return error.MissingRecoveredCommand;
            if (try adapter.trySend(.{ .order_reconciliation = .{
                .identity = command.command_id,
                .exchange_account = policy.exchange_account,
                .order = command.order_id,
            } }) != .accepted) return error.RecoveredReconciliationRejected;
            const started = (try adapter.tryDrain()) orelse return error.MissingRecoveredReconciliationStart;
            try decision_owner.applyAdapterBatch(started);
            try projection.applyBatch(started);
        }
    }
    establishReady(init, transport, implementation, reconciler, decision_owner) catch |err| {
        try drainDemo(adapter, decision_owner, projection);
        return err;
    };
    try drainDemo(adapter, decision_owner, projection);
    try requireNoPendingDemoOrders(init, transport);
    if (policy.startup == .recover) {
        for (gateway.uncertain_dispatches[0..gateway.uncertain_dispatch_count]) |item| {
            if (item.reconciliation_id != 0) continue;
            var recovered_command: ?oms.Command = null;
            for (decision_owner.shard.oms.command_history[0..decision_owner.shard.oms.command_history_count]) |command|
                if (command.command_id == item.command_id) {
                    recovered_command = command;
                    break;
                };
            const command = recovered_command orelse return error.MissingRecoveredCommand;
            const recovered_order = decision_owner.shard.oms.orderById(command.order_id) orelse return error.MissingRecoveredOrder;
            if (recovered_order.last_reconciliation_id == 0) return error.MissingRecoveredReconciliation;
            if (recovered_order.last_reconciliation_status == .unresolved) return error.UnresolvedRecoveredReconciliation;
            if (recovered_order.last_reconciliation_revision < command.revision) return error.StaleRecoveredReconciliation;
            try gateway.reconcileRecoveredDispatch(try decision_owner.source(), item.command_id);
        }
    }
    if (mode == .demo_live and hasNonzeroBtcBaseline(projection)) return error.NonzeroBaselineBtc;
    const bootstrap_prices = try ticker(init, transport);
    const bootstrap_limits = try priceLimits(init, transport);
    const bootstrap_price = if (mode == .demo_live)
        try protectedBuyPrice(bootstrap_prices, bootstrap_limits)
    else
        try protectedSellPrice(bootstrap_prices, bootstrap_limits);
    if (mode == .demo_live) try requireNotional(buy_quantity_atoms, bootstrap_price);
    var lease: failover.PrimaryLease = undefined;
    var have_lease = false;
    defer if (have_lease) authority.revoke(&lease) catch {};
    if (policy.startup == .virgin) {
        if (mode != .demo_live) return error.CleanupRequiresRecoveredDemo;
        const now = (try clock(init.io)).times.monotonic_time_ns;
        lease = try authority.acquire(.{ .exchange_account = policy.exchange_account, .decision_domain = policy.decision_domain }, policy.node_identity, now);
        have_lease = true;
        var bootstrap_guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
        const mark = try std.math.mul(i128, bootstrap_price, policy.price_tick_atoms);
        try policy.initialize(decision_owner, mark, &bootstrap_guard, now, source_session);
    }
    var public_raw: RawSink = .{};
    try establishPublicMarket(init, key, secret, passphrase, endpoint, &public_raw, decision_owner);
    const required_trace_capacity = if (mode == .demo_live) demo_round_trip_trace_reserve else demo_order_trace_reserve;
    if (!demoTraceCapacityAvailable(
        decision_owner.shard.authoritativeBarrier(),
        decision_owner.shard.trace.events.len,
        required_trace_capacity,
    )) return error.InsufficientDemoTraceCapacity;
    const execution_prices = try demoBookPrices(decision_owner);
    const execution_limits = try priceLimits(init, transport);
    const first_price = if (mode == .demo_live)
        try protectedBuyPrice(execution_prices, execution_limits)
    else
        try protectedSellPrice(execution_prices, execution_limits);
    if (mode == .demo_live) try requireNotional(buy_quantity_atoms, first_price);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try gateway.add(.{ .account = demo_account, .adapter = adapter, .venue_identity = demo_venue, .environment = .demo, .lease_guard = &guard, .capability = .{
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .session = source_session,
        .supports_post_only = true,
        .supports_market_protection = true,
    } });
    var cleanup_needed = false;
    defer if (cleanup_needed) emergencyAuthoritativeCleanup(init, policy, transport, implementation, adapter, decision_owner, projection, gateway, &guard, &authority, &lease, &have_lease) catch {};
    if (mode == .demo_live) {
        if (try currentNetBtc(decision_owner) != 0) return error.NonzeroBaselineBtc;
        const command = try emitDemoIntent(init, policy, decision_owner, &authority, &lease, &have_lease, .buy, false, buy_quantity_atoms, first_price);
        cleanup_needed = true;
        const wire_client_order_id = try sendDemoCommand(init, decision_owner, gateway, &guard, adapter, projection, command.command_id);
        const buy_result = try waitForOrder(init, transport, implementation, projection, decision_owner, wire_client_order_id.slice());
        var bought_atoms = try currentNetBtc(decision_owner);
        if (privateRestRefreshRequired(buy_result, bought_atoms >= min_quantity_atoms)) {
            try beginPrivateRestRefresh(implementation, decision_owner, projection);
            refreshPrivateRest(init, transport, implementation, reconciler) catch |err| {
                try drainDemo(adapter, decision_owner, projection);
                return err;
            };
            try drainDemo(adapter, decision_owner, projection);
            bought_atoms = try currentNetBtc(decision_owner);
        }
        if (!buyMinimumFilled(buy_result, bought_atoms))
            return error.BuyDidNotFillMinimum;
    }
    const cleanup_atoms = try currentNetBtc(decision_owner);
    if (cleanup_atoms < min_quantity_atoms) return error.NoCleanableBtc;
    const cleanup_prices = try demoBookPrices(decision_owner);
    const cleanup_limits = try priceLimits(init, transport);
    const sell_price = try protectedSellPrice(cleanup_prices, cleanup_limits);
    const cleanup = try emitDemoIntent(init, policy, decision_owner, &authority, &lease, &have_lease, .sell, true, cleanup_atoms, sell_price);
    const cleanup_wire_client_order_id = try sendDemoCommand(init, decision_owner, gateway, &guard, adapter, projection, cleanup.command_id);
    const cleaned = try waitForOrder(init, transport, implementation, projection, decision_owner, cleanup_wire_client_order_id.slice());
    var remaining_atoms = try currentNetBtc(decision_owner);
    if (privateRestRefreshRequired(cleaned, remaining_atoms == 0)) {
        try beginPrivateRestRefresh(implementation, decision_owner, projection);
        refreshPrivateRest(init, transport, implementation, reconciler) catch |err| {
            try drainDemo(adapter, decision_owner, projection);
            return err;
        };
        try drainDemo(adapter, decision_owner, projection);
        remaining_atoms = try currentNetBtc(decision_owner);
    }
    if (!cleanupConfirmed(cleaned, remaining_atoms, decision_owner.shard.oms.openOrdersClosed(), projection.has_unknown)) {
        gateway.latchAccount(demo_account);
        return error.CleanupUnconfirmed;
    }
    cleanup_needed = false;
    try progress(init.io, "authoritative_demo_cleanup");
}

fn establishPublicMarket(init: std.process.Init, key: []const u8, secret: []const u8, passphrase: []const u8, endpoint: curl.DemoEndpointProfile, raw: *RawSink, owner: *demo_authority.Owner) !void {
    var public_endpoint = endpoint;
    public_endpoint.private_ws_url = curl.demoPublicWsUrl();
    const transport = try init.gpa.create(curl.TransportOwner);
    defer init.gpa.destroy(transport);
    transport.* = try curl.TransportOwner.initWithEndpoint(try auth.Credentials.init(key, secret, passphrase), null, source_session + 1, public_endpoint);
    defer transport.deinit();
    const feed = try init.gpa.create(okx_market_feed.OkxMarketFeed);
    defer init.gpa.destroy(feed);
    feed.* = okx_market_feed.OkxMarketFeed.init(raw.interface());
    const adapter = feed.adapter();
    try adapter.start(.{ .venue = demo_venue, .environment = .demo, .subscription_set = 2, .config_version = 1, .session = source_session + 1, .output_capacity = market.max_events_per_ingress });
    try refresh(transport, init.io);
    const instruments = transport.request(.get, "/api/v5/public/instruments?instType=SPOT&instId=BTC-USDT", "");
    if (instruments.outcome != .response) return error.PublicInstrumentRequestUncertain;
    try feed.ingest(init.gpa, (try clock(init.io)).times, instruments.response.?);
    if (try adapter.tryDrain()) |batch| try owner.applyAdapterBatch(batch);
    if (owner.shard.canonical_market.get(okx_adapter.btc_usdt_spot) == null) return error.PublicInstrumentNotReady;
    try transport.wsConnect();
    const message_buffer = try init.gpa.alloc(u8, market.max_raw_frame_bytes);
    defer init.gpa.free(message_buffer);
    try transport.wsSend("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"instruments\",\"instType\":\"SPOT\",\"instId\":\"BTC-USDT\"}]}");
    try transport.wsSend("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"books\",\"instId\":\"BTC-USDT\"},{\"channel\":\"index-tickers\",\"instId\":\"BTC-USDT\"}]}");
    for (0..24) |_| {
        const message = (try receiveWithKeepalive(transport, message_buffer)) orelse continue;
        if (std.mem.indexOf(u8, message, "\"event\":\"error\"") != null) return error.PublicSubscriptionRejected;
        if (std.mem.indexOf(u8, message, "\"event\":\"subscribe\"") != null) continue;
        try feed.ingest(init.gpa, (try clock(init.io)).times, message);
        if (try adapter.tryDrain()) |batch| try owner.applyAdapterBatch(batch);
        const entry = owner.shard.canonical_market.get(okx_adapter.btc_usdt_spot);
        if (feed.decoder.isPublicMarketReady(.btc_usdt_spot) and entry != null and entry.?.index != null) return;
    }
    return error.PublicMarketNotReady;
}

fn emergencyAuthoritativeCleanup(init: std.process.Init, policy: demo_authority.Policy, transport: *curl.TransportOwner, implementation: *okx_adapter.OkxVenueAdapter, adapter: venue.VenueAdapter, owner: *demo_authority.Owner, projection: *DemoProjection, gateway: *execution.Gateway, guard: *failover.GatewayLeaseGuard, authority: anytype, lease: *failover.PrimaryLease, have_lease: *bool) !void {
    try beginPrivateRestRefresh(implementation, owner, projection);
    for (0..2) |_| {
        for (rest_endpoints) |endpoint| ingestRestEndpoint(init, transport, implementation, endpoint) catch |err| {
            try drainDemo(adapter, owner, projection);
            return err;
        };
    }
    try drainDemo(adapter, owner, projection);
    if (!owner.shard.oms.openOrdersClosed() or projection.has_unknown) {
        gateway.latchAccount(demo_account);
        return error.EmergencyStateUncertain;
    }
    const atoms = try currentNetBtc(owner);
    if (atoms < min_quantity_atoms) return;
    if (!demoTraceCapacityAvailable(owner.shard.trace.len, owner.shard.trace.events.len, demo_order_trace_reserve))
        return error.InsufficientDemoTraceCapacity;
    const prices = try demoBookPrices(owner);
    const limits = try priceLimits(init, transport);
    const price = try protectedSellPrice(prices, limits);
    const command = try emitDemoIntent(init, policy, owner, authority, lease, have_lease, .sell, true, atoms, price);
    _ = try sendDemoCommand(init, owner, gateway, guard, adapter, projection, command.command_id);
}

fn currentNetBtc(owner: *const demo_authority.Owner) !i64 {
    const quantity = (try owner.source()).currentNetExchangePosition(okx_adapter.btc_usdt_spot) orelse return error.MissingDemoPosition;
    return std.math.cast(i64, quantity.lots) orelse return error.InvalidDemoPosition;
}

fn canonicalSequence(owner: *const demo_authority.Owner, stream: u128) !u64 {
    for (owner.shard.canonical_ingress_cursors[0..owner.shard.canonical_ingress_cursor_count]) |cursor|
        if (cursor.identity.stream == stream) return cursor.identity.sequence;
    return error.MissingCanonicalCursor;
}

fn demoBookPrices(owner: *const demo_authority.Owner) !Prices {
    const entry = owner.shard.canonical_market.get(okx_adapter.btc_usdt_spot) orelse return error.PublicMarketNotReady;
    const book = entry.last_book orelse return error.PublicMarketNotReady;
    if (book.best_bid.ticks <= 0 or book.best_ask.ticks <= book.best_bid.ticks) return error.InvalidTicker;
    return .{ .bid_tenths = book.best_bid.ticks, .ask_tenths = book.best_ask.ticks };
}

fn requireNoPendingDemoOrders(init: std.process.Init, transport: *curl.TransportOwner) !void {
    try refresh(transport, init.io);
    const response = transport.request(.get, "/api/v5/trade/orders-pending?limit=20", "");
    if (response.outcome != .response or try restRowCount(init.gpa, response.response.?) != 0)
        return error.DemoPendingOrders;
}

fn drainDemo(adapter: venue.VenueAdapter, owner: *demo_authority.Owner, projection: *DemoProjection) !void {
    while (try adapter.tryDrain()) |batch| {
        try owner.applyAdapterBatch(batch);
        try projection.applyBatch(batch);
    }
}

fn emitDemoIntent(init: std.process.Init, policy: demo_authority.Policy, owner: *demo_authority.Owner, authority: anytype, lease: *failover.PrimaryLease, have_lease: *bool, side: strategy.Side, reduce_only: bool, quantity: i64, price_tenths: i128) !oms.Command {
    const now = (try clock(init.io)).times.monotonic_time_ns;
    if (have_lease.* and !lease.valid(now)) {
        try authority.revoke(lease);
        have_lease.* = false;
    }
    if (!have_lease.*) {
        lease.* = try authority.acquire(.{ .exchange_account = policy.exchange_account, .decision_domain = policy.decision_domain }, policy.node_identity, now);
        have_lease.* = true;
        const identity = try std.math.add(u64, owner.shard.authoritativeBarrier(), 1);
        _ = try owner.apply(.{ .core = .{ .identity = identity, .payload = .{ .primary_lease_granted = .{ .fencing_token = lease.token } } } });
    }
    const cursor = owner.shard.authoritativeBarrier();
    const authz: strategy.Authorization = .{ .strategy_identity = policy.strategy_identity, .config_version = policy.config_version, .activation_identity = policy.activation_identity, .activation_barrier = owner.shard.host_activation_barrier };
    const config: strategy.Config = .{ .schema_registry = 1, .decision_domain = policy.decision_domain, .session = .{ .fencing = lease.token, .shard = 0, .generation = 1 }, .authorization = authz };
    const subscriptions = [_]strategy.Subscription{strategy.Subscription.of(policy.strategy_identity, &.{ .mark_price, .l2_delta })};
    var host = try strategy.Gateway.init(config, &subscriptions);
    const now_i64 = std.math.cast(i64, now) orelse return error.ClockOutOfRange;
    try host.recordPublished(1, cursor, now_i64);
    try host.activate(&owner.shard, &owner.decision_journal);
    const intent_sequence = try std.math.add(u64, cursor, 1);
    var frame_buffer: [256]u8 = undefined;
    const frame = try strategy.encodeOutputOrderFrame(&frame_buffer, config, 1, cursor, intent_sequence, .{
        .instrument_identity = okx_adapter.btc_usdt_spot,
        .side = side,
        .time_in_force = .immediate_or_cancel,
        .portfolio_reduce_only = reduce_only,
        .quantity = quantity,
        .limit_price_micros = std.math.cast(i64, price_tenths * 100_000) orelse return error.InvalidTicker,
    });
    const intent = switch (host.ingest(frame, now_i64)) {
        .accepted => |value| value,
        .rejected => return error.DemoStrategyRejected,
    };
    return (try owner.apply(.{ .core = .{ .identity = intent_sequence, .monotonic_time = now, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = intent } } })) orelse error.DemoRiskRejected;
}

fn sendDemoCommand(init: std.process.Init, owner: *demo_authority.Owner, gateway: *execution.Gateway, guard: *failover.GatewayLeaseGuard, adapter: venue.VenueAdapter, projection: *DemoProjection, command_id: u64) !canonical.ClientOrderId {
    const now = (try clock(init.io)).times.monotonic_time_ns;
    const send_result = try owner.send(gateway, guard, command_id, now);
    if (send_result != .accepted) {
        try diagnostic(init.io, "venue_send_result", @tagName(send_result));
        return error.DemoNotSent;
    }
    var found = false;
    while (try adapter.tryDrain()) |batch| {
        for (batch.slice()) |record| switch (record.event) {
            .order_dispatch_result => |result| if (result.command == command_id) {
                try requireVenueAccepted(init.io, result, error.DemoNotSent, error.DemoRejected);
                found = true;
            },
            else => {},
        };
        try owner.applyAdapterBatch(batch);
        try projection.applyBatch(batch);
    }
    if (!found) return error.MissingDispatchResult;
    return gateway.acceptedClientOrderId(demo_account, command_id) orelse error.MissingDispatchIdentity;
}

const WaitResult = struct { terminal: bool = false, saw_balance: bool = false };

fn buyMinimumFilled(result: WaitResult, bought_atoms: i64) bool {
    return result.terminal and bought_atoms >= min_quantity_atoms;
}

test "Demo buy requires a terminal canonical observation with the minimum fill" {
    const terminal: WaitResult = .{ .terminal = true, .saw_balance = true };
    try std.testing.expect(!buyMinimumFilled(.{}, 0)); // not sent or submitted/Unknown
    try std.testing.expect(!buyMinimumFilled(terminal, 0)); // zero fill
    try std.testing.expect(!buyMinimumFilled(terminal, min_quantity_atoms - 1)); // partial fill
    try std.testing.expect(buyMinimumFilled(terminal, min_quantity_atoms)); // full bounded fill
}

fn cleanupConfirmed(result: WaitResult, remaining_atoms: i64, open_orders_closed: bool, has_unknown: bool) bool {
    return result.terminal and remaining_atoms == 0 and open_orders_closed and !has_unknown;
}

test "Demo cleanup only succeeds after terminal zero exposure and no open order or Unknown" {
    const complete: WaitResult = .{ .terminal = true, .saw_balance = true };
    try std.testing.expect(cleanupConfirmed(complete, 0, true, false));
    try std.testing.expect(!cleanupConfirmed(.{}, 0, true, false)); // partial or no terminal observation
    try std.testing.expect(!cleanupConfirmed(complete, 1, true, false)); // partial cleanup
    try std.testing.expect(!cleanupConfirmed(complete, 0, false, false)); // open order
    try std.testing.expect(!cleanupConfirmed(complete, 0, true, true)); // Unknown

    var gateway: execution.Gateway = .{};
    gateway.routes[0] = .{ .account = demo_account, .adapter = undefined, .capability = undefined };
    gateway.count = 1;
    gateway.latchAccount(demo_account);
    try std.testing.expectEqual(execution.LatchedSafetyGate.latched, gateway.routes[0].safety_gate);
}

fn privateRestRefreshRequired(result: WaitResult, balance_confirmed: bool) bool {
    return !result.terminal or !result.saw_balance or !balance_confirmed;
}

fn demoTraceCapacityAvailable(current: usize, capacity: usize, required: usize) bool {
    return current <= capacity and required <= capacity - current;
}

test "Demo trace capacity is reserved before external effects" {
    try std.testing.expect(!demoTraceCapacityAvailable(63, 64, 2));
    try std.testing.expect(demoTraceCapacityAvailable(32, 64, 32));
}

/// Test-only transport for the runner's offline lifecycle matrix.  A
/// `proven_before_send` result reaches the boundary but deliberately records
/// no write; qualification and capacity rejections do not reach it at all.
const OfflineTransport = struct {
    const Step = struct { outcome: order.TransportOutcome, response: ?[]const u8 = null };

    steps: [4]Step = @splat(.{ .outcome = .proven_before_send }),
    step_count: u8 = 0,
    next_step: u8 = 0,
    calls: u8 = 0,
    writes_sent: u8 = 0,

    fn interface(self: *OfflineTransport) live.Transport {
        return .{ .ptr = self, .submit_fn = submit };
    }

    fn submit(ptr: *anyopaque, _: []const u8, _: []const u8) live.TransportResult {
        const self: *OfflineTransport = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.next_step < self.step_count);
        const step = self.steps[self.next_step];
        self.next_step += 1;
        self.calls += 1;
        if (step.outcome != .proven_before_send) self.writes_sent += 1;
        return .{
            .outcome = step.outcome,
            .response = step.response,
            .source_session = source_session,
            .times = .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1 },
        };
    }
};

fn offlineAuthorizedCommand() live.AuthorizedCommand {
    return .{
        .reserved_notional_usdt_micros = 1_000_000,
        .command = .{
            .command_id = 1,
            .order_id = 2,
            .order_revision = 1,
            .shard_sequence = 3,
            .instrument = .btc_usdt_spot,
            .client_order_id = order.clientOrderId(2),
            .venue_order_id = null,
            .capability_version = 1,
            .rules_version = 1,
            .config_version = 1,
            .gateway_session = source_session,
            .dispatch_deadline_monotonic_ns = 100,
            .risk_reservation_id = 4,
            .payload = .{ .place = .{
                .side = .buy,
                .kind = .limit_ioc,
                .quantity = .{ .coefficient = 1, .scale = 4 },
                .limit_price = .{ .coefficient = 50_000, .scale = 0 },
                .market_protection_price = null,
                .portfolio_reduce_only = false,
                .venue_reduce_only = false,
            } },
        },
    };
}

test "offline Demo transport lifecycle fails closed before an unarmed or replay write" {
    const Case = struct {
        step: OfflineTransport.Step,
        state: order.DispatchState,
        writes_sent: u8,
    };
    const cases = [_]Case{
        .{ .step = .{ .outcome = .proven_before_send }, .state = .not_sent, .writes_sent = 0 },
        .{ .step = .{ .outcome = .response, .response = "{\"code\":\"0\",\"data\":[{\"sCode\":\"0\",\"ordId\":\"1\"}]}" }, .state = .submitted, .writes_sent = 1 },
        .{ .step = .{ .outcome = .write_or_response_uncertain }, .state = .unknown, .writes_sent = 1 },
    };
    const commands = [_]live.AuthorizedCommand{offlineAuthorizedCommand()};
    for (cases) |case| {
        var transport: OfflineTransport = .{};
        transport.steps[0] = case.step;
        transport.step_count = 1;
        var raw: RawSink = .{};
        var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualified(), .raw_sink = raw.interface(), .transport = transport.interface() };
        const attempt = try chain.dispatch(std.testing.allocator, &commands);
        try std.testing.expectEqual(case.state, attempt.dispatch.items[0].state);
        try std.testing.expectEqual(case.writes_sent, transport.writes_sent);
        if (case.state == .unknown) {
            try std.testing.expectError(error.UncertainOrderBlocksSend, chain.dispatch(std.testing.allocator, &commands));
            try std.testing.expectEqual(case.writes_sent, transport.writes_sent);
        }
    }

    for ([_]live.RunMode{ .replay, .demo_dry_run }) |mode| {
        var transport: OfflineTransport = .{};
        var raw: RawSink = .{};
        var chain: live.Chain = .{ .mode = mode, .qualification = qualified(), .raw_sink = raw.interface(), .transport = transport.interface() };
        try std.testing.expectError(error.SideEffectsDisabled, chain.dispatch(std.testing.allocator, &commands));
        try std.testing.expectEqual(@as(u8, 0), transport.writes_sent);
    }

    var transport: OfflineTransport = .{};
    var raw: RawSink = .{};
    var unarmed: live.Chain = .{ .mode = .demo_live, .qualification = qualified(), .raw_sink = raw.interface(), .transport = transport.interface() };
    unarmed.qualification.cleanup_armed = false;
    try std.testing.expectError(error.DemoNotQualified, unarmed.dispatch(std.testing.allocator, &commands));
    try std.testing.expectEqual(@as(u8, 0), transport.calls);
    try std.testing.expectEqual(@as(u8, 0), transport.writes_sent);
}

const RawOwnerResult = struct { digest: [32]u8, raw_count: u64 };

fn checkOkxRawPrivateOwner(store: durable.Store, io: std.Io) !RawOwnerResult {
    var parsed = try demo_authority.Policy.parse(std.testing.allocator,
        \\{"schema":3,"lot_size":{"coefficient":1,"scale":8},"price_tick_atoms":100000,"startup":"virgin","exchange_account":2,"portfolio_identity":1,"strategy_identity":40,"activation_identity":50,"config_version":1,"portfolio_allocation_atoms":20000000,"risk_limit_atoms":15000000,"decision_stream_id":91,"dispatch_stream_id":92,"decision_domain":1,"node_identity":1}
    );
    defer parsed.deinit();
    const owner = try std.testing.allocator.create(demo_authority.Owner);
    defer std.testing.allocator.destroy(owner);
    owner.* = try demo_authority.Owner.bootstrap(store, io, .{ .domain = .decision_log, .id = 91 });
    try @import("venue_adapter_contract.zig").activateTestAssets(owner);
    var raw = try raw_ingress.DurableSink.init(store, io, .{ .domain = .raw_ingress, .id = 93 });
    var transport: OfflineTransport = .{};
    transport.steps[0] = .{ .outcome = .response, .response = "{\"code\":\"0\",\"data\":[{\"sCode\":\"0\",\"ordId\":\"1001\"}]}" };
    transport.step_count = 1;
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualified(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock_source: AdapterClock = .{};
    const reconciler = try std.testing.allocator.create(private.Reconciler);
    defer std.testing.allocator.destroy(reconciler);
    reconciler.* = .{};
    const implementation = try std.testing.allocator.create(okx_adapter.OkxVenueAdapter);
    defer std.testing.allocator.destroy(implementation);
    implementation.* = okx_adapter.OkxVenueAdapter.init(std.testing.allocator, &chain, clock_source.interface(), demoProfile(), demoRules());
    implementation.attachPrivateReconciler(reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = demo_venue, .environment = .demo, .exchange_account = demo_account, .adapter_session = source_session, .request_capacity = 4, .output_capacity = 4, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
    try implementation.beginPrivateSession();
    const times: private.Times = .{ .receive_time_utc_ns = 1_800_000_000_000_000_001, .monotonic_time_ns = 10_000_001, .wall_time_utc_ns = 1_800_000_000_000_000_002 };
    const ws_bootstrap = [_][]const u8{
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
    for (ws_bootstrap) |frame| try std.testing.expect((try implementation.ingestPrivateWs(times, frame)).rejection == null);
    const started = try startPrivateRestRefresh(implementation, 1);
    try owner.applyAdapterBatch(started);
    const sources = [_]private.IngressSource{ .rest_account_config, .rest_leverage, .rest_balance, .rest_positions, .rest_orders_pending, .rest_orders_history_spot, .rest_orders_history_swap, .rest_fills_history_spot, .rest_fills_history_swap };
    const rest_frames = [_][]const u8{
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
    for (0..2) |_| {
        for (sources, rest_frames) |source, frame| {
            const batch = try implementation.ingestPrivateRest(times, source, .{ .final = true }, frame);
            try std.testing.expect(batch.rejection == null);
        }
        while (try adapter.tryDrain()) |batch| try owner.applyAdapterBatch(batch);
    }
    while (try adapter.tryDrain()) |batch| try owner.applyAdapterBatch(batch);
    try std.testing.expect(owner.shard.canonical_account.valid);

    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try parsed.value.initializePendingHost(owner, 50_000_000, &guard, 1, source_session);
    try parsed.value.activateHost(owner, .{ .fencing = lease.token, .shard = 0, .generation = 1 }, owner.shard.authoritativeBarrier(), owner.shard.canonicalStateDigest());

    const feed = try std.testing.allocator.create(okx_market_feed.OkxMarketFeed);
    defer std.testing.allocator.destroy(feed);
    feed.* = okx_market_feed.OkxMarketFeed.init(raw.interface());
    const market_adapter = feed.adapter();
    try market_adapter.start(.{ .venue = demo_venue, .environment = .demo, .subscription_set = 2, .config_version = 1, .session = 2, .output_capacity = market.max_events_per_ingress });
    const public_frames = [_][]const u8{
        \\{"arg":{"channel":"instruments","instType":"SPOT"},"data":[{"instType":"SPOT","instId":"BTC-USDT","state":"live","ruleType":"normal","tickSz":"0.1","lotSz":"0.00000001","minSz":"0.00001","maxLmtSz":"100","maxMktSz":"10","maxLmtAmt":"1000000","maxMktAmt":"100000","ctType":"","ctVal":"","ctValCcy":"","settleCcy":"","tradeQuoteCcyList":["USDT"],"upcChg":[],"ts":"1800000000000"}]}
        ,
        \\{"arg":{"channel":"books","instId":"BTC-USDT"},"action":"snapshot","data":[{"asks":[["50100.1","2.0","0","3"]],"bids":[["50099.9","1.5","0","2"]],"ts":"1800000000000","seqId":"100","prevSeqId":"-1","checksum":0}]}
        ,
        \\{"arg":{"channel":"index-tickers","instId":"BTC-USDT"},"data":[{"instId":"BTC-USDT","idxPx":"50120.1","ts":"1800000000200"}]}
    };
    const public_times: market.Times = .{ .receive_time_utc_ns = times.receive_time_utc_ns, .monotonic_time_ns = times.monotonic_time_ns, .wall_time_utc_ns = times.wall_time_utc_ns };
    for (public_frames) |frame| {
        try feed.ingest(std.testing.allocator, public_times, frame);
        if (try market_adapter.tryDrain()) |batch| try owner.applyAdapterBatch(batch);
    }
    try std.testing.expect(owner.shard.canonical_market.get(okx_adapter.btc_usdt_spot) != null);

    const gateway = try std.testing.allocator.create(execution.Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.* = .{};
    try gateway.add(.{ .account = demo_account, .adapter = adapter, .venue_identity = demo_venue, .environment = .demo, .lease_guard = &guard, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = source_session, .supports_post_only = true, .supports_market_protection = true } });
    try gateway.bootstrapDurableDispatch(store, io, .{ .domain = .control, .id = 92 });
    const sequence = try std.math.add(u64, owner.shard.authoritativeBarrier(), 1);
    const intent: strategy.OrderIntent = .{
        .strategy_identity = 40,
        .intent_sequence = sequence,
        .strategy_cursor = owner.shard.authoritativeBarrier(),
        .config_version = 1,
        .activation_identity = 50,
        .portfolio_identity = 1,
        .exchange_account_identity = 2,
        .instrument_identity = okx_adapter.btc_usdt_spot,
        .side = .buy,
        .order_type = .limit,
        .time_in_force = .immediate_or_cancel,
        .portfolio_reduce_only = false,
        .quantity = 20_000,
        .limit_price_micros = 50_100_100_000,
    };
    const command = (try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = intent } } })) orelse return error.MissingDemoCommand;
    var snapshot_storage: [durable.max_snapshot_bytes]u8 = undefined;
    const snapshot = try owner.committedSnapshot(&snapshot_storage);
    const decision_barrier = owner.shard.authoritativeBarrier();
    const decision_digest = owner.shard.canonicalStateDigest();
    try std.testing.expectError(error.DecisionSnapshotMismatch, demo_authority.sendFromCommittedSnapshot(
        snapshot,
        try std.math.add(u64, decision_barrier, 1),
        decision_digest,
        gateway,
        &guard,
        command.command_id,
        2,
    ));
    try std.testing.expectEqual(@as(u8, 0), transport.writes_sent);
    try std.testing.expectEqual(venue.SendResult.accepted, try demo_authority.sendFromCommittedSnapshot(
        snapshot,
        decision_barrier,
        decision_digest,
        gateway,
        &guard,
        command.command_id,
        2,
    ));
    try std.testing.expectEqual(@as(u8, 1), transport.writes_sent);
    const wire_client_order_id = gateway.acceptedClientOrderId(demo_account, command.command_id) orelse return error.MissingDispatchIdentity;
    try std.testing.expect(!std.mem.eql(u8, wire_client_order_id.slice(), command.client_order_id.slice()));
    var saw_dispatch = false;
    while (try adapter.tryDrain()) |batch| {
        for (batch.slice()) |record| if (record.event == .order_dispatch_result) {
            try std.testing.expectEqual(canonical.DispatchState.submitted, record.event.order_dispatch_result.state);
            saw_dispatch = true;
        };
        try owner.applyAdapterBatch(batch);
    }
    try std.testing.expect(saw_dispatch);

    var order_frame: [768]u8 = undefined;
    const filled_order = try std.fmt.bufPrint(&order_frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"ioc","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0002","px":"50100.1","accFillSz":"0.0002","avgPx":"50100.1","uTime":"1800000000100","tradeId":"2001","fillSz":"0.0002","fillPx":"50100.1","fillFee":"-0.000001","fillFeeCcy":"USDT","fillTime":"1800000000100","execType":"T"}}]}}
    , .{wire_client_order_id.slice()});
    try std.testing.expect((try implementation.ingestPrivateWs(times, filled_order)).rejection == null);
    try std.testing.expect((try implementation.ingestPrivateWs(times,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000101","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"0","details":[{"ccy":"USDT","cashBal":"14.979979","availBal":"14.979979","eq":"14.979979","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"},{"ccy":"BTC","cashBal":"0.0002","availBal":"0.0002","eq":"0.0002","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    )).rejection == null);
    var saw_report = false;
    var saw_fill = false;
    var saw_fee = false;
    var saw_account = false;
    while (try adapter.tryDrain()) |batch| {
        for (batch.slice()) |record| switch (record.event) {
            .execution_report => saw_report = true,
            .fill => |fill| {
                saw_fill = true;
                saw_fee = fill.fee != null and fill.fee.?.atoms == 1;
            },
            .account_observed => saw_account = true,
            else => {},
        };
        try owner.applyAdapterBatch(batch);
    }
    try std.testing.expect(saw_report and saw_fill and saw_fee and saw_account and !implementation.private_failed);
    try std.testing.expectEqual(oms.OrderState.filled, owner.shard.oms.orderById(command.order_id).?.state);
    try std.testing.expectEqual(@as(i64, 20_000), owner.shard.economicSummary().portfolio.spot.quantity);
    const settled_digest = owner.shard.canonicalStateDigest();
    try std.testing.expect((try implementation.ingestPrivateWs(times, filled_order)).rejection == null);
    while (try adapter.tryDrain()) |batch| try owner.applyAdapterBatch(batch);
    try std.testing.expectEqualSlices(u8, &settled_digest, &owner.shard.canonicalStateDigest());
    const recovered = try demo_authority.Owner.recover(store, io, .{ .domain = .decision_log, .id = 91 });
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    try std.testing.expect(raw.next_sequence > 1);
    return .{ .digest = settled_digest, .raw_count = raw.next_sequence - 1 };
}

test "OKX raw private report and Fill reach the committed Demo owner" {
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            const memory = std.testing.allocator.create(durable.MemoryAdapter) catch |err| {
                self.failure = err;
                return;
            };
            defer std.testing.allocator.destroy(memory);
            memory.* = .init();
            _ = checkOkxRawPrivateOwner(memory.interface(), undefined) catch |err| {
                self.failure = err;
            };
        }
    };
    var context = Context{};
    const worker = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Context.run, .{&context});
    worker.join();
    if (context.failure) |err| return err;
}

test "Windows file store reopens OKX private report and economic Fill" {
    if (builtin.os.tag != .windows) return;
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.check() catch |err| {
                self.failure = err;
            };
        }
        fn check(_: *@This()) !void {
            var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var path_buffer: [260]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "C:\\Windows\\Temp\\ringwin-okx-owner-{d}", .{std.Io.Clock.real.now(io).nanoseconds});
            try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
            defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
            var self_digest: [32]u8 = undefined;
            var raw_count: u64 = 0;
            {
                var file_store = try durable.WindowsFileAdapter.openWindowsVerification(io, path);
                defer file_store.close(io);
                const result = try checkOkxRawPrivateOwner(file_store.interface(), io);
                const dispatch = try file_store.interface().recover(io, .{ .domain = .control, .id = 92 });
                try std.testing.expect(dispatch.status == .ready and dispatch.committed_barrier >= 2);
                self_digest = result.digest;
                raw_count = result.raw_count;
            }
            var reopened = try durable.WindowsFileAdapter.openWindowsVerification(io, path);
            defer reopened.close(io);
            const recovered = try demo_authority.Owner.recover(reopened.interface(), io, .{ .domain = .decision_log, .id = 91 });
            try std.testing.expectEqual(oms.OrderState.filled, recovered.shard.oms.orders[0].state);
            try std.testing.expectEqual(@as(i64, 20_000), recovered.shard.economicSummary().portfolio.spot.quantity);
            try std.testing.expect(recovered.shard.canonical_account.valid);
            try std.testing.expect(recovered.shard.canonical_account.balance_count >= 2);
            try std.testing.expectEqualSlices(u8, &self_digest, &recovered.shard.canonicalStateDigest());
            try verifyRawIngressRecovery(reopened.interface(), io, raw_count);
        }
    };
    var context = Context{};
    const worker = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Context.run, .{&context});
    worker.join();
    if (context.failure) |err| return err;
}

fn verifyRawIngressRecovery(store: durable.Store, io: std.Io, expected_count: u64) !void {
    const recovered = try store.recover(io, .{ .domain = .raw_ingress, .id = 93 });
    try std.testing.expectEqual(expected_count, recovered.committed_barrier);
    try std.testing.expectEqual(expected_count, recovered.last_sequence);
    var replay_sink: RawSink = .{};
    const feed = try std.testing.allocator.create(okx_market_feed.OkxMarketFeed);
    defer std.testing.allocator.destroy(feed);
    feed.* = okx_market_feed.OkxMarketFeed.init(replay_sink.interface());
    const adapter = feed.adapter();
    try adapter.start(.{ .venue = demo_venue, .environment = .demo, .subscription_set = 2, .config_version = 1, .session = source_session + 1, .output_capacity = market.max_events_per_ingress });
    const replay_times: market.Times = .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1 };
    const bad_evidence: market.RawEvidenceRef = .{ .stream_sequence = 1, .sha256 = @splat(0) };
    try std.testing.expectError(error.SourceSessionMismatch, feed.replay(std.testing.allocator, source_session, replay_times, bad_evidence, "{}"));
    try std.testing.expectError(error.RawEvidenceMismatch, feed.replay(std.testing.allocator, source_session + 1, replay_times, bad_evidence, "{}"));
    const Counter = struct {
        count: u64 = 0,
        market_records: u64 = 0,
        feed: *okx_market_feed.OkxMarketFeed,
        adapter: @import("market_feed_adapter.zig").MarketFeedAdapter,
        fn consume(ptr: *anyopaque, sequence: u64, record: market.RawIngressRecord, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
            try std.testing.expectEqual(self.count, sequence);
            if (record.source_session == source_session) return;
            if (record.source_session != source_session + 1) return error.InvalidRawSourceSession;
            try self.feed.replay(std.testing.allocator, record.source_session, .{
                .receive_time_utc_ns = record.receive_time_utc_ns,
                .monotonic_time_ns = record.monotonic_time_ns,
                .wall_time_utc_ns = record.wall_time_utc_ns,
            }, .{ .stream_sequence = sequence, .sha256 = record.sha256 }, bytes);
            if (try self.adapter.tryDrain()) |batch| self.market_records += batch.slice().len;
        }
    };
    var counter: Counter = .{ .feed = feed, .adapter = adapter };
    try raw_ingress.replayCommitted(store, io, .{ .domain = .raw_ingress, .id = 93 }, .{
        .ptr = &counter,
        .consume_fn = Counter.consume,
    });
    try std.testing.expectEqual(expected_count, counter.count);
    try std.testing.expect(counter.market_records > 0);
    try std.testing.expectEqual(@as(u64, 0), replay_sink.count);
}

test "terminal order without its balance observation requires REST refresh" {
    try std.testing.expect(privateRestRefreshRequired(.{}, false));
    try std.testing.expect(privateRestRefreshRequired(.{ .terminal = true }, false));
    try std.testing.expect(!privateRestRefreshRequired(.{ .terminal = true, .saw_balance = true }, true));
}

const max_demo_records = 256;

const DemoProjection = struct {
    account: account_projection.AccountProjection = .{},
    fills: lifecycle.Projection = .{},
    records: [max_demo_records]canonical.EventRecord = undefined,
    record_count: u16 = 0,
    has_unknown: bool = false,

    fn drain(self: *DemoProjection, adapter: venue.VenueAdapter) !void {
        while (try adapter.tryDrain()) |batch| try self.applyBatch(batch);
    }

    fn applyBatch(self: *DemoProjection, batch: canonical.AdapterOutputBatch) !void {
        for (batch.slice()) |event_record| try self.apply(event_record, true);
    }

    fn apply(self: *DemoProjection, event_record: canonical.EventRecord, retain: bool) !void {
        switch (event_record.event) {
            .account_bootstrap_snapshot, .account_observed => try self.account.apply(event_record.event),
            .fill => _ = try self.fills.apply(event_record),
            .order_dispatch_result => |result| {
                if (result.state == .unknown) self.has_unknown = true;
            },
            .order_reconciliation_result, .account_reconciliation_result => |result| {
                if (result.status == .unresolved) self.has_unknown = true;
            },
            else => {},
        }
        if (!retain) return;
        if (self.record_count == self.records.len) return error.DemoRecordCapacity;
        self.records[self.record_count] = event_record;
        self.record_count += 1;
    }

    fn positionLots(self: *const DemoProjection) i128 {
        return self.fills.position_lots;
    }

    fn btcBalance(self: *const DemoProjection) ?i128 {
        for (self.account.balances[0..self.account.balance_count]) |balance|
            if (balance.asset == okx_adapter.btc) return balance.total.atoms;
        return null;
    }

    fn verifyReplay(self: *const DemoProjection) ![32]u8 {
        var replay: DemoProjection = .{};
        for (self.records[0..self.record_count]) |event_record|
            try replay.apply(event_record, false);
        const live_digest = self.digest();
        const replay_digest = replay.digest();
        if (!std.mem.eql(u8, &live_digest, &replay_digest)) return error.ReplayDigestMismatch;
        return replay_digest;
    }

    fn digest(self: *const DemoProjection) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(std.mem.asBytes(&self.fills.position_lots));
        hasher.update(std.mem.asBytes(&self.fills.fee_atoms));
        hasher.update(std.mem.asBytes(&self.fills.realized_pnl_atoms));
        hasher.update(std.mem.asBytes(&self.account.valid));
        for (self.account.balances[0..self.account.balance_count]) |balance| {
            hasher.update(std.mem.asBytes(&balance.asset));
            hasher.update(std.mem.asBytes(&balance.total.atoms));
            hasher.update(std.mem.asBytes(&balance.available.atoms));
            hasher.update(std.mem.asBytes(&balance.held.atoms));
        }
        hasher.update(std.mem.asBytes(&self.has_unknown));
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
};

fn hasNonzeroBtcBaseline(projection: *const DemoProjection) bool {
    return (projection.btcBalance() orelse 0) != 0;
}

test "missing BTC balance is a zero baseline" {
    var projection: DemoProjection = .{};
    try std.testing.expect(!hasNonzeroBtcBaseline(&projection));
}

test "Demo acceptance replays canonical Adapter output and rejects Unknown" {
    const envelope = canonical.EventEnvelope{
        .event_type = @intFromEnum(canonical.EventType.order_dispatch_result),
        .schema_version = canonical.schema_version,
        .identity = .{ .stream = 1, .sequence = 1 },
        .source_fact_identity = 1,
        .scope = .account,
        .venue = demo_venue,
        .exchange_account = demo_account,
        .source_stream = 1,
        .source_sequence = 1,
        .adapter_session = source_session,
        .times = .{ .monotonic_ns = 1 },
        .raw_evidence = .{ .stream = 1, .sequence = 1, .digest = @splat(0) },
    };
    var projection: DemoProjection = .{};
    try projection.apply(.{ .envelope = envelope, .event = .{ .order_dispatch_result = .{ .command = 1, .state = .submitted } } }, true);
    _ = try projection.verifyReplay();
    var unknown = envelope;
    unknown.identity.sequence = 2;
    unknown.source_fact_identity = 2;
    unknown.source_sequence = 2;
    try projection.apply(.{ .envelope = unknown, .event = .{ .order_dispatch_result = .{ .command = 2, .state = .unknown } } }, true);
    try std.testing.expect(projection.has_unknown);
}

fn waitForOrder(
    init: std.process.Init,
    owner: *curl.TransportOwner,
    implementation: *okx_adapter.OkxVenueAdapter,
    projection: *DemoProjection,
    decision_owner: ?*demo_authority.Owner,
    client_order_id: []const u8,
) !WaitResult {
    const message_buffer = try init.gpa.alloc(u8, market.max_raw_frame_bytes);
    defer init.gpa.free(message_buffer);
    var result: WaitResult = .{};
    for (0..12) |_| {
        const message = (try receiveWithKeepalive(owner, message_buffer)) orelse continue;
        const batch = try implementation.ingestPrivateWs((try clock(init.io)).times, message);
        if (batch.rejection) |reason| {
            while (try implementation.adapter().tryDrain()) |output| {
                if (decision_owner) |source| try source.applyAdapterBatch(output);
                try projection.applyBatch(output);
            }
            try diagnostic(init.io, "private_rejection", @tagName(reason));
            return error.PrivateIngressRejected;
        }
        if (batch.event_count != 0) return error.PrivateIngressEventsUnclaimed;
        if (try implementation.adapter().tryDrain()) |output| {
            for (output.slice()) |record| switch (record.event) {
                .execution_report => |report| {
                    if (std.mem.eql(u8, report.client_order_id.slice(), client_order_id))
                        result.terminal = report.status == .filled or report.status == .canceled;
                },
                .account_bootstrap_snapshot, .account_observed => result.saw_balance = true,
                else => {},
            };
            if (decision_owner) |source| try source.applyAdapterBatch(output);
            try projection.applyBatch(output);
        }
        if (result.terminal and result.saw_balance and !projection.has_unknown) return result;
    }
    return result;
}

fn establishReady(init: std.process.Init, owner: *curl.TransportOwner, implementation: *okx_adapter.OkxVenueAdapter, reconciler: *private.Reconciler, decision_owner: ?*demo_authority.Owner) !void {
    try implementation.beginPrivateSession();
    try owner.wsConnect();
    var stamp = try clock(init.io);
    try owner.wsLogin(stamp.secondsSlice());
    const message_buffer = try init.gpa.alloc(u8, market.max_raw_frame_bytes);
    defer init.gpa.free(message_buffer);
    var login_ok = false;
    for (0..8) |_| {
        const message = (try receiveWithKeepalive(owner, message_buffer)) orelse continue;
        const batch = try implementation.ingestPrivateWs((try clock(init.io)).times, message);
        if (batch.rejection != null) return error.PrivateIngressRejected;
        if (std.mem.indexOf(u8, message, "\"event\":\"login\"") != null) {
            login_ok = true;
            break;
        }
    }
    if (!login_ok) return error.MissingLoginAck;
    try owner.wsSend("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"orders\",\"instType\":\"ANY\"},{\"channel\":\"account\"},{\"channel\":\"positions\",\"instType\":\"ANY\"}]}");
    for (0..24) |_| {
        const message = (try receiveWithKeepalive(owner, message_buffer)) orelse continue;
        const batch = try implementation.ingestPrivateWs((try clock(init.io)).times, message);
        if (batch.rejection != null) return error.PrivateIngressRejected;
        if (reconciler.readiness().private_stream_ready) break;
    }
    if (!reconciler.readiness().private_stream_ready) return error.IncompletePrivateStream;
    try progress(init.io, "private_stream");
    const adapter = implementation.adapter();
    if (try adapter.trySend(.{ .account_reconciliation = .{ .identity = 1, .exchange_account = demo_account, .expected_session = source_session } }) != .accepted)
        return error.AdapterRejectedReconciliation;
    if (try adapter.tryDrain()) |output| if (decision_owner) |source| try source.applyAdapterBatch(output);
    try refreshPrivateRest(init, owner, implementation, reconciler);
    if (!reconciler.readiness().reconciliation_ready) return error.ReconciliationNotReady;
}

fn refreshPrivateRest(init: std.process.Init, owner: *curl.TransportOwner, implementation: *okx_adapter.OkxVenueAdapter, reconciler: *private.Reconciler) !void {
    for (0..2) |_| {
        for (rest_endpoints) |endpoint|
            try ingestRestEndpoint(init, owner, implementation, endpoint);
        _ = try reconciler.tryComplete();
    }
}

fn beginPrivateRestRefresh(implementation: *okx_adapter.OkxVenueAdapter, owner: *demo_authority.Owner, projection: *DemoProjection) !void {
    const started = try startPrivateRestRefresh(implementation, try std.math.add(u64, owner.shard.authoritativeBarrier(), 1));
    try owner.applyAdapterBatch(started);
    try projection.applyBatch(started);
}

fn startPrivateRestRefresh(implementation: *okx_adapter.OkxVenueAdapter, identity: u64) !canonical.AdapterOutputBatch {
    const adapter = implementation.adapter();
    if (try adapter.trySend(.{ .account_reconciliation = .{
        .identity = identity,
        .exchange_account = demo_account,
        .expected_session = source_session,
    } }) != .accepted) return error.AdapterRejectedReconciliation;
    return (try adapter.tryDrain()) orelse error.MissingAccountReconciliationStart;
}

test "private REST refresh starts account reconciliation before REST ingress" {
    const TestTransport = struct {
        fn interface(self: *@This()) @import("okx_live_chain.zig").Transport {
            return .{ .ptr = self, .submit_fn = submit };
        }
        fn submit(_: *anyopaque, _: []const u8, _: []const u8) @import("okx_live_chain.zig").TransportResult {
            unreachable;
        }
    };
    const TestClock = struct {
        fn interface(self: *@This()) okx_adapter.Clock {
            return .{ .ptr = self, .now_fn = now };
        }
        fn now(_: *anyopaque) u64 {
            return 1;
        }
    };
    var raw = RawSink{};
    var transport: TestTransport = .{};
    var chain: @import("okx_live_chain.zig").Chain = .{ .mode = .demo_live, .qualification = .{ .explicit_demo_live = true, .endpoint_is_demo = true, .simulated_header = true, .credentials_loaded = true, .clock_healthy = true, .account_qualified = true, .reconciliation_stable = true, .no_unknown_orders = true, .cleanup_armed = true }, .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock_source: TestClock = .{};
    var reconciler: private.Reconciler = .{};
    var implementation = okx_adapter.OkxVenueAdapter.init(std.testing.allocator, &chain, clock_source.interface(), demoProfile(), demoRules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = demo_venue, .environment = .demo, .exchange_account = demo_account, .adapter_session = source_session, .request_capacity = 4, .output_capacity = 4, .asset_definitions = try @import("venue_adapter_contract.zig").activatedTestAssets() });
    try implementation.beginPrivateSession();
    const frames = [_][]const u8{
        \\{"event":"subscribe","arg":{"channel":"orders","instType":"ANY"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"account"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"positions","instType":"ANY"}}
        ,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000000","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"25","details":[{"ccy":"USDT","cashBal":"25","availBal":"25","eq":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
        ,
        \\{"arg":{"channel":"positions"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[]}
    };
    const times: private.Times = .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 2, .wall_time_utc_ns = 3 };
    for (frames) |frame| try std.testing.expect((try implementation.ingestPrivateWs(times, frame)).rejection == null);
    const started = try startPrivateRestRefresh(&implementation, 1);
    try std.testing.expectEqual(@as(u8, 1), started.len);
    try std.testing.expectEqual(@as(u128, 1), started.events[0].event.account_reconciliation_started);
}

pub fn receiveWithKeepalive(owner: *curl.TransportOwner, buffer: []u8) !?[]u8 {
    const message = owner.wsReceive(buffer, 5_000) catch |err| switch (err) {
        error.WebSocketTimeout => {
            try owner.wsSend("ping");
            return null;
        },
        else => return err,
    };
    return if (std.mem.eql(u8, message, "pong")) null else message;
}

pub fn ingestRestEndpoint(
    init: std.process.Init,
    owner: *curl.TransportOwner,
    implementation: *okx_adapter.OkxVenueAdapter,
    endpoint: RestEndpoint,
) !void {
    var after: ?u64 = null;
    for (0..32) |_| {
        var path_buffer: [256]u8 = undefined;
        const path = if (after) |cursor|
            try std.fmt.bufPrint(&path_buffer, "{s}&after={d}", .{ endpoint.path, cursor })
        else
            endpoint.path;
        try refresh(owner, init.io);
        var response = owner.request(.get, path, "");
        for (0..5) |_| {
            if (response.outcome == .response) break;
            init.io.sleep(.fromNanoseconds(200 * std.time.ns_per_ms), .awake) catch {};
            try refresh(owner, init.io);
            response = owner.request(.get, path, "");
        }
        if (response.outcome != .response) {
            std.debug.print("rest_request_failed source={s} outcome={s}\n", .{ @tagName(endpoint.source), @tagName(response.outcome) });
            return error.PrivateRequestUncertain;
        }
        const row_count = restRowCount(init.gpa, response.response.?) catch 0;
        const final = endpoint.cursor == .none or row_count < endpoint.page_size;
        const batch = try implementation.ingestPrivateRest(
            (try clock(init.io)).times,
            endpoint.source,
            .{ .requested_after = after, .final = final },
            response.response.?,
        );
        if (batch.rejection) |reason| {
            try diagnostic(init.io, "rest_rejection_source", @tagName(endpoint.source));
            try diagnostic(init.io, "rest_rejection_reason", @tagName(reason));
            return error.RestBootstrapRejected;
        }
        if (final) return;
        after = batch.oldest_cursor orelse return error.MissingRestPageCursor;
    }
    return error.RestPageLimitExceeded;
}

fn restRowCount(gpa: std.mem.Allocator, raw: []const u8) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidRestPage,
    };
    const data = switch (root.get("data") orelse return error.InvalidRestPage) {
        .array => |value| value,
        else => return error.InvalidRestPage,
    };
    return data.items.len;
}

const Prices = struct { bid_tenths: i128, ask_tenths: i128 };
const PriceLimits = struct { buy_tenths: i128, sell_tenths: i128 };

fn ticker(init: std.process.Init, owner: *curl.TransportOwner) !Prices {
    try refresh(owner, init.io);
    const response = owner.request(.get, "/api/v5/market/ticker?instId=BTC-USDT", "");
    if (response.outcome != .response) return error.TickerUnavailable;
    const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, response.response.?, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidTicker,
    };
    const data = switch (root.get("data") orelse return error.InvalidTicker) {
        .array => |value| value,
        else => return error.InvalidTicker,
    };
    if (data.items.len != 1) return error.InvalidTicker;
    const row = switch (data.items[0]) {
        .object => |value| value,
        else => return error.InvalidTicker,
    };
    return .{
        .bid_tenths = try priceTenths(row.get("bidPx") orelse return error.InvalidTicker, false),
        .ask_tenths = try priceTenths(row.get("askPx") orelse return error.InvalidTicker, true),
    };
}

fn priceLimits(init: std.process.Init, owner: *curl.TransportOwner) !PriceLimits {
    try refresh(owner, init.io);
    const response = owner.request(.get, "/api/v5/public/price-limit?instId=BTC-USDT", "");
    if (response.outcome != .response) return error.PriceLimitUnavailable;
    const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, response.response.?, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidPriceLimit,
    };
    const data = switch (root.get("data") orelse return error.InvalidPriceLimit) {
        .array => |value| value,
        else => return error.InvalidPriceLimit,
    };
    if (data.items.len != 1) return error.InvalidPriceLimit;
    const row = switch (data.items[0]) {
        .object => |value| value,
        else => return error.InvalidPriceLimit,
    };
    const enabled = switch (row.get("enabled") orelse return error.InvalidPriceLimit) {
        .bool => |value| value,
        else => return error.InvalidPriceLimit,
    };
    if (!enabled) return error.PriceLimitDisabled;
    return .{
        .buy_tenths = try priceTenths(row.get("buyLmt") orelse return error.InvalidPriceLimit, false),
        .sell_tenths = try priceTenths(row.get("sellLmt") orelse return error.InvalidPriceLimit, true),
    };
}

fn protectedBuyPrice(prices: Prices, limits: PriceLimits) !i128 {
    const price = @min(ceilDiv(prices.ask_tenths * 1_001, 1_000), limits.buy_tenths);
    if (price < prices.ask_tenths) return error.NoExecutableBuyPrice;
    return price;
}

fn protectedSellPrice(prices: Prices, limits: PriceLimits) !i128 {
    const price = @max(@divFloor(prices.bid_tenths * 999, 1_000), limits.sell_tenths);
    if (price > prices.bid_tenths) return error.NoExecutableSellPrice;
    return price;
}

/// A fresh executable IOC price for the Windows process-chain Demo order.
/// The same source is checked again by the execution role just before send.
pub fn windowsProtectedPrice(init: std.process.Init, owner: *curl.TransportOwner, side: strategy.Side, quantity_atoms: i64) !i64 {
    const prices = try ticker(init, owner);
    const limits = try priceLimits(init, owner);
    const tenths = if (side == .buy) try protectedBuyPrice(prices, limits) else try protectedSellPrice(prices, limits);
    try requireNotional(quantity_atoms, tenths);
    return std.math.cast(i64, tenths * 100_000) orelse error.InvalidTicker;
}

pub fn windowsPriceStillExecutable(init: std.process.Init, owner: *curl.TransportOwner, side: strategy.Side, quantity_atoms: i64, price_micros: i64) !void {
    const prices = try ticker(init, owner);
    const limits = try priceLimits(init, owner);
    if (price_micros <= 0 or @mod(price_micros, 100_000) != 0) return error.InvalidDemoPrice;
    const tenths = @divExact(@as(i128, price_micros), 100_000);
    try requireNotional(quantity_atoms, tenths);
    if (side == .buy) {
        if (tenths < prices.ask_tenths or tenths > try protectedBuyPrice(prices, limits)) return error.StaleDemoPrice;
    } else if (tenths > prices.bid_tenths or tenths < try protectedSellPrice(prices, limits)) return error.StaleDemoPrice;
}

test "Demo price protection rejects non-executable limits" {
    const prices: Prices = .{ .bid_tenths = 1_000, .ask_tenths = 1_010 };
    try std.testing.expectError(error.NoExecutableBuyPrice, protectedBuyPrice(prices, .{ .buy_tenths = 1_009, .sell_tenths = 990 }));
    try std.testing.expectError(error.NoExecutableSellPrice, protectedSellPrice(prices, .{ .buy_tenths = 1_020, .sell_tenths = 1_001 }));
    try std.testing.expectEqual(@as(i128, 1_012), try protectedBuyPrice(prices, .{ .buy_tenths = 1_020, .sell_tenths = 990 }));
    try std.testing.expectEqual(@as(i128, 999), try protectedSellPrice(prices, .{ .buy_tenths = 1_020, .sell_tenths = 990 }));
}

fn priceTenths(value: std.json.Value, round_up: bool) !i128 {
    const text = switch (value) {
        .string => |bytes| bytes,
        else => return error.InvalidTicker,
    };
    const decimal = try order.Decimal.parse(text);
    if (decimal.coefficient <= 0) return error.InvalidTicker;
    if (decimal.scale <= 1) return decimal.coefficient * try pow10(1 - decimal.scale);
    const divisor = try pow10(decimal.scale - 1);
    return if (round_up) ceilDiv(decimal.coefficient, divisor) else @divFloor(decimal.coefficient, divisor);
}

fn requireNotional(quantity_atoms: i64, price_tenths: i128) !void {
    const micros = @divFloor(@as(i128, quantity_atoms) * price_tenths, 1_000);
    if (micros <= 0 or micros > live.max_notional_usdt_micros) return error.NotionalLimitExceeded;
}

fn requireVenueAccepted(io: std.Io, item: canonical.OrderDispatchResult, not_sent: anyerror, rejected: anyerror) !void {
    if (item.reason) |reason| {
        try diagnostic(io, "canonical_reject_reason", @tagName(reason));
        if (item.state == .not_sent) return switch (reason) {
            .capability_unsupported => error.DemoCapabilityUnsupported,
            .unsupported_instrument => error.DemoUnsupportedInstrument,
            .unsupported_value => error.DemoUnsupportedValue,
            .stale_version => error.DemoStaleVersion,
            .deadline_expired => error.DemoDeadlineExpired,
            .adapter_backpressure => error.DemoAdapterBackpressure,
            .venue_unavailable => error.DemoVenueUnavailable,
            .other_venue_reject => error.DemoVenueRejected,
        };
        return rejected;
    }
    if (item.state == .not_sent) return not_sent;
    if (item.state != .submitted) return error.DispatchUnknown;
}

fn diagnostic(io: std.Io, name: []const u8, value: []const u8) !void {
    var buffer: [160]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buffer);
    try out.interface.print("{s}={s}\n", .{ name, value });
    try out.interface.flush();
}

pub const Clock = struct {
    timestamp: [32]u8,
    timestamp_len: u8,
    seconds: [20]u8,
    seconds_len: u8,
    times: market.Times,
    pub fn timestampSlice(self: *const Clock) []const u8 {
        return self.timestamp[0..self.timestamp_len];
    }
    pub fn secondsSlice(self: *const Clock) []const u8 {
        return self.seconds[0..self.seconds_len];
    }
};

pub fn clock(io: std.Io) !Clock {
    const real_ns = std.math.cast(i64, std.Io.Clock.real.now(io).nanoseconds) orelse return error.ClockOutOfRange;
    const monotonic_ns = std.math.cast(i64, std.Io.Clock.awake.now(io).nanoseconds) orelse return error.ClockOutOfRange;
    if (real_ns <= 0 or monotonic_ns <= 0) return error.ClockUnavailable;
    const epoch_seconds: u64 = @intCast(@divFloor(real_ns, std.time.ns_per_s));
    const milliseconds: u16 = @intCast(@divFloor(@mod(real_ns, std.time.ns_per_s), std.time.ns_per_ms));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    var result: Clock = .{
        .timestamp = undefined,
        .timestamp_len = 0,
        .seconds = undefined,
        .seconds_len = 0,
        .times = .{
            .receive_time_utc_ns = @intCast(real_ns),
            .monotonic_time_ns = @intCast(monotonic_ns),
            .wall_time_utc_ns = @intCast(real_ns),
        },
    };
    const timestamp = try std.fmt.bufPrint(&result.timestamp, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,                 month_day.month.numeric(),        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute(),
        milliseconds,
    });
    if (timestamp.len != 24) return error.ClockFormat;
    result.timestamp_len = @intCast(timestamp.len);
    const seconds = try std.fmt.bufPrint(&result.seconds, "{d}", .{epoch_seconds});
    result.seconds_len = @intCast(seconds.len);
    return result;
}

pub fn refresh(owner: *curl.TransportOwner, io: std.Io) !void {
    const stamp = try clock(io);
    try owner.prepare(stamp.timestampSlice(), stamp.times);
}

const RunMode = enum { prepare_only, demo_live, cleanup_only };

fn runMode(init: std.process.Init) !RunMode {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const flag = args.next() orelse return error.ExplicitModeRequired;
    if (args.next() != null) return error.ExplicitModeRequired;
    if (std.mem.eql(u8, flag, "--demo-live")) return .demo_live;
    if (std.mem.eql(u8, flag, "--prepare-only")) return .prepare_only;
    if (std.mem.eql(u8, flag, "--cleanup-only")) return .cleanup_only;
    return error.ExplicitModeRequired;
}

fn progress(io: std.Io, phase: []const u8) !void {
    var buffer: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.print("phase={s} ok\n", .{phase});
    try out.interface.flush();
}

pub fn qualified() live.Qualification {
    return .{
        .explicit_demo_live = true,
        .endpoint_is_demo = true,
        .simulated_header = true,
        .credentials_loaded = true,
        .clock_healthy = true,
        .account_qualified = true,
        .reconciliation_stable = true,
        .no_unknown_orders = true,
        .cleanup_armed = true,
    };
}

const AdapterClock = struct {
    fn interface(self: *AdapterClock) okx_adapter.Clock {
        return .{ .ptr = self, .now_fn = now };
    }

    fn now(_: *anyopaque) u64 {
        return 1;
    }
};

pub fn demoProfile() order.CapabilityProfile {
    return .{
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .gateway_session = source_session,
        .qualification = .demo_qualified,
        .batch_max = 4,
        .place_limit = .{ .requests = 4, .window_ns = 1 },
        .place_batch_limit = .{ .requests = 4, .window_ns = 1 },
        .amend_limit = .{ .requests = 4, .window_ns = 1 },
        .amend_batch_limit = .{ .requests = 4, .window_ns = 1 },
        .cancel_limit = .{ .requests = 4, .window_ns = 1 },
        .cancel_batch_limit = .{ .requests = 4, .window_ns = 1 },
        .subaccount_place_amend_limit = .{ .requests = 4, .window_ns = 1 },
        .limit = true,
        .protected_market_ioc = true,
        .ioc = true,
        .fok = true,
        .native_amend = true,
        .native_post_only = true,
        .swap_venue_reduce_only = true,
    };
}

pub fn demoRules() okx_adapter.Rules {
    return .{
        .spot = .{ .identity = okx_adapter.btc_usdt_spot, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 8 } },
        .swap = .{ .identity = okx_adapter.btc_usdt_swap, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 2 } },
    };
}

fn pow10(exponent: u8) !i128 {
    var value: i128 = 1;
    for (0..exponent) |_| value = try std.math.mul(i128, value, 10);
    return value;
}

fn ceilDiv(value: i128, divisor: i128) i128 {
    return @divFloor(value + divisor - 1, divisor);
}

const RawSink = struct {
    count: u64 = 0,
    fn interface(self: *RawSink) market.RawSink {
        return .{ .ptr = self, .append_fn = append };
    }
    fn append(ptr: *anyopaque, value: market.RawIngressRecord, bytes: []const u8) market.RawSinkError!u64 {
        const self: *RawSink = @ptrCast(@alignCast(ptr));
        if (value.byte_len != bytes.len) return error.Unavailable;
        self.count += 1;
        return self.count;
    }
};
