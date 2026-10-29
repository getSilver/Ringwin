"""Preserve v1 evidence; hash the protected-scratch follow-up independently."""
from pathlib import Path
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parents[2]
module = root / '.scratch/credential-security-closure'

def identity(path):
    data = path.read_bytes()
    return {'path': str(path.relative_to(root)) if path.is_relative_to(root) else str(path), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

def git(*args):
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()

sources = [root/'src/protected_memory.zig', root/'src/credential_kdf.zig', *sorted((root/'src/credential_crypto').iterdir())]
logs = [module/name for name in ['02-v2-safe.log', '02-v2-fast.log', '02-v2-linux-default.log', '02-v2-linux-bounded.log']]
for path in logs:
    data = path.read_bytes()
    assert b'All 9 tests passed.' in data, path
    assert b'FAIL' not in data, path
assert b'refused insufficient RLIMIT_MEMLOCK' in (module/'02-v2-linux-default.log').read_bytes()
assert b'uid=1000 memlock=(67108864, 67108864)' in (module/'02-v2-linux-bounded.log').read_bytes()
result = {
    'compiler': identity(Path('D:/Program Files/zig/zig.exe')),
    'compiler_version': subprocess.check_output(['D:/Program Files/zig/zig.exe', 'version'], text=True).strip(),
    'integration_tip_merged': git('rev-parse', 'codex/credential-security-closure'),
    'supersedes_checkpoint': git('rev-parse', '55e06e2f'),
    'retained_v1_metadata': identity(module/'02-validation.json'),
    'sources': [identity(path) for path in sources],
    'logs': [identity(path) for path in logs],
    'red_green': [identity(module/'02-scratch-red.log'), identity(module/'02-scratch-green.log')],
    'artifacts': [identity(module/name) for name in ['credential02-v2-safe.exe', 'credential02-v2-fast.exe', 'credential02-v2-linux']],
    'test_counts': {'Windows_ReleaseSafe': 9, 'Windows_ReleaseFast': 9, 'Linux_ReleaseFast_default_limit_refusal': 9, 'Linux_ReleaseFast_bounded_child_native_success': 9},
    'scratch_storage': 'Scratch allocated in protected fixed-buffer region, includes contexts and named secret arrays; serialized lanes share one owner',
    'test_skips': 0,
    'synthetic_only': True,
    'qualification': {'target_dump_swap': False, 'compiler_register_temporaries': False, 'tls_os_internal': False, 'production': False},
}
(module/'02-v2-validation.json').write_bytes((json.dumps(result, indent=2) + '\n').encode())
