//! Binance public-market boundary. Venue wire fields never cross this module.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const market = @import("market_feed_adapter.zig");
const raw = @import("okx_public_market.zig");

const State = enum { idle, running, stopped };

pub const BinanceMarketFeed = struct {
    raw_sink: raw.RawSink,
    state: State = .idle,
    config: ?market.Config = null,
    pending: ?canonical.AdapterOutputBatch = null,

    pub fn init(raw_sink: raw.RawSink) BinanceMarketFeed {
        return .{ .raw_sink = raw_sink };
    }

    pub fn adapter(self: *BinanceMarketFeed) market.MarketFeedAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_drain = drain, .stop = stop } };
    }

    /// Commits each complete Binance frame before any field interpretation.
    pub fn ingestRaw(self: *BinanceMarketFeed, times: raw.Times, frame: []const u8) !raw.RawEvidenceRef {
        if (self.state == .idle) return error.NotStarted;
        if (self.state == .stopped) return error.Stopped;
        if (self.pending != null) return error.OutputPending;
        if (frame.len == 0 or frame.len > raw.max_raw_frame_bytes or frame.len > std.math.maxInt(u32))
            return error.InvalidFrame;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(frame, &digest, .{});
        return self.raw_sink.append(.{
            .source_session = @intCast((self.config orelse return error.NotStarted).session),
            .receive_time_utc_ns = times.receive_time_utc_ns,
            .monotonic_time_ns = times.monotonic_time_ns,
            .wall_time_utc_ns = times.wall_time_utc_ns,
            .byte_len = @intCast(frame.len),
            .sha256 = digest,
        }, frame);
    }

    fn start(ptr: *anyopaque, config: market.Config) market.StartError!void {
        const self: *BinanceMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.venue == 0 or config.subscription_set == 0 or config.session == 0 or
            config.output_capacity == 0 or config.output_capacity > canonical.max_events_per_adapter_batch)
            return error.InvalidConfig;
        self.config = config;
        self.state = .running;
    }

    fn drain(ptr: *anyopaque) market.DrainError!?canonical.AdapterOutputBatch {
        const self: *BinanceMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const pending = self.pending;
        self.pending = null;
        return pending;
    }

    fn stop(ptr: *anyopaque, _: market.DrainDeadline) market.StopError!void {
        const self: *BinanceMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.state = .stopped;
    }
};

test "Binance raw ingress commits before unsupported decoding" {
    const Sink = struct {
        count: u64 = 0,
        fn append(ptr: *anyopaque, _: raw.RawIngressRecord, _: []const u8) raw.RawSinkError!u64 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
            return self.count;
        }
    };
    var sink = Sink{};
    var feed = BinanceMarketFeed.init(.{ .ptr = &sink, .append_fn = Sink.append });
    const adapter = feed.adapter();
    try adapter.start(.{ .venue = 20, .environment = .demo, .subscription_set = 1, .config_version = 1, .session = 2, .output_capacity = 1 });
    const evidence = try feed.ingestRaw(.{ .receive_time_utc_ns = 1, .monotonic_time_ns = 2, .wall_time_utc_ns = 3 }, "{\"e\":\"depthUpdate\"}");
    try std.testing.expectEqual(@as(u64, 1), evidence.stream_sequence);
    try adapter.stop(.{ .monotonic_ns = 1 });
}
