//! Honest qualification state for Bybit Testnet.
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

pub fn officialConfirmed(contract: ContractTested) !OfficialConfirmed {
    if (contract.source != @as(*const ContractSeal, @ptrCast(&contract_marker))) return error.InvalidContractEvidence;
    return .{
        .contract = contract,
        .source = @ptrCast(&official_marker),
    };
}

pub fn status() RunStatus {
    return .not_run;
}

test "Bybit qualification stays not-run without an authoritative runner" {
    try std.testing.expect(status() == .not_run);
    try std.testing.expect(!@hasDecl(@This(), "recordTestnetRun"));
    try std.testing.expect(!@hasDecl(@This(), "grant"));
    _ = try officialConfirmed(contractTested());
}

test "Bybit failure evidence is retained and old run ids are rejected" {
    var ledger: RunLedger = .{};
    try ledger.recordFailure(.{ .run_id = 13, .reason = .reconciliation_failed });
    try std.testing.expectEqual(RunFailure.reconciliation_failed, ledger.status().failed.reason);
    try std.testing.expectError(error.StaleTestnetRun, ledger.recordFailure(.{ .run_id = 12, .reason = .request_failed }));
    try std.testing.expectEqual(RunFailure.reconciliation_failed, ledger.status().failed.reason);
}
