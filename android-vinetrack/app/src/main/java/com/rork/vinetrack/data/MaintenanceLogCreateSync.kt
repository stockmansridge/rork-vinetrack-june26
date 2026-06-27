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
 * Offline replay coordinator for maintenance-log CREATE only (Android Stage K-1).
 *
 * The operator logged a maintenance record offline (or a transient online insert
 * failed) and the optimistic row is already showing locally. This replays the
 * additive insert ([MaintenanceLogRepository.createMaintenanceLog]) and nothing
 * else: it never edits an existing log, never finalizes/archives an existing
 * one, never deletes, and never touches invoice/photo upload or any other
 * entity. Maintenance update and delete remain online-only in K-1 (parked for
 * K-2/K-3).
 *
 * Discriminator: create markers use [PendingEntityType.MAINTENANCE_LOG] / CREATE
 * so a future maintenance update/delete queue (different op type) can never pick
 * them up, and this coordinator only ever processes MAINTENANCE_LOG / CREATE
 * rows.
 *
 * Idempotency: the client mints the final maintenance-log UUID up front and uses
 * it as both [PendingWrite.clientId] and the inserted row id, so a retried
 * insert is safe — if the server reports a duplicate primary key (409) the row
 * is already there and we treat it as synced rather than inserting a second log.
 * The original [Payload.clientUpdatedAt] travels in the payload so replay
 * preserves the moment the operator actually saved the log, not when it later
 * synced. `created_by` is never carried — it is resolved from the signed-in
 * session at insert time; `photo_path` is never sent. No auth/session/tokens are
 * stored.
 */
class MaintenanceLogCreateSync(
    private val maintenanceRepo: MaintenanceLogRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full insert payload needed to replay the create. Carries the editable
     * maintenance-log fields plus the stable client id, vineyard scope and
     * original client_updated_at. `created_by`, `photo_path` and server-managed
     * sync columns are deliberately NOT carried.
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
     * Queue (or replace) a maintenance-log create for later replay. Coalesces by
     * log id: any earlier unresolved create for the same id is removed first so
     * only one is ever replayed. The [id] must be the same client-generated id
     * used for the optimistic local row and the eventual server insert.
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
                    it.opType == PendingOpType.CREATE &&
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
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Fold a later edit into a still-pending create (Android Stage K-2). When the
     * operator edits a maintenance log whose original create hasn't synced yet,
     * there is no server row to PATCH — instead the queued create payload is
     * rewritten in place with the latest editable fields and a fresh
     * [clientUpdatedAt], so the eventual insert carries the edited values
     * directly. The stable client [id] and the original [Payload.vineyardId] are
     * preserved. Returns true when a pending create existed and was updated;
     * false when there's nothing to fold into (the caller should then queue a
     * normal MAINTENANCE_LOG / UPDATE instead).
     */
    fun foldEdit(
        id: String,
        input: MaintenanceLogRepository.MaintenanceInput,
        clientUpdatedAt: String,
    ): Boolean {
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.MAINTENANCE_LOG &&
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
        enqueue(id, vineyardId, input, clientUpdatedAt)
        return true
    }

    /**
     * Replay every retry-eligible queued maintenance-log create. No-ops (returns)
     * if a replay is already running. For each item: mark in-progress, POST it,
     * then resolve the outcome:
     *  - success / duplicate (409) -> removed from the outbox; [onSynced] fires
     *    with the server row (success only) so callers can reconcile state,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt) or attempt cap hit ->
     *    blocked so it never loops forever.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (MaintenanceLog) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.MAINTENANCE_LOG &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved maintenance log.")
                    continue
                }
                try {
                    val created = maintenanceRepo.createMaintenanceLog(
                        vineyardId = payload.vineyardId,
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
                        id = payload.id,
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(created)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(write, "Sign-in needed to sync this maintenance log.")
                } catch (e: BackendError.Server) {
                    when {
                        // Duplicate primary key — the client id is already on the
                        // server, so the log exists. Idempotent success; the
                        // optimistic row stays as-is.
                        e.code == 409 -> pending.remove(write.id)
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The maintenance log was rejected (${e.code}).",
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
        /** Cap retries so a persistently-failing maintenance log can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
