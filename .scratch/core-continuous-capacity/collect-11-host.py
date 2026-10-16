"""Read-only Linux host metadata plus a new, three-byte file semantics probe."""
from pathlib import Path
import datetime
import errno
import hashlib
import json
import os
import platform
import resource
import subprocess
import sys

out = Path(__file__).resolve().parent
if sys.platform != 'linux':
    raise RuntimeError('Linux required')
target = Path(sys.argv[1]).resolve()
target.mkdir(parents=True, exist_ok=False)
probe = []
for generation, payload in enumerate((b'old', b'new')):
    temp = target / 'probe.tmp'
    published = target / 'probe'
    with temp.open('wb') as stream:
        stream.write(payload)
        os.fsync(stream.fileno())
    os.replace(str(temp), str(published))
    fd = os.open(str(target), os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            os.fsync(fd)
            directory_sync = {'result': 'success'}
        except OSError as error:
            directory_sync = {'result': 'failed', 'errno': error.errno, 'error': str(error)}
    finally:
        os.close(fd)
    assert published.read_bytes() == payload
    probe.append({'generation': generation, 'file_sync': 'passed', 'same_fs_replace': 'passed',
                  'reopen': 'passed', 'directory_sync': directory_sync,
                  'allocated_bytes_reported': published.stat().st_blocks * 512})
record = {'recorded_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'os_release': Path('/etc/os-release').read_text(), 'uname': list(os.uname()),
          'uid': os.getuid(), 'gid': os.getgid(), 'python': sys.version,
          'mounts': Path('/proc/mounts').read_text(),
          'cpuinfo': Path('/proc/cpuinfo').read_text(), 'meminfo': Path('/proc/meminfo').read_text(),
          'df': subprocess.check_output(['df', '-T', str(target)], universal_newlines=True),
          'stack_rlimit_bytes': list(resource.getrlimit(resource.RLIMIT_STACK)),
          'probe_directory': str(target), 'probe': probe,
          'wsl': 'Microsoft' in platform.release(),
          'verification_scope': 'WSL1/lxfs development file functionality; not target Linux qualification',
          'directory_durability_qualified': False, 'power_loss_qualification': False,
          'production_qualification': False,
          'allocation_caveat': 'WSL1 stat.st_blocks may be zero; do not claim allocated-size measurement',
          'peak_memory_caveat': 'WSL1 VmHWM may be zero; retain unavailable and report sampled RSS separately'}
path = out / '11-linux-host.json'
if path.exists():
    raise FileExistsError('Existing host record retained')
path.write_text(json.dumps(record, indent=2) + '\n')
print(record['df'], json.dumps(probe), flush=True)
