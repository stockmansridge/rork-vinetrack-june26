package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for fuel-log soft-DELETE only (Tier-A Stage H-3).
 *
 * The operator deleted an already-synced fuel log offline (or a transient online
 * delete failed) and the optimistic hide is already showing locally. This
 * replays the soft-delete RPC ([FuelLogRepository.softDeleteFuelLog]) and
 * nothing else: it never hard-deletes, never inserts, never edits, and never
 * touches any other entity. Fuel create is owned by [FuelLogCreateSync]
 * (FUEL_LOG / CREATE) and fuel edit by [FuelLogUpdateSync] (FUEL_LOG / UPDATE).
 *
 * Discriminator: delete markers use [PendingEntityType.FUEL_LOG] / DELETE so they
 * can never be picked up by the create or update coordinators (each owns its own
 * distinct op), and this coordinator only ever processes FUEL_LOG / DELETE rows.
 *
 * Local-only safety: a fuel log still queued for CREATE is never deleted via a
 * server marker — the caller ([com.rork.vinetrack.ui.AppViewModel.deleteFuelLog])
 * cancels the create (and any same-log update) locally instead, so an
 * offline-created log the operator deleted can't be resurrected by a later
 * [FuelLogCreateSync] replay. This coordinator only ever runs against logs the
 * server already knows about.
 *
 * Dependency gate (safety net): a delete is never finalised while same-log
 * create / update work is still unresolved — deleting first would race those
 * writes (a CREATE could re-insert the row, an UPDATE would 404 against a gone
 * row). Such a marker is deferred (kept FAILED, retry-eligible, no attempt
 * consumed) until the dependencies clear, mirroring [TripDeleteSync]'s gate. The
 * caller additionally cancels a local-only create rather than enqueueing, so this
 * gate is a safety net for markers that appear after enqueue.
 *
 * Idempotency / coalescing: the outbox row is keyed on the fuel-log id
 * ([PendingWrite.clientId] = fuelLogId) and only one unresolved delete is ever
 * kept per log. Re-deleting an already soft-deleted row is itself idempotent
 * server-side, and an already-deleted / not-found row is treated as success so a
 * delete can never loop forever.
 */
class FuelLogDeleteSync(
    private val fuelRepo: FuelLogRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Soft-delete-only replay payload. Just the target fuel-log id — nothing else. */
    @Serializable
    data class Payload(val fuelLogId: String)

    /**
     * Queue (or replace) a soft-delete for [fuelLogId]. Coalesces by fuel id: any
     * earlier unresolved delete write for the same log is removed first so only
     * one is ever replayed. Returns the created outbox row. Callers must only
     * enqueue this for a fuel log that exists server-side — a local-only
     * pending-create log is cancelled in place rather than queued for delete.
     */
    fun enqueue(fuelLogId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.FUEL_LOG &&
                    it.opType == PendingOpType.DELETE &&
                    it.clientId == fuelLogId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(Payload.serializer(), Payload(fuelLogId))
        return pending.enqueue(
            entityType = PendingEntityType.FUEL_LOG,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = fuelLogId,
        )
    }

    /**
     * Replay every retry-eligible queued fuel-log delete. No-ops (returns) if a
     * replay is already running. For each item: mark in-progress, then resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-log create / update still unresolved -> deferred (FAILED,
     *    retry-eligible, no attempt consumed), never deleted,
     *  - soft-delete succeeds (or the row is already gone / not found) -> removed
     *    from the outbox and [onDeleted] fires so the caller can keep the log
     *    hidden,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onDeleted: (fuelLogId: String) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.FUEL_LOG &&
                    it.opType == PendingOpType.DELETE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved fuel log delete.")
                    continue
                }
                // Dependency gate: never delete while the same log's create /
                // update work is still unresolved. Defer without consuming a retry
                // attempt so a legitimately-waiting delete can't exhaust its cap.
                if (hasUnresolvedDependencies(payload.fuelLogId)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this fuel log's other changes to sync first.",
                    )
                    continue
                }
                try {
                    fuelRepo.softDeleteFuelLog(payload.fuelLogId)
                    pending.remove(write.id)
                    onDeleted(payload.fuelLogId)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to delete this fuel log.")
                } catch (e: BackendError.Server) {
                    when {
                        // Already deleted / never existed server-side — the delete
                        // intent is satisfied. Idempotent success.
                        e.code == 404 -> {
                            pending.remove(write.id)
                            onDeleted(payload.fuelLogId)
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
     * True when the same fuel log still has an unresolved create or update marker
     * (pending / in-progress / failed / blocked). The delete waits for those to
     * land (or be resolved) rather than racing an insert or PATCHing/deleting in
     * the wrong order.
     */
    private fun hasUnresolvedDependencies(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.FUEL_LOG &&
                (it.opType == PendingOpType.CREATE || it.opType == PendingOpType.UPDATE) &&
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
        /** Cap retries so a persistently-failing delete can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
