"""Record bounded P0 evidence without claiming installed-source or server acceptance.
Reads Git and GitHub only; never stages, commits, deploys or accesses credentials.
"""
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/reviews/evidence/p0-trip-start'
OUT.mkdir(parents=True, exist_ok=True)
def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()
def sha(path):
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
def api(path):
    req = urllib.request.Request('https://api.github.com/repos/stockmansridge/rork-vinetrack-june26/' + path,
                                 headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'VineTrack-source-audit'})
    with urllib.request.urlopen(req, timeout=40) as response:
        return json.load(response)

paths = set(git('diff', 'HEAD', '--name-only').splitlines())
paths.update(['android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/IndependentQualifiedSprayStart.kt',
              'android-vinetrack/app/src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt',
              'sql/occurrence_setup_uuid_case_identity.sql',
              'sql/occurrence_setup_uuid_case_identity_verify.sql'])
paths = sorted(p for p in paths if p.startswith(('android-vinetrack/app/src/', 'ios/VineTrack/', 'ios/VineTrackTests/', 'sql/')) and (ROOT / p).is_file())
result = {
    'recordedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'incident': 'OPEN', 'release': 'BLOCKED_NO_UPLOAD_OR_PUBLIC_RELEASE',
    'managedBaseCommit': git('rev-parse', 'HEAD'),
    'sourceIdentityNote': 'Working-tree hashes identify the changed source; base commit is not a claim that uncommitted edits are already installed or published.',
    'sourceSha256': {p: sha(p) for p in paths},
    'installedBuildToSource': 'UNVERIFIED_BOTH_PLATFORMS',
    'builds': {'android': 'runChecks PASS; no signed candidate/build receipt returned',
               'ios': 'runChecks simulator PASS; device/Release build not verified'},
    'androidInstrumentation': {'status': 'INFRA_FAILED', 'passed': 0, 'failed': 0, 'skipped': 0,
        'reason': 'Two distinct androidTest selections each timed out after 600 seconds: original class, then two new focused boundary methods. Both returned zero execution results. No further retry.',
        'newBoundaryFixtures': 'Two new production-entry regressions compiled with compileDebugAndroidTestKotlin; narrowed execution attempt also infrastructure-timed-out, so NOT VERIFIED on emulator/device'},
    'swiftSelected': {'status': 'PASS', 'aggregatePassed': 3, 'durationSeconds': 108,
        'selectors': ['SprayOccurrenceRecoveryHotfixTests/testNewStartPreflightDoesNotMintJournalForHistoricalTripAndStillBlocksUncertainCreate',
                      'TripDeletionRecoveryTests/scopedIssueExportPreservesRegistryAndExcludesRawAndForeignEvidence()',
                      'TripDeletionRecoveryTests/pendingUploadInspectionIncludesQueueWithNoRecordedFailureAndPreservesIt()'],
        'limit': 'Aggregate tool receipt only, not per-case xcresult export, no handset workflow. Earlier one-pass selection overlaps; do not sum.'},
    'androidHostSuites': [],
    'backend': {'project': 'tbafuqwruefgkbyxrxyb', 'repairSourceSha256': sha('sql/occurrence_setup_uuid_case_identity.sql'),
        'deployment': 'NOT_ATTEMPTED_THIS_PASS; existing authorised function-owner path required',
        'verificationHandoff': 'sql/occurrence_setup_uuid_case_identity_verify.sql is read-only source, NOT EXECUTED; capture before/after owner-authorised repair and compare owner/security/ACL/search-path',
        'liveDefinitionMD5': 'NOT_FRESHLY_READ; user reports b0e166d78be75c8ba770b',
        'originalTripOperationReceipts': 'UNKNOWN; one earlier logged rejected call cannot establish all retained outcomes'},
    'diagnosticCoverage': {'status': 'PARTIAL',
        'implemented': ['Scoped Trip/spray/session/actual IDs and retained occurrence operation IDs',
            'Explicit unknown source/current-server/last-ack states; no inferred receipts',
            'Separate visible unique queued Trips from outbox/issues/handoffs; no false global sum',
            'No journal-directory creation in iOS preflight or inspection',
            'No decode-evidence writes in occurrence inspection',
            'Scoped fixed-code issue export with observed failure timestamps; no raw errors/payloads',
            'Android access inspection does not persist cache-derived holds'],
        'remaining': ['Complete orphan-journal discovery without changing evidence',
            'All saved-job/actual-draft/correction queues per-record coverage',
            'Exact cross-category global reconciliation on both original installations',
            'Verified immutable build-to-source receipts in exports',
            'Authoritative original server existence/receipt correlation',
            'Full transport-attempt/ack history where existing formats did not persist it']},
    'remainingGates': ['Authorised backend repair and live definition/security/ACL verification',
        'Original Cab Franc Trip/create/activate IDs and correlated authoritative records/receipts',
        'Production Android independent-start unchanged-journal execution (compiled, not run)',
        'Safe iOS independent-start proof; unresolved-create gate remains fail-closed',
        'Complete retained operational/network/account/access matrix and both original handsets after reopen',
        'Final source-matched signed candidate identity and explicit acceptance before any upload'],
    'safety': 'No customer mutation, journal removal, ownership/privilege change, quantity edits or store upload performed'
}
for name in ['com.rork.vinetrack.ui.IndependentQualifiedSprayStartTest', 'com.rork.vinetrack.data.VineyardWriteAuthorityTest']:
    path = ROOT / 'android-vinetrack/app/build/test-results/testDebugUnitTest' / ('TEST-' + name + '.xml')
    if path.exists():
        suite = ET.parse(path).getroot()
        result['androidHostSuites'].append({'attributes': suite.attrib, 'cases': [case.attrib for case in suite.findall('testcase')]})
        (OUT / path.name).write_bytes(path.read_bytes())
try:
    main = api('branches/main')['commit']['sha']
    result['publicMainObserved'] = main
    result['pullRequestsObserved'] = []
    for number in (29, 31, 33, 37):
        pr = api(f'pulls/{number}')
        result['pullRequestsObserved'].append({'number': number, 'head': pr['head']['sha'], 'base': pr['base']['sha'],
            'state': pr['state'], 'merged': pr['merged']})
except Exception as error:
    result['publicRefreshFailure'] = type(error).__name__
result['overlapReview'] = [
    'Earlier file-equality audit remains historical; it is not a complete hunk audit or installed-build receipt.',
    'PR29 start-actual validation and commit survive the PR37 start routing hunk; saved source is explicitly passed by calculator.',
    'PR37 only skips legacy retainedStart lookup for new qualified routes; account/vineyard, unresolved occurrence and device-active guards remain.',
    'iOS retains PR31 initial-mix/recovery flow and PR33 explicit-null water and exact-revision acknowledgement; newest edits affect inspection and preflight directory side effects, not receipt admission.',
    'SQL repair source matches reviewed PR31; deployment is not established by source equality.',
    'Exhaustive hunk equivalence and final public-main equality still require a completed final source comparison.'
]
(OUT / 'validation-current.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'managedBaseCommit': result['managedBaseCommit'], 'publicMainObserved': result.get('publicMainObserved'),
                  'hostSuites': [s['attributes'] for s in result['androidHostSuites']],
                  'evidence': str((OUT / 'validation-current.json').relative_to(ROOT))}, indent=2))
