//! Resident order capacity through Owner, Gateway and canonical adapter ingress.
const std = @import("std");
const acceptance = @import("../history/order_gateway_archive_acceptance.zig");
const canonical = @import("../../../model/canonical_event.zig");
const trading = @import("../../../trading/trading_shard.zig");
const fixture = @import("../../support/trading_shard_fixture.zig");
const history = @import("../../../persistence/business_history.zig");
const venue = @import("../../../execution/venue_adapter.zig");
const demo = @import("../../../runtime/demo/demo_authority.zig");
const execution = @import("../../../execution/execution_gateway.zig");

fn verifyRecoveredCapacity(cycle: *Cycle) !void {
    const allocator = std.testing.allocator;
    try cycle.harness.owner.checkpointWithScratch(cycle.checkpoint_scratch);
    try cycle.harness.gateway.checkpointDurableDispatch();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.recoverInto(owner, cycle.harness.backend.interface(), undefined, cycle.harness.stream);
    try std.testing.expectEqualSlices(u8, &cycle.harness.owner.shard.canonicalStateDigest(), &owner.shard.canonicalStateDigest());
    try std.testing.expectEqual(cycle.harness.owner.shard.oms.next_order_id, owner.shard.oms.next_order_id);
    const gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(gateway);
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
}

const Cycle = struct {
    harness: *acceptance.ArchiveHarness,
    checkpoint_scratch: []u8,
    simulator: acceptance.RestingSimulator = .{},
    next_intent: u64 = 101,
    next_reconciliation: u64 = 3,
    operations_since_checkpoint: u8 = 0,

    fn create(allocator: std.mem.Allocator, stream: u64) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        const checkpoint_scratch = try allocator.alloc(u8, @import("../../../persistence/durable_store.zig").max_snapshot_bytes);
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
        if (self.operations_since_checkpoint < 4) return;
        try self.harness.owner.checkpointWithScratch(self.checkpoint_scratch);
        try self.harness.gateway.checkpointDurableDispatch();
        self.operations_since_checkpoint = 0;
    }

    fn submit(self: *@This(), intent: trading.oms.Intent) !trading.oms.Command {
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
        try self.harness.owner.applyAdapterBatch((try self.simulator.adapter().tryDrain()).?);
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

fn verifyArchivedGroupRecovery(cycle: *Cycle, original: trading.oms.IntentGroup, dispatches: []const execution.DispatchEvidence) !void {
    const allocator = std.testing.allocator;
    const sends = cycle.simulator.sends;
    try cycle.harness.owner.checkpointWithScratch(cycle.checkpoint_scratch);
    try cycle.harness.gateway.checkpointDurableDispatch();
    const owner = try allocator.create(demo.Owner);
    defer allocator.destroy(owner);
    try demo.Owner.recoverInto(owner, cycle.harness.backend.interface(), undefined, cycle.harness.stream);
    try std.testing.expectEqualSlices(u8, &cycle.harness.owner.shard.canonicalStateDigest(), &owner.shard.canonicalStateDigest());
    const gateway = try allocator.create(execution.Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.add(cycle.harness.route);
    try gateway.attachRecoveredDurableDispatch(cycle.harness.backend.interface(), undefined, cycle.harness.dispatch_stream);
    try std.testing.expectEqual(@as(u16, 0), owner.shard.oms.order_count);
    try std.testing.expectEqual(@as(u16, 0), gateway.accepted_dispatch_count);
    try std.testing.expectEqual(@as(u16, 0), gateway.uncertain_dispatch_count);
    const next_order = owner.shard.oms.next_order_id;
    const next_command = owner.shard.oms.next_command_id;
    const economics = owner.shard.economic_projection.semanticDigest();
    const root = owner.shard.business_history_root.?;
    for (dispatches) |dispatch| {
        var encoded: [history.max_record_bytes]u8 = undefined;
        const request: history.LookupRequest = .{
            .pending_id = dispatch.proof.command.command_id,
            .key = .{ .origin = root.origin, .identity = .{ .dispatch_command = dispatch.proof.command.command_id } },
            .candidate_payload_digest = history.hash(try @import("../../../persistence/snapshot_codec.zig").encodeBare(&encoded, dispatch)),
            .original_input_digest = history.hash("recovered grouped dispatch retry"),
            .root_digest = root.root_digest,
            .epoch = root.epoch,
            .barrier = root.barrier,
        };
        const result = try cycle.harness.backend.interface().queryOrderHistory(undefined, request);
        for (0..2) |_| try std.testing.expectEqual(venue.SendResult.accepted, try gateway.retryArchivedDispatch(&owner.shard, request, &result));
    }
    try std.testing.expectEqual(sends, cycle.simulator.sends);
    _ = try owner.apply(fixture.atGroup(5000, .{ .identity = 5000, .payload = .{ .oms_intent_group = original } }));
    try std.testing.expect(owner.shard.pending_history_candidate == null);
    try std.testing.expect(!owner.shard.history_conflict_latched);
    var conflict = original;
    conflict.members[0].quantity += 1;
    _ = try owner.apply(fixture.atGroup(5001, .{ .identity = 5001, .payload = .{ .oms_intent_group = conflict } }));
    try std.testing.expect(owner.shard.history_conflict_latched and owner.shard.oms.recovery_only);
    try std.testing.expect(!owner.shard.operational_state.effectiveTradingAuthority());
    try std.testing.expectEqual(next_order, owner.shard.oms.next_order_id);
    try std.testing.expectEqual(next_command, owner.shard.oms.next_command_id);
    try std.testing.expectEqualSlices(u8, &economics, &owner.shard.economic_projection.semanticDigest());
    for (dispatches) |dispatch| try std.testing.expectError(error.NotSent, gateway.sendFromShard(&owner.shard, dispatch.proof.command.command_id, cycle.simulator.receive_monotonic_ns));
    try std.testing.expectEqual(sends, cycle.simulator.sends);
}

test "Owner public archive closes true CCC successor before predecessor and cold identities recover without resend" {
    const allocator = std.testing.allocator;
    const cycle = try Cycle.create(allocator, 1194);
    defer cycle.destroy(allocator);
    const predecessor = try cycle.place();
    const original_place = cycle.harness.owner.shard.oms.command_history[0];
    _ = try cycle.submit(.{ .intent_sequence = 0, .operation = .amend, .instrument = 3, .target_order_id = predecessor, .expected_revision = 1, .expected_cumulative_quantity = 0, .quantity = 10, .limit_price = fixture.omsPrice(3, 50_000_000), .native_amend = false, .allow_cancel_confirm_create = true });
    const successor_command = for (cycle.harness.owner.shard.oms.command_history[0..cycle.harness.owner.shard.oms.command_history_count]) |command| {
        if (command.operation == .place and command.predecessor_order_id == predecessor) break command;
    } else return error.MissingCccSuccessor;
    try std.testing.expect(successor_command.order_id != predecessor);
    try std.testing.expect(successor_command.command_id > original_place.command_id);
    try std.testing.expectEqual(@as(i64, 10), successor_command.quantity);
    try std.testing.expectEqual(trading.oms.OrderState.canceled, cycle.harness.owner.shard.oms.orderById(predecessor).?.state);
    try std.testing.expectEqual(venue.SendResult.accepted, try cycle.harness.owner.send(cycle.harness.gateway, &cycle.harness.guard, successor_command.command_id, cycle.simulator.receive_monotonic_ns));
    try cycle.harness.owner.applyAdapterBatch((try cycle.simulator.adapter().tryDrain()).?);
    try std.testing.expectEqual(trading.oms.OrderState.live, cycle.harness.owner.shard.oms.orderById(successor_command.order_id).?.state);
    const first_client = cycle.harness.gateway.acceptedClientOrderIdFromShard(&cycle.harness.owner.shard, original_place.command_id).?;
    const successor_client = cycle.harness.gateway.acceptedClientOrderIdFromShard(&cycle.harness.owner.shard, successor_command.command_id).?;
    try std.testing.expect(!std.meta.eql(first_client, successor_client));
    try cycle.coverTerminal(predecessor, original_place.revision);
    try cycle.terminal(successor_command.order_id);
    try std.testing.expectEqual(@as(u64, 4), cycle.simulator.sends);
    try std.testing.expectError(error.OrderArchiveReferenced, cycle.harness.owner.archiveTerminalOrder(predecessor, cycle.harness.gateway));
    try std.testing.expect(cycle.harness.owner.shard.oms.orderById(predecessor) != null);
    try std.testing.expect(cycle.harness.owner.shard.oms.orderById(successor_command.order_id) != null);
    var dispatches: [4]execution.DispatchEvidence = undefined;
    try std.testing.expectEqual(@as(usize, 2), (try cycle.harness.gateway.exportOrderDispatchEvidence(&cycle.harness.owner.shard, successor_command.order_id, dispatches[0..2])).len);
    try cycle.archive(successor_command.order_id);
    try std.testing.expect(cycle.harness.owner.shard.oms.orderById(predecessor) != null);
    try std.testing.expectEqual(@as(usize, 2), (try cycle.harness.gateway.exportOrderDispatchEvidence(&cycle.harness.owner.shard, predecessor, dispatches[2..4])).len);
    try cycle.archive(predecessor);
    var original: trading.oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 1 };
    original.members[0] = .{ .intent_sequence = 101, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    try verifyArchivedGroupRecovery(cycle, original, &dispatches);
}

test "Owner public archive retains shared multi member group until final member and cold identities recover without resend" {
    const allocator = std.testing.allocator;
    const cycle = try Cycle.create(allocator, 1196);
    defer cycle.destroy(allocator);
    var book = fixture.snapshotAt(101, cycle.next_reconciliation);
    cycle.next_reconciliation += 1;
    book.venue.envelope.identity.stream = 7;
    book.venue.envelope.source_stream = 7;
    book.venue.envelope.raw_evidence.stream = 7;
    _ = try cycle.harness.owner.apply(book);
    var group: trading.oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 2 };
    for (group.members[0..2], 0..) |*member, index| member.* = .{
        .intent_sequence = 101 + index,
        .operation = .place,
        .instrument = 3,
        .quantity = 20,
        .limit_price = fixture.omsPrice(3, 50_000_000),
    };
    const input = fixture.atGroup(101, .{ .identity = 101, .payload = .{ .oms_intent_group = group } });
    const dispatch_time = input.core.monotonic_time + std.time.ns_per_ms;
    try cycle.harness.authority.renew(&cycle.harness.lease, dispatch_time);
    cycle.simulator.receive_monotonic_ns = dispatch_time;
    cycle.simulator.receive_utc_ns = input.core.receive_time + std.time.ns_per_ms;
    _ = try cycle.harness.owner.apply(input);
    try std.testing.expectEqual(@as(usize, 2), cycle.harness.owner.shard.oms.emitted().len);
    var commands: [2]trading.oms.Command = undefined;
    @memcpy(&commands, cycle.harness.owner.shard.oms.emitted());
    for (commands) |command| {
        try std.testing.expectEqual(venue.SendResult.accepted, try cycle.harness.owner.send(cycle.harness.gateway, &cycle.harness.guard, command.command_id, dispatch_time));
        try cycle.harness.owner.applyAdapterBatch((try cycle.simulator.adapter().tryDrain()).?);
        try std.testing.expectEqual(trading.oms.OrderState.live, cycle.harness.owner.shard.oms.orderById(command.order_id).?.state);
    }
    try std.testing.expect(commands[0].order_id != commands[1].order_id);
    try std.testing.expect(commands[0].command_id != commands[1].command_id);
    try std.testing.expect(!std.meta.eql(
        cycle.harness.gateway.acceptedClientOrderIdFromShard(&cycle.harness.owner.shard, commands[0].command_id).?,
        cycle.harness.gateway.acceptedClientOrderIdFromShard(&cycle.harness.owner.shard, commands[1].command_id).?,
    ));
    cycle.next_intent = 103;
    try cycle.terminal(commands[0].order_id);
    try std.testing.expectError(error.OrderArchiveReferenced, cycle.harness.owner.archiveTerminalOrder(commands[0].order_id, cycle.harness.gateway));
    try std.testing.expectEqual(@as(u16, 2), cycle.harness.owner.shard.oms.order_count);
    try cycle.terminal(commands[1].order_id);
    try std.testing.expectEqual(@as(u64, 4), cycle.simulator.sends);
    var dispatches: [4]execution.DispatchEvidence = undefined;
    for (commands, 0..) |command, index| try std.testing.expectEqual(@as(usize, 2), (try cycle.harness.gateway.exportOrderDispatchEvidence(&cycle.harness.owner.shard, command.order_id, dispatches[index * 2 ..][0..2])).len);
    try cycle.archive(commands[0].order_id);
    for (group.members[0..2]) |member| {
        var retained = false;
        for (cycle.harness.owner.shard.oms.intent_history[0..cycle.harness.owner.shard.oms.intent_history_count]) |known| {
            if (known.intent_sequence == member.intent_sequence and known.group == group.first_intent_sequence) retained = true;
        }
        try std.testing.expect(retained);
    }
    try cycle.archive(commands[1].order_id);
    try std.testing.expectEqual(@as(u16, 0), cycle.harness.owner.shard.oms.intent_history_count);
    try verifyArchivedGroupRecovery(cycle, group, &dispatches);
}

fn runMatrix(comptime shard_count: usize, terminal_count: usize, live_count: usize, round_count: usize, retire_per_round: usize) !void {
    const allocator = std.testing.allocator;
    var cycles: [shard_count]*Cycle = undefined;
    var created: usize = 0;
    defer for (cycles[0..created]) |cycle| cycle.destroy(allocator);
    for (&cycles, 0..) |*slot, index| {
        slot.* = try Cycle.create(allocator, 1100 + 2 * index);
        created += 1;
    }
    for (cycles) |cycle| {
        for (0..terminal_count) |completed| {
            try cycle.terminal(try cycle.place());
            if ((completed + 1) % 512 == 0) std.debug.print("Owner capacity stream {d}: seeded_terminal={d}\n", .{ cycle.harness.stream.id, completed + 1 });
        }
        for (0..live_count) |live| {
            _ = try cycle.place();
            if ((live + 1) % 256 == 0) std.debug.print("Owner capacity stream {d}: seeded_live={d}\n", .{ cycle.harness.stream.id, live + 1 });
        }
    }
    for (cycles, 0..) |cycle, index| {
        try std.testing.expectEqual(terminal_count, cycle.harness.owner.shard.oms.retainedTerminalOrderCount());
        try std.testing.expectEqual(live_count, cycle.harness.owner.shard.oms.liveOrderCount());
        std.debug.print("Owner capacity shard {d}: live={d}, terminal={d}, adapter_sends={d}\n", .{ index, live_count, terminal_count, cycle.simulator.sends });
    }
    for (cycles, 0..) |cycle, index| {
        for (1..terminal_count + 1) |order_id| {
            try cycle.archive(order_id);
            if (order_id % 512 == 0 or order_id == terminal_count) {
                const memory = &cycle.harness.backend.memory;
                std.debug.print("Owner capacity shard {d}: archived_terminal={d} journal_bytes={d} history_bytes={d} quota={d}\n", .{ index, order_id, memory.archive_bytes, memory.history_objects.items.len, memory.archive_quota });
            }
        }
    }
    for (0..round_count) |round| {
        for (cycles) |cycle| {
            var retired: [64]u64 = undefined;
            if (retire_per_round > retired.len) return error.InvalidCapacityFixture;
            for (retired[0..retire_per_round], 0..) |*id, index| id.* = cycle.harness.owner.shard.oms.orders[index].id;
            for (retired[0..retire_per_round]) |id| try cycle.terminal(id);
            for (retired[0..retire_per_round]) |id| try cycle.archive(id);
            for (0..retire_per_round) |_| _ = try cycle.place();
            try std.testing.expectEqual(live_count, cycle.harness.owner.shard.oms.liveOrderCount());
            try std.testing.expectEqual(@as(u16, 0), cycle.harness.owner.shard.oms.retainedTerminalOrderCount());
        }
        std.debug.print("Owner capacity all {d} shards: round={d}, live_each={d}, cumulative_terminal_each={d}\n", .{ shard_count, round + 1, live_count, terminal_count + (round + 1) * retire_per_round });
    }
    for (cycles) |cycle| try @call(.never_inline, verifyRecoveredCapacity, .{cycle});
}

test "Owner public capacity fixture preserves two order identities through archive and replacement" {
    try runMatrix(1, 2, 2, 2, 1);
}

test "Owner archive compaction preserves the surviving order observation times" {
    const allocator = std.testing.allocator;
    const cycle = try Cycle.create(allocator, 1190);
    defer cycle.destroy(allocator);
    const first = try cycle.place();
    const survivor = try cycle.place();
    const created_at = cycle.harness.owner.shard.oms.orderById(survivor).?.created_at_utc_ns;
    try std.testing.expect(created_at != 0);
    try cycle.terminal(first);
    try cycle.archive(first);
    try std.testing.expectEqual(survivor, cycle.harness.owner.shard.oms.orders[0].id);
    try cycle.terminal(survivor);
    const terminal = cycle.harness.owner.shard.oms.orderById(survivor).?;
    try std.testing.expectEqual(created_at, terminal.created_at_utc_ns);
    try std.testing.expect(terminal.terminal_observed_at_utc_ns >= created_at);
    const observed_at = terminal.terminal_observed_at_utc_ns;
    _ = try cycle.place();
    try std.testing.expectEqual(observed_at, cycle.harness.owner.shard.oms.orderById(survivor).?.terminal_observed_at_utc_ns);
    try cycle.archive(survivor);
}

test "Owner public archive four shards retain 25 live and 25 terminal through ten replacement rounds" {
    runMatrix(4, 25, 25, 10, 5) catch |err| {
        std.debug.print("Owner archive failed: {s}\n", .{@errorName(err)});
        return err;
    };
}

test "Owner public capacity cycles active authority through checkpoints and cold lookup" {
    try runMatrix(1, 16, 32, 2, 4);
}

test "Owner sends protective cancel while an unrelated archived intent lookup is deferred" {
    const allocator = std.testing.allocator;
    const cycle = try Cycle.create(allocator, 1184);
    defer cycle.destroy(allocator);
    const old_order = try cycle.place();
    try cycle.terminal(old_order);
    try cycle.archive(old_order);
    const live_order = try cycle.place();
    cycle.harness.backend.timeout_intent_sequence = 101;
    var duplicate: trading.oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 1 };
    duplicate.members[0] = .{ .intent_sequence = 101, .operation = .place, .instrument = 3, .quantity = 20, .limit_price = fixture.omsPrice(3, 50_000_000) };
    try std.testing.expectError(error.HistoryLookupDeferred, cycle.harness.owner.apply(fixture.atGroup(cycle.next_intent, .{ .identity = 800, .payload = .{ .oms_intent_group = duplicate } })));
    const pending = cycle.harness.owner.shard.pending_history_candidate.?;
    const sends = cycle.simulator.sends;
    try cycle.terminal(live_order);
    try std.testing.expectEqual(sends + 1, cycle.simulator.sends);
    try std.testing.expectEqualDeep(pending, cycle.harness.owner.shard.pending_history_candidate.?);
    try std.testing.expect(cycle.harness.owner.shard.pending_safety_history_candidate == null);
    try std.testing.expectEqual(trading.oms.OrderState.canceled, cycle.harness.owner.shard.oms.orderById(live_order).?.state);
    try std.testing.expect(!cycle.harness.owner.closed);
    cycle.harness.backend.timeout_intent_sequence = null;
    _ = try cycle.harness.owner.resolveColdCandidate();
    try std.testing.expect(cycle.harness.owner.shard.pending_history_candidate == null);
    try std.testing.expectEqual(sends + 1, cycle.simulator.sends);
}

test "Owner completes interrupted predecessor archive before committing another order" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }, 0..) |fail_preflight, case| {
        const cycle = try Cycle.create(allocator, 1190 + 2 * case);
        defer cycle.destroy(allocator);
        const first = try cycle.place();
        try cycle.terminal(first);
        const second = try cycle.place();
        try cycle.terminal(second);
        const sends = cycle.simulator.sends;
        cycle.harness.backend.stage = .gateway_append;
        try std.testing.expectError(error.InjectedEio, cycle.harness.owner.archiveTerminalOrder(first, cycle.harness.gateway));
        const first_root = cycle.harness.owner.shard.business_history_root.?;
        try std.testing.expect(cycle.harness.owner.shard.oms.orderById(first) == null);
        // A fresh process uses the persisted backend with a fresh fault gate.
        cycle.harness.backend.closed = false;
        cycle.harness.backend.stage = .none;
        const store = cycle.harness.backend.interface();
        const owner = try allocator.create(demo.Owner);
        defer allocator.destroy(owner);
        try demo.Owner.recoverInto(owner, store, undefined, cycle.harness.stream);
        const gateway = try allocator.create(execution.Gateway);
        defer allocator.destroy(gateway);
        gateway.init();
        try gateway.add(cycle.harness.route);
        try gateway.attachRecoveredDurableDispatch(store, undefined, cycle.harness.dispatch_stream);
        try std.testing.expect(owner.shard.oms.orderById(second) != null);
        const before = owner.shard.authoritativeBarrier();
        if (fail_preflight) {
            cycle.harness.backend.stage = .gateway_append;
            try std.testing.expectError(error.InjectedEio, owner.archiveTerminalOrder(second, gateway));
            try std.testing.expect(owner.closed);
            try std.testing.expectEqual(before, owner.shard.authoritativeBarrier());
            try std.testing.expectEqualDeep(first_root, owner.shard.business_history_root.?);
            try std.testing.expectEqual(first, owner.shard.last_order_archive.?.order_id);
            try std.testing.expect(owner.shard.oms.orderById(second) != null);
        } else {
            const second_root = try owner.archiveTerminalOrder(second, gateway);
            try std.testing.expectEqualSlices(u8, &first_root.root_digest, &second_root.previous_root);
            try std.testing.expect(owner.shard.oms.orderById(second) == null);
            try std.testing.expectEqual(@as(u16, 0), gateway.accepted_dispatch_count);
            try std.testing.expectEqual(@as(u16, 0), gateway.uncertain_dispatch_count);
            const recovered = try allocator.create(demo.Owner);
            defer allocator.destroy(recovered);
            try demo.Owner.recoverInto(recovered, store, undefined, cycle.harness.stream);
            try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        }
        try std.testing.expectEqual(sends, cycle.simulator.sends);
    }
}
