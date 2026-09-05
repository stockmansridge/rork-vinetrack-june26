package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.PendingWrite
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Local persistence for the pending-write outbox (Stage 4A-ii — skeleton only).
 *
 * Backs the outbox with a single JSON blob in SharedPreferences, following the
 * same lightweight local-only pattern as [CanopyWaterRatesStore] /
 * [OperationPrefsStore]. Room + KSP were deliberately avoided for this slice:
 * the outbox is small, append/replace mostly, and adding a database toolchain
 * is disproportionate for plumbing that no write path uses yet.
 *
 * This store is intentionally low-level (whole-list read/replace). All callers
 * must go through [PendingWriteRepository]; nothing should touch this directly.
 */
class PendingWriteStore(context: Context) : PendingWriteStoring {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_pending_writes", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val serializer = ListSerializer(PendingWrite.serializer())

    /** Read all persisted pending writes (empty list on first run or parse error). */
    override fun load(): List<PendingWrite> {
        val raw = prefs.getString(KEY_WRITES, null) ?: return emptyList()
        return runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
    }

    /** Persist the full outbox, replacing any previous contents. */
    override fun save(writes: List<PendingWrite>): Boolean =
        prefs.edit().putString(KEY_WRITES, json.encodeToString(serializer, writes)).commit()

    /** Clear the entire outbox (used by tooling / future sign-out cleanup). */
    override fun clear(): Boolean = prefs.edit().remove(KEY_WRITES).commit()

    private companion object {
        const val KEY_WRITES = "pending_writes_json"
    }
}
