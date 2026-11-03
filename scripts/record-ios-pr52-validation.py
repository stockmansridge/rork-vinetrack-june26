"""Record the bounded PR52 validation checkpoint, without customer data or config bytes."""
import hashlib
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

DEST = Path('docs/reviews/evidence/ios-pr52-guided-repair-20261103')
PR_HEAD = 'cbe1795ad5d678a25d594e61eb607ef2656be4a0'
SUITES = ['GuidedSyncCorrectionPolicyTests', 'GuidedSyncRepairEngineTests',
          'TripActivityCancellationTests', 'TrackedSprayCompletionSyncTests',
          'TripClosureStatusTests', 'SprayTankActualTests', 'TankDependencyVerificationTests']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others',
                                     '--exclude-standard', '-z', '--', 'ios']).decode().split('\0')
    files = []
    for name in sorted(set(names)):
        path = Path(name)
        if not path.is_file() or path.name == 'Config.swift':
            continue
        files.append({'path': name, 'sha256': digest(path)})
    manifest = DEST / 'corrected-ios-source-manifest.json'
    manifest.write_text(json.dumps(files, indent=2) + '\n')
    log = (DEST / 'github-original-native-failure.log').read_text()
    current_case = None
    crashes = []
    for line in log.splitlines():
        match = re.search(r"Test Case '-\[([^\]]+)\]' started", line)
        if match:
            current_case = match.group(1)
        if 'pointer being freed was not allocated' in line:
            crashes.append({'active_case': current_case, 'message': line})
    catalog = json.loads((DEST / 'live-backend-catalog.json').read_text())[0]['inspection']
    live = next(f['definition'] for f in catalog['functions']
                if f['name'] == 'reconcile_deleted_trip_activity_v1')
    source = Path('sql/283_reviewed_legacy_trip_application_attestation.sql').read_text()
    norm = lambda s: re.sub(r'\s+', ' ', s.split('$function$')[1]).strip()
    receipt = {
        'recorded_at': datetime.now(timezone.utc).isoformat(),
        'release_decision': 'HOLD: not all required validation and device acceptance gates passed',
        'pr': 52, 'requested_source_sha': PR_HEAD,
        'managed_head_before_automatic_sync': subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip(),
        'source_identity': 'PR52 exact twelve-file import plus targeted corrections; NOT exact PR head or a merged commit',
        'merge_sha': None, 'testflight_build': None, 'signed_source': None,
        'corrected_source_files': len(files), 'corrected_manifest_sha256': digest(manifest),
        'managed_native_results': [
            {'scope': 'original pinned PR52 applied files, seven suites', 'passed': 70, 'seconds': 166},
            {'scope': 'new engine regressions before fix', 'passed': 6, 'failed': 1,
             'failure': 'testUnresolvedCorrectionCannotMintCompetingOperationAfterReopen: XCTAssertThrowsError did not throw'},
            {'scope': 'corrected engine first checkpoint', 'passed': 7, 'seconds': 85},
            {'scope': 'final corrected seven-suite selection', 'passed': 74, 'seconds': 89,
             'selectors': ['VineTrackTests/' + s for s in SUITES]}],
        'managed_native_limitations': 'Aggregate runner results only; no final passing named XML/xcresult exposed. Counts are separate runs, not additive. Tests are simulator/unit selection, not live authenticated Guided Repair acceptance.',
        'normal_simulator_build': 'PASS via runChecks(appPath=ios); device Release/signing not verified; two existing asset URL notices',
        'github_native': {'run': 41581305846, 'job': 125736549423, 'head': PR_HEAD,
            'result': 'FAILURE', 'xcode': '26.3', 'malloc_abort_count': len(crashes),
            'crashes': crashes, 'artifact_id': 13207747948,
            'artifact_sha256': 'ce8218c87e30147b93d42ea109f50bf713f4b4dcf6fab562e47287d44bfd7b21',
            'underlying_cause': 'Not established; no blind rerun or unproven memory-management change'},
        'backend_verification': {
            'method': 'SELECT-only production function/grant/RLS/trigger catalog; no customer rows or repair RPC execution',
            'sql283_reconciliation_body_matches_deployment_whitespace_normalized': norm(live) == norm(source),
            'repair_rpc_authenticated_execute': True, 'repair_rpc_anon_execute': False,
            'relevant_tables_rls': {t['name']: t['rls'] for t in catalog['tables']},
            'critical_findings': [
                'Deployed tank-actual BEFORE UPDATE trigger requires a non-deleted parent Trip. Reconciliation deliberately starts from a deleted Trip and updates its live Actuals: static contract conflict would abort that transaction. No production mutation was used to demonstrate it.',
                'Deployed reconciliation replay validates operation/vineyard/classification but not actor, attestation or exact evidence. Do not claim stronger replay validation. Client now independently compares archive creator and exact frozen evidence before cleanup.',
                'Accepted Actual Use lost-response retry remains incomplete: original-vs-server quantity preflight can reject the already-accepted correction before the original operation is reconciled.',
                'Full authenticated disposable-record RPC, failure, offline/restart and account/vineyard acceptance remains required.']},
        'navigation': 'Source wiring confirmed: Backend Settings -> Sync Diagnostics -> Guided Repair; not tapped on a device.',
        'corrections': [
            'Freeze action-relevant review fields durably and resume the same unresolved operation; reject competing input fingerprints.',
            'Stable chemical dictionary fingerprints and pre-freeze field validation.',
            'Pin repair detail to its originating account/vineyard and discard stale inspection/verification; guard full-sync dispatch.',
            'Archive exact first-tank drafts and frozen request evidence before deleted-Trip RPC; verify disk readback.',
            'Require exact independent server compliance archive proof, matching receipt and original scope before local cleanup.',
            'Reject foreign-owner Actuals/drafts and changed retained Trip/Spray/tank/journal evidence; do not swallow queue-retirement failures.'],
        'open_gates': [
            'Resolve required Xcode26.3 native malloc failures and obtain a passing required workflow for the FINAL corrected commit.',
            'Review/correct backend trigger compatibility and replay contract, then validate on authorised disposable records; no backend deployment made here.',
            'Finish accepted-Actual lost-response reconciliation and legacy audits that lack frozen review fields.',
            'Add direct legacy archive/changed-evidence cleanup and scope-race integration coverage; current tests do not certify this new network cleanup path.',
            'Restore valid managed iOS service configuration: current Supabase URL was empty; configuration preserved.',
            'Original affected iPhone must complete repair in place with authoritative receipt; no uninstall, data clear or queue reset.',
            'After ALL gates, use authenticated PR integration, fresh ASC maximum and internal-only 3.1.9 build >=211; bind real merge/source/signing identity. No allocation/upload attempted.'],
        'preservation': {'android_changed': bool(subprocess.check_output(['git', 'diff', 'HEAD', '--', 'android-vinetrack'])),
            'production_records_mutated': False, 'repair_rpcs_invoked': False,
            'original_device_replayed_or_cleared': False, 'config_preserved': True,
            'historical_quantities_ids_evidence_changed': False,
            'git_checkout_commit_push_reset_used': False},
        'evidence_hashes': {n: digest(DEST / n) for n in ['source-application.json', 'live-backend-catalog.json',
                    'pre-fix-engine-failure.log', 'github-original-native-failure.log']}
    }
    (DEST / 'validation-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'files': len(files), 'manifest_sha256': digest(manifest),
                      'malloc_aborts': len(crashes), 'release': 'HOLD'}, indent=2))


if __name__ == '__main__':
    main()
