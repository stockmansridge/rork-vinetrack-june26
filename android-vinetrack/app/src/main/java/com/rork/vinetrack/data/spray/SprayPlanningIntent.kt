package com.rork.vinetrack.data.spray

import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName

/** Declared complete-row equivalents per travel pass; never changes vineyard spacing. */
@Serializable
enum class SprayPassConfiguration(val title: String, val rowEquivalents: Double) {
    @SerialName("standard_pass") STANDARD_PASS("Single Row", 1.0),
    @SerialName("over_row_two_rows") OVER_ROW("Over-Row", 2.0),
}

@Serializable
enum class SprayPlanningMethod(val title: String) {
    @SerialName("by_area") BY_AREA("By Area"),
    @SerialName("full_tank") FULL_TANK("Only Full Tanks"),
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
        val message = "Only Full Tanks plan is incomplete or inconsistent. Recalculate before saving or starting."
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

    /** Validate frozen outputs without recalculating quantities or granting operational authority. */
    fun frozenResolutionBlocker(resolution: SprayPlanningResolution): String? {
        val message = "Spray planning outputs are incomplete or inconsistent. Recalculate before saving or starting."
        val pass = configuration ?: return message
        if (method == null) return message
        if (listOf(resolution.intendedLitres, resolution.plannedAreaHa, resolution.litresPerHectare)
                .any { !it.isFinite() || it <= 0 }) return message
        val geometry = listOf(resolution.physicalRowLitresPer100m, resolution.controllerLitresPer100mTravel, resolution.effectiveWorkingWidthMetres)
        if (geometry.any { it != null } && geometry.any { it == null || !it.isFinite() || it <= 0 }) return message
        fun matches(a: Double, b: Double): Boolean = a.isFinite() && b.isFinite() &&
            kotlin.math.abs(a - b) <= maxOf(0.000001, maxOf(kotlin.math.abs(a), kotlin.math.abs(b)) * 0.00000001)
        resolution.physicalRowLitresPer100m?.let { physical ->
            if (!matches(resolution.controllerLitresPer100mTravel!!, physical * pass.rowEquivalents) ||
                !matches(resolution.controllerLitresPer100mTravel, resolution.litresPerHectare * resolution.effectiveWorkingWidthMetres!! / 100)) return message
        }
        // By Area may use measured row length for carrier total; do not replace it with gross-area arithmetic.
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
        return SprayPlanningResolution(
            intendedLitres = litres, plannedAreaHa = area, litresPerHectare = rate,
            physicalRowLitresPer100m = physicalRate,
            controllerLitresPer100mTravel = physicalRate?.times(pass.rowEquivalents),
            effectiveWorkingWidthMetres = spacing?.times(pass.rowEquivalents),
            concentrationFactor = SprayCarrierConversion.concentrationFactor(diluteLitresPerHectare, rate),
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
    /** Delayed confirmation cannot execute an earlier recipe with the same record ID. */
    fun tankConfirmationBlocker(current: com.rork.vinetrack.data.model.SprayRecord?, captured: com.rork.vinetrack.data.model.SprayRecord): String? {
        if (current == null || current != captured) return "The planned mix changed while this tank was open. Reopen Start Tank and confirm again."
        return blocker(current.applicationGeometry, current.tanks.orEmpty())
    }
    const val MIGRATION_MESSAGE = "Calculation preview only. New spray planning save/start and replay are disabled until the schema and operational workflows are approved and validated."
    const val WARNING_TITLE = "Concentration / Label Warning"
    const val WARNING_MESSAGE = "VineTrack has calculated the chemical concentration factor (CF), but concentrate-spraying permission and applicable limits have not been verified against the product label.\n\nFor new calculations CF is at least 1.00, calculated from valid recommended and actual volumes when available. Missing or invalid CF uses the applicable 1.00 baseline. This information never prevents Start Spray, Save for Later or Tank Mixing.\n\nA calculated CF does not confirm label approval. Check the relevant product labels and application directions before spraying."

    /** Advisory only; never feeds operational readiness or write admission. */
    fun warningProducts(names: List<String>): List<String> = names.map { it.trim() }.filter { it.isNotEmpty() }.distinct().sorted()
    fun blocker(snapshot: SprayApplicationSnapshot?, tanks: List<com.rork.vinetrack.data.model.SprayTank>): String? {
        if (snapshot?.planningResolution != null) {
            snapshot.planningIntent?.frozenResolutionBlocker(snapshot.planningResolution)?.let { return it }
            snapshot.planningIntent?.fullTankExecutionBlocker(snapshot.planningResolution, snapshot.grossAreaHa)?.let { return it }
        }
        for (tank in tanks) {
            val ambiguous = tank.chemicals.filter { it.rateBasis == null && it.ratePer100L > 0 && it.ratePerHa > 0 }
            if (ambiguous.isNotEmpty()) return "Choose an explicit rate basis before saving or starting. Ambiguous rate basis: " + ambiguous.joinToString(", ") { it.name }
        }
        return LegacySpraySetup.blocker(snapshot?.planningIntent, snapshot?.planningResolution, snapshot?.planningFieldsCleared == true)
    }
    fun blocker(hasPlanningIntent: Boolean, concentrationFactor: Double?, hasDiluteRateProducts: Boolean, chemicalNames: List<String> = emptyList()): String? {
        // CF and label uncertainty are advisory, independent of planning-contract admission.
        return if (hasPlanningIntent) MIGRATION_MESSAGE else null
    }
}
