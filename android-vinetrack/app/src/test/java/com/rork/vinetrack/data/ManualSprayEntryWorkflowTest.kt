package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.ManualSprayBlock
import com.rork.vinetrack.data.model.ManualSprayChemical
import com.rork.vinetrack.data.model.ManualSprayPayload
import com.rork.vinetrack.data.model.ManualSprayPhysicalForm
import com.rork.vinetrack.data.model.ManualSpraySaveResponse
import com.rork.vinetrack.data.model.ManualSprayTank
import com.rork.vinetrack.data.model.canManageManualSprays
import kotlinx.coroutines.runBlocking
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
        coordinator.replay("operator")
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

private class MemoryStore : ManualSprayOperationStoring {
    var values: List<PendingManualSprayOperation> = emptyList()
    override fun load(): List<PendingManualSprayOperation> = values
    override fun save(operations: List<PendingManualSprayOperation>): Boolean { values = operations; return true }
}

private class TerminalGateway(private val error: Throwable) : ManualSprayGateway {
    override suspend fun save(operationId: String, payload: ManualSprayPayload, expectedVersion: Int?): ManualSpraySaveResponse = throw error
    override suspend fun delete(operationId: String, payload: ManualSprayPayload) = Unit
}

private class GatewayDouble(var failSave: Boolean = false, var failDelete: Boolean = false) : ManualSprayGateway {
    val operationIds = mutableListOf<String>()
    override suspend fun save(operationId: String, payload: ManualSprayPayload, expectedVersion: Int?): ManualSpraySaveResponse {
        operationIds += operationId
        if (failSave) { failSave = false; error("lost response") }
        return ManualSpraySaveResponse(operationId, payload.manualEntryId, payload.sprayRecordId, payload.tripId, "manual", "completed", 1, true)
    }
    override suspend fun delete(operationId: String, payload: ManualSprayPayload) { if (failDelete) { failDelete = false; error("offline") } }
}
