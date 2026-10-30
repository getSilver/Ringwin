"""Emergency KillSwitch console.

Signs a kill_switch ControlCommand with the channel key and drops it into the
emergency directory watched by the Zig host. This path deliberately bypasses
the control-plane process: if the control plane is dead, the node operator can
still forbid all new risk.

The key file must contain exactly 32 raw bytes (or 64 hex characters) and is
expected to be unlocked by the SystemOwner out of CredentialStore in
production; the raw-file form here is the development fixture.
"""

import argparse
import os
import sys

from control_plane import KEY_LEN, sign_command


def load_key(path: str) -> bytes:
    with open(path, "rb") as handle:
        material = handle.read().strip()
    if len(material) == KEY_LEN:
        return material
    if len(material) == KEY_LEN * 2:
        return bytes.fromhex(material.decode("ascii"))
    raise SystemExit(f"key file must contain {KEY_LEN} raw or hex bytes: {path}")


def drop_kill_switch(target: int, latch_identity: int, expected_version: int,
                     expires_in: int, now: int, drop_dir: str, key: bytes,
                     command_identity: int) -> str:
    command = {
        "command_identity": command_identity,
        "target_identity": target,
        "expected_version": expected_version,
        "expires_at": now + expires_in,
        "kind": "kill_switch",
        "referenced_latch_identity": latch_identity,
    }
    envelope = sign_command(command, key)
    temp_path = os.path.join(drop_dir, f"cmd-{command_identity}.tmp")
    final_path = os.path.join(drop_dir, f"cmd-{command_identity}.cmd")
    with open(temp_path, "wb") as handle:
        handle.write(envelope)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_path, final_path)
    return final_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Emergency KillSwitch console")
    parser.add_argument("--target", type=lambda v: int(v, 0), required=True)
    parser.add_argument("--latch-identity", type=lambda v: int(v, 0), required=True)
    parser.add_argument("--expected-version", type=int, default=3)
    parser.add_argument("--expires-in", type=int, default=300)
    parser.add_argument("--now", type=int, default=1_000_000)
    parser.add_argument("--command-identity", type=lambda v: int(v, 0), default=None)
    parser.add_argument("--drop-dir", required=True)
    parser.add_argument("--key-file", required=True)
    args = parser.parse_args()

    identity = args.command_identity
    if identity is None:
        identity = f"emergency-{args.target}".encode().hex()
        identity = int(identity[:16], 16)

    path = drop_kill_switch(args.target, args.latch_identity, args.expected_version,
                            args.expires_in, args.now, args.drop_dir,
                            load_key(args.key_file), identity)
    print(f"kill_switch dropped: {path}")


if __name__ == "__main__":
    main()
