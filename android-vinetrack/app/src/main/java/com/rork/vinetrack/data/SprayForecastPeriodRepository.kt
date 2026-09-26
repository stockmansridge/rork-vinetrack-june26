package com.rork.vinetrack.data

import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/** Converts actual provider samples to four-hour metric periods, preserving missing measurements. */
object SprayForecastPeriodRepository {
    private data class Sample(val date: String, val hour: Int, val temp: Double? = null,
                              val wind: Double? = null, val humidity: Double? = null, val rain: Double? = null)

    private fun aggregate(samples: List<Sample>): List<SprayForecastPeriod> =
        samples.groupBy { it.date to it.hour }.map { (key, rows) ->
            val rains = rows.mapNotNull { it.rain }
            SprayForecastPeriod(date = key.first, startHour = key.second,
                tempMinC = rows.mapNotNull { it.temp }.minOrNull(),
                tempMaxC = rows.mapNotNull { it.temp }.maxOrNull(),
                windMaxKmh = rows.mapNotNull { it.wind }.maxOrNull(),
                humidityMinPct = rows.mapNotNull { it.humidity }.minOrNull(),
                humidityMaxPct = rows.mapNotNull { it.humidity }.maxOrNull(),
                rainMm = if (rains.isEmpty()) null else rains.sum(), sampleCount = rows.size)
        }.sortedWith(compareBy({ it.date }, { it.startHour }))

    fun willyWeather(days: List<WillyWeatherForecastDay>, timezone: TimeZone): List<SprayForecastPeriod> {
        val dateFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = timezone }
        val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US)
        val samples = mutableListOf<Sample>()
        days.forEach { day ->
            listOf(
                day.temperatureEntries to "temperature", day.windEntries to "speed",
                day.humidityEntries to "humidity", day.rainfallEntries to "rainMaxMm",
            ).forEach { (entries, field) ->
                entries.forEach { entry ->
                    val instant = runCatching { timestamp.parse(entry.dateTime) }.getOrNull() ?: return@forEach
                    val hour = Calendar.getInstance(timezone).apply { time = instant }.get(Calendar.HOUR_OF_DAY) / 4 * 4
                    val value = entry.value(field)
                    samples.add(Sample(dateFormat.format(instant), hour,
                        temp = if (field == "temperature") value else null,
                        wind = if (field == "speed") value else null,
                        humidity = if (field == "humidity") value else null,
                        rain = if (field == "rainMaxMm") value else null))
                }
            }
        }
        return aggregate(samples)
    }

    fun openMeteo(body: String): Pair<TimeZone, List<SprayForecastPeriod>> {
        val root = SupabaseClient.json.parseToJsonElement(body).jsonObject
        val zone = TimeZone.getTimeZone(root["timezone"]?.jsonPrimitive?.contentOrNull ?: "UTC")
        val hourly = root["hourly"]?.jsonObject ?: return zone to emptyList()
        val times = hourly["time"]?.jsonArray ?: return zone to emptyList()
        val parser = SimpleDateFormat("yyyy-MM-dd'T'HH:mm", Locale.US).apply { timeZone = zone; isLenient = false }
        val dateFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = zone }
        fun value(field: String, index: Int): Double? = (hourly[field] as? JsonArray)?.getOrNull(index)?.jsonPrimitive?.doubleOrNull
        val samples = times.mapIndexedNotNull { index, item ->
            val date = parser.parse(item.jsonPrimitive.contentOrNull ?: "") ?: return@mapIndexedNotNull null
            val hour = Calendar.getInstance(zone).apply { time = date }.get(Calendar.HOUR_OF_DAY) / 4 * 4
            Sample(dateFormat.format(date), hour, value("temperature_2m", index), value("wind_speed_10m", index),
                value("relative_humidity_2m", index), value("precipitation", index))
        }
        return zone to aggregate(samples)
    }

    suspend fun fetchOpenMeteo(latitude: Double, longitude: Double): Pair<TimeZone, List<SprayForecastPeriod>> {
        val url = "https://api.open-meteo.com/v1/forecast?latitude=$latitude&longitude=$longitude" +
            "&hourly=temperature_2m,wind_speed_10m,relative_humidity_2m,precipitation&forecast_days=5&timezone=auto&wind_speed_unit=kmh&precipitation_unit=mm"
        val response = SupabaseClient.http.get(url)
        if (!response.status.isSuccess()) return TimeZone.getTimeZone("UTC") to emptyList()
        return openMeteo(response.bodyAsText())
    }
}
