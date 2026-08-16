package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.Paddock

/**
 * Turns a manual spray form's block selection into the attribution to persist
 * (sql/195).
 *
 * # Why this is not inside the form
 *
 * Manual entry is the one path with no guided calculation to project attribution
 * from, so it has to decide three things that are genuinely domain rules rather
 * than presentation:
 *
 *  1. When to keep a historical snapshot **verbatim**.
 *  2. When to project **fresh** geometry for a newly chosen block.
 *  3. What to do about a selected block that **no longer exists**.
 *
 * Those rules decide what a compliance record says, so they live here where they
 * can be tested directly, rather than inside a `@Composable` where they could
 * only ever be verified by eye.
 *
 * Mirrors the iOS `SprayRecordFormView` attribution rules.
 */
object SprayManualBlockAttribution {

    /**
     * The attribution to persist, or null for "blocks not recorded".
     *
     * @param selectedBlockIds what the operator currently has ticked, in order.
     * @param recordedBlocks what the record already says it treated (null when it
     *   predates sql/195, or for a brand-new record).
     * @param availableBlocks the vineyard's live blocks, used ONLY to resolve
     *   geometry for ids the operator selected. Never used to add ids.
     * @param isEdit true when editing an existing record rather than creating one
     *   (including from a template).
     */
    fun resolve(
        selectedBlockIds: List<String>,
        recordedBlocks: List<SprayApplicationBlockSnapshot>?,
        availableBlocks: List<Paddock>,
        isEdit: Boolean,
    ): List<SprayApplicationBlockSnapshot>? {
        // An empty selection is "not recorded", never "treated no blocks". This is
        // also what keeps an operator editing a legacy record's wind speed from
        // being forced to invent history: they leave it empty and it stays null.
        if (selectedBlockIds.isEmpty()) return null

        // Selection unchanged on an edit -> the stored snapshot is authoritative and
        // is returned untouched. Re-projecting here would silently refreeze TODAY's
        // block geometry onto a spray that happened last season, which is exactly
        // the retroactive rewrite the snapshot exists to prevent.
        val recordedIds = recordedBlocks?.blockIds
        if (isEdit && recordedIds != null && recordedIds.toSet() == selectedBlockIds.toSet()) {
            return recordedBlocks
        }

        // The operator changed the selection, so this is an intentional correction.
        // Resolve through the SAME canonical resolver the Guided Spray uses, so
        // per-block areas and row lengths come from one implementation, not two.
        val livePaddocks = selectedBlockIds.mapNotNull { id ->
            availableBlocks.firstOrNull { it.id == id }
        }
        val resolved = SprayGeometryResolver
            .resolve(livePaddocks.map { SprayBlockInput.from(it) })
            .blocks
            .associateBy { it.blockId }
        val stored = recordedBlocks.orEmpty().associateBy { it.blockId }

        return SprayApplicationBlockSnapshot.normalised(
            selectedBlockIds.mapNotNull { id ->
                // A live block gets fresh geometry. A block that no longer exists
                // keeps its stored snapshot, so changing the selection never
                // destroys the attribution of an archived block. An id that is
                // neither is dropped — there is nothing factual to record.
                resolved[id]?.let(SprayApplicationBlockSnapshot::from) ?: stored[id]
            }
        )
    }

    /**
     * The full geometry snapshot to persist from a manual save.
     *
     * Carries [existing] through VERBATIM and replaces only the attribution.
     * Before this existed the Android manual sheet sent no geometry at all, so
     * editing a calculator-produced record wiped its whole sql/191 snapshot —
     * treated area, band widths, row length and all.
     */
    fun geometryToPersist(
        existing: SprayApplicationSnapshot?,
        blocks: List<SprayApplicationBlockSnapshot>?,
    ): SprayApplicationSnapshot? =
        (existing ?: SprayApplicationSnapshot()).withBlocks(blocks)
}
