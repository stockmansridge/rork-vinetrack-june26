package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import com.rork.vinetrack.data.model.GrowthStage

/**
 * Device-local operation preferences for trips/spray jobs and reporting.
 * Never written to the backend, mirroring the lightweight [MapPrefsStore] /
 * [IrrigationPrefsStore] pattern. These mirror the iOS
 * `OperationPreferencesView` device-local settings (E-L confirmation, tank
 * fill timer, fuel cost and yield sampling).
 *
 * NOTE: the season start (month/day) is NOT here any more — it is a shared
 * vineyard setting on `public.vineyards` (sql/108), surfaced via
 * `AppUiState.seasonStartMonth/-Day`. This store only keeps the per-vineyard
 * offline cache of the last synced value (see [loadSeason]/[saveSeason]).
 */
data class OperationPrefs(
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

    // MARK: - Shared season start (vineyard-scoped offline cache, sql/108)

    /**
     * Last successfully synced shared season start for [vineyardId], or null
     * when this device has never synced that vineyard's setting. Used for
     * offline launches; the backend value is authoritative.
     */
    fun loadSeason(vineyardId: String): Pair<Int, Int>? {
        val month = prefs.getInt("$KEY_SEASON_MONTH_V$vineyardId", -1)
        val day = prefs.getInt("$KEY_SEASON_DAY_V$vineyardId", -1)
        return if (month in 1..12 && day in 1..31) month to day else null
    }

    /** Caches the confirmed shared season start for [vineyardId]. */
    fun saveSeason(vineyardId: String, month: Int, day: Int) {
        prefs.edit {
            putInt("$KEY_SEASON_MONTH_V$vineyardId", month)
            putInt("$KEY_SEASON_DAY_V$vineyardId", day)
        }
    }

    /**
     * The legacy device-global season start written by older app versions
     * (one value for every vineyard). Null when this device never stored one.
     * Only used for the one-time local→shared reconciliation prompt.
     */
    fun legacySeason(): Pair<Int, Int>? {
        if (!prefs.contains(KEY_SEASON_MONTH) || !prefs.contains(KEY_SEASON_DAY)) return null
        val month = prefs.getInt(KEY_SEASON_MONTH, 7)
        val day = prefs.getInt(KEY_SEASON_DAY, 1)
        return if (month in 1..12 && day in 1..31) month to day else null
    }

    /** Whether the local-vs-shared reconciliation was already resolved for [vineyardId]. */
    fun isSeasonMigrationDecided(vineyardId: String): Boolean =
        prefs.getBoolean("$KEY_SEASON_MIGRATED$vineyardId", false)

    /** Records that the reconciliation decision was made for [vineyardId]. */
    fun setSeasonMigrationDecided(vineyardId: String) {
        prefs.edit { putBoolean("$KEY_SEASON_MIGRATED$vineyardId", true) }
    }

    private companion object {
        const val KEY_SEASON_MONTH = "season_start_month"
        const val KEY_SEASON_DAY = "season_start_day"
        const val KEY_SEASON_MONTH_V = "season_start_month_"
        const val KEY_SEASON_DAY_V = "season_start_day_"
        const val KEY_SEASON_MIGRATED = "season_migration_decided_"
        const val KEY_EL_CONFIRM = "el_confirmation_enabled"
        const val KEY_FILL_TIMER = "fill_timer_enabled"
        const val KEY_FUEL_COST = "fuel_cost_per_litre"
        const val KEY_SAMPLES = "samples_per_hectare"
        const val KEY_ENABLED_STAGES = "enabled_growth_stage_codes"
    }
}
