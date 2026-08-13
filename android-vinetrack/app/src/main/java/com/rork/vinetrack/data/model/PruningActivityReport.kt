package com.rork.vinetrack.data.model

import java.time.LocalDate

/**
 * SHARED CONTRACT — the Pruning Activity Report.
 *
 * iOS and Android build the SAME rows, from the SAME server-authoritative
 * pruning entries, with the SAME column set, status rules, filter meanings,
 * sort defaults and summary maths. Anything added here must be mirrored in
 * `PruningActivityReport.swift`.
 *
 * The report NEVER re-interprets pruning records: rows are projected from the
 * existing [PruningEntry] cache (the same data the tracker, the dashboard and
 * the SQL 115 parity check use) plus the block, Work Task and labour-line
 * context the app already holds.
 */

/**
 * Lifecycle of one pruning record.
 *
 * [Edited] is derived from the server's own `updated_at` vs `created_at` —
 * never invented. An entry that has not been pulled back from the server yet
 * (no `updated_at`) is [Active].
 */
enum class PruningActivityStatus(val label: String) {
    Active("Active"),
    Edited("Edited"),
    Reversed("Reversed");

    /** Reversed work is audit history only — never part of an active total. */
    val countsTowardsTotals: Boolean get() = this != Reversed

    companion object {
        /**
         * Tolerance between `created_at` and `updated_at` below which a record
         * counts as untouched — a create writes both stamps in the same
         * statement, so they can differ by microseconds.
         */
        const val EDITED_TOLERANCE_MS: Long = 2_000

        fun resolve(reversedAtMs: Long, createdAtMs: Long, updatedAtMs: Long): PruningActivityStatus = when {
            reversedAtMs > 0L -> Reversed
            createdAtMs <= 0L || updatedAtMs <= 0L -> Active
            updatedAtMs - createdAtMs > EDITED_TOLERANCE_MS -> Edited
            else -> Active
        }
    }
}

/**
 * Block context the report needs for one paddock — resolved ONCE per block so
 * a large history never triggers per-record lookups (no N+1).
 */
data class PruningActivityBlockContext(
    val name: String,
    val variety: String?,
    /** The block's actual rows, used to convert quarters into exact vines. */
    val rows: List<PruningRowRef>,
)

/**
 * One fully-resolved report row. Every null is genuinely unavailable for that
 * record and renders as "—" — never as a misleading zero.
 */
data class PruningActivityRow(
    val id: String,
    val paddockId: String,
    val workTaskId: String?,
    /**
     * The PARENT activity this row is one allocation of (sql/166). A legacy
     * single-block record is its own activity, so this is never blank and
     * grouping by it is safe for every record ever written.
     */
    val activityKey: String = id,
    /** 0 for the PRIMARY allocation — the one carrying the activity's labour. */
    val allocationIndex: Int = 0,
    /** Pruning season (calendar year of the entry date). */
    val seasonYear: Int,
    val date: LocalDate?,
    /** Raw ISO date, kept so a malformed stored date still sorts and displays. */
    val dateIso: String,
    val worker: String?,
    val blockName: String,
    val variety: String?,
    /** Distinct row numbers touched by this record, ascending (natural order). */
    val rowNumbers: List<Int>,
    /** Quarters (row sections) completed by this record. */
    val quarters: Int,
    val rowEquivalents: Double,
    /** Exact vines completed — null when the block's rows can't be resolved. */
    val vines: Double?,
    /** This allocation's own client vine estimate, as recorded. */
    val estimatedVines: Int = 0,
    /**
     * The RESOLVED authoritative labour hours: summed Work Task labour lines
     * when the linked task has any, otherwise the legacy activity value. Never
     * both — see [PruningActivityReport.rows].
     */
    val labourHours: Double?,
    /**
     * The activity's OWN recorded operational hours, independent of the Work
     * Task's person-hours. Elapsed operational time is not person-hours and is
     * never multiplied by the crew size.
     */
    val operationalHours: Double? = null,
    /** HH:mm, as recorded. */
    val startTime: String?,
    val finishTime: String?,
    val durationHours: Double?,
    val vinesPerHour: Double?,
    /**
     * EFFECTIVE labour cost of the linked Work Task — the piece-rate snapshot
     * total for a per-vine job, the labour-line total for an hourly one. Null
     * when nothing was recorded or costing is not visible to this user.
     */
    val labourCost: Double?,
    /**
     * SNAPSHOT vine quantity the linked piece-rate job was priced on. Null for
     * hourly and legacy records. Never today's vineyard geometry.
     */
    val pieceRateVines: Int? = null,
    val workTaskTitle: String?,
    val workTaskStatus: String? = null,
    val notes: String?,
    val enteredBy: String?,
    val createdAtMs: Long?,
    val updatedAtMs: Long?,
    val method: String,
    val status: PruningActivityStatus,
) {
    val isReversed: Boolean get() = status == PruningActivityStatus.Reversed
    val hasWorkTask: Boolean get() = workTaskId != null

    /**
     * True when this row carries the activity's own labour/timing/task link —
     * the PRIMARY allocation. Activity-level values are written to exactly one
     * allocation, which is why an export can never double-count them.
     */
    val isPrimaryAllocation: Boolean get() = allocationIndex == 0

    /** Lowest row number — the natural sort key ("Row 2" before "Row 10"). */
    val rowSortKey: Int? get() = rowNumbers.minOrNull()

    /** "5" or "5–12" from the ACTUAL row numbers. */
    val rowRangeLabel: String?
        get() {
            val low = rowNumbers.minOrNull() ?: return null
            val high = rowNumbers.maxOrNull() ?: return null
            return if (low == high) "$low" else "$low–$high"
        }

    val quartersLabel: String? get() = if (quarters > 0) "$quarters" else null

    /**
     * Cost per vine for a piece-rate job, from the HISTORICAL snapshot quantity
     * — `$137.50 / 250 = $0.55`, which reproduces the agreed rate. Null for
     * hourly and legacy records.
     */
    val costPerVine: Double? get() = PieceRateCosting.costPerVine(labourCost, pieceRateVines)

    /** Minutes since midnight — times sort as times, never as strings. */
    val startMinutes: Int? get() = minutesOf(startTime)
    val finishMinutes: Int? get() = minutesOf(finishTime)

    private fun minutesOf(value: String?): Int? {
        val parts = value?.split(":") ?: return null
        if (parts.size < 2) return null
        val hour = parts[0].toIntOrNull() ?: return null
        val minute = parts[1].take(2).toIntOrNull() ?: return null
        return hour * 60 + minute
    }
}

/** The report's column set. Identical labels and order on both platforms. */
enum class PruningActivityColumn(val key: String, val label: String) {
    Date("date", "Date"),
    Worker("worker", "Worker"),
    Block("block", "Block"),
    Variety("variety", "Variety"),
    Rows("rows", "Rows"),
    Quarters("quarters", "Quarters"),
    Vines("vines", "Vines"),
    Hours("hours", "Hours"),
    Start("start", "Start"),
    Finish("finish", "Finish"),
    Duration("duration", "Duration"),
    VinesPerHour("vinesPerHour", "Vines / hr"),
    LabourCost("labourCost", "Labour cost"),
    WorkTask("workTask", "Work Task"),
    Notes("notes", "Notes"),
    EnteredBy("enteredBy", "Entered by"),
    Created("created", "Created"),
    Updated("updated", "Updated"),
    Status("status", "Status");

    /** Notes is free text with no meaningful order — everything else sorts. */
    val isSortable: Boolean get() = this != Notes

    /** Costing columns are hidden from roles without costing visibility. */
    val isCosting: Boolean get() = this == LabourCost

    companion object {
        /**
         * The first columns are the most useful operational fields; the rest
         * continue horizontally in this order.
         */
        val displayOrder: List<PruningActivityColumn> = listOf(
            Date, Worker, Block, Rows, Vines, Hours, Status,
            Variety, Quarters, Start, Finish, Duration, VinesPerHour,
            LabourCost, WorkTask, EnteredBy, Created, Updated, Notes,
        )

        fun fromKey(key: String?): PruningActivityColumn? =
            entries.firstOrNull { it.key == key }
    }
}

enum class PruningActivitySortDirection { None, Ascending, Descending }

/** Tri-state sort: unsorted → ascending → descending → unsorted. */
data class PruningActivitySort(
    /** Null = the default order (date descending, then created descending). */
    val column: PruningActivityColumn? = null,
    val ascending: Boolean = false,
) {
    /** Cycles the state for a tapped heading. */
    fun cycled(tapped: PruningActivityColumn): PruningActivitySort = when {
        column != tapped -> PruningActivitySort(tapped, ascending = true)
        ascending -> PruningActivitySort(tapped, ascending = false)
        else -> DEFAULT
    }

    fun direction(candidate: PruningActivityColumn): PruningActivitySortDirection = when {
        column != candidate -> PruningActivitySortDirection.None
        ascending -> PruningActivitySortDirection.Ascending
        else -> PruningActivitySortDirection.Descending
    }

    companion object {
        val DEFAULT = PruningActivitySort()
    }
}

enum class PruningActivityTaskLink(val label: String) {
    All("All"),
    Linked("Linked"),
    NotLinked("Not linked"),
}

/** Report filters. An EMPTY set means "no restriction" for that facet. */
data class PruningActivityFilter(
    val seasonYear: Int? = null,
    /** ISO yyyy-MM-dd bounds, inclusive. */
    val dateFrom: String? = null,
    val dateTo: String? = null,
    val workers: Set<String> = emptySet(),
    val blocks: Set<String> = emptySet(),
    val varieties: Set<String> = emptySet(),
    val statuses: Set<PruningActivityStatus> = emptySet(),
    val taskLink: PruningActivityTaskLink = PruningActivityTaskLink.All,
    val search: String = "",
) {
    /**
     * True when anything other than the default season is applied — drives the
     * "Clear filters" affordance.
     */
    val hasRestrictions: Boolean
        get() = dateFrom != null || dateTo != null || workers.isNotEmpty() || blocks.isNotEmpty() ||
            varieties.isNotEmpty() || statuses.isNotEmpty() ||
            taskLink != PruningActivityTaskLink.All || search.isNotBlank()
}

/**
 * Totals for the CURRENT filtered result. Reversed rows never contribute to
 * vines, hours, productivity or cost — they are counted separately.
 *
 * There are TWO labour figures and they answer different questions:
 *
 *  * [labourHours] / [labourCost] are ALLOCATED — the proportional share of
 *    each included allocation. These are the totals that match the rows on
 *    screen, and they stay correct when a multi-block activity is filtered to
 *    one of its blocks.
 *  * [wholeActivityLabourHours] / [wholeActivityLabourCost] are the totals of
 *    the FULL parent activities that the result touches, de-duplicated by
 *    activity id. When [partialActivities] is greater than zero these describe
 *    work that reaches beyond the filtered blocks.
 *
 * They are equal only when every activity in the result is complete.
 */
data class PruningActivitySummary(
    val jobs: Int = 0,
    val activeRecords: Int = 0,
    val reversedRecords: Int = 0,
    val vines: Double = 0.0,
    /** ALLOCATED person-hours for the included allocations. */
    val labourHours: Double = 0.0,
    val averageVinesPerHour: Double? = null,
    /** ALLOCATED labour cost for the included allocations. */
    val labourCost: Double? = null,
    /** Distinct parent activities represented in the result. */
    val activities: Int = 0,
    /** Whole-activity person-hours, de-duplicated by activity id. */
    val wholeActivityLabourHours: Double = 0.0,
    /** Whole-activity labour cost, de-duplicated by activity id. */
    val wholeActivityLabourCost: Double? = null,
    /** Activities represented by only SOME of their allocations. */
    val partialActivities: Int = 0,
) {
    /** True when the result shows part of at least one multi-block activity. */
    val hasPartialActivities: Boolean get() = partialActivities > 0

    companion object {
        val EMPTY = PruningActivitySummary()
    }
}

object PruningActivityReport {

    /**
     * Projects pruning entries into report rows.
     *
     * All related entities are passed in pre-indexed — the caller resolves
     * blocks, Work Tasks, labour costs and account names ONCE, so building a
     * large history never performs a per-record lookup.
     *
     * LABOUR AUTHORITY: [labourCosts] is the linked Work Task's EFFECTIVE labour
     * cost — built by [PieceRateCosting.effectiveCostsByWorkTask], so a
     * piece-rate job contributes its snapshot total even with zero labour lines.
     * [labourHours] come from the task's labour lines. The entry's own
     * `labourHours` / legacy rate are used ONLY when the task supplies neither,
     * so a row never mixes sources and no total can count labour twice.
     */
    fun rows(
        entries: List<PruningEntry>,
        blocks: Map<String, PruningActivityBlockContext>,
        workTaskTitles: Map<String, String> = emptyMap(),
        workTaskStatuses: Map<String, String> = emptyMap(),
        labourCosts: Map<String, Double> = emptyMap(),
        labourHours: Map<String, Double> = emptyMap(),
        pieceRateVines: Map<String, Int> = emptyMap(),
        accountNames: Map<String, String> = emptyMap(),
    ): List<PruningActivityRow> = entries.map { entry ->
        val context = blocks[entry.paddockId]
        val rowRefs = context?.rows.orEmpty()
        val vines = if (rowRefs.isEmpty()) null else PruningCalculator.exactVines(entry.segments, rowRefs)
        // Work Task person-hours are authoritative; the legacy activity hours are
        // the fallback for records with no labour lines.
        val hours = entry.workTaskId?.let { labourHours[it] } ?: entry.labourHours?.takeIf { it > 0 }
        val date = PruningCalculator.parseDate(entry.date)
        val worker = entry.worker.trim()
        val notes = entry.notes.trim()

        PruningActivityRow(
            id = entry.id,
            paddockId = entry.paddockId,
            workTaskId = entry.workTaskId,
            activityKey = entry.activityKey,
            allocationIndex = entry.allocationIndex,
            seasonYear = date?.year ?: 0,
            date = date,
            dateIso = entry.date,
            worker = worker.takeIf { it.isNotEmpty() },
            blockName = context?.name ?: "Unknown block",
            variety = context?.variety,
            rowNumbers = entry.segments.map { it.row }.distinct().sorted(),
            quarters = entry.segments.size,
            rowEquivalents = entry.rowEquivalents,
            vines = vines,
            estimatedVines = entry.estimatedVines,
            labourHours = hours,
            operationalHours = entry.labourHours?.takeIf { it > 0 },
            startTime = entry.startTime?.takeIf { it.isNotBlank() },
            finishTime = entry.finishTime?.takeIf { it.isNotBlank() },
            durationHours = entry.durationHours,
            vinesPerHour = if (vines != null && hours != null && hours > 0) vines / hours else null,
            labourCost = entry.workTaskId?.let { labourCosts[it] },
            pieceRateVines = entry.workTaskId?.let { pieceRateVines[it] },
            workTaskTitle = entry.workTaskId?.let { workTaskTitles[it] },
            workTaskStatus = entry.workTaskId?.let { workTaskStatuses[it] },
            notes = notes.takeIf { it.isNotEmpty() },
            enteredBy = entry.enteredBy?.let { accountNames[it] },
            createdAtMs = entry.createdAtMs.takeIf { it > 0 },
            updatedAtMs = entry.updatedAtMs.takeIf { it > 0 },
            method = PruningMethods.label(entry.method),
            status = PruningActivityStatus.resolve(
                reversedAtMs = entry.reversedAtMs,
                createdAtMs = entry.createdAtMs,
                updatedAtMs = entry.updatedAtMs,
            ),
        )
    }

    /**
     * Applies the filter set. Search matches worker, block, variety, row
     * number, Work Task title and notes.
     */
    fun filtered(rows: List<PruningActivityRow>, filter: PruningActivityFilter): List<PruningActivityRow> {
        val needle = filter.search.trim().lowercase()
        return rows.filter { row ->
            if (filter.seasonYear != null && row.seasonYear != filter.seasonYear) return@filter false
            if (filter.dateFrom != null && row.dateIso < filter.dateFrom) return@filter false
            if (filter.dateTo != null && row.dateIso > filter.dateTo) return@filter false
            if (filter.workers.isNotEmpty() && (row.worker ?: "") !in filter.workers) return@filter false
            if (filter.blocks.isNotEmpty() && row.paddockId !in filter.blocks) return@filter false
            if (filter.varieties.isNotEmpty() && (row.variety ?: "") !in filter.varieties) return@filter false
            if (filter.statuses.isNotEmpty() && row.status !in filter.statuses) return@filter false
            when (filter.taskLink) {
                PruningActivityTaskLink.All -> Unit
                PruningActivityTaskLink.Linked -> if (!row.hasWorkTask) return@filter false
                PruningActivityTaskLink.NotLinked -> if (row.hasWorkTask) return@filter false
            }
            if (needle.isEmpty()) return@filter true
            matches(row, needle)
        }
    }

    private fun matches(row: PruningActivityRow, needle: String): Boolean {
        val haystack = listOfNotNull(
            row.worker,
            row.blockName,
            row.variety,
            row.workTaskTitle,
            row.notes,
            row.rowRangeLabel,
            row.rowNumbers.joinToString(" "),
        )
        return haystack.any { it.isNotEmpty() && it.lowercase().contains(needle) }
    }

    /**
     * Sorts by the TYPED value of a column. Blank values always sort last, in
     * both directions; ties fall back to the default order (date descending,
     * then created descending) so the result is deterministic.
     */
    fun sorted(rows: List<PruningActivityRow>, sort: PruningActivitySort): List<PruningActivityRow> {
        val column = sort.column?.takeIf { it.isSortable }
            ?: return rows.sortedWith(defaultComparator)
        val comparator = Comparator<PruningActivityRow> { lhs, rhs ->
            val decision = compare(lhs, rhs, column, sort.ascending)
            if (decision != 0) decision else defaultComparator.compare(lhs, rhs)
        }
        return rows.sortedWith(comparator)
    }

    private val defaultComparator = Comparator<PruningActivityRow> { lhs, rhs ->
        val byDate = rhs.dateIso.compareTo(lhs.dateIso)
        if (byDate != 0) return@Comparator byDate
        val byCreated = (rhs.createdAtMs ?: 0L).compareTo(lhs.createdAtMs ?: 0L)
        if (byCreated != 0) return@Comparator byCreated
        lhs.id.compareTo(rhs.id)
    }

    private fun compare(
        lhs: PruningActivityRow,
        rhs: PruningActivityRow,
        column: PruningActivityColumn,
        ascending: Boolean,
    ): Int = when (column) {
        PruningActivityColumn.Date -> order(lhs.dateIso, rhs.dateIso, ascending)
        PruningActivityColumn.Worker -> orderText(lhs.worker, rhs.worker, ascending)
        PruningActivityColumn.Block -> orderText(lhs.blockName, rhs.blockName, ascending)
        PruningActivityColumn.Variety -> orderText(lhs.variety, rhs.variety, ascending)
        PruningActivityColumn.Rows -> order(lhs.rowSortKey, rhs.rowSortKey, ascending)
        PruningActivityColumn.Quarters -> order(lhs.quarters, rhs.quarters, ascending)
        PruningActivityColumn.Vines -> order(lhs.vines, rhs.vines, ascending)
        PruningActivityColumn.Hours -> order(lhs.labourHours, rhs.labourHours, ascending)
        PruningActivityColumn.Start -> order(lhs.startMinutes, rhs.startMinutes, ascending)
        PruningActivityColumn.Finish -> order(lhs.finishMinutes, rhs.finishMinutes, ascending)
        PruningActivityColumn.Duration -> order(lhs.durationHours, rhs.durationHours, ascending)
        PruningActivityColumn.VinesPerHour -> order(lhs.vinesPerHour, rhs.vinesPerHour, ascending)
        PruningActivityColumn.LabourCost -> order(lhs.labourCost, rhs.labourCost, ascending)
        PruningActivityColumn.WorkTask -> orderText(lhs.workTaskTitle, rhs.workTaskTitle, ascending)
        PruningActivityColumn.EnteredBy -> orderText(lhs.enteredBy, rhs.enteredBy, ascending)
        PruningActivityColumn.Created -> order(lhs.createdAtMs, rhs.createdAtMs, ascending)
        PruningActivityColumn.Updated -> order(lhs.updatedAtMs, rhs.updatedAtMs, ascending)
        PruningActivityColumn.Status -> orderText(lhs.status.label, rhs.status.label, ascending)
        PruningActivityColumn.Notes -> 0
    }

    /** Null-last comparison for any comparable value. 0 = tie. */
    private fun <T : Comparable<T>> order(lhs: T?, rhs: T?, ascending: Boolean): Int = when {
        lhs == null && rhs == null -> 0
        lhs == null -> 1
        rhs == null -> -1
        else -> {
            val result = lhs.compareTo(rhs)
            if (ascending) result else -result
        }
    }

    /**
     * Case-insensitive text order with natural number handling, blanks last
     * ("Row 2" before "Row 10", "block 9" before "Block 10"). Mirrors the iOS
     * `localizedStandardCompare`.
     */
    private fun orderText(lhs: String?, rhs: String?, ascending: Boolean): Int {
        val left = lhs?.trim()?.takeIf { it.isNotEmpty() }
        val right = rhs?.trim()?.takeIf { it.isNotEmpty() }
        return when {
            left == null && right == null -> 0
            left == null -> 1
            right == null -> -1
            else -> {
                val result = naturalCompare(left, right)
                if (ascending) result else -result
            }
        }
    }

    /** Digit-chunk aware comparison so "Row 2" precedes "Row 10". */
    private fun naturalCompare(left: String, right: String): Int {
        var i = 0
        var j = 0
        while (i < left.length && j < right.length) {
            val a = left[i]
            val b = right[j]
            if (a.isDigit() && b.isDigit()) {
                var endA = i
                while (endA < left.length && left[endA].isDigit()) endA++
                var endB = j
                while (endB < right.length && right[endB].isDigit()) endB++
                val numA = left.substring(i, endA).trimStart('0')
                val numB = right.substring(j, endB).trimStart('0')
                val byLength = numA.length.compareTo(numB.length)
                if (byLength != 0) return byLength
                val byDigits = numA.compareTo(numB)
                if (byDigits != 0) return byDigits
                i = endA
                j = endB
            } else {
                val byChar = a.lowercaseChar().compareTo(b.lowercaseChar())
                if (byChar != 0) return byChar
                i++
                j++
            }
        }
        return (left.length - i).compareTo(right.length - j)
    }

    /**
     * Totals for the filtered result. Reversed rows are counted but never
     * contribute vines, hours, productivity or cost.
     *
     * Labour is ALLOCATED per allocation, so a multi-block activity contributes
     * its person-hours ONCE across its blocks instead of once per block. The
     * whole-activity figures are reported separately, de-duplicated by activity
     * id, so a partly-filtered activity can still be reconciled to its parent.
     *
     * @param canonicalRows every allocation of every activity BEFORE filtering,
     *   supplying the parent totals and the allocation-share denominator.
     *   Defaults to [rows] for an unfiltered summary.
     */
    fun summary(
        rows: List<PruningActivityRow>,
        includeCost: Boolean,
        canonicalRows: List<PruningActivityRow> = rows,
    ): PruningActivitySummary {
        val model = PruningActivityAllocationModel.build(canonicalRows, includeCost)

        var active = 0
        var reversed = 0
        var vines = 0.0
        var hours = 0.0
        var vinesWithHours = 0.0
        var hoursWithVines = 0.0
        var cost = 0.0
        var sawCost = false
        val includedPerActivity = LinkedHashMap<String, Int>()

        for (row in rows) {
            if (!row.status.countsTowardsTotals) {
                reversed += 1
                continue
            }
            active += 1
            vines += row.vines ?: 0.0
            includedPerActivity[row.activityKey] = (includedPerActivity[row.activityKey] ?: 0) + 1

            val share = model.shareOf(row)
            val rowHours = share?.personHours
            if (rowHours != null && rowHours > 0) {
                hours += rowHours
                val rowVines = row.vines
                if (rowVines != null) {
                    vinesWithHours += rowVines
                    hoursWithVines += rowHours
                }
            }
            val rowCost = share?.labourCost
            if (includeCost && rowCost != null) {
                cost += rowCost
                sawCost = true
            }
        }

        // Whole-activity totals count each parent ONCE, however many of its
        // allocations the filter admitted.
        var wholeHours = 0.0
        var wholeCost = 0.0
        var sawWholeCost = false
        var partial = 0
        for ((activityId, includedCount) in includedPerActivity) {
            val parent = model.parent(activityId) ?: continue
            wholeHours += parent.personHours ?: 0.0
            val parentCost = parent.labourCost
            if (includeCost && parentCost != null) {
                wholeCost += parentCost
                sawWholeCost = true
            }
            if (includedCount < parent.allocationCount) partial += 1
        }

        return PruningActivitySummary(
            jobs = rows.size,
            activeRecords = active,
            reversedRecords = reversed,
            vines = vines,
            labourHours = hours,
            averageVinesPerHour = if (hoursWithVines > 0) vinesWithHours / hoursWithVines else null,
            labourCost = if (sawCost) cost else null,
            activities = includedPerActivity.size,
            wholeActivityLabourHours = wholeHours,
            wholeActivityLabourCost = if (sawWholeCost) wholeCost else null,
            partialActivities = partial,
        )
    }
}
