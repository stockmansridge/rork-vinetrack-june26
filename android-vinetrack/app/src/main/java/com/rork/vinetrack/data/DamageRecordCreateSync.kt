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
 * Offline replay coordinator for block-damage record CREATE only (Android Stage M-1).
 *
 * The operator recorded block damage offline (or a transient online insert
 * failed) and the optimistic row is already showing locally. This replays the
 * additive insert ([DamageRecordRepository.insertDamageRecord]) and nothing
 * else: it never edits an existing record, never deletes, and never touches any
 * other entity. Damage update and delete are owned by [DamageRecordUpdateSync]
 * (DAMAGE_RECORD / UPDATE) and [DamageRecordDeleteSync] (DAMAGE_RECORD / DELETE).
 *
 * Discriminator: create markers use [PendingEntityType.DAMAGE_RECORD] / CREATE
 * so the update/delete queues (different op type) can never pick them up, and
 * this coordinator only ever processes DAMAGE_RECORD / CREATE rows.
 *
 * Idempotency: the client mints the final damage-record UUID up front and uses
 * it as both [PendingWrite.clientId] and the inserted row id, so a retried
 * insert is safe — if the server reports a duplicate primary key (409) the row
 * is already there and we treat it as synced. The original
 * [Payload.clientUpdatedAt] travels in the payload so replay preserves the
 * moment the operator saved the record. `created_by` is never carried — it is
 * resolved from the signed-in session at insert time. No auth/session/tokens
 * are stored, and the portal-only additive columns are never written.
 */
class DamageRecordCreateSync(
    private val damageRepo: DamageRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full insert payload needed to replay the create. Carries the editable
     * damage fields plus the stable client id, vineyard/paddock scope and
     * original client_updated_at. `created_by` and server-managed sync columns
     * are deliberately NOT carried.
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
     * Queue (or replace) a damage-record create for later replay. Coalesces by
     * record id: any earlier unresolved create for the same id is removed first
     * so only one is ever replayed. The [record] id must be the same
     * client-generated id used for the optimistic local row and the eventual
     * server insert.
     */
    fun enqueue(record: DamageRecord, clientUpdatedAt: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.DAMAGE_RECORD &&
                    it.opType == PendingOpType.CREATE &&
                    it.clientId == record.id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = record.toPayload(clientUpdatedAt)
        return pending.enqueue(
            entityType = PendingEntityType.DAMAGE_RECORD,
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = record.id,
        )
    }

    /**
     * Fold a later edit into a still-pending create (Android Stage M-2). When the
     * operator edits a damage record whose original create hasn't synced yet,
     * there is no server row to PATCH — instead the queued create payload is
     * rewritten in place with the latest fields and a fresh [clientUpdatedAt], so
     * the eventual insert carries the edited values directly. The stable client
     * id is preserved. Returns true when a pending create existed and was
     * updated; false when there's nothing to fold into (the caller should then
     * queue a normal DAMAGE_RECORD / UPDATE instead).
     */
    fun foldEdit(record: DamageRecord, clientUpdatedAt: String): Boolean {
        val existing = pending.list().any {
            it.entityType == PendingEntityType.DAMAGE_RECORD &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == record.id &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (!existing) return false
        enqueue(record, clientUpdatedAt)
        return true
    }

    /**
     * Replay every retry-eligible queued damage-record create. No-ops (returns)
     * if a replay is already running. For each item: mark in-progress, POST it,
     * then resolve the outcome:
     *  - success / duplicate (409) -> removed from the outbox; [onSynced] fires
     *    with the server row (success only) so callers can reconcile state,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden / corrupt) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (DamageRecord) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.DAMAGE_RECORD &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved damage record.")
                    continue
                }
                try {
                    val created = damageRepo.insertDamageRecord(payload.toRecord(), payload.clientUpdatedAt)
                    pending.remove(write.id)
                    onSynced(created)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this damage record.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code == 409 -> pending.remove(write.id)
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The damage record was rejected (${e.code}).",
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

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private fun DamageRecord.toPayload(clientUpdatedAt: String): Payload = Payload(
        id = id,
        vineyardId = vineyardId,
        paddockId = paddockId,
        date = date ?: clientUpdatedAt,
        damageType = type.label,
        damagePercent = damagePercent,
        polygonPoints = polygonPoints ?: emptyList(),
        notes = notes,
        clientUpdatedAt = clientUpdatedAt,
    )

    private companion object {
        /** Cap retries so a persistently-failing damage record can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
