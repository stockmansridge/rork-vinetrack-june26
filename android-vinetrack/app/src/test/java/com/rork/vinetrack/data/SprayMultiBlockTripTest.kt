package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.Trip
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class SprayMultiBlockTripTest {
    private val ids = listOf("sauv-blanc", "pinot-noir", "pinot-gris")
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun block(id: String, row: Int, longitude: Double): Paddock = Paddock(
        id = id,
        vineyardId = "vineyard",
        name = id,
        rowWidth = 3.0,
        polygonPoints = listOf(
            CoordinatePoint(latitude = -33.001, longitude = longitude - 0.001),
            CoordinatePoint(latitude = -33.001, longitude = longitude + 0.001),
            CoordinatePoint(latitude = -32.999, longitude = longitude + 0.001),
            CoordinatePoint(latitude = -32.999, longitude = longitude - 0.001),
        ),
        rows = listOf(
            PaddockRow(
                number = row,
                startPoint = CoordinatePoint(latitude = -33.0008, longitude = longitude),
                endPoint = CoordinatePoint(latitude = -32.9992, longitude = longitude),
            ),
        ),
    )

    private fun completeTrip(active: Boolean = false): Trip = Trip(
        id = "trip-id",
        vineyardId = "vineyard",
        paddockId = ids.first(),
        paddockName = "Sauv Blanc, Pinot Noir, Pinot Gris",
        paddockIds = ids,
        startTime = "2026-09-04T00:00:00Z",
        isActive = active,
        personName = "Operator",
        machineId = "machine-id",
        operatorUserId = "operator-id",
        trackingPattern = "everySecondRow",
        rowSequence = listOf(0.5, 68.5, 108.5),
        sequenceIndex = 1,
        currentRowNumber = 68.5,
        nextRowNumber = 108.5,
        totalTanks = 4,
    )

    @Test
    fun `all selected ids and saved row plan survive persistence sync payload and relaunch`() {
        val trip = completeTrip()
        val relaunched = json.decodeFromString(Trip.serializer(), json.encodeToString(Trip.serializer(), trip))
        assertEquals(ids, relaunched.paddockIds)
        assertEquals(ids, relaunched.effectivePaddockIds)
        assertEquals("everySecondRow", relaunched.trackingPattern)
        assertEquals(listOf(0.5, 68.5, 108.5), relaunched.rowSequence)
        assertEquals(1, relaunched.sequenceIndex)
        assertEquals(4, relaunched.totalTanks)
        assertEquals("machine-id", relaunched.machineId)
        assertEquals("operator-id", relaunched.operatorUserId)

        val insert = TripRepository.TripInsert(
            id = trip.id,
            vineyardId = trip.vineyardId,
            paddockId = trip.paddockId,
            paddockName = trip.paddockName,
            paddockIds = trip.paddockIds,
            startTime = trip.startTime!!,
            isActive = true,
            personName = trip.personName,
            machineId = trip.machineId,
            operatorUserId = trip.operatorUserId,
            trackingPattern = trip.trackingPattern,
            rowSequence = trip.rowSequence,
            sequenceIndex = trip.sequenceIndex,
            currentRowNumber = trip.currentRowNumber,
            nextRowNumber = trip.nextRowNumber,
            totalTanks = trip.totalTanks,
            clientUpdatedAt = trip.startTime,
        )
        val payload = json.encodeToString(TripRepository.TripInsert.serializer(), insert)
        val decoded = json.decodeFromString(TripRepository.TripInsert.serializer(), payload)
        assertEquals(ids, decoded.paddockIds)
        assertEquals(trip.rowSequence, decoded.rowSequence)
        assertEquals(trip.totalTanks, decoded.totalTanks)
    }

    @Test
    fun `Pinot containment beats primary Sauv and Auto Path resolves in every selected block`() {
        val blocks = listOf(
            block(ids[0], 1, 149.000),
            block(ids[1], 69, 149.010),
            block(ids[2], 109, 149.020),
        )
        val trip = completeTrip(active = true)

        val pinot = TripBlockResolver.resolve(trip, blocks, -33.0, 149.010)
        assertEquals(ids[1], pinot?.paddock?.id)
        assertEquals(69, pinot?.rowHit?.rowNumber)
        assertEquals(69, pinot?.globalRowNumber)
        assertEquals(68.5, TripBlockResolver.livePath(69, trip.rowSequence, 68.5), 0.001)

        blocks.zip(listOf(1, 69, 109)).forEach { (block, expectedRow) ->
            val resolution = TripBlockResolver.resolve(trip, blocks, -33.0, block.polygonPoints!![0].longitude + 0.001)
            assertNotNull(resolution)
            assertEquals(block.id, resolution?.paddock?.id)
            assertEquals(expectedRow, resolution?.rowHit?.rowNumber)
            assertEquals(expectedRow, resolution?.globalRowNumber)
        }
    }

    @Test
    fun `trip pin attribution follows containing selected block`() {
        val blocks = listOf(
            block(ids[0], 1, 149.000),
            block(ids[1], 69, 149.010),
            block(ids[2], 109, 149.020),
        )
        val resolution = TripBlockResolver.resolve(completeTrip(active = true), blocks, -33.0, 149.010)
        val placement = PinPlacement.resolve(
            paddocks = listOf(resolution!!.paddock),
            selectedPaddockId = resolution.paddock.id,
            latitude = -33.0,
            longitude = 149.010,
            side = "left",
        )
        assertEquals(ids[1], placement.paddockId)
        assertEquals(69.0, placement.pinRowNumber!!, 0.001)
    }
}
