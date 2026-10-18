"""Bind recovered ticket-04 source, commands, outputs and synthetic artifacts."""
from pathlib import Path
import hashlib
import json
import subprocess
import capture

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
ZIG = 'D:/Program Files/zig/zig.exe'
INCLUDE = 'D:/github/Ringwin/.scratch/build/bootstrap/curl-source/curl-8.21.0/include'
LIB = 'D:/github/Ringwin/.scratch/build/libcurl-8.21.0-windows-x86_64-schannel/lib'
LABEL = '04-recovery-v1'
LINK = ['-L' + LIB] + ['-l' + name for name in ['curl', 'ws2_32', 'crypt32', 'secur32', 'advapi32', 'bcrypt', 'wldap32', 'normaliz', 'iphlpapi']]

def item(path):
    path = Path(path)
    return dict(path=str(path), bytes=path.stat().st_size, sha256=capture.sha(path))

def main():
    baseline = capture.source_manifest()
    stages = []
    def run(name, command, artifact=None):
        label = LABEL + '-' + name
        code = capture.capture(label, command, timeout=600, expected=baseline)
        record = OUT / 'runs' / label / 'result.json'
        stages.append(dict(name=name, result=item(record), artifact=item(ROOT / artifact) if artifact and (ROOT / artifact).exists() else None))
        if code:
            raise RuntimeError(label + ' exit=' + str(code))
    for mode, cache in [('Debug', 'auth04-debug'), ('ReleaseSafe', 'auth04-safe'), ('ReleaseFast', 'auth04-fast')]:
        artifact = '.scratch/credential-security-closure/04-recovery-auth-' + mode + '.exe'
        run('auth-' + mode, [ZIG, 'test', 'src/okx_rest_auth.zig', '-O', mode, '--cache-dir', '.zig-cache/' + cache, '-femit-bin=' + artifact], artifact)
    linux = '.scratch/credential-security-closure/04-recovery-auth-linux'
    run('linux-build', [ZIG, 'test', 'src/okx_rest_auth.zig', '-O', 'ReleaseSafe', '-target', 'x86_64-linux', '--test-no-exec', '--cache-dir', '.zig-cache/auth04-linux', '-femit-bin=' + linux], linux)
    run('linux-run', ['wsl.exe', '--', '/mnt/d/github/Ringwin-credential-auth-protection/' + linux], linux)
    transport = '.scratch/credential-security-closure/04-recovery-transport.exe'
    run('transport', [ZIG, 'test', 'src/okx_auth_transport_synthetic_test.zig', '-cflags', '-DRINGWIN_SHIM_NO_MAIN', '--', 'src/okx_curl_shim_request_test.c', '-I' + INCLUDE, '-O', 'ReleaseSafe', '--test-filter', 'protected credentials survive', '--cache-dir', '.zig-cache/auth04-transport', '-femit-bin=' + transport, '-lc'] + LINK, transport)
    c = '.scratch/credential-security-closure/04-recovery-c.exe'
    run('c-build', [ZIG, 'cc', 'src/okx_curl_shim_request_test.c', '-I' + INCLUDE, '-O2', '-o', c] + LINK, c)
    run('c-run', [str(ROOT / c)], c)
    result = dict(label=LABEL, compiler=item(ZIG), compiler_version=subprocess.check_output([ZIG, 'version']).decode().strip(), source=baseline, producer=item(__file__), capture=item(Path(capture.__file__)), dependencies=[item(Path(INCLUDE)/'curl/curl.h'), item(Path(INCLUDE)/'curl/curlver.h'), item(Path(INCLUDE)/'curl/system.h'), item(Path(LIB)/'libcurl.a')], stages=stages, qualification=False)
    (OUT / '04-recovery-validation.json').write_bytes((json.dumps(result, indent=2)+'\n').encode())

if __name__ == '__main__':
    main()
