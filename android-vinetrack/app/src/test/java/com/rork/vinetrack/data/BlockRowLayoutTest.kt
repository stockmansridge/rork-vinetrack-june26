package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sqrt

/**
 * Contract for the canonical block row layout shared by the full-screen editor
 * and the read-only block preview, plus the editor's numeric-entry parsing and
 * panel/sheet sizing rules.
 */
class BlockRowLayoutTest {

    /** ~186 m x 222 m rectangle near Orange, NSW. */
    private val block = listOf(
        CoordinatePoint(-33.2800, 149.0000),
        CoordinatePoint(-33.2800, 149.0020),
        CoordinatePoint(-33.2820, 149.0020),
        CoordinatePoint(-33.2820, 149.0000),
    )

    private fun layout(
        direction: Double = 0.0,
        count: Int = 40,
        width: Double = 2.8,
        offset: Double = 0.0,
        start: Int = 69,
        ascending: Boolean = true,
        polygon: List<CoordinatePoint> = block,
    ) = blockRowLayout(polygon, direction, count, width, offset, RowNumbering(start, ascending))

    private fun geometry(l: BlockRowLayout): List<Pair<CoordinatePoint, CoordinatePoint>> =
        l.rows.map { it.line.start to it.line.end }

    // MARK: - Direction normalisation (0 <= d < 180)

    @Test
    fun `direction normalises into the canonical half turn`() {
        assertEquals(0.0, normaliseRowDirection(180.0), 1e-9)
        assertEquals(24.8, normaliseRowDirection(204.8), 1e-9)
        assertEquals(170.0, normaliseRowDirection(-10.0), 1e-9)
        assertEquals(0.0, normaliseRowDirection(360.0), 1e-9)
        assertEquals(24.8, normaliseRowDirection(24.8), 1e-9)
        assertEquals(179.9, normaliseRowDirection(359.9), 1e-9)
    }

    @Test
    fun `direction never returns exactly 180 or a negative value`() {
        var d = -720.0
        while (d <= 720.0) {
            val n = normaliseRowDirection(d)
            assertTrue("normalised $d -> $n", n >= 0.0 && n < 180.0)
            d += 0.7
        }
        assertEquals(0.0, normaliseRowDirection(Double.NaN), 1e-9)
    }

    @Test
    fun `arrow steps wrap inside the half turn`() {
        assertEquals(179.5, stepRowDirection(0.0, -0.5), 1e-9)
        assertEquals(0.0, stepRowDirection(179.5, 0.5), 1e-9)
        assertEquals(25.3, stepRowDirection(24.8, 0.5), 1e-9)
    }

    @Test
    fun `a heading and that heading plus 180 lay out identical rows`() {
        val a = layout(direction = 24.8)
        val b = layout(direction = 204.8)
        assertEquals(24.8, b.direction, 1e-9)
        assertEquals(geometry(a), geometry(b))
    }

    @Test
    fun `an existing over-180 saved direction is normalised without moving the rows`() {
        val saved = layout(direction = 300.0)
        val canonical = layout(direction = normaliseRowDirection(300.0))
        assertEquals(120.0, saved.direction, 1e-9)
        assertEquals(geometry(canonical), geometry(saved))
    }

    // MARK: - Live regeneration from draft parameters

    @Test
    fun `every draft parameter change regenerates the geometry`() {
        val base = layout()
        assertNotEquals(geometry(base), geometry(layout(direction = 24.8)))
        assertNotEquals(geometry(base), geometry(layout(count = 41)))
        assertNotEquals(geometry(base), geometry(layout(width = 3.2)))
        assertNotEquals(geometry(base), geometry(layout(offset = 6.0)))
        assertNotEquals(geometry(base), geometry(layout(offset = -6.0)))
    }

    @Test
    fun `a slider drag produces a distinct layout at every step`() {
        val seen = mutableSetOf<List<Pair<CoordinatePoint, CoordinatePoint>>>()
        var direction = 20.0
        while (direction <= 30.0) {
            seen.add(geometry(layout(direction = direction)))
            direction += 1.0
        }
        assertEquals(11, seen.size)
    }

    @Test
    fun `positive and negative shift move the row set opposite ways`() {
        val centre = layout().rows.first().line.start
        val plus = layout(offset = 10.0).rows.first().line.start
        val minus = layout(offset = -10.0).rows.first().line.start
        assertTrue(abs(plus.longitude - centre.longitude) > 1e-6)
        assertEquals(
            centre.longitude - plus.longitude,
            minus.longitude - centre.longitude,
            1e-9,
        )
    }

    @Test
    fun `row width is metres, not degrees`() {
        val rows = layout(width = 2.8, count = 3).rows
        val mPerDegLon = 111_320.0 * cos(-33.281 * Math.PI / 180.0)
        val gap = abs(rows[1].line.start.longitude - rows[0].line.start.longitude) * mPerDegLon
        assertEquals(2.8, gap, 0.05)
    }

    // MARK: - Clipping

    @Test
    fun `rows stay clipped inside the boundary`() {
        val minLat = block.minOf { it.latitude } - 1e-9
        val maxLat = block.maxOf { it.latitude } + 1e-9
        val minLon = block.minOf { it.longitude } - 1e-9
        val maxLon = block.maxOf { it.longitude } + 1e-9
        val rows = layout(direction = 24.8).rows
        assertTrue(rows.isNotEmpty())
        rows.forEach { row ->
            listOf(row.line.start, row.line.end).forEach { p ->
                assertTrue("lat ${p.latitude}", p.latitude in minLat..maxLat)
                assertTrue("lon ${p.longitude}", p.longitude in minLon..maxLon)
            }
        }
    }

    @Test
    fun `rows falling outside the block are dropped but numbering keeps its slot`() {
        // 500 rows at 2.8 m spans 1.4 km — far wider than the block.
        val wide = layout(count = 500)
        assertTrue(wide.rows.size < 500)
        assertEquals(500, wide.requestedCount)
        // Indices remain the geometric slot, so labels stay aligned with reality.
        assertTrue(wide.rows.first().index > 0)
        assertEquals(69 + wide.rows.first().index, wide.rows.first().number)
    }

    @Test
    fun `no boundary or no rows yields an empty layout instead of stale geometry`() {
        assertTrue(layout(polygon = block.take(2)).isEmpty)
        assertTrue(layout(count = 0).isEmpty)
        assertTrue(layout(width = 0.0).isEmpty)
        assertEquals(0.0, layout(polygon = emptyList()).totalLengthMetres, 1e-9)
    }

    // MARK: - Numbering

    @Test
    fun `start number 69 across 40 rows ends at 108`() {
        val l = layout(count = 40, start = 69, ascending = true)
        assertEquals(69, l.numbering.firstNumber(40))
        assertEquals(108, l.numbering.lastNumber(40))
        assertEquals(69, l.rows.first().number)
        assertEquals(108, l.rows.last().number)
    }

    @Test
    fun `swapping the numbering side reverses labels only`() {
        val before = layout(ascending = true)
        val after = layout(ascending = false)
        // Geometry is byte-identical — no rotation, no shift, no regeneration.
        assertEquals(geometry(before), geometry(after))
        assertEquals(69, before.rows.first().number)
        assertEquals(108, before.rows.last().number)
        assertEquals(108, after.rows.first().number)
        assertEquals(69, after.rows.last().number)
    }

    @Test
    fun `changing the start number relabels live without moving rows`() {
        val a = layout(start = 69)
        val b = layout(start = 1)
        assertEquals(geometry(a), geometry(b))
        assertEquals(1, b.rows.first().number)
        assertEquals(40, b.rows.last().number)
    }

    @Test
    fun `saved rows restore the numbering they were created with`() {
        val ascending = RowNumbering.fromSavedRows(listOf(69, 70, 71, 72))
        assertEquals(69, ascending.startNumber)
        assertTrue(ascending.ascending)

        val descending = RowNumbering.fromSavedRows(listOf(108, 107, 106, 69))
        assertEquals(69, descending.startNumber)
        assertTrue(!descending.ascending)

        assertEquals(RowNumbering.DEFAULT, RowNumbering.fromSavedRows(emptyList()))
    }

    // MARK: - Save / reopen / offline reopen

    @Test
    fun `identical saved parameters reproduce an identical layout`() {
        val saved = layout(direction = 24.8, count = 40, width = 2.8, offset = 1.5, start = 69, ascending = false)
        val reopened = layout(direction = 24.8, count = 40, width = 2.8, offset = 1.5, start = 69, ascending = false)
        assertEquals(geometry(saved), geometry(reopened))
        assertEquals(saved.rows.map { it.number }, reopened.rows.map { it.number })
        assertEquals(saved.totalLengthMetres, reopened.totalLengthMetres, 1e-9)
    }

    @Test
    fun `the preview and the editor cannot disagree`() {
        // Both surfaces call the same function with the same draft state.
        val editor = layout(direction = 24.8, offset = 3.0)
        val preview = blockRowLayout(block, 24.8, 40, 2.8, 3.0, RowNumbering(69, true))
        assertEquals(geometry(editor), geometry(preview))
        assertEquals(editor.firstRow?.number, preview.firstRow?.number)
        assertEquals(editor.lastRow?.number, preview.lastRow?.number)
    }

    @Test
    fun `total row length is plausible for the block`() {
        val metres = layout(direction = 0.0, count = 10).totalLengthMetres
        // 10 rows across a ~222 m tall block.
        assertEquals(2220.0, metres, 60.0)
        assertTrue(metres > 0)
    }

    @Test
    fun `frame points cover every row endpoint`() {
        val l = layout(count = 5)
        assertEquals(l.rows.size * 2, l.framePoints.size)
    }

    // MARK: - Direct numeric entry

    @Test
    fun `partial text keeps the last valid value`() {
        assertNull(RowInput.parseDecimal(""))
        assertNull(RowInput.parseDecimal("-"))
        assertNull(RowInput.parseDecimal("24."))
        assertNull(RowInput.parseDecimal("."))
        assertNull(RowInput.parseInt(""))
        assertNull(RowInput.parseInt("-"))
        assertNull(RowInput.parseInt("abc"))
    }

    @Test
    fun `decimal entry accepts the device locale separator`() {
        assertEquals(24.8, RowInput.parseDecimal("24,8")!!, 1e-9)
        assertEquals(24.8, RowInput.parseDecimal("24.8")!!, 1e-9)
        assertEquals(24.8, RowInput.parseDecimal(" +24.8 ")!!, 1e-9)
        assertEquals(-3.5, RowInput.parseDecimal("-3,5")!!, 1e-9)
    }

    @Test
    fun `typed direction is normalised into 0 to 180`() {
        assertEquals(24.8, RowInput.direction("204.8")!!, 1e-9)
        assertEquals(0.0, RowInput.direction("180")!!, 1e-9)
        assertEquals(170.0, RowInput.direction("-10")!!, 1e-9)
    }

    @Test
    fun `typed values are clamped to their valid range`() {
        assertEquals(RowLimits.COUNT_MAX, RowInput.count("99999"))
        assertEquals(0, RowInput.count("-5"))
        assertEquals(RowLimits.WIDTH_MIN, RowInput.width("0")!!, 1e-9)
        assertEquals(RowLimits.WIDTH_MAX, RowInput.width("99")!!, 1e-9)
        assertEquals(RowLimits.SHIFT_MIN, RowInput.shift("-9999")!!, 1e-9)
        assertEquals(RowLimits.SHIFT_MAX, RowInput.shift("9999")!!, 1e-9)
        assertEquals(1, RowInput.startNumber("0"))
        assertEquals(RowLimits.START_NUMBER_MAX, RowInput.startNumber("100000"))
    }

    @Test
    fun `decimal fields show at least one decimal place regardless of locale`() {
        val previous = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.GERMANY)
            assertEquals("24.8", RowInput.formatDecimal(24.8))
            assertEquals("0.0", RowInput.formatDecimal(0.0))
            assertEquals("-3.5", RowInput.formatDecimal(-3.5))
        } finally {
            java.util.Locale.setDefault(previous)
        }
    }

    @Test
    fun `slider positions round to the displayed precision`() {
        assertEquals(24.8, RowInput.roundToDecimals(24.7834), 1e-9)
        assertEquals(2.8, RowInput.roundToDecimals(2.8449), 1e-9)
    }

    // MARK: - Editor panel + sheet sizing

    @Test
    fun `the expanded row sheet never takes more than half the usable map`() {
        listOf(560, 640, 740, 900, 1180).forEach { usable ->
            val sheet = BlockEditorLayout.expandedSheetHeightDp(usable)
            assertTrue(
                "sheet $sheet dp of $usable dp",
                sheet <= (usable * BlockEditorLayout.ROW_SHEET_MAX_FRACTION).toInt() + 1 ||
                    sheet == BlockEditorLayout.ROW_SHEET_MIN_EXPANDED_DP,
            )
            assertTrue(BlockEditorLayout.visibleMapHeightDp(usable, sheet) > 0)
        }
    }

    @Test
    fun `small and large screens both keep a usable live map`() {
        val small = BlockEditorLayout.expandedSheetHeightDp(560)
        val large = BlockEditorLayout.expandedSheetHeightDp(1180)
        assertTrue(BlockEditorLayout.visibleMapHeightDp(560, small) >= 240)
        assertTrue(BlockEditorLayout.visibleMapHeightDp(1180, large) >= 590)
        assertEquals(BlockEditorLayout.ROW_SHEET_MAX_EXPANDED_DP, large)
        assertEquals(0, BlockEditorLayout.expandedSheetHeightDp(0))
    }

    @Test
    fun `the collapsed sheet is far shorter than the expanded one`() {
        assertTrue(
            BlockEditorLayout.ROW_SHEET_COLLAPSED_HEIGHT_DP <
                BlockEditorLayout.expandedSheetHeightDp(740),
        )
    }

    @Test
    fun `fit reserves the panel height plus its anchor gap`() {
        assertEquals(
            BlockEditorLayout.BOUNDARY_BAR_HEIGHT_DP + BlockEditorLayout.BOTTOM_ANCHOR_GAP_DP,
            BlockEditorLayout.fitBottomInsetDp(BlockEditorLayout.BOUNDARY_BAR_HEIGHT_DP),
        )
        assertEquals(BlockEditorLayout.BOTTOM_ANCHOR_GAP_DP, BlockEditorLayout.fitBottomInsetDp(0))
        assertEquals(BlockEditorLayout.BOTTOM_ANCHOR_GAP_DP, BlockEditorLayout.fitBottomInsetDp(-40))
        assertEquals(0, BlockEditorLayout.fitTopInsetDp(-10))
        assertEquals(120, BlockEditorLayout.fitTopInsetDp(120))
    }

    @Test
    fun `the boundary bar is anchored, not floated`() {
        // A gap measured in single-digit dp is what keeps the bar hugging the
        // app navigation instead of hovering a nav-bar height above it.
        assertTrue(BlockEditorLayout.BOTTOM_ANCHOR_GAP_DP in 0..12)
        assertTrue(BlockEditorLayout.BOUNDARY_BAR_HEIGHT_DP <= 120)
    }

    // MARK: - Geometry sanity for boundaries with many points

    @Test
    fun `a boundary with more than twenty points still lays out rows`() {
        val circle = (0 until 24).map { i ->
            val a = i * 2 * Math.PI / 24
            CoordinatePoint(
                latitude = -33.281 + 0.0009 * cos(a),
                longitude = 149.001 + 0.0011 * Math.sin(a),
            )
        }
        val l = blockRowLayout(circle, 24.8, 30, 2.8, 0.0, RowNumbering(1, true))
        assertTrue(l.rows.isNotEmpty())
        assertTrue(l.rows.all { row -> distanceMetres(row.line.start, row.line.end) > 1.0 })
    }

    private fun distanceMetres(a: CoordinatePoint, b: CoordinatePoint): Double {
        val mPerDegLat = 111_320.0
        val mPerDegLon = 111_320.0 * cos(a.latitude * Math.PI / 180.0)
        val dLat = (b.latitude - a.latitude) * mPerDegLat
        val dLon = (b.longitude - a.longitude) * mPerDegLon
        return sqrt(dLat * dLat + dLon * dLon)
    }
}
