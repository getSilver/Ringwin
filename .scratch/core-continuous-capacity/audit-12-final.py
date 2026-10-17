"""Audit current-source Windows regressions and current physical recovery datasets."""
from pathlib import Path
import importlib.util
import hashlib
import json
import re
import sys
import zipfile

OUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('processes', OUT / 'run-10-file-processes.py')
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)


def audit_processes(directory, artifact, source):
    identity = json.loads((directory / 'identity.json').read_text())
    assert identity['source_tree_sha256'] == source
    assert identity['artifact_sha256'] == artifact['sha256']
    assert processes.sha(Path(identity['artifact'])) == artifact['sha256']
    for name, digest in identity['producer_dependencies'].items():
        assert processes.sha(OUT / name) == digest
    summary = json.loads((directory / 'summary.json').read_text())
    assert summary['rounds'] == 10 and summary['steps'] == 30
    assert summary['production_qualification'] is False and summary['power_loss_qualification'] is False
    steps = []
    for path in directory.glob('*.result.json'):
        step = json.loads(path.read_text())
        label = step['label']
        assert step['source_tree_sha256'] == source and step['artifact_sha256'] == artifact['sha256']
        assert not step['timed_out']
        assert processes.sha(directory / (label + '.stdout.log')) == step['stdout_sha256']
        assert processes.sha(directory / (label + '.stderr.log')) == step['stderr_sha256']
        if step['intentional_process_interruption']:
            assert step['exit_code'] != 0
        else:
            assert step['exit_code'] == 0
            report = json.loads((directory / (label + '.stdout.log')).read_text())
            if step['protocol'].endswith('observation-file'):
                processes.validate_observation(report, step['mode'])
            else:
                processes.validate(report, step['mode'], report['round'])
            if step['mode'] == 'recover':
                assert processes.same_file_content(step['files_before'], step['files_after'])
        steps.append(step)
    assert len(steps) == 30
    latest = {}
    for step in sorted(steps, key=lambda row: row['finished_utc']):
        latest[step['command'][-1]] = step['files_after']
    assert len(latest) == 5
    for name, expected in latest.items():
        assert processes.same_file_content(processes.inventory(Path(name)), expected), name
    reports = json.loads((directory / 'reports.json').read_text())
    assert len(reports) == 11
    processes.same_authority(reports[0]['seed'], reports[0]['recover'])
    previous = reports[0]['seed']
    for pair in reports[1:]:
        processes.advanced_once(previous, pair['advance'])
        processes.same_authority(pair['advance'], pair['recover'])
        previous = pair['advance']
    observations = json.loads((directory / 'observation-reports.json').read_text())
    processes.same_authority(observations['seed'], observations['recover'])
    faults = [json.loads(line) for line in (directory / 'faults.jsonl').read_text().splitlines()]
    assert sum(row['result'] == 'passed' for row in faults) == 2
    assert sum(row['result'] == 'not_run' for row in faults) == 6
    assert any(row['case'] == 'launcher-artifact-sha-mismatch' and not row['child_launched'] and not row['dataset_changed'] for row in faults)
    return {'artifact': artifact['name'], 'state': 'passed', 'processes': 30,
            'physical_datasets': 5, 'full_authority': True, 'recover_sends': 0,
            'source_tree_sha256': source, 'data_and_raw_evidence': str(directory),
            'production_qualification': False}


def main():
    prefix = sys.argv[1]
    identity = json.loads((OUT / (prefix + '-identity.json')).read_text())
    frozen = processes.capture.source_manifest()
    assert identity['files'] == frozen['files'] and identity['source_tree_sha256'] == frozen['source_tree_sha256']
    assert processes.sha(Path('D:/Program Files/zig/zig.exe')) == identity['zig_sha256']
    for name, digest in identity['producer_dependencies'].items():
        assert processes.sha(OUT / name) == digest
    linux_path = OUT / '11-final-v6-identity.json'
    assert processes.sha(linux_path) == identity['linux_identity_sha256']
    linux = json.loads(linux_path.read_text())
    assert linux['files'] == identity['files'] and linux['source_tree_sha256'] == identity['source_tree_sha256']
    package = OUT / '11-final-v6-linux-evidence'
    assert processes.sha(package / 'manifest.json') == identity['linux_package_manifest_sha256']
    for name, digest in json.loads((package / 'manifest.json').read_text()).items():
        assert processes.sha(package / name) == digest
    package_identity = json.loads((package / 'identity.json').read_text())
    for name, digest in {**package_identity['evidence_references'], **package_identity['retained_development_references']}.items():
        assert processes.sha(OUT / name) == digest
    previous_path = OUT / '10-final-v3-windows-evidence/identity.json'
    assert processes.sha(previous_path) == identity['previous_windows_package_identity_sha256']
    previous = json.loads(previous_path.read_text())
    assert previous['source_tree_sha256'] == identity['previous_windows_source_tree_sha256']
    for name, digest in previous['input_files'].items():
        assert processes.sha(OUT / name) == digest
    with zipfile.ZipFile(OUT / (prefix + '-source.zip')) as archive:
        expected = {row['path']: row['sha256'] for row in identity['files']}
        expected.update({'.scratch/core-continuous-capacity/' + name: digest for name, digest in identity['producer_dependencies'].items()})
        assert set(archive.namelist()) == set(expected)
        for name, digest in expected.items():
            assert hashlib.sha256(archive.read(name)).hexdigest() == digest
    artifacts = json.loads((OUT / (prefix + '-artifacts.json')).read_text())
    assert len(artifacts) == 6
    runner_spec = importlib.util.spec_from_file_location('runner', OUT / 'run-12-windows.py')
    runner = importlib.util.module_from_spec(runner_spec)
    runner_spec.loader.exec_module(runner)
    for artifact in artifacts:
        assert processes.sha(OUT / artifact['name']) == artifact['sha256']
        assert (OUT / artifact['name']).stat().st_size == artifact['bytes']
        assert (OUT / artifact['name']).read_bytes()[:2] == b'MZ'
        assert runner.pe_stack(OUT / artifact['name']) == artifact['pe_stack_reserve_bytes']
        assert artifact['pe_stack_reserve_bytes'] == (67108864 if artifact['role'] == 'application' else 268435456)
    captures = sorted(OUT.glob(prefix + '-*.result.json'))
    assert len(captures) == 16
    for path in captures:
        row = json.loads(path.read_text())
        assert row['source_tree_sha256'] == identity['source_tree_sha256']
        assert row['exit_code'] == 0 and not row['timed_out'] and row['capture_error'] is None
        assert row.get('fatal_diagnostic') is None
        assert row['source_mismatches_after'] == row['producer_mismatches_after'] == 0
        stem = path.name[:-len('.result.json')]
        for extension, digest in (('.log', row['log_sha256']), ('.stdout.log', row['stdout_sha256']),
                                   ('.memory.jsonl', row['memory']['samples_sha256'])):
            assert processes.sha(OUT / (stem + extension)) == digest
    tests = []
    fault_lines = []
    for label, count in (('native-file', 8), ('venue-family', 323), ('owner-memory', 1), ('owner-file', 1)):
        text = (OUT / (prefix + '-' + label + '.log')).read_text()
        assert re.search(r'All ' + str(count) + r' tests passed\.', text), label
        assert not re.search(r'FAIL \(|tests leaked memory|errors were logged', text)
        artifact = next(row for row in artifacts if row['name'] == prefix + '-' + label + '.exe')
        consumed = json.loads((OUT / (prefix + '-' + label + '.result.json')).read_text())
        assert consumed['consumed_artifact_sha256'] == artifact['sha256']
        tests.append({'label': label, 'passed': count, 'skipped': 0, 'failed': 0})
        for line in text.splitlines():
            if any(marker in line for marker in ('windows_capacity_fault injection=', 'windows_capacity_reject injection=', 'windows_capacity_gateway_fault injection=')):
                fault_lines.append(line)
    assert len(fault_lines) == 18
    physical = []
    for label in ('app', 'cli'):
        artifact = next(row for row in artifacts if row['name'] == prefix + '-' + label + '.exe')
        for flag in ('offline-fixture', 'windows-chain-test', 'processes'):
            record = json.loads((OUT / (prefix + '-' + label + '-' + flag + '.result.json')).read_text())
            assert record['consumed_artifact_sha256'] == artifact['sha256']
        physical.append(audit_processes(OUT / (prefix + '-' + label + '-processes'), artifact, identity['source_tree_sha256']))
    report = {'state': 'passed', 'source_tree_sha256': identity['source_tree_sha256'],
              'same_linux_source': True, 'archive_members': len(expected), 'captures': len(captures),
              'artifacts': len(artifacts), 'affected_windows_tests': tests, 'fault_cases': fault_lines,
              'physical_audits': physical, 'production_qualification': False,
              'capacity_stress_resource_performance': 'deferred',
              'full_windows_suite_rerun': False, 'historical_full_windows_scope': 'ticket10 source only'}
    (OUT / (prefix + '-audit.json')).write_text(json.dumps(report, indent=2) + '\n')
    print('Windows same-source audit passed:', sum(row['passed'] for row in tests), 'affected tests / 60 processes', flush=True)


if __name__ == '__main__':
    main()
