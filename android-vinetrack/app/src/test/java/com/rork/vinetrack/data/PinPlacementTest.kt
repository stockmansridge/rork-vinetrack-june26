package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * One-shot immutable pin placement tests — mirrored by iOS
 * `PinManualPlacementTests`. Uses the shared parity fixture: straight
 * north-south rows anchored at (-34.0, 138.0), rows ~3.7 m apart
 * (0.00004° longitude), 0.001° latitude ≈ 111 m.
 */
class PinPlacementTest {

    private fun rowLongitude(row: Int): Double = 138.0 + (row - 1) * 0.00004

    private fun fixtureBlock(id: String = "block-1"): Paddock = Paddock(
        id = id,
        vineyardId = "vineyard-1",
        name = "Block 1",
        rowWidth = 3.7,
        polygonPoints = listOf(
            CoordinatePoint(-34.0005, 137.99995),
            CoordinatePoint(-34.0005, 138.00015),
            CoordinatePoint(-33.9985, 138.00015),
            CoordinatePoint(-33.9985, 137.99995),
        ),
        rows = (1..3).map { row ->
            PaddockRow(
                number = row,
                startPoint = CoordinatePoint(-34.0, rowLongitude(row)),
                endPoint = CoordinatePoint(-33.999, rowLongitude(row)),
            )
        },
    )

    /** A block the fix is inside, but with no usable row geometry at all. */
    private fun bareBlock(id: String = "bare-block"): Paddock = Paddock(
        id = id,
        vineyardId = "vineyard-1",
        name = "Bare",
        polygonPoints = listOf(
            CoordinatePoint(-34.0005, 137.99995),
            CoordinatePoint(-34.0005, 138.00015),
            CoordinatePoint(-33.9985, 138.00015),
            CoordinatePoint(-33.9985, 137.99995),
        ),
    )

    @Test
    fun `pin inside a mapped block snaps and resolves the block by containment`() {
        val block = fixtureBlock()
        val result = PinPlacement.resolve(
            paddocks = listOf(block),
            selectedPaddockId = null,
            latitude = -33.9995,
            longitude = rowLongitude(2) + 0.00001, // ~0.9 m east of row 2
            side = "left",
        )
        assertEquals(PinSnapState.SNAPPED, result.snapState)
        assertTrue(result.snappedToRow)
        assertEquals(block.id, result.paddockId)
        assertEquals(2.0, result.pinRowNumber!!, 1e-9)
        assertEquals("left", result.pinSide)
        // Snapped point sits on the row-2 centreline.
        assertEquals(rowLongitude(2), result.snappedLongitude!!, 1e-7)
        assertEquals(-33.9995, result.snappedLatitude!!, 1e-6)
        // ~55.7 m along a 111 m row from its southern start.
        assertTrue(abs(result.alongRowDistanceM!! - 55.66) < 1.0)
        assertNotNull(result.toAttachment())
    }

    @Test
    fun `pin outside every block records an explicit NO_BLOCK state`() {
        val result = PinPlacement.resolve(
            paddocks = listOf(fixtureBlock()),
            selectedPaddockId = null,
            latitude = -35.0,
            longitude = 139.0,
            side = "right",
        )
        assertEquals(PinSnapState.NO_BLOCK, result.snapState)
        assertFalse(result.snappedToRow)
        assertNull(result.paddockId)
        assertNull(result.pinRowNumber)
        assertNull(result.snappedLatitude)
        assertNull(result.toAttachment())
    }

    @Test
    fun `block without row geometry keeps the block but stays honestly unsnapped`() {
        val bare = bareBlock()
        val result = PinPlacement.resolve(
            paddocks = listOf(bare),
            selectedPaddockId = bare.id,
            latitude = -33.9995,
            longitude = 138.0001,
            side = "left",
        )
        assertEquals(PinSnapState.NO_ROW_GEOMETRY, result.snapState)
        assertFalse(result.snappedToRow)
        assertEquals(bare.id, result.paddockId)
        assertNull(result.pinRowNumber)
        assertNull(result.toAttachment())
    }

    @Test
    fun `pin without a fix records NO_LOCATION and keeps the explicit block`() {
        val result = PinPlacement.resolve(
            paddocks = listOf(fixtureBlock()),
            selectedPaddockId = "block-1",
            latitude = null,
            longitude = null,
            side = "right",
        )
        assertEquals(PinSnapState.NO_LOCATION, result.snapState)
        assertFalse(result.snappedToRow)
        assertEquals("block-1", result.paddockId)
        assertNull(result.pinRowNumber)
        assertNull(result.alongRowDistanceM)
        assertNull(result.toAttachment())
    }

    @Test
    fun `an explicitly selected block always wins over containment`() {
        val bare = bareBlock()
        val mapped = fixtureBlock()
        val result = PinPlacement.resolve(
            paddocks = listOf(mapped, bare),
            selectedPaddockId = bare.id,
            latitude = -33.9995,
            longitude = rowLongitude(2),
            side = "left",
        )
        // The fix is inside the mapped block too, but the user's explicit
        // selection is authoritative.
        assertEquals(bare.id, result.paddockId)
        assertEquals(PinSnapState.NO_ROW_GEOMETRY, result.snapState)
    }

    @Test
    fun `side is normalised and carried verbatim only when snapped`() {
        val block = fixtureBlock()
        val snapped = PinPlacement.resolve(
            paddocks = listOf(block),
            selectedPaddockId = null,
            latitude = -33.9995,
            longitude = rowLongitude(1),
            side = "  Right ",
        )
        assertEquals("right", snapped.pinSide)

        val blank = PinPlacement.resolve(
            paddocks = listOf(block),
            selectedPaddockId = null,
            latitude = -33.9995,
            longitude = rowLongitude(1),
            side = "   ",
        )
        assertEquals(PinSnapState.SNAPPED, blank.snapState)
        assertNull(blank.pinSide)
    }
}
