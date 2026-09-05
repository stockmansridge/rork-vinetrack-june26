package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.CanopyWaterRates
import com.rork.vinetrack.data.SprayCalculator
import kotlin.math.max

/** The confirmed canopy's dilute/runoff recommendation at CF 1.00. */
data class SprayCanopyRecommendation(
    val type: SprayCalculator.CanopyType,
    val size: SprayCalculator.CanopySize,
    val density: SprayCalculator.CanopyDensity,
    val diluteLitresPer100Metres: Double,
    val rowSpacingMetres: Double?,
) {
    val diluteLitresPerHectare: Double?
        get() = SprayCarrierConversion.litresPerHectare(
            litresPer100Metres = diluteLitresPer100Metres,
            rowSpacingMetres = rowSpacingMetres,
        )
}

/** No spray output is assumed before the operator answers. */
enum class SprayVolumeChoice {
    UNDECIDED,
    USE_RECOMMENDED,
    USE_CUSTOM_SPRAYER_RATE,
}

/** One recommended-versus-actual decision shared by both foliar carrier displays. */
data class SprayVolumeDecision(
    val recommendation: SprayCanopyRecommendation?,
    val choice: SprayVolumeChoice,
    val customRate: Double?,
    val customBasis: SprayCarrierBasis,
) {
    val recommendedLitresPer100Metres: Double? get() = recommendation?.diluteLitresPer100Metres
    val recommendedLitresPerHectare: Double? get() = recommendation?.diluteLitresPerHectare

    val actualLitresPerHectare: Double?
        get() = when (choice) {
            SprayVolumeChoice.UNDECIDED -> null
            SprayVolumeChoice.USE_RECOMMENDED -> recommendedLitresPerHectare
            SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE -> when (customBasis) {
                SprayCarrierBasis.LITRES_PER_HECTARE -> SprayCarrierConversion.positive(customRate)
                SprayCarrierBasis.LITRES_PER_100_METRES -> SprayCarrierConversion.litresPerHectare(
                    litresPer100Metres = customRate,
                    rowSpacingMetres = recommendation?.rowSpacingMetres,
                )
            }
        }

    val actualLitresPer100Metres: Double?
        get() = when (choice) {
            SprayVolumeChoice.UNDECIDED -> null
            SprayVolumeChoice.USE_RECOMMENDED -> recommendedLitresPer100Metres
            SprayVolumeChoice.USE_CUSTOM_SPRAYER_RATE -> when (customBasis) {
                SprayCarrierBasis.LITRES_PER_100_METRES -> SprayCarrierConversion.positive(customRate)
                SprayCarrierBasis.LITRES_PER_HECTARE -> SprayCarrierConversion.litresPer100Metres(
                    litresPerHectare = customRate,
                    rowSpacingMetres = recommendation?.rowSpacingMetres,
                )
            }
        }

    val concentrationFactor: Double
        get() {
            val recommendedHa = recommendedLitresPerHectare
            val actualHa = actualLitresPerHectare
            if (recommendedHa != null && actualHa != null) {
                return SprayCarrierConversion.concentrationFactor(recommendedHa, actualHa)
            }
            return SprayCarrierConversion.concentrationFactor(
                recommendedLitresPer100Metres,
                actualLitresPer100Metres,
            )
        }

    val hasComparableRates: Boolean
        get() = (recommendedLitresPerHectare != null && actualLitresPerHectare != null) ||
            (recommendedLitresPer100Metres != null && actualLitresPer100Metres != null)

    val isResolved: Boolean get() =
        (actualLitresPerHectare != null || actualLitresPer100Metres != null) && hasComparableRates
}

/** Canonical carrier-rate conversions. No row spacing is ever guessed. */
object SprayCarrierConversion {
    fun positive(value: Double?): Double? = value?.takeIf { it.isFinite() && it > 0.0 }

    fun litresPerHectare(litresPer100Metres: Double?, rowSpacingMetres: Double?): Double? {
        val rate = positive(litresPer100Metres) ?: return null
        val spacing = positive(rowSpacingMetres) ?: return null
        return rate * 100.0 / spacing
    }

    fun litresPer100Metres(litresPerHectare: Double?, rowSpacingMetres: Double?): Double? {
        val rate = positive(litresPerHectare) ?: return null
        val spacing = positive(rowSpacingMetres) ?: return null
        return rate * spacing / 100.0
    }

    fun concentrationFactor(dilute: Double?, actual: Double?): Double {
        val diluteRate = positive(dilute) ?: return 1.0
        val actualRate = positive(actual) ?: return 1.0
        return max(1.0, diluteRate / actualRate)
    }
}

object SprayVolumeDecisionResolver {
    fun recommendation(
        canopy: SprayCanopySelection,
        isCanopyConfirmed: Boolean,
        rates: CanopyWaterRates,
        rowSpacingMetres: Double?,
    ): SprayCanopyRecommendation? {
        val type = canopy.type ?: return null
        if (!isCanopyConfirmed) return null
        return SprayCanopyRecommendation(
            type = type,
            size = canopy.size,
            density = canopy.density,
            diluteLitresPer100Metres = SprayCalculator.litresPer100m(rates, type, canopy.size, canopy.density),
            rowSpacingMetres = SprayCarrierConversion.positive(rowSpacingMetres),
        )
    }

    fun decide(
        canopy: SprayCanopySelection,
        isCanopyConfirmed: Boolean,
        rates: CanopyWaterRates,
        rowSpacingMetres: Double?,
        choice: SprayVolumeChoice,
        customRate: Double?,
        customBasis: SprayCarrierBasis,
    ): SprayVolumeDecision = SprayVolumeDecision(
        recommendation = recommendation(canopy, isCanopyConfirmed, rates, rowSpacingMetres),
        choice = choice,
        customRate = customRate,
        customBasis = customBasis,
    )
}

object SprayVolumeHelp {
    const val RECOMMENDED_VOLUME: String = "This is VineTrack's estimated dilute spray volume for the selected canopy at a concentration factor of 1.00."
    const val ACTUAL_SPRAYER_OUTPUT: String = "Enter the water/carrier rate your sprayer is calibrated to apply. This is your machine's spray volume, not the chemical label rate."
    const val ROW_SPACING_REQUIRED: String = "A matching row spacing across the selected blocks is required to show or use the equivalent rate."
}
