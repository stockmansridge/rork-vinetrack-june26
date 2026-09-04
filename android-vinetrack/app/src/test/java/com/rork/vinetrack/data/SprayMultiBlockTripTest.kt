package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.ui.resolveTripPinAttribution
import com.rork.vinetrack.ui.resolveTripRowLockBoundary
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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
    fun `actual trip start outbox preserves complete plan and survives process death`() {
        val store = InMemoryPendingWriteStore()
        val pending = PendingWriteRepository(store)
        val sync = TripStartSync(pending)
        val trip = completeTrip(active = true)

        sync.enqueue(trip)
        val afterRestart = PendingWriteRepository(store).list().single()
        val payload = json.decodeFromString(TripStartSync.Payload.serializer(), afterRestart.payloadJson)

        assertEquals(ids, payload.paddockIds)
        assertEquals("everySecondRow", payload.trackingPattern)
        assertEquals(listOf(0.5, 68.5, 108.5), payload.rowSequence)
        assertEquals(1, payload.sequenceIndex)
        assertEquals(68.5, payload.currentRowNumber!!, 0.001)
        assertEquals(108.5, payload.nextRowNumber!!, 0.001)
        assertEquals(4, payload.totalTanks)
        assertFalse(payload.activateExisting)

        val legacy = """{"tripId":"legacy","vineyardId":"vineyard","startTime":"2026-01-01T00:00:00Z","clientUpdatedAt":"2026-01-01T00:00:00Z","savedAt":1}"""
        val decodedLegacy = json.decodeFromString(TripStartSync.Payload.serializer(), legacy)
        assertEquals(0, decodedLegacy.sequenceIndex)
        assertNull(decodedLegacy.totalTanks)
    }

    @Test
    fun `offline saved job activation preserves identity plan and durable activation marker`() {
        val planned = completeTrip(active = false)
        val activated = SavedTripActivation.activate(planned, "2026-09-06T12:00:00Z")!!
        assertEquals(planned.id, activated.id)
        assertEquals(ids, activated.paddockIds)
        assertEquals(planned.rowSequence, activated.rowSequence)
        assertEquals(planned.trackingPattern, activated.trackingPattern)
        assertEquals(planned.totalTanks, activated.totalTanks)
        assertEquals("2026-09-06T12:00:00Z", activated.startTime)
        assertTrue(activated.isActive)

        val store = InMemoryPendingWriteStore()
        TripStartSync(PendingWriteRepository(store)).enqueueActivation(activated)
        val restored = PendingWriteRepository(store).list().single()
        val payload = json.decodeFromString(TripStartSync.Payload.serializer(), restored.payloadJson)
        assertEquals(planned.id, restored.clientId)
        assertTrue(payload.activateExisting)
        assertEquals(ids, payload.paddockIds)
        assertEquals(4, payload.totalTanks)
        assertEquals(1, payload.sequenceIndex)

        assertNull(SavedTripActivation.activate(planned.copy(endTime = "2026-09-05T00:00:00Z"), "later"))
    }

    @Test
    fun `Pinot containment beats primary Sauv and Auto Path resolves in every selected block`() {
        val blocks = listOf(
            block(ids[0], 1, 149.000),
            block(ids[1], 69, 149.010),
            block(ids[2], 109, 149.020),
        )
        val trip = completeTrip(active = true)

        val pinot = resolveTripRowLockBoundary(trip, blocks, -33.0, 149.010)
        assertEquals(ids[1], pinot.resolution?.paddock?.id)
        assertEquals(69, pinot.resolution?.rowHit?.rowNumber)
        assertEquals(69, pinot.resolution?.globalRowNumber)
        assertEquals(68.5, pinot.livePath!!, 0.001)
        assertTrue(pinot.isInCorridor)

        blocks.zip(listOf(1, 69, 109)).forEach { (block, expectedRow) ->
            val boundary = resolveTripRowLockBoundary(
                trip,
                blocks,
                -33.0,
                block.polygonPoints!![0].longitude + 0.001,
            )
            assertNotNull(boundary.resolution)
            assertEquals(block.id, boundary.resolution?.paddock?.id)
            assertEquals(expectedRow, boundary.resolution?.rowHit?.rowNumber)
            assertEquals(expectedRow, boundary.resolution?.globalRowNumber)
        }
    }

    @Test
    fun `selected scope never falls through to an unselected loaded block`() {
        val selectedMissing = completeTrip(active = true).copy(paddockIds = listOf(ids[1]), paddockId = ids[1])
        val unselected = block("neighbour", 500, 149.010)
        assertNull(TripBlockResolver.resolve(selectedMissing, listOf(unselected), -33.0, 149.010))

        val noDeclaredScope = selectedMissing.copy(paddockIds = emptyList(), paddockId = null)
        assertEquals(
            "neighbour",
            TripBlockResolver.resolve(noDeclaredScope, listOf(unselected), -33.0, 149.010)?.paddock?.id,
        )
    }

    @Test
    fun `overlapping selected polygons choose the block with the closest valid row`() {
        val farther = block(ids[0], 1, 149.010).copy(
            rows = listOf(
                PaddockRow(
                    number = 1,
                    startPoint = CoordinatePoint(-33.0008, 149.0108),
                    endPoint = CoordinatePoint(-32.9992, 149.0108),
                ),
            ),
        )
        val closest = block(ids[1], 69, 149.010)
        val result = TripBlockResolver.resolve(completeTrip(true), listOf(farther, closest), -33.0, 149.010)
        assertEquals(ids[1], result?.paddock?.id)
        assertEquals(69, result?.rowHit?.rowNumber)
    }

    @Test
    fun `activation replay classifies valid idempotent completed progressed and foreign active rows`() {
        val placeholder = completeTrip(false).copy(sequenceIndex = 0, currentRowNumber = 0.5, nextRowNumber = 68.5)
        val queued = "2026-09-06T12:00:00Z"
        assertEquals(TripStartSync.ActivationDecision.ACTIVATE, TripStartSync.activationDecision(placeholder, queued))
        assertEquals(
            TripStartSync.ActivationDecision.IDEMPOTENT_SUCCESS,
            TripStartSync.activationDecision(placeholder.copy(isActive = true, startTime = queued), queued),
        )
        assertEquals(
            TripStartSync.ActivationDecision.COMPLETED_CONFLICT,
            TripStartSync.activationDecision(placeholder.copy(endTime = "2026-09-07T00:00:00Z"), queued),
        )
        assertEquals(
            TripStartSync.ActivationDecision.ACTIVE_CONFLICT,
            TripStartSync.activationDecision(placeholder.copy(isActive = true, startTime = "2026-09-06T13:00:00Z"), queued),
        )
        assertEquals(
            TripStartSync.ActivationDecision.PROGRESS_CONFLICT,
            TripStartSync.activationDecision(placeholder.copy(completedPaths = listOf(0.5)), queued),
        )
    }

    @Test
    fun `activation coordinator executes valid idempotent conflict and missing outcomes`() = runBlocking {
        val queuedStart = "2026-09-06T12:00:00Z"
        val placeholder = completeTrip(false).copy(
            sequenceIndex = 0,
            currentRowNumber = 0.5,
            nextRowNumber = 68.5,
            startTime = queuedStart,
        )

        suspend fun replay(server: Trip?): Pair<List<Trip>, String?> {
            val store = InMemoryPendingWriteStore()
            val pending = PendingWriteRepository(store)
            TripStartSync(pending).enqueueActivation(placeholder.copy(isActive = true))
            val synced = mutableListOf<Trip>()
            val coordinator = TripStartSync(
                pending = pending,
                fetchTrip = { server },
                activateTrip = { _, start -> placeholder.copy(isActive = true, startTime = start) },
            )
            coordinator.replayAll { synced += it }
            return synced.toList() to PendingWriteRepository(store).list().singleOrNull()?.status
        }

        assertTrue(replay(placeholder).first.single().isActive)
        assertEquals(null, replay(placeholder).second)
        assertEquals(queuedStart, replay(placeholder.copy(isActive = true)).first.single().startTime)
        assertEquals(PendingWriteStatus.BLOCKED, replay(placeholder.copy(endTime = "2026-09-07T00:00:00Z")).second)
        assertEquals(PendingWriteStatus.BLOCKED, replay(placeholder.copy(isActive = true, startTime = "2026-09-06T13:00:00Z")).second)
        assertEquals(PendingWriteStatus.BLOCKED, replay(placeholder.copy(completedPaths = listOf(0.5))).second)
        assertEquals(PendingWriteStatus.BLOCKED, replay(null).second)
    }

    @Test
    fun `start reconciliation cannot undo row tank pause or locally ended state`() {
        val server = completeTrip(true).copy(sequenceIndex = 0, currentRowNumber = 0.5, nextRowNumber = 68.5)
        val local = server.copy(
            isActive = false,
            isPaused = false,
            endTime = "2026-09-06T13:00:00Z",
            pathPoints = listOf(CoordinatePoint(-33.0, 149.010)),
            totalDistance = 123.0,
            completedPaths = listOf(68.5),
            skippedPaths = listOf(0.5),
            sequenceIndex = 2,
            currentRowNumber = 108.5,
            nextRowNumber = null,
            tankSessions = listOf(TankSession(id = "tank", tankNumber = 2, startTime = "2026-09-06T12:10:00Z")),
            activeTankNumber = 2,
            isFillingTank = true,
            fillingTankNumber = 3,
            pauseTimestamps = listOf("2026-09-06T12:20:00Z"),
            resumeTimestamps = listOf("2026-09-06T12:25:00Z"),
            completionNotes = "Finished locally",
            endEngineHours = 812.4,
        )
        val reconciled = TripStartReconciliation.reconcile(server, local)
        assertFalse(reconciled.isActive)
        assertEquals(local.endTime, reconciled.endTime)
        assertEquals(local.completedPaths, reconciled.completedPaths)
        assertEquals(local.sequenceIndex, reconciled.sequenceIndex)
        assertEquals(local.tankSessions, reconciled.tankSessions)
        assertEquals(local.pauseTimestamps, reconciled.pauseTimestamps)
        assertEquals(local.completionNotes, reconciled.completionNotes)
        assertEquals(local.pathPoints, reconciled.pathPoints)
    }

    @Test
    fun `saved spray activation refreshes clocks and preserves frozen calculator plan`() {
        val chemical = SprayChemical(id = "chemical", name = "Product", volumePerTank = 2.5)
        val tanks = listOf(SprayTank(id = "tank", tankNumber = 1, waterVolume = 1000.0, chemicals = listOf(chemical)))
        val original = SprayRecord(
            id = "spray-id",
            vineyardId = "vineyard",
            tripId = "trip-id",
            date = "2026-09-01T09:00:00Z",
            startTime = "2026-09-01T09:00:00Z",
            tanks = tanks,
            grossAreaHa = 12.0,
            totalCarrierLitres = 4000.0,
        )
        val activated = SavedTripActivation.activateLinkedSpray(original, "trip-id", "2026-09-06T12:00:00Z")!!
        val input = SavedTripActivation.sprayUpdateInput(activated)
        assertEquals(original.id, activated.id)
        assertEquals(original.tripId, activated.tripId)
        assertEquals("2026-09-06T12:00:00Z", input.date)
        assertEquals("2026-09-06T12:00:00Z", input.startTime)
        assertEquals(tanks, input.tanks)
        assertEquals(original.applicationGeometry, input.applicationGeometry)
        assertEquals(2.5, input.tanks.single().chemicals.single().volumePerTank, 0.001)

        val store = InMemoryPendingWriteStore()
        SprayRecordUpdateSync(PendingWriteRepository(store)).enqueue(
            activated.id,
            input,
            "2026-09-06T12:00:00Z",
        )
        val durable = PendingWriteRepository(store).list().single()
        val payload = json.decodeFromString(SprayRecordUpdateSync.Payload.serializer(), durable.payloadJson)
        assertEquals(original.id, payload.id)
        assertEquals(original.tripId, payload.tripId)
        assertEquals(input.tanks, payload.tanks)
        assertEquals(input.applicationGeometry, payload.applicationGeometry)
    }

    @Test
    fun `trip pin attribution follows containing selected block`() {
        val blocks = listOf(
            block(ids[0], 1, 149.000),
            block(ids[1], 69, 149.010),
            block(ids[2], 109, 149.020),
        )
        val attribution = resolveTripPinAttribution(
            activeTrip = completeTrip(active = true),
            paddocks = blocks,
            latitude = -33.0,
            longitude = 149.010,
            side = "left",
            callerPaddockId = ids[0],
            callerRowNumber = 1,
            callerPlacement = null,
        )
        val placement = attribution.placement!!
        assertEquals(ids[1], attribution.paddockId)
        assertEquals(69, attribution.rowNumber)
        assertEquals(69.0, placement.pinRowNumber!!, 0.001)

        // The exact production outbox shape must keep trip, block, and row as
        // one attribution even when the launcher's stale values were Sauv/1.
        val input = PinRepository.PinInput(
            id = "pin-id",
            vineyardId = "vineyard",
            tripId = "trip-id",
            paddockId = attribution.paddockId,
            rowNumber = attribution.rowNumber,
            pinRowNumber = placement.pinRowNumber,
            snappedLatitude = placement.snappedLatitude,
            snappedLongitude = placement.snappedLongitude,
            snappedToRow = placement.snappedToRow,
            latitude = -33.0,
            longitude = 149.010,
        )
        val store = InMemoryPendingWriteStore()
        PinCreateSync(PendingWriteRepository(store)).enqueue(input)
        val persisted = PendingWriteRepository(store).list().single()
        val decoded = json.decodeFromString(PinRepository.PinInput.serializer(), persisted.payloadJson)
        assertEquals("trip-id", decoded.tripId)
        assertEquals(ids[1], decoded.paddockId)
        assertEquals(69, decoded.rowNumber)
        assertEquals(69.0, decoded.pinRowNumber!!, 0.001)
    }
}
