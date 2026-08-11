package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for picking-record soft-DELETE only (sql/180).
 *
 * Mirrors [YieldRecordDeleteSync]: replays the `soft_delete_picking_record`
 * RPC and nothing else. A picking record still queued for CREATE is cancelled
 * locally by the caller via [cancelLocalCreate] instead of being queued for
 * delete, and the replay dependency-gates on an unresolved same-record create
 * so a delete never races its own insert. Coalesced one-per record id;
 * already-deleted / not-found rows resolve as success. Soft-delete is
 * RLS-restricted (owner/manager/supervisor) so a permission rejection BLOCKS
 * rather than retrying forever.
 */
class PickingRecordDeleteSync(
    private val pickingRepo: PickingRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Soft-delete-only replay payload — just the target record id. */
    @Serializable
    data class Payload(val pickingRecordId: String)

    /** Queue (or replace) a soft-delete for [pickingRecordId]. */
    fun enqueue(pickingRecordId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.PICKING_RECORD &&
                    it.opType == PendingOpType.DELETE &&
                    it.clientId == pickingRecordId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(Payload.serializer(), Payload(pickingRecordId))
        return pending.enqueue(
            entityType = PendingEntityType.PICKING_RECORD,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = pickingRecordId,
        )
    }

    /**
     * Cancel a never-synced picking record locally: when its CREATE hasn't
     * synced yet there is no server row to delete — the queued create marker is
     * dropped so no insert ever fires. Returns true when a pending create
     * existed and was cancelled.
     */
    fun cancelLocalCreate(pickingRecordId: String): Boolean {
        val pendingCreate = pending.list().firstOrNull {
            it.entityType == PendingEntityType.PICKING_RECORD &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == pickingRecordId &&
                it.status != PendingWriteStatus.SYNCED
        } ?: return false
        pending.remove(pendingCreate.id)
        return true
    }

    /** Replay every retry-eligible queued picking-record delete. */
    suspend fun replayAll(onDeleted: (pickingRecordId: String) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.PICKING_RECORD &&
                    it.opType == PendingOpType.DELETE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved picking record delete.")
                    continue
                }
                // Dependency gate: never delete while the same record's create is
                // still unresolved. Defer without consuming a retry attempt.
                if (hasUnresolvedCreate(payload.pickingRecordId)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this picking record's create to sync first.",
                    )
                    continue
                }
                try {
                    pickingRepo.softDeletePickingRecord(payload.pickingRecordId)
                    pending.remove(write.id)
                    onDeleted(payload.pickingRecordId)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to delete this picking record.")
                } catch (e: BackendError.Server) {
                    when {
                        // Already deleted / never existed — the intent is satisfied.
                        e.code == 404 -> {
                            pending.remove(write.id)
                            onDeleted(payload.pickingRecordId)
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
