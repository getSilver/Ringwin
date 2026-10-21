//! Cross-Venue qualification status without synthetic promotion.
//! The offline build reports what has actually run; it cannot manufacture Demo
//! or Testnet qualification from caller-supplied records.

const std = @import("std");
const binance = @import("binance_testnet_acceptance.zig");
const bybit = @import("bybit_testnet_acceptance.zig");

pub const Environment = enum { demo, testnet };
pub const Qualification = enum { contract_tested, official_confirmed, demo_qualified, testnet_qualified };
pub const RunState = enum { not_run, failed, qualified };
pub const Venue = enum { okx, binance, bybit };

pub const VenueEvidence = struct {
    venue: Venue,
    environment: Environment,
    qualification: Qualification,
    run_state: RunState,
    run_id: ?u64 = null,
};

pub const Evidence = struct {
    okx: VenueEvidence,
    binance: VenueEvidence,
    bybit: VenueEvidence,
};

/// Current checked-in evidence. Real opt-in runner results must replace the
/// corresponding entry at their authoritative runner boundary; this offline
/// aggregate deliberately has no API that accepts fabricated run facts.
pub fn current() Evidence {
    return .{
        .okx = .{ .venue = .okx, .environment = .demo, .qualification = .official_confirmed, .run_state = .not_run },
        .binance = .{ .venue = .binance, .environment = .testnet, .qualification = .official_confirmed, .run_state = runState(binance.status()) },
        .bybit = .{ .venue = .bybit, .environment = .testnet, .qualification = .official_confirmed, .run_state = runState(bybit.status()) },
    };
}

fn runState(status_value: anytype) RunState {
    return switch (status_value) {
        .not_run => .not_run,
        .failed => .failed,
        .qualified => .qualified,
    };
}

test "offline qualification explicitly reports all live environments not run" {
    const evidence = current();
    try std.testing.expectEqual(RunState.not_run, evidence.okx.run_state);
    try std.testing.expectEqual(RunState.not_run, evidence.binance.run_state);
    try std.testing.expectEqual(RunState.not_run, evidence.bybit.run_state);
    try std.testing.expect(evidence.okx.qualification != .demo_qualified);
    try std.testing.expect(evidence.binance.qualification != .testnet_qualified);
    try std.testing.expect(evidence.bybit.qualification != .testnet_qualified);
}

test "Venue qualification types cannot be reused across adapters" {
    try std.testing.expect(binance.TestnetQualified != bybit.TestnetQualified);
    try std.testing.expect(!@hasDecl(@This(), "grant"));
    try std.testing.expect(!@hasDecl(@This(), "recordOkxDemoRun"));
}
