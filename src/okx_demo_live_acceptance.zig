//! Explicit, bounded OKX Demo fill-and-cleanup acceptance.
//! This executable is intentionally separate from replay-capable product code.

const std = @import("std");
const journal = @import("journal.zig");
const auth = @import("okx_rest_auth.zig");
const curl = @import("okx_curl_transport.zig");
const live = @import("okx_live_chain.zig");
const market = @import("okx_public_market.zig");
const order = @import("okx_order_entry.zig");
const private = @import("okx_private_reconciliation.zig");
const spot = @import("okx_spot_projection.zig");

const buy_quantity_atoms: i64 = 5_000; // 0.00005 BTC
const min_quantity_atoms: i64 = 1_000; // current BTC-USDT minSz 0.00001
const source_session: u64 = 1;

const RestEndpoint = struct {
    source: private.IngressSource,
    path: []const u8,
};

const rest_endpoints = [_]RestEndpoint{
    .{ .source = .rest_account_config, .path = "/api/v5/account/config" },
    .{ .source = .rest_leverage, .path = "/api/v5/account/leverage-info?instId=BTC-USDT-SWAP&mgnMode=isolated" },
    .{ .source = .rest_balance, .path = "/api/v5/account/balance?ccy=BTC,USDT" },
    .{ .source = .rest_positions, .path = "/api/v5/account/positions?instId=BTC-USDT-SWAP" },
    .{ .source = .rest_orders_pending, .path = "/api/v5/trade/orders-pending?limit=20" },
    .{ .source = .rest_orders_history_spot, .path = "/api/v5/trade/orders-history?instType=SPOT&limit=20" },
    .{ .source = .rest_orders_history_swap, .path = "/api/v5/trade/orders-history?instType=SWAP&limit=20" },
    .{ .source = .rest_fills_history_spot, .path = "/api/v5/trade/fills-history?instType=SPOT&limit=20" },
    .{ .source = .rest_fills_history_swap, .path = "/api/v5/trade/fills-history?instType=SWAP&limit=20" },
};

pub fn main(init: std.process.Init) !void {
    try requireExplicitDemoLive(init);
    const key = init.environ_map.get("RINGWIN_OKX_KEY") orelse return error.MissingCredential;
    const secret = init.environ_map.get("RINGWIN_OKX_SECRET") orelse return error.MissingCredential;
    const passphrase = init.environ_map.get("RINGWIN_OKX_PASSPHRASE") orelse return error.MissingCredential;

    var runtime = try curl.Runtime.init();
    defer runtime.deinit();
    var owner = try curl.TransportOwner.init(try auth.Credentials.init(key, secret, passphrase), null, source_session);
    defer owner.deinit();
    var raw: RawSink = .{};
    var reconciler: private.Reconciler = .{};
    var projection: spot.Projection = .{};
    var stable = journal.Journal.init();
    var stable_sequence: u64 = 1;

    try establishReady(init, &owner, &raw, &reconciler);
    while (reconciler.drainReconciled()) |event| switch (event.payload) {
        .exchange_balance_snapshot => |snapshot| if (snapshot.scope == .full_rest) {
            try record(&projection, &stable, &stable_sequence, event);
        },
        else => {},
    };
    if (projection.baseline_btc_atoms == null or projection.baseline_btc_atoms.? != 0)
        return error.NonzeroBaselineBtc;

    const prices = try ticker(init, &owner);
    const buy_price_tenths = ceilDiv(prices.ask_tenths * 101, 100);
    try requireNotional(buy_quantity_atoms, buy_price_tenths);
    const run_identity = try currentUnixSeconds(init.io);
    const buy_client = order.clientOrderId((@as(u128, run_identity) << 32) | 1);
    const sell_client = order.clientOrderId((@as(u128, run_identity) << 32) | 2);

    var chain: live.Chain = .{
        .mode = .demo_live,
        .qualification = qualified(),
        .raw_sink = raw.interface(),
        .transport = owner.transport(),
    };
    var cleanup_needed = false;
    defer if (cleanup_needed) emergencyCleanup(init, &owner, &chain, sell_client, prices.bid_tenths) catch {};

    try refresh(&owner, init.io);
    const buy = authorizedPlace(1, buy_client, .buy, buy_quantity_atoms, buy_price_tenths);
    const buy_attempt = try chain.dispatch(init.gpa, &.{buy});
    if (buy_attempt.dispatch.items[0].state == .not_sent) return error.BuyNotSent;
    cleanup_needed = true;
    const buy_result = try waitForOrder(init, &owner, &raw, &reconciler, &projection, &stable, &stable_sequence, buy_client);
    if (!buy_result.terminal or projection.portfolio.position_base_atoms < min_quantity_atoms)
        return error.BuyDidNotFillMinimum;

    const cleanup_atoms = projection.portfolio.position_base_atoms;
    const fresh_prices = try ticker(init, &owner);
    const sell_price_tenths = @divFloor(fresh_prices.bid_tenths * 99, 100);
    try refresh(&owner, init.io);
    const sell = authorizedPlace(2, sell_client, .sell, cleanup_atoms, sell_price_tenths);
    const sell_attempt = try chain.dispatch(init.gpa, &.{sell});
    if (sell_attempt.dispatch.items[0].state == .not_sent) return error.CleanupNotSent;
    // A possibly-sent cleanup is never replayed by the emergency path.
    cleanup_needed = false;
    const sell_result = try waitForOrder(init, &owner, &raw, &reconciler, &projection, &stable, &stable_sequence, sell_client);
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
    raw: *RawSink,
    reconciler: *private.Reconciler,
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
        const batch = try reconciler.ingestWsMessage(init.gpa, raw.interface(), source_session, (try clock(init.io)).times, message);
        if (batch.rejection != null) return error.PrivateIngressRejected;
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
        if (result.terminal and result.saw_balance) return result;
    }
    return result;
}

fn establishReady(init: std.process.Init, owner: *curl.TransportOwner, raw: *RawSink, reconciler: *private.Reconciler) !void {
    reconciler.beginSession(source_session);
    try owner.wsConnect();
    var stamp = try clock(init.io);
    try owner.wsLogin(stamp.secondsSlice());
    const message_buffer = try init.gpa.alloc(u8, market.max_raw_frame_bytes);
    defer init.gpa.free(message_buffer);
    var login_ok = false;
    for (0..8) |_| {
        const message = try owner.wsReceive(message_buffer, 5_000);
        const batch = try reconciler.ingestWsMessage(init.gpa, raw.interface(), source_session, (try clock(init.io)).times, message);
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
        const batch = try reconciler.ingestWsMessage(init.gpa, raw.interface(), source_session, (try clock(init.io)).times, message);
        if (batch.rejection != null) return error.PrivateIngressRejected;
        if (reconciler.readiness().private_stream_ready) break;
    }
    if (!reconciler.readiness().private_stream_ready) return error.IncompletePrivateStream;
    try reconciler.beginReconciliation(raw.count);
    for (0..2) |_| {
        for (rest_endpoints) |endpoint| {
            try refresh(owner, init.io);
            const response = owner.request(.get, endpoint.path, "");
            if (response.outcome != .response) return error.PrivateRequestUncertain;
            const batch = try reconciler.ingest(init.gpa, raw.interface(), source_session, (try clock(init.io)).times, endpoint.source, .{ .final = true }, response.response.?);
            if (batch.rejection != null) return error.RestBootstrapRejected;
        }
        _ = try reconciler.tryComplete();
    }
    if (!reconciler.readiness().reconciliation_ready) return error.ReconciliationNotReady;
}

fn record(projection: *spot.Projection, stable: *journal.Journal, sequence: *u64, event: private.CanonicalEvent) !void {
    try spot.appendStable(stable, sequence.*, event);
    try projection.apply(event);
    sequence.* += 1;
}

const Prices = struct { bid_tenths: i128, ask_tenths: i128 };

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

fn authorizedPlace(command_id: u64, client_id: order.ClientOrderId, side: order.Side, quantity_atoms: i64, price_tenths: i128) live.AuthorizedCommand {
    return .{
        .reserved_notional_usdt_micros = 5_000_000,
        .command = .{
            .command_id = command_id,
            .order_id = command_id,
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
                .kind = .market,
                .quantity = .{ .coefficient = quantity_atoms, .scale = 8 },
                .limit_price = null,
                .market_protection_price = .{ .coefficient = price_tenths, .scale = 1 },
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

fn emergencyCleanup(init: std.process.Init, owner: *curl.TransportOwner, chain: *live.Chain, client_id: order.ClientOrderId, bid_tenths: i128) !void {
    const balance_atoms = try availableBtcAtoms(init, owner);
    if (balance_atoms < min_quantity_atoms) return;
    try refresh(owner, init.io);
    const cleanup = authorizedPlace(99, client_id, .sell, balance_atoms, @divFloor(bid_tenths * 98, 100));
    _ = try chain.dispatch(init.gpa, &.{cleanup});
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
    timestamp: [24]u8,
    seconds: [20]u8,
    seconds_len: u8,
    times: market.Times,
    fn timestampSlice(self: *const Clock) []const u8 {
        return &self.timestamp;
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
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    var result: Clock = .{
        .timestamp = undefined,
        .seconds = undefined,
        .seconds_len = 0,
        .times = .{
            .receive_time_utc_ns = @intCast(real_ns),
            .monotonic_time_ns = @intCast(monotonic_ns),
            .wall_time_utc_ns = @intCast(real_ns),
        },
    };
    const timestamp = try std.fmt.bufPrint(&result.timestamp, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,                                                   month_day.month.numeric(),        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),                                   day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute(),
        @divFloor(@mod(real_ns, std.time.ns_per_s), std.time.ns_per_ms),
    });
    if (timestamp.len != result.timestamp.len) return error.ClockFormat;
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

fn requireExplicitDemoLive(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const flag = args.next() orelse return error.ExplicitDemoLiveRequired;
    if (!std.mem.eql(u8, flag, "--demo-live") or args.next() != null) return error.ExplicitDemoLiveRequired;
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
