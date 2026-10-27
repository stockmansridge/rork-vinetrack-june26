#!/usr/bin/env python3
"""Bounded Debug host regressions; init/log/XML artifacts stay outside the workspace."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLASSES = [
    'ExactBytesDecodeMemoTest', 'RecoverySnapshotStoreTest', 'SyncRecoveryStorageTest',
    'SavedChemicalCreateSyncTest', 'SavedChemicalReconciliationTest',
    'RecoveryRefusalValidationTest', 'RecoveryPermitSafetyTest', 'SelectiveRecoveryReplayTest',
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output')
    args = parser.parse_args()
    output = Path(args.output) if args.output else Path(tempfile.mkdtemp(prefix='vinetrack-switch-regressions-'))
    output.mkdir(parents=True, exist_ok=True)
    init = output / 'selected-tests.init.gradle'
    includes = ', '.join("'**/" + name + ".kt'" for name in CLASSES)
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
    result = runner.run_stage('recovery-and-chemicals', ROOT / 'android-vinetrack',
                              ['*.' + name for name in CLASSES], output, init)
    (output / 'finished.json').write_text(json.dumps(result, indent=2))
    print(output)
    return result['exit']


if __name__ == '__main__':
    sys.exit(main())
