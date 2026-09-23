package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Member-safe current weather routing. The server owns provider selection and staleness. */
class CurrentObservationRepository(private val session: SessionStore) {
    @Serializable
    private data class CachedRow(
        val source: String = "none",
        @SerialName("station_id") val stationId: String? = null,
        @SerialName("is_stale") val isStale: Boolean = false,
        val status: String = "not_configured",
    )

    suspend fun selected(vineyardId: String): String? = withContext(Dispatchers.IO) {
        val response = rpc("get_vineyard_current_observation_provider", buildJsonObject { put("p_vineyard_id", vineyardId) })
        SupabaseClient.json.parseToJsonElement(response).jsonPrimitive.contentOrNull
    }

    suspend fun select(vineyardId: String, source: String): Unit = withContext(Dispatchers.IO) {
        require(source in setOf("none", "davis_weatherlink", "wunderground_pws"))
        rpc("set_vineyard_current_observation_provider", buildJsonObject {
            put("p_vineyard_id", vineyardId)
            put("p_provider", source)
        })
    }

    suspend fun refresh(vineyardId: String, force: Boolean = false): String = withContext(Dispatchers.IO) {
        val rows = SupabaseClient.json.decodeFromString<List<CachedRow>>(
            rpc("get_vineyard_current_weather", buildJsonObject { put("p_vineyard_id", vineyardId) })
        )
        val row = rows.firstOrNull() ?: return@withContext "not_configured"
        val action = actionFor(row.source, row.status, row.isStale, force)
            ?: return@withContext row.status
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val function = if (action == "wunderground_pws") "wunderground-proxy" else "davis-proxy"
        val response = SupabaseClient.http.post(SupabaseClient.functionUrl(function)) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(buildJsonObject {
                put("vineyardId", vineyardId)
                put("action", "current")
                if (action == "davis_weatherlink") {
                    val stationId = row.stationId ?: error("No Davis station selected")
                    put("stationId", stationId)
                }
            })
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        "ok"
    }

    private suspend fun rpc(name: String, body: JsonObject): String {
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        return response.bodyAsText()
    }

    companion object {
        /** A failed WU request never becomes a Davis request. */
        fun actionFor(source: String, status: String, stale: Boolean, force: Boolean): String? =
            source.takeIf { status != "not_configured" && (force || stale || status == "no_data") &&
                it in setOf("davis_weatherlink", "wunderground_pws") }
    }
}
