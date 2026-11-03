"""Apply pinned PR52 files only when every existing file still matches its base.
Archives and GitHub metadata are downloaded separately outside the project.
Does not change Git state, generated configuration, Android or device data.
"""
import hashlib
import json
from pathlib import Path
import sys
import tarfile

HEAD = 'cbe1795ad5d678a25d594e61eb607ef2656be4a0'
BASE = '977868e9f480c46fb74c5f7352769dd8101ed0d8'


def files(archive):
    with tarfile.open(archive) as source:
        return {m.name.split('/', 1)[1]: source.extractfile(m).read()
                for m in source.getmembers() if m.isfile() and '/' in m.name}


def main():
    metadata = json.loads(Path('/tmp/pr52.json').read_text())
    changes = json.loads(Path('/tmp/pr52-files.json').read_text())
    assert metadata['head']['sha'] == HEAD and metadata['base']['sha'] == BASE
    assert len(changes) == 12
    head = files('/tmp/pr52-source.tgz')
    base = files('/tmp/pr52-base.tgz')
    for change in changes:
        name = change['filename']
        path = Path(name)
        assert name.startswith(('ios/', 'sql/', '.github/workflows/'))
        assert name != 'ios/VineTrack/Config.swift'
        assert name in head
        if path.exists():
            assert name in base and path.read_bytes() == base[name], name + ': preserve newer work; stop'
        else:
            assert change['status'] == 'added', name + ': unexpected missing file'
    receipt = {'head': HEAD, 'base': BASE, 'method': 'All existing changed files equal pinned base before applying exact head bytes', 'files': []}
    for change in changes:
        name = change['filename']
        path = Path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(head[name])
        assert path.read_bytes() == head[name]
        receipt['files'].append({'path': name, 'sha256': hashlib.sha256(head[name]).hexdigest()})
    destination = Path('docs/reviews/evidence/ios-pr52-guided-repair-20261103')
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'source-application.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('Applied and byte-verified all 12 pinned files. Git state unchanged; newer unrelated files preserved.')


if __name__ == '__main__':
    main()
