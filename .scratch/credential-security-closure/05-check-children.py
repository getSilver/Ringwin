import os,struct,subprocess,json,sys
from pathlib import Path
root=Path(__file__).resolve().parent
linux='--linux' in sys.argv
final='--final' in sys.argv
exe=str(root/(('05-final-linux-child' if linux else '05-final-windows-child.exe') if final else ('05-input-linux-child' if linux else '05-input-v3-child.exe')))
prefix=('05-final-linux-child-' if linux else '05-final-windows-child-') if final else ('05-linux-child-' if linux else '05-v3-child-')
fields=[b'synthetic-public-key-05',b'synthetic-private-secret-05',b'synthetic-passphrase-05']
def frame(env=1,purpose=2,account=2,lengths=None,version=1):return b'RWDC'+bytes([version,env,purpose,0])+struct.pack('<Q3H',account,*(lengths or list(map(len,fields))))+b''.join(fields)
cases=[('valid',frame(),0,None),('empty',b'',1,None),('truncated-header',frame()[:12],1,None),('truncated-payload',frame()[:-1],1,None),('zero',frame(lengths=[0,2,3]),1,None),('overlong',frame(lengths=[129,2,3]),1,None),('trailing',frame()+b'x',1,None),('production',frame(env=3),1,None),('testnet',frame(env=2),1,None),('wrong-purpose',frame(purpose=1),1,None),('wrong-account',frame(account=3),1,None),('version',frame(version=2),1,None)]
max_fields=[b'k'*128,b's'*128,b'p'*128]
max_frame=b'RWDC'+bytes([1,1,2,0])+struct.pack('<Q3H',2,128,128,128)+b''.join(max_fields)
binary_fields=[fields[0],b'synthetic-binary-secret\x00\r\n\xff',fields[2]]
binary_frame=b'RWDC'+bytes([1,1,2,0])+struct.pack('<Q3H',2,*map(len,binary_fields))+b''.join(binary_fields)
cases += [('maximum-128',max_frame,0,None),('binary-secret',binary_frame,0,None),('magic',b'BAD!'+frame()[4:],1,None),('reserved',frame()[:7]+b'\x01'+frame()[8:],1,None)]
for name in ['RINGWIN_OKX_KEY','RINGWIN_OKX_SECRET','RINGWIN_OKX_PASSPHRASE']:cases.append(('legacy-'+name,frame(),1,{name:'synthetic-legacy-'+name}))
cases += [('forward',frame(),0,None),('forward-early-exit',frame(),1,None),('valid-observation',frame(purpose=1),0,None)]
results=[]
for name,data,expected,extra in cases:
 env=os.environ.copy()
 for key in ['RINGWIN_OKX_KEY','RINGWIN_OKX_SECRET','RINGWIN_OKX_PASSPHRASE']:env.pop(key,None)
 env.update(extra or {})
 r=subprocess.run([exe]+(['--forward'] if name=='forward' else ['--forward-early-exit'] if name=='forward-early-exit' else ['--observation'] if name=='valid-observation' else []),input=data,capture_output=True,env=env,timeout=30)
 for f in fields:assert f not in r.stdout+r.stderr,(name,'secret output')
 assert (r.returncode==0)==(expected==0),(name,r.returncode,r.stderr)
 assert b'panic:' not in r.stderr and b'General protection' not in r.stderr,(name,r.stderr)
 if name=='forward-early-exit':assert r.returncode==1 and b'BrokenPipe' in r.stderr,(name,r.returncode,r.stderr)
 (root/(prefix+name+'.stdout.log')).write_bytes(r.stdout);(root/(prefix+name+'.stderr.log')).write_bytes(r.stderr)
 results.append({'case':name,'exit':r.returncode,'expected_success':expected==0})

with open(root/(prefix+'regular.frame'),'wb') as f:f.write(frame())
with open(root/(prefix+'regular.frame'),'rb') as f:
 r=subprocess.run([exe],stdin=f,capture_output=True,timeout=30)
 assert r.returncode!=0 and b'RestrictedCredentialStreamRequired' in r.stderr
 (root/(prefix+'regular.stderr.log')).write_bytes(r.stderr)
 results.append({'case':'regular-file','exit':r.returncode,'expected_success':False})
if linux:
 master,slave=os.openpty()
 try:
  r=subprocess.run([exe],stdin=slave,capture_output=True,timeout=30)
  assert r.returncode!=0 and b'RestrictedCredentialStreamRequired' in r.stderr
  (root/(prefix+'tty.stderr.log')).write_bytes(r.stderr)
  results.append({'case':'real-tty','exit':r.returncode,'expected_success':False})
 finally:os.close(master);os.close(slave)
print(json.dumps(results,indent=2));(root/(prefix+'results.json')).write_text(json.dumps(results,indent=2)+'\n')
