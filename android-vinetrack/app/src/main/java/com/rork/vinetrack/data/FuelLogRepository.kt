package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.TractorFuelLog
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.patch
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
import java.time.Instant
import java.util.UUID

/**
 * Write path for fuel logs, mirroring the iOS fuel-log sync contract
 * (`tractor_fuel_logs` table + `soft_delete_tractor_fuel_log` RPC). RLS scopes
 * everything to the signed-in user's vineyard role.
 *
 * Online-first — there is no local queue yet. The fuel form is the sole editor
 * of these columns, so create/edit send the editable column set. `machine_id`
 * is the preferred link; `tractor_id` carries the legacy fallback so existing
 * trip costing (which still reads `trips.tractor_id`) keeps working when the
 * selected machine is backed by a legacy tractor. `created_by` and
 * server-managed sync columns are left untouched on edit.
 */
class FuelLogRepository(private val session: SessionStore) {

    @Serializable
    private data class FuelInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("tractor_id") val tractorId: String? = null,
        @SerialName("machine_id") val machineId: String? = null,
        @SerialName("fill_datetime") val fillDatetime: String,
        @SerialName("litres_added") val litresAdded: Double,
        @SerialName("engine_hours") val engineHours: Double? = null,
        @SerialName("operator_user_id") val operatorUserId: String? = null,
        @SerialName("operator_name") val operatorName: String? = null,
        @SerialName("cost_per_litre") val costPerLitre: Double? = null,
        @SerialName("total_cost") val totalCost: Double? = null,
        @SerialName("filled_to_full") val filledToFull: Boolean? = null,
        val notes: String? = null,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class FuelPatch(
        @SerialName("tractor_id") val tractorId: String? = null,
        @SerialName("machine_id") val machineId: String? = null,
        @SerialName("fill_datetime") val fillDatetime: String,
        @SerialName("litres_added") val litresAdded: Double,
        @SerialName("engine_hours") val engineHours: Double? = null,
        @SerialName("operator_name") val operatorName: String? = null,
        @SerialName("cost_per_litre") val costPerLitre: Double? = null,
        @SerialName("total_cost") val totalCost: Double? = null,
        @SerialName("filled_to_full") val filledToFull: Boolean? = null,
        val notes: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    /** Fields the fuel form edits, shared by create and edit paths. */
    data class FuelInput(
        val machineId: String?,
        val tractorId: String?,
        val fillDatetime: String,
        val litresAdded: Double,
        val engineHours: Double?,
        val operatorName: String?,
        val costPerLitre: Double?,
        val totalCost: Double?,
        val filledToFull: Boolean,
        val notes: String?,
    )

    fun nowIso(): String = Instant.now().toString()

    /** Generate a fresh client-side fuel-log id (UUID). */
    fun newId(): String = UUID.randomUUID().toString()

    /**
     * Insert a fuel log using a caller-supplied [id] and [clientUpdatedAt] so the
     * same id is shared by the optimistic local row, the pending-write marker,
     * and the eventual server insert (Tier-A Stage H-1). Re-running this with the
     * same id is idempotent server-side: a duplicate primary key surfaces as a
     * 409 the create coordinator treats as success. `operator_user_id` /
     * `created_by` are still resolved from the signed-in session (the same user
     * across the offline session), never carried in the queued payload.
     */
    suspend fun createFuelLog(
        vineyardId: String,
        input: FuelInput,
        id: String,
        clientUpdatedAt: String,
    ): TractorFuelLog =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = FuelInsert(
                id = id,
                vineyardId = vineyardId,
                tractorId = input.tractorId,
                machineId = input.machineId,
                fillDatetime = input.fillDatetime,
                litresAdded = input.litresAdded,
                engineHours = input.engineHours,
                operatorUserId = session.userId,
                operatorName = input.operatorName,
                costPerLitre = input.costPerLitre,
                totalCost = input.totalCost,
                filledToFull = input.filledToFull,
                notes = input.notes,
                createdBy = session.userId,
                clientUpdatedAt = clientUpdatedAt,
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("tractor_fuel_logs")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    /**
     * PATCH the editable fuel-log columns by id. [clientUpdatedAt] is caller-
     * supplied for replay (Tier-A Stage H-2) so a queued edit keeps the moment
     * the operator actually saved it; the live online edit path passes null and
     * stamps `now` here. Re-running with the same payload is naturally idempotent
     * (it just rewrites the same columns).
     */
    suspend fun updateFuelLog(id: String, input: FuelInput, clientUpdatedAt: String? = null): TractorFuelLog =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = FuelPatch(
                tractorId = input.tractorId,
                machineId = input.machineId,
                fillDatetime = input.fillDatetime,
                litresAdded = input.litresAdded,
                engineHours = input.engineHours,
                operatorName = input.operatorName,
                costPerLitre = input.costPerLitre,
                totalCost = input.totalCost,
                filledToFull = input.filledToFull,
                notes = input.notes,
                clientUpdatedAt = clientUpdatedAt ?: nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("tractor_fuel_logs?id=eq.$id")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(patch)
            }
            firstRow(response)
        }

    suspend fun softDeleteFuelLog(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_tractor_fuel_log")) {
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

    private suspend fun firstRow(response: io.ktor.client.statement.HttpResponse): TractorFuelLog = when {
        response.status.isSuccess() -> response.body<List<TractorFuelLog>>().firstOrNull()
            ?: throw BackendError.Server(response.status.value, "Empty response")
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun io.ktor.client.request.HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
