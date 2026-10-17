"""Seal common-source functional evidence, historical failures and independent platform limits."""
from pathlib import Path
from collections import Counter
import datetime
import hashlib
import json
import subprocess
import sys

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    prefix = sys.argv[1]
    destination = OUT / (prefix + '-wave-evidence')
    assert not destination.exists(), 'New handoff required; previous bytes retained'
    identity = json.loads((OUT / (prefix + '-identity.json')).read_text())
    script = OUT / 'audit-12-final.py'
    assert sha(script) == identity['producer_dependencies'][script.name]
    subprocess.run([sys.executable, str(script), prefix], check=True)
    audit = json.loads((OUT / (prefix + '-audit.json')).read_text())
    assert audit['state'] == 'passed' and audit['same_linux_source']
    tickets = []
    for number in range(1, 12):
        matches = list((OUT / 'issues').glob(f'{number:02}-*.md'))
        assert len(matches) == 1
        text = matches[0].read_text(encoding='utf-8')
        assert 'Status: resolved' in text and '- [ ]' not in text
        tickets.append({'ticket': number, 'path': matches[0].relative_to(OUT).as_posix(),
                        'sha256': sha(matches[0]), 'scope': 'contract or small functional scope; capacity/performance not qualified'})
    references = {}
    tracked = subprocess.check_output(['git', 'ls-files', '--', str(OUT.relative_to(ROOT))], cwd=ROOT, text=True).splitlines()
    for name in tracked:
        path = ROOT / name
        relative = path.relative_to(OUT).as_posix()
        if relative == 'map.md' or relative.startswith('12-') or relative.startswith('issues/12-'):
            continue
        if path.suffix in ('.exe', '.pdb', '.o'):
            continue
        references[relative] = sha(path)
    for path in OUT.glob(prefix + '-*'):
        if path.is_file() and path.suffix in ('.json', '.jsonl', '.log', '.zip'):
            references[path.name] = sha(path)
    for name in identity['producer_dependencies']:
        references[name] = sha(OUT / name)
    for name in ('12-coverage.md', '12-production-handoff.md'):
        references[name] = sha(OUT / name)
    samples = []
    faults = []
    workloads = []
    physical = audit['physical_audits']
    for label in ('app', 'cli'):
        directory = OUT / (prefix + '-' + label + '-processes')
        workloads.append({'artifact': label, **json.loads((directory / 'workload.json').read_text())})
        samples.extend({'platform': 'windows', 'artifact': label, **json.loads(line)} for line in (directory / 'samples.jsonl').read_text().splitlines())
        faults.extend({'platform': 'windows', 'artifact': label, **json.loads(line)} for line in (directory / 'faults.jsonl').read_text().splitlines())
        for path in directory.iterdir():
            if path.is_file():
                references[path.relative_to(OUT).as_posix()] = sha(path)
    for line in audit['fault_cases']:
        faults.append({'platform': 'windows', 'case': line, 'result': 'passed', 'execution': 'new affected Native file Debug regression'})
    linux_package = OUT / '11-final-v6-linux-evidence'
    samples.extend({'evidence_platform': 'linux-wsl1', **json.loads(line)} for line in (linux_package / 'samples.jsonl').read_text().splitlines())
    faults.extend({'platform': 'linux-wsl1', **json.loads(line)} for line in (linux_package / 'faults.jsonl').read_text().splitlines())
    faults.append({'platform': 'windows', 'case': 'directory flush durability', 'result': 'not_qualified',
                   'evidence': '10-file-semantics-nativeprobe/output.log; error5; current Windows implementation unchanged'})
    status_counts = dict(Counter(row['result'] for row in faults))
    # Nonzero historical captures remain references, including deliberate kills
    # and negative probes; none are silently reclassified as successful runs.
    historical = []
    for name in references:
        if name.endswith('.result.json'):
            row = json.loads((OUT / name).read_text(encoding='utf-8-sig'))
            if row.get('exit_code', 0) != 0 or row.get('timed_out') or row.get('capture_error'):
                historical.append({'path': name, 'sha256': references[name],
                                   'exit_code': row.get('exit_code'), 'timed_out': row.get('timed_out'),
                                   'classification': 'retained original result; may be deliberate fault or failed candidate'})
    identity.update(sealed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    evidence_references=references, tickets=tickets,
                    windows_validation='333 affected Debug tests and sixty new process commands; not a new full Windows suite',
                    linux_validation='ticket11 exact common source: ReleaseSafe/Debug each 623 passed / 1 explicit IPC skip / 0 failed',
                    historical_nonzero_captures=historical, fault_status_counts=status_counts,
                    completed_scope='small functional closure only', parent_map_closure_is_production_qualification=False,
                    target_linux_qualification=False, windows_production_qualification=False,
                    power_loss_qualification=False, sealer_sha256=sha(Path(__file__)))
    destination.mkdir()
    for name, value in (('identity.json', identity), ('audit.json', audit), ('workload.json', {'windows': workloads}),
                        ('physical-audits.json', physical)):
        (destination / name).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    for name, rows in (('samples.jsonl', samples), ('faults.jsonl', faults)):
        (destination / name).write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')
    (destination / 'summary.md').write_text(
        '# Core continuous operation: small functional handoff\n\n'
        f'Common source `{identity["source_tree_sha256"]}`; journal/state/registry 39/43/37, artifact identity1, seed0x20261008.\n\n'
        'Linux/WSL1 ReleaseSafe and Debug each completed 623 passed, 1 exact memfd ENOSYS IPC skip, 0 failed. '
        'Windows artifacts were rebuilt from the identical source; 333 affected Debug tests and application/CLI '
        'each ten rounds / thirty new processes passed. Historical full Windows tests belong to ticket10 source '
        'and are not relabeled as current full-suite runs. Both platforms preserve complete authority and '
        'accepted/Unknown zero resend; all fixtures keep live/terminal counts separately at or below100.\n\n'
        'Ticket01-11 obligations are mapped in ../12-coverage.md. Independent production work and qualification '
        'limits are in ../12-production-handoff.md. Windows directory flush durability is unqualified; '
        'WSL1 directory fsync success does not qualify target disks or power-loss recovery. '
        'Capacity/stress, resource budgets, actual stack peaks, transient queues, index costs, target performance, '
        'production process/security/NodeFence/Venue/soak/shadow/Canary qualification remain deferred/not_run.\n\n'
        f'Fault status counts: `{json.dumps(status_counts, sort_keys=True)}`. '
        f'{len(historical)} nonzero/timed-out historical captures remain referenced without promotion. '
        'The map may close this functional scope only. No deployment, credentials or real trading were authorized.\n',
        encoding='utf-8')
    manifest = {path.name: sha(path) for path in destination.iterdir() if path.is_file()}
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print('Wave handoff sealed:', destination, 'references:', len(references), flush=True)


if __name__ == '__main__':
    main()
