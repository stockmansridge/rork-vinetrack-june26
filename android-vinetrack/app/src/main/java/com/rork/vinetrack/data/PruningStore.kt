package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
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

    fun deleteEntry(vineyardId: String, entryId: String): List<PruningEntry> {
        val updated = loadEntries(vineyardId).filterNot { it.id == entryId }
        saveEntries(vineyardId, updated)
        return updated
    }
}
