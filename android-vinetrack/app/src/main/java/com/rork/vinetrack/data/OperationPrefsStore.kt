package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import com.rork.vinetrack.data.model.GrowthStage

/**
 * Device-local operation preferences for trips/spray jobs and seasonal
 * reporting. Never written to the backend, mirroring the lightweight
 * [MapPrefsStore] / [IrrigationPrefsStore] pattern. These mirror the iOS
 * `OperationPreferencesView` settings (season boundaries, E-L confirmation,
 * tank fill timer, fuel cost and yield sampling), all stored on this device
 * only.
 */
data class OperationPrefs(
    val seasonStartMonth: Int = 7,
    val seasonStartDay: Int = 1,
    val elConfirmationEnabled: Boolean = true,
    val fillTimerEnabled: Boolean = false,
    val fuelCostPerLitre: Double = 0.0,
    val samplesPerHectare: Int = 0,
    /** E-L codes enabled for recording and reporting. Defaults to every stage. */
    val enabledGrowthStageCodes: List<String> = GrowthStage.allStages.map { it.code },
) {
    companion object {
        val factory = OperationPrefs()
    }
}

/** Persists [OperationPrefs] locally via SharedPreferences. */
class OperationPrefsStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_operations", Context.MODE_PRIVATE)

    fun load(): OperationPrefs = OperationPrefs(
        seasonStartMonth = prefs.getInt(KEY_SEASON_MONTH, OperationPrefs.factory.seasonStartMonth),
        seasonStartDay = prefs.getInt(KEY_SEASON_DAY, OperationPrefs.factory.seasonStartDay),
        elConfirmationEnabled = prefs.getBoolean(KEY_EL_CONFIRM, OperationPrefs.factory.elConfirmationEnabled),
        fillTimerEnabled = prefs.getBoolean(KEY_FILL_TIMER, OperationPrefs.factory.fillTimerEnabled),
        fuelCostPerLitre = prefs.getFloat(KEY_FUEL_COST, OperationPrefs.factory.fuelCostPerLitre.toFloat()).toDouble(),
        samplesPerHectare = prefs.getInt(KEY_SAMPLES, OperationPrefs.factory.samplesPerHectare),
        enabledGrowthStageCodes = prefs.getString(KEY_ENABLED_STAGES, null)
            ?.split('\u001F')?.filter { it.isNotBlank() }
            ?: OperationPrefs.factory.enabledGrowthStageCodes,
    )

    fun save(value: OperationPrefs) {
        prefs.edit {
            putInt(KEY_SEASON_MONTH, value.seasonStartMonth)
            putInt(KEY_SEASON_DAY, value.seasonStartDay)
            putBoolean(KEY_EL_CONFIRM, value.elConfirmationEnabled)
            putBoolean(KEY_FILL_TIMER, value.fillTimerEnabled)
            putFloat(KEY_FUEL_COST, value.fuelCostPerLitre.toFloat())
            putInt(KEY_SAMPLES, value.samplesPerHectare)
            putString(KEY_ENABLED_STAGES, value.enabledGrowthStageCodes.joinToString("\u001F"))
        }
    }

    fun setFillTimerEnabled(enabled: Boolean) {
        prefs.edit { putBoolean(KEY_FILL_TIMER, enabled) }
    }

    private companion object {
        const val KEY_SEASON_MONTH = "season_start_month"
        const val KEY_SEASON_DAY = "season_start_day"
        const val KEY_EL_CONFIRM = "el_confirmation_enabled"
        const val KEY_FILL_TIMER = "fill_timer_enabled"
        const val KEY_FUEL_COST = "fuel_cost_per_litre"
        const val KEY_SAMPLES = "samples_per_hectare"
        const val KEY_ENABLED_STAGES = "enabled_growth_stage_codes"
    }
}
