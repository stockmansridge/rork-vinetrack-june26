package com.rork.vinetrack.data

import com.rork.vinetrack.data.insights.PairedGrowthCaptureJournal
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GrowthStageVarietyParityTest {
    private val vineyardId = "11111111-1111-1111-1111-111111111111"
    private val blockId = "22222222-2222-2222-2222-222222222222"
    private val pinotId = "33333333-3333-3333-3333-333333333333"
    private val operatorId = "44444444-4444-4444-4444-444444444444"

    @Test fun `highest percentage Pinot Noir is snapshotted and serialized into canonical insert`() {
        val block = Paddock(id = blockId, vineyardId = vineyardId, name = "North", varietyAllocations = listOf(
            PaddockVarietyAllocation(percent = 20.0, name = "Shiraz"),
            PaddockVarietyAllocation(varietyId = pinotId, percent = 80.0, name = "Pinot Noir"),
        ))
        val journal = PairedGrowthCaptureJournal(
            operationId = "operation-1", pinId = "pin-1", growthRecordId = "record-1",
            vineyardId = vineyardId, paddockId = block.id, stageCode = "EL23", stageLabel = "E-L 23",
            variety = block.primaryVarietyName, varietyId = block.primaryVarietyAllocation?.varietyId,
            observedAtIso = "2026-09-29T09:00:00Z", notes = "Keep this note",
            latitude = -33.3, longitude = 149.1, rowNumber = 12,
            originatingFeature = "growth_screen", createdAtMillis = 1, updatedAtMillis = 1,
        )
        val savedJournal = Json.decodeFromString<PairedGrowthCaptureJournal>(Json.encodeToString(journal))
        val input = GrowthStageRecordRepository.GrowthInput(
            paddockId = savedJournal.paddockId, pinId = savedJournal.pinId,
            stageCode = savedJournal.stageCode, stageLabel = savedJournal.stageLabel,
            variety = savedJournal.variety, varietyId = savedJournal.varietyId,
            observedAt = savedJournal.observedAtIso, rowNumber = savedJournal.rowNumber,
            latitude = savedJournal.latitude, longitude = savedJournal.longitude, notes = savedJournal.notes,
        )
        val body = GrowthStageRecordRepository.insertPayload(
            vineyardId, input, savedJournal.growthRecordId, savedJournal.observedAtIso,
            createdBy = operatorId, recordedByName = "Operator",
        )
        val json = Json.encodeToString(GrowthStageRecordRepository.GrowthInsert.serializer(), body)
        assertEquals("Pinot Noir", body.variety)
        assertEquals(pinotId, body.varietyId)
        assertEquals(vineyardId, body.vineyardId)
        assertEquals(blockId, body.paddockId)
        assertEquals("pin-1", body.pinId)
        assertEquals("EL23", body.stageCode)
        assertEquals("E-L 23", body.stageLabel)
        assertEquals("2026-09-29T09:00:00Z", body.observedAt)
        assertEquals(-33.3, body.latitude!!, 0.0)
        assertEquals(149.1, body.longitude!!, 0.0)
        assertEquals(12, body.rowNumber)
        assertEquals("Keep this note", body.notes)
        assertEquals("Operator", body.recordedByName)
        assertEquals(operatorId, body.createdBy)
        assertEquals(savedJournal.observedAtIso, body.clientUpdatedAt)
        assertTrue(json.contains("\"variety_id\":\"$pinotId\""))
        assertTrue(json.contains("\"created_by\":\"$operatorId\""))
        assertTrue(json.contains("\"pin_id\":\"pin-1\""))
        // Neither platform fabricates a side or photo when the user did not provide one.
        assertTrue(!json.contains("\"side\""))
        assertTrue(!json.contains("\"photo_paths\""))

        val replanted = block.copy(varietyAllocations = listOf(PaddockVarietyAllocation(name = "Chardonnay", percent = 100.0)))
        assertEquals("Chardonnay", replanted.primaryVarietyName)
        assertEquals("Pinot Noir", savedJournal.variety)
        assertEquals(pinotId, savedJournal.varietyId)
    }

    @Test fun `unallocated block has null variety and first tied allocation wins`() {
        val empty = Paddock(id = blockId, vineyardId = vineyardId, name = "Empty")
        assertNull(empty.primaryVarietyName)
        assertNull(empty.primaryVarietyAllocation)
        val tied = empty.copy(varietyAllocations = listOf(
            PaddockVarietyAllocation(name = "Pinot Noir", percent = 50.0),
            PaddockVarietyAllocation(name = "Shiraz", percent = 50.0),
        ))
        assertEquals("Pinot Noir", tied.primaryVarietyName)
        val input = GrowthStageRecordRepository.GrowthInput(
            paddockId = blockId, stageCode = "EL23", stageLabel = "E-L 23",
            variety = empty.primaryVarietyName, observedAt = "2026-09-29T09:00:00Z", rowNumber = null, notes = null,
        )
        val body = GrowthStageRecordRepository.insertPayload(vineyardId, input, "record-2", input.observedAt, operatorId, null)
        assertNull(body.variety)
        assertNull(body.varietyId)
    }
}
