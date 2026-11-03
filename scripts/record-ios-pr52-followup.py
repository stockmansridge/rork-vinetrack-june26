"""Record observed follow-up results without overwriting historical checkpoints.

No production calls, credential reads, Git mutation or customer data. Tool results
are transcribed explicitly; stale failure logs are never labelled passing logs.
"""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
import re
import subprocess

DEST = Path('docs/reviews/evidence/ios-pr52-guided-repair-20261103')
SUITES = ['GuidedSyncCorrectionPolicyTests', 'GuidedSyncRepairEngineTests',
          'TripActivityCancellationTests', 'TrackedSprayCompletionSyncTests',
          'TripClosureStatusTests', 'SprayTankActualTests', 'TankDependencyVerificationTests']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    receipt_path = DEST / 'followup-validation-receipt.json'
    manifest_path = DEST / 'followup-source-manifest.json'
    if receipt_path.exists() or manifest_path.exists():
        raise SystemExit('Refusing to overwrite a checkpoint')
    before = json.loads((DEST / 'live-backend-expanded-catalog.json').read_text())[0]['inspection']
    after = json.loads((DEST / 'live-backend-after-sql284.json').read_text())[0]['inspection']
    old_functions = {f['identity']: f for f in before['functions']}
    changed = []
    final_hashes = {}
    expected = {'spray_tank_actuals_before_write': '2c361a16b999b3b05fb769d9c5558ec5',
                'reconcile_deleted_trip_activity_v1': 'b0800f82f1e869cb68b0dc01cfc43b92'}
    for function in after['functions']:
        previous = old_functions[function['identity']]
        assert {k: v for k, v in previous.items() if k != 'definition'} == {
            k: v for k, v in function.items() if k != 'definition'}, 'Function security/grant drift'
        if previous['definition'] != function['definition']:
            changed.append(function['name'])
        if function['name'] in expected:
            value = hashlib.md5(function['definition'].encode()).hexdigest()
            assert value == expected[function['name']], 'Unexpected deployed function definition'
            final_hashes[function['name']] = value
    assert sorted(changed) == sorted(expected), changed
    assert before['tables'] == after['tables'], 'RLS/grant/trigger drift'
    assert before['columns'] == after['columns'], 'Column drift'

    # Retain the actual historical catalog bytes used by the earlier receipt.
    historical = DEST / 'historical-managed-checkpoint-catalog.json'
    if historical.exists():
        raise SystemExit('Historical catalog already retained')
    historical.write_bytes(subprocess.check_output([
        'git', 'show', 'HEAD:' + str(DEST / 'live-backend-catalog.json')]))
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others',
        '--exclude-standard', '-z', '--', 'ios', '.github/workflows/ios-guided-sync-repair-native.yml',
        'sql/284_guided_repair_archived_actual_tombstone_contract.sql',
        'sql/tests/284_guided_repair_contract_tests.sql', 'scripts/test-pr52-postgres-contract.py',
        'scripts/inspect-pr52-backend.py', 'scripts/record-ios-pr52-followup.py']).decode().split('\0')
    files = [{'path': str(path), 'sha256': digest(path)} for path in
             sorted({Path(p) for p in paths if p}) if path.is_file() and path.name != 'Config.swift']
    manifest_path.write_text(json.dumps(files, indent=2) + '\n')
    public = json.loads(Path('/tmp/pr52-final-public.json').read_text())
    config = Path('ios/VineTrack/Config.swift').read_text()
    url = re.search(r'EXPO_PUBLIC_SUPABASE_URL\s*=\s*"([^"]*)"', config)
    android = subprocess.check_output(['git', 'diff', 'HEAD', '--', 'android-vinetrack'])
    evidence = ['legacy-audit-pre-fix-failure.log', 'amendment-reentrancy-pre-fix-failure.log',
                'local-postgres-contract-first-pass.log', 'local-postgres-expanded-fixture-syntax-failure.log',
                'local-postgres-expanded-contract-pass.log', 'live-backend-expanded-catalog.json',
                'live-backend-after-sql284.json', historical.name]
    receipt = {
        'recorded_at': datetime.now(timezone.utc).isoformat(),
        'decision': 'HOLD: no merge or TestFlight; not original-iPhone acceptance',
        'managed_head_before_automatic_sync': subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip(),
        'source_manifest': str(manifest_path), 'source_manifest_sha256': digest(manifest_path),
        'source_file_count': len(files), 'source_identity': 'Corrected workspace, not published PR head or merge',
        'public_pr': {'number': 52, 'state': public['state'], 'merged': public['merged'],
                      'head': public['head']['sha'], 'base': public['base']['sha']},
        'native_results': [
            {'selection': 'legacy audit regression before correction', 'passed': 0, 'failed': 1},
            {'selection': 'previous two-suite checkpoint', 'passed': 26, 'seconds': 82,
             'raw_log': 'Not retained before next run overwrote the temporary path; terminal tool response only'},
            {'selection': 'reentrant amendment regression before guard', 'passed': 0, 'failed': 1,
             'raw_log': 'amendment-reentrancy-pre-fix-failure.log'},
            {'selection': ['VineTrackTests/' + s for s in SUITES], 'passed': 82, 'seconds': 78,
             'result': 'PASS from terminal swiftTest response',
             'raw_log': 'Runner temporary path still contains prior failing run; not relabelled or copied as passing'}],
        'native_limitations': 'Separate runs, not additive. No passing named XML/xcresult exposed. Simulator tests are not live HTTP, original device, physical process death or Portal acceptance.',
        'normal_build': {'result': 'PASS', 'tool': 'runChecks', 'appPath': 'ios',
                         'device_release_verified': False, 'existing_asset_url_notices': 2},
        'backend_migration': {
            'tool': 'runMigration', 'name': '284-guided-repair-archived-actual-tombstone-contract',
            'tool_response': 'Migration applied successfully. TypeScript types updated.',
            'sql_sha256': digest(Path('sql/284_guided_repair_archived_actual_tombstone_contract.sql')),
            'live_post_deployment_catalog_at': after['captured_at'],
            'verified_final_function_md5': final_hashes, 'only_expected_definitions_changed': True,
            'inspected_rls_grants_trigger_declarations_and_columns_unchanged': True,
            'repair_rpcs_invoked': False, 'customer_rows_read_or_mutated': False,
            'local_contract': 'PASS: exact deployed-function baseline failure reproduced, rollback retains originals; corrected/idempotent migration and expanded negatives pass',
            'local_fixture_failure': 'First expanded run failed SQL fixture compilation due nested dollar quoting; corrected delimiter, rerun passed. Not an application/backend regression.',
            'limitations': 'Disposable local reduced schema, not production FK/RLS/concurrency/HTTP or original-device acceptance'},
        'corrections': [
            'Hold older unresolved audits without frozen inputs; preserve original operation.',
            'Durably freeze accepted-Actual amendment payload/version before dispatch and reconcile entire original receipt ledger before old-quantity comparison.',
            'Verify exact receipt actor, scope, version and all before/after water/chemical rows; reject missing/duplicate/conflicting evidence.',
            'Guard in-flight operation and Actual across MainActor awaits; release guard after failures without deleting frozen inputs.',
            'Preserve failed requests through repository reopen and post-send scope changes; encode nullable RPC water explicitly.',
            'Use documented async XCTest workaround in affected persistence/completion cases; Xcode26.3 crash cause not proven.',
            'Narrow archived-OLD tombstone exception and exact reviewed replay checks deployed with exact-definition guards.',
            'Required workflow now selects all seven suites and triggers for corrected completion tests and SQL contract files.'],
        'open_gates': [
            'Authenticated managed publication to existing PR branch unavailable; public SHA unchanged.',
            'Required Xcode26.3 workflow must pass on final published SHA; original run41581305846 remains FAILURE.',
            'Direct retained-first-tank archive/changed-evidence/cleanup integration coverage incomplete.',
            'Valid managed iOS service configuration and authenticated disposable-record offline/retry/account/vineyard/HTTP acceptance incomplete.',
            'Real merge SHA, fresh ASC maximum, source-bound signed internal TestFlight >=211 not produced.',
            'Affected original iPhone must repair in place with authoritative server receipt.'],
        'configuration': {'managed_config_preserved': True, 'supabase_url_literal_empty': None if url is None else not bool(url.group(1))},
        'preservation': {'android_changed': bool(android), 'customer_original_replay': False,
                         'data_clear_uninstall_or_queue_reset': False, 'manual_git_mutation': False,
                         'public_external_release': False},
        'historical_receipt_note': 'validation-receipt.json and corrected-ios-source-manifest.json remain historical checkpoints, not current-source receipts. live-backend-catalog.json was refreshed before no-overwrite protection; original managed bytes retained separately here.',
        'evidence_sha256': {name: digest(DEST / name) for name in evidence}
    }
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'decision': receipt['decision'], 'source_files': len(files),
                      'source_manifest_sha256': digest(manifest_path), 'backend_hashes': final_hashes,
                      'android_changed': bool(android)}, indent=2))


if __name__ == '__main__':
    main()
