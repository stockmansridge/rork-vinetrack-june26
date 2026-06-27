# VineTrack iOS — Offline Field Readiness QA Script

Run this on a real iPhone (not the simulator) so you exercise real GPS, camera, photo storage, and Airplane Mode behaviour.

**Flow under test:** online preload → Airplane Mode field work → reconnect → sync → portal confirmation.

**Devices/accounts needed**
- 1 iPhone with cellular + Wi-Fi, real GPS.
- A test org account with a known paddock/vineyard already set up.
- Access to the web portal logged in as the same org (a second device or laptop).
- Camera roll with a few photos, and ability to take new photos.

**Golden rules while testing**
- Use real **Airplane Mode** (toggle Wi-Fi off too) to simulate the field, not just "poor signal".
- Note timestamps for each created record so you can match them in the portal.
- Never force-quit mid-sync unless a test explicitly tells you to.

---

## 1. Login / Session Restore

**Setup:** Fully signed out. Online.
**Steps:**
1. Launch app, sign in.
2. Force-quit the app, relaunch (still online) → confirm you land logged in.
3. Enable Airplane Mode, force-quit, relaunch.

**Expected app behaviour:** Relaunch online restores session with no re-login. Relaunch offline still opens straight into the app with the last session — no login wall, no blank screen.
**Expected sync/badge:** Home chip shows **Online · Synced** when online; **Offline · Saving locally** after Airplane Mode.
**Portal:** No change expected.
**Failure signs:** Forced re-login offline, spinner that never resolves, "session expired" while offline, crash on cold launch offline.

---

## 2. Offline Readiness Screen

**Setup:** Online, before going to field.
**Steps:**
1. Open **Settings → Offline Readiness**.
2. Review all readiness rows (session, maps, data cache, subscription grace, pending sync).
3. Tap any "prepare/preload" actions offered.
4. Enable Airplane Mode and reopen the screen.

**Expected app behaviour:** Each readiness item shows a clear ready/not-ready state. Preload actions complete while online. Offline, the screen still renders cached status without hanging.
**Expected sync/badge:** Pending sync section shows **0 waiting** (clean start) and, later, failed-retry lines only when failures exist.
**Portal:** N/A.
**Failure signs:** Items stuck "checking…", crash offline, readiness claims ready when data wasn't actually cached.

---

## 3. Offline Maps (tile-free / overlay-only fallback)

**Setup:** Online, in/near the target paddock area. Confirm local paddock data is loaded.
**Steps:**
1. Open the map and confirm paddock polygons, row lines, pins, and existing overlays render while online.
2. Enable Airplane Mode.
3. Pan/zoom around the working area; open map-based screens (pins, trip tracking, damage, yield sampling).

**Expected app behaviour:**
- Apple hybrid/satellite base imagery may disappear once offline — this is expected.
- The app falls back to a **neutral background** and continues to draw all local vector content: **paddock polygons, row lines, trip paths, pins, damage polygons, yield sample points, and the current GPS position**.
- Offline map mode does **not** depend on previously cached Apple map tiles; the overlay-only view works even if you never visited that area online.
- No crash on pan/zoom; GPS dot tracks correctly.
**Expected sync/badge:** Home chip **Offline · Saving locally**.
**Portal:** N/A.
**Failure signs:** Completely blank map with no local polygons/overlays offline, missing GPS dot, crash on pan/zoom, app waiting on Apple tiles that never load, or assuming cached tiles are required.

---

## 4. Trips

**Setup:** Airplane Mode ON. On-site with real GPS.
**Steps:**
1. Start a trip, walk/drive a short path, then end the trip.
2. Start and complete a **second** trip.
3. Open the trip list and a trip detail.

**Expected app behaviour:** Trips start/track/end fully offline; GPS path recorded; editing/reviewing works.
**Expected sync/badge:** Each new trip row + detail header shows **Queued**. Home chip shows **2 waiting** (plus any other queued records). Nothing shows Synced yet.
**Portal:** Trips not yet visible.
**Failure signs:** Trip won't start offline, path empty, badge shows Synced while offline, badge missing.

---

## 5. Pins with Photos

**Setup:** Airplane Mode ON.
**Steps:**
1. Drop a pin at your location, add notes, attach **a new camera photo** and **a library photo**.
2. Edit the pin (change note).
3. Create a second pin with a photo.
4. Open pin list, pin detail, and the map callout.

**Expected app behaviour:** Pins create/edit offline; photos attach and display from local storage.
**Expected sync/badge:** Pins show **Queued** (including the photo-pending case) in list rows, detail header, and callout. Home chip waiting count increases.
**Portal:** Pins/photos not yet visible.
**Failure signs:** Photo attach fails offline, thumbnails broken, badge Synced while offline, app blocks pin creation waiting for upload.

---

## 6. Spray Records + PDF Export

**Setup:** Airplane Mode ON.
**Steps:**
1. Create a spray record (product, rate, paddock, conditions).
2. Edit it once.
3. Generate the **local PDF/export** for that record.
4. Open spray list and spray detail.

**Expected app behaviour:** Record saves offline; PDF generates locally without network.
**Expected sync/badge:** Spray record shows **Queued** in row + detail header. **Compliance check:** it must show Queued from its **own** state — it must NOT flip to Synced just because a linked trip syncs later.
**Portal:** Not yet visible.
**Failure signs:** PDF export requires network, export blocked, spray badge inheriting trip's sync state, badge missing.

---

## 7. Damage Records

**Setup:** Airplane Mode ON.
**Steps:**
1. Create a damage record and draw a multi-point polygon.
2. Save offline.
3. Edit the polygon (add/move vertices) and resave.
4. Open damage list and the record detail/RecordDamageView.

**Expected app behaviour:** Polygon drawing/editing and save all work offline.
**Expected sync/badge:** Whole record shows **Queued** as one unit — **no per-vertex badges**. Detail header badge present.
**Portal:** Not yet visible.
**Failure signs:** Per-point badges appearing, polygon edit blocked offline, save fails, badge missing.

---

## 8. Yield Sessions

**Setup:** Airplane Mode ON.
**Steps:**
1. Start a yield/sampling session, run guided sampling, record several sample counts.
2. View the sample path/summary.
3. Save the session offline; start and pause/continue a second session.
4. Open session list, session detail, sampling summary.

**Expected app behaviour:** Sessions create/continue, samples record, paths display — all offline.
**Expected sync/badge:** Session shows **Queued** as one unit (samples embedded in the session payload, not individually badged). Badge present on list row, detail header, sampling summary.
**Portal:** Not yet visible.
**Failure signs:** Sampling blocked offline, sample counts lost on pause/continue, per-sample badges, badge missing.

---

## 9. Work Tasks

**Setup:** Airplane Mode ON.
**Steps:**
1. Create a work task, assign labour/resources, link a paddock.
2. Edit the task.
3. **Complete** the task offline.
4. Open task list, task detail, and any board/kanban card.

**Expected app behaviour:** Create/edit/complete and labour assignment all work offline.
**Expected sync/badge:** Task shows **Queued** from its **own** record state. Related labour/paddock links must NOT incorrectly flip the task badge to Synced or Error. Badge present on rows, detail header, board card.
**Portal:** Not yet visible.
**Failure signs:** Completion blocked offline, badge driven by related records, badge missing.

---

## 10. Subscription Grace

**Setup:** Logged in with active subscription, then Airplane Mode ON for the full field session.
**Steps:**
1. Work offline through several of the tests above.
2. Force-quit and relaunch while still offline.
3. Check that premium/field features remain available.

**Expected app behaviour:** Subscription grace keeps field features unlocked offline; no paywall mid-field. Relaunch offline still honours grace.
**Expected sync/badge:** No sync impact; chip behaves normally.
**Portal:** N/A.
**Failure signs:** Paywall blocks field work offline, "subscription required" while in grace window, features lock after offline relaunch.

---

## 11. Pending Sync Counts

**Setup:** After tests 4–9, still in Airplane Mode with multiple queued records.
**Steps:**
1. Check the **Home chip**.
2. Open **Sync settings** and **Offline Readiness**.

**Expected app behaviour:** Counts reflect the true number of queued records.
**Expected sync/badge:** Home chip shows **X waiting**. Sync settings + Offline Readiness show matching pending totals. No failure/retry lines yet (nothing has failed).
**Portal:** N/A.
**Failure signs:** Count mismatch between chip / settings / readiness, count stuck at 0 despite queued records, premature "need retry" text.

---

## 12. Per-Record Badges (Reconnect → Syncing → Synced)

**Setup:** All the above queued. Turn Airplane Mode **OFF**.
**Steps:**
1. Watch the Home chip and a couple of record lists as sync runs.
2. Let sync complete; reopen each record type's list/detail.

**Expected app behaviour:** Sync runs automatically on reconnect without user action.
**Expected sync/badge:** Records transition **Queued → Syncing → Synced**. Home chip goes **Online · Syncing** then **Online · Synced**, waiting count → 0.
**Portal:** Records begin appearing (confirmed in Test 14).
**Failure signs:** Records stuck Queued after reconnect, badge jumps to Synced without upload, chip never clears, app needs a manual kick to start syncing.

---

## 13. Per-Record Failure Isolation

**Setup:** Create **two** records of the same type offline (e.g. two pins or two trips). Induce a failure on **one** only — e.g. make one record invalid/oversized, or reconnect briefly then drop signal so one upload fails while the other succeeds.
**Steps:**
1. Reconnect and let sync attempt both.
2. Inspect both records' badges and the detail header of the failed one.
3. Edit the failed record locally, then reconnect/retry.

**Expected app behaviour:** Only the failing record is affected; the healthy one syncs normally.
**Expected sync/badge:**
- Failed record → **Will retry / Error**, with detail-header hint "Last sync failed — will retry."
- Healthy record → **Synced**.
- Editing the failed record keeps it pending and refreshes stale failure state.
- After a successful retry, failed record → **Synced** and its failed ID clears.
- Sync settings / Offline Readiness show accurate retry counts ("X records need retry", failed uploads vs deletes). Home chip shows **X need retry** only while failures exist.
**Portal:** Healthy record appears; failed record appears only after successful retry.
**Failure signs:** Healthy record showing Error, all records flipped to failed by one failure, raw server error shown in a list row, failed badge never clearing after success, retry blocked/record locked.

---

## 14. Portal Confirmation After Reconnect

**Setup:** After Tests 12–13 complete and chip shows **Online · Synced** with 0 waiting.
**Steps:**
1. In the web portal, refresh and locate each created record by timestamp: trips, pins (+photos open full-res), spray records, damage polygons, yield sessions + samples, work tasks (+ labour/paddock links, completion status).
2. Compare values to what you entered on-device.

**Expected app behaviour:** App shows everything Synced, 0 waiting, 0 needing retry.
**Expected portal result:** Every record present with correct data, geometry, photos, and relationships. Completed tasks show completed. No duplicates.
**Failure signs:** Missing records, broken/missing photos, polygon geometry wrong, duplicate records, labour/paddock links missing, completion status not reflected.

---

# Final Pass/Fail Checklist (run on iPhone in Airplane Mode)

**Preload (online)**
- [ ] Login persists after force-quit (online + offline)
- [ ] Offline Readiness all green
- [ ] Local paddock data loaded for working area

**Offline field work (Airplane Mode)**
- [ ] Map usable offline: neutral background + local polygons/rows/pins/paths/GPS dot (no dependence on cached Apple tiles)
- [ ] Trip start → track → end works; shows Queued
- [ ] Pin + new photo + library photo; shows Queued
- [ ] Spray record saves; PDF exports locally; Queued from own state (not trip)
- [ ] Damage polygon draw/edit/save; one Queued badge, no per-vertex badges
- [ ] Yield session + guided sampling + counts; one Queued badge
- [ ] Work task create/assign/complete; Queued from own state
- [ ] Subscription grace keeps features unlocked offline (incl. after relaunch)
- [ ] Pending count matches across Home chip / Sync settings / Offline Readiness
- [ ] No record shows Synced while offline

**Reconnect (Airplane Mode OFF)**
- [ ] Sync starts automatically
- [ ] Badges move Queued → Syncing → Synced
- [ ] Home chip clears to Online · Synced, 0 waiting

**Failure isolation**
- [ ] Only the failed record shows Will retry; healthy record stays Synced
- [ ] Failed detail header shows "Last sync failed — will retry"
- [ ] No raw server errors in list rows
- [ ] Editing + retry moves failed record to Synced and clears failed ID
- [ ] Retry counts accurate in Sync settings + Offline Readiness; chip shows "X need retry" only when failures exist

**Portal**
- [ ] All records present, correct, no duplicates
- [ ] Photos full-res, polygons correct, samples present
- [ ] Task completion + labour/paddock links correct
