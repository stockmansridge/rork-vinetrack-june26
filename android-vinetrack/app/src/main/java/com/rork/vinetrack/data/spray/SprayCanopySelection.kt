package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.CanopyWaterRates
import com.rork.vinetrack.data.SprayCalculator

/** Deliberate canopy answer shared by both foliar carrier bases. */
data class SprayCanopySelection(
    val type: SprayCalculator.CanopyType? = null,
    val size: SprayCalculator.CanopySize = SprayCalculator.CanopySize.MEDIUM,
    val density: SprayCalculator.CanopyDensity = SprayCalculator.CanopyDensity.LOW,
    val confirmedSignature: String? = null,
) {
    val isValid: Boolean get() = type != null

    fun chooseType(value: SprayCalculator.CanopyType?): SprayCanopySelection =
        copy(type = value, confirmedSignature = null)

    fun chooseSize(value: SprayCalculator.CanopySize): SprayCanopySelection =
        copy(size = value, confirmedSignature = null)

    fun chooseDensity(value: SprayCalculator.CanopyDensity): SprayCanopySelection =
        copy(density = value, confirmedSignature = null)

    fun signature(selectedBlockIds: List<String>, carrierBasis: SprayCarrierBasis): String = listOf(
        type?.name ?: "unselected",
        size.name,
        density.name,
        selectedBlockIds.sorted().joinToString(","),
        carrierBasis.name,
    ).joinToString("|")

    fun confirm(selectedBlockIds: List<String>, carrierBasis: SprayCarrierBasis): SprayCanopySelection =
        if (!isValid) this else copy(confirmedSignature = signature(selectedBlockIds, carrierBasis))

    fun isConfirmed(selectedBlockIds: List<String>, carrierBasis: SprayCarrierBasis): Boolean =
        isValid && confirmedSignature == signature(selectedBlockIds, carrierBasis)

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

        /** Historical Program Step fields came from the old VSP-only controls. */
        fun prefilledVsp(
            size: SprayCalculator.CanopySize,
            density: SprayCalculator.CanopyDensity,
        ): SprayCanopySelection = SprayCanopySelection(
            type = SprayCalculator.CanopyType.VSP,
            size = size,
            density = density,
            confirmedSignature = null,
        )
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
