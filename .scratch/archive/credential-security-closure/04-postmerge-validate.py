"""Check only C/transport after C fixture line-ending normalization and store-only merge."""
from pathlib import Path
import json
import subprocess
import capture
OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
def item(p):
    p=Path(p)
    return dict(path=str(p),bytes=p.stat().st_size,sha256=capture.sha(p))
before=json.loads((OUT/'04-recovery-validation.json').read_text())
source=capture.source_manifest()
old={row['path']:row['sha256'] for row in before['source']['files']}
now={row['path']:row['sha256'] for row in source['files']}
auth=['src/okx_rest_auth.zig','src/okx_curl_transport.zig','src/protected_memory.zig','src/credential_crypto/sha256.zig','src/okx_curl_shim.c','src/okx_auth_transport_synthetic_test.zig']
assert all(old[p]==now[p] for p in auth)
stages=[]
for label in ['transport','c-build','c-run']:
    record=json.loads((OUT/'runs'/('04-recovery-v1-'+label)/'result.json').read_text())
    command=[arg.replace('04-recovery-transport.exe','04-recovery-normalized-transport.exe').replace('04-recovery-c.exe','04-recovery-normalized-c.exe') for arg in record['command']]
    name='04-postmerge-v1-'+label
    code=capture.capture(name,command,timeout=600,expected=source)
    if code:raise RuntimeError(name+' exit='+str(code))
    stages.append(item(OUT/'runs'/name/'result.json'))
result=dict(source=source,producer=item(__file__),capture=item(Path(capture.__file__)),auth_inputs_unchanged=auth,prior_validation=item(OUT/'04-recovery-validation.json'),integration_merged=subprocess.check_output(['git','rev-parse','HEAD']).decode().strip(),normalization='Only C request test fixture CRLF normalized to LF after previous captures; old C/auth production sources unchanged. Store-only integration merge does not affect imported auth source.',stages=stages,artifacts=[item(OUT/'04-recovery-normalized-transport.exe'),item(OUT/'04-recovery-normalized-c.exe')])
(OUT/'04-postmerge-validation.json').write_bytes((json.dumps(result,indent=2)+'\n').encode())
