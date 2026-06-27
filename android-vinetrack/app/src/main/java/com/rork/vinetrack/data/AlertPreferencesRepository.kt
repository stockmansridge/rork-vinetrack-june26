package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.AlertPreferences
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Read/write path for per-vineyard alert preferences, mirroring the iOS
 * `AlertService` persistence. One row per vineyard in `alert_preferences`,
 * keyed by `vineyard_id`. Saving upserts (merge-duplicates) so the same row is
 * shared with iOS and the web portal. RLS restricts writes to owner/manager.
 */
class AlertPreferencesRepository(private val session: SessionStore) {

    /** Loads the saved preferences for a vineyard, or null when none exist yet. */
    suspend fun load(vineyardId: String): AlertPreferences? = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(
            SupabaseClient.restUrl("alert_preferences?select=*&vineyard_id=eq.$vineyardId")
        ) {
            authHeaders(token)
        }
        when {
            response.status.isSuccess() -> response.body<List<AlertPreferences>>().firstOrNull()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, "")
        }
    }

    /** Upserts the preferences row. Returns the saved row. */
    suspend fun save(prefs: AlertPreferences): AlertPreferences = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("alert_preferences")) {
            authHeaders(token)
            headers {
                append("Prefer", "resolution=merge-duplicates,return=representation")
            }
            contentType(ContentType.Application.Json)
            setBody(prefs)
        }
        when {
            response.status.isSuccess() -> response.body<List<AlertPreferences>>().firstOrNull() ?: prefs
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, "")
        }
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
