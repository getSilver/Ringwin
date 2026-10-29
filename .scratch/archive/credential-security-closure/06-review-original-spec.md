# Independent Spec review

Pinned review: c5f73ba08ed10e6a5f42e97264f4c72e9b2f2864...2fb36708d4f7b6cac448eff01bce58651da32333. Read-only source/evidence review; no builds, network, real credentials or repository edits.

(a) Missing/partial required behavior: no additional substantial implementation gap found. Task 06 final full Debug/ReleaseSafe, builds and cleanup are scheduled acceptance work, not defects reported here. Native guard call paths preserve preflight and successful/failing postflight: Windows runDemoChain retains its independent credential/transport owners through child cleanup; Linux runLinuxAuthoritative runs emergency cleanup before the failure guard, with transport/credentials still alive. Liability blank strings preserve the existing public contract; missing/non-string reject.

(b) Scope creep: none found. CredentialStore.admitExecution still returns ExecutionAdmissionOutOfScope. Narrow pinned cryptographic adaptations retain source/license and compatibility tests. Linux rejects TTY before reading. Synthetic/native functionality does not establish target dump/swap, compiler temporary or TLS/OS copy erasure, or production qualification.

(c) Implemented wrongly:

- P2 — Current wave launcher can reject a valid compiler before reaching the controlled Demo input entry. Spec.md:35 requires “现有Demo工具使用新的受控注入入口”. At tools/verify-okx-demo-wave.ps1:29-30, the version probe calls Invoke-EmptyInputNative and then tests $LASTEXITCODE. tools/protected-demo-launch.ps1:8-28 launches Diagnostics.Process, checks its ExitCode and never assigns PowerShell LASTEXITCODE. Consequently a fresh strict-mode shell may throw because LASTEXITCODE is unset; a caller's prior nonzero native exit falsely rejects the correct pinned Zig version. This is source-established and independently confirms the already recorded task-06 item; no reproduction was run. Remove the stale status check because the helper already throws on nonzero, or explicitly propagate a current status. Add a bounded synthetic wrapper regression with unset and stale nonzero LASTEXITCODE, without running the full wave or networking.

Review checked current stage/transition/publishing, protected-memory/KDF/AEAD/auth ownership, C header borrowing, credential framing, role forwarding, migrated launchers and native account guards against spec/issues 01–08 and original audit. Findings do not assert exhaustive absence of security defects.
