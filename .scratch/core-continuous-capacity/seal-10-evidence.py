"""Collect already audited Windows evidence; keeps every original input in place."""
from pathlib import Path
import hashlib
import json
import re
import sys

OUT = Path(__file__).resolve().parent
prefix = sys.argv[1] if len(sys.argv) > 1 else '10-final-v1'
assert prefix and all(c.isalnum() or c in '-_' for c in prefix)
inputs = {}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    inputs[path.relative_to(OUT).as_posix()] = sha(path)
    return json.loads(path.read_text(encoding='utf-8-sig'))


def lines(path):
    inputs[path.relative_to(OUT).as_posix()] = sha(path)
    return path.read_text(encoding='utf-8-sig').splitlines()


audit = read(OUT / (prefix + '-audit.json'))
assert audit['state'] == 'passed'
original_identity = read(OUT / (prefix + '-identity.json'))
artifacts = read(OUT / (prefix + '-artifacts.json'))
assert original_identity['source_tree_sha256'] == audit['source_tree_sha256']
workloads, samples, faults, resources = [], [], [], []
for kind in ('app', 'cli'):
    directory = OUT / (prefix + '-' + kind + '-processes')
    summary = read(directory / 'summary.json')
    assert summary['rounds'] == 10 and summary['steps'] == 30
    workloads.append({'artifact_kind': kind, 'workload': read(directory / 'workload.json')})
    rows = [json.loads(line) for line in lines(directory / 'samples.jsonl')]
    samples.extend({'artifact_kind': kind, **row} for row in rows)
    faults.extend({'artifact_kind': kind, **json.loads(line)} for line in lines(directory / 'faults.jsonl'))
    seed = read(directory / 'recover-00.result.json')
    last = read(directory / 'recover-10.result.json')
    resources.append({'artifact_kind': kind,
                      'peak_working_set_bytes_observed': max((r['working_set_peak_observed'] for r in rows
                                                            if r['working_set_peak_observed'] is not None), default=None),
                      'main_dataset_initial_logical_bytes': sum(f['bytes'] for f in seed['files_after']),
                      'main_dataset_final_logical_bytes': sum(f['bytes'] for f in last['files_after']),
                      'main_dataset_final_allocated_regular_file_bytes': sum(f['allocated_bytes'] for f in last['files_after']
                                                                            if f['allocated_bytes'] is not None),
                      'allocation_observation_complete': all(f['allocated_bytes'] is not None for f in last['files_after']),
                      'allocation_observation_missing_files': sum(f['allocated_bytes'] is None for f in last['files_after']),
                      'normal_recovery_process_elapsed_ns': [r['elapsed_ns'] for r in rows if r['mode'] == 'recover'],
                      'actual_thread_stack_peak': 'not_measured', 'physical_index_cost': 'not_measured',
                      'resource_budget_qualification': 'deferred'})

markers = {'windows_capacity_fault injection=': 'owner_fault_hook',
           'windows_capacity_gateway_fault injection=': 'gateway_fault_hook',
           'windows_capacity_reject injection=': 'physical_or_authenticated_rejection'}
for mode in ('releasesafe', 'debug'):
    source = OUT / (prefix + '-full-' + mode + '.log')
    output = lines(source)
    assert any(re.fullmatch(r'All \d+ tests passed\.', line) for line in output)
    count = 0
    for line in output:
        for marker, group in markers.items():
            if marker not in line:
                continue
            values = dict(re.findall(r'([a-z_]+)=([^\s]+)', 'injection=' + line.split(marker, 1)[1]))
            for key, value in list(values.items()):
                if value in ('true', 'false'):
                    values[key] = value == 'true'
                elif len(value) < 30 and re.fullmatch(r'-?\d+', value):
                    values[key] = int(value)
            faults.append({'mode': mode, 'group': group, 'result': 'passed',
                           'assertion_scope': 'complete frozen suite terminal success and source-owned public seam assertions',
                           'source_log': source.name, 'diagnostic': values})
            count += 1
    assert count == 18

for observation in original_identity['native_file_probe']['observations']:
    faults.append({'group': 'native_platform_semantics', 'result': 'failed_unqualified' if
                   observation.get('directory_flush_result') == 0 else 'observed', 'observation': observation})

failures = []
capture_paths = set(OUT.glob('10-*.result.json'))
for directory in OUT.glob('10-*'):
    if directory.is_dir() and not directory.is_symlink():
        capture_paths.update(directory.rglob('*.result.json'))
for path in sorted(capture_paths):
    result = read(path)
    if result['exit_code'] != 0:
        intentional = result.get('intentional_process_interruption', False)
        failures.append({'path': path.relative_to(OUT).as_posix(), 'sha256': sha(path), 'exit_code': result['exit_code'],
                         'timed_out': result.get('timed_out'), 'capture_error': result.get('capture_error'),
                         'intentional_process_interruption': intentional,
                         'scope': 'expected owned-process termination' if intentional else
                         'retained development failure or explicit negative capture probe; not final qualification'})

destination = OUT / (prefix + '-windows-evidence')
assert not destination.exists(), 'Existing sealed evidence retained'
destination.mkdir()
identity = {'source_tree_sha256': audit['source_tree_sha256'], 'original_identity': original_identity,
            'artifacts': artifacts, 'collector_sha256': sha(Path(__file__)), 'input_files': inputs,
            'production_qualification': False, 'directory_durability_qualification': False,
            'power_loss_qualification': False, 'capacity_stress_qualification': 'deferred'}
for name, value in (('identity.json', identity), ('workload.json', {'fixtures': workloads}),
                    ('resources.json', resources), ('retained-failures.json', failures)):
    (destination / name).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
for name, rows in (('samples.jsonl', samples), ('faults.jsonl', faults)):
    (destination / name).write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')
(destination / 'summary.md').write_text(
    '# Windows small functional evidence\n\n'
    f'Frozen source: `{audit["source_tree_sha256"]}`. Full ReleaseSafe and Debug each '
    f'passed {audit["full_suite_tests_per_mode"]} tests; audit passed {audit["checks"]} checks. '
    'The application with 64MiB stack reserve and CLI with 256MiB each completed ten file archive rounds '
    'and thirty owned fresh processes, including separate four-route 500-identity fixtures.\n\n'
    'faults.jsonl includes 18 storage/rejection cases per full mode, owned-process interruptions, '
    'artifact mismatch rejection and explicit not-run scope. Hook errors are injected, not OS disk failures. '
    'Native directory flush actually failed (error 5); power-loss/directory durability is unqualified.\n\n'
    'samples.jsonl preserves direct native child observations. Process elapsed includes monitoring and file inventory; '
    'Owner recovery_ns covers only Owner restoration. Queue samples are command-end values; actual stack peak, '
    'index cost, resource budgets, thousand-order/stress, Linux, external fencing, memory-dump protection and '
    'production qualification remain unmeasured or deferred.\n\n'
    'identity.json binds source, artifacts, producers, host, compiler, schema and every original input hash. '
    'retained-failures.json inventories all nonzero captures; originals and physical datasets remain in place.\n',
    encoding='utf-8')
print('Sealed Windows evidence:', len(samples), 'native process samples,', len(faults), 'fault observations,',
      len(failures), 'retained nonzero captures')
