// Derived from Zig 0.17.0-dev.315+5b647b792; MIT, see LICENSE.
const std = @import("std");
const mem = std.mem;
const mulWide = std.math.mulWide;

pub const Poly1305 = struct {
    pub const block_length: usize = 16;
    pub const mac_length = 16;
    pub const key_length = 32;

    // constant multiplier (from the secret key)
    r: [2]u64,
    // accumulated hash
    h: [3]u64 = [_]u64{ 0, 0, 0 },
    // random number added at the end (from the secret key)
    end_pad: [2]u64,
    // how many bytes are waiting to be processed in a partial block
    leftover: usize = 0,
    // partial block buffer
    buf: [block_length]u8 align(16) = undefined,

    /// Destination already resides in protected storage.
    pub fn reset(st: *Poly1305, key: *const [key_length]u8) void {
        st.r[0] = mem.readInt(u64, key[0..8], .little) & 0x0ffffffc0fffffff;
        st.r[1] = mem.readInt(u64, key[8..16], .little) & 0x0ffffffc0ffffffc;
        st.end_pad[0] = mem.readInt(u64, key[16..24], .little);
        st.end_pad[1] = mem.readInt(u64, key[24..32], .little);
        @memset(&st.h, 0);
        @memset(&st.buf, 0);
        st.leftover = 0;
    }

    fn add(a: u64, b: u64, c: u1) struct { u64, u1 } {
        const v1 = @addWithOverflow(a, b);
        const v2 = @addWithOverflow(v1[0], c);
        return .{ v2[0], v1[1] | v2[1] };
    }

    fn sub(a: u64, b: u64, c: u1) struct { u64, u1 } {
        const v1 = @subWithOverflow(a, b);
        const v2 = @subWithOverflow(v1[0], c);
        return .{ v2[0], v1[1] | v2[1] };
    }

    fn blocks(st: *Poly1305, m: []const u8, comptime last: bool) void {
        const hibit: u64 = if (last) 0 else 1;
        const r0 = st.r[0];
        const r1 = st.r[1];

        var h0 = st.h[0];
        var h1 = st.h[1];
        var h2 = st.h[2];

        var i: usize = 0;

        while (i + block_length <= m.len) : (i += block_length) {
            const in0 = mem.readInt(u64, m[i..][0..8], .little);
            const in1 = mem.readInt(u64, m[i + 8 ..][0..8], .little);

            // Add the input message to H
            var v = @addWithOverflow(h0, in0);
            h0 = v[0];
            v = add(h1, in1, v[1]);
            h1 = v[0];
            h2 +%= v[1] +% hibit;

            // Compute H * R
            const m0 = mulWide(u64, h0, r0);
            const h1r0 = mulWide(u64, h1, r0);
            const h0r1 = mulWide(u64, h0, r1);
            const h2r0 = mulWide(u64, h2, r0);
            const h1r1 = mulWide(u64, h1, r1);
            const m3 = mulWide(u64, h2, r1);
            const m1 = h1r0 +% h0r1;
            const m2 = h2r0 +% h1r1;

            const t0 = @as(u64, @truncate(m0));
            v = @addWithOverflow(@as(u64, @truncate(m1)), @as(u64, @truncate(m0 >> 64)));
            const t1 = v[0];
            v = add(@as(u64, @truncate(m2)), @as(u64, @truncate(m1 >> 64)), v[1]);
            const t2 = v[0];
            v = add(@as(u64, @truncate(m3)), @as(u64, @truncate(m2 >> 64)), v[1]);
            const t3 = v[0];

            // Partial reduction
            h0 = t0;
            h1 = t1;
            h2 = t2 & 3;

            // Add c*(4+1)
            const cclo = t2 & ~@as(u64, 3);
            const cchi = t3;
            v = @addWithOverflow(h0, cclo);
            h0 = v[0];
            v = add(h1, cchi, v[1]);
            h1 = v[0];
            h2 +%= v[1];
            const cc = (cclo | (@as(u128, cchi) << 64)) >> 2;
            v = @addWithOverflow(h0, @as(u64, @truncate(cc)));
            h0 = v[0];
            v = add(h1, @as(u64, @truncate(cc >> 64)), v[1]);
            h1 = v[0];
            h2 +%= v[1];
        }
        st.h[0] = h0;
        st.h[1] = h1;
        st.h[2] = h2;
    }

    pub fn update(st: *Poly1305, m: []const u8) void {
        var mb = m;

        // handle leftover
        if (st.leftover > 0) {
            const want = @min(block_length - st.leftover, mb.len);
            const mc = mb[0..want];
            for (mc, 0..) |x, i| {
                st.buf[st.leftover + i] = x;
            }
            mb = mb[want..];
            st.leftover += want;
            if (st.leftover < block_length) {
                return;
            }
            st.blocks(&st.buf, false);
            st.leftover = 0;
        }

        // process full blocks
        if (mb.len >= block_length) {
            const want = mb.len & ~(block_length - 1);
            st.blocks(mb[0..want], false);
            mb = mb[want..];
        }

        // store leftover
        if (mb.len > 0) {
            for (mb, 0..) |x, i| {
                st.buf[st.leftover + i] = x;
            }
            st.leftover += mb.len;
        }
    }

    /// Zero-pad to align the next input to the first byte of a block
    pub fn pad(st: *Poly1305) void {
        if (st.leftover == 0) {
            return;
        }
        @memset(st.buf[st.leftover..], 0);
        st.blocks(&st.buf, false);
        st.leftover = 0;
    }

    pub fn final(st: *Poly1305, out: *[mac_length]u8) void {
        if (st.leftover > 0) {
            var i = st.leftover;
            st.buf[i] = 1;
            i += 1;
            @memset(st.buf[i..], 0);
            st.blocks(&st.buf, true);
        }

        var h0 = st.h[0];
        var h1 = st.h[1];
        const h2 = st.h[2];

        // H - (2^130 - 5)
        var v = @subWithOverflow(h0, 0xfffffffffffffffb);
        const h_p0 = v[0];
        v = sub(h1, 0xffffffffffffffff, v[1]);
        const h_p1 = v[0];
        v = sub(h2, 0x0000000000000003, v[1]);

        // Final reduction, subtract 2^130-5 from H if H >= 2^130-5
        const mask = @as(u64, v[1]) -% 1;
        h0 ^= mask & (h0 ^ h_p0);
        h1 ^= mask & (h1 ^ h_p1);

        // Add the first half of the key, we intentionally don't use @addWithOverflow() here.
        st.h[0] = h0 +% st.end_pad[0];
        const c = ((h0 & st.end_pad[0]) | ((h0 | st.end_pad[0]) & ~st.h[0])) >> 63;
        st.h[1] = h1 +% st.end_pad[1] +% c;

        mem.writeInt(u64, out[0..8], st.h[0], .little);
        mem.writeInt(u64, out[8..16], st.h[1], .little);

        std.crypto.secureZero(Poly1305, st[0..1]);
    }
};
