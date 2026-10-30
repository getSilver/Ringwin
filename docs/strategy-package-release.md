# Python StrategyPackage installation

This implements local strategy-package-contract ticket 03. The normative package
contract is in RingWin's `.scratch/strategy-package-contract/issues/01-package-and-loading-contract.md`.
The current domain vocabulary and ADRs are on `codex/strategy-package-03`; this
control-plane branch retains the existing Web and Linux publisher.

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
before calling the existing FilesystemApplier. The applier writes and fsyncs an
isolated version directory, including the complete generated
`strategy-registry.json`; bundle files and directories become read-only. Only
then does it rename the directory and atomically publish `current`, using the
existing systemd adapter and restoration behavior. Existing version directories
are verified against the complete signed inventory, file bytes, manifest and
generated registration before reuse.

The registry travels with the version directory, so publishing a pointer cannot
expose a partially registered bundle. Durable release records preserve historical
identity bindings; the current installed registry also survives a missing result
record. Missing or inconsistent publication history makes the operation `unknown`
and blocks new publication until reconciliation. It does not manufacture a success
or trading permission. Same-command retries use the existing persisted results;
active-version conflicts and same-definition/different-content conflicts reject.

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
they are never executed. Windows skips these Linux-applier cases.
`node tools/verify-strategy-package-ui.cjs` checks shipped UI rendering and failure
classification through HTTP/DOM adapters; it is not a browser automation run.
The existing binary release, authentication and control-plane regression entries
remain available. No Demo credentials or real systemd calls are used by acceptance.
