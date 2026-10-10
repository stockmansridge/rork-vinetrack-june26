package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for pin COMPLETION toggles only (Stage 9A).
 *
 * The second write path wired into the pending-write outbox, alongside
 * [PinCreateSync]. It is deliberately narrow: it replays the completion-only
 * write shape ([PinRepository.updatePinCompletion]) — never title/notes/
 * category/mode/row edits, deletes, or photos. Those stay online-only and
 * untouched.
 *
 * Replay shape safety: completion writes carry only `is_completed`, so a
 * delayed replay can never clobber editable fields changed elsewhere. This is
 * why completion was unblocked for offline queueing while text/category/mode
 * edits remain parked (Stage 9B — they need conflict metadata first).
 *
 * Idempotency / coalescing: the outbox row is keyed on the pin id
 * ([PendingWrite.clientId] = pinId) and only one unresolved completion write is
 * ever kept per pin — [enqueue] drops any earlier unresolved completion writes
 * for the same pin so the latest toggle wins. Re-applying the same boolean is
 * itself idempotent.
 *
 * NOTE: `clientUpdatedAt` is intentionally NOT carried in the payload. The
 * current [PendingWrite] model and Android [Pin] model don't decode/send
 * `client_updated_at`/`sync_version`, so there is no clean way to attach it
 * yet. Last-write-wins is acceptable for a completion-only boolean; ordered
 * conflict metadata is parked for Stage 9B.
 */
class PinCompletionSync private constructor(
    private val updateRemote: suspend (String, Boolean) -> Pin,
    private val pending: PendingWriteRepository,
) {
    constructor(pinRepo: PinRepository, pending: PendingWriteRepository) : this(pinRepo::updatePinCompletion, pending)
    internal constructor(pending: PendingWriteRepository, updateRemote: suspend (String, Boolean) -> Pin) : this(updateRemote, pending)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Completion-only replay payload. No editable fields — just the toggle. */
    @Serializable
    data class Payload(val pinId: String, val isCompleted: Boolean)

    /**
     * Queue (or replace) a completion toggle for [pinId]. Coalesces by pin:
     * any earlier unresolved completion write for the same pin is removed first
     * so only the latest toggle is ever replayed (latest toggle wins). Returns
     * the created outbox row.
     */
    fun enqueue(pinId: String, isCompleted: Boolean): PendingWrite {
        // Coalesce — drop earlier unresolved completion writes for this pin so
        // rapid Done/Open taps don't pile up. Synced rows are left alone.
        pending.list()
            .filter {
                it.entityType == PendingEntityType.PIN &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == pinId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(Payload.serializer(), Payload(pinId, isCompleted))
        return pending.enqueue(
            entityType = PendingEntityType.PIN,
            opType = PendingOpType.UPDATE,
            payloadJson = payload,
            clientId = pinId,
        )
    }

    /**
     * Replay every retry-eligible queued completion toggle. No-ops (returns) if
     * a replay is already running. For each item: mark in-progress, PATCH only
     * `is_completed`, then resolve the outcome:
     *  - success -> removed from the outbox; [onSynced] fires with the server
     *    pin so the caller can reconcile completion state by id,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt payload) or attempt cap
     *    hit -> blocked so it never loops forever.
     *
     * Caller is responsible for only invoking this when online and a session
     * token exists.
     */
    suspend fun replayAll(permittedWriteIds: Set<String>? = null, permittedWrites: Map<String, PendingWrite>? = null, onSynced: (Pin) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.PIN &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED) &&
                    (permittedWriteIds == null || it.id in permittedWriteIds) &&
                    (permittedWrites == null || permittedWrites[it.id] == it)
            }
            for (candidate in candidates) {
                val write = pending.claimReplay(candidate, permittedWrites) ?: continue
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    // Unreplayable payload — block it so it can't loop.
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.BLOCKED, "Couldn't read the saved change.")
                    continue
                }
                try {
                    val pin = updateRemote(payload.pinId, payload.isCompleted)
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    if (pending.removeIfCurrent(write)) onSynced(pin)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(write, "Sign-in needed to sync this change.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatusIfCurrent(
                            write,
                            PendingWriteStatus.BLOCKED,
                            "The change was rejected (${e.code}).",
                        )
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    pending.updateStatusIfCurrent(write, PendingWriteStatus.FAILED, "Completion sync was interrupted. Ready to retry.")
                    throw e
                } catch (e: Exception) {
                    // Still offline / transient network failure — leave for next time.
                    retryOrBlock(write, e.message ?: "No connection.")
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.retryIfCurrent(write, error, MAX_ATTEMPTS)
    }

    private companion object {
        /** Cap retries so a persistently-failing toggle can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
