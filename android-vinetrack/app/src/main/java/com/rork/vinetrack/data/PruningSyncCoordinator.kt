package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PruningActivityCanonical
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningActivityReconciliation
import com.rork.vinetrack.data.model.PruningAllocationEditor
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSeasonSelection
import com.rork.vinetrack.data.model.PruningSegment
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import android.util.Log
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.LocalDate

/**
 * Offline-first coordinator for the Pruning Tracker. Local-first semantics
 * mirroring iOS `PruningSyncService`:
 *
 * * every write lands in [PruningStore] first (instant UI, works offline) and
 *   is queued in the shared pending-write outbox,
 * * queued writes replay on reconnect / foreground / refresh through the
 *   idempotent `record_pruning_entry` RPC — a replay can never double-count a
 *   quarter, and a quarter completed first on another device stays with that
 *   device's entry,
 * * [refresh] pulls the server state and reconciles the cache; the
 *   `pruning_row_segments` table is the single source of truth for completed
 *   quarters, so a completed quarter can only revert through the explicit
 *   `delete_pruning_entry` action, never a stale-sync overwrite.
 */
class PruningSyncCoordinator(
    private val store: PruningStore,
    private val repo: PruningSyncRepository,
    private val pending: PendingWriteRepository,
    private val scope: CoroutineScope,
    private val canSync: () -> Boolean,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val replayLock = Mutex()

    /**
     * Reconciliation of the last server answer for each activity (sql/166).
     * Set on every acknowledged write and consumed by the UI, so a save with
     * refused quarters is never presented as fully successful.
     */
    private val reconciliations = LinkedHashMap<String, PruningActivityReconciliation>()

    /** Fired whenever the server answers an activity write. */
    var onActivityReconciled: ((PruningActivityReconciliation) -> Unit)? = null

    fun reconciliation(activityId: String): PruningActivityReconciliation? = reconciliations[activityId]

    // MARK: Cached reads

    fun setups(vineyardId: String): List<PruningBlockSetup> = store.loadSetups(vineyardId)

    /**
     * Entries that still count as work done. Reversed entries stay in the
     * cache purely as Activity Report audit history and must never reach a
     * progress, rate or forecast calculation.
     */
    fun entries(vineyardId: String): List<PruningEntry> =
        store.loadEntries(vineyardId).filterNot { it.isReversed }

    /** Audit view for the Pruning Activity Report — active AND reversed. */
    fun auditEntries(vineyardId: String): List<PruningEntry> = store.loadEntries(vineyardId)

    /**
     * Sync integrity for the Pruning Tracker. "Fully synced" requires the
     * SERVER to have acknowledged every record AND this device to have adopted
     * the canonical season the server resolved from the activity date
     * (sql/161) — an empty outbox alone is not enough.
     */
    fun syncStatus(vineyardId: String): PruningSyncStatus {
        val all = pending.list()
        val unresolved = all.filter {
            (it.entityType == PendingEntityType.PRUNING_ENTRY ||
                it.entityType == PendingEntityType.PRUNING_SEASON ||
                it.entityType == PendingEntityType.PRUNING_ACTIVITY) &&
                it.status in PendingWriteStatus.unresolved
        }
        // A queued ACTIVITY holds every one of its allocations back from
        // "synced": 100% must mean the server acknowledged the parent and this
        // device adopted the canonical allocations it returned.
        val queuedActivityAllocationIds = unresolved
            .filter { it.entityType == PendingEntityType.PRUNING_ACTIVITY }
            .flatMap { write -> allocationIdsOf(vineyardId, write.clientId) }
            .toSet()
        // An activity whose linked Work Task has not been acknowledged is NOT
        // synced either, even with an empty pruning queue: its `work_task_id`
        // cannot resolve server-side yet. Never counted as 100%.
        val taskBlocked = activitiesWaitingForWorkTask(vineyardId, all)
        return PruningSyncIntegrity.evaluate(
            entries = store.loadEntries(vineyardId),
            queuedEntryIds = unresolved
                .filter { it.entityType == PendingEntityType.PRUNING_ENTRY }
                .map { it.clientId }
                .toSet() + queuedActivityAllocationIds +
                taskBlocked.flatMap { allocationIdsOf(vineyardId, it) },
            queuedWrites = unresolved.size + taskBlocked.count { activityId ->
                unresolved.none {
                    it.entityType == PendingEntityType.PRUNING_ACTIVITY && it.clientId == activityId
                }
            },
        )
    }

    /**
     * Activities held back by an unresolved Work Task dependency — the task
     * header, its block associations, or its LABOUR LINES. The link is server
     * state, so it is never stripped to let the pruning upload through; the
     * activity simply waits, and is never counted as fully synced while a labour
     * line it depends on is still local.
     */
    private fun activitiesWaitingForWorkTask(
        vineyardId: String,
        writes: List<PendingWrite>,
    ): List<String> {
        val unresolvedTasks = PruningActivityTaskLink.unresolvedDependencyIds(writes)
        if (unresolvedTasks.isEmpty()) return emptyList()
        return store.loadActivities(vineyardId)
            .filter { PruningActivityTaskLink.isWaitingForTask(it.workTaskId, unresolvedTasks) }
            .map { it.id }
    }

    // MARK: Local-first writes

    fun upsertSetup(vineyardId: String, setup: PruningBlockSetup): List<PruningBlockSetup> {
        val updated = store.upsertSetup(vineyardId, setup)
        enqueueCoalesced(
            entityType = PendingEntityType.PRUNING_SEASON,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(PruningBlockSetup.serializer(), setup),
            clientId = setup.id,
        )
        scope.launch { replayAll() }
        return updated
    }

    fun recordEntry(vineyardId: String, entry: PruningEntry): List<PruningEntry> {
        val updated = store.addEntry(vineyardId, entry)
        enqueueCoalesced(
            entityType = PendingEntityType.PRUNING_ENTRY,
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(PruningEntry.serializer(), entry),
            clientId = entry.id,
        )
        scope.launch { replayAll() }
        return updated
    }

    /**
     * Local-first edit of an existing entry (sql/120). The full desired state
     * lands in the cache immediately; the push routes by dependency:
     *
     *  * an unresolved queued CREATE for the same entry means the create hasn't
     *    landed — the edit is FOLDED into the create payload (the
     *    `record_pruning_entry` replay carries the full new state and nothing
     *    was ever claimed server-side to release), never queued separately;
     *  * otherwise ONE coalesced UPDATE write is queued and replays through the
     *    idempotent `update_pruning_entry` RPC — LWW on the edit's own
     *    timestamp, so a delayed retry can never resurrect older values or
     *    restore quarters removed by a newer edit on another device.
     */
    fun editEntry(vineyardId: String, entry: PruningEntry): List<PruningEntry> {
        val updated = store.updateEntry(vineyardId, entry)
        val hasQueuedCreate = pending.list().any {
            it.entityType == PendingEntityType.PRUNING_ENTRY && it.opType == PendingOpType.CREATE &&
                it.clientId == entry.id && it.status in PendingWriteStatus.unresolved
        }
        enqueueCoalesced(
            entityType = PendingEntityType.PRUNING_ENTRY,
            opType = if (hasQueuedCreate) PendingOpType.CREATE else PendingOpType.UPDATE,
            payloadJson = json.encodeToString(PruningEntry.serializer(), entry),
            clientId = entry.id,
        )
        scope.launch { replayAll() }
        return updated
    }

    fun deleteEntry(vineyardId: String, entryId: String): List<PruningEntry> {
        val updated = store.deleteEntry(vineyardId, entryId)
        // Drop any unsent create or edit for the same entry, then queue the
        // delete — the delete RPC is a no-op server-side if the entry never
        // landed, and a queued edit of a reversed entry is obsolete.
        removeUnresolved(PendingEntityType.PRUNING_ENTRY, PendingOpType.CREATE, entryId)
        removeUnresolved(PendingEntityType.PRUNING_ENTRY, PendingOpType.UPDATE, entryId)
        enqueueCoalesced(
            entityType = PendingEntityType.PRUNING_ENTRY,
            opType = PendingOpType.DELETE,
            payloadJson = entryId,
            clientId = entryId,
        )
        scope.launch { replayAll() }
        return updated
    }

    // MARK: Multi-block activities (sql/166)

    /** Offline drafts of every multi-block activity held for the vineyard. */
    fun activities(vineyardId: String): List<PruningActivityDraft> = store.loadActivities(vineyardId)

    fun activity(vineyardId: String, activityId: String): PruningActivityDraft? =
        store.activity(vineyardId, activityId)

    /**
     * Canonical read-back of ONE activity through `get_pruning_activity`, so
     * opening an activity from the Activity Report restores the real server
     * state — every block, every quarter selection, the shared labour and both
     * resolved years — instead of reconstructing it from legacy per-block rows.
     * Falls back to the offline draft when the read is unavailable.
     */
    suspend fun loadActivity(vineyardId: String, activityId: String): PruningActivityDraft? {
        val local = store.activity(vineyardId, activityId)
        if (!canSync()) return local
        val canonical = runCatching { repo.fetchActivity(activityId) }.getOrNull() ?: return local
        if (canonical.activity == null) return local
        val base = local ?: PruningActivityDraft(
            id = activityId,
            vineyardId = vineyardId,
            date = canonical.activity.entryDate?.take(10) ?: LocalDate.now().toString(),
        )
        val adopted = PruningAllocationEditor.adoptCanonical(base, canonical)
        store.upsertActivity(vineyardId, adopted)
        store.mergeActivityEntries(vineyardId, PruningAllocationEditor.toLegacyEntries(adopted))
        return adopted
    }

    /**
     * Pulls every activity of the vineyard through `list_pruning_activities`
     * and adopts the canonical parents + allocations into the cache. Offline
     * this is a no-op and the local drafts stand.
     *
     * Activities with an unresolved queued write keep their optimistic local
     * state — a pull must never overwrite work that hasn't been pushed yet.
     */
    suspend fun refreshActivities(vineyardId: String): List<PruningActivityDraft> {
        if (!canSync()) return store.loadActivities(vineyardId)
        val remote = runCatching { repo.fetchActivities(vineyardId) }.getOrNull()
            ?: return store.loadActivities(vineyardId)
        val queued = pending.list()
            .filter {
                it.entityType == PendingEntityType.PRUNING_ACTIVITY &&
                    it.status in PendingWriteStatus.unresolved
            }
            .map { it.clientId }
            .toSet()
        for (canonical in remote) {
            val id = canonical.activity?.id ?: continue
            if (id in queued) continue
            val base = store.activity(vineyardId, id) ?: PruningActivityDraft(
                id = id,
                vineyardId = vineyardId,
                date = canonical.activity.entryDate?.take(10) ?: LocalDate.now().toString(),
            )
            val adopted = PruningAllocationEditor.adoptCanonical(base, canonical)
            store.upsertActivity(vineyardId, adopted)
        }
        return store.loadActivities(vineyardId)
    }

    private fun allocationIdsOf(vineyardId: String, activityId: String): List<String> =
        store.activity(vineyardId, activityId)
            ?.activeAllocations
            ?.map { it.allocationIdFor(activityId) }
            .orEmpty()

    /**
     * Local-first save of a multi-block activity. The COMPLETE draft (parent
     * plus EVERY allocation) lands in the cache and in ONE coalesced outbox
     * write, so an offline retry replays the whole activity atomically and can
     * never leave a partially saved set of blocks.
     *
     * The draft is also projected onto the legacy per-block entries so every
     * existing progress, rate, forecast and report screen keeps working. Labour
     * rides on the primary allocation only, so no total double-counts it.
     */
    fun saveActivity(vineyardId: String, draft: PruningActivityDraft): PruningActivityDraft {
        val previous = store.activity(vineyardId, draft.id)
        val cleaned = PruningAllocationEditor.pruneEmptyBlocks(draft)
        val keptIds = cleaned.activeAllocations.map { it.allocationIdFor(cleaned.id) }.toSet()
        val staleIds = previous?.activeAllocations
            ?.map { it.allocationIdFor(cleaned.id) }
            ?.filterNot { it in keptIds }
            ?.toSet()
            .orEmpty()

        store.upsertActivity(vineyardId, cleaned)
        store.mergeActivityEntries(
            vineyardId = vineyardId,
            entries = PruningAllocationEditor.toLegacyEntries(cleaned),
            staleAllocationIds = staleIds,
        )

        // A create that has not reached the server yet absorbs the edit: the
        // create payload carries the FULL desired state, so there is nothing
        // server-side to reconcile and no separate UPDATE is needed.
        val hasQueuedCreate = pending.list().any {
            it.entityType == PendingEntityType.PRUNING_ACTIVITY &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == cleaned.id && it.status in PendingWriteStatus.unresolved
        }
        val isNew = previous == null || !previous.serverAcknowledged
        enqueueCoalesced(
            entityType = PendingEntityType.PRUNING_ACTIVITY,
            opType = if (hasQueuedCreate || isNew) PendingOpType.CREATE else PendingOpType.UPDATE,
            payloadJson = json.encodeToString(PruningActivityDraft.serializer(), cleaned),
            clientId = cleaned.id,
        )
        scope.launch { replayAll() }
        return cleaned
    }

    /** Reverses the whole activity — one operation, every allocation inherits it. */
    fun reverseActivity(vineyardId: String, activityId: String): List<PruningActivityDraft> {
        val allocationIds = allocationIdsOf(vineyardId, activityId)
        val updated = store.reverseActivity(vineyardId, activityId)
        allocationIds.forEach { store.deleteEntry(vineyardId, it) }
        removeUnresolved(PendingEntityType.PRUNING_ACTIVITY, PendingOpType.CREATE, activityId)
        removeUnresolved(PendingEntityType.PRUNING_ACTIVITY, PendingOpType.UPDATE, activityId)
        enqueueCoalesced(
            entityType = PendingEntityType.PRUNING_ACTIVITY,
            opType = PendingOpType.DELETE,
            payloadJson = activityId,
            clientId = activityId,
        )
        scope.launch { replayAll() }
        return updated
    }

    /**
     * Replays queued activity writes. Every RPC is idempotent on the stable
     * client activity id, so a retry can never create a second parent or
     * duplicate an allocation, and the response replaces the local activity and
     * allocations wholesale.
     */
    private suspend fun replayActivityPass(opType: String) {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.PRUNING_ACTIVITY && it.opType == opType &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        // ORDERED DEPENDENCY CHAIN: Work Task header -> its block associations ->
        // its labour lines -> this activity.
        val unresolvedTasks = PruningActivityTaskLink.unresolvedDependencyIds(pending.list())
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            try {
                if (opType == PendingOpType.DELETE) {
                    repo.reverseActivity(write.clientId)
                    pending.remove(write.id)
                    continue
                }
                val draft = json.decodeFromString(PruningActivityDraft.serializer(), write.payloadJson)
                // ORDERED DEPENDENCY: `pruning_activities.work_task_id` is a real
                // foreign key, and its labour lines are the authoritative labour
                // record. The task, its block links and its labour lines must all
                // reach the server first. The link is NEVER dropped to make this
                // upload succeed — the activity waits and retries on the next pass.
                if (PruningActivityTaskLink.isWaitingForTask(draft.workTaskId, unresolvedTasks)) {
                    Log.i(TAG, "activity ${draft.id} held: Work Task ${draft.workTaskId} or its labour lines have not synced yet")
                    retryOrBlock(write, PruningActivityTaskLink.WAITING_REASON)
                    continue
                }
                // LWW stamp = when the write was queued, never the replay time.
                val stamp = Instant.ofEpochMilli(write.createdAt).toString()
                val result = if (opType == PendingOpType.CREATE) {
                    repo.recordActivity(draft, stamp)
                } else {
                    repo.updateActivity(draft, stamp)
                }
                when {
                    result.error == "activity_not_found" ->
                        retryOrBlock(write, "Waiting for the pruning activity to reach the server.")
                    result.error == "activity_reversed" -> pending.remove(write.id)
                    else -> {
                        if (result.stale != true) adoptCanonicalActivity(draft, result)
                        publishReconciliation(draft, result)
                        pending.remove(write.id)
                    }
                }
            } catch (_: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to sync pruning work.")
            } catch (e: BackendError.Server) {
                when {
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Rejected (${e.code}).")
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
    }

    /**
     * Replaces the local activity and ALL its allocations with the canonical
     * server state — canonical activity fields, every allocation, each
     * allocation's canonical season and vintage, and the activity totals. Never
     * a field-by-field merge: once the server has acknowledged, it is
     * authoritative.
     */
    private fun adoptCanonicalActivity(
        draft: PruningActivityDraft,
        result: PruningSyncRepository.ActivityResult,
    ) {
        val canonical = result.canonical ?: return
        val adopted = PruningAllocationEditor.adoptCanonical(draft, canonical)
        val keptIds = adopted.activeAllocations.map { it.allocationIdFor(adopted.id) }.toSet()
        val staleIds = draft.activeAllocations
            .map { it.allocationIdFor(draft.id) }
            .filterNot { it in keptIds }
            .toSet() + result.removedAllocations.mapNotNull { it.allocationId }
        val serverSeason = adopted.serverSeasonYear
        if (serverSeason != null && serverSeason != adopted.seasonYear) {
            Log.i(TAG, "activity ${adopted.id} is filed under season $serverSeason for ${adopted.date} — reported, not moved")
        }
        store.upsertActivity(draft.vineyardId, adopted)
        store.mergeActivityEntries(
            vineyardId = draft.vineyardId,
            entries = PruningAllocationEditor.toLegacyEntries(adopted),
            staleAllocationIds = staleIds,
        )
    }

    /**
     * Surfaces the server's answer to the UI. Quarters the server refused
     * (already completed by another record) are reported explicitly — the save
     * is never presented as fully successful while conflicts exist.
     */
    private fun publishReconciliation(
        draft: PruningActivityDraft,
        result: PruningSyncRepository.ActivityResult,
    ) {
        val reconciliation = PruningActivityReconciliations.from(
            result = result,
            blockNames = draft.allocations.mapValues { it.value.blockName },
            blockSummary = draft.blockSummary,
            activityId = draft.id,
        )
        reconciliations[draft.id] = reconciliation
        if (reconciliation.hasConflicts) {
            Log.i(
                TAG,
                "activity ${draft.id}: ${reconciliation.quartersConflicted} quarter(s) already " +
                    "recorded elsewhere — reported, never stolen",
            )
        }
        onActivityReconciled?.invoke(reconciliation)
    }

    // MARK: Replay

    /** Replays queued season upserts, entry creates, then entry deletes. */
    suspend fun replayAll() {
        if (!canSync()) return
        if (!replayLock.tryLock()) return
        try {
            replayPass(PendingEntityType.PRUNING_SEASON, PendingOpType.UPDATE) { write ->
                val setup = json.decodeFromString(PruningBlockSetup.serializer(), write.payloadJson)
                // Replay with the marker's ENQUEUE time (the edit time), not
                // the replay time — the sql/185 stale-write guard must be able
                // to drop this write if another device saved a newer setup
                // while this one was offline (conflict-order safety).
                repo.upsertSeason(
                    setup,
                    clientUpdatedAt = java.time.Instant.ofEpochMilli(write.createdAt).toString(),
                )
            }
            // conflictIsSuccess = false: `record_pruning_entry` guards every
            // insert with ON CONFLICT, so a 409 here is a REAL failure (e.g.
            // the pre-SQL-116 season-id collision) — dropping the write on 409
            // silently lost the entry. Retry instead; SQL 116 resolves the
            // canonical season server-side so the replay now lands.
            replayPass(PendingEntityType.PRUNING_ENTRY, PendingOpType.CREATE, conflictIsSuccess = false) { write ->
                val queued = json.decodeFromString(PruningEntry.serializer(), write.payloadJson)
                val entry = repointToActivityDate(queued)
                // A skipped record takes the sql/168 path, whose signature has
                // nowhere to put a worker, hours, a rate or a task — so an
                // out-of-rotation section can never reach the server carrying
                // labour, however the queued draft was built.
                val result = if (entry.isSkipped) repo.recordSkippedEntry(entry) else repo.recordEntry(entry)
                adoptCanonicalSeason(entry, result)
            }
            // Edits replay AFTER creates — an edit of an entry whose create
            // hasn't landed yet returns entry_not_found and stays queued.
            replayEditPass()
            replayPass(PendingEntityType.PRUNING_ENTRY, PendingOpType.DELETE) { write ->
                repo.deleteEntry(write.clientId)
            }
            // Activities replay after the single-block queue: both write the
            // same segment table, and the activity RPCs are the only path that
            // can add a block to an existing parent.
            replayActivityPass(PendingOpType.CREATE)
            replayActivityPass(PendingOpType.UPDATE)
            replayActivityPass(PendingOpType.DELETE)
            replayPass(PendingEntityType.PRUNING_SEASON, PendingOpType.DELETE) { write ->
                repo.softDeleteSeason(write.clientId)
            }
        } finally {
            replayLock.unlock()
        }
    }

    /**
     * Re-derives the season from the ACTIVITY DATE immediately before upload.
     *
     * The queued payload may have been written by an older build (or before a
     * date edit), so its `seasonId` is never trusted on replay: the season is
     * taken from the cached row for `year(entry.date)`, falling back to the
     * deterministic id the server derives for that same year. Never the device
     * clock at sync time, never the selected setup season, never the first or
     * highest season row, never the vintage.
     */
    private fun repointToActivityDate(entry: PruningEntry): PruningEntry {
        val canonical = PruningSeasonSelection.canonicalSeasonId(
            setups = store.loadSetups(entry.vineyardId),
            vineyardId = entry.vineyardId,
            paddockId = entry.paddockId,
            isoDate = entry.date,
        )
        if (canonical == entry.seasonId) return entry
        Log.i(TAG, "entry ${entry.id} re-pointed to the season of its activity date ${entry.date} before upload")
        val repointed = entry.copy(seasonId = canonical)
        store.updateEntry(entry.vineyardId, repointed)
        return repointed
    }

    /**
     * Adopts the season `record_pruning_entry` resolved from the entry date
     * (sql/161). Server resolution is authoritative: if this device guessed a
     * different season row — the cross-platform 2026-vs-2027 defect — the
     * local cache converges silently. Writing through [PruningStore.updateEntry]
     * directly (not the queueing [editEntry]) keeps this out of the outbox:
     * adopting the server's own answer is not a user edit.
     */
    private fun adoptCanonicalSeason(entry: PruningEntry, result: PruningSyncRepository.RecordEntryResult) {
        applyServerSeason(
            entry = entry,
            seasonId = result.seasonId,
            seasonYear = result.seasonYear,
            storedUnderNonCanonicalSeason = result.seasonMismatch == true,
        )
    }

    /**
     * Same adoption for `update_pruning_entry` (sql/161 §4): an edit that moves
     * the date across a pruning year is re-pointed SERVER-side, and the client
     * takes the canonical season back from the response.
     */
    private fun adoptCanonicalSeason(entry: PruningEntry, result: PruningSyncRepository.UpdateEntryResult) {
        applyServerSeason(
            entry = entry,
            seasonId = result.seasonId,
            seasonYear = result.seasonYear,
            storedUnderNonCanonicalSeason = false,
        )
    }

    /**
     * Records the server's answer as the acknowledgement that makes a record
     * count as synced. Both values are required: a server older than sql/161
     * omits them, and a record with no canonical answer must stay "awaiting
     * confirmation" rather than be counted as done.
     */
    private fun applyServerSeason(
        entry: PruningEntry,
        seasonId: String?,
        seasonYear: Int?,
        storedUnderNonCanonicalSeason: Boolean,
    ) {
        if (seasonId == null || seasonYear == null) return
        if (storedUnderNonCanonicalSeason) {
            // A historical row stored under a non-canonical season. Never moved
            // silently — reported for the reviewed data correction (sql/164),
            // and deliberately left OUT of the synced count so it stays visible.
            Log.i(TAG, "entry ${entry.id} is stored under a non-canonical season $seasonId — reported, not moved")
            store.updateEntry(
                entry.vineyardId,
                entry.copy(serverSeasonId = seasonId, serverSeasonYear = seasonYear),
            )
            return
        }
        if (seasonId != entry.seasonId) {
            Log.i(TAG, "entry ${entry.id} adopted canonical season $seasonId ($seasonYear)")
        }
        store.updateEntry(
            entry.vineyardId,
            entry.copy(seasonId = seasonId, serverSeasonId = seasonId, serverSeasonYear = seasonYear),
        )
    }

    /**
     * Replays queued `update_pruning_entry` pushes. The RPC is idempotent
     * (full desired state, LWW on client_updated_at), so a retry can never
     * duplicate quarters or restore quarters removed by a newer edit. The
     * structured JSON response is inspected — the RPC reports entry-level
     * failures in the body, never as an HTTP error:
     *
     *  * `entry_not_found` — ordered dependency: the create hasn't landed;
     *    keep the edit queued and retry next pass;
     *  * `entry_reversed` — the entry was reversed elsewhere; the edit is
     *    obsolete and dropped;
     *  * `stale: true` — a newer edit from another device already applied;
     *    dropped (LWW);
     *  * `conflicts` — quarters owned by another entry were refused (never
     *    stolen); the edit itself applied, so the write completes and the
     *    next refresh reconciles the grid to the server attribution.
     */
    private suspend fun replayEditPass() {
        val candidates = pending.list().filter {
            it.entityType == PendingEntityType.PRUNING_ENTRY && it.opType == PendingOpType.UPDATE &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            try {
                val queued = json.decodeFromString(PruningEntry.serializer(), write.payloadJson)
                // An edited DATE can move the record into another pruning year;
                // re-derive the season from that date before the push so the
                // local cache never lags the server's re-pointing.
                val entry = repointToActivityDate(queued)
                // LWW timestamp = when the edit was (re-)queued, NOT the replay
                // time — a delayed retry must never beat a newer edit.
                val editedAt = Instant.ofEpochMilli(write.createdAt).toString()
                val result = if (entry.isSkipped) {
                    repo.updateSkippedEntry(entry, editedAt)
                } else {
                    repo.updateEntry(entry, editedAt)
                }
                when {
                    result.error == "entry_not_found" ->
                        retryOrBlock(write, "Waiting for the pruning entry to reach the server — will retry.")
                    result.error == "entry_reversed" -> pending.remove(write.id)
                    else -> {
                        if (result.stale != true) adoptCanonicalSeason(entry, result)
                        pending.remove(write.id)
                    }
                }
            } catch (_: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to sync pruning work.")
            } catch (e: BackendError.Server) {
                when {
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Rejected (${e.code}).")
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
    }

    // MARK: Refresh (pull + reconcile)

    /**
     * Replays the queue, pulls the server state and reconciles the local
     * cache. Entries with an unresolved queued create keep their optimistic
     * local segments until the push lands. Falls back to the cache offline.
     */
    suspend fun refresh(vineyardId: String): Pair<List<PruningBlockSetup>, List<PruningEntry>> {
        if (!canSync()) return store.loadSetups(vineyardId) to entries(vineyardId)
        // Un-wedge: writes that exhausted their retries BEFORE the SQL 116
        // server fix landed sit at BLOCKED forever (replay only picks up
        // PENDING/FAILED). An explicit refresh grants them a new retry cycle
        // against the fixed RPC. Bounded — one demotion per refresh.
        retryBlockedPruningWrites()
        replayAll()
        return try {
            val unresolved = pending.list().filter { it.status in PendingWriteStatus.unresolved }
            val pendingSeasonIds = unresolved
                .filter { it.entityType == PendingEntityType.PRUNING_SEASON }
                .map { it.clientId }.toSet()
            val pendingEntryCreateIds = unresolved
                .filter { it.entityType == PendingEntityType.PRUNING_ENTRY && it.opType == PendingOpType.CREATE }
                .map { it.clientId }.toSet()
            // Entries with a queued edit keep their optimistic local state until
            // the `update_pruning_entry` push lands — a pull must not overwrite
            // the pending edit with the server's pre-edit row.
            val pendingEntryEditIds = unresolved
                .filter { it.entityType == PendingEntityType.PRUNING_ENTRY && it.opType == PendingOpType.UPDATE }
                .map { it.clientId }.toSet()
            val pendingEntryDeleteIds = unresolved
                .filter { it.entityType == PendingEntityType.PRUNING_ENTRY && it.opType == PendingOpType.DELETE }
                .map { it.clientId }.toSet()

            val remoteSeasons = repo.fetchSeasons(vineyardId)
            val remoteEntries = repo.fetchEntries(vineyardId)
            val remoteSegments = repo.fetchSegments(vineyardId)
            // The season year the SERVER has for each season row — the pulled
            // entry's own canonical-season confirmation (sql/161).
            val serverSeasonYears = remoteSeasons.associate { it.id to it.seasonYear }

            val localSetups = store.loadSetups(vineyardId)
            val remoteSeasonIds = remoteSeasons.map { it.id }.toSet()
            // Seed: local seasons the server has never seen and that aren't
            // queued — re-queue them AND keep them in the merged cache. They
            // previously fell out of the merged list (queued but dropped from
            // the UI until the push landed).
            val seededSetups = localSetups
                .filter { it.id !in remoteSeasonIds && it.id !in pendingSeasonIds }
            seededSetups.forEach { setup ->
                enqueueCoalesced(
                    entityType = PendingEntityType.PRUNING_SEASON,
                    opType = PendingOpType.UPDATE,
                    payloadJson = json.encodeToString(PruningBlockSetup.serializer(), setup),
                    clientId = setup.id,
                )
            }
            // A season archived on the portal (`status = 'archived'`) is
            // treated like a tombstone for display parity — it must not keep
            // showing as an active block setup on mobile. Mobile never writes
            // `status`, so the portal's archive marker is always preserved.
            val mergedSetups = remoteSeasons
                .filter { it.deletedAt == null && !it.isArchived && it.id !in pendingSeasonIds }
                .map { it.toModel() } +
                localSetups.filter { it.id in pendingSeasonIds } +
                seededSetups
            store.saveSetups(vineyardId, mergedSetups)

            // Server attribution: quarters grouped by the entry that completed them.
            val segmentsByEntry = HashMap<String, MutableList<PruningSegment>>()
            for (segment in remoteSegments) {
                val entryId = segment.pruningEntryId ?: continue
                if (!segment.completed) continue
                segmentsByEntry.getOrPut(entryId) { mutableListOf() }
                    .add(PruningSegment(row = segment.rowNumber, quarter = segment.segmentNumber, rowId = segment.paddockRowId))
            }

            val localEntries = store.loadEntries(vineyardId)
            val remoteEntryIds = remoteEntries.map { it.id }.toSet()
            // Seed: local entries the server has never seen and that aren't
            // queued — re-queue them AND keep them in the merged cache. They
            // previously fell out of the merged list, so an entry whose queued
            // create was wrongly dropped (pre-fix 409 handling) vanished from
            // the device while still unsynced.
            val seededEntries = localEntries
                .filter {
                    // A reversed entry is audit history — never re-push it,
                    // that would resurrect reversed work on the server.
                    !it.isReversed &&
                        it.id !in remoteEntryIds && it.id !in pendingEntryCreateIds &&
                        it.id !in pendingEntryEditIds && it.id !in pendingEntryDeleteIds
                }
            seededEntries.forEach { entry ->
                enqueueCoalesced(
                    entityType = PendingEntityType.PRUNING_ENTRY,
                    opType = PendingOpType.CREATE,
                    payloadJson = json.encodeToString(PruningEntry.serializer(), entry),
                    clientId = entry.id,
                )
            }
            // Reversed (server soft-deleted) rows are RETAINED as audit history
            // for the Activity Report — flagged, and filtered out of every
            // calculation path by [entries]. Locally reversed rows whose delete
            // is still queued are kept from the cache for the same reason.
            val mergedEntries = remoteEntries
                .filter {
                    it.id !in pendingEntryDeleteIds &&
                        it.id !in pendingEntryCreateIds && it.id !in pendingEntryEditIds
                }
                .map { row ->
                    val model = row.toModel(
                        segments = segmentsByEntry[row.id].orEmpty(),
                        serverSeasonYear = serverSeasonYears[row.pruningSeasonId],
                    )
                    if (model.isReversed && model.segments.isEmpty()) {
                        // The server no longer attributes quarters to a reversed
                        // entry; keep the recorded ones for the audit trail.
                        val cached = localEntries.firstOrNull { it.id == row.id }?.segments.orEmpty()
                        model.copy(segments = cached)
                    } else {
                        model
                    }
                } +
                localEntries.filter {
                    it.id in pendingEntryCreateIds || it.id in pendingEntryEditIds ||
                        it.id in pendingEntryDeleteIds
                } +
                seededEntries
            store.saveEntries(vineyardId, mergedEntries)

            mergedSetups to mergedEntries.filterNot { it.isReversed }
        } catch (_: Exception) {
            store.loadSetups(vineyardId) to entries(vineyardId)
        }
    }

    // MARK: SQL 115 parity probe

    /**
     * Fetches the authoritative `get_pruning_vineyard_summary` (sql/115)
     * for the online parity check. Never throws — offline or an older
     * schema simply returns null and the local offline math stands alone.
     */
    suspend fun fetchServerSummary(vineyardId: String): PruningSyncRepository.ServerSummary? =
        if (!canSync()) null else runCatching { repo.fetchVineyardSummary(vineyardId) }.getOrNull()

    // MARK: Outbox plumbing

    private fun enqueueCoalesced(entityType: String, opType: String, payloadJson: String, clientId: String) {
        pending.list()
            .filter {
                it.entityType == entityType && it.opType == opType && it.clientId == clientId &&
                    it.status in PendingWriteStatus.unresolved
            }
            .forEach { pending.remove(it.id) }
        pending.enqueue(entityType = entityType, opType = opType, payloadJson = payloadJson, clientId = clientId)
    }

    private fun removeUnresolved(entityType: String, opType: String, clientId: String) {
        pending.list()
            .filter {
                it.entityType == entityType && it.opType == opType && it.clientId == clientId &&
                    it.status in PendingWriteStatus.unresolved
            }
            .forEach { pending.remove(it.id) }
    }

    /**
     * @param conflictIsSuccess whether an HTTP 409 means "row already exists —
     * idempotent success" (true for the merge-duplicates season upsert) or a
     * genuine failure that must be retried (false for the guarded
     * `record_pruning_entry` RPC, where every insert is ON CONFLICT-protected
     * and a 409 signals a real collision such as the pre-SQL-116 season wedge).
     */
    private suspend fun replayPass(
        entityType: String,
        opType: String,
        conflictIsSuccess: Boolean = true,
        action: suspend (PendingWrite) -> Unit,
    ) {
        val candidates = pending.list().filter {
            it.entityType == entityType && it.opType == opType &&
                (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
        }
        for (write in candidates) {
            pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
            try {
                action(write)
                pending.remove(write.id)
            } catch (_: BackendError.Unauthorized) {
                retryOrBlock(write, "Sign-in needed to sync pruning work.")
            } catch (e: BackendError.Server) {
                when {
                    e.code == 409 && conflictIsSuccess -> pending.remove(write.id)
                    e.code == 409 -> retryOrBlock(write, "Conflict (409) — will retry.")
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Rejected (${e.code}).")
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
    }

    /** Demotes BLOCKED pruning writes back to FAILED so an explicit refresh retries them. */
    private fun retryBlockedPruningWrites() {
        pending.list()
            .filter {
                it.status == PendingWriteStatus.BLOCKED &&
                    (it.entityType == PendingEntityType.PRUNING_SEASON ||
                        it.entityType == PendingEntityType.PRUNING_ENTRY ||
                        // An activity blocked waiting for its Work Task must get
                        // another cycle once that task lands.
                        it.entityType == PendingEntityType.PRUNING_ACTIVITY)
            }
            .forEach { pending.updateStatus(it.id, PendingWriteStatus.FAILED, it.lastError) }
    }

    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        const val MAX_ATTEMPTS = 8
        const val TAG = "PruningSync"
    }
}
