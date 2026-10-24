const std = @import("std");
const canonical = @import("../model/canonical_event.zig");
const snapshot = @import("../persistence/snapshot_codec.zig");
const codec = @import("../persistence/canonical_event_codec.zig");

pub const capacity = 8;
pub const max_record_bytes = 8192;
pub const Slot = struct {
    bytes: [max_record_bytes]u8 = @splat(0),
    len: u16 = 0,
    targets: u4 = 0,
    acknowledged: u4 = 0,
    barrier: u64 = 0,
};
const Seen = struct { identity: u128 = 0, kind: u32 = 0, digest: [32]u8 = @splat(0) };
/// Durable input and delivery cursors; contains no adapter, network or ledger.
pub const State = struct {
    // Bounded snapshot cache; CoordinatorOwner reads authoritative pending facts from history.
    slots: [capacity]Slot = @splat(.{}),
    count: u8 = 0,
    seen: [32]Seen = @splat(.{}),
    seen_count: u8 = 0,
    stream: u128 = 0,
    venue: canonical.VenueIdentity = 0,
    source_stream: canonical.VenueSourceStreamIdentity = 0,
    sequence: u64 = 0,
    barrier: u64 = 0,
    broken: bool = false,
    retired_sequence: u64 = 0,
    acknowledged: [4]u64 = @splat(0),

    pub fn accept(self: *State, record: canonical.EventRecord, targets: u4) !bool {
        const hash = try semanticDigest(record);
        try self.validateSource(record);
        for (self.seen[0..self.seen_count]) |known| {
            if (known.identity == record.envelope.source_fact_identity and known.kind == record.envelope.event_type) {
                if (!std.mem.eql(u8, &known.digest, &hash)) return error.VenueFactIdentityConflict;
                if (record.envelope.identity.sequence <= self.sequence) return false;
                if (record.envelope.identity.stream != self.stream or record.envelope.identity.sequence != self.sequence + 1) return error.VenueSequenceGap;
                self.sequence = record.envelope.identity.sequence;
                return true;
            }
        }
        try self.validateSource(record);
        if (record.envelope.identity.sequence != self.sequence + 1) return error.VenueSequenceGap;
        if (record.envelope.identity.sequence <= self.retired_sequence) return error.VenueHistoryProofRequired;
        if (self.count == capacity) return error.VenueIngressBackpressure;
        if (self.seen_count == self.seen.len) return error.VenueHistoryProofRequired;
        var bytes: [max_record_bytes]u8 = undefined;
        const encoded = try codec.encode(&bytes, record);
        self.barrier += 1;
        const slot = &self.slots[self.count];
        slot.* = .{ .len = @intCast(encoded.len), .targets = targets, .barrier = self.barrier };
        @memcpy(slot.bytes[0..encoded.len], encoded);
        self.count += 1;
        self.seen[self.seen_count] = .{ .identity = record.envelope.source_fact_identity, .kind = record.envelope.event_type, .digest = hash };
        self.seen_count += 1;
        self.stream = record.envelope.identity.stream;
        self.venue = record.envelope.venue;
        self.source_stream = record.envelope.source_stream;
        self.sequence = record.envelope.identity.sequence;
        if (targets == 0) self.broken = true;
        return true;
    }

    pub fn validateSource(self: *const State, record: canonical.EventRecord) !void {
        if (record.envelope.identity.stream == 0 or record.envelope.source_stream == 0) return error.InvalidVenueFact;
        if (self.stream != 0 and (self.stream != record.envelope.identity.stream or
            self.venue != record.envelope.venue or self.source_stream != record.envelope.source_stream)) return error.VenueStreamChanged;
    }

    pub fn acceptArchived(self: *State, record: canonical.EventRecord, targets: u4, duplicate: bool) !void {
        try self.validateSource(record);
        if (record.envelope.identity.sequence <= self.sequence) {
            if (duplicate) return;
            return error.VenueSequenceGap;
        }
        if (record.envelope.identity.sequence != try std.math.add(u64, self.sequence, 1)) return error.VenueSequenceGap;
        self.stream = record.envelope.identity.stream;
        self.venue = record.envelope.venue;
        self.source_stream = record.envelope.source_stream;
        self.sequence = record.envelope.identity.sequence;
        if (duplicate) return;
        self.barrier = try std.math.add(u64, self.barrier, 1);
        if (self.count < capacity) {
            const slot = &self.slots[self.count];
            const bytes = try codec.encode(&slot.bytes, record);
            slot.len = @intCast(bytes.len);
            slot.targets = targets;
            slot.barrier = self.barrier;
            self.count += 1;
        }
        if (targets == 0) self.broken = true;
    }

    /// Cache inspection only; use CoordinatorOwner.pendingVenueFact for complete pending evidence.
    pub fn pendingFor(self: *const State, shard: u2) ?canonical.EventRecord {
        const mask = @as(u4, 1) << shard;
        for (self.slots[0..self.count]) |*slot| {
            if (slot.targets & mask != 0 and slot.acknowledged & mask == 0)
                return codec.decode(slot.bytes[0..slot.len]) catch null;
        }
        return null;
    }

    pub fn acknowledge(self: *State, barrier: u64, shard: u2) !void {
        if (barrier > self.barrier or barrier < self.acknowledged[shard]) return error.InvalidVenueAcknowledgement;
        self.acknowledged[shard] = barrier;
        const mask = @as(u4, 1) << shard;
        for (self.slots[0..self.count], 0..) |*slot, index| {
            if (slot.barrier != barrier) continue;
            if (slot.targets & mask == 0) return error.InvalidVenueAcknowledgement;
            slot.acknowledged |= mask;
            if (slot.acknowledged == slot.targets) {
                std.mem.copyForwards(Slot, self.slots[index .. self.count - 1], self.slots[index + 1 .. self.count]);
                self.count -= 1;
                self.slots[self.count] = .{};
            }
            return;
        }
        return;
    }

    pub fn write(self: *const State, writer: *std.Io.Writer) !void {
        try writer.writeInt(u128, self.stream, .little);
        try writer.writeInt(u64, self.venue, .little);
        try writer.writeInt(u128, self.source_stream, .little);
        try writer.writeInt(u64, self.sequence, .little);
        try writer.writeInt(u64, self.barrier, .little);
        try writer.writeInt(u64, self.retired_sequence, .little);
        for (self.acknowledged) |cursor| try writer.writeInt(u64, cursor, .little);
        try writer.writeByte(@intFromBool(self.broken));
        try writer.writeByte(self.seen_count);
        for (self.seen[0..self.seen_count]) |seen| {
            try writer.writeInt(u128, seen.identity, .little);
            try writer.writeInt(u32, seen.kind, .little);
            try writer.writeAll(&seen.digest);
        }
        try writer.writeByte(self.count);
        for (self.slots[0..self.count]) |*slot| {
            try writer.writeInt(u16, slot.len, .little);
            try writer.writeByte(slot.targets);
            try writer.writeByte(slot.acknowledged);
            try writer.writeInt(u64, slot.barrier, .little);
            try writer.writeAll(slot.bytes[0..slot.len]);
        }
    }

    pub fn read(reader: *std.Io.Reader) !State {
        var self: State = .{};
        self.stream = try reader.takeInt(u128, .little);
        self.venue = try reader.takeInt(u64, .little);
        self.source_stream = try reader.takeInt(u128, .little);
        self.sequence = try reader.takeInt(u64, .little);
        self.barrier = try reader.takeInt(u64, .little);
        self.retired_sequence = try reader.takeInt(u64, .little);
        for (&self.acknowledged) |*cursor| {
            cursor.* = try reader.takeInt(u64, .little);
            if (cursor.* > self.barrier) return error.InvalidVenueIngressSnapshot;
        }
        const broken = try reader.takeByte();
        if (broken > 1) return error.InvalidVenueIngressSnapshot;
        self.broken = broken == 1;
        self.seen_count = try reader.takeByte();
        if (self.seen_count > self.seen.len) return error.InvalidVenueIngressSnapshot;
        for (self.seen[0..self.seen_count]) |*seen| {
            seen.identity = try reader.takeInt(u128, .little);
            seen.kind = try reader.takeInt(u32, .little);
            @memcpy(&seen.digest, try reader.take(32));
        }
        self.count = try reader.takeByte();
        if (self.count > capacity) return error.InvalidVenueIngressSnapshot;
        for (self.slots[0..self.count]) |*slot| {
            slot.len = try reader.takeInt(u16, .little);
            const targets = try reader.takeByte();
            const acknowledged = try reader.takeByte();
            if (slot.len > max_record_bytes or targets > 15 or acknowledged & ~targets != 0) return error.InvalidVenueIngressSnapshot;
            slot.targets = @intCast(targets);
            slot.acknowledged = @intCast(acknowledged);
            slot.barrier = try reader.takeInt(u64, .little);
            @memcpy(slot.bytes[0..slot.len], try reader.take(slot.len));
            _ = try codec.decode(slot.bytes[0..slot.len]);
        }
        return self;
    }
};

pub fn semanticDigest(record: canonical.EventRecord) ![32]u8 {
    var bytes: [max_record_bytes]u8 = undefined;
    const payload = try codec.encodePayload(&bytes, record.event);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(payload);
    var scope_bytes: [128]u8 = undefined;
    hasher.update(try snapshot.encodeBare(&scope_bytes, .{ record.envelope.venue, record.envelope.exchange_account, record.envelope.scope, record.envelope.instrument, record.envelope.asset, record.envelope.schema_version, record.envelope.source_stream }));
    const hash = hasher.finalResult();
    return hash;
}
