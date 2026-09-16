package com.rork.vinetrack.data.mapalignment

/**
 * Key/value bytes on one device. The only part of local storage that is
 * platform-specific.
 *
 * Deliberately tiny: everything that can be got WRONG — versioning,
 * installation scoping, what replaces what, what survives a delete — lives in
 * [MapAlignmentRecordStore] below this, where it is pure and directly testable.
 * An Android `SharedPreferences` file and an in-memory map are then genuinely
 * interchangeable, so the rules that protect a vineyard walk are verified by
 * real assertions rather than by driving a screen.
 *
 * ## Why writing and removing are separate operations
 *
 * They were once one `write(key, value: String?)` where null meant "remove".
 * That signature made a serialization failure indistinguishable from a
 * deliberate deletion: the call site read
 * `write(KEY, runCatching { encode(...) }.getOrNull())`, so an encoding
 * exception produced null, and null erased the very record the app was trying
 * to protect. A failed save became a delete — the worst possible outcome for
 * four walked reference points, and one no test could see because the two
 * intentions shared an argument.
 *
 * [write] now takes a non-null [String] and [remove] is a separate, explicit
 * operation. Removal is therefore something a caller has to ASK for, and no
 * amount of encoding failure can produce it.
 */
interface MapAlignmentRawStore {
    /** @return the stored value, or null when absent or unreadable. */
    fun read(key: String): String?

    /**
     * Store [value] under [key].
     *
     * @return whether it was genuinely committed. False means the bytes are
     *   NOT on disk, and callers must treat any in-memory copy as unsaved.
     */
    fun write(key: String, value: String): Boolean

    /** Delete [key]. Only ever called from an explicit deletion path. */
    fun remove(key: String): Boolean
}

/**
 * Turns records into the bytes that get stored.
 *
 * Injectable purely so encoding FAILURE is testable. The safety rule that
 * matters most here — a failed encode must never reach the raw store, because
 * reaching it once meant deletion — cannot be verified against a codec that
 * always succeeds. Production uses [MapAlignmentJsonEncoder]; tests supply one
 * that throws.
 */
interface MapAlignmentEncoder {
    fun encodeDraft(draft: MapAlignmentStoredDraft): String

    fun encodeCalibrations(saved: List<MapAlignmentSavedCalibration>): String
}

/** The real codec: the versioned documents in [MapAlignmentStorage]. */
object MapAlignmentJsonEncoder : MapAlignmentEncoder {
    override fun encodeDraft(draft: MapAlignmentStoredDraft): String =
        MapAlignmentStorage.encodeDraft(draft)

    override fun encodeCalibrations(saved: List<MapAlignmentSavedCalibration>): String =
        MapAlignmentStorage.encodeCalibrations(saved)
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
 * * deleting a saved calibration never silently removes an active draft;
 * * unreadable bytes under one key never cost the operator the other key.
 *
 * Each of those is a case where the operator would otherwise lose a walk around
 * a vineyard to a side effect they did not ask for.
 *
 * ## Encode first, write second, and never write null
 *
 * Every write here encodes BEFORE touching storage and abandons the write
 * entirely if encoding fails. A failure returns false and leaves the previous
 * bytes exactly where they were, so the worst case is "your latest change is
 * not saved" rather than "your existing record is gone".
 *
 * ## Unreadable bytes are refused, not overwritten
 *
 * When the saved-calibration key cannot be decoded, saving and deleting are
 * REFUSED rather than performed on an assumed-empty list. Both would otherwise
 * silently destroy a record the app simply failed to understand — a save by
 * overwriting it, a delete by rewriting the list it could not read as empty.
 * Removal requires [removeUnreadableSavedCalibrations], which the operator has
 * to choose.
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
    private val encoder: MapAlignmentEncoder = MapAlignmentJsonEncoder,
) {

    // --- Draft ------------------------------------------------------------

    fun loadDraft(): MapAlignmentStorage.Decoded<MapAlignmentStoredDraft> =
        MapAlignmentStorage.decodeDraft(raw.read(KEY_DRAFT), installationId)

    /**
     * Autosave the unfinished calibration.
     *
     * Encodes first. If encoding fails, storage is not touched at all and this
     * returns false — an unwritable change must never remove the last draft
     * that WAS writable.
     *
     * @return true when the bytes were genuinely written. False means the draft
     *   is NOT on disk, whatever is still held in memory — callers must not
     *   treat an in-memory value as proof of persistence.
     */
    fun saveDraft(draft: MapAlignmentStoredDraft): Boolean {
        if (draft.draft.scope.androidInstallationId != installationId) return false
        val encoded = runCatching { encoder.encodeDraft(draft) }.getOrNull() ?: return false
        return raw.write(KEY_DRAFT, encoded)
    }

    /**
     * Remove the draft, and ONLY the draft.
     *
     * Reached from an explicit confirmed Delete draft or Start over, or after a
     * completed calibration has been successfully saved. Never from leaving the
     * wizard, and never from a failed write.
     */
    fun deleteDraft(): Boolean = raw.remove(KEY_DRAFT)

    // --- Completed calibrations -------------------------------------------

    /**
     * The authoritative read. Preserves
     * [MapAlignmentStorage.Decoded.Unusable] so unreadable bytes can be
     * reported to the operator instead of looking like "no saved
     * calibrations".
     */
    fun loadSavedCalibrations(): MapAlignmentStorage.Decoded<List<MapAlignmentSavedCalibration>> =
        MapAlignmentStorage.decodeCalibrations(raw.read(KEY_SAVED), installationId)

    /**
     * The readable saved calibrations, treating unreadable storage as empty.
     *
     * Convenience for DISPLAY only. It is deliberately not used to decide
     * whether anything may be written: collapsing Unusable into an empty list
     * is exactly how unreadable bytes get silently overwritten, so
     * [saveCalibration] and [deleteCalibration] consult
     * [loadSavedCalibrations] instead.
     */
    fun savedCalibrationsOrEmpty(): List<MapAlignmentSavedCalibration> =
        when (val decoded = loadSavedCalibrations()) {
            is MapAlignmentStorage.Decoded.Restored -> decoded.value
            else -> emptyList()
        }

    /** True when saved-calibration bytes exist but cannot be decoded. */
    fun isSavedStorageUnusable(): Boolean =
        loadSavedCalibrations() is MapAlignmentStorage.Decoded.Unusable

    /** The calibration currently saved for exactly [scope], if any. */
    fun savedFor(scope: MapAlignmentScope): MapAlignmentSavedCalibration? =
        MapAlignmentSaveFlow.existingFor(savedCalibrationsOrEmpty(), scope)

    /**
     * Save a completed, reviewed calibration, replacing any earlier one for the
     * SAME exact scope.
     *
     * Refused when the existing saved bytes are unreadable: overwriting a
     * record the app could not decode would destroy it on the operator's
     * behalf without their ever being told it existed. They remove it
     * deliberately, via [removeUnreadableSavedCalibrations], or not at all.
     *
     * Deliberately does NOT remove the draft. Saving and discarding the working
     * copy are separate decisions, and the second must only happen once this
     * one has genuinely succeeded — see [MapAlignmentSaveFlow.mayRemoveDraft].
     */
    fun saveCalibration(saved: MapAlignmentSavedCalibration): Boolean {
        if (saved.alignment.androidInstallationId != installationId) return false
        val existing = when (val decoded = loadSavedCalibrations()) {
            is MapAlignmentStorage.Decoded.Restored -> decoded.value
            MapAlignmentStorage.Decoded.Empty -> emptyList()
            // Unreadable: refuse rather than overwrite.
            is MapAlignmentStorage.Decoded.Unusable -> return false
        }
        val merged = MapAlignmentSaveFlow.merge(existing, saved)
        val encoded = runCatching { encoder.encodeCalibrations(merged) }.getOrNull() ?: return false
        return raw.write(KEY_SAVED, encoded)
    }

    /**
     * Remove one saved calibration by alignment id.
     *
     * Exact-id only, and the draft is untouched: an operator deleting a saved
     * result must not silently lose the recalibration they are part-way through
     * collecting to replace it.
     *
     * Refused when the list cannot be read, because rewriting an undecodable
     * list would turn "unreadable" into "empty" and delete records nobody
     * chose to delete. It is also refused if re-encoding the REMAINING entries
     * fails, so a bad encode cannot clear the whole list either.
     */
    fun deleteCalibration(alignmentId: String): Boolean {
        val decoded = loadSavedCalibrations()
        val existing = when (decoded) {
            is MapAlignmentStorage.Decoded.Restored -> decoded.value
            MapAlignmentStorage.Decoded.Empty -> return true
            is MapAlignmentStorage.Decoded.Unusable -> return false
        }
        val remaining = existing.filterNot { it.alignment.id == alignmentId }
        if (remaining.size == existing.size) return true
        if (remaining.isEmpty()) return raw.remove(KEY_SAVED)
        val encoded = runCatching { encoder.encodeCalibrations(remaining) }.getOrNull()
            ?: return false
        return raw.write(KEY_SAVED, encoded)
    }

    /**
     * Discard saved-calibration bytes that cannot be decoded.
     *
     * The one deliberate way past [saveCalibration]'s refusal, reached only
     * from the System Admin "Remove unreadable saved data" action. The draft is
     * untouched: a readable draft must still be resumable after this.
     */
    fun removeUnreadableSavedCalibrations(): Boolean = raw.remove(KEY_SAVED)

    /** Remove every locally stored Map Alignment record for this installation. */
    fun deleteEverything(): Boolean {
        val draftCleared = raw.remove(KEY_DRAFT)
        val savedCleared = raw.remove(KEY_SAVED)
        return draftCleared && savedCleared
    }

    companion object {
        const val KEY_DRAFT: String = "draft_v1"
        const val KEY_SAVED: String = "saved_calibrations_v1"
    }
}
