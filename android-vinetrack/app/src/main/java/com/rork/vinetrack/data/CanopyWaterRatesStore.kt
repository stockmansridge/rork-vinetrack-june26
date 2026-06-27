package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/**
 * VSP canopy water rates — indicative spray water volumes (litres per 100m of
 * row) for each canopy size × density combination. Mirrors the iOS
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

    fun load(): CanopyWaterRates {
        val d = CanopyWaterRates.defaults
        return CanopyWaterRates(
            smallLow = prefs.getFloat(KEY_SMALL_LOW, d.smallLow.toFloat()).toDouble(),
            smallHigh = prefs.getFloat(KEY_SMALL_HIGH, d.smallHigh.toFloat()).toDouble(),
            mediumLow = prefs.getFloat(KEY_MEDIUM_LOW, d.mediumLow.toFloat()).toDouble(),
            mediumHigh = prefs.getFloat(KEY_MEDIUM_HIGH, d.mediumHigh.toFloat()).toDouble(),
            largeLow = prefs.getFloat(KEY_LARGE_LOW, d.largeLow.toFloat()).toDouble(),
            largeHigh = prefs.getFloat(KEY_LARGE_HIGH, d.largeHigh.toFloat()).toDouble(),
            fullLow = prefs.getFloat(KEY_FULL_LOW, d.fullLow.toFloat()).toDouble(),
            fullHigh = prefs.getFloat(KEY_FULL_HIGH, d.fullHigh.toFloat()).toDouble(),
        )
    }

    fun save(rates: CanopyWaterRates) {
        prefs.edit {
            putFloat(KEY_SMALL_LOW, rates.smallLow.toFloat())
            putFloat(KEY_SMALL_HIGH, rates.smallHigh.toFloat())
            putFloat(KEY_MEDIUM_LOW, rates.mediumLow.toFloat())
            putFloat(KEY_MEDIUM_HIGH, rates.mediumHigh.toFloat())
            putFloat(KEY_LARGE_LOW, rates.largeLow.toFloat())
            putFloat(KEY_LARGE_HIGH, rates.largeHigh.toFloat())
            putFloat(KEY_FULL_LOW, rates.fullLow.toFloat())
            putFloat(KEY_FULL_HIGH, rates.fullHigh.toFloat())
        }
    }

    fun reset() {
        prefs.edit { clear() }
    }

    private companion object {
        const val KEY_SMALL_LOW = "small_low"
        const val KEY_SMALL_HIGH = "small_high"
        const val KEY_MEDIUM_LOW = "medium_low"
        const val KEY_MEDIUM_HIGH = "medium_high"
        const val KEY_LARGE_LOW = "large_low"
        const val KEY_LARGE_HIGH = "large_high"
        const val KEY_FULL_LOW = "full_low"
        const val KEY_FULL_HIGH = "full_high"
    }
}
