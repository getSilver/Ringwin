//! Read-only shard projection for the control plane: semantically replays a
//! stable journal segment through the core's own recovery path and exposes a
//! bounded JSON view. It never owns or writes authoritative state; any
//! structural or semantic failure degrades explicitly instead of serving
//! stale data.

const std = @import("std");
const trading = @import("trading_shard.zig");
const journal = @import("journal.zig");
const operational = @import("operational.zig");

pub const max_gates = operational.max_gates;

pub const GateView = struct {
    identity: u128,
    kind: []const u8,
    reason: []const u8,
    open: bool,
};

pub const ProjectionStatus = enum { complete, truncated_tail };

pub const ShardView = struct {
    target_identity: u128,
    mode: []const u8,
    trading_authorized: bool,
    effective_authority: bool,
    may_reduce_only: bool,
    unresolved_latches: u32,
    open_orders: u32,
    portfolio_position_quantity: i64,
    exchange_position_quantity: i64,
    reconciliation_break: bool,
    last_sequence: u64,
    status: ProjectionStatus,
    operational_version: u64 = 0,
    mark_price_micros: i64 = 0,
    position_margin_requirement_micros: i64 = 0,
    open_order_reservation_micros: i64 = 0,
    portfolio_position_open_cost_micros: i64 = 0,
    gates: [max_gates]GateView = undefined,
    gate_count: u32 = 0,
};

pub const DegradedReason = enum {
    invalid_segment_header,
    invalid_first_sequence,
    invalid_record_magic,
    invalid_record_length,
    invalid_header_checksum,
    invalid_payload_checksum,
    invalid_footer,
    sequence_gap,
    unsupported_schema,
    unknown_event_type,
    semantic_replay_failed,
    orphan_derived_fact,
};

pub const Outcome = union(enum) {
    view: ShardView,
    degraded: struct { reason: DegradedReason, last_sequence: u64 },
};

fn degradedFromReaderError(err: anyerror) ?DegradedReason {
    return switch (err) {
        error.InvalidSegmentHeader, error.TruncatedSegmentHeader => .invalid_segment_header,
        error.InvalidFirstSequence => .invalid_first_sequence,
        error.InvalidRecordMagic => .invalid_record_magic,
        error.InvalidRecordLength => .invalid_record_length,
        error.InvalidHeaderChecksum => .invalid_header_checksum,
        error.InvalidPayloadChecksum => .invalid_payload_checksum,
        error.InvalidFooter => .invalid_footer,
        error.SequenceGap => .sequence_gap,
        else => null,
    };
}

fn degradedFromReplayError(err: anyerror) ?DegradedReason {
    return switch (err) {
        error.UnsupportedSchema => .unsupported_schema,
        error.UnknownControlCommand, error.UnknownSafetyGateKind, error.UnknownOmsSide, error.MissingEventIdentity => .unknown_event_type,
        error.OrphanDerivedFact => .orphan_derived_fact,
        else => null,
    };
}

/// Projects one stable journal segment; fails closed through an explicit
/// degraded outcome instead of ever guessing state.
pub fn projectJournal(bytes: []const u8, quantity_denominator: i64, reservation_model: trading.ReservationModel) Outcome {
    const result = trading.replayForProjection(bytes, quantity_denominator, reservation_model) catch |err| {
        if (degradedFromReaderError(err)) |reason|
            return .{ .degraded = .{ .reason = reason, .last_sequence = 0 } };
        if (degradedFromReplayError(err)) |reason|
            return .{ .degraded = .{ .reason = reason, .last_sequence = 0 } };
        // Semantic replay diverged from its own recorded facts.
        if (err == error.InputProducedNoFact)
            return .{ .degraded = .{ .reason = .semantic_replay_failed, .last_sequence = 0 } };
        return .{ .degraded = .{ .reason = .semantic_replay_failed, .last_sequence = 0 } };
    };
    return .{ .view = buildView(result.shard, result.status) };
}

fn buildView(shard: trading.TradingShard, status: journal.ScanStatus) ShardView {
    var view = ShardView{
        .target_identity = shard.operational_state.target_identity,
        .mode = @tagName(shard.operational_state.mode),
        .trading_authorized = shard.operational_state.trading_authorized,
        .effective_authority = shard.operational_state.effectiveTradingAuthority(),
        .may_reduce_only = shard.operational_state.mayReduceOnly(),
        .unresolved_latches = 0,
        .open_orders = countOpenOrders(shard),
        .portfolio_position_quantity = shard.portfolio_position.quantity,
        .exchange_position_quantity = shard.exchange_position.quantity,
        .reconciliation_break = shard.economicSummary().reconciliation_break,
        .last_sequence = shard.trace.len,
        .operational_version = shard.operational_state.version,
        .mark_price_micros = shard.mark_price_micros,
        .position_margin_requirement_micros = shard.position_margin_requirement_micros,
        .open_order_reservation_micros = shard.open_order_reservation_micros,
        .portfolio_position_open_cost_micros = shard.portfolio_position.open_cost_micros,
        .status = switch (status) {
            .clean => .complete,
            .truncated_tail => .truncated_tail,
        },
    };
    for (shard.operational_state.latches[0..shard.operational_state.latch_count]) |latch| {
        if (!latch.resolved) view.unresolved_latches += 1;
    }
    for (shard.operational_state.gates[0..shard.operational_state.gate_count]) |gate| {
        view.gates[view.gate_count] = .{
            .identity = gate.gate_identity,
            .kind = @tagName(gate.kind),
            .reason = @tagName(gate.reason),
            .open = gate.open,
        };
        view.gate_count += 1;
    }
    return view;
}

fn countOpenOrders(shard: trading.TradingShard) u32 {
    var count: u32 = 0;
    for (shard.oms.orders[0..shard.oms.order_count]) |order| {
        switch (order.state) {
            .filled, .canceled, .rejected => {},
            else => count += 1,
        }
    }
    return count;
}

/// Writes one compact JSON object for a complete view.
pub fn writeViewJson(view: ShardView, writer: anytype) !void {
    try writer.print(
        "{{\"target_identity\":\"{d}\",\"mode\":\"{s}\",\"trading_authorized\":{},\"effective_authority\":{},\"may_reduce_only\":{},\"unresolved_latches\":{d},\"open_orders\":{d},\"portfolio_position_quantity\":{d},\"exchange_position_quantity\":{d},\"reconciliation_break\":{},\"last_sequence\":{d},\"operational_version\":{d},\"mark_price_micros\":{d},\"position_margin_requirement_micros\":{d},\"open_order_reservation_micros\":{d},\"open_cost_micros\":{d},\"status\":\"{s}\",\"gates\":[",
        .{
            view.target_identity,
            view.mode,
            view.trading_authorized,
            view.effective_authority,
            view.may_reduce_only,
            view.unresolved_latches,
            view.open_orders,
            view.portfolio_position_quantity,
            view.exchange_position_quantity,
            view.reconciliation_break,
            view.last_sequence,
            view.operational_version,
            view.mark_price_micros,
            view.position_margin_requirement_micros,
            view.open_order_reservation_micros,
            view.portfolio_position_open_cost_micros,
            @tagName(view.status),
        },
    );
    for (view.gates[0..view.gate_count], 0..) |gate, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"identity\":\"{d}\",\"kind\":\"{s}\",\"reason\":\"{s}\",\"open\":{}}}", .{
            gate.identity, gate.kind, gate.reason, gate.open,
        });
    }
    try writer.writeAll("]}");
}

/// Writes one compact JSON object for a degraded outcome; no state fields are
/// served so a consumer can never mistake it for fresh data.
pub fn writeDegradedJson(reason: DegradedReason, last_sequence: u64, writer: anytype) !void {
    try writer.print("{{\"degraded\":true,\"reason\":\"{s}\",\"last_sequence\":{d}}}", .{
        @tagName(reason), last_sequence,
    });
}

pub fn writeOutcomeJson(outcome: Outcome, writer: anytype) !void {
    switch (outcome) {
        .view => |view| try writeViewJson(view, writer),
        .degraded => |d| try writeDegradedJson(d.reason, d.last_sequence, writer),
    }
}
