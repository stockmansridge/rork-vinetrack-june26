package com.rork.vinetrack.data.spray

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.max

/**
 * How the operator expresses carrier (water) volume — the Kotlin twin of the
 * Swift `SprayCarrierBasis`.
 *
 * This is the SPRAY/CARRIER VOLUME BASIS and is completely independent of a
 * product's label rate basis ([SprayProductRateBasis]). A New Zealand vineyard
 * may enter carrier volume exclusively in L/100 m while still dosing a product
 * whose label is authoritative in L/ha.
 */
@Serializable
enum class SprayCarrierBasis(val raw: String) {
    /** Hectare-based carrier volume — the long-standing VineTrack behaviour. */
    @SerialName("l_per_ha")
    LITRES_PER_HECTARE("l_per_ha"),

    /** Row-length-based carrier volume — authoritative for NZ/SWNZ workflows. */
    @SerialName("l_per_100m")
    LITRES_PER_100_METRES("l_per_100m"),
    ;

    companion object {
        fun from(raw: String?): SprayCarrierBasis? =
            entries.firstOrNull { it.raw == raw?.trim()?.lowercase() }
    }
}

/**
 * A fully resolved carrier-volume calculation.
 *
 * Both modes populate [totalLitres] and [concentrationFactor], so every
 * downstream consumer (tank splitting, per-100 L product dosing, reporting)
 * works identically regardless of how the grower entered the volume.
 */
data class SprayCarrierVolume(
    val basis: SprayCarrierBasis,
    /** Total actual carrier litres for the whole application. */
    val totalLitres: Double,
    /**
     * Litres per hectare — as entered in [SprayCarrierBasis.LITRES_PER_HECTARE]
     * mode, or DERIVED in [SprayCarrierBasis.LITRES_PER_100_METRES] mode. Null
     * when it cannot be derived (no uniform row spacing).
     */
    val litresPerHectare: Double?,
    /** Dilute/runoff reference rate (L/100 m). L/100 m mode only. */
    val diluteLitresPer100Metres: Double?,
    /** Actual applied rate (L/100 m). L/100 m mode only. */
    val appliedLitresPer100Metres: Double?,
    /** `dilute ÷ actual`. 1.0 when spraying dilute (no concentration). */
    val concentrationFactor: Double,
    /** The canonical row/trellis metres this volume was calculated from. */
    val rowLengthMetres: Double?,
    /** The hectares this volume was calculated from (L/ha mode). */
    val areaHectaresUsed: Double?,
    val rowSpacingMetres: Double?,
) {
    /**
     * Dilute-equivalent litres — the volume a per-100 L label rate is written
     * against. Equals `totalLitres × concentrationFactor`.
     */
    val diluteEquivalentLitres: Double get() = totalLitres * concentrationFactor
}

object SprayCarrierVolumeCalculator {

    private fun positive(value: Double?): Double? =
        if (value != null && value.isFinite() && value > 0) value else null

    /**
     * L/ha mode — the existing hectare-based carrier calculation.
     *
     * [areaHectares] is supplied by the caller rather than assumed, so a banded
     * job can dose against treated hectares while a foliar job uses gross
     * hectares. Existing callers pass gross hectares and are unchanged.
     *
     * [concentrationFactor] keeps its established VineTrack meaning
     * (`recommendedRate ÷ chosenRate`) and defaults to 1.0.
     */
    fun perHectare(
        litresPerHectare: Double,
        areaHectares: Double,
        concentrationFactor: Double = 1.0,
        rowLengthMetres: Double? = null,
        rowSpacingMetres: Double? = null,
    ): SprayCarrierVolume {
        val rate = max(0.0, if (litresPerHectare.isFinite()) litresPerHectare else 0.0)
        val area = max(0.0, if (areaHectares.isFinite()) areaHectares else 0.0)
        val factor = positive(concentrationFactor) ?: 1.0
        return SprayCarrierVolume(
            basis = SprayCarrierBasis.LITRES_PER_HECTARE,
            totalLitres = rate * area,
            litresPerHectare = rate,
            diluteLitresPer100Metres = null,
            appliedLitresPer100Metres = null,
            concentrationFactor = factor,
            rowLengthMetres = rowLengthMetres,
            areaHectaresUsed = area,
            rowSpacingMetres = rowSpacingMetres,
        )
    }

    /**
     * L/100 m mode — the authoritative row-length carrier calculation.
     *
     * ```text
     * totalCarrierLitres = rowLengthMetres ÷ 100 × appliedLitresPer100m
     * derivedLitresPerHa = appliedLitresPer100m × 100 ÷ rowSpacingMetres
     * concentrationFactor = diluteLitresPer100m ÷ appliedLitresPer100m
     * ```
     *
     * [rowLengthMetres] MUST come from [SprayApplicationGeometry], which is the
     * same source the banded treated-area calculation uses.
     *
     * Returns null when the row length or the applied rate is unusable — a
     * carrier volume is never guessed.
     */
    fun per100Metres(
        appliedLitresPer100Metres: Double,
        diluteLitresPer100Metres: Double? = null,
        rowLengthMetres: Double?,
        rowSpacingMetres: Double? = null,
    ): SprayCarrierVolume? {
        val applied = positive(appliedLitresPer100Metres) ?: return null
        val metres = positive(rowLengthMetres) ?: return null

        val dilute = positive(diluteLitresPer100Metres)
        // Concentrating means applying LESS water than dilute/runoff. A dilute
        // reference below the applied rate is not a concentration, so the factor
        // floors at 1.0 rather than silently reducing product.
        val factor = max(1.0, (dilute ?: applied) / applied)
        val spacing = positive(rowSpacingMetres)

        return SprayCarrierVolume(
            basis = SprayCarrierBasis.LITRES_PER_100_METRES,
            totalLitres = metres / 100.0 * applied,
            litresPerHectare = spacing?.let { applied * 100.0 / it },
            diluteLitresPer100Metres = dilute,
            appliedLitresPer100Metres = applied,
            concentrationFactor = factor,
            rowLengthMetres = metres,
            areaHectaresUsed = null,
            rowSpacingMetres = spacing,
        )
    }

    /**
     * Convenience: build a L/100 m carrier volume straight from canonical
     * geometry, so callers cannot accidentally pass a different row length.
     */
    fun per100Metres(
        appliedLitresPer100Metres: Double,
        diluteLitresPer100Metres: Double? = null,
        geometry: SprayApplicationGeometry,
    ): SprayCarrierVolume? = per100Metres(
        appliedLitresPer100Metres = appliedLitresPer100Metres,
        diluteLitresPer100Metres = diluteLitresPer100Metres,
        rowLengthMetres = geometry.totalRowLengthMetres,
        rowSpacingMetres = geometry.uniformRowSpacingMetres,
    )
}
