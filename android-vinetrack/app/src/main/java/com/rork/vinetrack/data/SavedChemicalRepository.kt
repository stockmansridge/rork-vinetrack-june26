package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.ChemicalPurchase
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.SavedChemical
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * Write path for the shared saved-chemicals library, mirroring the iOS
 * `saved_chemicals` sync contract (sql/011, sql/086, sql/087). RLS scopes
 * selects to vineyard members; inserts/updates require owner/manager; hard
 * deletes are blocked client-side, so deletion goes through the
 * `soft_delete_saved_chemicals` RPC.
 *
 * Edits use a **partial PATCH** of the Android-surfaced columns, mirroring the
 * iOS `EditSavedChemicalSheet.save()` write set: agronomic metadata, the dual
 * per-ha / per-100L `rates` JSONB (base-unit values), and the `purchase` JSONB
 * costing. All payloads use the iOS-compatible shapes so values round-trip
 * across platforms.
 */
class SavedChemicalRepository(private val session: SessionStore) {

    /**
     * Editable fields surfaced by the Android management form. The form builds
     * the [rates] list (base-unit values, preserving existing rate IDs) and the
     * already-resolved [purchase] snapshot, mirroring the iOS editor's `save()`.
     */
    data class ChemicalInput(
        val name: String,
        val unit: String,
        /** Legacy per-ha column in display units (kept in sync with [rates]). */
        val ratePerHa: Double,
        val rates: List<ChemicalRate>,
        val activeIngredient: String?,
        val chemicalGroup: String?,
        val use: String?,
        val problem: String?,
        val manufacturer: String?,
        val notes: String?,
        val modeOfAction: String?,
        val labelUrl: String?,
        val productUrl: String?,
        /** Fully-resolved costing snapshot; null clears purchase tracking. */
        val purchase: ChemicalPurchase?,
    )

    @Serializable
    private data class ChemicalInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val name: String,
        val unit: String,
        @SerialName("rate_per_ha") val ratePerHa: Double,
        val rates: List<ChemicalRate>,
        @SerialName("active_ingredient") val activeIngredient: String,
        @SerialName("chemical_group") val chemicalGroup: String,
        val use: String,
        val problem: String,
        val manufacturer: String,
        val notes: String,
        @SerialName("mode_of_action") val modeOfAction: String,
        @SerialName("label_url") val labelUrl: String,
        @SerialName("product_url") val productUrl: String,
        val purchase: ChemicalPurchase? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class ChemicalPatch(
        val name: String,
        val unit: String,
        @SerialName("rate_per_ha") val ratePerHa: Double,
        val rates: List<ChemicalRate>,
        @SerialName("active_ingredient") val activeIngredient: String,
        @SerialName("chemical_group") val chemicalGroup: String,
        val use: String,
        val problem: String,
        val manufacturer: String,
        val notes: String,
        @SerialName("mode_of_action") val modeOfAction: String,
        @SerialName("label_url") val labelUrl: String,
        @SerialName("product_url") val productUrl: String,
        val purchase: ChemicalPurchase? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    @Serializable
    private data class HardDeleteResult(
        val ok: Boolean = false,
        val reason: String? = null,
        val message: String? = null,
    )

    /** Outcome of a permanent-delete attempt, mirroring the iOS deletion service. */
    sealed interface HardDeleteOutcome {
        object Deleted : HardDeleteOutcome
        object NotFound : HardDeleteOutcome
        data class InUse(val message: String) : HardDeleteOutcome
    }

    private fun nowIso(): String = Instant.now().toString()

    suspend fun create(vineyardId: String, input: ChemicalInput): SavedChemical =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = ChemicalInsert(
                id = UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                name = input.name,
                unit = input.unit,
                ratePerHa = input.ratePerHa,
                rates = input.rates,
                activeIngredient = input.activeIngredient.orEmpty(),
                chemicalGroup = input.chemicalGroup.orEmpty(),
                use = input.use.orEmpty(),
                problem = input.problem.orEmpty(),
                manufacturer = input.manufacturer.orEmpty(),
                notes = input.notes.orEmpty(),
                modeOfAction = input.modeOfAction.orEmpty(),
                labelUrl = input.labelUrl.orEmpty(),
                productUrl = input.productUrl.orEmpty(),
                purchase = input.purchase,
                createdBy = session.userId,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("saved_chemicals")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    suspend fun update(id: String, input: ChemicalInput): SavedChemical =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = ChemicalPatch(
                name = input.name,
                unit = input.unit,
                ratePerHa = input.ratePerHa,
                rates = input.rates,
                activeIngredient = input.activeIngredient.orEmpty(),
                chemicalGroup = input.chemicalGroup.orEmpty(),
                use = input.use.orEmpty(),
                problem = input.problem.orEmpty(),
                manufacturer = input.manufacturer.orEmpty(),
                notes = input.notes.orEmpty(),
                modeOfAction = input.modeOfAction.orEmpty(),
                labelUrl = input.labelUrl.orEmpty(),
                productUrl = input.productUrl.orEmpty(),
                purchase = input.purchase,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("saved_chemicals?id=eq.$id")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(patch)
            }
            firstRow(response)
        }

    /** Archive (soft-delete) via the owner/manager-gated server RPC. */
    suspend fun softDelete(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_saved_chemicals")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteArgs(id))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Permanently delete a saved chemical via the `hard_delete_unused_saved_chemical`
     * RPC. The backend is the final authority: it refuses (returning
     * [HardDeleteOutcome.InUse]) when the chemical is referenced by any spray
     * record, job, trip, or FK. Owner/manager only. Mirrors the iOS
     * `SavedChemicalDeletionService.hardDelete`.
     */
    suspend fun hardDeleteUnused(id: String): HardDeleteOutcome = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("hard_delete_unused_saved_chemical")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteArgs(id))
        }
        when {
            response.status.isSuccess() -> {
                val result = response.body<HardDeleteResult>()
                when {
                    result.ok -> HardDeleteOutcome.Deleted
                    result.reason == "not_found" -> HardDeleteOutcome.NotFound
                    result.reason == "chemical_in_use" -> HardDeleteOutcome.InUse(
                        result.message
                            ?: "This chemical has been used and cannot be permanently deleted. You can archive it instead.",
                    )
                    else -> throw BackendError.Server(response.status.value, result.reason ?: "delete_failed")
                }
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private suspend fun firstRow(response: HttpResponse): SavedChemical = when {
        response.status.isSuccess() -> response.body<List<SavedChemical>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
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
