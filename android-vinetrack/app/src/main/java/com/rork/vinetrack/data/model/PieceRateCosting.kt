package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.roundToLong

/**
 * How a Work Task's labour cost is calculated (sql/188).
 *
 * Stored as a stable string on `work_tasks.costing_method`. It is the ONLY
 * switch — piece rate is never inferred from the presence of a rate, and the
 * two costing methods are never summed.
 */
enum class WorkTaskCostingMethod(val storedValue: String, val label: String) {
    /** The pre-existing behaviour: Σ `work_task_labour_lines.total_cost`. */
    HOURLY("hourly", "Hourly"),

    /** Snapshotted vine quantity × agreed rate per vine. */
    PIECE_RATE("piece_rate", "Piece Rate");

    companion object {
        /**
         * Decodes a stored value. EVERY legacy record — and anything
         * unrecognised written by a future client — resolves to [HOURLY],
         * which is exactly how those records have always behaved.
         */
        fun resolve(raw: String?): WorkTaskCostingMethod {
            val key = raw?.trim()?.lowercase().orEmpty()
            if (key.isEmpty()) return HOURLY
            return entries.firstOrNull { it.storedValue == key } ?: HOURLY
        }
    }
}

/**
 * One row's HISTORICAL vine-count snapshot behind a piece-rate job.
 * Mirrors `public.work_task_piece_rate_rows` (sql/188) and the iOS
 * `WorkTaskPieceRateRow`.
 *
 * This is not a row-selection system: the tracker derives these FROM the
 * existing pruning row selection. They exist so a completed job keeps the
 * quantity it was priced on even after the vineyard setup is edited.
 */
@Serializable
data class WorkTaskPieceRateRow(
    val id: String,
    @SerialName("work_task_id") val workTaskId: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("paddock_id") val paddockId: String,
    /** Logical reference into `paddocks.rows[].id`; null for manual rows. */
    @SerialName("paddock_row_id") val paddockRowId: String? = null,
    /** Display snapshot of the row number AT COSTING TIME. */
    @SerialName("row_number") val rowNumber: Int? = null,
    /** THE snapshotted quantity this row was paid on. */
    @SerialName("vine_count") val vineCount: Int = 0,
    @SerialName("deleted_at") val deletedAt: String? = null,
)

/**
 * THE piece-rate costing contract (sql/188) — the Kotlin twin of the Swift
 * `PieceRateCosting`. Both platforms MUST produce identical numbers from
 * identical backend data; the unit suites on each side assert the same
 * fixtures.
 *
 * ```text
 * labour cost = piece vine count × piece rate per vine
 *     2,238 vines × $1.27 = $2,842.26
 * ```
 *
 * Rules this object encodes:
 * * The task's labour cost comes from EXACTLY ONE source, chosen by
 *   `costing_method`. Hourly lines and the piece-rate total are never summed.
 * * Hours may still be recorded on a piece-rate job for operational history,
 *   but they NEVER drive its cost.
 * * A completed piece-rate job is costed from its SNAPSHOT
 *   (`piece_vine_count`, `piece_rate_per_vine`), never from today's rows.
 */
object PieceRateCosting {

    /** A rate above this is a typo, not an agreement. */
    const val MAX_RATE_PER_VINE: Double = 1_000.0

    /** A quantity above this is a typo, not a vineyard. */
    const val MAX_VINE_COUNT: Int = 10_000_000

    // ---------------------------------------------------------------------
    // Arithmetic
    // ---------------------------------------------------------------------

    /**
     * Rounds a money value to whole cents, half away from zero — the SAME rule
     * as the database's `round(numeric, 2)` and the Swift twin, so no platform
     * ever reports a cent that another does not.
     */
    fun roundedToCents(value: Double): Double {
        if (!value.isFinite()) return 0.0
        val scaled = value * 100
        // Kotlin's roundToLong is half-UP, which disagrees with Swift's
        // half-away-from-zero on negatives. Mirroring the sign keeps both
        // platforms (and the database) on the identical cent.
        val cents = if (scaled < 0) -((-scaled).roundToLong()) else scaled.roundToLong()
        return cents / 100.0
    }

    /**
     * `vineCount × ratePerVine`, rounded to cents.
     * Null when either side is missing — an absent agreement is "not
     * specified", never `$0.00`.
     */
    fun cost(vineCount: Int?, ratePerVine: Double?): Double? {
        if (vineCount == null || ratePerVine == null || !ratePerVine.isFinite()) return null
        return roundedToCents(vineCount.coerceAtLeast(0).toDouble() * ratePerVine.coerceAtLeast(0.0))
    }

    /**
     * Cost per hectare for a piece-rate job. Null when no positive area is
     * known — an unknown denominator must never render as a number.
     */
    fun costPerHectare(cost: Double?, hectares: Double?): Double? {
        if (cost == null || hectares == null || !hectares.isFinite() || hectares <= 0) return null
        return roundedToCents(cost / hectares)
    }

    // ---------------------------------------------------------------------
    // Quantity derived from the selected rows
    // ---------------------------------------------------------------------

    /**
     * The vine quantity a NEW job starts from: Σ [WorkTaskPieceRateRow.vineCount]
     * across the selected rows, so the operator never re-enters a total the
     * app already knows.
     */
    fun vineCountForSelectedRows(rows: List<WorkTaskPieceRateRow>): Int =
        rows.sumOf { it.vineCount.coerceAtLeast(0) }

    /**
     * Builds the historical snapshot rows for a job from a block's selected
     * rows. Called at create/update time ONLY — never on read.
     *
     * @param selectedRowIds stable ids of the rows included in this job; empty
     *   means "every row of the block".
     * @param newId supplies a fresh client-generated row id.
     */
    fun snapshotRows(
        workTaskId: String,
        vineyardId: String,
        paddock: Paddock,
        selectedRowIds: Set<String>,
        newId: () -> String,
    ): List<WorkTaskPieceRateRow> {
        val all = paddock.rows.orEmpty()
        val selected = if (selectedRowIds.isEmpty()) all else all.filter { selectedRowIds.contains(it.stableId) }
        return selected.sortedBy { it.number }.map { row ->
            WorkTaskPieceRateRow(
                id = newId(),
                workTaskId = workTaskId,
                vineyardId = vineyardId,
                paddockId = paddock.id,
                paddockRowId = row.stableId,
                rowNumber = row.number,
                vineCount = paddock.effectiveVineCount(row),
            )
        }
    }

    // ---------------------------------------------------------------------
    // Resolved labour cost
    // ---------------------------------------------------------------------

    /**
     * The ONE labour cost of a task under its selected method, plus the hours
     * recorded against it (kept for BOTH methods as operational history).
     */
    data class ResolvedCost(
        val method: WorkTaskCostingMethod,
        /** THE task's labour cost. Null = not specified. */
        val cost: Double?,
        val hours: Double,
        val vineCount: Int? = null,
        val ratePerVine: Double? = null,
    ) {
        /** True when hours exist but are explicitly not the basis of the cost. */
        val hoursAreOperationalOnly: Boolean
            get() = method == WorkTaskCostingMethod.PIECE_RATE && hours > 0
    }

    /**
     * Resolves the ONE labour cost of a task. Exactly one source contributes,
     * which is what stops a report adding an hourly total to a piece-rate one.
     */
    fun resolve(
        method: WorkTaskCostingMethod,
        labourLines: List<WorkTaskLabourLine>,
        pieceVineCount: Int?,
        pieceRatePerVine: Double?,
    ): ResolvedCost {
        val live = labourLines.filter { it.deletedAt == null }
        val hours = live.sumOf { it.resolvedHours }
        return when (method) {
            WorkTaskCostingMethod.HOURLY -> {
                val costed = live.filter { it.hourlyRate != null }
                ResolvedCost(
                    method = WorkTaskCostingMethod.HOURLY,
                    cost = if (costed.isEmpty()) null else costed.sumOf { it.resolvedCost },
                    hours = hours,
                )
            }
            WorkTaskCostingMethod.PIECE_RATE -> ResolvedCost(
                method = WorkTaskCostingMethod.PIECE_RATE,
                cost = cost(pieceVineCount, pieceRatePerVine),
                hours = hours,
                vineCount = pieceVineCount,
                ratePerVine = pieceRatePerVine,
            )
        }
    }

    /** Convenience: resolves straight from a stored task. */
    fun resolve(task: WorkTask, labourLines: List<WorkTaskLabourLine>): ResolvedCost = resolve(
        method = task.resolvedCostingMethod,
        labourLines = labourLines.filter { it.workTaskId == task.id },
        pieceVineCount = task.pieceVineCount,
        pieceRatePerVine = task.pieceRatePerVine,
    )

    // ---------------------------------------------------------------------
    // Validation
    // ---------------------------------------------------------------------

    enum class PieceRateField { RATE_PER_VINE, VINE_COUNT }

    data class PieceRateIssue(val field: PieceRateField, val message: String)

    /**
     * Inline validation for the piece-rate form. Returns EVERY problem so the
     * form can mark each field; an empty list means saveable.
     */
    fun validate(ratePerVine: Double?, vineCount: Int?): List<PieceRateIssue> {
        val issues = mutableListOf<PieceRateIssue>()

        if (ratePerVine == null || !ratePerVine.isFinite() || ratePerVine <= 0) {
            issues += PieceRateIssue(PieceRateField.RATE_PER_VINE, "Enter the agreed rate per vine.")
        } else if (ratePerVine > MAX_RATE_PER_VINE) {
            issues += PieceRateIssue(
                PieceRateField.RATE_PER_VINE,
                "That rate per vine looks too high — check the number.",
            )
        }

        if (vineCount == null || vineCount <= 0) {
            issues += PieceRateIssue(
                PieceRateField.VINE_COUNT,
                "Select the rows this job covers so the vine count can be calculated.",
            )
        } else if (vineCount > MAX_VINE_COUNT) {
            issues += PieceRateIssue(
                PieceRateField.VINE_COUNT,
                "That vine count looks too high — check the selected rows.",
            )
        }

        return issues
    }

    fun isValid(ratePerVine: Double?, vineCount: Int?): Boolean =
        validate(ratePerVine, vineCount).isEmpty()

    fun message(issues: List<PieceRateIssue>, field: PieceRateField): String? =
        issues.firstOrNull { it.field == field }?.message

    // ---------------------------------------------------------------------
    // Formatting (Australian currency, consistent with the app)
    // ---------------------------------------------------------------------

    /** `$2,842.26` — a money total, grouped and always 2 decimals. */
    fun currencyLabel(value: Double): String {
        val amount = BigDecimal(value).setScale(2, RoundingMode.HALF_UP)
        return "$" + String.format(java.util.Locale.US, "%,.2f", amount)
    }

    /** `$1.27` — the agreed rate, always 2 decimals. */
    fun rateLabel(value: Double): String =
        "$" + String.format(java.util.Locale.US, "%.2f", value)

    /** `2,238` — a vine quantity, grouped. */
    fun vineCountLabel(value: Int): String =
        String.format(java.util.Locale.US, "%,d", value)
}
