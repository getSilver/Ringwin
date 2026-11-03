//! Bounded Hyperliquid execution and private facts; runtime supplies transport.
const std = @import("std");
const c = @import("../../model/canonical_event.zig");
const venue = @import("../../execution/venue_adapter.zig");
const signer = @import("hyperliquid_signer.zig");
pub const Times = struct { receive_time_utc_ns: u64, monotonic_time_ns: u64, wall_time_utc_ns: u64 };
pub const RawError = error{ Unavailable, Backpressure };
pub const Input = enum { exchange, orders, fills, account, spot_account, account_mode, funding, user_events, ledger, order_status };
pub const RawRecord = struct {
    venue: u64,
    environment: venue.Environment,
    account: u128,
    funding: [20]u8,
    session: u128,
    source_session: u64,
    input: Input,
    times: Times,
    byte_len: u32,
    sha256: [32]u8,
};
pub const RawSink = struct {
    ptr: *anyopaque,
    append_fn: *const fn (*anyopaque, RawRecord, []const u8) RawError!u64,
};
pub const Binding = struct {
    instrument: u128,
    coin: []const u8,
    wire_asset: u32,
    product: c.Product,
    size_decimals: u8,
    price_scale: u8,
    tick_atoms: i128,
    quantity_scale: u8,
    lot_atoms: i128,
};
pub const Profile = struct {
    venue: u64,
    account: u128,
    session: u64,
    funding: [20]u8,
    environment: venue.Environment,
    bindings: []const Binding,
    version: u64,
    rules_version: u64,
    config_version: u64,
    can_read: bool = true,
    can_trade: bool = false,
    bootstrap_identity: u128 = 0,
    /// Owner-approved native token index -> activated Asset, never inferred from a name.
    tokens: []const TokenBinding = &.{},
};
pub const TokenBinding = struct { index: u32, asset: c.AssetIdentity };
/// Runtime implements this with Signer.sign; it must persist the nonce before returning.
pub const Authorizer = struct {
    ptr: *anyopaque,
    sign_fn: *const fn (*anyopaque, signer.Request) anyerror!signer.SignedAction,
    check_fn: *const fn (*anyopaque, u64, u64, bool) anyerror!void,
};
/// Borrowed secure resources from the existing credential lifecycle; no secret copies.
pub const WalletAuthorization = struct {
    wallet: signer.Signer,
    store: *@import("../../security/credential_store.zig").CredentialStore,
    io: std.Io,
    password_file: std.Io.File,
    input_kind: @import("../../security/credential_store.zig").InputKind,
    password_buffer: []u8,
    runtime: @import("../../security/credential_store.zig").RuntimeContext,
    guard: *@import("../../runtime/failover.zig").GatewayLeaseGuard,
    pub fn interface(self: *@This()) Authorizer {
        return .{ .ptr = self, .sign_fn = sign, .check_fn = check };
    }
    fn sign(ptr: *anyopaque, request: signer.Request) !signer.SignedAction {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        defer std.crypto.secureZero(u8, self.password_buffer);
        if (self.wallet.metadata.environment != .testnet) return error.UnsupportedEnvironment;
        return self.wallet.sign(self.store, self.io, self.password_file, self.input_kind, self.password_buffer, self.runtime, self.guard, request);
    }
    fn check(ptr: *anyopaque, now: u64, token: u64, increases_risk: bool) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (token != self.wallet.owner_token or self.guard.lease.key.exchange_account != self.wallet.metadata.account) return error.StaleFencingToken;
        try self.guard.check(now, token, increases_risk);
    }
};
pub const TransportResult = struct {
    outcome: enum { proven_before_send, response, uncertain },
    bytes: ?[]const u8 = null,
    session: u64,
    times: Times,
};
pub const SignedRequest = struct { action_json: []const u8, signed: signer.SignedAction };
pub const Transport = struct {
    ptr: *anyopaque,
    submit_fn: *const fn (*anyopaque, SignedRequest) TransportResult,
    query_fn: *const fn (*anyopaque, []const u8) TransportResult,
};
pub const Clock = struct { ptr: *anyopaque, now_fn: *const fn (*anyopaque) Times };
/// Shared by all clients at this egress; runtime must reserve an aggregate IP budget.
pub const Budget = struct {
    start: u64 = 0,
    used: u16 = 0,
    limit: u16 = 100,
    fn take(self: *Budget, now: u64, cancel: bool, weight: u16) bool {
        if (self.limit < 2 or self.limit > 1200 or now < self.start) return false;
        if (now - self.start >= 60 * std.time.ns_per_s) {
            self.start = now;
            self.used = 0;
        }
        const ceiling = self.limit - @as(u16, if (cancel) 0 else 1);
        if (weight > ceiling -| self.used) return false;
        self.used += weight;
        return true;
    }
};
const Order = struct { command: c.OrderCommand, oid: ?u64 = null, sent: bool = false, unknown: bool = false };
const Seen = struct { identity: u128, event: c.Payload, reported_pnl: ?c.Decimal };

pub const HyperliquidVenueAdapter = struct {
    profile: Profile,
    clock: Clock,
    auth: Authorizer,
    raw_sink: RawSink,
    transport: Transport,
    budget: *Budget,
    state: enum { idle, running, stopped } = .idle,
    assets: @import("../../trading/asset_registry.zig").Registry = .{},
    instruments: @import("../../trading/instrument_registry.zig").Registry = .{},
    pending: ?c.AdapterOutputBatch = null,
    sequence: u64 = 0,
    raw_sequence: u64 = 0,
    failed: bool = false,
    // shortcut: retain 64 orders and 128 private facts; exhaustion fails closed until durable recovery in 06.
    orders: [64]Order = undefined,
    order_count: usize = 0,
    seen: [128]Seen = undefined,
    seen_count: usize = 0,
    fencing_token: u64 = 0,

    pub fn adapter(self: *@This()) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop, .prepare_client_order_id = prepareCloid } };
    }
    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        const p = self.profile;
        if ((p.environment == .demo and (!config.native_settlement_atoms or config.instrument_definitions == null)) or self.fencing_token == 0 or p.venue == 0 or p.account == 0 or p.session == 0 or p.version == 0 or p.rules_version == 0 or p.config_version == 0 or
            std.mem.allEqual(u8, &p.funding, 0) or config.venue != p.venue or config.exchange_account != p.account or
            config.adapter_session != p.session or config.environment != p.environment or config.request_capacity == 0 or config.output_capacity == 0 or
            p.bindings.len == 0 or p.bindings.len > 8) return error.InvalidConfig;
        self.assets = config.asset_definitions orelse return error.InvalidConfig;
        self.assets.validate() catch return error.InvalidConfig;
        if (p.tokens.len > 8) return error.InvalidConfig;
        for (p.tokens, 0..) |token, index| {
            if (!self.assets.hasVenueCode(token.asset, p.venue)) return error.InvalidConfig;
            for (p.tokens[0..index]) |prior| if (prior.index == token.index or prior.asset == token.asset) return error.InvalidConfig;
        }
        self.instruments = config.instrument_definitions orelse .{};
        self.instruments.validate() catch return error.InvalidConfig;
        for (p.bindings, 0..) |b, index| {
            const max: u8 = if (b.product == .spot) 8 else 6;
            if (b.instrument == 0 or b.coin.len == 0 or b.coin.len > 32 or b.size_decimals > max or b.price_scale > 38 or b.quantity_scale > 38 or b.tick_atoms <= 0 or b.lot_atoms <= 0 or
                (b.product == .spot and b.wire_asset < 10000) or (b.product == .isolated_linear and b.wire_asset >= 10000)) return error.InvalidConfig;
            for (b.coin) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '@' and byte != '/' and byte != '-') return error.InvalidConfig;
            for (p.bindings[0..index]) |prior| if (prior.instrument == b.instrument or prior.wire_asset == b.wire_asset or std.mem.eql(u8, prior.coin, b.coin)) return error.InvalidConfig;
            if (self.instruments.get(b.instrument)) |entry| {
                if (entry.venue != p.venue or entry.product != b.product) return error.InvalidConfig;
                self.instruments.validateVenueUnits(&self.assets, b.instrument, p.rules_version, .{ .coefficient = b.lot_atoms, .scale = b.quantity_scale }, .{ .coefficient = b.tick_atoms, .scale = b.price_scale }) catch return error.InvalidConfig;
            } else if (config.native_settlement_atoms) return error.InvalidConfig;
        }
        self.state = .running;
    }
    fn send(ptr: *anyopaque, request: c.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.state == .stopped) return .stopped;
        if (self.pending != null) return .backpressure;
        var output: c.AdapterOutputBatch = .{};
        switch (request) {
            .order_reconciliation => |r| {
                if (r.exchange_account != self.profile.account or !self.profile.can_read) return error.InvalidRequest;
                if (self.order(r.order)) |known| {
                    var query_bytes: [256]u8 = undefined;
                    const address = std.fmt.bytesToHex(self.profile.funding, .lower);
                    const request_bytes = std.fmt.bufPrint(&query_bytes, "{{\"type\":\"orderStatus\",\"user\":\"0x{s}\",\"oid\":\"{s}\"}}", .{ address, known.command.client_order_id.slice() }) catch return error.InvalidRequest;
                    self.query(&output, .order_status, request_bytes);
                }
                self.append(&output, .{ .order_reconciliation_result = .{ .identity = r.identity, .order = r.order, .complete = false } }, null, self.clock.now_fn(self.clock.ptr), null) catch return error.InvalidRequest;
            },
            .account_reconciliation => |r| {
                if (r.exchange_account != self.profile.account or r.expected_session != self.profile.session or !self.profile.can_read) return error.InvalidRequest;
                const address = std.fmt.bytesToHex(self.profile.funding, .lower);
                var query_bytes: [256]u8 = undefined;
                for ([_]Input{ .account, .spot_account }) |input| {
                    const request_bytes = std.fmt.bufPrint(&query_bytes, "{{\"type\":\"{s}\",\"user\":\"0x{s}\"}}", .{ if (input == .account) "clearinghouseState" else "spotClearinghouseState", address }) catch return error.InvalidRequest;
                    self.query(&output, input, request_bytes);
                }
                self.append(&output, .{ .account_reconciliation_result = .{ .identity = r.identity, .complete = false } }, null, self.clock.now_fn(self.clock.ptr), null) catch return error.InvalidRequest;
            },
            .order_command => |command| self.dispatch(&output, command),
            .order_batch => |batch| {
                if (batch.len == 0 or batch.len > c.max_order_commands_per_batch) return error.InvalidRequest;
                for (batch.slice()) |command| self.dispatch(&output, command);
            },
        }
        self.pending = output;
        return .accepted;
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?c.AdapterOutputBatch {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const pending = self.pending;
        self.pending = null;
        return pending;
    }
    fn stop(ptr: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.state = .stopped;
    }
    fn binding(self: *const @This(), instrument: u128) !Binding {
        for (self.profile.bindings) |b| if (b.instrument == instrument) return b;
        return error.UnsupportedInstrument;
    }
    fn order(self: *@This(), identity: u128) ?*Order {
        for (self.orders[0..self.order_count]) |*o| if (o.command.orderIdentity() == identity) return o;
        return null;
    }
    fn validate(self: *@This(), command: c.OrderCommand, now: Times) !Binding {
        if (!self.profile.can_read or !self.profile.can_trade) return error.Unavailable;
        if (command.identity == 0 or command.orderIdentity() == 0 or command.exchange_account != self.profile.account or command.adapter_session != self.profile.session or
            command.capability_version != self.profile.version or command.rules_version != self.profile.rules_version or command.config_version != self.profile.config_version) return error.StaleVersion;
        if (now.monotonic_time_ns >= command.dispatch_deadline_monotonic_ns) return error.Expired;
        try checkCloid(command.client_order_id);
        const b = try self.binding(command.instrument);
        if (command.operation == .amend) return error.Unsupported;
        if (command.operation == .cancel) {
            const existing = self.order(command.orderIdentity()) orelse return error.UnknownOrder;
            if (existing.command.instrument != command.instrument or !std.meta.eql(existing.command.client_order_id, command.client_order_id)) return error.OrderConflict;
            return b;
        }
        if (self.failed) return error.Unavailable;
        for (self.orders[0..self.order_count]) |existing| if (existing.unknown) return error.Unavailable;
        if (self.order(command.orderIdentity())) |known| {
            if (known.sent or !std.meta.eql(known.command, command)) return error.UnknownOrder;
        } else if (self.order_count == self.orders.len) return error.Capacity;
        for (self.orders[0..self.order_count]) |known| if (known.command.orderIdentity() != command.orderIdentity() and std.meta.eql(known.command.client_order_id, command.client_order_id)) return error.OrderConflict;
        const tif: c.TimeInForce = switch (command.order_type) {
            .limit => .good_til_canceled,
            .ioc => .immediate_or_cancel,
            .post_only => .post_only,
            else => return error.Unsupported,
        };
        if (tif != command.time_in_force or command.market_protection_price != null or (command.venue_reduce_only and b.product != .isolated_linear)) return error.Unsupported;
        const qty = command.quantity orelse return error.InvalidQuantity;
        const px = command.limit_price orelse return error.InvalidPrice;
        if (qty.instrument != b.instrument or px.instrument != b.instrument or qty.rules_version != self.profile.rules_version or px.rules_version != self.profile.rules_version or qty.lots <= 0) return error.InvalidQuantity;
        _ = try (c.Decimal{ .coefficient = try std.math.mul(i128, qty.lots, b.lot_atoms), .scale = b.quantity_scale }).exactAtoms(b.size_decimals);
        try (c.PriceConstraints{ .max_significant_digits = 5, .max_decimal_places = (if (b.product == .spot) @as(u8, 8) else 6) - b.size_decimals, .integer_exception = true }).validate(px.ticks, b.tick_atoms, b.price_scale);
        if (self.instruments.count != 0 and !self.instruments.permitsEconomicUnits(&self.assets, b.instrument)) return error.Unavailable;
        return b;
    }
    fn dispatch(self: *@This(), output: *c.AdapterOutputBatch, command: c.OrderCommand) void {
        const now = self.clock.now_fn(self.clock.ptr);
        const b = self.validate(command, now) catch |err| {
            self.dispatchResult(output, command, .not_sent, switch (err) {
                error.StaleVersion => .stale_version,
                error.Expired => .deadline_expired,
                error.Unsupported => .capability_unsupported,
                else => .unsupported_value,
            }, now, null);
            return;
        };
        if (!self.budget.take(now.monotonic_time_ns, command.operation == .cancel, 1)) {
            self.dispatchResult(output, command, .not_sent, .adapter_backpressure, now, null);
            return;
        }
        const encoded = encode(command, b) catch {
            self.dispatchResult(output, command, .not_sent, .unsupported_value, now, null);
            return;
        };
        const signed = self.auth.sign_fn(self.auth.ptr, .{ .command_identity = command.identity, .session = self.profile.session, .environment = .testnet, .action = encoded.msgpack[0..encoded.msgpack_len], .now_ms = now.wall_time_utc_ns / std.time.ns_per_ms, .now_monotonic_ns = now.monotonic_time_ns, .fencing_token = self.fencing_token, .increases_risk = command.operation != .cancel }) catch {
            self.dispatchResult(output, command, .not_sent, .venue_unavailable, now, null);
            return;
        };
        const send_time = self.clock.now_fn(self.clock.ptr);
        self.auth.check_fn(self.auth.ptr, send_time.monotonic_time_ns, self.fencing_token, command.operation != .cancel) catch {
            self.dispatchResult(output, command, .not_sent, .venue_unavailable, send_time, null);
            return;
        };
        if (signed.session != self.profile.session or !std.mem.eql(u8, &signed.funding_account, &self.profile.funding) or send_time.monotonic_time_ns >= command.dispatch_deadline_monotonic_ns or !self.profile.can_trade) {
            self.dispatchResult(output, command, .not_sent, .stale_version, now, null);
            return;
        }
        if (self.order(command.orderIdentity()) == null) {
            self.orders[self.order_count] = .{ .command = command };
            self.order_count += 1;
        }
        const existing = self.order(command.orderIdentity()).?;
        const response = self.transport.submit_fn(self.transport.ptr, .{ .action_json = encoded.json[0..encoded.json_len], .signed = signed });
        if (response.outcome == .proven_before_send) {
            self.dispatchResult(output, command, .not_sent, .venue_unavailable, response.times, null);
            return;
        }
        existing.sent = true;
        const evidence = if (response.bytes) |bytes| self.capture(.exchange, response.times, bytes, response.session) catch null else null;
        if (response.outcome != .response or response.session != self.profile.session or evidence == null) {
            existing.unknown = true;
            self.dispatchResult(output, command, .unknown, null, response.times, evidence);
            return;
        }
        var buffer: [65536]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&buffer);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator.allocator(), response.bytes.?, .{}) catch {
            existing.unknown = true;
            self.dispatchResult(output, command, .unknown, null, response.times, evidence);
            return;
        };
        var facts: c.AdapterOutputBatch = .{};
        var staged = self.*;
        staged.sequence += 1; // Reserve the preceding dispatch result in this source stream.
        staged.exchange(&facts, command, parsed.value, response.times, evidence.?) catch {
            existing.unknown = true;
            self.dispatchResult(output, command, .unknown, null, response.times, evidence);
            return;
        };
        self.dispatchResult(output, command, if (command.operation == .place and staged.order(command.orderIdentity()).?.unknown) .unknown else .submitted, null, response.times, evidence);
        self.sequence = staged.sequence;
        self.orders = staged.orders;
        for (facts.slice()) |record| output.append(record) catch unreachable;
    }

    fn dispatchResult(self: *@This(), output: *c.AdapterOutputBatch, command: c.OrderCommand, state: c.DispatchState, reason: ?c.CanonicalRejectReason, times: Times, evidence: ?c.RawEvidenceRef) void {
        self.append(output, .{ .order_dispatch_result = .{ .command = command.identity, .client_order_id = command.client_order_id, .state = state, .reason = reason } }, command.instrument, times, evidence) catch unreachable;
    }
    fn capture(self: *@This(), input: Input, times: Times, bytes: []const u8, source_session: u64) !c.RawEvidenceRef {
        if (bytes.len == 0 or bytes.len > 65536) return error.FrameTooLarge;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const seq = try self.raw_sink.append_fn(self.raw_sink.ptr, .{ .venue = self.profile.venue, .environment = self.profile.environment, .account = self.profile.account, .funding = self.profile.funding, .session = self.profile.session, .source_session = source_session, .input = input, .times = times, .byte_len = @intCast(bytes.len), .sha256 = digest }, bytes);
        if (seq <= self.raw_sequence) return error.InvalidRawSequence;
        self.raw_sequence = seq;
        return .{ .stream = self.profile.session, .sequence = seq, .digest = digest };
    }
    fn query(self: *@This(), output: *c.AdapterOutputBatch, input: Input, request: []const u8) void {
        if (!self.budget.take(self.clock.now_fn(self.clock.ptr).monotonic_time_ns, false, 2)) return;
        const response = self.transport.query_fn(self.transport.ptr, request);
        if (response.outcome != .response or response.bytes == null or response.session != self.profile.session) return;
        const evidence = self.capture(input, response.times, response.bytes.?, response.session) catch {
            self.failed = true;
            self.append(output, .{ .economic_fault = .{ .reason = .persistence_failure } }, null, response.times, null) catch unreachable;
            return;
        };
        var buffer: [131072]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&buffer);
        var staged = self.*;
        var facts: c.AdapterOutputBatch = .{};
        staged.decode(allocator.allocator(), &facts, input, response.times, evidence, response.bytes.?) catch {
            self.failed = true;
            self.append(output, .{ .economic_fault = .{ .reason = .decoder_rejected } }, null, response.times, evidence) catch unreachable;
            return;
        };
        self.sequence = staged.sequence;
        self.orders = staged.orders;
        self.seen = staged.seen;
        self.seen_count = staged.seen_count;
        for (facts.slice()) |fact| output.append(fact) catch unreachable;
    }
    fn append(self: *@This(), output: *c.AdapterOutputBatch, event: c.Payload, instrument: ?u128, times: Times, evidence: ?c.RawEvidenceRef) !void {
        self.sequence = try std.math.add(u64, self.sequence, 1);
        const identity: u128 = switch (event) {
            .execution_report => |v| v.identity,
            .fill => |v| v.identity,
            .venue_account_configuration_snapshot => |v| v.identity,
            else => self.sequence,
        };
        try output.append(.{ .envelope = .{ .event_type = @intFromEnum(c.eventType(event)), .schema_version = c.schema_version, .identity = .{ .stream = self.profile.session, .sequence = self.sequence }, .source_fact_identity = identity, .scope = .account, .venue = self.profile.venue, .exchange_account = self.profile.account, .instrument = instrument, .source_stream = self.profile.session, .source_sequence = self.sequence, .adapter_session = self.profile.session, .times = .{ .receive_utc_ns = times.receive_time_utc_ns, .monotonic_ns = times.monotonic_time_ns, .audit_utc_ns = times.wall_time_utc_ns }, .raw_evidence = evidence orelse .{ .stream = self.profile.session, .sequence = self.sequence, .digest = @splat(0) } }, .event = event });
    }
    fn exchange(self: *@This(), output: *c.AdapterOutputBatch, command: c.OrderCommand, root: std.json.Value, times: Times, evidence: c.RawEvidenceRef) !void {
        if (!eq(try field(root, "status"), "ok")) return error.UncertainResponse;
        const response = try field(root, "response");
        if (!eq(try field(response, "type"), if (command.operation == .cancel) "cancel" else "order")) return error.UncertainResponse;
        const statuses = try array(try field(try field(response, "data"), "statuses"));
        if (statuses.len != 1) return error.UncertainResponse;
        const status = statuses[0];
        if (command.operation == .cancel) {
            // Cancel acknowledgement has no final quantity evidence; wait for orderUpdates.
            if (!eq(status, "success") and !(status == .object and status.object.contains("error"))) return error.UncertainResponse;
            return;
        }
        if (status != .object) return error.UncertainResponse;
        if (status.object.count() != 1) return error.UncertainResponse;
        if (status.object.get("error")) |reason| {
            _ = try string(reason);
            const report = self.makeReport(command, null, .rejected, 0, command.quantity.?.lots, factId(self.profile, command.instrument, command.orderIdentity(), command.identity, 0, "rest-reject"));
            try self.append(output, .{ .execution_report = report }, command.instrument, times, evidence);
        } else if (status.object.get("resting")) |value| {
            try checkResponseCloid(value, command.client_order_id);
            const oid = try uint(try field(value, "oid"));
            try self.bindOid(command.orderIdentity(), oid);
            try self.append(output, .{ .execution_report = self.makeReport(command, oid, .accepted, 0, command.quantity.?.lots, factId(self.profile, command.instrument, oid, 0, 0, "resting")) }, command.instrument, times, evidence);
        } else if (status.object.get("filled")) |value| {
            try checkResponseCloid(value, command.client_order_id);
            const oid = try uint(try field(value, "oid"));
            try self.bindOid(command.orderIdentity(), oid);
            const b = try self.binding(command.instrument);
            const filled = try quantity(b, self.profile.rules_version, try string(try field(value, "totalSz")));
            const average = try price(b, self.profile.rules_version, try string(try field(value, "avgPx")));
            if (filled.lots <= 0 or filled.lots > command.quantity.?.lots) return error.UncertainResponse;
            if (filled.lots < command.quantity.?.lots) {
                // Keep the proved oid for independent Fill; the aggregate cannot prove the remainder's terminal state.
                self.order(command.orderIdentity()).?.unknown = true;
                return;
            }
            var report = self.makeReport(command, oid, .filled, filled.lots, 0, factId(self.profile, command.instrument, oid, 0, 0, "rest-filled"));
            report.average_fill_price = average;
            try self.append(output, .{ .execution_report = report }, command.instrument, times, evidence);
        } else return error.UncertainResponse;
    }
    fn bindOid(self: *@This(), identity: u128, oid: u64) !void {
        if (oid == 0) return error.InvalidOrder;
        const existing = self.order(identity) orelse return error.UnknownOrder;
        if (existing.oid) |known| if (known != oid) return error.OrderConflict;
        for (self.orders[0..self.order_count]) |other| if (other.command.orderIdentity() != identity and other.oid != null and other.oid.? == oid) return error.OrderConflict;
        existing.oid = oid;
    }
    /// Transport authenticates the route; frames cannot select another account/session.
    pub fn ingest(self: *@This(), allocator: std.mem.Allocator, session: u64, funding: [20]u8, input: Input, times: Times, bytes: []const u8) !void {
        if (self.state != .running) return error.NotStarted;
        if (self.pending != null) return error.OutputCapacityExceeded;
        if (session != self.profile.session or !std.mem.eql(u8, &funding, &self.profile.funding)) return error.StaleSession;
        const evidence = self.capture(input, times, bytes, session) catch |err| {
            self.fault(times, null, .persistence_failure);
            return err;
        };
        var staged = self.*;
        var output: c.AdapterOutputBatch = .{};
        staged.decode(allocator, &output, input, times, evidence, bytes) catch |err| {
            self.fault(times, evidence, .decoder_rejected);
            return err;
        };
        staged.pending = output;
        self.* = staged;
    }
    fn fault(self: *@This(), times: Times, evidence: ?c.RawEvidenceRef, reason: c.EconomicFaultReason) void {
        self.failed = true;
        var output: c.AdapterOutputBatch = .{};
        self.append(&output, .{ .economic_fault = .{ .reason = reason } }, null, times, evidence) catch unreachable;
        self.pending = output;
    }
    fn decode(self: *@This(), allocator: std.mem.Allocator, output: *c.AdapterOutputBatch, input: Input, times: Times, evidence: c.RawEvidenceRef, bytes: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always, .max_value_len = 65536 });
        defer parsed.deinit();
        var data = parsed.value;
        if (data == .object and data.object.contains("channel")) {
            const channel = try field(data, "channel");
            const expected = switch (input) {
                .orders => "orderUpdates",
                .fills => "userFills",
                .account => "clearinghouseState",
                .spot_account => "spotState",
                else => return error.UnsupportedFact,
            };
            if (!eq(channel, expected)) return error.UnsupportedFact;
            data = try field(data, "data");
        }
        switch (input) {
            .order_status => {
                if (eq(try field(data, "status"), "unknownOid")) return;
                if (!eq(try field(data, "status"), "order")) return error.InvalidFrame;
                try self.orderUpdate(output, try field(data, "order"), times, evidence);
            },
            .orders => {
                const rows = try array(data);
                if (rows.len > 16) return error.FrameTooLarge;
                for (rows) |row| try self.orderUpdate(output, row, times, evidence);
            },
            .fills => {
                if (data == .object) {
                    try self.checkUser(try field(data, "user"));
                    if (data.object.get("isSnapshot")) |snapshot| if (snapshot != .bool) return error.InvalidFrame;
                    data = try field(data, "fills");
                }
                const rows = try array(data);
                if (rows.len > 16) return error.FrameTooLarge;
                for (rows) |row| try self.fillUpdate(output, row, times, evidence);
            },
            .account => try self.accountUpdate(output, data, times, evidence),
            .spot_account => try self.spotUpdate(output, data, times, evidence),
            .account_mode => {
                if (!eq(data, "default")) return error.UnsupportedAccountMode;
                // Default abstraction alone proves neither trading permission nor isolated leverage.
            },
            // No stable funding bill or complete forced-execution provenance in the approved contract.
            .funding, .user_events, .ledger, .exchange => return error.UnsupportedFact,
        }
    }
    fn checkUser(self: *const @This(), value: std.json.Value) !void {
        const text = try string(value);
        if (text.len != 42 or !std.mem.startsWith(u8, text, "0x")) return error.WrongAccount;
        var address: [20]u8 = undefined;
        _ = std.fmt.hexToBytes(&address, text[2..]) catch return error.WrongAccount;
        if (!std.mem.eql(u8, &address, &self.profile.funding)) return error.WrongAccount;
    }
    fn byCoin(self: *const @This(), coin: std.json.Value) !Binding {
        for (self.profile.bindings) |b| if (eq(coin, b.coin)) return b;
        return error.UnsupportedInstrument;
    }
    fn findWireOrder(self: *@This(), row: std.json.Value, oid: u64) !*Order {
        if (row == .object) if (row.object.get("cloid")) |value| {
            if (value != .null) {
                const cloid = try c.ClientOrderId.init(try string(value));
                try checkCloid(cloid);
                for (self.orders[0..self.order_count]) |*known| if (std.meta.eql(known.command.client_order_id, cloid)) {
                    try self.bindOid(known.command.orderIdentity(), oid);
                    return known;
                };
                return error.UnknownOrder;
            }
        };
        for (self.orders[0..self.order_count]) |*known| if (known.oid != null and known.oid.? == oid) return known;
        return error.UnknownOrder;
    }
    fn unique(self: *@This(), identity: u128, event: c.Payload, reported_pnl: ?c.Decimal) !bool {
        for (self.seen[0..self.seen_count]) |known| if (known.identity == identity) {
            if (!std.meta.eql(known.event, event) or !std.meta.eql(known.reported_pnl, reported_pnl)) return error.FactConflict;
            return false;
        };
        if (self.seen_count == self.seen.len) return error.FactCapacity;
        self.seen[self.seen_count] = .{ .identity = identity, .event = event, .reported_pnl = reported_pnl };
        self.seen_count += 1;
        return true;
    }
    fn orderUpdate(self: *@This(), output: *c.AdapterOutputBatch, row: std.json.Value, times: Times, evidence: c.RawEvidenceRef) !void {
        const wire = try field(row, "order");
        const oid = try uint(try field(wire, "oid"));
        const known = try self.findWireOrder(wire, oid);
        const command = known.command;
        for ([_][]const u8{ "isTrigger", "isPositionTpsl" }) |name| if (wire.object.get(name)) |value| {
            if (value != .bool or value.bool) return error.UnsupportedOrderKind;
        };
        if (wire.object.get("children")) |value| if ((try array(value)).len != 0) return error.UnsupportedOrderKind;
        if (wire.object.get("triggerPx")) |value| if ((try c.Decimal.parse(try string(value))).coefficient != 0) return error.UnsupportedOrderKind;
        if (wire.object.get("orderType")) |value| if (!eq(value, "Limit")) return error.UnsupportedOrderKind;
        if (wire.object.get("reduceOnly")) |value| if (value != .bool or value.bool != command.venue_reduce_only) return error.OrderConflict;
        if (wire.object.get("tif")) |value| if (!eq(value, switch (command.time_in_force) {
            .good_til_canceled => "Gtc",
            .immediate_or_cancel => "Ioc",
            .post_only => "Alo",
            else => return error.UnsupportedOrderKind,
        })) return error.OrderConflict;
        const b = try self.byCoin(try field(wire, "coin"));
        if (b.instrument != command.instrument or !eq(try field(wire, "side"), if (command.side == .buy) "B" else "A")) return error.OrderConflict;
        const original = try quantity(b, self.profile.rules_version, try string(try field(wire, "origSz")));
        const remaining = try quantity(b, self.profile.rules_version, try string(try field(wire, "sz")));
        const px = try price(b, self.profile.rules_version, try string(try field(wire, "limitPx")));
        if (original.lots != command.quantity.?.lots or remaining.lots > original.lots or !std.meta.eql(px, command.limit_price.?)) return error.OrderConflict;
        const cumulative = original.lots - remaining.lots;
        const status_text = try string(try field(row, "status"));
        const status = try orderStatus(status_text, cumulative, remaining.lots);
        const time = try uint(try field(row, "statusTimestamp"));
        if (time == 0) return error.InvalidFrame;
        const identity = factId(self.profile, b.instrument, oid, time, 0, status_text);
        var report = self.makeReport(command, oid, status, cumulative, remaining.lots, identity);
        report.venue_update_time_utc_ns = try std.math.mul(u64, time, std.time.ns_per_ms);
        report.venue_create_time_utc_ns = try std.math.mul(u64, try uint(try field(wire, "timestamp")), std.time.ns_per_ms);
        if (try self.unique(identity, .{ .execution_report = report }, null)) try self.append(output, .{ .execution_report = report }, b.instrument, times, evidence);
    }
    fn fillUpdate(self: *@This(), output: *c.AdapterOutputBatch, row: std.json.Value, times: Times, evidence: c.RawEvidenceRef) !void {
        if (row != .object) return error.InvalidFrame;
        if (row.object.get("twapId")) |value| if (value != .null) return error.UnsupportedOrderKind;
        if (row.object.get("liquidation")) |v| if (v != .null) return error.UnsupportedForcedExecution;
        const dir = try string(try field(row, "dir"));
        const directions = [_][]const u8{ "Open Long", "Close Long", "Open Short", "Close Short", "Long > Short", "Short > Long", "Buy", "Sell" };
        var supported = false;
        for (directions) |v| {
            if (std.mem.eql(u8, dir, v)) supported = true;
        }
        if (!supported) return error.UnsupportedForcedExecution;
        const b = try self.byCoin(try field(row, "coin"));
        const oid = try uint(try field(row, "oid"));
        const known = try self.findWireOrder(row, oid);
        if (known.command.instrument != b.instrument) return error.OrderConflict;
        const side: c.OrderSide = if (eq(try field(row, "side"), "B")) .buy else if (eq(try field(row, "side"), "A")) .sell else return error.InvalidFrame;
        if (side != known.command.side) return error.OrderConflict;
        const time = try uint(try field(row, "time"));
        const tid = try uint(try field(row, "tid"));
        if (time == 0 or tid == 0) return error.InvalidFrame;
        const identity = factId(self.profile, b.instrument, oid, time, tid, "fill");
        const fee_asset = try self.assets.resolveCode(self.profile.venue, try string(try field(row, "feeToken")));
        const fee = try self.assets.amount(fee_asset, try c.Decimal.parse(try string(try field(row, "fee"))));
        var closed_pnl = try c.Decimal.parse(try string(try field(row, "closedPnl")));
        while (closed_pnl.scale > 0 and @rem(closed_pnl.coefficient, 10) == 0) {
            closed_pnl.coefficient = @divTrunc(closed_pnl.coefficient, 10);
            closed_pnl.scale -= 1;
        }
        if (row.object.get("builderFee")) |builder| if ((try c.Decimal.parse(try string(builder))).coefficient != 0) return error.UnsupportedBuilder;
        const crossed = try field(row, "crossed");
        if (crossed != .bool) return error.InvalidFrame;
        var text: [32]u8 = undefined;
        // Composite ID, not tid alone, is also the canonical venue-trade reference.
        var identity_bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &identity_bytes, identity, .big);
        const trade_hex = std.fmt.bytesToHex(identity_bytes, .lower);
        const qty = try quantity(b, self.profile.rules_version, try string(try field(row, "sz")));
        if (qty.lots <= 0) return error.InvalidQuantity;
        const fill: c.Fill = .{ .identity = identity, .order = known.command.orderIdentity(), .client_order_id = known.command.client_order_id, .venue_order = try c.VenueOrderRef.init(self.profile.venue, try std.fmt.bufPrint(&text, "{d}", .{oid})), .venue_trade = try c.VenueTradeRef.init(self.profile.venue, &trade_hex), .instrument = b.instrument, .exchange_account = self.profile.account, .side = side, .quantity = qty, .price = try price(b, self.profile.rules_version, try string(try field(row, "px"))), .fee = if (fee.atoms >= 0) fee else null, .rebate = if (fee.atoms < 0) .{ .asset = fee.asset, .atoms = try std.math.negate(fee.atoms) } else null, .liquidity = if (crossed.bool) .taker else .maker, .venue_fill_time_utc_ns = try std.math.mul(u64, time, std.time.ns_per_ms) };
        // Reported PnL participates in conflicts but is not a second local economic posting.
        if (try self.unique(identity, .{ .fill = fill }, closed_pnl)) try self.append(output, .{ .fill = fill }, b.instrument, times, evidence);
    }
    fn accountUpdate(self: *@This(), output: *c.AdapterOutputBatch, root: std.json.Value, times: Times, evidence: c.RawEvidenceRef) !void {
        var data = root;
        if (data == .object and data.object.contains("user")) {
            try self.checkUser(try field(data, "user"));
            if (data.object.get("dex")) |dex| if (!eq(dex, "")) return error.UnsupportedInstrument;
            data = try field(data, "clearinghouseState");
        }
        const rows = try array(try field(data, "assetPositions"));
        if (rows.len > 8) return error.FrameTooLarge;
        for (rows) |row| {
            if (!eq(try field(row, "type"), "oneWay")) return error.UnsupportedAccountMode;
            const position = try field(row, "position");
            const b = try self.byCoin(try field(position, "coin"));
            if (b.product != .isolated_linear) return error.UnsupportedInstrument;
            const leverage = try field(position, "leverage");
            if (!eq(try field(leverage, "type"), "isolated")) return error.UnsupportedAccountMode;
            const amount = try uint(try field(leverage, "value"));
            if (amount == 0) return error.InvalidFrame;
            const identity = factId(self.profile, b.instrument, 0, evidence.sequence, 0, "leverage");
            try self.append(output, .{ .venue_account_configuration_snapshot = .{ .identity = identity, .exchange_account = self.profile.account, .value = .{ .isolated_leverage = .{ .instrument = b.instrument, .position_mode_net = true, .margin_mode_isolated = true, .leverage = .{ .coefficient = amount, .scale = 0 } } } } }, b.instrument, times, evidence);
            if (self.profile.bootstrap_identity != 0) {
                const size = try c.Decimal.parse(try string(try field(position, "szi")));
                const atoms = try size.exactAtoms(b.quantity_scale);
                if (@rem(atoms, b.lot_atoms) != 0) return error.InvalidQuantity;
                const value: c.AccountPosition = .{ .instrument = b.instrument, .side = .net, .quantity = q(b.instrument, self.profile.rules_version, @divTrunc(atoms, b.lot_atoms)), .leverage = .{ .coefficient = amount, .scale = 0 } };
                try self.append(output, .{ .account_observed = .{ .identity = identity, .exchange_account = self.profile.account, .bootstrap = self.profile.bootstrap_identity, .source_stream = self.profile.session, .source_sequence = self.sequence + 1, .value = .{ .position = .{ .instrument = b.instrument, .side = .net, .value = value } } } }, b.instrument, times, evidence);
            }
        }
    }
    fn spotUpdate(self: *@This(), output: *c.AdapterOutputBatch, root: std.json.Value, times: Times, evidence: c.RawEvidenceRef) !void {
        if (self.profile.bootstrap_identity == 0) return error.MissingBootstrap;
        var data = root;
        if (data == .object and data.object.contains("user")) {
            try self.checkUser(try field(data, "user"));
            data = try field(data, "spotState");
        }
        const rows = try array(try field(data, "balances"));
        if (rows.len > 8) return error.FrameTooLarge;
        for (rows, 0..) |row, index| {
            const asset = try self.assets.resolveCode(self.profile.venue, try string(try field(row, "coin")));
            const native_token = try uint(try field(row, "token"));
            var matched = false;
            for (self.profile.tokens) |token| if (token.index == native_token and token.asset == asset) {
                matched = true;
                break;
            };
            if (!matched) return error.UnsupportedAsset;
            const total = try self.assets.amount(asset, try c.Decimal.parse(try string(try field(row, "total"))));
            const held = try self.assets.amount(asset, try c.Decimal.parse(try string(try field(row, "hold"))));
            if (total.atoms < 0 or held.atoms < 0 or held.atoms > total.atoms) return error.InvalidBalance;
            const identity = factId(self.profile, asset, index, evidence.sequence, 0, "balance");
            try self.append(output, .{ .account_observed = .{ .identity = identity, .exchange_account = self.profile.account, .bootstrap = self.profile.bootstrap_identity, .source_stream = self.profile.session, .source_sequence = self.sequence + 1, .value = .{ .balance = .{ .asset = asset, .value = .{ .asset = asset, .total = total, .held = held, .available = .{ .asset = asset, .atoms = total.atoms - held.atoms } } } } } }, null, times, evidence);
        }
    }
    fn makeReport(self: *const @This(), command: c.OrderCommand, oid: ?u64, status: c.ExecutionReportStatus, cumulative: i128, remaining: i128, identity: u128) c.ExecutionReport {
        var oid_buffer: [32]u8 = undefined;
        return .{ .identity = identity, .order = command.orderIdentity(), .client_order_id = command.client_order_id, .venue_order = if (oid) |v| c.VenueOrderRef.init(self.profile.venue, std.fmt.bufPrint(&oid_buffer, "{d}", .{v}) catch unreachable) catch unreachable else null, .instrument = command.instrument, .exchange_account = self.profile.account, .revision = command.revision, .side = command.side, .order_type = command.order_type, .time_in_force = command.time_in_force, .venue_reduce_only = command.venue_reduce_only, .portfolio_reduce_only = command.portfolio_reduce_only, .status = status, .reject_reason = if (status == .rejected) .other_venue_reject else null, .original_quantity = command.quantity, .cumulative_quantity = q(command.instrument, self.profile.rules_version, cumulative), .remaining_quantity = q(command.instrument, self.profile.rules_version, remaining), .limit_price = command.limit_price };
    }
};

fn checkCloid(id: c.ClientOrderId) !void {
    const text = id.slice();
    if (text.len != 34 or !std.mem.startsWith(u8, text, "0x")) return error.InvalidCloid;
    for (text[2..]) |byte| if (!std.ascii.isHex(byte)) return error.InvalidCloid;
}
fn checkResponseCloid(row: std.json.Value, expected: c.ClientOrderId) !void {
    if (row != .object) return error.InvalidFrame;
    if (row.object.get("cloid")) |value| if (!eq(value, expected.slice())) return error.OrderConflict;
}
fn orderStatus(text: []const u8, cumulative: i128, remaining: i128) !c.ExecutionReportStatus {
    if (std.mem.eql(u8, text, "open")) return if (cumulative == 0) .accepted else .partially_filled;
    if (std.mem.eql(u8, text, "filled")) {
        if (remaining != 0 or cumulative == 0) return error.InvalidQuantity;
        return .filled;
    }
    const canceled = [_][]const u8{ "canceled", "marginCanceled", "openInterestCapCanceled", "selfTradeCanceled", "reduceOnlyCanceled", "delistedCanceled", "liquidatedCanceled", "scheduledCancel" };
    for (canceled) |v| if (std.mem.eql(u8, text, v)) return .canceled;
    const rejected = [_][]const u8{ "rejected", "tickRejected", "minTradeNtlRejected", "perpMarginRejected", "reduceOnlyRejected", "badAloPxRejected", "iocCancelRejected", "badTriggerPxRejected", "marketOrderNoLiquidityRejected", "positionIncreaseAtOpenInterestCapRejected", "positionFlipAtOpenInterestCapRejected", "tooAggressiveAtOpenInterestCapRejected", "openInterestIncreaseRejected", "insufficientSpotBalanceRejected", "oracleRejected", "perpMaxPositionRejected" };
    for (rejected) |v| if (std.mem.eql(u8, text, v)) {
        if (cumulative != 0) return error.InvalidQuantity;
        return .rejected;
    };
    return error.UnsupportedStatus;
}
const Encoded = struct {
    json: [1024]u8 = undefined,
    json_len: usize = 0,
    msgpack: [1024]u8 = undefined,
    msgpack_len: usize = 0,
    fn byte(self: *@This(), value: u8) !void {
        if (self.msgpack_len == self.msgpack.len) return error.FrameTooLarge;
        self.msgpack[self.msgpack_len] = value;
        self.msgpack_len += 1;
    }
    fn text(self: *@This(), value: []const u8) !void {
        if (value.len < 32) try self.byte(0xa0 + @as(u8, @intCast(value.len))) else {
            try self.byte(0xd9);
            try self.byte(std.math.cast(u8, value.len) orelse return error.FrameTooLarge);
        }
        for (value) |v| try self.byte(v);
    }
    fn number(self: *@This(), value: u64) !void {
        if (value < 128) return self.byte(@intCast(value));
        const width: usize = if (value <= 255) 1 else if (value <= 65535) 2 else if (value <= 0xffffffff) 4 else 8;
        try self.byte(switch (width) {
            1 => 0xcc,
            2 => 0xcd,
            4 => 0xce,
            else => 0xcf,
        });
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .big);
        for (bytes[8 - width ..]) |v| try self.byte(v);
    }
};
fn encode(command: c.OrderCommand, b: Binding) !Encoded {
    var out: Encoded = .{};
    try out.byte(if (command.operation == .cancel) 0x82 else 0x83);
    try out.text("type");
    try out.text(if (command.operation == .cancel) "cancelByCloid" else "order");
    if (command.operation == .cancel) {
        try out.text("cancels");
        try out.byte(0x91);
        try out.byte(0x82);
        try out.text("asset");
        try out.number(b.wire_asset);
        try out.text("cloid");
        try out.text(command.client_order_id.slice());
        out.json_len = (try std.fmt.bufPrint(&out.json, "{{\"type\":\"cancelByCloid\",\"cancels\":[{{\"asset\":{d},\"cloid\":\"{s}\"}}]}}", .{ b.wire_asset, command.client_order_id.slice() })).len;
        return out;
    }
    var price_buffer: [80]u8 = undefined;
    var quantity_buffer: [80]u8 = undefined;
    const px = try decimalText(&price_buffer, command.limit_price.?.ticks, b.tick_atoms, b.price_scale);
    const sz = try decimalText(&quantity_buffer, command.quantity.?.lots, b.lot_atoms, b.quantity_scale);
    const tif = switch (command.time_in_force) {
        .good_til_canceled => "Gtc",
        .immediate_or_cancel => "Ioc",
        .post_only => "Alo",
        else => return error.Unsupported,
    };
    try out.text("orders");
    try out.byte(0x91);
    try out.byte(0x87);
    try out.text("a");
    try out.number(b.wire_asset);
    try out.text("b");
    try out.byte(if (command.side == .buy) 0xc3 else 0xc2);
    try out.text("p");
    try out.text(px);
    try out.text("s");
    try out.text(sz);
    try out.text("r");
    try out.byte(if (command.venue_reduce_only) 0xc3 else 0xc2);
    try out.text("t");
    try out.byte(0x81);
    try out.text("limit");
    try out.byte(0x81);
    try out.text("tif");
    try out.text(tif);
    try out.text("c");
    try out.text(command.client_order_id.slice());
    try out.text("grouping");
    try out.text("na");
    out.json_len = (try std.fmt.bufPrint(&out.json, "{{\"type\":\"order\",\"orders\":[{{\"a\":{d},\"b\":{},\"p\":\"{s}\",\"s\":\"{s}\",\"r\":{},\"t\":{{\"limit\":{{\"tif\":\"{s}\"}}}},\"c\":\"{s}\"}}],\"grouping\":\"na\"}}", .{ b.wire_asset, command.side == .buy, px, sz, command.venue_reduce_only, tif, command.client_order_id.slice() })).len;
    return out;
}
fn decimalText(buffer: []u8, units: i128, increment: i128, scale: u8) ![]const u8 {
    const coefficient = try std.math.mul(i128, units, increment);
    if (coefficient <= 0 or scale > 38) return error.InvalidDecimal;
    var divisor: i128 = 1;
    for (0..scale) |_| {
        divisor = try std.math.mul(i128, divisor, 10);
    }
    var len = (try std.fmt.bufPrint(buffer, "{d}", .{@divTrunc(coefficient, divisor)})).len;
    if (scale == 0) return buffer[0..len];
    if (len + 1 + scale > buffer.len) return error.FrameTooLarge;
    buffer[len] = '.';
    len += 1;
    var remainder = @rem(coefficient, divisor);
    for (0..scale) |_| {
        divisor = @divTrunc(divisor, 10);
        buffer[len] = @intCast('0' + @divTrunc(remainder, divisor));
        len += 1;
        remainder = @rem(remainder, divisor);
    }
    while (buffer[len - 1] == '0') len -= 1;
    if (buffer[len - 1] == '.') len -= 1;
    return buffer[0..len];
}
fn q(instrument: u128, version: u64, lots: i128) c.InstrumentQuantity {
    return .{ .instrument = instrument, .rules_version = version, .lots = lots };
}
fn quantity(b: Binding, version: u64, text: []const u8) !c.InstrumentQuantity {
    const decimal = try c.Decimal.parse(text);
    _ = try decimal.exactAtoms(b.size_decimals);
    const value = try c.InstrumentQuantity.fromDecimal(b.instrument, version, decimal, b.quantity_scale, b.lot_atoms);
    if (value.lots < 0) return error.InvalidQuantity;
    return value;
}
fn price(b: Binding, version: u64, text: []const u8) !c.InstrumentPrice {
    const value = try c.InstrumentPrice.fromDecimal(b.instrument, version, try c.Decimal.parse(text), b.price_scale, b.tick_atoms);
    if (value.ticks <= 0) return error.InvalidPrice;
    return value;
}
fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidFrame;
    return value.object.get(name) orelse error.MissingField;
}
fn string(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidFrame;
}
fn array(value: std.json.Value) ![]const std.json.Value {
    return if (value == .array) value.array.items else error.InvalidFrame;
}
fn uint(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => std.math.cast(u64, value.integer) orelse error.InvalidFrame,
        .number_string => std.fmt.parseInt(u64, value.number_string, 10),
        else => error.InvalidFrame,
    };
}
fn eq(value: std.json.Value, text: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, text);
}
fn factId(p: Profile, instrument: u128, oid: u128, time: u128, tid: u64, kind: []const u8) u128 {
    var bytes: [88]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], p.venue, .little);
    std.mem.writeInt(u128, bytes[8..24], p.account, .little);
    @memcpy(bytes[24..44], &p.funding);
    std.mem.writeInt(u128, bytes[44..60], instrument, .little);
    std.mem.writeInt(u128, bytes[60..76], oid, .little);
    std.mem.writeInt(u64, bytes[76..84], tid, .little);
    std.mem.writeInt(u32, bytes[84..88], @intFromEnum(p.environment), .little);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&bytes);
    hash.update(kind);
    var time_bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &time_bytes, time, .little);
    hash.update(&time_bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    // Existing order/economic consumers require a nonzero u64 source identity.
    return @max(1, std.mem.readInt(u64, digest[0..8], .little));
}

pub fn prepareCloid(_: *anyopaque, namespace: [16]u8, account: c.ExchangeAccountIdentity, order: u64, _: c.ClientOrderId) !c.ClientOrderId {
    if (account == 0 or order == 0) return error.InvalidOrderIdentity;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("Ringwin Hyperliquid CLOID v1");
    hash.update(&namespace);
    var identity: [24]u8 = undefined;
    std.mem.writeInt(u128, identity[0..16], account, .little);
    std.mem.writeInt(u64, identity[16..24], order, .little);
    hash.update(&identity);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
    var encoded: [34]u8 = undefined;
    @memcpy(encoded[0..2], "0x");
    @memcpy(encoded[2..], &hex);
    return c.ClientOrderId.init(&encoded);
}

test "Hyperliquid CLOID is stable and scoped at the public encoding seam" {
    var context: u8 = 0;
    const first = try prepareCloid(&context, @splat(1), 2, 3, .{});
    try std.testing.expectEqual(@as(usize, 34), first.slice().len);
    try std.testing.expectEqualStrings("0x", first.slice()[0..2]);
    try std.testing.expectEqualDeep(first, try prepareCloid(&context, @splat(1), 2, 3, .{}));
    try std.testing.expect(!std.meta.eql(first, try prepareCloid(&context, @splat(1), 4, 3, .{})));
}

const TestIO = struct {
    raw: u64 = 0,
    sends: u64 = 0,
    fail_raw: bool = false,
    revoked: bool = false,
    expected_action: ?[]const u8 = null,
    outcome: TransportResult = .{ .outcome = .response, .bytes = "{\"status\":\"ok\",\"response\":{\"type\":\"order\",\"data\":{\"statuses\":[{\"resting\":{\"oid\":42}}]}}}", .session = 3, .times = test_times },
    fn now(_: *anyopaque) Times {
        return test_times;
    }
    fn sign(ptr: *anyopaque, request: signer.Request) !signer.SignedAction {
        const self: *TestIO = @ptrCast(@alignCast(ptr));
        if (self.expected_action) |expected| try std.testing.expectEqualSlices(u8, expected, request.action);
        return .{ .nonce = request.now_ms, .digest = @splat(1), .signature = .{ .r = @splat(1), .s = @splat(1), .v = 27 }, .session = request.session, .funding_account = @splat(2), .subaccount = null };
    }
    fn check(ptr: *anyopaque, _: u64, _: u64, _: bool) !void {
        if (@as(*TestIO, @ptrCast(@alignCast(ptr))).revoked) return error.Revoked;
    }
    fn submit(ptr: *anyopaque, request: SignedRequest) TransportResult {
        const self: *TestIO = @ptrCast(@alignCast(ptr));
        self.sends += 1;
        std.debug.assert(std.mem.indexOf(u8, request.action_json, "0x") != null);
        return self.outcome;
    }
    fn query(_: *anyopaque, request: []const u8) TransportResult {
        std.debug.assert(std.mem.indexOf(u8, request, "0x0202020202020202020202020202020202020202") != null);
        return .{ .outcome = .response, .bytes = "{\"status\":\"unknownOid\"}", .session = 3, .times = test_times };
    }
    fn rawAppend(ptr: *anyopaque, _: RawRecord, _: []const u8) RawError!u64 {
        const self: *TestIO = @ptrCast(@alignCast(ptr));
        if (self.fail_raw) return error.Unavailable;
        self.raw += 1;
        return self.raw;
    }
    fn implementation(self: *TestIO, budget: *Budget) HyperliquidVenueAdapter {
        return .{ .profile = .{ .venue = 1, .account = 2, .session = 3, .funding = @splat(2), .environment = .simulation, .bindings = &test_bindings, .version = 1, .rules_version = 1, .config_version = 1, .can_trade = true }, .clock = .{ .ptr = self, .now_fn = now }, .auth = .{ .ptr = self, .sign_fn = sign, .check_fn = check }, .raw_sink = .{ .ptr = self, .append_fn = rawAppend }, .transport = .{ .ptr = self, .submit_fn = submit, .query_fn = query }, .budget = budget, .fencing_token = 1 };
    }
};
const test_times: Times = .{ .receive_time_utc_ns = 1_800_000_000_000_000_000, .wall_time_utc_ns = 1_800_000_000_000_000_000, .monotonic_time_ns = 1 };
const test_bindings = [_]Binding{.{ .instrument = 3, .coin = "BTC", .wire_asset = 3, .product = .isolated_linear, .size_decimals = 4, .price_scale = 6, .tick_atoms = 1, .quantity_scale = 4, .lot_atoms = 1 }};
fn testCommand() !c.OrderCommand {
    var context: u8 = 0;
    return .{ .identity = 1, .exchange_account = 2, .instrument = 3, .client_order_id = try prepareCloid(&context, @splat(1), 2, 1, .{}), .capability_version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 3, .dispatch_deadline_monotonic_ns = 100, .quantity = q(3, 1, 100), .limit_price = .{ .instrument = 3, .rules_version = 1, .ticks = 50_100_000_000 } };
}
fn testConfig() !venue.VenueConfig {
    return .{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 1, .asset_definitions = try @import("../../testing/contracts/venue_adapter_contract.zig").activatedTestAssets() };
}
test "Hyperliquid VenueAdapter shared lifecycle and actual ordered action encoding" {
    var io: TestIO = .{};
    var budget: Budget = .{};
    var implementation = io.implementation(&budget);
    try @import("../../testing/contracts/venue_adapter_contract.zig").exerciseWith(implementation.adapter(), try testConfig(), .{ .order_command = try testCommand() });
    try std.testing.expectEqual(@as(u64, 1), io.sends);
}
const fill_frame = "{\"channel\":\"userFills\",\"data\":{\"user\":\"0x0202020202020202020202020202020202020202\",\"isSnapshot\":false,\"fills\":[{\"coin\":\"BTC\",\"px\":\"49900\",\"sz\":\"0.004\",\"side\":\"B\",\"time\":1800000000000,\"oid\":42,\"tid\":7,\"fee\":\"0.1497\",\"feeToken\":\"USDT\",\"crossed\":true,\"closedPnl\":\"0\",\"dir\":\"Open Long\"}]}}";
test "Hyperliquid independent private Fill is idempotent and does not infer order cumulative" {
    var io: TestIO = .{};
    var budget: Budget = .{};
    var implementation = io.implementation(&budget);
    const adapter = implementation.adapter();
    try adapter.start(try testConfig());
    _ = try adapter.trySend(.{ .order_command = try testCommand() });
    _ = try adapter.tryDrain();
    try implementation.ingest(std.testing.allocator, 3, @splat(2), .fills, test_times, fill_frame);
    const output = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(usize, 1), output.slice().len);
    const fill = output.slice()[0].event.fill;
    try std.testing.expectEqual(@as(i128, 40), fill.quantity.lots);
    try std.testing.expectEqual(@as(i128, 149700), fill.fee.?.atoms);
    try implementation.ingest(std.testing.allocator, 3, @splat(2), .fills, test_times, fill_frame);
    try std.testing.expectEqual(@as(usize, 0), (try adapter.tryDrain()).?.slice().len);
}
test "Hyperliquid uncertain writes and raw failures cannot resend or affect a sibling account" {
    for ([_]bool{ false, true }) |raw_failure| {
        var io: TestIO = .{ .fail_raw = raw_failure };
        var budget: Budget = .{};
        if (!raw_failure) io.outcome.outcome = .uncertain;
        var implementation = io.implementation(&budget);
        const adapter = implementation.adapter();
        try adapter.start(try testConfig());
        const command = try testCommand();
        _ = try adapter.trySend(.{ .order_command = command });
        const result = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(c.DispatchState.unknown, result.slice()[0].event.order_dispatch_result.state);
        _ = try adapter.trySend(.{ .order_command = command });
        _ = try adapter.tryDrain();
        try std.testing.expectEqual(@as(u64, 1), io.sends);
        var sibling_io: TestIO = .{};
        var sibling = sibling_io.implementation(&budget);
        sibling.profile.account = 4;
        var config = try testConfig();
        config.exchange_account = 4;
        try sibling.adapter().start(config);
        var sibling_command = command;
        sibling_command.exchange_account = 4;
        _ = try sibling.adapter().trySend(.{ .order_command = sibling_command });
        try std.testing.expectEqual(@as(u64, 1), sibling_io.sends);
    }
}
test "Hyperliquid revocation stale binding deadline unsupported orders and reserved cancel budget" {
    var io: TestIO = .{};
    var budget: Budget = .{ .limit = 2 };
    var implementation = io.implementation(&budget);
    const adapter = implementation.adapter();
    try adapter.start(try testConfig());
    const command = try testCommand();
    for (0..7) |case| {
        var invalid = command;
        switch (case) {
            0 => invalid.exchange_account = 8,
            1 => invalid.adapter_session = 9,
            2 => invalid.dispatch_deadline_monotonic_ns = 1,
            3 => invalid.operation = .amend,
            4 => invalid.order_type = .market,
            5 => invalid.time_in_force = .fill_or_kill,
            6 => invalid.limit_price.?.ticks = 50_123_456_789,
            else => unreachable,
        }
        _ = try adapter.trySend(.{ .order_command = invalid });
        try std.testing.expectEqual(c.DispatchState.not_sent, (try adapter.tryDrain()).?.slice()[0].event.order_dispatch_result.state);
    }
    try std.testing.expectEqual(@as(u64, 0), io.sends);
    io.revoked = true;
    _ = try adapter.trySend(.{ .order_command = command });
    try std.testing.expectError(error.OutputPending, adapter.stop(.{ .monotonic_ns = 1 }));
    _ = try adapter.tryDrain();
    try std.testing.expectEqual(@as(u64, 0), io.sends);
    io.revoked = false;
    budget.used = 0;
    _ = try adapter.trySend(.{ .order_command = command });
    _ = try adapter.tryDrain();
    var second = command;
    second.identity = 2;
    var context: u8 = 0;
    second.client_order_id = try prepareCloid(&context, @splat(1), 2, 2, .{});
    _ = try adapter.trySend(.{ .order_command = second });
    try std.testing.expectEqual(c.CanonicalRejectReason.adapter_backpressure, (try adapter.tryDrain()).?.slice()[0].event.order_dispatch_result.reason.?);
    var cancel = command;
    cancel.identity = 3;
    cancel.order = 1;
    cancel.operation = .cancel;
    io.outcome.bytes = "{\"status\":\"ok\",\"response\":{\"type\":\"cancel\",\"data\":{\"statuses\":[\"success\"]}}}";
    _ = try adapter.trySend(.{ .order_command = cancel });
    const result = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(usize, 1), result.slice().len);
    try std.testing.expectEqual(c.DispatchState.submitted, result.slice()[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(@as(u64, 2), io.sends);
}
test "Hyperliquid private conflicting identity unknown assets forced and funding facts fail safely" {
    for (0..7) |case| {
        var io: TestIO = .{};
        var budget: Budget = .{};
        var implementation = io.implementation(&budget);
        const adapter = implementation.adapter();
        try adapter.start(try testConfig());
        _ = try adapter.trySend(.{ .order_command = try testCommand() });
        _ = try adapter.tryDrain();
        var bytes: [2048]u8 = undefined;
        var input: Input = .fills;
        const frame = switch (case) {
            0 => blk: {
                try implementation.ingest(std.testing.allocator, 3, @splat(2), .fills, test_times, fill_frame);
                _ = try adapter.tryDrain();
                const count = std.mem.replace(u8, fill_frame, "0.1497", "0.2497", &bytes);
                try std.testing.expectEqual(@as(usize, 1), count);
                break :blk bytes[0..fill_frame.len];
            },
            1 => blk: {
                _ = std.mem.replace(u8, fill_frame, "USDT", "NOPE", &bytes);
                break :blk bytes[0..fill_frame.len];
            },
            2 => blk: {
                input = .funding;
                break :blk "{\"time\":1800000000000,\"coin\":\"BTC\",\"usdc\":\"-1\"}";
            },
            3 => blk: {
                input = .user_events;
                break :blk "{\"liquidation\":{\"lid\":7}}";
            },
            4 => blk: {
                input = .ledger;
                break :blk "{\"delta\":{\"type\":\"internalTransfer\"}}";
            },
            5 => blk: {
                _ = std.mem.replace(u8, fill_frame, "Open Long", "ADL______", &bytes);
                break :blk bytes[0..fill_frame.len];
            },
            6 => "{}",
            else => unreachable,
        };
        if (implementation.ingest(std.testing.allocator, 3, @splat(2), input, test_times, frame)) |_| return error.ExpectedFault else |_| {}
        const fault = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(@as(usize, 1), fault.slice().len);
        try std.testing.expect(fault.slice()[0].event == .economic_fault);
        try @import("../../testing/contracts/venue_adapter_contract.zig").exerciseEconomicFaultRecovery(fault);
    }
}
test "Hyperliquid private rebate order status mapping and partial IOC terminal quantities" {
    var io: TestIO = .{};
    var budget: Budget = .{};
    var implementation = io.implementation(&budget);
    const adapter = implementation.adapter();
    try adapter.start(try testConfig());
    var ioc = try testCommand();
    ioc.order_type = .ioc;
    ioc.time_in_force = .immediate_or_cancel;
    _ = try adapter.trySend(.{ .order_command = ioc });
    _ = try adapter.tryDrain();
    var frame: [1024]u8 = undefined;
    const update = try std.fmt.bufPrint(&frame, "[{{\"order\":{{\"coin\":\"BTC\",\"side\":\"B\",\"limitPx\":\"50100\",\"sz\":\"0.006\",\"origSz\":\"0.01\",\"oid\":42,\"timestamp\":1800000000000}},\"status\":\"canceled\",\"statusTimestamp\":1800000000001}}]", .{});
    try implementation.ingest(std.testing.allocator, 3, @splat(2), .orders, test_times, update);
    const report = (try adapter.tryDrain()).?.slice()[0].event.execution_report;
    try std.testing.expectEqual(c.ExecutionReportStatus.canceled, report.status);
    try std.testing.expectEqual(@as(i128, 40), report.cumulative_quantity.lots);
    var rebate_frame: [2048]u8 = undefined;
    _ = std.mem.replace(u8, fill_frame, "0.1497", "-0.147", &rebate_frame);
    try implementation.ingest(std.testing.allocator, 3, @splat(2), .fills, test_times, rebate_frame[0..fill_frame.len]);
    const fill = (try adapter.tryDrain()).?.slice()[0].event.fill;
    try std.testing.expect(fill.fee == null);
    try std.testing.expectEqual(@as(i128, 147000), fill.rebate.?.atoms);
    // A future status suffix cannot be interpreted as a known rejection.
    const invalid = std.mem.replace(u8, update, "canceled", "xReject!", &rebate_frame);
    try std.testing.expectEqual(@as(usize, 1), invalid);
    try std.testing.expectError(error.UnsupportedStatus, implementation.ingest(std.testing.allocator, 3, @splat(2), .orders, test_times, rebate_frame[0..update.len]));
}
test "Hyperliquid Gtc Ioc Alo reduce-only encoding and explicit venue rejections" {
    const expected_action = "\x83\xa4type\xa5order\xa6orders\x91\x87\xa1a\x03\xa1b\xc3\xa1p\xa550100\xa1s\xa40.01\xa1r\xc2\xa1t\x81\xa5limit\x81\xa3tif\xa3Gtc\xa1c\xd9\x220x00000000000000000000000000000001\xa8grouping\xa2na";
    for (0..4) |case| {
        var io: TestIO = .{};
        var budget: Budget = .{};
        var implementation = io.implementation(&budget);
        const adapter = implementation.adapter();
        try adapter.start(try testConfig());
        var command = try testCommand();
        command.client_order_id = try c.ClientOrderId.init("0x00000000000000000000000000000001");
        switch (case) {
            0 => io.expected_action = expected_action,
            1 => {
                command.order_type = .ioc;
                command.time_in_force = .immediate_or_cancel;
            },
            2 => {
                command.order_type = .post_only;
                command.time_in_force = .post_only;
            },
            3 => command.venue_reduce_only = true,
            else => unreachable,
        }
        if (case == 1 or case == 2) io.outcome.bytes = "{\"status\":\"ok\",\"response\":{\"type\":\"order\",\"data\":{\"statuses\":[{\"error\":\"Order could not be placed\"}]}}}";
        _ = try adapter.trySend(.{ .order_command = command });
        const batch = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(@as(u64, 1), io.sends);
        try std.testing.expectEqual(c.DispatchState.submitted, batch.slice()[0].event.order_dispatch_result.state);
        try std.testing.expectEqual(if (case == 1 or case == 2) c.ExecutionReportStatus.rejected else .accepted, batch.slice()[1].event.execution_report.status);
        if (case == 1 or case == 2) try std.testing.expectEqual(@as(i128, 0), batch.slice()[1].event.execution_report.cumulative_quantity.lots);
    }
    _ = WalletAuthorization.interface;
}
test "Hyperliquid account observations report isolated leverage and explicit spot balances" {
    var io: TestIO = .{};
    var budget: Budget = .{};
    var implementation = io.implementation(&budget);
    implementation.profile.bootstrap_identity = 1;
    implementation.profile.tokens = &.{.{ .index = 0, .asset = 1 }};
    const adapter = implementation.adapter();
    try adapter.start(try testConfig());
    try implementation.ingest(std.testing.allocator, 3, @splat(2), .account, test_times, "{\"assetPositions\":[{\"type\":\"oneWay\",\"position\":{\"coin\":\"BTC\",\"szi\":\"-0.01\",\"leverage\":{\"type\":\"isolated\",\"value\":3}}}]}");
    const batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(usize, 2), batch.slice().len);
    try std.testing.expectEqual(@as(i128, 3), batch.slice()[0].event.venue_account_configuration_snapshot.value.isolated_leverage.leverage.coefficient);
    try std.testing.expectEqual(@as(i128, -100), batch.slice()[1].event.account_observed.value.position.value.quantity.lots);
    try implementation.ingest(std.testing.allocator, 3, @splat(2), .spot_account, test_times, "{\"balances\":[{\"coin\":\"USDT\",\"token\":0,\"total\":\"25\",\"hold\":\"2\"}]}");
    const balance = (try adapter.tryDrain()).?.slice()[0].event.account_observed.value.balance.value;
    try std.testing.expectEqual(@as(i128, 23000000), balance.available.atoms);
    try std.testing.expectError(error.UnsupportedAccountMode, implementation.ingest(std.testing.allocator, 3, @splat(2), .account, test_times, "{\"assetPositions\":[{\"type\":\"oneWay\",\"position\":{\"coin\":\"BTC\",\"leverage\":{\"type\":\"cross\",\"value\":3}}}]}"));
}
test "Hyperliquid order queries use funding account and never prove absence or resend Unknown" {
    var io: TestIO = .{};
    io.outcome.outcome = .uncertain;
    var budget: Budget = .{};
    var implementation = io.implementation(&budget);
    const adapter = implementation.adapter();
    try adapter.start(try testConfig());
    _ = try adapter.trySend(.{ .order_command = try testCommand() });
    _ = try adapter.tryDrain();
    const before = io.raw;
    _ = try adapter.trySend(.{ .order_reconciliation = .{ .identity = 8, .exchange_account = 2, .order = 1 } });
    const result = (try adapter.tryDrain()).?.slice()[0].event.order_reconciliation_result;
    try std.testing.expectEqual(c.ReconciliationStatus.unresolved, result.status);
    try std.testing.expect(!result.complete);
    try std.testing.expectEqual(before + 1, io.raw);
    _ = try adapter.trySend(.{ .order_command = try testCommand() });
    _ = try adapter.tryDrain();
    try std.testing.expectEqual(@as(u64, 1), io.sends);
}
test "Hyperliquid unsupported order kinds conflicting terms and wrong native token cannot cross the seam" {
    for (0..7) |case| {
        var io: TestIO = .{};
        var budget: Budget = .{};
        var implementation = io.implementation(&budget);
        implementation.profile.bootstrap_identity = 1;
        implementation.profile.tokens = &.{.{ .index = 0, .asset = 1 }};
        const adapter = implementation.adapter();
        try adapter.start(try testConfig());
        _ = try adapter.trySend(.{ .order_command = try testCommand() });
        _ = try adapter.tryDrain();
        var buffer: [2048]u8 = undefined;
        var input: Input = .orders;
        const frame = if (case < 5) try std.fmt.bufPrint(&buffer, "[{{\"order\":{{{s}\"coin\":\"BTC\",\"side\":\"B\",\"limitPx\":\"50100\",\"sz\":\"0.01\",\"origSz\":\"0.01\",\"oid\":42,\"timestamp\":1800000000000}},\"status\":\"open\",\"statusTimestamp\":1800000000001}}]", .{switch (case) {
            0 => "\"isTrigger\":true,",
            1 => "\"isPositionTpsl\":true,",
            2 => "\"children\":[{}],",
            3 => "\"reduceOnly\":true,",
            4 => "\"tif\":\"Alo\",",
            else => unreachable,
        }}) else if (case == 5) blk: {
            input = .fills;
            const needle = "\"tid\":7";
            const replacement = "\"tid\":7,\"twapId\":9";
            _ = std.mem.replace(u8, fill_frame, needle, replacement, &buffer);
            break :blk buffer[0 .. fill_frame.len + replacement.len - needle.len];
        } else blk: {
            input = .spot_account;
            break :blk "{\"balances\":[{\"coin\":\"USDT\",\"token\":1,\"total\":\"25\",\"hold\":\"0\"}]}";
        };
        if (implementation.ingest(std.testing.allocator, 3, @splat(2), input, test_times, frame)) |_| return error.ExpectedFault else |_| {}
        const batch = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(@as(usize, 1), batch.slice().len);
        try std.testing.expect(batch.slice()[0].event == .economic_fault);
    }
}
test "Hyperliquid spot execution retains activated USDC fee Asset instead of a quote fallback" {
    var io: TestIO = .{};
    var budget: Budget = .{};
    var implementation = io.implementation(&budget);
    const bindings = [_]Binding{.{ .instrument = 3, .coin = "@11", .wire_asset = 10011, .product = .spot, .size_decimals = 4, .price_scale = 6, .tick_atoms = 1, .quantity_scale = 4, .lot_atoms = 1 }};
    implementation.profile.bindings = &bindings;
    var config = try testConfig();
    var assets: @import("../../trading/asset_registry.zig").Registry = .{};
    var definition = @import("../../trading/asset_registry.zig").testDefinitions(6, 8)[0];
    definition.asset = 5;
    definition.code_bindings = @splat(.{});
    definition.code_binding_count = 1;
    definition.code_bindings[0] = try c.AssetCodeBinding.init(1, "USDC");
    _ = try assets.activate(definition, 1);
    config.asset_definitions = assets;
    const adapter = implementation.adapter();
    try adapter.start(config);
    _ = try adapter.trySend(.{ .order_command = try testCommand() });
    _ = try adapter.tryDrain();
    var first: [2048]u8 = undefined;
    var second: [2048]u8 = undefined;
    _ = std.mem.replace(u8, fill_frame, "BTC", "@11", &first);
    _ = std.mem.replace(u8, first[0..fill_frame.len], "USDT", "USDC", &second);
    try implementation.ingest(std.testing.allocator, 3, @splat(2), .fills, test_times, second[0..fill_frame.len]);
    const fill = (try adapter.tryDrain()).?.slice()[0].event.fill;
    try std.testing.expectEqual(@as(u64, 5), fill.fee.?.asset);
    try std.testing.expectEqual(@as(i128, 149700), fill.fee.?.atoms);
}
test "Hyperliquid partial IOC aggregate retains oid without inventing a terminal report or economic Fill" {
    var io: TestIO = .{};
    io.outcome.bytes = "{\"status\":\"ok\",\"response\":{\"type\":\"order\",\"data\":{\"statuses\":[{\"filled\":{\"oid\":42,\"totalSz\":\"0.004\",\"avgPx\":\"49900\"}}]}}}";
    var budget: Budget = .{};
    var implementation = io.implementation(&budget);
    const adapter = implementation.adapter();
    try adapter.start(try testConfig());
    var command = try testCommand();
    command.order_type = .ioc;
    command.time_in_force = .immediate_or_cancel;
    _ = try adapter.trySend(.{ .order_command = command });
    const aggregate = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(usize, 1), aggregate.slice().len);
    try std.testing.expectEqual(c.DispatchState.unknown, aggregate.slice()[0].event.order_dispatch_result.state);
    var cancel = command;
    cancel.identity = 2;
    cancel.order = 1;
    cancel.operation = .cancel;
    io.outcome.bytes = "{\"status\":\"ok\",\"response\":{\"type\":\"cancel\",\"data\":{\"statuses\":[\"success\"]}}}";
    _ = try adapter.trySend(.{ .order_command = cancel });
    try std.testing.expectEqual(c.DispatchState.submitted, (try adapter.tryDrain()).?.slice()[0].event.order_dispatch_result.state);
    try implementation.ingest(std.testing.allocator, 3, @splat(2), .fills, test_times, fill_frame);
    const fill = (try adapter.tryDrain()).?.slice()[0].event.fill;
    try std.testing.expectEqual(@as(i128, 40), fill.quantity.lots);
    try std.testing.expectEqual(@as(u64, 2), io.sends);
}
