//! Pure single-order archive builder. Ownership stays with the returned buffer.
const std = @import("std");
const trading = @import("trading_shard.zig");
const oms = @import("oms.zig");
const history = @import("business_history.zig");
const codec = @import("snapshot_codec.zig");
const durable = @import("durable_store.zig");

pub const max_batch_bytes = 128 * 1024;
pub const GroupRecord = struct {
    version: u16 = 1,
    strategy: u128,
    first_sequence: u64,
    count: u8,
    members: [oms.max_group_members]oms.SeenIntent,
};
pub const RecordSpan = struct { offset: u32, length: u32, payload_digest: history.Digest };
pub const Builder = struct {
    origin: history.Origin,
    qualification: oms.OrderArchiveQualification,
    bytes: [max_batch_bytes]u8 = undefined,
    byte_count: u32 = 0,
    spans: [history.max_batch_keys]RecordSpan = undefined,
    entries: [history.max_batch_keys]history.Entry = undefined,
    count: u16 = 0,
    record_count: u16 = 0,

    /// Owner may append trusted Gateway evidence before publishing this batch.
    pub fn add(self: *Builder, identity: history.Identity, value: anytype) !void {
        const key: history.Key = .{ .origin = self.origin, .identity = identity };
        if (self.byte_count >= self.bytes.len) return error.OrderHistoryBatchCapacity;
        const end = @min(self.bytes.len, @as(usize, self.byte_count) + history.max_record_bytes);
        const encoded = codec.encodeBare(self.bytes[self.byte_count..end], value) catch return error.OrderHistoryBatchCapacity;
        const digest = history.hash(encoded);
        for (self.entries[0..self.count]) |entry| {
            if (std.meta.eql(entry.key, key)) {
                const known = self.spans[entry.record_index];
                if (known.length != encoded.len or !std.mem.eql(u8, &known.payload_digest, &digest) or
                    !std.mem.eql(u8, self.bytes[known.offset..][0..known.length], encoded))
                    return error.ConflictingOrderHistoryRecord;
                return;
            }
        }
        if (self.count == history.max_batch_keys) return error.OrderHistoryBatchCapacity;
        for (self.spans[0..self.record_count], 0..) |span, index| {
            if (span.length == encoded.len and std.mem.eql(u8, &span.payload_digest, &digest) and
                std.mem.eql(u8, self.bytes[span.offset..][0..span.length], encoded))
            {
                self.entries[self.count] = .{ .key = key, .record_index = @intCast(index) };
                self.count += 1;
                return;
            }
        }
        self.spans[self.record_count] = .{ .offset = self.byte_count, .length = @intCast(encoded.len), .payload_digest = digest };
        self.entries[self.count] = .{ .key = key, .record_index = self.record_count };
        self.byte_count += @intCast(encoded.len);
        self.record_count += 1;
        self.count += 1;
    }

    pub fn batch(self: *const Builder, previous_root: ?history.Root, barrier: u64, epoch: u64) !BatchView {
        if (barrier == 0 or epoch == 0) return error.InvalidHistoryBatch;
        if (previous_root) |previous| {
            try history.validateRoot(previous);
            if (!std.meta.eql(previous.origin, self.origin) or barrier < previous.barrier or epoch < previous.epoch or previous.retired)
                return error.StaleHistoryRoot;
        }
        var result: BatchView = .{
            .origin = self.origin,
            .previous_root = previous_root,
            .barrier = barrier,
            .epoch = epoch,
            .qualification_digest = self.qualification.digest(),
            .entries = self.entries[0..self.count],
            .count = self.record_count,
        };
        for (self.spans[0..self.record_count], 0..) |span, index| result.records[index] = .{
            .bytes = self.bytes[span.offset..][0..span.length],
            .payload_digest = span.payload_digest,
        };
        return result;
    }
};

pub fn build(shard: *const trading.TradingShard, order_id: u64, origin: history.Origin) !Builder {
    if (shard.hasDeferredOrderHistory(order_id)) return error.OrderArchivePinned;
    for (shard.economic_projection.applied_fills[0..shard.economic_projection.applied_fill_count]) |fill| if (fill.fill.order_id == order_id) return error.OrderArchivePinned;
    const checkpoint = shard.checkpoint orelse return error.InvalidOrderHistoryOrigin;
    if (origin.stream.domain != .decision_log or origin.stream.id == 0 or origin.account == 0 or
        origin.account != shard.exchange_account_identity or checkpoint.stream != origin.stream.id)
        return error.InvalidOrderHistoryOrigin;
    const applied_fill = try shard.economic_projection.appliedCanonicalFillQuantity(order_id);
    const qualification = try shard.oms.prepareOrderArchive(order_id, applied_fill, origin.account);
    // Derive the release set through the public OMS operation, so retaining
    // another member's references cannot silently diverge from this builder.
    var released = shard.oms;
    try released.commitOrderArchive(qualification);
    var result: Builder = .{ .origin = origin, .qualification = qualification };
    try result.add(.{ .order = order_id }, qualification);
    for (shard.oms.command_history[0..shard.oms.command_history_count]) |command| {
        if (command.order_id == order_id) try result.add(.{ .command = command.command_id }, command);
    }
    for (shard.oms.commands[0..shard.oms.command_count]) |command| {
        if (command.order_id == order_id) try result.add(.{ .command = command.command_id }, command);
    }
    for (shard.oms.command_history[0..shard.oms.command_history_count]) |command| {
        if (command.order_id != order_id) continue;
        for (shard.dispatch_ingress_history[0..shard.dispatch_ingress_history_count]) |entry| {
            if (command.command_id == entry.body.command) try result.add(.{ .dispatch_result = .{ .command = entry.body.command, .state = entry.body.state } }, entry.body);
        }
    }
    for (shard.oms.report_history[0..shard.oms.report_history_count]) |report| {
        if (report.order_id == order_id) try result.add(.{ .report = report.report_id }, report);
    }
    for (shard.oms.reconciliation_history[0..shard.oms.reconciliation_history_count]) |reconciliation| {
        if (reconciliation.order_id == order_id) try result.add(.{ .reconciliation = reconciliation.reconciliation_id }, reconciliation);
    }
    for (shard.oms.tombstones[0..shard.oms.tombstone_count]) |tombstone| {
        // A hot qualification cannot also replace a different tombstone body.
        if (tombstone.order_id == order_id) return error.UnexpectedOrderArchiveTombstone;
    }
    // OMS deletes without reordering, so retained identities form a subsequence.
    var retained_index: usize = 0;
    for (shard.oms.intent_history[0..shard.oms.intent_history_count]) |intent| {
        if (retained_index < released.intent_history_count) {
            const retained = released.intent_history[retained_index];
            if (retained.strategy_instance == intent.strategy_instance and retained.intent_sequence == intent.intent_sequence) {
                retained_index += 1;
                continue;
            }
        }
        try result.add(.{ .intent = .{ .strategy = intent.strategy_instance, .sequence = intent.intent_sequence } }, intent);
        var group: GroupRecord = .{
            .strategy = intent.strategy_instance,
            .first_sequence = intent.group,
            .count = 0,
            .members = std.mem.zeroes([oms.max_group_members]oms.SeenIntent),
        };
        for (shard.oms.intent_history[0..shard.oms.intent_history_count]) |member| {
            if (member.strategy_instance != intent.strategy_instance or member.group != intent.group) continue;
            // Partial deletion cannot publish a changing body under one stable
            // group key. Keep the whole order hot until that group can close.
            if (containsIntent(&released, member)) return error.SharedOrderHistoryGroup;
            if (group.count == group.members.len) return error.OrderHistoryBatchCapacity;
            group.members[group.count] = member;
            group.count += 1;
        }
        std.mem.sort(oms.SeenIntent, group.members[0..group.count], {}, struct {
            fn less(_: void, a: oms.SeenIntent, b: oms.SeenIntent) bool {
                return a.intent_sequence < b.intent_sequence;
            }
        }.less);
        try result.add(.{ .group = .{ .strategy = group.strategy, .first_sequence = group.first_sequence } }, group);
    }
    return result;
}

fn containsIntent(state: *const oms.Oms, intent: oms.SeenIntent) bool {
    for (state.intent_history[0..state.intent_history_count]) |known| {
        if (known.strategy_instance == intent.strategy_instance and known.intent_sequence == intent.intent_sequence) return true;
    }
    return false;
}

test "order history batch releases only the ordered difference across interleaved strategy identities" {
    const allocator = std.testing.allocator;
    const shard = try allocator.create(trading.TradingShard);
    defer allocator.destroy(shard);
    shard.* = .{};
    shard.exchange_account_identity = 9;
    const inputs = [_]struct { strategy: u128, sequence: u64, cancel: bool = false }{
        .{ .strategy = 9, .sequence = 7 },
        .{ .strategy = 5, .sequence = 7 },
        .{ .strategy = 9, .sequence = 8 },
        .{ .strategy = 5, .sequence = 8, .cancel = true },
        .{ .strategy = 5, .sequence = 9 },
    };
    for (inputs) |input| {
        shard.oms.begin();
        var group: oms.IntentGroup = .{ .first_intent_sequence = input.sequence, .count = 1 };
        group.members[0] = .{
            .intent_sequence = input.sequence,
            .strategy_instance = input.strategy,
            .operation = if (input.cancel) .cancel else .place,
            .target_order_id = 2,
            .expected_revision = 1,
            .expected_cumulative_quantity = 0,
            .instrument = 1,
            .quantity = 2,
            .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 },
            .reservation = .{ .asset = 1, .atoms = 6 },
        };
        try shard.oms.applyGroup(group);
        var dispatch: oms.DispatchBatch = .{ .count = 1 };
        dispatch.items[0] = .{ .command_id = shard.oms.emitted()[0].command_id, .state = .submitted };
        try shard.oms.applyDispatch(dispatch);
        if (!input.cancel) {
            const order_id = shard.oms.emitted()[0].order_id;
            try shard.oms.applyReport(.{ .report_id = order_id, .order_id = order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 2 });
        } else try testTerminal(shard, 2, 10);
    }
    try shard.trace.append(.recovery_completed, 1);
    shard.checkpoint = try shard.checkpointReceipt(906, 1, history.hash("interleaved retained archive"));
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 906 }, .account = 9 };
    const builder = try build(shard, 2, origin);
    const view = try builder.batch(null, 20, 1);
    var intent_count: usize = 0;
    var group_count: usize = 0;
    for (view.entries) |entry| switch (entry.key.identity) {
        .intent => |identity| {
            try std.testing.expectEqual(@as(u128, 5), identity.strategy);
            try std.testing.expectEqual(@as(u64, 7 + intent_count), identity.sequence);
            const intent = try codec.decodeBare(view.records[entry.record_index].bytes, oms.SeenIntent);
            try std.testing.expectEqual(identity.strategy, intent.strategy_instance);
            try std.testing.expectEqual(identity.sequence, intent.intent_sequence);
            intent_count += 1;
        },
        .group => |identity| {
            const group = try codec.decodeBare(view.records[entry.record_index].bytes, GroupRecord);
            try std.testing.expectEqual(@as(u128, 5), identity.strategy);
            try std.testing.expectEqual(@as(u64, 7 + group_count), identity.first_sequence);
            try std.testing.expectEqual(@as(u8, 1), group.count);
            try std.testing.expectEqual(identity.first_sequence, group.members[0].intent_sequence);
            group_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), intent_count);
    try std.testing.expectEqual(@as(usize, 2), group_count);
    try std.testing.expectEqual(@as(u16, inputs.len), shard.oms.intent_history_count);
    for (shard.oms.intent_history[0..shard.oms.intent_history_count], inputs) |intent, input| {
        try std.testing.expectEqual(input.strategy, intent.strategy_instance);
        try std.testing.expectEqual(input.sequence, intent.intent_sequence);
    }
}

// The records borrow Builder storage, never this movable view's own fields.
// Keep Builder alive and stationary until the peripheral Store call returns.
pub const BatchView = struct {
    origin: history.Origin,
    previous_root: ?history.Root,
    barrier: u64,
    epoch: u64,
    qualification_digest: history.Digest,
    entries: []const history.Entry,
    records: [history.max_batch_keys]history.Record = undefined,
    count: u16,

    pub fn value(self: *const BatchView) history.Batch {
        return .{
            .origin = self.origin,
            .previous_root = self.previous_root,
            .barrier = self.barrier,
            .epoch = self.epoch,
            .floor = if (self.previous_root) |root| root.floor else 0,
            .qualification_digest = self.qualification_digest,
            .records = self.records[0..self.count],
            .entries = self.entries,
        };
    }
};

fn testTerminal(shard: *trading.TradingShard, order_id: u64, report_id: u64) !void {
    try shard.oms.applyReport(.{ .report_id = report_id, .order_id = order_id, .revision = 1, .status = .canceled, .cumulative_quantity = 0, .remaining_quantity = 2 });
    try shard.oms.applyReconciliation(.{ .reconciliation_id = report_id + 1, .order_id = order_id, .status = .found_terminal, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2, .terminal_state = .canceled });
    try shard.oms.noteOrderCreated(order_id, 100);
    try shard.oms.noteTerminalObserved(order_id, 200);
    try shard.oms.retainTerminalArchiveCoverage(order_id, .{
        .scope = .{ .exchange_account = 9, .instrument = 1, .order = order_id, .revision = 1, .from_utc_ns = 100, .through_utc_ns = 30_000_000_200 },
        .observed_at_utc_ns = 30_000_000_200,
        .source = .{ .stream = 1, .sequence = 1, .digest = @splat(1) },
        .terminal_archive = .{ .visibility_deadline_utc_ns = 30_000_000_200, .order_history_complete = true, .terminal_history_complete = true, .fills_complete = true, .economics_complete = true },
    });
}

fn testPlace(shard: *trading.TradingShard, count: u8, stream_id: u64) !void {
    shard.exchange_account_identity = 9;
    var group: oms.IntentGroup = .{ .first_intent_sequence = 7, .count = count };
    for (group.members[0..count], 0..) |*intent, index| intent.* = .{
        .intent_sequence = 7 + @as(u64, @intCast(index)),
        .strategy_instance = 5,
        .operation = .place,
        .instrument = 1,
        .quantity = 2,
        .limit_price = .{ .instrument = 1, .rules_version = 1, .ticks = 3 },
        .reservation = .{ .asset = 1, .atoms = 6 },
    };
    try shard.oms.applyGroup(group);
    var dispatch: oms.DispatchBatch = .{ .count = count };
    for (shard.oms.emitted(), 0..) |command, index| dispatch.items[index] = .{ .command_id = command.command_id, .state = .submitted };
    try shard.oms.applyDispatch(dispatch);
    try shard.trace.append(.recovery_completed, 1);
    shard.checkpoint = try shard.checkpointReceipt(stream_id, 1, history.hash("synthetic retained archive"));
}

test "order history batch owns relocated records and archives every released semantic identity" {
    const allocator = std.testing.allocator;
    const shard = try allocator.create(trading.TradingShard);
    defer allocator.destroy(shard);
    shard.* = .{};
    try testPlace(shard, 1, 901);
    try testTerminal(shard, 1, 10);
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 901 }, .account = 9 };
    const original_command = shard.oms.command_history[0];
    const original_intent = shard.oms.intent_history[0];
    var builder = try build(shard, 1, origin);
    const moved = builder;
    @memset(&builder.bytes, 0xff);
    const view = try moved.batch(null, 20, 1);
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const receipt = try memory.interface().publishOrderHistory(undefined, view.value());
    try std.testing.expectEqual(@as(u16, 6), moved.count);
    for (view.entries, 0..) |entry, index| {
        const request: history.LookupRequest = .{ .pending_id = index + 1, .key = entry.key, .candidate_payload_digest = view.records[entry.record_index].payload_digest, .original_input_digest = history.hash("original candidate"), .root_digest = receipt.root.root_digest, .epoch = 1, .barrier = 20 };
        const result = try memory.interface().queryOrderHistory(undefined, request);
        try std.testing.expectEqual(history.Verdict.same, try history.verifyResult(request, &result.proof, receipt.root));
        try history.validateRecord(&result);
        const bytes = result.record_bytes[0..result.record_len];
        switch (entry.key.identity) {
            .order => try std.testing.expectEqualDeep(moved.qualification, try codec.decodeBare(bytes, oms.OrderArchiveQualification)),
            .command => try std.testing.expectEqualDeep(original_command, try codec.decodeBare(bytes, oms.Command)),
            .intent => try std.testing.expectEqualDeep(original_intent, try codec.decodeBare(bytes, oms.SeenIntent)),
            .group => try std.testing.expectEqual(@as(u8, 1), (try codec.decodeBare(bytes, GroupRecord)).count),
            .report => try std.testing.expectEqualDeep(shard.oms.report_history[0], try codec.decodeBare(bytes, oms.ExecutionReport)),
            .reconciliation => try std.testing.expectEqualDeep(shard.oms.reconciliation_history[0], try codec.decodeBare(bytes, oms.ReconciliationResult)),
            .client_order_id, .dispatch_command, .dispatch_result => return error.UnexpectedClientOrderIdKey,
            .canonical_fill, .core_fill, .fill_detail, .fill_economic_digest => return error.UnexpectedFillHistoryKey,
        }
    }
    try std.testing.expectEqual(@as(u8, 1), shard.oms.order_count);
    try std.testing.expectEqual(@as(u8, 1), shard.oms.intent_history_count);
    // Owner appends a separate CID-keyed DTO without replacing Command bytes.
    var extended = moved;
    const Evidence = struct { command_id: u64, accepted: bool };
    const evidence: Evidence = .{ .command_id = original_command.command_id, .accepted = true };
    const cid: history.Identity = .{ .client_order_id = original_command.client_order_id };
    try extended.add(cid, evidence);
    try extended.add(cid, evidence);
    try std.testing.expectEqual(@as(u16, 7), extended.count);
    try std.testing.expectError(error.ConflictingOrderHistoryRecord, extended.add(cid, @as(Evidence, .{ .command_id = original_command.command_id, .accepted = false })));
    const extended_view = try extended.batch(receipt.root, 21, 1);
    const extended_receipt = try memory.interface().publishOrderHistory(undefined, extended_view.value());
    const cid_record = extended_view.records[6];
    const cid_request: history.LookupRequest = .{ .pending_id = 99, .key = .{ .origin = origin, .identity = cid }, .candidate_payload_digest = cid_record.payload_digest, .original_input_digest = history.hash("trusted appended evidence"), .root_digest = extended_receipt.root.root_digest, .epoch = 1, .barrier = 21 };
    const cid_result = try memory.interface().queryOrderHistory(undefined, cid_request);
    try std.testing.expectEqual(history.Verdict.same, try history.verifyResult(cid_request, &cid_result.proof, extended_receipt.root));
    try std.testing.expectEqualDeep(evidence, try codec.decodeBare(cid_result.record_bytes[0..cid_result.record_len], @TypeOf(evidence)));
}

test "order history batch keeps shared group members hot and archives the full final group" {
    const shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(shard);
    shard.* = .{};
    try testPlace(shard, 2, 902);
    try testTerminal(shard, 1, 10);
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 902 }, .account = 9 };
    try std.testing.expectError(error.OrderArchiveReferenced, build(shard, 1, origin));
    try testTerminal(shard, 2, 20);
    const first = try build(shard, 1, origin);
    for (first.entries[0..first.count]) |entry| switch (entry.key.identity) {
        .intent, .group => return error.SharedIntentArchivedPrematurely,
        else => {},
    };
    try shard.oms.commitOrderArchive(first.qualification);
    try std.testing.expectEqual(@as(u8, 2), shard.oms.intent_history_count);
    const second = try build(shard, 2, origin);
    try std.testing.expectEqual(@as(u16, 7), second.count);
    const view = try second.batch(null, 30, 1);
    var intents: usize = 0;
    var groups: usize = 0;
    for (view.entries) |entry| switch (entry.key.identity) {
        .intent => intents += 1,
        .group => {
            groups += 1;
            const group = try codec.decodeBare(view.records[entry.record_index].bytes, GroupRecord);
            try std.testing.expectEqual(@as(u8, 2), group.count);
            try std.testing.expectEqual(@as(u64, 7), group.members[0].intent_sequence);
            try std.testing.expectEqual(@as(u64, 8), group.members[1].intent_sequence);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), intents);
    try std.testing.expectEqual(@as(usize, 1), groups);
    try std.testing.expectEqual(@as(u8, 1), shard.oms.order_count);
    try std.testing.expectEqual(@as(u8, 2), shard.oms.intent_history_count);
}

test "order history batch refuses wrong owner incomplete fills and inconsistent command bodies" {
    const shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(shard);
    shard.* = .{};
    try testPlace(shard, 1, 903);
    try testTerminal(shard, 1, 10);
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 903 }, .account = 9 };
    var foreign = origin;
    foreign.account = 10;
    try std.testing.expectError(error.InvalidOrderHistoryOrigin, build(shard, 1, foreign));
    foreign = origin;
    foreign.stream.id += 1;
    try std.testing.expectError(error.InvalidOrderHistoryOrigin, build(shard, 1, foreign));
    shard.economic_projection.canonical_fill_evidence[0] = .{ .identity = 1, .order_id = 1, .quantity = 1, .digest = history.hash("retained fill") };
    shard.economic_projection.canonical_fill_evidence_count = 1;
    shard.economic_projection.applied_fill_totals[0] = .{ .order_id = 1, .quantity = 1 };
    shard.economic_projection.applied_fill_total_count = 1;
    try std.testing.expectError(error.OrderArchiveNotQualified, build(shard, 1, origin));
    try std.testing.expectEqual(@as(u8, 1), shard.economic_projection.canonical_fill_evidence_count);
    shard.economic_projection.canonical_fill_evidence_count = 0;
    shard.economic_projection.applied_fill_total_count = 0;
    shard.oms.commands[0].quantity += 1;
    try std.testing.expectError(error.ConflictingOrderHistoryRecord, build(shard, 1, origin));
    try std.testing.expectEqual(@as(u8, 1), shard.oms.order_count);
    try std.testing.expectEqual(@as(u8, 1), shard.oms.command_history_count);
}

test "order history batch refuses more than 256 primary keys without releasing evidence" {
    const shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(shard);
    shard.* = .{};
    try testPlace(shard, 1, 904);
    try testTerminal(shard, 1, 10);
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 904 }, .account = 9 };
    // A recovered order may retain many revisions and independent action groups.
    // Sixty-four revisions produce more than the bounded 256-key publication.
    for (0..64) |index| {
        var command = shard.oms.command_history[0];
        command.command_id = index + 1;
        command.intent_sequence = 7 + index;
        shard.oms.command_history[index] = command;
        shard.oms.intent_history[index] = .{ .strategy_instance = 5, .intent_sequence = 7 + index, .group = 7 + index, .policy = .independent, .fingerprint = @splat(@intCast(index)) };
        var report = shard.oms.report_history[0];
        if (index != 0) report.report_id = 100 + index;
        shard.oms.report_history[index] = report;
        var reconciliation = shard.oms.reconciliation_history[0];
        if (index != 0) reconciliation.reconciliation_id = 200 + index;
        shard.oms.reconciliation_history[index] = reconciliation;
    }
    shard.oms.command_history_count = 64;
    shard.oms.intent_history_count = 64;
    shard.oms.report_history_count = 64;
    shard.oms.reconciliation_history_count = 64;
    try std.testing.expectError(error.OrderHistoryBatchCapacity, build(shard, 1, origin));
    try std.testing.expectEqual(@as(u8, 1), shard.oms.order_count);
    try std.testing.expectEqual(@as(u8, 64), shard.oms.command_history_count);
    try std.testing.expectEqual(@as(u8, 64), shard.oms.intent_history_count);
    try std.testing.expectEqual(@as(u8, 64), shard.oms.report_history_count);
    try std.testing.expectEqual(@as(u8, 64), shard.oms.reconciliation_history_count);
}

test "order history batch rejects partial shared action group release under one stable group key" {
    const shard = try std.testing.allocator.create(trading.TradingShard);
    defer std.testing.allocator.destroy(shard);
    shard.* = .{};
    try testPlace(shard, 2, 905);
    try testTerminal(shard, 1, 10);
    try testTerminal(shard, 2, 20);
    // A shared action group can reference orders from different creation groups.
    // The second command still pins member 8 while member 7 would be removed.
    shard.oms.orders[1].group_first_sequence = 99;
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 905 }, .account = 9 };
    _ = try shard.oms.prepareOrderArchive(1, 0, 9);
    try std.testing.expectError(error.SharedOrderHistoryGroup, build(shard, 1, origin));
    try std.testing.expectEqual(@as(u8, 2), shard.oms.order_count);
    try std.testing.expectEqual(@as(u8, 2), shard.oms.intent_history_count);
    try std.testing.expectEqual(@as(u8, 2), shard.oms.command_history_count);
}

test "order history batch stores one dispatch body under command and CID identities" {
    var builder: Builder = .{ .origin = .{ .stream = .{ .domain = .decision_log, .id = 804 }, .account = 2 }, .qualification = undefined };
    const body = [_]u8{ 8, 11, 17, 31 };
    try builder.add(.{ .dispatch_command = 31 }, body);
    const client = try @import("canonical_event.zig").ClientOrderId.init("shared-command-cid");
    try builder.add(.{ .client_order_id = client }, body);
    try std.testing.expectEqual(@as(u16, 2), builder.count);
    try std.testing.expectEqual(@as(u16, 1), builder.record_count);
    try std.testing.expectEqual(builder.entries[0].record_index, builder.entries[1].record_index);
    const stored_bytes = builder.byte_count;
    try builder.add(.{ .dispatch_command = 31 }, body);
    try std.testing.expectEqual(@as(u16, 2), builder.count);
    try std.testing.expectEqual(stored_bytes, builder.byte_count);
    try std.testing.expectError(error.ConflictingOrderHistoryRecord, builder.add(.{ .dispatch_command = 31 }, [_]u8{ 8, 11, 17, 32 }));
    try std.testing.expectEqual(@as(u16, 2), builder.count);
}
