const canonical = @import("canonical_event.zig");
const venue = @import("venue_adapter.zig");
const std = @import("std");

pub const CapabilityProfile = struct { version: u64, rules_version: u64, config_version: u64, session: canonical.AdapterSessionIdentity, supports_place: bool = true };
pub const LatchedSafetyGate = enum { open, latched };
pub const OpeningGate = enum { open, blocked };
pub const Route = struct { account: canonical.ExchangeAccountIdentity, adapter: venue.VenueAdapter, capability: CapabilityProfile, safety_gate: LatchedSafetyGate = .open };
pub const InstrumentOpeningGate = struct { instrument: canonical.InstrumentIdentity, state: OpeningGate = .open };
pub const max_routes = 4;
pub const max_adapter_batches_per_turn: u8 = 1;
pub const Gateway = struct {
    routes: [max_routes]Route = undefined,
    count: u8 = 0,
    instrument_gates: [max_routes]InstrumentOpeningGate = undefined,
    instrument_gate_count: u8 = 0,
    pub fn add(self: *Gateway, route: Route) !void {
        if (self.count == self.routes.len) return error.RouteCapacity;
        self.routes[self.count] = route;
        self.count += 1;
    }
    pub fn send(self: *Gateway, request: canonical.OrderCommand) !venue.SendResult {
        for (self.routes[0..self.count]) |*route| if (route.account == request.exchange_account) {
            if (route.safety_gate == .latched or self.instrumentGapped(request.instrument) or !route.capability.supports_place or route.capability.version != request.capability_version or route.capability.rules_version != request.rules_version or route.capability.config_version != request.config_version or route.capability.session != request.adapter_session) return error.Rejected;
            return route.adapter.trySend(.{ .order_command = request });
        };
        return error.UnknownAccount;
    }
    pub fn latchAccount(self: *Gateway, account: canonical.ExchangeAccountIdentity) void {
        for (self.routes[0..self.count]) |*route| {
            if (route.account == account) route.safety_gate = .latched;
        }
    }
    pub fn setInstrumentGap(self: *Gateway, instrument: canonical.InstrumentIdentity) void {
        self.setInstrumentGate(instrument, .blocked);
    }
    /// Adapter uncertainty is account-private.  The caller drains it through
    /// the common seam, so a Venue implementation never needs a Gateway branch.
    pub fn observeAdapterOutput(self: *Gateway, batch: canonical.AdapterOutputBatch) void {
        for (batch.slice()) |record| switch (record.event) {
            .order_dispatch_result => |result| if (result.state == .unknown) {
                if (record.envelope.exchange_account) |account| self.latchAccount(account);
            },
            .order_reconciliation_result, .account_reconciliation_result => |result| if (result.status == .unresolved) {
                if (record.envelope.exchange_account) |account| self.latchAccount(account);
            },
            else => {},
        };
    }
    /// Market feeds stay independent of account routes; only their canonical
    /// health fact controls the affected Instrument opening gate.
    pub fn observeMarketOutput(self: *Gateway, batch: canonical.AdapterOutputBatch) void {
        for (batch.slice()) |record| switch (record.event) {
            .market_data_health_changed => |health| switch (health.health) {
                .healthy => self.setInstrumentGate(health.instrument, .open),
                .awaiting_snapshot, .gap => self.setInstrumentGap(health.instrument),
            },
            else => {},
        };
    }
    fn setInstrumentGate(self: *Gateway, instrument: canonical.InstrumentIdentity, state: OpeningGate) void {
        for (self.instrument_gates[0..self.instrument_gate_count]) |*gate| if (gate.instrument == instrument) {
            gate.state = state;
            return;
        };
        if (self.instrument_gate_count < self.instrument_gates.len) {
            self.instrument_gates[self.instrument_gate_count] = .{ .instrument = instrument, .state = state };
            self.instrument_gate_count += 1;
        }
    }
    fn instrumentGapped(self: *const Gateway, instrument: canonical.InstrumentIdentity) bool {
        for (self.instrument_gates[0..self.instrument_gate_count]) |gate| if (gate.instrument == instrument and gate.state == .blocked) return true;
        return false;
    }
    pub fn drainFair(self: *Gateway, output: *[max_routes]canonical.AdapterOutputBatch) !u8 {
        var count: u8 = 0;
        for (self.routes[0..self.count]) |route| if (try route.adapter.tryDrain()) |batch| {
            self.observeAdapterOutput(batch);
            output[count] = batch;
            count += 1;
        };
        return count;
    }
};
fn command(account: canonical.ExchangeAccountIdentity, instrument: canonical.InstrumentIdentity) !canonical.OrderCommand {
    return .{ .identity = 1, .exchange_account = account, .instrument = instrument, .client_order_id = try canonical.ClientOrderId.init("x"), .capability_version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .dispatch_deadline_monotonic_ns = 1 };
}

const Fixture = struct {
    pending: ?canonical.AdapterOutputBatch = .{},
    sent: u8 = 0,
    fn adapter(self: *Fixture) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    fn start(_: *anyopaque, _: venue.VenueConfig) venue.StartError!void {}
    fn send(ptr: *anyopaque, _: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.sent += 1;
        return .accepted;
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        const batch = self.pending;
        self.pending = null;
        return batch;
    }
    fn stop(_: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {}
};
test "gateway fixes route and rechecks every command dependency" {
    var first = Fixture{};
    var second = Fixture{};
    var gateway = Gateway{};
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    try gateway.add(.{ .account = 1, .adapter = first.adapter(), .capability = profile });
    try gateway.add(.{ .account = 2, .adapter = second.adapter(), .capability = profile });
    var request = try command(1, 10);
    try std.testing.expectEqual(.accepted, try gateway.send(request));
    try std.testing.expectEqual(@as(u8, 1), first.sent);
    request.config_version = 2;
    try std.testing.expectError(error.Rejected, gateway.send(request));
    try std.testing.expectEqual(@as(u8, 1), first.sent);
    request.config_version = 1;
    request.capability_version = 2;
    try std.testing.expectError(error.Rejected, gateway.send(request));
    request.capability_version = 1;
    request.rules_version = 2;
    try std.testing.expectError(error.Rejected, gateway.send(request));
    request.rules_version = 1;
    request.adapter_session = 2;
    try std.testing.expectError(error.Rejected, gateway.send(request));
    request.adapter_session = 1;
    gateway.latchAccount(1);
    try std.testing.expectError(error.Rejected, gateway.send(request));
    request.exchange_account = 2;
    try std.testing.expectEqual(.accepted, try gateway.send(request));
    gateway.setInstrumentGap(10);
    try std.testing.expectError(error.Rejected, gateway.send(request));
    request.instrument = 11;
    try std.testing.expectEqual(.accepted, try gateway.send(request));
    gateway.routes[1].capability.supports_place = false;
    try std.testing.expectError(error.Rejected, gateway.send(request));
    try std.testing.expectEqual(@as(u8, 2), second.sent);
}
test "gateway drains each fixed route once" {
    var first = Fixture{};
    var second = Fixture{};
    var gateway = Gateway{};
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    try gateway.add(.{ .account = 1, .adapter = first.adapter(), .capability = profile });
    try gateway.add(.{ .account = 2, .adapter = second.adapter(), .capability = profile });
    var output: [max_routes]canonical.AdapterOutputBatch = undefined;
    try std.testing.expectEqual(@as(u8, 2), try gateway.drainFair(&output));
}
test "Gateway scopes uncertainty and market health to the affected route" {
    var first = Fixture{ .pending = null };
    var second = Fixture{ .pending = null };
    var gateway = Gateway{};
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    try gateway.add(.{ .account = 11, .adapter = first.adapter(), .capability = profile });
    try gateway.add(.{ .account = 22, .adapter = second.adapter(), .capability = profile });

    var unknown: canonical.AdapterOutputBatch = .{};
    try unknown.append(.{ .envelope = .{
        .event_type = @intFromEnum(canonical.EventType.order_dispatch_result),
        .schema_version = 1,
        .identity = .{ .stream = 1, .sequence = 1 },
        .source_fact_identity = 1,
        .scope = .account,
        .venue = 2,
        .exchange_account = 11,
        .source_stream = 1,
        .source_sequence = 1,
        .adapter_session = 1,
        .times = .{ .monotonic_ns = 1 },
        .raw_evidence = .{ .stream = 1, .sequence = 1, .digest = @splat(0) },
    }, .event = .{ .order_dispatch_result = .{ .command = 1, .state = .unknown } } });
    gateway.observeAdapterOutput(unknown);
    try std.testing.expectError(error.Rejected, gateway.send(try command(11, 101)));
    try std.testing.expectEqual(.accepted, try gateway.send(try command(22, 202)));

    var gap: canonical.AdapterOutputBatch = .{};
    try gap.append(.{ .envelope = .{
        .event_type = @intFromEnum(canonical.EventType.market_data_health_changed),
        .schema_version = 1,
        .identity = .{ .stream = 2, .sequence = 1 },
        .source_fact_identity = 2,
        .scope = .instrument,
        .venue = 2,
        .instrument = 202,
        .source_stream = 2,
        .source_sequence = 1,
        .adapter_session = 2,
        .times = .{ .monotonic_ns = 1 },
        .raw_evidence = .{ .stream = 2, .sequence = 1, .digest = @splat(0) },
    }, .event = .{ .market_data_health_changed = .{ .instrument = 202, .health = .gap } } });
    gateway.observeMarketOutput(gap);
    try std.testing.expectError(error.Rejected, gateway.send(try command(22, 202)));
    try std.testing.expectError(error.Rejected, gateway.send(try command(11, 101)));

    gap.events[0].event.market_data_health_changed.health = .healthy;
    gateway.observeMarketOutput(gap);
    try std.testing.expectEqual(.accepted, try gateway.send(try command(22, 202)));
}
