package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Offline replay coordinator for spray-record CREATE only (Android Stage I-1).
 *
 * The operator logged a spray record offline (or a transient online insert
 * failed) and the optimistic row is already showing locally. This replays the
 * additive insert ([SprayRecordRepository.createSprayRecord]) and nothing else:
 * it never updates an existing record, never deletes, and never touches any
 * other entity. Spray update and delete remain online-only in I-1, and the
 * trip-coupled spray-create variants (which must create a trip first) are NOT
 * queued here.
 *
 * Discriminator: create markers use [PendingEntityType.SPRAY_RECORD] / CREATE so
 * a future spray update/delete queue (different op type) can never pick them up,
 * and this coordinator only ever processes SPRAY_RECORD / CREATE rows.
 *
 * Idempotency: the client mints the final spray-record UUID up front and uses it
 * as both [PendingWrite.clientId] and the inserted row id, so a retried insert is
 * safe — if the server reports a duplicate primary key (409) the row is already
 * there and we treat it as synced rather than inserting a second record. The
 * original [Payload.clientUpdatedAt] travels in the payload so replay preserves
 * the moment the operator actually saved the record, not when it later synced.
 */
class SprayRecordCreateSync(
    private val sprayRepo: SprayRecordRepository,
    private val pending: PendingWriteRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** Serialises replay so overlapping connectivity events can't double-fire. */
    private val replayLock = Mutex()

    /**
     * Full insert payload needed to replay the create. Carries the editable
     * spray-form fields plus the stable client id, vineyard scope and original
     * client_updated_at. `created_by` is deliberately NOT carried — it is
     * resolved from the signed-in session at insert time (same user across the
     * offline session), never frozen into the outbox. No auth/session/tokens are
     * stored.
     */
    @Serializable
    data class Payload(
        val id: String,
        val vineyardId: String,
        val date: String,
        val startTime: String,
        val temperature: Double? = null,
        val windSpeed: Double? = null,
        val windDirection: String? = null,
        val humidity: Double? = null,
        val sprayReference: String? = null,
        val notes: String? = null,
        val numberOfFansJets: String? = null,
        val averageSpeed: Double? = null,
        val equipmentType: String? = null,
        val tractor: String? = null,
        val tractorGear: String? = null,
        val machineId: String? = null,
        val sprayEquipmentId: String? = null,
        val operationType: String? = null,
        val tripId: String? = null,
        val isTemplate: Boolean = false,
        val tanks: List<SprayTank> = emptyList(),
        val clientUpdatedAt: String,
    )

    /**
     * Queue (or replace) a spray-record create for later replay. Coalesces by
     * record id: any earlier unresolved create for the same id is removed first
     * so only one is ever replayed. The [id] must be the same client-generated id
     * used for the optimistic local row and the eventual server insert.
     */
    fun enqueue(
        id: String,
        vineyardId: String,
        input: SprayRecordRepository.SprayInput,
        clientUpdatedAt: String,
    ): PendingWrite {
        pending.list()
            .filter {
                it.entityType == PendingEntityType.SPRAY_RECORD &&
                    it.opType == PendingOpType.CREATE &&
                    it.clientId == id &&
                    it.status != PendingWriteStatus.SYNCED
            }
            .forEach { pending.remove(it.id) }
        val payload = Payload(
            id = id,
            vineyardId = vineyardId,
            date = input.date,
            startTime = input.startTime,
            temperature = input.temperature,
            windSpeed = input.windSpeed,
            windDirection = input.windDirection,
            humidity = input.humidity,
            sprayReference = input.sprayReference,
            notes = input.notes,
            numberOfFansJets = input.numberOfFansJets,
            averageSpeed = input.averageSpeed,
            equipmentType = input.equipmentType,
            tractor = input.tractor,
            tractorGear = input.tractorGear,
            machineId = input.machineId,
            sprayEquipmentId = input.sprayEquipmentId,
            operationType = input.operationType,
            tripId = input.tripId,
            isTemplate = input.isTemplate,
            tanks = input.tanks,
            clientUpdatedAt = clientUpdatedAt,
        )
        return pending.enqueue(
            entityType = PendingEntityType.SPRAY_RECORD,
            opType = PendingOpType.CREATE,
            payloadJson = json.encodeToString(Payload.serializer(), payload),
            clientId = id,
        )
    }

    /**
     * Fold a later edit into a still-pending create (Android Stage I-2). When the
     * operator edits a spray record whose original create hasn't synced yet, there
     * is no server row to PATCH — instead the queued create payload is rewritten in
     * place with the latest editable values and a fresh [clientUpdatedAt], so the
     * eventual create inserts the edited values directly. The stable client [id]
     * and original [Payload.vineyardId] are preserved. Returns true when a pending
     * create existed and was updated; false when there's nothing to fold into (the
     * caller should then queue a normal SPRAY_RECORD / UPDATE instead).
     */
    fun foldEdit(
        id: String,
        input: SprayRecordRepository.SprayInput,
        clientUpdatedAt: String,
    ): Boolean {
        val existing = pending.list().filter {
            it.entityType == PendingEntityType.SPRAY_RECORD &&
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
     * Replay every retry-eligible queued spray-record create. No-ops (returns) if
     * a replay is already running. For each item: mark in-progress, POST it, then
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
    suspend fun replayAll(onSynced: (SprayRecord) -> Unit) {
        if (!replayLock.tryLock()) return
        try {
            val candidates = pending.list().filter {
                it.entityType == PendingEntityType.SPRAY_RECORD &&
                    it.opType == PendingOpType.CREATE &&
                    (it.status == PendingWriteStatus.PENDING || it.status == PendingWriteStatus.FAILED)
            }
            for (write in candidates) {
                pending.updateStatus(write.id, PendingWriteStatus.IN_PROGRESS)
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Couldn't read the saved spray record.")
                    continue
                }
                try {
                    val created = sprayRepo.createSprayRecord(
                        vineyardId = payload.vineyardId,
                        input = SprayRecordRepository.SprayInput(
                            date = payload.date,
                            startTime = payload.startTime,
                            temperature = payload.temperature,
                            windSpeed = payload.windSpeed,
                            windDirection = payload.windDirection,
                            humidity = payload.humidity,
                            sprayReference = payload.sprayReference,
                            notes = payload.notes,
                            numberOfFansJets = payload.numberOfFansJets,
                            averageSpeed = payload.averageSpeed,
                            equipmentType = payload.equipmentType,
                            tractor = payload.tractor,
                            tractorGear = payload.tractorGear,
                            machineId = payload.machineId,
                            sprayEquipmentId = payload.sprayEquipmentId,
                            operationType = payload.operationType,
                            tripId = payload.tripId,
                            isTemplate = payload.isTemplate,
                            tanks = payload.tanks,
                        ),
                        id = payload.id,
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    pending.remove(write.id)
                    onSynced(created)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(write, "Sign-in needed to sync this spray record.")
                } catch (e: BackendError.Server) {
                    when {
                        // Duplicate primary key — the client id is already on the
                        // server, so the spray record exists. Idempotent success;
                        // the optimistic row stays as-is.
                        e.code == 409 -> pending.remove(write.id)
                        e.code in 500..599 -> retryOrBlock(write, "Server error (${e.code}).")
                        else -> pending.updateStatus(
                            write.id,
                            PendingWriteStatus.BLOCKED,
                            "The spray record was rejected (${e.code}).",
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
        /** Cap retries so a persistently-failing spray record can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
