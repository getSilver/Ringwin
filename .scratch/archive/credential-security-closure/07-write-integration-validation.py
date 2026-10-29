"""Seal new store/AEAD integration evidence without relabeling ticket03 runs."""
from pathlib import Path
import hashlib
import json
import subprocess
import zipfile

root = Path(__file__).resolve().parents[2]
module = root/'.scratch/credential-security-closure'
if (module/'07-integration-validation.json').exists() or (module/'07-store-source.zip').exists():
    raise SystemExit('refusing to overwrite sealed ticket07 integration evidence')

def identity(path):
    data = path.read_bytes()
    return {'path':path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}

labels = ['07-store-windows-safe-v1','07-store-linux-compile-v1','07-store-linux-bounded-v1','07-store-linux-default-compile-v1','07-store-linux-default-v1','07-store-entry-windows-compile-v1','07-store-entry-linux-compile-v1','07-store-entry-windows-v1','07-store-entry-linux-v1']
records = []
refs = []
source = None
for label in labels:
    folder = module/'runs'/label
    record = json.loads((folder/'result.json').read_text())
    assert record['exit_code'] == 0 and not any(record[key] for key in ['timed_out','fatal_diagnostic','capture_error','source_changed']),label
    manifest = json.loads((folder/'source.json').read_text())
    if source is None:
        source = manifest
    assert manifest == source,label
    for stream in ['stdout','stderr']:
        assert identity(folder/(stream+'.log'))['sha256'] == record[stream+'_sha256'],label
    records.append(record)
    refs.extend(identity(folder/name) for name in ['result.json','source.json','stdout.log','stderr.log'])
for label in ['07-store-windows-safe-v1','07-store-linux-bounded-v1']:
    text = (module/'runs'/label/'stderr.log').read_bytes()
    assert b'All 38 tests passed.' in text
    assert b'public lifecycle reads and revokes original CRD4 v1 synthetic audit fixture...OK' in text
assert b'All 1 tests passed.' in (module/'runs/07-store-linux-default-v1/stderr.log').read_bytes()
for label in ['07-store-entry-windows-v1','07-store-entry-linux-v1']:
    text = (module/'runs'/label/'stdout.log').read_bytes()
    assert b'state=ready' in text and b'mode=read_only' in text and b'send_capability=false' in text
archive = module/'07-store-source.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as output:
    for row in source['files']:
        path = root/row['path']
        assert identity(path)['sha256'] == row['sha256'],row['path']
        output.write(path,row['path'])
result = {
    'stage':'ticket07 integrated protected AEAD in real CredentialStore',
    'integration_tip_merged':subprocess.check_output(['git','rev-parse','codex/credential-security-closure'],cwd=root,text=True).strip(),
    'source_tree_sha256':source['source_tree_sha256'],
    'source_archive':identity(archive),
    'compiler':identity(Path('D:/Program Files/zig/zig.exe')),
    'retained_module_checkpoint_metadata':identity(module/'07-validation.json'),
    'retained_ticket03_metadata':identity(module/'03-validation.json'),
    'producer':[identity(module/name) for name in ['capture.py','02-linux-bounded.py','03-entry.zig']],
    'external_callsite_patch':identity(Path('D:/github/Ringwin-credential-recovery-20261018/03-aead-integration.patch')),
    'normalized_callsite_patch':identity(module/'07-aead-integration.patch'),
    'captures':records,
    'references':refs,
    'artifacts':[identity(module/name) for name in ['credential07-store-safe.exe','credential07-store-linux','credential07-store-default-linux','credential07-entry.exe','credential07-entry-linux']],
    'tests':{'Windows_ReleaseSafe_store':38,'Linux_ReleaseSafe_store':38,'Linux_default_memlock_public_refusal':1,'native_non_test_entry_read_only_ready':2},
    'store_callsites_integrated':True,
    'old_CRD4_v1_fixture_read_and_revoke_both_platforms':True,
    'new_production_qualification':False,
    'real_credentials_or_network_used':False,
}
(module/'07-integration-validation.json').write_bytes((json.dumps(result,indent=2)+'\n').encode())
