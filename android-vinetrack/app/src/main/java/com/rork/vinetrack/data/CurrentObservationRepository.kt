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
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/** Member-safe current weather routing. The server owns provider selection and staleness. */
class CurrentObservationRepository(private val session: SessionStore) {
    @Serializable
    data class CachedRow(
        val source: String = "none",
        @SerialName("station_id") val stationId: String? = null,
        @SerialName("station_name") val stationName: String? = null,
        @SerialName("observed_at") val observedAt: String? = null,
        @SerialName("temperature_c") val temperatureC: Double? = null,
        @SerialName("humidity_pct") val humidityPct: Double? = null,
        @SerialName("wind_speed_kmh") val windSpeedKmh: Double? = null,
        @SerialName("wind_direction_deg") val windDirectionDeg: Double? = null,
        @SerialName("wind_gust_kmh") val windGustKmh: Double? = null,
        @SerialName("rain_today_mm") val rainTodayMm: Double? = null,
        @SerialName("rain_rate_mm_per_hr") val rainRateMmPerHr: Double? = null,
        @SerialName("leaf_wetness") val leafWetness: Double? = null,
        val message: String? = null,
        @SerialName("is_stale") val isStale: Boolean = false,
        val status: String = "not_configured",
    ) {
        val sourceLabel: String get() = labelFor(source)
        val refreshFailureMessage: String get() = "Live observations not refreshed — $sourceLabel"
    }

    suspend fun current(vineyardId: String): CachedRow? = withContext(Dispatchers.IO) {
        SupabaseClient.json.decodeFromString<List<CachedRow>>(
            rpc("get_vineyard_current_weather", buildJsonObject { put("p_vineyard_id", vineyardId) })
        ).firstOrNull()
    }

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
        val access = session.accountAccess() ?: throw BackendError.Unauthorized
        fun requireAccount() { if (!session.isAccountAccessCurrent(access)) throw BackendError.Unauthorized }
        val selection = try { selected(vineyardId) } catch (error: BackendError.Server) {
            val code = runCatching { SupabaseClient.json.parseToJsonElement(error.body).jsonObject["code"]?.jsonPrimitive?.contentOrNull }.getOrNull()
            // Older servers retain the existing Davis/WU route only. Never
            // interpret authentication or network failure as automatic selection.
            if (error.code in setOf(400, 404) && code in setOf("PGRST202", "42883")) null else throw error
        }
        requireAccount()
        val row = current(vineyardId)
        requireAccount()
        val source = resolvedSource(selection, row?.source ?: "none")
        val action = actionFor(source, row?.status ?: "no_data", row?.isStale ?: true, force)
            ?: return@withContext (row?.status ?: "not_configured")
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val function = functionFor(action)
        requireAccount()
        val response = SupabaseClient.http.post(SupabaseClient.functionUrl(function)) {
            attributes.put(SupabaseClient.accountRequestScope, access)
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(currentBody(vineyardId, action, row?.stationId))
        }
        if (!response.status.isSuccess()) {
            // Do not surface/log an upstream response body or credentials.
            throw BackendError.Server(response.status.value, "Live observations not refreshed — ${labelFor(action)}")
        }
        requireAccount()
        val updated = current(vineyardId)
        requireAccount()
        if (action == MAIT && row?.observedAt != null && (updated?.observedAt == row.observedAt || updated == null)) "no_newer" else "ok"
    }

    /** Independent authenticated sensor read. A failure never changes the primary cache. */
    suspend fun supplementary(vineyardId: String): MAITSupplementarySensors = withContext(Dispatchers.IO) {
        val access = session.accountAccess() ?: throw BackendError.Unauthorized
        val selectedAtStart = session.selectedVineyardId
        fun requireScope() {
            if (!session.isAccountAccessCurrent(access) || session.selectedVineyardId != selectedAtStart) throw BackendError.Unauthorized
        }
        val token = session.accessToken ?: throw BackendError.Unauthorized
        requireScope()
        val response = SupabaseClient.http.post(SupabaseClient.functionUrl("mait-intelliweb-proxy")) {
            attributes.put(SupabaseClient.accountRequestScope, access)
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(supplementaryBody(vineyardId))
        }
        requireScope()
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, MAITSupplementarySensors.WARNING)
        val decoded = SupabaseClient.json.decodeFromString<MAITSupplementarySensors>(response.bodyAsText())
        requireScope()
        if (response.status.value == 206) decoded.copy(partial = true) else decoded
    }

    private suspend fun rpc(name: String, body: JsonObject): String {
        val access = session.accountAccess() ?: throw BackendError.Unauthorized
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
            attributes.put(SupabaseClient.accountRequestScope, access)
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        if (!session.isAccountAccessCurrent(access)) throw BackendError.Unauthorized
        return response.bodyAsText()
    }

    companion object {
        const val MAIT = "mait_intelliweb"
        const val MAIT_LABEL = "MAIT iNTELLiWeb"
        const val MAIT_HELP = "MAIT iNTELLiWeb is configured in the VineTrack Portal by a Vineyard Owner or Manager."

        fun supplementaryBody(vineyardId: String): JsonObject = buildJsonObject {
            put("vineyardId", vineyardId)
            put("action", "supplementary_current")
        }

        fun compassDirection(degrees: Double): String {
            val directions = listOf("N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW")
            val normalized = ((degrees % 360) + 360) % 360
            return directions[kotlin.math.floor(normalized / 22.5 + 0.5).toInt() % 16]
        }

        fun retainingLastKnown(incoming: CachedRow?, previous: CachedRow?): CachedRow? = when {
            incoming == null -> previous
            incoming.status != "ok" && previous?.status == "ok" && previous.source == incoming.source -> previous
            else -> incoming
        }

        fun labelFor(source: String): String = when (source) {
            MAIT -> MAIT_LABEL
            "davis_weatherlink" -> "Davis WeatherLink"
            "wunderground_pws" -> "Weather Underground PWS"
            else -> source
        }

        fun resolvedSource(selection: String?, legacySource: String): String =
            selection ?: legacySource.takeIf { it in setOf("davis_weatherlink", "wunderground_pws") } ?: "none"

        fun functionFor(source: String): String = when (source) {
            MAIT -> "mait-intelliweb-proxy"
            "wunderground_pws" -> "wunderground-proxy"
            "davis_weatherlink" -> "davis-proxy"
            else -> error("No current-observation refresh for this source")
        }

        fun currentBody(vineyardId: String, source: String, stationId: String?): JsonObject = buildJsonObject {
            put("vineyardId", vineyardId)
            put("action", "current")
            if (source == "davis_weatherlink") put("stationId", stationId ?: error("No Davis station selected"))
        }

        /** A failed selected request never becomes another provider request. */
        fun actionFor(source: String, status: String, stale: Boolean, force: Boolean): String? =
            source.takeIf { status != "not_configured" && (force || stale || status == "no_data") &&
                it in setOf("davis_weatherlink", "wunderground_pws", MAIT) }
    }
}
