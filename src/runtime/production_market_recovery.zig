//! Replays the market-feed role's own durable capture over its control connection.
const std = @import("std");
const durable = @import("../persistence/durable_store.zig");
const raw = @import("../persistence/raw_ingress.zig");
const codec = @import("../persistence/canonical_event_codec.zig");
const engine = @import("production_engine.zig");
const okx = @import("../adapters/okx/okx_market_feed.zig");
const protocol = @import("../adapters/okx/okx_public_market.zig");
const market = @import("../market/market_feed_adapter.zig");

const Config = struct {
    source: engine.RecoverySource,
    environment: market.Environment,
    config_version: u64,
    okx_binding: protocol.Binding,
};

pub fn replay(init: std.process.Init, dir: std.Io.Dir, path: []const u8, stream: std.Io.net.Stream) !void {
    var writer_storage: [256]u8 = undefined;
    var output = stream.writer(init.io, &writer_storage);
    var started = false;
    sweep(init, dir, path, &output.interface, &started) catch |err| {
        std.log.warn("market-feed recovery: {s}", .{@errorName(err)});
        if (started) {
            try output.interface.writeInt(u32, std.math.maxInt(u32), .little);
        } else {
            try output.interface.writeInt(u64, 0, .little);
        }
        try output.interface.flush();
        return;
    };
    try output.interface.writeInt(u32, 0, .little);
    try output.interface.flush();
}

fn sweep(init: std.process.Init, dir: std.Io.Dir, path: []const u8, output: *std.Io.Writer, started: *bool) !void {
    var config_bytes: [4096]u8 = undefined;
    const bytes = try dir.readFile(init.io, "market-recovery.json", &config_bytes);
    if (bytes.len == config_bytes.len) return error.InvalidRecoveryConfiguration;
    const parsed = try std.json.parseFromSlice(Config, init.gpa, bytes, .{});
    defer parsed.deinit();
    const config = parsed.value;
    if (!config.source.valid() or config.source.venue != 1 or config.config_version == 0)
        return error.InvalidRecoveryConfiguration;
    const storage = try init.gpa.create(durable.LinuxFileAdapter);
    defer init.gpa.destroy(storage);
    storage.* = .{ .dir = undefined };
    try storage.initLinux(init.io, path);
    defer storage.close(init.io);
    const identity: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = config.source.raw_stream };
    const capture = try storage.interface().recover(init.io, identity);
    if (capture.gate != .open or capture.committed_barrier == 0 or capture.committed_barrier != capture.last_sequence)
        return error.RawIngressUnavailable;

    const feed = try init.gpa.create(okx.OkxMarketFeed);
    defer init.gpa.destroy(feed);
    feed.* = okx.OkxMarketFeed.init(.{ .ptr = feed, .append_fn = Replay.refuseAppend });
    _ = try feed.bind(config.okx_binding);
    try feed.adapter().start(.{
        .venue = config.source.venue,
        .environment = config.environment,
        .subscription_set = config.source.raw_stream,
        .config_version = config.config_version,
        .session = config.source.session,
        .output_capacity = protocol.max_events_per_ingress,
    });
    var consumer: Replay = .{ .feed = feed, .allocator = init.gpa, .output = output };
    try output.writeInt(u64, capture.committed_barrier, .little);
    for ([_]u64{ config.source.venue, config.source.raw_stream, config.source.session }) |part|
        try output.writeInt(u64, part, .little);
    try output.flush();
    started.* = true;
    try raw.replayCommitted(storage.interface(), init.io, identity, .{ .ptr = &consumer, .consume_fn = Replay.consume });
}

const Replay = struct {
    feed: *okx.OkxMarketFeed,
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,

    fn refuseAppend(_: *anyopaque, _: protocol.RawIngressRecord, _: []const u8) protocol.RawSinkError!u64 {
        return error.Unavailable;
    }

    fn consume(ptr: *anyopaque, sequence: u64, record: protocol.RawIngressRecord, bytes: []const u8) !void {
        const self: *Replay = @ptrCast(@alignCast(ptr));
        if (record.origin != 0) return error.UnknownCaptureRoute;
        try self.feed.replay(self.allocator, record.source_session, .{
            .receive_time_utc_ns = record.receive_time_utc_ns,
            .monotonic_time_ns = record.monotonic_time_ns,
            .wall_time_utc_ns = record.wall_time_utc_ns,
        }, .{ .stream_sequence = sequence, .sha256 = record.sha256 }, bytes);
        if (self.feed.rejected) return error.ReplayRejected;
        while (try self.feed.adapter().tryDrain()) |batch| {
            for (batch.slice()) |event| {
                var frame_storage: [codec.max_encoded_len]u8 = undefined;
                const frame = try codec.encode(&frame_storage, event);
                if (frame.len > engine.max_input_bytes) return error.VenueRecoveryFrameTooLarge;
                try self.output.writeInt(u32, @intCast(frame.len), .little);
                try self.output.writeAll(frame);
                try self.output.flush();
            }
        }
    }
};
