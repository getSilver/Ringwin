//! Synthetic offline callbacks. No credential or network capabilities.
const std = @import("std");
const hl = @import("../../adapters/hyperliquid/hyperliquid_venue_adapter.zig");
const signer = @import("../../adapters/hyperliquid/hyperliquid_signer.zig");
const raw = @import("../../persistence/raw_ingress.zig");
pub const times: hl.Times = .{ .receive_time_utc_ns = 1_800_000_000_100_000_000, .wall_time_utc_ns = 1_800_000_000_100_000_000, .monotonic_time_ns = 2 * std.time.ns_per_s };
pub const IO = struct {
    sink: raw.DurableSink,
    sends: u64 = 0,
    recover_funding: bool = false,
    session: u64 = 7,
    current: hl.Times = times,
    outcome: @FieldType(hl.TransportResult, "outcome") = .response,
    pub fn now(ptr: *anyopaque) hl.Times {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.current;
    }
    pub fn sign(_: *anyopaque, request: signer.Request) !signer.SignedAction {
        return .{ .nonce = request.now_ms, .digest = @splat(1), .signature = .{ .r = @splat(1), .s = @splat(1), .v = 27 }, .session = request.session, .funding_account = @splat(2), .subaccount = null };
    }
    pub fn check(_: *anyopaque, _: u64, _: u64, _: bool) !void {}
    pub fn query(ptr: *anyopaque, bytes: []const u8) hl.TransportResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const response = if (std.mem.indexOf(u8, bytes, "orderStatus") != null) "{\"status\":\"unknownOid\"}" else if (std.mem.indexOf(u8, bytes, "userAbstraction") != null) "\"default\"" else if (std.mem.indexOf(u8, bytes, "\"clearinghouseState\"") != null) "{\"assetPositions\":[]}" else if (std.mem.indexOf(u8, bytes, "spotClearinghouseState") != null) "{\"balances\":[]}" else if (self.recover_funding and std.mem.indexOf(u8, bytes, "\"userFunding\"") != null) "[{\"time\":1800000000001,\"delta\":{\"type\":\"funding\",\"usdc\":\"-0.01\"}}]" else "[]";
        return .{ .outcome = .response, .bytes = response, .session = self.session, .times = self.current };
    }
    pub fn submit(ptr: *anyopaque, request: hl.SignedRequest) hl.TransportResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.sends += 1;
        std.debug.assert(std.mem.indexOf(u8, request.action_json, "0x") != null);
        return .{ .session = self.session, .times = self.current, .outcome = self.outcome, .bytes = if (self.outcome == .response) "{\"status\":\"ok\",\"response\":{\"type\":\"order\",\"data\":{\"statuses\":[{\"resting\":{\"oid\":42}}]}}}" else null };
    }
    fn append(ptr: *anyopaque, record: hl.RawRecord, bytes: []const u8) hl.RawError!u64 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const sink = self.sink.interface();
        if (record.venue != 1 or record.account != 2 or record.session != 7) return error.Unavailable;
        return sink.append_fn(sink.ptr, .{ .origin = @intFromEnum(record.input), .source_session = @intCast(record.session), .receive_time_utc_ns = record.times.receive_time_utc_ns, .monotonic_time_ns = record.times.monotonic_time_ns, .wall_time_utc_ns = record.times.wall_time_utc_ns, .byte_len = record.byte_len, .sha256 = record.sha256 }, bytes);
    }
};
