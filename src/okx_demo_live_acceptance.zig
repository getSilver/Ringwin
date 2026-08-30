//! Explicit, bounded OKX Demo fill-and-cleanup acceptance.
//! This executable is intentionally separate from replay-capable product code.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const engine = @import("trading_shard.zig");
const journal = @import("journal.zig");
const auth = @import("okx_rest_auth.zig");
const curl = @import("okx_curl_transport.zig");
const live = @import("okx_live_chain.zig");
const market = @import("okx_public_market.zig");
const order = @import("okx_order_entry.zig");
const private = @import("okx_private_reconciliation.zig");
const spot = @import("okx_spot_projection.zig");
const okx_adapter = @import("okx_venue_adapter.zig");
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
    const key = init.environ_map.get("RINGWIN_OKX_KEY") orelse return error.MissingCredential;
    const secret = init.environ_map.get("RINGWIN_OKX_SECRET") orelse return error.MissingCredential;
    const passphrase = init.environ_map.get("RINGWIN_OKX_PASSPHRASE") orelse return error.MissingCredential;

    var runtime = try curl.Runtime.init();
    defer runtime.deinit();
    var owner = try curl.TransportOwner.init(try auth.Credentials.init(key, secret, passphrase), null, source_session);
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
    var projection: spot.Projection = .{};
    var stable = journal.Journal.init();
    var stable_sequence: u64 = 1;

    try establishReady(init, &owner, &implementation, &reconciler);
    try progress(init.io, "bootstrap");
    while (reconciler.drainReconciled()) |event| switch (event.payload) {
        .exchange_balance_snapshot => |snapshot| if (snapshot.scope == .full_rest) {
            try record(&projection, &stable, &stable_sequence, event);
        },
        else => {},
    };
    if (projection.baseline_btc_atoms == null) return error.MissingBaselineBtc;
    try progress(init.io, "baseline");

    if (mode == .cleanup_only) {
        try cleanupResidual(init, &owner, &raw);
        return;
    }
    if (projection.baseline_btc_atoms.? != 0) return error.NonzeroBaselineBtc;

    const prices = try ticker(init, &owner);
    const limits = try priceLimits(init, &owner);
    const buy_price_tenths = try protectedBuyPrice(prices, limits);
    try requireNotional(buy_quantity_atoms, buy_price_tenths);
    const run_identity = try currentUnixSeconds(init.io);
    var strategy_buy = try fixedStrategyBuy(init, run_identity, buy_price_tenths);
    try progress(init.io, "strategy_order_command");
    if (mode == .prepare_only) return;
    const buy_client = strategy_buy.command.command.client_order_id;
    const sell_client = order.clientOrderId((@as(u128, run_identity) << 32) | 2);

    var cleanup_needed = false;
    defer if (cleanup_needed) emergencyCleanup(init, &owner, adapter, sell_client) catch {};

    try refresh(&owner, init.io);
    const buy_attempt = try dispatch(adapter, strategy_buy.command);
    const buy_dispatch = switch (buy_attempt.event) {
        .order_dispatch_result => |value| value,
        else => return error.MissingDispatchResult,
    };
    try strategy_buy.ingress.applyDispatchResult(
        buy_attempt.envelope.identity.sequence,
        switch (buy_dispatch.state) {
            .submitted => .submitted,
            .unknown => .unknown,
            .not_sent => return error.BuyNotSent,
        },
    );
    try requireVenueAccepted(init.io, buy_dispatch, error.BuyNotSent, error.BuyRejected);
    cleanup_needed = true;
    const buy_result = try waitForOrder(init, &owner, &implementation, &projection, &stable, &stable_sequence, buy_client);
    if (!buy_result.terminal or projection.portfolio.position_base_atoms < min_quantity_atoms)
        return error.BuyDidNotFillMinimum;

    const cleanup_atoms = projection.portfolio.position_base_atoms;
    const fresh_prices = try ticker(init, &owner);
    const fresh_limits = try priceLimits(init, &owner);
    const sell_price_tenths = try protectedSellPrice(fresh_prices, fresh_limits);
    try refresh(&owner, init.io);
    const sell = authorizedPlace(2, 2, sell_client, .sell, .market, cleanup_atoms, sell_price_tenths);
    const sell_attempt = try dispatch(adapter, sell);
    const sell_result_dispatch = switch (sell_attempt.event) {
        .order_dispatch_result => |value| value,
        else => return error.MissingDispatchResult,
    };
    try requireVenueAccepted(init.io, sell_result_dispatch, error.CleanupNotSent, error.CleanupRejected);
    // A possibly-sent cleanup is never replayed by the emergency path.
    cleanup_needed = false;
    const sell_result = try waitForOrder(init, &owner, &implementation, &projection, &stable, &stable_sequence, sell_client);
    if (!sell_result.terminal or !sell_result.saw_balance) return error.CleanupUnconfirmed;
    if (projection.portfolio.position_base_atoms != 0 or projection.portfolio.open_cost_quote_atoms != 0)
        return error.CleanupIncomplete;
    if (!projection.economicReconciled()) return error.FinalBalanceMismatch;

    try stable.seal();
    const replayed = try spot.replayStable(stable.bytes());
    if (!std.mem.eql(u8, &projection.digest(), &replayed.digest())) return error.ReplayDigestMismatch;
    const digest_text = std.fmt.bytesToHex(projection.digest(), .lower);
    var out_buffer: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    try out.interface.print(
        "environment=demo strategy=fixed-btc-usdt-ioc orders=2 cleanup=closed position_atoms=0 open_cost_atoms=0 raw_ingress={d} stable_records={d} replay_digest={s}\n",
        .{ raw.count, stable_sequence - 1, &digest_text },
    );
    try out.interface.flush();
}

const WaitResult = struct { terminal: bool = false, saw_balance: bool = false };

fn waitForOrder(
    init: std.process.Init,
    owner: *curl.TransportOwner,
    implementation: *okx_adapter.OkxVenueAdapter,
    projection: *spot.Projection,
    stable: *journal.Journal,
    stable_sequence: *u64,
    client_order_id: order.ClientOrderId,
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
        for (batch.eventSlice()) |event| switch (event.payload) {
            .execution_report => |report| if (std.mem.eql(u8, report.client_order_id.slice(), client_order_id.slice())) {
                try record(projection, stable, stable_sequence, event);
                result.terminal = report.status == .filled or report.status == .canceled;
            },
            .fill => |fill| if (std.mem.eql(u8, fill.client_order_id.slice(), client_order_id.slice())) {
                try record(projection, stable, stable_sequence, event);
            },
            .exchange_balance_snapshot => {
                try record(projection, stable, stable_sequence, event);
                result.saw_balance = true;
            },
            else => {},
        };
        if (result.terminal and result.saw_balance and projection.economicReconciled()) return result;
    }
    return result;
}

fn establishReady(init: std.process.Init, owner: *curl.TransportOwner, implementation: *okx_adapter.OkxVenueAdapter, reconciler: *private.Reconciler) !void {
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
    _ = try adapter.tryDrain();
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

fn record(projection: *spot.Projection, stable: *journal.Journal, sequence: *u64, event: private.PrivateEvent) !void {
    try spot.appendStable(stable, sequence.*, event);
    try projection.apply(event);
    sequence.* += 1;
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

const StrategyBuy = struct {
    command: live.AuthorizedCommand,
    ingress: engine.TradingShardHostIngress,
};

fn fixedStrategyBuy(init: std.process.Init, intent_sequence: u64, price_tenths: i128) !StrategyBuy {
    const strategy_identity: u128 = 0x4f4b585f44454d4f5f4254435f494f43;
    const authorization: strategy.Authorization = .{
        .strategy_identity = strategy_identity,
        .config_version = 1,
        .activation_identity = 1,
        .activation_barrier = 10,
    };
    const config: strategy.Config = .{
        .schema_registry = 1,
        .decision_domain = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
        .authorization = authorization,
    };
    const subscriptions = [_]strategy.Subscription{
        strategy.Subscription.of(strategy_identity, &.{ .mark_price, .l2_delta }),
    };
    var gateway = try strategy.Gateway.init(config, &subscriptions);
    const now_ns = std.math.cast(i64, std.Io.Clock.awake.now(init.io).nanoseconds) orelse
        return error.ClockOutOfRange;
    try gateway.recordPublished(1, 14, now_ns);
    var frame_storage: [256]u8 = undefined;
    const frame = try strategy.encodeOutputOrderFrame(&frame_storage, config, 1, 14, intent_sequence, .{
        .instrument_identity = 3,
        .side = .buy,
        .time_in_force = .immediate_or_cancel,
        .quantity = buy_quantity_atoms,
        .limit_price_micros = std.math.cast(i64, price_tenths * 100_000) orelse return error.InvalidTicker,
    });
    const decision = gateway.ingest(frame, now_ns);
    if (decision != .accepted) return error.FixedStrategyRejected;
    var ingress = try engine.TradingShardHostIngress.initHealthySpotFixtureFor(authorization);
    const host_order = (try ingress.applyDecisionCommand(decision)) orelse return error.RiskRejected;
    if (host_order.instrument_identity != 3 or host_order.side != .buy or
        host_order.time_in_force != .immediate_or_cancel or host_order.portfolio_reduce_only or
        host_order.quantity.lots != buy_quantity_atoms or host_order.limit_price.ticks <= 0 or
        host_order.reservation.atoms <= 0)
        return error.InvalidQualifiedCommand;
    try ingress.verifyReplay();
    const order_identity = strategy_identity ^ @as(u128, intent_sequence);
    return .{
        .command = authorizedPlace(
            host_order.command_id,
            host_order.order_id,
            order.clientOrderId(order_identity),
            .buy,
            .limit_ioc,
            @intCast(host_order.quantity.lots),
            @divExact(host_order.limit_price.ticks, 100_000),
        ),
        .ingress = ingress,
    };
}

fn authorizedPlace(
    command_id: u64,
    order_id: u64,
    client_id: order.ClientOrderId,
    side: order.Side,
    kind: order.OrderKind,
    quantity_atoms: i64,
    price_tenths: i128,
) live.AuthorizedCommand {
    const protected_notional = @divFloor(@as(i128, quantity_atoms) * price_tenths, 1_000);
    return .{
        .reserved_notional_usdt_micros = std.math.cast(u64, protected_notional) orelse std.math.maxInt(u64),
        .command = .{
            .command_id = command_id,
            .order_id = order_id,
            .order_revision = 1,
            .shard_sequence = command_id,
            .instrument = .btc_usdt_spot,
            .client_order_id = client_id,
            .venue_order_id = null,
            .capability_version = 1,
            .rules_version = 1,
            .config_version = 1,
            .gateway_session = source_session,
            .dispatch_deadline_monotonic_ns = std.math.maxInt(u64),
            .risk_reservation_id = command_id,
            .payload = .{ .place = .{
                .side = side,
                .kind = kind,
                .quantity = .{ .coefficient = quantity_atoms, .scale = 8 },
                .limit_price = if (kind == .market) null else .{ .coefficient = price_tenths, .scale = 1 },
                .market_protection_price = if (kind == .market) .{ .coefficient = price_tenths, .scale = 1 } else null,
                .portfolio_reduce_only = side == .sell,
                .venue_reduce_only = false,
            } },
        },
    };
}

fn requireNotional(quantity_atoms: i64, price_tenths: i128) !void {
    const micros = @divFloor(@as(i128, quantity_atoms) * price_tenths, 1_000);
    if (micros <= 0 or micros > live.max_notional_usdt_micros) return error.NotionalLimitExceeded;
}

fn dispatch(adapter: venue.VenueAdapter, legacy: live.AuthorizedCommand) !canonical.EventRecord {
    if (try adapter.trySend(.{ .order_command = try canonicalCommand(legacy) }) != .accepted)
        return error.AdapterRejectedCommand;
    const batch = (try adapter.tryDrain()) orelse return error.MissingDispatchResult;
    for (batch.slice()) |event_record| switch (event_record.event) {
        .order_dispatch_result => |result| if (result.command == legacy.command.command_id)
            return event_record,
        else => {},
    };
    return error.MissingDispatchResult;
}

fn canonicalCommand(authorized: live.AuthorizedCommand) !canonical.OrderCommand {
    const command = authorized.command;
    const place = switch (command.payload) {
        .place => |value| value,
        else => return error.UnsupportedDemoCommand,
    };
    const instrument: canonical.InstrumentIdentity = switch (command.instrument) {
        .btc_usdt_spot => okx_adapter.btc_usdt_spot,
        .btc_usdt_swap => okx_adapter.btc_usdt_swap,
    };
    const quantity = canonical.InstrumentQuantity{
        .instrument = instrument,
        .rules_version = command.rules_version,
        .lots = try canonicalDecimal(place.quantity).exactAtoms(8),
    };
    const price = if (place.limit_price) |value| canonical.InstrumentPrice{
        .instrument = instrument,
        .rules_version = command.rules_version,
        .ticks = try canonicalDecimal(value).exactAtoms(1),
    } else null;
    const protection = if (place.market_protection_price) |value| canonical.InstrumentPrice{
        .instrument = instrument,
        .rules_version = command.rules_version,
        .ticks = try canonicalDecimal(value).exactAtoms(1),
    } else null;
    return .{
        .identity = command.command_id,
        .exchange_account = demo_account,
        .instrument = instrument,
        .client_order_id = try canonical.ClientOrderId.init(command.client_order_id.slice()),
        .capability_version = command.capability_version,
        .rules_version = command.rules_version,
        .config_version = command.config_version,
        .adapter_session = command.gateway_session,
        .dispatch_deadline_monotonic_ns = command.dispatch_deadline_monotonic_ns,
        .side = switch (place.side) {
            .buy => .buy,
            .sell => .sell,
        },
        .order_type = switch (place.kind) {
            .limit_gtc => .limit,
            .market => .market,
            .limit_ioc => .ioc,
            .limit_fok => .fok,
            .post_only => .post_only,
        },
        .time_in_force = switch (place.kind) {
            .limit_gtc => .good_til_canceled,
            .market, .limit_ioc => .immediate_or_cancel,
            .limit_fok => .fill_or_kill,
            .post_only => .post_only,
        },
        .portfolio_reduce_only = place.portfolio_reduce_only,
        .venue_reduce_only = place.venue_reduce_only,
        .quantity = quantity,
        .limit_price = price,
        .market_protection_price = protection,
    };
}

fn canonicalDecimal(value: order.Decimal) canonical.Decimal {
    return .{ .coefficient = value.coefficient, .scale = value.scale };
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

fn emergencyCleanup(init: std.process.Init, owner: *curl.TransportOwner, adapter: venue.VenueAdapter, client_id: order.ClientOrderId) !void {
    const balance_atoms = try availableBtcAtoms(init, owner);
    if (balance_atoms < min_quantity_atoms) return;
    const prices = try ticker(init, owner);
    const limits = try priceLimits(init, owner);
    const sell_price_tenths = try protectedSellPrice(prices, limits);
    try refresh(owner, init.io);
    const cleanup = authorizedPlace(99, 99, client_id, .sell, .market, balance_atoms, sell_price_tenths);
    const attempt = try dispatch(adapter, cleanup);
    const result = switch (attempt.event) {
        .order_dispatch_result => |value| value,
        else => return error.MissingDispatchResult,
    };
    try requireVenueAccepted(init.io, result, error.CleanupNotSent, error.CleanupRejected);
}

fn cleanupResidual(init: std.process.Init, owner: *curl.TransportOwner, raw: *RawSink) !void {
    var balance_atoms = try availableBtcAtoms(init, owner);
    if (balance_atoms < min_quantity_atoms) return error.NoCleanableBtc;
    if (balance_atoms < buy_quantity_atoms) {
        try topUpDemoCleanupBalance(init, owner);
        balance_atoms = try availableBtcAtoms(init, owner);
        if (balance_atoms < buy_quantity_atoms) return error.CleanupTopUpMissing;
    }
    const prices = try ticker(init, owner);
    const limits = try priceLimits(init, owner);
    const sell_price_tenths = try protectedSellPrice(prices, limits);
    const run_identity = try currentUnixSeconds(init.io);
    const client_id = order.clientOrderId((@as(u128, run_identity) << 32) | 3);
    var chain: live.Chain = .{
        .mode = .demo_live,
        .qualification = qualified(),
        .raw_sink = raw.interface(),
        .transport = owner.transport(),
    };
    var adapter_clock: AdapterClock = .{};
    var implementation = okx_adapter.OkxVenueAdapter.init(init.gpa, &chain, adapter_clock.interface(), demoProfile(), demoRules());
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = demo_venue, .environment = .demo, .exchange_account = demo_account, .adapter_session = source_session, .request_capacity = 4, .output_capacity = 4 });
    try refresh(owner, init.io);
    const cleanup = authorizedPlace(99, 99, client_id, .sell, .market, balance_atoms, sell_price_tenths);
    const attempt = try dispatch(adapter, cleanup);
    const result = switch (attempt.event) {
        .order_dispatch_result => |value| value,
        else => return error.MissingDispatchResult,
    };
    try requireVenueAccepted(init.io, result, error.CleanupNotSent, error.CleanupRejected);
    for (0..6) |_| if (try availableBtcAtoms(init, owner) == 0) {
        try progress(init.io, "residual_cleanup");
        return;
    };
    return error.CleanupBalanceNotZero;
}

fn topUpDemoCleanupBalance(init: std.process.Init, owner: *curl.TransportOwner) !void {
    try refresh(owner, init.io);
    const response = owner.request(
        .post,
        "/api/v5/account/demo-adjust-balance",
        "{\"type\":\"increase\",\"adjustments\":[{\"ccy\":\"BTC\",\"amt\":\"0.0001\"}]}",
    );
    if (response.outcome != .response) return error.CleanupTopUpUncertain;
    const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, response.response.?, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.CleanupTopUpRejected,
    };
    const code = switch (root.get("code") orelse return error.CleanupTopUpRejected) {
        .string => |value| value,
        else => return error.CleanupTopUpRejected,
    };
    if (!std.mem.eql(u8, code, "0")) return error.CleanupTopUpRejected;
    try progress(init.io, "demo_cleanup_top_up");
}

fn availableBtcAtoms(init: std.process.Init, owner: *curl.TransportOwner) !i64 {
    try refresh(owner, init.io);
    const response = owner.request(.get, "/api/v5/account/balance?ccy=BTC", "");
    if (response.outcome != .response) return error.BalanceUnavailable;
    const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, response.response.?, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidBalance,
    };
    const data = switch (root.get("data") orelse return error.InvalidBalance) {
        .array => |value| value,
        else => return error.InvalidBalance,
    };
    if (data.items.len != 1) return 0;
    const account = switch (data.items[0]) {
        .object => |value| value,
        else => return error.InvalidBalance,
    };
    const details = switch (account.get("details") orelse return error.InvalidBalance) {
        .array => |value| value,
        else => return error.InvalidBalance,
    };
    for (details.items) |item| {
        const detail = switch (item) {
            .object => |value| value,
            else => continue,
        };
        const ccy = switch (detail.get("ccy") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, ccy, "BTC")) continue;
        const available = switch (detail.get("availBal") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const decimal = try order.Decimal.parse(available);
        return std.math.cast(i64, try scaleAtoms(decimal)) orelse return error.InvalidBalance;
    }
    return 0;
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

fn currentUnixSeconds(io: std.Io) !u64 {
    const ns = std.Io.Clock.real.now(io).nanoseconds;
    if (ns <= 0) return error.ClockUnavailable;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
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

fn scaleAtoms(decimal: order.Decimal) !i128 {
    if (decimal.scale <= 8) return decimal.coefficient * try pow10(8 - decimal.scale);
    const divisor = try pow10(decimal.scale - 8);
    if (@mod(decimal.coefficient, divisor) != 0) return error.InexactBalance;
    return @divTrunc(decimal.coefficient, divisor);
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
