package com.rork.vinetrack.data

import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.double
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * A single hourly weather observation/forecast used by the disease risk models.
 *
 * The wetness signal is deliberately an *estimated proxy* — Open-Meteo does not
 * supply measured leaf wetness. We estimate it from rainfall, relative humidity
 * and the temperature/dew-point spread, exactly mirroring the iOS `WeatherHour`.
 */
data class WeatherHour(
    val epochMs: Long,
    val temperatureC: Double,
    val dewPointC: Double?,
    val humidityPercent: Double?,
    val precipitationMm: Double,
) {
    /**
     * `true` when the hour is considered wet, using the estimated proxy:
     * rain > 0 mm OR RH >= 90% OR (T - dewPoint) <= 2°C.
     */
    val isWetHour: Boolean
        get() {
            if (precipitationMm > 0) return true
            val h = humidityPercent
            if (h != null && h >= 90) return true
            val dp = dewPointC
            if (dp != null && (temperatureC - dp) <= 2) return true
            return false
        }
}

/** Hourly forecast bundle returned to the UI. */
data class HourlyForecast(
    val hours: List<WeatherHour>,
    val source: String,
)

/**
 * Fetches hourly weather (temperature, dew point, RH, precipitation) used for
 * disease-risk modelling. Uses the free Open-Meteo API today, mirroring the iOS
 * `WeatherHourlyService` request (`past_days=3`, `forecast_days=5`). No API key
 * is required and nothing is persisted.
 */
class WeatherHourlyRepository {

    suspend fun fetch(
        latitude: Double,
        longitude: Double,
        pastDays: Int = 3,
        forecastDays: Int = 5,
    ): HourlyForecast {
        val past = pastDays.coerceIn(0, 5)
        val ahead = forecastDays.coerceIn(1, 7)
        val url = "https://api.open-meteo.com/v1/forecast" +
            "?latitude=$latitude&longitude=$longitude" +
            "&hourly=temperature_2m,dew_point_2m,relative_humidity_2m,precipitation" +
            "&past_days=$past&forecast_days=$ahead&timezone=auto"

        val response = SupabaseClient.http.get(url)
        if (!response.status.isSuccess()) {
            throw IllegalStateException("Failed to fetch hourly forecast (HTTP ${response.status.value}).")
        }

        val root = SupabaseClient.json.parseToJsonElement(response.bodyAsText()).jsonObject
        val hourly = root["hourly"]?.jsonObject
            ?: throw IllegalStateException("Hourly forecast response could not be parsed.")
        val times = hourly["time"]?.jsonArray
            ?: throw IllegalStateException("Hourly forecast response could not be parsed.")
        val temps = hourly["temperature_2m"]?.jsonArray
            ?: throw IllegalStateException("Hourly forecast response could not be parsed.")
        val dews = hourly["dew_point_2m"]?.jsonArray
        val rhs = hourly["relative_humidity_2m"]?.jsonArray
        val precs = hourly["precipitation"]?.jsonArray

        // Open-Meteo returns local "yyyy-MM-dd'T'HH:mm" without a timezone suffix.
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm", Locale.US).apply {
            timeZone = TimeZone.getDefault()
        }

        val count = minOf(times.size, temps.size)
        val hours = mutableListOf<WeatherHour>()
        for (i in 0 until count) {
            val timeString = times[i].jsonPrimitive.content
            val date = formatter.parse(timeString) ?: continue
            val t = parseDoubleOrNull(temps, i) ?: continue
            hours.add(
                WeatherHour(
                    epochMs = date.time,
                    temperatureC = t,
                    dewPointC = parseDoubleOrNull(dews, i),
                    humidityPercent = parseDoubleOrNull(rhs, i),
                    precipitationMm = parseDoubleOrNull(precs, i) ?: 0.0,
                )
            )
        }

        return HourlyForecast(hours = hours, source = "Open-Meteo")
    }

    private fun parseDoubleOrNull(array: JsonArray?, index: Int): Double? {
        if (array == null || index >= array.size) return null
        return try {
            array[index].jsonPrimitive.doubleOrNull ?: array[index].jsonPrimitive.double
        } catch (e: Exception) {
            null
        }
    }
}
