package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The solver derives a translation-only candidate from reference points.
 *
 * The properties that matter: a known offset is recovered exactly, clustered
 * evidence is refused, independent GPS error is averaged out, and a mismatch a
 * pure translation cannot explain is SURFACED rather than absorbed.
 */
class MapAlignmentSolverTest {

    private val scope = MapAlignmentScope("install-a", "v1")

    /** Orange, NSW — southern hemisphere, so southward cases are exercised. */
    private val origin = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    private fun canonicalOffsetBy(eastMetres: Double, northMetres: Double): CanonicalCoordinate {
        // Reuse the production transform so the fixture cannot drift from it.
        val shifted = MapAlignment(
            id = "fixture",
            scope = scope,
            eastOffsetMetres = eastMetres,
            northOffsetMetres = northMetres,
            isEnabled = true,
        )
        val display = origin.toDisplay(shifted)
        return CanonicalCoordinate(display.latitude, display.longitude)
    }

    /**
     * A reference point standing at [canonical] whose operator tap was
     * [observedEast]/[observedNorth] metres away from it.
     */
    private fun point(
        id: String,
        canonical: CanonicalCoordinate,
        observedEast: Double,
        observedNorth: Double,
        pointScope: MapAlignmentScope = scope,
    ): MapAlignmentReferencePoint {
        val observation = MapAlignment(
            id = "obs",
            scope = pointScope,
            eastOffsetMetres = observedEast,
            northOffsetMetres = observedNorth,
            isEnabled = true,
        )
        return MapAlignmentReferencePoint(
            id = id,
            scope = pointScope,
            canonicalCoordinate = canonical,
            selectedMapCoordinate = canonical.toDisplay(observation),
            gpsAccuracyMetres = 2.0,
            capturedAtEpochMillis = 1_757_000_000_000,
        )
    }

    /** Four points spread ~150 m apart, each with the same observed offset. */
    private fun spreadPoints(
        east: Double,
        north: Double,
    ): List<MapAlignmentReferencePoint> = listOf(
        point("p1", origin, east, north),
        point("p2", canonicalOffsetBy(200.0, 0.0), east, north),
        point("p3", canonicalOffsetBy(0.0, 200.0), east, north),
        point("p4", canonicalOffsetBy(200.0, 200.0), east, north),
    )

    // ----- Readiness -----

    @Test
    fun `fewer than four points is not ready`() {
        val all = spreadPoints(10.0, -6.0)
        for (count in 0 until MapAlignmentSolver.MIN_POINTS) {
            val readiness = MapAlignmentSolver.readiness(all.take(count))
            assertTrue(readiness is MapAlignmentSolver.Readiness.NeedMorePoints)
            assertFalse(readiness.isReady)
            assertEquals(count, (readiness as MapAlignmentSolver.Readiness.NeedMorePoints).have)
        }
        assertTrue(MapAlignmentSolver.readiness(all).isReady)
    }

    @Test
    fun `four points clustered around one gate are refused`() {
        // All four within a few metres — measures the gate, not the vineyard.
        val clustered = listOf(
            point("c1", origin, 10.0, -6.0),
            point("c2", canonicalOffsetBy(3.0, 0.0), 10.0, -6.0),
            point("c3", canonicalOffsetBy(0.0, 3.0), 10.0, -6.0),
            point("c4", canonicalOffsetBy(3.0, 3.0), 10.0, -6.0),
        )
        val readiness = MapAlignmentSolver.readiness(clustered)
        assertTrue(readiness is MapAlignmentSolver.Readiness.NotWellSeparated)
        val notSeparated = readiness as MapAlignmentSolver.Readiness.NotWellSeparated
        // Greedy subset collapses the cluster to a single observation.
        assertEquals(1, notSeparated.wellSeparatedCount)
        assertTrue(notSeparated.widestSpanMetres < MapAlignmentSolver.MIN_SEPARATION_METRES)
        assertNull(MapAlignmentSolver.solve(clustered, scope, "a1"))
    }

    @Test
    fun `points just past the separation threshold are accepted`() {
        val step = MapAlignmentSolver.MIN_SEPARATION_METRES + 5.0
        val separated = listOf(
            point("s1", origin, 4.0, 4.0),
            point("s2", canonicalOffsetBy(step, 0.0), 4.0, 4.0),
            point("s3", canonicalOffsetBy(step * 2, 0.0), 4.0, 4.0),
            point("s4", canonicalOffsetBy(step * 3, 0.0), 4.0, 4.0),
        )
        assertTrue(MapAlignmentSolver.readiness(separated).isReady)
    }

    @Test
    fun `a mixed cluster counts only the well-separated points`() {
        // Three tight around one gate plus one far away = 2 distinct places.
        val mixed = listOf(
            point("m1", origin, 5.0, 5.0),
            point("m2", canonicalOffsetBy(2.0, 0.0), 5.0, 5.0),
            point("m3", canonicalOffsetBy(0.0, 2.0), 5.0, 5.0),
            point("m4", canonicalOffsetBy(300.0, 0.0), 5.0, 5.0),
        )
        assertEquals(2, MapAlignmentSolver.wellSeparatedSubset(mixed).size)
        assertFalse(MapAlignmentSolver.readiness(mixed).isReady)
    }

    // ----- Solving -----

    @Test
    fun `a consistent offset is recovered exactly`() {
        val solution = MapAlignmentSolver.solve(spreadPoints(12.0, -7.0), scope, "a1")
        assertNotNull(solution)
        requireNotNull(solution)
        assertEquals(12.0, solution.alignment.eastOffsetMetres, 1e-6)
        assertEquals(-7.0, solution.alignment.northOffsetMetres, 1e-6)
        // Perfectly consistent evidence leaves no residual.
        assertEquals(0.0, solution.meanResidualMetres, 1e-6)
        assertEquals(0.0, solution.maxResidualMetres, 1e-6)
        assertFalse(solution.needsReview)
        assertEquals(4, solution.pointCount)
    }

    @Test
    fun `independent errors average out`() {
        // Same true 10 m east offset, each point with a different small error.
        val noisy = listOf(
            point("n1", origin, 12.0, 0.0),
            point("n2", canonicalOffsetBy(200.0, 0.0), 8.0, 0.0),
            point("n3", canonicalOffsetBy(0.0, 200.0), 11.0, 0.0),
            point("n4", canonicalOffsetBy(200.0, 200.0), 9.0, 0.0),
        )
        val solution = requireNotNull(MapAlignmentSolver.solve(noisy, scope, "a1"))
        // The mean recovers the truth better than any single observation.
        assertEquals(10.0, solution.alignment.eastOffsetMetres, 1e-6)
        assertEquals(0.0, solution.alignment.northOffsetMetres, 1e-6)
        assertTrue(solution.maxResidualMetres <= 2.0 + 1e-6)
        assertFalse("2 m disagreement is not review-worthy", solution.needsReview)
    }

    @Test
    fun `a mismatch a translation cannot explain is surfaced not absorbed`() {
        // One point disagrees wildly — likely a mis-tap or real rotation.
        val inconsistent = listOf(
            point("i1", origin, 10.0, 0.0),
            point("i2", canonicalOffsetBy(200.0, 0.0), 10.0, 0.0),
            point("i3", canonicalOffsetBy(0.0, 200.0), 10.0, 0.0),
            point("i4", canonicalOffsetBy(200.0, 200.0), -30.0, 0.0),
        )
        val solution = requireNotNull(MapAlignmentSolver.solve(inconsistent, scope, "a1"))
        // It still produces a best fit...
        assertEquals(0.0, solution.alignment.eastOffsetMetres, 1e-6)
        // ...but flags it rather than presenting it as trustworthy.
        assertTrue(solution.maxResidualMetres > MapAlignmentSolver.RESIDUAL_REVIEW_METRES)
        assertTrue(solution.needsReview)
    }

    @Test
    fun `the derived alignment reproduces the mean observation through the transform`() {
        val solution = requireNotNull(MapAlignmentSolver.solve(spreadPoints(15.0, -9.0), scope, "a1"))
        val alignment = solution.alignment
        // Round-trip: the candidate draws canonical truth exactly where the
        // operator said the imagery showed it.
        solution.calibration.referencePoints.forEach { point ->
            val drawn = point.canonicalCoordinate.toDisplay(alignment)
            assertEquals(point.selectedMapCoordinate.latitude, drawn.latitude, 1e-9)
            assertEquals(point.selectedMapCoordinate.longitude, drawn.longitude, 1e-9)
        }
    }

    @Test
    fun `evidence is retained and stamped with the alignment it produced`() {
        val solution = requireNotNull(
            MapAlignmentSolver.solve(spreadPoints(6.0, 6.0), scope, "alignment-7"),
        )
        // A summary is not evidence — every point survives.
        assertEquals(4, solution.calibration.referencePoints.size)
        assertTrue(solution.calibration.referencePoints.all { it.alignmentId == "alignment-7" })
        assertTrue(solution.calibration.referencePoints.all { it.scope == scope })
    }

    @Test
    fun `the derived candidate is enabled so it can drive the preview`() {
        val solution = requireNotNull(MapAlignmentSolver.solve(spreadPoints(9.0, 9.0), scope, "a1"))
        assertTrue(solution.alignment.isEnabled)
        assertFalse(solution.alignment.isIdentity)
        assertEquals(scope, solution.alignment.scope)
    }

    @Test
    fun `a zero observed offset yields an enabled identity candidate`() {
        // Imagery genuinely agrees with GPS: a real, calculated "no correction".
        val solution = requireNotNull(MapAlignmentSolver.solve(spreadPoints(0.0, 0.0), scope, "a1"))
        assertTrue(solution.alignment.isEnabled)
        assertTrue(solution.alignment.isIdentity)
        assertEquals(0.0, solution.alignment.magnitudeMetres, 1e-9)
    }

    @Test
    fun `solving refuses evidence from another scope`() {
        val otherScope = MapAlignmentScope("install-b", "v1")
        val foreign = spreadPoints(5.0, 5.0).map { it.copy(scope = otherScope) }
        val thrown = try {
            MapAlignmentSolver.solve(foreign, scope, "a1")
            null
        } catch (e: IllegalArgumentException) {
            e
        }
        assertNotNull("mixed-scope evidence must not be solvable", thrown)
    }

    @Test
    fun `span reporting is symmetric and ignores order`() {
        val points = spreadPoints(3.0, 3.0)
        val span = MapAlignmentSolver.widestSpan(points)
        assertEquals(span, MapAlignmentSolver.widestSpan(points.reversed()), 1e-6)
        // Widest pair is the diagonal of the ~200 m square.
        assertTrue(span > 250.0 && span < 300.0)
        assertEquals(0.0, MapAlignmentSolver.widestSpan(points.take(1)), 0.0)
    }
}
