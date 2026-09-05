package com.rork.vinetrack.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SprayTractorPersistenceTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun input() = SprayRecordRepository.SprayInput(
        date = "2026-09-05T00:00:00Z", startTime = "2026-09-05T00:00:00Z",
        temperature = null, windSpeed = null, windDirection = null, humidity = null,
        sprayReference = "Job", notes = null, numberOfFansJets = "6", averageSpeed = null,
        equipmentType = "Sprayer", tractor = "Real Tractor", tractorGear = null,
        machineId = null, tractorId = "tractor-id", sprayEquipmentId = "sprayer-id",
        operationType = "Foliar Spray", tripId = null, tanks = emptyList(),
    )

    @Test fun `tractor id reaches offline spray create and update with machine null`() {
        val create = SprayRecordCreateSync.Payload(
            id = "spray", vineyardId = "vineyard", date = input().date, startTime = input().startTime,
            tractor = input().tractor, machineId = input().machineId, tractorId = input().tractorId,
            sprayEquipmentId = input().sprayEquipmentId, clientUpdatedAt = input().date,
        )
        val createDecoded = json.decodeFromString(SprayRecordCreateSync.Payload.serializer(), json.encodeToString(SprayRecordCreateSync.Payload.serializer(), create))
        assertEquals("tractor-id", createDecoded.tractorId)
        assertNull(createDecoded.machineId)

        val updateStore = InMemoryPendingWriteStore()
        SprayRecordUpdateSync(PendingWriteRepository(updateStore)).enqueue("spray", input(), input().date)
        val updatePayload = PendingWriteRepository(updateStore).list().single().payloadJson
        val updateDecoded = json.decodeFromString(SprayRecordUpdateSync.Payload.serializer(), updatePayload)
        assertEquals("tractor-id", updateDecoded.tractorId)
        assertNull(updateDecoded.machineId)
    }

    @Test fun `immediate and placeholder trip payloads keep tractor separate from machine`() {
        val immediate = TripRepository.TripInsert(
            id = "trip", vineyardId = "vineyard", startTime = "2026-09-05T00:00:00Z",
            isActive = true, machineId = null, tractorId = "tractor-id", clientUpdatedAt = "2026-09-05T00:00:00Z",
        )
        val immediateDecoded = json.decodeFromString(TripRepository.TripInsert.serializer(), json.encodeToString(TripRepository.TripInsert.serializer(), immediate))
        assertEquals("tractor-id", immediateDecoded.tractorId)
        assertNull(immediateDecoded.machineId)

        val placeholder = TripRepository.ImportedTripInsert(
            id = "trip", vineyardId = "vineyard", startTime = "2026-09-05T00:00:00Z",
            machineId = null, tractorId = "tractor-id", clientUpdatedAt = "2026-09-05T00:00:00Z",
        )
        val placeholderDecoded = json.decodeFromString(TripRepository.ImportedTripInsert.serializer(), json.encodeToString(TripRepository.ImportedTripInsert.serializer(), placeholder))
        assertEquals("tractor-id", placeholderDecoded.tractorId)
        assertNull(placeholderDecoded.machineId)
    }
}
