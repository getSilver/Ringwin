"""Web-owned, single-instance candidate loading; no trading command capability."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import secrets
import selectors
import shutil
import signal
import subprocess
import tempfile
import threading
import time

import release_lifecycle
import strategy_package as package


BINDING_FIELDS = {"release_artifact", "definition_identity", "package_manifest_sha256",
                  "strategy_identity", "portfolio_identity", "decision_domain", "config_version",
                  "config_sha256", "config_json", "scopes", "risk_budget", "initialization"}


class CandidateSource:
    """Node-owned scope and canonical QSHB input snapshot, outside Web requests.

    The embedding node supplies its sealed deployment ownership and ordered input
    batches. No HTTP field can supply or override either authority.
    """

    def __init__(self, *, shard, decision_domain, portfolio_identity, scopes, risk_budget, batches):
        package.uint(shard, 32, positive=False)
        package.identity(decision_domain)
        package.identity(portfolio_identity)
        validate_scopes(scopes)
        package.uint(risk_budget)
        self.shard = shard
        self.scope = json.loads(package.canonical(dict(decision_domain=decision_domain,
            portfolio_identity=portfolio_identity, scopes=scopes, risk_budget=risk_budget)))
        self.batches = tuple(batches)

    def prepare(self, binding):
        package.require(all(binding[k] == v for k, v in self.scope.items()), "deployment ownership or budget mismatch")
        package.require(all(type(b) is bytes and 128 <= len(b) <= 1048576 for b in self.batches),
                        "invalid canonical input snapshot")
        package.require(all(int.from_bytes(b[32:48], "little") == int(self.scope["decision_domain"], 16)
                            for b in self.batches), "canonical input DecisionDomain mismatch")
        barrier = int.from_bytes(self.batches[-1][88:96], "little") if self.batches else 0
        return self.shard, barrier, self.batches


def validate_scopes(scopes):
    package.require(type(scopes) is list and 0 < len(scopes) <= 256, "invalid scope capacity")
    keys = []
    for scope in scopes:
        package.fields(scope, {"venue", "exchange_account", "instrument"})
        package.require(scope["venue"] in ("okx", "binance", "bybit"), "unknown venue")
        package.identity(scope["exchange_account"])
        package.identity(scope["instrument"])
        keys.append((scope["venue"], scope["exchange_account"], scope["instrument"]))
    package.require(keys == sorted(set(keys)), "scopes must be sorted and unique")


class InstanceManager:
    def __init__(self, directory, releases, source):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.directory / "strategy-instances.jsonl"
        self.releases, self.source = releases, source
        self._lock = threading.RLock()
        self._records, self._hosts = {}, {}
        if self.path.exists():
            for line in self.path.read_bytes().splitlines():
                record = package.parse_json(line)
                self._records[record["binding"]["strategy_identity"]] = record
        # Loading a record cannot restore a process or reuse Ready authority.
        for record in self._records.values():
            if record["status"] in ("Ready", "Recovering"):
                record.update(status="Stopped", reason="Host absent; checkpoint recovery required")

    def _save(self, record):
        with self.path.open("ab") as handle:
            handle.write(package.canonical(record) + b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        self._records[record["binding"]["strategy_identity"]] = record

    def view(self):
        with self._lock:
            for identity, host in list(self._hosts.items()):
                if host["process"].poll() is not None:
                    record = dict(self._records[identity], status="Stopped", reason="candidate Host exited")
                    self._stop(identity)
                    self._save(record)
            return json.loads(package.canonical(list(self._records.values())))

    def create(self, binding):
        with self._lock, self.releases._lock:
            package.fields(binding, BINDING_FIELDS)
            binding = json.loads(package.canonical(binding))
            for key in ("definition_identity", "strategy_identity", "portfolio_identity", "decision_domain"):
                package.identity(binding[key])
            package.digest(binding["package_manifest_sha256"])
            package.digest(binding["config_sha256"])
            package.uint(binding["config_version"])
            package.uint(binding["risk_budget"])
            validate_scopes(binding["scopes"])
            package.require(binding["initialization"] == "new", "only explicit new-instance initialization is supported")
            package.require(type(binding["config_json"]) is str, "configuration must contain canonical JSON bytes")
            config = binding["config_json"].encode("ascii")
            package.require(len(package.canonical(binding)) <= 64 * 1024, "binding capacity exceeded")
            package.parse_json(config)
            package.require(hashlib.sha256(config).hexdigest() == binding["config_sha256"], "config digest mismatch")
            self.view()
            identity = binding["strategy_identity"]
            previous = self._records.get(identity)
            if previous:
                package.require(previous["binding"] == binding, "instance identity or ConfigVersion content conflict")
                return previous
            package.require(not self._hosts, "single candidate Host capacity; multiple instances require ticket 10")
            shard, barrier, batches = self.source.prepare(binding)
            root, manifest, lock = self._approved_package(binding)
            package.require(all(int.from_bytes(b[16:32], "little") == int(manifest["compatibility"]["schema_registry"], 16)
                                for b in batches), "canonical input schema registry mismatch")
            package.require(os.name == "posix" and shutil.which("prlimit") is not None,
                            "candidate OS memory enforcement unavailable")
            record = dict(binding=binding, status="Recovering", reason="", trading_authorized=False)
            self._save(record)
            temporary = tempfile.TemporaryDirectory(prefix="candidate-", dir=self.directory)
            work = Path(temporary.name)
            request = dict(binding=binding, manifest=manifest, package_root=str(root / "strategies" / binding["definition_identity"]),
                           python=str(root / lock["python_path"]), host=str(root / lock["host_path"]),
                           generation=secrets.randbits(63) + 1, shard=shard, barrier=barrier,
                           batches=[batch.hex() for batch in batches])
            data = package.canonical(request)
            process = None
            errors = (work / "host-errors.txt").open("w+b")
            try:
                package.require(len(data) <= package.MAX_JSON_BYTES, "candidate request capacity exceeded")
                (work / "request.json").write_bytes(data)
                limits = manifest["limits"]
                started = time.monotonic_ns()
                process = subprocess.Popen([
                    shutil.which("prlimit"), "--as=" + str(limits["max_memory_bytes"]), "--fsize=65536", "--",
                    str(root / "runtime/ringwin-strategy-candidate"), str(work / "request.json")],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, cwd=work,
                    env={"LANG": "C", "LC_ALL": "C"}, close_fds=True, start_new_session=True)
                self._hosts[identity] = dict(process=process, temporary=temporary, errors=errors)
                phase_budget = limits["max_warmup_ns"]
                pending = b""
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    while True:
                        remaining = min(phase_budget, limits["max_warmup_ns"] - (time.monotonic_ns() - started))
                        package.require(remaining > 0 and selector.select(remaining / 1e9),
                                        "candidate callback or warmup budget exhausted")
                        chunk = os.read(process.stdout.fileno(), 1024)
                        if not chunk:
                            process.wait(timeout=5)
                            errors.seek(0)
                            reason = errors.read(2048).decode("utf-8", "replace")
                            raise package.PackageError(f"candidate Host failed (exit {process.returncode}): " + reason)
                        pending += chunk
                        package.require(len(pending) <= 2048, "candidate result capacity exceeded")
                        while b"\n" in pending:
                            line, pending = pending.split(b"\n", 1)
                            result = json.loads(line)
                            if "phase" in result:
                                phase_budget = limits["max_callback_ns"]
                                continue
                            package.require(result["trading_authorized"] is False
                                            and result["cursor"] == barrier, "invalid Ready evidence")
                            record.update(status="Ready", evidence=result, reason="")
                            self._save(record)
                            return record
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                if process is not None:
                    self._stop(identity)
                else:
                    errors.close()
                    temporary.cleanup()
                record.update(status="Stopped", reason=str(error)[:2048])
                self._save(record)
                return record

    def _approved_package(self, binding):
        releases = self.releases
        package.require(not releases._publication_unknown, "release publication is unknown")
        package.require(isinstance(releases.applier, release_lifecycle.FilesystemApplier), "installed release backend required")
        active = releases.active_artifact()
        package.require(type(binding["release_artifact"]) is str and binding["release_artifact"] == active
                        and releases.applier.current_artifact() == active, "release is not current")
        registrations = releases._registrations()
        package.require(any(p["definition_identity"] == binding["definition_identity"]
                            and p["package_manifest_sha256"] == binding["package_manifest_sha256"]
                            and p["release_artifact"] == active for p in registrations), "package is not registered")
        approved = {r["manifest_sha256"] for r in releases.records()
                    if r.get("event") == "release_activated" and r.get("artifact_id") == active}
        artifact = None
        for path in Path(releases.release_root).glob("*.json"):
            try:
                candidate = release_lifecycle.ReleaseArtifact.load(str(path), releases.release_root,
                                                                  releases.signing_key, releases.strategy_policy)
                if candidate.artifact_id == active and candidate.manifest_sha256 in approved and candidate.bundle:
                    artifact = candidate
                    break
            except (OSError, ValueError):
                continue
        package.require(artifact is not None, "authenticated approved release bytes unavailable")
        package.require("runtime/ringwin-strategy-candidate" in artifact.bundle.files,
                        "approved candidate runtime adapter unavailable")
        root = Path(releases.version_root) / active
        package.require(not root.is_symlink(), "installed release must not be a symlink")
        for name, content in artifact.bundle.files.items():
            path = root / name
            package.require(not any(p.is_symlink() for p in (path, *path.parents) if p != root.parent)
                            and path.is_file() and path.stat().st_size == len(content)
                            and path.read_bytes() == content, "installed release differs from approved bytes")
        manifest = package.parse_json(artifact.bundle.files[f"strategies/{binding['definition_identity']}/manifest.json"])
        lock = package.parse_json(artifact.bundle.files["runtime-lock.json"])
        return root, manifest, lock

    def _stop(self, identity):
        host = self._hosts.pop(identity, None)
        if host is None:
            return
        process = host["process"]
        # The process group contains the Zig supervisor and its Python child.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
        process.stdin.close()
        process.stdout.close()
        host["errors"].close()
        host["temporary"].cleanup()

    def close(self):
        with self._lock:
            for identity in list(self._hosts):
                self._stop(identity)
