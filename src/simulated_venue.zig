//! Deterministic implementation of the shared VenueAdapter contract.
//!
//! It has no transport capability and exists to exercise the same public seam
//! as real Venue implementations without giving replay a side-effect path.

const canonical = @import("canonical_event.zig");
const account_projection = @import("account_projection.zig");
const std = @import("std");
const venue = @import("venue_adapter.zig");
const contract = @import("venue_adapter_contract.zig");

const State = enum { idle, running, stopped };
const Binding = struct {
    venue: canonical.VenueIdentity,
    exchange_account: canonical.ExchangeAccountIdentity,
    adapter_session: canonical.AdapterSessionIdentity,
};

pub const SimulatedVenue = struct {
    asset_definitions: @import("asset_registry.zig").Registry = .{},
    state: State = .idle,
    binding: ?Binding = null,
    pending: ?canonical.AdapterOutputBatch = null,
    next_event_identity: u64 = 1,
    unknown_order: ?canonical.OrderIdentity = null,

    pub fn adapter(self: *SimulatedVenue) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{
            .start = start,
            .try_send = send,
            .try_drain = drain,
            .stop = stop,
        } };
    }

    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.environment != .simulation or config.request_capacity == 0 or config.output_capacity == 0)
            return error.InvalidConfig;
        self.asset_definitions = config.asset_definitions orelse .{};
        self.asset_definitions.validate() catch return error.InvalidConfig;
        self.binding = .{
            .venue = config.venue,
            .exchange_account = config.exchange_account,
            .adapter_session = config.adapter_session,
        };
        self.state = .running;
    }

    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.state == .stopped) return .stopped;
        if (self.pending != null) return .backpressure;
        const binding = self.binding orelse return error.InvalidRequest;
        const account = switch (request) {
            .order_command => |value| value.exchange_account,
            .order_batch => |value| blk: {
                if (value.len == 0) return error.InvalidRequest;
                for (value.slice()) |command|
                    if (command.exchange_account != binding.exchange_account or command.adapter_session != binding.adapter_session) return error.InvalidRequest;
                break :blk binding.exchange_account;
            },
            .order_reconciliation => |value| value.exchange_account,
            .account_reconciliation => |value| value.exchange_account,
        };
        if (account != binding.exchange_account) return error.InvalidRequest;
        switch (request) {
            .order_command => |value| if (value.adapter_session != binding.adapter_session) return error.InvalidRequest,
            .order_batch => {},
            .account_reconciliation => |value| if (value.expected_session != binding.adapter_session) return error.InvalidRequest,
            .order_reconciliation => {},
        }

        switch (request) {
            .order_command => |command| if (command.operation != .cancel and !self.asset_definitions.legacyConsumerCompatible()) return .backpressure,
            .order_batch => |commands| for (commands.slice()) |command| {
                if (command.operation != .cancel and !self.asset_definitions.legacyConsumerCompatible()) return .backpressure;
            },
            else => {},
        }
        var batch: canonical.AdapterOutputBatch = .{};
        switch (request) {
            .order_command => |command| self.emitOrderCommand(&batch, binding, command) catch return error.InvalidRequest,
            .order_batch => |commands| for (commands.slice()) |command| self.emitOrderCommand(&batch, binding, command) catch return error.InvalidRequest,
            .order_reconciliation => |reconciliation| {
                self.append(&batch, binding, reconciliation.identity, .{ .reconciliation_started = reconciliation.identity }) catch return error.InvalidRequest;
                self.append(&batch, binding, reconciliation.identity + 1, .{ .order_reconciliation_result = .{ .identity = reconciliation.identity, .complete = false } }) catch return error.InvalidRequest;
                if (self.unknown_order == reconciliation.order) self.unknown_order = null;
            },
            .account_reconciliation => |reconciliation| self.emitAccountReconciliation(&batch, binding, reconciliation) catch return error.InvalidRequest,
        }
        self.pending = batch;
        return .accepted;
    }

    fn emitAccountReconciliation(self: *SimulatedVenue, batch: *canonical.AdapterOutputBatch, binding: Binding, reconciliation: canonical.AccountReconciliationRequest) !void {
        try self.append(batch, binding, reconciliation.identity, .{ .account_reconciliation_started = reconciliation.identity });
        var snapshot: canonical.AccountBootstrapSnapshot = .{
            .identity = reconciliation.identity,
            .exchange_account = reconciliation.exchange_account,
            .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
            .source_stream = 1,
            .source_sequence = 0,
            .balance_count = 1,
            .position_count = 1,
            .margin_count = 1,
        };
        snapshot.balances[0] = .{ .asset = 1, .total = .{ .asset = 1, .atoms = 100 }, .available = .{ .asset = 1, .atoms = 100 }, .held = .{ .asset = 1, .atoms = 0 } };
        snapshot.positions[0] = .{ .instrument = 1, .side = .long, .quantity = .{ .instrument = 1, .rules_version = 1, .lots = 0 } };
        snapshot.margins[0] = .{ .amount = .{ .asset = 1, .atoms = 0 } };
        try self.append(batch, binding, reconciliation.identity + 1, .{ .account_bootstrap_snapshot = snapshot });
        try self.append(batch, binding, reconciliation.identity + 2, .{ .account_observed = .{ .identity = reconciliation.identity + 2, .exchange_account = reconciliation.exchange_account, .bootstrap = snapshot.identity, .source_stream = 1, .source_sequence = 1, .value = .{ .balance = .{ .asset = 1, .value = snapshot.balances[0] } } } });
        try self.append(batch, binding, reconciliation.identity + 3, .{ .account_observed = .{ .identity = reconciliation.identity + 3, .exchange_account = reconciliation.exchange_account, .bootstrap = snapshot.identity, .source_stream = 1, .source_sequence = 2, .value = .{ .position = .{ .instrument = 1, .side = .long, .value = snapshot.positions[0] } } } });
        try self.append(batch, binding, reconciliation.identity + 4, .{ .account_observed = .{ .identity = reconciliation.identity + 4, .exchange_account = reconciliation.exchange_account, .bootstrap = snapshot.identity, .source_stream = 1, .source_sequence = 3, .value = .{ .margin = .{ .value = snapshot.margins[0] } } } });
        try self.append(batch, binding, reconciliation.identity + 5, .{ .account_reconciliation_result = .{ .identity = reconciliation.identity, .complete = true } });
    }

    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        const batch = self.pending;
        self.pending = null;
        return batch;
    }

    fn stop(ptr: *anyopaque, deadline: venue.DrainDeadline) venue.StopError!void {
        const self: *SimulatedVenue = @ptrCast(@alignCast(ptr));
        _ = deadline;
        if (self.state == .idle) return error.NotStarted;
        if (self.pending != null) return error.OutputPending;
        self.state = .stopped;
    }

    fn emitOrderCommand(self: *SimulatedVenue, batch: *canonical.AdapterOutputBatch, binding: Binding, command: canonical.OrderCommand) !void {
        const dispatch_state: canonical.DispatchState = if (self.unknown_order != null and command.operation != .cancel)
            .not_sent
        else if (command.dispatch_deadline_monotonic_ns == 0)
            .unknown
        else if (!validOrderCommand(command))
            .not_sent
        else
            .submitted;
        try self.append(batch, binding, command.identity, .{ .order_dispatch_result = .{
            .command = command.identity,
            .state = dispatch_state,
        } });
        if (dispatch_state == .unknown) self.unknown_order = command.identity;
        if (dispatch_state != .submitted) return;

        const quantity = command.quantity.?;
        const price = command.limit_price.?;
        const zero_quantity = canonical.InstrumentQuantity{
            .instrument = command.instrument,
            .rules_version = command.rules_version,
            .lots = 0,
        };
        const venue_order = try venueOrder(binding.venue, command.identity);
        switch (command.operation) {
            .place => {
                try self.append(batch, binding, command.identity + 1, .{ .execution_report = .{
                    .identity = command.identity + 1,
                    .order = command.identity,
                    .client_order_id = command.client_order_id,
                    .venue_order = venue_order,
                    .instrument = command.instrument,
                    .exchange_account = command.exchange_account,
                    .revision = command.revision,
                    .status = .accepted,
                    .original_quantity = quantity,
                    .cumulative_quantity = zero_quantity,
                    .remaining_quantity = quantity,
                } });
                const first_quantity = @divTrunc(quantity.lots, 2);
                const split = first_quantity > 0 and first_quantity < quantity.lots;
                const first_fee = if (split) @divTrunc(command.fee_atoms, 2) else command.fee_atoms;
                const first_rebate = if (split) @divTrunc(command.rebate_atoms, 2) else command.rebate_atoms;
                const first_realized_pnl = if (split) @divTrunc(command.realized_pnl_atoms, 2) else command.realized_pnl_atoms;
                const first = canonical.InstrumentQuantity{ .instrument = quantity.instrument, .rules_version = quantity.rules_version, .lots = if (split) first_quantity else quantity.lots };
                try self.append(batch, binding, command.identity + 2, .{ .fill = .{
                    .identity = command.identity + 2,
                    .order = command.identity,
                    .client_order_id = command.client_order_id,
                    .venue_order = venue_order,
                    .venue_trade = try venueTrade(binding.venue, command.identity, 1),
                    .instrument = command.instrument,
                    .exchange_account = command.exchange_account,
                    .side = command.side,
                    .quantity = first,
                    .price = price,
                    .fee = if (command.fee_asset) |asset| .{ .asset = asset, .atoms = first_fee } else null,
                    .rebate = if (command.rebate_asset) |asset| .{ .asset = asset, .atoms = first_rebate } else null,
                    .realized_pnl = if (command.realized_pnl_asset) |asset| .{ .asset = asset, .atoms = first_realized_pnl } else null,
                    .liquidity = command.liquidity,
                } });
                if (split) {
                    const remaining = canonical.InstrumentQuantity{ .instrument = quantity.instrument, .rules_version = quantity.rules_version, .lots = quantity.lots - first_quantity };
                    try self.append(batch, binding, command.identity + 3, .{ .execution_report = .{
                        .identity = command.identity + 3,
                        .order = command.identity,
                        .client_order_id = command.client_order_id,
                        .venue_order = venue_order,
                        .instrument = command.instrument,
                        .exchange_account = command.exchange_account,
                        .revision = command.revision,
                        .status = .partially_filled,
                        .original_quantity = quantity,
                        .cumulative_quantity = first,
                        .remaining_quantity = remaining,
                    } });
                    try self.append(batch, binding, command.identity + 4, .{ .fill = .{
                        .identity = command.identity + 4,
                        .order = command.identity,
                        .client_order_id = command.client_order_id,
                        .venue_order = venue_order,
                        .venue_trade = try venueTrade(binding.venue, command.identity, 2),
                        .instrument = command.instrument,
                        .exchange_account = command.exchange_account,
                        .side = command.side,
                        .quantity = remaining,
                        .price = price,
                        .fee = if (command.fee_asset) |asset| .{ .asset = asset, .atoms = command.fee_atoms - first_fee } else null,
                        .rebate = if (command.rebate_asset) |asset| .{ .asset = asset, .atoms = command.rebate_atoms - first_rebate } else null,
                        .realized_pnl = if (command.realized_pnl_asset) |asset| .{ .asset = asset, .atoms = command.realized_pnl_atoms - first_realized_pnl } else null,
                        .liquidity = command.liquidity,
                    } });
                }
                const final_offset: u128 = if (split) 5 else 3;
                try self.append(batch, binding, command.identity + final_offset, .{ .execution_report = .{
                    .identity = command.identity + final_offset,
                    .order = command.identity,
                    .client_order_id = command.client_order_id,
                    .venue_order = venue_order,
                    .instrument = command.instrument,
                    .exchange_account = command.exchange_account,
                    .revision = command.revision,
                    .status = .filled,
                    .original_quantity = quantity,
                    .cumulative_quantity = quantity,
                    .remaining_quantity = zero_quantity,
                } });
            },
            .amend, .cancel => try self.append(batch, binding, command.identity + 1, .{ .execution_report = .{
                .identity = command.identity + 1,
                .order = command.identity,
                .client_order_id = command.client_order_id,
                .venue_order = venue_order,
                .instrument = command.instrument,
                .exchange_account = command.exchange_account,
                .revision = command.revision,
                .status = if (command.operation == .amend) .amended else .canceled,
                .cumulative_quantity = zero_quantity,
                .remaining_quantity = if (command.operation == .amend) quantity else zero_quantity,
            } }),
        }
    }

    fn validOrderCommand(command: canonical.OrderCommand) bool {
        return command.quantity != null and command.limit_price != null and command.quantity.?.lots > 0 and command.limit_price.?.ticks > 0;
    }

    fn append(self: *SimulatedVenue, batch: *canonical.AdapterOutputBatch, binding: Binding, source_fact_identity: u128, event: canonical.Payload) !void {
        const identity = self.next_event_identity;
        self.next_event_identity += 1;
        var event_envelope = envelope(binding, identity, source_fact_identity);
        event_envelope.event_type = @intFromEnum(canonical.eventType(event));
        try batch.append(.{ .envelope = event_envelope, .event = event });
    }

    fn venueOrder(venue_identity: canonical.VenueIdentity, order: canonical.OrderIdentity) !canonical.VenueOrderRef {
        var buffer: [64]u8 = undefined;
        return canonical.VenueOrderRef.init(venue_identity, try std.fmt.bufPrint(&buffer, "sim-order-{d}", .{order}));
    }

    fn venueTrade(venue_identity: canonical.VenueIdentity, order: canonical.OrderIdentity, leg: u8) !canonical.VenueTradeRef {
        var buffer: [64]u8 = undefined;
        return canonical.VenueTradeRef.init(venue_identity, try std.fmt.bufPrint(&buffer, "sim-trade-{d}-{d}", .{ order, leg }));
    }

    fn envelope(binding: Binding, identity: u64, source_fact_identity: u128) canonical.EventEnvelope {
        return .{
            .event_type = 1,
            .schema_version = canonical.schema_version,
            .identity = .{ .stream = 1, .sequence = identity },
            .source_fact_identity = source_fact_identity,
            .scope = .account,
            .venue = binding.venue,
            .exchange_account = binding.exchange_account,
            .source_stream = 1,
            .source_sequence = identity,
            .adapter_session = binding.adapter_session,
            .times = .{ .receive_utc_ns = 1, .monotonic_ns = 1, .audit_utc_ns = 1 },
            .raw_evidence = .{ .stream = 1, .sequence = identity, .digest = @splat(0) },
        };
    }
};

test "simulated venue returns a canonical result for every request kind" {
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{
        .venue = 1,
        .asset_definitions = try contract.activatedTestAssets(),
        .environment = .simulation,
        .exchange_account = 2,
        .adapter_session = 4,
        .request_capacity = 1,
        .output_capacity = 1,
    });

    const requests = [_]canonical.AdapterRequest{
        .{ .order_command = .{
            .identity = 1,
            .exchange_account = 2,
            .instrument = 3,
            .client_order_id = try canonical.ClientOrderId.init("simulated-1"),
            .capability_version = 1,
            .rules_version = 1,
            .config_version = 1,
            .adapter_session = 4,
            .dispatch_deadline_monotonic_ns = 5,
        } },
        .{ .order_reconciliation = .{ .identity = 6, .exchange_account = 2, .order = 1 } },
        .{ .account_reconciliation = .{ .identity = 7, .exchange_account = 2, .expected_session = 4 } },
    };
    const expected_tags = [_]std.meta.Tag(canonical.Payload){
        .order_dispatch_result,
        .reconciliation_started,
        .account_reconciliation_started,
    };
    for (requests, expected_tags) |request, expected_tag| {
        try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(request));
        const batch = (try adapter.tryDrain()).?;
        try std.testing.expect(batch.len >= 1);
        try std.testing.expectEqual(expected_tag, std.meta.activeTag(batch.events[0].event));
    }
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "simulated venue rejects requests outside its fixed account session" {
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{
        .venue = 1,
        .asset_definitions = try contract.activatedTestAssets(),
        .environment = .simulation,
        .exchange_account = 2,
        .adapter_session = 3,
        .request_capacity = 1,
        .output_capacity = 1,
    });
    try std.testing.expectError(error.InvalidRequest, adapter.trySend(.{ .account_reconciliation = .{
        .identity = 1,
        .exchange_account = 4,
        .expected_session = 3,
    } }));
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "simulated venue emits deterministic order lifecycle facts" {
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{
        .venue = 1,
        .asset_definitions = try contract.activatedTestAssets(),
        .environment = .simulation,
        .exchange_account = 2,
        .adapter_session = 3,
        .request_capacity = 2,
        .output_capacity = 8,
    });
    const command: canonical.OrderCommand = .{
        .identity = 10,
        .exchange_account = 2,
        .instrument = 4,
        .client_order_id = try canonical.ClientOrderId.init("lifecycle-10"),
        .capability_version = 1,
        .rules_version = 1,
        .config_version = 1,
        .adapter_session = 3,
        .dispatch_deadline_monotonic_ns = 9,
        .quantity = .{ .instrument = 4, .rules_version = 1, .lots = 100 },
        .limit_price = .{ .instrument = 4, .rules_version = 1, .ticks = 50_100 },
        .fee_asset = 5,
        .fee_atoms = 15,
        .rebate_asset = 6,
        .rebate_atoms = 2,
        .realized_pnl_asset = 7,
        .realized_pnl_atoms = 7,
    };
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = command }));
    const batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 6), batch.len);
    try std.testing.expectEqual(canonical.DispatchState.submitted, batch.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(canonical.ExecutionReportStatus.accepted, batch.events[1].event.execution_report.status);
    try std.testing.expectEqual(@as(i128, 7), batch.events[2].event.fill.fee.?.atoms);
    try std.testing.expectEqual(@as(canonical.AssetIdentity, 6), batch.events[2].event.fill.rebate.?.asset);
    try std.testing.expectEqual(canonical.ExecutionReportStatus.partially_filled, batch.events[3].event.execution_report.status);
    try std.testing.expectEqual(@as(i128, 8), batch.events[4].event.fill.fee.?.atoms);
    try std.testing.expectEqual(canonical.ExecutionReportStatus.filled, batch.events[5].event.execution_report.status);
    try contract.exerciseFillRecovery(batch.slice(), .{ .venue = 1, .exchange_account = 2, .adapter_session = 3 });

    var unknown = command;
    unknown.identity = 11;
    unknown.dispatch_deadline_monotonic_ns = 0;
    _ = try adapter.trySend(.{ .order_command = unknown });
    const unknown_batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.DispatchState.unknown, unknown_batch.events[0].event.order_dispatch_result.state);

    var blocked = command;
    blocked.identity = 13;
    _ = try adapter.trySend(.{ .order_command = blocked });
    try std.testing.expectEqual(canonical.DispatchState.not_sent, (try adapter.tryDrain()).?.events[0].event.order_dispatch_result.state);
    _ = try adapter.trySend(.{ .order_reconciliation = .{ .identity = 14, .exchange_account = 2, .order = unknown.identity } });
    try std.testing.expectEqual(canonical.ReconciliationResult{ .identity = 14, .complete = false }, (try adapter.tryDrain()).?.events[1].event.order_reconciliation_result);

    var cancel = command;
    cancel.identity = 12;
    cancel.operation = .cancel;
    _ = try adapter.trySend(.{ .order_command = cancel });
    const cancel_batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.ExecutionReportStatus.canceled, cancel_batch.events[1].event.execution_report.status);

    var commands = canonical.OrderCommandBatch{};
    try commands.append(command);
    var amended = command;
    amended.identity = 13;
    amended.operation = .amend;
    try commands.append(amended);
    _ = try adapter.trySend(.{ .order_batch = commands });
    const command_batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 8), command_batch.len);
    try std.testing.expectEqual(canonical.DispatchState.submitted, command_batch.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(canonical.ExecutionReportStatus.amended, command_batch.events[7].event.execution_report.status);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "account reconciliation drains replayable bootstrap facts" {
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{ .venue = 1, .asset_definitions = try contract.activatedTestAssets(), .environment = .simulation, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 8 });
    _ = try adapter.trySend(.{ .account_reconciliation = .{ .identity = 9, .exchange_account = 2, .expected_session = 3 } });
    const batch = (try adapter.tryDrain()).?;
    var live = account_projection.AccountProjection{};
    var replay = account_projection.AccountProjection{};
    for (batch.slice()) |record| {
        try live.apply(record.event);
        try replay.apply(record.event);
    }
    try std.testing.expect(live.valid and replay.valid);
    try std.testing.expectEqual(live.last_sequence, replay.last_sequence);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "both reconciliation result types leave through tryDrain" {
    var simulated: SimulatedVenue = .{};
    const adapter = simulated.adapter();
    try adapter.start(.{ .venue = 1, .asset_definitions = try contract.activatedTestAssets(), .environment = .simulation, .exchange_account = 2, .adapter_session = 3, .request_capacity = 1, .output_capacity = 8 });
    _ = try adapter.trySend(.{ .order_reconciliation = .{ .identity = 7, .exchange_account = 2, .order = 1 } });
    const order_batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.ReconciliationResult{ .identity = 7, .complete = false }, order_batch.events[1].event.order_reconciliation_result);
    _ = try adapter.trySend(.{ .account_reconciliation = .{ .identity = 8, .exchange_account = 2, .expected_session = 3 } });
    const account_batch = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.ReconciliationResult{ .identity = 8, .complete = true }, account_batch.events[5].event.account_reconciliation_result);
    try adapter.stop(.{ .monotonic_ns = 1 });
}
