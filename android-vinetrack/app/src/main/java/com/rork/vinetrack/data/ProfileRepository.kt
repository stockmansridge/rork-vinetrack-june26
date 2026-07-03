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
 * iOS `SupabaseProfileRepository` contract. Exposes the per-user default
 * vineyard (`profiles.default_vineyard_id`, sql/012) and the cross-platform
 * display name (`profiles.full_name`), which is the single source of truth
 * for the user's name across iOS, Android, and the web portal.
 *
 * RLS: `profiles_select_own` / `profiles_insert_own` / `profiles_update_own`
 * scope reads & writes to the caller's own row. Default-vineyard writes go
 * through the SECURITY DEFINER `set_default_vineyard` RPC, which also
 * validates membership server-side.
 */
class ProfileRepository(private val session: SessionStore) {

    @Serializable
    private data class ProfileRow(
        @SerialName("default_vineyard_id") val defaultVineyardId: String? = null,
    )

    /** The signed-in user's own `public.profiles` row (server source of truth). */
    @Serializable
    data class MyProfile(
        val id: String,
        val email: String? = null,
        @SerialName("full_name") val fullName: String? = null,
        @SerialName("updated_at") val updatedAt: String? = null,
    )

    /**
     * Fetch the signed-in user's profile (`id`, `email`, `full_name`,
     * `updated_at`) from `public.profiles`. Returns null when no row exists
     * yet (e.g. dashboard-created users before their first profile write).
     */
    suspend fun getMyProfile(): MyProfile? = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val userId = session.userId ?: return@withContext null
        val response = SupabaseClient.http.get(
            SupabaseClient.restUrl("profiles?id=eq.$userId&select=id,email,full_name,updated_at&limit=1"),
        ) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
        }
        when {
            response.status.isSuccess() -> {
                val rows: List<MyProfile> = response.body()
                rows.firstOrNull()
            }
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, "")
        }
    }

    /**
     * Persist the user's display name to `public.profiles.full_name` (server
     * source of truth, mirrors iOS `upsertMyProfile`). Uses an upsert so it
     * also works when the profile row doesn't exist yet; the table's
     * `set_updated_at` trigger bumps `updated_at` on update.
     */
    suspend fun updateFullName(fullName: String) = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val userId = session.userId ?: throw BackendError.Unauthorized
        val trimmed = fullName.trim()
        val email = session.userEmail?.trim().orEmpty()
        val body = buildString {
            append("{\"id\":\"").append(userId).append("\",")
            if (email.isNotEmpty()) {
                append("\"email\":").append(SupabaseClient.json.encodeToString(kotlinx.serialization.serializer<String>(), email)).append(',')
            }
            append("\"full_name\":").append(SupabaseClient.json.encodeToString(kotlinx.serialization.serializer<String>(), trimmed))
            append('}')
        }
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("profiles?on_conflict=id")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
                append("Prefer", "resolution=merge-duplicates,return=minimal")
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
