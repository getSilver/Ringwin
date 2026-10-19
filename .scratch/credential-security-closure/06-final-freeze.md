# Final offline freeze

Implementation HEAD: `040a21a26b0dc61abb63d3f7b5dd2e1b991832ab`.

Standards and Spec independently closed the shared P2; byte-preserved follow-ups are [Standards](06-review-followup-standards.md) and [Spec](06-review-followup-spec.md). The optional password-wrapper duplication remains correct explicit ownership and is nonblocking.

Frozen source SHA256: `81bffb6dab6f22ad14feea2e99d520e7365b2900a60dc2b5d253228a4b7ee0ae`. Plan: [credential-final-v1-plan.json](credential-final-v1-plan.json), 35 sequential offline stages. Source archive and all compiler/dependency/producer hashes are bound by the plan. The controller persists under `runs/credential-final-v1/state.json`; stop on first failure, no automatic retry.

All roots and both full test executables compile before either full suite runs. Windows Debug and ReleaseSafe full suites use a 512 MiB executable stack. Linux native modules and credential entry execute via WSL with a 64 MiB child-only memlock limit after dropping to uid/gid 1000; a separate default-limit child must refuse staging. Linux standalone curl entry checks are semantic compile-only, not linked/executed curl binaries.

This file records the start boundary, not a pass. Task 06 remains open. No real credentials, Venue/network/orders, target dump/swap/power loss or production qualification. Main stays unchanged.

## v1 format-only stop and explicit v2 continuation

v1 stopped at diff-check exit2 before compilation or full-suite execution. Raw diagnostics are preserved in runs/credential-final-v1-diff-check/. Of 1811 diagnostics, 1810 were preserved CRLF line endings; one space belongs to the historical immutable stdin-inheritance producer. File-scoped attributes now accept CRLF while retaining real trailing-space checks; only that historical producer has blank-at-eol disabled. No source/evidence bytes were normalized or changed.

Business source remains 81bffb6dab6f22ad14feea2e99d520e7365b2900a60dc2b5d253228a4b7ee0ae. The revised preparer binds both attributes files as producers and archives their exact bytes. v2 is a new manually prepared plan; no results are relabeled or reused from v1.

v2 also stopped at the first diff-check, solely on the new immutable v1 launch JSON CRLF (7 lines); no compiler/test ran. All evidence JSON now has the same CR-at-EOL rule, including future launch records. v3 retains the same business source identity and fresh result labels. Both prior failed controllers/diagnostics remain unchanged.
