package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingPhotoStatus
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for pin soft-DELETE only (Tier-A Stage G-1).
 *
 * The fifth narrow pin write path wired into the pending-write outbox, alongside
 * [PinCreateSync] (create), [PinCompletionSync] (Done/Open toggle),
 * [PinEditSync] (descriptive edit) and [PinPhotoSync] (photo). It replays the
 * soft-delete write shape ([PinRepository.softDeletePin]) and nothing else: it
 * never hard-deletes, never touches other entities, and never performs any
 * destructive local recovery. Trip delete remains online-only and untouched.
 *
 * Discriminator: delete markers use [PendingEntityType.PIN] / DELETE so they are
 * never picked up by the create queue (PIN / CREATE), the completion queue
 * (PIN / UPDATE), the edit queue (PIN_EDIT / UPDATE) or the photo queue (which
 * only ever processes [com.rork.vinetrack.data.model.PendingPhotoAttachment]
 * rows). Conversely this coordinator only ever processes PIN / DELETE rows.
 *
 * Local-only safety: a pin still queued for CREATE is never deleted via a server
 * marker — the caller (AppViewModel.deletePin) cancels the create locally
 * instead, so an offline-created pin the user deleted can't be resurrected by a
 * later [PinCreateSync] replay. This coordinator only ever runs against pins the
 * server already knows about.
 *
 * Dependency gate: a delete is never finalised while same-pin create / completion
 * / edit / photo work is still unresolved — deleting first would race those
 * writes or orphan a photo upload. Such a marker is deferred (kept FAILED,
 * retry-eligible, no attempt consumed) until the dependencies clear, mirroring
 * [TripEndSync]'s gate.
 *
 * Idempotency / coalescing: the outbox row is keyed on the pin id
 * ([PendingWrite.clientId] = pinId) and only one unresolved delete is ever kept
 * per pin. Re-deleting an already soft-deleted row is itself idempotent
 * server-side, and an already-deleted / not-found row is treated as success so a
 * delete can never loop forever.
 */
class PinDeleteSync(
    private val pinRepo: PinRepository,
    private val pending: PendingWriteRepository,
    private val pendingPhotos: PendingPhotoRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Soft-delete-only replay payload. Just the target pin id — nothing else. */
    @Serializable
    data class Payload(val pinId: String)

    /**
     * Queue (or replace) a soft-delete for [pinId]. Coalesces by pin: any earlier
     * unresolved delete write for the same pin is removed first so only one is
     * ever replayed. Returns the created outbox row. Callers must only enqueue
     * this for a pin that exists (or will exist) server-side — a local-only
     * pending-create pin is cancelled in place rather than queued for delete.
     */
    fun enqueue(pinId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.PIN &&
                    it.opType == PendingOpType.DELETE &&
                    it.clientId == pinId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(Payload.serializer(), Payload(pinId))
        return pending.enqueue(
            entityType = PendingEntityType.PIN,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = pinId,
        )
    }

    /**
     * Replay every retry-eligible queued pin delete. No-ops (returns) if a replay
     * is already running. For each item: mark in-progress, then resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-pin create / completion / edit / photo still unresolved -> deferred
     *    (FAILED, retry-eligible, no attempt consumed), never deleted,
     *  - soft-delete succeeds (or the row is already gone / not found) -> removed
     *    from the outbox, the now-orphaned retained photo is cleaned up, and
     *    [onDeleted] fires so the caller can keep the pin hidden,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onDeleted: (pinId: String) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.PIN &&
                    it.opType == PendingOpType.DELETE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved pin delete.")
                    continue
                }
                // Dependency gate: never delete while same-pin create / completion
                // / edit / photo work is still unresolved. Defer without consuming
                // a retry attempt so a legitimately-waiting delete can't exhaust
                // its cap.
                if (hasUnresolvedDependencies(payload.pinId)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this pin's other changes to sync first.",
                    )
                    continue
                }
                try {
                    pinRepo.softDeletePin(payload.pinId)
                    pending.remove(write.id)
                    cleanupRetainedPhoto(payload.pinId)
                    onDeleted(payload.pinId)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to delete this pin.")
                } catch (e: BackendError.Server) {
                    when {
                        // Already deleted / never existed server-side — the delete
                        // intent is satisfied. Idempotent success.
                        e.code == 404 -> {
                            pending.remove(write.id)
                            cleanupRetainedPhoto(payload.pinId)
                            onDeleted(payload.pinId)
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
     * True when any same-pin write (create / completion / edit) or retained photo
     * attachment is still unresolved (pending / in-progress / failed / blocked).
     * A blocked dependency also counts — the delete waits for the operator to
     * resolve it rather than racing or orphaning unsynced work.
     */
    private fun hasUnresolvedDependencies(pinId: String): Boolean {
        val writeDep = pending.list().any {
            it.clientId == pinId &&
                it.status in PendingWriteStatus.unresolved &&
                (
                    (it.entityType == PendingEntityType.PIN && it.opType == PendingOpType.CREATE) ||
                        (it.entityType == PendingEntityType.PIN && it.opType == PendingOpType.UPDATE) ||
                        it.entityType == PendingEntityType.PIN_EDIT
                )
        }
        if (writeDep) return true
        return pendingPhotos.list().any {
            it.clientPinId == pinId && it.status in PendingPhotoStatus.unresolved
        }
    }

    /**
     * Drop any retained photo attachment for a now-deleted pin. Only reached once
     * the dependency gate has confirmed no photo upload is still unresolved, so
     * this removes at most an already-uploaded leftover row plus its (already
     * deleted) local file. Never deletes a pending photo before its parent delete
     * is confirmed.
     */
    private fun cleanupRetainedPhoto(pinId: String) {
        pendingPhotos.list()
            .filter { it.clientPinId == pinId }
            .forEach { pendingPhotos.remove(it.id) }
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
