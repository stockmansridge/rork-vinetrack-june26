# iOS Sync Status Parity — Status Note

Internal status tracker for iOS/Android Sync Status parity.

> **DIRECTION CHANGE (active).** The project direction is now **Android-only
> parity with the existing iOS app**. The **existing iOS app is the benchmark**;
> Android is brought up to match it. **No iOS app code changes are approved**, and
> there is **no iOS Sync Status parity implementation**. The iOS-F audit/design
> notes below are retained for **reference only** — they are not an approved
> implementation plan. Future work is Android-only unless explicitly instructed
> otherwise.

---

## Closure state

| Stage | Scope | Status |
|---|---|---|
| iOS-F-0 (design) | Sync Status parity audit/design after Android Tier-A H-5 — reference-only notes on the current iOS sync surface, dirty-tracking metadata model, a proposed read-only pending-work item model, label/display-state mapping, details + copy diagnostics design, Retry all (manual sweep) design, per-item retry recommendation, UX placement, and staged plan. **Reference only — not an approved implementation plan.** | **CLOSED / DESIGN ONLY** |
| iOS-F-1 | Read-only Sync Status pending-work list. **Not implemented.** Any prior implementation was **reverted**; the iOS app is unchanged. Cancelled because the project direction is Android-only parity with the existing iOS app. | **PARKED / NOT IMPLEMENTED / CANCELLED** |

---

## iOS-F-1 — read-only Sync Status pending-work list (cancelled / not implemented)

**Status: PARKED / NOT IMPLEMENTED / CANCELLED.** An earlier draft of iOS-F-1
added a read-only pending-work model, list UI, and read-only accessors to the
iOS sync services. **That work has been fully reverted** following a project
direction change: the goal is now **Android-only parity with the existing iOS
app**, and **no iOS app code changes are approved**.

State of the iOS app:

- The iOS app is back to its **pre-iOS-F-1 baseline** — unchanged.
- `Backend/Sync/PendingWorkItem.swift` was **removed** (no longer exists).
- `App/PendingWorkListView.swift` was **removed** (no longer exists).
- The read-only `pendingWork` / `failedUpsertIds` / `failedDeleteIds` accessor
  additions across the sync services were **reverted**.
- The `App/BackendSettingsView.swift` navigation entry was **reverted**.
- No iOS Sync Status pending-work list ships.

The earlier claims that `PendingWorkItem.swift` and `PendingWorkListView.swift`
were added, that 25 iOS services were wired, that iOS-F-1 build/QA passed, and
that iOS-F-1 was closed are **superseded and no longer accurate**.

### Why cancelled

- Project direction is **Android-only parity** using the **existing iOS app as
  the benchmark**.
- iOS is intentionally left **unchanged**.
- Any Sync Status parity work happens on **Android**, matching iOS behaviour —
  not by adding Android-style Sync Status features to iOS.

---

## iOS-F-0 — Sync Status parity audit/design (reference only)

**Status: CLOSED / DESIGN ONLY — reference only.** iOS-F-0 audited the existing
iOS sync surface and dirty-tracking metadata. The notes below are retained as
**reference material only** and are **not an approved implementation plan**;
the iOS app is not being changed. No app code was changed and no build was
required.

### Files inspected

- `Backend/Sync/SyncStatusCenter.swift`
- `Backend/Sync/PinSyncService.swift`
- `Backend/Sync/OperationsSyncServices.swift`
- `Backend/Sync/ManagementSyncServices.swift`
  - including `FuelPurchaseSyncService` and `TractorFuelLogSyncService`
- `App/BackendSettingsView.swift`
- `App/GlobalSyncStatusBar.swift`
- `App/RecordSyncState.swift`

### Current iOS Sync Status surface

- Users currently see sync status in **`GlobalSyncStatusBar`** (global online /
  offline / syncing / pending chip).
- Users also see status in the **Sync settings** surface (`BackendSettingsView`).
- Per-record **`RecordSyncBadges`** appear on individual records.
- There is **no user-facing itemised pending-work list**.
- **Operation type is not surfaced** (no create/edit/delete distinction in UI).
- Manual retry is **retry-all style only**, via
  `SyncStatusCenter.requestManualSync()` / the manual sync token.
- There is **no per-item retry**.
- **Copy diagnostics is not user-facing.**

### Available metadata (no persistence/schema change needed)

Each dirty-tracking sync service broadly exposes / persists:

- `pendingUpserts: [UUID: Date]`,
- `pendingDeletes: [UUID: Date]`,
- `failedUpserts: Set<UUID>`,
- `failedDeletes: Set<UUID>`,
- `lastSyncByVineyard: [UUID: Date]`,
- pending counts,
- failed id sets,
- `isSyncing`,
- service-level `sync(vineyardId:)`.

Findings:

- This is **enough to build a read-only pending-work list and Retry all**
  without any persistence or schema change.
- iOS **lacks Android-style attempt counts**, so there is no exact
  "Attempt N of X" equivalent yet.

### Proposed label map

- A pending **upsert** maps to an entity label, e.g. **Pin**, **Trip**,
  **Fuel log**, **Work task**, **Maintenance record**, **Yield session**,
  **Spray record**, **Damage record**.
- A pending **delete** maps to **`<Entity> delete`**.
- A **failed** upsert/delete uses the same label with a **Needs attention**
  state.
- iOS should **not fabricate create vs edit** where the dirty metadata only
  records an upsert.

### Proposed read-only item model

UI-only model (no persistence):

- record id,
- entity label,
- operation label,
- related id,
- state,
- queued timestamp,
- service key.

Presentation:

- flat list grouped by entity, sorted **newest-first**,
- **no payloads**,
- **no auth/session/tokens**,
- **no Supabase keys**,
- **no secrets**.

### Display state mapping

Proposed states:

- **Saved locally / Offline**,
- **Waiting to sync**,
- **Syncing**,
- **Needs attention**,
- **Synced** (omitted from the list).

Note: iOS has no attempt count, so there is **no exact Android "Attempt N of X"
equivalent** at this stage.

### Details + copy diagnostics design

- A **detail sheet per pending item**.
- Fields: type, operation, related id, status, queued timestamp, and a
  **sanitized error summary** if available.
- A **copy diagnostics** action using a safe template.
- Explicitly **exclude** payload JSON, auth/session/tokens, Supabase keys, and
  server stack traces.

### Retry all design

- **Retry all / Sync now** can call the existing
  `SyncStatusCenter.requestManualSync()`.
- Visible when the pending total is **greater than zero**.
- **Disabled offline or while syncing**.
- **No new persistence/schema API required.**

### Per-item retry recommendation

- **Defer per-item retry.**
- Current services sync **per vineyard**, not per record.
- True per-item retry needs **safe single-record service APIs**.
- Recommended order: read-only list/details/copy **first**, Retry all **second**,
  per-item retry **later only if safe**.

### UX placement

- Create/promote a user-facing **Sync Status screen under Settings → Sync**.
- Make the global sync bar / pending chip **tappable** to deep-link into it.
- **Do not add a new main tab.**

### Recommended implementation slices (reference only — not approved)

> These slices are **not approved for implementation.** They are kept only to
> document the original analysis. The active direction is Android-only parity
> with no iOS app changes.

- **iOS-F-1** — read-only outbox adapter + pending-work list.
- **iOS-F-2** — detail sheet + copy diagnostics.
- **iOS-F-3** — Retry all / manual sweep button.
- **iOS-F-4** — per-item retry only after safe single-id service APIs exist.
- **iOS-F-5** — wording alignment with Android labels.

### Risks / compatibility

- An **upsert cannot be reliably split** into create vs edit.
- A **strict field allow-list** is required to avoid exposing internals.
- **Per-item retry is the highest risk** and is deferred.
- The initial adapter should be **read-only** and must **not change sync
  semantics**.
- **Last-write-wins** and **eager-push / sweep** behaviour stay untouched.

### Build / check reference

- Audit / design only — **no code changed**, so no build was required.

### Parked next steps

> **Superseded by the direction change.** No iOS implementation is planned. The
> items below are historical reference only.

- ~~**iOS-F-1** — read-only outbox adapter + pending-work list.~~ (cancelled)
- ~~**iOS-F-2** — detail sheet + copy diagnostics.~~ (cancelled)
- ~~**iOS-F-3** — Retry all / manual sweep button.~~ (cancelled)
- ~~**iOS-F-4** — per-item retry only after safe single-id service APIs.~~ (cancelled)
- ~~**iOS-F-5** — wording alignment with Android labels.~~ (cancelled)

Active direction: **Android-only parity** with the existing iOS app as the
benchmark. No iOS app code changes unless explicitly instructed otherwise.
