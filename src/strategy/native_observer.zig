//! Minimal native definition: observes reference prices without trading output.
const canonical = @import("../model/canonical_event.zig");

pub const Config = struct { instrument: canonical.InstrumentIdentity, max_observations: u64 };
pub const State = struct { cursor: u64 = 0, observations: u64 = 0 };
pub const Error = error{ InvalidConfig, InvalidState, InvalidInput, CapacityExceeded };

pub fn create(config: Config) Error!State {
    if (config.instrument == 0 or config.max_observations == 0) return error.InvalidConfig;
    return .{};
}

pub fn validate(config: Config, state: State) Error!void {
    _ = try create(config);
    if (state.observations > config.max_observations or
        (state.observations == 0) != (state.cursor == 0)) return error.InvalidState;
}

pub fn onReferencePrice(config: Config, state: *State, cursor: u64, price: canonical.ReferencePrice) Error!void {
    try validate(config, state.*);
    if (cursor <= state.cursor or price.instrument != config.instrument or
        price.price.instrument != config.instrument or price.price.rules_version == 0 or
        price.price.ticks <= 0) return error.InvalidInput;
    if (state.observations == config.max_observations) return error.CapacityExceeded;
    state.* = .{ .cursor = cursor, .observations = state.observations + 1 };
}
