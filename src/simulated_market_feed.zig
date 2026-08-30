const canonical = @import("canonical_event.zig");
const market = @import("market_feed_adapter.zig");
const std = @import("std");

pub const SimulatedMarketFeed = struct {
    started: bool = false,
    pending: ?canonical.AdapterOutputBatch = null,
    venue: canonical.VenueIdentity = 0,
    rules_version: u64 = 0,
    sequence: u64 = 0,
    healthy: bool = false,

    pub fn adapter(self: *SimulatedMarketFeed) market.MarketFeedAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_drain = drain, .stop = stop } };
    }
    fn start(ptr: *anyopaque, config: market.Config) market.StartError!void {
        const self: *SimulatedMarketFeed = @ptrCast(@alignCast(ptr));
        if (self.started) return error.AlreadyStarted;
        if (config.environment != .simulation or config.output_capacity < 6 or config.output_capacity > canonical.max_events_per_adapter_batch) return error.InvalidConfig;
        self.started = true;
        self.venue = config.venue;
        self.rules_version = config.config_version;
        self.sequence = 1;
        self.healthy = true;
        var batch: canonical.AdapterOutputBatch = .{};
        batch.append(record(config.venue, 1, .{ .instrument_definition_observed = .{ .instrument = 1, .rules_version = config.config_version } })) catch return error.InvalidConfig;
        batch.append(record(config.venue, 2, .{ .l2_book_snapshot = .{ .instrument = 1, .sequence = 1, .best_bid = .{ .instrument = 1, .rules_version = config.config_version, .ticks = 100 }, .best_ask = .{ .instrument = 1, .rules_version = config.config_version, .ticks = 101 } } })) catch return error.InvalidConfig;
        batch.append(record(config.venue, 3, .{ .market_data_health_changed = .{ .instrument = 1, .health = .healthy } })) catch return error.InvalidConfig;
        batch.append(record(config.venue, 4, .{ .reference_price = .{ .instrument = 1, .kind = .mark, .price = .{ .instrument = 1, .rules_version = config.config_version, .ticks = 100 } } })) catch return error.InvalidConfig;
        batch.append(record(config.venue, 5, .{ .reference_price = .{ .instrument = 1, .kind = .index, .price = .{ .instrument = 1, .rules_version = config.config_version, .ticks = 99 } } })) catch return error.InvalidConfig;
        batch.append(record(config.venue, 6, .{ .funding_rate_published = .{ .instrument = 1, .rate_ppm = 10, .funding_time_utc_ns = 1 } })) catch return error.InvalidConfig;
        self.pending = batch;
    }
    pub fn emitDelta(self: *SimulatedMarketFeed, previous: u64, sequence: u64) !void {
        if (!self.started or self.pending != null) return error.Unavailable;
        var batch: canonical.AdapterOutputBatch = .{};
        if (!self.healthy or previous != self.sequence or sequence != previous + 1) {
            self.healthy = false;
            try batch.append(record(self.venue, sequence, .{ .market_data_health_changed = .{ .instrument = 1, .health = .gap } }));
        } else {
            self.sequence = sequence;
            try batch.append(record(self.venue, sequence, .{ .l2_book_delta = .{ .instrument = 1, .previous_sequence = previous, .sequence = sequence, .best_bid = .{ .instrument = 1, .rules_version = self.rules_version, .ticks = 100 }, .best_ask = .{ .instrument = 1, .rules_version = self.rules_version, .ticks = 101 } } }));
        }
        self.pending = batch;
    }
    fn drain(ptr: *anyopaque) market.DrainError!?canonical.AdapterOutputBatch {
        const self: *SimulatedMarketFeed = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        const batch = self.pending;
        self.pending = null;
        return batch;
    }
    fn stop(ptr: *anyopaque, _: market.DrainDeadline) market.StopError!void {
        const self: *SimulatedMarketFeed = @ptrCast(@alignCast(ptr));
        if (!self.started) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.started = false;
    }
};
fn record(venue: canonical.VenueIdentity, sequence: u64, event: canonical.CanonicalEvent) canonical.EventRecord {
    return .{ .envelope = .{ .event_type = @intFromEnum(canonical.eventType(event)), .schema_version = 1, .identity = .{ .stream = 2, .sequence = sequence }, .source_fact_identity = sequence, .scope = .instrument, .venue = venue, .instrument = 1, .source_stream = 2, .source_sequence = sequence, .times = .{ .receive_utc_ns = 1, .monotonic_ns = 1, .audit_utc_ns = 1 }, .raw_evidence = .{ .stream = 2, .sequence = sequence, .digest = @splat(0) } }, .event = event };
}
test "simulated feed is account independent and starts with a bounded healthy snapshot" {
    var feed = SimulatedMarketFeed{};
    const adapter = feed.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .subscription_set = 2, .config_version = 3, .session = 4, .output_capacity = 6 });
    const batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 6), batch.len);
    try std.testing.expectEqual(canonical.MarketDataHealth.healthy, batch.events[2].event.market_data_health_changed.health);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "book gap revokes health until a fresh feed session snapshot" {
    var feed = SimulatedMarketFeed{};
    const adapter = feed.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .subscription_set = 2, .config_version = 3, .session = 4, .output_capacity = 6 });
    _ = try adapter.tryDrain();
    try feed.emitDelta(1, 3);
    const gap = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.MarketDataHealth.gap, gap.events[0].event.market_data_health_changed.health);
    try feed.emitDelta(1, 2);
    const still_gap = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.MarketDataHealth.gap, still_gap.events[0].event.market_data_health_changed.health);
    try adapter.stop(.{ .monotonic_ns = 1 });
}
