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
    fun `row selection requires a block and at least one segment`() {
        val noBlock = UnifiedPinContract.validationError(
            scope = UnifiedPinContract.SCOPE_ROW,
            hasSelectedType = true,
            latitude = -34.0,
            longitude = 138.0,
            paddockId = null,
            segments = listOf(ManualIssueSegment(3, 1)),
        )
        assertEquals("Select the block that owns the rows.", noBlock)

        val noSegments = UnifiedPinContract.validationError(
            scope = UnifiedPinContract.SCOPE_ROW,
            hasSelectedType = true,
            latitude = -34.0,
            longitude = 138.0,
            paddockId = "block-1",
            segments = emptyList(),
        )
        assertEquals("Select at least one row.", noSegments)

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
