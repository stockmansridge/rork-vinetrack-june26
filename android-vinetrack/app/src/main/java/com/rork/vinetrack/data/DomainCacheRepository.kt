package com.rork.vinetrack.data

import android.content.Context
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

/**
 * Sole access point for the local read-cache of launch-critical vineyard data
 * (Stage 6A — write-through foundation only).
 *
 * Wraps [DomainCacheStore] and owns cache-owner separation so a cache saved by
 * one signed-in user is never served to another. Screens and the loading path
 * must use this rather than touching the store directly. Kept deliberately
 * separate from [PendingWriteRepository] (write outbox vs. read cache).
 *
 * IMPORTANT (this slice): only the write-through `save*` paths are wired into
 * production. The `load*` accessors exist for Stage 6B offline hydration and are
 * not yet used to drive app state or routing. Caching here never performs a
 * network call or any write-path side effect.
 */
class DomainCacheRepository(context: Context) {

    private val store = DomainCacheStore(context)

    // MARK: - Vineyard list

    /**
     * Save the vineyard list from a successful online fetch. Establishes the
     * cache owner; if the signed-in user changed, the whole cache is wiped
     * first so stale data from a previous account is never retained.
     */
    fun saveVineyards(userId: String?, vineyards: List<Vineyard>) {
        ensureOwner(userId)
        store.saveVineyards(vineyards, System.currentTimeMillis())
    }

    /** Cached vineyard list for [userId], or null if absent / owned by someone else. */
    fun loadVineyards(userId: String?): List<Vineyard>? {
        if (!ownerMatches(userId) || store.vineyardsSyncedAt() == null) return null
        return store.loadVineyards()
    }

    fun vineyardsSyncedAt(userId: String?): Long? =
        if (ownerMatches(userId)) store.vineyardsSyncedAt() else null

    // MARK: - Paddocks by vineyard

    /** Save paddocks from a successful online fetch, claiming the cache for [userId]. */
    fun savePaddocks(userId: String?, vineyardId: String, paddocks: List<Paddock>) {
        ensureOwner(userId)
        store.savePaddocks(vineyardId, paddocks, System.currentTimeMillis())
    }

    /** Cached paddocks for the vineyard, or null if absent / owned by someone else. */
    fun loadPaddocks(userId: String?, vineyardId: String): List<Paddock>? {
        if (!ownerMatches(userId) || store.paddocksSyncedAt(vineyardId) == null) return null
        return store.loadPaddocks(vineyardId)
    }

    fun paddocksSyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.paddocksSyncedAt(vineyardId) else null

    // MARK: - Pins by vineyard

    /** Save pins from a successful online fetch, claiming the cache for [userId]. */
    fun savePins(userId: String?, vineyardId: String, pins: List<Pin>) {
        ensureOwner(userId)
        store.savePins(vineyardId, pins, System.currentTimeMillis())
    }

    /** Cached pins for the vineyard, or null if absent / owned by someone else. */
    fun loadPins(userId: String?, vineyardId: String): List<Pin>? {
        if (!ownerMatches(userId) || store.pinsSyncedAt(vineyardId) == null) return null
        return store.loadPins(vineyardId)
    }

    fun pinsSyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.pinsSyncedAt(vineyardId) else null

    // MARK: - Maintenance logs by vineyard (Stage O-2 — single-entity field cache)

    /** Save maintenance logs from a successful online fetch, claiming the cache for [userId]. */
    fun saveMaintenance(userId: String?, vineyardId: String, logs: List<MaintenanceLog>) {
        ensureOwner(userId)
        store.saveMaintenance(vineyardId, logs, System.currentTimeMillis())
    }

    /** Cached maintenance logs for the vineyard, or null if absent / owned by someone else. */
    fun loadMaintenance(userId: String?, vineyardId: String): List<MaintenanceLog>? {
        if (!ownerMatches(userId) || store.maintenanceSyncedAt(vineyardId) == null) return null
        return store.loadMaintenance(vineyardId)
    }

    fun maintenanceSyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.maintenanceSyncedAt(vineyardId) else null

    // MARK: - Yield records by vineyard (Stage O-2)

    /** Save yield records from a successful online fetch, claiming the cache for [userId]. */
    fun saveYield(userId: String?, vineyardId: String, records: List<HistoricalYieldRecord>) {
        ensureOwner(userId)
        store.saveYield(vineyardId, records, System.currentTimeMillis())
    }

    /** Cached yield records for the vineyard, or null if absent / owned by someone else. */
    fun loadYield(userId: String?, vineyardId: String): List<HistoricalYieldRecord>? {
        if (!ownerMatches(userId) || store.yieldSyncedAt(vineyardId) == null) return null
        return store.loadYield(vineyardId)
    }

    fun yieldSyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.yieldSyncedAt(vineyardId) else null

    // MARK: - Damage records by vineyard

    fun saveDamage(userId: String?, vineyardId: String, records: List<DamageRecord>) {
        if (!ownerMatches(userId)) return
        store.saveDamage(vineyardId, records, System.currentTimeMillis())
    }

    fun loadDamage(userId: String?, vineyardId: String): List<DamageRecord>? {
        if (!ownerMatches(userId) || store.damageSyncedAt(vineyardId) == null) return null
        return store.loadDamage(vineyardId)
    }

    fun damageSyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.damageSyncedAt(vineyardId) else null

    // MARK: - Yield estimation sessions by vineyard

    fun saveYieldSessions(userId: String?, vineyardId: String, sessions: List<YieldEstimationSession>) {
        if (!ownerMatches(userId)) return
        store.saveYieldSessions(vineyardId, sessions, System.currentTimeMillis())
    }

    fun loadYieldSessions(userId: String?, vineyardId: String): List<YieldEstimationSession>? {
        if (!ownerMatches(userId) || store.yieldSessionsSyncedAt(vineyardId) == null) return null
        return store.loadYieldSessions(vineyardId)
    }

    fun yieldSessionsSyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.yieldSessionsSyncedAt(vineyardId) else null

    // MARK: - Growth-stage records by vineyard (Stage O-2)

    /** Save growth-stage records from a successful online fetch, claiming the cache for [userId]. */
    fun saveGrowth(userId: String?, vineyardId: String, records: List<GrowthStageRecord>) {
        ensureOwner(userId)
        store.saveGrowth(vineyardId, records, System.currentTimeMillis())
    }

    /** Cached growth-stage records for the vineyard, or null if absent / owned by someone else. */
    fun loadGrowth(userId: String?, vineyardId: String): List<GrowthStageRecord>? {
        if (!ownerMatches(userId) || store.growthSyncedAt(vineyardId) == null) return null
        return store.loadGrowth(vineyardId)
    }

    fun growthSyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.growthSyncedAt(vineyardId) else null

    // MARK: - Fuel logs by vineyard (Stage P-1 — single-entity field cache)

    /** Save fuel logs from a successful online fetch, claiming the cache for [userId]. */
    fun saveFuel(userId: String?, vineyardId: String, logs: List<TractorFuelLog>) {
        ensureOwner(userId)
        store.saveFuel(vineyardId, logs, System.currentTimeMillis())
    }

    /** Cached fuel logs for the vineyard, or null if absent / owned by someone else. */
    fun loadFuel(userId: String?, vineyardId: String): List<TractorFuelLog>? {
        if (!ownerMatches(userId) || store.fuelSyncedAt(vineyardId) == null) return null
        return store.loadFuel(vineyardId)
    }

    fun fuelSyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.fuelSyncedAt(vineyardId) else null

    // MARK: - Spray records by vineyard (Stage P-2 — single-entity field cache)

    /** Save spray records from a successful online fetch, claiming the cache for [userId]. */
    fun saveSpray(userId: String?, vineyardId: String, records: List<SprayRecord>) {
        ensureOwner(userId)
        store.saveSpray(vineyardId, records, System.currentTimeMillis())
    }

    /** Cached spray records for the vineyard, or null if absent / owned by someone else. */
    fun loadSpray(userId: String?, vineyardId: String): List<SprayRecord>? {
        if (!ownerMatches(userId) || store.spraySyncedAt(vineyardId) == null) return null
        return store.loadSpray(vineyardId)
    }

    fun spraySyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.spraySyncedAt(vineyardId) else null

    // MARK: - Work-task headers by vineyard (Stage P-3 — vineyard-scoped header cache)

    /** Save work-task headers from a successful online fetch, claiming the cache for [userId]. */
    fun saveWorkTasks(userId: String?, vineyardId: String, tasks: List<WorkTask>) {
        ensureOwner(userId)
        store.saveWorkTasks(vineyardId, tasks, System.currentTimeMillis())
    }

    /** Cached work-task headers for the vineyard, or null if absent / owned by someone else. */
    fun loadWorkTasks(userId: String?, vineyardId: String): List<WorkTask>? {
        if (!ownerMatches(userId) || store.workTasksSyncedAt(vineyardId) == null) return null
        return store.loadWorkTasks(vineyardId)
    }

    fun workTasksSyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.workTasksSyncedAt(vineyardId) else null

    // MARK: - Work-task labour lines by TASK (Stage P-3 — child lines load per task)

    /** Save a task's labour lines from a successful online fetch, claiming the cache for [userId]. */
    fun saveLabourLines(userId: String?, workTaskId: String, lines: List<WorkTaskLabourLine>) {
        ensureOwner(userId)
        store.saveLabourLines(workTaskId, lines, System.currentTimeMillis())
    }

    /** Cached labour lines for the task, or null if absent / owned by someone else. */
    fun loadLabourLines(userId: String?, workTaskId: String): List<WorkTaskLabourLine>? {
        if (!ownerMatches(userId) || store.labourLinesSyncedAt(workTaskId) == null) return null
        return store.loadLabourLines(workTaskId)
    }

    fun labourLinesSyncedAt(userId: String?, workTaskId: String): Long? =
        if (ownerMatches(userId)) store.labourLinesSyncedAt(workTaskId) else null

    // MARK: - Work-task machine lines by TASK (Stage P-3)

    /** Save a task's machine lines from a successful online fetch, claiming the cache for [userId]. */
    fun saveMachineLines(userId: String?, workTaskId: String, lines: List<WorkTaskMachineLine>) {
        ensureOwner(userId)
        store.saveMachineLines(workTaskId, lines, System.currentTimeMillis())
    }

    /** Cached machine lines for the task, or null if absent / owned by someone else. */
    fun loadMachineLines(userId: String?, workTaskId: String): List<WorkTaskMachineLine>? {
        if (!ownerMatches(userId) || store.machineLinesSyncedAt(workTaskId) == null) return null
        return store.loadMachineLines(workTaskId)
    }

    fun machineLinesSyncedAt(userId: String?, workTaskId: String): Long? =
        if (ownerMatches(userId)) store.machineLinesSyncedAt(workTaskId) else null

    // MARK: - Historical trips by vineyard (Stage P-4 — snapshot-only cache, no overlay)

    /**
     * Save the historical trip list from a successful online fetch, claiming the
     * cache for [userId]. Snapshot-only: trip pending markers are scalar deltas,
     * not reconstructable trip rows, so no pending-write overlay is applied to
     * trips. The active trip remains governed by [ActiveTripStore]; callers must
     * pass the raw server list so a restored active-trip provisional row is never
     * baked into this historical snapshot.
     */
    fun saveTrips(userId: String?, vineyardId: String, trips: List<Trip>) {
        ensureOwner(userId)
        store.saveTrips(vineyardId, trips, System.currentTimeMillis())
    }

    /** Cached historical trips for the vineyard, or null if absent / owned by someone else. */
    fun loadTrips(userId: String?, vineyardId: String): List<Trip>? {
        if (!ownerMatches(userId) || store.tripsSyncedAt(vineyardId) == null) return null
        return store.loadTrips(vineyardId)
    }

    fun tripsSyncedAt(userId: String?, vineyardId: String): Long? =
        if (ownerMatches(userId)) store.tripsSyncedAt(vineyardId) else null

    // MARK: - Maintenance

    /** Wipe the entire cache (e.g. on sign-out). */
    fun clearAll() = store.clearAll()

    /** Drop the cache if it belongs to a different user, then claim it for [userId]. */
    fun clearForDifferentUser(userId: String?) = ensureOwner(userId)

    private fun ownerMatches(userId: String?): Boolean = store.owner() == userId

    private fun ensureOwner(userId: String?) {
        if (store.owner() != userId) {
            store.clearAll()
            store.setOwner(userId)
        }
    }
}
