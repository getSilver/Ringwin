"""Audit frozen native evidence; never changes qualification or task status."""
from pathlib import Path
import importlib.util
import json
import re
import sys

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
prefix = sys.argv[1] if len(sys.argv) > 1 else '10-final-v1'
assert prefix and all(c.isalnum() or c in '-_' for c in prefix)


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


capture = module('capture', OUT / 'run-10-command.py')
protocol = module('protocol', OUT / 'run-10-file-processes.py')
checks = []


def require(condition, label):
    if not condition:
        raise AssertionError(label)
    checks.append(label)


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


manifest = read(OUT / (prefix + '-source-manifest.json'))
require(capture.source_manifest() == manifest, 'current source matches frozen source')
identity = read(OUT / (prefix + '-identity.json'))
require(identity['source_tree_sha256'] == manifest['source_tree_sha256'], 'identity source')
require(identity['production_qualification'] is False, 'production qualification remains false')
require(capture.sha(OUT / '10-windows-host.json') == identity['host_metadata_sha256'], 'native host metadata hash')
for field, symbol in (('journal', 'journal_schema_version'), ('state', 'state_schema_version'),
                      ('registry', 'schema_registry_identity')):
    code = (ROOT / 'src/production_contract.zig').read_text()
    actual = re.search(r'pub const ' + symbol + r'\s*:\s*\w+\s*=\s*(\d+)', code)
    require(actual is not None and int(actual.group(1)) == identity['schema_identity'][field], 'current schema ' + field)
for name, digest in identity['scripts'].items():
    require(capture.sha(OUT / name) == digest, 'frozen producer ' + name)

labels = ['full-releasesafe-build', 'full-releasesafe', 'full-debug-build', 'full-debug',
          'app-build', 'cli-build', 'app-offline-fixture', 'app-windows-chain-test',
          'cli-offline-fixture', 'cli-windows-chain-test', 'app-file-processes', 'cli-file-processes']
for label in labels:
    stem = OUT / (prefix + '-' + label)
    result = read(stem.with_suffix('.result.json'))
    require(result['exit_code'] == 0 and not result['timed_out'] and result['capture_error'] is None,
            label + ' successful terminal result')
    require(result['source_tree_sha256'] == manifest['source_tree_sha256'] and result['files'] == manifest['files']
            and result['source_mismatches_after'] == 0, label + ' source identity')
    require(result['producer_mismatches_after'] == 0, label + ' producer stable')
    require(capture.sha(stem.with_suffix('.log')) == result['log_sha256'], label + ' stderr hash')
    require(capture.sha(stem.with_suffix('.stdout.log')) == result['stdout_sha256'], label + ' stdout hash')
    require(capture.sha(stem.with_suffix('.memory.jsonl')) == result['memory']['samples_sha256'], label + ' memory hash')
    if not label.endswith('-build'):
        require(result['artifact_sha256'] == result['artifact_sha256_before_launch'], label + ' artifact bound before/after')

counts = []
for mode in ('releasesafe', 'debug'):
    log = (OUT / (prefix + '-full-' + mode + '.log')).read_text(encoding='utf-8')
    passed = re.search(r'All (\d+) tests passed\.', log)
    require(passed is not None, mode + ' complete suite terminal success')
    counts.append(int(passed.group(1)))
    for name in ('Windows capacity real file seed recovery preserves public business state',
                 'Windows observation file 500 distinct combinations recover three actual synthetic categories',
                 'order history file virgin absence keeps admission open but missing published objects closes it',
                 'Continuous mixed lifecycle two leg entry close hedge and selected quotes preserve economics through recovery'):
        require(name in log, mode + ' required seam ' + name)
    for marker, count in [('windows_capacity_fault injection=', 9),
                          ('windows_capacity_reject injection=', 6),
                          ('windows_capacity_gateway_fault injection=', 3)]:
        require(log.count(marker) == count, mode + ' fault cases ' + marker)
require(counts[0] == counts[1] and counts[0] > 616, 'same expanded full suite count')

artifacts = read(OUT / (prefix + '-artifacts.json'))
require(artifacts['source_tree_sha256'] == manifest['source_tree_sha256'], 'artifact source')
require(len(artifacts['artifacts']) == 4, 'four compiled artifacts')
for artifact in artifacts['artifacts']:
    path = ROOT / artifact['path']
    require(capture.sha(path) == artifact['sha256'], 'artifact hash ' + artifact['path'])
    build_label = ('app-build' if artifact['path'] == 'zig-out/bin/ringwin.exe' else
                   'cli-build' if artifact['path'].endswith('-cli.exe') else
                   'full-debug-build' if artifact['path'].endswith('-full-debug.exe') else 'full-releasesafe-build')
    build = read(OUT / (prefix + '-' + build_label + '.result.json'))
    require(build['artifact_sha256'] == artifact['sha256'], 'sealed artifact equals frozen build ' + artifact['path'])
    expected_stack = 64 * 1024 * 1024 if artifact['path'] == 'zig-out/bin/ringwin.exe' else 256 * 1024 * 1024
    require(artifact['pe_stack_reserve_bytes'] == expected_stack, 'unchanged stack reserve ' + artifact['path'])

for kind in ('app', 'cli'):
    directory = OUT / (prefix + '-' + kind + '-processes')
    summary = read(directory / 'summary.json')
    require(summary['state'] == 'process_recovery_passed_faults_separate' and summary['rounds'] == 10,
            kind + ' ten file archive rounds')
    require(summary['steps'] == 30, kind + ' thirty fresh processes')
    producer = read(directory / 'identity.json')
    require(producer['source_tree_sha256'] == manifest['source_tree_sha256'], kind + ' process source')
    require(producer['production_qualification'] is False and producer['power_loss_qualification'] is False,
            kind + ' qualification stays false')
    rows = read(directory / 'reports.json')
    require(len(rows) == 11, kind + ' seed plus ten rounds')
    prior = None
    for round_number, row in enumerate(rows):
        original = row['seed' if round_number == 0 else 'advance']
        protocol.validate(original, 'seed' if round_number == 0 else 'advance', round_number)
        protocol.validate(row['recover'], 'recover', round_number)
        protocol.same_authority(original, row['recover'])
        if prior is not None:
            protocol.advanced_once(prior, original)
        prior = original
        require(True, kind + ' complete recovered authority round ' + str(round_number))
    observations = read(directory / 'observation-reports.json')
    for mode in ('seed', 'recover'):
        protocol.validate_observation(observations[mode], mode)
    protocol.same_authority(observations['seed'], observations['recover'])
    require(True, kind + ' actual four-route 500-identity category recovery')
    workload = read(directory / 'workload.json')
    mapping = workload['observation_fixture']['identities']
    require(len(mapping) == 500 and len({r['instrument'] for r in mapping}) == 500,
            kind + ' complete unique observation mapping retained')
    pids = set()
    final_inventory = {}
    for result_path in sorted(directory.glob('*.result.json')):
        record = read(result_path)
        pids.add((record['pid'], record['started_utc']))
        require(record['source_tree_sha256'] == manifest['source_tree_sha256'], kind + ' child source ' + record['label'])
        require(record['artifact_sha256'] == producer['artifact_sha256'], kind + ' child artifact ' + record['label'])
        require(not record['timed_out'], kind + ' child deadline ' + record['label'])
        stem = result_path.with_name(result_path.name.removesuffix('.result.json'))
        for stream in ('stdout', 'stderr'):
            require(capture.sha(stem.with_suffix('.' + stream + '.log')) == record[stream + '_sha256'],
                    kind + ' child log hash ' + record['label'] + ' ' + stream)
        if record['intentional_process_interruption']:
            require(record['exit_code'] != 0, kind + ' real child interruption ' + record['label'])
            require(record['kill_marker'].encode() in stem.with_suffix('.stderr.log').read_bytes().splitlines(),
                    kind + ' exact durable phase marker ' + record['label'])
        else:
            require(record['exit_code'] == 0, kind + ' child succeeded ' + record['label'])
        if record['mode'] == 'recover':
            require(record['files_before'] == record['files_after'], kind + ' byte-identical physical recovery ' + record['label'])
        if record['label'] in ('recover-10', 'step-golden-recover', 'hold-before-step-recover',
                               'hold-after-step-recover', 'observation-recover'):
            final_inventory[record['command'][-1]] = record['files_after']
    require(len(pids) == 30, kind + ' thirty fresh owned child process identities')
    for path, expected in final_inventory.items():
        require(protocol.inventory(Path(path)) == expected, kind + ' retained physical dataset ' + path)
    faults = [json.loads(line) for line in (directory / 'faults.jsonl').read_text().splitlines()]
    require(sum(row['result'] == 'passed' for row in faults) == 2, kind + ' two interruption authorities')
    require(any(row['case'] == 'launcher-artifact-sha-mismatch' and row['result'] == 'rejected_before_launch'
                and not row['child_launched'] and not row['dataset_changed'] for row in faults), kind + ' artifact mismatch fails before launch')

result = {'state': 'passed', 'checks': len(checks), 'full_suite_tests_per_mode': counts[0],
          'source_tree_sha256': manifest['source_tree_sha256'], 'production_qualification': False,
          'power_loss_qualification': False, 'checks_passed': checks}
(OUT / (prefix + '-audit.json')).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print('PASS', len(checks), 'checks;', counts[0], 'tests per full mode')
