"""Continue the exact v4 source: reuse successful evidence and run Debug at 512 MiB.

Aliases retain original bytes, commands and timestamps. They are not fresh runs.
Original failed Debug artifacts and captures are never overwritten.
"""
from pathlib import Path
import datetime
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import zipfile

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
WSL_OUT = '/mnt/d/github/Ringwin-core-continuous-capacity/.scratch/core-continuous-capacity'
WSL_ROOT = '/home/ubuntu/ringwin-frontier11'
ZIG = Path('D:/Program Files/zig/zig.exe')
spec = importlib.util.spec_from_file_location('capture', OUT / 'run-10-command.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


def main():
    base, prefix = sys.argv[1:]
    assert os.name == 'nt'
    assert all(name and all(c.isalnum() or c in '-_' for c in name) for name in (base, prefix))
    assert not list(OUT.glob(prefix + '-*')), 'New prefix required; previous evidence retained'
    base_identity_path = OUT / (base + '-identity.json')
    original = json.loads(base_identity_path.read_text())
    frozen = capture.source_manifest()
    assert original['files'] == frozen['files'] and original['source_tree_sha256'] == frozen['source_tree_sha256']
    assert capture.sha(ZIG) == original['zig_sha256']
    dependencies = dict(original['producer_dependencies'])
    for name, digest in dependencies.items():
        assert capture.sha(OUT / name) == digest, name
    for name in ('resume-11-debug.py', 'audit-11-continuation.py', '11-test-runner-512.zig', '11-test-runner-512-origin.json'):
        dependencies[name] = capture.sha(OUT / name)
    reused = {}

    def alias(source, destination):
        assert not destination.exists()
        digest = capture.sha(source)
        shutil.copyfile(source, destination)
        assert capture.sha(destination) == digest
        reused[destination.relative_to(OUT).as_posix()] = {
            'origin': source.relative_to(OUT).as_posix(), 'sha256': digest,
            'execution': 'reused original bytes; commands and timestamps unchanged'}

    for label in ('app-build', 'adapter-syscalls', 'cli-build', 'app-processes', 'cli-processes',
                  'full-releasesafe-build', 'full-releasesafe', 'native-full-releasesafe'):
        record = json.loads((OUT / (base + '-' + label + '.result.json')).read_text())
        assert record['exit_code'] == 0 and not record['timed_out'] and record['capture_error'] is None
        assert record['source_tree_sha256'] == frozen['source_tree_sha256']
        assert record['source_mismatches_after'] == record['producer_mismatches_after'] == 0
        for extension, expected in (('.log', record['log_sha256']), ('.stdout.log', record['stdout_sha256']),
                                    ('.memory.jsonl', record['memory']['samples_sha256'])):
            source = OUT / (base + '-' + label + extension)
            assert capture.sha(source) == expected
        for extension in ('.result.json', '.log', '.stdout.log', '.memory.jsonl'):
            alias(OUT / (base + '-' + label + extension), OUT / (prefix + '-' + label + extension))
    artifacts = {}
    for label in ('app', 'cli', 'full-releasesafe'):
        alias(OUT / (base + '-' + label), OUT / (prefix + '-' + label))
        artifacts[prefix + '-' + label] = capture.sha(OUT / (prefix + '-' + label))
    probe_source = OUT / (base + '-adapter-evidence')
    probe_destination = OUT / (prefix + '-adapter-evidence')
    probe_destination.mkdir()
    for source in probe_source.iterdir():
        assert source.is_file()
        alias(source, probe_destination / source.name)
    identity = {**original, 'baseline_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'producer_dependencies': dependencies, 'continuation_of': base,
                'continued_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'base_identity_sha256': capture.sha(base_identity_path),
                'base_producer_dependencies': original['producer_dependencies'],
                'continuation_audit_script': 'audit-11-continuation.py',
                'reused_evidence': reused,
                'execution_scope': 'v4 ReleaseSafe and sixty processes reused; fresh physical audits and complete Debug at 512 MiB',
                'worker_stack_bytes': {'offline_file_app_and_cli': 67108864,
                                       'stock_test_runner': {'releasesafe': 268435456, 'debug': 536870912}},
                'actual_stack_peak': 'not_measured'}
    (OUT / (prefix + '-identity.json')).write_text(json.dumps(identity, indent=2) + '\n')
    alias(OUT / (base + '-source.diff'), OUT / (prefix + '-source.diff'))
    # source.diff is an alias too; publish the updated reuse map before execution.
    (OUT / (prefix + '-identity.json')).write_text(json.dumps(identity, indent=2) + '\n')
    with zipfile.ZipFile(OUT / (prefix + '-source.zip'), 'x', zipfile.ZIP_DEFLATED) as archive:
        for row in frozen['files']:
            archive.write(ROOT / row['path'], row['path'])
        for name in dependencies:
            archive.write(OUT / name, '.scratch/core-continuous-capacity/' + name)

    def check():
        assert capture.source_manifest() == frozen
        assert all(capture.sha(OUT / n) == digest for n, digest in dependencies.items())
        for destination, item in reused.items():
            assert capture.sha(OUT / destination) == capture.sha(OUT / item['origin']) == item['sha256']
        assert capture.sha(base_identity_path) == identity['base_identity_sha256']

    def run(label, command):
        check()
        state = {'stage': label, 'state': 'running', 'source_tree_sha256': frozen['source_tree_sha256'],
                 'continuation_of': base}
        path = OUT / (prefix + '-run-state.json')
        path.write_text(json.dumps(state, indent=2) + '\n')
        code = capture.capture(prefix + '-' + label, list(map(str, command)))
        state.update(state='stage_passed' if code == 0 else 'failed', exit_code=code)
        path.write_text(json.dumps(state, indent=2) + '\n')
        assert code == 0, label + ' failed; all previous evidence retained'
        check()

    for label in ('app', 'cli'):
        run(label + '-audit', ['wsl.exe', '-e', 'python3', WSL_OUT + '/audit-11-processes.py',
            WSL_ROOT + '/' + base + '-' + label + '-processes', WSL_OUT + '/' + prefix + '-' + label + '-evidence'])
    debug = OUT / (prefix + '-full-debug')
    run('full-debug-build', [ZIG, 'test', 'src/main.zig', '-target', 'x86_64-linux', '-O', 'Debug',
        '--test-runner', '.scratch/core-continuous-capacity/11-test-runner-512.zig', '--test-no-exec',
        '-femit-bin=' + str(debug)])
    artifacts[debug.name] = capture.sha(debug)
    run('full-debug', ['wsl.exe', '-e', 'env', 'RINGWIN_CAPTURE_CWD=' + WSL_ROOT,
        'python3', WSL_OUT + '/run-10-command.py', prefix + '-native-full-debug', WSL_OUT + '/' + debug.name])
    assert capture.sha(debug) == artifacts[debug.name]
    check()
    (OUT / (prefix + '-artifacts.json')).write_text(json.dumps([
        {'name': name, 'sha256': digest, 'bytes': (OUT / name).stat().st_size,
         'execution': 'new complete Debug' if name == debug.name else 'reused v4 artifact alias'}
        for name, digest in artifacts.items()], indent=2) + '\n')
    print('Continuation finished; final audit and independent review still required', flush=True)


if __name__ == '__main__':
    main()
