package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.SprayTankActual
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable

/** Durable, separate local authority for actual tank contents and their retry queue. */
class SprayTankActualStore(context: Context) {
    @Serializable private data class Cache(
        val records: List<SprayTankActual> = emptyList(),
        val pendingIds: Set<String> = emptySet(),
    )

    private val prefs = context.getSharedPreferences("vinetrack_spray_tank_actuals", Context.MODE_PRIVATE)
    private val _records = MutableStateFlow(cache().records)
    /** Single observable authority consumed by UI, reports, and reconciliation. */
    val records: StateFlow<List<SprayTankActual>> = _records.asStateFlow()

    @Synchronized fun load(): List<SprayTankActual> = _records.value

    @Synchronized fun actual(tripId: String, tankNumber: Int): SprayTankActual? =
        cache().records.filter { it.tripId == tripId && it.tankNumber == tankNumber }
            .maxByOrNull { it.clientUpdatedAt }

    /** Commits record and pending marker in one synchronous SharedPreferences transaction. */
    @Synchronized fun save(actual: SprayTankActual): Boolean {
        val current = cache()
        val records = current.records.toMutableList()
        val index = records.indexOfFirst { it.tripId == actual.tripId && it.tankSessionId == actual.tankSessionId }
        if (index >= 0) {
            if (records[index].clientUpdatedAt > actual.clientUpdatedAt) return true
            records[index] = actual
        } else records.add(actual)
        val validIds = records.mapTo(mutableSetOf()) { it.id }
        return write(Cache(records, (current.pendingIds intersect validIds) + actual.id))
    }

    /** Removes a just-created local row when a coordinated trip commit fails. */
    @Synchronized fun remove(id: String): Boolean {
        val current = cache()
        return write(current.copy(records = current.records.filterNot { it.id == id }, pendingIds = current.pendingIds - id))
    }

    @Synchronized fun pending(tripId: String? = null): List<SprayTankActual> {
        val current = cache()
        return current.records.filter { it.id in current.pendingIds && (tripId == null || it.tripId == tripId) }
    }

    /** Merges server rows without replacing a newer pending local confirmation. */
    @Synchronized fun mergeRemote(remote: List<SprayTankActual>): Boolean {
        val current = cache()
        val records = current.records.toMutableList()
        remote.forEach { incoming ->
            val index = records.indexOfFirst { it.tripId == incoming.tripId && it.tankSessionId == incoming.tankSessionId }
            if (index < 0) records.add(incoming)
            else if (records[index].id !in current.pendingIds && records[index].clientUpdatedAt < incoming.clientUpdatedAt) records[index] = incoming
        }
        return write(current.copy(records = records))
    }

    @Synchronized fun markSynced(id: String): Boolean {
        val current = cache()
        return write(current.copy(pendingIds = current.pendingIds - id))
    }

    private fun cache(): Cache = prefs.getString("cache", null)?.let {
        runCatching { SupabaseClient.json.decodeFromString(Cache.serializer(), it) }.getOrNull()
    } ?: Cache()

    private fun write(cache: Cache): Boolean {
        val committed = prefs.edit()
            .putString("cache", SupabaseClient.json.encodeToString(Cache.serializer(), cache))
            .commit()
        if (committed) _records.value = cache.records
        return committed
    }
}
