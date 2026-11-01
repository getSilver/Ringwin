# Task 08 validation

Baseline: `bb73ec18a466e967c12eaca356e7a1f07dde0977`, worktree
`D:/github/Ringwin-strategy-package-03`, branch `codex/strategy-package-03`.

## Ownership and scope

The authenticated instance Web API now accepts `replace` and `forward_rollback`
against an expected current definition and an explicit operation identity. It uses
the existing DeployRelease / ForwardRollback installation and signature checks;
there is no upload or independent control-plane path. The candidate must be the
currently installed, fully authenticated package. The new binding preserves the
portfolio, DecisionDomain, configuration, scopes and budget. ForwardRollback
requires previously used definition content in that portfolio and allocates
another new instance, never resurrecting its earlier instance.

An isolated, unauthorized candidate initializes its own private state, checkpoint
namespace and intent allocator through the existing new-instance API. No source
private payload is restored. Normal warmup can consume new intent sequences; the
allocator starts at one. The node independently rejects unresolved orders,
Unknown/recovery work, active predecessor cycles, residuals, unaccounted report
quantities, late economic facts and managed positions. It requires node-owned
Venue reconciliation evidence and rechecks closure before commit. No automatic
flattening or economic rollback is introduced.

The existing DecisionDomain pause and CutoverDrain precede a durable
VersionActivationEvent. A Rebuild successor inherits the predecessor's
VirtualPortfolio authority, with zero Host activation. The same fact fences the
predecessor and leaves all economic state, leases, budgets and operational latches
in place. The release's native u64 label derives from the approved signed manifest;
the complete manifest/package SHA-256 and bytes remain independently verified.
Predecessor fences remain pinned while their authority records are resident.
Resident fence and authority capacities are bounded; exhaustion rejects further
successors instead of dropping an identity or historical responsibility.

The candidate must actually consume the final version barrier and publish its
checkpoint before Web reports Ready. EnableTrading / HostActivated and its actual
application acknowledgement remain separate. Old instance requests cannot enter
the new node authority. Pre-validation rejection preserves the original Host;
failure after drain stops it and records unknown. Interrupted or incomplete
publication cannot restore the predecessor. Immutable command results survive
later control operations, multiple replacements and backend reopening; a reused
operation identity with different content is rejected.

The Web shows target and predecessor/successor identities, transition progress,
scope and errors, and provides replacement/ForwardRollback controls. Single Host
capacity and DecisionDomain-wide drain remain; ticket 10 owns multiple Hosts and
instances. This ticket does not reset or broaden instrument authorization.

## Verification

Final suites completed successfully after the editor-crash restart. Recorded
source and binary SHA-256 identities still match the current files.

- [Final Windows Python suite](08-python-windows-final.log): 320 tests, 306 passed,
  14 platform skips, 855.790 seconds; [runner exit code](08-python-exit.json): 0.
- [Final ReleaseSafe core suite](08-zig-tests.log): all 824 tests passed;
  [runner exit code](08-core-exit.json): 0. The [final compile](08-core-compile-final.log)
  uses `zig test src/main.zig -O ReleaseSafe --stack 536870912
  '-femit-bin=.scratch/build/08-core-tests.exe' --test-no-exec`, followed by a
  complete run of that executable. This is the normal full-suite root and stack;
  no test filter was applied.

- [Initial Web/Host vectors](08-successor-focused.log): replacement, forward
  rollback, rejected candidate and live-order rejection passed 3/3.
- [Failure boundaries](08-successor-boundaries.log): explicit successor enable and
  committed-but-lost ACK / backend reopening passed 2/2 before the final command
  result regression was added. Final Python suite includes that regression.
- [Core successor vectors](08-core-successor-verified.log): 4/4, including stable
  replay, unchanged economics/operational constraints and responsibility refusal.
- [UI self-check](08-ui-selfcheck.cjs): both request bindings, result identities,
  rejection messages and escaping pass. Existing 07 UI self-check also passes.
- Native ReleaseSafe [build](08-native-build.log): 9/9 steps succeeded. Final
  [acceptance node build](08-authority-build-sealed.log): 3/3 steps succeeded.
- Standards review: no actionable findings. Spec review found a command-result
  indexing bug after A→B→C and backend reopening; immutable terminal indexing and
  the actual Web/Host regression fixed it. Spec follow-up: no remaining definite
  findings. Neither review establishes runtime qualification.
- Python static compilation, Zig format and diff whitespace checks pass.
- [Source and native identities](08-native-identities.json) bind the tested files.

## Intermediate failures and interrupted runs

- [First focused core run](08-core-successor-focused.log) used a 64 MiB stack and
  overflowed existing core state-copy paths. Subsequent runs use the repository's
  512 MiB full-suite test stack.
- [Second focused run](08-core-successor-final.log) rejected a synthetic position
  fixture with `InvalidEconomicFact` before the position-specific closure guard.
  Position responsibility is now checked before the full economic assertion;
  the [verified vector](08-core-successor-verified.log) passes.
- [First direct compiler invocation](08-core-compile.log) failed because
  PowerShell split an unquoted `-femit-bin=...` argument. The final invocation
  quotes that argument.
- [First full core build](08-zig-intermediate.log),
  [superseded core build](08-zig-unsealed.log) and
  [superseded Python suite](08-python-intermediate.log) were explicitly terminated
  while the implementation/fixtures were being corrected. They are not passes.
- The editor crashed during the first final wave. The preserved
  [core log](08-zig-editor-crash.log) stops after 164/824 and the
  [Python log](08-python-editor-crash.log) stops in Host acceptance, without final
  summaries or recorded assertion failures. All recorded source/binary SHA-256
  identities still matched. Both suites were restarted from the beginning using
  hidden background runners with independent exit-code records; the interrupted
  wave is not a full-suite pass.

## Qualification boundary

These are Windows offline checks with signed fixture packages, real interpreter,
Host and native adapter, and the existing core/Gateway. The acceptance node owns
its reconciliation callback but obtains observations from its offline fixture;
it does not qualify an operational Venue evidence provider. Stable in-memory
fixture commits do not establish disk power-loss or standby durability. No
credentials, Demo/actual Venue orders, deployment, Linux resource qualification or
production qualification were exercised. Platform skips remain skips under ADR0010.
