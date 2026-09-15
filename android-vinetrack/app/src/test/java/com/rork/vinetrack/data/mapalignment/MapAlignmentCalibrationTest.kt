package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A calibration is one alignment plus the evidence that produced it, so every
 * reference point must carry exactly that alignment's scope.
 *
 * Mixed-scope evidence would corrupt any derived offset and make residuals
 * meaningless, so it is rejected at construction rather than filtered away.
 */
class MapAlignmentCalibrationTest {

    private val installA = "install-a"
    private val installB = "install-b"

    private val vineyardScope = MapAlignmentScope(installA, "v1")
    private val blockScope = MapAlignmentScope(installA, "v1", "b1")

    private val canonical = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    private fun alignment(scope: MapAlignmentScope, east: Double = 30.0, north: Double = -15.0) =
        MapAlignment(
            id = "a1",
            scope = scope,
            eastOffsetMetres = east,
            northOffsetMetres = north,
            isEnabled = true,
        )

    private fun point(
        id: String,
        scope: MapAlignmentScope,
        display: AndroidDisplayCoordinate,
        alignmentId: String? = null,
    ) = MapAlignmentReferencePoint(
        id = id,
        scope = scope,
        canonicalCoordinate = canonical,
        selectedMapCoordinate = display,
        capturedAtEpochMillis = 1_757_000_000_000,
        alignmentId = alignmentId,
    )

    /** A point that agrees exactly with [align], so its residual is zero. */
    private fun agreeingPoint(id: String, scope: MapAlignmentScope, align: MapAlignment) =
        point(id, scope, canonical.toDisplay(align))

    @Test
    fun `same-scope points are accepted`() {
        val align = alignment(vineyardScope)
        val calibration = MapAlignmentCalibration(
            alignment = align,
            referencePoints = listOf(
                agreeingPoint("r1", vineyardScope, align),
                agreeingPoint("r2", vineyardScope, align),
            ),
        )

        assertEquals(2, calibration.referencePoints.size)
        assertEquals(2, calibration.pointsInScope.size)
        assertTrue(calibration.acceptable(agreeingPoint("r3", vineyardScope, align)))
        assertEquals(3, calibration.withReferencePoint(agreeingPoint("r3", vineyardScope, align)).referencePoints.size)
    }

    @Test
    fun `another installation's point cannot enter the calibration`() {
        val align = alignment(vineyardScope)
        val foreign = point("foreign", MapAlignmentScope(installB, "v1"), canonical.toDisplay(align))

        assertFalse(MapAlignmentCalibration(align).acceptable(foreign))
        assertThrows(IllegalArgumentException::class.java) {
            MapAlignmentCalibration(alignment = align, referencePoints = listOf(foreign))
        }
        assertThrows(IllegalArgumentException::class.java) {
            MapAlignmentCalibration(align).withReferencePoint(foreign)
        }
    }

    @Test
    fun `another vineyard's point cannot enter the calibration`() {
        val align = alignment(vineyardScope)
        val otherVineyard = point("other-v", MapAlignmentScope(installA, "v2"), canonical.toDisplay(align))

        assertFalse(MapAlignmentCalibration(align).acceptable(otherVineyard))
        assertThrows(IllegalArgumentException::class.java) {
            MapAlignmentCalibration(alignment = align, referencePoints = listOf(otherVineyard))
        }
    }

    @Test
    fun `another block's point cannot enter the calibration`() {
        val align = alignment(blockScope)
        val otherBlock = point(
            "other-b",
            MapAlignmentScope(installA, "v1", "b2"),
            canonical.toDisplay(align),
        )

        assertFalse(MapAlignmentCalibration(align).acceptable(otherBlock))
        assertThrows(IllegalArgumentException::class.java) {
            MapAlignmentCalibration(alignment = align, referencePoints = listOf(otherBlock))
        }
    }

    @Test
    fun `vineyard-scope and block-scope evidence cannot be mixed`() {
        val vineyardAlign = alignment(vineyardScope)
        val blockAlign = alignment(blockScope)

        // A block-scope point may not join a vineyard-scope calibration...
        assertThrows(IllegalArgumentException::class.java) {
            MapAlignmentCalibration(
                alignment = vineyardAlign,
                referencePoints = listOf(
                    agreeingPoint("ok", vineyardScope, vineyardAlign),
                    point("block-point", blockScope, canonical.toDisplay(vineyardAlign)),
                ),
            )
        }

        // ...nor a vineyard-scope point a block-scope calibration.
        assertThrows(IllegalArgumentException::class.java) {
            MapAlignmentCalibration(
                alignment = blockAlign,
                referencePoints = listOf(point("vineyard-point", vineyardScope, canonical.toDisplay(blockAlign))),
            )
        }
    }

    @Test
    fun `residuals contain only valid evidence for the alignment being evaluated`() {
        val align = alignment(vineyardScope)

        // Two agreeing points, plus one that genuinely disagrees by 10 m east.
        val disagreeing = point(
            "r3",
            vineyardScope,
            canonical.toDisplay(
                alignment(vineyardScope, east = align.eastOffsetMetres + 10.0, north = align.northOffsetMetres),
            ),
        )
        val calibration = MapAlignmentCalibration(
            alignment = align,
            referencePoints = listOf(
                agreeingPoint("r1", vineyardScope, align),
                agreeingPoint("r2", vineyardScope, align),
                disagreeing,
            ),
        )

        val residuals = calibration.residuals()
        // One residual per retained point — evidence is never silently dropped.
        assertEquals(3, residuals.size)
        assertEquals(0.0, residuals[0].magnitudeMetres, 1e-6)
        assertEquals(0.0, residuals[1].magnitudeMetres, 1e-6)
        assertEquals(10.0, residuals[2].eastMetres, 1e-6)
        assertEquals(0.0, residuals[2].northMetres, 1e-6)

        // Residuals are computed over exactly the in-scope set, by construction.
        assertEquals(calibration.referencePoints.size, residuals.size)
        assertEquals(calibration.pointsInScope, calibration.referencePoints)
    }

    @Test
    fun `an empty calibration is valid and has no residuals`() {
        val calibration = MapAlignmentCalibration(alignment(vineyardScope))
        assertTrue(calibration.referencePoints.isEmpty())
        assertTrue(calibration.residuals().isEmpty())
    }

    @Test
    fun `evidence may still be collected before an alignment id exists`() {
        val align = alignment(vineyardScope)
        val uncomputed = point("r1", vineyardScope, canonical.toDisplay(align), alignmentId = null)

        // A null alignmentId must remain acceptable while collecting.
        val calibration = MapAlignmentCalibration(align).withReferencePoint(uncomputed)
        assertEquals(1, calibration.referencePoints.size)
        assertNull(calibration.referencePoints.first().alignmentId)
    }
}
