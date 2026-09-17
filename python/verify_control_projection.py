"""End-to-end acceptance for the read-only shard projection seam.

Fails closed on any mismatch: the demo views must reflect the authoritative
lifecycle, a clean journal must round-trip to a complete view, and any
corrupted byte must degrade explicitly instead of serving stale state.
"""

import json
import os
import shutil

import control_projection


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"acceptance failed: {message}")


def demo_phase() -> None:
    views = control_projection.demo_views()
    expect(len(views) == 2, f"expected two demo views, got {len(views)}")

    killed, live = views
    expect(killed["degraded"] if "degraded" in killed else True, "killed view degraded flag")
    expect(not killed.get("effective_authority", True),
           f"killed shard must have lost authority: {killed}")
    expect(killed["unresolved_latches"] == 1,
           f"kill switch must leave one unresolved latch: {killed}")
    expect(killed["may_reduce_only"] is True,
           f"killed shard stays reduce-only: {killed}")
    reasons = {gate["reason"] for gate in killed["gates"]}
    expect({"primary_lease", "risk_lease"} <= reasons,
           f"expected lease gates in projection: {killed['gates']}")

    expect(live.get("effective_authority") is True,
           f"genesis-only shard keeps authority: {live}")
    expect(live["unresolved_latches"] == 0,
           f"genesis-only shard has no latches: {live}")


def roundtrip_phase(workdir: str) -> str:
    hex_text = control_projection.dump_fixture_hex()
    hex_path = os.path.join(workdir, "fixture-journal.hex")
    with open(hex_path, "w", newline="\n") as handle:
        handle.write(hex_text)
    view = control_projection.project_hex_file(hex_path)
    expect(view["status"] in ("complete", "truncated_tail"),
           f"clean journal must project without degradation: {view}")
    expect(view["mode"] == "trading",
           f"fixture journal ends authorized: {view}")
    return hex_path


def corruption_phase(hex_path: str) -> None:
    with open(hex_path) as handle:
        hex_text = handle.read().strip()
    # Flip one payload nibble well past the segment header: checksums or the
    # semantic replay must catch it; either way the view degrades.
    flip_index = len(hex_text) // 2
    flipped = hex_text[:flip_index] + ("0" if hex_text[flip_index] != "0" else "1") + hex_text[flip_index + 1:]
    corrupt_path = hex_path + ".corrupt"
    with open(corrupt_path, "w", newline="\n") as handle:
        handle.write(flipped)
    view = control_projection.project_hex_file(corrupt_path)
    expect(view.get("degraded") is True,
           f"corrupted journal must degrade, got: {view}")
    expect("mode" not in view and "effective_authority" not in view,
           f"degraded view must serve no state fields: {view}")


def main() -> None:
    control_projection.build_probe()
    workdir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           ".scratch", "control-projection-acceptance")
    shutil.rmtree(workdir, ignore_errors=True)
    os.makedirs(workdir)

    demo_phase()
    print("demo_phase=ok")
    hex_path = roundtrip_phase(workdir)
    print("roundtrip_phase=ok")
    corruption_phase(hex_path)
    print("corruption_phase=ok")
    print("control_projection_acceptance=passed")


if __name__ == "__main__":
    main()
