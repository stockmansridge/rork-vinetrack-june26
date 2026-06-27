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
 * Offline replay coordinator for fuel-log CREATE only (Tier-A Stage H-1).
 *
 * The operator recorded a fuel fill offline (or a transient online insert
 * failed) and the optimistic row is already showing locally. This replays the
 * additive insert ([FuelLogRepository.createFuelLog]) and nothing else: it never
 * updates an existing log, never deletes, and never touches any other entity.
 * Fuel update and delete remain online-only in H-1.
 *
 * Discriminator: create markers use [PendingEntityType.FUEL_LOG] / CREATE so a
 * future fuel update/delete queue (different op type) can never pick them up,
 * and this coordinator only ever processes FUEL_LOG / CREATE rows.
 *
 * Idempotency: the client mints the final fuel-log UUID up front and uses it as
 * both [PendingWrite.clientId] and the inserted row id, so a retried insert is
 * safe — if the server reports a duplicate primary key (409) the row is already
 * there and we treat it as synced rather than inserting a second fill. The
 * original [Payload.clientUpdatedAt] travels in the payload so replay preserves
 * the moment the operator actually saved the fill, not when it later synced.
 */
class FuelLogCreateSync(
    private val fuelRepo: FuelLogRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full insert payload needed to replay the create. Carries the editable fuel
     * form fields plus the stable client id, vineyard scope and original
     * client_updated_at. `operator_user_id` / `created_by` are deliberately NOT
     * carried — they are resolved from the signed-in session at insert time
     * (same user across the offline session), never frozen into the outbox.
     */
    @Serializable
    data class Payload(
        val id: String,
        val vineyardId: String,
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
     * Queue (or replace) a fuel-log create for later replay. Coalesces by fuel
     * id: any earlier unresolved create for the same id is removed first so only
     * one is ever replayed. The [id] must be the same client-generated id used
     * for the optimistic local row and the eventual server insert.
     */
    fun enqueue(
        id: String,
        vineyardId: String,
        input: FuelLogRepository.FuelInput,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.FUEL_LOG &&
                    it.opType == PendingOpType.CREATE &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = id,
            vineyardId = vineyardId,
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
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Fold a later edit into a still-pending create (Tier-A Stage H-2). When the
     * operator edits a fuel log whose original create hasn't synced yet, there is
     * no server row to PATCH — instead the queued create payload is rewritten in
     * place with the latest editable values and a fresh [clientUpdatedAt], so the
     * eventual create inserts the edited values directly. The stable client [id]
     * and original [Payload.vineyardId] are preserved. Returns true when a pending
     * create existed and was updated; false when there's nothing to fold into (the
     * caller should then queue a normal FUEL_LOG / UPDATE instead).
     */
    fun foldEdit(
        id: String,
        input: FuelLogRepository.FuelInput,
        clientUpdatedAt: String,
    ): Boolean {
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.FUEL_LOG &&
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
     * Replay every retry-eligible queued fuel-log create. No-ops (returns) if a
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
    suspend fun replayAll(onSynced: (TractorFuelLog) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.FUEL_LOG &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved fuel log.")
                    continue
                }
                try {
                    val created = fuelRepo.createFuelLog(
                        vineyardId = payload.vineyardId,
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
                        id = payload.id,
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(created)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(write, "Sign-in needed to sync this fuel log.")
                } catch (e: BackendError.Server) {
                    when {
                        // Duplicate primary key — the client id is already on the
                        // server, so the fuel log exists. Idempotent success; the
                        // optimistic row stays as-is.
                        e.code == 409 -> pending.remove(write.id)
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The fuel log was rejected (${e.code}).",
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
        /** Cap retries so a persistently-failing fuel log can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
