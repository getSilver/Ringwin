# Task 09 validation

Baseline: `0f626361450460878fd8d4db8275d75799975a77`; worktree
`D:/github/Ringwin-strategy-package-03`, branch `codex/strategy-package-03`.

## Scope

Native bundles use signed `strategy_bundle_v2` and index version 2. The existing
release installer, registry, authenticated Web bindings and immutable definition
history remain the owners. Python v1 remains version 1. The approved native build
policy binds the complete inventory. The node independently checks its actual
running executable SHA-256, compiler, target, optimization and every static
definition/algorithm/schema/compatibility field before Ready. Native files never
enter the Python loader.

The existing node Writer runs the registered observation-only entrypoint through
typed Config/State. It consumes accepted ReferencePrice inputs from the committed
journal. It uses the shared signed EnableTrading, core activation, SafetyGate,
DecisionDomain drain, responsibility closure and VersionActivationEvent paths.
Native output frames and unsupported parameter transitions are explicitly refused.
Successor candidates remain unauthorized, preserve economic ownership, fence the
predecessor and return to Ready after consuming the final barrier. ForwardRollback
installs the original signed release and creates another fresh instance identity.
Only definitions already compiled into the actual running binary can be selected.

Native Web checkpoint data is a progress summary. Recovery revokes old activation
and deterministically rebuilds private observation state from a complete journal;
it does not load raw memory or Python portable state. Tests reopen the control
backend against the same node and verify Ready without trading authority. They do
not recreate a node process or establish disk/standby recovery qualification.

## Verification

- Native build regressions: [log](09-native-build-tests.log), 8/8 passed, including
  missing/duplicate registration, immutable content and compatibility refusals.
- UI self-check (`node tools/verify-strategy-package-ui.cjs`) passes, including
  native runtime display and definition selection with immutable binding prefill.
- Python static compilation, Zig format and whitespace checks pass.
- Full ReleaseSafe core: [log](09-core-tests.log), 824/824 passed;
  `zig build test -Doptimize=ReleaseSafe --summary all` exited 0. Compile took
  approximately 9 minutes and execution 63 minutes. The log contains one standalone
  `failed command` line before its successful summary; the completed process
  independently returned exit code 0. That line is preserved, not omitted.
  [Core binary identity](09-core-binary.json) records the exact test executable.
- ReleaseSafe [release build](09-release-build.log): 9/9 steps succeeded, exit 0.
  [Native node build](09-node-build.log): 3/3 succeeded, exit 0.
- First full Windows Python [log](09-python-windows.log): 327 tests, 313 passed,
  14 platform skips, 1248.620 seconds, [exit code](09-python-exit.txt) 0. It includes
  all seven native test methods and the existing Host/core/Gateway regressions.
- Final full Windows Python after the derived service-entry correction:
  [log](09-python-windows-final.log), 327 tests, 313 passed, 14 platform skips,
  709.657 seconds, [exit code](09-python-final-exit.txt) 0. This verifies actual
  installation of the fixed service entry alongside the full native and existing
  Python lifecycle regressions. No Zig source changed after the full core run.
  [Source and installed build identities](09-identities.json) still match.

## Standards

Parallel read-only review: 0 actionable findings against repository rules,
glossary, native contract and relevant ADRs; no additional abstraction requested.

## Spec

Parallel read-only review: 0 confirmed blocking findings. The review identified
that same-node recovery is not node-process restart evidence; the test name and
qualification boundary now explicitly describe backend reopening.

## Intermediate results

- The first native package test failed because v2 was not implemented, then
  exposed the existing 64 MiB binary file limit. v2 explicitly permits a bounded
  256 MiB native binary while retaining other file and total bundle limits.
- The two-definition node fixture exposed the compile-time branch quota in
  static identity lookup; the lookup and typed runtime now have explicit quotas.
- An intermediate fixture compile rejected a local variable shadowing stdin;
  the fixture variable was renamed. Two commands used the wrong working directory
  for formatting/imports; subsequent checks used the correct directory.
- An intermediate negative index test expected the wrong diagnostic; the
  assertion now names the explicit incompatible index version refusal.
- An initial four-vector node run passed successor/rollback, binary mismatch and
  the observation/enable/pause path. The gate vector sampled the existing
  nonblocking view during background revocation; it now waits for the terminal
  record and independently exercises unauthorized recovery. Native recovery was
  also separated from Python snapshot cursor requirements.
- Final integration inspection found that the existing Linux role unit executes
  `current/ringwin`, while native build output lives under `bin/`. Native validated
  install views now derive the root executable from the same signed binary bytes;
  generic installer, existing-version verification and immutable loader validation
  cover both paths. The new root-entry regression first failed with `KeyError`,
  then passed. No service unit, launcher or authorization path was added. Actual
  systemd execution was not tested.

## Qualification boundary

Windows offline evidence uses signed fixture releases, an actual compiled node
with two static observation definitions, authenticated Web, and the existing core.
The additional definition exists only in a temporary compiled test source tree.
The node's commit and Venue reconciliation callbacks use the existing offline
fixture. They do not establish real disk power-loss, standby ACK or operational
Venue evidence. No credentials, Demo/Venue orders, deployment, Linux resource
qualification or production qualification were exercised. Full-journal recovery
and existing single-instance capacity remain explicit limits.
