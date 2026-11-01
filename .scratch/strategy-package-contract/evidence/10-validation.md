# Task 10 validation

Baseline: `7408c420b1c0cdf835400ea687d9ae01c69a9f8c`; implementation commits
`3dabcab2` and `95c0c043`, worktree `D:/github/Ringwin-strategy-package-03`, branch
`codex/strategy-package-03`. [Environment](10-environment.json),
[source and installed executable identities](10-identities.json), and
[core test executable identity](10-core-binary.json) bind the offline evidence.

## Scope and placement

The existing authenticated Web, signed installer, immutable package directories,
node-owned deployment scopes, HostSupervisor and checkpoint repositories remain
the owners. Python instances with the same DecisionDomain and exact runtime-lock
compatibility share one actual interpreter process, with at most 16 members.
Different domains or incompatible locked runtimes use separate processes. The
node supplies approved portfolio/scope/budget placements; Web cannot expand them.
One Python definition can have distinct configurations, and multiple definitions
can use the same module names. Each callback selects its package-local module
table and approved code path. Private instances and durable repositories remain
separate. This organizes trusted, signed code; it is not hostile-plugin isolation.

The Zig adapter owns the physical child once. Each member retains its own
HostSupervisor, existing framed session, batch sequence, cursor and activation.
All member generations are reserved durably before a replacement child starts.
No pipe wire format, checkpoint codec, core event format, recovery protocol,
control-plane CLI or external authorization channel was added.

Windows shared memory is **aggregate Job committed bytes**, including the Zig
adapter and interpreter, capped at the checked sum of all member packages'
`max_memory_bytes`. This includes runtime overhead; a package cannot reserve the
whole allowance exclusively. There is no per-instance hard limit inside the
shared interpreter. Singleton processes retain their existing per-process
committed-memory limit. The aggregate Job has inherited membership and kernel
kill-on-owner-death behavior. Shared aggregate placement is explicitly unavailable
on Linux; the existing singleton address-space path is unchanged. Windows
acceptance does not close this Linux implementation/resource gap.

## Aggregate manifest convention

`strategy_package.host_manifests` defines v1. Sort members by the fixed-width
StrategyInstanceIdentity and encode arrays using existing canonical JSON.
Hash the strategy array after the exact domain bytes
`RingWin/StrategyHost/strategies/v1` and a zero byte; hash the checkpoint array
after `RingWin/StrategyHost/checkpoints/v1` and a zero byte. Both are full SHA-256.

Each strategy entry contains instance, definition, complete package manifest
SHA-256, ConfigVersion and complete config SHA-256. Each checkpoint entry contains
instance, definition, full state-schema descriptor, ConfigVersion and the known
publication descriptor, or JSON null for initialization without a publication.
These bind the exact approved startup set. The native Repository still resolves
the latest durable publication independently, including an unacknowledged one,
and validates the actual checkpoint's identity, state digest and recovery cursor.
The Python loader independently recomputes both aggregate handshake digests.
No u128 truncation or fixed placeholder replaces a complete package digest.

## Lifecycle and concurrency

Adding/recovering a compatible member checkpoints and revokes the current shared
members before restarting the process. Every member returns unauthorized Ready.
Web records expose physical members, memory metric/budget and both digests.
Package/config replacement changes only the target binding. Its progress exposes
all affected DecisionDomain instances; a physical restart stops every member of
that process. Retained members keep their original signed package/config and
checkpoint repository; recovery revalidates those immutable approved bytes.

The node's configured AuthoritySet routes each instance to its own bridge and
core portfolio authority. Explicit EnableTrading is still required for each
instance, including when the domain is already trading; safety gates, latches,
version and command identity checks remain enforced. A secondary target is first
selected using an ordinary Keep VersionActivation before its actual transition,
preserving the existing global activation-history chain and other portfolios.
Process faults revoke shared members and retain the existing core fault latch;
planned restarts use control revocation and do not create a new fault latch.

Pipe waits release the manager lock. Management writes acquire release before
manager; candidates share the parent's operation lock and have no independent
monitor. Validation completion checks the original target Host. A successful
begin marks the target Recovering/unauthorized; every cutover/checkpoint wait
checks it was not stopped. Other same-target controls are refused during commit;
KillSwitch remains available and forces unknown/reconciliation on interruption.
Rejected candidates merge current records, preserving concurrent Stopped state.

## Verification

- ReleaseSafe core: [log](10-core-tests.log), **825/825 passed**,
  [independent exit code](10-core-exit.txt) **0**. Compilation took 8 minutes and
  execution 62 minutes. As in task 09, the raw log contains a standalone
  `failed command` line before the successful summary; it is preserved. No core
  source changed after this build. Later candidate-only diagnostics do not enter
  the core test executable.
- [Final release build](10-release-build-final.log): **9/9**, exit 0.
  [Final node build](10-node-build-final.log): **3/3**, exit 0.
- [Operational seam](10-operational-test.log): the repeated explicit-enable
  regression passes, including refusal after a safety latch closes.
- [Multi-node lifecycle](10-multi-node-tests.log): **4/4** pass, covering two
  independent core bindings, fault recovery, secondary configuration, target
  successor and retained member recovery.
- [Complete group output](10-multi-output-test.log): **1/1** passes. Both members
  emit their own complete IntentGroups into the actual core; late output after
  shared process death does not create more orders.
- Final Windows Python suite: **341 tests, 327 passed, 14 platform skips**,
  882.844 seconds, [log](10-python-windows-final.log),
  [independent exit code](10-python-final-exit.txt) **0**. It includes real shared-process PID checks,
  same-module-name packages, private checkpoint separation, group recovery,
  aggregate Job pressure across processes, shared memory failure with another
  Host unaffected, and callback isolation.
- Three bounded real-Web subprocess regressions cover concurrent management
  writes, actual input delivery by another physical Host during a slow replacement
  candidate, and same-target pause during config validation with persistent
  Stopped state after rejection/reopen. The final full suite is the acceptance
  record for all three.
- [UI check](10-ui-check.log), Python static compilation, Zig format and
  source/report whitespace checks pass. Captured command logs retain original
  CRLF and terminal blank lines; their whitespace check permits those capture
  formats while still rejecting actual trailing spaces.

## Standards

Final independent read-only review of `7408c420 -> 95c0c043`: **0 remaining
findings**. Initial review found the manager/release lock cycle and stale config
record overwrite. Both were fixed and receive bounded concurrency regressions.

## Spec

Final independent read-only review of `7408c420 -> 95c0c043`: **0 remaining
findings**. Initial review found candidate waits retaining the parent's lock;
shared operation-lock ownership and actual other-Host delivery cover the repair.
Source review does not substitute for the completed test results above.

## Intermediate results and qualification boundary

- The first dual-instance Web test rejected the existing single-Host capacity;
  it now passes against one real interpreter PID.
- Early node vectors exposed a missing canonical account scope in the new
  two-portfolio fixture and the prior domain-trading EnableTrading rejection.
  The fixture was corrected and the explicit-enable behavior has a failing-then-
  passing operational regression; no safety gate was relaxed.
- An early whole-core run was deliberately interrupted after the operational
  source changed; [log](10-core-interrupted.log) and
  [exit](10-core-interrupted-exit.txt) are not acceptance. The later full run is
  the 825/825 result above.
- The first whole Python [log](10-python-windows.log) ran 338 tests, with 1 error
  and 14 platform skips, [exit 1](10-python-exit.txt). The checkpoint-failure
  regression instead encountered InvalidInputBatch during input delivery. Its
  isolated rerun passed. The exact rejection class in that run was not captured;
  candidate diagnostics now report it. The existing 50 ms freshness rule remains
  unchanged. The core runner was lowered to BelowNormal priority during follow-up
  work and has completed before the final Python suite.
- Intermediate concurrency regressions exposed nested Windows temporary paths
  exceeding the legacy cleanup path limit, and an attempted pause during the
  current Host's checkpoint callback. Independent temporary roots and bounded
  retry of the explicit public busy refusal corrected the test harness. Failed
  [first](10-concurrency-tests.log), [cutover](10-concurrency-cutover-tests.log)
  and [combined](10-concurrency-final.log) logs are retained; the subsequent
  [pause regression](10-disable-config-final.log) passed.
- The successful final Python log retains one local loopback socket
  `ResourceWarning`. Its allocation origin was not captured; the warning was not
  suppressed and is not evidence of process/socket lifetime qualification.

This is Windows offline evidence using signed fixture bundles, real restricted
Python processes, authenticated Web and the existing offline core/commit and Venue
fixture. It does not establish Linux shared-resource enforcement, node power-loss
or standby durability, actual Venue orders, deployment, soak, or production
qualification. Full-journal recovery and bounded member/history capacity remain
explicit limits. Task 11 owns the frozen end-to-end evidence; the map stays open.
