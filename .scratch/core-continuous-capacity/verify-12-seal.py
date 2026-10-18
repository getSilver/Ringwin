"""Read-only verification of the sealed package and interrupted-candidate chain."""
from pathlib import Path
import hashlib
import json
import sys

OUT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(references, base):
    for name, digest in references.items():
        assert sha(base / name) == digest, name
    return len(references)


def main():
    prefix = sys.argv[1]
    package = OUT / (prefix + '-wave-evidence')
    manifest_count = verify(json.loads((package / 'manifest.json').read_text()), package)
    identity = json.loads((package / 'identity.json').read_text())
    references = identity['evidence_references']
    reference_count = verify(references, OUT)
    interrupted_path = OUT / '12-interrupted-v1.json'
    interrupted_sha = sha(interrupted_path)
    coverage = OUT / '12-coverage.md'
    assert references[coverage.name] == sha(coverage)
    assert interrupted_sha in coverage.read_text(encoding='utf-8')
    interrupted = json.loads(interrupted_path.read_text())
    assert interrupted['state'] == 'interrupted_without_completion'
    interrupted_count = verify(interrupted['evidence_references'], OUT)
    assert interrupted_count == 98
    result = {'state': 'passed', 'source_tree_sha256': identity['source_tree_sha256'],
              'manifest_files': manifest_count, 'package_references': reference_count,
              'interrupted_candidate_references': interrupted_count,
              'interrupted_catalog_sha256': interrupted_sha,
              'coverage_sha256': references[coverage.name],
              'package_manifest_sha256': sha(package / 'manifest.json'),
              'verifier_sha256': sha(Path(__file__)),
              'production_qualification': False}
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
