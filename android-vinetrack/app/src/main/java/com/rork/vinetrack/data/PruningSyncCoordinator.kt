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
 * Offline-first coordinator for the Pruning Tracker (System Admin only while
 * in development). Local-first semantics mirroring iOS `PruningSyncService`:
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
            replayPass(PendingEntityType.PRUNING_ENTRY, PendingOpType.CREATE) { write ->
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
            val mergedSetups = remoteSeasons
                .filter { it.deletedAt == null && it.id !in pendingSeasonIds }
                .map { it.toModel() } +
                localSetups.filter { it.id in pendingSeasonIds }
            // Seed: local seasons the server has never seen and that aren't queued.
            localSetups
                .filter { it.id !in remoteSeasonIds && it.id !in pendingSeasonIds }
                .forEach { setup ->
                    enqueueCoalesced(
                        entityType = PendingEntityType.PRUNING_SEASON,
                        opType = PendingOpType.UPDATE,
                        payloadJson = json.encodeToString(PruningBlockSetup.serializer(), setup),
                        clientId = setup.id,
                    )
                }
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
            val mergedEntries = remoteEntries
                .filter { it.deletedAt == null && it.id !in pendingEntryDeleteIds && it.id !in pendingEntryCreateIds }
                .map { it.toModel(segmentsByEntry[it.id].orEmpty()) } +
                localEntries.filter { it.id in pendingEntryCreateIds }
            // Seed: local entries the server has never seen and that aren't queued.
            localEntries
                .filter { it.id !in remoteEntryIds && it.id !in pendingEntryCreateIds && it.id !in pendingEntryDeleteIds }
                .forEach { entry ->
                    enqueueCoalesced(
                        entityType = PendingEntityType.PRUNING_ENTRY,
                        opType = PendingOpType.CREATE,
                        payloadJson = json.encodeToString(PruningEntry.serializer(), entry),
                        clientId = entry.id,
                    )
                }
            store.saveEntries(vineyardId, mergedEntries)

            mergedSetups to mergedEntries
        } catch (_: Exception) {
            store.loadSetups(vineyardId) to store.loadEntries(vineyardId)
        }
    }

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

    private suspend fun replayPass(entityType: String, opType: String, action: suspend (PendingWrite) -> Unit) {
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
                    // Duplicate key — the row already exists (idempotent success).
                    e.code == 409 -> pending.remove(write.id)
                    e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                    else -> pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Rejected (${e.code}).")
                }
            } catch (e: Exception) {
                retryOrBlock(write, e.message ?: "No connection.")
            }
        }
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
