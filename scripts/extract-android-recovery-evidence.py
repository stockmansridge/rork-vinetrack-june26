#!/usr/bin/env python3
"""Extract test-only native screenshot packets from a retained instrumentation stream."""
import argparse
import base64
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('log', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
packets = {}
for label, index, payload in re.findall(r'^RECOVERY_SCREEN_(.+)_(\d+)=([A-Za-z0-9+/=]+)$', args.log.read_text(), re.M):
    packets.setdefault(label, {})[int(index)] = payload
for label, chunks in packets.items():
    assert sorted(chunks) == list(range(len(chunks))), f'Missing packet for {label}'
    image = base64.b64decode(''.join(chunks[index] for index in range(len(chunks))), validate=True)
    assert image[:4] == b'RIFF' and int.from_bytes(image[4:8], 'little') + 8 == len(image), f'Truncated image for {label}'
    target = args.output / f'{label}.webp'
    target.write_bytes(image)
    print(target)
