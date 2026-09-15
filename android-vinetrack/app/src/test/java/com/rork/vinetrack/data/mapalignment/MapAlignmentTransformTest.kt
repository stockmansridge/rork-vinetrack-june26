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
    private val canonical = GeoCoordinate(latitude = -33.2835, longitude = 149.0988)

    private fun alignment(east: Double, north: Double, enabled: Boolean = true) =
        MapAlignment(
            id = "a1",
            vineyardId = "v1",
            eastOffsetMetres = east,
            northOffsetMetres = north,
            isEnabled = enabled,
        )

    /** Roughly a tenth of a millimetre on the ground — far below GPS resolution. */
    private const val TIGHT = 1e-12

    @Test
    fun `zero translation returns the original coordinate`() {
        val result = MapAlignmentTransform.toDisplay(canonical, alignment(0.0, 0.0))
        assertEquals(canonical.latitude, result.latitude, 0.0)
        assertEquals(canonical.longitude, result.longitude, 0.0)
        assertEquals(canonical, result)
    }

    @Test
    fun `a disabled alignment is exactly production behaviour`() {
        // Non-zero offsets must still move nothing while disabled.
        val disabled = alignment(25.0, -40.0, enabled = false)
        assertTrue(disabled.isIdentity)
        assertEquals(canonical, MapAlignmentTransform.toDisplay(canonical, disabled))
        assertEquals(canonical, MapAlignmentTransform.toCanonical(canonical, disabled))
        assertEquals(canonical, MapAlignmentTransform.toDisplay(canonical, MapAlignment.none("v1")))
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
            val display = MapAlignmentTransform.toDisplay(canonical, align)
            val roundTrip = MapAlignmentTransform.toCanonical(display, align)
            assertEquals("lat for ($east,$north)", canonical.latitude, roundTrip.latitude, TIGHT)
            assertEquals("lon for ($east,$north)", canonical.longitude, roundTrip.longitude, TIGHT)
        }
    }

    @Test
    fun `inverse then forward also round-trips, for map taps`() {
        val align = alignment(-33.0, 21.0)
        val tapped = GeoCoordinate(-33.2840, 149.0995)
        val asCanonical = MapAlignmentTransform.toCanonical(tapped, align)
        val backToDisplay = MapAlignmentTransform.toDisplay(asCanonical, align)
        assertEquals(tapped.latitude, backToDisplay.latitude, TIGHT)
        assertEquals(tapped.longitude, backToDisplay.longitude, TIGHT)
    }

    @Test
    fun `positive east and north move in the correct direction`() {
        val result = MapAlignmentTransform.toDisplay(canonical, alignment(100.0, 100.0))
        assertTrue("east offset must increase longitude", result.longitude > canonical.longitude)
        assertTrue("north offset must increase latitude", result.latitude > canonical.latitude)
    }

    @Test
    fun `negative east and north move in the correct direction`() {
        val result = MapAlignmentTransform.toDisplay(canonical, alignment(-100.0, -100.0))
        assertTrue("west offset must decrease longitude", result.longitude < canonical.longitude)
        assertTrue("south offset must decrease latitude", result.latitude < canonical.latitude)
    }

    @Test
    fun `translation magnitude matches the requested metres`() {
        val align = alignment(50.0, 80.0)
        val display = MapAlignmentTransform.toDisplay(canonical, align)
        assertEquals(50.0, MapAlignmentTransform.eastMetresBetween(canonical, display), 1e-6)
        assertEquals(80.0, MapAlignmentTransform.northMetresBetween(canonical, display), 1e-6)
    }

    @Test
    fun `transforming does not mutate the original coordinate or alignment`() {
        val align = alignment(64.0, -19.0)
        val originalCoord = canonical.copy()
        val originalAlign = align.copy()

        val display = MapAlignmentTransform.toDisplay(canonical, align)
        MapAlignmentTransform.toCanonical(display, align)

        assertEquals("input coordinate must be untouched", originalCoord, canonical)
        assertEquals("alignment must be untouched", originalAlign, align)
        // And the derived value is genuinely a different, new coordinate.
        assertNotEquals(canonical, display)
    }

    @Test
    fun `an enabled non-zero alignment is not identity`() {
        assertFalse(alignment(1.0, 0.0).isIdentity)
        assertFalse(alignment(0.0, -1.0).isIdentity)
        assertTrue(alignment(0.0, 0.0).isIdentity)
    }

    @Test
    fun `reference point reports its observed discrepancy as evidence only`() {
        val align = alignment(30.0, -15.0)
        val onImage = MapAlignmentTransform.toDisplay(canonical, align)
        val point = MapAlignmentReferencePoint(
            id = "r1",
            canonicalCoordinate = canonical,
            selectedMapCoordinate = onImage,
            gpsAccuracyMetres = 3.5,
            capturedAtEpochMillis = 1_757_000_000_000,
            rowNumber = 12,
            rowPosition = MapAlignmentRowPosition.Start,
        )
        assertEquals(30.0, point.observedEastOffsetMetres, 1e-6)
        assertEquals(-15.0, point.observedNorthOffsetMetres, 1e-6)
        // The canonical coordinate it carries is unchanged by being measured.
        assertEquals(canonical, point.canonicalCoordinate)
    }

    @Test
    fun `alignment magnitude is reported in metres`() {
        assertEquals(5.0, alignment(3.0, 4.0).magnitudeMetres, 1e-9)
    }
}
