"""Read-only replay of the captured v2 allocation false positive; not qualification."""
from pathlib import Path
import copy
import importlib.util
import json

OUT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('processes', OUT / 'run-10-file-processes.py')
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)
directory = Path('/home/ubuntu/ringwin-frontier11/11-final-v2-app-processes')
rows = sorted((json.loads(path.read_text()) for path in directory.glob('*.result.json')),
              key=lambda row: row['finished_utc'])
final = {row['command'][-1]: row for row in rows}
results = []
for target, row in final.items():
    actual = processes.inventory(Path(target))
    corrupted = copy.deepcopy(actual)
    corrupted[0]['sha256'] = '0' * 64
    results.append({'label': row['label'], 'content_preserved': processes.same_file_content(actual, row['files_after']),
                    'corruption_rejected': not processes.same_file_content(corrupted, row['files_after']),
                    'allocation_observation_changed': actual != row['files_after']})
assert len(results) == 5
assert all(row['content_preserved'] and row['corruption_rejected'] for row in results)
assert any(row['allocation_observation_changed'] for row in results)
report = {'scope': 'real captured data regression only; v2 is not qualified', 'results': results}
path = OUT / '11-allocation-real-regression.json'
assert not path.exists()
path.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
