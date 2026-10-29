"""Seal existing account-guard captures; never relabel or overwrite old runs."""
from pathlib import Path
import hashlib
import json
import platform
import runpy
import subprocess
import zipfile

root = Path(__file__).resolve().parents[2]
module = root/'.scratch/credential-security-closure'
destination = module/'08-validation.json'
archive = module/'08-final-source.zip'
temporary = module/'08-final-source.zip.tmp'
if any(path.exists() for path in [destination,temporary]):
    raise SystemExit('refusing to overwrite account-guard evidence')

def identity(path):
    data = path.read_bytes()
    return {'path':path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}

def git(*args):
    return subprocess.check_output(['git',*args],cwd=root,text=True).strip()

capture = runpy.run_path(str(module/'capture.py'))
current = capture['source_manifest']()
subprocess.check_call(['git','merge-base','--is-ancestor','codex/credential-security-closure','HEAD'],cwd=root)
labels = sorted(path.name for path in (module/'runs').glob('08-*') if path.is_dir())
final_labels = ['08-final-debug-v1','08-final-safe-v1','08-final-linux-compile-v1','08-final-linux-run-v1']
expected_failures = {
    '08-normal-red-v1':'expected product red: implementation not present',
    '08-shape-red-v1':'expected product red: malformed extra leverage row accepted',
    '08-blank-liability-red-v1':'expected compatibility red: explicit blank liability convention rejected',
    '08-rejections-debug-v1':'test-harness compile error: unsupported array repetition spelling; v2 fixed fixture construction',
}
references = []
records = []
for label in labels:
    folder = module/'runs'/label
    record = json.loads((folder/'result.json').read_text())
    source = json.loads((folder/'source.json').read_text())
    assert not any(record[key] for key in ['timed_out','fatal_diagnostic','capture_error','source_changed']),label
    assert record['exit_code'] == (1 if label in expected_failures else 0),label
    assert record['capture_sha256'] == identity(module/'capture.py')['sha256'],label
    for stream in ['stdout','stderr']:
        assert identity(folder/(stream+'.log'))['sha256'] == record[stream+'_sha256'],label
    if label in final_labels:
        assert source == current,label
        if 'compile' not in label:
            assert b'All 10 tests passed.' in (folder/'stderr.log').read_bytes(),label
    records.append({'result':record,'classification':expected_failures.get(label,'passed')})
    references.extend(identity(folder/name) for name in ['result.json','source.json','stdout.log','stderr.log'])
assert set(final_labels).issubset(labels)
assert (module/'credential08-final-debug.exe').read_bytes()[:2] == b'MZ'
assert (module/'credential08-final-safe.exe').read_bytes()[:2] == b'MZ'
assert (module/'credential08-final-linux').read_bytes()[:4] == b'\x7fELF'
for row in current['files']:
    assert identity(root/row['path'])['sha256'] == row['sha256'],row['path']
if archive.exists():
    # A completed archive may remain if the integration branch advanced before
    # v1's final ancestry check. Resume only after exact member verification.
    with zipfile.ZipFile(archive) as retained:
        assert retained.testzip() is None
        assert set(retained.namelist()) == {row['path'] for row in current['files']}
        for row in current['files']:
            assert hashlib.sha256(retained.read(row['path'])).hexdigest() == row['sha256'],row['path']
else:
    with zipfile.ZipFile(temporary,'x',zipfile.ZIP_DEFLATED,compresslevel=9) as output:
        for row in current['files']:
            output.write(root/row['path'],row['path'])
    temporary.rename(archive)
assert capture['source_manifest']() == current
subprocess.check_call(['git','merge-base','--is-ancestor','codex/credential-security-closure','HEAD'],cwd=root)
result = {
    'sealed_date':'2026-10-19',
    'scope':'standalone generic read-only Demo guard; ticket05 owns real source and pre/post invocation',
    'head_before_seal':git('rev-parse','HEAD'),
    'integration_tip_merged':git('rev-parse','codex/credential-security-closure'),
    'compiler':identity(Path('D:/Program Files/zig/zig.exe')),
    'compiler_version':subprocess.check_output(['D:/Program Files/zig/zig.exe','version'],text=True).strip(),
    'host':platform.platform(),
    'source_tree_sha256':current['source_tree_sha256'],
    'guard_source':identity(root/'src/okx_demo_account_guard.zig'),
    'source_archive':identity(archive),
    'producer':[identity(module/'capture.py'),identity(Path(__file__))],
    'contract_sources':[identity(root/'tools/okx-demo-preflight.ps1'),identity(root/'tools/run-windows-demo-readonly.ps1'),identity(root/'src/okx_private_reconciliation.zig')],
    'artifacts':[identity(module/name) for name in ['credential08-final-debug.exe','credential08-final-safe.exe','credential08-final-linux']],
    'tests':{'Windows_Debug':10,'Windows_ReleaseSafe':10,'WSL_Linux_ReleaseSafe_actual_run':10},
    'normal_GET_paths':16,
    'algo_pending_kinds':7,
    'balance_views':2,
    'envelope_rejection_variants_per_path':8,
    'explicit_blank_liability_convention':'only existing string liab/isoLiab/crossLiab may be empty or whitespace; missing/non-string rejects; pos/eq remain strict nonempty decimal',
    'test_skips':0,
    'Linux_runtime':'WSL1 Linux 4.4.0-17763-Microsoft, uid1000, actual native ELF execution',
    'captures':records,
    'references':references,
    'safety':{'synthetic_only':True,'real_network_or_credentials':False,'CanonicalEvent_translation':False,'order_write_capability':False,'new_control_CLI':False,'production_qualification':False},
    'remaining_integration':'ticket05 must connect real protected GET source before first write and after both success/failure; this does not qualify that wider source',
}
with destination.open('xb') as file:
    file.write((json.dumps(result,indent=2)+'\n').encode())
