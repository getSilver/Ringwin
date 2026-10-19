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
                if (!try liabilityZero(detail, name)) return error.AccountGuardRejected;
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
        .string => |value| if (std.mem.trim(u8, value, " \t\r\n").len != 0) value else error.AccountGuardRejected,
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

/// Existing OKX no-margin convention: an explicitly present blank string is
/// zero liability. Missing/non-string remains unknown and rejects. This does
/// not relax position/equity decimal parsing.
fn liabilityZero(detail: Value, name: []const u8) !bool {
    const value = switch (try field(detail, name)) {
        .string => |string| string,
        else => return error.AccountGuardRejected,
    };
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return true;
    return decimalZero(value);
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
    allocation_observer: ?*std.testing.FailingAllocator = null,

    fn get(self: *TestSource, path: []const u8) ![]const u8 {
        if (self.allocation_observer) |observer| {
            if (observer.allocated_bytes != observer.freed_bytes) return error.PreviousResponseNotReleased;
        }
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
    var observer = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var source = TestSource{ .allocation_observer = &observer };
    try run(observer.allocator(), &source, 1700000000000, fixture_uid_hash, false);
    try std.testing.expectEqual(@as(usize, 16), source.calls);
    try std.testing.expect(std.mem.allEqual(bool, &source.seen, true));
    try std.testing.expectEqual(observer.allocated_bytes, observer.freed_bytes);
}

test "Demo account guard rejects malformed leverage rows even after a valid row" {
    var source = TestSource{};
    source.replies[4].body = "{\"code\":\"0\",\"data\":[{\"instId\":\"BTC-USDT-SWAP\",\"mgnMode\":\"isolated\",\"posSide\":\"net\"},{\"instId\":\"\",\"mgnMode\":\"isolated\",\"posSide\":\"net\"}]}";
    try std.testing.expectError(error.AccountGuardRejected, run(std.testing.allocator, &source, 1700000000000, fixture_uid_hash, false));
}

test "Demo account guard preserves explicit blank liability convention only" {
    for ([_]usize{ 14, 15 }) |index| {
        var source = TestSource{};
        source.replies[index].body = "{\"code\":\"0\",\"data\":[{\"details\":[{\"ccy\":\"USDT\",\"eq\":\"25\",\"liab\":\"\",\"isoLiab\":\"  \",\"crossLiab\":\"\"}]}]}";
        try run(std.testing.allocator, &source, 1700000000000, fixture_uid_hash, false);
        try std.testing.expectEqual(@as(usize, 16), source.calls);
    }
}

const TestTarget = enum { root, row, detail };

fn modifiedFixture(index: usize, target: TestTarget, name: []const u8, replacement: ?Value) ![]u8 {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, fixture_replies[index].body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    var object = &parsed.value;
    if (target != .root) object = &object.object.getPtr("data").?.array.items[0];
    if (target == .detail) object = &object.object.getPtr("details").?.array.items[0];
    if (replacement) |value| {
        object.object.getPtr(name).?.* = value;
    } else {
        if (!object.object.swapRemove(name)) return error.UnknownFixtureField;
    }
    return std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
}

fn expectRejectedResponse(index: usize, response: []const u8, allow_btc: bool) !void {
    var source = TestSource{};
    source.replies[index].body = response;
    try std.testing.expectError(error.AccountGuardRejected, run(std.testing.allocator, &source, 1700000000000, fixture_uid_hash, allow_btc));
    // No later GET is performed once an account safety check fails. This
    // source intentionally has no POST, order, transfer or cancel API.
    try std.testing.expectEqual(index + 1, source.calls);
}

fn expectRejectedMutation(index: usize, target: TestTarget, name: []const u8, replacement: ?Value) !void {
    const body = try modifiedFixture(index, target, name, replacement);
    defer std.testing.allocator.free(body);
    try expectRejectedResponse(index, body, false);
}

test "Demo account guard rejects non success malformed and missing response envelopes at every GET" {
    for (0..16) |index| {
        try expectRejectedMutation(index, .root, "code", .{ .string = "51000" });
        try expectRejectedMutation(index, .root, "code", .{ .integer = 0 });
        try expectRejectedMutation(index, .root, "code", null);
        try expectRejectedMutation(index, .root, "data", null);
        try expectRejectedMutation(index, .root, "data", .null);
        try expectRejectedMutation(index, .root, "data", .{ .string = "[]" });
        try expectRejectedResponse(index, "[", false);
        const duplicate = try std.fmt.allocPrint(std.testing.allocator, "{{\"code\":\"0\",{s}", .{fixture_replies[index].body[1..]});
        defer std.testing.allocator.free(duplicate);
        try expectRejectedResponse(index, duplicate, false);
    }
}

test "Demo account guard binds real UID permissions modes and disabled borrowing" {
    const Change = struct { name: []const u8, value: Value };
    const changes = [_]Change{
        .{ .name = "uid", .value = .{ .string = "another-account" } },
        .{ .name = "uid", .value = .{ .string = "" } },
        .{ .name = "perm", .value = .{ .string = "read_only" } },
        .{ .name = "perm", .value = .{ .string = "trade" } },
        .{ .name = "perm", .value = .{ .string = "Read, Trade, WITHDRAW" } },
        .{ .name = "acctLv", .value = .{ .string = "1" } },
        .{ .name = "posMode", .value = .{ .string = "long_short_mode" } },
        .{ .name = "autoLoan", .value = .{ .bool = true } },
        .{ .name = "enableSpotBorrow", .value = .{ .bool = true } },
        .{ .name = "autoLoan", .value = .{ .string = "false" } },
        .{ .name = "enableSpotBorrow", .value = .null },
    };
    for (changes) |change| try expectRejectedMutation(1, .row, change.name, change.value);
    for ([_][]const u8{ "uid", "perm", "acctLv", "posMode", "autoLoan", "enableSpotBorrow" }) |name| try expectRejectedMutation(1, .row, name, null);
    var source = TestSource{};
    const body = try modifiedFixture(1, .row, "perm", .{ .string = " Read , TrAdE " });
    defer std.testing.allocator.free(body);
    source.replies[1].body = body;
    try run(std.testing.allocator, &source, 1700000000000, fixture_uid_hash, false);
    for ([_][]const u8{ "", "not-a-sha256", "0000000000000000000000000000000000000000000000000000000000000000", "gd94fe63f4a04fb356520fbae4bd39ba3ada41ae2518185e2a3eb28f81101bcf" }) |expected| {
        var wrong_identity = TestSource{};
        try std.testing.expectError(error.AccountGuardRejected, run(std.testing.allocator, &wrong_identity, 1700000000000, expected, false));
        try std.testing.expect(wrong_identity.calls <= 2);
    }
}

test "Demo account guard preserves unique instruments isolated net leverage and all pending gates" {
    try expectRejectedMutation(2, .row, "instId", .{ .string = "ETH-USDT" });
    try expectRejectedMutation(2, .row, "state", .{ .string = "post_only" });
    try expectRejectedMutation(3, .row, "instId", .{ .string = "ETH-USDT-SWAP" });
    try expectRejectedMutation(3, .row, "state", .{ .string = "suspend" });
    for ([_]usize{ 2, 3 }) |index| {
        try expectRejectedMutation(index, .row, "instId", null);
        try expectRejectedMutation(index, .row, "state", null);
        try expectRejectedResponse(index, "{\"code\":\"0\",\"data\":[]}", false);
    }
    try expectRejectedResponse(2, "{\"code\":\"0\",\"data\":[{\"instId\":\"BTC-USDT\",\"state\":\"live\"},{\"instId\":\"BTC-USDT\",\"state\":\"live\"}]}", false);
    try expectRejectedResponse(3, "{\"code\":\"0\",\"data\":[{\"instId\":\"BTC-USDT-SWAP\",\"state\":\"live\"},{\"instId\":\"BTC-USDT-SWAP\",\"state\":\"live\"}]}", false);
    try expectRejectedResponse(4, "{\"code\":\"0\",\"data\":[]}", false);
    try expectRejectedMutation(4, .row, "instId", .{ .string = "ETH-USDT-SWAP" });
    try expectRejectedMutation(4, .row, "mgnMode", .{ .string = "cross" });
    try expectRejectedMutation(4, .row, "posSide", .{ .string = "long" });
    for ([_][]const u8{ "instId", "mgnMode", "posSide" }) |name| try expectRejectedMutation(4, .row, name, null);
    // Ordinary pending and each of the seven algo ordType paths must reject.
    for (6..14) |index| try expectRejectedResponse(index, "{\"code\":\"0\",\"data\":[{}]}", false);
    var source = TestSource{};
    const live_swap = try modifiedFixture(3, .row, "state", .{ .string = "live" });
    defer std.testing.allocator.free(live_swap);
    source.replies[3].body = live_swap;
    try run(std.testing.allocator, &source, 1700000000000, fixture_uid_hash, false);
}

test "Demo account guard clock arithmetic rejects invalid timestamps and overflow without panic" {
    for ([_]i64{ 1699999995000, 1700000005000 }) |local_ms| {
        var source = TestSource{};
        try run(std.testing.allocator, &source, local_ms, fixture_uid_hash, false);
    }
    for ([_]i64{ 1699999994999, 1700000005001, std.math.minInt(i64), std.math.maxInt(i64) }) |local_ms| {
        var source = TestSource{};
        try std.testing.expectError(error.AccountGuardRejected, run(std.testing.allocator, &source, local_ms, fixture_uid_hash, false));
        try std.testing.expectEqual(@as(usize, 1), source.calls);
    }
    for ([_][]const u8{ "", "-1", "+1700000000000", "1e12", "1700000000000.0", "9223372036854775808", "NaN" }) |value| try expectRejectedMutation(0, .row, "ts", .{ .string = value });
    try expectRejectedMutation(0, .row, "ts", null);
    try expectRejectedMutation(0, .row, "ts", .{ .integer = 1700000000000 });
    try expectRejectedResponse(0, "{\"code\":\"0\",\"data\":[]}", false);
}

test "Demo account guard strict decimal positions cannot underflow or accept unknown values" {
    for ([_][]const u8{ "0", "+0", "-0.000", "00000.000000000000000" }) |value| {
        var source = TestSource{};
        const body = try modifiedFixture(5, .row, "pos", .{ .string = value });
        defer std.testing.allocator.free(body);
        source.replies[5].body = body;
        try run(std.testing.allocator, &source, 1700000000000, fixture_uid_hash, false);
    }
    for ([_][]const u8{ "1", "-0.00000000000000000001", "1e-999", "0e0", "NaN", "Infinity", "", " ", "+", "--0", ".0", "0.", " 0", "0 " }) |value| try expectRejectedMutation(5, .row, "pos", .{ .string = value });
    try expectRejectedMutation(5, .row, "pos", null);
    try expectRejectedMutation(5, .row, "pos", .null);
    try expectRejectedMutation(5, .row, "pos", .{ .integer = 0 });
    try expectRejectedMutation(5, .row, "pos", .{ .number_string = "1e-999" });
    try expectRejectedResponse(5, "{\"code\":\"0\",\"data\":[{\"pos\":\"0\"},{\"pos\":\"0.00000000000000000001\"}]}", false);
    var tiny_nonzero: [515]u8 = @splat('0');
    tiny_nonzero[1] = '.';
    tiny_nonzero[514] = '1';
    try expectRejectedMutation(5, .row, "pos", .{ .string = &tiny_nonzero });
}

test "Demo account guard requires every liability field and USDT only equity in both balance views" {
    for ([_]usize{ 14, 15 }) |index| {
        for ([_][]const u8{ "liab", "isoLiab", "crossLiab" }) |name| {
            try expectRejectedMutation(index, .detail, name, null);
            try expectRejectedMutation(index, .detail, name, .null);
            try expectRejectedMutation(index, .detail, name, .{ .integer = 0 });
            for ([_][]const u8{ "0.00000000000000000001", "-0.00000000000000000001", "1e-999", "NaN", "0e0", "+", " 0" }) |value| try expectRejectedMutation(index, .detail, name, .{ .string = value });
        }
        try expectRejectedMutation(index, .row, "details", null);
        try expectRejectedMutation(index, .row, "details", .null);
        try expectRejectedResponse(index, "{\"code\":\"0\",\"data\":[]}", false);
        for ([_][]const u8{ "ccy", "eq" }) |name| {
            try expectRejectedMutation(index, .detail, name, null);
            try expectRejectedMutation(index, .detail, name, .{ .string = "" });
        }
        try expectRejectedMutation(index, .detail, "eq", .{ .string = "1e-999" });
        try expectRejectedMutation(index, .detail, "eq", .{ .integer = 0 });
        var btc = try std.json.parseFromSlice(Value, std.testing.allocator, fixture_replies[index].body, .{ .allocate = .alloc_always });
        defer btc.deinit();
        const detail = &btc.value.object.getPtr("data").?.array.items[0].object.getPtr("details").?.array.items[0];
        detail.object.getPtr("ccy").?.* = .{ .string = "BTC" };
        detail.object.getPtr("eq").?.* = .{ .string = "0.000001" };
        const body = try std.json.Stringify.valueAlloc(std.testing.allocator, btc.value, .{});
        defer std.testing.allocator.free(body);
        try expectRejectedResponse(index, body, false);
        var explicit_cleanup = TestSource{};
        explicit_cleanup.replies[index].body = body;
        try run(std.testing.allocator, &explicit_cleanup, 1700000000000, fixture_uid_hash, true);
        detail.object.getPtr("ccy").?.* = .{ .string = "ETH" };
        const eth = try std.json.Stringify.valueAlloc(std.testing.allocator, btc.value, .{});
        defer std.testing.allocator.free(eth);
        try expectRejectedResponse(index, eth, true);
    }
    var large_equity = TestSource{};
    var large_number: [515]u8 = @splat('9');
    large_number[512] = '.';
    const body = try modifiedFixture(14, .detail, "eq", .{ .string = &large_number });
    defer std.testing.allocator.free(body);
    large_equity.replies[14].body = body;
    try run(std.testing.allocator, &large_equity, 1700000000000, fixture_uid_hash, false);
}

test "Demo account guard releases parsed responses on every allocator failure" {
    const Operation = struct {
        fn check(allocator: Allocator) !void {
            var source = TestSource{};
            try run(allocator, &source, 1700000000000, fixture_uid_hash, false);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Operation.check, .{});
}
