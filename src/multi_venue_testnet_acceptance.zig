//! Cross-Venue acceptance evidence. Inputs are produced by each Venue's
//! bounded Demo/Testnet run; this module never grants production authority.
const std = @import("std");
const binance = @import("binance_testnet_acceptance.zig");
const bybit = @import("bybit_testnet_acceptance.zig");

pub const EvidenceScope = enum { testnet_run };
pub const Venue = enum { okx, binance, bybit };
pub const ContractMatrix = struct {
    venue_adapter: bool,
    market_feed_adapter: bool,
    field_disposition: bool,
    capability_profile: bool,

    fn isComplete(self: ContractMatrix) bool {
        return self.venue_adapter and self.market_feed_adapter and self.field_disposition and self.capability_profile;
    }
};
pub const AccountState = struct {
    open_orders: u16 = 0,
    position_atoms: i128 = 0,
    liability_atoms: i128 = 0,
    has_unknown: bool = false,

    fn isClean(self: AccountState) bool {
        return self.open_orders == 0 and self.position_atoms == 0 and self.liability_atoms == 0 and !self.has_unknown;
    }
};
pub const VenueRun = struct {
    venue: Venue,
    matrix: ContractMatrix,
    before: AccountState,
    after: AccountState,
    failed_venue_isolated: bool,
    live_digest: [32]u8,
    replay_digest: [32]u8,
};
pub const Evidence = struct { scope: EvidenceScope = .testnet_run };

pub fn grant(okx: VenueRun, binance_run: VenueRun, bybit_run: VenueRun) !Evidence {
    const runs = [_]VenueRun{ okx, binance_run, bybit_run };
    if (runs[0].venue != .okx or runs[1].venue != .binance or runs[2].venue != .bybit) return error.InvalidVenueMatrix;
    for (runs) |run| {
        if (!run.matrix.isComplete()) return error.IncompleteContractMatrix;
        if (!run.before.isClean()) return error.DirtyStartingAccount;
        if (!run.after.isClean()) return error.DirtyEndingAccount;
        if (!run.failed_venue_isolated) return error.FailureIsolationMissing;
        if (!std.mem.eql(u8, &run.live_digest, &run.replay_digest)) return error.ReplayDigestMismatch;
    }
    return .{};
}

fn completeRun(venue: Venue) VenueRun {
    return .{ .venue = venue, .matrix = .{ .venue_adapter = true, .market_feed_adapter = true, .field_disposition = true, .capability_profile = true }, .before = .{}, .after = .{}, .failed_venue_isolated = true, .live_digest = @splat(@intFromEnum(venue)), .replay_digest = @splat(@intFromEnum(venue)) };
}

test "three Venue acceptance requires the common matrix, cleanup, isolation, and replay equality" {
    _ = try binance.grant(.{ .explicit_enable = true, .endpoint_is_testnet = true, .credential_can_read = true, .credential_can_trade = true, .credential_can_withdraw = false }, .{}, .{});
    _ = try bybit.grant(.{ .explicit_enable = true, .endpoint_is_testnet = true, .credential_can_read = true, .credential_can_trade = true, .credential_can_withdraw = false }, .{}, .{});
    const evidence = try grant(completeRun(.okx), completeRun(.binance), completeRun(.bybit));
    try std.testing.expectEqual(EvidenceScope.testnet_run, evidence.scope);
    var broken = completeRun(.bybit);
    broken.after.has_unknown = true;
    try std.testing.expectError(error.DirtyEndingAccount, grant(completeRun(.okx), completeRun(.binance), broken));
    broken = completeRun(.bybit);
    broken.replay_digest[0] = 9;
    try std.testing.expectError(error.ReplayDigestMismatch, grant(completeRun(.okx), completeRun(.binance), broken));
}
