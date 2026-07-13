package com.rork.vinetrack.data.model

import kotlinx.serialization.Serializable
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * A fixed quarter of a vineyard row (quarter 1 = 0–25% … 4 = 75–100%).
 * Segments are absolute so the same portion can never be recorded twice and
 * the crew's stopping point stays visible. Mirrors the iOS `PruningSegment`.
 */
@Serializable
data class PruningSegment(val row: Int, val quarter: Int)

/** Per-block pruning configuration. Local-only for now; shaped for future sync. */
@Serializable
data class PruningBlockSetup(
    val id: String,
    val vineyardId: String,
    val paddockId: String,
    /** ISO dates, yyyy-MM-dd. */
    val startDate: String? = null,
    val dueDate: String? = null,
    val method: String = "spur",
    val crew: String = "",
    /** ISO weekdays that count as working days (1 = Monday … 7 = Sunday). */
    val workingDays: List<Int> = listOf(1, 2, 3, 4, 5),
    /** Manual row count for blocks without mapped rows. */
    val rowCountOverride: Int? = null,
    val estimatedLabourHours: Double? = null,
    val notes: String = "",
)

/** One day's recorded pruning work on a block. */
@Serializable
data class PruningEntry(
    val id: String,
    val vineyardId: String,
    val paddockId: String,
    /** ISO date, yyyy-MM-dd. */
    val date: String,
    val segments: List<PruningSegment> = emptyList(),
    val worker: String = "",
    val labourHours: Double? = null,
    /** Optional HH:mm times. */
    val startTime: String? = null,
    val finishTime: String? = null,
    val method: String = "spur",
    val notes: String = "",
    val createdAtMs: Long = 0L,
) {
    /** A full row = 1.0; each quarter = 0.25. */
    val rowEquivalents: Double get() = segments.size / 4.0
}

/** Pruning method keys + labels (matches the iOS `PruningMethod` cases). */
object PruningMethods {
    val all: List<Pair<String, String>> = listOf(
        "spur" to "Spur pruning",
        "cane" to "Cane pruning",
        "mechanical" to "Mechanical pre-pruning",
        "followUp" to "Follow-up pruning",
        "other" to "Other",
    )

    fun label(key: String): String = all.firstOrNull { it.first == key }?.second ?: "Other"
}

enum class PruningStatus(val label: String) {
    NotStarted("Not started"),
    Ahead("Ahead"),
    OnTrack("On track"),
    AtRisk("At risk"),
    Behind("Behind"),
    Complete("Complete"),
}

/** Aggregated progress + rate metrics for one block. */
data class PruningBlockMetrics(
    val rowCount: Int,
    val completed: Set<PruningSegment>,
    val completedRowEquivalents: Double,
    val totalRowEquivalents: Double,
    val fractionComplete: Double,
    val vinesPerRow: Double,
    val vinesPruned: Int,
    val vinesTotal: Int,
    val averageRowLength: Double,
    val ratePerWorkday: Double?,
    val projectedFinish: LocalDate?,
    val status: PruningStatus,
    val timeElapsedFraction: Double?,
)

/** Pure calculation helpers — mirrors the iOS `PruningCalculator`. */
object PruningCalculator {

    fun parseDate(value: String?): LocalDate? =
        value?.takeIf { it.isNotBlank() }?.let { runCatching { LocalDate.parse(it) }.getOrNull() }

    fun completedSegments(entries: List<PruningEntry>, rowCount: Int): Set<PruningSegment> {
        val set = mutableSetOf<PruningSegment>()
        for (entry in entries) {
            for (segment in entry.segments) {
                if (segment.row in 1..rowCount) set.add(segment)
            }
        }
        return set
    }

    /**
     * Average row equivalents per day-with-entries over the most recent
     * [lastDays] working days. Days without entries (e.g. rain days) never
     * count against the rate.
     */
    fun rowEquivalentsPerDay(entries: List<PruningEntry>, lastDays: Int?): Double? {
        val byDay = entries.groupBy { it.date }
        if (byDay.isEmpty()) return null
        val days = byDay.keys.sortedDescending()
        val selected = if (lastDays != null) days.take(lastDays) else days
        if (selected.isEmpty()) return null
        val total = selected.sumOf { day -> byDay[day].orEmpty().sumOf { it.rowEquivalents } }
        return total / selected.size
    }

    /** Rolling rate: last 3 working days when available, otherwise the whole period. */
    fun preferredRate(entries: List<PruningEntry>): Double? =
        rowEquivalentsPerDay(entries, 3) ?: rowEquivalentsPerDay(entries, null)

    /** Projects the completion date by walking forward through configured working days. */
    fun projectedFinish(
        remainingRowEquivalents: Double,
        ratePerWorkday: Double,
        workingDays: List<Int>,
        from: LocalDate = LocalDate.now(),
    ): LocalDate? {
        if (ratePerWorkday <= 0.0) return null
        if (remainingRowEquivalents <= 0.0) return from
        val workSet = (workingDays.ifEmpty { listOf(1, 2, 3, 4, 5) }).toSet()
        var daysNeeded = ceil(remainingRowEquivalents / ratePerWorkday).toInt()
        var date = from
        var iterations = 0
        while (iterations < 3_660) {
            if (workSet.contains(date.dayOfWeek.value)) {
                daysNeeded -= 1
                if (daysNeeded <= 0) return date
            }
            date = date.plusDays(1)
            iterations += 1
        }
        return null
    }

    /** Ahead > 3 days early · On track within 3 days · At risk 1–3 days late · Behind > 3 late. */
    fun status(
        completedRowEquivalents: Double,
        totalRowEquivalents: Double,
        projectedFinish: LocalDate?,
        dueDate: LocalDate?,
    ): PruningStatus {
        if (totalRowEquivalents > 0 && completedRowEquivalents >= totalRowEquivalents - 0.0001) {
            return PruningStatus.Complete
        }
        if (completedRowEquivalents <= 0.0) return PruningStatus.NotStarted
        if (projectedFinish == null || dueDate == null) return PruningStatus.OnTrack
        val daysLate = ChronoUnit.DAYS.between(dueDate, projectedFinish)
        return when {
            daysLate < -3 -> PruningStatus.Ahead
            daysLate <= 0 -> PruningStatus.OnTrack
            daysLate <= 3 -> PruningStatus.AtRisk
            else -> PruningStatus.Behind
        }
    }

    fun vines(segmentCount: Int, vinesPerRow: Double): Int =
        (segmentCount * vinesPerRow / 4.0).roundToInt()

    /** Full metric bundle for one block. */
    fun metrics(
        paddock: Paddock,
        setup: PruningBlockSetup?,
        entries: List<PruningEntry>,
    ): PruningBlockMetrics {
        val mappedRows = paddock.rowCount
        val rowCount = if (mappedRows > 0) mappedRows else (setup?.rowCountOverride ?: 0)
        val completed = completedSegments(entries, max(rowCount, 1))
        val completedRowEq = completed.size / 4.0
        val totalRowEq = rowCount.toDouble()
        val fraction = if (totalRowEq > 0) min(completedRowEq / totalRowEq, 1.0) else 0.0

        val totalVines = paddock.effectiveVineCount
        val vinesPerRow = if (rowCount > 0) totalVines.toDouble() / rowCount else 0.0
        val vinesPruned = vines(completed.size, vinesPerRow)
        val averageRowLength = if (rowCount > 0) paddock.effectiveTotalRowLength / rowCount else 0.0

        val rate = preferredRate(entries)
        val remaining = max(totalRowEq - completedRowEq, 0.0)
        val projected = if (rate != null && rate > 0 && remaining > 0) {
            projectedFinish(remaining, rate, setup?.workingDays ?: listOf(1, 2, 3, 4, 5))
        } else {
            null
        }

        val due = parseDate(setup?.dueDate)
        val blockStatus = status(completedRowEq, totalRowEq, projected, due)

        var elapsed: Double? = null
        if (due != null) {
            val start = parseDate(setup?.startDate)
                ?: entries.mapNotNull { parseDate(it.date) }.minOrNull()
            if (start != null && due.isAfter(start)) {
                val total = ChronoUnit.DAYS.between(start, due).toDouble()
                val gone = ChronoUnit.DAYS.between(start, LocalDate.now()).toDouble()
                if (total > 0) elapsed = min(max(gone / total, 0.0), 1.0)
            }
        }

        return PruningBlockMetrics(
            rowCount = rowCount,
            completed = completed,
            completedRowEquivalents = completedRowEq,
            totalRowEquivalents = totalRowEq,
            fractionComplete = fraction,
            vinesPerRow = vinesPerRow,
            vinesPruned = vinesPruned,
            vinesTotal = totalVines,
            averageRowLength = averageRowLength,
            ratePerWorkday = rate,
            projectedFinish = projected,
            status = blockStatus,
            timeElapsedFraction = elapsed,
        )
    }
}
