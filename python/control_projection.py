"""Read-only shard projection client for the control plane.

Runs the Zig projection probe (the same semantic replay path used by core
recovery) and parses its JSON views. The control plane never decodes journals
itself: there is exactly one journal parser, and it lives in Zig.
"""

import json
import os
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(ROOT, ".scratch", "build", "control_projection_probe.exe")


def build_probe() -> None:
    subprocess.run(
        ["zig", "build-exe",
         os.path.join(ROOT, "src", "control_projection_probe.zig"),
         "-O", "ReleaseSafe",
         f"-femit-bin={PROBE}"],
        check=True, cwd=ROOT)


def _run(args: list[str]) -> str:
    result = subprocess.run([PROBE, *args], capture_output=True, text=True,
                            timeout=60)
    if result.returncode != 0:
        raise RuntimeError(f"projection probe failed: {result.stderr}")
    return result.stdout


def demo_views() -> list[dict]:
    return json.loads(_run(["demo"]))


def dump_fixture_hex() -> str:
    return _run(["dump"]).strip()


def project_hex_file(path: str) -> dict:
    return json.loads(_run(["project", path]))
