package com.rork.vinetrack.data

import android.content.Context
import kotlinx.serialization.Serializable

/** Provider-isolated persistence contract for Optimal Ripeness daily weather. */
interface DailyWeatherCache {
    fun load(sourceKey: String): Map<String, DailyTemp>
    fun save(
        sourceKey: String,
        timeZoneId: String,
        stationOrLocationId: String,
        rows: Map<String, DailyTemp>,
        refreshedAtMs: Long = System.currentTimeMillis(),
    )
}

/** Durable SharedPreferences implementation of [DailyWeatherCache]. */
class DailyWeatherCacheStore(context: Context) : DailyWeatherCache {
    @Serializable
    private data class CachedTemp(val high: Double, val low: Double)

    @Serializable
    private data class SourceSnapshot(
        val sourceKey: String,
        val timeZoneId: String,
        val stationOrLocationId: String,
        val coverageStart: String? = null,
        val coverageEnd: String? = null,
        val lastSuccessfulRefreshMs: Long? = null,
        val rows: Map<String, CachedTemp> = emptyMap(),
    )

    private val preferences = context.getSharedPreferences("optimal_ripeness_daily_weather_v1", Context.MODE_PRIVATE)

    override fun load(sourceKey: String): Map<String, DailyTemp> {
        val payload = preferences.getString(key(sourceKey), null) ?: return emptyMap()
        val snapshot = runCatching {
            SupabaseClient.json.decodeFromString(SourceSnapshot.serializer(), payload)
        }.getOrNull() ?: return emptyMap()
        if (snapshot.sourceKey != sourceKey) return emptyMap()
        return snapshot.rows.mapValues { DailyTemp(it.value.high, it.value.low) }
    }

    override fun save(
        sourceKey: String,
        timeZoneId: String,
        stationOrLocationId: String,
        rows: Map<String, DailyTemp>,
        refreshedAtMs: Long,
    ) {
        val dates = rows.keys.sorted()
        val snapshot = SourceSnapshot(
            sourceKey = sourceKey,
            timeZoneId = timeZoneId,
            stationOrLocationId = stationOrLocationId,
            coverageStart = dates.firstOrNull(),
            coverageEnd = dates.lastOrNull(),
            lastSuccessfulRefreshMs = refreshedAtMs,
            rows = rows.mapValues { CachedTemp(it.value.high, it.value.low) },
        )
        val payload = SupabaseClient.json.encodeToString(SourceSnapshot.serializer(), snapshot)
        preferences.edit().putString(key(sourceKey), payload).apply()
    }

    private fun key(sourceKey: String): String = "source_${sourceKey.hashCode()}"
}
