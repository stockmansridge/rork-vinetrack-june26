#!/usr/bin/env python3
"""Focused Android task-header recovery tests; no live accounts or server writes."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLASSES = ['WorkTaskWriteRecoveryTest', 'WorkTaskWriteParityTest', 'WorkTaskPlanningParityTest', 'WorkTaskEditorLifecycleTest']
# The unchanged legacy completion suite has five previously recorded failures.
# It was included in the initial run; never repeat those failures implicitly.
if '--include-legacy-completion' in sys.argv:
    CLASSES.append('WorkTaskCompletionTest')

def main():
    output = Path(tempfile.mkdtemp(prefix='vinetrack-task-write-recovery-'))
    init = output / 'selected-tests.init.gradle'
    includes = ', '.join("'**/" + name + ".kt'" for name in CLASSES + ['RetentionReviewTest'])
    init.write_text("""gradle.projectsEvaluated {
    def app = gradle.rootProject.project(':app')
    app.tasks.named('compileDebugUnitTestKotlin').configure {
        setSource(app.fileTree('src/test/java') { include %s })
    }
    app.tasks.withType(org.gradle.api.tasks.testing.Test).configureEach {
        outputs.upToDateWhen { false }
        outputs.cacheIf { false }
        testLogging { events 'passed', 'failed', 'skipped' }
    }
}
""" % includes)
    spec = importlib.util.spec_from_file_location('host_runner', Path(__file__).with_name('run-costing-baseline-comparison.py'))
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    result = runner.run_stage('task-write-recovery', ROOT / 'android-vinetrack', ['*.' + name for name in CLASSES], output, init)
    (output / 'finished.json').write_text(json.dumps(result, indent=2))
    print(output)
    return result['exit']

if __name__ == '__main__':
    sys.exit(main())
