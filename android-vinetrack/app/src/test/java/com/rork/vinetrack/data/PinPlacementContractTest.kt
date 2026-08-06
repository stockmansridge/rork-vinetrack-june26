package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.ManualIssueSegment
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.PinPlacement
import com.rork.vinetrack.data.model.PinPlacementContract
import com.rork.vinetrack.data.model.PinRowSegmentValue
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Canonical pin placement contract (sql/171) — mirrored by iOS
 * `PinPlacementContractTests.swift`. The resolution matrix, warning rules,
 * row summaries and display lines MUST stay identical across iOS, Android,
 * the SQL view and the portal contract. Fixture expectations here are the
 * shared cross-platform fixtures: any change must land on both platforms.
 */
class PinPlacementContractTest {

    private fun wholeRow(row: Int): List<ManualIssueSegment> =
        (1..4).map { ManualIssueSegment(row, it) }

    private fun resolve(
        storedScope: String? = null,
        hasBlock: Boolean = false,
        segments: List<ManualIssueSegment> = emptyList(),
        hasCoordinates: Boolean = false,
        snappedToRow: Boolean = false,
        hasRowValues: Boolean = false,
    ): PinPlacement = PinPlacementContract.resolve(
        storedScope = storedScope,
        hasBlock = hasBlock,
        segments = segments,
        hasCoordinates = hasCoordinates,
        snappedToRow = snappedToRow,
        hasRowValues = hasRowValues,
    )

    // ------------------------------------------------------------------
    // The canonical assignment matrix
    // ------------------------------------------------------------------

    @Test
    fun `block-scope pin with a block and no row anywhere is assigned`() {
        val p = resolve(storedScope = "block", hasBlock = true, hasCoordinates = true)
        assertTrue(p.isAssigned)
        assertEquals(PinPlacementContract.BASIS_BLOCK, p.basis)
        assertNull(p.warningCode)
    }

    @Test
    fun `row-scope pin with segments and no base row number is assigned`() {
        val p = resolve(
            storedScope = "row",
            hasBlock = true,
            segments = wholeRow(41) + wholeRow(42) + wholeRow(43),
            hasCoordinates = true,
            hasRowValues = false,
        )
        assertTrue(p.isAssigned)
        assertEquals(PinPlacementContract.BASIS_ROW_SEGMENTS, p.basis)
        assertNull(p.warningCode)
        assertTrue(p.hasRowSegments)
    }

    @Test
    fun `row summary is derived from segments not base row fields`() {
        val ranges = resolve(
            storedScope = "row", hasBlock = true, hasCoordinates = true,
            segments = wholeRow(41) + wholeRow(42) + wholeRow(43),
        )
        assertEquals("Rows 41–43", ranges.rowSummary)

        val partial = resolve(
            storedScope = "row", hasBlock = true, hasCoordinates = true,
            segments = listOf(ManualIssueSegment(41, 1), ManualIssueSegment(41, 2)),
        )
        assertEquals("Row 41 (sections 1–2)", partial.rowSummary)
    }

    @Test
    fun `point pin with coordinates and no block is assigned`() {
        val p = resolve(storedScope = "point", hasCoordinates = true)
        assertTrue(p.isAssigned)
        assertEquals(PinPlacementContract.BASIS_POINT_COORDINATES, p.basis)
        assertNull(p.warningCode)
    }

    @Test
    fun `snapped point with block and row is assigned as snapped_point`() {
        val p = resolve(
            storedScope = "point", hasBlock = true, hasCoordinates = true,
            snappedToRow = true, hasRowValues = true,
        )
        assertTrue(p.isAssigned)
        assertEquals(PinPlacementContract.BASIS_SNAPPED_POINT, p.basis)
        assertNull(p.warningCode)
    }

    @Test
    fun `legacy pin with block but no row is a valid block assignment`() {
        val p = resolve(storedScope = null, hasBlock = true, hasCoordinates = true)
        assertTrue(p.isAssigned)
        assertEquals(PinPlacementContract.BASIS_LEGACY_BLOCK, p.basis)
        assertEquals("block", p.locationScope)
        assertNull(p.warningCode)
    }

    @Test
    fun `legacy pin with coordinates but no block is a valid point assignment`() {
        val p = resolve(storedScope = null, hasCoordinates = true)
        assertTrue(p.isAssigned)
        assertEquals(PinPlacementContract.BASIS_POINT_COORDINATES, p.basis)
        assertEquals("point", p.locationScope)
        assertNull(p.warningCode)
    }

    @Test
    fun `legacy pin with block and row values resolves as snapped point`() {
        val p = resolve(
            storedScope = null, hasBlock = true, hasCoordinates = true,
            hasRowValues = true,
        )
        assertTrue(p.isAssigned)
        assertEquals(PinPlacementContract.BASIS_SNAPPED_POINT, p.basis)
        assertEquals("point", p.locationScope)
        assertNull(p.warningCode)
    }

    @Test
    fun `genuinely empty pin is unassigned with the amber warning`() {
        val p = resolve()
        assertFalse(p.isAssigned)
        assertEquals(PinPlacementContract.BASIS_UNASSIGNED, p.basis)
        assertEquals(PinPlacementContract.WARNING_UNASSIGNED, p.warningCode)
    }

    @Test
    fun `deleted segments do not count - stored row scope falls back safely`() {
        // Server excludes dead segments; the pin arrives with none. The block
        // stays a valid assignment, flagged as incomplete metadata — never
        // the amber unassigned warning.
        val p = resolve(storedScope = "row", hasBlock = true, hasCoordinates = true)
        assertTrue(p.isAssigned)
        assertEquals(PinPlacementContract.WARNING_METADATA_INCOMPLETE, p.warningCode)
        assertFalse(p.hasRowSegments)
    }

    @Test
    fun `warning appears only for genuinely unassigned records`() {
        val valid = listOf(
            resolve(storedScope = "block", hasBlock = true, hasCoordinates = true),
            resolve(storedScope = "row", hasBlock = true, hasCoordinates = true, segments = wholeRow(3)),
            resolve(storedScope = "point", hasCoordinates = true),
            resolve(hasBlock = true, hasCoordinates = true),
            resolve(hasCoordinates = true),
        )
        valid.forEach { assertNull("no warning for ${it.basis}", it.warningCode) }
    }

    // ------------------------------------------------------------------
    // Display lines
    // ------------------------------------------------------------------

    @Test
    fun `block name remains visible when row metadata is absent`() {
        val block = resolve(storedScope = "block", hasBlock = true, hasCoordinates = true)
        assertEquals(
            "Pinot Noir",
            PinPlacementContract.blockContextLine("Pinot Noir", block, attachedRowText = null),
        )
        val legacy = resolve(hasBlock = true, hasCoordinates = true)
        assertEquals(
            "Pinot Noir",
            PinPlacementContract.blockContextLine("Pinot Noir", legacy, attachedRowText = null),
        )
    }

    @Test
    fun `row-scope line combines the block with the segment summary`() {
        val p = resolve(
            storedScope = "row", hasBlock = true, hasCoordinates = true,
            segments = wholeRow(41) + wholeRow(42),
        )
        assertEquals(
            "Pinot Noir — Rows 41–42",
            PinPlacementContract.blockContextLine("Pinot Noir", p, attachedRowText = null),
        )
    }

    @Test
    fun `point pin without a block shows a valid point location, never unassigned`() {
        val p = resolve(storedScope = "point", hasCoordinates = true)
        assertEquals(
            PinPlacementContract.POINT_LOCATION_LABEL,
            PinPlacementContract.blockContextLine(null, p, attachedRowText = null),
        )
    }

    @Test
    fun `unassigned label appears only for the genuinely empty record`() {
        val p = resolve()
        assertEquals(
            PinPlacementContract.UNASSIGNED_LOCATION_LABEL,
            PinPlacementContract.blockContextLine(null, p, attachedRowText = null),
        )
    }

    @Test
    fun `no side is invented and exact path rows are preserved`() {
        // 19.5 stays 19.5, whole rows trim, legacy backfills ".5".
        assertEquals("19.5", PinPlacementContract.attachedRowText(null, 19.5, null))
        assertEquals("15", PinPlacementContract.attachedRowText(15.0, null, null))
        assertEquals("14.5", PinPlacementContract.attachedRowText(null, null, 14))
        assertNull(PinPlacementContract.attachedRowText(null, null, null))
        // The snapped line never includes a side — sides are rendered only by
        // the facing line, and only from a genuinely stored value.
        val snapped = resolve(
            storedScope = "point", hasBlock = true, hasCoordinates = true,
            snappedToRow = true, hasRowValues = true,
        )
        assertEquals(
            "Pinot Noir row 19.5",
            PinPlacementContract.blockContextLine("Pinot Noir", snapped, attachedRowText = "19.5"),
        )
    }

    // ------------------------------------------------------------------
    // Every surface resolves the same placement
    // ------------------------------------------------------------------

    @Test
    fun `list detail map and export resolve the identical placement for one pin`() {
        val pin = Pin(
            id = "33333333-3333-3333-3333-333333333333",
            vineyardId = "22222222-2222-2222-2222-222222222222",
            paddockId = "44444444-4444-4444-4444-444444444444",
            mode = "Repairs",
            buttonName = "Broken Wire",
            latitude = -34.5,
            longitude = 148.5,
            locationScope = "row",
            rowSegments = (1..4).map { PinRowSegmentValue(41, it) },
        )
        val a = PinPlacementContract.placementFor(pin)
        val b = PinPlacementContract.placementFor(pin)
        assertEquals(a, b)
        assertEquals(PinPlacementContract.BASIS_ROW_SEGMENTS, a.basis)
        assertEquals("Row 41", a.rowSummary)
    }

    @Test
    fun `repair growth and custom pins resolve through the same rules`() {
        listOf("Repairs", "Growth", "ManualIssue").forEach { mode ->
            val pin = Pin(
                id = "33333333-3333-3333-3333-333333333333",
                vineyardId = "22222222-2222-2222-2222-222222222222",
                paddockId = "44444444-4444-4444-4444-444444444444",
                mode = mode,
                latitude = -34.5,
                longitude = 148.5,
                locationScope = "block",
            )
            val p = PinPlacementContract.placementFor(pin)
            assertTrue("$mode block pin must be assigned", p.isAssigned)
            assertEquals(PinPlacementContract.BASIS_BLOCK, p.basis)
            assertNull(p.warningCode)
        }
    }

    // ------------------------------------------------------------------
    // Offline cache compatibility
    // ------------------------------------------------------------------

    @Test
    fun `cached row-scope pin without embedded segments keeps its block, and regains the summary after refresh`() {
        val json = Json { ignoreUnknownKeys = true }
        // A cache entry written BEFORE the placement contract: no
        // pin_row_segments key at all.
        val stale = json.decodeFromString<Pin>(
            """
            {"id":"33333333-3333-3333-3333-333333333333",
             "vineyard_id":"22222222-2222-2222-2222-222222222222",
             "paddock_id":"44444444-4444-4444-4444-444444444444",
             "mode":"Repairs","latitude":-34.5,"longitude":148.5,
             "location_scope":"row"}
            """.trimIndent(),
        )
        val before = PinPlacementContract.placementFor(stale)
        assertTrue(before.isAssigned)
        assertEquals(PinPlacementContract.WARNING_METADATA_INCOMPLETE, before.warningCode)
        assertEquals(
            "Pinot Noir",
            PinPlacementContract.blockContextLine("Pinot Noir", before, attachedRowText = null),
        )

        // After refresh the delta sync embeds the segments.
        val fresh = json.decodeFromString<Pin>(
            """
            {"id":"33333333-3333-3333-3333-333333333333",
             "vineyard_id":"22222222-2222-2222-2222-222222222222",
             "paddock_id":"44444444-4444-4444-4444-444444444444",
             "mode":"Repairs","latitude":-34.5,"longitude":148.5,
             "location_scope":"row",
             "pin_row_segments":[
               {"row_number":41,"segment_number":1},{"row_number":41,"segment_number":2},
               {"row_number":41,"segment_number":3},{"row_number":41,"segment_number":4}]}
            """.trimIndent(),
        )
        val after = PinPlacementContract.placementFor(fresh)
        assertEquals(PinPlacementContract.BASIS_ROW_SEGMENTS, after.basis)
        assertNull(after.warningCode)
        assertEquals(
            "Pinot Noir — Row 41",
            PinPlacementContract.blockContextLine("Pinot Noir", after, attachedRowText = null),
        )
    }

    @Test
    fun `shared cross-platform fixtures match the iOS expectations exactly`() {
        // These literals are asserted identically in
        // PinPlacementContractTests.swift — do not change one side only.
        assertEquals("point_coordinates", PinPlacementContract.BASIS_POINT_COORDINATES)
        assertEquals("snapped_point", PinPlacementContract.BASIS_SNAPPED_POINT)
        assertEquals("row_segments", PinPlacementContract.BASIS_ROW_SEGMENTS)
        assertEquals("block", PinPlacementContract.BASIS_BLOCK)
        assertEquals("legacy_block", PinPlacementContract.BASIS_LEGACY_BLOCK)
        assertEquals("unassigned", PinPlacementContract.BASIS_UNASSIGNED)
        assertEquals("unassigned_location", PinPlacementContract.WARNING_UNASSIGNED)
        assertEquals("location_metadata_incomplete", PinPlacementContract.WARNING_METADATA_INCOMPLETE)
        assertEquals("Unassigned location", PinPlacementContract.UNASSIGNED_LOCATION_LABEL)
        assertEquals("Point location", PinPlacementContract.POINT_LOCATION_LABEL)
    }
}
