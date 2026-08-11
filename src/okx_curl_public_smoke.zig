const std = @import("std");
const curl = @import("okx_curl_transport.zig");

pub fn main(init: std.process.Init) !void {
    var runtime = try curl.Runtime.init();
    defer runtime.deinit();
    var response: [4096]u8 = undefined;
    const result = try curl.perform(
        "https://openapi.okx.com/api/v5/public/time",
        "GET",
        &.{},
        "",
        null,
        &response,
    );
    var out_buffer: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    try out.interface.print("transport=libcurl-8.21.0 tls=Schannel outcome={s} status={d} bytes={d} curl={d}\n", .{
        @tagName(result.outcome), result.http_status, result.body_len, result.curl_code,
    });
    try out.interface.flush();
    if (result.outcome != .response or result.http_status != 200 or result.body_len == 0)
        return error.PublicSmokeFailed;
}
