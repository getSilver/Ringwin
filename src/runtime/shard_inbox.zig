//! Single-writer pending inputs. A rejected enqueue is retained by the caller.
const demo = @import("demo/demo_authority.zig");
const trading = @import("../trading/trading_shard.zig");

pub const Inbox = struct {
    pub const capacity = 4;
    const overload_gate: u64 = 0x494e424f5846554c;
    events: [capacity]trading.CanonicalEvent = undefined,
    head: usize = 0,
    len: usize = 0,
    stream: ?@import("../persistence/durable_store.zig").StreamIdentity = null,
    overload_identity: ?u64 = null,

    /// Called by this shard's writer; overflow is a durable local safety fact.
    pub fn push(self: *Inbox, owner: *demo.Owner, input: trading.CanonicalEvent, now_monotonic_ns: u64) !void {
        if (self.stream) |stream| {
            if (!@import("std").meta.eql(stream, owner.stream)) return error.CrossShardDelivery;
        } else self.stream = owner.stream;
        if (self.len == capacity) {
            if (now_monotonic_ns == 0) return error.InvalidSafetyTime;
            const identity = self.overload_identity orelse try @import("std").math.add(u64, overload_gate, owner.shard.authoritativeBarrier());
            _ = try owner.apply(.{ .core = .{ .identity = identity, .monotonic_time = now_monotonic_ns, .time_presence = .{ .monotonic = true }, .payload = .{ .safety_gate_change = .{
                .gate_identity = identity,
                .target_identity = owner.shard.operational_state.target_identity,
                .kind = .latched,
                .reason = .observability,
                .open = false,
            } } } });
            self.overload_identity = identity;
            return error.ShardInboxFull;
        }
        self.events[(self.head + self.len) % capacity] = input;
        self.len += 1;
    }

    /// Failed applications remain pending; draining never clears an overload latch.
    pub fn drainOne(self: *Inbox, owner: *demo.Owner) !bool {
        if (self.len == 0) return false;
        if (!@import("std").meta.eql(self.stream.?, owner.stream)) return error.CrossShardDelivery;
        _ = try owner.apply(self.events[self.head]);
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        self.overload_identity = null;
        return true;
    }
};
