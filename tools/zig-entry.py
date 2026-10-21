"""Run a standalone Zig source under the shared src/ module root.

Usage: python tools/zig-entry.py [--zig PATH] test|run|build-exe|build-obj|build-lib SOURCE [ZIG_ARGS ...]
Arguments after -- are forwarded to the compiled program unchanged.
"""

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    args = sys.argv[1:]
    zig = shutil.which("zig")
    if args[:1] == ["--zig"]:
        zig, args = args[1], args[2:]
    if not zig or len(args) < 2 or args[0] not in ("test", "run", "build-exe", "build-obj", "build-lib"):
        raise SystemExit(__doc__)
    command, source, *flags = args
    source = Path(source).resolve()
    source_path = source.relative_to(ROOT / "src").as_posix()
    if source.suffix != ".zig" or not source.is_file() or source.name == "entry.zig":
        raise SystemExit("SOURCE must be an existing Zig file under src/, excluding entry.zig")
    entries = {
        path: int(index)
        for index, path in re.findall(r'(\d+) => @import\("([^"]+)"\)', (ROOT / "src" / "entry.zig").read_text())
    }
    if source_path not in entries:
        raise SystemExit("SOURCE must have a standalone entry in src/entry.zig")
    runtime_args = []
    if "--" in flags:
        index = flags.index("--")
        flags, runtime_args = flags[:index], flags[index:]
    build = ROOT / ".scratch" / "build" / "entries" / ("source-" + str(entries[source_path]))
    build.mkdir(parents=True, exist_ok=True)
    options = build / "entry_options.zig"
    # Stable input paths preserve Zig's compilation cache. Publish atomically so
    # concurrent invocations never read a partially written selection file.
    if not options.is_file():
        with tempfile.NamedTemporaryFile(dir=build, delete=False) as temporary:
            temporary.write(("pub const index: usize = " + str(entries[source_path]) + ";\n").encode("utf-8"))
            temporary_path = Path(temporary.name)
        try:
            temporary_path.replace(options)
        finally:
            temporary_path.unlink(missing_ok=True)
    result = subprocess.run([
        zig, command, *flags,
        "--dep", "entry_options",
        "-Mroot=" + str(ROOT / "src" / "entry.zig"),
        "-Mentry_options=" + str(options),
        *runtime_args,
    ])
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
