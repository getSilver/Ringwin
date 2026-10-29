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
logs = [module/name for name in ['02-safe.log', '02-fast.log', '02-linux-default.log', '02-linux-bounded.log']]
for path in logs:
    data = path.read_bytes()
    assert b'All 8 tests passed.' in data, path
    assert b'FAIL' not in data, path
assert b'refused insufficient RLIMIT_MEMLOCK' in (module/'02-linux-default.log').read_bytes()
assert b'uid=1000 memlock=(67108864, 67108864)' in (module/'02-linux-bounded.log').read_bytes()
recovery = Path('D:/github/Ringwin-credential-recovery-20261018/protected-memory-ORIG_HEAD-before-merge.bin')
original_ref = Path(git('rev-parse', '--git-path', 'ORIG_HEAD'))
result = {
    'compiler': identity(Path('D:/Program Files/zig/zig.exe')),
    'compiler_version': subprocess.check_output(['D:/Program Files/zig/zig.exe', 'version'], text=True).strip(),
    'integration_tip_merged': git('rev-parse', 'codex/credential-security-closure'),
    'sources': [identity(path) for path in sources],
    'logs': [identity(path) for path in logs],
    'artifacts': [identity(module/name) for name in ['credential02-safe.exe', 'credential02-fast.exe', 'credential02-linux']],
    'test_counts': {'Windows_ReleaseSafe': 8, 'Windows_ReleaseFast': 8, 'Linux_ReleaseFast_default_limit_refusal': 8, 'Linux_ReleaseFast_bounded_child_native_success': 8},
    'test_skips': 0,
    'synthetic_only': True,
    'qualification': {'target_dump_swap': False, 'compiler_register_temporaries': False, 'tls_os_internal': False, 'production': False},
    'recovery': {'original_auxiliary_ref_backup': identity(recovery), 'repaired_auxiliary_ref': identity(original_ref), 'repaired_ref_value': original_ref.read_text().strip(), 'restored_existing_head': git('rev-parse', '4d153bdf')},
}
(module/'02-validation.json').write_bytes((json.dumps(result, indent=2) + '\n').encode())
