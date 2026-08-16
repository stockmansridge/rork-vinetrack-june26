package com.rork.vinetrack.data.spray

import kotlinx.serialization.Serializable

/**
 * ONE block that an application actually treated, frozen at save time.
 *
 * # What this is for
 *
 * A completed spray record has always known its `vineyardId` and nothing more.
 * The operator's Blocks-step selection reached the canonical geometry engine,
 * every block's area and row length was resolved individually, and then the whole
 * per-block list was collapsed into aggregate totals and discarded. This type is
 * the durable form of that list (sql/195).
 *
 * # Identity is the id, never the name
 *
 * [blockId] is the stable `Paddock` id and is the ONLY identity. [blockName] is a
 * display snapshot kept so an export, or a block later renamed or deleted, still
 * reads sensibly. Matching on names is never correct: two vineyards may reuse a
 * name, and a rename must not move history.
 *
 * # It extends the geometry contract rather than duplicating it
 *
 * Every measurement here is copied verbatim from the [SprayBlockGeometry] the
 * calculation used, so the per-block values reconcile with the sql/191 aggregates
 * by construction: the gross areas sum to `grossAreaHa` and the row lengths to
 * `canonicalRowLengthMetres`. There is no second geometry path.
 *
 * # There is deliberately no per-block treated area
 *
 * Treated area is a banded-application figure the engine computes ONCE from the
 * selection's total row length. Splitting it per block here would be a second
 * implementation of the band arithmetic, and the two could drift. Per-block gross
 * area and row length are direct copies; a per-block treated area would be a new
 * derivation, so it is not stored. Read `treatedAreaHa` on the parent snapshot,
 * which remains the single authority.
 *
 * Mirrors the iOS `SprayApplicationBlockSnapshot` field-for-field.
 */
@Serializable
data class SprayApplicationBlockSnapshot(
    /** Stable `Paddock` id. THE identity of this attribution. */
    val blockId: String,
    /** Display-name snapshot at application time. Never used for matching. */
    val blockName: String? = null,
    /** Gross (whole-block) hectares for this block, copied from the geometry. */
    val grossAreaHa: Double? = null,
    /** Applicable row/trellis metres for this block, copied from the geometry. */
    val rowLengthMetres: Double? = null,
    val rowSpacingMetres: Double? = null,
    val rowCount: Int? = null,
    val geometrySource: SprayGeometrySource? = null,
    val geometryQuality: SprayGeometryQuality? = null,
) {

    /**
     * This block's IDENTITY only, with every geometry-dependent output cleared.
     *
     * What a template keeps. A template must carry *which blocks the operator
     * intends* without freezing one season's areas and row lengths, because the
     * new spray recalculates those from current geometry — and may well run
     * against a different selection entirely.
     */
    val identityOnly: SprayApplicationBlockSnapshot
        get() = SprayApplicationBlockSnapshot(blockId = blockId, blockName = blockName)

    /**
     * A name to show, falling back to a clearly non-authoritative placeholder
     * when the block was recorded before names were snapshotted.
     */
    val displayName: String
        get() = blockName?.takeIf { it.isNotBlank() } ?: "Unnamed block"

    companion object {
        /**
         * Project ONE resolved block geometry onto its persisted form.
         *
         * Values are copied, never recomputed — the same rule the parent snapshot
         * follows.
         */
        fun from(geometry: SprayBlockGeometry): SprayApplicationBlockSnapshot =
            SprayApplicationBlockSnapshot(
                blockId = geometry.blockId,
                blockName = geometry.blockName?.trim()?.takeIf { it.isNotEmpty() },
                grossAreaHa = nonNegative(geometry.grossAreaHectares),
                rowLengthMetres = positive(geometry.rowLengthMetres),
                rowSpacingMetres = positive(geometry.rowSpacingMetres),
                rowCount = geometry.rowCount?.takeIf { it > 0 },
                geometrySource = geometry.source,
                geometryQuality = geometry.quality,
            )

        /**
         * De-duplicate a selection by [blockId], keeping first occurrence and
         * order.
         *
         * A block appearing twice in one application would be counted twice by a
         * per-block resistance history, so this runs on every write path. Returns
         * null for an empty selection: absence of attribution is null and never
         * an empty list, matching the sql/195 constraint that rejects `[]`.
         */
        fun normalised(
            blocks: List<SprayApplicationBlockSnapshot>?,
        ): List<SprayApplicationBlockSnapshot>? {
            if (blocks == null) return null
            val seen = mutableSetOf<String>()
            val unique = blocks
                .filter { it.blockId.isNotBlank() }
                .filter { seen.add(it.blockId) }
            return unique.ifEmpty { null }
        }

        /** Project a whole resolved selection, normalised. */
        fun project(geometry: List<SprayBlockGeometry>): List<SprayApplicationBlockSnapshot>? =
            normalised(geometry.map(::from))

        private fun positive(value: Double?): Double? =
            if (value != null && value.isFinite() && value > 0) value else null

        private fun nonNegative(value: Double?): Double? =
            if (value != null && value.isFinite() && value >= 0) value else null
    }
}

/**
 * The stable ids, in selection order — the client-side mirror of the sql/195
 * `block_ids` projection.
 */
val List<SprayApplicationBlockSnapshot>.blockIds: List<String>
    get() = map { it.blockId }

/** Human-readable list for exports and summaries. */
val List<SprayApplicationBlockSnapshot>.displayNames: List<String>
    get() = map { it.displayName }
