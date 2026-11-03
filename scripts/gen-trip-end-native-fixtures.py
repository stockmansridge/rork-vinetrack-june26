#!/usr/bin/env python3
"""Turn the capture of scripts/test-trip-end-http-contract.py into the native golden fixtures.

    POSTGREST_BIN=/tmp/pgrst/postgrest TRIP_END_HTTP_CAPTURE=/tmp/trip-end-http-capture.json \\
        python3 scripts/test-trip-end-http-contract.py
    python3 scripts/gen-trip-end-native-fixtures.py /tmp/trip-end-http-capture.json

Writes ios/VineTrackTests/TripEndServerGoldenFixtures.swift. Every request and every answer in it was
produced by a real PostgREST in front of a real PostgreSQL carrying the repository's occurrence SQL, so
the native tests (TripEndServerReplayTests) hand the app's journal and failure classifier what the
server really says instead of what a test author imagines it says.

Nothing is invented here: a missing or ambiguous label, a failed suite or a body that cannot be embedded
verbatim stops the generator. The SHA-256 of every SQL file the answers came from is written into the
header; scripts/test-trip-end-http-contract.py refuses to pass when the SQL in the checkout has moved on.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'ios/VineTrackTests/TripEndServerGoldenFixtures.swift'
CREATE = 'golden: 01 create'

# Real refusals and answers the native tests classify. Each label must occur exactly once.
EXTRA_LABELS = [
    '01: CAS PATCH, unencoded + (build 214)',
    '01: CAS PATCH, %2B (build 215)',
    '01: CAS PATCH, stale updated_at',
    '02: setStatus with tank links, BEFORE the repair',
    '06: finalise with an open tank',
    '07: stale expected revision',
    '07: member of another vineyard',
    '07: no token',
    '07: CAS PATCH by a foreign vineyard member',
]


def raw(text):
    """A one-line Swift raw string that holds the text byte for byte."""
    if '\n' in text or '\r' in text or '"#' in text or '\\#' in text:
        raise SystemExit(f'cannot embed verbatim as a one-line raw string: {text[:100]!r}')
    return '#"' + text + '"#'


def main():
    source = Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/trip-end-http-capture.json')
    capture = json.loads(source.read_text())
    if not capture.get('suiteSucceeded'):
        raise SystemExit('the capture comes from a failing run; fix the suite first')
    exchanges = capture['exchanges']
    wanted = [e['label'] for e in exchanges if e['label'].startswith('golden: ')] + EXTRA_LABELS
    chosen = []
    for label in wanted:
        matches = [e for e in exchanges if e['label'] == label]
        if len(matches) != 1:
            raise SystemExit(f'label {label!r} matched {len(matches)} exchanges; expected exactly one')
        chosen.append(matches[0])
    golden = [e for e in chosen if e['label'].startswith('golden: ')]
    if len(golden) != 16:
        raise SystemExit(f'expected the 16 golden exchanges, found {len(golden)}')
    trip = next(e for e in chosen if e['label'] == CREATE)['request']['p_trip']
    lines = [
        '// GENERATED FILE - do not edit by hand.',
        '// Regenerate:',
        '//   POSTGREST_BIN=/tmp/pgrst/postgrest TRIP_END_HTTP_CAPTURE=/tmp/trip-end-http-capture.json \\',
        '//     python3 scripts/test-trip-end-http-contract.py',
        '//   python3 scripts/gen-trip-end-native-fixtures.py /tmp/trip-end-http-capture.json',
        '//',
        '// Real requests and answers: PostgREST in front of PostgreSQL 17 carrying the SQL below. Not a model of the server.',
    ]
    if capture.get('postgrest'):
        lines.append(f"// postgrest: {capture['postgrest']}")
    lines += [f'// sql-sha256: {path} {digest}' for path, digest in sorted(capture['sqlSha256'].items())]
    lines += [
        '',
        'import Foundation',
        '',
        'nonisolated struct TripEndGoldenExchange: Sendable {',
        '    let label: String',
        '    let method: String',
        '    let path: String',
        '    /// Percent-encoded exactly as it went over the wire.',
        '    let query: String',
        '    /// JSON request body, one line, nil for GET.',
        '    let request: String?',
        '    let status: Int',
        '    /// The response body byte for byte.',
        '    let body: String',
        '}',
        '',
        'nonisolated enum TripEndServerGoldenFixtures {',
        f'    static let owner = "{trip["created_by"].lower()}"',
        f'    static let vineyard = "{trip["vineyard_id"].lower()}"',
        f'    static let tripId = "{trip["id"].lower()}"',
        '',
        '    static func exchange(_ label: String) -> TripEndGoldenExchange {',
        '        guard let found = exchanges.first(where: { $0.label == label }) else {',
        '            preconditionFailure("No golden exchange labelled \\(label)")',
        '        }',
        '        return found',
        '    }',
        '',
        '    static let exchanges: [TripEndGoldenExchange] = [',
    ]
    for e in chosen:
        request = 'nil' if e['request'] is None else raw(json.dumps(e['request'], separators=(',', ':'), ensure_ascii=False))
        lines += [
            '        TripEndGoldenExchange(',
            f"            label: {raw(e['label'])}, method: \"{e['method']}\", path: {raw(e['path'])},",
            # Argument order must match the memberwise initialiser: query, request, status, body.
            f"            query: {raw(e['query'])},",
            f'            request: {request},',
            f"            status: {e['status']},",
            f"            body: {raw(e['body'])}),",
        ]
    lines += ['    ]', '}', '']
    OUTPUT.write_text('\n'.join(lines))
    print(f'wrote {OUTPUT.relative_to(ROOT)}: {len(chosen)} exchanges, {OUTPUT.stat().st_size} bytes')


if __name__ == '__main__':
    main()
