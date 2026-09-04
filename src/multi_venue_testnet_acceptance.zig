//! Cross-Venue qualification evidence with an explicit environment.
//! OKX Demo and Venue Testnet runs share the evidence shape, but one can never
//! be promoted to the other or to production qualification.
const std = @import("std");
const binance = @import("binance_testnet_acceptance.zig");
const bybit = @import("bybit_testnet_acceptance.zig");

pub const Environment = enum { demo, testnet };
pub const Qualification = enum { contract_tested, official_confirmed, demo_qualified, testnet_qualified };
pub const Venue = enum { okx, binance, bybit };

pub const AccountState = struct {
    open_orders: u16 = 0,
    position_atoms: i128 = 0,
    liability_atoms: i128 = 0,
    has_unknown: bool = false,

    fn isClean(self: AccountState) bool {
        return self.open_orders == 0 and self.position_atoms == 0 and self.liability_atoms == 0 and !self.has_unknown;
    }
};

pub const VenueEvidence = struct {
    venue: Venue,
    environment: Environment,
    qualification: Qualification,
    run_id: u64,
    live_digest: [32]u8,
    replay_digest: [32]u8,
};

/// Facts emitted by the explicit OKX Demo runner after the account is cleaned
/// and the canonical projection has replayed to the same digest.
pub const OkxDemoRun = struct {
    run_id: u64,
    before: AccountState,
    after: AccountState,
    requests: u32,
    private_facts: u32,
    reconciliation_facts: u32,
    live_digest: [32]u8,
    replay_digest: [32]u8,
    isolation_proven: bool,
    endpoint_is_demo: bool,
    simulated_header: bool,
    cleanup_closed: bool,
};

pub const Evidence = struct {
    okx: VenueEvidence,
    binance: VenueEvidence,
    bybit: VenueEvidence,
};

pub fn recordOkxDemoRun(run: OkxDemoRun) !VenueEvidence {
    if (!run.endpoint_is_demo or !run.simulated_header) return error.InvalidDemoEnvironment;
    if (run.run_id == 0 or run.requests == 0 or run.private_facts == 0 or run.reconciliation_facts == 0)
        return error.IncompleteDemoRun;
    if (!std.mem.eql(u8, &run.live_digest, &run.replay_digest)) return error.ReplayDigestMismatch;
    if (!run.before.isClean()) return error.DirtyStartingAccount;
    if (!run.after.isClean() or !run.cleanup_closed) return error.DirtyEndingAccount;
    if (!run.isolation_proven) return error.FailureIsolationMissing;
    return .{
        .venue = .okx,
        .environment = .demo,
        .qualification = .demo_qualified,
        .run_id = run.run_id,
        .live_digest = run.live_digest,
        .replay_digest = run.replay_digest,
    };
}

/// Aggregates independently qualified venue evidence without flattening Demo
/// into Testnet. The returned fields are the only cross-Venue mapping.
pub fn grant(okx_demo: OkxDemoRun, binance_run: binance.TestnetRun, bybit_run: bybit.TestnetRun) !Evidence {
    const okx = try recordOkxDemoRun(okx_demo);
    _ = try binance.grant(binance_run);
    _ = try bybit.grant(bybit_run);
    return .{
        .okx = okx,
        .binance = .{
            .venue = .binance,
            .environment = .testnet,
            .qualification = .testnet_qualified,
            .run_id = binance_run.run_id,
            .live_digest = binance_run.live_digest,
            .replay_digest = binance_run.replay_digest,
        },
        .bybit = .{
            .venue = .bybit,
            .environment = .testnet,
            .qualification = .testnet_qualified,
            .run_id = bybit_run.run_id,
            .live_digest = bybit_run.live_digest,
            .replay_digest = bybit_run.replay_digest,
        },
    };
}

fn completeOkxDemoRun() OkxDemoRun {
    return .{
        .run_id = 1,
        .before = .{},
        .after = .{},
        .requests = 2,
        .private_facts = 3,
        .reconciliation_facts = 2,
        .live_digest = @splat(1),
        .replay_digest = @splat(1),
        .isolation_proven = true,
        .endpoint_is_demo = true,
        .simulated_header = true,
        .cleanup_closed = true,
    };
}

fn completeBinanceTestnetRun(run_id: u64) !binance.TestnetRun {
    const official = try binance.officialConfirmed(binance.contractTested(), @splat(7));
    return binance.recordTestnetRun(official, .{
        .explicit_enable = true,
        .endpoint_is_testnet = true,
        .credential_can_read = true,
        .credential_can_trade = true,
        .credential_can_withdraw = false,
    }, run_id, .{}, .{}, 1, 1, 1, @splat(3), @splat(3), true);
}

fn completeBybitTestnetRun(run_id: u64) !bybit.TestnetRun {
    const official = try bybit.officialConfirmed(bybit.contractTested(), @splat(7));
    return bybit.recordTestnetRun(official, .{
        .explicit_enable = true,
        .endpoint_is_testnet = true,
        .credential_can_read = true,
        .credential_can_trade = true,
        .credential_can_withdraw = false,
    }, run_id, .{}, .{}, 1, 1, 1, @splat(3), @splat(3), true);
}

test "common qualification keeps OKX Demo separate from Venue Testnet" {
    const evidence = try grant(completeOkxDemoRun(), try completeBinanceTestnetRun(2), try completeBybitTestnetRun(3));
    try std.testing.expectEqual(Venue.okx, evidence.okx.venue);
    try std.testing.expectEqual(Environment.demo, evidence.okx.environment);
    try std.testing.expectEqual(Qualification.demo_qualified, evidence.okx.qualification);
    try std.testing.expectEqual(Environment.testnet, evidence.binance.environment);
    try std.testing.expectEqual(Qualification.testnet_qualified, evidence.binance.qualification);
    try std.testing.expectEqual(Qualification.testnet_qualified, evidence.bybit.qualification);
}

test "OKX Demo evidence fails closed and cannot be relabeled as Testnet" {
    var run = completeOkxDemoRun();
    run.endpoint_is_demo = false;
    try std.testing.expectError(error.InvalidDemoEnvironment, recordOkxDemoRun(run));
    run = completeOkxDemoRun();
    run.after.position_atoms = 1;
    try std.testing.expectError(error.DirtyEndingAccount, recordOkxDemoRun(run));
}
