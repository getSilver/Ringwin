//! Bounded, transient qualification of a private checkpoint against durable core
//! authority. This owns no balances, orders, occupancy, or reusable send permit.
const std = @import("std");
const trading = @import("../trading/trading_shard.zig");
const owner_module = @import("demo/demo_authority.zig");
const codec = @import("../strategy/strategy_host_recovery.zig");
const lifecycle = @import("../strategy/strategy_host_lifecycle.zig");
const history = @import("../persistence/business_history.zig");

pub const Clock = enum { unverified, utc };

/// Frozen package configuration, supplied independently of Python/checkpoints.
pub const Binding = struct {
    component: []const u8,
    first_sequence: u64,
    dependency: [32]u8,
    group_digest: [32]u8,
    projection_digest: [32]u8,
    holding_deadline_utc_ns: u64,
    repair_deadline_utc_ns: u64,
    exit_deadline_utc_ns: u64,
    legs: [2]Leg,
};

pub const Leg = struct {
    account: u128,
    instrument: u128,
    direction: trading.oms.Side,
    rules_version: u64,
    base_atomic_scale: u8,
};

pub const Recovery = opaque {
    pub fn begin(gpa: std.mem.Allocator, owner: *owner_module.Owner, strategy: u128, session: @import("../strategy/strategy_host_ipc.zig").Session) !*Recovery {
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.* = try State.begin(owner, strategy, session);
        state.allocator = gpa;
        return @ptrCast(state);
    }

    pub fn deinit(self: *Recovery) void {
        const state = self.internal();
        state.allocator.destroy(state);
    }

    pub fn currentUtc(self: *Recovery, owner: *const owner_module.Owner) !u64 {
        return self.internal().currentUtc(owner);
    }

    pub fn qualify(self: *Recovery, gpa: std.mem.Allocator, owner: *const owner_module.Owner, container: []const u8, expected: codec.Metadata, bindings: []const Binding, clock: Clock) !Ticket {
        return self.internal().qualify(gpa, owner, container, expected, bindings, clock);
    }

    pub fn activate(self: *Recovery, owner: *owner_module.Owner) !lifecycle.Activation {
        return self.internal().activate(owner);
    }

    fn internal(self: *Recovery) *State {
        return @ptrCast(@alignCast(self));
    }
};

const State = struct {
    allocator: std.mem.Allocator = undefined,
    strategy: u128,
    session: @import("../strategy/strategy_host_ipc.zig").Session,
    fence: u64,
    minimum_utc_ns: u64,
    consumed: bool = false,
    ticket: ?Ticket = null,

    pub fn currentUtc(self: *const State, owner: *const owner_module.Owner) !u64 {
        try stable(owner);
        const now = try latestUtc(owner);
        var reader = try trading.journal.Reader.init(owner.decision_journal.bytes());
        var previous = self.minimum_utc_ns;
        while (true) switch (try reader.next()) {
            .record => |record| if (record.sequence > self.fence and record.flags & trading.journal.input_flag != 0 and record.time_presence.wall) {
                if (record.wall_time < previous) return error.RecoveryClockUnavailable;
                previous = record.wall_time;
            },
            .end => break,
        };
        if (now < self.minimum_utc_ns) return error.RecoveryClockUnavailable;
        return now;
    }

    /// The caller first restores Owner and withdraws opening authorization.
    /// Revocation itself is committed through Owner before any new Host starts.
    pub fn begin(owner: *owner_module.Owner, strategy: u128, session: @import("../strategy/strategy_host_ipc.zig").Session) !State {
        try stable(owner);
        const authority = owner.shard.strategyAuthority(strategy);
        if (!authority.strategy_active or session.generation == 0 or session.fencing == 0 or
            session.fencing != owner.shard.fencing_token or owner.shard.operational_state.trading_authorized)
            return error.CoreRecoveryIncomplete;
        if (authority.host_activation_identity != 0) {
            if (std.meta.eql(authority.host_activation_session, session)) return error.OldHostSession;
            _ = try owner.apply(.{ .core = .{ .identity = owner.shard.authoritativeBarrier() + 1, .payload = .{ .host_activation_revoked = .{
                .strategy_identity = strategy,
                .activation_identity = authority.host_activation_identity,
                .reason = .session_replaced,
                .session = authority.host_activation_session,
            } } } });
        } else if (authority.host_activation_seen and std.meta.eql(authority.host_activation_session, session)) {
            return error.OldHostSession;
        }
        return .{ .strategy = strategy, .session = session, .fence = owner.shard.authoritativeBarrier(), .minimum_utc_ns = try latestUtc(owner) };
    }

    /// Validate the exact checkpoint returned by the recovered Host. All active
    /// core cycles must be represented; private Completed cannot release a key.
    pub fn qualify(self: *State, gpa: std.mem.Allocator, owner: *const owner_module.Owner, container: []const u8, expected: codec.Metadata, bindings: []const Binding, clock: Clock) !Ticket {
        self.ticket = null;
        try stable(owner);
        if (!owner.shard.strategyAuthority(self.strategy).strategy_active or owner.shard.strategyFenced(self.strategy)) return error.StrategyCutoverFenced;
        if (self.consumed or clock != .utc or expected.strategy_instance != self.strategy or
            self.session.fencing != owner.shard.fencing_token or
            expected.strategy_config_version != owner.shard.strategyAuthority(self.strategy).strategy_config_version or
            expected.strategy_cursor != owner.shard.authoritativeBarrier() or expected.strategy_cursor < self.fence or
            expected.state_schema != 0x43565354415445000000000000000001 or expected.state_schema_version != 2 or
            bindings.len > 16 or owner.shard.operational_state.trading_authorized)
            return error.InvalidRecoveryQualification;
        for (bindings, 0..) |binding, index| {
            if (binding.component.len == 0 or binding.component.len > 128 or binding.first_sequence == 0) return error.InvalidCycleBindings;
            for (bindings[0..index]) |prior| if (prior.first_sequence == binding.first_sequence or std.mem.eql(u8, prior.component, binding.component)) return error.InvalidCycleBindings;
        }
        const decoded = try codec.decodePayloadCheckpoint(container, expected);
        const now = try self.currentUtc(owner);
        try verifyAccount(owner, owner.shard.exchange_account_identity, self.fence, expected.next_intent_sequence, self.strategy);
        for (owner.shard.secondary_accounts[0..owner.shard.secondary_account_count]) |account|
            try verifyAccount(owner, account.identity, self.fence, expected.next_intent_sequence, self.strategy);
        if (owner.shard.business_history_root) |root| try verifyArchivedSequence(owner, root, self.strategy, expected.next_intent_sequence);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, decoded.payload, .{ .max_value_len = 128, .parse_numbers = false });
        defer parsed.deinit();
        const rows = try field(parsed.value, "components");
        if (rows != .array or rows.array.items.len > 64) return error.InvalidCycleCheckpoint;
        var found: [16]bool = @splat(false);
        var cycle_count: usize = 0;
        for (rows.array.items) |row| {
            const tag = try string(try field(row, "tag"));
            if (!std.mem.eql(u8, tag, "cycle") and !std.mem.eql(u8, tag, "maker_cycle")) continue;
            const state = try field(row, "state");
            const phase = try string(try field(state, "phase"));
            if (std.mem.eql(u8, phase, "idle")) {
                if (try unsigned(try field(state, "next_sequence")) != expected.next_intent_sequence) return error.IntentSequenceRegression;
                continue;
            }
            cycle_count += 1;
            const name = try string(try field(row, "name"));
            var matched: ?usize = null;
            for (bindings, 0..) |binding, index| if (std.mem.eql(u8, binding.component, name)) {
                if (matched != null or found[index]) return error.InvalidCycleCheckpoint;
                matched = index;
            };
            const index = matched orelse return error.UnboundPrivateCycle;
            found[index] = true;
            const binding = bindings[index];
            const hex = std.fmt.bytesToHex(binding.dependency, .lower);
            if (!std.mem.eql(u8, try string(try field(row, "dependency")), &hex)) return error.FrozenPlanMismatch;
            const completed = owner.shard.cycles.completed(self.strategy, binding.first_sequence);
            const record = if (completed) |closed| closed.record else owner.shard.cycles.find(self.strategy, binding.first_sequence) orelse return error.UnknownCycle;
            if (!std.mem.eql(u8, &record.content_digest, &binding.group_digest) or
                record.portfolio != owner.shard.strategyAuthority(self.strategy).portfolio_identity)
                return error.CycleOwnershipMismatch;
            if (std.mem.eql(u8, phase, "completed") != (completed != null) or std.mem.eql(u8, phase, "idle"))
                return error.CycleStateNotCaughtUp;
            var reference_buffer: [128]u8 = undefined;
            const reference = try std.fmt.bufPrint(&reference_buffer, "cycle:{d}:{d}", .{ self.strategy, binding.first_sequence });
            if (!std.mem.eql(u8, try string(try optional(try field(state, "cycle_ref"))), reference)) return error.CycleReferenceMismatch;
            var reservation_buffer: [128]u8 = undefined;
            const reservation = try std.fmt.bufPrint(&reservation_buffer, "reservation:{d}:{d}", .{ self.strategy, binding.first_sequence });
            if (!std.mem.eql(u8, try string(try optional(try field(state, "reservation_ref"))), reservation)) return error.CycleReferenceMismatch;
            var economic_buffer: [128]u8 = undefined;
            const economic = try std.fmt.bufPrint(&economic_buffer, "economic:{d}:{s}", .{ expected.strategy_cursor, std.fmt.bytesToHex(binding.projection_digest, .lower) });
            if (std.mem.allEqual(u8, &binding.projection_digest, 0) or
                !std.mem.eql(u8, try string(try optional(try field(state, "last_economic_ref"))), economic)) return error.EconomicProjectionMismatch;
            if (try unsigned(try field(state, "next_sequence")) != expected.next_intent_sequence or
                try unsigned(try field(state, "cursor")) > expected.strategy_cursor or
                try unsigned(try field(state, "last_at_ns")) != now)
                return error.StrategyTimeNotCaughtUp;
            const before = try optional(try field(state, "before_reconciling"));
            const holding = std.mem.eql(u8, phase, "holding") or (before == .string and std.mem.eql(u8, before.string, "holding"));
            if (completed == null) try verifyIssued(owner, self.strategy, record, binding, state);
            if (holding or std.mem.eql(u8, phase, "repairing")) {
                var exposed: usize = 0;
                for (record.members[0..record.count], 0..) |member, leg_index| {
                    const leg = binding.legs[leg_index];
                    if (leg.account != member.account or leg.instrument != member.instrument) return error.CycleOwnershipMismatch;
                    const account = owner.shard.accountState(member.account) orelse return error.UnknownRecoveryAccount;
                    const portfolio = account.economic_projection.portfolioLayer(record.portfolio) orelse return error.CycleOwnershipMismatch;
                    if (portfolio.instrumentPosition(member.instrument)) |position| {
                        if (position.position.quantity == 0 and position.spot_asset_atoms == 0) continue;
                        if (position.rules_version != leg.rules_version) return error.FrozenPlanMismatch;
                        var numerator: i128 = 0;
                        var denominator: i128 = 1;
                        if (position.product == .spot) {
                            if (leg.direction != .buy) return error.CycleEconomicMismatch;
                            numerator = try std.math.sub(i128, position.spot_asset_atoms, try owner.shard.cycles.reservedInstrumentAtoms(member.account, record.portfolio, position.base_asset, member.instrument));
                        } else {
                            if ((position.position.quantity > 0 and leg.direction != .buy) or (position.position.quantity < 0 and leg.direction != .sell)) return error.CycleEconomicMismatch;
                            const unit = try (trading.canonical.Decimal{ .coefficient = position.quantity_numerator, .scale = 0 }).exactAtoms(leg.base_atomic_scale);
                            numerator = try std.math.mul(i128, @intCast(@abs(position.position.quantity)), unit);
                            denominator = position.quantity_denominator;
                        }
                        if (numerator < 0 or denominator <= 0) return error.CycleEconomicMismatch;
                        if (numerator != 0) exposed += 1;
                        if (holding) {
                            const matched_base = try optional(try field(state, "matched_base"));
                            const n = try unsigned(try field(matched_base, "numerator"));
                            const d = try unsigned(try field(matched_base, "denominator"));
                            if (n == 0 or d == 0 or try std.math.mul(i128, numerator, d) != try std.math.mul(i128, denominator, n)) return error.CycleEconomicMismatch;
                        }
                    }
                }
                if ((holding and exposed != record.count) or exposed == 0) return error.CycleEconomicMismatch;
            }
            const exiting = std.mem.eql(u8, phase, "exiting") or std.mem.eql(u8, phase, "settling") or std.mem.eql(u8, phase, "completed") or
                (std.mem.eql(u8, phase, "reconciling") and before == .string and std.mem.eql(u8, before.string, "exiting"));
            if (binding.holding_deadline_utc_ns == 0 or binding.repair_deadline_utc_ns == 0 or
                binding.exit_deadline_utc_ns < binding.holding_deadline_utc_ns or
                (!exiting and now >= binding.holding_deadline_utc_ns)) return error.ExpiredPrivateCycle;
            if ((std.mem.eql(u8, phase, "holding") and now >= binding.holding_deadline_utc_ns) or
                (std.mem.eql(u8, phase, "repairing") and now >= binding.repair_deadline_utc_ns) or
                (std.mem.eql(u8, phase, "entering") and now >= binding.holding_deadline_utc_ns))
                return error.ExpiredPrivateCycle;
            if ((std.mem.eql(u8, phase, "exiting") or (before == .string and std.mem.eql(u8, before.string, "exiting"))) and
                (try optional(try field(state, "first_exit"))) == .null) return error.ExitLatchMissing;
        }
        if (cycle_count != bindings.len) return error.MissingPrivateCycle;
        for (owner.shard.cycles.records[0..owner.shard.cycles.count]) |record| {
            if (record.strategy != self.strategy) continue;
            var matched = false;
            for (bindings) |binding| if (binding.first_sequence == record.first_sequence) {
                matched = true;
            };
            if (!matched) return error.MissingPrivateCycle;
        }
        const ticket: Ticket = .{ .core_barrier = expected.strategy_cursor, .core_digest = owner.shard.canonicalStateDigest(), .private_digest = decoded.state_digest, .metadata = expected };
        self.ticket = ticket;
        return ticket;
    }

    /// Stable core activation is committed before an IPC activation can be sent.
    /// Neither this method nor replay resumes opening authorization.
    pub fn activate(self: *State, owner: *owner_module.Owner) !lifecycle.Activation {
        const ticket = self.ticket orelse return error.RecoveryNotQualified;
        try stable(owner);
        if (!owner.shard.strategyAuthority(self.strategy).strategy_active or owner.shard.strategyFenced(self.strategy)) return error.StrategyCutoverFenced;
        if (self.consumed or owner.shard.operational_state.trading_authorized or
            self.session.fencing != owner.shard.fencing_token or
            owner.shard.authoritativeBarrier() != ticket.core_barrier or
            !std.mem.eql(u8, &owner.shard.canonicalStateDigest(), &ticket.core_digest) or
            ticket.metadata.strategy_instance != self.strategy) return error.StaleRecoveryQualification;
        const authority = owner.shard.strategyAuthority(self.strategy);
        if (authority.host_activation_identity != 0) return error.HostNotRevoked;
        const identity = if (authority.host_activation_seen) try owner.shard.nextHostActivationIdentityForStrategy(self.strategy) else authority.strategy_activation_identity;
        const barrier = try std.math.add(u64, ticket.core_barrier, 1);
        _ = try owner.apply(.{ .core = .{ .identity = barrier, .payload = .{ .host_activated = .{
            .strategy_identity = self.strategy,
            .config_version = ticket.metadata.strategy_config_version,
            .activation_identity = identity,
            .session = self.session,
            .activation_barrier = barrier,
            .state_digest = ticket.core_digest,
        } } } });
        self.consumed = true;
        return .{ .strategy_identity = self.strategy, .activation_identity = identity, .barrier = barrier, .state_digest = ticket.private_digest };
    }
};

pub const Ticket = struct {
    core_barrier: u64,
    core_digest: [32]u8,
    private_digest: [32]u8,
    metadata: codec.Metadata,
};

fn stable(owner: *const owner_module.Owner) !void {
    if (!owner.ready or owner.closed or owner.store.safetyGate() != .open or owner.decision_journal.last_sequence != owner.shard.authoritativeBarrier()) return error.CoreRecoveryIncomplete;
    if (owner.shard.deployment.sealed) {
        const anchor = owner.deployment_anchor orelse return error.DeploymentAnchorRequired;
        if (!std.mem.eql(u8, &anchor, &owner.shard.deployment.header.?.expected_digest)) return error.DeploymentDigestMismatch;
    }
}

fn latestUtc(owner: *const owner_module.Owner) !u64 {
    var reader = try trading.journal.Reader.init(owner.decision_journal.bytes());
    var now: ?u64 = null;
    while (true) switch (try reader.next()) {
        .record => |record| if (record.flags & trading.journal.input_flag != 0 and record.time_presence.wall) {
            now = @max(now orelse 0, record.wall_time);
        },
        .end => break,
    };
    if (now) |value| return value;
    // A rotated journal can be empty; committed account cursors retain UTC
    // evidence, never a machine-local monotonic timestamp from another boot.
    if (owner.shard.reconciliation_cursor) |cursor| now = cursor.through_utc_ns;
    for (owner.shard.secondary_accounts[0..owner.shard.secondary_account_count]) |account| {
        if (account.state.reconciliation_cursor) |cursor| now = @max(now orelse 0, cursor.through_utc_ns);
    }
    return now orelse error.RecoveryClockUnavailable;
}

fn verifyAccount(owner: *const owner_module.Owner, account: u128, fence: u64, next_intent: u64, strategy: u128) !void {
    const state = owner.shard.accountState(account) orelse return error.UnknownRecoveryAccount;
    const cursor = state.reconciliation_cursor orelse return error.AccountRecoveryIncomplete;
    const archive = state.reconciliation_archive orelse return error.AccountRecoveryIncomplete;
    if (archive.receipt.root.barrier < fence or state.pending_reconciliation_window != null or
        state.reconciliation_completed_fact < state.reconciliation_started_fact or state.open_economic_fact_count != 0 or
        state.open_economic_unknown_time_count != 0 or state.economic_fault_count != 0 or owner.shard.oms.recovery_only or
        state.economic_projection.reconciliation_break or state.economic_projection.suspense_usdt_atoms != 0 or
        state.economic_projection.suspense_native_asset_count != 0 or std.mem.allEqual(u8, &cursor.root_digest, 0))
        return error.AccountRecoveryIncomplete;
    try state.economic_projection.assertClosed();
    for (owner.shard.oms.orders[0..owner.shard.oms.order_count]) |order| if (order.exchange_account == account and order.state == .unknown) return error.UnresolvedRecoveryOrder;
    for (owner.shard.oms.intent_history[0..owner.shard.oms.intent_history_count]) |intent| if (intent.strategy_instance == strategy and intent.intent_sequence >= next_intent) return error.IntentSequenceRegression;
}

fn verifyArchivedSequence(owner: *const owner_module.Owner, root: history.Root, strategy: u128, next: u64) !void {
    const request: history.LookupRequest = .{
        .pending_id = 1,
        .key = .{ .origin = root.origin, .identity = .{ .intent = .{ .strategy = strategy, .sequence = next } } },
        .candidate_payload_digest = @splat(0),
        .original_input_digest = history.hash("strategy recovery sequence boundary"),
        .root_digest = root.root_digest,
        .epoch = root.epoch,
        .barrier = root.barrier,
    };
    const result = try owner.store.queryOrderHistory(owner.io, request);
    try history.verifyFreshIntentSequence(request, &result.proof, root);
}

test "09b cold sequence boundary covers multiple leaves and proof failures" {
    const durable = @import("../persistence/durable_store.zig");
    const memory = try std.testing.allocator.create(durable.MemoryAdapter);
    defer std.testing.allocator.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 972 }, .account = 20 };
    var entries: [61]history.Entry = undefined;
    for (&entries, 0..) |*entry, index| entry.* = .{ .key = .{ .origin = origin, .identity = .{ .intent = .{ .strategy = if (index == 60) 10 else 9, .sequence = if (index == 60) 1 else 2 * index } } }, .record_index = 0 };
    const records = [_]history.Record{.{ .bytes = "authenticated archived intent", .payload_digest = history.hash("authenticated archived intent") }};
    const receipt = try memory.interface().publishOrderHistory(undefined, .{ .origin = origin, .barrier = 1, .epoch = 1, .qualification_digest = history.hash("archived sequence boundary"), .entries = &entries, .records = &records });
    for ([_]u64{ 93, 94, 119 }) |sequence| {
        const request: history.LookupRequest = .{ .pending_id = 1, .key = .{ .origin = origin, .identity = .{ .intent = .{ .strategy = 9, .sequence = sequence } } }, .candidate_payload_digest = @splat(0), .original_input_digest = history.hash("recover"), .root_digest = receipt.root.root_digest, .epoch = 1, .barrier = 1 };
        const result = try memory.interface().queryOrderHistory(undefined, request);
        try std.testing.expect(result.proof.path_len > 0);
        if (sequence < 119) {
            try std.testing.expectError(error.IntentSequenceRegression, history.verifyFreshIntentSequence(request, &result.proof, receipt.root));
        } else try history.verifyFreshIntentSequence(request, &result.proof, receipt.root);
        var corrupted = result.proof;
        corrupted.path[0].item.digest[0] ^= 1;
        try std.testing.expectError(error.InvalidHistoryProof, history.verifyFreshIntentSequence(request, &corrupted, receipt.root));
    }
}

fn verifyIssued(owner: *const owner_module.Owner, strategy: u128, record: @import("../trading/cycle_occupancy.zig").Record, binding: Binding, state: std.json.Value) !void {
    const issued = try field(state, "issued");
    if (issued != .array or issued.array.items.len > 256) return error.InvalidCycleCheckpoint;
    for (issued.array.items) |intent| {
        const sequence = try unsigned(try field(intent, "sequence"));
        const index = try unsigned(try field(intent, "leg"));
        if (index >= record.count) return error.CycleOwnershipMismatch;
        const leg = binding.legs[index];
        if (leg.account != record.members[index].account or leg.instrument != record.members[index].instrument) return error.CycleOwnershipMismatch;
        const reducing = try field(intent, "reducing");
        if (reducing != .bool) return error.InvalidCycleCheckpoint;
        const timing = if (intent.object.get("time_in_force")) |value| try string(value) else "ioc";
        const tif: trading.canonical.TimeInForce = if (std.mem.eql(u8, timing, "ioc")) .immediate_or_cancel else if (std.mem.eql(u8, timing, "post-only")) .post_only else return error.InvalidCycleCheckpoint;
        const direction: trading.oms.Side = if (reducing.bool) (if (leg.direction == .buy) .sell else .buy) else leg.direction;
        var found = false;
        for (owner.shard.oms.command_history[0..owner.shard.oms.command_history_count]) |command| {
            if (command.strategy_instance != strategy or command.intent_sequence != sequence or command.operation != .place) continue;
            const order = owner.shard.oms.orderById(command.order_id) orelse return error.UnresolvedPrivateIntent;
            if (command.authority.cycle.identity != record.first_sequence or order.exchange_account != leg.account or
                command.portfolio != record.portfolio or command.instrument != leg.instrument or command.side != direction or
                command.quantity != try unsigned(try field(intent, "lots")) or command.limit_price.ticks != try unsigned(try field(intent, "limit_ticks")) or
                command.limit_price.rules_version != leg.rules_version or command.portfolio_reduce_only != reducing.bool or command.time_in_force != tif)
                return error.PrivateIntentMismatch;
            found = true;
        }
        if (!found) return error.UnresolvedPrivateIntent;
    }
}

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidCycleCheckpoint;
    return value.object.get(name) orelse error.InvalidCycleCheckpoint;
}
fn string(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidCycleCheckpoint;
    return value.string;
}
fn unsigned(value: std.json.Value) !u64 {
    if (value != .number_string) return error.InvalidCycleCheckpoint;
    return std.fmt.parseInt(u64, value.number_string, 10) catch error.InvalidCycleCheckpoint;
}

fn optional(value: std.json.Value) !std.json.Value {
    const tag = try string(try field(value, "tag"));
    if (std.mem.eql(u8, tag, "none") and value.object.count() == 1) return .null;
    if (std.mem.eql(u8, tag, "present") and value.object.count() == 2) return field(value, "value");
    return error.InvalidCycleCheckpoint;
}

test "09b recovery requires withdrawn opening authority and every committed account root" {
    try std.testing.expect(@typeInfo(Recovery) == .@"opaque");
    try exerciseCoreRecovery(null);
}

test "09b activation append and commit failures never publish Host authority" {
    try exerciseCoreRecovery(.append);
    try exerciseCoreRecovery(.commit);
}

fn exerciseCoreRecovery(fault: ?@import("../persistence/durable_store.zig").FaultPoint) !void {
    const durable = @import("../persistence/durable_store.zig");
    const fixture = @import("../testing/support/trading_shard_fixture.zig");
    const multi = @import("../testing/acceptance/core/multi_account_authority_acceptance.zig");
    const gpa = std.testing.allocator;
    const memory = try gpa.create(durable.MemoryAdapter);
    defer gpa.destroy(memory);
    memory.* = .init();
    defer memory.deinit();
    const owner = try gpa.create(owner_module.Owner);
    defer gpa.destroy(owner);
    try owner_module.Owner.bootstrapInto(owner, memory.interface(), undefined, .{ .domain = .decision_log, .id = 91 });
    try multi.initializePythonOwner(owner);
    const session: @import("../strategy/strategy_host_ipc.zig").Session = .{ .fencing = owner.shard.fencing_token, .shard = 0, .generation = 2 };
    try std.testing.expectError(error.CoreRecoveryIncomplete, Recovery.begin(gpa, owner, 9, session));
    _ = try owner.apply(fixture.atGroup(45, .{ .identity = 2000, .payload = .{ .control_command = .{
        .command_identity = 2000,
        .content_hash = 2000,
        .target_identity = owner.shard.operational_state.target_identity,
        .expected_version = owner.shard.operational_state.version,
        .expires_at = std.math.maxInt(u64),
        .kind = .trading_pause,
    } } }));
    const recovered = try Recovery.begin(gpa, owner, 9, session);
    defer recovered.deinit();
    var metadata: codec.Metadata = .{
        .schema_registry = 0x0102030405060708090a0b0c0d0e0f10,
        .strategy_instance = 9,
        .strategy_definition = 2,
        .state_schema = 0x43565354415445000000000000000001,
        .state_schema_version = 2,
        .strategy_config_version = 1,
        .strategy_cursor = owner.shard.authoritativeBarrier(),
        .next_intent_sequence = 1,
    };
    var storage: [8192]u8 = undefined;
    const container = try codec.encodePayloadCheckpoint(&storage, metadata, @embedFile("../testing/fixtures/arbitrage_host_state_v2.json"));
    try std.testing.expectError(error.InvalidRecoveryQualification, recovered.qualify(gpa, owner, container, metadata, &.{}, .unverified));
    try std.testing.expectError(error.AccountRecoveryIncomplete, recovered.qualify(gpa, owner, container, metadata, &.{}, .utc));
    try std.testing.expectError(error.RecoveryNotQualified, recovered.activate(owner));
    const execution = @import("../execution/execution_gateway.zig");
    const gateway = try gpa.create(execution.Gateway);
    defer gpa.destroy(gateway);
    gateway.init();
    try gateway.bootstrapDurableDispatch(memory.interface(), undefined, .{ .domain = .control, .id = 92 });
    try multi.reconcileDomainAccount(owner, 20, gateway);
    metadata.strategy_cursor = owner.shard.authoritativeBarrier();
    var updated_storage: [8192]u8 = undefined;
    const one_root = try codec.encodePayloadCheckpoint(&updated_storage, metadata, @embedFile("../testing/fixtures/arbitrage_host_state_v2.json"));
    try std.testing.expectError(error.AccountRecoveryIncomplete, recovered.qualify(gpa, owner, one_root, metadata, &.{}, .utc));
    try multi.reconcileDomainAccount(owner, 30, gateway);
    metadata.strategy_cursor = owner.shard.authoritativeBarrier();
    const both_roots = try codec.encodePayloadCheckpoint(&updated_storage, metadata, @embedFile("../testing/fixtures/arbitrage_host_state_v2.json"));
    _ = try recovered.qualify(gpa, owner, both_roots, metadata, &.{}, .utc);
    _ = try owner.apply(fixture.atGroup(61, .{ .identity = 2001, .account_scope = 20, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } }));
    try std.testing.expectError(error.StaleRecoveryQualification, recovered.activate(owner));
    metadata.strategy_cursor = owner.shard.authoritativeBarrier();
    const refreshed = try codec.encodePayloadCheckpoint(&updated_storage, metadata, @embedFile("../testing/fixtures/arbitrage_host_state_v2.json"));
    const ticket = try recovered.qualify(gpa, owner, refreshed, metadata, &.{}, .utc);
    if (fault) |point| {
        const digest = owner.shard.canonicalStateDigest();
        memory.injectFaultAt(.eio, point);
        if (recovered.activate(owner)) |_| return error.ActivationSurvivedStoreFailure else |err| {
            try std.testing.expect(err == error.InputOutput or err == error.DecisionLogUnavailable);
        }
        try std.testing.expectEqualSlices(u8, &digest, &owner.shard.canonicalStateDigest());
        try std.testing.expectEqual(@as(u128, 0), owner.shard.strategyAuthority(9).host_activation_identity);
        try std.testing.expectError(error.CoreRecoveryIncomplete, recovered.activate(owner));
        return;
    }
    const activation = try recovered.activate(owner);
    const applied = try owner.shard.appliedHostActivationForStrategy(&owner.decision_journal, 9);
    try std.testing.expectEqual(ticket.core_barrier + 1, activation.barrier);
    try std.testing.expectEqual(applied.authorization.activation_identity, activation.activation_identity);
    try std.testing.expect(!owner.shard.operational_state.trading_authorized);
    try std.testing.expectError(error.StaleRecoveryQualification, recovered.activate(owner));
    _ = try owner.apply(fixture.atGroup(63, .{ .identity = 2002, .account_scope = 20, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } }));
    _ = try recovered.currentUtc(owner);
    _ = try owner.apply(fixture.atGroup(62, .{ .identity = 2003, .account_scope = 20, .payload = .{ .mark_price = .{ .instrument = 101, .price_atoms = 100 } } }));
    try std.testing.expectError(error.RecoveryClockUnavailable, recovered.currentUtc(owner));
}
