package com.rork.vinetrack.data.reporting

import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.Trip
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.concurrent.ConcurrentHashMap

/** Authenticated Spray Report v1 and hourly-weather server paths. */
class SprayReportRepository(private val session: SessionStore) {
    private val submittedSlots: MutableSet<String> = ConcurrentHashMap.newKeySet()

    @Serializable private data class ReportArgs(@SerialName("p_trip_id") val tripId: String)
    @Serializable private data class WeatherArgs(
        @SerialName("p_trip_id") val tripId: String,
        @SerialName("p_sample_slot") val sampleSlot: String,
        @SerialName("p_observed_at") val observedAt: String? = null,
        @SerialName("p_source") val source: String = "Mobile capture unavailable",
        @SerialName("p_source_kind") val sourceKind: String = "unavailable",
        @SerialName("p_station_id") val stationId: String? = null,
        @SerialName("p_temperature_c") val temperatureC: Double? = null,
        @SerialName("p_humidity_pct") val humidityPct: Double? = null,
        @SerialName("p_wind_speed_kmh") val windSpeedKmh: Double? = null,
        @SerialName("p_wind_gust_kmh") val windGustKmh: Double? = null,
        @SerialName("p_wind_direction_deg") val windDirectionDeg: Double? = null,
        @SerialName("p_rain_mm") val rainMm: Double? = null,
        @SerialName("p_is_stale") val isStale: Boolean = false,
    )

    suspend fun fetch(tripId: String): SprayReportPayloadV1 = rpc("get_spray_report_v1", ReportArgs(tripId))

    suspend fun downloadRoute(route: SprayReportPayloadV1.Route): ByteArray {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get("${SupabaseClient.baseUrl}/storage/v1/object/authenticated/${route.bucket}/${route.objectPath}") {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
        }
        if (response.status.value == 401 || response.status.value == 403) throw BackendError.Unauthorized
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        return response.body()
    }

    /** Writes an honest unavailable slot when no genuine provider observation is present. */
    suspend fun captureUnavailableIfDue(trip: Trip, now: Instant = Instant.now(), isFinal: Boolean = false) {
        if (trip.tripFunction != "spraying") return
        val start = trip.startTime?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: return
        val elapsedHours = ChronoUnit.HOURS.between(start, now).coerceAtLeast(0)
        val slot = if (isFinal) now else start.plus(elapsedHours, ChronoUnit.HOURS)
        val key = "${trip.id}:${slot.epochSecond}"
        if (!submittedSlots.add(key)) return
        runCatching {
            rpc<WeatherArgs, JsonElement>("capture_trip_weather_observation_v1", WeatherArgs(trip.id, slot.toString()))
        }.onFailure { submittedSlots.remove(key) }
    }

    private suspend inline fun <reified Body, reified Result> rpc(name: String, body: Body): Result {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        if (response.status.value == 401 || response.status.value == 403) throw BackendError.Unauthorized
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        return response.body()
    }
}
