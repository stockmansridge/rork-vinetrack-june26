package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.Vineyard
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant

/**
 * Read/repair data layer for the owner/manager Trip Audit tool, mirroring the
 * iOS `TripAuditService` data access. Reads every trip / paddock / vineyard the
 * signed-in user can access across ALL of their vineyards (not just the active
 * one) — RLS on each table scopes the rows server-side, so the unfiltered
 * queries below only ever return data the user is allowed to see.
 *
 * The only write is [updateTripVineyardAssignment], a focused patch that sets
 * just the trip's `vineyard_id` (+ optional `paddock_id`) and the sync stamp,
 * so a repair can never clobber live progress or any iOS-managed JSONB field.
 */
class TripAuditRepository(private val session: SessionStore) {

    /** Every vineyard the user can access, including soft-deleted ones. */
    suspend fun fetchAllAccessibleVineyards(): List<Vineyard> = withContext(Dispatchers.IO) {
        get("vineyards?select=*&order=name.asc")
    }

    /** Every non-deleted paddock the user can access, across all vineyards. */
    suspend fun fetchAllAccessiblePaddocks(): List<Paddock> = withContext(Dispatchers.IO) {
        get("paddocks?select=*&deleted_at=is.null")
    }

    /** Every non-deleted trip the user can access, across all vineyards. */
    suspend fun fetchAllAccessibleTrips(): List<Trip> = withContext(Dispatchers.IO) {
        get("trips?select=*&deleted_at=is.null&order=start_time.desc")
    }

    /**
     * Reassign a trip to [vineyardId]. When [paddockId] is supplied it is
     * written too; otherwise the existing `paddock_id` is left untouched (the
     * key is omitted so PostgREST does not clear it). Always bumps
     * `client_updated_at` so the change wins last-write-wins on every device.
     */
    suspend fun updateTripVineyardAssignment(
        id: String,
        vineyardId: String,
        paddockId: String?,
    ): Trip = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val patch: JsonObject = buildJsonObject {
            put("vineyard_id", JsonPrimitive(vineyardId))
            if (paddockId != null) put("paddock_id", JsonPrimitive(paddockId)) else put("paddock_id", JsonNull)
            put("client_updated_at", JsonPrimitive(Instant.now().toString()))
        }
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("trips?id=eq.$id")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(patch)
        }
        when {
            response.status.isSuccess() -> response.body<List<Trip>>().firstOrNull()
                ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private suspend inline fun <reified T> get(path: String): T {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response: HttpResponse = SupabaseClient.http.get(SupabaseClient.restUrl(path)) {
            authHeaders(token)
        }
        return when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
