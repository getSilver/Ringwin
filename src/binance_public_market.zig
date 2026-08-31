//! Private transport evidence types for Binance public-market frames.
//!
//! They stay on the Venue side of the seam; only `canonical_event` values
//! leave `binance_market_feed`.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_raw_frame_bytes = 1024 * 1024;

pub const Times = struct {
    receive_time_utc_ns: u64,
    monotonic_time_ns: u64,
    wall_time_utc_ns: u64,
};

pub const RawIngressRecord = struct {
    source_session: u64,
    receive_time_utc_ns: u64,
    monotonic_time_ns: u64,
    wall_time_utc_ns: u64,
    byte_len: u32,
    sha256: [Sha256.digest_length]u8,
};

pub const RawEvidenceRef = struct {
    stream_sequence: u64,
    sha256: [Sha256.digest_length]u8,
};

pub const RawSinkError = error{ Unavailable, Backpressure };

pub const RawSink = struct {
    ptr: *anyopaque,
    append_fn: *const fn (*anyopaque, RawIngressRecord, []const u8) RawSinkError!u64,

    pub fn append(self: RawSink, record: RawIngressRecord, bytes: []const u8) RawSinkError!RawEvidenceRef {
        return .{ .stream_sequence = try self.append_fn(self.ptr, record, bytes), .sha256 = record.sha256 };
    }
};
