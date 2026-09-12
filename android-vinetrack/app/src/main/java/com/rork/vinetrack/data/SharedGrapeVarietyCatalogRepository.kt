package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.request.HttpRequestBuilder
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
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.buildJsonObject

/**
 * One row of the global built-in grape variety catalogue returned by the
 * `get_grape_variety_catalog` RPC (sql/073). Mirrors the iOS
 * `SharedGrapeVarietyCatalogEntry`.
 */
@Serializable
data class SharedGrapeVarietyCatalogEntry(
    val key: String,
    @SerialName("canonical_name") val canonicalName: String = "",
    @SerialName("display_name") val displayName: String = "",
    @SerialName("optimal_gdd") val optimalGdd: Double? = null,
    @SerialName("is_builtin") val isBuiltin: Boolean = true,
    @SerialName("is_active") val isActive: Boolean = true,
)

/**
 * Read-only access to the shared grape variety catalogue, mirroring the iOS
 * `SupabaseGrapeVarietyCatalogRepository` + `SharedGrapeVarietyCatalogCache`.
 * The last successful response is cached locally so the Vineyard Setup card
 * can show the real catalogue size offline. Nothing is written to the backend.
 */
class SharedGrapeVarietyCatalogRepository(context: Context, private val session: SessionStore) {

    private val json = SupabaseClient.json
    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_shared_grape_catalog", Context.MODE_PRIVATE)

    /** Entries persisted from the last successful refresh, or empty. */
    fun loadCached(): List<SharedGrapeVarietyCatalogEntry> {
        val raw = prefs.getString(KEY_ENTRIES, null) ?: return emptyList()
        return runCatching { json.decodeFromString(ListSerializer(SharedGrapeVarietyCatalogEntry.serializer()), raw) }
            .getOrDefault(emptyList())
    }

    /** Fetch the global catalogue; any authenticated user can read. Persists on success. */
    suspend fun refresh(): List<SharedGrapeVarietyCatalogEntry> = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("get_grape_variety_catalog")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject {})
        }
        val text = response.bodyAsText()
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, text)
        }
        if (text.isBlank()) return@withContext emptyList()
        val entries = json.decodeFromString(ListSerializer(SharedGrapeVarietyCatalogEntry.serializer()), text)
        if (entries.isNotEmpty()) {
            prefs.edit { putString(KEY_ENTRIES, text) }
        }
        entries
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }

    private companion object {
        const val KEY_ENTRIES = "entries_json"
    }
}
