package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.EquipmentItem
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
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
 * Read + write path for `public.equipment_items` (sql/053), mirroring the iOS
 * `EquipmentItemSyncService`. Vineyard members may read; owner/manager/
 * supervisor may write. Hard deletes are blocked, so archiving goes through the
 * `soft_delete_equipment_item` RPC.
 */
class EquipmentItemRepository(private val session: SessionStore) {

    /** Editable fields surfaced by the Android other-equipment form. */
    data class ItemInput(
        val name: String,
        val make: String?,
        val model: String?,
        val serialNumber: String?,
        val notes: String,
    )

    @Serializable
    private data class ItemInsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val name: String,
        val category: String,
        val make: String?,
        val model: String?,
        @SerialName("serial_number") val serialNumber: String?,
        val notes: String,
        @SerialName("created_by") val createdBy: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class ItemPatch(
        val name: String,
        val make: String?,
        val model: String?,
        @SerialName("serial_number") val serialNumber: String?,
        val notes: String,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_id") val id: String)

    private fun nowIso(): String = Instant.now().toString()

    suspend fun list(vineyardId: String): List<EquipmentItem> = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(
            SupabaseClient.restUrl("equipment_items?select=*&vineyard_id=eq.$vineyardId&deleted_at=is.null&order=name.asc")
        ) { authHeaders(token) }
        when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    suspend fun create(vineyardId: String, input: ItemInput): EquipmentItem =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val body = ItemInsert(
                id = UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                name = input.name,
                category = "other",
                make = input.make,
                model = input.model,
                serialNumber = input.serialNumber,
                notes = input.notes,
                createdBy = session.userId,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.post(SupabaseClient.restUrl("equipment_items")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            firstRow(response)
        }

    suspend fun update(id: String, input: ItemInput): EquipmentItem =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val patch = ItemPatch(
                name = input.name,
                make = input.make,
                model = input.model,
                serialNumber = input.serialNumber,
                notes = input.notes,
                clientUpdatedAt = nowIso(),
            )
            val response = SupabaseClient.http.patch(SupabaseClient.restUrl("equipment_items?id=eq.$id")) {
                authHeaders(token)
                headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json)
                setBody(patch)
            }
            firstRow(response)
        }

    suspend fun softDelete(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_equipment_item")) {
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

    private suspend fun firstRow(response: HttpResponse): EquipmentItem = when {
        response.status.isSuccess() -> response.body<List<EquipmentItem>>().firstOrNull()
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
