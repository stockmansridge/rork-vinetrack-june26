package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.Collections

/** Privately decoded, read-only display snapshot; never grants access or Trip authority. */
internal class FieldCacheHydration private constructor(
    val userId: String,
    val vineyardId: String,
    private val source: Map<String, Any?>,
    val pins: List<Pin>?,
    val trips: List<Trip>?,
    val spray: List<SprayRecord>?,
    val tasks: List<WorkTask>?,
    val growth: List<GrowthStageRecord>?,
    val paddocks: List<Paddock>?,
    val paddocksSyncedAt: Long?,
) {
    /** Exact source comparison includes owner, raw bytes and timestamps; no clock-based guess. */
    fun matches(userId: String, vineyardId: String, current: Map<String, Any?>): Boolean =
        this.userId == userId && this.vineyardId == vineyardId && source == selectSource(vineyardId, current)

    companion object {
        private val json = Json { ignoreUnknownKeys = true }
        private const val OWNER = "cache_owner_user_id"
        private val datasets = listOf("pins", "trips", "spray", "worktask", "growth", "paddocks")

        private fun selectSource(vineyardId: String, preferences: Map<String, Any?>): Map<String, Any?> =
            buildMap {
                put(OWNER, preferences[OWNER])
                for (dataset in datasets) {
                    put("${dataset}_$vineyardId", preferences["${dataset}_$vineyardId"])
                    put("${dataset}_at_$vineyardId", preferences["${dataset}_at_$vineyardId"])
                }
            }

        /** Called only in an awaited read worker against one atomic preference-map snapshot. */
        fun prepare(userId: String, vineyardId: String, preferences: Map<String, Any?>, onlyPins: Boolean = false): FieldCacheHydration? {
            val source = selectSource(vineyardId, preferences)
            if (userId.isBlank() || vineyardId.isBlank() || source[OWNER] != userId) return null
            fun <T> decode(dataset: String, serializer: KSerializer<T>): List<T>? {
                if (onlyPins && dataset != "pins") return null
                if (source["${dataset}_at_$vineyardId"] !is Long) return null
                val raw = source["${dataset}_$vineyardId"] as? String ?: return null
                return runCatching {
                    Collections.unmodifiableList(json.decodeFromString(ListSerializer(serializer), raw))
                }.getOrNull()
            }
            return FieldCacheHydration(userId, vineyardId, source,
                decode("pins", Pin.serializer()), decode("trips", Trip.serializer()),
                decode("spray", SprayRecord.serializer()), decode("worktask", WorkTask.serializer()),
                decode("growth", GrowthStageRecord.serializer()), decode("paddocks", Paddock.serializer()),
                source["paddocks_at_$vineyardId"] as? Long)
        }
    }
}
