package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.VineyardMachine
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
 * Write path for `public.vineyard_machines` (sql/097), mirroring the iOS
 * `VineyardMachineSyncService` upsert contract. RLS scopes selects to vineyard
 * members; inserts/updates require owner/manager. Hard deletes are blocked, so
 * archiving goes through the `soft_delete_vineyard_machine` RPC.
 *
 * Tractor-backed machines (`legacy_tractor_id != null`) are left untouched here;
 * natively-created machines never set a legacy tractor link.
 */
class VineyardMachineRepository(private val session: SessionStore) {

    /** Editable fields surfaced by the Android machine form. */
    data class MachineInput(
        val name: String,
        val machineType: String,
        val fuelTrackingEnabled: Boolean,
        val availableForJobCosting: Boolean,
        val fuelUsageLPerHour: Double,
        val notes: String?,
        val serialNumber: String?,
        val vinNumber: String?,
    )

    @Serializable
    private data class MachineInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val name: String,
        @SerialName("machine_type") val machineType: String,
        @SerialName("fuel_tracking_enabled") val fuelTrackingEnabled: Boolean,
        @SerialName("available_for_job_costing") val availableForJobCosting: Boolean,
        @SerialName("fuel_usage_l_per_hour") val fuelUsageLPerHour: Double,
        val notes: String?,
        @SerialName("serial_number") val serialNumber: String?,
        @SerialName("vin_number") val vinNumber: String?,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class MachinePatch(
        val name: String,
        @SerialName("machine_type") val machineType: String,
        @SerialName("fuel_tracking_enabled") val fuelTrackingEnabled: Boolean,
        @SerialName("available_for_job_costing") val availableForJobCosting: Boolean,
        @SerialName("fuel_usage_l_per_hour") val fuelUsageLPerHour: Double,
        val notes: String?,
        @SerialName("serial_number") val serialNumber: String?,
        @SerialName("vin_number") val vinNumber: String?,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private fun nowIso(): String = Instant.now().toString()

    suspend fun create(vineyardId: String, input: MachineInput): VineyardMachine =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = MachineInsert(
                id = UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                name = input.name,
                machineType = input.machineType,
                fuelTrackingEnabled = input.fuelTrackingEnabled,
                availableForJobCosting = input.availableForJobCosting,
                fuelUsageLPerHour = input.fuelUsageLPerHour,
                notes = input.notes,
                serialNumber = input.serialNumber,
                vinNumber = input.vinNumber,
                createdBy = session.userId,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("vineyard_machines")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    suspend fun update(id: String, input: MachineInput): VineyardMachine =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = MachinePatch(
                name = input.name,
                machineType = input.machineType,
                fuelTrackingEnabled = input.fuelTrackingEnabled,
                availableForJobCosting = input.availableForJobCosting,
                fuelUsageLPerHour = input.fuelUsageLPerHour,
                notes = input.notes,
                serialNumber = input.serialNumber,
                vinNumber = input.vinNumber,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("vineyard_machines?id=eq.$id")) {
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
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_vineyard_machine")) {
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

    private suspend fun firstRow(response: HttpResponse): VineyardMachine = when {
        response.status.isSuccess() -> response.body<List<VineyardMachine>>().firstOrNull()
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
