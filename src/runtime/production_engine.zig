//! Durable decision owner for the formal Linux engine role.
const std = @import("std");
const durable = @import("../persistence/durable_store.zig");
const journal = @import("../persistence/journal.zig");
const codec = @import("../persistence/canonical_event_codec.zig");
const trading = @import("../trading/trading_shard.zig");
const strategy_authority = @import("../strategy/strategy_package_authority.zig");
const strategy_host = @import("production_strategy_host.zig");
const Owner = @import("demo/demo_authority.zig").Owner;
const pair = @import("../trading/pair_trading_authorization.zig");

pub const max_input_bytes = codec.max_encoded_len - 1;
pub const max_record_bytes = journal.max_payload_size;

pub const RecoverySource = struct {
    venue: u64,
    raw_stream: u64,
    session: u64,

    pub fn valid(self: RecoverySource) bool {
        return self.venue != 0 and self.raw_stream != 0 and self.session != 0;
    }
};

const max_recovery_sources = 32;

const Config = struct {
    decision_stream: u64,
    deployment_digest: []const u8,
    recovery_sources: []const RecoverySource = &.{},
    strategy_host: ?strategy_host.Config = null,
};

pub const Engine = struct {
    owner: *Owner,
    file_store: *durable.LinuxFileAdapter,
    sources: [max_recovery_sources]RecoverySource = undefined,
    source_count: usize = 0,
    recovered_sources: u32 = 0,
    config: std.json.Parsed(Config),
    host: ?*strategy_host.Host = null,

    pub fn open(init: std.process.Init, dir: std.Io.Dir, state_path: []const u8) !Engine {
        var config_buffer: [4097]u8 = undefined;
        const bytes = try dir.readFile(init.io, "engine.json", &config_buffer);
        if (bytes.len == config_buffer.len) return error.InvalidEngineConfiguration;
        const parsed = try std.json.parseFromSlice(Config, init.gpa, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const config = parsed.value;
        if (config.decision_stream == 0 or config.deployment_digest.len != 64 or
            (config.strategy_host != null and config.recovery_sources.len == 0))
            return error.InvalidEngineConfiguration;
        var digest: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&digest, config.deployment_digest);

        const file_store = try init.gpa.create(durable.LinuxFileAdapter);
        errdefer init.gpa.destroy(file_store);
        file_store.* = .{ .dir = undefined };
        try file_store.initLinux(init.io, state_path);
        errdefer file_store.close(init.io);
        const owner = try init.gpa.create(Owner);
        errdefer init.gpa.destroy(owner);
        try recover(owner, file_store.interface(), init.io, config.decision_stream, digest);
        try revokeHosts(owner);
        var engine: Engine = .{ .owner = owner, .file_store = file_store, .config = parsed };
        for (config.recovery_sources) |source| {
            if (!source.valid() or engine.source_count == engine.sources.len) return error.InvalidEngineConfiguration;
            for (engine.sources[0..engine.source_count]) |previous|
                if (previous.raw_stream == source.raw_stream or previous.session == source.session)
                    return error.InvalidEngineConfiguration;
            engine.sources[engine.source_count] = source;
            engine.source_count += 1;
        }
        return engine;
    }

    pub fn sourceIndex(self: *const Engine, source: RecoverySource) ?u5 {
        for (self.sources[0..self.source_count], 0..) |expected, index|
            if (std.meta.eql(source, expected)) return @intCast(index);
        return null;
    }

    pub fn finishSource(self: *Engine, index: u5, sweep: RecoverySweep) !void {
        if (sweep.last_event == 0 or sweep.last_raw > sweep.raw_barrier or sweep.raw_barrier == 0)
            return error.IncompleteVenueRecovery;
        // A regressed or incomplete replay must not exclude an already committed event.
        const shard = try self.owner.source();
        for (shard.canonical_ingress_cursors[0..shard.canonical_ingress_cursor_count]) |cursor| {
            if (cursor.identity.stream == sweep.source.session and cursor.identity.sequence > sweep.last_event)
                return error.IncompleteVenueRecovery;
        }
        const recovered_sources = self.recovered_sources | (@as(u32, 1) << index);
        if (@popCount(recovered_sources) == self.source_count) {
            if (self.owner.checkpoint_pending) return error.IncompleteVenueRecovery;
            try self.owner.completeIngressRecovery();
        }
        self.recovered_sources = recovered_sources;
    }

    pub fn startHost(self: *Engine, init: std.process.Init, generation: u64) !void {
        if (self.config.value.strategy_host) |config|
            self.host = try strategy_host.Host.start(init, self.owner, generation, config);
    }

    pub fn pumpHost(self: *Engine) !void {
        if (self.host) |host| try host.pump(self.owner);
    }

    pub fn readAuthority(self: *const Engine, gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
        const ready_strategy = if (self.host) |host| try host.readyStrategy(self.owner) else null;
        return readStrategyAuthority(self.owner, gpa, bytes, ready_strategy);
    }

    pub fn close(self: Engine, init: std.process.Init) void {
        if (self.host) |host| host.close(init);
        self.config.deinit();
        init.gpa.destroy(self.owner);
        self.file_store.close(init.io);
        init.gpa.destroy(self.file_store);
    }
};

pub fn recover(owner: *Owner, store: durable.Store, io: std.Io, decision_stream: u64, digest: [32]u8) !void {
    try Owner.recoverInto(owner, store, io, .{ .domain = .decision_log, .id = decision_stream });
    errdefer owner.closed = true;
    const shard = try owner.source();
    if (!shard.deployment.sealed or shard.decision_domain_identity == 0) return error.DeploymentConfigurationRequired;
    try owner.pinDeploymentDigest(digest);
    if (owner.checkpoint_pending) try owner.checkpoint();
}

pub const RecoverySweep = struct {
    source: RecoverySource,
    raw_barrier: u64,
    last_raw: u64 = 0,
    last_event: u64 = 0,

    committed: std.AutoHashMapUnmanaged(u64, [32]u8) = .empty,

    pub fn deinit(self: *RecoverySweep, allocator: std.mem.Allocator) void {
        self.committed.deinit(allocator);
    }

    pub fn loadCommitted(self: *RecoverySweep, owner: *const Owner, allocator: std.mem.Allocator) !void {
        const shard = try owner.source();
        for (shard.canonical_ingress_cursors[0..shard.canonical_ingress_cursor_count]) |cursor| {
            if (cursor.identity.stream == self.source.session) break;
        } else return;

        const Index = struct {
            sweep: *RecoverySweep,
            allocator: std.mem.Allocator,

            fn segment(ptr: *anyopaque, bytes: []const u8) !void {
                const index: *@This() = @ptrCast(@alignCast(ptr));
                var reader = try journal.Reader.init(bytes);
                while (true) switch (try reader.next()) {
                    .end => return,
                    .record => |record| {
                        if (record.flags & journal.input_flag == 0) continue;
                        const input = try trading.decodeStableInput(record);
                        if (input != .venue or input.venue.envelope.identity.stream != index.sweep.source.session) continue;
                        var buffer: [codec.max_encoded_len]u8 = undefined;
                        const hash = frameDigest(try codec.encode(&buffer, input.venue));
                        const entry = try index.sweep.committed.getOrPut(index.allocator, input.venue.envelope.identity.sequence);
                        if (entry.found_existing and !std.mem.eql(u8, entry.value_ptr, &hash))
                            return error.ConflictingCanonicalIdentity;
                        entry.value_ptr.* = hash;
                    },
                };
            }
        };
        var index: Index = .{ .sweep = self, .allocator = allocator };
        try owner.store.replaySegments(owner.io, owner.stream, .{ .ptr = &index, .consume_fn = Index.segment });
    }

    pub fn apply(self: *RecoverySweep, owner: *Owner, frame: []const u8) !void {
        const event = try codec.decode(frame);
        const envelope = event.envelope;
        const raw = envelope.raw_evidence;
        if (envelope.venue != self.source.venue or envelope.identity.stream != self.source.session or
            envelope.adapter_session != self.source.session or raw.stream != self.source.raw_stream or
            raw.sequence == 0 or raw.sequence < self.last_raw or raw.sequence > self.raw_barrier or
            std.mem.allEqual(u8, &raw.digest, 0) or
            envelope.identity.sequence != try std.math.add(u64, self.last_event, 1))
            return error.InvalidVenueRecoveryFrame;
        if (self.committed.get(envelope.identity.sequence)) |hash| {
            if (!std.mem.eql(u8, &hash, &frameDigest(frame))) return error.ConflictingCanonicalIdentity;
        } else _ = try owner.apply(.{ .venue = event });
        self.last_raw = raw.sequence;
        self.last_event = envelope.identity.sequence;
    }
};

fn frameDigest(frame: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(frame, &digest, .{});
    return digest;
}

/// The upstream role retains the input in its durable capture until this
/// operation returns a committed decision barrier.
pub fn ingest(owner: *Owner, frame: []const u8) !u64 {
    if (frame.len == 0 or frame.len > max_input_bytes) return error.InvalidCanonicalFrame;
    const event = try codec.decode(frame);
    _ = try owner.apply(.{ .venue = event });
    return (try owner.source()).authoritativeBarrier();
}

pub fn revokeHosts(owner: *Owner) !void {
    const shard = try owner.source();
    var cursor: usize = 0;
    while (cursor <= shard.portfolio_authority_count) : (cursor += 1) {
        const authority = if (cursor == 0)
            shard.strategyAuthority(shard.strategy_identity)
        else
            shard.portfolio_authorities[cursor - 1];
        if (authority.host_activation_identity == 0) continue;
        _ = try owner.apply(.{ .core = .{
            .identity = try std.math.add(u64, shard.authoritativeBarrier(), 1),
            .payload = .{ .host_activation_revoked = .{
                .strategy_identity = authority.strategy_identity,
                .activation_identity = authority.host_activation_identity,
                .reason = .control,
            } },
        } });
    }
}

pub const max_authority_bytes = 256 * 1024;

const PairApproval = struct {
    operation: enum { approve_pair },
    identity: u128,
    strategy: u128,
    portfolio: u128,
    expected_version: u64,
    legs: [2]struct {
        venue: u64,
        environment: @FieldType(pair.Leg, "environment"),
        instrument: u128,
        product: @FieldType(trading.InstrumentEntry, "product"),
        base_asset: u64,
        settlement_asset: u64,
        account: ?u128 = null,
    },
    direction: i8,
    mode: pair.Mode,
};

fn resolvePairApproval(shard: *const trading.TradingShard, selection: PairApproval) !pair.Request {
    const authority = shard.strategyAuthority(selection.strategy);
    if (!authority.strategy_active or authority.strategy_identity != selection.strategy or
        authority.portfolio_identity != selection.portfolio or shard.strategyFenced(selection.strategy))
        return error.InvalidPairStrategy;
    var legs: [2]pair.Leg = undefined;
    for (selection.legs, &legs, 0..) |selected, *leg, index| {
        var match: ?pair.Leg = null;
        for (shard.deployment.accounts[0..shard.deployment.account_count]) |account| {
            if (account.venue != selected.venue or account.environment != selected.environment or
                (selected.account != null and selected.account != account.identity) or
                shard.deployment.owner(account.identity, selected.instrument) != shard.decision_domain_identity) continue;
            const entry = shard.pairInstrument(account.identity, selected.instrument) orelse continue;
            if (entry.venue != selected.venue or entry.product != selected.product or entry.rules.base_asset != selected.base_asset or
                entry.rules.settlement_asset != selected.settlement_asset or
                shard.deployment.portfolioSliceLimit(account.identity, entry.rules.settlement_asset, selection.portfolio) == null) continue;
            if (match != null) return if (index == 0) error.AmbiguousPairFirstLeg else error.AmbiguousPairSecondLeg;
            match = .{ .venue = account.venue, .environment = account.environment, .account = account.identity, .instrument = entry.instrument, .rules_version = entry.rules.version };
        }
        leg.* = match orelse return if (index == 0) error.UnmappedPairFirstLeg else error.UnmappedPairSecondLeg;
    }
    return .{
        .identity = selection.identity,
        .strategy = selection.strategy,
        .portfolio = selection.portfolio,
        .activation = authority.strategy_activation_identity,
        .config_version = authority.strategy_config_version,
        .expected_version = selection.expected_version,
        .legs = legs,
        .direction = selection.direction,
        .mode = selection.mode,
        .enabled = true,
    };
}

fn pairOutcome(gpa: std.mem.Allocator, identity: u128, status: []const u8, reason: ?[]const u8) ![]u8 {
    var id: [39]u8 = undefined;
    return std.json.Stringify.valueAlloc(gpa, .{ .identity = try std.fmt.bufPrint(&id, "{d}", .{identity}), .status = status, .reason = reason }, .{});
}

fn pairReceipt(gpa: std.mem.Allocator, record: pair.Record) ![]u8 {
    var id: [39]u8 = undefined;
    var version: [20]u8 = undefined;
    var barrier: [20]u8 = undefined;
    return std.json.Stringify.valueAlloc(gpa, .{
        .identity = try std.fmt.bufPrint(&id, "{d}", .{record.request.identity}),
        .status = "accepted",
        .core_version = try std.fmt.bufPrint(&version, "{d}", .{record.version}),
        .barrier = try std.fmt.bufPrint(&barrier, "{d}", .{record.barrier}),
        .pair = strategy_authority.pairListEntry(record.request),
    }, .{});
}

/// Resolve the selected legs against the Writer's deployment and acknowledge committed approval.
pub fn approvePair(owner: *Owner, gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(PairApproval, gpa, bytes, .{});
    defer parsed.deinit();
    const selection = parsed.value;
    const shard = try owner.source();
    const request = resolvePairApproval(shard, selection) catch |err|
        return pairOutcome(gpa, selection.identity, "rejected", @errorName(err));
    if (shard.pair_authorizations.receipt(request.identity)) |record| {
        if (!std.meta.eql(record.request, request))
            return pairOutcome(gpa, request.identity, "rejected", "PairAuthorizationIdentityConflict");
        return pairReceipt(gpa, record);
    }
    shard.validatePairAuthorization(request) catch |err| return pairOutcome(gpa, request.identity, "rejected", @errorName(err));
    if (request.expected_version != shard.pair_authorizations.version)
        return pairOutcome(gpa, request.identity, "rejected", "PairAuthorizationVersionConflict");
    if (shard.pair_authorizations.count == shard.pair_authorizations.records.len)
        return pairOutcome(gpa, request.identity, "rejected", "PairAuthorizationCapacity");
    const event_identity = try std.math.add(u64, shard.authoritativeBarrier(), 1);
    _ = owner.apply(.{ .core = .{ .identity = event_identity, .payload = .{ .pair_trading_authorization = request } } }) catch |err|
        return pairOutcome(gpa, request.identity, "unknown", @errorName(err));
    const record = (try owner.source()).pair_authorizations.receipt(request.identity) orelse return error.PairConfirmationUnavailable;
    return pairReceipt(gpa, record);
}

pub fn readStrategyAuthority(owner: *const Owner, gpa: std.mem.Allocator, bytes: []const u8, ready_strategy: ?u128) ![]u8 {
    const Request = struct {
        operation: enum { pair_trading_list, strategy_instances, pair_authorization_version, pair_approval_status },
        strategy_identity: ?[]const u8 = null,
        scope_accounts: ?[]const []const u8 = null,
        identity: ?u128 = null,
        portfolio: ?u128 = null,
    };
    const shard = try owner.source();
    const parsed = try std.json.parseFromSlice(Request, gpa, bytes, .{});
    defer parsed.deinit();
    const request = parsed.value;
    if (request.operation == .strategy_instances) {
        if (request.strategy_identity != null or request.scope_accounts != null or request.identity != null or request.portfolio != null)
            return error.InvalidAuthorityFrame;
        return readStrategyInstances(gpa, shard, ready_strategy);
    }
    const id = request.strategy_identity orelse return error.StrategyIdentityMismatch;
    if (id.len != 32) return error.StrategyIdentityMismatch;
    const identity = try std.fmt.parseInt(u128, id, 16);
    if (identity == 0) return error.StrategyIdentityMismatch;
    if (request.operation == .pair_approval_status) {
        if (request.scope_accounts != null) return error.InvalidAuthorityFrame;
        const approval = request.identity orelse return error.InvalidAuthorityFrame;
        const portfolio = request.portfolio orelse return error.InvalidAuthorityFrame;
        if (shard.pair_authorizations.receipt(approval)) |record| {
            if (record.request.strategy == identity and record.request.portfolio == portfolio)
                return pairReceipt(gpa, record);
        }
        return pairOutcome(gpa, approval, "unknown", null);
    }
    if (request.identity != null or request.portfolio != null) return error.InvalidAuthorityFrame;
    if (!shard.strategyAuthority(identity).strategy_active) return error.StrategyIdentityMismatch;
    if (request.operation == .pair_authorization_version) {
        if (request.scope_accounts != null) return error.InvalidAuthorityFrame;
        var version: [20]u8 = undefined;
        return std.json.Stringify.valueAlloc(gpa, .{ .core_version = try std.fmt.bufPrint(&version, "{d}", .{shard.pair_authorizations.version}) }, .{});
    }
    return strategy_authority.pairTradingList(gpa, shard, identity, request.scope_accounts orelse return error.InvalidAuthorityFrame);
}

fn readStrategyInstances(gpa: std.mem.Allocator, shard: *const trading.TradingShard, ready_strategy: ?u128) ![]u8 {
    const Instance = struct {
        binding: struct {
            strategy_identity: [32]u8,
            decision_domain: [32]u8,
            portfolio_identity: [32]u8,
            config_version: u64,
        },
        status: []const u8,
        trading_authorized: bool = false,
        pair_trading_list: []strategy_authority.PairListEntry,
        pair_trading_list_empty: bool,
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var instances: std.ArrayList(Instance) = .empty;
    for (0..shard.portfolio_authority_count + 1) |index| {
        const authority = if (index == 0) shard.strategyAuthority(shard.strategy_identity) else shard.portfolio_authorities[index - 1];
        const identity = authority.strategy_identity;
        if (identity == 0 or !authority.strategy_active or shard.strategyFenced(identity)) continue;
        const pairs = try strategy_authority.effectivePairList(arena.allocator(), shard, identity);
        var instance: Instance = .{
            .binding = .{
                .strategy_identity = undefined,
                .decision_domain = undefined,
                .portfolio_identity = undefined,
                .config_version = authority.strategy_config_version,
            },
            .status = if (identity == ready_strategy) "Ready" else "Stopped",
            .pair_trading_list = pairs,
            .pair_trading_list_empty = pairs.len == 0,
        };
        _ = try std.fmt.bufPrint(&instance.binding.strategy_identity, "{x:0>32}", .{identity});
        _ = try std.fmt.bufPrint(&instance.binding.decision_domain, "{x:0>32}", .{shard.decision_domain_identity});
        _ = try std.fmt.bufPrint(&instance.binding.portfolio_identity, "{x:0>32}", .{authority.portfolio_identity});
        try instances.append(arena.allocator(), instance);
    }
    return std.json.Stringify.valueAlloc(gpa, .{ .instances = instances.items }, .{});
}

pub const CommittedRecord = struct {
    cursor: u64,
    record: ?journal.Record = null,
};

/// Preserve the full decision sequence, including cold proof and derived facts.
pub fn nextCommittedRecord(owner: *const Owner, after: u64, buffer: []u8) !CommittedRecord {
    const barrier = (try owner.source()).authoritativeBarrier();
    if (after > barrier) return error.CursorAheadOfCommit;
    if (after == barrier) return .{ .cursor = barrier };
    const Search = struct {
        after: u64,
        through: u64,
        buffer: []u8,
        result: ?journal.Record = null,

        fn segment(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            var reader = try journal.Reader.init(bytes);
            while (true) switch (try reader.next()) {
                .end => return,
                .record => |record| {
                    if (record.sequence <= self.after) continue;
                    if (record.sequence > self.through or record.sequence != self.after + 1)
                        return error.CommittedSequenceGap;
                    if (record.payload.len > self.buffer.len) return error.CommittedRecordBufferTooSmall;
                    const payload = self.buffer[0..record.payload.len];
                    @memcpy(payload, record.payload);
                    self.result = record;
                    self.result.?.payload = payload;
                    return error.CommittedRecordFound;
                },
            };
        }
    };
    var search: Search = .{ .after = after, .through = barrier, .buffer = buffer };
    owner.store.replaySegmentsAfter(owner.io, owner.stream, after, std.math.maxInt(usize), .{
        .ptr = &search,
        .consume_fn = Search.segment,
    }) catch |err| switch (err) {
        error.CommittedRecordFound => return .{ .cursor = search.result.?.sequence, .record = search.result.? },
        else => return err,
    };
    return error.CommittedSequenceGap;
}
