"""Describe the measured small functional sample, never promote design budgets."""
from pathlib import Path
import hashlib
import json
import re
import sys

out = Path(__file__).resolve().parent
prefix = sys.argv[1] if len(sys.argv) > 1 else '09-final-v1'
result = json.loads((out / (prefix + '-functional-sample.result.json')).read_text())
assert result['exit_code'] == 0 and result['source_mismatches_after'] == 0
text = (out / (prefix + '-functional-sample.log')).read_text()
assert hashlib.sha256((out / (prefix + '-functional-sample.log')).read_bytes()).hexdigest() == result['log_sha256']
layout = re.search(r'continuous layout (.*)', text)
assert layout is not None
sizes = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', layout[1])}
windows = []
for line in text.splitlines():
    if line.startswith('continuous seed='):
        windows.append({key: int(value) for key, value in re.findall(r'(\w+)=(\d+)(?:\s|$)', line)})
assert len(windows) == 40
backlog = [{key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
           for line in text.splitlines() if line.startswith('continuous backlog ')]
assert len(backlog) == 40
storage = [{key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
           for line in text.splitlines() if line.startswith('continuous storage ')]
assert len(storage) == 40
observations = {
    'layout_bytes': sizes,
    'minimum_explicit_shard_copy_bytes_per_committed_owner_input': 2 * sizes['shard'],
    'copy_scope': 'static explicit memcpy lower bound in Owner.apply only; journal, digest, rollback and codec traffic excluded',
    'memory': result['memory'],
    'command_elapsed_ns': result['elapsed_ns'],
    'recovered_windows': windows,
    'pre_archive_backlog_samples': backlog,
    'simulated_store_storage_samples': storage,
    'latency_scope': 'cumulative submit_total_ns / submit_samples per shard, including book refresh, apply, simulated send, batch and maintenance; not p99 or Core latency',
    'max_observed_checkpoint_snapshot_bytes': max(w['snapshot_bytes'] for w in windows),
    'actual_thread_stack_peak': 'not_measured',
    'pe_reservation': 'app 64MiB; test/CLI 256MiB; reservation is not measured usage',
    'physical_index_bytes_per_identity': 'not_measured',
    'queue_scope': 'one bounded simulated Adapter pending output, sampled at business boundaries; not 8192 safe-queue headroom or a throughput test',
    'small_fixture_scope': 'four-shard ten windows, mixed 5 live/3 terminal, safety <=2 orders, shared account 4 live, unique500 observation with <=100 live/4 terminal',
    'capacity_stress_qualification': 'deferred', 'resource_budget_qualification': 'not_qualified',
    'platform_performance_qualification': 'not_qualified', 'production_qualification': False,
}
report = {'source_tree_sha256': result['source_tree_sha256'],
          'producer_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          'sample_log_sha256': result['log_sha256'], **observations}
(out / (prefix + '-resource-observations.json')).write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: report[k] for k in ('layout_bytes', 'minimum_explicit_shard_copy_bytes_per_committed_owner_input', 'max_observed_checkpoint_snapshot_bytes', 'memory')}, indent=2))
