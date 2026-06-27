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
 * Offline replay coordinator for work-task HEADER CREATE only (Android Stage J-1).
 *
 * The operator logged a work task offline (or a transient online insert failed)
 * and the optimistic row is already showing locally. This replays the additive
 * insert ([WorkTaskRepository.createWorkTask]) and nothing else: it never updates
 * an existing task, never finalizes/reopens, never deletes, and never touches any
 * line (labour/machine/paddock) or any other entity. Work-task update,
 * finalize/reopen and delete remain online-only in J-1, and the line queues are
 * parked for J-4/J-5.
 *
 * Discriminator: create markers use [PendingEntityType.WORK_TASK] / CREATE so a
 * future work-task update/delete queue (different op type) can never pick them
 * up, and this coordinator only ever processes WORK_TASK / CREATE rows.
 *
 * Idempotency: the client mints the final work-task UUID up front and uses it as
 * both [PendingWrite.clientId] and the inserted row id, so a retried insert is
 * safe — if the server reports a duplicate primary key (409) the row is already
 * there and we treat it as synced rather than inserting a second task. The
 * original [Payload.clientUpdatedAt] travels in the payload so replay preserves
 * the moment the operator actually saved the task, not when it later synced.
 */
class WorkTaskCreateSync(
    private val workTaskRepo: WorkTaskRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full insert payload needed to replay the create. Carries the editable
     * work-task header fields plus the stable client id, vineyard scope and
     * original client_updated_at. `created_by` is deliberately NOT carried — it is
     * resolved from the signed-in session at insert time, never frozen into the
     * outbox. No auth/session/tokens are stored.
     */
    @Serializable
    data class Payload(
        val id: String,
        val vineyardId: String,
        val paddockId: String? = null,
        val paddockName: String,
        val date: String,
        val taskType: String,
        val durationHours: Double,
        val notes: String,
        val isFinalized: Boolean = false,
        val clientUpdatedAt: String,
    )

    /**
     * Queue (or replace) a work-task create for later replay. Coalesces by task
     * id: any earlier unresolved create for the same id is removed first so only
     * one is ever replayed. The [id] must be the same client-generated id used for
     * the optimistic local row and the eventual server insert.
     */
    fun enqueue(
        id: String,
        vineyardId: String,
        paddockId: String?,
        paddockName: String?,
        date: String,
        taskType: String,
        durationHours: Double,
        notes: String?,
        clientUpdatedAt: String,
        isFinalized: Boolean = false,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.WORK_TASK &&
                    it.opType == PendingOpType.CREATE &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = id,
            vineyardId = vineyardId,
            paddockId = paddockId,
            paddockName = paddockName ?: "",
            date = date,
            taskType = taskType,
            durationHours = durationHours,
            notes = notes ?: "",
            isFinalized = isFinalized,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.WORK_TASK,
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Fold a later edit / finalize change into a still-pending create (Android
     * Stage J-2). When the operator edits (or completes/reopens) a work task
     * whose original create hasn't synced yet, there is no server row to PATCH —
     * instead the queued create payload is rewritten in place with the latest
     * metadata, finalize state, and a fresh [clientUpdatedAt], so the eventual
     * insert carries the edited values directly. The stable client [id] and the
     * original [Payload.vineyardId] are preserved. Returns true when a pending
     * create existed and was updated; false when there's nothing to fold into
     * (the caller should then queue a normal WORK_TASK / UPDATE instead).
     */
    fun foldEdit(
        id: String,
        paddockId: String?,
        paddockName: String?,
        date: String,
        taskType: String,
        durationHours: Double,
        notes: String?,
        isFinalized: Boolean,
        clientUpdatedAt: String,
    ): Boolean {
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK &&
                it.opType == PendingOpType.CREATE &&
                it.clientId == id &&
                it.status != PendingWriteStatus.SYNCED
        }
        if (existing.isEmpty()) return false
        // Preserve the vineyard scope captured when the create was first queued.
        val vineyardId = existing
            .mapNotNull { runCatching { json.decodeFromString(Payload.serializer(), it.payloadJson) }.getOrNull() }
            .firstOrNull()
            ?.vineyardId
            ?: return false
        enqueue(id, vineyardId, paddockId, paddockName, date, taskType, durationHours, notes, clientUpdatedAt, isFinalized)
        return true
    }

    /**
     * Replay every retry-eligible queued work-task create. No-ops (returns) if a
     * replay is already running. For each item: mark in-progress, POST it, then
     * resolve the outcome:
     *  - success / duplicate (409) -> removed from the outbox; [onSynced] fires
     *    with the server row (success only) so callers can reconcile state,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt) or attempt cap hit ->
     *    blocked so it never loops forever.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (WorkTask) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.WORK_TASK &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved work task.")
                    continue
                }
                try {
                    val created = workTaskRepo.createWorkTask(
                        vineyardId = payload.vineyardId,
                        paddockId = payload.paddockId,
                        paddockName = payload.paddockName,
                        date = payload.date,
                        taskType = payload.taskType,
                        durationHours = payload.durationHours,
                        notes = payload.notes,
                        id = payload.id,
                        clientUpdatedAt = payload.clientUpdatedAt,
                        isFinalized = payload.isFinalized,
                    )
                    pending.remove(write.id)
                    onSynced(created)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(write, "Sign-in needed to sync this work task.")
                } catch (e: BackendError.Server) {
                    when {
                        // Duplicate primary key — the client id is already on the
                        // server, so the work task exists. Idempotent success;
                        // the optimistic row stays as-is.
                        e.code == 409 -> pending.remove(write.id)
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The work task was rejected (${e.code}).",
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
        /** Cap retries so a persistently-failing work task can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
