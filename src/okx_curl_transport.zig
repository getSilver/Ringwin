//! Qualified libcurl C-ABI boundary for the OKX transport owner.
//! This module is built separately because its headers and static library are
//! bootstrapped into the ignored build area by tools/bootstrap-libcurl.ps1.

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

pub const max_headers = 16;
pub const Outcome = enum { proven_before_send, response, write_or_response_uncertain };

pub const Response = struct {
    outcome: Outcome,
    body_len: usize,
    http_status: c_long,
    curl_code: c_int,
};

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
