package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.RegionalInput

/** Regional presentation/input boundary for carrier water and geometry, never chemical label rates. */
class SprayCarrierRegionalFormat(val formatter: RegionFormatter) {
    private fun display(value: Double?, format: (Double) -> String): String =
        value?.takeIf { it.isFinite() }?.let(format) ?: "—"

    fun hectares(value: Double?): String = display(value) { formatter.formatArea(it) }
    fun metres(value: Double?, decimals: Int = 0): String = display(value) { formatter.formatLength(it, decimals) }
    fun litres(value: Double?): String = display(value) { formatter.formatVolume(it) }
    fun litresPerHectare(value: Double?): String = display(value) { formatter.formatVolumePerArea(it, 2) }
    fun litresPer100m(value: Double?): String = display(value) { formatter.formatVolumePer100Length(it) }
    fun carrierBasisLabel(basis: SprayCarrierBasis): String = when (basis) {
        SprayCarrierBasis.LITRES_PER_HECTARE -> formatter.volumePerAreaUnit
        SprayCarrierBasis.LITRES_PER_100_METRES -> formatter.volumePer100LengthUnit
        SprayCarrierBasis.MANUAL_TOTAL_VOLUME -> "Manual total water"
    }
    fun rateInput(value: Double?, basis: SprayCarrierBasis): RegionalInput = RegionalInput.seed(value) {
        when (basis) {
            SprayCarrierBasis.LITRES_PER_HECTARE -> formatter.volumePerAreaValue(it)
            SprayCarrierBasis.LITRES_PER_100_METRES -> formatter.volumePer100LengthValue(it)
            SprayCarrierBasis.MANUAL_TOTAL_VOLUME -> formatter.volumeValue(it)
        }
    }
    fun resolveRate(text: String, basis: SprayCarrierBasis, seed: RegionalInput = rateInput(null, basis)): Double? =
        seed.resolve(text) {
            when (basis) {
                SprayCarrierBasis.LITRES_PER_HECTARE -> formatter.volumePerAreaToCanonical(it)
                SprayCarrierBasis.LITRES_PER_100_METRES -> formatter.volumePer100LengthToCanonical(it)
                SprayCarrierBasis.MANUAL_TOTAL_VOLUME -> formatter.volumeToCanonical(it)
            }
        }
}
