# Ticket03 protected store and input evidence

2026-10-18. Fixed compiler: `D:/Program Files/zig/zig.exe`, `0.17.0-dev.315+5b647b792`. Only synthetic credentials and offline processes were used. Exact source, artifact, command and log identities are recorded in [03-validation.json](03-validation.json); the source snapshot is [03-final-source.zip](03-final-source.zip).

Public stage, lifecycle transitions and admission now read passwords directly into native protected memory. Legacy caller password buffers are only cleared; they are never filled with plaintext. Stage clears caller material on success and all errors. Module-owned password copies, payload, KEK, decrypted plaintext and decoded lease material use `protected_memory.Buffer`; KDF uses ticket02 protected scratch. Decode writes directly to an already protected lease, and Secret construction borrows a pointer instead of taking material by value. Lease freeze, release and erasure belong to the central Buffer owner. The historical test_bypass parameter no longer bypasses native Buffer protection.

Pipe/socket inspection remains mandatory. Input requires newline, rejects oversized input instead of accepting a truncated prefix, and clears storage on failure. Linux rejects TTY before reading; no termios or signal-restoration guarantee is claimed. Windows retains its console echo toggle. Linux dedicated store directories are created/tightened to0700 and opened with iterable, fsync-capable descriptors without following the final symlink. Windows owner explicitly requests a24MiB native lock budget; successful VirtualLock remains mandatory. Both native acceptance fixtures create random128-bit directories exclusively and only remove paths they successfully created.

Encode/decode fields larger than128 reject with InvalidCredential rather than slicing out of bounds. Container schema and algorithms are unchanged; original CRD4/v1 fixture authentication and revocation pass.

## Red, green and retained failures

- [Password red](03-input-red.log): public stage accepted an overlong password prefix. [Green](03-input-green.log): PasswordTooLong, with caller password/material erased.
- [Decode red](03-decode-red.log): authenticated129-byte field reached public admission and panicked in decodeMaterial. Final tests reject InvalidCredential. Fixture encryption uses independent stdlib AEAD. [Earlier fixture setup error](03-decode-harness-error.log) was a wrong literal buffer length, retained separately and not counted as a product failure.
- Windows ReleaseSafe final **32/32**: [log](03-final-v2-safe.log). Linux-specific guarded test bodies do not run on Windows.
- WSL1 uid1000, child-only64MiB memlock, final **32/32**: [log](03-final-v2-linux-bounded.log). Actual `/dev/ptmx` is confirmed to be a TTY, then public stage rejects it before reading; x86_64 fstat observes0700. Initial [31/32](03-final-linux-bounded.log) failed in the new test observer because WSL1 lacks statx used by Io.Dir.stat. Only that test observer was changed to the documented x86_64 fstat ABI; production code was unchanged.
- WSL1 default64KiB public native refusal **1/1**: [log](03-final-linux-default.log). MemoryLockFailed, no published credential, caller password/material cleared. No global/user memlock configuration changed.
- [Native entry runner](03-entry.zig) invokes exactly runWindowsAcceptance/runLinuxAcceptance. [Windows](03-entry-windows.log) and [bounded Linux](03-entry-linux.log) both exit0 with read_only ready and send_capability=false. Final integration will also exercise actual application argument dispatch.

The Windows native entry/default-refusal executable were compiled at checkpoint7e01e01c before the Linux-only fstat test correction; runtime production code is identical. Final v2 Windows/Linux module binaries share the final source snapshot. Initial28/28 and30/30 logs are historical checkpoints. Empty compile logs mean no diagnostics were emitted. The initial source snapshot packaging command failed because this repo has no build.zig.zon; no runtime test was rerun or relabeled as a consequence.

## Remaining scope

Stdlib AEAD still owns explicit internal crypto/key copies; ticket07 replaces that workspace and must rerun store compatibility. Ticket03 does not claim that gap fixed. Compiler/register temporaries, OS/TLS internal memory, actual dump/swap resistance and target qualification remain outside this evidence. Interactive Windows console was not exercised; the existing echo toggle is retained. No real credentials, network, trading, deployment or production execution admission were enabled. Full Debug/ReleaseSafe acceptance stays deferred to final freeze.
