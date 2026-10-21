# Core pin-location contract

Permanent contract for how VineTrack decides, stores, and shows where a pin is.
Any change touching pin capture, GPS, rows, trips, sync, maps or pin
presentation must reference this document and run the focused production-path
pin suites on both changed platforms. Those suites are a required check for pin
changes and cover outside-trip Left/Right, opposite facing, delayed confirmation,
restart/replay, raw-coordinate survival and list/detail agreement. A green build
or successful compilation alone does not demonstrate these behaviours.

Implementations (one shared contract, two platforms):

| Concern | iOS | Android |
| --- | --- | --- |
| Aisle + heading-aware side geometry | `App/PinAisleGeometry.swift` | `data/PinAisleGeometry.kt` |
| Automatic capture resolver | `App/PinAttachmentResolver.swift` (`resolveAutomatic`, `resolveLive`) | `data/PinPlacement.kt` (`resolveAutomatic`) |
| Observation-backed aisle lock | `App/PinAisleObservationLock.swift`, `LegacyImported/Services/LocationService.swift` | `data/PinAisleObservationLock.kt`, `data/LocationTracker.kt` |
| Frozen capture boundary | `App/PinCaptureContext.swift`, `App/RepairsGrowthView.swift`, `LegacyImported/Services/TripTrackingService.swift`, `LegacyImported/Views/Buttons/QuickPinSheet.swift`, `LegacyImported/Views/Pins/PinDropView.swift` | `data/QualifiedLocationFix.kt` (`PinCaptureContext`), `ui/AppViewModel.kt` (`freezePinCapture`, `createPin`) |
| Live-lock validity (block + recency) | `App/PinAttachmentResolver.swift` (`LiveLock`, `lockIsValid`), `LegacyImported/Services/TripTrackingService.swift` (`lockedPaddockId`, `diagLockConfirmedAt`) | aisle never taken from the trip lock (`resolveTripPinAttribution`, `lockedDrivingPath = null`) |
| Persistence | `LegacyImported/Services/MigratedDataStore+Buttons.swift`, `Backend/Models/BackendPin.swift` | `data/PinRepository.kt` (`PinInput`), `data/PinCreateSync.kt`, `data/PinReplayMerge.kt` |
| Display | `App/PinAttachmentFormatter.swift`, `LegacyImported/Views/Pins/PinsView.swift` | `ui/screens/PinsScreen.kt` |
| Regressions | `VineTrackTests/PinAisleAttachmentTests.swift`, `VineTrackTests/PinManualPlacementTests.swift` | `data/PinAisleAttachmentTest.kt`, `data/PinPlacementTest.kt` |

## 1. Attached row and driving path are different facts

`pin_row_number` is the vine row containing the issue ("On Row 26").
`driving_row_number` is the aisle the operator occupied at capture
("Row 26.5"). Exact decimal path values (32.5) are preserved.

## 2. Automatic Left/Right is relative to qualified GPS travel at capture

The explicit selected side participates in choosing the physical adjacent row,
using qualified direction of travel and mapped geometry. Handset compass is
retained only as diagnostic evidence; rotating the phone must not choose the row.
GPS does not establish vehicle-facing direction or distinguish reverse gear
from a turnaround. No tractor-facing/reverse-detection claim is supported. **Left never means "the lower row
number".** The aisle number is the mean of the two adjacent rows' numbers,
derived from geometry.

## 3. Both directions must work

Reversing direction of travel reverses the left/right relationship between
the same two physical rows. The aisle stays the same aisle.

## 4. Automatic drops behave the same inside and outside a trip

Repairs, Growth, Growth Stage and automatic quick-pin entry points share these
placement rules. An active trip may supply a validated row lock, but the aisle
is taken from the block geometry that physically contains the fix — never from
the planned next path — so a stale or wrong-block lock cannot create false
certainty. Being outside a trip never silently disables the feature.

## 5. Manual placement keeps its meaning

A map-tapped point, whole-row selection, segment selection or block selection
does not imply that an operator drove an aisle. Those records keep the existing
structured location-scope contract: no invented side, heading or driving path.
A capture with no explicit Left/Right choice (including side-free Growth Stage
observations) remains point-only unless an explicit manual location workflow is
used. Never invent Right or choose a nearest row to imply automatic snapping.
Manual row-only confirmation does not set `snapped_to_row` or invent snap coordinates.

## 6. Freeze one observation

Location, capture time, vineyard/trip identity, resolved block, driving path,
attached row, side, heading and attachment geometry describe one capture event.
A later photo prompt, duplicate confirmation, retry or movement must not change
it. The heading saved on the pin is the exact heading used to choose the row.

The capture time written to the record is the instant of the press, not the
instant of the save, and a capture may only be written into the vineyard and
trip it was taken in. If either changed during the delay the write is refused
with a "press again" message rather than saved into the wrong context.

## 7. Retain evidence separately from the attachment

The accepted raw GPS observation and the selected vine-row snap are stored
separately. The record's own latitude/longitude are ALWAYS the original
observation; the snap lives only in the attachment fields
(`snapped_latitude`/`snapped_longitude`). The original coordinate is never
overwritten to make a marker look correct, and historic base coordinates are
never retrospectively relabelled as raw. Duplicate checking continues to compare
the attached point, with the raw point supplied alongside it.

## 8. Use a coherent navigation target

Marker, distance, in-app Directions and the exported attached location all use
the same validated attachment for a snapped point (`attachedCoordinate` on iOS,
`attachedLatitude`/`attachedLongitude` on Android). The stored driving path
remains approach context. Manual row/block representative markers keep their
current structured meaning.

## 9. Missing evidence stays explicit

- Unknown direction is **not** North. A genuine 0° is valid; nil, non-finite and
  out-of-range values are rejected.
- Unknown aisle is **not** attached row plus 0.5. The legacy `row_number`
  column has conflicting historical meanings and is never converted into a
  driving path or shown as an attached row. Where it is the only value a record
  carries it is surfaced as an explicitly labelled "Recorded row X", and an
  automatic capture that could not confirm a row does not populate it at all.
- An unconfirmed automatic capture states both missing facts in Details:
  "On Row — Not confirmed" and "Driving path — Not recorded", while still
  showing the side and facing that WERE recorded.
- A nearest row alone is not proof of the intended operator side.
- When the aisle or facing cannot be established, the capture stays honestly
  point-only: raw coordinates and the operator's own recorded side are kept,
  nothing else is claimed, and Details says "Driving path — Not recorded".
- A rejected automatic tap never creates a pin later when GPS improves.

## 10. Capture qualification is not row confidence

The Android fresh-fix/precise-location gates (5 s, 15 m), the iOS
stale/low-accuracy gates and the failed-tap semantics stay exactly as they are.
Passing them does not establish which ~3 m aisle the operator occupied. Aisle
confidence is judged separately, from evidence:

- **Bounded observation-backed lock.** Outside trips, the existing foreground
  location stream retains at most 16 distinct observations for 20 seconds. Three
  fresh, separately delivered observations matching the same mapped aisle establish
  its identity; elapsed time and repeated cached coordinates do not add confidence.
  One or two contradictory fixes are held as brief outliers, while three sustained
  qualified contradictions switch the lock. Entering a headland, leaving/changing
  blocks or GPS expiry clears the applicable evidence. Reversing direction does not
  change aisle identity. The history is never coordinate-averaged and row numbers
  are never averaged.
- **Uncertainty plus map matching.** The accepted fix is matched to the actual
  adjacent mapped rows, with polygon, corridor-width and row-end/headland checks.
  Its reported accuracy radius must be smaller than that full mapped aisle width.
  It does not have to fit separately between the point and each row: that
  single-fix rule made ordinary 2.8–3 m field GPS incapable of attaching in a
  ~3 m aisle even when the mapped corridor was otherwise unique. Missing or
  invalid accuracy, or uncertainty spanning the full aisle, remains ambiguous.
- **Freeze at the press.** The qualified aisle identity, current accepted raw fix,
  fresh heading and selected side are frozen together. The current raw fix—not an
  averaged or earlier coordinate—is projected onto the selected vine row. If the
  bounded evidence remains ambiguous, the frozen confirmation fallback applies.
- **Save first; enrich location later.** Once the existing GPS freshness and
  accuracy gate accepts the tap, the point pin is durably saved exactly once.
  Missing block, heading, aisle or attached row means only that those placement
  fields remain unresolved; it never blocks capture and never creates a later
  pin from a rejected tap. Left/Right is retained when pressed. Side-free E-L
  capture does not invent a side or require heading/row. Any optional user
  confirmation and automated enrichment keep the same pin ID and frozen fix.
- **Row ends.** If the nearest point on a row is only its clamped endpoint, the
  fix lies beyond that row and containment is not proven. Two 100 m rows 3 m
  apart with the fix halfway across but 1 m past their ends stays unconfirmed.
- **Qualified travel only.** At least three distinct actual provider observations
  from the 15 seconds before the tap, each with speed ≥1 m/s, accuracy 0–5 m,
  valid coordinates and GPS course. Newest provider observation must qualify and
  be no older than five seconds; span ≥1 second, displacement ≥5 m. Circular
  course deviations must be ≤25° and displacement/course disagreement ≤30°.
  An observed stop, poor latest fix, stale/missing course, contradictory movement
  or short displacement leaves direction unresolved. Android also checks
  monotonic freshness and deduplicates both provider clocks.
- **Compass is diagnostic only.** Actual compass/source/time may be retained,
  including opposite phone orientation; it cannot satisfy movement qualification.
- **Live lock scope (iOS).** A trip row lock may supply the aisle only when it is
  confident AND was earned in the block this fix resolved to AND was confirmed
  in the corridor recently. Confidence alone never validates stale or
  wrong-block evidence — row numbers repeat across blocks.

## 11. Persist and display identically

List and detail use one formatter. An established vine row is presented as the
recorded row; capture side and facing describe the operator at capture; the
driving aisle is shown separately. `row_number` by itself is only “Recorded row
X”. It never becomes X.5 and never establishes an aisle.


The capture result survives local optimistic save, insert payload, offline
queue/replay, server response, app restart and refresh on either platform.
Queued payloads written before a column existed must not erase valid saved
attachment metadata, and pending photos/edits are preserved — decoding
successfully is not enough. Android reconciles a replayed/refreshed pin through
`PinReplayMerge`: legacy thin responses retain omitted local attachment fields.
For confirmed placement, `location_confirmation_revision` then `sync_version`
choose complete location authority, including intentional null/false values.
A row-only server correction must clear an old snap rather than OR it back on.
Pending CREATE display overlays preserve offline content but cannot hide a newer
server confirmation; refreshed cache retains confirmation metadata. Cross-vineyard
identity cannot borrow placement. iOS creates ignore ID conflicts, then PATCHes
only content fields; stale create replay never writes confirmed location keys.
Normal delta sync merges confirmed location independently of newer offline notes.
Saved direction/side labels never change because the viewer turned around;
legacy “facing” wording must not be interpreted as proven vehicle facing.

## 12. Keep every newer pin improvement

Notes, photos and replacement revisions, type changes, creators, timestamps,
E-L and variety details, completion/deletion, sync state, scope/segments,
filters, exports, permissions, duplicate prevention and the recent GPS
qualification / immutable capture / recovery-evidence safeguards all remain
unchanged.

## Release checklist — four field checks

Keep these visible in the release checklist for any pin-related change:

- [ ] **Attached row** — "On Row X" matches the row physically holding the issue
- [ ] **Driving path** — "Row X.5" matches the aisle actually driven
- [ ] **Side** — explicit Left/Right matches qualified movement-relative side at capture
- [ ] **Direction** — displayed saved direction matches qualified GPS travel, not phone compass or an inferred reverse gear

Verify opposite-side drops at approximately the same along-row position, then
repeat facing the opposite direction. Record pin IDs and screenshots
immediately, after reopen, and after sync to the other platform. Report code
verification and physical handset acceptance separately.

## 13. Deferred enrichment evidence

Capture evidence is immutable and separate from derived placement. It carries
one stable pin ID, capture and GPS observation times, raw coordinates/accuracy,
qualified GPS travel and its source/time, diagnostic compass where available,
explicit pressed side (or nil), trip context,
resolver-supported placement, geometry identity where available, and at most 16
pre-tap observations from the preceding 20 seconds. Freshness is judged against
the capture instant, never upload time. Direction qualification uses the narrower
15-second window above. Later movement cannot enter this bundle. Freeze geometry
identity with the capture, not after a delayed picker/photo save. Same pin/revision
retry accepts identical evidence only (upload acknowledgement is separate).
iOS precise evidence storage preserves subsecond timestamps through restart and
reads legacy evidence without fabricating lost precision; shared persistence and
historical pin coordinates are unchanged.

The pin and evidence retry independently by exact ID. Evidence arriving after
the pin still enqueues enrichment. Failed evidence delivery never removes the
local pin or evidence. Server enrichment fills only absent, supported placement
fields and provenance. It never changes completion, deletion, raw coordinates,
creator, type, notes or photos; it refuses deleted records and does not overwrite
mobile/user-confirmed placement. Normal pin delta sync returns accepted results.

## 14. Worker rollout and reversal

The following is the separately owned server rollout contract, NOT permission
for a mobile integration to apply SQL, deploy a worker, enable a schedule or
correct historical pins. ChatGPT owns Supabase; this mobile checkpoint makes no
server changes.

Ordered release: (1) apply `sql/231_pin_location_enrichment.sql`; (2) deploy
`pin-location-enrichment-worker` with `PIN_ENRICHMENT_WORKER_SECRET`, leaving the
schedule disabled; (3) install mobile test builds; (4) verify controlled fixtures
and audit rows; (5) enable a one-minute authenticated schedule.

Disable immediately by unscheduling the cron invocation; leased jobs expire and
remain durable. Verification queries:

```sql
select location_enrichment_status, count(*) from public.pins group by 1;
select attempts, count(*) from public.pin_location_enrichment_queue group by 1;
select outcome, count(*) from public.pin_location_enrichment_audit group by 1;
select count(*) filter (where paddock_id is null) unresolved_block,
       count(*) filter (where pin_row_number is null) unresolved_row
from public.pins where deleted_at is null; -- SELECT-only historical review
```

Reversal is audited and conditional: select the relevant audit before-image,
lock the pin, and refuse reversal unless its current placement and enrichment
revision still equal that audit's after-image. Never overwrite a subsequent
mobile/user edit. Do not delete evidence or audit rows during reversal, and do
not enqueue the historical inventory automatically.
