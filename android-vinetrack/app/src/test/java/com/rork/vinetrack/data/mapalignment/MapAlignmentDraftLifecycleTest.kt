package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Leaving and reopening the calibration wizard, through the real store.
 *
 * The guarantee these protect is the one the field asked for: an operator who
 * has walked three reference points and is interrupted must come back to three
 * reference points. Every test here goes through [MapAlignmentRecordStore] and
 * the real codec, so "survives leaving" means bytes actually written and read
 * back, not an object held in memory.
 */
class MapAlignmentDraftLifecycleTest {

    private val installation = "install-a"
    private val scope = MapAlignmentScope(installation, "vineyard-1")
    private val origin = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    /** In-memory bytes, standing in for this installation's preference file. */
    private class FakeRawStore : MapAlignmentRawStore {
        val values = mutableMapOf<String, String>()

        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String?): Boolean {
            if (value == null) values.remove(key) else values[key] = value
            return true
        }
    }

    private val raw = FakeRawStore()
    private val store = MapAlignmentRecordStore(raw = raw, installationId = installation)

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

    private fun point(index: Int): MapAlignmentReferencePoint {
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

    /** The autosave the wizard performs after each meaningful change. */
    private fun autosave(
        pointCount: Int,
        pending: MapAlignmentPendingReference? = null,
        step: MapAlignmentWizardStep = MapAlignmentWizardStep.Capture,
    ): MapAlignmentDraft {
        var draft = MapAlignmentDraft(
            scope = scope,
            vineyardName = "Stockmans Ridge",
        )
        repeat(pointCount) { draft = draft.withReferencePoint(point(it)) }
        store.saveDraft(
            MapAlignmentStoredDraft(
                draft = draft,
                step = step,
                pending = pending,
                updatedAtEpochMillis = 1_757_100_000_000 + pointCount,
            ),
        )
        return draft
    }

    /** Reopen the wizard: everything in memory is gone, only bytes remain. */
    private fun reopen(): MapAlignmentStoredDraft? =
        (store.loadDraft() as? MapAlignmentStorage.Decoded.Restored)?.value

    // --- Resume -----------------------------------------------------------

    @Test
    fun `point 1 survives leaving and reopening`() {
        autosave(pointCount = 1)

        val resumed = requireNotNull(reopen())

        assertEquals(1, resumed.pointCount)
        assertEquals("p0", resumed.draft.referencePoints.single().id)
        assertEquals(
            "1 of 4 minimum reference points completed",
            resumed.progressSummary(),
        )
    }

    @Test
    fun `points 1 to 3 survive leaving and reopening`() {
        autosave(pointCount = 3)

        val resumed = requireNotNull(reopen())

        assertEquals(3, resumed.pointCount)
        assertEquals(listOf("p0", "p1", "p2"), resumed.draft.referencePoints.map { it.id })
        // The evidence itself came back, not just the count.
        assertEquals(point(1).canonicalCoordinate, resumed.draft.referencePoints[1].canonicalCoordinate)
        assertEquals(point(1).gpsEvidence, resumed.draft.referencePoints[1].gpsEvidence)
    }

    @Test
    fun `a resumed draft continues at the next point rather than point one`() {
        autosave(pointCount = 3)

        val resumed = requireNotNull(reopen())

        // This is the field guarantee: the operator records point 4 next.
        assertEquals(4, resumed.pointCount + 1)
        assertEquals(
            MapAlignmentSolver.Readiness.NeedMorePoints(have = 3),
            resumed.restoredDraft().readiness,
        )
        assertEquals(MapAlignmentWizardStep.Capture, resumed.step)
    }

    @Test
    fun `a resumed draft keeps its scope so the vineyard is not chosen again`() {
        autosave(pointCount = 2)

        val resumed = requireNotNull(reopen())

        assertEquals(scope, resumed.draft.scope)
        assertEquals("Stockmans Ridge", resumed.draft.vineyardName)
        assertFalse(resumed.draft.isBlockOverride)
        // Resuming lands on the capture step, not back at scope selection.
        assertFalse(resumed.step == MapAlignmentWizardStep.Scope)
    }

    // --- The GPS-complete checkpoint --------------------------------------

    @Test
    fun `a GPS-complete point resumes at image marking`() {
        val checkpoint = MapAlignmentPendingReference(
            editingId = null,
            canonicalCoordinate = shift(origin, 180.0, 0.0),
            gpsEvidence = MapAlignmentGpsEvidence(
                sampleCount = 7,
                samplingDurationMillis = 16_000L,
                representativeAccuracyMetres = 2.9,
                worstAccuracyMetres = 4.4,
                stabilityRadiusMetres = 2.1,
            ),
            capturedAtEpochMillis = 1_757_100_000_500,
        )
        autosave(pointCount = 3, pending = checkpoint)

        val resumed = requireNotNull(reopen())
        val pending = requireNotNull(resumed.pending)

        // The walk and the stationary wait do not have to be repeated.
        assertEquals(checkpoint.canonicalCoordinate, pending.canonicalCoordinate)
        assertEquals(checkpoint.gpsEvidence, pending.gpsEvidence)
        assertEquals(checkpoint.capturedAtEpochMillis, pending.capturedAtEpochMillis)
        assertEquals(
            "Point 4 GPS complete — image point still needs marking",
            resumed.pendingSummary(),
        )
        // It is not yet a reference point, so it cannot join the solve.
        assertEquals(3, resumed.pointCount)
    }

    @Test
    fun `an actively incomplete GPS reading restarts only that one point`() {
        // The wizard deliberately never checkpoints a partial sample group: a
        // partial group is not evidence, and restoring one would let samples
        // from before and after the interruption merge.
        autosave(pointCount = 3, pending = null)

        val resumed = requireNotNull(reopen())

        assertNull("no partial sample group is ever stored", resumed.pending)
        assertNull(resumed.pendingSummary())
        assertEquals(
            "the three completed points are untouched by the abandoned attempt",
            3,
            resumed.pointCount,
        )
    }

    @Test
    fun `completing the pending point clears the checkpoint`() {
        val checkpoint = MapAlignmentPendingReference(
            canonicalCoordinate = shift(origin, 180.0, 0.0),
            capturedAtEpochMillis = 1_757_100_000_500,
        )
        autosave(pointCount = 3, pending = checkpoint)

        // The operator marks the image point; it becomes a real reference.
        autosave(pointCount = 4, pending = null)

        val resumed = requireNotNull(reopen())
        assertEquals(4, resumed.pointCount)
        assertNull("a used checkpoint must not resume a second time", resumed.pending)
    }

    // --- Leaving is not destroying -----------------------------------------

    @Test
    fun `leaving the wizard does not remove the draft`() {
        autosave(pointCount = 3)
        val guard = MapAlignmentExitGuard()
        guard.onDraftChanged(reopen()!!.restoredDraft(), hasPendingReference = false)

        var exited = false
        guard.requestExit { exited = true }
        guard.leaveAndContinueLater()

        assertTrue("the operator did leave", exited)
        assertEquals(
            "leaving must never destroy autosaved field work",
            3,
            requireNotNull(reopen()).pointCount,
        )
    }

    @Test
    fun `the exit guard has no route to deletion`() {
        val guard = MapAlignmentExitGuard()
        autosave(pointCount = 3)
        guard.onDraftChanged(reopen()!!.restoredDraft())

        // Neither action on the leave confirmation touches storage.
        guard.requestExit { }
        guard.keepCalibrating()
        assertEquals(3, requireNotNull(reopen()).pointCount)

        guard.requestExit { }
        guard.leaveAndContinueLater()
        assertEquals(3, requireNotNull(reopen()).pointCount)
    }

    // --- The destructive paths are explicit --------------------------------

    @Test
    fun `start over removes the draft`() {
        autosave(pointCount = 3)

        // Only reached through the confirmed "Start calibration again?" dialog.
        store.deleteDraft()

        assertEquals(MapAlignmentStorage.Decoded.Empty, store.loadDraft())
        assertNull(reopen())
    }

    @Test
    fun `delete draft removes the draft and nothing else`() {
        autosave(pointCount = 3)
        raw.values["unrelated_key"] = "untouched"

        store.deleteDraft()

        assertNull(reopen())
        assertEquals("untouched", raw.values["unrelated_key"])
    }

    // --- Autosave fires at each meaningful change --------------------------

    @Test
    fun `each completed point is autosaved as it happens`() {
        (1..4).forEach { count ->
            autosave(pointCount = count)
            assertEquals(
                "point $count must be on disk the moment it completes",
                count,
                requireNotNull(reopen()).pointCount,
            )
        }
    }

    @Test
    fun `deleting a point is autosaved too`() {
        autosave(pointCount = 3)

        val reduced = requireNotNull(reopen()).restoredDraft().withoutReferencePoint("p1")
        store.saveDraft(
            MapAlignmentStoredDraft(draft = reduced, updatedAtEpochMillis = 1_757_100_000_900),
        )

        val resumed = requireNotNull(reopen())
        assertEquals(2, resumed.pointCount)
        assertEquals(listOf("p0", "p2"), resumed.draft.referencePoints.map { it.id })
    }

    @Test
    fun `a recalculated candidate is restored rather than stored as numbers`() {
        val solved = run {
            var draft = MapAlignmentDraft(scope = scope, vineyardName = "Stockmans Ridge")
            repeat(4) { draft = draft.withReferencePoint(point(it)) }
            draft.solved(alignmentId = "candidate-1", nowEpochMillis = 1L)
        }
        store.saveDraft(
            MapAlignmentStoredDraft(
                draft = solved,
                step = MapAlignmentWizardStep.Review,
                solvedAlignmentId = "candidate-1",
                updatedAtEpochMillis = 1_757_100_000_000,
            ),
        )

        val resumed = requireNotNull(reopen())
        val rebuilt = resumed.restoredDraft()

        assertEquals(MapAlignmentWizardStep.Review, resumed.step)
        assertNotNull(rebuilt.solution)
        assertEquals(
            solved.solution!!.alignment.eastOffsetMetres,
            rebuilt.solution!!.alignment.eastOffsetMetres,
            1e-9,
        )
    }

    @Test
    fun `retaking GPS invalidates the stored candidate`() {
        val solved = run {
            var draft = MapAlignmentDraft(scope = scope, vineyardName = "Stockmans Ridge")
            repeat(4) { draft = draft.withReferencePoint(point(it)) }
            draft.solved(alignmentId = "candidate-1", nowEpochMillis = 1L)
        }
        // A retake changes the evidence, so the candidate must not outlive it.
        val retaken = solved.withRetakenGps(
            pointId = "p2",
            canonicalCoordinate = shift(origin, 120.0, 4.0),
            gpsAccuracyMetres = 2.2,
            gpsEvidence = null,
            capturedAtEpochMillis = 1_757_100_000_700,
        )
        store.saveDraft(
            MapAlignmentStoredDraft(
                draft = retaken,
                step = MapAlignmentWizardStep.Capture,
                solvedAlignmentId = retaken.solution?.alignment?.id,
                updatedAtEpochMillis = 1_757_100_000_700,
            ),
        )

        val resumed = requireNotNull(reopen())
        assertNull("a stale candidate must not be restored", resumed.solvedAlignmentId)
        assertNull(resumed.restoredDraft().solution)
        assertEquals(4, resumed.pointCount)
    }
}
