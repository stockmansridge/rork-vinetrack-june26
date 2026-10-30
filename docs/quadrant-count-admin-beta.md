# Quadrant Count - System Admin testing only

## Scope

The existing **Start Bunch Count Trip** button opens a two-option selector for System Admins: **1. Bunches Per Vine Count**, **2. Quadrant Count**. Other users retain the original full-vine entry path. The full-vine entry forms and yield arithmetic are retained. No store release or customer enablement is included.

Quadrant Count reuses block selection, route generation, location/row capture, completion, durable local saves and replay. The separate input form defaults to **60 cm**, allows edits, shows block vine spacing and raw bunches, and supports minus/plus or numeric entry. Missing/invalid spacing blocks recording rather than assuming a value. Recorded samples retain their spacing snapshot when edited.

Each sample is normalized independently: **raw bunch count x vine spacing cm / section length cm**. The unrounded normalized value enters the existing bunches/vine average and Yield Estimate. Example: 12 bunches in 60 cm at 100 cm spacing = 20 bunches/vine. A second sample of 12 in 50 cm = 24; mean = 22, not a pooled-count estimate. Existing bunch-weight and damage rules remain unchanged.

## Additive payload

Session keys: `countMethod: "quadrant"`, `quadrantSectionLengthCm` (last section length, initially 60). Each `bunchCountEntry.quadrant` contains `rawBunchCount`, `sectionLengthCm`, `vineSpacingCm`, `calculationVersion: 1`. `bunchesPerVine` remains the existing normalized field. Legacy missing/null metadata stays full-vine. Counts must be finite nonnegative integers, lengths and spacing finite and positive. Zero bunches is valid.

Both platforms gate selection, raw capture and durable saves on the existing System Admin state. The database uses authoritative `public.is_system_admin()` on insert/update. Existing vineyard RLS remains in force. A trigger rejects nonadmin Quadrant writes, inconsistent normalization, changes of counting method on an existing trip, and old-client rewrites that would erase measurement evidence. New trips receive new identities. Rollout requires an explicit later change to these gates, not simply changing labels.

`sql/quadrant_count_admin_beta.sql` records the already-applied migration `quadrant_count_admin_beta` in project `tbafuqwruefgkbyxrxyb`. Do not reapply unless verifying a separate environment. No historical trip backfill or schema-column changes.

## Validation completed

`python scripts/test-quadrant-count.py`: **43 Swift and 34 Kotlin source-derived host checks passed**. Covers conversion/custom length, zero/invalid inputs, precision, per-sample averaging, current yield, method metadata, identity, completion, admin gates and durable-save rejection. Swift Codable roundtrip and legacy decode are included. The harness compiles production logic with host stubs; it is not a native app build or an Android serialization integration test. Swift Yield UI source parsing also passed; parsing is not SwiftUI typechecking.

Nine live backend checks passed in a rolled-back transaction using temporary probe tables: legacy write, Android null metadata, nonadmin insert denial, admin insert/replay, normalized-count rejection, metadata-stripping rejection, zero-length rejection, method immutability, nonadmin update denial. No customer sample records were changed. The security advisor reported no new finding for this change; existing unrelated findings were not modified.

## Required human acceptance before releasing the gate

Build both native apps from the exact feature commit; no unrelated source edits. Verify an admin sees both options and a nonadmin only the original path. Run the old full-vine trip unchanged. On a test block with 1 m spacing, record 12 bunches at 60 cm (20/vine), then at 50 cm (24/vine); confirm mean 22, raw values, method label and existing bunch-weight calculation. Test zero bunches and missing spacing. Pause/restart offline, resume the same trip and sync without duplicates; confirm raw measurements survive device/platform roundtrips. Confirm an older client cannot overwrite Quadrant records, while full-vine trips still save. Test loss of admin access and local save failure. Keep testing records away from production yield decisions because normalized estimates intentionally enter the existing estimate flow.

Full iOS/Android builds, device UI tests and offline force-quit acceptance are still outstanding. No version/build number or release settings changed.
