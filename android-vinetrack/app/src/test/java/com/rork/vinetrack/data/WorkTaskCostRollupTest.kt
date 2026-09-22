package com.rork.vinetrack.data

import com.rork.vinetrack.data.material.WorkTaskMaterial
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.TripCostAllocation
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskCostRollup
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.WorkTaskMachineLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigDecimal

class WorkTaskCostRollupTest {
    private val vineyard = "vineyard"
    private val taskId = "task"
    private val task = WorkTask(id = taskId, vineyardId = vineyard)

    private fun labour(cost: Double? = 100.0, rate: Double? = 25.0) = WorkTaskLabourLine(
        id = "labour", workTaskId = taskId, vineyardId = vineyard,
        workerCount = 1, hoursPerWorker = 4.0, hourlyRate = rate, totalCost = cost,
    )

    private fun material(cost: String = "180.00") = WorkTaskMaterial(
        id = "material", workTaskId = taskId, vineyardId = vineyard,
        materialName = "Post", quantityRaw = "1", unitCostRaw = cost, totalCostRaw = cost,
    )

    @Test fun `material-only task totals 180 only when gate allows it`() {
        val allowed = WorkTaskCostRollup.resolve(task, emptyList(), emptyList(), emptyList(), emptyList(), listOf(material()), true)
        val denied = WorkTaskCostRollup.resolve(task, emptyList(), emptyList(), emptyList(), emptyList(), listOf(material()), false)
        assertEquals(BigDecimal("180.00"), allowed.totalCost)
        assertEquals(BigDecimal("0.00"), denied.totalCost)
    }

    @Test fun `labour machine linked trip and materials each contribute once`() {
        val machine = WorkTaskMachineLine(
            id = "machine", workTaskId = taskId, vineyardId = vineyard,
            totalMachineCost = 50.0,
        )
        val trip = Trip(id = "trip", vineyardId = vineyard, workTaskId = taskId)
        val allocation = TripCostAllocation(id = "allocation", vineyardId = vineyard, tripId = trip.id, totalCostRaw = "75.25")
        val result = WorkTaskCostRollup.resolve(task, listOf(labour()), listOf(machine), listOf(trip), listOf(allocation), listOf(material()), true)
        assertEquals(BigDecimal("405.25"), result.totalCost)
        assertEquals(BigDecimal("75.25"), result.linkedTripCost)
        assertEquals(BigDecimal("202.63"), result.costPerArea(2.0, 2.0))
    }

    @Test fun `piece rate remains the single labour source`() {
        val pieceTask = task.copy(costingMethod = "piece_rate", pieceVineCount = 200, pieceRatePerVine = 0.50)
        val result = WorkTaskCostRollup.resolve(pieceTask, listOf(labour(cost = 999.0)), emptyList(), emptyList(), emptyList(), emptyList(), true)
        assertEquals(BigDecimal("100.00"), result.labourCost)
        assertEquals(BigDecimal("100.00"), result.totalCost)
    }

    @Test fun `stored trip allocation is used without estimating from trip`() {
        val trip = Trip(id = "trip", vineyardId = vineyard, workTaskId = taskId, totalDistance = 99999.0)
        val allocation = TripCostAllocation(id = "allocation", vineyardId = vineyard, tripId = trip.id, totalCostRaw = "12.34")
        val duplicateUnlinked = TripCostAllocation(id = "other", vineyardId = vineyard, tripId = "other-trip", totalCostRaw = "500")
        val result = WorkTaskCostRollup.resolve(task, emptyList(), emptyList(), listOf(trip), listOf(allocation, duplicateUnlinked), emptyList(), true)
        assertEquals(BigDecimal("12.34"), result.linkedTripCost)
    }

    @Test fun `missing labour rate marks material subtotal incomplete`() {
        val result = WorkTaskCostRollup.resolve(task, listOf(labour(cost = null, rate = null)), emptyList(), emptyList(), emptyList(), listOf(material()), true)
        assertEquals(BigDecimal("180.00"), result.totalCost)
        assertFalse(result.isComplete)
        assertEquals(null, result.costPerArea(1.0, 1.0))
    }

    @Test fun `season total uses the same per-task rollups`() {
        val second = WorkTask(id = "second", vineyardId = vineyard, costingMethod = "piece_rate", pieceVineCount = 10, pieceRatePerVine = 2.0)
        val season = WorkTaskCostRollup.seasonTotal(
            tasks = listOf(task, second), labourLines = listOf(labour()), machineLines = emptyList(),
            trips = emptyList(), tripCostAllocations = emptyList(), materials = listOf(material()), includeMaterials = true,
        )
        assertEquals(BigDecimal("300.00"), season.totalCost)
        assertTrue(season.isComplete)
    }
}
