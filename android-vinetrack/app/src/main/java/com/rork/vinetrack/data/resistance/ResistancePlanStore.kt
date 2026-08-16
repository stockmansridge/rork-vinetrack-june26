package com.rork.vinetrack.data.resistance

import android.content.Context
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json

/**
 * Local storage for Resistance Plans.
 *
 * WHY LOCAL FOR v1 (audited before writing any SQL):
 *
 * VineTrack's synced domain objects each have a dedicated Supabase table plus a
 * repository, RLS policies and sync plumbing (`SprayRecordRepository`,
 * `PaddockRepository`, and so on). There is NO generic per-vineyard JSON document table
 * to borrow, and the nearest planning-shaped stores — the Operational Tools layout,
 * button templates, fertiliser defaults, GDD settings — are either user-preference tables
 * with fixed columns or local-only stores. None of them can host a plan without a
 * migration.
 *
 * So a plan cannot be synced today without new SQL, and this task explicitly must not
 * apply a production migration. The tradeoff of staying local, stated plainly: a plan
 * does not follow the grower to another device, is not visible to a colleague, and is
 * lost if the app is reinstalled. That is a real limitation for a tool whose whole
 * purpose is season-long planning, which is why the proposed schema is reported for
 * approval rather than deferred.
 *
 * The model is already shaped for that move — serializable, vineyard-scoped, stable
 * position ids, stamped ruleset version — so adopting the table is a repository swap
 * behind this same interface, not a redesign.
 *
 * Mirrors `ResistancePlanStore.swift` on iOS.
 */
class ResistancePlanStore(context: Context) {

    private val prefs = context.getSharedPreferences("resistance_plans", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val _plans = MutableStateFlow<List<ResistancePlan>>(emptyList())

    /** Plans for the currently loaded vineyard, newest first. */
    val plans: StateFlow<List<ResistancePlan>> = _plans.asStateFlow()

    private var vineyardId: String? = null

    private fun storageKey(vineyardId: String) = "resistance_plans_v1_$vineyardId"

    fun load(vineyardId: String) {
        this.vineyardId = vineyardId
        val raw = prefs.getString(storageKey(vineyardId), null)
        if (raw == null) {
            _plans.value = emptyList()
            return
        }
        _plans.value = try {
            json.decodeFromString<List<ResistancePlan>>(raw)
                .sortedByDescending { it.updatedAtEpochMs }
        } catch (error: Exception) {
            // A decode failure must not wipe the grower's plans. The stored blob is left
            // untouched so a later app version with a migration can still read it.
            Log.w(TAG, "Could not read stored plans: ${error.message}")
            emptyList()
        }
    }

    /** Plans for a season and disease, newest first. */
    fun plans(seasonId: String, disease: ResistanceDisease): List<ResistancePlan> =
        _plans.value.filter { it.seasonId == seasonId && it.disease == disease }

    fun save(plan: ResistancePlan) {
        val vineyard = vineyardId ?: return
        val existing = _plans.value.toMutableList()
        val index = existing.indexOfFirst { it.id == plan.id }
        if (index >= 0) existing[index] = plan else existing.add(plan)
        _plans.value = existing.sortedByDescending { it.updatedAtEpochMs }
        persist(vineyard)
    }

    fun delete(planId: String) {
        val vineyard = vineyardId ?: return
        _plans.value = _plans.value.filterNot { it.id == planId }
        persist(vineyard)
    }

    private fun persist(vineyardId: String) {
        try {
            prefs.edit()
                .putString(storageKey(vineyardId), json.encodeToString(_plans.value))
                .apply()
        } catch (error: Exception) {
            Log.w(TAG, "Could not save plans: ${error.message}")
        }
    }

    companion object {
        private const val TAG = "ResistancePlanStore"

        /**
         * Shown wherever plans are listed, so the local-only limitation is never a
         * surprise discovered by losing work.
         */
        const val LOCAL_ONLY_NOTICE =
            "Resistance plans are saved on this device only. They do not yet sync between devices or to other users."
    }
}
