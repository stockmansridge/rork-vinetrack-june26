# Spray flow human-testing corrections - 30 October 2026

## Scope and source

Base: `50438333921355136fc8d81a375affc8a3334da0`.
This patch preserves the first-product recursion fix and existing Trip, Yield,
sync, permission and operational-start safeguards. It changes six mobile UI
files, updates three native UI-test files and adds a focused host/source suite.
No database, dependency, feature-gate, version or build-number change is made.
These corrections run in the normal production UI on iOS and Android.

## Corrections

1. **Operation selection:** an unanswered operation now reads "Tap to select
   operation" with a "Select operation" section summary. The iOS menu no
   longer checks the unconfirmed default. Choosing the same underlying Foliar
   Spray value still records the operator's deliberate decision.
2. **Pass layout:** row-equivalent information and controller help share a row.
   Redundant selected-pass text and the detached info row are removed. Both
   planning cards have full-width, consistent leading alignment and padding.
3. **Canopy progression:** "Confirm canopy" is a normal prominent action, not
   an orange warning-like panel. Acceptance produces a distinct checkmarked
   success state. The disabled Continue button explains "Confirm canopy above"
   when that is the actual blocker. Existing recommendation, volume-choice,
   custom-rate and other blocker controls remain wired to the real flow.
   Selecting canopy controls alone still does not accept an unchosen volume.
4. **Full Tank visibility:** the By Area / Only Full Tanks selector is visible
   for new drafts as well as prefilled ones. Existing inputs and model are
   reused. On iOS the displayed volume-basis selection follows the effective
   flow basis when switching from Manual to Full Tank; the underlying manual
   draft is not discarded.

The existing Full Tank operational restriction is NOT removed. A concise
"Planning only - Start Spray unavailable" explanation is shown when selected,
with additional detail behind the info button. This patch restores planning
visibility and input editing, not a new Full Tank execution or save/recovery
implementation. Do not claim end-to-end Full Tank Trip readiness.

Canopy tables, calculations, rate conversions, explicit confirmation rules,
CF warning policy, input validation and historical record handling are unchanged.
No Beta, System Admin, test-account or debug-only activation gate was added.

## Verification executed

- New source checks against the original source: **10 tests, 10 expected
  failures**, reproducing the missing presentation/wiring requirements.
- Final `python3 -m unittest discover -s scripts/tests -p
  test_spray_flow_human_testing.py -v`: **11 passed, no failures or skips**.
  Includes 10 source/wiring checks and one compiled host-model parity test:
  **212 Swift + 208 Kotlin scenarios**, with **16 canopy recommendations
  matching exactly** between platforms.
- Existing `python3 -m unittest discover -s scripts/tests -p
  test_spray_product_recursion.py -v`: **4 passed**, retaining the acyclic
  calculator dependency graph and **111 production-expression scenarios**.
- Modified Swift UI and UI-test files passed `swiftc -frontend -parse`.
- `git diff --check` passed.

The host suites use production model source with documented boundary stand-ins
and do not simulate native rendering. Swift parsing is not SDK type checking.
No Xcode/iOS app build, Android app build, native UI test, signed candidate or
physical-device acceptance was performed here. These remain required.

## Native regression coverage added (not executed here)

The existing iOS `MobileSprayUXParityUITests` and Android
`SprayPhase1CalculatorAndroidTest` journeys now assert the truthful initial
operation state, visible Full Tank option, explicit canopy acceptance and
separate spray-volume choice. Additional journeys cover Full Tank input
round-trips, Sprawl/High with L/100 m, and foliar Manual mode.
Android confirmation tests use stable tags to avoid matching the separate
blocker text. Both platforms' production confirmation controls remain unseeded
in the normal fresh-flow fixture.

## Rork integration and human acceptance

Integrate this PR onto current main, preserving any newer work. Do not reset
main to the base commit. Review the diff before one normal candidate build per
platform. Run only the affected native UI classes and relevant calculator,
planning and first-product regressions; avoid unrelated broad-suite churn.

On both platforms, with an ordinary authorized user:

1. Start a new spray. Confirm the operation placeholder is truthful and choose
   Foliar Spray without first changing to another operation.
2. Reach Canopy & Spray Volume. Check equal card alignment and inline pass help
   for Not Set, Single Row and 2 Row, including larger text sizes.
3. Select type, size and density; tap Confirm canopy. Check success state,
   recommendation and recommended/custom-output choice. Complete valid inputs
   and proceed to Products, then Review. Add first and second products without
   recurrence of the previous chemical-selection crash.
4. Repeat for VSP/Sprawl, Low/High, both hectare and row-length volume bases,
   recommended/custom output and Manual. Check invalid inputs stay blocked
   with their actual reason, and material canopy changes require reconfirmation.
5. Choose Only Full Tanks on a new draft, enter valid intended volume and area
   or calibrated rate, and verify calculation/retained inputs when switching
   back and forth. Confirm the operational restriction remains clearly shown.
6. Verify old drafts/templates and queued Trips retain their existing behaviour.

Record native test results, exact commit/build numbers and screenshots or video.
Do not publish to public store tracks or report human testing passed without
actual device evidence. These tests do not close the separate Issue #25 items.
