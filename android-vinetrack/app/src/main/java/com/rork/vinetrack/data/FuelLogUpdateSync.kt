package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.TractorFuelLog
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for fuel-log UPDATE only (Tier-A Stage H-2).
 *
 * The operator edited an existing, already-synced fuel log offline (or a
 * transient online PATCH failed) and the optimistic edit is already showing
 * locally. This replays the editable-column PATCH
 * ([FuelLogRepository.updateFuelLog]) and nothing else: it never inserts,
 * never deletes, and never touches any other entity. Fuel create is owned by
 * [FuelLogCreateSync] (FUEL_LOG / CREATE); fuel delete remains online-only in
 * H-2.
 *
 * Discriminator: update markers use [PendingEntityType.FUEL_LOG] / UPDATE so
 * they can never be picked up by the create coordinator (FUEL_LOG / CREATE) and
 * this coordinator only ever processes FUEL_LOG / UPDATE rows.
 *
 * Edit-before-create folding (caller side): when the same log still has an
 * unresolved create, the ViewModel folds the edit into that create payload via
 * [FuelLogCreateSync.foldEdit] and never queues an UPDATE — so a create+edit
 * pair replays as a single edited insert, not an insert then a patch.
 *
 * Dependency gate (safety net): if an UPDATE marker somehow coexists with an
 * unresolved same-log create (e.g. ordering races), it is deferred (kept
 * FAILED, retry-eligible, no attempt consumed) until the create resolves —
 * PATCHing a row the server doesn't have yet would 404.
 *
 * Idempotency / coalescing: the outbox row is keyed on the fuel-log id
 * ([PendingWrite.clientId] = fuelLogId) and only one unresolved update is ever
 * kept per log — [enqueue] drops any earlier unresolved update for the same id
 * so the latest edit wins (last-writer-wins via the queued [Payload.clientUpdatedAt]).
 */
class FuelLogUpdateSync(
    private val fuelRepo: FuelLogRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full editable update payload. Carries the fuel form's editable columns plus
     * the stable client id and the [clientUpdatedAt] the operator saved the edit
     * at (last-writer-wins stamp). No auth/session/secrets — `operator_user_id` /
     * `created_by` are left untouched server-side on edit.
     */
    @Serializable
    data class Payload(
        val id: String,
        val machineId: String? = null,
        val tractorId: String? = null,
        val fillDatetime: String,
        val litresAdded: Double,
        val engineHours: Double? = null,
        val operatorName: String? = null,
        val costPerLitre: Double? = null,
        val totalCost: Double? = null,
        val filledToFull: Boolean,
        val notes: String? = null,
        val clientUpdatedAt: String,
    )

    /**
     * Queue (or replace) a fuel-log update for later replay. Coalesces by fuel
     * id: any earlier unresolved update for the same id is removed first so only
     * the latest edit is ever replayed. The [id] must be the same id used for the
     * optimistic local row and the eventual server PATCH.
     */
    fun enqueue(
        id: String,
        input: FuelLogRepository.FuelInput,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.FUEL_LOG &&
                    it.opType == PendingOpType.UPDATE &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = id,
            machineId = input.machineId,
            tractorId = input.tractorId,
            fillDatetime = input.fillDatetime,
            litresAdded = input.litresAdded,
            engineHours = input.engineHours,
            operatorName = input.operatorName,
            costPerLitre = input.costPerLitre,
            totalCost = input.totalCost,
            filledToFull = input.filledToFull,
            notes = input.notes,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.FUEL_LOG,
            opType = PendingOpType.UPDATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Replay every retry-eligible queued fuel-log update. No-ops (returns) if a
     * replay is already running. For each item: mark in-progress, then resolve:
     *  - corrupt payload -> blocked so it can't loop,
     *  - same-log create still unresolved -> deferred (FAILED, retry-eligible, no
     *    attempt consumed), never PATCHed against a missing row,
     *  - PATCH succeeds -> removed from the outbox; [onSynced] fires with the
     *    server row so the caller reconciles by id,
     *  - transient (network / 5xx / expired session) -> back to failed for a
     *    later attempt, attempt counter bumped,
     *  - permanent (validation / forbidden / corrupt) or attempt cap -> blocked.
     *
     * Caller must only invoke this when online and a session token exists.
     */
    suspend fun replayAll(onSynced: (TractorFuelLog) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.FUEL_LOG &&
                    it.opType == PendingOpType.UPDATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved fuel log edit.")
                    continue
                }
                // Dependency gate: never PATCH while the same log's create is still
                // unresolved (the server row may not exist yet). Defer without
                // consuming a retry attempt. Normally the ViewModel folds edits
                // into a pending create so this is only a safety net.
                if (hasUnresolvedCreate(payload.id)) {
                    pending.updateStatus(
                        write.id,
                        PendingWriteStatus.FAILED,
                        "Waiting for this fuel log to finish saving first.",
                    )
                    continue
                }
                try {
                    val updated = fuelRepo.updateFuelLog(
                        id = payload.id,
                        input = FuelLogRepository.FuelInput(
                            machineId = payload.machineId,
                            tractorId = payload.tractorId,
                            fillDatetime = payload.fillDatetime,
                            litresAdded = payload.litresAdded,
                            engineHours = payload.engineHours,
                            operatorName = payload.operatorName,
                            costPerLitre = payload.costPerLitre,
                            totalCost = payload.totalCost,
                            filledToFull = payload.filledToFull,
                            notes = payload.notes,
                        ),
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(updated)
                } catch (e: BackendError.Unauthorized) {
                    retryOrBlock(write, "Sign-in needed to sync this fuel log edit.")
                } catch (e: BackendError.Server) {
                    when {
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The fuel log edit was rejected (${e.code}).",
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
     * True when the same fuel log still has an unresolved create marker
     * (pending / in-progress / failed / blocked). The update waits for the create
     * to land rather than PATCHing a server row that doesn't exist yet.
     */
    private fun hasUnresolvedCreate(id: String): Boolean =
        pending.list().any {
            it.clientId == id &&
                it.entityType == PendingEntityType.FUEL_LOG &&
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
