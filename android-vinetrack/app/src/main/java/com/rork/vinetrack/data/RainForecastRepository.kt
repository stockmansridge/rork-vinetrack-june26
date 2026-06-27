package com.rork.vinetrack.data

import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * A single daily rainfall/forecast day used by the Rain & Forecast page.
 *
 * Mirrors the iOS `RainAndForecastView` data model: each day carries the daily
 * precipitation total (mm) and the maximum forecast wind speed (km/h, when
 * available). Days in the past are treated as recorded rainfall history;
 * today + future days are treated as forecast.
 */
data class RainDay(
    val dateEpochMs: Long,
    val rainMm: Double,
    val windKmhMax: Double?,
)

/** Combined rainfall history + forecast bundle returned to the Rain page. */
data class RainForecastBundle(
    /** Past days (before today), most useful as recorded rainfall history. */
    val history: List<RainDay>,
    /** Today + future days, used as the forecast. */
    val forecast: List<RainDay>,
    val source: String,
) {
    /** Today's recorded/forecast rain (the day whose date matches today). */
    val todayMm: Double?
        get() = forecast.firstOrNull()?.rainMm
}

/**
 * Fetches daily rainfall (history + forecast) plus max wind from the free
 * Open-Meteo API. A single request covers `past_days` of recorded rainfall and
 * `forecast_days` of forecast, matching the data the iOS Rain & Forecast page
 * shows (today's rain, next 24h/48h/7d, daily forecast rows with wind, and the
 * last 30 days of rainfall history). No API key required and nothing persisted.
 */
class RainForecastRepository {

    suspend fun fetch(
        latitude: Double,
        longitude: Double,
        pastDays: Int = 30,
        forecastDays: Int = 7,
    ): RainForecastBundle {
        val past = pastDays.coerceIn(0, 92)
        val ahead = forecastDays.coerceIn(1, 16)
        val url = "https://api.open-meteo.com/v1/forecast" +
            "?latitude=$latitude&longitude=$longitude" +
            "&daily=precipitation_sum,wind_speed_10m_max" +
            "&past_days=$past&forecast_days=$ahead&timezone=auto"

        val response = SupabaseClient.http.get(url)
        if (!response.status.isSuccess()) {
            throw IllegalStateException("Failed to fetch rain forecast (HTTP ${response.status.value}).")
        }

        val root = SupabaseClient.json.parseToJsonElement(response.bodyAsText()).jsonObject
        val daily = root["daily"]?.jsonObject
            ?: throw IllegalStateException("Rain forecast response could not be parsed.")
        val times = daily["time"]?.jsonArray
            ?: throw IllegalStateException("Rain forecast response could not be parsed.")
        val rains = daily["precipitation_sum"]?.jsonArray
        val winds = daily["wind_speed_10m_max"]?.jsonArray

        // Open-Meteo daily times are local "yyyy-MM-dd".
        val formatter = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
            timeZone = TimeZone.getDefault()
        }

        // Start of today in local time, used to split history vs forecast.
        val startOfToday = run {
            val cal = java.util.Calendar.getInstance()
            cal.set(java.util.Calendar.HOUR_OF_DAY, 0)
            cal.set(java.util.Calendar.MINUTE, 0)
            cal.set(java.util.Calendar.SECOND, 0)
            cal.set(java.util.Calendar.MILLISECOND, 0)
            cal.timeInMillis
        }

        val history = mutableListOf<RainDay>()
        val forecast = mutableListOf<RainDay>()
        for (i in 0 until times.size) {
            val dateString = times[i].jsonPrimitive.content
            val date = formatter.parse(dateString) ?: continue
            val day = RainDay(
                dateEpochMs = date.time,
                rainMm = parseDoubleOrNull(rains, i) ?: 0.0,
                windKmhMax = parseDoubleOrNull(winds, i),
            )
            if (date.time < startOfToday) history.add(day) else forecast.add(day)
        }

        return RainForecastBundle(
            history = history.sortedBy { it.dateEpochMs },
            forecast = forecast.sortedBy { it.dateEpochMs },
            source = "Open-Meteo",
        )
    }

    /**
     * Fetches a full calendar year of daily rainfall (mm), keyed by
     * "yyyy-MM-dd". Uses the Open-Meteo archive API for the historical part of
     * the year and merges the recent ~30 days from the forecast API so the most
     * recent days (which the archive lags behind on) are still covered. Mirrors
     * the data the iOS Rainfall Calendar shows. No API key required, nothing
     * persisted.
     */
    suspend fun fetchYear(
        latitude: Double,
        longitude: Double,
        year: Int,
    ): YearlyRainfall {
        val formatter = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
            timeZone = TimeZone.getDefault()
        }
        val cal = java.util.Calendar.getInstance()
        val currentYear = cal.get(java.util.Calendar.YEAR)
        val todayString = formatter.format(cal.time)

        val startDate = "$year-01-01"
        val endDate = if (year >= currentYear) todayString else "$year-12-31"

        val daily = mutableMapOf<String, Double>()
        var archiveDays = 0
        var recentDays = 0

        // 1) Historical archive for the requested year.
        try {
            val archiveUrl = "https://archive-api.open-meteo.com/v1/archive" +
                "?latitude=$latitude&longitude=$longitude" +
                "&start_date=$startDate&end_date=$endDate" +
                "&daily=precipitation_sum&timezone=auto"
            val response = SupabaseClient.http.get(archiveUrl)
            if (response.status.isSuccess()) {
                archiveDays = mergeDailyRain(response.bodyAsText(), daily)
            }
        } catch (_: Exception) {
            // Archive is best-effort; recent merge below still gives coverage.
        }

        // 2) Merge the recent ~30 days from the forecast API (covers the days
        //    the archive lags behind on, only relevant for the current year).
        if (year >= currentYear) {
            try {
                val recentUrl = "https://api.open-meteo.com/v1/forecast" +
                    "?latitude=$latitude&longitude=$longitude" +
                    "&daily=precipitation_sum&past_days=92&forecast_days=1&timezone=auto"
                val response = SupabaseClient.http.get(recentUrl)
                if (response.status.isSuccess()) {
                    recentDays = mergeDailyRain(response.bodyAsText(), daily, onlyYear = year)
                }
            } catch (_: Exception) {
                // Best-effort.
            }
        }

        return YearlyRainfall(
            year = year,
            dailyMm = daily,
            archiveDays = archiveDays,
            recentDays = recentDays,
            source = "Open-Meteo",
        )
    }

    /**
     * Parses an Open-Meteo daily response and merges its precipitation values
     * into [into] (keyed by "yyyy-MM-dd"). Returns the number of days merged.
     */
    private fun mergeDailyRain(
        body: String,
        into: MutableMap<String, Double>,
        onlyYear: Int? = null,
    ): Int {
        val root = SupabaseClient.json.parseToJsonElement(body).jsonObject
        val dailyObj = root["daily"]?.jsonObject ?: return 0
        val times = dailyObj["time"]?.jsonArray ?: return 0
        val rains = dailyObj["precipitation_sum"]?.jsonArray
        var count = 0
        for (i in 0 until times.size) {
            val key = times[i].jsonPrimitive.content
            if (onlyYear != null && !key.startsWith("$onlyYear-")) continue
            val mm = parseDoubleOrNull(rains, i) ?: continue
            into[key] = mm
            count++
        }
        return count
    }

    private fun parseDoubleOrNull(array: JsonArray?, index: Int): Double? {
        if (array == null || index >= array.size) return null
        return try {
            array[index].jsonPrimitive.doubleOrNull
        } catch (e: Exception) {
            null
        }
    }
}

/** A full year of daily rainfall (mm) keyed by "yyyy-MM-dd". */
data class YearlyRainfall(
    val year: Int,
    val dailyMm: Map<String, Double>,
    val archiveDays: Int,
    val recentDays: Int,
    val source: String,
)
