package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.SprayCalculator
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Nullable canonical Program inputs. No calculation or confirmation is performed here. */
@Serializable
data class SprayProgramCalculatorInputs(
    @SerialName("vsp_canopy_size") val canopySize: String? = null,
    @SerialName("vsp_canopy_density") val canopyDensity: String? = null,
    @SerialName("carrier_volume_basis") val carrierBasis: String? = null,
    @SerialName("dilute_litres_per_100m") val diluteLitresPer100m: Double? = null,
    @SerialName("applied_litres_per_100m") val appliedLitresPer100m: Double? = null,
    @SerialName("band_width_total_metres") val bandWidthTotalMetres: Double? = null,
    @SerialName("row_spacing_metres") val rowSpacingMetres: Double? = null,
) {
    val canopy: SprayCanopySelection? get() {
        val size = SprayCalculator.CanopySize.entries.firstOrNull { it.label.equals(canopySize, true) }
        val density = SprayCalculator.CanopyDensity.entries.firstOrNull { it.label.equals(canopyDensity, true) }
        if (size == null && density == null) return null
        return SprayCanopySelection(type = SprayCalculator.CanopyType.VSP,
            size = size ?: SprayCalculator.CanopySize.MEDIUM,
            density = density ?: SprayCalculator.CanopyDensity.LOW)
    }
}
