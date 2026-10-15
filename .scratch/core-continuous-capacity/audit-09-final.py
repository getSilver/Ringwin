"""Verify actual serial Frontier09 artifacts; no execution or qualification claims."""
from pathlib import Path
import hashlib
import json
import re
import struct
import sys

root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent
prefix = sys.argv[1] if len(sys.argv) > 1 else '09-final-v1'
checks = []


def read(name):
    return json.loads((out / name).read_text(encoding='utf-8-sig'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(name, passed):
    checks.append({'check': name, 'passed': bool(passed)})
    if not passed:
        raise RuntimeError(name)


manifest = read(prefix + '-source-manifest.json')
files = manifest['files']
tree = hashlib.sha256(''.join(r['path'] + '\0' + r['sha256'] + '\n' for r in files).encode()).hexdigest()
check('aggregate source identity', tree == manifest['source_tree_sha256'])
check('all frozen source bytes', all(sha(root / r['path']) == r['sha256'] for r in files))
check('complete source inventory', {r['path'] for r in files} == {
    'build.zig', *[p.relative_to(root).as_posix() for p in (root / 'src').rglob('*.zig')]})
identity = read(prefix + '-identity.json')
check('run identity scope', identity['source_tree_sha256'] == tree and identity['production_qualification'] is False and
      identity['capacity_stress_qualification'] == 'deferred' and identity['max_fixture_live_across_shards'] == 100 and
      identity['max_fixture_terminal_across_shards'] == 100)
check('exact evidence scripts', all(sha(out / name) == digest for name, digest in identity['scripts'].items()))
names = ['full-releasesafe-build', 'full-releasesafe', 'full-debug-build', 'full-debug',
         'app-build', 'cli-build', 'app-offline-fixture', 'app-windows-chain-test',
         'cli-offline-fixture', 'cli-windows-chain-test', 'functional-sample-build', 'functional-sample']
steps = {}
logs = {}
for name in names:
    stem = prefix + '-' + name
    result = read(stem + '.result.json')
    steps[name] = result
    check(name + ' exit0 frozen source no drift', result['exit_code'] == 0 and
          result['source_tree_sha256'] == tree and result['files'] == files and result['source_mismatches_after'] == 0)
    check(name + ' native log identities', result['capture'] == 'native direct file handles' and
          sha(out / (stem + '.log')) == result['log_sha256'] and sha(out / (stem + '.stdout.log')) == result['stdout_sha256'])
    check(name + ' memory sample identity', sha(out / (stem + '.memory.jsonl')) == result['memory']['samples_sha256'])
    logs[name] = (out / (stem + '.log')).read_text(encoding='utf-8-sig')
for previous, following in zip(names, names[1:]):
    check(previous + ' before ' + following, steps[previous]['finished_utc'] <= steps[following]['started_utc'])
counts = []
for mode in ('releasesafe', 'debug'):
    command = steps['full-' + mode + '-build']['command']
    text = logs['full-' + mode]
    check(mode + ' full main tests without filters', 'src/main.zig' in command and 'test' in command and
          '--test-no-exec' in command and not any('--test-filter' in arg for arg in command))
    terminals = re.findall(r'All (\d+) tests passed\.', text)
    check(mode + ' one actual complete test terminal', len(terminals) == 1 and int(terminals[0]) > 602)
    counts.append(int(terminals[0]))
    check(mode + ' final native test reached', f'{terminals[0]}/{terminals[0]} ' in text)
    for token in ('09 coordinator summary count domain', '09 coordinator widened summary',
                  '09 recovery order evidence count', '09 canonical stream and deferred',
                  'Continuous capacity four shards', '09 four actual Owners'):
        check(mode + ' executed ' + token, token in text)
    samples = re.findall(r'continuous seed=0x20261008 round=(\d+) shard=(\d+) live=(\d+) terminal=(\d+)', text)
    check(mode + ' ten four-shard native windows', len(samples) == 40 and
          {(int(r), int(s)) for r, s, _, _ in samples} == {(r, s) for r in range(1, 11) for s in range(4)})
    for round_number in range(1, 11):
        group = [row for row in samples if int(row[0]) == round_number]
        check(mode + f' round {round_number} four-shard current order bounds',
              sum(int(row[2]) for row in group) <= 100 and sum(int(row[3]) for row in group) <= 100)
    check(mode + ' real four Owner shared ceiling', 'owners=4 live=4 terminal=0 sdk_sends=0' in text)
    check(mode + ' three actual synthetic classes', 'funding_spot_perpetual_pairs=4 cross_venue_pairs=1 independent_risk=true matched_base_quantity=true' in text and
          'observation_capacity: combinations=500 selected_live=100 owners=4' in text)
    economic = re.findall(r'continuous seed=0x20261008 round=\d+ shard=\d+ .*? ledger=(\d+) fills=(\d+)', text)
    check(mode + ' nonzero economics in all forty recovered windows', len(economic) == 40 and all(int(a) > 0 and int(b) > 0 for a, b in economic))
    backlog = re.findall(r'continuous backlog round=(\d+) shard=(\d+) live=(\d+) terminal=(\d+) batch_highwater=(\d+) deferred=(\d+)', text)
    check(mode + ' forty actual pre-archive backlog observations', len(backlog) == 40 and
          all(int(live) <= 100 and int(terminal) <= 3 and int(batch) > 0 for _, _, live, terminal, batch, _ in backlog))
check('same count in both full modes', counts[0] == counts[1])
sample = steps['functional-sample']['memory']
check('direct functional test process memory measured', sample['samples'] > 1 and sample['max_observed_peak_working_set_bytes'] > 0)
check('functional subset actually completed', re.search(r'All \d+ tests passed\.', logs['functional-sample']) is not None and
      'continuous classes selected_quotes=true' in logs['functional-sample'] and 'continuous mixed seed=' in logs['functional-sample'])
artifacts = read(prefix + '-artifacts.json')
check('artifact source identity and compiler', artifacts['source_tree_sha256'] == tree and artifacts['zig'] == '0.17.0-dev.315+5b647b792')
expected = {
    f'.scratch/core-continuous-capacity/{prefix}-full-releasesafe.exe': ('full-releasesafe', 268435456),
    f'.scratch/core-continuous-capacity/{prefix}-full-debug.exe': ('full-debug', 268435456),
    'zig-out/bin/ringwin.exe': ('app', 67108864),
    f'.scratch/core-continuous-capacity/{prefix}-cli.exe': ('cli', 268435456),
    f'.scratch/core-continuous-capacity/{prefix}-functional-sample.exe': ('functional-sample', 268435456),
}
check('exact five final artifacts', {r['path'] for r in artifacts['artifacts']} == set(expected))
for artifact in artifacts['artifacts']:
    path = root / artifact['path']
    label, reserve = expected[artifact['path']]
    check(label + ' exact artifact identity', sha(path) == artifact['sha256'] and path.stat().st_size == artifact['bytes'])
    data = path.read_bytes()
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    check(label + ' actual PE stack reservation', data[:2] == b'MZ' and data[offset:offset+4] == b'PE\0\0' and
          struct.unpack_from('<Q', data, offset + 24 + 72)[0] == reserve == artifact['pe_stack_reserve_bytes'])
    stages = [label + '-build', label] if label.startswith('full-') or label == 'functional-sample' else [label + '-build', label + '-offline-fixture', label + '-windows-chain-test']
    for stage in stages:
        check(stage + ' executed artifact identity', steps[stage]['artifact_sha256'] == artifact['sha256'])
for label in ('app', 'cli'):
    fixture = (out / (prefix + '-' + label + '-offline-fixture.stdout.log')).read_text(encoding='utf-8-sig')
    check(label + ' offline economic trajectories replayed', fixture.count('replay=equivalent') == 5 and 'recovery_checks=ok' in fixture)
    chain = (out / (prefix + '-' + label + '-windows-chain-test.stdout.log')).read_text(encoding='utf-8-sig')
    check(label + ' scoped offline qualification flags', all(token in chain for token in (
        'windows_okx_offline=passed', 'production_qualification=false', 'replay_send_capability=false',
        'read_only=not_run', 'demo_live=not_run', 'linux_admission_equivalent=false', 'power_loss_qualified=false')))
report = {'source_tree_sha256': tree, 'counts': dict(zip(('ReleaseSafe', 'Debug'), counts)),
          'checks': checks, 'passed': True, 'scope': 'small functional acceptance only; capacity, stress, RSS/index budgets and platform performance deferred'}
(out / (prefix + '-acceptance-audit.json')).write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(f'{len(checks)} checks passed; Debug/ReleaseSafe {counts[0]} each; no production qualification')
