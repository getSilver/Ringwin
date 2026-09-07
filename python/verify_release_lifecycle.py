"""Acceptance tests for the signed release and lifecycle backend seam."""

import hashlib
import hmac
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release_lifecycle


KEY = bytes(range(32))


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"acceptance failed: {message}")


def write_artifact(root: str, artifact_id: str, payload: bytes, signature_key: bytes,
                   **overrides) -> str:
    payload_name = f"{artifact_id}.elf"
    with open(os.path.join(root, payload_name), "wb") as handle:
        handle.write(payload)
    manifest = {
        "artifact_id": artifact_id,
        "source_revision": "abc123",
        "zig_version": "0.17.0-dev.315+5b647b792",
        "dependencies": ["stdlib@pinned"],
        "build_args": ["-OReleaseSafe", "--target=x86_64-linux-gnu"],
        "test_results": {"debug": "195/195", "release_safe": "195/195"},
        "schema_registry": 6,
        "payload_path": payload_name,
        "payload_sha256": hashlib.sha256(payload).hexdigest(),
    }
    manifest.update(overrides)
    manifest["signature"] = release_lifecycle.sign_manifest(manifest, signature_key)
    path = os.path.join(root, f"{artifact_id}.json")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
    return path


def filesystem_phase(root: str, good: str) -> None:
    if os.name == "nt":
        return
    observed_at_restart = []
    filesystem_root = os.path.join(root, "filesystem-versions")

    def restart(_command):
        pointer = os.path.join(filesystem_root, "current")
        observed_at_restart.append(os.path.basename(os.path.realpath(pointer)))
        if observed_at_restart[-1] == "release-b":
            raise RuntimeError("candidate restart failed")

    manager = release_lifecycle.ReleaseManager(
        root, filesystem_root, os.path.join(root, "filesystem-records.jsonl"), KEY,
        candidate_check=lambda artifact: True,
        applier=release_lifecycle.FilesystemApplier(
            filesystem_root, systemd_runner=restart),
    )
    result = manager.deploy(103, good, expected_active=None)
    expect(result["status"] == "activated", "filesystem release activation")
    current = os.path.join(filesystem_root, "current")
    expect(os.path.islink(current), "current version pointer must be a symlink")
    expect(os.path.basename(os.path.realpath(current)) == "release-a",
           "atomic current version pointer")
    expect(observed_at_restart == ["release-a"],
           "current must be published before systemd restart")

    second_manifest = write_artifact(root, "release-b", b"second-release", KEY)
    failed = manager.deploy(104, second_manifest, expected_active="release-a")
    expect(failed["status"] == "rejected", "failed restart must reject activation")
    expect(os.path.basename(os.path.realpath(current)) == "release-a",
           "failed restart must restore the previous current release")


def main() -> None:
    root = tempfile.mkdtemp(prefix="ringwin-release-")
    try:
        payload = b"release-safe-linux-binary"
        good = write_artifact(root, "release-a", payload, KEY)
        manager = release_lifecycle.ReleaseManager(
            root, os.path.join(root, "versions"), os.path.join(root, "records.jsonl"), KEY,
            candidate_check=lambda artifact: artifact.schema_registry == 6,
            applier=release_lifecycle.MemoryApplier(),
        )

        result = manager.deploy(100, good, expected_active=None)
        expect(result["status"] == "activated", "signed artifact must activate")
        expect(manager.active_artifact() == "release-a", "active release identity")

        duplicate = manager.deploy(100, good, expected_active=None)
        expect(duplicate == result, "replaying a release command must be idempotent")
        expect(len(manager.records()) == 1, "duplicate must not append another release record")

        bad = write_artifact(root, "release-b", payload, KEY, schema_registry=99)
        rejected = manager.deploy(101, bad, expected_active="release-a")
        expect(rejected["status"] == "rejected", "candidate gate must fail closed")
        expect(manager.active_artifact() == "release-a", "failed activation keeps current release")

        rollback = manager.forward_rollback(102, good, expected_active="release-a")
        expect(rollback["status"] == "activated", "forward rollback is a new activation")
        expect(rollback["activation_sequence"] == 2, "activation sequence only moves forward")

        filesystem_phase(root, good)

        outbox = release_lifecycle.LifecycleOutbox(os.path.join(root, "outbox"), KEY)
        first = outbox.submit(200, "credential_rotate", "okx-demo-account", {"version": 2})
        second = outbox.submit(200, "credential_rotate", "okx-demo-account", {"version": 2})
        expect(first == second, "lifecycle command replay must be idempotent")
        envelope = outbox.read(200)
        expect(hmac.compare_digest(envelope["signature"],
                                   release_lifecycle.sign_command(envelope["payload"], KEY)),
               "lifecycle outbox command must be signed")
        expect("secret" not in json.dumps(envelope).lower(),
               "lifecycle outbox must not contain secret material")
        print("release_lifecycle_acceptance=passed")
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
