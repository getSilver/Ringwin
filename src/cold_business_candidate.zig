//! Pure, bounded suspension of one original input awaiting authenticated business history.
const std = @import("std");
const journal = @import("journal.zig");
const history = @import("business_history.zig");
const codec = @import("snapshot_codec.zig");

pub const schema_version: u16 = 2;
pub const max_original_input_size = 8192;
pub const max_encoded_size = max_original_input_size + 2048;

pub const InputMetadata = struct {
    type_id: u16,
    schema_version: u16,
    flags: u32,
    sequence: u64,
    source_time: u64,
    receive_time: u64,
    monotonic_time: u64,
    wall_time: u64,
    time_presence: journal.TimePresence,
};

pub const PendingCandidate = struct {
    version: u16 = schema_version,
    original_was_admissible: bool = true,
    request: history.LookupRequest,
    original: InputMetadata,
    original_len: u32,
    original_bytes: [max_original_input_size]u8 = @splat(0),

    pub fn originalRecord(self: *const PendingCandidate) journal.Record {
        return .{ .type_id = self.original.type_id, .schema_version = self.original.schema_version, .flags = self.original.flags, .sequence = self.original.sequence, .source_time = self.original.source_time, .receive_time = self.original.receive_time, .monotonic_time = self.original.monotonic_time, .wall_time = self.original.wall_time, .time_presence = self.original.time_presence, .payload = self.original_bytes[0..self.original_len] };
    }

    /// Resolves the proof only. The caller applies or isolates the candidate and clears it in one transaction.
    pub fn finalize(self: *const PendingCandidate, proof: *const history.LookupProof, current_root: history.Root) !history.Verdict {
        try self.validate();
        return history.verifyResult(self.request, proof, current_root);
    }

    fn validate(self: *const PendingCandidate) !void {
        if (self.version != schema_version or self.original_len == 0 or self.original_len > self.original_bytes.len or
            self.original.schema_version == 0 or self.original.time_presence.reserved != 0 or
            self.request.pending_id == 0 or self.request.epoch == 0 or self.request.barrier == 0 or
            self.request.key.origin.stream.domain != .decision_log or self.request.key.origin.stream.id == 0 or
            self.request.key.origin.account == 0 or std.mem.allEqual(u8, &self.request.root_digest, 0) or
            std.mem.allEqual(u8, &self.request.candidate_payload_digest, 0)) return error.InvalidPendingCandidate;
        _ = try history.encodeKey(self.request.key);
        if (!std.mem.allEqual(u8, self.original_bytes[self.original_len..], 0)) return error.InvalidPendingCandidate;
        if (!std.mem.eql(u8, &inputDigest(self.originalRecord()), &self.request.original_input_digest)) return error.InvalidPendingCandidate;
    }
};

pub fn begin(original: journal.Record, request: history.LookupRequest, root: history.Root) !PendingCandidate {
    if (original.payload.len == 0 or original.payload.len > max_original_input_size) return error.InvalidPendingCandidate;
    try history.validateRoot(root);
    if (!std.meta.eql(request.key.origin, root.origin) or !std.mem.eql(u8, &request.root_digest, &root.root_digest) or
        request.epoch != root.epoch or request.barrier != root.barrier) return error.InvalidPendingCandidate;
    var pending: PendingCandidate = .{ .request = request, .original = .{ .type_id = original.type_id, .schema_version = original.schema_version, .flags = original.flags, .sequence = original.sequence, .source_time = original.source_time, .receive_time = original.receive_time, .monotonic_time = original.monotonic_time, .wall_time = original.wall_time, .time_presence = original.time_presence }, .original_len = @intCast(original.payload.len) };
    @memcpy(pending.original_bytes[0..original.payload.len], original.payload);
    try pending.validate();
    return pending;
}

/// Matches TradingShard's AcceptedShardInputV1 digest of stable encoded input and original times.
pub fn inputDigest(record: journal.Record) history.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("AcceptedShardInputV1\x00");
    digestInt(&hash, u16, record.schema_version);
    digestInt(&hash, u64, record.source_time);
    digestInt(&hash, u64, record.receive_time);
    digestInt(&hash, u64, record.monotonic_time);
    digestInt(&hash, u64, record.wall_time);
    digestInt(&hash, u8, @bitCast(record.time_presence));
    hash.update(record.payload);
    var digest: history.Digest = undefined;
    hash.final(&digest);
    return digest;
}

const CompactHeader = struct {
    version: u16,
    original_was_admissible: bool,
    request: history.LookupRequest,
    original: InputMetadata,
    original_len: u32,
};

/// The outer snapshot/journal supplies framing integrity; unused buffer capacity is never serialized.
pub fn encodeCompact(destination: []u8, pending: *const PendingCandidate) ![]const u8 {
    try pending.validate();
    if (destination.len < 4) return error.PendingCandidateTooLarge;
    const header = try codec.encodeBare(destination[4..], CompactHeader{ .version = pending.version, .original_was_admissible = pending.original_was_admissible, .request = pending.request, .original = pending.original, .original_len = pending.original_len });
    const end = 4 + header.len + pending.original_len;
    if (end > destination.len) return error.PendingCandidateTooLarge;
    std.mem.writeInt(u32, destination[0..4], @intCast(header.len), .little);
    @memcpy(destination[4 + header.len .. end], pending.originalRecord().payload);
    return destination[0..end];
}

pub fn decodeCompact(encoded: []const u8) !PendingCandidate {
    if (encoded.len < 4 or encoded.len > max_encoded_size) return error.InvalidPendingCandidateEncoding;
    const header_len: usize = std.mem.readInt(u32, encoded[0..4], .little);
    if (header_len == 0 or header_len > encoded.len - 4) return error.InvalidPendingCandidateEncoding;
    const header = codec.decodeBare(encoded[4 .. 4 + header_len], CompactHeader) catch return error.InvalidPendingCandidateEncoding;
    if (header.original_len == 0 or header.original_len > max_original_input_size or
        header.original_len != encoded.len - 4 - header_len) return error.InvalidPendingCandidateEncoding;
    var pending: PendingCandidate = .{ .version = header.version, .original_was_admissible = header.original_was_admissible, .request = header.request, .original = header.original, .original_len = header.original_len };
    @memcpy(pending.original_bytes[0..header.original_len], encoded[4 + header_len ..]);
    try pending.validate();
    return pending;
}

fn digestInt(hash: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hash.update(&bytes);
}

test "cold business same proof preserves the exact original candidate for transactional resolution" {
    var objects = TestObjects{};
    defer objects.deinit();
    const root = try objects.publish(0);
    const original = testOriginal();
    const request = testRequest(original, root, 11);
    const pending = try begin(original, request, root);
    const result = try history.query(objects.interface(), root, request);
    try std.testing.expectEqual(history.Verdict.same, try pending.finalize(&result.proof, root));
    try std.testing.expectEqualSlices(u8, original.payload, pending.originalRecord().payload);
    try std.testing.expectEqualDeep(request, pending.request);
    try std.testing.expectEqual(@as(u64, 41), pending.originalRecord().receive_time);
}

fn testOriginal() journal.Record {
    return .{ .type_id = 2, .schema_version = 34, .flags = journal.input_flag, .sequence = 13, .source_time = 40, .receive_time = 41, .monotonic_time = 42, .wall_time = 43, .time_presence = .{ .source = true, .receive = true, .monotonic = true, .wall = true }, .payload = "\x02original canonical event with immutable source evidence" };
}

fn testRequest(original: journal.Record, root: history.Root, identity: u128) history.LookupRequest {
    return .{ .pending_id = 1, .key = .{ .origin = root.origin, .identity = .{ .report = identity } }, .candidate_payload_digest = history.hash("terminal report body"), .original_input_digest = inputDigest(original), .root_digest = root.root_digest, .epoch = root.epoch, .barrier = root.barrier };
}

const TestObjects = struct {
    bytes: std.ArrayList(u8) = .empty,
    fn deinit(self: *@This()) void {
        self.bytes.deinit(std.testing.allocator);
    }
    fn interface(self: *@This()) history.Objects {
        return .{ .context = self, .read_fn = read, .write_fn = write };
    }
    fn read(context: *anyopaque, offset: u64, destination: []u8) !usize {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (offset > self.bytes.items.len) return error.InvalidOffset;
        const count = @min(destination.len, self.bytes.items.len - @as(usize, @intCast(offset)));
        @memcpy(destination[0..count], self.bytes.items[@intCast(offset)..][0..count]);
        return count;
    }
    fn write(context: *anyopaque, bytes: []const u8) !u64 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const offset = self.bytes.items.len;
        try self.bytes.appendSlice(std.testing.allocator, bytes);
        return @intCast(offset);
    }
    fn publish(self: *@This(), floor: u64) !history.Root {
        const origin: history.Origin = .{ .stream = .{ .domain = .decision_log, .id = 71 }, .account = 9 };
        const records = [_]history.Record{.{ .bytes = "terminal report body", .payload_digest = history.hash("terminal report body") }};
        const entries = [_]history.Entry{.{ .key = .{ .origin = origin, .identity = .{ .report = 11 } }, .record_index = 0 }};
        const receipt = try history.publish(self.interface(), .{ .origin = origin, .barrier = 12, .epoch = 1, .floor = floor, .qualification_digest = history.hash("qualified order"), .records = &records, .entries = &entries });
        return receipt.root;
    }
};

test "cold business pending compact snapshot round trip preserves stable input and request" {
    var objects = TestObjects{};
    defer objects.deinit();
    const root = try objects.publish(0);
    const original = testOriginal();
    var pending = try begin(original, testRequest(original, root, 11), root);
    pending.original_was_admissible = false;
    var storage: [max_encoded_size]u8 = undefined;
    const encoded = try encodeCompact(&storage, &pending);
    try std.testing.expect(encoded.len < 1024);
    const restored = try decodeCompact(encoded);
    try std.testing.expect(!restored.original_was_admissible);
    try std.testing.expectEqualDeep(pending.request, restored.request);
    try std.testing.expectEqualDeep(pending.original, restored.original);
    try std.testing.expectEqualSlices(u8, pending.originalRecord().payload, restored.originalRecord().payload);
    const proof = try history.query(objects.interface(), root, restored.request);
    try std.testing.expectEqual(history.Verdict.same, try restored.finalize(&proof.proof, root));
    try std.testing.expectError(error.InvalidPendingCandidateEncoding, decodeCompact(encoded[0 .. encoded.len - 1]));
    var corrupt = storage;
    corrupt[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidPendingCandidate, decodeCompact(corrupt[0..encoded.len]));
}

test "cold business wrong proof bindings retain pending input and original cursor" {
    var objects = TestObjects{};
    defer objects.deinit();
    const root = try objects.publish(0);
    const original = testOriginal();
    const pending = try begin(original, testRequest(original, root, 11), root);
    const result = try history.query(objects.interface(), root, pending.request);
    for (0..7) |case| {
        var wrong = result.proof;
        switch (case) {
            0 => wrong.request.root_digest[0] ^= 1,
            1 => wrong.request.epoch += 1,
            2 => wrong.request.barrier += 1,
            3 => wrong.request.pending_id += 1,
            4 => wrong.request.key.identity = .{ .report = 12 },
            5 => wrong.request.candidate_payload_digest[0] ^= 1,
            6 => wrong.request.original_input_digest[0] ^= 1,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidHistoryProof, pending.finalize(&wrong, root));
        try std.testing.expectEqualDeep(testRequest(original, root, 11), pending.request);
        try std.testing.expectEqualSlices(u8, original.payload, pending.originalRecord().payload);
        try std.testing.expectEqual(@as(u64, 13), pending.originalRecord().sequence);
    }
    var changed_root = root;
    changed_root.generation += 1;
    changed_root.root_digest = history.rootDigest(changed_root);
    try std.testing.expectError(error.InvalidHistoryProof, pending.finalize(&result.proof, changed_root));
    var corrupt = pending;
    corrupt.original_bytes[1] ^= 1;
    try std.testing.expectError(error.InvalidPendingCandidate, corrupt.finalize(&result.proof, root));
    corrupt = pending;
    corrupt.original.receive_time += 1;
    try std.testing.expectError(error.InvalidPendingCandidate, corrupt.finalize(&result.proof, root));
}

test "cold business conflict covered first and expired verdicts never apply or consume original input" {
    var objects = TestObjects{};
    defer objects.deinit();
    const root = try objects.publish(0);
    const original = testOriginal();
    var conflict_request = testRequest(original, root, 11);
    conflict_request.candidate_payload_digest = history.hash("conflicting report body");
    const conflict = try begin(original, conflict_request, root);
    const conflicting_proof = try history.query(objects.interface(), root, conflict.request);
    try std.testing.expectEqual(history.Verdict.conflict, try conflict.finalize(&conflicting_proof.proof, root));
    try std.testing.expectEqual(@as(u64, 13), conflict.originalRecord().sequence);
    const first = try begin(original, testRequest(original, root, 12), root);
    const missing_proof = try history.query(objects.interface(), root, first.request);
    try std.testing.expectEqual(history.Verdict.proven_first, try first.finalize(&missing_proof.proof, root));
    try std.testing.expectEqualSlices(u8, original.payload, first.originalRecord().payload);
    const advanced = try objects.publish(5);
    const expired = try begin(original, testRequest(original, advanced, 12), advanced);
    const expired_proof = try history.query(objects.interface(), advanced, expired.request);
    try std.testing.expectEqual(history.Verdict.expired, try expired.finalize(&expired_proof.proof, advanced));
    try std.testing.expectEqualSlices(u8, original.payload, expired.originalRecord().payload);
}

test "cold business begin rejects mismatched original root epoch barrier and capacity" {
    var objects = TestObjects{};
    defer objects.deinit();
    const root = try objects.publish(0);
    const original = testOriginal();
    for (0..5) |case| {
        var wrong = testRequest(original, root, 11);
        switch (case) {
            0 => wrong.original_input_digest[0] ^= 1,
            1 => wrong.root_digest[0] ^= 1,
            2 => wrong.epoch += 1,
            3 => wrong.barrier += 1,
            4 => wrong.key.origin.account += 1,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidPendingCandidate, begin(original, wrong, root));
    }
    var oversized = original;
    const bytes: [max_original_input_size + 1]u8 = @splat(1);
    oversized.payload = &bytes;
    try std.testing.expectError(error.InvalidPendingCandidate, begin(oversized, testRequest(oversized, root, 11), root));
}
