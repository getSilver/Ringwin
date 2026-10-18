"""Opt-in per-child memlock budget; no system/user configuration changes."""
import os
import resource
import sys

if os.geteuid() != 0:
    raise SystemExit('requires root only to set a child-local memlock limit')
resource.setrlimit(resource.RLIMIT_MEMLOCK, (64 * 1024 * 1024, 64 * 1024 * 1024))
os.setgroups([])
os.setgid(1000)
os.setuid(1000)
print(f'uid={os.geteuid()} memlock={resource.getrlimit(resource.RLIMIT_MEMLOCK)}', flush=True)
os.execv(sys.argv[1], sys.argv[1:])
