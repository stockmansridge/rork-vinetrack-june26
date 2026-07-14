package com.rork.vinetrack.data.model

import kotlinx.serialization.Serializable
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Deterministic pruning-season ids shared with iOS: both platforms derive the
 * SAME `pruning_seasons` row id from (vineyard, paddock, season year), so two
 * devices that configure a block independently converge instead of colliding
 * on the unique season index. Uses `UUID.nameUUIDFromBytes` (MD5 v3), which
 * the iOS `PruningSeasonId.make` replicates byte-for-byte.
 */
object PruningSeasonIds {
    fun make(vineyardId: String, paddockId: String, seasonYear: Int): String {
        val name = "vinetrack-pruning-season|${vineyardId.lowercase()}|${paddockId.lowercase()}|$seasonYear"
        return UUID.nameUUIDFromBytes(name.toByteArray(Charsets.UTF_8)).toString()
    }

    fun currentSeasonYear(): Int = LocalDate.now().year
}

/**
 * A fixed quarter of a vineyard row (quarter 1 = 0–25% … 4 = 75–100%).
 * Segments are absolute so the same portion can never be recorded twice and
 * the crew's stopping point stays visible. Mirrors the iOS `PruningSegment`.
 *
 * Identity is the ACTUAL paddock row record ([rowId]) when the block has
 * configured rows — renaming or reordering rows never detaches progress.
 * [row] is the display-number snapshot (the real stored number, e.g. 101,
 * never a 1…N index). [rowId] is null only for manual fallback rows.
 */
@Serializable
data class PruningSegment(val row: Int, val quarter: Int, val rowId: String? = null) {
    /** Canonical row identity: the stable row id when present, else the number. */
    val rowKey: String get() = rowId?.lowercase() ?: "n$row"

    override fun equals(other: Any?): Boolean =
        other is PruningSegment && other.rowKey == rowKey && other.quarter == quarter

    override fun hashCode(): Int = rowKey.hashCode() * 31 + quarter
}

/**
 * One selectable row on the progress screen — the ACTUAL configured paddock
 * row when the block has row records, or a numbered fallback row generated
 * from the manual row count otherwise. Mirrors the iOS `PruningRowRef`.
 * Precedence:
 *   1. configured paddock rows (stored order, real numbers, per-row length),
 *   2. sequential fallback rows from `manual_row_count`.
 */
data class PruningRowRef(
    /** Stable paddock row id (null for manual fallback rows). */
    val rowId: String?,
    /** Real stored row number (or 1…N only for fallback rows). */
    val number: Int,
    /** Display label — the stored row identifier. */
    val label: String,
    /** This row's length in metres when geometry exists. */
    val lengthMetres: Double?,
    /** Estimated vines in THIS row (rows can have different lengths). */
    val vines: Double,
    /** True when generated from the manual row count. */
    val isFallback: Boolean,
) {
    val key: String get() = rowId?.lowercase() ?: "n$number"

    fun segment(quarter: Int): PruningSegment = PruningSegment(row = number, quarter = quarter, rowId = rowId)
}

/** Per-block pruning configuration — one row per block + season year (`pruning_seasons`). */
@Serializable
data class PruningBlockSetup(
    val id: String,
    val vineyardId: String,
    val paddockId: String,
    /** Pruning season (calendar year); part of the deterministic season id. */
    val seasonYear: Int = PruningSeasonIds.currentSeasonYear(),
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

/** One day's recorded pruning work on a block (one press of Complete Today). */
@Serializable
data class PruningEntry(
    val id: String,
    val vineyardId: String,
    val paddockId: String,
    /** The `pruning_seasons` row this entry belongs to. */
    val seasonId: String = "",
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
    /** Client estimate at save time; the server re-attributes on sync. */
    val estimatedVines: Int = 0,
    /** The Work Task created from this recording (at most one per entry). */
    val workTaskId: String? = null,
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
    /**
     * The actual rows the tracker operates on (configured rows first,
     * manual fallback rows only when none are configured).
     */
    val rows: List<PruningRowRef>,
    val rowCount: Int,
    val completed: Set<PruningSegment>,
    val completedRowEquivalents: Double,
    val totalRowEquivalents: Double,
    val fractionComplete: Double,
    val vinesPerRow: Double,
    /**
     * EXACT (unrounded) vines pruned — sum of each completed quarter's exact
     * vines. Vineyard totals MUST sum this and round once at display
     * (rounding per block first drifts against iOS/portal).
     */
    val vinesPrunedExact: Double,
    /** Display value for this block: round(vinesPrunedExact). */
    val vinesPruned: Int,
    val vinesTotal: Int,
    val averageRowLength: Double,
    val ratePerWorkday: Double?,
    val projectedFinish: LocalDate?,
    val status: PruningStatus,
    val timeElapsedFraction: Double?,
)

/**
 * Vineyard-wide dashboard summary — the aggregation contract shared with iOS
 * and the SQL 115 RPC `get_pruning_vineyard_summary`. All values are exact;
 * round only at display.
 */
data class PruningVineyardSummary(
    val blockCount: Int,
    val completedRowEquivalents: Double,
    val totalRowEquivalents: Double,
    /** Exact completion fraction (row-equivalent based, capped at 1). */
    val fraction: Double,
    val vinesPrunedExact: Double,
    /** round(vinesPrunedExact) — the ONE rounding point for vine totals. */
    val vinesPruned: Int,
    val vinesTotal: Int,
    val vinesPerDay: Double?,
    val vinesPerLabourHour: Double?,
    val labourHours: Double,
    val blocksComplete: Int,
    val blocksAtRisk: Int,
    val projectedFinish: LocalDate?,
) {
    val vinesRemaining: Int get() = maxOf(vinesTotal - vinesPruned, 0)
    val displayPercent: Int get() = PruningCalculator.displayPercent(fraction)
}

/**
 * Pure calculation helpers — mirrors the iOS `PruningCalculator`.
 *
 * CALCULATION CONTRACT (shared with iOS + the portal RPC
 * `get_pruning_vineyard_summary`): all intermediate row/quarter vine values
 * stay full-precision doubles; rounding happens ONCE at display via
 * [displayPercent] / `round(exact)`. Overall progress is row-equivalent
 * based (completed ÷ total row equivalents), never vine-weighted.
 */
object PruningCalculator {

    /**
     * The ONE display rounding rule for percentages on every platform:
     * round(fraction × 100) half up — never truncate. Matches the iOS
     * `PruningCalculator.displayPercent` and the SQL RPC.
     */
    fun displayPercent(fraction: Double): Int = (fraction * 100).roundToInt()

    fun parseDate(value: String?): LocalDate? =
        value?.takeIf { it.isNotBlank() }?.let { runCatching { LocalDate.parse(it) }.getOrNull() }

    /** Length of one mapped row in metres (matches iOS `PruningCalculator.rowLength`). */
    fun rowLength(row: PaddockRow, paddock: Paddock): Double {
        val start = row.startPoint ?: return 0.0
        val end = row.endPoint ?: return 0.0
        val points = paddock.polygonPoints.orEmpty()
        val centroidLat = if (points.isEmpty()) start.latitude else points.sumOf { it.latitude } / points.size
        val mPerDegLat = 111_320.0
        val mPerDegLon = 111_320.0 * cos(centroidLat * Math.PI / 180.0)
        val dLat = (end.latitude - start.latitude) * mPerDegLat
        val dLon = (end.longitude - start.longitude) * mPerDegLon
        return sqrt(dLat * dLat + dLon * dLon)
    }

    /**
     * The rows the tracker operates on. Uses the ACTUAL configured paddock
     * rows (stored order, real numbers — non-sequential and >1 starts are
     * preserved); falls back to sequential rows from the manual row count
     * only when the block has no configured row records.
     *
     * Vine distribution mirrors iOS: each row is weighted by its own length
     * (rows without geometry get the average mapped length, or an equal share
     * when nothing is mapped), and the block's effective vine count is split
     * across those weights — so a quarter contributes 25% of THAT row's vines
     * and totals always reconcile with the block vine count.
     */
    fun rowRefs(paddock: Paddock, setup: PruningBlockSetup?): List<PruningRowRef> {
        val totalVines = paddock.effectiveVineCount.toDouble()
        val configured = paddock.rows.orEmpty()
        if (configured.isNotEmpty()) {
            val lengths = configured.map { rowLength(it, paddock) }
            val positive = lengths.filter { it > 0 }
            val averageLength = if (positive.isEmpty()) 0.0 else positive.sum() / positive.size
            val weights = lengths.map { if (it > 0) it else (if (averageLength > 0) averageLength else 1.0) }
            val totalWeight = weights.sum()
            return configured.mapIndexed { index, row ->
                PruningRowRef(
                    rowId = row.stableId,
                    number = row.number,
                    label = row.number.toString(),
                    lengthMetres = lengths[index].takeIf { it > 0 },
                    vines = if (totalWeight > 0) totalVines * weights[index] / totalWeight else 0.0,
                    isFallback = false,
                )
            }
        }
        val count = setup?.rowCountOverride ?: 0
        if (count <= 0) return emptyList()
        return (1..count).map { number ->
            PruningRowRef(
                rowId = null,
                number = number,
                label = number.toString(),
                lengthMetres = null,
                vines = totalVines / count,
                isFallback = true,
            )
        }
    }

    /**
     * Union of completed segments across entries, canonicalised onto the
     * block's actual rows. Segments carrying a row id only match that exact
     * row (a renamed row keeps its progress; a deleted row's quarters are
     * excluded rather than silently attached to a different row). Legacy
     * segments without a row id are matched by their stored number.
     */
    fun completedSegments(entries: List<PruningEntry>, rows: List<PruningRowRef>): Set<PruningSegment> {
        val byId = HashMap<String, PruningRowRef>()
        val byNumber = HashMap<Int, PruningRowRef>()
        for (ref in rows) {
            ref.rowId?.let { byId[it.lowercase()] = ref }
            byNumber.putIfAbsent(ref.number, ref)
        }
        val set = mutableSetOf<PruningSegment>()
        for (entry in entries) {
            for (segment in entry.segments) {
                val ref = if (segment.rowId != null) byId[segment.rowId.lowercase()] else byNumber[segment.row]
                if (ref != null) set.add(ref.segment(segment.quarter))
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

    /**
     * EXACT vines represented by a set of segments using each ACTUAL row's
     * vine estimate — a quarter contributes 25% of that specific row's vines.
     * Full precision: aggregate these and round ONCE at display.
     */
    fun exactVines(segments: Collection<PruningSegment>, rows: List<PruningRowRef>): Double {
        val byKey = rows.associateBy({ it.key }, { it.vines })
        return segments.sumOf { (byKey[it.rowKey] ?: 0.0) / 4.0 }
    }

    /**
     * Display-rounded variant of [exactVines]. Never sum these — sum the
     * exact values and round the total instead.
     */
    fun vines(segments: Collection<PruningSegment>, rows: List<PruningRowRef>): Int =
        exactVines(segments, rows).roundToInt()

    /**
     * Mean EXACT vines per day-with-entries (whole period) — the same
     * vines/day contract the vineyard dashboard and the SQL 115 RPC use,
     * applied to one block. Days without entries never count against the rate.
     */
    fun exactVinesPerDay(entries: List<PruningEntry>, rows: List<PruningRowRef>): Double? {
        val byDay = HashMap<String, Double>()
        for (entry in entries) {
            byDay[entry.date] = (byDay[entry.date] ?: 0.0) + exactVines(entry.segments, rows)
        }
        if (byDay.isEmpty()) return null
        return byDay.values.sum() / byDay.size
    }

    /**
     * Vines per person-hour: Σ EXACT vines of entries with labour hours > 0
     * ÷ Σ labour hours. Entries without hours are excluded from BOTH sides
     * (SQL 115 contract). Round only for display.
     */
    fun vinesPerLabourHour(entries: List<PruningEntry>, rows: List<PruningRowRef>): Double? {
        var vines = 0.0
        var hours = 0.0
        for (entry in entries) {
            val entryHours = entry.labourHours
            if (entryHours != null && entryHours > 0) {
                vines += exactVines(entry.segments, rows)
                hours += entryHours
            }
        }
        return if (hours > 0) vines / hours else null
    }

    /**
     * THE vineyard dashboard aggregation — mirrors the authoritative SQL 115
     * RPC `get_pruning_vineyard_summary` exactly:
     * * Σ EXACT per-quarter vines across blocks, rounded ONCE at the end,
     * * overall % = completed ÷ total row equivalents (row-equivalent based),
     * * vines/day = mean of per-day exact totals over days-with-entries,
     * * vines/labour hr = exact vines of hour-carrying entries ÷ person-hours,
     * * vineyard projection = the LATEST block projection.
     */
    fun vineyardSummary(blocks: List<Pair<PruningBlockMetrics, List<PruningEntry>>>): PruningVineyardSummary {
        var completedEq = 0.0
        var totalEq = 0.0
        var vinesPrunedExact = 0.0
        var vinesTotal = 0
        var blocksComplete = 0
        var blocksAtRisk = 0
        var projected: LocalDate? = null
        val vinesByDay = HashMap<String, Double>()
        var vinesForHours = 0.0
        var hours = 0.0

        for ((metrics, blockEntries) in blocks) {
            completedEq += metrics.completedRowEquivalents
            totalEq += metrics.totalRowEquivalents
            vinesPrunedExact += metrics.vinesPrunedExact
            vinesTotal += metrics.vinesTotal
            if (metrics.status == PruningStatus.Complete) blocksComplete += 1
            if (metrics.status == PruningStatus.Behind || metrics.status == PruningStatus.AtRisk) blocksAtRisk += 1
            metrics.projectedFinish?.let { finish ->
                projected = projected?.let { if (finish.isAfter(it)) finish else it } ?: finish
            }
            for (entry in blockEntries) {
                val vines = exactVines(entry.segments, metrics.rows)
                vinesByDay[entry.date] = (vinesByDay[entry.date] ?: 0.0) + vines
                val entryHours = entry.labourHours
                if (entryHours != null && entryHours > 0) {
                    vinesForHours += vines
                    hours += entryHours
                }
            }
        }

        val fraction = if (totalEq > 0) min(completedEq / totalEq, 1.0) else 0.0
        return PruningVineyardSummary(
            blockCount = blocks.size,
            completedRowEquivalents = completedEq,
            totalRowEquivalents = totalEq,
            fraction = fraction,
            vinesPrunedExact = vinesPrunedExact,
            vinesPruned = vinesPrunedExact.roundToInt(),
            vinesTotal = vinesTotal,
            vinesPerDay = if (vinesByDay.isNotEmpty()) vinesByDay.values.sum() / vinesByDay.size else null,
            vinesPerLabourHour = if (hours > 0) vinesForHours / hours else null,
            labourHours = hours,
            blocksComplete = blocksComplete,
            blocksAtRisk = blocksAtRisk,
            projectedFinish = projected,
        )
    }

    /**
     * Convenience overload building block metrics from raw store data — used
     * by the online SQL 115 parity check and the shared fixture tests.
     * Includes EVERY non-deleted paddock of the vineyard (blocks without a
     * season row or without entries still count), matching the RPC.
     */
    fun vineyardSummary(
        paddocks: List<Paddock>,
        setups: List<PruningBlockSetup>,
        entries: List<PruningEntry>,
        asOf: LocalDate = LocalDate.now(),
    ): PruningVineyardSummary {
        val blocks = paddocks.map { paddock ->
            val setup = setups
                .filter { it.paddockId == paddock.id }
                .maxByOrNull { it.seasonYear }
            val blockEntries = entries.filter { it.paddockId == paddock.id }
            metrics(paddock, setup, blockEntries, asOf) to blockEntries
        }
        return vineyardSummary(blocks)
    }

    /**
     * Full metric bundle for one block. [asOf] is the projection start date
     * (defaults to today; fixture tests pass a fixed date for determinism).
     */
    fun metrics(
        paddock: Paddock,
        setup: PruningBlockSetup?,
        entries: List<PruningEntry>,
        asOf: LocalDate = LocalDate.now(),
    ): PruningBlockMetrics {
        val rows = rowRefs(paddock, setup)
        val rowCount = rows.size
        val completed = completedSegments(entries, rows)
        val completedRowEq = completed.size / 4.0
        val totalRowEq = rowCount.toDouble()
        val fraction = if (totalRowEq > 0) min(completedRowEq / totalRowEq, 1.0) else 0.0

        val totalVines = paddock.effectiveVineCount
        val vinesPerRow = if (rowCount > 0) totalVines.toDouble() / rowCount else 0.0
        val vinesPrunedExact = exactVines(completed, rows)
        val averageRowLength = if (rowCount > 0) paddock.effectiveTotalRowLength / rowCount else 0.0

        val rate = preferredRate(entries)
        val remaining = max(totalRowEq - completedRowEq, 0.0)
        val projected = if (rate != null && rate > 0 && remaining > 0) {
            projectedFinish(remaining, rate, setup?.workingDays ?: listOf(1, 2, 3, 4, 5), from = asOf)
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
                val gone = ChronoUnit.DAYS.between(start, asOf).toDouble()
                if (total > 0) elapsed = min(max(gone / total, 0.0), 1.0)
            }
        }

        return PruningBlockMetrics(
            rows = rows,
            rowCount = rowCount,
            completed = completed,
            completedRowEquivalents = completedRowEq,
            totalRowEquivalents = totalRowEq,
            fractionComplete = fraction,
            vinesPerRow = vinesPerRow,
            vinesPrunedExact = vinesPrunedExact,
            vinesPruned = vinesPrunedExact.roundToInt(),
            vinesTotal = totalVines,
            averageRowLength = averageRowLength,
            ratePerWorkday = rate,
            projectedFinish = projected,
            status = blockStatus,
            timeElapsedFraction = elapsed,
        )
    }
}
