package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.ForecastDay
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** Forecast bundle returned to the UI. */
data class IrrigationForecast(
    val days: List<ForecastDay>,
    val source: String,
)

/**
 * Fetches a 5-day ETo + rainfall forecast from the free Open-Meteo API, exactly
 * matching the iOS `IrrigationForecastService` request. No API key required and
 * no data is persisted — this drives the local irrigation calculator only.
 */
class IrrigationForecastRepository {

    suspend fun fetchForecast(latitude: Double, longitude: Double): IrrigationForecast {
        val url = "https://api.open-meteo.com/v1/forecast" +
            "?latitude=$latitude&longitude=$longitude" +
            "&daily=et0_fao_evapotranspiration,precipitation_sum" +
            "&forecast_days=5&timezone=auto"

        val response = SupabaseClient.http.get(url)
        if (!response.status.isSuccess()) {
            throw IllegalStateException("Failed to fetch forecast (HTTP ${response.status.value}).")
        }

        val root = SupabaseClient.json.parseToJsonElement(response.bodyAsText()).jsonObject
        val daily = root["daily"]?.jsonObject ?: throw IllegalStateException("Forecast response could not be parsed.")
        val times = daily["time"]?.jsonArray ?: throw IllegalStateException("Forecast response could not be parsed.")
        val etoValues = daily["et0_fao_evapotranspiration"]?.jsonArray ?: throw IllegalStateException("Forecast response could not be parsed.")
        val rainValues = daily["precipitation_sum"]?.jsonArray ?: throw IllegalStateException("Forecast response could not be parsed.")

        val formatter = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
            timeZone = TimeZone.getDefault()
        }

        val count = minOf(times.size, etoValues.size, rainValues.size)
        val days = mutableListOf<ForecastDay>()
        for (i in 0 until count) {
            val dateString = times[i].jsonPrimitive.content
            val date = formatter.parse(dateString) ?: continue
            val eto = parseDouble(etoValues, i)
            val rain = parseDouble(rainValues, i)
            days.add(ForecastDay(dateEpochMs = date.time, forecastEToMm = eto, forecastRainMm = rain))
        }

        return IrrigationForecast(days = days, source = "Open-Meteo")
    }

    private fun parseDouble(array: JsonArray, index: Int): Double {
        return try {
            array[index].jsonPrimitive.double
        } catch (e: Exception) {
            0.0
        }
    }
}
