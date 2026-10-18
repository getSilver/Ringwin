from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
ZIG = 'D:/Program Files/zig/zig.exe'
records = []
for mode in ('ReleaseSafe', 'ReleaseFast'):
    command = [ZIG, 'test', '-O', mode, '--cache-dir', '.zig-cache/credential-review-probe-' + mode,
               '--test-filter', 'review', '--dep', 'credentials',
               '-Mroot=' + (OUT / 'probe.zig').relative_to(ROOT).as_posix(),
               '-Mcredentials=src/credential_store.zig']
    result = subprocess.run(command, cwd=ROOT, capture_output=True)
    log = OUT / (mode + '.log')
    log.write_bytes(result.stdout + result.stderr)
    records.append({'mode': mode, 'command': command, 'exit_code': result.returncode,
                    'log': log.name, 'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
    print(mode, 'exit', result.returncode, flush=True)
    if result.returncode:
        print(result.stderr.decode(errors='replace'), flush=True)
        break
report = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(),
          'synthetic_credentials_only': True, 'network_requests': 0,
          'probe_sha256': hashlib.sha256((OUT / 'probe.zig').read_bytes()).hexdigest(),
          'runs': records}
(OUT / 'validation.json').write_bytes((json.dumps(report, indent=2) + '\n').encode())
assert len(records) == 2 and all(row['exit_code'] == 0 for row in records)
