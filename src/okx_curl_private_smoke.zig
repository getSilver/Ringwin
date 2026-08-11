const std = @import("std");
const curl = @import("okx_curl_transport.zig");
const auth = @import("okx_rest_auth.zig");

pub fn main(init: std.process.Init) !void {
    const key = init.environ_map.get("RINGWIN_OKX_KEY") orelse return error.MissingCredential;
    const secret = init.environ_map.get("RINGWIN_OKX_SECRET") orelse return error.MissingCredential;
    const passphrase = init.environ_map.get("RINGWIN_OKX_PASSPHRASE") orelse return error.MissingCredential;
    const timestamp = init.environ_map.get("RINGWIN_OKX_TIMESTAMP") orelse return error.MissingTimestamp;

    var runtime = try curl.Runtime.init();
    defer runtime.deinit();
    var owner = try curl.RestOwner.init(try auth.Credentials.init(key, secret, passphrase), null, 1);
    defer owner.deinit();
    try owner.prepare(timestamp, .{
        .receive_time_utc_ns = 1,
        .monotonic_time_ns = 1,
        .wall_time_utc_ns = 1,
    });
    const result = owner.request(.get, "/api/v5/account/config", "");
    if (result.outcome != .response) return error.PrivateRequestUncertain;
    const parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, result.response.?, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) { .object => |value| value, else => return error.InvalidResponse };
    const code = switch (object.get("code") orelse return error.InvalidResponse) {
        .string => |value| value,
        else => return error.InvalidResponse,
    };
    if (!std.mem.eql(u8, code, "0")) return error.OkxRejectedRequest;

    var out_buffer: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    try out.interface.writeAll("transport=zig-libcurl auth=hmac-sha256 environment=demo private_rest=ok writes=0\n");
    try out.interface.flush();
}
