//! Evidence boundary for the bounded Binance TestnetRun acceptance.
//! It cannot express production or Linux-performance qualification.

const binance = @import("binance_venue_adapter.zig");
const std = @import("std");

pub const EvidenceScope = enum { testnet_run };
pub const Evidence = struct { scope: EvidenceScope = .testnet_run };

pub const AccountState = struct {
    open_orders: u16 = 0,
    position_atoms: i128 = 0,
    liability_atoms: i128 = 0,
    has_unknown: bool = false,

    pub fn isClean(self: AccountState) bool {
        return self.open_orders == 0 and self.position_atoms == 0 and self.liability_atoms == 0 and !self.has_unknown;
    }
};

/// Call only after the read-only bootstrap before and after the bounded run.
pub fn grant(admission: binance.TestnetAdmission, before: AccountState, after: AccountState) !Evidence {
    if (!admission.permitsPlace()) return error.TestnetNotAuthorized;
    if (!before.isClean()) return error.DirtyStartingAccount;
    if (!after.isClean()) return error.DirtyEndingAccount;
    return .{};
}

test "Binance TestnetRun evidence is fail-closed and scope-limited" {
    const admitted = binance.TestnetAdmission{
        .explicit_enable = true,
        .endpoint_is_testnet = true,
        .credential_can_read = true,
        .credential_can_trade = true,
        .credential_can_withdraw = false,
    };
    const evidence = try grant(admitted, .{}, .{});
    try std.testing.expectEqual(EvidenceScope.testnet_run, evidence.scope);
    try std.testing.expectError(error.TestnetNotAuthorized, grant(.{}, .{}, .{}));
    try std.testing.expectError(error.DirtyStartingAccount, grant(admitted, .{ .open_orders = 1 }, .{}));
    try std.testing.expectError(error.DirtyEndingAccount, grant(admitted, .{}, .{ .liability_atoms = 1 }));
    try std.testing.expectError(error.DirtyEndingAccount, grant(admitted, .{}, .{ .has_unknown = true }));
}
