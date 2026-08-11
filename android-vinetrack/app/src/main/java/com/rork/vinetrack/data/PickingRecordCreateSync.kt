package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.PickingRecord
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for picking-record CREATE only (sql/180).
 *
 * The operator logged a Detailed pick offline (or a transient online insert
 * failed) and the optimistic row is already showing locally. This replays the
 * additive insert ([PickingRecordRepository.insertPickingRecord]) and nothing
 * else: it never edits, never deletes, and never touches archived yield
 * records or any other entity. Delete is owned by [PickingRecordDeleteSync]
 * (PICKING_RECORD / DELETE).
 *
 * Idempotency: the client mints the final record UUID up front and uses it as
 * both [PendingWrite.clientId] and the inserted row id, so a retried insert is
 * safe — a duplicate primary key (409) means the row is already there and the
 * marker resolves as synced. The payload carries the full insert fields plus
 * the original clientUpdatedAt; `vintage` and `grape_value` are NEVER carried
 * (both are server-derived). `created_by` resolves from the live session at
 * insert time. No auth/session/tokens are stored.
 */
class PickingRecordCreateSync(
    private val pickingRepo: PickingRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Full insert payload needed to replay the create. */
    @Serializable
    data class Payload(
        val id: String,
        val vineyardId: String,
        val pickedAt: String,
        val paddockId: String,
        val paddockName: String,
        val varietyId: String? = null,
        val varietyKey: String? = null,
        val varietyName: String = "",
        val clone: String? = null,
        val weightKg: Double,
        val sugarValue: Double? = null,
        val sugarUnit: String? = null,
        val ph: Double? = null,
        val taGPerL: Double? = null,
        val purpose: String = "",
        val sold: Boolean = false,
        val soldTo: String? = null,
        val pricePerTonne: Double? = null,
        val notes: String = "",
        val clientUpdatedAt: String,
    )

    private fun Payload.toRecord(): PickingRecord = PickingRecord(
        id = id,
        vineyardId = vineyardId,
        pickedAt = pickedAt,
        paddockId = paddockId,
        paddockName = paddockName,
        varietyId = varietyId,
        varietyKey = varietyKey,
        varietyName = varietyName,
        clone = clone,
        weightKg = weightKg,
        sugarValue = sugarValue,
        sugarUnit = sugarUnit,
        ph = ph,
        taGPerL = taGPerL,
        purpose = purpose,
        sold = sold,
        soldTo = soldTo,
        pricePerTonne = pricePerTonne,
        notes = notes,
    )

    /**
     * Queue (or replace) a picking-record create for later replay. Coalesces by
     * record id so only one create is ever replayed per record.
     */
    fun enqueue(record: PickingRecord, clientUpdatedAt: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.PICKING_RECORD &&
                    it.opType == PendingOpType.CREATE &&
                    it.clientId == record.id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = record.id,
            vineyardId = record.vineyardId,
            pickedAt = record.pickedAt,
            paddockId = record.paddockId,
            paddockName = record.paddockName,
            varietyId = record.varietyId,
            varietyKey = record.varietyKey,
            varietyName = record.varietyName,
            clone = record.clone,
            weightKg = record.weightKg,
            sugarValue = record.sugarValue,
            sugarUnit = record.sugarUnit,
            ph = record.ph,
            taGPerL = record.taGPerL,
            purpose = record.purpose,
            sold = record.sold,
            soldTo = record.soldTo,
            pricePerTonne = record.pricePerTonne,
            notes = record.notes,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.PICKING_RECORD,
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = record.id,
        )
    }

    /**
     * True while this record's CREATE marker is still queued/unresolved. Used
     * by the edit flow: editing a record whose insert hasn't synced yet folds
     * the changes into the queued CREATE payload (via [enqueue], which
     * coalesces by record id) instead of queueing an UPDATE the server would
     * reject for a row that doesn't exist yet.
     */
    fun hasUnresolvedCreate(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.PICKING_RECORD &&
                it.opType == PendingOpType.CREATE &&
                it.status in PendingWriteStatus.unresolved
        }

    /**
     * Replay every retry-eligible queued picking-record create. Success and
     * duplicate (409) both resolve the marker; [onSynced] fires with the server
     * row (success only) so the caller can reconcile the authoritative vintage
     * and grape value into state.
     */
    suspend fun replayAll(onSynced: (PickingRecord) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.PICKING_RECORD &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved picking record.")
                    continue
                }
                try {
                    val created = pickingRepo.insertPickingRecord(payload.toRecord(), payload.clientUpdatedAt)
                    pending.remove(write.id)
                    onSynced(created)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this picking record.")
                } catch (e: BackendError.Server) {
                    when {
                        // Duplicate primary key — already inserted. Idempotent success.
                        e.code == 409 -> pending.remove(write.id)
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The picking record was rejected (${e.code}).",
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

    private companion object {
        const val MAX_ATTEMPTS = 8
    }
}
