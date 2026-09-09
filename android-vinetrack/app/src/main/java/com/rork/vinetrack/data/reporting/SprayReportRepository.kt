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
import java.security.MessageDigest
import java.util.Locale

/** Authenticated Spray Report v1 and hourly-weather server paths. */
class SprayReportRepository(private val session: SessionStore) {
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

    suspend fun fetch(tripId: String): SprayReportPayloadV1 {
        recoverRows(tripId)
        return rpc("get_spray_report_v1", ReportArgs(tripId))
    }

    /** Fetches every distinct trip separately; failures are omitted for caller fallback. */
    suspend fun fetchAll(tripIds: List<String>): Map<String, SprayReportPayloadV1> = buildMap {
        tripIds.distinct().forEach { tripId ->
            runCatching { fetch(tripId) }.getOrNull()?.let { put(tripId, it) }
        }
    }

    @Serializable
    private data class CorrectionArgs(
        @SerialName("p_operation_id") val operationId: String,
        @SerialName("p_trip_id") val tripId: String,
        @SerialName("p_expected_version") val expectedVersion: Long,
        @SerialName("p_machine_id") val machineId: String?,
        @SerialName("p_tractor_id") val tractorId: String?,
        @SerialName("p_spray_equipment_id") val sprayEquipmentId: String?,
        @SerialName("p_operator_user_id") val operatorUserId: String?,
        @SerialName("p_fuel_consumption_l_per_hour") val fuelRate: Double?,
        @SerialName("p_start_engine_hours") val startEngineHours: Double?,
        @SerialName("p_end_engine_hours") val endEngineHours: Double?,
    )
    @Serializable private data class CorrectionResponse(val report: SprayReportPayloadV1)

    suspend fun correctMetadata(
        tripId: String,
        expectedVersion: Long,
        machineId: String?,
        tractorId: String?,
        sprayEquipmentId: String?,
        operatorUserId: String?,
        fuelRate: Double?,
        startEngineHours: Double?,
        endEngineHours: Double?,
    ): SprayReportPayloadV1 {
        val response: CorrectionResponse = rpc(
            "correct_spray_trip_metadata_v1",
            CorrectionArgs(java.util.UUID.randomUUID().toString(), tripId, expectedVersion, machineId, tractorId,
                sprayEquipmentId, operatorUserId, fuelRate, startEngineHours, endEngineHours),
        )
        return response.report
    }

    /** Runs the shared server derivation; ambiguous paths are intentionally left unresolved. */
    private suspend fun recoverRows(tripId: String) {
        if (!SupabaseClient.isConfigured) return
        val token = session.accessToken ?: return
        runCatching {
            SupabaseClient.http.post("${SupabaseClient.baseUrl}/functions/v1/spray-row-recovery") {
                headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
                contentType(ContentType.Application.Json)
                setBody(RowRecoveryArgs(tripId))
            }
        }
    }

    @Serializable private data class RowRecoveryArgs(val tripId: String)

    /** Generates/registers the immutable hybrid route when no canonical winner exists. */
    suspend fun ensureRoute(trip: Trip): SprayReportPayloadV1.Route? {
        val points = trip.pathPoints.orEmpty()
        if (points.size < 2 || !SupabaseClient.isConfigured) return null
        val token = session.accessToken ?: return null
        val input = buildList {
            add(SprayReportPayloadV1.ROUTE_STYLE_VERSION)
            add("1030x700")
            points.forEach { add(String.format(Locale.US, "%.6f,%.6f", it.latitude, it.longitude)) }
        }.joinToString("|")
        val routeHash = MessageDigest.getInstance("SHA-256").digest(input.toByteArray()).joinToString("") { "%02x".format(it) }
        val response = SupabaseClient.http.post("${SupabaseClient.baseUrl}/functions/v1/spray-report-route-upload") {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            contentType(ContentType.Application.Json)
            setBody(RouteGenerateArgs(trip.id, routeHash, points.map { CoordinateArg(it.latitude, it.longitude) }, 1030, 700))
        }
        if (!response.status.isSuccess()) return null
        return response.body<RouteUploadResponse>().route
    }

    @Serializable private data class CoordinateArg(val latitude: Double, val longitude: Double)
    @Serializable private data class RouteGenerateArgs(val tripId: String, val routeHash: String, val coordinates: List<CoordinateArg>, val width: Int, val height: Int)
    @Serializable private data class RouteUploadResponse(val route: SprayReportPayloadV1.Route)

    suspend fun downloadRoute(route: SprayReportPayloadV1.Route): ByteArray {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get("${SupabaseClient.baseUrl}/storage/v1/object/authenticated/${route.bucket}/${route.objectPath}") {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
        }
        if (response.status.value == 401 || response.status.value == 403) throw BackendError.Unauthorized
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        val bytes: ByteArray = response.body()
        val actualHash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        if (actualHash != route.sha256) throw BackendError.Server(409, "Canonical route image hash mismatch")
        return bytes
    }

    @Serializable
    data class WeatherRecoveryResult(
        val success: Boolean,
        val captured: Int,
        val unavailable: Int,
        val pending: Int,
        val provider: String? = null,
        val stationId: String? = null,
        val reason: String? = null,
        val errors: List<String> = emptyList(),
    )

    /** Explicit historical recovery. Station availability never controls spray saving. */
    suspend fun recoverWeather(tripId: String, through: Instant): WeatherRecoveryResult {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post("${SupabaseClient.baseUrl}/functions/v1/spray-weather-recovery") {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            contentType(ContentType.Application.Json)
            setBody(WeatherRecoveryArgs(tripId, through.toString()))
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        return response.body()
    }

    /** Recovers every missing scheduled slot; server-side absence is the durable retry queue. */
    suspend fun captureUnavailableIfDue(trip: Trip, now: Instant = Instant.now(), isFinal: Boolean = false) {
        if (trip.tripFunction != "spraying" || !SupabaseClient.isConfigured) return
        val start = trip.startTime?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: return
        val elapsedHours = ChronoUnit.HOURS.between(start, now).coerceAtLeast(0)
        val through = if (isFinal) now else start.plus(elapsedHours, ChronoUnit.HOURS)
        val token = session.accessToken ?: return
        runCatching {
            SupabaseClient.http.post("${SupabaseClient.baseUrl}/functions/v1/spray-weather-recovery") {
                headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
                contentType(ContentType.Application.Json)
                setBody(WeatherRecoveryArgs(trip.id, through.toString()))
            }
        }
    }

    @Serializable private data class WeatherRecoveryArgs(val tripId: String, val through: String)

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
