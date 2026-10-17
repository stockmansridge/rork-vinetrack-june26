#!/usr/bin/env python3
"""Extract emulator-produced WebP evidence from the bounded instrumentation stream."""
import argparse
import base64
import re
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--log', default='/tmp/rork-android-test-android-vinetrack.log')
parser.add_argument('--output', default='/tmp/live-trip-ui-evidence')
args = parser.parse_args()
output = Path(args.output)
output.mkdir(parents=True, exist_ok=True)
text = Path(args.log).read_text()
chunks = {}
for name, index, encoded in re.findall(r'LIVE_TRIP_WEBP_CHUNK_([a-z0-9-]+)_([0-9]+)=([A-Za-z0-9+/=]+)', text):
    chunks.setdefault(name, {})[int(index)] = encoded
images = [(name, ''.join(parts[i] for i in range(max(parts) + 1))) for name, parts in chunks.items()]
found = 0
for name, encoded in images:
    path = output / (name + '.webp')
    path.write_bytes(base64.b64decode(encoded, validate=True))
    print(path)
    found += 1
if not found:
    raise SystemExit('No image evidence in the instrumentation stream.')
