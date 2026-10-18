// Derived from Zig 0.17.0-dev.315+5b647b792; MIT, see LICENSE.
// https://datatracker.ietf.org/doc/rfc9106
// https://github.com/golang/crypto/tree/master/argon2
// https://github.com/P-H-C/phc-winner-argon2

const builtin = @import("builtin");

const std = @import("std");
const blake2 = @import("blake2b.zig");
const crypto = std.crypto;
const Io = std.Io;
const math = std.math;
const mem = std.mem;
const phc_format = pwhash.phc_format;
const pwhash = crypto.pwhash;
const Blake2b512 = blake2.Blake2b512;
const Blocks = std.array_list.AlignedManaged([block_length]u64, .@"16");
const H0 = [Blake2b512.digest_length + 8]u8;

const EncodingError = crypto.errors.EncodingError;
const KdfError = pwhash.KdfError;
const HasherError = pwhash.HasherError;
const Error = pwhash.Error;

const version = 0x13;
const block_length = 128;
const sync_points = 4;
const max_int = 0xffff_ffff;

const default_salt_len = 32;
const default_hash_len = 32;
const max_salt_len = 64;
const max_hash_len = 64;

/// Argon2 type
pub const Mode = enum {
    /// Argon2d is faster and uses data-depending memory access, which makes it highly resistant
    /// against GPU cracking attacks and suitable for applications with no threats from side-channel
    /// timing attacks (eg. cryptocurrencies).
    argon2d,

    /// Argon2i instead uses data-independent memory access, which is preferred for password
    /// hashing and password-based key derivation, but it is slower as it makes more passes over
    /// the memory to protect from tradeoff attacks.
    argon2i,

    /// Argon2id is a hybrid of Argon2i and Argon2d, using a combination of data-depending and
    /// data-independent memory accesses, which gives some of Argon2i's resistance to side-channel
    /// cache timing attacks and much of Argon2d's resistance to GPU cracking attacks.
    argon2id,
};

/// Argon2 parameters
pub const Params = struct {
    const Self = @This();

    /// Time cost, which defines the amount of computation realized and therefore the execution
    /// time, given in number of iterations.
    t: u32,

    /// Memory cost, which defines the memory usage, given in kibibytes.
    m: u32,

    /// Parallelism degree, which defines the number of independent tasks,
    /// to be multiplexed onto threads when possible.
    p: u24,

    /// The secret parameter, which is used for keyed hashing. This allows a secret key to be input
    /// at hashing time (from some external location) and be folded into the value of the hash. This
    /// means that even if your salts and hashes are compromised, an attacker cannot brute-force to
    /// find the password without the key.
    secret: ?[]const u8 = null,

    /// The ad parameter, which is used to fold any additional data into the hash value. Functionally,
    /// this behaves almost exactly like the secret or salt parameters; the ad parameter is folding
    /// into the value of the hash. However, this parameter is used for different data. The salt
    /// should be a random string stored alongside your password. The secret should be a random key
    /// only usable at hashing time. The ad is for any other data.
    ad: ?[]const u8 = null,

    /// Baseline parameters for interactive logins using argon2i type
    pub const interactive_2i = Self.fromLimits(4, 33554432);
    /// Baseline parameters for normal usage using argon2i type
    pub const moderate_2i = Self.fromLimits(6, 134217728);
    /// Baseline parameters for offline usage using argon2i type
    pub const sensitive_2i = Self.fromLimits(8, 536870912);

    /// Baseline parameters for interactive logins using argon2id type
    pub const interactive_2id = Self.fromLimits(2, 67108864);
    /// Baseline parameters for normal usage using argon2id type
    pub const moderate_2id = Self.fromLimits(3, 268435456);
    /// Baseline parameters for offline usage using argon2id type
    pub const sensitive_2id = Self.fromLimits(4, 1073741824);

    /// Recommended parameters for argon2id type according to the
    /// [OWASP cheat sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
    pub const owasp_2id = Self{ .t = 2, .m = 19 * 1024, .p = 1 };

    /// Create parameters from ops and mem limits, where mem_limit given in bytes
    pub fn fromLimits(ops_limit: u32, mem_limit: usize) Self {
        const m = mem_limit / 1024;
        std.debug.assert(m <= max_int);
        return .{ .t = ops_limit, .m = @as(u32, @intCast(m)), .p = 1 };
    }
};

fn initHash(
    password: []const u8,
    salt: []const u8,
    params: Params,
    dk_len: usize,
    mode: Mode,
) H0 {
    var h0: H0 = undefined;
    defer crypto.secureZero(u8, &h0);
    var parameters: [24]u8 = undefined;
    var tmp: [4]u8 = undefined;
    var b2 = Blake2b512.init(.{});
    defer crypto.secureZero(u8, mem.asBytes(&b2));
    mem.writeInt(u32, parameters[0..4], params.p, .little);
    mem.writeInt(u32, parameters[4..8], @as(u32, @intCast(dk_len)), .little);
    mem.writeInt(u32, parameters[8..12], params.m, .little);
    mem.writeInt(u32, parameters[12..16], params.t, .little);
    mem.writeInt(u32, parameters[16..20], version, .little);
    mem.writeInt(u32, parameters[20..24], @intFromEnum(mode), .little);
    b2.update(&parameters);
    mem.writeInt(u32, &tmp, @as(u32, @intCast(password.len)), .little);
    b2.update(&tmp);
    b2.update(password);
    mem.writeInt(u32, &tmp, @as(u32, @intCast(salt.len)), .little);
    b2.update(&tmp);
    b2.update(salt);
    const secret = params.secret orelse "";
    std.debug.assert(secret.len <= max_int);
    mem.writeInt(u32, &tmp, @as(u32, @intCast(secret.len)), .little);
    b2.update(&tmp);
    b2.update(secret);
    const ad = params.ad orelse "";
    std.debug.assert(ad.len <= max_int);
    mem.writeInt(u32, &tmp, @as(u32, @intCast(ad.len)), .little);
    b2.update(&tmp);
    b2.update(ad);
    b2.final(h0[0..Blake2b512.digest_length]);
    return h0;
}

fn blake2bLong(out: []u8, in: []const u8) void {
    const H = Blake2b512;
    var outlen_bytes: [4]u8 = undefined;
    mem.writeInt(u32, &outlen_bytes, @as(u32, @intCast(out.len)), .little);

    var out_buf: [H.digest_length]u8 = undefined;
    defer crypto.secureZero(u8, &out_buf);

    if (out.len <= H.digest_length) {
        var h = H.init(.{ .expected_out_bits = out.len * 8 });
        defer crypto.secureZero(u8, mem.asBytes(&h));
        h.update(&outlen_bytes);
        h.update(in);
        h.final(&out_buf);
        @memcpy(out, out_buf[0..out.len]);
        return;
    }

    var h = H.init(.{});
    defer crypto.secureZero(u8, mem.asBytes(&h));
    h.update(&outlen_bytes);
    h.update(in);
    h.final(&out_buf);
    var out_slice = out;
    out_slice[0 .. H.digest_length / 2].* = out_buf[0 .. H.digest_length / 2].*;
    out_slice = out_slice[H.digest_length / 2 ..];

    var in_buf: [H.digest_length]u8 = undefined;
    defer crypto.secureZero(u8, &in_buf);
    while (out_slice.len > H.digest_length) {
        in_buf = out_buf;
        H.hash(&in_buf, &out_buf, .{});
        out_slice[0 .. H.digest_length / 2].* = out_buf[0 .. H.digest_length / 2].*;
        out_slice = out_slice[H.digest_length / 2 ..];
    }
    in_buf = out_buf;
    H.hash(&in_buf, &out_buf, .{ .expected_out_bits = out_slice.len * 8 });
    @memcpy(out_slice, out_buf[0..out_slice.len]);
}

fn initBlocks(
    blocks: *Blocks,
    h0: *H0,
    memory: u32,
    threads: u24,
) void {
    var block0: [1024]u8 = undefined;
    defer crypto.secureZero(u8, &block0);
    var lane: u24 = 0;
    while (lane < threads) : (lane += 1) {
        const j = lane * (memory / threads);
        mem.writeInt(u32, h0[Blake2b512.digest_length + 4 ..][0..4], lane, .little);

        mem.writeInt(u32, h0[Blake2b512.digest_length..][0..4], 0, .little);
        blake2bLong(&block0, h0);
        for (&blocks.items[j + 0], 0..) |*v, i| {
            v.* = mem.readInt(u64, block0[i * 8 ..][0..8], .little);
        }

        mem.writeInt(u32, h0[Blake2b512.digest_length..][0..4], 1, .little);
        blake2bLong(&block0, h0);
        for (&blocks.items[j + 1], 0..) |*v, i| {
            v.* = mem.readInt(u64, block0[i * 8 ..][0..8], .little);
        }
    }
}

fn processBlocks(
    blocks: *Blocks,
    time: u32,
    memory: u32,
    threads: u24,
    mode: Mode,
    io: Io,
) Io.Cancelable!void {
    const lanes = memory / threads;
    const segments = lanes / sync_points;

    if (builtin.single_threaded or threads == 1) {
        processBlocksSync(blocks, time, memory, threads, mode, lanes, segments);
    } else {
        try processBlocksAsync(blocks, time, memory, threads, mode, lanes, segments, io);
    }
}

fn processBlocksSync(
    blocks: *Blocks,
    time: u32,
    memory: u32,
    threads: u24,
    mode: Mode,
    lanes: u32,
    segments: u32,
) void {
    var n: u32 = 0;
    while (n < time) : (n += 1) {
        var slice: u32 = 0;
        while (slice < sync_points) : (slice += 1) {
            var lane: u24 = 0;
            while (lane < threads) : (lane += 1) {
                processSegment(blocks, time, memory, threads, mode, lanes, segments, n, slice, lane);
            }
        }
    }
}

fn processBlocksAsync(
    blocks: *Blocks,
    time: u32,
    memory: u32,
    threads: u24,
    mode: Mode,
    lanes: u32,
    segments: u32,
    io: Io,
) Io.Cancelable!void {
    var n: u32 = 0;
    while (n < time) : (n += 1) {
        var slice: u32 = 0;
        while (slice < sync_points) : (slice += 1) {
            var group: Io.Group = .init;
            defer group.cancel(io);
            var lane: u24 = 0;
            while (lane < threads) : (lane += 1) {
                group.async(io, processSegment, .{
                    blocks, time, memory, threads, mode, lanes, segments, n, slice, lane,
                });
            }
            try group.await(io);
        }
    }
}

fn processSegment(
    blocks: *Blocks,
    passes: u32,
    memory: u32,
    threads: u24,
    mode: Mode,
    lanes: u32,
    segments: u32,
    n: u32,
    slice: u32,
    lane: u24,
) void {
    var addresses: [block_length]u64 align(16) = @splat(0);
    defer crypto.secureZero(u64, &addresses);
    var in: [block_length]u64 align(16) = @splat(0);
    defer crypto.secureZero(u64, &in);
    const zero: [block_length]u64 align(16) = @splat(0);
    if (mode == .argon2i or (mode == .argon2id and n == 0 and slice < sync_points / 2)) {
        in[0] = n;
        in[1] = lane;
        in[2] = slice;
        in[3] = memory;
        in[4] = passes;
        in[5] = @intFromEnum(mode);
    }
    var index: u32 = 0;
    if (n == 0 and slice == 0) {
        index = 2;
        if (mode == .argon2i or mode == .argon2id) {
            in[6] += 1;
            processBlock(&addresses, &in, &zero);
            processBlock(&addresses, &addresses, &zero);
        }
    }
    var offset = lane * lanes + slice * segments + index;
    var random: u64 = 0;
    while (index < segments) : ({
        index += 1;
        offset += 1;
    }) {
        var prev = offset -% 1;
        if (index == 0 and slice == 0) {
            prev +%= lanes;
        }
        if (mode == .argon2i or (mode == .argon2id and n == 0 and slice < sync_points / 2)) {
            if (index % block_length == 0) {
                in[6] += 1;
                processBlock(&addresses, &in, &zero);
                processBlock(&addresses, &addresses, &zero);
            }
            random = addresses[index % block_length];
        } else {
            random = blocks.items[prev][0];
        }
        const new_offset = indexAlpha(random, lanes, segments, threads, n, slice, lane, index);
        processBlockXor(&blocks.items[offset], &blocks.items[prev], &blocks.items[new_offset]);
    }
}

fn processBlock(
    out: *align(16) [block_length]u64,
    in1: *align(16) const [block_length]u64,
    in2: *align(16) const [block_length]u64,
) void {
    processBlockGeneric(out, in1, in2, false);
}

fn processBlockXor(
    out: *[block_length]u64,
    in1: *const [block_length]u64,
    in2: *const [block_length]u64,
) void {
    processBlockGeneric(out, in1, in2, true);
}

fn processBlockGeneric(
    out: *[block_length]u64,
    in1: *const [block_length]u64,
    in2: *const [block_length]u64,
    comptime xor: bool,
) void {
    var t: [block_length]u64 = undefined;
    defer crypto.secureZero(u64, &t);
    for (&t, 0..) |*v, i| {
        v.* = in1[i] ^ in2[i];
    }
    var i: usize = 0;
    while (i < block_length) : (i += 16) {
        blamkaGeneric(t[i..][0..16]);
    }
    i = 0;
    var buffer: [16]u64 = undefined;
    defer crypto.secureZero(u64, &buffer);
    while (i < block_length / 8) : (i += 2) {
        var j: usize = 0;
        while (j < block_length / 8) : (j += 2) {
            buffer[j] = t[j * 8 + i];
            buffer[j + 1] = t[j * 8 + i + 1];
        }
        blamkaGeneric(&buffer);
        j = 0;
        while (j < block_length / 8) : (j += 2) {
            t[j * 8 + i] = buffer[j];
            t[j * 8 + i + 1] = buffer[j + 1];
        }
    }
    if (xor) {
        for (t, 0..) |v, j| {
            out[j] ^= in1[j] ^ in2[j] ^ v;
        }
    } else {
        for (t, 0..) |v, j| {
            out[j] = in1[j] ^ in2[j] ^ v;
        }
    }
}

const QuarterRound = struct { a: usize, b: usize, c: usize, d: usize };

fn Rp(a: usize, b: usize, c: usize, d: usize) QuarterRound {
    return .{ .a = a, .b = b, .c = c, .d = d };
}

fn fBlaMka(x: u64, y: u64) u64 {
    const xy = @as(u64, @as(u32, @truncate(x))) * @as(u64, @as(u32, @truncate(y)));
    return x +% y +% 2 *% xy;
}

fn blamkaGeneric(x: *[16]u64) void {
    const rounds = comptime [_]QuarterRound{
        Rp(0, 4, 8, 12),
        Rp(1, 5, 9, 13),
        Rp(2, 6, 10, 14),
        Rp(3, 7, 11, 15),
        Rp(0, 5, 10, 15),
        Rp(1, 6, 11, 12),
        Rp(2, 7, 8, 13),
        Rp(3, 4, 9, 14),
    };
    inline for (rounds) |r| {
        x[r.a] = fBlaMka(x[r.a], x[r.b]);
        x[r.d] = math.rotr(u64, x[r.d] ^ x[r.a], 32);
        x[r.c] = fBlaMka(x[r.c], x[r.d]);
        x[r.b] = math.rotr(u64, x[r.b] ^ x[r.c], 24);
        x[r.a] = fBlaMka(x[r.a], x[r.b]);
        x[r.d] = math.rotr(u64, x[r.d] ^ x[r.a], 16);
        x[r.c] = fBlaMka(x[r.c], x[r.d]);
        x[r.b] = math.rotr(u64, x[r.b] ^ x[r.c], 63);
    }
}

fn finalize(
    blocks: *Blocks,
    memory: u32,
    threads: u24,
    out: []u8,
) void {
    const lanes = memory / threads;
    var lane: u24 = 0;
    while (lane < threads - 1) : (lane += 1) {
        for (blocks.items[(lane * lanes) + lanes - 1], 0..) |v, i| {
            blocks.items[memory - 1][i] ^= v;
        }
    }
    var block: [1024]u8 = undefined;
    defer crypto.secureZero(u8, &block);
    for (blocks.items[memory - 1], 0..) |v, i| {
        mem.writeInt(u64, block[i * 8 ..][0..8], v, .little);
    }
    blake2bLong(out, &block);
}

fn indexAlpha(
    rand: u64,
    lanes: u32,
    segments: u32,
    threads: u24,
    n: u32,
    slice: u32,
    lane: u24,
    index: u32,
) u32 {
    var ref_lane = @as(u32, @intCast(rand >> 32)) % threads;
    if (n == 0 and slice == 0) {
        ref_lane = lane;
    }
    var m = 3 * segments;
    var s = ((slice + 1) % sync_points) * segments;
    if (lane == ref_lane) {
        m += index;
    }
    if (n == 0) {
        m = slice * segments;
        s = 0;
        if (slice == 0 or lane == ref_lane) {
            m += index;
        }
    }
    if (index == 0 or lane == ref_lane) {
        m -= 1;
    }
    var p = @as(u64, @as(u32, @truncate(rand)));
    p = (p * p) >> 32;
    p = (p * m) >> 32;
    return ref_lane * lanes + @as(u32, @intCast(((s + m - (p + 1)) % lanes)));
}

/// Derives a key from the password, salt, and argon2 parameters.
///
/// Derived key has to be at least 4 bytes length.
///
/// Salt has to be at least 8 bytes length.
pub fn kdf(
    allocator: mem.Allocator,
    derived_key: []u8,
    password: []const u8,
    salt: []const u8,
    params: Params,
    mode: Mode,
    io: Io,
) KdfError!void {
    if (derived_key.len < 4) return KdfError.WeakParameters;
    if (derived_key.len > max_int) return KdfError.OutputTooLong;

    if (password.len > max_int) return KdfError.WeakParameters;
    if (salt.len < 8 or salt.len > max_int) return KdfError.WeakParameters;
    if (params.t < 1 or params.p < 1) return KdfError.WeakParameters;
    if (params.m / 8 < params.p) return KdfError.WeakParameters;

    var h0 = initHash(password, salt, params, derived_key.len, mode);
    defer crypto.secureZero(u8, &h0);
    const memory = @max(
        params.m / (sync_points * params.p) * (sync_points * params.p),
        2 * sync_points * params.p,
    );

    var blocks = try Blocks.initCapacity(allocator, memory);
    defer {
        crypto.secureZero(u8, mem.sliceAsBytes(blocks.items));
        blocks.deinit();
    }

    blocks.appendNTimesAssumeCapacity(@splat(0), memory);

    initBlocks(&blocks, &h0, memory, params.p);
    try processBlocks(&blocks, params.t, memory, params.p, mode, io);
    finalize(&blocks, memory, params.p, derived_key);
}
