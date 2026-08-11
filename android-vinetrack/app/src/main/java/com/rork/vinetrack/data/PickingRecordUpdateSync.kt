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
 * Offline replay coordinator for picking-record UPDATE only (sql/180).
 *
 * The member edited an existing Detailed pick offline (or a transient online
 * PATCH failed) and the edited row is already showing locally. This replays
 * [PickingRecordRepository.updatePickingRecord] and nothing else: it never
 * inserts, never deletes, and never touches other entities. CREATE is owned
 * by [PickingRecordCreateSync] and DELETE by [PickingRecordDeleteSync].
 *
 * Coalesced one marker per record id — the LATEST queued edit wins, matching
 * the server's last-write-wins `client_updated_at` contract. Replay is
 * dependency-gated behind an unresolved same-record CREATE so an edit never
 * races its own insert (an edit of a still-unsynced record is folded into the
 * queued CREATE payload by the caller instead of being queued here).
 *
 * The payload carries the full edited snapshot plus the original
 * clientUpdatedAt; `vintage` and `grape_value` are NEVER carried (both are
 * server-derived). A PATCH that matches no live row (the record was deleted
 * on another device) resolves the marker as moot via [ReplayCallbacks.onMissing].
 * No auth/session/tokens are stored.
 */
class PickingRecordUpdateSync(
    private val pickingRepo: PickingRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Full edited snapshot needed to replay the PATCH. */
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
        val varietyAllocationId: String? = null,
        val clone: String? = null,
        val rootstock: String? = null,
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
    ) {
        fun toRecord(): PickingRecord = PickingRecord(
            id = id,
            vineyardId = vineyardId,
            pickedAt = pickedAt,
            paddockId = paddockId,
            paddockName = paddockName,
            varietyId = varietyId,
            varietyKey = varietyKey,
            varietyName = varietyName,
            varietyAllocationId = varietyAllocationId,
            clone = clone,
            rootstock = rootstock,
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

        companion object {
            fun from(record: PickingRecord, clientUpdatedAt: String): Payload = Payload(
                id = record.id,
                vineyardId = record.vineyardId,
                pickedAt = record.pickedAt,
                paddockId = record.paddockId,
                paddockName = record.paddockName,
                varietyId = record.varietyId,
                varietyKey = record.varietyKey,
                varietyName = record.varietyName,
                varietyAllocationId = record.varietyAllocationId,
                clone = record.clone,
                rootstock = record.rootstock,
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
        }
    }

    /**
     * Queue (or replace) a picking-record edit for later replay. Coalesces by
     * record id so only the latest edit is ever replayed per record.
     */
    fun enqueue(record: PickingRecord, clientUpdatedAt: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.PICKING_RECORD &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == record.id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload.from(record, clientUpdatedAt)
        return pending.enqueue(
            entityType = PendingEntityType.PICKING_RECORD,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = record.id,
        )
    }

    /**
     * Replay every retry-eligible queued picking-record edit. [onSynced] fires
     * with the authoritative server row (vintage + grape value re-derived);
     * [onMissing] fires when the row no longer exists (deleted elsewhere) so
     * the caller can drop the stale local copy.
     */
    suspend fun replayAll(
        onSynced: (PickingRecord) -> Unit,
        onMissing: (pickingRecordId: String) -> Unit = {},
    ) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.PICKING_RECORD &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved picking record edit.")
                    continue
                }
                // Dependency gate: never PATCH while the same record's create is
                // still unresolved. Defer without consuming a retry attempt.
                if (hasUnresolvedCreate(payload.id)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this picking record's create to sync first.",
                    )
                    continue
                }
                try {
                    val updated = pickingRepo.updatePickingRecord(payload.toRecord(), payload.clientUpdatedAt)
                    pending.remove(write.id)
                    if (updated != null) {
                        onSynced(updated)
                    } else {
                        // Row deleted on another device — the edit is moot.
                        onMissing(payload.id)
                    }
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this picking record edit.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code == 404 -> {
                            pending.remove(write.id)
                            onMissing(payload.id)
                        }
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The picking record edit was rejected (${e.code}).",
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

    private fun hasUnresolvedCreate(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.PICKING_RECORD &&
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
        const val MAX_ATTEMPTS = 8
    }
}
