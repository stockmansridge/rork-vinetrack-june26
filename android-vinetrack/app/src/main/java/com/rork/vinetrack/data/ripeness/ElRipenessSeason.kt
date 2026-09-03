package com.rork.vinetrack.data.ripeness

import com.rork.vinetrack.data.VintageResolver

/**
 * Season / Vintage resolution for the E-L Ripeness Heatmap.
 *
 * Contract v1.1.0 section 4 makes the authoritative database resolver
 * (`resolve_vintage_year`, SQL 119) the single Vintage authority for the Portal,
 * iOS and Android alike:
 *
 * > **The database / shared VintageResolver is authoritative.** No platform may
 * > invent its own season logic.
 *
 * This object therefore owns **no** Vintage arithmetic. It resolves the season
 * settings fallbacks the contract specifies and then delegates every year
 * decision and every range to [VintageResolver], which is the same helper Yield,
 * Costing, Pruning and the Growth Stage Summary already use. There is exactly one
 * Vintage implementation on this platform.
 *
 * The 1 January case is the one that used to diverge: under SQL 119 a 1 January
 * season start makes the Vintage the observation's own calendar year, so
 * `2026-02-15` is Vintage 2026 (not 2027). Contract 1.1.0 adopts that rule.
 */
object ElRipenessSeason {

    const val DEFAULT_SEASON_START_MONTH = 7
    const val DEFAULT_SEASON_START_DAY = 1

    /**
     * Contract: Feb -> 29, Apr/Jun/Sep/Nov -> 30, otherwise 31. Deliberately
     * year-independent, matching the Portal's `maxDayForMonth`. Used only to
     * normalise the stored *setting*; the per-year leap clamp lives in
     * [VintageResolver].
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

    /** Vintage for an ISO day key, or null when the key cannot be parsed. */
    fun vintageForDayKey(dayKey: String, month: Int?, day: Int?): Int? {
        val date = CivilDate.parse(ElRipenessHeatmap.dayKey(dayKey)) ?: return null
        return vintageForDate(date, month, day)
    }

    /** Delegates to the shared, database-mirroring resolver. */
    fun vintageForDate(date: CivilDate, month: Int?, day: Int?): Int {
        val s = normaliseSeasonSettings(month, day)
        return VintageResolver.vintageYear(
            year = date.year,
            monthOfDate = date.month,
            dayOfDate = date.day,
            seasonStartMonth = s.month,
            seasonStartDay = s.day,
        )
    }

    data class SeasonRange(val startIso: String, val endIso: String)

    /**
     * Inclusive season range for a Vintage label, derived from the same shared
     * resolver as [vintageForDate]. Because both come from
     * `VintageResolver.seasonYearOffset`, the range for a date's own Vintage is
     * guaranteed to contain that date.
     */
    fun seasonRangeForVintage(month: Int?, day: Int?, vintage: Int): SeasonRange {
        val s = normaliseSeasonSettings(month, day)
        val (start, endExclusive) = VintageResolver.seasonBounds(vintage, s.month, s.day)
        val startCivil = CivilDate(start.year, start.monthValue, start.dayOfMonth)
        val endCivil = CivilDate(endExclusive.year, endExclusive.monthValue, endExclusive.dayOfMonth).adding(-1)
        return SeasonRange(startCivil.iso, endCivil.iso)
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
