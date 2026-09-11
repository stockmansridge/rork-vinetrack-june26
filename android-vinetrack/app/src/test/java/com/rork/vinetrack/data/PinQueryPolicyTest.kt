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
        mode: String? = "Repairs",
        stage: String? = null,
        completed: Boolean = false,
        row: Double? = null,
        segments: List<PinRowSegmentValue>? = null,
    ): Pin = Pin(
        id = id,
        vineyardId = "vineyard",
        mode = mode,
        growthStageCode = stage,
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

    @Test fun `selected EL stages match exact recognized identity`() {
        val filter = PinQueryFilter(includesElStages = true, selectedElStageCodes = setOf("EL12"))
        assertTrue(PinQueryPolicy.matches(pin("12", mode = "Growth", stage = "EL12"), filter))
        assertFalse(PinQueryPolicy.matches(pin("13", mode = "Growth", stage = "EL13"), filter))
        assertFalse(PinQueryPolicy.matches(pin("unknown", mode = "Growth", stage = "unknown"), filter))
    }

    @Test fun `usable row uses attached or segments but never legacy row`() {
        assertEquals(8.0, PinQueryPolicy.usableRow(pin("attached", row = 8.0))!!, 0.0)
        assertEquals(4.0, PinQueryPolicy.usableRow(pin("segment", segments = listOf(PinRowSegmentValue(4, 2))))!!, 0.0)
        assertNull(PinQueryPolicy.usableRow(Pin(id = "legacy", vineyardId = "vineyard", rowNumber = 22)))
    }

    @Test fun `travel context requires qualified row and separately qualified heading`() {
        assertNull(PinQueryPolicy.qualifiedTravelContext(12.5, false, 90.0, true))
        val rowOnly = PinQueryPolicy.qualifiedTravelContext(12.5, true, 90.0, false)
        assertEquals(12.5, rowOnly?.row ?: 0.0, 0.0)
        assertNull(rowOnly?.heading)
        assertEquals(90.0, PinQueryPolicy.qualifiedTravelContext(12.5, true, 90.0, true)?.heading ?: 0.0, 0.0)
    }

    @Test fun `nearest row sort is numeric stable and leaves unusable rows last`() {
        val ordered = PinQueryPolicy.nearestRowOrdered(
            listOf(pin("14", row = 14.0), pin("none"), pin("11", row = 11.0), pin("13", row = 13.0)),
            currentRow = 12.5,
        )
        assertEquals(listOf("11", "13", "14", "none"), ordered.map { it.id })
    }
}
