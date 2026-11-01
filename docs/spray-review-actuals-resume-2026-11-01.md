# Spray review actual quantities and in-progress resume repair

## Status

Source repair for iOS and Android, based on `f8d36eec3298071b92cb0d653e3b74d0d27ecc12`.
The repair was verified against `7947edc7d52ee483288783525b54b112c11d1581`;
the newer base adds recovery documentation, evidence and isolated test fixtures
without changing either application's source or overlapping this repair.
Host runtime and source checks pass. Native application builds, native UI tests,
and acceptance on the affected phones remain outstanding. This change does not
upload a TestFlight or Google Play build.

## Reported failures and correction

The iOS Review Spray Mix confirmation acknowledged calculated rates but did not
provide actual quantity inputs. Its Boolean sheet presentation could expose an
empty pending recipe until another state change, such as path selection. Both
new and saved iOS reviews now carry their recipe in one presentation item.

Review shows calculated quantities as a guide, followed by blank fields for the
first physical tank's actual water and every chemical amount. These fields are
available before path setup. Path changes do not reset them. Water must be
positive and finite; every chemical must have an explicit finite amount, with
zero meaning the operator did not add that product. Later tanks keep their
existing per-fill workflow.

Entered quantities are retained separately from the planned recipe, then
committed through the existing actual-tank/session coordinator. A missing field
cannot fall back to a calculated quantity. The draft is consumed only after the
matching actual and tank session are durable. Interrupted attempts retain the
original trip, record, session and quantities; tracking waits for that first
actual confirmation. In the new iOS calculator review, a refusal before durable
preparation keeps the entries editable for retry. A saved-job review retains its
submitted amounts for retry; dismiss and reopen that review to edit them after a
preflight refusal.

Android had the same read-only rate acknowledgement and now uses the same
explicit actual-entry semantics. Its existing actuals cache has an additive
draft field. The recovery classifier accepts old caches and classifies the new
field with the original-owner and vineyard-membership requirements intact.

The iOS In Progress picker incorrectly opened the not-started activation sheet.
It now opens the existing active trip for the owning device/account. A synced
active trip without local ownership opens its existing details with an explicit
explanation. It never creates a replacement, resets the start time or takes
control from another device. Android already routes this picker to the existing
trip.

## Data contract

- Planned `SprayRecord.tanks` and calculation geometry remain unchanged.
- Confirmed quantities use the existing actual-tank records and exact tank-session link.
- A review draft is not an actual record and does not claim completion of future tanks.
- Existing reports can resolve actual quantities through their existing actual/session contract.
- No database migration, backend deployment, release-version edit or new feature gate is part of this repair.

## Verification performed

| Selection | Result | Boundary |
| --- | --- | --- |
| Swift actual input, regional conversion, cache, actual resolver and interrupted tank commit | 76 checks passed | Production logic; explicit platform, transport and JSON-I/O doubles |
| Android actual input, draft storage and tank commit coordinator | 33 tests passed | Production logic; explicit Android/auth/Trip-container doubles |
| Android retained-cache ownership classifier | 13 scenarios passed | Production classifier and serializers; explicit Android/filesystem/unrelated-store doubles |
| Actual-entry wiring, resume routing, existing spray flow and trip/yield wiring | 33 checks passed | Source wiring only |
| Changed Swift files | Syntax parsing passed | Swift 6.2.1; does not type-check SwiftUI against the Apple SDK |
| Changed Kotlin files | Syntax parsing passed | Compiler PSI; does not substitute for an Android build |
| Whitespace/error-marker review | `git diff --check` passed | Source diff |

Reproducible host runners:

```text
scripts/test-spray-review-actuals-host.py
scripts/test-spray-actuals-host.py
scripts/test-spray-draft-recovery-host.py
scripts/tests/test_spray_review_actuals_wiring.py
scripts/tests/test_spray_resume_routing.py
```

## Native verification required in Rork

Import the exact GitHub repair revision supplied with the handoff and verify its
changed source files. Include the new test files explicitly in discovery. Run
the normal iOS simulator and Android builds before producing device candidates.
The host results above must not be described as native build or handset results.

Relevant native selections include:

- iOS: `SprayInitialTankAmountsTests`, `SprayProgramResumeRouteTests`,
  `StartTankCommitCoordinatorTests`, `SprayTankActualTests`,
  `SprayTripPhase5FinalisationTests`, `SprayReportPayloadV1Tests`,
  `SprayStartPresentationTests`, and `SprayOperationalBundleTests`.
- iOS UI: `SprayEditingAcceptanceUITests` and `MobileSprayUXParityUITests`.
- Android: `SprayStartActualAmountsTest`, `SprayActualInputDraftStoreTest`,
  `StartTankCommitCoordinatorTest`, `AuthRetentionAndroidTest`,
  `SprayFieldLayoutAndroidTest`, and `SprayStartProductionAndroidTest`.

## Phone acceptance

1. Use a synthetic spray with a calculated tank of 294.7 L water and 0.70 kg of
   a product. Open Review. Before choosing a path, enter 300 L and 0.75 kg.
2. Select or change the path. Both entered amounts must stay unchanged and
   editable until Start is submitted. Leaving a field blank must keep Start
   unavailable; explicitly entering zero for a product records it as not added.
3. Start the spray. Confirm one original trip and one first-tank session, with
   actual water 300 L and actual chemical 750 g in canonical storage. The planned
   values must remain 294.7 L and 700 g. Check the tank details, synced actual row
   and exported report agree on planned versus actual quantities.
4. With a multiple-tank plan, confirm that future tanks are not marked actual or
   complete. Record the next tank through the normal per-fill flow.
5. Repeat through an original saved Not Started job. Simulate a failed local
   write or interrupted activation in an isolated fixture, reopen, and recover
   the same trip/session and entered quantities without a duplicate start.
6. From Resume a Spray Program, open an In Progress trip started on that phone.
   Its active screen must open directly, preserving the original time, pause
   state, path and tank records. An active trip owned elsewhere must explain why
   this phone cannot control it, without presenting an ineffective Start button.
7. On Android, verify old retained caches and new input drafts during update and
   close/reopen. Preserve the separate ongoing recovery incident's device data
   and require its own original-device acceptance; this spray repair does not
   establish that the unrelated recovery incident is resolved.

Do not submit production store releases or alter backend data as part of this
verification. Report exact source revision, build identifiers, discovered test
counts, outcomes and remaining device checks.
