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

/// Explicit local Demo policy. It supplies authorization limits, never an
/// account balance, lease token, Venue fact, or send proof.
pub const Policy = struct {
    schema: u16,
    exchange_account: u128,
    portfolio_identity: u128,
    strategy_identity: u128,
    activation_identity: u128,
    config_version: u64,
    portfolio_allocation_micros: i64,
    risk_limit_micros: i64,
    decision_stream_id: u64,
    dispatch_stream_id: u64,
    decision_domain: u64,
    node_identity: u64,

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Policy) {
        const parsed = try std.json.parseFromSlice(Policy, gpa, bytes, .{});
        errdefer parsed.deinit();
        const value = parsed.value;
        if (value.schema != 1 or value.exchange_account == 0 or value.portfolio_identity == 0 or
            value.strategy_identity == 0 or value.activation_identity == 0 or value.config_version == 0 or
            value.portfolio_allocation_micros <= 0 or value.risk_limit_micros <= 0 or
            value.risk_limit_micros > value.portfolio_allocation_micros or
            value.decision_stream_id == 0 or value.dispatch_stream_id == 0 or
            value.decision_stream_id == value.dispatch_stream_id or value.decision_domain == 0 or value.node_identity == 0)
            return error.InvalidDemoPolicy;
        return parsed;
    }

    /// Virgin startup derives cash only from a complete private account
    /// snapshot; existing BTC/derivative exposure requires recovery instead.
    pub fn initialize(self: Policy, owner: *Owner, mark_price_micros: i64, guard: *failover.GatewayLeaseGuard, now_ns: u64, adapter_session: u64) !void {
        if (owner.ready or owner.closed or owner.shard.trace.len == 0 or
            owner.stream.id != self.decision_stream_id or mark_price_micros <= 0 or
            now_ns == 0 or adapter_session == 0 or
            guard.lease.key.exchange_account != self.exchange_account or
            guard.lease.key.decision_domain != self.decision_domain or
            guard.lease.node != self.node_identity or !guard.lease.valid(now_ns))
            return error.InvalidDemoBootstrap;
        guard.check(now_ns, guard.lease.token, true) catch return error.InvalidDemoLease;
        const account = &owner.shard.canonical_account;
        if (!account.valid or account.exchange_account != self.exchange_account or
            account.position_count != 0 or account.margin_count != 0)
            return error.InvalidDemoAccount;
        var usdt_total: ?i64 = null;
        var usdt_available: ?i64 = null;
        for (account.balances[0..account.balance_count]) |balance| {
            if (balance.asset == okx.btc and balance.total.atoms != 0) return error.NonzeroDemoBaseline;
            if (balance.asset != okx.usdt) continue;
            if (usdt_total != null or balance.total.asset != okx.usdt or balance.available.asset != okx.usdt or
                balance.total.atoms <= 0 or balance.available.atoms < self.portfolio_allocation_micros or
                balance.available.atoms > balance.total.atoms or
                (balance.liability != null and balance.liability.?.atoms != 0))
                return error.InvalidDemoAccount;
            usdt_total = std.math.cast(i64, balance.total.atoms) orelse return error.InvalidDemoAccount;
            usdt_available = std.math.cast(i64, balance.available.atoms) orelse return error.InvalidDemoAccount;
        }
        if (usdt_total == null or usdt_available == null) return error.MissingDemoCash;
        const core = struct {
            fn put(target: *Owner, identity: u64, payload: trading.CorePayload) !void {
                if (try target.apply(.{ .core = .{ .identity = identity, .payload = payload } }) != null)
                    return error.UnexpectedDemoOrder;
            }
        }.put;
        try core(owner, 1, .{ .instrument_rules_activated = .{
            .version = 1,
            .instrument_identity = okx.btc_usdt_spot,
            .quantity_denominator = 100_000_000,
            .reservation_model = .cash,
            .product = .spot,
            .venue = 1,
            .base_asset = okx.btc,
        } });
        try core(owner, 2, .{ .margin_rules_activated = .{ .version = 1, .instrument = okx.btc_usdt_spot, .price_tick_micros = 100_000 } });
        try core(owner, 3, .{ .account_configuration = .{ .exchange_account_identity = self.exchange_account } });
        try core(owner, 4, .{ .exchange_balance = .{ .cash_micros = usdt_total.? } });
        try core(owner, 5, .exchange_positions);
        try core(owner, 6, .{ .opening_balance = .{ .cash_micros = usdt_total.? } });
        try core(owner, 7, .{ .virtual_portfolio_activated = .{ .portfolio_identity = self.portfolio_identity } });
        try core(owner, 8, .{ .portfolio_transfer = .{ .amount_micros = self.portfolio_allocation_micros } });
        try core(owner, 9, .{ .strategy_activated = .{
            .strategy_identity = self.strategy_identity,
            .config_version = self.config_version,
            .activation_identity = self.activation_identity,
        } });
        try core(owner, 10, .{ .primary_lease_granted = .{ .fencing_token = guard.lease.token } });
        const risk_valid_through = std.math.add(u64, owner.shard.trace.len, 32) catch return error.InvalidDemoBootstrap;
        try core(owner, 11, .{ .risk_lease_granted = .{
            .lease_identity = 11,
            .version = 1,
            .amount_micros = self.risk_limit_micros,
            .valid_through_barrier = risk_valid_through,
        } });
        try core(owner, 12, .{ .mark_price = .{ .instrument = okx.btc_usdt_spot, .price_micros = mark_price_micros } });
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
            .max_dispatch_age_ns = std.time.ns_per_s,
            .supports_place = true,
            .supports_cancel = true,
            .supports_native_amend = false,
            .supports_venue_reduce_only = false,
            .supports_post_only = true,
            .supports_market_protection = true,
        } });
        const digest = owner.shard.canonicalStateDigest();
        try core(owner, 17, .{ .host_activated = .{
            .strategy_identity = self.strategy_identity,
            .config_version = self.config_version,
            .activation_identity = self.activation_identity,
            .activation_barrier = owner.shard.trace.len,
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
        const recovered_shard = if (recovered.tail.len == 0)
            (trading.TradingShard.restoreSnapshot(recovered.snapshot) catch return error.DecisionLogUnavailable).shard
        else blk: {
            const restored = trading.TradingShard.restore(recovered.snapshot, recovered.tail) catch return error.DecisionLogUnavailable;
            // An open, fully committed tail is legal; the Store verified its
            // continuity and the shard replay verified every derived fact.
            break :blk restored.shard;
        };
        if (recovered_shard.trace.len != recovered.committed_barrier) return error.DecisionLogUnavailable;
        const next_sequence = std.math.add(u64, recovered.last_sequence, 1) catch return error.DecisionLogUnavailable;
        return .{
            .store = store,
            .io = io,
            .stream = stream,
            .shard = recovered_shard,
            .decision_journal = journal.Journal.initAt(next_sequence),
            .ready = true,
        };
    }

    /// Apply to a candidate and publish only after every record and the
    /// barrier have been committed. A fault closes this owner permanently.
    pub fn apply(self: *Owner, input: trading.CanonicalEvent) !?trading.OrderCommand {
        if (self.closed or self.store.safetyGate() != .open) return error.DecisionLogUnavailable;
        var candidate = self.shard;
        var candidate_journal = self.decision_journal;
        const before = candidate_journal.last_sequence;
        var rejected: ?anyerror = null;
        const command = trading.applyStable(&candidate, &candidate_journal, input) catch |err| blk: {
            rejected = err;
            break :blk null;
        };
        if (candidate_journal.last_sequence == before) {
            self.closed = true;
            return rejected orelse error.InputProducedNoFact;
        }
        var reader = journal.Reader.init(candidate_journal.bytes()) catch {
            self.closed = true;
            return error.DecisionLogUnavailable;
        };
        while (true) switch (reader.next() catch {
            self.closed = true;
            return error.DecisionLogUnavailable;
        }) {
            .end => break,
            .record => |record| if (record.sequence > before) {
                self.store.append(self.io, .{ .stream = self.stream, .record = record }) catch {
                    self.closed = true;
                    return error.DecisionLogUnavailable;
                };
            },
        };
        self.store.commit(self.io, self.stream, candidate_journal.last_sequence) catch {
            self.closed = true;
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

    /// Seal a genuinely ingested bootstrap before allowing dispatch.
    pub fn sealBootstrap(self: *Owner) !void {
        if (self.ready or self.closed or self.store.safetyGate() != .open or self.shard.trace.len == 0 or
            self.shard.trace.len != self.decision_journal.last_sequence)
            return error.DecisionLogUnavailable;
        var sealed = self.decision_journal;
        sealed.seal() catch return error.DecisionLogUnavailable;
        var snapshot_buffer: [durable.max_snapshot_bytes]u8 = undefined;
        const snapshot = self.shard.snapshot(&sealed, sealed.last_sequence, &snapshot_buffer) catch return error.DecisionLogUnavailable;
        self.store.seal(self.io, self.stream) catch {
            self.closed = true;
            return error.DecisionLogUnavailable;
        };
        self.store.publishSnapshot(self.io, self.stream, sealed.last_sequence, snapshot) catch {
            self.closed = true;
            return error.DecisionLogUnavailable;
        };
        self.store.rotate(self.io, self.stream) catch {
            self.closed = true;
            return error.DecisionLogUnavailable;
        };
        const next_sequence = std.math.add(u64, sealed.last_sequence, 1) catch {
            self.closed = true;
            return error.DecisionLogUnavailable;
        };
        self.decision_journal = journal.Journal.initAt(next_sequence);
        self.ready = true;
    }

    pub fn source(self: *const Owner) !*const trading.TradingShard {
        if (!self.ready or self.closed or self.store.safetyGate() != .open)
            return error.DecisionLogUnavailable;
        return &self.shard;
    }

    pub fn send(self: *const Owner, gateway: *execution.Gateway, command_id: u64, now_monotonic_ns: u64) !venue.SendResult {
        return gateway.sendFromShard(try self.source(), command_id, now_monotonic_ns);
    }
};

test "Demo owner commits before publication and recovers only a complete barrier" {
    const fixture = @import("trading_shard_fixture.zig");
    const host = @import("strategy_host_gateway.zig");
    const authorization: host.Authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = 1 };
    const genesis = fixture.genesisEvents(authorization, .cash);
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    var owner = try Owner.bootstrap(memory.interface(), undefined, stream);
    try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
    var gateway: execution.Gateway = .{};
    try std.testing.expectError(error.DecisionLogUnavailable, owner.send(&gateway, 1, 1));
    var spot_rules = genesis[0];
    spot_rules.core.payload.instrument_rules_activated.base_asset = 0x425443;
    _ = try owner.apply(spot_rules);
    try std.testing.expectEqual(owner.shard.trace.len, (try memory.interface().recover(undefined, stream)).committed_barrier);
    try owner.sealBootstrap();
    const source = try owner.source();
    try std.testing.expectEqual(@as(u64, 1), source.trace.len);
    var restored = try Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &source.canonicalStateDigest(), &(try restored.source()).canonicalStateDigest());
    _ = try owner.apply(genesis[1]);
    _ = try owner.apply(genesis[6]);
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
    restored = try Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &owner.shard.canonicalStateDigest(), &(try restored.source()).canonicalStateDigest());
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
    try std.testing.expectError(error.DecisionLogUnavailable, restored.send(&gateway, 1, 1));
    memory.injectFault(.eio);
    try std.testing.expectError(error.DecisionLogUnavailable, owner.apply(genesis[2]));
    try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
}

test "versioned Demo policy derives bootstrap cash from committed private account facts" {
    const fixture = @import("trading_shard_fixture.zig");
    var parsed = try Policy.parse(std.testing.allocator,
        \\{"schema":1,"exchange_account":2,"portfolio_identity":1,"strategy_identity":40,"activation_identity":50,"config_version":1,"portfolio_allocation_micros":20000000,"risk_limit_micros":10000000,"decision_stream_id":91,"dispatch_stream_id":92,"decision_domain":1,"node_identity":1}
    );
    defer parsed.deinit();
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    const stream: durable.StreamIdentity = .{ .domain = .decision_log, .id = 91 };
    var owner = try Owner.bootstrap(memory.interface(), undefined, stream);
    var snapshot = fixture.canonicalAt(1, 1, .{ .account_bootstrap_snapshot = .{
        .identity = 1,
        .exchange_account = 2,
        .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
        .source_stream = 1,
        .source_sequence = 1,
        .balance_count = 2,
        .position_count = 0,
        .margin_count = 0,
    } });
    snapshot.venue.event.account_bootstrap_snapshot.balances[0] = .{
        .asset = okx.usdt,
        .total = .{ .asset = okx.usdt, .atoms = 25_000_000 },
        .available = .{ .asset = okx.usdt, .atoms = 25_000_000 },
        .held = .{ .asset = okx.usdt, .atoms = 0 },
    };
    snapshot.venue.event.account_bootstrap_snapshot.balances[1] = .{
        .asset = okx.btc,
        .total = .{ .asset = okx.btc, .atoms = 0 },
        .available = .{ .asset = okx.btc, .atoms = 0 },
        .held = .{ .asset = okx.btc, .atoms = 0 },
    };
    _ = try owner.apply(snapshot);
    var authority = failover.authorityForTesting();
    var lease = try authority.acquire(.{ .exchange_account = 2, .decision_domain = 1 }, 1, 1);
    var guard: failover.GatewayLeaseGuard = .{ .authority = &authority, .lease = &lease };
    authority.available = false;
    try std.testing.expectError(error.InvalidDemoLease, parsed.value.initialize(&owner, 50_000_000, &guard, 1, 1));
    try std.testing.expectError(error.DecisionLogUnavailable, owner.source());
    authority.available = true;
    try parsed.value.initialize(&owner, 50_000_000, &guard, 1, 1);
    try std.testing.expect((try owner.source()).operational_state.effectiveTradingAuthority());
    try std.testing.expectEqual(@as(i64, 10_000_000), (try owner.source()).risk_lease_micros);
    const recovered = try Owner.recover(memory.interface(), undefined, stream);
    try std.testing.expectEqualSlices(u8, &(try owner.source()).canonicalStateDigest(), &(try recovered.source()).canonicalStateDigest());
}
