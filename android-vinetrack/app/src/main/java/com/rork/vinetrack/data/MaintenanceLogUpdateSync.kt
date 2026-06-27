package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.MaintenanceLog
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for maintenance-log UPDATE only (Android Stage K-2).
 *
 * The operator edited an existing, already-synced maintenance log offline (or a
 * transient online PATCH failed) and the optimistic edit is already showing
 * locally. This replays the maintenance PATCH
 * ([MaintenanceLogRepository.updateMaintenanceLog]) and nothing else: it never
 * inserts, never deletes, never touches invoice/photo upload or any other
 * entity. Maintenance delete remains online-only / parked for K-3.
 *
 * Discriminator: update markers use [PendingEntityType.MAINTENANCE_LOG] / UPDATE
 * so they can never be picked up by the create coordinator (MAINTENANCE_LOG /
 * CREATE) and this coordinator only ever processes MAINTENANCE_LOG / UPDATE rows.
 *
 * Edit-before-create folding (caller side): when the same log still has an
 * unresolved create, the ViewModel folds the edit into that create payload via
 * [MaintenanceLogCreateSync.foldEdit] and never queues an UPDATE — so a
 * create+edit pair replays as a single edited insert, not an insert then a patch.
 *
 * Dependency gate (safety net): if an UPDATE marker somehow coexists with an
 * unresolved same-log create (e.g. ordering races), it is deferred (kept FAILED,
 * retry-eligible, no attempt consumed) until the create resolves — PATCHing a
 * row the server doesn't have yet would 404.
 *
 * Idempotency / coalescing: the outbox row is keyed on the maintenance-log id
 * ([PendingWrite.clientId] = maintenanceLogId) and only one unresolved update is
 * ever kept per log — [enqueue] drops any earlier unresolved update for the same
 * id so the latest edit wins (last-writer-wins via the queued
 * [Payload.clientUpdatedAt]). No auth/session/tokens are stored; `created_by`
 * and `photo_path` are never carried.
 */
class MaintenanceLogUpdateSync(
    private val maintenanceRepo: MaintenanceLogRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full patch payload needed to replay the edit. Carries the editable
     * maintenance-log fields plus the stable client id, vineyard scope and the
     * [clientUpdatedAt] the operator saved the edit at (last-writer-wins stamp).
     * `created_by`, `photo_path` and server-managed sync columns are deliberately
     * NOT carried.
     */
    @Serializable
    data class Payload(
        val id: String,
        val vineyardId: String,
        val itemName: String,
        val equipmentSource: String? = null,
        val equipmentRefId: String? = null,
        val hours: Double = 0.0,
        val machineHours: Double? = null,
        val workCompleted: String = "",
        val partsUsed: String = "",
        val partsCost: Double = 0.0,
        val labourCost: Double = 0.0,
        val date: String,
        val isArchived: Boolean = false,
        val isFinalized: Boolean = false,
        val clientUpdatedAt: String,
    )

    /**
     * Queue (or replace) a maintenance-log update for later replay. Coalesces by
     * log id: any earlier unresolved update for the same id is removed first so
     * only the latest edit is ever replayed. The [id] must be the same id used
     * for the optimistic local row and the eventual server PATCH.
     */
    fun enqueue(
        id: String,
        vineyardId: String,
        input: MaintenanceLogRepository.MaintenanceInput,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.MAINTENANCE_LOG &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = id,
            vineyardId = vineyardId,
            itemName = input.itemName,
            equipmentSource = input.equipmentSource,
            equipmentRefId = input.equipmentRefId,
            hours = input.hours,
            machineHours = input.machineHours,
            workCompleted = input.workCompleted,
            partsUsed = input.partsUsed,
            partsCost = input.partsCost,
            labourCost = input.labourCost,
            date = input.date,
            isArchived = input.isArchived,
            isFinalized = input.isFinalized,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.MAINTENANCE_LOG,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Replay every retry-eligible queued maintenance-log update. No-ops
     * (returns) if a replay is already running. For each item: mark in-progress,
     * then resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-log create still unresolved -> deferred (FAILED, retry-eligible,
     *    no attempt consumed), never PATCHed against a missing row,
     *  - PATCH succeeds -> removed from the outbox; [onSynced] fires with the
     *    server row so the caller reconciles by id,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (MaintenanceLog) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.MAINTENANCE_LOG &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved maintenance log edit.")
                    continue
                }
                // Dependency gate: never PATCH while the same log's create is
                // still unresolved (the server row may not exist yet). Defer
                // without consuming a retry attempt. Normally the ViewModel folds
                // edits into a pending create so this is only a safety net.
                if (hasUnresolvedCreate(payload.id)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this maintenance log to finish saving first.",
                    )
                    continue
                }
                try {
                    val updated = maintenanceRepo.updateMaintenanceLog(
                        id = payload.id,
                        input = MaintenanceLogRepository.MaintenanceInput(
                            itemName = payload.itemName,
                            equipmentSource = payload.equipmentSource,
                            equipmentRefId = payload.equipmentRefId,
                            hours = payload.hours,
                            machineHours = payload.machineHours,
                            workCompleted = payload.workCompleted,
                            partsUsed = payload.partsUsed,
                            partsCost = payload.partsCost,
                            labourCost = payload.labourCost,
                            date = payload.date,
                            isArchived = payload.isArchived,
                            isFinalized = payload.isFinalized,
                        ),
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(updated)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this maintenance log edit.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The maintenance log edit was rejected (${e.code}).",
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
     * True when the same maintenance log still has an unresolved create marker
     * (pending / in-progress / failed / blocked). The update waits for the create
     * to land rather than PATCHing a server row that doesn't exist yet.
     */
    private fun hasUnresolvedCreate(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.MAINTENANCE_LOG &&
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
