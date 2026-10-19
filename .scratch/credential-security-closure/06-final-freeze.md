# Final offline freeze

Implementation HEAD: `040a21a26b0dc61abb63d3f7b5dd2e1b991832ab`.

Standards and Spec independently closed the shared P2; byte-preserved follow-ups are [Standards](06-review-followup-standards.md) and [Spec](06-review-followup-spec.md). The optional password-wrapper duplication remains correct explicit ownership and is nonblocking.

Frozen source SHA256: `81bffb6dab6f22ad14feea2e99d520e7365b2900a60dc2b5d253228a4b7ee0ae`. Plan: [credential-final-v1-plan.json](credential-final-v1-plan.json), 35 sequential offline stages. Source archive and all compiler/dependency/producer hashes are bound by the plan. The controller persists under `runs/credential-final-v1/state.json`; stop on first failure, no automatic retry.

All roots and both full test executables compile before either full suite runs. Windows Debug and ReleaseSafe full suites use a 512 MiB executable stack. Linux native modules and credential entry execute via WSL with a 64 MiB child-only memlock limit after dropping to uid/gid 1000; a separate default-limit child must refuse staging. Linux standalone curl entry checks are semantic compile-only, not linked/executed curl binaries.

This file records the start boundary, not a pass. Task 06 remains open. No real credentials, Venue/network/orders, target dump/swap/power loss or production qualification. Main stays unchanged.
