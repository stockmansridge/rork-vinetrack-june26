"""Export tested PR52 delta without Git mutation, credentials, or Android.

Requires exact public PR head tarball at --baseline. Creates a reviewable patch,
changed-file source archive and hashes; verifies application in a disposable tree.
Does not run application analysis, builds, native tests, migrations or publication.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BASE = 'cbe1795ad5d678a25d594e61eb607ef2656be4a0'
EVIDENCE = 'docs/reviews/evidence/ios-pr52-guided-repair-20261103'
IMPLEMENTATION = [
    '.github/workflows/ios-guided-sync-repair-native.yml',
    'ios/VineTrack/App/GuidedSyncIssueRepairView.swift',
    'ios/VineTrack/Backend/Sync/GuidedLegacyDeletedTripRepair.swift',
    'ios/VineTrack/Backend/Sync/GuidedSyncRepairEngine.swift',
    'ios/VineTrackTests/GuidedSyncRepairEngineTests.swift',
    'ios/VineTrackTests/TrackedSprayCompletionSyncTests.swift',
    'sql/284_guided_repair_archived_actual_tombstone_contract.sql',
    'sql/tests/284_guided_repair_contract_tests.sql',
    'scripts/inspect-pr52-backend.py',
    'scripts/test-pr52-postgres-contract.py',
    'scripts/record-ios-pr52-validation.py',
    'scripts/record-ios-pr52-followup.py',
    'scripts/prepare-ios-pr52-source.py',
    'scripts/export-ios-pr52-corrections.py',
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with tarfile.open(args.baseline) as archive:
        members = [m for m in archive if m.isfile()]
        assert all(BASE in m.name.split('/')[0] for m in members), 'Wrong archive revision'
        baseline = {m.name.split('/', 1)[1]: archive.extractfile(m).read() for m in members}
    imported = json.loads((ROOT / EVIDENCE / 'source-application.json').read_text())
    assert imported['head'] == BASE
    for item in imported['files']:
        assert sha(baseline[item['path']]) == item['sha256'], 'Original PR bytes differ'
    validated = json.loads((ROOT / EVIDENCE / 'followup-source-manifest.json').read_text())
    assert all(sha((ROOT / x['path']).read_bytes()) == x['sha256'] for x in validated), 'Validated source changed'
    ios_delta = {p for p in baseline if p.startswith('ios/') and p != 'ios/VineTrack/Config.swift'
                 and (ROOT / p).is_file() and (ROOT / p).read_bytes() != baseline[p]}
    assert ios_delta == {p for p in IMPLEMENTATION if p.startswith('ios/')}, 'Unexpected iOS delta'
    assert not [p for p in baseline if p.startswith('ios/') and not (ROOT / p).is_file()], 'Missing iOS files'
    assert not [p for p in ROOT.joinpath('ios').rglob('*.swift')
                if p.relative_to(ROOT).as_posix() not in baseline and p.name != 'Config.swift'], 'Unexpected new Swift files'
    paths = sorted(set(IMPLEMENTATION + [p.relative_to(ROOT).as_posix()
                    for p in (ROOT / EVIDENCE).iterdir() if p.is_file()]))
    payload, entries, chunks = {}, [], []
    for name in paths:
        assert not name.startswith(('android', '.rork/')) and Path(name).name != 'Config.swift'
        after = (ROOT / name).read_bytes()
        before = baseline.get(name)
        if before == after:
            continue
        payload[name] = after
        lines = after.decode('utf-8').splitlines(keepends=True)
        old_lines = [] if before is None else before.decode('utf-8').splitlines(keepends=True)
        chunks.append(f'diff --git a/{name} b/{name}\n')
        if before is None:
            chunks.append('new file mode 100644\n')
        chunks.append(f'index {"0" * 40 if before is None else blob(before)}..{blob(after)}' +
                      (' 100644' if before is not None else '') + '\n')
        for line in difflib.unified_diff(old_lines, lines,
                      fromfile='/dev/null' if before is None else 'a/' + name,
                      tofile='b/' + name, n=3):
            chunks.append(line if line.endswith('\n') else line + '\n\\ No newline at end of file\n')
        entries.append({'path': name, 'status': 'added' if before is None else 'modified',
                        'base_sha256': None if before is None else sha(before),
                        'corrected_sha256': sha(after), 'bytes': len(after)})
    patch = ''.join(chunks).encode()
    patch_name = 'pr52-corrected-since-cbe1795.patch'
    patch_path = args.output / patch_name
    if patch_path.exists():
        raise SystemExit('Refusing to overwrite existing export')
    patch_path.write_bytes(patch)
    # Apply only in an isolated non-Git directory; current source/index untouched.
    with tempfile.TemporaryDirectory(prefix='pr52-export-check-') as temp:
        tree = Path(temp)
        for name in payload:
            if name in baseline:
                target = tree / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(baseline[name])
        subprocess.run(['git', 'apply', '--check', str(patch_path.resolve())], cwd=tree, check=True)
        subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-i', str(patch_path.resolve())],
                       cwd=tree, check=True, capture_output=True)
        assert all((tree / name).read_bytes() == data for name, data in payload.items())
    handoff = {
        'base_pr': 52, 'repository': 'stockmansridge/rork-vinetrack-june26',
        'base_sha': BASE, 'managed_export_head': subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(),
        'purpose': 'Transfer exact corrected implementation into existing PR52; not a full-main replacement',
        'files': entries, 'file_count': len(entries), 'patch_sha256': sha(patch),
        'verified': ['All 1312 recorded validation-manifest file hashes still match',
                     'Original 12 PR import hashes match downloaded exact-head archive',
                     'All five iOS deltas included; no extra/new Swift delta omitted',
                     'git apply --check succeeds against exact baseline files',
                     'Isolated zero-fuzz patch application reproduces every exported byte'],
        'validation': {'native': 'Previously observed seven-suite 82 passes /78 seconds',
                       'build': 'Previously observed runChecks iOS simulator PASS',
                       'rerun_for_export': False, 'xcode_26_3_final_sha': 'Still required',
                       'original_iphone_acceptance': 'Still required'},
        'sql284': 'Already deployed successfully through managed migration; exact post-deploy hashes and SELECT-only verification are in followup-validation-receipt.json. Do not blindly redeploy.',
        'excluded': ['Android', 'unrelated main changes', '.rork history/state',
                     'ignored Config.swift, environment values, credentials and signing assets',
                     'backend/types.ts automatic regeneration unrelated to iOS implementation'],
        'preservation': 'Patch application must stop on conflicts. Never copy source/ over newer files wholesale.',
        'evidence_note': 'All evidence files are retained with original historical/pass/failure limitations. No final passing named XML/xcresult was exposed; stale failure log is not a passing log.'
    }
    instructions = f'''# PR52 corrected implementation transfer

Base: `{BASE}`. This is a delta, not a main-branch snapshot.

1. Download/extract this package outside the target checkout. Verify SHA256SUMS.
2. In the existing PR52 branch checkout, inspect its current HEAD and working-tree changes.
3. Run `git apply --check /absolute/path/{patch_name}`. If it fails, STOP and reconcile conflicts individually. Do not reset, force, overwrite newer main files, or apply with ignored rejects.
4. Once the check passes, apply `git apply /absolute/path/{patch_name}`. Review the diff and publish through your authenticated GitHub workflow to the existing PR branch. Do not replace main with this archive.
5. Run required Xcode26.3 validation on the actual new public SHA. Existing 82-pass simulator result does not waive that gate.

`source/` contains exact changed-file bytes only, for review and hash comparison; it is NOT an overwrite installer. `handoff.json` contains original and corrected per-file SHA-256 checksums. The patch includes validation evidence at its original repository paths.

SQL284 is already deployed. Preserve the migration file for source parity, but do not blindly run it again. Exact-definition guards intentionally reject drift.

SQL282/283 and other unchanged PR52 files already exist at the base revision and therefore require no delta. Android, unrelated main changes, managed configuration, credentials, signing material and Rork history are excluded.

The Swift/XCTest async teardown workaround, frozen review inputs, retained first-tank evidence, amendment durable request/version/UUID, full lost-response receipt verification, and overlapping-operation guards are included. Direct legacy cleanup integration, live authenticated acceptance, original-iPhone repair and final public-SHA CI remain open exactly as recorded. No tests or builds were rerun for this export.
'''
    handoff_bytes = (json.dumps(handoff, indent=2) + '\n').encode()
    zip_name = 'pr52-corrected-cbe1795-export.zip'
    with zipfile.ZipFile(args.output / zip_name, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(patch_name, patch)
        archive.writestr('handoff.json', handoff_bytes)
        archive.writestr('APPLY.md', instructions)
        for name, data in payload.items():
            archive.writestr('source/' + name, data)
    (args.output / 'handoff.json').write_bytes(handoff_bytes)
    sums = '\n'.join(f'{sha((args.output / name).read_bytes())}  {name}'
                     for name in [patch_name, zip_name, 'handoff.json']) + '\n'
    (args.output / 'SHA256SUMS').write_text(sums)
    print(sums)
    print(json.dumps({'exported_files': len(entries), 'ios_files': len(ios_delta),
                      'patch_application': 'PASS; exact byte parity; no source/Git mutation'}, indent=2))


if __name__ == '__main__':
    main()
