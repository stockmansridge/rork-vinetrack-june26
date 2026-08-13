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

    // ---- The automatic calculation ----

    /**
     * Why a row has no calculated vine count. There are exactly two reasons,
     * and each one names the single thing the grower must fix.
     */
    enum class Unavailable(val message: String) {
        /** The block has no usable vine spacing. */
        MISSING_VINE_SPACING("Set vine spacing in block details to calculate vines."),

        /** The row has no usable length (unmapped or zero-length geometry). */
        INVALID_GEOMETRY("Map this row on the block boundary to calculate vines."),
    }

    /**
     * The outcome of the automatic calculation. Modelled explicitly so "we
     * cannot calculate this" can never be confused with "this row has no
     * vines" — a `0` would be a lie about the vineyard.
     */
    sealed interface Calculation {
        data class Available(val vines: Int) : Calculation
        data class Missing(val reason: Unavailable) : Calculation

        /** The vine count when one could be calculated, else null. */
        val value: Int? get() = (this as? Available)?.vines

        /** The reason there is no number, else null. */
        val unavailable: Unavailable? get() = (this as? Missing)?.reason

        /** The subtle hint to show beside a "—", else null. */
        val message: String? get() = unavailable?.message
    }

    /**
     * Rounds a raw vines-per-row quotient to whole vines, half away from zero
     * — the SAME rule as the Swift twin, so the two platforms can never report
     * a different vine.
     *
     * Deliberately NOT `kotlin.math.round`: that delegates to `Math.rint`,
     * which breaks ties to the EVEN integer, so a 249.75 m row at 1.5 m
     * spacing (exactly 166.5) would report 166 vines on Android and 167 on
     * iOS. `floor(magnitude + 0.5)` with the sign mirrored back on is the
     * exact equivalent of Swift's `.toNearestOrAwayFromZero`.
     */
    fun roundVines(raw: Double): Int {
        if (!raw.isFinite()) return 0
        val magnitude = kotlin.math.floor(kotlin.math.abs(raw) + 0.5)
        val whole = magnitude.coerceAtMost(Int.MAX_VALUE.toDouble()).toInt()
        return if (raw < 0) -whole else whole
    }

    /**
     * THE automatic per-row estimate, with its reason when it cannot be made:
     *
     * ```text
     * calculatedVineCount = round(row length in metres / vine spacing in metres)
     *     250 m / 1.5 m = 166.67 -> 167 vines
     * ```
     *
     * Both inputs come from data the app already holds — the row's own
     * start/end geometry and the BLOCK's vine spacing — so a grower never has
     * to type anything to get a vine count.
     *
     * Note this is the ROW rule. The block-level `Paddock.estimatedVineCount`
     * keeps its own long-standing truncation of the block's total row length;
     * the two are deliberately independent (see sql/188).
     */
    fun calculation(rowLengthMetres: Double, vineSpacing: Double?): Calculation {
        if (vineSpacing == null || !vineSpacing.isFinite() || vineSpacing <= 0) {
            return Calculation.Missing(Unavailable.MISSING_VINE_SPACING)
        }
        if (!rowLengthMetres.isFinite() || rowLengthMetres <= 0) {
            return Calculation.Missing(Unavailable.INVALID_GEOMETRY)
        }
        return Calculation.Available(roundVines(rowLengthMetres / vineSpacing))
    }

    /**
     * The automatic per-row estimate, or null when it genuinely cannot be
     * calculated. NEVER returns 0 as a stand-in for "unknown".
     */
    fun calculated(rowLengthMetres: Double, vineSpacing: Double?): Int? =
        calculation(rowLengthMetres, vineSpacing).value

    /**
     * THE rule: manual override wins, otherwise the calculated estimate.
     * Null only when there is no override AND no calculable estimate.
     */
    fun effective(override: Int?, rowLengthMetres: Double, vineSpacing: Double?): Int? {
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
