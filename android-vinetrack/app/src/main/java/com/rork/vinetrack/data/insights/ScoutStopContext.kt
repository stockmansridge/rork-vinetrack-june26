package com.rork.vinetrack.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Capture-time evidence for one stop. Null on legacy assessments; never infer historical conditions. */
@Serializable
data class ScoutStopContext(
    @SerialName("captured_at") val capturedAt: String,
    @SerialName("observer_id") val observerId: String? = null,
    @SerialName("observer_name") val observerName: String? = null,
    @SerialName("is_draft") val isDraft: Boolean = true,
    val latitude: Double? = null,
    val longitude: Double? = null,
    @SerialName("accuracy_metres") val accuracyMetres: Double? = null,
    @SerialName("location_measured_at") val locationMeasuredAt: String? = null,
    val weather: VineyardInsightsSyncApi.WeatherPayload? = null,
) {
    val weatherSnapshot: ScoutWeatherSnapshot? get() = weather?.let {
        ScoutWeatherSnapshot(it.observedAt, it.capturedAt, it.source, it.temperatureC, it.humidityPct,
            it.windKph, it.gustKph, it.recentRainfallMm, it.isStale, it.isUnavailable)
    }
    fun withWeather(value: ScoutWeatherSnapshot): ScoutStopContext = copy(weather =
        VineyardInsightsSyncApi.WeatherPayload(value.observedAtIso, value.capturedAtIso, value.source,
            value.temperatureCelsius, value.humidityPercent, value.windSpeedKph, value.windGustKph,
            value.recentRainfallMm, value.isStale, value.isUnavailable))
}
