// Derived from Zig 0.17.0-dev.315+5b647b792; MIT, see LICENSE.
const std = @import("std");
const mem = std.mem;
const math = std.math;
const debug = std.debug;

const RoundParam = struct {
    a: usize,
    b: usize,
    c: usize,
    d: usize,
    x: usize,
    y: usize,
};

fn roundParam(a: usize, b: usize, c: usize, d: usize, x: usize, y: usize) RoundParam {
    return RoundParam{
        .a = a,
        .b = b,
        .c = c,
        .d = d,
        .x = x,
        .y = y,
    };
}

pub const Blake2b128 = Blake2b(128);
pub const Blake2b160 = Blake2b(160);
pub const Blake2b256 = Blake2b(256);
pub const Blake2b384 = Blake2b(384);
pub const Blake2b512 = Blake2b(512);

pub fn Blake2b(comptime out_bits: usize) type {
    return struct {
        const Self = @This();
        pub const block_length = 128;
        pub const digest_length = out_bits / 8;
        pub const key_length_min = 0;
        pub const key_length_max = 64;
        pub const key_length = 32; // recommended key length
        pub const Options = struct { key: ?[]const u8 = null, salt: ?[16]u8 = null, context: ?[16]u8 = null, expected_out_bits: usize = out_bits };

        const iv = [8]u64{
            0x6a09e667f3bcc908,
            0xbb67ae8584caa73b,
            0x3c6ef372fe94f82b,
            0xa54ff53a5f1d36f1,
            0x510e527fade682d1,
            0x9b05688c2b3e6c1f,
            0x1f83d9abfb41bd6b,
            0x5be0cd19137e2179,
        };

        const sigma = [12][16]u8{
            [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
            [_]u8{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
            [_]u8{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
            [_]u8{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
            [_]u8{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
            [_]u8{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
            [_]u8{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
            [_]u8{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
            [_]u8{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
            [_]u8{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
            [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
            [_]u8{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
        };

        h: [8]u64,
        t: u128,
        // Streaming cache
        buf: [128]u8,
        buf_len: u8,

        pub fn init(options: Options) Self {
            comptime debug.assert(8 <= out_bits and out_bits <= 512);

            var d: Self = undefined;
            d.h = iv;

            const key_len = if (options.key) |key| key.len else 0;
            // default parameters
            d.h[0] ^= 0x01010000 ^ (key_len << 8) ^ (options.expected_out_bits >> 3);
            d.t = 0;
            d.buf_len = 0;

            if (options.salt) |salt| {
                d.h[4] ^= mem.readInt(u64, salt[0..8], .little);
                d.h[5] ^= mem.readInt(u64, salt[8..16], .little);
            }
            if (options.context) |context| {
                d.h[6] ^= mem.readInt(u64, context[0..8], .little);
                d.h[7] ^= mem.readInt(u64, context[8..16], .little);
            }
            if (key_len > 0) {
                @memset(d.buf[key_len..], 0);
                d.update(options.key.?);
                d.buf_len = 128;
            }
            return d;
        }

        pub fn hash(b: []const u8, out: *[digest_length]u8, options: Options) void {
            var d = Self.init(options);
            defer std.crypto.secureZero(u8, std.mem.asBytes(&d));
            d.update(b);
            d.final(out);
        }

        pub fn update(d: *Self, b: []const u8) void {
            var off: usize = 0;

            // Partial buffer exists from previous update. Copy into buffer then hash.
            if (d.buf_len != 0 and d.buf_len + b.len > 128) {
                off += 128 - d.buf_len;
                @memcpy(d.buf[d.buf_len..][0..off], b[0..off]);
                d.t += 128;
                d.round(d.buf[0..], false);
                d.buf_len = 0;
            }

            // Full middle blocks.
            while (off + 128 < b.len) : (off += 128) {
                d.t += 128;
                d.round(b[off..][0..128], false);
            }

            // Copy any remainder for next pass.
            const b_slice = b[off..];
            @memcpy(d.buf[d.buf_len..][0..b_slice.len], b_slice);
            d.buf_len += @as(u8, @intCast(b_slice.len));
        }

        pub fn final(d: *Self, out: *[digest_length]u8) void {
            @memset(d.buf[d.buf_len..], 0);
            d.t += d.buf_len;
            d.round(d.buf[0..], true);
            for (&d.h) |*x| x.* = mem.nativeToLittle(u64, x.*);
            out.* = @as(*[digest_length]u8, @ptrCast(&d.h)).*;
        }

        fn round(d: *Self, b: *const [128]u8, last: bool) void {
            var m: [16]u64 = undefined;
            defer std.crypto.secureZero(u64, &m);
            var v: [16]u64 = undefined;
            defer std.crypto.secureZero(u64, &v);

            for (&m, 0..) |*r, i| {
                r.* = mem.readInt(u64, b[8 * i ..][0..8], .little);
            }

            var k: usize = 0;
            while (k < 8) : (k += 1) {
                v[k] = d.h[k];
                v[k + 8] = iv[k];
            }

            v[12] ^= @as(u64, @truncate(d.t));
            v[13] ^= @as(u64, @intCast(d.t >> 64));
            if (last) v[14] = ~v[14];

            const rounds = comptime [_]RoundParam{
                roundParam(0, 4, 8, 12, 0, 1),
                roundParam(1, 5, 9, 13, 2, 3),
                roundParam(2, 6, 10, 14, 4, 5),
                roundParam(3, 7, 11, 15, 6, 7),
                roundParam(0, 5, 10, 15, 8, 9),
                roundParam(1, 6, 11, 12, 10, 11),
                roundParam(2, 7, 8, 13, 12, 13),
                roundParam(3, 4, 9, 14, 14, 15),
            };

            comptime var j: usize = 0;
            inline while (j < 12) : (j += 1) {
                inline for (rounds) |r| {
                    v[r.a] = v[r.a] +% v[r.b] +% m[sigma[j][r.x]];
                    v[r.d] = math.rotr(u64, v[r.d] ^ v[r.a], @as(usize, 32));
                    v[r.c] = v[r.c] +% v[r.d];
                    v[r.b] = math.rotr(u64, v[r.b] ^ v[r.c], @as(usize, 24));
                    v[r.a] = v[r.a] +% v[r.b] +% m[sigma[j][r.y]];
                    v[r.d] = math.rotr(u64, v[r.d] ^ v[r.a], @as(usize, 16));
                    v[r.c] = v[r.c] +% v[r.d];
                    v[r.b] = math.rotr(u64, v[r.b] ^ v[r.c], @as(usize, 63));
                }
            }

            for (&d.h, 0..) |*r, i| {
                r.* ^= v[i] ^ v[i + 8];
            }
        }
    };
}
