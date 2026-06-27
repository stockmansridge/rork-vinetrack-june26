package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SavedSprayPreset
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
 * Write path for reusable tank presets, mirroring the iOS `saved_spray_presets`
 * sync contract (sql/011). RLS scopes selects to vineyard members; inserts/updates
 * require owner/manager; hard deletes are blocked client-side, so deletion goes
 * through the `soft_delete_saved_spray_preset` RPC. Only the iOS `SavedSprayPreset`
 * fields are surfaced — name, water volume, spray rate per ha, concentration factor.
 */
class SavedSprayPresetRepository(private val session: SessionStore) {

    /** Editable fields surfaced by the Android tank-preset form. */
    data class PresetInput(
        val name: String,
        val waterVolume: Double,
        val sprayRatePerHa: Double,
        val concentrationFactor: Double,
    )

    @Serializable
    private data class PresetInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val name: String,
        @SerialName("water_volume") val waterVolume: Double,
        @SerialName("spray_rate_per_ha") val sprayRatePerHa: Double,
        @SerialName("concentration_factor") val concentrationFactor: Double,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class PresetPatch(
        val name: String,
        @SerialName("water_volume") val waterVolume: Double,
        @SerialName("spray_rate_per_ha") val sprayRatePerHa: Double,
        @SerialName("concentration_factor") val concentrationFactor: Double,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private fun nowIso(): String = Instant.now().toString()

    suspend fun create(vineyardId: String, input: PresetInput): SavedSprayPreset =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = PresetInsert(
                id = UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                name = input.name,
                waterVolume = input.waterVolume,
                sprayRatePerHa = input.sprayRatePerHa,
                concentrationFactor = input.concentrationFactor,
                createdBy = session.userId,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("saved_spray_presets")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    suspend fun update(id: String, input: PresetInput): SavedSprayPreset =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = PresetPatch(
                name = input.name,
                waterVolume = input.waterVolume,
                sprayRatePerHa = input.sprayRatePerHa,
                concentrationFactor = input.concentrationFactor,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("saved_spray_presets?id=eq.$id")) {
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
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_saved_spray_preset")) {
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

    private suspend fun firstRow(response: HttpResponse): SavedSprayPreset = when {
        response.status.isSuccess() -> response.body<List<SavedSprayPreset>>().firstOrNull()
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
