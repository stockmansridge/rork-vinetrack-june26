package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.spray.SprayApplicationSnapshot
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
 * identity-stable. HTTP 409 alone never proves the same operation was accepted;
 * without a reviewed scoped payload/revision receipt it remains blocked. The
 * original [Payload.clientUpdatedAt] travels in the payload so replay preserves
 * the moment the operator actually saved the record, not when it later synced.
 */
class SprayRecordCreateSync(
    private val sprayRepo: SprayRecordRepository?,
    private val pending: PendingWriteRepository,
    private val createRemote: (suspend (Payload) -> SprayRecord)? = null,
    private val occurrenceParentReady: (Payload) -> Boolean = { false },
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
        val tractorId: String? = null,
        val sprayEquipmentId: String? = null,
        val operationType: String? = null,
        val tripId: String? = null,
        /**
         * sql/033 Job -> Record link (Stage 5B): the planned `spray_jobs` row
         * this record fulfils. Default null keeps every pre-5B queued marker
         * decodable as a plain unlinked create.
         */
        val sprayJobId: String? = null,
        val isTemplate: Boolean = false,
        val tanks: List<SprayTank> = emptyList(),
        /**
         * Canonical sql/191 + sql/192 calculation snapshot, carried through the
         * outbox so a spray created OFFLINE keeps its gross/treated distinction,
         * canonical row metres, band geometry and carrier values when it finally
         * replays. Null on payloads queued before this field existed, and on
         * records never calculated through the Spray Engine.
         */
        val applicationGeometry: SprayApplicationSnapshot? = null,
        val clientUpdatedAt: String,
        val requiresOccurrenceParent: Boolean = false,
    )

    /**
     * Queue (or replace) a spray-record create for later replay. Coalesces by
     * record id in one durable mutation. Blocked/in-flight operations cannot be
     * replaced, and failed persistence leaves the original operation intact. The [id] must be the same client-generated id
     * used for the optimistic local row and the eventual server insert.
     */
    fun enqueue(
        id: String,
        vineyardId: String,
        input: SprayRecordRepository.SprayInput,
        clientUpdatedAt: String,
        requiresOccurrenceParent: Boolean = false,
    ): PendingWrite {
        input.operationalBlocker()?.let { throw IllegalStateException(it) }
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
            tractorId = input.tractorId,
            sprayEquipmentId = input.sprayEquipmentId,
            operationType = input.operationType,
            tripId = input.tripId,
            sprayJobId = input.sprayJobId,
            isTemplate = input.isTemplate,
            tanks = input.tanks,
            applicationGeometry = input.applicationGeometry,
            clientUpdatedAt = clientUpdatedAt,
            requiresOccurrenceParent = requiresOccurrenceParent,
        )
        val encoded = json.encodeToString(Payload.serializer(), payload)
        return requireNotNull(pending.coalesceUnstartedCreate(PendingEntityType.SPRAY_RECORD, id) { existing ->
            if (existing != null) {
                val original = json.decodeFromString(Payload.serializer(), existing.payloadJson)
                check(original.id == id && original.vineyardId == vineyardId) { "The original spray scope cannot be replaced." }
            }
            encoded
        })
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
        check(existing.size == 1) { "Multiple retained spray operations require review." }
        val original = json.decodeFromString(Payload.serializer(), existing.single().payloadJson)
        check(original.id == id) { "The original spray identity cannot be replaced." }
        val vineyardId = original.vineyardId
        enqueue(id, vineyardId, input, clientUpdatedAt)
        return true
    }

    /**
     * Replay every retry-eligible queued spray-record create. No-ops (returns) if
     * a replay is already running. For each item: mark in-progress, POST it, then
     * resolve the outcome:
     *  - successful insert -> removed and reconciled with the server row,
     *  - conflict/unverified duplicate -> retained blocked, never acknowledged,
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
                val retained = runCatching { json.decodeFromString(Payload.serializer(), write.payloadJson) }.getOrNull()
                if (retained?.requiresOccurrenceParent == true && !occurrenceParentReady(retained)) continue
                val claimed = pending.claimReplay(write) ?: continue
                val payload = runCatching {
                    json.decodeFromString(Payload.serializer(), write.payloadJson)
                }.getOrNull()
                if (payload == null) {
                    pending.updateStatusIfCurrent(claimed, PendingWriteStatus.BLOCKED, "Couldn't read the saved spray record.")
                    continue
                }
                val planningBlocker = com.rork.vinetrack.data.spray.SprayPlanningOperationalGate.blocker(payload.applicationGeometry, payload.tanks)
                if (planningBlocker != null) {
                    pending.updateStatusIfCurrent(claimed, PendingWriteStatus.BLOCKED, planningBlocker)
                    continue
                }
                try {
                    val created = createRemote?.invoke(payload) ?: requireNotNull(sprayRepo).createSprayRecord(
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
                            tractorId = payload.tractorId,
                            sprayEquipmentId = payload.sprayEquipmentId,
                            operationType = payload.operationType,
                            tripId = payload.tripId,
                            sprayJobId = payload.sprayJobId,
                            isTemplate = payload.isTemplate,
                            tanks = payload.tanks,
                            applicationGeometry = payload.applicationGeometry,
                        ),
                        id = payload.id,
                        clientUpdatedAt = payload.clientUpdatedAt,
                    )
                    if (pending.removeIfCurrent(claimed)) onSynced(created)
                } catch (e: BackendError.Unauthorized) {
                    // Session expired mid-replay — retry after re-auth (bounded by the cap).
                    retryOrBlock(claimed, "Sign-in needed to sync this spray record.")
                } catch (e: BackendError.Server) {
                    when {
                        SprayOperationalFailure.isComplianceRejection(e) -> pending.updateStatusIfCurrent(
                            claimed, PendingWriteStatus.BLOCKED, "The spray was rejected by server safety validation. Review the original recipe before retrying.")
                        e.code == 409 -> pending.updateStatusIfCurrent(claimed, PendingWriteStatus.BLOCKED,
                            when (SprayOperationalFailure.createConflict(e)) {
                                SprayOperationalFailure.CreateConflict.COMPLIANCE_REJECTION -> "The spray was rejected by server safety validation."
                                SprayOperationalFailure.CreateConflict.REVISION_OR_DATA_CONFLICT -> "The saved spray conflicts with server data. The original operation is retained for review."
                                SprayOperationalFailure.CreateConflict.UNVERIFIED -> "The server response did not verify this exact operation. The original save is retained; it has not been acknowledged."
                            })
                        e.code in 500..599 -> retryOrBlock(claimed, "Server error (${e.code}).")
                        else -> pending.updateStatusIfCurrent(
                            claimed,
                            PendingWriteStatus.BLOCKED,
                            "The spray record was rejected (${e.code}).",
                        )
                    }
                } catch (e: Exception) {
                    // Still offline / transient network failure — leave for next time.
                    retryOrBlock(claimed, e.message ?: "No connection.")
                }
            }
        } finally {
            replayLock.unlock()
        }
    }

    /** Bump the attempt counter and either re-queue (failed) or give up (blocked). */
    private fun retryOrBlock(write: PendingWrite, error: String) {
        pending.retryIfCurrent(write, error, MAX_ATTEMPTS)
    }

    private companion object {
        /** Cap retries so a persistently-failing spray record can't loop indefinitely. */
        const val MAX_ATTEMPTS = 8
    }
}
