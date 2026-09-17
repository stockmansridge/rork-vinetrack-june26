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
        deletedAt: String? = null,
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
        deletedAt = deletedAt,
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

    @Test fun `current EL selects the only stage in a block`() {
        val stage = pin("a18", mode = "Growth", stage = "EL18")
        val result = PinQueryPolicy.currentElSelection(listOf(stage), setOf(stage.id))
        assertEquals(listOf("a18"), result.pins.map { it.id })
        assertEquals(18, result.stageByBlockId["block-current"])
    }

    @Test fun `current EL selects only the highest numeric stage`() {
        val stages = listOf(15, 18, 21).map { pin("a$it", mode = "Growth", stage = "EL$it") }
        val result = PinQueryPolicy.currentElSelection(stages, stages.mapTo(HashSet()) { it.id })
        assertEquals(listOf("a21"), result.pins.map { it.id })
    }

    @Test fun `current EL preserves every pin tied at the maximum`() {
        val stages = listOf(
            pin("a15", mode = "Growth", stage = "EL15"),
            pin("a21-first", mode = "Growth", stage = "EL21"),
            pin("a21-second", mode = "Growth", stage = "EL21"),
        )
        val result = PinQueryPolicy.currentElSelection(stages, stages.mapTo(HashSet()) { it.id })
        assertEquals(listOf("a21-first", "a21-second"), result.pins.map { it.id })
    }

    @Test fun `current EL compares stage numbers numerically`() {
        val stages = listOf(
            pin("a9", mode = "Growth", stage = "EL9"),
            pin("a10", mode = "Growth", stage = "EL10"),
        )
        val result = PinQueryPolicy.currentElSelection(stages, stages.mapTo(HashSet()) { it.id })
        assertEquals(listOf("a10"), result.pins.map { it.id })
        assertEquals(10, result.stageByBlockId["block-current"])
    }

    @Test fun `current EL calculates blocks independently`() {
        val stages = listOf(
            pin("a18", mode = "Growth", stage = "EL18", blockId = "block-a"),
            pin("a21", mode = "Growth", stage = "EL21", blockId = "block-a"),
            pin("b25", mode = "Growth", stage = "EL25", blockId = "block-b"),
            pin("b27", mode = "Growth", stage = "EL27", blockId = "block-b"),
        )
        val result = PinQueryPolicy.currentElSelection(stages, stages.mapTo(HashSet()) { it.id })
        assertEquals(listOf("a21", "b27"), result.pins.map { it.id })
        assertEquals(mapOf("block-a" to 21, "block-b" to 27), result.stageByBlockId)
    }

    @Test fun `current EL ignores invalid unavailable and non growth records`() {
        val stages = listOf(
            pin("valid", mode = "Growth", stage = "EL18"),
            pin("malformed", mode = "Growth", stage = "ELbanana"),
            pin("missing", mode = "Growth", stage = null),
            pin("unlinked", mode = "Growth", stage = "EL21", blockId = null),
            pin("ordinary", mode = "Repairs", stage = "EL21"),
            pin("deleted", mode = "Growth", stage = "EL27", deletedAt = "2026-09-17T00:00:00Z"),
        )
        val result = PinQueryPolicy.currentElSelection(stages, stages.mapTo(HashSet()) { it.id })
        assertEquals(listOf("valid"), result.pins.map { it.id })
    }

    @Test fun `current EL returns nothing when a block has no EL stages`() {
        val ordinary = pin("ordinary-growth", mode = "Growth", stage = null)
        val result = PinQueryPolicy.currentElSelection(listOf(ordinary), emptySet())
        assertTrue(result.pins.isEmpty())
        assertTrue(result.stageByBlockId.isEmpty())
    }

    @Test fun `current EL map labels are unique and disappear when disabled`() {
        val stages = listOf(
            pin("a15", mode = "Growth", stage = "EL15"),
            pin("a21-first", mode = "Growth", stage = "EL21"),
            pin("a21-second", mode = "Growth", stage = "EL21"),
        )
        val result = PinQueryPolicy.currentElSelection(stages, stages.mapTo(HashSet()) { it.id })
        assertEquals(2, result.pins.size)
        assertEquals(mapOf("block-current" to "EL 21"), PinQueryPolicy.currentElBlockLabels(result, true))
        assertTrue(PinQueryPolicy.currentElBlockLabels(result, false).isEmpty())
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
