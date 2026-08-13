package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PieceRateCosting
import com.rork.vinetrack.data.model.PruningActivityLabourLine
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskLabourLine

/**
 * THE authoritative labour contract for PRUNING ACTIVITIES (sql/190) — the
 * Kotlin twin of the Swift `PruningActivityLabourCosting`. Both platforms MUST
 * produce identical numbers from identical inputs; the unit suites on each side
 * assert the same fixtures, and those fixtures match the SQL suite.
 *
 * ## Ownership
 *
 * Labour is **PRUNING-OWNED**. A linked Work Task never gets a copy of these
 * rows; it resolves *through* to them. One stored set, two readers, identical
 * number — which is what stops the same money existing twice.
 *
 * Labour belongs to the ACTIVITY and is counted ONCE regardless of how many
 * blocks the activity covers. Nothing here is ever apportioned per block.
 *
 * ## Hours vs cost — two deliberately different rules
 *
 *  * **Hours** sum EVERY active line, including unrated ones. An unpriced line
 *    is still work that was done and still drives vines-per-hour.
 *  * **Cost** sums only lines that carry a rate. The SQL `total_cost` column is
 *    generated with `coalesce(hourly_rate, 0)`, so summing blindly would turn
 *    "nobody entered a rate" into `$0.00`. Unknown is **null**, never `0`.
 */
object PruningActivityLabourCosting {

    // ---------------------------------------------------------------------
    // Line arithmetic
    // ---------------------------------------------------------------------

    /** `workerCount × hoursPerWorker`, floored at zero and never NaN/∞. */
    fun personHours(workerCount: Int, hoursPerWorker: Double): Double {
        if (!hoursPerWorker.isFinite()) return 0.0
        return workerCount.coerceAtLeast(0).toDouble() * hoursPerWorker.coerceAtLeast(0.0)
    }

    /** Person-hours of one stored line. */
    fun personHours(line: PruningActivityLabourLine): Double = line.resolvedHours

    /**
     * Cost of one stored line. Null when the line carries no rate — an absent
     * rate is "not specified", never `$0.00`.
     */
    fun lineCost(line: PruningActivityLabourLine): Double? {
        val rate = line.hourlyRate ?: return null
        if (!rate.isFinite()) return null
        return personHours(line) * rate.coerceAtLeast(0.0)
    }

    // ---------------------------------------------------------------------
    // Activity totals
    // ---------------------------------------------------------------------

    /**
     * The live lines of ONE activity, in stable display order.
     *
     * Ordered by `lineIndex` first — exactly like
     * `pruning_activity_labour_lines_json` — so a crew list cannot reshuffle
     * between devices.
     */
    fun linesFor(
        lines: List<PruningActivityLabourLine>,
        activityId: String,
    ): List<PruningActivityLabourLine> = lines
        .filter { it.pruningActivityId == activityId && it.deletedAt == null }
        .sortedWith(compareBy({ it.lineIndex }, { it.workDate.orEmpty() }))

    /**
     * Σ person-hours across EVERY given line, rated or not — the Kotlin twin of
     * `pruning_activity_labour_line_hours`. Null when there is no line at all.
     */
    fun totalHours(lines: List<PruningActivityLabourLine>): Double? {
        val live = lines.filter { it.deletedAt == null }
        if (live.isEmpty()) return null
        return live.sumOf { personHours(it) }
    }

    /**
     * Σ costs across the RATED lines only — the Kotlin twin of
     * `pruning_activity_labour_line_cost`. Null (never `0.00`) when no line
     * carries a rate, so "not specified" can never render as zero.
     */
    fun totalCost(lines: List<PruningActivityLabourLine>): Double? {
        var sum = 0.0
        var sawCost = false
        for (line in lines.filter { it.deletedAt == null }) {
            val cost = lineCost(line) ?: continue
            sum += cost
            sawCost = true
        }
        return if (sawCost) sum else null
    }

    /** Σ worker counts across the given lines. */
    fun totalWorkers(lines: List<PruningActivityLabourLine>): Int =
        lines.filter { it.deletedAt == null }.sumOf { it.workerCount.coerceAtLeast(0) }

    data class LabourTotals(
        val lineCount: Int,
        val workers: Int,
        /** Hours of EVERY active line, including unrated ones. */
        val personHours: Double,
        /** Cost of the RATED lines only. Null means "not specified". */
        val cost: Double?,
    ) {
        val isEmpty: Boolean get() = lineCount == 0
    }

    /** One activity's own line totals in a single pass. */
    fun totals(lines: List<PruningActivityLabourLine>): LabourTotals {
        val live = lines.filter { it.deletedAt == null }
        return LabourTotals(
            lineCount = live.size,
            workers = totalWorkers(live),
            personHours = totalHours(live) ?: 0.0,
            cost = totalCost(live),
        )
    }

    // ---------------------------------------------------------------------
    // Effective resolution — precedence, never addition
    // ---------------------------------------------------------------------

    /**
     * Which source an activity's labour figure came from — the Kotlin twin of
     * `pruning_activity_labour_cost_source`.
     *
     * The cases are mutually exclusive by construction, which is what stops a
     * report adding an activity's lines to a linked task's, or a piece-rate
     * total to an hourly one.
     */
    enum class Source {
        /** A linked piece-rate task's snapshot total (sql/188). */
        PIECE_RATE,

        /** The activity's OWN labour lines (sql/190). */
        PRUNING_LABOUR_LINES,

        /** The linked hourly task's labour lines (sql/189). */
        WORK_TASK_LINES,

        /** The activity's legacy `labour_hours` × `hourly_rate` (sql/166). */
        ACTIVITY_HOURS,

        /** Nothing recorded. */
        NONE,
    }

    data class Resolved(
        val source: Source,
        /**
         * Total labour hours of the activity. Present even on a piece-rate job,
         * where hours are operational history that never moves the cost.
         */
        val hours: Double?,
        /** THE labour cost of the activity. Null means "not specified". */
        val cost: Double?,
        /** True when the figures come from pre-SQL-190 history. */
        val isLegacy: Boolean,
        /**
         * How many labour lines the ACTIVITY itself owns. 0 means the activity
         * is legacy/single-crew and resolved further down the chain.
         */
        val lineCount: Int,
    )

    /**
     * Effective HOURS of an activity — the Kotlin twin of
     * `pruning_activity_effective_labour_hours`.
     *
     * The activity's own lines when it owns any, otherwise the legacy scalar.
     * Precedence, never addition: the legacy scalar and the lines are two
     * representations of the SAME hours.
     */
    fun effectiveHours(
        activityLines: List<PruningActivityLabourLine>,
        legacyHours: Double?,
    ): Double? {
        totalHours(activityLines)?.let { return it }
        return legacyHours?.takeIf { it.isFinite() && it > 0 }
    }

    /**
     * **THE** effective labour cost and hours of one pruning activity — the
     * Kotlin twin of `pruning_activity_effective_labour_cost`.
     *
     * Strict precedence, never addition:
     *
     *  1. a linked **piece-rate** task → its snapshot total. No fallback: an
     *     unpriced piece-rate job is "not specified", and falling back to hours
     *     would report an HOURLY figure for a piece-rate job.
     *  2. the activity's **own rated labour lines** (sql/190),
     *  3. the linked **hourly task's** rated labour lines (sql/189),
     *  4. the activity's legacy `labour_hours × hourly_rate` (sql/166).
     *
     * @param includeCost false hides every monetary value for roles without
     *   costing visibility. Hours are still returned.
     */
    fun resolve(
        task: WorkTask?,
        activityLines: List<PruningActivityLabourLine>,
        taskLines: List<WorkTaskLabourLine>,
        legacyHours: Double?,
        legacyRate: Double?,
        includeCost: Boolean = true,
    ): Resolved {
        val liveActivity = activityLines.filter { it.deletedAt == null }
        val liveTask = taskLines.filter { it.deletedAt == null }
        val lineCount = liveActivity.size
        // Hours are resolved ONCE, independently of the cost branch: a
        // piece-rate job still records hours for productivity, and an unrated
        // line is still work that was done.
        val ownHours = totalHours(liveActivity)

        // 1. A linked piece-rate task IS the cost.
        if (task != null && task.isPieceRate) {
            val resolved = PieceRateCosting.resolve(task, liveTask)
            val hours = ownHours
                ?: resolved.hours.takeIf { it > 0 }
                ?: legacyHours?.takeIf { it.isFinite() && it > 0 }
            return Resolved(
                source = Source.PIECE_RATE,
                hours = hours,
                cost = if (includeCost) resolved.cost else null,
                isLegacy = false,
                lineCount = lineCount,
            )
        }

        // 2. The activity's OWN rated labour lines.
        totalCost(liveActivity)?.let { cost ->
            return Resolved(
                source = Source.PRUNING_LABOUR_LINES,
                hours = ownHours,
                cost = if (includeCost) cost else null,
                isLegacy = false,
                lineCount = lineCount,
            )
        }

        // The activity owns lines but none of them carry a rate. Hours are real
        // and reported; the cost is genuinely "not specified" — it must NOT fall
        // through to a linked task or a legacy rate, because these lines ARE the
        // labour record for this activity.
        if (lineCount > 0) {
            return Resolved(
                source = Source.PRUNING_LABOUR_LINES,
                hours = ownHours,
                cost = null,
                isLegacy = false,
                lineCount = lineCount,
            )
        }

        // 3. The linked hourly task's rated labour lines.
        if (task != null && liveTask.isNotEmpty()) {
            val hours = WorkTaskLabourCosting.totalPersonHours(liveTask)
            return Resolved(
                source = Source.WORK_TASK_LINES,
                hours = hours.takeIf { it > 0 },
                cost = if (includeCost) WorkTaskLabourCosting.totalCost(liveTask) else null,
                isLegacy = false,
                lineCount = 0,
            )
        }

        // 4. The legacy scalar pair.
        val hours = legacyHours?.takeIf { it.isFinite() && it > 0 }
        val rate = legacyRate?.takeIf { it.isFinite() && it > 0 }
        if (hours == null && rate == null) {
            return Resolved(Source.NONE, null, null, isLegacy = false, lineCount = 0)
        }
        return Resolved(
            source = Source.ACTIVITY_HOURS,
            hours = hours,
            cost = if (includeCost && hours != null && rate != null) hours * rate else null,
            isLegacy = true,
            lineCount = 0,
        )
    }

    // ---------------------------------------------------------------------
    // Work task side — read THROUGH, never a copy
    // ---------------------------------------------------------------------

    /**
     * Rated labour-line total of the PRUNING ACTIVITY linked to a work task —
     * the Kotlin twin of `work_task_pruning_labour_line_cost`.
     *
     * Used only as a fallback so a pruning-linked task reports the activity's
     * labour instead of null. The rows live in exactly ONE place; this is a
     * read-through, never a copy.
     */
    fun pruningLineCostForWorkTask(
        workTaskId: String,
        activities: List<com.rork.vinetrack.data.model.PruningActivityDraft>,
        activityLines: List<PruningActivityLabourLine>,
    ): Double? {
        val linkedIds = activities
            .filter { it.workTaskId == workTaskId && !it.isReversed }
            .map { it.id }
            .toSet()
        if (linkedIds.isEmpty()) return null
        return totalCost(activityLines.filter { it.pruningActivityId in linkedIds })
    }

    /**
     * **THE** effective labour cost of a work task under SQL 189 + SQL 190:
     *
     *  1. `piece_rate` → `piece_rate_total_cost`,
     *  2. else its OWN rated labour lines,
     *  3. else the rated labour lines of the pruning activity linked to it.
     *
     * Rung 3 only ever turns a null into a value, so no pre-190 record changes.
     * Never summed. Null means "not specified", never `$0.00`.
     */
    fun effectiveWorkTaskCost(
        task: WorkTask,
        taskLines: List<WorkTaskLabourLine>,
        activities: List<com.rork.vinetrack.data.model.PruningActivityDraft>,
        activityLines: List<PruningActivityLabourLine>,
    ): Double? {
        if (task.isPieceRate) return PieceRateCosting.resolve(task, taskLines).cost
        WorkTaskLabourCosting.totalCost(taskLines.filter { it.deletedAt == null })?.let { return it }
        return pruningLineCostForWorkTask(task.id, activities, activityLines)
    }

    // ---------------------------------------------------------------------
    // Conversion of a legacy activity
    // ---------------------------------------------------------------------

    /**
     * Builds the ONE labour line that represents a legacy activity's scalar crew
     * record, for the explicit "convert to labour lines" action.
     *
     * Never called automatically. `worker_or_crew` is free text ("Dave + 2
     * casuals") and neither the database nor this client can honestly split it
     * into a worker type and a crew size, so the user confirms the result — the
     * crew text becomes the worker TYPE and the count defaults to one, which
     * preserves the recorded hours exactly.
     */
    fun legacyConversionLine(
        lineId: String,
        activityId: String,
        vineyardId: String,
        workDate: String?,
        workerOrCrew: String,
        legacyHours: Double?,
        legacyRate: Double?,
    ): PruningActivityLabourLine? {
        val hours = legacyHours?.takeIf { it.isFinite() && it > 0 } ?: return null
        val trimmed = workerOrCrew.trim()
        return PruningActivityLabourLine(
            id = lineId,
            pruningActivityId = activityId,
            vineyardId = vineyardId,
            workDate = workDate,
            workerType = trimmed.ifBlank { "Labour" },
            // One "worker" doing all the recorded hours reproduces the legacy
            // total exactly: 1 × 7.5 h × $32 = $240, the pre-190 figure.
            workerCount = 1,
            hoursPerWorker = hours,
            hourlyRate = legacyRate?.takeIf { it.isFinite() && it > 0 },
            notes = "Converted from the original crew record.",
            lineIndex = 0,
        )
    }

    // ---------------------------------------------------------------------
    // Validation
    // ---------------------------------------------------------------------

    /**
     * Validation is IDENTICAL to a Work Task labour line — the two tables mirror
     * each other, so one rule set serves both and the editors cannot drift
     * apart.
     */
    fun validate(
        labourType: String,
        workerCount: Int?,
        hoursPerWorker: Double?,
        hourlyRate: Double?,
        rateProvided: Boolean = hourlyRate != null,
    ): List<WorkTaskLabourCosting.LabourLineIssue> =
        WorkTaskLabourCosting.validate(labourType, workerCount, hoursPerWorker, hourlyRate, rateProvided)

    fun isValid(
        labourType: String,
        workerCount: Int?,
        hoursPerWorker: Double?,
        hourlyRate: Double?,
        rateProvided: Boolean = hourlyRate != null,
    ): Boolean = validate(labourType, workerCount, hoursPerWorker, hourlyRate, rateProvided).isEmpty()
}
