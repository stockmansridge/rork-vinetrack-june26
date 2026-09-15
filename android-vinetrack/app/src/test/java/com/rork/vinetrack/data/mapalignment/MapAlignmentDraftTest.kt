package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wizard's session draft.
 *
 * The properties that matter: the before/after preview can never imply a
 * correction that was not calculated, ANY change to the evidence invalidates a
 * stale candidate, editing a reference preserves the half of it that was not
 * being replaced, and the draft's scope owns all of its evidence.
 */
class MapAlignmentDraftTest {

    private val scope = MapAlignmentScope("install-a", "v1")
    private val blockScope = MapAlignmentScope("install-a", "v1", "b1")
    private val origin = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    private fun draft(scope: MapAlignmentScope = this.scope) = MapAlignmentDraft(
        scope = scope,
        vineyardName = "Stockman's Ridge",
        blockName = if (scope.isBlockOverride) "Block 1" else null,
    )

    private fun shifted(east: Double, north: Double): CanonicalCoordinate {
        val display = origin.toDisplay(
            MapAlignment("f", scope, east, north, isEnabled = true),
        )
        return CanonicalCoordinate(display.latitude, display.longitude)
    }

    private fun point(
        id: String,
        canonical: CanonicalCoordinate,
        pointScope: MapAlignmentScope = scope,
        east: Double = 10.0,
        north: Double = -6.0,
    ): MapAlignmentReferencePoint {
        val observation = MapAlignment("o", pointScope, east, north, isEnabled = true)
        return MapAlignmentReferencePoint(
            id = id,
            scope = pointScope,
            canonicalCoordinate = canonical,
            selectedMapCoordinate = canonical.toDisplay(observation),
            gpsAccuracyMetres = 2.0,
            gpsEvidence = MapAlignmentGpsEvidence(
                sampleCount = 6,
                samplingDurationMillis = 7_000,
                representativeAccuracyMetres = 2.0,
                worstAccuracyMetres = 3.5,
                stabilityRadiusMetres = 1.2,
            ),
            capturedAtEpochMillis = 1_757_000_000_000,
        )
    }

    /** Four distinct locations sharing one observed offset. */
    private fun readyDraft(scope: MapAlignmentScope = this.scope): MapAlignmentDraft {
        var d = draft(scope)
        listOf(
            point("p1", origin, scope),
            point("p2", shifted(200.0, 0.0), scope),
            point("p3", shifted(0.0, 200.0), scope),
            point("p4", shifted(200.0, 200.0), scope),
        ).forEach { d = d.withReferencePoint(it) }
        return d
    }

    // ----- Preview honesty -----

    @Test
    fun `original and aligned are both identity until an alignment is calculated`() {
        val collecting = readyDraft()
        assertNull(collecting.candidate)
        // The preview must not imply a correction that has not been calculated.
        assertTrue(collecting.previewBefore.isIdentity)
        assertTrue(collecting.previewAfter.isIdentity)
        assertEquals(collecting.previewBefore, collecting.previewAfter)
    }

    @Test
    fun `original stays identity after calculating and aligned becomes the candidate`() {
        val solved = readyDraft().solved("draft-1", nowEpochMillis = 1_757_000_000_000)
        val candidate = requireNotNull(solved.candidate)

        // "Original" must be exactly current production rendering, always.
        assertTrue(solved.previewBefore.isIdentity)
        assertEquals(MapAlignment.none(scope), solved.previewBefore)

        assertEquals(candidate, solved.previewAfter)
        assertFalse(solved.previewAfter.isIdentity)
        assertEquals(10.0, solved.previewAfter.eastOffsetMetres, 1e-6)
        assertEquals(-6.0, solved.previewAfter.northOffsetMetres, 1e-6)
    }

    @Test
    fun `the preview never mutates the canonical coordinates it draws`() {
        val solved = readyDraft().solved("draft-1", null)
        val candidate = requireNotNull(solved.candidate)
        val before = solved.referencePoints.map { it.canonicalCoordinate }

        // Rendering through the alignment is what the preview does.
        val drawn = solved.referencePoints.map { it.canonicalCoordinate.toDisplay(candidate) }

        assertEquals(before, solved.referencePoints.map { it.canonicalCoordinate })
        // Display coordinates are genuinely different values, not aliases.
        drawn.forEachIndexed { index, display ->
            assertFalse(display.latitude == before[index].latitude &&
                display.longitude == before[index].longitude)
        }
    }

    // ----- Stale candidate invalidation -----

    @Test
    fun `adding evidence invalidates a previously calculated candidate`() {
        val solved = readyDraft().solved("draft-1", null)
        assertNotNull(solved.solution)

        val extended = solved.withReferencePoint(point("p5", shifted(400.0, 0.0)))
        // A candidate must never be shown as derived from points it never saw.
        assertNull(extended.solution)
        assertNull(extended.candidate)
        assertTrue(extended.previewAfter.isIdentity)
        assertEquals(5, extended.pointCount)
    }

    @Test
    fun `deleting down to three points makes the calibration incomplete`() {
        val solved = readyDraft().solved("draft-1", null)
        val reduced = solved.withoutReferencePoint("p1")

        assertNull(reduced.solution)
        assertEquals(3, reduced.pointCount)
        assertFalse(reduced.readiness.isReady)
        assertTrue(reduced.readiness is MapAlignmentSolver.Readiness.NeedMorePoints)
        // It cannot be talked back into a candidate either.
        assertNull(reduced.solved("draft-2", null).solution)
    }

    @Test
    fun `clearing discards evidence and candidate but keeps the chosen scope`() {
        val cleared = readyDraft().solved("draft-1", null).cleared()
        assertEquals(0, cleared.pointCount)
        assertNull(cleared.solution)
        assertEquals(scope, cleared.scope)
        assertEquals("Stockman's Ridge", cleared.vineyardName)
    }

    // ----- Editing an existing reference -----

    @Test
    fun `retaking GPS replaces only the position and invalidates the candidate`() {
        val solved = readyDraft().solved("draft-1", null)
        val original = solved.referencePoints.first { it.id == "p2" }
        val moved = shifted(205.0, 3.0)

        val retaken = solved.withRetakenGps(
            pointId = "p2",
            canonicalCoordinate = moved,
            gpsAccuracyMetres = 1.5,
            gpsEvidence = MapAlignmentGpsEvidence(8, 9_000, 1.5, 2.0, 0.9),
            capturedAtEpochMillis = 1_757_000_100_000,
        )
        val updated = retaken.referencePoints.first { it.id == "p2" }

        assertEquals(moved, updated.canonicalCoordinate)
        assertEquals(1.5, updated.gpsAccuracyMetres!!, 1e-9)
        assertEquals(8, updated.gpsEvidence?.sampleCount)
        // The marked image point is the operator's own observation and survives.
        assertEquals(original.selectedMapCoordinate, updated.selectedMapCoordinate)
        // Order is preserved so "Point 2" stays Point 2.
        assertEquals(1, retaken.referencePoints.indexOfFirst { it.id == "p2" })
        assertEquals(4, retaken.pointCount)
        assertNull(retaken.solution)
        assertNull(updated.alignmentId)
    }

    @Test
    fun `re-marking replaces only the image point and preserves the GPS evidence`() {
        val solved = readyDraft().solved("draft-1", null)
        val original = solved.referencePoints.first { it.id == "p3" }
        val newMark = AndroidDisplayCoordinate(
            original.selectedMapCoordinate.latitude + 0.00005,
            original.selectedMapCoordinate.longitude + 0.00005,
        )

        val remarked = solved.withRemarkedImagePoint("p3", newMark)
        val updated = remarked.referencePoints.first { it.id == "p3" }

        assertEquals(newMark, updated.selectedMapCoordinate)
        // Canonical GPS evidence is untouched — it was never in question.
        assertEquals(original.canonicalCoordinate, updated.canonicalCoordinate)
        assertEquals(original.gpsEvidence, updated.gpsEvidence)
        assertEquals(original.gpsAccuracyMetres, updated.gpsAccuracyMetres)
        assertEquals(original.capturedAtEpochMillis, updated.capturedAtEpochMillis)
        assertEquals(4, remarked.pointCount)
        assertNull(remarked.solution)
    }

    @Test
    fun `editing a reference does not collide with its own position`() {
        val d = readyDraft()
        val ownPlace = d.referencePoints.first { it.id == "p1" }.canonicalCoordinate

        assertTrue(d.isNearDuplicate(ownPlace))
        assertFalse(
            "a point being retaken must not be its own duplicate",
            d.isNearDuplicate(ownPlace, excludingId = "p1"),
        )
    }

    @Test
    fun `a near-duplicate location is detected before it is added`() {
        val d = readyDraft()
        val tooClose = shifted(202.0, 1.0) // ~2 m from p2
        val farEnough = shifted(400.0, 0.0)

        assertTrue(d.isNearDuplicate(tooClose))
        assertFalse(d.isNearDuplicate(farEnough))
    }

    @Test
    fun `editing an unknown reference is a no-op`() {
        val d = readyDraft()
        assertEquals(d, d.withRemarkedImagePoint("missing", AndroidDisplayCoordinate(0.0, 0.0)))
        assertEquals(
            d,
            d.withRetakenGps("missing", origin, 1.0, null, 1L),
        )
    }

    // ----- Scope ownership -----

    @Test
    fun `a point from another scope cannot enter the draft`() {
        val d = draft()
        assertThrows(IllegalArgumentException::class.java) {
            d.withReferencePoint(point("foreign", origin, MapAlignmentScope("install-b", "v1")))
        }
        assertThrows(IllegalArgumentException::class.java) {
            d.withReferencePoint(point("other-vineyard", origin, MapAlignmentScope("install-a", "v2")))
        }
        // Vineyard-level draft must not accept block-level evidence.
        assertThrows(IllegalArgumentException::class.java) {
            d.withReferencePoint(point("block", origin, blockScope))
        }
    }

    @Test
    fun `a block override draft carries the block scope through to its candidate`() {
        val solved = readyDraft(blockScope).solved("draft-b", null)
        assertTrue(solved.isBlockOverride)
        assertEquals("Block 1", solved.blockName)
        assertEquals(blockScope, solved.candidate?.scope)
        assertEquals("b1", solved.candidate?.blockId)
        assertTrue(solved.solution?.calibration?.referencePoints?.all { it.scope == blockScope } == true)
    }

    // ----- Guarded calculation -----

    @Test
    fun `solving is refused while evidence is insufficient`() {
        val tooFew = draft().withReferencePoint(point("p1", origin))
        val attempted = tooFew.solved("draft-1", null)
        // Returned unchanged rather than producing a weak candidate.
        assertNull(attempted.solution)
        assertEquals(tooFew, attempted)
    }

    @Test
    fun `solving is refused while two references describe the same place`() {
        var duplicated = draft()
        listOf(
            point("c1", origin),
            point("c2", shifted(2.0, 0.0)),
            point("c3", shifted(0.0, 200.0)),
            point("c4", shifted(200.0, 200.0)),
        ).forEach { duplicated = duplicated.withReferencePoint(it) }

        assertEquals(4, duplicated.pointCount)
        assertFalse(duplicated.readiness.isReady)
        assertNull(duplicated.solved("draft-1", null).solution)
    }

    @Test
    fun `a small block with distinct references can still be calculated`() {
        var small = draft()
        listOf(
            point("s1", origin),
            point("s2", shifted(15.0, 0.0)),
            point("s3", shifted(0.0, 15.0)),
            point("s4", shifted(15.0, 15.0)),
        ).forEach { small = small.withReferencePoint(it) }

        assertTrue(small.widestSpanMetres < 40.0)
        assertTrue(small.readiness.isReady)
        assertNotNull(small.solved("draft-1", null).solution)
    }

    @Test
    fun `readiness is delegated to the solver`() {
        val ready = readyDraft()
        assertTrue(ready.readiness.isReady)
        assertEquals(
            MapAlignmentSolver.readiness(ready.referencePoints),
            ready.readiness,
        )
    }
}
