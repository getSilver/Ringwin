"""End-to-end acceptance for the control-plane command channel.

Builds the Zig probe host, serves signed commands over the localhost TCP pull
channel (including duplicate, expired, unknown-target and bad-MAC cases), then
exercises the emergency directory drop path. Fails closed on any mismatch.
"""

import os
import shutil
import subprocess
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from control_plane import CommandServer, frame, sign_command  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(ROOT, ".scratch", "build", "control_plane_probe.exe")
KEY = bytes(range(32))
NOW = 1_000_000 + 5


def build_probe() -> None:
    subprocess.run(
        ["zig", "build-exe",
         os.path.join(ROOT, "src", "control_plane_probe.zig"),
         "-O", "ReleaseSafe", f"-femit-bin={PROBE}"],
        check=True, cwd=ROOT)


def run_probe(mode: str, location: str) -> str:
    result = subprocess.run([PROBE, mode, location, KEY.hex()],
                            capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise SystemExit(f"probe failed ({result.returncode}): {result.stderr}")
    return result.stdout.strip()


def expect(actual: str, line: str) -> None:
    if actual != line:
        raise SystemExit(f"expected:\n  {line}\ngot:\n  {actual}")


def tcp_phase() -> dict:
    server = CommandServer(KEY)
    server.enqueue({  # accepted: cancel open orders on shard 100
        "command_identity": 20,
        "target_identity": 100,
        "expected_version": 3,
        "expires_at": NOW + 600,
        "kind": "cancel_open_orders",
    })
    server.enqueue({  # accepted: kill switch on shard 200
        "command_identity": 21,
        "target_identity": 200,
        "expected_version": 3,
        "expires_at": NOW + 600,
        "kind": "kill_switch",
        "referenced_latch_identity": 77,
    })
    server.enqueue({  # duplicate of the first command
        "command_identity": 20,
        "target_identity": 100,
        "expected_version": 3,
        "expires_at": NOW + 600,
        "kind": "cancel_open_orders",
    })
    server.enqueue({  # expired
        "command_identity": 22,
        "target_identity": 100,
        "expected_version": 4,
        "expires_at": NOW - 1,
        "kind": "cancel_open_orders",
    })
    server.enqueue({  # wrong target: cross-shard delivery rejection
        "command_identity": 23,
        "target_identity": 999,
        "expected_version": 0,
        "expires_at": NOW + 600,
        "kind": "cancel_open_orders",
    })

    thread = threading.Thread(target=server.serve_one_connection)
    thread.start()
    output = run_probe("tcp", str(server.port))
    thread.join()
    expect(output,
           "control_plane_probe accepted=2 duplicate=1 expired=1 rejected=1 "
           "authority_100=true authority_200=false")
    return {"port": server.port}


def bad_mac_phase() -> None:
    """A corrupted envelope must be rejected without touching any shard."""
    server = CommandServer(KEY)
    good = sign_command({
        "command_identity": 30,
        "target_identity": 100,
        "expected_version": 3,
        "expires_at": NOW + 600,
        "kind": "cancel_open_orders",
    }, KEY)
    evil = bytearray(good)
    evil[-1] ^= 0xFF  # flip one command byte: MAC no longer matches

    def poisoned_serve() -> None:
        conn, _ = server._socket.accept()  # noqa: SLF001
        try:
            if server._recv_exact(conn, 1) != b"P":  # noqa: SLF001
                raise ValueError("unexpected channel request")
            conn.sendall(frame(bytes(evil)))
            conn.sendall(frame(good))
            conn.sendall(b"\x00\x00\x00\x00")
        finally:
            conn.close()
            server._socket.close()

    thread = threading.Thread(target=poisoned_serve)
    thread.start()
    output = run_probe("tcp", str(server.port))
    thread.join()
    expect(output,
           "control_plane_probe accepted=1 duplicate=0 expired=0 rejected=1 "
           "authority_100=true authority_200=true")


def emergency_dir_phase(workdir: str) -> None:
    key_file = os.path.join(workdir, "emergency.key")
    with open(key_file, "wb") as handle:
        handle.write(KEY.hex().encode("ascii"))
    drop_dir = os.path.join(workdir, "drop")
    os.makedirs(drop_dir)
    subprocess.run(
        [sys.executable, os.path.join(ROOT, "python", "emergency_kill_switch.py"),
         "--target", "100", "--latch-identity", "55",
         "--drop-dir", drop_dir, "--key-file", key_file],
        check=True, cwd=os.path.join(ROOT, "python"))
    output = run_probe("dir", drop_dir)
    expect(output,
           "control_plane_probe accepted=1 duplicate=0 expired=0 rejected=0 "
           "authority_100=false authority_200=true")


def main() -> None:
    build_probe()
    workdir = os.path.join(ROOT, ".scratch", "control-plane-channel-acceptance")
    shutil.rmtree(workdir, ignore_errors=True)
    os.makedirs(workdir)

    print(tcp_phase.__name__)
    tcp_phase()
    print(bad_mac_phase.__name__)
    bad_mac_phase()
    print(emergency_dir_phase.__name__)
    emergency_dir_phase(workdir)

    print("control_plane_channel_acceptance=passed")


if __name__ == "__main__":
    main()


