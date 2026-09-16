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
 * edited, a retake, a re-mark, a deletion, a recalculation, a completed save.
 * Letting each of those touch `SharedPreferences` directly would scatter the
 * storage key, the version check, the installation-scoping rule and the
 * replacement semantics across the UI, where the first refactor would quietly
 * break one copy. Everything goes through here, so the format is decided in one
 * place and the screens deal only in domain types.
 *
 * ## Structure
 *
 * This class is deliberately thin. It owns only the Android-specific part —
 * which `SharedPreferences` file, and how a failed commit is logged. Every rule
 * that could be got dangerously wrong lives in [MapAlignmentRecordStore], which
 * is pure and directly testable: what replaces what, what a delete is allowed
 * to take with it, and the guarantee that an in-progress recalibration can
 * never destroy an already-saved calibration.
 *
 * ## Local only
 *
 * Backed by this installation's own `SharedPreferences`. There is deliberately
 * no SQL table, Supabase table, migration, RPC, API endpoint, sync entity,
 * outbox write, Portal record or iOS counterpart. It works with no network and
 * makes no network call of any kind. Data may be lost on uninstall, which is
 * acceptable for a field test: the calibration can be re-walked.
 *
 * Nothing written here is applied to a normal VineTrack map in this phase — see
 * [MapAlignmentResolver], which is not fed from storage.
 *
 * ## Fail-soft, never fail-fatal
 *
 * Storage problems must never take the app down in a vineyard. Every read
 * returns a [MapAlignmentStorage.Decoded] outcome rather than throwing, and an
 * unreadable document is reported as [MapAlignmentStorage.Decoded.Unusable] so
 * the operator can remove it — never partially adopted, never active. Writes
 * report failure by returning false rather than propagating, and callers treat
 * false as "this is NOT on disk": in particular a completed save that fails
 * leaves the draft in place, so a vineyard walk is never traded for a write
 * that did not happen.
 */
class MapAlignmentLocalStore(
    context: Context,
    installationId: String,
) {

    private val prefs = context.applicationContext
        .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private val records = MapAlignmentRecordStore(
        raw = object : MapAlignmentRawStore {
            override fun read(key: String): String? =
                runCatching { prefs.getString(key, null) }
                    .onFailure { Log.w(TAG, "Could not read $key: ${it.javaClass.simpleName}") }
                    .getOrNull()

            override fun write(key: String, value: String?): Boolean = runCatching {
                prefs.edit(commit = true) {
                    if (value == null) remove(key) else putString(key, value)
                }
                true
            }.onFailure {
                // Never rethrow: a storage failure must not end a calibration walk.
                Log.w(TAG, "Could not write $key: ${it.javaClass.simpleName}")
            }.getOrDefault(false)
        },
        installationId = installationId,
    )

    // --- Draft ------------------------------------------------------------

    /** Read the unfinished calibration for this installation, if any. */
    fun loadDraft(): MapAlignmentStorage.Decoded<MapAlignmentStoredDraft> = records.loadDraft()

    /**
     * Autosave the unfinished calibration.
     *
     * @return true when the bytes were genuinely written. A false result means
     *   the draft is NOT on disk, whatever is still held in memory.
     */
    fun saveDraft(draft: MapAlignmentStoredDraft): Boolean = records.saveDraft(draft)

    /**
     * Remove the draft, and only the draft.
     *
     * Reached from an explicit confirmed **Delete draft** or **Start over**, or
     * after a completed calibration has been successfully saved — never from
     * leaving the wizard. Any saved calibration is untouched.
     */
    fun deleteDraft(): Boolean = records.deleteDraft()

    // --- Completed calibrations -------------------------------------------

    fun loadSavedCalibrations(): MapAlignmentStorage.Decoded<List<MapAlignmentSavedCalibration>> =
        records.loadSavedCalibrations()

    /** The saved calibrations, or empty when absent or unreadable. */
    fun savedCalibrationsOrEmpty(): List<MapAlignmentSavedCalibration> =
        records.savedCalibrationsOrEmpty()

    /** The calibration currently saved for exactly [scope], if any. */
    fun savedFor(scope: MapAlignmentScope): MapAlignmentSavedCalibration? = records.savedFor(scope)

    /**
     * Save a completed, reviewed calibration, replacing any earlier one for the
     * same exact scope. Deliberately does NOT remove the draft.
     */
    fun saveCalibration(saved: MapAlignmentSavedCalibration): Boolean =
        records.saveCalibration(saved)

    /** Remove one saved calibration. Any active draft is untouched. */
    fun deleteCalibration(alignmentId: String): Boolean = records.deleteCalibration(alignmentId)

    /** Remove every locally stored Map Alignment record for this installation. */
    fun deleteEverything(): Boolean = records.deleteEverything()

    private companion object {
        const val PREFERENCES_NAME = "vinetrack_map_alignment"
        const val TAG = "MapAlignmentStore"
    }
}
