const canonical = @import("../model/canonical_event.zig");
const oms = @import("oms.zig");
const venue = @import("venue_adapter.zig");
const std = @import("std");
const trading = @import("../trading/trading_shard.zig");
const shard_event = @import("../trading/trading_shard_event.zig");
const durable = @import("../persistence/durable_store.zig");
const snapshot_codec = @import("../persistence/snapshot_codec.zig");
const production_contract = @import("../runtime/production_contract.zig");
const failover = @import("../runtime/failover.zig");
const history = @import("../persistence/business_history.zig");
const dispatch_record_type: u16 = 0x4701;
const resolution_record_type: u16 = 0x4702;
const accepted_record_type: u16 = 0x4703;
const archive_record_type: u16 = 0x4704;
const economic_history_record_type: u16 = 0x4705;
const dispatch_snapshot = "GatewayDispatchV8";
const namespace_size = 16;
const snapshot_prefix_size = dispatch_snapshot.len + @sizeOf(u16);

pub const CapabilityProfile = struct {
    version: u64,
    rules_version: u64,
    config_version: u64,
    session: canonical.AdapterSessionIdentity,
    supports_place: bool = true,
    supports_cancel: bool = true,
    supports_native_amend: bool = false,
    supports_venue_reduce_only: bool = false,
    supports_post_only: bool = false,
    supports_market_protection: bool = false,
};
pub const LatchedSafetyGate = enum { open, latched };
pub const OpeningGate = enum { open, blocked };
pub const Route = struct {
    account: canonical.ExchangeAccountIdentity,
    adapter: venue.VenueAdapter,
    capability: CapabilityProfile,
    venue_identity: canonical.VenueIdentity = 0,
    environment: shard_event.CapabilityProfileActivation.Environment = .simulation,
    lease_guard: ?*failover.GatewayLeaseGuard = null,
    safety_gate: LatchedSafetyGate = .open,
    /// Zero preserves legacy routing; new multi-product routes grant an explicit mask.
    supported_products: u8 = 0,
};
pub fn productMask(product: canonical.Product) u8 {
    return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(product)));
}
pub const InstrumentOpeningGate = struct { instrument: canonical.InstrumentIdentity, state: OpeningGate = .open };
pub const OmsDispatchContext = struct {
    account: canonical.ExchangeAccountIdentity,
    capability_version: u64,
    rules_version: u64,
    config_version: u64,
    adapter_session: canonical.AdapterSessionIdentity,
    dispatch_deadline_monotonic_ns: u64,
};
pub const AuthorityFacts = struct {
    account: canonical.ExchangeAccountIdentity,
    effective_trading_authority: bool,
    reservation_identity: u64,
    reservation: canonical.AssetAmount,
    primary_lease_expires_at_monotonic_ns: u64,
    fencing_token: u64,
    exchange_position: canonical.InstrumentQuantity,
    authority_barrier: u64,
};
pub const DispatchProof = struct {
    origin: DispatchOrigin = .{},
    context: OmsDispatchContext,
    command: oms.Command,
    fencing_token: u64,
    authority_barrier: u64,
    now_monotonic_ns: u64,
    prior_reconciliation_id: u64 = 0,
};
pub const DispatchOrigin = struct {
    decision_stream: u64 = 0,
    account: canonical.ExchangeAccountIdentity = 0,
    portfolio: u128 = 0,
    test_shard: u32 = 0,
};
pub const DispatchEvidence = struct {
    proof: DispatchProof,
    outcome: enum { accepted, resolved_unknown },
    reconciliation_id: u64 = 0,
    reconciliation_status: ?oms.ReconciliationStatus = null,
};
const ArchiveBinding = struct { origin: DispatchOrigin, root: history.Root, last_order: ?DispatchArchiveCommit = null };
const DispatchArchiveCommit = struct { origin: DispatchOrigin, order_id: u64, receipt: history.Receipt };
const EconomicHistoryKind = enum { fill, funding, reconciliation_window, control, forced };
const EconomicHistoryCommit = struct { origin: DispatchOrigin, kind: EconomicHistoryKind, identity: u128, qualification_digest: history.Digest, receipt: history.Receipt };
pub const max_routes = 4;
pub const max_adapter_batches_per_turn: u8 = 1;
pub const max_authority_records = 128;
pub const max_dispatch_records = 4 * (1024 + 4096) * 2;
pub const max_reservation_facts = 4 * 1024 * 2;

fn atCapacity(count: usize, limit: usize) bool {
    return count == limit;
}

fn dispatchBudgetFull(accepted: u16, uncertain: u16) bool {
    return atCapacity(@as(usize, accepted) + uncertain, max_dispatch_records);
}

test "Gateway production dispatch and authority limits reject their numeric boundaries without resident load" {
    try std.testing.expect(!dispatchBudgetFull(40959, 0));
    try std.testing.expect(!dispatchBudgetFull(40958, 1));
    try std.testing.expect(dispatchBudgetFull(40959, 1));
    try std.testing.expect(dispatchBudgetFull(40960, 0));
    try std.testing.expect(dispatchBudgetFull(0, 40960));
    try std.testing.expect(!atCapacity(8191, max_reservation_facts));
    try std.testing.expect(atCapacity(8192, max_reservation_facts));
    try std.testing.expect(!atCapacity(499, max_exchange_position_facts));
    try std.testing.expect(atCapacity(500, max_exchange_position_facts));
}
pub const max_observed_instruments = 500;
pub const max_exchange_position_facts = max_observed_instruments;
const AccountAuthority = struct {
    effective_trading_authority: bool = false,
    primary_lease_expires_at_monotonic_ns: u64 = 0,
    fencing_token: u64 = 0,
    authority_barrier: u64 = 0,
};
const ReservationFact = struct {
    origin: DispatchOrigin = .{},
    account: canonical.ExchangeAccountIdentity,
    identity: u64,
    amount: canonical.AssetAmount,
    barrier: u64,
};
const ExchangePositionFact = struct {
    origin: DispatchOrigin = .{},
    account: canonical.ExchangeAccountIdentity,
    quantity: canonical.InstrumentQuantity,
    barrier: u64,
};
const AcceptedDispatch = struct {
    origin: DispatchOrigin = .{},
    account: canonical.ExchangeAccountIdentity,
    command_id: u64,
    proof: DispatchProof,
};
const UncertainDispatch = struct {
    origin: DispatchOrigin = .{},
    account: canonical.ExchangeAccountIdentity,
    command_id: u64,
    client_order_id: canonical.ClientOrderId,
    prior_reconciliation_id: u64 = 0,
    reconciliation_id: u64 = 0,
    reconciliation_status: ?oms.ReconciliationStatus = null,
    recovered_proof: ?DispatchProof = null,
};
const DispatchResolution = struct {
    origin: DispatchOrigin = .{},
    account: canonical.ExchangeAccountIdentity,
    command_id: u64,
    reconciliation_id: u64,
    status: oms.ReconciliationStatus,
};
const DurableDispatch = struct {
    store: durable.Store,
    io: std.Io,
    stream: durable.StreamIdentity,
    namespace: [namespace_size]u8,
    next_sequence: u64,
};
const dispatch_snapshot_version: u16 = 8;
const DispatchSnapshotHeader = struct {
    version: u16 = dispatch_snapshot_version,
    stream: durable.StreamIdentity,
    barrier: u64,
    namespace: [namespace_size]u8,
    archive_count: u8,
    accepted_count: u16,
    uncertain_count: u16,
    latch_count: u8,
};
const SnapshotUnknown = struct { proof: DispatchProof, reconciliation_id: u64, reconciliation_status: ?oms.ReconciliationStatus };
const DispatchLatch = struct { account: canonical.ExchangeAccountIdentity, state: LatchedSafetyGate };
const SnapshotRows = struct {
    bytes: []const u8,
    position: usize = 0,
    fn read(self: *@This(), comptime T: type) !T {
        if (self.bytes.len - self.position < 4) return error.DurableDispatchUnavailable;
        const length = std.mem.readInt(u32, self.bytes[self.position..][0..4], .little);
        self.position += 4;
        if (length > self.bytes.len - self.position) return error.DurableDispatchUnavailable;
        const value = snapshot_codec.decodeBare(self.bytes[self.position..][0..length], T) catch return error.DurableDispatchUnavailable;
        self.position += length;
        return value;
    }
};
fn writeSnapshotRow(destination: []u8, position: *usize, value: anytype) !void {
    if (destination.len - position.* < 4) return error.DurableDispatchUnavailable;
    const encoded = try snapshot_codec.encodeBare(destination[position.* + 4 ..], value);
    std.mem.writeInt(u32, destination[position.*..][0..4], @intCast(encoded.len), .little);
    position.* += 4 + encoded.len;
}
pub const Gateway = struct {
    routes: [max_routes]Route = undefined,
    count: u8 = 0,
    instrument_gates: [max_observed_instruments]InstrumentOpeningGate = undefined,
    instrument_gate_count: u16 = 0,
    instrument_gate_capacity_exhausted: bool = false,
    account_authority: [max_routes]AccountAuthority = @splat(.{}),
    origin_authority: [max_authority_records]struct { origin: DispatchOrigin, authority: AccountAuthority, source_barrier: u64 = 0 } = undefined,
    origin_authority_count: u8 = 0,
    archive_bindings: [max_authority_records]ArchiveBinding = undefined,
    archive_binding_count: u8 = 0,
    reservations: [max_reservation_facts]ReservationFact = undefined,
    reservation_count: u16 = 0,
    exchange_positions: [max_exchange_position_facts]ExchangePositionFact = undefined,
    exchange_position_count: u16 = 0,
    accepted_dispatches: [max_dispatch_records]AcceptedDispatch = undefined,
    accepted_dispatch_count: u16 = 0,
    uncertain_dispatches: [max_dispatch_records]UncertainDispatch = undefined,
    uncertain_dispatch_count: u16 = 0,
    durable_dispatch: ?DurableDispatch = null,
    // Borrowed caller-owned storage; never encoded into durable state.
    dispatch_snapshot_buffer: ?[]u8 = null,
    send_attempt_count: u64 = 0,

    /// Initializes caller-owned storage without materializing the large resident arrays.
    pub fn init(self: *Gateway) void {
        self.count = 0;
        self.instrument_gate_count = 0;
        self.instrument_gate_capacity_exhausted = false;
        self.account_authority = @splat(.{});
        self.origin_authority_count = 0;
        self.archive_binding_count = 0;
        self.reservation_count = 0;
        self.exchange_position_count = 0;
        self.accepted_dispatch_count = 0;
        self.uncertain_dispatch_count = 0;
        self.durable_dispatch = null;
        self.dispatch_snapshot_buffer = null;
        self.send_attempt_count = 0;
    }

    /// Storage must remain exclusively available until this Gateway is retired.
    pub fn initWithDispatchSnapshotBuffer(self: *Gateway, snapshot_buffer: []u8) void {
        self.init();
        self.dispatch_snapshot_buffer = snapshot_buffer;
    }

    /// Explicit virgin-stream bootstrap. Production callers must establish
    /// stream identity from operator-owned durable metadata, not a missing file.
    pub fn bootstrapDurableDispatch(self: *Gateway, store: durable.Store, io: std.Io, stream: durable.StreamIdentity) !void {
        if (self.dispatch_snapshot_buffer) |buffer| return self.bootstrapDurableDispatchWithBuffer(store, io, stream, buffer);
        return @call(.never_inline, Gateway.bootstrapDurableDispatchOnStack, .{ self, store, io, stream });
    }

    fn bootstrapDurableDispatchOnStack(self: *Gateway, store: durable.Store, io: std.Io, stream: durable.StreamIdentity) !void {
        var snapshot_buffer: [durable.max_snapshot_bytes]u8 = undefined;
        return self.bootstrapDurableDispatchWithBuffer(store, io, stream, &snapshot_buffer);
    }

    /// The caller owns snapshot storage through synchronous durable publication.
    pub fn bootstrapDurableDispatchWithBuffer(self: *Gateway, store: durable.Store, io: std.Io, stream: durable.StreamIdentity, snapshot_buffer: []u8) !void {
        if (self.durable_dispatch != null or stream.domain != .control or stream.id == 0 or store.safetyGate() != .open)
            return error.DurableDispatchUnavailable;
        var namespace: [namespace_size]u8 = undefined;
        std.Io.randomSecure(std.Io.Threaded.global_single_threaded.io(), &namespace) catch return error.DurableDispatchUnavailable;
        const snapshot = try self.encodeDispatchSnapshot(snapshot_buffer, stream, 1, namespace);
        store.append(io, .{ .stream = stream, .record = .{
            .type_id = dispatch_record_type,
            .schema_version = production_contract.journal_schema_version,
            .flags = 0,
            .sequence = 1,
            .source_time = 0,
            .receive_time = 0,
            .monotonic_time = 0,
            .wall_time = 0,
            .time_presence = .{},
            .payload = &.{},
        } }) catch return error.DurableDispatchUnavailable;
        store.commit(io, stream, 1) catch return error.DurableDispatchUnavailable;
        store.seal(io, stream) catch return error.DurableDispatchUnavailable;
        store.publishSnapshot(io, stream, 1, snapshot) catch return error.DurableDispatchUnavailable;
        store.rotate(io, stream) catch return error.DurableDispatchUnavailable;
        self.durable_dispatch = .{ .store = store, .io = io, .stream = stream, .namespace = namespace, .next_sequence = 2 };
    }

    fn encodeDispatchSnapshot(self: *const Gateway, destination: []u8, stream: durable.StreamIdentity, barrier: u64, namespace: [namespace_size]u8) ![]const u8 {
        const header: DispatchSnapshotHeader = .{ .stream = stream, .barrier = barrier, .namespace = namespace, .archive_count = self.archive_binding_count, .accepted_count = self.accepted_dispatch_count, .uncertain_count = self.uncertain_dispatch_count, .latch_count = self.count };
        if (destination.len < snapshot_prefix_size) return error.DurableDispatchUnavailable;
        @memcpy(destination[0..dispatch_snapshot.len], dispatch_snapshot);
        std.mem.writeInt(u16, destination[dispatch_snapshot.len..][0..2], production_contract.journal_schema_version, .little);
        var position: usize = snapshot_prefix_size;
        try writeSnapshotRow(destination, &position, header);
        for (self.archive_bindings[0..self.archive_binding_count]) |row| try writeSnapshotRow(destination, &position, row);
        for (self.accepted_dispatches[0..self.accepted_dispatch_count]) |row| try writeSnapshotRow(destination, &position, row.proof);
        for (self.uncertain_dispatches[0..self.uncertain_dispatch_count]) |row| try writeSnapshotRow(destination, &position, SnapshotUnknown{ .proof = row.recovered_proof orelse return error.DurableDispatchUnavailable, .reconciliation_id = row.reconciliation_id, .reconciliation_status = row.reconciliation_status });
        for (self.routes[0..self.count]) |route| try writeSnapshotRow(destination, &position, DispatchLatch{ .account = route.account, .state = route.safety_gate });
        return destination[0..position];
    }

    pub fn checkpointDurableDispatch(self: *Gateway) !void {
        if (self.dispatch_snapshot_buffer) |buffer| return self.checkpointDurableDispatchWithBuffer(buffer);
        return @call(.never_inline, Gateway.checkpointDurableDispatchOnStack, .{self});
    }

    fn checkpointDurableDispatchOnStack(self: *Gateway) !void {
        var snapshot_buffer: [durable.max_snapshot_bytes]u8 = undefined;
        return self.checkpointDurableDispatchWithBuffer(&snapshot_buffer);
    }

    /// Uses independent caller-owned storage; Store recovery may load older snapshots.
    pub fn checkpointDurableDispatchWithBuffer(self: *Gateway, snapshot_buffer: []u8) !void {
        errdefer for (self.routes[0..self.count]) |*route| {
            route.safety_gate = .latched;
        };
        const committed = self.durable_dispatch orelse return error.DurableDispatchUnavailable;
        if (committed.store.safetyGate() != .open or committed.next_sequence <= 1) return error.DurableDispatchUnavailable;
        const barrier = committed.next_sequence - 1;
        const snapshot = try self.encodeDispatchSnapshot(snapshot_buffer, committed.stream, barrier, committed.namespace);
        const persisted = try committed.store.recover(committed.io, committed.stream);
        if (persisted.status == .ready and persisted.gate == .open and persisted.snapshot_barrier == barrier and
            persisted.committed_barrier == barrier and persisted.last_sequence == barrier)
        {
            var active = try trading.journal.Reader.init(persisted.active_segment);
            switch (try active.next()) {
                .end => {
                    if (active.records == 0 and persisted.active_segment.len == trading.journal.segment_header_size and
                        std.mem.eql(u8, snapshot, persisted.snapshot)) return;
                    // shortcut: unsequenced latch changes cannot checkpoint, add a durable latch fact when standalone latch checkpoints are needed.
                    return error.DurableDispatchUnavailable;
                },
                .record => {},
            }
        }
        if (!persisted.segment_sealed) try committed.store.seal(committed.io, committed.stream);
        try committed.store.publishSnapshot(committed.io, committed.stream, barrier, snapshot);
        try committed.store.rotate(committed.io, committed.stream);
        const receipt = try committed.store.archiveReceipt(committed.io, committed.stream);
        if (receipt.covered_last != barrier or !try committed.store.verifyArchiveReceipt(committed.io, committed.stream, barrier, receipt.ordered_root)) return error.DurableDispatchUnavailable;
    }

    /// Recovery preserves durable outcomes; an attempt without an outcome
    /// remains Unknown. It never replays an adapter send.
    pub fn attachRecoveredDurableDispatch(self: *Gateway, store: durable.Store, io: std.Io, stream: durable.StreamIdentity) !void {
        if (self.durable_dispatch != null or stream.domain != .control or stream.id == 0 or store.safetyGate() != .open)
            return error.DurableDispatchUnavailable;
        const recovered = store.recover(io, stream) catch return error.DurableDispatchUnavailable;
        if (recovered.status != .ready or recovered.gate != .open or
            recovered.snapshot.len < snapshot_prefix_size or
            !std.mem.eql(u8, recovered.snapshot[0..dispatch_snapshot.len], dispatch_snapshot) or
            std.mem.readInt(u16, recovered.snapshot[dispatch_snapshot.len..][0..2], .little) != production_contract.journal_schema_version or
            recovered.committed_barrier == 0 or recovered.last_sequence != recovered.committed_barrier)
            return error.DurableDispatchUnavailable;
        var rows: SnapshotRows = .{ .bytes = recovered.snapshot[snapshot_prefix_size..] };
        const snapshot = try rows.read(DispatchSnapshotHeader);
        if (snapshot.version != dispatch_snapshot_version or !std.meta.eql(snapshot.stream, stream) or snapshot.barrier != recovered.snapshot_barrier or snapshot.barrier == 0 or snapshot.barrier > recovered.committed_barrier or
            @as(usize, snapshot.accepted_count) + snapshot.uncertain_count > max_dispatch_records or snapshot.latch_count > max_routes or snapshot.archive_count > max_authority_records or recovered.tail_count > recovered.tail_segments.len)
            return error.DurableDispatchUnavailable;
        const candidate = try std.heap.page_allocator.create(Gateway);
        defer std.heap.page_allocator.destroy(candidate);
        @memcpy(std.mem.asBytes(candidate), std.mem.asBytes(self));
        candidate.accepted_dispatch_count = 0;
        candidate.uncertain_dispatch_count = 0;
        candidate.archive_binding_count = 0;
        for (0..snapshot.archive_count) |_| {
            const binding = try rows.read(ArchiveBinding);
            try history.validateRoot(binding.root);
            if (binding.origin.decision_stream != binding.root.origin.stream.id or binding.origin.account != binding.root.origin.account or
                binding.origin.portfolio == 0 or binding.origin.test_shard != 0 or candidate.archiveBindingIndex(binding.origin) != null)
                return error.DurableDispatchUnavailable;
            if (binding.last_order) |order| {
                try history.validateRoot(order.receipt.root);
                if (!std.meta.eql(order.origin, binding.origin) or order.order_id == 0 or
                    !std.meta.eql(order.receipt.root.origin, binding.root.origin) or order.receipt.root.generation > binding.root.generation or
                    !std.mem.eql(u8, &order.receipt.previous_root, &order.receipt.root.previous_root) or
                    !std.mem.eql(u8, &order.receipt.qualification_digest, &order.receipt.root.qualification_digest) or
                    !std.mem.eql(u8, &order.receipt.batch_digest, &order.receipt.root.batch_digest) or
                    (order.receipt.root.generation == binding.root.generation and !std.meta.eql(order.receipt.root, binding.root)))
                    return error.DurableDispatchUnavailable;
            }
            candidate.archive_bindings[candidate.archive_binding_count] = binding;
            candidate.archive_binding_count += 1;
        }
        for (0..snapshot.accepted_count) |_| {
            const proof = try rows.read(DispatchProof);
            if (!validPersistedProof(proof) or candidate.acceptedDispatchIndex(proof.origin, proof.context.account, proof.command.command_id) != null) return error.DurableDispatchUnavailable;
            try candidate.restoreAcceptedDispatch(proof);
        }
        for (0..snapshot.uncertain_count) |_| {
            const uncertain = try rows.read(SnapshotUnknown);
            const proof = uncertain.proof;
            if (!validPersistedProof(proof) or
                candidate.acceptedDispatchIndex(proof.origin, proof.context.account, proof.command.command_id) != null or candidate.uncertainIndex(proof.origin, proof.context.account, proof.command.command_id) != null or
                (uncertain.reconciliation_id == 0) != (uncertain.reconciliation_status == null) or uncertain.reconciliation_status == .unresolved)
                return error.DurableDispatchUnavailable;
            try candidate.markUncertain(proof);
            candidate.uncertain_dispatches[candidate.uncertain_dispatch_count - 1].reconciliation_id = uncertain.reconciliation_id;
            candidate.uncertain_dispatches[candidate.uncertain_dispatch_count - 1].reconciliation_status = uncertain.reconciliation_status;
        }
        for (0..snapshot.latch_count) |_| {
            const latch = try rows.read(DispatchLatch);
            const index = candidate.routeIndex(latch.account) orelse return error.DurableDispatchUnavailable;
            if (latch.state == .latched) candidate.routes[index].safety_gate = .latched;
        }
        if (rows.position != rows.bytes.len) return error.DurableDispatchUnavailable;
        var last_committed_sequence: u64 = snapshot.barrier;
        const tails = if (recovered.tail_count != 0) recovered.tail_segments[0..recovered.tail_count] else &.{recovered.tail};
        for (tails) |tail| {
            if (tail.len == 0) continue;
            var reader = try trading.journal.Reader.init(tail);
            while (true) switch (try reader.next()) {
                .end => break,
                .record => |record| {
                    if (record.sequence > recovered.committed_barrier) continue;
                    if (record.sequence != (std.math.add(u64, last_committed_sequence, 1) catch return error.DurableDispatchUnavailable))
                        return error.DurableDispatchUnavailable;
                    last_committed_sequence = record.sequence;
                    if (record.schema_version != production_contract.journal_schema_version or record.flags != 0)
                        return error.DurableDispatchUnavailable;
                    switch (record.type_id) {
                        dispatch_record_type => {
                            const proof = snapshot_codec.decodeBare(record.payload, DispatchProof) catch return error.DurableDispatchUnavailable;
                            if (!validPersistedProof(proof) or candidate.uncertainIndex(proof.origin, proof.context.account, proof.command.command_id) != null or candidate.acceptedDispatchIndex(proof.origin, proof.context.account, proof.command.command_id) != null)
                                return error.DurableDispatchUnavailable;
                            candidate.markUncertain(proof) catch return error.DurableDispatchUnavailable;
                        },
                        resolution_record_type => {
                            const resolution = snapshot_codec.decodeBare(record.payload, DispatchResolution) catch return error.DurableDispatchUnavailable;
                            if (resolution.reconciliation_id == 0 or resolution.status == .unresolved)
                                return error.DurableDispatchUnavailable;
                            const index = candidate.uncertainIndex(resolution.origin, resolution.account, resolution.command_id) orelse return error.DurableDispatchUnavailable;
                            if (candidate.uncertain_dispatches[index].reconciliation_id != 0)
                                return error.DurableDispatchUnavailable;
                            candidate.uncertain_dispatches[index].reconciliation_id = resolution.reconciliation_id;
                            candidate.uncertain_dispatches[index].reconciliation_status = resolution.status;
                        },
                        accepted_record_type => {
                            const proof = snapshot_codec.decodeBare(record.payload, DispatchProof) catch return error.DurableDispatchUnavailable;
                            const index = candidate.uncertainIndex(proof.origin, proof.context.account, proof.command.command_id) orelse return error.DurableDispatchUnavailable;
                            const attempt = candidate.uncertain_dispatches[index];
                            if (attempt.reconciliation_id != 0 or attempt.recovered_proof == null or
                                !std.meta.eql(attempt.recovered_proof.?, proof)) return error.DurableDispatchUnavailable;
                            candidate.uncertain_dispatch_count -= 1;
                            std.mem.copyForwards(UncertainDispatch, candidate.uncertain_dispatches[index..candidate.uncertain_dispatch_count], candidate.uncertain_dispatches[index + 1 .. candidate.uncertain_dispatch_count + 1]);
                            candidate.restoreAcceptedDispatch(proof) catch return error.DurableDispatchUnavailable;
                        },
                        archive_record_type => {
                            const commit = snapshot_codec.decodeBare(record.payload, DispatchArchiveCommit) catch return error.DurableDispatchUnavailable;
                            try candidate.applyDispatchArchive(commit);
                        },
                        economic_history_record_type => {
                            const commit = snapshot_codec.decodeBare(record.payload, EconomicHistoryCommit) catch return error.DurableDispatchUnavailable;
                            try candidate.applyEconomicHistory(commit);
                        },
                        else => return error.DurableDispatchUnavailable,
                    }
                },
            };
        }
        if (last_committed_sequence != recovered.committed_barrier) return error.DurableDispatchUnavailable;
        candidate.durable_dispatch = .{ .store = store, .io = io, .stream = stream, .namespace = snapshot.namespace, .next_sequence = std.math.add(u64, recovered.last_sequence, 1) catch return error.DurableDispatchUnavailable };
        @memcpy(std.mem.asBytes(self), std.mem.asBytes(candidate));
    }

    fn dispatchCount(self: *const Gateway) usize {
        return @as(usize, self.accepted_dispatch_count) + self.uncertain_dispatch_count;
    }

    fn markUncertain(self: *Gateway, proof: DispatchProof) !void {
        const account = proof.context.account;
        const command_id = proof.command.command_id;
        if (self.uncertainIndex(proof.origin, account, command_id) != null) return;
        if (dispatchBudgetFull(self.accepted_dispatch_count, self.uncertain_dispatch_count)) return error.DispatchCapacity;
        self.uncertain_dispatches[self.uncertain_dispatch_count] = .{ .origin = proof.origin, .account = account, .command_id = command_id, .client_order_id = proof.command.client_order_id, .prior_reconciliation_id = proof.prior_reconciliation_id, .recovered_proof = proof };
        self.uncertain_dispatch_count += 1;
    }

    fn uncertainIndex(self: *const Gateway, origin: DispatchOrigin, account: canonical.ExchangeAccountIdentity, command_id: u64) ?usize {
        for (self.uncertain_dispatches[0..self.uncertain_dispatch_count], 0..) |known, index|
            if (std.meta.eql(known.origin, origin) and known.account == account and known.command_id == command_id) return index;
        return null;
    }

    /// Only an OMS-applied authoritative reconciliation can close a recovered
    /// Unknown. The durable identity remains a tombstone: it can never resend.
    pub fn reconcileRecoveredDispatch(self: *Gateway, shard: *const trading.TradingShard, command_id: u64) !void {
        const committed = self.durable_dispatch orelse return error.DurableDispatchUnavailable;
        if (committed.store.safetyGate() != .open or shard.exchange_account_identity == 0)
            return error.DurableDispatchUnavailable;
        const route = self.routeFor(shard.exchange_account_identity) orelse return error.UnknownDispatch;
        const origin = try sourceOrigin(shard, route.environment == .simulation);
        const index = self.uncertainIndex(origin, shard.exchange_account_identity, command_id) orelse return error.UnknownDispatch;
        var command_value: ?oms.Command = null;
        for (shard.oms.command_history[0..shard.oms.command_history_count]) |known|
            if (known.command_id == command_id) {
                command_value = known;
                break;
            };
        const oms_command = command_value orelse return error.UnknownDispatch;
        if (oms_command.authority.exchange_account != shard.exchange_account_identity or
            oms_command.authority.virtual_portfolio != shard.portfolio_identity)
            return error.UnknownDispatch;
        const order = shard.oms.orderById(oms_command.order_id) orelse return error.UnreconciledDispatch;
        if (order.last_reconciliation_id <= self.uncertain_dispatches[index].prior_reconciliation_id or
            order.last_reconciliation_status == .unresolved or
            order.last_reconciliation_revision < oms_command.revision or
            switch (order.last_reconciliation_status) {
                .found_live => order.state != .live and order.state != .partially_filled,
                .found_terminal, .confirmed_absent => order.state != .filled and order.state != .canceled and order.state != .rejected,
                .unresolved => true,
            }) return error.UnreconciledDispatch;
        if (self.uncertain_dispatches[index].reconciliation_id != 0) {
            if (self.uncertain_dispatches[index].reconciliation_id == order.last_reconciliation_id and
                self.uncertain_dispatches[index].reconciliation_status == order.last_reconciliation_status) return;
            return error.ConflictingDispatchResolution;
        }
        const resolution: DispatchResolution = .{
            .origin = origin,
            .account = shard.exchange_account_identity,
            .command_id = command_id,
            .reconciliation_id = order.last_reconciliation_id,
            .status = order.last_reconciliation_status,
        };
        var payload_buffer: [trading.journal.max_payload_size]u8 = undefined;
        const payload = snapshot_codec.encodeBare(&payload_buffer, resolution) catch return error.DurableDispatchUnavailable;
        committed.store.append(committed.io, .{ .stream = committed.stream, .record = .{
            .type_id = resolution_record_type,
            .schema_version = production_contract.journal_schema_version,
            .flags = 0,
            .sequence = committed.next_sequence,
            .source_time = 0,
            .receive_time = 0,
            .monotonic_time = 0,
            .wall_time = 0,
            .time_presence = .{},
            .payload = payload,
        } }) catch {
            self.latchAccount(shard.exchange_account_identity);
            return error.DurableDispatchUnavailable;
        };
        committed.store.commit(committed.io, committed.stream, committed.next_sequence) catch {
            self.latchAccount(shard.exchange_account_identity);
            return error.DurableDispatchUnavailable;
        };
        self.durable_dispatch.?.next_sequence = std.math.add(u64, committed.next_sequence, 1) catch {
            self.latchAccount(shard.exchange_account_identity);
            return error.DurableDispatchUnavailable;
        };
        self.uncertain_dispatches[index].reconciliation_id = resolution.reconciliation_id;
        self.uncertain_dispatches[index].reconciliation_status = resolution.status;
    }
    pub fn add(self: *Gateway, route: Route) !void {
        for (self.routes[0..self.count]) |existing|
            if (existing.account == route.account) return error.DuplicateAccountRoute;
        if (self.count == self.routes.len) return error.RouteCapacity;
        self.routes[self.count] = route;
        self.count += 1;
    }

    /// Replaces the latest account authority and upserts the command-scoped
    /// reservation and instrument position that the Gateway will re-read at send.
    pub fn observeAuthority(self: *Gateway, facts: AuthorityFacts) !void {
        return self.observeAuthorityForOrigin(.{}, facts);
    }

    pub fn observeAuthorityFromShard(self: *Gateway, shard: *const trading.TradingShard, facts: AuthorityFacts) !void {
        if (facts.account != shard.exchange_account_identity or
            facts.effective_trading_authority != shard.operational_state.effectiveTradingAuthority() or
            !std.meta.eql(facts.exchange_position, shard.currentNetExchangePosition(facts.exchange_position.instrument) orelse return error.InvalidAuthorityFacts)) return error.InvalidAuthorityFacts;
        const route = self.routeFor(facts.account) orelse return error.UnknownAccount;
        const origin = try sourceOrigin(shard, route.environment == .simulation);
        if (self.originAuthorityIndex(origin)) |index| {
            const current = self.origin_authority[index].authority;
            if (shard.authoritativeBarrier() < self.origin_authority[index].source_barrier or facts.authority_barrier < current.authority_barrier or facts.fencing_token < current.fencing_token) return error.StaleAuthorityFacts;
        }
        const previous_source_barrier = if (self.originAuthorityIndex(origin)) |index| self.origin_authority[index].source_barrier else 0;
        // Permission caches follow the verified current source; dispatch evidence remains pinned independently.
        var index: usize = 0;
        while (index < self.reservation_count) {
            const fact = self.reservations[index];
            if (std.meta.eql(fact.origin, origin) and (fact.barrier < facts.authority_barrier or shard.authoritativeBarrier() > previous_source_barrier)) {
                self.removeReservation(origin, fact.identity);
            } else index += 1;
        }
        index = 0;
        while (index < self.exchange_position_count) {
            const fact = self.exchange_positions[index];
            if (std.meta.eql(fact.origin, origin) and (fact.barrier < facts.authority_barrier or shard.authoritativeBarrier() > previous_source_barrier)) {
                self.exchange_position_count -= 1;
                std.mem.copyForwards(ExchangePositionFact, self.exchange_positions[index..self.exchange_position_count], self.exchange_positions[index + 1 .. self.exchange_position_count + 1]);
            } else index += 1;
        }
        try self.observeAuthorityForOrigin(origin, facts);
        self.origin_authority[self.originAuthorityIndex(origin).?].source_barrier = shard.authoritativeBarrier();
    }

    fn observeAuthorityForOrigin(self: *Gateway, origin: DispatchOrigin, facts: AuthorityFacts) !void {
        const route_index = self.routeIndex(facts.account) orelse return error.UnknownAccount;
        if (facts.reservation_identity == 0 or facts.fencing_token == 0 or facts.authority_barrier == 0 or
            facts.exchange_position.instrument == 0 or facts.exchange_position.rules_version == 0)
            return error.InvalidAuthorityFacts;
        const origin_index = self.originAuthorityIndex(origin);
        if (origin.account != 0 and origin_index == null and self.origin_authority_count == self.origin_authority.len) return error.AuthorityCapacity;
        const current = if (origin.account == 0) self.account_authority[route_index] else if (origin_index) |index| self.origin_authority[index].authority else AccountAuthority{};
        const next_authority: AccountAuthority = .{
            .effective_trading_authority = facts.effective_trading_authority,
            .primary_lease_expires_at_monotonic_ns = facts.primary_lease_expires_at_monotonic_ns,
            .fencing_token = facts.fencing_token,
            .authority_barrier = facts.authority_barrier,
        };
        if (facts.authority_barrier < current.authority_barrier or facts.fencing_token < current.fencing_token)
            return error.StaleAuthorityFacts;
        if (facts.authority_barrier == current.authority_barrier and current.authority_barrier != 0 and
            !std.meta.eql(current, next_authority))
            return error.ConflictingAuthorityFacts;

        const reservation_index = self.reservationIndex(origin, facts.account, facts.reservation_identity);
        const position_index = self.exchangePositionIndex(origin, facts.account, facts.exchange_position.instrument);
        if (reservation_index == null and atCapacity(self.reservation_count, self.reservations.len))
            return error.AuthorityCapacity;
        if (position_index == null and atCapacity(self.exchange_position_count, self.exchange_positions.len))
            return error.AuthorityCapacity;
        if (reservation_index) |index| {
            const known = self.reservations[index];
            if (facts.authority_barrier < known.barrier or
                (facts.authority_barrier == known.barrier and !std.meta.eql(known.amount, facts.reservation)))
                return error.ConflictingAuthorityFacts;
        }
        if (position_index) |index| {
            const known = self.exchange_positions[index];
            if (facts.authority_barrier < known.barrier or
                (facts.authority_barrier == known.barrier and !std.meta.eql(known.quantity, facts.exchange_position)))
                return error.ConflictingAuthorityFacts;
        }

        if (origin.account == 0) {
            self.account_authority[route_index] = next_authority;
        } else if (origin_index) |index| {
            self.origin_authority[index].authority = next_authority;
        } else {
            self.origin_authority[self.origin_authority_count] = .{ .origin = origin, .authority = next_authority };
            self.origin_authority_count += 1;
        }
        if (reservation_index) |index| {
            self.reservations[index].amount = facts.reservation;
            self.reservations[index].barrier = facts.authority_barrier;
        } else {
            self.reservations[self.reservation_count] = .{ .origin = origin, .account = facts.account, .identity = facts.reservation_identity, .amount = facts.reservation, .barrier = facts.authority_barrier };
            self.reservation_count += 1;
        }
        if (position_index) |index| {
            self.exchange_positions[index].quantity = facts.exchange_position;
            self.exchange_positions[index].barrier = facts.authority_barrier;
        } else {
            self.exchange_positions[self.exchange_position_count] = .{ .origin = origin, .account = facts.account, .quantity = facts.exchange_position, .barrier = facts.authority_barrier };
            self.exchange_position_count += 1;
        }
    }

    /// Rehydrates a durable accepted dispatch during recovery. Replaying its
    /// proof returns the accepted result without crossing the adapter again.
    fn restoreAcceptedDispatch(self: *Gateway, proof: DispatchProof) !void {
        const account = proof.context.account;
        const command_id = proof.command.command_id;
        if (self.routeIndex(account) == null) return error.UnknownAccount;
        if (command_id == 0) return error.InvalidDispatchIdentity;
        if (self.acceptedDispatchIndex(proof.origin, account, command_id)) |index| {
            if (!std.meta.eql(self.accepted_dispatches[index].proof, proof)) return error.DispatchIdentityConflict;
            return;
        }
        if (dispatchBudgetFull(self.accepted_dispatch_count, self.uncertain_dispatch_count)) return error.DispatchCapacity;
        self.accepted_dispatches[self.accepted_dispatch_count] = .{ .origin = proof.origin, .account = account, .command_id = command_id, .proof = proof };
        self.accepted_dispatch_count += 1;
    }

    /// The public order path takes an actual shard outbox identity. The caller
    /// cannot supply missing capability, rules, config, lease or deadline data.
    pub fn sendFromShard(self: *Gateway, shard: *const trading.TradingShard, command_id: u64, now_monotonic_ns: u64) !venue.SendResult {
        const committed = self.durable_dispatch orelse return error.NotSent;
        if (committed.store.safetyGate() != .open or now_monotonic_ns == 0)
            return error.NotSent;
        var command_value: ?oms.Command = null;
        for (shard.oms.command_history[0..shard.oms.command_history_count]) |known| {
            if (known.command_id == command_id) {
                command_value = known;
                break;
            }
        }
        const oms_command = command_value orelse return error.NotSent;
        const active_assets = shard.activatedAssets();
        if (oms_command.operation != .cancel) for (active_assets.entries[0..active_assets.count]) |entry| {
            if (entry.barrier > oms_command.risk_decision_identity) return error.NotSent;
        };
        if ((shard.economic_fault_count != 0 or shard.recovery_admission_pending or shard.oms.recovery_only or
            shard.asset_configuration_failed or !shard.settlementConsumersCompatible(oms_command.instrument)) and oms_command.operation != .cancel) return error.NotSent;
        const refs = oms_command.authority;
        if (!refs.complete() or refs.exchange_account != shard.exchange_account_identity or
            refs.virtual_portfolio != shard.portfolio_identity or refs.deadline_barrier > shard.authoritativeBarrier() or
            oms_command.risk_decision_identity == 0 or oms_command.reservation_identity == 0 or
            oms_command.risk_decision_identity >= oms_command.reservation_identity or oms_command.reservation_identity > shard.authoritativeBarrier())
            return error.NotSent;
        const decision = shard.trace.factAt(oms_command.risk_decision_identity) orelse return error.NotSent;
        const reservation_fact = shard.trace.factAt(oms_command.reservation_identity) orelse return error.NotSent;
        if (decision.kind != .risk_accepted or reservation_fact.kind != .risk_reservation_created or
            decision.identity != oms_command.intent_sequence or reservation_fact.identity != oms_command.intent_sequence)
            return error.NotSent;
        const order = shard.oms.orderById(oms_command.order_id) orelse return error.NotSent;
        if (order.revision != oms_command.revision or order.instrument != oms_command.instrument or
            order.predecessor_order_id != oms_command.predecessor_order_id or
            order.state != switch (oms_command.operation) {
                .place => oms.OrderState.pending_submit,
                .amend => oms.OrderState.pending_amend,
                .cancel => oms.OrderState.pending_cancel,
            } or
            (oms_command.operation != .cancel and (!order.reservation_active or
                !std.meta.eql(order.reservation, oms_command.reservation))))
            return error.NotSent;
        const latest = shard.currentDispatchAuthorityRefs(oms_command.instrument) catch return error.NotSent;
        if (!std.meta.eql(refs.trading_authorization, latest.trading_authorization) or
            !std.meta.eql(refs.primary_lease, latest.primary_lease) or
            !std.meta.eql(refs.risk_lease, latest.risk_lease) or
            !std.meta.eql(refs.capability, latest.capability) or
            !std.meta.eql(refs.instrument_rules, latest.instrument_rules) or
            !std.meta.eql(refs.margin_rules, latest.margin_rules) or
            !std.meta.eql(refs.instrument_trading, latest.instrument_trading) or
            !std.meta.eql(refs.config, latest.config) or
            refs.adapter_session != latest.adapter_session)
            return error.NotSent;
        const route_index = self.routeIndex(refs.exchange_account) orelse return error.NotSent;
        const route = &self.routes[route_index];
        const instrument = shard.registryInstrument(oms_command.instrument) orelse return error.NotSent;
        if (route.supported_products != 0 and route.supported_products & productMask(instrument.product) == 0)
            return error.NotSent;
        if (oms_command.operation != .cancel and !oms_command.portfolio_reduce_only) {
            const market = shard.canonical_market.get(oms_command.instrument) orelse return error.NotSent;
            if (market.health != .healthy) return error.NotSent;
        }
        if (oms_command.operation != .cancel) {
            if (!instrument.trading_enabled) return error.NotSent;
            const native_cash = shard.currentNativeRiskCash(oms_command.instrument) catch return error.NotSent;
            const committed_requirement = std.math.add(i128, shard.activeReservationAtoms() catch return error.NotSent, shard.economic_projection.exchange.margin_atoms) catch return error.NotSent;
            if (native_cash < @max(committed_requirement, oms_command.reservation.atoms)) return error.NotSent;
        }
        if (route.environment == .demo and instrument.product == .spot and instrument.rules.base_asset == 0)
            return error.NotSent;
        const profile = instrument.capability orelse return error.NotSent;
        if (route.venue_identity == 0 or route.venue_identity != profile.venue or
            route.environment != profile.environment or route.capability.version != profile.version or
            route.capability.config_version != profile.config_version or route.capability.session != profile.adapter_session or
            (profile.supports_place and !route.capability.supports_place) or
            (profile.supports_cancel and !route.capability.supports_cancel) or
            (profile.supports_native_amend and !route.capability.supports_native_amend) or
            (profile.supports_venue_reduce_only and !route.capability.supports_venue_reduce_only) or
            (profile.supports_post_only and !route.capability.supports_post_only) or
            (profile.supports_market_protection and !route.capability.supports_market_protection))
            return error.NotSent;
        const origin = sourceOrigin(shard, route.environment == .simulation) catch return error.NotSent;
        if (self.archiveBindingIndex(origin)) |binding_index| {
            const current_root = shard.business_history_root orelse return error.NotSent;
            const bound = self.archive_bindings[binding_index].root;
            if (!std.meta.eql(current_root.origin, bound.origin) or current_root.generation < bound.generation or
                current_root.barrier < bound.barrier or (current_root.generation == bound.generation and !std.meta.eql(current_root, bound)))
                return error.NotSent;
        }
        const authority_index = self.originAuthorityIndex(origin) orelse return error.NotSent;
        const authority = self.origin_authority[authority_index].authority;
        if (authority.effective_trading_authority != shard.operational_state.effectiveTradingAuthority())
            return error.NotSent;
        const observed_position_index = self.exchangePositionIndex(origin, refs.exchange_account, oms_command.instrument) orelse return error.NotSent;
        const source_position = shard.currentNetExchangePosition(oms_command.instrument) orelse return error.NotSent;
        if (!std.meta.eql(self.exchange_positions[observed_position_index].quantity, source_position))
            return error.NotSent;
        const increases_risk = oms_command.operation != .cancel and
            !genuinelyReduces(source_position.lots, oms_command.side, oms_command.quantity);
        if (increases_risk and (shard.pending_history_candidate != null or shard.pending_safety_history_candidate != null or shard.deferred_history_admission_count != 0 or shard.oms.capacity_pressure)) return error.NotSent;
        if (increases_risk and (shard.risk_lease_atoms <= 0 or
            shard.risk_lease_valid_through_barrier < shard.authoritativeBarrier()))
            return error.NotSent;
        const token = std.math.cast(u64, refs.primary_lease.identity) orelse return error.NotSent;
        if (token == 0 or token != authority.fencing_token or authority.authority_barrier == 0 or
            now_monotonic_ns > refs.dispatch_deadline_monotonic_ns or
            now_monotonic_ns > authority.primary_lease_expires_at_monotonic_ns)
            return error.NotSent;
        if (route.environment != .simulation and route.lease_guard == null) return error.NotSent;
        if (route.lease_guard) |guard| {
            if (guard.lease.key.exchange_account != refs.exchange_account) return error.NotSent;
            if (!guard.lease.valid(now_monotonic_ns)) return error.NotSent;
            guard.check(now_monotonic_ns, token, increases_risk) catch return error.NotSent;
        }
        var proof: DispatchProof = .{
            .origin = origin,
            .context = .{
                .account = refs.exchange_account,
                .capability_version = refs.capability.version,
                .rules_version = refs.instrument_rules.version,
                .config_version = refs.config.version,
                .adapter_session = refs.adapter_session,
                .dispatch_deadline_monotonic_ns = refs.dispatch_deadline_monotonic_ns,
            },
            .command = oms_command,
            .fencing_token = token,
            .authority_barrier = authority.authority_barrier,
            .now_monotonic_ns = now_monotonic_ns,
            .prior_reconciliation_id = order.last_reconciliation_id,
        };
        proof.command.client_order_id = route.adapter.prepareClientOrderId(
            originNamespace(committed.namespace, origin),
            refs.exchange_account,
            oms_command.order_id,
            oms_command.client_order_id,
        ) catch return error.NotSent;
        if (proof.command.client_order_id.len == 0) return error.NotSent;
        if (self.acceptedDispatchIndex(origin, refs.exchange_account, command_id) != null) return self.sendProofInternal(proof);
        for (self.uncertain_dispatches[0..self.uncertain_dispatch_count]) |uncertain|
            if (std.meta.eql(uncertain.origin, origin) and uncertain.account == refs.exchange_account and uncertain.command_id == command_id) return error.NotSent;
        if (dispatchBudgetFull(self.accepted_dispatch_count, self.uncertain_dispatch_count)) return error.NotSent;
        var payload_buffer: [trading.journal.max_payload_size]u8 = undefined;
        const payload = snapshot_codec.encodeBare(&payload_buffer, proof) catch return error.NotSent;
        committed.store.append(committed.io, .{ .stream = committed.stream, .record = .{
            .type_id = dispatch_record_type,
            .schema_version = production_contract.journal_schema_version,
            .flags = 0,
            .sequence = committed.next_sequence,
            .source_time = 0,
            .receive_time = 0,
            .monotonic_time = now_monotonic_ns,
            .wall_time = 0,
            .time_presence = .{ .monotonic = true },
            .payload = payload,
        } }) catch {
            self.latchAccount(refs.exchange_account);
            return error.NotSent;
        };
        committed.store.commit(committed.io, committed.stream, committed.next_sequence) catch {
            self.latchAccount(refs.exchange_account);
            try self.markUncertain(proof);
            return error.NotSent;
        };
        self.durable_dispatch.?.next_sequence = std.math.add(u64, committed.next_sequence, 1) catch {
            self.latchAccount(refs.exchange_account);
            return error.NotSent;
        };
        const result = self.sendProofInternal(proof) catch {
            try self.markUncertain(proof);
            return error.NotSent;
        };
        if (result == .accepted) {
            self.commitDispatchRecord(accepted_record_type, proof.now_monotonic_ns, payload) catch {
                const index = self.acceptedDispatchIndex(origin, refs.exchange_account, command_id).?;
                self.accepted_dispatch_count -= 1;
                std.mem.copyForwards(AcceptedDispatch, self.accepted_dispatches[index..self.accepted_dispatch_count], self.accepted_dispatches[index + 1 .. self.accepted_dispatch_count + 1]);
                self.latchAccount(refs.exchange_account);
                try self.markUncertain(proof);
                return error.NotSent;
            };
        } else try self.markUncertain(proof);
        return result;
    }

    fn commitDispatchRecord(self: *Gateway, type_id: u16, now_monotonic_ns: u64, payload: []const u8) !void {
        const committed = self.durable_dispatch.?;
        try committed.store.append(committed.io, .{ .stream = committed.stream, .record = .{
            .type_id = type_id,
            .schema_version = production_contract.journal_schema_version,
            .flags = 0,
            .sequence = committed.next_sequence,
            .source_time = 0,
            .receive_time = 0,
            .monotonic_time = now_monotonic_ns,
            .wall_time = 0,
            .time_presence = .{ .monotonic = true },
            .payload = payload,
        } });
        try committed.store.commit(committed.io, committed.stream, committed.next_sequence);
        self.durable_dispatch.?.next_sequence = try std.math.add(u64, committed.next_sequence, 1);
    }
    fn sendUnprovedForContractTest(self: *Gateway, request: canonical.OrderCommand) !venue.SendResult {
        const route = self.routeFor(request.exchange_account) orelse return error.UnknownAccount;
        try self.validateOrder(route, request, false);
        return self.sendRequestForRoute(route, .{ .order_command = request });
    }

    /// Converts a qualified OMS outbox item once at the execution boundary.
    fn sendOms(self: *Gateway, context: OmsDispatchContext, command_value: oms.Command) !venue.SendResult {
        const route = self.routeFor(context.account) orelse return error.UnknownAccount;
        if (command_value.limit_price.rules_version != context.rules_version) return error.Rejected;
        const request: canonical.OrderCommand = .{
            .identity = command_value.command_id,
            .exchange_account = context.account,
            .instrument = command_value.instrument,
            .client_order_id = command_value.client_order_id,
            .capability_version = context.capability_version,
            .rules_version = context.rules_version,
            .config_version = context.config_version,
            .adapter_session = context.adapter_session,
            .dispatch_deadline_monotonic_ns = context.dispatch_deadline_monotonic_ns,
            .operation = switch (command_value.operation) {
                .place => .place,
                .amend => .amend,
                .cancel => .cancel,
            },
            .side = if (command_value.side == .buy) .buy else .sell,
            .revision = command_value.revision,
            .portfolio_reduce_only = command_value.portfolio_reduce_only,
            .venue_reduce_only = command_value.venue_reduce_only,
            .order_type = command_value.order_type,
            .time_in_force = command_value.time_in_force,
            .quantity = if (command_value.operation == .cancel) null else .{ .instrument = command_value.instrument, .rules_version = command_value.limit_price.rules_version, .lots = command_value.quantity },
            .limit_price = if (command_value.operation == .cancel or command_value.order_type == .market) null else command_value.limit_price,
            .market_protection_price = command_value.market_protection_price,
            // The simulated/core boundary knows zero fees explicitly. Venue
            // adapters must replace this with the authoritative charged fee.
            .fee_asset = command_value.reservation.asset,
            .fee_atoms = 0,
        };
        try self.validateOrder(route, request, true);
        return self.sendRequestForRoute(route, .{ .order_command = request });
    }

    /// The sole business-order boundary. Every mutable authority dependency is
    /// rechecked immediately before the VenueAdapter external effect.
    /// Legacy caller-built proofs remain representable during expand but can
    /// never cross the public business-order send boundary.
    pub fn sendProof(_: *Gateway, _: DispatchProof) !venue.SendResult {
        return error.OrderProofRequired;
    }

    fn sendProofInternal(self: *Gateway, proof: DispatchProof) !venue.SendResult {
        const command_value = proof.command;
        for (self.uncertain_dispatches[0..self.uncertain_dispatch_count]) |uncertain|
            if (std.meta.eql(uncertain.origin, proof.origin) and uncertain.account == proof.context.account and uncertain.command_id == command_value.command_id)
                return error.NotSent;
        if (self.acceptedDispatchIndex(proof.origin, proof.context.account, command_value.command_id)) |index| {
            if (!std.meta.eql(self.accepted_dispatches[index].proof, proof)) return error.NotSent;
            return .accepted;
        }
        if (dispatchBudgetFull(self.accepted_dispatch_count, self.uncertain_dispatch_count)) return error.NotSent;
        const route_index = self.routeIndex(proof.context.account) orelse return error.NotSent;
        const authority = if (proof.origin.account == 0) self.account_authority[route_index] else self.origin_authority[self.originAuthorityIndex(proof.origin) orelse return error.NotSent].authority;
        const reservation_index = self.reservationIndex(proof.origin, proof.context.account, command_value.reservation_identity) orelse return error.NotSent;
        const position_index = self.exchangePositionIndex(proof.origin, proof.context.account, command_value.instrument) orelse return error.NotSent;
        const reservation = self.reservations[reservation_index].amount;
        const exchange_position = self.exchange_positions[position_index].quantity;
        const route = &self.routes[route_index];
        if (route.environment != .simulation and route.lease_guard == null) return error.NotSent;
        if (route.lease_guard) |guard| {
            if (guard.lease.key.exchange_account != proof.context.account or !guard.lease.valid(proof.now_monotonic_ns))
                return error.NotSent;
            guard.check(proof.now_monotonic_ns, proof.fencing_token, command_value.operation != .cancel and
                !genuinelyReduces(exchange_position.lots, command_value.side, command_value.quantity)) catch return error.NotSent;
        }
        if (command_value.intent_sequence == 0 or command_value.risk_decision_identity == 0 or command_value.reservation_identity == 0 or
            command_value.order_id == 0 or command_value.revision == 0 or command_value.client_order_id.len == 0 or
            proof.authority_barrier == 0 or proof.authority_barrier != authority.authority_barrier or
            self.reservations[reservation_index].barrier != authority.authority_barrier or
            self.exchange_positions[position_index].barrier != authority.authority_barrier or
            proof.fencing_token == 0 or proof.fencing_token != authority.fencing_token or
            proof.now_monotonic_ns > proof.context.dispatch_deadline_monotonic_ns or
            proof.now_monotonic_ns > authority.primary_lease_expires_at_monotonic_ns or
            exchange_position.instrument != command_value.instrument or
            exchange_position.rules_version != command_value.limit_price.rules_version)
            return error.NotSent;
        const reducing = genuinelyReduces(exchange_position.lots, command_value.side, command_value.quantity);
        if (command_value.operation != .cancel and
            ((!authority.effective_trading_authority or self.routes[route_index].safety_gate == .latched or self.instrumentGapped(command_value.instrument) or
                command_value.portfolio_reduce_only or command_value.venue_reduce_only) and !reducing))
            return error.NotSent;
        if (command_value.operation != .cancel and
            (reservation.asset != command_value.reservation.asset or reservation.atoms != command_value.reservation.atoms or reservation.atoms <= 0))
            return error.NotSent;
        const result = self.sendOms(proof.context, command_value) catch return error.NotSent;
        if (result == .accepted) {
            self.accepted_dispatches[self.accepted_dispatch_count] = .{ .origin = proof.origin, .account = proof.context.account, .command_id = command_value.command_id, .proof = proof };
            self.accepted_dispatch_count += 1;
        }
        return result;
    }

    /// Sends a non-order request through the same account-owned route.  Only
    /// the canonical request crosses this seam; replay callers never own a
    /// Gateway and therefore cannot send anything.
    pub fn sendRequest(self: *Gateway, request: canonical.AdapterRequest) !venue.SendResult {
        switch (request) {
            .order_command, .order_batch => return error.OrderProofRequired,
            else => {},
        }
        const account = switch (request) {
            .order_reconciliation => |reconciliation| reconciliation.exchange_account,
            .account_reconciliation => |reconciliation| reconciliation.exchange_account,
            .order_command, .order_batch => unreachable,
        };
        const route = self.routeFor(account) orelse return error.UnknownAccount;
        return self.sendRequestForRoute(route, request);
    }

    fn routeFor(self: *Gateway, account: canonical.ExchangeAccountIdentity) ?*Route {
        for (self.routes[0..self.count]) |*route_value|
            if (route_value.account == account) return route_value;
        return null;
    }

    fn routeIndex(self: *const Gateway, account: canonical.ExchangeAccountIdentity) ?usize {
        for (self.routes[0..self.count], 0..) |route, index|
            if (route.account == account) return index;
        return null;
    }

    fn originAuthorityIndex(self: *const Gateway, origin: DispatchOrigin) ?usize {
        for (self.origin_authority[0..self.origin_authority_count], 0..) |entry, index| if (std.meta.eql(entry.origin, origin)) return index;
        return null;
    }
    fn reservationIndex(self: *const Gateway, origin: DispatchOrigin, account: canonical.ExchangeAccountIdentity, identity: u64) ?usize {
        for (self.reservations[0..self.reservation_count], 0..) |fact, index|
            if (std.meta.eql(fact.origin, origin) and fact.account == account and fact.identity == identity) return index;
        return null;
    }

    fn exchangePositionIndex(self: *const Gateway, origin: DispatchOrigin, account: canonical.ExchangeAccountIdentity, instrument: canonical.InstrumentIdentity) ?usize {
        for (self.exchange_positions[0..self.exchange_position_count], 0..) |fact, index|
            if (std.meta.eql(fact.origin, origin) and fact.account == account and fact.quantity.instrument == instrument) return index;
        return null;
    }

    fn acceptedDispatchIndex(self: *const Gateway, origin: DispatchOrigin, account: canonical.ExchangeAccountIdentity, command_id: u64) ?usize {
        for (self.accepted_dispatches[0..self.accepted_dispatch_count], 0..) |dispatch, index|
            if (std.meta.eql(dispatch.origin, origin) and dispatch.account == account and dispatch.command_id == command_id) return index;
        return null;
    }

    pub fn acceptedClientOrderId(self: *const Gateway, account: canonical.ExchangeAccountIdentity, command_id: u64) ?canonical.ClientOrderId {
        var found: ?canonical.ClientOrderId = null;
        for (self.accepted_dispatches[0..self.accepted_dispatch_count]) |entry| if (entry.account == account and entry.command_id == command_id) {
            if (found != null) return null;
            found = entry.proof.command.client_order_id;
        };
        return found;
    }

    pub fn acceptedClientOrderIdFromShard(self: *const Gateway, shard: *const trading.TradingShard, command_id: u64) ?canonical.ClientOrderId {
        const origin = sourceOrigin(shard, true) catch return null;
        const index = self.acceptedDispatchIndex(origin, shard.exchange_account_identity, command_id) orelse return null;
        return self.accepted_dispatches[index].proof.command.client_order_id;
    }

    pub fn exportOrderDispatchEvidence(self: *const Gateway, shard: *const trading.TradingShard, order_id: u64, destination: []DispatchEvidence) ![]const DispatchEvidence {
        const origin = try sourceOrigin(shard, false);
        _ = try shard.oms.prepareOrderArchive(order_id, try shard.economic_projection.appliedCanonicalFillQuantity(order_id), shard.exchange_account_identity);
        var count: usize = 0;
        for (self.accepted_dispatches[0..self.accepted_dispatch_count]) |entry| {
            if (!std.meta.eql(entry.origin, origin) or entry.proof.command.order_id != order_id) continue;
            if (count == destination.len) return error.DispatchCapacity;
            destination[count] = .{ .proof = entry.proof, .outcome = .accepted };
            count += 1;
        }
        for (self.uncertain_dispatches[0..self.uncertain_dispatch_count]) |entry| {
            if (!std.meta.eql(entry.origin, origin)) continue;
            const proof = entry.recovered_proof orelse return error.DispatchArchivePinned;
            if (proof.command.order_id != order_id) continue;
            if (entry.reconciliation_id == 0 or entry.reconciliation_status == null or entry.reconciliation_status == .unresolved) return error.DispatchArchivePinned;
            if (count == destination.len) return error.DispatchCapacity;
            destination[count] = .{ .proof = proof, .outcome = .resolved_unknown, .reconciliation_id = entry.reconciliation_id, .reconciliation_status = entry.reconciliation_status };
            count += 1;
        }
        return destination[0..count];
    }

    /// Complete the preceding root before Owner can replace its recovery receipt.
    pub fn completePreviousOrderArchive(self: *Gateway, shard: *const trading.TradingShard) !void {
        const archived = shard.last_order_archive orelse return;
        const origin = try sourceOrigin(shard, false);
        if (self.archiveBindingIndex(origin)) |index| {
            if (self.archive_bindings[index].last_order) |completed| {
                if (completed.order_id == archived.order_id and std.meta.eql(completed.origin, origin) and
                    std.meta.eql(completed.receipt, archived.receipt))
                {
                    const committed = self.durable_dispatch orelse return error.DurableDispatchUnavailable;
                    if (committed.next_sequence <= 1) return error.DurableDispatchUnavailable;
                    const persisted = try committed.store.recover(committed.io, committed.stream);
                    if (persisted.status != .ready or persisted.gate != .open or
                        persisted.last_sequence != committed.next_sequence - 1 or persisted.committed_barrier != persisted.last_sequence)
                        return error.DurableDispatchUnavailable;
                    if (persisted.segment_sealed) try self.checkpointDurableDispatch();
                    return;
                }
            }
        }
        try self.reclaimOrderDispatchEvidence(shard, archived.order_id);
    }

    /// Only the published Core economic commit can advance history without retiring dispatch evidence.
    pub fn acknowledgeEconomicHistory(self: *Gateway, shard: *const trading.TradingShard) !void {
        const origin = try sourceOrigin(shard, false);
        const root = shard.business_history_root orelse return error.EconomicHistoryNotCommitted;
        const record: EconomicHistoryCommit = switch (shard.last_business_archive_kind orelse return error.EconomicHistoryNotCommitted) {
            .order => return error.EconomicHistoryNotCommitted,
            .fill => blk: {
                const commit = shard.last_fill_archive orelse return error.EconomicHistoryNotCommitted;
                if (!std.meta.eql(root, commit.receipt.root)) return error.EconomicHistoryNotCommitted;
                break :blk .{ .origin = origin, .kind = .fill, .identity = commit.fill_id, .qualification_digest = commit.qualification_digest, .receipt = commit.receipt };
            },
            .forced => blk: {
                const commit = shard.last_forced_archive orelse return error.EconomicHistoryNotCommitted;
                if (!std.meta.eql(root, commit.receipt.root)) return error.EconomicHistoryNotCommitted;
                break :blk .{ .origin = origin, .kind = .forced, .identity = commit.forced_id, .qualification_digest = commit.qualification_digest, .receipt = commit.receipt };
            },
            .control => blk: {
                const commit = shard.last_control_archive orelse return error.EconomicHistoryNotCommitted;
                if (!std.meta.eql(root, commit.receipt.root)) return error.EconomicHistoryNotCommitted;
                break :blk .{ .origin = origin, .kind = .control, .identity = root.barrier, .qualification_digest = commit.qualification_digest, .receipt = commit.receipt };
            },
            .funding => blk: {
                const commit = shard.last_funding_archive orelse return error.EconomicHistoryNotCommitted;
                if (!std.meta.eql(root, commit.receipt.root)) return error.EconomicHistoryNotCommitted;
                break :blk .{ .origin = origin, .kind = .funding, .identity = commit.funding_id, .qualification_digest = commit.qualification_digest, .receipt = commit.receipt };
            },
            .reconciliation => blk: {
                const commit = shard.last_reconciliation_archive orelse return error.EconomicHistoryNotCommitted;
                if (!std.meta.eql(root, commit.receipt.root)) return error.EconomicHistoryNotCommitted;
                break :blk .{ .origin = origin, .kind = .reconciliation_window, .identity = commit.window_id, .qualification_digest = commit.qualification_digest, .receipt = commit.receipt };
            },
        };
        const previous_index = self.archiveBindingIndex(origin);
        const previous_count = self.archive_binding_count;
        const previous_binding: ?ArchiveBinding = if (previous_index) |index| self.archive_bindings[index] else null;
        const previous_dispatch = self.durable_dispatch orelse return error.DurableDispatchUnavailable;
        // This single-writer transition changes only one binding and its durable cursor.
        errdefer {
            self.archive_binding_count = previous_count;
            if (previous_index) |index| self.archive_bindings[index] = previous_binding.?;
            self.durable_dispatch = previous_dispatch;
        }
        const already_committed = previous_index != null and std.meta.eql(self.archive_bindings[previous_index.?].root, root);
        try self.applyEconomicHistory(record);
        if (!already_committed) {
            var payload_buffer: [trading.journal.max_payload_size]u8 = undefined;
            const payload = try snapshot_codec.encodeBare(&payload_buffer, record);
            try self.commitDispatchRecord(economic_history_record_type, 0, payload);
        }
        try self.checkpointDurableDispatch();
    }

    fn applyEconomicHistory(self: *Gateway, commit: EconomicHistoryCommit) !void {
        const origin = commit.origin;
        const root = commit.receipt.root;
        if (origin.decision_stream == 0 or origin.portfolio == 0 or origin.test_shard != 0 or commit.identity == 0 or
            origin.account != root.origin.account or origin.decision_stream != root.origin.stream.id or
            !std.mem.eql(u8, &commit.qualification_digest, &commit.receipt.qualification_digest)) return error.EconomicHistoryNotCommitted;
        if (commit.kind != .reconciliation_window and commit.identity > std.math.maxInt(u64)) return error.EconomicHistoryNotCommitted;
        const previous_index = self.archiveBindingIndex(origin);
        const previous: ?history.Root = if (previous_index) |index| self.archive_bindings[index].root else null;
        if (previous != null and std.meta.eql(previous.?, root)) {
            try history.validateRoot(root);
            if (!std.mem.eql(u8, &commit.receipt.previous_root, &root.previous_root) or
                !std.mem.eql(u8, &commit.qualification_digest, &root.qualification_digest) or
                !std.mem.eql(u8, &commit.receipt.batch_digest, &root.batch_digest)) return error.InvalidHistoryReceipt;
            return;
        }
        _ = try history.verifyReceipt(commit.receipt, root.origin, commit.qualification_digest, previous);
        if (previous_index == null and self.archive_binding_count == self.archive_bindings.len) return error.DispatchCapacity;
        const target = previous_index orelse self.archive_binding_count;
        const last_order = if (previous_index) |index| self.archive_bindings[index].last_order else null;
        if (previous_index == null) self.archive_binding_count += 1;
        self.archive_bindings[target] = .{ .origin = origin, .root = root, .last_order = last_order };
    }

    pub fn reclaimOrderDispatchEvidence(self: *Gateway, shard: *const trading.TradingShard, order_id: u64) !void {
        const origin = try sourceOrigin(shard, false);
        const commit = shard.last_order_archive orelse return error.DispatchArchiveNotCommitted;
        const root = shard.business_history_root orelse return error.DispatchArchiveNotCommitted;
        if (commit.order_id != order_id or !std.meta.eql(commit.receipt.root, root) or
            root.origin.stream.id != origin.decision_stream or root.origin.account != origin.account or
            !std.mem.eql(u8, &commit.qualification_digest, &commit.receipt.qualification_digest) or
            !std.mem.eql(u8, &commit.qualification_digest, &root.qualification_digest)) return error.DispatchArchiveNotCommitted;
        try history.validateRoot(root);
        const candidate = try std.heap.page_allocator.create(Gateway);
        defer std.heap.page_allocator.destroy(candidate);
        @memcpy(std.mem.asBytes(candidate), std.mem.asBytes(self));
        const record: DispatchArchiveCommit = .{ .origin = origin, .order_id = order_id, .receipt = commit.receipt };
        const previous_index = self.archiveBindingIndex(origin);
        const already_committed = previous_index != null and std.meta.eql(self.archive_bindings[previous_index.?].root, root);
        try candidate.applyDispatchArchive(record);
        if (!already_committed) {
            var payload_buffer: [trading.journal.max_payload_size]u8 = undefined;
            const payload = try snapshot_codec.encodeBare(&payload_buffer, record);
            try candidate.commitDispatchRecord(archive_record_type, 0, payload);
        }
        try candidate.checkpointDurableDispatch();
        @memcpy(std.mem.asBytes(self), std.mem.asBytes(candidate));
    }

    fn applyDispatchArchive(self: *Gateway, commit: DispatchArchiveCommit) !void {
        const origin = commit.origin;
        const order_id = commit.order_id;
        const root = commit.receipt.root;
        if (origin.decision_stream == 0 or order_id == 0 or origin.account != root.origin.account or origin.decision_stream != root.origin.stream.id or origin.test_shard != 0) return error.DispatchArchiveNotCommitted;
        const previous_index = self.archiveBindingIndex(origin);
        const previous: ?history.Root = if (previous_index) |index| self.archive_bindings[index].root else null;
        if (previous != null and std.meta.eql(previous.?, root)) {
            try history.validateRoot(root);
            if (!std.mem.eql(u8, &commit.receipt.previous_root, &root.previous_root) or
                !std.mem.eql(u8, &commit.receipt.qualification_digest, &root.qualification_digest) or
                !std.mem.eql(u8, &commit.receipt.batch_digest, &root.batch_digest)) return error.InvalidHistoryReceipt;
        } else _ = try history.verifyReceipt(commit.receipt, root.origin, root.qualification_digest, previous);
        const binding_index = self.archiveBindingIndex(origin);
        if (binding_index == null and self.archive_binding_count == self.archive_bindings.len) return error.DispatchCapacity;
        const target = binding_index orelse self.archive_binding_count;
        if (binding_index == null) self.archive_binding_count += 1;
        self.archive_bindings[target] = .{ .origin = origin, .root = root, .last_order = commit };
        var index: usize = 0;
        while (index < self.uncertain_dispatch_count) {
            const entry = self.uncertain_dispatches[index];
            if (!std.meta.eql(entry.origin, origin)) {
                index += 1;
                continue;
            }
            const proof = entry.recovered_proof orelse return error.DispatchArchivePinned;
            if (proof.command.order_id != order_id) {
                index += 1;
                continue;
            }
            if (entry.reconciliation_id == 0 or entry.reconciliation_status == null or entry.reconciliation_status == .unresolved) return error.DispatchArchivePinned;
            self.removeReservation(origin, proof.command.reservation_identity);
            self.uncertain_dispatch_count -= 1;
            std.mem.copyForwards(UncertainDispatch, self.uncertain_dispatches[index..self.uncertain_dispatch_count], self.uncertain_dispatches[index + 1 .. self.uncertain_dispatch_count + 1]);
        }
        index = 0;
        while (index < self.accepted_dispatch_count) {
            const entry = self.accepted_dispatches[index];
            if (!std.meta.eql(entry.origin, origin) or entry.proof.command.order_id != order_id) {
                index += 1;
                continue;
            }
            self.removeReservation(origin, entry.proof.command.reservation_identity);
            self.accepted_dispatch_count -= 1;
            std.mem.copyForwards(AcceptedDispatch, self.accepted_dispatches[index..self.accepted_dispatch_count], self.accepted_dispatches[index + 1 .. self.accepted_dispatch_count + 1]);
        }
        var referenced = false;
        for (self.reservations[0..self.reservation_count]) |entry| if (std.meta.eql(entry.origin, origin)) {
            referenced = true;
        };
        for (self.accepted_dispatches[0..self.accepted_dispatch_count]) |entry| if (std.meta.eql(entry.origin, origin)) {
            referenced = true;
        };
        for (self.uncertain_dispatches[0..self.uncertain_dispatch_count]) |entry| if (std.meta.eql(entry.origin, origin)) {
            referenced = true;
        };
        if (!referenced) {
            index = 0;
            while (index < self.exchange_position_count) {
                if (!std.meta.eql(self.exchange_positions[index].origin, origin)) {
                    index += 1;
                    continue;
                }
                self.exchange_position_count -= 1;
                std.mem.copyForwards(ExchangePositionFact, self.exchange_positions[index..self.exchange_position_count], self.exchange_positions[index + 1 .. self.exchange_position_count + 1]);
            }
        }
    }

    fn removeReservation(self: *Gateway, origin: DispatchOrigin, identity: u64) void {
        const index = self.reservationIndex(origin, origin.account, identity) orelse return;
        self.reservation_count -= 1;
        std.mem.copyForwards(ReservationFact, self.reservations[index..self.reservation_count], self.reservations[index + 1 .. self.reservation_count + 1]);
    }

    fn archiveBindingIndex(self: *const Gateway, origin: DispatchOrigin) ?usize {
        for (self.archive_bindings[0..self.archive_binding_count], 0..) |binding, index| if (std.meta.eql(binding.origin, origin)) return index;
        return null;
    }

    pub fn retryArchivedDispatch(self: *Gateway, shard: *const trading.TradingShard, request: history.LookupRequest, result: *const history.LookupResult) !venue.SendResult {
        const origin = sourceOrigin(shard, false) catch return error.NotSent;
        const root = shard.business_history_root orelse return error.NotSent;
        const command_key = request.key.identity == .dispatch_command;
        if ((request.key.identity != .client_order_id and !command_key) or request.key.origin.stream.id != origin.decision_stream or request.key.origin.account != origin.account) return error.NotSent;
        const verdict = history.verifyResult(request, &result.proof, root) catch return error.NotSent;
        if (verdict == .conflict) self.latchAccount(origin.account);
        if (verdict != .same) return error.NotSent;
        history.validateRecord(result) catch return error.NotSent;
        const evidence = snapshot_codec.decodeBare(result.record_bytes[0..result.record_len], DispatchEvidence) catch return error.NotSent;
        if (!validPersistedProof(evidence.proof) or !std.meta.eql(evidence.proof.origin, origin)) return error.NotSent;
        if (request.key.identity == .client_order_id) {
            if (!std.meta.eql(request.key.identity.client_order_id, evidence.proof.command.client_order_id)) return error.NotSent;
        } else {
            if (request.key.identity.dispatch_command != evidence.proof.command.command_id) return error.NotSent;
        }
        switch (evidence.outcome) {
            .accepted => if (evidence.reconciliation_id != 0 or evidence.reconciliation_status != null) return error.NotSent,
            .resolved_unknown => return error.NotSent,
        }
        return .accepted;
    }

    fn validateOrder(self: *const Gateway, route: *const Route, request: canonical.OrderCommand, instrument_rules_proven: bool) !void {
        if (request.operation != .cancel and !oms.exactOrderSpec(request.order_type, request.time_in_force, request.market_protection_price != null))
            return error.Rejected;
        const increasing = request.operation != .cancel and
            !(request.portfolio_reduce_only or request.venue_reduce_only);
        if (increasing and (route.safety_gate == .latched or self.instrumentGapped(request.instrument)))
            return error.Rejected;
        if (request.operation != .cancel and !route.capability.supports_place)
            return error.Rejected;
        if (request.operation == .cancel and !route.capability.supports_cancel) return error.Rejected;
        if (request.operation == .amend and !route.capability.supports_native_amend) return error.Rejected;
        if (request.venue_reduce_only and !route.capability.supports_venue_reduce_only) return error.Rejected;
        if ((request.order_type == .post_only or request.time_in_force == .post_only) and !route.capability.supports_post_only) return error.Rejected;
        if (request.market_protection_price != null and !route.capability.supports_market_protection) return error.Rejected;
        if (route.capability.version != request.capability_version or
            (!instrument_rules_proven and route.capability.rules_version != request.rules_version) or
            route.capability.config_version != request.config_version or
            route.capability.session != request.adapter_session)
            return error.Rejected;
    }

    fn sendRequestForRoute(self: *Gateway, route: *Route, request: canonical.AdapterRequest) !venue.SendResult {
        self.send_attempt_count += 1;
        return route.adapter.trySend(request) catch |err| {
            route.safety_gate = .latched;
            return err;
        };
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
                // A health notification is an observation, not continuity
                // proof. Only a validated L2 snapshot may reopen a gate.
                .healthy => {},
                .awaiting_snapshot, .gap => self.setInstrumentGap(health.instrument),
            },
            .l2_book_snapshot => |snapshot| self.setInstrumentGate(snapshot.instrument, .open),
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
        } else self.instrument_gate_capacity_exhausted = true;
    }
    fn instrumentGapped(self: *const Gateway, instrument: canonical.InstrumentIdentity) bool {
        for (self.instrument_gates[0..self.instrument_gate_count]) |gate| if (gate.instrument == instrument and gate.state == .blocked) return true;
        return self.instrument_gate_capacity_exhausted;
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

fn validPersistedProof(proof: DispatchProof) bool {
    const value = proof.command;
    return proof.origin.account == proof.context.account and proof.origin.portfolio == value.authority.virtual_portfolio and
        (proof.origin.decision_stream == 0 or proof.origin.test_shard == 0) and
        value.command_id != 0 and value.order_id != 0 and value.revision != 0 and value.intent_sequence != 0 and
        value.client_order_id.len > 0 and value.client_order_id.len <= value.client_order_id.bytes.len and value.authority.complete() and
        proof.context.account == value.authority.exchange_account and proof.context.capability_version == value.authority.capability.version and
        proof.context.rules_version == value.limit_price.rules_version and proof.context.rules_version == value.authority.instrument_rules.version and
        proof.context.config_version == value.authority.config.version and proof.context.adapter_session == value.authority.adapter_session and
        proof.context.dispatch_deadline_monotonic_ns == value.authority.dispatch_deadline_monotonic_ns and
        proof.fencing_token != 0 and proof.fencing_token == value.authority.primary_lease.identity and proof.authority_barrier != 0 and
        proof.now_monotonic_ns != 0 and proof.now_monotonic_ns <= proof.context.dispatch_deadline_monotonic_ns;
}

fn sourceOrigin(shard: *const trading.TradingShard, simulation: bool) !DispatchOrigin {
    if (shard.exchange_account_identity == 0 or shard.portfolio_identity == 0) return error.InvalidDispatchOrigin;
    if (shard.checkpoint) |checkpoint| {
        if (checkpoint.stream == 0) return error.InvalidDispatchOrigin;
        return .{ .decision_stream = checkpoint.stream, .account = shard.exchange_account_identity, .portfolio = shard.portfolio_identity };
    }
    if (!simulation) return error.InvalidDispatchOrigin;
    return .{ .account = shard.exchange_account_identity, .portfolio = shard.portfolio_identity, .test_shard = shard.host_activation_session.shard };
}

fn originNamespace(namespace: [namespace_size]u8, origin: DispatchOrigin) [namespace_size]u8 {
    var bytes: [128]u8 = undefined;
    const encoded = snapshot_codec.encodeBare(&bytes, .{ namespace, origin }) catch unreachable;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
    return digest[0..namespace_size].*;
}

fn genuinelyReduces(position: i128, side: oms.Side, quantity: i64) bool {
    if (quantity <= 0 or position == 0) return false;
    const after = std.math.add(i128, position, if (side == .buy) quantity else -@as(i128, quantity)) catch return false;
    if ((position > 0 and after < 0) or (position < 0 and after > 0)) return false;
    return if (position > 0) after < position else after > position;
}
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

const CountingSimulatedVenue = struct {
    implementation: @import("../adapters/simulated/simulated_venue.zig").SimulatedVenue = .{},
    sends: u64 = 0,
    outcome_fault_store: ?*durable.MemoryAdapter = null,

    fn adapter(self: *@This()) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.implementation.adapter().start(config);
    }
    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.sends += 1;
        const result = try self.implementation.adapter().trySend(request);
        if (result == .accepted) if (self.outcome_fault_store) |store| store.injectFaultAt(.eio, .commit);
        return result;
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.implementation.adapter().tryDrain();
    }
    fn stop(ptr: *anyopaque, deadline: venue.DrainDeadline) venue.StopError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.implementation.adapter().stop(deadline);
    }
};

test "Gateway checkpoint encodes only resident dispatch evidence" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    const stream: durable.StreamIdentity = .{ .domain = .control, .id = 978 };
    var bootstrap_buffer: [4096]u8 = undefined;
    try std.testing.expectError(error.DurableDispatchUnavailable, gateway.bootstrapDurableDispatchWithBuffer(memory.interface(), undefined, stream, bootstrap_buffer[0..1]));
    try std.testing.expect(gateway.durable_dispatch == null);
    try std.testing.expectEqual(durable.GateState.open, memory.interface().safetyGate());
    try gateway.bootstrapDurableDispatchWithBuffer(memory.interface(), undefined, stream, &bootstrap_buffer);
    @memset(&bootstrap_buffer, 0);
    const restored = try memory.interface().recover(undefined, stream);
    var layout_bytes: [4096]u8 = undefined;
    const accepted_bytes = (try snapshot_codec.encodeBare(&layout_bytes, std.mem.zeroes(DispatchProof))).len;
    var unknown = std.mem.zeroes(UncertainDispatch);
    unknown.recovered_proof = std.mem.zeroes(DispatchProof);
    unknown.recovered_proof.?.command.market_protection_price = std.mem.zeroes(oms.Price);
    unknown.reconciliation_status = .found_terminal;
    const uncertain_bytes = (try snapshot_codec.encodeBare(&layout_bytes, SnapshotUnknown{ .proof = unknown.recovered_proof.?, .reconciliation_id = unknown.reconciliation_id, .reconciliation_status = unknown.reconciliation_status })).len;
    try std.testing.expect(40960 * (4 + uncertain_bytes) + 128 * 1024 + 256 < durable.max_snapshot_bytes);
    std.debug.print("gateway_encoded_rows: accepted={d}, resolved_unknown={d}, max_40960={d}\n", .{ accepted_bytes, uncertain_bytes, 40960 * (4 + @max(accepted_bytes, uncertain_bytes)) });
    std.debug.print("gateway_layout: gateway={d}, accepted={d}, uncertain={d}, proof={d}, empty_snapshot={d}\n", .{ @sizeOf(Gateway), @sizeOf(AcceptedDispatch), @sizeOf(UncertainDispatch), @sizeOf(DispatchProof), restored.snapshot.len });
    try std.testing.expect(restored.snapshot.len < 256);
    const recovered = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(recovered);
    recovered.initWithDispatchSnapshotBuffer(&bootstrap_buffer);
    try recovered.attachRecoveredDurableDispatch(memory.interface(), undefined, stream);
    try recovered.checkpointDurableDispatch();
    try recovered.checkpointDurableDispatch();
    try std.testing.expectEqual(@as(u64, 0), recovered.send_attempt_count);
}

test "Gateway accepted dispatch survives restart without another adapter send" {
    const shard = try gatewaySelectionHeapFixture();
    defer std.testing.allocator.destroy(shard);
    const place = shard.oms.command_history[0];
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    var implementation: CountingSimulatedVenue = .{};
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = shard.activatedAssets(), .instrument_definitions = shard.instrument_registry });
    const route: Route = .{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } };
    const stream: durable.StreamIdentity = .{ .domain = .control, .id = 905 };
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try gateway.add(route);
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, stream);
    try observeGatewayCommand(gateway, shard, place, 1);
    try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(shard, place.command_id, 2 * std.time.ns_per_s));
    const client = gateway.acceptedClientOrderId(2, place.command_id).?;
    const recovered = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(recovered);
    var recovered_snapshot_buffer: [4096]u8 = undefined;
    recovered.initWithDispatchSnapshotBuffer(&recovered_snapshot_buffer);
    try recovered.add(route);
    try recovered.attachRecoveredDurableDispatch(memory.interface(), undefined, stream);
    try observeGatewayCommand(recovered, shard, place, 1);
    try std.testing.expectEqual(venue.SendResult.accepted, try recovered.sendFromShard(shard, place.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(client, recovered.acceptedClientOrderId(2, place.command_id).?);
    try std.testing.expectEqual(@as(u64, 1), implementation.sends);
    try recovered.checkpointDurableDispatch();
    const first_checkpoint = try memory.interface().recover(undefined, stream);
    const first_snapshot_digest = history.hash(first_checkpoint.snapshot);
    try recovered.checkpointDurableDispatch();
    const checkpoint = try memory.interface().recover(undefined, stream);
    try std.testing.expectEqual(first_checkpoint.segment_index, checkpoint.segment_index);
    try std.testing.expectEqual(first_checkpoint.committed_barrier, checkpoint.committed_barrier);
    try std.testing.expectEqualSlices(u8, &first_snapshot_digest, &history.hash(checkpoint.snapshot));
    const changed_empty = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(changed_empty);
    changed_empty.init();
    try changed_empty.add(route);
    try changed_empty.attachRecoveredDurableDispatch(memory.interface(), undefined, stream);
    changed_empty.latchAccount(2);
    try std.testing.expectError(error.DurableDispatchUnavailable, changed_empty.checkpointDurableDispatch());
    try std.testing.expectEqualSlices(u8, &first_snapshot_digest, &history.hash((try memory.interface().recover(undefined, stream)).snapshot));
    try std.testing.expectEqual(@as(u64, 3), checkpoint.snapshot_barrier);
    std.debug.print("gateway checkpoint: bytes={d}, accepted=1, tail_barrier=3\n", .{checkpoint.snapshot.len});
    const checkpoint_recovered = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(checkpoint_recovered);
    checkpoint_recovered.init();
    try checkpoint_recovered.add(route);
    try checkpoint_recovered.attachRecoveredDurableDispatch(memory.interface(), undefined, stream);
    try observeGatewayCommand(checkpoint_recovered, shard, place, 1);
    try std.testing.expectEqual(venue.SendResult.accepted, try checkpoint_recovered.sendFromShard(shard, place.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 1), implementation.sends);
    const fixture = @import("../testing/support/trading_shard_fixture.zig");
    var group: oms.IntentGroup = .{ .first_intent_sequence = 102, .count = 1 };
    group.members[0] = .{ .intent_sequence = 102, .operation = .place, .instrument = 3, .quantity = 10, .limit_price = fixture.omsPrice(3, 50_000_000) };
    const placed = try shard.apply(fixture.atGroup(18, .{ .identity = 102, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), placed.oms_commands.len);
    const unknown = placed.oms_commands[0];
    try observeGatewayCommand(checkpoint_recovered, shard, unknown, 1);
    // The simulator still has the first response queued, so this attempt is backpressured.
    try std.testing.expectEqual(venue.SendResult.backpressure, try checkpoint_recovered.sendFromShard(shard, unknown.command_id, 2 * std.time.ns_per_s));
    const unknown_recovered = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(unknown_recovered);
    unknown_recovered.init();
    for ([_]bool{ false, true }) |checkpoint_unknown| {
        if (checkpoint_unknown) try checkpoint_recovered.checkpointDurableDispatch();
        unknown_recovered.init();
        try unknown_recovered.add(route);
        try unknown_recovered.attachRecoveredDurableDispatch(memory.interface(), undefined, stream);
        try observeGatewayCommand(unknown_recovered, shard, unknown, 1);
        try std.testing.expectError(error.NotSent, unknown_recovered.sendFromShard(shard, unknown.command_id, 2 * std.time.ns_per_s));
        try std.testing.expectEqual(venue.SendResult.accepted, try unknown_recovered.sendFromShard(shard, place.command_id, 2 * std.time.ns_per_s));
        try std.testing.expectEqual(@as(u64, 2), implementation.sends);
    }
    _ = try adapter.tryDrain();
    group.first_intent_sequence = 103;
    group.members[0].intent_sequence = 103;
    const next = try shard.apply(fixture.atGroup(19, .{ .identity = 103, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), next.oms_commands.len);
    const next_command = next.oms_commands[0];
    try observeGatewayCommand(unknown_recovered, shard, next_command, 1);
    try std.testing.expectEqual(venue.SendResult.accepted, try unknown_recovered.sendFromShard(shard, next_command.command_id, 2 * std.time.ns_per_s));
    const tail_recovered = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(tail_recovered);
    tail_recovered.init();
    try tail_recovered.add(route);
    try tail_recovered.attachRecoveredDurableDispatch(memory.interface(), undefined, stream);
    try observeGatewayCommand(tail_recovered, shard, next_command, 1);
    try std.testing.expectEqual(venue.SendResult.accepted, try tail_recovered.sendFromShard(shard, next_command.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 3), implementation.sends);
    tail_recovered.latchAccount(2);
    try tail_recovered.checkpointDurableDispatch();
    try tail_recovered.checkpointDurableDispatch();
    const latched_recovered = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(latched_recovered);
    latched_recovered.init();
    try latched_recovered.add(route);
    try latched_recovered.attachRecoveredDurableDispatch(memory.interface(), undefined, stream);
    try std.testing.expectEqual(LatchedSafetyGate.latched, latched_recovered.routes[0].safety_gate);
    try std.testing.expectEqual(@as(u64, 3), implementation.sends);
}

test "Gateway accepted outcome commit failure cannot publish acceptance or resend" {
    const shard = try gatewaySelectionHeapFixture();
    defer std.testing.allocator.destroy(shard);
    const place = shard.oms.command_history[0];
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    var implementation: CountingSimulatedVenue = .{ .outcome_fault_store = memory };
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = shard.activatedAssets(), .instrument_definitions = shard.instrument_registry });
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 906 });
    try observeGatewayCommand(gateway, shard, place, 1);
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(shard, place.command_id, 2 * std.time.ns_per_s));
    try std.testing.expect(gateway.acceptedClientOrderId(2, place.command_id) == null);
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(shard, place.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectError(error.DurableDispatchUnavailable, gateway.checkpointDurableDispatch());
    try std.testing.expectEqual(@as(u64, 1), implementation.sends);
}

test "Gateway recovers accepted and Unknown together without sending and rejects expired authority" {
    const shard = try gatewaySelectionHeapFixture();
    defer std.testing.allocator.destroy(shard);
    const command_value = shard.oms.command_history[0];
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    var implementation: CountingSimulatedVenue = .{};
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = shard.activatedAssets(), .instrument_definitions = shard.instrument_registry });
    const route: Route = .{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } };
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try gateway.add(route);
    const stream: durable.StreamIdentity = .{ .domain = .control, .id = 979 };
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, stream);
    try observeGatewayCommand(gateway, shard, command_value, 1);
    try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(shard, command_value.command_id, 2 * std.time.ns_per_s));
    // Preserve both recovered kinds in a small artifact from an actual SDK attempt.
    const durable_state = try memory.interface().recover(undefined, stream);
    var reader = try trading.journal.Reader.init(durable_state.tail);
    const record = (try reader.next()).record;
    var proof = try snapshot_codec.decodeBare(record.payload, DispatchProof);
    const bytes = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..dispatch_snapshot.len], dispatch_snapshot);
    std.mem.writeInt(u16, bytes[dispatch_snapshot.len..][0..2], production_contract.journal_schema_version, .little);
    var position: usize = snapshot_prefix_size;
    try writeSnapshotRow(bytes, &position, DispatchSnapshotHeader{ .stream = stream, .barrier = 3, .namespace = gateway.durable_dispatch.?.namespace, .archive_count = 0, .accepted_count = 99, .uncertain_count = 1, .latch_count = 0 });
    for (0..99) |index| {
        proof.command.command_id = index + 1000;
        proof.command.order_id = index + 1000;
        try writeSnapshotRow(bytes, &position, proof);
    }
    proof.command.command_id = 1099;
    proof.command.order_id = 1099;
    try writeSnapshotRow(bytes, &position, SnapshotUnknown{ .proof = proof, .reconciliation_id = 0, .reconciliation_status = null });
    try std.testing.expect(position < 128 * 1024);
    try memory.interface().seal(undefined, stream);
    try memory.interface().publishSnapshot(undefined, stream, 3, bytes[0..position]);
    try memory.interface().rotate(undefined, stream);
    const recovered = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(recovered);
    recovered.init();
    try recovered.add(route);
    try recovered.attachRecoveredDurableDispatch(memory.interface(), undefined, stream);
    try std.testing.expectEqual(@as(u16, 99), recovered.accepted_dispatch_count);
    try std.testing.expectEqual(@as(u16, 1), recovered.uncertain_dispatch_count);
    try std.testing.expectEqual(@as(usize, 100), recovered.dispatchCount());
    try observeGatewayCommand(recovered, shard, command_value, 1);
    const before = try memory.interface().recover(undefined, stream);
    try std.testing.expectError(error.NotSent, recovered.sendFromShard(shard, command_value.command_id, 100 * std.time.ns_per_s));
    const after = try memory.interface().recover(undefined, stream);
    try std.testing.expectEqual(before.committed_barrier, after.committed_barrier);
    try std.testing.expectEqual(@as(u64, 1), implementation.sends);
}

test "Gateway distinguishes equal command identities from two simulated shard sources" {
    const first = try gatewaySelectionHeapFixtureForShard(0);
    defer std.testing.allocator.destroy(first);
    const second = try gatewaySelectionHeapFixtureForShard(1);
    defer std.testing.allocator.destroy(second);
    const first_command = first.oms.command_history[0];
    const second_command = second.oms.command_history[0];
    try std.testing.expectEqual(first_command.command_id, second_command.command_id);
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    var implementation: CountingSimulatedVenue = .{};
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = first.activatedAssets(), .instrument_definitions = first.instrument_registry });
    const route: Route = .{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } };
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try gateway.add(route);
    const stream: durable.StreamIdentity = .{ .domain = .control, .id = 907 };
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, stream);
    try observeGatewayCommand(gateway, first, first_command, 1);
    try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(first, first_command.command_id, 2 * std.time.ns_per_s));
    _ = try adapter.tryDrain();
    try observeGatewayCommand(gateway, second, second_command, 1);
    try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(second, second_command.command_id, 2 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 2), implementation.sends);
    try gateway.checkpointDurableDispatch();
    const recovered = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(recovered);
    recovered.init();
    try recovered.add(route);
    try recovered.attachRecoveredDurableDispatch(memory.interface(), undefined, stream);
    for ([_]*const trading.TradingShard{ first, second }) |source| {
        try observeGatewayCommand(recovered, source, source.oms.command_history[0], 1);
        try std.testing.expectEqual(venue.SendResult.accepted, try recovered.sendFromShard(source, 1, 2 * std.time.ns_per_s));
    }
    try std.testing.expectEqual(@as(u64, 2), implementation.sends);
}

test "Gateway retires old source permission rows without accepting a shard rollback" {
    const old = try gatewaySelectionHeapFixture();
    defer std.testing.allocator.destroy(old);
    const current = try copyShardForTesting(old);
    defer std.testing.allocator.destroy(current);
    var implementation: CountingSimulatedVenue = .{};
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try gateway.add(.{ .account = 2, .adapter = implementation.adapter(), .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    try observeGatewayCommand(gateway, old, old.oms.command_history[0], 1);
    const fixture = @import("../testing/support/trading_shard_fixture.zig");
    var group: oms.IntentGroup = .{ .first_intent_sequence = 102, .count = 1 };
    group.members[0] = .{ .intent_sequence = 102, .operation = .place, .instrument = 3, .quantity = 10, .limit_price = fixture.omsPrice(3, 50_000_000) };
    const next = try current.apply(fixture.atGroup(18, .{ .identity = 102, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), next.oms_commands.len);
    try observeGatewayCommand(gateway, current, next.oms_commands[0], 1);
    try std.testing.expectEqual(@as(u16, 1), gateway.reservation_count);
    try std.testing.expectError(error.StaleAuthorityFacts, observeGatewayCommand(gateway, old, old.oms.command_history[0], 1));
    try std.testing.expectEqual(@as(u16, 1), gateway.reservation_count);
    try std.testing.expectEqual(@as(u64, 0), implementation.sends);
}
test "gateway fixes route and rechecks every command dependency" {
    var first = Fixture{};
    var second = Fixture{};
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    try gateway.add(.{ .account = 1, .adapter = first.adapter(), .capability = profile });
    try gateway.add(.{ .account = 2, .adapter = second.adapter(), .capability = profile });
    var request = try command(1, 10);
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(request));
    try std.testing.expectEqual(@as(u8, 1), first.sent);
    request.config_version = 2;
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    try std.testing.expectEqual(@as(u8, 1), first.sent);
    request.config_version = 1;
    request.capability_version = 2;
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.capability_version = 1;
    request.rules_version = 2;
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.rules_version = 1;
    request.adapter_session = 2;
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.adapter_session = 1;
    gateway.latchAccount(1);
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.operation = .cancel;
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(request));
    request.operation = .place;
    request.exchange_account = 2;
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(request));
    gateway.setInstrumentGap(10);
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.instrument = 11;
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(request));
    gateway.routes[1].capability.supports_place = false;
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.operation = .cancel;
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(request));
    try std.testing.expectEqual(@as(u8, 3), second.sent);
    try std.testing.expectEqual(@as(u64, 5), gateway.send_attempt_count);
    std.debug.print("execution_gateway_acceptance: adapter_submissions={d}\n", .{gateway.send_attempt_count});
}
test "gateway drains each fixed route once" {
    var first = Fixture{};
    var second = Fixture{};
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    try gateway.add(.{ .account = 1, .adapter = first.adapter(), .capability = profile });
    try gateway.add(.{ .account = 2, .adapter = second.adapter(), .capability = profile });
    var output: [max_routes]canonical.AdapterOutputBatch = undefined;
    try std.testing.expectEqual(@as(u8, 2), try gateway.drainFair(&output));
}

test "DispatchProof rechecks authority reservation lease fencing and true reduce-only" {
    var adapter_fixture = Fixture{ .pending = null };
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try gateway.add(.{ .account = 1, .adapter = adapter_fixture.adapter(), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1, .supports_venue_reduce_only = true } });
    const command_value: oms.Command = .{ .command_id = 1, .order_id = 1, .strategy_instance = 1, .revision = 1, .operation = .place, .instrument = 10, .side = .sell, .portfolio_reduce_only = true, .venue_reduce_only = true, .quantity = 2, .limit_price = .{ .instrument = 10, .rules_version = 1, .ticks = 100 }, .reservation = .{ .asset = 1, .atoms = 20 }, .client_order_id = try canonical.ClientOrderId.init("RWN-1"), .intent_sequence = 1, .risk_decision_identity = 1, .reservation_identity = 1 };
    try gateway.observeAuthority(.{
        .account = 1,
        .effective_trading_authority = false,
        .reservation_identity = command_value.reservation_identity,
        .reservation = command_value.reservation,
        .primary_lease_expires_at_monotonic_ns = 10,
        .fencing_token = 7,
        .exchange_position = .{ .instrument = 10, .rules_version = 1, .lots = 3 },
        .authority_barrier = 5,
    });
    const proof: DispatchProof = .{
        .context = .{ .account = 1, .capability_version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .dispatch_deadline_monotonic_ns = 10 },
        .command = command_value,
        .fencing_token = 7,
        .authority_barrier = 5,
        .now_monotonic_ns = 9,
    };
    try std.testing.expectError(error.OrderProofRequired, gateway.sendProof(proof));
    gateway.routes[0].environment = .demo;
    try std.testing.expectError(error.NotSent, gateway.sendProofInternal(proof));
    try std.testing.expectEqual(@as(u8, 0), adapter_fixture.sent);
    gateway.routes[0].environment = .simulation;
    try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendProofInternal(proof));
    try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendProofInternal(proof));
    var conflicting = proof;
    conflicting.command.quantity = 1;
    try std.testing.expectError(error.NotSent, gateway.sendProofInternal(conflicting));
    try std.testing.expectEqual(@as(u8, 1), adapter_fixture.sent);

    var recovered_fixture = Fixture{ .pending = null };
    const recovered = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(recovered);
    recovered.init();
    try recovered.add(.{ .account = 1, .adapter = recovered_fixture.adapter(), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1, .supports_venue_reduce_only = true } });
    try recovered.restoreAcceptedDispatch(proof);
    try std.testing.expectEqual(venue.SendResult.accepted, try recovered.sendProofInternal(proof));
    try std.testing.expectError(error.NotSent, recovered.sendProofInternal(conflicting));
    try std.testing.expectEqual(@as(u8, 0), recovered_fixture.sent);
}

test "Gateway reads current authority facts instead of caller proof fields" {
    var adapter_fixture = Fixture{ .pending = null };
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    try gateway.add(.{ .account = 1, .adapter = adapter_fixture.adapter(), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    const command_value: oms.Command = .{ .command_id = 2, .order_id = 2, .strategy_instance = 1, .revision = 1, .operation = .place, .instrument = 10, .side = .sell, .portfolio_reduce_only = true, .venue_reduce_only = true, .quantity = 2, .limit_price = .{ .instrument = 10, .rules_version = 1, .ticks = 100 }, .reservation = .{ .asset = 1, .atoms = 20 }, .client_order_id = try canonical.ClientOrderId.init("RWN-2"), .intent_sequence = 2, .risk_decision_identity = 2, .reservation_identity = 2 };
    const proof: DispatchProof = .{
        .context = .{ .account = 1, .capability_version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .dispatch_deadline_monotonic_ns = 10 },
        .command = command_value,
        .fencing_token = 7,
        .authority_barrier = 5,
        .now_monotonic_ns = 9,
    };
    try gateway.observeAuthority(.{ .account = 1, .effective_trading_authority = false, .reservation_identity = 2, .reservation = command_value.reservation, .primary_lease_expires_at_monotonic_ns = 10, .fencing_token = 7, .exchange_position = .{ .instrument = 10, .rules_version = 1, .lots = -3 }, .authority_barrier = 5 });
    try std.testing.expectError(error.ConflictingAuthorityFacts, gateway.observeAuthority(.{ .account = 1, .effective_trading_authority = false, .reservation_identity = 2, .reservation = command_value.reservation, .primary_lease_expires_at_monotonic_ns = 10, .fencing_token = 7, .exchange_position = .{ .instrument = 10, .rules_version = 1, .lots = 3 }, .authority_barrier = 5 }));
    try std.testing.expectError(error.NotSent, gateway.sendProofInternal(proof));
    try gateway.observeAuthority(.{ .account = 1, .effective_trading_authority = false, .reservation_identity = 2, .reservation = command_value.reservation, .primary_lease_expires_at_monotonic_ns = 10, .fencing_token = 8, .exchange_position = .{ .instrument = 10, .rules_version = 1, .lots = 3 }, .authority_barrier = 6 });
    try std.testing.expectError(error.NotSent, gateway.sendProofInternal(proof));
    try gateway.observeAuthority(.{ .account = 1, .effective_trading_authority = false, .reservation_identity = 3, .reservation = command_value.reservation, .primary_lease_expires_at_monotonic_ns = 10, .fencing_token = 8, .exchange_position = .{ .instrument = 10, .rules_version = 1, .lots = 3 }, .authority_barrier = 7 });
    var stale_reservation = proof;
    stale_reservation.fencing_token = 8;
    stale_reservation.authority_barrier = 7;
    try std.testing.expectError(error.NotSent, gateway.sendProofInternal(stale_reservation));
    try std.testing.expectEqual(@as(u8, 0), adapter_fixture.sent);
}
test "Gateway route and batch admission fail atomically" {
    var adapter_fixture = Fixture{ .pending = null };
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    for (1..max_routes + 1) |account|
        try gateway.add(.{ .account = account, .adapter = adapter_fixture.adapter(), .capability = profile });
    try std.testing.expectError(error.DuplicateAccountRoute, gateway.add(.{ .account = 1, .adapter = adapter_fixture.adapter(), .capability = profile }));
    try std.testing.expectEqual(@as(u8, max_routes), gateway.count);
    try std.testing.expectError(error.RouteCapacity, gateway.add(.{ .account = 99, .adapter = adapter_fixture.adapter(), .capability = profile }));
    try std.testing.expectEqual(@as(u8, max_routes), gateway.count);

    var batch: canonical.OrderCommandBatch = .{};
    var invalid = try command(1, 10);
    invalid.config_version = 2;
    try batch.append(invalid);
    try std.testing.expectError(error.OrderProofRequired, gateway.sendRequest(.{ .order_batch = batch }));
    try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
    try std.testing.expectEqual(@as(u8, 0), adapter_fixture.sent);
}

test "Gateway observation universe and resident authority facts remain independent without emitted commands" {
    var implementation: Fixture = .{};
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    for (1..max_routes + 1) |account| try gateway.add(.{ .account = account, .adapter = implementation.adapter(), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    for (0..max_observed_instruments) |index| gateway.setInstrumentGap(index + 1);
    try std.testing.expectEqual(@as(u16, max_observed_instruments), gateway.instrument_gate_count);
    try std.testing.expect(!gateway.instrument_gate_capacity_exhausted);
    for (0..3) |index| try gateway.observeAuthority(.{
        .account = index + 1,
        .effective_trading_authority = true,
        .reservation_identity = index + 1,
        .reservation = .{ .asset = 1, .atoms = 10 },
        .primary_lease_expires_at_monotonic_ns = 100,
        .fencing_token = 1,
        .exchange_position = .{ .instrument = index + 1, .rules_version = 1, .lots = 0 },
        .authority_barrier = 1,
    });
    try std.testing.expectEqual(@as(u16, 3), gateway.reservation_count);
    try std.testing.expectEqual(@as(u16, 3), gateway.exchange_position_count);
    for (0..3) |index| try gateway.observeAuthority(.{
        .account = index + 1,
        .effective_trading_authority = true,
        .reservation_identity = index + 4,
        .reservation = .{ .asset = 1, .atoms = 10 },
        .primary_lease_expires_at_monotonic_ns = 100,
        .fencing_token = 1,
        .exchange_position = .{ .instrument = index + 1, .rules_version = 1, .lots = 0 },
        .authority_barrier = 1,
    });
    try std.testing.expectEqual(@as(u16, 6), gateway.reservation_count);
    try std.testing.expectEqual(@as(u16, 3), gateway.exchange_position_count);
    gateway.setInstrumentGap(max_observed_instruments + 1);
    try std.testing.expect(gateway.instrument_gate_capacity_exhausted);
    try std.testing.expectEqual(@as(u16, max_observed_instruments), gateway.instrument_gate_count);
    try std.testing.expectEqual(@as(u8, 0), implementation.sent);
}

fn initializeGatewaySelectionFixture(shard: *trading.TradingShard, shard_id: u32) !void {
    const fixture = @import("../testing/support/trading_shard_fixture.zig");
    const run = try std.testing.allocator.create(fixture.LiveRun);
    defer std.testing.allocator.destroy(run);
    run.* = .{ .shard = .{}, .decision_journal = trading.journal.Journal.init() };
    for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .cash)) |event| _ = try fixture.apply(run, event);
    const digest = run.shard.canonicalStateDigest();
    _ = try fixture.apply(run, fixture.atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .session = .{ .fencing = 1, .shard = shard_id, .generation = 1 }, .activation_barrier = 0, .state_digest = digest } } }));
    // The generic prelude observes linear rules; this fixture already owns spot rules.
    _ = try run.shard.apply(fixture.atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = 3, .price_atoms = 50_000_000_000 } } }));
    _ = try run.shard.apply(fixture.snapshotAt(13, 100));
    _ = try run.shard.apply(fixture.deltaAt(14, 100, 101, 49_850_000_000));
    const profile: shard_event.CapabilityProfileActivation = .{
        .exchange_account = 2,
        .instrument = 3,
        .venue = 1,
        .environment = .simulation,
        .product = .spot,
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 1,
        .max_dispatch_age_ns = 10 * std.time.ns_per_s,
        .supports_place = true,
        .supports_cancel = true,
        .supports_native_amend = false,
        .supports_venue_reduce_only = false,
        .supports_post_only = false,
        .supports_market_protection = false,
    };
    _ = try run.shard.apply(fixture.atGroup(15, .{ .identity = 100, .payload = .{ .capability_profile_activation = profile } }));
    var snapshot: canonical.AccountBootstrapSnapshot = .{
        .identity = 1,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 2,
        .source_sequence = 1,
        .balance_count = 2,
        .position_count = 0,
        .margin_count = 0,
    };
    for ([_]canonical.AssetIdentity{ 1, 0x425443 }, 0..) |asset, index| {
        const amount: i128 = if (asset == 1) 25_000_000_000 else 0;
        snapshot.balances[index] = .{
            .asset = asset,
            .total = .{ .asset = asset, .atoms = amount },
            .available = .{ .asset = asset, .atoms = amount },
            .held = .{ .asset = asset, .atoms = 0 },
            .cash_balance = .{ .asset = asset, .atoms = amount },
            .liability = .{ .asset = asset, .atoms = 0 },
            .isolated_liability = .{ .asset = asset, .atoms = 0 },
            .cross_liability = .{ .asset = asset, .atoms = 0 },
        };
    }
    var input = fixture.canonicalAt(16, 1, .{ .account_bootstrap_snapshot = snapshot });
    input.venue.envelope.identity.stream = 2;
    input.venue.envelope.source_stream = 2;
    _ = try run.shard.apply(input);
    var group: oms.IntentGroup = .{ .first_intent_sequence = 101, .count = 1 };
    group.members[0] = .{ .intent_sequence = 101, .operation = .place, .instrument = 3, .quantity = 10, .limit_price = fixture.omsPrice(3, 50_000_000) };
    const placed = try run.shard.apply(fixture.atGroup(17, .{ .identity = 101, .payload = .{ .oms_intent_group = group } }));
    try std.testing.expectEqual(@as(usize, 1), placed.oms_commands.len);
    @memcpy(std.mem.asBytes(shard), std.mem.asBytes(&run.shard));
}

fn observeGatewayCommand(gateway: *Gateway, shard: *const trading.TradingShard, value: oms.Command, barrier: u64) !void {
    try gateway.observeAuthorityFromShard(shard, .{
        .account = shard.exchange_account_identity,
        .effective_trading_authority = shard.operational_state.effectiveTradingAuthority(),
        .reservation_identity = value.reservation_identity,
        .reservation = value.reservation,
        .primary_lease_expires_at_monotonic_ns = 20 * std.time.ns_per_s,
        .fencing_token = 1,
        .exchange_position = shard.currentNetExchangePosition(value.instrument) orelse return error.MissingPosition,
        .authority_barrier = barrier,
    });
}

test "Gateway public proof preserves physical binding and rechecks per instrument rules and selection" {
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.check() catch |err| {
                self.failure = err;
            };
        }
        fn check(_: *@This()) !void {
            const fixture = @import("../testing/support/trading_shard_fixture.zig");
            const shard = try @call(.never_inline, gatewaySelectionHeapFixture, .{});
            defer std.testing.allocator.destroy(shard);
            const place = shard.oms.command_history[0];
            const memory = try std.testing.allocator.create(durable.MemoryAdapter);
            defer std.testing.allocator.destroy(memory);
            memory.* = .initWithAllocator(std.testing.allocator);
            defer memory.deinit();
            var implementation: Fixture = .{};
            const gateway = try std.testing.allocator.create(Gateway);
            defer std.testing.allocator.destroy(gateway);
            gateway.init();
            const route: Route = .{
                .account = 2,
                .adapter = implementation.adapter(),
                .venue_identity = 1,
                .supported_products = productMask(.spot) | productMask(.isolated_linear_usdt),
                // A physical route does not own the version of every symbol's rules.
                .capability = .{ .version = 1, .rules_version = 99, .config_version = 1, .session = 1, .supports_post_only = true },
            };
            try gateway.add(route);
            try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 904 });
            try observeGatewayCommand(gateway, shard, place, 1);
            try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(2, 3)));
            try std.testing.expectEqual(@as(u8, 0), implementation.sent);
            for (0..8) |field| {
                gateway.routes[0] = route;
                switch (field) {
                    0 => gateway.routes[0].account = 99,
                    1 => gateway.routes[0].venue_identity = 99,
                    2 => gateway.routes[0].environment = .demo,
                    3 => gateway.routes[0].capability.session = 2,
                    4 => gateway.routes[0].capability.version = 2,
                    5 => gateway.routes[0].supported_products = productMask(.isolated_linear_usdt),
                    6 => gateway.routes[0].capability.config_version = 2,
                    7 => gateway.routes[0].capability.supports_cancel = false,
                    else => unreachable,
                }
                try std.testing.expectError(error.NotSent, gateway.sendFromShard(shard, place.command_id, 2 * std.time.ns_per_s));
                try std.testing.expectEqual(@as(u8, 0), implementation.sent);
            }
            gateway.routes[0] = route;
            const gapped = try copyShardForTesting(shard);
            defer std.testing.allocator.destroy(gapped);
            for ([_]bool{ false, true }) |explicit_health| {
                @memcpy(std.mem.asBytes(gapped), std.mem.asBytes(shard));
                if (explicit_health) {
                    _ = try gapped.apply(fixture.canonicalAt(18, 102, .{ .market_data_health_changed = .{
                        .instrument = 3,
                        .health = .gap,
                    } }));
                } else {
                    _ = try gapped.apply(fixture.deltaAt(18, 100, 102, 49_850_000_000));
                }
                var sibling_snapshot = fixture.snapshotAt(19, 103);
                const book = &sibling_snapshot.venue.event.l2_book_snapshot;
                book.instrument = 4;
                book.best_bid.instrument = 4;
                book.best_ask.instrument = 4;
                book.next_ask.?.instrument = 4;
                book.best_bid_quantity.?.instrument = 4;
                book.best_ask_quantity.?.instrument = 4;
                book.next_ask_quantity.?.instrument = 4;
                _ = try gapped.apply(sibling_snapshot);
                try std.testing.expectEqual(canonical.MarketDataHealth.gap, gapped.canonical_market.get(3).?.health);
                try std.testing.expectEqual(canonical.MarketDataHealth.healthy, gapped.canonical_market.get(4).?.health);
                try std.testing.expectEqual(@as(u16, 0), gateway.instrument_gate_count);
                try std.testing.expectError(error.NotSent, gateway.sendFromShard(gapped, place.command_id, 2 * std.time.ns_per_s));
                try std.testing.expectEqual(@as(u8, 0), implementation.sent);
                try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
                try std.testing.expectEqual(@as(u64, 1), (try memory.interface().recover(undefined, .{ .domain = .control, .id = 904 })).committed_barrier);
            }
            const stale_margin = try copyShardForTesting(shard);
            defer std.testing.allocator.destroy(stale_margin);
            var margin = stale_margin.registryInstrument(3).?.margin;
            margin.instrument = 3;
            margin.version += 1;
            _ = try stale_margin.apply(fixture.atGroup(18, .{ .identity = 103, .payload = .{ .margin_rules_activated = margin } }));
            try std.testing.expectError(error.NotSent, gateway.sendFromShard(stale_margin, place.command_id, 2 * std.time.ns_per_s));
            try std.testing.expectEqual(@as(u8, 0), implementation.sent);
            const disabled = try copyShardForTesting(shard);
            defer std.testing.allocator.destroy(disabled);
            _ = try disabled.apply(fixture.atGroup(18, .{ .identity = 104, .payload = .{ .instrument_trading_authorization = .{
                .exchange_account = 2,
                .instrument = 3,
                .strategy_activation_identity = 1,
                .config_version = 1,
                .expected_version = 1,
                .enabled = false,
            } } }));
            try std.testing.expectError(error.NotSent, gateway.sendFromShard(disabled, place.command_id, 2 * std.time.ns_per_s));
            _ = try disabled.apply(fixture.atGroup(19, .{ .identity = 105, .payload = .{ .instrument_trading_authorization = .{
                .exchange_account = 2,
                .instrument = 3,
                .strategy_activation_identity = 1,
                .config_version = 1,
                .expected_version = 2,
                .enabled = true,
            } } }));
            // Re-enabling does not revive an earlier proof's selection version.
            try std.testing.expectError(error.NotSent, gateway.sendFromShard(disabled, place.command_id, 2 * std.time.ns_per_s));
            try std.testing.expectEqual(@as(u8, 0), implementation.sent);
            const sibling_disabled = try copyShardForTesting(shard);
            defer std.testing.allocator.destroy(sibling_disabled);
            var sibling_profile = shard.registryInstrument(3).?.capability.?;
            sibling_profile.instrument = 4;
            _ = try sibling_disabled.apply(fixture.atGroup(18, .{ .identity = 106, .payload = .{ .capability_profile_activation = sibling_profile } }));
            _ = try sibling_disabled.apply(fixture.atGroup(19, .{ .identity = 107, .payload = .{ .instrument_trading_authorization = .{
                .exchange_account = 2,
                .instrument = 4,
                .strategy_activation_identity = 1,
                .config_version = 1,
                .expected_version = 1,
                .enabled = false,
            } } }));
            try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(sibling_disabled, place.command_id, 2 * std.time.ns_per_s));
            try std.testing.expectEqual(@as(u8, 1), implementation.sent);
            const cancellable = try copyShardForTesting(shard);
            defer std.testing.allocator.destroy(cancellable);
            var dispatch: oms.DispatchBatch = .{ .count = 1 };
            dispatch.items[0] = .{ .command_id = place.command_id, .state = .submitted };
            _ = try cancellable.apply(fixture.atGroup(18, .{ .identity = 108, .payload = .{ .oms_dispatch_batch = dispatch } }));
            _ = try cancellable.apply(fixture.atGroup(19, .{ .identity = 109, .payload = .{ .oms_execution_report = .{
                .report_id = 109,
                .order_id = place.order_id,
                .revision = place.revision,
                .status = .accepted,
                .cumulative_quantity = 0,
                .remaining_quantity = place.quantity,
            } } }));
            _ = try cancellable.apply(fixture.atGroup(20, .{ .identity = 110, .payload = .{ .instrument_trading_authorization = .{
                .exchange_account = 2,
                .instrument = 3,
                .strategy_activation_identity = 1,
                .config_version = 1,
                .expected_version = 1,
                .enabled = false,
            } } }));
            _ = try cancellable.apply(fixture.deltaAt(20, 100, 102, 49_850_000_000));
            var cancellation: oms.IntentGroup = .{ .first_intent_sequence = 111, .count = 1 };
            cancellation.members[0] = .{ .intent_sequence = 111, .operation = .cancel, .instrument = 3, .target_order_id = place.order_id, .expected_revision = place.revision };
            const cancelled = try cancellable.apply(fixture.atGroup(21, .{ .identity = 111, .payload = .{ .oms_intent_group = cancellation } }));
            try std.testing.expectEqual(@as(usize, 1), cancelled.oms_commands.len);
            const cancel = cancelled.oms_commands[0];
            try observeGatewayCommand(gateway, cancellable, cancel, 2);
            try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(cancellable, cancel.command_id, 2 * std.time.ns_per_s));
            try std.testing.expectEqual(@as(u8, 2), implementation.sent);
        }
    };
    var context: Context = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 * 1024 }, Context.run, .{&context});
    thread.join();
    if (context.failure) |err| return err;
}
test "dispatch namespace survives recovery and changes for a new stream" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const store = memory.interface();
    const first = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(first);
    first.init();
    const first_stream: durable.StreamIdentity = .{ .domain = .control, .id = 91 };
    try first.bootstrapDurableDispatch(store, undefined, first_stream);
    const recovered = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(recovered);
    recovered.init();
    try recovered.attachRecoveredDurableDispatch(store, undefined, first_stream);
    try std.testing.expectEqualSlices(u8, &first.durable_dispatch.?.namespace, &recovered.durable_dispatch.?.namespace);
    const wrong_stream = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(wrong_stream);
    wrong_stream.init();
    try std.testing.expectError(error.DurableDispatchUnavailable, wrong_stream.attachRecoveredDurableDispatch(store, undefined, .{ .domain = .control, .id = 93 }));
    const second = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(second);
    second.init();
    try second.bootstrapDurableDispatch(store, undefined, .{ .domain = .control, .id = 92 });
    try std.testing.expect(!std.mem.eql(u8, &first.durable_dispatch.?.namespace, &second.durable_dispatch.?.namespace));
    memory.snapshots[0][dispatch_snapshot.len] ^= 1;
    const wrong_schema = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(wrong_schema);
    wrong_schema.init();
    try std.testing.expectError(error.DurableDispatchUnavailable, wrong_schema.attachRecoveredDurableDispatch(store, undefined, first_stream));
    memory.snapshots[0][dispatch_snapshot.len] ^= 1;
    try std.testing.expectEqual(durable.GateState.closed, store.safetyGate());
    const closed = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(closed);
    closed.init();
    try std.testing.expectError(error.DurableDispatchUnavailable, closed.bootstrapDurableDispatch(store, undefined, .{ .domain = .control, .id = 94 }));
}

test "recovered dispatch needs an order reconciliation newer than its send" {
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .initWithAllocator(std.testing.allocator);
    defer memory.deinit();
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    var implementation: Fixture = .{};
    try gateway.add(.{ .account = 1, .adapter = implementation.adapter(), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 94 });
    var shard: trading.TradingShard = .{};
    shard.exchange_account_identity = 1;
    shard.portfolio_identity = 2;
    var group: oms.IntentGroup = .{ .first_intent_sequence = 1, .count = 1 };
    group.members[0] = .{ .intent_sequence = 1, .operation = .place, .instrument = 10, .quantity = 2, .limit_price = .{ .instrument = 10, .rules_version = 1, .ticks = 3 }, .reservation = .{ .asset = 1, .atoms = 6 } };
    try shard.oms.applyGroup(group);
    const command_value = shard.oms.emitted()[0];
    shard.oms.command_history[0].authority.exchange_account = 1;
    shard.oms.command_history[0].authority.virtual_portfolio = 2;
    var dispatch: oms.DispatchBatch = .{ .count = 1 };
    dispatch.items[0] = .{ .command_id = command_value.command_id, .state = .submitted };
    try shard.oms.applyDispatch(dispatch);
    try shard.oms.applyReport(.{ .report_id = 1, .order_id = command_value.order_id, .revision = 1, .status = .accepted, .cumulative_quantity = 0, .remaining_quantity = 2 });
    const first: oms.ReconciliationResult = .{ .reconciliation_id = 10, .order_id = command_value.order_id, .status = .found_live, .revision = 1, .cumulative_quantity = 0, .remaining_quantity = 2 };
    try shard.oms.applyReconciliation(first);
    gateway.uncertain_dispatches[0] = .{ .origin = try sourceOrigin(&shard, true), .account = 1, .command_id = command_value.command_id, .client_order_id = command_value.client_order_id, .prior_reconciliation_id = first.reconciliation_id };
    gateway.uncertain_dispatch_count = 1;
    try std.testing.expectError(error.UnreconciledDispatch, gateway.reconcileRecoveredDispatch(&shard, command_value.command_id));
    var fresh = first;
    fresh.reconciliation_id = 11;
    try shard.oms.applyReconciliation(fresh);
    try gateway.reconcileRecoveredDispatch(&shard, command_value.command_id);
    try std.testing.expectEqual(fresh.reconciliation_id, gateway.uncertain_dispatches[0].reconciliation_id);
    try gateway.reconcileRecoveredDispatch(&shard, command_value.command_id);
}

test "Gateway scopes uncertainty and market health to the affected route" {
    var first = Fixture{ .pending = null };
    var second = Fixture{ .pending = null };
    const gateway = try std.testing.allocator.create(Gateway);
    defer std.testing.allocator.destroy(gateway);
    gateway.init();
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    try gateway.add(.{ .account = 11, .adapter = first.adapter(), .capability = profile });
    try gateway.add(.{ .account = 22, .adapter = second.adapter(), .capability = profile });

    var unknown: canonical.AdapterOutputBatch = .{};
    try unknown.append(.{ .envelope = .{
        .event_type = @intFromEnum(canonical.EventType.order_dispatch_result),
        .schema_version = canonical.schema_version,
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
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(11, 101)));
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(try command(22, 202)));

    var gap: canonical.AdapterOutputBatch = .{};
    try gap.append(.{ .envelope = .{
        .event_type = @intFromEnum(canonical.EventType.market_data_health_changed),
        .schema_version = canonical.schema_version,
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
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(22, 202)));
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(11, 101)));

    gap.events[0].event.market_data_health_changed.health = .healthy;
    gateway.observeMarketOutput(gap);
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(22, 202)));
    gap.events[0].envelope.event_type = @intFromEnum(canonical.EventType.l2_book_snapshot);
    gap.events[0].event = .{ .l2_book_snapshot = .{
        .instrument = 202,
        .sequence = 2,
        .best_bid = .{ .instrument = 202, .rules_version = 1, .ticks = 1 },
        .best_ask = .{ .instrument = 202, .rules_version = 1, .ticks = 2 },
    } };
    gateway.observeMarketOutput(gap);
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(try command(22, 202)));

    for (0..max_observed_instruments + 1) |index| gateway.setInstrumentGap(1_000 + index);
    try std.testing.expect(gateway.instrument_gate_capacity_exhausted);
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(22, 999)));
}

fn gatewaySelectionHeapFixture() !*trading.TradingShard {
    return gatewaySelectionHeapFixtureForShard(0);
}
fn gatewaySelectionHeapFixtureForShard(shard_id: u32) !*trading.TradingShard {
    const shard = try std.testing.allocator.create(trading.TradingShard);
    errdefer std.testing.allocator.destroy(shard);
    try initializeGatewaySelectionFixture(shard, shard_id);
    return shard;
}
fn copyShardForTesting(shard: *const trading.TradingShard) !*trading.TradingShard {
    const copy = try std.testing.allocator.create(trading.TradingShard);
    @memcpy(std.mem.asBytes(copy), std.mem.asBytes(shard));
    return copy;
}

test "Gateway economic history binds committed adjacent roots without retiring dispatch and recovers order completion" {
    const allocator = std.testing.allocator;
    const shard = try gatewaySelectionHeapFixture();
    defer allocator.destroy(shard);
    shard.checkpoint = try shard.checkpointReceipt(981, 1, history.hash("gateway checkpoint"));
    const memory = try allocator.create(durable.MemoryAdapter);
    defer allocator.destroy(memory);
    memory.* = .initWithAllocator(allocator);
    defer memory.deinit();
    const store = memory.interface();
    var implementation: CountingSimulatedVenue = .{};
    const adapter = implementation.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = shard.activatedAssets(), .instrument_definitions = shard.instrument_registry });
    const route: Route = .{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } };
    const gateway = try allocator.create(Gateway);
    defer allocator.destroy(gateway);
    gateway.init();
    try gateway.add(route);
    const stream: durable.StreamIdentity = .{ .domain = .control, .id = 982 };
    try gateway.bootstrapDurableDispatch(store, undefined, stream);
    const command_value = shard.oms.command_history[0];
    try observeGatewayCommand(gateway, shard, command_value, 1);
    try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendFromShard(shard, command_value.command_id, 2 * std.time.ns_per_s));
    const accepted = gateway.accepted_dispatches[0];
    var uncertain_proof = accepted.proof;
    uncertain_proof.command.command_id += 100;
    uncertain_proof.command.order_id += 100;
    var attempt_bytes: [trading.journal.max_payload_size]u8 = undefined;
    try gateway.commitDispatchRecord(dispatch_record_type, 0, try snapshot_codec.encodeBare(&attempt_bytes, uncertain_proof));
    try gateway.markUncertain(uncertain_proof);
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 981 }, .account = 2 };
    const records = [_]history.Record{.{ .bytes = "committed archive", .payload_digest = history.hash("committed archive") }};
    var entries = [_]history.Entry{.{ .key = .{ .origin = origin, .identity = .{ .order = 999 } }, .record_index = 0 }};
    const first = try store.publishOrderHistory(undefined, .{ .origin = origin, .barrier = 1, .epoch = 1, .qualification_digest = history.hash("order qualification"), .records = &records, .entries = &entries });
    shard.business_history_root = first.root;
    shard.last_order_archive = .{ .order_id = 999, .applied_fill_quantity = 0, .qualification_digest = first.qualification_digest, .receipt = first };
    shard.last_business_archive_kind = .order;
    try gateway.reclaimOrderDispatchEvidence(shard, 999);
    const completed_order = gateway.archive_bindings[0].last_order.?;
    const reservation_count = gateway.reservation_count;
    entries[0].key.identity = .{ .order = 1000 };
    const second = try store.publishOrderHistory(undefined, .{ .origin = origin, .previous_root = first.root, .barrier = 2, .epoch = 1, .qualification_digest = history.hash("fill qualification"), .records = &records, .entries = &entries });
    shard.business_history_root = second.root;
    shard.last_fill_archive = .{ .fill_id = 10, .qualification_digest = second.qualification_digest, .receipt = second };
    try std.testing.expectError(error.EconomicHistoryNotCommitted, gateway.acknowledgeEconomicHistory(shard));
    shard.last_business_archive_kind = .fill;
    shard.last_fill_archive.?.qualification_digest = history.hash("wrong qualification");
    try std.testing.expectError(error.EconomicHistoryNotCommitted, gateway.acknowledgeEconomicHistory(shard));
    shard.last_fill_archive.?.qualification_digest = second.qualification_digest;
    entries[0].key.identity = .{ .order = 1001 };
    const third = try store.publishOrderHistory(undefined, .{ .origin = origin, .previous_root = second.root, .barrier = 3, .epoch = 1, .qualification_digest = history.hash("next fill qualification"), .records = &records, .entries = &entries });
    shard.business_history_root = third.root;
    shard.last_fill_archive = .{ .fill_id = 11, .qualification_digest = third.qualification_digest, .receipt = third };
    try std.testing.expectError(error.InvalidHistoryReceipt, gateway.acknowledgeEconomicHistory(shard));
    try std.testing.expectEqualDeep(first.root, gateway.archive_bindings[0].root);
    shard.business_history_root = second.root;
    shard.last_fill_archive = .{ .fill_id = 10, .qualification_digest = second.qualification_digest, .receipt = second };
    try gateway.acknowledgeEconomicHistory(shard);
    try gateway.acknowledgeEconomicHistory(shard);
    try std.testing.expectEqualDeep(second.root, gateway.archive_bindings[0].root);
    try std.testing.expectEqualDeep(completed_order, gateway.archive_bindings[0].last_order.?);
    try std.testing.expectEqualDeep(accepted, gateway.accepted_dispatches[0]);
    try std.testing.expectEqual(@as(u16, 1), gateway.accepted_dispatch_count);
    try std.testing.expectEqual(@as(u16, 1), gateway.uncertain_dispatch_count);
    try std.testing.expectEqual(reservation_count, gateway.reservation_count);
    try gateway.completePreviousOrderArchive(shard);
    const recovered = try allocator.create(Gateway);
    defer allocator.destroy(recovered);
    recovered.init();
    try recovered.add(route);
    try recovered.attachRecoveredDurableDispatch(store, undefined, stream);
    try std.testing.expectEqualDeep(gateway.archive_bindings[0], recovered.archive_bindings[0]);
    try std.testing.expectEqual(@as(u16, 1), recovered.accepted_dispatch_count);
    try std.testing.expectEqual(@as(u16, 1), recovered.uncertain_dispatch_count);
    try recovered.completePreviousOrderArchive(shard);
    // A committed economic record also survives interruption before its checkpoint.
    const tail_commit: EconomicHistoryCommit = .{ .origin = accepted.origin, .kind = .fill, .identity = 11, .qualification_digest = third.qualification_digest, .receipt = third };
    try recovered.commitDispatchRecord(economic_history_record_type, 0, try snapshot_codec.encodeBare(&attempt_bytes, tail_commit));
    const tail_recovered = try allocator.create(Gateway);
    defer allocator.destroy(tail_recovered);
    tail_recovered.init();
    try tail_recovered.add(route);
    try tail_recovered.attachRecoveredDurableDispatch(store, undefined, stream);
    try std.testing.expectEqualDeep(third.root, tail_recovered.archive_bindings[0].root);
    try std.testing.expectEqualDeep(completed_order, tail_recovered.archive_bindings[0].last_order.?);
    try std.testing.expectEqual(@as(u16, 1), tail_recovered.accepted_dispatch_count);
    try std.testing.expectEqual(@as(u16, 1), tail_recovered.uncertain_dispatch_count);
    try tail_recovered.completePreviousOrderArchive(shard);
    // Funding and closed windows advance the same continuous root without retiring either outcome.
    entries[0].key.identity = .{ .funding_detail = 901 };
    const fourth = try store.publishOrderHistory(undefined, .{ .origin = origin, .previous_root = third.root, .barrier = 4, .epoch = 1, .qualification_digest = history.hash("funding qualification"), .records = &records, .entries = &entries });
    shard.business_history_root = fourth.root;
    shard.last_funding_archive = .{ .funding_id = 901, .qualification_digest = fourth.qualification_digest, .receipt = fourth };
    shard.last_business_archive_kind = .funding;
    try tail_recovered.acknowledgeEconomicHistory(shard);
    entries[0].key.identity = .{ .reconciliation_window = @as(u128, std.math.maxInt(u64)) + 1 };
    const fifth = try store.publishOrderHistory(undefined, .{ .origin = origin, .previous_root = fourth.root, .barrier = 5, .epoch = 1, .qualification_digest = history.hash("window qualification"), .records = &records, .entries = &entries });
    shard.business_history_root = fifth.root;
    shard.last_reconciliation_archive = .{ .window_id = @as(u128, std.math.maxInt(u64)) + 1, .qualification_digest = fifth.qualification_digest, .receipt = fifth };
    shard.last_business_archive_kind = .reconciliation;
    try tail_recovered.acknowledgeEconomicHistory(shard);
    try tail_recovered.acknowledgeEconomicHistory(shard);
    recovered.init();
    try recovered.add(route);
    try recovered.attachRecoveredDurableDispatch(store, undefined, stream);
    try std.testing.expectEqualDeep(fifth.root, recovered.archive_bindings[0].root);
    try std.testing.expectEqualDeep(accepted, recovered.accepted_dispatches[0]);
    try std.testing.expectEqual(@as(u16, 1), recovered.uncertain_dispatch_count);
    try std.testing.expectEqual(@as(u64, 0), recovered.send_attempt_count);
    const barrier = recovered.durable_dispatch.?.next_sequence;
    shard.last_order_archive.?.order_id += 1;
    try std.testing.expectError(error.DispatchArchiveNotCommitted, recovered.completePreviousOrderArchive(shard));
    try std.testing.expectEqual(barrier, recovered.durable_dispatch.?.next_sequence);
    try std.testing.expectEqual(@as(u64, 1), implementation.sends);
}
