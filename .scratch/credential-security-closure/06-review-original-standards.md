# Final independent Standards review

Pinned scope: `git diff c5f73ba08ed10e6a5f42e97264f4c72e9b2f2864...2fb36708d4f7b6cac448eff01bce58651da32333`. The 57-commit captured context was read first. This review covers changed src/tools/build implementation and selected tests; raw evidence logs were excluded. Read-only review only: no build, test, network, real credentials, or subagents.

Sources read: AGENTS.md; CONTEXT.md credential/security vocabulary; docs/agents/domain.md; docs/agents/issue-tracker.md; ADR0005; ADR0010; Zig SKILL.md and its code-review/pattern references; closure spec. No CODING_STANDARDS or CONTRIBUTING exists in the captured standards context. Repository contracts override general smell advice. The fixed scalar crypto adaptations, their mathematical variable names, and deliberately retained narrow upstream duplication are intentional and are not findings.

## (a) Documented-standard breaches

No additional documented repository-standard breach was established in the reviewed implementation hunks. The migrated ownership and protection paths retain explicit cleanup, role separation and platform qualification limitations. ADR0005's original stdlib choice is refined explicitly by the closure spec's permission for pinned, licensed narrow adaptations; this is not a silent algorithm change. Linux TTY refusal is likewise explicitly authorized by the spec. Final full-suite evidence is still in progress and is not reported as a new code bug.

## Substantive runtime finding (not a documented style breach)

**P2 — Correct the exit-status contract at tools/verify-okx-demo-wave.ps1:29-30.**

Hunk:

```powershell
$zigVersion = (Invoke-EmptyInputNative (Get-Command zig -ErrorAction Stop).Source @('version') -CaptureOutput).Trim()
if ($LASTEXITCODE -ne 0 -or $zigVersion -ne $ExpectedZig) {
```

`Invoke-EmptyInputNative` (tools/protected-demo-launch.ps1:8-29) starts a Diagnostics.Process, checks its own `ExitCode`, and throws on failure, but never assigns PowerShell's `$LASTEXITCODE`. Thus the next expression observes an unrelated previous native-command result. In a fresh shell with no native exit state, StrictMode can reject the uninitialized variable; with a stale nonzero value it rejects a successful, exactly matching Zig version. The wrapper aborts before its validation wave. The `Invoke-Zig` wrapper's later assignment at line17 cannot initialize this earlier check. Remove the redundant native exit check here, or make the helper/wrapper consistently publish explicit exit status. Static call-path verification only; no execution was requested or performed.

## (b) Fowler baseline: judgement calls, not hard breaches

**Optional Duplicated Code — src/credential_store.zig:287-326.**

The public stage/activate/retire/revoke/admission wrappers each repeat:

```zig
var password_storage = try protected.Buffer.init(max_password + 1);
defer password_storage.deinit();
const password = try readPassword(io, file, input_kind, try password_storage.writable());
try password_storage.freeze();
```

This is one shared ownership shape repeated five times. A small private password-owner constructor could centralize acquisition/read/freeze error cleanup while each wrapper retains its compatibility caller-buffer wipe and operation-specific material cleanup. This is optional: the current repetition is explicit and correct; any extraction must preserve stable protected ownership and must not return borrowed slices whose owner expires. It is not a closure blocker or a reason to enlarge the current patch.

All mandatory baseline categories were considered: Mysterious Name, Duplicated Code, Feature Envy, Data Clumps, Primitive Obsession, Repeated Switches, Shotgun Surgery, Divergent Change, Speculative Generality, Message Chains, Middle Man and Refused Bequest. Beyond the single optional duplication observation, no actionable candidate was established. Primitive fields at the bounded frame/crypto ABI boundary, thin typed public wrappers, and platform switches are justified by the actual repository contract. Naming/duplication inside pinned crypto is intentionally excluded, and tooling-enforced formatting/compiler issues are not review findings.

## Limits

Source inspection cannot establish target dump/swap protection, power-loss durability, real Venue behavior or production qualification. This report makes none of those claims. No memory files were used. No repository files were modified by this review; this report is written outside the repository as requested.