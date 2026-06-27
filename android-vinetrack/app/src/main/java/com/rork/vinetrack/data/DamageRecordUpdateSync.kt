package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.DamageRecord
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for block-damage record UPDATE only (Android Stage M-2).
 *
 * The operator edited an existing, already-synced damage record offline (or a
 * transient online PATCH failed) and the optimistic edit is already showing
 * locally. This replays the damage PATCH
 * ([DamageRecordRepository.updateDamageRecord]) and nothing else: it never
 * inserts, never deletes, and never touches any other entity. Create is owned by
 * [DamageRecordCreateSync] and delete by [DamageRecordDeleteSync].
 *
 * Discriminator: update markers use [PendingEntityType.DAMAGE_RECORD] / UPDATE
 * so they can never be picked up by the create coordinator (DAMAGE_RECORD /
 * CREATE) and this coordinator only ever processes DAMAGE_RECORD / UPDATE rows.
 *
 * Edit-before-create folding (caller side): when the same record still has an
 * unresolved create, the ViewModel folds the edit into that create payload via
 * [DamageRecordCreateSync.foldEdit] and never queues an UPDATE — so a
 * create+edit pair replays as a single edited insert, not an insert then a patch.
 *
 * Dependency gate (safety net): if an UPDATE marker somehow coexists with an
 * unresolved same-record create, it is deferred (kept FAILED, retry-eligible, no
 * attempt consumed) until the create resolves — PATCHing a row the server
 * doesn't have yet would 404.
 *
 * Idempotency / coalescing: the outbox row is keyed on the damage-record id
 * ([PendingWrite.clientId] = damageRecordId) and only one unresolved update is
 * ever kept per record — [enqueue] drops any earlier unresolved update so the
 * latest edit wins (last-writer-wins via the queued [Payload.clientUpdatedAt]).
 * No auth/session/tokens are stored; `created_by` is never carried and the
 * portal-only additive columns are never written.
 */
class DamageRecordUpdateSync(
    private val damageRepo: DamageRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full patch payload needed to replay the edit. Carries the editable damage
     * fields plus the stable client id, vineyard/paddock scope and the
     * [clientUpdatedAt] the operator saved the edit at (last-writer-wins stamp).
     */
    @Serializable
    data class Payload(
        val id: String,
        val vineyardId: String,
        val paddockId: String,
        val date: String,
        val damageType: String,
        val damagePercent: Double,
        val polygonPoints: List<CoordinatePoint>,
        val notes: String,
        val clientUpdatedAt: String,
    ) {
        /** Reconstruct the persistable [DamageRecord] from this payload. */
        fun toRecord(): DamageRecord = DamageRecord(
            id = id,
            vineyardId = vineyardId,
            paddockId = paddockId,
            date = date,
            damageType = damageType,
            damagePercent = damagePercent,
            polygonPoints = polygonPoints,
            notes = notes,
        )
    }

    /**
     * Queue (or replace) a damage-record update for later replay. Coalesces by
     * record id: any earlier unresolved update for the same id is removed first
     * so only the latest edit is ever replayed.
     */
    fun enqueue(record: DamageRecord, clientUpdatedAt: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.DAMAGE_RECORD &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == record.id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = record.id,
            vineyardId = record.vineyardId,
            paddockId = record.paddockId,
            date = record.date ?: clientUpdatedAt,
            damageType = record.type.label,
            damagePercent = record.damagePercent,
            polygonPoints = record.polygonPoints ?: emptyList(),
            notes = record.notes,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.DAMAGE_RECORD,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = record.id,
        )
    }

    /**
     * Replay every retry-eligible queued damage-record update. No-ops (returns)
     * if a replay is already running. For each item: mark in-progress, then
     * resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-record create still unresolved -> deferred (FAILED, retry-eligible,
     *    no attempt consumed), never PATCHed against a missing row,
     *  - PATCH succeeds -> removed from the outbox; [onSynced] fires with the
     *    server row so the caller reconciles by id,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (DamageRecord) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.DAMAGE_RECORD &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved damage record edit.")
                    continue
                }
                if (hasUnresolvedCreate(payload.id)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this damage record to finish saving first.",
                    )
                    continue
                }
                try {
                    val updated = damageRepo.updateDamageRecord(payload.toRecord(), payload.clientUpdatedAt)
                    pending.remove(write.id)
                    onSynced(updated)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this damage record edit.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The damage record edit was rejected (${e.code}).",
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
     * True when the same damage record still has an unresolved create marker
     * (pending / in-progress / failed / blocked). The update waits for the create
     * to land rather than PATCHing a server row that doesn't exist yet.
     */
    private fun hasUnresolvedCreate(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.DAMAGE_RECORD &&
                it.opType == PendingOpType.CREATE &&
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
        /** Cap retries so a persistently-failing edit can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
