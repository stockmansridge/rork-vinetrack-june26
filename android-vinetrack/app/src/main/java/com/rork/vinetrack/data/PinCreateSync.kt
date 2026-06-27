package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for pin CREATE only (Stage 4A-iv).
 *
 * This is the first — and deliberately the only — write path wired into the
 * pending-write outbox. It is intentionally NOT a general SyncManager: it
 * replays additive, non-destructive `pin` / `create` rows and nothing else.
 * Pin update, complete/toggle, delete, photos, trips, rows, tanks, sprays,
 * fuel, and every other entity remain online-only and untouched.
 *
 * Idempotency: a queued pin carries the client-generated UUID (`PinInput.id`)
 * minted when the user created it offline. Replaying re-uses that same id, so
 * a retried insert is safe — if the server reports a duplicate (409) the row is
 * already there and we treat it as synced rather than creating a second pin.
 */
class PinCreateSync(
    private val pinRepo: PinRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Queue a pin create for later replay. The [input] must already carry its
     * client-generated [PinRepository.PinInput.id]; that id is also stored as
     * the outbox idempotency key.
     */
    fun enqueue(input: PinRepository.PinInput): PendingWrite {
        val clientId = input.id ?: error("Queued pin create requires a client id")
        val payload = json.encodeToString(PinRepository.PinInput.serializer(), input)
        return pending.enqueue(
            entityType = PendingEntityType.PIN,
            opType = PendingOpType.CREATE,
            payloadJson = payload,
            clientId = clientId,
        )
    }

    /**
     * Replay every retry-eligible queued pin create. No-ops (returns) if a
     * replay is already running. For each item: mark in-progress, POST it, then
     * resolve the outcome:
     *  - success / duplicate (409) -> removed from the outbox; [onSynced] fires
     *    with the server pin (success only) so callers can reconcile state,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt) or attempt cap hit ->
     *    blocked so it never loops forever.
     *
     * Caller is responsible for only invoking this when a session token exists.
     */
    suspend fun replayAll(onSynced: (Pin) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.PIN &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val input = runCatching {
                    json.decodeFromString(PinRepository.PinInput.serializer(), write.payloadJson)
                }.getOrNull()
                if (input == null) {
                    // Unreplayable payload — block it so it can't loop.
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved pin.")
                    continue
                }
                try {
                    val pin = pinRepo.createPin(input)
                    pending.remove(write.id)
                    onSynced(pin)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(write, "Sign-in needed to sync this pin.")
                } catch (e: BackendError.Server) {
                    when {
                        // Duplicate primary key — the client id is already on the
                        // server, so the pin exists. Idempotent success.
                        e.code == 409 -> pending.remove(write.id)
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The pin was rejected (${e.code}).",
                        )
                    }
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
        pending.incrementAttempt(write.id)
        val attempts = write.attemptCount + 1
        val status = if (attempts >= MAX_ATTEMPTS) PendingWriteStatus.BLOCKED else PendingWriteStatus.FAILED
        pending.updateStatus(write.id, status, error)
    }

    private companion object {
        /** Cap retries so a persistently-failing pin can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
