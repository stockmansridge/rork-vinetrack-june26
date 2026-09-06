package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.CanopyWaterRates
import com.rork.vinetrack.data.SprayCalculator

/** Deliberate canopy answer shared by both foliar carrier bases. */
data class SprayCanopySelection(
    val type: SprayCalculator.CanopyType? = null,
    val size: SprayCalculator.CanopySize = SprayCalculator.CanopySize.MEDIUM,
    val density: SprayCalculator.CanopyDensity = SprayCalculator.CanopyDensity.LOW,
    val isSizeAndDensityConfirmed: Boolean = false,
) {
    val isValid: Boolean get() = type != null

    /** A complete answer needs a training system and a deliberately accepted size/density pair. */
    val isConfirmed: Boolean get() = isValid && isSizeAndDensityConfirmed

    /** Choosing or changing the training system does not alter confirmation of the displayed pair. */
    fun chooseType(value: SprayCalculator.CanopyType?): SprayCanopySelection = copy(type = value)

    /** Touching either pair control deliberately confirms both displayed values. */
    fun chooseSize(value: SprayCalculator.CanopySize): SprayCanopySelection =
        copy(size = value, isSizeAndDensityConfirmed = true)

    fun chooseDensity(value: SprayCalculator.CanopyDensity): SprayCanopySelection =
        copy(density = value, isSizeAndDensityConfirmed = true)

    /** Accepts the displayed pair unchanged; type is still independently required. */
    fun confirm(): SprayCanopySelection = copy(isSizeAndDensityConfirmed = true)

    fun litresPer100m(rates: CanopyWaterRates): Double? = type?.let {
        SprayCalculator.litresPer100m(rates, it, size, density)
    }

    fun referenceBand(rates: CanopyWaterRates): CanopyReferenceBand? = type?.let {
        CanopyReferenceBand(
            low = SprayCalculator.litresPer100m(rates, it, size, SprayCalculator.CanopyDensity.LOW),
            high = SprayCalculator.litresPer100m(rates, it, size, SprayCalculator.CanopyDensity.HIGH),
        )
    }

    companion object {
        val unconfirmed: SprayCanopySelection = SprayCanopySelection()

        /** Program/repeat values are already deliberate; legacy values without type were VSP-only. */
        fun prefilled(
            size: SprayCalculator.CanopySize,
            density: SprayCalculator.CanopyDensity,
            type: SprayCalculator.CanopyType = SprayCalculator.CanopyType.VSP,
        ): SprayCanopySelection = SprayCanopySelection(
            type = type,
            size = size,
            density = density,
            isSizeAndDensityConfirmed = true,
        )

        fun prefilledVsp(
            size: SprayCalculator.CanopySize,
            density: SprayCalculator.CanopyDensity,
        ): SprayCanopySelection = prefilled(size = size, density = density)
    }
}

data class CanopyReferenceBand(val low: Double, val high: Double)

/** Stable drawable names, mapped to packaged resources by the shared UI. */
object SprayCanopyReferenceImages {
    fun drawableName(type: SprayCalculator.CanopyType, size: SprayCalculator.CanopySize): String =
        "canopy_${type.name.lowercase()}_${size.name.lowercase()}"

    fun accessibilityDescription(
        type: SprayCalculator.CanopyType,
        size: SprayCalculator.CanopySize,
    ): String = "${type.label} ${size.label.lowercase()} canopy reference image"
}

/** Foliar alone requires canopy confirmation; banded and spreader remain unchanged. */
object SprayCanopyRequirement {
    fun requiresConfirmation(operationType: SprayOperationType): Boolean =
        operationType == SprayOperationType.FOLIAR_SPRAY

    fun usesSharedModel(carrierBasis: SprayCarrierBasis): Boolean = when (carrierBasis) {
        SprayCarrierBasis.LITRES_PER_100_METRES,
        SprayCarrierBasis.LITRES_PER_HECTARE -> true
    }
}
