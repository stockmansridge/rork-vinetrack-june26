package com.rork.vinetrack.data.model

import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale

/**
 * SHARED CONTRACT — Pruning Activity Report EXPORTS (CSV + PDF).
 *
 * Anything changed here must be mirrored in `PruningActivityExport.swift`. The
 * regression fixtures in `PruningActivityExportTest.kt` and
 * `PruningActivityExportTests.swift` are byte-for-byte the same.
 *
 * ## The model
 *
 * A pruning activity is ONE piece of work that may cover MANY blocks, and
 * `pruning_entries` is the allocation table. Every exported row is one
 * ALLOCATION, and it carries three kinds of value:
 *
 *  * ALLOCATION quantities — block, variety, rows, quarters, row equivalents,
 *    vines, allocation share, ALLOCATED person-hours, ALLOCATED cost. Present
 *    on EVERY row. These are proportional slices, so they sum correctly across
 *    any filtered subset.
 *  * PARENT CONTEXT — activity id, worker/crew, method, Work Task, start,
 *    finish, allocation counts, partial marker. Present on EVERY row, resolved
 *    from the PARENT ACTIVITY via [PruningActivityAllocationModel].
 *  * PARENT TOTALS — whole-activity operational hours, person-hours, labour
 *    cost and duration. Present on the DESIGNATED TOTALS ROW only, so a
 *    spreadsheet `SUM()` cannot count one activity's labour once per block.
 *
 * Suppressed values are BLANK, never `0` — a zero claims a real recorded
 * measurement of nothing.
 *
 * ## Parent context is never blanked by a filter
 *
 * The `allocation_index = 0` row is a legacy MIRROR of some parent values, not
 * the authority. Filtering to a block that the activity touched second must
 * still show that activity's worker, Work Task and labour. The totals row is
 * therefore the first INCLUDED allocation, not necessarily the primary.
 *
 * ## Partial activities
 *
 * When the filter admits fewer allocations than the activity really has, the
 * rows are marked `Partial activity = Yes` and carry both counts. The parent
 * totals still describe the WHOLE activity and are labelled as such; the
 * filtered block's proportional figures are the ALLOCATED columns. Confusing
 * the two is exactly the error this file exists to prevent.
 */
object PruningActivityExport {

    /**
     * One CSV row — one ALLOCATION of one activity.
     *
     * Whole-activity totals are nullable and populated ONLY when
     * [isActivityTotalsRow] is true. Allocated values and parent context are
     * populated on every row.
     */
    data class Row(
        /** Raw chronological `yyyy-MM-dd`, retained for sorting and pivots. */
        val dateIso: String,
        /** `dd/MM/yyyy`. */
        val dateDisplay: String,
        /** "Monday". */
        val weekday: String,
        /** The activity's name — the linked Work Task title, else "Spur pruning". */
        val activityLabel: String,
        /**
         * The PARENT activity's id, exported so a filtered extract can be
         * reconciled against the portal and so whole-activity totals can be
         * de-duplicated by the reader.
         */
        val activityId: String,
        /** This allocation's own id — the row's stable key. */
        val allocationId: String,
        /** 1-based position within the FULL activity, not within the extract. */
        val allocationNumber: Int,
        /** How many allocations the activity really has. */
        val fullAllocationCount: Int,
        /** How many of them survived the filter. */
        val includedAllocationCount: Int,
        /** True when [includedAllocationCount] < [fullAllocationCount]. */
        val isPartialActivity: Boolean,
        /** "block 1 of 2", or "block 2 of 2 (1 shown)" when partial. */
        val allocationLabel: String,
        val blockName: String,
        val variety: String?,
        /** "90" or "90–108", from the ACTUAL row numbers. */
        val rowRange: String?,
        val quarters: Int,
        val rowEquivalents: Double,
        /** Exact vines when the block's rows resolve, else this allocation's estimate. */
        val estimatedVines: Double?,
        // --- allocation slice: present on EVERY row ---------------------------
        /** 0..1 of the FULL activity's row equivalents. */
        val allocationShare: Double?,
        /** parent person-hours × share. */
        val allocatedPersonHours: Double?,
        /** parent labour cost × share; null when costing is not permitted. */
        val allocatedLabourCost: Double?,
        // --- parent context: present on EVERY row -----------------------------
        val method: String,
        val worker: String?,
        val workTaskTitle: String?,
        val workTaskStatus: String?,
        val startTime: String?,
        val finishTime: String?,
        // --- whole-activity totals: totals row ONLY ---------------------------
        /** The activity's own recorded operational hours. */
        val activityOperationalHours: Double?,
        /** RESOLVED authoritative person-hours for the WHOLE activity. */
        val activityPersonHours: Double?,
        /** Whole-activity labour cost; null when costing is not permitted. */
        val activityLabourCost: Double?,
        /** Elapsed start→finish duration for the whole activity. */
        val activityDurationHours: Double?,
        val notes: String?,
        // ---------------------------------------------------------------------
        val isReversed: Boolean,
        /**
         * True on the first INCLUDED allocation row of each activity — the one
         * carrying the whole-activity totals. Exported as a `Yes`/`No` column so
         * a pivot can aggregate parent values without de-duplicating.
         */
        val isActivityTotalsRow: Boolean,
    )

    /**
     * One activity and its INCLUDED allocations — the PDF's grouped layout. The
     * whole-activity labour is stated ONCE in the header; the allocation list
     * underneath carries each block's proportional slice.
     */
    data class Group(
        val activityId: String,
        val activityLabel: String,
        val dateIso: String,
        /** "Monday 3 August 2026". */
        val dateDisplay: String,
        val method: String,
        val worker: String?,
        val activityOperationalHours: Double?,
        val activityPersonHours: Double?,
        val activityLabourCost: Double?,
        val activityDurationHours: Double?,
        val workTaskTitle: String?,
        val workTaskStatus: String?,
        val startTime: String?,
        val finishTime: String?,
        val notes: String?,
        val isReversed: Boolean,
        val fullAllocationCount: Int,
        val allocations: List<Row>,
    ) {
        val includedAllocationCount: Int get() = allocations.size
        val isPartialActivity: Boolean get() = includedAllocationCount < fullAllocationCount
        val isMultiBlock: Boolean get() = fullAllocationCount > 1

        /**
         * "Partial activity — 1 of 2 blocks shown", or null for a complete one.
         * The PDF prints this above the whole-activity totals so nobody reads
         * those totals as belonging to the filtered block.
         */
        val partialLabel: String?
            get() = if (!isPartialActivity) {
                null
            } else {
                "Partial activity — $includedAllocationCount of $fullAllocationCount blocks shown"
            }

        /** "Pinot Noir + Cabernet Franc" — the INCLUDED blocks. */
        val blockSummary: String
            get() = allocations.map { it.blockName }.distinct().joinToString(" + ")

        val totalQuarters: Int get() = allocations.sumOf { it.quarters }
        val totalRowEquivalents: Double get() = allocations.sumOf { it.rowEquivalents }
        val totalVines: Double get() = allocations.sumOf { it.estimatedVines ?: 0.0 }

        /** Person-hours attributable to the SHOWN blocks only. */
        val allocatedPersonHours: Double?
            get() = sumOrNull(allocations.map { it.allocatedPersonHours })

        /** Labour cost attributable to the SHOWN blocks only. */
        val allocatedLabourCost: Double?
            get() = sumOrNull(allocations.map { it.allocatedLabourCost })

        private fun sumOrNull(values: List<Double?>): Double? {
            val present = values.filterNotNull()
            return if (present.isEmpty()) null else present.sum()
        }
    }

    // ------------------------------------------------------------------
    // Grouping
    // ------------------------------------------------------------------

    /**
     * Groups the report's ALREADY filtered and sorted rows into parent
     * activities, preserving each activity as a CONTIGUOUS block.
     *
     * Group order follows the report's own visible order: an activity ranks by
     * the position of its first-appearing row, so changing the report's sort
     * reorders the groups without ever scattering one activity's allocations
     * through the file. Allocation order inside a group is the canonical
     * `allocation_index` order.
     *
     * @param reportRows the report's filtered + sorted rows, in visible order.
     * @param includeCost false for roles without costing visibility; BOTH the
     *   whole-activity cost and the allocated cost are then dropped from the
     *   data, not merely hidden in the renderer.
     * @param canonicalRows every allocation of every activity BEFORE filtering.
     *   This supplies the parent context and the allocation-share denominator.
     *   Defaults to [reportRows] for an unfiltered export.
     */
    fun groups(
        reportRows: List<PruningActivityRow>,
        includeCost: Boolean,
        canonicalRows: List<PruningActivityRow> = reportRows,
    ): List<Group> {
        val model = PruningActivityAllocationModel.build(canonicalRows, includeCost)
        return groups(reportRows, includeCost, model)
    }

    /** Overload for callers that already built the model (the summary path). */
    fun groups(
        reportRows: List<PruningActivityRow>,
        includeCost: Boolean,
        model: PruningActivityAllocationModel,
    ): List<Group> {
        val buckets = LinkedHashMap<String, MutableList<PruningActivityRow>>()
        for (row in reportRows) {
            buckets.getOrPut(row.activityKey) { mutableListOf() }.add(row)
        }

        return buckets.map { (activityId, included) ->
            val ordered = PruningActivityAllocationModel.canonicalOrder(included)
            val head = ordered.first()
            val parent = model.parent(activityId)
            val fullCount = parent?.allocationCount ?: ordered.size
            val includedCount = ordered.size
            val partial = includedCount < fullCount
            val label = parent?.label
                ?: PruningActivityAllocationModel.label(head.workTaskTitle, head.method)

            val exported = ordered.mapIndexed { index, row ->
                val share = model.shareOf(row)
                // The totals row is the first INCLUDED allocation. When a filter
                // has excluded the legacy primary, the parent's values move to
                // whichever allocation survived — they are never dropped.
                val isTotals = index == 0
                Row(
                    dateIso = row.dateIso,
                    dateDisplay = auDate(row.date, row.dateIso),
                    weekday = weekday(row.date),
                    activityLabel = label,
                    activityId = activityId,
                    allocationId = row.id,
                    allocationNumber = share?.allocationNumber ?: (index + 1),
                    fullAllocationCount = fullCount,
                    includedAllocationCount = includedCount,
                    isPartialActivity = partial,
                    allocationLabel = allocationLabel(
                        number = share?.allocationNumber ?: (index + 1),
                        fullCount = fullCount,
                        includedCount = includedCount,
                    ),
                    blockName = row.blockName,
                    variety = row.variety,
                    rowRange = row.rowRangeLabel,
                    quarters = row.quarters,
                    rowEquivalents = row.rowEquivalents,
                    estimatedVines = row.vines ?: row.estimatedVines.takeIf { it > 0 }?.toDouble(),
                    // Proportional slices — on every row, because they are this
                    // block's own share and can be summed safely.
                    allocationShare = share?.share,
                    allocatedPersonHours = share?.personHours,
                    allocatedLabourCost = if (includeCost) share?.labourCost else null,
                    // Parent context — on every row, sourced from the ACTIVITY.
                    method = parent?.method ?: row.method,
                    worker = parent?.worker,
                    workTaskTitle = parent?.workTaskTitle,
                    workTaskStatus = parent?.workTaskStatus,
                    startTime = parent?.startTime,
                    finishTime = parent?.finishTime,
                    // Whole-activity totals — once, on the totals row.
                    activityOperationalHours = parent?.operationalHours.takeIf { isTotals },
                    activityPersonHours = parent?.personHours.takeIf { isTotals },
                    activityLabourCost = if (isTotals && includeCost) parent?.labourCost else null,
                    activityDurationHours = parent?.durationHours.takeIf { isTotals },
                    notes = parent?.notes.takeIf { isTotals },
                    isReversed = row.isReversed,
                    isActivityTotalsRow = isTotals,
                )
            }

            Group(
                activityId = activityId,
                activityLabel = label,
                dateIso = head.dateIso,
                dateDisplay = longDate(head.date, head.dateIso),
                method = parent?.method ?: head.method,
                worker = parent?.worker,
                activityOperationalHours = parent?.operationalHours,
                activityPersonHours = parent?.personHours,
                activityLabourCost = if (includeCost) parent?.labourCost else null,
                activityDurationHours = parent?.durationHours,
                workTaskTitle = parent?.workTaskTitle,
                workTaskStatus = parent?.workTaskStatus,
                startTime = parent?.startTime,
                finishTime = parent?.finishTime,
                notes = parent?.notes,
                isReversed = ordered.all { it.isReversed },
                fullAllocationCount = fullCount,
                allocations = exported,
            )
        }
    }

    /** The flat CSV row set — every allocation, activities kept contiguous. */
    fun rows(
        reportRows: List<PruningActivityRow>,
        includeCost: Boolean,
        canonicalRows: List<PruningActivityRow> = reportRows,
    ): List<Row> = groups(reportRows, includeCost, canonicalRows).flatMap { it.allocations }

    /**
     * "block 1 of 2"; a single-allocation activity says "whole activity". A
     * partial extract appends the included count so the row is self-describing
     * even when read on its own.
     */
    fun allocationLabel(number: Int, fullCount: Int, includedCount: Int): String {
        val base = if (fullCount <= 1) "whole activity" else "block $number of $fullCount"
        return if (includedCount < fullCount) "$base ($includedCount shown)" else base
    }

    // ------------------------------------------------------------------
    // CSV
    // ------------------------------------------------------------------

    /**
     * Column headings, in export order. BOTH cost columns are absent entirely
     * when [includeCost] is false, so a supervisor's export has no empty cost
     * column hinting at withheld data.
     */
    fun headers(includeCost: Boolean): List<String> = buildList {
        add("Date (ISO)")
        add("Activity Date")
        add("Weekday")
        add("Activity")
        add("Activity ID")
        add("Allocation ID")
        add("Allocation Number")
        add("Full Allocation Count")
        add("Included Allocation Count")
        add("Partial Activity")
        add("Allocation Label")
        add("Block")
        add("Variety")
        add("Rows")
        add("Quarters")
        add("Row Equivalents")
        add("Estimated Vines")
        add("Allocation Share (%)")
        add("Allocated Person-Hours")
        if (includeCost) add("Allocated Labour Cost")
        add("Pruning Method")
        add("Worker or Crew")
        add("Work Task")
        add("Work Task Status")
        add("Start Time")
        add("Finish Time")
        add("Activity Operational Hours")
        add("Activity Person-Hours")
        if (includeCost) add("Activity Total Labour Cost")
        add("Activity Duration (h)")
        add("Notes")
        add("Reversed")
        add("Activity Totals Row")
    }

    /** One row's cells, aligned with [headers]. */
    fun cells(row: Row, includeCost: Boolean): List<String> = buildList {
        add(row.dateIso)
        add(row.dateDisplay)
        add(row.weekday)
        add(row.activityLabel)
        add(row.activityId)
        add(row.allocationId)
        add(row.allocationNumber.toString())
        add(row.fullAllocationCount.toString())
        add(row.includedAllocationCount.toString())
        add(if (row.isPartialActivity) "Yes" else "No")
        add(row.allocationLabel)
        add(row.blockName)
        add(row.variety.orEmpty())
        add(row.rowRange.orEmpty())
        add(if (row.quarters > 0) row.quarters.toString() else "")
        add(number(row.rowEquivalents.takeIf { it > 0 }, 2))
        add(number(row.estimatedVines, 0))
        add(number(row.allocationShare?.let { it * 100.0 }, 2))
        add(number(row.allocatedPersonHours, 2))
        if (includeCost) add(number(row.allocatedLabourCost, 2))
        add(row.method)
        add(row.worker.orEmpty())
        add(row.workTaskTitle.orEmpty())
        add(row.workTaskStatus.orEmpty())
        add(row.startTime.orEmpty())
        add(row.finishTime.orEmpty())
        add(number(row.activityOperationalHours, 2))
        add(number(row.activityPersonHours, 2))
        if (includeCost) add(number(row.activityLabourCost, 2))
        add(number(row.activityDurationHours, 2))
        add(row.notes.orEmpty())
        add(if (row.isReversed) "Yes" else "No")
        add(if (row.isActivityTotalsRow) "Yes" else "No")
    }

    /**
     * The complete CSV. Values are quoted only when they need it, so hours and
     * costs stay NUMERIC for a spreadsheet rather than arriving as text.
     */
    fun csv(
        reportRows: List<PruningActivityRow>,
        includeCost: Boolean,
        canonicalRows: List<PruningActivityRow> = reportRows,
    ): String {
        val exported = rows(reportRows, includeCost, canonicalRows)
        val builder = StringBuilder()
        builder.append(headers(includeCost).joinToString(",") { escape(it) })
        builder.append("\r\n")
        for (row in exported) {
            builder.append(cells(row, includeCost).joinToString(",") { escape(it) })
            builder.append("\r\n")
        }
        return builder.toString()
    }

    /**
     * Fixed-decimal numeric text, or "" for a value that was never recorded.
     * BLANK is deliberate: `0` would claim a measured zero.
     */
    fun number(value: Double?, decimals: Int): String {
        if (value == null || !value.isFinite()) return ""
        return String.format(Locale.US, "%.${decimals}f", value)
    }

    /** Minimal RFC 4180 escaping — quote only when the value forces it. */
    private fun escape(value: String): String {
        val needsQuotes = value.any { it == ',' || it == '"' || it == '\n' || it == '\r' }
        if (!needsQuotes) return value
        return "\"" + value.replace("\"", "\"\"") + "\""
    }

    // ------------------------------------------------------------------
    // Dates
    // ------------------------------------------------------------------

    /** `dd/MM/yyyy`; falls back to the raw stored value if it won't parse. */
    fun auDate(date: LocalDate?, fallbackIso: String): String {
        date ?: return fallbackIso
        return String.format(
            Locale.US,
            "%02d/%02d/%04d",
            date.dayOfMonth,
            date.monthValue,
            date.year,
        )
    }

    /** "Monday 3 August 2026" — the PDF's group heading. */
    fun longDate(date: LocalDate?, fallbackIso: String): String {
        date ?: return fallbackIso
        val day = date.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.ENGLISH)
        val month = date.month.getDisplayName(TextStyle.FULL, Locale.ENGLISH)
        return "$day ${date.dayOfMonth} $month ${date.year}"
    }

    /** "Monday", or "" when the stored date is unparseable. */
    fun weekday(date: LocalDate?): String =
        date?.dayOfWeek?.getDisplayName(TextStyle.FULL, Locale.ENGLISH).orEmpty()

    // ------------------------------------------------------------------
    // Totals validation
    // ------------------------------------------------------------------

    /**
     * Sums an exported column the way a spreadsheet would, skipping reversed
     * rows exactly as [PruningActivityReport.summary] does. Used by the
     * regression tests to prove the export and the on-screen summary agree.
     */
    fun columnTotal(rows: List<Row>, selector: (Row) -> Double?): Double =
        rows.filterNot { it.isReversed }.sumOf { selector(it) ?: 0.0 }

    /**
     * Sums a WHOLE-ACTIVITY column, de-duplicating by activity id the way a
     * reader must. Only the totals rows carry these values, so this is really a
     * guard that no second row ever starts carrying them too.
     */
    fun activityTotal(rows: List<Row>, selector: (Row) -> Double?): Double {
        val seen = HashSet<String>()
        var total = 0.0
        for (row in rows) {
            if (row.isReversed) continue
            if (!seen.add(row.activityId)) continue
            total += selector(row) ?: 0.0
        }
        return total
    }
}
