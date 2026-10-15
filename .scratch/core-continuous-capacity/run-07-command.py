"""Capture one authorized local command with native file handles and source hashes."""
from pathlib import Path
import datetime
import hashlib
import json
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
out = root / '.scratch/core-continuous-capacity'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def source_manifest():
    paths = sorted(p for p in [*root.glob('src/**/*.zig'), root / 'build.zig', root / 'build.zig.zon'] if p.is_file())
    files = [{'path': str(p.relative_to(root)).replace('\\', '/'), 'sha256': sha(p)} for p in paths]
    digest = hashlib.sha256(''.join(row['path'] + '\0' + row['sha256'] + '\n' for row in files).encode()).hexdigest()
    return {'files': files, 'source_tree_sha256': digest}

if __name__ == '__main__':
    name, *command = sys.argv[1:]
    before = source_manifest()
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    log = out / (name + '.log')
    stdout = out / (name + '.stdout.log')
    with log.open('wb') as err, stdout.open('wb') as output:
        result = subprocess.run(command, cwd=root, stdout=output, stderr=err)
    after = source_manifest()
    record = {
        **before, 'command': command, 'started_utc': started,
        'finished_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'exit_code': result.returncode, 'log_sha256': sha(log), 'stdout_sha256': sha(stdout),
        'source_mismatches_after': sum(row not in after['files'] for row in before['files']),
        'capture': 'native direct file handles',
    }
    (out / (name + '.result.json')).write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    print(name, 'exit=' + str(result.returncode), 'source=' + before['source_tree_sha256'])
    if result.returncode:
        print(log.read_text(encoding='utf-8', errors='replace')[-16000:])
    sys.exit(result.returncode)
