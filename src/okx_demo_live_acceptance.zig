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
const failover = @import("failover.zig");
const oms = @import("oms.zig");
const strategy = @import("strategy_host_gateway.zig");
const venue = @import("venue_adapter.zig");

const buy_quantity_atoms: i64 = 20_000; // 0.0002 BTC; Demo minimum plus exact 1e-8 fee/quote projection
const min_quantity_atoms: i64 = 1_000; // current BTC-USDT minSz 0.00001
const source_session: u64 = 1;
const demo_venue: canonical.VenueIdentity = 1;
const demo_account: canonical.ExchangeAccountIdentity = 2;

const RestEndpoint = struct {
    source: private.IngressSource,
    path: []const u8,
    cursor: enum { none, order_id, bill_id } = .none,
};

const rest_endpoints = [_]RestEndpoint{
    .{ .source = .rest_account_config, .path = "/api/v5/account/config" },
    .{ .source = .rest_leverage, .path = "/api/v5/account/leverage-info?instId=BTC-USDT-SWAP&mgnMode=isolated" },
    .{ .source = .rest_balance, .path = "/api/v5/account/balance?ccy=BTC,USDT" },
    .{ .source = .rest_positions, .path = "/api/v5/account/positions?instId=BTC-USDT-SWAP" },
    .{ .source = .rest_orders_pending, .path = "/api/v5/trade/orders-pending?limit=20", .cursor = .order_id },
    .{ .source = .rest_orders_history_spot, .path = "/api/v5/trade/orders-history?instType=SPOT&limit=20", .cursor = .order_id },
    .{ .source = .rest_orders_history_swap, .path = "/api/v5/trade/orders-history?instType=SWAP&limit=20", .cursor = .order_id },
    .{ .source = .rest_fills_history_spot, .path = "/api/v5/trade/fills-history?instType=SPOT&limit=20", .cursor = .bill_id },
    .{ .source = .rest_fills_history_swap, .path = "/api/v5/trade/fills-history?instType=SWAP&limit=20", .cursor = .bill_id },
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
    const endpoint = try curl.demoEndpointProfile(rest_base_url, entity);

    var runtime = try curl.Runtime.init();
    defer runtime.deinit();
    var owner = try curl.TransportOwner.initWithEndpoint(
        try auth.Credentials.init(key, secret, passphrase),
        null,
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
    const baseline_btc_atoms = projection.btcBalance() orelse return error.MissingBaselineBtc;
    try progress(init.io, "baseline");

    if (baseline_btc_atoms != 0) return error.NonzeroBaselineBtc;

    const prices = try ticker(init, &owner);
    const limits = try priceLimits(init, &owner);
    const buy_price_tenths = try protectedBuyPrice(prices, limits);
    try requireNotional(buy_quantity_atoms, buy_price_tenths);
    try progress(init.io, "observation_only");
}

fn readDemoPolicy(init: std.process.Init) !std.json.Parsed(demo_authority.Policy) {
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
    const decision_owner = try init.gpa.create(demo_authority.Owner);
    defer init.gpa.destroy(decision_owner);
    decision_owner.* = switch (policy.startup) {
        .virgin => try demo_authority.Owner.bootstrap(file_store.interface(), init.io, decision_stream),
        .recover => try demo_authority.Owner.recover(file_store.interface(), init.io, decision_stream),
    };
    if (policy.startup == .recover and
        (decision_owner.shard.exchange_account_identity != policy.exchange_account or
            decision_owner.shard.portfolio_identity != policy.portfolio_identity or
            decision_owner.shard.strategy_identity != policy.strategy_identity or
            decision_owner.shard.strategy_activation_identity != policy.activation_identity or
            decision_owner.shard.strategy_config_version != policy.config_version))
        return error.RecoveredDemoPolicyMismatch;
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
    const endpoint = try curl.demoEndpointProfile(base_url, entity);
    var runtime = try curl.Runtime.init();
    defer runtime.deinit();
    const transport = try init.gpa.create(curl.TransportOwner);
    defer init.gpa.destroy(transport);
    transport.* = try curl.TransportOwner.initWithEndpoint(try auth.Credentials.init(key, secret, passphrase), null, source_session, endpoint);
    defer transport.deinit();
    var raw: RawSink = .{};
    const reconciler = try init.gpa.create(private.Reconciler);
    defer init.gpa.destroy(reconciler);
    reconciler.* = .{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualified(), .raw_sink = raw.interface(), .transport = transport.transport() };
    var adapter_clock: AdapterClock = .{};
    const implementation = try init.gpa.create(okx_adapter.OkxVenueAdapter);
    defer init.gpa.destroy(implementation);
    implementation.* = okx_adapter.OkxVenueAdapter.init(init.gpa, &chain, adapter_clock.interface(), demoProfile(), demoRules());
    implementation.attachPrivateReconciler(reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = demo_venue, .environment = .demo, .exchange_account = demo_account, .adapter_session = source_session, .request_capacity = 4, .output_capacity = 4 });
    const projection = try init.gpa.create(DemoProjection);
    defer init.gpa.destroy(projection);
    projection.* = .{};
    try establishReady(init, transport, implementation, reconciler, decision_owner);
    try drainDemo(adapter, decision_owner, projection);
    try requireNoPendingDemoOrders(init, transport);
    if (policy.startup == .recover) {
        for (gateway.uncertain_dispatches[0..gateway.uncertain_dispatch_count]) |item| {
            if (item.reconciliation_id == 0) try gateway.reconcileRecoveredDispatch(try decision_owner.source(), item.command_id);
        }
    }
    if (mode == .demo_live and projection.btcBalance() != 0) return error.NonzeroBaselineBtc;
    const first_prices = try ticker(init, transport);
    const first_limits = try priceLimits(init, transport);
    const first_price = if (mode == .demo_live)
        try protectedBuyPrice(first_prices, first_limits)
    else
        try protectedSellPrice(first_prices, first_limits);
    var lease: failover.PrimaryLease = undefined;
    var have_lease = false;
    defer if (have_lease) authority.revoke(&lease) catch {};
    if (policy.startup == .virgin) {
        if (mode != .demo_live) return error.CleanupRequiresRecoveredDemo;
        const now = (try clock(init.io)).times.monotonic_time_ns;
        lease = try authority.acquire(.{ .exchange_account = policy.exchange_account, .decision_domain = policy.decision_domain }, policy.node_identity, now);
        have_lease = true;
        var bootstrap_guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
        const mark = std.math.cast(i64, first_price * 100_000) orelse return error.InvalidTicker;
        try policy.initialize(decision_owner, mark, &bootstrap_guard, now, source_session);
    }
    try establishPublicMarket(init, key, secret, passphrase, endpoint, &raw, decision_owner);
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
        try sendDemoCommand(init, decision_owner, gateway, &guard, adapter, projection, command.command_id);
        const buy_result = try waitForOrder(init, transport, implementation, projection, decision_owner, command.client_order_id.slice());
        if (!buy_result.terminal or !buy_result.saw_balance or try currentNetBtc(decision_owner) < min_quantity_atoms)
            return error.BuyDidNotFillMinimum;
    }
    const cleanup_atoms = try currentNetBtc(decision_owner);
    if (cleanup_atoms < min_quantity_atoms) return error.NoCleanableBtc;
    const cleanup_prices = try ticker(init, transport);
    const cleanup_limits = try priceLimits(init, transport);
    const sell_price = try protectedSellPrice(cleanup_prices, cleanup_limits);
    const cleanup = try emitDemoIntent(init, policy, decision_owner, &authority, &lease, &have_lease, .sell, true, cleanup_atoms, sell_price);
    try sendDemoCommand(init, decision_owner, gateway, &guard, adapter, projection, cleanup.command_id);
    const cleaned = try waitForOrder(init, transport, implementation, projection, decision_owner, cleanup.client_order_id.slice());
    if (!cleaned.terminal or !cleaned.saw_balance or try currentNetBtc(decision_owner) != 0 or projection.has_unknown)
        return error.CleanupUnconfirmed;
    cleanup_needed = false;
    try progress(init.io, "authoritative_demo_cleanup");
}

fn establishPublicMarket(init: std.process.Init, key: []const u8, secret: []const u8, passphrase: []const u8, endpoint: curl.DemoEndpointProfile, raw: *RawSink, owner: *demo_authority.Owner) !void {
    var public_endpoint = endpoint;
    public_endpoint.private_ws_url = "wss://wspap.okx.com:8443/ws/v5/public";
    const transport = try init.gpa.create(curl.TransportOwner);
    defer init.gpa.destroy(transport);
    transport.* = try curl.TransportOwner.initWithEndpoint(try auth.Credentials.init(key, secret, passphrase), null, source_session + 1, public_endpoint);
    defer transport.deinit();
    const feed = try init.gpa.create(okx_market_feed.OkxMarketFeed);
    defer init.gpa.destroy(feed);
    feed.* = okx_market_feed.OkxMarketFeed.init(raw.interface());
    const adapter = feed.adapter();
    try adapter.start(.{ .venue = demo_venue, .environment = .demo, .subscription_set = 2, .config_version = 1, .session = source_session + 1, .output_capacity = market.max_events_per_ingress });
    try transport.wsConnect();
    const message_buffer = try init.gpa.alloc(u8, market.max_raw_frame_bytes);
    defer init.gpa.free(message_buffer);
    try transport.wsSend("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"instruments\",\"instType\":\"SPOT\",\"instId\":\"BTC-USDT\"}]}");
    for (0..8) |_| {
        const message = transport.wsReceive(message_buffer, 5_000) catch |err| switch (err) {
            error.WebSocketTimeout => continue,
            else => return err,
        };
        if (std.mem.indexOf(u8, message, "\"event\":\"subscribe\"") != null) continue;
        try feed.ingest(init.gpa, (try clock(init.io)).times, message);
        if (try adapter.tryDrain()) |batch| try owner.applyAdapterBatch(batch);
        if (owner.shard.canonical_market.get(okx_adapter.btc_usdt_spot) != null) break;
    } else return error.PublicInstrumentNotReady;
    try transport.wsSend("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"books\",\"instId\":\"BTC-USDT\"},{\"channel\":\"index-tickers\",\"instId\":\"BTC-USDT\"}]}");
    for (0..24) |_| {
        const message = transport.wsReceive(message_buffer, 5_000) catch |err| switch (err) {
            error.WebSocketTimeout => continue,
            else => return err,
        };
        if (std.mem.indexOf(u8, message, "\"event\":\"subscribe\"") != null) continue;
        try feed.ingest(init.gpa, (try clock(init.io)).times, message);
        if (try adapter.tryDrain()) |batch| try owner.applyAdapterBatch(batch);
        const entry = owner.shard.canonical_market.get(okx_adapter.btc_usdt_spot);
        if (feed.decoder.isPublicMarketReady(.btc_usdt_spot) and entry != null and entry.?.index != null) return;
    }
    return error.PublicMarketNotReady;
}

fn emergencyAuthoritativeCleanup(init: std.process.Init, policy: demo_authority.Policy, transport: *curl.TransportOwner, implementation: *okx_adapter.OkxVenueAdapter, adapter: venue.VenueAdapter, owner: *demo_authority.Owner, projection: *DemoProjection, gateway: *execution.Gateway, guard: *failover.GatewayLeaseGuard, authority: anytype, lease: *failover.PrimaryLease, have_lease: *bool) !void {
    for (0..2) |_| {
        for (rest_endpoints) |endpoint| try ingestRestEndpoint(init, transport, implementation, endpoint);
    }
    try drainDemo(adapter, owner, projection);
    if (!owner.shard.oms.openOrdersClosed() or projection.has_unknown) return error.EmergencyStateUncertain;
    const atoms = try currentNetBtc(owner);
    if (atoms < min_quantity_atoms) return;
    const prices = try ticker(init, transport);
    const limits = try priceLimits(init, transport);
    const price = try protectedSellPrice(prices, limits);
    const command = try emitDemoIntent(init, policy, owner, authority, lease, have_lease, .sell, true, atoms, price);
    try sendDemoCommand(init, owner, gateway, guard, adapter, projection, command.command_id);
}

fn currentNetBtc(owner: *const demo_authority.Owner) !i64 {
    const quantity = (try owner.source()).currentNetExchangePosition(okx_adapter.btc_usdt_spot) orelse return error.MissingDemoPosition;
    return std.math.cast(i64, quantity.lots) orelse return error.InvalidDemoPosition;
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
        const identity = owner.shard.trace.len + 1;
        _ = try owner.apply(.{ .core = .{ .identity = identity, .payload = .{ .primary_lease_granted = .{ .fencing_token = lease.token } } } });
    }
    const cursor = owner.shard.trace.len;
    const authz: strategy.Authorization = .{ .strategy_identity = policy.strategy_identity, .config_version = policy.config_version, .activation_identity = policy.activation_identity, .activation_barrier = owner.shard.host_activation_barrier };
    const config: strategy.Config = .{ .schema_registry = 1, .decision_domain = policy.decision_domain, .session = .{ .fencing = lease.token, .shard = 0, .generation = 1 }, .authorization = authz };
    const subscriptions = [_]strategy.Subscription{strategy.Subscription.of(policy.strategy_identity, &.{ .mark_price, .l2_delta })};
    var host = try strategy.Gateway.init(config, &subscriptions);
    const now_i64 = std.math.cast(i64, now) orelse return error.ClockOutOfRange;
    try host.recordPublished(1, cursor, now_i64);
    try host.activate(authz);
    const intent_sequence = cursor + 1;
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

fn sendDemoCommand(init: std.process.Init, owner: *demo_authority.Owner, gateway: *execution.Gateway, guard: *failover.GatewayLeaseGuard, adapter: venue.VenueAdapter, projection: *DemoProjection, command_id: u64) !void {
    const now = (try clock(init.io)).times.monotonic_time_ns;
    if (try owner.send(gateway, guard, command_id, now) != .accepted) return error.DemoNotSent;
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
}

const WaitResult = struct { terminal: bool = false, saw_balance: bool = false };

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

test "Demo acceptance replays canonical Adapter output and rejects Unknown" {
    const envelope = canonical.EventEnvelope{
        .event_type = @intFromEnum(canonical.EventType.order_dispatch_result),
        .schema_version = 1,
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
        const message = owner.wsReceive(message_buffer, 5_000) catch |err| switch (err) {
            error.WebSocketTimeout => continue,
            else => return err,
        };
        const batch = try implementation.ingestPrivateWs((try clock(init.io)).times, message);
        if (batch.rejection) |reason| {
            try diagnostic(init.io, "private_rejection", @tagName(reason));
            return error.PrivateIngressRejected;
        }
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
        const message = try owner.wsReceive(message_buffer, 5_000);
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
        const message = try owner.wsReceive(message_buffer, 5_000);
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
    for (0..2) |_| {
        for (rest_endpoints) |endpoint|
            try ingestRestEndpoint(init, owner, implementation, endpoint);
        _ = try reconciler.tryComplete();
    }
    if (!reconciler.readiness().reconciliation_ready) return error.ReconciliationNotReady;
}

fn ingestRestEndpoint(
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
        const response = owner.request(.get, path, "");
        if (response.outcome != .response) return error.PrivateRequestUncertain;
        const row_count = try restRowCount(init.gpa, response.response.?);
        const final = endpoint.cursor == .none or row_count < 20;
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
    const crossing_with_headroom = ceilDiv(prices.ask_tenths * 1_001, 1_000);
    const price = @min(crossing_with_headroom, limits.buy_tenths);
    if (price < prices.ask_tenths) return error.NoExecutableBuyPrice;
    return price;
}

fn protectedSellPrice(prices: Prices, limits: PriceLimits) !i128 {
    const crossing_with_headroom = @divFloor(prices.bid_tenths * 999, 1_000);
    const price = @max(crossing_with_headroom, limits.sell_tenths);
    if (price > prices.bid_tenths) return error.NoExecutableSellPrice;
    return price;
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
    if (item.state == .not_sent) return not_sent;
    if (item.reason) |reason| {
        try diagnostic(io, "canonical_reject_reason", @tagName(reason));
        return rejected;
    }
    if (item.state != .submitted) return error.DispatchUnknown;
}

fn diagnostic(io: std.Io, name: []const u8, value: []const u8) !void {
    var buffer: [160]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buffer);
    try out.interface.print("{s}={s}\n", .{ name, value });
    try out.interface.flush();
}

const Clock = struct {
    timestamp: [32]u8,
    timestamp_len: u8,
    seconds: [20]u8,
    seconds_len: u8,
    times: market.Times,
    fn timestampSlice(self: *const Clock) []const u8 {
        return self.timestamp[0..self.timestamp_len];
    }
    fn secondsSlice(self: *const Clock) []const u8 {
        return self.seconds[0..self.seconds_len];
    }
};

fn clock(io: std.Io) !Clock {
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

fn refresh(owner: *curl.TransportOwner, io: std.Io) !void {
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

fn qualified() live.Qualification {
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

fn demoProfile() order.CapabilityProfile {
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

fn demoRules() okx_adapter.Rules {
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
