package com.rork.vinetrack.data.model

import java.math.BigDecimal
import java.math.MathContext

/** Read-only costing boundaries; fallback hectares and reconciled rows are never persisted. */
object CostingReadAuthority {
    fun positive(area: Double?): Double? = area?.takeIf { it.isFinite() && it > 0 }
    fun physicalArea(block: Paddock): Double? = positive(block.savedAreaHa) ?: positive(block.areaHectares)
    fun physicalArea(blocks: List<Paddock>): Double? {
        val unique = blocks.filter { it.deletedAt == null }.distinctBy { it.id }
        if (unique.isEmpty()) return null
        val areas = unique.mapNotNull { physicalArea(it) }
        return if (areas.size == unique.size) areas.sum() else null
    }
    fun taskArea(task: WorkTask, links: List<WorkTaskPaddock>, blocks: List<Paddock>): Double? {
        positive(task.areaHa)?.let { return it }
        val linked = links.filter { it.workTaskId == task.id && it.vineyardId == task.vineyardId && it.deletedAt == null }.distinctBy { it.paddockId }
        if (linked.isNotEmpty() && linked.all { positive(it.areaHa) != null }) return linked.sumOf { it.areaHa!! }
        val ids = if (linked.isEmpty()) setOfNotNull(task.paddockId) else linked.map { it.paddockId }.toSet()
        if (ids.isEmpty()) return null
        val selected = blocks.filter { it.id in ids && it.vineyardId == task.vineyardId && it.deletedAt == null }
        if (selected.map { it.id }.toSet() != ids) return null
        return physicalArea(selected)
    }
    fun allocations(rows: List<TripCostAllocation>, trips: List<Trip>): List<TripCostAllocation> {
        val parents = trips.filter { it.deletedAt == null }.associate { it.id to it.vineyardId }
        return rows.filter { it.deletedAt == null && parents[it.tripId] == it.vineyardId }.distinctBy { it.id }
            .groupBy { it.tripId }.values.flatMap { group ->
                val markers = group.filter { it.allocationBasis == "labour_snapshot" }
                val slices = group.filter { it.allocationBasis != "labour_snapshot" }
                val marker = markers.firstOrNull()
                if (marker == null) slices else if (slices.isEmpty()) markers else {
                    val labour = slices.mapNotNull { it.labourCost }.fold(BigDecimal.ZERO, BigDecimal::add)
                    val area = slices.sumOf { it.allocationAreaHa ?: 0.0 }
                    slices.map { row ->
                        val share = when {
                            labour > BigDecimal.ZERO -> (row.labourCost ?: BigDecimal.ZERO).divide(labour, MathContext.DECIMAL128)
                            area > 0 -> BigDecimal.valueOf((row.allocationAreaHa ?: 0.0) / area)
                            else -> BigDecimal.ONE.divide(BigDecimal(slices.size), MathContext.DECIMAL128)
                        }
                        val snapshot = marker.totalCost ?: marker.labourCost
                        row.copy(
                            labourCostRaw = snapshot?.multiply(share)?.toPlainString(),
                            totalCostRaw = row.totalCost?.let { total -> snapshot?.let { total - (row.labourCost ?: BigDecimal.ZERO) + it * share } }?.toPlainString(),
                            costingStatus = if (marker.costingStatus in listOf("partial", "unavailable") || markers.size != 1) "partial" else row.costingStatus,
                        )
                    }
                }
            }
    }
    fun distinctTrips(rows: List<TripCostAllocation>): Int = rows.map { it.tripId }.toSet().size
    fun machineComplete(line: WorkTaskMachineLine): Boolean {
        val machineOK = line.totalMachineCost?.isFinite() ?: (line.hourlyMachineRate == null)
        val fuelOK = line.fuelCost?.isFinite() ?: (line.fuelLitres == null || line.fuelLitres == 0.0)
        return (line.totalMachineCost != null || line.fuelCost != null) && machineOK && fuelOK
    }
}
