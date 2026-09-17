package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Paddock

/** Pure EL4-to-budburst reconciliation shared by online, offline and relaunch paths. */
object BudburstReconciler {
    data class Update(val paddockId: String, val observationId: String, val localDate: String)

    fun missingBudburstUpdates(
        paddocks: List<Paddock>,
        observations: List<GrowthStageRecord>,
    ): List<Update> {
        val missing = paddocks.filter { it.budburstDate.isNullOrBlank() }.associateBy { it.id }
        return observations
            .asSequence()
            .filter { it.deletedAt == null }
            .filter { it.stageCode.equals(GrowthStage.BUDBURST_CODE, ignoreCase = true) }
            .filter { !it.paddockId.isNullOrBlank() && missing.containsKey(it.paddockId) }
            .mapNotNull { record ->
                val date = record.observedAt?.takeIf { it.length >= 10 }?.substring(0, 10) ?: return@mapNotNull null
                Update(requireNotNull(record.paddockId), record.id, date)
            }
            .groupBy { it.paddockId }
            .mapNotNull { (_, values) -> values.minByOrNull { it.localDate } }
    }
}
