package com.rork.vinetrack.data.model

/**
 * THE per-row vine-count contract (sql/188) — the Kotlin twin of the Swift
 * `PaddockRowVineCount`. Both platforms and the portal MUST produce identical
 * numbers from identical inputs.
 *
 * Canonical `paddocks.rows` element:
 * ```json
 * {
 *   "id": "uuid",
 *   "number": 12,
 *   "startPoint": { "latitude": .., "longitude": .. },
 *   "endPoint":   { "latitude": .., "longitude": .. },
 *   "vineCountOverride": 182
 * }
 * ```
 *
 * `vineCountOverride` is OPTIONAL. Rows without it keep the calculated
 * estimate, so every row ever written stays valid.
 *
 * RELATIONSHIP TO THE BLOCK-LEVEL OVERRIDE (unchanged, do not conflate):
 * * `paddocks.vine_count_override` — the BLOCK total. Still drives water,
 *   spray, fertiliser and yield estimates exactly as before.
 * * `rows[].vineCountOverride` — per-ROW truth. Drives row-based work,
 *   specifically the pruning piece-rate quantity.
 * Neither writes to the other.
 */
object PaddockRowVineCount {

    /** A manual count above this is a typo, not a row. */
    const val MAX_OVERRIDE: Int = 100_000

    /**
     * Normalises a decoded/entered override to the stored contract: a whole
     * POSITIVE number, or null for "no override". Zero and negatives are not
     * overrides — they are absence.
     */
    fun sanitiseOverride(value: Int?): Int? =
        if (value != null && value > 0 && value <= MAX_OVERRIDE) value else null

    /**
     * Parsed user input for the override field.
     * * blank → [Cleared] (no override)
     * * whole number 1..[MAX_OVERRIDE] → [Valid]
     * * anything else (negative, zero, decimal, junk) → [Invalid]
     */
    sealed interface OverrideInput {
        data object Cleared : OverrideInput
        data class Valid(val amount: Int) : OverrideInput
        data class Invalid(val reason: String) : OverrideInput

        /** The manual count when valid, else null ("no override"). */
        val value: Int? get() = (this as? Valid)?.amount
        val isInvalid: Boolean get() = this is Invalid
        /** The user-facing validation message, or null when acceptable. */
        val message: String? get() = (this as? Invalid)?.reason
    }

    fun parseOverride(text: String): OverrideInput {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return OverrideInput.Cleared
        if (trimmed.contains('.') || trimmed.contains(',')) {
            return OverrideInput.Invalid("Enter whole vines — part of a vine isn't a vine.")
        }
        val value = trimmed.toIntOrNull()
            ?: return OverrideInput.Invalid("Enter a whole number of vines.")
        return when {
            value <= 0 -> OverrideInput.Invalid("Enter a vine count greater than zero, or leave it blank.")
            value > MAX_OVERRIDE -> OverrideInput.Invalid("That's more than $MAX_OVERRIDE vines — check the number.")
            else -> OverrideInput.Valid(value)
        }
    }

    /**
     * The AUTOMATIC per-row estimate: row length ÷ vine spacing, truncated —
     * the identical rule `Paddock.estimatedVineCount` applies at block level.
     */
    fun calculated(rowLengthMetres: Double, vineSpacing: Double?): Int {
        val spacing = vineSpacing ?: return 0
        if (spacing <= 0 || !rowLengthMetres.isFinite() || rowLengthMetres <= 0) return 0
        return (rowLengthMetres / spacing).toInt()
    }

    /** THE rule: manual override wins, otherwise the calculated estimate. */
    fun effective(override: Int?, rowLengthMetres: Double, vineSpacing: Double?): Int {
        sanitiseOverride(override)?.let { return it }
        return calculated(rowLengthMetres, vineSpacing)
    }
}

/**
 * Row-identity preservation across block geometry regeneration — the Kotlin
 * twin of the Swift `PaddockRowRegeneration`.
 *
 * The block editor rebuilds every row from the boundary + direction + count on
 * each save. Before sql/188 that minted a BRAND NEW row id every time, which
 * silently detached anything keyed on row identity — pruning progress
 * (`pruning_row_segments.paddock_row_id`, sql/112) included.
 *
 * [preserveIdentity] re-attaches regenerated rows to the block's existing rows
 * by their REAL-WORLD row number — the identifier the grower actually uses and
 * the one the editor keeps stable — carrying across the existing stable row id
 * and the row's manual [PaddockRow.vineCountOverride].
 */
object PaddockRowRegeneration {

    /** Re-applies existing identity + manual counts onto freshly generated rows. */
    fun preserveIdentity(regenerated: List<PaddockRow>, existing: List<PaddockRow>): List<PaddockRow> {
        if (existing.isEmpty()) return regenerated
        val byNumber = LinkedHashMap<Int, PaddockRow>()
        existing.forEach { row -> byNumber.putIfAbsent(row.number, row) }
        return regenerated.map { row ->
            val match = byNumber[row.number] ?: return@map row
            row.copy(id = match.stableId, vineCountOverride = match.vineCountOverride)
        }
    }

    /**
     * Applies an edited map of manual counts (keyed by ROW NUMBER — stable
     * across regeneration) onto a set of rows. A number missing from the map
     * clears that row's override.
     */
    fun applyOverrides(overrides: Map<Int, Int>, rows: List<PaddockRow>): List<PaddockRow> =
        rows.map { row ->
            row.copy(vineCountOverride = PaddockRowVineCount.sanitiseOverride(overrides[row.number]))
        }

    /** Extracts the current manual counts keyed by row number. */
    fun overrides(rows: List<PaddockRow>): Map<Int, Int> =
        rows.mapNotNull { row -> row.vineCountOverride?.let { row.number to it } }.toMap()
}
