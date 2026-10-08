//! OKX execution implementation of the shared VenueAdapter seam.
//!
//! The protocol codec, priority scheduler, and qualified Demo transport remain
//! Venue-private. Only canonical requests and canonical dispatch facts cross
//! this boundary.

const std = @import("std");
const canonical_event_codec = @import("canonical_event_codec.zig");
const canonical = @import("canonical_event.zig");
const account_projection = @import("account_projection.zig");
const live = @import("okx_live_chain.zig");
const order = @import("okx_order_entry.zig");
const private = @import("okx_private_reconciliation.zig");
const venue = @import("venue_adapter.zig");
const contract = @import("venue_adapter_contract.zig");

pub const btc_usdt_spot: canonical.InstrumentIdentity = 0x4f4b58_00000001;
pub const btc_usdt_swap: canonical.InstrumentIdentity = 0x4f4b58_00000002;
pub const btc: canonical.AssetIdentity = 0x425443;
/// The core's single settlement-asset identity; venue spellings are normalized
/// before they cross the adapter boundary.
pub const usdt: canonical.AssetIdentity = 1;

pub const Clock = struct {
    ptr: *anyopaque,
    now_fn: *const fn (*anyopaque) u64,

    pub fn now(self: Clock) u64 {
        return self.now_fn(self.ptr);
    }
};

pub const InstrumentRules = struct {
    identity: canonical.InstrumentIdentity,
    tick_size: canonical.Decimal,
    lot_size: canonical.Decimal,
};

pub const Rules = struct {
    spot: InstrumentRules,
    swap: InstrumentRules,
};

const State = enum { idle, running, stopped };
const Binding = struct {
    venue: canonical.VenueIdentity,
    account: canonical.ExchangeAccountIdentity,
    session: canonical.AdapterSessionIdentity,
};
const Pending = struct {
    legacy_id: u64,
    command: canonical.OrderCommand,
    notional_usdt_micros: u64,
};
const pending_capacity = order.normal_queue_capacity + order.safety_queue_capacity;
const reconciliation_capacity = 8;

const OrderLink = struct {
    order: canonical.OrderIdentity,
    client_order_id: canonical.ClientOrderId,
    portfolio_reduce_only: bool,
    quantity: canonical.InstrumentQuantity,
    revision: u32,
};

const PendingOrderReconciliation = struct {
    identity: u128,
    order: canonical.OrderIdentity,
    venue_order: ?canonical.VenueOrderRef,
    result: canonical.ReconciliationStatus = .unresolved,
    cumulative: ?canonical.InstrumentQuantity = null,
    terminal_status: ?canonical.ExecutionReportStatus = null,
    evidence: ?canonical.ReconciliationEvidence = null,
};

const Bootstrap = struct {
    balance: ?private.PrivateEvent = null,
    positions: ?private.PrivateEvent = null,
    margin: ?private.PrivateEvent = null,
};

pub const OkxVenueAdapter = struct {
    asset_definitions: @import("asset_registry.zig").Registry = .{},
    native_settlement_atoms: bool = false,
    instrument_definitions: @import("instrument_registry.zig").Registry = .{},
    allocator: std.mem.Allocator,
    chain: *live.Chain,
    clock: Clock,
    profile: order.CapabilityProfile,
    rules: Rules,
    state: State = .idle,
    binding: ?Binding = null,
    scheduler: ?order.Scheduler = null,
    pending_output: ?canonical.AdapterOutputBatch = null,
    pending_private: [private.max_ws_events]private.PrivateEvent = undefined,
    pending_private_count: u8 = 0,
    private_failed: bool = false,
    pending: [pending_capacity]Pending = undefined,
    pending_count: u8 = 0,
    next_legacy_id: u64 = 1,
    next_event_sequence: u64 = 1,
    reconciler: ?*private.Reconciler = null,
    order_links: [pending_capacity]OrderLink = undefined,
    order_link_count: u8 = 0,
    pending_order_reconciliations: [reconciliation_capacity]PendingOrderReconciliation = undefined,
    pending_order_reconciliation_count: u8 = 0,
    pending_account_reconciliation: ?u128 = null,
    pending_economic_boundary: ?u64 = null,
    pending_economic_through: ?u64 = null,
    independent_before: ?canonical.AccountEconomicEvidence = null,
    economic_bills: [16]private.EconomicBillCheckpoint = undefined,
    economic_bill_count: u8 = 0,
    economic_queries: [4]canonical.RawEvidenceRef = undefined,
    economic_query_count: u8 = 0,
    economic_bill_after: ?u64 = null,
    economic_bills_complete: bool = false,
    known_economic_fills: [32]canonical.Fill = undefined,
    known_economic_fill_count: u8 = 0,
    balance_source_assets: [8]canonical.AssetIdentity = @splat(0),
    balance_source_times: [8]u64 = @splat(0),
    balance_source_count: u8 = 0,
    margin_source_utc_ns: u64 = 0,
    bootstrap: Bootstrap = .{},
    active_bootstrap: ?canonical.BootstrapSnapshotIdentity = null,
    bootstrap_released: bool = false,
    account_source_sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, chain: *live.Chain, clock: Clock, capability_profile: order.CapabilityProfile, instrument_rules: Rules) OkxVenueAdapter {
        return .{ .allocator = allocator, .chain = chain, .clock = clock, .profile = capability_profile, .rules = instrument_rules };
    }

    pub fn resumeAfter(self: *OkxVenueAdapter, last_sequence: u64) !void {
        const fresh = self.state == .idle and self.binding == null;
        const replay_drained = self.state == .running and self.chain.mode == .replay and self.pending_output == null and self.pending_private_count == 0;
        if (!fresh and !replay_drained)
            return error.InvalidState;
        self.next_event_sequence = @max(self.next_event_sequence, try std.math.add(u64, last_sequence, 1));
    }

    pub fn rememberRecoveredOrder(self: *OkxVenueAdapter, order_identity: canonical.OrderIdentity, client_order_id: canonical.ClientOrderId, portfolio_reduce_only: bool, quantity: canonical.InstrumentQuantity, revision: u32) !void {
        try self.rememberLink(.{ .order = order_identity, .client_order_id = client_order_id, .portfolio_reduce_only = portfolio_reduce_only, .quantity = quantity, .revision = revision });
    }

    /// The owning private transport feeds this reconciler. Keeping that I/O
    /// private lets this adapter release only canonical facts through its seam.
    pub fn attachPrivateReconciler(self: *OkxVenueAdapter, reconciler: *private.Reconciler) void {
        self.reconciler = reconciler;
    }

    pub fn beginPrivateSession(self: *OkxVenueAdapter) !void {
        try self.requireRunning();
        const binding = self.binding orelse return error.InvalidBinding;
        const reconciler = self.reconciler orelse return error.MissingPrivateReconciler;
        reconciler.beginSession(@intCast(binding.session));
    }

    /// Commits a complete REST frame to this adapter's RawIngress before its
    /// Venue-private decoder considers pagination or business fields.
    pub fn ingestPrivateRest(self: *OkxVenueAdapter, times: private.Times, source: private.IngressSource, page: private.Page, raw: []const u8) !private.IngressBatch {
        try self.requireRunning();
        if (self.pending_output != null) return error.OutputPending;
        const binding = self.binding orelse return error.InvalidBinding;
        const reconciler = self.reconciler orelse return error.MissingPrivateReconciler;
        var scoped_page = page;
        if (source == .rest_account_bills and self.pending_economic_through != null) {
            scoped_page.economic_from_utc_ns = self.pending_economic_boundary;
            scoped_page.economic_through_utc_ns = self.pending_economic_through;
        }
        var batch = reconciler.ingest(self.allocator, self.chain.raw_sink, @intCast(binding.session), times, source, scoped_page, raw) catch |err| {
            self.private_failed = true;
            return err;
        };
        if (source == .rest_account_bills and self.pending_economic_through != null and batch.rejection == null) {
            self.rememberEconomicPage(page, batch) catch {
                batch.rejection = .invalid_page_cursor;
                batch.event_count = 0;
            };
        }
        try self.acceptPrivateBatch(&batch, times);
        return batch;
    }

    /// Commits ACKs and private WebSocket frames before subscription, snapshot,
    /// buffering, and idempotency checks. Ready events become adapter-owned
    /// pending output, so Venue-private facts never escape this seam.
    pub fn ingestPrivateWs(self: *OkxVenueAdapter, times: private.Times, raw: []const u8) !private.IngressBatch {
        try self.requireRunning();
        if (self.pending_output != null or private.max_ws_events - self.pending_private_count < private.max_events_per_ingress)
            return error.OutputPending;
        const binding = self.binding orelse return error.InvalidBinding;
        const reconciler = self.reconciler orelse return error.MissingPrivateReconciler;
        var batch = reconciler.ingestWsMessage(self.allocator, self.chain.raw_sink, @intCast(binding.session), times, raw) catch |err| {
            self.private_failed = true;
            return err;
        };
        try self.acceptPrivateBatch(&batch, times);
        return batch;
    }

    /// Reparse one already-durable private WebSocket frame. Recovery passes
    /// the original evidence so this path cannot manufacture or re-persist
    /// RawIngress records.
    pub fn replayPrivateWs(self: *OkxVenueAdapter, times: private.Times, evidence: private.RawEvidenceRef, raw: []const u8) !private.IngressBatch {
        try self.requireReplayCapacity();
        const binding = self.binding orelse return error.InvalidBinding;
        const reconciler = self.reconciler orelse return error.MissingPrivateReconciler;
        var batch = try reconciler.replayWsMessage(self.allocator, @intCast(binding.session), times, evidence, raw);
        try self.acceptPrivateBatch(&batch, times);
        return batch;
    }

    /// Reparse one already-durable private REST page through the same
    /// reconciliation state machine, without another RawIngress append.
    pub fn replayPrivateRest(self: *OkxVenueAdapter, times: private.Times, source: private.IngressSource, page: private.Page, evidence: private.RawEvidenceRef, raw: []const u8) !private.IngressBatch {
        if (source.isWebSocket()) return error.InvalidReplayRoute;
        try self.requireReplayCapacity();
        const binding = self.binding orelse return error.InvalidBinding;
        const reconciler = self.reconciler orelse return error.MissingPrivateReconciler;
        var scoped_page = page;
        if (source == .rest_account_bills and self.pending_economic_through != null) {
            scoped_page.economic_from_utc_ns = self.pending_economic_boundary;
            scoped_page.economic_through_utc_ns = self.pending_economic_through;
        }
        var batch = try reconciler.replayRest(self.allocator, @intCast(binding.session), times, source, scoped_page, evidence, raw);
        if (source == .rest_account_bills and self.pending_economic_through != null and batch.rejection == null) {
            self.rememberEconomicPage(page, batch) catch {
                batch.rejection = .invalid_page_cursor;
                batch.event_count = 0;
            };
        }
        try self.acceptPrivateBatch(&batch, times);
        return batch;
    }

    pub const EconomicRequestRecord = struct { version: u16 = 1, request: canonical.AccountReconciliationRequest };

    pub fn replayEconomicRequest(self: *OkxVenueAdapter, raw: []const u8) !void {
        if (self.chain.mode != .replay) return error.InvalidReplayRoute;
        const value = try @import("snapshot_codec.zig").decodeBare(raw, EconomicRequestRecord);
        if (value.version != 1 or value.request.economic_boundary_utc_ns == null) return error.InvalidReplayRoute;
        try self.beginAccountReconciliation(value.request);
    }

    fn acceptPrivateBatch(self: *OkxVenueAdapter, batch: *private.IngressBatch, times: private.Times) !void {
        if (batch.rejection) |reason| {
            var output: canonical.AdapterOutputBatch = .{};
            try self.appendEconomicFault(&output, .{
                .source_time_utc_ns = null,
                .receive_time_utc_ns = times.receive_time_utc_ns,
                .monotonic_time_ns = times.monotonic_time_ns,
                .wall_time_utc_ns = times.wall_time_utc_ns,
                .raw_evidence = batch.raw_evidence,
                .source_fact_identity = batch.raw_evidence.sha256,
            }, switch (reason) {
                .missing_amount => .missing_amount,
                .missing_asset => .missing_asset,
                .malformed_amount => .malformed_amount,
                .amount_overflow => .overflow,
                else => .decoder_rejected,
            });
            self.pending_output = output;
        } else {
            // A report from the same raw frame must not release occupancy
            // before its economic facts have proved representable.
            var candidate = self.*;
            for (batch.eventSlice()) |event| {
                var checked: canonical.AdapterOutputBatch = .{};
                candidate.translatePrivate(&checked, event, false) catch |err| {
                    var output: canonical.AdapterOutputBatch = .{};
                    try self.appendEconomicFault(&output, event.envelope, economicReason(err));
                    self.pending_output = output;
                    batch.event_count = 0;
                    return;
                };
            }
            try self.queueReadyPrivate(batch.eventSlice());
            batch.event_count = 0;
        }
    }

    pub fn adapter(self: *OkxVenueAdapter) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop, .prepare_client_order_id = prepareClientOrderId } };
    }

    fn prepareClientOrderId(_: *anyopaque, namespace: [16]u8, account: canonical.ExchangeAccountIdentity, order_id: u64, _: canonical.ClientOrderId) !canonical.ClientOrderId {
        if (account == 0 or order_id == 0) return error.InvalidOrderIdentity;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("Ringwin OKX clOrdId v1");
        hash.update(&namespace);
        var identity: [64]u8 = undefined;
        hash.update(try std.fmt.bufPrint(&identity, "{x}:{x}", .{ account, order_id }));
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        var prefix: [14]u8 = undefined;
        @memcpy(&prefix, digest[0..14]);
        const hex = std.fmt.bytesToHex(prefix, .upper);
        var text: [32]u8 = undefined;
        @memcpy(text[0..4], "RWN1");
        @memcpy(text[4..], &hex);
        return canonical.ClientOrderId.init(&text);
    }

    fn requireRunning(self: *const OkxVenueAdapter) !void {
        return switch (self.state) {
            .idle => error.NotStarted,
            .stopped => error.Stopped,
            .running => {},
        };
    }

    fn requireReplayCapacity(self: *const OkxVenueAdapter) !void {
        try self.requireRunning();
        if (self.pending_output != null or private.max_ws_events - self.pending_private_count < private.max_events_per_ingress)
            return error.OutputPending;
    }

    fn start(ptr: *anyopaque, config: venue.VenueConfig) venue.StartError!void {
        const self: *OkxVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .running) return error.AlreadyStarted;
        if (self.state == .stopped) return error.Stopped;
        if (config.environment != .demo or config.venue == 0 or config.exchange_account == 0 or config.adapter_session == 0 or
            config.adapter_session > std.math.maxInt(u64) or config.request_capacity == 0 or config.output_capacity == 0 or
            self.profile.gateway_session != @as(u64, @intCast(config.adapter_session)))
            return error.InvalidConfig;
        self.scheduler = order.Scheduler.init(self.profile) catch return error.InvalidConfig;
        self.asset_definitions = config.asset_definitions orelse .{};
        self.native_settlement_atoms = config.native_settlement_atoms;
        self.asset_definitions.validate() catch return error.InvalidConfig;
        self.instrument_definitions = config.instrument_definitions orelse .{};
        self.instrument_definitions.validate() catch return error.InvalidConfig;
        if (self.native_settlement_atoms and self.instrument_definitions.count == 0) return error.InvalidConfig;
        for ([_]InstrumentRules{ self.rules.spot, self.rules.swap }) |configured| {
            if (self.instrument_definitions.get(configured.identity) != null)
                self.instrument_definitions.validateVenueUnits(&self.asset_definitions, configured.identity, self.profile.rules_version, configured.lot_size, configured.tick_size) catch return error.InvalidConfig;
        }
        self.binding = .{ .venue = config.venue, .account = config.exchange_account, .session = config.adapter_session };
        self.state = .running;
    }

    fn send(ptr: *anyopaque, request: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *OkxVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.state == .stopped) return .stopped;
        if (self.pending_output != null) return .backpressure;
        switch (request) {
            .order_command => |command| if (command.operation != .cancel and (self.private_failed or !self.instrument_definitions.permitsEconomicUnits(&self.asset_definitions, command.instrument))) return .backpressure,
            .order_batch => |commands| for (commands.slice()) |command| {
                if (command.operation != .cancel and (self.private_failed or !self.instrument_definitions.permitsEconomicUnits(&self.asset_definitions, command.instrument))) return .backpressure;
            },
            else => {},
        }
        switch (request) {
            .order_command => |command| try self.enqueue(command),
            .order_batch => |commands| {
                if (commands.len == 0) return error.InvalidRequest;
                for (commands.slice()) |command| try self.enqueue(command);
            },
            .order_reconciliation => |reconciliation| try self.beginOrderReconciliation(reconciliation),
            .account_reconciliation => |reconciliation| try self.beginAccountReconciliation(reconciliation),
        }
        self.pump();
        return .accepted;
    }

    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *OkxVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        self.pump();
        self.pumpPrivate();
        const output = self.pending_output;
        self.pending_output = null;
        return output;
    }

    fn stop(ptr: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {
        const self: *OkxVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.state == .idle) return error.NotStarted;
        if (self.pending_output != null or self.pending_private_count != 0 or self.pending_count != 0 or
            self.pending_order_reconciliation_count != 0 or self.pending_account_reconciliation != null)
            return error.OutputPending;
        self.state = .stopped;
    }

    fn beginOrderReconciliation(self: *OkxVenueAdapter, request: canonical.OrderReconciliationRequest) venue.SendError!void {
        const binding = self.binding orelse return error.InvalidRequest;
        if (request.exchange_account != binding.account or self.reconciler == null or self.pending_order_reconciliation_count == reconciliation_capacity or
            (request.venue_order != null and request.venue_order.?.venue != binding.venue) or
            (request.venue_order == null and !self.hasOrder(request.order)))
            return error.InvalidRequest;
        self.pending_order_reconciliations[self.pending_order_reconciliation_count] = .{
            .identity = request.identity,
            .order = request.order,
            .venue_order = request.venue_order,
        };
        self.pending_order_reconciliation_count += 1;
        self.appendControl(.{ .reconciliation_started = request.identity }, request.identity);
    }

    fn beginAccountReconciliation(self: *OkxVenueAdapter, request: canonical.AccountReconciliationRequest) venue.SendError!void {
        const binding = self.binding orelse return error.InvalidRequest;
        const reconciler = self.reconciler orelse return error.InvalidRequest;
        if (request.exchange_account != binding.account or request.expected_session != binding.session or self.pending_account_reconciliation != null)
            return error.InvalidRequest;
        if (request.economic_boundary_utc_ns) |boundary| {
            if (boundary == 0 or !reconciler.readiness().reconciliation_ready) return error.InvalidRequest;
            if (request.economic_through_utc_ns) |through| if (through <= boundary) return error.InvalidRequest;
            if (self.chain.mode != .replay) {
                var bytes: [256]u8 = undefined;
                const encoded = @import("snapshot_codec.zig").encodeBare(&bytes, EconomicRequestRecord{ .request = request }) catch return error.InvalidRequest;
                _ = reconciler.commitRaw(self.chain.raw_sink, @intCast(binding.session), .{ .receive_time_utc_ns = 0, .monotonic_time_ns = self.clock.now(), .wall_time_utc_ns = 0 }, encoded, .economic_reconciliation_request) catch {
                    self.private_failed = true;
                    return error.InvalidRequest;
                };
            }
            self.pending_account_reconciliation = request.identity;
            self.pending_economic_boundary = boundary;
            self.pending_economic_through = request.economic_through_utc_ns;
            self.independent_before = null;
            self.economic_bill_count = 0;
            self.economic_query_count = 0;
            self.economic_bill_after = null;
            self.economic_bills_complete = false;
            self.appendControl(.{ .account_reconciliation_started = request.identity }, request.identity);
            return;
        }
        reconciler.beginReconciliation(reconciler.rawWatermark()) catch return error.InvalidRequest;
        self.pending_account_reconciliation = request.identity;
        self.bootstrap = .{};
        self.active_bootstrap = null;
        self.bootstrap_released = false;
        self.appendControl(.{ .account_reconciliation_started = request.identity }, request.identity);
    }

    fn appendControl(self: *OkxVenueAdapter, event: canonical.Payload, source_fact_identity: u128) void {
        var output = self.pending_output orelse canonical.AdapterOutputBatch{};
        const binding = self.binding orelse return;
        const sequence = self.next_event_sequence;
        self.next_event_sequence +%= 1;
        output.append(.{ .envelope = .{
            .event_type = @intFromEnum(canonical.eventType(event)),
            .schema_version = canonical.schema_version,
            .identity = .{ .stream = binding.session, .sequence = sequence },
            .source_fact_identity = source_fact_identity,
            .scope = .account,
            .venue = binding.venue,
            .exchange_account = binding.account,
            .source_stream = binding.session,
            .source_sequence = sequence,
            .adapter_session = binding.session,
            .times = .{ .monotonic_ns = self.clock.now() },
            .raw_evidence = .{ .stream = binding.session, .sequence = sequence, .digest = @splat(0) },
        }, .event = event }) catch return;
        self.pending_output = output;
    }

    fn pumpPrivate(self: *OkxVenueAdapter) void {
        if (self.state != .running or self.pending_output != null) return;
        const reconciler = self.reconciler orelse return;
        var output: canonical.AdapterOutputBatch = .{};
        while (self.pending_private_count != 0 and output.events.len - output.len >= 8) {
            const event = self.pending_private[0];
            const previous_output = output;
            self.translatePrivate(&output, event, false) catch |err| {
                output = previous_output;
                self.appendEconomicFault(&output, event.envelope, economicReason(err)) catch return;
                _ = self.takeReadyPrivate();
                std.debug.print("okx_private_translate_failed={s}\n", .{@errorName(err)});
                self.private_failed = true;
                self.finishPrivateFailure(&output);
                break;
            };
            _ = self.takeReadyPrivate();
        }
        if (output.len != 0) {
            self.pending_output = output;
            return;
        }
        _ = reconciler.tryComplete() catch {
            self.finishReconciliation(false);
            return;
        };
        if (!reconciler.readiness().reconciliation_ready) return;

        while (output.events.len - output.len >= 8) {
            const event = reconciler.drainReconciled() orelse {
                self.finishPrivateBatch(&output);
                break;
            };
            const previous_output = output;
            self.translatePrivate(&output, event, true) catch |err| {
                output = previous_output;
                self.appendEconomicFault(&output, event.envelope, economicReason(err)) catch return;
                std.debug.print("okx_private_reconciled_translate_failed={s}\n", .{@errorName(err)});
                self.private_failed = true;
                self.finishPrivateFailure(&output);
                break;
            };
        }
        if (output.len != 0) self.pending_output = output;
    }

    fn queueReadyPrivate(self: *OkxVenueAdapter, events: []const private.PrivateEvent) !void {
        if (self.pending_private.len - self.pending_private_count < events.len) return error.OutputPending;
        @memcpy(self.pending_private[self.pending_private_count..][0..events.len], events);
        self.pending_private_count += @intCast(events.len);
    }

    fn takeReadyPrivate(self: *OkxVenueAdapter) private.PrivateEvent {
        const event = self.pending_private[0];
        self.pending_private_count -= 1;
        std.mem.copyForwards(private.PrivateEvent, self.pending_private[0..self.pending_private_count], self.pending_private[1 .. self.pending_private_count + 1]);
        return event;
    }

    fn finishPrivateBatch(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch) void {
        const required = self.pending_order_reconciliation_count + @intFromBool(self.pending_account_reconciliation != null);
        if (required > output.events.len - output.len) return;
        if (self.pending_economic_boundary == null) if (self.pending_account_reconciliation) |identity| {
            self.appendPrivateResult(output, .account_reconciliation_result, identity, .{ .identity = identity, .complete = self.active_bootstrap != null, .status = if (self.active_bootstrap == null) .unresolved else .found_terminal });
            self.pending_account_reconciliation = null;
        };
        for (self.pending_order_reconciliations[0..self.pending_order_reconciliation_count]) |*request| {
            const link = self.findOrder(request.order);
            self.appendPrivateResult(output, .order_reconciliation_result, request.identity, if (request.result != .unresolved and link != null and request.cumulative != null and request.evidence != null and
                request.cumulative.?.instrument == link.?.quantity.instrument and request.cumulative.?.rules_version == link.?.quantity.rules_version and
                request.cumulative.?.lots >= 0 and request.cumulative.?.lots <= link.?.quantity.lots) .{
                .identity = request.identity,
                .complete = true,
                .status = request.result,
                .order = request.order,
                .revision = link.?.revision,
                .cumulative_quantity = request.cumulative,
                .remaining_quantity = .{ .instrument = link.?.quantity.instrument, .rules_version = link.?.quantity.rules_version, .lots = link.?.quantity.lots - request.cumulative.?.lots },
                .terminal_status = request.terminal_status,
                .rules_version = link.?.quantity.rules_version,
                .evidence = request.evidence,
            } else .{ .identity = request.identity, .complete = false, .status = .unresolved });
        }
        self.pending_order_reconciliation_count = 0;
    }

    fn finishReconciliation(self: *OkxVenueAdapter, complete: bool) void {
        if (self.pending_output != null) return;
        var output: canonical.AdapterOutputBatch = .{};
        self.appendUnresolvedResults(&output, complete);
        if (output.len != 0) self.pending_output = output;
    }

    fn appendEconomicFault(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, envelope: private.EventEnvelope, reason: canonical.EconomicFaultReason) !void {
        self.private_failed = true;
        try self.appendPrivate(output, envelope, .account, null, null, digestIdentity(envelope.source_fact_identity), .{ .economic_fault = .{ .reason = reason } });
    }

    fn finishPrivateFailure(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch) void {
        self.appendUnresolvedResults(output, false);
    }

    fn appendUnresolvedResults(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, account_complete: bool) void {
        const required = self.pending_order_reconciliation_count + @intFromBool(self.pending_account_reconciliation != null);
        if (required > output.events.len - output.len) return;
        if (self.pending_account_reconciliation) |identity| {
            self.appendPrivateResult(output, .account_reconciliation_result, identity, .{ .identity = identity, .complete = account_complete, .status = .unresolved });
            self.pending_account_reconciliation = null;
        }
        for (self.pending_order_reconciliations[0..self.pending_order_reconciliation_count]) |request|
            self.appendPrivateResult(output, .order_reconciliation_result, request.identity, .{ .identity = request.identity, .complete = false, .status = .unresolved });
        self.pending_order_reconciliation_count = 0;
    }

    fn appendPrivateResult(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, comptime tag: std.meta.Tag(canonical.Payload), source_fact_identity: u128, result: canonical.ReconciliationResult) void {
        const event: canonical.Payload = @unionInit(canonical.Payload, @tagName(tag), result);
        const previous_len = output.len;
        self.appendPrivate(output, null, .account, null, null, source_fact_identity, event) catch {};
        if (output.len != previous_len) if (result.evidence) |evidence| {
            output.events[previous_len].envelope.times.receive_utc_ns = evidence.observed_at_utc_ns;
        };
    }

    fn translatePrivate(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, event: private.PrivateEvent, historical: bool) !void {
        switch (event.payload) {
            .economic_bill_checkpoint => |checkpoint| {
                if (self.pending_economic_through != null) {
                    if (self.economic_bill_count == self.economic_bills.len) return error.NativeAssetCapacityExceeded;
                    self.economic_bills[self.economic_bill_count] = checkpoint;
                    self.economic_bill_count += 1;
                }
            },
            .execution_report => |report| try self.translateReport(output, event.envelope, report, historical),
            .fill => |fill| try self.translateFill(output, event.envelope, fill, historical),
            .funding_settlement => |settlement| {
                const binding = self.binding orelse return error.InvalidBinding;
                const mapped = self.mapPrivateInstrument(settlement.instrument) orelse return error.UnsupportedInstrument;
                const configured = self.instrument_definitions.get(mapped.identity) orelse return error.UnsupportedInstrument;
                const asset = try self.asset_definitions.resolveCode(binding.venue, settlement.asset.slice());
                if (configured.product != .isolated_linear_usdt or configured.rules.settlement_asset != asset)
                    return error.UnsupportedMarginUnit;
                const identity = digestIdentity(event.envelope.source_fact_identity);
                try self.appendPrivate(output, event.envelope, .account, mapped.identity, asset, identity, .{ .funding_settlement = .{
                    .identity = identity,
                    .exchange_account = binding.account,
                    .instrument = mapped.identity,
                    .rules_version = configured.rules.version,
                    .venue_bill_id = @intFromEnum(settlement.venue_bill_id),
                    .amount = try assetAmount(self.asset_definitions, asset, settlement.amount),
                    .settlement_time_utc_ns = settlement.settlement_time_utc_ns,
                } });
            },
            .exchange_balance_snapshot => |snapshot| if (snapshot.scope == .full_rest and self.pending_economic_boundary != null) {
                try self.emitBalanceObserved(output, event.envelope, snapshot);
                try self.emitNativeReconciliation(output, event);
            } else if (snapshot.scope == .full_rest and self.bootstrap_released) {
                try self.emitBalanceObserved(output, event.envelope, snapshot);
            } else if (snapshot.scope == .full_rest) {
                self.bootstrap.balance = event;
                try self.emitBootstrap(output);
            } else try self.emitBalanceObserved(output, event.envelope, snapshot),
            .exchange_position_snapshot => |snapshot| if (snapshot.scope == .full_rest) {
                self.bootstrap.positions = event;
                try self.emitBootstrap(output);
            } else try self.emitPositionObserved(output, event.envelope, snapshot),
            .exchange_margin_snapshot => |snapshot| if (snapshot.scope == .full_rest and self.bootstrap_released) {
                try self.emitMarginObserved(output, event.envelope, snapshot);
            } else if (snapshot.scope == .full_rest) {
                self.bootstrap.margin = event;
                try self.emitBootstrap(output);
            } else try self.emitMarginObserved(output, event.envelope, snapshot),
            .venue_account_configuration_snapshot => |snapshot| try self.translateAccountConfiguration(output, event.envelope, snapshot),
        }
    }

    fn rememberEconomicPage(self: *OkxVenueAdapter, page: private.Page, batch: private.IngressBatch) !void {
        const boundary = self.pending_economic_boundary orelse return error.InvalidRequest;
        const through = self.pending_economic_through orelse return error.InvalidRequest;
        const query = batch.query_evidence orelse return error.IncompleteReconciliationEvidence;
        const target = page.request_target orelse return error.IncompleteReconciliationEvidence;
        if (self.economic_bills_complete or page.requested_after != self.economic_bill_after) return error.InvalidRestPage;
        if (boundary < std.time.ns_per_ms or boundary % std.time.ns_per_ms != 0 or through % std.time.ns_per_ms != 0) return error.InvalidRestPage;
        var buffer: [256]u8 = undefined;
        const expected = if (page.requested_after) |after|
            try std.fmt.bufPrint(&buffer, "/api/v5/account/bills?begin={d}&end={d}&limit=8&after={d}", .{ boundary / std.time.ns_per_ms - 1, through / std.time.ns_per_ms + 1, after })
        else
            try std.fmt.bufPrint(&buffer, "/api/v5/account/bills?begin={d}&end={d}&limit=8", .{ boundary / std.time.ns_per_ms - 1, through / std.time.ns_per_ms + 1 });
        if (!std.mem.eql(u8, target, expected) or batch.bill_row_count > 8 or page.final != (batch.bill_row_count < 8)) return error.InvalidRestPage;
        var rows: u8 = 0;
        var previous = page.requested_after;
        for (batch.bill_cursors[0..batch.bill_row_count], batch.bill_times[0..batch.bill_row_count]) |cursor, time| {
            if (previous) |older| if (cursor >= older) return error.InvalidRestPage;
            if (try std.math.add(u64, time, std.time.ns_per_ms) < boundary or time > try std.math.add(u64, through, std.time.ns_per_ms)) return error.InvalidRestPage;
            previous = cursor;
            if (time > boundary and time <= through) rows += 1;
        }
        var checkpoints: u8 = 0;
        for (batch.eventSlice()) |event| if (event.payload == .economic_bill_checkpoint) {
            checkpoints += 1;
        };
        if (rows != checkpoints or self.economic_query_count == self.economic_queries.len) return error.IncompleteReconciliationEvidence;
        self.economic_queries[self.economic_query_count] = .{ .stream = self.binding.?.session, .sequence = query.stream_sequence, .digest = query.sha256 };
        self.economic_query_count += 1;
        self.economic_bill_after = previous;
        self.economic_bills_complete = page.final;
    }

    fn proveEconomicBills(self: *OkxVenueAdapter, evidence: *canonical.AccountEconomicEvidence) !bool {
        if (!self.economic_bills_complete or self.economic_bill_count == 0 or evidence.query_count == 0) return false;
        const before = self.independent_before orelse return false;
        var balances = before.balances;
        var bills = self.economic_bills;
        var i: usize = 1;
        while (i < self.economic_bill_count) : (i += 1) {
            var j = i;
            while (j > 0 and bills[j].bill_id < bills[j - 1].bill_id) : (j -= 1)
                std.mem.swap(private.EconomicBillCheckpoint, &bills[j], &bills[j - 1]);
        }
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var latest: u64 = 0;
        var fees: [16]i128 = @splat(0);
        var rebates: [16]i128 = @splat(0);
        var expected_fees: [16]i128 = @splat(0);
        var expected_rebates: [16]i128 = @splat(0);
        for (bills[0..self.economic_bill_count], 0..) |bill, index| {
            if (index != 0 and bills[index - 1].bill_id == bill.bill_id) return false;
            const asset = try self.asset_definitions.resolveCode(self.binding.?.venue, bill.asset.slice());
            const after = try assetAmount(self.asset_definitions, asset, bill.balance);
            const change = try assetAmount(self.asset_definitions, asset, bill.change);
            const fee = try assetAmount(self.asset_definitions, asset, bill.fee);
            var found = false;
            for (balances[0..before.balance_count]) |*balance| {
                if (balance.asset != asset) continue;
                if (try std.math.add(i128, balance.atoms, change.atoms) != after.atoms) return false;
                balance.* = after;
                found = true;
            }
            if (!found) return false;
            latest = @max(latest, bill.time_utc_ns);
            const identity = std.math.cast(u64, digestIdentity(bill.related_identity)) orelse return error.IdentityOutOfRange;
            var fact: canonical.EconomicFactRef = .{ .identity = identity, .kind = if (bill.funding) .funding else .fill, .digest = @splat(0), .fee_confirmed = false };
            var bytes: [canonical_event_codec.max_encoded_len]u8 = undefined;
            var expected_fee: i128 = 0;
            var expected_rebate: i128 = 0;
            if (bill.funding) {
                const amount = try assetAmount(self.asset_definitions, asset, bill.funding_amount orelse return false);
                if (amount.atoms != change.atoms or fee.atoms != 0) return false;
                const mapped = self.mapPrivateInstrument(bill.instrument) orelse return false;
                const configured = self.instrument_definitions.get(mapped.identity) orelse return false;
                const payload: canonical.Payload = .{ .funding_settlement = .{ .identity = identity, .exchange_account = self.binding.?.account, .instrument = mapped.identity, .rules_version = configured.rules.version, .venue_bill_id = bill.bill_id, .amount = amount, .settlement_time_utc_ns = bill.time_utc_ns } };
                std.crypto.hash.sha2.Sha256.hash(try canonical_event_codec.encodePayload(&bytes, payload), &fact.digest, .{});
                fact.fee_confirmed = true;
            } else {
                var matched = false;
                for (self.known_economic_fills[0..self.known_economic_fill_count]) |fill| {
                    if (fill.identity != identity) continue;
                    const filled_at = fill.venue_fill_time_utc_ns orelse return false;
                    if (filled_at <= evidence.from_utc_ns or filled_at > bill.time_utc_ns) return false;
                    std.crypto.hash.sha2.Sha256.hash(try canonical_event_codec.encodePayload(&bytes, .{ .fill = fill }), &fact.digest, .{});
                    const charge = fill.fee orelse return false;
                    const rebate = fill.rebate orelse canonical.AssetAmount{ .asset = charge.asset, .atoms = 0 };
                    if (charge.asset != rebate.asset) return false;
                    if (charge.asset == asset) fact.fee_confirmed = true else if (fee.atoms != 0) return false;
                    expected_fee = charge.atoms;
                    expected_rebate = rebate.atoms;
                    matched = true;
                }
                if (!matched) return false;
            }
            var recorded = false;
            var fact_index: usize = evidence.covered_economic_fact_count;
            for (evidence.facts[0..evidence.covered_economic_fact_count], 0..) |*known, known_index| {
                if (known.identity != fact.identity or known.kind != fact.kind) continue;
                if (!std.mem.eql(u8, &known.digest, &fact.digest)) return false;
                known.fee_confirmed = known.fee_confirmed or fact.fee_confirmed;
                recorded = true;
                fact_index = known_index;
            }
            if (!recorded) {
                if (evidence.covered_economic_fact_count == evidence.facts.len) return error.NativeAssetCapacityExceeded;
                evidence.facts[evidence.covered_economic_fact_count] = fact;
                evidence.covered_economic_fact_count += 1;
            }
            expected_fees[fact_index] = expected_fee;
            expected_rebates[fact_index] = expected_rebate;
            if (fee.atoms < 0) fees[fact_index] = try std.math.add(i128, fees[fact_index], try std.math.sub(i128, 0, fee.atoms)) else rebates[fact_index] = try std.math.add(i128, rebates[fact_index], fee.atoms);
            const encoded = try @import("snapshot_codec.zig").encodeBare(&bytes, .{ bill.bill_id, asset, after.atoms, change.atoms, fee.atoms, bill.time_utc_ns, bill.related_identity });
            hasher.update(encoded);
        }
        if (latest != evidence.through_utc_ns or before.balance_count != evidence.balance_count) return false;
        for (evidence.balances[0..evidence.balance_count]) |closing| {
            var matched = false;
            for (balances[0..before.balance_count]) |balance| if (std.meta.eql(balance, closing)) {
                matched = true;
            };
            if (!matched) return false;
        }
        for (evidence.facts[0..evidence.covered_economic_fact_count], 0..) |*fact, fact_index| {
            if (fact.kind == .fill) fact.fee_confirmed = fact.fee_confirmed and fees[fact_index] == expected_fees[fact_index] and rebates[fact_index] == expected_rebates[fact_index];
        }
        hasher.final(&evidence.bill_chain_digest);
        evidence.bills_complete = true;
        return true;
    }

    fn emitNativeReconciliation(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, event: private.PrivateEvent) !void {
        const boundary = self.pending_economic_boundary orelse return;
        const identity = self.pending_account_reconciliation orelse return error.InvalidRequest;
        const binding = self.binding orelse return error.InvalidBinding;
        const snapshot = event.payload.exchange_balance_snapshot;
        var evidence: canonical.AccountEconomicEvidence = .{
            .exchange_account = binding.account,
            .scope = .spot_and_isolated_linear_usdt,
            .from_utc_ns = boundary,
            .through_utc_ns = snapshot.venue_update_time_utc_ns,
            .source = .{ .stream = binding.session, .sequence = event.envelope.raw_evidence.stream_sequence, .digest = event.envelope.raw_evidence.sha256 },
            .balance_count = snapshot.balance_count,
        };
        for (snapshot.balances[0..snapshot.balance_count], 0..) |balance, index| {
            const asset = try self.asset_definitions.resolveCode(binding.venue, balance.asset.slice());
            evidence.balances[index] = try assetAmount(self.asset_definitions, asset, balance.cash_balance orelse return error.MissingAmount);
            evidence.asset_versions[index] = self.asset_definitions.get(asset).?.definition.version;
        }
        if (self.pending_economic_through != null and self.independent_before == null) {
            if (evidence.through_utc_ns != boundary) return error.IncompleteReconciliationEvidence;
            self.independent_before = evidence;
            return;
        }
        var complete = boundary == evidence.through_utc_ns;
        if (self.pending_economic_through) |through| {
            const before = self.independent_before orelse return error.IncompleteReconciliationEvidence;
            evidence.before_source = before.source;
            evidence.before_balances = before.balances;
            evidence.before_balance_count = before.balance_count;
            evidence.query_count = self.economic_query_count;
            @memcpy(evidence.query_sources[0..evidence.query_count], self.economic_queries[0..evidence.query_count]);
            complete = evidence.through_utc_ns == through and try self.proveEconomicBills(&evidence);
        }
        try self.appendPrivate(output, event.envelope, .account, null, null, identity, .{ .account_reconciliation_result = .{
            .identity = identity,
            .complete = complete,
            .status = if (complete) .found_terminal else .unresolved,
            .account_economics = evidence,
        } });
        self.pending_account_reconciliation = null;
        self.pending_economic_boundary = null;
        self.pending_economic_through = null;
    }

    fn translateReport(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, envelope: private.EventEnvelope, report: private.ExecutionReport, historical: bool) !void {
        if (!report.owned_by_ringwin) return;
        const link = self.findOrderByClient(report.client_order_id.slice()) orelse {
            if (historical and (report.status == .filled or report.status == .canceled)) return;
            return error.UnmappedOrder;
        };
        const rules = self.mapPrivateInstrument(report.instrument) orelse return error.UnsupportedInstrument;
        const quantity = try self.privateQuantity(rules.identity, rules.rules, report.quantity);
        const cumulative = try self.privateQuantity(rules.identity, rules.rules, report.cumulative_filled_quantity);
        if (cumulative.lots > quantity.lots) return error.InvalidReportQuantity;
        const venue_order = try venueOrderRef((self.binding orelse return error.InvalidBinding).venue, @intFromEnum(report.venue_order_id));
        try self.appendPrivate(output, envelope, .account, rules.identity, null, digestIdentity(envelope.source_fact_identity), .{ .execution_report = .{
            .identity = digestIdentity(envelope.source_fact_identity),
            .order = link.order,
            .client_order_id = link.client_order_id,
            .venue_order = venue_order,
            .instrument = rules.identity,
            .exchange_account = (self.binding orelse return error.InvalidBinding).account,
            .revision = 1,
            .side = switch (report.side) {
                .buy => .buy,
                .sell => .sell,
            },
            .order_type = switch (report.order_type) {
                .market => .market,
                .limit => .limit,
                .post_only => .post_only,
                .fok => .fok,
                .ioc => .ioc,
            },
            .time_in_force = switch (report.order_type) {
                .fok => .fill_or_kill,
                .ioc => .immediate_or_cancel,
                .post_only => .post_only,
                else => .good_til_canceled,
            },
            .venue_reduce_only = report.venue_reduce_only,
            .portfolio_reduce_only = link.portfolio_reduce_only,
            .position_side = if (report.position_side) |_| .net else null,
            .position_mode_net = if (report.position_side) |_| true else null,
            .margin_mode_isolated = if (report.margin_mode) |mode| mode == .isolated else null,
            .leverage = if (report.leverage) |leverage| decimal(leverage) else null,
            .status = switch (report.status) {
                .live => .accepted,
                .partially_filled => .partially_filled,
                .filled => .filled,
                .canceled => .canceled,
            },
            .original_quantity = quantity,
            .cumulative_quantity = cumulative,
            .remaining_quantity = .{ .instrument = rules.identity, .rules_version = self.profile.rules_version, .lots = quantity.lots - cumulative.lots },
            .limit_price = if (report.limit_price) |value| try self.privatePrice(rules.identity, rules.rules, value) else null,
            .average_fill_price = if (report.average_fill_price) |value| try self.privatePrice(rules.identity, rules.rules, value) else null,
            .venue_create_time_utc_ns = report.venue_create_time_utc_ns,
            .venue_update_time_utc_ns = report.venue_update_time_utc_ns,
        } });
        self.observeOrder(report.venue_order_id, link.order, report.status, cumulative, envelope);
    }

    fn translateFill(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, envelope: private.EventEnvelope, fill: private.Fill, historical: bool) !void {
        const binding = self.binding orelse return error.InvalidBinding;
        const fee_asset = try self.asset_definitions.resolveCode(binding.venue, fill.fee_asset.slice());
        const signed_fee = try assetAmount(self.asset_definitions, fee_asset, fill.fee);
        const explicit_rebate = if (fill.rebate) |value|
            try assetAmount(self.asset_definitions, try self.asset_definitions.resolveCode(binding.venue, (fill.rebate_asset orelse return error.MissingRebateAsset).slice()), value)
        else
            null;
        if (explicit_rebate != null and explicit_rebate.?.atoms < 0) return error.InvalidFee;
        const normalized_fee: canonical.AssetAmount = if (signed_fee.atoms < 0) .{
            .asset = signed_fee.asset,
            .atoms = std.math.sub(i128, 0, signed_fee.atoms) catch return error.DecimalOverflow,
        } else .{ .asset = signed_fee.asset, .atoms = 0 };
        const realized_pnl = if (fill.realized_pnl) |value| try assetAmount(self.asset_definitions, usdt, value) else null;
        // Account-wide monetary validation precedes portfolio ownership filtering.
        if (!fill.owned_by_ringwin) return;
        const link = self.findOrderByClient(fill.client_order_id.slice()) orelse {
            if (historical) return;
            return error.UnmappedOrder;
        };
        const rules = self.mapPrivateInstrument(fill.instrument) orelse return error.UnsupportedInstrument;
        const venue_order = try venueOrderRef(binding.venue, @intFromEnum(fill.venue_order_id));
        const venue_trade = try venueTradeRef(binding.venue, @intFromEnum(fill.venue_trade_id));
        try self.appendPrivate(output, envelope, .account, rules.identity, null, digestIdentity(envelope.source_fact_identity), .{ .fill = .{
            .identity = digestIdentity(envelope.source_fact_identity),
            .order = link.order,
            .client_order_id = link.client_order_id,
            .venue_order = venue_order,
            .venue_trade = venue_trade,
            .instrument = rules.identity,
            .exchange_account = binding.account,
            .side = switch (fill.side) {
                .buy => .buy,
                .sell => .sell,
            },
            .quantity = try self.privateQuantity(rules.identity, rules.rules, fill.quantity),
            .price = try self.privatePrice(rules.identity, rules.rules, fill.price),
            .fee = normalized_fee,
            .rebate = explicit_rebate orelse if (signed_fee.atoms > 0) signed_fee else null,
            .realized_pnl = realized_pnl,
            .liquidity = switch (fill.liquidity orelse return error.MissingLiquidity) {
                .maker => .maker,
                .taker => .taker,
            },
            .venue_fill_time_utc_ns = fill.venue_fill_time_utc_ns,
        } });
        const translated_fill = output.events[output.len - 1].event.fill;
        for (self.known_economic_fills[0..self.known_economic_fill_count]) |known| if (known.identity == translated_fill.identity) return;
        if (self.known_economic_fill_count == self.known_economic_fills.len) return error.NativeAssetCapacityExceeded;
        self.known_economic_fills[self.known_economic_fill_count] = translated_fill;
        self.known_economic_fill_count += 1;
    }

    fn translateAccountConfiguration(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, envelope: private.EventEnvelope, snapshot: private.VenueAccountConfigurationSnapshot) !void {
        const binding = self.binding orelse return error.InvalidBinding;
        switch (snapshot) {
            .account => |account| try self.appendPrivate(output, envelope, .account, null, null, digestIdentity(envelope.source_fact_identity), .{ .venue_account_configuration_snapshot = .{
                .identity = digestIdentity(envelope.source_fact_identity),
                .exchange_account = binding.account,
                .value = .{ .account = .{
                    .position_mode_net = account.position_mode == .net,
                    .can_read = account.can_read,
                    .can_trade = account.can_trade,
                    .can_withdraw = account.can_withdraw,
                    .auto_loan = account.auto_loan,
                    .spot_borrow_enabled = account.spot_borrow_enabled,
                    .contract_isolated_autonomy = account.contract_isolated_mode == .autonomy,
                } },
            } }),
            .isolated_leverage => |leverage| {
                const rules = self.mapPrivateInstrument(leverage.instrument) orelse return error.UnsupportedInstrument;
                try self.appendPrivate(output, envelope, .account, rules.identity, null, digestIdentity(envelope.source_fact_identity), .{ .venue_account_configuration_snapshot = .{
                    .identity = digestIdentity(envelope.source_fact_identity),
                    .exchange_account = binding.account,
                    .value = .{ .isolated_leverage = .{
                        .instrument = rules.identity,
                        .position_mode_net = leverage.position_side == .net,
                        .margin_mode_isolated = leverage.margin_mode == .isolated,
                        .leverage = decimal(leverage.leverage),
                    } },
                } });
            },
        }
    }

    fn emitBootstrap(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch) !void {
        const balance_event = self.bootstrap.balance orelse return;
        const position_event = self.bootstrap.positions orelse return;
        const margin_event = self.bootstrap.margin orelse return;
        const balance = balance_event.payload.exchange_balance_snapshot;
        const positions = position_event.payload.exchange_position_snapshot;
        const margin = margin_event.payload.exchange_margin_snapshot;
        const binding = self.binding orelse return error.InvalidBinding;
        var snapshot: canonical.AccountBootstrapSnapshot = .{
            .identity = digestIdentity(balance_event.envelope.source_fact_identity),
            .exchange_account = binding.account,
            .scope = .{ .balances_complete = true, .positions_complete = true, .margins_complete = true },
            .source_stream = binding.session,
            .source_sequence = self.account_source_sequence,
            .balance_count = balance.balance_count,
            .position_count = positions.position_count,
            .margin_count = 1,
        };
        for (balance.balances[0..balance.balance_count], 0..) |value, index|
            snapshot.balances[index] = try balanceFor(self.asset_definitions, binding.venue, value);
        for (positions.positions[0..positions.position_count], 0..) |value, index|
            snapshot.positions[index] = try self.positionFor(value);
        snapshot.margins[0] = try marginFor(margin);
        if (self.bootstrap_released) return;
        for (snapshot.balances[0..snapshot.balance_count]) |value| _ = try self.acceptBalanceTime(value.asset, balance.venue_update_time_utc_ns);
        self.margin_source_utc_ns = @max(self.margin_source_utc_ns, margin.venue_update_time_utc_ns);
        self.active_bootstrap = snapshot.identity;
        self.bootstrap_released = true;
        try self.appendPrivate(output, balance_event.envelope, .account, null, null, snapshot.identity, .{ .account_bootstrap_snapshot = snapshot });
    }

    fn acceptBalanceTime(self: *OkxVenueAdapter, asset: canonical.AssetIdentity, time: u64) !bool {
        for (self.balance_source_assets[0..self.balance_source_count], self.balance_source_times[0..self.balance_source_count]) |known, *latest| {
            if (known != asset) continue;
            if (time < latest.*) return false;
            latest.* = time;
            return true;
        }
        if (self.balance_source_count == self.balance_source_assets.len) return error.NativeAssetCapacityExceeded;
        self.balance_source_assets[self.balance_source_count] = asset;
        self.balance_source_times[self.balance_source_count] = time;
        self.balance_source_count += 1;
        return true;
    }

    fn emitBalanceObserved(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, envelope: private.EventEnvelope, snapshot: private.ExchangeBalanceSnapshot) !void {
        const bootstrap = self.active_bootstrap orelse return error.MissingBootstrap;
        const binding = self.binding orelse return error.InvalidBinding;
        for (snapshot.balances[0..snapshot.balance_count]) |value| {
            const balance = try balanceFor(self.asset_definitions, binding.venue, value);
            if (!try self.acceptBalanceTime(balance.asset, snapshot.venue_update_time_utc_ns)) continue;
            self.account_source_sequence = try std.math.add(u64, self.account_source_sequence, 1);
            try self.appendPrivate(output, envelope, .asset, null, balance.asset, digestIdentity(envelope.source_fact_identity), .{ .account_observed = .{
                .identity = digestIdentity(envelope.source_fact_identity) + self.account_source_sequence,
                .exchange_account = binding.account,
                .bootstrap = bootstrap,
                .source_stream = binding.session,
                .source_sequence = self.account_source_sequence,
                .value = .{ .balance = .{ .asset = balance.asset, .value = balance } },
            } });
        }
    }

    fn emitPositionObserved(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, envelope: private.EventEnvelope, snapshot: private.ExchangePositionSnapshot) !void {
        const bootstrap = self.active_bootstrap orelse return error.MissingBootstrap;
        const binding = self.binding orelse return error.InvalidBinding;
        for (snapshot.positions[0..snapshot.position_count]) |value| {
            self.account_source_sequence = try std.math.add(u64, self.account_source_sequence, 1);
            const position = try self.positionFor(value);
            try self.appendPrivate(output, envelope, .instrument, position.instrument, null, digestIdentity(envelope.source_fact_identity), .{ .account_observed = .{
                .identity = digestIdentity(envelope.source_fact_identity) + self.account_source_sequence,
                .exchange_account = binding.account,
                .bootstrap = bootstrap,
                .source_stream = binding.session,
                .source_sequence = self.account_source_sequence,
                .value = .{ .position = .{ .instrument = position.instrument, .side = position.side, .value = position, .removed = position.quantity.lots == 0 } },
            } });
        }
    }

    fn emitMarginObserved(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, envelope: private.EventEnvelope, snapshot: private.ExchangeMarginSnapshot) !void {
        if (snapshot.venue_update_time_utc_ns < self.margin_source_utc_ns) return;
        self.margin_source_utc_ns = snapshot.venue_update_time_utc_ns;
        const bootstrap = self.active_bootstrap orelse return error.MissingBootstrap;
        const binding = self.binding orelse return error.InvalidBinding;
        self.account_source_sequence = try std.math.add(u64, self.account_source_sequence, 1);
        const margin = try marginFor(snapshot);
        try self.appendPrivate(output, envelope, .account, null, null, digestIdentity(envelope.source_fact_identity), .{ .account_observed = .{
            .identity = digestIdentity(envelope.source_fact_identity) + self.account_source_sequence,
            .exchange_account = binding.account,
            .bootstrap = bootstrap,
            .source_stream = binding.session,
            .source_sequence = self.account_source_sequence,
            .value = .{ .margin = .{ .value = margin } },
        } });
    }

    fn positionFor(self: *const OkxVenueAdapter, value: private.Position) !canonical.AccountPosition {
        const mapped = self.mapPrivateInstrument(value.instrument) orelse return error.UnsupportedInstrument;
        var settlement: canonical.AssetIdentity = 0;
        if (value.margin != null or value.unrealized_pnl != null) {
            const binding = self.binding orelse return error.InvalidBinding;
            const currency = value.currency orelse return error.MissingAsset;
            settlement = try self.asset_definitions.resolveCode(binding.venue, currency.slice());
            const configured = self.instrument_definitions.get(mapped.identity) orelse return error.UnsupportedInstrument;
            if (configured.venue != binding.venue or configured.rules.version != self.profile.rules_version or configured.rules.settlement_asset != settlement)
                return error.UnsupportedMarginUnit;
        }
        const signed = try self.privateQuantity(mapped.identity, mapped.rules, value.quantity);
        const side: canonical.PositionSide = if (signed.lots < 0) .short else .long;
        const quantity = canonical.InstrumentQuantity{ .instrument = mapped.identity, .rules_version = self.profile.rules_version, .lots = if (signed.lots < 0) -signed.lots else signed.lots };
        return .{
            .instrument = mapped.identity,
            .side = side,
            .quantity = quantity,
            .average_price = if (value.average_price) |price| try self.privatePrice(mapped.identity, mapped.rules, price) else null,
            .mark_price = if (value.mark_price) |price| try self.privatePrice(mapped.identity, mapped.rules, price) else null,
            .liquidation_price = if (value.liquidation_price) |price| try self.privatePrice(mapped.identity, mapped.rules, price) else null,
            .margin = if (value.margin) |amount| try assetAmount(self.asset_definitions, settlement, amount) else null,
            .leverage = if (value.leverage) |leverage| decimal(leverage) else null,
            .unrealized_pnl = if (value.unrealized_pnl) |pnl| try assetAmount(self.asset_definitions, settlement, pnl) else null,
        };
    }

    fn enqueue(self: *OkxVenueAdapter, command: canonical.OrderCommand) venue.SendError!void {
        const binding = self.binding orelse return error.InvalidRequest;
        if (command.exchange_account != binding.account) return error.InvalidRequest;
        if (command.operation != .cancel) self.rememberOrder(command) catch {
            self.appendResult(command, .not_sent, .adapter_backpressure, null);
            return;
        };
        const legacy_id = self.allocateLegacyId() catch {
            self.appendResult(command, .not_sent, .adapter_backpressure, null);
            return;
        };
        const translated = self.translate(command, legacy_id) catch |err| {
            std.debug.print("okx_translate_order_failed={s}\n", .{@errorName(err)});
            self.appendResult(command, .not_sent, translateError(err), null);
            return;
        };
        const scheduler = &(self.scheduler orelse return error.InvalidRequest);
        const guard = self.guardFor(&translated.command);
        switch (scheduler.enqueue(translated.command, guard, self.clock.now())) {
            .queued => self.appendPending(.{ .legacy_id = legacy_id, .command = command, .notional_usdt_micros = translated.notional_usdt_micros }) catch
                self.appendResult(command, .not_sent, .adapter_backpressure, null),
            .dispatch => |result| self.appendResult(command, dispatchState(result.state), rejectReason(result.reason), null),
        }
    }

    fn pump(self: *OkxVenueAdapter) void {
        if (self.state != .running or self.pending_output != null) return;
        const scheduler = &(self.scheduler orelse return);
        const next = scheduler.next(self.clock.now(), self.guardSource()) orelse return;
        switch (next) {
            .dispatch => |result| {
                const pending = self.takePending(result.command_id) orelse return;
                self.appendResult(pending.command, dispatchState(result.state), rejectReason(result.reason), null);
            },
            .batch => |batch| self.dispatchBatch(batch),
        }
    }

    fn dispatchBatch(self: *OkxVenueAdapter, batch: order.TransportBatch) void {
        if (self.private_failed or !self.asset_definitions.consumerCompatible(self.native_settlement_atoms)) for (batch.slice()) |legacy| {
            if (legacy.operation() != .cancel) {
                for (batch.slice()) |item| if (self.takePending(item.command_id)) |pending| self.appendResult(pending.command, .not_sent, .venue_unavailable, null);
                return;
            }
        };
        var commands: [order.max_batch_items]live.AuthorizedCommand = undefined;
        for (batch.slice(), 0..) |legacy, index| {
            const pending = self.findPending(legacy.command_id) orelse return;
            commands[index] = .{ .command = legacy, .reserved_notional_usdt_micros = pending.notional_usdt_micros };
        }
        const attempt = self.chain.dispatch(self.allocator, commands[0..batch.count]) catch |err| {
            std.debug.print("[DEBUG-okx-adapter] dispatch_error={s}\n", .{@errorName(err)});
            const reason = dispatchErrorReason(err);
            const state: canonical.DispatchState = if (reason == null) .unknown else .not_sent;
            for (batch.slice()) |legacy| if (self.takePending(legacy.command_id)) |pending|
                self.appendResult(pending.command, state, reason, null);
            return;
        };
        for (attempt.dispatch.items[0..attempt.dispatch.count]) |result| if (self.takePending(result.command_id)) |pending|
            self.appendResult(pending.command, dispatchState(result.state), rejectReason(result.reason), attempt.raw_evidence);
    }

    fn translate(self: *const OkxVenueAdapter, command: canonical.OrderCommand, legacy_id: u64) !struct { command: order.OrderCommand, notional_usdt_micros: u64 } {
        const binding = self.binding orelse return error.InvalidBinding;
        const mapped = self.mapInstrument(command.instrument) orelse return error.UnsupportedInstrument;
        if (command.adapter_session > std.math.maxInt(u64)) return error.StaleVersion;
        const client_order_id = try order.ClientOrderId.init(command.client_order_id.slice());
        var result: order.OrderCommand = .{
            .command_id = legacy_id,
            .order_id = legacy_id,
            .order_revision = command.revision,
            .shard_sequence = legacy_id,
            .instrument = mapped.instrument,
            .client_order_id = client_order_id,
            .venue_order_id = try self.venueOrder(command.venue_order, binding.venue),
            .capability_version = command.capability_version,
            .rules_version = command.rules_version,
            .config_version = command.config_version,
            .gateway_session = @intCast(command.adapter_session),
            .dispatch_deadline_monotonic_ns = command.dispatch_deadline_monotonic_ns,
            .risk_reservation_id = 1,
            .payload = undefined,
        };
        switch (command.operation) {
            .place => {
                const quantity = command.quantity orelse return error.UnsupportedValue;
                if (quantity.rules_version != command.rules_version)
                    return error.StaleVersion;
                try validatePlace(command, mapped.rules);
                const quantity_decimal = try decimalFor(quantity.lots, mapped.rules.lot_size);
                const limit_price = if (command.limit_price) |price| try decimalFor(price.ticks, mapped.rules.tick_size) else null;
                const protection_price = if (command.market_protection_price) |price| try decimalFor(price.ticks, mapped.rules.tick_size) else null;
                result.payload = .{ .place = .{ .side = switch (command.side) {
                    .buy => .buy,
                    .sell => .sell,
                }, .kind = try orderKind(command), .quantity = quantity_decimal, .limit_price = limit_price, .market_protection_price = protection_price, .portfolio_reduce_only = command.portfolio_reduce_only, .venue_reduce_only = command.venue_reduce_only } };
                return .{ .command = result, .notional_usdt_micros = try notionalMicros(quantity_decimal, limit_price orelse protection_price orelse return error.UnsupportedValue) };
            },
            .amend => {
                const quantity = command.quantity orelse return error.UnsupportedValue;
                if (quantity.rules_version != command.rules_version) return error.StaleVersion;
                try validateQuantity(quantity, mapped.rules);
                result.payload = .{ .amend = .{ .request_id = order.amendRequestId(command.identity), .target_remaining_quantity = try decimalFor(quantity.lots, mapped.rules.lot_size), .cumulative_filled_quantity = .{ .coefficient = 0, .scale = 0 }, .new_limit_price = if (command.limit_price) |price| blk: {
                    if (price.rules_version != command.rules_version) return error.StaleVersion;
                    try validatePrice(price, mapped.rules);
                    break :blk try decimalFor(price.ticks, mapped.rules.tick_size);
                } else null, .increases_risk = false } };
                return .{ .command = result, .notional_usdt_micros = 1 };
            },
            .cancel => {
                result.payload = .{ .cancel = .{} };
                return .{ .command = result, .notional_usdt_micros = 1 };
            },
        }
    }

    fn mapInstrument(self: *const OkxVenueAdapter, identity: canonical.InstrumentIdentity) ?struct { instrument: order.Instrument, rules: InstrumentRules } {
        if (identity == self.rules.spot.identity) return .{ .instrument = .btc_usdt_spot, .rules = self.rules.spot };
        if (identity == self.rules.swap.identity) return .{ .instrument = .btc_usdt_swap, .rules = self.rules.swap };
        return null;
    }

    fn mapPrivateInstrument(self: *const OkxVenueAdapter, instrument: private.Instrument) ?struct { identity: canonical.InstrumentIdentity, rules: InstrumentRules } {
        const identity = privateInstrumentIdentity(instrument) orelse return null;
        const mapped = self.mapInstrument(identity) orelse return null;
        return .{ .identity = identity, .rules = mapped.rules };
    }

    fn privateQuantity(self: *const OkxVenueAdapter, instrument: canonical.InstrumentIdentity, instrument_rules: InstrumentRules, value: private.Decimal) !canonical.InstrumentQuantity {
        const increment = try instrument_rules.lot_size.exactAtoms(instrument_rules.lot_size.scale);
        return canonical.InstrumentQuantity.fromDecimal(instrument, self.profile.rules_version, decimal(value), instrument_rules.lot_size.scale, increment);
    }

    fn privatePrice(self: *const OkxVenueAdapter, instrument: canonical.InstrumentIdentity, instrument_rules: InstrumentRules, value: private.Decimal) !canonical.InstrumentPrice {
        const increment = try instrument_rules.tick_size.exactAtoms(instrument_rules.tick_size.scale);
        return canonical.InstrumentPrice.fromDecimal(instrument, self.profile.rules_version, decimal(value), instrument_rules.tick_size.scale, increment);
    }

    fn venueOrder(_: *const OkxVenueAdapter, reference: ?canonical.VenueOrderRef, venue_identity: canonical.VenueIdentity) !?order.VenueOrderId {
        const value = reference orelse return null;
        if (value.venue != venue_identity) return error.InvalidVenueOrder;
        return @enumFromInt(try std.fmt.parseInt(u64, value.value.slice(), 10));
    }

    fn guardFor(self: *const OkxVenueAdapter, command: *const order.OrderCommand) order.Guard {
        return .{ .order_entry_ready = true, .risk_reservation_valid = true, .capability_version = self.profile.version, .rules_version = self.profile.rules_version, .config_version = self.profile.config_version, .gateway_session = self.profile.gateway_session, .current_order_revision = command.order_revision, .cumulative_filled_quantity = .{ .coefficient = 0, .scale = 0 } };
    }

    fn guardSource(self: *OkxVenueAdapter) order.GuardSource {
        return .{ .ptr = self, .load_fn = loadGuard };
    }

    fn loadGuard(ptr: *anyopaque, command: *const order.OrderCommand) ?order.Guard {
        const self: *OkxVenueAdapter = @ptrCast(@alignCast(ptr));
        if (self.findPending(command.command_id) == null) return null;
        return self.guardFor(command);
    }

    fn appendPending(self: *OkxVenueAdapter, pending: Pending) !void {
        if (self.pending_count == self.pending.len) return error.Full;
        self.pending[self.pending_count] = pending;
        self.pending_count += 1;
    }

    fn rememberOrder(self: *OkxVenueAdapter, command: canonical.OrderCommand) !void {
        const quantity = command.quantity orelse return error.InvalidOrderLink;
        try self.rememberLink(.{ .order = command.identity, .client_order_id = command.client_order_id, .portfolio_reduce_only = command.portfolio_reduce_only, .quantity = quantity, .revision = command.revision });
    }

    fn rememberLink(self: *OkxVenueAdapter, incoming: OrderLink) !void {
        for (self.order_links[0..self.order_link_count]) |*link| {
            if (link.order != incoming.order) continue;
            if (!std.meta.eql(link.*, incoming))
                return error.ConflictingOrderIdentity;
            return;
        }
        if (self.order_link_count == self.order_links.len) return error.Full;
        self.order_links[self.order_link_count] = incoming;
        self.order_link_count += 1;
    }

    fn findPending(self: *const OkxVenueAdapter, legacy_id: u64) ?*const Pending {
        for (self.pending[0..self.pending_count]) |*pending| if (pending.legacy_id == legacy_id) return pending;
        return null;
    }

    fn takePending(self: *OkxVenueAdapter, legacy_id: u64) ?Pending {
        for (self.pending[0..self.pending_count], 0..) |pending, index| if (pending.legacy_id == legacy_id) {
            var cursor = index;
            while (cursor + 1 < self.pending_count) : (cursor += 1) self.pending[cursor] = self.pending[cursor + 1];
            self.pending_count -= 1;
            return pending;
        };
        return null;
    }

    fn findOrderByClient(self: *const OkxVenueAdapter, client_order_id: []const u8) ?OrderLink {
        for (self.order_links[0..self.order_link_count]) |link|
            if (std.mem.eql(u8, link.client_order_id.slice(), client_order_id)) return link;
        return null;
    }

    fn findOrder(self: *const OkxVenueAdapter, identity: canonical.OrderIdentity) ?OrderLink {
        for (self.order_links[0..self.order_link_count]) |link| if (link.order == identity) return link;
        return null;
    }

    fn hasOrder(self: *const OkxVenueAdapter, identity: canonical.OrderIdentity) bool {
        for (self.order_links[0..self.order_link_count]) |link| if (link.order == identity) return true;
        return false;
    }

    fn observeOrder(self: *OkxVenueAdapter, venue_order: private.VenueOrderId, order_identity: canonical.OrderIdentity, status: private.ExecutionStatus, cumulative: canonical.InstrumentQuantity, envelope: private.EventEnvelope) void {
        const binding = self.binding orelse return;
        const link = self.findOrder(order_identity) orelse return;
        var digits: [64]u8 = undefined;
        const reference = canonical.VenueOrderRef.init(binding.venue, std.fmt.bufPrint(&digits, "{d}", .{@intFromEnum(venue_order)}) catch return) catch return;
        for (self.pending_order_reconciliations[0..self.pending_order_reconciliation_count]) |*request| {
            if (request.order != order_identity or (request.venue_order != null and !std.meta.eql(request.venue_order.?, reference))) continue;
            request.result = switch (status) {
                .live, .partially_filled => .found_live,
                .filled, .canceled => .found_terminal,
            };
            request.cumulative = cumulative;
            request.terminal_status = switch (status) {
                .filled => .filled,
                .canceled => .canceled,
                else => null,
            };
            request.evidence = .{
                .scope = .{ .exchange_account = binding.account, .instrument = link.quantity.instrument, .order = request.order, .revision = link.revision, .from_utc_ns = envelope.receive_time_utc_ns, .through_utc_ns = envelope.receive_time_utc_ns },
                .observed_at_utc_ns = envelope.receive_time_utc_ns,
                .source = .{ .stream = binding.session, .sequence = envelope.raw_evidence.stream_sequence, .digest = envelope.raw_evidence.sha256 },
            };
        }
    }

    fn appendPrivate(self: *OkxVenueAdapter, output: *canonical.AdapterOutputBatch, envelope: ?private.EventEnvelope, scope: canonical.CanonicalEventScope, instrument: ?canonical.InstrumentIdentity, asset: ?canonical.AssetIdentity, source_fact_identity: u128, event: canonical.Payload) !void {
        const binding = self.binding orelse return error.InvalidBinding;
        const sequence = self.next_event_sequence;
        self.next_event_sequence = try std.math.add(u64, self.next_event_sequence, 1);
        const private_envelope = envelope orelse return output.append(.{ .envelope = .{
            .event_type = @intFromEnum(canonical.eventType(event)),
            .schema_version = canonical.schema_version,
            .identity = .{ .stream = binding.session, .sequence = sequence },
            .source_fact_identity = source_fact_identity,
            .scope = scope,
            .venue = binding.venue,
            .exchange_account = binding.account,
            .instrument = instrument,
            .asset = asset,
            .source_stream = binding.session,
            .source_sequence = sequence,
            .adapter_session = binding.session,
            .times = .{ .monotonic_ns = self.clock.now() },
            .raw_evidence = .{ .stream = binding.session, .sequence = sequence, .digest = @splat(0) },
        }, .event = event });
        try output.append(.{ .envelope = .{
            .event_type = @intFromEnum(canonical.eventType(event)),
            .schema_version = canonical.schema_version,
            .identity = .{ .stream = binding.session, .sequence = sequence },
            .source_fact_identity = source_fact_identity,
            .scope = scope,
            .venue = binding.venue,
            .exchange_account = binding.account,
            .instrument = instrument,
            .asset = asset,
            .source_stream = binding.session,
            .source_sequence = private_envelope.raw_evidence.stream_sequence,
            .adapter_session = binding.session,
            .times = .{ .source_utc_ns = private_envelope.source_time_utc_ns, .receive_utc_ns = private_envelope.receive_time_utc_ns, .monotonic_ns = private_envelope.monotonic_time_ns, .audit_utc_ns = private_envelope.wall_time_utc_ns },
            .raw_evidence = .{ .stream = binding.session, .sequence = private_envelope.raw_evidence.stream_sequence, .digest = private_envelope.raw_evidence.sha256 },
        }, .event = event });
    }

    fn allocateLegacyId(self: *OkxVenueAdapter) !u64 {
        const identity = self.next_legacy_id;
        self.next_legacy_id = try std.math.add(u64, identity, 1);
        return identity;
    }

    fn appendResult(self: *OkxVenueAdapter, command: canonical.OrderCommand, state: canonical.DispatchState, reason: ?canonical.CanonicalRejectReason, raw: ?@import("okx_public_market.zig").RawEvidenceRef) void {
        var output = self.pending_output orelse canonical.AdapterOutputBatch{};
        const binding = self.binding orelse return;
        const sequence = self.next_event_sequence;
        self.next_event_sequence +%= 1;
        output.append(.{ .envelope = .{
            .event_type = 1,
            .schema_version = canonical.schema_version,
            .identity = .{ .stream = binding.session, .sequence = sequence },
            .source_fact_identity = command.identity,
            .scope = .account,
            .venue = binding.venue,
            .exchange_account = binding.account,
            .instrument = command.instrument,
            .source_stream = binding.session,
            .source_sequence = sequence,
            .adapter_session = binding.session,
            .times = .{ .monotonic_ns = self.clock.now() },
            .raw_evidence = if (raw) |evidence| .{ .stream = binding.session, .sequence = evidence.stream_sequence, .digest = evidence.sha256 } else .{ .stream = binding.session, .sequence = sequence, .digest = @splat(0) },
        }, .event = .{ .order_dispatch_result = .{ .command = command.identity, .state = state, .reason = reason } } }) catch return;
        self.pending_output = output;
    }
};

fn validatePlace(command: canonical.OrderCommand, instrument_rules: InstrumentRules) !void {
    try validateQuantity(command.quantity orelse return error.UnsupportedValue, instrument_rules);
    _ = try orderKind(command);
    switch (command.order_type) {
        .market => {
            if (command.limit_price != null) return error.UnsupportedValue;
            try validatePrice(command.market_protection_price orelse return error.UnsupportedValue, instrument_rules);
        },
        else => {
            try validatePrice(command.limit_price orelse return error.UnsupportedValue, instrument_rules);
            if (command.market_protection_price != null) return error.UnsupportedValue;
        },
    }
}

fn orderKind(command: canonical.OrderCommand) !order.OrderKind {
    return switch (command.order_type) {
        .limit => switch (command.time_in_force) {
            .good_til_canceled => .limit_gtc,
            .immediate_or_cancel => .limit_ioc,
            .fill_or_kill => .limit_fok,
            .post_only => return error.UnsupportedValue,
        },
        .market => if (command.time_in_force == .immediate_or_cancel) .market else error.UnsupportedValue,
        .ioc => if (command.time_in_force == .immediate_or_cancel) .limit_ioc else error.UnsupportedValue,
        .fok => if (command.time_in_force == .fill_or_kill) .limit_fok else error.UnsupportedValue,
        .post_only => if (command.time_in_force == .post_only) .post_only else error.UnsupportedValue,
    };
}

fn digestIdentity(digest: [32]u8) u128 {
    return std.mem.readInt(u64, digest[0..8], .little);
}

test "OKX canonical economic identities fit the legacy authoritative seam" {
    try std.testing.expect(digestIdentity(@splat(0xff)) <= std.math.maxInt(u64));
}

fn decimal(value: private.Decimal) canonical.Decimal {
    return .{ .coefficient = value.coefficient, .scale = value.scale };
}

fn privateInstrumentIdentity(value: private.Instrument) ?canonical.InstrumentIdentity {
    return switch (value) {
        .btc_usdt_spot => btc_usdt_spot,
        .btc_usdt_swap => btc_usdt_swap,
    };
}

fn assetAmount(assets: @import("asset_registry.zig").Registry, asset: canonical.AssetIdentity, value: private.Decimal) !canonical.AssetAmount {
    return assets.amount(asset, decimal(value));
}

fn balanceFor(assets: @import("asset_registry.zig").Registry, venue_identity: canonical.VenueIdentity, value: private.Balance) !canonical.AccountBalance {
    const asset = try assets.resolveCode(venue_identity, value.asset.slice());
    const total = try assetAmount(assets, asset, value.equity orelse return error.MissingBalanceTotal);
    const available = try assetAmount(assets, asset, value.available_balance orelse return error.MissingBalanceAvailable);
    const held = try assetAmount(assets, asset, value.frozen_balance orelse return error.MissingBalanceHeld);
    return .{
        .asset = asset,
        .total = total,
        .available = available,
        .held = held,
        .liability = if (value.liability) |amount| try assetAmount(assets, asset, amount) else null,
        .cash_balance = if (value.cash_balance) |amount| try assetAmount(assets, asset, amount) else null,
        .isolated_liability = if (value.isolated_liability) |amount| try assetAmount(assets, asset, amount) else null,
        .cross_liability = if (value.cross_liability) |amount| try assetAmount(assets, asset, amount) else null,
    };
}

fn marginFor(value: private.ExchangeMarginSnapshot) !canonical.AccountMargin {
    const total = value.total_equity_usd orelse return error.MissingMarginEquity;
    return .{
        .usd_valuation = .{
            .total_equity = decimal(total),
            .adjusted_equity = if (value.adjusted_equity_usd) |amount_value| decimal(amount_value) else null,
            .initial_margin = if (value.initial_margin_usd) |amount_value| decimal(amount_value) else null,
            .maintenance_margin = if (value.maintenance_margin_usd) |amount_value| decimal(amount_value) else null,
            .isolated_equity = if (value.isolated_equity_usd) |amount_value| decimal(amount_value) else null,
        },
        .margin_ratio = if (value.margin_ratio) |ratio| decimal(ratio) else null,
    };
}

fn venueOrderRef(venue_identity: canonical.VenueIdentity, value: u64) !canonical.VenueOrderRef {
    var text: [64]u8 = undefined;
    return canonical.VenueOrderRef.init(venue_identity, try std.fmt.bufPrint(&text, "{d}", .{value}));
}

fn venueTradeRef(venue_identity: canonical.VenueIdentity, value: i64) !canonical.VenueTradeRef {
    var text: [64]u8 = undefined;
    return canonical.VenueTradeRef.init(venue_identity, try std.fmt.bufPrint(&text, "{d}", .{value}));
}

fn validateQuantity(quantity: canonical.InstrumentQuantity, instrument_rules: InstrumentRules) !void {
    if (quantity.instrument != instrument_rules.identity or quantity.rules_version == 0 or quantity.lots <= 0) return error.UnsupportedValue;
}

fn validatePrice(price: canonical.InstrumentPrice, instrument_rules: InstrumentRules) !void {
    if (price.instrument != instrument_rules.identity or price.rules_version == 0 or price.ticks <= 0) return error.UnsupportedValue;
}

fn decimalFor(units: i128, increment: canonical.Decimal) !order.Decimal {
    return .{ .coefficient = try std.math.mul(i128, units, increment.coefficient), .scale = increment.scale };
}

fn notionalMicros(quantity: order.Decimal, price: order.Decimal) !u64 {
    const product = canonical.Decimal{ .coefficient = try std.math.mul(i128, quantity.coefficient, price.coefficient), .scale = try std.math.add(u8, quantity.scale, price.scale) };
    if (product.coefficient <= 0) return error.InvalidNotional;
    const micros = product.exactAtoms(6) catch |err| switch (err) {
        error.InexactDecimal => blk: {
            var divisor: i128 = 1;
            for (0..product.scale - 6) |_| divisor = try std.math.mul(i128, divisor, 10);
            break :blk @divTrunc(product.coefficient, divisor) + @intFromBool(@rem(product.coefficient, divisor) != 0);
        },
        else => return err,
    };
    return std.math.cast(u64, micros) orelse error.InvalidNotional;
}

test "OKX fee-reduced spot sell rounds dispatch notional up for the Demo cap" {
    try std.testing.expectEqual(@as(u64, 4_194_622), try notionalMicros(
        .{ .coefficient = 4_995, .scale = 8 },
        .{ .coefficient = 839_764, .scale = 1 },
    ));
}

fn dispatchState(value: order.DispatchState) canonical.DispatchState {
    return switch (value) {
        .not_sent => .not_sent,
        .submitted => .submitted,
        .unknown => .unknown,
    };
}

fn rejectReason(value: ?order.RejectReason) ?canonical.CanonicalRejectReason {
    return switch (value orelse return null) {
        .capability_unsupported => .capability_unsupported,
        .deadline_expired => .deadline_expired,
        .adapter_backpressure, .rate_limited => .adapter_backpressure,
        .venue_unavailable, .order_entry_not_ready => .venue_unavailable,
        .invalid_spec, .invalid_risk_reservation, .stale_order_revision, .capability_version_changed => .stale_version,
        else => .other_venue_reject,
    };
}

fn translateError(err: anyerror) canonical.CanonicalRejectReason {
    return switch (err) {
        error.UnsupportedInstrument => .unsupported_instrument,
        error.StaleVersion => .stale_version,
        error.InvalidVenueOrder, error.InvalidCharacter, error.Overflow => .unsupported_value,
        else => .unsupported_value,
    };
}

fn dispatchErrorReason(err: anyerror) ?canonical.CanonicalRejectReason {
    return switch (err) {
        error.SideEffectsDisabled => .capability_unsupported,
        error.DemoNotQualified => .venue_unavailable,
        error.NotionalLimitExceeded => .unsupported_value,
        error.InstrumentNotAllowed => .unsupported_instrument,
        else => null,
    };
}

const TestClock = struct {
    value: u64 = 1,
    fn interface(self: *TestClock) Clock {
        return .{ .ptr = self, .now_fn = now };
    }
    fn now(ptr: *anyopaque) u64 {
        return (@as(*TestClock, @ptrCast(@alignCast(ptr)))).value;
    }
};

const TestRawSink = struct {
    calls: u64 = 0,
    fn interface(self: *TestRawSink) @import("okx_public_market.zig").RawSink {
        return .{ .ptr = self, .append_fn = append };
    }
    fn append(ptr: *anyopaque, _: @import("okx_public_market.zig").RawIngressRecord, _: []const u8) @import("okx_public_market.zig").RawSinkError!u64 {
        const self: *TestRawSink = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return self.calls;
    }
};

const TestTransport = struct {
    calls: u64 = 0,
    outcome: order.TransportOutcome = .response,
    response: ?[]const u8 = "{\"code\":\"0\",\"data\":[{\"sCode\":\"0\",\"ordId\":\"1\"}]}",
    fn interface(self: *TestTransport) live.Transport {
        return .{ .ptr = self, .submit_fn = submit };
    }
    fn submit(ptr: *anyopaque, _: []const u8, _: []const u8) live.TransportResult {
        const self: *TestTransport = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return .{ .outcome = self.outcome, .response = self.response, .source_session = 5, .times = .{ .receive_time_utc_ns = 2, .monotonic_time_ns = 3, .wall_time_utc_ns = 4 } };
    }
};

fn qualification() live.Qualification {
    return .{ .explicit_demo_live = true, .endpoint_is_demo = true, .simulated_header = true, .credentials_loaded = true, .clock_healthy = true, .account_qualified = true, .reconciliation_stable = true, .no_unknown_orders = true, .cleanup_armed = true };
}

fn testProfile() order.CapabilityProfile {
    return .{ .version = 7, .rules_version = 8, .config_version = 9, .gateway_session = 6, .qualification = .demo_qualified, .batch_max = 4, .place_limit = .{ .requests = 4, .window_ns = 100 }, .place_batch_limit = .{ .requests = 4, .window_ns = 100 }, .amend_limit = .{ .requests = 4, .window_ns = 100 }, .amend_batch_limit = .{ .requests = 4, .window_ns = 100 }, .cancel_limit = .{ .requests = 4, .window_ns = 100 }, .cancel_batch_limit = .{ .requests = 4, .window_ns = 100 }, .subaccount_place_amend_limit = .{ .requests = 4, .window_ns = 100 }, .limit = true, .protected_market_ioc = true, .ioc = true, .fok = true, .native_amend = true, .native_post_only = true, .swap_venue_reduce_only = true };
}

fn testRules() Rules {
    return .{ .spot = .{ .identity = btc_usdt_spot, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 4 } }, .swap = .{ .identity = btc_usdt_swap, .tick_size = .{ .coefficient = 1, .scale = 1 }, .lot_size = .{ .coefficient = 1, .scale = 2 } } };
}

fn testCommand(identity: u128) !canonical.OrderCommand {
    return .{ .identity = identity, .exchange_account = 2, .instrument = btc_usdt_spot, .client_order_id = try canonical.ClientOrderId.init("OKX15A"), .capability_version = 7, .rules_version = 8, .config_version = 9, .adapter_session = 6, .dispatch_deadline_monotonic_ns = 10, .quantity = .{ .instrument = btc_usdt_spot, .rules_version = 8, .lots = 1 }, .limit_price = .{ .instrument = btc_usdt_spot, .rules_version = 8, .ticks = 500_000 } };
}

fn startTest(adapter: venue.VenueAdapter) !void {
    try adapter.start(.{ .venue = 1, .asset_definitions = try contract.activatedTestAssets(), .environment = .demo, .exchange_account = 2, .adapter_session = 6, .request_capacity = 4, .output_capacity = 4 });
}

fn privateEnvelope(sequence: u64, identity: u8) private.EventEnvelope {
    return .{
        .source_time_utc_ns = 1_800_000_000_000_000_000,
        .receive_time_utc_ns = 1_800_000_000_000_000_001,
        .monotonic_time_ns = sequence,
        .wall_time_utc_ns = 1_800_000_000_000_000_002,
        .raw_evidence = .{ .stream_sequence = sequence, .sha256 = @splat(identity) },
        .source_fact_identity = @splat(identity),
    };
}

const private_test_times: private.Times = .{
    .receive_time_utc_ns = 1_800_000_000_000_000_001,
    .monotonic_time_ns = 10_000_001,
    .wall_time_utc_ns = 1_800_000_000_000_000_002,
};

fn ingestOkxBootstrapRound(implementation: *OkxVenueAdapter) !void {
    const sources = [_]private.IngressSource{ .rest_account_config, .rest_leverage, .rest_balance, .rest_positions, .rest_orders_pending, .rest_orders_history_spot, .rest_orders_history_swap, .rest_fills_history_spot, .rest_fills_history_swap };
    const frames = [_][]const u8{
        \\{"code":"0","data":[{"acctLv":"2","posMode":"net_mode","ctIsoMode":"automatic","autoLoan":false,"enableSpotBorrow":false,"perm":"read_only,trade"}]}
        ,
        \\{"code":"0","data":[{"instId":"BTC-USDT-SWAP","mgnMode":"isolated","posSide":"net","lever":"3"}]}
        ,
        \\{"code":"0","data":[{"uTime":"1800000000000","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"25","details":[{"ccy":"USDT","cashBal":"25","availBal":"25","eq":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
        ,
        \\{"code":"0","data":[]}
        ,
        \\{"code":"0","data":[]}
        ,
        \\{"code":"0","data":[]}
        ,
        \\{"code":"0","data":[]}
        ,
        \\{"code":"0","data":[]}
        ,
        \\{"code":"0","data":[]}
    };
    for (sources, frames) |source, frame| {
        const batch = try implementation.ingestPrivateRest(private_test_times, source, .{ .final = true }, frame);
        try std.testing.expect(batch.rejection == null);
        try std.testing.expect(batch.buffered);
    }
}

test "OKX adapter releases buffered private bootstrap only after stable REST scope" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var reconciler: private.Reconciler = .{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try startTest(adapter);
    try implementation.beginPrivateSession();
    const ws_frames = [_][]const u8{
        \\{"event":"subscribe","arg":{"channel":"orders","instType":"ANY"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"account"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"positions","instType":"ANY"}}
        ,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000000","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"25","details":[{"ccy":"USDT","cashBal":"25","availBal":"25","eq":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
        ,
        \\{"arg":{"channel":"positions"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[]}
    };
    for (ws_frames) |frame| try std.testing.expect((try implementation.ingestPrivateWs(private_test_times, frame)).rejection == null);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 6 } }));
    _ = (try adapter.tryDrain()).?;
    try ingestOkxBootstrapRound(&implementation);
    try std.testing.expect((try adapter.tryDrain()) == null);
    try ingestOkxBootstrapRound(&implementation);
    const output = (try adapter.tryDrain()).?;
    var bootstrap_index: ?usize = null;
    var observed_index: ?usize = null;
    var complete = false;
    for (output.slice(), 0..) |record, index| {
        try std.testing.expectEqual(@intFromEnum(canonical.eventType(record.event)), record.envelope.event_type);
        switch (record.event) {
            .account_bootstrap_snapshot => bootstrap_index = index,
            .account_observed => {
                if (observed_index == null) observed_index = index;
            },
            .account_reconciliation_result => |result| complete = result.complete,
            else => {},
        }
    }
    try std.testing.expect(bootstrap_index != null);
    try std.testing.expect(observed_index != null and bootstrap_index.? < observed_index.?);
    try std.testing.expect(complete);
    var projection = account_projection.AccountProjection{};
    for (output.slice()) |record| try projection.apply(record.event);
    try std.testing.expect(projection.valid);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "OKX adapter releases ready private WS facts through the canonical seam" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var reconciler: private.Reconciler = .{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try startTest(adapter);
    try implementation.beginPrivateSession();
    const subscriptions = [_][]const u8{
        \\{"event":"subscribe","arg":{"channel":"orders","instType":"ANY"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"account"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"positions","instType":"ANY"}}
        ,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000000","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"25","details":[{"ccy":"USDT","cashBal":"25","availBal":"25","eq":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
        ,
        \\{"arg":{"channel":"positions"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[]}
    };
    for (subscriptions) |frame| try std.testing.expect((try implementation.ingestPrivateWs(private_test_times, frame)).rejection == null);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 6 } }));
    _ = (try adapter.tryDrain()).?;
    try ingestOkxBootstrapRound(&implementation);
    _ = try adapter.tryDrain();
    try ingestOkxBootstrapRound(&implementation);
    _ = (try adapter.tryDrain()).?;
    try std.testing.expect(reconciler.readiness().reconciliation_ready);

    var command = try testCommand(16);
    command.client_order_id = try canonical.ClientOrderId.init("RWN16");
    try implementation.rememberOrder(command);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_reconciliation = .{ .identity = 123, .exchange_account = 2, .order = 16 } }));
    _ = (try adapter.tryDrain()).?; // ReconciliationStarted; the private report arrives afterward.
    const venue_client_order_id = command.client_order_id;
    var order_frame: [768]u8 = undefined;
    const filled_order = try std.fmt.bufPrint(&order_frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0001","px":"50000","accFillSz":"0.0001","avgPx":"50000","uTime":"1800000000100","tradeId":"2001","fillSz":"0.0001","fillPx":"50000","fillFee":"-0.000001","fillFeeCcy":"USDT","fillTime":"1800000000100","execType":"T"}}]}}
    , .{venue_client_order_id.slice()});
    const order_batch = try implementation.ingestPrivateWs(private_test_times, filled_order);
    try std.testing.expectEqual(@as(u8, 0), order_batch.event_count);
    const account_batch = try implementation.ingestPrivateWs(private_test_times,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000101","totalEq":"20","adjEq":"20","imr":"0","mmr":"0","mgnRatio":"","isoEq":"20","details":[{"ccy":"USDT","cashBal":"20","availBal":"20","eq":"20","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    );
    try std.testing.expectEqual(@as(u8, 0), account_batch.event_count);
    try std.testing.expectError(error.OutputPending, adapter.stop(.{ .monotonic_ns = 1 }));
    const output = (try adapter.tryDrain()).?;
    var saw_report = false;
    var saw_fill = false;
    var saw_account = false;
    for (output.slice()) |record| switch (record.event) {
        .execution_report => saw_report = true,
        .fill => saw_fill = true,
        .account_observed => saw_account = true,
        else => {},
    };
    try std.testing.expect(saw_report);
    try std.testing.expect(saw_fill);
    try std.testing.expect(saw_account);
    const reconciled = (try adapter.tryDrain()) orelse return error.MissingOrderReconciliation;
    var found = false;
    for (reconciled.slice()) |record| if (record.event == .order_reconciliation_result) {
        const result = record.event.order_reconciliation_result;
        try std.testing.expectEqual(canonical.ReconciliationStatus.found_terminal, result.status);
        try std.testing.expectEqual(@as(canonical.OrderIdentity, 16), result.evidence.?.scope.order);
        try std.testing.expect(!std.mem.eql(u8, &result.evidence.?.source.digest, &@as([32]u8, @splat(0))));
        found = true;
    };
    try std.testing.expect(found);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 100, .exchange_account = 2, .expected_session = 6 } }));
    _ = (try adapter.tryDrain()).?;
    try ingestOkxBootstrapRound(&implementation);
    while (try adapter.tryDrain()) |_| {}
    try ingestOkxBootstrapRound(&implementation);
    while (try adapter.tryDrain()) |_| {}
    try std.testing.expect(reconciler.readiness().reconciliation_ready);
    try std.testing.expect(implementation.pending_account_reconciliation == null);
    _ = try implementation.instrument_definitions.register(.{ .instrument = btc_usdt_swap, .venue = 1, .product = .isolated_linear_usdt, .rules = .{ .version = 8, .instrument_identity = btc_usdt_swap, .quantity_denominator = 10000, .reservation_model = .leveraged, .venue = 1, .settlement_asset = usdt }, .margin = .{ .version = 1 } });
    const native_positions =
        \\{"arg":{"channel":"positions"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"posId":"55","instId":"BTC-USDT-SWAP","mgnMode":"isolated","posSide":"net","pos":"1","margin":"1.000001","upl":"0.000001","ccy":"USDT","uTime":"1800000000300"}]}
    ;
    try std.testing.expect((try implementation.ingestPrivateWs(private_test_times, native_positions)).rejection == null);
    const position_output = (try adapter.tryDrain()).?;
    const native_position = position_output.slice()[0].event.account_observed.value.position.value;
    try std.testing.expectEqual(@as(i128, 1_000_001), native_position.margin.?.atoms);
    try std.testing.expectEqual(@as(i128, 1), native_position.unrealized_pnl.?.atoms);
    try std.testing.expectEqual(usdt, native_position.margin.?.asset);
    try std.testing.expect((try implementation.ingestPrivateWs(private_test_times,
        \\{"arg":{"channel":"positions"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"posId":"55","instId":"BTC-USDT-SWAP","mgnMode":"isolated","posSide":"net","pos":"1","margin":"1.000001","upl":"0.000001","uTime":"1800000000301"}]}
    )).rejection == null);
    const failure = (try adapter.tryDrain()).?;
    var missing_asset = false;
    for (failure.slice()) |record| if (record.event == .economic_fault) {
        try std.testing.expectEqual(canonical.EconomicFaultReason.missing_asset, record.event.economic_fault.reason);
        missing_asset = true;
    };
    try std.testing.expect(missing_asset);
    try std.testing.expect(implementation.private_failed);
}

test "OKX private facts normalize fee signs into canonical execution fill and account facts" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    const adapter = implementation.adapter();
    try startTest(adapter);
    var command = try testCommand(16);
    command.client_order_id = try canonical.ClientOrderId.init("RWN-16");
    try implementation.rememberOrder(command);
    const venue_client_order_id = command.client_order_id;

    var output: canonical.AdapterOutputBatch = .{};
    try implementation.translatePrivate(&output, .{ .envelope = privateEnvelope(1, 1), .payload = .{ .execution_report = .{
        .venue_order_id = @enumFromInt(1001),
        .client_order_id = try private.ClientOrderId.init(venue_client_order_id.slice()),
        .instrument = .btc_usdt_spot,
        .side = .buy,
        .order_type = .limit,
        .status = .partially_filled,
        .margin_mode = .isolated,
        .position_side = .net,
        .venue_reduce_only = true,
        .leverage = try private.Decimal.parse("3"),
        .quantity = try private.Decimal.parse("0.0002"),
        .limit_price = try private.Decimal.parse("50000"),
        .cumulative_filled_quantity = try private.Decimal.parse("0.0001"),
        .average_fill_price = try private.Decimal.parse("50000"),
        .request_id = try private.FixedText(32).init("request"),
        .last_trade_id = @enumFromInt(2001),
        .venue_update_time_utc_ns = 1,
        .owned_by_ringwin = true,
    } } }, false);
    try implementation.translatePrivate(&output, .{ .envelope = privateEnvelope(2, 2), .payload = .{ .fill = .{
        .venue_trade_id = @enumFromInt(2001),
        .venue_bill_id = @enumFromInt(3001),
        .venue_order_id = @enumFromInt(1001),
        .client_order_id = try private.ClientOrderId.init(venue_client_order_id.slice()),
        .instrument = .btc_usdt_spot,
        .side = .buy,
        .quantity = try private.Decimal.parse("0.0001"),
        .price = try private.Decimal.parse("50000"),
        .fee = try private.Decimal.parse("-0.00000001"),
        .fee_asset = try private.AssetCode.init("BTC"),
        .rebate = try private.Decimal.parse("0.01"),
        .rebate_asset = try private.AssetCode.init("USDT"),
        .realized_pnl = try private.Decimal.parse("0"),
        .liquidity = .maker,
        .venue_fill_time_utc_ns = 1,
        .owned_by_ringwin = true,
    } } }, false);
    try std.testing.expectEqual(@as(u8, 2), output.len);
    try std.testing.expectEqualStrings("RWN-16", output.events[0].event.execution_report.client_order_id.slice());
    try std.testing.expectEqual(canonical.ExecutionReportStatus.partially_filled, output.events[0].event.execution_report.status);
    try std.testing.expectEqual(@as(i128, 1), output.events[0].event.execution_report.cumulative_quantity.lots);
    try std.testing.expect(output.events[0].event.execution_report.venue_reduce_only.?);
    try std.testing.expect(output.events[0].event.execution_report.margin_mode_isolated.?);
    try std.testing.expectEqual(@as(i128, 3), output.events[0].event.execution_report.leverage.?.coefficient);
    try std.testing.expectEqual(btc, output.events[1].event.fill.fee.?.asset);
    try std.testing.expectEqual(@as(i128, 1), output.events[1].event.fill.fee.?.atoms);
    try std.testing.expectEqual(usdt, output.events[1].event.fill.rebate.?.asset);

    var balance: private.ExchangeBalanceSnapshot = .{ .scope = .full_rest, .venue_update_time_utc_ns = 1 };
    balance.balances[0] = .{ .asset = try private.AssetCode.init("USDT"), .cash_balance = try private.Decimal.parse("25"), .available_balance = try private.Decimal.parse("24"), .equity = try private.Decimal.parse("25"), .frozen_balance = try private.Decimal.parse("1"), .liability = try private.Decimal.parse("0.1"), .isolated_liability = try private.Decimal.parse("0.2"), .cross_liability = try private.Decimal.parse("0.3") };
    balance.balance_count = 1;
    var positions: private.ExchangePositionSnapshot = undefined;
    positions.scope = .full_rest;
    positions.position_count = 0;
    positions.includes_zero_positions = true;
    const margin: private.ExchangeMarginSnapshot = .{ .scope = .full_rest, .venue_update_time_utc_ns = 1, .total_equity_usd = try private.Decimal.parse("25"), .adjusted_equity_usd = try private.Decimal.parse("25"), .initial_margin_usd = try private.Decimal.parse("1"), .maintenance_margin_usd = try private.Decimal.parse("0.5"), .margin_ratio = try private.Decimal.parse("0.1"), .isolated_equity_usd = try private.Decimal.parse("25") };
    try implementation.translatePrivate(&output, .{ .envelope = privateEnvelope(3, 3), .payload = .{ .exchange_balance_snapshot = balance } }, false);
    try implementation.translatePrivate(&output, .{ .envelope = privateEnvelope(4, 4), .payload = .{ .exchange_position_snapshot = positions } }, false);
    try implementation.translatePrivate(&output, .{ .envelope = privateEnvelope(5, 5), .payload = .{ .exchange_margin_snapshot = margin } }, false);
    try std.testing.expectEqual(@as(u8, 1), output.events[2].event.account_bootstrap_snapshot.balance_count);
    try std.testing.expectEqual(@as(i128, 25_000_000), output.events[2].event.account_bootstrap_snapshot.balances[0].total.atoms);
    try std.testing.expectEqual(@as(i128, 100_000), output.events[2].event.account_bootstrap_snapshot.balances[0].liability.?.atoms);
    try std.testing.expectEqual(@as(i128, 200_000), output.events[2].event.account_bootstrap_snapshot.balances[0].isolated_liability.?.atoms);
    try std.testing.expectEqual(@as(i128, 300_000), output.events[2].event.account_bootstrap_snapshot.balances[0].cross_liability.?.atoms);
    try std.testing.expect(output.events[2].event.account_bootstrap_snapshot.margins[0].amount == null);
    try std.testing.expectEqual(@as(i128, 1), output.events[2].event.account_bootstrap_snapshot.margins[0].usd_valuation.?.initial_margin.?.coefficient);
    try std.testing.expectEqual(@as(i128, 5), output.events[2].event.account_bootstrap_snapshot.margins[0].usd_valuation.?.maintenance_margin.?.coefficient);
    try std.testing.expectEqual(@as(i128, 25), output.events[2].event.account_bootstrap_snapshot.margins[0].usd_valuation.?.isolated_equity.?.coefficient);
    var observed_positions: private.ExchangePositionSnapshot = undefined;
    observed_positions.scope = .ws_reported;
    observed_positions.position_count = 1;
    observed_positions.includes_zero_positions = true;
    observed_positions.positions[0] = .{ .venue_position_id = @enumFromInt(1), .instrument = .btc_usdt_swap, .margin_mode = .isolated, .position_side = .net, .quantity = try private.Decimal.parse("1"), .average_price = try private.Decimal.parse("50000"), .mark_price = try private.Decimal.parse("50001"), .liquidation_price = try private.Decimal.parse("40000"), .margin = try private.Decimal.parse("2"), .leverage = try private.Decimal.parse("3"), .unrealized_pnl = try private.Decimal.parse("1"), .venue_update_time_utc_ns = 1 };
    observed_positions.positions[0].currency = try private.AssetCode.init("USDT");
    _ = try implementation.instrument_definitions.register(.{ .instrument = btc_usdt_swap, .venue = 1, .product = .isolated_linear_usdt, .rules = .{ .version = 8, .instrument_identity = btc_usdt_swap, .quantity_denominator = 10000, .reservation_model = .leveraged, .venue = 1, .settlement_asset = usdt }, .margin = .{ .version = 1 } });
    try implementation.translatePrivate(&output, .{ .envelope = privateEnvelope(6, 6), .payload = .{ .exchange_position_snapshot = observed_positions } }, false);
    const observed = output.events[3].event.account_observed.value.position;
    try std.testing.expectEqual(@as(i128, 500_010), observed.value.mark_price.?.ticks);
    try std.testing.expectEqual(@as(i128, 2_000_000), observed.value.margin.?.atoms);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "OKX adapter preserves fail-closed dispatch rejection causes" {
    try std.testing.expectEqual(canonical.CanonicalRejectReason.capability_unsupported, dispatchErrorReason(error.SideEffectsDisabled).?);
    try std.testing.expectEqual(canonical.CanonicalRejectReason.venue_unavailable, dispatchErrorReason(error.DemoNotQualified).?);
    try std.testing.expectEqual(canonical.CanonicalRejectReason.unsupported_value, dispatchErrorReason(error.NotionalLimitExceeded).?);
    try std.testing.expectEqual(canonical.CanonicalRejectReason.unsupported_instrument, dispatchErrorReason(error.InstrumentNotAllowed).?);
    try std.testing.expect(dispatchErrorReason(error.WebSocketTransport) == null);
}

test "OKX adapter resumes canonical event sequence before start" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    try implementation.resumeAfter(41);
    try std.testing.expectEqual(@as(u64, 42), implementation.next_event_sequence);
    const adapter = implementation.adapter();
    try startTest(adapter);
    try std.testing.expectError(error.InvalidState, implementation.resumeAfter(42));
}

test "OKX drained replay handoff preserves committed floor and fresh fault evidence" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .replay, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var reconciler: private.Reconciler = .{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try startTest(adapter);
    try implementation.beginPrivateSession();
    const times: private.Times = .{ .receive_time_utc_ns = 1, .monotonic_time_ns = 2, .wall_time_utc_ns = 3 };
    const first = try implementation.ingestPrivateWs(times, "{");
    try std.testing.expectError(error.InvalidState, implementation.resumeAfter(41));
    const initial = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u64, 1), initial.events[0].envelope.identity.sequence);
    try implementation.resumeAfter(41);
    try implementation.resumeAfter(10);
    chain.mode = .demo_live;
    const second = try implementation.ingestPrivateWs(times, "}");
    const fresh = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u64, 42), fresh.events[0].envelope.identity.sequence);
    try std.testing.expect(fresh.events[0].event == .economic_fault);
    try std.testing.expectEqual(second.raw_evidence.stream_sequence, fresh.events[0].envelope.raw_evidence.sequence);
    try std.testing.expectEqualSlices(u8, &second.raw_evidence.sha256, &fresh.events[0].envelope.raw_evidence.digest);
    try std.testing.expect(second.raw_evidence.stream_sequence > first.raw_evidence.stream_sequence);
    try std.testing.expectEqual(@as(u64, 1), chain.next_attempt_id);
}

test "OKX reconciliation result states are deterministic and bounded" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var reconciler: private.Reconciler = .{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try startTest(adapter);
    try implementation.rememberOrder(try testCommand(16));

    const requests = [_]canonical.ReconciliationStatus{ .found_live, .found_terminal };
    for (requests, 0..) |expected, index| {
        const identity: u128 = index + 1;
        try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_reconciliation = .{ .identity = identity, .exchange_account = 2, .order = 16, .venue_order = try canonical.VenueOrderRef.init(1, "1001") } }));
        _ = (try adapter.tryDrain()).?;
        implementation.observeOrder(@enumFromInt(1001), 16, if (expected == .found_live) .live else .filled, .{ .instrument = btc_usdt_spot, .rules_version = 8, .lots = if (expected == .found_live) 0 else 1 }, privateEnvelope(@intCast(index + 1), 1));
        var output: canonical.AdapterOutputBatch = .{};
        implementation.finishPrivateBatch(&output);
        try std.testing.expectEqual(@as(u8, 1), output.len);
        try std.testing.expectEqual(expected, output.events[0].event.order_reconciliation_result.status);
        try std.testing.expect(output.events[0].event.order_reconciliation_result.complete);
        try std.testing.expectEqual(@as(i128, if (expected == .found_live) 0 else 1), output.events[0].event.order_reconciliation_result.cumulative_quantity.?.lots);
    }

    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_reconciliation = .{ .identity = 40, .exchange_account = 2, .order = 16, .venue_order = try canonical.VenueOrderRef.init(1, "1001") } }));
    _ = (try adapter.tryDrain()).?;
    var incomplete: canonical.AdapterOutputBatch = .{};
    implementation.finishPrivateBatch(&incomplete);
    try std.testing.expectEqual(canonical.ReconciliationStatus.unresolved, incomplete.events[0].event.order_reconciliation_result.status);
    try std.testing.expect(!incomplete.events[0].event.order_reconciliation_result.complete);

    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_reconciliation = .{ .identity = 4, .exchange_account = 2, .order = 16 } }));
    _ = (try adapter.tryDrain()).?;
    implementation.finishReconciliation(false);
    const unresolved = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.ReconciliationStatus.unresolved, unresolved.events[0].event.order_reconciliation_result.status);
    try std.testing.expect(!unresolved.events[0].event.order_reconciliation_result.complete);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "OKX client order ID is stable per durable namespace account and order" {
    var marker: u8 = 0;
    const namespace: [16]u8 = @splat(7);
    const requested = try canonical.ClientOrderId.init("RWN-1");
    const first = try OkxVenueAdapter.prepareClientOrderId(&marker, namespace, 2, 1, requested);
    try std.testing.expectEqual(@as(usize, 32), first.slice().len);
    try std.testing.expect(std.mem.startsWith(u8, first.slice(), "RWN1"));
    try std.testing.expect(std.meta.eql(first, try OkxVenueAdapter.prepareClientOrderId(&marker, namespace, 2, 1, requested)));
    var next_namespace = namespace;
    next_namespace[0] = 8;
    try std.testing.expect(!std.meta.eql(first, try OkxVenueAdapter.prepareClientOrderId(&marker, next_namespace, 2, 1, requested)));
    try std.testing.expect(!std.meta.eql(first, try OkxVenueAdapter.prepareClientOrderId(&marker, namespace, 3, 1, requested)));
    try std.testing.expect(!std.meta.eql(first, try OkxVenueAdapter.prepareClientOrderId(&marker, namespace, 2, 2, requested)));
}

test "OKX venue adapter translates canonical commands and itemizes a batch" {
    var raw = TestRawSink{};
    var transport = TestTransport{ .response = "{\"code\":\"0\",\"data\":[{\"sCode\":\"0\",\"ordId\":\"1\"},{\"sCode\":\"0\",\"ordId\":\"2\"}]}" };
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    const adapter = implementation.adapter();
    try startTest(adapter);
    var batch = canonical.OrderCommandBatch{};
    try batch.append(try testCommand(100));
    try batch.append(try testCommand(101));
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_batch = batch }));
    const output = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(@as(u8, 2), output.len);
    try std.testing.expectEqual(canonical.DispatchState.submitted, output.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(@as(canonical.OrderIdentity, 100), output.events[0].event.order_dispatch_result.command);
    try std.testing.expectEqual(@as(canonical.OrderIdentity, 101), output.events[1].event.order_dispatch_result.command);
    try std.testing.expectEqual(@as(u64, 1), transport.calls);
    try std.testing.expectEqual(@as(u64, 1), raw.calls);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "OKX adapter preserves canonical order semantics at the execution seam" {
    var raw: TestRawSink = .{};
    var transport: TestTransport = .{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock: TestClock = .{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    try startTest(implementation.adapter());

    var market_command = try testCommand(1);
    market_command.order_type = .market;
    market_command.time_in_force = .immediate_or_cancel;
    market_command.limit_price = null;
    market_command.market_protection_price = .{ .instrument = btc_usdt_spot, .rules_version = 8, .ticks = 500_000 };
    market_command.portfolio_reduce_only = true;
    market_command.venue_reduce_only = true;
    const translated = try implementation.translate(market_command, 1);
    switch (translated.command.payload) {
        .place => |place| {
            try std.testing.expectEqual(order.OrderKind.market, place.kind);
            try std.testing.expect(place.limit_price == null);
            try std.testing.expect(place.market_protection_price != null);
            try std.testing.expect(place.portfolio_reduce_only);
            try std.testing.expect(place.venue_reduce_only);
        },
        else => return error.ExpectedPlace,
    }

    market_command.time_in_force = .good_til_canceled;
    try std.testing.expectError(error.UnsupportedValue, implementation.translate(market_command, 2));

    var limit_ioc = try testCommand(3);
    limit_ioc.time_in_force = .immediate_or_cancel;
    const translated_ioc = try implementation.translate(limit_ioc, 3);
    try std.testing.expectEqual(order.OrderKind.limit_ioc, translated_ioc.command.payload.place.kind);
}

test "OKX venue adapter preserves not-sent and unknown without retrying transport" {
    var raw = TestRawSink{};
    var transport = TestTransport{ .outcome = .write_or_response_uncertain, .response = null };
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    const adapter = implementation.adapter();
    try startTest(adapter);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = try testCommand(200) }));
    const unknown = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.DispatchState.unknown, unknown.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(@as(u64, 1), transport.calls);

    var expired = try testCommand(201);
    expired.dispatch_deadline_monotonic_ns = 1;
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = expired }));
    const not_sent = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.DispatchState.not_sent, not_sent.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(canonical.CanonicalRejectReason.deadline_expired, not_sent.events[0].event.order_dispatch_result.reason.?);
    try std.testing.expectEqual(@as(u64, 1), transport.calls);

    var stale = try testCommand(202);
    stale.rules_version = 99;
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = stale }));
    const stale_result = (try adapter.tryDrain()).?;
    try std.testing.expectEqual(canonical.CanonicalRejectReason.stale_version, stale_result.events[0].event.order_dispatch_result.reason.?);
    try std.testing.expectEqual(@as(u64, 1), transport.calls);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "replay and dry-run OKX adapters cannot call transport" {
    for ([_]live.RunMode{ .replay, .demo_dry_run }) |mode| {
        var raw = TestRawSink{};
        var transport = TestTransport{};
        var chain: live.Chain = .{ .mode = mode, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
        var clock = TestClock{};
        var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
        const adapter = implementation.adapter();
        try startTest(adapter);
        try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = try testCommand(300) }));
        const output = (try adapter.tryDrain()).?;
        try std.testing.expectEqual(canonical.DispatchState.not_sent, output.events[0].event.order_dispatch_result.state);
        try std.testing.expectEqual(@as(u64, 0), transport.calls);
        try adapter.stop(.{ .monotonic_ns = 1 });
    }

    var raw = TestRawSink{};
    var transport = TestTransport{};
    var unavailable = qualification();
    unavailable.cleanup_armed = false;
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = unavailable, .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    const adapter = implementation.adapter();
    try startTest(adapter);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = try testCommand(301) }));
    try std.testing.expectEqual(canonical.DispatchState.not_sent, (try adapter.tryDrain()).?.events[0].event.order_dispatch_result.state);
    try std.testing.expectEqual(@as(u64, 0), transport.calls);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

test "OKX adapter reuses the shared VenueAdapter contract" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    try contract.exerciseWith(implementation.adapter(), .{ .venue = 1, .asset_definitions = try contract.activatedTestAssets(), .environment = .demo, .exchange_account = 2, .adapter_session = 6, .request_capacity = 1, .output_capacity = 1 }, .{ .order_command = try testCommand(400) });
}

test "amend and cancel use the canonical VenueOrderRef without leaking an OKX order identity" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    const adapter = implementation.adapter();
    try startTest(adapter);
    var amend = try testCommand(500);
    amend.operation = .amend;
    amend.venue_order = try canonical.VenueOrderRef.init(1, "21");
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = amend }));
    try std.testing.expectEqual(canonical.DispatchState.submitted, (try adapter.tryDrain()).?.events[0].event.order_dispatch_result.state);

    var cancel = try testCommand(501);
    cancel.operation = .cancel;
    cancel.venue_order = try canonical.VenueOrderRef.init(1, "21");
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_command = cancel }));
    try std.testing.expectEqual(canonical.DispatchState.submitted, (try adapter.tryDrain()).?.events[0].event.order_dispatch_result.state);
    try adapter.stop(.{ .monotonic_ns = 1 });
}

fn economicReason(err: anyerror) canonical.EconomicFaultReason {
    if (canonical.Decimal.faultReason(err)) |reason| return reason;
    return switch (err) {
        error.Overflow => .overflow,
        error.UnsupportedAsset => .unknown_asset,
        error.MissingAsset => .missing_asset,
        error.MissingBalanceTotal, error.MissingBalanceAvailable, error.MissingBalanceHeld, error.MissingMarginEquity => .missing_amount,
        else => .invalid_economic_fact,
    };
}

test "OKX activated precision converts private fills without trading authority" {
    var raw = TestRawSink{};
    var transport = TestTransport{};
    var chain: live.Chain = .{ .mode = .demo_live, .qualification = qualification(), .raw_sink = raw.interface(), .transport = transport.interface() };
    var clock = TestClock{};
    var reconciler: private.Reconciler = .{};
    var implementation = OkxVenueAdapter.init(std.testing.allocator, &chain, clock.interface(), testProfile(), testRules());
    implementation.attachPrivateReconciler(&reconciler);
    const adapter = implementation.adapter();
    try adapter.start(.{ .asset_definitions = try contract.activatedTestAssetsWithScales(12, 9), .venue = 1, .environment = .demo, .exchange_account = 2, .adapter_session = 6, .request_capacity = 4, .output_capacity = 4 });
    try implementation.beginPrivateSession();
    const subscriptions = [_][]const u8{
        \\{"event":"subscribe","arg":{"channel":"orders","instType":"ANY"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"account"}}
        ,
        \\{"event":"subscribe","arg":{"channel":"positions","instType":"ANY"}}
        ,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000000","totalEq":"25","adjEq":"25","imr":"0","mmr":"0","mgnRatio":"","isoEq":"25","details":[{"ccy":"USDT","cashBal":"25","availBal":"25","eq":"25","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
        ,
        \\{"arg":{"channel":"positions"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[]}
    };
    for (subscriptions) |frame| try std.testing.expect((try implementation.ingestPrivateWs(private_test_times, frame)).rejection == null);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .account_reconciliation = .{ .identity = 99, .exchange_account = 2, .expected_session = 6 } }));
    _ = (try adapter.tryDrain()).?;
    try ingestOkxBootstrapRound(&implementation);
    _ = try adapter.tryDrain();
    try ingestOkxBootstrapRound(&implementation);
    _ = (try adapter.tryDrain()).?;
    try std.testing.expect(reconciler.readiness().reconciliation_ready);

    var command = try testCommand(16);
    command.client_order_id = try canonical.ClientOrderId.init("RWN16");
    try implementation.rememberOrder(command);
    try std.testing.expectEqual(venue.SendResult.accepted, try adapter.trySend(.{ .order_reconciliation = .{ .identity = 123, .exchange_account = 2, .order = 16 } }));
    _ = (try adapter.tryDrain()).?; // ReconciliationStarted; the private report arrives afterward.
    const venue_client_order_id = command.client_order_id;
    var order_frame: [768]u8 = undefined;
    const filled_order = try std.fmt.bufPrint(&order_frame,
        \\{{"arg":{{"channel":"orders"}},"data":[{{"instId":"BTC-USDT","ordId":"1001","clOrdId":"{s}","side":"buy","ordType":"limit","state":"filled","tdMode":"cash","posSide":"net","reduceOnly":"false","sz":"0.0001","px":"50000","accFillSz":"0.0001","avgPx":"50000","uTime":"1800000000100","tradeId":"2001","fillSz":"0.0001","fillPx":"50000","fillFee":"-0.004198632165","fillFeeCcy":"USDT","fillTime":"1800000000100","execType":"T"}}]}}
    , .{venue_client_order_id.slice()});
    const order_batch = try implementation.ingestPrivateWs(private_test_times, filled_order);
    try std.testing.expectEqual(@as(u8, 0), order_batch.event_count);
    const account_batch = try implementation.ingestPrivateWs(private_test_times,
        \\{"arg":{"channel":"account"},"eventType":"snapshot","curPage":1,"lastPage":true,"data":[{"uTime":"1800000000101","totalEq":"20","adjEq":"20","imr":"0","mmr":"0","mgnRatio":"","isoEq":"20","details":[{"ccy":"USDT","cashBal":"20","availBal":"20","eq":"20","frozenBal":"0","liab":"0","isoLiab":"0","crossLiab":"0"}]}]}
    );
    try std.testing.expectEqual(@as(u8, 0), account_batch.event_count);
    try std.testing.expectError(error.OutputPending, adapter.stop(.{ .monotonic_ns = 1 }));
    const output = (try adapter.tryDrain()).?;
    var fills: usize = 0;
    for (output.slice()) |record| if (record.event == .fill) {
        fills += 1;
        try std.testing.expectEqual(@as(i128, 4_198_632_165), record.event.fill.fee.?.atoms);
        try std.testing.expectEqual(@as(i128, 1), record.event.fill.quantity.lots);
    };
    try std.testing.expectEqual(@as(usize, 1), fills);
    try std.testing.expectEqual(venue.SendResult.backpressure, try adapter.trySend(.{ .order_command = command }));
    try std.testing.expectEqual(@as(u64, 0), transport.calls);
}
