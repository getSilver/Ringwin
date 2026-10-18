# Credential AEAD pinned adaptation

Source: Zig `0.17.0-dev.315+5b647b792`, commit `5b647b792`, MIT license retained.

Upstream SHA256:
- `lib/std/crypto/chacha20.zig`: `d7d7162c17b8ca58be2c7284d6b25573a17a642bf4f27bfe0bfd9057f7952eeb`
- `lib/std/crypto/poly1305.zig`: `d60ead7afe6cf3f86ffa568bf9545e231889c8d0743ec33d2f3c48b55f8360de`
- `LICENSE`: `5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177`

Retains the scalar 20-round ChaCha core and Poly1305 integer arithmetic. Changes: pointer-input/output core; in-place Poly1305 reset; no secret-returning create helper or unrelated tests; field writes replace the explicit temporary h array. Credential AEAD mirrors the original XChaCha/HChaCha/ChaCha-Poly flow in protected Scratch instead of ordinary local arrays and by-value key/context returns. SIMD selection is omitted for this bounded credential operation; no algorithm, nonce/counter, authentication ordering or container-format change.

Named secret-owning buffers and contexts live in native protected pages before first sensitive write. Explicit erasure precedes unlock/free. Arithmetic/register/compiler temporaries, TLS/OS internals and target dump/swap qualification are not proven erased. The existing Poly1305 final clear remains intact.
