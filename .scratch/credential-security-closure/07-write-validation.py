from pathlib import Path
import hashlib
import json
import platform
import subprocess

root = Path(__file__).resolve().parents[2]
module = root/'.scratch/credential-security-closure'

def identity(path):
    data = path.read_bytes()
    return {'path': path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

def git(*args):
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()

logs = [module/name for name in ['07-safe.log','07-fast.log','07-linux.log']]
for path in logs:
    data = path.read_bytes()
    assert b'All 10 tests passed.' in data and b'FAIL' not in data, path
refusal = module/'07-native-refusal-linux.log'
assert b'native memlock=0 refused before secret scratch; caller ciphertext/tag cleared' in refusal.read_bytes()
sources = [root/'src/credential_aead.zig', root/'src/protected_memory.zig', *sorted((root/'src/credential_aead_crypto').iterdir())]
result = {
    'stage': 'ticket07 standalone module checkpoint; store integration pending ticket03 merge',
    'host': platform.platform(),
    'compiler': identity(Path('D:/Program Files/zig/zig.exe')),
    'compiler_version': subprocess.check_output(['D:/Program Files/zig/zig.exe', 'version'], text=True).strip(),
    'integration_tip_merged': git('rev-parse','codex/credential-security-closure'),
    'minimal_checkpoint': git('rev-parse','e5524e78'),
    'sources': [identity(path) for path in sources],
    'producer': [identity(module/'vendor-aead.py'),identity(module/'07-native-refusal.zig')],
    'logs': [identity(path) for path in [*logs,refusal,module/'07-red-compat.log',module/'07-green-compat.log']],
    'artifacts': [identity(module/name) for name in ['credential07-safe.exe','credential07-fast.exe','credential07-linux','credential07-native-refusal-linux']],
    'test_counts': {'Windows_ReleaseSafe':10,'Windows_ReleaseFast':10,'WSL_Linux_ReleaseFast':10,'Linux_zero_memlock_native_refusal':1},
    'exit_codes': {'Windows_ReleaseSafe':0,'Windows_ReleaseFast':0,'WSL_Linux_ReleaseFast':0,'Linux_zero_memlock_native_refusal':0},
    'boundary_pairs':54,
    'test_skips':0,
    'synthetic_only':True,
    'store_callsites_integrated':False,
    'qualification': {'target_dump_swap':False,'compiler_register_temporaries':False,'tls_os_internal':False,'production':False},
}
(module/'07-validation.json').write_bytes((json.dumps(result,indent=2)+'\n').encode())
