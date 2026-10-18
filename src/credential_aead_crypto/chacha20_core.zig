// Derived from Zig 0.17.0-dev.315+5b647b792; MIT, see LICENSE.
// Scalar core from the pinned standard library, 20 rounds unchanged.
const math = @import("std").math;

const QuarterRound = struct {
    a: usize,
    b: usize,
    c: usize,
    d: usize,
};

fn Rp(a: usize, b: usize, c: usize, d: usize) QuarterRound {
    return QuarterRound{
        .a = a,
        .b = b,
        .c = c,
        .d = d,
    };
}

pub fn core(x: *[16]u32, input: *const [16]u32) void {
    @memcpy(x, input);

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

    comptime var j: usize = 0;
    inline while (j < 20) : (j += 2) {
        inline for (rounds) |r| {
            x[r.a] +%= x[r.b];
            x[r.d] = math.rotl(u32, x[r.d] ^ x[r.a], @as(u32, 16));
            x[r.c] +%= x[r.d];
            x[r.b] = math.rotl(u32, x[r.b] ^ x[r.c], @as(u32, 12));
            x[r.a] +%= x[r.b];
            x[r.d] = math.rotl(u32, x[r.d] ^ x[r.a], @as(u32, 8));
            x[r.c] +%= x[r.d];
            x[r.b] = math.rotl(u32, x[r.b] ^ x[r.c], @as(u32, 7));
        }
    }
}
