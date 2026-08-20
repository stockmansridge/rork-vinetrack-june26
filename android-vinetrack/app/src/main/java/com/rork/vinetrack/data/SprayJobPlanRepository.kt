package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.resistance.ResistancePlan
import com.rork.vinetrack.data.resistance.ResistancePlannedPosition
import com.rork.vinetrack.data.resistance.displayLabel
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import java.util.UUID

/**
 * A `spray_jobs` row carrying resistance-plan provenance (sql/201).
 *
 * The snapshot is the sql/196 position document FROZEN at job creation — the
 * ORIGINAL planned intent, never a verdict, and never re-derived from the
 * current plan (a manager editing the plan later must not rewrite what an
 * existing job was asked to do). Stored here as raw JSON and decoded lazily
 * and tolerantly so a job never disappears because a field is malformed.
 */
@Serializable
data class PlanSprayJob(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    val name: String = "",
    val status: String? = null,
    val target: String? = null,
    val notes: String? = null,
    @SerialName("chemical_lines") val chemicalLines: JsonArray? = null,
    @SerialName("resistance_plan_id") val resistancePlanId: String? = null,
    @SerialName("resistance_position_id") val resistancePositionId: String? = null,
    @SerialName("resistance_position_snapshot") val resistancePositionSnapshot: JsonObject? = null,
    @SerialName("resistance_plan_source_revision") val resistancePlanSourceRevision: Long? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
) {
    /** One proposed product line of the job's current (editable) chemistry. */
    data class ProposedLine(val chemicalId: String?, val name: String)

    /** The frozen original intent as a typed sql/196 position, or null. */
    fun snapshotPosition(): ResistancePlannedPosition? =
        resistancePositionSnapshot?.let { obj ->
            runCatching {
                lenientJson.decodeFromJsonElement(ResistancePlannedPosition.serializer(), obj)
            }.getOrNull()
        }

    /** Tolerant read of the job's current chemical lines. */
    fun proposedLines(): List<ProposedLine> = chemicalLines.orEmpty().mapNotNull { element ->
        val obj = element as? JsonObject ?: return@mapNotNull null
        val name = (obj["name"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
            ?: return@mapNotNull null
        ProposedLine(
            chemicalId = (obj["chemical_id"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() },
            name = name,
        )
    }

    /** Original planned intent, e.g. `"FRAC 3 — Talendo"`. Null when unlinked. */
    val originalIntentLabel: String?
        get() = snapshotPosition()?.let { snapshot ->
            val names = snapshot.products.mapNotNull { it.productName?.takeIf(String::isNotBlank) }
            if (names.isEmpty()) snapshot.groupsLabel
            else "${snapshot.groupsLabel} — ${names.joinToString(", ")}"
        }

    /** The job's CURRENT proposal from its editable chemical lines. */
    val currentProposalLabel: String
        get() = proposedLines().map { it.name }.filter { it.isNotBlank() }
            .takeIf { it.isNotEmpty() }
            ?.joinToString(", ")
            ?: "No products proposed yet"

    /**
     * PLAN DEVIATION, not compliance: true when the current proposal no longer
     * matches the originally planned product identities. A deviating job can
     * still be resistance-compliant — compliance is always the Resistance
     * Engine's call against current history.
     */
    val deviatesFromPlan: Boolean
        get() {
            val snapshot = snapshotPosition() ?: return false
            val planned = snapshot.products.map { product ->
                (product.savedChemicalId ?: product.productName ?: product.groups.displayLabel).lowercase()
            }.toSet()
            val proposed = proposedLines().map { (it.chemicalId ?: it.name).lowercase() }.toSet()
            return planned != proposed
        }

    /**
     * Maps this job into an in-memory record used ONLY to prefill the Spray
     * Calculator (mirrors the portal-template prefill path). Never stored:
     * the record the calculator saves is brand new and carries
     * `spray_job_id = id` — the Job -> Record completion link (sql/033).
     * Rates and carrier volumes are NOT invented — the operator supplies them.
     */
    fun toPrefillSprayRecord(): SprayRecord = SprayRecord(
        id = id,
        vineyardId = vineyardId,
        sprayReference = name.ifBlank { null },
        notes = notes,
        // Prefill semantics only (keeps the name verbatim, no "(Copy)");
        // the record actually saved is a new non-template.
        isTemplate = true,
        tanks = listOf(
            SprayTank(
                id = "$id-job-tank-1",
                tankNumber = 1,
                waterVolume = 0.0,
                sprayRatePerHa = 0.0,
                concentrationFactor = 0.0,
                rowApplications = emptyList(),
                chemicals = proposedLines().mapIndexed { index, line ->
                    SprayChemical(
                        id = "$id-job-line-$index",
                        name = line.name,
                        volumePerTank = 0.0,
                        ratePerHa = 0.0,
                        ratePer100L = 0.0,
                        costPerUnit = 0.0,
                        unit = "Litres",
                        savedChemicalId = line.chemicalId,
                    )
                },
            ),
        ),
    )

    private companion object {
        val lenientJson = Json { ignoreUnknownKeys = true }
    }
}

/** Insert payload for a spray job created FROM a resistance plan position. */
@Serializable
data class PlanSprayJobInsert(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    val name: String,
    @SerialName("is_template") val isTemplate: Boolean = false,
    val status: String = "planned",
    val target: String? = null,
    val notes: String? = null,
    @SerialName("chemical_lines") val chemicalLines: JsonArray,
    @SerialName("resistance_plan_id") val resistancePlanId: String,
    @SerialName("resistance_position_id") val resistancePositionId: String,
    /** Frozen VERBATIM from the plan position at creation time (sql/196 shape). */
    @SerialName("resistance_position_snapshot") val resistancePositionSnapshot: JsonObject,
    @SerialName("resistance_plan_source_revision") val resistancePlanSourceRevision: Long? = null,
    @SerialName("created_by") val createdBy: String? = null,
) {
    /** Optimistic local row shown while the create is queued/in flight. */
    fun asJob(createdAt: String? = null): PlanSprayJob = PlanSprayJob(
        id = id,
        vineyardId = vineyardId,
        name = name,
        status = status,
        target = target,
        notes = notes,
        chemicalLines = chemicalLines,
        resistancePlanId = resistancePlanId,
        resistancePositionId = resistancePositionId,
        resistancePositionSnapshot = resistancePositionSnapshot,
        resistancePlanSourceRevision = resistancePlanSourceRevision,
        createdAt = createdAt,
    )
}

/**
 * Reads and creates `spray_jobs` rows linked to resistance plans (sql/201).
 *
 * Distinct from [SprayJobTemplateRepository] (read-only `is_template = true`
 * portal templates): this handles PLANNED jobs created from plan positions.
 * Creation is idempotent — the client mints the job UUID, so a duplicate-key
 * 409 on replay means "already synced". RLS gates INSERT to owner/manager.
 */
class SprayJobPlanRepository(private val session: SessionStore) {

    @Serializable
    private data class PaddockLinkInsert(
        @SerialName("spray_job_id") val sprayJobId: String,
        @SerialName("paddock_id") val paddockId: String,
    )

    /**
     * Live (non-archived) jobs linked to [planId], oldest first. Filtered by
     * vineyard as well — the same vineyard-equality rule the sql/201
     * resolution functions apply, so a cross-vineyard link can never surface.
     */
    suspend fun fetchJobsForPlan(vineyardId: String, planId: String): List<PlanSprayJob> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "spray_jobs?vineyard_id=eq.$vineyardId&resistance_plan_id=eq.$planId" +
                        "&deleted_at=is.null&order=created_at.asc"
                )
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body<List<PlanSprayJob>>()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Inserts the job, then its paddock links (proposed coverage). Safe to
     * replay: a duplicate job insert (409) is treated as already-synced and
     * paddock links upsert with duplicates merged.
     */
    suspend fun createJob(insert: PlanSprayJobInsert, paddockIds: List<String>) =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized

            val jobResponse = SupabaseClient.http.post(SupabaseClient.restUrl("spray_jobs")) {
                authHeaders(token)
                contentType(ContentType.Application.Json)
                setBody(insert)
            }
            when {
                jobResponse.status.isSuccess() -> Unit
                // Duplicate primary key — the client-minted id is already on
                // the server; the job exists. Idempotent success.
                jobResponse.status.value == 409 -> Unit
                jobResponse.status.value == 401 || jobResponse.status.value == 403 ->
                    throw BackendError.Unauthorized
                else -> throw BackendError.Server(jobResponse.status.value, jobResponse.bodyAsText())
            }

            if (paddockIds.isEmpty()) return@withContext
            val links = paddockIds.distinct().map { PaddockLinkInsert(insert.id, it) }
            val linkResponse = SupabaseClient.http.post(
                SupabaseClient.restUrl("spray_job_paddocks?on_conflict=spray_job_id,paddock_id")
            ) {
                authHeaders(token)
                headers { append("Prefer", "resolution=merge-duplicates") }
                contentType(ContentType.Application.Json)
                setBody(links)
            }
            when {
                linkResponse.status.isSuccess() -> Unit
                linkResponse.status.value == 409 -> Unit
                linkResponse.status.value == 401 || linkResponse.status.value == 403 ->
                    throw BackendError.Unauthorized
                else -> throw BackendError.Server(linkResponse.status.value, linkResponse.bodyAsText())
            }
        }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }

    companion object {
        /**
         * Builds the insert for "Create Spray Job" on a planner position.
         *
         * Freezes [position] VERBATIM as the snapshot and prefills only what
         * the plan genuinely knows — product identity and planned FRAC groups —
         * NEVER carrier volumes or rates. The job remains fully editable.
         */
        fun buildInsert(
            plan: ResistancePlan,
            position: ResistancePlannedPosition,
            name: String,
            target: String?,
            createdBy: String?,
            id: String = UUID.randomUUID().toString(),
        ): PlanSprayJobInsert {
            val lines = buildJsonArray {
                position.products
                    .filter { it.groups.codes.isNotEmpty() || !it.productName.isNullOrBlank() }
                    .forEach { product ->
                        add(
                            buildJsonObject {
                                product.savedChemicalId?.let { put("chemical_id", JsonPrimitive(it)) }
                                put("name", JsonPrimitive(product.displayLabel))
                                if (product.groups.codes.isNotEmpty()) {
                                    put("notes", JsonPrimitive("Planned ${product.groups.displayLabel}"))
                                }
                            }
                        )
                    }
            }
            val snapshot = Json
                .encodeToJsonElement(ResistancePlannedPosition.serializer(), position)
                .jsonObject
            return PlanSprayJobInsert(
                id = id,
                vineyardId = plan.vineyardId,
                name = name,
                target = target,
                notes = position.note,
                chemicalLines = lines,
                resistancePlanId = plan.id,
                resistancePositionId = position.id,
                resistancePositionSnapshot = snapshot,
                resistancePlanSourceRevision = plan.serverRevision,
                createdBy = createdBy,
            )
        }
    }
}
