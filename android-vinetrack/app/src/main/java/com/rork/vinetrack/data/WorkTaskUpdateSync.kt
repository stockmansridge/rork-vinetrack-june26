package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.WorkTask
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for work-task HEADER UPDATE only (Android Stage J-2).
 *
 * The operator edited an existing, already-synced work task offline — a metadata
 * change, a finalize/reopen flip, or both coalesced together — (or a transient
 * online PATCH failed) and the optimistic edit is already showing locally. This
 * replays the combined header PATCH ([WorkTaskRepository.applyHeaderUpdate]) and
 * nothing else: it never inserts, never deletes, and never touches any line
 * (labour/machine) or any other entity. Work-task create is owned by
 * [WorkTaskCreateSync] (WORK_TASK / CREATE); work-task delete and the line
 * queues remain online-only / parked for J-3 / J-4-J-5.
 *
 * Discriminator: update markers use [PendingEntityType.WORK_TASK] / UPDATE so
 * they can never be picked up by the create coordinator (WORK_TASK / CREATE)
 * and this coordinator only ever processes WORK_TASK / UPDATE rows.
 *
 * Edit-before-create folding (caller side): when the same task still has an
 * unresolved create, the ViewModel folds the edit/finalize into that create
 * payload via [WorkTaskCreateSync.foldEdit] and never queues an UPDATE — so a
 * create+edit pair replays as a single edited insert, not an insert then a patch.
 *
 * Dependency gate (safety net): if an UPDATE marker somehow coexists with an
 * unresolved same-task create (e.g. ordering races), it is deferred (kept
 * FAILED, retry-eligible, no attempt consumed) until the create resolves —
 * PATCHing a row the server doesn't have yet would 404.
 *
 * Idempotency / coalescing: the outbox row is keyed on the work-task id
 * ([PendingWrite.clientId] = workTaskId) and only one unresolved update is ever
 * kept per task — [enqueue] drops any earlier unresolved update for the same id
 * so the latest edit wins (last-writer-wins via the queued
 * [Payload.clientUpdatedAt]). Metadata edits and finalize flips coalesce into
 * that single marker.
 */
class WorkTaskUpdateSync(
    private val workTaskRepo: WorkTaskRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Combined header update payload. Carries the editable work-task header
     * columns plus the finalize/reopen state and the [clientUpdatedAt] the
     * operator saved the edit at (last-writer-wins stamp). No
     * auth/session/secrets — `created_by` is left untouched server-side on edit.
     */
    @Serializable
    data class Payload(
        val id: String,
        val paddockId: String? = null,
        val paddockName: String,
        val date: String,
        val taskType: String,
        val durationHours: Double,
        val notes: String,
        val isFinalized: Boolean = false,
        val finalizedAt: String? = null,
        val finalizedBy: String? = null,
        val clientUpdatedAt: String,
    )

    /**
     * Queue (or replace) a work-task header update for later replay. Coalesces by
     * task id: any earlier unresolved update for the same id is removed first so
     * only the latest edit is ever replayed. The [id] must be the same id used
     * for the optimistic local row and the eventual server PATCH.
     */
    fun enqueue(
        id: String,
        paddockId: String?,
        paddockName: String?,
        date: String,
        taskType: String,
        durationHours: Double,
        notes: String?,
        isFinalized: Boolean,
        finalizedAt: String?,
        finalizedBy: String?,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = id,
            paddockId = paddockId,
            paddockName = paddockName ?: "",
            date = date,
            taskType = taskType,
            durationHours = durationHours,
            notes = notes ?: "",
            isFinalized = isFinalized,
            finalizedAt = finalizedAt,
            finalizedBy = finalizedBy,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Replay every retry-eligible queued work-task header update. No-ops
     * (returns) if a replay is already running. For each item: mark in-progress,
     * then resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-task create still unresolved -> deferred (FAILED, retry-eligible,
     *    no attempt consumed), never PATCHed against a missing row,
     *  - PATCH succeeds -> removed from the outbox; [onSynced] fires with the
     *    server row so the caller reconciles by id,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (WorkTask) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.WORK_TASK &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved work task edit.")
                    continue
                }
                // Dependency gate: never PATCH while the same task's create is
                // still unresolved (the server row may not exist yet). Defer
                // without consuming a retry attempt. Normally the ViewModel folds
                // edits into a pending create so this is only a safety net.
                if (hasUnresolvedCreate(payload.id)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this work task to finish saving first.",
                    )
                    continue
                }
                try {
                    val updated = workTaskRepo.applyHeaderUpdate(
                        id = payload.id,
                        paddockId = payload.paddockId,
                        paddockName = payload.paddockName,
                        date = payload.date,
                        taskType = payload.taskType,
                        durationHours = payload.durationHours,
                        notes = payload.notes,
                        isFinalized = payload.isFinalized,
                        finalizedAt = payload.finalizedAt,
                        finalizedBy = payload.finalizedBy,
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(updated)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this work task edit.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The work task edit was rejected (${e.code}).",
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
     * True when the same work task still has an unresolved create marker
     * (pending / in-progress / failed / blocked). The update waits for the create
     * to land rather than PATCHing a server row that doesn't exist yet.
     */
    private fun hasUnresolvedCreate(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.WORK_TASK &&
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
        /** Cap retries so a persistently-failing edit can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
