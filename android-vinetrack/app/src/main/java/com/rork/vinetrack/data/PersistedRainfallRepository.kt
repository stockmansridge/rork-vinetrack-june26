package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone
import kotlin.math.max

/**
 * One row returned by `public.get_daily_rainfall(p_vineyard_id, p_from, p_to)`.
 * One row exists for every day in the requested range; [rainfallMm] is null
 * when no source has data for that day. Mirrors the iOS `PersistedRainfallDay`.
 *
 * [source] is the raw source string from the RPC: `"manual"`,
 * `"davis_weatherlink"`, `"open_meteo"`, `"wunderground"`, or null when no row
 * exists for the day. The RPC returns the highest-priority source per day:
 * `manual > davis_weatherlink > wunderground > open_meteo`.
 */
data class PersistedRainfallDay(
    /** Calendar-day key, "yyyy-MM-dd", as returned by the RPC. */
    val date: String,
    val rainfallMm: Double?,
    val source: String?,
    val stationId: String?,
    val stationName: String?,
    val notes: String?,
)

/**
 * Reads vineyard-level persisted rainfall history (`public.rainfall_daily`)
 * via the `get_daily_rainfall` RPC. The RPC enforces vineyard membership and
 * returns the highest-priority source per day. This lets Android show the same
 * station-sourced rainfall history the iOS app stores — without hammering the
 * weather providers from every device.
 */
class PersistedRainfallRepository(private val session: SessionStore) {

    @Serializable
    private data class Params(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_from_date") val fromDate: String,
        @SerialName("p_to_date") val toDate: String,
    )

    @Serializable
    private data class Row(
        val date: String,
        @SerialName("rainfall_mm") val rainfallMm: Double? = null,
        val source: String? = null,
        @SerialName("station_id") val stationId: String? = null,
        @SerialName("station_name") val stationName: String? = null,
        val notes: String? = null,
    )

    /**
     * Fetch persisted daily rainfall in `[from, to]` (inclusive). Dates are
     * "yyyy-MM-dd" calendar-day strings. Returns an empty list when Supabase is
     * not configured or the user has no session.
     */
    suspend fun fetchDailyRainfall(
        vineyardId: String,
        fromDate: String,
        toDate: String,
    ): List<PersistedRainfallDay> = withContext(Dispatchers.IO) {
        if (!SupabaseClient.isConfigured) return@withContext emptyList()
        val token = session.accessToken ?: return@withContext emptyList()

        val response = SupabaseClient.http.post(
            SupabaseClient.rpcUrl("get_daily_rainfall")
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(Params(vineyardId, fromDate, toDate))
        }
        rows(response).map {
            PersistedRainfallDay(
                date = it.date.take(10),
                rainfallMm = it.rainfallMm,
                source = it.source,
                stationId = it.stationId,
                stationName = it.stationName,
                notes = it.notes,
            )
        }
    }

    /**
     * Total recent measured rainfall over a lookback window, preferring the
     * persisted vineyard history (`get_daily_rainfall`) and falling back to the
     * free Open-Meteo archive. Used by the Irrigation Advisor to offset the
     * forecast deficit, mirroring iOS `fetchRecentRainfallPreferringPersisted`.
     */
    suspend fun fetchRecentRainfallSummary(
        vineyardId: String?,
        latitude: Double,
        longitude: Double,
        days: Int,
        rainRepo: RainForecastRepository,
    ): RecentRainfallSummary = withContext(Dispatchers.IO) {
        val window = max(1, days)
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = TimeZone.getDefault() }
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val toKey = fmt.format(cal.time)
        cal.add(Calendar.DAY_OF_YEAR, -(window - 1))
        val fromKey = fmt.format(cal.time)

        // Persisted station-sourced rainfall preferred.
        if (vineyardId != null && SupabaseClient.isConfigured) {
            try {
                val rows = fetchDailyRainfall(vineyardId, fromKey, toKey)
                    .filter { it.rainfallMm != null }
                if (rows.isNotEmpty()) {
                    val total = rows.sumOf { it.rainfallMm ?: 0.0 }
                    return@withContext RecentRainfallSummary(
                        totalMm = total,
                        measuredDays = rows.size,
                        windowDays = window,
                        sourceLabel = recentSourceLabel(rows),
                        usedPersisted = true,
                    )
                }
            } catch (_: Exception) {
                // Fall through to the Open-Meteo archive.
            }
        }

        // Fallback: Open-Meteo archive for the recent window.
        return@withContext try {
            val bundle = rainRepo.fetch(latitude, longitude, pastDays = window, forecastDays = 1)
            val recent = bundle.history.takeLast(window)
            RecentRainfallSummary(
                totalMm = recent.sumOf { it.rainMm },
                measuredDays = recent.size,
                windowDays = window,
                sourceLabel = "Open-Meteo archive",
                usedPersisted = false,
            )
        } catch (_: Exception) {
            RecentRainfallSummary(0.0, 0, window, "Unavailable", false)
        }
    }

    /** Pick a human label for the dominant persisted source in a recent window. */
    private fun recentSourceLabel(days: List<PersistedRainfallDay>): String {
        val sources = days.mapNotNull { it.source }
        return when {
            sources.any { it == "davis_weatherlink" } -> "Davis WeatherLink"
            sources.any { it == "manual" } -> "Manual readings"
            sources.any { it == "wunderground" } -> "Weather Underground"
            sources.any { it == "open_meteo" } -> "Open-Meteo"
            else -> "Recorded rainfall"
        }
    }

    private suspend fun rows(response: HttpResponse): List<Row> = when {
        response.status.isSuccess() -> response.body()
        response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
        else -> throw BackendError.Server(response.status.value, response.bodyAsText())
    }

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}

/**
 * Summary of recent measured rainfall used to offset the irrigation deficit.
 * [usedPersisted] is true when the values came from the vineyard's persisted
 * station history rather than the Open-Meteo archive fallback.
 */
data class RecentRainfallSummary(
    val totalMm: Double,
    val measuredDays: Int,
    val windowDays: Int,
    val sourceLabel: String,
    val usedPersisted: Boolean,
)
