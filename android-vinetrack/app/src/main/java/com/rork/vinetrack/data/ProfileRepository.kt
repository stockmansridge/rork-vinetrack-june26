package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Read/write path for the signed-in user's profile, mirroring the canonical
 * iOS `SupabaseProfileRepository` contract. Currently exposes the per-user
 * default vineyard (`profiles.default_vineyard_id`, sql/012), which the app
 * uses to choose which vineyard opens on launch.
 *
 * RLS: `profiles_select_own` / `profiles_update_own` scope reads & writes to
 * the caller's own row. Writes go through the SECURITY DEFINER
 * `set_default_vineyard` RPC, which also validates membership server-side.
 */
class ProfileRepository(private val session: SessionStore) {

    @Serializable
    private data class ProfileRow(
        @SerialName("default_vineyard_id") val defaultVineyardId: String? = null,
    )

    /**
     * The user's preferred default vineyard id, or null when none is set.
     * Returns null on any failure so callers fall back to the local selection.
     */
    suspend fun getDefaultVineyardId(): String? = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val userId = session.userId ?: return@withContext null
        val response = SupabaseClient.http.get(
            SupabaseClient.restUrl("profiles?id=eq.$userId&select=default_vineyard_id"),
        ) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
        }
        when {
            response.status.isSuccess() -> {
                val rows: List<ProfileRow> = response.body()
                rows.firstOrNull()?.defaultVineyardId
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, "")
        }
    }

    /**
     * Persist the per-user default vineyard via the `set_default_vineyard` RPC.
     * Pass null to clear the default. The RPC validates that the caller is a
     * member of the vineyard before writing.
     */
    suspend fun setDefaultVineyard(vineyardId: String?) = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        // Build the body explicitly so a null id is sent as JSON null (the RPC
        // param has no default, so it must be present rather than omitted).
        val body = if (vineyardId != null) {
            "{\"p_vineyard_id\":\"$vineyardId\"}"
        } else {
            "{\"p_vineyard_id\":null}"
        }
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("set_default_vineyard")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, "")
        }
    }
}
