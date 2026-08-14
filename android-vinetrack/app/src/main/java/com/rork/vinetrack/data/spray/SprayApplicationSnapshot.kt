package com.rork.vinetrack.data.spray

import kotlinx.serialization.Serializable

/**
 * An immutable projection of ONE canonical [SprayApplicationPlan] onto the
 * `spray_records` geometry/carrier columns added by sql/191 + sql/192.
 *
 * # Why this type exists
 *
 * The rule for the whole spray pipeline is:
 *
 * ```text
 * Calculate once through the canonical engine → persist the resulting snapshot.
 * ```
 *
 * This is the *persistence face* of that rule. It performs **no calculation of
 * its own** — every property is copied straight off a plan the engine already
 * produced. There is deliberately no constructor that takes loose numbers and
 * derives anything, because that would be a second calculation path and the two
 * could drift apart.
 *
 * # Why it is a snapshot and not a live view
 *
 * A completed spray record is a compliance document: it must keep saying what
 * was actually applied even after the vineyard changes underneath it. Block
 * polygons get redrawn, row spacing gets corrected, an operator override gets
 * edited, the vineyard's carrier preference gets switched. None of that may
 * retroactively rewrite what a sprayer put through a nozzle last Tuesday.
 *
 * # Legacy records
 *
 * Every property is nullable and the whole snapshot is null for any record
 * written before sql/191. Absence is preserved, never guessed: a historical
 * banded spray whose treated area was never measured reads back as null, not as
 * a treated area invented from today's geometry. See [isEmpty].
 *
 * Mirrors the iOS `SprayApplicationSnapshot` field-for-field so both platforms
 * write byte-identical column values from equivalent vineyard data.
 *
 * Serialisable so the offline outbox can carry a full snapshot through a queued
 * create/update without flattening it into loose parameters. The enums encode
 * to their `raw` wire strings, so outbox JSON and database columns agree.
 */
@Serializable
data class SprayApplicationSnapshot(
    // ------------------------------------------------------ application geometry
    /** Total GROSS area of the selected blocks. Never replaced by treated area. */
    val grossAreaHa: Double? = null,
    /**
     * The genuinely treated area. Null when it was not determinable — for a
     * banded job that means the band geometry was incomplete, and the UI must
     * say so rather than fall back to gross.
     */
    val treatedAreaHa: Double? = null,
    val applicationMode: SprayApplicationMode? = null,
    val treatedAreaMethod: SprayTreatedAreaMethod? = null,

    // ------------------------------------------------------------ band geometry
    val bandWidthTotalMetres: Double? = null,
    val bandWidthLeftMetres: Double? = null,
    val bandWidthRightMetres: Double? = null,

    // -------------------------------------------------- canonical row geometry
    /**
     * The row length the calculation actually used, from the canonical
     * resolver — the same metres the banded treated area and any L/100 m
     * carrier volume were computed from, so they cannot disagree.
     */
    val canonicalRowLengthMetres: Double? = null,
    val rowSpacingMetres: Double? = null,
    val geometrySource: SprayGeometrySource? = null,
    val geometryQuality: SprayGeometryQuality? = null,

    // ----------------------------------------------------------- carrier volume
    val carrierVolumeBasis: SprayCarrierBasis? = null,
    val totalCarrierLitres: Double? = null,
    val carrierLitresPerHectare: Double? = null,
    val diluteLitresPer100m: Double? = null,
    val appliedLitresPer100m: Double? = null,
    val concentrationFactor: Double? = null,
) {

    /**
     * True when no field carries a value — the shape a pre-sql/191 record reads
     * back as. Callers persist null rather than a row of NULLs so "never
     * recorded" stays distinguishable from "recorded as zero".
     */
    val isEmpty: Boolean
        get() = grossAreaHa == null && treatedAreaHa == null && applicationMode == null &&
            treatedAreaMethod == null && bandWidthTotalMetres == null &&
            bandWidthLeftMetres == null && bandWidthRightMetres == null &&
            canonicalRowLengthMetres == null && rowSpacingMetres == null &&
            geometrySource == null && geometryQuality == null &&
            carrierVolumeBasis == null && totalCarrierLitres == null &&
            carrierLitresPerHectare == null && diluteLitresPer100m == null &&
            appliedLitresPer100m == null && concentrationFactor == null

    /**
     * True when this snapshot records a banded application whose treated area is
     * genuinely known. Lets the UI separate "banded, 2.5 ha treated" from
     * "banded, geometry unavailable" without re-deriving anything.
     */
    val hasGenuineTreatedArea: Boolean
        get() = treatedAreaHa != null &&
            treatedAreaMethod != null &&
            treatedAreaMethod != SprayTreatedAreaMethod.UNAVAILABLE

    /**
     * Strip this snapshot down to the operator's reusable CONFIGURATION,
     * discarding every geometry-dependent calculated OUTPUT.
     *
     * A template must capture *input intent*, not *historical output*. Freezing a
     * 31,250 m row length into a template would mean a spray created from it next
     * season silently reuses last season's geometry - even after blocks were
     * resurveyed or different blocks were selected. So when a template is opened
     * for a new spray the flow is:
     *
     * ```text
     * Template inputs -> current canonical geometry -> new calculation snapshot
     * ```
     *
     * KEPT (reusable inputs the operator chose):
     * [applicationMode], the three band widths, [carrierVolumeBasis],
     * [diluteLitresPer100m], [appliedLitresPer100m], [concentrationFactor], and
     * [carrierLitresPerHectare] **only** in `l_per_ha` mode, where it is the rate
     * the operator typed rather than a derived figure.
     *
     * CLEARED (recalculated per spray from current geometry):
     * [grossAreaHa], [treatedAreaHa], [treatedAreaMethod],
     * [canonicalRowLengthMetres], [rowSpacingMetres], [geometrySource],
     * [geometryQuality], [totalCarrierLitres], and [carrierLitresPerHectare] in
     * `l_per_100m` mode, where it is derived from row spacing.
     */
    fun templateConfiguration(): SprayApplicationSnapshot? {
        // In L/ha mode the per-hectare figure IS the operator's entered rate and
        // is reusable. In L/100 m mode it was derived from row spacing, so it is
        // an output and must be recalculated against the new blocks.
        val reusableLitresPerHectare =
            if (carrierVolumeBasis == SprayCarrierBasis.LITRES_PER_HECTARE) {
                carrierLitresPerHectare
            } else {
                null
            }
        val configuration = SprayApplicationSnapshot(
            grossAreaHa = null,
            treatedAreaHa = null,
            applicationMode = applicationMode,
            treatedAreaMethod = null,
            bandWidthTotalMetres = bandWidthTotalMetres,
            bandWidthLeftMetres = bandWidthLeftMetres,
            bandWidthRightMetres = bandWidthRightMetres,
            canonicalRowLengthMetres = null,
            rowSpacingMetres = null,
            geometrySource = null,
            geometryQuality = null,
            carrierVolumeBasis = carrierVolumeBasis,
            totalCarrierLitres = null,
            carrierLitresPerHectare = reusableLitresPerHectare,
            diluteLitresPer100m = diluteLitresPer100m,
            appliedLitresPer100m = appliedLitresPer100m,
            concentrationFactor = concentrationFactor,
        )
        return if (configuration.isEmpty) null else configuration
    }

    companion object {
        /**
         * Project a finished plan onto the storage columns.
         *
         * This is the ONLY way to build a populated snapshot from a calculation.
         * Values are copied, never recomputed.
         */
        fun from(plan: SprayApplicationPlan): SprayApplicationSnapshot =
            SprayApplicationSnapshot(
                grossAreaHa = nonNegative(plan.treatedArea.grossAreaHectares),
                treatedAreaHa = nonNegative(plan.treatedArea.treatedAreaHectares),
                applicationMode = plan.mode,
                treatedAreaMethod = plan.treatedArea.method,
                bandWidthTotalMetres = positive(plan.treatedArea.bandWidth?.totalMetres),
                bandWidthLeftMetres = nonNegative(plan.treatedArea.bandWidth?.leftMetres),
                bandWidthRightMetres = nonNegative(plan.treatedArea.bandWidth?.rightMetres),
                canonicalRowLengthMetres = positive(plan.geometry.totalRowLengthMetres),
                rowSpacingMetres = positive(plan.geometry.uniformRowSpacingMetres),
                geometrySource = plan.geometry.source,
                geometryQuality = plan.geometry.quality,
                carrierVolumeBasis = plan.carrier.basis,
                totalCarrierLitres = nonNegative(plan.carrier.totalLitres),
                carrierLitresPerHectare = nonNegative(plan.carrier.litresPerHectare),
                diluteLitresPer100m = positive(plan.carrier.diluteLitresPer100Metres),
                appliedLitresPer100m = positive(plan.carrier.appliedLitresPer100Metres),
                concentrationFactor = positive(plan.carrier.concentrationFactor),
            )

        /**
         * Rebuild a snapshot from stored column values, read back VERBATIM.
         *
         * Nothing is re-derived from current block geometry — that is what keeps
         * a completed record stable after the vineyard is edited. Returns null
         * when every column is null (a pre-sql/191 record). Unrecognised enum
         * text degrades that single field to null instead of failing the record.
         */
        @Suppress("LongParameterList")
        fun fromColumns(
            grossAreaHa: Double?,
            treatedAreaHa: Double?,
            applicationMode: String?,
            treatedAreaMethod: String?,
            bandWidthTotalMetres: Double?,
            bandWidthLeftMetres: Double?,
            bandWidthRightMetres: Double?,
            canonicalRowLengthMetres: Double?,
            rowSpacingMetres: Double?,
            geometrySource: String?,
            geometryQuality: String?,
            carrierVolumeBasis: String?,
            totalCarrierLitres: Double?,
            carrierLitresPerHectare: Double?,
            diluteLitresPer100m: Double?,
            appliedLitresPer100m: Double?,
            concentrationFactor: Double?,
        ): SprayApplicationSnapshot? {
            val snapshot = SprayApplicationSnapshot(
                grossAreaHa = grossAreaHa,
                treatedAreaHa = treatedAreaHa,
                applicationMode = SprayApplicationMode.from(applicationMode),
                treatedAreaMethod = SprayTreatedAreaMethod.from(treatedAreaMethod),
                bandWidthTotalMetres = bandWidthTotalMetres,
                bandWidthLeftMetres = bandWidthLeftMetres,
                bandWidthRightMetres = bandWidthRightMetres,
                canonicalRowLengthMetres = canonicalRowLengthMetres,
                rowSpacingMetres = rowSpacingMetres,
                geometrySource = SprayGeometrySource.from(geometrySource),
                geometryQuality = SprayGeometryQuality.from(geometryQuality),
                carrierVolumeBasis = SprayCarrierBasis.from(carrierVolumeBasis),
                totalCarrierLitres = totalCarrierLitres,
                carrierLitresPerHectare = carrierLitresPerHectare,
                diluteLitresPer100m = diluteLitresPer100m,
                appliedLitresPer100m = appliedLitresPer100m,
                concentrationFactor = concentrationFactor,
            )
            return if (snapshot.isEmpty) null else snapshot
        }

        // sql/191 constrains several columns to be strictly positive, because a
        // band width or row length of 0 is not a measurement — absence must be
        // NULL so it can never dose a tank. These helpers make the client honour
        // that contract rather than relying on the database to reject the write.

        /** Strictly-positive columns: 0, negatives and non-finite become null. */
        private fun positive(value: Double?): Double? =
            if (value != null && value.isFinite() && value > 0) value else null

        /** Non-negative columns: negatives and non-finite become null. */
        private fun nonNegative(value: Double?): Double? =
            if (value != null && value.isFinite() && value >= 0) value else null
    }
}
