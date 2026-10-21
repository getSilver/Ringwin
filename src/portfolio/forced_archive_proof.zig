//! Cross-owner closure proof; no I/O or authority grant.
const std = @import("std");
const history = @import("../persistence/business_history.zig");
const coordinator = @import("account_coordinator.zig");
const economics = @import("economics.zig");
const codec = @import("../persistence/snapshot_codec.zig");
const event = @import("../trading/trading_shard_event.zig");
pub const Evidence = struct { proof: history.LookupProof, source: coordinator.ForcedSourceHistory };

pub fn validate(evidence: *const Evidence, applied: economics.AppliedForcedExecution) !economics.ForcedArchiveClosure {
    const root = evidence.proof.root;
    const source = evidence.source;
    if (root.origin.stream.domain != .control or root.origin.account != applied.source.exchange_account or
        source.source.exchange_account != applied.source.exchange_account or source.source.identity != applied.forced.source_identity or
        source.source.payload != .forced_execution or source.count == 0 or source.count > coordinator.max_shards)
        return error.InvalidForcedClosure;
    var bytes: [8192]u8 = undefined;
    const digest = history.hash(try codec.encodeBare(&bytes, source));
    var request = evidence.proof.request;
    request.key = .{ .origin = root.origin, .identity = .{ .coordinator_forced_source = source.source.identity } };
    request.candidate_payload_digest = digest;
    if (try history.verifyResult(request, &evidence.proof, root) != .same) return error.InvalidForcedClosure;
    const original = try codec.decodeBare(applied.source.core_payload_bytes[0..applied.source.core_payload_len], event.VenueForcedExecution);
    var matched = false;
    var quantity: i128 = 0;
    var fees: i128 = 0;
    var penalties: i128 = 0;
    var pnl: i128 = 0;
    for (source.allocations[0..source.count], 0..) |record, record_index| {
        const allocation = record.allocation;
        if (allocation.identity == 0 or allocation.forced_execution_identity != source.source.identity or
            allocation.count == 0 or allocation.count > coordinator.max_shards or
            record.delivered_mask != (@as(u8, 1) << @intCast(allocation.count)) - 1) return error.InvalidForcedClosure;
        for (source.allocations[0..record_index]) |prior| if (prior.allocation.identity == allocation.identity) return error.InvalidForcedClosure;
        for (allocation.slices[0..allocation.count], 0..) |slice, index| {
            for (allocation.slices[0..index]) |prior| if (prior.owner == slice.owner) return error.InvalidForcedClosure;
            quantity = try std.math.add(i128, quantity, slice.position_delta);
            fees = try std.math.add(i128, fees, slice.fee_atoms);
            penalties = try std.math.add(i128, penalties, slice.penalty_atoms);
            pnl = try std.math.add(i128, pnl, slice.realized_pnl_atoms);
            const identity = try std.math.add(u64, try std.math.mul(u64, std.math.cast(u64, allocation.identity) orelse return error.InvalidForcedClosure, coordinator.max_shards), index + 1);
            if (identity != applied.forced.identity) continue;
            const owner = source.owners[@intFromEnum(slice.owner)];
            if (owner.portfolio != applied.source.portfolio or owner.decision_domain == 0) return error.InvalidForcedClosure;
            var fact = source.source;
            fact.identity = identity;
            fact.payload.forced_execution.owner = slice.owner;
            fact.payload.forced_execution.quantity = slice.position_delta;
            fact.payload.forced_execution.realized_pnl_atoms = slice.realized_pnl_atoms;
            fact.payload.forced_execution.fee_atoms = slice.fee_atoms;
            fact.payload.forced_execution.penalty_atoms = slice.penalty_atoms;
            const expected = try coordinator.accountFactEvent(.{ .shard_id = slice.owner, .fact = fact, .allocation_identity = allocation.identity, .slice_index = @intCast(index), .source_identity = source.source.identity });
            if (!std.meta.eql(expected.payload.venue_forced_execution, original) or expected.identity != applied.source.core_event_identity or
                !std.meta.eql(source.source.times, applied.source.core_times)) return error.InvalidForcedClosure;
            matched = true;
        }
    }
    const execution = source.source.payload.forced_execution;
    if (!matched or quantity != execution.quantity or fees != execution.fee_atoms or penalties != execution.penalty_atoms or pnl != execution.realized_pnl_atoms) return error.InvalidForcedClosure;
    return .{ .source_identity = source.source.identity, .coordinator_root = root, .source_record_digest = digest };
}
