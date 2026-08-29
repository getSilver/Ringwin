//! Deterministic consumer used to prove the simulated adapter's lifecycle seam.

const canonical = @import("canonical_event.zig");
const std = @import("std");

const SeenFact = struct {
    identity: canonical.SourceFactIdentity,
    fingerprint: u64,
};

pub const Projection = struct {
    seen: [canonical.max_events_per_adapter_batch]SeenFact = undefined,
    seen_count: u8 = 0,
    position_lots: i128 = 0,
    fee_atoms: i128 = 0,
    realized_pnl_atoms: i128 = 0,

    /// Returns false for an idempotent duplicate; conflicting source facts fail closed.
    pub fn apply(self: *Projection, record: canonical.EventRecord) !bool {
        const fingerprint = eventFingerprint(record.event);
        for (self.seen[0..self.seen_count]) |known| if (known.identity == record.envelope.source_fact_identity) {
            if (known.fingerprint != fingerprint) return error.ConflictingSourceFact;
            return false;
        };
        if (self.seen_count == self.seen.len) return error.SourceFactCapacity;
        self.seen[self.seen_count] = .{ .identity = record.envelope.source_fact_identity, .fingerprint = fingerprint };
        self.seen_count += 1;
        switch (record.event) {
            .fill => |fill| try self.applyFill(fill),
            else => {}, // Dispatch and lifecycle reports never post economics.
        }
        return true;
    }

    pub fn applyBatch(self: *Projection, batch: canonical.AdapterOutputBatch) !void {
        for (batch.slice()) |record| _ = try self.apply(record);
    }

    pub fn digest(self: *const Projection) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(std.mem.asBytes(&self.position_lots));
        hasher.update(std.mem.asBytes(&self.fee_atoms));
        hasher.update(std.mem.asBytes(&self.realized_pnl_atoms));
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn applyFill(self: *Projection, fill: canonical.Fill) !void {
        if (fill.quantity.lots <= 0) return error.InvalidFill;
        const signed_lots = if (fill.side == .buy) fill.quantity.lots else std.math.negate(fill.quantity.lots) catch return error.InvalidFill;
        self.position_lots = std.math.add(i128, self.position_lots, signed_lots) catch return error.EconomicOverflow;
        if (fill.fee) |fee| self.fee_atoms = std.math.add(i128, self.fee_atoms, fee.atoms) catch return error.EconomicOverflow;
        if (fill.realized_pnl) |pnl| self.realized_pnl_atoms = std.math.add(i128, self.realized_pnl_atoms, pnl.atoms) catch return error.EconomicOverflow;
    }
};

fn eventFingerprint(event: canonical.CanonicalEvent) u64 {
    return switch (event) {
        .order_dispatch_result => |value| fingerprintPart(value.command),
        .execution_report => |value| fingerprintPart(value.identity ^ value.order ^ @as(u128, @bitCast(value.cumulative_quantity.lots))),
        .fill => |value| fingerprintPart(value.identity ^ value.order ^ @as(u128, @bitCast(value.quantity.lots)) ^ @as(u128, @bitCast(value.price.ticks))),
        .reconciliation_started, .account_reconciliation_started => |identity| fingerprintPart(identity),
        else => 0,
    } ^ @as(u64, @intFromEnum(std.meta.activeTag(event)));
}

fn fingerprintPart(value: u128) u64 {
    return @truncate(value);
}

test "simulated lifecycle makes fill the only economic fact and replays identically" {
    const simulated = @import("simulated_venue.zig");
    const venue = @import("venue_adapter.zig");
    var adapter_state: simulated.SimulatedVenue = .{};
    const adapter = adapter_state.adapter();
    try adapter.start(.{ .venue = 1, .environment = .simulation, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 8 });
    const command: canonical.OrderCommand = .{
        .identity = 7,
        .exchange_account = 2,
        .instrument = 4,
        .client_order_id = try canonical.ClientOrderId.init("projection-7"),
        .capability_version = 1,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 3,
        .dispatch_deadline_monotonic_ns = 1,
        .quantity = .{ .instrument = 4, .rules_version = 1, .lots = 10 },
        .limit_price = .{ .instrument = 4, .rules_version = 1, .ticks = 100 },
        .fee_asset = 5,
        .fee_atoms = 2,
        .realized_pnl_asset = 5,
        .realized_pnl_atoms = 3,
    };
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = command }));
    const batch = (try adapter.tryDrain()).?;
    var live = Projection{};
    try live.applyBatch(batch);
    const initial_digest = live.digest();
    try std.testing.expectEqual(@as(i128, 10), live.position_lots);
    try std.testing.expectEqual(@as(i128, 2), live.fee_atoms);
    try std.testing.expectEqual(@as(i128, 3), live.realized_pnl_atoms);
    try std.testing.expect(!(try live.apply(batch.events[2])));
    try std.testing.expectEqualSlices(u8, &initial_digest, &live.digest());
    var delayed_report = batch.events[1];
    delayed_report.envelope.source_fact_identity = 99;
    delayed_report.event.execution_report.identity = 99;
    try std.testing.expect(try live.apply(delayed_report));
    try std.testing.expectEqualSlices(u8, &initial_digest, &live.digest());
    var conflicting_fill = batch.events[2];
    var altered_fill = conflicting_fill.event.fill;
    altered_fill.quantity.lots = 11;
    conflicting_fill.event = .{ .fill = altered_fill };
    try std.testing.expectError(error.ConflictingSourceFact, live.apply(conflicting_fill));

    var replay = Projection{};
    try replay.applyBatch(batch);
    try std.testing.expectEqualSlices(u8, &initial_digest, &replay.digest());
    try adapter.stop(.{ .monotonic_ns = 1 });
}
