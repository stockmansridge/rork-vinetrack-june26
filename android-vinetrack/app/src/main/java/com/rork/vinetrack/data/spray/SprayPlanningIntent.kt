package com.rork.vinetrack.data.spray

import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName

/** Declared complete-row equivalents per travel pass; never changes vineyard spacing. */
@Serializable
enum class SprayPassConfiguration(val title: String, val rowEquivalents: Double) {
    @SerialName("standard_pass") STANDARD_PASS("Standard Pass", 1.0),
    @SerialName("over_row_two_rows") OVER_ROW("Over-Row", 2.0),
}

@Serializable
enum class SprayPlanningMethod(val title: String) {
    @SerialName("by_area") BY_AREA("By Area"),
    @SerialName("full_tank") FULL_TANK("Full Tank"),
}

@Serializable
enum class SprayFullTankSpecification(val title: String) {
    @SerialName("target_area") TARGET_AREA("Target area"),
    @SerialName("calibrated_rate") CALIBRATED_RATE("Calibrated rate"),
}

/** Nullable local provenance. Null historical intent is never defaulted on decode. */
@Serializable
data class SprayPlanningIntent(
    val configuration: SprayPassConfiguration? = null,
    val method: SprayPlanningMethod? = null,
    val fullTankSpecification: SprayFullTankSpecification? = null,
    val intendedTankLitres: Double? = null,
    val targetAreaHa: Double? = null,
    val calibratedLitresPerHectare: Double? = null,
    val inputProvenance: SprayPlanningInputProvenance? = null,
) {
    /** Execution-only completeness boundary; do not apply to historical records or editable drafts. */
    fun fullTankExecutionBlocker(resolution: SprayPlanningResolution?, selectedGrossAreaHa: Double?): String? {
        if (method != SprayPlanningMethod.FULL_TANK) return null
        val message = "Full Tank plan is incomplete or inconsistent. Recalculate before saving or starting."
        val pass = configuration ?: return message
        val tank = intendedTankLitres?.takeIf { it.isFinite() && it > 0 } ?: return message
        val resolved = resolution ?: return message
        val gross = selectedGrossAreaHa?.takeIf { it.isFinite() && it > 0 } ?: return message
        fun matches(a: Double, b: Double): Boolean = a.isFinite() && b.isFinite() &&
            kotlin.math.abs(a - b) <= maxOf(0.000001, maxOf(kotlin.math.abs(a), kotlin.math.abs(b)) * 0.00000001)
        if (!resolved.plannedAreaHa.isFinite() || resolved.plannedAreaHa <= 0 ||
            resolved.plannedAreaHa > gross + maxOf(0.000001, gross * 0.00000001) ||
            !resolved.litresPerHectare.isFinite() || resolved.litresPerHectare <= 0 ||
            !matches(tank, resolved.intendedLitres) || !matches(tank, resolved.plannedAreaHa * resolved.litresPerHectare)) return message
        when (fullTankSpecification) {
            SprayFullTankSpecification.TARGET_AREA -> if (targetAreaHa == null || targetAreaHa <= 0 || !matches(targetAreaHa, resolved.plannedAreaHa)) return message
            SprayFullTankSpecification.CALIBRATED_RATE -> if (calibratedLitresPerHectare == null || calibratedLitresPerHectare <= 0 || !matches(calibratedLitresPerHectare, resolved.litresPerHectare)) return message
            null -> return message
        }
        if (resolved.physicalRowLitresPer100m != null && resolved.controllerLitresPer100mTravel != null &&
            !matches(resolved.controllerLitresPer100mTravel, resolved.physicalRowLitresPer100m * pass.rowEquivalents)) return message
        return null
    }

    fun resolve(selectedAreaHa: Double, physicalRowSpacingMetres: Double?, diluteLitresPerHectare: Double?): SprayPlanningResolution? {
        val pass = configuration ?: return null
        val planning = method ?: return null
        if (!selectedAreaHa.isFinite() || selectedAreaHa <= 0) return null
        val litres: Double
        val area: Double
        val rate: Double
        if (planning == SprayPlanningMethod.FULL_TANK) {
            val tank = intendedTankLitres?.takeIf { it.isFinite() && it > 0 } ?: return null
            litres = tank
            when (fullTankSpecification) {
                SprayFullTankSpecification.TARGET_AREA -> {
                    area = targetAreaHa?.takeIf { it.isFinite() && it > 0 && it <= selectedAreaHa } ?: return null
                    rate = tank / area
                }
                SprayFullTankSpecification.CALIBRATED_RATE -> {
                    rate = calibratedLitresPerHectare?.takeIf { it.isFinite() && it > 0 } ?: return null
                    area = tank / rate
                    if (area > selectedAreaHa) return null
                }
                null -> return null
            }
        } else {
            rate = calibratedLitresPerHectare?.takeIf { it.isFinite() && it > 0 } ?: return null
            area = selectedAreaHa
            litres = area * rate
        }
        if (!litres.isFinite() || !area.isFinite() || !rate.isFinite()) return null
        val spacing = physicalRowSpacingMetres?.takeIf { it.isFinite() && it > 0 }
        val physicalRate = spacing?.let { rate * it / 100.0 }
        val dilute = diluteLitresPerHectare?.takeIf { it.isFinite() && it > 0 }
        return SprayPlanningResolution(
            intendedLitres = litres, plannedAreaHa = area, litresPerHectare = rate,
            physicalRowLitresPer100m = physicalRate,
            controllerLitresPer100mTravel = physicalRate?.times(pass.rowEquivalents),
            effectiveWorkingWidthMetres = spacing?.times(pass.rowEquivalents),
            concentrationFactor = if (dilute == null) 1.0 else maxOf(1.0, dilute / rate),
        )
    }
}

/** Frozen selected-unit typing, independent of the canonical calculation. */
@Serializable
data class SprayPlanningInputProvenance(
    val tankText: String,
    val areaText: String,
    val rateText: String,
    val volumeUnit: String,
    val areaUnit: String,
    val rateAreaUnit: String,
    val countryCode: String,
)

@Serializable
data class SprayPlanningResolution(
    val intendedLitres: Double,
    val plannedAreaHa: Double,
    val litresPerHectare: Double,
    val physicalRowLitresPer100m: Double?,
    val controllerLitresPer100mTravel: Double?,
    val effectiveWorkingWidthMetres: Double?,
    val concentrationFactor: Double,
)

/** Fail closed; activation requires separately reviewed schema and workflow integration. */
object SprayPlanningOperationalGate {
    const val MIGRATION_MESSAGE = "Calculation preview only. New spray planning save/start and replay are disabled until the schema and operational workflows are approved and validated."
    const val CONCENTRATE_MESSAGE = "Concentrate spraying permission and limits are unverified for this dilute-rate mix. Save/start is blocked. A displayed CF is not label approval."
    fun blocker(snapshot: SprayApplicationSnapshot?, tanks: List<com.rork.vinetrack.data.model.SprayTank>): String? {
        if (snapshot?.planningResolution != null) {
            snapshot.planningIntent?.fullTankExecutionBlocker(snapshot.planningResolution, snapshot.grossAreaHa)?.let { return it }
        }
        for (tank in tanks) {
            val ambiguous = tank.chemicals.filter { it.rateBasis == null && it.ratePer100L > 0 && it.ratePerHa > 0 }
            if (ambiguous.isNotEmpty()) return CONCENTRATE_MESSAGE + " Ambiguous rate basis: " + ambiguous.joinToString(", ") { it.name }
            val dilute = tank.chemicals.filter { it.rateBasis == SprayProductRateBasis.PER_100_LITRES.raw ||
                (it.rateBasis == null && it.ratePer100L > 0) }
            blocker(false, tank.concentrationFactor, dilute.isNotEmpty(), dilute.map { it.name })?.let { return it }
        }
        return blocker(snapshot?.planningFieldsCleared == true || snapshot?.planningIntent != null || snapshot?.planningResolution != null, null, false)
    }
    fun blocker(hasPlanningIntent: Boolean, concentrationFactor: Double?, hasDiluteRateProducts: Boolean, chemicalNames: List<String> = emptyList()): String? {
        if (hasDiluteRateProducts && (concentrationFactor == null || !concentrationFactor.isFinite() || concentrationFactor < 1.0 || concentrationFactor > 1.000001)) {
            val names = chemicalNames.map { it.trim() }.filter { it.isNotEmpty() }.distinct().sorted()
            return if (names.isEmpty()) CONCENTRATE_MESSAGE else CONCENTRATE_MESSAGE + " Products: " + names.joinToString(", ")
        }
        return if (hasPlanningIntent) MIGRATION_MESSAGE else null
    }
}
