//! Offline Linux business scenario. Each role exchanges bounded canonical data
//! over the authenticated control stream. Uses only SimulatedVenue.
const std = @import("std");
const canonical = @import("../../model/canonical_event.zig");
const codec = @import("../../persistence/canonical_event_codec.zig");
const durable_store = @import("../../persistence/durable_store.zig");
const demo_authority = @import("../../runtime/demo/demo_authority.zig");
const execution_gateway = @import("../../execution/execution_gateway.zig");
const venue = @import("../../execution/venue_adapter.zig");
const simulated = @import("../../adapters/simulated/simulated_venue.zig");
const fixture = @import("../support/trading_shard_fixture.zig");
const host_gateway = @import("../../strategy/strategy_host_gateway.zig");
const strategy_host_lifecycle = @import("../../strategy/strategy_host_lifecycle.zig");
const trading_shard = @import("../../trading/trading_shard.zig");

pub const Engine = struct {
    host: strategy_host_lifecycle.ManagedHost,
    store: durable_store.LinuxFileAdapter,
    shard_run: demo_authority.Owner,
    strategy_gateway: host_gateway.Gateway,
    gateway: execution_gateway.Gateway,
    remote: Remote,
    snapshot: []u8,
    pending: bool = false,

    pub fn start(init: std.process.Init, stream: std.Io.net.Stream, generation: u64, socket_path: []const u8) !*Engine {
        const self = try init.gpa.create(Engine);
        errdefer init.gpa.destroy(self);
        self.snapshot = try init.gpa.alloc(u8, durable_store.max_snapshot_bytes);
        errdefer init.gpa.free(self.snapshot);
        const directory = try std.fmt.allocPrint(init.gpa, "{s}.state", .{socket_path});
        defer init.gpa.free(directory);
        try std.Io.Dir.cwd().createDir(init.io, directory, @enumFromInt(0o700));
        errdefer std.Io.Dir.cwd().deleteTree(init.io, directory) catch {};
        @memset(std.mem.asBytes(&self.store), 0);
        try self.store.initLinux(init.io, directory);
        errdefer self.store.close(init.io);
        const python_abi = try strategy_host_lifecycle.discoverPythonAbi(init, "python3");
        self.host = try strategy_host_lifecycle.ManagedHost.start(
            init,
            "python3",
            "python/strategy_host.py",
            strategy_host_lifecycle.developmentPlan(1, generation, python_abi),
            "trade",
            &.{ "--strategy-identity", "1", "--activation-identity", "1", "--config-version", "1", "--intent-sequence", "220", "--quantity", "10", "--limit-price", "50100000000" },
        );
        errdefer self.host.deinit(init.io);
        try self.host.sendPlan(init.io);
        if (try self.host.receive(init.io, 1) != .accepted or
            try self.host.receive(init.io, 2) != .accepted or
            self.host.supervisor.state != .ready_for_recovery)
            return error.HostHandshakeFailed;
        try demo_authority.Owner.bootstrapInto(&self.shard_run, self.store.interface(), init.io, .{ .domain = .decision_log, .id = 78 });
        const genesis = fixture.genesisEvents(.{
            .strategy_identity = 1,
            .config_version = 1,
            .activation_identity = 1,
            .activation_barrier = 0,
        }, .leveraged);
        for (genesis) |event| if (try self.shard_run.apply(event) != null) return error.UnexpectedCommand;
        const host_digest = self.shard_run.shard.canonicalStateDigest();
        const activation_barrier = self.shard_run.shard.authoritativeBarrier();
        if (try self.shard_run.apply(fixture.atGroup(11, .{ .identity = 3, .payload = .{ .host_activated = .{
            .strategy_identity = 1,
            .config_version = 1,
            .activation_identity = 1,
            .session = self.host.supervisor.plan.session,
            .activation_barrier = activation_barrier,
            .state_digest = host_digest,
        } } })) != null) return error.UnexpectedCommand;
        try self.shard_run.sealBootstrap();
        try self.host.activate(init.io, .{
            .strategy_identity = 1,
            .activation_identity = 1,
            .barrier = activation_barrier,
            .state_digest = host_digest,
        });

        self.gateway.initWithDispatchSnapshotBuffer(self.snapshot);
        self.remote = .{ .init = init, .stream = stream };
        self.pending = false;
        return self;
    }

    pub fn deinit(self: *Engine, init: std.process.Init) void {
        self.host.deinit(init.io);
        self.store.close(init.io);
        init.gpa.free(self.snapshot);
        init.gpa.destroy(self);
    }

    pub fn submit(self: *Engine, init: std.process.Init, mark: i128, token: u64) !void {
        if (self.pending or token == 0 or mark <= 0) return error.InvalidBusinessInput;
        const capability = fixture.atGroup(12, .{ .identity = 219, .payload = .{ .capability_profile_activation = .{
            .exchange_account = 2,
            .instrument = fixture.swap_instrument,
            .venue = 1,
            .environment = .simulation,
            .product = .isolated_linear,
            .version = 1,
            .rules_version = 1,
            .config_version = 1,
            .adapter_session = 1,
            .max_dispatch_age_ns = std.time.ns_per_s,
            .supports_place = true,
            .supports_cancel = true,
            .supports_native_amend = false,
            .supports_venue_reduce_only = false,
            .supports_post_only = false,
            .supports_market_protection = false,
        } } });
        _ = try self.shard_run.apply(capability);
        var account_bootstrap = fixture.canonicalAt(12, 1, .{ .account_bootstrap_snapshot = .{
            .identity = 1,
            .exchange_account = 2,
            .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
            .source_stream = 2,
            .source_sequence = 1,
            .balance_count = 0,
            .position_count = 0,
            .margin_count = 0,
        } });
        account_bootstrap.venue.envelope.identity.stream = 2;
        // The simulated account supplies explicit native funding and margin facts.
        account_bootstrap.venue.event.account_bootstrap_snapshot.balance_count = 1;
        account_bootstrap.venue.event.account_bootstrap_snapshot.balances[0] = .{
            .asset = fixture.settlement_asset,
            .total = .{ .asset = fixture.settlement_asset, .atoms = 25_000_000_000 },
            .available = .{ .asset = fixture.settlement_asset, .atoms = 25_000_000_000 },
            .held = .{ .asset = fixture.settlement_asset, .atoms = 0 },
            .cash_balance = .{ .asset = fixture.settlement_asset, .atoms = 25_000_000_000 },
            .liability = .{ .asset = fixture.settlement_asset, .atoms = 0 },
            .isolated_liability = .{ .asset = fixture.settlement_asset, .atoms = 0 },
            .cross_liability = .{ .asset = fixture.settlement_asset, .atoms = 0 },
        };
        account_bootstrap.venue.event.account_bootstrap_snapshot.margin_count = 1;
        account_bootstrap.venue.event.account_bootstrap_snapshot.margins[0] = .{
            .instrument = fixture.swap_instrument,
            .amount = .{ .asset = fixture.settlement_asset, .atoms = 25_000_000_000 },
            .initial_margin = .{ .asset = fixture.settlement_asset, .atoms = 0 },
            .maintenance_margin = .{ .asset = fixture.settlement_asset, .atoms = 0 },
            .isolated_equity = .{ .asset = fixture.settlement_asset, .atoms = 25_000_000_000 },
        };
        account_bootstrap.venue.envelope.source_stream = 2;
        account_bootstrap.venue.envelope.raw_evidence.stream = 2;
        _ = try self.shard_run.apply(account_bootstrap);
        var market_prelude = [_]trading_shard.CanonicalEvent{
            fixture.atGroup(12, .{ .identity = 1, .payload = .{ .mark_price = .{ .instrument = fixture.swap_instrument, .price_atoms = mark } } }),
            fixture.canonicalAt(12, 99, .{ .instrument_definition_observed = .{ .instrument = fixture.swap_instrument, .rules_version = 1 } }),
            fixture.snapshotAt(13, 100),
            fixture.deltaAt(14, 100, 101, 49_850_000_000),
        };
        for (market_prelude[1..]) |*event| {
            event.venue.envelope.identity.stream = 3;
            event.venue.envelope.source_stream = 3;
            event.venue.envelope.raw_evidence.stream = 3;
        }
        for (market_prelude, 0..) |event, index| _ = self.shard_run.apply(event) catch |err| {
            std.debug.print("market_prelude_failed={d} {s}\n", .{ index, @errorName(err) });
            return err;
        };
        const host_config: host_gateway.Config = .{
            .schema_registry = self.host.supervisor.plan.compatibility.schema_registry,
            .decision_domain = self.host.supervisor.plan.decision_domain,
            .session = self.host.supervisor.plan.session,
            .authorization = .{ .strategy_identity = 1, .config_version = 1, .activation_identity = 1, .activation_barrier = self.shard_run.shard.host_activation_barrier },
        };
        const subscriptions = [_]host_gateway.Subscription{host_gateway.Subscription.of(1, &.{.mark_price})};
        self.strategy_gateway = try host_gateway.Gateway.init(host_config, &subscriptions);
        const cursor = self.shard_run.shard.authoritativeBarrier();
        const published_ns: i64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        const payload = [_]u8{1};
        const events = [_]host_gateway.EventEnvelope{.{
            .event_type = .mark_price,
            .shard_sequence = cursor,
            .source_time_ns = published_ns,
            .receive_time_ns = published_ns,
            .monotonic_time_ns = published_ns,
            .wall_time_utc_ns = published_ns,
            .payload = &payload,
        }};
        var input_storage: [512]u8 = undefined;
        const input = try self.strategy_gateway.encodeBatch(&input_storage, 1, cursor, cursor, published_ns, &events);
        try self.host.sendInput(init.io, input, published_ns);
        try self.strategy_gateway.recordPublished(1, cursor, published_ns);
        try self.strategy_gateway.activate(&self.shard_run.shard, &self.shard_run.decision_journal);
        var output_storage: [512]u8 = undefined;
        const host_output = try self.host.receiveOutput(init.io, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds), &output_storage);
        const host_decision = self.strategy_gateway.ingest(host_output, @intCast(std.Io.Clock.awake.now(init.io).nanoseconds));
        const host_intent = switch (host_decision) {
            .accepted => |intent| intent,
            .accepted_group => return error.JointAdmissionUnavailable,
            .rejected => return error.HostIntentRejected,
        };
        const proved = (try self.shard_run.apply(fixture.atGroup(12, .{ .identity = 220, .payload = .{ .external_order_intent = host_intent } }))) orelse {
            std.debug.print("host_intent_reject={s} cursor={d} activation_barrier={d} source_cursor={d}\n", .{
                @tagName(self.shard_run.shard.last_reject_reason), host_intent.strategy_cursor,
                self.shard_run.shard.host_activation_barrier,      self.shard_run.shard.strategy_cursor,
            });
            return error.MissingOmsCommand;
        };

        const adapter = self.remote.adapter();
        try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 1, .request_capacity = 1, .output_capacity = 1, .asset_definitions = self.shard_run.shard.activatedAssets(), .instrument_definitions = self.shard_run.shard.instrument_registry, .native_settlement_atoms = self.shard_run.shard.instrument_registry.get(proved.instrument).?.margin.native_settlement_atoms });
        try self.gateway.add(.{ .account = 2, .adapter = adapter, .venue_identity = 1, .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
        try self.gateway.observeAuthorityFromShard(&self.shard_run.shard, .{
            .account = self.shard_run.shard.exchange_account_identity,
            .effective_trading_authority = self.shard_run.shard.operational_state.effectiveTradingAuthority(),
            .reservation_identity = proved.reservation_identity,
            .reservation = proved.reservation,
            .primary_lease_expires_at_monotonic_ns = 3 * std.time.ns_per_s,
            .fencing_token = self.shard_run.shard.fencing_token,
            .exchange_position = self.shard_run.shard.currentNetExchangePosition(proved.instrument) orelse return error.MissingExchangePosition,
            .authority_barrier = self.shard_run.shard.authoritativeBarrier(),
        });
        const store = self.store.interface();
        const stream: durable_store.StreamIdentity = .{ .domain = .control, .id = 77 };
        try self.gateway.bootstrapDurableDispatch(store, init.io, stream);
        if (store.safetyGate() != .open) return error.DurableSafetyGateClosed;
        const dispatch_bootstrap = try store.recover(init.io, stream);
        if (dispatch_bootstrap.status != .ready or dispatch_bootstrap.committed_barrier == 0) return error.DurableBootstrapIncomplete;
        if (self.shard_run.shard.risk_lease_atoms <= 0) return error.RiskLeaseClosed;
        if (self.shard_run.shard.fencing_token == 0) return error.MissingFencingToken;
        if (!proved.authority.complete()) return error.IncompleteDispatchAuthority;
        const send_now = proved.authority.dispatch_deadline_monotonic_ns -| 1;
        const order = self.shard_run.shard.oms.orderById(proved.order_id) orelse return error.MissingOmsOrder;
        const received_at = try std.math.add(u64, order.created_at_utc_ns, std.time.ns_per_ms);
        self.remote.times = .{ .receive_utc_ns = received_at, .monotonic_ns = send_now, .audit_utc_ns = received_at };
        if (token != self.shard_run.shard.fencing_token) return error.StaleBusinessFence;
        const send_result = try self.gateway.sendFromShard(&self.shard_run.shard, proved.command_id, send_now);
        if (send_result != .accepted) return error.GatewaySendFailed;
        if ((try store.recover(init.io, stream)).committed_barrier < 2) return error.DurableCommitMissing;
        self.pending = true;
    }

    pub fn revoke(self: *Engine, init: std.process.Init) !void {
        const now: u64 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        if (!try strategy_host_lifecycle.revokeHostOwnerForDrain(&self.host.supervisor, &self.strategy_gateway, &self.shard_run, 221, now))
            return error.HostAuthorityNotRevoked;
        try self.host.shutdown(init.io, @intCast(now));
    }

    pub fn settle(self: *Engine, init: std.process.Init, batch: canonical.AdapterOutputBatch) !void {
        if (!self.pending) return error.NoDispatchPending;
        self.remote.pending = batch;
        var output: [execution_gateway.max_routes]canonical.AdapterOutputBatch = undefined;
        if (try self.gateway.drainFair(&output) != 1) return error.MissingSimulatedFill;
        try self.shard_run.applyAdapterBatch(output[0]);
        if (self.shard_run.shard.oms.orders[0].state != .filled or
            self.shard_run.shard.economicSummary().portfolio.swap.quantity != 10)
            return error.LedgerNotClosed;
        const recovered = try init.gpa.create(demo_authority.Owner);
        defer init.gpa.destroy(recovered);
        try demo_authority.Owner.recoverInto(recovered, self.shard_run.store, init.io, self.shard_run.stream);
        if (!std.mem.eql(u8, &self.shard_run.shard.canonicalStateDigest(), &recovered.shard.canonicalStateDigest()))
            return error.ReplayDigestMismatch;
        self.pending = false;
    }
};

const asset_registry = @import("../../trading/asset_registry.zig");
const instrument_registry = @import("../../trading/instrument_registry.zig");
pub const max_frame = @max(64 * 1024, codec.max_encoded_len);

pub fn writeFrame(stream: std.Io.net.Stream, io: std.Io, data: []const u8) !void {
    if (data.len == 0 or data.len > max_frame) return error.InvalidBusinessFrame;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(data.len), .little);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

pub fn readFrame(stream: std.Io.net.Stream, io: std.Io, storage: []u8) ![]const u8 {
    var header: [4]u8 = undefined;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5 * std.time.ns_per_s;
    try readExact(stream, io, &header, deadline);
    const length = std.mem.readInt(u32, &header, .little);
    if (length == 0 or length > @min(storage.len, max_frame)) return error.InvalidBusinessFrame;
    try readExact(stream, io, storage[0..length], deadline);
    return storage[0..length];
}

fn readExact(stream: std.Io.net.Stream, io: std.Io, data: []u8, deadline: i96) !void {
    var remaining = data;
    while (remaining.len != 0) {
        const ns = deadline - std.Io.Clock.awake.now(io).nanoseconds;
        if (ns <= 0) return error.BusinessFrameDeadline;
        var poll = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.os.linux.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&poll, @intCast(@divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms))) == 0)
            return error.BusinessFrameDeadline;
        var buffers = [1][]u8{remaining};
        const n = try stream.read(io, &buffers);
        if (n == 0) return error.BusinessPeerDisconnected;
        remaining = remaining[n..];
    }
}

const Submission = struct {
    request: canonical.OrderCommand,
    times: canonical.Times,
    assets: []const asset_registry.Entry,
    instruments: []const instrument_registry.Entry,
    native: bool,
};

const Remote = struct {
    init: std.process.Init,
    stream: std.Io.net.Stream,
    config: ?venue.VenueConfig = null,
    times: canonical.Times = undefined,
    pending: ?canonical.AdapterOutputBatch = null,
    fn adapter(self: *Remote) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *Remote = @ptrCast(@alignCast(ptr));
        if (self.config != null) return error.AlreadyStarted;
        self.config = config;
    }
    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *Remote = @ptrCast(@alignCast(ptr));
        const config = self.config orelse return error.NotStarted;
        const assets = config.asset_definitions orelse return error.InvalidRequest;
        const instruments = config.instrument_definitions orelse return error.InvalidRequest;
        if (request != .order_command) return error.InvalidRequest;
        const data = std.json.Stringify.valueAlloc(self.init.gpa, Submission{
            .request = request.order_command,
            .times = self.times,
            .assets = assets.entries[0..assets.count],
            .instruments = instruments.entries[0..instruments.count],
            .native = config.native_settlement_atoms,
        }, .{ .emit_strings_as_arrays = true }) catch return error.InvalidRequest;
        defer self.init.gpa.free(data);
        writeFrame(self.stream, self.init.io, data) catch return error.InvalidRequest;
        var ack: [1]u8 = undefined;
        const received = readFrame(self.stream, self.init.io, &ack) catch return error.InvalidRequest;
        if (!std.mem.eql(u8, received, "A")) return error.InvalidRequest;
        return .accepted;
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *Remote = @ptrCast(@alignCast(ptr));
        const batch = self.pending;
        self.pending = null;
        return batch;
    }
    fn stop(ptr: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {
        const self: *Remote = @ptrCast(@alignCast(ptr));
        if (self.pending != null) return error.OutputPending;
    }
};

pub fn execute(init: std.process.Init, backend: *simulated.SimulatedVenue, data: []const u8) !void {
    const parsed = try std.json.parseFromSlice(Submission, init.gpa, data, .{});
    defer parsed.deinit();
    const submission = parsed.value;
    var assets: asset_registry.Registry = .{};
    var instruments: instrument_registry.Registry = .{};
    if (submission.assets.len > assets.entries.len or submission.instruments.len > instruments.entries.len)
        return error.InvalidBusinessRegistry;
    @memcpy(assets.entries[0..submission.assets.len], submission.assets);
    @memcpy(instruments.entries[0..submission.instruments.len], submission.instruments);
    assets.count = @intCast(submission.assets.len);
    instruments.count = @intCast(submission.instruments.len);
    backend.receipt_times = submission.times;
    const adapter = backend.adapter();
    try adapter.start(.{
        .venue = 1,
        .environment = .simulation,
        .exchange_account = 2,
        .adapter_session = 1,
        .output_capacity = 1,
        .request_capacity = 1,
        .asset_definitions = assets,
        .instrument_definitions = instruments,
        .native_settlement_atoms = submission.native,
    });
    if (try adapter.trySend(.{ .order_command = submission.request }) != .accepted) return error.SimulatedDispatchRejected;
}

pub fn writeBatch(stream: std.Io.net.Stream, io: std.Io, batch: *const canonical.AdapterOutputBatch) !void {
    try writeFrame(stream, io, &.{batch.len});
    var storage: [codec.max_encoded_len]u8 = undefined;
    for (batch.slice()) |record| try writeFrame(stream, io, try codec.encode(&storage, record));
}

pub fn readBatch(stream: std.Io.net.Stream, io: std.Io) !canonical.AdapterOutputBatch {
    var count: [1]u8 = undefined;
    _ = try readFrame(stream, io, &count);
    if (count[0] == 0 or count[0] > canonical.max_events_per_adapter_batch) return error.InvalidBusinessBatch;
    var batch: canonical.AdapterOutputBatch = .{};
    var storage: [codec.max_encoded_len]u8 = undefined;
    for (0..count[0]) |_| try batch.append(try codec.decode(try readFrame(stream, io, &storage)));
    return batch;
}
