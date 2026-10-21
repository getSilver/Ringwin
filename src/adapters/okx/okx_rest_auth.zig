//! Auth buffers own protected mappings; owners must not be copied after initialization.
const std = @import("std");
const builtin = @import("builtin");
const protected = @import("../../security/protected_memory.zig");
const Sha256 = @import("../../security/credential_crypto/sha256.zig").Sha256;

/// Owns one mapping. TransportOwner borrows this object until transport deinit.
/// init inputs are borrowed only during the call; callers erase their own inputs.
pub const Credentials = struct {
    buffer: protected.Buffer,
    lengths: [3]u8 = @splat(0),
    sealed: bool = false,
    pub const Fields = struct { api_key: []u8, secret_key: []u8, passphrase: []u8 };

    pub fn initEmpty() !Credentials {
        return .{ .buffer = try protected.Buffer.init(384) };
    }
    pub fn initEmptyForTesting(backend: protected.Backend) !Credentials {
        if (!builtin.is_test) @compileError("credential backend is test-only");
        return .{ .buffer = try protected.Buffer.initForTesting(384, backend) };
    }
    pub fn init(api_key: []const u8, secret_key: []const u8, passphrase: []const u8) !Credentials {
        for ([_][]const u8{ api_key, secret_key, passphrase }) |value|
            if (value.len == 0 or value.len > 128) return error.InvalidCredential;
        var result = try initEmpty();
        errdefer result.deinit();
        const fields = try result.writableFields();
        @memcpy(fields.api_key[0..api_key.len], api_key);
        @memcpy(fields.secret_key[0..secret_key.len], secret_key);
        @memcpy(fields.passphrase[0..passphrase.len], passphrase);
        try result.sealLengths(api_key.len, secret_key.len, passphrase.len);
        return result;
    }
    /// Borrowed destination for a one-time restricted-input parser; no raw secret return value.
    pub fn writableFields(self: *Credentials) !Fields {
        if (self.sealed) return error.CredentialSealed;
        const bytes = try self.buffer.writable();
        return .{ .api_key = bytes[0..128], .secret_key = bytes[128..256], .passphrase = bytes[256..384] };
    }
    pub fn sealLengths(self: *Credentials, key_len: usize, secret_len: usize, pass_len: usize) !void {
        if (self.sealed) return error.CredentialSealed;
        for ([_]usize{ key_len, secret_len, pass_len }) |length|
            if (length == 0 or length > 128) return error.InvalidCredential;
        try self.buffer.freeze();
        self.lengths = .{ @intCast(key_len), @intCast(secret_len), @intCast(pass_len) };
        self.sealed = true;
    }
    fn field(self: *const Credentials, index: usize) ![]const u8 {
        if (!self.sealed or self.buffer.length == 0) return error.InvalidCredential;
        return self.buffer.bytes()[index * 128 ..][0..self.lengths[index]];
    }
    pub fn protection(self: *const Credentials) protected.Report {
        return self.buffer.report();
    }
    pub fn deinit(self: *Credentials) void {
        self.buffer.deinit();
        self.lengths = @splat(0);
        self.sealed = false;
    }
};

pub const Headers = struct {
    buffer: protected.Buffer,
    lengths: [5]u8 = @splat(0),
    pub fn slices(self: *const Headers) [5][:0]const u8 {
        var result: [5][:0]const u8 = undefined;
        for (&result, 0..) |*item, index| item.* = self.buffer.bytes()[index * 256 ..][0..self.lengths[index] :0];
        return result;
    }
    pub fn clear(self: *Headers) void {
        self.buffer.deinit();
        self.lengths = @splat(0);
    }
};
pub const LoginPayload = struct {
    buffer: protected.Buffer,
    len: usize = 0,
    pub fn slice(self: *const LoginPayload) []const u8 {
        return self.buffer.bytes()[0..self.len];
    }
    pub fn clear(self: *LoginPayload) void {
        self.buffer.deinit();
        self.len = 0;
    }
};

fn allocate(credentials: *const Credentials, length: usize) !protected.Buffer {
    if (builtin.is_test) return protected.Buffer.initForTesting(length, credentials.buffer.backend);
    return protected.Buffer.init(length);
}

const SigningScratch = struct {
    inner: Sha256,
    outer: Sha256,
    key_hash: Sha256,
    key: [64]u8,
    inner_pad: [64]u8,
    outer_pad: [64]u8,
    digest: [32]u8,
};

/// RFC 2104 HMAC-SHA256. Output must belong to caller-controlled protected memory
/// for real credentials. No raw key/pad/digest/context is returned by value.
pub fn sign(credentials: *const Credentials, timestamp: []const u8, method: []const u8, request_path: []const u8, body: []const u8, encoded: *[44]u8) !void {
    errdefer std.crypto.secureZero(u8, encoded);
    const key = try credentials.field(1);
    var scratch = try allocate(credentials, @sizeOf(SigningScratch));
    defer scratch.deinit();
    const state: *SigningScratch = @ptrCast(@alignCast((try scratch.writable()).ptr));
    if (key.len > 64) {
        state.key_hash = Sha256.init(.{});
        state.key_hash.update(key);
        state.key_hash.final(state.key[0..32]);
    } else @memcpy(state.key[0..key.len], key);
    for (state.key, 0..) |byte, index| {
        state.inner_pad[index] = byte ^ 0x36;
        state.outer_pad[index] = byte ^ 0x5c;
    }
    state.inner = Sha256.init(.{});
    state.inner.update(&state.inner_pad);
    state.inner.update(timestamp);
    state.inner.update(method);
    state.inner.update(request_path);
    state.inner.update(body);
    state.inner.final(&state.digest);
    state.outer = Sha256.init(.{});
    state.outer.update(&state.outer_pad);
    state.outer.update(&state.digest);
    state.outer.final(&state.digest);
    _ = std.base64.standard.Encoder.encode(encoded, &state.digest);
}

pub fn websocketLogin(credentials: *const Credentials, timestamp_seconds: []const u8) !LoginPayload {
    if (timestamp_seconds.len == 0 or timestamp_seconds.len > 20) return error.InvalidTimestamp;
    var result: LoginPayload = .{ .buffer = try allocate(credentials, 768 + 44) };
    errdefer result.clear();
    const bytes = try result.buffer.writable();
    const signature: *[44]u8 = bytes[768..812];
    try sign(credentials, timestamp_seconds, "GET", "/users/self/verify", "", signature);
    defer std.crypto.secureZero(u8, signature);
    var writer: std.Io.Writer = .fixed(bytes[0..767]);
    try std.json.Stringify.value(.{ .op = "login", .args = &.{.{
        .apiKey = try credentials.field(0),
        .passphrase = try credentials.field(2),
        .timestamp = timestamp_seconds,
        .sign = signature,
    }} }, .{}, &writer);
    result.len = writer.end;
    bytes[result.len] = 0;
    return result;
}

pub fn headers(credentials: *const Credentials, timestamp: []const u8, method: []const u8, request_path: []const u8, body: []const u8) !Headers {
    if (timestamp.len == 0 or method.len == 0 or request_path.len == 0 or request_path[0] != '/') return error.InvalidRequest;
    var result: Headers = .{ .buffer = try allocate(credentials, 1280 + 44) };
    errdefer result.clear();
    const signature: *[44]u8 = (try result.buffer.writable())[1280..1324];
    try sign(credentials, timestamp, method, request_path, body, signature);
    defer std.crypto.secureZero(u8, signature);
    try putHeader(&result, 0, "OK-ACCESS-KEY: ", try credentials.field(0));
    try putHeader(&result, 1, "OK-ACCESS-SIGN: ", signature);
    try putHeader(&result, 2, "OK-ACCESS-TIMESTAMP: ", timestamp);
    try putHeader(&result, 3, "OK-ACCESS-PASSPHRASE: ", try credentials.field(2));
    try putHeader(&result, 4, "x-simulated-trading: ", "1");
    return result;
}
fn putHeader(result: *Headers, index: usize, prefix: []const u8, value: []const u8) !void {
    for (value) |byte| if (byte == 0 or byte == '\r' or byte == '\n') return error.InvalidHeaderValue;
    const length = prefix.len + value.len;
    if (length >= 256) return error.HeaderTooLarge;
    const destination = (try result.buffer.writable())[index * 256 ..][0..256];
    @memcpy(destination[0..prefix.len], prefix);
    @memcpy(destination[prefix.len..length], value);
    destination[length] = 0;
    result.lengths[index] = @intCast(length);
}

test "OKX signature and Demo headers are stable and credentials are cleared" {
    var credentials = try Credentials.init("key", "secret", "pass");
    defer credentials.deinit();
    var built = try headers(&credentials, "2020-12-08T09:08:57.715Z", "POST", "/api/v5/trade/order", "{\"x\":1}");
    defer built.clear();
    try std.testing.expectEqualStrings("OK-ACCESS-SIGN: uZ0OB9jFCN1FU9vKX6ED/rY/T+NyFw5os4M+UlJknIk=", built.slices()[1]);
    try std.testing.expectEqualStrings("x-simulated-trading: 1", built.slices()[4]);
    var login = try websocketLogin(&credentials, "1607447337");
    try std.testing.expect(std.mem.indexOf(u8, login.slice(), "\"op\":\"login\"") != null);
    login.clear();
    try std.testing.expectEqual(@as(usize, 0), login.buffer.length);
    credentials.deinit();
    try std.testing.expectEqual(@as(usize, 0), credentials.buffer.length);
}

test "credential direct protected import validates complete fields before signing" {
    var credentials = try Credentials.initEmpty();
    defer credentials.deinit();
    const fields = try credentials.writableFields();
    @memcpy(fields.api_key[0..3], "key");
    @memcpy(fields.secret_key[0..6], "secret");
    @memcpy(fields.passphrase[0..4], "pass");
    try credentials.sealLengths(3, 6, 4);
    try std.testing.expect(credentials.protection().locked);
    var built = try headers(&credentials, "2020-12-08T09:08:57.715Z", "POST", "/api/v5/trade/order", "{\"x\":1}");
    defer built.clear();
    try std.testing.expectEqualStrings("OK-ACCESS-SIGN: uZ0OB9jFCN1FU9vKX6ED/rY/T+NyFw5os4M+UlJknIk=", built.slices()[1]);
}

test "HMAC RFC4231 vector and hashed long key remain compatible" {
    const key: [20]u8 = @splat(0x0b);
    var credentials = try Credentials.init("key", &key, "pass");
    defer credentials.deinit();
    var output: [44]u8 = undefined; // synthetic public vector only
    try sign(&credentials, "Hi ", "There", "", "", &output);
    try std.testing.expectEqualStrings("sDRMYdjbOFNcqK/OrwvxK4gdwgDJgz2nJuk3bC4yz/c=", &output);
    const long_key: [100]u8 = @splat(0xaa);
    var long_credentials = try Credentials.init("key", &long_key, "pass");
    defer long_credentials.deinit();
    try sign(&long_credentials, "long-key-", "message", "", "", &output);
    // Independently generated with Python hmac/hashlib SHA256.
    try std.testing.expectEqualStrings("Zd65U7NPH2ENFwtmcevuNaH/z0+JfNoHr6KVekcufIE=", &output);
}

const TestMemory = struct {
    locks: usize = 0,
    releases: usize = 0,
    fail_lock_at: usize = 0,
    clean: bool = true,
    const Page = []align(std.heap.page_size_min) u8;
    fn backend(self: *TestMemory) protected.Backend {
        return .{ .context = self, .allocate = alloc, .lock = lock, .dontDump = dump, .protect = protect, .unlock = unlock, .release = release };
    }
    fn alloc(_: *anyopaque, length: usize) protected.Error!Page {
        return std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), length);
    }
    fn lock(context: *anyopaque, _: Page) protected.Error!void {
        const self: *TestMemory = @ptrCast(@alignCast(context));
        self.locks += 1;
        if (self.locks == self.fail_lock_at) return error.MemoryLockFailed;
    }
    fn dump(_: *anyopaque, _: Page) protected.Error!void {}
    fn protect(_: *anyopaque, _: Page, _: bool) protected.Error!void {}
    fn unlock(context: *anyopaque, page: Page) void {
        const self: *TestMemory = @ptrCast(@alignCast(context));
        self.clean = self.clean and std.mem.allEqual(u8, page, 0);
    }
    fn release(context: *anyopaque, page: Page) void {
        const self: *TestMemory = @ptrCast(@alignCast(context));
        self.clean = self.clean and std.mem.allEqual(u8, page, 0);
        self.releases += 1;
        std.heap.page_allocator.free(page);
    }
};

test "auth public owners wipe signatures request buffers and failing constructions before release" {
    var memory: TestMemory = .{};
    var credentials = try Credentials.initEmptyForTesting(memory.backend());
    const fields = try credentials.writableFields();
    @memcpy(fields.api_key[0..3], "key");
    @memcpy(fields.secret_key[0..6], "secret");
    @memcpy(fields.passphrase[0..4], "pass");
    try credentials.sealLengths(3, 6, 4);
    try std.testing.expectError(error.CredentialSealed, credentials.writableFields());
    var request = try headers(&credentials, "time", "POST", "/path", "body");
    try std.testing.expectEqualStrings("OK-ACCESS-KEY: key", request.slices()[0]);
    request.clear();
    var login = try websocketLogin(&credentials, "1607447337");
    login.clear();
    const huge_timestamp: [256]u8 = @splat('x');
    try std.testing.expectError(error.HeaderTooLarge, headers(&credentials, &huge_timestamp, "GET", "/path", ""));
    // Header mapping succeeds, scratch mapping lock fails; both are erased.
    memory.fail_lock_at = memory.locks + 2;
    try std.testing.expectError(error.MemoryLockFailed, headers(&credentials, "time", "GET", "/path", ""));
    credentials.deinit();
    try std.testing.expect(memory.clean);
    try std.testing.expectEqual(memory.locks, memory.releases);
    var output: [44]u8 = @splat(0x5a);
    try std.testing.expectError(error.InvalidCredential, sign(&credentials, "time", "GET", "/path", "", &output));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
}

test "auth headers reject credential and timestamp framing injection" {
    for ([_][]const u8{ "key\r\nInjected: true", "key\x00suffix" }) |key| {
        var credentials = try Credentials.init(key, "secret", "pass");
        defer credentials.deinit();
        try std.testing.expectError(error.InvalidHeaderValue, headers(&credentials, "time", "GET", "/path", ""));
    }
    var credentials = try Credentials.init("key", "secret", "pass\nInjected: true");
    defer credentials.deinit();
    try std.testing.expectError(error.InvalidHeaderValue, headers(&credentials, "time", "GET", "/path", ""));
    var valid = try Credentials.init("key", "secret", "pass");
    defer valid.deinit();
    try std.testing.expectError(error.InvalidHeaderValue, headers(&valid, "time\r\nInjected: true", "GET", "/path", ""));
}

test "websocket login serialization failure erases owned request and signature mappings" {
    var memory: TestMemory = .{};
    var credentials = try Credentials.initEmptyForTesting(memory.backend());
    const fields = try credentials.writableFields();
    @memset(fields.api_key, 0);
    @memcpy(fields.secret_key[0..6], "secret");
    @memset(fields.passphrase, 0);
    try credentials.sealLengths(128, 6, 128);
    // JSON escaping expands these valid synthetic fields beyond the bounded payload.
    try std.testing.expectError(error.WriteFailed, websocketLogin(&credentials, "1607447337"));
    credentials.deinit();
    try std.testing.expect(memory.clean);
    try std.testing.expectEqual(memory.locks, memory.releases);
}
