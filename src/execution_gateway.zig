const canonical = @import("canonical_event.zig");
const oms = @import("oms.zig");
const venue = @import("venue_adapter.zig");
const std = @import("std");

pub const CapabilityProfile = struct {
    version: u64,
    rules_version: u64,
    config_version: u64,
    session: canonical.AdapterSessionIdentity,
    supports_place: bool = true,
    supports_post_only: bool = false,
    supports_market_protection: bool = false,
};
pub const LatchedSafetyGate = enum { open, latched };
pub const OpeningGate = enum { open, blocked };
pub const Route = struct { account: canonical.ExchangeAccountIdentity, adapter: venue.VenueAdapter, capability: CapabilityProfile, safety_gate: LatchedSafetyGate = .open };
pub const InstrumentOpeningGate = struct { instrument: canonical.InstrumentIdentity, state: OpeningGate = .open };
pub const OmsDispatchContext = struct {
    account: canonical.ExchangeAccountIdentity,
    capability_version: u64,
    rules_version: u64,
    config_version: u64,
    adapter_session: canonical.AdapterSessionIdentity,
    dispatch_deadline_monotonic_ns: u64,
};
pub const AuthorityFacts = struct {
    account: canonical.ExchangeAccountIdentity,
    effective_trading_authority: bool,
    reservation_identity: u64,
    reservation: canonical.AssetAmount,
    primary_lease_expires_at_monotonic_ns: u64,
    fencing_token: u64,
    exchange_position: canonical.InstrumentQuantity,
    authority_barrier: u64,
};
pub const DispatchProof = struct {
    context: OmsDispatchContext,
    command: oms.Command,
    fencing_token: u64,
    authority_barrier: u64,
    now_monotonic_ns: u64,
};
pub const max_routes = 4;
pub const max_adapter_batches_per_turn: u8 = 1;
const max_authority_records = max_routes * oms.max_commands;
const AccountAuthority = struct {
    effective_trading_authority: bool = false,
    primary_lease_expires_at_monotonic_ns: u64 = 0,
    fencing_token: u64 = 0,
    authority_barrier: u64 = 0,
};
const ReservationFact = struct {
    account: canonical.ExchangeAccountIdentity,
    identity: u64,
    amount: canonical.AssetAmount,
    barrier: u64,
};
const ExchangePositionFact = struct {
    account: canonical.ExchangeAccountIdentity,
    quantity: canonical.InstrumentQuantity,
    barrier: u64,
};
const AcceptedDispatch = struct {
    account: canonical.ExchangeAccountIdentity,
    command_id: u64,
    proof: DispatchProof,
};
pub const Gateway = struct {
    routes: [max_routes]Route = undefined,
    count: u8 = 0,
    instrument_gates: [max_routes]InstrumentOpeningGate = undefined,
    instrument_gate_count: u8 = 0,
    instrument_gate_capacity_exhausted: bool = false,
    account_authority: [max_routes]AccountAuthority = @splat(.{}),
    reservations: [max_authority_records]ReservationFact = undefined,
    reservation_count: u8 = 0,
    exchange_positions: [max_authority_records]ExchangePositionFact = undefined,
    exchange_position_count: u8 = 0,
    accepted_dispatches: [max_authority_records]AcceptedDispatch = undefined,
    accepted_dispatch_count: u8 = 0,
    send_attempt_count: u64 = 0,
    pub fn add(self: *Gateway, route: Route) !void {
        for (self.routes[0..self.count]) |existing|
            if (existing.account == route.account) return error.DuplicateAccountRoute;
        if (self.count == self.routes.len) return error.RouteCapacity;
        self.routes[self.count] = route;
        self.count += 1;
    }

    /// Replaces the latest account authority and upserts the command-scoped
    /// reservation and instrument position that the Gateway will re-read at send.
    pub fn observeAuthority(self: *Gateway, facts: AuthorityFacts) !void {
        const route_index = self.routeIndex(facts.account) orelse return error.UnknownAccount;
        if (facts.reservation_identity == 0 or facts.fencing_token == 0 or facts.authority_barrier == 0 or
            facts.exchange_position.instrument == 0 or facts.exchange_position.rules_version == 0)
            return error.InvalidAuthorityFacts;
        const current = self.account_authority[route_index];
        const next_authority: AccountAuthority = .{
            .effective_trading_authority = facts.effective_trading_authority,
            .primary_lease_expires_at_monotonic_ns = facts.primary_lease_expires_at_monotonic_ns,
            .fencing_token = facts.fencing_token,
            .authority_barrier = facts.authority_barrier,
        };
        if (facts.authority_barrier < current.authority_barrier or facts.fencing_token < current.fencing_token)
            return error.StaleAuthorityFacts;
        if (facts.authority_barrier == current.authority_barrier and current.authority_barrier != 0 and
            !std.meta.eql(current, next_authority))
            return error.ConflictingAuthorityFacts;

        const reservation_index = self.reservationIndex(facts.account, facts.reservation_identity);
        const position_index = self.exchangePositionIndex(facts.account, facts.exchange_position.instrument);
        if (reservation_index == null and self.reservation_count == self.reservations.len)
            return error.AuthorityCapacity;
        if (position_index == null and self.exchange_position_count == self.exchange_positions.len)
            return error.AuthorityCapacity;
        if (reservation_index) |index| {
            const known = self.reservations[index];
            if (facts.authority_barrier < known.barrier or
                (facts.authority_barrier == known.barrier and !std.meta.eql(known.amount, facts.reservation)))
                return error.ConflictingAuthorityFacts;
        }
        if (position_index) |index| {
            const known = self.exchange_positions[index];
            if (facts.authority_barrier < known.barrier or
                (facts.authority_barrier == known.barrier and !std.meta.eql(known.quantity, facts.exchange_position)))
                return error.ConflictingAuthorityFacts;
        }

        self.account_authority[route_index] = next_authority;
        if (reservation_index) |index| {
            self.reservations[index].amount = facts.reservation;
            self.reservations[index].barrier = facts.authority_barrier;
        } else {
            self.reservations[self.reservation_count] = .{ .account = facts.account, .identity = facts.reservation_identity, .amount = facts.reservation, .barrier = facts.authority_barrier };
            self.reservation_count += 1;
        }
        if (position_index) |index| {
            self.exchange_positions[index].quantity = facts.exchange_position;
            self.exchange_positions[index].barrier = facts.authority_barrier;
        } else {
            self.exchange_positions[self.exchange_position_count] = .{ .account = facts.account, .quantity = facts.exchange_position, .barrier = facts.authority_barrier };
            self.exchange_position_count += 1;
        }
    }

    /// Rehydrates a durable accepted dispatch during recovery. Replaying its
    /// proof returns the accepted result without crossing the adapter again.
    pub fn restoreAcceptedDispatch(self: *Gateway, proof: DispatchProof) !void {
        const account = proof.context.account;
        const command_id = proof.command.command_id;
        if (self.routeIndex(account) == null) return error.UnknownAccount;
        if (command_id == 0) return error.InvalidDispatchIdentity;
        if (self.acceptedDispatchIndex(account, command_id)) |index| {
            if (!std.meta.eql(self.accepted_dispatches[index].proof, proof)) return error.DispatchIdentityConflict;
            return;
        }
        if (self.accepted_dispatch_count == self.accepted_dispatches.len) return error.DispatchCapacity;
        self.accepted_dispatches[self.accepted_dispatch_count] = .{ .account = account, .command_id = command_id, .proof = proof };
        self.accepted_dispatch_count += 1;
    }
    fn sendUnprovedForContractTest(self: *Gateway, request: canonical.OrderCommand) !venue.SendResult {
        const route = self.routeFor(request.exchange_account) orelse return error.UnknownAccount;
        try self.validateOrder(route, request);
        return self.sendRequestForRoute(route, .{ .order_command = request });
    }

    /// Converts a qualified OMS outbox item once at the execution boundary.
    fn sendOms(self: *Gateway, context: OmsDispatchContext, command_value: oms.Command) !venue.SendResult {
        const route = self.routeFor(context.account) orelse return error.UnknownAccount;
        if (command_value.limit_price.rules_version != context.rules_version) return error.Rejected;
        const request: canonical.OrderCommand = .{
            .identity = command_value.command_id,
            .exchange_account = context.account,
            .instrument = command_value.instrument,
            .client_order_id = command_value.client_order_id,
            .capability_version = context.capability_version,
            .rules_version = context.rules_version,
            .config_version = context.config_version,
            .adapter_session = context.adapter_session,
            .dispatch_deadline_monotonic_ns = context.dispatch_deadline_monotonic_ns,
            .operation = switch (command_value.operation) {
                .place => .place,
                .amend => .amend,
                .cancel => .cancel,
            },
            .side = if (command_value.side == .buy) .buy else .sell,
            .revision = command_value.revision,
            .portfolio_reduce_only = command_value.portfolio_reduce_only,
            .venue_reduce_only = command_value.venue_reduce_only,
            .order_type = command_value.order_type,
            .time_in_force = command_value.time_in_force,
            .quantity = if (command_value.operation == .cancel) null else .{ .instrument = command_value.instrument, .rules_version = command_value.limit_price.rules_version, .lots = command_value.quantity },
            .limit_price = if (command_value.operation == .cancel or command_value.order_type == .market) null else command_value.limit_price,
            .market_protection_price = command_value.market_protection_price,
            // The simulated/core boundary knows zero fees explicitly. Venue
            // adapters must replace this with the authoritative charged fee.
            .fee_asset = command_value.reservation.asset,
            .fee_atoms = 0,
        };
        try self.validateOrder(route, request);
        return self.sendRequestForRoute(route, .{ .order_command = request });
    }

    /// The sole business-order boundary. Every mutable authority dependency is
    /// rechecked immediately before the VenueAdapter external effect.
    pub fn sendProof(self: *Gateway, proof: DispatchProof) !venue.SendResult {
        const command_value = proof.command;
        if (self.acceptedDispatchIndex(proof.context.account, command_value.command_id)) |index| {
            if (!std.meta.eql(self.accepted_dispatches[index].proof, proof)) return error.NotSent;
            return .accepted;
        }
        if (self.accepted_dispatch_count == self.accepted_dispatches.len) return error.NotSent;
        const route_index = self.routeIndex(proof.context.account) orelse return error.NotSent;
        const authority = self.account_authority[route_index];
        const reservation_index = self.reservationIndex(proof.context.account, command_value.reservation_identity) orelse return error.NotSent;
        const position_index = self.exchangePositionIndex(proof.context.account, command_value.instrument) orelse return error.NotSent;
        const reservation = self.reservations[reservation_index].amount;
        const exchange_position = self.exchange_positions[position_index].quantity;
        if (command_value.intent_sequence == 0 or command_value.risk_decision_identity == 0 or command_value.reservation_identity == 0 or
            command_value.order_id == 0 or command_value.revision == 0 or command_value.client_order_id.len == 0 or
            proof.authority_barrier == 0 or proof.authority_barrier != authority.authority_barrier or
            self.reservations[reservation_index].barrier != authority.authority_barrier or
            self.exchange_positions[position_index].barrier != authority.authority_barrier or
            proof.fencing_token == 0 or proof.fencing_token != authority.fencing_token or
            proof.now_monotonic_ns > proof.context.dispatch_deadline_monotonic_ns or
            proof.now_monotonic_ns > authority.primary_lease_expires_at_monotonic_ns or
            exchange_position.instrument != command_value.instrument or
            exchange_position.rules_version != command_value.limit_price.rules_version)
            return error.NotSent;
        const reducing = genuinelyReduces(exchange_position.lots, command_value.side, command_value.quantity);
        if (!authority.effective_trading_authority and !reducing) return error.NotSent;
        if (command_value.operation != .cancel and
            (reservation.asset != command_value.reservation.asset or reservation.atoms != command_value.reservation.atoms or reservation.atoms <= 0))
            return error.NotSent;
        const result = self.sendOms(proof.context, command_value) catch return error.NotSent;
        if (result == .accepted) {
            self.accepted_dispatches[self.accepted_dispatch_count] = .{ .account = proof.context.account, .command_id = command_value.command_id, .proof = proof };
            self.accepted_dispatch_count += 1;
        }
        return result;
    }

    /// Sends a non-order request through the same account-owned route.  Only
    /// the canonical request crosses this seam; replay callers never own a
    /// Gateway and therefore cannot send anything.
    pub fn sendRequest(self: *Gateway, request: canonical.AdapterRequest) !venue.SendResult {
        switch (request) {
            .order_command, .order_batch => return error.OrderProofRequired,
            else => {},
        }
        const account = switch (request) {
            .order_reconciliation => |reconciliation| reconciliation.exchange_account,
            .account_reconciliation => |reconciliation| reconciliation.exchange_account,
            .order_command, .order_batch => unreachable,
        };
        const route = self.routeFor(account) orelse return error.UnknownAccount;
        return self.sendRequestForRoute(route, request);
    }

    fn routeFor(self: *Gateway, account: canonical.ExchangeAccountIdentity) ?*Route {
        for (self.routes[0..self.count]) |*route_value|
            if (route_value.account == account) return route_value;
        return null;
    }

    fn routeIndex(self: *const Gateway, account: canonical.ExchangeAccountIdentity) ?usize {
        for (self.routes[0..self.count], 0..) |route, index|
            if (route.account == account) return index;
        return null;
    }

    fn reservationIndex(self: *const Gateway, account: canonical.ExchangeAccountIdentity, identity: u64) ?usize {
        for (self.reservations[0..self.reservation_count], 0..) |fact, index|
            if (fact.account == account and fact.identity == identity) return index;
        return null;
    }

    fn exchangePositionIndex(self: *const Gateway, account: canonical.ExchangeAccountIdentity, instrument: canonical.InstrumentIdentity) ?usize {
        for (self.exchange_positions[0..self.exchange_position_count], 0..) |fact, index|
            if (fact.account == account and fact.quantity.instrument == instrument) return index;
        return null;
    }

    fn acceptedDispatchIndex(self: *const Gateway, account: canonical.ExchangeAccountIdentity, command_id: u64) ?usize {
        for (self.accepted_dispatches[0..self.accepted_dispatch_count], 0..) |dispatch, index|
            if (dispatch.account == account and dispatch.command_id == command_id) return index;
        return null;
    }

    fn validateOrder(self: *const Gateway, route: *const Route, request: canonical.OrderCommand) !void {
        const increasing = request.operation != .cancel and
            !(request.portfolio_reduce_only or request.venue_reduce_only);
        if (increasing and (route.safety_gate == .latched or self.instrumentGapped(request.instrument)))
            return error.Rejected;
        if (request.operation != .cancel and !route.capability.supports_place)
            return error.Rejected;
        if (request.order_type == .post_only and !route.capability.supports_post_only) return error.Rejected;
        if (request.market_protection_price != null and !route.capability.supports_market_protection) return error.Rejected;
        if (route.capability.version != request.capability_version or
            route.capability.rules_version != request.rules_version or
            route.capability.config_version != request.config_version or
            route.capability.session != request.adapter_session)
            return error.Rejected;
    }

    fn sendRequestForRoute(self: *Gateway, route: *Route, request: canonical.AdapterRequest) !venue.SendResult {
        self.send_attempt_count += 1;
        return route.adapter.trySend(request) catch |err| {
            route.safety_gate = .latched;
            return err;
        };
    }
    pub fn latchAccount(self: *Gateway, account: canonical.ExchangeAccountIdentity) void {
        for (self.routes[0..self.count]) |*route| {
            if (route.account == account) route.safety_gate = .latched;
        }
    }
    pub fn setInstrumentGap(self: *Gateway, instrument: canonical.InstrumentIdentity) void {
        self.setInstrumentGate(instrument, .blocked);
    }
    /// Adapter uncertainty is account-private.  The caller drains it through
    /// the common seam, so a Venue implementation never needs a Gateway branch.
    pub fn observeAdapterOutput(self: *Gateway, batch: canonical.AdapterOutputBatch) void {
        for (batch.slice()) |record| switch (record.event) {
            .order_dispatch_result => |result| if (result.state == .unknown) {
                if (record.envelope.exchange_account) |account| self.latchAccount(account);
            },
            .order_reconciliation_result, .account_reconciliation_result => |result| if (result.status == .unresolved) {
                if (record.envelope.exchange_account) |account| self.latchAccount(account);
            },
            else => {},
        };
    }
    /// Market feeds stay independent of account routes; only their canonical
    /// health fact controls the affected Instrument opening gate.
    pub fn observeMarketOutput(self: *Gateway, batch: canonical.AdapterOutputBatch) void {
        for (batch.slice()) |record| switch (record.event) {
            .market_data_health_changed => |health| switch (health.health) {
                // A health notification is an observation, not continuity
                // proof. Only a validated L2 snapshot may reopen a gate.
                .healthy => {},
                .awaiting_snapshot, .gap => self.setInstrumentGap(health.instrument),
            },
            .l2_book_snapshot => |snapshot| self.setInstrumentGate(snapshot.instrument, .open),
            else => {},
        };
    }
    fn setInstrumentGate(self: *Gateway, instrument: canonical.InstrumentIdentity, state: OpeningGate) void {
        for (self.instrument_gates[0..self.instrument_gate_count]) |*gate| if (gate.instrument == instrument) {
            gate.state = state;
            return;
        };
        if (self.instrument_gate_count < self.instrument_gates.len) {
            self.instrument_gates[self.instrument_gate_count] = .{ .instrument = instrument, .state = state };
            self.instrument_gate_count += 1;
        } else self.instrument_gate_capacity_exhausted = true;
    }
    fn instrumentGapped(self: *const Gateway, instrument: canonical.InstrumentIdentity) bool {
        for (self.instrument_gates[0..self.instrument_gate_count]) |gate| if (gate.instrument == instrument and gate.state == .blocked) return true;
        return self.instrument_gate_capacity_exhausted;
    }
    pub fn drainFair(self: *Gateway, output: *[max_routes]canonical.AdapterOutputBatch) !u8 {
        var count: u8 = 0;
        for (self.routes[0..self.count]) |route| if (try route.adapter.tryDrain()) |batch| {
            self.observeAdapterOutput(batch);
            output[count] = batch;
            count += 1;
        };
        return count;
    }
};

fn genuinelyReduces(position: i128, side: oms.Side, quantity: i64) bool {
    if (quantity <= 0 or position == 0) return false;
    const after = std.math.add(i128, position, if (side == .buy) quantity else -@as(i128, quantity)) catch return false;
    if ((position > 0 and after < 0) or (position < 0 and after > 0)) return false;
    return if (position > 0) after < position else after > position;
}
fn command(account: canonical.ExchangeAccountIdentity, instrument: canonical.InstrumentIdentity) !canonical.OrderCommand {
    return .{ .identity = 1, .exchange_account = account, .instrument = instrument, .client_order_id = try canonical.ClientOrderId.init("x"), .capability_version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .dispatch_deadline_monotonic_ns = 1 };
}

const Fixture = struct {
    pending: ?canonical.AdapterOutputBatch = .{},
    sent: u8 = 0,
    fn adapter(self: *Fixture) venue.VenueAdapter {
        return .{ .ptr = self, .vtable = &.{ .start = start, .try_send = send, .try_drain = drain, .stop = stop } };
    }
    fn start(_: *anyopaque, _: venue.VenueConfig) venue.StartError!void {}
    fn send(ptr: *anyopaque, _: canonical.AdapterRequest) venue.SendError!venue.SendResult {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.sent += 1;
        return .accepted;
    }
    fn drain(ptr: *anyopaque) venue.DrainError!?canonical.AdapterOutputBatch {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        const batch = self.pending;
        self.pending = null;
        return batch;
    }
    fn stop(_: *anyopaque, _: venue.DrainDeadline) venue.StopError!void {}
};
test "gateway fixes route and rechecks every command dependency" {
    var first = Fixture{};
    var second = Fixture{};
    var gateway = Gateway{};
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    try gateway.add(.{ .account = 1, .adapter = first.adapter(), .capability = profile });
    try gateway.add(.{ .account = 2, .adapter = second.adapter(), .capability = profile });
    var request = try command(1, 10);
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(request));
    try std.testing.expectEqual(@as(u8, 1), first.sent);
    request.config_version = 2;
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    try std.testing.expectEqual(@as(u8, 1), first.sent);
    request.config_version = 1;
    request.capability_version = 2;
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.capability_version = 1;
    request.rules_version = 2;
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.rules_version = 1;
    request.adapter_session = 2;
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.adapter_session = 1;
    gateway.latchAccount(1);
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.operation = .cancel;
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(request));
    request.operation = .place;
    request.exchange_account = 2;
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(request));
    gateway.setInstrumentGap(10);
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.instrument = 11;
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(request));
    gateway.routes[1].capability.supports_place = false;
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(request));
    request.operation = .cancel;
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(request));
    try std.testing.expectEqual(@as(u8, 3), second.sent);
    try std.testing.expectEqual(@as(u64, 5), gateway.send_attempt_count);
    std.debug.print("execution_gateway_acceptance: adapter_submissions={d}\n", .{gateway.send_attempt_count});
}
test "gateway drains each fixed route once" {
    var first = Fixture{};
    var second = Fixture{};
    var gateway = Gateway{};
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    try gateway.add(.{ .account = 1, .adapter = first.adapter(), .capability = profile });
    try gateway.add(.{ .account = 2, .adapter = second.adapter(), .capability = profile });
    var output: [max_routes]canonical.AdapterOutputBatch = undefined;
    try std.testing.expectEqual(@as(u8, 2), try gateway.drainFair(&output));
}

test "DispatchProof rechecks authority reservation lease fencing and true reduce-only" {
    var adapter_fixture = Fixture{ .pending = null };
    var gateway = Gateway{};
    try gateway.add(.{ .account = 1, .adapter = adapter_fixture.adapter(), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    const command_value: oms.Command = .{ .command_id = 1, .order_id = 1, .strategy_instance = 1, .revision = 1, .operation = .place, .instrument = 10, .side = .sell, .portfolio_reduce_only = true, .venue_reduce_only = true, .quantity = 2, .limit_price = .{ .instrument = 10, .rules_version = 1, .ticks = 100 }, .reservation = .{ .asset = 1, .atoms = 20 }, .client_order_id = try canonical.ClientOrderId.init("RWN-1"), .intent_sequence = 1, .risk_decision_identity = 1, .reservation_identity = 1 };
    try gateway.observeAuthority(.{
        .account = 1,
        .effective_trading_authority = false,
        .reservation_identity = command_value.reservation_identity,
        .reservation = command_value.reservation,
        .primary_lease_expires_at_monotonic_ns = 10,
        .fencing_token = 7,
        .exchange_position = .{ .instrument = 10, .rules_version = 1, .lots = 3 },
        .authority_barrier = 5,
    });
    const proof: DispatchProof = .{
        .context = .{ .account = 1, .capability_version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .dispatch_deadline_monotonic_ns = 10 },
        .command = command_value,
        .fencing_token = 7,
        .authority_barrier = 5,
        .now_monotonic_ns = 9,
    };
    try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendProof(proof));
    try std.testing.expectEqual(venue.SendResult.accepted, try gateway.sendProof(proof));
    var conflicting = proof;
    conflicting.command.quantity = 1;
    try std.testing.expectError(error.NotSent, gateway.sendProof(conflicting));
    try std.testing.expectEqual(@as(u8, 1), adapter_fixture.sent);

    var recovered_fixture = Fixture{ .pending = null };
    var recovered = Gateway{};
    try recovered.add(.{ .account = 1, .adapter = recovered_fixture.adapter(), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    try recovered.restoreAcceptedDispatch(proof);
    try std.testing.expectEqual(venue.SendResult.accepted, try recovered.sendProof(proof));
    try std.testing.expectError(error.NotSent, recovered.sendProof(conflicting));
    try std.testing.expectEqual(@as(u8, 0), recovered_fixture.sent);
}

test "Gateway reads current authority facts instead of caller proof fields" {
    var adapter_fixture = Fixture{ .pending = null };
    var gateway = Gateway{};
    try gateway.add(.{ .account = 1, .adapter = adapter_fixture.adapter(), .capability = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 } });
    const command_value: oms.Command = .{ .command_id = 2, .order_id = 2, .strategy_instance = 1, .revision = 1, .operation = .place, .instrument = 10, .side = .sell, .portfolio_reduce_only = true, .venue_reduce_only = true, .quantity = 2, .limit_price = .{ .instrument = 10, .rules_version = 1, .ticks = 100 }, .reservation = .{ .asset = 1, .atoms = 20 }, .client_order_id = try canonical.ClientOrderId.init("RWN-2"), .intent_sequence = 2, .risk_decision_identity = 2, .reservation_identity = 2 };
    const proof: DispatchProof = .{
        .context = .{ .account = 1, .capability_version = 1, .rules_version = 1, .config_version = 1, .adapter_session = 1, .dispatch_deadline_monotonic_ns = 10 },
        .command = command_value,
        .fencing_token = 7,
        .authority_barrier = 5,
        .now_monotonic_ns = 9,
    };
    try gateway.observeAuthority(.{ .account = 1, .effective_trading_authority = false, .reservation_identity = 2, .reservation = command_value.reservation, .primary_lease_expires_at_monotonic_ns = 10, .fencing_token = 7, .exchange_position = .{ .instrument = 10, .rules_version = 1, .lots = -3 }, .authority_barrier = 5 });
    try std.testing.expectError(error.ConflictingAuthorityFacts, gateway.observeAuthority(.{ .account = 1, .effective_trading_authority = false, .reservation_identity = 2, .reservation = command_value.reservation, .primary_lease_expires_at_monotonic_ns = 10, .fencing_token = 7, .exchange_position = .{ .instrument = 10, .rules_version = 1, .lots = 3 }, .authority_barrier = 5 }));
    try std.testing.expectError(error.NotSent, gateway.sendProof(proof));
    try gateway.observeAuthority(.{ .account = 1, .effective_trading_authority = false, .reservation_identity = 2, .reservation = command_value.reservation, .primary_lease_expires_at_monotonic_ns = 10, .fencing_token = 8, .exchange_position = .{ .instrument = 10, .rules_version = 1, .lots = 3 }, .authority_barrier = 6 });
    try std.testing.expectError(error.NotSent, gateway.sendProof(proof));
    try gateway.observeAuthority(.{ .account = 1, .effective_trading_authority = false, .reservation_identity = 3, .reservation = command_value.reservation, .primary_lease_expires_at_monotonic_ns = 10, .fencing_token = 8, .exchange_position = .{ .instrument = 10, .rules_version = 1, .lots = 3 }, .authority_barrier = 7 });
    var stale_reservation = proof;
    stale_reservation.fencing_token = 8;
    stale_reservation.authority_barrier = 7;
    try std.testing.expectError(error.NotSent, gateway.sendProof(stale_reservation));
    try std.testing.expectEqual(@as(u8, 0), adapter_fixture.sent);
}
test "Gateway route and batch admission fail atomically" {
    var adapter_fixture = Fixture{ .pending = null };
    var gateway = Gateway{};
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    for (1..max_routes + 1) |account|
        try gateway.add(.{ .account = account, .adapter = adapter_fixture.adapter(), .capability = profile });
    try std.testing.expectError(error.DuplicateAccountRoute, gateway.add(.{ .account = 1, .adapter = adapter_fixture.adapter(), .capability = profile }));
    try std.testing.expectEqual(@as(u8, max_routes), gateway.count);
    try std.testing.expectError(error.RouteCapacity, gateway.add(.{ .account = 99, .adapter = adapter_fixture.adapter(), .capability = profile }));
    try std.testing.expectEqual(@as(u8, max_routes), gateway.count);

    var batch: canonical.OrderCommandBatch = .{};
    var invalid = try command(1, 10);
    invalid.config_version = 2;
    try batch.append(invalid);
    try std.testing.expectError(error.OrderProofRequired, gateway.sendRequest(.{ .order_batch = batch }));
    try std.testing.expectEqual(@as(u64, 0), gateway.send_attempt_count);
    try std.testing.expectEqual(@as(u8, 0), adapter_fixture.sent);
}
test "Gateway scopes uncertainty and market health to the affected route" {
    var first = Fixture{ .pending = null };
    var second = Fixture{ .pending = null };
    var gateway = Gateway{};
    const profile: CapabilityProfile = .{ .version = 1, .rules_version = 1, .config_version = 1, .session = 1 };
    try gateway.add(.{ .account = 11, .adapter = first.adapter(), .capability = profile });
    try gateway.add(.{ .account = 22, .adapter = second.adapter(), .capability = profile });

    var unknown: canonical.AdapterOutputBatch = .{};
    try unknown.append(.{ .envelope = .{
        .event_type = @intFromEnum(canonical.EventType.order_dispatch_result),
        .schema_version = 1,
        .identity = .{ .stream = 1, .sequence = 1 },
        .source_fact_identity = 1,
        .scope = .account,
        .venue = 2,
        .exchange_account = 11,
        .source_stream = 1,
        .source_sequence = 1,
        .adapter_session = 1,
        .times = .{ .monotonic_ns = 1 },
        .raw_evidence = .{ .stream = 1, .sequence = 1, .digest = @splat(0) },
    }, .event = .{ .order_dispatch_result = .{ .command = 1, .state = .unknown } } });
    gateway.observeAdapterOutput(unknown);
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(11, 101)));
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(try command(22, 202)));

    var gap: canonical.AdapterOutputBatch = .{};
    try gap.append(.{ .envelope = .{
        .event_type = @intFromEnum(canonical.EventType.market_data_health_changed),
        .schema_version = 1,
        .identity = .{ .stream = 2, .sequence = 1 },
        .source_fact_identity = 2,
        .scope = .instrument,
        .venue = 2,
        .instrument = 202,
        .source_stream = 2,
        .source_sequence = 1,
        .adapter_session = 2,
        .times = .{ .monotonic_ns = 1 },
        .raw_evidence = .{ .stream = 2, .sequence = 1, .digest = @splat(0) },
    }, .event = .{ .market_data_health_changed = .{ .instrument = 202, .health = .gap } } });
    gateway.observeMarketOutput(gap);
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(22, 202)));
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(11, 101)));

    gap.events[0].event.market_data_health_changed.health = .healthy;
    gateway.observeMarketOutput(gap);
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(22, 202)));
    gap.events[0].envelope.event_type = @intFromEnum(canonical.EventType.l2_book_snapshot);
    gap.events[0].event = .{ .l2_book_snapshot = .{
        .instrument = 202,
        .sequence = 2,
        .best_bid = .{ .instrument = 202, .rules_version = 1, .ticks = 1 },
        .best_ask = .{ .instrument = 202, .rules_version = 1, .ticks = 2 },
    } };
    gateway.observeMarketOutput(gap);
    try std.testing.expectEqual(.accepted, try gateway.sendUnprovedForContractTest(try command(22, 202)));

    for (0..max_routes + 1) |index| gateway.setInstrumentGap(1_000 + index);
    try std.testing.expect(gateway.instrument_gate_capacity_exhausted);
    try std.testing.expectError(error.Rejected, gateway.sendUnprovedForContractTest(try command(22, 999)));
}
