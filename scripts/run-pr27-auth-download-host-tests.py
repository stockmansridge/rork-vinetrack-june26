#!/usr/bin/env python3
"""Run bounded PR27 JSON/download/session host tests with fresh XML evidence."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLASSES = [
    'RefreshRejectionLegacyTest', 'SyncDownloadStatusTest', 'HomeSyncStatusTest',
    'SessionLifecycleContractTest', 'SessionRefreshAdmissionTest',
]
output = Path(tempfile.mkdtemp(prefix='vinetrack-pr27-auth-download-'))
init = output / 'selected-tests.init.gradle'
patterns = '; '.join("include '**/" + name + ".kt'" for name in CLASSES)
init.write_text("""gradle.projectsEvaluated {
    def app = gradle.rootProject.project(':app')
    app.tasks.named('compileDebugUnitTestKotlin').configure {
        setSource(app.fileTree('src/test/java') { """ + patterns + """ })
    }
    app.tasks.withType(org.gradle.api.tasks.testing.Test).configureEach {
        outputs.upToDateWhen { false }
        outputs.cacheIf { false }
        testLogging { events 'passed', 'failed', 'skipped' }
    }
}
""")
spec = importlib.util.spec_from_file_location('host_runner', ROOT / 'scripts/run-costing-baseline-comparison.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
result = runner.run_stage('auth-download', ROOT / 'android-vinetrack', ['*.' + name for name in CLASSES], output, init)
(output / 'finished.json').write_text(json.dumps(result, indent=2))
print(output)
if result['exit'] == 0 and (len(result['suites']) != len(CLASSES) or result['totals']['tests'] == 0):
    raise RuntimeError('Unexpected discovery; requested selection is not verified')
sys.exit(result['exit'])
