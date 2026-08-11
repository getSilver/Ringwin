const std = @import("std");
const ipc = @import("strategy_host_ipc.zig");

const Crc32c = std.hash.crc.Crc32Iscsi;
const batch_header_len: usize = 128;
const event_header_len: usize = 64;
const output_header_len: usize = 128;
const order_intent_len: usize = 80;
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
};

pub const EventEnvelope = struct {
    event_type: EventType,
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

pub const Config = struct {
    schema_registry: u128,
    decision_domain: u128,
    session: ipc.Session,
    authorization: Authorization,
};

pub const Side = enum(u8) { buy = 1, sell = 2 };
pub const OrderType = enum(u8) { limit = 1 };
pub const TimeInForce = enum(u8) { good_til_canceled = 1, immediate_or_cancel = 2 };

pub const OutputOrder = struct {
    instrument_identity: u128 = 3,
    side: Side = .buy,
    time_in_force: TimeInForce = .good_til_canceled,
    portfolio_reduce_only: bool = false,
    quantity: i64,
    limit_price_micros: i64,
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
    limit_price_micros: i64,
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
};

pub const Decision = union(enum) {
    accepted: OrderIntent,
    rejected: Rejection,
};

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
    trading_enabled: bool = true,
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
        self.trading_enabled = false;
    }

    pub fn beginSession(self: *Gateway, config: Config) !void {
        if (config.authorization.strategy_identity !=
            self.config.authorization.strategy_identity or
            config.authorization.config_version != self.config.authorization.config_version or
            (config.session.fencing == self.config.session.fencing and
                config.session.shard == self.config.session.shard and
                config.session.generation == self.config.session.generation))
            return error.InvalidSessionTransition;
        self.config = config;
        self.published_count = 0;
        self.trading_enabled = false;
    }

    pub fn activate(self: *Gateway, authorization: Authorization) !void {
        if (authorization.strategy_identity == 0 or authorization.activation_identity == 0)
            return error.InvalidAuthorization;
        self.config.authorization = authorization;
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
            const record_len = std.mem.alignForward(usize, event_header_len + event.payload.len, 8);
            if (destination.len -| offset < record_len) return error.BatchTooLarge;
            const record = destination[offset..][0..record_len];
            @memset(record, 0);
            put(u32, record, 0, @intCast(record_len));
            put(u32, record, 4, @intCast(event.payload.len));
            put(u16, record, 8, @intFromEnum(event.event_type));
            put(u16, record, 10, 1);
            put(u32, record, 12, 0x1f);
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

    pub fn ingest(self: *Gateway, frame: []const u8, now_ns: i64) Decision {
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

    fn parse(self: Gateway, frame: []const u8, now_ns: i64) !OrderIntent {
        if (frame.len != output_header_len + order_intent_len or
            !std.mem.eql(u8, frame[0..4], &output_magic) or
            get(u16, frame, 4) != 1 or get(u16, frame, 6) != output_header_len or
            get(u32, frame, 8) != 0 or get(u32, frame, 12) != frame.len or
            get(u32, frame, 44) != 0 or get(u32, frame, 100) != 1 or
            get(u32, frame, 104) != order_intent_len or
            wireCrc(frame) != get(u32, frame, 124))
            return error.Malformed;
        if (get(u64, frame, 32) != self.config.session.fencing or
            get(u32, frame, 40) != self.config.session.shard or
            get(u64, frame, 48) != self.config.session.generation)
            return error.OldSession;
        if (get(u128, frame, 16) != self.config.schema_registry or
            get(u16, frame, 96) != 1 or get(u16, frame, 98) != 1)
            return error.UnknownSchema;
        if (!self.trading_enabled or
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
            cursor <= self.config.authorization.activation_barrier)
            return error.InvalidCursor;
        if (now_ns < batch.published_monotonic_ns or
            now_ns - batch.published_monotonic_ns > stale_intent_ns)
            return error.Stale;

        const payload = frame[128..];
        if (get(u16, payload, 0) != 1 or
            std.enums.fromInt(Side, payload[2]) == null or
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
            .limit_price_micros = get(i64, payload, 72),
        };
    }
};

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
    const total_len = output_header_len + order_intent_len;
    if (destination.len < total_len) return error.FrameTooLarge;
    const frame = destination[0..total_len];
    @memset(frame, 0);
    @memcpy(frame[0..4], &output_magic);
    put(u16, frame, 4, 1);
    put(u16, frame, 6, output_header_len);
    put(u32, frame, 12, total_len);
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
    put(u32, frame, 104, order_intent_len);
    put(u128, frame, 108, config.authorization.activation_identity);
    const payload = frame[128..];
    put(u16, payload, 0, 1);
    payload[2] = @intFromEnum(order.side);
    payload[3] = @intFromEnum(OrderType.limit);
    payload[4] = @intFromEnum(order.time_in_force);
    payload[5] = @intFromBool(order.portfolio_reduce_only);
    put(u64, payload, 8, intent_sequence);
    put(u128, payload, 16, 1);
    put(u128, payload, 32, 2);
    put(u128, payload, 48, order.instrument_identity);
    put(i64, payload, 64, order.quantity);
    put(i64, payload, 72, order.limit_price_micros);
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

test "subscription merge and intent rejection contract" {
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
    next_config.session.generation += 1;
    next_config.authorization.activation_identity += 1;
    next_config.authorization.activation_barrier = 12;
    try gateway.beginSession(next_config);
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
    try gateway.activate(next_config.authorization);
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
