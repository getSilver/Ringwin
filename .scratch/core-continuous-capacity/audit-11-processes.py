"""Audit native file process evidence against retained physical files, then export flat evidence."""
from pathlib import Path
import importlib.util
import json
import shutil
import subprocess
import sys

OUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('processes', OUT / 'run-10-file-processes.py')
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)


def main():
    evidence, export = map(Path, sys.argv[1:])
    if sys.platform != 'linux' or export.exists():
        raise RuntimeError('Native Linux and a new export directory required')
    summary = json.loads((evidence / 'summary.json').read_text())
    identity = json.loads((evidence / 'identity.json').read_text())
    assert summary['rounds'] == 10 and summary['steps'] == 30
    assert summary['production_qualification'] is False and summary['power_loss_qualification'] is False
    assert processes.sha(Path(identity['artifact'])) == identity['artifact_sha256']
    frozen = processes.capture.source_manifest()
    assert identity['files'] == frozen['files'] and identity['source_tree_sha256'] == frozen['source_tree_sha256']
    checks = []
    final_files = {}
    for path in sorted(evidence.glob('*.result.json')):
        step = json.loads(path.read_text())
        label = step['label']
        assert not step['timed_out']
        assert step['artifact_sha256'] == identity['artifact_sha256']
        assert step['source_tree_sha256'] == identity['source_tree_sha256']
        assert step['stdout_sha256'] == processes.sha(evidence / (label + '.stdout.log'))
        assert step['stderr_sha256'] == processes.sha(evidence / (label + '.stderr.log'))
        if step['intentional_process_interruption']:
            assert step['exit_code'] == -9
        else:
            assert step['exit_code'] == 0
            report = json.loads((evidence / (label + '.stdout.log')).read_text())
            if step['protocol'] == '--linux-observation-file':
                processes.validate_observation(report, step['mode'])
            else:
                processes.validate(report, step['mode'], report['round'])
            if step['mode'] == 'recover':
                assert step['files_before'] == step['files_after']
        checks.append(label)
    # Last command for each dataset is selected by recorded finish time, not filename.
    steps = sorted((json.loads(p.read_text()) for p in evidence.glob('*.result.json')),
                   key=lambda s: s['finished_utc'])
    for step in steps:
        final_files[step['command'][-1]] = step['files_after']
    for directory, expected in final_files.items():
        assert processes.inventory(Path(directory)) == expected, 'Retained physical dataset drift'
        checks.append('physical:' + directory)
    reports = json.loads((evidence / 'reports.json').read_text())
    assert len(reports) == 11
    processes.same_authority(reports[0]['seed'], reports[0]['recover'])
    previous = reports[0]['seed']
    for pair in reports[1:]:
        processes.advanced_once(previous, pair['advance'])
        processes.same_authority(pair['advance'], pair['recover'])
        previous = pair['advance']
    observation = json.loads((evidence / 'observation-reports.json').read_text())
    processes.same_authority(observation['seed'], observation['recover'])
    faults = [json.loads(line) for line in (evidence / 'faults.jsonl').read_text().splitlines()]
    assert sum(f['result'] == 'passed' for f in faults) == 2
    assert sum(f['result'] == 'not_run' for f in faults) == 6
    assert any(f['case'] == 'launcher-artifact-sha-mismatch' and not f['child_launched'] for f in faults)
    for name, digest in identity['producer_dependencies'].items():
        assert processes.sha(OUT / name) == digest
    host = json.loads((OUT / '11-linux-host.json').read_text())
    assert identity['host_metadata_sha256'] == processes.sha(OUT / '11-linux-host.json')
    result = {'state': 'passed', 'checks': checks, 'processes': len(steps),
              'source_tree_sha256': frozen['source_tree_sha256'], 'artifact_sha256': identity['artifact_sha256'],
              'df': subprocess.check_output(['df', '-T', str(evidence)], universal_newlines=True),
              'platform_scope': host['verification_scope'], 'production_qualification': False}
    (evidence / 'audit.json').write_text(json.dumps(result, indent=2) + '\n')
    export.mkdir()
    for path in evidence.iterdir():
        if path.is_file():
            shutil.copyfile(str(path), str(export / path.name))
    print('physical/native audit passed; {} processes, {} datasets; exported {}'.format(len(steps), len(final_files), export))


if __name__ == '__main__':
    main()
