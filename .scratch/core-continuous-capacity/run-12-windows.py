"""Bind current Windows artifacts and affected regressions to ticket 11's exact source.

This is a functional revalidation, not a repeated full Windows suite or production qualification.
"""
from pathlib import Path
import datetime
import importlib.util
import json
import os
import platform
import shutil
import struct
import subprocess
import sys
import zipfile

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
ZIG = Path('D:/Program Files/zig/zig.exe')
spec = importlib.util.spec_from_file_location('capture', OUT / 'run-10-command.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


def pe_stack(path):
    with path.open('rb') as stream:
        assert stream.read(2) == b'MZ'
        stream.seek(0x3c)
        offset = struct.unpack('<I', stream.read(4))[0]
        stream.seek(offset)
        assert stream.read(4) == b'PE\0\0'
        stream.seek(offset + 24)
        magic = struct.unpack('<H', stream.read(2))[0]
        stream.seek(offset + 24 + 72)
        return struct.unpack('<Q' if magic == 0x20b else '<I', stream.read(8 if magic == 0x20b else 4))[0]


def main():
    prefix = sys.argv[1]
    assert os.name == 'nt' and prefix and all(c.isalnum() or c in '-_' for c in prefix)
    assert not list(OUT.glob(prefix + '-*')), 'New prefix required; previous evidence retained'
    frozen = capture.source_manifest()
    linux_path = OUT / '11-final-v6-identity.json'
    linux = json.loads(linux_path.read_text())
    assert frozen['files'] == linux['files'] and frozen['source_tree_sha256'] == linux['source_tree_sha256']
    assert capture.sha(ZIG) == linux['zig_sha256']
    names = ('run-07-command.py', 'run-10-command.py', 'run-10-file-processes.py',
             'run-12-windows.py', 'audit-12-final.py', 'seal-12-wave.py')
    producers = {name: capture.sha(OUT / name) for name in names}
    previous = json.loads((OUT / '10-final-v3-source-manifest.json').read_text())
    old = {row['path']: row['sha256'] for row in previous['files']}
    new = {row['path']: row['sha256'] for row in frozen['files']}
    identity = {**frozen, 'recorded_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'baseline_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'producer_dependencies': producers, 'zig_sha256': capture.sha(ZIG),
                'zig_version': '0.17.0-dev.315+5b647b792', 'target': 'native Windows x86_64',
                'os': platform.platform(), 'linux_identity_sha256': capture.sha(linux_path),
                'linux_package_manifest_sha256': capture.sha(OUT / '11-final-v6-linux-evidence/manifest.json'),
                'previous_windows_source_tree_sha256': previous['source_tree_sha256'],
                'previous_windows_package_identity_sha256': capture.sha(OUT / '10-final-v3-windows-evidence/identity.json'),
                'changed_since_windows_ticket10': [name for name in sorted(old.keys() | new.keys()) if old.get(name) != new.get(name)],
                'seed': '0x20261008', 'schema': linux['schema'],
                'scope': 'same-source Windows functional revalidation and evidence handoff',
                'validation': 'affected regressions only; historical full Windows results remain ticket10 source',
                'production_qualification': False, 'capacity_stress_resource_performance': 'deferred',
                'directory_durability_qualified': False, 'actual_stack_peak': 'not_measured'}
    (OUT / (prefix + '-identity.json')).write_text(json.dumps(identity, indent=2) + '\n')
    with zipfile.ZipFile(OUT / (prefix + '-source.zip'), 'x', zipfile.ZIP_DEFLATED) as archive:
        for row in frozen['files']:
            archive.write(ROOT / row['path'], row['path'])
        for name in names:
            archive.write(OUT / name, '.scratch/core-continuous-capacity/' + name)
    artifacts = {}

    def guard():
        assert capture.source_manifest() == frozen
        assert all(capture.sha(OUT / name) == digest for name, digest in producers.items())
        assert capture.sha(linux_path) == identity['linux_identity_sha256']

    def save_artifacts():
        (OUT / (prefix + '-artifacts.json')).write_text(json.dumps(list(artifacts.values()), indent=2) + '\n')

    def register(path, role):
        artifacts[path.name] = {'name': path.name, 'role': role, 'sha256': capture.sha(path),
                                'bytes': path.stat().st_size, 'pe_stack_reserve_bytes': pe_stack(path)}
        save_artifacts()

    def run(label, command, artifact=None):
        guard()
        digest = capture.sha(artifact) if artifact else None
        if artifact and artifact.name in artifacts:
            assert digest == artifacts[artifact.name]['sha256']
        state = {'stage': label, 'state': 'running', 'source_tree_sha256': frozen['source_tree_sha256']}
        state_path = OUT / (prefix + '-run-state.json')
        state_path.write_text(json.dumps(state, indent=2) + '\n')
        previous_watch = os.environ.get('RINGWIN_CAPTURE_ABORT_ON_CRASH')
        try:
            os.environ['RINGWIN_CAPTURE_ABORT_ON_CRASH'] = '1'
            code = capture.capture(prefix + '-' + label, list(map(str, command)))
        finally:
            if previous_watch is None:
                os.environ.pop('RINGWIN_CAPTURE_ABORT_ON_CRASH', None)
            else:
                os.environ['RINGWIN_CAPTURE_ABORT_ON_CRASH'] = previous_watch
        state.update(state='stage_passed' if code == 0 else 'failed', exit_code=code)
        state_path.write_text(json.dumps(state, indent=2) + '\n')
        assert code == 0, label + ': failed evidence retained'
        if artifact:
            assert capture.sha(artifact) == digest
            result_path = OUT / (prefix + '-' + label + '.result.json')
            record = json.loads(result_path.read_text())
            record['consumed_artifact_sha256'] = digest
            result_path.write_text(json.dumps(record, indent=2) + '\n')
        guard()

    run('app-build', [ZIG, 'build', '--cache-dir', '.zig-cache/frontier12-build', '-Doptimize=ReleaseSafe'])
    app = OUT / (prefix + '-app.exe')
    shutil.copyfile(ROOT / 'zig-out/bin/ringwin.exe', app)
    register(app, 'application')
    cli = OUT / (prefix + '-cli.exe')
    run('cli-build', [ZIG, 'build-exe', 'src/main.zig', '-O', 'ReleaseSafe', '--stack', '268435456', '-femit-bin=' + str(cli)])
    register(cli, 'CLI')
    assert artifacts[app.name]['pe_stack_reserve_bytes'] == 67108864
    assert artifacts[cli.name]['pe_stack_reserve_bytes'] == 268435456
    for label, artifact in (('app', app), ('cli', cli)):
        for flag in ('offline-fixture', 'windows-chain-test'):
            run(label + '-' + flag, [artifact, '--' + flag], artifact)
        run(label + '-processes', [sys.executable, OUT / 'run-10-file-processes.py',
            '--artifact', artifact, '--expected-sha256', artifacts[artifact.name]['sha256'],
            '--prefix', prefix + '-' + label + '-processes'], artifact)
    tests = (('native-file', 'src/main.zig', 'Native file'),
             ('venue-family', 'src/venue_fill_recovery_acceptance.zig', None),
             ('owner-memory', 'src/okx_demo_live_acceptance.zig', 'OKX raw private report and Fill reach'),
             ('owner-file', 'src/okx_demo_live_acceptance.zig', 'Windows file store reopens OKX'))
    for label, source, test_filter in tests:
        path = OUT / (prefix + '-' + label + '.exe')
        command = [ZIG, 'test', source, '-O', 'Debug', '--stack', '268435456', '--test-no-exec', '-femit-bin=' + str(path)]
        if test_filter:
            command += ['--test-filter', test_filter]
        run(label + '-build', command)
        register(path, 'affected Debug regression: ' + label)
        run(label, [path], path)
    guard()
    assert all(capture.sha(OUT / name) == row['sha256'] for name, row in artifacts.items())
    print('Same-source Windows revalidation completed; audit and handoff still required', flush=True)


if __name__ == '__main__':
    main()
