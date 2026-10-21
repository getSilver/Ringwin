//! Shared small Windows/Linux real file/process acceptance (legacy module name). Offline synthetic Venue only.
const std = @import("std");
const builtin = @import("builtin");
const durable = @import("../../../persistence/durable_store.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const trading = @import("../../../trading/trading_shard.zig");
const canonical = @import("../../../model/canonical_event.zig");
const execution = @import("../../../execution/execution_gateway.zig");
const venue = @import("../../../execution/venue_adapter.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const acceptance = @import("../history/order_gateway_archive_acceptance.zig");
const failover = @import("../../../runtime/failover.zig");
const history = @import("../../../persistence/business_history.zig");
const raw = @import("../../../persistence/raw_ingress.zig");
const codec = @import("../../../persistence/snapshot_codec.zig");
const coordination = @import("../../../portfolio/account_coordinator.zig");
const seed: u64 = 0x20261008;
fn require(ok: bool) !void {
    if (!ok) return error.WindowsCapacityInvariant;
}

fn initializeOwner(owner: *demo.Owner, shard: usize) !void {
    for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .cash)) |original| {
        var input = original;
        if (input.core.payload == .virtual_portfolio_activated) input.core.payload.virtual_portfolio_activated.portfolio_identity = 11 + shard;
        _ = try owner.apply(input);
    }
    _ = try owner.apply(fixture.atGroup(12, .{ .identity = 3, .payload = .{ .host_activated = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .session = .{ .fencing = 1, .shard = @intCast(shard), .generation = 1 }, .activation_barrier = 0, .state_digest = owner.shard.canonicalStateDigest() } } }));
    _ = try owner.apply(fixture.atGroup(13, .{ .identity = 4, .payload = .{ .capability_profile_activation = .{ .exchange_account = 2, .instrument = 3, .venue = 1, .environment = .simulation, .product = .spot, .version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .max_dispatch_age_ns = 10 * std.time.ns_per_s, .supports_place = true, .supports_cancel = true, .supports_native_amend = false, .supports_venue_reduce_only = false, .supports_post_only = false, .supports_market_protection = false } } }));
    try acceptance.bootstrapArchiveAccount(owner, &.{});
    var book = fixture.snapshotAt(15, 2);
    book.venue.envelope.identity.stream = 7;
    book.venue.envelope.source_stream = 7;
    book.venue.envelope.raw_evidence.stream = 7;
    _ = try owner.apply(book);
    try owner.sealBootstrap();
}

const OfflineVenue = struct {
    resting: acceptance.RestingSimulator = .{},
    lose_next_response: bool = false,
    fn adapter(self: *@This()) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop, .prepare_client_order_id = prepare } };
    }
    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.resting.adapter().start(config);
    }
    fn prepare(ptr: *anyopaque, namespace: [16]u8, account: u128, order: u64, candidate: canonical.ClientOrderId) anyerror!canonical.ClientOrderId {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.resting.adapter().prepareClientOrderId(namespace, account, order, candidate);
    }
    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const result = try self.resting.adapter().trySend(request);
        if (self.lose_next_response) {
            self.lose_next_response = false;
            // Explicit synthetic transport response loss after the external
            // send. Gateway retains its real durable attempt as Unknown.
            self.resting.pending = null;
            return error.InvalidRequest;
        }
        return result;
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.resting.adapter().tryDrain();
    }
    fn stop(_: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {}
};

const Cycle = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: *durable.LinuxFileAdapter,
    decision_stream: durable.StreamIdentity,
    dispatch_stream: durable.StreamIdentity,
    ingress_stream: durable.StreamIdentity,
    owner: *demo.Owner,
    gateway: *execution.Gateway,
    scratch: []u8,
    simulator: OfflineVenue = .{},
    authority: failover.FencingAuthority,
    lease: failover.PrimaryLease,
    guard: failover.GatewayLeaseGuard,
    path: []const u8,
    round: u64 = 0,
    recovery_ns: i128 = 0,
    recovery_send_count: u64 = 0,

    fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, virgin: bool, shard: usize) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.io = io;
        self.path = path;
        self.decision_stream = .{ .domain = .decision_log, .id = 100 + shard * 10 };
        self.dispatch_stream = .{ .domain = .control, .id = 101 + shard * 10 };
        self.ingress_stream = .{ .domain = .raw_ingress, .id = 102 + shard * 10 };
        self.simulator = .{};
        self.round = 0;
        self.recovery_ns = 0;
        self.recovery_send_count = 0;
        self.file = try allocator.create(durable.LinuxFileAdapter);
        errdefer allocator.destroy(self.file);
        @memset(std.mem.asBytes(self.file), 0);
        if (!virgin) {
            var existing = try std.Io.Dir.openDirAbsolute(io, path, .{});
            existing.close(io);
        }
        if (builtin.os.tag == .linux) try self.file.initLinux(io, path) else try self.file.initWindowsVerification(io, path);
        errdefer self.file.close(io);
        self.owner = try allocator.create(demo.Owner);
        errdefer allocator.destroy(self.owner);
        self.gateway = try allocator.create(execution.Gateway);
        errdefer allocator.destroy(self.gateway);
        self.gateway.init();
        self.scratch = try allocator.alloc(u8, durable.max_snapshot_bytes);
        errdefer allocator.free(self.scratch);
        self.gateway.dispatch_snapshot_buffer = self.scratch;
        const store = self.file.interface();
        if (virgin) {
            var directory = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
            defer directory.close(io);
            var entries = directory.iterate();
            if (try entries.next(io) != null) return error.SeedDirectoryNotEmpty;
            try demo.Owner.bootstrapInto(self.owner, store, io, self.decision_stream);
            try initializeOwner(self.owner, shard);
        } else {
            const started = std.Io.Clock.awake.now(io).nanoseconds;
            try demo.Owner.recoverInto(self.owner, store, io, self.decision_stream);
            self.recovery_ns = std.Io.Clock.awake.now(io).nanoseconds - started;
        }
        // Offline simulation authority only: the report explicitly records
        // synthetic_fencing=true and never claims external NodeFence evidence.
        // The production test-only factory and its compile guard stay intact.
        self.authority = .{ .durable = true };
        self.lease = try self.authority.acquire(.{ .exchange_account = 2, .decision_domain = shard + 1 }, 1, 3 * std.time.ns_per_s / 2);
        self.guard = .{ .authority = &self.authority, .lease = &self.lease };
        const adapter = self.simulator.adapter();
        try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = self.owner.shard.activatedAssets(), .instrument_definitions = self.owner.shard.instrument_registry });
        try self.gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .lease_guard = &self.guard, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
        if (virgin) {
            try self.gateway.bootstrapDurableDispatch(store, io, self.dispatch_stream);
        } else {
            try self.gateway.attachRecoveredDurableDispatch(store, io, self.dispatch_stream);
            for (self.owner.shard.canonical_ingress_cursors[0..self.owner.shard.canonical_ingress_cursor_count]) |cursor| {
                if (cursor.identity.stream == 1) self.simulator.resting.next_sequence = cursor.identity.sequence + 1;
            }
            // Reconstruct only the synthetic remote resting book. It carries no
            // authority; Core/Gateway come exclusively from the real files.
            for (self.owner.shard.oms.orders[0..self.owner.shard.oms.order_count]) |order| {
                if (order.state == .canceled or order.state == .filled or order.state == .rejected or order.state == .unknown) continue;
                self.simulator.resting.resting[self.simulator.resting.resting_count] = .{ .client = order.client_order_id, .order = order.id, .quantity = .{ .instrument = order.instrument, .rules_version = 1, .lots = order.quantity } };
                self.simulator.resting.resting_count += 1;
            }
            const before = self.owner.shard.economic_projection.semanticDigest();
            try self.owner.bindRecoveryIngress(store, self.ingress_stream);
            const Replay = struct {
                fn consume(ptr: *anyopaque, _: u64, _: @import("../../../adapters/okx/okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
                    const target: *demo.Owner = @ptrCast(@alignCast(ptr));
                    var batch: canonical.AdapterOutputBatch = .{};
                    try batch.append(try codec.decodeBare(bytes, canonical.EventRecord));
                    try target.applyAdapterBatch(batch);
                }
            };
            try self.owner.replayCommittedIngress(self.ingress_stream, .{ .ptr = self.owner, .consume_fn = Replay.consume });
            try require(!self.owner.shard.recovery_admission_pending);
            try require(std.mem.eql(u8, &before, &self.owner.shard.economic_projection.semanticDigest()));
            try require(self.simulator.resting.sends == 0);
        }
        return self;
    }
    fn close(self: *@This()) void {
        self.file.close(self.io);
        self.allocator.destroy(self.file);
        self.allocator.destroy(self.owner);
        self.allocator.destroy(self.gateway);
        self.allocator.free(self.scratch);
        self.allocator.destroy(self);
    }
    fn sourceSequence(self: *@This(), stream: u128) u64 {
        for (self.owner.shard.canonical_ingress_cursors[0..self.owner.shard.canonical_ingress_cursor_count]) |cursor| if (cursor.identity.stream == stream) return cursor.identity.sequence + 1;
        return 1;
    }
    fn checkpoint(self: *@This()) !void {
        try self.owner.checkpointWithScratch(self.scratch);
        try self.gateway.checkpointDurableDispatchWithBuffer(self.scratch);
    }
    fn submit(self: *@This(), intent: trading.oms.Intent, lose_response: bool) !trading.oms.Command {
        const identity = 100 + self.owner.shard.oms.next_command_id;
        const sequence = self.sourceSequence(7);
        var book = fixture.snapshotAt(identity, sequence);
        book.venue.envelope.identity.stream = 7;
        book.venue.envelope.source_stream = 7;
        book.venue.envelope.raw_evidence.stream = 7;
        _ = try self.owner.apply(book);
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = identity, .count = 1 };
        group.members[0] = intent;
        group.members[0].intent_sequence = identity;
        const input = fixture.atGroup(identity, .{ .identity = identity, .payload = .{ .oms_intent_group = group } });
        const when = input.core.monotonic_time + std.time.ns_per_ms;
        try self.authority.renew(&self.lease, when);
        self.simulator.resting.receive_monotonic_ns = when;
        self.simulator.resting.receive_utc_ns = input.core.receive_time + std.time.ns_per_ms;
        _ = try self.owner.apply(input);
        try require(self.owner.shard.oms.emitted().len == 1);
        const command = self.owner.shard.oms.emitted()[0];
        self.simulator.lose_next_response = lose_response;
        if (lose_response) {
            if (self.owner.send(self.gateway, &self.guard, command.command_id, when)) |_| return error.UnknownSendUnexpectedlyAccepted else |err| if (err != error.NotSent) return err;
            var unknown = fixture.canonicalAt(identity, 1, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .unknown } });
            unknown.venue.envelope.identity.stream = 66;
            unknown.venue.envelope.source_stream = 66;
            unknown.venue.envelope.raw_evidence.stream = 66;
            _ = try self.owner.apply(unknown);
            try require(self.gateway.uncertain_dispatch_count == 1);
        } else {
            try require(try self.owner.send(self.gateway, &self.guard, command.command_id, when) == .accepted);
            try self.owner.applyAdapterBatch((try self.simulator.adapter().tryDrain()).?);
        }
        return command;
    }
    fn place(self: *@This()) !trading.oms.Command {
        return self.submit(.{ .intent_sequence = 0, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) }, false);
    }
    fn seedState(self: *@This(), shard: usize) !void {
        const pending_quote = if (shard == 3) try self.mixedEconomics() else 0;
        const order = try self.place();
        const fill_sequence = self.sourceSequence(55);
        const report_sequence = self.sourceSequence(33);
        var fill = fixture.canonicalAt(100 + self.owner.shard.oms.next_command_id, fill_sequence, .{ .fill = .{ .identity = 7001, .order = order.order_id, .client_order_id = self.gateway.acceptedClientOrderIdFromShard(&self.owner.shard, order.command_id).?, .venue_order = try canonical.VenueOrderRef.init(1, "windows-capacity-order"), .venue_trade = try canonical.VenueTradeRef.init(1, "windows-capacity-trade"), .instrument = 3, .exchange_account = 2, .side = .buy, .quantity = .{ .instrument = 3, .rules_version = 1, .lots = 2 }, .price = fixture.omsPrice(3, 50_000_000), .fee = .{ .asset = 1, .atoms = 1 }, .liquidity = .taker } });
        fill.venue.envelope.identity.stream = 55;
        fill.venue.envelope.source_stream = 55;
        fill.venue.envelope.raw_evidence.stream = 55;
        var raw_sink = try raw.DurableSink.init(self.file.interface(), self.io, self.ingress_stream);
        var bytes: [32768]u8 = undefined;
        const encoded = try codec.encodeBare(&bytes, fill.venue);
        _ = try raw_sink.interface().append(.{ .source_session = 1, .byte_len = @intCast(encoded.len), .sha256 = history.hash(encoded), .receive_time_utc_ns = fill.venue.envelope.times.receive_utc_ns.?, .monotonic_time_ns = fill.venue.envelope.times.monotonic_ns.?, .wall_time_utc_ns = fill.venue.envelope.times.audit_utc_ns.? }, encoded);
        _ = try self.owner.apply(fill);
        var execution_report = fixture.canonicalAt(100 + self.owner.shard.oms.next_command_id, report_sequence, .{ .execution_report = .{ .identity = 8001, .order = order.order_id, .client_order_id = self.gateway.acceptedClientOrderIdFromShard(&self.owner.shard, order.command_id).?, .instrument = 3, .exchange_account = 2, .revision = order.revision, .status = .partially_filled, .original_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 20 }, .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 2 }, .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 18 } } });
        execution_report.venue.envelope.identity.stream = 33;
        execution_report.venue.envelope.source_stream = 33;
        execution_report.venue.envelope.raw_evidence.stream = 33;
        _ = try self.owner.apply(execution_report);
        if (shard == 3) {
            _ = try self.submit(.{ .intent_sequence = 0, .operation = .place, .instrument = 3, .quantity = 2, .limit_price = fixture.omsPrice(3, 50_000_000) }, true);
            _ = try self.unsent(.{ .intent_sequence = 0, .operation = .cancel, .instrument = 3, .target_order_id = pending_quote, .expected_revision = 1, .expected_cumulative_quantity = 0 });
        }
        try self.checkpoint();
    }

    fn unsent(self: *@This(), intent: trading.oms.Intent) !trading.oms.Command {
        const identity = 100 + self.owner.shard.oms.next_command_id;
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = identity, .count = 1 };
        group.members[0] = intent;
        group.members[0].intent_sequence = identity;
        _ = try self.owner.apply(fixture.atGroup(identity, .{ .identity = identity, .payload = .{ .oms_intent_group = group } }));
        try require(self.owner.shard.oms.emitted().len == 1);
        return self.owner.shard.oms.emitted()[0];
    }
    fn fillOrder(self: *@This(), command: trading.oms.Command, lots: i64) !void {
        const identity = 9000 + command.order_id;
        var order_buffer: [40]u8 = undefined;
        var trade_buffer: [40]u8 = undefined;
        var fill = fixture.canonicalAt(100 + self.owner.shard.oms.next_command_id, self.sourceSequence(55), .{ .fill = .{
            .identity = identity,
            .order = command.order_id,
            .client_order_id = self.gateway.acceptedClientOrderIdFromShard(&self.owner.shard, command.command_id).?,
            .venue_order = try canonical.VenueOrderRef.init(1, try std.fmt.bufPrint(&order_buffer, "windows-mixed-order-{d}", .{command.order_id})),
            .venue_trade = try canonical.VenueTradeRef.init(1, try std.fmt.bufPrint(&trade_buffer, "windows-mixed-trade-{d}", .{identity})),
            .instrument = command.instrument,
            .exchange_account = 2,
            .side = if (command.side == .buy) .buy else .sell,
            .quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = lots },
            .price = fixture.omsPrice(command.instrument, 50_000_000),
            .fee = .{ .asset = 1, .atoms = 1 },
            .liquidity = .taker,
        } });
        fill.venue.envelope.identity.stream = 55;
        fill.venue.envelope.source_stream = 55;
        fill.venue.envelope.raw_evidence.stream = 55;
        _ = try self.owner.apply(fill);
        var execution_report = fixture.canonicalAt(100 + self.owner.shard.oms.next_command_id, self.sourceSequence(33), .{ .execution_report = .{
            .identity = identity + 1000,
            .order = command.order_id,
            .client_order_id = self.gateway.acceptedClientOrderIdFromShard(&self.owner.shard, command.command_id).?,
            .instrument = command.instrument,
            .exchange_account = 2,
            .revision = command.revision,
            .side = if (command.side == .buy) .buy else .sell,
            .status = if (lots == command.quantity) .filled else .partially_filled,
            .original_quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = command.quantity },
            .cumulative_quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = lots },
            .remaining_quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = command.quantity - lots },
        } });
        execution_report.venue.envelope.identity.stream = 33;
        execution_report.venue.envelope.source_stream = 33;
        execution_report.venue.envelope.raw_evidence.stream = 33;
        _ = try self.owner.apply(execution_report);
        try self.checkpoint();
    }
    fn observeBtc(self: *@This(), sequence: u64, atoms: i128) !void {
        const amount: canonical.AssetAmount = .{ .asset = 0x425443, .atoms = atoms };
        const zero: canonical.AssetAmount = .{ .asset = 0x425443, .atoms = 0 };
        var input = fixture.canonicalAt(100 + self.owner.shard.oms.next_command_id, sequence, .{ .account_observed = .{ .identity = sequence, .exchange_account = 2, .bootstrap = 1, .source_stream = 7, .source_sequence = sequence, .value = .{ .balance = .{ .asset = 0x425443, .value = .{ .asset = 0x425443, .total = amount, .available = amount, .held = zero, .cash_balance = amount, .liability = zero, .isolated_liability = zero, .cross_liability = zero } } } } });
        input.venue.envelope.identity.stream = 77;
        input.venue.envelope.source_stream = 7;
        input.venue.envelope.raw_evidence.stream = 77;
        _ = try self.owner.apply(input);
    }
    fn mixedEconomics(self: *@This()) !u64 {
        _ = try self.owner.apply(fixture.atGroup(20, .{ .identity = 400, .payload = .{ .capability_profile_activation = .{ .exchange_account = 2, .instrument = 4, .venue = 1, .environment = .simulation, .product = .spot, .version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .max_dispatch_age_ns = 10 * std.time.ns_per_s, .supports_place = true, .supports_cancel = true, .supports_native_amend = false, .supports_venue_reduce_only = false, .supports_post_only = false, .supports_market_protection = false } } }));
        var book = fixture.snapshotAt(20, 1);
        const snapshot = &book.venue.event.l2_book_snapshot;
        snapshot.instrument = 4;
        snapshot.best_bid.instrument = 4;
        snapshot.best_ask.instrument = 4;
        snapshot.best_bid_quantity.?.instrument = 4;
        snapshot.best_ask_quantity.?.instrument = 4;
        snapshot.next_ask.?.instrument = 4;
        snapshot.next_ask_quantity.?.instrument = 4;
        book.venue.envelope.identity.stream = 44;
        book.venue.envelope.source_stream = 44;
        book.venue.envelope.raw_evidence.stream = 44;
        _ = try self.owner.apply(book);
        for ([_]u128{ 3, 4 }) |instrument| {
            const entry = try self.submit(.{ .intent_sequence = 0, .operation = .place, .instrument = instrument, .quantity = 20, .limit_price = fixture.omsPrice(instrument, 50_000_000) }, false);
            try self.fillOrder(entry, 4);
        }
        try self.observeBtc(2, 8);
        for ([_]u128{ 3, 4 }) |instrument| {
            const lots: i64 = if (instrument == 3) 4 else 2;
            const close_order = try self.submit(.{ .intent_sequence = 0, .operation = .place, .instrument = instrument, .side = .sell, .portfolio_reduce_only = true, .quantity = lots, .limit_price = fixture.omsPrice(instrument, 50_000_000) }, false);
            try self.fillOrder(close_order, lots);
        }
        const hedge = try self.submit(.{ .intent_sequence = 0, .operation = .place, .instrument = 4, .side = .sell, .portfolio_reduce_only = true, .quantity = 2, .limit_price = fixture.omsPrice(4, 50_000_000) }, false);
        try self.fillOrder(hedge, 2);
        try require(self.owner.shard.economic_projection.portfolio.positionForInstrument(3).quantity == 0);
        try require(self.owner.shard.economic_projection.portfolio.positionForInstrument(4).quantity == 0);
        try self.observeBtc(3, 0);
        const quote = try self.place();
        _ = try self.place();
        return quote.order_id;
    }
    fn advance(self: *@This()) !void {
        const order = try self.place();
        const cancel = try self.submit(.{ .intent_sequence = 0, .operation = .cancel, .instrument = 3, .target_order_id = order.order_id, .expected_revision = 1, .expected_cumulative_quantity = 0 }, false);
        try self.coverTerminal(order.order_id, cancel.revision);
        var proofs: [2]execution.DispatchEvidence = undefined;
        const exported = try self.gateway.exportOrderDispatchEvidence(&self.owner.shard, order.order_id, &proofs);
        try require(exported.len == 2);
        _ = try self.owner.archiveTerminalOrder(order.order_id, self.gateway);
        const root = self.owner.shard.business_history_root.?;
        const sends = self.simulator.resting.sends;
        for (proofs) |proof| {
            var storage: [history.max_record_bytes]u8 = undefined;
            const request: history.LookupRequest = .{ .pending_id = proof.proof.command.command_id, .key = .{ .origin = root.origin, .identity = .{ .dispatch_command = proof.proof.command.command_id } }, .candidate_payload_digest = history.hash(try codec.encodeBare(&storage, proof)), .original_input_digest = history.hash("windows accepted cold retry"), .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
            const result = try self.file.interface().queryOrderHistory(self.io, request);
            try require(try self.gateway.retryArchivedDispatch(&self.owner.shard, request, &result) == .accepted);
        }
        try require(sends == self.simulator.resting.sends);
        try self.checkpoint();
    }
    fn coverTerminal(self: *@This(), order_id: u64, revision: u32) !void {
        const order = self.owner.shard.oms.orderById(order_id) orelse return error.MissingCapacityOrder;
        const source_sequence = self.sourceSequence(7);
        const deadline = order.terminal_observed_at_utc_ns + 30 * std.time.ns_per_s;
        const digest = history.hash(std.mem.asBytes(&order_id));
        var terminal_event = fixture.canonicalAt(100 + self.owner.shard.oms.next_command_id, source_sequence, .{ .order_reconciliation_result = .{
            .identity = source_sequence,
            .complete = true,
            .status = .found_terminal,
            .order = order_id,
            .revision = revision,
            .cumulative_quantity = .{ .instrument = 3, .rules_version = 1, .lots = 0 },
            .remaining_quantity = .{ .instrument = 3, .rules_version = 1, .lots = order.quantity },
            .terminal_status = .canceled,
            .rules_version = 1,
            .evidence = .{
                .scope = .{ .exchange_account = 2, .instrument = 3, .order = order_id, .revision = revision, .from_utc_ns = order.created_at_utc_ns, .through_utc_ns = deadline },
                .observed_at_utc_ns = deadline,
                .source = .{ .stream = 7, .sequence = source_sequence, .digest = digest },
                .terminal_archive = .{ .visibility_deadline_utc_ns = deadline, .order_history_complete = true, .terminal_history_complete = true, .fills_complete = true, .economics_complete = true },
            },
        } });
        terminal_event.venue.envelope.identity.stream = 7;
        terminal_event.venue.envelope.source_stream = 7;
        terminal_event.venue.envelope.raw_evidence.stream = 7;
        terminal_event.venue.envelope.raw_evidence.digest = digest;
        terminal_event.venue.envelope.times.source_utc_ns = deadline;
        terminal_event.venue.envelope.times.receive_utc_ns = deadline;
        _ = try self.owner.apply(terminal_event);
    }
};

const ShardReport = struct {
    shard: usize,
    account: u128,
    decision_domain: u64,
    decision_stream_id: u64,
    dispatch_stream_id: u64,
    raw_stream_id: u64,
    portfolio: u128,
    partially_filled: u16,
    pending_cancel: u16,
    resting: u16,
    filled: u16,
    unknown_orders: u16,
    two_leg_entry_orders: u8,
    two_leg_closed_lots: i64,
    hedge_lots: i64,
    instrument4_quantity: i64,
    round: u64,
    barrier: u64,
    digest: [64]u8,
    economic_digest: [64]u8,
    cash_atoms: i128,
    exchange_cash_atoms: i128,
    inventory_atoms: i128,
    quantity: i64,
    cost_atoms: i128,
    fee_atoms: i128,
    ledger_count: u8,
    ledger_digest: [64]u8,
    ledger_debits_atoms: i128,
    ledger_credits_atoms: i128,
    exchange_ledger_debits_atoms: i128,
    exchange_ledger_credits_atoms: i128,
    private_source_cursor: u64,
    reservation_atoms: i128,
    ingress_count: u64,
    next_order: u64,
    next_command: u64,
    live: u16,
    terminal: u16,
    accepted: u16,
    unknown: u16,
    adapter_queue: u8,
    sends: u64,
    recovery_sends: u64,
    snapshot_bytes: usize,
    stored_bytes: u64,
    stored_files: u64,
    history_generation: u64,
    history_root: [64]u8,
    recovery_ns: i128,
};
fn report(cycle: *Cycle, shard: usize) !ShardReport {
    var directory = try std.Io.Dir.openDirAbsolute(cycle.io, cycle.path, .{ .iterate = true });
    defer directory.close(cycle.io);
    var entries = directory.iterate();
    var stored_bytes: u64 = 0;
    var stored_files: u64 = 0;
    while (try entries.next(cycle.io)) |entry| {
        if (entry.kind != .file) return error.UnexpectedStoreEntry;
        stored_bytes += try @import("../../support/file_acceptance_runtime.zig").fileBytes(directory, cycle.io, entry.name);
        stored_files += 1;
    }
    const state = &cycle.owner.shard;
    const economic = &state.economic_projection;
    const root = state.business_history_root;
    const zero: [32]u8 = @splat(0);
    var partial: u16 = 0;
    var pending_cancel: u16 = 0;
    var resting: u16 = 0;
    var filled: u16 = 0;
    var unknown: u16 = 0;
    for (state.oms.orders[0..state.oms.order_count]) |order| switch (order.state) {
        .partially_filled => partial += 1,
        .pending_cancel => pending_cancel += 1,
        .live => resting += 1,
        .filled => filled += 1,
        .unknown => unknown += 1,
        else => {},
    };
    var entry_orders: u8 = 0;
    var closed_lots: i64 = 0;
    var hedge_lots: i64 = 0;
    if (shard == 3) {
        for ([_]u64{ 1, 2 }) |id| {
            const order = state.oms.orderById(id) orelse return error.MissingMixedEntry;
            try require(order.state == .partially_filled and order.side == .buy);
            try require(order.instrument == (if (id == 1) @as(u128, 3) else @as(u128, 4)));
            try require(try economic.appliedCanonicalFillQuantity(id) == 4);
            entry_orders += 1;
        }
        for ([_]u64{ 3, 4 }) |id| closed_lots += try economic.appliedCanonicalFillQuantity(id);
        const hedge_order = state.oms.orderById(5) orelse return error.MissingMixedHedge;
        try require(hedge_order.portfolio_reduce_only and hedge_order.instrument == 4 and hedge_order.side == .sell and hedge_order.state == .filled);
        hedge_lots = try economic.appliedCanonicalFillQuantity(5);
    }
    const encoded = try cycle.owner.committedSnapshot(cycle.scratch);
    var ledger_bytes: [512]u8 = undefined;
    const ledger = try codec.encodeBare(&ledger_bytes, economic.ledger_summary);
    return .{ .shard = shard, .account = state.exchange_account_identity, .decision_domain = cycle.lease.key.decision_domain, .decision_stream_id = cycle.decision_stream.id, .dispatch_stream_id = cycle.dispatch_stream.id, .raw_stream_id = cycle.ingress_stream.id, .portfolio = state.portfolio_identity, .partially_filled = partial, .pending_cancel = pending_cancel, .resting = resting, .filled = filled, .unknown_orders = unknown, .two_leg_entry_orders = entry_orders, .two_leg_closed_lots = closed_lots, .hedge_lots = hedge_lots, .instrument4_quantity = economic.portfolio.positionForInstrument(4).quantity, .round = if (shard == 3) 0 else state.oms.next_order_id - 2, .barrier = state.authoritativeBarrier(), .digest = std.fmt.bytesToHex(state.canonicalStateDigest(), .lower), .economic_digest = std.fmt.bytesToHex(economic.semanticDigest(), .lower), .cash_atoms = economic.portfolio.usdt_balance_atoms, .exchange_cash_atoms = economic.exchange.usdt_balance_atoms, .inventory_atoms = economic.portfolio.spotInventoryAtoms(0x425443), .quantity = economic.portfolio.positionForInstrument(3).quantity, .cost_atoms = economic.portfolio.positionForInstrument(3).open_cost_atoms, .fee_atoms = economic.portfolio.fee_atoms, .ledger_count = economic.ledger_count, .ledger_digest = std.fmt.bytesToHex(history.hash(ledger), .lower), .ledger_debits_atoms = economic.ledger_summary.portfolio_debits_atoms, .ledger_credits_atoms = economic.ledger_summary.portfolio_credits_atoms, .exchange_ledger_debits_atoms = economic.ledger_summary.exchange_debits_atoms, .exchange_ledger_credits_atoms = economic.ledger_summary.exchange_credits_atoms, .private_source_cursor = cycle.sourceSequence(1) - 1, .reservation_atoms = try state.activeReservationAtoms(), .ingress_count = state.canonical_ingress_count, .next_order = state.oms.next_order_id, .next_command = state.oms.next_command_id, .live = state.oms.liveOrderCount(), .terminal = state.oms.retainedTerminalOrderCount(), .accepted = cycle.gateway.accepted_dispatch_count, .unknown = cycle.gateway.uncertain_dispatch_count, .adapter_queue = @intFromBool(cycle.simulator.resting.pending != null), .sends = cycle.simulator.resting.sends, .recovery_sends = cycle.recovery_send_count, .snapshot_bytes = encoded.len, .stored_bytes = stored_bytes, .stored_files = stored_files, .history_generation = if (root) |r| r.generation else 0, .history_root = std.fmt.bytesToHex(if (root) |r| r.root_digest else zero, .lower), .recovery_ns = cycle.recovery_ns };
}

pub fn run(init: std.process.Init, mode: []const u8, path: []const u8) !void {
    return @import("../../support/file_acceptance_runtime.zig").run(runCurrentThread, init, mode, path);
}

fn runCurrentThread(init: std.process.Init, mode: []const u8, path: []const u8) !void {
    const evidence = try runProtocol(init.gpa, init.io, mode, path);
    var output_buffer: [16384]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try std.json.Stringify.value(evidence, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
fn halt(io: std.Io, phase: []const u8, cycle: *Cycle) !void {
    var buffer: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    const hex = std.fmt.bytesToHex(cycle.owner.shard.canonicalStateDigest(), .lower);
    try stderr.interface.print("READY_{s} shard=0 barrier={d} digest={s}\n", .{ phase, cycle.owner.shard.authoritativeBarrier(), &hex });
    try stderr.interface.flush();
    while (true) try io.sleep(.fromSeconds(1), .awake);
}
fn atomicStep(cycle: *Cycle) !void {
    const barrier = cycle.owner.shard.authoritativeBarrier();
    _ = try cycle.owner.apply(fixture.atGroup(200, .{ .identity = 500000 + barrier, .payload = .{ .mark_price = .{ .instrument = 3, .price_atoms = 50_000_000 } } }));
}

const Report = struct { schema: u16 = 2, mode: []const u8, seed: u64 = seed, round: u64, shards: [4]ShardReport, shared_account: @import("../../support/windows_capacity_shared.zig").Report = undefined, send_count: u64, recovery_send_count: u64 = 0, synthetic_fencing: bool = true, production_qualification: bool = false };
fn runProtocol(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, path: []const u8) !Report {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.NativeFilePlatformRequired;
    const virgin = std.mem.eql(u8, mode, "seed");
    const advancing = std.mem.eql(u8, mode, "advance");
    const stepping = std.mem.eql(u8, mode, "step");
    const hold_before = std.mem.eql(u8, mode, "hold-before-step");
    const hold_after = std.mem.eql(u8, mode, "hold-after-step");
    if (!virgin and !advancing and !stepping and !hold_before and !hold_after and !std.mem.eql(u8, mode, "recover")) return error.InvalidWindowsCapacityMode;
    if (!std.fs.path.isAbsolute(path)) return error.AbsoluteDirectoryRequired;
    if (virgin) {
        std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else {
        var existing = try std.Io.Dir.openDirAbsolute(io, path, .{});
        existing.close(io);
    }
    var result: Report = .{ .mode = mode, .round = 0, .shards = undefined, .send_count = 0 };
    var summaries: [4]coordination.ShardSummary = undefined;
    for (0..4) |shard| {
        var child_buffer: [1024]u8 = undefined;
        const child = try std.fmt.bufPrint(&child_buffer, "{s}{s}shard-{d}", .{ path, std.fs.path.sep_str, shard });
        const cycle = try Cycle.open(allocator, io, child, virgin, shard);
        defer cycle.close();
        if (virgin) try cycle.seedState(shard) else if (advancing and shard != 3) try cycle.advance();
        if (shard == 0 and hold_before) try halt(io, "BEFORE", cycle);
        if (shard == 0 and (stepping or hold_after)) try atomicStep(cycle);
        if (shard == 0 and hold_after) try halt(io, "AFTER", cycle);
        result.shards[shard] = try report(cycle, shard);
        summaries[shard] = try coordination.shardSummaryFromShard(&cycle.owner.shard, @enumFromInt(shard), 1, shard + 1);
        try require(summaries[shard].virtual_portfolio == 11 + shard and summaries[shard].exchange_account == 2);
        if (shard == 0) result.round = result.shards[shard].round;
        result.send_count += result.shards[shard].sends;
        try require(result.shards[shard].quantity == 2 and result.shards[shard].inventory_atoms == 2);
        try require(result.shards[shard].fee_atoms == (if (shard == 3) @as(i128, 6) else @as(i128, 1)));
        try require(result.shards[shard].live <= 6 and result.shards[shard].terminal == (if (shard == 3) @as(u16, 3) else @as(u16, 0)));
        if (shard == 3) try require(result.shards[shard].unknown == 1);
    }
    result.shared_account = try @import("../../support/windows_capacity_shared.zig").verify(allocator, io, path, virgin, advancing, summaries);
    return result;
}

test "Native file capacity real file seed recovery preserves public business state" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{});
    var completed = false;
    defer if (completed) temp.cleanup();
    var path_buffer: [1024]u8 = undefined;
    const path = path_buffer[0..try temp.dir.realPath(std.testing.io, &path_buffer)];
    const seeded = try runProtocol(std.testing.allocator, std.testing.io, "seed", path);
    const recovered = try runProtocol(std.testing.allocator, std.testing.io, "recover", path);
    try std.testing.expectEqual(@as(u64, 0), recovered.send_count);
    for (seeded.shards, recovered.shards) |before, after| {
        try std.testing.expectEqualSlices(u8, &before.digest, &after.digest);
        try std.testing.expectEqualSlices(u8, &before.economic_digest, &after.economic_digest);
    }
    const advanced = try runProtocol(std.testing.allocator, std.testing.io, "advance", path);
    try std.testing.expectEqual(@as(u64, 1), advanced.round);
    try std.testing.expectEqual(@as(u64, 6), advanced.send_count);
    const twice = try runProtocol(std.testing.allocator, std.testing.io, "recover", path);
    for (advanced.shards, twice.shards) |before, after| try std.testing.expectEqualSlices(u8, &before.digest, &after.digest);
    completed = true;
}
