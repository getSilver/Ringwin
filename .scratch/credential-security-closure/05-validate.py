"""Frozen targeted ticket05 offline acceptance; never invokes a network entry."""
from pathlib import Path
import hashlib,json,os,subprocess,sys,zipfile,datetime
import capture
ROOT=capture.ROOT
OUT=Path(__file__).resolve().parent
ZIG='D:/Program Files/zig/zig.exe'
LABEL='05-final-v2'
INCLUDE='.scratch/build/bootstrap/curl-source/curl-8.21.0/include'
LIB='.scratch/build/libcurl-8.21.0-windows-x86_64-schannel/lib'
LINK=['-lc','-L'+LIB,'-lcurl','-lws2_32','-lcrypt32','-lsecur32','-ladvapi32','-lbcrypt','-lwldap32','-lnormaliz','-liphlpapi']
def item(p):
 p=Path(p);return dict(path=str(p),bytes=p.stat().st_size,sha256=capture.sha(p))
def save(p,obj):p.write_bytes((json.dumps(obj,indent=2,ensure_ascii=False)+'\n').encode())
def main():
 os.chdir(ROOT)
 state_path=OUT/(LABEL+'-state.json')
 if state_path.exists():raise RuntimeError('new run prefix required; prior result is immutable')
 source=capture.source_manifest()
 producers=[Path(__file__).resolve(),OUT/'capture.py',OUT/'05-check-children.py',OUT/'05-check-wrappers.py',OUT/'05-empty-stdin.zig']
 producer_rows=[item(p) for p in producers]
 prior_path=OUT/'05-final-v1-state.json'
 prior=json.loads(prior_path.read_bytes())
 old={r['path']:r['sha256'] for r in prior['source']['files']}
 new={r['path']:r['sha256'] for r in source['files']}
 changed=[p for p in sorted(set(old)|set(new)) if old.get(p)!=new.get(p)]
 if changed!=['tools/run-okx-linux-acceptance.ps1']:raise RuntimeError('unexpected source change since v1 '+repr(changed))
 closure=[r for r in source['files'] if r['path'].startswith('src/') or r['path']=='build.zig']
 assert closure==[r for r in prior['source']['files'] if r['path'].startswith('src/') or r['path']=='build.zig']
 prior_producers={Path(r['path']).name:r for r in prior['producers']}
 assert item(OUT/'05-empty-stdin.zig')['sha256']==prior_producers['05-empty-stdin.zig']['sha256']
 reused=[]
 for record in prior['stages']:
  if record['exit_code']!=0:continue
  assert not record['source_changed'] and not record['fatal_diagnostic'] and not record['timed_out']
  if 'artifact' in record:assert item(record['artifact']['path'])==record['artifact']
  reused.append(dict(original=record,result=item(OUT/'runs'/record['label']/'result.json'),source_manifest=item(OUT/'runs'/record['label']/'source.json'),compile_input_closure_unchanged=True))
 assert len(reused)==5
 state=dict(label=LABEL,status='running',pid=os.getpid(),source=source,producers=producer_rows,started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),compiler=item(ZIG),reused_stages=reused,reuse_provenance=dict(previous_state=item(prior_path),retained_source=item(OUT/'05-final-v1-retained-source.zip'),source_changed_paths=changed,unchanged_zig_and_embed_inputs=closure,unchanged_external_zig_input=item(OUT/'05-empty-stdin.zig'),old_global_source_sha256=prior['source']['source_tree_sha256'],new_global_source_sha256=source['source_tree_sha256'],compiler_identity_measured_at_continuation=True),stages=[])
 save(state_path,state)
 def run(name,command,artifact=None,timeout=900):
  for r in producer_rows:
   if capture.sha(Path(r['path']))!=r['sha256']:raise RuntimeError('producer drift '+r['path'])
  state['active_stage']=name;save(state_path,state)
  label=LABEL+'-'+name
  code=capture.capture(label,command,timeout,source)
  record=json.loads((OUT/'runs'/label/'result.json').read_bytes())
  if artifact:record['artifact']=item(ROOT/artifact)
  state['stages'].append(record);save(state_path,state)
  if code!=0:raise RuntimeError(name+' failed with '+str(code))
 try:
  run('windows-children',[sys.executable,str(OUT/'05-check-children.py'),'--final'])
  run('linux-children',['wsl.exe','--','python3','/mnt/d/github/Ringwin-credential-gateway-injection/.scratch/credential-security-closure/05-check-children.py','--linux','--final'])
  run('wrappers',[sys.executable,str(OUT/'05-check-wrappers.py')],timeout=300)
  run('app-build',[ZIG,'build','-Doptimize=ReleaseSafe','--cache-dir','.zig-cache/credential05-final-app'],'zig-out/bin/ringwin.exe')
  run('demo-build',[ZIG,'build','windows-demo-bin','-Doptimize=ReleaseSafe','--cache-dir','.zig-cache/credential05-final-demo'],'zig-out/bin/ringwin-windows-demo.exe')
  for stem,src in [('live','src/okx_demo_live_acceptance.zig'),('private','src/okx_curl_private_smoke.zig')]:
   exe='.scratch/credential-security-closure/05-final-'+stem+'.exe'
   run(stem+'-build',[ZIG,'build-exe',src,'src/okx_curl_shim.c','-I'+INCLUDE,*LINK,'-OReleaseSafe','--stack','67108864','--cache-dir','.zig-cache/credential05-final-'+stem,'-femit-bin='+exe],exe)
  run('transport',[ZIG,'test','src/okx_auth_transport_synthetic_test.zig','-cflags','-DRINGWIN_SHIM_NO_MAIN','--','src/okx_curl_shim_request_test.c','-I'+INCLUDE,'-OReleaseSafe','--stack','67108864','--test-filter','protected credentials survive','--test-filter','read-only account guard rejects','--cache-dir','.zig-cache/credential05-final-transport','-femit-bin=.scratch/credential-security-closure/05-final-transport.exe',*LINK],'.scratch/credential-security-closure/05-final-transport.exe')
  run('offline-chain',[str(ROOT/'zig-out/bin/ringwin.exe'),'--windows-chain-test'],timeout=900)
  for r in producer_rows:assert capture.sha(Path(r['path']))==r['sha256']
  for record in state['stages']+[row['original'] for row in reused]:
   if 'artifact' in record:assert capture.sha(Path(record['artifact']['path']))==record['artifact']['sha256']
  assert capture.source_manifest()==source
  archive=OUT/'05-final-source.zip'
  with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED) as z:
   for r in source['files']:z.write(ROOT/r['path'],r['path'])
   for p in producers:z.write(p,p.relative_to(ROOT).as_posix())
   z.write(ROOT/'docs/okx-demo-credential-input.md','docs/okx-demo-credential-input.md')
  state.update(status='passed',active_stage=None,compiler=item(ZIG),compiler_version=subprocess.check_output([ZIG,'version']).decode().strip(),source_archive=item(archive),dependencies=[item(ROOT/r) for r in [INCLUDE+'/curl/curl.h',LIB+'/libcurl.a']],finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
  save(state_path,state)
 except BaseException as e:
  state.update(status='failed',error=repr(e),finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat());save(state_path,state);raise
if __name__=='__main__':main()
