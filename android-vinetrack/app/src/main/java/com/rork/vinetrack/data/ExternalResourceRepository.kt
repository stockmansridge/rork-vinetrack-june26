package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.VineyardExternalResource
import io.ktor.client.request.*
import io.ktor.client.statement.bodyAsText
import io.ktor.http.*
import kotlinx.serialization.json.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Online-only CRUD, using RLS and an atomic entire-observed-state PATCH predicate. */
class ExternalResourceRepository(private val session: SessionStore) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun list(vineyardId: String): List<VineyardExternalResource> = withContext(Dispatchers.IO) {
        require(session.selectedVineyardId == vineyardId)
        val response = SupabaseClient.http.get(SupabaseClient.restUrl("vineyard_external_resources")) {
            auth(); parameter("vineyard_id", "eq.$vineyardId"); parameter("order", "name.asc")
        }
        check(response.status.isSuccess()) { "Directory unavailable" }
        json.decodeFromString<List<VineyardExternalResource>>(response.bodyAsText())
    }

    suspend fun save(desired: VineyardExternalResource, expected: VineyardExternalResource?): VineyardExternalResource = withContext(Dispatchers.IO) {
        val author = session.userId ?: error("Sign in required")
        require(session.selectedVineyardId == desired.vineyardId && desired.name.isNotBlank() && desired.kind in listOf("crew", "contractor") && desired.deletedAt == null)
        if (expected != null) require(expected.id == desired.id && expected.vineyardId == desired.vineyardId && expected.updatedAt != null && expected.deletedAt == null)
        val response = try {
            if (expected == null) SupabaseClient.http.post(SupabaseClient.restUrl("vineyard_external_resources")) {
                auth(); headers { append("Prefer", "return=representation") }; contentType(ContentType.Application.Json); setBody(payload(desired).toString())
            } else SupabaseClient.http.patch(SupabaseClient.restUrl("vineyard_external_resources")) {
                auth(); headers { append("Prefer", "return=representation") }; contentType(ContentType.Application.Json); setBody(payload(desired).toString())
                parameter("id", "eq.${expected.id}"); parameter("vineyard_id", "eq.${expected.vineyardId}")
                parameter("updated_at", "eq.${expected.updatedAt}"); parameter("deleted_at", "is.null")
                payload(expected).forEach { (key, value) ->
                    if (key != "id" && key != "vineyard_id") parameter(key, if (value == JsonNull) "is.null" else "eq.${(value as JsonPrimitive).content}")
                }
            }
        } catch (e: Exception) {
            if (expected != null) throw IllegalStateException("Save was not confirmed. Your edits are retained. Reopen the directory to review current state.")
            null
        }
        val rows = if (response?.status?.isSuccess() == true) json.decodeFromString<List<VineyardExternalResource>>(response.bodyAsText()) else if (expected == null) list(desired.vineyardId).filter { it.id == desired.id } else emptyList()
        check(session.userId == author && session.selectedVineyardId == desired.vineyardId) { "Account or vineyard changed" }
        val row = rows.singleOrNull()
        check(row != null && payload(row) == payload(desired) && row.deletedAt == null) {
            "Resource changed, permission is unavailable, or save was not confirmed. Your form is retained. Reopen to review the latest directory."
        }
        row
    }

    private fun HttpRequestBuilder.auth() {
        val token = session.accessToken ?: error("Sign in required")
        headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
    }

    companion object {
        /** Explicit null contact fields; never writes server audit/timestamp columns. */
        fun payload(resource: VineyardExternalResource): JsonObject = buildJsonObject {
            put("id", resource.id); put("vineyard_id", resource.vineyardId); put("name", resource.name); put("kind", resource.kind); put("is_active", resource.isActive)
            put("contact_name", resource.contactName?.let(::JsonPrimitive) ?: JsonNull)
            put("phone", resource.phone?.let(::JsonPrimitive) ?: JsonNull)
            put("email", resource.email?.let(::JsonPrimitive) ?: JsonNull)
            put("notes", resource.notes?.let(::JsonPrimitive) ?: JsonNull)
        }
    }
}
