package com.rork.vinetrack.data.model

import com.rork.vinetrack.data.material.WorkTaskMaterial
import com.rork.vinetrack.data.material.WorkTaskMaterialCosting
import com.rork.vinetrack.data.material.NullableMaterialNumericStringSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.math.BigDecimal
import java.math.RoundingMode

/** Stored authoritative cost allocation for one linked GPS trip slice. */
@Serializable
data class TripCostAllocation(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("trip_id") val tripId: String,
    @SerialName("total_cost")
    @Serializable(with = NullableMaterialNumericStringSerializer::class)
    val totalCostRaw: String? = null,
    @SerialName("costing_status") val costingStatus: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
) {
    val totalCost: BigDecimal? get() = totalCostRaw?.toBigDecimalOrNull()
}

data class WorkTaskCostRollupResult(
    val labourCost: BigDecimal,
    val manualMachineCost: BigDecimal,
    val linkedTripCost: BigDecimal,
    val materialCost: BigDecimal,
    val totalCost: BigDecimal,
    val isComplete: Boolean,
) {
    fun costPerArea(areaHectares: Double, regionalAreaValue: Double): BigDecimal? {
        if (!isComplete || !areaHectares.isFinite() || areaHectares <= 0 || regionalAreaValue <= 0) return null
        return totalCost.divide(BigDecimal.valueOf(regionalAreaValue), 2, RoundingMode.HALF_UP)
    }
}

/** One shared, money-safe aggregation contract for every Work Task cost surface. */
object WorkTaskCostRollup {
    fun resolve(
        task: WorkTask,
        labourLines: List<WorkTaskLabourLine>,
        machineLines: List<WorkTaskMachineLine>,
        trips: List<Trip>,
        tripCostAllocations: List<TripCostAllocation>,
        materials: List<WorkTaskMaterial>,
        includeMaterials: Boolean,
    ): WorkTaskCostRollupResult {
        val scopedLabour = labourLines.filter { it.workTaskId == task.id && it.deletedAt == null }
        val effectiveLabour = PieceRateCosting.effectiveLabourCost(task, scopedLabour)
        val labourComplete = if (task.isPieceRate) {
            effectiveLabour != null
        } else {
            scopedLabour.all { it.hourlyRate != null || it.totalCost != null }
        }
        val labour = effectiveLabour?.let(BigDecimal::valueOf) ?: BigDecimal.ZERO

        val machine = machineLines
            .filter { it.workTaskId == task.id && it.deletedAt == null }
            .sumOf { BigDecimal.valueOf(it.resolvedCost) }
        val linkedTripIds = trips.filter { it.workTaskId == task.id }.mapTo(mutableSetOf()) { it.id }
        val linkedAllocations = tripCostAllocations.filter { it.deletedAt == null && it.tripId in linkedTripIds }
        val linked = linkedAllocations.mapNotNull { it.totalCost }.fold(BigDecimal.ZERO, BigDecimal::add)
        val material = if (includeMaterials) WorkTaskMaterialCosting.total(materials, task.id) else BigDecimal.ZERO
        val allocatedTripIds = linkedAllocations.mapTo(mutableSetOf()) { it.tripId }
        val linkedTripsComplete = linkedTripIds.all { it in allocatedTripIds } && linkedAllocations.all { it.totalCost != null }
        val complete = labourComplete && linkedTripsComplete

        return WorkTaskCostRollupResult(
            labourCost = labour.money(),
            manualMachineCost = machine.money(),
            linkedTripCost = linked.money(),
            materialCost = material.money(),
            totalCost = labour.add(machine).add(linked).add(material).money(),
            isComplete = complete,
        )
    }

    fun seasonTotal(
        tasks: List<WorkTask>,
        labourLines: List<WorkTaskLabourLine>,
        machineLines: List<WorkTaskMachineLine>,
        trips: List<Trip>,
        tripCostAllocations: List<TripCostAllocation>,
        materials: List<WorkTaskMaterial>,
        includeMaterials: Boolean,
    ): WorkTaskCostRollupResult {
        val results = tasks.map { resolve(it, labourLines, machineLines, trips, tripCostAllocations, materials, includeMaterials) }
        return WorkTaskCostRollupResult(
            labourCost = results.sumOf { it.labourCost }.money(),
            manualMachineCost = results.sumOf { it.manualMachineCost }.money(),
            linkedTripCost = results.sumOf { it.linkedTripCost }.money(),
            materialCost = results.sumOf { it.materialCost }.money(),
            totalCost = results.sumOf { it.totalCost }.money(),
            isComplete = results.all { it.isComplete },
        )
    }

    private fun BigDecimal.money(): BigDecimal = setScale(2, RoundingMode.HALF_UP)
}
