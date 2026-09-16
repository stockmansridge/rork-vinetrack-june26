package com.rork.vinetrack.data.mapalignment

/**
 * Key/value bytes on one device. The only part of local storage that is
 * platform-specific.
 *
 * Deliberately tiny: everything that can be got WRONG — versioning,
 * installation scoping, what replaces what, what survives a delete — lives in
 * [MapAlignmentRecordStore] above this, where it is pure and directly testable.
 * An Android `SharedPreferences` file and an in-memory map are then genuinely
 * interchangeable, so the rules that protect a vineyard walk are verified by
 * real assertions rather than by driving a screen.
 */
interface MapAlignmentRawStore {
    /** @return the stored value, or null when absent or unreadable. */
    fun read(key: String): String?

    /** @param value null removes the entry. @return whether it was committed. */
    fun write(key: String, value: String?): Boolean
}

/**
 * The local Map Alignment record rules: what is stored, what replaces what, and
 * what a delete is allowed to take with it.
 *
 * ## The two records are independent
 *
 * The unfinished [MapAlignmentStoredDraft] and the completed
 * [MapAlignmentSavedCalibration] list live under separate keys and are written
 * separately. That independence is the safety property this class exists to
 * guarantee:
 *
 * * an in-progress recalibration can NEVER destroy the calibration already
 *   saved for that scope — only an explicit, successful replacement does;
 * * deleting a draft never touches a saved calibration;
 * * deleting a saved calibration never silently removes an active draft.
 *
 * Each of those is a case where the operator would otherwise lose a walk around
 * a vineyard to a side effect they did not ask for.
 *
 * ## Local only
 *
 * No SQL, Supabase table, migration, RPC, API endpoint, sync entity, outbox,
 * Portal record or iOS file. Nothing here is read by any production map — see
 * [MapAlignmentResolver].
 */
class MapAlignmentRecordStore(
    private val raw: MapAlignmentRawStore,
    private val installationId: String,
) {

    // --- Draft ------------------------------------------------------------

    fun loadDraft(): MapAlignmentStorage.Decoded<MapAlignmentStoredDraft> =
        MapAlignmentStorage.decodeDraft(raw.read(KEY_DRAFT), installationId)

    /**
     * Autosave the unfinished calibration.
     *
     * @return true when the bytes were genuinely written. False means the draft
     *   is NOT on disk, whatever is still held in memory — callers must not
     *   treat an in-memory value as proof of persistence.
     */
    fun saveDraft(draft: MapAlignmentStoredDraft): Boolean {
        if (draft.draft.scope.androidInstallationId != installationId) return false
        return raw.write(
            KEY_DRAFT,
            runCatching { MapAlignmentStorage.encodeDraft(draft) }.getOrNull(),
        )
    }

    /**
     * Remove the draft, and ONLY the draft.
     *
     * Reached from an explicit confirmed Delete draft or Start over, or after a
     * completed calibration has been successfully saved. Never from leaving the
     * wizard.
     */
    fun deleteDraft(): Boolean = raw.write(KEY_DRAFT, null)

    // --- Completed calibrations -------------------------------------------

    fun loadSavedCalibrations(): MapAlignmentStorage.Decoded<List<MapAlignmentSavedCalibration>> =
        MapAlignmentStorage.decodeCalibrations(raw.read(KEY_SAVED), installationId)

    /** The saved calibrations, or an empty list when absent or unreadable. */
    fun savedCalibrationsOrEmpty(): List<MapAlignmentSavedCalibration> =
        when (val decoded = loadSavedCalibrations()) {
            is MapAlignmentStorage.Decoded.Restored -> decoded.value
            else -> emptyList()
        }

    /** The calibration currently saved for exactly [scope], if any. */
    fun savedFor(scope: MapAlignmentScope): MapAlignmentSavedCalibration? =
        MapAlignmentSaveFlow.existingFor(savedCalibrationsOrEmpty(), scope)

    /**
     * Save a completed, reviewed calibration, replacing any earlier one for the
     * SAME exact scope.
     *
     * Deliberately does NOT remove the draft. Saving and discarding the working
     * copy are separate decisions, and the second must only happen once this
     * one has genuinely succeeded — see [MapAlignmentSaveFlow.mayRemoveDraft].
     */
    fun saveCalibration(saved: MapAlignmentSavedCalibration): Boolean {
        if (saved.alignment.androidInstallationId != installationId) return false
        val merged = MapAlignmentSaveFlow.merge(savedCalibrationsOrEmpty(), saved)
        return raw.write(
            KEY_SAVED,
            runCatching { MapAlignmentStorage.encodeCalibrations(merged) }.getOrNull(),
        )
    }

    /**
     * Remove one saved calibration by alignment id.
     *
     * Exact-id only, and the draft is untouched: an operator deleting a saved
     * result must not silently lose the recalibration they are part-way through
     * collecting to replace it.
     */
    fun deleteCalibration(alignmentId: String): Boolean {
        val remaining = savedCalibrationsOrEmpty().filterNot { it.alignment.id == alignmentId }
        return raw.write(
            KEY_SAVED,
            runCatching { MapAlignmentStorage.encodeCalibrations(remaining) }.getOrNull(),
        )
    }

    /** Remove every locally stored Map Alignment record for this installation. */
    fun deleteEverything(): Boolean {
        val draftCleared = raw.write(KEY_DRAFT, null)
        val savedCleared = raw.write(KEY_SAVED, null)
        return draftCleared && savedCleared
    }

    companion object {
        const val KEY_DRAFT: String = "draft_v1"
        const val KEY_SAVED: String = "saved_calibrations_v1"
    }
}
