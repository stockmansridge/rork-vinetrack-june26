package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Per-vineyard alert & notification preferences, mirroring the iOS
 * `BackendAlertPreferences`. Backs the `alert_preferences` table (one row per
 * vineyard, keyed by `vineyard_id`). The same row drives the iOS app and the
 * web portal, so editing here keeps all platforms in sync.
 */
@Serializable
data class AlertPreferences(
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("irrigation_alerts_enabled") val irrigationAlertsEnabled: Boolean = true,
    @SerialName("irrigation_forecast_days") val irrigationForecastDays: Int = 5,
    @SerialName("irrigation_deficit_threshold_mm") val irrigationDeficitThresholdMm: Double = 8.0,
    @SerialName("aged_pin_alerts_enabled") val agedPinAlertsEnabled: Boolean = true,
    @SerialName("aged_pin_days") val agedPinDays: Int = 14,
    @SerialName("weather_alerts_enabled") val weatherAlertsEnabled: Boolean = true,
    @SerialName("rain_alert_threshold_mm") val rainAlertThresholdMm: Double = 5.0,
    @SerialName("wind_alert_threshold_kmh") val windAlertThresholdKmh: Double = 25.0,
    @SerialName("frost_alert_threshold_c") val frostAlertThresholdC: Double = 1.0,
    @SerialName("heat_alert_threshold_c") val heatAlertThresholdC: Double = 35.0,
    @SerialName("spray_job_reminders_enabled") val sprayJobRemindersEnabled: Boolean = true,
    @SerialName("push_enabled") val pushEnabled: Boolean = false,
    @SerialName("disease_alerts_enabled") val diseaseAlertsEnabled: Boolean = true,
    @SerialName("disease_downy_enabled") val diseaseDownyEnabled: Boolean = true,
    @SerialName("disease_powdery_enabled") val diseasePowderyEnabled: Boolean = true,
    @SerialName("disease_botrytis_enabled") val diseaseBotrytisEnabled: Boolean = true,
    @SerialName("disease_use_measured_wetness") val diseaseUseMeasuredWetness: Boolean = false,
) {
    companion object {
        /** Server defaults, matching the iOS `BackendAlertPreferences.defaults`. */
        fun defaults(vineyardId: String): AlertPreferences = AlertPreferences(vineyardId = vineyardId)
    }
}
