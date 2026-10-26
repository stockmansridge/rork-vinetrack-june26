package com.rork.vinetrack.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.text.NumberFormat

/** Read-only extras: never a primary observation, rainfall or irrigation input. */
@Serializable
data class MAITSupplementarySensors(
    val success: Boolean? = null,
    val partial: Boolean = false,
    val modules: List<Module> = emptyList(),
) {
    val warning: String? get() = WARNING.takeIf { partial || success == false || modules.any { it.partial || it.status == "error" } }

    @Serializable
    data class Module(
        @SerialName("friendly_name") val friendlyName: String? = null,
        @SerialName("display_name") val displayName: String? = null,
        val name: String? = null,
        @SerialName("observed_at") val observedAt: String? = null,
        val status: String = "no_data",
        val partial: Boolean = false,
        val readings: List<Reading> = emptyList(),
    ) {
        val title: String get() = friendlyName ?: displayName ?: name ?: "MAIT sensor"
        val statusLabel: String get() = when (status) {
            "ok" -> "Observed"
            "no_data" -> "No recent data"
            else -> "Sensor data unavailable"
        }
        val visibleReadings: List<Reading> get() = if (status == "ok") readings.filter { it.displayValue != null } else emptyList()
    }

    @Serializable
    data class Reading(
        @SerialName("canonical_metric") val canonicalMetric: String,
        @SerialName("channel_key") val channelKey: String? = null,
        @SerialName("channel_number") val channelNumber: Int? = null,
        @SerialName("source_label") val sourceLabel: String? = null,
        @SerialName("source_unit") val sourceUnit: String? = null,
        val value: Double? = null,
    ) {
        val title: String get() = sourceLabel?.takeIf { it.isNotBlank() } ?: when (canonicalMetric) {
            "soil_moisture" -> "Soil moisture"
            "soil_temperature" -> "Soil temperature"
            "leaf_wetness" -> "Leaf wetness"
            else -> canonicalMetric.replace('_', ' ')
        }
        val displayValue: String? get() {
            val normalized = value?.takeIf { it.isFinite() } ?: return null
            val unit = if (canonicalMetric == "soil_temperature") "°C" else sourceUnit.orEmpty().trim()
            val number = NumberFormat.getNumberInstance().apply { maximumFractionDigits = 2; minimumFractionDigits = 0 }.format(normalized)
            // No raw-value conversion or inferred percentage/wetness semantics.
            return number + if (unit.isEmpty()) "" else " $unit"
        }
    }

    companion object {
        const val WARNING = "Some MAIT sensor data may be incomplete. Primary weather is unaffected."
    }
}
