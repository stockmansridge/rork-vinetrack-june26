package com.rork.vinetrack.data

import android.content.Context
import kotlinx.serialization.Serializable

/** Provider-isolated persistence contract for Optimal Ripeness daily weather. */
interface DailyWeatherCache {
    fun load(sourceKey: String): Map<String, DailyTemp>
    fun lastSuccessfulRefreshMs(sourceKey: String): Long?
    fun save(
        sourceKey: String,
        timeZoneId: String,
        stationOrLocationId: String,
        rows: Map<String, DailyTemp>,
        refreshedAtMs: Long = System.currentTimeMillis(),
    )
}

/** Durable SharedPreferences implementation of [DailyWeatherCache]. */
class DailyWeatherCacheStore(
    context: Context,
    private val requiredTimeZoneId: String,
) : DailyWeatherCache {
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

    // v2 intentionally rejects legacy rows that did not prove provider and
    // vineyard-timezone provenance. They are refetched automatically online.
    private val preferences = context.getSharedPreferences("optimal_ripeness_daily_weather_v2", Context.MODE_PRIVATE)

    private fun snapshot(sourceKey: String): SourceSnapshot? {
        val payload = preferences.getString(key(sourceKey), null) ?: return null
        val snapshot = runCatching {
            SupabaseClient.json.decodeFromString(SourceSnapshot.serializer(), payload)
        }.getOrNull() ?: return null
        return snapshot.takeIf {
            it.sourceKey == sourceKey &&
                it.stationOrLocationId == sourceKey &&
                it.timeZoneId == requiredTimeZoneId
        }
    }

    override fun load(sourceKey: String): Map<String, DailyTemp> =
        snapshot(sourceKey)?.rows?.mapValues { DailyTemp(it.value.high, it.value.low) }.orEmpty()

    override fun lastSuccessfulRefreshMs(sourceKey: String): Long? =
        snapshot(sourceKey)?.lastSuccessfulRefreshMs

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
