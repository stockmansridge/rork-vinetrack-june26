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

    /**
     * CANONICAL RULE (shared with iOS and enforced by sql/161): the pruning
     * season year is the CALENDAR YEAR IN WHICH THE WINTER PRUNING HAPPENED —
     * the year of the entry's own date, never the vintage, and never the
     * device clock at sync time. Work on 2 Aug 2026 → season 2026
     * (vintage 2027).
     */
    fun seasonYearFor(date: LocalDate): Int = date.year

    /** Same rule for an ISO `yyyy-MM-dd` entry date; falls back to today. */
    fun seasonYearFor(isoDate: String): Int =
        runCatching { LocalDate.parse(isoDate).year }.getOrDefault(LocalDate.now().year)

    /** Deterministic id of the season that OWNS an ISO-dated record. */
    fun makeForDate(vineyardId: String, paddockId: String, isoDate: String): String =
        make(vineyardId, paddockId, seasonYearFor(isoDate))

    /** The season year a NEW block setup defaults to — today's pruning year. */
    fun currentSeasonYear(): Int = LocalDate.now().year
}

/**
 * Canonical season selection — the Kotlin twin of the iOS
 * `PruningStore.setup(for:)` family. Both platforms MUST pick the same season
 * row for the same block, otherwise entries recorded on the same day split
 * across season years (the confirmed 2026-vs-2027 defect).
 */
object PruningSeasonSelection {

    /**
     * The block's setup for [seasonYear], falling back to the most recent
     * PAST season and only then to the earliest other row. A stray next-year
     * season (e.g. a portal row keyed by the vintage) must never hijack the
     * block — which both `firstOrNull` (arbitrary list order, the old Android
     * rule) and `maxByOrNull` (always the highest year) allowed.
     */
    fun setupFor(
        setups: List<PruningBlockSetup>,
        paddockId: String,
        seasonYear: Int = PruningSeasonIds.currentSeasonYear(),
    ): PruningBlockSetup? {
        val blockSetups = setups.filter { it.paddockId == paddockId }
        blockSetups.firstOrNull { it.seasonYear == seasonYear }?.let { return it }
        blockSetups.filter { it.seasonYear < seasonYear }.maxByOrNull { it.seasonYear }?.let { return it }
        return blockSetups.minByOrNull { it.seasonYear }
    }

    /** The season row a record dated [isoDate] belongs to — exact year only. */
    fun setupOnDate(
        setups: List<PruningBlockSetup>,
        paddockId: String,
        isoDate: String,
    ): PruningBlockSetup? {
        val year = PruningSeasonIds.seasonYearFor(isoDate)
        return setups.firstOrNull { it.paddockId == paddockId && it.seasonYear == year }
    }

    /**
     * The season id a record dated [isoDate] MUST be sent under — the cached
     * row for `year(isoDate)` if this device knows one, otherwise the
     * deterministic id the server derives for that same year (sql/161 §1).
     *
     * Used before every upload, including replays of payloads written by an
     * older build: the season is always re-derived from the ACTIVITY DATE,
     * never from the device clock, the selected setup season, the first or
     * highest season row, or the vintage.
     */
    fun canonicalSeasonId(
        setups: List<PruningBlockSetup>,
        vineyardId: String,
        paddockId: String,
        isoDate: String,
    ): String = setupOnDate(setups, paddockId, isoDate)?.id
        ?: PruningSeasonIds.makeForDate(vineyardId, paddockId, isoDate)
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
    /**
     * `pruning_entries.pruning_activity_id` (sql/166) — the PARENT activity this
     * row is one ALLOCATION of. Null for records that predate the activity
     * model; the server back-fills those with `pruning_activity_id = id`, which
     * is exactly what [activityKey] falls back to.
     */
    val pruningActivityId: String? = null,
    /**
     * `pruning_entries.allocation_index` — 0 for the PRIMARY allocation, the
     * only one carrying the activity's labour, timing and Work Task link.
     */
    val allocationIndex: Int = 0,
    val createdAtMs: Long = 0L,
    /**
     * Server `updated_at` — the ONLY signal that distinguishes an edited
     * record from an untouched one in the Activity Report. 0 until the entry
     * has been pulled back from the server.
     */
    val updatedAtMs: Long = 0L,
    /** Server `created_by` (the account that entered the record). */
    val enteredBy: String? = null,
    /**
     * Server `deleted_at` — a REVERSED entry. Reversed entries are retained
     * locally for the Activity Report's audit history and are excluded from
     * every progress/rate/forecast calculation.
     */
    val reversedAtMs: Long = 0L,
    /**
     * The season the SERVER has this entry filed under — `null` until the
     * record has actually been acknowledged (by `record_pruning_entry` /
     * `update_pruning_entry`, or by a pull that found the stored row).
     *
     * This is what makes "fully synced" mean something: an empty outbox only
     * proves the device stopped trying. A record counts as synced when the
     * server has confirmed it AND this device has adopted the canonical
     * season the server resolved (sql/161).
     */
    val serverSeasonId: String? = null,
    /** `pruning_seasons.season_year` of [serverSeasonId] as the server sees it. */
    val serverSeasonYear: Int? = null,
    /**
     * `pruning_entries.is_skipped` (sql/168) — this record marks its sections
     * OUT OF PRUNING ROTATION (vines removed, row pulled out, replanted, dead)
     * rather than pruned.
     *
     * A skipped record counts its sections as COMPLETE for progress and as
     * nothing at all for pruning work: no vines pruned, no labour, no cost, no
     * worker, no Work Task, no rate. The default keeps every entry cached
     * before this field existed decoding as what it was — pruned.
     */
    val isSkipped: Boolean = false,
) {
    /** A full row = 1.0; each quarter = 0.25. */
    val rowEquivalents: Double get() = segments.size / 4.0

    /**
     * The parent activity this allocation belongs to. A legacy single-block
     * record is its own activity, matching the server's back-fill, so grouping
     * by this key is safe for every record ever written.
     */
    val activityKey: String get() = pruningActivityId ?: id

    /** Reversed entries are audit history only — never progress, never rates. */
    val isReversed: Boolean get() = reversedAtMs > 0L

    /** Hours between the recorded start and finish times (HH:mm). */
    val durationHours: Double?
        get() {
            val start = parseHhmmMinutes(startTime) ?: return null
            val finish = parseHhmmMinutes(finishTime) ?: return null
            val span = finish - start
            return if (span > 0) span / 60.0 else null
        }

    private fun parseHhmmMinutes(value: String?): Int? {
        val parts = value?.split(":") ?: return null
        if (parts.size < 2) return null
        val hour = parts[0].toIntOrNull() ?: return null
        val minute = parts[1].take(2).toIntOrNull() ?: return null
        return hour * 60 + minute
    }
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
    /**
     * EVERY finished quarter — pruned AND skipped. This is what "complete"
     * means for progress, rows remaining and sections remaining.
     */
    val completed: Set<PruningSegment>,
    /** Quarters finished by actual pruning work. [completed] minus [skipped]. */
    val pruned: Set<PruningSegment> = emptySet(),
    /**
     * Quarters marked OUT OF ROTATION (sql/168 `is_skipped`). Complete, but
     * never pruning work — no vines, no labour, no cost, no rate.
     */
    val skipped: Set<PruningSegment> = emptySet(),
    val completedRowEquivalents: Double,
    /** Row equivalents finished by real pruning work. */
    val prunedRowEquivalents: Double = 0.0,
    /** Row equivalents marked skipped. */
    val skippedRowEquivalents: Double = 0.0,
    val totalRowEquivalents: Double,
    /** Pruned + skipped ÷ total — the headline "Complete overall". */
    val fractionComplete: Double,
    /** Pruned ÷ total — the "Pruned" line of the split display. */
    val fractionPruned: Double = 0.0,
    /** Skipped ÷ total — the "Skipped" line of the split display. */
    val fractionSkipped: Double = 0.0,
    val vinesPerRow: Double,
    /**
     * EXACT (unrounded) vines pruned — sum of each pruned quarter's exact
     * vines. Vineyard totals MUST sum this and round once at display
     * (rounding per block first drifts against iOS/portal).
     */
    val vinesPrunedExact: Double,
    /** Display value for this block: round(vinesPrunedExact). */
    val vinesPruned: Int,
    /**
     * EXACT vines inside skipped sections. Counted as complete, never as
     * pruned — reported separately so "vines pruned" stays truthful.
     */
    val vinesSkippedExact: Double = 0.0,
    val vinesSkipped: Int = 0,
    val vinesTotal: Int,
    val averageRowLength: Double,
    /** Hectares finished — pruned + skipped. Use for completion reporting. */
    val completionAreaHa: Double = 0.0,
    /**
     * Hectares actually WORKED. Skipped area is excluded, so this is the only
     * safe denominator for cost per hectare.
     */
    val workedAreaHa: Double = 0.0,
    val ratePerWorkday: Double?,
    val projectedFinish: LocalDate?,
    val status: PruningStatus,
    val timeElapsedFraction: Double?,
) {
    /**
     * True when any section of this block is out of rotation — the trigger for
     * showing the Pruned / Skipped / Complete split instead of one figure.
     */
    val hasSkippedSections: Boolean get() = skipped.isNotEmpty()
}

/** Outcome of the vineyard-wide completion forecast (mirrors iOS). */
sealed interface PruningForecastOutcome {
    /**
     * Not enough valid data to forecast (no entries, no configured vines,
     * zero average). NEVER render an arbitrary date for this case.
     */
    data object NotEnoughData : PruningForecastOutcome

    /** Pruning is finished — [date] is the LAST valid pruning activity. */
    data class Completed(val date: LocalDate) : PruningForecastOutcome

    /** today + estimated days remaining. */
    data class Projected(val date: LocalDate) : PruningForecastOutcome
}

/**
 * Vineyard-wide completion forecast.
 *
 * SHARED CONTRACT (identical on iOS, Android and any portal implementation):
 * * elapsed days = calendar days from the FIRST valid pruning entry through
 *   today, INCLUSIVE — days with no recorded pruning still count,
 * * average vines/day = total exact vines pruned ÷ elapsed days,
 * * remaining = every configured block's vines − vines pruned (blocks with
 *   zero progress are part of the workload),
 * * days remaining = ceil(remaining ÷ average) — rounded UP so the forecast
 *   never understates the finish date.
 */
data class PruningVineyardForecast(
    val firstEntryDate: LocalDate?,
    val lastEntryDate: LocalDate?,
    /** Inclusive calendar days from [firstEntryDate] through `asOf` (0 when unknown). */
    val elapsedDays: Int,
    val averageVinesPerElapsedDay: Double?,
    /** Exact vines still to prune across every configured block. */
    val vinesRemainingExact: Double,
    val estimatedDaysRemaining: Int?,
    val outcome: PruningForecastOutcome,
) {
    companion object {
        val EMPTY = PruningVineyardForecast(
            firstEntryDate = null,
            lastEntryDate = null,
            elapsedDays = 0,
            averageVinesPerElapsedDay = null,
            vinesRemainingExact = 0.0,
            estimatedDaysRemaining = null,
            outcome = PruningForecastOutcome.NotEnoughData,
        )
    }
}

/**
 * Vineyard-wide dashboard summary — the aggregation contract shared with iOS
 * and the SQL 115 RPC `get_pruning_vineyard_summary`. All values are exact;
 * round only at display.
 */
data class PruningVineyardSummary(
    val blockCount: Int,
    /** Pruned + skipped row equivalents — what "complete" means. */
    val completedRowEquivalents: Double,
    /** Row equivalents finished by real pruning work. */
    val prunedRowEquivalents: Double = 0.0,
    /** Row equivalents marked out of rotation. */
    val skippedRowEquivalents: Double = 0.0,
    val totalRowEquivalents: Double,
    /** Exact completion fraction (row-equivalent based, capped at 1). */
    val fraction: Double,
    /** Pruned ÷ total — the "Pruned: 70%" line. */
    val fractionPruned: Double = 0.0,
    /** Skipped ÷ total — the "Skipped: 10%" line. */
    val fractionSkipped: Double = 0.0,
    val vinesPrunedExact: Double,
    /** round(vinesPrunedExact) — the ONE rounding point for vine totals. */
    val vinesPruned: Int,
    /** Vines inside skipped sections — complete, but never pruned. */
    val vinesSkippedExact: Double = 0.0,
    val vinesSkipped: Int = 0,
    val vinesTotal: Int,
    /** Hectares finished (pruned + skipped). */
    val completionAreaHa: Double = 0.0,
    /**
     * Hectares actually worked — the ONLY safe denominator for cost per
     * hectare. Skipped area is excluded by construction.
     */
    val workedAreaHa: Double = 0.0,
    val vinesPerDay: Double?,
    val vinesPerLabourHour: Double?,
    val labourHours: Double,
    val blocksComplete: Int,
    val blocksAtRisk: Int,
    /**
     * Roll-up of the per-block projections. Parity diagnostics ONLY — the
     * dashboard shows [forecast], which is vineyard-wide and calendar based.
     */
    val projectedFinish: LocalDate?,
    /** The vineyard-wide completion forecast shown on the dashboard. */
    val forecast: PruningVineyardForecast = PruningVineyardForecast.EMPTY,
) {
    /** Vines pruned ÷ elapsed calendar days ("Average vines / day"). */
    val averageVinesPerElapsedDay: Double? get() = forecast.averageVinesPerElapsedDay

    /**
     * Vines still needing work. Skipped vines are complete and are never coming
     * back into rotation, so they leave the remaining workload.
     */
    val vinesRemaining: Int get() = maxOf(vinesTotal - vinesPruned - vinesSkipped, 0)
    val displayPercent: Int get() = PruningCalculator.displayPercent(fraction)

    /** "Pruned: 70%" — real work only. */
    val prunedPercent: Int get() = PruningCalculator.displayPercent(fractionPruned)

    /** "Skipped: 10%" — out of rotation. */
    val skippedPercent: Int get() = PruningCalculator.displayPercent(fractionSkipped)

    /**
     * True when the vineyard has any out-of-rotation sections, so the UI should
     * show the Pruned / Skipped / Complete split rather than one figure.
     */
    val hasSkippedSections: Boolean get() = skippedRowEquivalents > 0.0
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
        val configured = paddock.rows.orEmpty().sortedBy { it.number }
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
    /**
     * Quarters marked SKIPPED (out of rotation), canonicalised onto the block's
     * rows exactly like [completedSegments].
     *
     * A quarter that is ALSO claimed by a real pruning record is not returned:
     * recorded work always outranks a skip, so a stray overlapping skip can
     * never erase pruning from the vines-pruned figures.
     */
    fun skippedSegments(entries: List<PruningEntry>, rows: List<PruningRowRef>): Set<PruningSegment> {
        val skipped = completedSegments(entries.filter { it.isSkipped }, rows)
        if (skipped.isEmpty()) return emptySet()
        val worked = completedSegments(entries.filter { !it.isSkipped }, rows)
        return skipped - worked
    }

    /**
     * Entries that represent actual pruning WORK. Skipped records carry no
     * labour, no vines and no rate, so every work-rate calculation drops them
     * from both sides of the ratio rather than counting them as a fast day.
     */
    fun workEntries(entries: List<PruningEntry>): List<PruningEntry> = entries.filter { !it.isSkipped }

    /**
     * Hectares represented by a set of quarters: each quarter is 25% of THAT
     * row's length × the block's row width. Rows without geometry use the
     * average mapped length, matching the vine-weighting rule.
     */
    fun areaHectares(
        segments: Collection<PruningSegment>,
        rows: List<PruningRowRef>,
        paddock: Paddock,
    ): Double {
        // Row width is optional on a block that was never fully mapped; with no
        // width there is no area to report, and 0 is the honest answer.
        val rowWidth = paddock.rowWidth ?: 0.0
        if (rowWidth <= 0 || rows.isEmpty()) return 0.0
        val mapped = rows.mapNotNull { it.lengthMetres }.filter { it > 0 }
        val fallback = if (mapped.isEmpty()) {
            if (paddock.effectiveTotalRowLength > 0) paddock.effectiveTotalRowLength / rows.size else 0.0
        } else {
            mapped.sum() / mapped.size
        }
        if (fallback <= 0.0 && mapped.isEmpty()) return 0.0
        val lengthByKey = rows.associateBy({ it.key }, { it.lengthMetres ?: fallback })
        val metres = segments.sumOf { (lengthByKey[it.rowKey] ?: fallback) / 4.0 }
        return metres * rowWidth / 10_000.0
    }

    fun rowEquivalentsPerDay(entries: List<PruningEntry>, lastDays: Int?): Double? {
        // Skipped records are excluded: marking a dead block out of rotation is
        // not a productive day and must never inflate the crew's throughput.
        val byDay = workEntries(entries).groupBy { it.date }
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
        for (entry in workEntries(entries)) {
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
        for (entry in workEntries(entries)) {
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
     * * `projectedFinish` = the LATEST block projection (kept ONLY for the
     *   SQL 115 parity diagnostic — never displayed; the dashboard uses
     *   `forecast`, the elapsed-calendar-day vineyard forecast).
     */
    fun vineyardSummary(
        blocks: List<Pair<PruningBlockMetrics, List<PruningEntry>>>,
        asOf: LocalDate = LocalDate.now(),
    ): PruningVineyardSummary {
        var completedEq = 0.0
        var prunedEq = 0.0
        var skippedEq = 0.0
        var totalEq = 0.0
        var vinesPrunedExact = 0.0
        var vinesSkippedExact = 0.0
        var vinesTotal = 0
        var completionAreaHa = 0.0
        var workedAreaHa = 0.0
        var blocksComplete = 0
        var blocksAtRisk = 0
        var projected: LocalDate? = null
        val vinesByDay = HashMap<String, Double>()
        val validEntryDays = mutableListOf<LocalDate>()
        var vinesForHours = 0.0
        var hours = 0.0

        for ((metrics, blockEntries) in blocks) {
            completedEq += metrics.completedRowEquivalents
            prunedEq += metrics.prunedRowEquivalents
            skippedEq += metrics.skippedRowEquivalents
            totalEq += metrics.totalRowEquivalents
            vinesPrunedExact += metrics.vinesPrunedExact
            vinesSkippedExact += metrics.vinesSkippedExact
            vinesTotal += metrics.vinesTotal
            completionAreaHa += metrics.completionAreaHa
            workedAreaHa += metrics.workedAreaHa
            if (metrics.status == PruningStatus.Complete) blocksComplete += 1
            if (metrics.status == PruningStatus.Behind || metrics.status == PruningStatus.AtRisk) blocksAtRisk += 1
            metrics.projectedFinish?.let { finish ->
                projected = projected?.let { if (finish.isAfter(it)) finish else it } ?: finish
            }
            // Skipped records are excluded from EVERY work figure below: they
            // carry no vines pruned, no labour and no rate, so including them
            // would make an out-of-rotation block look like a productive day.
            for (entry in workEntries(blockEntries)) {
                val vines = exactVines(entry.segments, metrics.rows)
                vinesByDay[entry.date] = (vinesByDay[entry.date] ?: 0.0) + vines
                // A VALID entry is one whose segments actually resolve onto
                // this block's rows — quarters pointing at deleted rows (or an
                // entry reversed to empty) must not anchor the elapsed period.
                val day = parseDate(entry.date)
                if (day != null && completedSegments(listOf(entry), metrics.rows).isNotEmpty()) {
                    validEntryDays.add(day)
                }
                val entryHours = entry.labourHours
                if (entryHours != null && entryHours > 0) {
                    vinesForHours += vines
                    hours += entryHours
                }
            }
        }

        val fraction = if (totalEq > 0) min(completedEq / totalEq, 1.0) else 0.0
        val complete = (totalEq > 0 && completedEq >= totalEq - 0.0001) ||
            (vinesTotal > 0 && vinesTotal - vinesPrunedExact - vinesSkippedExact < 0.5)
        val forecast = vineyardForecast(
            vinesPrunedExact = vinesPrunedExact,
            vinesTotal = vinesTotal,
            isComplete = complete,
            entryDates = validEntryDays,
            asOf = asOf,
            vinesSkippedExact = vinesSkippedExact,
        )
        return PruningVineyardSummary(
            blockCount = blocks.size,
            completedRowEquivalents = completedEq,
            prunedRowEquivalents = prunedEq,
            skippedRowEquivalents = skippedEq,
            totalRowEquivalents = totalEq,
            fraction = fraction,
            fractionPruned = if (totalEq > 0) min(prunedEq / totalEq, 1.0) else 0.0,
            fractionSkipped = if (totalEq > 0) min(skippedEq / totalEq, 1.0) else 0.0,
            vinesPrunedExact = vinesPrunedExact,
            vinesPruned = vinesPrunedExact.roundToInt(),
            vinesSkippedExact = vinesSkippedExact,
            vinesSkipped = vinesSkippedExact.roundToInt(),
            vinesTotal = vinesTotal,
            completionAreaHa = completionAreaHa,
            workedAreaHa = workedAreaHa,
            vinesPerDay = if (vinesByDay.isNotEmpty()) vinesByDay.values.sum() / vinesByDay.size else null,
            vinesPerLabourHour = if (hours > 0) vinesForHours / hours else null,
            labourHours = hours,
            blocksComplete = blocksComplete,
            blocksAtRisk = blocksAtRisk,
            projectedFinish = projected,
            forecast = forecast,
        )
    }

    /**
     * THE vineyard completion forecast — the one rule iOS, Android and the
     * portal must all apply (see [PruningVineyardForecast]).
     *
     * * [entryDates] — dates of every VALID pruning entry across ALL blocks.
     * * [vinesTotal] — vines of EVERY configured block, including blocks with
     *   zero progress (they are still remaining workload).
     *
     * Never derived from per-block rates or per-block projections, and never
     * from "days that contain entries" — rain days count as elapsed time.
     */
    fun vineyardForecast(
        vinesPrunedExact: Double,
        vinesTotal: Int,
        isComplete: Boolean,
        entryDates: Collection<LocalDate>,
        asOf: LocalDate = LocalDate.now(),
        /**
         * Vines inside sections marked OUT OF ROTATION. They are already
         * complete and will never be pruned, so they leave the remaining
         * workload without ever counting as work done.
         */
        vinesSkippedExact: Double = 0.0,
    ): PruningVineyardForecast {
        val days = entryDates.sorted()
        val first = days.firstOrNull()
        val last = days.lastOrNull()
        val remaining = max(vinesTotal - vinesPrunedExact - vinesSkippedExact, 0.0)
        val empty = PruningVineyardForecast(
            firstEntryDate = first,
            lastEntryDate = last,
            elapsedDays = 0,
            averageVinesPerElapsedDay = null,
            vinesRemainingExact = remaining,
            estimatedDaysRemaining = null,
            outcome = PruningForecastOutcome.NotEnoughData,
        )

        // No configured vines, or no valid pruning activity at all.
        if (vinesTotal <= 0 || first == null || last == null || vinesPrunedExact <= 0.0) return empty

        // Inclusive elapsed rule: the first pruning day counts as day 1, and
        // every calendar day since counts — including days with no entries.
        val spanned = ChronoUnit.DAYS.between(first, asOf).toInt()
        val elapsedDays = max(spanned + 1, 1)
        val average = vinesPrunedExact / elapsedDays
        if (average <= 0.0) return empty.copy(elapsedDays = elapsedDays)

        // < 0.5 rounds to "0 vines remaining" on the dashboard — treat it as done.
        if (isComplete || remaining < 0.5) {
            return empty.copy(
                elapsedDays = elapsedDays,
                averageVinesPerElapsedDay = average,
                estimatedDaysRemaining = 0,
                outcome = PruningForecastOutcome.Completed(last),
            )
        }

        val daysRemaining = ceil(remaining / average).toInt().coerceIn(1, 3_650)
        return empty.copy(
            elapsedDays = elapsedDays,
            averageVinesPerElapsedDay = average,
            estimatedDaysRemaining = daysRemaining,
            outcome = PruningForecastOutcome.Projected(asOf.plusDays(daysRemaining.toLong())),
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
        return vineyardSummary(blocks, asOf)
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
        // `completed` is pruned + skipped: both finish a section, so both count
        // toward progress, rows remaining and sections remaining. Only `pruned`
        // is ever treated as work done.
        val completed = completedSegments(entries, rows)
        val skipped = skippedSegments(entries, rows)
        val pruned = completed - skipped
        val completedRowEq = completed.size / 4.0
        val prunedRowEq = pruned.size / 4.0
        val skippedRowEq = skipped.size / 4.0
        val totalRowEq = rowCount.toDouble()
        val fraction = if (totalRowEq > 0) min(completedRowEq / totalRowEq, 1.0) else 0.0
        val prunedFraction = if (totalRowEq > 0) min(prunedRowEq / totalRowEq, 1.0) else 0.0
        val skippedFraction = if (totalRowEq > 0) min(skippedRowEq / totalRowEq, 1.0) else 0.0

        val totalVines = paddock.effectiveVineCount
        val vinesPerRow = if (rowCount > 0) totalVines.toDouble() / rowCount else 0.0
        val vinesPrunedExact = exactVines(pruned, rows)
        val vinesSkippedExact = exactVines(skipped, rows)
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
            pruned = pruned,
            skipped = skipped,
            completedRowEquivalents = completedRowEq,
            prunedRowEquivalents = prunedRowEq,
            skippedRowEquivalents = skippedRowEq,
            totalRowEquivalents = totalRowEq,
            fractionComplete = fraction,
            fractionPruned = prunedFraction,
            fractionSkipped = skippedFraction,
            vinesPerRow = vinesPerRow,
            vinesPrunedExact = vinesPrunedExact,
            vinesPruned = vinesPrunedExact.roundToInt(),
            vinesSkippedExact = vinesSkippedExact,
            vinesSkipped = vinesSkippedExact.roundToInt(),
            vinesTotal = totalVines,
            averageRowLength = averageRowLength,
            completionAreaHa = areaHectares(completed, rows, paddock),
            workedAreaHa = areaHectares(pruned, rows, paddock),
            ratePerWorkday = rate,
            projectedFinish = projected,
            status = blockStatus,
            timeElapsedFraction = elapsed,
        )
    }
}
