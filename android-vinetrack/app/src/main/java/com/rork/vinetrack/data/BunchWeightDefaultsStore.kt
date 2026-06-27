package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/**
 * Per-block default average bunch weight (grams), used to seed yield estimation
 * calculations. Mirrors the iOS `AppSettings.defaultBlockBunchWeightsGrams`
 * dictionary keyed by paddock id.
 *
 * This is on-device-only preference data (no backing table in the shared
 * schema), so it follows the same lightweight local SharedPreferences pattern
 * as [CanopyWaterRatesStore]. Nothing is written to the backend.
 */
class BunchWeightDefaultsStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_bunch_weights", Context.MODE_PRIVATE)

    /** All stored per-block defaults, keyed by paddock id → grams. */
    fun load(): Map<String, Double> {
        return prefs.all.entries.mapNotNull { (key, value) ->
            if (!key.startsWith(KEY_PREFIX)) return@mapNotNull null
            val grams = (value as? Float)?.toDouble() ?: return@mapNotNull null
            key.removePrefix(KEY_PREFIX) to grams
        }.toMap()
    }

    /** Default bunch weight for a single block, or [DEFAULT_BUNCH_WEIGHT_GRAMS] if unset. */
    fun weightGrams(paddockId: String): Double =
        prefs.getFloat(KEY_PREFIX + paddockId, DEFAULT_BUNCH_WEIGHT_GRAMS.toFloat()).toDouble()

    fun setWeightGrams(paddockId: String, grams: Double) {
        if (grams <= 0) return
        prefs.edit { putFloat(KEY_PREFIX + paddockId, grams.toFloat()) }
    }

    companion object {
        const val DEFAULT_BUNCH_WEIGHT_GRAMS = 150.0
        private const val KEY_PREFIX = "bw_"
    }
}
