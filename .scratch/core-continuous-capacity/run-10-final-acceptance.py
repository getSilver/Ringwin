"""Serial, frozen-source functional acceptance; never promotes qualification."""
from pathlib import Path
import datetime
import hashlib
import importlib.util
import json
import os
import platform
import struct
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
out = root / '.scratch/core-continuous-capacity'
prefix = sys.argv[1] if len(sys.argv) > 1 else '10-final-v1'
assert len(sys.argv) <= 2, 'Use one new evidence prefix'
zig = r'D:\Program Files\zig\zig.exe'
spec = importlib.util.spec_from_file_location('capture', out / 'run-10-command.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
manifest = json.loads((out / (prefix + '-source-manifest.json')).read_text())
identity = {
    'source_tree_sha256': manifest['source_tree_sha256'],
    'commit_before_implementation_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'branch': subprocess.check_output(['git', 'branch', '--show-current'], cwd=root, text=True).strip(),
    'tracked_source_diff_sha256': hashlib.sha256(subprocess.check_output(['git', 'diff', 'HEAD', '--', 'src', 'build.zig'], cwd=root)).hexdigest(),
    'os': platform.platform(), 'architecture': platform.machine(), 'logical_cpus': os.cpu_count(),
    'zig': '0.17.0-dev.315+5b647b792', 'seed_label': '0x20261008',
    'scope': 'offline small functional fixtures; not a platform performance or production qualification',
    'max_fixture_live_across_shards': 100, 'max_fixture_terminal_across_shards': 100,
    'production_qualification': False, 'capacity_stress_qualification': 'deferred',
    'actual_thread_stack_peak': 'not_measured', 'physical_index_bytes_per_identity': 'not_measured',
    'scripts': {name: capture.sha(out / name) for name in ('run-07-command.py', 'run-10-command.py', 'run-10-final-acceptance.py', 'run-10-file-processes.py', 'audit-10-final.py', 'collect-10-host.ps1')},
    'zig_executable_sha256': capture.sha(Path(zig)),
    'schema_identity': {'journal': 39, 'state': 43, 'registry': 37, 'release_artifact': 1},
    'host_metadata_sha256': capture.sha(out / '10-windows-host.json'),
    'python_version': sys.version,
    'directory_durability_qualified': False,
    'native_file_probe': {
        'source_sha256': capture.sha(out / '10-file-semantics-nativeprobe/probe.zig'),
        'stdout_sha256': capture.sha(out / '10-file-semantics-nativeprobe/output.log'),
        'observations': [json.loads(line) for line in (out / '10-file-semantics-nativeprobe/output.log').read_text().splitlines()],
    },
}
identity_path = out / (prefix + '-identity.json')
if identity_path.exists():
    raise FileExistsError('Existing acceptance prefix retained; choose a new prefix')
else:
    identity_path.write_text(json.dumps(identity, indent=2) + '\n', encoding='utf-8')
built_artifacts = {}

def frozen():
    assert capture.source_manifest() == manifest, 'Frozen source changed'
    assert all(capture.sha(out / name) == digest for name, digest in identity['scripts'].items()), 'Frozen producer changed'
    assert capture.sha(out / '10-windows-host.json') == identity['host_metadata_sha256'], 'Frozen host metadata changed'
    assert capture.sha(out / '10-file-semantics-nativeprobe/probe.zig') == identity['native_file_probe']['source_sha256'], 'Native probe source changed'
    assert capture.sha(out / '10-file-semantics-nativeprobe/output.log') == identity['native_file_probe']['stdout_sha256'], 'Native probe result changed'

def run(label, command, artifact=None):
    frozen()
    is_build = label.endswith('-build')
    expected_artifact = None
    if artifact and not is_build:
        expected_artifact = built_artifacts[str(artifact)]
        assert capture.sha(artifact) == expected_artifact, 'Artifact changed before launch'
    state = {'stage': label, 'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'source_tree_sha256': manifest['source_tree_sha256'], 'state': 'running'}
    state_path = out / (prefix + '-run-state.json')
    state_path.write_text(json.dumps(state, indent=2) + '\n')
    code = subprocess.call([sys.executable, str(out / 'run-10-command.py'), prefix + '-' + label, *map(str, command)], cwd=root)
    result_path = out / (prefix + '-' + label + '.result.json')
    result = json.loads(result_path.read_text())
    if artifact and artifact.is_file():
        result['artifact_sha256'] = capture.sha(artifact)
        result['artifact_sha256_before_launch'] = expected_artifact
        result_path.write_text(json.dumps(result, indent=2) + '\n')
    state.update(state='completed-stage' if code == 0 else 'failed', exit_code=code)
    state_path.write_text(json.dumps(state, indent=2) + '\n')
    assert code == 0, label + ' failed; original results retained'
    assert result['source_mismatches_after'] == 0
    assert not result['timed_out']
    if artifact:
        if is_build:
            built_artifacts[str(artifact)] = result['artifact_sha256']
        else:
            assert result['artifact_sha256'] == expected_artifact, 'Artifact changed during execution'
    frozen()

assert subprocess.check_output([zig, 'version'], text=True).strip() == '0.17.0-dev.315+5b647b792'
app = root / 'zig-out/bin/ringwin.exe'
run('app-build', [zig, 'build', '--cache-dir', '.zig-cache/frontier10-build', '-Doptimize=ReleaseSafe'], app)
cli = out / (prefix + '-cli.exe')
run('cli-build', [zig, 'build-exe', 'src/main.zig', '-O', 'ReleaseSafe', '--stack', '268435456', '-femit-bin=' + str(cli)], cli)
for label, exe in (('app', app), ('cli', cli)):
    for flag in ('offline-fixture', 'windows-chain-test'):
        run(label + '-' + flag, [exe, '--' + flag], exe)

for label, exe in (('app', app), ('cli', cli)):
    run(label + '-file-processes', [sys.executable, out / 'run-10-file-processes.py',
        '--artifact', exe, '--expected-sha256', capture.sha(exe),
        '--prefix', prefix + '-' + label + '-processes'], exe)
for mode in ('ReleaseSafe', 'Debug'):
    label = 'full-' + mode.lower()
    exe = out / (prefix + '-' + label + '.exe')
    run(label + '-build', [zig, 'test', 'src/main.zig', '-O', mode, '--stack', '268435456',
        '--test-no-exec', '-femit-bin=' + str(exe)], exe)
    run(label, [exe], exe)

def pe_stack(path):
    with path.open('rb') as stream:
        stream.seek(0x3c)
        offset = struct.unpack('<I', stream.read(4))[0]
        stream.seek(offset + 24)
        magic = struct.unpack('<H', stream.read(2))[0]
        stream.seek(offset + 24 + 72)
        return struct.unpack('<Q' if magic == 0x20b else '<I', stream.read(8 if magic == 0x20b else 4))[0]

paths = [out / (prefix + '-full-releasesafe.exe'), out / (prefix + '-full-debug.exe'), app, cli]
for path in paths:
    assert capture.sha(path) == built_artifacts[str(path)], 'Built artifact changed before final sealing'
identity = {'recorded_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'source_tree_sha256': manifest['source_tree_sha256'], 'zig': '0.17.0-dev.315+5b647b792',
            'artifacts': [{'path': p.relative_to(root).as_posix(), 'bytes': p.stat().st_size,
                           'sha256': capture.sha(p), 'pe_stack_reserve_bytes': pe_stack(p)} for p in paths],
            'scope': 'functional artifacts only; no capacity pressure or production qualification'}
(out / (prefix + '-artifacts.json')).write_text(json.dumps(identity, indent=2) + '\n')
print('10 acceptance commands completed; audit and reviews required before closure')
