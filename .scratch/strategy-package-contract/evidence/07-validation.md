# Task 07 validation

Baseline: `7386cb332d2364c7aa8596bbb0bdc6b0401c15ca`, worktree
`D:/github/Ringwin-strategy-package-03`, branch `codex/strategy-package-03`.
Implementation commits: `cc81feee`, `a32761af`; test journal seal: `e500d76e`.

## Ownership and scope

Authenticated Web config updates keep the original instance, definition, package,
deployment scope and budget. Full canonical config bytes and SHA-256 are retained
per ConfigVersion; a version cannot change content. Signed config/state contracts
declare compatibility and explicitly rebuildable state. The fixed API creates
with the new configuration and restores old private progress; no migration ABI,
implicit defaults or payload rewriting is introduced.

The candidate uses its own checkpoint namespace. Actual Host snapshots and normal
unauthorized event replay preserve allocation progress. Before drain, candidate
rejection preserves the original Host authority; a failed original Host snapshot
instead faults and revokes it. Native single-Writer cutover uses the existing
TradingPause, node-owned Venue evidence, CutoverDrain and VersionActivationEvent.
That fact updates same-instance config authority without changing economics or
risk latches. Actual application and a new published checkpoint precede Ready.
EnableTrading remains a separate command, and instrument permissions bound to an
old configuration are not silently broadened.

Single resident Host capacity remains; drain covers the DecisionDomain and is
shown in Web. Missing node-owned reconciliation evidence rejects the operation.
An interrupted drain/commit is unknown and cannot recover the old config by guess.

## Verification

Captured logs use LF line endings; diagnostic content and failed invocations are retained.

- Windows real Web/Host positive and failure-boundary vectors pass in the
  [focused transition log](07-transition-focused.log) and
  [final boundary log](07-failure-boundaries-final.log).
- [UI self-check](07-ui-selfcheck.cjs): request binding, Keep/Rebuild result,
  failure display and escaping pass. Python static compilation, Zig format and
  diff whitespace checks pass.
- [Native build](07-native-build.log): ReleaseSafe, pinned Zig
  `0.17.0-dev.315+5b647b792`, 9/9 steps succeeded.
- [Native acceptance node](07-authority-build.log): 3/3 steps succeeded.
- Native/runtime sources and the final core test executable are recorded by
  full SHA-256 in [native identities](07-native-identities.json).
- [Core config vector](07-core-config-focused.log): 2/2 passed, including the
  standalone entry and same-instance config/economics/latch/stable-replay check.
- Standards and Spec reviews independently report 0 actionable findings, including
  follow-up review of the rejection/snapshot boundary, timeout and generation checks.
- [Final Windows Python suite](07-python-windows-final.log): 316 tests,
  302 passed and 14 platform skips, exit 0, 830.477 seconds.
- [Final ReleaseSafe core suite](07-zig-tests.log): 822/822 passed,
  3/3 build steps succeeded, process exit 0. Runner reports 64 minutes for tests
  and 6 minutes for compilation. The log retains a `failed command:` context line:
  the pinned build runner prints captured stderr through `printStepFailure`,
  including the child-command label, regardless of the successful step summary.
  The complete counts and process exit above are the final result.

## Intermediate failures and corrections

- [First full Python invocation](07-python-intermediate.log): 314 tests, 8 errors,
  14 skips, exit 1. All eight errors were HTTP socket timeouts under concurrent
  native/core validation. The test client's 10-second timeout equaled a single
  package warmup budget and excluded bundle verification and a second candidate.
  Only WebInstanceTests now wait 30 seconds; ordinary clients still default to
  10 seconds, and callback, warmup, memory and native IPC deadlines are unchanged.
- [Original boundary run](07-failure-boundaries.log): two socket timeouts; the
  [same vectors with the test-client correction](07-failure-boundaries-final.log)
  pass 2/2 while core validation remains active.
- [Initial negative vectors](07-negative-focused.log): one assertion expected a
  Zig phase name, but the valid rejection reported the package's actual
  `warmup data insufficient`. The assertion now checks that concrete cause;
  the corrected vector passes in the focused transition log.
- [First core vector](07-core-config-focused-intermediate.log) redundantly revoked
  the Host after TradingPause had already revoked it, causing InvalidHostRevocation.
  The test now asserts the pause's actual revocation.
- [Second core vector](07-core-config-focused-unsealed.log) omitted journal seal,
  so the helper rejected its truncated tail with ReplayNotEquivalent. The test
  now seals before complete stable replay, matching the existing fixture pattern.
  Superseded full core invocations containing these known bad test vectors were
  terminated, and are not passes; the [terminated invocation log](07-zig-intermediate.log)
  preserves its failed build exit.
- [Initial focused invocation](07-core-config-focused-invocation.log) used an
  unsupported test-stack option; the corrected invocation uses `--stack`.

## Qualification boundary

These are controlled Windows offline tests with signed fixture packages, a real
interpreter/Host/native adapter and the existing core/Gateway with a simulated
Venue. The acceptance node derives its reconciliation observations from its
offline fixture; it does not establish a production Venue observation provider.
Windows verification persistence is not power-loss qualification. No credentials,
Demo orders, actual Venue orders, operational deployment, Linux resource
qualification or production qualification were exercised. Platform skips remain
skips under ADR 0010.
