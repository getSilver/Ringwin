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
reproduce the same canonical payload and pass validate before Ready. This is an
in-memory private-state roundtrip, not checkpoint publication or restart recovery.
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
memory per process. The Windows adapter starts suspended, is assigned to the job,
and is resumed only after assignment; child membership is inherited, breakaway is
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
from disk without a Host. Restart reports Stopped/recovery-required. Checkpoint
publication/recovery and multiple resident instances belong to tasks 05 and 10.
Windows runs its own Ready/resource acceptance and does not depend on Linux passing,
as required by ADR 0010. Legacy WSL1 still rejects loading because its kernel ignores
RLIMIT_AS; Linux resource acceptance remains pending on a genuinely enforcing kernel.

Run `python3 -m unittest discover -s python -p test_strategy_instance.py -v` on
Linux after building its adapter, or `python -m unittest discover -s python
-p test_strategy_instance.py -v` on Windows after `zig build -Doptimize=ReleaseSafe`.
The defaults are `.scratch/build/candidate-linux/bin/ringwin-strategy-candidate`
and `zig-out/bin/ringwin-strategy-candidate.exe` respectively; the optional
`RINGWIN_CANDIDATE_ENGINE` test environment variable selects another build of that
adapter. The fixture signs and installs the **real adapter, Python interpreter and
Host**, then drives authenticated HTTP. The engine payload and canonical depth
input are explicitly synthetic. It proves offline unauthorized loading, not live
node integration, economic qualification, OS/runtime qualification or deployment.
