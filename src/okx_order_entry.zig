//! Fixed OKX Demo order codec and bounded scheduler.
//! The caller supplies immutable, already-normalized commands. This module
//! validates their frozen versions and safety guards, but never rounds,
//! reroutes, retries, or invents replacement orders.

const std = @import("std");
const market = @import("okx_public_market.zig");
const private = @import("okx_private_reconciliation.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Decimal = market.Decimal;
pub const Instrument = market.Instrument;
pub const ClientOrderId = private.ClientOrderId;
pub const VenueOrderId = private.VenueOrderId;
pub const RequestId = private.FixedText(32);

pub const max_batch_items = 20;
pub const max_request_bytes = 16 * 1024;
pub const normal_queue_capacity = 64;
pub const safety_queue_capacity = 32;

pub const Product = enum(u8) { spot, swap };
pub const Side = enum(u8) { buy, sell };
pub const OrderKind = enum(u8) { limit_gtc, market, limit_ioc, limit_fok, post_only };
pub const Operation = enum(u8) { place, amend, cancel };
pub const Priority = enum(u8) { cancel, de_risk, normal };
pub const Qualification = enum(u8) { official_confirmed, demo_qualified };

pub fn clientOrderId(order_identity: u128) ClientOrderId {
    return codedIdentity(ClientOrderId, "RWN1", order_identity);
}

pub fn amendRequestId(command_identity: u128) RequestId {
    return codedIdentity(RequestId, "RWA1", command_identity);
}

fn codedIdentity(comptime Id: type, prefix: []const u8, identity: u128) Id {
    var result: Id = .{ .len = 0 };
    @memcpy(result.bytes[0..prefix.len], prefix);
    var reversed: [26]u8 = undefined;
    var value = identity;
    var count: usize = 0;
    while (value != 0) : (value /= 36) {
        const digit: u8 = @intCast(value % 36);
        reversed[count] = if (digit < 10) '0' + digit else 'A' + digit - 10;
        count += 1;
    }
    if (count == 0) {
        reversed[0] = '0';
        count = 1;
    }
    for (0..count) |index| result.bytes[prefix.len + index] = reversed[count - index - 1];
    result.len = @intCast(prefix.len + count);
    return result;
}

pub const RateLimit = struct {
    requests: u16,
    window_ns: u64,
};

pub const CapabilityProfile = struct {
    version: u64,
    rules_version: u64,
    config_version: u64,
    gateway_session: u64,
    qualification: Qualification,
    batch_max: u8,
    place_limit: RateLimit,
    place_batch_limit: RateLimit,
    amend_limit: RateLimit,
    amend_batch_limit: RateLimit,
    cancel_limit: RateLimit,
    cancel_batch_limit: RateLimit,
    subaccount_place_amend_limit: RateLimit,
    limit: bool,
    protected_market_ioc: bool,
    ioc: bool,
    fok: bool,
    native_amend: bool,
    native_post_only: bool,
    swap_venue_reduce_only: bool,
};

pub const Place = struct {
    side: Side,
    kind: OrderKind,
    quantity: Decimal,
    limit_price: ?Decimal,
    market_protection_price: ?Decimal,
    portfolio_reduce_only: bool,
    venue_reduce_only: bool,
};

pub const Amend = struct {
    request_id: RequestId,
    target_remaining_quantity: Decimal,
    cumulative_filled_quantity: Decimal,
    new_limit_price: ?Decimal,
    increases_risk: bool,
};

pub const Cancel = struct {};

pub const Payload = union(Operation) {
    place: Place,
    amend: Amend,
    cancel: Cancel,
};

pub const OrderCommand = struct {
    command_id: u64,
    order_id: u64,
    order_revision: u32,
    shard_sequence: u64,
    instrument: Instrument,
    client_order_id: ClientOrderId,
    venue_order_id: ?VenueOrderId,
    capability_version: u64,
    rules_version: u64,
    config_version: u64,
    gateway_session: u64,
    dispatch_deadline_monotonic_ns: u64,
    risk_reservation_id: u64,
    payload: Payload,

    pub fn operation(self: *const OrderCommand) Operation {
        return std.meta.activeTag(self.payload);
    }

    pub fn product(self: *const OrderCommand) Product {
        return switch (self.instrument) {
            .btc_usdt_spot => .spot,
            .btc_usdt_swap => .swap,
        };
    }

    pub fn priority(self: *const OrderCommand) Priority {
        return switch (self.payload) {
            .cancel => .cancel,
            .place => |place| if (place.venue_reduce_only) .de_risk else .normal,
            .amend => |amend| if (amend.increases_risk) .normal else .de_risk,
        };
    }
};

pub const Guard = struct {
    order_entry_ready: bool,
    risk_reservation_valid: bool,
    capability_version: u64,
    rules_version: u64,
    config_version: u64,
    gateway_session: u64,
    current_order_revision: u32,
    cumulative_filled_quantity: Decimal,
};

pub const RejectReason = enum(u8) {
    capability_unsupported,
    invalid_spec,
    capability_version_changed,
    stale_order_revision,
    deadline_expired,
    adapter_backpressure,
    order_entry_not_ready,
    invalid_risk_reservation,
    rate_limited,
    insufficient_margin,
    post_only_would_take,
    venue_unavailable,
    other_venue_reject,
};

pub const DispatchState = enum(u8) { not_sent, submitted, unknown };

pub const DispatchResult = struct {
    command_id: u64,
    attempt_id: u64,
    state: DispatchState,
    reason: ?RejectReason,
    request_hash: ?[Sha256.digest_length]u8 = null,
    venue_code: private.FixedText(16) = .{ .len = 0 },
};

pub const EnqueueResult = union(enum) {
    queued,
    dispatch: DispatchResult,
};

pub const EncodedRequest = struct {
    operation: Operation,
    product: Product,
    body: [max_request_bytes]u8 = undefined,
    body_len: u16,
    command_ids: [max_batch_items]u64 = undefined,
    item_count: u8,
    request_hash: [Sha256.digest_length]u8,

    pub fn path(self: *const EncodedRequest) []const u8 {
        return switch (self.operation) {
            .place => if (self.item_count == 1)
                "/api/v5/trade/order"
            else
                "/api/v5/trade/batch-orders",
            .amend => if (self.item_count == 1)
                "/api/v5/trade/amend-order"
            else
                "/api/v5/trade/amend-batch-orders",
            .cancel => if (self.item_count == 1)
                "/api/v5/trade/cancel-order"
            else
                "/api/v5/trade/cancel-batch-orders",
        };
    }

    pub fn bytes(self: *const EncodedRequest) []const u8 {
        return self.body[0..self.body_len];
    }
};

pub const TransportBatch = struct {
    commands: [max_batch_items]OrderCommand = undefined,
    count: u8 = 0,

    pub fn slice(self: *const TransportBatch) []const OrderCommand {
        return self.commands[0..self.count];
    }
};

const Queue = struct {
    items: [normal_queue_capacity]OrderCommand = undefined,
    count: u8 = 0,

    fn append(self: *Queue, command: OrderCommand, capacity: usize) !void {
        if (self.count >= capacity) return error.Full;
        self.items[self.count] = command;
        self.count += 1;
    }

    fn remove(self: *Queue, index: usize) OrderCommand {
        const command = self.items[index];
        var cursor = index;
        while (cursor + 1 < self.count) : (cursor += 1)
            self.items[cursor] = self.items[cursor + 1];
        self.count -= 1;
        return command;
    }

    fn best(self: *const Queue) ?usize {
        if (self.count == 0) return null;
        var result: usize = 0;
        for (self.items[1..self.count], 1..) |candidate, index| {
            if (commandLess(candidate, self.items[result])) result = index;
        }
        return result;
    }
};

const Bucket = struct {
    window_start_ns: u64 = 0,
    used: u16 = 0,

    fn refresh(self: *Bucket, now_ns: u64, limit: RateLimit) void {
        if (self.window_start_ns == 0 or now_ns -| self.window_start_ns >= limit.window_ns)
            self.* = .{ .window_start_ns = now_ns };
    }

    fn available(self: *Bucket, now_ns: u64, limit: RateLimit, cost: u16) bool {
        self.refresh(now_ns, limit);
        return cost <= limit.requests -| self.used;
    }

    fn consume(self: *Bucket, cost: u16) void {
        self.used += cost;
    }
};

pub const Next = union(enum) {
    dispatch: DispatchResult,
    batch: TransportBatch,
};

pub const Scheduler = struct {
    profile: CapabilityProfile,
    safety: Queue = .{},
    normal: Queue = .{},
    operation_buckets: [3][2][2]Bucket = @splat(@splat(@splat(.{}))),
    subaccount_bucket: Bucket = .{},
    safe_burst: u8 = 0,
    next_attempt_id: u64 = 1,

    pub fn init(profile: CapabilityProfile) !Scheduler {
        if (profile.batch_max == 0 or profile.batch_max > max_batch_items)
            return error.InvalidProfile;
        inline for (.{
            profile.place_limit,
            profile.place_batch_limit,
            profile.amend_limit,
            profile.amend_batch_limit,
            profile.cancel_limit,
            profile.cancel_batch_limit,
            profile.subaccount_place_amend_limit,
        }) |limit| if (limit.requests == 0 or limit.window_ns == 0)
            return error.InvalidProfile;
        return .{ .profile = profile };
    }

    pub fn enqueue(
        self: *Scheduler,
        command: OrderCommand,
        guard: Guard,
        now_ns: u64,
    ) EnqueueResult {
        if (validateCommand(&self.profile, &command, guard, now_ns)) |reason|
            return .{ .dispatch = self.notSent(command.command_id, reason) };
        const queue = if (command.priority() == .normal) &self.normal else &self.safety;
        const capacity: usize = if (command.priority() == .normal)
            normal_queue_capacity
        else
            safety_queue_capacity;
        queue.append(command, capacity) catch
            return .{ .dispatch = self.notSent(command.command_id, .adapter_backpressure) };
        return .queued;
    }

    pub fn next(self: *Scheduler, now_ns: u64) ?Next {
        const prefer_normal = self.safe_burst >= 8 and self.normal.count != 0;
        var queue = if (!prefer_normal and self.safety.count != 0) &self.safety else &self.normal;
        if (queue.count == 0) queue = &self.safety;
        const best_index = queue.best() orelse return null;
        const first = queue.items[best_index];
        if (first.dispatch_deadline_monotonic_ns <= now_ns) {
            _ = queue.remove(best_index);
            return .{ .dispatch = self.notSent(first.command_id, .deadline_expired) };
        }
        if (!self.rateAvailable(&first, now_ns, 1)) {
            if (bestMatching(queue, &first) == null or !self.rateAvailable(&first, now_ns, 2))
                return null;
        }

        var batch: TransportBatch = .{};
        batch.commands[0] = queue.remove(best_index);
        batch.count = 1;
        while (batch.count < self.profile.batch_max) {
            const index = bestMatching(queue, &first) orelse break;
            const candidate = queue.items[index];
            if (candidate.dispatch_deadline_monotonic_ns <= now_ns) break;
            if (!self.rateAvailable(&candidate, now_ns, batch.count + 1)) break;
            batch.commands[batch.count] = queue.remove(index);
            batch.count += 1;
        }
        self.consumeRate(&first, now_ns, batch.count);
        if (queue == &self.safety) self.safe_burst += 1 else self.safe_burst = 0;
        return .{ .batch = batch };
    }

    fn rateAvailable(self: *Scheduler, command: *const OrderCommand, now_ns: u64, cost: u16) bool {
        const operation = command.operation();
        const batched = cost > 1;
        const limit = self.operationLimit(operation, batched);
        const bucket = &self.operation_buckets[@intFromEnum(operation)][@intFromEnum(command.product())][@intFromBool(batched)];
        if (!bucket.available(now_ns, limit, cost)) return false;
        if (operation == .place or operation == .amend)
            return self.subaccount_bucket.available(
                now_ns,
                self.profile.subaccount_place_amend_limit,
                cost,
            );
        return true;
    }

    fn consumeRate(self: *Scheduler, command: *const OrderCommand, now_ns: u64, cost: u16) void {
        const operation = command.operation();
        const batched = cost > 1;
        const bucket = &self.operation_buckets[@intFromEnum(operation)][@intFromEnum(command.product())][@intFromBool(batched)];
        bucket.refresh(now_ns, self.operationLimit(operation, batched));
        bucket.consume(cost);
        if (operation == .place or operation == .amend) {
            self.subaccount_bucket.refresh(now_ns, self.profile.subaccount_place_amend_limit);
            self.subaccount_bucket.consume(cost);
        }
    }

    fn operationLimit(self: *const Scheduler, operation: Operation, batched: bool) RateLimit {
        return switch (operation) {
            .place => if (batched) self.profile.place_batch_limit else self.profile.place_limit,
            .amend => if (batched) self.profile.amend_batch_limit else self.profile.amend_limit,
            .cancel => if (batched) self.profile.cancel_batch_limit else self.profile.cancel_limit,
        };
    }

    fn notSent(self: *Scheduler, command_id: u64, reason: RejectReason) DispatchResult {
        defer self.next_attempt_id += 1;
        return .{
            .command_id = command_id,
            .attempt_id = self.next_attempt_id,
            .state = .not_sent,
            .reason = reason,
        };
    }
};

fn commandLess(left: OrderCommand, right: OrderCommand) bool {
    if (left.dispatch_deadline_monotonic_ns != right.dispatch_deadline_monotonic_ns)
        return left.dispatch_deadline_monotonic_ns < right.dispatch_deadline_monotonic_ns;
    if (left.shard_sequence != right.shard_sequence)
        return left.shard_sequence < right.shard_sequence;
    return left.command_id < right.command_id;
}

fn bestMatching(queue: *const Queue, first: *const OrderCommand) ?usize {
    var result: ?usize = null;
    for (queue.items[0..queue.count], 0..) |candidate, index| {
        if (candidate.operation() != first.operation() or candidate.product() != first.product() or
            candidate.instrument != first.instrument or candidate.capability_version != first.capability_version or
            candidate.gateway_session != first.gateway_session)
            continue;
        if (result == null or commandLess(candidate, queue.items[result.?])) result = index;
    }
    return result;
}

fn validateCommand(
    profile: *const CapabilityProfile,
    command: *const OrderCommand,
    guard: Guard,
    now_ns: u64,
) ?RejectReason {
    if (command.command_id == 0 or command.order_id == 0 or command.client_order_id.len == 0)
        return .invalid_spec;
    if (command.dispatch_deadline_monotonic_ns <= now_ns) return .deadline_expired;
    if (!guard.order_entry_ready or profile.qualification != .demo_qualified)
        return .order_entry_not_ready;
    if (command.capability_version != profile.version or command.capability_version != guard.capability_version or
        command.rules_version != profile.rules_version or command.rules_version != guard.rules_version or
        command.config_version != profile.config_version or command.config_version != guard.config_version or
        command.gateway_session != profile.gateway_session or command.gateway_session != guard.gateway_session)
        return .capability_version_changed;
    if (command.order_revision != guard.current_order_revision) return .stale_order_revision;
    if (command.priority() == .normal and (!guard.risk_reservation_valid or command.risk_reservation_id == 0))
        return .invalid_risk_reservation;

    switch (command.payload) {
        .place => |place| {
            if (place.quantity.coefficient <= 0) return .invalid_spec;
            if (place.kind == .market) {
                if (place.limit_price != null or place.market_protection_price == null)
                    return .invalid_spec;
            } else if (place.limit_price == null or place.market_protection_price != null) {
                return .invalid_spec;
            }
            if (place.kind == .post_only and !profile.native_post_only)
                return .capability_unsupported;
            if (place.kind == .limit_gtc and !profile.limit) return .capability_unsupported;
            if (place.kind == .market and (!profile.protected_market_ioc or !profile.ioc))
                return .capability_unsupported;
            if (place.kind == .limit_ioc and !profile.ioc) return .capability_unsupported;
            if (place.kind == .limit_fok and !profile.fok) return .capability_unsupported;
            if (command.product() == .spot and place.venue_reduce_only)
                return .capability_unsupported;
            if (place.venue_reduce_only and !profile.swap_venue_reduce_only)
                return .capability_unsupported;
        },
        .amend => |amend| {
            if (!profile.native_amend) return .capability_unsupported;
            if (command.venue_order_id == null or amend.request_id.len == 0 or
                amend.target_remaining_quantity.coefficient <= 0 or
                !decimalEqual(amend.cumulative_filled_quantity, guard.cumulative_filled_quantity))
                return .stale_order_revision;
            if (amend.new_limit_price == null and amend.target_remaining_quantity.coefficient <= 0)
                return .invalid_spec;
        },
        .cancel => if (command.venue_order_id == null and command.client_order_id.len == 0)
            return .invalid_spec,
    }
    return null;
}

pub fn encode(batch: *const TransportBatch) !EncodedRequest {
    if (batch.count == 0 or batch.count > max_batch_items) return error.InvalidBatch;
    const first = &batch.commands[0];
    var result: EncodedRequest = .{
        .operation = first.operation(),
        .product = first.product(),
        .body_len = 0,
        .item_count = batch.count,
        .request_hash = undefined,
    };
    var offset: usize = 0;
    if (batch.count > 1) try appendBytes(&result.body, &offset, "[");
    for (batch.slice(), 0..) |*command, index| {
        if (command.operation() != result.operation or command.product() != result.product)
            return error.InvalidBatch;
        if (index != 0) try appendBytes(&result.body, &offset, ",");
        const encoded = try encodeOne(command);
        try appendBytes(&result.body, &offset, encoded.bytes());
        result.command_ids[index] = command.command_id;
    }
    if (batch.count > 1) try appendBytes(&result.body, &offset, "]");
    result.body_len = std.math.cast(u16, offset) orelse return error.RequestTooLarge;
    var hasher = Sha256.init(.{});
    hasher.update(result.path());
    hasher.update(result.bytes());
    result.request_hash = hasher.finalResult();
    return result;
}

const EncodedItem = struct {
    storage: [1024]u8 = undefined,
    len: u16,
    fn bytes(self: *const EncodedItem) []const u8 {
        return self.storage[0..self.len];
    }
};

fn encodeOne(command: *const OrderCommand) !EncodedItem {
    try validateIdentifier(command.client_order_id.slice());
    var result: EncodedItem = .{ .len = 0 };
    var writer: std.Io.Writer = .fixed(&result.storage);
    const out = &writer;
    const inst_id = instrumentId(command.instrument);
    switch (command.payload) {
        .place => |place| {
            const quantity = try decimalText(place.quantity);
            const effective_price = if (place.kind == .market)
                place.market_protection_price
            else
                place.limit_price;
            const price = if (effective_price) |value| try decimalText(value) else null;
            try std.json.Stringify.value(.{
                .instId = inst_id,
                .tdMode = if (command.product() == .spot) "cash" else "isolated",
                .clOrdId = command.client_order_id.slice(),
                .side = @tagName(place.side),
                .ordType = if (place.kind == .market) "ioc" else orderType(place.kind),
                .sz = quantity.slice(),
                .px = if (price) |value| value.slice() else null,
                .posSide = if (command.product() == .swap) "net" else null,
                .reduceOnly = if (command.product() == .swap) place.venue_reduce_only else null,
                .pxAmendType = "0",
            }, .{ .emit_null_optional_fields = false }, out);
        },
        .amend => |amend| {
            try validateIdentifier(amend.request_id.slice());
            const total = try decimalAdd(amend.target_remaining_quantity, amend.cumulative_filled_quantity);
            const quantity = try decimalText(total);
            const price = if (amend.new_limit_price) |value| try decimalText(value) else null;
            const venue_order_id = try venueIdText(command.venue_order_id.?);
            try std.json.Stringify.value(.{
                .instId = inst_id,
                .ordId = venue_order_id.slice(),
                .clOrdId = command.client_order_id.slice(),
                .reqId = amend.request_id.slice(),
                .newSz = quantity.slice(),
                .newPx = if (price) |value| value.slice() else null,
                .cxlOnFail = false,
                .pxAmendType = "0",
            }, .{ .emit_null_optional_fields = false }, out);
        },
        .cancel => {
            const venue_order_id = if (command.venue_order_id) |value| try venueIdText(value) else null;
            try std.json.Stringify.value(.{
                .instId = inst_id,
                .ordId = if (venue_order_id) |value| value.slice() else null,
                .clOrdId = command.client_order_id.slice(),
            }, .{ .emit_null_optional_fields = false }, out);
        },
    }
    result.len = std.math.cast(u16, out.end) orelse return error.RequestTooLarge;
    return result;
}

const DecimalText = struct {
    bytes: [64]u8 = undefined,
    len: u8,
    fn slice(self: *const DecimalText) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn decimalText(value: Decimal) !DecimalText {
    if (value.scale > 18) return error.InvalidDecimal;
    var result: DecimalText = .{ .len = 0 };
    const negative = value.coefficient < 0;
    const magnitude: u128 = @intCast(if (negative) -value.coefficient else value.coefficient);
    var digits_buffer: [40]u8 = undefined;
    const digits = try std.fmt.bufPrint(&digits_buffer, "{d}", .{magnitude});
    var offset: usize = 0;
    if (negative) try appendBytes(&result.bytes, &offset, "-");
    if (value.scale == 0) {
        try appendBytes(&result.bytes, &offset, digits);
    } else if (digits.len <= value.scale) {
        try appendBytes(&result.bytes, &offset, "0.");
        var zeros = value.scale - digits.len;
        while (zeros != 0) : (zeros -= 1) try appendBytes(&result.bytes, &offset, "0");
        try appendBytes(&result.bytes, &offset, digits);
    } else {
        const split = digits.len - value.scale;
        try appendBytes(&result.bytes, &offset, digits[0..split]);
        try appendBytes(&result.bytes, &offset, ".");
        try appendBytes(&result.bytes, &offset, digits[split..]);
    }
    result.len = @intCast(offset);
    return result;
}

fn decimalAdd(left: Decimal, right: Decimal) !Decimal {
    const scale = @max(left.scale, right.scale);
    const left_factor = try pow10(scale - left.scale);
    const right_factor = try pow10(scale - right.scale);
    return .{
        .coefficient = try std.math.add(
            i128,
            try std.math.mul(i128, left.coefficient, left_factor),
            try std.math.mul(i128, right.coefficient, right_factor),
        ),
        .scale = scale,
    };
}

fn pow10(exponent: u8) !i128 {
    var result: i128 = 1;
    for (0..exponent) |_| result = try std.math.mul(i128, result, 10);
    return result;
}

fn decimalEqual(left: Decimal, right: Decimal) bool {
    const scale = @max(left.scale, right.scale);
    const left_factor = pow10(scale - left.scale) catch return false;
    const right_factor = pow10(scale - right.scale) catch return false;
    const normalized_left = std.math.mul(i128, left.coefficient, left_factor) catch return false;
    const normalized_right = std.math.mul(i128, right.coefficient, right_factor) catch return false;
    return normalized_left == normalized_right;
}

fn appendBytes(destination: []u8, offset: *usize, bytes: []const u8) !void {
    if (destination.len - offset.* < bytes.len) return error.RequestTooLarge;
    @memcpy(destination[offset.*..][0..bytes.len], bytes);
    offset.* += bytes.len;
}

fn validateIdentifier(value: []const u8) !void {
    if (value.len == 0 or value.len > 32) return error.InvalidIdentifier;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte))
        return error.InvalidIdentifier;
}

fn venueIdText(value: VenueOrderId) !DecimalText {
    var result: DecimalText = .{ .len = 0 };
    const text = try std.fmt.bufPrint(&result.bytes, "{d}", .{@intFromEnum(value)});
    result.len = @intCast(text.len);
    return result;
}

fn instrumentId(instrument: Instrument) []const u8 {
    return switch (instrument) {
        .btc_usdt_spot => "BTC-USDT",
        .btc_usdt_swap => "BTC-USDT-SWAP",
    };
}

fn orderType(kind: OrderKind) []const u8 {
    return switch (kind) {
        .limit_gtc => "limit",
        .market => "market",
        .limit_ioc => "ioc",
        .limit_fok => "fok",
        .post_only => "post_only",
    };
}

pub const TransportOutcome = enum(u8) {
    proven_before_send,
    response,
    write_or_response_uncertain,
};

pub const ResultBatch = struct {
    items: [max_batch_items]DispatchResult = undefined,
    count: u8 = 0,
};

pub fn classifyResponse(
    gpa: std.mem.Allocator,
    request: *const EncodedRequest,
    attempt_base: u64,
    outcome: TransportOutcome,
    raw: ?[]const u8,
) !ResultBatch {
    var result: ResultBatch = .{};
    if (outcome != .response) {
        for (request.command_ids[0..request.item_count], 0..) |command_id, index| {
            result.items[index] = .{
                .command_id = command_id,
                .attempt_id = attempt_base + index,
                .state = if (outcome == .proven_before_send) .not_sent else .unknown,
                .reason = if (outcome == .proven_before_send) .venue_unavailable else null,
                .request_hash = request.request_hash,
            };
            result.count += 1;
        }
        return result;
    }
    const bytes = raw orelse return error.MissingResponse;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch
        return unknownBatch(request, attempt_base);
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return unknownBatch(request, attempt_base),
    };
    const data_value = object.get("data") orelse return unknownBatch(request, attempt_base);
    const data = switch (data_value) {
        .array => |value| value,
        else => return unknownBatch(request, attempt_base),
    };
    if (data.items.len != request.item_count) return unknownBatch(request, attempt_base);
    for (data.items, 0..) |item, index| {
        const row = switch (item) {
            .object => |value| value,
            else => return unknownBatch(request, attempt_base),
        };
        const code_value = row.get("sCode") orelse return unknownBatch(request, attempt_base);
        const code = switch (code_value) {
            .string => |value| value,
            else => return unknownBatch(request, attempt_base),
        };
        const success = std.mem.eql(u8, code, "0");
        const complete_success = !success or request.operation != .place or placeAckHasOrderId(row);
        result.items[index] = .{
            .command_id = request.command_ids[index],
            .attempt_id = attempt_base + index,
            .state = if (complete_success) .submitted else .unknown,
            .reason = if (!complete_success or success) null else mapVenueReject(code),
            .request_hash = request.request_hash,
            .venue_code = try private.FixedText(16).init(code),
        };
        result.count += 1;
    }
    return result;
}

fn placeAckHasOrderId(row: std.json.ObjectMap) bool {
    const value = row.get("ordId") orelse return false;
    return switch (value) {
        .string => |text| text.len != 0,
        else => false,
    };
}

fn unknownBatch(request: *const EncodedRequest, attempt_base: u64) ResultBatch {
    var result: ResultBatch = .{};
    for (request.command_ids[0..request.item_count], 0..) |command_id, index| {
        result.items[index] = .{
            .command_id = command_id,
            .attempt_id = attempt_base + index,
            .state = .unknown,
            .reason = null,
            .request_hash = request.request_hash,
        };
        result.count += 1;
    }
    return result;
}

fn mapVenueReject(code: []const u8) RejectReason {
    if (std.mem.eql(u8, code, "50011") or std.mem.eql(u8, code, "50061"))
        return .rate_limited;
    if (std.mem.eql(u8, code, "51008")) return .insufficient_margin;
    return .other_venue_reject;
}

pub const ReplacementGate = struct {
    old_order_id: u64,
    old_revision: u32,
    state: enum { cancel_required, awaiting_terminal, awaiting_reconciliation, revalidate } = .cancel_required,

    pub fn cancelQueued(self: *ReplacementGate) !void {
        if (self.state != .cancel_required) return error.InvalidTransition;
        self.state = .awaiting_terminal;
    }

    pub fn observeTerminal(self: *ReplacementGate, order_id: u64, revision: u32) !void {
        if ((self.state != .awaiting_terminal and self.state != .awaiting_reconciliation) or
            order_id != self.old_order_id or
            revision < self.old_revision)
            return error.InvalidTransition;
        self.state = .revalidate;
    }

    pub fn observeUnknown(self: *ReplacementGate) void {
        self.state = .awaiting_reconciliation;
    }

    pub fn mayCreateReplacement(self: *const ReplacementGate) bool {
        return self.state == .revalidate;
    }
};

const test_profile: CapabilityProfile = .{
    .version = 11,
    .rules_version = 12,
    .config_version = 13,
    .gateway_session = 14,
    .qualification = .demo_qualified,
    .batch_max = 20,
    .place_limit = .{ .requests = 2, .window_ns = std.time.ns_per_s },
    .place_batch_limit = .{ .requests = 10, .window_ns = std.time.ns_per_s },
    .amend_limit = .{ .requests = 2, .window_ns = std.time.ns_per_s },
    .amend_batch_limit = .{ .requests = 10, .window_ns = std.time.ns_per_s },
    .cancel_limit = .{ .requests = 4, .window_ns = std.time.ns_per_s },
    .cancel_batch_limit = .{ .requests = 10, .window_ns = std.time.ns_per_s },
    .subaccount_place_amend_limit = .{ .requests = 3, .window_ns = std.time.ns_per_s },
    .limit = true,
    .protected_market_ioc = true,
    .ioc = true,
    .fok = true,
    .native_amend = true,
    .native_post_only = true,
    .swap_venue_reduce_only = true,
};

fn testCommand(command_id: u64, payload: Payload) OrderCommand {
    return .{
        .command_id = command_id,
        .order_id = command_id,
        .order_revision = 1,
        .shard_sequence = command_id,
        .instrument = .btc_usdt_swap,
        .client_order_id = ClientOrderId.init("RWNTEST0001") catch unreachable,
        .venue_order_id = @enumFromInt(9001),
        .capability_version = test_profile.version,
        .rules_version = test_profile.rules_version,
        .config_version = test_profile.config_version,
        .gateway_session = test_profile.gateway_session,
        .dispatch_deadline_monotonic_ns = 10 * std.time.ns_per_s,
        .risk_reservation_id = command_id,
        .payload = payload,
    };
}

fn testGuard() Guard {
    return .{
        .order_entry_ready = true,
        .risk_reservation_valid = true,
        .capability_version = test_profile.version,
        .rules_version = test_profile.rules_version,
        .config_version = test_profile.config_version,
        .gateway_session = test_profile.gateway_session,
        .current_order_revision = 1,
        .cumulative_filled_quantity = .{ .coefficient = 4, .scale = 1 },
    };
}

fn limitPlace(reduce_only: bool) Payload {
    return .{ .place = .{
        .side = .buy,
        .kind = .limit_gtc,
        .quantity = .{ .coefficient = 1, .scale = 0 },
        .limit_price = .{ .coefficient = 50_000, .scale = 0 },
        .market_protection_price = null,
        .portfolio_reduce_only = reduce_only,
        .venue_reduce_only = reduce_only,
    } };
}

test "versioned OKX identities are deterministic alphanumeric and bounded" {
    const first = clientOrderId(0x123456789abcdef);
    const same = clientOrderId(0x123456789abcdef);
    const other = clientOrderId(0x123456789abcdee);
    try std.testing.expectEqualStrings(first.slice(), same.slice());
    try std.testing.expect(!std.mem.eql(u8, first.slice(), other.slice()));
    try std.testing.expect(first.len <= 32);
    try std.testing.expect(std.mem.startsWith(u8, first.slice(), "RWN1"));
    for (first.slice()) |byte| try std.testing.expect(std.ascii.isAlphanumeric(byte));
    const request_id = amendRequestId(std.math.maxInt(u128));
    try std.testing.expect(request_id.len <= 32);
    for (request_id.slice()) |byte| try std.testing.expect(std.ascii.isAlphanumeric(byte));
}

test "place amend and cancel encode only frozen OKX semantics" {
    var place_command = testCommand(1, limitPlace(true));
    var place_batch: TransportBatch = .{};
    place_batch.commands[0] = place_command;
    place_batch.count = 1;
    const place = try encode(&place_batch);
    try std.testing.expectEqualStrings("/api/v5/trade/order", place.path());
    try std.testing.expectEqualStrings(
        "{\"instId\":\"BTC-USDT-SWAP\",\"tdMode\":\"isolated\",\"clOrdId\":\"RWNTEST0001\",\"side\":\"buy\",\"ordType\":\"limit\",\"sz\":\"1\",\"px\":\"50000\",\"posSide\":\"net\",\"reduceOnly\":true,\"pxAmendType\":\"0\"}",
        place.bytes(),
    );

    const amend_payload: Payload = .{ .amend = .{
        .request_id = try RequestId.init("RWNREQ0001"),
        .target_remaining_quantity = .{ .coefficient = 6, .scale = 1 },
        .cumulative_filled_quantity = .{ .coefficient = 4, .scale = 1 },
        .new_limit_price = .{ .coefficient = 49_900, .scale = 0 },
        .increases_risk = false,
    } };
    var amend_batch: TransportBatch = .{};
    amend_batch.commands[0] = testCommand(2, amend_payload);
    amend_batch.count = 1;
    const amend = try encode(&amend_batch);
    try std.testing.expectEqualStrings("/api/v5/trade/amend-order", amend.path());
    try std.testing.expect(std.mem.indexOf(u8, amend.bytes(), "\"newSz\":\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, amend.bytes(), "\"cxlOnFail\":false") != null);

    var cancel_batch: TransportBatch = .{};
    cancel_batch.commands[0] = testCommand(3, .{ .cancel = .{} });
    cancel_batch.commands[1] = testCommand(4, .{ .cancel = .{} });
    cancel_batch.count = 2;
    const cancel = try encode(&cancel_batch);
    try std.testing.expectEqualStrings("/api/v5/trade/cancel-batch-orders", cancel.path());
    try std.testing.expect(cancel.bytes()[0] == '[' and cancel.bytes()[cancel.body_len - 1] == ']');
    _ = &place_command;
}

test "all qualified limit kinds map directly and spot omits derivatives fields" {
    const cases = [_]struct { kind: OrderKind, wire: []const u8 }{
        .{ .kind = .limit_gtc, .wire = "limit" },
        .{ .kind = .limit_ioc, .wire = "ioc" },
        .{ .kind = .limit_fok, .wire = "fok" },
        .{ .kind = .post_only, .wire = "post_only" },
    };
    for (cases, 0..) |case, index| {
        var command = testCommand(index + 20, limitPlace(false));
        command.instrument = .btc_usdt_spot;
        command.payload.place.kind = case.kind;
        var batch: TransportBatch = .{};
        batch.commands[0] = command;
        batch.count = 1;
        const request = try encode(&batch);
        var needle_buffer: [48]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buffer, "\"ordType\":\"{s}\"", .{case.wire});
        try std.testing.expect(std.mem.indexOf(u8, request.bytes(), needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, request.bytes(), "\"tdMode\":\"cash\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, request.bytes(), "posSide") == null);
        try std.testing.expect(std.mem.indexOf(u8, request.bytes(), "reduceOnly") == null);
    }

    var invalid = testCommand(30, limitPlace(false));
    invalid.client_order_id = try ClientOrderId.init("RWN-INVALID");
    var invalid_batch: TransportBatch = .{};
    invalid_batch.commands[0] = invalid;
    invalid_batch.count = 1;
    try std.testing.expectError(error.InvalidIdentifier, encode(&invalid_batch));
}

test "market requires a protection price but never encodes an unreviewed limit" {
    var scheduler = try Scheduler.init(test_profile);
    var unprotected = testCommand(1, .{ .place = .{
        .side = .buy,
        .kind = .market,
        .quantity = .{ .coefficient = 1, .scale = 0 },
        .limit_price = null,
        .market_protection_price = null,
        .portfolio_reduce_only = false,
        .venue_reduce_only = false,
    } });
    const rejected = scheduler.enqueue(unprotected, testGuard(), 1);
    try std.testing.expectEqual(RejectReason.invalid_spec, rejected.dispatch.reason.?);

    unprotected.payload.place.market_protection_price = .{ .coefficient = 51_000, .scale = 0 };
    try std.testing.expect(scheduler.enqueue(unprotected, testGuard(), 1) == .queued);
    const batch = scheduler.next(2).?.batch;
    const request = try encode(&batch);
    try std.testing.expect(std.mem.indexOf(u8, request.bytes(), "\"ordType\":\"ioc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.bytes(), "\"px\":\"51000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.bytes(), "\"ordType\":\"market\"") == null);
}

test "bounded scheduler prioritizes safety batches and charges every item" {
    var scheduler = try Scheduler.init(test_profile);
    try std.testing.expect(scheduler.enqueue(testCommand(2, limitPlace(false)), testGuard(), 1) == .queued);
    try std.testing.expect(scheduler.enqueue(testCommand(3, .{ .cancel = .{} }), testGuard(), 1) == .queued);
    try std.testing.expect(scheduler.enqueue(testCommand(4, .{ .cancel = .{} }), testGuard(), 1) == .queued);

    const first = scheduler.next(2).?.batch;
    try std.testing.expectEqual(@as(u8, 2), first.count);
    try std.testing.expectEqual(Operation.cancel, first.commands[0].operation());
    const second = scheduler.next(2).?.batch;
    try std.testing.expectEqual(@as(u8, 1), second.count);
    try std.testing.expectEqual(Operation.place, second.commands[0].operation());

    try std.testing.expect(scheduler.enqueue(testCommand(5, limitPlace(false)), testGuard(), 2) == .queued);
    try std.testing.expect(scheduler.enqueue(testCommand(6, limitPlace(false)), testGuard(), 2) == .queued);
    try std.testing.expect(scheduler.next(2) != null);
    try std.testing.expect(scheduler.enqueue(testCommand(7, limitPlace(false)), testGuard(), 2) == .queued);
    try std.testing.expect(scheduler.next(2) == null);
    try std.testing.expect(scheduler.next(std.time.ns_per_s + 2) != null);
}

test "stale versions revisions deadlines and queue pressure are proven not sent" {
    var scheduler = try Scheduler.init(test_profile);
    var guard = testGuard();
    guard.current_order_revision = 2;
    const stale = scheduler.enqueue(testCommand(1, .{ .cancel = .{} }), guard, 1);
    try std.testing.expectEqual(RejectReason.stale_order_revision, stale.dispatch.reason.?);

    var expired = testCommand(2, .{ .cancel = .{} });
    expired.dispatch_deadline_monotonic_ns = 1;
    const deadline = scheduler.enqueue(expired, testGuard(), 1);
    try std.testing.expectEqual(RejectReason.deadline_expired, deadline.dispatch.reason.?);

    var index: u64 = 0;
    while (index < safety_queue_capacity) : (index += 1)
        try std.testing.expect(scheduler.enqueue(
            testCommand(100 + index, .{ .cancel = .{} }),
            testGuard(),
            1,
        ) == .queued);
    const full = scheduler.enqueue(testCommand(999, .{ .cancel = .{} }), testGuard(), 1);
    try std.testing.expectEqual(RejectReason.adapter_backpressure, full.dispatch.reason.?);
}

test "batch response is itemized and transport ambiguity makes every item unknown" {
    var batch: TransportBatch = .{};
    batch.commands[0] = testCommand(1, .{ .cancel = .{} });
    batch.commands[1] = testCommand(2, .{ .cancel = .{} });
    batch.count = 2;
    const request = try encode(&batch);
    const response = try classifyResponse(
        std.testing.allocator,
        &request,
        40,
        .response,
        "{\"code\":\"2\",\"data\":[{\"sCode\":\"0\"},{\"sCode\":\"50011\"}]}",
    );
    try std.testing.expectEqual(DispatchState.submitted, response.items[0].state);
    try std.testing.expectEqual(DispatchState.submitted, response.items[1].state);
    try std.testing.expectEqual(RejectReason.rate_limited, response.items[1].reason.?);

    const unknown = try classifyResponse(
        std.testing.allocator,
        &request,
        50,
        .write_or_response_uncertain,
        null,
    );
    try std.testing.expectEqual(DispatchState.unknown, unknown.items[0].state);
    try std.testing.expectEqual(DispatchState.unknown, unknown.items[1].state);

    var place_batch: TransportBatch = .{};
    place_batch.commands[0] = testCommand(3, limitPlace(false));
    place_batch.count = 1;
    const place_request = try encode(&place_batch);
    const incomplete_ack = try classifyResponse(
        std.testing.allocator,
        &place_request,
        60,
        .response,
        "{\"code\":\"0\",\"data\":[{\"sCode\":\"0\",\"ordId\":\"\"}]}",
    );
    try std.testing.expectEqual(DispatchState.unknown, incomplete_ack.items[0].state);
}

test "cancel confirm create cannot overlap or reuse the old order" {
    var gate: ReplacementGate = .{ .old_order_id = 7, .old_revision = 3 };
    try std.testing.expect(!gate.mayCreateReplacement());
    try gate.cancelQueued();
    try std.testing.expectError(error.InvalidTransition, gate.observeTerminal(8, 3));
    try gate.observeTerminal(7, 4);
    try std.testing.expect(gate.mayCreateReplacement());

    var unknown: ReplacementGate = .{ .old_order_id = 9, .old_revision = 1 };
    try unknown.cancelQueued();
    unknown.observeUnknown();
    try std.testing.expect(!unknown.mayCreateReplacement());
    try unknown.observeTerminal(9, 1);
    try std.testing.expect(unknown.mayCreateReplacement());
}
