//! Public-market seam, intentionally independent of ExchangeAccount lifecycle.

const canonical = @import("canonical_event.zig");
const std = @import("std");

pub const Environment = enum { simulation, demo };
pub const SubscriptionSetIdentity = u128;
pub const MarketFeedSessionIdentity = u128;
pub const Config = struct {
    venue: canonical.VenueIdentity,
    environment: Environment,
    subscription_set: SubscriptionSetIdentity,
    config_version: u64,
    session: MarketFeedSessionIdentity,
    output_capacity: u16,
};
pub const DrainDeadline = struct { monotonic_ns: u64 };
pub const StartError = error{ AlreadyStarted, Stopped, InvalidConfig };
pub const DrainError = error{NotStarted};
pub const StopError = error{ NotStarted, OutputPending };
pub const MarketEventBatch = canonical.AdapterOutputBatch;

pub const MarketFeedAdapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (*anyopaque, Config) StartError!void,
        try_drain: *const fn (*anyopaque) DrainError!?MarketEventBatch,
        stop: *const fn (*anyopaque, DrainDeadline) StopError!void,
    };

    pub fn start(self: MarketFeedAdapter, config: Config) StartError!void {
        return self.vtable.start(self.ptr, config);
    }
    pub fn tryDrain(self: MarketFeedAdapter) DrainError!?MarketEventBatch {
        return self.vtable.try_drain(self.ptr);
    }
    pub fn stop(self: MarketFeedAdapter, deadline: DrainDeadline) StopError!void {
        return self.vtable.stop(self.ptr, deadline);
    }
};

const FixtureFeed = struct {
    state: enum { idle, running, stopped } = .idle,
    pending: ?MarketEventBatch = null,

    fn adapter(self: *FixtureFeed) MarketFeedAdapter {
        return .{ .ptr = self, .vtable = &.{
            .start = start,
            .try_drain = drain,
            .stop = stop,
        } };
    }

    fn start(ptr: *anyopaque, config: Config) StartError!void {
        const self: *FixtureFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.output_capacity == 0) return error.InvalidConfig;
        self.state = .running;
    }

    fn drain(ptr: *anyopaque) DrainError!?MarketEventBatch {
        const self: *FixtureFeed = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const batch = self.pending;
        self.pending = null;
        return batch;
    }

    fn stop(ptr: *anyopaque, deadline: DrainDeadline) StopError!void {
        const self: *FixtureFeed = @ptrCast(@alignCast(ptr));
        _ = deadline;
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.state = .stopped;
    }
};

test "market feed contract drains without blocking and stops at a boundary" {
    var fixture = FixtureFeed{};
    const adapter = fixture.adapter();
    try std.testing.expectError(error.NotStarted, adapter.tryDrain());
    try adapter.start(.{
        .venue = 1,
        .environment = .simulation,
        .subscription_set = 2,
        .config_version = 3,
        .session = 4,
        .output_capacity = 1,
    });
    try std.testing.expect((try adapter.tryDrain()) == null);
    fixture.pending = .{};
    try std.testing.expectError(error.OutputPending, adapter.stop(.{ .monotonic_ns = 1 }));
    _ = try adapter.tryDrain();
    try adapter.stop(.{ .monotonic_ns = 1 });
}
