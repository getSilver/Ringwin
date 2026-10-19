import json,os,shutil,struct,subprocess
from pathlib import Path
base=Path(__file__).resolve().parent
repo=base.parent.parent
fixture=base/'05 wrapper fixture v1'
fixture.mkdir(exist_ok=False)
(fixture/'tools').mkdir()
wrappers=['run-windows-demo-readonly.ps1','run-okx-demo-live-acceptance.ps1','test-okx-zig-private.ps1','run-okx-linux-acceptance.ps1']
for n in wrappers+['protected-demo-launch.ps1']:shutil.copyfile(repo/'tools'/n,fixture/'tools'/n)
for relative in ['zig-out/bin/ringwin-windows-demo.exe','.scratch/build/okx-demo-live-acceptance.exe','.scratch/build/okx-curl-private-smoke.exe']:
 p=fixture/relative;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(base/'05-input-v3-child.exe',p)
p=fixture/'.scratch/build/okx-demo-live-acceptance-linux';shutil.copyfile(base/'05-input-linux-child',p)
for relative in ['.scratch/build/bootstrap/curl-source/curl-8.21.0/include/curl/curl.h','.scratch/build/curl-linux-openssl-3/lib/libcurl.a','.scratch/build/linux-deps/openssl3/root/usr/lib/x86_64-linux-gnu/libssl.a','.scratch/build/linux-deps/openssl3/root/usr/lib/x86_64-linux-gnu/libcrypto.a','.scratch/build/linux-deps/root/usr/lib/x86_64-linux-gnu/libz.a']:
 p=fixture/relative;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'fixture only - never linked')
bin=fixture/'fakebin';bin.mkdir();shutil.copyfile(base/'05-empty-stdin.exe',bin/'zig.exe')
fields=[b'synthetic-public-key-05',b'synthetic-private-secret-05',b'synthetic-passphrase-05']
frame=b'RWDC'+bytes([1,1,1,0])+struct.pack('<Q3H',2,*map(len,fields))+b''.join(fields)
env=os.environ.copy();env['PATH']=str(bin)+os.pathsep+env['PATH']
for key in ['RINGWIN_OKX_KEY','RINGWIN_OKX_SECRET','RINGWIN_OKX_PASSPHRASE']:env.pop(key,None)
results=[]
for n in wrappers:
 args=['powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(fixture/'tools'/n),'-UidSha256','0'*64]
 if n!='test-okx-zig-private.ps1':args+=['-RestBaseUrl','https://openapi.okx.com','-Entity','global']
 if n=='run-okx-demo-live-acceptance.ps1':args+=['-PrepareOnly']
 r=subprocess.run(args,input=frame,capture_output=True,env=env,timeout=60)
 (base/('05-wrapper-'+n+'.stdout.log')).write_bytes(r.stdout);(base/('05-wrapper-'+n+'.stderr.log')).write_bytes(r.stderr)
 assert r.returncode==0,(n,r.returncode,r.stdout,r.stderr)
 assert b'build_stdin_empty=true' in r.stdout and b'credential_input=accepted network=false' in r.stdout,(n,r.stdout)
 for field in fields:assert field not in r.stdout+r.stderr
 results.append({'wrapper':n,'exit':r.returncode,'compiler_stdin_empty':True,'native_frame_accepted':True,'actual_network_binary':False})
(base/'05-wrapper-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
