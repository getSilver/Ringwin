//! Read-only Demo account assertion. The source exposes GET only; borrowed
//! response storage may be overwritten by the very next get call.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator, source: anytype, local_ms: i64, expected_uid_hash: []const u8, allow_btc: bool) !void {
    var expected_digest: [32]u8 = undefined;
    if (expected_uid_hash.len != 64) return error.AccountGuardRejected;
    _ = std.fmt.hexToBytes(&expected_digest, expected_uid_hash) catch return error.AccountGuardRejected;
    {
        var response = try fetch(allocator, source, "/api/v5/public/time");
        defer response.deinit();
        const row = try singleton(response.value);
        const ts = try text(row, "ts");
        if (ts.len == 0) return error.AccountGuardRejected;
        for (ts) |byte| if (!std.ascii.isDigit(byte)) return error.AccountGuardRejected;
        const server_ms = std.fmt.parseInt(i64, ts, 10) catch return error.AccountGuardRejected;
        const difference = std.math.sub(i64, server_ms, local_ms) catch return error.AccountGuardRejected;
        if (difference < -5000 or difference > 5000) return error.AccountGuardRejected;
    }
    {
        var response = try fetch(allocator, source, "/api/v5/account/config");
        defer response.deinit();
        const row = try singleton(response.value);
        const uid = try text(row, "uid");
        if (std.mem.trim(u8, uid, " \t\r\n").len == 0) return error.AccountGuardRejected;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(uid, &digest, .{});
        if (!std.mem.eql(u8, &digest, &expected_digest)) return error.AccountGuardRejected;
        var read = false;
        var trade = false;
        var tokens = std.mem.splitScalar(u8, try text(row, "perm"), ',');
        while (tokens.next()) |raw| {
            const token = std.mem.trim(u8, raw, " \t\r\n");
            if (token.len == 0 or std.ascii.eqlIgnoreCase(token, "withdraw")) return error.AccountGuardRejected;
            read = read or std.ascii.eqlIgnoreCase(token, "read") or std.ascii.eqlIgnoreCase(token, "read_only");
            trade = trade or std.ascii.eqlIgnoreCase(token, "trade");
        }
        if (!read or !trade) return error.AccountGuardRejected;
        if (!std.mem.eql(u8, try text(row, "acctLv"), "2") or !std.mem.eql(u8, try text(row, "posMode"), "net_mode")) return error.AccountGuardRejected;
        try requireFalse(row, "autoLoan");
        try requireFalse(row, "enableSpotBorrow");
    }
    {
        var response = try fetch(allocator, source, "/api/v5/account/instruments?instType=SPOT&instId=BTC-USDT");
        defer response.deinit();
        const row = try singleton(response.value);
        if (!std.mem.eql(u8, try text(row, "instId"), "BTC-USDT") or !std.mem.eql(u8, try text(row, "state"), "live")) return error.AccountGuardRejected;
    }
    {
        var response = try fetch(allocator, source, "/api/v5/account/instruments?instType=SWAP&instId=BTC-USDT-SWAP");
        defer response.deinit();
        const row = try singleton(response.value);
        const state = try text(row, "state");
        if (!std.mem.eql(u8, try text(row, "instId"), "BTC-USDT-SWAP") or (!std.mem.eql(u8, state, "live") and !std.mem.eql(u8, state, "post_only"))) return error.AccountGuardRejected;
    }
    {
        var response = try fetch(allocator, source, "/api/v5/account/leverage-info?instId=BTC-USDT-SWAP&mgnMode=isolated");
        defer response.deinit();
        const rows = try data(response.value);
        var found = false;
        for (rows) |row| {
            const id = try text(row, "instId");
            const mode = try text(row, "mgnMode");
            const side = try text(row, "posSide");
            found = found or (std.mem.eql(u8, id, "BTC-USDT-SWAP") and std.mem.eql(u8, mode, "isolated") and std.mem.eql(u8, side, "net"));
        }
        if (!found) return error.AccountGuardRejected;
    }
    {
        var response = try fetch(allocator, source, "/api/v5/account/positions");
        defer response.deinit();
        for (try data(response.value)) |row| {
            if (!try decimalZero(try text(row, "pos"))) return error.AccountGuardRejected;
        }
    }
    {
        var response = try fetch(allocator, source, "/api/v5/trade/orders-pending");
        defer response.deinit();
        if ((try data(response.value)).len != 0) return error.AccountGuardRejected;
    }
    inline for (.{ "conditional", "oco", "trigger", "move_order_stop", "iceberg", "twap", "chase" }) |kind| {
        var response = try fetch(allocator, source, "/api/v5/trade/orders-algo-pending?ordType=" ++ kind);
        defer response.deinit();
        if ((try data(response.value)).len != 0) return error.AccountGuardRejected;
    }
    inline for (.{ "/api/v5/account/balance", "/api/v5/account/balance?ccy=BTC,USDT" }) |path| {
        var response = try fetch(allocator, source, path);
        defer response.deinit();
        const row = try singleton(response.value);
        const details = try array(try field(row, "details"));
        for (details) |detail| {
            const currency = try text(detail, "ccy");
            if (currency.len == 0) return error.AccountGuardRejected;
            inline for (.{ "liab", "isoLiab", "crossLiab" }) |name| {
                if (!try decimalZero(try text(detail, name))) return error.AccountGuardRejected;
            }
            const zero_equity = try decimalZero(try text(detail, "eq"));
            if (!zero_equity and !std.mem.eql(u8, currency, "USDT") and !(allow_btc and std.mem.eql(u8, currency, "BTC"))) return error.AccountGuardRejected;
        }
    }
}

const Value = std.json.Value;

fn field(object: Value, key: []const u8) !Value {
    return switch (object) {
        .object => |map| map.get(key) orelse error.AccountGuardRejected,
        else => error.AccountGuardRejected,
    };
}

fn text(object: Value, key: []const u8) ![]const u8 {
    return switch (try field(object, key)) {
        .string => |value| value,
        else => error.AccountGuardRejected,
    };
}

fn array(value: Value) ![]Value {
    return switch (value) {
        .array => |value_array| value_array.items,
        else => error.AccountGuardRejected,
    };
}

fn data(root: Value) ![]Value {
    if (!std.mem.eql(u8, try text(root, "code"), "0")) return error.AccountGuardRejected;
    return array(try field(root, "data"));
}

fn singleton(root: Value) !Value {
    const rows = try data(root);
    if (rows.len != 1) return error.AccountGuardRejected;
    return rows[0];
}

fn fetch(allocator: Allocator, source: anytype, path: []const u8) !std.json.Parsed(Value) {
    var parsed = std.json.parseFromSlice(Value, allocator, try source.get(path), .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.AccountGuardRejected,
    };
    errdefer parsed.deinit();
    _ = try data(parsed.value);
    return parsed;
}

fn requireFalse(row: Value, name: []const u8) !void {
    switch (try field(row, name)) {
        .bool => |value| if (value) return error.AccountGuardRejected,
        else => return error.AccountGuardRejected,
    }
}

/// Strict decimal lexical equality, with no float conversion or integer
/// accumulation. An arbitrarily tiny nonzero value cannot underflow to zero.
fn decimalZero(value: []const u8) !bool {
    if (value.len == 0) return error.AccountGuardRejected;
    var offset: usize = if (value[0] == '-' or value[0] == '+') 1 else 0;
    const first_digit = offset;
    var zero = true;
    while (offset < value.len and std.ascii.isDigit(value[offset])) : (offset += 1) {
        zero = zero and value[offset] == '0';
    }
    if (offset == first_digit) return error.AccountGuardRejected;
    if (offset < value.len) {
        if (value[offset] != '.') return error.AccountGuardRejected;
        offset += 1;
        const fractional_start = offset;
        while (offset < value.len and std.ascii.isDigit(value[offset])) : (offset += 1) {
            zero = zero and value[offset] == '0';
        }
        if (offset == fractional_start) return error.AccountGuardRejected;
    }
    if (offset != value.len) return error.AccountGuardRejected;
    return zero;
}

const TestReply = struct { path: []const u8, body: []const u8 };
const fixture_replies = [_]TestReply{
    .{ .path = "/api/v5/public/time", .body = "{\"code\":\"0\",\"data\":[{\"ts\":\"1700000000000\"}]}" },
    .{ .path = "/api/v5/account/config", .body = "{\"code\":\"0\",\"data\":[{\"uid\":\"synthetic-account-08\",\"perm\":\"read_only,trade\",\"acctLv\":\"2\",\"posMode\":\"net_mode\",\"autoLoan\":false,\"enableSpotBorrow\":false}]}" },
    .{ .path = "/api/v5/account/instruments?instType=SPOT&instId=BTC-USDT", .body = "{\"code\":\"0\",\"data\":[{\"instId\":\"BTC-USDT\",\"state\":\"live\"}]}" },
    .{ .path = "/api/v5/account/instruments?instType=SWAP&instId=BTC-USDT-SWAP", .body = "{\"code\":\"0\",\"data\":[{\"instId\":\"BTC-USDT-SWAP\",\"state\":\"post_only\"}]}" },
    .{ .path = "/api/v5/account/leverage-info?instId=BTC-USDT-SWAP&mgnMode=isolated", .body = "{\"code\":\"0\",\"data\":[{\"instId\":\"BTC-USDT-SWAP\",\"mgnMode\":\"isolated\",\"posSide\":\"net\"}]}" },
    .{ .path = "/api/v5/account/positions", .body = "{\"code\":\"0\",\"data\":[{\"pos\":\"-000.00\"}]}" },
    .{ .path = "/api/v5/trade/orders-pending", .body = "{\"code\":\"0\",\"data\":[]}" },
    .{ .path = "/api/v5/trade/orders-algo-pending?ordType=conditional", .body = "{\"code\":\"0\",\"data\":[]}" },
    .{ .path = "/api/v5/trade/orders-algo-pending?ordType=oco", .body = "{\"code\":\"0\",\"data\":[]}" },
    .{ .path = "/api/v5/trade/orders-algo-pending?ordType=trigger", .body = "{\"code\":\"0\",\"data\":[]}" },
    .{ .path = "/api/v5/trade/orders-algo-pending?ordType=move_order_stop", .body = "{\"code\":\"0\",\"data\":[]}" },
    .{ .path = "/api/v5/trade/orders-algo-pending?ordType=iceberg", .body = "{\"code\":\"0\",\"data\":[]}" },
    .{ .path = "/api/v5/trade/orders-algo-pending?ordType=twap", .body = "{\"code\":\"0\",\"data\":[]}" },
    .{ .path = "/api/v5/trade/orders-algo-pending?ordType=chase", .body = "{\"code\":\"0\",\"data\":[]}" },
    .{ .path = "/api/v5/account/balance", .body = "{\"code\":\"0\",\"data\":[{\"details\":[{\"ccy\":\"USDT\",\"eq\":\"25.00\",\"liab\":\"0\",\"isoLiab\":\"-0.00\",\"crossLiab\":\"+000.0\"}]}]}" },
    .{ .path = "/api/v5/account/balance?ccy=BTC,USDT", .body = "{\"code\":\"0\",\"data\":[{\"details\":[{\"ccy\":\"BTC\",\"eq\":\"0.00000000\",\"liab\":\"0\",\"isoLiab\":\"0\",\"crossLiab\":\"0\"}]}]}" },
};

const TestSource = struct {
    replies: [fixture_replies.len]TestReply = fixture_replies,
    seen: [fixture_replies.len]bool = @splat(false),
    borrowed: [4096]u8 = undefined,
    calls: usize = 0,

    fn get(self: *TestSource, path: []const u8) ![]const u8 {
        for (self.replies, 0..) |reply, index| {
            if (std.mem.eql(u8, path, reply.path)) {
                if (self.seen[index]) return error.UnexpectedDuplicateGet;
                self.seen[index] = true;
                self.calls += 1;
                @memset(&self.borrowed, 0x5a);
                @memcpy(self.borrowed[0..reply.body.len], reply.body);
                return self.borrowed[0..reply.body.len];
            }
        }
        return error.UnexpectedGet;
    }
};

// Independently generated with Python hashlib.sha256(b'synthetic-account-08').
const fixture_uid_hash = "bd94fe63f4a04fb356520fbae4bd39ba3ada41ae2518185e2a3eb28f81101bcf";

test "Demo account guard validates every public GET and both balance views" {
    var source = TestSource{};
    try run(std.testing.allocator, &source, 1700000000000, fixture_uid_hash, false);
    try std.testing.expectEqual(@as(usize, 16), source.calls);
    try std.testing.expect(std.mem.allEqual(bool, &source.seen, true));
}
