"""Seal completed ticket05 evidence without changing any frozen producer/source."""
from pathlib import Path
import datetime,hashlib,json,platform,struct,subprocess,zipfile
import capture
ROOT=capture.ROOT; OUT=Path(__file__).resolve().parent

def item(p):
 p=Path(p);return dict(path=str(p),bytes=p.stat().st_size,sha256=capture.sha(p))
def verify(row):
 actual=item(row['path']);assert actual['sha256']==row['sha256'],row['path']
 if 'bytes' in row:assert actual['bytes']==row['bytes'],row['path']
def save(p,obj):p.write_bytes((json.dumps(obj,indent=2,ensure_ascii=False)+'\n').encode())
def main():
 state_path=OUT/'05-final-v2-state.json';state=json.loads(state_path.read_bytes())
 assert state['status']=='passed' and len(state['stages'])==9 and len(state['reused_stages'])==5
 assert capture.source_manifest()==state['source']
 for row in state['producers']:verify(row)
 verify(state['compiler']);verify(state['source_archive'])
 refs=[item(state_path),item(OUT/'05-final-v1-state.json')]
 artifacts=[]
 for original,reused in [(r,False) for r in state['stages']]+[(r['original'],True) for r in state['reused_stages']]:
  assert original['exit_code']==0 and not original['fatal_diagnostic'] and not original['timed_out'] and not original['source_changed']
  directory=OUT/'runs'/original['label']
  disk=json.loads((directory/'result.json').read_bytes())
  for key,value in disk.items():assert original[key]==value,(original['label'],key)
  assert capture.sha(directory/'stdout.log')==disk['stdout_sha256']
  assert capture.sha(directory/'stderr.log')==disk['stderr_sha256']
  wanted=state['reuse_provenance']['old_global_source_sha256'] if reused else state['source']['source_tree_sha256']
  assert disk['source_tree_sha256']==wanted
  refs += [item(directory/n) for n in ['result.json','source.json','stdout.log','stderr.log']]
  if 'artifact' in original:
   verify(original['artifact']); artifacts.append(original['artifact'])
 for row in state['reused_stages']:verify(row['result']);verify(row['source_manifest'])
 verify(state['reuse_provenance']['previous_state']);verify(state['reuse_provenance']['retained_source'])
 windows=json.loads((OUT/'05-final-v2-windows-child-results.json').read_bytes())
 linux=json.loads((OUT/'05-final-v2-linux-child-results.json').read_bytes())
 wrappers=json.loads((OUT/'05-final-v2-wrapper-results.json').read_bytes())
 assert len(windows)==23 and len(linux)==24 and len(wrappers)==8
 assert all((r['exit']==0)==r['expected_success'] for r in windows+linux)
 assert sum('native_frame_accepted' in r for r in wrappers)==4
 assert all(r.get('before_build_and_network',True) for r in wrappers)
 chain=(OUT/'runs/05-final-v2-offline-chain/stdout.log').read_text()
 assert 'windows_okx_offline=passed' in chain and 'role_ownership=passed durable_recovery=passed' in chain
 assert 'production_qualification=false' in chain
 assert 'All 11 tests passed' in (OUT/'runs/05-final-v1-parser-tests/stderr.log').read_text()
 assert 'All 2 tests passed' in (OUT/'runs/05-final-v2-transport/stderr.log').read_text()
 pe=[]
 for row in artifacts:
  if not row['path'].endswith('.exe'):continue
  data=Path(row['path']).read_bytes();offset=struct.unpack_from('<I',data,0x3c)[0]+24
  assert struct.unpack_from('<H',data,offset)[0]==0x20b
  reserve=struct.unpack_from('<Q',data,offset+72)[0]
  # The tiny empty-stdin producer is not a product/test stack requirement.
  if not row['path'].endswith('05-final-empty-stdin.exe'):assert reserve==64*1024*1024,(row['path'],reserve)
  pe.append(dict(path=row['path'],stack_reserve_bytes=reserve))
 deps=json.loads((OUT/'build-dependencies.json').read_bytes())
 for row in deps['files']:verify(dict(row,path=str(ROOT/row['path'])))
 retained=OUT/'05-retained-tool-producers.zip'
 retained_members=[]
 with zipfile.ZipFile(retained,'x',zipfile.ZIP_DEFLATED) as z:
  for p in sorted(OUT.glob('05 wrapper fixture v*/tools/*.ps1')):
   retained_members.append(item(p));z.write(p,p.relative_to(ROOT).as_posix())
 flat=[item(p) for p in sorted(OUT.glob('05-*')) if p.is_file() and p.suffix in ['.json','.log','.py','.zig','.zip'] and p.name not in ['05-validation.json']]
 v=dict(client_date='2026-10-19',sealed_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),source=state['source'],controller_state=item(state_path),producer=item(Path(__file__).resolve()),producers=state['producers'],compiler=state['compiler'],compiler_version=state['compiler_version'],source_archive=state['source_archive'],runtime_platform=platform.platform(),dependencies_manifest=item(OUT/'build-dependencies.json'),dependencies=deps['files'],new_current_source_stages=9,reused_original_stages=5,reuse_provenance=state['reuse_provenance'],artifacts=artifacts,pe_stack_reserves=pe,result_references=refs,flat_evidence=flat,retained_tool_sources=item(retained),retained_tool_members=retained_members,checks=dict(windows_child_cases=23,linux_child_cases=24,windows_parser_dependency_tests=11,synthetic_transport_and_http_tests=2,wrapper_valid_native_frames=4,wrapper_retired_envfile_rejections=4,offline_chain_passed=True),historical_classification={'05-input-red.log':'Intentional missing implementation red','05-child-build.log':'Probe Args.Iterator Windows API compile diagnostic; fixed initAllocator','05-guard-demo-build.log':'Allocator.dupeZ unavailable in pinned Zig; fixed dupeSentinel','05-wrapper/05-v2-wrapper failures':'.NET Framework automatically inserted UTF8 BOM in compiler pipe; no credential frame was forwarded to compiler','05-v3-wrapper failure':'PS5.1 has no StandardInputEncoding property; Console.InputEncoding scope used instead','05-v4-wrapper Linux failure':'PS5.1 param-default PSScriptRoot empty; paths now filled in script body','05-final-v1':'Five prechecks passed; Windows closed-pipe errno assertion was too narrow; actual exit1 Unexpected with no panic. Source/archive and recovered stderr provenance retained.','05-chain-v1':'Historical offline pass before final dependency/cleanup/source binding; final v2 chain is separate','older unbound phase artifacts/logs':'Diagnostic history only; not counted as final-source qualification'},limits=['Only synthetic credentials; no Venue requests/orders, deployment or real EnvFile reads','Linux/WSL functional byte-stream/memory API evidence; no target dump/swap or production qualification','Native guard source GET refusal matrix belongs to ticket08; actual network guard responses not exercised','Windows closed-pipe forward returns pinned Io Unexpected, Linux BrokenPipe; exact failure context/no panic/no accepted output asserted','Five v1 successful results keep original global source hash; new global source only changes Linux wrapper shell literal, all Zig/embed/build inputs and extra empty-stdin producer equal','Arbitrary process termination, compiler/register spills, libcurl/TLS/OS internal storage remain outside functional wipe proof'])
 v['pending_review_findings']=[dict(file='tools/verify-okx-demo-wave.ps1',finding='Invoke-EmptyInputNative CaptureOutput does not set global LASTEXITCODE; immediate check may see undefined/stale value under PS5.1 StrictMode',coverage='Four launcher mirror successes exercise final native invocation, not this long verify prefix',disposition='Deferred to single ticket06 review fixer; frozen source unchanged; whole-task/full acceptance remains pending')]
 save(OUT/'05-validation.json',v)
 print('05 seal verified',len(refs),'result references,',len(flat),'flat evidence files,',len(artifacts),'artifacts')
if __name__=='__main__':main()
