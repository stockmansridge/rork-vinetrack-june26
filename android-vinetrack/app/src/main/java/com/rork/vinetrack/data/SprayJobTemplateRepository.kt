package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayTargetVocabulary
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.statement.bodyAsText
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
 * without a second code path. Android never writes to `spray_jobs`.
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
