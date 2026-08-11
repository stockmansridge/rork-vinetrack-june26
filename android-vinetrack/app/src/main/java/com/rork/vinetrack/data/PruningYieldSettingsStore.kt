package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import com.rork.vinetrack.data.model.PruningYieldSettings
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Offline cache for the shared per-block Pruning Yield Calculator
 * configuration (sql/181). Supabase is AUTHORITATIVE — this is only a
 * per-vineyard snapshot so saved values survive an offline app restart.
 * Written on every successful server read and on every local save; read as
 * the fallback when the server list can't be fetched.
 *
 * Replaces the legacy [YieldDeterminationPrefsStore] per-block input storage
 * as the source of truth; that store is kept only as the one-time migration
 * source and for the device-local "Latest t/ha" hub detail.
 */
class PruningYieldSettingsStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_pruning_yield_settings", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val serializer = ListSerializer(PruningYieldSettings.serializer())

    fun load(vineyardId: String): List<PruningYieldSettings> {
        val raw = prefs.getString(key(vineyardId), null) ?: return emptyList()
        return runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
    }

    fun save(vineyardId: String, settings: List<PruningYieldSettings>) {
        prefs.edit {
            putString(key(vineyardId), json.encodeToString(serializer, settings))
        }
    }

    private fun key(vineyardId: String) = "settings_$vineyardId"
}
