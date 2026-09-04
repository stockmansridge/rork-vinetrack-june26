package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin
import java.util.Locale

/**
 * Stable duplicate-warning identity for a launcher pin. Spatial fields, colour,
 * launcher position and E-L observation details deliberately do not participate.
 */
data class PinTypeKey(
    val mode: String,
    val logicalType: String,
) {
    override fun toString(): String = "$mode|$logicalType"

    companion object {
        const val GROWTH_STAGE_LOGICAL_TYPE: String = "growth stage"

        fun candidate(mode: String, logicalType: String): PinTypeKey = PinTypeKey(
            mode = normalize(mode),
            logicalType = normalizeLogicalType(logicalType),
        )

        /** Resolve legacy records in persisted-field priority order. */
        fun existing(pin: Pin): PinTypeKey? {
            val type = sequenceOf(pin.buttonName, pin.title, pin.category)
                .mapNotNull { it?.takeIf(String::isNotBlank) }
                .firstOrNull()
                ?: pin.displayTitle.takeIf {
                    it.isNotBlank() &&
                        !it.equals("Pin", ignoreCase = true) &&
                        !it.equals(pin.mode, ignoreCase = true)
                }
                ?: return null
            val mode = pin.mode?.takeIf(String::isNotBlank) ?: return null
            return candidate(mode = mode, logicalType = type)
        }

        fun normalize(value: String): String = value
            .trim()
            .split(Regex("\\s+"))
            .filter(String::isNotEmpty)
            .joinToString(" ")
            .lowercase(Locale.ROOT)

        fun normalizeLogicalType(value: String): String {
            val normalized = normalize(value)
            return if (
                normalized == GROWTH_STAGE_LOGICAL_TYPE ||
                normalized.startsWith("$GROWTH_STAGE_LOGICAL_TYPE ")
            ) {
                GROWTH_STAGE_LOGICAL_TYPE
            } else {
                normalized
            }
        }
    }
}
