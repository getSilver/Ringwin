# Python StrategyPackage installation

This implements local strategy-package-contract ticket 03. The normative package
contract is in RingWin's `.scratch/strategy-package-contract/issues/01-package-and-loading-contract.md`.
The implementation, current core, domain vocabulary and ADRs are unified on
`codex/strategy-package-03` in `D:/github/Ringwin-strategy-package-03`.

The merged control channel uses envelope version 2 and KillSwitch kind 9;
the current core keeps residual freeze/unfreeze kinds 7/8. Version 1 envelopes
are rejected, so both channel endpoints must use this revision. Old control-plane
fixture journals are not migrated to the current core schema. The existing Web
projection displays the shard's primary instrument and supports settlement scale 6
and one portfolio; unsupported scales or additional portfolios degrade explicitly.
This merge does not establish runtime or production qualification.

Installation validates and registers definitions. It does not import a strategy,
start a candidate Host, create an instance, or issue EnableTrading. Those paths
belong to subsequent tickets. Offline acceptance does not qualify a runtime,
account, platform, or live deployment.

## Signed container

The existing ReleaseArtifact envelope, signing key, candidate safety check,
OwnerSession, RiskWarning, command identity and expected-active precondition remain
in use. Legacy manifests without `payload_format` retain the single-binary format.
The new signed field `payload_format: "strategy_bundle_v1"` selects an uncompressed
TAR containing only regular files:

```text
ringwin
runtime-lock.json
runtime/<approved interpreter, Host and offline dependencies>
strategy-index.json
strategies/<definition-identity>/manifest.json
strategies/<definition-identity>/<all manifest-declared files>
```

No extraction API, script, interpreter or package installer is run. Each TAR header
is checked before reading its payload; links, directories, devices, GNU/PAX
extensions, duplicate/case-colliding names, file/directory collisions, unsafe
paths and nonzero trailing content are rejected. Paths have at most 1024 UTF-8
bytes and components at most 255 bytes, with Windows aliases and control characters
rejected. Containers and expanded data are capped at 512 MiB, 16384 files, and
64 MiB per file. Index, runtime lock, package manifest and outer release manifest
each have a 256 KiB limit. The package contract's 4096-file/256 MiB limits apply
independently to each definition.

The runtime lock is canonical JSON with exactly:

| Field | Meaning |
|---|---|
| `format_version` | integer 1 |
| `compatibility` | exact `host_build`, `python_abi`, `host_protocol`, `schema_registry` |
| `python_path`, `host_path` | distinct declared files under `runtime/` |
| `files` | sorted `{path,size_bytes,sha256}` records covering `ringwin` and every runtime file |

The approved deployment policy must explicitly supply `compatibility` (including
the full SHA-256 of these canonical runtime-lock bytes), all eight resource
`limits`, and the sorted supported `subscriptions`. There are no runtime-policy
defaults. The bundle's outer ReleaseArtifact `schema_registry` must be the positive
u128 integer corresponding to the approved Host registry's 32-digit hex identity.
The interpreter, Host, engine and dependencies are thus bound to approved bytes;
their real ABI and operational qualification remain build/qualification evidence,
not an inference from filenames. Runtime dependencies are delivered offline.

Package manifests and the index follow contract v1 exactly, including canonical
encoding, strict integer types, complete SHA-256, exact compatibility, sorted
inventories, schema identities and file coverage. Strategy packages cannot contain
compiled Python caches or native extensions; approved compiled dependencies belong
to the outer locked runtime. Installation never imports the declared entrypoint.

## Publication and Web results

Bundle DeployRelease/ForwardRollback commands must contain `manifest_sha256`: the
SHA-256 of the canonical signed outer manifest, including `signature`. RiskWarning
and the durable command fingerprint cover that digest. Changing the digest under
one command identity is a conflict; omitting it or supplying the wrong digest for
a bundle rejects the command. Legacy binary commands may omit it.

`ReleaseManager(..., strategy_policy=approved_policy)` validates all signed bytes
before calling FilesystemApplier (Linux) or WindowsFilesystemApplier. Both write and fsync an
isolated version directory, including the complete generated
`strategy-registry.json`; bundle files and directories become read-only. Only
then does it rename the directory and atomically publish `current`, using the
platform runtime adapter and restoration behavior. Linux uses its existing systemd
adapter and symlink pointer. Windows uses a flushed, atomically replaced ASCII
`current` file containing the artifact identity and a newline; the embedding node
supplies `runtime_runner` for its existing runtime manager. Windows seals files and
directories with a protected DACL granting the current service identity read/execute
and permission maintenance, without data/attribute writes. Reparse points (including
junctions) are rejected. This implements signed candidate installation; it does not
qualify Windows service management or power-loss recovery. Existing version directories
are verified against the complete signed inventory, file bytes, manifest and
generated registration before reuse.

The registry travels with the version directory, so publishing a pointer cannot
expose a partially registered bundle. Durable release records preserve historical
identity bindings; the current installed registry also survives a missing result
record. Missing or inconsistent publication history makes the operation `unknown`
and blocks new publication until reconciliation. It does not manufacture a success
or trading permission. Same-command retries use the existing persisted results;
active-version conflicts and same-definition/different-content conflicts reject.
Config/state schema identity and version also retain complete content digests;
another definition cannot redefine a published schema under the same identity/version.

Authenticated `/api/releases` returns a consistent release/registry snapshot,
including full definition and manifest identities, validation, active-release
membership, release results and reasons. The existing operations page renders
these values as escaped text. HTTP 200 with a rejected or unknown operation is
displayed as a failure/uncertainty, not a successful submission. All installation
records have `trading_authorized: false`.

## External qualification evidence

Configure `qualification_manifests` with approved paths under the existing release
root. Each is authenticated by the existing ReleaseArtifact loader, including its
payload digest. Its signed `test_results.strategy_packages` list contains records
with exactly `package_manifest_sha256`, `compatibility`, `scope`, and a boolean
`qualified`. These report artifacts cannot be deployed as runtimes.

The scope must explicitly contain `platform`, `os_build`, `node_identity`,
`environment`, `mode`, `config_sha256`, sorted nonempty `venues`,
`exchange_accounts`, `instruments`, `products`, and `capabilities`. Identity and
digest widths are checked; registry identity and runtime compatibility must match
the registered package. A report with a missing scope, mismatched final package
digest, invalid signature/payload or malformed verdict is rejected with a reason.

Reports are read outside installed package directories. Supplementary evidence
does not rewrite frozen package bytes. Web returns each authenticated report's
full manifest/payload hashes, exact scope and explicit verdict; absent evidence is
pending, and an authenticated negative verdict stays `not_qualified`. There is no
package-wide production-qualified boolean and no report can enable trading.

## Offline verification

`python -m unittest discover -s python -p test_strategy_package_release.py -v`
uses real authenticated HTTP and temporary version directories on Linux/WSL.
The bundled engine/interpreter/Host are labelled synthetic, hash-bound fixtures;
they are never executed. Windows skips these Linux-applier cases and separately
runs `WindowsPackageReleaseTests` for signed publication, restart rollback, unknown
first activation and junction rejection.
`node tools/verify-strategy-package-ui.cjs` checks shipped UI rendering and failure
classification through HTTP/DOM adapters; it is not a browser automation run.
The existing binary release, authentication and control-plane regression entries
remain available. No Demo credentials or real systemd calls are used by acceptance.

## New Python instances (task 04)

The operations page creates an unauthorized instance via authenticated, CSRF-protected
`POST /api/strategy-instances`; `GET` on the same path reports Ready or a concrete
failure. The request has exactly these fields:

```json
{"release_artifact":"approved-release","definition_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","package_manifest_sha256":"<64 lowercase hex>","strategy_identity":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","portfolio_identity":"cccccccccccccccccccccccccccccccc","decision_domain":"dddddddddddddddddddddddddddddddd","config_version":1,"config_json":"{\"warmup_events\":1}","config_sha256":"<SHA-256 of config_json ASCII bytes>","scopes":[{"venue":"okx","exchange_account":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","instrument":"ffffffffffffffffffffffffffffffff"}],"risk_budget":100,"initialization":"new"}
```

This is a binding example, not a trading configuration. The node embedding
`ControlPlaneApp` must supply `instance_source=CandidateSource(...)` built from its
sealed deployment ownership, approved integer risk budget and canonical QSHB input
snapshot. The source declares its actual shard, DecisionDomain, VirtualPortfolio,
sorted account/instrument scopes and budget. Every binding must match these values;
HTTP cannot supply input events or ownership policy. Missing source returns 503.
Input domain/registry, framing, coverage, record schema and depth payloads are
checked before callbacks. The backend normalizes transport batches into independently
supervised callbacks, retaining complete sequence coverage and filtering gaps;
batch boundaries do not change strategy events or state. The source covers sequence 1 through its declared last
barrier for explicit new-instance initialization. Existing identities cannot be
reinitialized or rebound. Binding bytes have a 64 KiB ceiling; the complete internal
candidate request, including input snapshot, has a 256 KiB ceiling.

The signed runtime inventory must include `runtime/ringwin-strategy-candidate`
on Linux or `runtime/ringwin-strategy-candidate.exe` on Windows,
the internal Zig adapter built under `bin/`, plus the locked
Python Host and its API/codec modules. This optional known runtime path receives
execute permission during installation. It is invoked by the backend, and has no
control commands, Gateway or trading admission path. The approved lock's `host_path`
points to `strategy_candidate_host.py`; its directory includes `strategy_api.py`,
`strategy_host.py`, `strategy_package.py` and `strategy_state.py` as locked files.
Before launch the backend reauthenticates the approved active release and compares
all installed bytes to that signed inventory. Keep the release manifests/payloads
available; registration alone cannot authorize execution of unverified disk files.

The adapter owns the existing Zig ManagedHost/HostSupervisor and anonymous framed
pipes. Empty BeginRecovery state denotes **only explicit initialization of a new
identity**; other Host modes continue to require valid checkpoints. No existing
instance failure falls back to initialization. Python starts with `-I -S -B`, a
clean environment, only approved runtime/package import roots and the standard
library. Its audit policy denies network/child-process actions and filesystem writes;
this remains trusted signed Python, not a hostile-code sandbox. Dependencies are
delivered offline. No credentials, sockets, activation identity or core capability
are passed to the Host.

The fixed API calls validate_config/create, bounded on_event callbacks and final
validate/snapshot. A fresh instance must restore the snapshot, agree on IntentSequence,
reproduce the same canonical payload and pass validate before Ready. Zig then
requests a checkpoint at that exact cursor, verifies its metadata, content identity,
private-state digest and next IntentSequence, and publishes it through the existing
DurableStore checkpoint Repository before returning Ready. Content storage commits
before its immutable catalog reference; Python supplies no storage path or commit proof.
Immutable Context/Event/OrderIntent/IntentGroup values carry
only the contract fields. Output checks cover exact types, declared kinds, complete
2–4-member groups, codec capacities, ownership, positive integer quantities/prices,
and continuous IntentSequence advancement including empty output and overflow.
Candidate outputs are counted and discarded. Ready never submits EnableTrading,
HostActivated or a candidate intent to the core.

The backend first probes actual allocation failure in the approved interpreter;
an unavailable or ineffective hard limit is rejected before any strategy code is
imported. Linux `prlimit` enforces the signed memory ceiling as address space for
each adapter/child process. Windows Job Objects enforce the ceiling as committed
memory per process. Windows creates the suspended adapter atomically in the job
using `PROC_THREAD_ATTRIBUTE_JOB_LIST`, then resumes it; child membership is inherited, breakaway is
disabled, and closing the backend's non-inherited job handle kills the whole tree.
The probe uses a 128 MiB job and requires MemoryError from a 256 MiB allocation;
startup failure is not accepted as enforcement evidence. Acceptance also attempts
a real 512 MiB allocation inside a candidate callback with a 256 MiB limit.
Bounded pipe readers support both platforms; diagnostic output is capped at 64 KiB
and retained reasons at 2 KiB. The backend monitors callback phases and absolute
total warmup deadlines outside Python, terminating the entire process group/job on
exhaustion; Zig also checks elapsed callback/warmup time. Windows inherits only the
OS-reported SystemRoot needed by Python's random source, with all Python dependencies
delivered offline in the signed inventory. Its fixture uses an isolated `_pth` file,
stdlib ZIP and declared DLLs/extensions, excluding user and site packages.
Data insufficiency, invalid config/state, exceptions, unsupported input, output
errors and exceeded budgets stay Stopped with a reason. A successful Host stays
resident, unauthorized, at Ready until the manager closes or the process exits.
Durable bindings and outcomes survive Web restart; Ready is never reconstructed
from disk without a Host. Restart reports Stopped/recovery-required. Multiple
resident instances belong to task 10.
Windows runs its own Ready/resource acceptance and does not depend on Linux passing,
as required by ADR 0010. Legacy WSL1 still rejects loading because its kernel ignores
RLIMIT_AS. Linux resource acceptance was rerun on an enforcing Debian 11 kernel;
see the [2026-11-18 target-machine report](research/2026-11-18-linux-development-validation.md).
This is offline Host evidence, not production qualification.

To recover a stopped instance, use the Web recovery button or authenticated
`POST /api/strategy-instances` with only
`{"operation":"recover","strategy_identity":"00000000000000000000000000000010"}`.
The backend keeps its immutable binding and reserves a higher Host generation in
the shared candidate namespace before launch. A running Host must first stop;
neither replay nor Ready restores trading authority. GET returns Recovering with
cursor/barrier progress, Ready with checkpoint evidence, or Stopped with a reason.

Recovery opens the committed checkpoint catalog and validates the referenced
content against the instance, definition, state schema and configuration version.
The node-owned input source may retain the full stream or supply only its tail;
replay must continuously cover the checkpoint cursor through the requested barrier.
An already committed publication is discoverable even if Web crashed before
recording its Ready acknowledgment. Missing/corrupt content, incompatible schema,
tail gaps, restore/validation failures and budget exhaustion refuse recovery;
they never initialize empty state or publish suspect callback state. The original
binding cannot be reused to bypass recovery. Windows uses the existing verification
file adapter; these functional checks do not establish power-loss durability or
production qualification on either platform.

Run `python3 -m unittest discover -s python -p test_strategy_instance.py -v` on
Linux after building its adapter, or `python -m unittest discover -s python
-p test_strategy_instance.py -v` on Windows after `zig build -Doptimize=ReleaseSafe`.
Also build `zig build strategy-authority-probe -Doptimize=ReleaseSafe` and place
`ringwin-strategy-authority-probe` beside the candidate executable. The authority,
configuration transition, and successor tests execute that real native probe.
The defaults are `.scratch/build/candidate-linux/bin/ringwin-strategy-candidate`
and `zig-out/bin/ringwin-strategy-candidate.exe` respectively; the optional
`RINGWIN_CANDIDATE_ENGINE` test environment variable selects another build of that
adapter. The fixture signs and installs the **real adapter, Python interpreter and
Host**, then drives authenticated HTTP. The engine payload and canonical depth
input are explicitly synthetic. It proves offline unauthorized loading, not live
node integration, economic qualification, OS/runtime qualification or deployment.

Ready instances can now use the existing `/risk-warning` and `/command` Web flow
with `kind=enable_trading` and their `strategy_identity`. The confirmation binds
the instance as well as the DecisionDomain and operational version. Instance
deadlines are converted from Web UTC seconds to canonical UTC nanoseconds before
signing. A package, successful release, or healthy process cannot enable itself.

The embedding node supplies `CandidateSource.authority`, a `NativeAuthority`
connection to its private native admission adapter, and its current fencing token.
`strategy_package_authority.Authority` borrows the existing Writer's shard and
journal; its `commit` callback must apply and durably commit through that same
owner before returning. It never bootstraps trading state or grants a budget.
The node owns this connection and must revoke on its EOF or failure. The adapter
checks the signed command, current Ready cursor, binding, SafetyGates and committed
barrier. It records HostActivated, supplies the actual session and batch, then
enables the Host gateway only after the runtime receives an exact cursor ACK.
An absent node adapter leaves EnableTrading unavailable.

The formal Linux engine role opens the existing Linux DurableStore in its
state directory and recovers the configured decision stream. Provision that
directory with a committed checkpoint for a sealed deployment and an
`engine.json` containing a positive `decision_stream` and the 64-character
hexadecimal `deployment_digest` from the deployment configuration. The
operator supplies the digest independently of the recovered journal.

After authenticating on the engine's existing Unix control socket, the
controller receives `H` followed by `V` (recovery only). The engine gates
`I` on Venue recovery. The adapter-produced canonical frame uses a little-endian
`u32` byte count and the canonical event bytes. The originating adapter
retains its durable input until the engine replies with the committed decision
barrier (`u64`, followed by zero as a `u32`).

The controller can read the next committed decision record with `C` followed
by its last consumed `u64` cursor. The reply starts with the next `u64`
cursor and `u32` payload length. A zero length indicates the cursor has
reached the committed barrier. A nonempty reply carries `u16` type, `u16`
schema, `u32` flags, the four `u64` journal clocks (source, receive,
monotonic, wall), one byte of time-presence flags, and the stable record
payload. All integers are little-endian. This includes derived facts and cold
history proof records in decision order.

Venue adapters own replay of their durable RawIngress. The formal engine
requires committed recovery evidence from the node role chain before admitting
new input. Host activation also requires the node-owned
journal-to-StrategyHost batch producer.

The node calls `InstanceManager.deliver` with its committed canonical input;
there is no HTTP input/frame injection endpoint. The locked Host wrapper creates
the existing QSHO envelope around fixed API OrderIntent or complete IntentGroup
values. Native Host ingress checks session, activation, published batch, cursor
and freshness, then commits through core ownership/risk/account/instrument
admission. The existing execution Gateway still rechecks each committed command
before sending. Native status and refusal reasons appear in the instance view.
The existing bounded Host gateway capacities fail closed on exhaustion.
Ready Hosts also consume this input without publishing output, advancing private
IntentSequence by the same callback path. Their current ACK cursor is tracked
separately from the published checkpoint evidence. A stale Ready enable stays
Ready for node-owned catch-up and a fresh explicit command. Runtime batches are
split through the same source normalizer as recovery, so transport batching is
invisible to package callbacks. Both pipe writes and reads share one deadline;
an unresponsive reader cannot keep the manager lock indefinitely.

TradingPause/StopKeepPositions/KillSwitch can use the same instance command
route. Core revocation precedes stopping the Host; the monitor also checks Host
death and native authority withdrawal. Faults revoke and latch through the core;
an unavailable revocation acknowledgment is explicitly reported. Restart and
replay remain unauthorized and require a fresh explicit enable. Stopping retains
the last published checkpoint and authoritative intent history. Only one resident
package Host is supported until task 10.

For task 06 acceptance also build `zig build strategy-authority-probe
-Doptimize=ReleaseSafe` alongside the candidate. This optional test executable
embeds the same native adapter with the existing single-account and multi-account
fixtures and a simulated Venue. Authenticated Web tests install the signed real
package runtime, apply the activation barrier, admit actual single/group Python
outputs and exercise Gateway sending/withdrawal. This is controlled offline
integration evidence, not a live node launcher or real Venue/deployment authority.
Windows and Linux qualification remain independent under ADR 0010.
