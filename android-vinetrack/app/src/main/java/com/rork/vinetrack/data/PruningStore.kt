package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import com.rork.vinetrack.data.model.PruningActivityDraft
import com.rork.vinetrack.data.model.PruningBlockSetup
import com.rork.vinetrack.data.model.PruningEntry
import kotlinx.serialization.json.Json

/**
 * Offline-first local cache for the Pruning Tracker (in development — System
 * Admin only). Backs seasons (block setups) and entries with per-vineyard
 * JSON blobs in SharedPreferences. This is the CACHE layer for the shared
 * `pruning_seasons` / `pruning_entries` / `pruning_row_segments` Supabase
 * tables — [PruningSyncCoordinator] writes through it and reconciles it with
 * the server.
 *
 * Key note: the v1 keys held device-only development test data and are
 * intentionally abandoned by the move to synced v2 keys.
 */
class PruningStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_pruning", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun loadSetups(vineyardId: String): List<PruningBlockSetup> {
        val raw = prefs.getString("setups_v2_$vineyardId", null) ?: return emptyList()
        return runCatching { json.decodeFromString<List<PruningBlockSetup>>(raw) }.getOrDefault(emptyList())
    }

    fun saveSetups(vineyardId: String, setups: List<PruningBlockSetup>) {
        prefs.edit { putString("setups_v2_$vineyardId", json.encodeToString(setups)) }
    }

    fun upsertSetup(vineyardId: String, setup: PruningBlockSetup): List<PruningBlockSetup> {
        val current = loadSetups(vineyardId)
        val updated = if (current.any { it.paddockId == setup.paddockId }) {
            current.map { if (it.paddockId == setup.paddockId) setup else it }
        } else {
            current + setup
        }
        saveSetups(vineyardId, updated)
        return updated
    }

    fun loadEntries(vineyardId: String): List<PruningEntry> {
        val raw = prefs.getString("entries_v2_$vineyardId", null) ?: return emptyList()
        return runCatching { json.decodeFromString<List<PruningEntry>>(raw) }.getOrDefault(emptyList())
    }

    fun saveEntries(vineyardId: String, entries: List<PruningEntry>) {
        prefs.edit { putString("entries_v2_$vineyardId", json.encodeToString(entries)) }
    }

    fun addEntry(vineyardId: String, entry: PruningEntry): List<PruningEntry> {
        val updated = loadEntries(vineyardId) + entry
        saveEntries(vineyardId, updated)
        return updated
    }

    fun updateEntry(vineyardId: String, entry: PruningEntry): List<PruningEntry> {
        val updated = loadEntries(vineyardId).map { if (it.id == entry.id) entry else it }
        saveEntries(vineyardId, updated)
        return updated
    }

    // MARK: Multi-block activities (sql/166)

    /**
     * Offline drafts of multi-block pruning activities. The COMPLETE activity
     * is persisted — parent fields plus EVERY block allocation — so an offline
     * draft is never partially saved and reopening it restores every block, not
     * only the one that happened to be on screen.
     */
    fun loadActivities(vineyardId: String): List<PruningActivityDraft> {
        val raw = prefs.getString("activities_v1_$vineyardId", null) ?: return emptyList()
        return runCatching { json.decodeFromString<List<PruningActivityDraft>>(raw) }
            .getOrDefault(emptyList())
    }

    fun saveActivities(vineyardId: String, activities: List<PruningActivityDraft>) {
        prefs.edit { putString("activities_v1_$vineyardId", json.encodeToString(activities)) }
    }

    fun activity(vineyardId: String, activityId: String): PruningActivityDraft? =
        loadActivities(vineyardId).firstOrNull { it.id == activityId }

    fun upsertActivity(vineyardId: String, draft: PruningActivityDraft): List<PruningActivityDraft> {
        val current = loadActivities(vineyardId)
        val updated = if (current.any { it.id == draft.id }) {
            current.map { if (it.id == draft.id) draft else it }
        } else {
            current + draft
        }
        saveActivities(vineyardId, updated)
        return updated
    }

    /** Flags the whole activity reversed; every allocation inherits it. */
    fun reverseActivity(vineyardId: String, activityId: String): List<PruningActivityDraft> {
        val now = System.currentTimeMillis()
        val updated = loadActivities(vineyardId).map {
            if (it.id == activityId && !it.isReversed) it.copy(reversedAtMs = now) else it
        }
        saveActivities(vineyardId, updated)
        return updated
    }

    /**
     * Merges one activity's legacy per-block projection into the entries cache.
     * [staleAllocationIds] are allocations the edit dropped: they are flagged
     * reversed rather than deleted, so the Activity Report keeps the audit
     * trail while every progress calculation excludes them.
     */
    fun mergeActivityEntries(
        vineyardId: String,
        entries: List<PruningEntry>,
        staleAllocationIds: Set<String> = emptySet(),
    ): List<PruningEntry> {
        val now = System.currentTimeMillis()
        val incoming = entries.associateBy { it.id }
        val existing = loadEntries(vineyardId).map { row ->
            when {
                incoming.containsKey(row.id) -> incoming.getValue(row.id)
                row.id in staleAllocationIds && !row.isReversed -> row.copy(reversedAtMs = now)
                else -> row
            }
        }
        val known = existing.map { it.id }.toSet()
        val updated = existing + entries.filterNot { it.id in known }
        saveEntries(vineyardId, updated)
        return updated
    }

    /**
     * Reverses an entry. The row is RETAINED in the cache (flagged
     * [PruningEntry.reversedAtMs]) so the Pruning Activity Report keeps the
     * audit trail; every read path that feeds progress, rates and forecasts
     * filters reversed entries out, so progress reverts exactly as before.
     * Returns the ACTIVE entries.
     */
    fun deleteEntry(vineyardId: String, entryId: String): List<PruningEntry> {
        val now = System.currentTimeMillis()
        val updated = loadEntries(vineyardId).map {
            if (it.id == entryId && !it.isReversed) it.copy(reversedAtMs = now) else it
        }
        saveEntries(vineyardId, updated)
        return updated.filterNot { it.isReversed }
    }
}
