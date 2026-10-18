# Pinned crypto adaptation

Upstream Zig commit `5b647b792`, compiler `0.17.0-dev.315+5b647b792`.

Original file SHA256:
- `lib/std/crypto/argon2.zig`: `680c0e03a8e5cb0a1ded530283ddd3865e370888e0801241399bd879b6bc8a7b`
- `lib/std/crypto/blake2.zig`: `b3d3b9a7c37f623be7fd17fa43c73e0f1ef5a7d73d09dd7f87d92f3a808e22da`
- `LICENSE`: `5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177`

Only the raw Argon2 KDF and Blake2b implementation are retained. No algorithm, parameter, lane scheduling, or digest changes. Added secureZero defers for owned state, intermediate blocks, Blake2b compression words and contexts; Argon2 block allocation is supplied by a protected fixed-buffer allocator in credential_kdf. PHC string encoding and unrelated algorithms/tests are excluded. MIT license is retained next to these sources.

These wipes cover explicitly owned program storage, not compiler/register temporaries, TLS or OS internals. Hash constants and index scalars are not secret-owning buffers. Preserve this narrow diff when updating the pinned compiler.
