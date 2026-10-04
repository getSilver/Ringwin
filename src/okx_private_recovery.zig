//! Rebuild private decoder state and submit only facts absent from the retained
//! committed decision inputs. Raw and canonical sequence spaces stay separate.
const std = @import("std");
const canonical = @import("canonical_event.zig");
const codec = @import("canonical_event_codec.zig");
const durable = @import("durable_store.zig");
const journal = @import("journal.zig");
const trading = @import("trading_shard.zig");
const demo = @import("demo_authority.zig");
const okx = @import("okx_venue_adapter.zig");
const private = @import("okx_private_reconciliation.zig");
const live = @import("okx_live_chain.zig");
const raw = @import("raw_ingress.zig");
const market = @import("okx_public_market.zig");

const max_inputs = 1024;
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
        .execution_report, .fill, .economic_fault, .account_bootstrap_snapshot, .account_observed, .venue_account_configuration_snapshot, .order_reconciliation_result => true,
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

    pub fn init(store: durable.Store, io: std.Io, decision_stream: durable.StreamIdentity) !CommittedInputs {
        if (decision_stream.domain != .decision_log or !store.supportsSegmentReplay() or store.safetyGate() != .open)
            return error.PrivateRecoveryHistoryUnavailable;
        const recovered = try store.recover(io, decision_stream);
        if (recovered.gate != .open or recovered.committed_barrier == 0 or recovered.last_sequence != recovered.committed_barrier)
            return error.PrivateRecoveryHistoryUnavailable;
        var result: CommittedInputs = .{};
        try store.replaySegments(io, decision_stream, .{ .ptr = &result, .consume_fn = segment });
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

pub const Sweep = struct {
    implementation: *okx.OkxVenueAdapter,
    owner: *demo.Owner,
    index: *CommittedInputs,
    session: u64 = 1,
    reconciliation_identity: u128 = 1,
    rest_page_size: usize = 3,
    last_sequence: u64 = 0,
    reconciliation_started: bool = false,
    previous_source: ?private.IngressSource = null,
    after: ?u64 = null,

    pub fn consumer(self: *Sweep) raw.ReplayConsumer {
        return .{ .ptr = self, .consume_fn = consume };
    }

    fn drain(self: *Sweep) !void {
        while (try self.implementation.adapter().tryDrain()) |batch| try self.index.applyBatch(self.owner, batch);
    }

    fn consume(ptr: *anyopaque, sequence: u64, record: market.RawIngressRecord, bytes: []const u8) !void {
        const self: *Sweep = @ptrCast(@alignCast(ptr));
        if (self.last_sequence == 0 or sequence > self.last_sequence) return error.PrivateRecoveryBoundaryUnavailable;
        try self.consumeRecord(sequence, record, bytes);
        if (sequence == self.last_sequence) {
            try self.index.verifySweep();
            if (!self.implementation.reconciler.?.readiness().reconciliation_ready and self.owner.shard.economic_fault_count == 0)
                return error.IncompletePrivateRecovery;
        }
    }

    fn consumeRecord(self: *Sweep, sequence: u64, record: market.RawIngressRecord, bytes: []const u8) !void {
        if (record.source_session != self.session) return error.PrivateReplaySessionMismatch;
        if (record.origin == live.transport_response_origin) return;
        const evidence: private.RawEvidenceRef = .{ .stream_sequence = sequence, .sha256 = record.sha256 };
        const times: private.Times = .{ .receive_time_utc_ns = record.receive_time_utc_ns, .monotonic_time_ns = record.monotonic_time_ns, .wall_time_utc_ns = record.wall_time_utc_ns };
        if (record.origin == 0) {
            _ = try self.implementation.replayPrivateWs(times, evidence, bytes);
        } else {
            const source = std.enums.fromInt(private.IngressSource, record.origin - 1) orelse return error.InvalidPrivateReplaySource;
            if (source.isWebSocket()) return error.InvalidPrivateReplaySource;
            if (!self.reconciliation_started or (source == .rest_account_config and self.implementation.reconciler.?.readiness().reconciliation_ready)) {
                if (try self.implementation.adapter().trySend(.{ .account_reconciliation = .{ .identity = self.reconciliation_identity, .exchange_account = self.implementation.binding.?.account, .expected_session = self.session } }) != .accepted)
                    return error.PrivateReplayReconciliationRejected;
                self.reconciliation_started = true;
                try self.drain();
            }
            if (self.previous_source != source) self.after = null;
            const parsed = std.json.parseFromSlice(std.json.Value, self.implementation.allocator, bytes, .{}) catch null;
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
            const final = !paginated or row_count < self.rest_page_size;
            const batch = try self.implementation.replayPrivateRest(times, source, .{ .requested_after = self.after, .final = final }, evidence, bytes);
            self.previous_source = source;
            self.after = if (final or batch.rejection != null) null else batch.oldest_cursor orelse {
                try self.drain();
                return error.MissingRestPageCursor;
            };
        }
        // Rejections are canonical economic_fault outputs too. Always publish
        // them before permitting the Owner's exhaustive sweep to finish.
        try self.drain();
    }
};
