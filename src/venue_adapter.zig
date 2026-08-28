const canonical = @import("canonical_event.zig");

pub const Environment = enum { simulation, demo };

pub const Config = struct {
    environment: Environment,
    request_capacity: u16,
    output_capacity: u16,
};

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

pub fn Interface(comptime Request: type, comptime OutputBatch: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            start: *const fn (*anyopaque, Config) StartError!void,
            try_send: *const fn (*anyopaque, Request) SendError!SendResult,
            try_drain: *const fn (*anyopaque) DrainError!?OutputBatch,
            stop: *const fn (*anyopaque, DrainDeadline) StopError!void,
        };

        pub fn start(self: @This(), config: Config) StartError!void {
            return self.vtable.start(self.ptr, config);
        }

        pub fn trySend(self: @This(), request: Request) SendError!SendResult {
            return self.vtable.try_send(self.ptr, request);
        }

        pub fn tryDrain(self: @This()) DrainError!?OutputBatch {
            return self.vtable.try_drain(self.ptr);
        }

        pub fn stop(self: @This(), deadline: DrainDeadline) StopError!void {
            return self.vtable.stop(self.ptr, deadline);
        }
    };
}

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
    };

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
