//! Qualified libcurl C-ABI boundary for the OKX transport owner.
//! This module is built separately because its headers and static library are
//! bootstrapped into the ignored build area by tools/bootstrap-libcurl.ps1.

const std = @import("std");
const auth = @import("okx_rest_auth.zig");
const live = @import("okx_live_chain.zig");
const market = @import("okx_public_market.zig");

pub const required_version: u32 = 0x081500; // 8.21.0

extern fn ringwin_curl_global_init() c_int;
extern fn ringwin_curl_global_cleanup() void;
extern fn ringwin_curl_probe(required_version: u32) c_int;
extern fn ringwin_curl_request(
    url: [*:0]const u8,
    method: [*:0]const u8,
    headers: [*]const [*:0]const u8,
    header_count: usize,
    body: [*]const u8,
    body_len: usize,
    proxy: ?[*:0]const u8,
    response: [*]u8,
    response_capacity: usize,
    response_len: *usize,
    http_status: *c_long,
    curl_code: *c_int,
) c_int;
extern fn ringwin_ws_create(url: [*:0]const u8, proxy: ?[*:0]const u8) ?*anyopaque;
extern fn ringwin_ws_connect(ws: *anyopaque) c_int;
extern fn ringwin_ws_send_text(ws: *anyopaque, bytes: [*]const u8, length: usize) c_int;
extern fn ringwin_ws_recv_message(ws: *anyopaque, bytes: [*]u8, capacity: usize, length: *usize, timeout_ms: c_int) c_int;
extern fn ringwin_ws_cancel(ws: *anyopaque) c_int;
extern fn ringwin_ws_destroy(ws: *anyopaque) void;

pub const max_headers = 16;
pub const Outcome = enum { proven_before_send, response, write_or_response_uncertain };

pub const Response = struct {
    outcome: Outcome,
    body_len: usize,
    http_status: c_long,
    curl_code: c_int,
};

pub const TransportOwner = struct {
    pub const Method = enum { get, post };
    credentials: auth.Credentials,
    proxy: ?[:0]const u8,
    source_session: u64,
    timestamp: [25]u8 = @splat(0),
    timestamp_len: u8 = 0,
    times: market.Times = .{ .receive_time_utc_ns = 0, .monotonic_time_ns = 0, .wall_time_utc_ns = 0 },
    response: [market.max_raw_frame_bytes]u8 = undefined,
    ws: ?*anyopaque = null,

    pub fn init(credentials: auth.Credentials, proxy: ?[:0]const u8, source_session: u64) !TransportOwner {
        if (source_session == 0) return error.InvalidSourceSession;
        return .{ .credentials = credentials, .proxy = proxy, .source_session = source_session };
    }

    pub fn deinit(self: *RestOwner) void {
        self.wsDisconnect();
        self.credentials.deinit();
        @memset(&self.timestamp, 0);
        @memset(&self.response, 0);
    }

    pub fn prepare(self: *RestOwner, timestamp: []const u8, times: market.Times) !void {
        if (timestamp.len != 24 or timestamp[10] != 'T' or timestamp[23] != 'Z')
            return error.InvalidTimestamp;
        @memcpy(self.timestamp[0..timestamp.len], timestamp);
        self.timestamp[timestamp.len] = 0;
        self.timestamp_len = @intCast(timestamp.len);
        self.times = times;
    }

    pub fn transport(self: *RestOwner) live.Transport {
        return .{ .ptr = self, .submit_fn = submit };
    }

    pub fn wsConnect(self: *RestOwner) !void {
        if (self.ws != null) return error.AlreadyConnected;
        const session = ringwin_ws_create(
            "wss://wspap.okx.com/ws/v5/private",
            if (self.proxy) |value| value.ptr else null,
        ) orelse return error.WebSocketInitFailed;
        errdefer ringwin_ws_destroy(session);
        try wsResult(ringwin_ws_connect(session));
        self.ws = session;
    }

    pub fn wsLogin(self: *RestOwner, timestamp_seconds: []const u8) !void {
        const session = self.ws orelse return error.NotConnected;
        var payload = try auth.websocketLogin(&self.credentials, timestamp_seconds);
        defer payload.clear();
        try wsResult(ringwin_ws_send_text(session, payload.slice().ptr, payload.slice().len));
    }

    pub fn wsSend(self: *RestOwner, message: []const u8) !void {
        const session = self.ws orelse return error.NotConnected;
        if (message.len == 0 or message.len > market.max_raw_frame_bytes) return error.InvalidMessage;
        try wsResult(ringwin_ws_send_text(session, message.ptr, message.len));
    }

    pub fn wsReceive(self: *RestOwner, destination: []u8, timeout_ms: u31) ![]u8 {
        const session = self.ws orelse return error.NotConnected;
        if (destination.len == 0 or destination.len > market.max_raw_frame_bytes) return error.InvalidMessageBuffer;
        var length: usize = 0;
        try wsResult(ringwin_ws_recv_message(session, destination.ptr, destination.len, &length, @intCast(timeout_ms)));
        return destination[0..length];
    }

    pub fn wsCancel(self: *RestOwner) !void {
        try wsResult(ringwin_ws_cancel(self.ws orelse return error.NotConnected));
    }

    pub fn wsDisconnect(self: *RestOwner) void {
        if (self.ws) |session| ringwin_ws_destroy(session);
        self.ws = null;
    }

    fn submit(ptr: *anyopaque, path: []const u8, body: []const u8) live.TransportResult {
        const self: *RestOwner = @ptrCast(@alignCast(ptr));
        return self.request(.post, path, body);
    }

    pub fn request(self: *RestOwner, method: Method, path: []const u8, body: []const u8) live.TransportResult {
        if (self.timestamp_len == 0) return self.beforeSend();
        if (path.len == 0 or path[0] != '/') return self.beforeSend();
        var url_buffer: [512]u8 = @splat(0);
        const url = std.fmt.bufPrint(url_buffer[0 .. url_buffer.len - 1], "https://openapi.okx.com{s}", .{path}) catch
            return self.beforeSend();
        url_buffer[url.len] = 0;
        const timestamp = self.timestamp[0..self.timestamp_len];
        const method_text: [:0]const u8 = switch (method) { .get => "GET", .post => "POST" };
        const signed = auth.headers(&self.credentials, timestamp, method_text, path, body) catch
            return self.beforeSend();
        const signed_slices = signed.slices();
        const headers = [_][:0]const u8{
            signed_slices[0], signed_slices[1], signed_slices[2], signed_slices[3], signed_slices[4],
            "Content-Type: application/json",
        };
        const response = perform(
            url_buffer[0..url.len :0],
            method_text,
            &headers,
            body,
            self.proxy,
            &self.response,
        ) catch return self.beforeSend();
        return .{
            .outcome = switch (response.outcome) {
                .proven_before_send => .proven_before_send,
                .response => .response,
                .write_or_response_uncertain => .write_or_response_uncertain,
            },
            .response = if (response.outcome == .response) self.response[0..response.body_len] else null,
            .source_session = self.source_session,
            .times = self.times,
        };
    }

    fn beforeSend(self: *const RestOwner) live.TransportResult {
        return .{
            .outcome = .proven_before_send,
            .source_session = self.source_session,
            .times = self.times,
        };
    }
};

pub const RestOwner = TransportOwner;

fn wsResult(code: c_int) !void {
    return switch (code) {
        0 => {},
        1 => error.WebSocketInvalidState,
        2 => error.WebSocketTimeout,
        3 => error.WebSocketCancelled,
        4 => error.WebSocketClosed,
        5 => error.WebSocketMessageTooLarge,
        6 => error.WebSocketTransport,
        7 => error.WebSocketNonTextMessage,
        else => error.WebSocketInvalidResult,
    };
}

pub const Runtime = struct {
    pub fn init() !Runtime {
        if (ringwin_curl_global_init() != 0)
            return error.CurlGlobalInitFailed;
        errdefer ringwin_curl_global_cleanup();
        try verifyRuntime();
        return .{};
    }

    pub fn deinit(_: *Runtime) void {
        ringwin_curl_global_cleanup();
    }
};

pub fn verifyRuntime() !void {
    switch (ringwin_curl_probe(required_version)) {
        0 => {},
        1 => return error.MissingCurlVersionInfo,
        2 => return error.WrongCurlVersion,
        3 => return error.WrongTlsBackend,
        4 => return error.MissingRequiredProtocol,
        else => return error.InvalidProbeResult,
    }
}

pub fn perform(
    url: [:0]const u8,
    method: [:0]const u8,
    headers: []const [:0]const u8,
    body: []const u8,
    proxy: ?[:0]const u8,
    response_buffer: []u8,
) !Response {
    if (headers.len > max_headers) return error.TooManyHeaders;
    if (response_buffer.len == 0) return error.EmptyResponseBuffer;
    var header_ptrs: [max_headers][*:0]const u8 = undefined;
    for (headers, 0..) |header, index| header_ptrs[index] = header.ptr;
    var response_len: usize = 0;
    var http_status: c_long = 0;
    var curl_code: c_int = 0;
    const code = ringwin_curl_request(
        url.ptr,
        method.ptr,
        &header_ptrs,
        headers.len,
        body.ptr,
        body.len,
        if (proxy) |value| value.ptr else null,
        response_buffer.ptr,
        response_buffer.len,
        &response_len,
        &http_status,
        &curl_code,
    );
    return .{
        .outcome = switch (code) {
            0 => .response,
            1 => .proven_before_send,
            2 => .write_or_response_uncertain,
            else => return error.InvalidTransportResult,
        },
        .body_len = response_len,
        .http_status = http_status,
        .curl_code = curl_code,
    };
}

test "linked libcurl is exactly the resolved Schannel websocket baseline" {
    var runtime = try Runtime.init();
    defer runtime.deinit();
}

test "REST owner fails before send until a signing time is prepared" {
    var owner = try RestOwner.init(try auth.Credentials.init("key", "secret", "pass"), null, 1);
    defer owner.deinit();
    const result = owner.transport().submit("/api/v5/trade/order", "{}");
    try std.testing.expect(result.outcome == .proven_before_send);
    try std.testing.expect(result.response == null);
}
