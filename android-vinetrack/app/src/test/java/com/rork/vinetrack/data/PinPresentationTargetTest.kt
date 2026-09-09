package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Pin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PinPresentationTargetTest {
    private val vineyardId = "11111111-1111-1111-1111-111111111111"

    @Test
    fun `standalone growth display routes to growth identity`() {
        val growth = GrowthStageRecord(id = "growth-1", vineyardId = vineyardId, stageCode = "EL4")
        val target = resolvePinPresentationTarget("growth-1", emptyList(), listOf(growth))

        assertEquals(PinPresentationTarget.Kind.STANDALONE_GROWTH, target?.kind)
        assertEquals("growth-1", target?.growthRecordId)
        assertNull(target?.pinId)
    }

    @Test
    fun `linked growth keeps both ids when pin is absent locally`() {
        val growth = GrowthStageRecord(
            id = "growth-2",
            vineyardId = vineyardId,
            pinId = "pin-2",
            stageCode = "EL12",
        )
        val target = resolvePinPresentationTarget("pin-2", emptyList(), listOf(growth))

        assertEquals(PinPresentationTarget.Kind.LINKED_GROWTH, target?.kind)
        assertEquals("pin-2", target?.pinId)
        assertEquals("growth-2", target?.growthRecordId)
    }

    @Test
    fun `real linked pin keeps both ids`() {
        val pin = Pin(id = "pin-3", vineyardId = vineyardId)
        val growth = GrowthStageRecord(
            id = "growth-3",
            vineyardId = vineyardId,
            pinId = "pin-3",
            stageCode = "EL23",
        )
        val target = resolvePinPresentationTarget("pin-3", listOf(pin), listOf(growth))

        assertEquals(PinPresentationTarget.Kind.LINKED_GROWTH, target?.kind)
        assertEquals("pin-3", target?.pinId)
        assertEquals("growth-3", target?.growthRecordId)
    }

    @Test
    fun `ordinary pin stays pin only`() {
        val target = resolvePinPresentationTarget(
            "pin-4",
            listOf(Pin(id = "pin-4", vineyardId = vineyardId)),
            emptyList(),
        )

        assertEquals(PinPresentationTarget.Kind.PIN, target?.kind)
        assertEquals("pin-4", target?.pinId)
        assertNull(target?.growthRecordId)
    }
}
