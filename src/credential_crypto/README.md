# Pinned crypto adaptation

Upstream Zig commit `5b647b792`, compiler `0.17.0-dev.315+5b647b792`.

Original file SHA256:
- `lib/std/crypto/argon2.zig`: `680c0e03a8e5cb0a1ded530283ddd3865e370888e0801241399bd879b6bc8a7b`
- `lib/std/crypto/blake2.zig`: `b3d3b9a7c37f623be7fd17fa43c73e0f1ef5a7d73d09dd7f87d92f3a808e22da`
- `LICENSE`: `5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177`

Only the raw Argon2 KDF and Blake2b implementation are retained. Algorithms, parameters, sync-point ordering, reference indices and digests are unchanged. Lanes execute serially within each slice, preserving barriers while allowing one protected Scratch owner (production OWASP parameters already use p=1). Added secureZero defers and moved all explicitly owned secret arrays and hash contexts into protected allocator-backed Scratch. Blake2b compression words are context fields; initHash writes its destination in place and returns no H0 value. PHC string encoding and unrelated algorithms/tests are excluded. MIT license is retained next to these sources.

The caller must supply protected storage to the raw KDF; credential_kdf enforces this with a dedicated protected fixed-buffer region sized for blocks plus Scratch/alignment. Explicit storage is protected throughout its live interval and securely erased on success and failure. Compiler/register temporaries, TLS and OS internals are not proven erased. Public parameter encodings and index scalars do not own secret buffers. Preserve this narrow diff when updating the pinned compiler.
