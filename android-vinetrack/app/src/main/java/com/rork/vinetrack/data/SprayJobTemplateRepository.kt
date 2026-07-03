package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
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
        val notes: String? = null,
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
        val combinedNotes = buildString {
            target?.takeIf { it.isNotBlank() }?.let { append("Target: $it") }
            notes?.takeIf { it.isNotBlank() }?.let {
                if (isNotEmpty()) append('\n')
                append(it)
            }
        }.ifBlank { null }
        return SprayRecord(
            id = id,
            vineyardId = vineyardId,
            date = plannedDate ?: createdAt,
            sprayReference = name.trim().ifBlank { null },
            notes = combinedNotes,
            isTemplate = true,
            operationType = operationType?.takeIf { it.isNotBlank() },
            tanks = listOf(tank),
            createdAt = createdAt,
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
        val unitRaw = (str("unit", "rate_unit", "rateUnit") ?: "").lowercase()
        val per100L = unitRaw.contains("100")
        // Map free-text units onto the strict ChemicalUnit raw values shared
        // with iOS ("Litres", "mL", "Kg", "g"); order matters (kg before g).
        val unit = when {
            unitRaw.contains("ml") -> "mL"
            unitRaw.contains("kg") -> "Kg"
            unitRaw.startsWith("g") || unitRaw.contains("g/") -> "g"
            else -> "Litres"
        }
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
            savedChemicalId = str("chemical_id", "chemicalId", "saved_chemical_id", "savedChemicalId"),
        )
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
}
