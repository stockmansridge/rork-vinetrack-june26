# VineTrack — Offline Field Readiness (One-Page Checklist)

Print this or keep it open on your phone. Use real **Airplane Mode** (Wi-Fi off too). Note timestamps so you can match records in the portal.

---

## 1. Online Preload (before the field)
- [ ] Sign in; login persists after force-quit
- [ ] Offline Readiness screen all green
- [ ] Local paddock data loaded for the working area
- [ ] Active subscription confirmed

## 2. Airplane Mode Field Work
**Maps**
- [ ] Map works offline: neutral background + paddock polygons, row lines, trip paths, pins, damage polygons, yield sample points, GPS dot
- [ ] (Apple satellite/hybrid imagery dropping out is expected — local overlays must still show)

**Capture (each shows Queued, never Synced while offline)**
- [ ] Trip: start → track → end
- [ ] Pin + new camera photo + library photo
- [ ] Spray record + local PDF export (Queued from its own state, not the trip)
- [ ] Damage record polygon draw/edit/save (one badge, no per-vertex badges)
- [ ] Yield session + guided sampling + sample counts (one badge)
- [ ] Work task create / assign labour / complete (Queued from own state)

**Offline checks**
- [ ] Subscription grace keeps features unlocked (incl. after offline relaunch)
- [ ] Pending count matches across Home chip / Sync settings / Offline Readiness

## 3. Reconnect / Sync (Airplane Mode OFF)
- [ ] Sync starts automatically
- [ ] Badges move Queued → Syncing → Synced
- [ ] Home chip clears to Online · Synced, 0 waiting

## 4. Failure Isolation
- [ ] Only the failed record shows "Will retry"; healthy record stays Synced
- [ ] Failed detail header shows "Last sync failed — will retry"
- [ ] No raw server errors in list rows
- [ ] Edit + retry moves failed record to Synced; failed ID clears
- [ ] Retry counts accurate; chip shows "X need retry" only when failures exist

## 5. Portal Confirmation
- [ ] All records present, correct, no duplicates
- [ ] Photos full-res, polygons correct, samples present
- [ ] Task completion + labour/paddock links correct

---

**Pass criteria:** every box ticked, app shows 0 waiting / 0 needing retry, portal matches the device.
