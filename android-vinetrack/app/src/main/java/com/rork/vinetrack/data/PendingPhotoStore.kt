package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
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
class PendingPhotoStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_pending_photos", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val serializer = ListSerializer(PendingPhotoAttachment.serializer())

    /** Read all persisted attachments (empty list on first run or parse error). */
    fun load(): List<PendingPhotoAttachment> {
        val raw = prefs.getString(KEY_PHOTOS, null) ?: return emptyList()
        return runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
    }

    /** Persist the full attachment list, replacing any previous contents. */
    fun save(attachments: List<PendingPhotoAttachment>) {
        prefs.edit { putString(KEY_PHOTOS, json.encodeToString(serializer, attachments)) }
    }

    /** Clear the entire attachment list (used by tooling / future sign-out cleanup). */
    fun clear() {
        prefs.edit { remove(KEY_PHOTOS) }
    }

    private companion object {
        const val KEY_PHOTOS = "pending_photos_json"
    }
}
