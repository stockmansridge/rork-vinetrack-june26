package com.rork.vinetrack.data.resistance

import android.content.Context
import android.util.Log
import kotlinx.serialization.json.Json

/**
 * SharedPreferences-backed local cache for Resistance Plans.
 *
 * This is the OFFLINE CACHE and OUTBOX behind [ResistancePlanRepository], not the source
 * of truth — the server (`public.resistance_plans`, sql/196) is. It keeps three things
 * per vineyard:
 *
 *   1. every plan, INCLUDING soft-deleted tombstones, so a delete can propagate;
 *   2. the set of plan ids with unpushed local changes (the outbox);
 *   3. a one-time flag recording that Planner v1's local-only plans have been adopted.
 *
 * The storage key is unchanged from Planner v1 (`resistance_plans_v1_<vineyardId>`) on
 * purpose: that is what lets an existing user's plans be FOUND and adopted rather than
 * orphaned in a key nothing reads any more.
 *
 * Mirrors `ResistancePlanStore.swift` on iOS.
 */
class ResistancePlanStore(context: Context) : ResistancePlanLocalStore {

    private val prefs = context.applicationContext
        .getSharedPreferences("resistance_plans", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun plansKey(vineyardId: String) = "resistance_plans_v1_$vineyardId"
    private fun pendingKey(vineyardId: String) = "resistance_plans_pending_v1_$vineyardId"
    private fun adoptedKey(vineyardId: String) = "resistance_plans_adopted_v1_$vineyardId"
    private fun conflictsKey(vineyardId: String) = "resistance_plans_conflicts_v1_$vineyardId"

    override fun loadAll(vineyardId: String): List<ResistancePlan> {
        val raw = prefs.getString(plansKey(vineyardId), null) ?: return emptyList()
        return try {
            json.decodeFromString<List<ResistancePlan>>(raw)
        } catch (error: Exception) {
            // A decode failure must not wipe the grower's plans. The stored blob is left
            // untouched so a later app version can still read it, and the server copy is
            // unaffected either way.
            Log.w(TAG, "Could not read cached plans: ${error.message}")
            emptyList()
        }
    }

    override fun saveAll(vineyardId: String, plans: List<ResistancePlan>) {
        try {
            prefs.edit()
                .putString(plansKey(vineyardId), json.encodeToString(plans))
                .apply()
        } catch (error: Exception) {
            Log.w(TAG, "Could not cache plans: ${error.message}")
        }
    }

    override fun loadPending(vineyardId: String): Set<String> =
        prefs.getStringSet(pendingKey(vineyardId), emptySet())?.toSet() ?: emptySet()

    override fun savePending(vineyardId: String, ids: Set<String>) {
        prefs.edit().putStringSet(pendingKey(vineyardId), ids).apply()
    }

    override fun isAdopted(vineyardId: String): Boolean =
        prefs.getBoolean(adoptedKey(vineyardId), false)

    override fun markAdopted(vineyardId: String) {
        prefs.edit().putBoolean(adoptedKey(vineyardId), true).apply()
    }

    /**
     * Conflicts are PERSISTED, not held in memory.
     *
     * A conflict means the grower's authored plan exists nowhere except this device. If it
     * lived only in RAM, backgrounding the app would destroy the very copy the conflict
     * exists to protect, and the "Changes need review" badge would come back pointing at
     * nothing.
     */
    override fun loadConflicts(vineyardId: String): List<ResistancePlanConflict> {
        val raw = prefs.getString(conflictsKey(vineyardId), null) ?: return emptyList()
        return try {
            json.decodeFromString<List<ResistancePlanConflict>>(raw)
        } catch (error: Exception) {
            Log.w(TAG, "Could not read stored conflicts: ${error.message}")
            emptyList()
        }
    }

    override fun saveConflicts(vineyardId: String, conflicts: List<ResistancePlanConflict>) {
        try {
            prefs.edit()
                .putString(conflictsKey(vineyardId), json.encodeToString(conflicts))
                .apply()
        } catch (error: Exception) {
            Log.w(TAG, "Could not store conflicts: ${error.message}")
        }
    }

    companion object {
        private const val TAG = "ResistancePlanStore"
    }
}

/**
 * In-memory [ResistancePlanLocalStore] for tests and previews.
 *
 * Lives in production source rather than the test source set so the iOS mirror and any
 * future preview/demo mode use exactly the same cache semantics the repository is tested
 * against — a test-only fake that drifts from the real store proves nothing.
 */
class InMemoryResistancePlanLocalStore : ResistancePlanLocalStore {
    private val plans = mutableMapOf<String, List<ResistancePlan>>()
    private val pending = mutableMapOf<String, Set<String>>()
    private val adopted = mutableSetOf<String>()
    private val conflicts = mutableMapOf<String, List<ResistancePlanConflict>>()

    override fun loadAll(vineyardId: String): List<ResistancePlan> = plans[vineyardId] ?: emptyList()

    override fun saveAll(vineyardId: String, plans: List<ResistancePlan>) {
        this.plans[vineyardId] = plans
    }

    override fun loadPending(vineyardId: String): Set<String> = pending[vineyardId] ?: emptySet()

    override fun savePending(vineyardId: String, ids: Set<String>) {
        pending[vineyardId] = ids
    }

    override fun isAdopted(vineyardId: String): Boolean = adopted.contains(vineyardId)

    override fun markAdopted(vineyardId: String) {
        adopted.add(vineyardId)
    }

    override fun loadConflicts(vineyardId: String): List<ResistancePlanConflict> =
        conflicts[vineyardId] ?: emptyList()

    override fun saveConflicts(vineyardId: String, conflicts: List<ResistancePlanConflict>) {
        this.conflicts[vineyardId] = conflicts
    }
}
