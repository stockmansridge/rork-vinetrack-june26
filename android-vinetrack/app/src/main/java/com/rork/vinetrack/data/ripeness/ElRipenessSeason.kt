package com.rork.vinetrack.data.ripeness

/**
 * Season / Vintage resolution for the E-L Ripeness Heatmap, transcribed from
 * the Portal cross-platform contract v1.0.0 (section 4).
 *
 * The anchor is the vineyard's stored `season_start_month` / `season_start_day`
 * only. There is no hemisphere field driving Vintage anywhere in this type.
 *
 * ## Why this is not the app-wide vintage helper
 *
 * The app's shared vintage logic mirrors the authoritative database function
 * `resolve_vintage_year` (sql/119), which contains an explicit special case:
 *
 * ```sql
 * if v_month = 1 and v_day = 1 then return v_year; end if;
 * ```
 *
 * The Portal contract has **no such special case**. For a `season_start = 1/1`
 * vineyard the two rules therefore disagree by exactly one year:
 *
 * | Date | Database rule | Portal contract |
 * |---|---|---|
 * | 2026-02-15, start 1/1 | Vintage 2026 | Vintage 2027 |
 * | 2026-01-01, start 1/1 | Vintage 2026 | Vintage 2027 |
 * | 2025-12-31, start 1/1 | Vintage 2025 | Vintage 2026 |
 *
 * Every other configuration (1 July, 1 November, and any month >= 2) agrees
 * exactly. This object exists so the heatmap reproduces the Portal numerically,
 * as the contract and its fixture require, **without** altering the
 * server-authoritative vintage used by Yield, Costing, Pruning and the Growth
 * Stage Summary report. Resolving that disagreement needs a product decision
 * and, most likely, a SQL change — neither of which is authorised here.
 */
object ElRipenessSeason {

    const val DEFAULT_SEASON_START_MONTH = 7
    const val DEFAULT_SEASON_START_DAY = 1

    /**
     * Contract: Feb -> 29, Apr/Jun/Sep/Nov -> 30, otherwise 31. Deliberately
     * year-independent, matching the Portal's `maxDayForMonth`.
     */
    fun maxDayForMonth(month: Int): Int = when (month) {
        2 -> 29
        4, 6, 9, 11 -> 30
        else -> 31
    }

    data class SeasonStart(val month: Int, val day: Int)

    /**
     * Applies the contract's fallbacks: an out-of-range month falls back to 7,
     * an invalid day falls back to 1, and the day is clamped to the month's
     * maximum.
     */
    fun normaliseSeasonSettings(month: Int?, day: Int?): SeasonStart {
        var m = month ?: DEFAULT_SEASON_START_MONTH
        if (m < 1 || m > 12) m = DEFAULT_SEASON_START_MONTH
        var d = day ?: DEFAULT_SEASON_START_DAY
        if (d < 1) d = DEFAULT_SEASON_START_DAY
        d = minOf(d, maxDayForMonth(m))
        return SeasonStart(m, d)
    }

    /**
     * Portal rule: `now >= start ? now.year + 1 : now.year`, where `start` is
     * the season start in the observation's own calendar year. The boundary is
     * inclusive of the start day.
     */
    fun vintageForDayKey(dayKey: String, month: Int?, day: Int?): Int? {
        val date = CivilDate.parse(ElRipenessHeatmap.dayKey(dayKey)) ?: return null
        return vintageForDate(date, month, day)
    }

    fun vintageForDate(date: CivilDate, month: Int?, day: Int?): Int {
        val s = normaliseSeasonSettings(month, day)
        val start = CivilDate(date.year, s.month, s.day)
        return if (date < start) date.year else date.year + 1
    }

    data class SeasonRange(val startIso: String, val endIso: String)

    /**
     * Inclusive season range for a Vintage label. The label is the *exclusive*
     * end year: a season starting 1 July 2025 is Vintage 2026.
     */
    fun seasonRangeForVintage(month: Int?, day: Int?, vintage: Int): SeasonRange {
        val s = normaliseSeasonSettings(month, day)
        val start = CivilDate(vintage - 1, s.month, s.day)
        val endExclusive = CivilDate(vintage, s.month, s.day)
        return SeasonRange(start.iso, endExclusive.adding(-1).iso)
    }

    /** Vintages that actually contain observations, newest first. */
    fun availableVintages(
        observations: List<ElRipenessHeatmap.Observation>,
        month: Int?,
        day: Int?,
    ): List<Int> = observations
        .mapNotNull { vintageForDayKey(it.dateIso, month, day) }
        .distinct()
        .sortedDescending()

    /**
     * Defaults to the current Vintage when it has observations, otherwise the
     * newest Vintage that does.
     */
    fun defaultVintage(
        observations: List<ElRipenessHeatmap.Observation>,
        month: Int?,
        day: Int?,
        today: CivilDate,
    ): Int? {
        val available = availableVintages(observations, month, day)
        if (available.isEmpty()) return null
        val current = vintageForDate(today, month, day)
        return if (available.contains(current)) current else available.first()
    }

    /** Filters observations to a Vintage by inclusive day-key comparison. */
    fun filterToVintage(
        observations: List<ElRipenessHeatmap.Observation>,
        vintage: Int,
        month: Int?,
        day: Int?,
    ): List<ElRipenessHeatmap.Observation> {
        val range = seasonRangeForVintage(month, day, vintage)
        return ElRipenessHeatmap.filterToVintage(observations, range.startIso, range.endIso)
    }
}
