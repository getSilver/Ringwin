"""Preserve completed implementer trees; this script never removes anything."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PARENT = Path('D:/github').resolve()
DESTINATION = PARENT / 'Ringwin-credential-worktrees-archive-20261019'
NAMES = ['lifecycle-fix', 'protected-memory', 'store-protection', 'auth-protection',
         'aead-protection', 'gateway-injection', 'native-account-guard', 'review-fixes']


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', '-C', str(cwd), *args], text=True).strip()


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def files(tree):
    for directory, directories, names in os.walk(tree, followlinks=False):
        base = Path(directory)
        directories[:] = [name for name in directories
                          if name not in ('.git', '.zig-cache')
                          and (base / name).relative_to(tree).as_posix() != '.scratch/build']
        for name in directories:
            if (base / name).is_symlink():
                raise RuntimeError('Unexpected directory link: ' + str(base / name))
        for name in names:
            path = base / name
            if name == '.git':
                continue
            if path.is_symlink():
                raise RuntimeError('Unexpected file link: ' + str(path))
            if name.startswith('.env') and path.relative_to(tree).as_posix() != '.env.example':
                raise RuntimeError('Unexpected environment file; preserve tree untouched: ' + str(path))
            yield path


def main():
    integration_head = git('rev-parse', 'HEAD')
    trees = []
    # Finish all read-only checks before creating a snapshot.
    for suffix in NAMES:
        tree = (PARENT / ('Ringwin-credential-' + suffix)).resolve()
        assert tree.parent == PARENT and tree != ROOT.resolve()
        head = git('rev-parse', 'HEAD', cwd=tree)
        assert not git('status', '--porcelain', '--untracked-files=no', cwd=tree), tree
        subprocess.run(['git', '-C', str(ROOT), 'merge-base', '--is-ancestor',
                        head, integration_head], check=True)
        selected = list(files(tree))
        trees.append((tree, head, selected))
    DESTINATION.mkdir(exist_ok=False)
    manifest = dict(started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    integration_head=integration_head, destination=str(DESTINATION),
                    exclusions=['.git', '.zig-cache', '.scratch/build'],
                    scope='complete source/evidence/binary preservation; no deletion', trees=[])
    for tree, head, selected in trees:
        rows = []
        for source in selected:
            relative = source.relative_to(tree)
            target = DESTINATION / tree.name / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            before = source.stat()
            checksum = digest(source)
            shutil.copy2(source, target)
            after = source.stat()
            assert (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns), source
            assert digest(target) == checksum, target
            rows.append(dict(path=relative.as_posix(), bytes=before.st_size, sha256=checksum))
        assert git('rev-parse', 'HEAD', cwd=tree) == head
        assert not git('status', '--porcelain', '--untracked-files=no', cwd=tree)
        record = dict(path=str(tree), head=head, files=rows, bytes=sum(r['bytes'] for r in rows))
        manifest['trees'].append(record)
        (DESTINATION / 'manifest.partial.json').write_bytes((json.dumps(manifest, indent=2) + '\n').encode())
        print(json.dumps(dict(tree=tree.name, files=len(rows), bytes=record['bytes'])), flush=True)
    manifest['finished_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (DESTINATION / 'manifest.json').write_bytes((json.dumps(manifest, indent=2) + '\n').encode())
    print('preservation_complete=true worktrees_removed=false', flush=True)


if __name__ == '__main__':
    main()
