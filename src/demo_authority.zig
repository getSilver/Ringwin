//! Demo-only authoritative shard owner. Venue facts and core control facts
//! share one committed decision stream before the Gateway may observe state.

const std = @import("std");
const durable = @import("durable_store.zig");
const journal = @import("journal.zig");
const trading = @import("trading_shard.zig");
const canonical = @import("canonical_event.zig");
const execution = @import("execution_gateway.zig");
const venue = @import("venue_adapter.zig");
const okx = @import("okx_venue_adapter.zig");
const failover = @import("failover.zig");
const raw_ingress = @import("raw_ingress.zig");

pub const max_private_resume_bytes = okx.max_resume_checkpoint_bytes;
pub const PrivateRecoveryBoundary = struct {
    schema: u16 = 1,
    decision_stream: u64,
    decision_barrier: u64,
    core_digest: [32]u8,
    raw_stream: durable.StreamIdentity,
    raw_sequence: u64,
    raw_digest: [32]u8,
    raw_archive_root: [32]u8,
    adapter_session: u64,
    canonical_stream: u128,
    canonical_sequence: u64,
    seed_digest: [32]u8,
};

pub const PrivateCheckpointView = struct {
    core_snapshot: []const u8,
    boundary: ?PrivateRecoveryBoundary = null,
    seed: []const u8 = &.{},
};

const private_bundle_magic = "RWPRV001";

fn validatePrivateBoundary(boundary: PrivateRecoveryBoundary) !void {
    if (boundary.schema != 1 or boundary.decision_stream == 0 or boundary.decision_barrier == 0 or
        boundary.raw_stream.domain != .raw_ingress or boundary.raw_stream.id == 0 or boundary.raw_sequence == 0 or
        boundary.adapter_session == 0 or boundary.canonical_stream == 0 or boundary.canonical_sequence == 0 or
        boundary.canonical_stream != @as(u128, boundary.adapter_session) or boundary.canonical_sequence == std.math.maxInt(u64) or boundary.raw_sequence == std.math.maxInt(u64) or
        std.mem.allEqual(u8, &boundary.raw_archive_root, 0) or std.mem.allEqual(u8, &boundary.raw_digest, 0))
        return error.InvalidPrivateResumeCheckpoint;
}

pub fn privateCheckpointView(encoded: []const u8) !PrivateCheckpointView {
    if (!std.mem.startsWith(u8, encoded, private_bundle_magic)) return .{ .core_snapshot = encoded };
    if (encoded.len < 20) return error.InvalidPrivateResumeCheckpoint;
    const metadata_len = std.mem.readInt(u32, encoded[8..12], .little);
    const core_len = std.mem.readInt(u32, encoded[12..16], .little);
    const seed_len = std.mem.readInt(u32, encoded[16..20], .little);
    if (seed_len == 0 or seed_len > max_private_resume_bytes or core_len == 0 or
        @as(u64, 20) + metadata_len + core_len + seed_len != encoded.len) return error.InvalidPrivateResumeCheckpoint;
    const boundary = try @import("snapshot_codec.zig").decodeBare(encoded[20..][0..metadata_len], PrivateRecoveryBoundary);
    try validatePrivateBoundary(boundary);
    const seed = encoded[20 + metadata_len + core_len ..];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(seed, &digest, .{});
    if (!std.mem.eql(u8, &digest, &boundary.seed_digest)) return error.InvalidPrivateResumeCheckpoint;
    return .{ .core_snapshot = encoded[20 + metadata_len ..][0..core_len], .boundary = boundary, .seed = seed };
}

pub fn recoverPrivateCheckpoint(store: durable.Store, io: std.Io, stream: durable.StreamIdentity) !PrivateCheckpointView {
    const recovered = try store.recover(io, stream);
    if (recovered.status != .ready or recovered.gate != .open or recovered.last_sequence != recovered.committed_barrier)
        return error.PrivateRecoveryHistoryUnavailable;
    const view = try privateCheckpointView(recovered.snapshot);
    if (view.boundary) |boundary| if (boundary.decision_stream != stream.id or boundary.decision_barrier > recovered.snapshot_barrier)
        return error.InvalidPrivateResumeCheckpoint;
    return view;
}

/// Explicit local Demo policy. It supplies authorization limits, never an
/// account balance, lease token, Venue fact, or send proof.
pub const Policy = struct {
    pub const Startup = enum { virgin, recover };
    asset_definitions: []const canonical.AssetDefinition = &.{},
    schema: u16,
    startup: Startup,
    exchange_account: u128,
    portfolio_identity: u128,
    strategy_identity: u128,
    activation_identity: u128,
    config_version: u64,
    portfolio_allocation_atoms: i128,
    risk_limit_atoms: i128,
    price_tick_atoms: i128,
    lot_size: canonical.Decimal,
    native_settlement_atoms: bool = false,
    decision_stream_id: u64,
    dispatch_stream_id: u64,
    decision_domain: u64,
    node_identity: u64,

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Policy) {
        const parsed = try std.json.parseFromSlice(Policy, gpa, bytes, .{});
        errdefer parsed.deinit();
        const value = parsed.value;
        if (value.schema != 3 or value.lot_size.coefficient <= 0 or value.lot_size.coefficient > std.math.maxInt(i64) or value.lot_size.scale > 18 or value.price_tick_atoms <= 0 or value.exchange_account == 0 or value.portfolio_identity == 0 or
            value.strategy_identity == 0 or value.activation_identity == 0 or value.config_version == 0 or
            value.portfolio_allocation_atoms <= 0 or value.risk_limit_atoms <= 0 or
            value.risk_limit_atoms > value.portfolio_allocation_atoms or
            value.decision_stream_id == 0 or value.dispatch_stream_id == 0 or
            value.decision_stream_id == value.dispatch_stream_id or value.decision_domain == 0 or value.node_identity == 0)
            return error.InvalidDemoPolicy;
        return parsed;
    }

    /// Must run before the first private account frame; Owner commits all units.
    pub fn activateAssets(self: Policy, owner: *Owner) !void {
        return self.activateAssetDefinitions(owner, false);
    }

    /// Only callers with transport disabled may admit explicit fixture evidence.
    pub fn activateAssetsForOfflineValidation(self: Policy, owner: *Owner) !void {
        return self.activateAssetDefinitions(owner, true);
    }

    fn activateAssetDefinitions(self: Policy, owner: *Owner, offline: bool) !void {
        if (self.asset_definitions.len == 0) {
            owner.closeAdmission();
            return error.MissingAssetDefinitions;
        }
        for (self.asset_definitions) |definition| {
            if (definition.source_kind == .test_fixture and !offline) {
                owner.closeAdmission();
                return error.TestAssetDefinitionForbidden;
            }
            _ = try owner.apply(.{ .core = .{ .identity = @intCast(try std.math.add(u64, owner.shard.authoritativeBarrier(), 1)), .payload = .{ .asset_definition_activated = definition } } });
        }
        try self.activateInstrumentConfiguration(owner);
    }

    /// Configuration is durable before private bootstrap; initialization later
    /// validates the same rules without republishing an identical fact.
    fn activateInstrumentConfiguration(self: Policy, owner: *Owner) !void {
        if (self.schema != 3 or self.lot_size.coefficient <= 0 or self.lot_size.scale > 18 or self.price_tick_atoms <= 0)
            return error.InvalidDemoPolicy;
        const numerator = std.math.cast(i64, self.lot_size.coefficient) orelse return error.InvalidDemoPolicy;
        const denominator = std.math.cast(i64, try (canonical.Decimal{ .coefficient = 1, .scale = 0 }).exactAtoms(self.lot_size.scale)) orelse return error.InvalidDemoPolicy;
        const rules: @import("trading_shard_event.zig").InstrumentRules = .{
            .version = 1,
            .instrument_identity = okx.btc_usdt_spot,
            .quantity_denominator = denominator,
            .quantity_numerator = numerator,
            .reservation_model = .cash,
            .product = .spot,
            .venue = 1,
            .base_asset = okx.btc,
        };
        const margin: @import("trading_shard_event.zig").MarginRules = .{
            .version = 1,
            .instrument = okx.btc_usdt_spot,
            .price_tick_atoms = self.price_tick_atoms,
            .native_settlement_atoms = self.native_settlement_atoms,
        };
        const known = owner.shard.instrument_registry.get(okx.btc_usdt_spot);
        if (known == null or !std.meta.eql(known.?.rules, rules))
            _ = try owner.apply(.{ .core = .{ .identity = @intCast(try std.math.add(u64, owner.shard.authoritativeBarrier(), 1)), .payload = .{ .instrument_rules_activated = rules } } });
        const configured = owner.shard.instrument_registry.get(okx.btc_usdt_spot).?;
        if (!configured.margin_configured or !std.meta.eql(configured.margin, margin))
            _ = try owner.apply(.{ .core = .{ .identity = @intCast(try std.math.add(u64, owner.shard.authoritativeBarrier(), 1)), .payload = .{ .margin_rules_activated = margin } } });
    }

    /// Virgin startup derives cash only from a complete private account
    /// snapshot; existing BTC/derivative exposure requires recovery instead.
    pub fn initialize(self: Policy, owner: *Owner, mark_price_atoms: i128, guard: *failover.GatewayLeaseGuard, now_ns: u64, adapter_session: u64) !void {
        try self.initializePendingHost(owner, mark_price_atoms, guard, now_ns, adapter_session);
        const barrier = owner.shard.authoritativeBarrier();
        try self.activateHost(owner, .{ .fencing = guard.lease.token, .shard = 0, .generation = 1 }, barrier, owner.shard.canonicalStateDigest());
    }

    /// The process-chain variant waits for a real ManagedHost recovery and
    /// activation handshake before sealing the decision owner as ready.
    pub fn initializePendingHost(self: Policy, owner: *Owner, mark_price_atoms: i128, guard: *failover.GatewayLeaseGuard, now_ns: u64, adapter_session: u64) !void {
        try self.activateInstrumentConfiguration(owner);
        if (!owner.shard.activatedAssets().consumerCompatible(self.native_settlement_atoms)) return error.AssetPrecisionUnsupported;
        if (owner.ready or owner.closed or owner.shard.authoritativeBarrier() == 0 or
            owner.stream.id != self.decision_stream_id or mark_price_atoms <= 0 or
            now_ns == 0 or adapter_session == 0 or
            guard.lease.key.exchange_account != self.exchange_account or
            guard.lease.key.decision_domain != self.decision_domain or
            guard.lease.node != self.node_identity or !guard.lease.valid(now_ns))
            return error.InvalidDemoBootstrap;
        guard.check(now_ns, guard.lease.token, true) catch return error.InvalidDemoLease;
        const account = &owner.shard.canonical_account;
        if (!account.valid or account.exchange_account != self.exchange_account)
            return error.InvalidDemoAccount;
        try requireSafeDemoExposure(account, false, owner.shard.activatedAssets());
        var usdt_total: ?i128 = null;
        var usdt_available: ?i128 = null;
        var opening: @import("trading_shard_event.zig").OpeningBalance = .{ .cash_atoms = 0 };
        const base_asset = owner.shard.instrument_registry.get(okx.btc_usdt_spot).?.rules.base_asset;
        for (account.balances[0..account.balance_count]) |balance| {
            if (balance.asset != okx.usdt) {
                if (balance.asset == base_asset) continue;
                if (account.nativeAvailable(balance.asset) == null or opening.native_balance_count == opening.native_balances.len)
                    return error.InvalidDemoAccount;
                try owner.shard.activatedAssets().checkAmount(balance.total, false);
                opening.native_balances[opening.native_balance_count] = balance.total;
                opening.native_balance_count += 1;
                continue;
            }
            if (usdt_total != null or balance.total.asset != okx.usdt or balance.available.asset != okx.usdt or
                balance.total.atoms <= 0 or balance.available.atoms < self.portfolio_allocation_atoms or
                balance.available.atoms > balance.total.atoms)
                return error.InvalidDemoAccount;
            usdt_total = balance.total.atoms;
            usdt_available = balance.available.atoms;
        }
        if (usdt_total == null or usdt_available == null) return error.MissingDemoCash;
        opening.cash_atoms = usdt_total.?;
        const core = struct {
            fn put(target: *Owner, identity: u64, payload: trading.CorePayload) !void {
                if (try target.apply(.{ .core = .{ .identity = identity, .payload = payload } }) != null)
                    return error.UnexpectedDemoOrder;
            }
        }.put;
        try core(owner, 3, .{ .account_configuration = .{ .exchange_account_identity = self.exchange_account } });
        try core(owner, 4, .{ .exchange_balance = .{ .cash_atoms = usdt_total.? } });
        try core(owner, 5, .exchange_positions);
        try core(owner, 6, .{ .opening_balance = opening });
        try core(owner, 7, .{ .virtual_portfolio_activated = .{ .portfolio_identity = self.portfolio_identity } });
        try core(owner, 8, .{ .portfolio_transfer = .{ .amount_atoms = self.portfolio_allocation_atoms } });
        try core(owner, 9, .{ .strategy_activated = .{
            .strategy_identity = self.strategy_identity,
            .config_version = self.config_version,
            .activation_identity = self.activation_identity,
        } });
        try core(owner, 10, .{ .primary_lease_granted = .{ .fencing_token = guard.lease.token } });
        const risk_valid_through = std.math.add(u64, owner.shard.authoritativeBarrier(), 128) catch return error.InvalidDemoBootstrap;
        try core(owner, 11, .{ .risk_lease_granted = .{
            .lease_identity = 11,
            .version = 1,
            .amount_atoms = self.risk_limit_atoms,
            .valid_through_barrier = risk_valid_through,
        } });
        try core(owner, 12, .{ .mark_price = .{ .instrument = okx.btc_usdt_spot, .price_atoms = mark_price_atoms } });
        try core(owner, 13, .{ .control_command = .{
            .command_identity = 1,
            .content_hash = 1,
            .target_identity = self.portfolio_identity,
            .expected_version = 0,
            .expires_at = std.math.maxInt(u64),
            .kind = .start_recovery,
        } });
        try core(owner, 14, .recovery_completed);
        try core(owner, 15, .{ .control_command = .{
            .command_identity = 2,
            .content_hash = 2,
            .target_identity = self.portfolio_identity,
            .expected_version = 2,
            .expires_at = std.math.maxInt(u64),
            .kind = .enable_trading,
        } });
        try core(owner, 16, .{ .capability_profile_activation = .{
            .exchange_account = self.exchange_account,
            .instrument = okx.btc_usdt_spot,
            .venue = 1,
            .environment = .demo,
            .product = .spot,
            .version = 1,
            .rules_version = 1,
            .config_version = self.config_version,
            .adapter_session = adapter_session,
            .max_dispatch_age_ns = 15 * std.time.ns_per_s,
            .supports_place = true,
            .supports_cancel = true,
            .supports_native_amend = false,
            .supports_venue_reduce_only = false,
            .supports_post_only = true,
            .supports_market_protection = true,
        } });
    }

    pub fn activateHost(self: Policy, owner: *Owner, session: @import("strategy_host_ipc.zig").Session, barrier: u64, digest: [32]u8) !void {
        if (owner.ready or owner.closed or barrier == 0 or barrier != owner.shard.authoritativeBarrier() or
            !std.mem.eql(u8, &digest, &owner.shard.canonicalStateDigest()) or
            owner.shard.strategy_identity != self.strategy_identity or
            owner.shard.strategy_config_version != self.config_version or
            owner.shard.strategy_activation_identity != self.activation_identity or
            session.fencing == 0 or session.fencing != owner.shard.fencing_token or session.generation == 0)
            return error.InvalidHostActivation;
        const core = struct {
            fn put(target: *Owner, identity: u64, payload: trading.CorePayload) !void {
                if (try target.apply(.{ .core = .{ .identity = identity, .payload = payload } }) != null)
                    return error.UnexpectedDemoOrder;
            }
        }.put;
        try core(owner, 17, .{ .host_activated = .{
            .strategy_identity = self.strategy_identity,
            .config_version = self.config_version,
            .activation_identity = self.activation_identity,
            .session = session,
            .activation_barrier = barrier,
            .state_digest = digest,
        } });
        try owner.sealBootstrap();
    }
};

pub const Owner = struct {
    store: durable.Store,
    io: std.Io,
    stream: durable.StreamIdentity,
    shard: trading.TradingShard = .{},
    decision_journal: journal.Journal = journal.Journal.init(),
    ready: bool = false,
    closed: bool = false,
    checkpoint_pending: bool = false,
    recovery_ingress_verified: bool = false,
    committing_checkpoint: bool = false,
    recovery_ingress: ?durable.StreamIdentity = null,
    recovery_ingress_store: ?durable.Store = null,
    private_boundary: ?PrivateRecoveryBoundary = null,
    private_resume: [max_private_resume_bytes]u8 = undefined,
    private_resume_len: usize = 0,
    private_seed_restored: bool = false,

    /// Caller must supply an operator-owned virgin identity. A missing file is
    /// never interpreted as permission to create a new authority history.
    pub fn bootstrap(store: durable.Store, io: std.Io, stream: durable.StreamIdentity) !Owner {
        if (stream.domain != .decision_log or stream.id == 0 or store.safetyGate() != .open)
            return error.DecisionLogUnavailable;
        return .{ .store = store, .io = io, .stream = stream };
    }

    pub fn recover(store: durable.Store, io: std.Io, stream: durable.StreamIdentity) !Owner {
        if (stream.domain != .decision_log or stream.id == 0 or store.safetyGate() != .open)
            return error.DecisionLogUnavailable;
        const recovered = store.recover(io, stream) catch return error.DecisionLogUnavailable;
        if (recovered.status != .ready or recovered.gate != .open or
            recovered.committed_barrier == 0 or recovered.last_sequence != recovered.committed_barrier)
            return error.DecisionLogUnavailable;
        const checkpoint_view = privateCheckpointView(recovered.snapshot) catch return error.DecisionLogUnavailable;
        var recovered_shard = if (recovered.tail_count == 0 and recovered.tail.len == 0)
            (trading.TradingShard.restoreSnapshot(checkpoint_view.core_snapshot) catch return error.DecisionLogUnavailable).shard
        else blk: {
            const tails = if (recovered.tail_count != 0) recovered.tail_segments[0..recovered.tail_count] else &.{recovered.tail};
            const restored = trading.TradingShard.restoreSegments(checkpoint_view.core_snapshot, tails) catch return error.DecisionLogUnavailable;
            // An open, fully committed tail is legal; the Store verified its
            // continuity and the shard replay verified every derived fact.
            break :blk restored.shard;
        };
        if (recovered_shard.authoritativeBarrier() != recovered.committed_barrier) return error.DecisionLogUnavailable;
        if (recovered_shard.checkpoint) |receipt| if (receipt.stream != stream.id) return error.DecisionLogUnavailable;
        if (recovered_shard.checkpointGeneration() != 0 and
            !(store.verifyArchiveReceipt(io, stream, recovered_shard.checkpointArchiveBarrier(), recovered_shard.checkpointArchiveRoot()) catch return error.DecisionLogUnavailable))
            return error.DecisionLogUnavailable;
        // A committed decision prefix may precede durable private facts. Every
        // restart re-arms admission, independent of the saved snapshot flag.
        recovered_shard.recovery_admission_pending = true;
        const next_sequence = std.math.add(u64, recovered.last_sequence, 1) catch return error.DecisionLogUnavailable;
        var recovered_journal = journal.Journal.initAt(next_sequence);
        const active_segment = if (recovered.active_segment.len != 0) recovered.active_segment else recovered.tail;
        if (active_segment.len != 0) {
            var reader = journal.Reader.init(active_segment) catch return error.DecisionLogUnavailable;
            recovered_journal = journal.Journal.initAt(reader.next_sequence);
            while (true) switch (reader.next() catch return error.DecisionLogUnavailable) {
                .record => |record| recovered_journal.append(record) catch return error.DecisionLogUnavailable,
                .end => break,
            };
            if (recovered.segment_sealed) recovered_journal.seal() catch return error.DecisionLogUnavailable;
        }
        var owner: Owner = .{
            .store = store,
            .io = io,
            .stream = stream,
            .shard = recovered_shard,
            .decision_journal = recovered_journal,
            .checkpoint_pending = recovered.segment_sealed or (recovered.archived_barrier == recovered_shard.authoritativeBarrier() and !std.mem.eql(u8, &recovered.archive_root, &recovered_shard.checkpointArchiveRoot())),
            .ready = true,
        };
        if (checkpoint_view.boundary) |boundary| {
            if (boundary.decision_stream != stream.id or boundary.decision_barrier > recovered.snapshot_barrier)
                return error.DecisionLogUnavailable;
            owner.private_boundary = boundary;
            @memcpy(owner.private_resume[0..checkpoint_view.seed.len], checkpoint_view.seed);
            owner.private_resume_len = checkpoint_view.seed.len;
        }
        return owner;
    }

    /// Bind the configured durable ingress identity explicitly. Decision-only
    /// recovery remains read-only for new-risk admission; a caller cannot infer
    /// a raw Store stream from canonical source-session identities.
    pub fn recoverWithIngress(store: durable.Store, io: std.Io, stream: durable.StreamIdentity, ingress: durable.StreamIdentity) !Owner {
        var owner = try recover(store, io, stream);
        try owner.bindRecoveryIngress(store, ingress);
        return owner;
    }

    /// Explicitly bind an execution-owned Store through its read-only public
    /// seam. The caller owns its lifetime until the synchronous sweep returns.
    pub fn bindRecoveryIngress(self: *Owner, store: durable.Store, ingress: durable.StreamIdentity) !void {
        if (!self.ready or self.closed or !self.shard.recovery_admission_pending or self.recovery_ingress != null)
            return error.DecisionLogUnavailable;
        if (ingress.domain != .raw_ingress or ingress.id == 0) return error.DecisionLogUnavailable;
        const raw = store.recover(self.io, ingress) catch return error.DecisionLogUnavailable;
        if (raw.gate != .open or raw.last_sequence == 0 or raw.last_sequence != raw.committed_barrier)
            return error.DecisionLogUnavailable;
        if (self.private_boundary) |boundary| {
            if (!std.meta.eql(boundary.raw_stream, ingress) or
                !(store.verifyArchiveReceipt(self.io, ingress, boundary.raw_sequence, boundary.raw_archive_root) catch return error.DecisionLogUnavailable))
                return error.PrivateRecoveryBoundaryUnavailable;
        }
        self.recovery_ingress = ingress;
        self.recovery_ingress_store = store;
    }

    /// Apply to a candidate and publish only after every record and the
    /// barrier have been committed. A fault closes this owner permanently.
    pub fn apply(self: *Owner, input: trading.CanonicalEvent) !?trading.OrderCommand {
        const maintenance = input == .core and input.core.payload == .checkpoint_committed;
        if ((maintenance and !self.committing_checkpoint) or (self.checkpoint_pending and !maintenance)) return error.DecisionLogUnavailable;
        if (self.closed or self.store.safetyGate() != .open) {
            self.closeAdmission();
            return error.DecisionLogUnavailable;
        }
        if (self.private_boundary) |boundary| if (self.shard.authoritativeBarrier() - boundary.decision_barrier >= 1024) {
            self.closeAdmission();
            return error.PrivateRecoveryCapacity;
        };
        var candidate = self.shard;
        var candidate_journal = self.decision_journal;
        const before = candidate_journal.last_sequence;
        var rejected: ?anyerror = null;
        const command = trading.applyStable(&candidate, &candidate_journal, input) catch |err| blk: {
            if (err == error.RecoveryAdmissionPending) return err;
            rejected = err;
            break :blk null;
        };
        if (candidate_journal.last_sequence == before) {
            if (rejected == null) return null;
            self.closeAdmission();
            return rejected.?;
        }
        if (self.private_boundary) |boundary| if (candidate.authoritativeBarrier() - boundary.decision_barrier > 1024) {
            self.closeAdmission();
            return error.PrivateRecoveryCapacity;
        };
        var reader = journal.Reader.init(candidate_journal.bytes()) catch {
            self.closeAdmission();
            return error.DecisionLogUnavailable;
        };
        while (true) switch (reader.next() catch {
            self.closeAdmission();
            return error.DecisionLogUnavailable;
        }) {
            .end => break,
            .record => |record| if (record.sequence > before) {
                self.store.append(self.io, .{ .stream = self.stream, .record = record }) catch {
                    self.closeAdmission();
                    return error.DecisionLogUnavailable;
                };
            },
        };
        self.store.commit(self.io, self.stream, candidate_journal.last_sequence) catch {
            self.closeAdmission();
            return error.DecisionLogUnavailable;
        };
        self.shard = candidate;
        self.decision_journal = candidate_journal;
        if (rejected) |err| return err;
        return command;
    }

    pub fn applyAdapterBatch(self: *Owner, batch: canonical.AdapterOutputBatch) !void {
        for (batch.slice()) |record| _ = try self.apply(.{ .venue = record });
    }

    fn closeAdmission(self: *Owner) void {
        self.closed = true;
        self.shard.recovery_admission_pending = true;
    }

    /// Recovery owns the exhaustive durable ingress sweep. The trusted Venue
    /// consumer must drain/apply every newly decoded fact before returning.
    /// A fault or incomplete sweep leaves admission closed; successful replay
    /// never clears the shard's durable economic/OMS safety latches.
    pub fn replayCommittedIngress(self: *Owner, stream: durable.StreamIdentity, consumer: raw_ingress.ReplayConsumer) !void {
        const bound = self.recovery_ingress orelse return error.DecisionLogUnavailable;
        const ingress_store = self.recovery_ingress_store orelse return error.DecisionLogUnavailable;
        if (!self.ready or self.closed or !self.shard.recovery_admission_pending or
            self.store.safetyGate() != .open or !std.meta.eql(stream, bound))
            return error.DecisionLogUnavailable;
        if (self.private_boundary != null and !self.private_seed_restored) return error.PrivateRecoveryBoundaryUnavailable;
        const before = try ingress_store.recover(self.io, stream);
        if (self.private_boundary) |boundary|
            try raw_ingress.replayCommittedAfter(ingress_store, self.io, stream, boundary.raw_sequence, 2 * 1024 * 1024, consumer)
        else
            try raw_ingress.replayCommitted(ingress_store, self.io, stream, consumer);
        const after = try ingress_store.recover(self.io, stream);
        if (self.closed or self.store.safetyGate() != .open or after.gate != .open or
            after.last_sequence != before.last_sequence or after.committed_barrier != before.committed_barrier)
            return error.DecisionLogUnavailable;
        self.recovery_ingress_verified = true;
        self.shard.recovery_admission_pending = self.checkpoint_pending;
        self.recovery_ingress_store = null;
    }

    /// Seal a genuinely ingested bootstrap before allowing dispatch.
    pub fn sealBootstrap(self: *Owner) !void {
        if (self.ready or self.shard.recovery_admission_pending)
            return error.DecisionLogUnavailable;
        self.checkpointCommitted() catch return error.DecisionLogUnavailable;
        self.ready = true;
    }

    /// Publish a complete old barrier before its verified continuation can
    /// reclaim the resident trace. No candidate becomes sendable before commit.
    pub fn checkpoint(self: *Owner) !void {
        if (!self.ready) return error.DecisionLogUnavailable;
        if (self.checkpoint_pending and self.decision_journal.records == 0) return self.completeCheckpoint();
        self.checkpointCommitted() catch return error.DecisionLogUnavailable;
    }

    pub fn checkpointPrivate(self: *Owner, boundary: PrivateRecoveryBoundary, seed: []const u8) !void {
        errdefer self.closeAdmission();
        try validatePrivateBoundary(boundary);
        if (!self.ready or self.closed or self.checkpoint_pending or seed.len == 0 or seed.len > self.private_resume.len or
            boundary.schema != 1 or boundary.decision_stream != self.stream.id or
            boundary.decision_barrier != self.shard.authoritativeBarrier() or
            !std.mem.eql(u8, &boundary.core_digest, &self.shard.canonicalStateDigest()))
            return error.PrivateRecoveryBoundaryUnavailable;
        var seed_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(seed, &seed_digest, .{});
        if (!std.mem.eql(u8, &seed_digest, &boundary.seed_digest)) return error.InvalidPrivateResumeCheckpoint;
        self.private_boundary = boundary;
        @memcpy(self.private_resume[0..seed.len], seed);
        self.private_resume_len = seed.len;
        try self.checkpoint();
    }

    fn durableSnapshot(self: *const Owner, core_snapshot: []const u8, destination: []u8) ![]const u8 {
        const boundary = self.private_boundary orelse return core_snapshot;
        if (destination.len < 20) return error.SnapshotTooLarge;
        const metadata = try @import("snapshot_codec.zig").encodeBare(destination[20..], boundary);
        const len = 20 + metadata.len + core_snapshot.len + self.private_resume_len;
        if (len > destination.len) return error.SnapshotTooLarge;
        @memcpy(destination[0..8], private_bundle_magic);
        std.mem.writeInt(u32, destination[8..12], @intCast(metadata.len), .little);
        std.mem.writeInt(u32, destination[12..16], @intCast(core_snapshot.len), .little);
        std.mem.writeInt(u32, destination[16..20], @intCast(self.private_resume_len), .little);
        @memcpy(destination[20 + metadata.len ..][0..core_snapshot.len], core_snapshot);
        @memcpy(destination[20 + metadata.len + core_snapshot.len ..][0..self.private_resume_len], self.private_resume[0..self.private_resume_len]);
        return destination[0..len];
    }

    /// Resume an already durable rotation; recovery itself never writes or sends.
    pub fn completeCheckpoint(self: *Owner) !void {
        errdefer self.closeAdmission();
        if (!self.ready or self.closed or !self.checkpoint_pending or self.decision_journal.records != 0 or self.store.safetyGate() != .open)
            return error.DecisionLogUnavailable;
        const barrier = self.shard.authoritativeBarrier();
        const generation = try std.math.add(u64, self.shard.checkpointGeneration(), 1);
        const archive = try self.store.archiveReceipt(self.io, self.stream);
        if (!std.meta.eql(archive.stream, self.stream) or archive.covered_first != 1 or archive.covered_last != barrier or
            archive.segment_count != generation or !try self.store.verifyArchiveReceipt(self.io, self.stream, barrier, archive.ordered_root))
            return error.DecisionLogUnavailable;
        const receipt = try self.shard.checkpointReceipt(self.stream.id, generation, archive.ordered_root);
        try self.commitCheckpointReceipt(receipt);
    }
    fn checkpointCommitted(self: *Owner) !void {
        errdefer self.closeAdmission();
        if (self.closed or self.store.safetyGate() != .open or self.shard.authoritativeBarrier() == 0 or
            self.shard.authoritativeBarrier() != self.decision_journal.last_sequence or self.decision_journal.records == 0)
            return error.DecisionLogUnavailable;
        const barrier = self.shard.authoritativeBarrier();
        const generation = try std.math.add(u64, self.shard.checkpointGeneration(), 1);
        var sealed = self.decision_journal;
        if (!sealed.sealed) try sealed.seal();
        var snapshot_buffer: [durable.max_snapshot_bytes]u8 = undefined;
        const core_snapshot = try self.shard.snapshot(&sealed, barrier, &snapshot_buffer);
        var bundle_buffer: [durable.max_snapshot_bytes]u8 = undefined;
        const snapshot = try self.durableSnapshot(core_snapshot, &bundle_buffer);
        if (!self.decision_journal.sealed) try self.store.seal(self.io, self.stream);
        // A recovered seal may already have published this exact barrier.
        // Reuse its committed snapshot: the restart admission fence is runtime
        // state and must not create a conflicting snapshot object at that barrier.
        var already_published = false;
        if (self.checkpoint_pending and self.decision_journal.sealed) {
            const published = try self.store.recover(self.io, self.stream);
            if (published.snapshot_barrier == barrier and published.snapshot.len != 0) {
                const view = try privateCheckpointView(published.snapshot);
                const restored = try trading.TradingShard.restoreSnapshot(view.core_snapshot);
                if (restored.barrier != barrier or !std.mem.eql(u8, &restored.shard.canonicalStateDigest(), &self.shard.canonicalStateDigest()))
                    return error.DecisionLogUnavailable;
                already_published = true;
            }
        }
        if (!already_published) try self.store.publishSnapshot(self.io, self.stream, barrier, snapshot);
        try self.store.rotate(self.io, self.stream);
        const archive = try self.store.archiveReceipt(self.io, self.stream);
        var payload_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(sealed.bytes(), &payload_digest, .{});
        if (!std.meta.eql(archive.stream, self.stream) or archive.covered_first != 1 or archive.covered_last != barrier or
            archive.segment_count != generation or archive.latest_first_sequence != barrier - sealed.records + 1 or
            archive.latest_last_sequence != barrier or archive.latest_byte_len != sealed.bytes().len or
            !std.mem.eql(u8, &archive.latest_payload_digest, &payload_digest))
            return error.DecisionLogUnavailable;
        const receipt = try self.shard.checkpointReceipt(self.stream.id, generation, archive.ordered_root);
        const next_sequence = try std.math.add(u64, barrier, 1);
        self.decision_journal = journal.Journal.initAt(next_sequence);
        try self.commitCheckpointReceipt(receipt);
    }

    fn commitCheckpointReceipt(self: *Owner, receipt: trading.CheckpointReceipt) !void {
        self.committing_checkpoint = true;
        defer self.committing_checkpoint = false;
        _ = try self.apply(.{ .core = .{ .identity = receipt.generation, .payload = .{ .checkpoint_committed = receipt } } });
        self.checkpoint_pending = false;
        if (self.recovery_ingress_verified) self.shard.recovery_admission_pending = false;
    }

    pub fn source(self: *const Owner) !*const trading.TradingShard {
        if (!self.ready or self.closed or self.store.safetyGate() != .open)
            return error.DecisionLogUnavailable;
        return &self.shard;
    }

    /// A read-only, schema-checked copy for the execution role. The source
    /// remains the committed decision owner; this copy grants no send ability.
    pub fn committedSnapshot(self: *const Owner, destination: []u8) ![]const u8 {
        const shard = try self.source();
        var sealed = self.decision_journal;
        if (!sealed.sealed) try sealed.seal();
        return shard.snapshot(&sealed, shard.authoritativeBarrier(), destination);
    }

    pub fn send(self: *const Owner, gateway: *execution.Gateway, guard: *failover.GatewayLeaseGuard, command_id: u64, now_monotonic_ns: u64) !venue.SendResult {
        if (self.checkpoint_pending) return error.DecisionLogUnavailable;
        const shard = try self.source();
        return sendFromShard(shard, gateway, guard, command_id, now_monotonic_ns);
    }
};

/// The execution process accepts only a sealed decision snapshot whose barrier
/// and digest were supplied by the decision owner on the authenticated channel.
/// The lease guard and durable dispatch store still belong to the execution process.
pub fn sendFromCommittedSnapshot(
    bytes: []const u8,
    expected_barrier: u64,
    expected_digest: [32]u8,
    gateway: *execution.Gateway,
    guard: *failover.GatewayLeaseGuard,
    command_id: u64,
    now_monotonic_ns: u64,
) !venue.SendResult {
    const restored = try trading.TradingShard.restoreSnapshot(bytes);
    if (restored.barrier != expected_barrier or
        !std.mem.eql(u8, &restored.shard.canonicalStateDigest(), &expected_digest))
        return error.DecisionSnapshotMismatch;
    return sendFromShard(&restored.shard, gateway, guard, command_id, now_monotonic_ns);
}

fn sendFromShard(shard: *const trading.TradingShard, gateway: *execution.Gateway, guard: *failover.GatewayLeaseGuard, command_id: u64, now_monotonic_ns: u64) !venue.SendResult {
    var command: ?trading.OrderCommand = null;
    for (shard.oms.command_history[0..shard.oms.command_history_count]) |known| {
        if (known.command_id == command_id) {
            command = known;
            break;
        }
    }
    const current = command orelse return error.NotSent;
    if (shard.recovery_admission_pending and current.operation != .cancel) return error.DecisionLogUnavailable;
    requireSafeDemoExposure(&shard.canonical_account, current.side == .sell, shard.activatedAssets()) catch return error.NotSent;
    const position = shard.currentNetExchangePosition(current.instrument) orelse return error.NotSent;
    try gateway.observeAuthority(.{
        .account = shard.exchange_account_identity,
        .effective_trading_authority = shard.operational_state.effectiveTradingAuthority(),
        .reservation_identity = current.reservation_identity,
        .reservation = current.reservation,
        .primary_lease_expires_at_monotonic_ns = guard.lease.expires_at_ns,
        .fencing_token = guard.lease.token,
        .exchange_position = position,
        .authority_barrier = shard.authoritativeBarrier(),
    });
    return gateway.sendFromShard(shard, command_id, now_monotonic_ns);
}

fn requireSafeDemoExposure(account: *const @import("account_projection.zig").AccountProjection, allow_btc: bool, configured_assets: ?@import("asset_registry.zig").Registry) !void {
    if (!account.valid or account.margin_count != 1) return error.InvalidDemoAccount;
    var saw_btc = false;
    var saw_usdt = false;
    for (account.positions[0..account.position_count]) |position|
        if (position.quantity.lots != 0) return error.NonzeroDemoBaseline;
    for (account.balances[0..account.balance_count]) |balance| {
        if (balance.asset == okx.btc) {
            if (saw_btc) return error.InvalidDemoAccount;
            saw_btc = true;
        } else if (balance.asset == okx.usdt) {
            if (saw_usdt) return error.InvalidDemoAccount;
            saw_usdt = true;
        }
        if (balance.total.asset != balance.asset or balance.available.asset != balance.asset or balance.held.asset != balance.asset or
            balance.total.atoms < 0 or balance.available.atoms < 0 or balance.held.atoms < 0 or
            balance.available.atoms > balance.total.atoms)
            return error.InvalidDemoAccount;
        if (balance.held.atoms != 0) return error.NonzeroDemoBaseline;
        if (balance.liability == null or balance.isolated_liability == null or balance.cross_liability == null)
            return error.InvalidDemoAccount;
        for ([_]?canonical.AssetAmount{ balance.liability, balance.isolated_liability, balance.cross_liability }) |debt|
            if (debt) |amount| {
                if (amount.asset != balance.asset) return error.InvalidDemoAccount;
                if (amount.atoms != 0) return error.NonzeroDemoBaseline;
            };
        if (balance.asset == okx.btc) {
            if (!allow_btc and balance.total.atoms != 0) return error.NonzeroDemoBaseline;
        } else if (balance.asset != okx.usdt and
            (balance.total.atoms != 0 or balance.available.atoms != 0 or balance.held.atoms != 0))
        {
            const assets = configured_assets orelse return error.NonzeroDemoBaseline;
            _ = assets.get(balance.asset) orelse return error.InvalidDemoAccount;
            _ = account.nativeAvailable(balance.asset) orelse return error.InvalidDemoAccount;
        }
    }
    for (account.margins[0..account.margin_count]) |margin| {
        if (margin.instrument != null) return error.NonzeroDemoBaseline;
        if (margin.amount) |amount| {
            if (amount.asset != okx.usdt or margin.initial_margin == null or
                margin.maintenance_margin == null or margin.isolated_equity == null)
                return error.InvalidDemoAccount;
            if (margin.initial_margin.?.atoms != 0 or margin.maintenance_margin.?.atoms != 0 or margin.isolated_equity.?.atoms != 0)
                return error.NonzeroDemoBaseline;
        } else {
            const observed = margin.usd_valuation orelse return error.InvalidDemoAccount;
            if (observed.initial_margin == null or observed.maintenance_margin == null or observed.isolated_equity == null)
                return error.InvalidDemoAccount;
            if (observed.initial_margin.?.coefficient != 0 or observed.maintenance_margin.?.coefficient != 0 or observed.isolated_equity.?.coefficient != 0)
                return error.NonzeroDemoBaseline;
        }
    }
    // OKX full balance snapshots list nonzero assets only; absent BTC is zero.
    if (!saw_usdt) return error.InvalidDemoAccount;
}

pub fn requireZeroDemoExposure(account: *const @import("account_projection.zig").AccountProjection) !void {
    return requireSafeDemoExposure(account, false, null);
}

test "Demo owner commits before publication and recovers only a complete barrier" {
    const fixture = @import("trading_shard_fixture.zig");
    const host = @import("strategy_host_gateway.zig");
    const authorization: host.Authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 1 };
    const genesis = fixture.genesisEvents(authorization, .cash);
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    var owner = try Owner.bootstrap(memory.interface(), undefined, stream);
    try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
    var gateway: execution.Gateway = .{};
    var dummy_guard: failover.GatewayLeaseGuard = undefined;
    try std.testing.expectError(error.DecisionLogUnavailable, owner.send(&gateway, &dummy_guard, 1, 1));
    var spot_rules = genesis[0];
    spot_rules.core.payload.instrument_rules_activated.base_asset = 0x425443;
    _ = try owner.apply(spot_rules);
    try std.testing.expectEqual(owner.shard.authoritativeBarrier(), (try memory.interface().recover(undefined, stream)).committed_barrier);
    try owner.sealBootstrap();
    const source = try owner.source();
    try std.testing.expectEqual(@as(u64, 2), source.authoritativeBarrier());
    try std.testing.expectEqual(@as(u64, 1), source.checkpointGeneration());
    var restored = try Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &source.canonicalStateDigest(), &(try restored.source()).canonicalStateDigest());
    _ = try owner.apply(genesis[1]);
    _ = try owner.apply(genesis[6]);
    try @import("venue_adapter_contract.zig").activateTestAssets(&owner);
    var account_snapshot = fixture.canonicalAt(2, 1, .{ .account_bootstrap_snapshot = .{
        .identity = 1,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 1,
        .source_sequence = 1,
        .balance_count = 1,
        .position_count = 0,
        .margin_count = 0,
    } });
    account_snapshot.venue.event.account_bootstrap_snapshot.balances[0] = .{
        .asset = 0x425443,
        .total = .{ .asset = 0x425443, .atoms = 123 },
        .available = .{ .asset = 0x425443, .atoms = 123 },
        .held = .{ .asset = 0x425443, .atoms = 0 },
    };
    var adapter_output: canonical.AdapterOutputBatch = .{};
    try adapter_output.append(account_snapshot.venue);
    try owner.applyAdapterBatch(adapter_output);
    for (0..canonical.max_account_facts + 1) |index| {
        const sequence: u64 = @intCast(index + 2);
        _ = try owner.apply(fixture.canonicalAt(3 + sequence, sequence, .{ .account_observed = .{
            .identity = 100 + index,
            .exchange_account = 2,
            .bootstrap = 1,
            .source_stream = 1,
            .source_sequence = sequence,
            .value = .{ .margin = .{ .value = .{ .amount = .{ .asset = 1, .atoms = 100 } } } },
        } }));
    }
    restored = try Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &(try restored.source()).canonicalStateDigest());
    var snapshot_storage: [durable.max_snapshot_bytes]u8 = undefined;
    const snapshot = try owner.committedSnapshot(&snapshot_storage);
    const snapshot_copy = try trading.TradingShard.restoreSnapshot(snapshot);
    try std.testing.expectEqual(owner.shard.authoritativeBarrier(), snapshot_copy.barrier);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &snapshot_copy.shard.canonicalStateDigest());
    try std.testing.expect((try restored.source()).canonical_account.valid);
    try std.testing.expectEqual(@as(i128, 123), (try restored.source()).currentNetExchangePosition(3).?.lots);
    var invalid = fixture.canonicalAt(3, 2, .{ .account_bootstrap_snapshot = .{
        .identity = 2,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 1,
        .source_sequence = 2,
        .balance_count = 0,
        .position_count = 0,
        .margin_count = 0,
    } });
    invalid.venue.envelope.schema_version = 99;
    try std.testing.expectError(error.UnsupportedSchema, restored.apply(invalid));
    try std.testing.expectError(error.DecisionLogUnavailable, restored.send(&gateway, &dummy_guard, 1, 1));
    memory.injectFault(.eio);
    try std.testing.expectError(error.DecisionLogUnavailable, owner.apply(genesis[2]));
    try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
    try std.testing.expectError(error.DecisionLogUnavailable, owner.committedSnapshot(&snapshot_storage));
}

test "Demo owner closes persistence faults at their last proven barrier" {
    const fixture = @import("trading_shard_fixture.zig");
    const host = @import("strategy_host_gateway.zig");
    const authorization: host.Authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 1 };
    const genesis = fixture.genesisEvents(authorization, .cash);
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 93 };
    const Case = struct { point: durable.FaultPoint, seal: bool, expected_last: u64, expected_barrier: u64 };
    const cases = [_]Case{
        .{ .point = .append, .seal = false, .expected_last = 0, .expected_barrier = 0 },
        .{ .point = .commit, .seal = false, .expected_last = 1, .expected_barrier = 0 },
        .{ .point = .publish, .seal = true, .expected_last = 1, .expected_barrier = 1 },
    };
    for (cases) |case| {
        var memory = durable.MemoryAdapter.init();
        defer memory.deinit();
        var owner = try Owner.bootstrap(memory.interface(), undefined, stream);
        if (case.seal) {
            _ = try owner.apply(genesis[0]);
            memory.injectFaultAt(.eio, case.point);
            try std.testing.expectError(error.DecisionLogUnavailable, owner.sealBootstrap());
        } else {
            memory.injectFaultAt(.eio, case.point);
            try std.testing.expectError(error.DecisionLogUnavailable, owner.apply(genesis[0]));
        }
        const recovered = try memory.interface().recover(undefined, stream);
        try std.testing.expectEqual(durable.GateState.closed, memory.interface().safetyGate());
        try std.testing.expectEqual(case.expected_last, recovered.last_sequence);
        try std.testing.expectEqual(case.expected_barrier, recovered.committed_barrier);
        try std.testing.expectError(error.DecisionLogUnavailable, Owner.recover(memory.interface(), undefined, stream));
    }
}

fn setupOwnerCheckpointFixture(owner: *Owner) !trading.OrderCommand {
    const fixture = @import("trading_shard_fixture.zig");
    const genesis = fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged);
    for (genesis) |event| _ = try owner.apply(event);
    _ = try owner.apply(fixture.atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{
        .strategy_identity = 1,
        .config_version = 1,
        .activation_identity = 1,
        .session = .{ .fencing = 1, .shard = 0, .generation = 1 },
        .activation_barrier = 0,
        .state_digest = owner.shard.canonicalStateDigest(),
    } } }));
    try owner.sealBootstrap();
    _ = try owner.apply(fixture.atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = 3, .price_atoms = 50_000_000_000 } } }));
    _ = try owner.apply(fixture.canonicalAt(12, 99, .{ .instrument_definition_observed = .{ .instrument = 3, .rules_version = 1 } }));
    _ = try owner.apply(fixture.snapshotAt(13, 100));
    _ = try owner.apply(fixture.deltaAt(14, 100, 101, 49_850_000_000));
    const command = (try owner.apply(fixture.atGroup(15, .{ .identity = 1, .payload = .{ .timer = fixture.timer(fixture.happy_order_quantity) } }))) orelse return error.MissingOrderCommand;
    const facts = try fixture.happyVenueFacts(command);
    for (facts[0..4]) |event| _ = try owner.apply(event);
    // A transport uncertainty never discards already applied economics.
    _ = try owner.apply(fixture.canonicalAt(19, 106, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .unknown } }));
    return command;
}

fn checkOwnerCheckpointRounds(store: durable.Store, io: std.Io) ![32]u8 {
    const fixture = @import("trading_shard_fixture.zig");
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 903 };
    var owner = try Owner.bootstrap(store, io, stream);
    const command = try setupOwnerCheckpointFixture(&owner);
    const initial_barrier = owner.shard.authoritativeBarrier();
    const reservation = try owner.shard.activeReservationAtoms();
    const initial_authority = try owner.shard.currentDispatchAuthorityRefs(3);
    const initial_command = owner.shard.oms.command_history[0];
    for (0..100) |round| {
        for (0..8) |offset| {
            const identity = 10_000 + round * 8 + offset;
            _ = try owner.apply(fixture.atGroup(identity, .{ .identity = identity, .payload = .{ .mark_price = .{ .instrument = 3, .price_atoms = 50_000_000_000 + @as(i128, @intCast(identity)) } } }));
        }
        try owner.checkpoint();
        try std.testing.expectEqual(@as(u64, round + 2), owner.shard.checkpointGeneration());
        try std.testing.expectEqual(trading.oms.OrderState.unknown, owner.shard.oms.orderById(command.order_id).?.state);
        try std.testing.expectEqual(@as(i64, 40), owner.shard.economicSummary().portfolio.swap.quantity);
        try std.testing.expectEqual(@as(i128, 149_700), owner.shard.economicSummary().portfolio.fee_atoms);
        try std.testing.expectEqual(reservation, try owner.shard.activeReservationAtoms());
        try std.testing.expectEqualDeep(initial_authority, try owner.shard.currentDispatchAuthorityRefs(3));
        try std.testing.expectEqualDeep(initial_command, owner.shard.oms.command_history[0]);
        const recovered = try Owner.recover(store, io, stream);
        try std.testing.expect(recovered.shard.recovery_admission_pending);
        try std.testing.expectEqual(owner.shard.authoritativeBarrier(), recovered.shard.authoritativeBarrier());
        try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
        try std.testing.expectEqual(trading.oms.OrderState.unknown, recovered.shard.oms.orderById(command.order_id).?.state);
        var snapshot_storage: [durable.max_snapshot_bytes]u8 = undefined;
        const snapshot = try owner.committedSnapshot(&snapshot_storage);
        const restored = try trading.TradingShard.restoreSnapshot(snapshot);
        try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &restored.shard.canonicalStateDigest());
    }
    try std.testing.expect(owner.shard.authoritativeBarrier() > initial_barrier + 3 * 256);
    return owner.shard.canonicalStateDigest();
}

fn expectCheckpointBusinessState(actual: *const trading.TradingShard, expected: *const trading.TradingShard) !void {
    try std.testing.expectEqualSlices(u8, &expected.canonicalStateDigest(), &actual.canonicalStateDigest());
    try std.testing.expectEqualDeep(expected.trace.history_head, actual.trace.history_head);
    try std.testing.expectEqualDeep(expected.trace.input_head, actual.trace.input_head);
    try std.testing.expectEqualDeep(expected.trace.pinned_root, actual.trace.pinned_root);
    try std.testing.expectEqualDeep(expected.checkpoint, actual.checkpoint);
    try std.testing.expectEqualDeep(expected.economicSummary(), actual.economicSummary());
    try std.testing.expectEqual(try expected.activeReservationAtoms(), try actual.activeReservationAtoms());
    try std.testing.expectEqualDeep(try expected.currentDispatchAuthorityRefs(3), try actual.currentDispatchAuthorityRefs(3));
    try std.testing.expectEqualDeep(expected.oms.orders[0..expected.oms.order_count], actual.oms.orders[0..actual.oms.order_count]);
    try std.testing.expectEqualDeep(expected.oms.command_history[0..expected.oms.command_history_count], actual.oms.command_history[0..actual.oms.command_history_count]);
    // These are replayed dispatch facts, not calls to a live transport.
    try std.testing.expectEqual(expected.dispatch_attempt_count, actual.dispatch_attempt_count);
    try std.testing.expectEqual(trading.oms.OrderState.unknown, actual.oms.orders[0].state);
    try std.testing.expectEqual(@as(i64, 40), actual.economicSummary().portfolio.swap.quantity);
    try std.testing.expectEqual(@as(i128, 149_700), actual.economicSummary().portfolio.fee_atoms);
}

fn expectCheckpointAdmissionClosed(owner: *const Owner) !void {
    var gateway: execution.Gateway = .{};
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    try std.testing.expectError(error.DecisionLogUnavailable, owner.send(&gateway, &guard, owner.shard.oms.command_history[0].command_id, 2));
    try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
}

test "Checkpoint owner file interruptions preserve coherent Unknown fill economics and authority" {
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.check() catch |err| {
                self.failure = err;
            };
        }
        fn check(_: *@This()) !void {
            const io = std.testing.io;
            const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 903 };
            const input = @import("trading_shard_fixture.zig").atGroup(900, .{ .identity = 900, .payload = .{ .mark_price = .{ .instrument = 3, .price_atoms = 50_000_001_000 } } });
            var reference_temp = std.testing.tmpDir(.{});
            defer reference_temp.cleanup();
            var reference: durable.LinuxFileAdapter = .{ .dir = reference_temp.dir };
            var clean = try Owner.bootstrap(reference.interface(), io, stream);
            _ = try setupOwnerCheckpointFixture(&clean);
            try clean.checkpoint();
            const old = clean.shard;
            _ = try clean.apply(input);
            const before_receipt = clean.shard;
            try clean.checkpoint();
            const new = clean.shard;
            const Case = struct { point: durable.FaultPoint, skip: usize = 0, apply_input: bool = false };
            const cases = [_]Case{
                .{ .point = .append, .apply_input = true },
                .{ .point = .commit, .apply_input = true },
                .{ .point = .root_publish, .apply_input = true },
                .{ .point = .root_publish, .skip = 1, .apply_input = true },
                .{ .point = .seal },
                .{ .point = .publish },
                .{ .point = .snapshot_sync },
                .{ .point = .rotate },
                .{ .point = .archive_sync },
                .{ .point = .reclaim },
                .{ .point = .reclaim, .skip = 1 },
                // seal, snapshot, rotation, receipt append and receipt commit each publish a root.
                .{ .point = .root_publish },
                .{ .point = .root_publish, .skip = 1 },
                .{ .point = .root_publish, .skip = 2 },
                .{ .point = .root_publish, .skip = 3 },
                .{ .point = .root_publish, .skip = 4 },
                .{ .point = .append },
                .{ .point = .commit },
            };
            const faults = [_]durable.Fault{ .short_write, .sync_timeout, .enospc, .eio, .corruption };
            for (faults) |fault| for (cases, 0..) |case, case_index| {
                std.debug.print("owner_file_fault: {s} case={d} point={s} skip={d}\n", .{ @tagName(fault), case_index, @tagName(case.point), case.skip });
                var temp = std.testing.tmpDir(.{});
                defer temp.cleanup();
                var adapter: durable.LinuxFileAdapter = .{ .dir = temp.dir };
                var owner = try Owner.bootstrap(adapter.interface(), io, stream);
                _ = try setupOwnerCheckpointFixture(&owner);
                try owner.checkpoint();
                if (!case.apply_input) _ = try owner.apply(input);
                adapter.injectFaultAfter(fault, case.point, case.skip);
                if (case.apply_input) {
                    if (owner.apply(input)) |_| return error.ExpectedOwnerFault else |_| {}
                } else {
                    if (owner.checkpoint()) |_| return error.ExpectedOwnerFault else |_| {}
                }
                try std.testing.expect(owner.closed);
                try expectCheckpointAdmissionClosed(&owner);
                try std.testing.expectEqual(durable.GateState.closed, adapter.interface().safetyGate());
                // A real partial temporary manifest must never supersede the published root.
                const partial = try temp.dir.createFile(io, "manifest.tmp", .{});
                try partial.writeStreamingAll(io, "partial-manifest");
                partial.close(io);
                var reopened: durable.LinuxFileAdapter = .{ .dir = temp.dir };
                const durable_state = try reopened.interface().recover(io, stream);
                if (durable_state.last_sequence != durable_state.committed_barrier) {
                    try std.testing.expectError(error.DecisionLogUnavailable, Owner.recover(reopened.interface(), io, stream));
                    continue;
                }
                var recovered = try Owner.recover(reopened.interface(), io, stream);
                try std.testing.expect(recovered.shard.recovery_admission_pending);
                try expectCheckpointAdmissionClosed(&recovered);
                const expected = if (case.apply_input) &old else if (recovered.shard.authoritativeBarrier() == new.authoritativeBarrier()) &new else &before_receipt;
                try expectCheckpointBusinessState(&recovered.shard, expected);
                if (recovered.checkpoint_pending) {
                    try recovered.checkpoint();
                    try expectCheckpointBusinessState(&recovered.shard, &new);
                    try expectCheckpointAdmissionClosed(&recovered);
                }
                var again: durable.LinuxFileAdapter = .{ .dir = temp.dir };
                const repeated = try Owner.recover(again.interface(), io, stream);
                try expectCheckpointBusinessState(&repeated.shard, &recovered.shard);
            };
        }
    };
    var context: Context = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Context.run, .{&context});
    thread.join();
    if (context.failure) |err| return err;
}

test "Checkpoint owner explicitly resumes each durable checkpoint interruption without sending" {
    const fixture = @import("trading_shard_fixture.zig");
    for (0..3) |phase| {
        const memory = try std.testing.allocator.create(durable.MemoryAdapter);
        defer std.testing.allocator.destroy(memory);
        memory.* = .init();
        memory.allocator = std.testing.allocator;
        defer memory.deinit();
        const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 904 };
        var owner = try Owner.bootstrap(memory.interface(), undefined, stream);
        for (fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged)) |event|
            _ = try owner.apply(event);
        try owner.sealBootstrap();
        const price: trading.CanonicalEvent = .{ .core = .{ .identity = 900, .payload = .{ .mark_price = .{ .instrument = fixture.swap_instrument, .price_atoms = 50_000_003 } } } };
        _ = try owner.apply(price);
        const before = owner.shard.authoritativeBarrier();
        var sealed = owner.decision_journal;
        try sealed.seal();
        try memory.interface().seal(undefined, stream);
        if (phase >= 1) {
            var bytes: [durable.max_snapshot_bytes]u8 = undefined;
            try memory.interface().publishSnapshot(undefined, stream, before, try owner.shard.snapshot(&sealed, before, &bytes));
        }
        if (phase == 2) try memory.interface().rotate(undefined, stream);
        var recovered = try Owner.recover(memory.interface(), undefined, stream);
        try std.testing.expect(recovered.checkpoint_pending);
        try std.testing.expect(recovered.shard.recovery_admission_pending);
        try std.testing.expectEqual(before, recovered.shard.authoritativeBarrier());
        try std.testing.expectError(error.DecisionLogUnavailable, recovered.apply(price));
        try recovered.checkpoint();
        try std.testing.expect(!recovered.checkpoint_pending);
        try std.testing.expect(recovered.shard.recovery_admission_pending);
        try std.testing.expectEqual(@as(u64, 2), recovered.shard.checkpointGeneration());
        try std.testing.expectEqual(before + 1, recovered.shard.authoritativeBarrier());
        const again = try Owner.recover(memory.interface(), undefined, stream);
        try std.testing.expect(!again.checkpoint_pending);
        try std.testing.expectEqualSlices(u8, &recovered.shard.canonicalStateDigest(), &again.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u64, 0), again.shard.dispatch_attempt_count);
    }
}

test "Checkpoint owner commits 100 rotations with live authority and economic state" {
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.check() catch |err| {
                self.failure = err;
            };
        }
        fn check(_: *@This()) !void {
            const memory = try std.testing.allocator.create(durable.MemoryAdapter);
            defer std.testing.allocator.destroy(memory);
            memory.* = .init();
            memory.allocator = std.testing.allocator;
            defer memory.deinit();
            _ = try checkOwnerCheckpointRounds(memory.interface(), undefined);
        }
    };
    var context: Context = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Context.run, .{&context});
    thread.join();
    if (context.failure) |err| return err;
}

test "Checkpoint owner durable private bundle owns its seed and rejects mixed metadata" {
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.check() catch |err| {
                self.failure = err;
            };
        }
        fn check(_: *@This()) !void {
            const memory = try std.testing.allocator.create(durable.MemoryAdapter);
            defer std.testing.allocator.destroy(memory);
            memory.* = .init();
            memory.allocator = std.testing.allocator;
            defer memory.deinit();
            const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 990 };
            var owner = try Owner.bootstrap(memory.interface(), undefined, stream);
            const fixture = @import("trading_shard_fixture.zig");
            const genesis = fixture.genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged);
            _ = try owner.apply(genesis[0]);
            try owner.sealBootstrap();
            var seed = [_]u8{ 1, 2, 3 };
            var seed_digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(&seed, &seed_digest, .{});
            try owner.checkpointPrivate(.{
                .decision_stream = stream.id,
                .decision_barrier = owner.shard.authoritativeBarrier(),
                .core_digest = owner.shard.canonicalStateDigest(),
                .raw_stream = .{ .domain = .raw_ingress, .id = 991 },
                .raw_sequence = 1,
                .raw_digest = @splat(1),
                .raw_archive_root = @splat(2),
                .adapter_session = 1,
                .canonical_stream = 1,
                .canonical_sequence = 1,
                .seed_digest = seed_digest,
            }, &seed);
            seed[0] = 99;
            try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, owner.private_resume[0..owner.private_resume_len]);
            const recovered = try Owner.recover(memory.interface(), undefined, stream);
            try std.testing.expectEqualSlices(u8, owner.private_resume[0..owner.private_resume_len], recovered.private_resume[0..recovered.private_resume_len]);
            try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest());
            const before = try memory.interface().archiveReceipt(undefined, stream);
            for (0..9) |field| {
                var candidate = owner;
                var invalid = owner.private_boundary.?;
                invalid.decision_barrier = owner.shard.authoritativeBarrier();
                invalid.core_digest = owner.shard.canonicalStateDigest();
                switch (field) {
                    0 => invalid.raw_stream.domain = .control,
                    1 => invalid.raw_stream.id = 0,
                    2 => invalid.raw_sequence = 0,
                    3 => invalid.adapter_session = 0,
                    4 => invalid.canonical_stream = 0,
                    5 => invalid.canonical_sequence = 0,
                    6 => invalid.canonical_stream = 2,
                    7 => invalid.canonical_sequence = std.math.maxInt(u64),
                    8 => invalid.raw_sequence = std.math.maxInt(u64),
                    else => unreachable,
                }
                try std.testing.expectError(error.InvalidPrivateResumeCheckpoint, candidate.checkpointPrivate(invalid, owner.private_resume[0..owner.private_resume_len]));
                try std.testing.expect(candidate.closed);
                try std.testing.expectEqualDeep(before, try memory.interface().archiveReceipt(undefined, stream));
            }
            var core_buffer: [durable.max_snapshot_bytes]u8 = undefined;
            const gateway_snapshot = try owner.committedSnapshot(&core_buffer);
            try std.testing.expect(!std.mem.startsWith(u8, gateway_snapshot, private_bundle_magic));
            const raw_recovery = try memory.interface().recover(undefined, stream);
            var bundle: [durable.max_snapshot_bytes]u8 = undefined;
            @memcpy(bundle[0..raw_recovery.snapshot.len], raw_recovery.snapshot);
            bundle[raw_recovery.snapshot.len - 1] ^= 1;
            try std.testing.expectError(error.InvalidPrivateResumeCheckpoint, privateCheckpointView(bundle[0..raw_recovery.snapshot.len]));
        }
    };
    var context: Context = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Context.run, .{&context});
    thread.join();
    if (context.failure) |err| return err;
}

test "Checkpoint owner rejects a valid receipt bound to a foreign decision stream" {
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.check() catch |err| {
                self.failure = err;
            };
        }
        fn check(_: *@This()) !void {
            const memory = try std.testing.allocator.create(durable.MemoryAdapter);
            defer std.testing.allocator.destroy(memory);
            memory.* = .init();
            memory.allocator = std.testing.allocator;
            defer memory.deinit();
            const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 994 };
            var owner = try Owner.bootstrap(memory.interface(), undefined, stream);
            const genesis = @import("trading_shard_fixture.zig").genesisEvents(.{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 0 }, .leveraged);
            _ = try owner.apply(genesis[0]);
            var sealed = owner.decision_journal;
            try sealed.seal();
            var buffer: [durable.max_snapshot_bytes]u8 = undefined;
            try memory.interface().seal(undefined, stream);
            try memory.interface().publishSnapshot(undefined, stream, 1, try owner.shard.snapshot(&sealed, 1, &buffer));
            try memory.interface().rotate(undefined, stream);
            const archive = try memory.interface().archiveReceipt(undefined, stream);
            const receipt = try owner.shard.checkpointReceipt(995, 1, archive.ordered_root);
            var tail = journal.Journal.initAt(2);
            _ = try trading.applyStable(&owner.shard, &tail, .{ .core = .{ .identity = 1, .payload = .{ .checkpoint_committed = receipt } } });
            var reader = try journal.Reader.init(tail.bytes());
            while (true) switch (try reader.next()) {
                .end => break,
                .record => |record| try memory.interface().append(undefined, .{ .stream = stream, .record = record }),
            };
            try memory.interface().commit(undefined, stream, 2);
            try tail.seal();
            try memory.interface().seal(undefined, stream);
            try memory.interface().publishSnapshot(undefined, stream, 2, try owner.shard.snapshot(&tail, 2, &buffer));
            try std.testing.expect(try memory.interface().verifyArchiveReceipt(undefined, stream, 1, receipt.archive_root));
            try std.testing.expectError(error.DecisionLogUnavailable, Owner.recover(memory.interface(), undefined, stream));
        }
    };
    var context: Context = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Context.run, .{&context});
    thread.join();
    if (context.failure) |err| return err;
}

test "Checkpoint owner Windows file commits 100 rotations and reopens without sending" {
    if (@import("builtin").os.tag != .windows) return;
    const Context = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.check() catch |err| {
                self.failure = err;
            };
        }
        fn check(_: *@This()) !void {
            var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var path_buffer: [260]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "C:\\Windows\\Temp\\ringwin-owner-checkpoint-{d}", .{std.Io.Clock.real.now(io).nanoseconds});
            try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
            defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
            var expected: [32]u8 = undefined;
            {
                var file = try durable.WindowsFileAdapter.openWindowsVerification(io, path);
                defer file.close(io);
                expected = try checkOwnerCheckpointRounds(file.interface(), io);
            }
            var reopened = try durable.WindowsFileAdapter.openWindowsVerification(io, path);
            defer reopened.close(io);
            const recovered = try Owner.recover(reopened.interface(), io, .{ .domain = .decision_log, .id = 903 });
            try std.testing.expectEqual(@as(u64, 101), recovered.shard.checkpointGeneration());
            try std.testing.expect(recovered.shard.recovery_admission_pending);
            try std.testing.expectEqualSlices(u8, &expected, &recovered.shard.canonicalStateDigest());
        }
    };
    var context: Context = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Context.run, .{&context});
    thread.join();
    if (context.failure) |err| return err;
}

fn checkDemoPolicyGateway(fail_persistence: bool) !void {
    const fixture = @import("trading_shard_fixture.zig");
    var parsed = try Policy.parse(std.testing.allocator,
        \\{"schema":3,"price_tick_atoms":100000,"lot_size":{"coefficient":1,"scale":8},"startup":"virgin","exchange_account":2,"portfolio_identity":1,"strategy_identity":40,"activation_identity":50,"config_version":1,"portfolio_allocation_atoms":20000000,"risk_limit_atoms":10000000,"decision_stream_id":91,"dispatch_stream_id":92,"decision_domain":1,"node_identity":1}
    );
    defer parsed.deinit();
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const dispatch_memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(dispatch_memory);
    dispatch_memory.* = .init();
    defer dispatch_memory.deinit();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    var owner = try Owner.bootstrap(memory.interface(), undefined, stream);
    const definitions = @import("asset_registry.zig").testDefinitions(6, 8);
    parsed.value.asset_definitions = &definitions;
    try parsed.value.activateAssetsForOfflineValidation(&owner);
    var snapshot = fixture.canonicalAt(1, 1, .{ .account_bootstrap_snapshot = .{
        .identity = 1,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 1,
        .source_sequence = 1,
        .balance_count = 2,
        .position_count = 0,
        .margin_count = 1,
    } });
    snapshot.venue.event.account_bootstrap_snapshot.balances[0] = .{
        .asset = okx.usdt,
        .total = .{ .asset = okx.usdt, .atoms = 25_000_000 },
        .cash_balance = .{ .asset = okx.usdt, .atoms = 25_000_000 },
        .available = .{ .asset = okx.usdt, .atoms = 25_000_000 },
        .held = .{ .asset = okx.usdt, .atoms = 0 },
        .liability = .{ .asset = okx.usdt, .atoms = 0 },
        .isolated_liability = .{ .asset = okx.usdt, .atoms = 0 },
        .cross_liability = .{ .asset = okx.usdt, .atoms = 0 },
    };
    snapshot.venue.event.account_bootstrap_snapshot.balances[1] = .{
        .asset = okx.btc,
        .total = .{ .asset = okx.btc, .atoms = 0 },
        .cash_balance = .{ .asset = okx.btc, .atoms = 0 },
        .available = .{ .asset = okx.btc, .atoms = 0 },
        .held = .{ .asset = okx.btc, .atoms = 0 },
        .liability = .{ .asset = okx.btc, .atoms = 0 },
        .isolated_liability = .{ .asset = okx.btc, .atoms = 0 },
        .cross_liability = .{ .asset = okx.btc, .atoms = 0 },
    };
    snapshot.venue.event.account_bootstrap_snapshot.margins[0] = .{
        .amount = .{ .asset = okx.usdt, .atoms = 25_000_000 },
        .initial_margin = .{ .asset = okx.usdt, .atoms = 0 },
        .maintenance_margin = .{ .asset = okx.usdt, .atoms = 0 },
        .isolated_equity = .{ .asset = okx.usdt, .atoms = 0 },
    };
    snapshot.venue.event.account_bootstrap_snapshot.positions[0] = .{
        .instrument = okx.btc_usdt_spot,
        .side = .net,
        .quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 0 },
    };
    _ = try owner.apply(snapshot);
    const clean_account = owner.shard.canonical_account;
    try requireSafeDemoExposure(&clean_account, false, null);
    var missing_btc = clean_account;
    missing_btc.balance_count = 1;
    try requireSafeDemoExposure(&missing_btc, false, null);
    var btc_debt = clean_account;
    btc_debt.balances[1].liability.?.atoms = 1;
    try std.testing.expectError(error.NonzeroDemoBaseline, requireSafeDemoExposure(&btc_debt, false, null));
    var usdt_cross_debt = clean_account;
    usdt_cross_debt.balances[0].cross_liability.?.atoms = 1;
    try std.testing.expectError(error.NonzeroDemoBaseline, requireSafeDemoExposure(&usdt_cross_debt, false, null));
    var usdt_isolated_debt = clean_account;
    usdt_isolated_debt.balances[0].isolated_liability.?.atoms = 1;
    try std.testing.expectError(error.NonzeroDemoBaseline, requireSafeDemoExposure(&usdt_isolated_debt, false, null));
    var borrowed_without_field = clean_account;
    borrowed_without_field.balances[1].liability = null;
    try std.testing.expectError(error.InvalidDemoAccount, requireSafeDemoExposure(&borrowed_without_field, false, null));
    var margin_used = clean_account;
    margin_used.margins[0].initial_margin.?.atoms = 1;
    try std.testing.expectError(error.NonzeroDemoBaseline, requireSafeDemoExposure(&margin_used, false, null));
    margin_used = clean_account;
    margin_used.margins[0].maintenance_margin.?.atoms = 1;
    try std.testing.expectError(error.NonzeroDemoBaseline, requireSafeDemoExposure(&margin_used, false, null));
    margin_used = clean_account;
    margin_used.margins[0].isolated_equity.?.atoms = 1;
    try std.testing.expectError(error.NonzeroDemoBaseline, requireSafeDemoExposure(&margin_used, false, null));
    var extra_asset = clean_account;
    extra_asset.balances[2] = .{ .asset = 99, .total = .{ .asset = 99, .atoms = 1 }, .available = .{ .asset = 99, .atoms = 1 }, .held = .{ .asset = 99, .atoms = 0 }, .liability = .{ .asset = 99, .atoms = 0 }, .isolated_liability = .{ .asset = 99, .atoms = 0 }, .cross_liability = .{ .asset = 99, .atoms = 0 } };
    extra_asset.balance_count = 3;
    try std.testing.expectError(error.NonzeroDemoBaseline, requireSafeDemoExposure(&extra_asset, false, null));
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    authority.available = false;
    try std.testing.expectError(error.InvalidDemoLease, parsed.value.initialize(&owner, 50_000_000, &guard, 1, 1));
    try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
    authority.available = true;
    try parsed.value.initializePendingHost(&owner, 50_000_000, &guard, 1, 1);
    try std.testing.expect(owner.shard.risk_lease_valid_through_barrier >= owner.shard.authoritativeBarrier() + 100);
    try std.testing.expectEqual(@as(u64, 15 * std.time.ns_per_s), owner.shard.registryInstrument(okx.btc_usdt_spot).?.capability.?.max_dispatch_age_ns);
    try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
    const activation_barrier = owner.shard.authoritativeBarrier();
    const activation_digest = owner.shard.canonicalStateDigest();
    const host_session: @import("strategy_host_ipc.zig").Session = .{ .fencing = lease.token, .shard = 0, .generation = 1 };
    try std.testing.expectError(error.InvalidHostActivation, parsed.value.activateHost(&owner, host_session, activation_barrier + 1, activation_digest));
    try std.testing.expectError(error.InvalidHostActivation, parsed.value.activateHost(&owner, .{ .fencing = lease.token, .shard = 0, .generation = 0 }, activation_barrier, activation_digest));
    try parsed.value.activateHost(&owner, host_session, activation_barrier, activation_digest);
    _ = try owner.apply(fixture.canonicalAt(18, 2, .{ .instrument_definition_observed = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1 } }));
    var book = fixture.snapshotAt(19, 3);
    book.venue.event.l2_book_snapshot.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_bid.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_ask.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_bid_quantity.?.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.best_ask_quantity.?.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.next_ask.?.instrument = okx.btc_usdt_spot;
    book.venue.event.l2_book_snapshot.next_ask_quantity.?.instrument = okx.btc_usdt_spot;
    _ = try owner.apply(book);
    try std.testing.expect((try owner.source()).operational_state.effectiveTradingAuthority());
    try std.testing.expectEqual(@as(i64, 10_000_000), (try owner.source()).risk_lease_atoms);
    const recovered = try Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &(try owner.source()).canonicalStateDigest(), &(try recovered.source()).canonicalStateDigest());

    const Spy = struct {
        sends: u64 = 0,
        fn adapter(self: *@This()) venue.VenueAdapter {
            return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
        }
        fn start(_: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
            if (config.environment != .demo) return error.InvalidConfig;
        }
        fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
            switch (request) {
                .order_command => {},
                else => return error.InvalidRequest,
            }
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.sends += 1;
            return .accepted;
        }
        fn drain(_: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
            return null;
        }
        fn stop(_: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {}
    };
    var spy: Spy = .{};
    const adapter = spy.adapter();
    try adapter.start(.{ .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1 });
    var gateway: execution.Gateway = .{};
    try gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .environment = .demo, .lease_guard = &guard, .capability = .{
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .session = 1,
        .supports_post_only = true,
        .supports_market_protection = true,
    } });
    try gateway.bootstrapDurableDispatch(dispatch_memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    const sequence = owner.shard.authoritativeBarrier() + 1;
    const intent: @import("strategy_host_gateway.zig").OrderIntent = .{
        .strategy_identity = 40,
        .intent_sequence = sequence,
        .strategy_cursor = owner.shard.authoritativeBarrier(),
        .config_version = 1,
        .activation_identity = 50,
        .portfolio_identity = 1,
        .exchange_account_identity = 2,
        .instrument_identity = okx.btc_usdt_spot,
        .side = .buy,
        .order_type = .limit,
        .time_in_force = .immediate_or_cancel,
        .portfolio_reduce_only = false,
        .quantity = 20_000,
        .limit_price_micros = 50_000_000,
    };
    const maybe_command = try owner.apply(.{ .core = .{ .identity = sequence, .monotonic_time = 2, .time_presence = .{ .monotonic = true }, .payload = .{ .external_order_intent = intent } } });
    try std.testing.expectEqual(@import("trading_shard_event.zig").RejectReason.none, owner.shard.last_reject_reason);
    const command = maybe_command orelse return error.MissingDemoCommand;
    try std.testing.expectEqual(@as(i128, 500), command.limit_price.ticks);
    var snapshot_storage: [durable.max_snapshot_bytes]u8 = undefined;
    const committed = try owner.committedSnapshot(&snapshot_storage);
    const digest = owner.shard.canonicalStateDigest();
    var wrong_digest = digest;
    wrong_digest[0] ^= 1;
    try std.testing.expectError(error.DecisionSnapshotMismatch, sendFromCommittedSnapshot(committed, owner.shard.authoritativeBarrier(), wrong_digest, &gateway, &guard, command.command_id, 2));
    try std.testing.expectError(error.DecisionSnapshotMismatch, sendFromCommittedSnapshot(committed, owner.shard.authoritativeBarrier() + 1, digest, &gateway, &guard, command.command_id, 2));
    try std.testing.expectEqual(@as(u64, 0), spy.sends);
    try std.testing.expectEqual(venue.SendResult.accepted, try sendFromCommittedSnapshot(committed, owner.shard.authoritativeBarrier(), digest, &gateway, &guard, command.command_id, 2));
    try std.testing.expectEqual(@as(u64, 1), spy.sends);
    var recovering = try Owner.recover(memory.interface(), undefined, stream);
    // The same qualified pending-submit command was admitted immediately
    // above. Calling Gateway directly cannot bypass restart admission.
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(&recovering.shard, command.command_id, 2));
    try std.testing.expectError(error.DecisionLogUnavailable, recovering.send(&gateway, &guard, command.command_id, 2));
    const pending_snapshot = try recovering.committedSnapshot(&snapshot_storage);
    const pending_copy = try trading.TradingShard.restoreSnapshot(pending_snapshot);
    try std.testing.expect(pending_copy.shard.recovery_admission_pending);
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(&pending_copy.shard, command.command_id, 2));
    try std.testing.expectError(error.DecisionLogUnavailable, sendFromCommittedSnapshot(pending_snapshot, recovering.shard.authoritativeBarrier(), digest, &gateway, &guard, command.command_id, 2));
    const pending_barrier = recovering.shard.authoritativeBarrier();
    try std.testing.expectError(error.RecoveryAdmissionPending, recovering.apply(.{ .core = .{ .identity = sequence, .payload = .{ .external_order_intent = intent } } }));
    try std.testing.expectError(error.RecoveryAdmissionPending, recovering.apply(.{ .core = .{ .identity = sequence, .payload = .{ .timer = .{ .side = .buy, .time_in_force = .immediate_or_cancel, .portfolio_reduce_only = true, .quantity = 1, .limit_price_micros = 50_000_000 } } } }));
    var pending_group: @import("oms.zig").IntentGroup = .{ .first_intent_sequence = 999, .count = 1 };
    pending_group.members[0] = .{
        .intent_sequence = pending_group.first_intent_sequence,
        .operation = .place,
        .instrument = command.instrument,
        .quantity = 1,
        .limit_price = command.limit_price,
    };
    try std.testing.expectError(error.RecoveryAdmissionPending, recovering.apply(.{ .core = .{ .identity = sequence, .payload = .{ .oms_intent_group = pending_group } } }));
    pending_group.count = @intCast(pending_group.members.len + 1);
    try std.testing.expectError(error.InvalidIntentGroup, recovering.shard.apply(.{ .core = .{ .identity = sequence, .payload = .{ .oms_intent_group = pending_group } } }));
    try std.testing.expectEqual(pending_barrier, recovering.shard.authoritativeBarrier());
    try std.testing.expect(!recovering.closed);
    try std.testing.expectEqual(@as(u64, 1), spy.sends);
    const raw_stream: durable.StreamIdentity = .{ .domain = .raw_ingress, .id = 93 };
    const raw_memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(raw_memory);
    raw_memory.* = .initWithAllocator(std.testing.allocator);
    defer raw_memory.deinit();
    var raw = try raw_ingress.DurableSink.init(raw_memory.interface(), undefined, raw_stream);
    const frame =
        \\{"event":"subscribe","arg":{"channel":"orders","instType":"ANY"}}
    ;
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(frame, &raw_digest, .{});
    _ = try raw.interface().append(.{ .source_session = 1, .byte_len = frame.len, .sha256 = raw_digest, .receive_time_utc_ns = 1, .monotonic_time_ns = 1, .wall_time_utc_ns = 1 }, frame);
    const Sweep = struct {
        fn consume(_: *anyopaque, _: u64, _: @import("okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
            if (bytes.len == 0) return error.EmptyReplay;
            return error.IncompleteReplay;
        }
    };
    var context: u8 = 0;
    try std.testing.expectError(error.DecisionLogUnavailable, recovering.replayCommittedIngress(raw_stream, .{ .ptr = &context, .consume_fn = Sweep.consume }));
    recovering = try Owner.recover(memory.interface(), undefined, stream);
    try recovering.bindRecoveryIngress(raw_memory.interface(), raw_stream);
    try std.testing.expectError(error.DecisionLogUnavailable, recovering.replayCommittedIngress(.{ .domain = .raw_ingress, .id = 94 }, .{ .ptr = &context, .consume_fn = Sweep.consume }));
    try std.testing.expectError(error.IncompleteReplay, recovering.replayCommittedIngress(raw_stream, .{ .ptr = &context, .consume_fn = Sweep.consume }));
    try std.testing.expectError(error.NotSent, gateway.sendFromShard(&recovering.shard, command.command_id, 2));
    try std.testing.expect(recovering.shard.recovery_admission_pending);
    try std.testing.expectEqualSlices(u8, &digest, &recovering.shard.canonicalStateDigest());
    try std.testing.expectEqual(@as(u64, 1), spy.sends);
    // The spy deliberately emits no dispatch result: model a failure after the
    // external buy effect, then recover authoritative facts before cleanup.
    var restored_gateway: execution.Gateway = .{};
    try restored_gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .environment = .demo, .lease_guard = &guard, .capability = .{
        .version = 1,
        .rules_version = 1,
        .config_version = 1,
        .session = 1,
        .supports_post_only = true,
        .supports_market_protection = true,
    } });
    try restored_gateway.attachRecoveredDurableDispatch(dispatch_memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    try std.testing.expectError(error.NotSent, owner.send(&restored_gateway, &guard, command.command_id, 2));
    try std.testing.expectEqual(@as(u64, 1), spy.sends);
    const venue_order = try canonical.VenueOrderRef.init(1, "demo-order");
    const fill_quantity: canonical.InstrumentQuantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 20_000 };
    const fill_price: canonical.InstrumentPrice = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .ticks = 500 };
    _ = try owner.apply(fixture.canonicalAt(20, 4, .{ .order_dispatch_result = .{ .command = command.command_id, .state = .submitted } }));
    const accepted_report = fixture.canonicalAt(21, 5, .{ .execution_report = .{
        .identity = 5,
        .order = command.order_id,
        .client_order_id = command.client_order_id,
        .venue_order = venue_order,
        .instrument = okx.btc_usdt_spot,
        .exchange_account = 2,
        .revision = 1,
        .status = .accepted,
        .cumulative_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 0 },
        .remaining_quantity = fill_quantity,
    } });
    _ = try owner.apply(accepted_report);
    const accepted_fill = fixture.canonicalAt(22, 6, .{ .fill = .{
        .identity = 6,
        .order = command.order_id,
        .client_order_id = command.client_order_id,
        .venue_order = venue_order,
        .venue_trade = try canonical.VenueTradeRef.init(1, "demo-fill"),
        .instrument = okx.btc_usdt_spot,
        .exchange_account = 2,
        .side = .buy,
        .quantity = fill_quantity,
        .price = fill_price,
        .fee = .{ .asset = okx.btc, .atoms = 1 },
        .liquidity = .taker,
    } });
    _ = try owner.apply(accepted_fill);
    const duplicate_barrier = owner.shard.authoritativeBarrier();
    _ = try owner.apply(accepted_report);
    _ = try owner.apply(accepted_fill);
    try std.testing.expectEqual(duplicate_barrier, owner.shard.authoritativeBarrier());
    try std.testing.expectEqual(duplicate_barrier, (try memory.interface().recover(undefined, stream)).committed_barrier);
    try std.testing.expect(!owner.closed);
    var conflict_owner = owner;
    var conflicting_report = accepted_report;
    conflicting_report.venue.event.execution_report.status = .filled;
    try std.testing.expectError(error.ConflictingReportIdentity, conflict_owner.apply(conflicting_report));
    try std.testing.expect(conflict_owner.closed);
    try std.testing.expectEqual(@as(i64, 20_000), owner.shard.economicSummary().portfolio.spot.quantity);
    try std.testing.expectEqual(@as(i128, 19_999), owner.shard.economicSummary().portfolio.spot_asset_atoms);

    _ = try owner.apply(fixture.canonicalAt(23, 7, .{ .execution_report = .{
        .identity = 7,
        .order = command.order_id,
        .client_order_id = command.client_order_id,
        .venue_order = venue_order,
        .instrument = okx.btc_usdt_spot,
        .exchange_account = 2,
        .revision = command.revision,
        .status = .filled,
        .cumulative_quantity = fill_quantity,
        .remaining_quantity = .{ .instrument = okx.btc_usdt_spot, .rules_version = 1, .lots = 0 },
    } }));
    _ = try owner.apply(fixture.canonicalAt(24, 8, .{ .account_observed = .{
        .identity = 8,
        .exchange_account = 2,
        .bootstrap = 1,
        .source_stream = 1,
        .source_sequence = 2,
        .value = .{ .balance = .{ .asset = okx.btc, .value = .{
            .asset = okx.btc,
            .total = .{ .asset = okx.btc, .atoms = 19_999 },
            .cash_balance = .{ .asset = okx.btc, .atoms = 19_999 },
            .available = .{ .asset = okx.btc, .atoms = 19_999 },
            .held = .{ .asset = okx.btc, .atoms = 0 },
            .liability = .{ .asset = okx.btc, .atoms = 0 },
            .isolated_liability = .{ .asset = okx.btc, .atoms = 0 },
            .cross_liability = .{ .asset = okx.btc, .atoms = 0 },
        } } },
    } }));
    const cleanup_sequence = owner.shard.authoritativeBarrier() + 1;
    const cleanup_intent: @import("strategy_host_gateway.zig").OrderIntent = .{
        .strategy_identity = 40,
        .intent_sequence = cleanup_sequence,
        .strategy_cursor = owner.shard.authoritativeBarrier(),
        .config_version = 1,
        .activation_identity = 50,
        .portfolio_identity = 1,
        .exchange_account_identity = 2,
        .instrument_identity = okx.btc_usdt_spot,
        .side = .sell,
        .order_type = .limit,
        .time_in_force = .immediate_or_cancel,
        .portfolio_reduce_only = true,
        .quantity = 19_999,
        .limit_price_micros = 50_000_000,
    };
    const cleanup = (try owner.apply(.{ .core = .{
        .identity = cleanup_sequence,
        .monotonic_time = 3,
        .time_presence = .{ .monotonic = true },
        .payload = .{ .external_order_intent = cleanup_intent },
    } })) orelse return error.MissingDemoCommand;
    if (fail_persistence) {
        // This fresh qualified command is still pending-submit. The execution
        // store and transport remain healthy when the decision append fails.
        const source = try owner.source();
        try gateway.observeAuthority(.{
            .account = source.exchange_account_identity,
            .effective_trading_authority = source.operational_state.effectiveTradingAuthority(),
            .reservation_identity = cleanup.reservation_identity,
            .reservation = cleanup.reservation,
            .primary_lease_expires_at_monotonic_ns = guard.lease.expires_at_ns,
            .fencing_token = guard.lease.token,
            .exchange_position = source.currentNetExchangePosition(cleanup.instrument).?,
            .authority_barrier = source.authoritativeBarrier(),
        });
        const healthy_digest = source.canonicalStateDigest();
        const healthy_economics = source.economicSummary();
        memory.injectFault(.eio);
        try std.testing.expectError(error.DecisionLogUnavailable, owner.apply(.{ .core = .{ .identity = source.authoritativeBarrier() + 1, .payload = .{ .mark_price = .{ .instrument = okx.btc_usdt_spot, .price_atoms = 50_000_000 } } } }));
        try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
        try std.testing.expectEqual(durable.GateState.open, dispatch_memory.interface().safetyGate());
        try std.testing.expectEqualSlices(u8, &healthy_digest, &owner.shard.canonicalStateDigest());
        try std.testing.expectEqualDeep(healthy_economics, owner.shard.economicSummary());
        try std.testing.expectError(error.NotSent, gateway.sendFromShard(&owner.shard, cleanup.command_id, 3));
        try std.testing.expectEqual(@as(u64, 1), spy.sends);
        return;
    }
    try std.testing.expectEqual(venue.SendResult.accepted, try owner.send(&gateway, &guard, cleanup.command_id, 3));
    try std.testing.expect(cleanup.portfolio_reduce_only);
    try std.testing.expectEqual(@as(u64, 2), spy.sends);
}

test "Demo policy drives buy and fault cleanup through one durable Gateway" {
    try checkDemoPolicyGateway(false);
    try checkDemoPolicyGateway(true);
}
