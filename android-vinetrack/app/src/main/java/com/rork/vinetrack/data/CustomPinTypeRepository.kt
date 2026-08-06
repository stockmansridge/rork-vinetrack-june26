package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.CustomPinCreateParams
import com.rork.vinetrack.data.model.CustomPinType
import com.rork.vinetrack.data.model.CustomPinTypeCreateParams
import com.rork.vinetrack.data.model.ManualIssue
import io.ktor.client.call.body
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

/**
 * Server-authoritative access to the sql/170 unified pin composer RPCs:
 * the vineyard-shared custom pin type catalogue and the simplified Custom
 * pin create. Mirrors iOS `CustomPinTypeRepository`.
 *
 * Idempotency: both creates are keyed by client-generated ids, so an offline
 * replay returns the existing canonical row instead of duplicating; a
 * duplicate active type NAME (trimmed, case-insensitive) converges on the
 * existing shared entry server-side.
 */
class CustomPinTypeRepository(private val session: SessionStore) {

    @Serializable
    private data class ListArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_include_inactive") val includeInactive: Boolean = false,
    )

    @Serializable
    private data class SetActiveArgs(
        @SerialName("p_id") val id: String,
        @SerialName("p_is_active") val isActive: Boolean,
    )

    suspend fun createType(params: CustomPinTypeCreateParams): CustomPinType =
        rpc("create_vineyard_custom_pin_type", params)

    suspend fun listTypes(vineyardId: String, includeInactive: Boolean = false): List<CustomPinType> =
        rpc("list_vineyard_custom_pin_types", ListArgs(vineyardId, includeInactive))

    suspend fun setTypeActive(id: String, isActive: Boolean): CustomPinType =
        rpc("set_vineyard_custom_pin_type_active", SetActiveArgs(id, isActive))

    /** Simplified Custom-tab save — returns the canonical manual-issue JSON. */
    suspend fun createCustomPin(params: CustomPinCreateParams): ManualIssue =
        rpc("create_custom_pin", params)

    private suspend inline fun <reified Body, reified Result> rpc(name: String, body: Body): Result =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                }
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            when {
                response.status.isSuccess() -> response.body<Result>()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }
}
