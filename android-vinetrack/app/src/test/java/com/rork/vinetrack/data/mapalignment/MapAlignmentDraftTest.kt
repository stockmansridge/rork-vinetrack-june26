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
 * correction that was not calculated, adding or removing evidence invalidates a
 * stale candidate, and the draft's scope owns all of its evidence.
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
            capturedAtEpochMillis = 1_757_000_000_000,
        )
    }

    /** Four well-separated points sharing one observed offset. */
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
    fun `before and after are both identity until an alignment is calculated`() {
        val collecting = readyDraft()
        assertNull(collecting.candidate)
        // The preview must not imply a correction that has not been calculated.
        assertTrue(collecting.previewBefore.isIdentity)
        assertTrue(collecting.previewAfter.isIdentity)
        assertEquals(collecting.previewBefore, collecting.previewAfter)
    }

    @Test
    fun `before stays identity after calculating and after becomes the candidate`() {
        val solved = readyDraft().solved("draft-1", nowEpochMillis = 1_757_000_000_000)
        val candidate = assertNotNull(solved.candidate).let { solved.candidate!! }

        // "Before" must be exactly current production rendering, always.
        assertTrue(solved.previewBefore.isIdentity)
        assertEquals(MapAlignment.none(scope), solved.previewBefore)

        assertEquals(candidate, solved.previewAfter)
        assertFalse(solved.previewAfter.isIdentity)
        assertEquals(10.0, solved.previewAfter.eastOffsetMetres, 1e-6)
        assertEquals(-6.0, solved.previewAfter.northOffsetMetres, 1e-6)
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
    fun `removing evidence invalidates a previously calculated candidate`() {
        val solved = readyDraft().solved("draft-1", null)
        val reduced = solved.withoutReferencePoint("p1")
        assertNull(reduced.solution)
        assertEquals(3, reduced.pointCount)
        assertFalse(reduced.readiness.isReady)
    }

    @Test
    fun `clearing discards evidence and candidate but keeps the chosen scope`() {
        val cleared = readyDraft().solved("draft-1", null).cleared()
        assertEquals(0, cleared.pointCount)
        assertNull(cleared.solution)
        assertEquals(scope, cleared.scope)
        assertEquals("Stockman's Ridge", cleared.vineyardName)
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
        // Evidence travels with the block scope too.
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
    fun `solving is refused while evidence is clustered`() {
        var clustered = draft()
        listOf(
            point("c1", origin),
            point("c2", shifted(3.0, 0.0)),
            point("c3", shifted(0.0, 3.0)),
            point("c4", shifted(3.0, 3.0)),
        ).forEach { clustered = clustered.withReferencePoint(it) }

        assertEquals(4, clustered.pointCount)
        assertFalse(clustered.readiness.isReady)
        assertNull(clustered.solved("draft-1", null).solution)
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
