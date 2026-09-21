package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Member-safe configured vineyard weather snapshot; credentials stay server-side. */
class ScoutWeatherRepository(private val session: SessionStore) {
    @Serializable
    private data class Args(@SerialName("p_vineyard_id") val vineyardId: String)

    @Serializable
    private data class Row(
        val source: String? = null,
        @SerialName("station_name") val stationName: String? = null,
        @SerialName("observed_at") val observedAt: String? = null,
        @SerialName("temperature_c") val temperatureC: Double? = null,
        @SerialName("humidity_pct") val humidityPct: Double? = null,
        @SerialName("wind_speed_kmh") val windSpeedKmh: Double? = null,
        @SerialName("wind_gust_kmh") val windGustKmh: Double? = null,
        @SerialName("rain_today_mm") val rainTodayMm: Double? = null,
        @SerialName("is_stale") val isStale: Boolean = false,
        val status: String? = null,
    )

    suspend fun current(vineyardId: String, capturedAtIso: String): ScoutWeatherSnapshot {
        if (!SupabaseClient.isConfigured) return ScoutWeatherSnapshot.unavailable(
            capturedAtIso,
            "Configured vineyard weather source",
        )
        val token = session.accessToken ?: return ScoutWeatherSnapshot.unavailable(
            capturedAtIso,
            "Configured vineyard weather source",
        )
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("get_vineyard_current_weather")) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(Args(vineyardId))
        }
        if (!response.status.isSuccess()) {
            if (response.status.value == 401 || response.status.value == 403) throw BackendError.Unauthorized
            throw BackendError.Server(response.status.value, response.bodyAsText())
        }
        val row = response.body<List<Row>>().firstOrNull()
        if (row == null || row.status != "ok") {
            return ScoutWeatherSnapshot.unavailable(capturedAtIso, "Configured vineyard weather source")
        }
        val source = row.stationName?.takeIf { it.isNotBlank() }?.let {
            "${row.source ?: "Configured vineyard weather source"} — $it"
        } ?: row.source
        return ScoutWeatherSnapshot(
            observedAtIso = row.observedAt,
            capturedAtIso = capturedAtIso,
            source = source,
            temperatureCelsius = row.temperatureC,
            humidityPercent = row.humidityPct,
            windSpeedKph = row.windSpeedKmh,
            windGustKph = row.windGustKmh,
            recentRainfallMm = row.rainTodayMm,
            isStale = row.isStale,
            isUnavailable = false,
        )
    }
}
