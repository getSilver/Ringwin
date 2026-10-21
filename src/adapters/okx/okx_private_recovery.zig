//! Rebuild private decoder state and submit only facts absent from the retained
//! committed decision inputs. Raw and canonical sequence spaces stay separate.
const std = @import("std");
const canonical = @import("../../model/canonical_event.zig");
const codec = @import("../../persistence/canonical_event_codec.zig");
const durable = @import("../../persistence/durable_store.zig");
const journal = @import("../../persistence/journal.zig");
const trading = @import("../../trading/trading_shard.zig");
const demo = @import("../../runtime/demo/demo_authority.zig");
const okx = @import("okx_venue_adapter.zig");
const private = @import("okx_private_reconciliation.zig");
const live = @import("../../runtime/demo/okx_live_chain.zig");
const raw = @import("../../persistence/raw_ingress.zig");
const market = @import("okx_public_market.zig");

const max_inputs = 1024;
pub const recovery_byte_budget = 2 * 1024 * 1024;
const Entry = struct {
    evidence: canonical.RawEvidenceRef,
    source_fact: u128,
    kind: canonical.EventType,
    scope: canonical.CanonicalEventScope,
    account: ?u128,
    instrument: ?u128,
    asset: ?canonical.AssetIdentity,
    payload: [32]u8,
};

fn privateFact(record: canonical.EventRecord) bool {
    if (std.mem.eql(u8, &record.envelope.raw_evidence.digest, &@as([32]u8, @splat(0)))) return false;
    return switch (record.event) {
        .account_reconciliation_result => |result| result.account_economics != null,
        .execution_report, .fill, .funding_settlement, .economic_fault, .account_bootstrap_snapshot, .account_observed, .venue_account_configuration_snapshot, .order_reconciliation_result => true,
        else => false,
    };
}

fn entryFor(record: canonical.EventRecord) !Entry {
    var buffer: [codec.max_encoded_len]u8 = undefined;
    const bytes = try codec.encodePayload(&buffer, record.event);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{
        .evidence = record.envelope.raw_evidence,
        .source_fact = record.envelope.source_fact_identity,
        .kind = canonical.eventType(record.event),
        .scope = record.envelope.scope,
        .account = record.envelope.exchange_account,
        .instrument = record.envelope.instrument,
        .asset = record.envelope.asset,
        .payload = digest,
    };
}

fn sameFact(a: Entry, b: Entry) bool {
    return a.evidence.stream == b.evidence.stream and a.evidence.sequence == b.evidence.sequence and a.source_fact == b.source_fact and
        a.kind == b.kind and a.scope == b.scope and a.account == b.account and
        a.instrument == b.instrument and a.asset == b.asset;
}

pub const CommittedInputs = struct {
    // ponytail: bounded linear index over retained journal inputs; compact
    // checkpoint/index only when retained history exceeds this verified bound.
    entries: [max_inputs]Entry = undefined,
    count: usize = 0,
    visited: [max_inputs]bool = @splat(false),
    streams: [16]canonical.EventIdentity = undefined,
    stream_count: usize = 0,
    next_sequence: u64 = 1,
    boundary: ?demo.PrivateRecoveryBoundary = null,
    private_seed: [demo.max_private_resume_bytes]u8 = undefined,
    resume_len: usize = 0,

    pub fn init(store: durable.Store, io: std.Io, decision_stream: durable.StreamIdentity) !CommittedInputs {
        if (decision_stream.domain != .decision_log or !store.supportsSegmentReplay() or store.safetyGate() != .open)
            return error.PrivateRecoveryHistoryUnavailable;
        const recovered = try store.recover(io, decision_stream);
        if (recovered.gate != .open or recovered.committed_barrier == 0 or recovered.last_sequence != recovered.committed_barrier)
            return error.PrivateRecoveryHistoryUnavailable;
        var result: CommittedInputs = .{};
        const view = try demo.recoverPrivateCheckpoint(store, io, decision_stream);
        if (view.boundary) |boundary| {
            if (recovered.committed_barrier - boundary.decision_barrier > 1024) return error.PrivateRecoveryCapacity;
            result.boundary = boundary;
            @memcpy(result.private_seed[0..view.seed.len], view.seed);
            result.resume_len = view.seed.len;
            result.next_sequence = try std.math.add(u64, boundary.decision_barrier, 1);
            try result.rememberSequence(.{ .stream = boundary.canonical_stream, .sequence = boundary.canonical_sequence });
            try store.replaySegmentsAfter(io, decision_stream, boundary.decision_barrier, recovery_byte_budget, .{ .ptr = &result, .consume_fn = segment });
        } else {
            try store.replaySegments(io, decision_stream, .{ .ptr = &result, .consume_fn = segment });
        }
        if (result.next_sequence != (try std.math.add(u64, recovered.committed_barrier, 1))) return error.PrivateRecoveryHistoryUnavailable;
        return result;
    }

    fn segment(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *CommittedInputs = @ptrCast(@alignCast(ptr));
        var reader = try journal.Reader.init(bytes);
        while (true) switch (try reader.next()) {
            .end => |status| {
                if (status != .clean and reader.offset != bytes.len) return error.PrivateRecoveryHistoryUnavailable;
                break;
            },
            .record => |record| {
                if (self.boundary) |boundary| if (record.sequence <= boundary.decision_barrier) continue;
                if (record.sequence != self.next_sequence) return error.PrivateRecoveryHistoryUnavailable;
                self.next_sequence = try std.math.add(u64, self.next_sequence, 1);
                if (record.flags & journal.input_flag == 0) continue;
                switch (try trading.decodeStableInput(record)) {
                    .core => {},
                    .venue => |event| {
                        try self.rememberSequence(event.envelope.identity);
                        if (privateFact(event)) try self.remember(event);
                    },
                }
            },
        };
    }

    fn rememberSequence(self: *CommittedInputs, identity: canonical.EventIdentity) !void {
        for (self.streams[0..self.stream_count]) |*known| {
            if (known.stream != identity.stream) continue;
            known.sequence = @max(known.sequence, identity.sequence);
            return;
        }
        if (self.stream_count == self.streams.len) return error.PrivateRecoveryCapacity;
        self.streams[self.stream_count] = identity;
        self.stream_count += 1;
    }

    pub fn sequenceFor(self: *const CommittedInputs, session: u128) u64 {
        for (self.streams[0..self.stream_count]) |identity| if (identity.stream == session) return identity.sequence;
        return 0;
    }

    fn find(self: *const CommittedInputs, record: canonical.EventRecord) !?usize {
        if (self.boundary) |boundary| if (record.envelope.raw_evidence.sequence <= boundary.raw_sequence)
            return error.PrivateFactOutsideRecoveryBoundary;
        const incoming = try entryFor(record);
        for (self.entries[0..self.count], 0..) |known, index| {
            if (!sameFact(known, incoming)) continue;
            if (!std.mem.eql(u8, &known.evidence.digest, &incoming.evidence.digest) or
                !std.mem.eql(u8, &known.payload, &incoming.payload)) return error.ConflictingRecoveredPrivateFact;
            return index;
        }
        return null;
    }

    pub fn contains(self: *const CommittedInputs, record: canonical.EventRecord) !bool {
        return (try self.find(record)) != null;
    }

    pub fn verifySweep(self: *const CommittedInputs) !void {
        for (self.visited[0..self.count]) |visited| if (!visited) return error.IncompletePrivateRecovery;
    }

    fn remember(self: *CommittedInputs, record: canonical.EventRecord) !void {
        if (try self.contains(record)) return;
        if (self.count == self.entries.len) return error.PrivateRecoveryCapacity;
        self.entries[self.count] = try entryFor(record);
        self.count += 1;
    }

    pub fn applyBatch(self: *CommittedInputs, owner: *demo.Owner, batch: canonical.AdapterOutputBatch) !void {
        for (batch.slice()) |record| {
            // Recovery control requests reconstruct only the decoder state;
            // their historical authorization facts belong to the Owner journal.
            if (!privateFact(record)) continue;
            if (try self.find(record)) |known| {
                self.visited[known] = true;
                continue;
            }
            if (self.count == self.entries.len) return error.PrivateRecoveryCapacity;
            _ = try owner.apply(.{ .venue = record });
            try self.remember(record);
            self.visited[self.count - 1] = true;
        }
    }
};

/// Capture only a complete raw frame after its complete canonical drain has
/// committed. This is an explicit checkpoint, never a canonical cursor guess.
pub fn checkpointPrivate(owner: *demo.Owner, implementation: *okx.OkxVenueAdapter, decoder: *const DecoderReplay, sink: *raw.DurableSink) !void {
    errdefer {
        owner.closed = true;
        owner.shard.recovery_admission_pending = true;
    }
    if (owner.checkpoint_pending or owner.closed or !owner.ready or !decoder.complete(implementation, false))
        return error.PrivateRecoveryBoundaryUnavailable;
    const reconciler = implementation.reconciler orelse return error.MissingPrivateReconciler;
    const raw_sequence = try std.math.sub(u64, sink.next_sequence, 1);
    if (raw_sequence == 0 or reconciler.rawWatermark() != raw_sequence) return error.PrivateRecoveryBoundaryUnavailable;
    var seed_buffer: [okx.max_resume_checkpoint_bytes]u8 = undefined;
    const seed = try implementation.exportResumeCheckpoint(&seed_buffer);
    const binding = implementation.binding orelse return error.InvalidBinding;
    if (binding.account != owner.shard.exchange_account_identity or implementation.next_event_sequence <= 1)
        return error.PrivateRecoveryBoundaryUnavailable;
    var matching_cursor = false;
    for (owner.shard.canonical_ingress_cursors[0..owner.shard.canonical_ingress_cursor_count]) |cursor| {
        if (cursor.identity.stream == binding.session and cursor.identity.sequence == implementation.next_event_sequence - 1)
            matching_cursor = true;
    }
    if (!matching_cursor) return error.PrivateRecoveryBoundaryUnavailable;
    const Continuity = struct {
        stream: u128,
        next: u64,
        fn consume(ptr: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var inputs = try journal.Reader.init(bytes);
            while (true) switch (try inputs.next()) {
                .end => break,
                .record => |record| {
                    if (record.flags & journal.input_flag == 0) continue;
                    const input = try trading.decodeStableInput(record);
                    if (input != .venue or input.venue.envelope.identity.stream != self.stream) continue;
                    const sequence = input.venue.envelope.identity.sequence;
                    if (sequence < self.next) continue;
                    if (sequence != self.next) return error.PrivateRecoveryBoundaryUnavailable;
                    self.next = try std.math.add(u64, self.next, 1);
                },
            };
        }
    };
    const after = if (owner.private_boundary) |boundary| boundary.decision_barrier else 0;
    const floor = if (owner.private_boundary) |boundary| (if (boundary.canonical_stream == binding.session) boundary.canonical_sequence else 0) else 0;
    var continuity: Continuity = .{ .stream = binding.session, .next = try std.math.add(u64, floor, 1) };
    try owner.store.replaySegmentsAfter(owner.io, owner.stream, after, recovery_byte_budget, .{ .ptr = &continuity, .consume_fn = Continuity.consume });
    if (continuity.next != implementation.next_event_sequence) return error.PrivateRecoveryBoundaryUnavailable;
    const recovered = try sink.store.recover(sink.io, sink.stream);
    if (recovered.gate != .open or recovered.last_sequence != raw_sequence or recovered.committed_barrier != raw_sequence)
        return error.PrivateRecoveryBoundaryUnavailable;
    var reader = try journal.Reader.init(recovered.active_segment);
    var raw_digest: [32]u8 = undefined;
    var found = false;
    while (true) switch (try reader.next()) {
        .end => break,
        .record => |record| if (record.sequence == raw_sequence) {
            if (record.payload.len < 72) return error.InvalidRawIngress;
            std.crypto.hash.sha2.Sha256.hash(record.payload[72..], &raw_digest, .{});
            if (!std.mem.eql(u8, &raw_digest, record.payload[40..72])) return error.InvalidRawIngress;
            found = true;
        },
    };
    if (!found) return error.PrivateRecoveryBoundaryUnavailable;
    try sink.checkpoint();
    const archive = try sink.store.archiveReceipt(sink.io, sink.stream);
    if (archive.covered_last != raw_sequence or !try sink.store.verifyArchiveReceipt(sink.io, sink.stream, raw_sequence, archive.ordered_root))
        return error.PrivateRecoveryBoundaryUnavailable;
    var seed_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(seed, &seed_digest, .{});
    try owner.checkpointPrivate(.{
        .decision_stream = owner.stream.id,
        .decision_barrier = owner.shard.authoritativeBarrier(),
        .core_digest = owner.shard.canonicalStateDigest(),
        .raw_stream = sink.stream,
        .raw_sequence = raw_sequence,
        .raw_digest = raw_digest,
        .raw_archive_root = archive.ordered_root,
        .adapter_session = @intCast(binding.session),
        .canonical_stream = binding.session,
        .canonical_sequence = implementation.next_event_sequence - 1,
        .seed_digest = seed_digest,
    }, seed);
}

pub const Sweep = struct {
    implementation: *okx.OkxVenueAdapter,
    owner: *demo.Owner,
    index: *CommittedInputs,
    session: u64 = 1,
    reconciliation_identity: u128 = 1,
    rest_page_size: usize = 3,
    last_sequence: u64 = 0,
    decoder: DecoderReplay = .{},
    checkpoint_restored: bool = false,

    pub fn restoreCheckpoint(self: *Sweep) !void {
        errdefer {
            self.owner.closed = true;
            self.owner.shard.recovery_admission_pending = true;
        }
        const boundary = self.index.boundary orelse return;
        const owner_boundary = self.owner.private_boundary orelse return error.PrivateRecoveryBoundaryUnavailable;
        const ingress_store = self.owner.recovery_ingress_store orelse return error.PrivateRecoveryBoundaryUnavailable;
        const ingress = self.owner.recovery_ingress orelse return error.PrivateRecoveryBoundaryUnavailable;
        if (self.checkpoint_restored or !std.meta.eql(boundary, owner_boundary) or !std.meta.eql(boundary.raw_stream, ingress) or
            boundary.adapter_session != self.session or
            !try ingress_store.verifyArchiveReceipt(self.owner.io, ingress, boundary.raw_sequence, boundary.raw_archive_root))
            return error.PrivateRecoveryBoundaryUnavailable;
        try self.implementation.restoreResumeCheckpoint(self.index.private_seed[0..self.index.resume_len]);
        const next_sequence = std.math.add(u64, boundary.canonical_sequence, 1) catch return error.InvalidPrivateResumeCheckpoint;
        if (self.implementation.next_event_sequence != next_sequence or
            self.implementation.reconciler.?.rawWatermark() != boundary.raw_sequence)
            return error.InvalidPrivateResumeCheckpoint;
        for (self.owner.shard.oms.orders[0..self.owner.shard.oms.order_count]) |order| {
            try self.implementation.rememberRecoveredOrder(order.id, order.client_order_id, order.portfolio_reduce_only, .{ .instrument = order.instrument, .rules_version = order.limit_price.rules_version, .lots = order.quantity }, order.revision);
        }
        self.decoder.reconciliation_started = true;
        self.checkpoint_restored = true;
        self.owner.private_seed_restored = true;
    }

    pub fn replayCommitted(self: *Sweep, stream: durable.StreamIdentity) !void {
        errdefer {
            self.owner.closed = true;
            self.owner.shard.recovery_admission_pending = true;
        }
        if (self.index.boundary != null and !self.checkpoint_restored) try self.restoreCheckpoint();
        try self.owner.replayCommittedIngress(stream, self.consumer());
        try self.index.verifySweep();
        if (!self.decoder.complete(self.implementation, self.owner.shard.economic_fault_count != 0))
            return error.IncompletePrivateRecovery;
    }

    pub fn consumer(self: *Sweep) raw.ReplayConsumer {
        return .{ .ptr = self, .consume_fn = consume };
    }

    fn drain(self: *Sweep) !void {
        while (try self.implementation.adapter().tryDrain()) |batch| try self.index.applyBatch(self.owner, batch);
    }

    fn consume(ptr: *anyopaque, sequence: u64, record: market.RawIngressRecord, bytes: []const u8) !void {
        const self: *Sweep = @ptrCast(@alignCast(ptr));
        if (self.index.boundary) |boundary| if (!self.checkpoint_restored or sequence <= boundary.raw_sequence)
            return error.PrivateRecoveryBoundaryUnavailable;
        if (self.last_sequence == 0 or sequence > self.last_sequence) return error.PrivateRecoveryBoundaryUnavailable;
        try self.consumeRecord(sequence, record, bytes);
        if (sequence == self.last_sequence) {
            if (!self.decoder.complete(self.implementation, self.owner.shard.economic_fault_count != 0))
                return error.IncompletePrivateRecovery;
            try self.index.verifySweep();
        }
    }

    fn consumeRecord(self: *Sweep, sequence: u64, record: market.RawIngressRecord, bytes: []const u8) !void {
        self.decoder.session = self.session;
        self.decoder.reconciliation_identity = self.reconciliation_identity;
        self.decoder.rest_page_size = self.rest_page_size;
        const Drain = struct {
            fn call(ptr: *anyopaque) !void {
                try @as(*Sweep, @ptrCast(@alignCast(ptr))).drain();
            }
        };
        try self.decoder.ingest(self.implementation, sequence, record, bytes, self, Drain.call);
    }
};

/// One raw-history decoder for in-process Owner recovery and the existing
/// Windows execution process. The caller drains through its own Owner seam.
pub const DecoderReplay = struct {
    session: u64 = 1,
    reconciliation_identity: u128 = 1,
    rest_page_size: usize = 3,
    reconciliation_started: bool = false,
    previous_source: ?private.IngressSource = null,
    after: ?u64 = null,
    query_target: [256]u8 = undefined,
    query_target_len: usize = 0,
    query_evidence: ?private.RawEvidenceRef = null,

    pub fn complete(self: *const DecoderReplay, implementation: *const okx.OkxVenueAdapter, economic_fault: bool) bool {
        return self.query_evidence == null and implementation.pending_economic_boundary == null and
            (implementation.reconciler.?.readiness().reconciliation_ready or economic_fault);
    }

    pub fn ingest(self: *DecoderReplay, implementation: *okx.OkxVenueAdapter, sequence: u64, record: market.RawIngressRecord, bytes: []const u8, drain_context: *anyopaque, drain_fn: *const fn (*anyopaque) anyerror!void) !void {
        if (record.source_session != self.session) return error.PrivateReplaySessionMismatch;
        if (record.origin == live.transport_response_origin) return;
        const evidence: private.RawEvidenceRef = .{ .stream_sequence = sequence, .sha256 = record.sha256 };
        const times: private.Times = .{ .receive_time_utc_ns = record.receive_time_utc_ns, .monotonic_time_ns = record.monotonic_time_ns, .wall_time_utc_ns = record.wall_time_utc_ns };
        if (record.origin == 0) {
            _ = try implementation.replayPrivateWs(times, evidence, bytes);
        } else {
            const source = std.enums.fromInt(private.IngressSource, record.origin - 1) orelse return error.InvalidPrivateReplaySource;
            if (source.isWebSocket()) return error.InvalidPrivateReplaySource;
            if (source == .economic_reconciliation_request) {
                if (self.query_evidence != null) return error.IncompletePrivateRecovery;
                try implementation.replayEconomicRequest(bytes);
                return drain_fn(drain_context);
            }
            if (source == .rest_account_bill_query) {
                if (self.query_evidence != null or bytes.len == 0 or bytes.len > self.query_target.len)
                    return error.IncompletePrivateRecovery;
                @memcpy(self.query_target[0..bytes.len], bytes);
                self.query_target_len = bytes.len;
                self.query_evidence = evidence;
                return;
            }
            if (self.query_evidence) |query| {
                if (source != .rest_account_bills or sequence != try std.math.add(u64, query.stream_sequence, 1)) return error.IncompletePrivateRecovery;
            }
            if (!self.reconciliation_started or (source == .rest_account_config and implementation.reconciler.?.readiness().reconciliation_ready)) {
                if (try implementation.adapter().trySend(.{ .account_reconciliation = .{ .identity = self.reconciliation_identity, .exchange_account = implementation.binding.?.account, .expected_session = self.session } }) != .accepted)
                    return error.PrivateReplayReconciliationRejected;
                self.reconciliation_started = true;
                try drain_fn(drain_context);
            }
            if (self.previous_source != source) self.after = null;
            const parsed = std.json.parseFromSlice(std.json.Value, implementation.allocator, bytes, .{}) catch null;
            defer if (parsed) |value| value.deinit();
            const row_count = if (parsed) |value| blk: {
                if (value.value != .object) break :blk 0;
                const rows = value.value.object.get("data") orelse break :blk 0;
                break :blk if (rows == .array) rows.array.items.len else 0;
            } else 0;
            const paginated = switch (source) {
                .rest_orders_pending, .rest_orders_history_spot, .rest_orders_history_swap, .rest_fills_history_spot, .rest_fills_history_swap => true,
                else => false,
            };
            if (self.rest_page_size == 0) return error.InvalidRestPage;
            const economic_page = source == .rest_account_bills and implementation.pending_economic_through != null;
            if (economic_page and self.query_evidence == null) return error.IncompletePrivateRecovery;
            const final = if (economic_page) row_count < 8 else !paginated or row_count < self.rest_page_size;
            const batch = try implementation.replayPrivateRest(times, source, .{
                .requested_after = if (economic_page) implementation.economic_bill_after else self.after,
                .final = final,
                .request_target = if (economic_page) self.query_target[0..self.query_target_len] else null,
                .query_evidence = self.query_evidence,
            }, evidence, bytes);
            self.query_evidence = null;
            self.previous_source = source;
            self.after = if (final or batch.rejection != null) null else batch.oldest_cursor orelse {
                try drain_fn(drain_context);
                return error.MissingRestPageCursor;
            };
        }
        // Rejections are canonical economic_fault outputs too. Always publish
        // them before permitting the Owner's exhaustive sweep to finish.
        try drain_fn(drain_context);
    }
};
