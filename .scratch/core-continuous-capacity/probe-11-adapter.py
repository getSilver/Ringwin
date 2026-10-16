"""Trace the real offline FileAdapter to verify directory fsync, not only a Python probe."""
from pathlib import Path
import datetime
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import sys

OUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('base', OUT / 'run-07-command.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
artifact, evidence = map(Path, sys.argv[1:3])
if sys.platform != 'linux' or not evidence.is_absolute():
    raise ValueError('Linux and an absolute new evidence directory required')
evidence.mkdir(exist_ok=False)
before = base.source_manifest()
artifact_sha = base.sha(artifact)
command = ['strace', '-f', '-yy', '-e', 'trace=fsync,sync,rename,renameat,renameat2',
           '-o', str(evidence / 'syscalls.log'), str(artifact), '--linux-capacity-file', 'seed', str(evidence / 'store')]
with (evidence / 'stdout.log').open('wb') as output, (evidence / 'stderr.log').open('wb') as error:
    result = subprocess.run(command, stdout=output, stderr=error, timeout=300)
text = (evidence / 'syscalls.log').read_text()
directories = [str(evidence / 'store' / ('shard-' + str(i))) for i in range(4)] + [str(evidence / 'store' / 'coordination')]
counts = {directory: len(re.findall(r'fsync\(\d+<' + re.escape(directory) + r'>\)\s+= 0', text)) for directory in directories}
failures = [line for line in text.splitlines() if ' = -1 ' in line]
fallback_count = len(re.findall(r'\bsync\(', text))
record = {'command': command, 'exit_code': result.returncode, 'source_tree_sha256': before['source_tree_sha256'],
          'artifact_sha256': artifact_sha, 'directory_fsync_successes': counts,
          'failed_syscalls': failures, 'global_sync_fallbacks': fallback_count,
          'source_unchanged': before == base.source_manifest(), 'artifact_unchanged': artifact_sha == base.sha(artifact),
          'scope': 'actual offline adapter syscalls on WSL1/lxfs; not power-loss or target durability',
          'power_loss_qualification': False, 'production_qualification': False,
          'logs': {name: base.sha(evidence / name) for name in ('syscalls.log', 'stdout.log', 'stderr.log')}}
record['passed'] = result.returncode == 0 and all(counts.values()) and not failures and fallback_count == 0 and record['source_unchanged'] and record['artifact_unchanged']
(evidence / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
assert record['passed'], 'Adapter fsync probe failed; all raw evidence retained'
print(json.dumps({'passed': record['passed'], 'directory_fsync_successes': counts, 'global_sync_fallbacks': fallback_count}), flush=True)
if len(sys.argv) > 3:
    export = Path(sys.argv[3])
    export.mkdir(exist_ok=False)
    for path in evidence.iterdir():
        if path.is_file():
            shutil.copyfile(str(path), str(export / path.name))
