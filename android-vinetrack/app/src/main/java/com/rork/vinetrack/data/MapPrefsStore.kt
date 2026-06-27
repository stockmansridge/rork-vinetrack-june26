package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/** Map imagery style for the vineyard overview map. */
enum class MapStyle(val label: String) {
    Hybrid("Hybrid"),
    Satellite("Satellite"),
    Normal("Standard"),
    Terrain("Terrain"),
}

/**
 * Saved map display defaults for the vineyard overview map. On-device only —
 * never written to the backend. Mirrors the lightweight pattern used by
 * [IrrigationPrefsStore].
 */
data class MapDefaults(
    val style: MapStyle = MapStyle.Hybrid,
    val overview3D: Boolean = false,
    val showPins: Boolean = true,
    val showRowLines: Boolean = true,
    val showBlockLabels: Boolean = true,
) {
    companion object {
        val factory = MapDefaults()
    }
}

/**
 * Persists vineyard map defaults locally via SharedPreferences, following the
 * same lightweight pattern as [IrrigationPrefsStore].
 */
class MapPrefsStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_map", Context.MODE_PRIVATE)

    fun load(): MapDefaults {
        val d = MapDefaults.factory
        val styleName = prefs.getString(KEY_STYLE, d.style.name) ?: d.style.name
        val style = runCatching { MapStyle.valueOf(styleName) }.getOrDefault(d.style)
        return MapDefaults(
            style = style,
            overview3D = prefs.getBoolean(KEY_3D, d.overview3D),
            showPins = prefs.getBoolean(KEY_PINS, d.showPins),
            showRowLines = prefs.getBoolean(KEY_ROWS, d.showRowLines),
            showBlockLabels = prefs.getBoolean(KEY_LABELS, d.showBlockLabels),
        )
    }

    fun save(defaults: MapDefaults) {
        prefs.edit {
            putString(KEY_STYLE, defaults.style.name)
            putBoolean(KEY_3D, defaults.overview3D)
            putBoolean(KEY_PINS, defaults.showPins)
            putBoolean(KEY_ROWS, defaults.showRowLines)
            putBoolean(KEY_LABELS, defaults.showBlockLabels)
        }
    }

    fun reset() {
        prefs.edit { clear() }
    }

    private companion object {
        const val KEY_STYLE = "style"
        const val KEY_3D = "overview_3d"
        const val KEY_PINS = "show_pins"
        const val KEY_ROWS = "show_row_lines"
        const val KEY_LABELS = "show_block_labels"
    }
}
