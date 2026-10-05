//! Reusable black-box contract checks for any VenueAdapter implementation.

const std = @import("std");
const canonical = @import("canonical_event.zig");
const simulated = @import("simulated_venue.zig");
const venue = @import("venue_adapter.zig");

pub fn activateTestAssets(owner: *@import("demo_authority.zig").Owner) !void {
    for (@import("asset_registry.zig").testDefinitions(6, 8)) |definition|
        _ = try owner.apply(.{ .core = .{ .identity = definition.asset, .payload = .{ .asset_definition_activated = definition } } });
}

pub fn activatedTestAssets() !@import("asset_registry.zig").Registry {
    return activatedTestAssetsWithScales(6, 8);
}

pub fn activatedTestAssetsWithScales(usdt_scale: u8, btc_scale: u8) !@import("asset_registry.zig").Registry {
    var shard: @import("trading_shard.zig").TradingShard = .{};
    for (@import("asset_registry.zig").testDefinitions(usdt_scale, btc_scale)) |definition|
        _ = try shard.apply(.{ .core = .{ .identity = definition.asset, .payload = .{ .asset_definition_activated = definition } } });
    return shard.activatedAssets();
}

/// The same Owner/Core/store contract consumes a fault from any real adapter.
pub fn exerciseEconomicFaultRecovery(batch: canonical.AdapterOutputBatch) !void {
    const durable = @import("durable_store.zig");
    const demo = @import("demo_authority.zig");
    const trading = @import("trading_shard.zig");
    const allocator = std.heap.page_allocator;
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    owner.* = try demo.Owner.bootstrap(memory.interface(), undefined, stream);
    try activateTestAssets(owner);
    _ = try owner.apply(.{ .core = .{ .identity = 1, .payload = .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = 3, .quantity_denominator = 10_000, .reservation_model = .leveraged, .product = .isolated_linear_usdt, .venue = batch.events[0].envelope.venue } } } });
    _ = try owner.apply(.{ .core = .{ .identity = 2, .payload = .{ .margin_rules_activated = .{ .version = 1 } } } });
    _ = try owner.apply(.{ .core = .{ .identity = 3, .payload = .{ .account_configuration = .{ .exchange_account_identity = batch.events[0].envelope.exchange_account orelse return error.MissingAccount } } } });
    const economics_before = owner.shard.economicSummary();
    try std.testing.expect(!owner.shard.oms.recovery_only);
    try owner.applyAdapterBatch(batch);
    const once = owner.shard.canonicalStateDigest();
    try owner.applyAdapterBatch(batch);
    try std.testing.expectEqualSlices(u8, &once, &owner.shard.canonicalStateDigest());
    try owner.sealBootstrap();
    try std.testing.expectEqualDeep(economics_before, owner.shard.economicSummary());
    try std.testing.expectEqual(@as(u64, 1), owner.shard.economic_fault_count);
    try std.testing.expect(owner.shard.oms.recovery_only);
    const recovered = try allocator.create(demo.Owner);
    defer allocator.destroy(recovered);
    recovered.* = try demo.Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
    var bytes: [durable.max_snapshot_bytes]u8 = undefined;
    const restored = try trading.TradingShard.restoreSnapshot(try owner.committedSnapshot(&bytes));
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
}

pub fn exercise(adapter: venue.VenueAdapter, adapter_request: canonical.AdapterRequest) !void {
    return exerciseWith(adapter, .{
        .venue = 1,
        .environment = .simulation,
        .exchange_account = 2,
        .adapter_session = 3,
        .request_capacity = 1,
        .output_capacity = 1,
        .asset_definitions = try activatedTestAssets(),
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

pub const FillRecoveryFixture = struct {
    venue: canonical.VenueIdentity,
    exchange_account: canonical.ExchangeAccountIdentity,
    adapter_session: canonical.AdapterSessionIdentity,
};

/// Checks only canonical records emitted at the public adapter seam.  The
/// TradingShard owns duplicate/conflict application; this contract proves that
/// every adapter supplies it with a scoped report/Fill trajectory.
pub fn exerciseFillRecovery(records: []const canonical.EventRecord, fixture: FillRecoveryFixture) !void {
    var applied_quantity: i128 = 0;
    var original_quantity: ?i128 = null;
    var reports: usize = 0;
    var fills: usize = 0;
    for (records) |record| {
        try std.testing.expectEqual(@intFromEnum(canonical.eventType(record.event)), record.envelope.event_type);
        try std.testing.expectEqual(fixture.venue, record.envelope.venue);
        try std.testing.expectEqual(fixture.exchange_account, record.envelope.exchange_account);
        try std.testing.expectEqual(fixture.adapter_session, record.envelope.adapter_session);
        switch (record.event) {
            .execution_report => |report| {
                reports += 1;
                try std.testing.expectEqual(fixture.exchange_account, report.exchange_account);
                try std.testing.expect(report.cumulative_quantity.lots >= 0);
                try std.testing.expect(report.remaining_quantity.lots >= 0);
                if (report.original_quantity) |quantity| {
                    try std.testing.expect(quantity.lots >= report.cumulative_quantity.lots);
                    original_quantity = quantity.lots;
                }
            },
            .fill => |fill| {
                fills += 1;
                try std.testing.expectEqual(fixture.exchange_account, fill.exchange_account);
                try std.testing.expect(fill.quantity.lots > 0 and fill.price.ticks > 0);
                if (fill.fee) |fee| try std.testing.expect(fee.atoms >= 0);
                if (fill.rebate) |rebate| try std.testing.expect(rebate.atoms >= 0);
                applied_quantity = try std.math.add(i128, applied_quantity, fill.quantity.lots);
            },
            else => {},
        }
    }
    try std.testing.expect(reports != 0 and fills != 0);
    try std.testing.expectEqual(original_quantity orelse return error.MissingOriginalQuantity, applied_quantity);
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
        .schema_version = canonical.schema_version,
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
