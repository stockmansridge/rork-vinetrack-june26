#!/usr/bin/env python3
"""Execute only Android current shared-weight/tonnes parity, preserving baseline failures."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
output = Path(tempfile.mkdtemp(prefix='vinetrack-pr23-yield-host-'))
init = output / 'selected-tests.init.gradle'
init.write_text("""gradle.projectsEvaluated {
    def app = gradle.rootProject.project(':app')
    app.tasks.named('compileDebugUnitTestKotlin').configure {
        setSource(app.fileTree('src/test/java') { include '**/CurrentYieldMasterParityTest.kt' })
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
result = runner.run_stage('yield-parity', ROOT / 'android-vinetrack', ['*.CurrentYieldMasterParityTest'], output, init)
(output / 'finished.json').write_text(json.dumps(result, indent=2))
print(output)
if result['exit'] == 0 and (len(result['suites']) != 1 or result['totals']['tests'] != 15):
    raise RuntimeError('Unexpected discovery count; do not report this as the requested selection passing')
sys.exit(result['exit'])
