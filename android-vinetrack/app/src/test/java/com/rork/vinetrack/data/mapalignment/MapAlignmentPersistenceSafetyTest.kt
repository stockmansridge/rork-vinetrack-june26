package com.rork.vinetrack.data.mapalignment

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The ways local storage could destroy work while appearing to protect it.
 *
 * Every case here is a failure being MISREPORTED rather than a failure
 * happening: an encoding exception that deleted the record it could not write,
 * a commit result that was hardcoded true, and unreadable bytes that looked
 * like "nothing saved" and were then overwritten. A vineyard walk is only as
 * safe as the honesty of these three answers.
 */
class MapAlignmentPersistenceSafetyTest {

    private val installation = "install-a"
    private val scope = MapAlignmentScope(installation, "vineyard-1")
    private val origin = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    /**
     * In-memory bytes that records every call.
     *
     * [removedKeys] is the point: it lets a test assert that a failed encode
     * never even ASKED for a deletion, which is stronger than observing that
     * the value happened to survive.
     */
    private class RecordingRawStore : MapAlignmentRawStore {
        val values = mutableMapOf<String, String>()
        val writtenKeys = mutableListOf<String>()
        val removedKeys = mutableListOf<String>()
        var failWrites: Boolean = false

        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String): Boolean {
            writtenKeys += key
            if (failWrites) return false
            values[key] = value
            return true
        }

        override fun remove(key: String): Boolean {
            removedKeys += key
            values.remove(key)
            return true
        }
    }

    /** Fails on demand, standing in for a serialization defect. */
    private class BreakableEncoder(
        var failDraft: Boolean = false,
        var failCalibrations: Boolean = false,
    ) : MapAlignmentEncoder {
        override fun encodeDraft(draft: MapAlignmentStoredDraft): String {
            if (failDraft) error("draft encoding failed")
            return MapAlignmentJsonEncoder.encodeDraft(draft)
        }

        override fun encodeCalibrations(saved: List<MapAlignmentSavedCalibration>): String {
            if (failCalibrations) error("calibration encoding failed")
            return MapAlignmentJsonEncoder.encodeCalibrations(saved)
        }
    }

    private val raw = RecordingRawStore()
    private val encoder = BreakableEncoder()
    private val store = MapAlignmentRecordStore(
        raw = raw,
        installationId = installation,
        encoder = encoder,
    )

    private fun shift(
        from: CanonicalCoordinate,
        eastMetres: Double,
        northMetres: Double,
    ): CanonicalCoordinate {
        if (eastMetres == 0.0 && northMetres == 0.0) return from
        val display = from.toDisplay(
            MapAlignment(
                id = "fixture",
                scope = scope,
                eastOffsetMetres = eastMetres,
                northOffsetMetres = northMetres,
                isEnabled = true,
            ),
        )
        return CanonicalCoordinate(display.latitude, display.longitude)
    }

    private fun point(index: Int, scope: MapAlignmentScope = this.scope): MapAlignmentReferencePoint {
        val canonical = shift(origin, index * 60.0, if (index % 2 == 0) 0.0 else 55.0)
        val marked = shift(canonical, 9.0, 0.0)
        return MapAlignmentReferencePoint(
            id = "p$index",
            scope = scope,
            canonicalCoordinate = canonical,
            selectedMapCoordinate = AndroidDisplayCoordinate(marked.latitude, marked.longitude),
            gpsAccuracyMetres = 2.4,
            gpsEvidence = MapAlignmentGpsEvidence(
                sampleCount = 6,
                samplingDurationMillis = 14_000L,
                representativeAccuracyMetres = 2.4,
                worstAccuracyMetres = 3.9,
                stabilityRadiusMetres = 1.8,
            ),
            capturedAtEpochMillis = 1_757_000_000_000 + index,
        )
    }

    private fun draft(pointCount: Int, scope: MapAlignmentScope = this.scope): MapAlignmentDraft {
        var draft = MapAlignmentDraft(scope = scope, vineyardName = "Stockmans Ridge")
        repeat(pointCount) { draft = draft.withReferencePoint(point(it, scope)) }
        return draft
    }

    private fun storedDraft(pointCount: Int) = MapAlignmentStoredDraft(
        draft = draft(pointCount),
        step = MapAlignmentWizardStep.Capture,
        updatedAtEpochMillis = 1_757_100_000_000,
    )

    private fun savedRecord(
        scope: MapAlignmentScope = this.scope,
        alignmentId: String = "saved-1",
    ): MapAlignmentSavedCalibration {
        val solved = draft(4, scope).solved(alignmentId = alignmentId, nowEpochMillis = 1L)
        return MapAlignmentSaveFlow.savedFrom(
            draft = solved,
            solution = solved.solution!!,
            nowEpochMillis = 1_757_200_000_000,
        )
    }

    // --- 1. A failed encode is never a deletion ---------------------------

    @Test
    fun `a failed draft encode does not remove the existing draft`() {
        assertTrue(store.saveDraft(storedDraft(3)))

        encoder.failDraft = true
        val result = store.saveDraft(storedDraft(4))

        assertFalse("an unwritable change must report failure", result)
        assertTrue(
            "encoding failure must never reach a deletion — that is how a " +
                "failed save became a delete",
            raw.removedKeys.isEmpty(),
        )
        encoder.failDraft = false
        val restored = store.loadDraft() as MapAlignmentStorage.Decoded.Restored
        assertEquals("the previously saved draft is untouched", 3, restored.value.pointCount)
    }

    @Test
    fun `a failed draft encode does not even attempt a write`() {
        encoder.failDraft = true

        assertFalse(store.saveDraft(storedDraft(2)))

        // Encode first, write second. Nothing reaches storage at all.
        assertTrue(raw.writtenKeys.isEmpty())
        assertTrue(raw.removedKeys.isEmpty())
    }

    @Test
    fun `a failed calibration encode does not remove existing saved calibrations`() {
        assertTrue(store.saveCalibration(savedRecord(alignmentId = "saved-original")))

        encoder.failCalibrations = true
        val result = store.saveCalibration(
            savedRecord(
                scope = MapAlignmentScope(installation, "vineyard-2"),
                alignmentId = "saved-new",
            ),
        )

        assertFalse(result)
        assertTrue(raw.removedKeys.isEmpty())
        encoder.failCalibrations = false
        val remaining = store.savedCalibrationsOrEmpty()
        assertEquals(1, remaining.size)
        assertEquals("saved-original", remaining.single().alignment.id)
    }

    @Test
    fun `a failed rewrite while deleting leaves the whole list intact`() {
        assertTrue(store.saveCalibration(savedRecord(alignmentId = "keep-me")))
        assertTrue(
            store.saveCalibration(
                savedRecord(
                    scope = MapAlignmentScope(installation, "vineyard-2"),
                    alignmentId = "remove-me",
                ),
            ),
        )

        // Re-encoding the survivors fails part-way through the delete.
        encoder.failCalibrations = true
        val result = store.deleteCalibration("remove-me")

        assertFalse("a failed rewrite must be reported as failed", result)
        assertTrue("and must not clear the key", raw.removedKeys.isEmpty())

        encoder.failCalibrations = false
        val remaining = store.savedCalibrationsOrEmpty().map { it.alignment.id }.sorted()
        assertEquals(
            "one delete that cannot be written must not cost the operator both",
            listOf("keep-me", "remove-me"),
            remaining,
        )
    }

    @Test
    fun `a failed raw write is reported and changes nothing`() {
        assertTrue(store.saveDraft(storedDraft(3)))

        raw.failWrites = true
        assertFalse(store.saveDraft(storedDraft(4)))

        raw.failWrites = false
        val restored = store.loadDraft() as MapAlignmentStorage.Decoded.Restored
        assertEquals(3, restored.value.pointCount)
    }

    @Test
    fun `only explicit deletion paths remove anything`() {
        store.saveDraft(storedDraft(3))
        store.saveCalibration(savedRecord())
        assertTrue(raw.removedKeys.isEmpty())

        store.deleteDraft()
        assertEquals(listOf(MapAlignmentRecordStore.KEY_DRAFT), raw.removedKeys)
    }

    @Test
    fun `the raw write contract cannot express a deletion`() {
        // Removal used to be `write(key, null)`, which made a failed encode
        // indistinguishable from a deliberate delete. The types now forbid it.
        val write = MapAlignmentRawStore::class.java.methods.first { it.name == "write" }

        assertEquals(String::class.java, write.parameterTypes[1])
        assertTrue(
            MapAlignmentRawStore::class.java.methods.any { it.name == "remove" },
        )
    }

    // --- 2. The commit result must be real --------------------------------

    @Test
    fun `the android store returns the editors own commit result`() {
        val source = File(
            "src/main/java/com/rork/vinetrack/data/mapalignment/MapAlignmentLocalStore.kt",
        ).readText()

        // SharedPreferences cannot be exercised on the JVM cheaply, so the
        // contract is source-checked. `apply()` would be unusable here: the
        // save flow spends this boolean on deleting a draft holding a whole
        // vineyard walk, so a hopeful true is a data-loss bug.
        assertTrue("must call commit()", source.contains("editor.commit()"))
        assertFalse("must not use apply()", source.contains(".apply()"))
        assertFalse(
            "must not use the commit = true extension, whose result is discarded",
            source.contains("edit(commit = true)"),
        )
        // The only `true` allowed is inside getOrDefault(false)-style handling,
        // never as a standalone returned literal after a write.
        assertFalse(
            "must not return an unconditional true after writing",
            source.contains("putString(key, value)\n                }\n                true"),
        )
    }

    // --- 4. Unreadable completed storage is surfaced, not assumed empty ----

    private fun unusableStore(stored: String): MapAlignmentRecordStore {
        val backing = RecordingRawStore()
        backing.values[MapAlignmentRecordStore.KEY_SAVED] = stored
        return MapAlignmentRecordStore(raw = backing, installationId = installation)
    }

    @Test
    fun `an unsupported saved storage version surfaces as unusable`() {
        val future = """{"storage_version":99,"calibrations":[]}"""

        val decoded = unusableStore(future).loadSavedCalibrations()

        assertTrue(decoded is MapAlignmentStorage.Decoded.Unusable)
        assertTrue((decoded as MapAlignmentStorage.Decoded.Unusable).reason.contains("99"))
    }

    @Test
    fun `a malformed saved list surfaces as unusable`() {
        val decoded = unusableStore("{ this is not json").loadSavedCalibrations()

        assertTrue(decoded is MapAlignmentStorage.Decoded.Unusable)
    }

    @Test
    fun `unreadable saved storage is not reported as no saved calibrations`() {
        val unreadable = unusableStore("""{"storage_version":99,"calibrations":[]}""")

        // The convenience accessor still flattens for display, but the
        // authoritative load — and the flag the UI uses — say "unreadable".
        assertTrue(unreadable.isSavedStorageUnusable())
        assertTrue(
            unreadable.loadSavedCalibrations() is MapAlignmentStorage.Decoded.Unusable,
        )
    }

    @Test
    fun `a normal save cannot overwrite unreadable saved storage`() {
        val backing = RecordingRawStore()
        val bytes = """{"storage_version":99,"calibrations":[]}"""
        backing.values[MapAlignmentRecordStore.KEY_SAVED] = bytes
        val blocked = MapAlignmentRecordStore(raw = backing, installationId = installation)

        val result = blocked.saveCalibration(savedRecord())

        assertFalse("saving over undecodable bytes must be refused", result)
        assertEquals(
            "the unreadable bytes are left exactly as they were",
            bytes,
            backing.values[MapAlignmentRecordStore.KEY_SAVED],
        )
    }

    @Test
    fun `deleting one calibration cannot turn an unreadable list into an empty one`() {
        val backing = RecordingRawStore()
        val bytes = """{"storage_version":99,"calibrations":[]}"""
        backing.values[MapAlignmentRecordStore.KEY_SAVED] = bytes
        val blocked = MapAlignmentRecordStore(raw = backing, installationId = installation)

        val result = blocked.deleteCalibration("saved-1")

        assertFalse(result)
        assertEquals(bytes, backing.values[MapAlignmentRecordStore.KEY_SAVED])
        assertTrue(backing.removedKeys.isEmpty())
    }

    @Test
    fun `explicit removal clears unreadable saved data and keeps a valid draft`() {
        val backing = RecordingRawStore()
        backing.values[MapAlignmentRecordStore.KEY_SAVED] =
            """{"storage_version":99,"calibrations":[]}"""
        val recovering = MapAlignmentRecordStore(raw = backing, installationId = installation)
        assertTrue(recovering.saveDraft(storedDraft(3)))

        assertTrue(recovering.removeUnreadableSavedCalibrations())

        assertEquals(MapAlignmentStorage.Decoded.Empty, recovering.loadSavedCalibrations())
        val draft = recovering.loadDraft() as MapAlignmentStorage.Decoded.Restored
        assertEquals("the draft is not collateral damage", 3, draft.value.pointCount)
        // And saving is unblocked again now the operator chose to remove them.
        assertTrue(recovering.saveCalibration(savedRecord()))
    }

    @Test
    fun `unreadable saved data does not prevent a valid draft being resumed`() {
        val backing = RecordingRawStore()
        backing.values[MapAlignmentRecordStore.KEY_SAVED] = "{ not json at all"
        val mixed = MapAlignmentRecordStore(raw = backing, installationId = installation)
        assertTrue(mixed.saveDraft(storedDraft(3)))

        // The two records fail independently. Three walked points stay
        // resumable regardless of the state of the completed list.
        val draft = mixed.loadDraft() as MapAlignmentStorage.Decoded.Restored
        assertEquals(3, draft.value.pointCount)
        assertTrue(mixed.isSavedStorageUnusable())
    }

    @Test
    fun `an unreadable draft does not prevent saved calibrations being read`() {
        val backing = RecordingRawStore()
        val readable = MapAlignmentRecordStore(raw = backing, installationId = installation)
        readable.saveCalibration(savedRecord())
        backing.values[MapAlignmentRecordStore.KEY_DRAFT] = "{ corrupt"

        assertTrue(readable.loadDraft() is MapAlignmentStorage.Decoded.Unusable)
        assertEquals(1, readable.savedCalibrationsOrEmpty().size)
        assertFalse(readable.isSavedStorageUnusable())
    }

    @Test
    fun `deleting from an empty saved list succeeds without writing`() {
        val backing = RecordingRawStore()
        val empty = MapAlignmentRecordStore(raw = backing, installationId = installation)

        assertTrue(empty.deleteCalibration("anything"))

        assertTrue(backing.writtenKeys.isEmpty())
        assertTrue(backing.removedKeys.isEmpty())
    }

    @Test
    fun `deleting the last calibration removes the key outright`() {
        assertTrue(store.saveCalibration(savedRecord()))

        assertTrue(store.deleteCalibration("saved-1"))

        assertEquals(listOf(MapAlignmentRecordStore.KEY_SAVED), raw.removedKeys)
        assertEquals(MapAlignmentStorage.Decoded.Empty, store.loadSavedCalibrations())
    }
}
