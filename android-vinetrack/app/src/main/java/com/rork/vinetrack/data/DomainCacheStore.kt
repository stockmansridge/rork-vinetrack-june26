package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import com.rork.vinetrack.data.model.DamageRecord
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.HistoricalYieldRecord
import com.rork.vinetrack.data.model.MaintenanceLog
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.TractorFuelLog
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.Vineyard
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.WorkTaskMachineLine
import com.rork.vinetrack.data.model.YieldEstimationSession
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Local read-cache persistence for launch-critical vineyard data (Stage 6A —
 * write-through foundation only).
 *
 * Backs each cached group with a JSON blob in a dedicated SharedPreferences
 * file, following the same lightweight local-only pattern as
 * [PendingWriteStore] / [CanopyWaterRatesStore]. Room was deliberately avoided
 * for this slice: the cached set is small (vineyard list + the selected
 * vineyard's paddocks/pins), whole-group replace is sufficient, and a database
 * toolchain is disproportionate for a cache that nothing hydrates from yet.
 *
 * This store is intentionally low-level (whole-group read/replace). All callers
 * must go through [DomainCacheRepository]; nothing should touch it directly.
 *
 * IMPORTANT (this slice): the cache is written through on successful online
 * reads only. No code reads it back into app state yet — offline hydration
 * lands in Stage 6B.
 */
class DomainCacheStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_domain_cache", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val vineyardSerializer = ListSerializer(Vineyard.serializer())
    private val paddockSerializer = ListSerializer(Paddock.serializer())
    private val pinSerializer = ListSerializer(Pin.serializer())
    private val maintenanceSerializer = ListSerializer(MaintenanceLog.serializer())
    private val yieldSerializer = ListSerializer(HistoricalYieldRecord.serializer())
    private val damageSerializer = ListSerializer(DamageRecord.serializer())
    private val growthSerializer = ListSerializer(GrowthStageRecord.serializer())
    private val fuelSerializer = ListSerializer(TractorFuelLog.serializer())
    private val spraySerializer = ListSerializer(SprayRecord.serializer())
    private val workTaskSerializer = ListSerializer(WorkTask.serializer())
    private val labourLineSerializer = ListSerializer(WorkTaskLabourLine.serializer())
    private val machineLineSerializer = ListSerializer(WorkTaskMachineLine.serializer())
    private val tripSerializer = ListSerializer(Trip.serializer())
    private val yieldSessionSerializer = ListSerializer(YieldEstimationSession.serializer())

    // MARK: - Cache owner

    /** User id the current cache belongs to (null on first run / after clear). */
    fun owner(): String? = prefs.getString(KEY_OWNER, null)

    fun setOwner(userId: String?) = prefs.edit { putString(KEY_OWNER, userId) }

    // MARK: - Vineyard list

    fun loadVineyards(): List<Vineyard> = decode(prefs.getString(KEY_VINEYARDS, null), vineyardSerializer)

    fun saveVineyards(vineyards: List<Vineyard>, syncedAt: Long) {
        prefs.edit {
            putString(KEY_VINEYARDS, json.encodeToString(vineyardSerializer, vineyards))
            putLong(KEY_VINEYARDS_AT, syncedAt)
        }
    }

    fun vineyardsSyncedAt(): Long? = readTimestamp(KEY_VINEYARDS_AT)

    // MARK: - Paddocks by vineyard

    fun loadPaddocks(vineyardId: String): List<Paddock> =
        decode(prefs.getString(keyPaddocks(vineyardId), null), paddockSerializer)

    fun savePaddocks(vineyardId: String, paddocks: List<Paddock>, syncedAt: Long) {
        prefs.edit {
            putString(keyPaddocks(vineyardId), json.encodeToString(paddockSerializer, paddocks))
            putLong(keyPaddocksAt(vineyardId), syncedAt)
        }
    }

    fun paddocksSyncedAt(vineyardId: String): Long? = readTimestamp(keyPaddocksAt(vineyardId))

    // MARK: - Pins by vineyard

    fun loadPins(vineyardId: String): List<Pin> =
        decode(prefs.getString(keyPins(vineyardId), null), pinSerializer)

    fun savePins(vineyardId: String, pins: List<Pin>, syncedAt: Long) {
        prefs.edit {
            putString(keyPins(vineyardId), json.encodeToString(pinSerializer, pins))
            putLong(keyPinsAt(vineyardId), syncedAt)
        }
    }

    fun pinsSyncedAt(vineyardId: String): Long? = readTimestamp(keyPinsAt(vineyardId))

    // MARK: - Maintenance logs by vineyard (Stage O-2 — single-entity field cache)

    fun loadMaintenance(vineyardId: String): List<MaintenanceLog> =
        decode(prefs.getString(keyMaintenance(vineyardId), null), maintenanceSerializer)

    fun saveMaintenance(vineyardId: String, logs: List<MaintenanceLog>, syncedAt: Long) {
        prefs.edit {
            putString(keyMaintenance(vineyardId), json.encodeToString(maintenanceSerializer, logs))
            putLong(keyMaintenanceAt(vineyardId), syncedAt)
        }
    }

    fun maintenanceSyncedAt(vineyardId: String): Long? = readTimestamp(keyMaintenanceAt(vineyardId))

    // MARK: - Yield records by vineyard (Stage O-2)

    fun loadYield(vineyardId: String): List<HistoricalYieldRecord> =
        decode(prefs.getString(keyYield(vineyardId), null), yieldSerializer)

    fun saveYield(vineyardId: String, records: List<HistoricalYieldRecord>, syncedAt: Long) {
        prefs.edit {
            putString(keyYield(vineyardId), json.encodeToString(yieldSerializer, records))
            putLong(keyYieldAt(vineyardId), syncedAt)
        }
    }

    fun yieldSyncedAt(vineyardId: String): Long? = readTimestamp(keyYieldAt(vineyardId))

    // MARK: - Damage records by vineyard

    fun loadDamage(vineyardId: String): List<DamageRecord> =
        decode(prefs.getString(keyDamage(vineyardId), null), damageSerializer)

    fun saveDamage(vineyardId: String, records: List<DamageRecord>, syncedAt: Long) {
        prefs.edit {
            putString(keyDamage(vineyardId), json.encodeToString(damageSerializer, records))
            putLong(keyDamageAt(vineyardId), syncedAt)
        }
    }

    fun damageSyncedAt(vineyardId: String): Long? = readTimestamp(keyDamageAt(vineyardId))

    // MARK: - Yield estimation sessions by vineyard (Stage Q — working-session cache)

    fun loadYieldSessions(vineyardId: String): List<YieldEstimationSession> =
        decode(prefs.getString(keyYieldSession(vineyardId), null), yieldSessionSerializer)

    fun saveYieldSessions(vineyardId: String, sessions: List<YieldEstimationSession>, syncedAt: Long) {
        prefs.edit {
            putString(keyYieldSession(vineyardId), json.encodeToString(yieldSessionSerializer, sessions))
            putLong(keyYieldSessionAt(vineyardId), syncedAt)
        }
    }

    fun yieldSessionsSyncedAt(vineyardId: String): Long? = readTimestamp(keyYieldSessionAt(vineyardId))

    // MARK: - Growth-stage records by vineyard (Stage O-2)

    fun loadGrowth(vineyardId: String): List<GrowthStageRecord> =
        decode(prefs.getString(keyGrowth(vineyardId), null), growthSerializer)

    fun saveGrowth(vineyardId: String, records: List<GrowthStageRecord>, syncedAt: Long) {
        prefs.edit {
            putString(keyGrowth(vineyardId), json.encodeToString(growthSerializer, records))
            putLong(keyGrowthAt(vineyardId), syncedAt)
        }
    }

    fun growthSyncedAt(vineyardId: String): Long? = readTimestamp(keyGrowthAt(vineyardId))

    // MARK: - Fuel logs by vineyard (Stage P-1 — single-entity field cache)

    fun loadFuel(vineyardId: String): List<TractorFuelLog> =
        decode(prefs.getString(keyFuel(vineyardId), null), fuelSerializer)

    fun saveFuel(vineyardId: String, logs: List<TractorFuelLog>, syncedAt: Long) {
        prefs.edit {
            putString(keyFuel(vineyardId), json.encodeToString(fuelSerializer, logs))
            putLong(keyFuelAt(vineyardId), syncedAt)
        }
    }

    fun fuelSyncedAt(vineyardId: String): Long? = readTimestamp(keyFuelAt(vineyardId))

    // MARK: - Spray records by vineyard (Stage P-2 — single-entity field cache)

    fun loadSpray(vineyardId: String): List<SprayRecord> =
        decode(prefs.getString(keySpray(vineyardId), null), spraySerializer)

    fun saveSpray(vineyardId: String, records: List<SprayRecord>, syncedAt: Long) {
        prefs.edit {
            putString(keySpray(vineyardId), json.encodeToString(spraySerializer, records))
            putLong(keySprayAt(vineyardId), syncedAt)
        }
    }

    fun spraySyncedAt(vineyardId: String): Long? = readTimestamp(keySprayAt(vineyardId))

    // MARK: - Work-task headers by vineyard (Stage P-3 — vineyard-scoped header cache)

    fun loadWorkTasks(vineyardId: String): List<WorkTask> =
        decode(prefs.getString(keyWorkTask(vineyardId), null), workTaskSerializer)

    fun saveWorkTasks(vineyardId: String, tasks: List<WorkTask>, syncedAt: Long) {
        prefs.edit {
            putString(keyWorkTask(vineyardId), json.encodeToString(workTaskSerializer, tasks))
            putLong(keyWorkTaskAt(vineyardId), syncedAt)
        }
    }

    fun workTasksSyncedAt(vineyardId: String): Long? = readTimestamp(keyWorkTaskAt(vineyardId))

    // MARK: - Work-task labour lines by TASK (Stage P-3 — child lines load per task)

    fun loadLabourLines(workTaskId: String): List<WorkTaskLabourLine> =
        decode(prefs.getString(keyLabour(workTaskId), null), labourLineSerializer)

    fun saveLabourLines(workTaskId: String, lines: List<WorkTaskLabourLine>, syncedAt: Long) {
        prefs.edit {
            putString(keyLabour(workTaskId), json.encodeToString(labourLineSerializer, lines))
            putLong(keyLabourAt(workTaskId), syncedAt)
        }
    }

    fun labourLinesSyncedAt(workTaskId: String): Long? = readTimestamp(keyLabourAt(workTaskId))

    // MARK: - Work-task machine lines by TASK (Stage P-3)

    fun loadMachineLines(workTaskId: String): List<WorkTaskMachineLine> =
        decode(prefs.getString(keyMachine(workTaskId), null), machineLineSerializer)

    fun saveMachineLines(workTaskId: String, lines: List<WorkTaskMachineLine>, syncedAt: Long) {
        prefs.edit {
            putString(keyMachine(workTaskId), json.encodeToString(machineLineSerializer, lines))
            putLong(keyMachineAt(workTaskId), syncedAt)
        }
    }

    fun machineLinesSyncedAt(workTaskId: String): Long? = readTimestamp(keyMachineAt(workTaskId))

    // MARK: - Historical trips by vineyard (Stage P-4 — snapshot-only cache, no overlay)

    fun loadTrips(vineyardId: String): List<Trip> =
        decode(prefs.getString(keyTrips(vineyardId), null), tripSerializer)

    fun saveTrips(vineyardId: String, trips: List<Trip>, syncedAt: Long) {
        prefs.edit {
            putString(keyTrips(vineyardId), json.encodeToString(tripSerializer, trips))
            putLong(keyTripsAt(vineyardId), syncedAt)
        }
    }

    fun tripsSyncedAt(vineyardId: String): Long? = readTimestamp(keyTripsAt(vineyardId))

    // MARK: - Maintenance

    /** Wipe the entire cache (used when the cache owner changes). */
    fun clearAll() = prefs.edit { clear() }

    private fun <T> decode(raw: String?, serializer: kotlinx.serialization.KSerializer<List<T>>): List<T> {
        if (raw == null) return emptyList()
        return runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
    }

    private fun readTimestamp(key: String): Long? =
        if (prefs.contains(key)) prefs.getLong(key, 0L) else null

    private fun keyPaddocks(vineyardId: String) = "paddocks_$vineyardId"
    private fun keyPaddocksAt(vineyardId: String) = "paddocks_at_$vineyardId"
    private fun keyPins(vineyardId: String) = "pins_$vineyardId"
    private fun keyPinsAt(vineyardId: String) = "pins_at_$vineyardId"
    private fun keyMaintenance(vineyardId: String) = "maintenance_$vineyardId"
    private fun keyMaintenanceAt(vineyardId: String) = "maintenance_at_$vineyardId"
    private fun keyYield(vineyardId: String) = "yield_$vineyardId"
    private fun keyYieldAt(vineyardId: String) = "yield_at_$vineyardId"
    private fun keyDamage(vineyardId: String) = "damage_$vineyardId"
    private fun keyDamageAt(vineyardId: String) = "damage_at_$vineyardId"
    private fun keyYieldSession(vineyardId: String) = "yield_session_$vineyardId"
    private fun keyYieldSessionAt(vineyardId: String) = "yield_session_at_$vineyardId"
    private fun keyGrowth(vineyardId: String) = "growth_$vineyardId"
    private fun keyGrowthAt(vineyardId: String) = "growth_at_$vineyardId"
    private fun keyFuel(vineyardId: String) = "fuel_$vineyardId"
    private fun keyFuelAt(vineyardId: String) = "fuel_at_$vineyardId"
    private fun keySpray(vineyardId: String) = "spray_$vineyardId"
    private fun keySprayAt(vineyardId: String) = "spray_at_$vineyardId"
    private fun keyWorkTask(vineyardId: String) = "worktask_$vineyardId"
    private fun keyWorkTaskAt(vineyardId: String) = "worktask_at_$vineyardId"
    private fun keyLabour(workTaskId: String) = "worktask_labour_$workTaskId"
    private fun keyLabourAt(workTaskId: String) = "worktask_labour_at_$workTaskId"
    private fun keyMachine(workTaskId: String) = "worktask_machine_$workTaskId"
    private fun keyMachineAt(workTaskId: String) = "worktask_machine_at_$workTaskId"
    private fun keyTrips(vineyardId: String) = "trips_$vineyardId"
    private fun keyTripsAt(vineyardId: String) = "trips_at_$vineyardId"

    private companion object {
        const val KEY_OWNER = "cache_owner_user_id"
        const val KEY_VINEYARDS = "vineyards_json"
        const val KEY_VINEYARDS_AT = "vineyards_synced_at"
    }
}
