"""Recheck source, producers, ELF identities, raw logs and exported Linux evidence."""
from pathlib import Path
import hashlib
import importlib.util
import json
import re
import sys

OUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('base', OUT / 'run-07-command.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


def main():
    prefix = sys.argv[1]
    identity = json.loads((OUT / (prefix + '-identity.json')).read_text())
    frozen = base.source_manifest()
    assert identity['files'] == frozen['files'] and identity['source_tree_sha256'] == frozen['source_tree_sha256']
    for name, digest in identity['producer_dependencies'].items():
        assert base.sha(OUT / name) == digest, name
    checks = ['source', 'producers']
    artifacts = json.loads((OUT / (prefix + '-artifacts.json')).read_text())
    assert len(artifacts) == 4
    for item in artifacts:
        path = OUT / item['name']
        assert base.sha(path) == item['sha256'] and path.read_bytes()[:4] == b'\x7fELF'
        assert path.stat().st_size == item['bytes']
        checks.append('ELF:' + item['name'])
    captures = sorted(OUT.glob(prefix + '-*.result.json'))
    assert len(captures) == 13, 'Expected 13 build/probe/process/audit/test captures'
    for path in captures:
        record = json.loads(path.read_text())
        assert record['exit_code'] == 0 and not record['timed_out'] and record['capture_error'] is None, str(path)
        assert record['source_tree_sha256'] == frozen['source_tree_sha256']
        assert record['source_mismatches_after'] == 0 and record['producer_mismatches_after'] == 0
        stem = path.name[:-len('.result.json')]
        assert record['log_sha256'] == base.sha(OUT / (stem + '.log'))
        assert record['stdout_sha256'] == base.sha(OUT / (stem + '.stdout.log'))
        assert record['memory']['samples_sha256'] == base.sha(OUT / (stem + '.memory.jsonl'))
        checks.append('capture:' + stem)
    suites = []
    faults = []
    for mode in ('releasesafe', 'debug'):
        text = (OUT / (prefix + '-native-full-' + mode + '.log')).read_text()
        all_pass = re.search(r'All (\d+) tests passed\.', text)
        mixed = re.search(r'(\d+) passed; (\d+) skipped; (\d+) failed\.', text)
        assert all_pass or mixed, mode + ': suite incomplete'
        counts = {'passed': int(all_pass[1]), 'skipped': 0, 'failed': 0} if all_pass else dict(zip(('passed', 'skipped', 'failed'), map(int, mixed.groups())))
        assert counts['failed'] == 0 and counts['passed'] + counts['skipped'] >= 624
        assert not re.search(r'\d+ (tests leaked memory|errors were logged)', text)
        skipped = re.findall(r'^\d+/\d+ (.+)\.\.\.SKIP$', text, re.MULTILINE)
        assert len(skipped) == counts['skipped']
        assert skipped == ['strategy_host_ipc.test.bounded rings and frozen bridge fail closed'], skipped
        suites.append({'mode': mode, **counts, 'skipped_tests': skipped,
                       'skip_reason': 'WSL1 memfd_create ENOSYS; production IPC unchanged'})
        faults.append({'mode': mode, 'result': 'skipped', 'case': skipped[0],
                       'reason': 'WSL1 memfd_create ENOSYS'})
        for line in text.splitlines():
            for marker in ('windows_capacity_fault injection=', 'windows_capacity_reject injection=', 'windows_capacity_gateway_fault injection='):
                if marker in line:
                    faults.append({'mode': mode, 'result': 'passed', 'evidence': line[line.index(marker):]})
        assert sum(f['mode'] == mode and f['result'] == 'passed' for f in faults) == 18
        checks.append('suite:' + mode)
    resources = []
    adapter_evidence = OUT / (prefix + '-adapter-evidence')
    adapter = json.loads((adapter_evidence / 'result.json').read_text())
    assert adapter['passed'] and adapter['global_sync_fallbacks'] == 0 and not adapter['failed_syscalls']
    assert adapter['source_tree_sha256'] == frozen['source_tree_sha256']
    assert adapter['artifact_sha256'] == next(a['sha256'] for a in artifacts if a['name'] == prefix + '-app')
    for name, digest in adapter['logs'].items():
        assert base.sha(adapter_evidence / name) == digest
    checks.append('actual-adapter-directory-fsync')
    for label in ('app', 'cli'):
        evidence = OUT / (prefix + '-' + label + '-evidence')
        audit = json.loads((evidence / 'audit.json').read_text())
        assert audit['state'] == 'passed' and audit['processes'] == 30
        assert audit['source_tree_sha256'] == frozen['source_tree_sha256']
        artifact = next(a for a in artifacts if a['name'] == prefix + '-' + label)
        assert audit['artifact_sha256'] == artifact['sha256']
        for path in evidence.glob('*.result.json'):
            step = json.loads(path.read_text())
            assert step['stdout_sha256'] == base.sha(evidence / (step['label'] + '.stdout.log'))
            assert step['stderr_sha256'] == base.sha(evidence / (step['label'] + '.stderr.log'))
            checks.append(label + ':' + step['label'])
        rows = [json.loads(line) for line in (evidence / 'samples.jsonl').read_text().splitlines()]
        resources.append({'artifact': label, 'sampled_rss_max_bytes': max((r['working_set_sampled_max'] for r in rows if r['working_set_sampled_max'] is not None), default=None),
                          'os_peak_rss': 'unavailable on WSL1', 'allocated_regular_file_bytes': 'partial/mutable WSL1 allocation observations; see raw samples',
                          'main_chain_seed_bytes': rows[0]['logical_dataset_bytes'],
                          'actual_stack_peak': 'not_measured', 'queue_high_water': 'not_measured; only end-of-command samples',
                          'resources_performance_qualified': False})
        checks.append('native-physical-audit:' + label)
    result = {'state': 'passed', 'source_tree_sha256': frozen['source_tree_sha256'], 'checks': checks,
              'check_count': len(checks), 'suites': suites, 'resources': resources,
              'production_qualification': False, 'target_linux_qualification': False,
              'directory_durability_qualified': False, 'power_loss_qualification': False}
    (OUT / (prefix + '-audit.json')).write_text(json.dumps(result, indent=2) + '\n')
    (OUT / (prefix + '-faults.jsonl')).write_text(''.join(json.dumps(f) + '\n' for f in faults))
    print(json.dumps({'state': result['state'], 'check_count': len(checks), 'suites': suites}, indent=2))


if __name__ == '__main__':
    main()
