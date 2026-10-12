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
) {
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
    fun blocker(snapshot: SprayApplicationSnapshot?, tanks: List<com.rork.vinetrack.data.model.SprayTank>): String? = blocker(
        snapshot?.planningIntent != null || snapshot?.planningResolution != null,
        tanks.firstOrNull { !it.concentrationFactor.isFinite() }?.concentrationFactor
            ?: (tanks.map { it.concentrationFactor } + listOfNotNull(snapshot?.concentrationFactor)).maxOrNull(),
        tanks.any { tank -> tank.chemicals.any { chemical ->
            chemical.rateBasis == SprayProductRateBasis.PER_100_LITRES.raw ||
                (chemical.rateBasis == null && chemical.ratePer100L > 0 && chemical.ratePerHa <= 0)
        } },
    )
    fun blocker(hasPlanningIntent: Boolean, concentrationFactor: Double?, hasDiluteRateProducts: Boolean): String? {
        if (hasDiluteRateProducts && concentrationFactor != null && (!concentrationFactor.isFinite() || concentrationFactor > 1.000001)) return CONCENTRATE_MESSAGE
        return if (hasPlanningIntent) MIGRATION_MESSAGE else null
    }
}
