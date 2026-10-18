"""Read-only dependency equivalence after unrelated ticket04 integration."""
from pathlib import Path
import hashlib
import json
import re
import runpy
import subprocess

root = Path(__file__).resolve().parents[2]
module = root/'.scratch/credential-security-closure'
destination = module/'07-postmerge-v2-validation.json'
if destination.exists():
    raise SystemExit('refusing to overwrite ticket07 postmerge evidence')
original = json.loads((module/'runs/07-store-windows-safe-v1/source.json').read_text())
before = {row['path']:row['sha256'] for row in original['files']}
current = runpy.run_path(str(module/'capture.py'))['source_manifest']()
after = {row['path']:row['sha256'] for row in current['files']}
closure = set()
pending = [root/'src/credential_store.zig']
while pending:
    path = pending.pop().resolve()
    name = path.relative_to(root).as_posix()
    if name in closure:
        continue
    assert before[name] == after[name],name
    closure.add(name)
    if path.suffix == '.zig':
        for imported in re.findall(r'@(import|embedFile)\("([^"]+)"\)',path.read_text()):
            kind, relative = imported
            candidate = path.parent/relative
            if kind == 'embedFile' or relative.endswith('.zig'):
                assert candidate.is_file(),candidate
                pending.append(candidate)
changed = [{'path':name,'before':before.get(name),'after':after.get(name)} for name in sorted(set(before)|set(after)) if before.get(name) != after.get(name)]
assert changed
source_sha = current['source_tree_sha256']
subprocess.check_call(['git','merge-base','--is-ancestor','codex/credential-security-closure','HEAD'],cwd=root)
result = {
    'latest_integration_merged':subprocess.check_output(['git','rev-parse','codex/credential-security-closure'],cwd=root,text=True).strip(),
    'tested_source_tree_sha256':original['source_tree_sha256'],
    'postmerge_global_source_tree_sha256':source_sha,
    'superseded_metadata_sha256':hashlib.sha256((module/'07-postmerge-validation.json').read_bytes()).hexdigest(),
    'metadata_only_correction':'v1 used case-sensitive POSIX-name ordering while authoritative capture sorts WindowsPath; v2 directly calls capture.source_manifest; all raw runtime captures and dependency-file hashes remain unchanged',
    'store_dependency_closure_unchanged':True,
    'dependency_files':[{'path':name,'sha256':after[name]} for name in sorted(closure)],
    'unrelated_global_source_changes_after_ticket04_merge':changed,
    'claim':'Ticket07 dependency regression remains unchanged; new full global freeze is still required by integration.',
}
destination.write_bytes((json.dumps(result,indent=2)+'\n').encode())
