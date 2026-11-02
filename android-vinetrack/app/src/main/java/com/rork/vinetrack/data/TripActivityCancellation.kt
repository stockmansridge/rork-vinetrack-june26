package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SprayTankActual
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * P0 Phase A: account-scoped Cancel Trip recovery for a Trip this device owns but could
 * not finalise (LOCAL_END_PENDING). Server contract: sql/281 cancel_trip_activity_v1.
 *
 * Order is fixed and fail-closed:
 *  1. eligibility + explicit application classification (UNKNOWN is held, never guessed);
 *  2. original evidence written and fsynced BEFORE any request;
 *  3. durable intent committed with a stable operation id (lost responses replay it);
 *  4. server receipt verified against operation/Trip/vineyard/classification;
 *  5. ACKED committed BEFORE local cleanup; cleanup removes only writes whose identity is this
 *     Trip (or its linked spray record), never by count, never while one is IN_PROGRESS.
 * No Tank session is fabricated and no recorded quantity is changed or substituted.
 */
object TripActivityCancellation {
    enum class Classification(val wire: String?) { NOT_APPLIED("not_applied"), APPLIED("applied"), UNKNOWN(null) }

    enum class State { REQUESTED, REFUSED, RECEIPT_MISMATCH, ACKED, CLEANED }

    const val CONTRACT = "vinetrack.trip-activity-cancellation"

    /** Pending-write types whose clientId is the Trip id. */
    val TRIP_SCOPED_TYPES: Set<String> = setOf(
        PendingEntityType.TRIP, PendingEntityType.TRIP_METADATA, PendingEntityType.TRIP_GPS,
        PendingEntityType.TRIP_ROW, PendingEntityType.TRIP_ROW_PLAN, PendingEntityType.TRIP_TANK,
        PendingEntityType.TRIP_END, PendingEntityType.TRIP_START, PendingEntityType.TRIP_LABOUR,
        PendingEntityType.TRIP_SEEDING,
    )

    /** Definitive server refusals: nothing was changed server-side, local evidence stays. */
    val DEFINITIVE_REFUSALS: Set<String> = setOf(
        "TRIP_CANCEL_FORBIDDEN", "TRIP_CANCEL_TRIP_NOT_FOUND", "TRIP_CANCEL_TRIP_ALREADY_DELETED",
        "TRIP_CANCEL_TRIP_COMPLETED", "TRIP_CANCEL_MANUAL_ENTRY_UNSUPPORTED",
        "TRIP_CANCEL_SERVER_ACTUALS_REQUIRE_APPLIED_REVIEW", "TRIP_CANCEL_COMPLIANCE_FACTS_REQUIRED",
        "TRIP_CANCEL_CLASSIFICATION_REQUIRED", "TRIP_CANCEL_INVALID_IDENTITY", "TRIP_CANCEL_INVALID_BASELINE",
        "TRIP_CANCEL_OPERATION_CONFLICT",
    )

    @Serializable
    data class Intent(
        val operationId: String,
        val ownerId: String,
        val vineyardId: String,
        val tripId: String,
        val classification: String,
        val sprayRecordIds: List<String>,
        val localActualIds: List<String>,
        val baseline: JsonObject,
        val complianceFacts: JsonObject? = null,
        val evidencePath: String,
        val state: State,
        val requestedAt: Long,
        val receipt: JsonObject? = null,
        val lastCode: String? = null,
    ) {
        val isOpen: Boolean get() = state == State.REQUESTED || state == State.ACKED || state == State.RECEIPT_MISMATCH
    }

    data class Request(
        val ownerId: String,
        val vineyardId: String,
        val tripId: String,
        val classification: Classification,
        /** Required when NOT_APPLIED but this device holds recorded tank actuals. */
        val confirmedRecordedActualsWereNotApplied: Boolean = false,
    )

    data class Eligibility(val allowed: Boolean, val code: String?)

    fun eligibility(
        role: String?, signedInUserId: String?, claimOwnerId: String?, claimVineyardId: String?, claimTripId: String?,
        tripId: String, vineyardId: String, localEndPending: Boolean,
    ): Eligibility {
        fun no(code: String) = Eligibility(false, code)
        if (signedInUserId.isNullOrBlank()) return no("TRIP_CANCEL_AUTH_REQUIRED")
        if (role?.lowercase() !in setOf("owner", "manager", "supervisor")) return no("TRIP_CANCEL_FORBIDDEN")
        if (!localEndPending) return no("TRIP_CANCEL_NOT_LOCAL_END_PENDING")
        if (claimTripId != tripId) return no("TRIP_CANCEL_NOT_DEVICE_CLAIM")
        if (claimOwnerId != signedInUserId) return no("TRIP_CANCEL_CLAIM_OWNER_MISMATCH")
        if (claimVineyardId != vineyardId) return no("TRIP_CANCEL_CLAIM_VINEYARD_MISMATCH")
        return Eligibility(true, null)
    }

    sealed interface Plan {
        data class Ready(val writes: List<PendingWrite>) : Plan
        data class Refused(val code: String, val writeIds: List<String>) : Plan
    }

    /** Pure identity match; resolved (SYNCED) rows are ignored. */
    fun matchingWrites(writes: List<PendingWrite>, tripId: String, sprayRecordIds: Collection<String>): List<PendingWrite> =
        writes.filter { w ->
            w.status in PendingWriteStatus.unresolved && (
                (w.entityType in TRIP_SCOPED_TYPES && w.clientId == tripId) ||
                    (w.entityType == PendingEntityType.SPRAY_RECORD && w.clientId in sprayRecordIds))
        }

    fun plan(writes: List<PendingWrite>, tripId: String, sprayRecordIds: Collection<String>): Plan {
        val matching = matchingWrites(writes, tripId, sprayRecordIds)
        val inFlight = matching.filter { it.status == PendingWriteStatus.IN_PROGRESS }
        return if (inFlight.isNotEmpty()) Plan.Refused("TRIP_CANCEL_WRITE_IN_FLIGHT", inFlight.map { it.id })
        else Plan.Ready(matching)
    }

    /** Facts are copied verbatim from recorded actuals; planned values are never substituted. */
    fun complianceFacts(tripId: String, vineyardId: String, actuals: List<SprayTankActual>): JsonObject = buildJsonObject {
        put("contract", CONTRACT)
        put("trip_id", tripId)
        put("vineyard_id", vineyardId)
        put("source", "device_recorded_tank_actuals")
        put("tanks", buildJsonArray {
            actuals.sortedBy { it.tankNumber }.forEach { a ->
                add(buildJsonObject {
                    put("actual_id", a.id)
                    put("spray_record_id", a.sprayRecordId)
                    put("tank_session_id", a.tankSessionId)
                    put("tank_number", a.tankNumber)
                    val water = a.waterVolumeL
                    if (water != null) put("water_volume_l", water) else put("water_volume_l", kotlinx.serialization.json.JsonNull)
                    put("confirmed_at", a.confirmedAt)
                    put("confirmed_by", a.confirmedBy)
                    put("chemicals", buildJsonArray {
                        a.chemicals.forEach { c ->
                            add(buildJsonObject {
                                put("id", c.id)
                                put("name", c.name)
                                put("actual_amount_base", c.actualAmountBase)
                                put("unit", c.unit)
                                c.savedChemicalId?.let { put("saved_chemical_id", it) }
                                c.plannedChemicalId?.let { put("planned_chemical_id", it) }
                            })
                        }
                    })
                })
            }
        })
    }

    sealed interface ReceiptCheck {
        data object Valid : ReceiptCheck
        data class Invalid(val reason: String) : ReceiptCheck
    }

    /**
     * [acceptOtherOperation] is true only for a readback after TRIP_CANCEL_ALREADY_CANCELLED_OTHER_OPERATION:
     * the server's durable tombstone for this exact Trip/vineyard is authoritative even if another
     * device's operation wrote it.
     */
    fun verifyReceipt(receipt: JsonObject, intent: Intent, acceptOtherOperation: Boolean = false): ReceiptCheck {
        fun s(key: String) = (receipt[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (s("status") != "CANCELLED_ACKED") return ReceiptCheck.Invalid("status")
        if (s("trip_id") != intent.tripId) return ReceiptCheck.Invalid("trip_id")
        if (s("vineyard_id") != intent.vineyardId) return ReceiptCheck.Invalid("vineyard_id")
        if (!acceptOtherOperation) {
            if (s("operation_id") != intent.operationId) return ReceiptCheck.Invalid("operation_id")
            if (s("application_classification") != intent.classification) return ReceiptCheck.Invalid("classification")
        } else if (s("operation_id").isNullOrBlank()) return ReceiptCheck.Invalid("operation_id")
        val revision = (receipt["server_revision"] as? JsonPrimitive)?.content?.toLongOrNull()
        if (revision == null || revision <= 0) return ReceiptCheck.Invalid("server_revision")
        if (intent.classification == "applied" && !acceptOtherOperation && s("compliance_archive_id").isNullOrBlank())
            return ReceiptCheck.Invalid("compliance_archive_id")
        return ReceiptCheck.Valid
    }

    /** Fixed server code from a PostgREST error body; never echoes free text. */
    fun serverCode(body: String?): String? =
        body?.let { Regex("TRIP_CANCEL[A-Z_]*|TRIP_CANCELLED_TOMBSTONE").find(it)?.value }
}

/** Durable, synchronous intent store. One record per (owner, vineyard, trip). */
class TripCancellationIntentStore internal constructor(private val storage: Storage) {
    interface Storage { fun all(): Map<String, String>; fun commit(key: String, value: String): Boolean }
    constructor(context: Context) : this(object : Storage {
        private val prefs = context.getSharedPreferences("trip_activity_cancellation_v1", Context.MODE_PRIVATE)
        override fun all(): Map<String, String> = prefs.all.mapNotNull { (k, v) -> (v as? String)?.let { k to it } }.toMap()
        override fun commit(key: String, value: String): Boolean = prefs.edit().putString(key, value).commit()
    })

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private fun key(i: TripActivityCancellation.Intent) = "${i.ownerId}/${i.vineyardId}/${i.tripId}"

    @Synchronized fun all(): List<TripActivityCancellation.Intent> = storage.all().values.mapNotNull {
        runCatching { json.decodeFromString(TripActivityCancellation.Intent.serializer(), it) }.getOrNull()
    }

    @Synchronized fun find(tripId: String): TripActivityCancellation.Intent? = all().firstOrNull { it.tripId == tripId }

    /** True while a cancellation for this Trip is requested or acknowledged but not cleaned: hold replay. */
    fun holdsTrip(tripId: String): Boolean = find(tripId)?.isOpen == true

    @Synchronized fun commit(intent: TripActivityCancellation.Intent): Boolean =
        storage.commit(key(intent), json.encodeToString(TripActivityCancellation.Intent.serializer(), intent))
}

/** Original evidence, written atomically and fsynced before any server request. Never deleted by this flow. */
class TripCancellationEvidenceWriter(private val directory: File) {
    fun write(operationId: String, evidence: JsonObject): File? = runCatching {
        UUID.fromString(operationId)
        if (!directory.exists() && !directory.mkdirs()) return null
        val target = File(directory, "$operationId.json")
        if (target.exists()) return target
        val temp = File(directory, "$operationId.json.tmp")
        FileOutputStream(temp).use { out ->
            out.write(Json.encodeToString(JsonObject.serializer(), evidence).toByteArray(Charsets.UTF_8))
            out.flush()
            out.fd.sync()
        }
        if (!temp.renameTo(target)) return null
        target
    }.getOrNull()
}

/** Orchestrates request, receipt verification, readback and exact local cleanup. */
class TripActivityCancellationCoordinator(
    private val intents: TripCancellationIntentStore,
    private val evidence: TripCancellationEvidenceWriter,
    private val remote: Remote,
    private val local: Local,
    private val now: () -> Long = System::currentTimeMillis,
    private val newOperationId: () -> String = { UUID.randomUUID().toString() },
) {
    interface Remote {
        suspend fun cancel(intent: TripActivityCancellation.Intent): JsonObject
        /** Null when the server has no receipt for this Trip (RLS-scoped readback). */
        suspend fun readReceipt(tripId: String, vineyardId: String): JsonObject?
    }

    interface Local {
        fun pendingWrites(): List<PendingWrite>
        fun removeWriteIfCurrent(expected: PendingWrite): Boolean
        fun localActuals(tripId: String): List<SprayTankActual>
        fun removeActual(id: String): Boolean
        fun rawJournal(ownerId: String, vineyardId: String, tripId: String): String?
        fun removeJournal(ownerId: String, vineyardId: String, tripId: String): Boolean
        fun activeClaimJson(): String?
        /** True when no active claim for this exact Trip remains afterwards. */
        fun clearActiveClaimIfTrip(ownerId: String, vineyardId: String, tripId: String): Boolean
    }

    sealed interface Outcome {
        data class Refused(val code: String) : Outcome
        /** Request sent or about to be retried; the outcome is unknown and evidence is retained. */
        data class Pending(val code: String?) : Outcome
        data class Acked(val receipt: JsonObject, val cleaned: Boolean) : Outcome
    }

    class ServerRefusal(val status: Int, val code: String?) : Exception(code ?: "server $status")

    suspend fun cancel(request: TripActivityCancellation.Request, sprayRecordIds: List<String>): Outcome {
        intents.find(request.tripId)?.let { existing ->
            if (existing.isOpen) return reconcile(existing)
        }
        if (request.classification == TripActivityCancellation.Classification.UNKNOWN)
            return Outcome.Refused("TRIP_CANCEL_CLASSIFICATION_UNKNOWN_HELD")
        val actuals = local.localActuals(request.tripId)
        if (request.classification == TripActivityCancellation.Classification.NOT_APPLIED && actuals.isNotEmpty() &&
            !request.confirmedRecordedActualsWereNotApplied) return Outcome.Refused("TRIP_CANCEL_LOCAL_ACTUALS_REQUIRE_CONFIRMATION")
        val plan = TripActivityCancellation.plan(local.pendingWrites(), request.tripId, sprayRecordIds)
        if (plan is TripActivityCancellation.Plan.Refused) return Outcome.Refused(plan.code)
        val writes = (plan as TripActivityCancellation.Plan.Ready).writes

        // Evidence must be complete: an unreadable journal or claim holds instead of being recorded as absent.
        val journalRaw = runCatching { local.rawJournal(request.ownerId, request.vineyardId, request.tripId) }
            .getOrElse { return Outcome.Refused("TRIP_CANCEL_EVIDENCE_UNREADABLE") }
        val claimRaw = runCatching { local.activeClaimJson() }.getOrElse { return Outcome.Refused("TRIP_CANCEL_EVIDENCE_UNREADABLE") }
        val operationId = newOperationId()
        val json = Json { encodeDefaults = true }
        val evidenceDoc = buildJsonObject {
            put("contract", TripActivityCancellation.CONTRACT)
            put("operation_id", operationId)
            put("owner_id", request.ownerId); put("vineyard_id", request.vineyardId); put("trip_id", request.tripId)
            put("classification", request.classification.wire)
            put("captured_at_ms", now())
            put("active_claim_raw", claimRaw)
            put("occurrence_journal_raw", journalRaw)
            put("matching_pending_writes", JsonArray(writes.map { json.encodeToJsonElement(PendingWrite.serializer(), it) }))
            put("local_tank_actuals", JsonArray(actuals.map { json.encodeToJsonElement(SprayTankActual.serializer(), it) }))
            put("spray_record_ids", JsonArray(sprayRecordIds.map(::JsonPrimitive)))
        }
        val file = evidence.write(operationId, evidenceDoc) ?: return Outcome.Refused("TRIP_CANCEL_EVIDENCE_NOT_SAVED")
        val baseline = buildJsonObject {
            put("app_platform", "android")
            put("local_pending_write_count", writes.size)
            put("local_pending_write_types", JsonArray(writes.map { JsonPrimitive(it.entityType) }.distinct()))
            put("local_tank_actual_count", actuals.size)
            put("evidence_file", file.name)
        }
        val intent = TripActivityCancellation.Intent(
            operationId = operationId, ownerId = request.ownerId, vineyardId = request.vineyardId, tripId = request.tripId,
            classification = requireNotNull(request.classification.wire), sprayRecordIds = sprayRecordIds,
            localActualIds = actuals.map { it.id }, baseline = baseline,
            complianceFacts = if (request.classification == TripActivityCancellation.Classification.APPLIED)
                TripActivityCancellation.complianceFacts(request.tripId, request.vineyardId, actuals) else null,
            evidencePath = file.absolutePath, state = TripActivityCancellation.State.REQUESTED, requestedAt = now(),
        )
        if (intent.classification == "applied" && actuals.isEmpty()) return Outcome.Refused("TRIP_CANCEL_COMPLIANCE_FACTS_REQUIRED")
        if (!intents.commit(intent)) return Outcome.Refused("TRIP_CANCEL_INTENT_NOT_SAVED")
        return send(intent)
    }

    private suspend fun send(intent: TripActivityCancellation.Intent): Outcome {
        val receipt = try {
            remote.cancel(intent)
        } catch (refusal: ServerRefusal) {
            return when (val code = refusal.code) {
                "TRIP_CANCEL_ALREADY_CANCELLED_OTHER_OPERATION" -> readback(intent, acceptOtherOperation = true)
                in TripActivityCancellation.DEFINITIVE_REFUSALS -> {
                    intents.commit(intent.copy(state = TripActivityCancellation.State.REFUSED, lastCode = code))
                    Outcome.Refused(code!!)
                }
                else -> { intents.commit(intent.copy(lastCode = code ?: "HTTP_${refusal.status}")); Outcome.Pending(code) }
            }
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            intents.commit(intent.copy(lastCode = "TRIP_CANCEL_RESPONSE_UNKNOWN"))
            return Outcome.Pending("TRIP_CANCEL_RESPONSE_UNKNOWN")
        }
        return accept(intent, receipt, acceptOtherOperation = false)
    }

    private suspend fun readback(intent: TripActivityCancellation.Intent, acceptOtherOperation: Boolean): Outcome {
        val receipt = try { remote.readReceipt(intent.tripId, intent.vineyardId) } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            return Outcome.Pending("TRIP_CANCEL_READBACK_UNAVAILABLE")
        }
        if (receipt == null) return Outcome.Pending("TRIP_CANCEL_READBACK_ABSENT")
        val other = acceptOtherOperation ||
            (receipt["operation_id"] as? JsonPrimitive)?.content != intent.operationId
        return accept(intent, receipt, acceptOtherOperation = other)
    }

    private fun accept(intent: TripActivityCancellation.Intent, receipt: JsonObject, acceptOtherOperation: Boolean): Outcome {
        when (val check = TripActivityCancellation.verifyReceipt(receipt, intent, acceptOtherOperation)) {
            is TripActivityCancellation.ReceiptCheck.Invalid -> {
                intents.commit(intent.copy(state = TripActivityCancellation.State.RECEIPT_MISMATCH,
                    lastCode = "TRIP_CANCEL_RECEIPT_MISMATCH_${check.reason.uppercase()}", receipt = receipt))
                return Outcome.Refused("TRIP_CANCEL_RECEIPT_MISMATCH")
            }
            TripActivityCancellation.ReceiptCheck.Valid -> Unit
        }
        val acked = intent.copy(state = TripActivityCancellation.State.ACKED, receipt = receipt, lastCode = null)
        // Ack must be durable before anything local is removed.
        if (!intents.commit(acked)) return Outcome.Pending("TRIP_CANCEL_ACK_NOT_SAVED")
        return Outcome.Acked(receipt, cleanup(acked))
    }

    /** Removes only this Trip's exact local dependents after a verified, durable ack. Idempotent. */
    private fun cleanup(intent: TripActivityCancellation.Intent): Boolean {
        check(intent.state == TripActivityCancellation.State.ACKED && intent.receipt != null)
        val plan = TripActivityCancellation.plan(local.pendingWrites(), intent.tripId, intent.sprayRecordIds)
        if (plan is TripActivityCancellation.Plan.Refused) return false
        var complete = true
        (plan as TripActivityCancellation.Plan.Ready).writes.forEach {
            if (!runCatching { local.removeWriteIfCurrent(it) }.getOrDefault(false)) complete = false
        }
        runCatching { local.localActuals(intent.tripId) }.getOrElse { complete = false; emptyList() }
            .forEach { if (!runCatching { local.removeActual(it.id) }.getOrDefault(false)) complete = false }
        if (!runCatching { local.removeJournal(intent.ownerId, intent.vineyardId, intent.tripId) }.getOrDefault(false)) complete = false
        if (!runCatching { local.clearActiveClaimIfTrip(intent.ownerId, intent.vineyardId, intent.tripId) }.getOrDefault(false)) complete = false
        if (complete && TripActivityCancellation.matchingWrites(local.pendingWrites(), intent.tripId, intent.sprayRecordIds).isNotEmpty())
            complete = false
        if (complete) complete = intents.commit(intent.copy(state = TripActivityCancellation.State.CLEANED))
        return complete
    }

    /** Startup/refresh: resolve lost responses by readback, then idempotent replay; finish cleanup. */
    suspend fun reconcile(intent: TripActivityCancellation.Intent): Outcome = when (intent.state) {
        TripActivityCancellation.State.ACKED -> Outcome.Acked(requireNotNull(intent.receipt), cleanup(intent))
        TripActivityCancellation.State.REQUESTED -> when (val read = readback(intent, acceptOtherOperation = false)) {
            is Outcome.Pending -> if (read.code == "TRIP_CANCEL_READBACK_ABSENT") send(intent) else read
            else -> read
        }
        TripActivityCancellation.State.RECEIPT_MISMATCH -> Outcome.Refused(intent.lastCode ?: "TRIP_CANCEL_RECEIPT_MISMATCH")
        TripActivityCancellation.State.REFUSED -> Outcome.Refused(intent.lastCode ?: "TRIP_CANCEL_REFUSED")
        TripActivityCancellation.State.CLEANED -> Outcome.Acked(requireNotNull(intent.receipt), true)
    }

    suspend fun reconcileAll(): List<Pair<String, Outcome>> =
        intents.all().filter { it.isOpen }.map { it.tripId to reconcile(it) }
}

