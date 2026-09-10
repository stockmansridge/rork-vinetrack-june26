package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.ManualSprayBlock
import com.rork.vinetrack.data.model.ManualSprayChemical
import com.rork.vinetrack.data.model.ManualSprayPayload
import com.rork.vinetrack.data.model.ManualSprayPhysicalForm
import com.rork.vinetrack.data.model.ManualSpraySaveResponse
import com.rork.vinetrack.data.model.ManualSprayTank
import com.rork.vinetrack.data.model.canManageManualSprays
import com.rork.vinetrack.ui.screens.initializeBlankManualInput
import com.rork.vinetrack.ui.screens.manualSprayVineyardZone
import com.rork.vinetrack.ui.screens.shouldLoadManualEditEvidence
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class ManualSprayEntryWorkflowTest {
    @Test fun supervisorAllowedOperatorRejected() {
        assertTrue(canManageManualSprays("supervisor"))
        assertFalse(canManageManualSprays("operator"))
    }

    @Test fun midnightAndBaseUnitsRoundTrip() {
        val payload = fixture()
        assertNull(payload.validationError())
        assertEquals(2_500.0, payload.tanks.first().chemicals.first().actualAmountBase, 0.0)
        assertEquals(750.0, payload.tanks.last().chemicals.first().actualAmountBase, 0.0)
    }

    @Test fun incompleteDraftTextSerializesWithoutNaNAndOnlyValidatedValuesReachPayload() {
        val fullPayload = fixture()
        val tank = fullPayload.tanks.first()
        val payload = fullPayload.copy(tanks = listOf(tank))
        val chemical = tank.chemicals.first()
        val incomplete = ManualSprayFormDraft(
            base = payload,
            waterInputs = mapOf(tank.id to ""),
            chemicalInputs = mapOf(chemical.id to "not-a-number"),
        )
        val encoded = Json.encodeToString(ManualSprayFormDraft.serializer(), incomplete)
        assertFalse(encoded.contains("NaN"))
        assertEquals("", Json.decodeFromString(ManualSprayFormDraft.serializer(), encoded).waterInputs[tank.id])
        assertTrue(runCatching { incomplete.validatedPayload() }.isFailure)

        val valid = incomplete.copy(waterInputs = mapOf(tank.id to "0"), chemicalInputs = mapOf(chemical.id to "2.5"))
        val validated = valid.validatedPayload()
        assertEquals(0.0, validated.tanks.first().waterVolumeLitres, 0.0)
        assertEquals(2_500.0, validated.tanks.first().chemicals.first().actualAmountBase, 0.0)
    }

    @Test fun newInputsAreBlankWhileRestoredAndCopiedZerosRemainExplicit() {
        val inputs = mutableMapOf("restored" to "0")
        initializeBlankManualInput(inputs, "new")
        assertEquals("", inputs["new"])
        assertEquals("0", inputs["restored"])
        assertTrue(runCatching {
            val fullPayload = fixture()
            val payload = fullPayload.copy(tanks = listOf(fullPayload.tanks.first()))
            ManualSprayFormDraft(
                base = payload,
                waterInputs = mapOf(payload.tanks.first().id to ""),
                chemicalInputs = mapOf(payload.tanks.first().chemicals.first().id to ""),
            ).validatedPayload()
        }.isFailure)
    }

    @Test fun loadedEditEvidenceSurvivesRefreshAndRetainsSavedVineyardTimeZone() {
        val loaded = fixture().copy(vineyardTimeZone = "Australia/Adelaide", notes = "Unsaved edit")
        assertFalse(shouldLoadManualEditEvidence(loaded, loadedRetry = 0, editRetry = 0))
        assertTrue(shouldLoadManualEditEvidence(null, loadedRetry = null, editRetry = 0))
        assertTrue(shouldLoadManualEditEvidence(loaded, loadedRetry = 0, editRetry = 1))
        assertEquals("Australia/Adelaide", manualSprayVineyardZone(loaded, java.time.ZoneId.of("UTC")).id)
        assertEquals("Australia/Adelaide", loaded.copy(notes = "Changed note").vineyardTimeZone)
    }

    @Test fun copyPreviousPreservesEnteredTextForNewStableIdentities() {
        val previous = fixture().tanks.first()
        val copy = previous.copied(2)
        val copied = copyManualTankInputs(previous, copy, mapOf(previous.id to "123.5"), mapOf(previous.chemicals.first().id to "0"))
        assertTrue(copy.id != previous.id)
        assertTrue(copy.chemicals.first().id != previous.chemicals.first().id)
        assertEquals("123.5", copied.waterInputs[copy.id])
        assertEquals("0", copied.chemicalInputs[copy.chemicals.first().id])
    }

    @Test fun notesOnlyDraftPreservesWeatherSourceAndObservationTime() {
        val payload = fixture().copy(manualWeather = com.rork.vinetrack.data.model.ManualSprayWeather("2026-09-08T23:45:00Z", "Recorded station override", temperatureC = 12.0))
        val draft = ManualSprayFormDraft(payload.copy(notes = "Changed note"))
        val validated = draft.validatedPayload()
        assertEquals("2026-09-08T23:45:00Z", validated.manualWeather?.observedAt)
        assertEquals("Recorded station override", validated.manualWeather?.source)
    }

    @Test fun terminalConflictAndDeletedErrorsAreNotQueuedForReplay() = runBlocking {
        listOf(ManualSprayMutationException.StaleVersion(), ManualSprayMutationException.Deleted()).forEach { terminal ->
            val store = MemoryStore()
            val coordinator = ManualSprayEntryCoordinator(TerminalGateway(terminal), store)
            val result = runCatching { coordinator.save(fixture(), 1) }
            assertTrue(result.exceptionOrNull() is ManualSprayMutationException)
            assertTrue(coordinator.pendingPayloads().isEmpty())
            assertTrue(store.values.isEmpty())
        }
    }

    @Test fun failedPersistenceNeverSendsOrCreatesMemoryShortcut() = runBlocking {
        val gateway = GatewayDouble()
        val store = MemoryStore(failSaves = 1)
        val coordinator = ManualSprayEntryCoordinator(gateway, store)
        assertTrue(runCatching { coordinator.save(fixture(), 0) }.isFailure)
        assertTrue(gateway.operationIds.isEmpty())
        assertTrue(coordinator.pendingPayloads().isEmpty())
    }

    @Test fun unconfirmedOrMismatchedResponseKeepsExactRetry() = runBlocking {
        val payload = fixture()
        val gateway = GatewayDouble(serverConfirmed = false)
        val coordinator = ManualSprayEntryCoordinator(gateway, MemoryStore())
        assertNull(coordinator.save(payload, 0))
        assertEquals(payload, coordinator.pendingPayloads().single())
    }

    @Test fun replayUsesEachOperationsOwningVineyardRole() = runBlocking {
        val payload = fixture()
        val gateway = GatewayDouble(failSave = true)
        val coordinator = ManualSprayEntryCoordinator(gateway, MemoryStore())
        coordinator.save(payload, 0)
        coordinator.replay { vineyardId -> if (vineyardId == payload.vineyardId) "operator" else "owner" }
        assertEquals(1, gateway.operationIds.size)
        assertEquals(payload, coordinator.pendingPayloads().single())
    }

    @Test fun lostResponseReplaysSameOperationAndDeleteSuppressesCreate() = runBlocking {
        val gateway = GatewayDouble(failSave = true)
        val store = MemoryStore()
        val coordinator = ManualSprayEntryCoordinator(gateway, store)
        val payload = fixture()
        assertNull(coordinator.save(payload, 0))
        assertEquals(payload.manualEntryId, coordinator.pendingPayloads().single().manualEntryId)
        assertTrue(coordinator.save(payload, 0)?.serverConfirmed == true)
        assertTrue(coordinator.pendingPayloads().isEmpty())
        assertEquals(1, gateway.operationIds.distinct().size)

        val second = fixture()
        gateway.failSave = true
        coordinator.save(second, 0)
        gateway.failDelete = true
        coordinator.delete(second)
        assertTrue(coordinator.pendingPayloads().none { it.manualEntryId == second.manualEntryId })
        coordinator.replay { "operator" }
        assertTrue(store.values.any { it.kind == PendingManualSprayKind.DELETE })
    }

    private fun fixture(): ManualSprayPayload = ManualSprayPayload(
        vineyardId = UUID.randomUUID().toString(), reference = "Manual 1", operationType = "Foliar Spray",
        startUtc = "2026-09-08T23:30:00Z", endUtc = "2026-09-09T01:00:00Z", vineyardTimeZone = "Australia/Adelaide",
        tractorId = UUID.randomUUID().toString(), operatorUserId = UUID.randomUUID().toString(), sprayEquipmentId = UUID.randomUUID().toString(),
        startEngineHours = 100.0, endEngineHours = 101.0,
        blocks = listOf(ManualSprayBlock(UUID.randomUUID().toString(), "A")),
        tanks = listOf(
            ManualSprayTank(tankNumber = 1, waterVolumeLitres = 2_000.0, chemicals = listOf(ManualSprayChemical(savedChemicalId = UUID.randomUUID().toString(), name = "Liquid", actualAmountBase = 2_500.0, unit = "Litres", productCategory = "fungicide", physicalForm = ManualSprayPhysicalForm.liquid))),
            ManualSprayTank(tankNumber = 2, waterVolumeLitres = 1_500.0, chemicals = listOf(ManualSprayChemical(savedChemicalId = UUID.randomUUID().toString(), name = "Solid", actualAmountBase = 750.0, unit = "Kg", productCategory = "fungicide", physicalForm = ManualSprayPhysicalForm.solid))),
        ),
    )
}

private class MemoryStore(private var failSaves: Int = 0) : ManualSprayOperationStoring {
    var values: List<PendingManualSprayOperation> = emptyList()
    override fun load(): List<PendingManualSprayOperation> = values
    override fun save(operations: List<PendingManualSprayOperation>): Boolean {
        if (failSaves > 0) { failSaves -= 1; return false }
        values = operations
        return true
    }
}

private class TerminalGateway(private val error: Throwable) : ManualSprayGateway {
    override suspend fun save(operationId: String, payload: ManualSprayPayload, expectedVersion: Int?): ManualSpraySaveResponse = throw error
    override suspend fun delete(operationId: String, payload: ManualSprayPayload) = Unit
}

private class GatewayDouble(
    var failSave: Boolean = false,
    var failDelete: Boolean = false,
    var serverConfirmed: Boolean = true,
) : ManualSprayGateway {
    val operationIds = mutableListOf<String>()
    override suspend fun save(operationId: String, payload: ManualSprayPayload, expectedVersion: Int?): ManualSpraySaveResponse {
        operationIds += operationId
        if (failSave) { failSave = false; error("lost response") }
        return ManualSpraySaveResponse(operationId, payload.manualEntryId, payload.sprayRecordId, payload.tripId, "manual", "completed", 1, serverConfirmed)
    }
    override suspend fun delete(operationId: String, payload: ManualSprayPayload) { if (failDelete) { failDelete = false; error("offline") } }
}
