"""Pinned stdlib extraction; only in-place ownership/storage adaptations."""
from pathlib import Path
import hashlib

zig = Path('D:/Program Files/zig')
out = Path('src/credential_aead_crypto')
out.mkdir(exist_ok=True)
(out/'LICENSE').write_bytes((zig/'LICENSE').read_bytes())
header = '// Derived from Zig 0.17.0-dev.315+5b647b792; MIT, see LICENSE.\n'
p = (zig/'lib/std/crypto/poly1305.zig').read_text()
p = p[:p.index('test "rfc7439 vector1"')]
p = p.replace('@import("../std.zig")', '@import("std")')
start = p.index('    pub fn init(')
end = p.index('    fn add(', start)
p = p[:start] + '''    /// Destination already resides in protected storage.
    pub fn reset(st: *Poly1305, key: *const [key_length]u8) void {
        st.r[0] = mem.readInt(u64, key[0..8], .little) & 0x0ffffffc0fffffff;
        st.r[1] = mem.readInt(u64, key[8..16], .little) & 0x0ffffffc0ffffffc;
        st.end_pad[0] = mem.readInt(u64, key[16..24], .little);
        st.end_pad[1] = mem.readInt(u64, key[24..32], .little);
        @memset(&st.h, 0);
        @memset(&st.buf, 0);
        st.leftover = 0;
    }

''' + p[end:]
p = p.replace('        st.h = [_]u64{ h0, h1, h2 };', '        st.h[0] = h0;\n        st.h[1] = h1;\n        st.h[2] = h2;')
start = p.index('    pub fn create(')
p = p[:start] + '};\n'
(out/'poly1305.zig').write_bytes((header+p).encode())
c = (zig/'lib/std/crypto/chacha20.zig').read_text()
start = c.index('        const QuarterRound', c.index('fn ChaChaNonVecImpl'))
end = c.index('        fn hashToBytes', start)
core = c[start:end]
core = core.replace('        ', '', 1) if False else core
core = '\n'.join(line[8:] if line.startswith('        ') else line for line in core.splitlines())
core = core.replace('fn chacha20Core(x: *BlockVec, input: BlockVec)', 'pub fn core(x: *[16]u32, input: *const [16]u32)')
core = core.replace('    x.* = input;', '    @memcpy(x, input);')
core = core.replace('rounds_nb', '20')
(out/'chacha20_core.zig').write_bytes((header+'// Scalar core from the pinned standard library, 20 rounds unchanged.\nconst math = @import("std").math;\n\n'+core+'\n').encode())
lines = ['# Credential AEAD pinned adaptation', '', 'Source: Zig `0.17.0-dev.315+5b647b792`, commit `5b647b792`, MIT license retained.', '', 'Upstream SHA256:']
for path in ['lib/std/crypto/chacha20.zig','lib/std/crypto/poly1305.zig','LICENSE']:
    lines.append(f'- `{path}`: `{hashlib.sha256((zig/path).read_bytes()).hexdigest()}`')
lines += ['', 'Retains the scalar 20-round ChaCha core and Poly1305 integer arithmetic. Changes: pointer-input/output core; in-place Poly1305 reset; no secret-returning create helper or unrelated tests; field writes replace the explicit temporary h array. Credential AEAD mirrors the original XChaCha/HChaCha/ChaCha-Poly flow in protected Scratch instead of ordinary local arrays and by-value key/context returns. SIMD selection is omitted for this bounded credential operation; no algorithm, nonce/counter, authentication ordering or container-format change.', '', 'Named secret-owning buffers and contexts live in native protected pages before first sensitive write. Explicit erasure precedes unlock/free. Arithmetic/register/compiler temporaries, TLS/OS internals and target dump/swap qualification are not proven erased. The existing Poly1305 final clear remains intact.']
(out/'README.md').write_bytes(('\n'.join(lines)+'\n').encode())
