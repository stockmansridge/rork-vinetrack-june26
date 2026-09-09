package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.model.CompletedPhotoCacheEntry
import com.rork.vinetrack.data.model.PendingPhotoAttachment
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Local persistence for pending pin-photo attachments (Stage 7B — local
 * persistence only).
 *
 * Backs the attachment list with a single JSON blob in SharedPreferences,
 * following the same lightweight local-only pattern as [PendingWriteStore] /
 * [DomainCacheStore]. It is deliberately separate from those stores: photos
 * have their own lifecycle (a copied local file + upload retry later) and
 * mixing them into the write outbox would blur that boundary. Room + KSP were
 * avoided for the same reasons as the rest of the offline plumbing — the list
 * is small and append/replace mostly.
 *
 * This store is intentionally low-level (whole-list read/replace). All callers
 * must go through [PendingPhotoRepository]; nothing should touch this directly.
 * The compressed JPEG bytes themselves live in app-private files, not here —
 * this store only persists the metadata rows.
 */
interface PendingPhotoStoring {
    fun load(): List<PendingPhotoAttachment>
    fun save(attachments: List<PendingPhotoAttachment>)
    fun loadCompletedCache(): List<CompletedPhotoCacheEntry>
    fun saveCompletedCache(entries: List<CompletedPhotoCacheEntry>)
    fun clear()
}

class PendingPhotoStore(context: Context) : PendingPhotoStoring {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_pending_photos", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val serializer = ListSerializer(PendingPhotoAttachment.serializer())
    private val cacheSerializer = ListSerializer(CompletedPhotoCacheEntry.serializer())

    /** Read all persisted attachments (empty list on first run or parse error). */
    override fun load(): List<PendingPhotoAttachment> {
        val raw = prefs.getString(KEY_PHOTOS, null) ?: return emptyList()
        return runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
    }

    /** Persist the full attachment list, replacing any previous contents. */
    override fun save(attachments: List<PendingPhotoAttachment>) {
        val encoded = json.encodeToString(serializer, attachments)
        check(prefs.edit().putString(KEY_PHOTOS, encoded).commit()) {
            "Couldn't persist pending photo metadata."
        }
    }

    override fun loadCompletedCache(): List<CompletedPhotoCacheEntry> {
        val raw = prefs.getString(KEY_COMPLETED_CACHE, null) ?: return emptyList()
        return runCatching { json.decodeFromString(cacheSerializer, raw) }.getOrDefault(emptyList())
    }

    override fun saveCompletedCache(entries: List<CompletedPhotoCacheEntry>) {
        val encoded = json.encodeToString(cacheSerializer, entries)
        check(prefs.edit().putString(KEY_COMPLETED_CACHE, encoded).commit()) {
            "Couldn't persist offline photo cache metadata."
        }
    }

    /** Clear the entire attachment list (used by tooling / future sign-out cleanup). */
    override fun clear() {
        check(prefs.edit().remove(KEY_PHOTOS).remove(KEY_COMPLETED_CACHE).commit()) {
            "Couldn't clear pending photo metadata."
        }
    }

    private companion object {
        const val KEY_PHOTOS = "pending_photos_json"
        const val KEY_COMPLETED_CACHE = "completed_photo_cache_json"
    }
}
