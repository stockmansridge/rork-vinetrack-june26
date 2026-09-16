package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The advisory outlier rule, driven by the residual pattern seen in the field.
 *
 * The behaviour under test is a judgement about ONE point relative to its
 * siblings, deliberately separate from the overall quality verdict. The two
 * most important properties are that it flags the real field case, and that it
 * stays silent when a calibration is merely poor everywhere.
 */
class MapAlignmentOutliersTest {

    private val scope = MapAlignmentScope("install-a", "vineyard-1")
    private val origin = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    /**
     * Move [from] by a known east/north translation, using the SAME production
     * transform the solver uses. Going through the public alignment path keeps
     * the test honest: the residuals below are computed by real code rather
     * than asserted into existence.
     */
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

    /**
     * A reference whose observed offset is [eastMetres]/[northMetres] from its
     * canonical position, built through the production transform.
     */
    private fun reference(
        id: String,
        placeEastMetres: Double,
        placeNorthMetres: Double,
        eastMetres: Double,
        northMetres: Double,
    ): MapAlignmentReferencePoint {
        val canonical = shift(origin, placeEastMetres, placeNorthMetres)
        val marked = shift(canonical, eastMetres, northMetres)
        return MapAlignmentReferencePoint(
            id = id,
            scope = scope,
            canonicalCoordinate = canonical,
            selectedMapCoordinate = AndroidDisplayCoordinate(marked.latitude, marked.longitude),
            gpsAccuracyMetres = 2.5,
            capturedAtEpochMillis = 1_757_000_000_000,
        )
    }

    /** Four well-spread references whose east offsets are [offsets]. */
    private fun solutionWithEastOffsets(offsets: List<Double>): MapAlignmentSolver.Solution {
        val points = offsets.mapIndexed { index, east ->
            reference(
                id = "p$index",
                placeEastMetres = index * 60.0,
                placeNorthMetres = if (index % 2 == 0) 0.0 else 55.0,
                eastMetres = east,
                northMetres = 0.0,
            )
        }
        return requireNotNull(
            MapAlignmentSolver.solve(points, scope, "candidate", 1_757_000_000_000),
        )
    }

    @Test
    fun `the field pattern flags point 3 and only point 3`() {
        // Residuals of about 1.4, 1.5, 6.1 and 1.3 m around the median offset.
        // Median east offset is 10.0, so residuals are the deviations from it.
        val solution = solutionWithEastOffsets(listOf(8.6, 8.5, 16.1, 11.3))

        val review = MapAlignmentOutliers.review(solution)

        assertTrue(review.hasSuspects)
        assertEquals(1, review.suspectCount)
        assertEquals(3, review.suspects.single().pointNumber)
        assertTrue(review.isSuspect("p2"))
        assertFalse(review.isSuspect("p0"))
        assertFalse(review.isSuspect("p1"))
        assertFalse(review.isSuspect("p3"))
    }

    @Test
    fun `a uniformly poor calibration blames no individual point`() {
        // 4.0, 4.1, 4.3, 4.2 — genuinely poor overall, but nothing stands out.
        // Claiming one of these is uniquely bad would send the operator to
        // re-walk a point no worse than the rest, and would imply the
        // calibration becomes fine once it is "fixed". It would not.
        val solution = solutionWithEastOffsets(listOf(6.0, 14.1, 5.7, 14.2))

        val review = MapAlignmentOutliers.review(solution)

        assertFalse(
            "a poor overall fit is the Check alignment rule's job, not this one",
            review.hasSuspects,
        )
        // And the overall rule still does speak up about it, which is the
        // whole reason this one can afford to stay quiet.
        assertEquals(
            MapAlignmentSolver.Quality.CheckAlignment,
            solution.quality,
        )
    }

    @Test
    fun `near-perfect evidence never flags sub-metre noise`() {
        // 0.2 / 0.3 / 0.2 / 0.9: a pure multiple of the median would flag the
        // 0.9 as 4.5x typical. It is noise, and re-walking it gains nothing.
        val review = MapAlignmentOutliers.review(
            points = listOf(
                reference("a", 0.0, 0.0, 0.0, 0.0),
                reference("b", 60.0, 0.0, 0.0, 0.0),
                reference("c", 0.0, 60.0, 0.0, 0.0),
                reference("d", 60.0, 60.0, 0.0, 0.0),
            ),
            residualMetres = listOf(0.2, 0.3, 0.2, 0.9),
        )

        assertFalse(review.hasSuspects)
        assertEquals(
            "the absolute floor must win over the multiple here",
            MapAlignmentOutliers.MIN_FLAG_RESIDUAL_METRES,
            review.thresholdMetres,
            1e-9,
        )
    }

    @Test
    fun `the threshold is the greater of the floor and twice the median`() {
        val points = List(4) { reference("p$it", it * 60.0, 0.0, 0.0, 0.0) }

        // Tight evidence: floor applies.
        val tight = MapAlignmentOutliers.review(points, listOf(0.4, 0.5, 0.6, 0.5))
        assertEquals(3.0, tight.thresholdMetres, 1e-9)

        // Loose evidence: the multiple applies and is higher than the floor.
        val loose = MapAlignmentOutliers.review(points, listOf(4.0, 4.0, 4.0, 4.0))
        assertEquals(8.0, loose.thresholdMetres, 1e-9)
        assertFalse("all four agree with each other", loose.hasSuspects)
    }

    @Test
    fun `the boundary is strictly greater than the threshold`() {
        val points = List(4) { reference("p$it", it * 60.0, 0.0, 0.0, 0.0) }

        // Median 1.0 -> threshold max(3.0, 2.0) = 3.0.
        val atThreshold = MapAlignmentOutliers.review(points, listOf(1.0, 1.0, 1.0, 3.0))
        assertFalse("exactly at the threshold is not flagged", atThreshold.hasSuspects)

        val above = MapAlignmentOutliers.review(points, listOf(1.0, 1.0, 1.0, 3.01))
        assertTrue(above.hasSuspects)
    }

    @Test
    fun `fewer than four references produce no accusation`() {
        // With two or three points a "typical" residual is not a description of
        // a group, and calling one of them odd is meaningless.
        val two = listOf(reference("a", 0.0, 0.0, 0.0, 0.0), reference("b", 60.0, 0.0, 0.0, 0.0))
        assertFalse(MapAlignmentOutliers.review(two, listOf(0.5, 40.0)).hasSuspects)

        val three = two + reference("c", 0.0, 60.0, 0.0, 0.0)
        assertFalse(MapAlignmentOutliers.review(three, listOf(0.5, 0.6, 40.0)).hasSuspects)

        assertEquals(
            MapAlignmentSolver.MIN_POINTS,
            MapAlignmentOutliers.MIN_POINTS_FOR_DETECTION,
        )
    }

    @Test
    fun `multiple suspects are reported together`() {
        val points = List(5) { reference("p$it", it * 60.0, 0.0, 0.0, 0.0) }

        val review = MapAlignmentOutliers.review(points, listOf(1.0, 9.0, 1.2, 11.0, 1.1))

        assertEquals(2, review.suspectCount)
        assertEquals(listOf(2, 4), review.suspects.map { it.pointNumber })
        assertEquals("Check 2 reference points", review.title())
        assertEquals("Review 2 reference points", review.reviewActionLabel())
    }

    @Test
    fun `wording names the point and both possible causes without blaming one`() {
        val solution = solutionWithEastOffsets(listOf(8.6, 8.5, 16.1, 11.3))

        val review = MapAlignmentOutliers.review(solution)
        val message = review.message()

        assertEquals("Check reference point 3", review.title())
        assertEquals("Review point 3", review.reviewActionLabel())
        assertTrue(message.contains("Point 3 differs"))
        assertTrue(message.contains("Typical residual:"))
        // We cannot tell from a residual whether the GPS or the image mark is
        // at fault, so the wording must offer both rather than pick one.
        assertTrue(message.contains("GPS position or satellite-image point"))
        assertFalse(message.lowercase().contains("wrong"))
        assertFalse(message.lowercase().contains("invalid"))
    }

    @Test
    fun `the list label recommends review rather than declaring a point bad`() {
        val solution = solutionWithEastOffsets(listOf(8.6, 8.5, 16.1, 11.3))
        val suspect = MapAlignmentOutliers.review(solution).suspects.single()

        assertEquals("Point 3 — Review recommended", suspect.listLabel)
        assertFalse(suspect.listLabel.lowercase().contains("wrong"))
        assertFalse(suspect.listLabel.lowercase().contains("bad"))
    }

    @Test
    fun `fixing the suspect point clears the warning`() {
        val flagged = solutionWithEastOffsets(listOf(8.6, 8.5, 16.1, 11.3))
        assertTrue(MapAlignmentOutliers.review(flagged).hasSuspects)

        // The operator re-marks point 3; recalculating rebuilds the candidate.
        val corrected = solutionWithEastOffsets(listOf(8.6, 8.5, 10.2, 11.3))

        val review = MapAlignmentOutliers.review(corrected)
        assertFalse("a corrected point must stop warning", review.hasSuspects)
        assertNull(review.suspectFor("p2"))
    }

    @Test
    fun `the review changes no arithmetic and removes no evidence`() {
        val solution = solutionWithEastOffsets(listOf(8.6, 8.5, 16.1, 11.3))
        val alignmentBefore = solution.alignment
        val pointsBefore = solution.calibration.referencePoints

        MapAlignmentOutliers.review(solution)

        // The authoritative median estimator is untouched, the flagged point is
        // still part of the evidence, and the quality verdict is unchanged.
        assertEquals(alignmentBefore, solution.alignment)
        assertEquals(4, solution.pointCount)
        assertEquals(pointsBefore, solution.calibration.referencePoints)
        assertTrue(solution.calibration.referencePoints.any { it.id == "p2" })
    }

    @Test
    fun `mismatched inputs are safe rather than throwing`() {
        val points = List(4) { reference("p$it", it * 60.0, 0.0, 0.0, 0.0) }

        assertFalse(MapAlignmentOutliers.review(emptyList(), emptyList()).hasSuspects)
        assertFalse(MapAlignmentOutliers.review(points, listOf(1.0, 2.0)).hasSuspects)
    }
}
