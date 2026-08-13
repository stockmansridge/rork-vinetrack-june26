package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.WorkTaskLabourLine

/**
 * THE authoritative labour-costing contract for Work Tasks — the Kotlin twin of
 * the Swift `WorkTaskLabourCosting`. Both platforms MUST produce identical
 * numbers from identical inputs; the unit suites on each side assert the same
 * fixtures.
 *
 * Ownership rule this object encodes:
 *
 *  * A **Work Task labour line** owns labour type, hourly rate, worker count,
 *    hours per worker, person-hours and labour cost. These are the ONLY
 *    authoritative source of labour cost.
 *  * A **Pruning Activity** owns operational output (date, blocks, rows,
 *    quarters, method, crew reference, vines, start/finish, elapsed duration,
 *    notes, `work_task_id`). It no longer offers an editable hourly rate.
 *
 * Legacy `pruning_activities.hourly_rate` / `labour_hours` values stay READABLE
 * for compatibility, but they are never combined with Work Task labour totals —
 * see [resolveLabour], which returns exactly one source.
 *
 * Arithmetic (mirrored in Swift):
 *
 *     person-hours = workerCount × hoursPerWorker
 *     line cost    = person-hours × hourlyRate
 *     task totals  = Σ line person-hours, Σ line costs
 *
 * An already-aggregated activity duration is NEVER multiplied again: elapsed
 * activity duration, hours per worker, and total person-hours are three
 * distinct quantities.
 */
object WorkTaskLabourCosting {

    // MARK: Bounds (shared with the standard Work Task form)

    /** A crew larger than this is a typo, not a vineyard. */
    const val MAX_WORKER_COUNT: Int = 500

    /** More than a full day per worker on one line is a typo. */
    const val MAX_HOURS_PER_WORKER: Double = 24.0

    /** Defensive upper bound on an hourly rate. */
    const val MAX_HOURLY_RATE: Double = 100_000.0

    // MARK: Line arithmetic

    /** `workerCount × hoursPerWorker`, floored at zero and never NaN/∞. */
    fun personHours(workerCount: Int, hoursPerWorker: Double): Double {
        if (!hoursPerWorker.isFinite()) return 0.0
        val count = workerCount.coerceAtLeast(0)
        val hours = hoursPerWorker.coerceAtLeast(0.0)
        return count.toDouble() * hours
    }

    /** `person-hours × hourlyRate`. A null rate means "cost not specified". */
    fun lineCost(workerCount: Int, hoursPerWorker: Double, hourlyRate: Double?): Double? {
        val rate = hourlyRate ?: return null
        if (!rate.isFinite()) return null
        return personHours(workerCount, hoursPerWorker) * rate.coerceAtLeast(0.0)
    }

    /** Person-hours of one stored line, preferring the DB-generated value. */
    fun personHours(line: WorkTaskLabourLine): Double {
        val stored = line.totalHours
        if (stored != null && stored.isFinite() && stored >= 0) return stored
        return personHours(line.workerCount, line.hoursPerWorker)
    }

    /**
     * Cost of one stored line. Null when neither a stored total nor a rate
     * exists — an absent rate is "not specified", never `$0.00`.
     */
    fun lineCost(line: WorkTaskLabourLine): Double? {
        val stored = line.totalCost
        if (stored != null && stored.isFinite()) return stored
        val rate = line.hourlyRate ?: return null
        if (!rate.isFinite()) return null
        return personHours(line) * rate.coerceAtLeast(0.0)
    }

    // MARK: Task totals

    /** Live (non-deleted) lines of one task, oldest first. */
    fun linesFor(lines: List<WorkTaskLabourLine>, workTaskId: String): List<WorkTaskLabourLine> =
        lines
            .filter { it.workTaskId == workTaskId && it.deletedAt == null }
            .sortedBy { it.workDate.orEmpty() }

    /** Σ person-hours across the given lines. */
    fun totalPersonHours(lines: List<WorkTaskLabourLine>): Double =
        lines.sumOf { personHours(it) }

    /**
     * Σ costs across the given lines. Null when NO line carries a cost at all,
     * so "not specified" never renders as zero. Lines without a rate contribute
     * nothing rather than blocking the total.
     */
    fun totalCost(lines: List<WorkTaskLabourLine>): Double? {
        var sum = 0.0
        var sawCost = false
        for (line in lines) {
            val cost = lineCost(line) ?: continue
            sum += cost
            sawCost = true
        }
        return if (sawCost) sum else null
    }

    /** Σ worker counts across the given lines. */
    fun totalWorkers(lines: List<WorkTaskLabourLine>): Int = lines.sumOf { it.workerCount.coerceAtLeast(0) }

    /** One task's totals in a single pass. */
    fun totals(lines: List<WorkTaskLabourLine>): LabourTotals = LabourTotals(
        lineCount = lines.size,
        workers = totalWorkers(lines),
        personHours = totalPersonHours(lines),
        cost = totalCost(lines),
    )

    // MARK: Legacy fallback (never double-counted)

    /**
     * Which source a pruning report must use for one activity's labour.
     *
     *  * [PIECE_RATE] — the linked task is costed per vine (sql/188). Its own
     *    snapshot IS the labour-cost record, so it wins outright and labour
     *    lines on the same task are operational history only.
     *  * [WORK_TASK_LINES] — the linked task has labour lines. Authoritative.
     *  * [LEGACY_ACTIVITY] — no labour lines exist; the activity's own historical
     *    `labour_hours` / `hourly_rate` are shown as legacy data.
     *  * [NONE] — nothing recorded.
     *
     * The value sources are mutually exclusive by construction, which is what
     * stops a report summing an activity rate AND its task's lines — or a
     * piece-rate total AND an hourly one.
     */
    enum class LabourSource { PIECE_RATE, WORK_TASK_LINES, LEGACY_ACTIVITY, NONE }

    data class LabourTotals(
        val lineCount: Int,
        val workers: Int,
        val personHours: Double,
        val cost: Double?,
    ) {
        val isEmpty: Boolean get() = lineCount == 0
    }

    data class ResolvedLabour(
        val source: LabourSource,
        /** Person-hours from labour lines, or the legacy activity hours. */
        val hours: Double?,
        /** Cost from labour lines, or the legacy activity hours × rate. */
        val cost: Double?,
        /** True when [hours]/[cost] come from pre-labour-line history. */
        val isLegacy: Boolean,
    )

    /**
     * Resolves ONE activity's labour, preferring Work Task labour lines and
     * falling back to the legacy activity-level values only when the task has no
     * lines at all. Exactly one source contributes, so no total can count labour
     * twice.
     *
     * @param lines every live labour line of the LINKED task (empty when the
     *   activity has no task, or the task has no lines).
     * @param legacyHours historical `pruning_activities.labour_hours`.
     * @param legacyRate historical `pruning_activities.hourly_rate`.
     * @param includeCost false hides every monetary value for roles without
     *   costing visibility (hours are still returned).
     */
    fun resolveLabour(
        lines: List<WorkTaskLabourLine>,
        legacyHours: Double?,
        legacyRate: Double?,
        includeCost: Boolean = true,
    ): ResolvedLabour {
        val live = lines.filter { it.deletedAt == null }
        if (live.isNotEmpty()) {
            val hours = totalPersonHours(live)
            return ResolvedLabour(
                source = LabourSource.WORK_TASK_LINES,
                hours = hours.takeIf { it > 0 },
                cost = if (includeCost) totalCost(live) else null,
                isLegacy = false,
            )
        }
        val hours = legacyHours?.takeIf { it.isFinite() && it > 0 }
        val rate = legacyRate?.takeIf { it.isFinite() && it > 0 }
        if (hours == null && rate == null) {
            return ResolvedLabour(LabourSource.NONE, null, null, isLegacy = false)
        }
        return ResolvedLabour(
            source = LabourSource.LEGACY_ACTIVITY,
            hours = hours,
            cost = if (includeCost && hours != null && rate != null) hours * rate else null,
            isLegacy = true,
        )
    }

    /**
     * Per-task labour cost map from labour lines ONLY.
     *
     * This answers "what do this task's labour lines cost?", NOT "what is this
     * task's labour cost?". A piece-rate task legitimately has no labour lines,
     * so any caller that means the latter must use
     * [com.rork.vinetrack.data.model.PieceRateCosting.effectiveCostsByWorkTask],
     * which applies the `costing_method` switch first.
     */
    fun costsByWorkTask(
        lines: List<WorkTaskLabourLine>,
        includeCost: Boolean = true,
    ): Map<String, Double> {
        if (!includeCost) return emptyMap()
        return lines
            .filter { it.deletedAt == null }
            .groupBy { it.workTaskId }
            .mapNotNull { (taskId, group) -> totalCost(group)?.let { taskId to it } }
            .toMap()
    }

    /** Per-task person-hours map for the Activity Report, built in ONE pass. */
    fun hoursByWorkTask(lines: List<WorkTaskLabourLine>): Map<String, Double> = lines
        .filter { it.deletedAt == null }
        .groupBy { it.workTaskId }
        .mapValues { (_, group) -> totalPersonHours(group) }
        .filterValues { it > 0 }

    // MARK: Defaults

    /**
     * The rate a newly selected labour type supplies. The saved worker-type
     * cost is the default; an explicit edit always wins.
     */
    fun defaultRate(category: OperatorCategory?): Double? =
        category?.costPerHour?.takeIf { it.isFinite() && it > 0 }

    // MARK: Validation

    enum class LabourLineField { LABOUR_TYPE, WORKER_COUNT, HOURS_PER_WORKER, HOURLY_RATE }

    data class LabourLineIssue(val field: LabourLineField, val message: String)

    /**
     * Inline validation for one labour line. Returns EVERY problem so the form
     * can mark each field; an empty list means saveable. The caller must keep
     * the entered values on failure — nothing here discards input.
     *
     * Rules (identical on iOS):
     *  * a labour type is required (a linked worker type or a typed name),
     *  * worker count > 0 and ≤ [MAX_WORKER_COUNT],
     *  * hours per worker > 0 and ≤ [MAX_HOURS_PER_WORKER],
     *  * hourly rate, when given, ≥ 0 and ≤ [MAX_HOURLY_RATE],
     *  * every numeric value must be finite.
     */
    fun validate(
        labourType: String,
        workerCount: Int?,
        hoursPerWorker: Double?,
        hourlyRate: Double?,
        rateProvided: Boolean = hourlyRate != null,
    ): List<LabourLineIssue> {
        val issues = mutableListOf<LabourLineIssue>()

        if (labourType.trim().isEmpty()) {
            issues += LabourLineIssue(LabourLineField.LABOUR_TYPE, "Choose a labour type.")
        }

        when {
            workerCount == null ->
                issues += LabourLineIssue(LabourLineField.WORKER_COUNT, "Enter how many people worked.")
            workerCount <= 0 ->
                issues += LabourLineIssue(LabourLineField.WORKER_COUNT, "At least one person is needed.")
            workerCount > MAX_WORKER_COUNT ->
                issues += LabourLineIssue(
                    LabourLineField.WORKER_COUNT,
                    "That is more than $MAX_WORKER_COUNT people — check the number.",
                )
        }

        when {
            hoursPerWorker == null || !hoursPerWorker.isFinite() ->
                issues += LabourLineIssue(LabourLineField.HOURS_PER_WORKER, "Enter the hours each person worked.")
            hoursPerWorker <= 0.0 ->
                issues += LabourLineIssue(LabourLineField.HOURS_PER_WORKER, "Hours must be more than zero.")
            hoursPerWorker > MAX_HOURS_PER_WORKER ->
                issues += LabourLineIssue(
                    LabourLineField.HOURS_PER_WORKER,
                    "One person cannot work more than ${MAX_HOURS_PER_WORKER.toInt()} hours in a day.",
                )
        }

        if (rateProvided) {
            when {
                hourlyRate == null || !hourlyRate.isFinite() ->
                    issues += LabourLineIssue(LabourLineField.HOURLY_RATE, "Enter a valid hourly rate.")
                hourlyRate < 0.0 ->
                    issues += LabourLineIssue(LabourLineField.HOURLY_RATE, "An hourly rate cannot be negative.")
                hourlyRate > MAX_HOURLY_RATE ->
                    issues += LabourLineIssue(LabourLineField.HOURLY_RATE, "That hourly rate looks too high.")
            }
        }

        return issues
    }

    fun isValid(
        labourType: String,
        workerCount: Int?,
        hoursPerWorker: Double?,
        hourlyRate: Double?,
        rateProvided: Boolean = hourlyRate != null,
    ): Boolean = validate(labourType, workerCount, hoursPerWorker, hourlyRate, rateProvided).isEmpty()

    fun message(issues: List<LabourLineIssue>, field: LabourLineField): String? =
        issues.firstOrNull { it.field == field }?.message
}
