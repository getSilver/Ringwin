"""Apply the storage-only adaptation after vendor-crypto base extraction."""
from pathlib import Path

base = Path('src/credential_crypto')
b = (base/'blake2b.zig').read_text()
b = b.replace('        buf_len: u8,', '        buf_len: u8,\n        compression_m: [16]u64,\n        compression_v: [16]u64,')
b = b.replace('pub fn init(options: Options) Self {', 'pub fn reset(d: *Self, options: Options) void {')
b = b.replace('            var d: Self = undefined;\n', '')
b = b.replace('            return d;\n', '')
b = b.replace('pub fn hash(b: []const u8, out: *[digest_length]u8, options: Options) void {\n            var d = Self.init(options);\n            defer std.crypto.secureZero(u8, std.mem.asBytes(&d));', 'pub fn hash(d: *Self, b: []const u8, out: *[digest_length]u8, options: Options) void {\n            d.reset(options);\n            defer std.crypto.secureZero(u8, std.mem.asBytes(d));')
b = b.replace('            out.* = @as(*[digest_length]u8, @ptrCast(&d.h)).*;', '            @memcpy(out, std.mem.asBytes(&d.h)[0..digest_length]);')
b = b.replace('var m: [16]u64 = undefined;\n            defer std.crypto.secureZero(u64, &m);\n            var v: [16]u64 = undefined;\n            defer std.crypto.secureZero(u64, &v);', 'const m = &d.compression_m;\n            defer std.crypto.secureZero(u64, m);\n            const v = &d.compression_v;\n            defer std.crypto.secureZero(u64, v);')
b = b.replace('for (&m, 0..)', 'for (m, 0..)')
assert 'var d' not in b and 'Self.init(' not in b
(base/'blake2b.zig').write_bytes(b.encode())

a = (base/'argon2.zig').read_text()
a = a.replace('const builtin = @import("builtin");\n', '')
scratch = '''/// All secret-owning mutable state is allocated from the caller's protected
/// allocator before processing password bytes. Lane segments execute serially
/// so a single Scratch is never shared by concurrent workers.
pub const Scratch = struct {
    h0: H0,
    initial_hash: Blake2b512,
    long_hash: Blake2b512,
    long_out: [64]u8,
    long_in: [64]u8,
    block_bytes: [1024]u8,
    addresses: [block_length]u64 align(16),
    input: [block_length]u64 align(16),
    zero: [block_length]u64 align(16),
    compression_t: [block_length]u64,
    compression_buffer: [16]u64,
    random: u64,
};

'''
a = a.replace('fn initHash(\n', scratch + 'fn initHash(\n    scratch: *Scratch,\n')
a = a.replace(') H0 {\n    var h0: H0 = undefined;\n    defer crypto.secureZero(u8, &h0);', ') void {\n    const h0 = &scratch.h0;')
a = a.replace('var b2 = Blake2b512.init(.{});\n    defer crypto.secureZero(u8, mem.asBytes(&b2));', 'const b2 = &scratch.initial_hash;\n    b2.reset(.{});\n    defer crypto.secureZero(u8, mem.asBytes(b2));')
a = a.replace('    return h0;\n', '')
a = a.replace('fn blake2bLong(out: []u8, in: []const u8)', 'fn blake2bLong(scratch: *Scratch, out: []u8, in: []const u8)')
a = a.replace('var out_buf: [H.digest_length]u8 = undefined;\n    defer crypto.secureZero(u8, &out_buf);', 'const out_buf = &scratch.long_out;\n    defer crypto.secureZero(u8, out_buf);')
a = a.replace('var h = H.init(.{ .expected_out_bits = out.len * 8 });\n        defer crypto.secureZero(u8, mem.asBytes(&h));', 'const h = &scratch.long_hash;\n        h.reset(.{ .expected_out_bits = out.len * 8 });\n        defer crypto.secureZero(u8, mem.asBytes(h));')
a = a.replace('var h = H.init(.{});\n    defer crypto.secureZero(u8, mem.asBytes(&h));', 'const h = &scratch.long_hash;\n    h.reset(.{});\n    defer crypto.secureZero(u8, mem.asBytes(h));')
a = a.replace('h.final(&out_buf)', 'h.final(out_buf)')
a = a.replace('var in_buf: [H.digest_length]u8 = undefined;\n    defer crypto.secureZero(u8, &in_buf);', 'const in_buf = &scratch.long_in;\n    defer crypto.secureZero(u8, in_buf);')
a = a.replace('in_buf = out_buf;', '@memcpy(in_buf, out_buf);')
a = a.replace('H.hash(&in_buf, &out_buf,', 'h.hash(in_buf, out_buf,')
a = a.replace('fn initBlocks(\n', 'fn initBlocks(\n    scratch: *Scratch,\n')
a = a.replace('var block0: [1024]u8 = undefined;\n    defer crypto.secureZero(u8, &block0);', 'const block0 = &scratch.block_bytes;\n    defer crypto.secureZero(u8, block0);')
a = a.replace('blake2bLong(&block0, h0)', 'blake2bLong(scratch, block0, h0)')
# Sequential lane execution retains every pass/slice barrier and index rule.
start = a.index('fn processBlocks(')
end = a.index('fn processSegment(')
a = a[:start] + '''fn processBlocks(
    scratch: *Scratch,
    blocks: *Blocks,
    time: u32,
    memory: u32,
    threads: u24,
    mode: Mode,
    io: Io,
) Io.Cancelable!void {
    const lanes = memory / threads;
    const segments = lanes / sync_points;
    var n: u32 = 0;
    while (n < time) : (n += 1) {
        var slice: u32 = 0;
        while (slice < sync_points) : (slice += 1) {
            try io.checkCancel();
            var lane: u24 = 0;
            while (lane < threads) : (lane += 1) {
                processSegment(scratch, blocks, time, memory, threads, mode, lanes, segments, n, slice, lane);
            }
        }
    }
}

''' + a[end:]
a = a.replace('fn processSegment(\n', 'fn processSegment(\n    scratch: *Scratch,\n')
a = a.replace('var addresses: [block_length]u64 align(16) = @splat(0);\n    defer crypto.secureZero(u64, &addresses);', 'const addresses = &scratch.addresses;\n    @memset(addresses, 0);\n    defer crypto.secureZero(u64, addresses);')
a = a.replace('var in: [block_length]u64 align(16) = @splat(0);\n    defer crypto.secureZero(u64, &in);', 'const in = &scratch.input;\n    @memset(in, 0);\n    defer crypto.secureZero(u64, in);')
a = a.replace('const zero: [block_length]u64 align(16) = @splat(0);', 'const zero = &scratch.zero;\n    @memset(zero, 0);')
a = a.replace('processBlock(&addresses, &in, &zero)', 'processBlock(scratch, addresses, in, zero)')
a = a.replace('processBlock(&addresses, &addresses, &zero)', 'processBlock(scratch, addresses, addresses, zero)')
a = a.replace('    var random: u64 = 0;\n', '    scratch.random = 0;\n    defer crypto.secureZero(u8, mem.asBytes(&scratch.random));\n')
a = a.replace('            random =', '            scratch.random =')
a = a.replace('indexAlpha(random,', 'indexAlpha(scratch.random,')
a = a.replace('processBlockXor(&blocks.items[offset]', 'processBlockXor(scratch, &blocks.items[offset]')
for name in ['processBlock', 'processBlockXor', 'processBlockGeneric']:
    a = a.replace('fn ' + name + '(\n', 'fn ' + name + '(\n    scratch: *Scratch,\n')
a = a.replace('processBlockGeneric(out,', 'processBlockGeneric(scratch, out,')
a = a.replace('var t: [block_length]u64 = undefined;\n    defer crypto.secureZero(u64, &t);', 'const t = &scratch.compression_t;\n    defer crypto.secureZero(u64, t);')
a = a.replace('for (&t, 0..)', 'for (t, 0..)')
a = a.replace('for (t, 0..) |v, j|', 'for (t, 0..) |v, j|')
a = a.replace('var buffer: [16]u64 = undefined;\n    defer crypto.secureZero(u64, &buffer);', 'const buffer = &scratch.compression_buffer;\n    defer crypto.secureZero(u64, buffer);')
a = a.replace('blamkaGeneric(&buffer)', 'blamkaGeneric(buffer)')
a = a.replace('fn finalize(\n', 'fn finalize(\n    scratch: *Scratch,\n')
a = a.replace('var block: [1024]u8 = undefined;\n    defer crypto.secureZero(u8, &block);', 'const block = &scratch.block_bytes;\n    defer crypto.secureZero(u8, block);')
a = a.replace('blake2bLong(out, &block)', 'blake2bLong(scratch, out, block)')
a = a.replace('    var h0 = initHash(password, salt, params, derived_key.len, mode);\n    defer crypto.secureZero(u8, &h0);', '''    const scratch = try allocator.create(Scratch);
    defer {
        crypto.secureZero(u8, mem.asBytes(scratch));
        allocator.destroy(scratch);
    }
    @memset(mem.asBytes(scratch), 0);
    initHash(scratch, password, salt, params, derived_key.len, mode);''')
a = a.replace('initBlocks(&blocks, &h0,', 'initBlocks(scratch, &blocks, &scratch.h0,')
a = a.replace('processBlocks(&blocks,', 'processBlocks(scratch, &blocks,')
a = a.replace('finalize(&blocks,', 'finalize(scratch, &blocks,')
assert 'var h0' not in a and 'H.init' not in a and 'var block' not in a.replace('var blocks', '')
(base/'argon2.zig').write_bytes(a.encode())
