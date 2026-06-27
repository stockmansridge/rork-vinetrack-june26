package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/**
 * Growing-degree-day calculation mode. Mirrors the iOS `GDDCalculationMode`:
 * plain GDD (base 10°C) versus BEDD (caps daily temps at 19°C, adds a
 * diurnal-range bonus and applies a latitude day-length factor).
 */
enum class GddCalculationMode(val storageKey: String, val displayName: String, val shortName: String) {
    GDD("gdd", "Standard GDD", "GDD"),
    BEDD("bedd", "BEDD", "BEDD");

    val useBEDD: Boolean get() = this == BEDD

    companion object {
        fun fromKey(key: String?): GddCalculationMode =
            entries.firstOrNull { it.storageKey == key } ?: BEDD
    }
}

/**
 * Point in the season where degree-day accumulation restarts. Mirrors the iOS
 * `GDDResetMode`. When a phenology date for the chosen stage is set on a block
 * it is used as the reset date; otherwise the season start is used.
 */
enum class GddResetMode(val storageKey: String, val displayName: String) {
    SEASON_START("seasonStart", "Season Start"),
    BUDBURST("budburst", "Budburst"),
    FLOWERING("flowering", "Flowering"),
    VERAISON("veraison", "Veraison");

    companion object {
        fun fromKey(key: String?): GddResetMode =
            entries.firstOrNull { it.storageKey == key } ?: BUDBURST
    }
}

/**
 * On-device GDD calculation preferences (calculation mode + reset point).
 * Mirrors the iOS `AppSettings.calculationMode` / `resetMode`, persisted with
 * the same lightweight SharedPreferences pattern as [OperationPrefsStore] /
 * [IrrigationPrefsStore]. Nothing is written to the backend.
 */
data class GddSettings(
    val calculationMode: GddCalculationMode = GddCalculationMode.BEDD,
    val resetMode: GddResetMode = GddResetMode.BUDBURST,
)

/** Persists [GddSettings] locally via SharedPreferences. */
class GddSettingsStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_gdd_settings", Context.MODE_PRIVATE)

    fun load(): GddSettings = GddSettings(
        calculationMode = GddCalculationMode.fromKey(prefs.getString(KEY_MODE, null)),
        resetMode = GddResetMode.fromKey(prefs.getString(KEY_RESET, null)),
    )

    fun save(value: GddSettings) {
        prefs.edit {
            putString(KEY_MODE, value.calculationMode.storageKey)
            putString(KEY_RESET, value.resetMode.storageKey)
        }
    }

    private companion object {
        const val KEY_MODE = "calculation_mode"
        const val KEY_RESET = "reset_mode"
    }
}
