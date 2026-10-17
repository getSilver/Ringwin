"""Assemble a Linux-only handoff after runtime acceptance and independent audits.

No builds, tests, trading or physical dataset mutations. Refuse existing output.
"""
from pathlib import Path
from collections import Counter
import datetime
import hashlib
import json
import subprocess
import sys
import zipfile

OUT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def main():
    prefix = sys.argv[1]
    if not prefix or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in prefix):
        raise ValueError('Simple acceptance prefix required')
    destination = OUT / (prefix + '-linux-evidence')
    if destination.exists():
        raise FileExistsError('Existing handoff retained')
    audit_path = OUT / (prefix + '-audit.json')
    identity = read(OUT / (prefix + '-identity.json'))
    audit_script = OUT / 'audit-11-final.py'
    assert sha(audit_script) == identity['producer_dependencies']['audit-11-final.py']
    # Revalidate original linked hashes rather than bless changed bytes after audit.
    # This checks evidence only; it does not repeat runtime or full tests.
    if identity.get('continuation_of'):
        audit_script = OUT / identity['continuation_audit_script']
        assert sha(audit_script) == identity['producer_dependencies'][audit_script.name]
    subprocess.run([sys.executable, str(audit_script), prefix], check=True)
    audit = read(audit_path)
    assert audit['state'] == 'passed'
    assert audit['source_tree_sha256'] == identity['source_tree_sha256']
    compiler = Path(read(OUT / (prefix + '-app-build.result.json'))['command'][0])
    assert sha(compiler) == identity['zig_sha256'], 'Compiler identity changed'
    artifacts = read(OUT / (prefix + '-artifacts.json'))
    for artifact in artifacts:
        assert sha(OUT / artifact['name']) == artifact['sha256']
    archive_path = OUT / (prefix + '-source.zip')
    with zipfile.ZipFile(archive_path) as archive:
        expected = {item['path']: item['sha256'] for item in identity['files']}
        expected.update({'.scratch/core-continuous-capacity/' + name: digest
                         for name, digest in identity['producer_dependencies'].items()})
        assert set(archive.namelist()) == set(expected), 'Frozen archive members differ'
        for name, digest in expected.items():
            assert hashlib.sha256(archive.read(name)).hexdigest() == digest, name
    assert sha(OUT / (prefix + '-source.diff')) == identity['source_diff_sha256']
    references = {}
    workloads = []
    samples = []
    faults = [json.loads(line) for line in (OUT / (prefix + '-faults.jsonl')).read_text().splitlines()]
    resources = []
    for label in ('app', 'cli'):
        directory = OUT / (prefix + '-' + label + '-evidence')
        physical = read(directory / 'audit.json')
        assert physical['state'] == 'passed' and physical['source_tree_sha256'] == identity['source_tree_sha256']
        workloads.append({'artifact': label, **read(directory / 'workload.json')})
        rows = [json.loads(line) for line in (directory / 'samples.jsonl').read_text().splitlines()]
        samples.extend({'artifact': label, **row} for row in rows)
        faults.extend({'artifact': label, **json.loads(line)} for line in (directory / 'faults.jsonl').read_text().splitlines())
        seed = next(row for row in rows if row['label'] == 'seed')
        last = next(row for row in rows if row['label'] == 'recover-10')
        recoveries = [row['elapsed_ns'] for row in rows if row['mode'] == 'recover']
        resources.append({'artifact': label,
                          'sampled_rss_max_bytes': max((row['working_set_sampled_max'] for row in rows if row['working_set_sampled_max'] is not None), default=None),
                          'os_peak_rss_bytes': None, 'allocated_regular_file_bytes': last['allocated_regular_file_bytes'],
                          'main_seed_logical_bytes': seed['logical_dataset_bytes'],
                          'main_round10_logical_bytes': last['logical_dataset_bytes'],
                          'recovery_whole_command_min_ns': min(recoveries), 'recovery_whole_command_max_ns': max(recoveries),
                          'latency_scope': 'whole native process and file inventory; not apply/commit/p99',
                          'actual_stack_peak': 'not_measured', 'queue_high_water': 'not_measured; only final resident queue',
                          'resource_budget_qualified': False})
        for path in directory.iterdir():
            if path.is_file():
                references[path.relative_to(OUT).as_posix()] = sha(path)
    probe_dir = OUT / (prefix + '-adapter-evidence')
    probe = read(probe_dir / 'result.json')
    assert probe['passed'] and probe['source_tree_sha256'] == identity['source_tree_sha256']
    faults.append({'case': 'actual-adapter-directory-fsync', 'result': 'passed',
                   'directory_fsync_successes': probe['directory_fsync_successes'],
                   'global_sync_fallbacks': probe['global_sync_fallbacks'], 'power_loss_qualification': False})
    faults.append({'case': 'os-peak-rss', 'result': 'not_measured',
                   'reason': 'WSL1 VmHWM reports zero; sampled RSS separately retained'})
    faults.append({'case': 'allocated-disk', 'result': 'partially_measured',
                   'reason': 'WSL1 st_blocks may report zero or change without content changes; preserve raw observations and null aggregates'})
    for path in probe_dir.iterdir():
        if path.is_file():
            references[path.relative_to(OUT).as_posix()] = sha(path)
    for path in OUT.glob(prefix + '-*'):
        if path.is_file() and path.suffix in ('.json', '.jsonl', '.log', '.zip', '.diff'):
            references[path.name] = sha(path)
    history = {}
    for earlier in ('11-red', '11-green', '11-targeted-', '11-store-dir-', '11-owner-dir-', '11-preflight-', '11-final-v1', '11-final-v2', '11-final-v3', '11-final-v4', '11-final-tail-', '11-ipc-', '11-owner-stack-', '11-cutover-stack-', '11-windows-owner-', '11-adapter-v3', '11-content-identity', '11-allocation-'):
        for path in OUT.glob(earlier + '*'):
            paths = [path] if path.is_file() else list(path.iterdir()) if path.is_dir() and path.name.endswith('-evidence') else []
            for item in paths:
                if item.is_file() and item.suffix in ('.json', '.jsonl', '.log', '.zip', '.diff', '.md'):
                    history[item.relative_to(OUT).as_posix()] = sha(item)
    history['11-development-failures.md'] = sha(OUT / '11-development-failures.md')
    history['11-debug/allocation-regression.py'] = sha(OUT / '11-debug/allocation-regression.py')
    identity.update(recorded_handoff_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    host=read(OUT / '11-linux-host.json'), artifacts=artifacts,
                    runtime_audit_sha256=sha(audit_path), frozen_source_archive_sha256=sha(archive_path),
                    frozen_archive_members_verified=len(expected), sealer_sha256=sha(Path(__file__)),
                    verification_scope='WSL1/lxfs Linux file functionality only',
                    target_linux_qualification=False, production_qualification=False,
                    power_loss_qualification=False, directory_durability_qualified=False,
                    capacity_stress_resource_performance='deferred', evidence_references=references)
    identity['retained_development_references'] = history
    license_path = OUT / '11-test-runner-LICENSE'
    identity['stock_runner_license_sha256'] = sha(license_path)
    destination.mkdir()
    (destination / 'stock-runner-LICENSE.txt').write_bytes(license_path.read_bytes())
    for name, data in (('identity.json', identity), ('workload.json', {'fixtures': workloads}),
                       ('resources.json', resources), ('audit.json', audit)):
        (destination / name).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    for name, rows in (('samples.jsonl', samples), ('faults.jsonl', faults)):
        (destination / name).write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')
    statuses = dict(Counter(row['result'] for row in faults))
    suites = '; '.join('{mode}: {passed} passed, {skipped} skipped, {failed} failed'.format(**suite) for suite in audit['suites'])
    summary = ('# Linux file recovery handoff\n\n'
               'Actual WSL1/lxfs execution; target Linux production qualification remains false.\n\n'
               'Source `{}`; {} source/build files. {}.\n\n'
               'Application and CLI each completed ten rounds / thirty native processes, including '
               '500 combinations, three synthetic strategy categories, shared account risk, '
               'complete reported authority, accepted/Unknown zero resend and two owned SIGKILL recoveries.\n\n'
               'Frozen archive: {} members independently verified; runtime audit: {} checks. '
               'Fault/observation status counts: `{}`. Counts include not_run/not_measured, not only passes.\n\n'
               'Real adapter directory fsync passed without global sync fallback. This does not prove '
               'power-loss or target filesystem durability. OS peak RSS is unavailable on this WSL1 host; '
               'disk allocation is only partially observable and can change independently of content. '
               'Sampled RSS, raw allocation observations, '
               'logical bytes and complete file hashes are retained. '
               'Queue high water, actual stack peaks, index costs, thousand-order capacity, stress, '
               'resource budgets, target performance, credentials/dumps, external NodeFence and '
               'production qualification remain unmeasured/deferred/not_run.\n\n'
               'See identity.json, workload.json, samples.jsonl, faults.jsonl, resources.json and audit.json; '
               'identity references raw sibling evidence by path/SHA. Physical datasets remain on lxfs. '
               'Earlier failures and v1 source/output remain preserved in the module. '
               'This seals ticket 11 evidence only; it does not execute ticket 12.\n').format(
                   identity['source_tree_sha256'], len(identity['files']), suites, len(expected),
                   audit['check_count'], json.dumps(statuses, sort_keys=True))
    if identity.get('continuation_of'):
        summary += ('\nContinuation of `' + identity['continuation_of'] + '`: ReleaseSafe and sixty process executions '
                    'reuse original bytes, commands and timestamps, with individually hashed aliases. '
                    'Only physical audits and the complete Debug run are new. ReleaseSafe used a 256 MiB '
                    'test runner; Debug used 512 MiB. Original failed Debug and guard-page diagnosis remain '
                    'retained. See reused_evidence and the continuation audit; no production stack or budget '
                    'qualification is inferred.\n')
    (destination / 'summary.md').write_text(summary, encoding='utf-8')
    manifest = {path.name: sha(path) for path in destination.iterdir() if path.is_file()}
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(str(destination), statuses, flush=True)


if __name__ == '__main__':
    main()
