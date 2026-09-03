package com.rork.vinetrack.data

import android.content.Context
import kotlinx.serialization.Serializable

/** Vineyard-scoped persisted snapshot for cache-first Optimal Ripeness rendering. */
@Serializable
data class OptimalRipenessSnapshot(
    val ownerId: String,
    val vineyardId: String,
    val sourceFingerprint: String,
    val sourceLabel: String,
    val cachedAtEpochMs: Long,
    val rows: List<OptimalRipenessSnapshotRow>,
)

@Serializable
data class OptimalRipenessSnapshotRow(
    val blockId: String,
    val varietyName: String? = null,
    val allocationPercent: Double? = null,
    val multiVariety: Boolean = false,
    val resetDateMs: Long? = null,
    val total: Double,
    val target: Double,
    val daysToTarget: Int? = null,
)

/** Persists only the last successful result for each vineyard and signed-in owner. */
class OptimalRipenessCacheStore(context: Context) {
    private val preferences = context.getSharedPreferences("optimal_ripeness_cache_v1", Context.MODE_PRIVATE)

    fun load(ownerId: String?, vineyardId: String): OptimalRipenessSnapshot? {
        val owner = ownerId?.takeIf { it.isNotBlank() } ?: return null
        val payload = preferences.getString(key(vineyardId), null) ?: return null
        val snapshot = runCatching {
            SupabaseClient.json.decodeFromString(OptimalRipenessSnapshot.serializer(), payload)
        }.getOrNull() ?: return null
        return snapshot.takeIf {
            it.ownerId == owner && it.vineyardId.equals(vineyardId, ignoreCase = true)
        }
    }

    fun save(snapshot: OptimalRipenessSnapshot) {
        val payload = SupabaseClient.json.encodeToString(OptimalRipenessSnapshot.serializer(), snapshot)
        preferences.edit().putString(key(snapshot.vineyardId), payload).apply()
    }

    fun remove(vineyardId: String) {
        preferences.edit().remove(key(vineyardId)).apply()
    }

    private fun key(vineyardId: String): String = "vineyard_${vineyardId.lowercase()}"
}
