package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.parseIsoToEpochMs
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import java.time.ZoneId

/** Canonical current-season observation for one block and variety. */
data class DiseaseBlockStage(
    val vineyardId: String,
    val paddockId: String?,
    val variety: String?,
    val stageCode: String,
    val stageLabel: String?,
    val observedAt: Long,
    val el: Int,
)

/**
 * Operational advisory, NOT an infection model or spray recommendation.
 * Exact parity with iOS DiseaseGrowthStagePolicy: inclusive E-L intervals,
 * one-tier reduction outside them, never an increase in weather pressure.
 */
object DiseaseGrowthStagePolicy {
    fun resolve(
        records: List<GrowthStageRecord>, vineyardId: String, season: SeasonWindow,
        zone: ZoneId, now: Long, pendingDeleteIds: Set<String> = emptySet(),
    ): List<DiseaseBlockStage> {
        val latest = mutableMapOf<String, Pair<GrowthStageRecord, Long>>()
        records.forEach { record ->
            if (record.vineyardId != vineyardId || record.deletedAt != null || record.id in pendingDeleteIds) return@forEach
            // Do not use the model's observedEpochMs fallback to created_at here.
            val observed = parseIsoToEpochMs(record.observedAt) ?: return@forEach
            if (observed > now || !season.containsEpochMs(observed, zone)) return@forEach
            val el = ElRipenessHeatmap.parseElStage(record.stageCode) ?: return@forEach
            if (el != el.toInt().toDouble()) return@forEach
            val key = "${record.paddockId ?: "unassigned"}|${record.varietyId ?: record.variety?.trim()?.lowercase().orEmpty()}"
            val previous = latest[key]
            if (previous == null || observed > previous.second ||
                (observed == previous.second && record.id > previous.first.id)) latest[key] = record to observed
        }
        return latest.values.mapNotNull { (record, observed) ->
            val el = ElRipenessHeatmap.parseElStage(record.stageCode) ?: return@mapNotNull null
            DiseaseBlockStage(record.vineyardId, record.paddockId, record.variety,
                record.stageCode, record.stageLabel, observed, el.toInt())
        }.sortedWith(compareBy({ it.paddockId.orEmpty() }, { it.variety.orEmpty() }, { it.stageCode }))
    }

    fun stageText(stages: List<DiseaseBlockStage>): String {
        val low = stages.minOfOrNull { it.el } ?: return "No current-season observation"
        val high = stages.maxOf { it.el }
        return if (low == high) "EL$low" else "EL$low–EL$high"
    }

    /** Highest remaining pressure across observed blocks; latest known stage held fixed through the 7-day window. */
    fun adjust(base: DiseaseRiskAssessment, stages: List<DiseaseBlockStage>): DiseaseRiskAssessment {
        if (stages.isEmpty() || base.summary == "Insufficient hourly data to assess.") return base
        val final = stages.maxOf { stage ->
            if (susceptible(base.model, stage.el)) base.severity else reduced(base.severity)
        }
        return base.copy(severity = final)
    }

    fun changed(base: DiseaseRiskAssessment, final: DiseaseRiskAssessment): Boolean = base.severity != final.severity

    private fun susceptible(model: DiseaseModel, el: Int): Boolean = when (model) {
        DiseaseModel.DOWNY_MILDEW -> el in 12..33
        DiseaseModel.POWDERY_MILDEW -> el in 12..33
        DiseaseModel.BOTRYTIS -> el in 19..25 || el in 33..47
    }

    private fun reduced(severity: DiseaseSeverity): DiseaseSeverity = when (severity) {
        DiseaseSeverity.HIGH -> DiseaseSeverity.MEDIUM
        DiseaseSeverity.MEDIUM -> DiseaseSeverity.LOW
        DiseaseSeverity.LOW -> DiseaseSeverity.LOW
    }
}
