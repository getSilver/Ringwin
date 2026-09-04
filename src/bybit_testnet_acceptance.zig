//! Evidence boundary for a bounded Bybit TestnetRun.
//! It cannot express production or Linux-performance qualification.
const adapter = @import("bybit_venue_adapter.zig");
const std = @import("std");

pub const EvidenceScope = enum { contract_tested, official_confirmed, testnet_run };
pub const Evidence = struct { scope: EvidenceScope, run_id: u64 = 0 };

const ContractSeal = struct { value: u64 };
pub const ContractTested = struct { seal: ContractSeal, digest: [32]u8 };
pub const OfficialConfirmed = struct { contract: ContractTested, source_digest: [32]u8 };
pub const TestnetRun = struct {
    official: OfficialConfirmed,
    run_id: u64,
    before: AccountState,
    after: AccountState,
    requests: u32,
    private_facts: u32,
    reconciliation_facts: u32,
    live_digest: [32]u8,
    replay_digest: [32]u8,
    isolation_proven: bool,
    seal: u64,
};

pub const AccountState = struct {
    open_orders: u16 = 0,
    position_atoms: i128 = 0,
    liability_atoms: i128 = 0,
    has_unknown: bool = false,

    pub fn isClean(self: AccountState) bool {
        return self.open_orders == 0 and self.position_atoms == 0 and self.liability_atoms == 0 and !self.has_unknown;
    }
};

pub fn contractTested() ContractTested {
    return .{ .seal = .{ .value = 0x4259424954 }, .digest = @splat(0x42) };
}

pub fn officialConfirmed(contract: ContractTested, source_digest: [32]u8) !OfficialConfirmed {
    if (contract.seal.value == 0 or std.mem.eql(u8, &source_digest, &@as([32]u8, @splat(0)))) return error.InvalidOfficialEvidence;
    return .{ .contract = contract, .source_digest = source_digest };
}

pub fn status() EvidenceScope {
    return .contract_tested;
}

pub fn recordTestnetRun(
    official: OfficialConfirmed,
    admission: adapter.TestnetAdmission,
    run_id: u64,
    before: AccountState,
    after: AccountState,
    requests: u32,
    private_facts: u32,
    reconciliation_facts: u32,
    live_digest: [32]u8,
    replay_digest: [32]u8,
    isolation_proven: bool,
) !TestnetRun {
    if (!admission.permitsPlace()) return error.TestnetNotAuthorized;
    if (run_id == 0 or requests == 0 or private_facts == 0 or reconciliation_facts == 0)
        return error.IncompleteTestnetRun;
    if (!std.mem.eql(u8, &live_digest, &replay_digest)) return error.ReplayDigestMismatch;
    return .{ .official = official, .run_id = run_id, .before = before, .after = after, .requests = requests, .private_facts = private_facts, .reconciliation_facts = reconciliation_facts, .live_digest = live_digest, .replay_digest = replay_digest, .isolation_proven = isolation_proven, .seal = official.contract.seal.value ^ run_id };
}

pub fn grant(run: TestnetRun) !Evidence {
    if (run.seal != run.official.contract.seal.value ^ run.run_id) return error.InvalidTestnetEvidence;
    if (!run.before.isClean()) return error.DirtyStartingAccount;
    if (!run.after.isClean()) return error.DirtyEndingAccount;
    if (!run.isolation_proven) return error.FailureIsolationMissing;
    return .{ .scope = .testnet_run, .run_id = run.run_id };
}

test "Bybit TestnetRun evidence is fail-closed and scope-limited" {
    const admitted = adapter.TestnetAdmission{
        .explicit_enable = true,
        .endpoint_is_testnet = true,
        .credential_can_read = true,
        .credential_can_trade = true,
        .credential_can_withdraw = false,
    };
    const official = try officialConfirmed(contractTested(), @splat(7));
    const evidence = try grant(try recordTestnetRun(official, admitted, 1, .{}, .{}, 1, 1, 1, @splat(3), @splat(3), true));
    try std.testing.expectEqual(EvidenceScope.testnet_run, evidence.scope);
    try std.testing.expectError(error.TestnetNotAuthorized, recordTestnetRun(official, .{}, 1, .{}, .{}, 1, 1, 1, @splat(3), @splat(3), true));
    try std.testing.expectError(error.DirtyStartingAccount, grant(try recordTestnetRun(official, admitted, 2, .{ .open_orders = 1 }, .{}, 1, 1, 1, @splat(3), @splat(3), true)));
    try std.testing.expectError(error.DirtyEndingAccount, grant(try recordTestnetRun(official, admitted, 3, .{}, .{ .position_atoms = 1 }, 1, 1, 1, @splat(3), @splat(3), true)));
    try std.testing.expectError(error.DirtyEndingAccount, grant(try recordTestnetRun(official, admitted, 4, .{}, .{ .has_unknown = true }, 1, 1, 1, @splat(3), @splat(3), true)));
}
