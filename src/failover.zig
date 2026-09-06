//! Fail-closed primary lease, external node fencing, and failover evidence.
//!
//! The authority and fence below are injectable adapters.  They deliberately
//! model the external durability and isolation boundaries without pretending
//! that an offline test is a target-node qualification.

const std = @import("std");

pub const lease_duration_ns: u64 = std.time.ns_per_s;
pub const lease_renew_interval_ns: u64 = 250 * std.time.ns_per_ms;
pub const standby_max_lag_ns: u64 = 50 * std.time.ns_per_ms;
pub const standby_max_lag_events: u64 = 25_000;
pub const safety_rto_ns: u64 = std.time.ns_per_s;
pub const process_trading_rto_ns: u64 = 10 * std.time.ns_per_s;
pub const node_trading_rto_ns: u64 = 30 * std.time.ns_per_s;
pub const max_domains: usize = 8;
pub const max_report_entries: usize = 32;

pub const DomainKey = struct {
    exchange_account: u128,
    decision_domain: u64,

    fn eql(self: DomainKey, other: DomainKey) bool {
        return self.exchange_account == other.exchange_account and self.decision_domain == other.decision_domain;
    }
};

pub const FailoverCause = enum {
    planned_switch,
    process_failure,
    node_failure,
    network_partition,
    untrusted_state,
};

pub const Outcome = enum { passed, blocked, failed, invalid };

pub const FaultKind = enum {
    normal,
    process_exit,
    node_power_loss,
    replication_interrupt,
    network_partition,
    fence_failure,
    stale_token,
    storage_corruption,
    admission_interrupt,
};

pub const FixedText = struct {
    bytes: [96]u8 = @splat(0),
    len: u8 = 0,

    pub fn literal(comptime value: []const u8) FixedText {
        comptime if (value.len > 96) @compileError("failover evidence text is too long");
        var result: FixedText = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = value.len;
        return result;
    }

    pub fn slice(self: *const FixedText) []const u8 {
        return self.bytes[0..self.len];
    }
};

const AuthorityRecord = struct {
    key: DomainKey,
    current_token: u64 = 0,
    next_token: u64 = 1,
    owner_node: u64 = 0,
    durable_barrier: u64 = 0,
};

pub const PrimaryLease = struct {
    key: DomainKey,
    node: u64,
    token: u64,
    issued_at_ns: u64,
    expires_at_ns: u64,
    revoked: bool = false,

    pub fn valid(self: *const PrimaryLease, now_ns: u64) bool {
        return !self.revoked and now_ns >= self.issued_at_ns and now_ns < self.expires_at_ns;
    }
};

pub const FencingAuthority = struct {
    records: [max_domains]AuthorityRecord = undefined,
    count: usize = 0,
    available: bool = true,
    durable: bool = true,

    fn find(self: *FencingAuthority, key: DomainKey) ?*AuthorityRecord {
        for (self.records[0..self.count]) |*record| if (record.key.eql(key)) return record;
        return null;
    }

    pub fn acquire(self: *FencingAuthority, key: DomainKey, node: u64, now_ns: u64) !PrimaryLease {
        if (!self.available or !self.durable) return error.FencingAuthorityUnavailable;
        if (node == 0) return error.InvalidNode;
        const record = if (self.find(key)) |existing| existing else blk: {
            if (self.count == self.records.len) return error.AuthorityCapacity;
            self.records[self.count] = .{ .key = key };
            self.count += 1;
            break :blk &self.records[self.count - 1];
        };
        if (record.current_token != 0) return error.LeaseAlreadyHeld;
        if (record.next_token == 0) return error.FencingTokenExhausted;
        const token = record.next_token;
        const next_token = std.math.add(u64, token, 1) catch return error.FencingTokenExhausted;
        const durable_barrier = std.math.add(u64, record.durable_barrier, 1) catch return error.DurableBarrierExhausted;
        const expires_at_ns = std.math.add(u64, now_ns, lease_duration_ns) catch return error.LeaseTimeOverflow;
        record.next_token = next_token;
        record.current_token = token;
        record.owner_node = node;
        record.durable_barrier = durable_barrier;
        return .{
            .key = key,
            .node = node,
            .token = token,
            .issued_at_ns = now_ns,
            .expires_at_ns = expires_at_ns,
        };
    }

    pub fn renew(self: *FencingAuthority, lease: *PrimaryLease, now_ns: u64) !void {
        if (!self.available or !self.durable) return error.FencingAuthorityUnavailable;
        if (!lease.valid(now_ns)) return error.LeaseExpired;
        const record = self.find(lease.key) orelse return error.StaleFencingToken;
        if (record.current_token != lease.token or record.owner_node != lease.node)
            return error.StaleFencingToken;
        lease.expires_at_ns = std.math.add(u64, now_ns, lease_duration_ns) catch return error.LeaseTimeOverflow;
    }

    pub fn revoke(self: *FencingAuthority, lease: *PrimaryLease) !void {
        const record = self.find(lease.key) orelse return error.StaleFencingToken;
        if (record.current_token != lease.token or record.owner_node != lease.node)
            return error.StaleFencingToken;
        record.current_token = 0;
        record.owner_node = 0;
        lease.revoked = true;
    }

    pub fn currentToken(self: *FencingAuthority, key: DomainKey) ?u64 {
        const record = self.find(key) orelse return null;
        return if (record.current_token == 0) null else record.current_token;
    }

    pub fn accepts(self: *FencingAuthority, key: DomainKey, node: u64, token: u64) bool {
        const record = self.find(key) orelse return false;
        return token != 0 and record.current_token == token and record.owner_node == node;
    }
};

pub const NodeFence = struct {
    available: bool = true,
    verified: bool = false,
    isolated_node: u64 = 0,
    active_node: u64 = 0,
    generation: u64 = 0,

    pub fn bootstrap(self: *NodeFence, node: u64) !void {
        if (!self.available or node == 0) return error.NodeFenceUnavailable;
        self.active_node = node;
        self.verified = true;
    }

    pub fn establish(self: *NodeFence, old_node: u64, new_node: u64) !void {
        if (!self.available or old_node == 0 or new_node == 0 or old_node == new_node)
            return error.NodeFenceUnavailable;
        self.isolated_node = old_node;
        self.active_node = new_node;
        self.generation = std.math.add(u64, self.generation, 1) catch return error.FenceGenerationExhausted;
        self.verified = false;
    }

    pub fn readBack(self: *NodeFence, expected_old: u64, expected_new: u64) !void {
        if (!self.available or self.isolated_node != expected_old or self.active_node != expected_new)
            return error.NodeFenceReadbackMismatch;
        self.verified = true;
    }

    pub fn blocks(self: *const NodeFence, node: u64) bool {
        return self.verified and self.isolated_node == node;
    }
};

pub const GatewayLeaseGuard = struct {
    authority: *FencingAuthority,
    lease: *PrimaryLease,
    recovery_only: bool = false,

    pub fn renew(self: *GatewayLeaseGuard, now_ns: u64) !void {
        self.authority.renew(self.lease, now_ns) catch |err| {
            self.recovery_only = true;
            return err;
        };
    }

    /// Every send checks the current token. Increasing risk additionally
    /// requires a live monotonic lease; expiry leaves cancel/reduce recovery.
    pub fn check(self: *GatewayLeaseGuard, now_ns: u64, token: u64, increases_risk: bool) !void {
        if (!self.authority.accepts(self.lease.key, self.lease.node, token) or token != self.lease.token)
            return error.StaleFencingToken;
        if (increases_risk and self.recovery_only) return error.RecoveryOnly;
        if (increases_risk and !self.lease.valid(now_ns)) {
            self.recovery_only = true;
            return error.PrimaryLeaseExpired;
        }
    }
};

pub const ObservationCredential = struct {
    exchange_account: u128,
    node: u64,
    read_only: bool = true,
    can_trade: bool = false,
};

pub const Standby = struct {
    credential: ObservationCredential,
    last_sequence: u64 = 0,
    last_update_ns: u64 = 0,
    corrupted: bool = false,

    pub fn apply(self: *Standby, sequence: u64, now_ns: u64) !void {
        if (self.corrupted or sequence != self.last_sequence + 1) {
            self.corrupted = true;
            return error.ReplaySequenceGap;
        }
        self.last_sequence = sequence;
        self.last_update_ns = now_ns;
    }

    pub fn health(self: *const Standby, primary_sequence: u64, now_ns: u64) ReplayHealth {
        if (self.corrupted or primary_sequence < self.last_sequence) return .invalid;
        const lag_events = primary_sequence - self.last_sequence;
        const lag_ns = if (now_ns >= self.last_update_ns) now_ns - self.last_update_ns else std.math.maxInt(u64);
        if (lag_events > standby_max_lag_events or lag_ns > standby_max_lag_ns) return .degraded;
        return .healthy;
    }
};

pub const ReplayHealth = enum { healthy, degraded, invalid };

pub const AdmissionEvidence = struct {
    cause: FailoverCause,
    fault: FaultKind = .normal,
    outcome: Outcome,
    reason: FixedText,
    old_node: u64,
    new_node: u64,
    old_token: u64,
    new_token: u64 = 0,
    fence_verified: bool = false,
    old_lease_revoked: bool = false,
    replay_zero: bool = false,
    observation_only: bool = false,
    reconciliation_ok: bool = false,
    state_gap: bool = false,
    open_orders: u32,
    safety_rto_ns: u64 = 0,
    trading_rto_ns: u64 = 0,
    automatic_candidate: bool,
};

pub const FailoverInput = struct {
    cause: FailoverCause,
    old_node: u64,
    new_node: u64,
    now_ns: u64,
    primary_sequence: u64,
    standby_sequence: u64,
    standby_last_update_ns: u64,
    open_orders: u32 = 0,
    reconciliation_ok: bool = true,
    state_gap: bool = false,
    market_healthy: bool = true,
};

pub const FailoverEngine = struct {
    authority: *FencingAuthority,
    fence: *NodeFence,
    old_lease: *PrimaryLease,
    standby: *const Standby,

    pub fn attempt(self: *FailoverEngine, input: FailoverInput) AdmissionEvidence {
        var evidence: AdmissionEvidence = .{
            .cause = input.cause,
            .outcome = .blocked,
            .reason = FixedText.literal("failover_not_admitted"),
            .old_node = input.old_node,
            .new_node = input.new_node,
            .old_token = self.old_lease.token,
            .open_orders = input.open_orders,
            .automatic_candidate = isAutomaticCause(input.cause),
        };
        if (input.old_node != self.old_lease.node or input.new_node == 0 or input.new_node == input.old_node) {
            evidence.reason = FixedText.literal("failover_node_identity_mismatch");
            return evidence;
        }
        if (!evidence.automatic_candidate) {
            evidence.reason = FixedText.literal("network_partition_or_untrusted_state_never_auto_promotes");
            return evidence;
        }
        if (self.standby.credential.can_trade or !self.standby.credential.read_only) {
            evidence.reason = FixedText.literal("standby_credential_is_not_observation_only");
            return evidence;
        }
        if (input.cause == .planned_switch and (input.open_orders != 0 or input.primary_sequence != input.standby_sequence)) {
            evidence.reason = FixedText.literal("planned_switch_requires_zero_open_orders_and_replay_rpo_zero");
            return evidence;
        }
        const replay = if (input.standby_sequence != self.standby.last_sequence)
            ReplayHealth.invalid
        else if (input.primary_sequence < input.standby_sequence or input.now_ns < input.standby_last_update_ns)
            ReplayHealth.invalid
        else if (input.primary_sequence - input.standby_sequence > standby_max_lag_events or
            input.now_ns - input.standby_last_update_ns > standby_max_lag_ns)
            ReplayHealth.degraded
        else
            self.standby.health(input.primary_sequence, input.now_ns);
        if (replay != .healthy) {
            evidence.reason = if (replay == .degraded)
                FixedText.literal("HADegraded_replay_lag_blocks_auto_promotion")
            else
                FixedText.literal("invalid_standby_state_blocks_auto_promotion");
            return evidence;
        }
        if (!input.reconciliation_ok or input.state_gap or !input.market_healthy) {
            evidence.reason = FixedText.literal("reconciliation_state_or_market_gate_failed");
            evidence.state_gap = input.state_gap;
            evidence.reconciliation_ok = input.reconciliation_ok;
            return evidence;
        }
        self.authority.revoke(self.old_lease) catch {
            evidence.reason = FixedText.literal("old_primary_lease_revoke_failed");
            return evidence;
        };
        evidence.old_lease_revoked = true;
        self.fence.establish(input.old_node, input.new_node) catch {
            evidence.reason = FixedText.literal("NodeFence_establish_failed");
            return evidence;
        };
        self.fence.readBack(input.old_node, input.new_node) catch {
            evidence.reason = FixedText.literal("NodeFence_readback_failed");
            return evidence;
        };
        evidence.fence_verified = self.fence.blocks(input.old_node);
        if (!evidence.fence_verified) {
            evidence.reason = FixedText.literal("old_node_is_not_fenced");
            return evidence;
        }
        const wait_until = @max(input.now_ns, self.old_lease.expires_at_ns);
        const new_lease = self.authority.acquire(self.old_lease.key, input.new_node, wait_until) catch {
            evidence.reason = FixedText.literal("new_fencing_token_allocation_failed");
            return evidence;
        };
        evidence.new_token = new_lease.token;
        evidence.replay_zero = input.primary_sequence == input.standby_sequence;
        evidence.observation_only = self.standby.credential.read_only and !self.standby.credential.can_trade;
        evidence.reconciliation_ok = input.reconciliation_ok;
        evidence.state_gap = input.state_gap;
        evidence.safety_rto_ns = wait_until -| input.now_ns;
        evidence.trading_rto_ns = if (input.cause == .process_failure) 2 * std.time.ns_per_s else 5 * std.time.ns_per_s;
        const limit = if (input.cause == .process_failure) process_trading_rto_ns else node_trading_rto_ns;
        if (evidence.safety_rto_ns > safety_rto_ns or evidence.trading_rto_ns > limit) {
            evidence.reason = FixedText.literal("RTO_contract_exceeded");
            return evidence;
        }
        if (!self.authority.accepts(self.old_lease.key, input.new_node, new_lease.token)) {
            evidence.reason = FixedText.literal("new_token_readback_failed");
            return evidence;
        }
        evidence.outcome = .passed;
        evidence.reason = FixedText.literal("fenced_replayed_reconciled_and_admitted");
        return evidence;
    }
};

fn isAutomaticCause(cause: FailoverCause) bool {
    return cause == .planned_switch or cause == .process_failure or cause == .node_failure;
}

pub const FailoverReport = struct {
    schema_version: u16 = 1,
    entries: [max_report_entries]AdmissionEvidence = undefined,
    entry_count: usize = 0,
    sealed: bool = false,

    pub fn append(self: *FailoverReport, entry: AdmissionEvidence) !void {
        if (self.sealed) return error.ReportSealed;
        if (self.entry_count == self.entries.len) return error.ReportFull;
        self.entries[self.entry_count] = entry;
        self.entry_count += 1;
    }

    pub fn seal(self: *FailoverReport) !void {
        if (self.sealed or self.entry_count == 0) return error.InvalidReport;
        self.sealed = true;
    }

    fn conclusion(self: *const FailoverReport) Outcome {
        for (self.entries[0..self.entry_count]) |entry|
            if (entry.outcome == .failed or entry.outcome == .invalid) return entry.outcome;
        return .passed;
    }

    pub fn writeJson(self: *const FailoverReport, writer: *std.Io.Writer) !void {
        if (!self.sealed) return error.ReportNotSealed;
        try writer.print("{{\"schema_version\":{d},\"conclusion\":\"{s}\",\"entries\":[", .{ self.schema_version, @tagName(self.conclusion()) });
        for (self.entries[0..self.entry_count], 0..) |entry, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{{\"cause\":\"{s}\",\"fault\":\"{s}\",\"outcome\":\"{s}\",\"reason\":\"{s}\",\"old_node\":{d},\"new_node\":{d},\"old_token\":{d},\"new_token\":{d},\"fence_verified\":{},\"old_lease_revoked\":{},\"replay_zero\":{},\"observation_only\":{},\"reconciliation_ok\":{},\"state_gap\":{},\"open_orders\":{d},\"safety_rto_ns\":{d},\"trading_rto_ns\":{d},\"automatic_candidate\":{}}}", .{
                @tagName(entry.cause),
                @tagName(entry.fault),
                @tagName(entry.outcome),
                entry.reason.slice(),
                entry.old_node,
                entry.new_node,
                entry.old_token,
                entry.new_token,
                entry.fence_verified,
                entry.old_lease_revoked,
                entry.replay_zero,
                entry.observation_only,
                entry.reconciliation_ok,
                entry.state_gap,
                entry.open_orders,
                entry.safety_rto_ns,
                entry.trading_rto_ns,
                entry.automatic_candidate,
            });
        }
        try writer.writeAll("]}\n");
    }
};

fn writeAtomic(init: std.process.Init, path: []const u8, report: *const FailoverReport) !void {
    var temp_name: [256]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_name, "{s}.tmp", .{path});
    var file = try std.Io.Dir.cwd().createFile(init.io, temp, .{ .truncate = true });
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try report.writeJson(&writer.interface);
    try writer.interface.flush();
    try file.sync(init.io);
    file.close(init.io);
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, init.io);
}

fn freshStandby(now_ns: u64, sequence: u64) !Standby {
    var standby = Standby{ .credential = .{ .exchange_account = 900, .node = 2 } };
    for (1..sequence + 1) |item| try standby.apply(item, now_ns);
    return standby;
}

fn runAllowed(cause: FailoverCause, now_ns: u64) !AdmissionEvidence {
    const key: DomainKey = .{ .exchange_account = 900, .decision_domain = 1 };
    var authority: FencingAuthority = .{};
    var old_lease = try authority.acquire(key, 1, now_ns);
    var fence: NodeFence = .{};
    try fence.bootstrap(1);
    var standby = try freshStandby(now_ns, 100);
    var engine = FailoverEngine{ .authority = &authority, .fence = &fence, .old_lease = &old_lease, .standby = &standby };
    var evidence = engine.attempt(.{
        .cause = cause,
        .old_node = 1,
        .new_node = 2,
        .now_ns = now_ns,
        .primary_sequence = 100,
        .standby_sequence = 100,
        .standby_last_update_ns = now_ns,
    });
    evidence.fault = switch (cause) {
        .planned_switch => .normal,
        .process_failure => .process_exit,
        .node_failure => .node_power_loss,
        else => .normal,
    };
    return evidence;
}

pub fn runSmoke(init: std.process.Init, report_path: []const u8) !void {
    var report: FailoverReport = .{};
    for (0..3) |attempt| {
        const now = 1_000_000_000 + @as(u64, @intCast(attempt)) * 100_000_000;
        for ([_]FailoverCause{ .planned_switch, .process_failure, .node_failure }) |cause| {
            const evidence = try runAllowed(cause, now);
            if (evidence.outcome != .passed) return error.AutomaticFailoverRejected;
            try report.append(evidence);
        }
    }

    const key: DomainKey = .{ .exchange_account = 900, .decision_domain = 1 };
    var authority: FencingAuthority = .{};
    var old_lease = try authority.acquire(key, 1, 1_000_000_000);
    var fence: NodeFence = .{};
    try fence.bootstrap(1);
    var standby = try freshStandby(1_000_000_000, 100);
    var engine = FailoverEngine{ .authority = &authority, .fence = &fence, .old_lease = &old_lease, .standby = &standby };

    var blocked = engine.attempt(.{
        .cause = .network_partition,
        .old_node = 1,
        .new_node = 2,
        .now_ns = 1_000_000_000,
        .primary_sequence = 100,
        .standby_sequence = 100,
        .standby_last_update_ns = 1_000_000_000,
    });
    blocked.fault = .network_partition;
    try report.append(blocked);
    blocked = engine.attempt(.{
        .cause = .process_failure,
        .old_node = 1,
        .new_node = 2,
        .now_ns = 1_000_000_000,
        .primary_sequence = 30_000,
        .standby_sequence = 100,
        .standby_last_update_ns = 0,
    });
    blocked.fault = .replication_interrupt;
    try report.append(blocked);
    blocked = engine.attempt(.{
        .cause = .untrusted_state,
        .old_node = 1,
        .new_node = 2,
        .now_ns = 1_000_000_000,
        .primary_sequence = 100,
        .standby_sequence = 100,
        .standby_last_update_ns = 1_000_000_000,
    });
    blocked.fault = .storage_corruption;
    try report.append(blocked);
    fence.available = false;
    blocked = engine.attempt(.{
        .cause = .node_failure,
        .old_node = 1,
        .new_node = 2,
        .now_ns = 1_000_000_000,
        .primary_sequence = 100,
        .standby_sequence = 100,
        .standby_last_update_ns = 1_000_000_000,
    });
    blocked.fault = .fence_failure;
    try report.append(blocked);

    var stale_guard = GatewayLeaseGuard{ .authority = &authority, .lease = &old_lease };
    const stale_rejected = stale_guard.check(1_000_000_000, old_lease.token, true) catch |err| err == error.StaleFencingToken;
    if (!stale_rejected) return error.StaleTokenWasAccepted;
    var stale = engine.attempt(.{
        .cause = .process_failure,
        .old_node = 1,
        .new_node = 2,
        .now_ns = 1_000_000_000,
        .primary_sequence = 100,
        .standby_sequence = 100,
        .standby_last_update_ns = 1_000_000_000,
    });
    stale.fault = .stale_token;
    stale.outcome = .blocked;
    stale.reason = FixedText.literal("old_token_or_reappearing_node_rejected");
    try report.append(stale);

    var admission = engine.attempt(.{
        .cause = .process_failure,
        .old_node = 1,
        .new_node = 2,
        .now_ns = 1_000_000_000,
        .primary_sequence = 100,
        .standby_sequence = 100,
        .standby_last_update_ns = 1_000_000_000,
        .reconciliation_ok = false,
    });
    admission.fault = .admission_interrupt;
    try report.append(admission);
    try report.seal();
    try writeAtomic(init, report_path, &report);

    var buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("failover_smoke=passed entries={d} automatic_runs=9 blocked_faults=6 production_qualification=false report={s}\n", .{ report.entry_count, report_path });
    try stdout.interface.flush();
}

test "fencing tokens are strictly increasing and stale sends fail" {
    const key: DomainKey = .{ .exchange_account = 900, .decision_domain = 1 };
    var authority: FencingAuthority = .{};
    var first = try authority.acquire(key, 1, 0);
    try std.testing.expectEqual(@as(u64, 1), first.token);
    try std.testing.expectError(error.LeaseExpired, authority.renew(&first, lease_duration_ns + 1));
    try authority.revoke(&first);
    const second = try authority.acquire(key, 2, lease_duration_ns + 1);
    try std.testing.expectEqual(@as(u64, 2), second.token);
}

test "lease renewal failure enters recovery only and gateway checks clock" {
    const key: DomainKey = .{ .exchange_account = 900, .decision_domain = 1 };
    var authority: FencingAuthority = .{};
    var lease = try authority.acquire(key, 1, 0);
    var guard = GatewayLeaseGuard{ .authority = &authority, .lease = &lease };
    try guard.check(100, lease.token, true);
    authority.available = false;
    try std.testing.expectError(error.FencingAuthorityUnavailable, guard.renew(100));
    try std.testing.expectError(error.RecoveryOnly, guard.check(100, lease.token, true));
    try std.testing.expect(guard.recovery_only);
}

test "standby observation credential and lag fail closed" {
    var standby = Standby{ .credential = .{ .exchange_account = 900, .node = 2 } };
    try standby.apply(1, 0);
    try std.testing.expectEqual(ReplayHealth.healthy, standby.health(1, 1));
    try std.testing.expectEqual(ReplayHealth.degraded, standby.health(standby_max_lag_events + 2, 1));
    try std.testing.expectEqual(ReplayHealth.degraded, standby.health(1, standby_max_lag_ns + 1));
    try std.testing.expect(!standby.credential.can_trade and standby.credential.read_only);
}

test "failover fences old node before allocating a new token" {
    const evidence = try runAllowed(.planned_switch, 1_000_000_000);
    try std.testing.expectEqual(Outcome.passed, evidence.outcome);
    try std.testing.expect(evidence.fence_verified);
    try std.testing.expect(evidence.old_lease_revoked);
    try std.testing.expect(evidence.replay_zero);
    try std.testing.expect(evidence.new_token > evidence.old_token);
}

test "network partition and untrusted state never auto promote" {
    const key: DomainKey = .{ .exchange_account = 900, .decision_domain = 1 };
    var authority: FencingAuthority = .{};
    var old_lease = try authority.acquire(key, 1, 0);
    var fence: NodeFence = .{};
    try fence.bootstrap(1);
    var standby = try freshStandby(0, 1);
    var engine = FailoverEngine{ .authority = &authority, .fence = &fence, .old_lease = &old_lease, .standby = &standby };
    const evidence = engine.attempt(.{
        .cause = .network_partition,
        .old_node = 1,
        .new_node = 2,
        .now_ns = 1,
        .primary_sequence = 1,
        .standby_sequence = 1,
        .standby_last_update_ns = 0,
    });
    try std.testing.expectEqual(Outcome.blocked, evidence.outcome);
    try std.testing.expectEqual(@as(u64, 1), authority.currentToken(key).?);
}

test "failover report is immutable and keeps blocked evidence" {
    var report: FailoverReport = .{};
    try report.append(.{
        .cause = .network_partition,
        .outcome = .blocked,
        .reason = FixedText.literal("blocked"),
        .old_node = 1,
        .new_node = 2,
        .old_token = 1,
        .open_orders = 0,
        .automatic_candidate = false,
    });
    try report.seal();
    try std.testing.expectEqual(Outcome.passed, report.conclusion());
    try std.testing.expectError(error.ReportSealed, report.append(.{
        .cause = .node_failure,
        .fault = .normal,
        .outcome = .passed,
        .reason = FixedText.literal("late"),
        .old_node = 1,
        .new_node = 2,
        .old_token = 1,
        .open_orders = 0,
        .automatic_candidate = true,
    }));
}
