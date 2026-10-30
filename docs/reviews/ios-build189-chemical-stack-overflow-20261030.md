# Build 189 chemical-selection stack overflow - 30 October 2026

## Evidence and scope

Two customer reports: VineTrack 3.1.9 (189), arm64, 30 October 2026 at 17:26:40 and 22:06:47 +1100. Both report `Thread stack size exceeded`, `EXC_BAD_ACCESS/SIGSEGV`, thread 0/main-thread Stack Guard, and the same repeated app image offsets 11291424 / 11297652. Both app binaries have UUID `427604DE-2A8C-34E4-8744-979847C2C1E1`.

The repeated offsets demonstrate the same recursion signature across two launches. `SecItemCopyMatching` is the deepest system call at exhaustion; this does NOT establish a Keychain defect and is not a reason to reset authentication, remove credentials or change database access.

The app frames are NOT symbolicated here. Use the matching build 189 archive/dSYM to confirm the exact compiled function/line mapping. Current main is source evidence, not a certified source manifest for the installed binary.

## Confirmed source cycle

Verified at main `13f412660355939343d716fe46aa4354c6068d7f`:
- `SprayCalculatorView.flow` builds `SprayGuidedFlow(inputs: guidedInputs, ...)`.
- `guidedInputs` sets `inputs.products = guidedProductLines`.
- `guidedProductLines` reads `flow.requiresBandWidth` while choosing a product's default area basis.
- This recursively constructs another flow and enters the same product projection. With no product the map body does not run. A new/template spray's first resolved product without an area override triggers it, including per-100 L lines because the flow read precedes the rate-basis check.
- `SprayGuidedFlow.requiresBandWidth` is only `inputs.operationType == .bandedSpray`.

Production fix: replace that single `flow.requiresBandWidth` dependency inside `guidedProductLines` with `operationType == .bandedSpray`. Keep explicit overrides, new/template banded per-ha treated-area default, historical whole-block fallback, and per-100 L semantics unchanged. No picker redesign, dose arithmetic, Keychain, Supabase, Android, Trip, queue, yield, permission, dependency or release-counter changes.

Verified source blobs before correction:
- SprayCalculatorView.swift: `b91ea21a82bf9ed730f46dee1fb57e14bf811db0`
- SprayGuidedFlow.swift: `0c0a805bf416cc8a67d7a213709afb37dfd24c88`

## Executed validation

`python3 -m unittest discover -s scripts/tests -p test_spray_product_recursion.py -v`

Before production change: 1 passed / 3 failed. The source graph identified `flow -> guidedInputs -> guidedProductLines -> flow`; the Swift host probe using the exact production area-selection fragment exited with the controlled recursion sentinel 86. The host intentionally bounds recursion instead of exhausting its stack.

After correction: 4 passed, no failures/skips. The Swift host ran 111 scenarios: empty list, five operation cases x three prefill states x two chemical rate bases x three override states, and twenty repeated two-product builds. These assert unchanged resolved/explicit area bases and one flow construction per evaluation. UI, store and model boundaries are synthetic; this is NOT an iPhone, SwiftUI rendering or full-dose-engine test.

Modified production Swift syntax parse passed with `swiftc -frontend -parse`. Initial development of the source-graph check falsely counted a foreign object's member as a local dependency; the matcher was corrected BEFORE the recorded failing-before/fixed-after selection above. This was a test issue, not another production change.

## Native acceptance required before shipping

Preserve current main work, including PR #23 yield/Trip fixes. Do not replace main with the older picker-only PR #21.

1. Use build 189's matching archive/dSYM to symbolicate the repeated frames. Record the function names; do not assign names from offsets alone.
2. Run the four source/host checks above with Swift available.
3. Run existing native `MobileSprayUXParityUITests` journeys that actually SELECT a product: `testPhase2RecommendedToReview`, `testPhase2CustomToReview`, `testPhase2BandedToReview`, and `testPhase2SpreaderToReview`. A test that only opens the picker or unlocks Products is not adequate.
4. Add/check first and second products, per-ha and per-100 L, cancellation/reselection, original manual overrides, template and saved historical basis preservation. Confirm Products and Review render and the app remains in foreground. No real Trip must be activated for these checks.
5. Run focused existing calculator/area-basis tests, then one normal iOS build. Do not run unrelated Android/Supabase changes or unnecessary broad builds.
6. Install the new signed candidate over the existing app; retain local data. Original-device chemical-selection acceptance remains mandatory. Do not call the incident resolved on compilation or these host tests alone.

## Symbolication handoff

Apple guidance: https://developer.apple.com/documentation/xcode/adding-identifiable-symbol-names-to-a-crash-report

Check UUID first:

```sh
dwarfdump --uuid /path/to/VineTrack.app.dSYM/Contents/Resources/DWARF/VineTrack
```

It must match `427604DE-2A8C-34E4-8744-979847C2C1E1` (arm64). A newly compiled dSYM is not interchangeable.

For the SECOND report (22:06:47), image base decimal 4338565120 = `0x102994000`:

```sh
atos -arch arm64 \
  -o /path/to/VineTrack.app.dSYM/Contents/Resources/DWARF/VineTrack \
  -l 0x102994000 \
  0x103458b08 0x103458b20 0x10345a374 \
  0x10334ec2c 0x10334f22c 0x103351568 \
  0x10345ffc4 0x10345f77c 0x103501e38
```

For the FIRST report (17:26:40), base `0x100350000` and repeated addresses `0x100e14b20`, `0x100e16374`. Do not mix one report's load address with another report's absolute addresses.

Full customer crash logs and device/vendor identifiers are deliberately not committed.
