package com.rork.vinetrack.data.mapalignment

import android.content.Context
import android.util.Log
import androidx.core.content.edit

/**
 * The ONLY place Android Map Alignment state is read from or written to disk.
 *
 * ## Why an abstraction rather than writes from Composables
 *
 * Autosave fires from many places — scope chosen, a point completed, metadata
 * edited, a retake, a re-mark, a deletion, a recalculation. Letting each of
 * those touch `SharedPreferences` directly would scatter the storage key, the
 * version check and the installation-scoping rule across the UI, where the
 * first refactor would quietly break one copy. Everything goes through here, so
 * the format is decided in exactly one file and the screens deal only in
 * domain types.
 *
 * ## Local only
 *
 * Backed by this installation's own `SharedPreferences`. There is deliberately
 * no SQL table, Supabase table, migration, RPC, API endpoint, sync entity,
 * outbox write, Portal record or iOS counterpart. It works with no network and
 * makes no network call of any kind. Data may be lost on uninstall, which is
 * acceptable for a field test: the calibration can be re-walked.
 *
 * Nothing written here is applied to a normal VineTrack map in this phase.
 *
 * ## Fail-soft, never fail-fatal
 *
 * Storage problems must never take the app down in a vineyard. Every read
 * returns a [MapAlignmentStorage.Decoded] outcome rather than throwing, and an
 * unreadable document is reported as
 * [MapAlignmentStorage.Decoded.Unusable] so the operator can remove it — it is
 * never partially adopted and never becomes active. Writes swallow and log
 * their failure rather than propagating: a failed autosave must not interrupt a
 * calibration in progress, and the operator learns about it from the draft not
 * being offered on return, not from a crash mid-walk.
 *
 * ## Installation scoping
 *
 * Every read is filtered by the current `AndroidInstallationIdentity`. A
 * document belonging to another installation is refused rather than adopted,
 * because the installation is part of the calibration's identity.
 */
class MapAlignmentLocalStore(
    context: Context,
    private val installationId: String,
) {

    private val prefs = context.applicationContext
        .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    // --- Draft ------------------------------------------------------------

    /** Read the unfinished calibration for this installation, if any. */
    fun loadDraft(): MapAlignmentStorage.Decoded<MapAlignmentStoredDraft> =
        MapAlignmentStorage.decodeDraft(
            raw = read(KEY_DRAFT),
            installationId = installationId,
        )

    /**
     * Autosave the unfinished calibration.
     *
     * @return true when the bytes were genuinely written. A false result means
     *   the draft is NOT on disk, whatever is still held in memory.
     */
    fun saveDraft(draft: MapAlignmentStoredDraft): Boolean {
        if (draft.draft.scope.androidInstallationId != installationId) {
            Log.w(TAG, "Refusing to save a draft belonging to another installation")
            return false
        }
        return write(KEY_DRAFT, runCatching { MapAlignmentStorage.encodeDraft(draft) }.getOrNull())
    }

    /**
     * Remove the draft.
     *
     * Destructive, and reached only from an explicit confirmed **Delete draft**
     * or **Start over** — never from leaving the wizard. Also used to clear an
     * unreadable document.
     */
    fun deleteDraft(): Boolean = write(KEY_DRAFT, null)

    // --- Completed calibrations -------------------------------------------

    fun loadSavedCalibrations(): MapAlignmentStorage.Decoded<List<MapAlignmentSavedCalibration>> =
        MapAlignmentStorage.decodeCalibrations(
            raw = read(KEY_SAVED),
            installationId = installationId,
        )

    /**
     * Save a completed, reviewed calibration, replacing any earlier entry with
     * the same alignment id.
     *
     * Deliberately does NOT remove the draft: finishing and discarding are
     * separate decisions, and the caller makes the second one explicitly.
     */
    fun saveCalibration(saved: MapAlignmentSavedCalibration): Boolean {
        if (saved.alignment.androidInstallationId != installationId) {
            Log.w(TAG, "Refusing to save a calibration belonging to another installation")
            return false
        }
        val existing = when (val decoded = loadSavedCalibrations()) {
            is MapAlignmentStorage.Decoded.Restored -> decoded.value
            // An unreadable list is replaced rather than appended to: appending
            // to something we could not parse would discard it silently anyway,
            // and this way the new calibration is definitely stored.
            else -> emptyList()
        }
        val merged = existing.filterNot { it.alignment.id == saved.alignment.id } + saved
        return write(
            KEY_SAVED,
            runCatching { MapAlignmentStorage.encodeCalibrations(merged) }.getOrNull(),
        )
    }

    fun deleteCalibration(alignmentId: String): Boolean {
        val existing = when (val decoded = loadSavedCalibrations()) {
            is MapAlignmentStorage.Decoded.Restored -> decoded.value
            else -> return write(KEY_SAVED, null)
        }
        val remaining = existing.filterNot { it.alignment.id == alignmentId }
        return write(
            KEY_SAVED,
            runCatching { MapAlignmentStorage.encodeCalibrations(remaining) }.getOrNull(),
        )
    }

    /** Remove every locally stored Map Alignment record for this installation. */
    fun deleteEverything(): Boolean {
        val draftCleared = write(KEY_DRAFT, null)
        val savedCleared = write(KEY_SAVED, null)
        return draftCleared && savedCleared
    }

    // --- Raw access -------------------------------------------------------

    private fun read(key: String): String? = runCatching { prefs.getString(key, null) }
        .onFailure { Log.w(TAG, "Could not read $key: ${it.javaClass.simpleName}") }
        .getOrNull()

    /** @param value null removes the entry. Returns whether the commit succeeded. */
    private fun write(key: String, value: String?): Boolean = runCatching {
        prefs.edit(commit = true) {
            if (value == null) remove(key) else putString(key, value)
        }
        true
    }.onFailure {
        // Never rethrow: a storage failure must not end a calibration walk.
        Log.w(TAG, "Could not write $key: ${it.javaClass.simpleName}")
    }.getOrDefault(false)

    private companion object {
        const val PREFERENCES_NAME = "vinetrack_map_alignment"
        const val KEY_DRAFT = "draft_v1"
        const val KEY_SAVED = "saved_calibrations_v1"
        const val TAG = "MapAlignmentStore"
    }
}
