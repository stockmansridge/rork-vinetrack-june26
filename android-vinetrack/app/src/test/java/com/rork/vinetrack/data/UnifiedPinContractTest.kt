package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CustomPinType
import com.rork.vinetrack.data.model.ManualIssueSegment
import com.rork.vinetrack.data.model.UnifiedPinContract
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unified "Add Pin / Action" composer contract — mirrored by iOS
 * `UnifiedPinComposerContractTests.swift`. Tab ordering, the location
 * validation matrix and the custom-name duplicate rule MUST stay identical
 * across iOS, Android and the portal contract.
 */
class UnifiedPinContractTest {

    private fun type(name: String, active: Boolean = true) = CustomPinType(
        id = "11111111-1111-1111-1111-111111111111",
        vineyardId = "22222222-2222-2222-2222-222222222222",
        name = name,
        isActive = active,
    )

    @Test
    fun `tabs are Repair Growth Custom in that exact order`() {
        assertEquals(listOf("Repair", "Growth", "Custom"), UnifiedPinContract.TABS)
    }

    @Test
    fun `point placement never requires a block`() {
        val error = UnifiedPinContract.validationError(
            scope = UnifiedPinContract.SCOPE_POINT,
            hasSelectedType = true,
            latitude = -34.0,
            longitude = 138.0,
            paddockId = null,
            segments = emptyList(),
        )
        assertNull(error)
    }

    @Test
    fun `row selection requires at least one segment and a derivable block`() {
        // Rows are selected FIRST; a missing block is a derivation failure,
        // reported with a safe message — never a prompt to open a dropdown.
        val noBlock = UnifiedPinContract.validationError(
            scope = UnifiedPinContract.SCOPE_ROW,
            hasSelectedType = true,
            latitude = -34.0,
            longitude = 138.0,
            paddockId = null,
            segments = listOf(ManualIssueSegment(3, 1)),
        )
        assertEquals(UnifiedPinContract.ERROR_ROW_BLOCK, noBlock)
        assertEquals("Couldn't match the selected row to a block.", noBlock)

        val noSegments = UnifiedPinContract.validationError(
            scope = UnifiedPinContract.SCOPE_ROW,
            hasSelectedType = true,
            latitude = -34.0,
            longitude = 138.0,
            paddockId = "block-1",
            segments = emptyList(),
        )
        assertEquals(UnifiedPinContract.ERROR_SELECT_ROW, noSegments)

        val valid = UnifiedPinContract.validationError(
            scope = UnifiedPinContract.SCOPE_ROW,
            hasSelectedType = true,
            latitude = -34.0,
            longitude = 138.0,
            paddockId = "block-1",
            segments = listOf(ManualIssueSegment(3, 1)),
        )
        assertNull(valid)
    }

    @Test
    fun `block selection requires a block`() {
        val missing = UnifiedPinContract.validationError(
            scope = UnifiedPinContract.SCOPE_BLOCK,
            hasSelectedType = true,
            latitude = -34.0,
            longitude = 138.0,
            paddockId = null,
            segments = emptyList(),
        )
        assertEquals("Select a block.", missing)

        val valid = UnifiedPinContract.validationError(
            scope = UnifiedPinContract.SCOPE_BLOCK,
            hasSelectedType = true,
            latitude = -34.0,
            longitude = 138.0,
            paddockId = "block-1",
            segments = emptyList(),
        )
        assertNull(valid)
    }

    @Test
    fun `every scope requires a selected type and a marker coordinate`() {
        assertEquals(
            "Select a pin type.",
            UnifiedPinContract.validationError(
                scope = UnifiedPinContract.SCOPE_POINT,
                hasSelectedType = false,
                latitude = -34.0,
                longitude = 138.0,
                paddockId = null,
                segments = emptyList(),
            ),
        )
        assertEquals(
            "A map location is required.",
            UnifiedPinContract.validationError(
                scope = UnifiedPinContract.SCOPE_POINT,
                hasSelectedType = true,
                latitude = null,
                longitude = null,
                paddockId = null,
                segments = emptyList(),
            ),
        )
    }

    @Test
    fun `quick action label is exactly Manual Pin Repair Observation`() {
        assertEquals("Manual Pin / Repair / Observation", UnifiedPinContract.QUICK_ACTION_TITLE)
        assertEquals("Drop a pin, select a row or select a block", UnifiedPinContract.QUICK_ACTION_SUBTITLE)
    }

    @Test
    fun `quick action uses the shared burgundy semantic colour`() {
        assertEquals("#800020", UnifiedPinContract.QUICK_ACTION_COLOR_HEX)
        assertEquals("#5C0017", UnifiedPinContract.QUICK_ACTION_COLOR_DARK_HEX)
    }

    @Test
    fun `location controls use the enlarged layout in canonical order`() {
        assertEquals(128, UnifiedPinContract.METHOD_BUTTON_MIN_HEIGHT)
        assertEquals(
            listOf("Drop a pin manually", "Select a row", "Select a block"),
            UnifiedPinContract.METHOD_TITLES,
        )
        assertEquals(3, UnifiedPinContract.METHOD_SUBTITLES.size)
        // Row selection is row-first: the subtitle never asks for a block.
        assertEquals(
            "Tap rows or row sections — the block is detected automatically",
            UnifiedPinContract.METHOD_SUBTITLES[1],
        )
    }

    @Test
    fun `growth tab includes Growth Stage exactly once and first`() {
        val items = UnifiedPinContract.growthTabItems(
            listOf("Powdery", "Downy", "Blackberries", "Powdery", "growth stage"),
        )
        assertEquals(listOf("Growth Stage", "Powdery", "Downy", "Blackberries"), items)
    }

    @Test
    fun `growth stage pin stores the existing stage identifier and colour`() {
        assertEquals("Growth Stage 12", UnifiedPinContract.growthStagePinTitle("12"))
        assertEquals("darkgreen", UnifiedPinContract.GROWTH_STAGE_PIN_COLOR)
    }

    @Test
    fun `repair and growth catalogues stay deduplicated by name and colour`() {
        val entries = listOf(
            "Irrigation" to "blue",
            "Broken Post" to "brown",
            "Irrigation" to "blue", // left/right launcher duplicate
            "Broken Post" to "brown",
        )
        val deduped = entries.distinctBy { UnifiedPinContract.catalogueKey(it.first, it.second) }
        assertEquals(listOf("Irrigation" to "blue", "Broken Post" to "brown"), deduped)
    }

    @Test
    fun `tapping a row derives its block automatically`() {
        val tapped = setOf(ManualIssueSegment(41, 1))
        val (block, segments) = UnifiedPinContract.applyRowTap(
            currentBlockId = null,
            tappedBlockId = "block-a",
            currentSegments = emptySet(),
            tappedSegments = tapped,
        )
        assertEquals("block-a", block)
        assertEquals(tapped, segments)
    }

    @Test
    fun `tapping a row in another block switches block and starts fresh`() {
        // "Row 41" exists in two blocks — the tapped block's geometry wins and
        // the previous block's selection is discarded (a pin has one block).
        val (block, segments) = UnifiedPinContract.applyRowTap(
            currentBlockId = "block-a",
            tappedBlockId = "block-b",
            currentSegments = setOf(ManualIssueSegment(41, 1), ManualIssueSegment(41, 2)),
            tappedSegments = setOf(ManualIssueSegment(41, 3)),
        )
        assertEquals("block-b", block)
        assertEquals(setOf(ManualIssueSegment(41, 3)), segments)
    }

    @Test
    fun `tapping within the current block toggles segments`() {
        val current = setOf(ManualIssueSegment(3, 1), ManualIssueSegment(3, 2))
        // Add a new quarter.
        val added = UnifiedPinContract.applyRowTap("block-a", "block-a", current, setOf(ManualIssueSegment(3, 3)))
        assertEquals(current + ManualIssueSegment(3, 3), added.second)
        // Re-tapping a selected quarter removes it.
        val removed = UnifiedPinContract.applyRowTap("block-a", "block-a", current, setOf(ManualIssueSegment(3, 1)))
        assertEquals(setOf(ManualIssueSegment(3, 2)), removed.second)
        // Whole-row tap on a fully selected row clears the row.
        val cleared = UnifiedPinContract.applyRowTap("block-a", "block-a", current + ManualIssueSegment(3, 3) + ManualIssueSegment(3, 4), (1..4).map { ManualIssueSegment(3, it) }.toSet())
        assertEquals(emptySet<ManualIssueSegment>(), cleared.second)
    }

    @Test
    fun `custom names are trimmed and blank names rejected`() {
        assertEquals("Broken Wire", UnifiedPinContract.normalizeCustomTypeName("  Broken Wire  "))
        assertNull(UnifiedPinContract.normalizeCustomTypeName("   "))
        assertNull(UnifiedPinContract.normalizeCustomTypeName(""))
    }

    @Test
    fun `duplicate detection is trimmed case-insensitive and ignores inactive items`() {
        val existing = listOf(type("Broken Wire"), type("Large Divot", active = false))
        assertTrue(UnifiedPinContract.isDuplicateCustomTypeName("broken wire", existing))
        assertTrue(UnifiedPinContract.isDuplicateCustomTypeName("  BROKEN WIRE ", existing))
        // Inactive items are hidden from selection, so re-adding the name is allowed.
        assertFalse(UnifiedPinContract.isDuplicateCustomTypeName("Large Divot", existing))
        assertFalse(UnifiedPinContract.isDuplicateCustomTypeName("Check Irrigation", existing))
    }
}
