package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for spray-record soft-DELETE only (Android Stage I-3).
 *
 * The operator deleted an already-synced spray record offline (or a transient
 * online delete failed) and the optimistic hide is already showing locally. This
 * replays the soft-delete RPC ([SprayRecordRepository.softDeleteSprayRecord]) and
 * nothing else: it never hard-deletes, never inserts, never edits, and never
 * touches any other entity. Spray create is owned by [SprayRecordCreateSync]
 * (SPRAY_RECORD / CREATE) and spray edit by [SprayRecordUpdateSync]
 * (SPRAY_RECORD / UPDATE).
 *
 * Discriminator: delete markers use [PendingEntityType.SPRAY_RECORD] / DELETE so
 * they can never be picked up by the create or update coordinators (each owns its
 * own distinct op), and this coordinator only ever processes SPRAY_RECORD /
 * DELETE rows.
 *
 * Local-only safety: a spray record still queued for CREATE is never deleted via a
 * server marker — the caller
 * ([com.rork.vinetrack.ui.AppViewModel.deleteSprayRecord]) cancels the create (and
 * any same-record update) locally instead, so an offline-created record the
 * operator deleted can't be resurrected by a later [SprayRecordCreateSync] replay.
 * This coordinator only ever runs against records the server already knows about.
 *
 * Dependency gate (safety net): a delete is never finalised while same-record
 * create / update work is still unresolved — deleting first would race those
 * writes (a CREATE could re-insert the row, an UPDATE would 404 against a gone
 * row). Such a marker is deferred (kept FAILED, retry-eligible, no attempt
 * consumed) until the dependencies clear, mirroring [FuelLogDeleteSync]'s gate.
 * The caller additionally cancels a local-only create rather than enqueueing, so
 * this gate is a safety net for markers that appear after enqueue.
 *
 * Idempotency / coalescing: the outbox row is keyed on the spray-record id
 * ([PendingWrite.clientId] = sprayRecordId) and only one unresolved delete is ever
 * kept per record. Re-deleting an already soft-deleted row is itself idempotent
 * server-side, and an already-deleted / not-found row is treated as success so a
 * delete can never loop forever.
 *
 * Role / permission: server soft-delete is RLS-restricted (owner / manager /
 * supervisor only). A permission/validation rejection is BLOCKED (needs
 * attention) rather than retried forever.
 */
class SprayRecordDeleteSync(
    private val sprayRepo: SprayRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Soft-delete-only replay payload. Just the target spray-record id — nothing else. */
    @Serializable
    data class Payload(val sprayRecordId: String)

    /**
     * Queue (or replace) a soft-delete for [sprayRecordId]. Coalesces by spray id:
     * any earlier unresolved delete write for the same record is removed first so
     * only one is ever replayed. Returns the created outbox row. Callers must only
     * enqueue this for a spray record that exists server-side — a local-only
     * pending-create record is cancelled in place rather than queued for delete.
     */
    fun enqueue(sprayRecordId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.SPRAY_RECORD &&
                    it.opType == PendingOpType.DELETE &&
                    it.clientId == sprayRecordId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(Payload.serializer(), Payload(sprayRecordId))
        return pending.enqueue(
            entityType = PendingEntityType.SPRAY_RECORD,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = sprayRecordId,
        )
    }

    /**
     * Replay every retry-eligible queued spray-record delete. No-ops (returns) if a
     * replay is already running. For each item: mark in-progress, then resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-record create / update still unresolved -> deferred (FAILED,
     *    retry-eligible, no attempt consumed), never deleted,
     *  - soft-delete succeeds (or the row is already gone / not found) -> removed
     *    from the outbox and [onDeleted] fires so the caller can keep the record
     *    hidden,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onDeleted: (sprayRecordId: String) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.SPRAY_RECORD &&
                    it.opType == PendingOpType.DELETE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved spray record delete.")
                    continue
                }
                // Dependency gate: never delete while the same record's create /
                // update work is still unresolved. Defer without consuming a retry
                // attempt so a legitimately-waiting delete can't exhaust its cap.
                if (hasUnresolvedDependencies(payload.sprayRecordId)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this spray record's other changes to sync first.",
                    )
                    continue
                }
                try {
                    sprayRepo.softDeleteSprayRecord(payload.sprayRecordId)
                    pending.remove(write.id)
                    onDeleted(payload.sprayRecordId)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to delete this spray record.")
                } catch (e: BackendError.Server) {
                    when {
                        // Already deleted / never existed server-side — the delete
                        // intent is satisfied. Idempotent success.
                        e.code == 404 -> {
                            pending.remove(write.id)
                            onDeleted(payload.sprayRecordId)
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
     * True when the same spray record still has an unresolved create or update
     * marker (pending / in-progress / failed / blocked). The delete waits for those
     * to land (or be resolved) rather than racing an insert or PATCHing/deleting in
     * the wrong order.
     */
    private fun hasUnresolvedDependencies(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.SPRAY_RECORD &&
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
