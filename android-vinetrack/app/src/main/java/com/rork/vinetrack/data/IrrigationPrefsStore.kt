package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/**
 * Saved irrigation agronomy defaults. Mirrors the iOS persisted fields
 * (`irrigationKc`, `irrigationEfficiencyPercent`,
 * `irrigationRainfallEffectivenessPercent`, `irrigationReplacementPercent`,
 * `irrigationSoilBufferMm`). On-device only — never written to the backend.
 */
data class IrrigationDefaults(
    val cropCoefficientKc: Double = 0.65,
    val irrigationEfficiencyPercent: Double = 90.0,
    val rainfallEffectivenessPercent: Double = 80.0,
    val replacementPercent: Double = 100.0,
    val soilMoistureBufferMm: Double = 0.0,
) {
    companion object {
        val factory = IrrigationDefaults()
    }
}

/**
 * Persists irrigation calculator defaults locally via SharedPreferences,
 * following the same lightweight pattern as [com.rork.vinetrack.data.auth.SessionStore].
 */
class IrrigationPrefsStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_irrigation", Context.MODE_PRIVATE)

    fun load(): IrrigationDefaults {
        val d = IrrigationDefaults.factory
        return IrrigationDefaults(
            cropCoefficientKc = prefs.getFloat(KEY_KC, d.cropCoefficientKc.toFloat()).toDouble(),
            irrigationEfficiencyPercent = prefs.getFloat(KEY_EFFICIENCY, d.irrigationEfficiencyPercent.toFloat()).toDouble(),
            rainfallEffectivenessPercent = prefs.getFloat(KEY_RAIN_EFF, d.rainfallEffectivenessPercent.toFloat()).toDouble(),
            replacementPercent = prefs.getFloat(KEY_REPLACEMENT, d.replacementPercent.toFloat()).toDouble(),
            soilMoistureBufferMm = prefs.getFloat(KEY_BUFFER, d.soilMoistureBufferMm.toFloat()).toDouble(),
        )
    }

    fun save(defaults: IrrigationDefaults) {
        prefs.edit {
            putFloat(KEY_KC, defaults.cropCoefficientKc.toFloat())
            putFloat(KEY_EFFICIENCY, defaults.irrigationEfficiencyPercent.toFloat())
            putFloat(KEY_RAIN_EFF, defaults.rainfallEffectivenessPercent.toFloat())
            putFloat(KEY_REPLACEMENT, defaults.replacementPercent.toFloat())
            putFloat(KEY_BUFFER, defaults.soilMoistureBufferMm.toFloat())
        }
    }

    fun reset() {
        prefs.edit { clear() }
    }

    private companion object {
        const val KEY_KC = "kc"
        const val KEY_EFFICIENCY = "efficiency_percent"
        const val KEY_RAIN_EFF = "rain_effectiveness_percent"
        const val KEY_REPLACEMENT = "replacement_percent"
        const val KEY_BUFFER = "soil_buffer_mm"
    }
}
