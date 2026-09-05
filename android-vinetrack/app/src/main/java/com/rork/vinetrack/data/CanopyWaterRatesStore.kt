package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/**
 * Canopy water rates — indicative spray water volumes (litres per 100m of row)
 * for VSP and Sprawl size × density combinations. Mirrors the iOS
 * `CanopyWaterRateEntry` persisted on `AppSettings.canopyWaterRates`.
 *
 * This is on-device-only preference data (no `canopy_water_rates` table exists
 * in the shared schema), so it follows the same local SharedPreferences pattern
 * as [IrrigationPrefsStore] / [MapPrefsStore]. Nothing is written to the backend.
 */
data class CanopyWaterRates(
    val smallLow: Double = 10.0,
    val smallHigh: Double = 20.0,
    val mediumLow: Double = 20.0,
    val mediumHigh: Double = 40.0,
    val largeLow: Double = 30.0,
    val largeHigh: Double = 45.0,
    val fullLow: Double = 45.0,
    val fullHigh: Double = 75.0,
    val sprawlSmallLow: Double = 10.0,
    val sprawlSmallHigh: Double = 20.0,
    val sprawlMediumLow: Double = 20.0,
    val sprawlMediumHigh: Double = 40.0,
    val sprawlLargeLow: Double = 45.0,
    val sprawlLargeHigh: Double = 60.0,
    val sprawlFullLow: Double = 60.0,
    val sprawlFullHigh: Double = 90.0,
) {
    companion object {
        val defaults = CanopyWaterRates()

        /**
         * Convert a litres-per-100m volume into litres per hectare for a given
         * row spacing. Matches iOS `CanopyWaterRate.litresPerHa`:
         * L/ha = (L per 100m) × 10000 ÷ rowSpacing ÷ 100.
         */
        fun litresPerHa(litresPer100m: Double, rowSpacingMetres: Double): Double {
            if (rowSpacingMetres <= 0) return 0.0
            return litresPer100m * 10000.0 / rowSpacingMetres / 100.0
        }
    }
}

/**
 * Persists [CanopyWaterRates] locally via SharedPreferences, following the same
 * lightweight pattern as [IrrigationPrefsStore].
 */
class CanopyWaterRatesStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_canopy_rates", Context.MODE_PRIVATE)

    fun load(): CanopyWaterRates = CanopyWaterRatePreferences.decode { key, fallback ->
        prefs.getFloat(key, fallback)
    }

    fun save(rates: CanopyWaterRates) {
        prefs.edit {
            CanopyWaterRatePreferences.entries(rates).forEach { (key, value) ->
                putFloat(key, value)
            }
        }
    }

    fun reset() {
        prefs.edit { clear() }
    }

}

/** Pure preference codec so legacy migration is testable without Android runtime. */
object CanopyWaterRatePreferences {
    const val KEY_SMALL_LOW = "small_low"
    const val KEY_SMALL_HIGH = "small_high"
    const val KEY_MEDIUM_LOW = "medium_low"
    const val KEY_MEDIUM_HIGH = "medium_high"
    const val KEY_LARGE_LOW = "large_low"
    const val KEY_LARGE_HIGH = "large_high"
    const val KEY_FULL_LOW = "full_low"
    const val KEY_FULL_HIGH = "full_high"
    const val KEY_SPRAWL_SMALL_LOW = "sprawl_small_low"
    const val KEY_SPRAWL_SMALL_HIGH = "sprawl_small_high"
    const val KEY_SPRAWL_MEDIUM_LOW = "sprawl_medium_low"
    const val KEY_SPRAWL_MEDIUM_HIGH = "sprawl_medium_high"
    const val KEY_SPRAWL_LARGE_LOW = "sprawl_large_low"
    const val KEY_SPRAWL_LARGE_HIGH = "sprawl_large_high"
    const val KEY_SPRAWL_FULL_LOW = "sprawl_full_low"
    const val KEY_SPRAWL_FULL_HIGH = "sprawl_full_high"

    fun decode(readFloat: (String, Float) -> Float): CanopyWaterRates {
        val d = CanopyWaterRates.defaults
        fun value(key: String, fallback: Double): Double =
            readFloat(key, fallback.toFloat()).toDouble().takeIf(Double::isFinite) ?: fallback
        return CanopyWaterRates(
            smallLow = value(KEY_SMALL_LOW, d.smallLow),
            smallHigh = value(KEY_SMALL_HIGH, d.smallHigh),
            mediumLow = value(KEY_MEDIUM_LOW, d.mediumLow),
            mediumHigh = value(KEY_MEDIUM_HIGH, d.mediumHigh),
            largeLow = value(KEY_LARGE_LOW, d.largeLow),
            largeHigh = value(KEY_LARGE_HIGH, d.largeHigh),
            fullLow = value(KEY_FULL_LOW, d.fullLow),
            fullHigh = value(KEY_FULL_HIGH, d.fullHigh),
            sprawlSmallLow = value(KEY_SPRAWL_SMALL_LOW, d.sprawlSmallLow),
            sprawlSmallHigh = value(KEY_SPRAWL_SMALL_HIGH, d.sprawlSmallHigh),
            sprawlMediumLow = value(KEY_SPRAWL_MEDIUM_LOW, d.sprawlMediumLow),
            sprawlMediumHigh = value(KEY_SPRAWL_MEDIUM_HIGH, d.sprawlMediumHigh),
            sprawlLargeLow = value(KEY_SPRAWL_LARGE_LOW, d.sprawlLargeLow),
            sprawlLargeHigh = value(KEY_SPRAWL_LARGE_HIGH, d.sprawlLargeHigh),
            sprawlFullLow = value(KEY_SPRAWL_FULL_LOW, d.sprawlFullLow),
            sprawlFullHigh = value(KEY_SPRAWL_FULL_HIGH, d.sprawlFullHigh),
        )
    }

    fun entries(rates: CanopyWaterRates): Map<String, Float> = linkedMapOf(
        KEY_SMALL_LOW to rates.smallLow.toFloat(),
        KEY_SMALL_HIGH to rates.smallHigh.toFloat(),
        KEY_MEDIUM_LOW to rates.mediumLow.toFloat(),
        KEY_MEDIUM_HIGH to rates.mediumHigh.toFloat(),
        KEY_LARGE_LOW to rates.largeLow.toFloat(),
        KEY_LARGE_HIGH to rates.largeHigh.toFloat(),
        KEY_FULL_LOW to rates.fullLow.toFloat(),
        KEY_FULL_HIGH to rates.fullHigh.toFloat(),
        KEY_SPRAWL_SMALL_LOW to rates.sprawlSmallLow.toFloat(),
        KEY_SPRAWL_SMALL_HIGH to rates.sprawlSmallHigh.toFloat(),
        KEY_SPRAWL_MEDIUM_LOW to rates.sprawlMediumLow.toFloat(),
        KEY_SPRAWL_MEDIUM_HIGH to rates.sprawlMediumHigh.toFloat(),
        KEY_SPRAWL_LARGE_LOW to rates.sprawlLargeLow.toFloat(),
        KEY_SPRAWL_LARGE_HIGH to rates.sprawlLargeHigh.toFloat(),
        KEY_SPRAWL_FULL_LOW to rates.sprawlFullLow.toFloat(),
        KEY_SPRAWL_FULL_HIGH to rates.sprawlFullHigh.toFloat(),
    )
}
