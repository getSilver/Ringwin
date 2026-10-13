//! Offline Owner/Gateway archive recovery through the same public seams as execution.
const std = @import("std");
const canonical = @import("canonical_event.zig");
const durable = @import("durable_store.zig");
const demo = @import("demo_authority.zig");
const execution = @import("execution_gateway.zig");
const fixture = @import("trading_shard_fixture.zig");
const trading = @import("trading_shard.zig");
const venue = @import("venue_adapter.zig");
const failover = @import("failover.zig");
const history = @import("business_history.zig");
const terminal_utc: u64 = 1_767_225_602_000_000_000;

pub const CountingSimulator = struct {
    implementation: @import("simulated_venue.zig").SimulatedVenue = .{},
    sends: u64 = 0,
    pub fn adapter(self: *@This()) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        return @as(*@This(), @ptrCast(@alignCast(ptr))).implementation.adapter().start(config);
    }
    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.sends += 1;
        return self.implementation.adapter().trySend(request);
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var batch = (try self.implementation.adapter().tryDrain()) orelse return null;
        // The offline adapter owns its logical receipt clock; preserve every economic payload.
        for (batch.events[0..batch.len]) |*record| record.envelope.times = .{ .source_utc_ns = terminal_utc, .receive_utc_ns = terminal_utc, .monotonic_ns = 2 * std.time.ns_per_s, .audit_utc_ns = terminal_utc };
        return batch;
    }
    fn stop(ptr: *anyopaque, deadline: venue.DrainDeadline) venue.StopError!void {
        return @as(*@This(), @ptrCast(@alignCast(ptr))).implementation.adapter().stop(deadline);
    }
};

pub fn initializeOwner(owner: *demo.Owner) !void {
    for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .cash)) |event| _ = try owner.apply(event);
    const digest = owner.shard.canonicalStateDigest();
    _ = try owner.apply(fixture.atGroup(12, .{ .identity = 3, .payload = .{ .host_activated = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .session = .{ .fencing = 1, .shard = 0, .generation = 1 }, .activation_barrier = 0, .state_digest = digest } } }));
    _ = try owner.apply(fixture.atGroup(13, .{ .identity = 4, .payload = .{ .capability_profile_activation = .{ .exchange_account = 2, .instrument = 3, .venue = 1, .environment = .simulation, .product = .spot, .version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .max_dispatch_age_ns = 10 * std.time.ns_per_s, .supports_place = true, .supports_cancel = true, .supports_native_amend = false, .supports_venue_reduce_only = false, .supports_post_only = false, .supports_market_protection = false } } }));
    var snapshot: canonical.AccountBootstrapSnapshot = .{ .identity = 1, .exchange_account = 2, .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true }, .source_stream = 7, .source_sequence = 1, .balance_count = 2, .position_count = 0, .margin_count = 1 };
    for ([_]u64{ 1, 0x425443 }, 0..) |asset, index| {
        const amount: canonical.AssetAmount = .{ .asset = asset, .atoms = if (asset == 1) 25_000_000_000 else 0 };
        const zero: canonical.AssetAmount = .{ .asset = asset, .atoms = 0 };
        snapshot.balances[index] = .{ .asset = asset, .total = amount, .available = amount, .held = zero, .cash_balance = amount, .liability = zero, .isolated_liability = zero, .cross_liability = zero };
    }
    const zero: canonical.AssetAmount = .{ .asset = 1, .atoms = 0 };
    snapshot.margins[0] = .{ .amount = zero, .initial_margin = zero, .maintenance_margin = zero, .isolated_equity = zero };
    var account = fixture.canonicalAt(14, 1, .{ .account_bootstrap_snapshot = snapshot });
    account.venue.envelope.identity.stream = 7;
    account.venue.envelope.source_stream = 7;
    account.venue.envelope.raw_evidence.stream = 7;
    _ = try owner.apply(account);
    var book = fixture.snapshotAt(15, 2);
    book.venue.envelope.identity.stream = 7;
    book.venue.envelope.source_stream = 7;
    book.venue.envelope.raw_evidence.stream = 7;
    _ = try owner.apply(book);
    try owner.sealBootstrap();
}

pub fn recordTerminalArchiveCoverage(owner: *demo.Owner, command: trading.oms.Command) !void {
    return recordTerminalArchiveCoverageFor(owner, command, .filled, 20);
}

pub fn recordTerminalArchiveCoverageFor(owner: *demo.Owner, command: trading.oms.Command, status: canonical.ExecutionReportStatus, cumulative: i64) !void {
    const deadline = terminal_utc + 30 * std.time.ns_per_s;
    var terminal = fixture.canonicalAt(21, 3, .{ .order_reconciliation_result = .{ .identity = 1000, .complete = true, .status = .found_terminal, .order = command.order_id, .revision = command.revision, .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = cumulative }, .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 0 }, .terminal_status = status, .rules_version = 1, .evidence = .{ .scope = .{ .exchange_account = 2, .instrument = 3, .order = command.order_id, .revision = command.revision, .from_utc_ns = 0, .through_utc_ns = deadline }, .observed_at_utc_ns = deadline, .source = .{ .stream = 7, .sequence = 3, .digest = history.hash("offline complete terminal query") }, .terminal_archive = .{ .visibility_deadline_utc_ns = deadline, .order_history_complete = true, .terminal_history_complete = true, .fills_complete = true, .economics_complete = true } } } });
    terminal.venue.envelope.identity.stream = 7;
    terminal.venue.envelope.source_stream = 7;
    terminal.venue.envelope.raw_evidence.stream = 7;
    terminal.venue.envelope.raw_evidence.digest = terminal.venue.event.order_reconciliation_result.evidence.?.source.digest;
    terminal.venue.event.order_reconciliation_result.evidence.?.scope.from_utc_ns = (owner.shard.oms.orderById(command.order_id) orelse return error.MissingOrder).created_at_utc_ns;
    terminal.venue.event.order_reconciliation_result.remaining_quantity.?.lots = owner.shard.oms.orderById(command.order_id).?.quantity - cumulative;
    terminal.venue.envelope.times.source_utc_ns = deadline;
    terminal.venue.envelope.times.receive_utc_ns = deadline;
    _ = try owner.apply(terminal);
}

test "Owner archives a truly accepted Gateway command and verifies cold retries without sending" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 920 };
    const dispatch_stream: durable.StreamIdentity = .{ .domain = .control, .id = 921 };
    const owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(owner);
    try @call(.never_inline, bootstrapOwnerInto, .{ owner, memory.interface(), stream });
    try initializeOwner(owner);
    var simulator: CountingSimulator = .{};
    const adapter = simulator.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = owner.shard.activatedAssets(), .instrument_definitions = owner.shard.instrument_registry });
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 3 * std.time.ns_per_s / 2);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    const route: execution.Route = .{ .account = 2, .adapter = adapter, .venue_identity = 1, .lease_guard = &guard, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } };
    const gateway = try std.testing.allocator.create(execution.Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try gateway.add(route);
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, dispatch_stream);
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 1 };
    group.members[0] = .{ .intent_sequence = 101, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    _ = try owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .oms_intent_group = group } }));
    const command = owner.shard.oms.emitted()[0];
    const old_shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(old_shard);
    @memcpy(std.mem.asBytes(old_shard), std.mem.asBytes(&owner.shard));
    try std.testing.expectEqual(venue.SendResult.accepted, try owner.send(gateway, &guard, command.command_id, 2 * std.time.ns_per_s));
    try owner.applyAdapterBatch((try adapter.tryDrain()).?);
    try std.testing.expectEqual(@as(i64, 20), try owner.shard.economic_projection.appliedCanonicalFillQuantity(command.order_id));
    try recordTerminalArchiveCoverage(owner, command);
    var evidence_storage: [8]execution.DispatchEvidence = undefined;
    const evidence = try gateway.exportOrderDispatchEvidence(&owner.shard, command.order_id, &evidence_storage);
    try std.testing.expectEqual(@as(usize, 1), evidence.len);
    const client = evidence[0].proof.command.client_order_id;
    var encoded: [history.max_record_bytes]u8 = undefined;
    const evidence_digest = history.hash(try @import("snapshot_codec.zig").encodeBare(&encoded, evidence[0]));
    const root = try owner.archiveTerminalOrder(command.order_id, gateway);
    try std.testing.expect(owner.shard.oms.orderById(command.order_id) == null);
    try std.testing.expect(gateway.acceptedClientOrderIdFromShard(&owner.shard, command.command_id) == null);
    const request: history.LookupRequest = .{ .pending_id = 1, .key = .{ .origin = root.origin, .identity = .{ .client_order_id = client } }, .candidate_payload_digest = evidence_digest, .original_input_digest = history.hash("same original command retry"), .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
    const result = try memory.interface().queryOrderHistory(undefined, request);
    for (0..2) |_| try std.testing.expectEqual(venue.SendResult.accepted, try gateway.retryArchivedDispatch(&owner.shard, request, &result));
    try std.testing.expectEqual(@as(u64, 1), simulator.sends);
    const economic_before_retry = owner.shard.economic_projection.semanticDigest();
    const next_order_before_retry = owner.shard.oms.next_order_id;
    _ = try owner.apply(fixture.atGroup(3100, .{ .identity = 202, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expect(owner.shard.pending_history_candidate == null);
    try std.testing.expectEqual(next_order_before_retry, owner.shard.oms.next_order_id);
    try std.testing.expectEqualSlices(u8, &economic_before_retry, &owner.shard.economic_projection.semanticDigest());
    var deferred_vtable = memory.interface().vtable.*;
    deferred_vtable.query_order_history = timeoutHistoryQuery;
    owner.store.vtable = &deferred_vtable;
    try std.testing.expectError(error.HistoryLookupDeferred, owner.apply(fixture.atGroup(3101, .{ .identity = 203, .payload = .{ .oms_intent_group = group } })));
    try std.testing.expect(owner.shard.pending_history_candidate != null);
    try std.testing.expect(!owner.closed);
    try std.testing.expectEqual(next_order_before_retry, owner.shard.oms.next_order_id);
    try std.testing.expectEqualSlices(u8, &economic_before_retry, &owner.shard.economic_projection.semanticDigest());
    try owner.checkpoint();
    const recovered_owner = try std.testing.allocator.create(demo.Owner);
    defer std.testing.allocator.destroy(recovered_owner);
    try @call(.never_inline, recoverOwnerInto, .{ recovered_owner, memory.interface(), stream });
    try std.testing.expect(recovered_owner.shard.pending_history_candidate != null);
    _ = try recovered_owner.resolveColdCandidate();
    try std.testing.expect(recovered_owner.shard.pending_history_candidate == null);
    try std.testing.expectEqual(next_order_before_retry, recovered_owner.shard.oms.next_order_id);
    try std.testing.expectEqualSlices(u8, &economic_before_retry, &recovered_owner.shard.economic_projection.semanticDigest());
    try std.testing.expectEqual(root, recovered_owner.shard.business_history_root.?);
    try std.testing.expect(recovered_owner.shard.oms.orderById(command.order_id) == null);
    const recovered_gateway = try std.testing.allocator.create(execution.Gateway);
    defer std.testing.allocator.destroy(recovered_gateway);
    recovered_gateway.init();
    try recovered_gateway.add(route);
    try recovered_gateway.attachRecoveredDurableDispatch(memory.interface(), undefined, dispatch_stream);
    try std.testing.expectEqual(venue.SendResult.accepted, try recovered_gateway.retryArchivedDispatch(&recovered_owner.shard, request, &result));
    try recovered_gateway.observeAuthorityFromShard(old_shard, .{ .account = 2, .effective_trading_authority = old_shard.operational_state.effectiveTradingAuthority(), .reservation_identity = command.reservation_identity, .reservation = command.reservation, .primary_lease_expires_at_monotonic_ns = lease.expires_at_ns, .fencing_token = lease.token, .exchange_position = old_shard.currentNetExchangePosition(3).?, .authority_barrier = old_shard.authoritativeBarrier() });
    try std.testing.expectError(error.NotSent, recovered_gateway.sendFromShard(old_shard, command.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 1), simulator.sends);
    var conflicting_group = group;
    conflicting_group.members[0].quantity += 20;
    _ = try recovered_owner.apply(fixture.atGroup(3102, .{ .identity = 204, .payload = .{ .oms_intent_group = conflicting_group } }));
    try std.testing.expect(recovered_owner.shard.oms.recovery_only);
    try std.testing.expect(!recovered_owner.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expect(recovered_owner.shard.pending_history_candidate != null);
    try std.testing.expectEqual(next_order_before_retry, recovered_owner.shard.oms.next_order_id);
    try std.testing.expectEqualSlices(u8, &economic_before_retry, &recovered_owner.shard.economic_projection.semanticDigest());
}

fn timeoutHistoryQuery(_: *anyopaque, _: std.Io, _: history.LookupRequest) anyerror!history.LookupResult {
    return error.SyncTimeout;
}

/// A process-boundary fault wrapper; the persisted MemoryAdapter survives restart.
pub const ArchiveFaultMemory = struct {
    memory: durable.MemoryAdapter,
    original: @TypeOf(@as(durable.Store, undefined).vtable),
    vtable: @typeInfo(@TypeOf(@as(durable.Store, undefined).vtable)).pointer.child,
    stage: enum { none, history_publish, decision_commit, gateway_append, gateway_checkpoint } = .none,
    closed: bool = false,
    timeout_intent_sequence: ?u64 = null,
    timeout_report_identity: ?u128 = null,

    fn initialize(self: *@This(), allocator: std.mem.Allocator) void {
        self.memory = .initWithAllocator(allocator);
        self.original = self.memory.interface().vtable;
        self.vtable = self.original.*;
        self.vtable.publish_order_history = publishHistory;
        self.vtable.commit = commit;
        self.vtable.append = append;
        self.vtable.publish = publishSnapshot;
        self.vtable.gate = gate;
        self.vtable.query_order_history = queryHistory;
        self.timeout_intent_sequence = null;
        self.timeout_report_identity = null;
        self.stage = .none;
        self.closed = false;
    }
    pub fn interface(self: *@This()) durable.Store {
        return .{ .context = &self.memory, .vtable = &self.vtable };
    }
    fn from(ptr: *anyopaque) *@This() {
        const memory: *durable.MemoryAdapter = @ptrCast(@alignCast(ptr));
        return @fieldParentPtr("memory", memory);
    }
    fn fail(self: *@This()) anyerror {
        self.closed = true;
        return error.InjectedEio;
    }
    fn gate(ptr: *anyopaque) durable.GateState {
        const self = from(ptr);
        return if (self.closed) .closed else self.memory.interface().safetyGate();
    }
    fn queryHistory(ptr: *anyopaque, io: std.Io, request: history.LookupRequest) anyerror!history.LookupResult {
        const self = from(ptr);
        switch (request.key.identity) {
            .intent => |identity| if (self.timeout_intent_sequence == identity.sequence) return error.InjectedQueryTimeout,
            .report => |identity| if (self.timeout_report_identity == identity) return error.InjectedQueryTimeout,
            else => {},
        }
        return self.original.query_order_history.?(ptr, io, request);
    }
    fn publishHistory(ptr: *anyopaque, io: std.Io, batch: history.Batch) anyerror!history.Receipt {
        const self = from(ptr);
        if (self.stage == .history_publish) return self.fail();
        return self.original.publish_order_history.?(ptr, io, batch);
    }
    fn append(ptr: *anyopaque, io: std.Io, request: durable.Append) anyerror!void {
        const self = from(ptr);
        if (self.stage == .gateway_append and request.stream.domain == .control) return self.fail();
        return self.original.append(ptr, io, request);
    }
    fn commit(ptr: *anyopaque, io: std.Io, stream: durable.StreamIdentity, barrier: u64) anyerror!void {
        const self = from(ptr);
        if (self.stage == .decision_commit and stream.domain == .decision_log) return self.fail();
        return self.original.commit(ptr, io, stream, barrier);
    }
    fn publishSnapshot(ptr: *anyopaque, io: std.Io, stream: durable.StreamIdentity, barrier: u64, bytes: []const u8) anyerror!void {
        const self = from(ptr);
        if (self.stage == .gateway_checkpoint and stream.domain == .control) return self.fail();
        return self.original.publish(ptr, io, stream, barrier, bytes);
    }
};

pub const ArchiveHarness = struct {
    allocator: std.mem.Allocator,
    backend: *ArchiveFaultMemory,
    owner: *demo.Owner,
    gateway: *execution.Gateway,
    simulator: CountingSimulator = .{},
    authority: failover.FencingAuthority,
    lease: failover.PrimaryLease,
    guard: failover.GatewayLeaseGuard,
    route: execution.Route,
    command: trading.oms.Command,
    stream: durable.StreamIdentity,
    dispatch_stream: durable.StreamIdentity,

    pub fn createBase(allocator: std.mem.Allocator, stream_id: u64) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.backend = try allocator.create(ArchiveFaultMemory);
        errdefer allocator.destroy(self.backend);
        @call(.never_inline, ArchiveFaultMemory.initialize, .{ self.backend, allocator });
        errdefer self.backend.memory.deinit();
        self.owner = try allocator.create(demo.Owner);
        errdefer allocator.destroy(self.owner);
        self.gateway = try allocator.create(execution.Gateway);
        errdefer allocator.destroy(self.gateway);
        self.gateway.init();
        self.simulator = .{};
        self.stream = .{ .domain = .decision_log, .id = stream_id };
        self.dispatch_stream = .{ .domain = .control, .id = stream_id + 1 };
        try @call(.never_inline, bootstrapOwnerInto, .{ self.owner, self.backend.interface(), self.stream });
        try initializeOwner(self.owner);
        self.authority = failover.authorityForTesting();
        self.lease = try self.authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 3 * std.time.ns_per_s / 2);
        self.guard = .{ .authority = &self.authority, .lease = &self.lease };
        try self.gateway.bootstrapDurableDispatch(self.backend.interface(), undefined, self.dispatch_stream);
        return self;
    }

    pub fn bindAdapter(self: *@This(), adapter: venue.VenueAdapter) !void {
        try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = self.owner.shard.activatedAssets(), .instrument_definitions = self.owner.shard.instrument_registry });
        self.route = .{ .account = 2, .adapter = adapter, .venue_identity = 1, .lease_guard = &self.guard, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } };
        try self.gateway.add(self.route);
    }

    pub fn create(allocator: std.mem.Allocator, stream_id: u64) !*@This() {
        const self = try createBase(allocator, stream_id);
        errdefer self.destroy();
        const adapter = self.simulator.adapter();
        try self.bindAdapter(adapter);
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 1 };
        group.members[0] = .{ .intent_sequence = 101, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
        _ = try self.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .oms_intent_group = group } }));
        self.command = self.owner.shard.oms.emitted()[0];
        try std.testing.expectEqual(venue.SendResult.accepted, try self.owner.send(self.gateway, &self.guard, self.command.command_id, 2 * std.time.ns_per_s));
        try self.owner.applyAdapterBatch((try adapter.tryDrain()).?);
        try recordTerminalArchiveCoverage(self.owner, self.command);
        return self;
    }
    pub fn destroy(self: *@This()) void {
        self.backend.memory.deinit();
        self.allocator.destroy(self.backend);
        self.allocator.destroy(self.owner);
        self.allocator.destroy(self.gateway);
        self.allocator.destroy(self);
    }
};

test "Owner Gateway archive failure boundaries preserve committed evidence on recovery" {
    for ([_]@TypeOf(@as(ArchiveFaultMemory, undefined).stage){ .history_publish, .decision_commit, .gateway_checkpoint }, 0..) |stage, index| {
        const harness = try ArchiveHarness.create(std.testing.allocator, 940 + 2 * index);
        defer harness.destroy();
        const client = harness.gateway.acceptedClientOrderIdFromShard(&harness.owner.shard, harness.command.command_id).?;
        var evidence: [1]execution.DispatchEvidence = undefined;
        const exported = try harness.gateway.exportOrderDispatchEvidence(&harness.owner.shard, harness.command.order_id, &evidence);
        try std.testing.expectEqual(@as(usize, 1), exported.len);
        var payload: [history.max_record_bytes]u8 = undefined;
        const digest = history.hash(try @import("snapshot_codec.zig").encodeBare(&payload, exported[0]));
        harness.backend.stage = stage;
        try std.testing.expectError(if (stage == .decision_commit) error.DecisionLogUnavailable else error.InjectedEio, harness.owner.archiveTerminalOrder(harness.command.order_id, harness.gateway));
        try std.testing.expect(harness.owner.closed);
        try std.testing.expect(harness.gateway.acceptedClientOrderIdFromShard(&harness.owner.shard, harness.command.command_id) != null);
        if (stage == .gateway_checkpoint) {
            try std.testing.expect(harness.owner.shard.oms.orderById(harness.command.order_id) == null);
            try std.testing.expect(harness.owner.shard.business_history_root != null);
        } else {
            try std.testing.expect(harness.owner.shard.oms.orderById(harness.command.order_id) != null);
            try std.testing.expect(harness.owner.shard.business_history_root == null);
        }
        // A new process uses the same durable backend without the failed process's gate.
        const store = harness.backend.memory.interface();
        const persisted = try store.recover(undefined, harness.stream);
        std.debug.print("archive fault {s}: status={s} gate={s} last={d} committed={d} tails={d} snapshot={d}\n", .{ @tagName(stage), @tagName(persisted.status), @tagName(persisted.gate), persisted.last_sequence, persisted.committed_barrier, persisted.tail_count, persisted.snapshot_barrier });
        const recovered_owner = try std.testing.allocator.create(demo.Owner);
        defer std.testing.allocator.destroy(recovered_owner);
        try std.testing.expectError(error.DecisionLogUnavailable, demo.Owner.recoverInto(recovered_owner, harness.backend.interface(), undefined, harness.stream));
        try std.testing.expectError(error.DecisionLogUnavailable, recovered_owner.source());
        try std.testing.expectError(error.DecisionLogUnavailable, recovered_owner.apply(fixture.atGroup(30, .{ .identity = 200, .payload = .{ .timer = fixture.timer(20) } })));
        try @call(.never_inline, recoverOwnerInto, .{ recovered_owner, store, harness.stream });
        const recovered_gateway = try std.testing.allocator.create(execution.Gateway);
        defer std.testing.allocator.destroy(recovered_gateway);
        recovered_gateway.init();
        try recovered_gateway.add(harness.route);
        try recovered_gateway.attachRecoveredDurableDispatch(store, undefined, harness.dispatch_stream);
        try std.testing.expectEqual(@as(u64, 1), harness.simulator.sends);
        if (stage == .decision_commit) {
            try std.testing.expect(recovered_owner.closed);
            try std.testing.expect(recovered_owner.shard.business_history_root == null);
            const barrier = recovered_owner.shard.authoritativeBarrier();
            try std.testing.expectEqual(persisted.committed_barrier, barrier);
            try std.testing.expectError(error.DecisionLogUnavailable, recovered_owner.source());
            try std.testing.expectError(error.DecisionLogUnavailable, recovered_owner.apply(fixture.atGroup(30, .{ .identity = 200, .payload = .{ .timer = fixture.timer(20) } })));
            try std.testing.expectError(error.DecisionLogUnavailable, recovered_owner.send(recovered_gateway, &harness.guard, harness.command.command_id, 2 * std.time.ns_per_s));
            try std.testing.expectEqual(barrier, recovered_owner.shard.authoritativeBarrier());
            const retained = try store.recover(undefined, harness.stream);
            try std.testing.expectEqual(persisted.last_sequence, retained.last_sequence);
            try std.testing.expectEqual(persisted.committed_barrier, retained.committed_barrier);
            try std.testing.expect(retained.last_sequence > retained.committed_barrier);
        }
        if (stage == .gateway_checkpoint) {
            const root = recovered_owner.shard.business_history_root.?;
            try std.testing.expect(recovered_owner.shard.oms.orderById(harness.command.order_id) == null);
            const request: history.LookupRequest = .{ .pending_id = 1, .key = .{ .origin = root.origin, .identity = .{ .client_order_id = client } }, .candidate_payload_digest = digest, .original_input_digest = history.hash("retry after archive checkpoint fault"), .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
            const result = try store.queryOrderHistory(undefined, request);
            try std.testing.expectEqual(venue.SendResult.accepted, try recovered_gateway.retryArchivedDispatch(&recovered_owner.shard, request, &result));
            try recovered_owner.resumeOrderArchive(recovered_gateway);
            const completed = try store.recover(undefined, harness.dispatch_stream);
            try recovered_owner.resumeOrderArchive(recovered_gateway);
            const repeated = try store.recover(undefined, harness.dispatch_stream);
            try std.testing.expectEqual(completed.last_sequence, repeated.last_sequence);
            try std.testing.expectEqual(completed.committed_barrier, repeated.committed_barrier);
            try std.testing.expectEqual(completed.segment_index, repeated.segment_index);
        } else {
            try std.testing.expect(recovered_owner.shard.oms.orderById(harness.command.order_id) != null);
            try std.testing.expect(recovered_gateway.acceptedClientOrderIdFromShard(&recovered_owner.shard, harness.command.command_id) != null);
            try std.testing.expectError(error.NotSent, recovered_gateway.sendFromShard(&recovered_owner.shard, harness.command.command_id, 2 * std.time.ns_per_s));
        }
        try std.testing.expectEqual(@as(u64, 1), harness.simulator.sends);
    }
}

fn recoverOwnerInto(owner: *demo.Owner, store: durable.Store, stream: durable.StreamIdentity) !void {
    try demo.Owner.recoverInto(owner, store, undefined, stream);
}

test "Gateway blocks a qualified increasing risk command during a durable cold lookup" {
    const harness = try ArchiveHarness.create(std.testing.allocator, 952);
    defer harness.destroy();
    _ = try harness.owner.archiveTerminalOrder(harness.command.order_id, harness.gateway);
    var next: trading.oms.IntentGroup = .{ .first_intent_sequence = 102, .count = 1 };
    next.members[0] = .{ .intent_sequence = 102, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    _ = try harness.owner.apply(fixture.atGroup(22, .{ .identity = 102, .payload = .{ .oms_intent_group = next } }));
    const pending_command = harness.owner.shard.oms.emitted()[0];
    var duplicate: trading.oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 1 };
    duplicate.members[0] = .{ .intent_sequence = 101, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    var deferred_vtable = harness.owner.store.vtable.*;
    deferred_vtable.query_order_history = timeoutHistoryQuery;
    harness.owner.store.vtable = &deferred_vtable;
    try std.testing.expectError(error.HistoryLookupDeferred, harness.owner.apply(fixture.atGroup(23, .{ .identity = 103, .payload = .{ .oms_intent_group = duplicate } })));
    try std.testing.expect(harness.owner.shard.pending_history_candidate != null);
    try harness.gateway.observeAuthorityFromShard(&harness.owner.shard, .{ .account = 2, .effective_trading_authority = harness.owner.shard.operational_state.effectiveTradingAuthority(), .reservation_identity = pending_command.reservation_identity, .reservation = pending_command.reservation, .primary_lease_expires_at_monotonic_ns = harness.lease.expires_at_ns, .fencing_token = harness.lease.token, .exchange_position = harness.owner.shard.currentNetExchangePosition(3).?, .authority_barrier = harness.owner.shard.authoritativeBarrier() });
    try std.testing.expectError(error.NotSent, harness.gateway.sendFromShard(&harness.owner.shard, pending_command.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 1), harness.simulator.sends);
    try std.testing.expect(harness.owner.shard.oms.orderById(pending_command.order_id) != null);
    try std.testing.expect(harness.owner.shard.pending_history_candidate != null);
}

fn bootstrapOwnerInto(owner: *demo.Owner, store: durable.Store, stream: durable.StreamIdentity) !void {
    owner.* = try demo.Owner.bootstrap(store, undefined, stream);
}

/// This offline venue rests a place until cancel; every output is public canonical ingress.
pub const RestingSimulator = struct {
    const RestingOrder = struct { client: canonical.ClientOrderId, order: canonical.OrderIdentity, quantity: canonical.InstrumentQuantity };
    sends: u64 = 0,
    receive_monotonic_ns: u64 = 2 * std.time.ns_per_s,
    receive_utc_ns: u64 = terminal_utc,
    binding: ?struct { venue_identity: canonical.VenueIdentity, account: canonical.ExchangeAccountIdentity, session: canonical.AdapterSessionIdentity } = null,
    next_sequence: u64 = 1,
    pending: ?canonical.AdapterOutputBatch = null,
    resting: [5120]RestingOrder = undefined,
    resting_count: u16 = 0,
    pub fn adapter(self: *@This()) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop, .prepare_client_order_id = prepare } };
    }
    fn prepare(_: *anyopaque, namespace: [16]u8, _: canonical.ExchangeAccountIdentity, order: u64, _: canonical.ClientOrderId) anyerror!canonical.ClientOrderId {
        var bytes: [64]u8 = undefined;
        const hex = std.fmt.bytesToHex(namespace, .lower);
        return canonical.ClientOrderId.init(try std.fmt.bufPrint(&bytes, "RWN-{s}-{d}", .{ hex, order }));
    }
    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.binding != null) return error.AlreadyStarted;
        if (config.environment != .simulation) return error.InvalidConfig;
        self.binding = .{ .venue_identity = config.venue, .account = config.exchange_account, .session = config.adapter_session };
    }
    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const binding = self.binding orelse return error.NotStarted;
        if (self.pending != null) return .backpressure;
        if (request != .order_command) return error.InvalidRequest;
        const command = request.order_command;
        if (command.exchange_account != binding.account or command.adapter_session != binding.session or
            (command.operation != .place and command.operation != .cancel)) return error.InvalidRequest;
        var found: ?usize = null;
        for (self.resting[0..self.resting_count], 0..) |order, index| {
            if (std.meta.eql(order.client, command.client_order_id)) {
                found = index;
                break;
            }
        }
        if (command.operation == .place) {
            if (found != null or self.resting_count == self.resting.len) return error.InvalidRequest;
            // The fixture's wire identity retains the Gateway namespace and original order identity.
            const client = command.client_order_id.slice();
            if (!std.mem.startsWith(u8, client, "RWN-")) return error.InvalidRequest;
            const separator = std.mem.lastIndexOfScalar(u8, client, '-') orelse return error.InvalidRequest;
            const order_id = std.fmt.parseInt(u64, client[separator + 1 ..], 10) catch return error.InvalidRequest;
            self.resting[self.resting_count] = .{ .client = command.client_order_id, .order = order_id, .quantity = command.quantity orelse return error.InvalidRequest };
            found = self.resting_count;
            self.resting_count += 1;
        }
        const index = found orelse return error.InvalidRequest;
        const resting = self.resting[index];
        self.sends += 1;
        var batch: canonical.AdapterOutputBatch = .{};
        self.append(&batch, .{ .order_dispatch_result = .{ .command = command.identity, .state = .submitted } }) catch return error.InvalidRequest;
        const zero: canonical.InstrumentQuantity = .{ .instrument = command.instrument, .rules_version = command.rules_version, .lots = 0 };
        self.append(&batch, .{ .execution_report = .{ .identity = self.next_sequence, .order = resting.order, .client_order_id = command.client_order_id, .instrument = command.instrument, .exchange_account = binding.account, .revision = command.revision, .status = if (command.operation == .place) .accepted else .canceled, .original_quantity = resting.quantity, .cumulative_quantity = zero, .remaining_quantity = if (command.operation == .place) resting.quantity else zero } }) catch return error.InvalidRequest;
        self.pending = batch;
        if (command.operation == .cancel) {
            self.resting_count -= 1;
            self.resting[index] = self.resting[self.resting_count];
        }
        return .accepted;
    }
    fn append(self: *@This(), batch: *canonical.AdapterOutputBatch, payload: canonical.Payload) !void {
        const binding = self.binding.?;
        const sequence = self.next_sequence;
        self.next_sequence += 1;
        try batch.append(.{ .envelope = .{ .event_type = @intFromEnum(canonical.eventType(payload)), .schema_version = canonical.schema_version, .identity = .{ .stream = 1, .sequence = sequence }, .source_fact_identity = sequence, .scope = .account, .venue = binding.venue_identity, .exchange_account = binding.account, .source_stream = 1, .source_sequence = sequence, .adapter_session = binding.session, .times = .{ .source_utc_ns = self.receive_utc_ns, .receive_utc_ns = self.receive_utc_ns, .monotonic_ns = self.receive_monotonic_ns, .audit_utc_ns = self.receive_utc_ns }, .raw_evidence = .{ .stream = 1, .sequence = sequence, .digest = @splat(0) } }, .event = payload });
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const pending = self.pending;
        self.pending = null;
        return pending;
    }
    fn stop(_: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {}
};

test "Owner archives accepted place and cancel sharing a client ID and retries both command proofs" {
    const harness = try ArchiveHarness.createBase(std.testing.allocator, 960);
    defer harness.destroy();
    var simulator: RestingSimulator = .{};
    const adapter = simulator.adapter();
    try harness.bindAdapter(adapter);
    var place_group: trading.oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 1 };
    place_group.members[0] = .{ .intent_sequence = 101, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    _ = try harness.owner.apply(fixture.atGroup(20, .{ .identity = 101, .payload = .{ .oms_intent_group = place_group } }));
    const place = harness.owner.shard.oms.emitted()[0];
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, place.command_id, 2 * std.time.ns_per_s));
    try harness.owner.applyAdapterBatch((try adapter.tryDrain()).?);
    try std.testing.expectEqual(trading.oms.OrderState.live, harness.owner.shard.oms.orderById(place.order_id).?.state);
    var cancel_group: trading.oms.IntentGroup = .{ .first_intent_sequence = 102, .count = 1 };
    cancel_group.members[0] = .{ .intent_sequence = 102, .operation = .cancel, .instrument = 3, .target_order_id = place.order_id, .expected_revision = place.revision, .expected_cumulative_quantity = 0 };
    _ = try harness.owner.apply(fixture.atGroup(21, .{ .identity = 102, .payload = .{ .oms_intent_group = cancel_group } }));
    const cancel = harness.owner.shard.oms.emitted()[0];
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, cancel.command_id, 2 * std.time.ns_per_s));
    try harness.owner.applyAdapterBatch((try adapter.tryDrain()).?);
    try std.testing.expectEqual(trading.oms.OrderState.canceled, harness.owner.shard.oms.orderById(place.order_id).?.state);
    try std.testing.expectEqual(@as(i64, 0), try harness.owner.shard.economic_projection.appliedCanonicalFillQuantity(place.order_id));
    try recordTerminalArchiveCoverageFor(harness.owner, cancel, .canceled, 0);
    var evidence: [2]execution.DispatchEvidence = undefined;
    const exported = try harness.gateway.exportOrderDispatchEvidence(&harness.owner.shard, place.order_id, &evidence);
    try std.testing.expectEqual(@as(usize, 2), exported.len);
    try std.testing.expectEqual(exported[0].proof.command.client_order_id, exported[1].proof.command.client_order_id);
    const root = try harness.owner.archiveTerminalOrder(place.order_id, harness.gateway);
    try std.testing.expect(harness.owner.shard.oms.orderById(place.order_id) == null);
    for (exported, 0..) |dispatch, index| {
        var bytes: [history.max_record_bytes]u8 = undefined;
        const digest = history.hash(try @import("snapshot_codec.zig").encodeBare(&bytes, dispatch));
        const request: history.LookupRequest = .{ .pending_id = index + 1, .key = .{ .origin = root.origin, .identity = .{ .dispatch_command = dispatch.proof.command.command_id } }, .candidate_payload_digest = digest, .original_input_digest = history.hash("old command retry"), .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
        const result = try harness.backend.memory.interface().queryOrderHistory(undefined, request);
        for (0..2) |_| try std.testing.expectEqual(venue.SendResult.accepted, try harness.gateway.retryArchivedDispatch(&harness.owner.shard, request, &result));
    }
    try std.testing.expectEqual(@as(u64, 2), simulator.sends);
    place_group.first_intent_sequence = 103;
    place_group.members[0].intent_sequence = 103;
    _ = try harness.owner.apply(fixture.atGroup(22, .{ .identity = 103, .payload = .{ .oms_intent_group = place_group } }));
    const second_place = harness.owner.shard.oms.emitted()[0];
    try std.testing.expect(second_place.command_id != second_place.order_id);
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, second_place.command_id, 2 * std.time.ns_per_s));
    try harness.owner.applyAdapterBatch((try adapter.tryDrain()).?);
    try std.testing.expectEqual(trading.oms.OrderState.live, harness.owner.shard.oms.orderById(second_place.order_id).?.state);
    cancel_group.first_intent_sequence = 104;
    cancel_group.members[0].intent_sequence = 104;
    cancel_group.members[0].target_order_id = second_place.order_id;
    cancel_group.members[0].expected_revision = second_place.revision;
    _ = try harness.owner.apply(fixture.atGroup(23, .{ .identity = 104, .payload = .{ .oms_intent_group = cancel_group } }));
    const second_cancel = harness.owner.shard.oms.emitted()[0];
    try std.testing.expectEqual(venue.SendResult.accepted, try harness.owner.send(harness.gateway, &harness.guard, second_cancel.command_id, 2 * std.time.ns_per_s));
    try harness.owner.applyAdapterBatch((try adapter.tryDrain()).?);
    try std.testing.expectEqual(trading.oms.OrderState.canceled, harness.owner.shard.oms.orderById(second_place.order_id).?.state);
    try std.testing.expectEqual(@as(u16, 0), simulator.resting_count);
    try std.testing.expectEqual(@as(u64, 4), simulator.sends);
}
