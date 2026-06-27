package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.YieldEstimationSession
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for yield-estimation session SAVE (upsert) only
 * (Android Stage Q).
 *
 * The operator created or edited a working yield-estimation session offline (set
 * blocks, generated sample sites, recorded bunch counts, marked complete) or a
 * transient online upsert failed, and the optimistic session is already showing
 * locally. This replays the merge-duplicates upsert
 * ([YieldEstimationSessionRepository.upsertSession]) and nothing else: it never
 * deletes and never touches another entity.
 *
 * Discriminator: [PendingEntityType.YIELD_SESSION] / UPDATE. Both create and
 * edit fold into this single upsert op (the table is keyed by session id), so a
 * separate create queue is unnecessary.
 *
 * Coalescing / idempotency: the outbox row is keyed on the session id
 * ([PendingWrite.clientId] = sessionId) and only one unresolved save is ever
 * kept per session — [enqueue] drops any earlier unresolved save so the latest
 * full session payload wins (last-writer-wins via [Payload.clientUpdatedAt]).
 * Re-applying the same upsert is idempotent server-side. `created_by` is
 * resolved from the signed-in session at upsert time; no auth/session/tokens are
 * stored. A queued DELETE for the same session id cancels any pending save (see
 * [YieldSessionDeleteSync]).
 */
class YieldSessionSaveSync(
    private val sessionRepo: YieldEstimationSessionRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Full upsert payload: the whole session plus its last-writer-wins stamp. */
    @Serializable
    data class Payload(
        val session: YieldEstimationSession,
        val clientUpdatedAt: String,
    )

    /**
     * Queue (or replace) a yield-session save for later replay. Coalesces by
     * session id: any earlier unresolved save for the same id is removed first
     * so only the latest session payload is ever replayed.
     */
    fun enqueue(session: YieldEstimationSession, clientUpdatedAt: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.YIELD_SESSION &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == session.id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(session = session, clientUpdatedAt = clientUpdatedAt)
        return pending.enqueue(
            entityType = PendingEntityType.YIELD_SESSION,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = session.id,
        )
    }

    /**
     * Replay every retry-eligible queued yield-session save. No-ops if a replay
     * is already running. For each item: mark in-progress, upsert, then resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - upsert succeeds -> removed; [onSynced] fires with the server session,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (YieldEstimationSession) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.YIELD_SESSION &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                // Defer if a delete for the same session is still queued — the
                // delete pass cancels saves, so never resurrect a deleted session.
                val hasDelete = pending.list().any {
                    it.entityType == PendingEntityType.YIELD_SESSION &&
                        it.opType == PendingOpType.DELETE &&
                        it.clientId == write.clientId &&
                        it.status != PendingWriteStatus.SYNCED
                }
                if (hasDelete) {
                    pending.remove(write.id)
                    continue
                }
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved estimation.")
                    continue
                }
                try {
                    val saved = sessionRepo.upsertSession(payload.session, payload.clientUpdatedAt)
                    pending.remove(write.id)
                    onSynced(saved)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this estimation.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The estimation was rejected (${e.code}).",
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
