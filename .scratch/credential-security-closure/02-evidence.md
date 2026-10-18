# Ticket 02 protected memory and KDF evidence

2026-10-18. Fixed compiler `D:/Program Files/zig/zig.exe`, `0.17.0-dev.315+5b647b792`. Source/artifact/log hashes: [02-validation.json](02-validation.json).

## Red and green

- Public `Buffer.init(64)` initially returned `NotImplemented`: native protection test failed 0/1. Implemented page ownership, native protection and controlled read/write transitions, then ReleaseSafe 1/1 passed.
- Public fixed-format KDF initially returned `NotImplemented`: compatibility test failed 0/1 after independently computing the old standard-library Argon2id result. Added protected workspace and the pinned narrow adaptation, then ReleaseSafe compatibility 1/1 passed.
- Final Windows ReleaseSafe and ReleaseFast suites each **8/8 passed**. [Safe log](02-safe.log), [Fast log](02-fast.log). Tests observe entire mappings before unlock/release, including allocation/lock/dump/protection failures, normal ownership, error cancellation and failed write transition. Byte checks happen before allocator poison. RFC 9106 section 5.3 known vector (Argon2id with secret/ad, p=4) and original OWASP t=2/m=19456KiB/p=1 compatibility both pass.
- Native Windows KDF locks the actual 19 MiB workspace after explicit, bounded per-process `configureNativeLockBudget(24*1024*1024)`. This setup raises existing working-set minima/maxima monotonically under a mutex; it never reduces/restores a budget while another mapping may remain locked. Each native allocation still requires successful `VirtualLock`. Default insufficient Windows working-set budget is not silently bypassed.
- Cross-compiled **same source** ReleaseFast x86_64-linux ELF executed under WSL1, uid1000. With default soft/hard memlock 65536, all 8 tests pass and native KDF specifically refuses `MemoryLockFailed`, zeroing the caller's output. [Default log](02-linux-default.log).
- With [child-only helper](02-linux-bounded.py), root sets 64 MiB memlock for the one child, then clears groups/drops gid/uid to1000 before exec. All **8/8 pass** including actual native KDF and MADV_DONTDUMP calls. [Bounded log](02-linux-bounded.log). No global or per-user configuration changed.

WSL1 independently returned success from libc `mlock(20MiB)` despite 64KiB memlock. Therefore native Linux explicitly checks the current soft limit and serializes accounting of this module's rounded mappings before calling `mlock`; real kernels additionally account other libraries. Success on this WSL ABI is functional evidence, not proof of real swap/dump exclusion or target-machine qualification.

## Reproduce

```powershell
& 'D:/Program Files/zig/zig.exe' test src/credential_kdf.zig -O ReleaseSafe --cache-dir .zig-cache/credential02
& 'D:/Program Files/zig/zig.exe' test src/credential_kdf.zig -O ReleaseFast --cache-dir .zig-cache/credential02
& 'D:/Program Files/zig/zig.exe' test src/credential_kdf.zig -O ReleaseFast -target x86_64-linux --test-no-exec --cache-dir .zig-cache/credential02-linux '-femit-bin=.scratch/credential-security-closure/credential02-linux'
wsl.exe -- /mnt/d/github/Ringwin-credential-protected-memory/.scratch/credential-security-closure/credential02-linux
wsl.exe -u root -- python3 /mnt/d/github/Ringwin-credential-protected-memory/.scratch/credential-security-closure/02-linux-bounded.py /mnt/d/github/Ringwin-credential-protected-memory/.scratch/credential-security-closure/credential02-linux
```

The first unquoted PowerShell `-femit-bin=...` attempt failed at argument parsing before compiling; the quoted command above succeeded. It is not a product failure or skipped test.

## Ownership and limits

The stable APIs are recorded in [ticket02](issues/02-protect-secret-and-crypto-workspaces.md). Production `Buffer.init` has no injectable backend. Test-only construction and observer are guarded by `builtin.is_test`; native Windows report does not claim DONTDUMP. Restoring write permission for deinit is mandatory: failure panics before unlock/free, rather than releasing an unwiped page. Normal release securely erases the whole rounded mapping before unlocking/freeing. Linux failed unlock conservatively retains its budget charge.

The adapted Argon2 and Blake2b sources retain [MIT license/provenance](../../src/credential_crypto/README.md). Algorithms, parameters and lane scheduling are unchanged. Explicit wipes cover block allocation, h0, initial hash context, long-hash intermediates, initialization/finalization blocks, compression contexts/words and per-segment buffers. Caller must keep password and output destination in preprotected memory; no key is returned by value. Compiler/register temporaries, TLS/OS internals, actual dump/swap resistance and target security qualification remain outside this functional evidence.

Only new modules and ticket02 evidence changed; existing CredentialStore/auth/transport are left for dependent tickets. Final integrated full Debug/ReleaseSafe acceptance is owned by the integration task.

## Interrupted auxiliary reference recovery

Before merging latest integration tip `e7fb53c5`, Git found this worktree's `ORIG_HEAD` broken. Its original 41 bytes were copied verbatim to `D:/github/Ringwin-credential-recovery-20261018/protected-memory-ORIG_HEAD-before-merge.bin`; hashes are in the validation JSON. Only this worktree-private auxiliary ref was restored to its existing valid HEAD `4d153bdf` (full SHA in validation JSON), then the integration branch fast-forwarded. Tracked implementation edits and all untracked test artifacts remained present; branch ownership, shared refs and main were not altered. `git status`, ancestry and log were checked afterward.
