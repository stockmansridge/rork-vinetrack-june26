package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for growth-stage record soft-DELETE only (Android Stage N-3).
 *
 * The operator deleted an already-synced growth observation offline (or a
 * transient online delete failed) and the optimistic hide is already showing
 * locally. This replays the soft-delete RPC
 * ([GrowthStageRecordRepository.softDeleteGrowthStageRecord]) and nothing else:
 * it never inserts, never edits, and never touches photo uploads/removals or any
 * other entity. Growth photo writes stay online-only. Growth create is owned by
 * [GrowthRecordCreateSync] (GROWTH_RECORD / CREATE) and edit by
 * [GrowthRecordUpdateSync] (GROWTH_RECORD / UPDATE).
 *
 * Discriminator: delete markers use [PendingEntityType.GROWTH_RECORD] / DELETE so
 * they can never be picked up by the create or update coordinators (each owns its
 * own distinct op), and this coordinator only ever processes
 * GROWTH_RECORD / DELETE rows.
 *
 * Local-only safety: a growth record still queued for CREATE is never deleted via
 * a server marker — the caller
 * ([com.rork.vinetrack.ui.AppViewModel.deleteGrowthStageRecord]) cancels the
 * create (and any same-record update) locally instead, so an offline-created
 * record the operator deleted can't be resurrected by a later
 * [GrowthRecordCreateSync] replay. This coordinator only ever runs against
 * records the server already knows about.
 *
 * Dependency gate (safety net): a delete is never finalised while same-record
 * create / update work is still unresolved — deleting first would race those
 * writes (a CREATE could re-insert the row, an UPDATE would 404 against a gone
 * row). Such a marker is deferred (kept FAILED, retry-eligible, no attempt
 * consumed) until the dependencies clear. The caller additionally cancels a
 * local-only create rather than enqueueing, so this gate is a safety net for
 * markers that appear after enqueue.
 *
 * Idempotency / coalescing: the outbox row is keyed on the growth-record id
 * ([PendingWrite.clientId] = growthRecordId) and only one unresolved delete is
 * ever kept per record. Re-deleting an already soft-deleted row is itself
 * idempotent server-side, and an already-deleted / not-found row is treated as
 * success so a delete can never loop forever.
 *
 * Role / permission: server soft-delete is RLS-restricted (operators may create
 * and edit growth records but may not delete). A permission/validation rejection
 * is BLOCKED (needs attention) rather than retried forever.
 */
class GrowthRecordDeleteSync(
    private val growthRepo: GrowthStageRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Soft-delete-only replay payload. Just the target growth-record id — nothing else. */
    @Serializable
    data class Payload(val growthRecordId: String)

    /**
     * Queue (or replace) a soft-delete for [growthRecordId]. Coalesces by record
     * id: any earlier unresolved delete write for the same record is removed
     * first so only one is ever replayed. Returns the created outbox row. Callers
     * must only enqueue this for a growth record that exists server-side — a
     * local-only pending-create record is cancelled in place rather than queued
     * for delete.
     */
    fun enqueue(growthRecordId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.GROWTH_RECORD &&
                    it.opType == PendingOpType.DELETE &&
                    it.clientId == growthRecordId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(Payload.serializer(), Payload(growthRecordId))
        return pending.enqueue(
            entityType = PendingEntityType.GROWTH_RECORD,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = growthRecordId,
        )
    }

    /**
     * Cancel a never-synced growth record locally (Android Stage N-3). When the
     * operator deletes a record whose original CREATE hasn't synced yet, there is
     * no server row to delete — instead the queued create (and any same-record
     * update) marker is dropped so no insert/patch ever fires and no DELETE
     * marker is queued. Returns true when a pending create existed and was
     * cancelled; false when the record is already synced server-side (the caller
     * should then take the normal optimistic-hide + enqueue path).
     */
    fun cancelLocalCreate(growthRecordId: String): Boolean {
        val pendingCreate = pending.list().firstOrNull {
            it.entityType == PendingEntityType.GROWTH_RECORD &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == growthRecordId &&
                it.status != PendingWriteStatus.SYNCED
        } ?: return false
        pending.remove(pendingCreate.id)
        pending.list()
            .filter {
                it.entityType == PendingEntityType.GROWTH_RECORD &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == growthRecordId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        return true
    }

    /**
     * Replay every retry-eligible queued growth-record delete. No-ops (returns)
     * if a replay is already running. For each item: mark in-progress, then
     * resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-record create / update still unresolved -> deferred (FAILED,
     *    retry-eligible, no attempt consumed), never deleted,
     *  - soft-delete succeeds (or the row is already gone / not found) -> removed
     *    from the outbox and [onDeleted] fires so the caller can keep the record
     *    hidden,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onDeleted: (growthRecordId: String) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.GROWTH_RECORD &&
                    it.opType == PendingOpType.DELETE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved observation delete.")
                    continue
                }
                // Dependency gate: never delete while the same record's create /
                // update work is still unresolved. Defer without consuming a retry
                // attempt so a legitimately-waiting delete can't exhaust its cap.
                if (hasUnresolvedDependencies(payload.growthRecordId)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this observation's other changes to sync first.",
                    )
                    continue
                }
                try {
                    growthRepo.softDeleteGrowthStageRecord(payload.growthRecordId)
                    pending.remove(write.id)
                    onDeleted(payload.growthRecordId)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to delete this observation.")
                } catch (e: BackendError.Server) {
                    when {
                        // Already deleted / never existed server-side — the delete
                        // intent is satisfied. Idempotent success.
                        e.code == 404 -> {
                            pending.remove(write.id)
                            onDeleted(payload.growthRecordId)
                        }
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The delete was rejected (${e.code}).",
                        )
                    }
                } catch (e: Exception) {
                    retryOrBlock(write, e.message ?: "No connection.")
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    /**
     * True when the same growth record still has an unresolved create or update
     * marker (pending / in-progress / failed / blocked). The delete waits for
     * those to land (or be resolved) rather than racing an insert or PATCHing /
     * deleting in the wrong order.
     */
    private fun hasUnresolvedDependencies(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.GROWTH_RECORD &&
                (it.opType == PendingOpType.CREATE || it.opType == PendingOpType.UPDATE) &&
                it.status in PendingWriteStatus.unresolved
        }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        /** Cap retries so a persistently-failing delete can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
