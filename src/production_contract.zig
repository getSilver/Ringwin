//! The single checked-in contract for the first Linux production baseline.
//!
//! Development and qualification evidence are inputs to this contract, not
//! implicit upgrades of its environment or authority.

const std = @import("std");
const canonical = @import("canonical_event.zig");

pub const contract_version: u16 = 1;
pub const acceptance_schema_version: u16 = 13;
pub const journal_schema_version: u16 = 38;
pub const state_schema_version: u32 = 42;
pub const schema_registry_identity: u64 = 36;
pub const previous_journal_schema_version: u16 = journal_schema_version - 1;
pub const previous_state_schema_version: u32 = state_schema_version - 1;
pub const production_optimize = std.builtin.OptimizeMode.ReleaseSafe;
pub const ProductionPlatform = enum { linux };
pub const production_platform = ProductionPlatform.linux;

pub const Environment = enum { demo, testnet, production };
pub const Venue = enum { okx, binance, bybit, gate_io, bitget };
pub const Instrument = enum { btc_usdt_spot, btc_usdt_isolated_linear_perpetual, none };
pub const ExchangeAccountScope = enum { explicit_qualified_account, none };
pub const MatrixStatus = enum { production_candidate, non_production_reference, disabled };
pub const Qualification = enum { not_run, failed, invalid, demo_qualified, testnet_qualified, production_qualified };

pub const OrderCapability = enum {
    limit_place,
    cancel,
    native_amend,
    native_post_only,
    venue_reduce_only,
    bounded_batch,
};

pub const SupportMatrixEntry = struct {
    venue: Venue,
    environment: Environment,
    exchange_account: ExchangeAccountScope,
    product: canonical.Product,
    instrument: Instrument,
    /// Target capabilities the adapter must be able to encode. Presence here is
    /// not live evidence.
    capabilities: []const OrderCapability,
    /// Capabilities proven by a real transport/Testnet/Demo run. Empty means
    /// `not_run`.
    verified_capabilities: []const OrderCapability = &.{},
    qualification: Qualification = .not_run,
    status: MatrixStatus,
};

pub const VerificationRuntime = enum { windows };
pub const windows_verification_runtime = VerificationRuntime.windows;
pub const VerificationRole = enum { engine, market_feed, execution_gateway, telemetry, control_fence };
pub const VerificationResult = enum { not_run, blocked, failed, passed };

pub const WindowsChainEvidence = struct {
    revision: []const u8 = "",
    environment: Environment = .demo,
    venue: Venue = .okx,
    account_scope: []const u8 = "",
    product: ?canonical.Product = null,
    strategy: []const u8 = "",
    configuration: []const u8 = "",
    offline: VerificationResult = .not_run,
    read_only: VerificationResult = .not_run,
    demo_live: VerificationResult = .not_run,
    role_ownership: VerificationResult = .not_run,
    durable_recovery: VerificationResult = .not_run,
    final_reconciliation: VerificationResult = .not_run,
    production_qualification: bool = false,
    adapter: enum { windows_file } = .windows_file,
    protection: enum { windows_virtual_lock } = .windows_virtual_lock,
    power_loss_qualified: bool = false,
    linux_admission_equivalent: bool = false,
};

const spot_capabilities = [_]OrderCapability{ .limit_place, .cancel, .native_amend, .bounded_batch };
const linear_capabilities = [_]OrderCapability{
    .limit_place,
    .cancel,
    .native_amend,
    .native_post_only,
    .venue_reduce_only,
    .bounded_batch,
};
const no_capabilities = [_]OrderCapability{};

/// The only production product/instrument rows that may become qualified.
/// The exchange account is intentionally a scope, not a fabricated account ID.
pub const support_matrix = [_]SupportMatrixEntry{
    .{ .venue = .okx, .environment = .production, .exchange_account = .explicit_qualified_account, .product = .spot, .instrument = .btc_usdt_spot, .capabilities = &spot_capabilities, .status = .production_candidate },
    .{ .venue = .okx, .environment = .production, .exchange_account = .explicit_qualified_account, .product = .isolated_linear_usdt, .instrument = .btc_usdt_isolated_linear_perpetual, .capabilities = &linear_capabilities, .status = .production_candidate },
    .{ .venue = .binance, .environment = .production, .exchange_account = .explicit_qualified_account, .product = .spot, .instrument = .btc_usdt_spot, .capabilities = &spot_capabilities, .status = .production_candidate },
    .{ .venue = .binance, .environment = .production, .exchange_account = .explicit_qualified_account, .product = .isolated_linear_usdt, .instrument = .btc_usdt_isolated_linear_perpetual, .capabilities = &linear_capabilities, .status = .production_candidate },
    .{ .venue = .bybit, .environment = .production, .exchange_account = .explicit_qualified_account, .product = .spot, .instrument = .btc_usdt_spot, .capabilities = &spot_capabilities, .status = .production_candidate },
    .{ .venue = .bybit, .environment = .production, .exchange_account = .explicit_qualified_account, .product = .isolated_linear_usdt, .instrument = .btc_usdt_isolated_linear_perpetual, .capabilities = &linear_capabilities, .status = .production_candidate },

    .{ .venue = .okx, .environment = .demo, .exchange_account = .explicit_qualified_account, .product = .spot, .instrument = .btc_usdt_spot, .capabilities = &spot_capabilities, .status = .non_production_reference },
    .{ .venue = .okx, .environment = .demo, .exchange_account = .explicit_qualified_account, .product = .isolated_linear_usdt, .instrument = .btc_usdt_isolated_linear_perpetual, .capabilities = &linear_capabilities, .status = .non_production_reference },
    .{ .venue = .binance, .environment = .testnet, .exchange_account = .explicit_qualified_account, .product = .spot, .instrument = .btc_usdt_spot, .capabilities = &spot_capabilities, .status = .non_production_reference },
    .{ .venue = .binance, .environment = .testnet, .exchange_account = .explicit_qualified_account, .product = .isolated_linear_usdt, .instrument = .btc_usdt_isolated_linear_perpetual, .capabilities = &linear_capabilities, .status = .non_production_reference },
    .{ .venue = .bybit, .environment = .testnet, .exchange_account = .explicit_qualified_account, .product = .spot, .instrument = .btc_usdt_spot, .capabilities = &spot_capabilities, .status = .non_production_reference },
    .{ .venue = .bybit, .environment = .testnet, .exchange_account = .explicit_qualified_account, .product = .isolated_linear_usdt, .instrument = .btc_usdt_isolated_linear_perpetual, .capabilities = &linear_capabilities, .status = .non_production_reference },

    .{ .venue = .gate_io, .environment = .production, .exchange_account = .none, .product = .spot, .instrument = .none, .capabilities = &no_capabilities, .status = .disabled },
    .{ .venue = .bitget, .environment = .production, .exchange_account = .none, .product = .spot, .instrument = .none, .capabilities = &no_capabilities, .status = .disabled },
};

pub const ProductionAdmission = struct {
    venue: Venue,
    product: canonical.Product,
    instrument: Instrument,
    environment: Environment,
    endpoint_environment: Environment,
    credential_environment: Environment,
    exchange_account: ?canonical.ExchangeAccountIdentity = null,
    qualification: Qualification = .not_run,
    owner_enabled: bool = false,
    credential_can_read: bool = false,
    credential_can_trade: bool = false,
    credential_can_withdraw: bool = true,
};

fn productionEntry(venue: Venue, product: canonical.Product, instrument: Instrument) ?*const SupportMatrixEntry {
    for (&support_matrix) |*entry| {
        if (entry.venue == venue and entry.environment == .production and entry.product == product and
            entry.instrument == instrument and
            entry.status == .production_candidate)
            return entry;
    }
    return null;
}

/// Production authority requires an independently qualified production
/// account and matching production endpoint/credential. Demo and Testnet
/// evidence can never satisfy this predicate.
pub fn permitsProduction(admission: ProductionAdmission) bool {
    _ = productionEntry(admission.venue, admission.product, admission.instrument) orelse return false;
    return admission.environment == .production and
        admission.endpoint_environment == .production and
        admission.credential_environment == .production and
        admission.exchange_account != null and
        admission.qualification == .production_qualified and
        admission.owner_enabled and
        admission.credential_can_read and
        admission.credential_can_trade and
        !admission.credential_can_withdraw;
}

pub fn supportsCapability(entry: SupportMatrixEntry, capability: OrderCapability) bool {
    for (entry.capabilities) |available| if (available == capability) return true;
    return false;
}

pub fn verifiedCapability(entry: SupportMatrixEntry, capability: OrderCapability) bool {
    for (entry.verified_capabilities) |available| if (available == capability) return true;
    return false;
}

/// Windows verification evidence never satisfies production authority, even
/// when the Windows process chain itself passed.
pub fn windowsChainPermitsProduction(evidence: WindowsChainEvidence) bool {
    _ = evidence;
    return false;
}

pub fn isWindowsProcessChainVerified(evidence: WindowsChainEvidence) bool {
    return !evidence.production_qualification and
        evidence.environment == .demo and evidence.venue == .okx and
        evidence.revision.len != 0 and evidence.account_scope.len != 0 and
        evidence.product != null and evidence.strategy.len != 0 and evidence.configuration.len != 0 and
        evidence.offline == .passed and evidence.read_only == .passed and evidence.demo_live == .passed and
        evidence.role_ownership == .passed and evidence.durable_recovery == .passed and
        evidence.final_reconciliation == .passed and
        !evidence.power_loss_qualified and
        !evidence.linux_admission_equivalent;
}

test "production contract freezes Linux scope and schema" {
    try std.testing.expectEqual(@as(u16, 38), journal_schema_version);
    try std.testing.expectEqual(@as(u32, 42), state_schema_version);
    try std.testing.expectEqual(@as(u16, 37), previous_journal_schema_version);
    try std.testing.expectEqual(@as(u32, 41), previous_state_schema_version);
    try std.testing.expectEqual(@as(usize, 14), support_matrix.len);
    try std.testing.expectEqual(std.builtin.OptimizeMode.ReleaseSafe, production_optimize);
    try std.testing.expectEqual(ProductionPlatform.linux, production_platform);
}

test "demo and testnet evidence never promotes production authority" {
    const base: ProductionAdmission = .{
        .venue = .okx,
        .product = .spot,
        .instrument = .btc_usdt_spot,
        .environment = .production,
        .endpoint_environment = .production,
        .credential_environment = .production,
        .exchange_account = 42,
        .qualification = .production_qualified,
        .owner_enabled = true,
        .credential_can_read = true,
        .credential_can_trade = true,
        .credential_can_withdraw = false,
    };
    try std.testing.expect(permitsProduction(base));

    var demo = base;
    demo.environment = .demo;
    demo.endpoint_environment = .demo;
    demo.credential_environment = .demo;
    demo.qualification = .demo_qualified;
    try std.testing.expect(!permitsProduction(demo));

    var testnet = base;
    testnet.environment = .testnet;
    testnet.endpoint_environment = .testnet;
    testnet.credential_environment = .testnet;
    testnet.qualification = .testnet_qualified;
    try std.testing.expect(!permitsProduction(testnet));

    var not_run = base;
    not_run.qualification = .not_run;
    try std.testing.expect(!permitsProduction(not_run));
}

test "Gate.io and Bitget are explicit disabled rows" {
    for (support_matrix) |entry| {
        if (entry.venue == .gate_io or entry.venue == .bitget) {
            try std.testing.expectEqual(MatrixStatus.disabled, entry.status);
            try std.testing.expectEqual(@as(usize, 0), entry.capabilities.len);
        }
    }
    try std.testing.expect(!permitsProduction(.{
        .venue = .gate_io,
        .product = .spot,
        .instrument = .none,
        .environment = .production,
        .endpoint_environment = .production,
        .credential_environment = .production,
    }));
}

test "Windows verification success cannot permit production" {
    const evidence: WindowsChainEvidence = .{
        .revision = "test-revision",
        .account_scope = "test-account",
        .product = .spot,
        .strategy = "test-strategy",
        .configuration = "test-config",
        .offline = .passed,
        .read_only = .passed,
        .demo_live = .passed,
        .role_ownership = .passed,
        .durable_recovery = .passed,
        .final_reconciliation = .passed,
    };
    try std.testing.expect(isWindowsProcessChainVerified(evidence));
    try std.testing.expect(!windowsChainPermitsProduction(evidence));
    var incomplete = evidence;
    incomplete.demo_live = .not_run;
    try std.testing.expect(!isWindowsProcessChainVerified(incomplete));
    incomplete = evidence;
    incomplete.role_ownership = .failed;
    try std.testing.expect(!isWindowsProcessChainVerified(incomplete));
    try std.testing.expectEqual(VerificationRuntime.windows, windows_verification_runtime);
    try std.testing.expectEqual(ProductionPlatform.linux, production_platform);
}

test "required capabilities are not verified evidence" {
    for (support_matrix) |entry| {
        try std.testing.expectEqual(@as(usize, 0), entry.verified_capabilities.len);
        try std.testing.expectEqual(Qualification.not_run, entry.qualification);
        try std.testing.expect(!verifiedCapability(entry, .native_amend));
        try std.testing.expect(!verifiedCapability(entry, .native_post_only));
        try std.testing.expect(!verifiedCapability(entry, .bounded_batch));
    }
    try std.testing.expect(supportsCapability(support_matrix[2], .native_amend));
    try std.testing.expectEqual(Venue.binance, support_matrix[2].venue);
    try std.testing.expectEqual(Venue.bybit, support_matrix[4].venue);
}
