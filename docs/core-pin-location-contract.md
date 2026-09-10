# Core pin-location contract

Permanent contract for how VineTrack decides, stores, and shows where a pin is.
Any change touching pin capture, GPS, rows, trips, sync, maps or pin
presentation must reference this document and run the relevant regression cases.
A green build alone does not demonstrate these behaviours.

Implementations (one shared contract, two platforms):

| Concern | iOS | Android |
| --- | --- | --- |
| Aisle + heading-aware side geometry | `App/PinAisleGeometry.swift` | `data/PinAisleGeometry.kt` |
| Automatic capture resolver | `App/PinAttachmentResolver.swift` (`resolveAutomatic`, `resolveLive`) | `data/PinPlacement.kt` (`resolveAutomatic`) |
| Frozen capture boundary | `App/RepairsGrowthView.swift`, `LegacyImported/Services/TripTrackingService.swift`, `LegacyImported/Views/Buttons/QuickPinSheet.swift`, `LegacyImported/Views/Pins/PinDropView.swift` | `ui/AppViewModel.kt` (`freezePinCapture`, `createPin`) |
| Persistence | `Backend/Models/BackendPin.swift` | `data/PinRepository.kt` (`PinInput`), `data/PinCreateSync.kt` |
| Display | `App/PinAttachmentFormatter.swift`, `LegacyImported/Views/Pins/PinsView.swift` | `ui/screens/PinsScreen.kt` |
| Regressions | `VineTrackTests/PinAisleAttachmentTests.swift`, `VineTrackTests/PinManualPlacementTests.swift` | `data/PinAisleAttachmentTest.kt`, `data/PinPlacementTest.kt` |

## 1. Attached row and driving path are different facts

`pin_row_number` is the vine row containing the issue ("On Row 26").
`driving_row_number` is the aisle the operator occupied at capture
("Row 26.5"). Exact decimal path values (32.5) are preserved.

## 2. Left/Right is relative to the operator at capture

The selected side participates in choosing the physical adjacent row, using the
recorded facing and mapped geometry. **Left never means "the lower row
number".** The aisle number is the mean of the two adjacent rows' numbers,
derived from geometry.

## 3. Both directions must work

Reversing the operator's direction reverses the left/right relationship between
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
A capture with no Left/Right choice at all (Growth Stage observations) keeps the
established side-free nearest-row contract.

## 6. Freeze one observation

Location, capture time, vineyard/trip identity, resolved block, driving path,
attached row, side, heading and attachment geometry describe one capture event.
A later photo prompt, duplicate confirmation, retry or movement must not change
it. The heading saved on the pin is the exact heading used to choose the row.

## 7. Retain evidence separately from the attachment

The accepted raw GPS observation and the selected vine-row snap are stored
separately. The original coordinate is never overwritten to make a marker look
correct, and historic base coordinates are never retrospectively relabelled as
raw.

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
  driving path.
- A nearest row alone is not proof of the intended operator side.
- When the aisle or facing cannot be established, the capture stays honestly
  point-only: raw coordinates and the operator's own recorded side are kept,
  nothing else is claimed, and Details says "Driving path — Not recorded".
- A rejected automatic tap never creates a pin later when GPS improves.

## 10. Capture qualification is not row confidence

The Android fresh-fix/precise-location gates (5 s, 15 m) and failed-tap
semantics stay exactly as they are. Passing them does not establish which ~3 m
aisle the operator occupied; row placement is confirmed from geometry and a
valid heading.

## 11. Persist and display identically

The capture result survives local optimistic save, insert payload, offline
queue/replay, server response, app restart and refresh on either platform.
Queued payloads written before a column existed must not erase valid saved
attachment metadata, and pending photos/edits are preserved. Saved facing/side
labels never change because the person viewing the pin turned around.

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
- [ ] **Side** — Left/Right matches the operator's own view at capture
- [ ] **Facing** — the displayed direction matches the recorded heading

Verify opposite-side drops at approximately the same along-row position, then
repeat facing the opposite direction. Record pin IDs and screenshots
immediately, after reopen, and after sync to the other platform. Report code
verification and physical handset acceptance separately.
