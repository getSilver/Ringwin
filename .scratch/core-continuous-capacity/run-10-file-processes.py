"""Bounded native Windows FileAdapter scenario using fresh executable processes.

Only creates a new task directory. Never cleans, deletes, or writes another dataset.
The executable remains the repo application, not a separate control plane.
"""
from pathlib import Path
from ctypes import wintypes
import argparse
import ctypes
import datetime
import hashlib
import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('capture', OUT / 'run-10-command.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class FileStandardInfo(ctypes.Structure):
    _fields_ = [('AllocationSize', ctypes.c_longlong), ('EndOfFile', ctypes.c_longlong),
                ('NumberOfLinks', wintypes.DWORD), ('DeletePending', ctypes.c_ubyte), ('Directory', ctypes.c_ubyte)]


def allocated_size(path):
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                                  wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.GetFileInformationByHandleEx.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel.GetFileInformationByHandleEx.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.CreateFileW(str(path), 0, 7, None, 3, 0, None)
    if handle == ctypes.c_void_p(-1).value:
        return {'allocated_bytes': None, 'win32_error': ctypes.get_last_error()}
    try:
        data = FileStandardInfo()
        if not kernel.GetFileInformationByHandleEx(handle, 1, ctypes.byref(data), ctypes.sizeof(data)):
            return {'allocated_bytes': None, 'win32_error': ctypes.get_last_error()}
        return {'allocated_bytes': data.AllocationSize, 'logical_bytes': data.EndOfFile}
    finally:
        kernel.CloseHandle(handle)


def inventory(directory):
    result = []
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise RuntimeError('Dataset unexpectedly contains a symlink: ' + str(path))
        if path.is_file():
            result.append({'path': path.relative_to(directory).as_posix(), 'bytes': path.stat().st_size,
                           'sha256': sha(path), **allocated_size(path)})
    return result


def verify_artifact(path, expected):
    actual = sha(path)
    if actual != expected:
        raise RuntimeError('ArtifactIdentityMismatch: process was not launched')


def validate(report, mode, round_number):
    assert report['schema'] == 2 and report['mode'] == mode
    assert report['seed'] == 0x20261008 and report['round'] == round_number
    assert report['synthetic_fencing'] is True and report['production_qualification'] is False
    assert len(report['shards']) == 4
    assert sum(s['live'] for s in report['shards']) <= 100
    assert sum(s['terminal'] for s in report['shards']) <= 100
    assert report['recovery_send_count'] == 0
    if mode == 'recover':
        assert report['send_count'] == 0
    for index, shard in enumerate(report['shards']):
        assert shard['shard'] == index
        assert shard['round'] == (0 if index == 3 else round_number)
        assert shard['quantity'] == 2 and shard['inventory_atoms'] == 2
        assert shard['fee_atoms'] == (6 if index == 3 else 1) and shard['reservation_atoms'] > 0
        assert shard['account'] == 2 and shard['portfolio'] == 11 + index
        assert shard['decision_domain'] == index + 1
        assert shard['decision_stream_id'] == 100 + 10 * index
        assert shard['dispatch_stream_id'] == 101 + 10 * index
        assert shard['raw_stream_id'] == 102 + 10 * index
        assert shard['terminal'] == (3 if index == 3 else 0)
        assert shard['recovery_sends'] == 0 and shard['adapter_queue'] == 0
        assert shard['ledger_count'] > 0 and shard['ingress_count'] > 0
        assert shard['ledger_debits_atoms'] + shard['ledger_credits_atoms'] > 0
        for key in ('digest', 'economic_digest', 'ledger_digest'):
            value = shard[key]
            assert len(value) == 64 and int(value, 16) != 0
        assert len(shard['history_root']) == 64
        assert (int(shard['history_root'], 16) == 0) == (index == 3 or round_number == 0)
        if index == 3:
            assert shard['unknown'] == 1 and shard['unknown_orders'] == 1
            assert shard['partially_filled'] == 3 and shard['pending_cancel'] == 1
            assert shard['resting'] == 1 and shard['filled'] == 3
            assert shard['two_leg_entry_orders'] == 2 and shard['two_leg_closed_lots'] == 6
            assert shard['hedge_lots'] == 2 and shard['instrument4_quantity'] == 0
    shared = report['shared_account']
    assert shared['exchange_account'] == 2 and shared['ceiling_rejected'] is True
    assert shared['gross_reservation_atoms'] == sum(s['reservation_atoms'] for s in report['shards'])
    assert shared['denied_ceiling_atoms'] == shared['gross_reservation_atoms'] - 1
    assert shared['account_ceiling_atoms'] >= shared['gross_reservation_atoms']
    assert len(shared['owners']) == 4 and len(shared['ownership_digest']) == 64
    for index, owner in enumerate(shared['owners']):
        assert owner['shard'] == index and owner['portfolio'] == 11 + index and owner['account'] == 2
        assert owner['decision_domain'] == index + 1
        assert owner['reservation_atoms'] == report['shards'][index]['reservation_atoms']
        assert owner['lease_used_atoms'] == owner['reservation_atoms']
        assert owner['lease_limit_atoms'] >= owner['lease_used_atoms']


def same_authority(before, after):
    # Process-local timing/counters are observations, not recovered authority.
    transient = {'recovery_ns', 'sends', 'recovery_sends'}
    if 'shared_account' in before or 'shared_account' in after:
        assert before['shared_account'] == after['shared_account'], 'Recovered coordinator differs'
    assert len(before['shards']) == len(after['shards'])
    for left, right in zip(before['shards'], after['shards']):
        assert {k: v for k, v in left.items() if k not in transient} == {
            k: v for k, v in right.items() if k not in transient}, 'Recovered authority differs'


def advanced_once(before, after):
    assert after['send_count'] == 6
    assert len(before['shards']) == len(after['shards'])
    for index, (left, right) in enumerate(zip(before['shards'], after['shards'])):
        if index == 3:
            same_authority({'shards': [left]}, {'shards': [right]})
            continue
        assert right['barrier'] > left['barrier']
        assert right['next_order'] == left['next_order'] + 1
        assert right['next_command'] == left['next_command'] + 2
        assert right['history_generation'] > left['history_generation']
        assert right['digest'] != left['digest']
        assert right['economic_digest'] == left['economic_digest']


def validate_observation(report, mode):
    assert report['schema'] == 1 and report['mode'] == mode
    assert report['seed'] == 0x20261008 and report['unique_combinations'] == 500
    assert report['funding_pairs'] == 4 and report['cross_venue_pairs'] == 1
    assert report['independent_risk'] is True and report['production_qualification'] is False
    assert report['synthetic_fencing'] is True and report['recovery_send_count'] == 0
    assert len(report['shards']) == 4
    assert sum(s['live'] for s in report['shards']) <= 100
    assert sum(s['terminal'] for s in report['shards']) <= 100
    assert len({s['venue'] for s in report['shards']}) == 4
    assert len({s['account'] for s in report['shards']}) == 4
    if mode == 'recover':
        assert report['send_count'] == 0
    for index, shard in enumerate(report['shards']):
        assert shard['shard'] == index and shard['observed'] == 125
        assert shard['spot_observed'] == 75 and shard['perpetual_observed'] == 50
        assert shard['selected_live'] == 25 and shard['recovery_sends'] == 0
        assert shard['ledger_count'] > 0 and shard['fee_atoms'] >= 0
        assert shard['spot_quantity'] == 100_000 and shard['inventory_atoms'] == 99_999
        assert shard['cross_perpetual_quantity'] == (-10 if index == 1 else 10)
        assert shard['reservation_atoms'] > 0 and shard['adapter_queue'] == 0
        assert shard['funding_perpetual_quantity'] < 0
        for key in ('digest', 'economic_digest', 'ledger_digest', 'ownership_digest', 'mapping_digest'):
            assert len(shard[key]) == 64 and int(shard[key], 16) != 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--prefix', required=True)
    parser.add_argument('--smoke', action='store_true')
    args = parser.parse_args()
    if os.name != 'nt':
        raise RuntimeError('Native Windows required')
    if not args.prefix or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in args.prefix):
        raise ValueError('A simple new evidence prefix is required')
    artifact = args.artifact.resolve(strict=True)
    verify_artifact(artifact, args.expected_sha256)
    evidence = OUT / args.prefix
    if evidence.exists():
        raise FileExistsError('Existing evidence retained: ' + str(evidence))
    evidence.mkdir()
    dataset = evidence / 'store'
    dataset.mkdir()
    frozen = capture.source_manifest()
    host_path = OUT / '10-windows-host.json'
    producers = {name: sha(OUT / name) for name in
                 ('run-07-command.py', 'run-10-command.py', 'run-10-file-processes.py')}
    identity = {**frozen, 'artifact': str(artifact), 'artifact_sha256': args.expected_sha256,
                'baseline_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'host_metadata_sha256': sha(host_path), 'producer_sha256': sha(Path(__file__)),
                'producer_dependencies': producers,
                'seed': '0x20261008', 'scope': 'development smoke' if args.smoke else 'small native Windows file functionality',
                'native_platform': platform.platform(), 'production_qualification': False,
                'power_loss_qualification': False, 'capacity_stress': 'deferred', 'platform_performance': 'deferred'}
    (evidence / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n', encoding='utf-8')
    steps = []

    def run(mode, label, target=None, kill_marker=None, flag='--windows-capacity-file'):
        target = target or dataset
        verify_artifact(artifact, args.expected_sha256)
        assert all(sha(OUT / name) == digest for name, digest in producers.items()), 'Producer drift'
        assert sha(host_path) == identity['host_metadata_sha256'], 'Host metadata drift'
        if capture.source_manifest() != frozen:
            raise RuntimeError('Source drift; original evidence retained')
        before = inventory(target)
        stem = evidence / label
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        begin = time.perf_counter_ns()
        samples = []
        get_memory = ctypes.WinDLL('psapi', use_last_error=True).GetProcessMemoryInfo
        get_memory.argtypes = [wintypes.HANDLE, ctypes.POINTER(capture.ProcessMemory), wintypes.DWORD]
        get_memory.restype = wintypes.BOOL
        with stem.with_suffix('.stdout.log').open('wb') as output, stem.with_suffix('.stderr.log').open('wb') as error:
            command = [str(artifact), flag, mode, str(target)]
            process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=error)
            interrupted = False
            timed_out = False
            while True:
                memory = capture.ProcessMemory()
                memory.cb = ctypes.sizeof(memory)
                if get_memory(int(process._handle), ctypes.byref(memory), memory.cb):
                    samples.append({'elapsed_ns': time.perf_counter_ns() - begin,
                                    'working_set_bytes': memory.WorkingSetSize,
                                    'peak_working_set_bytes': memory.PeakWorkingSetSize})
                code = process.poll()
                if code is not None:
                    break
                if kill_marker and kill_marker in stem.with_suffix('.stderr.log').read_bytes().splitlines():
                    process.terminate()  # Windows TerminateProcess; only this owned child PID.
                    code = process.wait(timeout=30)
                    interrupted = True
                    break
                if time.perf_counter_ns() - begin > 300_000_000_000:
                    process.terminate()
                    code = process.wait(timeout=30)
                    timed_out = True
                    break
                time.sleep(0.1)
        after = inventory(target)
        record = {'label': label, 'mode': mode, 'command': command, 'pid': process.pid,
                  'protocol': flag,
                  'started_utc': started, 'finished_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'elapsed_ns': time.perf_counter_ns() - begin, 'exit_code': code,
                  'intentional_process_interruption': interrupted,
                  'timed_out': timed_out,
                  'kill_marker': kill_marker.decode('ascii') if kill_marker else None,
                  'stdout_sha256': sha(stem.with_suffix('.stdout.log')), 'stderr_sha256': sha(stem.with_suffix('.stderr.log')),
                  'source_tree_sha256': frozen['source_tree_sha256'], 'artifact_sha256': sha(artifact),
                  'files_before': before, 'files_after': after, 'memory_samples': samples,
                  'allocated_byte_scope': 'regular dataset files only; excludes directory/MFT/journal overhead'}
        stem.with_suffix('.result.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
        steps.append(record)
        assert all(sha(OUT / name) == digest for name, digest in producers.items()), 'Producer drift during command'
        if timed_out:
            raise TimeoutError(label + ': child timed out; result, dataset and logs retained')
        if kill_marker:
            if not interrupted or code == 0:
                raise RuntimeError(label + ': deterministic interruption was not observed')
            print(label, 'interrupted_owned_pid=' + str(process.pid), flush=True)
            return record
        if code != 0:
            raise RuntimeError(label + ' failed; original logs and dataset retained')
        report = json.loads(stem.with_suffix('.stdout.log').read_text(encoding='utf-8-sig'))
        if mode == 'recover' and before != after:
            raise RuntimeError('Recovery changed physical dataset bytes')
        if capture.source_manifest() != frozen:
            raise RuntimeError('Source drift during command')
        print(label, 'exit=0', 'pid=' + str(process.pid), flush=True)
        return report

    seeded = run('seed', 'seed')
    validate(seeded, 'seed', 0)
    assert seeded['send_count'] == 12
    recovered = run('recover', 'recover-00')
    validate(recovered, 'recover', 0)
    same_authority(seeded, recovered)
    # Each interruption starts from its own physical copy of the seed files.
    # No in-memory snapshot or parent-side state is supplied to a child process.
    golden_store = evidence / 'step-golden-store'
    shutil.copytree(dataset, golden_store)
    golden = run('step', 'step-golden', golden_store)
    validate(golden, 'step', 0)
    assert golden['send_count'] == 0
    assert golden['shards'][0]['barrier'] > seeded['shards'][0]['barrier']
    assert golden['shards'][0]['digest'] != seeded['shards'][0]['digest']
    assert golden['shards'][0]['economic_digest'] == seeded['shards'][0]['economic_digest']
    same_authority({'shards': seeded['shards'][1:]}, {'shards': golden['shards'][1:]})
    golden_recovered = run('recover', 'step-golden-recover', golden_store)
    validate(golden_recovered, 'recover', 0)
    same_authority(golden, golden_recovered)
    faults = []
    for mode, marker, expected in (
            ('hold-before-step', b'READY_BEFORE', seeded),
            ('hold-after-step', b'READY_AFTER', golden)):
        target = evidence / (mode + '-store')
        shutil.copytree(dataset, target)
        expected_marker = (marker + b' shard=0 barrier=' + str(expected['shards'][0]['barrier']).encode('ascii')
                           + b' digest=' + expected['shards'][0]['digest'].encode('ascii'))
        interrupted = run(mode, mode, target, expected_marker)
        restored = run('recover', mode + '-recover', target)
        validate(restored, 'recover', 0)
        same_authority(expected, restored)
        assert restored['send_count'] == 0 and restored['recovery_send_count'] == 0
        faults.append({'case': mode, 'result': 'passed', 'killed_pid': interrupted['pid'],
                       'expected_authority': 'old' if mode == 'hold-before-step' else 'new',
                       'recovery_send_count': restored['recovery_send_count'],
                       'old_authority': seeded['shards'], 'new_authority': golden['shards'],
                       'recovered_authority': restored['shards'],
                       'interruption_result': mode + '.result.json',
                       'recovery_result': mode + '-recover.result.json'})
    before_mismatch = inventory(dataset)
    try:
        verify_artifact(artifact, '0' * 64)
    except RuntimeError as error:
        assert str(error).startswith('ArtifactIdentityMismatch:')
        assert inventory(dataset) == before_mismatch
        faults.append({'case': 'launcher-artifact-sha-mismatch', 'result': 'rejected_before_launch',
                       'child_launched': False, 'dataset_changed': False})
    else:
        raise AssertionError('Artifact mismatch was accepted')
    for case in ('power-loss', 'in-syscall-termination', 'memory-dump-protection', 'external-NodeFence',
                 'thousand-order-capacity-stress', 'Linux-platform-qualification'):
        faults.append({'case': case, 'result': 'not_run', 'reason': 'outside authorized Windows small functional scope'})
    (evidence / 'faults.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in faults), encoding='utf-8')
    rounds = 1 if args.smoke else 10
    reports = [{'seed': seeded, 'recover': recovered}]
    previous = seeded
    for round_number in range(1, rounds + 1):
        advanced = run('advance', f'advance-{round_number:02}')
        validate(advanced, 'advance', round_number)
        advanced_once(previous, advanced)
        recovered = run('recover', f'recover-{round_number:02}')
        validate(recovered, 'recover', round_number)
        same_authority(advanced, recovered)
        reports.append({'advance': advanced, 'recover': recovered})
        previous = advanced
    (evidence / 'reports.json').write_text(json.dumps(reports, indent=2) + '\n', encoding='utf-8')
    observation_store = evidence / 'observation-store'
    observation_store.mkdir()
    observation_seed = run('seed', 'observation-seed', observation_store, flag='--windows-observation-file')
    validate_observation(observation_seed, 'seed')
    observation_recovered = run('recover', 'observation-recover', observation_store, flag='--windows-observation-file')
    validate_observation(observation_recovered, 'recover')
    same_authority(observation_seed, observation_recovered)
    (evidence / 'observation-reports.json').write_text(json.dumps(
        {'seed': observation_seed, 'recover': observation_recovered}, indent=2) + '\n', encoding='utf-8')
    workload = {'seed': '0x20261008', 'rounds': rounds, 'owner_count': 4,
                'identities': [{'owner_directory': f'shard-{i}', 'instrument': 3,
                                'product': 'spot', 'exchange_account': 2,
                                'portfolio': 11 + i, 'decision_domain': i + 1,
                                'scenario': 'two-leg open/close, independent hedge, pending cancel, accepted and Unknown' if i == 3 else 'accepted partial fill plus sequential place/cancel archive'}
                               for i in range(4)],
                'seed_sends': seeded['send_count'], 'sends_per_advance': 6,
                'scope': 'small file lifecycle plus separate 500-identity observation and strategy-category file fixture',
                'max_live_across_shards': max(sum(s['live'] for s in r['recover']['shards']) for r in reports),
                'max_retained_terminal_across_shards': max(sum(s['terminal'] for s in r['recover']['shards']) for r in reports),
                'max_transient_terminal_across_shards': 4,
                'generation': 'durable next_order and next_command; fixed arithmetic business clock; no reset',
                'configured_market_making_M_L': 'not_exercised', 'input_rate': 'unpaced small functional commands',
                'capacity_stress': 'deferred',
                'strategy_category_coverage': 'separate observation File fixture; see observation-reports.json',
                'observation_fixture': {'unique_combinations': 500, 'funding_pairs': observation_seed['funding_pairs'],
                                        'cross_venue_pairs': observation_seed['cross_venue_pairs'],
                                        'mapping': 'formula below; executable verifies every registry venue/product and mapping_digest per Owner',
                                        'identities': [
                                            {'shard': route, 'venue': venue, 'account': 100 + route,
                                             'instrument': str((venue << 64) | ((1 if index < 75 else 2) << 32) | (1000 + index % 75)),
                                             'product': 'spot' if index < 75 else 'isolated_linear_usdt',
                                             'selected': index < 9 or 75 <= index < 91}
                                            for route, venue in enumerate((1, 21, 42, 84)) for index in range(125)]}}
    (evidence / 'workload.json').write_text(json.dumps(workload, indent=2) + '\n', encoding='utf-8')
    samples = []
    for step in steps:
        row = {k: step[k] for k in ('label', 'mode', 'pid', 'elapsed_ns', 'exit_code')}
        row.update(logical_dataset_bytes=sum(f['bytes'] for f in step['files_after']),
                   allocated_regular_file_bytes=sum(f['allocated_bytes'] for f in step['files_after']
                                                    if f['allocated_bytes'] is not None),
                   working_set_peak_observed=max((s['peak_working_set_bytes'] for s in step['memory_samples']), default=None),
                   memory_sample_count=len(step['memory_samples']),
                   latency_scope='whole command including file recovery and JSON; not per-apply/commit or p99',
                   thread_stack_actual_peak='not_measured', physical_index_cost='not_measured')
        if not step['intentional_process_interruption']:
            report_path = evidence / (step['label'] + '.stdout.log')
            data = json.loads(report_path.read_text(encoding='utf-8-sig'))
            row['shards'] = [{k: s[k] for k in ('shard', 'live', 'terminal', 'adapter_queue', 'snapshot_bytes',
                                               'stored_bytes', 'stored_files', 'barrier', 'recovery_ns') if k in s}
                             for s in data['shards']]
            row['queue_scope'] = 'end-of-command resident adapter queue; transient queue high water not sampled'
        samples.append(row)
    (evidence / 'samples.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in samples), encoding='utf-8')
    (evidence / 'summary.json').write_text(json.dumps({'state': 'process_recovery_passed_faults_separate',
        'rounds': rounds, 'steps': len(steps), 'source_tree_sha256': frozen['source_tree_sha256'],
        'production_qualification': False, 'power_loss_qualification': False}, indent=2) + '\n', encoding='utf-8')
    (evidence / 'summary.md').write_text(
        '# Native Windows file process recovery\n\n'
        f'{rounds} sequential archive rounds; {len(steps)} owned child processes; '
        'all ordinary recoveries preserve physical file bytes and full reported authority.\n\n'
        'Before/after durable apply termination selects complete old/new shard-0 authority; '
        'the other three Owners are unchanged. This is not a cross-shard atomic transaction test. '
        'Artifact SHA mismatch rejects before launching a child.\n\n'
        'See identity.json, workload.json, samples.jsonl, faults.jsonl, reports.json and '
        'per-command result JSON for exact commands, PIDs, file inventories and log hashes. '
        'Deterministic storage fault and authenticated schema tests are separate Zig tests.\n\n'
        'Power loss, directory durability, resource budgets, thousand-order capacity, stress, '
        'external fencing, memory dump protection and platform production qualification remain unqualified.\n',
        encoding='utf-8')
    print('Native process recovery and authority comparison passed; fault evidence is separate', flush=True)


if __name__ == '__main__':
    main()
