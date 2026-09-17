package com.rork.vinetrack.data

import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.acos
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.tan

/** One day's high/low temperature in °C. */
data class DailyTemp(val high: Double, val low: Double)

/** One point in a cumulative GDD series. */
data class GddPoint(
    val epochDayMs: Long,
    val daily: Double,
    val cumulative: Double,
    val interpolated: Boolean,
)

/** Exclusive-end date range requested from one weather provider. */
data class WeatherDateWindow(val startEpochMs: Long, val endEpochMs: Long)

/**
 * Growing Degree Day engine for the Optimal Ripeness surface. Ports the iOS
 * `DegreeDayService` Open-Meteo path: daily min/max temperatures are pulled from
 * the free Open-Meteo Archive (older days) and forecast `past_days` (recent days
 * the archive lags ~5 days behind), then accumulated as plain GDD or BEDD with a
 * day-length factor — identical maths to iOS so Android and iOS agree.
 *
 * No API key is required. Temperatures are cached per location for the app
 * session; missing days are interpolated from neighbours, matching iOS.
 */
class DegreeDayService(
    private val persistentCache: DailyWeatherCache? = null,
    private val timeZone: TimeZone = TimeZone.getDefault(),
) {

    private val baseTemp: Double = 10.0
    private val beddCap: Double = 19.0

    /** Per-location cache of daily temperatures keyed by yyyyMMdd. */
    private val tempsBySource: MutableMap<String, MutableMap<String, DailyTemp>> = mutableMapOf()

    /** The source key whose data was most recently fetched (for the UI label). */
    var lastSourceKey: String? = null
        private set

    /** True while a season fetch is in flight (UI spinner). */
    var isLoading: Boolean = false
        private set

    companion object {
        /** Stable cache key for an Open-Meteo location source. */
        fun openMeteoKey(latitude: Double, longitude: Double): String =
            String.format(Locale.US, "openmeteo:%.4f,%.4f", latitude, longitude)

        fun davisKey(stationId: String): String = "davis:${stationId.trim()}"

        private fun compactFormatter(timeZone: TimeZone): SimpleDateFormat =
            SimpleDateFormat("yyyyMMdd", Locale.US).apply { this.timeZone = timeZone }

        private fun isoFormatter(timeZone: TimeZone): SimpleDateFormat =
            SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { this.timeZone = timeZone }
    }

    private fun startOfDay(time: Long): Long {
        val cal = Calendar.getInstance(timeZone)
        cal.timeInMillis = time
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }

    private fun addDays(time: Long, days: Int): Long {
        val cal = Calendar.getInstance(timeZone)
        cal.timeInMillis = time
        cal.add(Calendar.DAY_OF_YEAR, days)
        return cal.timeInMillis
    }

    /** True when at least one usable day is cached for a source. */
    fun hasUsableData(sourceKey: String): Boolean = sourceTemps(sourceKey).isNotEmpty()

    private fun sourceTemps(sourceKey: String): MutableMap<String, DailyTemp> =
        tempsBySource.getOrPut(sourceKey) { persistentCache?.load(sourceKey)?.toMutableMap() ?: mutableMapOf() }

    /** Exact observed coverage, excluding interpolation. */
    fun hasCompleteData(sourceKey: String, fromMs: Long, toMs: Long): Boolean {
        val rows = sourceTemps(sourceKey)
        var day = startOfDay(fromMs)
        val end = startOfDay(toMs)
        while (day < end) {
            if (rows[compactFormatter(timeZone).format(Date(day))] == null) return false
            day = addDays(day, 1)
        }
        return day > startOfDay(fromMs)
    }

    /**
     * Plans provider-specific refreshes. Missing dates are requested, plus the
     * latest three completed days so revised provider observations are upserted.
     */
    fun refreshWindows(
        sourceKey: String,
        fromMs: Long,
        toMs: Long,
        recentOverlapDays: Int = 3,
    ): List<WeatherDateWindow> {
        val start = startOfDay(fromMs)
        val end = startOfDay(toMs)
        if (start >= end) return emptyList()
        val rows = sourceTemps(sourceKey)
        val formatter = compactFormatter(timeZone)
        val overlapStart = max(start, addDays(end, -recentOverlapDays.coerceAtLeast(0)))
        val requestedDays = mutableListOf<Long>()
        var day = start
        while (day < end) {
            val isMissing = rows[formatter.format(Date(day))] == null
            if (isMissing || day >= overlapStart) requestedDays.add(day)
            day = addDays(day, 1)
        }
        if (requestedDays.isEmpty()) return emptyList()
        val windows = mutableListOf<WeatherDateWindow>()
        var windowStart = requestedDays.first()
        var previous = windowStart
        for (candidate in requestedDays.drop(1)) {
            if (candidate != addDays(previous, 1)) {
                windows.add(WeatherDateWindow(windowStart, addDays(previous, 1)))
                windowStart = candidate
            }
            previous = candidate
        }
        windows.add(WeatherDateWindow(windowStart, addDays(previous, 1)))
        return windows
    }

    /** Installs daily data fetched through the canonical provider repository. */
    fun installDailyTemps(sourceKey: String, temperatures: Map<String, DailyTemp>): Boolean {
        val merged = sourceTemps(sourceKey)
        merged.putAll(temperatures)
        lastSourceKey = sourceKey
        if (temperatures.isNotEmpty()) {
            persistentCache?.save(sourceKey, timeZone.id, sourceKey, merged)
        }
        return merged.isNotEmpty()
    }

    /** Fetches only the planned missing/recent windows from Open-Meteo. */
    suspend fun fetchOpenMeteoWindows(
        latitude: Double,
        longitude: Double,
        windows: List<WeatherDateWindow>,
    ): Boolean {
        val key = openMeteoKey(latitude, longitude)
        val today = startOfDay(System.currentTimeMillis())
        val archiveCutoff = addDays(today, -6)
        val station = sourceTemps(key)
        val isoFmt = isoFormatter(timeZone)
        isLoading = true
        try {
            windows.forEach { window ->
                val finalIncludedDay = addDays(window.endEpochMs, -1)
                val archiveEnd = min(finalIncludedDay, archiveCutoff)
                if (window.startEpochMs <= archiveEnd) {
                    val url = "https://archive-api.open-meteo.com/v1/archive" +
                        "?latitude=$latitude&longitude=$longitude" +
                        "&start_date=${isoFmt.format(Date(window.startEpochMs))}" +
                        "&end_date=${isoFmt.format(Date(archiveEnd))}" +
                        "&daily=temperature_2m_max,temperature_2m_min&timezone=auto"
                    runCatching { applyDaily(fetchJson(url), station) }
                }
            }
            val firstRecentDay = addDays(archiveCutoff, 1)
            val recentStart = windows
                .filter { it.endEpochMs > firstRecentDay }
                .minOfOrNull { max(it.startEpochMs, firstRecentDay) }
            if (recentStart != null) {
                val daysBack = ((today - recentStart) / 86_400_000L).toInt() + 1
                val pastDays = max(1, min(92, daysBack))
                val url = "https://api.open-meteo.com/v1/forecast" +
                    "?latitude=$latitude&longitude=$longitude" +
                    "&daily=temperature_2m_max,temperature_2m_min" +
                    "&past_days=$pastDays&forecast_days=1&timezone=auto"
                runCatching { applyDaily(fetchJson(url), station) }
            }
            lastSourceKey = key
            if (station.isNotEmpty()) persistentCache?.save(key, timeZone.id, key, station)
            return station.isNotEmpty()
        } catch (_: Exception) {
            return station.isNotEmpty()
        } finally {
            isLoading = false
        }
    }

    private suspend fun fetchJson(url: String): String {
        val response = SupabaseClient.http.get(url)
        if (!response.status.isSuccess()) {
            throw IllegalStateException("Open-Meteo HTTP ${response.status.value}")
        }
        return response.bodyAsText()
    }

    /** Parses an Open-Meteo daily payload into the cache; returns days written. */
    private fun applyDaily(body: String, into: MutableMap<String, DailyTemp>): Int {
        val daily = SupabaseClient.json.parseToJsonElement(body).jsonObject["daily"]?.jsonObject ?: return 0
        val times = daily["time"]?.jsonArray ?: return 0
        val highs = daily["temperature_2m_max"]?.jsonArray ?: return 0
        val lows = daily["temperature_2m_min"]?.jsonArray ?: return 0
        val count = minOf(times.size, highs.size, lows.size)
        var written = 0
        for (i in 0 until count) {
            val localDate = times[i].jsonPrimitive.content
            if (localDate.length != 10) continue
            val high = highs[i].jsonPrimitive.doubleOrNull ?: continue
            val low = lows[i].jsonPrimitive.doubleOrNull ?: continue
            into[localDate.replace("-", "")] = DailyTemp(high, low)
            written++
        }
        return written
    }

    /**
     * Per-day GDD series (missing days interpolated from up to 3 reported
     * neighbours on each side) with a running cumulative total, between
     * [fromMs] and [toMs] (exclusive end). Mirrors iOS `dailyGDDSeries`.
     */
    fun dailyGddSeries(
        sourceKey: String,
        fromMs: Long,
        toMs: Long,
        latitude: Double?,
        useBEDD: Boolean,
    ): List<GddPoint> {
        val station = sourceTemps(sourceKey)
        if (station.isEmpty()) return emptyList()
        val startDay = startOfDay(fromMs)
        val endDay = startOfDay(toMs)
        val allDays = buildList {
            var d = startDay
            while (d < endDay) { add(d); d = addDays(d, 1) }
        }
        val compactFmt = compactFormatter(timeZone)
        val raw: List<DailyTemp?> = allDays.map { station[compactFmt.format(Date(it))] }
        val filled = raw.toMutableList()
        val interpolatedFlags = BooleanArray(raw.size)
        for (i in filled.indices) {
            if (filled[i] != null) continue
            val highs = mutableListOf<Double>()
            val lows = mutableListOf<Double>()
            var j = i - 1
            while (j >= 0 && highs.size < 3) {
                raw[j]?.let { highs.add(it.high); lows.add(it.low) }
                j--
            }
            var k = i + 1
            while (k < raw.size && highs.size < 6) {
                raw[k]?.let { highs.add(it.high); lows.add(it.low) }
                k++
            }
            if (highs.isEmpty()) continue
            filled[i] = DailyTemp(highs.average(), lows.average())
            interpolatedFlags[i] = true
        }
        var cumulative = 0.0
        val result = mutableListOf<GddPoint>()
        for ((idx, day) in allDays.withIndex()) {
            val temp = filled[idx] ?: continue
            val value = if (useBEDD) beddDay(temp.high, temp.low, latitude, day)
            else max(0.0, (temp.high + temp.low) / 2.0 - baseTemp)
            cumulative += value
            result.add(GddPoint(day, value, cumulative, interpolatedFlags[idx]))
        }
        return result
    }

    private fun beddDay(high: Double, low: Double, latitude: Double?, dayMs: Long): Double {
        val cappedHigh = min(high, beddCap)
        val cappedLow = min(low, beddCap)
        val mean = (cappedHigh + cappedLow) / 2.0
        var heat = max(0.0, mean - baseTemp)
        val range = high - low
        if (range > 13) heat += (range - 13) * 0.25
        return heat * dayLengthFactor(latitude, dayMs)
    }

    private fun dayLengthFactor(latitude: Double?, dayMs: Long): Double {
        val lat = latitude ?: return 1.0
        if (kotlin.math.abs(lat) > 66) return 1.0
        val cal = Calendar.getInstance(timeZone)
        cal.timeInMillis = dayMs
        val n = cal.get(Calendar.DAY_OF_YEAR)
        val decl = 23.45 * sin((360.0 * (284 + n) / 365.0) * Math.PI / 180.0)
        val latRad = lat * Math.PI / 180.0
        val declRad = decl * Math.PI / 180.0
        val cosOmega = -tan(latRad) * tan(declRad)
        val clamped = max(-1.0, min(1.0, cosOmega))
        val omega = acos(clamped) * 180.0 / Math.PI
        val dayLength = 2.0 * omega / 15.0
        return max(0.5, min(1.5, dayLength / 12.0))
    }
}
