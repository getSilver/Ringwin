//! Node-owned package admission. The embedding single Writer commits every
//! fact through its existing durable owner; package IPC never owns this state.
const std = @import("std");
const trading = @import("../trading/trading_shard.zig");
const gateway = @import("strategy_host_gateway.zig");
const ipc = @import("strategy_host_ipc.zig");
const channel = @import("../control_channel.zig");

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

    const Request = struct {
        operation: []const u8,
        strategy_identity: []const u8,
        envelope: []const u8 = "",
        batch: []const u8 = "",
        frame: []const u8 = "",
        cursor: u64 = 0,
        evidence: ?struct { host_generation: u64, cursor: u64, next_input_batch: u64 } = null,
    };

    pub fn request(self: *Authority, gpa: std.mem.Allocator, bytes: []const u8, key: *const [32]u8, io: std.Io) ![]u8 {
        if (self.journal.last_sequence != self.shard.authoritativeBarrier()) return error.DecisionLogUnavailable;
        if (self.decision_domain != self.shard.operational_state.target_identity or self.fencing != self.shard.fencing_token)
            return error.NodeAuthorityMismatch;
        const parsed = try std.json.parseFromSlice(Request, gpa, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const value = parsed.value;
        if (value.strategy_identity.len != 32 or try std.fmt.parseInt(u128, value.strategy_identity, 16) != self.strategy)
            return error.StrategyIdentityMismatch;
        const op = value.operation;
        if (std.mem.eql(u8, op, "control")) {
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
            const bridge = if (self.bridge) |*b| b else return error.NoHostActivation;
            if (value.frame.len > 2 * gateway.max_group_frame_len or value.frame.len < 256) return error.InvalidOutputFrame;
            var storage: [gateway.max_group_frame_len]u8 = undefined;
            const frame = try std.fmt.hexToBytes(&storage, value.frame);
            const decision = bridge.ingest(frame, @intCast(std.Io.Clock.awake.now(io).nanoseconds));
            try self.commit(self.context, decision.corePayload());
        } else if (std.mem.eql(u8, op, "fault")) {
            try self.revoke();
        } else if (!std.mem.eql(u8, op, "status")) return error.UnknownOperation;
        return self.status(gpa);
    }

    pub fn revoke(self: *Authority) !void {
        const authority = self.shard.strategyAuthority(self.strategy);
        if (authority.host_activation_identity != 0) try self.commit(self.context, .{ .host_activation_revoked = .{
            .strategy_identity = self.strategy,
            .activation_identity = authority.host_activation_identity,
            .reason = .fault,
        } });
        if (self.bridge) |*bridge| bridge.beginRecovery();
        self.applied = false;
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
        }, .{});
    }
};
