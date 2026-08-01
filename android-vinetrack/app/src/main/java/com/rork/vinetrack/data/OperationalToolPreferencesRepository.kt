package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The caller's saved Operational Tools layout as returned by SQL 159.
 *
 * `hasPreference == false` means "no record yet" — the app uses the VineTrack
 * default order and shows every authorised tool.
 */
@Serializable
data class OperationalToolPreferencesDto(
    @SerialName("has_preference") val hasPreference: Boolean = false,
    val version: Int = 1,
    @SerialName("visible_tool_ids") val visibleToolIds: List<String> = emptyList(),
    @SerialName("hidden_tool_ids") val hiddenToolIds: List<String> = emptyList(),
)

/**
 * Reads and writes the signed-in user's own Operational Tools layout.
 *
 * Every RPC is SECURITY DEFINER and derives the user from `auth.uid()`, so the
 * layout is per-user (never per-vineyard) and is shared with iOS and the
 * portal.
 */
class OperationalToolPreferencesRepository(private val session: SessionStore) {

    suspend fun fetch(): OperationalToolPreferencesDto = call("get_my_operational_tool_preferences", null)

    suspend fun save(
        visibleToolIds: List<String>,
        hiddenToolIds: List<String>,
    ): OperationalToolPreferencesDto = call(
        "set_my_operational_tool_preferences",
        buildJsonObject {
            put("p_visible_tool_ids", buildJsonArray { visibleToolIds.forEach { add(it) } })
            put("p_hidden_tool_ids", buildJsonArray { hiddenToolIds.forEach { add(it) } })
            put("p_preference_version", 1)
        },
    )

    suspend fun reset(): OperationalToolPreferencesDto = call("reset_my_operational_tool_preferences", null)

    private suspend fun call(rpc: String, body: JsonObject?): OperationalToolPreferencesDto =
        withContext(Dispatchers.IO) {
            if (!SupabaseClient.isConfigured) throw IllegalStateException("Supabase is not configured")
            val token = session.accessToken ?: throw IllegalStateException("Not signed in")
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(rpc)) {
                headers {
                    append("apikey", SupabaseClient.anonKey)
                    append("Authorization", "Bearer $token")
                }
                contentType(ContentType.Application.Json)
                setBody(body ?: JsonObject(emptyMap()))
            }
            if (!response.status.isSuccess()) {
                // Sanitised: the server message never contains user data, but we
                // only surface the status to the UI layer.
                throw IllegalStateException("tool_preferences_rpc_failed_${response.status.value}")
            }
            val payload = response.body<JsonObject>()
            SupabaseClient.json.decodeFromJsonElement(
                OperationalToolPreferencesDto.serializer(),
                payload,
            )
        }
}
