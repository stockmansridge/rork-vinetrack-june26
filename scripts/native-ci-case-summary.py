#!/usr/bin/env python3
"""Summarise an xcodebuild XCTest log per suite: started / passed / failed / crashed.

A case is "crashed" when it logged `started` but neither `passed` nor `failed`: the test
process died (SIGABRT, signal, timeout) and xcodebuild restarted it. A run whose
`crashed` column is not all zero is NOT a pass, even when the final xcodebuild summary
looks clean, because restarts hide the lost cases.

Usage:
    python3 scripts/native-ci-case-summary.py <xcodebuild-log> [--expect-suites N] [--expect-cases N]

Exit code 0 only when there are no failed and no crashed cases (and the optional
expectations hold). Used to compare GitHub native-replay logs, e.g.
docs/reviews/evidence/ios-trip-end-native-ci-crash-20261103/NATIVE-CI-DIAGNOSIS.md.
"""
import argparse
import collections
import re
import sys

CASE = re.compile(r"Test Case '-\[(\S+) (\w+)\]' (started|passed|failed)")
RESTART = "Restarting after unexpected exit, crash, or test timeout"
ABORT = re.compile(r"malloc: \*\*\* error for object \S+: pointer being freed was not allocated")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    parser.add_argument("--expect-suites", type=int)
    parser.add_argument("--expect-cases", type=int)
    args = parser.parse_args()

    with open(args.log, errors="replace") as handle:
        text = handle.read()

    seen = {"started": set(), "passed": set(), "failed": set()}
    for suite, case, event in CASE.findall(text):
        seen[event].add((suite, case))

    crashed = seen["started"] - seen["passed"] - seen["failed"]
    suites = sorted({suite for suite, _ in seen["started"]})
    count = {event: collections.Counter(s for s, _ in cases) for event, cases in seen.items()}
    lost = collections.Counter(s for s, _ in crashed)

    print(f"{'suite':<58} {'started':>7} {'passed':>6} {'failed':>6} {'crashed':>7}")
    for suite in suites:
        print(f"{suite:<58} {count['started'][suite]:>7} {count['passed'][suite]:>6} "
              f"{count['failed'][suite]:>6} {lost[suite]:>7}")
    print(f"{'TOTAL':<58} {len(seen['started']):>7} {len(seen['passed']):>6} "
          f"{len(seen['failed']):>6} {len(crashed):>7}")
    print(f"runner restarts logged: {text.count(RESTART)}; malloc 'pointer being freed' aborts logged: "
          f"{len(ABORT.findall(text))}")

    ok = not seen["failed"] and not crashed
    if args.expect_suites is not None and len(suites) != args.expect_suites:
        print(f"EXPECTATION FAILED: {len(suites)} suites, expected {args.expect_suites}")
        ok = False
    if args.expect_cases is not None and len(seen["started"]) != args.expect_cases:
        print(f"EXPECTATION FAILED: {len(seen['started'])} cases, expected {args.expect_cases}")
        ok = False
    print("RESULT:", "CLEAN (no failed, no crashed cases)" if ok else "NOT CLEAN")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
