package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression suite for the Android block boundary editor.
 *
 * Covers the map-editor defects reported from the field: pin-style midpoints
 * that did nothing, insertion on the closing segment, undo of every edit kind,
 * camera restoration from another block, and the zoom clamp that stops the
 * imagery source being asked for tiles it cannot serve (the grey screen).
 */
class BoundaryEditorTest {

    private fun p(lat: Double, lng: Double) = CoordinatePoint(latitude = lat, longitude = lng)

    private val square = listOf(
        p(-34.0, 138.0),
        p(-34.0, 138.001),
        p(-34.001, 138.001),
        p(-34.001, 138.0),
    )

    // MARK: Midpoint controls

    @Test
    fun zeroOrOnePoint_hasNoMidpoints() {
        assertTrue(BoundaryEditor.midpoints(emptyList()).isEmpty())
        assertTrue(BoundaryEditor.midpoints(listOf(p(-34.0, 138.0))).isEmpty())
    }

    @Test
    fun twoPoints_haveOneOpenSegmentOnly() {
        val mids = BoundaryEditor.midpoints(square.take(2))
        assertEquals(1, mids.size)
        assertEquals(1, mids[0].insertIndex)
        assertEquals("Add boundary point between points 1 and 2", mids[0].accessibilityLabel)
        assertEquals(138.0005, mids[0].point.longitude, 1e-9)
    }

    @Test
    fun threePoints_haveAMidpointOnEverySegmentIncludingTheClosingOne() {
        val mids = BoundaryEditor.midpoints(square.take(3))
        assertEquals(3, mids.size)
        assertEquals(listOf(1, 2, 3), mids.map { it.insertIndex })
        assertEquals(
            listOf(
                "Add boundary point between points 1 and 2",
                "Add boundary point between points 2 and 3",
                "Add boundary point between points 3 and 1",
            ),
            mids.map { it.accessibilityLabel },
        )
    }

    @Test
    fun moreThanThreePoints_haveOneMidpointPerSegment() {
        assertEquals(4, BoundaryEditor.midpoints(square).size)
        assertEquals(6, BoundaryEditor.midpoints(square + listOf(p(-34.002, 138.0), p(-34.002, 138.001))).size)
    }

    @Test
    fun midpointSitsHalfwayAlongItsSegment() {
        val mids = BoundaryEditor.midpoints(square)
        val first = mids[0]
        assertEquals((square[0].latitude + square[1].latitude) / 2, first.point.latitude, 1e-12)
        assertEquals((square[0].longitude + square[1].longitude) / 2, first.point.longitude, 1e-12)
    }

    @Test
    fun midpointKeysAreSegmentStable_soDraggingAVertexDoesNotRecreateThem() {
        val before = BoundaryEditor.midpoints(square).map { it.key }
        val moved = square.toMutableList().apply { this[1] = p(-34.0005, 138.002) }
        assertEquals(before, BoundaryEditor.midpoints(moved).map { it.key })
    }

    // MARK: Insertion

    @Test
    fun insertingOnTheFirstSegment_renumbersTheFollowingPoints() {
        val mids = BoundaryEditor.midpoints(square.take(3))
        val after = BoundaryEditor.insert(square.take(3), mids[0])
        // 1 → new 2 → old 2 becomes 3 → old 3 becomes 4.
        assertEquals(4, after.size)
        assertEquals(square[0], after[0])
        assertEquals(mids[0].point, after[1])
        assertEquals(square[1], after[2])
        assertEquals(square[2], after[3])
    }

    @Test
    fun insertingOnTheClosingSegment_appendsToTheEnd() {
        val mids = BoundaryEditor.midpoints(square.take(3))
        val closing = mids.last()
        assertEquals(3, closing.insertIndex)
        val after = BoundaryEditor.insert(square.take(3), closing)
        assertEquals(4, after.size)
        assertEquals(closing.point, after[3])
        // Ring order is preserved: the original three points keep their order.
        assertEquals(square.take(3), after.take(3))
    }

    @Test
    fun everySegmentCanReceiveAPoint() {
        var points = square
        BoundaryEditor.midpoints(square).reversed().forEach { midpoint ->
            points = BoundaryEditor.insert(points, midpoint)
        }
        assertEquals(8, points.size)
    }

    @Test
    fun insertedPointParticipatesInLaterMidpointsAndOrdering() {
        val inserted = BoundaryEditor.insert(square, BoundaryEditor.midpoints(square)[0])
        assertEquals(5, inserted.size)
        assertEquals(5, BoundaryEditor.midpoints(inserted).size)
    }

    // MARK: Undo

    @Test
    fun undoRemovesTheLastAppendedPoint() {
        val added = square + p(-34.002, 138.002)
        val undone = BoundaryEditor.undo(added, BoundaryEdit.Added(added.lastIndex))
        assertEquals(square, undone)
    }

    @Test
    fun undoRemovesTheInsertedMidpointFromTheMiddle() {
        val midpoint = BoundaryEditor.midpoints(square)[1]
        val inserted = BoundaryEditor.insert(square, midpoint)
        val undone = BoundaryEditor.undo(inserted, BoundaryEdit.Inserted(midpoint.insertIndex))
        assertEquals(square, undone)
    }

    @Test
    fun undoRestoresADraggedPoint() {
        val dragged = square.toMutableList().apply { this[2] = p(-34.005, 138.005) }
        val undone = BoundaryEditor.undo(dragged, BoundaryEdit.Moved(2, square[2]))
        assertEquals(square, undone)
    }

    @Test
    fun undoRestoresAClearedBoundary() {
        val undone = BoundaryEditor.undo(emptyList(), BoundaryEdit.Cleared(square))
        assertEquals(square, undone)
    }

    @Test
    fun undoWithAStaleIndexIsIgnoredInsteadOfCrashing() {
        assertEquals(square, BoundaryEditor.undo(square, BoundaryEdit.Added(9)))
        assertEquals(square, BoundaryEditor.undo(square, BoundaryEdit.Moved(9, square[0])))
    }

    // MARK: Camera safety

    @Test
    fun zoomIsClampedToTheSupportedImageryRange() {
        assertEquals(BoundaryEditor.MAX_ZOOM, BoundaryEditor.clampZoom(24f))
        assertEquals(BoundaryEditor.MIN_ZOOM, BoundaryEditor.clampZoom(0f))
        assertEquals(18f, BoundaryEditor.clampZoom(18f))
    }

    @Test
    fun invalidCoordinatesAreRejectedBeforeFraming() {
        assertFalse(BoundaryEditor.isValidPoint(null))
        assertFalse(BoundaryEditor.isValidPoint(p(0.0, 0.0)))
        assertFalse(BoundaryEditor.isValidPoint(p(95.0, 138.0)))
        assertFalse(BoundaryEditor.isValidPoint(p(-34.0, 200.0)))
        assertFalse(BoundaryEditor.isValidPoint(p(Double.NaN, 138.0)))
        assertTrue(BoundaryEditor.isValidPoint(p(-34.0, 138.0)))
    }

    @Test
    fun cameraFromAnotherBlockIsNeverRestored() {
        assertFalse(BoundaryEditor.canRestoreCamera("v1:block-a", "v1:block-b", square[0], 18f))
        assertFalse(BoundaryEditor.canRestoreCamera(null, "v1:block-a", square[0], 18f))
        assertTrue(BoundaryEditor.canRestoreCamera("v1:block-a", "v1:block-a", square[0], 18f))
    }

    @Test
    fun cameraWithAnUnsupportedZoomOrCoordinateIsNeverRestored() {
        assertFalse(BoundaryEditor.canRestoreCamera("k", "k", square[0], 24f))
        assertFalse(BoundaryEditor.canRestoreCamera("k", "k", square[0], null))
        assertFalse(BoundaryEditor.canRestoreCamera("k", "k", p(0.0, 0.0), 18f))
    }
}
