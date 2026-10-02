package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.SeasonWindow
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayStatus
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.sprayRecordStatus
import java.time.ZoneId
import java.util.Locale

/** No fuzzy matching and no generated operational records. */
object SprayProgramProgression {
    private val stagePattern = Regex("""(?i)(?<![a-z0-9])e-?l[\s.\-]*(?:stage\s*)?([0-9]{1,3})(?![0-9])""")
    fun stage(record: SprayRecord): Int? {
        val number = record.templateGrowthStageCode?.let { stagePattern.find(it)?.groupValues?.get(1)?.toIntOrNull() }
            ?: stagePattern.find("${record.displayLabel} ${record.notes.orEmpty()}")?.groupValues?.get(1)?.toIntOrNull()
        return number?.takeIf { GrowthStage.byCode("EL$it") != null }
    }
    fun normalizedName(name: String): String = stagePattern.replace(name, "")
        .lowercase(Locale.ROOT).split(Regex("[^\\p{L}\\p{N}]+"))
        .filter { it.isNotEmpty() }.joinToString(" ")

    fun completed(records: List<SprayRecord>, trips: List<Trip>, vineyardId: String?, window: SeasonWindow, zone: ZoneId): List<SprayRecord> =
        SprayProgramLanding.uniqueOperational(records).filter {
            it.deletedAt == null && it.vineyardId == vineyardId &&
                window.containsEpochMs(SeasonWindow.epochMsOf(it.date ?: it.startTime, zone), zone) &&
                sprayRecordStatus(it, trips) == SprayStatus.COMPLETED
        }

    fun remaining(steps: List<SprayRecord>, completed: List<SprayRecord>): List<SprayRecord> {
        val highest = completed.mapNotNull { record ->
            record.sprayJobId?.let { id -> steps.firstOrNull { it.id == id }?.let(::stage) } ?: stage(record)
        }.maxOrNull()
        val remaining = steps.filter { step ->
            val stepStage = stage(step)
            if (highest == null) true
            else if (stepStage != null && stepStage < highest) false
            else !completed.any { record ->
                if (record.sprayJobId != null) record.sprayJobId == step.id
                else stepStage != null && stage(record) == stepStage && normalizedName(step.displayLabel).isNotEmpty() &&
                    normalizedName(record.displayLabel) == normalizedName(step.displayLabel)
            }
        }
        return remaining.sortedWith(compareBy<SprayRecord> { stage(it) ?: Int.MAX_VALUE }
            .thenBy { normalizedName(it.displayLabel) }.thenBy { it.id })
    }
}
