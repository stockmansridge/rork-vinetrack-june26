package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.SprayTankActual
import kotlinx.serialization.Serializable

/** Durable, separate local authority for actual tank contents and their retry queue. */
class SprayTankActualStore(context: Context) {
    @Serializable private data class Cache(
        val records: List<SprayTankActual> = emptyList(),
        val pendingIds: Set<String> = emptySet(),
    )

    private val prefs = context.getSharedPreferences("vinetrack_spray_tank_actuals", Context.MODE_PRIVATE)

    @Synchronized fun load(): List<SprayTankActual> = cache().records

    @Synchronized fun actual(tripId: String, tankNumber: Int): SprayTankActual? =
        cache().records.filter { it.tripId == tripId && it.tankNumber == tankNumber }
            .maxByOrNull { it.clientUpdatedAt }

    /** Commits record and pending marker in one synchronous SharedPreferences transaction. */
    @Synchronized fun save(actual: SprayTankActual): Boolean {
        val current = cache()
        val records = current.records.toMutableList()
        val index = records.indexOfFirst { it.tripId == actual.tripId && it.tankSessionId == actual.tankSessionId }
        if (index >= 0) {
            if (records[index].clientUpdatedAt <= actual.clientUpdatedAt) records[index] = actual
        } else records.add(actual)
        return write(Cache(records, current.pendingIds + actual.id))
    }

    @Synchronized fun pending(): List<SprayTankActual> {
        val current = cache()
        return current.records.filter { it.id in current.pendingIds }
    }

    @Synchronized fun markSynced(id: String): Boolean {
        val current = cache()
        return write(current.copy(pendingIds = current.pendingIds - id))
    }

    private fun cache(): Cache = prefs.getString("cache", null)?.let {
        runCatching { SupabaseClient.json.decodeFromString(Cache.serializer(), it) }.getOrNull()
    } ?: Cache()

    private fun write(cache: Cache): Boolean = prefs.edit()
        .putString("cache", SupabaseClient.json.encodeToString(Cache.serializer(), cache))
        .commit()
}
