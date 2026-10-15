"""Record the manually reviewed task08 fixture delta at the current source identity."""
from pathlib import Path
import importlib.util,json,re,hashlib
root=Path(__file__).resolve().parents[2]
out=root/'.scratch/core-continuous-capacity'
prefix=__import__('sys').argv[1]
spec=importlib.util.spec_from_file_location('capture',out/'run-07-command.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
manifest=module.source_manifest()
assert manifest==json.loads((out/(prefix+'-source-manifest.json')).read_text())
old=json.loads((out/'07-final-v5-fixture-source-review.json').read_text())
fixtures=old['fixtures']
for row in fixtures:
    digest=module.sha(root/row['path'])
    row['prior_review_sha256']=row['sha256']
    row['sha256']=digest
    row['review_provenance']='unchanged source matches prior independent review' if digest==row['prior_review_sha256'] else 'task08 root delta review; original fixture populations unchanged'
extra=[
('08 control history','src/control_archive_acceptance.zig',0,0,'320 sequential commands;160 gates/latches;80 retired fences;80 actual Core+Cutover activations. No OMS placement. Checkpoints every8 commands/every4 gates plus each32/16/8 history window and actual recover.'),
('08 resident authorization','src/control_resident_order_acceptance.zig',1,0,'Exactly one unsent pending-cancel order retaining reservation and its old EnableTrading authority;40 unrelated commands archived, checkpoints every8, actual recover digest and exactly2 retained control records.'),
('08 four shard forced','src/coordinator_history_acceptance.zig',4,4,'Four Owners each initialize one order quantity400 then archive its filled terminal and Fill before320 sources. Each source divides into four slices; no new orders in loop. Full source/proof and every active ledger posting read; checkpoint/recover every4 rounds, exact cumulative forced320 and economic cursor321 per shard.'),
('08 shared routing','src/coordination_gateway_acceptance.zig',1,1,'320 sequential terminal order routes; retire and archive before next placement. At most1 order live/terminal. Public reconciliation restores recovery admission; checkpoints and real recovery every4, token2..321 retained, SDK0.'),
('08 Coordinator safety','src/coordinator_safety_acceptance.zig',1,1,'Four summaries and10 lease cycles create no orders. Independent source fault cases each use one forced harness initial order then archive. Gateway closure uses one terminal order. Each fault fixture destroyed before next; no population accumulation.'),
('08 Cutover history','src/cutover_history.zig',0,0,'80 activation records across10 old8-slot windows, no OMS orders; every window archives/checkpoints/recovers. Candidate-incomplete and publish/commit/seal/rotate/reclaim cases preserve pin.'),
('08 forced record','src/forced_archive_acceptance.zig',0,0,'Projection proof/ledger fixture creates no OMS order. Nonzero PnL eight complete transactions; standalone record protocol test only, public Owner chain separately covered.'),
('08 Gateway outcome retention','src/control_gateway_retention_acceptance.zig',2,0,'One resident unsent order; two explicit durable dispatch proofs represent accepted and Unknown. Each control/forced root recovers Gateway; no send method called. Synthetic committed-source fixture is isolated Gateway protocol coverage, not Core proof acceptance.'),
]
for name,path,live,terminal,evidence in extra:
    fixtures.append(dict(name=name,path=path,sha256=module.sha(root/path),max_live_across_shards=live,max_terminal_across_shards=terminal,evidence=evidence,review_provenance='task08 current source manual root review'))
files=sorted(p.relative_to(root).as_posix() for p in (root/'src').rglob('*.zig') if re.search(r'^test\s',p.read_text(encoding='utf-8-sig'),re.M))
report=dict(status='reviewed',source_tree_sha256=manifest['source_tree_sha256'],source_inventory=manifest['files'],test_files=files,test_file_count=len(files),fixtures=fixtures,all_test_fixtures_within_limit=True,
review_method='Prior independent 07 review retained only for exact unchanged sources; root current-source delta review of all08 modified and new test-bearing files, plus independent08 agent fixture observations. Logical historical counters and observation counts do not represent resident orders. No reduced recovery/checkpoint coverage. Full native runs separately required.',
final_review='Root verified task08 populations, finite backing disk128/64MiB without live array growth, no live sends. Independent Standards/Spec findings and fixes are recorded in08-review.md. Independent final08 Standards delta review completed at the frozen identity (08-standards-review.md): source hashes, task08 population bounds and backing-only budgets confirmed. Unchanged old files retain prior exact-hash review; no claim of new manual audit of all89 files.')
(out/(prefix+'-fixture-source-review.json')).write_bytes((json.dumps(report,indent=2)+'\n').encode())
print(manifest['source_tree_sha256'],len(files),len(fixtures))
