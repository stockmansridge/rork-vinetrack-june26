package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.PinRowSegmentValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PinQueryPolicyTest {
    private fun pin(
        id: String,
        name: String = id,
        mode: String? = "Repairs",
        stage: String? = null,
        completed: Boolean = false,
        row: Double? = null,
        segments: List<PinRowSegmentValue>? = null,
        vineyardId: String = "vineyard",
        blockId: String? = "block-current",
    ): Pin = Pin(
        id = id,
        vineyardId = vineyardId,
        buttonName = name,
        mode = mode,
        growthStageCode = stage,
        paddockId = blockId,
        isCompleted = completed,
        pinRowNumber = row,
        rowSegments = segments,
    )

    @Test fun `default filter excludes EL and completed pins`() {
        val filter = PinQueryFilter()
        assertTrue(PinQueryPolicy.matches(pin("open"), filter))
        assertFalse(PinQueryPolicy.matches(pin("el", mode = "Growth", stage = "EL12"), filter))
        assertFalse(PinQueryPolicy.matches(pin("done", completed = true), filter))
    }

    @Test fun `category taps select exactly the intended category`() {
        assertEquals(PinCategoryFilter.entries.toSet(), PinQueryPolicy.categoriesFor(null))
        assertEquals(setOf(PinCategoryFilter.REPAIRS), PinQueryPolicy.categoriesFor(PinCategoryFilter.REPAIRS))
        assertEquals(setOf(PinCategoryFilter.GROWTH), PinQueryPolicy.categoriesFor(PinCategoryFilter.GROWTH))
        assertEquals(setOf(PinCategoryFilter.MANUAL_ISSUES), PinQueryPolicy.categoriesFor(PinCategoryFilter.MANUAL_ISSUES))
        val repairs = PinQueryFilter(categories = PinQueryPolicy.categoriesFor(PinCategoryFilter.REPAIRS))
        assertTrue(PinQueryPolicy.matches(pin("repair"), repairs))
        assertFalse(PinQueryPolicy.matches(pin("growth", mode = "Growth"), repairs))
    }

    @Test fun `selected EL stages match exact recognized identity`() {
        val filter = PinQueryFilter(
            categories = PinQueryPolicy.categoriesFor(PinCategoryFilter.GROWTH),
            includesElStages = true,
            selectedElStageCodes = setOf("EL12"),
        )
        assertTrue(PinQueryPolicy.matches(pin("12", mode = "Growth", stage = "EL12"), filter, isElRecord = true))
        assertFalse(PinQueryPolicy.matches(pin("13", mode = "Growth", stage = "EL13"), filter, isElRecord = true))
        assertFalse(PinQueryPolicy.matches(pin("unknown", mode = "Growth", stage = "unknown"), filter, isElRecord = true))
    }

    @Test fun `unknown EL identity never becomes ordinary growth`() {
        val unknown = pin("unknown", mode = "Growth", stage = "unknown")
        assertFalse(PinQueryPolicy.matches(unknown, PinQueryFilter(categories = setOf(PinCategoryFilter.GROWTH)), isElRecord = true))
        assertTrue(PinQueryPolicy.matches(unknown, PinQueryFilter(categories = setOf(PinCategoryFilter.GROWTH), includesElStages = true), isElRecord = true))
        assertFalse(PinQueryPolicy.matches(unknown, PinQueryFilter(categories = setOf(PinCategoryFilter.GROWTH), includesElStages = true, selectedElStageCodes = setOf("EL12")), isElRecord = true))
    }

    @Test fun `authoritative EL names stay out of issue growth options and stale selections are cleaned`() {
        val pins = listOf(
            pin("repair", name = "Broken post"),
            pin("growth", name = "Canopy check", mode = "Growth"),
            pin("el-id", name = "E-L 12", mode = "Growth"),
        )
        val names = PinQueryPolicy.ordinaryFilterNames(pins, setOf("el-id"))
        assertEquals(listOf("Broken post", "Canopy check"), names)
        assertEquals(setOf("Broken post"), PinQueryPolicy.cleanedNameSelection(setOf("Broken post", "E-L 12"), names))
    }

    @Test fun `heading qualification remains independent from row availability`() {
        assertEquals(45.0, PinQueryPolicy.qualifiedHeading(45.0, true)!!, 0.0)
        assertNull(PinQueryPolicy.qualifiedHeading(45.0, false))
        assertNull(PinQueryPolicy.qualifiedHeading(Double.NaN, true))
        val estimated = PinQueryPolicy.TravelContext("vineyard", "block", 13.5, 45.0, isEstimated = true)
        assertTrue(estimated.isEstimated)
        assertEquals(45.0, estimated.heading!!, 0.0)
    }

    @Test fun `usable row uses attached or segments but never legacy row`() {
        assertEquals(8.0, PinQueryPolicy.usableRow(pin("attached", row = 8.0))!!, 0.0)
        assertEquals(4.0, PinQueryPolicy.usableRow(pin("segment", segments = listOf(PinRowSegmentValue(4, 2))))!!, 0.0)
        assertNull(PinQueryPolicy.usableRow(Pin(id = "legacy", vineyardId = "vineyard", rowNumber = 22)))
    }

    @Test fun `travel context requires fresh matching vineyard and separately qualified heading`() {
        fun context(vineyardId: String = "vineyard", observedAtMs: Long = 95_000L, headingQualified: Boolean = true) =
            PinQueryPolicy.qualifiedTravelContext(
                selectedVineyardId = "vineyard",
                contextVineyardId = vineyardId,
                blockId = "block-current",
                row = 12.5,
                isRowQualified = true,
                observedAtMs = observedAtMs,
                heading = 90.0,
                isHeadingQualified = headingQualified,
                nowMs = 100_000L,
            )
        assertNull(context(vineyardId = "wrong"))
        assertNull(context(observedAtMs = 80_000L))
        assertNull(context(headingQualified = false)?.heading)
        assertEquals(90.0, context()?.heading ?: 0.0, 0.0)
    }

    @Test fun `nearest row sort uses distance within current block`() {
        val ordered = PinQueryPolicy.nearestRowOrdered(
            pins = listOf(pin("14", row = 14.0), pin("11", row = 11.0), pin("13", row = 13.0)),
            currentRow = 12.5,
            currentVineyardId = "vineyard",
            currentBlockId = "block-current",
            blockNames = mapOf("block-current" to "B"),
        )
        assertEquals(listOf("13", "14", "11"), ordered.map { it.id })
    }

    @Test fun `nearest row never compares rows across blocks`() {
        val ordered = PinQueryPolicy.nearestRowOrdered(
            pins = listOf(
                pin("other-near", row = 12.0, blockId = "block-a"),
                pin("current-far", row = 30.0, blockId = "block-current"),
                pin("other-low", row = 2.0, blockId = "block-a"),
            ),
            currentRow = 12.5,
            currentVineyardId = "vineyard",
            currentBlockId = "block-current",
            blockNames = mapOf("block-current" to "B", "block-a" to "A"),
        )
        assertEquals(listOf("current-far", "other-low", "other-near"), ordered.map { it.id })
    }
}
