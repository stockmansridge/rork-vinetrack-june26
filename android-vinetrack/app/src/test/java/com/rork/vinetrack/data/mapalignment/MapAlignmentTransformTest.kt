package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The alignment transform is display-only maths. These tests pin the two
 * properties later integration depends on: a zero/disabled alignment is
 * behaviourally invisible, and the inverse exactly undoes the forward.
 */
class MapAlignmentTransformTest {

    // Orange, NSW — representative southern-hemisphere vineyard latitude.
    private val canonical = CanonicalCoordinate(latitude = -33.2835, longitude = 149.0988)

    private val scope = MapAlignmentScope(
        androidInstallationId = "install-a",
        vineyardId = "v1",
    )

    private fun alignment(east: Double, north: Double, enabled: Boolean = true) =
        MapAlignment(
            id = "a1",
            scope = scope,
            eastOffsetMetres = east,
            northOffsetMetres = north,
            isEnabled = enabled,
        )

    @Test
    fun `canonical converts to a display coordinate`() {
        val display: AndroidDisplayCoordinate = canonical.toDisplay(alignment(40.0, 25.0))
        assertNotEquals(canonical.latitude, display.latitude)
        assertNotEquals(canonical.longitude, display.longitude)
    }

    @Test
    fun `display converts back to a canonical coordinate`() {
        val align = alignment(40.0, 25.0)
        val display = canonical.toDisplay(align)
        val back: CanonicalCoordinate = display.toCanonical(align)
        assertEquals(canonical.latitude, back.latitude, TIGHT)
        assertEquals(canonical.longitude, back.longitude, TIGHT)
    }

    @Test
    fun `zero translation leaves the position unchanged`() {
        val result = canonical.toDisplay(alignment(0.0, 0.0))
        assertEquals(canonical.latitude, result.latitude, 0.0)
        assertEquals(canonical.longitude, result.longitude, 0.0)
    }

    @Test
    fun `a disabled alignment is exactly production behaviour`() {
        // Non-zero offsets must still move nothing while disabled.
        val disabled = alignment(25.0, -40.0, enabled = false)
        assertTrue(disabled.isIdentity)

        val display = canonical.toDisplay(disabled)
        assertEquals(canonical.latitude, display.latitude, 0.0)
        assertEquals(canonical.longitude, display.longitude, 0.0)

        val tap = AndroidDisplayCoordinate(-33.2840, 149.0995)
        val asCanonical = tap.toCanonical(disabled)
        assertEquals(tap.latitude, asCanonical.latitude, 0.0)
        assertEquals(tap.longitude, asCanonical.longitude, 0.0)

        val none = canonical.toDisplay(MapAlignment.none(scope))
        assertEquals(canonical.latitude, none.latitude, 0.0)
        assertEquals(canonical.longitude, none.longitude, 0.0)
    }

    @Test
    fun `forward then inverse returns the original canonical coordinate`() {
        listOf(
            12.5 to 7.25,
            -12.5 to 7.25,
            12.5 to -7.25,
            -12.5 to -7.25,
            0.0 to 18.0,
            18.0 to 0.0,
            250.0 to -340.0,
        ).forEach { (east, north) ->
            val align = alignment(east, north)
            val roundTrip = canonical.toDisplay(align).toCanonical(align)
            assertEquals("lat for ($east,$north)", canonical.latitude, roundTrip.latitude, TIGHT)
            assertEquals("lon for ($east,$north)", canonical.longitude, roundTrip.longitude, TIGHT)
        }
    }

    @Test
    fun `inverse then forward also round-trips, for map taps`() {
        val align = alignment(-33.0, 21.0)
        val tapped = AndroidDisplayCoordinate(-33.2840, 149.0995)
        val back = tapped.toCanonical(align).toDisplay(align)
        assertEquals(tapped.latitude, back.latitude, TIGHT)
        assertEquals(tapped.longitude, back.longitude, TIGHT)
    }

    @Test
    fun `positive east and north move in the correct direction`() {
        val result = canonical.toDisplay(alignment(100.0, 100.0))
        assertTrue("east offset must increase longitude", result.longitude > canonical.longitude)
        assertTrue("north offset must increase latitude", result.latitude > canonical.latitude)
    }

    @Test
    fun `negative east and north move in the correct direction`() {
        val result = canonical.toDisplay(alignment(-100.0, -100.0))
        assertTrue("west offset must decrease longitude", result.longitude < canonical.longitude)
        assertTrue("south offset must decrease latitude", result.latitude < canonical.latitude)
    }

    @Test
    fun `translation magnitude matches the requested metres`() {
        val align = alignment(50.0, 80.0)
        val display = canonical.toDisplay(align)
        val observed = MapAlignmentTransform.observedOffset(canonical, display)
        assertEquals(50.0, observed.eastMetres, 1e-6)
        assertEquals(80.0, observed.northMetres, 1e-6)
    }

    @Test
    fun `transforming does not mutate the original coordinate or alignment`() {
        val align = alignment(64.0, -19.0)
        val originalCoord = canonical.copy()
        val originalAlign = align.copy()

        canonical.toDisplay(align).toCanonical(align)

        assertEquals("input coordinate must be untouched", originalCoord, canonical)
        assertEquals("alignment must be untouched", originalAlign, align)
    }

    @Test
    fun `an enabled non-zero alignment is not identity`() {
        assertFalse(alignment(1.0, 0.0).isIdentity)
        assertFalse(alignment(0.0, -1.0).isIdentity)
        assertTrue(alignment(0.0, 0.0).isIdentity)
    }

    @Test
    fun `reference point preserves separate canonical and display values`() {
        val align = alignment(30.0, -15.0)
        val onImage = canonical.toDisplay(align)
        val point = MapAlignmentReferencePoint(
            id = "r1",
            scope = scope,
            canonicalCoordinate = canonical,
            selectedMapCoordinate = onImage,
            gpsAccuracyMetres = 3.5,
            capturedAtEpochMillis = 1_757_000_000_000,
            rowNumber = 12,
            rowPosition = MapAlignmentRowPosition.Start,
        )

        // The two positions stay distinct and separately typed — the canonical
        // one is never overwritten by the operator's map selection.
        assertEquals(canonical, point.canonicalCoordinate)
        assertEquals(onImage, point.selectedMapCoordinate)
        assertNotEquals(point.canonicalCoordinate.latitude, point.selectedMapCoordinate.latitude)

        assertEquals(30.0, point.observedEastOffsetMetres, 1e-6)
        assertEquals(-15.0, point.observedNorthOffsetMetres, 1e-6)
    }

    @Test
    fun `calibration retains individual evidence and reports residuals`() {
        // Evidence must never be reduced to just the two offset numbers.
        val align = alignment(30.0, -15.0)
        val point = MapAlignmentReferencePoint(
            id = "r1",
            scope = scope,
            canonicalCoordinate = canonical,
            selectedMapCoordinate = canonical.toDisplay(align),
            capturedAtEpochMillis = 1_757_000_000_000,
            alignmentId = align.id,
        )
        val calibration = MapAlignmentCalibration(alignment = align, referencePoints = listOf(point))

        assertEquals(1, calibration.referencePoints.size)
        assertEquals(1, calibration.pointsInScope.size)
        assertEquals(align.id, calibration.referencePoints.first().alignmentId)
        // This point agrees exactly with the alignment, so it has no residual.
        assertEquals(0.0, calibration.residuals().first().magnitudeMetres, 1e-6)
    }

    @Test
    fun `alignment magnitude is reported in metres`() {
        assertEquals(5.0, alignment(3.0, 4.0).magnitudeMetres, 1e-9)
    }

    private companion object {
        /** Roughly a tenth of a millimetre on the ground — far below GPS resolution. */
        const val TIGHT = 1e-12
    }
}
