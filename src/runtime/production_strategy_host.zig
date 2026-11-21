//! Formal engine delivery of committed Writer records to a locally provisioned StrategyHost.
const std = @import("std");
const lifecycle = @import("../strategy/strategy_host_lifecycle.zig");
const bridge = @import("../strategy/strategy_host_gateway.zig");
const checkpoints = @import("../strategy/strategy_host_recovery.zig");
const journal = @import("../persistence/journal.zig");
const trading = @import("../trading/trading_shard.zig");
const market = @import("../market/market_projection.zig");
const Owner = @import("demo/demo_authority.zig").Owner;

const checkpoint_limit = 8 * 1024 * 1024 + 192;
const input_capacity = 16 * 1024;
const output_limit = 16;

pub const Config = struct {
    python: []const u8,
    script: []const u8,
    request: []const u8,
    checkpoint: []const u8,
    checkpoint_sha256: []const u8,
};

const Request = struct {
    binding: struct {
        strategy_identity: []const u8,
        definition_identity: []const u8,
        decision_domain: []const u8,
        portfolio_identity: []const u8,
        config_version: u64,
    },
    manifest: struct {
        state_schema: struct { identity: []const u8, version: u32 },
        compatibility: struct { python_abi: u32 },
        subscriptions: []const struct { event_type: bridge.EventType, schema_version: u16 },
    },
    recover: bool,
    checkpoint_cursor: u64,
    strategy_manifest: []const u8,
    checkpoint_manifest: []const u8,
};

pub const Host = struct {
    process: lifecycle.ManagedHost,
    gateway: bridge.Gateway,
    projection: market.Projection = .{},
    cursor: u64,
    delivered_events: u64 = 0,
    activation_ack: ?u64 = null,

    pub fn start(init: std.process.Init, owner: *Owner, generation: u64, config: Config) !*Host {
        for ([_][]const u8{ config.python, config.script, config.request, config.checkpoint }) |path|
            if (!std.fs.path.isAbsolute(path)) return error.InvalidStrategyHostPath;
        const request_bytes = try readBounded(init, config.request, 1024 * 1024);
        defer init.gpa.free(request_bytes);
        const parsed = try std.json.parseFromSlice(Request, init.gpa, request_bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const request = parsed.value;
        const checkpoint = try readBounded(init, config.checkpoint, checkpoint_limit);
        defer init.gpa.free(checkpoint);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(checkpoint, &digest, .{});
        if (!std.mem.eql(u8, &digest, &try parseDigest(config.checkpoint_sha256)) or !request.recover or checkpoint.len < 192)
            return error.InvalidStrategyHostCheckpoint;
        var plan = lifecycle.developmentPlan(0, generation, request.manifest.compatibility.python_abi);
        const metadata: checkpoints.Metadata = .{
            .schema_registry = plan.compatibility.schema_registry,
            .strategy_instance = try parseIdentity(request.binding.strategy_identity),
            .strategy_definition = try parseIdentity(request.binding.definition_identity),
            .state_schema = try parseIdentity(request.manifest.state_schema.identity),
            .state_schema_version = request.manifest.state_schema.version,
            .strategy_config_version = request.binding.config_version,
            .strategy_cursor = request.checkpoint_cursor,
            .next_intent_sequence = std.mem.readInt(u64, checkpoint[104..112], .little),
        };
        _ = try checkpoints.decodePayloadCheckpoint(checkpoint, metadata);
        const shard = try owner.source();
        const authority = shard.strategyAuthority(metadata.strategy_instance);
        const recovery_barrier = shard.authoritativeBarrier();
        if (!authority.strategy_active or shard.strategyFenced(metadata.strategy_instance) or
            authority.strategy_config_version != metadata.strategy_config_version or
            authority.portfolio_identity != try parseIdentity(request.binding.portfolio_identity) or
            shard.decision_domain_identity != try parseIdentity(request.binding.decision_domain) or
            shard.fencing_token == 0 or metadata.strategy_cursor > recovery_barrier)
            return error.InvalidStrategyHostBinding;
        var subscription: bridge.Subscription = .{ .strategy_identity = metadata.strategy_instance, .event_mask = 0 };
        for (request.manifest.subscriptions) |entry| {
            if (entry.schema_version != 1 or (entry.event_type != .depth_snapshot and entry.event_type != .market_trade))
                return error.UnsupportedFormalHostSubscription;
            subscription.event_mask |= bridge.Subscription.of(metadata.strategy_instance, &.{entry.event_type}).event_mask;
        }
        plan.session.fencing = shard.fencing_token;
        plan.decision_domain = shard.decision_domain_identity;
        plan.compatibility.strategy_manifest = try parseDigest(request.strategy_manifest);
        plan.compatibility.checkpoint_manifest = try parseDigest(request.checkpoint_manifest);
        plan.input_capacity = input_capacity;
        const activation_identity = if (authority.host_activation_seen)
            try shard.nextHostActivationIdentityForStrategy(metadata.strategy_instance)
        else
            authority.strategy_activation_identity;
        const activation: bridge.Authorization = .{
            .strategy_identity = metadata.strategy_instance,
            .config_version = metadata.strategy_config_version,
            .activation_identity = activation_identity,
            .activation_barrier = try std.math.add(u64, recovery_barrier, 1),
        };
        const gateway = try bridge.Gateway.init(.{
            .schema_registry = plan.compatibility.schema_registry,
            .decision_domain = plan.decision_domain,
            .session = plan.session,
            .authorization = activation,
        }, &.{subscription});
        var fencing_text: [20]u8 = undefined;
        var generation_text: [20]u8 = undefined;
        const host = try init.gpa.create(Host);
        errdefer init.gpa.destroy(host);
        host.* = .{
            .process = try lifecycle.ManagedHost.start(init, config.python, config.script, plan, "candidate", &.{
                config.request,
                "--engine-session",
                try std.fmt.bufPrint(&fencing_text, "{d}", .{plan.session.fencing}),
                try std.fmt.bufPrint(&generation_text, "{d}", .{generation}),
            }),
            .gateway = gateway,
            .cursor = metadata.strategy_cursor,
        };
        errdefer host.process.deinit(init.io);
        try host.process.sendPlan(init.io);
        if (try host.process.receive(init.io, now(init.io)) != .accepted) return error.StrategyHostHandshake;
        const storage = try init.gpa.alloc(u8, checkpoint_limit + 128);
        defer init.gpa.free(storage);
        try host.process.beginRecovery(init.io, recovery_barrier, checkpoint, storage);
        host.process.last_input_cursor = metadata.strategy_cursor;
        _ = try host.process.receiveBatchAck(init.io, now(init.io), 0);
        // Reconstruct historical public depth before emitting events after the checkpoint.
        try host.deliver(owner, 0, recovery_barrier, true);
        if (try host.process.receive(init.io, now(init.io)) != .accepted) return error.StrategyHostRecovery;
        const recovered = host.process.supervisor.last_recovered orelse return error.StrategyHostRecovery;
        if (recovered.cursor != recovery_barrier or recovered.strategy_identity != metadata.strategy_instance or
            recovered.config_version != metadata.strategy_config_version or recovered.state_schema_identity != metadata.state_schema or
            recovered.state_schema_version != metadata.state_schema_version or recovered.next_intent_sequence < metadata.next_intent_sequence)
            return error.StrategyHostRecoveryMismatch;
        var expected = metadata;
        expected.strategy_cursor = recovered.cursor;
        expected.next_intent_sequence = recovered.next_intent_sequence;
        try host.process.requestCheckpoint(init.io, 1, expected);
        const content = try host.process.receiveCheckpoint(init.io, storage);
        const verified = try checkpoints.decodePayloadCheckpoint(content, expected);
        if (!std.mem.eql(u8, &verified.state_digest, &recovered.state_digest)) return error.StrategyHostRecoveryMismatch;
        std.debug.print("strategy_host_recovery: generation={d} checkpoint={d} replay_through={d} subscribed_events={d} next_intent={d}\n", .{
            generation, metadata.strategy_cursor, recovery_barrier, host.delivered_events, recovered.next_intent_sequence,
        });

        const core_digest = (try owner.source()).canonicalStateDigest();
        _ = try owner.apply(.{ .core = .{
            .identity = activation.activation_barrier,
            .payload = .{ .host_activated = .{
                .strategy_identity = activation.strategy_identity,
                .config_version = activation.config_version,
                .activation_identity = activation.activation_identity,
                .session = plan.session,
                .activation_barrier = activation.activation_barrier,
                .state_digest = core_digest,
            } },
        } });
        errdefer revoke(owner, activation) catch |err| std.log.err("strategy_host_revoke: {s}", .{@errorName(err)});
        const applied = try (try owner.source()).appliedHostActivationForStrategy(&owner.decision_journal, activation.strategy_identity);
        if (applied.fact_sequence != activation.activation_barrier or !std.meta.eql(applied.authorization, activation) or
            !std.meta.eql(applied.session, plan.session)) return error.StrategyHostActivationMismatch;
        try host.process.activate(init.io, .{
            .strategy_identity = activation.strategy_identity,
            .activation_identity = activation.activation_identity,
            .barrier = applied.fact_sequence,
            .state_digest = applied.state_digest,
        });
        // Coverage includes the committed HostActivated fact. A zero-output ACK
        // at this exact sequence is required before accepting any active batch.
        try host.deliver(owner, recovery_barrier, applied.fact_sequence, true);
        host.activation_ack = applied.fact_sequence;
        std.debug.print("strategy_host_activation: generation={d} committed={d} ack={d} outputs_before_ack=0\n", .{
            generation, applied.fact_sequence, host.activation_ack.?,
        });
        try host.pump(owner);
        return host;
    }

    pub fn pump(self: *Host, owner: *Owner) !void {
        if (self.activation_ack == null) return error.StrategyHostActivationMissing;
        try self.deliver(owner, self.cursor, (try owner.source()).authoritativeBarrier(), false);
    }

    pub fn readyStrategy(self: *const Host, owner: *const Owner) !?u128 {
        const acknowledged = self.activation_ack orelse return null;
        const authorization = self.gateway.config.authorization;
        const shard = try owner.source();
        const current = shard.strategyAuthority(authorization.strategy_identity);
        if (current.host_activation_fact_sequence != acknowledged or
            current.host_activation_identity != authorization.activation_identity or
            !std.meta.eql(current.host_activation_session, self.process.supervisor.plan.session)) return null;
        return authorization.strategy_identity;
    }

    pub fn close(self: *Host, init: std.process.Init) void {
        self.process.deinit(init.io);
        init.gpa.destroy(self);
    }

    fn deliver(self: *Host, owner: *Owner, after: u64, through: u64, suppress: bool) !void {
        if (after == through) return;
        var delivery: Delivery = .{ .host = self, .io = owner.io, .seen = after, .through = through, .suppress = suppress };
        try owner.store.replaySegmentsAfter(owner.io, owner.stream, after, std.math.maxInt(usize), .{
            .ptr = &delivery,
            .consume_fn = Delivery.segment,
        });
        if (delivery.seen != through or self.cursor != through) return error.StrategyHostSequenceGap;
    }
};

const Delivery = struct {
    host: *Host,
    io: std.Io,
    seen: u64,
    through: u64,
    suppress: bool,

    fn segment(context: *anyopaque, bytes: []const u8) !void {
        const self: *Delivery = @ptrCast(@alignCast(context));
        var reader = try journal.Reader.init(bytes);
        while (true) switch (try reader.next()) {
            .end => return,
            .record => |record| {
                if (record.sequence <= self.seen) continue;
                if (record.sequence > self.through) return;
                if (record.sequence != self.seen + 1) return error.StrategyHostSequenceGap;
                self.seen = record.sequence;
                var payload: [input_capacity]u8 = undefined;
                const event = try self.project(record, &payload);
                if (record.sequence <= self.host.cursor) continue;
                const events: []const bridge.EventEnvelope = if (event) |item| &.{item} else &.{};
                try self.send(record.sequence, events);
            },
        };
    }

    fn project(self: *Delivery, record: journal.Record, payload: []u8) !?bridge.EventEnvelope {
        if (record.flags & journal.input_flag == 0 or record.flags >> 8 != 0) return null;
        const input = try trading.decodeStableInput(record);
        if (input == .core and self.subscribed(.depth_snapshot)) {
            if (input.core.payload == .instrument_rules_activated) {
                const rules = input.core.payload.instrument_rules_activated;
                try self.host.projection.apply(.{ .instrument_definition_observed = .{
                    .instrument = rules.instrument_identity,
                    .rules_version = rules.version,
                } });
                try self.host.projection.activateRules(rules.instrument_identity, rules.version);
            }
        }
        if (input != .venue) return null;
        const venue = input.venue;
        switch (venue.event) {
            .market_trade => return if (record.sequence > self.host.cursor and self.subscribed(.market_trade))
                try bridge.marketTradeInput(venue, record.sequence, payload)
            else
                null,
            .instrument_definition_observed, .market_data_health_changed, .l2_book_snapshot, .l2_book_delta => {
                if (!self.subscribed(.depth_snapshot)) return null;
                self.host.projection.apply(venue.event) catch |err| switch (err) {
                    error.MissingBookSnapshot, error.MarketGap, error.ConflictingBookDelta, error.BookSequenceGap => return null,
                    else => return err,
                };
            },
            else => return null,
        }
        if (record.sequence <= self.host.cursor) return null;
        const instrument = switch (venue.event) {
            .l2_book_snapshot => |book| book.instrument,
            .l2_book_delta => |delta| delta.instrument,
            else => return null,
        };
        const projection = self.host.projection.get(instrument) orelse return error.MissingInstrumentDefinition;
        const book = projection.last_book orelse return error.MissingBookSnapshot;
        if (projection.health != .healthy or book.depth == null) return null;
        return try bridge.depthSnapshotInput(&self.host.projection, instrument, record.sequence, payload, std.math.cast(i64, record.monotonic_time) orelse return error.InvalidMarketTime, std.math.cast(i64, record.wall_time) orelse return error.InvalidMarketTime);
    }

    fn subscribed(self: *const Delivery, event_type: bridge.EventType) bool {
        const mask = bridge.Subscription.of(self.host.gateway.config.authorization.strategy_identity, &.{event_type}).event_mask;
        return self.host.gateway.subscription_mask & mask != 0;
    }

    fn send(self: *Delivery, sequence: u64, events: []const bridge.EventEnvelope) !void {
        var bytes: [input_capacity]u8 = undefined;
        const timestamp = now(self.io);
        const batch = try self.host.gateway.encodeBatch(&bytes, self.host.process.next_input_batch, sequence, sequence, timestamp, events);
        try self.host.process.sendInput(self.io, batch, timestamp);
        try self.host.gateway.recordPublished(self.host.process.next_input_batch - 1, sequence, timestamp);
        const outputs = try self.host.process.receiveBatchAck(self.io, now(self.io), if (self.suppress) 0 else output_limit);
        // Formal role risk is locked behind signed control. Drain bounded Host
        // frames here without forwarding them to TradingShard or a Venue.
        for (0..outputs) |_| {
            var storage: [1024]u8 = undefined;
            _ = try self.host.process.receiveOutput(self.io, now(self.io), &storage);
        }
        self.host.gateway.retainLatestPublication();
        self.host.delivered_events += events.len;
        self.host.cursor = sequence;
    }
};

fn revoke(owner: *Owner, auth: bridge.Authorization) !void {
    const seq = try std.math.add(u64, (try owner.source()).authoritativeBarrier(), 1);
    _ = try owner.apply(.{ .core = .{ .identity = seq, .payload = .{ .host_activation_revoked = .{
        .strategy_identity = auth.strategy_identity,
        .activation_identity = auth.activation_identity,
        .reason = .control,
    } } } });
}

fn readBounded(init: std.process.Init, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(limit));
}

fn parseIdentity(value: []const u8) !u128 {
    if (value.len != 32) return error.InvalidStrategyHostIdentity;
    const identity = try std.fmt.parseInt(u128, value, 16);
    if (identity == 0) return error.InvalidStrategyHostIdentity;
    return identity;
}

fn parseDigest(value: []const u8) ![32]u8 {
    if (value.len != 64) return error.InvalidStrategyHostDigest;
    var bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, value);
    return bytes;
}

fn now(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}
