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

import strategy_package


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


class ActivationStateUnknown(RuntimeError):
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
    payload_bytes: bytes
    bundle: Optional[strategy_package.Bundle]

    @classmethod
    def load(cls, manifest_path: str, release_root: str, signing_key: bytes,
             strategy_policy=None) -> "ReleaseArtifact":
        if not _within(release_root, manifest_path):
            raise ReleaseError("release manifest is outside the release root")
        if not os.path.isfile(manifest_path):
            raise ReleaseError("release manifest is not a regular file")
        try:
            with open(manifest_path, "rb") as handle:
                encoded = handle.read(strategy_package.MAX_JSON_BYTES + 1)
            if len(encoded) > strategy_package.MAX_JSON_BYTES:
                raise ReleaseError("release manifest capacity exceeded")
            manifest = json.loads(encoded)
        except (OSError, ValueError, RecursionError) as error:
            raise ReleaseError(f"release manifest cannot be read: {error}") from error
        if not isinstance(manifest, dict) or not REQUIRED_MANIFEST_FIELDS.issubset(manifest):
            raise ReleaseError("release manifest is incomplete")
        try:
            _ensure_safe_fields(_without_signature(manifest))
        except RecursionError as error:
            raise ReleaseError("release metadata nesting capacity exceeded") from error
        if (type(manifest["dependencies"]) is not list or type(manifest["build_args"]) is not list
                or type(manifest["test_results"]) is not dict
                or type(manifest["payload_path"]) is not str):
            raise ReleaseError("release metadata has invalid field types")
        signature = manifest["signature"]
        if not isinstance(signature, str) or not re.fullmatch(r"[0-9a-f]{64}", signature) or not hmac.compare_digest(
                signature, sign_manifest(manifest, signing_key)):
            raise ReleaseError("release signature is invalid")
        if type(manifest["schema_registry"]) is not int or not 0 < manifest["schema_registry"] < 2 ** 128:
            raise ReleaseError("release schema registry identity is invalid")
        payload_path = os.path.realpath(os.path.join(
            os.path.dirname(manifest_path), str(manifest["payload_path"])))
        if not _within(release_root, payload_path):
            raise ReleaseError("release payload is outside the release root")
        if not os.path.isfile(payload_path):
            raise ReleaseError("release payload is not a regular file")
        if type(manifest["payload_sha256"]) is not str or not re.fullmatch(r"[0-9a-f]{64}", manifest["payload_sha256"]):
            raise ReleaseError("release payload hash is invalid")
        try:
            with open(payload_path, "rb") as handle:
                payload_bytes = handle.read(strategy_package.MAX_BUNDLE_BYTES + 1)
                if len(payload_bytes) > strategy_package.MAX_BUNDLE_BYTES:
                    raise ReleaseError("release payload capacity exceeded")
                payload_hash = hashlib.sha256(payload_bytes).hexdigest()
        except OSError as error:
            raise ReleaseError(f"release payload cannot be read: {error}") from error
        if not hmac.compare_digest(payload_hash, str(manifest["payload_sha256"])):
            raise ReleaseError("release payload hash is invalid")
        if not isinstance(manifest["artifact_id"], str) or not manifest["artifact_id"]:
            raise ReleaseError("release artifact identity is invalid")
        payload_format = manifest.get("payload_format", "binary")
        if payload_format not in ("binary", "strategy_bundle_v1"):
            raise ReleaseError("unsupported release payload format")
        try:
            bundle = (strategy_package.validate_bundle(payload_bytes, strategy_policy)
                      if payload_format == "strategy_bundle_v1" else None)
            if bundle and manifest["schema_registry"] != int(
                    strategy_policy["compatibility"]["schema_registry"], 16):
                raise ReleaseError("release schema registry differs from the approved runtime")
        except (ValueError, TypeError, KeyError, RecursionError) as error:
            raise ReleaseError(str(error)) from error
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
            payload_bytes=payload_bytes,
            bundle=bundle,
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
        if systemd_runner is None:
            raise ReleaseError("Linux filesystem activation requires a systemd runner")
        self.version_root = os.path.realpath(version_root)
        self.systemd_runner = systemd_runner

    def _sync_root(self) -> None:
        if os.name == "posix":
            descriptor = os.open(self.version_root, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)

    def _is_link(self, path):
        return os.path.islink(path) or (os.name == "nt" and bool(os.lstat(path).st_file_attributes & 0x400))

    def current_artifact(self) -> Optional[str]:
        pointer = os.path.join(self.version_root, "current")
        if not os.path.lexists(pointer):
            return None
        if not self._is_link(pointer):
            raise ReleaseError("current version pointer is not a symlink")
        target = os.readlink(pointer)
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", target):
            raise ReleaseError("current version pointer escapes the version root")
        directory = os.path.join(self.version_root, target)
        if self._is_link(directory) or not os.path.isdir(directory):
            raise ReleaseError("current version directory is invalid")
        return target

    def registered_packages(self) -> list[dict]:
        current = self.current_artifact()
        if current is None:
            return []
        path = os.path.join(self.version_root, current, "strategy-registry.json")
        if not os.path.lexists(path):
            return []
        try:
            if self._is_link(path) or not os.path.isfile(path):
                raise ReleaseError("installed strategy registry is not a regular file")
            with open(path, "rb") as handle:
                data = handle.read(8 * 1024 * 1024 + 1)
            if len(data) > 8 * 1024 * 1024:
                raise ReleaseError("installed strategy registry capacity exceeded")
            packages = json.loads(data)
            if type(packages) is not list or _canonical(packages) != data:
                raise ReleaseError("installed strategy registry is invalid")
            for package in packages:
                strategy_package.identity(package["definition_identity"])
                strategy_package.digest(package["package_manifest_sha256"])
                if package["release_artifact"] != current or package["trading_authorized"] is not False:
                    raise ReleaseError("installed strategy registry binding is invalid")
            return packages
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise ReleaseError(f"installed strategy registry cannot be read: {error}") from error

    def _discard_staging(self, directory: str) -> None:
        if not os.path.exists(directory):
            return
        if (os.path.dirname(os.path.realpath(directory)) != self.version_root
                or not os.path.basename(directory).startswith(".")
                or not directory.endswith(".tmp") or self._is_link(directory)):
            raise ReleaseError("invalid staging cleanup path")
        for root, _, _ in os.walk(directory):
            os.chmod(root, 0o750)
        shutil.rmtree(directory)

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

    def _restore_previous(self, pointer: str, previous_target: Optional[str]) -> None:
        if previous_target is None:
            try:
                if os.path.lexists(pointer):
                    os.unlink(pointer)
                self._sync_root()
            except Exception as cleanup_error:
                raise ActivationStateUnknown(
                    "candidate pointer could not be removed") from cleanup_error
            raise ActivationStateUnknown(
                "activation failed with no previous runtime to restore")
        try:
            self._publish_pointer(previous_target)
            self._restart()
        except Exception as rollback_error:
            raise ActivationStateUnknown(
                "previous runtime could not be restored") from rollback_error

    def _restart(self):
        self.systemd_runner(["systemctl", "reload-or-restart", "ringwin-role.target"])

    def activate(self, artifact: ReleaseArtifact) -> None:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", artifact.artifact_id):
            raise ReleaseError("release artifact identity is unsafe for a version directory")
        os.makedirs(self.version_root, mode=0o750, exist_ok=True)
        final_dir = os.path.join(self.version_root, artifact.artifact_id)
        if os.path.lexists(final_dir) and (self._is_link(final_dir) or not os.path.isdir(final_dir)):
            raise ReleaseError("existing version is not a regular version directory")
        temporary_dir = os.path.join(
            self.version_root,
            f".{artifact.artifact_id}.{secrets.token_hex(8)}.tmp")
        os.makedirs(temporary_dir, mode=0o750)
        try:
            files = (artifact.bundle.files if artifact.bundle else
                     {"ringwin": artifact.payload_bytes})
            executables = artifact.bundle.executable_paths if artifact.bundle else ("ringwin",)
            for name, content in files.items():
                destination = os.path.join(temporary_dir, *name.split("/"))
                os.makedirs(os.path.dirname(destination), mode=0o750, exist_ok=True)
                with open(destination, "xb") as target:
                    target.write(content)
                    target.flush()
                    os.fsync(target.fileno())
                os.chmod(destination, 0o550 if name in executables else 0o440)
            if artifact.bundle:
                registry = _canonical([dict(p, release_artifact=artifact.artifact_id)
                                       for p in artifact.bundle.packages])
                with open(os.path.join(temporary_dir, "strategy-registry.json"), "xb") as handle:
                    handle.write(registry)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(os.path.join(temporary_dir, "strategy-registry.json"), 0o440)
            manifest_identity = os.path.join(temporary_dir, "manifest.sha256")
            with open(manifest_identity, "w", encoding="ascii", newline="\n") as handle:
                handle.write(f"{artifact.manifest_sha256}\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(manifest_identity, 0o440)
            if os.name != "nt":
                for directory, _, _ in os.walk(temporary_dir, topdown=False):
                    if artifact.bundle:
                        os.chmod(directory, 0o550)
                    directory_fd = os.open(directory, os.O_RDONLY)
                    try:
                        os.fsync(directory_fd)
                    finally:
                        os.close(directory_fd)
            pointer = os.path.join(self.version_root, "current")
            if os.path.exists(final_dir):
                expected_names = set(files) | {"manifest.sha256"}
                if artifact.bundle:
                    expected_names.add("strategy-registry.json")
                actual_names = set()
                for root, directories, filenames in os.walk(final_dir):
                    for name in directories + filenames:
                        deployed = os.path.join(root, name)
                        if self._is_link(deployed):
                            raise ReleaseError("installed payload contains a link")
                    for name in filenames:
                        deployed = os.path.join(root, name)
                        if not os.path.isfile(deployed):
                            raise ReleaseError("installed payload contains a non-regular file")
                        actual_names.add(os.path.relpath(deployed, final_dir).replace(os.sep, "/"))
                if actual_names != expected_names:
                    raise ReleaseError("installed payload inventory differs from the signed release")
                for name, content in files.items():
                    deployed_payload = os.path.join(final_dir, *name.split("/"))
                    current_path = final_dir
                    for component in name.split("/"):
                        current_path = os.path.join(current_path, component)
                        if self._is_link(current_path):
                            raise ReleaseError("installed payload contains a link")
                    with open(deployed_payload, "rb") as handle:
                        deployed_hash = hashlib.sha256(handle.read(len(content) + 1)).digest()
                    if not hmac.compare_digest(deployed_hash, hashlib.sha256(content).digest()):
                        raise ReleaseError("artifact identity already names different payload bytes")
                try:
                    with open(os.path.join(final_dir, "manifest.sha256"),
                              encoding="ascii") as handle:
                        deployed_manifest_hash = handle.read().strip()
                except OSError as error:
                    raise ReleaseError(
                        "artifact identity is missing its deployed manifest") from error
                if not hmac.compare_digest(deployed_manifest_hash,
                                           artifact.manifest_sha256):
                    raise ReleaseError("artifact identity already names a different manifest")
                if artifact.bundle:
                    with open(os.path.join(final_dir, "strategy-registry.json"), "rb") as handle:
                        if handle.read(len(registry) + 1) != registry:
                            raise ReleaseError("installed registry differs from the validated release")
                self._discard_staging(temporary_dir)
            else:
                os.replace(temporary_dir, final_dir)
                self._sync_root()

            previous_target = self.current_artifact()

            try:
                self._publish_pointer(artifact.artifact_id)
                self._restart()
            except Exception as activation_error:
                self._restore_previous(pointer, previous_target)
                raise activation_error
        except Exception:
            self._discard_staging(temporary_dir)
            raise


class WindowsFilesystemApplier(FilesystemApplier):
    """Same signed installation, with an atomic file pointer and Windows ACLs.

    The embedding Windows node supplies its existing runtime restart adapter.
    This does not qualify service management or power-loss durability.
    """

    def __init__(self, version_root, runtime_runner):
        if os.name != "nt" or not callable(runtime_runner):
            raise ReleaseError("Windows activation requires a Windows runtime adapter")
        self.version_root = os.path.realpath(version_root)
        self.runtime_runner = runtime_runner

    def _restart(self):
        self.runtime_runner()

    def current_artifact(self):
        pointer = os.path.join(self.version_root, "current")
        if not os.path.lexists(pointer):
            return None
        if os.lstat(pointer).st_file_attributes & 0x400 or not os.path.isfile(pointer):
            raise ReleaseError("current version pointer is not a regular file")
        with open(pointer, "rb") as handle:
            content = handle.read(130)
        if not re.fullmatch(rb"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\n", content):
            raise ReleaseError("current version pointer escapes the version root")
        target = content[:-1].decode("ascii")
        directory = os.path.join(self.version_root, target)
        if not os.path.isdir(directory) or os.lstat(directory).st_file_attributes & 0x400:
            raise ReleaseError("current version directory is invalid")
        return target

    def _discard_staging(self, directory):
        # Validate the owned staging path before changing any attributes.
        if os.path.exists(directory):
            if (os.path.dirname(os.path.realpath(directory)) != self.version_root
                    or not os.path.basename(directory).startswith(".")
                    or not directory.endswith(".tmp") or self._is_link(directory)):
                raise ReleaseError("invalid staging cleanup path")
            for root, _, files in os.walk(directory):
                for name in files:
                    os.chmod(os.path.join(root, name), 0o600)
        super()._discard_staging(directory)

    def _publish_pointer(self, target):
        import strategy_windows as windows
        directory = os.path.join(self.version_root, target)
        for root, directories, files in os.walk(directory):
            if any(os.lstat(path).st_file_attributes & 0x400
                   for path in [root] + [os.path.join(root, name) for name in directories + files]):
                raise ReleaseError("installed payload contains a reparse point")
        for root, directories, files in os.walk(directory, topdown=False):
            for name in files:
                path = os.path.join(root, name)
                windows.set_permissions(path)
            windows.set_permissions(root)
        temporary = os.path.join(self.version_root, f".current.{secrets.token_hex(8)}.tmp")
        try:
            with open(temporary, "xb") as handle:
                handle.write((target + "\n").encode("ascii"))
                handle.flush()
                os.fsync(handle.fileno())
            move = windows.api(windows.kernel, "MoveFileExW", windows.w.BOOL,
                               windows.w.LPCWSTR, windows.w.LPCWSTR, windows.w.DWORD)
            windows.checked(move(temporary, os.path.join(self.version_root, "current"), 0x1 | 0x8))
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


class ReleaseManager:
    def __init__(self, release_root: str, version_root: str, records_path: str,
                 signing_key: bytes, candidate_check: Callable[[ReleaseArtifact], bool],
                 applier, strategy_policy=None, qualification_manifests=()) -> None:
        self.release_root = os.path.realpath(release_root)
        self.version_root = os.path.realpath(version_root)
        self.records_path = records_path
        self.signing_key = signing_key
        self.candidate_check = candidate_check
        self.applier = applier
        self.strategy_policy = json.loads(_canonical(strategy_policy))
        self.qualification_manifests = tuple(os.path.realpath(p) for p in qualification_manifests)
        self._results = {}
        self._lock = threading.RLock()
        self._publication_unknown = False
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
        if isinstance(self.applier, FilesystemApplier):
            self._publication_unknown = self.applier.current_artifact() != self.active_artifact()
        if self._records and self._records[-1].get("event") == "release_activation_unknown":
            self._publication_unknown = True

    def records(self) -> list[dict]:
        return list(self._records)

    def _registrations(self) -> list[dict]:
        packages = {}
        for record in self._records:
            if record.get("event") == "release_activated":
                for package in record.get("strategy_packages", []):
                    packages[package["definition_identity"]] = package
        if isinstance(self.applier, FilesystemApplier):
            for package in self.applier.registered_packages():
                previous = packages.get(package["definition_identity"])
                if previous and previous["package_manifest_sha256"] != package["package_manifest_sha256"]:
                    raise ReleaseError("installed definition identity conflicts with release history")
                packages[package["definition_identity"]] = package
        return json.loads(_canonical([packages[key] for key in sorted(packages)]))

    def release_view(self) -> dict:
        with self._lock:
            return {"active_artifact": self.active_artifact(),
                    "release_records": self.records(), **self.strategy_catalog()}

    def strategy_catalog(self) -> dict:
        packages = self._registrations()
        for package in packages:
            package["active_release"] = package["release_artifact"] == self.active_artifact()
        by_hash = {p["package_manifest_sha256"]: p for p in packages}
        rejected = []
        for path in self.qualification_manifests:
            try:
                artifact = ReleaseArtifact.load(path, self.release_root, self.signing_key)
                reports = artifact.test_results.get("strategy_packages")
                strategy_package.require(type(reports) is list and len(reports) <= 256,
                                         "qualification report inventory is missing or too large")
                validated = []
                for report in reports:
                    strategy_package.validate_qualification(report)
                    package = by_hash.get(report["package_manifest_sha256"])
                    strategy_package.require(package is not None, "qualification package digest is not registered")
                    strategy_package.require(report["compatibility"] == package["compatibility"],
                                             "qualification runtime compatibility mismatch")
                    strategy_package.require(artifact.schema_registry == int(
                        report["compatibility"]["schema_registry"], 16),
                        "qualification artifact registry mismatch")
                    validated.append((package, {
                        "report_artifact": artifact.artifact_id,
                        "report_manifest_sha256": artifact.manifest_sha256,
                        "report_payload_sha256": artifact.payload_sha256,
                        "scope": report["scope"],
                        "status": "qualified" if report["qualified"] else "not_qualified"}))
                for package, report in validated:
                    package["qualifications"].append(report)
            except (ValueError, OSError, TypeError, KeyError, RecursionError) as error:
                rejected.append({"manifest_path": path, "reason": str(error)})
        return {"strategy_packages": packages, "qualification_rejections": rejected}

    def active_artifact(self) -> Optional[str]:
        if self._publication_unknown:
            return None
        for record in reversed(self._records):
            if record.get("event") == "release_activation_unknown":
                return None
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
             expected_active: Optional[str], operation: str, expected_manifest_sha256=None) -> dict:
        if type(command_identity) is not int or not 0 < command_identity < 2 ** 128:
            raise ReleaseError("release command identity is invalid")
        if type(manifest_path) is not str or not manifest_path:
            raise ReleaseError("release manifest path is invalid")
        if expected_active is not None and type(expected_active) is not str:
            raise ReleaseError("active release precondition is invalid")
        content = {"operation": operation, "manifest_path": os.path.realpath(manifest_path),
                   "expected_active": expected_active}
        if expected_manifest_sha256 is not None:
            content["manifest_sha256"] = expected_manifest_sha256
        fingerprint = json.dumps(content, sort_keys=True, separators=(",", ":"))
        with self._lock:
            return self._run_locked(command_identity, manifest_path, expected_active,
                                    operation, fingerprint, expected_manifest_sha256)

    def _run_locked(self, command_identity: int, manifest_path: str,
                    expected_active: Optional[str], operation: str,
                    fingerprint: str, expected_manifest_sha256=None) -> dict:
        if command_identity in self._results:
            previous_fingerprint, previous_result = self._results[command_identity]
            if previous_fingerprint != fingerprint:
                raise ReleaseError("release command identity conflict")
            if not self._publication_unknown or previous_result["status"] == "unknown":
                return previous_result
        current = self.active_artifact()
        if self._publication_unknown:
            return {"status": "unknown", "reason": "release publication requires reconciliation",
                    "active_artifact": None}
        if current != expected_active:
            result = {"status": "rejected", "reason": "active release precondition failed",
                      "active_artifact": current}
            self._record_result(command_identity, operation, result, current, fingerprint)
            return result
        try:
            artifact = ReleaseArtifact.load(manifest_path, self.release_root, self.signing_key,
                                            self.strategy_policy)
            if artifact.bundle and expected_manifest_sha256 is None:
                raise ReleaseError("bundle requires the approved release manifest SHA-256")
            if expected_manifest_sha256 is not None and (
                    type(expected_manifest_sha256) is not str
                    or not re.fullmatch(r"[0-9a-f]{64}", expected_manifest_sha256)
                    or expected_manifest_sha256 != artifact.manifest_sha256):
                raise ReleaseError("approved release manifest SHA-256 mismatch")
            registered = {p["definition_identity"]: p["package_manifest_sha256"]
                          for p in self._registrations()}
            if "strategy_packages" in artifact.test_results:
                raise ReleaseError("qualification evidence is not a deployable runtime")
            if artifact.bundle:
                schema_contents = {}
                for package in self._registrations() + list(artifact.bundle.packages):
                    for kind in ("config_schema", "state_schema"):
                        schema = package[kind]
                        key = (schema["identity"], schema["version"])
                        digest = package.get(kind + "_sha256")
                        if digest is None or schema_contents.setdefault(key, digest) != digest:
                            raise ReleaseError("schema identity and version already names different content")
                for package in artifact.bundle.packages:
                    previous = registered.get(package["definition_identity"])
                    if previous is not None and previous != package["package_manifest_sha256"]:
                        raise ReleaseError("definition identity already names different package content")
        except ReleaseError as error:
            result = {"status": "rejected", "reason": str(error), "active_artifact": current}
            self._record_result(command_identity, operation, result, current, fingerprint)
            return result
        if not self.candidate_check(artifact):
            result = {"status": "rejected", "reason": "candidate safety check failed",
                      "active_artifact": current}
            self._record_result(command_identity, operation, result, current, fingerprint,
                                artifact=artifact)
            return result
        try:
            os.makedirs(self.version_root, exist_ok=True)
            self.applier.activate(artifact)
        except ActivationStateUnknown as error:
            self._publication_unknown = True
            result = {"status": "unknown", "reason": f"activation state unknown: {error}",
                      "active_artifact": None}
            self._record_result(command_identity, operation, result, current, fingerprint,
                                artifact=artifact)
            return result
        except Exception as error:
            result = {"status": "rejected", "reason": f"activation failed: {error}",
                      "active_artifact": current}
            self._record_result(command_identity, operation, result, current, fingerprint,
                                artifact=artifact)
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
        event = {"activated": "release_activated",
                 "unknown": "release_activation_unknown"}.get(
                     result["status"], "release_rejected")
        record = {
            "event": event,
            "command_identity": str(command_identity),
            "command_fingerprint": command_fingerprint,
            "operation": operation,
            "artifact_id": artifact.artifact_id if artifact else None,
            "manifest_sha256": artifact.manifest_sha256 if artifact else None,
            "active_before": current,
            "result": result,
        }
        if artifact and artifact.bundle and result["status"] == "activated":
            record["strategy_packages"] = [dict(package, release_artifact=artifact.artifact_id)
                                           for package in artifact.bundle.packages]
        try:
            self._append(record)
        except OSError:
            self._publication_unknown = True
            result.clear()
            result.update(status="unknown", reason="release result could not be persisted",
                          active_artifact=None)
        self._results[command_identity] = (command_fingerprint, result)

    def deploy(self, command_identity: int, manifest_path: str,
               expected_active: Optional[str], expected_manifest_sha256=None) -> dict:
        return self._run(command_identity, manifest_path, expected_active, "deploy_release",
                         expected_manifest_sha256)

    def forward_rollback(self, command_identity: int, manifest_path: str,
                         expected_active: Optional[str], expected_manifest_sha256=None) -> dict:
        return self._run(command_identity, manifest_path, expected_active, "forward_rollback",
                         expected_manifest_sha256)


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
