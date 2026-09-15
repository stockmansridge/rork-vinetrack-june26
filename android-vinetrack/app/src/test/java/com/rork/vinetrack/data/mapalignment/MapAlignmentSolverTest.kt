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
 * The properties that matter: the estimator is ROBUST (one wrong point must not
 * drag the result), eligibility does not demand wide separation, duplicates are
 * refused, and a fit a single shift cannot explain is SURFACED rather than
 * absorbed or silently trimmed.
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
     * A reference point standing at [canonical] whose marked image point was
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

    /** Four distinct locations, each with the same observed offset. */
    private fun spreadPoints(
        east: Double,
        north: Double,
    ): List<MapAlignmentReferencePoint> = listOf(
        point("p1", origin, east, north),
        point("p2", canonicalOffsetBy(200.0, 0.0), east, north),
        point("p3", canonicalOffsetBy(0.0, 200.0), east, north),
        point("p4", canonicalOffsetBy(200.0, 200.0), east, north),
    )

    // ----- Readiness: count and distinctness only -----

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
    fun `four references do NOT need to be far apart to be eligible`() {
        // A small block: every point is well inside the old 40 m gate, but each
        // is a genuinely distinct location. This must be calibratable.
        val smallBlock = listOf(
            point("s1", origin, 6.0, 2.0),
            point("s2", canonicalOffsetBy(15.0, 0.0), 6.0, 2.0),
            point("s3", canonicalOffsetBy(0.0, 15.0), 6.0, 2.0),
            point("s4", canonicalOffsetBy(15.0, 15.0), 6.0, 2.0),
        )
        assertTrue(MapAlignmentSolver.widestSpan(smallBlock) < 40.0)
        assertTrue(
            "a small block must still be calibratable",
            MapAlignmentSolver.readiness(smallBlock).isReady,
        )
        val solution = requireNotNull(MapAlignmentSolver.solve(smallBlock, scope, "a1"))
        assertEquals(6.0, solution.alignment.eastOffsetMetres, 1e-6)
        // Narrow spread is reported as a quality signal, not an eligibility failure.
        assertTrue(solution.spreadIsNarrow)
    }

    @Test
    fun `references at the same place are refused as duplicates`() {
        val duplicated = listOf(
            point("d1", origin, 10.0, -6.0),
            point("d2", canonicalOffsetBy(2.0, 0.0), 10.0, -6.0),
            point("d3", canonicalOffsetBy(0.0, 3.0), 10.0, -6.0),
            point("d4", canonicalOffsetBy(300.0, 0.0), 10.0, -6.0),
        )
        val readiness = MapAlignmentSolver.readiness(duplicated)
        assertTrue(readiness is MapAlignmentSolver.Readiness.DuplicateLocations)
        // d2 and d3 both collide with d1.
        assertEquals(2, (readiness as MapAlignmentSolver.Readiness.DuplicateLocations).duplicateCount)
        assertNull(MapAlignmentSolver.solve(duplicated, scope, "a1"))
    }

    @Test
    fun `a point just past the near-duplicate threshold is accepted`() {
        val justInside = canonicalOffsetBy(MapAlignmentSolver.NEAR_DUPLICATE_METRES - 2.0, 0.0)
        val justOutside = canonicalOffsetBy(MapAlignmentSolver.NEAR_DUPLICATE_METRES + 2.0, 0.0)
        val existing = listOf(point("e1", origin, 5.0, 5.0))

        assertTrue(MapAlignmentSolver.isNearDuplicate(justInside, existing))
        assertFalse(MapAlignmentSolver.isNearDuplicate(justOutside, existing))
    }

    @Test
    fun `a reference being retaken does not collide with itself`() {
        val points = spreadPoints(5.0, 5.0)
        val itsOwnPlace = points[0].canonicalCoordinate

        // Without the exclusion it would look like a duplicate of itself.
        assertTrue(MapAlignmentSolver.isNearDuplicate(itsOwnPlace, points))
        assertFalse(
            "retaking a point must not collide with its own previous position",
            MapAlignmentSolver.isNearDuplicate(itsOwnPlace, points, excludingId = "p1"),
        )
        assertTrue(MapAlignmentSolver.duplicateLocations(points, excludingId = "p1").isEmpty())
    }

    // ----- The robust estimator -----

    @Test
    fun `a consistent offset is recovered exactly`() {
        val solution = requireNotNull(MapAlignmentSolver.solve(spreadPoints(12.0, -7.0), scope, "a1"))
        assertEquals(12.0, solution.alignment.eastOffsetMetres, 1e-6)
        assertEquals(-7.0, solution.alignment.northOffsetMetres, 1e-6)
        assertEquals(0.0, solution.rmsResidualMetres, 1e-6)
        assertEquals(0.0, solution.maxResidualMetres, 1e-6)
        assertEquals(MapAlignmentSolver.Quality.Good, solution.quality)
        assertEquals(4, solution.pointCount)
    }

    @Test
    fun `one bad reference does not drag the candidate`() {
        // Three points agree closely; the fourth is an obvious mistake —
        // a post marked on the wrong side of the block.
        val withOutlier = listOf(
            point("o1", origin, 5.0, 2.0),
            point("o2", canonicalOffsetBy(200.0, 0.0), 5.5, 2.5),
            point("o3", canonicalOffsetBy(0.0, 200.0), 4.5, 1.5),
            point("o4", canonicalOffsetBy(200.0, 200.0), 30.0, -20.0),
        )
        val solution = requireNotNull(MapAlignmentSolver.solve(withOutlier, scope, "a1"))

        // East offsets 4.5/5.0/5.5/30.0 -> median 5.25.
        // North offsets -20.0/1.5/2.0/2.5 -> median 1.75.
        // A mean would have produced 11.25 E / -3.5 N — dragged clean out of
        // the cluster, and in the wrong hemisphere for north.
        assertEquals(5.25, solution.alignment.eastOffsetMetres, 1e-6)
        assertEquals(1.75, solution.alignment.northOffsetMetres, 1e-6)
        assertTrue(solution.alignment.eastOffsetMetres in 4.0..6.5)
        assertTrue(solution.alignment.northOffsetMetres in 1.0..3.0)

        // The outlier is not hidden: it is retained and surfaced.
        assertEquals(4, solution.pointCount)
        assertEquals(3, solution.worstPointIndex)
        assertTrue(solution.maxResidualMetres > MapAlignmentSolver.GOOD_MAX_RESIDUAL_METRES)
        assertEquals(MapAlignmentSolver.Quality.CheckAlignment, solution.quality)
    }

    @Test
    fun `median uses the standard even-count rule`() {
        assertEquals(3.0, MapAlignmentSolver.median(listOf(1.0, 3.0, 5.0)), 1e-9)
        assertEquals(4.0, MapAlignmentSolver.median(listOf(1.0, 3.0, 5.0, 7.0)), 1e-9)
        // Order must not matter.
        assertEquals(4.0, MapAlignmentSolver.median(listOf(7.0, 1.0, 5.0, 3.0)), 1e-9)
    }

    // ----- Quality scoring -----

    @Test
    fun `a tight fit is Good`() {
        val tight = listOf(
            point("q1", origin, 5.0, 2.0),
            point("q2", canonicalOffsetBy(200.0, 0.0), 5.5, 2.5),
            point("q3", canonicalOffsetBy(0.0, 200.0), 4.5, 1.5),
            point("q4", canonicalOffsetBy(200.0, 200.0), 5.2, 2.2),
        )
        val solution = requireNotNull(MapAlignmentSolver.solve(tight, scope, "a1"))
        assertTrue(solution.rmsResidualMetres <= MapAlignmentSolver.GOOD_RMS_RESIDUAL_METRES)
        assertTrue(solution.maxResidualMetres <= MapAlignmentSolver.GOOD_MAX_RESIDUAL_METRES)
        assertEquals(MapAlignmentSolver.Quality.Good, solution.quality)
        assertFalse(solution.needsReview)
    }

    @Test
    fun `a high RMS is Check alignment even with no single huge residual`() {
        // Every point is off by ~4 m in a different direction: no outlier, but
        // the evidence simply does not agree on one shift.
        val scattered = listOf(
            point("r1", origin, 4.0, 0.0),
            point("r2", canonicalOffsetBy(200.0, 0.0), -4.0, 0.0),
            point("r3", canonicalOffsetBy(0.0, 200.0), 0.0, 4.0),
            point("r4", canonicalOffsetBy(200.0, 200.0), 0.0, -4.0),
        )
        val solution = requireNotNull(MapAlignmentSolver.solve(scattered, scope, "a1"))
        assertTrue(solution.rmsResidualMetres > MapAlignmentSolver.GOOD_RMS_RESIDUAL_METRES)
        assertTrue(solution.maxResidualMetres <= MapAlignmentSolver.GOOD_MAX_RESIDUAL_METRES)
        // RMS alone is enough to withhold "Good".
        assertEquals(MapAlignmentSolver.Quality.CheckAlignment, solution.quality)
    }

    @Test
    fun `a single large residual is Check alignment even when RMS is acceptable`() {
        val solution = requireNotNull(
            MapAlignmentSolver.solve(
                listOf(
                    point("x1", origin, 5.0, 0.0),
                    point("x2", canonicalOffsetBy(200.0, 0.0), 5.0, 0.0),
                    point("x3", canonicalOffsetBy(0.0, 200.0), 5.0, 0.0),
                    point("x4", canonicalOffsetBy(200.0, 200.0), 5.0, 0.0),
                    point("x5", canonicalOffsetBy(400.0, 0.0), 5.0, 0.0),
                    point("x6", canonicalOffsetBy(0.0, 400.0), 5.0, 0.0),
                    point("x7", canonicalOffsetBy(400.0, 400.0), 5.0, 0.0),
                    point("x8", canonicalOffsetBy(600.0, 0.0), 5.0, 0.0),
                    // One point 8 m out: RMS stays low across nine points.
                    point("x9", canonicalOffsetBy(0.0, 600.0), 13.0, 0.0),
                ),
                scope,
                "a1",
            ),
        )
        assertEquals(5.0, solution.alignment.eastOffsetMetres, 1e-6)
        assertTrue(solution.rmsResidualMetres <= MapAlignmentSolver.GOOD_RMS_RESIDUAL_METRES)
        assertTrue(solution.maxResidualMetres > MapAlignmentSolver.GOOD_MAX_RESIDUAL_METRES)
        assertEquals(MapAlignmentSolver.Quality.CheckAlignment, solution.quality)
        assertEquals(8, solution.worstPointIndex)
    }

    @Test
    fun `RMS weights the worst point more heavily than a plain mean would`() {
        val solution = requireNotNull(
            MapAlignmentSolver.solve(
                listOf(
                    point("w1", origin, 5.0, 0.0),
                    point("w2", canonicalOffsetBy(200.0, 0.0), 5.0, 0.0),
                    point("w3", canonicalOffsetBy(0.0, 200.0), 5.0, 0.0),
                    point("w4", canonicalOffsetBy(200.0, 200.0), 25.0, 0.0),
                ),
                scope,
                "a1",
            ),
        )
        val magnitudes = solution.residualMagnitudesMetres
        val plainMean = magnitudes.average()
        assertTrue(
            "RMS must not flatter a fit containing one bad point",
            solution.rmsResidualMetres > plainMean,
        )
    }

    // ----- Evidence integrity -----

    @Test
    fun `the derived alignment reproduces the median observation through the transform`() {
        val solution = requireNotNull(MapAlignmentSolver.solve(spreadPoints(15.0, -9.0), scope, "a1"))
        solution.calibration.referencePoints.forEach { point ->
            val drawn = point.canonicalCoordinate.toDisplay(solution.alignment)
            assertEquals(point.selectedMapCoordinate.latitude, drawn.latitude, 1e-9)
            assertEquals(point.selectedMapCoordinate.longitude, drawn.longitude, 1e-9)
        }
    }

    @Test
    fun `evidence is retained and stamped with the alignment it produced`() {
        val solution = requireNotNull(
            MapAlignmentSolver.solve(spreadPoints(6.0, 6.0), scope, "alignment-7"),
        )
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
        assertTrue(span > 250.0 && span < 300.0)
        assertEquals(0.0, MapAlignmentSolver.widestSpan(points.take(1)), 0.0)
    }
}
