package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.TimeZone

/** App-wide display theme, mirroring the iOS `AppAppearance` enum. */
enum class DisplayMode(val label: String) {
    System("System"),
    Light("Light"),
    Dark("Dark");

    companion object {
        fun fromKey(key: String?): DisplayMode = entries.firstOrNull { it.name == key } ?: System
    }
}

/**
 * Device-local app preferences mirroring the iOS `PreferencesHubView`
 * (appearance, in-field trip/row tracking, auto photo prompt, AI suggestions
 * and timezone). Stored on this device only, following the lightweight
 * [OperationPrefsStore] / [MapPrefsStore] pattern.
 */
data class AppPreferences(
    val displayMode: DisplayMode = DisplayMode.System,
    val rowTrackingEnabled: Boolean = true,
    val rowTrackingInterval: Double = 1.0,
    val autoPhotoPrompt: Boolean = false,
    val aiSuggestionsEnabled: Boolean = true,
    val keepScreenAwake: Boolean = true,
    val timezone: String = TimeZone.getDefault().id,
) {
    companion object {
        val factory = AppPreferences()
    }
}

/** Persists [AppPreferences] locally via SharedPreferences. */
class AppPreferencesStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_app_prefs", Context.MODE_PRIVATE)

    fun load(): AppPreferences = AppPreferences(
        displayMode = DisplayMode.fromKey(prefs.getString(KEY_DISPLAY_MODE, null)),
        rowTrackingEnabled = prefs.getBoolean(KEY_ROW_TRACKING, AppPreferences.factory.rowTrackingEnabled),
        rowTrackingInterval = prefs.getFloat(KEY_ROW_INTERVAL, AppPreferences.factory.rowTrackingInterval.toFloat()).toDouble(),
        autoPhotoPrompt = prefs.getBoolean(KEY_AUTO_PHOTO, AppPreferences.factory.autoPhotoPrompt),
        aiSuggestionsEnabled = prefs.getBoolean(KEY_AI, AppPreferences.factory.aiSuggestionsEnabled),
        keepScreenAwake = prefs.getBoolean(KEY_AWAKE, AppPreferences.factory.keepScreenAwake),
        timezone = prefs.getString(KEY_TZ, null) ?: AppPreferences.factory.timezone,
    )

    fun save(value: AppPreferences) {
        prefs.edit {
            putString(KEY_DISPLAY_MODE, value.displayMode.name)
            putBoolean(KEY_ROW_TRACKING, value.rowTrackingEnabled)
            putFloat(KEY_ROW_INTERVAL, value.rowTrackingInterval.toFloat())
            putBoolean(KEY_AUTO_PHOTO, value.autoPhotoPrompt)
            putBoolean(KEY_AI, value.aiSuggestionsEnabled)
            putBoolean(KEY_AWAKE, value.keepScreenAwake)
            putString(KEY_TZ, value.timezone)
        }
        _displayModeFlow.value = value.displayMode
        _keepScreenAwakeFlow.value = value.keepScreenAwake
    }

    companion object {
        private const val KEY_DISPLAY_MODE = "display_mode"
        private const val KEY_ROW_TRACKING = "row_tracking_enabled"
        private const val KEY_ROW_INTERVAL = "row_tracking_interval"
        private const val KEY_AUTO_PHOTO = "auto_photo_prompt"
        private const val KEY_AI = "ai_suggestions_enabled"
        private const val KEY_AWAKE = "keep_screen_awake"
        private const val KEY_TZ = "timezone"

        private val _displayModeFlow = MutableStateFlow(DisplayMode.System)

        /** Process-wide display mode, observed by the root theme to switch live. */
        val displayModeFlow: StateFlow<DisplayMode> = _displayModeFlow.asStateFlow()

        private val _keepScreenAwakeFlow = MutableStateFlow(AppPreferences.factory.keepScreenAwake)

        /**
         * Process-wide "keep screen awake during trips" preference, observed by
         * the active trip screen so a mid-trip toggle applies immediately
         * (mirrors iOS `ScreenAwakeManager.preferenceDidChange`).
         */
        val keepScreenAwakeFlow: StateFlow<Boolean> = _keepScreenAwakeFlow.asStateFlow()

        /** Seeds the process-wide flows from persisted prefs. Call once at app start. */
        fun seedDisplayMode(context: Context) {
            val loaded = AppPreferencesStore(context).load()
            _displayModeFlow.value = loaded.displayMode
            _keepScreenAwakeFlow.value = loaded.keepScreenAwake
        }
    }
}
