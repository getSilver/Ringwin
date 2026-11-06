//! Node-owned package admission. The embedding single Writer commits every
//! fact through its existing durable owner; package IPC never owns this state.
const std = @import("std");
const trading = @import("../trading/trading_shard.zig");
const gateway = @import("strategy_host_gateway.zig");
const ipc = @import("strategy_host_ipc.zig");
const channel = @import("../runtime/control_channel.zig");
const cutover = @import("../runtime/recovery_cutover.zig");
const native = @import("native_instance.zig");

/// The node supplies these bindings from its sealed deployment, never from Web input.
pub const AuthoritySet = struct {
    members: []*Authority,

    pub fn request(self: AuthoritySet, gpa: std.mem.Allocator, bytes: []const u8, key: *const [32]u8, io: std.Io) ![]u8 {
        if (self.members.len == 0 or self.members.len > 16) return error.InvalidAuthorityPlacement;
        for (self.members, 0..) |member, index| {
            for (self.members[0..index]) |previous| {
                if (member.strategy == previous.strategy) return error.InvalidAuthorityPlacement;
            }
        }
        const parsed = try std.json.parseFromSlice(Authority.Request, gpa, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const identity = try nativeIdentity(parsed.value.strategy_identity);
        for (self.members) |member| {
            if (member.strategy != identity and member.native_candidate_strategy != identity) continue;
            const result = try member.request(gpa, bytes, key, io);
            const beginning = std.mem.eql(u8, parsed.value.operation, "begin_config") or std.mem.eql(u8, parsed.value.operation, "begin_successor");
            if (beginning) {
                defer gpa.free(result);
                for (self.members) |peer| {
                    if (peer != member and peer.shard == member.shard) try peer.revokeFor(.control);
                }
                const evidence = parsed.value.evidence orelse return error.ReadyEvidenceRequired;
                return member.configBatch(gpa, evidence.host_generation, evidence.next_input_batch, evidence.cursor, io);
            }
            return result;
        }
        // The existing successor validator owns new native candidates.
        if (self.members.len == 1) return self.members[0].request(gpa, bytes, key, io);
        return error.StrategyIdentityMismatch;
    }

    fn nativeIdentity(value: []const u8) !u128 {
        if (value.len != 32) return error.StrategyIdentityMismatch;
        const identity = try std.fmt.parseInt(u128, value, 16);
        if (identity == 0) return error.StrategyIdentityMismatch;
        return identity;
    }
};

pub const Authority = struct {
    shard: *trading.TradingShard,
    journal: *trading.journal.Journal,
    context: *anyopaque,
    commit: *const fn (*anyopaque, trading.CorePayload) anyerror!void,
    strategy: u128,
    config_version: u64,
    schema_registry: u128,
    decision_domain: u128,
    fencing: u64,
    shard_id: u32,
    max_outputs: u64,
    bridge: ?gateway.Gateway = null,
    applied: bool = false,
    last_cursor: u64 = 0,
    reconciliation: ?*const fn (*anyopaque) anyerror!cutover.VenueEvidence = null,
    running_binary_sha256: ?[64]u8 = null,
    native_instance: ?native.Instance = null,
    native_candidate: ?native.Instance = null,
    native_candidate_strategy: u128 = 0,
    native_candidate_release: u64 = 0,
    native_candidate_config: u64 = 0,

    const Request = struct {
        operation: []const u8,
        strategy_identity: []const u8,
        envelope: []const u8 = "",
        batch: []const u8 = "",
        frame: []const u8 = "",
        cursor: u64 = 0,
        config_version: u64 = 0,
        definition_identity: []const u8 = "",
        state_schema_version: u32 = 0,
        transition: []const u8 = "",
        operation_identity: []const u8 = "",
        successor_identity: []const u8 = "",
        release_identity: u64 = 0,
        current_release_identity: u64 = 0,
        current_definition_identity: []const u8 = "",
        current_state_schema_version: u32 = 0,
        build_inventory: []const u8 = "",
        binary_sha256: []const u8 = "",
        config_json: []const u8 = "",
        pair_request: ?@import("../trading/pair_trading_authorization.zig").Request = null,
        evidence: ?struct { host_generation: u64, cursor: u64, next_input_batch: u64 } = null,
    };

    pub fn request(self: *Authority, gpa: std.mem.Allocator, bytes: []const u8, key: *const [32]u8, io: std.Io) ![]u8 {
        if (self.journal.last_sequence != self.shard.authoritativeBarrier()) return error.DecisionLogUnavailable;
        if (self.decision_domain != self.shard.operational_state.target_identity or self.fencing != self.shard.fencing_token)
            return error.NodeAuthorityMismatch;
        const parsed = try std.json.parseFromSlice(Request, gpa, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const value = parsed.value;
        if (std.mem.eql(u8, value.operation, "native_prepare")) {
            const binary = self.running_binary_sha256 orelse return error.NativeRunningIdentityUnavailable;
            if (!std.mem.eql(u8, &binary, value.binary_sha256)) return error.NativeRunningBinaryMismatch;
            try native.verifyBuild(gpa, value.build_inventory);
            const definition = try @import("native_definition.zig").identity(value.definition_identity);
            const strategy = try @import("native_definition.zig").identity(value.strategy_identity);
            if (value.release_identity == 0 or value.config_version == 0 or self.shard.strategyFenced(strategy)) return error.StrategyBindingMismatch;
            var instance = try native.Instance.create(gpa, definition, value.config_json);
            if (self.shard.registryInstrument(instance.config.instrument) == null) return error.StrategyBindingMismatch;
            try instance.catchUp(self.journal, self.shard.authoritativeBarrier());
            if (strategy == self.strategy) {
                if (self.applied or value.config_version != self.config_version) return error.StrategyBindingMismatch;
                if (self.shard.active_release != 0 and self.shard.active_release != value.release_identity) return error.StrategyBindingMismatch;
                const binding = self.shard.strategyAuthority(strategy);
                if (!binding.strategy_active or binding.strategy_config_version != value.config_version or
                    binding.host_activation_identity != 0 or self.shard.operational_state.effectiveTradingAuthority()) return error.StrategyBindingMismatch;
                if (self.native_instance) |current| {
                    if (current.definition != definition or !std.meta.eql(current.config, instance.config)) return error.StrategyBindingMismatch;
                }
                if (self.shard.active_release == 0) {
                    try self.commit(self.context, .{ .version_activation = .{
                        .activation_identity = value.release_identity,
                        .generation = self.shard.release_generation + 1,
                        .old_release = 0,
                        .new_release = value.release_identity,
                        .old_strategy_instance = self.shard.active_strategy_instance,
                        .new_strategy_instance = strategy,
                        .strategy_definition = definition,
                        .parameter_version = value.config_version,
                        .state_schema_version = (@import("native_registry.zig").find(definition) orelse return error.NativeDefinitionNotRegistered).state_schema.version,
                        .transition = .rebuild,
                        .barrier = self.shard.authoritativeBarrier() + 1,
                        .canonical_state_digest = self.shard.canonicalStateDigest(),
                    } });
                    try instance.catchUp(self.journal, self.shard.authoritativeBarrier());
                } else {
                    var reader = try trading.journal.Reader.init(self.journal.bytes());
                    var matched = false;
                    while (true) switch (try reader.next()) {
                        .record => |record| {
                            if (record.flags & trading.journal.input_flag == 0) continue;
                            const input = try trading.decodeStableInput(record);
                            if (input == .core and input.core.payload == .version_activation) {
                                const activation = input.core.payload.version_activation;
                                matched = activation.new_strategy_instance == strategy and activation.strategy_definition == definition and
                                    activation.new_release == value.release_identity and activation.parameter_version == value.config_version;
                            }
                        },
                        .end => break,
                    };
                    if (!matched) return error.StrategyBindingMismatch;
                }
                self.native_instance = instance;
            } else {
                if (self.shard.strategyAuthority(strategy).strategy_active) return error.StrategyBindingMismatch;
                self.native_candidate = instance;
                self.native_candidate_strategy = strategy;
                self.native_candidate_release = value.release_identity;
                self.native_candidate_config = value.config_version;
            }
            return self.nativeSnapshot(gpa, instance);
        }
        if (std.mem.eql(u8, value.operation, "native_catchup")) {
            const strategy = try @import("native_definition.zig").identity(value.strategy_identity);
            const instance = if (strategy == self.strategy) current: {
                break :current if (self.native_instance) |*n| n else return error.NativeNotReady;
            } else candidate: {
                if (strategy != self.native_candidate_strategy) return error.StrategyIdentityMismatch;
                break :candidate if (self.native_candidate) |*n| n else return error.NativeNotReady;
            };
            try instance.catchUp(self.journal, self.shard.authoritativeBarrier());
            return self.nativeSnapshot(gpa, instance.*);
        }
        if (value.strategy_identity.len != 32 or try std.fmt.parseInt(u128, value.strategy_identity, 16) != self.strategy)
            return error.StrategyIdentityMismatch;
        const op = value.operation;
        if (std.mem.eql(u8, op, "pair_authorization_version")) {
            const version = try std.fmt.allocPrint(gpa, "{d}", .{self.shard.pair_authorizations.version});
            defer gpa.free(version);
            return std.json.Stringify.valueAlloc(gpa, .{ .core_version = version }, .{});
        }
        if (std.mem.eql(u8, op, "pair_authorize") or std.mem.eql(u8, op, "pair_authorization_status")) {
            const request_value = value.pair_request orelse return error.InvalidPairAuthorization;
            if (request_value.strategy != self.strategy) return error.StrategyIdentityMismatch;
            const identity = try std.fmt.allocPrint(gpa, "{d}", .{request_value.identity});
            defer gpa.free(identity);
            if (self.shard.pair_authorizations.receipt(request_value.identity)) |record| {
                if (!std.meta.eql(record.request, request_value)) return error.PairAuthorizationIdentityConflict;
                const version = try std.fmt.allocPrint(gpa, "{d}", .{record.version});
                defer gpa.free(version);
                const barrier = try std.fmt.allocPrint(gpa, "{d}", .{record.barrier});
                defer gpa.free(barrier);
                return std.json.Stringify.valueAlloc(gpa, .{ .identity = identity, .status = "accepted", .core_version = version, .barrier = barrier }, .{});
            }
            if (std.mem.eql(u8, op, "pair_authorization_status"))
                return std.json.Stringify.valueAlloc(gpa, .{ .identity = identity, .status = "unknown" }, .{});
            self.shard.validatePairAuthorization(request_value) catch |err|
                return std.json.Stringify.valueAlloc(gpa, .{ .identity = identity, .status = "rejected", .reason = @errorName(err) }, .{});
            if (request_value.expected_version != self.shard.pair_authorizations.version)
                return std.json.Stringify.valueAlloc(gpa, .{ .identity = identity, .status = "rejected", .reason = "PairAuthorizationVersionConflict" }, .{});
            self.commit(self.context, .{ .pair_trading_authorization = request_value }) catch |err|
                return std.json.Stringify.valueAlloc(gpa, .{ .identity = identity, .status = "unknown", .reason = @errorName(err) }, .{});
            const record = self.shard.pair_authorizations.receipt(request_value.identity) orelse return error.PairConfirmationUnavailable;
            const version = try std.fmt.allocPrint(gpa, "{d}", .{record.version});
            defer gpa.free(version);
            const barrier = try std.fmt.allocPrint(gpa, "{d}", .{record.barrier});
            defer gpa.free(barrier);
            return std.json.Stringify.valueAlloc(gpa, .{ .identity = identity, .status = "accepted", .core_version = version, .barrier = barrier }, .{});
        }
        const successor = std.mem.eql(u8, op, "begin_successor") or std.mem.eql(u8, op, "commit_successor");
        if (successor or std.mem.eql(u8, op, "begin_config") or std.mem.eql(u8, op, "commit_config")) {
            if (self.native_instance != null and !successor) return error.UnsupportedNativeConfigTransition;
            if (self.native_instance != null) {
                const candidate = self.native_candidate orelse return error.NativeNotReady;
                if (value.successor_identity.len != 32 or try std.fmt.parseInt(u128, value.successor_identity, 16) != self.native_candidate_strategy or
                    value.release_identity != self.native_candidate_release or value.config_version != self.native_candidate_config or
                    value.state_schema_version != (@import("native_registry.zig").find(candidate.definition) orelse return error.NativeDefinitionNotRegistered).state_schema.version or
                    try std.fmt.parseInt(u128, value.definition_identity, 16) != candidate.definition)
                    return error.NativeBuildMismatch;
            }
            if ((!successor and value.config_version <= self.config_version) or value.config_version == 0 or value.state_schema_version == 0 or
                (!std.mem.eql(u8, value.transition, "Keep") and !std.mem.eql(u8, value.transition, "Rebuild"))) return error.InvalidConfigTransition;
            const next_strategy = if (successor) blk: {
                if (value.successor_identity.len != 32 or value.release_identity == 0 or !std.mem.eql(u8, value.transition, "Rebuild")) return error.InvalidSuccessorTransition;
                const next = try std.fmt.parseInt(u128, value.successor_identity, 16);
                if (next == 0 or next == self.strategy or self.shard.strategyAuthority(next).strategy_active or self.shard.strategyFenced(next)) return error.InvalidSuccessorTransition;
                try self.shard.requireSuccessorClosure(self.strategy);
                break :blk next;
            } else self.strategy;
            const evidence = value.evidence orelse return error.ReadyEvidenceRequired;
            if (evidence.host_generation == 0 or evidence.next_input_batch == 0 or evidence.cursor != self.shard.authoritativeBarrier()) return error.ReadyBarrierMismatch;
            const reconcile = self.reconciliation orelse return error.VenueReconciliationUnavailable;
            if (value.operation_identity.len != 32 or value.definition_identity.len != 32) return error.InvalidConfigTransition;
            const identity = try std.fmt.parseInt(u128, value.operation_identity, 16);
            const definition = try std.fmt.parseInt(u128, value.definition_identity, 16);
            if (identity == 0 or definition == 0) return error.InvalidConfigTransition;
            const beginning = std.mem.eql(u8, op, "begin_config") or std.mem.eql(u8, op, "begin_successor");
            if (beginning) {
                try self.commit(self.context, .{ .control_command = .{
                    .command_identity = identity,
                    .content_hash = identity,
                    .target_identity = self.decision_domain,
                    .expected_version = self.shard.operational_state.version,
                    .expires_at = std.math.maxInt(u64),
                    .kind = .trading_pause,
                } });
                try self.revokeFor(.control);
            }
            if (self.applied or self.shard.strategyAuthority(self.strategy).host_activation_identity != 0 or
                self.shard.operational_state.effectiveTradingAuthority()) return error.ConfigTransitionNotQuiesced;
            var drain: cutover.Cutover = .{ .phase = .quiescing };
            const venue = try reconcile(self.context);
            try drain.drain(self.shard, venue);
            if (beginning) {
                try self.commit(self.context, .{ .lifecycle_progress = .{
                    .operation_identity = identity,
                    .target_identity = self.decision_domain,
                    .open_orders_closed = true,
                    .reconciliation_complete = true,
                    .position_quantity = venue.portfolio_quantity,
                } });
            }
            if (!beginning) {
                const selected = if (self.shard.active_strategy_instance == 0) self.shard.strategy_identity else self.shard.active_strategy_instance;
                if (selected != self.strategy) {
                    if (value.current_release_identity == 0 or value.current_state_schema_version == 0)
                        return error.StrategyBindingMismatch;
                    const current_definition = try AuthoritySet.nativeIdentity(value.current_definition_identity);
                    var operation_bytes: [16]u8 = undefined;
                    std.mem.writeInt(u128, &operation_bytes, identity, .little);
                    var hash = std.crypto.hash.sha2.Sha256.init(.{});
                    hash.update("RingWin/StrategyTargetSelection/v1\x00");
                    hash.update(&operation_bytes);
                    var digest: [32]u8 = undefined;
                    hash.final(&digest);
                    // Keep selects the target without fencing or changing any other instance.
                    try self.commit(self.context, .{ .version_activation = .{
                        .activation_identity = std.mem.readInt(u128, digest[0..16], .little),
                        .generation = self.shard.release_generation + 1,
                        .old_release = self.shard.active_release,
                        .new_release = if (self.shard.active_release == 0) value.current_release_identity else self.shard.active_release,
                        .old_strategy_instance = self.shard.active_strategy_instance,
                        .new_strategy_instance = self.strategy,
                        .strategy_definition = current_definition,
                        .parameter_version = self.config_version,
                        .state_schema_version = value.current_state_schema_version,
                        .transition = .keep,
                        .barrier = self.shard.authoritativeBarrier() + 1,
                        .canonical_state_digest = self.shard.canonicalStateDigest(),
                    } });
                }
                try self.commit(self.context, .{ .version_activation = .{
                    .activation_identity = identity,
                    .generation = self.shard.release_generation + 1,
                    .old_release = self.shard.active_release,
                    .new_release = if (successor) value.release_identity else if (self.shard.active_release == 0) 1 else self.shard.active_release,
                    .old_strategy_instance = self.shard.active_strategy_instance,
                    .new_strategy_instance = next_strategy,
                    .strategy_definition = definition,
                    .parameter_version = value.config_version,
                    .state_schema_version = value.state_schema_version,
                    .transition = if (std.mem.eql(u8, value.transition, "Keep")) .keep else .rebuild,
                    .barrier = self.shard.authoritativeBarrier() + 1,
                    .canonical_state_digest = self.shard.canonicalStateDigest(),
                } });
                self.config_version = value.config_version;
                self.strategy = next_strategy;
                self.bridge = null;
                if (self.native_candidate_strategy == next_strategy) {
                    self.native_instance = self.native_candidate;
                    self.native_candidate = null;
                    self.native_candidate_strategy = 0;
                }
            }
            return self.configBatch(gpa, evidence.host_generation, evidence.next_input_batch, evidence.cursor, io);
        } else if (std.mem.eql(u8, op, "control")) {
            var envelope: [channel.envelope_len]u8 = undefined;
            if (value.envelope.len != envelope.len * 2) return error.InvalidEnvelope;
            _ = try std.fmt.hexToBytes(&envelope, value.envelope);
            const command = try channel.verify(&envelope, key);
            if (command.target_identity != self.decision_domain) return error.WrongDecisionDomain;
            if (command.kind == .enable_trading) {
                const evidence = value.evidence orelse return error.ReadyEvidenceRequired;
                if (evidence.cursor != self.shard.authoritativeBarrier() or evidence.host_generation == 0 or evidence.next_input_batch == 0 or self.applied)
                    return error.ReadyBarrierMismatch;
                const strategy = self.shard.strategyAuthority(self.strategy);
                if (strategy.strategy_config_version != self.config_version or !strategy.strategy_active)
                    return error.StrategyBindingMismatch;
                try self.commit(self.context, .{ .control_command = command });
                if (!self.shard.operational_state.effectiveTradingAuthority()) return error.TradingSafetyGateClosed;
                const barrier = self.shard.authoritativeBarrier();
                const digest = self.shard.canonicalStateDigest();
                const identity = if (strategy.host_activation_seen)
                    try self.shard.nextHostActivationIdentityForStrategy(self.strategy)
                else
                    strategy.strategy_activation_identity;
                const session: ipc.Session = .{ .fencing = self.fencing, .shard = self.shard_id, .generation = evidence.host_generation };
                try self.commit(self.context, .{ .host_activated = .{
                    .strategy_identity = self.strategy,
                    .config_version = self.config_version,
                    .activation_identity = identity,
                    .activation_barrier = barrier,
                    .session = session,
                    .state_digest = digest,
                } });
                self.bridge = try gateway.Gateway.init(.{
                    .schema_registry = self.schema_registry,
                    .decision_domain = self.decision_domain,
                    .session = session,
                    .authorization = .{ .strategy_identity = self.strategy, .config_version = self.config_version, .activation_identity = identity, .activation_barrier = barrier },
                }, &.{gateway.Subscription.of(self.strategy, &.{ .mark_price, .l2_snapshot, .l2_delta, .timer, .account, .fill, .depth_snapshot })});
                self.last_cursor = evidence.cursor;
                const now_ns: i64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
                if (evidence.next_input_batch > 1) try self.bridge.?.recordPublished(evidence.next_input_batch - 1, evidence.cursor, now_ns);
                var batch_storage: [128]u8 = undefined;
                const batch = try self.bridge.?.encodeBatch(&batch_storage, evidence.next_input_batch, evidence.cursor + 1, self.shard.authoritativeBarrier(), now_ns, &.{});
                try self.bridge.?.recordPublished(evidence.next_input_batch, self.shard.authoritativeBarrier(), now_ns);
                const hex = try std.fmt.allocPrint(gpa, "{x}", .{batch});
                defer gpa.free(hex);
                const identity_text = try std.fmt.allocPrint(gpa, "{x:0>32}", .{identity});
                defer gpa.free(identity_text);
                const digest_text = std.fmt.bytesToHex(digest, .lower);
                return std.json.Stringify.valueAlloc(gpa, .{ .host_command = .{
                    .activation = .{ .identity = identity_text, .barrier = barrier, .state_digest = digest_text[0..] },
                    .batch = hex,
                    .max_outputs = self.max_outputs,
                } }, .{});
            }
            if (command.kind != .trading_pause and command.kind != .stop_keep_positions and command.kind != .kill_switch)
                return error.UnsupportedInstanceCommand;
            try self.commit(self.context, .{ .control_command = command });
            try self.revoke();
        } else if (std.mem.eql(u8, op, "applied")) {
            const bridge = if (self.bridge) |*b| b else return error.NoHostActivation;
            if (self.applied or value.cursor != self.shard.authoritativeBarrier()) return error.ActivationBarrierNotApplied;
            try bridge.activate(self.shard, self.journal);
            self.last_cursor = value.cursor;
            self.applied = true;
        } else if (std.mem.eql(u8, op, "publish")) {
            if (!self.applied) {
                const evidence = value.evidence orelse return error.ReadyEvidenceRequired;
                if (self.shard.strategyAuthority(self.strategy).host_activation_identity != 0 or
                    evidence.host_generation == 0 or evidence.next_input_batch == 0) return error.ActivationBarrierNotApplied;
                self.bridge = try gateway.Gateway.init(.{
                    .schema_registry = self.schema_registry,
                    .decision_domain = self.decision_domain,
                    .session = .{ .fencing = self.fencing, .shard = self.shard_id, .generation = evidence.host_generation },
                    .authorization = .{ .strategy_identity = self.strategy, .config_version = self.config_version, .activation_identity = 0, .activation_barrier = 0 },
                }, &.{gateway.Subscription.of(self.strategy, &.{ .mark_price, .l2_snapshot, .l2_delta, .timer, .account, .fill, .depth_snapshot })});
                self.last_cursor = evidence.cursor;
                if (evidence.next_input_batch > 1) try self.bridge.?.recordPublished(evidence.next_input_batch - 1, evidence.cursor, @intCast(std.Io.Clock.awake.now(io).nanoseconds));
            }
            const bridge = if (self.bridge) |*b| b else return error.NoHostActivation;
            if (self.applied and !self.shard.operational_state.effectiveTradingAuthority()) return error.TradingSafetyGateClosed;
            if (value.batch.len > 2 * 1048576 or value.batch.len < 256) return error.InvalidInputBatch;
            const batch = try gpa.alloc(u8, value.batch.len / 2);
            defer gpa.free(batch);
            _ = try std.fmt.hexToBytes(batch, value.batch);
            const number = if (bridge.published_count == 0) 1 else try std.math.add(u64, bridge.published[bridge.published_count - 1].sequence, 1);
            const now_ns: i64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
            // Only the node supplies these bytes; authority stamps the real session and batch.
            std.mem.writeInt(u64, batch[48..56], bridge.config.session.fencing, .little);
            std.mem.writeInt(u32, batch[56..60], bridge.config.session.shard, .little);
            std.mem.writeInt(u64, batch[64..72], bridge.config.session.generation, .little);
            std.mem.writeInt(u64, batch[72..80], number, .little);
            std.mem.writeInt(i64, batch[96..104], now_ns, .little);
            var crc = std.hash.crc.Crc32Iscsi.init();
            crc.update(batch[0..124]);
            crc.update(batch[128..]);
            std.mem.writeInt(u32, batch[124..128], crc.final(), .little);
            if (std.mem.readInt(u128, batch[16..32], .little) != self.schema_registry or
                std.mem.readInt(u128, batch[32..48], .little) != self.decision_domain or
                ipc.validateBatchAt(batch, bridge.config.session, number, self.last_cursor, now_ns).status != .ok)
                return error.InvalidInputBatch;
            const cursor = std.mem.readInt(u64, batch[88..96], .little);
            if (cursor > self.shard.authoritativeBarrier()) return error.UncommittedInput;
            try bridge.recordPublished(number, cursor, now_ns);
            self.last_cursor = cursor;
            const hex = try std.fmt.allocPrint(gpa, "{x}", .{batch});
            defer gpa.free(hex);
            return std.json.Stringify.valueAlloc(gpa, .{ .host_command = .{ .batch = hex, .max_outputs = self.max_outputs } }, .{});
        } else if (std.mem.eql(u8, op, "output")) {
            if (self.native_instance != null) return error.UnsupportedNativeOutput;
            const bridge = if (self.bridge) |*b| b else return error.NoHostActivation;
            if (value.frame.len > 2 * gateway.max_group_frame_len or value.frame.len < 256) return error.InvalidOutputFrame;
            var storage: [gateway.max_group_frame_len]u8 = undefined;
            const frame = try std.fmt.hexToBytes(&storage, value.frame);
            const decision = bridge.ingest(frame, @intCast(std.Io.Clock.awake.now(io).nanoseconds));
            try self.commit(self.context, decision.corePayload());
        } else if (std.mem.eql(u8, op, "fault")) {
            try self.revoke();
        } else if (std.mem.eql(u8, op, "restart")) {
            try self.revokeFor(.control);
        } else if (!std.mem.eql(u8, op, "status")) return error.UnknownOperation;
        return self.status(gpa);
    }

    pub fn revoke(self: *Authority) !void {
        try self.revokeFor(.fault);
    }

    fn revokeFor(self: *Authority, reason: @import("../trading/trading_shard_event.zig").HostRevocationReason) !void {
        const authority = self.shard.strategyAuthority(self.strategy);
        if (authority.host_activation_identity != 0) try self.commit(self.context, .{ .host_activation_revoked = .{
            .strategy_identity = self.strategy,
            .activation_identity = authority.host_activation_identity,
            .reason = reason,
        } });
        if (self.bridge) |*bridge| bridge.beginRecovery();
        self.applied = false;
    }

    fn configBatch(self: *Authority, gpa: std.mem.Allocator, generation: u64, number: u64, cursor: u64, io: std.Io) ![]u8 {
        self.bridge = try gateway.Gateway.init(.{
            .schema_registry = self.schema_registry,
            .decision_domain = self.decision_domain,
            .session = .{ .fencing = self.fencing, .shard = self.shard_id, .generation = generation },
            .authorization = .{ .strategy_identity = self.strategy, .config_version = self.config_version, .activation_identity = 0, .activation_barrier = 0 },
        }, &.{gateway.Subscription.of(self.strategy, &.{ .mark_price, .l2_snapshot, .l2_delta, .timer, .account, .fill, .depth_snapshot })});
        var storage: [128]u8 = undefined;
        if (number > 1) try self.bridge.?.recordPublished(number - 1, cursor, @intCast(std.Io.Clock.awake.now(io).nanoseconds));
        const batch = try self.bridge.?.encodeBatch(&storage, number, cursor + 1, self.shard.authoritativeBarrier(), @intCast(std.Io.Clock.awake.now(io).nanoseconds), &.{});
        const hex = try std.fmt.allocPrint(gpa, "{x}", .{batch});
        defer gpa.free(hex);
        return std.json.Stringify.valueAlloc(gpa, .{ .host_command = .{ .batch = hex, .max_outputs = self.max_outputs } }, .{});
    }

    fn status(self: *Authority, gpa: std.mem.Allocator) ![]u8 {
        const authority = self.shard.strategyAuthority(self.strategy);
        return std.json.Stringify.valueAlloc(gpa, .{
            .trading_authorized = self.applied and authority.host_activation_identity != 0 and self.shard.operational_state.effectiveTradingAuthority(),
            .operational_version = self.shard.operational_state.version,
            .cursor = self.shard.authoritativeBarrier(),
            .orders = self.shard.oms.order_count,
            .commands = self.shard.oms.command_history_count,
            .last_rejection = @tagName(self.shard.last_reject_reason),
            .config_version = authority.strategy_config_version,
        }, .{});
    }

    fn nativeSnapshot(self: *Authority, gpa: std.mem.Allocator, instance: native.Instance) ![]u8 {
        _ = self;
        const state = try std.json.Stringify.valueAlloc(gpa, instance.state, .{});
        defer gpa.free(state);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(state, &digest, .{});
        const digest_text = std.fmt.bytesToHex(digest, .lower);
        return std.json.Stringify.valueAlloc(gpa, .{
            .cursor = instance.cursor,
            .next_input_batch = 1,
            .next_intent_sequence = 1,
            .state_digest = digest_text[0..],
            .trading_authorized = false,
            .checkpoint = .{ .cursor = instance.cursor, .state = instance.state, .encoding = "native_observer_v1" },
        }, .{});
    }
};
