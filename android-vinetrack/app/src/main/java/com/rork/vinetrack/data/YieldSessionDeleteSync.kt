package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for yield-estimation session DELETE only (Android
 * Stage Q).
 *
 * The operator deleted a yield-estimation session offline (or a transient online
 * soft-delete failed) and the row is already hidden locally. This replays the
 * soft-delete RPC ([YieldEstimationSessionRepository.softDeleteSession]) and
 * nothing else.
 *
 * Discriminator: [PendingEntityType.YIELD_SESSION] / DELETE, keyed by session id
 * ([PendingWrite.clientId] = sessionId). When a delete is enqueued, any still
 * unresolved SAVE for the same session id is dropped — there is no point
 * upserting a session we are about to soft-delete (and [YieldSessionSaveSync]
 * also defers/cancels saves while a delete is queued). Replay ordering: the save
 * pass runs first, then the delete pass.
 *
 * Idempotency / permissions: the soft-delete RPC is naturally idempotent (a
 * not-found / already-deleted row is treated as success). Soft-delete is
 * RLS-restricted to owner/manager/supervisor, so a permission rejection BLOCKS
 * (needs attention) rather than retrying forever. No auth/session/tokens stored.
 */
class YieldSessionDeleteSync(
    private val sessionRepo: YieldEstimationSessionRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val replayLock = Mutex()

    @Serializable
    data class Payload(val id: String)

    /**
     * Queue (or replace) a yield-session delete. Cancels any unresolved save for
     * the same session id, then coalesces by id so only one delete is replayed.
     */
    fun enqueue(sessionId: String): PendingWrite {
        // Cancel any pending save for this session — it must not be upserted.
        pending.list()
            .filter {
                it.entityType == PendingEntityType.YIELD_SESSION &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == sessionId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        // Coalesce existing deletes for this session.
        pending.list()
            .filter {
                it.entityType == PendingEntityType.YIELD_SESSION &&
                    it.opType == PendingOpType.DELETE &&
                    it.clientId == sessionId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        return pending.enqueue(
            entityType = PendingEntityType.YIELD_SESSION,
            opType = PendingOpType.DELETE,
            payloadJson = json.encodeToString(Payload.serializer(), Payload(sessionId)),
            clientId = sessionId,
        )
    }

    suspend fun replayAll(onSynced: (String) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.YIELD_SESSION &&
                    it.opType == PendingOpType.DELETE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the delete request.")
                    continue
                }
                try {
                    sessionRepo.softDeleteSession(payload.id)
                    pending.remove(write.id)
                    onSynced(payload.id)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this delete.")
                } catch (e: BackendError.Server) {
                    when {
                        // Already gone — idempotent success.
                        e.code == 404 -> {
                            pending.remove(write.id)
                            onSynced(payload.id)
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
