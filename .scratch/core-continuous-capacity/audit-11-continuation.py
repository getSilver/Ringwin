"""Verify exact provenance of reused v4 bytes before auditing combined acceptance."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

OUT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    prefix = sys.argv[1]
    identity = json.loads((OUT / (prefix + '-identity.json')).read_text())
    base = identity['continuation_of']
    original_path = OUT / (base + '-identity.json')
    assert sha(original_path) == identity['base_identity_sha256']
    original = json.loads(original_path.read_text())
    assert identity['files'] == original['files']
    assert identity['source_tree_sha256'] == original['source_tree_sha256']
    assert identity['zig_sha256'] == original['zig_sha256']
    assert identity['base_producer_dependencies'] == original['producer_dependencies']
    for name, digest in original['producer_dependencies'].items():
        assert identity['producer_dependencies'][name] == sha(OUT / name) == digest
    for name in ('audit-11-final.py', 'audit-11-continuation.py'):
        assert sha(OUT / name) == identity['producer_dependencies'][name]
    checks = ['base-source-compiler-producers']
    reused = identity['reused_evidence']
    assert len(reused) == 40, 'Eight captures, three artifacts, four probe files, source diff'
    for destination, item in reused.items():
        assert destination.startswith(prefix + '-') and item['origin'].startswith(base + '-')
        assert '..' not in Path(destination).parts and '..' not in Path(item['origin']).parts
        assert sha(OUT / destination) == sha(OUT / item['origin']) == item['sha256']
        checks.append('reuse:' + destination)
    for label in ('app-build', 'adapter-syscalls', 'cli-build', 'app-processes', 'cli-processes',
                  'full-releasesafe-build', 'full-releasesafe', 'native-full-releasesafe'):
        path = OUT / (base + '-' + label + '.result.json')
        record = json.loads(path.read_text())
        assert record['source_tree_sha256'] == identity['source_tree_sha256']
        assert record['exit_code'] == 0 and not record['timed_out'] and record['capture_error'] is None
        assert record['source_mismatches_after'] == record['producer_mismatches_after'] == 0
        assert reused[prefix + '-' + label + '.result.json']['origin'] == path.name
    failed_path = OUT / (base + '-native-full-debug.result.json')
    failed = json.loads(failed_path.read_text())
    assert failed['exit_code'] != 0 and failed['source_tree_sha256'] == identity['source_tree_sha256']
    assert sha(OUT / (base + '-native-full-debug.log')) == failed['log_sha256']
    assert 'Segmentation fault' in (OUT / (base + '-native-full-debug.log')).read_text()
    checks.append('original-Debug-failure-retained')
    assert identity['worker_stack_bytes']['stock_test_runner'] == {'releasesafe': 268435456, 'debug': 536870912}
    runner = OUT / '11-test-runner-512.zig'
    expected = (OUT / '11-test-runner.zig').read_bytes().replace(b'256 MiB', b'512 MiB').replace(
        b'256 * 1024 * 1024', b'512 * 1024 * 1024')
    assert runner.read_bytes() == expected
    assert sha(runner) == identity['producer_dependencies'][runner.name]
    build = json.loads((OUT / (prefix + '-full-debug-build.result.json')).read_text())
    assert '.scratch/core-continuous-capacity/11-test-runner-512.zig' in build['command']
    checks.append('new-Debug-only-runner-stack-delta')
    # This unchanged, frozen audit verifies all thirteen captures, four ELFs,
    # exact allowed skip, fault cases and the freshly exported physical audits.
    subprocess.run([sys.executable, str(OUT / 'audit-11-final.py'), prefix], check=True)
    report = {'state': 'passed', 'continuation_of': base, 'checks': checks,
              'check_count': len(checks), 'source_tree_sha256': identity['source_tree_sha256'],
              'original_failed_debug_capture_sha256': sha(failed_path),
              'reused_execution': 'v4 ReleaseSafe and sixty application/CLI processes',
              'new_execution': 'two physical audits and complete Debug with 512 MiB test runner',
              'production_qualification': False}
    (OUT / (prefix + '-continuation-audit.json')).write_text(json.dumps(report, indent=2) + '\n')
    print('Continuation provenance passed:', len(checks), 'checks', flush=True)


if __name__ == '__main__':
    main()
