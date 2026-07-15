package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningEntry
import com.rork.vinetrack.data.model.PruningSegment
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.Json

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

    // MARK: Cached reads

    fun setups(vineyardId: String): List<PruningBlockSetup> = store.loadSetups(vineyardId)

    fun entries(vineyardId: String): List<PruningEntry> = store.loadEntries(vineyardId)

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

    fun deleteEntry(vineyardId: String, entryId: String): List<PruningEntry> {
        val updated = store.deleteEntry(vineyardId, entryId)
        // Drop any unsent create for the same entry, then queue the delete —
        // the delete RPC is a no-op server-side if the entry never landed.
        removeUnresolved(PendingEntityType.PRUNING_ENTRY, PendingOpType.CREATE, entryId)
        enqueueCoalesced(
            entityType = PendingEntityType.PRUNING_ENTRY,
            opType = PendingOpType.DELETE,
            payloadJson = entryId,
            clientId = entryId,
        )
        scope.launch { replayAll() }
        return updated
    }

    // MARK: Replay

    /** Replays queued season upserts, entry creates, then entry deletes. */
    suspend fun replayAll() {
        if (!canSync()) return
        if (!replayLock.tryLock()) return
        try {
            replayPass(PendingEntityType.PRUNING_SEASON, PendingOpType.UPDATE) { write ->
                val setup = json.decodeFromString(PruningBlockSetup.serializer(), write.payloadJson)
                repo.upsertSeason(setup)
            }
            // conflictIsSuccess = false: `record_pruning_entry` guards every
            // insert with ON CONFLICT, so a 409 here is a REAL failure (e.g.
            // the pre-SQL-116 season-id collision) — dropping the write on 409
            // silently lost the entry. Retry instead; SQL 116 resolves the
            // canonical season server-side so the replay now lands.
            replayPass(PendingEntityType.PRUNING_ENTRY, PendingOpType.CREATE, conflictIsSuccess = false) { write ->
                val entry = json.decodeFromString(PruningEntry.serializer(), write.payloadJson)
                repo.recordEntry(entry)
            }
            replayPass(PendingEntityType.PRUNING_ENTRY, PendingOpType.DELETE) { write ->
                repo.deleteEntry(write.clientId)
            }
            replayPass(PendingEntityType.PRUNING_SEASON, PendingOpType.DELETE) { write ->
                repo.softDeleteSeason(write.clientId)
            }
        } finally {
            replayLock.unlock()
        }
    }

    // MARK: Refresh (pull + reconcile)

    /**
     * Replays the queue, pulls the server state and reconciles the local
     * cache. Entries with an unresolved queued create keep their optimistic
     * local segments until the push lands. Falls back to the cache offline.
     */
    suspend fun refresh(vineyardId: String): Pair<List<PruningBlockSetup>, List<PruningEntry>> {
        if (!canSync()) return store.loadSetups(vineyardId) to store.loadEntries(vineyardId)
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
            val pendingEntryDeleteIds = unresolved
                .filter { it.entityType == PendingEntityType.PRUNING_ENTRY && it.opType == PendingOpType.DELETE }
                .map { it.clientId }.toSet()

            val remoteSeasons = repo.fetchSeasons(vineyardId)
            val remoteEntries = repo.fetchEntries(vineyardId)
            val remoteSegments = repo.fetchSegments(vineyardId)

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
            val mergedSetups = remoteSeasons
                .filter { it.deletedAt == null && it.id !in pendingSeasonIds }
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
                .filter { it.id !in remoteEntryIds && it.id !in pendingEntryCreateIds && it.id !in pendingEntryDeleteIds }
            seededEntries.forEach { entry ->
                enqueueCoalesced(
                    entityType = PendingEntityType.PRUNING_ENTRY,
                    opType = PendingOpType.CREATE,
                    payloadJson = json.encodeToString(PruningEntry.serializer(), entry),
                    clientId = entry.id,
                )
            }
            val mergedEntries = remoteEntries
                .filter { it.deletedAt == null && it.id !in pendingEntryDeleteIds && it.id !in pendingEntryCreateIds }
                .map { it.toModel(segmentsByEntry[it.id].orEmpty()) } +
                localEntries.filter { it.id in pendingEntryCreateIds } +
                seededEntries
            store.saveEntries(vineyardId, mergedEntries)

            mergedSetups to mergedEntries
        } catch (_: Exception) {
            store.loadSetups(vineyardId) to store.loadEntries(vineyardId)
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
                    (it.entityType == PendingEntityType.PRUNING_SEASON || it.entityType == PendingEntityType.PRUNING_ENTRY)
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
    }
}
