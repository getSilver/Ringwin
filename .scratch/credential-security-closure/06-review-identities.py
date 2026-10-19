"""Capture task-06 targeted identities, without relabeling earlier task evidence."""
import hashlib, json, subprocess
from pathlib import Path
base = Path(__file__).resolve().parent
repo = base.parent.parent
compiler = Path('D:/Program Files/zig/zig.exe')
def identity(path):
    data = path.read_bytes()
    return {'path': str(path.relative_to(repo)) if path.is_relative_to(repo) else str(path), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
tracked = subprocess.check_output(['git', 'ls-files', 'src', 'tools', 'build.zig', 'build.zig.zon'], cwd=repo, text=True).splitlines()
sources = [identity(repo / p) for p in tracked if (repo / p).is_file()]
evidence = [identity(p) for p in sorted(base.glob('06-review-*')) if p.is_file() and p.name != '06-review-validation.json']
builds = []
for source, output, extra in [
    ('.scratch/credential-security-closure/06-review-fake-compiler.zig', '06-review-fake-compiler.exe', []),
    ('src/okx_demo_credential_input.zig', '06-review-windows-child.exe', []),
    ('src/okx_demo_credential_input.zig', '06-review-linux-child', ['-target', 'x86_64-linux-gnu']),
    ('.scratch/credential-security-closure/05-empty-stdin.zig', '06-review-empty-stdin.exe', []),
]:
    builds.append({'command': [str(compiler), 'build-exe', source, *extra, '-OReleaseSafe', '-femit-bin=.scratch/credential-security-closure/' + output], 'exit': 0, 'stdout': '', 'stderr': '', 'observation': 'Actual tool execution returned exit 0 and empty output; identities captured after execution, not a fresh build log.'})
reports = []
external = Path('D:/github/Ringwin-credential-recovery-20261018')
for axis in ('standards', 'spec'):
    original = external / ('final-' + axis + '-review.md')
    retained = base / ('06-review-original-' + axis + '.md')
    assert original.read_bytes() == retained.read_bytes()
    reports.append({'external_original': identity(original), 'retained_copy': identity(retained)})
result = {
    'scope': 'New targeted task-06 review-fix evidence only. No old global-source qualification is relabeled.',
    'integration_base': '7d884048903b0f731a4e318f10116eff06919e12',
    'compiler': identity(compiler),
    'compiler_version': subprocess.check_output([str(compiler), 'version'], text=True).strip(),
    'builds': builds,
    'commands': [['python', '.scratch/credential-security-closure/06-review-regression.py', phase] for phase in ('red', 'green')] + [['python', '.scratch/credential-security-closure/06-review-check-wrappers.py']],
    'sources': sources,
    'retained_prior_producers': [identity(base / p) for p in ('05-empty-stdin.zig', '05-check-wrappers.py')],
    'evidence_and_artifacts': evidence, 'reports': reports,
}
assert result['compiler_version'] == '0.17.0-dev.315+5b647b792'
(base / '06-review-validation.json').write_text(json.dumps(result, indent=2) + '\n')
print('source_identities=' + str(len(sources)) + ' evidence_artifact_identities=' + str(len(evidence)) + ' report_copies_exact=true')
