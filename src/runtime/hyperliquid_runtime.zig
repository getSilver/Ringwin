//! Configuration-owned assembly. Owner/Gateway retain all trading authority.
const std = @import("std");
const c = @import("../model/canonical_event.zig");
const execution = @import("../execution/execution_gateway.zig");
const venue = @import("../execution/venue_adapter.zig");
const hl = @import("../adapters/hyperliquid/hyperliquid_venue_adapter.zig");
const feed = @import("../adapters/hyperliquid/hyperliquid_market_feed.zig");
const Owner = @import("demo/demo_authority.zig").Owner;
const durable = @import("../persistence/durable_store.zig");
const raw = @import("../persistence/raw_ingress.zig");
const codec = @import("../persistence/snapshot_codec.zig");
const journal = @import("../persistence/journal.zig");

pub const Mode = enum { offline, read_only, testnet_write };
pub const FeedConfiguration = struct { binding: feed.Binding, subscription_set: u128, session: u128 };
pub const Configuration = struct {
    schema: u16 = 1,
    epoch_startup: enum { virgin, recover } = .recover,
    profile: hl.Profile,
    feeds: []const FeedConfiguration,

    /// expected is the immutable configuration artifact hash selected by the control plane.
    /// An observed metadata digest must never be substituted for this approval.
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, expected: [32]u8) !std.json.Parsed(Configuration) {
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
        if (std.mem.allEqual(u8, &expected, 0) or !std.mem.eql(u8, &actual, &expected)) return error.ConfigurationNotApproved;
        const parsed = try std.json.parseFromSlice(Configuration, gpa, bytes, .{});
        errdefer parsed.deinit();
        try parsed.value.validate();
        return parsed;
    }

    pub fn identity(self: Configuration) ![32]u8 {
        var normalized = self;
        normalized.epoch_startup = .recover;
        var bytes: [65536]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.json.Stringify.value(normalized, .{}, &writer);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(writer.buffered(), &digest, .{});
        return digest;
    }

    pub fn validate(self: Configuration) !void {
        const p = self.profile;
        if (self.schema != 1 or p.venue == 0 or p.account == 0 or p.session == 0 or
            p.config_version == 0 or p.version == 0 or p.rules_version == 0 or
            p.environment == .demo or self.feeds.len == 0 or self.feeds.len > 8 or
            p.bindings.len != self.feeds.len or p.can_trade or !p.can_read) return error.InvalidConfiguration;
        for (self.feeds, p.bindings, 0..) |f, b, index| {
            const m = f.binding;
            const wire_asset = if (m.product == .spot) try std.math.add(u32, m.universe_index, 10000) else m.universe_index;
            if (f.session == 0 or f.session > std.math.maxInt(u64) or f.subscription_set == 0 or b.instrument != m.instrument or b.product != m.product or
                b.wire_asset != wire_asset or
                b.size_decimals != m.size_decimals or b.price_scale != m.price_scale or b.tick_atoms != m.tick_atoms or
                b.quantity_scale != m.quantity_scale or b.lot_atoms != m.lot_atoms or m.rules_version != p.rules_version or
                !std.mem.eql(u8, b.coin, m.coin) or std.mem.allEqual(u8, &m.expected_metadata_digest, 0)) return error.InvalidConfiguration;
            for (self.feeds[0..index]) |prior| if (prior.binding.instrument == m.instrument or prior.subscription_set == f.subscription_set or prior.session == f.session) return error.InvalidConfiguration;
        }
    }
};

/// Offline injection has no credential path. Online resources are supplied only
/// after the existing credential/Owner admission, never loaded by this module.
pub const Resources = union(Mode) {
    offline: struct { transport: hl.Transport, authorizer: hl.Authorizer },
    read_only: hl.Transport,
    testnet_write: struct {
        transport: hl.Transport,
        wallet: *hl.WalletAuthorization,
        hyperliquid_testnet_write_authorized: bool,
        expires_monotonic_ns: u64,
    },
};
const Epoch = struct { instrument: u128 = 0, value: u64 = 0 };
const EpochState = struct { schema: u16 = 1, venue: u64, account: u128, generation: u64 = 0, entries: [8]Epoch = @splat(.{}), barrier: u64 = 0 };
const market_header_origin: u16 = 0x484d;
const MarketHeader = struct { schema: u16 = 1, configuration: [32]u8, generation: u64, previous_epoch: u64, event_sequence: u64, record: feed.RawRecord };

pub const Runtime = struct {
    configuration: Configuration,
    resources: Resources,
    owner: *Owner,
    gateway: *execution.Gateway,
    private: hl.HyperliquidVenueAdapter,
    feeds: [8]feed.HyperliquidMarketFeed = undefined,
    private_raw: raw.DurableSink,
    market_raw: raw.DurableSink,
    epoch_stream: durable.StreamIdentity,
    epochs: EpochState,
    configuration_identity: [32]u8,
    closed: bool = false,

    /// Configuration strings and resources must outlive this stable destination.
    pub fn initInto(self: *Runtime, allocator: std.mem.Allocator, configuration: Configuration, resources: Resources, owner: *Owner, gateway: *execution.Gateway, clock: hl.Clock, budget: *hl.Budget, private_raw: raw.DurableSink, market_raw: raw.DurableSink, epoch_stream: durable.StreamIdentity) !void {
        try configuration.validate();
        const p = configuration.profile;
        const mode = std.meta.activeTag(resources);
        if ((mode == .offline) != (p.environment == .simulation) or epoch_stream.domain != .control or epoch_stream.id == 0 or
            private_raw.stream.domain != .raw_ingress or market_raw.stream.domain != .raw_ingress or private_raw.stream.id == market_raw.stream.id or
            owner.closed or budget.limit < 2 or budget.limit > 1200) return error.InvalidRuntimeBinding;
        if (gateway.durable_dispatch) |dispatch| if (epoch_stream.id == dispatch.stream.id) return error.InvalidRuntimeBinding;
        const now = clock.now_fn(clock.ptr).monotonic_time_ns;
        var view: @import("../trading/trading_shard.zig").TradingShard = undefined;
        if (owner.shard.decision_domain_identity == 0) {
            if (owner.shard.exchange_account_identity != p.account) return error.InvalidRuntimeBinding;
            @memcpy(std.mem.asBytes(&view), std.mem.asBytes(&owner.shard));
        } else try owner.shard.copyAccountViewInto(&view, p.account);
        var profile = p;
        var auth = hl.Authorizer{ .ptr = self, .sign_fn = denySign, .check_fn = denyCheck };
        const transport = switch (resources) {
            .offline => |injected| blk: {
                auth = injected.authorizer;
                profile.can_trade = true;
                break :blk injected.transport;
            },
            .read_only => |transport| transport,
            .testnet_write => |write| blk: {
                if (!write.hyperliquid_testnet_write_authorized or now >= write.expires_monotonic_ns or
                    write.wallet.wallet.metadata.environment != .testnet or write.wallet.wallet.metadata.account != p.account or
                    write.wallet.wallet.session() != p.session or !std.mem.eql(u8, &write.wallet.wallet.funding_account, &p.funding)) return error.TestnetWriteNotAuthorized;
                try write.wallet.guard.check(now, write.wallet.wallet.owner_token, false);
                auth = .{ .ptr = self, .sign_fn = sign, .check_fn = check };
                profile.can_trade = true;
                break :blk write.transport;
            },
        };
        var capability: ?execution.CapabilityProfile = null;
        const environment: @import("../trading/trading_shard_event.zig").CapabilityProfileActivation.Environment = if (mode == .offline) .simulation else .testnet;
        var products: u8 = 0;
        for (p.bindings) |binding| {
            const entry = view.instrument_registry.get(binding.instrument) orelse return error.InstrumentNotActivated;
            const fact = entry.capability orelse return error.CapabilityNotActivated;
            if (entry.venue != p.venue or entry.product != binding.product or !entry.margin_configured or
                entry.rules.version != p.rules_version or fact.exchange_account != p.account or fact.venue != p.venue or
                fact.environment != environment or fact.config_version != p.config_version or
                fact.version != p.version or fact.adapter_session != p.session or fact.supports_native_amend or fact.supports_market_protection)
                return error.CapabilityMismatch;
            const scoped: execution.CapabilityProfile = .{ .version = fact.version, .rules_version = fact.rules_version, .config_version = fact.config_version, .session = fact.adapter_session, .supports_place = fact.supports_place, .supports_cancel = fact.supports_cancel, .supports_post_only = fact.supports_post_only, .supports_venue_reduce_only = fact.supports_venue_reduce_only };
            if (capability) |known| {
                if (!std.meta.eql(known, scoped)) return error.CapabilityMismatch;
            } else capability = scoped;
            products |= execution.productMask(binding.product);
        }
        const restored_private = if (configuration.epoch_startup == .recover) try recoverRaw(private_raw) else private_raw;
        const restored_market = if (configuration.epoch_startup == .recover) try recoverRaw(market_raw) else market_raw;
        if (restored_market.next_sequence > 1) {
            var replay: MarketReplay = undefined;
            try MarketReplay.initInto(&replay, configuration, owner, allocator);
            try raw.replayCommitted(restored_market.store, restored_market.io, restored_market.stream, replay.consumer());
            try replay.finish();
        }
        const epochs: EpochState = if (configuration.epoch_startup == .virgin) .{ .venue = p.venue, .account = p.account } else try restoreEpochs(private_raw.store, private_raw.io, epoch_stream, p.venue, p.account);
        self.* = .{ .configuration = configuration, .resources = resources, .owner = owner, .gateway = gateway, .private_raw = restored_private, .market_raw = restored_market, .epoch_stream = epoch_stream, .epochs = epochs, .configuration_identity = try configuration.identity(), .private = .{ .profile = profile, .clock = clock, .auth = auth, .raw_sink = .{ .ptr = self, .append_fn = privateAppend }, .transport = transport, .budget = budget, .fencing_token = owner.shard.fencing_token } };
        errdefer self.closed = true;
        try self.private.adapter().start(.{ .venue = p.venue, .environment = p.environment, .exchange_account = p.account, .adapter_session = p.session, .request_capacity = 1, .output_capacity = 32, .asset_definitions = view.activatedAssets(), .instrument_definitions = view.instrument_registry, .native_settlement_atoms = mode != .offline });
        for (configuration.feeds, 0..) |f, index| {
            self.feeds[index] = feed.HyperliquidMarketFeed.init(f.binding, .{ .ptr = self, .append_fn = marketAppend }, self.epochFor(f.binding.instrument));
            try self.feeds[index].adapter().start(.{ .venue = p.venue, .environment = if (mode == .offline) .simulation else .testnet, .subscription_set = f.subscription_set, .session = f.session, .config_version = p.config_version, .output_capacity = 32 });
            for (owner.shard.canonical_ingress_cursors[0..owner.shard.canonical_ingress_cursor_count]) |cursor| if (cursor.scope.venue == p.venue and cursor.scope.account == null and cursor.identity.stream == f.session) {
                self.feeds[index].event_sequence = cursor.identity.sequence;
            };
        }
        var incarnation = self.epochs;
        incarnation.generation = try std.math.add(u64, incarnation.generation, 1);
        try self.persistEpochs(incarnation);
        try gateway.add(.{ .account = p.account, .adapter = self.private.adapter(), .venue_identity = p.venue, .environment = if (mode == .offline) .simulation else .testnet, .capability = capability.?, .supported_products = products, .lease_guard = if (resources == .testnet_write) resources.testnet_write.wallet.guard else null });
    }

    /// Epoch consumption is durable before subscribe. A crash may waste an epoch.
    pub fn subscribe(self: *Runtime, allocator: std.mem.Allocator, index: usize, times: feed.Times) !u64 {
        const epoch = try self.reserveEpoch(index, times.monotonic_time_ns);
        try self.feeds[index].ingest(allocator, epoch, .subscribe, times, "subscribe");
        return epoch;
    }

    pub fn reserveEpoch(self: *Runtime, index: usize, now: u64) !u64 {
        if (self.closed or index >= self.configuration.feeds.len) return error.RuntimeClosed;
        if (!self.private.budget.take(now, false, 1)) return error.RateLimited;
        var next = self.epochs;
        const instrument = self.configuration.feeds[index].binding.instrument;
        var slot: ?*Epoch = null;
        for (&next.entries) |*entry| if (entry.instrument == instrument) {
            slot = entry;
            break;
        };
        if (slot == null) for (&next.entries) |*entry| if (entry.instrument == 0) {
            slot = entry;
            break;
        };
        const selected = slot orelse return error.EpochCapacity;
        selected.instrument = instrument;
        selected.value = try std.math.add(u64, selected.value, 1);
        try self.persistEpochs(next);
        return selected.value;
    }

    fn persistEpochs(self: *Runtime, candidate: EpochState) !void {
        var next = candidate;
        next.barrier = try std.math.add(u64, next.barrier, 1);
        var bytes: [512]u8 = undefined;
        const encoded = try codec.encodeBare(&bytes, next);
        self.private_raw.store.append(self.private_raw.io, .{ .stream = self.epoch_stream, .record = .{ .type_id = 0x4845, .schema_version = @import("production_contract.zig").journal_schema_version, .flags = 0, .sequence = next.barrier, .source_time = 0, .receive_time = 0, .monotonic_time = 0, .wall_time = 0, .time_presence = .{}, .payload = encoded } }) catch {
            self.closed = true;
            return error.EpochUnavailable;
        };
        self.private_raw.store.commit(self.private_raw.io, self.epoch_stream, next.barrier) catch {
            self.closed = true;
            return error.EpochUnavailable;
        };
        self.epochs = next;
        self.private_raw.store.seal(self.private_raw.io, self.epoch_stream) catch {
            self.closed = true;
            return error.EpochUnavailable;
        };
        self.private_raw.store.publishSnapshot(self.private_raw.io, self.epoch_stream, next.barrier, encoded) catch {
            self.closed = true;
            return error.EpochUnavailable;
        };
        self.private_raw.store.rotate(self.private_raw.io, self.epoch_stream) catch {
            self.closed = true;
            return error.EpochUnavailable;
        };
    }

    pub fn send(self: *Runtime, command: u64, now: u64) !venue.SendResult {
        if (self.closed) return error.RuntimeClosed;
        switch (self.resources) {
            .read_only => return error.ReadOnly,
            .testnet_write => |write| {
                if (now >= write.expires_monotonic_ns) return error.TestnetWriteNotAuthorized;
                return self.owner.send(self.gateway, write.wallet.guard, command, now);
            },
            .offline => return self.gateway.sendFromShard(&self.owner.shard, command, now),
        }
    }

    /// Bounded single sweep; other accounts retain their own fair Gateway drain.
    pub fn drain(self: *Runtime) !void {
        if (self.closed) return error.RuntimeClosed;
        errdefer self.closed = true;
        if (try self.private.adapter().tryDrain()) |batch| try self.owner.applyAdapterBatch(batch);
        for (self.feeds[0..self.configuration.feeds.len]) |*source| if (try source.adapter().tryDrain()) |batch| try self.owner.applyAdapterBatch(batch);
    }

    fn epochFor(self: *const Runtime, instrument: u128) u64 {
        for (self.epochs.entries) |entry| if (entry.instrument == instrument) return entry.value;
        return 0;
    }
    fn denySign(_: *anyopaque, _: @import("../adapters/hyperliquid/hyperliquid_signer.zig").Request) anyerror!@import("../adapters/hyperliquid/hyperliquid_signer.zig").SignedAction {
        return error.ReadOnly;
    }
    fn denyCheck(_: *anyopaque, _: u64, _: u64, _: bool) anyerror!void {
        return error.ReadOnly;
    }
    fn check(ptr: *anyopaque, now: u64, token: u64, increases_risk: bool) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(ptr));
        if (self.closed or self.resources != .testnet_write) return error.ReadOnly;
        const write = self.resources.testnet_write;
        if (!write.hyperliquid_testnet_write_authorized or now >= write.expires_monotonic_ns) return error.TestnetWriteNotAuthorized;
        const auth = write.wallet.interface();
        try auth.check_fn(auth.ptr, now, token, increases_risk);
    }
    fn sign(ptr: *anyopaque, request: @import("../adapters/hyperliquid/hyperliquid_signer.zig").Request) anyerror!@import("../adapters/hyperliquid/hyperliquid_signer.zig").SignedAction {
        const self: *Runtime = @ptrCast(@alignCast(ptr));
        try check(ptr, request.now_monotonic_ns, request.fencing_token, request.increases_risk);
        const auth = self.resources.testnet_write.wallet.interface();
        return auth.sign_fn(auth.ptr, request);
    }
    fn privateAppend(ptr: *anyopaque, record: hl.RawRecord, bytes: []const u8) hl.RawError!u64 {
        const self: *Runtime = @ptrCast(@alignCast(ptr));
        const p = self.configuration.profile;
        if (self.closed or record.venue != p.venue or record.account != p.account or record.session != p.session or record.environment != p.environment or !std.mem.eql(u8, &record.funding, &p.funding)) return error.Unavailable;
        const sink = self.private_raw.interface();
        return sink.append_fn(sink.ptr, .{ .origin = @intFromEnum(record.input), .source_session = @intCast(record.session), .receive_time_utc_ns = record.times.receive_time_utc_ns, .monotonic_time_ns = record.times.monotonic_time_ns, .wall_time_utc_ns = record.times.wall_time_utc_ns, .byte_len = record.byte_len, .sha256 = record.sha256 }, bytes);
    }
    fn marketAppend(ptr: *anyopaque, record: feed.RawRecord, bytes: []const u8) feed.RawError!u64 {
        const self: *Runtime = @ptrCast(@alignCast(ptr));
        if (self.closed or record.venue != self.configuration.profile.venue) return error.Unavailable;
        for (self.configuration.feeds, 0..) |f, index| if (f.binding.instrument == record.instrument and f.session == record.session and f.subscription_set == record.stream) {
            const sink = self.market_raw.interface();
            var storage: [512]u8 = undefined;
            const header = codec.encodeBare(&storage, MarketHeader{ .configuration = self.configuration_identity, .generation = self.epochs.generation, .previous_epoch = self.feeds[index].epoch, .event_sequence = self.feeds[index].event_sequence, .record = record }) catch return error.Unavailable;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(header, &digest, .{});
            _ = try sink.append_fn(sink.ptr, .{ .origin = market_header_origin, .source_session = @intCast(record.session), .receive_time_utc_ns = record.times.receive_time_utc_ns, .monotonic_time_ns = record.times.monotonic_time_ns, .wall_time_utc_ns = record.times.wall_time_utc_ns, .byte_len = @intCast(header.len), .sha256 = digest }, header);
            return sink.append_fn(sink.ptr, .{ .origin = @intFromEnum(record.input), .source_session = @intCast(record.session), .receive_time_utc_ns = record.times.receive_time_utc_ns, .monotonic_time_ns = record.times.monotonic_time_ns, .wall_time_utc_ns = record.times.wall_time_utc_ns, .byte_len = record.byte_len, .sha256 = record.sha256 }, bytes);
        };
        return error.Unavailable;
    }
};

/// Read-only raw reconstruction uses the configuration that captured this stream.
/// It never consults the latest epoch high-water mark or owns a transport.
pub const MarketReplay = struct {
    configuration: Configuration,
    owner: *Owner,
    allocator: std.mem.Allocator,
    feeds: [8]feed.HyperliquidMarketFeed = undefined,
    pending: ?MarketHeader = null,
    generations: [8]u64 = @splat(0),
    configuration_identity: [32]u8,

    pub fn initInto(self: *MarketReplay, configuration: Configuration, owner: *Owner, allocator: std.mem.Allocator) !void {
        try configuration.validate();
        self.* = .{ .configuration = configuration, .owner = owner, .allocator = allocator, .configuration_identity = try configuration.identity() };
        for (configuration.feeds, 0..) |f, index| {
            self.feeds[index] = feed.HyperliquidMarketFeed.init(f.binding, .{ .ptr = self, .append_fn = denyCapture }, 0);
            try self.feeds[index].adapter().start(.{ .venue = configuration.profile.venue, .environment = if (configuration.profile.environment == .simulation) .simulation else .testnet, .subscription_set = f.subscription_set, .session = f.session, .config_version = configuration.profile.config_version, .output_capacity = 32 });
        }
    }
    pub fn consumer(self: *MarketReplay) raw.ReplayConsumer {
        return .{ .ptr = self, .consume_fn = consume };
    }
    pub fn finish(self: *const MarketReplay) !void {
        if (self.pending != null) return error.IncompleteMarketCapture;
    }
    fn denyCapture(_: *anyopaque, _: feed.RawRecord, _: []const u8) feed.RawError!u64 {
        return error.Unavailable;
    }
    fn consume(ptr: *anyopaque, sequence: u64, record: @import("../adapters/okx/okx_public_market.zig").RawIngressRecord, bytes: []const u8) !void {
        const self: *MarketReplay = @ptrCast(@alignCast(ptr));
        if (record.origin == market_header_origin) {
            if (self.pending != null) return error.IncompleteMarketCapture;
            const header = try codec.decodeBare(bytes, MarketHeader);
            if (header.schema != 1 or !std.mem.eql(u8, &header.configuration, &self.configuration_identity)) return error.ConfigurationNotApproved;
            self.pending = header;
            return;
        }
        const header = self.pending orelse return error.IncompleteMarketCapture;
        const captured = header.record;
        if (@intFromEnum(captured.input) != record.origin or captured.session != record.source_session or
            captured.times.receive_time_utc_ns != record.receive_time_utc_ns or captured.times.monotonic_time_ns != record.monotonic_time_ns or captured.times.wall_time_utc_ns != record.wall_time_utc_ns or
            captured.byte_len != record.byte_len or !std.mem.eql(u8, &captured.sha256, &record.sha256)) return error.InvalidReplayRoute;
        for (self.configuration.feeds, 0..) |f, index| if (f.binding.instrument == captured.instrument and f.session == captured.session and f.subscription_set == captured.stream) {
            if (header.generation == 0 or header.generation < self.generations[index]) return error.InvalidReplayRoute;
            if (header.generation != self.generations[index]) {
                self.generations[index] = header.generation;
                self.feeds[index] = feed.HyperliquidMarketFeed.init(f.binding, .{ .ptr = self, .append_fn = denyCapture }, header.previous_epoch);
                try self.feeds[index].adapter().start(.{ .venue = self.configuration.profile.venue, .environment = if (self.configuration.profile.environment == .simulation) .simulation else .testnet, .subscription_set = f.subscription_set, .session = f.session, .config_version = self.configuration.profile.config_version, .output_capacity = 32 });
                self.feeds[index].event_sequence = header.event_sequence;
            } else if (header.event_sequence != self.feeds[index].event_sequence or header.previous_epoch != self.feeds[index].epoch) return error.IncompleteMarketCapture;
            var rejection: ?anyerror = null;
            self.feeds[index].replay(self.allocator, captured, .{ .sequence = sequence, .digest = record.sha256 }, bytes) catch |err| {
                rejection = err;
            };
            const output = try self.feeds[index].adapter().tryDrain();
            if (rejection) |err| if (err == error.OutOfMemory or output == null) return err;
            self.pending = null;
            if (output) |batch| {
                var tail: c.AdapterOutputBatch = .{};
                for (batch.slice()) |fact| {
                    var through: u64 = 0;
                    for (self.owner.shard.canonical_ingress_cursors[0..self.owner.shard.canonical_ingress_cursor_count]) |cursor| if (cursor.scope.venue == fact.envelope.venue and cursor.scope.account == null and cursor.identity.stream == fact.envelope.identity.stream) {
                        through = cursor.identity.sequence;
                        break;
                    };
                    if (fact.envelope.identity.sequence >= through) try tail.append(fact);
                }
                try self.owner.applyAdapterBatch(tail);
            }
            return;
        };
        return error.InvalidReplayRoute;
    }
};

fn restoreEpochs(store: durable.Store, io: std.Io, stream: durable.StreamIdentity, venue_id: u64, account: u128) !EpochState {
    const recovered = try store.recover(io, stream);
    if (recovered.gate != .open or recovered.last_sequence != recovered.committed_barrier) return error.EpochUnavailable;
    var state: EpochState = .{ .venue = venue_id, .account = account };
    if (recovered.snapshot.len != 0) state = try codec.decodeBare(recovered.snapshot, EpochState);
    const tails = if (recovered.tail_count != 0) recovered.tail_segments[0..recovered.tail_count] else &.{recovered.tail};
    for (tails) |tail| {
        if (tail.len == 0) continue;
        var reader = try journal.Reader.init(tail);
        while (true) switch (try reader.next()) {
            .end => |end| {
                if (end != .clean and reader.offset != tail.len) return error.EpochUnavailable;
                break;
            },
            .record => |record| {
                if (record.sequence <= state.barrier) continue;
                if (record.sequence != state.barrier + 1 or record.sequence > recovered.committed_barrier or record.type_id != 0x4845 or record.schema_version != @import("production_contract.zig").journal_schema_version) return error.EpochUnavailable;
                state = try codec.decodeBare(record.payload, EpochState);
                if (state.barrier != record.sequence) return error.EpochUnavailable;
            },
        };
    }
    if (state.schema != 1 or state.venue != venue_id or state.account != account or state.barrier != recovered.committed_barrier) return error.EpochUnavailable;
    if (recovered.segment_sealed) {
        var bytes: [512]u8 = undefined;
        try store.publishSnapshot(io, stream, state.barrier, try codec.encodeBare(&bytes, state));
        try store.rotate(io, stream);
    }
    return state;
}

fn recoverRaw(sink: raw.DurableSink) !raw.DurableSink {
    const recovered = try sink.store.recover(sink.io, sink.stream);
    if (recovered.gate == .open) return raw.DurableSink.recover(sink.store, sink.io, sink.stream);
    if (sink.store.safetyGate() == .open and recovered.last_sequence == 0 and recovered.snapshot.len == 0 and recovered.tail.len == 0)
        return raw.DurableSink.init(sink.store, sink.io, sink.stream);
    return error.RawIngressUnavailable;
}
