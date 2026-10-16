"""Native local capture with source identity and Windows process memory observations."""
from pathlib import Path
import ctypes
from ctypes import wintypes
import datetime
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('base_capture', out / 'run-07-command.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
source_manifest = base.source_manifest
sha = base.sha


def linux_memory(pid, begin):
    try:
        fields = dict(line.split(':', 1) for line in Path('/proc/{}/status'.format(pid)).read_text().splitlines() if ':' in line)
        rss = int(fields.get('VmRSS', '0 kB').split()[0]) * 1024
        hwm = int(fields.get('VmHWM', '0 kB').split()[0]) * 1024
        return {'elapsed_ns': time.perf_counter_ns() - begin, 'working_set_bytes': rss,
                'peak_working_set_bytes': hwm or None,
                'api': '/proc/PID/status; zero VmHWM treated as unavailable'}
    except (FileNotFoundError, ProcessLookupError):
        return None


class ProcessMemory(ctypes.Structure):
    _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD)] + [
        (name, ctypes.c_size_t) for name in (
            'PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage',
            'QuotaPagedPoolUsage', 'QuotaPeakNonPagedPoolUsage', 'QuotaNonPagedPoolUsage',
            'PagefileUsage', 'PeakPagefileUsage', 'PrivateUsage')]


def capture(name, command):
    command_cwd = Path(os.environ.get('RINGWIN_CAPTURE_CWD', str(root))).resolve(strict=True)
    if not name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in name):
        raise ValueError('A simple new capture name is required')
    for suffix in ('.log', '.stdout.log', '.memory.jsonl', '.result.json'):
        if (out / (name + suffix)).exists():
            raise FileExistsError('Existing evidence retained: ' + name + suffix)
    before = source_manifest()
    producers = {p.name: sha(p) for p in (Path(__file__), out / 'run-07-command.py')}
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    begin = time.perf_counter_ns()
    observations = []
    get_memory = None
    if os.name == 'nt':
        get_memory = ctypes.WinDLL('psapi', use_last_error=True).GetProcessMemoryInfo
        get_memory.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessMemory), wintypes.DWORD]
        get_memory.restype = wintypes.BOOL
    log = out / (name + '.log')
    stdout = out / (name + '.stdout.log')
    timed_out = False
    timeout_seconds = int(os.environ.get('RINGWIN_CAPTURE_TIMEOUT_SECONDS', '10800'))
    if timeout_seconds <= 0:
        raise ValueError('Capture timeout must be positive')
    process = None
    code = 1
    capture_error = None
    try:
        with log.open('wb') as err, stdout.open('wb') as output:
            process = subprocess.Popen(command, cwd=command_cwd, stdout=output, stderr=err)
            while True:
                if get_memory:
                    memory = ProcessMemory()
                    memory.cb = ctypes.sizeof(memory)
                    if get_memory(int(process._handle), ctypes.byref(memory), memory.cb):
                        observations.append({'elapsed_ns': time.perf_counter_ns() - begin,
                                             'working_set_bytes': memory.WorkingSetSize,
                                             'peak_working_set_bytes': memory.PeakWorkingSetSize,
                                             'private_bytes': memory.PrivateUsage,
                                             'peak_pagefile_bytes': memory.PeakPagefileUsage})
                elif sys.platform == 'linux':
                    observation = linux_memory(process.pid, begin)
                    if observation:
                        observations.append(observation)
                code = process.poll()
                if code is not None:
                    break
                if time.perf_counter_ns() - begin > timeout_seconds * 1_000_000_000:
                    process.terminate()
                    code = process.wait(timeout=30)
                    timed_out = True
                    break
                time.sleep(0.1)
    except Exception as error:
        capture_error = type(error).__name__ + ': ' + str(error)
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=30)
        code = 1
    after = source_manifest()
    samples_path = out / (name + '.memory.jsonl')
    samples_path.write_text(''.join(json.dumps(row) + '\n' for row in observations), encoding='utf-8')
    record = {**before, 'command': command, 'cwd': str(command_cwd), 'started_utc': started,
              'finished_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'elapsed_ns': time.perf_counter_ns() - begin, 'exit_code': code,
              'timed_out': timed_out, 'timeout_seconds': timeout_seconds,
              'pid': process.pid if process else None, 'capture_error': capture_error,
              'producer_dependencies': producers,
              'producer_mismatches_after': sum(sha(out / name) != digest for name, digest in producers.items()),
              'log_sha256': sha(log), 'stdout_sha256': sha(stdout),
              'source_mismatches_after': len({(r['path'], r['sha256']) for r in before['files']} ^
                                             {(r['path'], r['sha256']) for r in after['files']}),
              'capture': 'native direct file handles',
              'memory': {'api': 'Windows GetProcessMemoryInfo' if get_memory else '/proc/PID/status',
                         'scope': 'direct child process only; 100ms polling; short processes may have no sample',
                         'samples': len(observations), 'samples_sha256': sha(samples_path),
                         'max_observed_rss_bytes': max((r['working_set_bytes'] for r in observations), default=None),
                         'max_observed_peak_working_set_bytes': max((r['peak_working_set_bytes'] for r in observations if r['peak_working_set_bytes'] is not None), default=None),
                         'latency_scope': 'whole command wall time; not per-input latency or throughput qualification'}}
    (out / (name + '.result.json')).write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    print(name, 'exit=' + str(code), 'source=' + before['source_tree_sha256'], flush=True)
    if code:
        print(log.read_text(encoding='utf-8', errors='replace')[-12000:])
    return code if code else (124 if timed_out or record['producer_mismatches_after'] else 0)


if __name__ == '__main__':
    name, *command = sys.argv[1:]
    sys.exit(capture(name, command))
