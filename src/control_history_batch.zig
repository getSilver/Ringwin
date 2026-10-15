//! Pure retirement selection. Current authority and referenced facts remain hot.
const std = @import("std");
const history = @import("business_history.zig");
const operational = @import("operational.zig");
const codec = @import("snapshot_codec.zig");
const trading = @import("trading_shard.zig");
pub const max_entries = 73;
pub const Qualification = struct {
    origin: history.Origin,
    barrier: u64,
    state_digest: history.Digest,
    command_mask: u32 = 0,
    gate_mask: u16 = 0,
    latch_mask: u16 = 0,
    fence_mask: u8 = 0,
    count: u8 = 0,

    pub fn digest(self: Qualification) history.Digest {
        var bytes: [256]u8 = undefined;
        return history.hash(codec.encodeBare(&bytes, self) catch unreachable);
    }
};
pub fn selected(mask: anytype, index: usize) bool {
    return (mask & (@as(@TypeOf(mask), 1) << @intCast(index))) != 0;
}
pub fn qualify(shard: *const trading.TradingShard, origin: history.Origin, barrier: u64) !Qualification {
    if (origin.stream.domain != .decision_log or origin.account != shard.exchange_account_identity or
        origin.stream.id != (shard.checkpoint orelse return error.OrderArchiveOriginUnavailable).stream or
        barrier != shard.authoritativeBarrier() or shard.pending_history_candidate != null or
        shard.pending_safety_history_candidate != null or shard.deferred_history_admission_count != 0)
        return error.ControlHistoryPinned;
    var result: Qualification = .{ .origin = origin, .barrier = barrier, .state_digest = shard.canonicalStateDigest() };
    const state = &shard.operational_state;
    for (state.command_history[0..state.command_count], 0..) |record, i| {
        if (record.command.command_identity == state.active_operation_identity or
            shard.control_fact_sequences[i] == shard.authority_control_barrier) continue;
        // Resident OMS commands retain the authority used for their own risk
        // decision. Unrelated completed controls do not belong to that proof.
        var referenced = false;
        for (shard.oms.command_history[0..shard.oms.command_history_count]) |command| {
            const authorization = command.authority.trading_authorization;
            if ((authorization.barrier != 0 and authorization.barrier == shard.control_fact_sequences[i]) or
                (authorization.identity != 0 and authorization.identity == record.command.command_identity))
            {
                referenced = true;
                break;
            }
        }
        if (referenced) continue;
        result.command_mask |= @as(u32, 1) << @intCast(i);
        result.count += 1;
    }
    for (state.latches[0..state.latch_count], 0..) |latch, i| {
        if (!latch.resolved) continue;
        var referenced = false;
        for (state.command_history[0..state.command_count], 0..) |record, j|
            if (!selected(result.command_mask, j) and record.command.referenced_latch_identity == latch.identity) {
                referenced = true;
            };
        if (referenced) continue;
        result.latch_mask |= @as(u16, 1) << @intCast(i);
        result.count += 1;
    }
    for (state.gates[0..state.gate_count], 0..) |gate, i| {
        // Lease gates are current authority, not retired observations.
        if (!gate.open or gate.reason == .primary_lease or gate.reason == .risk_lease) continue;
        var pinned = false;
        for (state.latches[0..state.latch_count], 0..) |latch, j|
            if (latch.identity == gate.gate_identity and !selected(result.latch_mask, j)) {
                pinned = true;
            };
        if (pinned) continue;
        result.gate_mask |= @as(u16, 1) << @intCast(i);
        result.count += 1;
    }
    for (shard.fenced_strategy_instances[0..shard.fenced_strategy_count], 0..) |id, i| {
        if (id == shard.active_strategy_instance or id == shard.strategy_identity or
            (shard.host_activation_identity != 0 and id == shard.strategy_identity)) continue;
        var referenced = false;
        for (shard.oms.orders[0..shard.oms.order_count]) |order| if (order.strategy_instance == id) {
            referenced = true;
        };
        if (referenced) continue;
        result.fence_mask |= @as(u8, 1) << @intCast(i);
        result.count += 1;
    }
    if (result.count == 0) return error.ControlHistoryPinned;
    return result;
}
pub const Builder = struct {
    qualification: Qualification,
    bytes: [max_entries][1024]u8 = undefined,
    records: [max_entries]history.Record = undefined,
    entries: [max_entries]history.Entry = undefined,
    count: usize = 0,
    fn add(self: *Builder, identity: history.Identity, value: anytype) !void {
        const encoded = try codec.encodeBare(&self.bytes[self.count], value);
        self.records[self.count] = .{ .bytes = encoded, .payload_digest = history.hash(encoded) };
        self.entries[self.count] = .{ .key = .{ .origin = self.qualification.origin, .identity = identity }, .record_index = @intCast(self.count) };
        self.count += 1;
    }
    // Build in place: slices point into this stationary caller-owned builder.
    pub fn init(self: *Builder, shard: *const trading.TradingShard, origin: history.Origin) !void {
        self.qualification = try qualify(shard, origin, shard.authoritativeBarrier());
        self.count = 0;
        const q = self.qualification;
        for (shard.operational_state.command_history[0..shard.operational_state.command_count], 0..) |record, i|
            if (selected(q.command_mask, i)) {
                try self.add(.{ .operational_command = record.command.command_identity }, record.command);
            };
        for (shard.operational_state.gates[0..shard.operational_state.gate_count], 0..) |gate, i|
            if (selected(q.gate_mask, i)) {
                try self.add(.{ .retired_gate = gate.gate_identity }, gate);
            };
        for (shard.operational_state.latches[0..shard.operational_state.latch_count], 0..) |latch, i|
            if (selected(q.latch_mask, i)) {
                try self.add(.{ .resolved_latch = latch.identity }, latch);
            };
        for (shard.fenced_strategy_instances[0..shard.fenced_strategy_count], 0..) |id, i|
            if (selected(q.fence_mask, i)) {
                try self.add(.{ .strategy_fence = id }, trading.StrategyCutoverFence{ .strategy_instance = id });
            };
        try self.add(.{ .control_archive = q.barrier }, q);
    }
    pub fn batch(self: *const Builder, previous: ?history.Root) history.Batch {
        return .{ .origin = self.qualification.origin, .previous_root = previous, .barrier = self.qualification.barrier, .epoch = if (previous) |root| root.epoch else 1, .qualification_digest = self.qualification.digest(), .records = self.records[0..self.count], .entries = self.entries[0..self.count] };
    }
};

pub fn release(shard: *trading.TradingShard, q: Qualification) !void {
    var count: u8 = 0;
    for (shard.operational_state.command_history[0..shard.operational_state.command_count], 0..) |record, i| {
        if (selected(q.command_mask, i)) continue;
        shard.operational_state.command_history[count] = record;
        shard.control_fact_sequences[count] = shard.control_fact_sequences[i];
        count += 1;
    }
    shard.operational_state.command_count = count;
    @memset(shard.control_fact_sequences[count..], 0);
    count = 0;
    for (shard.operational_state.gates[0..shard.operational_state.gate_count], 0..) |gate, i| {
        if (selected(q.gate_mask, i)) continue;
        shard.operational_state.gates[count] = gate;
        count += 1;
    }
    shard.operational_state.gate_count = count;
    count = 0;
    for (shard.operational_state.latches[0..shard.operational_state.latch_count], 0..) |latch, i| {
        if (selected(q.latch_mask, i)) continue;
        shard.operational_state.latches[count] = latch;
        count += 1;
    }
    shard.operational_state.latch_count = count;
    count = 0;
    for (shard.fenced_strategy_instances[0..shard.fenced_strategy_count], 0..) |id, i| {
        if (selected(q.fence_mask, i)) continue;
        shard.fenced_strategy_instances[count] = id;
        count += 1;
    }
    shard.fenced_strategy_count = count;
    @memset(shard.fenced_strategy_instances[count..], 0);
    shard.archived_control_records = try std.math.add(u64, shard.archived_control_records, q.count);
}
