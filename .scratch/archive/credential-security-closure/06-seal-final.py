"""Seal completed final-wave results without rerunning or relabeling evidence."""
from pathlib import Path
import argparse
import datetime
import json
import re
import struct
import subprocess
from capture import ROOT, OUT, sha, source_manifest


def item(path):
    path = Path(path)
    return dict(path=str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path),
                bytes=path.stat().st_size, sha256=sha(path))


def pe_stack(path):
    with path.open('rb') as f:
        assert f.read(2) == b'MZ'
        f.seek(0x3c)
        offset = struct.unpack('<I', f.read(4))[0]
        f.seek(offset)
        assert f.read(4) == b'PE\0\0'
        f.seek(offset + 24)
        assert struct.unpack('<H', f.read(2))[0] == 0x20b
        f.seek(offset + 24 + 72)
        return struct.unpack('<Q', f.read(8))[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('wave')
    args = parser.parse_args()
    wave = args.wave
    plan_path = OUT / (wave + '-plan.json')
    state_path = OUT / 'runs' / wave / 'state.json'
    plan = json.loads(plan_path.read_bytes())
    state = json.loads(state_path.read_bytes())
    assert state['status'] == 'passed', state
    assert state['plan_sha256'] == sha(plan_path)
    assert source_manifest() == plan['source']
    for row in plan['producers']:
        assert sha(ROOT / row['path']) == row['sha256'], row['path']
    assert sha(ROOT / plan['source_archive']['path']) == plan['source_archive']['sha256']
    assert len(state['completed']) == len(plan['steps'])
    results = []
    for step, completed in zip(plan['steps'], state['completed']):
        label = wave + '-' + step['label']
        assert completed['label'] == label and completed['exit_code'] == 0
        folder = OUT / 'runs' / label
        assert sha(folder / 'result.json') == completed['result_sha256']
        record = json.loads((folder / 'result.json').read_bytes())
        assert record['exit_code'] == record['child_exit_code'] == 0
        assert not any(record[key] for key in ('timed_out', 'fatal_diagnostic',
                                             'capture_error', 'source_changed'))
        assert record['source_tree_sha256'] == plan['source']['source_tree_sha256']
        assert record['command'] == step['command']
        assert json.loads((folder / 'source.json').read_bytes()) == plan['source']
        assert sha(folder / 'stdout.log') == record['stdout_sha256']
        assert sha(folder / 'stderr.log') == record['stderr_sha256']
        raw = (folder / 'stdout.log').read_bytes() + b'\n' + (folder / 'stderr.log').read_bytes()
        summaries = re.findall(rb'All (\d+) tests passed\.', raw)
        progress = re.findall(rb'(?:^|\n)(\d+)/(\d+) ', raw)
        counts = dict(all_passed_summaries=[int(n) for n in summaries],
                      reported_total=max((int(n[1]) for n in progress), default=None),
                      skip_markers=len(re.findall(rb'\bSKIP\b', raw)))
        results.append(dict(label=step['label'], elapsed_ns=record['elapsed_ns'],
                            result=item(folder / 'result.json'),
                            source=item(folder / 'source.json'),
                            stdout=item(folder / 'stdout.log'), stderr=item(folder / 'stderr.log'),
                            tests=counts))
    artifacts = []
    for row in plan['artifacts']:
        path = ROOT / row['path']
        measured = item(path)
        measured['label'] = row['label']
        if path.suffix == '.exe':
            measured['pe_stack_reserve'] = pe_stack(path)
            if row['label'].startswith('compile-core-'):
                assert measured['pe_stack_reserve'] == 536870912
        artifacts.append(measured)
    for label in ('full-debug', 'full-releasesafe'):
        result = next(r for r in results if r['label'] == label)
        assert result['tests']['reported_total'], label
    report = dict(sealed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  head_at_seal=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  implementation_head=plan['implementation_head'],
                  source_tree_sha256=plan['source']['source_tree_sha256'],
                  plan=item(plan_path), state=item(state_path), sealer=item(Path(__file__).resolve()),
                  source_archive=item(ROOT / plan['source_archive']['path']),
                  producers=plan['producers'], compiler_version=plan['compiler_version'],
                  results=results, artifacts=artifacts,
                  review_resolution=item(OUT / '06-review-resolution.md'),
                  review_followups=[item(OUT / ('06-review-followup-' + axis + '.md'))
                                    for axis in ('standards', 'spec')],
                  prior_attempts='v1/v2 stopped solely at metadata whitespace precheck before any compiler/full suite',
                  network_or_production_qualification=False,
                  limits=['Synthetic/offline only; no real credentials, Venue orders or deployment',
                          'WSL1 functional evidence does not establish target dump/swap/power-loss qualification',
                          'Linux standalone curl roots semantic compile checks only, not linked curl executables',
                          'Compiler temporaries/registers and TLS/OS internal storage are outside this wipe proof',
                          'Final task closure additionally requires implementer preservation/cleanup'])
    target = OUT / (wave + '-validation.json')
    with target.open('xb') as f:
        f.write((json.dumps(report, indent=2) + '\n').encode())
    print(json.dumps(dict(path=str(target), stages=len(results), artifacts=len(artifacts),
                         full_tests={r['label']: r['tests'] for r in results if r['label'].startswith('full-')})))


if __name__ == '__main__':
    main()
