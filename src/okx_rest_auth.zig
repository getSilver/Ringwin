//! Fixed OKX Demo REST authentication owner.
//! Credentials stay in bounded memory, signatures are generated incrementally,
//! and callers receive complete NUL-terminated headers for the curl seam.

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Credentials = struct {
    api_key: Secret(128),
    secret_key: Secret(128),
    passphrase: Secret(128),

    pub fn init(api_key: []const u8, secret_key: []const u8, passphrase: []const u8) !Credentials {
        return .{
            .api_key = try Secret(128).init(api_key),
            .secret_key = try Secret(128).init(secret_key),
            .passphrase = try Secret(128).init(passphrase),
        };
    }

    pub fn deinit(self: *Credentials) void {
        self.api_key.clear();
        self.secret_key.clear();
        self.passphrase.clear();
    }
};

fn Secret(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: u8,

        fn init(value: []const u8) !@This() {
            if (value.len == 0 or value.len > capacity) return error.InvalidCredential;
            var result: @This() = .{ .len = @intCast(value.len) };
            @memcpy(result.bytes[0..value.len], value);
            return result;
        }

        fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }

        fn clear(self: *@This()) void {
            @memset(&self.bytes, 0);
            self.len = 0;
        }
    };
}

pub const Headers = struct {
    storage: [5][256]u8 = @splat(@splat(0)),
    lengths: [5]u8 = @splat(0),

    pub fn slices(self: *const Headers) [5][:0]const u8 {
        var result: [5][:0]const u8 = undefined;
        for (&result, 0..) |*item, index| {
            item.* = self.storage[index][0..self.lengths[index] :0];
        }
        return result;
    }
};

pub fn sign(
    credentials: *const Credentials,
    timestamp: []const u8,
    method: []const u8,
    request_path: []const u8,
    body: []const u8,
) [44]u8 {
    var hmac = HmacSha256.init(credentials.secret_key.slice());
    hmac.update(timestamp);
    hmac.update(method);
    hmac.update(request_path);
    hmac.update(body);
    var digest: [HmacSha256.mac_length]u8 = undefined;
    hmac.final(&digest);
    var encoded: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &digest);
    return encoded;
}

pub fn headers(
    credentials: *const Credentials,
    timestamp: []const u8,
    method: []const u8,
    request_path: []const u8,
    body: []const u8,
) !Headers {
    if (timestamp.len == 0 or method.len == 0 or request_path.len == 0 or request_path[0] != '/')
        return error.InvalidRequest;
    const signature = sign(credentials, timestamp, method, request_path, body);
    var result: Headers = .{};
    try putHeader(&result, 0, "OK-ACCESS-KEY: ", credentials.api_key.slice());
    try putHeader(&result, 1, "OK-ACCESS-SIGN: ", &signature);
    try putHeader(&result, 2, "OK-ACCESS-TIMESTAMP: ", timestamp);
    try putHeader(&result, 3, "OK-ACCESS-PASSPHRASE: ", credentials.passphrase.slice());
    try putHeader(&result, 4, "x-simulated-trading: ", "1");
    return result;
}

fn putHeader(result: *Headers, index: usize, prefix: []const u8, value: []const u8) !void {
    const length = prefix.len + value.len;
    if (length >= result.storage[index].len) return error.HeaderTooLarge;
    @memcpy(result.storage[index][0..prefix.len], prefix);
    @memcpy(result.storage[index][prefix.len..length], value);
    result.storage[index][length] = 0;
    result.lengths[index] = @intCast(length);
}

test "OKX signature and Demo headers are stable and credentials are cleared" {
    var credentials = try Credentials.init("key", "secret", "pass");
    const timestamp = "2020-12-08T09:08:57.715Z";
    const path = "/api/v5/trade/order";
    const body = "{\"x\":1}";
    const signature = sign(&credentials, timestamp, "POST", path, body);
    try std.testing.expectEqualSlices(u8, "uZ0OB9jFCN1FU9vKX6ED/rY/T+NyFw5os4M+UlJknIk=", &signature);
    const built = try headers(&credentials, timestamp, "POST", path, body);
    const values = built.slices();
    try std.testing.expectEqualStrings("x-simulated-trading: 1", values[4]);
    credentials.deinit();
    try std.testing.expect(credentials.secret_key.len == 0);
    try std.testing.expect(std.mem.allEqual(u8, &credentials.secret_key.bytes, 0));
}
