"""Capture one offline validation command without overwriting earlier evidence."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
FATAL = re.compile(rb'(?:^|\n)(?:thread \d+ panic:|Segmentation fault at address|General protection exception)')


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def source_manifest():
    paths = [ROOT / 'build.zig', ROOT / 'build.zig.zon']
    for directory in ('src', 'tools'):
        paths.extend(path for path in (ROOT / directory).rglob('*')
                     if path.is_file() and path.suffix in ('.zig', '.c', '.h', '.ps1', '.sh', '.py'))
    rows = [{'path': path.relative_to(ROOT).as_posix(), 'sha256': sha(path)}
            for path in sorted(set(paths)) if path.is_file()]
    digest = hashlib.sha256(''.join(row['path'] + '\0' + row['sha256'] + '\n' for row in rows).encode()).hexdigest()
    return {'files': rows, 'source_tree_sha256': digest}


def capture(label, command, timeout=10800, expected=None):
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', label):
        raise ValueError('A new simple label is required')
    if timeout <= 0 or not command:
        raise ValueError('A command and positive timeout are required')
    before = source_manifest()
    if expected is not None and before != expected:
        raise RuntimeError('Frozen source mismatch before launch')
    directory = OUT / 'runs' / label
    directory.mkdir(parents=True, exist_ok=False)
    (directory / 'source.json').write_bytes((json.dumps(before, indent=2) + '\n').encode())
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    begin = time.perf_counter_ns()
    process = None
    timed_out = False
    fatal = None
    error = None
    child_code = None
    stdout, stderr = directory / 'stdout.log', directory / 'stderr.log'
    try:
        with stdout.open('xb') as output, stderr.open('xb') as errors:
            process = subprocess.Popen(list(map(str, command)), cwd=ROOT, stdout=output, stderr=errors)
            offset = 0
            tail = b''
            while process.poll() is None:
                with stderr.open('rb') as reader:
                    reader.seek(offset)
                    data = reader.read()
                    offset += len(data)
                match = FATAL.search(tail + data)
                tail = (tail + data)[-512:]
                if match:
                    fatal = match.group(0).decode(errors='replace').strip()
                    process.terminate()
                    break
                if time.perf_counter_ns() - begin > timeout * 1_000_000_000:
                    timed_out = True
                    process.terminate()
                    break
                time.sleep(0.1)
            try:
                child_code = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                child_code = process.wait(timeout=10)
        if fatal is None:
            match = FATAL.search(stderr.read_bytes())
            if match:
                fatal = match.group(0).decode(errors='replace').strip()
    except Exception as caught:
        error = type(caught).__name__ + ': ' + str(caught)
        if process is not None and process.poll() is None:
            process.kill()
            child_code = process.wait(timeout=10)
    after = source_manifest()
    changed = before != after
    code = 127 if error else 126 if changed else 125 if fatal else 124 if timed_out else child_code
    record = {'label': label, 'command': list(map(str, command)), 'cwd': str(ROOT),
              'started_utc': started, 'finished_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'elapsed_ns': time.perf_counter_ns() - begin, 'pid': process.pid if process else None,
              'exit_code': code, 'child_exit_code': child_code, 'timed_out': timed_out,
              'fatal_diagnostic': fatal, 'capture_error': error, 'source_changed': changed,
              'source_tree_sha256': before['source_tree_sha256'],
              'capture_sha256': sha(Path(__file__)), 'stdout_sha256': sha(stdout),
              'stderr_sha256': sha(stderr), 'network_or_production_qualification': False}
    (directory / 'result.json').write_bytes((json.dumps(record, indent=2) + '\n').encode())
    print(label, 'exit=' + str(code), 'source=' + before['source_tree_sha256'], flush=True)
    return code


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--timeout', type=float, default=10800)
    parser.add_argument('label')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    raise SystemExit(capture(args.label, command, args.timeout))
