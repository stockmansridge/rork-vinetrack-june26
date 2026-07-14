package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import com.rork.vinetrack.data.model.FertiliserRecord
import kotlinx.serialization.json.Json

/**
 * Offline-first local cache for the Fertiliser Calculator (in development —
 * System Admin only). Backs saved calculations with per-vineyard JSON blobs in
 * SharedPreferences. This is the CACHE layer for the shared
 * `fertiliser_records` / `fertiliser_record_allocations` Supabase tables —
 * [FertiliserSyncCoordinator] writes through it and reconciles it with the
 * server.
 *
 * Products are NOT cached here — the Fertiliser Calculator reads its product
 * library from the shared saved chemical database (`saved_chemicals`,
 * sql/111), which lives in the main app state.
 */
class FertiliserStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_fertiliser", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun loadRecords(vineyardId: String): List<FertiliserRecord> {
        val raw = prefs.getString("records_v2_$vineyardId", null) ?: return emptyList()
        return runCatching { json.decodeFromString<List<FertiliserRecord>>(raw) }
            .getOrDefault(emptyList())
            .sortedByDescending { it.date }
    }

    fun saveRecords(vineyardId: String, records: List<FertiliserRecord>) {
        prefs.edit { putString("records_v2_$vineyardId", json.encodeToString(records)) }
    }

    fun addRecord(vineyardId: String, record: FertiliserRecord): List<FertiliserRecord> {
        val updated = loadRecords(vineyardId) + record
        saveRecords(vineyardId, updated)
        return updated.sortedByDescending { it.date }
    }

    fun markCompleted(vineyardId: String, recordId: String, date: String): List<FertiliserRecord> {
        val updated = loadRecords(vineyardId).map {
            if (it.id == recordId) it.copy(status = "completed", date = date) else it
        }
        saveRecords(vineyardId, updated)
        return updated
    }

    fun deleteRecord(vineyardId: String, recordId: String): List<FertiliserRecord> {
        val updated = loadRecords(vineyardId).filterNot { it.id == recordId }
        saveRecords(vineyardId, updated)
        return updated
    }
}
