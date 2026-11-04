const canonical = @import("../model/canonical_event.zig");
const std = @import("std");

/// Both REST adapters accept this 32-character alphanumeric wire identity.
pub fn prepareNamespacedClientOrderId(_: *anyopaque, namespace: [16]u8, account: canonical.ExchangeAccountIdentity, order: u64, _: canonical.ClientOrderId) !canonical.ClientOrderId {
    if (account == 0 or order == 0) return error.InvalidOrderIdentity;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("Ringwin canonical client order v1");
    hash.update(&namespace);
    var identity: [24]u8 = undefined;
    std.mem.writeInt(u128, identity[0..16], account, .little);
    std.mem.writeInt(u64, identity[16..24], order, .little);
    hash.update(&identity);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..14].*, .upper);
    var encoded: [32]u8 = undefined;
    @memcpy(encoded[0..4], "RW01");
    @memcpy(encoded[4..], &hex);
    return canonical.ClientOrderId.init(&encoded);
}

/// Convert TargetRemainingQuantity against a known prior revision, with checked units.
pub fn amendTotalQuantity(command: canonical.OrderCommand, report: canonical.ExecutionReport) ?canonical.InstrumentQuantity {
    const remaining = command.quantity orelse return null;
    const expected_cumulative = command.amend_expected_cumulative_quantity orelse return null;
    if (!std.meta.eql(expected_cumulative, report.cumulative_quantity)) return null;
    if (report.status != .accepted and report.status != .partially_filled) return null;
    if (command.revision <= 1 or report.revision != command.revision - 1 or
        report.order != command.orderIdentity() or report.exchange_account != command.exchange_account or
        report.instrument != command.instrument or !std.meta.eql(report.client_order_id, command.client_order_id) or
        report.venue_order == null or !std.meta.eql(report.venue_order, command.venue_order) or
        report.side != command.side or report.order_type != command.order_type or
        (report.venue_reduce_only orelse false) != command.venue_reduce_only or report.portfolio_reduce_only != command.portfolio_reduce_only or
        remaining.instrument != command.instrument or remaining.rules_version != command.rules_version or remaining.lots <= 0 or
        report.cumulative_quantity.instrument != command.instrument or report.cumulative_quantity.rules_version != command.rules_version or
        report.cumulative_quantity.lots < 0) return null;
    var total = remaining;
    total.lots = std.math.add(i128, total.lots, report.cumulative_quantity.lots) catch return null;
    return total;
}

pub const Environment = enum { simulation, demo, testnet };

pub const VenueConfig = struct {
    /// Copied only after Owner committed AssetDefinition activation. No implicit units.
    asset_definitions: ?@import("../trading/asset_registry.zig").Registry = null,
    instrument_definitions: ?@import("../trading/instrument_registry.zig").Registry = null,
    /// Bound from the committed instrument margin configuration.
    native_settlement_atoms: bool = false,
    venue: canonical.VenueIdentity,
    environment: Environment,
    exchange_account: canonical.ExchangeAccountIdentity,
    adapter_session: canonical.AdapterSessionIdentity,
    request_capacity: u16,
    output_capacity: u16,
};

pub const DrainDeadline = struct {
    monotonic_ns: u64,
};

pub const SendResult = enum { accepted, backpressure, stopped };
pub const StartError = error{ AlreadyStarted, Stopped, InvalidConfig };
pub const SendError = error{ NotStarted, InvalidRequest };
pub const DrainError = error{NotStarted};
pub const StopError = error{ NotStarted, OutputPending };

/// The shared execution seam binds exactly one Venue, environment, and
/// ExchangeAccount. Implementations own transport and codec; callers only see
/// canonical requests and bounded canonical event batches. Fee adjustments require
/// an explicit source revision and immutable original Fill provenance; balance
/// differences or the latest order fee cannot authorize a revision. Current live
/// adapters do not claim this capability.
pub const VenueAdapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (*anyopaque, VenueConfig) StartError!void,
        try_send: *const fn (*anyopaque, canonical.AdapterRequest) SendError!SendResult,
        try_drain: *const fn (*anyopaque) DrainError!?canonical.AdapterOutputBatch,
        stop: *const fn (*anyopaque, DrainDeadline) StopError!void,
        /// Pure encoding only: Gateway persists the returned ID before any send.
        prepare_client_order_id: ?*const fn (*anyopaque, [16]u8, canonical.ExchangeAccountIdentity, u64, canonical.ClientOrderId) anyerror!canonical.ClientOrderId = null,
    };

    pub fn prepareClientOrderId(self: VenueAdapter, namespace: [16]u8, account: canonical.ExchangeAccountIdentity, order_id: u64, requested: canonical.ClientOrderId) !canonical.ClientOrderId {
        const prepare = self.vtable.prepare_client_order_id orelse return requested;
        return prepare(self.ptr, namespace, account, order_id, requested);
    }

    pub fn start(self: VenueAdapter, config: VenueConfig) StartError!void {
        return self.vtable.start(self.ptr, config);
    }
    pub fn trySend(self: VenueAdapter, request: canonical.AdapterRequest) SendError!SendResult {
        return self.vtable.try_send(self.ptr, request);
    }
    pub fn tryDrain(self: VenueAdapter) DrainError!?canonical.AdapterOutputBatch {
        return self.vtable.try_drain(self.ptr);
    }
    pub fn stop(self: VenueAdapter, deadline: DrainDeadline) StopError!void {
        return self.vtable.stop(self.ptr, deadline);
    }
};
