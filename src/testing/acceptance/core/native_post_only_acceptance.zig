//! Native maker requirements at Host / Owner / Gateway public boundaries, offline only.
const std = @import("std");
const trading = @import("../../../trading/trading_shard.zig");
const canonical = trading.canonical;
const host = @import("../../../strategy/strategy_host_gateway.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const durable = @import("../../../persistence/durable_store.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const venue = @import("../../../execution/venue_adapter.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const accounts = @import("multi_account_authority_acceptance.zig");

const Adapter = struct {
    sends: usize = 0,
    command: ?canonical.OrderCommand = null,
    fn interface(self: *@This()) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    fn start(_: *anyopaque, _: venue.VenueConfig) venue.StartError!void {}
    fn stop(_: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {}
    fn drain(_: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        return null;
    }
    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.sends += 1;
        self.command = request.order_command;
        return .accepted;
    }
};

const Harness = struct {
    memory: *durable.MemoryAdapter,
    owner: *demo.Owner,
    gateway: *execution.Gateway,
    adapters: [2]Adapter = @splat(.{}),

    fn init(self: *@This()) !void {
        const allocator = std.testing.allocator;
        self.adapters = @splat(.{});
        self.memory = try allocator.create(durable.MemoryAdapter);
        errdefer allocator.destroy(self.memory);
        self.memory.* = .init();
        errdefer self.memory.deinit();
        self.owner = try allocator.create(demo.Owner);
        errdefer allocator.destroy(self.owner);
        self.gateway = try allocator.create(execution.Gateway);
        errdefer allocator.destroy(self.gateway);
        try demo.Owner.bootstrapInto(self.owner, self.memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
        try accounts.initializePythonOwner(self.owner);
        for ([_]u128{ 20, 30 }, [_]u128{ 101, 102 }) |account, instrument| {
            var view: trading.TradingShard = undefined;
            try self.owner.shard.copyAccountViewInto(&view, account);
            var profile = view.registryInstrument(instrument).?.capability.?;
            profile.version = 2;
            profile.supports_post_only = true;
            _ = try self.owner.apply(fixture.atGroup(44, .{ .identity = @intCast(2000 + instrument), .account_scope = account, .payload = .{ .capability_profile_activation = profile } }));
        }
        self.gateway.init();
        try self.gateway.bootstrapDurableDispatch(self.memory.interface(), undefined, .{ .domain = .control, .id = 92 });
        try self.routes(self.gateway);
        try self.gateway.pinDeploymentDigest(self.owner.shard.deployment.header.?.expected_digest);
    }

    fn deinit(self: *@This()) void {
        self.memory.deinit();
        std.testing.allocator.destroy(self.memory);
        std.testing.allocator.destroy(self.owner);
        std.testing.allocator.destroy(self.gateway);
    }

    fn routes(self: *@This(), gateway: *execution.Gateway) !void {
        for (&self.adapters, [_]u128{ 20, 30 }, [_]u64{ 1, 21 }) |*adapter, account, identity| try gateway.add(.{
            .account = account,
            .adapter = adapter.interface(),
            .venue_identity = identity,
            .supported_products = execution.productMask(.isolated_linear_usdt),
            .capability = .{ .version = 2, .rules_version = 1, .config_version = 1, .session = 1, .supports_post_only = true },
        });
    }

    fn orders() [2]host.OutputOrder {
        return .{
            .{ .portfolio_identity = 10, .exchange_account_identity = 20, .instrument_identity = 101, .order_type = .post_only, .time_in_force = .post_only, .quantity = 10000, .limit_price_micros = 100 },
            .{ .portfolio_identity = 10, .exchange_account_identity = 30, .instrument_identity = 102, .side = .sell, .time_in_force = .immediate_or_cancel, .quantity = 10000, .limit_price_micros = 100 },
        };
    }

    fn admit(self: *@This(), output: []const host.OutputOrder) !void {
        const barrier = self.owner.shard.authoritativeBarrier();
        const config: host.Config = .{
            .schema_registry = trading.schema_registry_identity,
            .decision_domain = 1,
            .session = .{ .fencing = 1, .shard = 1, .generation = 1 },
            .authorization = .{ .strategy_identity = 9, .config_version = 1, .activation_identity = 1, .activation_barrier = barrier },
        };
        _ = try self.owner.apply(fixture.atGroup(45, .{ .identity = 3000, .payload = .{ .host_activated = .{
            .strategy_identity = 9,
            .config_version = 1,
            .activation_identity = 1,
            .activation_barrier = barrier,
            .session = config.session,
            .state_digest = self.owner.shard.canonicalStateDigest(),
        } } }));
        var gateway = try host.Gateway.init(config, &.{host.Subscription.of(9, &.{.mark_price})});
        const cursor = self.owner.shard.authoritativeBarrier() + 1;
        try gateway.recordPublished(1, cursor, 100);
        try gateway.activate(&self.owner.shard, &self.owner.decision_journal);
        var storage: [host.max_group_frame_len]u8 = undefined;
        const frame = try host.encodeOutputGroupFrame(&storage, config, 1, cursor, 1, output);
        const accepted = gateway.ingest(frame, 101);
        try std.testing.expect(accepted == .accepted_group);
        _ = try self.owner.apply(fixture.atGroup(45, .{ .identity = 3001, .payload = .{ .external_intent_group = accepted.accepted_group } }));
        try self.observe(self.gateway);
    }

    fn observe(self: *@This(), gateway: *execution.Gateway) !void {
        for (self.owner.shard.oms.command_history[0..self.owner.shard.oms.command_history_count]) |command| {
            var view: trading.TradingShard = undefined;
            try self.owner.shard.copyAccountViewInto(&view, command.authority.exchange_account);
            try gateway.observeAuthorityFromShard(&self.owner.shard, .{
                .account = command.authority.exchange_account,
                .effective_trading_authority = view.operational_state.effectiveTradingAuthority(),
                .reservation_identity = command.reservation_identity,
                .reservation = command.reservation,
                .primary_lease_expires_at_monotonic_ns = 100 * std.time.ns_per_s,
                .fencing_token = 1,
                .exchange_position = view.currentNetExchangePosition(command.instrument).?,
                .authority_barrier = self.owner.shard.authoritativeBarrier(),
            });
        }
    }

    fn now(self: *const @This()) u64 {
        return self.owner.shard.oms.findCommand(1).?.authority.dispatch_deadline_monotonic_ns - 1;
    }
};

test "07 Host maker taker group reaches adapters and journal snapshot recovery keeps native requirement" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.admit(&Harness.orders());
    try std.testing.expectEqual(@as(u16, 2), h.owner.shard.oms.command_history_count);
    const recovered = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered);
    // Journal tail, then checkpoint, must retain the same authority and exact order requirement.
    for ([_]bool{ false, true }) |checkpoint| {
        if (checkpoint) try h.owner.checkpoint();
        try demo.Owner.recoverInto(recovered, h.memory.interface(), undefined, h.owner.stream);
        try std.testing.expectEqualSlices(u8, &h.owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        try std.testing.expectEqualDeep(h.owner.shard.oms.findCommand(1).?, recovered.shard.oms.findCommand(1).?);
        try std.testing.expectEqual(canonical.OrderType.post_only, recovered.shard.oms.findCommand(1).?.order_type);
        try std.testing.expectEqual(@as(u64, 2), recovered.shard.oms.findCommand(1).?.authority.capability.version);
    }
    try h.observe(h.gateway);
    for ([_]u64{ 1, 2 }) |id| try std.testing.expectEqual(venue.SendResult.accepted, try h.gateway.sendFromShard(&h.owner.shard, id, h.now()));
    try std.testing.expectEqual(canonical.OrderType.post_only, h.adapters[0].command.?.order_type);
    try std.testing.expectEqual(canonical.TimeInForce.post_only, h.adapters[0].command.?.time_in_force);
    try std.testing.expectEqual(canonical.TimeInForce.immediate_or_cancel, h.adapters[1].command.?.time_in_force);
    const gateway = try std.testing.allocator.create(execution.Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try h.routes(gateway);
    try gateway.attachRecoveredDurableDispatch(h.memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    try gateway.pinDeploymentDigest(h.owner.shard.deployment.header.?.expected_digest);
    try std.testing.expectEqual(@as(u16, 2), gateway.accepted_dispatch_count);
    const accepted = gateway.accepted_dispatches[0];
    try std.testing.expectEqualDeep(h.owner.shard.oms.findCommand(1).?, accepted.proof.command);
    try std.testing.expectEqual(@as(u64, 2), accepted.proof.context.capability_version);
    // Retain live authority here so recovery gates cannot hide an accidental resend.
    try h.observe(gateway);
    try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(&h.owner.shard, 1, h.now()));
    try std.testing.expectEqual(@as(usize, 1), h.adapters[0].sends);
}

test "07 unsupported native maker or GTC substitution rejects the entire Host group" {
    for (0..5) |case| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        var orders = Harness.orders();
        switch (case) {
            0, 1 => {
                const account: u128 = if (case == 0) 20 else 30;
                const instrument: u128 = if (case == 0) 101 else 102;
                var view: trading.TradingShard = undefined;
                try h.owner.shard.copyAccountViewInto(&view, account);
                var profile = view.registryInstrument(instrument).?.capability.?;
                profile.version = 3;
                profile.supports_post_only = false;
                _ = try h.owner.apply(fixture.atGroup(44, .{ .identity = 2500, .account_scope = account, .payload = .{ .capability_profile_activation = profile } }));
                orders[case].order_type = .post_only;
                orders[case].time_in_force = .post_only;
            },
            2 => orders[0].time_in_force = .good_til_canceled,
            3 => orders[0].order_type = .limit,
            4 => {
                // A rules update invalidates the old profile; absence cannot authorize native maker.
                var rules = h.owner.shard.registryInstrument(101).?.rules;
                rules.version = 2;
                _ = try h.owner.apply(fixture.atGroup(44, .{ .identity = 2500, .account_scope = 20, .payload = .{ .instrument_rules_activated = rules } }));
                var book = fixture.canonicalAt(44, 2, .{ .l2_book_snapshot = .{
                    .instrument = 101,
                    .sequence = 2,
                    .best_bid = .{ .instrument = 101, .rules_version = 2, .ticks = 99 },
                    .best_ask = .{ .instrument = 101, .rules_version = 2, .ticks = 100 },
                    .best_bid_quantity = .{ .instrument = 101, .rules_version = 2, .lots = 100000 },
                    .best_ask_quantity = .{ .instrument = 101, .rules_version = 2, .lots = 100000 },
                } });
                book.venue.envelope.scope = .instrument;
                book.venue.envelope.exchange_account = null;
                book.venue.envelope.instrument = 101;
                book.venue.envelope.venue = 1;
                book.venue.envelope.identity.stream = 1101;
                book.venue.envelope.source_stream = 1101;
                _ = try h.owner.apply(book);
                _ = try h.owner.apply(fixture.atGroup(44, .{ .identity = 2501, .account_scope = 20, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } }));
            },
            else => unreachable,
        }
        try h.admit(&orders);
        const RejectReason = @import("../../../trading/trading_shard_event.zig").RejectReason;
        try std.testing.expectEqual(if (case == 2 or case == 3) RejectReason.unsupported_order_spec else .capability_unsupported, h.owner.shard.last_reject_reason);
        try std.testing.expectEqual(@as(u16, 0), h.owner.shard.oms.command_history_count);
        try std.testing.expectEqual(@as(u8, 0), h.owner.shard.cycles.count);
        for ([_]u128{ 20, 30 }) |account| try std.testing.expectEqual(@as(i128, 0), (try h.owner.shard.oms.reservationsForAccount(1, account)).atoms);
        const restored = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(restored);
        try demo.Owner.recoverInto(restored, h.memory.interface(), undefined, h.owner.stream);
        try std.testing.expectEqualSlices(u8, &h.owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    }
}

test "07 send rechecks native capability scope version and deadline without releasing committed reservations" {
    for (0..10) |case| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.admit(&Harness.orders());
        var now = h.now();
        switch (case) {
            0 => h.gateway.routes[0].capability.supports_post_only = false,
            1 => h.gateway.routes[0].capability.version = 3,
            2 => h.gateway.routes[0].capability.session = 2,
            3 => h.gateway.routes[0].environment = .testnet,
            4 => h.gateway.routes[0].venue_identity = 99,
            5 => h.gateway.routes[0].supported_products = execution.productMask(.spot),
            6 => now = h.owner.shard.oms.findCommand(1).?.authority.dispatch_deadline_monotonic_ns + 1,
            7 => h.gateway.routes[0].account = 999,
            8, 9 => {
                var profile = h.owner.shard.registryInstrument(101).?.capability.?;
                profile.version = 3;
                profile.supports_post_only = case == 9;
                _ = try h.owner.apply(fixture.atGroup(46, .{ .identity = 4000, .account_scope = 20, .payload = .{ .capability_profile_activation = profile } }));
                h.gateway.routes[0].capability.version = 3;
            },
            else => unreachable,
        }
        const before = h.owner.shard.canonicalStateDigest();
        try std.testing.expectError(error.NotSent, h.gateway.sendFromShard(&h.owner.shard, 1, now));
        try std.testing.expectEqual(@as(usize, 0), h.adapters[0].sends);
        try std.testing.expectEqualSlices(u8, &before, &h.owner.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u16, 2), h.owner.shard.oms.command_history_count);
        try std.testing.expectEqual(@as(u8, 1), h.owner.shard.cycles.count);
        for ([_]u128{ 20, 30 }) |account| try std.testing.expect((try h.owner.shard.oms.reservationsForAccount(1, account)).atoms > 0);
        try std.testing.expect(h.gateway.acceptedClientOrderIdFromShard(&h.owner.shard, 1) == null);
        if (case >= 8) {
            const restored = try std.testing.allocator.create(demo.Owner);
            defer std.testing.allocator.destroy(restored);
            try demo.Owner.recoverInto(restored, h.memory.interface(), undefined, h.owner.stream);
            try std.testing.expectEqualSlices(u8, &before, &restored.shard.canonicalStateDigest());
            try std.testing.expectEqual(@as(u64, 2), restored.shard.oms.findCommand(1).?.authority.capability.version);
            try std.testing.expectEqual(@as(u64, 3), restored.shard.registryInstrument(101).?.capability.?.version);
            try std.testing.expectEqual(canonical.OrderType.post_only, restored.shard.oms.findCommand(1).?.order_type);
        }
    }
}

test "07 single Host native maker retains exact semantics and missing capability rejects through replay" {
    for ([_]bool{ false, true }) |supported| {
        const run = try std.testing.allocator.create(fixture.LiveRun);
        defer std.testing.allocator.destroy(run);
        const authorization: host.Authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 };
        try fixture.startScenarioInto(run, authorization, .leveraged, .{ .fencing = 1, .shard = 0, .generation = 1 });
        try fixture.applyHealthyPrelude(run);
        if (supported) _ = try trading.applyStable(&run.shard, &run.decision_journal, fixture.atGroup(15, .{ .identity = 2000, .payload = .{ .capability_profile_activation = .{
            .exchange_account = 2,
            .instrument = 3,
            .venue = 1,
            .environment = .simulation,
            .product = .isolated_linear_usdt,
            .version = 1,
            .rules_version = 1,
            .config_version = 1,
            .adapter_session = 1,
            .max_dispatch_age_ns = std.time.ns_per_s,
            .supports_place = true,
            .supports_cancel = true,
            .supports_native_amend = false,
            .supports_venue_reduce_only = false,
            .supports_post_only = true,
            .supports_market_protection = false,
        } } }));
        const config: host.Config = .{ .schema_registry = trading.schema_registry_identity, .decision_domain = 1, .session = .{ .fencing = 1, .shard = 0, .generation = 1 }, .authorization = authorization };
        var gateway = try host.Gateway.init(config, &.{host.Subscription.of(1, &.{.mark_price})});
        const cursor = run.shard.authoritativeBarrier() + 1;
        try gateway.recordPublished(1, cursor, 100);
        try gateway.activate(&run.shard, &run.decision_journal);
        var storage: [208]u8 = undefined;
        const frame = try host.encodeOutputOrderFrame(&storage, config, 1, cursor, 1, .{
            .order_type = .post_only,
            .time_in_force = .post_only,
            .quantity = fixture.happy_order_quantity,
            .limit_price_micros = fixture.order_limit_price,
        });
        const accepted = gateway.ingest(frame, 101);
        try std.testing.expect(accepted == .accepted);
        _ = try trading.applyStable(&run.shard, &run.decision_journal, fixture.atGroup(16, .{ .identity = 2001, .payload = .{ .external_order_intent = accepted.accepted } }));
        try std.testing.expectEqual(@as(u16, if (supported) 1 else 0), run.shard.oms.command_history_count);
        if (supported) {
            try std.testing.expectEqual(canonical.OrderType.post_only, run.shard.oms.findCommand(1).?.order_type);
            try std.testing.expectEqual(canonical.TimeInForce.post_only, run.shard.oms.findCommand(1).?.time_in_force);
        } else try std.testing.expectEqual(@import("../../../trading/trading_shard_event.zig").RejectReason.capability_unsupported, run.shard.last_reject_reason);
        try run.decision_journal.seal();
        _ = try fixture.assertReplayEquivalent(run);
    }
}

test "07 capability activation rejects wrong account product venue rules config and stale version" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const before = h.owner.shard.canonicalStateDigest();
    for (0..7) |case| {
        var profile = h.owner.shard.registryInstrument(101).?.capability.?;
        profile.version = 3;
        switch (case) {
            0 => profile.exchange_account = 30,
            1 => profile.product = .spot,
            2 => profile.venue = 21,
            3 => profile.rules_version = 2,
            4 => profile.config_version = 2,
            5 => profile.version = 1,
            6 => profile.environment = .testnet,
            else => unreachable,
        }
        try std.testing.expectError(if (case == 0 or case == 2 or case == 6) error.CanonicalScopeMismatch else if (case == 5) error.StaleCapabilityProfile else error.InvalidCapabilityProfile, h.owner.shard.apply(fixture.atGroup(44, .{ .identity = 2500, .account_scope = 20, .payload = .{ .capability_profile_activation = profile } })));
        try std.testing.expectEqualSlices(u8, &before, &h.owner.shard.canonicalStateDigest());
    }
}

test "07 native maker capability revocation still permits an explicit safety cancel" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.admit(&Harness.orders());
    try std.testing.expectEqual(venue.SendResult.accepted, try h.gateway.sendFromShard(&h.owner.shard, 1, h.now()));
    const order = h.owner.shard.oms.orderById(1).?;
    var report = fixture.canonicalAt(46, 2, .{ .execution_report = .{
        .identity = 1,
        .order = 1,
        .client_order_id = order.client_order_id,
        .instrument = 101,
        .exchange_account = 20,
        .revision = 1,
        .status = .accepted,
        .cumulative_quantity = .{ .instrument = 101, .rules_version = 1, .lots = 0 },
        .remaining_quantity = .{ .instrument = 101, .rules_version = 1, .lots = 10000 },
    } });
    report.venue.envelope.exchange_account = 20;
    report.venue.envelope.venue = 1;
    _ = try h.owner.apply(report);
    var profile = h.owner.shard.registryInstrument(101).?.capability.?;
    profile.version = 3;
    profile.supports_post_only = false;
    _ = try h.owner.apply(fixture.atGroup(47, .{ .identity = 5000, .account_scope = 20, .payload = .{ .capability_profile_activation = profile } }));
    var cancellation: trading.oms.IntentGroup = .{ .first_intent_sequence = 3, .count = 1 };
    cancellation.members[0] = .{ .intent_sequence = 3, .strategy_instance = 9, .exchange_account = 20, .operation = .cancel, .instrument = 101, .target_order_id = 1, .expected_revision = 1 };
    _ = try h.owner.apply(fixture.atGroup(48, .{ .identity = 5001, .payload = .{ .oms_intent_group = cancellation } }));
    const command = h.owner.shard.oms.findCommand(3).?;
    try std.testing.expectEqual(trading.oms.Operation.cancel, command.operation);
    try std.testing.expectEqual(canonical.OrderType.post_only, command.order_type);
    h.gateway.routes[0].capability.version = 3;
    h.gateway.routes[0].capability.supports_post_only = false;
    try h.observe(h.gateway);
    try std.testing.expectEqual(venue.SendResult.accepted, try h.gateway.sendFromShard(&h.owner.shard, 3, command.authority.dispatch_deadline_monotonic_ns - 1));
    try std.testing.expectEqual(@as(usize, 2), h.adapters[0].sends);
    try std.testing.expectEqual(canonical.OrderOperation.cancel, h.adapters[0].command.?.operation);
    try std.testing.expect((try h.owner.shard.oms.reservationsForAccount(1, 20)).atoms > 0);
}

var fault_remaining: usize = 0;
fn failAppend(context: *anyopaque, io: std.Io, request: durable.Append) anyerror!void {
    if (fault_remaining == 1) return error.InjectedEio;
    fault_remaining -= 1;
    const memory: *durable.MemoryAdapter = @ptrCast(@alignCast(context));
    try memory.interface().append(io, request);
}
fn failCommit(context: *anyopaque, io: std.Io, stream: durable.StreamIdentity, barrier: u64) anyerror!void {
    if (fault_remaining == 1) return error.InjectedEio;
    fault_remaining -= 1;
    const memory: *durable.MemoryAdapter = @ptrCast(@alignCast(context));
    try memory.interface().commit(io, stream, barrier);
}

test "07 native maker dispatch persistence faults retain exact proof and never replay as GTC" {
    for ([_]bool{ false, true }) |at_commit| for (1..3) |boundary| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.admit(&Harness.orders());
        const before = h.owner.shard.canonicalStateDigest();
        const store = h.memory.interface();
        var failing = store.vtable.*;
        if (at_commit) failing.commit = failCommit else failing.append = failAppend;
        h.gateway.durable_dispatch.?.store = .{ .context = store.context, .vtable = &failing };
        fault_remaining = boundary;
        try std.testing.expectError(error.NotSent, h.gateway.sendFromShard(&h.owner.shard, 1, h.now()));
        h.gateway.durable_dispatch.?.store = store;
        const sends: usize = if (boundary == 1) 0 else 1;
        try std.testing.expectEqual(sends, h.adapters[0].sends);
        const gateway = try std.testing.allocator.create(execution.Gateway);
        defer std.testing.allocator.destroy(gateway);
        gateway.init();
        try h.routes(gateway);
        if (at_commit) {
            try std.testing.expectError(error.DurableDispatchUnavailable, gateway.attachRecoveredDurableDispatch(store, undefined, .{ .domain = .control, .id = 92 }));
            try std.testing.expectError(error.NotSent, gateway.sendFromShard(&h.owner.shard, 1, h.now()));
        } else {
            try gateway.attachRecoveredDurableDispatch(store, undefined, .{ .domain = .control, .id = 92 });
            try gateway.pinDeploymentDigest(h.owner.shard.deployment.header.?.expected_digest);
            try h.observe(gateway);
            if (boundary == 2) {
                try std.testing.expectEqual(@as(u16, 1), gateway.uncertain_dispatch_count);
                const proof = gateway.uncertain_dispatches[0].recovered_proof.?;
                try std.testing.expectEqualDeep(h.owner.shard.oms.findCommand(1).?, proof.command);
                try std.testing.expectEqual(canonical.OrderType.post_only, proof.command.order_type);
                try std.testing.expectEqual(@as(u64, 2), proof.context.capability_version);
                try std.testing.expectError(error.NotSent, gateway.sendFromShard(&h.owner.shard, 1, h.now()));
            }
        }
        try std.testing.expectEqual(sends, h.adapters[0].sends);
        try std.testing.expectEqualSlices(u8, &before, &h.owner.shard.canonicalStateDigest());
    };
}
