const canonical = @import("canonical_event.zig");

pub const Environment = enum { simulation, demo };

pub const VenueConfig = struct {
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
/// canonical requests and bounded canonical event batches.
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
