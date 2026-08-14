package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.Paddock
import kotlin.math.abs

/**
 * Where a block's applicable row/trellis length came from — the Kotlin twin of
 * the Swift `SprayGeometrySource`.
 *
 * Recorded on every result so a spray quantity can always be traced back to the
 * geometry that produced it. This is the ONLY place spray calculations are
 * allowed to decide what "row length" means.
 */
enum class SprayGeometrySource(val raw: String) {
    /** Summed length of the block's actual mapped rows. Best available truth. */
    MAPPED_ROWS("mapped_rows"),

    /** The operator's stored block row/trellis length (`rowLengthOverride`). */
    STORED_ROW_LENGTH("stored_row_length"),

    /** Derived from block area and row spacing: `areaHa × 10_000 / rowSpacing`. */
    DERIVED_FROM_AREA_AND_SPACING("derived_from_area_and_spacing"),

    /** Nothing reliable enough to calculate a spray quantity from. */
    UNAVAILABLE("unavailable"),
    ;

    companion object {
        fun from(raw: String?): SprayGeometrySource? =
            entries.firstOrNull { it.raw == raw?.trim()?.lowercase() }
    }
}

/**
 * How much the geometry can be trusted. Drives whether the UI may present a
 * quantity plainly, must qualify it, or must refuse to calculate.
 */
enum class SprayGeometryQuality(val raw: String) {
    /** Measured or explicitly stored by the operator. */
    AUTHORITATIVE("authoritative"),

    /** Arithmetically derived from other valid stored values. */
    DERIVED("derived"),

    /** Cannot be determined — spray quantities must not be calculated. */
    INCOMPLETE("incomplete"),
}

/**
 * Why geometry could not be resolved. Each case names the ONE thing the grower
 * has to fix, mirroring the `PaddockRowVineCount.Unavailable` pattern.
 */
enum class SprayGeometryUnavailable(val raw: String, val message: String) {
    MISSING_ROW_SPACING(
        "missing_row_spacing",
        "Set row spacing in block details to calculate spray volumes.",
    ),
    MISSING_AREA(
        "missing_area",
        "Map this block's boundary to calculate spray volumes.",
    ),
    MISSING_GEOMETRY(
        "missing_geometry",
        "Map this block's rows, or enter a row length in block details.",
    ),
}

/**
 * The raw per-block numbers the geometry engine needs.
 *
 * Deliberately decoupled from [Paddock] so the contract can be tested with
 * explicit fixtures and shared with the portal without dragging in the data
 * store. Use [from] for live data.
 */
data class SprayBlockInput(
    val blockId: String,
    /** Gross block area in hectares. Null/non-positive means unmapped. */
    val grossAreaHectares: Double?,
    /** Summed length of mapped rows, when the block actually has rows. */
    val mappedRowLengthMetres: Double? = null,
    /** Stored block row/trellis length, when the operator has entered one. */
    val storedRowLengthMetres: Double? = null,
    /** Row spacing in metres. Null means genuinely unknown — NEVER defaulted. */
    val rowSpacingMetres: Double? = null,
    val rowCount: Int? = null,
) {
    companion object {
        /**
         * Adapts a live [Paddock] to the geometry contract.
         *
         * `mappedRowLengthMetres` is taken only when the block genuinely has
         * mapped rows, so an empty `rows` list cannot masquerade as a measured
         * zero.
         *
         * Unlike iOS — where `Paddock.rowWidth` is non-optional and defaults to
         * 2.5 m — the Android model stores row spacing as nullable, so a block
         * whose spacing was never entered correctly reports
         * [SprayGeometryUnavailable.MISSING_ROW_SPACING] instead of silently
         * calculating against an assumed 2.5 m.
         */
        fun from(paddock: Paddock): SprayBlockInput {
            val hasRows = !paddock.rows.isNullOrEmpty()
            return SprayBlockInput(
                blockId = paddock.id,
                grossAreaHectares = paddock.areaHectares,
                mappedRowLengthMetres = if (hasRows) paddock.totalRowLengthMetres else null,
                storedRowLengthMetres = paddock.rowLengthOverride,
                rowSpacingMetres = paddock.rowWidth?.takeIf { it > 0 },
                rowCount = if (hasRows) paddock.rowCount else null,
            )
        }
    }
}

/** Resolved geometry for ONE block. */
data class SprayBlockGeometry(
    val blockId: String,
    val grossAreaHectares: Double,
    /** Applicable row/trellis length. Null when it could not be resolved. */
    val rowLengthMetres: Double?,
    val rowSpacingMetres: Double?,
    val rowCount: Int?,
    val source: SprayGeometrySource,
    val quality: SprayGeometryQuality,
    val unavailableReason: SprayGeometryUnavailable?,
) {
    val isUsable: Boolean get() = rowLengthMetres != null && quality != SprayGeometryQuality.INCOMPLETE
}

/**
 * Resolved geometry for the whole application (all selected blocks).
 *
 * This is THE canonical geometry result. Banded treated-area and L/100 m
 * carrier-volume calculations both read [totalRowLengthMetres] from here, so the
 * two can never disagree.
 */
data class SprayApplicationGeometry(val blocks: List<SprayBlockGeometry>) {

    val blockIds: List<String> get() = blocks.map { it.blockId }

    /** Gross (whole-block) hectares across the selection. */
    val grossAreaHectares: Double get() = blocks.sumOf { it.grossAreaHectares }

    /**
     * Total applicable row/trellis metres, or null when ANY selected block could
     * not be resolved. Partial totals are refused deliberately: a silently short
     * row length under-doses the whole tank mix.
     */
    val totalRowLengthMetres: Double?
        get() {
            if (blocks.isEmpty() || !blocks.all { it.isUsable }) return null
            return blocks.sumOf { it.rowLengthMetres ?: 0.0 }
        }

    val rowCount: Int?
        get() {
            val counts = blocks.mapNotNull { it.rowCount }
            return if (counts.size == blocks.size && counts.isNotEmpty()) counts.sum() else null
        }

    /**
     * Row spacing for the selection, but ONLY when every block shares the same
     * spacing (within 1 mm). Mixed spacings return null rather than an average,
     * because an averaged spacing produces a derived L/ha that is wrong for
     * every block in the set.
     */
    val uniformRowSpacingMetres: Double?
        get() {
            val spacings = blocks.mapNotNull { it.rowSpacingMetres }
            if (spacings.size != blocks.size) return null
            val first = spacings.firstOrNull() ?: return null
            return if (spacings.all { abs(it - first) < 0.001 }) first else null
        }

    /** The weakest link across the selection. */
    val quality: SprayGeometryQuality
        get() = when {
            blocks.isEmpty() -> SprayGeometryQuality.INCOMPLETE
            blocks.any { it.quality == SprayGeometryQuality.INCOMPLETE } -> SprayGeometryQuality.INCOMPLETE
            blocks.any { it.quality == SprayGeometryQuality.DERIVED } -> SprayGeometryQuality.DERIVED
            else -> SprayGeometryQuality.AUTHORITATIVE
        }

    /** The single source when all blocks agree, otherwise the weakest one. */
    val source: SprayGeometrySource
        get() {
            val first = blocks.firstOrNull()?.source ?: return SprayGeometrySource.UNAVAILABLE
            if (blocks.all { it.source == first }) return first
            if (blocks.any { it.source == SprayGeometrySource.UNAVAILABLE }) {
                return SprayGeometrySource.UNAVAILABLE
            }
            return if (blocks.any { it.source == SprayGeometrySource.DERIVED_FROM_AREA_AND_SPACING }) {
                SprayGeometrySource.DERIVED_FROM_AREA_AND_SPACING
            } else {
                SprayGeometrySource.STORED_ROW_LENGTH
            }
        }

    val isUsable: Boolean get() = totalRowLengthMetres != null

    /** Blocks that stopped the selection from being calculable, with reasons. */
    val unresolvedBlocks: List<SprayBlockGeometry> get() = blocks.filter { !it.isUsable }

    val unavailableMessage: String?
        get() {
            if (isUsable) return null
            if (blocks.isEmpty()) return "Select at least one block."
            return unresolvedBlocks.firstOrNull()?.unavailableReason?.message
                ?: SprayGeometryUnavailable.MISSING_GEOMETRY.message
        }
}

/**
 * THE canonical row/trellis-length engine for spray calculations.
 *
 * Resolution hierarchy, highest first:
 *  1. Actual mapped row geometry ([SprayBlockInput.mappedRowLengthMetres]) — authoritative.
 *  2. Valid stored block row/trellis length — authoritative.
 *  3. Derived from gross area × valid row spacing — derived.
 *  4. Otherwise an explicit incomplete state.
 *
 * NOTE ON PRECEDENCE: this deliberately prefers MAPPED geometry over the stored
 * `rowLengthOverride`, which is the opposite of the long-standing
 * `Paddock.effectiveTotalRowLength` (override-wins). That legacy property is
 * left untouched — it still drives irrigation, vine counts and pruning — so
 * nothing existing changes behaviour. Spray is the only consumer of this engine.
 */
object SprayGeometryResolver {

    /** Square metres in a hectare. */
    const val SQUARE_METRES_PER_HECTARE: Double = 10_000.0

    private fun positive(value: Double?): Double? =
        if (value != null && value.isFinite() && value > 0) value else null

    /** Resolves ONE block against the hierarchy above. */
    fun resolve(input: SprayBlockInput): SprayBlockGeometry {
        val area = positive(input.grossAreaHectares) ?: 0.0
        val spacing = positive(input.rowSpacingMetres)

        fun result(
            length: Double?,
            source: SprayGeometrySource,
            quality: SprayGeometryQuality,
            reason: SprayGeometryUnavailable? = null,
        ) = SprayBlockGeometry(
            blockId = input.blockId,
            grossAreaHectares = area,
            rowLengthMetres = length,
            rowSpacingMetres = spacing,
            rowCount = input.rowCount,
            source = source,
            quality = quality,
            unavailableReason = reason,
        )

        // 1. Mapped row geometry.
        positive(input.mappedRowLengthMetres)?.let {
            return result(it, SprayGeometrySource.MAPPED_ROWS, SprayGeometryQuality.AUTHORITATIVE)
        }
        // 2. Stored block row/trellis length.
        positive(input.storedRowLengthMetres)?.let {
            return result(it, SprayGeometrySource.STORED_ROW_LENGTH, SprayGeometryQuality.AUTHORITATIVE)
        }
        // 3. Derived from area and spacing.
        if (spacing != null && area > 0) {
            return result(
                area * SQUARE_METRES_PER_HECTARE / spacing,
                SprayGeometrySource.DERIVED_FROM_AREA_AND_SPACING,
                SprayGeometryQuality.DERIVED,
            )
        }
        // 4. Refuse to guess.
        val reason = if (spacing == null) {
            SprayGeometryUnavailable.MISSING_ROW_SPACING
        } else {
            SprayGeometryUnavailable.MISSING_AREA
        }
        return result(null, SprayGeometrySource.UNAVAILABLE, SprayGeometryQuality.INCOMPLETE, reason)
    }

    /** Resolves the full selection. */
    fun resolve(inputs: List<SprayBlockInput>): SprayApplicationGeometry =
        SprayApplicationGeometry(inputs.map { resolve(it) })

    /** Resolves straight from live blocks. */
    fun resolvePaddocks(paddocks: List<Paddock>): SprayApplicationGeometry =
        resolve(paddocks.map { SprayBlockInput.from(it) })
}
