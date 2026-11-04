package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.ForecastDay
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** Forecast bundle returned to the Irrigation Advisor. Always identify the actual source. */
data class IrrigationForecast(
    val days: List<ForecastDay>,
    val source: String,
    val fallbackReason: String? = null,
)

/** Mirrors the iOS configured-provider / auto-with-WillyWeather-location selection. */
internal fun shouldUseWillyWeather(provider: String, configuredLocation: Boolean): Boolean =
    when (provider.lowercase(Locale.US)) {
        "willyweather" -> true
        "auto" -> configuredLocation
        else -> false
    }

/** Parse daily dates in the forecast provider's vineyard timezone, never the device timezone. */
internal fun irrigationForecastDateMillis(date: String, timezone: String?): Long? =
    SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
        isLenient = false
        timeZone = TimeZone.getTimeZone(timezone?.takeIf { it.isNotBlank() } ?: "UTC")
    }.parse(date)?.time

/** Identical ETo/rain mapping to iOS WillyWeatherForecastDay.asForecastDay(). */
internal fun WillyWeatherForecastResult.asIrrigationForecast(maxDays: Int = 5): IrrigationForecast =
    IrrigationForecast(
        days = days.take(maxDays.coerceIn(1, 7)).mapNotNull { day ->
            irrigationForecastDateMillis(day.date, timezone)?.let { epoch ->
                ForecastDay(
                    dateEpochMs = epoch,
                    forecastEToMm = day.et0Mm ?: 0.0,
                    forecastRainMm = day.rainMm ?: 0.0,
                )
            }
        },
        source = source.ifBlank { "WillyWeather" },
    )

/**
 * Resolve the shared vineyard's provider exactly as the iOS IrrigationForecastService does:
 * WillyWeather when selected, or auto with a configured WillyWeather location; otherwise
 * use Open-Meteo. A provider outage falls back transparently without writing any data.
 */
class IrrigationForecastRepository(
    private val willyWeather: WillyWeatherRepository? = null,
    private val integrations: VineyardWeatherIntegrationRepository? = null,
) {
    suspend fun fetchForecast(
        latitude: Double,
        longitude: Double,
        vineyardId: String? = null,
    ): IrrigationForecast {
        var fallbackReason: String? = null
        if (vineyardId != null && willyWeather != null) {
            val provider = try {
                willyWeather.getProviderPreference(vineyardId)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // Like iOS, failure to load preference must not block a usable forecast.
                "auto"
            }
            val configuredLocation = if (provider == "auto" && integrations != null) {
                try {
                    integrations.fetch(vineyardId, WeatherIntegrationProvider.WILLY_WEATHER)
                        ?.let { it.isActive && !it.stationId.isNullOrBlank() } == true
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    false
                }
            } else {
                false
            }
            if (shouldUseWillyWeather(provider, configuredLocation)) {
                try {
                    val result = willyWeather.fetchForecast(vineyardId, days = 5)
                        .asIrrigationForecast(maxDays = 5)
                    if (result.days.isNotEmpty()) return result
                    fallbackReason = "WillyWeather returned no forecast days; showing Open-Meteo."
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    fallbackReason = "WillyWeather is unavailable; showing Open-Meteo."
                }
            }
        }

        return fetchOpenMeteo(latitude, longitude).copy(fallbackReason = fallbackReason)
    }

    private suspend fun fetchOpenMeteo(latitude: Double, longitude: Double): IrrigationForecast {
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
        val timezone = root["timezone"]?.jsonPrimitive?.content

        val count = minOf(times.size, etoValues.size, rainValues.size)
        val days = mutableListOf<ForecastDay>()
        for (i in 0 until count) {
            val dateString = times[i].jsonPrimitive.content
            val dateEpochMs = irrigationForecastDateMillis(dateString, timezone) ?: continue
            val eto = parseDouble(etoValues, i)
            val rain = parseDouble(rainValues, i)
            days.add(ForecastDay(dateEpochMs = dateEpochMs, forecastEToMm = eto, forecastRainMm = rain))
        }

        return IrrigationForecast(days = days, source = "Open-Meteo")
    }

    private fun parseDouble(array: JsonArray, index: Int): Double = try {
        array[index].jsonPrimitive.double
    } catch (_: Exception) {
        0.0
    }
}
