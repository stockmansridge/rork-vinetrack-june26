package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for work-task HEADER soft-DELETE only (Android Stage J-3).
 *
 * The operator deleted an already-synced work task offline (or a transient online
 * delete failed) and the optimistic hide is already showing locally. This replays
 * the soft-delete RPC ([WorkTaskRepository.softDeleteWorkTask]) and nothing else:
 * it never hard-deletes, never inserts, never edits, and never touches any line
 * (labour/machine) or any other entity. Work-task create is owned by
 * [WorkTaskCreateSync] (WORK_TASK / CREATE) and work-task edit/finalize by
 * [WorkTaskUpdateSync] (WORK_TASK / UPDATE).
 *
 * Discriminator: delete markers use [PendingEntityType.WORK_TASK] / DELETE so they
 * can never be picked up by the create or update coordinators (each owns its own
 * distinct op), and this coordinator only ever processes WORK_TASK / DELETE rows.
 *
 * Local-only safety: a work task still queued for CREATE is never deleted via a
 * server marker — the caller
 * ([com.rork.vinetrack.ui.AppViewModel.deleteWorkTask]) cancels the create (and
 * any same-task update) locally instead, so an offline-created task the operator
 * deleted can't be resurrected by a later [WorkTaskCreateSync] replay. This
 * coordinator only ever runs against tasks the server already knows about.
 *
 * Dependency gate (safety net): a delete is never finalised while same-task
 * create / update work is still unresolved — deleting first would race those
 * writes (a CREATE could re-insert the row, an UPDATE would 404 against a gone
 * row). Such a marker is deferred (kept FAILED, retry-eligible, no attempt
 * consumed) until the dependencies clear, mirroring [SprayRecordDeleteSync]'s
 * gate. The caller additionally cancels a local-only create rather than
 * enqueueing, so this gate is a safety net for markers that appear after enqueue.
 *
 * Idempotency / coalescing: the outbox row is keyed on the work-task id
 * ([PendingWrite.clientId] = workTaskId) and only one unresolved delete is ever
 * kept per task. Re-deleting an already soft-deleted row is itself idempotent
 * server-side, and an already-deleted / not-found row is treated as success so a
 * delete can never loop forever.
 *
 * Role / permission: server soft-delete is RLS-restricted (owner / manager /
 * supervisor only — operators may not delete). A permission/validation rejection
 * is BLOCKED (needs attention) rather than retried forever.
 *
 * Child-line boundary: labour/machine line queues do not exist yet (parked for
 * J-4/J-5), so there are no child markers to clean up here. When they arrive the
 * caller's local-create cancellation will own any same-task child-marker cleanup.
 */
class WorkTaskDeleteSync(
    private val workTaskRepo: WorkTaskRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /** Soft-delete-only replay payload. Just the target work-task id — nothing else. */
    @Serializable
    data class Payload(val workTaskId: String)

    /**
     * Queue (or replace) a soft-delete for [workTaskId]. Coalesces by task id: any
     * earlier unresolved delete write for the same task is removed first so only
     * one is ever replayed. Returns the created outbox row. Callers must only
     * enqueue this for a work task that exists server-side — a local-only
     * pending-create task is cancelled in place rather than queued for delete.
     */
    fun enqueue(workTaskId: String): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK &&
                    it.opType == PendingOpType.DELETE &&
                    it.clientId == workTaskId &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = json.encodeToString(Payload.serializer(), Payload(workTaskId))
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK,
            opType = PendingOpType.DELETE,
            payloadJson = payload,
            clientId = workTaskId,
        )
    }

    /**
     * Replay every retry-eligible queued work-task delete. No-ops (returns) if a
     * replay is already running. For each item: mark in-progress, then resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-task create / update still unresolved -> deferred (FAILED,
     *    retry-eligible, no attempt consumed), never deleted,
     *  - soft-delete succeeds (or the row is already gone / not found) -> removed
     *    from the outbox and [onDeleted] fires so the caller can keep the task
     *    hidden,
     *  - transient (network / 5xx / expired session) -> back to failed,
     *  - permanent (validation / forbidden) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onDeleted: (workTaskId: String) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.WORK_TASK &&
                    it.opType == PendingOpType.DELETE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved work task delete.")
                    continue
                }
                // Dependency gate: never delete while the same task's create /
                // update work is still unresolved. Defer without consuming a retry
                // attempt so a legitimately-waiting delete can't exhaust its cap.
                if (hasUnresolvedDependencies(payload.workTaskId)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this work task's other changes to sync first.",
                    )
                    continue
                }
                try {
                    workTaskRepo.softDeleteWorkTask(payload.workTaskId)
                    pending.remove(write.id)
                    onDeleted(payload.workTaskId)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to delete this work task.")
                } catch (e: BackendError.Server) {
                    when {
                        // Already deleted / never existed server-side — the delete
                        // intent is satisfied. Idempotent success.
                        e.code == 404 -> {
                            pending.remove(write.id)
                            onDeleted(payload.workTaskId)
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
     * True when the same work task still has an unresolved create or update marker
     * (pending / in-progress / failed / blocked). The delete waits for those to
     * land (or be resolved) rather than racing an insert or PATCHing/deleting in
     * the wrong order.
     */
    private fun hasUnresolvedDependencies(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.WORK_TASK &&
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
