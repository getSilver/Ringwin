const std = @import("std");
const ipc = @import("strategy_host_ipc.zig");
const trading = @import("../trading/trading_shard.zig");
const depth_snapshot = @import("../market/depth_snapshot.zig");
const market_projection = @import("../market/market_projection.zig");
const journal = @import("../persistence/journal.zig");

const Crc32c = std.hash.crc.Crc32Iscsi;
const batch_header_len: usize = 128;
const event_header_len: usize = 64;
const output_header_len: usize = 128;
const order_intent_len: usize = 80;
const versioned_order_intent_len = order_intent_len + @sizeOf(u64) + @sizeOf(i128);

fn validMemberLength(len: usize) bool {
    return len == order_intent_len or len == versioned_order_intent_len;
}

pub const ExactLimitPrice = struct {
    ticks: i64,
    rules_version: u64,
    tick_coefficient: i128,

    // The coefficient represents one venue tick in decimal price units.
    pub const tick_scale = 18;
};

fn memberExactPrice(payload: []const u8) !?ExactLimitPrice {
    switch (get(u16, payload, 0)) {
        1 => if (payload.len == order_intent_len) return null,
        2 => if (payload.len == versioned_order_intent_len) {
            const version = get(u64, payload, order_intent_len);
            if (version != 0) return .{
                .ticks = get(i64, payload, 72),
                .rules_version = version,
                .tick_coefficient = get(i128, payload, order_intent_len + @sizeOf(u64)),
            };
        },
        else => {},
    }
    return error.Malformed;
}
const max_events: usize = 64;
const max_seen_intents: usize = 64;
const stale_intent_ns: i64 = 100_000_000;
const batch_magic = "QSHB".*;
const output_magic = "QSHO".*;

pub const EventType = enum(u16) {
    mark_price = 1,
    l2_snapshot = 2,
    l2_delta = 3,
    timer = 4,
    account = 5,
    fill = 6,
    depth_snapshot = 7,
    market_trade = 8,
    cycle_projection = 9,
};

pub const OrderQuery = struct {
    strategy: u128,
    first_sequence: u64,
    intent_sequence: u64,
    cursor: u64,
};

pub const MakerRoute = struct {
    first_sequence: u64,
    peer: @import("../trading/cycle_occupancy.zig").Member,
};

pub const EventEnvelope = struct {
    event_type: EventType,
    time_presence: u32 = 0x1f,
    shard_sequence: u64,
    source_time_ns: i64,
    receive_time_ns: i64,
    monotonic_time_ns: i64,
    wall_time_utc_ns: i64,
    payload: []const u8,
};

pub const Subscription = struct {
    strategy_identity: u128,
    event_mask: u64,

    pub fn of(strategy_identity: u128, event_types: []const EventType) Subscription {
        var mask: u64 = 0;
        for (event_types) |event_type| mask |= eventBit(event_type);
        return .{ .strategy_identity = strategy_identity, .event_mask = mask };
    }
};

pub const Authorization = struct {
    strategy_identity: u128,
    config_version: u64,
    activation_identity: u128,
    activation_barrier: u64,
};
pub const AppliedActivation = struct {
    authorization: Authorization,
    session: ipc.Session,
    fact_sequence: u64,
    state_digest: [32]u8,
};

pub const Config = struct {
    schema_registry: u128,
    decision_domain: u128,
    session: ipc.Session,
    authorization: Authorization,
};

pub const Side = enum(u8) { buy = 1, sell = 2 };
pub const OrderType = enum(u8) { limit = 1, post_only = 2 };
pub const TimeInForce = enum(u8) { good_til_canceled = 1, immediate_or_cancel = 2, post_only = 3 };

pub const OutputOrder = struct {
    portfolio_identity: u128 = 1,
    exchange_account_identity: u128 = 2,
    instrument_identity: u128 = 3,
    side: Side = .buy,
    order_type: OrderType = .limit,
    time_in_force: TimeInForce = .good_til_canceled,
    portfolio_reduce_only: bool = false,
    quantity: i64,
    limit_price_micros: i64 = 0,
    exact_limit_price: ?ExactLimitPrice = null,
};

pub const OrderIntent = struct {
    strategy_identity: u128,
    intent_sequence: u64,
    strategy_cursor: u64,
    config_version: u64,
    activation_identity: u128,
    portfolio_identity: u128,
    exchange_account_identity: u128,
    instrument_identity: u128,
    side: Side,
    order_type: OrderType,
    time_in_force: TimeInForce,
    portfolio_reduce_only: bool,
    quantity: i64,
    limit_price_micros: i64 = 0,
    exact_limit_price: ?ExactLimitPrice = null,

    pub fn originalPrice(self: OrderIntent) @import("../model/canonical_event.zig").InstrumentPrice {
        // The legacy value remains raw so deduplication binds the original request.
        const exact = self.exact_limit_price orelse return .{
            .instrument = self.instrument_identity,
            .rules_version = 0,
            .ticks = self.limit_price_micros,
        };
        return .{ .instrument = self.instrument_identity, .rules_version = exact.rules_version, .ticks = exact.ticks };
    }
};

pub const RejectReason = enum(u16) {
    old_session,
    unknown_schema,
    invalid_cursor,
    stale,
    unauthorized,
    duplicate_identity,
    conflicting_identity,
    malformed,
};

pub const Rejection = struct {
    reason: RejectReason,
    strategy_identity: u128,
    intent_sequence: u64,
    group: ?GroupCandidate = null,
};

pub const Decision = union(enum) {
    accepted: OrderIntent,
    accepted_group: GroupCandidate,
    rejected: Rejection,

    pub fn corePayload(self: Decision) trading.CorePayload {
        return switch (self) {
            .accepted => |intent| .{ .external_order_intent = intent },
            .accepted_group => |candidate| .{ .external_intent_group = candidate },
            .rejected => |rejection| if (rejection.group) |candidate| .{ .external_intent_group = candidate } else .{ .strategy_intent_rejected = rejection },
        };
    }
};

pub const max_group_members = 4;
// Keep the persisted candidate capacity. A versioned group fits up to three members.
pub const max_group_frame_len = output_header_len + max_group_members * order_intent_len;

/// Owned, bounded bytes. The original envelope is journaled with the candidate;
/// no member is independently admitted and no Python-supplied command exists.
pub const GroupCandidate = struct {
    len: u16,
    bytes: [max_group_frame_len]u8 = @splat(0),
    rejection: ?RejectReason = null,

    pub fn isCycleCancel(self: *const GroupCandidate) bool {
        return self.len <= self.bytes.len and Gateway.isOrderCancel(self.frame());
    }

    pub fn frame(self: *const GroupCandidate) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const IntentGroup = struct {
    session: ipc.Session,
    business_digest: [32]u8,
    count: u8,
    maker_route: ?MakerRoute = null,
    members: [max_group_members]OrderIntent = undefined,
};

pub fn decodeIntentGroup(frame: []const u8) !IntentGroup {
    if (frame.len < output_header_len or frame.len > max_group_frame_len or
        !std.mem.eql(u8, frame[0..4], &output_magic) or
        get(u16, frame, 4) != 1 or get(u16, frame, 6) != output_header_len or
        get(u32, frame, 8) != 0 or get(u32, frame, 12) != frame.len or
        get(u32, frame, 44) != 0 or get(u16, frame, 96) != 1 or
        wireCrc(frame) != get(u32, frame, 124)) return error.Malformed;
    const count = get(u32, frame, 100);
    const schema = get(u16, frame, 98);
    const route_len: usize = if (schema == 5) 40 else 0;
    switch (schema) {
        1 => if (count != 1 or frame.len != output_header_len + versioned_order_intent_len) return error.Malformed,
        2 => if (count < 2 or count > max_group_members) return error.Malformed,
        5 => if (count != 1 or frame.len != output_header_len + versioned_order_intent_len + route_len) return error.Malformed,
        else => return error.Malformed,
    }
    const member_len = (frame.len - output_header_len - route_len) / count;
    if (!validMemberLength(member_len) or
        get(u32, frame, 104) != count * member_len + route_len or
        frame.len != output_header_len + count * member_len + route_len or
        get(u64, frame, 56) == 0 or get(u128, frame, 64) == 0) return error.Malformed;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("HostIntentGroupBusinessV1\x00");
    hasher.update(frame[64..80]); // StrategyInstanceIdentity
    hasher.update(frame[88..96]); // immutable strategy configuration
    hasher.update(frame[128..]); // complete ordered member content
    var group: IntentGroup = .{
        .session = .{ .fencing = get(u64, frame, 32), .shard = get(u32, frame, 40), .generation = get(u64, frame, 48) },
        .business_digest = undefined,
        .count = @intCast(count),
    };
    hasher.final(&group.business_digest);
    const first = get(u64, frame, 136);
    if (first == 0) return error.Malformed;
    for (group.members[0..count], 0..) |*member, index| {
        const payload = frame[output_header_len + index * member_len ..][0..member_len];
        if (payload[5] > 1 or get(u16, payload, 6) != 0 or
            get(u64, payload, 8) != (std.math.add(u64, first, index) catch return error.Malformed) or
            get(u128, payload, 16) == 0 or get(u128, payload, 32) == 0 or get(u128, payload, 48) == 0 or
            get(i64, payload, 64) <= 0 or get(i64, payload, 72) <= 0) return error.Malformed;
        member.* = .{
            .strategy_identity = get(u128, frame, 64),
            .intent_sequence = get(u64, payload, 8),
            .strategy_cursor = get(u64, frame, 80),
            .config_version = get(u64, frame, 88),
            .activation_identity = get(u128, frame, 108),
            .portfolio_identity = get(u128, payload, 16),
            .exchange_account_identity = get(u128, payload, 32),
            .instrument_identity = get(u128, payload, 48),
            .side = std.enums.fromInt(Side, payload[2]) orelse return error.Malformed,
            .order_type = std.enums.fromInt(OrderType, payload[3]) orelse return error.Malformed,
            .time_in_force = std.enums.fromInt(TimeInForce, payload[4]) orelse return error.Malformed,
            .portfolio_reduce_only = payload[5] == 1,
            .quantity = get(i64, payload, 64),
            .limit_price_micros = if (payload.len == order_intent_len) get(i64, payload, 72) else 0,
            .exact_limit_price = try memberExactPrice(payload),
        };
    }
    if (schema == 5) {
        const offset = output_header_len + member_len;
        const first_sequence = get(u64, frame, offset);
        const peer: @FieldType(MakerRoute, "peer") = .{ .account = get(u128, frame, offset + 8), .instrument = get(u128, frame, offset + 24) };
        const member = group.members[0];
        if (first_sequence == 0 or first_sequence > first or member.portfolio_reduce_only or
            peer.account == 0 or peer.instrument == 0 or peer.account == member.exchange_account_identity or
            peer.instrument == member.instrument_identity) return error.Malformed;
        group.maker_route = .{ .first_sequence = first_sequence, .peer = peer };
    }
    return group;
}

const PublishedBatch = struct {
    sequence: u64,
    last_shard_sequence: u64,
    published_monotonic_ns: i64,
};

const SeenIntent = struct {
    strategy_identity: u128,
    intent_sequence: u64,
    payload_crc: u32,
};

pub const Gateway = struct {
    config: Config,
    subscription_mask: u64,
    trading_enabled: bool = false,
    activation_floor: u128 = 0,
    authority_shard: ?*trading.TradingShard = null,
    authority_journal: ?*journal.Journal = null,
    activation_sequence: u64 = 0,
    published: [max_events]PublishedBatch = undefined,
    published_count: usize = 0,
    seen: [max_seen_intents]SeenIntent = undefined,
    seen_count: usize = 0,

    pub fn init(config: Config, subscriptions: []const Subscription) !Gateway {
        var mask: u64 = 0;
        for (subscriptions) |subscription| {
            if (subscription.strategy_identity == 0) return error.InvalidSubscription;
            mask |= subscription.event_mask;
        }
        if (mask == 0) return error.EmptySubscription;
        return .{ .config = config, .subscription_mask = mask };
    }

    pub fn beginRecovery(self: *Gateway) void {
        if (self.trading_enabled)
            self.activation_floor = @max(self.activation_floor, self.config.authorization.activation_identity);
        self.trading_enabled = false;
        self.activation_sequence = 0;
    }

    pub fn beginSession(self: *Gateway, config: Config, shard: *trading.TradingShard, stable_journal: *journal.Journal) !void {
        if (config.authorization.strategy_identity !=
            self.config.authorization.strategy_identity or
            config.authorization.config_version != self.config.authorization.config_version or
            config.authorization.activation_identity == 0 or
            config.session.generation == 0 or
            std.meta.eql(config.session, self.config.session))
            return error.InvalidSessionTransition;
        if (self.trading_enabled)
            self.activation_floor = @max(self.activation_floor, self.config.authorization.activation_identity);
        self.trading_enabled = false;
        if (stable_journal.last_sequence != shard.authoritativeBarrier() or
            shard.strategyAuthority(self.config.authorization.strategy_identity).strategy_identity != self.config.authorization.strategy_identity)
            return error.UnstableHostAuthority;
        if (shard.strategyAuthority(self.config.authorization.strategy_identity).host_activation_identity != 0 and
            config.authorization.activation_identity == shard.strategyAuthority(self.config.authorization.strategy_identity).host_activation_identity)
            return error.StaleHostActivation;
        if (shard.hasHostAuthorityForSession(self.config.session)) {
            self.activation_floor = @max(self.activation_floor, shard.strategyAuthority(self.config.authorization.strategy_identity).host_activation_identity);
            const fact_identity = try std.math.add(u64, stable_journal.last_sequence, 1);
            _ = try trading.applyStable(shard, stable_journal, .{ .core = .{
                .identity = fact_identity,
                .payload = .{ .host_activation_revoked = .{
                    .strategy_identity = shard.strategyAuthority(self.config.authorization.strategy_identity).strategy_identity,
                    .activation_identity = shard.strategyAuthority(self.config.authorization.strategy_identity).host_activation_identity,
                    .reason = .session_replaced,
                    .session = self.config.session,
                } },
            } });
        }
        self.config = config;
        self.published_count = 0;
        self.authority_shard = null;
        self.authority_journal = null;
        self.activation_sequence = 0;
    }

    pub fn activate(self: *Gateway, shard: *trading.TradingShard, stable_journal: *journal.Journal) !void {
        const applied = try shard.appliedHostActivationForStrategy(stable_journal, self.config.authorization.strategy_identity);
        const authorization = applied.authorization;
        if (authorization.strategy_identity == 0 or authorization.activation_identity == 0 or
            applied.session.generation == 0 or self.config.session.generation == 0 or
            authorization.activation_identity <= self.activation_floor)
            return error.InvalidAuthorization;
        if (authorization.strategy_identity != self.config.authorization.strategy_identity or
            authorization.config_version != self.config.authorization.config_version or
            authorization.activation_identity != self.config.authorization.activation_identity or
            authorization.activation_barrier != self.config.authorization.activation_barrier or
            !std.meta.eql(applied.session, self.config.session) or
            applied.fact_sequence == 0 or std.mem.allEqual(u8, &applied.state_digest, 0))
            return error.InvalidAuthorization;
        if (self.published_count == 0 or
            self.published[self.published_count - 1].last_shard_sequence < applied.fact_sequence or
            self.published[self.published_count - 1].last_shard_sequence < authorization.activation_barrier)
            return error.ActivationBarrierNotApplied;
        self.config.authorization = authorization;
        self.authority_shard = shard;
        self.authority_journal = stable_journal;
        self.activation_sequence = applied.fact_sequence;
        self.trading_enabled = true;
    }

    pub fn encodeBatch(
        self: *Gateway,
        destination: []u8,
        batch_sequence: u64,
        first_shard_sequence: u64,
        last_shard_sequence: u64,
        published_monotonic_ns: i64,
        events: []const EventEnvelope,
    ) ![]u8 {
        if (batch_sequence == 0 or first_shard_sequence > last_shard_sequence or
            events.len > max_events)
            return error.InvalidBatch;
        if ((self.published_count == 0 and batch_sequence != 1) or
            (self.published_count != 0 and
                (self.published[self.published_count - 1].sequence == std.math.maxInt(u64) or
                    batch_sequence != self.published[self.published_count - 1].sequence + 1 or
                    self.published[self.published_count - 1].last_shard_sequence ==
                        std.math.maxInt(u64) or
                    first_shard_sequence !=
                        self.published[self.published_count - 1].last_shard_sequence + 1)))
            return error.InvalidBatchSequence;
        var offset: usize = batch_header_len;
        var included: u32 = 0;
        var previous_sequence: ?u64 = null;
        for (events) |event| {
            if (event.shard_sequence < first_shard_sequence or
                event.shard_sequence > last_shard_sequence or
                (previous_sequence != null and event.shard_sequence <= previous_sequence.?))
                return error.InvalidBatch;
            previous_sequence = event.shard_sequence;
            if (self.subscription_mask & eventBit(event.event_type) == 0) continue;
            if (event.event_type == .market_trade) _ = try @import("../market/market_trade.zig").decode(event.payload);
            if (event.event_type == .depth_snapshot) _ = try depth_snapshot.decode(event.payload);
            const record_len = std.mem.alignForward(usize, event_header_len + event.payload.len, 8);
            if (destination.len -| offset < record_len) return error.BatchTooLarge;
            const record = destination[offset..][0..record_len];
            @memset(record, 0);
            put(u32, record, 0, @intCast(record_len));
            put(u32, record, 4, @intCast(event.payload.len));
            put(u16, record, 8, @intFromEnum(event.event_type));
            put(u16, record, 10, 1);
            put(u32, record, 12, event.time_presence);
            put(u64, record, 16, event.shard_sequence);
            put(i64, record, 24, event.source_time_ns);
            put(i64, record, 32, event.receive_time_ns);
            put(i64, record, 40, event.monotonic_time_ns);
            put(i64, record, 48, event.wall_time_utc_ns);
            @memcpy(record[event_header_len..][0..event.payload.len], event.payload);
            offset += record_len;
            included += 1;
        }
        const frame = destination[0..offset];
        @memset(frame[0..batch_header_len], 0);
        @memcpy(frame[0..4], &batch_magic);
        put(u16, frame, 4, 1);
        put(u16, frame, 6, batch_header_len);
        put(u32, frame, 12, @intCast(frame.len));
        put(u128, frame, 16, self.config.schema_registry);
        put(u128, frame, 32, self.config.decision_domain);
        put(u64, frame, 48, self.config.session.fencing);
        put(u32, frame, 56, self.config.session.shard);
        put(u64, frame, 64, self.config.session.generation);
        put(u64, frame, 72, batch_sequence);
        put(u64, frame, 80, first_shard_sequence);
        put(u64, frame, 88, last_shard_sequence);
        put(i64, frame, 96, published_monotonic_ns);
        put(u32, frame, 104, included);
        put(u32, frame, 108, @intCast(frame.len - batch_header_len));
        put(u32, frame, 124, wireCrc(frame));

        return frame;
    }

    pub fn recordPublished(
        self: *Gateway,
        sequence: u64,
        last_shard_sequence: u64,
        published_monotonic_ns: i64,
    ) !void {
        if (self.published_count == self.published.len or sequence == 0 or
            (self.published_count != 0 and
                (self.published[self.published_count - 1].sequence == std.math.maxInt(u64) or
                    sequence != self.published[self.published_count - 1].sequence + 1)))
            return error.InvalidPublishedBatch;
        self.published[self.published_count] = .{
            .sequence = sequence,
            .last_shard_sequence = last_shard_sequence,
            .published_monotonic_ns = published_monotonic_ns,
        };
        self.published_count += 1;
    }

    /// A synchronous consumer has drained earlier outputs and needs only the
    /// latest publication to validate continuity of the next batch.
    pub fn retainLatestPublication(self: *Gateway) void {
        if (self.published_count == 0) return;
        self.published[0] = self.published[self.published_count - 1];
        self.published_count = 1;
    }

    pub fn ingest(self: *Gateway, frame: []const u8, now_ns: i64) Decision {
        if (self.trading_enabled and (self.authority_shard == null or self.authority_journal == null or
            self.authority_shard.?.strategyAuthority(self.config.authorization.strategy_identity).host_activation_identity != self.config.authorization.activation_identity or
            self.authority_shard.?.strategyAuthority(self.config.authorization.strategy_identity).host_activation_fact_sequence != self.activation_sequence or
            self.authority_journal.?.last_sequence != self.authority_shard.?.authoritativeBarrier()))
            self.beginRecovery();
        if (frame.len >= output_header_len) {
            const schema = get(u16, frame, 98);
            const domain_single = schema == 1 and frame.len == output_header_len + versioned_order_intent_len and
                (if (self.authority_shard) |shard| shard.decision_domain_identity != 0 else false);
            if (schema == 2 or schema == 5 or domain_single) return self.ingestGroup(frame, now_ns);
        }
        const identity = if (frame.len >= output_header_len)
            get(u128, frame, 64)
        else
            0;
        const parsed = self.parse(frame, now_ns) catch |err| return .{ .rejected = .{
            .reason = reasonForError(err),
            .strategy_identity = identity,
            .intent_sequence = payloadIntentSequence(frame),
        } };

        for (self.seen[0..self.seen_count]) |seen| {
            if (seen.strategy_identity == parsed.strategy_identity and
                seen.intent_sequence == parsed.intent_sequence)
                return .{ .rejected = .{
                    .reason = if (seen.payload_crc == Crc32c.hash(frame[128..]))
                        .duplicate_identity
                    else
                        .conflicting_identity,
                    .strategy_identity = parsed.strategy_identity,
                    .intent_sequence = parsed.intent_sequence,
                } };
        }
        if (self.seen_count == self.seen.len) return .{ .rejected = .{
            .reason = .malformed,
            .strategy_identity = parsed.strategy_identity,
            .intent_sequence = parsed.intent_sequence,
        } };
        self.seen[self.seen_count] = .{
            .strategy_identity = parsed.strategy_identity,
            .intent_sequence = parsed.intent_sequence,
            .payload_crc = Crc32c.hash(frame[128..]),
        };
        self.seen_count += 1;
        return .{ .accepted = parsed };
    }

    fn ingestGroup(self: *Gateway, frame: []const u8, now_ns: i64) Decision {
        const group = decodeIntentGroup(frame) catch return .{ .rejected = .{ .reason = .malformed, .strategy_identity = get(u128, frame, 64), .intent_sequence = payloadIntentSequence(frame) } };
        var candidate: GroupCandidate = .{ .len = @intCast(frame.len) };
        @memcpy(candidate.bytes[0..frame.len], frame);
        // Reuse the established single-intent envelope validation, including
        // activation, published cursor and freshness, without touching its cache.
        var buffer: [output_header_len + versioned_order_intent_len]u8 = undefined;
        const member_len = if (group.maker_route != null) versioned_order_intent_len else (frame.len - output_header_len) / group.count;
        const single = buffer[0 .. output_header_len + member_len];
        @memcpy(single, frame[0..single.len]);
        put(u32, single, 12, @intCast(single.len));
        put(u16, single, 98, 1);
        put(u32, single, 100, 1);
        put(u32, single, 104, @intCast(member_len));
        put(u32, single, 124, wireCrc(single));
        _ = self.parse(single, now_ns) catch |err| {
            const reason = reasonForError(err);
            // Only an authorized, structurally complete business identity may
            // be consumed. Persist stale/cursor rejection with all members.
            if (reason == .stale or reason == .invalid_cursor) candidate.rejection = reason;
            return .{ .rejected = .{ .reason = reason, .strategy_identity = group.members[0].strategy_identity, .intent_sequence = group.members[0].intent_sequence, .group = if (candidate.rejection != null) candidate else null } };
        };
        return .{ .accepted_group = candidate };
    }

    fn parse(self: Gateway, frame: []const u8, now_ns: i64) !OrderIntent {
        if (frame.len < output_header_len or !validMemberLength(frame.len - output_header_len) or
            !std.mem.eql(u8, frame[0..4], &output_magic) or
            get(u16, frame, 4) != 1 or get(u16, frame, 6) != output_header_len or
            get(u32, frame, 8) != 0 or get(u32, frame, 12) != frame.len or
            get(u32, frame, 44) != 0 or get(u32, frame, 100) != 1 or
            get(u32, frame, 104) != frame.len - output_header_len or
            wireCrc(frame) != get(u32, frame, 124))
            return error.Malformed;
        if (get(u16, frame, 98) != 1) return error.UnknownSchema;
        const cursor = try self.outputCursor(frame, now_ns, false);
        const payload = frame[128..];
        if (self.authority_shard.?.strategyAuthority(self.config.authorization.strategy_identity).portfolio_identity != get(u128, payload, 16)) return error.Unauthorized;
        if (std.enums.fromInt(Side, payload[2]) == null or
            std.enums.fromInt(OrderType, payload[3]) == null or
            std.enums.fromInt(TimeInForce, payload[4]) == null or
            payload[5] > 1 or get(u16, payload, 6) != 0 or
            get(i64, payload, 64) <= 0 or get(i64, payload, 72) <= 0)
            return error.Malformed;
        return .{
            .strategy_identity = get(u128, frame, 64),
            .intent_sequence = get(u64, payload, 8),
            .strategy_cursor = cursor,
            .config_version = get(u64, frame, 88),
            .activation_identity = get(u128, frame, 108),
            .portfolio_identity = get(u128, payload, 16),
            .exchange_account_identity = get(u128, payload, 32),
            .instrument_identity = get(u128, payload, 48),
            .side = std.enums.fromInt(Side, payload[2]).?,
            .order_type = std.enums.fromInt(OrderType, payload[3]).?,
            .time_in_force = std.enums.fromInt(TimeInForce, payload[4]).?,
            .portfolio_reduce_only = payload[5] == 1,
            .quantity = get(i64, payload, 64),
            .limit_price_micros = if (payload.len == order_intent_len) get(i64, payload, 72) else 0,
            .exact_limit_price = try memberExactPrice(payload),
        };
    }

    pub fn isOrderQuery(frame: []const u8) bool {
        return frame.len >= output_header_len and get(u16, frame, 98) == 3;
    }

    pub fn isOrderCancel(frame: []const u8) bool {
        return frame.len >= output_header_len and get(u16, frame, 98) == 4;
    }

    pub fn authorizeCycleOrderReference(self: *const Gateway, frame: []const u8, now_ns: i64) !CycleOrderReference {
        const reference = try decodeCycleOrderReference(frame);
        _ = try self.outputCursor(frame, now_ns, isOrderQuery(frame));
        return reference;
    }

    fn outputCursor(self: *const Gateway, frame: []const u8, now_ns: i64, read_only: bool) !u64 {
        if (get(u64, frame, 32) != self.config.session.fencing or
            get(u32, frame, 40) != self.config.session.shard or
            get(u64, frame, 48) != self.config.session.generation)
            return error.OldSession;
        if (get(u128, frame, 16) != self.config.schema_registry or
            get(u16, frame, 96) != 1)
            return error.UnknownSchema;
        if (!self.trading_enabled or
            self.authority_shard == null or self.authority_journal == null or
            self.authority_shard.?.strategyAuthority(self.config.authorization.strategy_identity).host_activation_identity != self.config.authorization.activation_identity or
            self.authority_shard.?.strategyAuthority(self.config.authorization.strategy_identity).host_activation_fact_sequence != self.activation_sequence or
            self.authority_journal.?.last_sequence != self.authority_shard.?.authoritativeBarrier() or
            get(u128, frame, 64) != self.config.authorization.strategy_identity or
            get(u64, frame, 88) != self.config.authorization.config_version or
            get(u128, frame, 108) != self.config.authorization.activation_identity)
            return error.Unauthorized;

        const source_batch = get(u64, frame, 56);
        const batch = for (self.published[0..self.published_count]) |published| {
            if (published.sequence == source_batch) break published;
        } else return error.InvalidCursor;
        const cursor = get(u64, frame, 80);
        if (cursor != batch.last_shard_sequence or
            cursor < self.config.authorization.activation_barrier or
            cursor < self.activation_sequence or (!read_only and cursor == self.activation_sequence))
            return error.InvalidCursor;
        if (now_ns < batch.published_monotonic_ns or
            now_ns - batch.published_monotonic_ns > stale_intent_ns)
            return error.Stale;

        return cursor;
    }
};

pub const CycleOrderReference = struct {
    request: OrderQuery,
    session: ipc.Session,
    config_version: u64,
    activation: u128,
};

pub fn decodeCycleOrderReference(frame: []const u8) !CycleOrderReference {
    if (frame.len != output_header_len + 16 or (!Gateway.isOrderQuery(frame) and !Gateway.isOrderCancel(frame)) or
        !std.mem.eql(u8, frame[0..4], &output_magic) or
        get(u16, frame, 4) != 1 or get(u16, frame, 6) != output_header_len or
        get(u32, frame, 8) != 0 or get(u32, frame, 12) != frame.len or
        get(u32, frame, 44) != 0 or get(u16, frame, 96) != 1 or get(u32, frame, 100) != 1 or
        get(u32, frame, 104) != 16 or wireCrc(frame) != get(u32, frame, 124))
        return error.Malformed;
    const first = get(u64, frame, 128);
    const intent = get(u64, frame, 136);
    if (first == 0 or intent < first) return error.Malformed;
    return .{
        .request = .{ .strategy = get(u128, frame, 64), .first_sequence = first, .intent_sequence = intent, .cursor = get(u64, frame, 80) },
        .session = .{ .fencing = get(u64, frame, 32), .shard = get(u32, frame, 40), .generation = get(u64, frame, 48) },
        .config_version = get(u64, frame, 88),
        .activation = get(u128, frame, 108),
    };
}

pub fn encodeOutputFrame(
    destination: []u8,
    config: Config,
    source_batch_sequence: u64,
    strategy_cursor: u64,
    intent_sequence: u64,
    quantity: i64,
    limit_price_micros: i64,
) ![]u8 {
    return encodeOutputOrderFrame(destination, config, source_batch_sequence, strategy_cursor, intent_sequence, .{
        .quantity = quantity,
        .limit_price_micros = limit_price_micros,
    });
}

pub fn encodeOutputOrderFrame(
    destination: []u8,
    config: Config,
    source_batch_sequence: u64,
    strategy_cursor: u64,
    intent_sequence: u64,
    order: OutputOrder,
) ![]u8 {
    const exact = order.exact_limit_price;
    const member_len = if (exact == null) order_intent_len else versioned_order_intent_len;
    const total_len = output_header_len + member_len;
    if (destination.len < total_len) return error.FrameTooLarge;
    const frame = destination[0..total_len];
    @memset(frame, 0);
    @memcpy(frame[0..4], &output_magic);
    put(u16, frame, 4, 1);
    put(u16, frame, 6, output_header_len);
    put(u32, frame, 12, @intCast(total_len));
    put(u128, frame, 16, config.schema_registry);
    put(u64, frame, 32, config.session.fencing);
    put(u32, frame, 40, config.session.shard);
    put(u64, frame, 48, config.session.generation);
    put(u64, frame, 56, source_batch_sequence);
    put(u128, frame, 64, config.authorization.strategy_identity);
    put(u64, frame, 80, strategy_cursor);
    put(u64, frame, 88, config.authorization.config_version);
    put(u16, frame, 96, 1);
    put(u16, frame, 98, 1);
    put(u32, frame, 100, 1);
    put(u32, frame, 104, @intCast(member_len));
    put(u128, frame, 108, config.authorization.activation_identity);
    const payload = frame[128..];
    put(u16, payload, 0, if (exact == null) 1 else 2);
    payload[2] = @intFromEnum(order.side);
    payload[3] = @intFromEnum(order.order_type);
    payload[4] = @intFromEnum(order.time_in_force);
    payload[5] = @intFromBool(order.portfolio_reduce_only);
    put(u64, payload, 8, intent_sequence);
    put(u128, payload, 16, order.portfolio_identity);
    put(u128, payload, 32, order.exchange_account_identity);
    put(u128, payload, 48, order.instrument_identity);
    put(i64, payload, 64, order.quantity);
    if (exact) |price| {
        put(i64, payload, 72, price.ticks);
        put(u64, payload, order_intent_len, price.rules_version);
        put(i128, payload, order_intent_len + @sizeOf(u64), price.tick_coefficient);
    } else {
        put(i64, payload, 72, order.limit_price_micros);
    }
    put(u32, frame, 124, wireCrc(frame));
    return frame;
}

pub fn encodeOutputGroupFrame(destination: []u8, config: Config, source_batch: u64, cursor: u64, first_sequence: u64, orders: []const OutputOrder) ![]u8 {
    if (orders.len < 2 or orders.len > max_group_members or first_sequence == 0) return error.InvalidIntentGroup;
    const exact = orders[0].exact_limit_price != null;
    const member_len = if (exact) versioned_order_intent_len else order_intent_len;
    const len = output_header_len + orders.len * member_len;
    if (destination.len < len or len > max_group_frame_len) return error.FrameTooLarge;
    const frame = destination[0..len];
    var single: [output_header_len + versioned_order_intent_len]u8 = undefined;
    for (orders, 0..) |order, index| {
        if ((order.exact_limit_price != null) != exact) return error.InvalidIntentGroup;
        const encoded = try encodeOutputOrderFrame(&single, config, source_batch, cursor, try std.math.add(u64, first_sequence, index), order);
        if (index == 0) @memcpy(frame[0..output_header_len], encoded[0..output_header_len]);
        @memcpy(frame[output_header_len + index * member_len ..][0..member_len], encoded[output_header_len..]);
    }
    put(u32, frame, 12, @intCast(len));
    put(u16, frame, 98, 2);
    put(u32, frame, 100, @intCast(orders.len));
    put(u32, frame, 104, @intCast(len - output_header_len));
    put(u32, frame, 124, wireCrc(frame));
    return frame;
}

pub fn eventCount(batch: []const u8) !u32 {
    if (batch.len < batch_header_len or !std.mem.eql(u8, batch[0..4], &batch_magic))
        return error.InvalidBatch;
    return get(u32, batch, 104);
}

fn reasonForError(err: anyerror) RejectReason {
    return switch (err) {
        error.OldSession => .old_session,
        error.UnknownSchema => .unknown_schema,
        error.InvalidCursor => .invalid_cursor,
        error.Stale => .stale,
        error.Unauthorized => .unauthorized,
        else => .malformed,
    };
}

fn payloadIntentSequence(frame: []const u8) u64 {
    if (frame.len < output_header_len + 16) return 0;
    return get(u64, frame, 136);
}

fn eventBit(event_type: EventType) u64 {
    return @as(u64, 1) << @intCast(@intFromEnum(event_type) - 1);
}

fn wireCrc(bytes: []const u8) u32 {
    var crc = Crc32c.init();
    crc.update(bytes[0..124]);
    crc.update(bytes[128..]);
    return crc.final();
}

fn put(comptime T: type, destination: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, destination[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, source: []const u8, offset: usize) T {
    return std.mem.readInt(T, source[offset..][0..@sizeOf(T)], .little);
}

test "07 Host native post-only wire values survive complete group decoding" {
    const config: Config = .{
        .schema_registry = 10,
        .decision_domain = 20,
        .session = .{ .fencing = 30, .shard = 1, .generation = 2 },
        .authorization = .{ .strategy_identity = 40, .config_version = 3, .activation_identity = 50, .activation_barrier = 9 },
    };
    var storage: [448]u8 = undefined;
    const frame = try encodeOutputGroupFrame(&storage, config, 1, 12, 1, &.{
        .{ .quantity = 100, .limit_price_micros = 100 },
        .{ .quantity = 100, .limit_price_micros = 100 },
    });
    // Independent Host wire values: order type 2, TIF 3; existing limit/IOC remain 1/2.
    frame[131] = 2;
    frame[132] = 3;
    put(u32, frame, 124, wireCrc(frame));
    const parsed = try decodeIntentGroup(frame);
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(parsed.members[0].order_type));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(parsed.members[0].time_in_force));
    try std.testing.expectEqual(OrderType.limit, parsed.members[1].order_type);
    try std.testing.expectEqual(TimeInForce.good_til_canceled, parsed.members[1].time_in_force);
}

test "subscription merge and intent rejection contract" {
    const fixture = @import("../testing/support/trading_shard_fixture.zig");
    const config: Config = .{
        .schema_registry = 10,
        .decision_domain = 20,
        .session = .{ .fencing = 30, .shard = 1, .generation = 2 },
        .authorization = .{
            .strategy_identity = 40,
            .config_version = 3,
            .activation_identity = 50,
            .activation_barrier = 9,
        },
    };
    const subscriptions = [_]Subscription{
        Subscription.of(40, &.{ .mark_price, .l2_delta }),
        Subscription.of(41, &.{.l2_delta}),
    };
    var gateway = try Gateway.init(config, &subscriptions);
    const authority = try std.testing.allocator.create(fixture.LiveRun);
    defer std.testing.allocator.destroy(authority);
    try fixture.gatewayActivationFixtureForSessionInto(authority, config.authorization, config.session);
    const payload = [_]u8{1};
    const events = [_]EventEnvelope{
        .{ .event_type = .mark_price, .shard_sequence = 10, .source_time_ns = 1, .receive_time_ns = 2, .monotonic_time_ns = 3, .wall_time_utc_ns = 4, .payload = &payload },
        .{ .event_type = .fill, .shard_sequence = 11, .source_time_ns = 1, .receive_time_ns = 2, .monotonic_time_ns = 3, .wall_time_utc_ns = 4, .payload = &payload },
        .{ .event_type = .l2_delta, .shard_sequence = 12, .source_time_ns = 1, .receive_time_ns = 2, .monotonic_time_ns = 3, .wall_time_utc_ns = 4, .payload = &payload },
    };
    var batch_storage: [512]u8 = undefined;
    const batch = try gateway.encodeBatch(&batch_storage, 1, 10, 12, 100, &events);
    try std.testing.expectEqual(@as(u32, 2), try eventCount(batch));
    try gateway.recordPublished(1, 12, 100);
    var frame_storage: [256]u8 = undefined;
    const frame = try encodeOutputFrame(&frame_storage, config, 1, 12, 1, 100, 50_100_000_000);
    try std.testing.expectEqual(RejectReason.unauthorized, gateway.ingest(frame, 101).rejected.reason);
    try gateway.activate(&authority.shard, &authority.decision_journal);
    try std.testing.expect(gateway.ingest(frame, 101) == .accepted);
    const duplicate = gateway.ingest(frame, 102);
    try std.testing.expectEqual(RejectReason.duplicate_identity, duplicate.rejected.reason);

    const unsubscribed = [_]EventEnvelope{
        .{ .event_type = .fill, .shard_sequence = 13, .source_time_ns = 1, .receive_time_ns = 2, .monotonic_time_ns = 3, .wall_time_utc_ns = 4, .payload = &payload },
    };
    var empty_batch_storage: [256]u8 = undefined;
    const empty_batch = try gateway.encodeBatch(
        &empty_batch_storage,
        2,
        13,
        13,
        103,
        &unsubscribed,
    );
    try std.testing.expectEqual(@as(u32, 0), try eventCount(empty_batch));

    var next_config = config;
    next_config.authorization.activation_identity += 1;
    try std.testing.expectError(error.InvalidSessionTransition, gateway.beginSession(next_config, &authority.shard, &authority.decision_journal));
    next_config.session.generation += 1;
    next_config.authorization.activation_barrier = 12;
    try gateway.beginSession(next_config, &authority.shard, &authority.decision_journal);
    try std.testing.expectEqual(
        RejectReason.old_session,
        gateway.ingest(frame, 104).rejected.reason,
    );
    const next_events = [_]EventEnvelope{
        .{ .event_type = .mark_price, .shard_sequence = 13, .source_time_ns = 1, .receive_time_ns = 2, .monotonic_time_ns = 3, .wall_time_utc_ns = 4, .payload = &payload },
    };
    const next_batch = try gateway.encodeBatch(
        &empty_batch_storage,
        1,
        13,
        13,
        105,
        &next_events,
    );
    try gateway.recordPublished(1, 13, 105);
    const next_authority = try std.testing.allocator.create(fixture.LiveRun);
    defer std.testing.allocator.destroy(next_authority);
    try fixture.gatewayActivationFixtureForSessionInto(next_authority, next_config.authorization, next_config.session);
    try gateway.activate(&next_authority.shard, &next_authority.decision_journal);
    const retried = try encodeOutputFrame(
        &frame_storage,
        next_config,
        1,
        13,
        1,
        100,
        50_100_000_000,
    );
    try std.testing.expectEqual(
        RejectReason.duplicate_identity,
        gateway.ingest(retried, 106).rejected.reason,
    );
    try std.testing.expectEqual(@as(u32, 1), try eventCount(next_batch));
}

/// Build Host input exclusively from the currently healthy canonical projection.
/// The caller binds the authoritative ShardSequence and decision clocks.
pub fn depthSnapshotInput(projection: *const market_projection.Projection, instrument: u128, shard_sequence: u64, destination: []u8, monotonic_ns: i64, wall_ns: i64) !EventEnvelope {
    const market = projection.get(instrument) orelse return error.MissingInstrumentDefinition;
    if (market.health != .healthy) return error.MarketGap;
    const book = market.last_book orelse return error.MissingBookSnapshot;
    const payload = try depth_snapshot.encode(destination, book);
    const visible = std.math.cast(i64, book.depth.?.visible_at_ns) orelse return error.InvalidDepthTime;
    return .{ .event_type = .depth_snapshot, .shard_sequence = shard_sequence, .time_presence = 0x1e, .source_time_ns = 0, .receive_time_ns = visible, .monotonic_time_ns = monotonic_ns, .wall_time_utc_ns = wall_ns, .payload = payload };
}

/// Caller supplies a successfully applied canonical trade and its authoritative cursor.
pub fn marketTradeInput(record: @import("../model/canonical_event.zig").EventRecord, shard_sequence: u64, destination: []u8) !EventEnvelope {
    if (record.event != .market_trade) return error.InvalidMarketTrade;
    const payload = try @import("../market/market_trade.zig").encode(destination, record.event.market_trade);
    return .{ .event_type = .market_trade, .shard_sequence = shard_sequence, .time_presence = @as(u32, 1) | (if (record.envelope.times.receive_utc_ns != null) @as(u32, 2) else 0) | (if (record.envelope.times.monotonic_ns != null) @as(u32, 4) else 0) | (if (record.envelope.times.audit_utc_ns != null) @as(u32, 8) else 0), .source_time_ns = std.math.cast(i64, record.event.market_trade.source_time_utc_ns) orelse return error.InvalidMarketTrade, .receive_time_ns = std.math.cast(i64, record.envelope.times.receive_utc_ns orelse 0) orelse return error.InvalidMarketTrade, .monotonic_time_ns = std.math.cast(i64, record.envelope.times.monotonic_ns orelse 0) orelse return error.InvalidMarketTrade, .wall_time_utc_ns = std.math.cast(i64, record.envelope.times.audit_utc_ns orelse 0) orelse return error.InvalidMarketTrade, .payload = payload };
}
