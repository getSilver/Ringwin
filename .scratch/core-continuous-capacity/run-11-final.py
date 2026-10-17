"""Freeze sources, build Linux ELFs with pinned Zig, and execute them in WSL1.

Run on Windows with a new prefix. File data and test cwd are on WSL lxfs.
Only offline fixtures and owned child processes are used. No cleanup or retries.
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
ZIG = Path('D:/Program Files/zig/zig.exe')
WSL_ROOT = '/home/ubuntu/ringwin-frontier11'
WSL_REPO = '/mnt/d/github/Ringwin-core-continuous-capacity'
WSL_OUT = WSL_REPO + '/.scratch/core-continuous-capacity'
spec = importlib.util.spec_from_file_location('capture', OUT / 'run-10-command.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


def main():
    prefix = sys.argv[1]
    if os.name != 'nt' or not prefix or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in prefix):
        raise ValueError('Windows orchestration and a simple new prefix required')
    identity_path = OUT / (prefix + '-identity.json')
    if identity_path.exists():
        raise FileExistsError('Existing prefix retained')
    assert subprocess.check_output([str(ZIG), 'version'], text=True).strip() == '0.17.0-dev.315+5b647b792'
    frozen = capture.source_manifest()
    dependencies = ('run-07-command.py', 'run-10-command.py', 'run-10-file-processes.py',
                    'run-11-final.py', 'audit-11-final.py', 'audit-11-processes.py',
                    'collect-11-host.py', 'probe-11-adapter.py', 'test-11-content-identity.py',
                    '11-linux-host.json', '11-test-runner.zig', '11-test-runner-origin.json',
                    '11-test-runner-512.zig', '11-test-runner-512-origin.json', 'test-11-crash-capture.py')
    producers = {name: capture.sha(OUT / name) for name in dependencies}
    identity = {**frozen, 'baseline_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'branch': subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip(),
                'source_diff_sha256': hashlib.sha256(subprocess.check_output(['git', 'diff', 'HEAD', '--', 'src', 'build.zig'], cwd=ROOT)).hexdigest(),
                'producer_dependencies': producers, 'zig_sha256': capture.sha(ZIG),
                'zig_version': '0.17.0-dev.315+5b647b792', 'target': 'x86_64-linux',
                'scope': 'actual WSL1/lxfs file functionality; cross build alone is not acceptance',
                'production_qualification': False, 'target_linux_qualification': False,
                'seed': '0x20261008', 'schema': {'journal': 39, 'state': 43, 'registry': 37, 'release_artifact': 1},
                'worker_stack_bytes': {'offline_file_app_and_cli': 67108864,
                                       'stock_test_runner': {'releasesafe': 268435456, 'debug': 536870912}},
                'actual_stack_peak': 'not_measured', 'capacity_stress_resource_performance': 'deferred',
                'recorded_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    identity_path.write_text(json.dumps(identity, indent=2) + '\n')
    (OUT / (prefix + '-source.diff')).write_bytes(subprocess.check_output(['git', 'diff', 'HEAD', '--', 'src', 'build.zig'], cwd=ROOT))
    with zipfile.ZipFile(OUT / (prefix + '-source.zip'), 'x', zipfile.ZIP_DEFLATED) as archive:
        for row in frozen['files']:
            archive.write(ROOT / row['path'], row['path'])
        for name in dependencies:
            archive.write(OUT / name, '.scratch/core-continuous-capacity/' + name)
    artifacts = {}

    def check():
        assert capture.source_manifest() == frozen, 'Source drift; evidence retained'
        assert all(capture.sha(OUT / n) == digest for n, digest in producers.items()), 'Producer drift'

    def run(label, command, cwd=None):
        check()
        state = {'stage': label, 'state': 'running', 'source_tree_sha256': frozen['source_tree_sha256']}
        state_path = OUT / (prefix + '-run-state.json')
        state_path.write_text(json.dumps(state, indent=2) + '\n')
        old_cwd = os.environ.get('RINGWIN_CAPTURE_CWD')
        try:
            if cwd:
                os.environ['RINGWIN_CAPTURE_CWD'] = str(cwd)
            code = capture.capture(prefix + '-' + label, list(map(str, command)))
        finally:
            if old_cwd is None:
                os.environ.pop('RINGWIN_CAPTURE_CWD', None)
            else:
                os.environ['RINGWIN_CAPTURE_CWD'] = old_cwd
        state.update(state='stage_passed' if code == 0 else 'failed', exit_code=code)
        state_path.write_text(json.dumps(state, indent=2) + '\n')
        assert code == 0, label + ' failed; raw output retained'
        check()

    def wsl_capture(label, executable):
        native = WSL_OUT + '/' + executable.name
        assert capture.sha(executable) == artifacts[executable.name], 'ELF drift'
        run(label, ['wsl.exe', '-e', 'env', 'RINGWIN_CAPTURE_CWD=' + WSL_ROOT,
                    'RINGWIN_CAPTURE_ABORT_ON_CRASH=1',
                    'python3', WSL_OUT + '/run-10-command.py', prefix + '-native-' + label, native])
        assert capture.sha(executable) == artifacts[executable.name], 'ELF drift'

    run('app-build', [ZIG, 'build', '-Dtarget=x86_64-linux', '-Doptimize=ReleaseSafe', '--cache-dir', '.zig-cache/frontier11-build'])
    app = OUT / (prefix + '-app')
    shutil.copyfile(ROOT / 'zig-out/bin/ringwin', app)
    artifacts[app.name] = capture.sha(app)
    run('adapter-syscalls', ['wsl.exe', '-e', 'python3', WSL_OUT + '/probe-11-adapter.py',
        WSL_OUT + '/' + app.name, WSL_ROOT + '/' + prefix + '-adapter-probe',
        WSL_OUT + '/' + prefix + '-adapter-evidence'])
    cli = OUT / (prefix + '-cli')
    run('cli-build', [ZIG, 'build-exe', 'src/main.zig', '-target', 'x86_64-linux', '-O', 'ReleaseSafe',
                      '--stack', '268435456', '-femit-bin=' + str(cli)])
    artifacts[cli.name] = capture.sha(cli)
    for label, artifact in (('app', app), ('cli', cli)):
        run(label + '-processes', ['wsl.exe', '-e', 'python3', WSL_OUT + '/run-10-file-processes.py',
            '--artifact', WSL_OUT + '/' + artifact.name, '--expected-sha256', artifacts[artifact.name],
            '--prefix', prefix + '-' + label + '-processes', '--data-root', WSL_ROOT])
        run(label + '-audit', ['wsl.exe', '-e', 'python3', WSL_OUT + '/audit-11-processes.py',
            WSL_ROOT + '/' + prefix + '-' + label + '-processes', WSL_OUT + '/' + prefix + '-' + label + '-evidence'])
        assert capture.sha(artifact) == artifacts[artifact.name], 'ELF drift'
    # Long suites begin only after the frozen application chains pass.
    for mode in ('ReleaseSafe', 'Debug'):
        label = 'full-' + mode.lower()
        artifact = OUT / (prefix + '-' + label)
        runner = '11-test-runner-512.zig' if mode == 'Debug' else '11-test-runner.zig'
        run(label + '-build', [ZIG, 'test', 'src/main.zig', '-target', 'x86_64-linux', '-O', mode,
            '--test-runner', '.scratch/core-continuous-capacity/' + runner, '--test-no-exec',
            '-femit-bin=' + str(artifact)])
        artifacts[artifact.name] = capture.sha(artifact)
        wsl_capture(label, artifact)
    check()
    (OUT / (prefix + '-artifacts.json')).write_text(json.dumps([
        {'name': name, 'sha256': digest, 'bytes': (OUT / name).stat().st_size}
        for name, digest in artifacts.items()], indent=2) + '\n')
    print('Frozen Linux runtime acceptance completed; audit and review still required', flush=True)


if __name__ == '__main__':
    main()
