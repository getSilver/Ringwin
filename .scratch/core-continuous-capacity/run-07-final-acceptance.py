"""Serial, frozen-source functional acceptance; never promotes qualification."""
from pathlib import Path
import datetime
import hashlib
import importlib.util
import json
import struct
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
out = root / '.scratch/core-continuous-capacity'
prefix = sys.argv[1] if len(sys.argv) > 1 else '07-final-v5'
phase = sys.argv[2] if len(sys.argv) > 2 else 'all'
assert phase in ('all', '--compile-rs', '--resume-rs')
zig = r'D:\Program Files\zig\zig.exe'
spec = importlib.util.spec_from_file_location('capture', out / 'run-07-command.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
manifest = json.loads((out / (prefix + '-source-manifest.json')).read_text())

def frozen():
    assert capture.source_manifest() == manifest, 'Frozen source changed'

def run(label, command, artifact=None):
    frozen()
    state = {'stage': label, 'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'source_tree_sha256': manifest['source_tree_sha256'], 'state': 'running'}
    state_path = out / (prefix + '-run-state.json')
    state_path.write_text(json.dumps(state, indent=2) + '\n')
    code = subprocess.call([sys.executable, str(out / 'run-07-command.py'), prefix + '-' + label, *map(str, command)], cwd=root)
    result_path = out / (prefix + '-' + label + '.result.json')
    result = json.loads(result_path.read_text())
    if artifact and artifact.is_file():
        result['artifact_sha256'] = capture.sha(artifact)
        result_path.write_text(json.dumps(result, indent=2) + '\n')
    state.update(state='completed-stage' if code == 0 else 'failed', exit_code=code)
    state_path.write_text(json.dumps(state, indent=2) + '\n')
    assert code == 0, label + ' failed; original results retained'
    assert result['source_mismatches_after'] == 0
    frozen()

assert subprocess.check_output([zig, 'version'], text=True).strip() == '0.17.0-dev.315+5b647b792'
for mode in ('ReleaseSafe', 'Debug'):
    label = 'full-' + mode.lower()
    exe = out / (prefix + '-' + label + '.exe')
    command = [zig, 'test', 'src/main.zig', '-O', mode, '--stack', '268435456', '--test-no-exec', '-femit-bin=' + str(exe)]
    if mode == 'ReleaseSafe' and phase == '--resume-rs':
        frozen()
        build = json.loads((out / (prefix + '-' + label + '-build.result.json')).read_text())
        assert build['command'] == command and build['exit_code'] == 0
        assert build['source_mismatches_after'] == 0 and build['files'] == manifest['files']
        assert build['source_tree_sha256'] == manifest['source_tree_sha256']
        assert build['artifact_sha256'] == capture.sha(exe)
        assert build['log_sha256'] == capture.sha(out / (prefix + '-' + label + '-build.log'))
        assert build['stdout_sha256'] == capture.sha(out / (prefix + '-' + label + '-build.stdout.log'))
        print('verified existing frozen ReleaseSafe build; tests have not been skipped', flush=True)
    else:
        run(label + '-build', command, exe)
    if phase == '--compile-rs':
        print('compiled ReleaseSafe only; no tests executed', flush=True)
        sys.exit(0)
    run(label, [exe], exe)
app = root / 'zig-out/bin/ringwin.exe'
run('app-build', [zig, 'build', '-Doptimize=ReleaseSafe'], app)
cli = out / (prefix + '-cli.exe')
run('cli-build', [zig, 'build-exe', 'src/main.zig', '-O', 'ReleaseSafe', '--stack', '268435456', '-femit-bin=' + str(cli)], cli)
for label, exe in (('app', app), ('cli', cli)):
    for flag in ('offline-fixture', 'windows-chain-test'):
        run(label + '-' + flag, [exe, '--' + flag], exe)

def pe_stack(path):
    with path.open('rb') as stream:
        stream.seek(0x3c)
        offset = struct.unpack('<I', stream.read(4))[0]
        stream.seek(offset + 24)
        magic = struct.unpack('<H', stream.read(2))[0]
        stream.seek(offset + 24 + 72)
        return struct.unpack('<Q' if magic == 0x20b else '<I', stream.read(8 if magic == 0x20b else 4))[0]

paths = [out / (prefix + '-full-releasesafe.exe'), out / (prefix + '-full-debug.exe'), app, cli]
identity = {'recorded_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'source_tree_sha256': manifest['source_tree_sha256'], 'zig': '0.17.0-dev.315+5b647b792',
            'artifacts': [{'path': p.relative_to(root).as_posix(), 'bytes': p.stat().st_size,
                           'sha256': capture.sha(p), 'pe_stack_reserve_bytes': pe_stack(p)} for p in paths],
            'scope': 'functional artifacts only; no capacity pressure or production qualification'}
(out / (prefix + '-artifacts.json')).write_text(json.dumps(identity, indent=2) + '\n')
print('07 acceptance commands completed; audit and reviews required before closure')
