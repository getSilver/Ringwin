//! Honest qualification state for Binance Testnet.
//! No public function can turn caller-supplied counters, booleans or digests
//! into TestnetQualified evidence. A real opt-in runner may add that transition
//! when its external inputs and network workflow exist.

const std = @import("std");

pub const RunFailure = enum { incomplete_external_input, request_failed, private_facts_missing, reconciliation_failed, isolation_failed, replay_mismatch };

const ContractSeal = opaque {};
const OfficialSeal = opaque {};
const TestnetSeal = opaque {};
var contract_marker: u8 = 0;
var official_marker: u8 = 0;

pub const ContractTested = struct {
    source: *const ContractSeal,
};

pub const OfficialConfirmed = struct {
    contract: ContractTested,
    source: *const OfficialSeal,
};

/// Only the future Binance Testnet runner in this module may create this type.
/// The opaque source pointer prevents ordinary callers from constructing it.
pub const TestnetQualified = struct {
    source: *const TestnetSeal,
    run_id: u64,
    live_digest: [32]u8,
    replay_digest: [32]u8,
};

pub const FailedRun = struct {
    run_id: u64,
    reason: RunFailure,
};

pub const RunStatus = union(enum) {
    not_run,
    failed: FailedRun,
    qualified: TestnetQualified,
};

/// Persists non-qualifying run outcomes and rejects stale/replayed run ids.
pub const RunLedger = struct {
    latest_run_id: u64 = 0,
    current: RunStatus = .not_run,

    pub fn recordFailure(self: *RunLedger, failure: FailedRun) !void {
        if (failure.run_id == 0 or failure.run_id <= self.latest_run_id) return error.StaleTestnetRun;
        self.latest_run_id = failure.run_id;
        self.current = .{ .failed = failure };
    }

    pub fn status(self: *const RunLedger) RunStatus {
        return self.current;
    }
};

pub fn contractTested() ContractTested {
    return .{ .source = @ptrCast(&contract_marker) };
}

/// The documentation identity is fixed by this module; callers do not provide
/// an arbitrary digest and cannot promote it to Testnet qualification.
pub fn officialConfirmed(contract: ContractTested) !OfficialConfirmed {
    if (contract.source != @as(*const ContractSeal, @ptrCast(&contract_marker))) return error.InvalidContractEvidence;
    return .{
        .contract = contract,
        .source = @ptrCast(&official_marker),
    };
}

/// Default/offline execution never accesses the network.
pub fn status() RunStatus {
    return .not_run;
}

test "Binance qualification stays not-run without an authoritative runner" {
    try std.testing.expect(status() == .not_run);
    try std.testing.expect(!@hasDecl(@This(), "recordTestnetRun"));
    try std.testing.expect(!@hasDecl(@This(), "grant"));
    _ = try officialConfirmed(contractTested());
}

test "Binance failure evidence is retained and old run ids are rejected" {
    var ledger: RunLedger = .{};
    try ledger.recordFailure(.{ .run_id = 8, .reason = .isolation_failed });
    try std.testing.expectEqual(RunFailure.isolation_failed, ledger.status().failed.reason);
    try std.testing.expectError(error.StaleTestnetRun, ledger.recordFailure(.{ .run_id = 8, .reason = .request_failed }));
    try std.testing.expectEqual(RunFailure.isolation_failed, ledger.status().failed.reason);
}
