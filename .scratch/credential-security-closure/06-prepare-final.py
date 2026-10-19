"""Prepare, but do not execute, one final frozen offline validation wave."""
from pathlib import Path
import argparse
import json
import subprocess
import zipfile
from capture import ROOT, OUT, sha, source_manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('wave')
    args = parser.parse_args()
    wave = args.wave
    if not wave or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in wave):
        raise ValueError('simple unique wave name required')
    directory = OUT / wave
    directory.mkdir(exist_ok=False)
    zig = Path('D:/Program Files/zig/zig.exe')
    version = subprocess.check_output([str(zig), 'version'], text=True).strip()
    assert version == '0.17.0-dev.315+5b647b792'
    source = source_manifest()
    dependencies = json.loads((OUT / 'build-dependencies.json').read_bytes())['files']
    for row in dependencies:
        assert sha(ROOT / row['path']) == row['sha256'], row['path']
    producers = [OUT / name for name in ('capture.py', 'final-wave.py',
                 '06-prepare-final.py', '02-linux-bounded.py')]
    producer_rows = [{'path': p.relative_to(ROOT).as_posix(), 'sha256': sha(p)} for p in producers]
    producer_rows += [{'path': str(zig), 'sha256': sha(zig)}]
    producer_rows += [{'path': row['path'], 'sha256': row['sha256']} for row in dependencies]
    steps = []
    artifacts = []

    def add(label, command, artifact=None, timeout=1800):
        steps.append(dict(label=label, command=list(map(str, command)), timeout=timeout))
        if artifact:
            artifacts.append(dict(label=label, path=artifact))

    def z(label, arguments, artifact=None, timeout=1800):
        add(label, [zig, *arguments], artifact, timeout)

    def out(name):
        return (directory / name).relative_to(ROOT).as_posix()

    def linux(path):
        path = (ROOT / path).resolve()
        return '/mnt/' + path.drive[0].lower() + path.as_posix()[2:]

    def bounded(label, artifact, arguments=()):
        add(label, ['wsl.exe', '-u', 'root', '-e', 'python3',
                    linux(OUT.relative_to(ROOT) / '02-linux-bounded.py'),
                    linux(artifact), *arguments])

    include = '.scratch/build/bootstrap/curl-source/curl-8.21.0/include'
    library = '.scratch/build/libcurl-8.21.0-windows-x86_64-schannel/lib'
    link = ['-lc', '-L' + library, '-lcurl', '-lws2_32', '-lcrypt32',
            '-lsecur32', '-ladvapi32', '-lbcrypt', '-lwldap32', '-lnormaliz', '-liphlpapi']
    add('diff-check', ['git', 'diff', '--check', 'c5f73ba08ed10e6a5f42e97264f4c72e9b2f2864...HEAD'])
    z('format', ['fmt', '--check', 'src', 'build.zig'])
    # Compile every root before starting either long full suite.
    for mode in ('Debug', 'ReleaseSafe'):
        artifact = out('core-' + mode + '.exe')
        z('compile-core-' + mode.lower(), ['test', 'src/main.zig', '-O' + mode,
          '--test-no-exec', '--stack', '536870912', '-femit-bin=' + artifact], artifact)
    z('build-app', ['build', '-Doptimize=ReleaseSafe', '--cache-dir', '.zig-cache/credential06-app'],
      'zig-out/bin/ringwin.exe')
    z('build-demo', ['build', 'windows-demo-bin', '-Doptimize=ReleaseSafe', '--cache-dir',
      '.zig-cache/credential06-demo'], 'zig-out/bin/ringwin-windows-demo.exe')
    for name, stem in [('live', 'okx_demo_live_acceptance'), ('private', 'okx_curl_private_smoke')]:
        artifact = out(name + '.exe')
        z('build-' + name, ['build-exe', 'src/' + stem + '.zig', 'src/okx_curl_shim.c',
          '-I' + include, *link, '-OReleaseSafe', '--stack', '67108864', '-femit-bin=' + artifact], artifact)
        z('linux-check-' + name, ['build-exe', 'src/' + stem + '.zig',
          '-target', 'x86_64-linux-gnu', '-OReleaseSafe', '-fno-emit-bin'])
    artifact = out('shim.exe')
    z('compile-shim', ['cc', 'src/okx_curl_shim_request_test.c', '-I' + include, *link,
      '-o', artifact], artifact)
    artifact = out('transport.exe')
    z('compile-transport', ['test', 'src/okx_auth_transport_synthetic_test.zig', '-cflags',
      '-DRINGWIN_SHIM_NO_MAIN', '--', 'src/okx_curl_shim_request_test.c', '-I' + include,
      '-OReleaseSafe', '--test-no-exec', '--stack', '67108864',
      '--test-filter', 'protected credentials survive', '--test-filter',
      'read-only account guard rejects', '-femit-bin=' + artifact, *link], artifact)
    for name, root in [('store', 'credential_store'), ('kdf', 'credential_kdf'),
                       ('aead', 'credential_aead'), ('auth', 'okx_rest_auth'),
                       ('guard', 'okx_demo_account_guard'), ('input', 'okx_demo_credential_input')]:
        artifact = out('linux-' + name)
        z('compile-linux-' + name, ['test', 'src/' + root + '.zig', '-target',
          'x86_64-linux-gnu', '-OReleaseSafe', '--test-no-exec', '--stack', '67108864',
          '-femit-bin=' + artifact], artifact)
    artifact = out('linux-app')
    refusal = out('linux-default-refusal')
    z('compile-linux-default-refusal', ['test', 'src/credential_store.zig', '-target',
      'x86_64-linux-gnu', '-OReleaseSafe', '--test-no-exec', '--test-filter',
      'public native stage refuses insufficient Linux memlock', '-femit-bin=' + refusal], refusal)
    z('compile-linux-app', ['build-exe', 'src/main.zig', '-target', 'x86_64-linux-gnu',
      '-OReleaseSafe', '--stack', '67108864', '-femit-bin=' + artifact], artifact)
    add('shim', [ROOT / out('shim.exe')])
    add('transport', [ROOT / out('transport.exe')])
    for name in ('store', 'kdf', 'aead', 'auth', 'guard', 'input'):
        bounded('linux-' + name, out('linux-' + name))
    add('linux-default-refusal', ['wsl.exe', '-e', linux(refusal)])
    bounded('linux-credential-entry', out('linux-app'), ['--credential-store-test'])
    for label, flag in [('fixture', '--offline-fixture'), ('credential-entry',
                         '--windows-credential-store-test'), ('chain', '--windows-chain-test')]:
        add('windows-' + label, [ROOT / 'zig-out/bin/ringwin.exe', flag])
    for mode in ('Debug', 'ReleaseSafe'):
        add('full-' + mode.lower(), [ROOT / out('core-' + mode + '.exe')], timeout=14400)
    archive = directory / 'source.zip'
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as zfile:
        for row in source['files']:
            zfile.write(ROOT / row['path'], row['path'])
        for path in producers:
            zfile.write(path, path.relative_to(ROOT).as_posix())
    assert source_manifest() == source
    record = dict(wave=wave, source=source, producers=producer_rows, steps=steps,
                  artifacts=artifacts, compiler_version=version,
                  implementation_head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                  source_archive=dict(path=archive.relative_to(ROOT).as_posix(), sha256=sha(archive)),
                  scope='synthetic/offline only; Linux standalone curl roots semantic-check only; WSL is functional evidence')
    plan = OUT / (wave + '-plan.json')
    with plan.open('xb') as stream:
        stream.write((json.dumps(record, indent=2) + '\n').encode())
    print(json.dumps(dict(plan=str(plan), steps=len(steps), source=source['source_tree_sha256'])))


if __name__ == '__main__':
    main()
