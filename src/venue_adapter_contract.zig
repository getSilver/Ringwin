//! Reusable black-box contract checks for any VenueAdapter implementation.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const simulated = @import("simulated_venue.zig");
const venue = @import("venue_adapter.zig");

pub fn exercise(adapter: venue.VenueAdapter, adapter_request: canonical.AdapterRequest) !void {
    return exerciseWith(adapter, .{
        .venue = 1,
        .environment = .simulation,
        .exchange_account = 2,
        .adapter_session = 3,
        .request_capacity = 1,
        .output_capacity = 1,
    }, adapter_request);
}

pub fn exerciseWith(adapter: venue.VenueAdapter, config: venue.VenueConfig, adapter_request: canonical.AdapterRequest) !void {
    try std.testing.expectError(error.NotStarted, adapter.tryDrain());
    try adapter.start(config);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(adapter_request));
    try std.testing.expectEqual(venue.SendResult.backpressure, try adapter.trySend(adapter_request));
    const batch = (try adapter.tryDrain()).?;
    try std.testing.expect(batch.len > 0 and batch.len <= canonical.max_events_per_adapter_batch);
    try adapter.stop(.{ .monotonic_ns = 1 });
    try std.testing.expectEqual(venue.SendResult.stopped, try adapter.trySend(adapter_request));
}

const FixtureVenue = struct {
    running: bool = false,
    stopped: bool = false,
    pending: ?canonical.AdapterOutputBatch = null,

    fn adapter(self: *FixtureVenue) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }

    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *FixtureVenue = @ptrCast(@alignCast(ptr));
        if (self.stopped) return error.Stopped;
        if (self.running) return error.AlreadyStarted;
        if (config.venue != 1 or config.environment != .simulation or config.exchange_account != 2 or config.adapter_session != 3 or config.request_capacity != 1 or config.output_capacity != 1)
            return error.InvalidConfig;
        self.running = true;
    }

    fn send(ptr: *anyopaque, adapter_request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *FixtureVenue = @ptrCast(@alignCast(ptr));
        if (!self.running) return if (self.stopped) .stopped else error.NotStarted;
        if (self.pending != null) return .backpressure;
        const identity = switch (adapter_request) {
            .order_command => |value| value.identity,
            .order_batch => |value| if (value.len == 0) return error.InvalidRequest else value.commands[0].identity,
            .order_reconciliation => |value| value.identity,
            .account_reconciliation => |value| value.identity,
        };
        var batch: canonical.AdapterOutputBatch = .{};
        batch.append(.{ .envelope = fixtureEnvelope(identity), .event = .{ .reconciliation_started = identity } }) catch
            return error.InvalidRequest;
        self.pending = batch;
        return .accepted;
    }

    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *FixtureVenue = @ptrCast(@alignCast(ptr));
        if (!self.running and !self.stopped) return error.NotStarted;
        const batch = self.pending;
        self.pending = null;
        return batch;
    }

    fn stop(ptr: *anyopaque, deadline: venue.DrainDeadline) venue.StopError!void {
        const self: *FixtureVenue = @ptrCast(@alignCast(ptr));
        _ = deadline;
        if (!self.running) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.running = false;
        self.stopped = true;
    }
};

fn fixtureEnvelope(identity: u128) canonical.EventEnvelope {
    return .{
        .event_type = 1,
        .schema_version = 1,
        .identity = .{ .stream = 1, .sequence = @intCast(identity) },
        .source_fact_identity = identity,
        .scope = .account,
        .venue = 1,
        .exchange_account = 2,
        .source_stream = 1,
        .source_sequence = @intCast(identity),
        .adapter_session = 3,
        .times = .{ .receive_utc_ns = 1, .monotonic_ns = 1, .audit_utc_ns = 1 },
        .raw_evidence = .{ .stream = 1, .sequence = @intCast(identity), .digest = @splat(0) },
    };
}

fn sampleRequests() ![3]canonical.AdapterRequest {
    return .{
        .{ .order_command = .{
            .identity = 7,
            .exchange_account = 2,
            .instrument = 4,
            .client_order_id = try canonical.ClientOrderId.init("fixture-7"),
            .capability_version = 1,
            .rules_version = 1,
            .config_version = 1,
            .adapter_session = 3,
            .dispatch_deadline_monotonic_ns = 9,
        } },
        .{ .order_reconciliation = .{ .identity = 8, .exchange_account = 2, .order = 7, .venue_order = try canonical.VenueOrderRef.init(1, "7") } },
        .{ .account_reconciliation = .{ .identity = 9, .exchange_account = 2, .expected_session = 3 } },
    };
}

test "contract harness is reusable across independent implementations" {
    const requests = try sampleRequests();
    for (requests) |request| {
        var first: FixtureVenue = .{};
        var second: simulated.SimulatedVenue = .{};
        try exercise(first.adapter(), request);
        try exercise(second.adapter(), request);
    }
}
