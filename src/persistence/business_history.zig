//! Order-history identity contract and pure authenticated-page verification.
const std = @import("std");
const durable = @import("durable_store.zig");
const canonical = @import("../model/canonical_event.zig");
const codec = @import("snapshot_codec.zig");
pub const Digest = [32]u8;
pub const page_bytes = 4096;
pub const max_record_bytes = 16 * 1024;
pub const max_depth = 8;
const fanout = 48;
const key_bytes = 82;
pub const DomainOrigin = struct { identity: u128, deployment: u128, epoch: u64, configuration_digest: Digest };
pub const OriginScope = union(enum(u8)) { account, decision_domain: DomainOrigin };
pub const Origin = struct {
    stream: durable.StreamIdentity,
    account: u128,
    scope: OriginScope = .account,
};
pub const GatewayHistoryIdentity = struct { shard: u8, command: u64 };
pub const Identity = union(enum) {
    intent: struct { strategy: u128, sequence: u64 },
    group: struct { strategy: u128, first_sequence: u64 },
    order: u64,
    command: u64,
    client_order_id: canonical.ClientOrderId,
    report: u128,
    reconciliation: u128,
    dispatch_command: u64,
    dispatch_result: struct { command: u64, state: canonical.DispatchState },
    canonical_fill: u64,
    core_fill: u64,
    fill_detail: u64,
    fill_economic_digest: u64,
    canonical_funding: u64,
    core_funding: u64,
    funding_detail: u64,
    funding_economic_digest: u64,
    reconciliation_window: u128,
    canonical_account_reconciliation: u128,
    operational_command: u128,
    retired_gate: u128,
    resolved_latch: u128,
    strategy_fence: u128,
    control_archive: u64,
    version_activation: u128,
    coordinator_forced_source: u128,
    coordinator_forced_allocation: u128,
    coordinator_gateway_command: GatewayHistoryIdentity,
    coordinator_account_fact: u128,
    core_forced: u128,
    forced_detail: u128,
    forced_economic_digest: u128,
    coordinator_gateway_closure: GatewayHistoryIdentity,
    cycle: u128,
    deployment_configuration: u128,
};
pub const Key = struct { origin: Origin, account: ?u128 = null, identity: Identity };

pub fn scopedKey(origin: Origin, identity: Identity, account: ?u128) !Key {
    const domain_identity = switch (identity) {
        .intent, .group, .cycle, .deployment_configuration, .operational_command, .retired_gate, .resolved_latch, .strategy_fence, .control_archive => true,
        else => false,
    };
    const key: Key = .{ .origin = origin, .identity = identity, .account = if (origin.scope == .decision_domain and !domain_identity) account else null };
    if (origin.scope == .account and account != null and account.? != origin.account) return error.InvalidHistoryKey;
    _ = try encodeKey(key);
    return key;
}

pub fn validOrigin(origin: Origin) bool {
    if ((origin.stream.domain != .decision_log and origin.stream.domain != .control) or origin.stream.id == 0) return false;
    return switch (origin.scope) {
        .account => origin.account != 0,
        .decision_domain => |domain| origin.account == 0 and origin.stream.domain == .decision_log and domain.identity != 0 and domain.deployment != 0 and domain.epoch != 0 and !std.mem.allEqual(u8, &domain.configuration_digest, 0),
    };
}
pub const Root = struct {
    version: u16 = 2,
    origin: Origin,
    generation: u64,
    barrier: u64,
    epoch: u64,
    floor: u64 = 0,
    retired: bool = false,
    tree_offset: u64,
    tree_digest: Digest,
    previous_root: Digest,
    batch_digest: Digest,
    qualification_digest: Digest,
    root_digest: Digest,
};
pub const Record = struct { bytes: []const u8, payload_digest: Digest };
pub const Entry = struct { key: Key, record_index: u32 };
pub const Batch = struct {
    origin: Origin,
    previous_root: ?Root = null,
    barrier: u64,
    epoch: u64,
    floor: u64 = 0,
    retired: bool = false,
    qualification_digest: Digest,
    records: []const Record,
    entries: []const Entry,
};
pub const Receipt = struct { root: Root, previous_root: Digest, qualification_digest: Digest, batch_digest: Digest };
pub const LookupRequest = struct {
    pending_id: u128,
    key: Key,
    candidate_payload_digest: Digest,
    original_input_digest: Digest,
    root_digest: Digest,
    epoch: u64,
    barrier: u64,
};
pub const Verdict = enum { same, conflict, proven_first, expired };
pub const EncodedKey = struct { len: u8 = 0, bytes: [key_bytes]u8 = @splat(0) };
pub const Item = struct {
    lower: EncodedKey = .{},
    upper: EncodedKey = .{},
    digest: Digest = @splat(0),
    offset: u64 = 0,
    length: u32 = 0,
};
pub const Witness = struct {
    level: u8 = 0,
    count: u8 = 0,
    slot: u8 = 0,
    item: Item = .{},
    siblings: [6]Digest = @splat(@splat(0)),
};
pub const LookupProof = struct {
    request: LookupRequest,
    root: Root,
    path: [max_depth]Witness = @splat(.{}),
    path_len: u8 = 0,
    lower: ?Witness = null,
    upper: ?Witness = null,
    leaf_count: u8 = 0,
};
pub const LookupResult = struct {
    proof: LookupProof,
    record_len: u32 = 0,
    record_bytes: [max_record_bytes]u8 = @splat(0),
};
pub fn hash(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn verifyResult(request: LookupRequest, proof: *const LookupProof, root: Root) !Verdict {
    try validateRoot(root);
    if (!std.meta.eql(request, proof.request) or !std.meta.eql(root, proof.root) or
        !std.meta.eql(request.key.origin, root.origin) or
        !std.mem.eql(u8, &request.root_digest, &root.root_digest) or
        request.epoch != root.epoch or request.barrier != root.barrier or
        request.pending_id == 0 or proof.path_len > max_depth or proof.leaf_count > fanout)
        return error.InvalidHistoryProof;
    const key = try encodeKey(request.key);
    var expected = root.tree_digest;
    var open_upper = true;
    var previous_level: ?u8 = null;
    for (proof.path[0..proof.path_len]) |witness| {
        if (witness.level == 0 or (previous_level != null and witness.level + 1 != previous_level.?) or
            !std.mem.eql(u8, &expected, &try witnessRoot(witness)) or
            (witness.item.lower.len != 0 and compare(key, witness.item.lower) != .gt) or
            (compare(key, witness.item.upper) == .gt and !(open_upper and witness.slot + 1 == witness.count))) return error.InvalidHistoryProof;
        open_upper = open_upper and witness.slot + 1 == witness.count;
        expected = witness.item.digest;
        previous_level = witness.level;
    }
    if (previous_level != null and previous_level.? != 1) return error.InvalidHistoryProof;
    if (proof.leaf_count == 0) {
        const empty: Node = .{};
        if (proof.lower != null or proof.upper != null or
            !std.mem.eql(u8, &expected, &nodeDigest(empty))) return error.InvalidHistoryProof;
    } else {
        if (proof.lower == null and proof.upper == null) return error.InvalidHistoryProof;
        if (proof.lower) |lower| {
            if (lower.level != 0 or lower.count != proof.leaf_count or
                !std.mem.eql(u8, &expected, &try witnessRoot(lower)) or compare(lower.item.upper, key) == .gt)
                return error.InvalidHistoryProof;
            if (compare(lower.item.upper, key) == .eq) {
                if (proof.upper != null or lower.item.length > max_record_bytes) return error.InvalidHistoryProof;
                return if (std.mem.eql(u8, &request.candidate_payload_digest, &lower.item.digest)) .same else .conflict;
            }
        }
        if (proof.upper) |upper| {
            if (upper.level != 0 or upper.count != proof.leaf_count or
                !std.mem.eql(u8, &expected, &try witnessRoot(upper)) or compare(upper.item.upper, key) != .gt)
                return error.InvalidHistoryProof;
        }
        if (proof.lower) |lower| {
            if (proof.upper) |upper| {
                if (upper.slot != lower.slot + 1) return error.InvalidHistoryProof;
            } else if (lower.slot + 1 != lower.count) return error.InvalidHistoryProof;
        } else if (proof.upper.?.slot != 0) return error.InvalidHistoryProof;
    }
    // Without a kind-specific fresh-identity boundary, absence after retention
    // has advanced is unprovable. Never interpret a missing old id as new.
    if (root.retired or root.floor != 0) return .expired;
    return .proven_first;
}

pub fn rootDigest(root: Root) Digest {
    var copy = root;
    copy.root_digest = @splat(0);
    var bytes: [1024]u8 = undefined;
    return hash(codec.encodeBare(&bytes, copy) catch unreachable);
}

pub fn validateRoot(root: Root) !void {
    if (root.version != 2 or !validOrigin(root.origin) or
        root.generation == 0 or root.barrier == 0 or root.epoch == 0 or
        !std.mem.eql(u8, &root.root_digest, &rootDigest(root))) return error.InvalidHistoryRoot;
}

pub fn verifyReceipt(receipt: Receipt, origin: Origin, qualification: Digest, previous: ?Root) !Root {
    try validateRoot(receipt.root);
    const previous_digest: Digest = if (previous) |old| old.root_digest else @splat(0);
    if (!std.meta.eql(receipt.root.origin, origin) or
        !std.mem.eql(u8, &receipt.previous_root, &previous_digest) or
        !std.mem.eql(u8, &receipt.root.previous_root, &previous_digest) or
        !std.mem.eql(u8, &receipt.qualification_digest, &qualification) or
        !std.mem.eql(u8, &receipt.root.qualification_digest, &qualification) or
        !std.mem.eql(u8, &receipt.batch_digest, &receipt.root.batch_digest)) return error.InvalidHistoryReceipt;
    if (previous) |old| {
        try validateRoot(old);
        if (!std.meta.eql(old.origin, origin) or receipt.root.generation != try std.math.add(u64, old.generation, 1) or
            receipt.root.barrier < old.barrier or receipt.root.epoch < old.epoch or receipt.root.floor < old.floor or
            (old.retired and !receipt.root.retired)) return error.InvalidHistoryReceipt;
    } else if (receipt.root.generation != 1) return error.InvalidHistoryReceipt;
    return receipt.root;
}

pub fn validateRecord(result: *const LookupResult) !void {
    const witness = result.proof.lower orelse return error.HistoryRecordAbsent;
    const key = try encodeKey(result.proof.request.key);
    if (compare(witness.item.upper, key) != .eq or result.record_len != witness.item.length or
        result.record_len > max_record_bytes or !std.mem.eql(u8, &hash(result.record_bytes[0..result.record_len]), &witness.item.digest))
        return error.InvalidHistoryRecord;
}

pub fn encodeKey(key: Key) !EncodedKey {
    if (!validOrigin(key.origin)) return error.InvalidHistoryKey;
    var account = key.origin.account;
    switch (key.origin.scope) {
        .account => if (key.account != null) return error.InvalidHistoryKey,
        .decision_domain => switch (key.identity) {
            .intent, .group, .cycle, .deployment_configuration, .operational_command, .retired_gate, .resolved_latch, .strategy_fence, .control_archive => if (key.account != null) return error.InvalidHistoryKey,
            else => {
                account = key.account orelse return error.InvalidHistoryKey;
                if (account == 0) return error.InvalidHistoryKey;
            },
        },
    }
    switch (key.identity) {
        .coordinator_forced_source, .coordinator_forced_allocation, .coordinator_gateway_command, .coordinator_gateway_closure, .coordinator_account_fact, .version_activation => {
            if (key.origin.stream.domain != .control) return error.InvalidHistoryKey;
        },
        else => if (key.origin.stream.domain != .decision_log) return error.InvalidHistoryKey,
    }
    var result: EncodedKey = .{};
    std.mem.writeInt(u128, result.bytes[0..16], account, .big);
    result.bytes[16] = @intFromEnum(std.meta.activeTag(key.identity));
    result.len = 17;
    switch (key.identity) {
        .intent => |v| {
            std.mem.writeInt(u128, result.bytes[17..33], v.strategy, .big);
            std.mem.writeInt(u64, result.bytes[33..41], v.sequence, .big);
            result.len = 41;
        },
        .group => |v| {
            std.mem.writeInt(u128, result.bytes[17..33], v.strategy, .big);
            std.mem.writeInt(u64, result.bytes[33..41], v.first_sequence, .big);
            result.len = 41;
        },
        .coordinator_gateway_command, .coordinator_gateway_closure => |v| {
            result.bytes[17] = v.shard;
            std.mem.writeInt(u64, result.bytes[18..26], v.command, .big);
            result.len = 26;
        },
        .dispatch_result => |v| {
            std.mem.writeInt(u64, result.bytes[17..25], v.command, .big);
            result.bytes[25] = @intFromEnum(v.state);
            result.len = 26;
        },
        .order, .command, .dispatch_command, .canonical_fill, .core_fill, .fill_detail, .fill_economic_digest, .canonical_funding, .core_funding, .funding_detail, .funding_economic_digest, .control_archive => |v| {
            std.mem.writeInt(u64, result.bytes[17..25], v, .big);
            result.len = 25;
        },
        .report, .reconciliation, .reconciliation_window, .canonical_account_reconciliation, .operational_command, .retired_gate, .resolved_latch, .strategy_fence, .version_activation, .coordinator_forced_source, .coordinator_forced_allocation, .coordinator_account_fact, .core_forced, .forced_detail, .forced_economic_digest, .cycle, .deployment_configuration => |v| {
            std.mem.writeInt(u128, result.bytes[17..33], v, .big);
            result.len = 33;
        },
        .client_order_id => |v| {
            if (v.len == 0 or v.len > v.bytes.len) return error.InvalidHistoryKey;
            @memcpy(result.bytes[17..][0..v.len], v.slice());
            result.len = @intCast(17 + @as(usize, v.len));
        },
    }
    return result;
}

fn compare(a: EncodedKey, b: EncodedKey) std.math.Order {
    return std.mem.order(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
}

fn within(key: EncodedKey, lower: EncodedKey, upper: EncodedKey) bool {
    return (lower.len == 0 or compare(key, lower) == .gt) and (upper.len == 0 or compare(key, upper) != .gt);
}

const Node = struct {
    level: u8 = 0,
    count: u8 = 0,
    items: [fanout]Item = @splat(.{}),
};

fn itemDigest(item: Item) Digest {
    var bytes: [256]u8 = undefined;
    var cursor: usize = 0;
    encodeItem(&bytes, &cursor, item) catch unreachable;
    return hash(bytes[0..cursor]);
}

fn pairDigest(a: Digest, b: Digest) Digest {
    var bytes: [65]u8 = undefined;
    bytes[0] = 1;
    @memcpy(bytes[1..33], &a);
    @memcpy(bytes[33..65], &b);
    return hash(&bytes);
}

fn leafHashes(node: Node) [64]Digest {
    var leaves: [64]Digest = @splat(hash("Ringwin.OrderHistory.EmptySlot.V1"));
    for (node.items[0..node.count], 0..) |item, i| leaves[i] = itemDigest(item);
    return leaves;
}

fn pageDigest(level: u8, count: u8, merkle: Digest) Digest {
    var bytes: [60]u8 = undefined;
    @memcpy(bytes[0..26], "Ringwin.OrderHistory.Page1");
    bytes[26] = level;
    bytes[27] = count;
    @memcpy(bytes[28..60], &merkle);
    return hash(&bytes);
}

fn nodeDigest(node: Node) Digest {
    var leaves = leafHashes(node);
    var count: usize = 64;
    while (count > 1) {
        for (0..count / 2) |i| leaves[i] = pairDigest(leaves[2 * i], leaves[2 * i + 1]);
        count /= 2;
    }
    return pageDigest(node.level, node.count, leaves[0]);
}

fn witnessFor(node: Node, slot: usize) Witness {
    var result: Witness = .{ .level = node.level, .count = node.count, .slot = @intCast(slot), .item = node.items[slot] };
    var leaves = leafHashes(node);
    var index = slot;
    var count: usize = 64;
    for (0..6) |depth| {
        result.siblings[depth] = leaves[index ^ 1];
        for (0..count / 2) |i| leaves[i] = pairDigest(leaves[2 * i], leaves[2 * i + 1]);
        index /= 2;
        count /= 2;
    }
    return result;
}

fn witnessRoot(witness: Witness) !Digest {
    if (witness.count == 0 or witness.count > fanout or witness.slot >= witness.count or
        witness.item.lower.len > key_bytes or witness.item.upper.len == 0 or witness.item.upper.len > key_bytes)
        return error.InvalidHistoryProof;
    var digest_value = itemDigest(witness.item);
    var index = witness.slot;
    for (witness.siblings) |sibling| {
        digest_value = if (index & 1 == 0) pairDigest(digest_value, sibling) else pairDigest(sibling, digest_value);
        index /= 2;
    }
    return pageDigest(witness.level, witness.count, digest_value);
}

fn encodeItem(bytes: []u8, cursor: *usize, item: Item) !void {
    const required = 2 + @as(usize, item.lower.len) + item.upper.len + 44;
    if (cursor.* + required > bytes.len) return error.HistoryPageFull;
    for ([_]EncodedKey{ item.lower, item.upper }) |key| {
        bytes[cursor.*] = key.len;
        cursor.* += 1;
        @memcpy(bytes[cursor.*..][0..key.len], key.bytes[0..key.len]);
        cursor.* += key.len;
    }
    @memcpy(bytes[cursor.*..][0..32], &item.digest);
    cursor.* += 32;
    std.mem.writeInt(u64, bytes[cursor.*..][0..8], item.offset, .little);
    cursor.* += 8;
    std.mem.writeInt(u32, bytes[cursor.*..][0..4], item.length, .little);
    cursor.* += 4;
}

fn decodeItem(bytes: []const u8, cursor: *usize) !Item {
    var item: Item = .{};
    for ([_]*EncodedKey{ &item.lower, &item.upper }) |key| {
        if (cursor.* >= bytes.len) return error.InvalidHistoryPage;
        key.len = bytes[cursor.*];
        cursor.* += 1;
        if (key.len > key_bytes or cursor.* + key.len > bytes.len) return error.InvalidHistoryPage;
        @memcpy(key.bytes[0..key.len], bytes[cursor.*..][0..key.len]);
        cursor.* += key.len;
    }
    if (cursor.* + 44 > bytes.len) return error.InvalidHistoryPage;
    @memcpy(&item.digest, bytes[cursor.*..][0..32]);
    cursor.* += 32;
    item.offset = std.mem.readInt(u64, bytes[cursor.*..][0..8], .little);
    cursor.* += 8;
    item.length = std.mem.readInt(u32, bytes[cursor.*..][0..4], .little);
    cursor.* += 4;
    return item;
}

fn writeNode(objects: Objects, node: Node) !Item {
    var bytes: [page_bytes]u8 = @splat(0);
    @memcpy(bytes[0..8], "RWOHBP01");
    bytes[8] = node.level;
    bytes[9] = node.count;
    var cursor: usize = 16;
    for (node.items[0..node.count]) |item| try encodeItem(&bytes, &cursor, item);
    std.mem.writeInt(u16, bytes[10..12], @intCast(cursor), .little);
    return .{ .upper = if (node.count == 0) .{} else node.items[node.count - 1].upper, .digest = nodeDigest(node), .offset = try objects.write(&bytes), .length = page_bytes };
}

fn readNode(objects: Objects, offset: u64, expected: Digest) !Node {
    var bytes: [page_bytes]u8 = undefined;
    if (try objects.read(offset, &bytes) != page_bytes or !std.mem.eql(u8, bytes[0..8], "RWOHBP01") or
        bytes[9] > fanout or bytes[8] > max_depth) return error.InvalidHistoryPage;
    const end = std.mem.readInt(u16, bytes[10..12], .little);
    if (end < 16 or end > page_bytes or !std.mem.allEqual(u8, bytes[12..16], 0) or
        !std.mem.allEqual(u8, bytes[end..], 0)) return error.InvalidHistoryPage;
    var node: Node = .{ .level = bytes[8], .count = bytes[9] };
    var cursor: usize = 16;
    for (node.items[0..node.count], 0..) |*item, i| {
        item.* = try decodeItem(bytes[0..end], &cursor);
        if (item.upper.len == 0 or (i > 0 and compare(node.items[i - 1].upper, item.upper) != .lt)) return error.InvalidHistoryPage;
        if (node.level == 0 and item.lower.len != 0) return error.InvalidHistoryPage;
        if (node.level != 0 and i > 0 and compare(item.lower, node.items[i - 1].upper) != .eq) return error.InvalidHistoryPage;
    }
    if (cursor != end or !std.mem.eql(u8, &expected, &nodeDigest(node))) return error.InvalidHistoryPage;
    return node;
}

pub fn verifyStoredRoot(objects: Objects, root: Root) !void {
    try validateRoot(root);
    _ = try readNode(objects, root.tree_offset, root.tree_digest);
}

pub fn query(objects: Objects, root: Root, request: LookupRequest) !LookupResult {
    try validateRoot(root);
    if (!std.meta.eql(request.key.origin, root.origin) or !std.mem.eql(u8, &request.root_digest, &root.root_digest) or
        request.epoch != root.epoch or request.barrier != root.barrier) return error.StaleHistoryRequest;
    const key = try encodeKey(request.key);
    var result: LookupResult = .{ .proof = .{ .request = request, .root = root } };
    var offset = root.tree_offset;
    var digest_value = root.tree_digest;
    while (true) {
        const node = try readNode(objects, offset, digest_value);
        if (node.level == 0) {
            result.proof.leaf_count = node.count;
            for (node.items[0..node.count], 0..) |item, i| {
                switch (compare(item.upper, key)) {
                    .lt => result.proof.lower = witnessFor(node, i),
                    .eq => {
                        result.proof.lower = witnessFor(node, i);
                        result.proof.upper = null;
                        if (item.length > max_record_bytes or try objects.read(item.offset, result.record_bytes[0..item.length]) != item.length or
                            !std.mem.eql(u8, &hash(result.record_bytes[0..item.length]), &item.digest)) return error.InvalidHistoryRecord;
                        result.record_len = item.length;
                        return result;
                    },
                    .gt => {
                        result.proof.upper = witnessFor(node, i);
                        break;
                    },
                }
            }
            return result;
        }
        if (result.proof.path_len == max_depth or node.count == 0) return error.HistoryDepthExceeded;
        var selected: usize = node.count - 1;
        for (node.items[0..node.count], 0..) |item, i| if (compare(key, item.upper) != .gt) {
            selected = i;
            break;
        };
        const witness = witnessFor(node, selected);
        result.proof.path[result.proof.path_len] = witness;
        result.proof.path_len += 1;
        offset = witness.item.offset;
        digest_value = witness.item.digest;
    }
}

// Storage callbacks are peripheral; proof verification never receives them.
pub const Objects = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, u64, []u8) anyerror!usize,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!u64,
    pub fn read(self: Objects, offset: u64, bytes: []u8) !usize {
        return self.read_fn(self.context, offset, bytes);
    }
    pub fn write(self: Objects, bytes: []const u8) !u64 {
        return self.write_fn(self.context, bytes);
    }
};

pub const max_batch_keys = 256;
const branch_fanout = 16;
const Split = struct {
    items: [max_batch_keys + fanout]Item = @splat(.{}),
    count: usize = 0,
};

pub fn batchDigest(batch: Batch) !Digest {
    var state = std.crypto.hash.sha2.Sha256.init(.{});
    state.update("Ringwin.OrderHistory.Batch.V1");
    var metadata: [512]u8 = undefined;
    state.update(try codec.encodeBare(&metadata, .{
        .origin = batch.origin,
        .previous = if (batch.previous_root) |root| root.root_digest else @as(Digest, @splat(0)),
        .barrier = batch.barrier,
        .epoch = batch.epoch,
        .floor = batch.floor,
        .retired = batch.retired,
        .qualification = batch.qualification_digest,
        .record_count = @as(u64, batch.records.len),
        .entry_count = @as(u64, batch.entries.len),
    }));
    for (batch.records) |record| {
        if (record.bytes.len == 0 or record.bytes.len > max_record_bytes or !std.mem.eql(u8, &hash(record.bytes), &record.payload_digest))
            return error.InvalidHistoryRecord;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(record.bytes.len), .little);
        state.update(&length);
        state.update(&record.payload_digest);
    }
    for (batch.entries) |entry| {
        if (!std.meta.eql(entry.key.origin, batch.origin) or entry.record_index >= batch.records.len) return error.InvalidHistoryKey;
        const key = try encodeKey(entry.key);
        state.update(&.{key.len});
        state.update(key.bytes[0..key.len]);
        var index: [4]u8 = undefined;
        std.mem.writeInt(u32, &index, entry.record_index, .little);
        state.update(&index);
    }
    var result: Digest = undefined;
    state.final(&result);
    return result;
}

pub fn publish(objects: Objects, batch: Batch) !Receipt {
    if (!validOrigin(batch.origin) or
        batch.barrier == 0 or batch.epoch == 0 or batch.entries.len == 0 or batch.entries.len > max_batch_keys or
        batch.records.len > max_batch_keys or batch.floor > batch.barrier) return error.InvalidHistoryBatch;
    const batch_digest = try batchDigest(batch);
    if (batch.previous_root) |previous| {
        try validateRoot(previous);
        if (!std.meta.eql(previous.origin, batch.origin) or batch.barrier < previous.barrier or batch.epoch < previous.epoch or
            batch.floor < previous.floor or (previous.retired and !batch.retired)) return error.InvalidHistoryBatch;
    }
    var offsets: [max_batch_keys]u64 = undefined;
    for (batch.records, 0..) |record, i| offsets[i] = try objects.write(record.bytes);
    var incoming: [max_batch_keys]Item = undefined;
    for (batch.entries, 0..) |entry, i| {
        const record = batch.records[entry.record_index];
        incoming[i] = .{ .upper = try encodeKey(entry.key), .digest = record.payload_digest, .offset = offsets[entry.record_index], .length = @intCast(record.bytes.len) };
    }
    std.mem.sort(Item, incoming[0..batch.entries.len], {}, struct {
        fn less(_: void, a: Item, b: Item) bool {
            return compare(a.upper, b.upper) == .lt;
        }
    }.less);
    for (incoming[0..batch.entries.len], 0..) |item, i| {
        if (i > 0 and compare(incoming[i - 1].upper, item.upper) == .eq) return error.DuplicateHistoryBatchKey;
    }
    var old: Node = .{};
    if (batch.previous_root) |previous| old = try readNode(objects, previous.tree_offset, previous.tree_digest);
    var replacement = try mergeNode(objects, old, incoming[0..batch.entries.len]);
    var level = old.level;
    while (replacement.count > 1) {
        level = try std.math.add(u8, level, 1);
        if (level > max_depth) return error.HistoryDepthExceeded;
        replacement = try packNodes(objects, level, replacement.items[0..replacement.count], .{});
    }
    const previous_digest: Digest = if (batch.previous_root) |previous| previous.root_digest else @splat(0);
    var root: Root = .{
        .origin = batch.origin,
        .generation = if (batch.previous_root) |previous| try std.math.add(u64, previous.generation, 1) else 1,
        .barrier = batch.barrier,
        .epoch = batch.epoch,
        .floor = batch.floor,
        .retired = batch.retired,
        .tree_offset = replacement.items[0].offset,
        .tree_digest = replacement.items[0].digest,
        .previous_root = previous_digest,
        .batch_digest = batch_digest,
        .qualification_digest = batch.qualification_digest,
        .root_digest = @splat(0),
    };
    root.root_digest = rootDigest(root);
    return .{ .root = root, .previous_root = previous_digest, .qualification_digest = batch.qualification_digest, .batch_digest = batch_digest };
}

pub fn verifyBatch(objects: Objects, receipt: Receipt, batch: Batch) !void {
    const root = try verifyReceipt(receipt, batch.origin, batch.qualification_digest, batch.previous_root);
    if (!std.mem.eql(u8, &receipt.batch_digest, &try batchDigest(batch)) or
        root.barrier != batch.barrier or root.epoch != batch.epoch or root.floor != batch.floor or root.retired != batch.retired)
        return error.InvalidHistoryReceipt;
    for (batch.entries, 0..) |entry, index| {
        const request: LookupRequest = .{
            .pending_id = index + 1,
            .key = entry.key,
            .candidate_payload_digest = batch.records[entry.record_index].payload_digest,
            .original_input_digest = receipt.batch_digest,
            .root_digest = root.root_digest,
            .epoch = root.epoch,
            .barrier = root.barrier,
        };
        const result = try query(objects, root, request);
        if (try verifyResult(request, &result.proof, root) != .same) return error.HistoryBatchCoverageIncomplete;
        try validateRecord(&result);
    }
}

fn mergeNode(objects: Objects, node: Node, incoming: []const Item) anyerror!Split {
    var merged: [max_batch_keys + fanout]Item = undefined;
    var count: usize = 0;
    if (node.level == 0) {
        var old_index: usize = 0;
        var new_index: usize = 0;
        while (old_index < node.count or new_index < incoming.len) {
            if (old_index == node.count) {
                merged[count] = incoming[new_index];
                new_index += 1;
            } else if (new_index == incoming.len or compare(node.items[old_index].upper, incoming[new_index].upper) == .lt) {
                merged[count] = node.items[old_index];
                old_index += 1;
            } else if (compare(node.items[old_index].upper, incoming[new_index].upper) == .eq) {
                if (!std.mem.eql(u8, &node.items[old_index].digest, &incoming[new_index].digest)) return error.HistoryIdentityConflict;
                merged[count] = node.items[old_index];
                old_index += 1;
                new_index += 1;
            } else {
                merged[count] = incoming[new_index];
                new_index += 1;
            }
            count += 1;
        }
        return packNodes(objects, 0, merged[0..count], .{});
    }
    var start: usize = 0;
    for (node.items[0..node.count], 0..) |child, index| {
        var end = start;
        if (index + 1 == node.count) {
            end = incoming.len;
        } else while (end < incoming.len and compare(incoming[end].upper, child.upper) != .gt) : (end += 1) {}
        if (start == end) {
            merged[count] = child;
            count += 1;
        } else {
            const child_node = try readNode(objects, child.offset, child.digest);
            if (child_node.level + 1 != node.level) return error.InvalidHistoryPage;
            const split = try mergeNode(objects, child_node, incoming[start..end]);
            if (count + split.count > merged.len) return error.HistoryBatchTooLarge;
            @memcpy(merged[count..][0..split.count], split.items[0..split.count]);
            count += split.count;
        }
        start = end;
    }
    return packNodes(objects, node.level, merged[0..count], node.items[0].lower);
}

fn packNodes(objects: Objects, level: u8, items: []const Item, lower: EncodedKey) !Split {
    var result: Split = .{};
    const capacity: usize = if (level == 0) fanout else branch_fanout;
    var offset: usize = 0;
    var previous = lower;
    while (offset < items.len) {
        var node: Node = .{ .level = level };
        var encoded_len: usize = 16;
        while (offset < items.len and node.count < capacity) {
            var item = items[offset];
            if (level != 0) item.lower = previous;
            const length = 2 + @as(usize, item.lower.len) + item.upper.len + 44;
            if (length > page_bytes - encoded_len) break;
            encoded_len += length;
            node.items[node.count] = item;
            node.count += 1;
            previous = item.upper;
            offset += 1;
        }
        if (node.count == 0) return error.HistoryPageFull;
        result.items[result.count] = try writeNode(objects, node);
        result.count += 1;
    }
    return result;
}
