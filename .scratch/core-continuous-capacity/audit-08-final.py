"""Audit captured ticket08 evidence. Does not run tests or grant qualification."""
from pathlib import Path
import datetime
import hashlib
import json
import re
import struct
import sys

root = Path(__file__).resolve().parents[2]
out = root / '.scratch/core-continuous-capacity'
prefix = sys.argv[1] if len(sys.argv) > 1 else '08-final-v1'
checks = []


def read(name):
    return json.loads((out / name).read_text(encoding='utf-8-sig'))


def check(name, ok):
    checks.append({'check': name, 'passed': bool(ok)})
    if not ok:
        raise RuntimeError(name)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


manifest = read(prefix + '-source-manifest.json')
rows = manifest['files']
paths = [row['path'] for row in rows]
check('manifest unique relative paths', len(set(paths)) == len(paths) and all(
    not Path(path).is_absolute() and '..' not in Path(path).parts for path in paths))
check('manifest includes all Zig sources and build',
      {'build.zig', *[path.relative_to(root).as_posix() for path in (root / 'src').rglob('*.zig')]} <= set(paths))
check('frozen source file hashes', all(sha(root / row['path']) == row['sha256'] for row in rows))
tree = hashlib.sha256(''.join(row['path'] + '\0' + row['sha256'] + '\n' for row in rows).encode()).hexdigest()
check('manifest aggregate SHA256 recomputed', tree == manifest['source_tree_sha256'])
names = ['full-releasesafe-build', 'full-releasesafe', 'full-debug-build', 'full-debug',
         'app-build', 'cli-build', 'app-offline-fixture', 'app-windows-chain-test',
         'cli-offline-fixture', 'cli-windows-chain-test']
steps = {}
logs = {}
for name in names:
    stem = prefix + '-' + name
    record = read(stem + '.result.json')
    steps[name] = record
    check(stem + ' exit0 same source no drift', record['exit_code'] == 0 and
          record['source_tree_sha256'] == tree and record['source_mismatches_after'] == 0)
    check(stem + ' exact frozen source inventory', record['files'] == rows)
    check(stem + ' native capture', record['capture'] == 'native direct file handles')
    check(stem + ' exact captured log hashes', sha(out / (stem + '.log')) == record['log_sha256'] and
          sha(out / (stem + '.stdout.log')) == record['stdout_sha256'])
    if 'log_bytes' in record:
        check(stem + ' capture byte count', (out / (stem + '.log')).stat().st_size == record['log_bytes'])
    logs[name] = (out / (stem + '.log')).read_text(encoding='utf-8-sig')
for previous, following in zip(names, names[1:]):
    check(previous + ' precedes ' + following, steps[previous]['finished_utc'] <= steps[following]['started_utc'])
counts = {}
for mode in ('releasesafe', 'debug'):
    text = logs['full-' + mode]
    command = steps['full-' + mode + '-build']['command']
    check(mode + ' complete src/main build without test filter',
          'test' in command and 'src/main.zig' in command and
          ('ReleaseSafe' if mode == 'releasesafe' else 'Debug') in command and
          '--test-no-exec' in command and '--stack' in command and '268435456' in command and
          not any('--test-filter' in argument for argument in command))
    terminals = re.findall(r'All (\d+) tests passed\.', text)
    count = int(terminals[0]) if len(terminals) == 1 else 0
    counts[mode] = count
    check(mode + ' actual full native terminal', count > 0 and re.search(rf'{count}/{count}\s', text) is not None)
    check(mode + ' ticket08 tests actually executed',
          all(name in text for name in ['Owner control history crosses command gate latch and strategy fence bounds',
              '08 four shared account Owners preserve 320 forced sources',
              '08 shared gateway retires', '08 forced closure rejects']))
    for family in ('control commands round', 'control pause/resume round',
                   'control gates/latches round', 'control fences round',
                   'forced history window', 'gateway history window'):
        windows = [int(value) for value in re.findall(re.escape(family) + r' (\d+)', text)]
        check(mode + ' ten actual ' + family + ' windows', windows == list(range(10)))
check('same actual test count across modes', counts['debug'] == counts['releasesafe'])
identity = read(prefix + '-artifacts.json')
check('artifact manifest same source', identity['source_tree_sha256'] == tree)
if 'zig' in identity:
    check('artifact pinned Zig', identity['zig'] == '0.17.0-dev.315+5b647b792')
expected = {
    '.scratch/core-continuous-capacity/' + prefix + '-full-releasesafe.exe': ('full-releasesafe', 268435456),
    '.scratch/core-continuous-capacity/' + prefix + '-full-debug.exe': ('full-debug', 268435456),
    'zig-out/bin/ringwin.exe': ('app', 67108864),
    '.scratch/core-continuous-capacity/' + prefix + '-cli.exe': ('cli', 268435456),
}
check('exact four final artifacts', {row['path'] for row in identity['artifacts']} == set(expected))
for item in identity['artifacts']:
    path = root / item['path']
    label, expected_stack = expected[item['path']]
    check(item['path'] + ' artifact bytes and hash', sha(path) == item['sha256'] and path.stat().st_size == item['bytes'])
    with path.open('rb') as stream:
        check(item['path'] + ' DOS signature', stream.read(2) == b'MZ')
        stream.seek(0x3c)
        offset = struct.unpack('<I', stream.read(4))[0]
        stream.seek(offset)
        check(item['path'] + ' PE signature', stream.read(4) == b'PE\0\0')
        stream.seek(offset + 24)
        magic = struct.unpack('<H', stream.read(2))[0]
        check(item['path'] + ' PE type', magic in (0x20b, 0x10b))
        stream.seek(offset + 24 + 72)
        reserve = struct.unpack('<Q' if magic == 0x20b else '<I', stream.read(8 if magic == 0x20b else 4))[0]
    check(item['path'] + ' original stack contract', reserve == item['pe_stack_reserve_bytes'] == expected_stack)
    bound_steps = [label, label + '-build'] if label.startswith('full-') else [label + '-build', label + '-offline-fixture', label + '-windows-chain-test']
    for name in bound_steps:
        check(name + ' executed exact artifact', steps[name]['artifact_sha256'] == item['sha256'])
for label in ('app', 'cli'):
    text = (out / (prefix + '-' + label + '-offline-fixture.stdout.log')).read_text(encoding='utf-8-sig')
    check(label + ' five recovered trajectories', 'recovery_checks=ok' in text and text.count('replay=equivalent') == 5)
    text = (out / (prefix + '-' + label + '-windows-chain-test.stdout.log')).read_text(encoding='utf-8-sig')
    check(label + ' Windows offline output qualifications stay false', all(token in text for token in (
        'windows_okx_offline=passed', 'replay_send_capability=false', 'production_qualification=false',
        'read_only=not_run', 'demo_live=not_run', 'power_loss_qualified=false', 'linux_admission_equivalent=false')))
review = read(prefix + '-fixture-source-review.json')
check('fixture source review finalized at frozen identity', review['status'] == 'reviewed' and review['source_tree_sha256'] == tree)
check('fixture source inventory matches frozen source', review['source_inventory'] == rows)
check('fixture review covers all test-bearing Zig files', set(review['test_files']) == {
    path.relative_to(root).as_posix() for path in (root / 'src').rglob('*.zig')
    if re.search(r'^test\s', path.read_text(encoding='utf-8-sig'), re.M)})
for fixture in review['fixtures']:
    check(fixture['name'] + ' source bounds live and retained terminal <=100',
          0 <= fixture['max_live_across_shards'] <= 100 and 0 <= fixture['max_terminal_across_shards'] <= 100 and
          bool(fixture['evidence']) and sha(root / fixture['path']) == fixture['sha256'])
check('full fixture review conclusion', review['all_test_fixtures_within_limit'] is True)
for mode in ('releasesafe', 'debug'):
    text = logs['full-' + mode]
    check(mode + ' Windows native observation workload <=100',
          'observation_capacity: combinations=500 selected_live=100 owners=4' in text)
    workload_cases = [
        ('OMS functional', 'retained', 'order_capacity_acceptance.test.OMS functional archive four shards retain 25 live and 25 terminal then complete ten rounds'),
        ('Owner capacity', 'terminal', 'order_public_capacity_acceptance.test.Owner public archive four shards retain 25 live and 25 terminal through ten replacement rounds'),
    ]
    for family, terminal_key, case in workload_cases:
        sections = re.findall(r'^\d+/\d+ ' + re.escape(case) + r'\.\.\.(.*?)(?=^\d+/\d+ |\Z)', text, re.M | re.S)
        check(mode + ' exact ' + family + ' four-shard test section', len(sections) == 1)
        entries = re.findall(rf'{family} shard (\d+): live=(\d+), {terminal_key}=(\d+)', sections[0])
        check(mode + ' ' + family + ' four-shard native bounds', len(entries) == 4 and
              {int(row[0]) for row in entries} == {0, 1, 2, 3} and
              all(int(row[1]) == 25 and int(row[2]) == 25 for row in entries) and
              sum(int(row[1]) for row in entries) == 100 and sum(int(row[2]) for row in entries) == 100)
report = {'recorded_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'source_tree_sha256': tree, 'steps': len(names), 'native_test_counts': counts,
          'checks': checks, 'result': 'passed',
          'scope': 'ticket08 small functional acceptance only; not capacity, resource, Venue or production qualification'}
destination = out / (prefix + '-acceptance-audit.json')
if destination.exists():
    previous = read(destination.name)
    if not all(previous[key] == report[key] for key in (
        'source_tree_sha256', 'steps', 'native_test_counts', 'checks', 'result', 'scope')):
        raise RuntimeError('existing audit differs')
else:
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('audit passed:', len(checks), 'checks;', counts, '; source', tree)
