//! Shared account proof derived from the four file-restored TradingShards.
const std = @import("std");
const durable = @import("durable_store.zig");
const coordination = @import("account_coordinator.zig");
const stream: durable.StreamIdentity = .{ .domain = .control, .id = 1 };
fn require(ok: bool) !void {
    if (!ok) return error.WindowsSharedAccountInvariant;
}
pub const Ownership = struct { shard: usize, portfolio: u128, account: u128, decision_domain: u128, reservation_atoms: i128, lease_used_atoms: i128, lease_limit_atoms: i128, lease_version: u64, open_orders: u16, unknown_orders: u16 };
pub const Report = struct { exchange_account: u128, gross_reservation_atoms: i128, account_ceiling_atoms: i128, denied_ceiling_atoms: i128, ceiling_rejected: bool, coordinator_barrier: u64, ownership_digest: [64]u8, owners: [4]Ownership };
pub fn verify(allocator: std.mem.Allocator, io: std.Io, parent: []const u8, virgin: bool, publish_updates: bool, summaries: [4]coordination.ShardSummary) !Report {
    var gross: i128 = 0;
    for (summaries, 0..) |summary, index| {
        try require(summary.virtual_portfolio == index + 11 and summary.exchange_account == 2 and summary.decision_domain == index + 1);
        gross += summary.reservation_atoms;
    }
    try require(gross > 0);
    // This deliberately failing allocation consumes the actual four file-owned
    // public summaries. It has no Store and cannot grant authority or write.
    var denied = coordination.AccountCoordinator.init(2, gross - 1, gross * 10);
    for (summaries, 0..) |summary, index| _ = try denied.publishSummary(index + 1, summary);
    if (denied.allocateLeases(1, 1000000)) |_| return error.AccountCeilingUnexpectedlyAccepted else |err| if (err != error.AccountSafetyCeilingExceeded) return err;
    try require(denied.lease_count == 0);
    var path_buffer: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}{s}coordination", .{ parent, std.fs.path.sep_str });
    if (!virgin) {
        var existing = try std.Io.Dir.openDirAbsolute(io, path, .{});
        existing.close(io);
    }
    const file = try allocator.create(durable.LinuxFileAdapter);
    defer allocator.destroy(file);
    @memset(std.mem.asBytes(file), 0);
    if (@import("builtin").os.tag == .linux) try file.initLinux(io, path) else try file.initWindowsVerification(io, path);
    defer file.close(io);
    var owner: coordination.CoordinatorOwner = undefined;
    if (virgin) {
        var directory = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
        defer directory.close(io);
        var entries = directory.iterate();
        if (try entries.next(io) != null) return error.SeedDirectoryNotEmpty;
        owner = try coordination.CoordinatorOwner.init(.init(2, gross * 4, gross * 10), stream, file.interface(), io);
        for (summaries, 0..) |summary, index| try owner.apply(.{ .publish_summary = .{ .identity = index + 1, .summary = summary } });
        try owner.apply(.{ .allocate_leases = .{ .version = 1, .valid_through_barrier = 1000000 } });
        try owner.checkpoint();
    } else {
        owner = try coordination.CoordinatorOwner.recover(stream, file.interface(), io);
        try require(owner.coordinator.recovery_only);
        // Recovering the published leases never grants send authority.
        if (owner.coordinator.allocateLeases(2, 1000000)) |_| return error.RecoveryUnexpectedlyAuthorized else |err| if (err != error.CoordinatorRecoveryOnly) return err;
        if (publish_updates) {
            // New public observations may advance risk facts even when the
            // gross reservation stays unchanged. Publish them durably while
            // preserving recovery-only admission and the existing lease set.
            const before_publication = owner.sequence;
            for (summaries, 0..) |summary, index| {
                var updated = summary;
                updated.shard_sequence = owner.coordinator.summaries[index].value.shard_sequence;
                if (!std.meta.eql(updated, owner.coordinator.summaries[index].value)) {
                    updated.shard_sequence += 1;
                    try owner.apply(.{ .publish_summary = .{ .identity = owner.sequence + 1, .summary = updated } });
                }
            }
            // An unchanged observation has no new committed tail to archive.
            // Keep its existing checkpoint instead of rotating an empty tail.
            if (owner.sequence != before_publication) try owner.checkpoint();
            try require(owner.coordinator.recovery_only);
        }
    }
    try require(try owner.coordinator.grossPortfolioMargin() == gross);
    var result: Report = .{ .exchange_account = 2, .gross_reservation_atoms = gross, .account_ceiling_atoms = owner.coordinator.account_safety_ceiling_atoms, .denied_ceiling_atoms = gross - 1, .ceiling_rejected = true, .coordinator_barrier = owner.sequence, .ownership_digest = std.fmt.bytesToHex(owner.coordinator.digest(), .lower), .owners = undefined };
    for (summaries, 0..) |summary, index| {
        const restored_summary = owner.coordinator.summaries[index];
        var expected = summary;
        expected.shard_sequence = restored_summary.value.shard_sequence;
        try require(restored_summary.present and std.meta.eql(restored_summary.value, expected));
        const lease = owner.coordinator.leases[index];
        try require(@intFromEnum(lease.shard_id) == index and lease.exchange_account == summary.exchange_account and lease.decision_domain == summary.decision_domain and lease.used_atoms == summary.reservation_atoms);
        result.owners[index] = .{ .shard = index, .portfolio = summary.virtual_portfolio, .account = summary.exchange_account, .decision_domain = summary.decision_domain, .reservation_atoms = summary.reservation_atoms, .lease_used_atoms = lease.used_atoms, .lease_limit_atoms = lease.limit_atoms, .lease_version = lease.version, .open_orders = summary.open_orders, .unknown_orders = summary.unknown_orders };
    }
    return result;
}

test "Native file shared unchanged public summaries recover without empty archive" {
    if (@import("builtin").os.tag != .windows and @import("builtin").os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    var completed = false;
    defer if (completed) temp.cleanup();
    var path_buffer: [1024]u8 = undefined;
    const path = path_buffer[0..try temp.dir.realPath(std.testing.io, &path_buffer)];
    std.debug.print("windows_shared_unchanged_fixture={s}\n", .{path});
    var summaries: [4]coordination.ShardSummary = undefined;
    for (&summaries, 0..) |*summary, index| summary.* = .{
        .shard_id = @enumFromInt(index),
        .decision_domain = index + 1,
        .virtual_portfolio = index + 11,
        .exchange_account = 2,
        .shard_sequence = 1,
        .rules_version = 1,
        .lease_version = 1,
        .reservation_atoms = 100,
        .spot_quantity = 0,
        .swap_quantity = 0,
        .cash_atoms = 1_000,
        .open_orders = 0,
        .unknown_orders = 0,
        .local_gate_closed = false,
    };
    _ = try verify(std.testing.allocator, io, path, true, false, summaries);
    summaries[0].cash_atoms += 1;
    const first_update = try verify(std.testing.allocator, io, path, false, true, summaries);
    const unchanged = try verify(std.testing.allocator, io, path, false, true, summaries);
    try std.testing.expectEqualDeep(first_update, unchanged);
    const recovered = try verify(std.testing.allocator, io, path, false, false, summaries);
    try std.testing.expectEqualDeep(unchanged, recovered);
    summaries[0].cash_atoms += 1;
    const changed = try verify(std.testing.allocator, io, path, false, true, summaries);
    try std.testing.expect(changed.coordinator_barrier > unchanged.coordinator_barrier);
    const changed_recovered = try verify(std.testing.allocator, io, path, false, false, summaries);
    try std.testing.expectEqualDeep(changed, changed_recovered);
    try std.Io.Dir.cwd().deleteTree(io, path);
    completed = true;
}
