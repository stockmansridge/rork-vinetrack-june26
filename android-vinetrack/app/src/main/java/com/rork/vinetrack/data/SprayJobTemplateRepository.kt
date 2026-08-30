package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayProgramStepNotPermitted
import com.rork.vinetrack.data.spray.SprayTargetVocabulary
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import java.util.UUID

/**
 * Read-only fetch of reusable spray templates from `public.spray_jobs`
 * (sql/032). These rows are created by the Lovable admin portal, so the
 * template filter deliberately mirrors the portal contract and iOS:
 *
 *   * `vineyard_id = selected vineyard`
 *   * `is_template = true`
 *   * `deleted_at IS NULL`
 *   * NO status filter — portal templates are typically `status = 'draft'`
 *   * NO planned_date filter — templates carry no planned date
 *   * NO created_by filter — RLS grants read by vineyard membership and
 *     Lovable-created templates have `created_by = null`
 *
 * Rows are mapped into read-only in-memory [SprayRecord] templates (the
 * embedded `chemical_lines` JSON becomes a single tank's chemical list) so
 * the existing template UI and "new record from template" prefill flow work
 * without a second code path.
 *
 * A Program Step is a SHARED vineyard resource: the portal, iOS and Android
 * edit the SAME `spray_jobs` row. [updateTemplate] therefore updates in place
 * (PATCH + `id` filter) and never inserts a parallel copy. Authorisation is
 * the database's, not the client's — `spray_jobs_update_managers` (sql/032)
 * restricts UPDATE to owner/manager, and a denied write returns zero rows
 * rather than an error. There is deliberately no offline mutation queue for
 * `spray_jobs` — a write either reaches the shared row or fails loudly,
 * mirroring iOS.
 */
class SprayJobTemplateRepository(private val session: SessionStore) {

    /**
     * Tolerant row decode: every operational field is nullable so a template
     * is never dropped because water volume, rates, equipment, canopy or
     * audit columns are missing.
     */
    @Serializable
    private data class SprayJobRow(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val name: String = "",
        @SerialName("is_template") val isTemplate: Boolean = false,
        val status: String? = null,
        @SerialName("planned_date") val plannedDate: String? = null,
        @SerialName("chemical_lines") val chemicalLines: JsonArray? = null,
        @SerialName("water_volume") val waterVolume: Double? = null,
        @SerialName("spray_rate_per_ha") val sprayRatePerHa: Double? = null,
        @SerialName("concentration_factor") val concentrationFactor: Double? = null,
        @SerialName("operation_type") val operationType: String? = null,
        val target: String? = null,
        /**
         * Structured target identifiers (sql/193) — authoritative for WHICH
         * targets whenever present; the legacy [target] wording then only
         * supplies verbatim labels. Absent on rows written before the
         * contract.
         */
        val targets: List<String>? = null,
        /** Portal-chosen spray equipment, carried through by identity. */
        @SerialName("equipment_id") val equipmentId: String? = null,
        /** Portal-chosen tractor, carried through by identity. */
        @SerialName("tractor_id") val tractorId: String? = null,
        val notes: String? = null,
        /** Canonical E-L stage for the template (sql/034), e.g. "EL12". */
        @SerialName("growth_stage_code") val growthStageCode: String? = null,
        @SerialName("created_at") val createdAt: String? = null,
        @SerialName("deleted_at") val deletedAt: String? = null,
    )

    /**
     * One portal Program Step row, as the server currently holds it, with the
     * `chemical_lines` array kept RAW so the editor can round-trip every key
     * it does not model (`chemical_snapshot` above all) verbatim.
     */
    data class PortalProgramStepRow(
        val id: String,
        val vineyardId: String,
        val name: String,
        val growthStageCode: String?,
        val operationType: String?,
        val target: String?,
        val targets: List<String>?,
        val notes: String?,
        val equipmentId: String?,
        val tractorId: String?,
        val chemicalLines: JsonArray?,
    )

    /** A `public.tractors` row, decoded tolerantly for the tractor picker. */
    @Serializable
    data class SprayTractor(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String? = null,
        val name: String? = null,
        val make: String? = null,
        val model: String? = null,
    ) {
        val displayName: String
            get() = name?.takeIf { it.isNotBlank() }
                ?: listOfNotNull(make?.takeIf { it.isNotBlank() }, model?.takeIf { it.isNotBlank() })
                    .joinToString(" ")
                    .ifBlank { "Tractor" }
    }

    suspend fun listTemplates(vineyardId: String): List<SprayRecord> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(
                    "spray_jobs?vineyard_id=eq.$vineyardId&is_template=eq.true&deleted_at=is.null&order=name.asc"
                )
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() -> response.body<List<SprayJobRow>>().map { it.toSprayRecord() }
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Fetch ONE Program Step row fresh from the server, raw lines included,
     * so an edit starts from what the row actually holds now rather than a
     * mapped cache. Same filter contract as [listTemplates]; null when the
     * row is gone (deleted, or never visible to this user).
     */
    suspend fun fetchTemplateRow(id: String, vineyardId: String): PortalProgramStepRow? =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl(templateFilterPath(id, vineyardId)),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() ->
                    response.body<List<SprayJobRow>>().firstOrNull()?.toPortalRow()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Update one existing Program Step row IN PLACE and return it as the
     * server now holds it. The filter chain is the safety contract, mirroring
     * iOS `SupabaseSprayJobTemplateRepository.updateTemplate`:
     *
     *  * `id` — the SAME Program Step, never a new row
     *  * `vineyard_id` — a cross-vineyard write is impossible even if an id leaks
     *  * `is_template = true` — this path can never touch an operational job
     *  * `deleted_at IS NULL` — an archived step is not silently resurrected
     *
     * `is_template` is filtered on but never written, so the row cannot
     * change what kind of thing it is.
     *
     * @throws SprayProgramStepNotPermitted when the statement affects no
     * rows. Under RLS that is indistinguishable from "row not found", and
     * both mean the same thing: this save did not land. Reporting success
     * would be the one unacceptable outcome.
     */
    suspend fun updateTemplate(
        id: String,
        vineyardId: String,
        payload: JsonObject,
    ): SprayRecord =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.patch(
                SupabaseClient.restUrl(templateFilterPath(id, vineyardId)),
            ) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(payload)
            }
            when {
                response.status.isSuccess() -> {
                    val row = response.body<List<SprayJobRow>>().firstOrNull()
                        ?: throw SprayProgramStepNotPermitted()
                    row.toSprayRecord()
                }
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * The vineyard's tractors (`public.tractors`), for the Program Step
     * tractor picker. `spray_jobs.tractor_id` is a foreign key into this
     * table — vineyard machines must never be offered here, exactly as on
     * iOS.
     */
    suspend fun listTractors(vineyardId: String): List<SprayTractor> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.get(
                SupabaseClient.restUrl("tractors?vineyard_id=eq.$vineyardId"),
            ) { authHeaders(token) }
            when {
                response.status.isSuccess() ->
                    response.body<List<SprayTractor>>().sortedBy { it.displayName.lowercase() }
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    private fun SprayJobRow.toPortalRow(): PortalProgramStepRow = PortalProgramStepRow(
        id = id,
        vineyardId = vineyardId,
        name = name,
        growthStageCode = growthStageCode?.trim()?.takeIf { it.isNotEmpty() },
        operationType = operationType?.takeIf { it.isNotBlank() },
        target = target?.takeIf { it.isNotBlank() },
        targets = targets,
        notes = notes?.takeIf { it.isNotBlank() },
        equipmentId = equipmentId,
        tractorId = tractorId,
        chemicalLines = chemicalLines,
    )

    /** Deterministic ids so re-fetches don't churn Compose list identity. */
    private fun stableUuid(seed: String): String =
        UUID.nameUUIDFromBytes(seed.toByteArray(Charsets.UTF_8)).toString()

    private fun SprayJobRow.toSprayRecord(): SprayRecord {
        val chemicals = chemicalLines.orEmpty().mapIndexedNotNull { index, element ->
            (element as? JsonObject)?.let { parseChemicalLine(it, id, index) }
        }
        val tank = SprayTank(
            id = stableUuid("$id-template-tank-1"),
            tankNumber = 1,
            waterVolume = waterVolume ?: 0.0,
            sprayRatePerHa = sprayRatePerHa ?: 0.0,
            concentrationFactor = concentrationFactor ?: 0.0,
            rowApplications = emptyList(),
            chemicals = chemicals,
        )
        // The step's target selection. `targets` is authoritative when the
        // row has it; otherwise the legacy wording is split into tags so
        // "Eutypa Dieback, Botryosphaeria Dieback" loads as two targets
        // rather than as one unparsed sentence or as nothing. The old
        // "Target: ..." notes prefix is gone — a target VineTrack has no
        // typed case for is now carried as a real identifier rather than
        // smuggled into the notes, and duplicating it there would show the
        // operator the same words twice. Mirrors iOS `toSprayRecord()`.
        val tags = SprayTargetVocabulary.tags(
            identifiers = targets.orEmpty(),
            wording = target,
        )
        val targetIdentifiers = SprayTargetVocabulary.identifiers(tags)
        return SprayRecord(
            id = id,
            vineyardId = vineyardId,
            date = plannedDate ?: createdAt,
            sprayReference = name.trim().ifBlank { null },
            notes = notes?.takeIf { it.isNotBlank() },
            // Portal-chosen identities the previous adapter dropped. Passing
            // them through lets a Program Step prefill the equipment and
            // tractor by ID rather than by matching a display name.
            tractorId = tractorId,
            sprayEquipmentId = equipmentId,
            isTemplate = true,
            operationType = operationType?.takeIf { it.isNotBlank() },
            tanks = listOf(tank),
            // Flat sql/193 column: built-in raws plus custom slugs, in the
            // vocabulary's stable order. Null when the step names none —
            // which reads as "not recorded", never as "explicitly none".
            targets = targetIdentifiers.takeIf { it.isNotEmpty() },
            createdAt = createdAt,
            templateGrowthStageCode = growthStageCode?.trim()?.takeIf { it.isNotEmpty() },
        )
    }

    /**
     * Tolerant `chemical_lines` line parse. Portal/Excel imports write
     * snake_case keys (`chemical_id`, `rate`, `unit`) but camelCase variants
     * are accepted defensively; a malformed line is skipped, never fatal.
     */
    private fun parseChemicalLine(obj: JsonObject, templateId: String, index: Int): SprayChemical? {
        fun str(vararg keys: String): String? = keys.firstNotNullOfOrNull { key ->
            (obj[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
        }

        fun num(vararg keys: String): Double? = keys.firstNotNullOfOrNull { key ->
            (obj[key] as? JsonPrimitive)?.let { it.doubleOrNull ?: it.contentOrNull?.toDoubleOrNull() }
        }

        val name = str("name", "product_name", "productName", "product", "chemical_name", "chemicalName")
            ?: return null
        val rate = num("rate", "rate_per_ha", "ratePerHa", "rate_value", "amount") ?: 0.0
        val (unit, per100L) = parseLineUnit(str("unit", "rate_unit", "rateUnit"))
        // SprayChemical rates are stored in base units (mL or g).
        val baseRate = when (unit) {
            "Litres", "Kg" -> rate * 1000
            else -> rate
        }
        return SprayChemical(
            id = stableUuid("$templateId-template-line-$index"),
            name = name,
            volumePerTank = 0.0,
            ratePerHa = if (per100L) 0.0 else baseRate,
            ratePer100L = if (per100L) baseRate else 0.0,
            costPerUnit = 0.0,
            unit = unit,
            // The basis the portal's own unit string states. Previously left
            // null, so a `mL/100L` program line reloaded as a legacy
            // whole-block rate. A line with no rate at all stays null — an
            // honest "not stated". Mirrors iOS `BackendSprayJobTemplate`.
            rateBasis = if (baseRate > 0) {
                (if (per100L) SprayProductRateBasis.PER_100_LITRES else SprayProductRateBasis.WHOLE_BLOCK_AREA).raw
            } else {
                null
            },
            savedChemicalId = str("chemical_id", "chemicalId", "saved_chemical_id", "savedChemicalId"),
        )
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    companion object {
        /**
         * The PostgREST filter path shared by [fetchTemplateRow] and
         * [updateTemplate] — factored so the safety contract (id + vineyard +
         * `is_template=true` + `deleted_at IS NULL`) is one testable string.
         */
        fun templateFilterPath(id: String, vineyardId: String): String =
            "spray_jobs?id=eq.$id&vineyard_id=eq.$vineyardId&is_template=eq.true&deleted_at=is.null"

        /**
         * Compose the `chemical_lines` unit string the portal and the Excel
         * import already write — the exact INVERSE of [parseLineUnit], which
         * is the only thing that reads it back. The per-100 L basis lives in
         * this string and nowhere else, so a per-100 L line must round-trip
         * through it verbatim: writing `mL/ha` for a `mL/100L` line would
         * silently restate the rate. Mirrors iOS
         * `BackendSprayJobTemplate.composeLineUnit`.
         */
        fun composeLineUnit(unitRaw: String, per100Litres: Boolean): String {
            val measure = when (unitRaw) {
                "Litres" -> "L"
                "mL" -> "mL"
                "Kg" -> "kg"
                "g" -> "g"
                else -> "L"
            }
            return "$measure/" + if (per100Litres) "100L" else "ha"
        }

        /**
         * Parse a free-text chemical-line unit ("L/ha", "mL/100L", "kg/ha",
         * "g") into the strict ChemicalUnit raw shared with iOS ("Litres",
         * "mL", "Kg", "g") plus a per-100L basis flag. Mirrors the iOS
         * `BackendSprayJobTemplate.parseLineUnit` exactly.
         */
        fun parseLineUnit(raw: String?): Pair<String, Boolean> {
            val lowered = raw.orEmpty().lowercase()
            val per100 = lowered.contains("100")
            val unit = when {
                lowered.contains("ml") -> "mL"
                lowered.contains("kg") -> "Kg"
                lowered.startsWith("g") || lowered.contains("g/") -> "g"
                else -> "Litres"
            }
            return unit to per100
        }
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
