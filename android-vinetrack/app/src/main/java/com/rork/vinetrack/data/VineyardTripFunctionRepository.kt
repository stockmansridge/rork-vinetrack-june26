package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.VineyardTripFunction
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
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

/**
 * Read/write path for vineyard-scoped custom Trip Functions, mirroring the iOS
 * `SupabaseVineyardTripFunctionRepository` and the `vineyard_trip_functions`
 * table (sql/037). RLS scopes selects to vineyard members; inserts/updates
 * require owner/manager. Hard deletes are blocked client-side, so archive and
 * restore go through the `archive_vineyard_trip_function` /
 * `restore_vineyard_trip_function` RPCs.
 */
class VineyardTripFunctionRepository(private val session: SessionStore) {

    @Serializable
    private data class FunctionUpsert(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        val label: String,
        val slug: String,
        @SerialName("is_active") val isActive: Boolean,
        @SerialName("sort_order") val sortOrder: Int,
    )

    @Serializable
    private data class IdArg(@SerialName("p_id") val id: String)

    /** Fetch all (active + archived) trip functions for a vineyard. */
    suspend fun fetchAll(vineyardId: String): List<VineyardTripFunction> = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(
            SupabaseClient.restUrl(
                "vineyard_trip_functions?select=*&vineyard_id=eq.$vineyardId&order=sort_order.asc,label.asc",
            ),
        ) { authHeaders(token) }
        when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** Insert or update a custom trip function (owner/manager-gated by RLS). */
    suspend fun upsert(
        id: String,
        vineyardId: String,
        label: String,
        slug: String,
        isActive: Boolean,
        sortOrder: Int,
    ): VineyardTripFunction = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = FunctionUpsert(
            id = id,
            vineyardId = vineyardId,
            label = label,
            slug = slug,
            isActive = isActive,
            sortOrder = sortOrder,
        )
        val response = SupabaseClient.http.post(
            SupabaseClient.restUrl("vineyard_trip_functions?on_conflict=id"),
        ) {
            authHeaders(token)
            headers {
                append("Prefer", "return=representation,resolution=merge-duplicates")
            }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        firstRow(response)
    }

    /** Soft-delete (archive) via the owner/manager-gated server RPC. */
    suspend fun archive(id: String) = withContext(Dispatchers.IO) {
        rpc("archive_vineyard_trip_function", id)
    }

    /** Restore a previously-archived trip function via the server RPC. */
    suspend fun restore(id: String) = withContext(Dispatchers.IO) {
        rpc("restore_vineyard_trip_function", id)
    }

    private suspend fun rpc(name: String, id: String) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(IdArg(id))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private suspend fun firstRow(response: HttpResponse): VineyardTripFunction = when {
        response.status.isSuccess() -> response.body<List<VineyardTripFunction>>().firstOrNull()
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
