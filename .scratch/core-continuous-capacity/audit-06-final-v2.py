from pathlib import Path
import datetime
import hashlib
import json
import struct

root = Path.cwd()
out = root / '.scratch/core-continuous-capacity'
prefix = '06-final-v2'
manifest = json.loads((out / (prefix + '-source-manifest.json')).read_text(encoding='utf-8-sig'))
checks = []


def check(name, ok):
    checks.append({'check': name, 'passed': bool(ok)})
    if not ok:
        raise RuntimeError(name)


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


check('all 91 frozen source file hashes', len(manifest['files']) == 91 and all(
    sha(root / row['path']) == row['sha256'] for row in manifest['files']))
names = [
    'four-shard-rs-build', 'four-shard-rs', 'full-releasesafe-build',
    'full-releasesafe', 'full-debug-build', 'full-debug', 'app-build', 'cli-build',
    'app-offline-fixture', 'app-windows-chain-test', 'cli-offline-fixture',
    'cli-windows-chain-test',
]
steps = {}
for name in names:
    stem = prefix + '-' + name
    record = json.loads((out / (stem + '.result.json')).read_text(encoding='utf-8-sig'))
    steps[name] = record
    check(stem + ' exit0 same source no drift', record['exit_code'] == 0 and
          record['source_tree_sha256'] == manifest['source_tree_sha256'] and
          record['source_mismatches_after'] == 0)
    check(stem + ' exact captured log hashes',
          sha(out / (stem + '.log')) == record['log_sha256'] and
          sha(out / (stem + '.stdout.log')) == record['stdout_sha256'])
for mode in ['releasesafe', 'debug']:
    log = (out / (prefix + '-full-' + mode + '.log')).read_text(encoding='utf-8-sig')
    check(mode + ' full terminal 551/551',
          '551/551 ' in log and 'All 551 tests passed.' in log)
check('full modes serial', steps['full-releasesafe']['finished_utc'] <= steps['full-debug']['started_utc'])
identity = json.loads((out / (prefix + '-artifacts.json')).read_text(encoding='utf-8-sig'))
check('artifact manifest same source', identity['source_tree_sha256'] == manifest['source_tree_sha256'])
for item in identity['artifacts']:
    path = root / item['path']
    check(item['path'] + ' artifact hash', sha(path) == item['sha256'])
    with path.open('rb') as file:
        file.seek(0x3c)
        offset = struct.unpack('<I', file.read(4))[0]
        file.seek(offset + 24)
        magic = struct.unpack('<H', file.read(2))[0]
        check(item['path'] + ' PE header type', magic in (0x20b, 0x10b))
        file.seek(offset + 24 + 72)
        reserve = struct.unpack('<Q' if magic == 0x20b else '<I', file.read(8 if magic == 0x20b else 4))[0]
    check(item['path'] + ' PE stack metadata', reserve == item['pe_stack_reserve_bytes'])
    if item['path'] == 'zig-out/bin/ringwin.exe':
        check('application stack remains64MiB', reserve == 67108864)
for label in ['app', 'cli']:
    text = (out / (prefix + '-' + label + '-offline-fixture.stdout.log')).read_text(encoding='utf-8-sig')
    check(label + ' five trajectories with recovery',
          'recovery_checks=ok' in text and text.count('replay=equivalent') == 5)
    text = (out / (prefix + '-' + label + '-windows-chain-test.stdout.log')).read_text(encoding='utf-8-sig')
    check(label + ' offline chain and no new qualification',
          'windows_okx_offline=passed' in text and 'replay_send_capability=false' in text and
          'production_qualification=false' in text and 'demo_live=not_run' in text)
report = {
    'recorded_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'source_tree_sha256': manifest['source_tree_sha256'],
    'steps': len(names), 'checks': checks, 'result': 'passed',
    'scope': 'ticket06 small functional acceptance only;not capacity,resource or production qualification',
}
report_path = out / (prefix + '-acceptance-audit.json')
if report_path.exists():
    previous = json.loads(report_path.read_text(encoding='utf-8-sig'))
    for field in ['source_tree_sha256', 'steps', 'checks', 'result', 'scope']:
        if previous[field] != report[field]:
            raise RuntimeError('existing audit record differs: ' + field)
else:
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('audit passed:', len(checks), 'checks;', len(names), 'captured commands;source', manifest['source_tree_sha256'])
