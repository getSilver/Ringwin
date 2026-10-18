# Protected AEAD evidence

2026-10-18. Ticket07 supplements the already protected KDF with XChaCha20-Poly1305 live-state protection. Fixed compiler: `D:/Program Files/zig/zig.exe`, `0.17.0-dev.315+5b647b792`.

Checkpoint `e5524e78` retains the first minimal implementation and public red/green: [NotImplemented failure](07-red-compat.log), then [ReleaseSafe 1/1 success](07-green-compat.log). Subsequent tests/evidence use distinct names. No real credential, exchange request or production operation is involved.

## Scope and API

`credential_aead.encrypt(c,*tag,m,ad,nonce,*const key)!void` and `decrypt(m,c,tag,ad,nonce,*const key)!void` preserve original byte lengths, AEAD format and parameter ordering; key is borrowed by pointer. Caller owns already protected key/plaintext buffers. Ciphertext, tag, nonce and AAD may reside in ordinary memory. Synchronous calls allocate a dedicated native protected Buffer before copying a secret or constructing secret state. The owner Scratch contains HChaCha subkey, original/derived-key ChaCha context, working state, keystream block, polyKey and Poly1305 context. HChaCha output/context reset use destination pointers; no explicit secret array/context returns by value.

Scratch and its complete rounded mapping are securely erased before unlock/free on every ordinary success/error path. Authentication failure explicitly secureZeroes the caller's output, rather than relying on undefined poison. Encrypt errors similarly clear ciphertext/tag. Native lock/dump/protection failures fail closed. Test-only backend injection is guarded by `builtin.is_test`; production paths cannot select it. Existing Poly1305.final's full-context clear is retained and independently observed with its RFC vector.

Pinned provenance/MIT license: [credential_aead_crypto](../../src/credential_aead_crypto/README.md). The extracted scalar ChaCha20 round function and Poly1305 integer arithmetic retain original logic. Only pointer ownership/init, omitted unrelated APIs/SIMD and protected state placement change; round count20, nonce construction, Poly counter0, payload counter1, AAD/ciphertext padding and little-endian lengths are unchanged. This does not modify the CRD4 container format or KDF parameters. The scalar choice is for bounded credential payloads, with no new performance qualification claim.

Arithmetic expressions/register spills and compiler-generated temporaries remain a distinct limitation; these tests do not establish their erasure, TLS/OS internal erasure, actual target dump/swap exclusion or production qualification.

## Targeted checks

Module suites: [Windows ReleaseSafe](07-safe.log), [Windows ReleaseFast](07-fast.log), [actual WSL Linux ReleaseFast](07-linux.log), all **10/10 passed**, exit0. Each covers six AEAD/crypto tests plus four inherited public protected-memory tests. Source/artifact/log identities and exact counts are recorded in [07-validation.json](07-validation.json).

- Original stdlib encryption/tag byte comparison and original stdlib decrypt of new ciphertext; new decrypt of old ciphertext.
- 54 payload/AAD pairs: payload lengths0,1,15,16,17,63,64,65,512; AAD lengths0,1,15,16,17,252. In-place decrypt, empty and maximum current credential payload are covered.
- Fixed known XChaCha ciphertext/tag literal from the pinned upstream test, and RFC Poly1305 known vector; in-place reset and final-context zero check.
- Ciphertext/tag/nonce/key/AAD tampering all fail authentication and clear full output. Length mismatch fails without releasing stale output.
- Allocator, lock, DONTDUMP and page-protection failure observations: all allocated pages erased before unlock/release, caller output cleared; no fallback/bypass.
- Real native owner flow uses protected key/plaintext Buffers and successful encrypt/decrypt. Windows has no DONTDUMP qualification claim; WSL1's syscall success remains ABI/functional evidence.

The standalone [native refusal probe](07-native-refusal.zig) built as a non-test application module and executed successfully, exit0, with only its child shell's Linux memlock limit set to0. It observes the public encrypt API returning MemoryLockFailed and ciphertext/tag as zeros; this verifies native refusal and production compilation without relying on fake backend injection. No global/user limits changed. See [native refusal log](07-native-refusal-linux.log).

## Reproduce module checks

```powershell
& 'D:/Program Files/zig/zig.exe' test src/credential_aead.zig -O ReleaseSafe --cache-dir .zig-cache/credential07
& 'D:/Program Files/zig/zig.exe' test src/credential_aead.zig -O ReleaseFast --cache-dir .zig-cache/credential07
& 'D:/Program Files/zig/zig.exe' test src/credential_aead.zig -O ReleaseFast -target x86_64-linux --test-no-exec --cache-dir .zig-cache/credential07-linux '-femit-bin=.scratch/credential-security-closure/credential07-linux'
wsl.exe -- /mnt/d/github/Ringwin-credential-aead-protection/.scratch/credential-security-closure/credential07-linux
& 'D:/Program Files/zig/zig.exe' build-exe -O ReleaseFast -target x86_64-linux --cache-dir .zig-cache/credential07-linux-refusal --dep aead '-Mroot=.scratch/credential-security-closure/07-native-refusal.zig' '-Maead=src/credential_aead.zig' '-femit-bin=.scratch/credential-security-closure/credential07-native-refusal-linux'
wsl.exe -- sh -c 'ulimit -l 0; exec /mnt/d/github/Ringwin-credential-aead-protection/.scratch/credential-security-closure/credential07-native-refusal-linux'
```

## Integration

Ticket03 owns `credential_store.zig` and has prepared a separate callsite patch using the agreed pointer API. This worktree does not modify that file while03 is editing it. After03 is committed/merged, integration must apply that patch in sequence and rerun the real store/old CRD4 fixture regression before final freeze. Module test results alone do not assert the existing store callsites already use this implementation.
