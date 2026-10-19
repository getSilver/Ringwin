"""Bounded public PS5.1 helper/verify regression. Never runs real wave suites."""
import base64, hashlib, json, os, struct, subprocess, sys
from pathlib import Path

base = Path(__file__).resolve().parent
repo = base.parent.parent
phase = sys.argv[1]
assert phase in ('red', 'green')
compiler = base / '06-review-fake-compiler.exe'
fields = [b'synthetic-public-key-06', b'synthetic-secret-06\x00\r\n\xff', b'synthetic-passphrase-06']
frame = b'RWDC' + bytes([1, 1, 1, 0]) + struct.pack('<Q3H', 2, *map(len, fields)) + b''.join(fields)
env = os.environ.copy()
for name in ('RINGWIN_OKX_KEY', 'RINGWIN_OKX_SECRET', 'RINGWIN_OKX_PASSPHRASE'):
    env.pop(name, None)
env['RINGWIN_SYNTHETIC_FRAME_BASE64'] = base64.b64encode(frame).decode()
# Get-Command zig resolves an actual controlled native executable.
fakebin = base / ('06-review-' + phase + '-fakebin')
fakebin.mkdir(exist_ok=False)
(fakebin / 'zig.exe').write_bytes(compiler.read_bytes())
env['PATH'] = str(fakebin) + os.pathsep + env['PATH']
results = []
for case, seed in [('success', 'unset'), ('success', 'stale'), ('failure', 'unset'), ('verify', 'unset'), ('verify', 'stale')]:
    args = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(base / '06-review-exit-state.ps1'),
            '-Helper', str(repo / 'tools/protected-demo-launch.ps1'), '-Compiler', str(compiler),
            '-Verify', str(repo / 'tools/verify-okx-demo-wave.ps1'), '-Seed', seed, '-Case', case]
    r = subprocess.run(args, input=frame, capture_output=True, env=env, timeout=30)
    prefix = base / f'06-review-{phase}-{case}-{seed}'
    prefix.with_suffix('.stdout.log').write_bytes(r.stdout)
    prefix.with_suffix('.stderr.log').write_bytes(r.stderr)
    for field in fields:
        assert field not in r.stdout + r.stderr
    results.append({'case': case, 'seed': seed, 'exit': r.returncode, 'command': args})
    if phase == 'green':
        assert r.returncode == 0, (case, seed, r.stdout, r.stderr)
        assert b'original_frame_preserved=true' in r.stdout
        if case == 'verify':
            assert b'bounded_verify_reached_fmt=true compiler_stdin_empty=true' in r.stdout
    else:
        assert r.returncode != 0, (case, seed, 'red unexpectedly passed')
result = {'phase': phase, 'helper_sha256': hashlib.sha256((repo / 'tools/protected-demo-launch.ps1').read_bytes()).hexdigest(), 'results': results}
(base / f'06-review-{phase}-results.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
