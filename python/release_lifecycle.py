"""Signed ReleaseArtifact and lifecycle outbox for the existing Web control plane.

This module deliberately has no shell or remote-execution surface.  The Web
backend validates and signs an immutable command; a Linux node adapter owns
candidate loading, systemd activation, credential changes, and fencing.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import threading
from dataclasses import dataclass
from typing import Callable, Optional


REQUIRED_MANIFEST_FIELDS = {
    "artifact_id",
    "source_revision",
    "zig_version",
    "dependencies",
    "build_args",
    "test_results",
    "schema_registry",
    "payload_path",
    "payload_sha256",
    "signature",
}
LIFECYCLE_KINDS = {
    "credential_stage",
    "credential_activate",
    "credential_retire",
    "credential_revoke",
    "credential_rotate",
    "failover",
}
_SENSITIVE_NAMES = {
    "secret",
    "secret_material",
    "api_secret",
    "passphrase",
    "private_key",
    "trading_credential",
    "authorization",
    "cookie",
}


class ReleaseError(ValueError):
    pass


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode("utf-8")


def _without_signature(manifest: dict) -> dict:
    unsigned = dict(manifest)
    unsigned.pop("signature", None)
    return unsigned


def sign_manifest(manifest: dict, signing_key: bytes) -> str:
    if len(signing_key) != 32:
        raise ReleaseError("release signing key must be 32 bytes")
    return hmac.new(signing_key, _canonical(_without_signature(manifest)),
                    hashlib.sha256).hexdigest()


def sign_command(payload: dict, signing_key: bytes) -> str:
    if len(signing_key) != 32:
        raise ReleaseError("control signing key must be 32 bytes")
    return hmac.new(signing_key, _canonical(payload), hashlib.sha256).hexdigest()


def _ensure_safe_fields(value: object, path: str = "payload") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = str(key).lower().replace("-", "_")
            if normalized in _SENSITIVE_NAMES or any(
                    marker in normalized for marker in ("secret", "private_key", "passphrase")):
                raise ReleaseError(f"sensitive field is not allowed: {path}.{key}")
            _ensure_safe_fields(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _ensure_safe_fields(child, f"{path}[{index}]")


def _within(root: str, candidate: str) -> bool:
    root = os.path.realpath(root)
    candidate = os.path.realpath(candidate)
    return os.path.commonpath((root, candidate)) == root


@dataclass(frozen=True)
class ReleaseArtifact:
    artifact_id: str
    source_revision: str
    zig_version: str
    dependencies: tuple
    build_args: tuple
    test_results: dict
    schema_registry: int
    payload_path: str
    payload_sha256: str
    manifest_sha256: str
    signature: str

    @classmethod
    def load(cls, manifest_path: str, release_root: str, signing_key: bytes) -> "ReleaseArtifact":
        if not _within(release_root, manifest_path):
            raise ReleaseError("release manifest is outside the release root")
        try:
            with open(manifest_path, "r", encoding="utf-8") as handle:
                manifest = json.load(handle)
        except (OSError, json.JSONDecodeError) as error:
            raise ReleaseError(f"release manifest cannot be read: {error}") from error
        if not isinstance(manifest, dict) or not REQUIRED_MANIFEST_FIELDS.issubset(manifest):
            raise ReleaseError("release manifest is incomplete")
        _ensure_safe_fields(_without_signature(manifest))
        signature = manifest["signature"]
        if not isinstance(signature, str) or not hmac.compare_digest(
                signature, sign_manifest(manifest, signing_key)):
            raise ReleaseError("release signature is invalid")
        payload_path = os.path.realpath(os.path.join(
            os.path.dirname(manifest_path), str(manifest["payload_path"])))
        if not _within(release_root, payload_path):
            raise ReleaseError("release payload is outside the release root")
        try:
            with open(payload_path, "rb") as handle:
                payload_hash = hashlib.sha256(handle.read()).hexdigest()
        except OSError as error:
            raise ReleaseError(f"release payload cannot be read: {error}") from error
        if not hmac.compare_digest(payload_hash, str(manifest["payload_sha256"])):
            raise ReleaseError("release payload hash is invalid")
        if not isinstance(manifest["artifact_id"], str) or not manifest["artifact_id"]:
            raise ReleaseError("release artifact identity is invalid")
        return cls(
            artifact_id=manifest["artifact_id"],
            source_revision=str(manifest["source_revision"]),
            zig_version=str(manifest["zig_version"]),
            dependencies=tuple(manifest["dependencies"]),
            build_args=tuple(manifest["build_args"]),
            test_results=dict(manifest["test_results"]),
            schema_registry=int(manifest["schema_registry"]),
            payload_path=payload_path,
            payload_sha256=payload_hash,
            manifest_sha256=hashlib.sha256(_canonical(manifest)).hexdigest(),
            signature=signature,
        )


class MemoryApplier:
    """Test adapter; production supplies a Linux version-directory adapter."""

    def __init__(self):
        self.active: Optional[str] = None

    def activate(self, artifact: ReleaseArtifact) -> None:
        self.active = artifact.artifact_id


class FilesystemApplier:
    """Atomic version-directory publisher for a Linux deployment adapter."""

    def __init__(self, version_root: str, systemd_runner=None):
        self.version_root = os.path.realpath(version_root)
        self.systemd_runner = systemd_runner

    def _sync_root(self) -> None:
        if os.name == "posix":
            descriptor = os.open(self.version_root, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)

    def _publish_pointer(self, target: str) -> None:
        pointer = os.path.join(self.version_root, "current")
        temporary = os.path.join(
            self.version_root, f".current.{secrets.token_hex(8)}.tmp")
        os.symlink(target, temporary, target_is_directory=True)
        try:
            os.replace(temporary, pointer)
            self._sync_root()
        finally:
            if os.path.lexists(temporary):
                os.unlink(temporary)

    def activate(self, artifact: ReleaseArtifact) -> None:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", artifact.artifact_id):
            raise ReleaseError("release artifact identity is unsafe for a version directory")
        os.makedirs(self.version_root, mode=0o750, exist_ok=True)
        final_dir = os.path.join(self.version_root, artifact.artifact_id)
        temporary_dir = os.path.join(
            self.version_root,
            f".{artifact.artifact_id}.{secrets.token_hex(8)}.tmp")
        os.makedirs(temporary_dir, mode=0o750)
        try:
            payload = os.path.join(temporary_dir, "ringwin")
            with open(artifact.payload_path, "rb") as source, open(payload, "wb") as target:
                shutil.copyfileobj(source, target)
                target.flush()
                os.fsync(target.fileno())
            os.chmod(payload, 0o550)
            if os.name != "nt":
                directory_fd = os.open(temporary_dir, os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            pointer = os.path.join(self.version_root, "current")
            if os.path.exists(final_dir):
                deployed_payload = os.path.join(final_dir, "ringwin")
                with open(deployed_payload, "rb") as handle:
                    deployed_hash = hashlib.sha256(handle.read()).hexdigest()
                if not hmac.compare_digest(deployed_hash, artifact.payload_sha256):
                    raise ReleaseError("artifact identity already names different payload bytes")
                shutil.rmtree(temporary_dir)
            else:
                os.replace(temporary_dir, final_dir)
                self._sync_root()

            previous_target = None
            if os.path.islink(pointer):
                previous_target = os.readlink(pointer)
            elif os.path.lexists(pointer):
                raise ReleaseError("current version pointer is not a symlink")

            self._publish_pointer(artifact.artifact_id)
            try:
                if self.systemd_runner is not None:
                    self.systemd_runner(
                        ["systemctl", "reload-or-restart", "ringwin-role.target"])
            except Exception:
                if previous_target is None:
                    os.unlink(pointer)
                    self._sync_root()
                else:
                    self._publish_pointer(previous_target)
                    try:
                        self.systemd_runner(
                            ["systemctl", "reload-or-restart", "ringwin-role.target"])
                    except Exception:
                        pass
                raise
        except Exception:
            shutil.rmtree(temporary_dir, ignore_errors=True)
            raise


class ReleaseManager:
    def __init__(self, release_root: str, version_root: str, records_path: str,
                 signing_key: bytes, candidate_check: Callable[[ReleaseArtifact], bool],
                 applier) -> None:
        self.release_root = os.path.realpath(release_root)
        self.version_root = os.path.realpath(version_root)
        self.records_path = records_path
        self.signing_key = signing_key
        self.candidate_check = candidate_check
        self.applier = applier
        self._results = {}
        self._lock = threading.Lock()
        self._records = []
        if os.path.exists(records_path):
            with open(records_path, "r", encoding="utf-8") as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    record = json.loads(line)
                    self._records.append(record)
                    if record.get("command_identity") is not None and record.get("result"):
                        self._results[int(record["command_identity"])] = (
                            record.get("command_fingerprint", ""), record["result"])

    def records(self) -> list[dict]:
        return list(self._records)

    def active_artifact(self) -> Optional[str]:
        for record in reversed(self._records):
            if record.get("event") == "release_activated":
                return record["artifact_id"]
        return None

    def _append(self, record: dict) -> None:
        os.makedirs(os.path.dirname(os.path.realpath(self.records_path)), exist_ok=True)
        encoded = _canonical(record) + b"\n"
        with open(self.records_path, "ab") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        self._records.append(record)

    def _run(self, command_identity: int, manifest_path: str,
             expected_active: Optional[str], operation: str) -> dict:
        fingerprint = json.dumps({"operation": operation,
                                  "manifest_path": os.path.realpath(manifest_path),
                                  "expected_active": expected_active},
                                 sort_keys=True, separators=(",", ":"))
        with self._lock:
            return self._run_locked(command_identity, manifest_path, expected_active,
                                    operation, fingerprint)

    def _run_locked(self, command_identity: int, manifest_path: str,
                    expected_active: Optional[str], operation: str,
                    fingerprint: str) -> dict:
        if command_identity in self._results:
            previous_fingerprint, previous_result = self._results[command_identity]
            if previous_fingerprint != fingerprint:
                raise ReleaseError("release command identity conflict")
            return previous_result
        current = self.active_artifact()
        if current != expected_active:
            result = {"status": "rejected", "reason": "active release precondition failed",
                      "active_artifact": current}
            self._record_result(command_identity, operation, result, current, fingerprint)
            return result
        try:
            artifact = ReleaseArtifact.load(manifest_path, self.release_root, self.signing_key)
        except ReleaseError as error:
            result = {"status": "rejected", "reason": str(error), "active_artifact": current}
            self._record_result(command_identity, operation, result, current, fingerprint)
            return result
        if not self.candidate_check(artifact):
            result = {"status": "rejected", "reason": "candidate safety check failed",
                      "active_artifact": current}
            self._record_result(command_identity, operation, result, current, fingerprint)
            return result
        try:
            os.makedirs(self.version_root, exist_ok=True)
            self.applier.activate(artifact)
        except Exception as error:
            result = {"status": "rejected", "reason": f"activation failed: {error}",
                      "active_artifact": current}
            self._record_result(command_identity, operation, result, current, fingerprint)
            return result
        sequence = sum(1 for item in self._records if item.get("event") == "release_activated") + 1
        result = {"status": "activated", "artifact_id": artifact.artifact_id,
                  "activation_sequence": sequence, "previous_artifact": current}
        self._record_result(command_identity, operation, result, current, fingerprint,
                            artifact=artifact)
        return result

    def _record_result(self, command_identity: int, operation: str, result: dict,
                       current: Optional[str], command_fingerprint: str,
                       artifact: Optional[ReleaseArtifact] = None) -> None:
        record = {
            "event": "release_activated" if result["status"] == "activated" else "release_rejected",
            "command_identity": str(command_identity),
            "command_fingerprint": command_fingerprint,
            "operation": operation,
            "artifact_id": artifact.artifact_id if artifact else None,
            "manifest_sha256": artifact.manifest_sha256 if artifact else None,
            "active_before": current,
            "result": result,
        }
        self._append(record)
        self._results[command_identity] = (command_fingerprint, result)

    def deploy(self, command_identity: int, manifest_path: str,
               expected_active: Optional[str]) -> dict:
        return self._run(command_identity, manifest_path, expected_active, "deploy_release")

    def forward_rollback(self, command_identity: int, manifest_path: str,
                         expected_active: Optional[str]) -> dict:
        return self._run(command_identity, manifest_path, expected_active, "forward_rollback")


class LifecycleOutbox:
    """Atomic, signed handoff for credential and fencing node adapters."""

    def __init__(self, directory: str, signing_key: bytes):
        self.directory = os.path.realpath(directory)
        self.signing_key = signing_key
        os.makedirs(self.directory, exist_ok=True)

    def _path(self, command_identity: int) -> str:
        if int(command_identity) <= 0:
            raise ReleaseError("command identity must be positive")
        return os.path.join(self.directory, f"{int(command_identity)}.json")

    def submit(self, command_identity: int, kind: str, target: str, details: dict) -> dict:
        if kind not in LIFECYCLE_KINDS:
            raise ReleaseError("unsupported lifecycle command")
        payload = {"command_identity": int(command_identity), "kind": kind,
                   "target": str(target), "details": dict(details)}
        _ensure_safe_fields(payload)
        path = self._path(command_identity)
        if os.path.exists(path):
            existing = self.read(command_identity)
            if existing["payload"] != payload:
                raise ReleaseError("lifecycle command identity conflict")
            return existing
        envelope = {"payload": payload, "signature": sign_command(payload, self.signing_key)}
        temporary = f"{path}.tmp"
        with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(envelope, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        return envelope

    def read(self, command_identity: int) -> dict:
        with open(self._path(command_identity), "r", encoding="utf-8") as handle:
            envelope = json.load(handle)
        if not hmac.compare_digest(envelope["signature"],
                                   sign_command(envelope["payload"], self.signing_key)):
            raise ReleaseError("lifecycle command signature is invalid")
        return envelope
