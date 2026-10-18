"""One-shot provenance-preserving extraction from the pinned Zig distribution."""
from pathlib import Path
import hashlib

source = Path('D:/Program Files/zig')
target = Path('src/credential_crypto')
target.mkdir(exist_ok=True)
license_text = (source / 'LICENSE').read_text()
(target / 'LICENSE').write_bytes(license_text.encode())
header = '// Derived from Zig 0.17.0-dev.315+5b647b792; MIT, see LICENSE.\n'
b = (source / 'lib/std/crypto/blake2.zig').read_text()
blake = b[:b.index('/////////////////////')].replace('@import("../std.zig")', '@import("std")').replace('const htest = @import("test.zig");\n', '')
blake += b[b.index('pub const Blake2b128'):b.index('test "blake2b160 single"')]
blake = blake.replace('var d = Self.init(options);', 'var d = Self.init(options);\n            defer std.crypto.secureZero(u8, std.mem.asBytes(&d));')
blake = blake.replace('var m: [16]u64 = undefined;', 'var m: [16]u64 = undefined;\n            defer std.crypto.secureZero(u64, &m);')
blake = blake.replace('var v: [16]u64 = undefined;', 'var v: [16]u64 = undefined;\n            defer std.crypto.secureZero(u64, &v);')
(target / 'blake2b.zig').write_bytes((header + blake).encode())
a = (source / 'lib/std/crypto/argon2.zig').read_text()
argon = a[:a.index('const PhcFormatHasher = struct')]
argon = argon.replace('const blake2 = crypto.hash.blake2;', 'const blake2 = @import("blake2b.zig");')
argon = argon.replace('    var h0: H0 = undefined;', '    var h0: H0 = undefined;\n    defer crypto.secureZero(u8, &h0);')
argon = argon.replace('    var b2 = Blake2b512.init(.{});', '    var b2 = Blake2b512.init(.{});\n    defer crypto.secureZero(u8, mem.asBytes(&b2));')
argon = argon.replace('    var h0 = initHash(password, salt, params, derived_key.len, mode);', '    var h0 = initHash(password, salt, params, derived_key.len, mode);\n    defer crypto.secureZero(u8, &h0);')
argon = argon.replace('    defer blocks.deinit();', '    defer {\n        crypto.secureZero(u8, mem.sliceAsBytes(blocks.items));\n        blocks.deinit();\n    }')
for declaration, wipe in [
    ('var out_buf: [H.digest_length]u8 = undefined;', 'crypto.secureZero(u8, &out_buf);'),
    ('var in_buf: [H.digest_length]u8 = undefined;', 'crypto.secureZero(u8, &in_buf);'),
    ('var h = H.init(.{ .expected_out_bits = out.len * 8 });', 'crypto.secureZero(u8, mem.asBytes(&h));'),
    ('var h = H.init(.{});', 'crypto.secureZero(u8, mem.asBytes(&h));'),
    ('var block0: [1024]u8 = undefined;', 'crypto.secureZero(u8, &block0);'),
    ('var addresses: [block_length]u64 align(16) = @splat(0);', 'crypto.secureZero(u64, &addresses);'),
    ('var in: [block_length]u64 align(16) = @splat(0);', 'crypto.secureZero(u64, &in);'),
    ('var t: [block_length]u64 = undefined;', 'crypto.secureZero(u64, &t);'),
    ('var buffer: [16]u64 = undefined;', 'crypto.secureZero(u64, &buffer);'),
    ('var block: [1024]u8 = undefined;', 'crypto.secureZero(u8, &block);'),
]:
    argon = argon.replace(declaration, declaration + '\n    defer ' + wipe)
(target / 'argon2.zig').write_bytes((header + argon).encode())
lines = ['# Pinned crypto adaptation', '', 'Upstream Zig commit `5b647b792`, compiler `0.17.0-dev.315+5b647b792`.', '', 'Original file SHA256:']
for name in ['lib/std/crypto/argon2.zig', 'lib/std/crypto/blake2.zig', 'LICENSE']:
    lines.append(f'- `{name}`: `{hashlib.sha256((source/name).read_bytes()).hexdigest()}`')
lines.extend(['', 'Only the raw Argon2 KDF and Blake2b implementation are retained. No algorithm, parameter, lane scheduling, or digest changes. Added secureZero defers for owned state, intermediate blocks, Blake2b compression words and contexts; Argon2 block allocation is supplied by a protected fixed-buffer allocator in credential_kdf. PHC string encoding and unrelated algorithms/tests are excluded. MIT license is retained next to these sources.', '', 'These wipes cover explicitly owned program storage, not compiler/register temporaries, TLS or OS internals. Hash constants and index scalars are not secret-owning buffers. Preserve this narrow diff when updating the pinned compiler.'])
(target / 'README.md').write_bytes(('\n'.join(lines) + '\n').encode())
