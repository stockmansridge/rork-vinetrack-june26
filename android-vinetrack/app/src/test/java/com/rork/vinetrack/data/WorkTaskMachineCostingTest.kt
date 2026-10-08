package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class WorkTaskMachineCostingTest {
    @Test fun automaticFuelAndCharges() {
        val result = WorkTaskMachineCosting.resolve(2.0, null, 8.0, 2.0, 40.0, null, null, null)
        assertEquals(16.0, result.fuelLitres)
        assertEquals(32.0, result.fuelCost)
        assertEquals(80.0, result.machineCharge)
    }
    @Test fun engineHoursPreferredIncludingZero() {
        assertEquals(8.0, WorkTaskMachineCosting.resolve(2.0, 1.0, 8.0, 2.0, 40.0, null, null, null).fuelLitres)
        assertEquals(0.0, WorkTaskMachineCosting.resolve(2.0, 0.0, 8.0, 2.0, 40.0, null, null, null).fuelLitres)
    }
    @Test fun missingConfigurationIsNotZero() {
        val result = WorkTaskMachineCosting.resolve(2.0, null, null, null, null, null, null, null)
        assertNull(result.fuelLitres); assertNull(result.fuelCost); assertNull(result.machineCharge)
    }
    @Test fun manualQuantityWithMissingRate() {
        val result = WorkTaskMachineCosting.resolve(2.0, null, null, 2.0, 40.0, 10.0, null, null)
        assertEquals(10.0, result.fuelLitres); assertEquals(20.0, result.fuelCost)
    }
    @Test fun missingPriceLeavesCostUnset() {
        val result = WorkTaskMachineCosting.resolve(2.0, null, 8.0, null, 40.0, null, null, null)
        assertEquals(16.0, result.fuelLitres); assertNull(result.fuelCost)
    }
    @Test fun overridesSurviveEquipmentAndPriceRefresh() {
        val result = WorkTaskMachineCosting.resolve(9.0, 4.0, 30.0, 7.0, 40.0, 10.123456789, 19.123456789, 55.123456789)
        assertEquals(10.123456789, result.fuelLitres); assertEquals(19.123456789, result.fuelCost); assertEquals(55.123456789, result.machineCharge)
    }
    @Test fun zeroOverridesRemainExplicit() {
        val result = WorkTaskMachineCosting.resolve(2.0, null, 8.0, 2.0, 40.0, 0.0, 0.0, 0.0)
        assertEquals(WorkTaskMachineCosting.Result(0.0, 0.0, 0.0), result)
    }
    @Test fun clearingOverridesRestoresAutomatic() {
        val result = WorkTaskMachineCosting.resolve(2.0, null, 12.0, 3.0, 40.0, null, null, null)
        assertEquals(WorkTaskMachineCosting.Result(24.0, 72.0, 80.0), result)
    }
    @Test fun zeroRateAndOverflowUnavailable() {
        assertNull(WorkTaskMachineCosting.resolve(2.0, null, 0.0, 2.0, 40.0, null, null, null).fuelLitres)
        assertNull(WorkTaskMachineCosting.product(Double.MAX_VALUE, 2.0)); assertNull(WorkTaskMachineCosting.valid(-1.0))
    }
    @Test fun equipmentScopedIncludingLegacyMapping() {
        val machine = VineyardMachine("machine", "vineyard", fuelUsageLPerHour = 8.0, legacyTractorId = "tractor")
        assertEquals(machine, WorkTaskMachineCosting.equipment("vineyard", "tractor", "tractor", listOf(machine)))
        assertEquals(machine, WorkTaskMachineCosting.equipment("vineyard", "vineyard_machine", "machine", listOf(machine)))
        assertNull(WorkTaskMachineCosting.equipment("other", "tractor", "tractor", listOf(machine)))
        assertNull(WorkTaskMachineCosting.equipment("vineyard", "tractor", null, listOf(machine)))
        assertNull(WorkTaskMachineCosting.equipment("vineyard", "tractor", "tractor", listOf(machine.copy(deletedAt = "deleted"))))
    }
    @Test fun weightedPriceScoped() {
        val purchases = listOf(FuelPurchase("a", "vineyard", 10.0, 10.0), FuelPurchase("b", "vineyard", 30.0, 70.0), FuelPurchase("c", "other", 100.0, 900.0))
        assertEquals(2.0, WorkTaskMachineCosting.fuelPrice("vineyard", purchases)); assertNull(WorkTaskMachineCosting.fuelPrice("empty", purchases))
    }
    @Test fun canonicalPayloadReopensWithoutRepricing() {
        val json = Json { encodeDefaults = true }
        val payload = WorkTaskMachineSync.UpsertPayload(id = "line", workTaskId = "task", vineyardId = "vineyard", workDate = "2026-10-08", equipmentSource = "tractor", equipmentRefId = "tractor", equipmentNameSnapshot = "Tractor", durationHours = 2.0, engineHoursUsed = 0.0, entrySource = "correction", fuelLitres = 16.0, fuelCost = 0.0, hourlyMachineRate = 40.0, totalMachineCost = 80.0, notes = "", clientUpdatedAt = "2026-10-08T00:00:00Z")
        val reopened = json.decodeFromString(WorkTaskMachineSync.UpsertPayload.serializer(), json.encodeToString(WorkTaskMachineSync.UpsertPayload.serializer(), payload))
        assertEquals(payload, reopened)
        val marker = PendingWrite(id = "write", entityType = PendingEntityType.WORK_TASK_MACHINE, opType = PendingOpType.CREATE, clientId = "line", payloadJson = json.encodeToString(WorkTaskMachineSync.UpsertPayload.serializer(), reopened), createdAt = 1, updatedAt = 1)
        val rows = PendingWriteOverlay.overlayMachineLines(emptyList(), listOf(marker), setOf("task"), "task")
        val row = rows.single()
        assertEquals(0.0, row.engineHoursUsed); assertEquals(16.0, row.fuelLitres); assertEquals(0.0, row.fuelCost); assertEquals("correction", row.entrySource)
        val wire = json.encodeToString(WorkTaskMachineLine.serializer(), row)
        assertTrue(wire.contains("\"engine_hours_used\":0.0")); assertTrue(wire.contains("\"total_machine_cost\":80.0"))
        assertEquals(rows, PendingWriteOverlay.overlayMachineLines(rows, listOf(marker), setOf("task"), "task"))
    }
    @Test fun clearedMachineFieldsEncodeExplicitNulls() {
        val body = WorkTaskLineRepository.MachineLineUpsert(id = "line", workTaskId = "task", vineyardId = "vineyard", workDate = "2026-10-08", equipmentNameSnapshot = "Machine", notes = "", clientUpdatedAt = "2026-10-08T00:00:00Z")
        val snapshot = Json.parseToJsonElement(WorkTaskLineRepository.encodeMachineSnapshot(body)).jsonArray.single().jsonObject
        for (key in listOf("engine_hours_used", "duration_hours", "fuel_litres", "fuel_cost", "hourly_machine_rate", "total_machine_cost", "equipment_ref_id", "worker_type_id")) {
            assertEquals(JsonNull, snapshot[key])
        }
        assertFalse(snapshot.containsKey("operator_user_id"))
    }
    @Test fun legacyPayloadStillDecodes() {
        val payload = Json.decodeFromString(WorkTaskMachineSync.UpsertPayload.serializer(), """{"id":"line","workTaskId":"task","vineyardId":"vineyard","workDate":"2026-10-08","equipmentNameSnapshot":"Machine","notes":"","clientUpdatedAt":"now"}""")
        assertNull(payload.engineHoursUsed); assertEquals("manual", payload.entrySource)
    }
    @Test fun missingAmountsKeepSummaryIncomplete() {
        val task = WorkTask("task", "vineyard")
        val line = WorkTaskMachineLine("line", "task", "vineyard", fuelLitres = 16.0, totalMachineCost = 80.0)
        val result = WorkTaskCostRollup.resolve(task, emptyList(), listOf(line), emptyList(), emptyList(), emptyList(), false)
        assertFalse(result.isComplete); assertNull(result.costPerArea(2.0, 2.0))
    }
    @Test fun linkedTripCostsRemainSeparate() {
        val task = WorkTask("task", "vineyard")
        val trip = Trip("trip", "vineyard", workTaskId = "task")
        val allocation = TripCostAllocation("allocation", "vineyard", "trip", totalCostRaw = "12", labourCostRaw = "5")
        val line = WorkTaskMachineLine("line", "task", "vineyard", fuelCost = 32.0, totalMachineCost = 80.0)
        val result = WorkTaskCostRollup.resolve(task, emptyList(), listOf(line), listOf(trip), listOf(allocation), emptyList(), false)
        assertEquals("12.00", result.linkedTripCost.toPlainString()); assertEquals("124.00", result.totalCost.toPlainString())
    }
    @Test fun outboxRepositoryRestartRetainsSnapshot() {
        val store = InMemoryPendingWriteStore()
        val repo = PendingWriteRepository(store)
        val payload = WorkTaskMachineSync.UpsertPayload(id = "line", workTaskId = "task", vineyardId = "vineyard", workDate = "2026-10-08", equipmentNameSnapshot = "Machine", engineHoursUsed = 0.0, fuelLitres = 16.0, fuelCost = 0.0, totalMachineCost = 80.0, notes = "", clientUpdatedAt = "2026-10-08T00:00:00Z")
        repo.enqueue(PendingEntityType.WORK_TASK_MACHINE, PendingOpType.CREATE, Json.encodeToString(WorkTaskMachineSync.UpsertPayload.serializer(), payload), "line")
        val reopened = PendingWriteRepository(store)
        val rows = PendingWriteOverlay.overlayMachineLines(emptyList(), reopened.list(), setOf("task"), "task")
        assertEquals(16.0, rows.single().fuelLitres); assertEquals(0.0, rows.single().fuelCost); assertEquals(0.0, rows.single().engineHoursUsed)
        assertEquals(80.0, rows.single().totalMachineCost)
    }
    @Test fun taskRollupIncludesSeparateFuelOnce() {
        val task = WorkTask("task", "vineyard")
        val line = WorkTaskMachineLine("line", "task", "vineyard", durationHours = 2.0, fuelCost = 32.0, hourlyMachineRate = 40.0, totalMachineCost = 80.0)
        val labour = WorkTaskLabourLine("labour", "task", "vineyard", hoursPerWorker = 2.0, hourlyRate = 38.0, totalCost = 76.0)
        val result = WorkTaskCostRollup.resolve(task, listOf(labour), listOf(line), emptyList(), emptyList(), emptyList(), false)
        assertEquals("188.00", result.totalCost.toPlainString()); assertEquals("112.00", result.manualMachineCost.toPlainString())
        assertEquals("94.00", result.costPerArea(2.0, 2.0)?.toPlainString())
    }
}
