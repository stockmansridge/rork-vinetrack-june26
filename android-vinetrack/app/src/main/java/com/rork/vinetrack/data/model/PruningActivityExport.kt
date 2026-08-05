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
 * ## Why this exists
 *
 * A pruning activity is ONE piece of work that may cover MANY blocks (sql/166).
 * `pruning_entries` is the allocation table, so a two-block activity is two
 * rows in the report — and naively exporting both rows with the activity's
 * labour on each would make every spreadsheet `SUM()` count that labour twice.
 *
 * The rule this file enforces:
 *
 *  * ALLOCATION-level quantities (block, variety, rows, quarters, row
 *    equivalents, vines) appear on EVERY allocation row.
 *  * ACTIVITY-level values (operational hours, Work Task person-hours, labour
 *    cost, worker/crew, start, finish, duration, notes) appear on the FIRST
 *    allocation row only.
 *  * Suppressed values are BLANK, never `0` — a zero claims a real recorded
 *    measurement of nothing.
 *
 * This is not a presentation trick: the activity's labour and timing are stored
 * on exactly one allocation (`allocation_index = 0`, the PRIMARY), so the first
 * allocation row is the only row that ever holds them. The export makes that
 * storage invariant visible instead of fighting it.
 *
 * ## Labour authority
 *
 * Unchanged from [WorkTaskLabourCosting]: summed Work Task labour lines win
 * outright, and the legacy activity-level value is used ONLY when the linked
 * task has no lines. The two sources are never combined, so the exported
 * person-hours and labour-cost columns sum to the report summary exactly.
 */
object PruningActivityExport {

    /** Australian display format. The raw ISO date is exported alongside it. */
    private const val AU_DATE = "dd/MM/yyyy"

    /**
     * One CSV row — one ALLOCATION of one activity.
     *
     * Every activity-level field is nullable and is populated ONLY when
     * [isActivityTotalsRow] is true. No field carries a UUID: internal ids are
     * used for grouping and then dropped, so an exported file never leaks a
     * database identifier.
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
        val allocationNumber: Int,
        val allocationCount: Int,
        /** "block 1 of 2". */
        val allocationLabel: String,
        val blockName: String,
        val variety: String?,
        /** "90" or "90–108", from the ACTUAL row numbers. */
        val rowRange: String?,
        val quarters: Int,
        val rowEquivalents: Double,
        /** Exact vines when the block's rows resolve, else this allocation's estimate. */
        val estimatedVines: Double?,
        val method: String,
        // --- activity level: first allocation row only -----------------------
        val worker: String?,
        /** The activity's own recorded operational hours. */
        val operationalHours: Double?,
        /** RESOLVED authoritative person-hours (task labour lines, else legacy). */
        val personHours: Double?,
        /** Null when costing is not visible to this role, or none was recorded. */
        val labourCost: Double?,
        val workTaskTitle: String?,
        val workTaskStatus: String?,
        val startTime: String?,
        val finishTime: String?,
        val durationHours: Double?,
        val notes: String?,
        // --------------------------------------------------------------------
        val isReversed: Boolean,
        /**
         * True on the first allocation row of each activity — the one carrying
         * the activity-level totals. Exported as a `Yes`/`No` column so pivot
         * tables can aggregate activity values without any de-duplication.
         */
        val isActivityTotalsRow: Boolean,
    )

    /**
     * One activity and all of its exported allocations — the PDF's grouped
     * layout. The activity's labour and timing are stated ONCE in the header,
     * so the allocation list underneath is pure block detail.
     */
    data class Group(
        /**
         * The parent activity's id. Used for grouping and ordering ONLY — no
         * renderer ever prints it, so no identifier reaches an exported file.
         */
        val activityKey: String,
        val activityLabel: String,
        val dateIso: String,
        /** "Monday 3 August 2026". */
        val dateDisplay: String,
        val method: String,
        val worker: String?,
        val operationalHours: Double?,
        val personHours: Double?,
        val labourCost: Double?,
        val workTaskTitle: String?,
        val workTaskStatus: String?,
        val startTime: String?,
        val finishTime: String?,
        val durationHours: Double?,
        val notes: String?,
        val isReversed: Boolean,
        val allocations: List<Row>,
    ) {
        val allocationCount: Int get() = allocations.size
        val isMultiBlock: Boolean get() = allocations.size > 1

        /** "Pinot Noir + Cabernet Franc". */
        val blockSummary: String
            get() = allocations.map { it.blockName }.distinct().joinToString(" + ")

        val totalQuarters: Int get() = allocations.sumOf { it.quarters }
        val totalRowEquivalents: Double get() = allocations.sumOf { it.rowEquivalents }
        val totalVines: Double get() = allocations.sumOf { it.estimatedVines ?: 0.0 }
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
     * through the file.
     *
     * Allocation order inside a group is the server's `allocation_index`, which
     * puts the PRIMARY allocation — the one holding the activity's labour and
     * timing — first. That is what makes "totals on row 1" true rather than
     * hopeful.
     *
     * @param rows the report's filtered + sorted rows, in visible order.
     * @param includeCost false for roles without costing visibility; the labour
     *   cost is then dropped from the data, not merely hidden in the renderer.
     */
    fun groups(
        reportRows: List<PruningActivityRow>,
        includeCost: Boolean,
    ): List<Group> {
        val order = LinkedHashMap<String, MutableList<PruningActivityRow>>()
        for (row in reportRows) {
            order.getOrPut(row.activityKey) { mutableListOf() }.add(row)
        }

        return order.values.map { activityRows ->
            val allocations = activityRows.sortedWith(
                compareBy<PruningActivityRow> { it.allocationIndex }
                    .thenBy { it.blockName.lowercase() }
                    .thenBy { it.id },
            )
            // The activity's own values live on the PRIMARY allocation. When a
            // filter has excluded that allocation the values are genuinely not
            // in this result, and every activity-level field stays blank rather
            // than being invented from a sibling row.
            val head = allocations.first()
            val count = allocations.size
            val label = activityLabel(head)

            val exported = allocations.mapIndexed { index, row ->
                val isTotals = index == 0
                Row(
                    dateIso = row.dateIso,
                    dateDisplay = auDate(row.date, row.dateIso),
                    weekday = weekday(row.date),
                    activityLabel = label,
                    allocationNumber = index + 1,
                    allocationCount = count,
                    allocationLabel = allocationLabel(index + 1, count),
                    blockName = row.blockName,
                    variety = row.variety,
                    rowRange = row.rowRangeLabel,
                    quarters = row.quarters,
                    rowEquivalents = row.rowEquivalents,
                    estimatedVines = row.vines ?: row.estimatedVines.takeIf { it > 0 }?.toDouble(),
                    method = row.method,
                    // Work Task title and status repeat on every allocation:
                    // they are text, they cannot be summed, and repeating them
                    // keeps a wide spreadsheet readable when scrolled.
                    workTaskTitle = row.workTaskTitle ?: head.workTaskTitle,
                    workTaskStatus = row.workTaskStatus ?: head.workTaskStatus,
                    // Everything below is numeric or activity-level narrative
                    // and appears exactly once per activity.
                    worker = head.worker.takeIf { isTotals },
                    operationalHours = head.operationalHours.takeIf { isTotals },
                    personHours = head.labourHours.takeIf { isTotals },
                    labourCost = if (isTotals && includeCost) head.labourCost else null,
                    startTime = head.startTime.takeIf { isTotals },
                    finishTime = head.finishTime.takeIf { isTotals },
                    durationHours = head.durationHours.takeIf { isTotals },
                    notes = head.notes.takeIf { isTotals },
                    isReversed = row.isReversed,
                    isActivityTotalsRow = isTotals,
                )
            }

            Group(
                activityKey = head.activityKey,
                activityLabel = label,
                dateIso = head.dateIso,
                dateDisplay = longDate(head.date, head.dateIso),
                method = head.method,
                worker = head.worker,
                operationalHours = head.operationalHours,
                personHours = head.labourHours,
                labourCost = if (includeCost) head.labourCost else null,
                workTaskTitle = head.workTaskTitle,
                workTaskStatus = head.workTaskStatus,
                startTime = head.startTime,
                finishTime = head.finishTime,
                durationHours = head.durationHours,
                notes = head.notes,
                isReversed = head.isReversed,
                allocations = exported,
            )
        }
    }

    /** The flat CSV row set — every allocation, activities kept contiguous. */
    fun rows(reportRows: List<PruningActivityRow>, includeCost: Boolean): List<Row> =
        groups(reportRows, includeCost).flatMap { it.allocations }

    /**
     * Activity name. There is no free-text activity title in the schema, so the
     * linked Work Task's title is used when there is one and a method-derived
     * label otherwise — never a UUID, never "Activity 3f2a…".
     */
    private fun activityLabel(head: PruningActivityRow): String {
        val title = head.workTaskTitle?.trim()?.takeIf { it.isNotEmpty() }
        if (title != null) return title
        val method = head.method.trim().takeIf { it.isNotEmpty() } ?: return "Pruning"
        return if (method.contains("prun", ignoreCase = true)) method else "$method pruning"
    }

    /** "block 1 of 2"; a single-allocation activity says "whole activity". */
    fun allocationLabel(number: Int, count: Int): String =
        if (count <= 1) "whole activity" else "block $number of $count"

    // ------------------------------------------------------------------
    // CSV
    // ------------------------------------------------------------------

    /**
     * Column headings, in export order. The labour cost column is absent
     * entirely when [includeCost] is false, so a supervisor's export has no
     * empty cost column hinting at withheld data.
     */
    fun headers(includeCost: Boolean): List<String> = buildList {
        add("Date (ISO)")
        add("Activity Date")
        add("Weekday")
        add("Activity")
        add("Allocation Number")
        add("Allocation Count")
        add("Allocation Label")
        add("Block")
        add("Variety")
        add("Rows")
        add("Quarters")
        add("Row Equivalents")
        add("Estimated Vines")
        add("Pruning Method")
        add("Worker or Crew")
        add("Operational Hours")
        add("Work Task Person-Hours")
        if (includeCost) add("Labour Cost")
        add("Work Task")
        add("Work Task Status")
        add("Start Time")
        add("Finish Time")
        add("Duration (h)")
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
        add(row.allocationNumber.toString())
        add(row.allocationCount.toString())
        add(row.allocationLabel)
        add(row.blockName)
        add(row.variety.orEmpty())
        add(row.rowRange.orEmpty())
        add(if (row.quarters > 0) row.quarters.toString() else "")
        add(number(row.rowEquivalents.takeIf { it > 0 }, 2))
        add(number(row.estimatedVines, 0))
        add(row.method)
        add(row.worker.orEmpty())
        add(number(row.operationalHours, 2))
        add(number(row.personHours, 2))
        if (includeCost) add(number(row.labourCost, 2))
        add(row.workTaskTitle.orEmpty())
        add(row.workTaskStatus.orEmpty())
        add(row.startTime.orEmpty())
        add(row.finishTime.orEmpty())
        add(number(row.durationHours, 2))
        add(row.notes.orEmpty())
        add(if (row.isReversed) "Yes" else "No")
        add(if (row.isActivityTotalsRow) "Yes" else "No")
    }

    /**
     * The complete CSV. Values are quoted only when they need it, so hours and
     * costs stay NUMERIC for a spreadsheet rather than arriving as text.
     */
    fun csv(reportRows: List<PruningActivityRow>, includeCost: Boolean): String {
        val exported = rows(reportRows, includeCost)
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
}
