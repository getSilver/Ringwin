//! Deterministic implementation of the shared VenueAdapter contract.
//!
//! It has no transport capability and exists to exercise the same public seam
//! as real Venue implementations without giving replay a side-effect path.

const canonical = @import("canonical_event.zig");
const account_projection = @import("account_projection.zig");
const std = @import("std");
const venue = @import("venue_adapter.zig");

const State = enum { idle, running, stopped };
const Binding = struct {
    venue: canonical.VenueIdentity,
    exchange_account: canonical.ExchangeAccountIdentity,
    adapter_session: canonical.AdapterSessionIdentity,
};

pub const SimulatedVenue = struct {
    state: State = .idle,
    binding: ?Binding = null,
    pending: ?canonical.AdapterOutputBatch = null,

    pub fn adapter(self: *SimulatedVenue) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{
            .start = start,
            .try_send = send,
            .try_drain = drain,
            .stop = stop,
        } };
    }

    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.environment != .simulation or config.request_capacity == 0 or config.output_capacity == 0)
            return error.InvalidConfig;
        self.binding = .{
            .venue = config.venue,
            .exchange_account = config.exchange_account,
            .adapter_session = config.adapter_session,
        };
        self.state = .running;
    }

    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.state == .stopped) return .stopped;
        if (self.pending != null) return .backpressure;
        const binding = self.binding orelse return error.InvalidRequest;
        const account = switch (request) {
            .order_command => |value| value.exchange_account,
            .order_reconciliation => |value| value.exchange_account,
            .account_reconciliation => |value| value.exchange_account,
        };
        if (account != binding.exchange_account) return error.InvalidRequest;
        switch (request) {
            .order_command => |value| if (value.adapter_session != binding.adapter_session) return error.InvalidRequest,
            .account_reconciliation => |value| if (value.expected_session != binding.adapter_session) return error.InvalidRequest,
            .order_reconciliation => {},
        }

        const identity: u128, const event: canonical.CanonicalEvent = switch (request) {
            .order_command => |command| .{ command.identity, .{ .order_dispatch_result = .{
                .command = command.identity,
                .state = .submitted,
            } } },
            .order_reconciliation => |reconciliation| .{ reconciliation.identity, .{ .reconciliation_started = reconciliation.identity } },
            .account_reconciliation => |reconciliation| .{ reconciliation.identity, .{ .account_reconciliation_started = reconciliation.identity } },
        };
        var batch: canonical.AdapterOutputBatch = .{};
        batch.append(.{ .envelope = envelope(binding, identity), .event = event }) catch return error.InvalidRequest;
        switch (request) {
            .order_reconciliation => |reconciliation| batch.append(.{
                .envelope = envelope(binding, reconciliation.identity + 1),
                .event = .{ .order_reconciliation_result = .{ .identity = reconciliation.identity, .complete = true } },
            }) catch return error.InvalidRequest,
            .account_reconciliation => |reconciliation| {
                var snapshot: canonical.AccountBootstrapSnapshot = .{
                    .identity = reconciliation.identity,
                    .exchange_account = reconciliation.exchange_account,
                    .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
                    .source_stream = 1,
                    .source_sequence = 0,
                    .balance_count = 1,
                    .position_count = 1,
                    .margin_count = 1,
                };
                snapshot.balances[0] = .{ .asset = 1, .total = .{ .asset = 1, .atoms = 100 }, .available = .{ .asset = 1, .atoms = 100 }, .held = .{ .asset = 1, .atoms = 0 } };
                snapshot.positions[0] = .{ .instrument = 1, .side = .long, .quantity = .{ .instrument = 1, .rules_version = 1, .lots = 0 } };
                snapshot.margins[0] = .{ .amount = .{ .asset = 1, .atoms = 0 } };
                batch.append(.{ .envelope = envelope(binding, reconciliation.identity + 1), .event = .{ .account_bootstrap_snapshot = snapshot } }) catch return error.InvalidRequest;
                batch.append(.{ .envelope = envelope(binding, reconciliation.identity + 2), .event = .{ .account_observed = .{
                    .identity = reconciliation.identity + 2,
                    .exchange_account = reconciliation.exchange_account,
                    .bootstrap = snapshot.identity,
                    .source_stream = 1,
                    .source_sequence = 1,
                    .value = .{ .balance = .{ .asset = 1, .value = .{ .asset = 1, .total = .{ .asset = 1, .atoms = 100 }, .available = .{ .asset = 1, .atoms = 100 }, .held = .{ .asset = 1, .atoms = 0 } } } },
                } } }) catch return error.InvalidRequest;
                batch.append(.{ .envelope = envelope(binding, reconciliation.identity + 3), .event = .{ .account_observed = .{
                    .identity = reconciliation.identity + 3,
                    .exchange_account = reconciliation.exchange_account,
                    .bootstrap = snapshot.identity,
                    .source_stream = 1,
                    .source_sequence = 2,
                    .value = .{ .position = .{ .instrument = 1, .side = .long, .value = .{ .instrument = 1, .rules_version = 1, .lots = 0 } } },
                } } }) catch return error.InvalidRequest;
                batch.append(.{ .envelope = envelope(binding, reconciliation.identity + 4), .event = .{ .account_observed = .{
                    .identity = reconciliation.identity + 4,
                    .exchange_account = reconciliation.exchange_account,
                    .bootstrap = snapshot.identity,
                    .source_stream = 1,
                    .source_sequence = 3,
                    .value = .{ .margin = .{ .value = .{ .amount = .{ .asset = 1, .atoms = 0 } } } },
                } } }) catch return error.InvalidRequest;
                batch.append(.{ .envelope = envelope(binding, reconciliation.identity + 5), .event = .{ .account_reconciliation_result = .{ .identity = reconciliation.identity, .complete = true } } }) catch return error.InvalidRequest;
            },
            .order_command => {},
        }
        self.pending = batch;
        return .accepted;
    }

    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const batch = self.pending;
        self.pending = null;
        return batch;
    }

    fn stop(ptr: *anyopaque, deadline: venue.DrainDeadline) venue.StopError!void {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        _ = deadline;
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.state = .stopped;
    }

    fn envelope(binding: Binding, identity: u128) canonical.EventEnvelope {
        return .{
            .event_type = 1,
            .schema_version = 1,
            .identity = .{ .stream = 1, .sequence = @intCast(identity) },
            .source_fact_identity = identity,
            .scope = .account,
            .venue = binding.venue,
            .exchange_account = binding.exchange_account,
            .source_stream = 1,
            .source_sequence = @intCast(identity),
            .adapter_session = binding.adapter_session,
            .times = .{ .receive_utc_ns = 1, .monotonic_ns = 1, .audit_utc_ns = 1 },
            .raw_evidence = .{ .stream = 1, .sequence = @intCast(identity), .digest = @splat(0) },
        };
    }
};

test "simulated venue returns a canonical result for every request kind" {
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{
        .venue = 1,
        .environment = .simulation,
        .exchange_account = 2,
        .adapter_session = 4,
        .request_capacity = 1,
        .output_capacity = 1,
    });

    const requests = [_]canonical.AdapterRequest{
        .{ .order_command = .{
            .identity = 1,
            .exchange_account = 2,
            .instrument = 3,
            .client_order_id = try canonical.ClientOrderId.init("simulated-1"),
            .capability_version = 1,
            .rules_version = 1,
            .config_version = 1,
            .adapter_session = 4,
            .dispatch_deadline_monotonic_ns = 5,
        } },
        .{ .order_reconciliation = .{ .identity = 6, .exchange_account = 2, .order = 1 } },
        .{ .account_reconciliation = .{ .identity = 7, .exchange_account = 2, .expected_session = 4 } },
    };
    const expected_tags = [_]std.meta.Tag(canonical.CanonicalEvent){
        .order_dispatch_result,
        .reconciliation_started,
        .account_reconciliation_started,
    };
    for (requests, expected_tags) |request, expected_tag| {
        try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(request));
        const batch = (try adapter.tryDrain()).?;
        try std.testing.expect(batch.len >= 1);
        try std.testing.expectEqual(expected_tag, std.meta.activeTag(batch.events[0].event));
    }
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "simulated venue rejects requests outside its fixed account session" {
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{
        .venue = 1,
        .environment = .simulation,
        .exchange_account = 2,
        .adapter_session = 3,
        .request_capacity = 1,
        .output_capacity = 1,
    });
    try std.testing.expectError(error.InvalidRequest, adapter.trySend(.{ .account_reconciliation = .{
        .identity = 1,
        .exchange_account = 4,
        .expected_session = 3,
    } }));
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "account reconciliation drains replayable bootstrap facts" {
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 8 });
    _ = try adapter.trySend(.{ .account_reconciliation = .{ .identity = 9, .exchange_account = 2, .expected_session = 3 } });
    const batch = (try adapter.tryDrain()).?;
    var live = account_projection.AccountProjection{};
    var replay = account_projection.AccountProjection{};
    for (batch.slice()) |record| {
        try live.apply(record.event);
        try replay.apply(record.event);
    }
    try std.testing.expect(live.valid and replay.valid);
    try std.testing.expectEqual(live.last_sequence, replay.last_sequence);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "both reconciliation result types leave through tryDrain" {
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 8 });
    _ = try adapter.trySend(.{ .order_reconciliation = .{ .identity = 7, .exchange_account = 2, .order = 1 } });
    const order_batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.ReconciliationResult{ .identity = 7, .complete = true }, order_batch.events[1].event.order_reconciliation_result);
    _ = try adapter.trySend(.{ .account_reconciliation = .{ .identity = 8, .exchange_account = 2, .expected_session = 3 } });
    const account_batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.ReconciliationResult{ .identity = 8, .complete = true }, account_batch.events[5].event.account_reconciliation_result);
    try adapter.stop(.{ .monotonic_ns = 1 });
}
