package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SprayEquipment
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
 * Write path for vineyard spray rigs & tanks, mirroring the iOS `spray_equipment`
 * sync contract (sql/011). RLS scopes selects to vineyard members; inserts/updates
 * require owner/manager; hard deletes are blocked client-side, so deletion goes
 * through the `soft_delete_spray_equipment` RPC. Only `name` and
 * `tank_capacity_litres` are surfaced — matching the iOS `SprayEquipmentItem`.
 */
class SprayEquipmentRepository(private val session: SessionStore) {

    /** Editable fields surfaced by the Android spray-equipment form. */
    data class EquipmentInput(
        val name: String,
        val tankCapacityLitres: Double,
    )

    @Serializable
    private data class EquipmentInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val name: String,
        @SerialName("tank_capacity_litres") val tankCapacityLitres: Double,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class EquipmentPatch(
        val name: String,
        @SerialName("tank_capacity_litres") val tankCapacityLitres: Double,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private fun nowIso(): String = Instant.now().toString()

    suspend fun create(vineyardId: String, input: EquipmentInput): SprayEquipment =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = EquipmentInsert(
                id = UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                name = input.name,
                tankCapacityLitres = input.tankCapacityLitres,
                createdBy = session.userId,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("spray_equipment")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    suspend fun update(id: String, input: EquipmentInput): SprayEquipment =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = EquipmentPatch(
                name = input.name,
                tankCapacityLitres = input.tankCapacityLitres,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("spray_equipment?id=eq.$id")) {
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
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_spray_equipment")) {
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

    private suspend fun firstRow(response: HttpResponse): SprayEquipment = when {
        response.status.isSuccess() -> response.body<List<SprayEquipment>>().firstOrNull()
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
