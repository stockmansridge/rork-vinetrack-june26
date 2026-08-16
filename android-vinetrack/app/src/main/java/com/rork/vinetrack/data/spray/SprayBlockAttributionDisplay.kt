package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.model.Paddock

/**
 * The ONE rule for turning stored block attribution (sql/195) into text a human
 * reads — on screen, in a PDF, in a CSV cell.
 *
 * # Why this is centralised
 *
 * Every export faces the same three-way question and must answer it identically,
 * because a spray PDF and a spray CSV describing the same application in
 * different words is a compliance problem, not a cosmetic one.
 *
 * # The deterministic display rule
 *
 * ```text
 * 1. The id still resolves to a live block  -> that block's CURRENT name
 * 2. The id no longer resolves              -> the STORED blockName snapshot
 * 3. Neither is available                   -> "Unknown block"
 * ```
 *
 * Step 1 is deliberately the current name, not the snapshot: after a rename,
 * "North 3" is what the operator will find in the app today, so an export that
 * still said "North Three" would send them looking for a block that no longer
 * appears anywhere. The stored snapshot exists for step 2, which is the case a
 * live lookup cannot serve — an archived or deleted block whose name would
 * otherwise be lost. Readability must not depend on the block still existing.
 *
 * Identity is always the id. Names are never matched on, in either direction.
 *
 * # Absence
 *
 * [NOT_RECORDED] is the single wording for "this record predates block
 * attribution". Resolving null attribution NEVER falls back to the vineyard's
 * current blocks: that would turn an honest unknown into a false statement about
 * where a chemical was applied.
 *
 * Mirrors the iOS `SprayBlockAttributionDisplay`.
 */
object SprayBlockAttributionDisplay {

    /** The single human wording for attribution that was never recorded. */
    const val NOT_RECORDED: String = "Blocks not recorded"

    /** Shown when an id resolves to nothing and carried no name snapshot. */
    const val UNKNOWN_BLOCK: String = "Unknown block"

    /** One attributed block, resolved for display. */
    data class Resolved(
        val blockId: String,
        val name: String,
        /** True when the id still resolves to a live block in the vineyard. */
        val isLive: Boolean,
    )

    /**
     * Resolve each attributed block to a display name.
     *
     * Returns null when [blocks] is null — attribution was never recorded — so
     * callers must handle the unknown case explicitly rather than receiving an
     * empty list they might render as "no blocks".
     */
    fun resolve(
        blocks: List<SprayApplicationBlockSnapshot>?,
        paddocks: List<Paddock>,
    ): List<Resolved>? {
        if (blocks == null) return null
        val liveNames: Map<String, String> = paddocks.associate { it.id to it.name }
        return blocks.map { block ->
            val live = liveNames[block.blockId]?.trim()?.takeIf { it.isNotEmpty() }
            val snapshot = block.blockName?.trim()?.takeIf { it.isNotEmpty() }
            Resolved(
                blockId = block.blockId,
                name = live ?: snapshot ?: UNKNOWN_BLOCK,
                isLive = live != null,
            )
        }
    }

    /**
     * Human-readable summary for a PDF row or a compact table cell:
     * `"Block A, Block C"`, or [NOT_RECORDED] when attribution is absent.
     */
    fun summary(
        blocks: List<SprayApplicationBlockSnapshot>?,
        paddocks: List<Paddock>,
    ): String {
        val resolved = resolve(blocks, paddocks) ?: return NOT_RECORDED
        return resolved.joinToString(", ") { it.name }.ifBlank { NOT_RECORDED }
    }

    /**
     * Human-readable names for a machine-readable cell, or an EMPTY string when
     * attribution was never recorded.
     *
     * Machine-readable exports use emptiness for unknown rather than the
     * [NOT_RECORDED] prose, matching how every other never-recorded spray field
     * is already exported. A parser must not have to string-match English.
     */
    fun namesCell(
        blocks: List<SprayApplicationBlockSnapshot>?,
        paddocks: List<Paddock>,
        separator: String = MACHINE_SEPARATOR,
    ): String {
        val resolved = resolve(blocks, paddocks) ?: return ""
        return resolved.joinToString(separator) { it.name.replace(separator.trim(), " ") }
    }

    /**
     * Stable ids for a machine-readable cell, in the operator's selection order,
     * or an EMPTY string when attribution was never recorded.
     *
     * This is the column a consumer should join on. Names are for people.
     */
    fun idsCell(
        blocks: List<SprayApplicationBlockSnapshot>?,
        separator: String = MACHINE_SEPARATOR,
    ): String = blocks?.blockIds?.joinToString(separator) ?: ""

    /**
     * Separator for multi-value machine-readable cells.
     *
     * `"; "` rather than `","` because these exports are CSV: a comma inside a
     * cell would force quoting and invite a consumer to split the row on the
     * wrong character. Semicolon cannot occur in a uuid, so the ID cell stays
     * unambiguously splittable, and this matches the separator the existing
     * exports already use for multi-value cells.
     */
    const val MACHINE_SEPARATOR: String = "; "
}
