package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Exact shared JSON contract for one confirmed product quantity. */
@Serializable
data class SprayTankActualChemical(
    val id: String,
    val plannedChemicalId: String? = null,
    val savedChemicalId: String? = null,
    val name: String,
    val actualAmountBase: Double,
    val unit: String,
    val replacesPlannedChemicalId: String? = null,
    val usageKind: String? = null,
    val productCategory: String? = null,
    val physicalForm: String? = null,
    val snapshotAt: String? = null,
) {
    init {
        require(id.isNotBlank() && actualAmountBase.isFinite() && actualAmountBase >= 0.0)
        require(unit in setOf("Litres", "mL", "Kg", "g"))
    }
}

@Serializable
data class SprayTankActual(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("spray_record_id") val sprayRecordId: String,
    @SerialName("trip_id") val tripId: String,
    @SerialName("tank_session_id") val tankSessionId: String,
    @SerialName("tank_number") val tankNumber: Int,
    @SerialName("water_volume_l") val waterVolumeL: Double? = null,
    val chemicals: List<SprayTankActualChemical>,
    @SerialName("confirmed_at") val confirmedAt: String,
    @SerialName("confirmed_by") val confirmedBy: String,
    @SerialName("client_updated_at") val clientUpdatedAt: String = confirmedAt,
    @SerialName("correction_version") val correctionVersion: Long = 0,
    @SerialName("last_corrected_at") val lastCorrectedAt: String? = null,
) {
    init {
        require(tankSessionId.isNotBlank() && tankNumber >= 1)
        require(waterVolumeL == null || (waterVolumeL.isFinite() && waterVolumeL >= 0.0))
    }
}

/** Resolves one exact trip/spray/session actual and rejects ambiguous duplicate revisions. */
fun resolveSprayTankActual(
    plannedTank: SprayTank,
    actuals: List<SprayTankActual>,
    vineyardId: String,
    sprayRecordId: String,
    tripId: String,
    tankSessionIds: Set<String> = emptySet(),
): SprayTankActual? {
    if (tankSessionIds.isEmpty()) return null
    val scoped = actuals.filter { actual ->
        actual.vineyardId == vineyardId && actual.sprayRecordId == sprayRecordId &&
            actual.tripId == tripId && actual.tankNumber == plannedTank.tankNumber &&
            actual.tankSessionId in tankSessionIds
    }
    val bySession = scoped.groupBy { it.tankSessionId }
    if (bySession.size != 1) return null
    val revisions = bySession.values.single()
    val highestVersion = revisions.maxOfOrNull { it.correctionVersion } ?: return null
    val highest = revisions.filter { it.correctionVersion == highestVersion }
    return highest.singleOrNull()
}

/** True only when exact identity, water, and every planned or amended chemical result are unambiguous. */
fun areSprayTankActualsComplete(
    plannedTanks: List<SprayTank>,
    actuals: List<SprayTankActual>,
    vineyardId: String,
    sprayRecordId: String,
    tripId: String,
    tankSessionIdsByNumber: Map<Int, Set<String>> = emptyMap(),
): Boolean {
    if (plannedTanks.isEmpty()) return false
    val plannedNumbers = plannedTanks.mapTo(mutableSetOf()) { it.tankNumber }
    val scopedActuals = actuals.filter {
        it.vineyardId == vineyardId && it.sprayRecordId == sprayRecordId && it.tripId == tripId
    }
    if (scopedActuals.any { actual ->
            actual.tankNumber !in plannedNumbers ||
                actual.tankSessionId !in tankSessionIdsByNumber[actual.tankNumber].orEmpty()
        }) return false
    return plannedTanks.all { tank ->
        val actual = resolveSprayTankActual(
            tank, actuals, vineyardId, sprayRecordId, tripId,
            tankSessionIdsByNumber[tank.tankNumber].orEmpty(),
        ) ?: return@all false
        if (actual.waterVolumeL?.let { it.isFinite() && it >= 0.0 } != true) return@all false
        val plannedIds = tank.chemicals.mapTo(mutableSetOf()) { it.id }
        if (plannedIds.size != tank.chemicals.size || actual.chemicals.map { it.id }.toSet().size != actual.chemicals.size) return@all false
        val validAssociations = actual.chemicals.all { line ->
            if (!line.actualAmountBase.isFinite() || line.actualAmountBase < 0.0) return@all false
            when (line.usageKind ?: "planned") {
                "planned" -> line.plannedChemicalId in plannedIds && line.replacesPlannedChemicalId == null
                "additional" -> line.plannedChemicalId == null && line.replacesPlannedChemicalId == null
                "substitution" -> line.plannedChemicalId == null && line.replacesPlannedChemicalId in plannedIds
                else -> false
            }
        }
        validAssociations && tank.chemicals.all { planned ->
            val direct = actual.chemicals.filter { (it.usageKind ?: "planned") == "planned" && it.plannedChemicalId == planned.id }
            val substitutes = actual.chemicals.filter { it.usageKind == "substitution" && it.replacesPlannedChemicalId == planned.id }
            when {
                substitutes.size == 1 -> direct.size <= 1 && direct.all { it.actualAmountBase == 0.0 }
                substitutes.isEmpty() -> direct.size == 1
                else -> false
            }
        }
    }
}
