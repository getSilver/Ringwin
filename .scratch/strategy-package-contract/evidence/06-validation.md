# Task 06 validation

Starting commit: `0676beeafc2716776eb6bc75cd3608555f4ed680`, worktree
`D:/github/Ringwin-strategy-package-03`, branch `codex/strategy-package-03`.

## Implementation and ownership

- The existing authenticated Web command/RiskWarning route binds the instance.
  The native adapter verifies the existing signed envelope and borrows the
  current core Writer; its commit callback must durably apply through that owner.
  No package or Web field supplies a risk approval, Gateway command, or budget.
- Native HostActivated precedes delivery; exact Host cursor acknowledgment
  precedes gateway activation. Ready input is normalized through the existing
  recovery normalizer, consumes normal decision sequences and suppresses output.
  Checkpoint evidence remains distinct from the current runtime cursor.
- Actual fixed-API package outputs use the existing single/group codecs, native
  ingress, core admission and execution Gateway. Stop and fault paths revoke;
  stale sessions/activations and withdrawn permission cannot authorize sending.
- Both pipe writes and reads have a shared deadline. Failed native connections
  are poisoned, and an unknown revocation is reported explicitly.

## Verification

Captured logs use LF line endings for repository storage; diagnostic content is
retained, including intermediate failures.

- Pinned Zig `0.17.0-dev.315+5b647b792`, ReleaseSafe normal build: 9/9.
- ReleaseSafe native acceptance adapter build: 3/3. Source/binary hashes are in
  [native identities](06-native-identities.json).
- Final Windows Python suite: 306 tests, 292 passed and 14 platform skips;
  exit 0 in 597.651 seconds. See [full log](06-python-windows-final.log).
- Final core suite: `zig build test -Doptimize=ReleaseSafe --summary all`,
  821/821 tests passed, 3/3 steps succeeded, exit 0; completed 2026-10-31
  03:01 Asia/Shanghai. The runner reports 67 minutes for tests and 7 minutes for
  compilation. See [full log](06-zig-tests.log). Test binary
  `.zig-cache/o/1af73bba7d79fd8a9dd43aa7d8f258f7/test.exe` SHA256:
  `c3c53c8e306cb4c48e1f28f50883c024ebbec39de297b81cfcc5107b69198458`.
  The raw log retains a `failed command:` context line alongside the successful
  summary. The pinned build runner prints stderr diagnostics regardless of step
  success (`lib/compiler/build_runner.zig`); the process exit and complete test
  counts above are the final result.
- UI adapter assertions, Python `py_compile`, Zig format and `git diff --check`
  passed. UI tests exercise instance controls, permission display and escaping.
- Two-axis review: Standards 0 remaining material findings; Spec 0. Fixed
  unauthorized Ready catch-up, runtime batching, write deadlines and empty first
  publication history. Tests include a real peer that does not read its pipe.

## Intermediate failures

[Initial Python full run](06-python-intermediate.log) ran 302 tests with 2 errors
and 14 platform skips. The group-native startup deadline and an existing recovery
HTTP deadline expired while full core execution and native compilation were also
running. This invocation is not a pass. Revisions and final validation follow it;
timing failure logs are retained rather than relabeled as successful evidence.

The earlier [focused activation run](06-activation-focused.log) also exposed a
test assertion racing the existing asynchronous permission monitor. Its safety
vector now waits for the externally visible Stopped state; native permission was
already closed. The corrected [group vector](06-group-final.log) and final full
suite pass. The [first-batch vector](06-first-batch.log) independently checks an
empty publication history starts at one without granting authority.

[The first 304-test run](06-python-pre-bootstrap.log) had 1 error and 14 platform
skips: the new multi-account node's initial status request included cold fixture
bootstrap and exceeded the normal 3-second request deadline. The fixture now
allows 30 seconds for that initial readiness response, then restores the normal
3-second request deadline. Package callback, warmup, memory and write-deadline
limits are unchanged. The corrected complete-group/Gateway test passed separately
before the final full run.

[The next run](06-python-pre-session-lock.log) stopped at test 288 on the existing
concurrent Web recovery-progress scenario: Windows refused `session.json`
replacement while another authentication request held it open. A focused public
SessionManager concurrent validation/renewal test reproduced the same WinError 5
in 0.388 seconds; 240 serial calls passed. A reentrant lock now serializes the
single Web application's session file transactions, including revoke, and failed
renewal returns 401. Regression tests cover both parallel renewal and preventing
revocation from being undone by renewal. The five-test owner security suite passed
with its one POSIX-only skip; the original recovery-progress scenario passed too.

## Qualification boundary

The acceptance node uses the existing core fixtures (including a multi-account
durable MemoryAdapter owner), real signed runtime/package/Host and the actual
execution Gateway with a simulated Venue. It demonstrates controlled Windows
offline integration, not a production node launcher or actual Venue authority.
Single-account legacy fixture commands do not carry a complete send proof; the
multi-account vector supplies the positive Gateway-send evidence. Existing
Windows verification file persistence is not power-loss qualification.

No credentials, Demo orders, real Venue orders, deployment, production or Linux
resource qualification were exercised. Linux remains independently pending under
ADR 0010; platform skips are not passes.
