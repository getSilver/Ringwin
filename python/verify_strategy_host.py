"""Run the complete Python StrategyHost product acceptance on this machine."""

from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".scratch" / "build"
IS_WINDOWS = sys.platform == "win32"


def main():
    zig = shutil.which("zig")
    if not zig:
        raise SystemExit("zig is required")
    BUILD.mkdir(parents=True, exist_ok=True)
    bridge = BUILD / (
        "strategy_host_ipc-current.dll"
        if IS_WINDOWS
        else "libstrategy_host_ipc-current.so"
    )
    capacity = BUILD / (
        "strategy_host_capacity-current.exe"
        if IS_WINDOWS
        else "strategy_host_capacity-current"
    )
    checks = [
        [zig, "fmt", "--check", *map(str, sorted((ROOT / "src").glob("strategy_host_*.zig")))],
        [zig, "test", "src/strategy_host_ipc.zig", "-O", "ReleaseSafe"],
        [zig, "test", "src/strategy_host_lifecycle.zig", "-O", "ReleaseSafe"],
        [zig, "test", "src/strategy_host_gateway.zig", "-O", "ReleaseSafe"],
        [zig, "test", "src/strategy_host_recovery.zig", "-O", "ReleaseSafe"],
        [zig, "test", "src/strategy_host_failures.zig", "-O", "ReleaseSafe"],
        [zig, "run", "src/strategy_host_ipc.zig", "-O", "ReleaseSafe"],
        [
            zig,
            "build-lib",
            "src/strategy_host_ipc.zig",
            "-dynamic",
            "-O",
            "ReleaseSafe",
            f"-femit-bin={bridge}",
        ],
        [zig, "run", "src/strategy_host_lifecycle.zig", "-O", "ReleaseSafe"],
        [
            zig,
            "run",
            "src/strategy_host_integration.zig",
            "-O",
            "ReleaseSafe",
            "--",
            str(bridge),
        ],
        [
            zig,
            "run",
            "src/strategy_host_recovery_integration.zig",
            "-O",
            "ReleaseSafe",
            "--",
            str(bridge),
        ],
        [
            zig,
            "run",
            "src/strategy_host_failure_integration.zig",
            "-O",
            "ReleaseSafe",
            "--",
            str(bridge),
        ],
        [
            zig,
            "build-exe",
            "src/strategy_host_capacity.zig",
            "-O",
            "ReleaseSafe",
            f"-femit-bin={capacity}",
        ],
        [str(capacity), str(bridge), sys.executable, "python/strategy_host.py"],
    ]
    for index, command in enumerate(checks, 1):
        print(f"[{index}/{len(checks)}] {subprocess.list2cmdline(command)}", flush=True)
        result = subprocess.run(
            command,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        print(result.stdout, end="", flush=True)
        result.check_returncode()
    print("strategy_host_product_acceptance=passed", flush=True)


if __name__ == "__main__":
    main()
