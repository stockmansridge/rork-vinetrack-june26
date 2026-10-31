#!/usr/bin/env python3
"""Inspect exact PR26 archive deltas without extracting or mutating source."""
import argparse
import difflib
import json
import tarfile
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('name', nargs='?')
p.add_argument('--full', action='store_true')
p.add_argument('--offset', type=int, default=0)
p.add_argument('--limit', type=int, default=200)
a = p.parse_args()
files = json.loads(Path('/tmp/vinetrack-quadrant-files.json').read_text())
if not a.name:
    for item in files:
        print(item['status'], item['filename'])
else:
    name = next(x['filename'] for x in files if x['filename'].endswith(a.name))
    with tarfile.open('/tmp/vinetrack-quadrant-base.tar.gz') as base, tarfile.open('/tmp/vinetrack-quadrant-head.tar.gz') as head:
        after = head.extractfile(head.getnames()[0] + '/' + name).read().decode()
        if a.full:
            lines = after.splitlines()
        else:
            member = base.getnames()[0] + '/' + name
            before = base.extractfile(member).read().decode() if member in base.getnames() else ''
            lines = list(difflib.unified_diff(before.splitlines(), after.splitlines(), fromfile='base/' + name, tofile='head/' + name, lineterm=''))
        print(f'{name}: {len(lines)} lines; requested {a.offset}:{a.offset+a.limit}')
        for n, line in enumerate(lines[a.offset:a.offset+a.limit], a.offset+1):
            print(f'{n:5} {line}')
