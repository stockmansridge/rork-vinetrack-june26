package com.rork.vinetrack.data

import android.content.Context
import kotlinx.serialization.Serializable

/** Durable authoritative provider identity; daily rows remain in [DailyWeatherCache]. */
@Serializable
data class OptimalRipenessSourceSelection(
    val ownerId: String,
    val vineyardId: String,
    val sourceFingerprint: String,
    val sourceLabel: String,
)

class OptimalRipenessSourceStore(context: Context) {
    private val preferences = context.getSharedPreferences("optimal_ripeness_source_v1", Context.MODE_PRIVATE)

    fun load(ownerId: String?, vineyardId: String): OptimalRipenessSourceSelection? {
        val owner = ownerId?.takeIf { it.isNotBlank() } ?: return null
        val payload = preferences.getString(key(vineyardId), null) ?: return null
        return runCatching {
            SupabaseClient.json.decodeFromString(OptimalRipenessSourceSelection.serializer(), payload)
        }.getOrNull()?.takeIf { it.ownerId == owner && it.vineyardId.equals(vineyardId, ignoreCase = true) }
    }

    fun save(selection: OptimalRipenessSourceSelection) {
        val payload = SupabaseClient.json.encodeToString(OptimalRipenessSourceSelection.serializer(), selection)
        preferences.edit().putString(key(selection.vineyardId), payload).apply()
    }

    private fun key(vineyardId: String): String = "vineyard_${vineyardId.lowercase()}"
}
