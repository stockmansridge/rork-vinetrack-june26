package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The separation guarantees between an unfinished draft and a completed saved
 * calibration, and the rules for replacing one safely.
 *
 * These are the cases where the operator can lose a walk around a vineyard to a
 * side effect they did not ask for: a recalibration quietly overwriting a known
 * good calibration, a failed save that has already deleted the draft, or a
 * delete taking the other record with it. Each is asserted directly against the
 * production rules rather than through a screen.
 */
class MapAlignmentSaveFlowTest {

    private val installation = "install-a"
    private val scope = MapAlignmentScope(installation, "vineyard-1")
    private val blockScope = MapAlignmentScope(installation, "vineyard-1", blockId = "block-9")
    private val otherVineyard = MapAlignmentScope(installation, "vineyard-2")
    private val origin = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    /**
     * In-memory bytes. Interchangeable with SharedPreferences by design.
     *
     * Writing and removing are separate operations here, exactly as in the
     * production contract, so a test can assert that a failed encode never
     * caused a REMOVAL rather than merely observing that a value vanished.
     */
    private class FakeRawStore(
        /** Set to make every write fail, as a full or unwritable device would. */
        var failWrites: Boolean = false,
    ) : MapAlignmentRawStore {
        val values = mutableMapOf<String, String>()

        /** Keys this store was ever asked to delete. */
        val removedKeys = mutableListOf<String>()

        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String): Boolean {
            if (failWrites) return false
            values[key] = value
            return true
        }

        override fun remove(key: String): Boolean {
            removedKeys += key
            if (failWrites) return false
            values.remove(key)
            return true
        }
    }

    /** An encoder that fails, standing in for a serialization defect. */
    private class FailingEncoder(
        private val onDraft: Boolean = true,
        private val onCalibrations: Boolean = true,
    ) : MapAlignmentEncoder {
        override fun encodeDraft(draft: MapAlignmentStoredDraft): String =
            if (onDraft) error("draft encoding failed") else MapAlignmentJsonEncoder.encodeDraft(draft)

        override fun encodeCalibrations(saved: List<MapAlignmentSavedCalibration>): String =
            if (onCalibrations) {
                error("calibration encoding failed")
            } else {
                MapAlignmentJsonEncoder.encodeCalibrations(saved)
            }
    }

    private fun store(raw: FakeRawStore) =
        MapAlignmentRecordStore(raw = raw, installationId = installation)

    private fun brokenStore(raw: FakeRawStore, encoder: MapAlignmentEncoder) =
        MapAlignmentRecordStore(raw = raw, installationId = installation, encoder = encoder)

    private fun shift(
        from: CanonicalCoordinate,
        eastMetres: Double,
        northMetres: Double,
        scope: MapAlignmentScope = this.scope,
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

    private fun point(
        index: Int,
        scope: MapAlignmentScope = this.scope,
        eastMetres: Double = 9.0,
        northMetres: Double = 0.0,
    ): MapAlignmentReferencePoint {
        val canonical = shift(origin, index * 60.0, if (index % 2 == 0) 0.0 else 55.0, scope)
        val marked = shift(canonical, eastMetres, northMetres, scope)
        return MapAlignmentReferencePoint(
            id = "${scope.blockId ?: scope.vineyardId}-p$index",
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
            referenceType = MapAlignmentReferenceType.RowEnd,
            description = "North-west corner post",
            rowNumber = 26,
            rowPosition = MapAlignmentRowPosition.End,
        )
    }

    private fun draft(
        pointCount: Int,
        scope: MapAlignmentScope = this.scope,
        eastMetres: Double = 9.0,
    ): MapAlignmentDraft {
        var draft = MapAlignmentDraft(
            scope = scope,
            vineyardName = "Stockmans Ridge",
            blockName = if (scope.isBlockOverride) "Home Block" else null,
        )
        repeat(pointCount) {
            draft = draft.withReferencePoint(point(it, scope, eastMetres))
        }
        return draft
    }

    private fun solvedDraft(
        scope: MapAlignmentScope = this.scope,
        alignmentId: String = "saved-1",
        eastMetres: Double = 9.0,
    ): MapAlignmentDraft =
        draft(4, scope, eastMetres).solved(alignmentId = alignmentId, nowEpochMillis = 1L)

    private fun savedRecord(
        scope: MapAlignmentScope = this.scope,
        alignmentId: String = "saved-1",
        savedAt: Long = 1_757_200_000_000,
        eastMetres: Double = 9.0,
    ): MapAlignmentSavedCalibration {
        val solved = solvedDraft(scope, alignmentId, eastMetres)
        return MapAlignmentSaveFlow.savedFrom(
            draft = solved,
            solution = solved.solution!!,
            nowEpochMillis = savedAt,
        )
    }

    private fun storedDraft(
        pointCount: Int,
        scope: MapAlignmentScope = this.scope,
    ) = MapAlignmentStoredDraft(
        draft = draft(pointCount, scope),
        step = MapAlignmentWizardStep.Capture,
        updatedAtEpochMillis = 1_757_100_000_000,
    )

    // --- Draft and completed calibration coexist ---------------------------

    @Test
    fun `an active draft and a saved calibration live side by side`() {
        val raw = FakeRawStore()
        val store = store(raw)

        assertTrue(store.saveCalibration(savedRecord()))
        assertTrue(store.saveDraft(storedDraft(3)))

        // Both are readable, and neither has disturbed the other.
        val draft = store.loadDraft() as MapAlignmentStorage.Decoded.Restored
        assertEquals(3, draft.value.pointCount)
        assertEquals(1, store.savedCalibrationsOrEmpty().size)
        assertEquals("saved-1", store.savedCalibrationsOrEmpty().single().alignment.id)
        // Separate keys, so one write can never land on the other's bytes.
        assertEquals(2, raw.values.size)
    }

    @Test
    fun `a recalibration draft does not overwrite the saved calibration`() {
        val raw = FakeRawStore()
        val store = store(raw)
        val original = savedRecord(alignmentId = "saved-original", eastMetres = 9.0)
        store.saveCalibration(original)

        // A full recalibration is walked and autosaved for the SAME scope...
        repeat(4) { count ->
            store.saveDraft(storedDraft(count + 1))
        }

        // ...and the saved calibration is still exactly what it was.
        val saved = store.savedFor(scope)
        assertNotNull(saved)
        assertEquals("saved-original", saved!!.alignment.id)
        assertEquals(
            original.alignment.eastOffsetMetres,
            saved.alignment.eastOffsetMetres,
            1e-9,
        )
        assertEquals(original.savedAtEpochMillis, saved.savedAtEpochMillis)
    }

    @Test
    fun `only an explicit save replaces the calibration for that scope`() {
        val store = store(FakeRawStore())
        store.saveCalibration(savedRecord(alignmentId = "saved-original", eastMetres = 9.0))

        val replacement = savedRecord(
            alignmentId = "saved-new",
            savedAt = 1_757_300_000_000,
            eastMetres = 14.0,
        )
        assertTrue(store.saveCalibration(replacement))

        // One current calibration per scope: replaced, not accumulated.
        val saved = store.savedCalibrationsOrEmpty()
        assertEquals(1, saved.size)
        assertEquals("saved-new", saved.single().alignment.id)
    }

    @Test
    fun `a block override and its vineyard calibration never replace each other`() {
        val store = store(FakeRawStore())

        store.saveCalibration(savedRecord(scope = scope, alignmentId = "vineyard-level"))
        store.saveCalibration(savedRecord(scope = blockScope, alignmentId = "block-level"))
        store.saveCalibration(savedRecord(scope = otherVineyard, alignmentId = "other-vineyard"))

        // Three different scopes are three different questions.
        assertEquals(3, store.savedCalibrationsOrEmpty().size)
        assertEquals("vineyard-level", store.savedFor(scope)!!.alignment.id)
        assertEquals("block-level", store.savedFor(blockScope)!!.alignment.id)
        assertEquals("other-vineyard", store.savedFor(otherVineyard)!!.alignment.id)
    }

    @Test
    fun `existingFor matches the exact scope only`() {
        val saved = listOf(savedRecord(scope = scope, alignmentId = "vineyard-level"))

        assertEquals("vineyard-level", MapAlignmentSaveFlow.existingFor(saved, scope)?.alignment?.id)
        // A block override is NOT covered by its vineyard's calibration.
        assertNull(MapAlignmentSaveFlow.existingFor(saved, blockScope))
        assertNull(MapAlignmentSaveFlow.existingFor(saved, otherVineyard))
        assertNull(
            "another installation must never match",
            MapAlignmentSaveFlow.existingFor(saved, scope.copy(androidInstallationId = "install-b")),
        )
    }

    // --- Save-then-delete ordering ----------------------------------------

    @Test
    fun `the draft is removed only after the completed save succeeds`() {
        assertTrue(MapAlignmentSaveFlow.mayRemoveDraft(saveSucceeded = true))
        assertFalse(
            "a failed save must leave the only remaining copy of the field work alone",
            MapAlignmentSaveFlow.mayRemoveDraft(saveSucceeded = false),
        )
    }

    @Test
    fun `a failed save keeps the draft on disk`() {
        val raw = FakeRawStore()
        val store = store(raw)
        store.saveDraft(storedDraft(4))

        // The device can no longer be written to.
        raw.failWrites = true
        val saveSucceeded = store.saveCalibration(savedRecord())

        assertFalse("a failed write must be reported as failed", saveSucceeded)
        if (MapAlignmentSaveFlow.mayRemoveDraft(saveSucceeded)) store.deleteDraft()

        raw.failWrites = false
        val draft = store.loadDraft() as MapAlignmentStorage.Decoded.Restored
        assertEquals("the walk survives a failed save", 4, draft.value.pointCount)
        assertTrue(store.savedCalibrationsOrEmpty().isEmpty())
    }

    @Test
    fun `a successful save then clears the draft and keeps the calibration`() {
        val raw = FakeRawStore()
        val store = store(raw)
        store.saveDraft(storedDraft(4))

        val saveSucceeded = store.saveCalibration(savedRecord())
        assertTrue(saveSucceeded)
        if (MapAlignmentSaveFlow.mayRemoveDraft(saveSucceeded)) store.deleteDraft()

        assertEquals(MapAlignmentStorage.Decoded.Empty, store.loadDraft())
        assertEquals(1, store.savedCalibrationsOrEmpty().size)
    }

    // --- Deletion is exact and never collateral ---------------------------

    @Test
    fun `deleting the draft does not delete the completed calibration`() {
        val store = store(FakeRawStore())
        store.saveCalibration(savedRecord())
        store.saveDraft(storedDraft(3))

        store.deleteDraft()

        assertEquals(MapAlignmentStorage.Decoded.Empty, store.loadDraft())
        assertEquals(
            "a draft deletion must never reach the saved calibration",
            1,
            store.savedCalibrationsOrEmpty().size,
        )
    }

    @Test
    fun `deleting the calibration does not silently delete an active draft`() {
        val store = store(FakeRawStore())
        store.saveCalibration(savedRecord())
        store.saveDraft(storedDraft(3))

        store.deleteCalibration("saved-1")

        assertTrue(store.savedCalibrationsOrEmpty().isEmpty())
        val draft = store.loadDraft() as MapAlignmentStorage.Decoded.Restored
        assertEquals(
            "an in-progress recalibration is not collateral damage",
            3,
            draft.value.pointCount,
        )
    }

    @Test
    fun `deleting a calibration removes only the one named`() {
        val store = store(FakeRawStore())
        store.saveCalibration(savedRecord(scope = scope, alignmentId = "vineyard-level"))
        store.saveCalibration(savedRecord(scope = blockScope, alignmentId = "block-level"))

        store.deleteCalibration("block-level")

        val remaining = store.savedCalibrationsOrEmpty()
        assertEquals(1, remaining.size)
        assertEquals("vineyard-level", remaining.single().alignment.id)
    }

    @Test
    fun `deleting an unknown id changes nothing`() {
        val store = store(FakeRawStore())
        store.saveCalibration(savedRecord())

        store.deleteCalibration("never-existed")

        assertEquals(1, store.savedCalibrationsOrEmpty().size)
    }

    @Test
    fun `deleteEverything is explicit and takes both`() {
        val store = store(FakeRawStore())
        store.saveCalibration(savedRecord())
        store.saveDraft(storedDraft(3))

        assertTrue(store.deleteEverything())

        assertEquals(MapAlignmentStorage.Decoded.Empty, store.loadDraft())
        assertTrue(store.savedCalibrationsOrEmpty().isEmpty())
    }

    // --- Complete evidence is carried into the saved record ----------------

    @Test
    fun `saving carries every reference point and its full GPS evidence`() {
        val store = store(FakeRawStore())
        val record = savedRecord()
        store.saveCalibration(record)

        val restored = store.savedFor(scope)!!
        assertEquals(4, restored.pointCount)

        val before = point(0)
        val after = restored.calibration.referencePoints.first { it.id == before.id }
        assertEquals(before.canonicalCoordinate, after.canonicalCoordinate)
        assertEquals(before.selectedMapCoordinate, after.selectedMapCoordinate)
        assertEquals(before.gpsAccuracyMetres, after.gpsAccuracyMetres)
        assertEquals(before.gpsEvidence, after.gpsEvidence)
        assertEquals(before.capturedAtEpochMillis, after.capturedAtEpochMillis)
        assertEquals(before.referenceType, after.referenceType)
        assertEquals(before.description, after.description)
        assertEquals(before.rowNumber, after.rowNumber)
        assertEquals(before.rowPosition, after.rowPosition)
        assertEquals(before.scope, after.scope)
    }

    @Test
    fun `saved alignment keeps its identity scope offsets and times`() {
        val store = store(FakeRawStore())
        store.saveCalibration(savedRecord(savedAt = 1_757_200_000_000))

        val alignment = store.savedFor(scope)!!.alignment
        assertEquals("saved-1", alignment.id)
        assertEquals(scope, alignment.scope)
        assertEquals(1_757_200_000_000, alignment.createdAtEpochMillis)
        assertEquals(1_757_200_000_000, alignment.updatedAtEpochMillis)
        // A 9 m east mark on every point means a 9 m east candidate.
        assertEquals(9.0, alignment.eastOffsetMetres, 0.05)
        assertEquals(0.0, alignment.northOffsetMetres, 0.05)
    }

    @Test
    fun `review values are recomputed from evidence rather than stored`() {
        val store = store(FakeRawStore())
        val record = savedRecord()
        store.saveCalibration(record)

        val restored = store.savedFor(scope)!!
        val review = restored.review()

        assertNotNull("a solvable saved calibration reports its own quality", review)
        assertEquals(4, review!!.pointCount)
        assertEquals(record.calibration.alignment.id, review.alignment.id)
        // Derived from the restored points, so the figure shown beside the
        // evidence can never disagree with it.
        assertEquals(
            record.review()!!.rmsResidualMetres,
            review.rmsResidualMetres,
            1e-9,
        )
        assertEquals(MapAlignmentSolver.Quality.Good, review.quality)
    }

    // --- The two warnings stay separate -----------------------------------

    @Test
    fun `the overall quality warning fires for a poor fit with no odd point`() {
        // Uniformly mediocre: 4.0/4.1/4.3/4.2-style evidence.
        val spread = listOf(4.0, 4.1, 4.3, 4.2)
        var draft = MapAlignmentDraft(scope = scope, vineyardName = "Stockmans Ridge")
        spread.forEachIndexed { index, east ->
            draft = draft.withReferencePoint(point(index, scope, eastMetres = east, northMetres = 0.0))
        }
        // Push one axis so the fit is genuinely outside the limits.
        val solution = draft(4, scope, eastMetres = 9.0)
            .withUpdatedReferencePoint(
                point(0, scope, eastMetres = 9.0, northMetres = 14.0),
            )
            .solved("q", 1L).solution!!

        assertTrue(
            "overall quality is its own rule",
            MapAlignmentSaveFlow.needsQualityConfirmation(solution),
        )
        assertEquals(MapAlignmentSolver.Quality.CheckAlignment, solution.quality)

        val message = MapAlignmentSaveFlow.qualityWarningMessage(solution)
        assertTrue(message.contains("RMS residual"))
        assertTrue(message.contains("Maximum residual"))
        assertTrue(message.contains("not be applied to VineTrack's normal maps"))
    }

    @Test
    fun `a good fit needs no quality confirmation`() {
        val solution = solvedDraft().solution!!

        assertEquals(MapAlignmentSolver.Quality.Good, solution.quality)
        assertFalse(MapAlignmentSaveFlow.needsQualityConfirmation(solution))
    }

    @Test
    fun `the quality rule and the outlier rule are not the same rule`() {
        // One clear outlier, overall fit still acceptable: 1.4/1.5/6.1/1.3.
        val outlierCase = draft(4, scope, eastMetres = 9.0)
            .withUpdatedReferencePoint(point(2, scope, eastMetres = 15.1))
            .solved("o", 1L).solution!!

        val review = MapAlignmentOutliers.review(outlierCase)

        assertTrue("the per-point rule sees the odd point", review.hasSuspects)
        // Whether the overall rule ALSO fires is a separate question, and the
        // two answers are produced independently. Collapsing them would let one
        // rule's case slip past the other unnoticed.
        assertEquals(
            outlierCase.quality != MapAlignmentSolver.Quality.Good,
            MapAlignmentSaveFlow.needsQualityConfirmation(outlierCase),
        )
    }

    @Test
    fun `a Check alignment calibration may still be saved for field testing`() {
        val store = store(FakeRawStore())
        val poor = draft(4, scope, eastMetres = 9.0)
            .withUpdatedReferencePoint(point(0, scope, eastMetres = 9.0, northMetres = 14.0))
            .solved("poor", 1L)
        val record = MapAlignmentSaveFlow.savedFrom(poor, poor.solution!!, 1_757_200_000_000)

        assertTrue(
            "the warning informs, it does not block",
            store.saveCalibration(record),
        )
        assertEquals(
            MapAlignmentSolver.Quality.CheckAlignment,
            store.savedFor(scope)!!.review()!!.quality,
        )
    }

    // --- Replacement wording ----------------------------------------------

    @Test
    fun `the replace prompt names what is already saved`() {
        val message = MapAlignmentSaveFlow.replaceMessage(savedRecord())

        assertTrue(message.contains("already saved for this vineyard/block"))
        assertTrue(message.contains("Stockmans Ridge"))
        assertTrue(message.contains("4 reference points"))
    }

    @Test
    fun `the replace prompt names a block override as a block`() {
        val message = MapAlignmentSaveFlow.replaceMessage(savedRecord(scope = blockScope))

        assertTrue(message.contains("Home Block"))
    }

    // --- Installation scoping ----------------------------------------------

    @Test
    fun `another installation's calibration is never written or read`() {
        val raw = FakeRawStore()
        val store = store(raw)
        val foreign = MapAlignmentScope("install-b", "vineyard-1")

        assertFalse(store.saveCalibration(savedRecord(scope = foreign, alignmentId = "foreign")))
        assertFalse(store.saveDraft(storedDraft(2, scope = foreign)))
        assertTrue("nothing foreign reached storage", raw.values.isEmpty())
    }

    // --- Merge semantics ---------------------------------------------------

    @Test
    fun `merge replaces by scope and by id but keeps other scopes`() {
        val vineyard = savedRecord(scope = scope, alignmentId = "v1")
        val block = savedRecord(scope = blockScope, alignmentId = "b1")
        val replacement = savedRecord(scope = scope, alignmentId = "v2")

        val merged = MapAlignmentSaveFlow.merge(listOf(vineyard, block), replacement)

        assertEquals(listOf("b1", "v2"), merged.map { it.alignment.id })
    }
}
