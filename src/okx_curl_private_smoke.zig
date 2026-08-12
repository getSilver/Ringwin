const std = @import("std");
const curl = @import("okx_curl_transport.zig");
const auth = @import("okx_rest_auth.zig");
const private = @import("okx_private_reconciliation.zig");

pub fn main(init: std.process.Init) !void {
    const key = init.environ_map.get("RINGWIN_OKX_KEY") orelse return error.MissingCredential;
    const secret = init.environ_map.get("RINGWIN_OKX_SECRET") orelse return error.MissingCredential;
    const passphrase = init.environ_map.get("RINGWIN_OKX_PASSPHRASE") orelse return error.MissingCredential;
    const timestamp = init.environ_map.get("RINGWIN_OKX_TIMESTAMP") orelse return error.MissingTimestamp;
    const timestamp_seconds = init.environ_map.get("RINGWIN_OKX_TIMESTAMP_SECONDS") orelse return error.MissingTimestamp;

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
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidResponse,
    };
    const code = switch (object.get("code") orelse return error.InvalidResponse) {
        .string => |value| value,
        else => return error.InvalidResponse,
    };
    if (!std.mem.eql(u8, code, "0")) return error.OkxRejectedRequest;

    try owner.wsConnect();
    try owner.wsLogin(timestamp_seconds);
    const message_buffer = try init.gpa.alloc(u8, 1024 * 1024);
    defer init.gpa.free(message_buffer);
    var raw: RawSink = .{};
    var reconciler: private.Reconciler = .{};
    reconciler.beginSession(1);
    const times: private.Times = .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1 };
    var login_ok = false;
    for (0..8) |_| {
        const message = try owner.wsReceive(message_buffer, 10_000);
        const batch = try reconciler.ingestWsMessage(init.gpa, raw.interface(), 1, times, message);
        if (batch.rejection != null) return error.PrivateIngressRejected;
        const frame = try std.json.parseFromSlice(std.json.Value, init.gpa, message, .{});
        defer frame.deinit();
        const frame_object = switch (frame.value) {
            .object => |value| value,
            else => continue,
        };
        if (stringField(frame_object, "event")) |event| {
            if (std.mem.eql(u8, event, "login")) {
                if (stringField(frame_object, "code")) |login_code|
                    if (!std.mem.eql(u8, login_code, "0")) return error.OkxRejectedLogin;
                login_ok = true;
                break;
            }
            if (std.mem.eql(u8, event, "error")) return error.OkxRejectedLogin;
        }
    }
    if (!login_ok) return error.MissingLoginAck;
    try owner.wsSend("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"orders\",\"instType\":\"ANY\"},{\"channel\":\"account\"},{\"channel\":\"positions\",\"instType\":\"ANY\"}]}");
    for (0..24) |_| {
        const message = try owner.wsReceive(message_buffer, 10_000);
        const batch = try reconciler.ingestWsMessage(init.gpa, raw.interface(), 1, times, message);
        if (batch.rejection != null) return error.PrivateIngressRejected;
        if (reconciler.readiness().private_stream_ready) break;
    }
    if (!reconciler.readiness().private_stream_ready)
        return error.IncompletePrivateQualification;
    try owner.wsCancel();
    if (owner.wsReceive(message_buffer, 1_000)) |_| return error.CancelDidNotFenceReceive else |err| {
        if (err != error.WebSocketCancelled) return err;
    }

    var out_buffer: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    try out.interface.print("transport=zig-libcurl-multi auth=hmac-sha256 environment=demo private_rest=ok private_wss=ok raw_ingress={d} writes=0\n", .{raw.count});
    try out.interface.flush();
}

const RawSink = struct {
    count: u64 = 0,

    fn interface(self: *RawSink) private.RawSink {
        return .{ .ptr = self, .append_fn = append };
    }

    fn append(ptr: *anyopaque, record: @import("okx_public_market.zig").RawIngressRecord, bytes: []const u8) private.RawSinkError!u64 {
        const self: *RawSink = @ptrCast(@alignCast(ptr));
        if (record.byte_len != bytes.len) return error.Unavailable;
        self.count += 1;
        return self.count;
    }
};

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}
