//! Frontier 09 small deterministic public workload. No network or capacity stress.
const std = @import("std");
const acceptance = @import("order_gateway_archive_acceptance.zig");
const canonical = @import("canonical_event.zig");
const trading = @import("trading_shard.zig");
const fixture = @import("trading_shard_fixture.zig");
const history = @import("business_history.zig");
const venue = @import("venue_adapter.zig");
const demo = @import("demo_authority.zig");
const execution = @import("execution_gateway.zig");

fn verifyRecoveredCapacity(cycle: *Cycle) !void {
    const allocator = std.testing.allocator;
    try cycle.harness.owner.checkpointWithScratch(cycle.checkpoint_scratch);
    try cycle.harness.gateway.checkpointDurableDispatch();
    const owner = try allocator.create(demo.Owner);
    errdefer allocator.destroy(owner);
    try demo.Owner.recoverInto(owner, cycle.harness.backend.interface(), undefined, cycle.harness.stream);
    try std.testing.expectEqualSlices(u8, &cycle.harness.owner.shard.canonicalStateDigest(), &owner.shard.canonicalStateDigest());
    try std.testing.expectEqual(cycle.harness.owner.shard.oms.next_order_id, owner.shard.oms.next_order_id);
    const gateway = try allocator.create(execution.Gateway);
    errdefer allocator.destroy(gateway);
    gateway.init();
    try gateway.add(cycle.harness.route);
    const sends = cycle.simulator.sends;
    try gateway.attachRecoveredDurableDispatch(cycle.harness.backend.interface(), undefined, cycle.harness.dispatch_stream);
    try std.testing.expectEqual(cycle.harness.gateway.accepted_dispatch_count, gateway.accepted_dispatch_count);
    try std.testing.expectEqual(cycle.harness.gateway.uncertain_dispatch_count, gateway.uncertain_dispatch_count);
    for (owner.shard.oms.commands[0..owner.shard.oms.command_count]) |command| {
        try std.testing.expectEqual(cycle.harness.gateway.acceptedClientOrderIdFromShard(&cycle.harness.owner.shard, command.command_id), gateway.acceptedClientOrderIdFromShard(&owner.shard, command.command_id));
    }
    try std.testing.expectEqual(sends, cycle.simulator.sends);
    const raw_stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = cycle.harness.stream.id + 100 };
    try owner.bindRecoveryIngress(cycle.harness.backend.interface(), raw_stream);
    const Replay = struct {
        fn consume(ptr: *anyopaque, _: u64, _: @import("okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
            const target: *demo.Owner = @ptrCast(@alignCast(ptr));
            const input = try codec.decodeBare(bytes, canonical.EventRecord);
            var batch: canonical.AdapterOutputBatch = .{};
            try batch.append(input);
            try target.applyAdapterBatch(batch);
        }
    };
    try owner.replayCommittedIngress(raw_stream, .{ .ptr = owner, .consume_fn = Replay.consume });
    try std.testing.expect(!owner.shard.recovery_admission_pending);
    allocator.destroy(cycle.harness.owner);
    allocator.destroy(cycle.harness.gateway);
    cycle.harness.owner = owner;
    cycle.harness.gateway = gateway;
}

const Cycle = struct {
    harness: *acceptance.ArchiveHarness,
    checkpoint_scratch: []u8,
    simulator: acceptance.RestingSimulator = .{},
    next_intent: u64 = 101,
    next_reconciliation: u64 = 4,
    operations_since_checkpoint: u8 = 0,
    submit_sample_count: u64 = 0,
    submit_elapsed_ns: i128 = 0,
    max_adapter_batch_records: u8 = 0,

    fn create(allocator: std.mem.Allocator, stream: u64) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        const checkpoint_scratch = try allocator.alloc(u8, @import("durable_store.zig").max_snapshot_bytes);
        errdefer allocator.free(checkpoint_scratch);
        self.* = .{ .harness = try acceptance.ArchiveHarness.createBase(allocator, stream), .checkpoint_scratch = checkpoint_scratch };
        errdefer self.harness.destroy();
        // Retained COW paths alone measured 630 MiB; retention/RSS qualification is ticket 09.
        self.harness.backend.memory.archive_quota = 1024 * 1024 * 1024;
        try self.harness.bindAdapter(self.simulator.adapter());
        return self;
    }

    fn destroy(self: *@This(), allocator: std.mem.Allocator) void {
        self.harness.destroy();
        allocator.free(self.checkpoint_scratch);
        allocator.destroy(self);
    }

    fn maintain(self: *@This()) !void {
        self.operations_since_checkpoint += 1;
        if (self.operations_since_checkpoint < 3) return;
        try self.harness.owner.checkpointWithScratch(self.checkpoint_scratch);
        try self.harness.gateway.checkpointDurableDispatch();
        self.operations_since_checkpoint = 0;
    }

    fn submit(self: *@This(), intent: trading.oms.Intent) !trading.oms.Command {
        const start_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        defer {
            self.submit_sample_count += 1;
            self.submit_elapsed_ns += std.Io.Clock.awake.now(std.testing.io).nanoseconds - start_ns;
        }
        const sequence = self.next_intent;
        self.next_intent += 1;
        if (sequence == 101 or sequence % 8 == 0) {
            const source_sequence = self.next_reconciliation;
            self.next_reconciliation += 1;
            var book = fixture.snapshotAt(sequence, source_sequence);
            book.venue.envelope.identity.stream = 7;
            book.venue.envelope.source_stream = 7;
            book.venue.envelope.raw_evidence.stream = 7;
            _ = try self.harness.owner.apply(book);
            try self.maintain();
        }
        var group: trading.oms.IntentGroup = .{ .first_intent_sequence = sequence, .count = 1 };
        group.members[0] = intent;
        group.members[0].intent_sequence = sequence;
        const input = fixture.atGroup(sequence, .{ .identity = sequence, .payload = .{ .oms_intent_group = group } });
        const dispatch_time = input.core.monotonic_time + std.time.ns_per_ms;
        try self.harness.authority.renew(&self.harness.lease, dispatch_time);
        self.simulator.receive_monotonic_ns = dispatch_time;
        self.simulator.receive_utc_ns = input.core.receive_time + std.time.ns_per_ms;
        _ = try self.harness.owner.apply(input);
        if (self.harness.owner.shard.oms.emitted().len != 1) return error.MissingCapacityCommand;
        const command = self.harness.owner.shard.oms.emitted()[0];
        try std.testing.expect(command.authority.complete());
        try std.testing.expectEqual(venue.SendResult.accepted, try self.harness.owner.send(self.harness.gateway, &self.harness.guard, command.command_id, dispatch_time));
        const batch = (try self.simulator.adapter().tryDrain()).?;
        self.max_adapter_batch_records = @max(self.max_adapter_batch_records, batch.len);
        try self.harness.owner.applyAdapterBatch(batch);
        try self.maintain();
        return command;
    }

    fn place(self: *@This()) !u64 {
        const command = try self.submit(.{ .intent_sequence = 0, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) });
        try std.testing.expectEqual(trading.oms.OrderState.live, self.harness.owner.shard.oms.orderById(command.order_id).?.state);
        return command.order_id;
    }

    fn terminal(self: *@This(), order_id: u64) !void {
        const command = try self.submit(.{ .intent_sequence = 0, .operation = .cancel, .instrument = 3, .target_order_id = order_id, .expected_revision = 1, .expected_cumulative_quantity = 0 });
        const order = self.harness.owner.shard.oms.orderById(order_id) orelse return error.MissingCapacityOrder;
        try std.testing.expectEqual(trading.oms.OrderState.canceled, order.state);
        try self.coverTerminal(order_id, command.revision);
        try self.maintain();
    }

    fn coverTerminal(self: *@This(), order_id: u64, revision: u32) !void {
        const order = self.harness.owner.shard.oms.orderById(order_id) orelse return error.MissingCapacityOrder;
        const source_sequence = self.next_reconciliation;
        self.next_reconciliation += 1;
        const deadline = order.terminal_observed_at_utc_ns + 30 * std.time.ns_per_s;
        const digest = history.hash(std.mem.asBytes(&order_id));
        var terminal_event = fixture.canonicalAt(self.next_intent, source_sequence, .{ .order_reconciliation_result = .{
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
        _ = try self.harness.owner.apply(terminal_event);
    }

    fn archive(self: *@This(), order_id: u64) !void {
        _ = self.harness.owner.archiveTerminalOrder(order_id, self.harness.gateway) catch |err| {
            const memory = &self.harness.backend.memory;
            std.debug.print("Owner archive failed: stream={d} order={d} error={s} journal_bytes={d} history_bytes={d} quota={d}\n", .{ self.harness.stream.id, order_id, @errorName(err), memory.archive_bytes, memory.history_objects.items.len, memory.archive_quota });
            return err;
        };
        try std.testing.expect(self.harness.owner.shard.oms.orderById(order_id) == null);
        try self.maintain();
    }
};

const raw = @import("raw_ingress.zig");
const codec = @import("snapshot_codec.zig");
const seed: u64 = 0x20261008;
const durable = @import("durable_store.zig");

fn observe(cycle: *Cycle, route: usize) !void {
    // 500 Owner-local rows / 494 globally distinct combinations: shared genesis
    // identities 3 and 4 occur on all four Owners. The separate observation
    // acceptance fixture supplies the unique-500 qualification.
    // 125 real instrument identities per Owner; 123 observation-only identities
    // supplement genesis instruments 3 and 4. Four Venue identities are observed;
    // only Venue 1 receives the selected synthetic order subset.
    for (0..125) |index| {
        const id: u128 = if (index < 2) index + 3 else 10000 + route * 125 + index;
        const venue_id: u64 = if (index < 2) 1 else ([_]u64{ 1, 21, 42, 84 })[index % 4];
        if (index >= 2) {
            _ = try cycle.harness.owner.apply(fixture.atGroup(20, .{ .identity = 10000 + index, .payload = .{ .instrument_rules_activated = .{ .version = 1, .instrument_identity = id, .quantity_denominator = 100_000_000, .reservation_model = .cash, .product = .spot, .venue = venue_id, .base_asset = 0x425443 } } }));
            if (cycle.harness.owner.shard.trace.len >= 180) try cycle.harness.owner.checkpointWithScratch(cycle.checkpoint_scratch);
        }
        var input = fixture.canonicalAt(21, index + 1, .{ .l2_book_snapshot = .{ .instrument = id, .sequence = if (index == 0) 3 else 1, .best_bid = fixture.omsPrice(id, 49_000_000), .best_ask = fixture.omsPrice(id, 50_000_000), .best_bid_quantity = .{ .instrument = id, .rules_version = 1, .lots = 100 }, .best_ask_quantity = .{ .instrument = id, .rules_version = 1, .lots = 100 } } });
        input.venue.envelope.venue = venue_id;
        input.venue.envelope.exchange_account = null;
        input.venue.envelope.scope = .instrument;
        input.venue.envelope.instrument = id;
        input.venue.envelope.identity.stream = 8 + venue_id;
        input.venue.envelope.source_stream = 8 + venue_id;
        input.venue.envelope.raw_evidence.stream = 8 + venue_id;
        _ = try cycle.harness.owner.apply(input);
        if (index == 124) {
            var sink = try raw.DurableSink.init(cycle.harness.backend.interface(), undefined, .{ .domain = .raw_ingress, .id = cycle.harness.stream.id + 100 });
            var storage: [32768]u8 = undefined;
            const bytes = try codec.encodeBare(&storage, input.venue);
            _ = try sink.interface().append(.{ .source_session = 1, .byte_len = @intCast(bytes.len), .sha256 = history.hash(bytes), .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1 }, bytes);
        }
        if (cycle.harness.owner.shard.trace.len >= 180) try cycle.harness.owner.checkpointWithScratch(cycle.checkpoint_scratch);
        try std.testing.expect(cycle.harness.owner.shard.instrument_registry.get(id) != null);
    }
    try std.testing.expectEqual(@as(usize, 125), cycle.harness.owner.shard.instrument_registry.count);
}

fn recoverRound(cycle: *Cycle, round: usize, shard: usize) !void {
    try verifyRecoveredCapacity(cycle);
    const owner = cycle.harness.owner;
    const encoded = try owner.committedSnapshot(cycle.checkpoint_scratch);
    const root = owner.shard.business_history_root.?;
    std.debug.print("continuous storage round={d} shard={d} archive_journal_bytes={d} history_object_bytes={d} quota_bytes={d} tail_records={d} tail_bytes={d}\n", .{ round, shard, cycle.harness.backend.memory.archive_bytes, cycle.harness.backend.memory.history_objects.items.len, cycle.harness.backend.memory.archive_quota, owner.decision_journal.records, owner.decision_journal.bytes().len });
    std.debug.print("continuous seed=0x{x} round={d} shard={d} live={d} terminal={d} trace={d} ingress={d} ledger={d} fills={d} accepted={d} unknown={d} adapter_queue={d} barrier={d} snapshot_bytes={d} history_generation={d} history_root={x} sends={d} submit_samples={d} submit_total_ns={d}\n", .{ seed, round, shard, owner.shard.oms.liveOrderCount(), owner.shard.oms.retainedTerminalOrderCount(), owner.shard.trace.len, owner.shard.canonical_ingress_count, owner.shard.economic_projection.ledger_count, owner.shard.economic_projection.applied_fill_count, cycle.harness.gateway.accepted_dispatch_count, cycle.harness.gateway.uncertain_dispatch_count, @intFromBool(cycle.simulator.pending != null), owner.shard.authoritativeBarrier(), encoded.len, root.generation, root.root_digest, cycle.simulator.sends, cycle.submit_sample_count, cycle.submit_elapsed_ns });
}

fn retryAcceptedHistory(cycle: *Cycle, proofs: []const execution.DispatchEvidence) !void {
    if (proofs.len != 0) {
        const root = cycle.harness.owner.shard.business_history_root.?;
        for (proofs) |proof| {
            var encoded: [history.max_record_bytes]u8 = undefined;
            const request: history.LookupRequest = .{ .pending_id = proof.proof.command.command_id, .key = .{ .origin = root.origin, .identity = .{ .dispatch_command = proof.proof.command.command_id } }, .candidate_payload_digest = history.hash(try codec.encodeBare(&encoded, proof)), .original_input_digest = history.hash("continuous accepted retry"), .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
            const result = try cycle.harness.backend.interface().queryOrderHistory(undefined, request);
            try std.testing.expectEqual(venue.SendResult.accepted, try cycle.harness.gateway.retryArchivedDispatch(&cycle.harness.owner.shard, request, &result));
        }
    }
}

fn runContinuous() !void {
    const allocator = std.testing.allocator;
    var cycles: [4]*Cycle = undefined;
    var initialized: usize = 0;
    defer for (cycles[0..initialized]) |cycle| cycle.destroy(allocator);
    for (&cycles, 0..) |*cycle, shard| {
        cycle.* = try Cycle.create(allocator, 6200 + shard * 2);
        initialized += 1;
        try observe(cycle.*, shard);
    }
    std.debug.print("continuous layout owner={d} shard={d} oms={d} gateway={d} adapter_batch={d} canonical_record={d} command={d} fixture={d}\n", .{ @sizeOf(demo.Owner), @sizeOf(trading.TradingShard), @sizeOf(trading.oms.Oms), @sizeOf(execution.Gateway), @sizeOf(canonical.AdapterOutputBatch), @sizeOf(canonical.EventRecord), @sizeOf(trading.oms.Command), @sizeOf(Cycle) });
    // Selected resting orders coexist with completed order lifecycles.
    var retained_fill: [4]trading.CanonicalEvent = undefined;
    for (cycles, 0..) |cycle, shard| {
        _ = try cycle.place();
        const command = cycle.harness.owner.shard.oms.command_history[0];
        retained_fill[shard] = try applyFill(cycle, command, 7001, 2);
        try reportFill(cycle, command, 8001, 2);
    }
    var old_group: [4]trading.oms.IntentGroup = undefined;
    for (0..10) |round| {
        var total_live: usize = 0;
        var total_terminal: usize = 0;
        for (cycles, 0..) |cycle, shard| {
            // First five rounds balanced, last five shard 0 hot; shard 3
            // remains observation/resting-only during the hotspot phase.
            const count: usize = if (round < 5) 1 else if (shard == 0) 3 else if (shard == 3) 0 else 1;
            var terminal_ids: [3]u64 = undefined;
            for (terminal_ids[0..count]) |*id| {
                const sequence = cycle.next_intent;
                id.* = try cycle.place();
                if (round == 0) {
                    old_group[shard] = .{ .first_intent_sequence = sequence, .count = 1 };
                    old_group[shard].members[0] = .{ .intent_sequence = sequence, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
                }
                try cycle.terminal(id.*);
            }
            try std.testing.expectEqual(@as(u16, 1), cycle.harness.owner.shard.oms.liveOrderCount());
            try std.testing.expectEqual(@as(u16, @intCast(count)), cycle.harness.owner.shard.oms.retainedTerminalOrderCount());
            total_live += cycle.harness.owner.shard.oms.liveOrderCount();
            total_terminal += cycle.harness.owner.shard.oms.retainedTerminalOrderCount();
            std.debug.print("continuous backlog round={d} shard={d} live={d} terminal={d} batch_highwater={d} deferred={d}\n", .{ round + 1, shard, cycle.harness.owner.shard.oms.liveOrderCount(), cycle.harness.owner.shard.oms.retainedTerminalOrderCount(), cycle.max_adapter_batch_records, cycle.harness.owner.shard.deferred_history_admission_count });
            std.debug.print("continuous coexist round={d} shard={d} live=1 terminal={d}\n", .{ round + 1, shard, count });
            var proofs: [6]execution.DispatchEvidence = undefined;
            for (terminal_ids[0..count], 0..) |id, index| {
                const exported = try cycle.harness.gateway.exportOrderDispatchEvidence(&cycle.harness.owner.shard, id, proofs[index * 2 ..][0..2]);
                try std.testing.expectEqual(@as(usize, 2), exported.len);
                try cycle.archive(id);
            }
            const accepted_sends = cycle.simulator.sends;
            try retryAcceptedHistory(cycle, proofs[0 .. count * 2]);
            try std.testing.expectEqual(accepted_sends, cycle.simulator.sends);
            try recoverRound(cycle, round + 1, shard);
            try retryAcceptedHistory(cycle, proofs[0 .. count * 2]);
            try std.testing.expectEqual(accepted_sends, cycle.simulator.sends);
            const before = cycle.harness.owner.shard.economic_projection.semanticDigest();
            const next_order = cycle.harness.owner.shard.oms.next_order_id;
            const sends = cycle.simulator.sends;
            _ = try cycle.harness.owner.apply(fixture.atGroup(3000 + round, .{ .identity = 3000 + round, .payload = .{ .oms_intent_group = old_group[shard] } }));
            _ = try cycle.harness.owner.apply(retained_fill[shard]);
            try std.testing.expectEqual(@as(i64, 2), cycle.harness.owner.shard.economic_projection.portfolio.positionForInstrument(3).quantity);
            try std.testing.expectEqual(next_order, cycle.harness.owner.shard.oms.next_order_id);
            try std.testing.expectEqualSlices(u8, &before, &cycle.harness.owner.shard.economic_projection.semanticDigest());
            try std.testing.expectEqual(sends, cycle.simulator.sends);
        }
        try std.testing.expect(total_live <= 100 and total_terminal <= 100);
    }
}

test "Continuous capacity four shards retain 500 observation projections and recover ten balanced and hotspot rounds without resend" {
    try runContinuous();
}

fn applyFill(cycle: *Cycle, command: trading.oms.Command, identity: u64, lots: i64) !trading.CanonicalEvent {
    var order_text: [32]u8 = undefined;
    var trade_text: [32]u8 = undefined;
    var input = fixture.canonicalAt(cycle.next_intent, 1000 + identity, .{ .fill = .{
        .identity = identity,
        .order = command.order_id,
        .client_order_id = cycle.harness.gateway.acceptedClientOrderIdFromShard(&cycle.harness.owner.shard, command.command_id).?,
        .venue_order = try canonical.VenueOrderRef.init(1, try std.fmt.bufPrint(&order_text, "continuous-order-{d}", .{command.order_id})),
        .venue_trade = try canonical.VenueTradeRef.init(1, try std.fmt.bufPrint(&trade_text, "continuous-fill-{d}", .{identity})),
        .instrument = command.instrument,
        .exchange_account = 2,
        .side = if (command.side == .buy) .buy else .sell,
        .quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = lots },
        .price = fixture.omsPrice(command.instrument, 50_000_000),
        .fee = .{ .asset = 1, .atoms = 0 },
        .liquidity = .taker,
    } });
    input.venue.envelope.identity.stream = 55;
    input.venue.envelope.source_stream = 55;
    input.venue.envelope.raw_evidence.stream = 55;
    _ = try cycle.harness.owner.apply(input);
    try cycle.maintain();
    return input;
}

fn reportFill(cycle: *Cycle, command: trading.oms.Command, identity: u64, lots: i64) !void {
    const input = fixture.canonicalAt(cycle.next_intent, identity, .{ .execution_report = .{
        .identity = identity,
        .order = command.order_id,
        .client_order_id = cycle.harness.gateway.acceptedClientOrderIdFromShard(&cycle.harness.owner.shard, command.command_id).?,
        .instrument = command.instrument,
        .exchange_account = 2,
        .revision = command.revision,
        .side = if (command.side == .buy) .buy else .sell,
        .status = if (lots == command.quantity) .filled else .partially_filled,
        .original_quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = command.quantity },
        .cumulative_quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = lots },
        .remaining_quantity = .{ .instrument = command.instrument, .rules_version = 1, .lots = command.quantity - lots },
    } });
    var private_input = input;
    private_input.venue.envelope.identity.stream = 33;
    private_input.venue.envelope.source_stream = 33;
    private_input.venue.envelope.raw_evidence.stream = 33;
    _ = try cycle.harness.owner.apply(private_input);
    try cycle.maintain();
}

fn unsent(cycle: *Cycle, intent: trading.oms.Intent) !trading.oms.Command {
    const sequence = cycle.next_intent;
    cycle.next_intent += 1;
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = sequence, .count = 1 };
    group.members[0] = intent;
    group.members[0].intent_sequence = sequence;
    _ = try cycle.harness.owner.apply(fixture.atGroup(sequence, .{ .identity = sequence, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), cycle.harness.owner.shard.oms.emitted().len);
    return cycle.harness.owner.shard.oms.emitted()[0];
}

fn observeBtc(cycle: *Cycle, sequence: u64, atoms: i128) !void {
    const amount: canonical.AssetAmount = .{ .asset = 0x425443, .atoms = atoms };
    const zero: canonical.AssetAmount = .{ .asset = 0x425443, .atoms = 0 };
    var input = fixture.canonicalAt(cycle.next_intent, sequence, .{ .account_observed = .{ .identity = sequence, .exchange_account = 2, .bootstrap = 1, .source_stream = 7, .source_sequence = sequence, .value = .{ .balance = .{ .asset = 0x425443, .value = .{ .asset = 0x425443, .total = amount, .available = amount, .held = zero, .cash_balance = amount, .liability = zero, .isolated_liability = zero, .cross_liability = zero } } } } });
    input.venue.envelope.identity.stream = 77;
    input.venue.envelope.source_stream = 7;
    input.venue.envelope.raw_evidence.stream = 77;
    _ = try cycle.harness.owner.apply(input);
    try cycle.maintain();
}

test "Continuous mixed lifecycle two leg entry close hedge and selected quotes preserve economics through recovery" {
    const allocator = std.testing.allocator;
    const cycle = try Cycle.create(allocator, 6290);
    defer cycle.destroy(allocator);
    _ = try cycle.harness.owner.apply(fixture.atGroup(20, .{ .identity = 400, .payload = .{ .capability_profile_activation = .{ .exchange_account = 2, .instrument = 4, .venue = 1, .environment = .simulation, .product = .spot, .version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .max_dispatch_age_ns = 10 * std.time.ns_per_s, .supports_place = true, .supports_cancel = true, .supports_native_amend = false, .supports_venue_reduce_only = false, .supports_post_only = false, .supports_market_protection = false } } }));
    var second_book = fixture.snapshotAt(20, 1);
    second_book.venue.event.l2_book_snapshot.instrument = 4;
    second_book.venue.event.l2_book_snapshot.best_bid.instrument = 4;
    second_book.venue.event.l2_book_snapshot.best_ask.instrument = 4;
    second_book.venue.event.l2_book_snapshot.best_bid_quantity.?.instrument = 4;
    second_book.venue.event.l2_book_snapshot.best_ask_quantity.?.instrument = 4;
    second_book.venue.event.l2_book_snapshot.next_ask.?.instrument = 4;
    second_book.venue.event.l2_book_snapshot.next_ask_quantity.?.instrument = 4;
    second_book.venue.envelope.identity.stream = 44;
    second_book.venue.envelope.source_stream = 44;
    second_book.venue.envelope.raw_evidence.stream = 44;
    _ = try cycle.harness.owner.apply(second_book);
    const first = try cycle.submit(.{ .intent_sequence = 0, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) });
    const second = try cycle.submit(.{ .intent_sequence = 0, .operation = .place, .instrument = 4, .quantity = 20, .limit_price = fixture.omsPrice(4, 50_000_000) });
    const original_fill = try applyFill(cycle, first, 7001, 4);
    try reportFill(cycle, first, 8001, 4);
    _ = try applyFill(cycle, second, 7002, 4);
    try reportFill(cycle, second, 8002, 4);
    try std.testing.expectEqual(@as(i64, 4), cycle.harness.owner.shard.economic_projection.portfolio.positionForInstrument(3).quantity);
    try std.testing.expectEqual(@as(i64, 4), cycle.harness.owner.shard.economic_projection.portfolio.positionForInstrument(4).quantity);
    try observeBtc(cycle, 2, 8);
    // Close both entry legs, retaining two lots on leg 4 for a separate
    // synthetic hedge intent. Every close/hedge passes normal risk and Gateway.
    for ([_]u128{ 3, 4 }) |instrument| {
        const lots: i64 = if (instrument == 3) 4 else 2;
        const close = try cycle.submit(.{ .intent_sequence = 0, .operation = .place, .instrument = instrument, .side = .sell, .portfolio_reduce_only = true, .quantity = lots, .limit_price = fixture.omsPrice(instrument, 50_000_000) });
        _ = try applyFill(cycle, close, 7000 + cycle.next_intent, lots);
        try reportFill(cycle, close, 8000 + cycle.next_intent, lots);
        try std.testing.expectEqual(4 - lots, cycle.harness.owner.shard.economic_projection.portfolio.positionForInstrument(instrument).quantity);
    }
    const hedge = try cycle.submit(.{ .intent_sequence = 0, .operation = .place, .instrument = 4, .side = .sell, .portfolio_reduce_only = true, .quantity = 2, .limit_price = fixture.omsPrice(4, 50_000_000) });
    _ = try applyFill(cycle, hedge, 7500, 2);
    try reportFill(cycle, hedge, 8500, 2);
    try std.testing.expectEqual(@as(i64, 0), cycle.harness.owner.shard.economic_projection.portfolio.positionForInstrument(4).quantity);
    try observeBtc(cycle, 3, 0);
    const quote = try cycle.place();
    const resting = try cycle.place();
    try std.testing.expectEqual(trading.oms.OrderState.live, cycle.harness.owner.shard.oms.orderById(resting).?.state);
    const uncertain = try unsent(cycle, .{ .intent_sequence = 0, .operation = .place, .instrument = 3, .quantity = 1, .limit_price = fixture.omsPrice(3, 50_000_000) });
    _ = try unsent(cycle, .{ .intent_sequence = 0, .operation = .cancel, .instrument = 3, .target_order_id = quote, .expected_revision = 1, .expected_cumulative_quantity = 0 });
    try std.testing.expectEqual(trading.oms.OrderState.pending_cancel, cycle.harness.owner.shard.oms.orderById(quote).?.state);
    var unknown_input = fixture.canonicalAt(200, 1, .{ .order_dispatch_result = .{ .command = uncertain.command_id, .state = .unknown } });
    unknown_input.venue.envelope.identity.stream = 66;
    unknown_input.venue.envelope.source_stream = 66;
    unknown_input.venue.envelope.raw_evidence.stream = 66;
    _ = try cycle.harness.owner.apply(unknown_input);
    try std.testing.expectEqual(trading.oms.OrderState.unknown, cycle.harness.owner.shard.oms.orderById(uncertain.order_id).?.state);
    try cycle.harness.owner.checkpointWithScratch(cycle.checkpoint_scratch);
    try cycle.harness.gateway.checkpointDurableDispatch();
    const economics = cycle.harness.owner.shard.economic_projection.semanticDigest();
    const digest = cycle.harness.owner.shard.canonicalStateDigest();
    const sends = cycle.simulator.sends;
    const restored = try allocator.create(demo.Owner);
    defer allocator.destroy(restored);
    try demo.Owner.recoverInto(restored, cycle.harness.backend.interface(), undefined, cycle.harness.stream);
    try std.testing.expectEqualSlices(u8, &digest, &restored.shard.canonicalStateDigest());
    _ = try restored.apply(original_fill);
    try std.testing.expectEqualSlices(u8, &economics, &restored.shard.economic_projection.semanticDigest());
    try std.testing.expectError(error.NotSent, cycle.harness.gateway.sendFromShard(&restored.shard, uncertain.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(sends, cycle.simulator.sends);
    std.debug.print("continuous mixed seed=0x{x} live={d} terminal={d} ledger={d} fills={d} sends={d} unknown_zero_resend=true\n", .{ seed, restored.shard.oms.liveOrderCount(), restored.shard.oms.retainedTerminalOrderCount(), restored.shard.economic_projection.ledger_count, restored.shard.economic_projection.applied_fill_count, sends });
}
